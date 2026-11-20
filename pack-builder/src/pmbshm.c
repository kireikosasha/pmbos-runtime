/*
 * libpmbshm.so - System V shared memory emulation for PMB OS.
 *
 * Android kernels are built without CONFIG_SYSVIPC (and app seccomp policies may kill a
 * process that issues the raw syscalls), but X11 clients (wine's winex11.drv XShm path,
 * Mesa's software WSI, libXext) rely on shmget/shmat/shmdt/shmctl for MIT-SHM.
 * This LD_PRELOAD library (arm64 glibc, installed at <imagefs>/usr/lib/libpmbshm.so)
 * implements those four calls over plain files.
 *
 * SYSV-SHM EMULATION CONTRACT (shared with the PMB OS X server, see
 * pmbos/docs/subsystems/packbuilder.md):
 *   - Directory: $PMBOS_SHM_DIR (absolute path; the Windows launcher sets it to
 *     <imagefs>/tmp/pmbshm). If it is unset/empty/relative every call is forwarded to the
 *     real libc implementation (real syscalls).
 *   - Segment with shmid N is the regular file "$PMBOS_SHM_DIR/N" (decimal), the segment
 *     size is the file size, attachments are MAP_SHARED mappings of that file.
 *   - IPC_PRIVATE allocates a fresh id from the counter file "$PMBOS_SHM_DIR/.next"
 *     (decimal text) while holding flock(LOCK_EX) on it.
 *   - A keyed segment additionally has the symlink "key-<8 lowercase hex digits>" -> "N".
 *   - IPC_RMID removes the key symlink immediately and unlinks the segment file. Existing
 *     mappings stay valid. If the calling process still has the segment attached, the
 *     unlink is deferred until its last local shmdt() (or process exit) - this matches
 *     SysV "destroy after last detach" semantics and keeps the file openable by the X
 *     server for clients that call IPC_RMID before the server processed ShmAttach.
 *   - The X server's MIT-SHM ShmAttach(shmseg, shmid, readOnly) opens "$PMBOS_SHM_DIR/<shmid>"
 *     and mmaps it synchronously while processing the request.
 *
 * Thread-safety: the attachment table is protected by a mutex (fork-safe via
 * pthread_atfork); id allocation and key bookkeeping are serialized across threads and
 * processes with flock() on ".next" (each call opens its own file description).
 *
 * Limitations (documented): shm_nattch / shm_lpid reported by IPC_STAT are process-local,
 * SHM_STAT treats its index argument as a shmid, SHM_LOCK/SHM_UNLOCK are no-ops.
 *
 * Build: gcc -O2 -fPIC -shared -fvisibility=hidden -D_GNU_SOURCE -o libpmbshm.so pmbshm.c -ldl -lpthread
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <sys/types.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/syscall.h>
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* ---------------------------------------------------------------------------------------
 * libc compatibility. The production target is aarch64 glibc. Bionic (Android) is only
 * supported for compile checks with the NDK: before API 26 it does not declare the SysV
 * shm functions at all.
 * ------------------------------------------------------------------------------------- */
#if defined(__ANDROID__) && (!defined(__ANDROID_API__) || __ANDROID_API__ < 26)
void *shmat(int shmid, const void *shmaddr, int shmflg);
int shmctl(int shmid, int cmd, struct shmid_ds *buf);
int shmdt(const void *shmaddr);
int shmget(key_t key, size_t size, int shmflg);
#endif

#ifndef SHM_RDONLY
#define SHM_RDONLY 010000
#endif
#ifndef SHM_RND
#define SHM_RND 020000
#endif
#ifndef SHM_REMAP
#define SHM_REMAP 040000
#endif
#ifndef SHM_EXEC
#define SHM_EXEC 0100000
#endif
#ifndef SHM_DEST
#define SHM_DEST 01000
#endif
#ifndef SHM_LOCK
#define SHM_LOCK 11
#endif
#ifndef SHM_UNLOCK
#define SHM_UNLOCK 12
#endif
#ifndef SHM_STAT
#define SHM_STAT 13
#endif
#ifndef SHM_INFO
#define SHM_INFO 14
#endif
#ifndef SHM_STAT_ANY
#define SHM_STAT_ANY 15
#endif
#ifndef IPC_INFO
#define IPC_INFO 3
#endif
#ifndef MAP_FIXED_NOREPLACE
#define MAP_FIXED_NOREPLACE 0x100000 /* Linux >= 4.17; older kernels treat it as a hint */
#endif
#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif

