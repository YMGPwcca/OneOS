# SM8850 companion: 60 FPS XNUHost-first performance priorities

**Date:** 2026-11-24 · **Device:** Galaxy S26 Ultra / SM-S948B / SM8850.

The active 29-item performance execution backlog lives in OneiOS: [SM8850 60 FPS / XNUHost tracker](https://github.com/YMGPwcca/OneiOS/blob/feat/sm8850-xnuhost-perf-p0/docs/SM8850_60FPS_XNUHOST_PERFORMANCE_TRACKER.md). Source implementation belongs primarily to OneiOS `runtime/xnuhost`, `runtime/display` and `runtime/bridges`. OneOS acts as the runtime's launcher, versioned submodule source and session/artifact evidence owner.

**Do not reinterpret this document as a change to the operator's existing no-root-thermal-guard / fixed-duration X-second test profile.** No thermal or recovery script is modified by this branch. Existing safety findings and the earlier 180-second run's incomplete return provenance remain documented in [root-side findings tracker](SM8850_180S_UNCAPPED_ROOT_TRACKER_2026_11_24.md), irrespective of performance priorities. No live framework takeover is authorized by a docs change.

## OneOS-side performance work (aligned with OneiOS P0-P4)

- [ ] **OOS-PERF-P0-01** Record exact OneiOS commit, OneOS submodule SHA, firmware, session token and bounded X-second profile in a single launch/evidence manifest. Distinguish staged revision from executed revision.
- [ ] **OOS-PERF-P0-02** Preserve the existing fixed-duration session collection with no implicit re-arm, no framework stop and no side effect in collect-only mode. Capture XNUHost + display + KGSL timestamps where present; explicitly mark absent data.
- [ ] **OOS-PERF-P0-03** Provide read-only, monotonic-clock-correlated CPU/vCPU frequency, CPU utilization, GPU and surface timing telemetry for offline attribution. Never assume device telemetry is itself frame presentation timing.
- [ ] **OOS-PERF-P1-01** Define deterministic workload timestamps/input recipes for Home swipe, Settings scroll, brightness slider and app transitions, with a declared active-animation window and no automatic physical guest launch in CI.
- [ ] **OOS-PERF-P1-02** Add offline parser fixtures for multi-source trace clock mismatch, missing reports, idle periods and out-of-order events. No false 60 FPS PASS based on `post/s`.
- [ ] **OOS-PERF-P2-01** Pin and provenance-check OneiOS/OneOS tested revisions before A/B benchmarks. Preserve correct `app` submodule relation; an updated docs branch is not automatically the deployed OneOS runtime.
- [ ] **OOS-PERF-P3-01** Keep CachyOS local-first testing, unit/sanitizer and local artifact capture. Run GitHub Actions only for final PR verification when appropriate.
- [ ] **OOS-PERF-P4-01** Report sustained **presented** FPS and active-window frame interval/jank p50/p95/p99 with a traced presentation observable. If only posts are available, label `POST_CADENCE_ONLY` and do not claim 60 FPS achieved.

## First action and scope

1. OneiOS `feat/sm8850-xnuhost-perf-p0`: patch `runtime/xnuhost/src/task.c` to avoid NULL dereference on `order(t,NULL,0)` timeout/slow logging; add deterministic host regression coverage.
2. Add XNUHost CPU/VM/timer attribution and linked frame IDs; perform source-only and host local tests first.
3. Update this launcher-side manifest/collection layer after a concrete trace schema exists. **No changes to thermal abort threshold, vendor/kernel protections, watchdog, reboot deadline or physical switcher in this documentation step.**

## Evidence constraints

Earlier 180-second full-framework run: OneiOS `f244b5cdfdedd592cc68bcbbb0770762def9e140`, pinned OneOS `f5c1b4a44fc45d78987694a230f7ffabb213e99c`, launch token `7434ae27f8e84b76806f7a4b506e90c9`. `57.42 posts/s` peak and estimated `43.91 Hz` active posting cadence **are not actual presented FPS**; GPU fence maximum was `61.656 ms`. XNUHost remains a *high-priority suspected performance bottleneck*, not yet conclusively attributed by frame-critical-path evidence.
