/* SPDX-License-Identifier: MIT */
#ifndef ONEIOS_SM8850_THERMAL_SOURCE_H
#define ONEIOS_SM8850_THERMAL_SOURCE_H
#include "sm8850_thermal_controller.h"

/* A single trusted root-side owner pins the manifest before Framework stop.
 * All mandatory junction types/IDs are checked on every sample. Never use
 * the diagnostic reader's partial maxima as a safety sample. No sysfs writes.
 * An independent owner must bound execution: sysfs reads are synchronous.
 * No HAL call, device access from test builds, clock write or live admission
 * is supplied by this interface. Do not invoke on an existing legacy run. */
#define ONEIOS_RAW_MAX_ZONES 96u
struct oneios_raw_zone {
    unsigned index, group;
    char type[64];
};
struct oneios_raw_source {
    struct oneios_thermal_identity id;
    struct oneios_raw_zone zones[ONEIOS_RAW_MAX_ZONES];
    unsigned count;
    uint64_t seq, last_ms;
    bool ready;
#ifdef ONEIOS_RAW_SOURCE_TEST
    char fixture[512];
#endif
};
int oneios_raw_source_open(struct oneios_raw_source *,
                           const struct oneios_thermal_identity *);
#ifdef ONEIOS_RAW_SOURCE_TEST
/* Compile-time fixture backend; production never accepts a path override. */
int oneios_raw_source_fixture(struct oneios_raw_source *,
    const struct oneios_thermal_identity *, const char *directory);
#endif
/* On any incomplete, invalid, stale or wrong-boot sample, fail without
 * publishing a sample or advancing the sequence. Timestamp is scan START
 * in BOOTTIME ms; completion must be within the controller freshness bound.
 * Valid high temperatures are data, not rejection criteria. */
int oneios_raw_source_read(struct oneios_raw_source *, struct oneios_thermal_sample *);
/* Actual sample-to-policy binding; caller owns clock, session, cgroups and
 * real drain/resume providers. Native sample must arrive independently,
 * already authenticated by that owner (NULL = unavailable).
 * Never block here on native Binder. Not a complete session launcher. */
enum oneios_thermal_result oneios_stock_source_tick(
    struct oneios_raw_source *, struct oneios_thermal_controller *,
    const struct oneios_thermal_native_sample *);
#endif