#define PMBSHM_EXPORT __attribute__((visibility("default")))
#define PMBSHM_IPC_64 0x100            /* glibc may or may not OR this into cmd */
#define PMBSHM_MAX_ALLOC_TRIES 65536    /* ids probed while looking for a free one */
#define PMBSHM_PERM_MASK 0777
#define PMBSHM_OWNER_RW 0600            /* the X server (same uid) must be able to open */

/* struct shminfo / shm_info (IPC_INFO / SHM_INFO): glibc layout only (bionic's uapi
 * struct shminfo has int fields; bionic is a compile-check target, not a runtime one). */
#if defined(__GLIBC__)
#define PMBSHM_HAVE_INFO_STRUCTS 1
#endif

/* ---------------------------------------------------------------------------------------
 * Configuration (read once)
 * ------------------------------------------------------------------------------------- */
static pthread_once_t g_once = PTHREAD_ONCE_INIT;
/* PATH_MAX - 512, not PATH_MAX: every "<g_dir>/<suffix>" (suffix <= "/" + 255-byte d_name)
 * then provably fits a PATH_MAX buffer, which GCC's -Wformat-truncation (-Wall, -Werror in
 * stage-pmbshm.sh) requires; init_once rejects longer PMBOS_SHM_DIR values. */
static char g_dir[PATH_MAX - 512];
static int g_enabled;
static long g_pagesize = 4096;

typedef void *(*shmat_fn)(int, const void *, int);
typedef int (*shmctl_fn)(int, int, struct shmid_ds *);
typedef int (*shmdt_fn)(const void *);
typedef int (*shmget_fn)(key_t, size_t, int);

static shmat_fn real_shmat;
static shmctl_fn real_shmctl;
static shmdt_fn real_shmdt;
static shmget_fn real_shmget;

static void init_once(void) {
    long ps = sysconf(_SC_PAGESIZE);
    if (ps > 0) g_pagesize = ps;

    const char *dir = getenv("PMBOS_SHM_DIR");
    if (dir && dir[0] == '/') {
        size_t n = strlen(dir);
        while (n > 1 && dir[n - 1] == '/') n--; /* strip trailing slashes */
        /* room for "/key-xxxxxxxx" and "/<int>" suffixes */
        if (n + 32 < sizeof(g_dir)) {
            memcpy(g_dir, dir, n);
            g_dir[n] = '\0';
            g_enabled = 1;
        }
    }
    if (!g_enabled) {
        real_shmat = (shmat_fn)dlsym(RTLD_NEXT, "shmat");
        real_shmctl = (shmctl_fn)dlsym(RTLD_NEXT, "shmctl");
        real_shmdt = (shmdt_fn)dlsym(RTLD_NEXT, "shmdt");
        real_shmget = (shmget_fn)dlsym(RTLD_NEXT, "shmget");
    }
}

static int enabled(void) {
    pthread_once(&g_once, init_once);
    return g_enabled;
}

/* ---------------------------------------------------------------------------------------
 * Process-local attachment table
 * ------------------------------------------------------------------------------------- */
typedef struct {
    uintptr_t addr;
    size_t len;
    int id;
} attachment_t;

typedef struct {
    int id;
    pid_t owner; /* process that issued IPC_RMID; only it performs the deferred unlink */
} pending_t;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static attachment_t *g_att;
static size_t g_att_len, g_att_cap;
static pending_t *g_pend;
static size_t g_pend_len, g_pend_cap;

static void atfork_prepare(void) { pthread_mutex_lock(&g_lock); }
static void atfork_parent(void) { pthread_mutex_unlock(&g_lock); }
static void atfork_child(void) { pthread_mutex_unlock(&g_lock); }

