/*
 * Self-test for patches/glibc-2.36-pmbos-rootfs.patch (PMBOS_ROOTFS path relocation).
 *
 *   glibc-rootfs-test --selftest ROOTDIR REALSH
 *       Must run under the patched loader + libc, e.g.
 *         <glibc>/lib/ld-linux-aarch64.so.1 --library-path <glibc>/usr/lib/aarch64-linux-gnu \
 *             ./glibc-rootfs-test --selftest "$(mktemp -d)" /bin/sh
 *       Builds a fake rootfs in the empty directory ROOTDIR (etc files with unique entries, a
 *       TZif zone, bin/sh = logging wrapper script around REALSH), then
 *         1. in a forked child WITHOUT PMBOS_ROOTFS: nothing is read from ROOTDIR (upstream
 *            behaviour, /etc and /bin/sh of the build system are used);
 *         2. with PMBOS_ROOTFS=ROOTDIR: nss_files (passwd, group, hosts, services, protocols),
 *            nsswitch.conf, resolv.conf (res_init), localtime + zoneinfo, and the shell of
 *            system(), popen(), wordexp() and the execvp() ENOEXEC fallback all come from it.
 *   glibc-rootfs-test --imagefs
 *       Smoke test of an installed imagefs: PMBOS_ROOTFS must point at it. Checks the shipped
 *       /etc files resolve (root, localhost, the "http" service, "tcp" protocol, UTC
 *       localtime) and that system() runs <imagefs>/bin/sh.
 * Exit status 0 = all checks passed.
 */
#define _GNU_SOURCE
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <errno.h>
#include <grp.h>
#include <limits.h>
#include <netdb.h>
#include <pwd.h>
#include <resolv.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <wordexp.h>

static int failures;
static const char *root;

#define CHECK(cond)                                                                     \
    do {                                                                                \
        if (!(cond)) {                                                                  \
            fprintf(stderr, "FAIL %s:%d: %s (errno=%d %s)\n", __FILE__, __LINE__, #cond, \
                    errno, strerror(errno));                                            \
            failures++;                                                                 \
        }                                                                               \
    } while (0)

static void path_in_root(char *out, size_t size, const char *rel) {
    int n = snprintf(out, size, "%s/%s", root, rel);
    if (n < 0 || (size_t)n >= size) {
        fprintf(stderr, "path too long: %s/%s\n", root, rel);
        exit(2);
    }
}

static void mkdirs(const char *rel) {
    char p[PATH_MAX];
    path_in_root(p, sizeof(p), rel);
    for (char *s = p + strlen(root) + 1; *s; s++) {
        if (*s == '/') {
            *s = '\0';
            if (mkdir(p, 0755) != 0 && errno != EEXIST) {
                perror(p);
                exit(2);
            }
            *s = '/';
        }
    }
    if (mkdir(p, 0755) != 0 && errno != EEXIST) {
        perror(p);
        exit(2);
    }
}

static void write_file(const char *rel, const void *data, size_t len, mode_t mode) {
    char p[PATH_MAX];
    path_in_root(p, sizeof(p), rel);
    FILE *f = fopen(p, "wb");
    if (f == NULL || fwrite(data, 1, len, f) != len || fclose(f) != 0) {
        perror(p);
        exit(2);
    }
    if (chmod(p, mode) != 0) {
        perror(p);
        exit(2);
    }
}

static void write_text(const char *rel, const char *text, mode_t mode) {
    write_file(rel, text, strlen(text), mode);
}

static void put32(unsigned char *p, uint32_t v) {
    p[0] = (unsigned char)(v >> 24);
    p[1] = (unsigned char)(v >> 16);
    p[2] = (unsigned char)(v >> 8);
    p[3] = (unsigned char)v;
}

/* Minimal TZif version-1 file: no transitions, one local time type. */
static void write_tzif(const char *rel, int32_t utoff, const char *abbr3) {
    unsigned char b[54];
    memset(b, 0, sizeof(b));
    memcpy(b, "TZif", 4);           /* version byte b[4] = 0 -> v1 */
    put32(b + 36, 1);               /* tzh_typecnt */
    put32(b + 40, 4);               /* tzh_charcnt */
    put32(b + 44, (uint32_t)utoff); /* ttinfo: utoff, isdst = 0, desigidx = 0 */
    memcpy(b + 50, abbr3, 3);       /* "XXX\0" */
    write_file(rel, b, sizeof(b), 0644);
}

static int count_lines(const char *rel) {
    char p[PATH_MAX];
    path_in_root(p, sizeof(p), rel);
    FILE *f = fopen(p, "r");
    if (f == NULL)
        return 0;
    int n = 0, c;
    while ((c = fgetc(f)) != EOF)
        if (c == '\n')
            n++;
    fclose(f);
    return n;
}

static long gmtoff_now(char *zone, size_t zsize) {
    time_t t = 0;
    struct tm tm;
    tzset();
    if (localtime_r(&t, &tm) == NULL)
        return -999999;
    snprintf(zone, zsize, "%s", tm.tm_zone ? tm.tm_zone : "");
    return tm.tm_gmtoff;
}

