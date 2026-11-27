/* Host-only controller tests. Mock providers and cgroup transport, never
 * open real cgroupfs, GPU or vendor frequency interfaces. The actual group
 * primitives have their own filesystem/ACK fixtures. */
#include "../switcher/native/sm8850_thermal_controller.h"
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef ONEIOS_RAW_SOURCE_TEST
#include "../switcher/native/sm8850_thermal_source.h"
#include <time.h>
#endif

static unsigned checks;
#define CHECK(x) do { checks++; if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); exit(1); } } while (0)

static const struct oneios_thermal_identity id = {
    "51ca8a7b-7fe0-4075-be5f-6a9029b8d392",
    "51ca8a7b-7fe0-4075-be5f-6a9029b8d392.123.456",
    "ee7c626acb814d92901a8672dc8169ef"
};
struct fixture {
    struct oneios_thermal_controller c;
    struct oneios_owned_groups g;
    uint64_t now;
#ifdef ONEIOS_RAW_SOURCE_TEST
    bool use_clock;
#endif
    unsigned freq;
    bool owned, gpu_closed, drain_failed, resume_failed, freeze_failed,
        freq_failed, expire_on_thaw;
    char trace[256];
    size_t used;
};
static struct fixture *active;
static void trace(struct fixture *x, char ch)
{
    CHECK(x->used + 1 < sizeof x->trace);
    x->trace[x->used++] = ch; x->trace[x->used] = 0;
}
static void clear_trace(struct fixture *x) { x->used = 0; x->trace[0] = 0; }

