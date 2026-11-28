/* SPDX-License-Identifier: MIT */
#define _GNU_SOURCE
#include "sm8850_owned_groups.h"
#include "sm8850_guest_launch.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/syscall.h>
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


/* A fresh session creator, never adopt an existing token name. The caller
 * still owns the blocked-start barrier and ALL membership transitions. */
#ifdef ONEIOS_OWNED_GROUPS_TEST
static int fixture_create_nodes(int fd, bool cpu);
static int fixture_remove_nodes(int fd, bool cpu);
#endif
static int empty_group(int fd)
{
    char b[2];
    return read_text(fd, "cgroup.procs", b, sizeof b) || b[0] ? refuse() : 0;
}
static int create_leaf(int parent, const char *name, long magic, bool cpu,
                       int *fd, struct oneios_group_id *id)
{
    if (mkdirat(parent, name, 0700)) return -1;
    int f = openat(parent, name, DIR_FLAGS);
    struct stat st;
    if (f < 0) return -1; /* no pinned identity: leave for trusted cleanup */
    if (fstat(f, &st) || !S_ISDIR(st.st_mode) || st.st_uid != geteuid() ||
        (st.st_mode & 0022)) { close(f); return refuse(); }
    *fd = f;
    *id = (struct oneios_group_id){ st.st_dev, st.st_ino };
    if (correct_fs(f, magic) || same_leaf(parent, f, name, *id)) return -1;
#ifdef ONEIOS_OWNED_GROUPS_TEST
    if (fixture_create_nodes(f, cpu)) return -1;
#else
    (void)cpu;
#endif
    return empty_group(f);
}
static int remove_leaf_empty(int parent, int fd, const char *name,
                             struct oneios_group_id id, bool cpu)
{
    if (same_leaf(parent, fd, name, id) || empty_group(fd)) return -1;
#ifdef ONEIOS_OWNED_GROUPS_TEST
    if (fixture_remove_nodes(fd, cpu)) return -1;
#else
    (void)cpu;
#endif
    return unlinkat(parent, name, AT_REMOVEDIR);
}
/* Consumes the parent descriptors; no adoption, migration, thaw or changes
 * to a parent. On failure, remove only identity-pinned, still-empty leaves
 * created by this call. Unconfirmed rollback must not be reused. */
static int create_parents(struct oneios_owned_groups *g, int cp, int fp,
                          const char *token, unsigned pct)
{
    init_handle(g);
    int c = -1, f = -1, rc = -1;
    struct oneios_group_id ci = {0}, fi = {0};
    char name[sizeof g->name] = {0};
    if (cp < 0 || fp < 0 || !valid_token(token) || !valid_pct(pct) ||
        correct_fs(cp, CGROUP_V1_MAGIC) || correct_fs(fp, CGROUP_V2_MAGIC) ||
        monitor_outside_groups()) goto done;
    snprintf(name, sizeof name, "oneios_guest.%s", token);
    if (create_leaf(cp, name, CGROUP_V1_MAGIC, true, &c, &ci) ||
        create_leaf(fp, name, CGROUP_V2_MAGIC, false, &f, &fi)) goto done;
    if (write_number(c, "cpu.cfs_period_us", PERIOD_US) ||
        write_number(c, "cpu.cfs_quota_us", quota_for(pct)) ||
        empty_group(c) || empty_group(f) ||
        bind_parents(g, fcntl(cp, F_DUPFD_CLOEXEC, 0),
                        fcntl(fp, F_DUPFD_CLOEXEC, 0), token, ci, fi, pct)) goto done;
    rc = 0;
done:;
    int saved = errno;
    if (rc) {
        if (f >= 0 && remove_leaf_empty(fp, f, name, fi, false)) saved = EIO;
        if (c >= 0 && remove_leaf_empty(cp, c, name, ci, true)) saved = EIO;
    }
    if (f >= 0) close(f);
    if (c >= 0) close(c);
    if (fp >= 0) close(fp);
    if (cp >= 0) close(cp);
    if (rc) errno = saved ? saved : EPERM;
    return rc;
}
int oneios_owned_groups_create(struct oneios_owned_groups *g, const char *token,
                               unsigned initial_pct)
{
    if (!g) return invalid();
    init_handle(g);
#ifdef ONEIOS_OWNED_GROUPS_TEST
    (void)token; (void)initial_pct;
    return refuse(); /* fixture build never opens live cgroup paths */
#else
    if (geteuid() != 0 || !valid_token(token) || !valid_pct(initial_pct)) return refuse();
    return create_parents(g, open("/dev/cpuctl", DIR_FLAGS),
                          open("/sys/fs/cgroup", DIR_FLAGS), token, initial_pct);
#endif
}
/* Call only after the external owner retired all producers. A nonempty
 * group is never touched. A partial rmdir failure invalidates the handle;
 * report it and leave any remaining leaf for the trusted owner. */
