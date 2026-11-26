/* SPDX-License-Identifier: MIT */
#define _GNU_SOURCE
#include "sm8850_owned_groups.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/vfs.h>
#include <time.h>
#include <unistd.h>

#define CGROUP_V1_MAGIC 0x27e0eb
#define CGROUP_V2_MAGIC 0x63677270
#define PERIOD_US 20000L
#define MAX_WAIT_MS 2000u
#define DIR_FLAGS (O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)

static int invalid(void) { errno = EINVAL; return -1; }
static int refuse(void) { errno = EPERM; return -1; }

static void init_handle(struct oneios_owned_groups *g)
{
    memset(g, 0, sizeof *g);
    g->cpu_parent = g->freezer_parent = g->cpu = g->freezer = -1;
}

void oneios_owned_groups_close(struct oneios_owned_groups *g)
{
    if (!g) return;
    if (g->cpu >= 0) close(g->cpu);
    if (g->freezer >= 0) close(g->freezer);
    if (g->cpu_parent >= 0) close(g->cpu_parent);
    if (g->freezer_parent >= 0) close(g->freezer_parent);
    init_handle(g);
}

static bool valid_token(const char *token)
{
    return token && strlen(token) == 32 &&
           strspn(token, "0123456789abcdef") == 32;
}

static bool valid_pct(unsigned pct) { return pct >= 10 && pct <= 100; }
static long quota_for(unsigned pct) { return 1600L * pct; }

/* No O_CREAT, no symlink following, no caller-controlled filenames. */
static int read_text(int dir, const char *name, char *buf, size_t cap)
{
    int fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    size_t off = 0;
    int rc = -1;
    while (off < cap - 1) {
        ssize_t n = read(fd, buf + off, cap - 1 - off);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) goto done;
        if (!n) { buf[off] = 0; rc = 0; goto done; }
        off += (size_t)n;
    }
    errno = EOVERFLOW;
done:
    close(fd);
    return rc;
}

static int read_number(int dir, const char *name, long *value)
{
    char buf[96], *end;
    if (read_text(dir, name, buf, sizeof buf)) return -1;
    errno = 0;
    long n = strtol(buf, &end, 10);
    if (errno || end == buf) return invalid();
    if (*end == '\n') end++;
    if (*end) return invalid();
    *value = n;
    return 0;
}

static int expect_number(int dir, const char *name, long expected)
{
    long actual;
    if (read_number(dir, name, &actual)) return -1;
    return actual == expected ? 0 : refuse();
}

static int write_number(int dir, const char *name, long value)
{
    char buf[32];
    int n = snprintf(buf, sizeof buf, "%ld\n", value);
    if (n <= 0 || (size_t)n >= sizeof buf) return invalid();
    int fd = openat(dir, name, O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    /* One complete cgroup command; never replay a partially accepted write. */
    ssize_t written;
    do { written = write(fd, buf, (size_t)n); }
    while (written < 0 && errno == EINTR);
    int saved = errno;
    int closed = close(fd);
    if (written != n) { errno = written < 0 ? saved : EIO; return -1; }
    return closed;
}

/* The live backend is Linux/Android cgroupfs only. Test fixtures use a
 * separate compile-time entry point, never a production path override.
 */
#ifndef ONEIOS_OWNED_GROUPS_TEST
static int correct_fs(int dir, long magic)
{
    struct statfs fs;
    if (fstatfs(dir, &fs)) return -1;
    return (long)fs.f_type == magic ? 0 : refuse();
}

static int monitor_outside_groups(void)
{
    char buf[4096];
    if (read_text(AT_FDCWD, "/proc/self/cgroup", buf, sizeof buf)) return -1;
    bool cpu = false, unified = false;
    char *save = NULL;
    for (char *row = strtok_r(buf, "\n", &save); row;
         row = strtok_r(NULL, "\n", &save)) {
        char *a = strchr(row, ':');
        if (!a) return invalid();
        char *b = strchr(a + 1, ':');
        if (!b) return invalid();
        *a++ = 0; *b++ = 0;
        if (!strcmp(row, "0") && !*a && !strcmp(b, "/")) unified = true;
        char *cs = NULL;
        for (char *c = strtok_r(a, ",", &cs); c; c = strtok_r(NULL, ",", &cs))
            if (!strcmp(c, "cpu") && !strcmp(b, "/")) cpu = true;
    }
    return cpu && unified ? 0 : refuse();
}
#else
static int correct_fs(int dir, long magic) { (void)dir; (void)magic; return 0; }
static int monitor_outside_groups(void) { return 0; }
#endif

static int leaf_only(int fd)
{
    /* Fresh directory description; do not share directory iteration offset. */
    int copy = openat(fd, ".", DIR_FLAGS);
    if (copy < 0) return -1;
    DIR *d = fdopendir(copy);
    if (!d) { close(copy); return -1; }
    int rc = 0;
    for (;;) {
        errno = 0;
        struct dirent *e = readdir(d);
        if (!e) { if (errno) rc = -1; break; }
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        struct stat st;
        if (fstatat(fd, e->d_name, &st, AT_SYMLINK_NOFOLLOW)) { rc = -1; break; }
        if (S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) { rc = refuse(); break; }
    }
    closedir(d);
    return rc;
}

static int same_leaf(int parent, int fd, const char *name,
                     struct oneios_group_id id)
{
    struct stat held, named;
    if (fstat(fd, &held) || fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW))
        return -1;
    if (!S_ISDIR(held.st_mode) || !S_ISDIR(named.st_mode) ||
        held.st_dev != id.dev || held.st_ino != id.ino ||
        named.st_dev != id.dev || named.st_ino != id.ino ||
        held.st_uid != geteuid() || (held.st_mode & 0022)) return refuse();
    return leaf_only(fd);
}