static void path_of_id(char *out, size_t cap, int id) {
    snprintf(out, cap, "%s/%d", g_dir, id);
}

static void path_of_key(char *out, size_t cap, key_t key) {
    snprintf(out, cap, "%s/key-%08x", g_dir, (unsigned int)key);
}

/* called with g_lock held */
static int local_attach_count(int id) {
    int n = 0;
    for (size_t i = 0; i < g_att_len; i++)
        if (g_att[i].id == id) n++;
    return n;
}

/* called with g_lock held; returns index or -1 */
static long pending_index(int id) {
    for (size_t i = 0; i < g_pend_len; i++)
        if (g_pend[i].id == id) return (long)i;
    return -1;
}

static int grow(void **arr, size_t *cap, size_t elem) {
    size_t ncap = *cap ? *cap * 2 : 16;
    void *n = realloc(*arr, ncap * elem);
    if (!n) return -1;
    *arr = n;
    *cap = ncap;
    return 0;
}

__attribute__((constructor)) static void pmbshm_ctor(void) {
    pthread_atfork(atfork_prepare, atfork_parent, atfork_child);
}

/* Deferred IPC_RMID unlinks that are still outstanding when the process exits. */
__attribute__((destructor)) static void pmbshm_dtor(void) {
    if (!g_enabled) return;
    pid_t self = getpid();
    char path[PATH_MAX];
    pthread_mutex_lock(&g_lock);
    for (size_t i = 0; i < g_pend_len; i++) {
        if (g_pend[i].owner == self) {
            path_of_id(path, sizeof(path), g_pend[i].id);
            unlink(path);
        }
    }
    g_pend_len = 0;
    pthread_mutex_unlock(&g_lock);
}

/* ---------------------------------------------------------------------------------------
 * Cross-process lock + id allocation
 * ------------------------------------------------------------------------------------- */
static int ensure_dir(void) {
    if (mkdir(g_dir, 0700) == 0 || errno == EEXIST) return 0;
    return -1;
}

/* Opens and exclusively flocks "<dir>/.next". Returns fd or -1 (errno set). */
static int lock_counter(void) {
    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/.next", g_dir);
    int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (fd < 0 && errno == ENOENT) {
        if (ensure_dir() != 0) return -1;
        fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    }
    if (fd < 0) return -1;
    while (flock(fd, LOCK_EX) != 0) {
        if (errno != EINTR) {
            int e = errno;
            close(fd);
            errno = e;
            return -1;
        }
    }
    return fd;
}

static void unlock_counter(int fd) {
    int e = errno;
    flock(fd, LOCK_UN);
    close(fd);
    errno = e;
}

static int parse_id(const char *s, size_t n) {
    long v = 0;
    size_t i = 0;
    while (i < n && (s[i] == ' ' || s[i] == '\n' || s[i] == '\t' || s[i] == '\r')) i++;
    if (i >= n || s[i] < '0' || s[i] > '9') return -1;
    for (; i < n && s[i] >= '0' && s[i] <= '9'; i++) {
        v = v * 10 + (s[i] - '0');
        if (v > INT_MAX) return -1;
    }
    return (int)v;
}

/*
 * Allocates a new segment file of the given size while the counter lock (lockfd) is held.
 * Returns the new id or -1 (errno set).
 */
