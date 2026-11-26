/* Host-only controller tests. Mock providers and cgroup transport, never
 * open real cgroupfs, GPU or vendor frequency interfaces. The actual group
 * primitives have their own filesystem/ACK fixtures. */
#include "../switcher/native/sm8850_thermal_controller.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
static int now_ms(void *ctx, uint64_t *v) { *v = ((struct fixture *)ctx)->now; return 0; }
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

int main(void)
{
    normal_and_hard(); pause_and_resume(); stale_duplicate_and_wrong_session();
    failure_paths(); refusal_and_missing();
    printf("THERMAL_CONTROLLER=PASS checks=%u DEVICE_ACCESS=NONE\n", checks);
    return 0;
}