int oneios_owned_groups_remove_empty(struct oneios_owned_groups *g)
{
    if (verify_groups(g) || empty_group(g->cpu) || empty_group(g->freezer)) return -1;
    if (remove_leaf_empty(g->cpu_parent, g->cpu, g->name, g->cpu_id, true)) return -1;
    int b = remove_leaf_empty(g->freezer_parent, g->freezer, g->name, g->freezer_id, false);
    int saved = errno;
    oneios_owned_groups_close(g);
    if (b) { errno = saved; return -1; }
    return 0;
}


/* Actual two-root blocked-start ownership, using only the existing
 * identity-pinned private leaves. No mutation of stock cgroups. */
#define LAUNCH_MAX_PROCS 4096u
#define LAUNCH_READY_MS 1000u

static int pid_order(const void *a, const void *b)
{
    pid_t x = *(const pid_t *)a, y = *(const pid_t *)b;
    return (x > y) - (x < y);
}
static int group_pids(int fd, pid_t *pids, unsigned *n)
{
    char buf[LAUNCH_MAX_PROCS * 12u + 1u];
    if (read_text(fd, "cgroup.procs", buf, sizeof buf)) return -1;
    unsigned count = 0;
    char *p = buf;
    while (*p) {
        char *end;
        if (count == LAUNCH_MAX_PROCS || *p < '0' || *p > '9') return invalid();
        errno = 0;
        long v = strtol(p, &end, 10);
        if (errno || v <= 0 || v > INT_MAX || *end != '\n') return invalid();
        pids[count++] = (pid_t)v;
        p = end + 1;
    }
    qsort(pids, count, sizeof *pids, pid_order);
    unsigned unique = 0; /* cgroup.procs can contain duplicate PIDs */
    for (unsigned i = 0; i < count; i++)
        if (!unique || pids[i] != pids[unique-1]) pids[unique++] = pids[i];
    *n = unique;
    return 0;
}
static int launch_live(const struct oneios_guest_child *p)
{
    if (!p || p->pid <= 0 || p->pidfd < 0) return invalid();
    struct pollfd f = { .fd = p->pidfd, .events = POLLIN };
    int n;
    do n = poll(&f, 1, 0); while (n < 0 && errno == EINTR);
    if (n < 0) return -1;
    if (n) { errno = ESRCH; return -1; }
    return 0;
}
static int launch_members(struct oneios_guest_launch *l, bool exact)
{
    if (l->owner_pid != getpid()) return refuse();
    if (oneios_owned_groups_verify(l->groups, l->groups->freeze_confirmed)) return -1;
    pid_t cpu[LAUNCH_MAX_PROCS], freezer[LAUNCH_MAX_PROCS];
    unsigned nc, nf, roots = 0;
    if (group_pids(l->groups->cpu,cpu,&nc) || group_pids(l->groups->freezer,freezer,&nf)) return -1;
    if (nc != nf || memcmp(cpu, freezer, nc * sizeof *cpu)) {
        errno = EAGAIN; return -1;
    }
    for (unsigned i = 0; i < ONEIOS_GUEST_ROOTS; i++) {
        const struct oneios_guest_child *p = &l->root[i];
        if (!p->pid) continue;
        if (launch_live(p)) return -1;
        if (!bsearch(&p->pid,cpu,nc,sizeof *cpu,pid_order)) return refuse();
        roots++;
    }
    if (exact && nc != roots) return refuse();
    return 0;
}
static int attach_created(int fd, pid_t pid)
{
#ifdef ONEIOS_OWNED_GROUPS_TEST
    /* Ordinary-file fixture models cgroup.procs append; never real cgroups. */
    int f = openat(fd,"cgroup.procs",O_WRONLY|O_APPEND|O_CLOEXEC|O_NOFOLLOW);
    if (f < 0) return -1;
    char b[32];
    int n = snprintf(b,sizeof b,"%ld\n",(long)pid);
    ssize_t got = write(f,b,(size_t)n);
    int rc = close(f);
    return got == n && !rc ? 0 : refuse();
#else
    return write_number(fd,"cgroup.procs",(long)pid);
#endif
}
static int launch_fault(struct oneios_guest_launch *l)
{
    if (l) l->phase = ONEIOS_LAUNCH_FAULT;
    return -1;
}
/* The creator must retain exclusive waitpid ownership until bootstrap
 * ends: a zombie pins its numeric PID until reaped. Reject auto-reaping
 * or an asynchronous SIGCHLD handler before any numeric cgroup write. */