int oneios_owned_groups_verify(struct oneios_owned_groups *g, bool frozen)
{
    return g == &active->g && !g->fault && g->freeze_confirmed == frozen ? 0 : -1;
}
int oneios_owned_cpu_set(struct oneios_owned_groups *g, unsigned pct)
{
    CHECK(g == &active->g && active->owned);
    if (g->fault) return -1;
    trace(active, pct > g->cpu_pct ? 'C' : 'c');
    g->cpu_pct = pct;
    return 0;
}
int oneios_owned_freeze(struct oneios_owned_groups *g, unsigned ms)
{
    CHECK(g == &active->g && active->owned && ms <= 2000);
    trace(active, 'F');
    if (active->freeze_failed) { g->fault = true; return -1; }
    g->freeze_confirmed = true;
    return 0;
}
int oneios_owned_thaw(struct oneios_owned_groups *g, unsigned ms)
{
    CHECK(g == &active->g && active->owned && ms <= 2000 && active->gpu_closed);
    trace(active, 'T');
    if (g->fault || !g->freeze_confirmed) return -1;
    g->freeze_confirmed = false;
    if (active->expire_on_thaw) active->now += 3000;
    return 0;
}
static int now_ms(void *ctx, uint64_t *v)
{
#ifdef ONEIOS_RAW_SOURCE_TEST
    if (((struct fixture *)ctx)->use_clock) {
        struct timespec t;
        if (clock_gettime(CLOCK_BOOTTIME,&t)) return -1;
        *v=(uint64_t)t.tv_sec*1000+(uint64_t)t.tv_nsec/1000000;
        return 0;
    }
#endif
    *v=((struct fixture *)ctx)->now; return 0;
}
static int session(void *ctx, const struct oneios_thermal_identity *key)
{
    return ((struct fixture *)ctx)->owned && !strcmp(key->token, id.token) &&
        !strcmp(key->generation, id.generation) && !strcmp(key->boot, id.boot) ? 0 : -1;
}
static int verify_freq(void *ctx, unsigned pct)
{
    struct fixture *x = ctx;
    return x->owned && x->freq == pct ? 0 : -1;
}
static int set_freq(void *ctx, unsigned pct)
{
    struct fixture *x = ctx;
    CHECK(x->owned);
    trace(x, pct > x->freq ? 'V' : 'v');
    if (x->freq_failed) return -1;
    x->freq = pct; return 0;
}
static int quiesce(void *ctx, unsigned ms)
{
    struct fixture *x = ctx;
    CHECK(x->owned && ms <= 2000);
    trace(x, 'Q');
    if (x->drain_failed) return -1;
    x->gpu_closed = true; return 0;
}
static int verify_gpu(void *ctx, bool paused)
{
    return ((struct fixture *)ctx)->gpu_closed == paused ? 0 : -1;
}
static int resume(void *ctx, unsigned ms)
{
    struct fixture *x = ctx;
    CHECK(x->owned && !x->g.freeze_confirmed && x->gpu_closed && ms <= 2000);
    trace(x, 'R');
    if (x->resume_failed) return -1;
    x->gpu_closed = false; return 0;
}
static const struct oneios_thermal_ops ops = {
    now_ms, session, verify_freq, set_freq, quiesce, verify_gpu, resume
};
static void setup(struct fixture *x)
{
    memset(x, 0, sizeof *x); active = x;
    x->owned = true; x->freq = x->g.cpu_pct = 70;
    snprintf(x->g.name, sizeof x->g.name, "oneios_guest.%s", id.token);
    CHECK(!oneios_thermal_controller_init(&x->c, &x->g, &id, &ops, x, 70, 20));
    CHECK(!x->used);
}
static struct oneios_thermal_sample sample(uint64_t seq, int temp)
{
    return (struct oneios_thermal_sample){
        .id = id, .seq = seq, .ms = seq * 1000, .cpu_mc = temp,
        .gpu_mc = 40000, .ddr_mc = 40000, .battery_dc = 300,
        .lrp_dc = 300, .board_ap_dc = 400
    };
}
static enum oneios_thermal_result tick(struct fixture *x, uint64_t seq, int temp)
{
    struct oneios_thermal_sample s = sample(seq, temp);
    x->now = s.ms;
    return oneios_thermal_controller_tick(&x->c, &s);
}
static void normal_and_hard(void)
{
    struct fixture x; setup(&x);
    for (unsigned i = 1; i <= 20; i++) CHECK(tick(&x, i, 44000) == ONEIOS_THERMAL_RUNNING);
    CHECK(x.freq == 100 && x.g.cpu_pct == 100);
    clear_trace(&x);
    CHECK(tick(&x, 21, 70000) == ONEIOS_THERMAL_RUNNING);
    CHECK(x.freq == 90 && x.g.cpu_pct == 90 && !strcmp(x.trace, "cv"));
    CHECK(tick(&x, 22, 80000) == ONEIOS_THERMAL_RUNNING);
    CHECK(x.freq == 20 && x.g.cpu_pct == 10 && x.c.policy.hard);
    CHECK(tick(&x, 23, 70001) == ONEIOS_THERMAL_RUNNING && x.c.policy.hard);
    CHECK(tick(&x, 24, 70000) == ONEIOS_THERMAL_RUNNING && !x.c.policy.hard);
    CHECK(x.freq == 20 && x.g.cpu_pct == 10);
}
static void pause_and_resume(void)
{
    struct fixture x; setup(&x);
    CHECK(tick(&x, 1, 90000) == ONEIOS_THERMAL_PAUSED);
    CHECK(!strcmp(x.trace, "cvQF"));
    CHECK(x.freq == 20 && x.g.cpu_pct == 10 && x.g.freeze_confirmed && x.gpu_closed);
    clear_trace(&x);
    for (unsigned i = 2; i < 6; i++) CHECK(tick(&x, i, 65000) == ONEIOS_THERMAL_PAUSED);
    CHECK(!x.used);
    CHECK(tick(&x, 6, 65000) == ONEIOS_THERMAL_RUNNING);
    CHECK(!strcmp(x.trace, "TR") && !x.g.freeze_confirmed && !x.gpu_closed);
    CHECK(x.freq == 20 && x.g.cpu_pct == 10);
}
static void stale_duplicate_and_wrong_session(void)
{
    struct fixture x; setup(&x);
    CHECK(tick(&x, 1, 44000) == ONEIOS_THERMAL_RUNNING);
    struct oneios_thermal_sample s = sample(1, 44000);
    x.now = 2000;
    CHECK(oneios_thermal_controller_tick(&x.c, &s) == ONEIOS_THERMAL_RUNNING);
    CHECK(!x.used);
    x.now = 3001;
    CHECK(oneios_thermal_controller_tick(&x.c, &s) == ONEIOS_THERMAL_FAULT_QUIESCED);
    clear_trace(&x);
    CHECK(tick(&x, 4, 44000) == ONEIOS_THERMAL_FAULT_QUIESCED && !x.used);

    setup(&x);
    CHECK(tick(&x, 1, 44000) == ONEIOS_THERMAL_RUNNING);
    s.cpu_mc = 80000; x.now = 1000;
    CHECK(oneios_thermal_controller_tick(&x.c, &s) == ONEIOS_THERMAL_FAULT_QUIESCED);

    setup(&x);
    x.owned = false;
    CHECK(tick(&x, 1, 90000) == ONEIOS_THERMAL_FAULT_UNCONFIRMED && !x.used);

    setup(&x); s = sample(1, 44000); s.id.token[0] = 'a'; x.now = s.ms;
    CHECK(oneios_thermal_controller_tick(&x.c, &s) == ONEIOS_THERMAL_FAULT_QUIESCED);
}
static void failure_paths(void)
{
    struct fixture x; setup(&x); x.drain_failed = true;
    CHECK(tick(&x, 1, 90000) == ONEIOS_THERMAL_FAULT_UNCONFIRMED);
    CHECK(x.g.freeze_confirmed && !x.gpu_closed);
    clear_trace(&x);
    CHECK(tick(&x, 2, 40000) == ONEIOS_THERMAL_FAULT_UNCONFIRMED && !x.used);

    setup(&x); x.freeze_failed = true;
    CHECK(tick(&x, 1, 90000) == ONEIOS_THERMAL_FAULT_UNCONFIRMED);
    CHECK(!x.g.freeze_confirmed && x.gpu_closed);

    setup(&x); x.freq = 90; /* readback drift: no write against an unverified vote */
    CHECK(tick(&x, 1, 44000) == ONEIOS_THERMAL_FAULT_QUIESCED);
    CHECK(x.freq == 90 && !strchr(x.trace, 'v') && !strchr(x.trace, 'V'));

    setup(&x); x.freq_failed = true;
    CHECK(tick(&x, 1, 80000) == ONEIOS_THERMAL_FAULT_QUIESCED);
    CHECK(x.g.freeze_confirmed && x.freq == 70);

    for (unsigned kind = 0; kind < 2; kind++) {
        setup(&x);
        CHECK(tick(&x, 1, 90000) == ONEIOS_THERMAL_PAUSED);
        for (unsigned i = 2; i < 6; i++) CHECK(tick(&x, i, 65000) == ONEIOS_THERMAL_PAUSED);
        x.resume_failed = kind == 0; x.expire_on_thaw = kind == 1;
        clear_trace(&x);
        CHECK(tick(&x, 6, 65000) == ONEIOS_THERMAL_FAULT_QUIESCED);
        CHECK(x.g.freeze_confirmed && x.gpu_closed);
        CHECK(strchr(x.trace, 'T') && strchr(x.trace, 'F'));
        if (kind) CHECK(!strchr(x.trace, 'R'));
    }
}
static void refusal_and_missing(void)
{
    struct fixture x; setup(&x);
    struct oneios_thermal_controller c;
    struct oneios_thermal_ops incomplete = ops; incomplete.frequency_set = NULL;
    CHECK(oneios_thermal_controller_init(&c, &x.g, &id, &incomplete, &x, 70, 20) != 0);
    CHECK(oneios_thermal_controller_tick(&c, NULL) == ONEIOS_THERMAL_REFUSED);
    CHECK(!x.used);
    CHECK(oneios_thermal_controller_tick(&x.c, NULL) == ONEIOS_THERMAL_FAULT_QUIESCED);
}

