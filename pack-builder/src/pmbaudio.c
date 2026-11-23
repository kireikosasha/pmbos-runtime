/*
 * libasound_module_pcm_pmbos.so - ALSA PCM plugin "pmbos": sound of the programs in the PMB OS rootfs (Wine's
 * winealsa.drv through box64's libasound wrapper, or any native ALSA client) played by the PMB OS app.
 *
 * Android has no ALSA devices an app could open, so the "device" is the app itself: the plugin connects to a
 * unix socket the app listens on (AudioServer.java) and streams PCM to it; the app feeds an AudioTrack. One PCM
 * = one connection = one AudioTrack (Android mixes them).
 *
 * ALSA configuration (written by the launcher, ALSA_CONFIG_PATH):
 *     pcm_type.pmbos { lib "<imagefs>/usr/lib/aarch64-linux-gnu/alsa-lib/libasound_module_pcm_pmbos.so" }
 *     pcm.!default { type pmbos }                 # optional: socket "<name>"
 * The socket comes from the "socket" field or $PMBOS_AUDIO_SOCKET: a path, or "@name" for the abstract namespace.
 *
 * Protocol (little endian; every message starts with four uint32: type, a, b, c):
 *   client -> server
 *     CONFIG  a = rate, b = channels, c = sample format (PMB_FMT_*) | protocol version << 16
 *             The server (re)creates its output and answers READY.
 *     DATA    a = byte count; that many bytes of interleaved PCM follow
 *     RESET   a = epoch, b = 1: let the buffered sound play out (end of a drain), 0: drop it now
 *             Everything played from here on is reported with this epoch.
 *   server -> client
 *     READY   a = 0 or an errno (format not playable), b = frames the device buffers behind the server
 *     PLAYED  a = epoch, b = frames taken out of the stream since the last PLAYED (they are in the device now)
 *
 * Timing model: the hardware pointer is what the server has taken, never more than the application has written.
 * So ALSA's "buffer" is the sound still in flight (the socket) - it empties as fast as the device accepts it, and an
 * application that stops writing gets silence, not an xrun. The device's own buffer shows up in snd_pcm_delay().
 * Frames an application takes back (snd_pcm_rewind) cannot be taken back from the socket: when it writes them
 * again they are skipped, so everything is played exactly once.
 *
 * Playback only (capture streams fail to open: no microphone here).
 *
 * Build (stage pmbaudio): gcc -shared -fPIC ... pmbaudio.c -lasound
 * SPDX-License-Identifier: LGPL-2.1-or-later (an ALSA plugin; same terms as alsa-lib)
 */
#define _GNU_SOURCE
#include <alsa/asoundlib.h>
#include <alsa/pcm_external.h>

#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <unistd.h>

#define PMB_AUDIO_VERSION 1

#define PMB_C_CONFIG 1
#define PMB_C_DATA 2
#define PMB_C_RESET 3
#define PMB_S_READY 1
#define PMB_S_PLAYED 2

#define PMB_FMT_U8 0
#define PMB_FMT_S16 1
#define PMB_FMT_FLOAT 2

#define PMB_READY_TIMEOUT_MS 4000

struct pmb_msg {
    uint32_t type, a, b, c;
};

typedef struct {
    snd_pcm_ioplug_t io;
    int fd;                  /* connection to the app */
    int dead;                /* the connection broke: every call fails from now on */
    int wake;                /* eventfd, readable while the application may write (for poll) */
    int wake_set;
    uint32_t epoch;          /* counts RESETs; PLAYED of older epochs are ignored */
    int dirty;               /* sound was sent since the last RESET */
    int ready;               /* READY arrived for the last CONFIG */
    int ready_error;
    unsigned int frame_bytes;   /* of the application's format */
    int wire_format;         /* PMB_FMT_* the server gets */
    unsigned int wire_frame_bytes;
    snd_pcm_uframes_t boundary;
    snd_pcm_uframes_t avail_min;
    snd_pcm_uframes_t appl_raw; /* io.appl_ptr when it was last looked at */
    uint64_t appl;           /* application pointer, unwrapped, 0 at prepare */
    uint64_t sent;           /* position up to which frames went to the server */
    uint64_t base;           /* position of the first frame of this epoch */
    uint64_t played;         /* frames the server took in this epoch */
    uint64_t hw;             /* hardware pointer reported so far */
    uint32_t latency;        /* frames buffered behind the server */
    unsigned char rx[sizeof(struct pmb_msg)];
    size_t rx_len;
    void *conv;              /* converted samples of one transfer */
    size_t conv_size;
} pmb_t;

