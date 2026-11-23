/*
 * Self-test of libasound_module_pcm_pmbos.so (pmbaudio.c) against a stand-in for the app's AudioServer: buffer
 * accounting, flow control through poll, rewind, drop, drain, sample conversion, a vanishing server.
 *
 * Usage: pmbaudio-test <plugin .so> <scratch dir>
 * Build: gcc -O1 -o pmbaudio-test pmbaudio-test.c -lasound -lpthread
 */
#define _GNU_SOURCE
#include <alsa/asoundlib.h>

#include <errno.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

struct msg {
    uint32_t type, a, b, c;
};

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
static int listener = -1;
static int client = -1;          /* the current connection (server side) */
static int hold;                 /* 1: take data but do not acknowledge it yet */
static uint64_t held_frames;     /* frames taken while holding */
static uint64_t bytes_total;     /* payload bytes received on the current connection */
static uint32_t cfg_rate, cfg_channels, cfg_format;
static uint32_t epoch;
static int resets, last_play_out;
static int connections;
static unsigned char last_data[64];
static size_t last_len;

#define CHECK(cond, ...) \
    do { \
        if (!(cond)) { \
            fprintf(stderr, "FAIL %s:%d: %s: ", __FILE__, __LINE__, #cond); \
            fprintf(stderr, __VA_ARGS__); \
            fprintf(stderr, "\n"); \
            exit(1); \
        } \
    } while (0)

static int read_full(int fd, void *buf, size_t len)
{
    size_t n = 0;
    while (n < len) {
        ssize_t r = read(fd, (char *)buf + n, len - n);
        if (r <= 0)
            return -1;
        n += (size_t)r;
    }
    return 0;
}

static void send_msg(int fd, uint32_t type, uint32_t a, uint32_t b)
{
    struct msg m = { type, a, b, 1 };
    if (send(fd, &m, sizeof(m), MSG_NOSIGNAL) != (ssize_t)sizeof(m)) {
        /* the client went away: the reader notices */
    }
}

static unsigned frame_bytes(void)
{
    return (cfg_format == 0 ? 1 : cfg_format == 1 ? 2 : 4) * (cfg_channels ? cfg_channels : 1);
}

static void *server(void *arg)
{
    (void)arg;
    for (;;) {
        int fd = accept(listener, NULL, NULL);
        if (fd < 0)
            return NULL;
        pthread_mutex_lock(&lock);
        client = fd;
        bytes_total = 0;
        held_frames = 0;
        connections++;
        pthread_cond_broadcast(&cond);
        pthread_mutex_unlock(&lock);
        for (;;) {
            struct msg m;
            if (read_full(fd, &m, sizeof(m)) < 0)
                break;
            pthread_mutex_lock(&lock);
            if (m.type == 1) {
                cfg_rate = m.a;
                cfg_channels = m.b;
                cfg_format = m.c & 0xffff;
                send_msg(fd, 1, 0, 480);
            } else if (m.type == 2) {
                static unsigned char buf[1 << 20];
                pthread_mutex_unlock(&lock);
                if (m.a > sizeof(buf) || read_full(fd, buf, m.a) < 0)
                    break;
                pthread_mutex_lock(&lock);
                bytes_total += m.a;
                last_len = m.a < sizeof(last_data) ? m.a : sizeof(last_data);
                memcpy(last_data, buf, last_len);
                if (hold)
                    held_frames += m.a / frame_bytes();
                else
                    send_msg(fd, 2, epoch, m.a / frame_bytes());
            } else if (m.type == 3) {
                epoch = m.a;
                last_play_out = (int)m.b;
                resets++;
                held_frames = 0; /* dropped sound is never reported */
            }
            pthread_cond_broadcast(&cond);
            pthread_mutex_unlock(&lock);
        }
        pthread_mutex_lock(&lock);
        client = -1;
        pthread_cond_broadcast(&cond);
        pthread_mutex_unlock(&lock);
        close(fd);
    }
}

static void set_hold(int on)
{
    pthread_mutex_lock(&lock);
    hold = on;
    if (!on && held_frames && client >= 0) {
        send_msg(client, 2, epoch, (uint32_t)held_frames);
        held_frames = 0;
    }
    pthread_mutex_unlock(&lock);
}

/* Waits until the server has received `want` payload bytes on this connection. */
static void wait_bytes(uint64_t want)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += 5;
    pthread_mutex_lock(&lock);
    while (bytes_total < want) {
        if (pthread_cond_timedwait(&cond, &lock, &ts) == ETIMEDOUT)
            break;
    }
    CHECK(bytes_total == want, "server has %llu bytes, expected %llu", (unsigned long long)bytes_total,
          (unsigned long long)want);
    pthread_mutex_unlock(&lock);
}

