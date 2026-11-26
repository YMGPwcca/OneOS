/* SPDX-License-Identifier: MIT */
#include "sm8850_thermal_controller.h"
#include <errno.h>
#include <stdio.h>
#include <string.h>

static unsigned min_u(unsigned a, unsigned b) { return a < b ? a : b; }
static unsigned max_u(unsigned a, unsigned b) { return a > b ? a : b; }
static unsigned decrease(unsigned value, unsigned delta, unsigned floor)
{
    return value <= floor + delta ? floor : value - delta;
}
static bool pct_valid(unsigned p) { return p >= 10 && p <= 100; }
static bool bounded_string(const char *s, size_t n)
{
    return s && s[0] && memchr(s, 0, n) != NULL;
}
static bool identity_valid(const struct oneios_thermal_identity *id)
{
    if (!id || !bounded_string(id->boot, sizeof id->boot) ||
        !bounded_string(id->generation, sizeof id->generation) ||
        !bounded_string(id->token, sizeof id->token) ||
        strlen(id->boot) != 36 || strlen(id->token) != 32 ||
        strspn(id->token, "0123456789abcdef") != 32) return false;
    for (unsigned i = 0; i < 36; i++) {
        char c = id->boot[i];
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            if (c != '-') return false;
        } else if (!strchr("0123456789abcdef", c)) return false;
    }
    return strspn(id->generation, "0123456789abcdef.-") == strlen(id->generation);
}
static bool identity_equal(const struct oneios_thermal_identity *a,
                           const struct oneios_thermal_identity *b)
{
    return identity_valid(a) && identity_valid(b) &&
        !strcmp(a->boot, b->boot) && !strcmp(a->generation, b->generation) &&
        !strcmp(a->token, b->token);
}
static bool sample_valid(const struct oneios_thermal_sample *s)
{
    return s && s->seq && s->cpu_mc > 0 && s->cpu_mc <= 200000 &&
        s->gpu_mc > 0 && s->gpu_mc <= 200000 && s->ddr_mc > 0 &&
        s->ddr_mc <= 200000 && s->battery_dc > 0 && s->battery_dc <= 1500 &&
        s->lrp_dc > 0 && s->lrp_dc <= 1500 &&
        s->board_ap_dc > 0 && s->board_ap_dc <= 1500;
}
static unsigned auxiliary(const struct oneios_thermal_sample *s)
{
    static const int limits[][4] = {
        {340,370,450,40}, {370,400,500,28}, {400,430,550,18},
        {420,450,600,12}, {440,470,650,10}
    };
    unsigned cap = 100;
    for (unsigned i = 0; i < sizeof limits / sizeof limits[0]; i++)
        if (s->battery_dc >= limits[i][0] || s->lrp_dc >= limits[i][1] ||
            s->board_ap_dc >= limits[i][2]) cap = (unsigned)limits[i][3];
    return cap;
}
enum oneios_thermal_action oneios_thermal_policy_step(
    struct oneios_thermal_policy *p, const struct oneios_thermal_sample *s)
{
    if (!p || !sample_valid(s) || !pct_valid(p->floor_pct) ||
        !pct_valid(p->cpu_pct) || !pct_valid(p->freq_pct) ||
        p->freq_pct < p->floor_pct || s->seq < p->last_seq ||
        s->ms < p->last_ms) return ONEIOS_THERMAL_INVALID;
    if (s->seq == p->last_seq) return ONEIOS_THERMAL_DUPLICATE;
    if (!p->last_seq) p->last_change_ms = s->ms;
    p->last_seq = s->seq; p->last_ms = s->ms;
    unsigned peak = max_u((unsigned)s->cpu_mc,
                         max_u((unsigned)s->gpu_mc, (unsigned)s->ddr_mc));
    unsigned aux = auxiliary(s);
    bool severe = s->cpu_mc >= 90000 || s->gpu_mc >= 95000 ||
        s->ddr_mc >= 95000 || s->battery_dc >= 480 ||
        s->lrp_dc >= 500 || s->board_ap_dc >= 700;
    if (severe) {
        p->freq_pct = p->floor_pct; p->cpu_pct = 10;
        p->hard = p->paused = true; p->cool_samples = 0;
        p->last_change_ms = s->ms;
        return ONEIOS_THERMAL_QUIESCE;
    }
    if (p->paused) {
        bool cool = peak <= 70000 && aux == 100;
        p->cool_samples = cool ? min_u(p->cool_samples + 1, 5) : 0;
        if (!cool) p->last_change_ms = s->ms;
        if (p->cool_samples >= 5 && s->ms - p->last_change_ms >= 5000) {
            p->paused = p->hard = false; p->cool_samples = 0;
            p->last_change_ms = s->ms;
            return ONEIOS_THERMAL_RESUME_MINIMUM;
        }
        return ONEIOS_THERMAL_QUIESCE;
    }
    if (peak >= 80000 || (p->hard && peak > 70000)) {
        p->freq_pct = p->floor_pct; p->cpu_pct = 10;
        p->hard = true; p->cool_samples = 0; p->last_change_ms = s->ms;
        return ONEIOS_THERMAL_HARD;
    }
    if (p->hard) {
        p->hard = false; p->cool_samples = 0; p->last_change_ms = s->ms;
        return ONEIOS_THERMAL_RECOVERY_MINIMUM;
    }
    unsigned f = p->freq_pct, q = p->cpu_pct, count = 0;
    enum oneios_thermal_action a;
    if (peak >= 70000) {
        unsigned reduction = peak >= 75000 ? 20 : 10;
        f = decrease(f, reduction, p->floor_pct); q = decrease(q, reduction, 10);
        a = ONEIOS_THERMAL_SOFT;
    } else if (peak >= 65000) {
        a = ONEIOS_THERMAL_HOLD;
    } else {
        a = ONEIOS_THERMAL_COOL;
        count = min_u(p->cool_samples + 1, 5);
        if (count >= 5 && s->ms - p->last_change_ms >= 5000) {
            unsigned inc = peak < 45000 ? 10 : 5;
            f = min_u(100, f + inc); q = min_u(100, q + inc); count = 0;
        }
    }
    f = min_u(f, max_u(p->floor_pct, aux)); q = min_u(q, aux);
    if (a != ONEIOS_THERMAL_COOL || f != p->freq_pct || q != p->cpu_pct) {
        p->last_change_ms = s->ms; count = 0;
    }
    p->freq_pct = f; p->cpu_pct = q; p->cool_samples = count;
    return a;
}