/* ------------------------------------------------------------------ connection */

static void pmb_fail(pmb_t *p)
{
    p->dead = 1; /* the fd stays open: it keeps poll() returning, close() releases it */
}

static int pmb_send(pmb_t *p, const struct pmb_msg *m, const void *payload, size_t len)
{
    struct iovec iov[2] = {
        { .iov_base = (void *)m, .iov_len = sizeof(*m) },
        { .iov_base = (void *)payload, .iov_len = len },
    };
    struct msghdr mh = { .msg_iov = iov, .msg_iovlen = len ? 2 : 1 };

    if (p->dead)
        return -ENODEV;
    while (mh.msg_iovlen) {
        ssize_t n = sendmsg(p->fd, &mh, MSG_NOSIGNAL);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                struct pollfd pfd = { .fd = p->fd, .events = POLLOUT };
                poll(&pfd, 1, 1000);
                continue;
            }
            pmb_fail(p);
            return -ENODEV;
        }
        while (n > 0 && mh.msg_iovlen) {
            if ((size_t)n >= mh.msg_iov->iov_len) {
                n -= mh.msg_iov->iov_len;
                mh.msg_iov++;
                mh.msg_iovlen--;
            } else {
                mh.msg_iov->iov_base = (char *)mh.msg_iov->iov_base + n;
                mh.msg_iov->iov_len -= n;
                n = 0;
            }
        }
    }
    return 0;
}

static void pmb_handle(pmb_t *p, const struct pmb_msg *m)
{
    switch (m->type) {
    case PMB_S_READY:
        p->ready = 1;
        p->ready_error = (int)m->a;
        p->latency = m->b;
        break;
    case PMB_S_PLAYED:
        if (m->a == p->epoch)
            p->played += m->b;
        break;
    default:
        break; /* a newer server: not for us */
    }
}

/* Takes everything the server has sent so far; never blocks. */
static void pmb_pump(pmb_t *p)
{
    if (p->dead)
        return;
    for (;;) {
        ssize_t n = recv(p->fd, p->rx + p->rx_len, sizeof(p->rx) - p->rx_len, MSG_DONTWAIT);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            if (errno != EAGAIN && errno != EWOULDBLOCK)
                pmb_fail(p);
            return;
        }
        if (n == 0) {
            pmb_fail(p);
            return;
        }
        p->rx_len += (size_t)n;
        if (p->rx_len == sizeof(p->rx)) {
            struct pmb_msg m;
            memcpy(&m, p->rx, sizeof(m));
            p->rx_len = 0;
            pmb_handle(p, &m);
        }
    }
}

static int pmb_connect(const char *name)
{
    struct sockaddr_un addr;
    socklen_t len;
    size_t n = strlen(name);
    int fd, size = 512 * 1024;

    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    if (name[0] == '@') {
        /* abstract namespace: sun_path[0] = 0, the name is not NUL terminated */
        if (n - 1 == 0 || n - 1 > sizeof(addr.sun_path) - 1)
            return -EINVAL;
        memcpy(addr.sun_path + 1, name + 1, n - 1);
        len = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + n);
    } else {
        if (n == 0 || n >= sizeof(addr.sun_path))
            return -EINVAL;
        memcpy(addr.sun_path, name, n);
        len = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + n + 1);
    }
    fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0)
        return -errno;
    if (connect(fd, (struct sockaddr *)&addr, len) < 0) {
        int err = errno;
        close(fd);
        return -err;
    }
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, sizeof(size)); /* best effort: room for a whole ALSA buffer */
    return fd;
}

