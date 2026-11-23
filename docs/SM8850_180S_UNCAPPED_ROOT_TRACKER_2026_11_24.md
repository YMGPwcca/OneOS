# SM8850 OneOS root-side finding tracker — 180s unguarded run

> **Repo-local issue replacement: GitHub Issues is disabled (`has_issues=false`).** Treat each `OOS-P0-*` as a tracked task. This tracker is documentation, not proof that a software thermal cutoff, watchdog or unattended return is certified.

[Root-side current-run evidence](SM8850_180S_UNCAPPED_ROOT_POLICY_2026_11_24.md) · [OneiOS session/performance report](https://github.com/YMGPwcca/OneiOS/blob/feat/oneios-sm8850-m3q/docs/SM8850_180S_UNCAPPED_SESSION_FINDINGS_2026_11_24.md) · [OneiOS P0–P3 tracker](https://github.com/YMGPwcca/OneiOS/blob/feat/oneios-sm8850-m3q/docs/SM8850_180S_UNCAPPED_ENGINEERING_TRACKER_2026_11_24.md)

Exact source: OneOS `f5c1b4a` + OneiOS `f244b5c`, full-bridges/8-vCPU/KGSL/180s, root guard OFF, root CPU cap OFF, legacy candidate watchdog `a:82`. The operator's previous chat telemetry summary reports CPU junction **104.8°C**, raw thermistor timeline not re-parsed here. **Do not repeat this configuration.**

## OOS-P0-01 · Independently qualified fail-closed thermal guard [OPEN, STOP]

**Why:** `SM8850_SOFT_THERMAL_GUARD=OFF_NOT_SPAWNED` and `SM8850_CPU_CAP=DISABLED_NO_ROOT_WORKER` were actually admitted. Passive host monitoring and unchanged kernel/firmware thermal limits do not constitute a root emergency cutoff.

**Source:** `switcher/assets/oneios_sm8850_thermal_takeover_guard.sh`, `oneios_sm8850_thermal_cap.sh`, `oneios_switch.sh`.

- [ ] Validate exact-boot pinned thermal manifest (28 zones CPU16/GPU11/DDR1), battery/LRP/board sensors, units, freshness, permissions, monotonic time and missing-sensor handling.
- [ ] Ensure independent root monitor lifecycle/heartbeat outside guest and no reliance on host ADB or a running XNUHost.
- [ ] Specify firmware-reviewed early-abort/critical policy, rate limits/hysteresis and bounded recovery action; do not raise a cutoff to avoid a previous abort.
- [ ] Verify CPU cap floor/vote policies honestly, no false `28%` effective cap when Samsung minimum vote prevents it. Preserve vendor/kernel protections.
- [ ] Test failure-injection (stale boot/generation, partial heartbeat, monitor death, cpufreq write refusal, thermal surge) fully offline on CachyOS.
- [ ] Only plan a separately approved, cool and genuinely protected physical acceptance after recovery is also verified.

**Done:** observed same-session bounded fail-closed response, authentic root return and thermal sensor source; no uncontrolled high-temperature reruns.

## OOS-P0-02 · Proven original reboot return / independent watchdog [OPEN, STOP]

**Why:** the host saw a new One UI boot and `reboot,oneios-sm8850-reboot-return`, but `BOUNDED_TAKEOVER_RESULT=POST_REBOOT_OBSERVED_SESSION_CAUSE_NOT_PROVEN` / host exit 4. Legacy watchdog `a:82` is still `UNVERIFIED_REBOOT_ONLY`, and original requester and fully unattended return were not authenticated.

- [ ] Preserve matching root-owned `return.log`, `return.outcome`, `control/framework.deadline`, `control/watchdog.generation` and `launches/*/switch.log`.
- [ ] Correlate original requester PID/birth, precise monotonic deadline and chosen reboot reason with boot ID and launch token.
- [ ] Verify owner/module/timeout/keepalive/magic-close semantics **without opening** a watchdog character device for inspection.
- [ ] Simulate expired deadline, guest hang, guard death and partial root availability; never pass solely due to a new Android boot property.
- [ ] Demonstrate return to normal One UI without physical key or Download Mode detour, under a separate risk-reviewed acceptance.

**Done:** original root source and independently bounded recovery authenticated; no in-place return claim.

## OOS-P0-03 · Mode handoff correctness and guarded-default regression [OPEN]

**Why:** earlier env-only handoff mismatch armed a root guard despite a requested no-guard profile and refused before stopping Framework. Current tokenized explicit preflight passed both `OFF_NOT_SPAWNED` and `DISABLED_NO_ROOT_WORKER`. **PASS admission != physical safety.**

- [ ] Cover exact `--framework-check run 180` and detached `--framework-session run ... 180` token agreement, including missing/malformed/mismatched token.
- [ ] Reject stale firmware/boot/generation and accidental 600s fallback before APFS consumption.
- [ ] Ensure guarded mode remains default; no no-guard exception in normal Android app switch.
- [ ] Verify unambiguous root guard/cap worker spawn/no-spawn markers and no false “ready” after stage-only.
- [ ] Run local regression without phone and document both modes.

**Done:** no silent host/detached profile mismatch; rejection has no Framework stop.

## OOS-P0-04 · Durable exact-session evidence across ephemeral root loss [OPEN]

**Why:** local run folder did not contain a tar initially; a later read-only collect recovered a current session matching `framework.launch=7434ae27f8e84b76806f7a4b506e90c9` plus 16 distinct historical sessions. XNUHost **339,854 bytes**, display **10,203 bytes**. Root-owned deadline return evidence remains partially absent.

- [ ] Save pre-reboot root switch, guard/cap, watchdog and returner evidence with token+boot+generation+hashes.
- [ ] Reject mixing current and `logs/session.*` logs, missing/empty guest logs and stale return receipts.
- [ ] Ensure collect-only mode never starts guest, rearms APFS, stops Framework, opens watchdog or changes system-wide policy.
- [ ] Preserve consumed APFS Data and `data.consumed`/retired clone receipts, including F2FS sparse fallback integrity.
- [ ] Test root lost at reboot, early thermal abort, empty trace, malformed archive and interrupted collection.

**Done:** an immutable, attributable evidence package including precise “not verified” fields when root is missing.

## OOS-P0-05 · One-shot APFS/stage/profile acceptance regression [OPEN]

**Already observed PASS:** stage-only untouched Framework, F2FS sparse fallback after `FICLONE` unavailable, hash verification of `data.img` and `unique-chip-id`, archived previous consumed guest Data, 28-zone manifest, preflight without new Data consumption. These are **historical PASS receipts**, not sufficient to authorize another live run.

- [ ] Assert no source overwrite or consumed clone reuse, no marker bypass, correct blob SHA for staged native runtime, and audit old/new session metadata.
- [ ] Keep stage-only, rearm and run as separate explicit operations with different safety preconditions.
- [ ] Regression-test that rearm default preflight text cannot be misread as an actual detached root mode or a physical safety PASS.
- [ ] Keep local-first validation and physical P0 gate independent from build/test success.

**Done:** reliable idempotent/one-shot stage semantics without implicit guest execution.

## Parallel performance roadmap (not a change to root-side safety findings)

The operator has prioritized **XNUHost CPU/VM attribution and eventual 60 FPS** over additional thermal/recovery implementation work. The new [OneOS 60 FPS companion backlog](SM8850_60FPS_PERFORMANCE_COMPANION.md) links the 29-item [OneiOS workstream](https://github.com/YMGPwcca/OneiOS/blob/feat/sm8850-xnuhost-perf-p0/docs/SM8850_60FPS_XNUHOST_PERFORMANCE_TRACKER.md). The original five `OOS-P0-*` findings above remain open and factually unchanged. This is **priority tracking only**, not a modification to existing thermal scripts, fixed-duration reboot mechanism or a statement that physical-session risks are resolved.

## Work order

**STOP:** OOS-P0-01 and OOS-P0-02 before any new invasive phone session; implement OOS-P0-04 alongside them to avoid losing the proof. OOS-P0-03/05 maintain trusted admission and APFS integrity. No item is closed by this documentation commit.