static void setup_stock(struct fixture *x)
{
    memset(x, 0, sizeof *x); active = x;
    x->owned = true; x->freq = 73; x->g.cpu_pct = 100;
    snprintf(x->g.name, sizeof x->g.name, "oneios_guest.%s", id.token);
    struct oneios_thermal_ops stock = ops;
    stock.frequency_verify = NULL; stock.frequency_set = NULL;
    CHECK(!oneios_thermal_controller_init_stock(&x->c, &x->g, &id, &stock, x));
    CHECK(x->c.stock_managed && !x->c.freq_applied && !x->used);
}
static enum oneios_thermal_result stock_tick(struct fixture *x, uint64_t seq, int temp, int sev)
{
    struct oneios_thermal_sample raw = sample(seq, temp);
    struct oneios_thermal_native_sample native = {id, seq, raw.ms, sev};
    x->now = raw.ms;
    return oneios_thermal_controller_tick_stock(&x->c, &raw, sev < 0 ? NULL : &native);
}
static void stock_native_and_raw(void)
{
    struct fixture x; setup_stock(&x);
    CHECK(stock_tick(&x, 1, 65000, 2) == ONEIOS_THERMAL_RUNNING);
    CHECK(x.g.cpu_pct == 60 && x.freq == 73 && !strcmp(x.trace, "c"));
    CHECK(stock_tick(&x, 2, 65000, 3) == ONEIOS_THERMAL_RUNNING);
    CHECK(x.g.cpu_pct == 25 && x.freq == 73);
    CHECK(stock_tick(&x, 3, 80000, 0) == ONEIOS_THERMAL_RUNNING);
    CHECK(x.g.cpu_pct == 10 && x.c.policy.hard && x.freq == 73);
    CHECK(stock_tick(&x, 4, 70001, 0) == ONEIOS_THERMAL_RUNNING && x.c.policy.hard);
    CHECK(stock_tick(&x, 5, 70000, 0) == ONEIOS_THERMAL_RUNNING && !x.c.policy.hard);
    clear_trace(&x);
    for (unsigned i=6; i<22; i++) CHECK(stock_tick(&x, i, 45000, -1) == ONEIOS_THERMAL_RUNNING);
    CHECK(x.g.cpu_pct == 10 && !x.used); // HAL loss cannot authorize recovery.
    for (unsigned i=22; i<=60; i++) CHECK(stock_tick(&x, i, 44000, 0) == ONEIOS_THERMAL_RUNNING);
    CHECK(x.g.cpu_pct > 40 && x.freq == 73 && !strchr(x.trace,'V') && !strchr(x.trace,'v'));

    setup_stock(&x);
    CHECK(stock_tick(&x, 1, 95000, -1) == ONEIOS_THERMAL_PAUSED);
    CHECK(x.g.cpu_pct == 10 && !strcmp(x.trace, "cQF"));
    clear_trace(&x);
    for (unsigned i=2; i<=10; i++) CHECK(stock_tick(&x, i, 64000, -1) == ONEIOS_THERMAL_PAUSED);
    CHECK(!x.used);
    for (unsigned i=11; i<15; i++) CHECK(stock_tick(&x, i, 64000, 0) == ONEIOS_THERMAL_PAUSED);
    CHECK(stock_tick(&x, 15, 64000, 0) == ONEIOS_THERMAL_RUNNING);
    CHECK(!strcmp(x.trace, "TR") && x.freq == 73);

    setup_stock(&x);
    CHECK(stock_tick(&x, 1, 55000, 4) == ONEIOS_THERMAL_PAUSED);
    CHECK(x.g.cpu_pct == 10 && x.freq == 73 && !strcmp(x.trace,"cQF"));
    CHECK(stock_tick(&x, 2, 55000, 3) == ONEIOS_THERMAL_PAUSED);
    CHECK(oneios_thermal_controller_tick(&x.c, NULL) == ONEIOS_THERMAL_FAULT_QUIESCED);
    CHECK(x.freq == 73);
}
static void stock_identity_and_refusal(void)
{
    struct fixture x; setup_stock(&x);
    struct oneios_thermal_controller c;
    struct oneios_thermal_ops mixed = ops;
    CHECK(oneios_thermal_controller_init_stock(&c, &x.g, &id, &mixed, &x) != 0);
    mixed.frequency_set = NULL;
    CHECK(oneios_thermal_controller_init_stock(&c, &x.g, &id, &mixed, &x) != 0);
    CHECK(stock_tick(&x, 1, 65000, 3) == ONEIOS_THERMAL_RUNNING);
    clear_trace(&x);
    for (uint64_t i=2; i<20; i++) {
        struct oneios_thermal_sample raw = sample(i, 44000);
        struct oneios_thermal_native_sample stale = {id, 1, 1000, 0};
        x.now = raw.ms;
        CHECK(oneios_thermal_controller_tick_stock(&x.c, &raw, &stale) == ONEIOS_THERMAL_RUNNING);
    }
    CHECK(x.g.cpu_pct == 25 && !x.used); // stale or conflicting native replay
    struct oneios_thermal_sample hot = sample(20, 80000);
    struct oneios_thermal_native_sample wrong = {id,20,hot.ms,0};
    wrong.id.token[0] = 'a'; x.now = hot.ms;
    CHECK(oneios_thermal_controller_tick_stock(&x.c, &hot, &wrong) == ONEIOS_THERMAL_RUNNING);
    CHECK(x.g.cpu_pct == 10 && x.freq == 73);
    CHECK(oneios_thermal_controller_tick(&x.c, NULL) == ONEIOS_THERMAL_FAULT_QUIESCED);
    CHECK(x.freq == 73 && !strchr(x.trace,'v') && !strchr(x.trace,'V'));
    setup(&x);
    CHECK(oneios_thermal_controller_tick_stock(&x.c, &hot, &wrong) == ONEIOS_THERMAL_REFUSED);
}