/* ------------------------------------------------------------------ pointers */

/* Follows io.appl_ptr (it also moves backwards: snd_pcm_rewind). */
static void pmb_track(pmb_t *p)
{
    snd_pcm_uframes_t raw = p->io.appl_ptr;
    snd_pcm_sframes_t d = (snd_pcm_sframes_t)(raw - p->appl_raw);

    if (p->boundary) {
        snd_pcm_sframes_t half = (snd_pcm_sframes_t)(p->boundary / 2);
        if (d > half)
            d -= (snd_pcm_sframes_t)p->boundary;
        else if (d < -half)
            d += (snd_pcm_sframes_t)p->boundary;
    }
    if (d < 0 && (uint64_t)(-d) > p->appl)
        p->appl = 0;
    else
        p->appl += (uint64_t)d;
    p->appl_raw = raw;
}

/* The hardware pointer: what the server took, within [last reported, application pointer]. */
static uint64_t pmb_hw(pmb_t *p)
{
    uint64_t hw = p->base + p->played;

    if (hw > p->appl)
        hw = p->appl;
    if (hw < p->hw)
        hw = p->hw;
    p->hw = hw;
    return hw;
}

static void pmb_update_wake(pmb_t *p)
{
    uint64_t queued = p->appl > p->hw ? p->appl - p->hw : 0;
    snd_pcm_uframes_t size = p->io.buffer_size;
    snd_pcm_uframes_t min = p->avail_min ? p->avail_min : 1;
    /* while draining nobody writes: the only news is "everything is out" (ioplug then stops the stream) */
    int writable = p->dead || size == 0 ||
                   (p->io.state == SND_PCM_STATE_DRAINING ? queued == 0 : queued <= size && size - queued >= min);
    uint64_t one = 1;

    if (writable && !p->wake_set) {
        if (write(p->wake, &one, sizeof(one)) == sizeof(one))
            p->wake_set = 1;
    } else if (!writable && p->wake_set) {
        if (read(p->wake, &one, sizeof(one)) == sizeof(one))
            p->wake_set = 0;
    }
}

static void pmb_refresh(pmb_t *p)
{
    pmb_pump(p);
    pmb_track(p);
    pmb_hw(p);
    pmb_update_wake(p);
}

/* ------------------------------------------------------------------ callbacks */

static int pmb_reset(pmb_t *p, int play_out)
{
    struct pmb_msg m = { .type = PMB_C_RESET, .a = ++p->epoch, .b = play_out ? 1 : 0 };

    p->dirty = 0;
    return pmb_send(p, &m, NULL, 0);
}

static int pmb_start(snd_pcm_ioplug_t *io)
{
    pmb_t *p = io->private_data;
    return p->dead ? -ENODEV : 0; /* the server plays what arrives, when it arrives */
}

static int pmb_stop(snd_pcm_ioplug_t *io)
{
    pmb_t *p = io->private_data;

    if (p->dead)
        return 0;
    /* the end of a drain keeps what is in the device, a drop silences it */
    if (p->dirty)
        pmb_reset(p, io->state == SND_PCM_STATE_DRAINING);
    return 0;
}

static int pmb_prepare(snd_pcm_ioplug_t *io)
{
    pmb_t *p = io->private_data;

    if (p->dead)
        return -ENODEV;
    /* without anything sent since the last RESET no PLAYED of this epoch can be on its way */
    if (p->dirty && pmb_reset(p, 0) < 0)
        return -ENODEV;
    p->appl_raw = io->appl_ptr; /* ioplug has just reset it */
    p->appl = p->sent = p->base = p->hw = 0;
    p->played = 0;
    pmb_update_wake(p);
    return 0;
}

static snd_pcm_sframes_t pmb_pointer(snd_pcm_ioplug_t *io)
{
    pmb_t *p = io->private_data;
    uint64_t hw;

    if (p->dead)
        return -ENODEV;
    pmb_refresh(p);
    hw = p->hw;
    return (snd_pcm_sframes_t)(p->boundary ? hw % p->boundary : hw);
}

