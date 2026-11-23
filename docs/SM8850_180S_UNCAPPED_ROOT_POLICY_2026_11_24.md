# SM8850: 180-second no-root-guard / no-root-CPU-cap Framework takeover — OneOS evidence (2026-11-24)

> **P0 safety finding; NOT a qualified recovery or thermal profile.** The 2026-11-23 UTC physical run used an explicitly opted-in **180s, 8-vCPU, GPU3D, full-bridges** iOS guest. Root software thermal guard and the root CPU-frequency cap worker were **OFF**. A previously summarized internal CPU thermal zone reached **104.8 °C**. No new physical test or watchdog certification is claimed by this document. **Do not repeat guard-OFF/cap-OFF takeover to collect more performance data.**

[OneiOS full archive/performance report](https://github.com/YMGPwcca/OneiOS/blob/feat/oneios-sm8850-m3q/docs/SM8850_180S_UNCAPPED_SESSION_FINDINGS_2026_11_24.md) · [OneOS watchdog limits](oneios-watchdog-recovery.md) · [Prior OneiOS thermal-mode mismatch](https://github.com/YMGPwcca/OneiOS/blob/feat/oneios-sm8850-m3q/docs/SM8850_MODE_HANDOFF_2026_11_23.md)

## Ownership, exact revisions and evidence quality

- **OneOS owns:** `switcher/assets/oneios_switch.sh` (root Framework stop/session mode and return orchestration), `oneios_sm8850_thermal_takeover_guard.sh`, `oneios_sm8850_thermal_cap.sh`, root-scoped watchdog/deadline/feeder and reboot-only return receipts.
- **OneiOS owns:** `sm8850-600s-thermal-telemetry.py` (passive host-side monitor), actual XNUHost execution, iOS GPU/display/CPU logs, offline archive parsing.
- **Source at physical run:** OneOS `f5c1b4a44fc45d78987694a230f7ffabb213e99c` on `feat/sm8850-no-root-cpu-cap-180s`; OneiOS parent `f244b5cdfdedd592cc68bcbbb0770762def9e140`. Firmware `S948BXXS4BZIG` on Samsung `SM-S948B` (m3q/SM8850), SELinux Enforcing.
- **Current-run identifier:** `control/framework.launch=7434ae27f8e84b76806f7a4b506e90c9`. The operator verified matching nonempty `session/xnuhost.log` (**339,854 bytes**) and `control/display.log` (**10,203 bytes**) from the same archive. Do not use older archived sessions to explain this run.
- **Evidence levels:** operator supplied preflight/host messages, physical brightness observation, offline parsed device archive, and a separate earlier chat summary of passive thermal samples. Full raw `telemetry.jsonl` and authenticated original root return receipt were **not made part of this Git commit**.

## OneOS state transition / contracts

### Before Framework stop (observed)

1. Exact repository and submodule revisions and staged SHA-256 checks passed. Staging preserved prior OneOS/native runtime under root-owned `.rollback/` directories.
2. The current-boot 28-zone manifest (`CPU=16 GPU=11 DDR=1`), isolated mount-namespace probe and reboot-stage preflight passed without stopping Android Framework.
3. One-shot APFS Data was independently rearmed: `FICLONE` unsupported on F2FS, so sparse clone was used; both `data.img` and `unique-chip-id` were hash-verified. Consumed Data was retired, not reused. `APFS_DATA_REARMED=YES` and `FULL_BRIDGES_180S_REARM=PASS_NO_FRAMEWORK_STOP`.
4. A **plain rearm-wrapper preflight** printed default `ACTIVE_BRIDGES_1_ROOT_MONITOR_MANDATORY` wording. **This is not proof the guard was running.** The actual explicit profile preflight was then executed with the no-guard token and confirmed:
   ~~~text
   SM8850_SOFT_THERMAL_GUARD=OFF_NOT_SPAWNED
   SM8850_CPU_CAP=DISABLED_NO_ROOT_WORKER
   SM8850_KERNEL_FIRMWARE_THERMAL_PROTECTION=UNCHANGED
   SM8850_FULL_RUN_THERMAL_BRIDGE=NO_ROOT_THERMAL_GUARD; HOST_READ_ONLY_TELEMETRY_ONLY
   SM8850_FULL_RUN_CPU_CAP=DISABLED_NO_ROOT_WORKER
   SM8850_SOFTWARE_THERMAL_MONITOR=DISABLED_FOR_180S
   SM8850_CPU_CAP_ADMISSION=DISABLED_NO_ROOT_WORKER
   SM8850_NO_GUARD_XNUHOST_ADMISSION=STAGED_RUNTIME_COMPATIBLE
   NO_USERSPACE_THERMAL_180S_PREFLIGHT=PASS_NO_FRAMEWORK_STOP_NO_DATA_CONSUMPTION
   ~~~
5. Source mode selectors require explicit experimental opt-in (`ONEIOS_SM8850_FULL_BRIDGES_180S` and `ONEIOS_SM8850_SOFT_THERMAL_OFF` with their exact acceptance values) plus a detached-session token. This addresses the earlier **env-only mode handoff mismatch** documented separately: a previous run accidentally launched its guarded profile despite host requesting guard OFF and stopped **before** Framework takeover. The current preflight PASS establishes **mode agreement**, not safety.

### Live guest and return (observed, with crucial gaps)

- The host recorded `FRAMEWORK_TAKEOVER=CONFIRMED`, iOS guest ready and first frame; the user's display brightness changed in response to slider input, though with stutter. OneiOS analyzed active KGSL 3D work.
- The operator's new session has **0 logged EPROTO GPU_COMMAND failures, 0 logged backboardd exits, 0 logged SpringBoard exits**, despite historical prior failures. This is important but **not attributable solely** to cap removal or the DRM2KGSL patch without matched conditions.
- At end, host saw **new Android/One UI boot**, rootless boot reason `reboot,oneios-sm8850-reboot-return`, `BOUNDED_TAKEOVER_RESULT=POST_REBOOT_OBSERVED_SESSION_CAUSE_NOT_PROVEN` and exit code **4**. It does **not** establish that the armed deadline specifically requested reboot, which watchdog/feeder was independent, or that normal One UI returned entirely without intervention.
- The current watchdog candidate is legacy `a:82`. `WATCHDOG_QUALIFICATION=UNVERIFIED_REBOOT_ONLY`, `PHYSICAL_THERMAL_WATCHDOG_QUALIFICATION=NOT_VERIFIED` and `UNASSISTED_RETURN_TO_ONEUI=UNVERIFIED` remain open. Boot reason and postboot `sys.boot_completed=1` cannot replace original root-owned `return.log`, `return.outcome` or `launches/*/switch.log` evidence.

## Critical thermal issue — owner OneOS

The chosen 180s mode intentionally did **not** spawn either:
- The **independent root temperature guard** and its fail-closed software over-temperature return path; or
- The separate best-effort `28%` root CPU `scaling_max_freq` cap worker (this branch's `CPU_THROTTLE=OFF_NO_ROOT_CAP_WORKER` contract).

The host's **passive** read-only thermal logger (and any guest thermal bridge) does **not** have authority to issue an emergency root return. Android kernel/vendor/firmware thermal facilities were not intentionally changed, but they **must not** be treated as a qualified replacement for a root monitor during an invasive Framework takeover.

An earlier summary of host passive thermal telemetry from this session reported a CPU internal zone **104.8 °C near T+61s**. Other approximate samples: CPU 82.2°C at ~17s, 93.1°C at ~30s, 96.2°C at ~91s, 89.6°C at ~121s and 65.0°C at ~171s. **These samples were recited in the conversation but the raw time-series has not been re-opened in this report**; preserve the original local `telemetry.jsonl` and never imply independently paired guest timestamps. CPU die temperature differs from battery/skin/case temperature.

**Do not:** (a) increase experimental thresholds to suppress aborts, (b) disable firmware thermal, (c) repeatedly run the no-guard variant, (d) force max CPU/GPU clocks, (e) remove an existing safety gate merely because normal One UI reboot eventually appeared.

## P0 issues and explicit exit criteria

### P0-A: Independently qualified root thermal guard / abort

**Finding:** 180s no-root-guard profile was admitted and run, while a CPU zone later reached an extreme sample temperature. Sensor coverage and preflight correctness alone cannot prevent high heat when the root monitor is absent.

**Implementation/evidence tasks:**
- Keep current firmware-specific, boot-pinned CPU/GPU/DDR manifest with complete 28-zone identity validation and trustworthy battery/LRP/board sensors. Confirm range, units, missing sensor handling, clock source and poll interval.
- Design **root-owned, independent of XNUHost, fail-closed** thermal monitoring that cannot silently stop after Framework shutdown, including stale/malformed sample behavior, heartbeat and generation binding.
- Bind hard abort and independent return request to device/firmware-reviewed temperature policy and sensor semantics; do not assert a universal threshold from one sample or raise the guard cutoff to avoid an abort.
- Handle CPU power votes/cap floors honestly and do not lower `scaling_min_freq` or relax tighter vendor limits. A cap that cannot be enforced must not be reported as protecting the CPU.
- Preserve and verify root-owned `thermal.guard.heartbeat`/`thermal.guard.fault`, original sample/crossed zone, source and destination clock, actual return request and postboot state.
- Qualify independently via local fault-injection tests before a separately risk-reviewed **cool** device acceptance with measured escape latency.

**Acceptance:** missing/stale sensor fails closed; guard lifecycle independent of guest/ADB; observed bounded abort-to-root-return evidence and reliable logs; no threshold or software-limit bypass; no repeated over-100°C sessions.

### P0-B: Recovery/deadline/watchdog requester provenance

**Finding:** `WATCHDOG_QUALIFICATION=UNVERIFIED_REBOOT_ONLY` and reboot-only rootless metadata are insufficient for a full recovery claim.

**Implementation/evidence tasks:**
- Use already captured root-owned files `control/framework.launch`, `control/framework.deadline`, `control/watchdog.generation`, `return.outcome`, `return.log`, `launches/*/switch.log`, guard/cap status and the matching `session/xnuhost.log`. Keep historical session logs separated.
- Record exact deadline arming, heartbeat, watchdog descriptor ownership, switch/return requester PID/birth/boot generation and return outcome **before** reboot, with a durable postboot retrieval path that survives ephemeral root loss.
- Demonstrate which root process issued reboot, not just presence of a matching bootreason string or ADB's observation of a new boot.
- Audit the legacy `/dev/watchdog` `a:82` path **without opening/closing the device for inspection**. Driver identity, timeout, magic-close semantics and independent liveness are still unknown.
- Clearly distinguish `NEW_ONEUI_BOOT_OBSERVED` from `UNASSISTED_RETURN_VERIFIED` and from `INDEPENDENT_WATCHDOG_QUALIFIED` in all console/JSON receipts.
- Never claim in-place handback for this experiment; it is a **mandatory reboot-return** design.

**Acceptance:** authenticated, same-generation original return requester, evidence-preserving deadline/failure abort, independent watchdog/guard behavior and separately validated unattended One UI recovery; no manual key/Download Mode shortcut disguised as automated return.

### P0-C: A consistent mode handoff from host to detached root session

**Finding:** a previous session lost the intended software thermal mode across the host-to-detached-session boundary. The later explicit tokenized admission passed, but requires continuous regression coverage.

**Implementation/evidence tasks:**
- Verify explicit mode token at both `--framework-check` and `--framework-session`; reject missing or mismatched token *before* APFS consumption or Framework stop.
- Verify the profile after detach with same-generation receipts, not only host environment variables.
- Enforce root guard and root cap spawn/absence according to the selected mode and record the mode *before* destructive stop.
- Add unit tests for forged/missing token, old boot/generation, mismatched 180s duration, accidental 600s fallback, consumed Data, initial One UI still alive.
- Keep **guarded default** and normal OneOS Android-app device eligibility unchanged; the no-guard branch is a research-only path, not a production configuration.

**Acceptance:** no cross-process profile mismatch and no false PASS; does **not** by itself qualify physical safety.

### P0-D: Evidence preservation across DirtyFrag/KernelSU ephemeral root loss

**Finding:** the host's first attempt to locate a current `device-logs.tar` failed, but a later read-only collection recovered **16 prior archived sessions plus the current session** and a valid current GPU/display pair. Root loss can still obscure original deadline/return receipts.

**Implementation/evidence tasks:**
- Archive only from explicitly matched `framework.launch` token, boot ID and generation, with file sizes and SHA-256; reject mixed historical/current traces.
- Persist return/thermal/device evidence in a trusted area before Framework reboot; retain consumed APFS evidence instead of overwriting with seed or deleting `data.consumed`.
- Reconnect/collect must **never** start iOS, rearm Data, touch governors, open the watchdog or change Android state beyond collecting requested diagnostics.
- Test collection when guest never starts, display log is empty, reboot completes but root is absent, stage archive has mixed generations, and sensor fault arrives before first frame.
- CI remains **local-first on CachyOS**, GitHub Actions only for final PR/release checks; no automatic hot physical run.

**Acceptance:** durable, exact-session, artifact-hashed provenance and correctly reported missing evidence; the collector never converts absence of proof into success.

## OneOS vs OneiOS follow-up boundaries

**OneOS P0 owns** actual root thermal lifecycle, independent watchdog/deadline return, strict mode handoff, safely archived root receipts and cap state. **OneiOS P1/P2 owns** actual guest VM fault/map churn (**8,889,193** traps over **180.6s**), high syscall/fault tails, GPU fence max **61.656 ms**, active-post estimate **43.91 Hz** (not actual FPS), touch-to-frame max **263.9 ms**, 9/16 touch summaries without a paired frame before close, physical brightness stutter and `host_statistics64` guest warnings **22**. Full issue-level details and source code inspection: [OneiOS findings](https://github.com/YMGPwcca/OneiOS/blob/feat/oneios-sm8850-m3q/docs/SM8850_180S_UNCAPPED_SESSION_FINDINGS_2026_11_24.md).

### Local-only verification commands (examples, **not executed by this doc commit**)

~~~sh
# Work against the pinned OneOS branch and matching OneiOS submodule locally.
sh -n switcher/assets/oneios_switch.sh
sh -n switcher/assets/oneios_sm8850_thermal_takeover_guard.sh
sh -n switcher/assets/oneios_sm8850_thermal_cap.sh
python3 tests/test_sm8850_guarded_full.py -v
# Then run the repository's local SM8850 thermal simulation suite.
# No ADB, no Framework stop and no guest run to remeasure FPS.
~~~

## Disposition

**Recorded physical success:** explicit no-guard/no-root-cap profile was accepted; OneiOS guest/UI/brightness/GPU3D worked; post-run normal Android boot was observed.

**Still BLOCKED:** thermal safety, independent root monitor, exact reboot requester, legacy watchdog ownership and unattended recovery. The absence of a new GPU crash does **not** justify repeating a profile that produced a **104.8 °C** internal CPU sensor sample.