static int verify_groups(struct oneios_owned_groups *g)
{
    if (!g || g->cpu < 0 || g->freezer < 0) return invalid();
    if (monitor_outside_groups() ||
        same_leaf(g->cpu_parent, g->cpu, g->name, g->cpu_id) ||
        same_leaf(g->freezer_parent, g->freezer, g->name, g->freezer_id))
        return -1;
    return 0;
}

static int verify_quota(struct oneios_owned_groups *g)
{
    if (expect_number(g->cpu, "cpu.cfs_period_us", PERIOD_US) ||
        expect_number(g->cpu, "cpu.cfs_quota_us", quota_for(g->cpu_pct)))
        return -1;
    long burst;
    if (read_number(g->cpu, "cpu.cfs_burst_us", &burst))
        return errno == ENOENT ? 0 : -1;
    return burst == 0 ? 0 : refuse();
}

static int frozen_event(int dir, long *value)
{
    char buf[256], *save = NULL;
    bool found = false;
    if (read_text(dir, "cgroup.events", buf, sizeof buf)) return -1;
    for (char *row = strtok_r(buf, "\n", &save); row;
         row = strtok_r(NULL, "\n", &save)) {
        if (strncmp(row, "frozen ", 7)) continue;
        if (found || (strcmp(row + 7, "0") && strcmp(row + 7, "1")))
            return invalid();
        *value = row[7] - '0';
        found = true;
    }
    return found ? 0 : invalid();
}

int oneios_owned_groups_verify(struct oneios_owned_groups *g, bool frozen)
{
    if (!g) return invalid();
    if (g->fault) return refuse();
    long actual;
    if (verify_groups(g) || verify_quota(g) ||
        expect_number(g->freezer, "cgroup.freeze", frozen ? 1 : 0) ||
        frozen_event(g->freezer, &actual) || actual != (long)frozen ||
        g->freeze_confirmed != frozen) {
        g->fault = true;
        return refuse();
    }
    return 0;
}

/* Consumes parent FDs even on failure. The caller supplies identities from
 * its trusted session creator, not identities discovered by this actuator.
 */
static int bind_parents(struct oneios_owned_groups *g, int cpu, int freezer,
                        const char *token, struct oneios_group_id cpu_id,
                        struct oneios_group_id freezer_id, unsigned pct)
{
    init_handle(g);
    g->cpu_parent = cpu; g->freezer_parent = freezer;
    if (cpu < 0 || freezer < 0 || !valid_token(token) || !valid_pct(pct)) goto bad;
    snprintf(g->name, sizeof g->name, "oneios_guest.%s", token);
    g->cpu_id = cpu_id; g->freezer_id = freezer_id; g->cpu_pct = pct;
    if (correct_fs(cpu, CGROUP_V1_MAGIC) || correct_fs(freezer, CGROUP_V2_MAGIC))
        goto bad;
    g->cpu = openat(cpu, g->name, DIR_FLAGS);
    g->freezer = openat(freezer, g->name, DIR_FLAGS);
    if (g->cpu < 0 || g->freezer < 0 ||
        correct_fs(g->cpu, CGROUP_V1_MAGIC) ||
        correct_fs(g->freezer, CGROUP_V2_MAGIC) ||
        verify_groups(g) || verify_quota(g) ||
        expect_number(g->freezer, "cgroup.freeze", 0)) goto bad;
    long state;
    if (frozen_event(g->freezer, &state) || state != 0) goto bad;
    return 0;
bad:
    oneios_owned_groups_close(g);
    return refuse();
}