static int pmb_delay(snd_pcm_ioplug_t *io, snd_pcm_sframes_t *delayp)
{
    pmb_t *p = io->private_data;

    if (p->dead)
        return -ENODEV;
    pmb_refresh(p);
    *delayp = (snd_pcm_sframes_t)((p->appl > p->hw ? p->appl - p->hw : 0) + p->latency);
    return 0;
}

/* Samples the server does not take as they are become 32-bit floats. */
static const void *pmb_convert(pmb_t *p, const unsigned char *src, snd_pcm_uframes_t frames)
{
    size_t samples = (size_t)frames * p->io.channels, need = samples * sizeof(float), i;
    float *out;

    if (p->conv_size < need) {
        void *n = realloc(p->conv, need);
        if (!n)
            return NULL;
        p->conv = n;
        p->conv_size = need;
    }
    out = p->conv;
    if (p->io.format == SND_PCM_FORMAT_S24_3LE) {
        for (i = 0; i < samples; i++, src += 3) {
            int32_t v = (int32_t)((uint32_t)src[0] << 8 | (uint32_t)src[1] << 16 | (uint32_t)src[2] << 24) >> 8;
            out[i] = (float)v * (1.0f / 8388608.0f);
        }
    } else { /* S32_LE */
        for (i = 0; i < samples; i++, src += 4) {
            int32_t v;
            memcpy(&v, src, 4);
            out[i] = (float)v * (1.0f / 2147483648.0f);
        }
    }
    return out;
}

static snd_pcm_sframes_t pmb_transfer(snd_pcm_ioplug_t *io, const snd_pcm_channel_area_t *areas,
                                      snd_pcm_uframes_t offset, snd_pcm_uframes_t size)
{
    pmb_t *p = io->private_data;
    const unsigned char *src = (const unsigned char *)areas->addr + (areas->first + areas->step * offset) / 8;
    snd_pcm_uframes_t skip = 0, frames;
    uint64_t pos;

    if (p->dead)
        return -ENODEV;
    pmb_pump(p);
    pmb_track(p);
    pos = p->appl; /* position of the first frame of this write */
    if (pos < p->sent) {
        /* taken back by a rewind and written again: the server has these frames already */
        skip = p->sent - pos < size ? (snd_pcm_uframes_t)(p->sent - pos) : size;
    } else if (pos > p->sent) {
        /* the application skipped ahead (snd_pcm_forward): nothing to play for the gap */
        p->base += pos - p->sent;
        p->sent = pos;
    }
    frames = size - skip;
    if (frames) {
        struct pmb_msg m = { .type = PMB_C_DATA };
        const void *data = src + (size_t)skip * p->frame_bytes;

        if (p->wire_frame_bytes != p->frame_bytes || p->io.format == SND_PCM_FORMAT_S32_LE) {
            data = pmb_convert(p, data, frames);
            if (!data)
                return -ENOMEM;
        }
        m.a = (uint32_t)(frames * p->wire_frame_bytes);
        if (pmb_send(p, &m, data, m.a) < 0)
            return -ENODEV;
        p->sent = pos + size;
        p->dirty = 1;
    }
    return (snd_pcm_sframes_t)size;
}