static bool session_ok(struct oneios_thermal_controller *c)
{
    return c->ops.session_verify(c->ctx, &c->id) == 0;
}
static bool fresh(struct oneios_thermal_controller *c,
                  const struct oneios_thermal_sample *s)
{
    uint64_t now;
    return sample_valid(s) && identity_equal(&c->id, &s->id) &&
        session_ok(c) && !c->ops.now_ms(c->ctx, &now) &&
        now >= s->ms && now - s->ms <= ONEIOS_THERMAL_MAX_SAMPLE_AGE_MS;
}
static bool same_sample(const struct oneios_thermal_sample *a,
                        const struct oneios_thermal_sample *b)
{
    return identity_equal(&a->id, &b->id) && a->seq == b->seq && a->ms == b->ms &&
        a->cpu_mc == b->cpu_mc && a->gpu_mc == b->gpu_mc && a->ddr_mc == b->ddr_mc &&
        a->battery_dc == b->battery_dc && a->lrp_dc == b->lrp_dc &&
        a->board_ap_dc == b->board_ap_dc;
}
static bool healthy(struct oneios_thermal_controller *c, bool paused)
{
    return session_ok(c) && !oneios_owned_groups_verify(c->groups, paused) &&
        !c->ops.frequency_verify(c->ctx, c->freq_applied) &&
        !c->ops.gpu_verify(c->ctx, paused);
}
static int set_freq(struct oneios_thermal_controller *c, unsigned pct)
{
    if (!session_ok(c) || c->ops.frequency_verify(c->ctx, c->freq_applied))
        return -1;
    if (pct == c->freq_applied) return 0;
    if (c->ops.frequency_set(c->ctx, pct) ||
        c->ops.frequency_verify(c->ctx, pct)) return -1;
    c->freq_applied = pct;
    return 0;
}
static int set_cpu(struct oneios_thermal_controller *c, unsigned pct)
{
    return session_ok(c) ? oneios_owned_cpu_set(c->groups, pct) : -1;
}

/* Failure is NOT a reboot request. Try bounded reductions/quiesce only
 * while the current session remains owned. A failed GPU drain does not
 * prevent an attempted CPU freeze, but the result stays UNCONFIRMED.
 * Never issue a second automatic thaw or an increase after a fault. */
static enum oneios_thermal_result fault(struct oneios_thermal_controller *c)
{
    if (c->fault) return c->fault_result;
    c->fault = true;
    c->fault_result = ONEIOS_THERMAL_FAULT_UNCONFIRMED;
    if (!session_ok(c)) return c->fault_result;
    (void)set_cpu(c, 10);
    (void)set_freq(c, c->policy.floor_pct);
    if (!session_ok(c)) return c->fault_result;
    bool drained = c->ops.gpu_quiesce(c->ctx, ONEIOS_THERMAL_ACK_MS) == 0;
    bool frozen = session_ok(c) &&
        oneios_owned_freeze(c->groups, ONEIOS_THERMAL_ACK_MS) == 0;
    if (drained && frozen && session_ok(c) &&
        !c->ops.gpu_verify(c->ctx, true))
        c->fault_result = ONEIOS_THERMAL_FAULT_QUIESCED;
    return c->fault_result;
}

