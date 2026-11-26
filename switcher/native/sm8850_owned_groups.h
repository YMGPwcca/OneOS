/* SPDX-License-Identifier: MIT */
#ifndef ONEIOS_SM8850_OWNED_GROUPS_H
#define ONEIOS_SM8850_OWNED_GROUPS_H

#include <stdbool.h>
#include <sys/types.h>

/*
 * Native userspace actuator primitives, NOT a complete thermal controller.
 * The root session creator must create these private leaf groups, pin their
 * identities, own all membership transitions, and keep the independent
 * monitor/deadline outside them. No group creation or migration here.
 * Never use these primitives on a legacy live session.
 */
struct oneios_group_id { dev_t dev; ino_t ino; };
struct oneios_owned_groups {
    int cpu_parent, freezer_parent, cpu, freezer;
    struct oneios_group_id cpu_id, freezer_id;
    char name[46]; /* oneios_guest. + 32 lowercase hex + NUL */
    unsigned cpu_pct;
    bool fault, freeze_confirmed;
};

/* Bind /dev/cpuctl and /sys/fs/cgroup private leaves of the same token.
 * The initial quota must already match the creator's requested budget.
 * On failure the handle is closed. Returns 0 or -1 (errno).
 */
int oneios_owned_groups_open(struct oneios_owned_groups *g, const char *token,
    struct oneios_group_id cpu_id, struct oneios_group_id freezer_id,
    unsigned initial_pct);

/* Aggregate CFS bandwidth of eight CPUs; NOT MHz or utilization clamp. */
int oneios_owned_cpu_set(struct oneios_owned_groups *g, unsigned pct);

/* Request v2 CPU freeze and wait for cgroup.events frozen=1.
 * Failure leaves any freeze request intact and latches fault.
 * A successful CPU freeze does NOT prove GPU/IO quiescence.
 */
int oneios_owned_freeze(struct oneios_owned_groups *g, unsigned timeout_ms);

/* Explicit resume primitive ONLY after the caller has verified its
 * thermal/session/GPU resume conditions. No thaw after a latched fault.
 */
int oneios_owned_thaw(struct oneios_owned_groups *g, unsigned timeout_ms);

/* Closing handles changes no quotas, no membership, and never thaws. */
void oneios_owned_groups_close(struct oneios_owned_groups *g);
#endif
