/* SPDX-License-Identifier: MIT */
#ifndef ONEIOS_SM8850_THERMAL_CONTROLLER_H
#define ONEIOS_SM8850_THERMAL_CONTROLLER_H
#include <stdint.h>
#include "sm8850_owned_groups.h"

/* Source-only candidate, not an admitted session runner. Time is CLOCK_BOOTTIME
 * milliseconds; the creator must supply a verified sensor/session identity. */
#define ONEIOS_THERMAL_MAX_SAMPLE_AGE_MS 2000u
#define ONEIOS_THERMAL_ACK_MS 1000u

struct oneios_thermal_identity {
    char boot[37], generation[96], token[33];
};
struct oneios_thermal_sample {
    struct oneios_thermal_identity id;
    uint64_t seq, ms;
    int cpu_mc, gpu_mc, ddr_mc, battery_dc, lrp_dc, board_ap_dc;
};

/* Additional native HAL observation; identity/freshness and source
 * qualification are independent of the mandatory raw sensor sample.
 * severity is the max of explicitly qualified HAL sensors (0..6), NOT
 * the Framework global thermal status. Never synthesize it from sysfs
 * junction temperature. A missing/invalid native sample is unknown. */
struct oneios_thermal_native_sample {
    struct oneios_thermal_identity id;
    uint64_t seq, ms;
    int severity;
};

/* Pure policy: frequency percentage means a requested independently owned
 * hardware-MAX ceiling, never CFS duty or measured GHz. Stock-managed mode
 * uses a fixed internal 100/100 placeholder in this policy ONLY; no
 * frequency request or readback is emitted in that mode. */
struct oneios_thermal_policy {
    unsigned freq_pct, cpu_pct, floor_pct, cool_samples;
    uint64_t last_seq, last_ms, last_change_ms;
    bool hard, paused;
};
enum oneios_thermal_action {
    ONEIOS_THERMAL_INVALID = -1, ONEIOS_THERMAL_DUPLICATE,
    ONEIOS_THERMAL_COOL, ONEIOS_THERMAL_HOLD, ONEIOS_THERMAL_SOFT,
    ONEIOS_THERMAL_HARD, ONEIOS_THERMAL_RECOVERY_MINIMUM,
    ONEIOS_THERMAL_QUIESCE, ONEIOS_THERMAL_RESUME_MINIMUM
};
enum oneios_thermal_action oneios_thermal_policy_step(
    struct oneios_thermal_policy *p, const struct oneios_thermal_sample *s);

/* No production provider is supplied here. Callbacks must be bounded and
 * trusted. Session verification includes current boot/generation, creator
 * ownership, exact guest membership and exclusion of root/stock services.
 * In owned-frequency mode, verification proves OWNED request/readback
 * and an effective cap no higher than that vote; it does not relax stock
 * constraints. Stock-managed mode requires BOTH frequency callbacks NULL:
 * Samsung/Qualcomm own frequency policy, the controller owns CPU demand.
 * Neither mode is a substitute for a verified session/guard/provider.
 * gpu_quiesce closes submissions and drains GPU/IO; gpu_verify(true) must
 * independently prove that state even while all guest threads are frozen.
 * A no-op provider, shared sysfs vote, or unverified GPU ACK is inadmissible.
 */
struct oneios_thermal_ops {
    int (*now_ms)(void *, uint64_t *);
    int (*session_verify)(void *, const struct oneios_thermal_identity *);
    int (*frequency_verify)(void *, unsigned);
    int (*frequency_set)(void *, unsigned);
    int (*gpu_quiesce)(void *, unsigned);
    int (*gpu_verify)(void *, bool);
    int (*gpu_resume)(void *, unsigned);
};
enum oneios_thermal_result {
    ONEIOS_THERMAL_REFUSED = -1, ONEIOS_THERMAL_RUNNING,
    ONEIOS_THERMAL_PAUSED, ONEIOS_THERMAL_FAULT_QUIESCED,
    ONEIOS_THERMAL_FAULT_UNCONFIRMED
};
struct oneios_thermal_controller {
    struct oneios_owned_groups *groups;
    struct oneios_thermal_ops ops;
    void *ctx;
    struct oneios_thermal_identity id;
    struct oneios_thermal_policy policy;
    struct oneios_thermal_sample last;
    unsigned freq_applied; /* zero when stock-managed; no vote */
    struct oneios_thermal_native_sample last_native;
    bool stock_managed, ready, fault, paused;
    enum oneios_thermal_result fault_result;
};
/* Verify preexisting, creator-configured minimum/initial bounds. No writes. */
int oneios_thermal_controller_init(struct oneios_thermal_controller *c,
    struct oneios_owned_groups *g, const struct oneios_thermal_identity *id,
    const struct oneios_thermal_ops *ops, void *ctx,
    unsigned initial_freq_pct, unsigned qualified_floor_pct);
/* Explicit alternative: stock vendor DVFS, independently owned CPU
 * bandwidth and the same session/quiesce requirements. No frequency
 * actuator callbacks, no fake vote, no shared sysfs clock writes.
 * This initializer verifies the owned groups/providers, not whether
 * Samsung mitigation survives Framework OFF. It is NOT launch admission. */
int oneios_thermal_controller_init_stock(struct oneios_thermal_controller *c,
    struct oneios_owned_groups *g, const struct oneios_thermal_identity *id,
    const struct oneios_thermal_ops *ops, void *ctx);
/* The independent runner must call even on missing/stale data. NULL is a
 * fault, not an idle reading. No operation requests reboot or Android return.
 * A fault is latched for the lifetime of this controller/session. */
enum oneios_thermal_result oneios_thermal_controller_tick(
    struct oneios_thermal_controller *c, const struct oneios_thermal_sample *s);
/* Stock-managed tick: fresh native severity constrains CPU demand before
 * raw junctions overheat. Unknown native data never masks a raw fault,
 * permits a workload increase or releases a temperature pause. The
 * ordinary tick on a stock-managed controller is the NULL-native case. */
enum oneios_thermal_result oneios_thermal_controller_tick_stock(
    struct oneios_thermal_controller *c, const struct oneios_thermal_sample *s,
    const struct oneios_thermal_native_sample *native);
#endif