#ifdef ONEIOS_RAW_SOURCE_TEST
static void fixture_write(const char *root,const char *rel,const char *value)
{
    char path[1024];
    int n=snprintf(path,sizeof path,"%s%s",root,rel);
    CHECK(n>0 && (size_t)n<sizeof path);
    FILE *f=fopen(path,"w"); CHECK(f);
    CHECK(fputs(value,f)>=0 && fclose(f)==0);
}
static void stock_source_fixture(const char *root)
{
    struct fixture x; setup_stock(&x); x.use_clock=true;
    struct oneios_raw_source src;
    struct oneios_thermal_sample s={0};
    CHECK(oneios_raw_source_open(&src,&id)!=0);
    CHECK(!oneios_raw_source_fixture(&src,&id,root));
    CHECK(!oneios_raw_source_read(&src,&s) && s.seq==1 &&
          s.cpu_mc==45000 && s.gpu_mc==42000 && s.ddr_mc==40000 &&
          s.battery_dc==300 && s.lrp_dc==300 && s.board_ap_dc==400);
    CHECK(oneios_stock_source_tick(&src,&x.c,NULL)==ONEIOS_THERMAL_RUNNING);
    CHECK(x.g.cpu_pct==100 && x.freq==73 && !x.used);
    fixture_write(root,"/sys/class/thermal/thermal_zone2/temp","80000\n");
    CHECK(oneios_stock_source_tick(&src,&x.c,NULL)==ONEIOS_THERMAL_RUNNING);
    CHECK(x.g.cpu_pct==10 && x.c.policy.hard && x.freq==73);
    fixture_write(root,"/sys/class/thermal/thermal_zone2/temp","104800\n");
    CHECK(oneios_stock_source_tick(&src,&x.c,NULL)==ONEIOS_THERMAL_PAUSED);
    CHECK(x.g.freeze_confirmed && x.gpu_closed && x.freq==73);
    uint64_t seq=src.seq;
    fixture_write(root,"/sys/class/thermal/thermal_zone2/type","cpu-wrong\n");
    CHECK(oneios_raw_source_read(&src,&s)!=0 && src.seq==seq);
    CHECK(oneios_stock_source_tick(&src,&x.c,NULL)==ONEIOS_THERMAL_FAULT_QUIESCED);
    CHECK(x.g.freeze_confirmed && x.gpu_closed && x.freq==73);
    fixture_write(root,"/sys/class/thermal/thermal_zone2/type","cpu-1\n");
    fixture_write(root,"/sys/class/thermal/thermal_zone2/temp","45000\n45000\n");
    CHECK(oneios_raw_source_read(&src,&s)!=0 && src.seq==seq);
    fixture_write(root,"/sys/class/thermal/thermal_zone2/temp","45000\n");
    fixture_write(root,"/proc/sys/kernel/random/boot_id","wrong\n");
    CHECK(oneios_raw_source_read(&src,&s)!=0 && src.seq==seq);
    fixture_write(root,"/proc/sys/kernel/random/boot_id","51ca8a7b-7fe0-4075-be5f-6a9029b8d392\n");
    const char *manifest="/data/adb/oneios-m3q-framework/thermal.guard.manifest";
    fixture_write(root,manifest,"v1 51ca8a7b-7fe0-4075-be5f-6a9029b8d392 3\nz 2 cpu-1 cpu\nz 2 gpuss-0 gpu\nz 4 ddr ddr\n");
    CHECK(oneios_raw_source_fixture(&src,&id,root)!=0 && !src.ready);
    printf("STOCK_SOURCE_CONTROLLER=PASS checks=%u DEVICE_ACCESS=NONE\n",checks);
}
#endif