static int create_segment(int lockfd, size_t size, int mode) {
    char buf[32];
    ssize_t r = pread(lockfd, buf, sizeof(buf) - 1, 0);
    int next = (r > 0) ? parse_id(buf, (size_t)r) : -1;
    if (next <= 0) next = 1;

    char path[PATH_MAX];
    int id = -1, fd = -1;
    for (int tries = 0; tries < PMBSHM_MAX_ALLOC_TRIES; tries++) {
        int cand = next;
        next = (next >= INT_MAX) ? 1 : next + 1;
        path_of_id(path, sizeof(path), cand);
        fd = open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, PMBSHM_OWNER_RW);
        if (fd >= 0) {
            id = cand;
            break;
        }
        if (errno != EEXIST) return -1;
    }
    if (id < 0) {
        errno = ENOSPC;
        return -1;
    }
    if (ftruncate(fd, (off_t)size) != 0) {
        int e = (errno == EFBIG || errno == EINVAL) ? EINVAL : ENOMEM;
        close(fd);
        unlink(path);
        errno = e;
        return -1;
    }
    /* Reserve the blocks now: a sparse file lets shmget/shmat succeed on a nearly full
     * filesystem and the client then dies with SIGBUS on its first write fault. Filesystems
     * without fallocate keep the sparse ftruncate'd file (EOPNOTSUPP/EINVAL ignored). */
    if (size > 0) {
        int fr;
        do {
            fr = posix_fallocate(fd, 0, (off_t)size);
        } while (fr == EINTR);
        if (fr != 0 && fr != EOPNOTSUPP && fr != EINVAL) {
            close(fd);
            unlink(path);
            errno = (fr == ENOSPC) ? ENOSPC : ENOMEM;
            return -1;
        }
    }
    /* exact permissions (open() is subject to umask); owner rw is always kept */
    fchmod(fd, (mode_t)((mode & PMBSHM_PERM_MASK) | PMBSHM_OWNER_RW));
    close(fd);

    int len = snprintf(buf, sizeof(buf), "%d\n", next);
    if (pwrite(lockfd, buf, (size_t)len, 0) == len) {
        if (ftruncate(lockfd, len) != 0) { /* stale tail is harmless: parse stops at '\n' */ }
    }
    return id;
}

/* Removes every "key-*" symlink pointing at id. Caller holds the counter lock. */
static void remove_key_links(int id) {
    DIR *d = opendir(g_dir);
    if (!d) return;
    char want[16];
    int wl = snprintf(want, sizeof(want), "%d", id);
    char path[PATH_MAX], target[32];
    struct dirent *de;
    while ((de = readdir(d)) != NULL) {
        if (strncmp(de->d_name, "key-", 4) != 0) continue;
        snprintf(path, sizeof(path), "%s/%s", g_dir, de->d_name);
        ssize_t n = readlink(path, target, sizeof(target) - 1);
        if (n == wl && memcmp(target, want, (size_t)wl) == 0) unlink(path);
    }
    closedir(d);
}

/* Finds the key of a keyed segment (IPC_PRIVATE if none). Caller holds the counter lock. */
static key_t find_key_of(int id) {
    DIR *d = opendir(g_dir);
    if (!d) return IPC_PRIVATE;
    char want[16];
    int wl = snprintf(want, sizeof(want), "%d", id);
    char path[PATH_MAX], target[32];
    key_t key = IPC_PRIVATE;
    struct dirent *de;
    while ((de = readdir(d)) != NULL) {
        if (strncmp(de->d_name, "key-", 4) != 0 || strlen(de->d_name) != 12) continue;
        snprintf(path, sizeof(path), "%s/%s", g_dir, de->d_name);
        ssize_t n = readlink(path, target, sizeof(target) - 1);
        if (n == wl && memcmp(target, want, (size_t)wl) == 0) {
            key = (key_t)(unsigned int)strtoul(de->d_name + 4, NULL, 16);
            break;
        }
    }
    closedir(d);
    return key;
}

/* ---------------------------------------------------------------------------------------
 * shmget
 * ------------------------------------------------------------------------------------- */
