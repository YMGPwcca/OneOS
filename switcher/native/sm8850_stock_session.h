/* SPDX-License-Identifier: MIT */
#ifndef ONEIOS_SM8850_STOCK_SESSION_H
#define ONEIOS_SM8850_STOCK_SESSION_H
#include "sm8850_thermal_source.h"

/* Root-side assembly of the existing stock-managed components. The owner
 * must supervise blocking calls, hold the launch/membership barrier, and
 * supply real session and drain/resume providers. No live admission here.
 * Initialize with {0}; never copy or move an initialized session. */
enum oneios_stock_session_phase {
    ONEIOS_STOCK_NEW = 0, ONEIOS_STOCK_PREPARED, ONEIOS_STOCK_BOUND,
    ONEIOS_STOCK_FAILED, ONEIOS_STOCK_CLOSED
};
struct oneios_stock_session {
    struct oneios_owned_groups groups;
    struct oneios_raw_source raw;
    struct oneios_thermal_controller controller;
    struct oneios_thermal_identity id;
    enum oneios_stock_session_phase phase;
    bool groups_owned;
};
/* Check complete boot-pinned raw source, then create new private leaves.
 * initial_pct is explicit, not a frequency vote or qualified default.
 * Valid high temperature is data, not a temperature-only refusal. */
int oneios_stock_session_prepare(struct oneios_stock_session *,
    const struct oneios_thermal_identity *, unsigned initial_pct);
/* Only after verified guest membership and real provider binding.
 * Returns the FIRST actual controller result. Never release a startup
 * barrier on REFUSED, FAULT, or PAUSED. No fake or frequency callbacks. */
enum oneios_thermal_result oneios_stock_session_activate(
    struct oneios_stock_session *, const struct oneios_thermal_ops *, void *,
    const struct oneios_thermal_native_sample *);
/* Preferred supervised-source variants: the caller obtains a raw sample
 * through its independent bounded transport. Do not call synchronous raw
 * sysfs reads in that owner loop. NULL raw remains a latched fault; the
 * controller rechecks identity, sequence, freshness and provider state.
 * The existing synchronous entry points are retained for fixtures and
 * compatibility, not a substitute for independent supervision. */
enum oneios_thermal_result oneios_stock_session_activate_sample(
    struct oneios_stock_session *, const struct oneios_thermal_ops *, void *,
    const struct oneios_thermal_sample *, const struct oneios_thermal_native_sample *);
/* Transfer only a real pre-READY policy latch, with actual quota
 * already reduced to 10. The controller obtains its own pause receipt. */
enum oneios_thermal_result oneios_stock_session_activate_held_sample(
    struct oneios_stock_session *, const struct oneios_thermal_ops *, void *,
    const struct oneios_thermal_sample *, const struct oneios_thermal_native_sample *,
    bool hard, bool paused);
enum oneios_thermal_result oneios_stock_session_tick_sample(
    struct oneios_stock_session *, const struct oneios_thermal_sample *,
    const struct oneios_thermal_native_sample *);
/* Invoke on each independently supervised sample interval, including
 * while paused. Missing native data is unknown; raw failure is a fault. */
enum oneios_thermal_result oneios_stock_session_tick(
    struct oneios_stock_session *, const struct oneios_thermal_native_sample *);
enum oneios_thermal_result oneios_stock_session_fault(struct oneios_stock_session *);
/* After external retirement only, remove identity-pinned empty leaves. */
int oneios_stock_session_retire_empty(struct oneios_stock_session *);
/* Close handles only after independent fencing/retirement. No automatic
 * thaw, membership migration, group deletion, reboot or Android return. */
void oneios_stock_session_close(struct oneios_stock_session *);
#endif