static void wait_resets(int want)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += 5;
    pthread_mutex_lock(&lock);
    while (resets < want) {
        if (pthread_cond_timedwait(&cond, &lock, &ts) == ETIMEDOUT)
            break;
    }
    CHECK(resets >= want, "server saw %d resets, expected %d", resets, want);
    pthread_mutex_unlock(&lock);
}

static snd_pcm_t *open_pcm(snd_pcm_format_t format, unsigned channels, unsigned rate, snd_pcm_uframes_t buffer,
                           snd_pcm_uframes_t period, int mode)
{
    snd_pcm_t *pcm;
    snd_pcm_hw_params_t *hw;
    snd_pcm_uframes_t got;
    int err = snd_pcm_open(&pcm, "default", SND_PCM_STREAM_PLAYBACK, mode);

    CHECK(err == 0, "snd_pcm_open: %s", snd_strerror(err));
    snd_pcm_hw_params_alloca(&hw);
    CHECK((err = snd_pcm_hw_params_any(pcm, hw)) >= 0, "any: %s", snd_strerror(err));
    CHECK((err = snd_pcm_hw_params_set_access(pcm, hw, SND_PCM_ACCESS_RW_INTERLEAVED)) == 0, "access: %s", snd_strerror(err));
    CHECK((err = snd_pcm_hw_params_set_format(pcm, hw, format)) == 0, "format: %s", snd_strerror(err));
    CHECK((err = snd_pcm_hw_params_set_channels(pcm, hw, channels)) == 0, "channels: %s", snd_strerror(err));
    CHECK((err = snd_pcm_hw_params_set_rate(pcm, hw, rate, 0)) == 0, "rate: %s", snd_strerror(err));
    CHECK((err = snd_pcm_hw_params_set_period_size(pcm, hw, period, 0)) == 0, "period: %s", snd_strerror(err));
    CHECK((err = snd_pcm_hw_params_set_buffer_size(pcm, hw, buffer)) == 0, "buffer: %s", snd_strerror(err));
    CHECK((err = snd_pcm_hw_params(pcm, hw)) == 0, "hw_params: %s", snd_strerror(err));
    CHECK(snd_pcm_hw_params_get_buffer_size(hw, &got) == 0 && got == buffer, "buffer size %lu", got);
    CHECK((err = snd_pcm_prepare(pcm)) == 0, "prepare: %s", snd_strerror(err));
    return pcm;
}

