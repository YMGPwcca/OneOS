/* Host-only fixture. No Android/cgroupfs access, no root needed. */
#define ONEIOS_OWNED_GROUPS_TEST
#include "../switcher/native/sm8850_owned_groups.c"
#include <assert.h>
#include <pthread.h>
#include <sys/wait.h>
#include <signal.h>

static const char token[] = "0123456789abcdef0123456789abcdef";
static const char leaf[] = "oneios_guest.0123456789abcdef0123456789abcdef";
static _Atomic unsigned checks;
#define CHECK(x) do { checks++; if (!(x)) { fprintf(stderr, "FAIL line %d: %s (errno=%d)\n", __LINE__, #x, errno); exit(1); } } while (0)

struct fixture {
    char root[64];
    int rootfd, cp, fp, c, f;
    struct oneios_group_id ci, fi;
    struct oneios_owned_groups g;
};

static void put(int dir, const char *name, const char *data)
{
    int fd = openat(dir, name, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
    CHECK(fd >= 0);
    CHECK(write(fd, data, strlen(data)) == (ssize_t)strlen(data));
    CHECK(close(fd) == 0);
}


/* Emulate kernel-created nodes only inside the existing host-only fixture. */
static int fixture_create_nodes(int fd, bool cpu)
{
    put(fd, "cgroup.procs", "");
    if (cpu) {
        put(fd, "cpu.cfs_period_us", "100000\n");
        put(fd, "cpu.cfs_quota_us", "-1\n");
        put(fd, "cpu.cfs_burst_us", "0\n");
    } else {
        put(fd, "cgroup.freeze", "0\n");
        put(fd, "cgroup.events", "populated 0\nfrozen 0\n");
    }
    return 0;
}
static int fixture_remove_nodes(int fd, bool cpu)
{
    if (unlinkat(fd, "cgroup.procs", 0)) return -1;
    if (cpu) {
        if (unlinkat(fd, "cpu.cfs_period_us", 0) ||
            unlinkat(fd, "cpu.cfs_quota_us", 0) ||
            unlinkat(fd, "cpu.cfs_burst_us", 0)) return -1;
    } else if (unlinkat(fd, "cgroup.freeze", 0) ||
               unlinkat(fd, "cgroup.events", 0)) return -1;
    return 0;
}
static void creator_fresh_only(void)
{
    char dir[] = "/tmp/oneios-owned-creator.XXXXXX";
    CHECK(mkdtemp(dir));
    int root = open(dir, DIR_FLAGS);
    CHECK(root >= 0);
    CHECK(!mkdirat(root, "cpu", 0700) && !mkdirat(root, "freezer", 0700));
    int cp = openat(root, "cpu", DIR_FLAGS), fp = openat(root, "freezer", DIR_FLAGS);
    CHECK(cp >= 0 && fp >= 0);
    put(cp, "cpu.cfs_quota_us", "-1\n");
    struct oneios_owned_groups g, other;
    CHECK(oneios_owned_groups_create(&other, token, 70) != 0);
    CHECK(create_parents(&other, dup(cp), dup(fp), "../bad", 70) != 0);
    CHECK(create_parents(&other, dup(cp), dup(fp), token, 0) != 0);
    CHECK(!create_parents(&g, dup(cp), dup(fp), token, 70));
    CHECK(!oneios_owned_groups_verify(&g, false));
    CHECK(!expect_number(g.cpu, "cpu.cfs_quota_us", 112000));
    CHECK(!expect_number(cp, "cpu.cfs_quota_us", -1));
    /* An existing leaf may never be adopted or removed by failed creation. */
    CHECK(create_parents(&other, dup(cp), dup(fp), token, 10) != 0);
    CHECK(!expect_number(g.cpu, "cpu.cfs_quota_us", 112000));
    put(g.freezer, "cgroup.procs", "123\n");
    CHECK(oneios_owned_groups_remove_empty(&g) != 0);
    CHECK(!expect_number(g.cpu, "cpu.cfs_quota_us", 112000));
    put(g.freezer, "cgroup.procs", "");
    CHECK(!oneios_owned_groups_remove_empty(&g));
    CHECK(g.cpu == -1 && g.freezer == -1);
    CHECK(faccessat(cp, leaf, F_OK, 0) != 0 && errno == ENOENT);
    CHECK(faccessat(fp, leaf, F_OK, 0) != 0 && errno == ENOENT);
    /* Failure on second mkdir rolls back only the newly created first leaf. */
    CHECK(!mkdirat(fp, leaf, 0700));
    CHECK(create_parents(&other, dup(cp), dup(fp), token, 70) != 0);
    CHECK(faccessat(cp, leaf, F_OK, 0) != 0 && errno == ENOENT);
    CHECK(!faccessat(fp, leaf, F_OK, 0));
    CHECK(!unlinkat(fp, leaf, AT_REMOVEDIR));
    CHECK(!expect_number(cp, "cpu.cfs_quota_us", -1));
    CHECK(!unlinkat(cp, "cpu.cfs_quota_us", 0));
    close(cp); close(fp);
    CHECK(!unlinkat(root, "cpu", AT_REMOVEDIR));
    CHECK(!unlinkat(root, "freezer", AT_REMOVEDIR));
    close(root); CHECK(!rmdir(dir));
}

static struct oneios_group_id identity(int fd)
{
    struct stat s;
    CHECK(fstat(fd, &s) == 0);
    return (struct oneios_group_id){ s.st_dev, s.st_ino };
}

static void setup(struct fixture *x)
{
    strcpy(x->root, "/tmp/oneios-owned-groups.XXXXXX");
    CHECK(mkdtemp(x->root) != NULL);
    x->rootfd = open(x->root, DIR_FLAGS);
    CHECK(x->rootfd >= 0);
    CHECK(!mkdirat(x->rootfd, "cpu", 0700) && !mkdirat(x->rootfd, "freezer", 0700));
    x->cp = openat(x->rootfd, "cpu", DIR_FLAGS);
    x->fp = openat(x->rootfd, "freezer", DIR_FLAGS);
    CHECK(x->cp >= 0 && x->fp >= 0);
    CHECK(!mkdirat(x->cp, leaf, 0700) && !mkdirat(x->fp, leaf, 0700));
    x->c = openat(x->cp, leaf, DIR_FLAGS);
    x->f = openat(x->fp, leaf, DIR_FLAGS);
    CHECK(x->c >= 0 && x->f >= 0);
    x->ci = identity(x->c); x->fi = identity(x->f);
    put(x->cp, "cpu.cfs_quota_us", "-1\n"); /* parent must never change */
    put(x->c, "cpu.cfs_period_us", "20000\n");
    put(x->c, "cpu.cfs_quota_us", "64000\n");
    put(x->c, "cpu.cfs_burst_us", "0\n");
    put(x->f, "cgroup.freeze", "0\n");
    put(x->f, "cgroup.events", "populated 1\nfrozen 0\n");
    CHECK(!bind_parents(&x->g, dup(x->cp), dup(x->fp), token, x->ci, x->fi, 40));
}

static void cleanup(struct fixture *x)
{
    oneios_owned_groups_close(&x->g);
    CHECK(!unlinkat(x->c, "cpu.cfs_period_us", 0));
    CHECK(!unlinkat(x->c, "cpu.cfs_quota_us", 0));
    CHECK(!unlinkat(x->c, "cpu.cfs_burst_us", 0));
    CHECK(!unlinkat(x->f, "cgroup.freeze", 0));
    CHECK(!unlinkat(x->f, "cgroup.events", 0));
    CHECK(!unlinkat(x->cp, "cpu.cfs_quota_us", 0));
    close(x->c); close(x->f);
    CHECK(!unlinkat(x->cp, leaf, AT_REMOVEDIR) && !unlinkat(x->fp, leaf, AT_REMOVEDIR));
    close(x->cp); close(x->fp);
    CHECK(!unlinkat(x->rootfd, "cpu", AT_REMOVEDIR));
    CHECK(!unlinkat(x->rootfd, "freezer", AT_REMOVEDIR));
    close(x->rootfd);
    CHECK(!rmdir(x->root));
}

/* Simulate the asynchronous kernel event acknowledgement, using atomic
 * replacement of ordinary fixture files. Real cgroupfs is not involved.
 */
struct ack { int fd, parent; long wanted; };
static void *acknowledge(void *arg)
{
    struct ack *a = arg;
    for (unsigned i = 0; i < 500; i++) {
        long requested;
        if (!read_number(a->fd, "cgroup.freeze", &requested) && requested == a->wanted) {
            /* Keep the temporary name outside the leaf so it cannot race
             * the production leaf scan while being renamed into place. */
            put(a->parent, "events.next", a->wanted ? "populated 1\nfrozen 1\n" : "populated 1\nfrozen 0\n");
            CHECK(!renameat(a->parent, "events.next", a->fd, "cgroup.events"));
            return NULL;
        }
        usleep(1000);
    }
    CHECK(false);
    return NULL;
}

static void happy_path(void)
{
    struct fixture x; setup(&x);
    CHECK(!oneios_owned_groups_verify(&x.g, false));
    CHECK(!oneios_owned_cpu_set(&x.g, 70));
    CHECK(!expect_number(x.c, "cpu.cfs_quota_us", 112000));
    CHECK(!oneios_owned_cpu_set(&x.g, 100));
    CHECK(!expect_number(x.c, "cpu.cfs_quota_us", 160000));
    CHECK(!oneios_owned_cpu_set(&x.g, 10));
    CHECK(!expect_number(x.c, "cpu.cfs_quota_us", 16000));
    CHECK(oneios_owned_cpu_set(&x.g, 101) != 0);
    CHECK(!expect_number(x.cp, "cpu.cfs_quota_us", -1));
    CHECK(oneios_owned_thaw(&x.g, 100) != 0);
    struct ack a = { x.f, x.fp, 1 }; pthread_t th;
    CHECK(!pthread_create(&th, NULL, acknowledge, &a));
    /* Only the acknowledgement proves frozen, not the write. */
    int rc = oneios_owned_freeze(&x.g, 1000);
    CHECK(!pthread_join(th, NULL));
    CHECK(!rc && x.g.freeze_confirmed);
    CHECK(!oneios_owned_groups_verify(&x.g, true));
    CHECK(!oneios_owned_cpu_set(&x.g, 20));
    a.wanted = 0;
    CHECK(!pthread_create(&th, NULL, acknowledge, &a));
    rc = oneios_owned_thaw(&x.g, 1000);
    CHECK(!pthread_join(th, NULL));
    CHECK(!rc && !x.g.freeze_confirmed);
    CHECK(!oneios_owned_groups_verify(&x.g, false));
    CHECK(!expect_number(x.cp, "cpu.cfs_quota_us", -1));
    cleanup(&x);
}

static void timeout_is_latched(void)
{
    struct fixture x; setup(&x);
    CHECK(oneios_owned_freeze(&x.g, 20) != 0);
    CHECK(x.g.fault && !x.g.freeze_confirmed);
    CHECK(!expect_number(x.f, "cgroup.freeze", 1));
    CHECK(oneios_owned_cpu_set(&x.g, 100) != 0);
    CHECK(oneios_owned_thaw(&x.g, 20) != 0);
    oneios_owned_groups_close(&x.g);
    CHECK(!expect_number(x.f, "cgroup.freeze", 1));
    cleanup(&x);
}

static void foreign_write_and_drift(void)
{
    struct fixture x; setup(&x);
    struct oneios_owned_groups rejected;
    struct oneios_group_id wrong = x.ci; wrong.ino++;
    CHECK(bind_parents(&rejected, dup(x.cp), dup(x.fp), token, wrong, x.fi, 40) != 0);
    CHECK(bind_parents(&rejected, dup(x.cp), dup(x.fp), "../not-a-token", x.ci, x.fi, 40) != 0);
    CHECK(!mkdirat(x.f, "foreign-child", 0700));
    CHECK(oneios_owned_freeze(&x.g, 20) != 0);
    CHECK(!expect_number(x.f, "cgroup.freeze", 0));
    CHECK(!unlinkat(x.f, "foreign-child", AT_REMOVEDIR));
    cleanup(&x);

    setup(&x);
    put(x.c, "cpu.cfs_quota_us", "80000\n");
    CHECK(oneios_owned_cpu_set(&x.g, 100) != 0 && x.g.fault);
    CHECK(!expect_number(x.c, "cpu.cfs_quota_us", 80000));
    CHECK(!expect_number(x.cp, "cpu.cfs_quota_us", -1));
    /* Fault must not suppress a freeze, but must suppress a thaw. */
    put(x.f, "cgroup.events", "populated 1\nfrozen 1\n");
    CHECK(!oneios_owned_freeze(&x.g, 100));
    CHECK(oneios_owned_thaw(&x.g, 100) != 0);
    CHECK(!expect_number(x.f, "cgroup.freeze", 1));
    cleanup(&x);
}

static void replacement_is_refused(void)
{
    struct fixture x; setup(&x);
    CHECK(!renameat(x.cp, leaf, x.cp, "retired"));
    CHECK(!mkdirat(x.cp, leaf, 0700));
    CHECK(oneios_owned_cpu_set(&x.g, 100) != 0);
    CHECK(!expect_number(x.c, "cpu.cfs_quota_us", 64000));
    CHECK(!unlinkat(x.cp, leaf, AT_REMOVEDIR));
    CHECK(!renameat(x.cp, "retired", x.cp, leaf));
    cleanup(&x);
}

static void resume_timeout_refreezes(void)
{
    struct fixture x; setup(&x);
    put(x.f, "cgroup.events", "populated 1\nfrozen 1\n");
    CHECK(!oneios_owned_freeze(&x.g, 100));
    CHECK(oneios_owned_thaw(&x.g, 20) != 0);
    CHECK(x.g.fault && !x.g.freeze_confirmed);
    CHECK(!expect_number(x.f, "cgroup.freeze", 1));
    cleanup(&x);
}

static void unexpected_freeze_latches(void)
{
    struct fixture x; setup(&x);
    put(x.f, "cgroup.freeze", "1\n");
    CHECK(oneios_owned_groups_verify(&x.g, false) != 0 && x.g.fault);
    CHECK(!expect_number(x.f, "cgroup.freeze", 1));
    CHECK(oneios_owned_thaw(&x.g, 100) != 0);
    cleanup(&x);
}


/* Real child gate/exec, simulated cgroup membership. No device or actual
 * cgroup writes. The test target cannot call the live creator. */
static void launch_fixture(void)
{
    char dir[]="/tmp/oneios-guest-launch.XXXXXX";
    CHECK(mkdtemp(dir));
    int root=open(dir,DIR_FLAGS);
    CHECK(root>=0 && !mkdirat(root,"cpu",0700) && !mkdirat(root,"freezer",0700));
    int cp=openat(root,"cpu",DIR_FLAGS),fp=openat(root,"freezer",DIR_FLAGS);
    CHECK(cp>=0 && fp>=0);
    struct oneios_owned_groups g;
    CHECK(!create_parents(&g,dup(cp),dup(fp),token,70));

    char exe[512], a[512], b[512], keep[32], omit[32];
    ssize_t len=readlink("/proc/self/exe",exe,sizeof exe-1);
    CHECK(len>0 && (size_t)len<sizeof exe-1);exe[len]=0;
    CHECK(snprintf(a,sizeof a,"%s/a",dir)>0 && snprintf(b,sizeof b,"%s/b",dir)>0);
    int fd=open("/dev/null",O_RDONLY|O_CLOEXEC), other=open("/dev/null",O_RDONLY);
    CHECK(fd>=3 && other>=3 && fd!=other);
    snprintf(keep,sizeof keep,"%d",fd);snprintf(omit,sizeof omit,"%d",other);
    char *const env[]={"PATH=/usr/bin:/bin",NULL};
    char *const aa[]={exe,"--launch-fixture-child",a,keep,omit,NULL};
    char *const bb[]={exe,"--launch-fixture-child",b,keep,omit,NULL};
    struct oneios_guest_launch l={0};
    CHECK(!oneios_guest_launch_init(&l,&g));
    CHECK(oneios_guest_launch_release(&l)!=0);
    CHECK(!oneios_guest_launch_hold(&l,ONEIOS_GUEST_XNUHOST,exe,aa,env,&fd,1));
    CHECK(l.root[ONEIOS_GUEST_XNUHOST].pid>0 && !l.root[ONEIOS_GUEST_XNUHOST].released);
    CHECK(access(a,F_OK)!=0 && errno==ENOENT);
    CHECK(oneios_guest_launch_release(&l)!=0);
    CHECK(oneios_guest_launch_hold(&l,ONEIOS_GUEST_XNUHOST,exe,aa,env,&fd,1)!=0);
    CHECK(!oneios_guest_launch_hold(&l,ONEIOS_GUEST_DISPLAY,exe,bb,env,&fd,1));
    CHECK(l.root[0].pid!=l.root[1].pid && !oneios_guest_launch_check_roots(&l));
    CHECK(access(a,F_OK)!=0 && access(b,F_OK)!=0);
    CHECK(!oneios_guest_launch_release(&l) && l.phase==ONEIOS_LAUNCH_RELEASED);
    CHECK(l.root[0].released && l.root[1].released);
    CHECK(oneios_guest_launch_release(&l)!=0);
    for(unsigned i=0;i<ONEIOS_GUEST_ROOTS;i++){
        int status;
        CHECK(waitpid(l.root[i].pid,&status,0)==l.root[i].pid);
        CHECK(WIFEXITED(status) && !WEXITSTATUS(status));
    }
    CHECK(!access(a,F_OK) && !access(b,F_OK));
    CHECK(oneios_guest_launch_check_roots(&l)!=0);
    oneios_guest_launch_close(&l);
    CHECK(l.root[0].pid>0 && l.root[0].pidfd==-1 && l.root[1].gate==-1);
    CHECK(oneios_guest_launch_init(&l,&g)!=0);
    CHECK(!unlink(a) && !unlink(b));
    /* A held child's EOF is not release. Verify unexpected PID drift is
     * rejected before the target can execute. */
    put(g.cpu,"cgroup.procs","");put(g.freezer,"cgroup.procs","");
    struct oneios_guest_launch bad={0};
    CHECK(!oneios_guest_launch_init(&bad,&g));
    CHECK(!oneios_guest_launch_hold(&bad,ONEIOS_GUEST_XNUHOST,exe,aa,env,&fd,1));
    CHECK(!oneios_guest_launch_hold(&bad,ONEIOS_GUEST_DISPLAY,exe,bb,env,&fd,1));
    /* Disagreeing group sets must not permit bootstrap. */
    put(g.freezer,"cgroup.procs","123456789\n");
    CHECK(oneios_guest_launch_release(&bad)!=0 && bad.phase==ONEIOS_LAUNCH_FAULT);
    CHECK(!bad.root[0].released && !bad.root[1].released);
    oneios_guest_launch_close(&bad);
    for(unsigned i=0;i<ONEIOS_GUEST_ROOTS;i++){
        int status;
        CHECK(waitpid(bad.root[i].pid,&status,0)==bad.root[i].pid);
        CHECK(WIFEXITED(status) && WEXITSTATUS(status)==125);
    }
    CHECK(access(a,F_OK)!=0 && access(b,F_OK)!=0);
    put(g.cpu,"cgroup.procs","");put(g.freezer,"cgroup.procs","");
    CHECK(!oneios_owned_groups_remove_empty(&g));
    close(fd);close(other);close(cp);close(fp);
    CHECK(!unlinkat(root,"cpu",AT_REMOVEDIR) && !unlinkat(root,"freezer",AT_REMOVEDIR));
    close(root);CHECK(!rmdir(dir));
}
static int launch_fixture_child(char **argv)
{
    int keep=atoi(argv[3]),omit=atoi(argv[4]);
    if (fcntl(keep,F_GETFD)<0 || fcntl(omit,F_GETFD)>=0 || errno!=EBADF) return 2;
    int fd=open(argv[2],O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600);
    return fd<0 || close(fd) ? 3 : 0;
}

int main(int argc,char **argv)
{
    if (argc==5 && !strcmp(argv[1],"--launch-fixture-child")) return launch_fixture_child(argv);
    if (argc!=1) return 2;
    alarm(30);
    launch_fixture();
    creator_fresh_only();
    unexpected_freeze_latches();
    happy_path();
    timeout_is_latched();
    foreign_write_and_drift();
    replacement_is_refused();
    resume_timeout_refreezes();
    printf("OWNED_GROUP_ACTUATOR=PASS checks=%u DEVICE_ACCESS=NONE\n", checks);
    return 0;
}