static int wait_status(pid_t pid) {
    int st;
    while (waitpid(pid, &st, 0) < 0) {
        if (errno != EINTR)
            return -1;
    }
    return WIFEXITED(st) ? WEXITSTATUS(st) : 128 + (WIFSIGNALED(st) ? WTERMSIG(st) : 0);
}

#define ZONE_DEFAULT_OFF (3 * 3600 + 25 * 60)
#define ZONE_NAMED_OFF (5 * 3600 + 40 * 60)

static void build_root(const char *realsh) {
    mkdirs("etc");
    mkdirs("bin");
    mkdirs("usr/share/zoneinfo/PMB");
    write_text("etc/passwd",
               "root:x:0:0:root:/root:/bin/sh\n"
               "pmbos-selftest:x:4242:4243:PMB OS self-test:/home/pmbos-selftest:/bin/sh\n", 0644);
    write_text("etc/group", "root:x:0:\npmbos-selftest:x:4243:\n", 0644);
    write_text("etc/hosts", "127.0.0.1 localhost\n192.0.2.7 pmbos-selftest.invalid\n", 0644);
    write_text("etc/services", "pmbos-selftest 4244/tcp\n", 0644);
    write_text("etc/protocols", "pmbos-selftest 253 PMBOS-SELFTEST\n", 0644);
    write_text("etc/networks", "pmbosnet 10.99.0.0\n", 0644);
    /* networks: a module that does not exist -> getnetbyname() must fail although
       etc/networks has the entry; proves nsswitch.conf was read from ROOTDIR. */
    write_text("etc/nsswitch.conf",
               "passwd: files\ngroup: files\nshadow: files\nhosts: files\n"
               "services: files\nprotocols: files\nnetworks: pmbosnone\n", 0644);
    write_text("etc/resolv.conf", "nameserver 192.0.2.53\noptions ndots:3 timeout:1 attempts:1\n",
               0644);
    write_tzif("etc/localtime", ZONE_DEFAULT_OFF, "PMA");
    write_tzif("usr/share/zoneinfo/PMB/Test", ZONE_NAMED_OFF, "PMB");
    char sh[PATH_MAX + 256];
    int n = snprintf(sh, sizeof(sh),
                     "#!%s\n"
                     "echo \"pmbos-sh $*\" >> \"$PMBOS_ROOTFS/sh.log\"\n"
                     "exec %s \"$@\"\n", realsh, realsh);
    if (n < 0 || (size_t)n >= sizeof(sh))
        exit(2);
    write_text("bin/sh", sh, 0755);
    write_text("noshebang-script", "exit 5\n", 0755);
}

/* Upstream behaviour without PMBOS_ROOTFS (runs in a forked child before anything is cached). */
static void check_unset(void) {
    char zone[16];
    CHECK(getenv("PMBOS_ROOTFS") == NULL);
    errno = 0;
    CHECK(getpwnam("pmbos-selftest") == NULL);
    CHECK(getpwnam("root") != NULL);
    int st = system("exit 3");
    CHECK(st != -1 && WIFEXITED(st) && WEXITSTATUS(st) == 3);
    CHECK(count_lines("sh.log") == 0);
    unsetenv("TZ");
    unsetenv("TZDIR");
    CHECK(gmtoff_now(zone, sizeof(zone)) != ZONE_DEFAULT_OFF);
}

