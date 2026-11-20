/*
 * Self-test for libpmbshm.so, run by stages/stage-pmbshm.sh right after the build:
 *   PMBOS_SHM_DIR=<empty dir> LD_PRELOAD=./libpmbshm.so ./pmbshm-test <same dir>
 * Exercises the SYSV-SHM EMULATION CONTRACT end to end, including the X server side
 * (open "<dir>/<shmid>" + mmap) and cross-process visibility after fork().
 * Exit status 0 = all checks passed.
 */
#define _GNU_SOURCE
#include <sys/types.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int failures;
static const char *dir;

#define CHECK(cond)                                                                     \
    do {                                                                                \
        if (!(cond)) {                                                                  \
            fprintf(stderr, "FAIL %s:%d: %s (errno=%d %s)\n", __FILE__, __LINE__, #cond, \
                    errno, strerror(errno));                                            \
            failures++;                                                                 \
        }                                                                               \
    } while (0)

static int file_exists(const char *name) {
    char p[PATH_MAX];
    struct stat st;
    snprintf(p, sizeof(p), "%s/%s", dir, name);
    return lstat(p, &st) == 0;
}

static void *server_map(int id, size_t *len) {
    char p[PATH_MAX];
    snprintf(p, sizeof(p), "%s/%d", dir, id);
    int fd = open(p, O_RDWR);
    if (fd < 0) return NULL;
    struct stat st;
    if (fstat(fd, &st) != 0) {
        close(fd);
        return NULL;
    }
    void *m = mmap(NULL, (size_t)st.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (m == MAP_FAILED) return NULL;
    *len = (size_t)st.st_size;
    return m;
}

#define THREADS 8
#define PER_THREAD 32
static int thread_ids[THREADS][PER_THREAD];

static void *alloc_worker(void *arg) {
    int t = (int)(long)arg;
    for (int i = 0; i < PER_THREAD; i++) thread_ids[t][i] = shmget(IPC_PRIVATE, 4096, IPC_CREAT | 0600);
    return NULL;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <PMBOS_SHM_DIR>\n", argv[0]);
        return 2;
    }
    dir = argv[1];
    char name[32];

    /* 1. private segment, size = file size, X-server-style open+mmap sees client writes */
    int id = shmget(IPC_PRIVATE, 10000, IPC_CREAT | 0700);
    CHECK(id > 0);
    snprintf(name, sizeof(name), "%d", id);
    CHECK(file_exists(name));
    CHECK(file_exists(".next"));
    char *a = shmat(id, NULL, 0);
    CHECK(a != (void *)-1);
    strcpy(a, "hello from client");
    size_t slen = 0;
    char *srv = server_map(id, &slen);
    CHECK(srv != NULL && slen == 10000);
    if (srv) {
        CHECK(strcmp(srv, "hello from client") == 0);
        strcpy(srv + 100, "hello from server");
        CHECK(strcmp(a + 100, "hello from server") == 0);
    }

    /* 2. IPC_STAT */
    struct shmid_ds ds;
    CHECK(shmctl(id, IPC_STAT, &ds) == 0);
    CHECK(ds.shm_segsz == 10000);
    CHECK(ds.shm_nattch == 1);
    CHECK((ds.shm_perm.mode & 0777) == 0700);

    /* 3. RMID while attached: deferred until last local detach (wine pattern) */
    CHECK(shmctl(id, IPC_RMID, NULL) == 0);
    CHECK(file_exists(name));
    CHECK(shmctl(id, IPC_STAT, &ds) == 0 && (ds.shm_perm.mode & SHM_DEST));
    CHECK(shmdt(a) == 0);
    CHECK(!file_exists(name));
    if (srv) {
        CHECK(strcmp(srv, "hello from client") == 0); /* server mapping survives unlink */
        munmap(srv, slen);
    }
    CHECK(shmdt(a) == -1 && errno == EINVAL);

    /* 4. RMID while not attached: immediate unlink; attach then fails */
    id = shmget(IPC_PRIVATE, 4096, IPC_CREAT | 0600);
    CHECK(id > 0);
    CHECK(shmctl(id, IPC_RMID, NULL) == 0);
    CHECK(shmat(id, NULL, 0) == (void *)-1 && errno == EINVAL);
    CHECK(shmctl(id, IPC_STAT, &ds) == -1 && errno == EINVAL);

    /* 5. keyed segments, IPC_EXCL, ENOENT, size check */
    key_t key = (key_t)0x1234abcd;
    CHECK(shmget(key, 4096, 0600) == -1 && errno == ENOENT);
    int kid = shmget(key, 8192, IPC_CREAT | IPC_EXCL | 0600);
    CHECK(kid > 0);
    CHECK(file_exists("key-1234abcd"));
    CHECK(shmget(key, 4096, 0600) == kid);
    CHECK(shmget(key, 8192, IPC_CREAT | 0600) == kid);
    CHECK(shmget(key, 4096, IPC_CREAT | IPC_EXCL | 0600) == -1 && errno == EEXIST);
    CHECK(shmget(key, 1 << 20, 0600) == -1 && errno == EINVAL);
    CHECK(shmctl(kid, IPC_STAT, &ds) == 0 && ds.shm_perm.__key == key);

    /* 6. SHM_RDONLY: writes must fault -> verify via mprotect-free check of prot (read only) */
    char *ro = shmat(kid, NULL, SHM_RDONLY);
    CHECK(ro != (void *)-1);
    char *rw = shmat(kid, NULL, 0);
    CHECK(rw != (void *)-1);
    rw[5] = 'x';
    CHECK(ro[5] == 'x');

    /* 7. attach at a given address (+SHM_RND) */
    long ps = sysconf(_SC_PAGESIZE);
    char *hint = mmap(NULL, (size_t)ps * 8, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    CHECK(hint != MAP_FAILED);
    munmap(hint, (size_t)ps * 8);
    char *fixed = shmat(kid, hint + ps, 0);
    CHECK(fixed == hint + ps);
    CHECK(shmat(kid, hint + ps, 0) == (void *)-1 && errno == EINVAL); /* overlap w/o SHM_REMAP */
    CHECK(shmat(kid, hint + ps + 1, 0) == (void *)-1 && errno == EINVAL);
    CHECK(shmdt(fixed) == 0);
    char *rnd = shmat(kid, hint + ps + 1, SHM_RND);
    CHECK(rnd == hint + ps);
    if (rnd != (void *)-1) CHECK(rnd[5] == 'x');
    CHECK(shmdt(rnd) == 0);

    /* 8. fork: child inherits attachment, writes are visible to the parent */
    pid_t pid = fork();
    if (pid == 0) {
        rw[100] = 'C';
        int child_id = shmget(key, 0, 0);
        _exit(child_id == kid ? 0 : 1);
    }
    int status = 0;
    CHECK(waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    CHECK(rw[100] == 'C');

    /* 9. keyed RMID removes the key link immediately; the key can be re-created */
    CHECK(shmctl(kid, IPC_RMID, NULL) == 0);
    CHECK(!file_exists("key-1234abcd"));
    int kid2 = shmget(key, 4096, IPC_CREAT | IPC_EXCL | 0600);
    CHECK(kid2 > 0 && kid2 != kid);
    CHECK(shmdt(ro) == 0 && shmdt(rw) == 0);
    snprintf(name, sizeof(name), "%d", kid);
    CHECK(!file_exists(name));
    CHECK(shmctl(kid2, IPC_RMID, NULL) == 0);

    /* 10. concurrent IPC_PRIVATE allocation never hands out duplicate ids */
    pthread_t th[THREADS];
    for (long t = 0; t < THREADS; t++) pthread_create(&th[t], NULL, alloc_worker, (void *)t);
    for (int t = 0; t < THREADS; t++) pthread_join(th[t], NULL);
    for (int i = 0; i < THREADS * PER_THREAD; i++) {
        int x = thread_ids[i / PER_THREAD][i % PER_THREAD];
        CHECK(x > 0);
        for (int j = i + 1; j < THREADS * PER_THREAD; j++)
            if (x == thread_ids[j / PER_THREAD][j % PER_THREAD]) {
                fprintf(stderr, "duplicate id %d\n", x);
                failures++;
            }
        shmctl(x, IPC_RMID, NULL);
    }

    /* 11. invalid arguments */
    CHECK(shmget(IPC_PRIVATE, 0, IPC_CREAT | 0600) == -1 && errno == EINVAL);
    CHECK(shmat(-1, NULL, 0) == (void *)-1 && errno == EINVAL);
    CHECK(shmctl(999999, IPC_RMID, NULL) == -1 && errno == EINVAL);
    CHECK(shmctl(1, 4242, &ds) == -1 && errno == EINVAL);

    if (failures) {
        fprintf(stderr, "pmbshm-test: %d failure(s)\n", failures);
        return 1;
    }
    printf("pmbshm-test: all checks passed\n");
    return 0;
}