PMBSHM_EXPORT int shmget(key_t key, size_t size, int shmflg) {
    if (!enabled()) {
        if (real_shmget) return real_shmget(key, size, shmflg);
#ifdef SYS_shmget
        return (int)syscall(SYS_shmget, key, size, shmflg);
#else
        errno = ENOSYS;
        return -1;
#endif
    }
    if (size > (size_t)INT64_MAX) {
        errno = EINVAL;
        return -1;
    }

    int lockfd = lock_counter();
    if (lockfd < 0) return -1;

    int id;
    if (key == IPC_PRIVATE) {
        if (size == 0) {
            errno = EINVAL;
            id = -1;
        } else {
            id = create_segment(lockfd, size, shmflg);
        }
        unlock_counter(lockfd);
        return id;
    }

    char link[PATH_MAX], path[PATH_MAX], target[32];
    path_of_key(link, sizeof(link), key);
    ssize_t n = readlink(link, target, sizeof(target) - 1);
    id = (n > 0) ? parse_id(target, (size_t)n) : -1;
    if (id > 0) {
        struct stat st;
        path_of_id(path, sizeof(path), id);
        if (stat(path, &st) != 0) {
            unlink(link); /* stale key: its segment was removed */
            id = -1;
        } else if ((shmflg & IPC_CREAT) && (shmflg & IPC_EXCL)) {
            unlock_counter(lockfd);
            errno = EEXIST;
            return -1;
        } else if ((off_t)size > st.st_size) {
            unlock_counter(lockfd);
            errno = EINVAL;
            return -1;
        } else {
            unlock_counter(lockfd);
            return id;
        }
    } else if (n > 0) {
        unlink(link); /* garbage link */
    }

    if (!(shmflg & IPC_CREAT)) {
        unlock_counter(lockfd);
        errno = ENOENT;
        return -1;
    }
    if (size == 0) {
        unlock_counter(lockfd);
        errno = EINVAL;
        return -1;
    }
    id = create_segment(lockfd, size, shmflg);
    if (id > 0) {
        char idstr[16];
        snprintf(idstr, sizeof(idstr), "%d", id);
        if (symlink(idstr, link) != 0) {
            int e = errno;
            path_of_id(path, sizeof(path), id);
            unlink(path);
            id = -1;
            errno = e;
        }
    }
    unlock_counter(lockfd);
    return id;
}

/* ---------------------------------------------------------------------------------------
 * shmat
 * ------------------------------------------------------------------------------------- */
PMBSHM_EXPORT void *shmat(int shmid, const void *shmaddr, int shmflg) {
    if (!enabled()) {
        if (real_shmat) return real_shmat(shmid, shmaddr, shmflg);
        errno = ENOSYS;
        return (void *)-1;
    }
    if (shmid <= 0) {
        errno = EINVAL;
        return (void *)-1;
    }

    const int rdonly = (shmflg & SHM_RDONLY) != 0;
    char path[PATH_MAX];
    path_of_id(path, sizeof(path), shmid);
    int fd = open(path, (rdonly ? O_RDONLY : O_RDWR) | O_CLOEXEC);
    if (fd < 0) {
        if (errno == ENOENT || errno == ENOTDIR) errno = EINVAL;
        return (void *)-1;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size <= 0) {
        close(fd);
        errno = EINVAL;
        return (void *)-1;
    }
    size_t len = (size_t)st.st_size;

    int prot = PROT_READ | (rdonly ? 0 : PROT_WRITE) | ((shmflg & SHM_EXEC) ? PROT_EXEC : 0);
    int flags = MAP_SHARED;
    uintptr_t want = (uintptr_t)shmaddr;
    if (want) {
        if (shmflg & SHM_RND) {
            want &= ~((uintptr_t)g_pagesize - 1);
        } else if (want & ((uintptr_t)g_pagesize - 1)) {
            close(fd);
            errno = EINVAL;
            return (void *)-1;
        }
        flags |= (shmflg & SHM_REMAP) ? MAP_FIXED : MAP_FIXED_NOREPLACE;
    }

    void *p = mmap((void *)want, len, prot, flags, fd, 0);
    int e = errno;
    close(fd);
    if (p == MAP_FAILED) {
        errno = (e == EEXIST) ? EINVAL : e;
        return (void *)-1;
    }
    if (want && (uintptr_t)p != want) {
        /* pre-4.17 kernel ignored MAP_FIXED_NOREPLACE and picked another address */
        munmap(p, len);
        errno = EINVAL;
        return (void *)-1;
    }

    pthread_mutex_lock(&g_lock);
    if (g_att_len == g_att_cap && grow((void **)&g_att, &g_att_cap, sizeof(*g_att)) != 0) {
        pthread_mutex_unlock(&g_lock);
        munmap(p, len);
        errno = ENOMEM;
        return (void *)-1;
    }
    /* SHM_REMAP may have replaced an older attachment in that range: drop stale entries */
    if (want && (shmflg & SHM_REMAP)) {
        for (size_t i = 0; i < g_att_len;) {
            if (g_att[i].addr < want + len && want < g_att[i].addr + g_att[i].len) {
                g_att[i] = g_att[--g_att_len];
            } else {
                i++;
            }
        }
    }
    g_att[g_att_len].addr = (uintptr_t)p;
    g_att[g_att_len].len = len;
    g_att[g_att_len].id = shmid;
    g_att_len++;
    pthread_mutex_unlock(&g_lock);
    return p;
}

