/* Host-only assembly fixture. Real controller, mocked raw/group/provider
 * transport. No production cgroupfs, vendor HAL or Android device. */
#include "../switcher/native/sm8850_stock_session.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned checks;
#define CHECK(x) do { ++checks; if (!(x)) { fprintf(stderr, "FAIL %d: %s\n", __LINE__, #x); exit(1); } } while (0)
static const struct oneios_thermal_identity id = {
    "51ca8a7b-7fe0-4075-be5f-6a9029b8d392",
    "51ca8a7b-7fe0-4075-be5f-6a9029b8d392.123.456",
    "ee7c626acb814d92901a8672dc8169ef"
};
static bool raw_bad, member, closed, nonempty;
static int temp;
static unsigned created, removed, handles_closed;
static uint64_t now;

int oneios_raw_source_open(struct oneios_raw_source *s, const struct oneios_thermal_identity *key)
{
    memset(s, 0, sizeof *s); s->id = *key; s->ready = true; return 0;
}
int oneios_raw_source_read(struct oneios_raw_source *s, struct oneios_thermal_sample *out)
{
    if (!s->ready || raw_bad) return -1;
    now += 1000;
    *out = (struct oneios_thermal_sample){ .id=s->id, .seq=++s->seq, .ms=now,
        .cpu_mc=temp, .gpu_mc=40000, .ddr_mc=40000,
        .battery_dc=300, .lrp_dc=300, .board_ap_dc=400 };
    return 0;
}
enum oneios_thermal_result oneios_stock_source_tick(
    struct oneios_raw_source *s, struct oneios_thermal_controller *c,
    const struct oneios_thermal_native_sample *n)
{
    struct oneios_thermal_sample raw;
    return oneios_thermal_controller_tick_stock(c,
        oneios_raw_source_read(s, &raw) ? NULL : &raw, n);
}
int oneios_owned_groups_create(struct oneios_owned_groups *g, const char *token, unsigned pct)
{
    ++created;
    memset(g, 0, sizeof *g); g->cpu_pct=pct;
    snprintf(g->name,sizeof g->name,"oneios_guest.%s",token); return 0;
}
void oneios_owned_groups_close(struct oneios_owned_groups *g) { (void)g; ++handles_closed; }
int oneios_owned_groups_remove_empty(struct oneios_owned_groups *g)
{
    (void)g; if (nonempty) return -1; ++removed; return 0;
}
int oneios_owned_groups_verify(struct oneios_owned_groups *g, bool frozen)
{ return g->freeze_confirmed == frozen && !g->fault ? 0 : -1; }
int oneios_owned_cpu_set(struct oneios_owned_groups *g, unsigned pct)
{ CHECK(member); g->cpu_pct=pct; return 0; }
int oneios_owned_freeze(struct oneios_owned_groups *g, unsigned timeout)
{ CHECK(member && closed && timeout <= 2000); g->freeze_confirmed=true; return 0; }
int oneios_owned_thaw(struct oneios_owned_groups *g, unsigned timeout)
{ CHECK(member && closed && timeout <= 2000); g->freeze_confirmed=false; return 0; }
static int clock_ms(void *ctx, uint64_t *v) { (void)ctx; *v=now; return 0; }
static int verify_session(void *ctx, const struct oneios_thermal_identity *key)
{ (void)ctx; return member && !strcmp(key->token,id.token) ? 0 : -1; }
static int park(void *ctx, unsigned ms) { (void)ctx; CHECK(member && ms <= 2000); closed=true; return 0; }
static int verify_gpu(void *ctx, bool paused) { (void)ctx; return closed == paused ? 0 : -1; }
static int resume(void *ctx, unsigned ms) { (void)ctx; CHECK(member && ms <= 2000); closed=false; return 0; }
static const struct oneios_thermal_ops ops = {
    .now_ms=clock_ms, .session_verify=verify_session,
    .gpu_quiesce=park, .gpu_verify=verify_gpu, .gpu_resume=resume
};
int main(void)
{
    struct oneios_stock_session a={0}, b={0}, c={0};
    temp=45000; raw_bad=true;
    CHECK(oneios_stock_session_prepare(&a,&id,70)!=0 && !created);
    raw_bad=false;
    CHECK(oneios_stock_session_prepare(&a,&id,70)!=0);
    oneios_stock_session_close(&a);
    CHECK(!handles_closed);
    CHECK(!oneios_stock_session_prepare(&b,&id,70) && created==1);
    CHECK(oneios_stock_session_tick(&b,NULL)==ONEIOS_THERMAL_REFUSED);
    CHECK(oneios_stock_session_activate(&b,&ops,NULL,NULL)==ONEIOS_THERMAL_REFUSED);
    CHECK(b.groups_owned && !handles_closed);
    CHECK(oneios_stock_session_activate(&b,&ops,NULL,NULL)==ONEIOS_THERMAL_REFUSED);
    CHECK(!oneios_stock_session_retire_empty(&b) && removed==1);
    temp=104800; member=true;
    CHECK(!oneios_stock_session_prepare(&c,&id,70) && created==2);
    CHECK(oneios_stock_session_activate(&c,&ops,NULL,NULL)==ONEIOS_THERMAL_PAUSED);
    CHECK(c.groups.cpu_pct==10 && c.groups.freeze_confirmed && closed);
    raw_bad=true;
    CHECK(oneios_stock_session_tick(&c,NULL)==ONEIOS_THERMAL_FAULT_QUIESCED);
    CHECK(c.controller.fault && c.controller.freq_applied==0);
    nonempty=true;
    CHECK(oneios_stock_session_retire_empty(&c)!=0 && removed==1);
    CHECK(oneios_stock_session_tick(&c,NULL)==ONEIOS_THERMAL_REFUSED);
    nonempty=false;
    CHECK(!oneios_stock_session_retire_empty(&c) && removed==2);
    CHECK(oneios_stock_session_prepare(&c,&id,70)!=0);
    printf("STOCK_SESSION_ASSEMBLY=PASS checks=%u DEVICE_ACCESS=NONE\n", checks);
    return 0;
}