/* Batch interface used ONLY by the host parity test. A trajectory starts
 * with three explicit budgets, followed by valid sample rows. */
static int policy_trace(void)
{
    struct oneios_thermal_policy p = {0};
    if (scanf("%u %u %u", &p.freq_pct, &p.cpu_pct, &p.floor_pct) != 3) return 2;
    struct oneios_thermal_sample s = {0};
    int n;
    while ((n = scanf("%" SCNu64 " %" SCNu64 " %d %d %d %d %d %d",
                     &s.seq, &s.ms, &s.cpu_mc, &s.gpu_mc, &s.ddr_mc,
                     &s.battery_dc, &s.lrp_dc, &s.board_ap_dc)) == 8) {
        enum oneios_thermal_action a = oneios_thermal_policy_step(&p, &s);
        const char *label;
        switch (a) {
        case ONEIOS_THERMAL_DUPLICATE: label = "NO_NEW_SAMPLE"; break;
        case ONEIOS_THERMAL_COOL: label = "COOL"; break;
        case ONEIOS_THERMAL_HOLD: label = "HOLD"; break;
        case ONEIOS_THERMAL_SOFT: label = "SOFT"; break;
        case ONEIOS_THERMAL_HARD: label = "HARD"; break;
        case ONEIOS_THERMAL_RECOVERY_MINIMUM: label = "RECOVERY_MINIMUM"; break;
        case ONEIOS_THERMAL_QUIESCE: label = "QUIESCE_TEMPERATURE"; break;
        case ONEIOS_THERMAL_RESUME_MINIMUM: label = "RESUME_MINIMUM"; break;
        default: return 2;
        }
        printf("%s %u %u %d %d %u %" PRIu64 " %" PRIu64 " %" PRIu64 "\n",
            label, p.freq_pct, p.cpu_pct, (int)p.hard, (int)p.paused,
            p.cool_samples, p.last_seq, p.last_ms, p.last_change_ms);
    }
    return n == EOF ? 0 : 2;
}

int main(int argc, char **argv)
{
#ifdef ONEIOS_RAW_SOURCE_TEST
    if (argc == 3 && !strcmp(argv[1],"--source-fixture")) {
        stock_source_fixture(argv[2]); return 0;
    }
#endif
    if (argc == 2 && !strcmp(argv[1], "--policy")) return policy_trace();
    if (argc != 1) return 2;
    normal_and_hard(); pause_and_resume(); stale_duplicate_and_wrong_session();
    failure_paths(); refusal_and_missing();
    stock_native_and_raw(); stock_identity_and_refusal();
    printf("THERMAL_CONTROLLER=PASS checks=%u DEVICE_ACCESS=NONE\n", checks);
    return 0;
}
