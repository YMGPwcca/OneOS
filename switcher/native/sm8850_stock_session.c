/* SPDX-License-Identifier: MIT */
#include "sm8850_stock_session.h"
#include <errno.h>
#include <string.h>

static int reject(void) { errno = EINVAL; return -1; }

int oneios_stock_session_prepare(struct oneios_stock_session *s,
    const struct oneios_thermal_identity *id, unsigned initial_pct)
{
    if (!s || s->phase != ONEIOS_STOCK_NEW || !id ||
        initial_pct < 10 || initial_pct > 100) return reject();
    /* No reuse after partial initialization. */
    s->phase = ONEIOS_STOCK_FAILED;
    struct oneios_thermal_sample first;
    if (oneios_raw_source_open(&s->raw, id) ||
        oneios_raw_source_read(&s->raw, &first)) return -1;
    if (oneios_owned_groups_create(&s->groups, id->token, initial_pct))
        return -1;
    s->groups_owned = true;
    s->id = *id;
    s->phase = ONEIOS_STOCK_PREPARED;
    return 0;
}

enum oneios_thermal_result oneios_stock_session_activate(
    struct oneios_stock_session *s, const struct oneios_thermal_ops *ops,
    void *ctx, const struct oneios_thermal_native_sample *n)
{
    if (!s || s->phase != ONEIOS_STOCK_PREPARED || !s->groups_owned)
        return ONEIOS_THERMAL_REFUSED;
    if (oneios_thermal_controller_init_stock(&s->controller, &s->groups,
                                               &s->id, ops, ctx)) {
        /* Retain group handles for the external owner to fence/retire. */
        s->phase = ONEIOS_STOCK_FAILED;
        return ONEIOS_THERMAL_REFUSED;
    }
    s->phase = ONEIOS_STOCK_BOUND;
    return oneios_stock_session_tick(s, n);
}

enum oneios_thermal_result oneios_stock_session_tick(
    struct oneios_stock_session *s, const struct oneios_thermal_native_sample *n)
{
    if (!s || s->phase != ONEIOS_STOCK_BOUND) return ONEIOS_THERMAL_REFUSED;
    return oneios_stock_source_tick(&s->raw, &s->controller, n);
}

enum oneios_thermal_result oneios_stock_session_fault(struct oneios_stock_session *s)
{
    if (!s || s->phase != ONEIOS_STOCK_BOUND) return ONEIOS_THERMAL_REFUSED;
    return oneios_thermal_controller_tick_stock(&s->controller, NULL, NULL);
}

int oneios_stock_session_retire_empty(struct oneios_stock_session *s)
{
    if (!s || !s->groups_owned) return reject();
    s->phase = ONEIOS_STOCK_FAILED; /* Never tick or reactivate after retirement starts. */
    if (oneios_owned_groups_remove_empty(&s->groups)) return -1;
    s->groups_owned = false;
    oneios_stock_session_close(s);
    return 0;
}

void oneios_stock_session_close(struct oneios_stock_session *s)
{
    if (!s || s->phase == ONEIOS_STOCK_CLOSED) return;
    if (s->groups_owned) oneios_owned_groups_close(&s->groups);
    s->groups_owned = false;
    memset(&s->controller, 0, sizeof s->controller);
    s->phase = ONEIOS_STOCK_CLOSED;
}