int main(int argc, char **argv)
{
    char path[512], conf[512];
    struct sockaddr_un addr;
    pthread_t th;
    snd_pcm_t *pcm;
    snd_pcm_sframes_t n, delay;
    static int16_t s16[4800 * 2];
    FILE *f;
    int err, i, before;

    if (argc != 3) {
        fprintf(stderr, "usage: %s <plugin .so> <scratch dir>\n", argv[0]);
        return 2;
    }
    snprintf(path, sizeof(path), "%s/audio.sock", argv[2]);
    snprintf(conf, sizeof(conf), "%s/asound.conf", argv[2]);
    unlink(path);
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    CHECK(strlen(path) < sizeof(addr.sun_path), "scratch dir too long");
    strcpy(addr.sun_path, path);
    listener = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    CHECK(listener >= 0 && bind(listener, (struct sockaddr *)&addr, sizeof(addr)) == 0 && listen(listener, 4) == 0,
          "listen on %s: %s", path, strerror(errno));
    CHECK(pthread_create(&th, NULL, server, NULL) == 0, "thread");

    f = fopen(conf, "w");
    CHECK(f != NULL, "write %s", conf);
    fprintf(f, "pcm_type.pmbos {\n\tlib \"%s\"\n}\npcm.!default {\n\ttype pmbos\n\tsocket \"%s\"\n}\n", argv[1], path);
    fclose(f);
    setenv("ALSA_CONFIG_PATH", conf, 1);
    unsetenv("PMBOS_AUDIO_SOCKET");

    /* ---- no microphone */
    err = snd_pcm_open(&pcm, "default", SND_PCM_STREAM_CAPTURE, 0);
    CHECK(err < 0, "a capture stream opened");

    /* ---- buffer accounting: nothing acknowledged = nothing played */
    pcm = open_pcm(SND_PCM_FORMAT_S16_LE, 2, 48000, 4800, 480, SND_PCM_NONBLOCK);
    CHECK(cfg_rate == 48000 && cfg_channels == 2 && cfg_format == 1, "config %u %u %u", cfg_rate, cfg_channels, cfg_format);
    for (i = 0; i < 4800 * 2; i++)
        s16[i] = (int16_t)(i * 7);
    CHECK((n = snd_pcm_avail_update(pcm)) == 4800, "avail before writing: %ld", (long)n);
    set_hold(1);
    for (i = 0; i < 10; i++) {
        n = snd_pcm_writei(pcm, s16 + i * 960, 480);
        CHECK(n == 480, "write %d: %ld", i, (long)n);
    }
    wait_bytes(4800 * 4);
    CHECK((n = snd_pcm_avail_update(pcm)) == 0, "avail with a full buffer: %ld", (long)n);
    CHECK((n = snd_pcm_writei(pcm, s16, 480)) == -EAGAIN, "write into a full buffer: %ld", (long)n);
    CHECK(snd_pcm_delay(pcm, &delay) == 0 && delay == 4800 + 480, "delay %ld", (long)delay);
    CHECK(snd_pcm_wait(pcm, 50) == 0, "poll reports room in a full buffer");
    CHECK(snd_pcm_state(pcm) == SND_PCM_STATE_RUNNING, "state %s", snd_pcm_state_name(snd_pcm_state(pcm)));

    /* ---- the server takes everything: poll wakes up, the buffer is empty, and that is no xrun */
    set_hold(0);
    CHECK((err = snd_pcm_wait(pcm, 2000)) == 1, "poll after the server took the sound: %d", err);
    CHECK((n = snd_pcm_avail_update(pcm)) == 4800, "avail after the server took everything: %ld", (long)n);
    CHECK(snd_pcm_delay(pcm, &delay) == 0 && delay == 480, "delay of an empty buffer %ld", (long)delay);
    CHECK(snd_pcm_state(pcm) == SND_PCM_STATE_RUNNING, "state %s", snd_pcm_state_name(snd_pcm_state(pcm)));

    /* ---- a whole buffer between two looks at the pointer (the wrap-around ambiguity) */
    for (i = 0; i < 10; i++)
        CHECK((n = snd_pcm_writei(pcm, s16 + i * 960, 480)) == 480, "refill %d: %ld", i, (long)n);
    wait_bytes(2 * 4800 * 4);
    usleep(20000);
    CHECK((n = snd_pcm_avail_update(pcm)) == 4800, "avail after a whole buffer went through: %ld", (long)n);

    /* ---- rewind: frames taken back and written again are not sent twice */
    set_hold(1);
    CHECK((n = snd_pcm_writei(pcm, s16, 960)) == 960, "write: %ld", (long)n);
    wait_bytes((2 * 4800 + 960) * 4);
    CHECK((n = snd_pcm_rewind(pcm, 480)) == 480, "rewind: %ld", (long)n);
    CHECK((n = snd_pcm_avail_update(pcm)) == 4800 - 480, "avail after rewind: %ld", (long)n);
    CHECK((n = snd_pcm_writei(pcm, s16 + 960, 480)) == 480, "rewrite: %ld", (long)n);
    CHECK((n = snd_pcm_writei(pcm, s16, 480)) == 480, "write after rewrite: %ld", (long)n);
    wait_bytes((2 * 4800 + 960 + 480) * 4);
    usleep(20000);
    wait_bytes((2 * 4800 + 960 + 480) * 4);
    CHECK((n = snd_pcm_avail_update(pcm)) == 4800 - 1440, "avail after rewrite: %ld", (long)n);
    set_hold(0);
    CHECK(snd_pcm_wait(pcm, 2000) == 1, "poll");
    CHECK((n = snd_pcm_avail_update(pcm)) == 4800, "avail at the end of the rewind test: %ld", (long)n);

    /* ---- drop silences the device; the stream starts again from zero */
    set_hold(1);
    CHECK((n = snd_pcm_writei(pcm, s16, 480)) == 480, "write: %ld", (long)n);
    before = resets;
    CHECK((err = snd_pcm_drop(pcm)) == 0, "drop: %s", snd_strerror(err));
    wait_resets(before + 1);
    CHECK(last_play_out == 0, "drop must not let the sound play out");
    set_hold(0);
    CHECK((err = snd_pcm_prepare(pcm)) == 0, "prepare: %s", snd_strerror(err));
    CHECK((n = snd_pcm_avail_update(pcm)) == 4800, "avail after drop + prepare: %ld", (long)n);
    CHECK((n = snd_pcm_writei(pcm, s16, 480)) == 480, "write after prepare: %ld", (long)n);
    CHECK(snd_pcm_wait(pcm, 2000) == 1, "poll");
    usleep(20000);
    CHECK((n = snd_pcm_avail_update(pcm)) == 4800, "avail after the first write of the new epoch: %ld", (long)n);

    /* ---- drain waits for the server and lets the device play out */
    CHECK(snd_pcm_nonblock(pcm, 0) == 0, "blocking mode");
    CHECK((n = snd_pcm_writei(pcm, s16, 960)) == 960, "write: %ld", (long)n);
    before = resets;
    CHECK((err = snd_pcm_drain(pcm)) == 0, "drain: %s", snd_strerror(err));
    wait_resets(before + 1);
    CHECK(last_play_out == 1, "drain must let the sound play out");
    CHECK((err = snd_pcm_close(pcm)) == 0, "close: %s", snd_strerror(err));

    /* ---- 24-bit samples reach the server as floats; blocking writes larger than the buffer */
    {
        static unsigned char s24[9600 * 3];
        float got[2];
        for (i = 0; i < 9600; i++) {
            int32_t v = (i & 1) ? -0x200000 : 0x400000; /* -0.25, 0.5 */
            s24[i * 3] = (unsigned char)v;
            s24[i * 3 + 1] = (unsigned char)(v >> 8);
            s24[i * 3 + 2] = (unsigned char)(v >> 16);
        }
        pcm = open_pcm(SND_PCM_FORMAT_S24_3LE, 1, 44100, 4410, 441, 0);
        CHECK(cfg_rate == 44100 && cfg_channels == 1 && cfg_format == 2, "config %u %u %u", cfg_rate, cfg_channels, cfg_format);
        CHECK((n = snd_pcm_writei(pcm, s24, 9600)) == 9600, "blocking write of two buffers: %ld", (long)n);
        wait_bytes(9600 * 4);
        pthread_mutex_lock(&lock);
        memcpy(got, last_data, sizeof(got));
        pthread_mutex_unlock(&lock);
        /* a chunk starts at an even or an odd sample */
        CHECK((got[0] == 0.5f && got[1] == -0.25f) || (got[0] == -0.25f && got[1] == 0.5f), "converted samples %f %f",
              got[0], got[1]);

        /* ---- the server vanishes: errors, no hang */
        pthread_mutex_lock(&lock);
        if (client >= 0)
            shutdown(client, SHUT_RDWR);
        pthread_mutex_unlock(&lock);
        for (i = 0; i < 50; i++) {
            n = snd_pcm_writei(pcm, s24, 441);
            if (n < 0)
                break;
            usleep(10000);
        }
        CHECK(n < 0, "writes keep succeeding without a server");
        snd_pcm_close(pcm);
    }

    /* ---- the socket named by the environment, abstract namespace */
    {
        int l2 = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0), old = listener;
        char name[64];
        socklen_t len;

        snprintf(name, sizeof(name), "pmbaudio-test-%d", (int)getpid());
        memset(&addr, 0, sizeof(addr));
        addr.sun_family = AF_UNIX;
        memcpy(addr.sun_path + 1, name, strlen(name));
        len = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + strlen(name));
        CHECK(l2 >= 0 && bind(l2, (struct sockaddr *)&addr, len) == 0 && listen(l2, 4) == 0, "abstract socket: %s", strerror(errno));
        listener = l2;
        shutdown(old, SHUT_RDWR); /* the server thread's accept fails and it ends */
        close(old);
        pthread_join(th, NULL);
        CHECK(pthread_create(&th, NULL, server, NULL) == 0, "thread");

        f = fopen(conf, "w");
        CHECK(f != NULL, "write %s", conf);
        fprintf(f, "pcm_type.pmbos {\n\tlib \"%s\"\n}\npcm.!default {\n\ttype pmbos\n}\n", argv[1]);
        fclose(f);
        snd_config_update_free_global();
        err = snd_pcm_open(&pcm, "default", SND_PCM_STREAM_PLAYBACK, 0);
        CHECK(err < 0, "opened without any socket name");
        snprintf(path, sizeof(path), "@%s", name);
        setenv("PMBOS_AUDIO_SOCKET", path, 1);
        before = connections;
        pcm = open_pcm(SND_PCM_FORMAT_FLOAT_LE, 2, 48000, 4800, 480, 0);
        CHECK(connections == before + 1 && cfg_format == 2, "abstract connection");
        snd_pcm_close(pcm);
    }

    unlink(conf);
    snprintf(path, sizeof(path), "%s/audio.sock", argv[2]);
    unlink(path);
    printf("pmbaudio self-test OK\n");
    return 0;
}