/* ---------------------------------------------------------------------------------------
 * shmdt
 * ------------------------------------------------------------------------------------- */
PMBSHM_EXPORT int shmdt(const void *shmaddr) {
    if (!enabled()) {
        if (real_shmdt) return real_shmdt(shmaddr);
        errno = ENOSYS;
        return -1;
    }
    uintptr_t a = (uintptr_t)shmaddr;
    int unlink_id = -1;

    pthread_mutex_lock(&g_lock);
    size_t i;
    for (i = 0; i < g_att_len; i++)
        if (g_att[i].addr == a) break;
    if (i == g_att_len) {
        pthread_mutex_unlock(&g_lock);
        errno = EINVAL;
        return -1;
    }
    attachment_t at = g_att[i];
    g_att[i] = g_att[--g_att_len];
    munmap((void *)at.addr, at.len);
    if (local_attach_count(at.id) == 0) {
        long pi = pending_index(at.id);
        if (pi >= 0 && g_pend[pi].owner == getpid()) {
            g_pend[pi] = g_pend[--g_pend_len];
            unlink_id = at.id;
        }
    }
    pthread_mutex_unlock(&g_lock);

    if (unlink_id > 0) {
        char path[PATH_MAX];
        path_of_id(path, sizeof(path), unlink_id);
        unlink(path);
    }
    return 0;
}

/* ---------------------------------------------------------------------------------------
 * shmctl
 * ------------------------------------------------------------------------------------- */
static int do_stat(int shmid, struct shmid_ds *buf) {
    if (!buf) {
        errno = EFAULT;
        return -1;
    }
    char path[PATH_MAX];
    path_of_id(path, sizeof(path), shmid);
    struct stat st;
    if (stat(path, &st) != 0) {
        errno = EINVAL;
        return -1;
    }
    key_t key = IPC_PRIVATE;
    int lockfd = lock_counter();
    if (lockfd >= 0) {
        key = find_key_of(shmid);
        unlock_counter(lockfd);
    }

    int nattch, dest;
    pthread_mutex_lock(&g_lock);
    nattch = local_attach_count(shmid);
    dest = pending_index(shmid) >= 0;
    pthread_mutex_unlock(&g_lock);

    memset(buf, 0, sizeof(*buf));
    buf->shm_perm.__key = key;
    buf->shm_perm.uid = st.st_uid;
    buf->shm_perm.gid = st.st_gid;
    buf->shm_perm.cuid = st.st_uid;
    buf->shm_perm.cgid = st.st_gid;
    buf->shm_perm.mode = (st.st_mode & PMBSHM_PERM_MASK) | (dest ? SHM_DEST : 0);
    buf->shm_segsz = (size_t)st.st_size;
    buf->shm_atime = st.st_atime;
    buf->shm_dtime = 0;
    buf->shm_ctime = st.st_ctime;
    buf->shm_cpid = 0;
    buf->shm_lpid = nattch ? getpid() : 0;
    buf->shm_nattch = (shmatt_t)nattch;
    return 0;
}

static int do_rmid(int shmid) {
    char path[PATH_MAX];
    path_of_id(path, sizeof(path), shmid);

    int lockfd = lock_counter();
    if (lockfd < 0) return -1;
    struct stat st;
    if (stat(path, &st) != 0) {
        unlock_counter(lockfd);
        errno = EINVAL;
        return -1;
    }
    remove_key_links(shmid);

    int defer = 0;
    pthread_mutex_lock(&g_lock);
    if (local_attach_count(shmid) > 0) {
        if (pending_index(shmid) >= 0) {
            defer = 1;
        } else if (g_pend_len < g_pend_cap || grow((void **)&g_pend, &g_pend_cap, sizeof(*g_pend)) == 0) {
            g_pend[g_pend_len].id = shmid;
            g_pend[g_pend_len].owner = getpid();
            g_pend_len++;
            defer = 1;
        } /* else: out of memory -> unlink right away (mappings stay valid anyway) */
    }
    pthread_mutex_unlock(&g_lock);

    if (!defer) unlink(path);
    unlock_counter(lockfd);
    return 0;
}