int oneios_owned_groups_open(struct oneios_owned_groups *g, const char *token,
    struct oneios_group_id cpu_id, struct oneios_group_id freezer_id,
    unsigned initial_pct)
{
    if (!g) return invalid();
    init_handle(g);
    if (geteuid() != 0 || !valid_token(token) || !valid_pct(initial_pct))
        return refuse();
    return bind_parents(g, open("/dev/cpuctl", DIR_FLAGS),
                        open("/sys/fs/cgroup", DIR_FLAGS),
                        token, cpu_id, freezer_id, initial_pct);
}

int oneios_owned_cpu_set(struct oneios_owned_groups *g, unsigned pct)
{
    if (!g || !valid_pct(pct)) return invalid();
    if (g->fault) return refuse();
    if (verify_groups(g) || verify_quota(g)) goto fault;
    if (pct == g->cpu_pct) return 0; /* do not reset CFS bandwidth unnecessarily */
    if (write_number(g->cpu, "cpu.cfs_quota_us", quota_for(pct)) ||
        expect_number(g->cpu, "cpu.cfs_quota_us", quota_for(pct)) ||
        expect_number(g->cpu, "cpu.cfs_period_us", PERIOD_US) ||
        verify_groups(g)) goto fault;
    g->cpu_pct = pct;
    return 0;
fault:
    g->fault = true;
    return -1;
}

static int boot_ms(unsigned long long *out)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_BOOTTIME, &ts)) return -1;
    *out = (unsigned long long)ts.tv_sec * 1000u + (unsigned long long)ts.tv_nsec / 1000000u;
    return 0;
}

static int wait_frozen(struct oneios_owned_groups *g, long wanted, unsigned ms)
{
    unsigned long long start, now;
    if (boot_ms(&start)) return -1;
    for (;;) {
        long actual;
        if (verify_groups(g) || expect_number(g->freezer, "cgroup.freeze", wanted) ||
            frozen_event(g->freezer, &actual)) return -1;
        if (boot_ms(&now)) return -1;
        if (now < start) return invalid();
        if (now - start >= ms) { errno = ETIMEDOUT; return -1; }
        if (actual == wanted) return 0;
        unsigned long long remain = ms - (now - start);
        long nap = (long)(remain < 10 ? remain : 10);
        nanosleep(&(struct timespec){ .tv_sec = 0, .tv_nsec = nap * 1000000L }, NULL);
    }
}

int oneios_owned_freeze(struct oneios_owned_groups *g, unsigned timeout_ms)
{
    if (!g || !timeout_ms || timeout_ms > MAX_WAIT_MS) return invalid();
    g->freeze_confirmed = false;
    /* A budget fault must not prevent a verified freeze of our own group. */
    if (verify_groups(g) || write_number(g->freezer, "cgroup.freeze", 1) ||
        wait_frozen(g, 1, timeout_ms)) {
        g->fault = true;
        return -1;
    }
    g->freeze_confirmed = true;
    return 0;
}

int oneios_owned_thaw(struct oneios_owned_groups *g, unsigned timeout_ms)
{
    if (!g || !timeout_ms || timeout_ms > MAX_WAIT_MS) return invalid();
    if (g->fault || !g->freeze_confirmed) return refuse();
    long actual;
    if (verify_groups(g) || verify_quota(g) ||
        expect_number(g->freezer, "cgroup.freeze", 1) ||
        frozen_event(g->freezer, &actual) || actual != 1) goto fault;
    g->freeze_confirmed = false;
    if (!write_number(g->freezer, "cgroup.freeze", 0) &&
        !wait_frozen(g, 0, timeout_ms)) return 0;
    /* Never intentionally leave an unconfirmed resume request in effect.
     * Attempt to reassert freeze only if the original group still verifies.
     * This is not proof of successful refreeze.
     */
    if (!verify_groups(g)) (void)write_number(g->freezer, "cgroup.freeze", 1);
fault:
    g->fault = true;
    return -1;
}