int oneios_thermal_controller_init(struct oneios_thermal_controller *c,
    struct oneios_owned_groups *g, const struct oneios_thermal_identity *id,
    const struct oneios_thermal_ops *ops, void *ctx,
    unsigned initial_freq_pct, unsigned qualified_floor_pct)
{
    if (!c) { errno = EINVAL; return -1; }
    memset(c, 0, sizeof *c);
    if (!g || !identity_valid(id) || !ops || !ops->now_ms || !ops->session_verify ||
        !ops->frequency_verify || !ops->frequency_set || !ops->gpu_quiesce ||
        !ops->gpu_verify || !ops->gpu_resume || !pct_valid(g->cpu_pct) ||
        !pct_valid(initial_freq_pct) || !pct_valid(qualified_floor_pct) ||
        initial_freq_pct < qualified_floor_pct) { errno = EINVAL; return -1; }
    char group[sizeof g->name];
    snprintf(group, sizeof group, "oneios_guest.%s", id->token);
    if (!memchr(g->name, 0, sizeof g->name) || strcmp(group, g->name)) {
        errno = EPERM; return -1;
    }
    c->groups = g; c->id = *id; c->ops = *ops; c->ctx = ctx;
    c->freq_applied = initial_freq_pct;
    c->policy = (struct oneios_thermal_policy){
        .freq_pct = initial_freq_pct, .cpu_pct = g->cpu_pct, .floor_pct = qualified_floor_pct
    };
    if (!healthy(c, false)) { errno = EPERM; return -1; }
    c->ready = true;
    return 0;
}

enum oneios_thermal_result oneios_thermal_controller_tick(
    struct oneios_thermal_controller *c, const struct oneios_thermal_sample *s)
{
    if (!c || !c->ready) return ONEIOS_THERMAL_REFUSED;
    if (c->fault) return c->fault_result;
    if (!fresh(c, s) || !healthy(c, c->paused)) return fault(c);
    if (s->seq == c->policy.last_seq && !same_sample(s, &c->last)) return fault(c);
    struct oneios_thermal_policy next = c->policy;
    enum oneios_thermal_action action = oneios_thermal_policy_step(&next, s);
    if (action == ONEIOS_THERMAL_INVALID) return fault(c);
    if (action == ONEIOS_THERMAL_DUPLICATE)
        return c->paused ? ONEIOS_THERMAL_PAUSED : ONEIOS_THERMAL_RUNNING;

    /* Apply all reductions before any relaxation. Recheck freshness and
     * ownership immediately before each increase or resume. */
    if (next.cpu_pct < c->groups->cpu_pct && set_cpu(c, next.cpu_pct)) return fault(c);
    if (next.freq_pct < c->freq_applied && set_freq(c, next.freq_pct)) return fault(c);
    if (next.freq_pct > c->freq_applied &&
        (!fresh(c, s) || set_freq(c, next.freq_pct))) return fault(c);
    if (next.cpu_pct > c->groups->cpu_pct &&
        (!fresh(c, s) || set_cpu(c, next.cpu_pct))) return fault(c);

    if (next.paused && !c->paused) {
        /* Stop submissions and drain first; freezing a worker required for
         * completion can deadlock the drain. ACK of CPU freeze is separate. */
        if (!session_ok(c) || c->ops.gpu_quiesce(c->ctx, ONEIOS_THERMAL_ACK_MS) ||
            !session_ok(c) || oneios_owned_freeze(c->groups, ONEIOS_THERMAL_ACK_MS))
            return fault(c);
        c->paused = true;
    } else if (!next.paused && c->paused) {
        if (action != ONEIOS_THERMAL_RESUME_MINIMUM ||
            next.cpu_pct != 10 || next.freq_pct != next.floor_pct ||
            !fresh(c, s) || !healthy(c, true) ||
            oneios_owned_thaw(c->groups, ONEIOS_THERMAL_ACK_MS))
            return fault(c);
        c->paused = false;
        /* The GPU gate stays closed until thaw and current sample verified. */
        if (!fresh(c, s) || c->ops.gpu_verify(c->ctx, true) ||
            c->ops.gpu_resume(c->ctx, ONEIOS_THERMAL_ACK_MS))
            return fault(c);
    }
    if (!healthy(c, c->paused)) return fault(c);
    c->policy = next; c->last = *s;
    return c->paused ? ONEIOS_THERMAL_PAUSED : ONEIOS_THERMAL_RUNNING;
}