static int pmb_hw_params(snd_pcm_ioplug_t *io, snd_pcm_hw_params_t *params)
{
    pmb_t *p = io->private_data;
    struct pmb_msg m = { .type = PMB_C_CONFIG, .a = io->rate, .b = io->channels };
    int waited = 0;
    (void)params;

    if (p->dead)
        return -ENODEV;
    p->frame_bytes = (unsigned int)(snd_pcm_format_physical_width(io->format) / 8) * io->channels;
    switch (io->format) {
    case SND_PCM_FORMAT_U8:
        p->wire_format = PMB_FMT_U8;
        p->wire_frame_bytes = io->channels;
        break;
    case SND_PCM_FORMAT_S16_LE:
        p->wire_format = PMB_FMT_S16;
        p->wire_frame_bytes = 2 * io->channels;
        break;
    case SND_PCM_FORMAT_S24_3LE:
    case SND_PCM_FORMAT_S32_LE:
    case SND_PCM_FORMAT_FLOAT_LE:
        p->wire_format = PMB_FMT_FLOAT;
        p->wire_frame_bytes = 4 * io->channels;
        break;
    default:
        return -EINVAL;
    }
    /* the same rule as alsa-lib's, in case sw_params is not called before the first pointer() */
    p->boundary = io->buffer_size;
    while (p->boundary && p->boundary * 2 <= (snd_pcm_uframes_t)LONG_MAX - io->buffer_size)
        p->boundary *= 2;

    m.c = (uint32_t)p->wire_format | (uint32_t)PMB_AUDIO_VERSION << 16;
    p->ready = 0;
    /* the server starts a new output: nothing of the old one counts, and it learns the epoch to report */
    if (pmb_send(p, &m, NULL, 0) < 0 || pmb_reset(p, 0) < 0)
        return -ENODEV;
    while (!p->ready && !p->dead && waited < PMB_READY_TIMEOUT_MS) {
        struct pollfd pfd = { .fd = p->fd, .events = POLLIN };
        int r = poll(&pfd, 1, 100);
        if (r < 0 && errno != EINTR)
            break;
        if (r == 0)
            waited += 100;
        pmb_pump(p);
    }
    if (p->dead)
        return -ENODEV;
    if (!p->ready)
        return -ETIMEDOUT;
    if (p->ready_error)
        return -EINVAL;
    return 0;
}

static int pmb_sw_params(snd_pcm_ioplug_t *io, snd_pcm_sw_params_t *params)
{
    pmb_t *p = io->private_data;
    snd_pcm_uframes_t v;

    if (snd_pcm_sw_params_get_boundary(params, &v) == 0 && v)
        p->boundary = v;
    if (snd_pcm_sw_params_get_avail_min(params, &v) == 0)
        p->avail_min = v;
    pmb_update_wake(p);
    return 0;
}

static int pmb_poll_descriptors_count(snd_pcm_ioplug_t *io)
{
    (void)io;
    return 2;
}

static int pmb_poll_descriptors(snd_pcm_ioplug_t *io, struct pollfd *pfd, unsigned int space)
{
    pmb_t *p = io->private_data;

    if (space < 2)
        return -EINVAL;
    pmb_refresh(p);
    /* room to write right now, or news from the server that may make room */
    pfd[0].fd = p->wake;
    pfd[0].events = POLLIN;
    pfd[0].revents = 0;
    pfd[1].fd = p->fd;
    pfd[1].events = POLLIN;
    pfd[1].revents = 0;
    return 2;
}

static int pmb_poll_revents(snd_pcm_ioplug_t *io, struct pollfd *pfd, unsigned int nfds, unsigned short *revents)
{
    pmb_t *p = io->private_data;
    (void)pfd;
    (void)nfds;

    pmb_refresh(p);
    *revents = 0;
    if (p->dead)
        *revents |= POLLERR;
    else if (p->wake_set)
        *revents |= POLLOUT;
    return 0;
}

static int pmb_close(snd_pcm_ioplug_t *io)
{
    pmb_t *p = io->private_data;

    if (p->fd >= 0)
        close(p->fd);
    if (p->wake >= 0)
        close(p->wake);
    free(p->conv);
    free(p);
    return 0;
}

static const snd_pcm_ioplug_callback_t pmb_callbacks = {
    .start = pmb_start,
    .stop = pmb_stop,
    .pointer = pmb_pointer,
    .transfer = pmb_transfer,
    .close = pmb_close,
    .hw_params = pmb_hw_params,
    .sw_params = pmb_sw_params,
    .prepare = pmb_prepare,
    .poll_descriptors_count = pmb_poll_descriptors_count,
    .poll_descriptors = pmb_poll_descriptors,
    .poll_revents = pmb_poll_revents,
    .delay = pmb_delay,
};