static void check_set(void) {
    char zone[16];
    int lines = 0;

    /* nss_files via __nss_files_fopen */
    struct passwd *pw = getpwnam("pmbos-selftest");
    CHECK(pw != NULL && pw->pw_uid == 4242 && pw->pw_gid == 4243);
    pw = getpwuid(4242);
    CHECK(pw != NULL && strcmp(pw->pw_name, "pmbos-selftest") == 0);
    struct group *gr = getgrgid(4243);
    CHECK(gr != NULL && strcmp(gr->gr_name, "pmbos-selftest") == 0);
    struct servent *se = getservbyname("pmbos-selftest", "tcp");
    CHECK(se != NULL && ntohs((uint16_t)se->s_port) == 4244);
    struct protoent *pe = getprotobyname("pmbos-selftest");
    CHECK(pe != NULL && pe->p_proto == 253);

    /* hosts + services through getaddrinfo */
    struct addrinfo hints, *ai = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    int rc = getaddrinfo("pmbos-selftest.invalid", "pmbos-selftest", &hints, &ai);
    CHECK(rc == 0 && ai != NULL);
    if (rc == 0 && ai != NULL) {
        const struct sockaddr_in *sin = (const struct sockaddr_in *)ai->ai_addr;
        CHECK(sin->sin_addr.s_addr == htonl(0xC0000207u)); /* 192.0.2.7 */
        CHECK(ntohs(sin->sin_port) == 4244);
        freeaddrinfo(ai);
    }

    /* nsswitch.conf */
    CHECK(getnetbyname("pmbosnet") == NULL);

    /* resolv.conf */
    CHECK(res_init() == 0);
    CHECK(_res.nscount == 1);
    CHECK(_res.nsaddr_list[0].sin_addr.s_addr == htonl(0xC0000235u)); /* 192.0.2.53 */
    CHECK(_res.ndots == 3);

    /* time zones: default file and default zoneinfo directory */
    unsetenv("TZ");
    unsetenv("TZDIR");
    CHECK(gmtoff_now(zone, sizeof(zone)) == ZONE_DEFAULT_OFF && strcmp(zone, "PMA") == 0);
    setenv("TZ", "PMB/Test", 1);
    CHECK(gmtoff_now(zone, sizeof(zone)) == ZONE_NAMED_OFF && strcmp(zone, "PMB") == 0);
    unsetenv("TZ");

    /* shells */
    int st = system("exit 7");
    CHECK(st != -1 && WIFEXITED(st) && WEXITSTATUS(st) == 7);
    CHECK(count_lines("sh.log") == ++lines);

    FILE *p = popen("echo pmbos-popen", "r");
    CHECK(p != NULL);
    if (p != NULL) {
        char buf[64] = "";
        CHECK(fgets(buf, sizeof(buf), p) != NULL && strcmp(buf, "pmbos-popen\n") == 0);
        CHECK(pclose(p) == 0);
    }
    CHECK(count_lines("sh.log") == ++lines);

    wordexp_t we;
    rc = wordexp("$(echo pmbos-wordexp)", &we, 0);
    CHECK(rc == 0);
    if (rc == 0) {
        CHECK(we.we_wordc == 1 && strcmp(we.we_wordv[0], "pmbos-wordexp") == 0);
        wordfree(&we);
    }
    CHECK(count_lines("sh.log") == ++lines);

    char script[PATH_MAX];
    path_in_root(script, sizeof(script), "noshebang-script");
    pid_t pid = fork();
    if (pid == 0) {
        char *const argv[] = {script, NULL};
        execvp(script, argv);
        _exit(99);
    }
    CHECK(pid > 0 && wait_status(pid) == 5);
    CHECK(count_lines("sh.log") == ++lines);
}

static int imagefs_mode(void) {
    char zone[16];
    root = getenv("PMBOS_ROOTFS");
    if (root == NULL || root[0] != '/') {
        fprintf(stderr, "--imagefs needs PMBOS_ROOTFS=<absolute imagefs path>\n");
        return 2;
    }
    CHECK(getpwnam("root") != NULL);
    CHECK(getgrnam("root") != NULL);
    struct addrinfo hints, *ai = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    int rc = getaddrinfo("localhost", "http", &hints, &ai);
    CHECK(rc == 0 && ai != NULL);
    if (rc == 0 && ai != NULL) {
        const struct sockaddr_in *sin = (const struct sockaddr_in *)ai->ai_addr;
        CHECK(sin->sin_addr.s_addr == htonl(INADDR_LOOPBACK) && ntohs(sin->sin_port) == 80);
        freeaddrinfo(ai);
    }
    CHECK(getprotobyname("tcp") != NULL);
    CHECK(res_init() == 0 && _res.nscount >= 1);
    unsetenv("TZ");
    unsetenv("TZDIR");
    CHECK(gmtoff_now(zone, sizeof(zone)) == 0 && strcmp(zone, "UTC") == 0);
    setenv("TZ", "Europe/Berlin", 1);
    CHECK(gmtoff_now(zone, sizeof(zone)) == 3600 && strcmp(zone, "CET") == 0);
    unsetenv("TZ");
    int st = system("test -n \"$PMBOS_ROOTFS\" && exit 6");
    CHECK(st != -1 && WIFEXITED(st) && WEXITSTATUS(st) == 6);
    FILE *p = popen("echo ok", "r");
    CHECK(p != NULL);
    if (p != NULL) {
        char buf[16] = "";
        CHECK(fgets(buf, sizeof(buf), p) != NULL && strcmp(buf, "ok\n") == 0);
        CHECK(pclose(p) == 0);
    }
    if (failures)
        fprintf(stderr, "glibc-rootfs-test --imagefs: %d check(s) failed\n", failures);
    return failures ? 1 : 0;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--imagefs") == 0)
        return imagefs_mode();
    if (argc != 4 || strcmp(argv[1], "--selftest") != 0 || argv[2][0] != '/' || argv[3][0] != '/') {
        fprintf(stderr, "usage: %s --selftest ROOTDIR REALSH | --imagefs\n", argv[0]);
        return 2;
    }
    root = argv[2];
    unsetenv("PMBOS_ROOTFS");
    build_root(argv[3]);

    fflush(NULL);
    pid_t pid = fork();
    if (pid == 0) {
        check_unset();
        fflush(NULL);
        _exit(failures ? 1 : 0);
    }
    CHECK(pid > 0 && wait_status(pid) == 0);

    if (setenv("PMBOS_ROOTFS", root, 1) != 0)
        return 2;
    check_set();
    if (failures) {
        fprintf(stderr, "glibc-rootfs-test: %d check(s) failed\n", failures);
        return 1;
    }
    printf("glibc-rootfs-test: all checks passed\n");
    return 0;
}