#ifdef PMBSHM_HAVE_INFO_STRUCTS
static int count_segments(unsigned long *ids, unsigned long *pages) {
    DIR *d = opendir(g_dir);
    if (!d) return -1;
    char path[PATH_MAX];
    struct dirent *de;
    *ids = 0;
    *pages = 0;
    while ((de = readdir(d)) != NULL) {
        if (parse_id(de->d_name, strlen(de->d_name)) <= 0) continue;
        snprintf(path, sizeof(path), "%s/%s", g_dir, de->d_name);
        struct stat st;
        if (lstat(path, &st) == 0 && S_ISREG(st.st_mode)) {
            (*ids)++;
            *pages += (unsigned long)((st.st_size + g_pagesize - 1) / g_pagesize);
        }
    }
    closedir(d);
    return 0;
}
#endif

PMBSHM_EXPORT int shmctl(int shmid, int cmd, struct shmid_ds *buf) {
    if (!enabled()) {
        if (real_shmctl) return real_shmctl(shmid, cmd, buf);
        errno = ENOSYS;
        return -1;
    }
    cmd &= ~PMBSHM_IPC_64;

    switch (cmd) {
    case IPC_STAT:
        return do_stat(shmid, buf);
    case SHM_STAT:
    case SHM_STAT_ANY:
        /* the "index" is interpreted as a shmid; success returns the id */
        return do_stat(shmid, buf) == 0 ? shmid : -1;
    case IPC_SET: {
        if (!buf) {
            errno = EFAULT;
            return -1;
        }
        char path[PATH_MAX];
        path_of_id(path, sizeof(path), shmid);
        struct stat st;
        if (stat(path, &st) != 0) {
            errno = EINVAL;
            return -1;
        }
        if (buf->shm_perm.uid != st.st_uid || buf->shm_perm.gid != st.st_gid) {
            errno = EPERM; /* ownership cannot be transferred on Android app storage */
            return -1;
        }
        if (chmod(path, (mode_t)((buf->shm_perm.mode & PMBSHM_PERM_MASK) | PMBSHM_OWNER_RW)) != 0) {
            errno = EPERM;
            return -1;
        }
        return 0;
    }
    case IPC_RMID:
        return do_rmid(shmid);
    case SHM_LOCK:
    case SHM_UNLOCK: {
        char path[PATH_MAX];
        path_of_id(path, sizeof(path), shmid);
        if (access(path, F_OK) != 0) {
            errno = EINVAL;
            return -1;
        }
        return 0;
    }
#ifdef PMBSHM_HAVE_INFO_STRUCTS
    case IPC_INFO: {
        if (!buf) {
            errno = EFAULT;
            return -1;
        }
        struct shminfo *info = (struct shminfo *)(void *)buf;
        memset(info, 0, sizeof(*info));
        info->shmmax = (unsigned long)(SIZE_MAX / 2);
        info->shmmin = 1;
        info->shmmni = 4096;
        info->shmseg = 4096;
        info->shmall = (unsigned long)(SIZE_MAX / 2) / (unsigned long)g_pagesize;
        return 0;
    }
    case SHM_INFO: {
        if (!buf) {
            errno = EFAULT;
            return -1;
        }
        unsigned long ids = 0, pages = 0;
        if (count_segments(&ids, &pages) != 0) {
            errno = EINVAL;
            return -1;
        }
        struct shm_info *info = (struct shm_info *)(void *)buf;
        memset(info, 0, sizeof(*info));
        info->used_ids = (int)ids;
        info->shm_tot = pages;
        info->shm_rss = pages;
        return 0;
    }
#endif
    default:
        errno = EINVAL;
        return -1;
    }
}