static int pmb_constraints(pmb_t *p)
{
    static const unsigned int access[] = { SND_PCM_ACCESS_RW_INTERLEAVED };
    static const unsigned int formats[] = {
        SND_PCM_FORMAT_FLOAT_LE, SND_PCM_FORMAT_S16_LE, SND_PCM_FORMAT_U8,
        SND_PCM_FORMAT_S32_LE,   SND_PCM_FORMAT_S24_3LE,
    };
    int err;

    if ((err = snd_pcm_ioplug_set_param_list(&p->io, SND_PCM_IOPLUG_HW_ACCESS, 1, access)) < 0 ||
        (err = snd_pcm_ioplug_set_param_list(&p->io, SND_PCM_IOPLUG_HW_FORMAT,
                                             sizeof(formats) / sizeof(formats[0]), formats)) < 0 ||
        (err = snd_pcm_ioplug_set_param_minmax(&p->io, SND_PCM_IOPLUG_HW_CHANNELS, 1, 2)) < 0 ||
        (err = snd_pcm_ioplug_set_param_minmax(&p->io, SND_PCM_IOPLUG_HW_RATE, 8000, 192000)) < 0 ||
        (err = snd_pcm_ioplug_set_param_minmax(&p->io, SND_PCM_IOPLUG_HW_PERIOD_BYTES, 64, 128 * 1024)) < 0 ||
        (err = snd_pcm_ioplug_set_param_minmax(&p->io, SND_PCM_IOPLUG_HW_PERIODS, 2, 1024)) < 0 ||
        (err = snd_pcm_ioplug_set_param_minmax(&p->io, SND_PCM_IOPLUG_HW_BUFFER_BYTES, 256, 256 * 1024)) < 0)
        return err;
    return 0;
}

SND_PCM_PLUGIN_DEFINE_FUNC(pmbos)
{
    snd_config_iterator_t i, next;
    const char *socket_name = NULL;
    pmb_t *p;
    int err;
    (void)root;

    snd_config_for_each(i, next, conf) {
        snd_config_t *n = snd_config_iterator_entry(i);
        const char *id;

        if (snd_config_get_id(n, &id) < 0)
            continue;
        if (!strcmp(id, "comment") || !strcmp(id, "type") || !strcmp(id, "hint"))
            continue;
        if (!strcmp(id, "socket")) {
            if (snd_config_get_string(n, &socket_name) < 0) {
                SNDERR("pmbos: socket must be a string");
                return -EINVAL;
            }
            continue;
        }
        SNDERR("pmbos: unknown field %s", id);
        return -EINVAL;
    }
    if (stream != SND_PCM_STREAM_PLAYBACK)
        return -ENODEV;
    if (!socket_name || !socket_name[0])
        socket_name = getenv("PMBOS_AUDIO_SOCKET");
    if (!socket_name || !socket_name[0])
        return -ENOENT;

    p = calloc(1, sizeof(*p));
    if (!p)
        return -ENOMEM;
    p->fd = p->wake = -1;
    p->fd = pmb_connect(socket_name);
    if (p->fd < 0) {
        err = p->fd;
        free(p);
        return err;
    }
    p->wake = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (p->wake < 0) {
        err = -errno;
        close(p->fd);
        free(p);
        return err;
    }

    p->io.version = SND_PCM_IOPLUG_VERSION;
    p->io.name = "PMB OS sound output";
    p->io.callback = &pmb_callbacks;
    p->io.private_data = p;
    p->io.mmap_rw = 0;
    p->io.flags = SND_PCM_IOPLUG_FLAG_BOUNDARY_WA;
    p->io.poll_fd = p->wake;
    p->io.poll_events = POLLIN;

    err = snd_pcm_ioplug_create(&p->io, name, stream, mode);
    if (err < 0) {
        close(p->wake);
        close(p->fd);
        free(p);
        return err;
    }
    err = pmb_constraints(p);
    if (err < 0) {
        snd_pcm_ioplug_delete(&p->io); /* calls pmb_close */
        return err;
    }
    *pcmp = p->io.pcm;
    return 0;
}

SND_PCM_PLUGIN_SYMBOL(pmbos);