static int launch_wait_owner(void)
{
    struct sigaction sa;
    if (sigaction(SIGCHLD,NULL,&sa)) return -1;
    return sa.sa_handler == SIG_DFL && !(sa.sa_flags & SA_NOCLDWAIT) ? 0 : refuse();
}
int oneios_guest_launch_init(struct oneios_guest_launch *l, struct oneios_owned_groups *g)
{
    if (!l || l->phase != ONEIOS_LAUNCH_NEW || !g) return invalid();
    l->groups = g;
    l->owner_pid=getpid();
    for (unsigned i=0;i<ONEIOS_GUEST_ROOTS;i++)
        l->root[i].gate=l->root[i].pidfd=-1;
    l->phase=ONEIOS_LAUNCH_FAULT;
    if (launch_wait_owner() || g->freeze_confirmed || oneios_owned_groups_verify(g,false) ||
        empty_group(g->cpu) || empty_group(g->freezer)) return refuse();
    l->phase=ONEIOS_LAUNCH_HELD;
    return 0;
}
/* The freshly forked child cannot run the target while the gate is held.
 * Close all descriptors except stdio, the gate, and the explicit
 * whitelist. In particular it must not inherit an earlier child's gate
 * or the parent's endpoint of a supervisor channel. No best-effort
 * fallback on a kernel without close_range. */
static int close_except(int gate,const int *fds,unsigned n)
{
#if defined(SYS_close_range)
    int keep[ONEIOS_LAUNCH_PASS_FDS+1];
    keep[0]=gate;
    for (unsigned i=0;i<n;i++) keep[i+1]=fds[i];
    for (unsigned i=1;i<=n;i++) {
        int a=keep[i]; unsigned j=i;
        while(j && keep[j-1]>a) { keep[j]=keep[j-1];j--; }
        keep[j]=a;
    }
    unsigned first=3;
    for (unsigned i=0;i<=n;i++) {
        unsigned last=(unsigned)keep[i];
        if (last<first) return invalid();
        if (last>first && syscall(SYS_close_range,first,last-1,0u)) return -1;
        first=last+1;
    }
    if (syscall(SYS_close_range,first,UINT_MAX,0u)) return -1;
    for (unsigned i=0;i<n;i++)
        if (fcntl(fds[i],F_SETFD,0)) return -1;
    return 0;
#else
    (void)gate;(void)fds;(void)n;
    errno=ENOTSUP;return -1;
#endif
}
static _Noreturn void launch_child(int gate,const char *path,char *const argv[],
                         char *const envp[],const int *fds,unsigned n)
{
    char c=0;
    if (close_except(gate,fds,n) || send(gate,"R",1,MSG_NOSIGNAL)!=1) _exit(125);
    ssize_t got;
    do got=recv(gate,&c,1,MSG_TRUNC); while(got<0 && errno==EINTR);
    if (got!=1 || c!='G') _exit(125);
    close(gate);
    execve(path,argv,envp);
    _exit(126);
}
static int wait_child_ready(const struct oneios_guest_child *p)
{
    unsigned long long start,now;
    if (boot_ms(&start)) return -1;
    struct pollfd f[]={{.fd=p->gate,.events=POLLIN},{.fd=p->pidfd,.events=POLLIN}};
    for (;;) {
        if (boot_ms(&now)) return -1;
        if (now<start || now-start>=LAUNCH_READY_MS) {errno=ETIMEDOUT;return -1;}
        int n=poll(f,2,(int)(LAUNCH_READY_MS-(now-start)));
        if (n<0) {if(errno==EINTR)continue;return -1;}
        if (!n) {errno=ETIMEDOUT;return -1;}
        if (f[1].revents || (f[0].revents&(POLLHUP|POLLERR|POLLNVAL))) return refuse();
        if (!(f[0].revents&POLLIN)) return refuse();
        char c;
        if (recv(p->gate,&c,1,MSG_DONTWAIT|MSG_TRUNC)!=1 || c!='R') return refuse();
        return launch_live(p);
    }
}
int oneios_guest_launch_hold(struct oneios_guest_launch *l,enum oneios_guest_role role,
    const char *path,char *const argv[],char *const envp[],const int *fds,unsigned n)
{
    if (!l || l->owner_pid!=getpid() || l->phase!=ONEIOS_LAUNCH_HELD || (unsigned)role>=ONEIOS_GUEST_ROOTS ||
        l->root[role].pid || !path || path[0]!='/' || !argv || !argv[0] || !envp ||
        n>ONEIOS_LAUNCH_PASS_FDS || (n && !fds)) return invalid();
    for (int i=0;i<3;i++) if (fcntl(i,F_GETFD)<0) return invalid();
    for (unsigned i=0;i<n;i++) {
        if (fds[i]<3 || fcntl(fds[i],F_GETFD)<0 || fds[i]==l->groups->cpu ||
            fds[i]==l->groups->freezer || fds[i]==l->groups->cpu_parent ||
            fds[i]==l->groups->freezer_parent) return invalid();
        for (unsigned j=0;j<ONEIOS_GUEST_ROOTS;j++)
            if (fds[i]==l->root[j].gate || fds[i]==l->root[j].pidfd) return invalid();
        for (unsigned j=0;j<i;j++) if (fds[i]==fds[j]) return invalid();
    }
    if (launch_wait_owner() || launch_members(l,true)) return launch_fault(l);
    int pair[2];
    if (socketpair(AF_UNIX,SOCK_SEQPACKET|SOCK_CLOEXEC,0,pair)) return launch_fault(l);
    pid_t pid=fork();
    if (!pid) {
        close(pair[0]);
        launch_child(pair[1],path,argv,envp,fds,n);
    }
    close(pair[1]);
    if (pid<0) {close(pair[0]);return launch_fault(l);}
    struct oneios_guest_child *p=&l->root[role];
    p->pid=pid;p->gate=pair[0];
#if defined(SYS_pidfd_open)
    p->pidfd=(int)syscall(SYS_pidfd_open,pid,0);
#else
    errno=ENOTSUP;
#endif
    if (p->pidfd<0 || wait_child_ready(p) ||
        oneios_owned_groups_verify(l->groups,false) ||
        attach_created(l->groups->cpu,pid) || launch_live(p) ||
        attach_created(l->groups->freezer,pid) || launch_members(l,true)) {
        int saved=errno;
        close(p->gate);p->gate=-1;errno=saved;
        return launch_fault(l);
    }
    return 0;
}
int oneios_guest_launch_release(struct oneios_guest_launch *l)
{
    if (!l || l->owner_pid!=getpid() || l->phase!=ONEIOS_LAUNCH_HELD) return invalid();
    for (unsigned i=0;i<ONEIOS_GUEST_ROOTS;i++)
        if (!l->root[i].pid || l->root[i].gate<0) return invalid();
    if (launch_wait_owner() || l->groups->freeze_confirmed || launch_members(l,true)) return launch_fault(l);
    for (unsigned i=0;i<ONEIOS_GUEST_ROOTS;i++) {
        struct oneios_guest_child *p=&l->root[i];
        if (launch_live(p) || send(p->gate,"G",1,MSG_DONTWAIT|MSG_NOSIGNAL)!=1)
            return launch_fault(l);
        p->released=true;
        close(p->gate);p->gate=-1;
    }
    l->phase=ONEIOS_LAUNCH_RELEASED;
    return 0;
}
int oneios_guest_launch_check_roots(struct oneios_guest_launch *l)
{
    if (!l || (l->phase!=ONEIOS_LAUNCH_HELD && l->phase!=ONEIOS_LAUNCH_RELEASED))
        return invalid();
    return launch_members(l,l->phase==ONEIOS_LAUNCH_HELD);
}
void oneios_guest_launch_close(struct oneios_guest_launch *l)
{
    if (!l || l->phase==ONEIOS_LAUNCH_NEW || l->phase==ONEIOS_LAUNCH_CLOSED) return;
    for (unsigned i=0;i<ONEIOS_GUEST_ROOTS;i++) {
        struct oneios_guest_child *p=&l->root[i];
        if (p->gate>=0) close(p->gate);
        if (p->pidfd>=0) close(p->pidfd);
        p->gate=p->pidfd=-1;
    }
    l->phase=ONEIOS_LAUNCH_CLOSED;
}
