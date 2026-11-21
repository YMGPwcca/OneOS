# SM8850 CPU 90 C thermal-abort experiment (ISOLATED RISK BRANCH)

**Not a P0 safety certification.** This experimental branch is kept separate from the normal OneOS P0 branch `feat/sm8850-p0-thermal-reader-sim`, where the prior conservative CPU 55 C early-abort gate stays in place.

## Why the branch exists

The operator's 2026-11-21 physical 300s-request probe reported `P0_THERMAL_GUARD=FAIL_CLOSED soft_temperature_abort crossed=cpu cpu_mC=75200 cpu_zone=cpu-0-2-1@10`. This was an actual CPU thermal-zone read of 75.2 C; the earlier trial aborted before any new iOS guest launch or verified +300s deadline. The exact reboot requester was unavailable after ephemeral root loss; the watchdog magic close also reported EBUSY.

The operator explicitly requested a second, higher-risk physical experiment with CPU abort at **90 C**. This is an exploratory threshold only and is **not supported by an SM-S948B / S948BXXS4BZIG vendor thermal critical-limit qualification**. A sample from another Qualcomm SoC model or public generic device tree is not a safety argument for this firmware.

## Exact source change

| Sensor group | Experiment abort | Prior conservative cutoff | Source units |
| --- | ---: | ---: | --- |
| CPU peak across all mapped CPU zones | **90 C** | 55 C | 90000 mC |
| GPU peak | **55 C (unchanged)** | 55 C | 55000 mC |
| DDR peak | **55 C (unchanged)** | 55 C | 55000 mC |
| Battery | **38 C (unchanged)** | 38 C | 380 deci-C |
| Samsung LRP | **42 C (unchanged)** | 42 C | 420 deci-C |
| Board AP | **42 C (unchanged)** | 42 C | 420 deci-C |

Everything else stays fail-closed: unreadable/mismatched sensor type, invalid samples, monitor death or stale heartbeat, wrong boot/generation/PID birth, and the early return request; the `--framework-session run` 600s source admission lock is not removed. A CPU internal junction reading is **not** skin/battery temperature. The health/return protocol and original OneOS legacy watchdog remain **unqualified**.

This does **not** change Android kernel, vendor throttling, temperature trips, governor, CPU frequency, charging controls or the hardware watchdog interface. The guard still checks all groups approximately once a second, so a fast thermal spike can precede the next check.

## Run/evidence contract

The single-run `scripts/phone/oneos-p0-live-300s-evidence.sh` wrapper on THIS experimental branch must require the explicit `ONEOS_CPU90_RISK_ACK=I_ACCEPT_SM8850_CPU_90C_EXPERIMENT` opt-in and verify the published runtime source pin before any phone action. It must archive the old one-shot APFS clone if consumed, retain host preboot switch/thermal streams and postboot witness, never retry automatically, and mark `P0_ACCEPTANCE=OPEN_NOT_CERTIFIED`. The 300s value is only a **reboot-request deadline after independently verified Framework stop**, not guaranteed runtime or return.

**Operator must have physical access, a data backup and a reliable manual return plan.** Stop if temperature/behavior is abnormal. Do not press both volume keys with USB attached, and do not treat reboot with a named bootreason as independent recovery certification.

The prior physical 300s record and forensic provenance remain in the normal P0 branch [probe ledger](https://github.com/YMGPwcca/OneOS/blob/feat/sm8850-p0-thermal-reader-sim/docs/SM8850_SHORT_GUARDED_IOS_PROBE.md). Never backport the 90 C cutoff into that accepted historical ledger as if its tests had been run at 90 C.

## 2026-11-21 observed CPU90 attempt: no reboot, root cause recovered from existing logs

The operator invoked the CPU90 high-risk wrapper from experiment branch at commit `10b18f38df0a9f116c4b8a0e1bd7b5314dd2462f`, pinned to runtime source `fa6cd88610c031c13288432476838e8b7b5a68f3`; local OneiOS source `4ae8874bac37c66e1214f68bc2606543ad941a1b`. Target model/firmware matched SM-S948B/m3q/SM8850/S948BXXS4BZIG with root and SELinux Enforcing. A targeted source regression passed.

The first on-device action rearmed the previous consumed APFS Data clone, preserving it at `/data/adb/oneios-m3q-framework/.retired-data/consumed.vSWdiVfs` and reporting `SM8850_MOUNT_NAMESPACE_PROBE=PASS_NO_FRAMEWORK_STOP`, `APFS_DATA_REARMED=YES`, `APFS_CLONE_READY=UNUSED_ONE_SHOT`. The host then reported 28-zone prepare PASS, passive probe preflight PASS, and printed `SHORT_PROBE_REQUESTING_REAL_IOS_GUEST` and `SHORT_PROBE_TIMEBASE=REBOOT_REQUEST_DEADLINE_300S_AFTER_FRAMEWORK_STOP`.

**Outcome:** `SHORT_PROBE=BLOCKED_OR_UNVERIFIED no independently observed healthy new One UI boot: no new healthy One UI boot observed after an ADB loss within bounded window`. The operator additionally reported **no visible Android Framework stop, no iOS screen and no reboot**. This is **NOT** a successful 300-second Framework takeover. The host's printed request marker precedes the actual remote `setsid` launch; it cannot alone prove switch execution. A missing new-boot witness likewise **cannot prove the switch never started** or that APFS Data remains unused. **This was the initial classification, superseded by the direct root logs below.**

**Collector deficiency found in source:** `sm8850-takeover-short-probe.py` raises when no postboot witness exists *before* writing the normal JSON artifact and milestone summary. Host filesystem logs are nevertheless written. Do **not** repeat the physical probe merely to obtain the missing JSON. The isolated experiment now includes `scripts/phone/sm8850-cpu90-failed-launch-forensics.sh` to read the saved host files and fixed on-device receipts **without** rearm, guest launch, watchdog opens or reboot.

The original conservative P0 branch retains CPU 55 C; its prior 75.2 C CPU fault is separate physical evidence. CPU 90 C remains **vendor-unqualified**, recovery and watchdog independence are not certified, and the 600s full run stays blocked. Next action is read-only log forensics only; do not automatically rearm or retry.


## 2026-11-21 P0 post-attempt forensics: exact root guard typo `birth $`

The operator subsequently ran the committed **read-only** forensics script and supplied the complete saved per-token switch log plus current-boot root receipts:

- Switch reached `[2/5] Arming the way back` at 07:54:09, printed `Cannot arm root thermal monitor; One UI left running.`, then root-owned `control/state=failed`. There was **no** `framework.deadline`, `framework.cutoff`, `watchdog.phase`, `session/return.request`, `return.outcome` or `return.log` record from this attempt. `init.svc.zygote=running`, system_server PID remained available, original and current boot ID were both `fd4647cf-85f1-407a-918d-caca56570f08`.
- Root thermal-guard stream contained `P0_THERMAL_GUARD=BLOCKED no_pid_birth` **for the CPU90 attempt**. Earlier `soft_temperature_abort cpu_mC=75200 cpu_zone=cpu-0-2-1@10` lines remained in the **append-only thermal-guard.log from the preceding 55 C attempt**; they were NOT a fresh CPU90 thermal fault.
- Exact bug in CPU90 guard source was **`BIRTH=$(birth $)` instead of `BIRTH=$(birth $$)`**. With a lone `$`, `birth` tries to read `/proc/$/stat` and produces no process-start-time; the guard cannot publish `thermal.guard.pid` or a heartbeat, so the switcher's 30-attempt guard readiness window fails. This is a source-level root cause, not a threshold/thermal/kernel/watchdog fault during this session.
- The one-shot `data.consumed` marker had already been created before the guard-arm phase. **`APFS_CLONE=CONSUMED`** is genuine, but Framework never stopped and `xnuhost` did not launch; do not delete the marker, do not claim APFS guest writes, and do not claim a reboot.
- Source patch on **this isolated experiment branch only** repairs `BIRTH=$(birth $$)`, adds root-independent `--pid-birth-selftest`, requires it in passive `--framework-check probe` **before APFS consumption**, and adds a live-root PID-birth selftest **before APFS rearm** in the experiment wrapper. A targeted regression now checks the exact PID expression and exercises the passive selftest. Host short-probe reporting also fails promptly if a guard arm refusal reappears, instead of silently waiting for a new-boot witness.
- **Change has not yet been physically accepted.** The experiment CPU 90 C cutoff remains vendor-unqualified; the baseline P0 CPU 55 C branch is unchanged. Full 600s remains blocked. Next action: one **read-only** `--pid-birth-selftest` on the phone with the corrected source, no rearm or Framework stop. Only if it succeeds should a *separately risk-reviewed* real probe be considered.

`ROOT_CAUSE=ROOT_THERMAL_GUARD_PID_BIRTH_TYPO`
`PHONE_REBOOT=NO`
`FRAMEWORK_STOP=NO`
`GUEST_LAUNCH=NO`
`APFS_DATA=CONSUMED_ONE_SHOT`
`P0_ACCEPTANCE=BLOCKED`

This records a **failed physical source attempt**, not a completed 300-second guest test or thermal certification.

## 2026-11-21: operator's real-phone PID-birth regression result (PASS, read-only)

The operator fetched exact experiment branch commit `55b7f0f895981171dfc155ff729797051c38d2bd` and piped `switcher/assets/oneios_sm8850_thermal_takeover_guard.sh` from Git into rooted S26 Ultra's `/system/bin/sh -s -- --pid-birth-selftest` (no installation, APFS rearm, guest launch, Framework stop or reboot). The reported output was exactly:

```text
P0_THERMAL_PID_BIRTH=PASS_READ_ONLY
```

**Scope:** the corrected `birth $$` source can obtain a valid process start-time from real device `/proc` in this shell invocation, and the dedicated passive selftest exits successfully. This **closes the specific PID-birth parser smoke gate** that blocked the previous CPU90 attempt. It does **not** demonstrate that an independent thermal worker can start under real switcher cgroup/namespace conditions, publish a fresh heartbeat, stop Android Framework, boot `xnuhost`, or initiate independently certified recovery. The earlier `data.consumed` remains valid; no rearm or new guest test occurred.

**Next safe verification:** passive `--check` against the current boot's trusted on-device thermal manifest, then review real watchdog/returner readiness separately. Do not call P0 complete or automatically run the experimental CPU90/300s guest. CPU90 remains vendor-unqualified and the 600s source admission lock remains intact.

`ROOT_GUARD_PID_BIRTH_SELFTEST=PASS_PHYSICAL_READ_ONLY`
`P0_THERMAL_ARMED_FOR_REAL_SESSION=NOT_RETESTED`
`P0_APFS_CLONE=CONSUMED_PRIOR_ATTEMPT`
`P0_ACCEPTANCE=BLOCKED`

## 2026-11-21: current-boot thermal manifest check PASS on physical S26 Ultra

Immediately after the real-phone PID-birth selftest PASS, the operator executed the same corrected guard source (`55b7f0f895981171dfc155ff729797051c38d2bd`) in **read-only** mode through root `/system/bin/sh -s -- --check /data/adb/oneios-m3q-framework/thermal.guard.manifest`. Exact reported receipt:

```text
P0_THERMAL_GUARD=READ_ONLY_CURRENT_BOOT_READY_NOT_CERTIFIED
```

**Interpretation limited to what source `--check` actually enforces:** the manifest was a non-symlink root-owned file; the recorded boot ID matched this boot before and after sensor sampling; mapped zone indices/types/CPU-GPU-DDR coverage and count were validated; each mapped CPU/GPU/DDR zone could be read with valid units; Samsung battery/LRP/board AP readers returned well-formed values; and the current readings did not cross the experimental guard cutoffs. The prior host manifest survey showed 28 selected zones; the single output line does not independently restate the count or publish per-zone measurements.

**Not established:** independent `--run` lifecycle/PID birth under takeover cgroup/namespace, continuous heartbeat, fail-closed reboot causality, watchdog ownership, exact 300-second deadline, iOS guest runtime, vendor-approved CPU 90 C cutoff or unassisted recovery. The prior failed experiment's one-shot `data.consumed` remains in force; this test did not rearm, stop Framework or reboot.

`P0_THERMAL_PID_BIRTH=PASS_PHYSICAL_READ_ONLY`
`P0_THERMAL_CURRENT_BOOT_CHECK=PASS_PHYSICAL_READ_ONLY`
`P0_INDEPENDENT_GUARD_LIFECYCLE=NOT_TESTED`
`P0_RETURNER_WATCHDOG_QUALIFICATION=BLOCKED`
`P0_ACCEPTANCE=BLOCKED`

**Next engineering gate:** verify continuous monitoring and heartbeat generation with a safely isolated, non-disruptive trial while One UI remains running, and independently review the legacy watchdog/return path before any further hot/long takeover. The conservative 55 C P0 branch and 600s lock remain unchanged.


## 2026-11-21: CPU90 300-second-request physical probe — monitor armed, Framework stopped, xnuhost launch marker, normal One UI reboot

Operator executed the isolated experiment wrapper from OneOS branch head `eeff8fc3ff8fa26e39ae59cd7cfe241c8b82bb55` with pinned source `022c0fac5ed32a3b1445717c0a384cdc458ebd5e`; OneiOS local checkout `4ae8874bac37c66e1214f68bc2606543ad941a1b`, device SM-S948B/m3q/SM8850, firmware S948BXXS4BZIG, rooted, SELinux Enforcing. This was a **new physical experiment** separate from both the earlier 55 C thermal abort and the CPU90 `no_pid_birth` failure. Operator supplied the console output and reported the phone restarted on its own.

- Offline `CPU90_TARGETED_REGRESSION=PASS_OFFLINE_NOT_HARDWARE_QUALIFICATION`; root `P0_THERMAL_PID_BIRTH_BEFORE_REARM=PASS_READ_ONLY`; prior APFS clone was consumed; freshly staged one-shot clone passed `REBOOT_STAGE_CHECK=PASS_NO_FRAMEWORK_STOP`, `SM8850_MOUNT_NAMESPACE_PROBE=PASS_NO_FRAMEWORK_STOP`, `APFS_DATA_REARMED=YES`. Existing consumed Data was archived in root-owned `.retired-data/`.
- Host started preboot thermal streaming, then 28-zone prepare and passive probe preflight passed. The `--run-300s` **return-request** profile was dispatched, not a promise of 300 seconds of guest execution.
- **New, affirmative launch receipts:** `THERMAL_GUARD_ARMED=TRUE`, `FRAMEWORK_STOP_MARKER=TRUE`, `XNUHOST_LAUNCH_MARKER=TRUE`. The preboot switch stream preserved **4,395 bytes**; the host's per-probe JSON was written to `out/sm8850/p0-physical/live-300s-20261121T075940Z-SzjtNA/probe/short-probe-20261121T080216Z-cc89fb.json`. These markers are evidence of the root guard's arm milestone, the switcher's Framework-stop completion milestone and the OneOS `xnuhost` launch milestone, **not of iOS guest READY, first frame, smooth performance or successful 300-second guest runtime**.
- Host observed a **new normal One UI boot** after the probe (`ONEUI_NEW_BOOT=OBSERVED_AFTER_PROBE_REQUEST`); operator additionally attested the phone rebooted without their intervention. This is meaningful physical return evidence but does **not** establish the original reboot requester, verified absence of all operator interventions or the independence of the legacy hardware watchdog.
- `POSTBOOT_ROOT_LOG_ACCESSIBLE=FALSE`, `HISTORICAL_RETURN_CORRELATED=FALSE`, `UNASSISTED_RETURN=OPERATOR_ATTESTATION_REQUIRED`. The script concluded `SHORT_PROBE=GUEST_LAUNCH_MARKERS_OBSERVED_RECOVERY_NOT_CERTIFIED`. **Exact reboot trigger (thermal fault, early watcher/fallback, watchdog, or deadline) and the actual Framework-stop-to-return interval remain unresolved until the saved preboot switch/thermal logs and host witness JSON are examined.** The host session folder and JSON filename timestamps alone are *not* a reliable device-monotonic 300-second timer.
- No fresh thermal peak, iOS display frame, deadline expiry, returner signature or watchdog qualification was supplied in this operator console output. Preserve the raw root/host evidence privately; do not rearm, rerun or increase the experimental CPU 90 C abort threshold solely to fill these evidence gaps.

**Disposition:** `P0_THERMAL_GUARD_ARMED=OBSERVED_REAL_PHONE`; `P0_FRAMEWORK_STOP=OBSERVED_LOG_MARKER`; `P0_XNUHOST_LAUNCH=OBSERVED_LOG_MARKER`; `P0_NEW_ONEUI_BOOT=HOST_OBSERVED`; `P0_UNASSISTED_RETURN=OPERATOR_REPORTED_NOT_INDEPENDENTLY_CERTIFIED`; `P0_ACTUAL_GUEST_DURATION=UNVERIFIED`; `P0_ORIGINAL_RETURN_REQUESTER=UNVERIFIED`; `P0_ACCEPTANCE=BLOCKED`. This is **substantial forward progress**, but not 300-second runtime or P0 safety certification; normal P0 CPU 55 C branch and 600s full-run admission lock remain unchanged.


## 2026-11-21 post-run forensics: **new CPU 101.1 C thermal fault** after Framework stop and xnuhost launch

Operator supplied original host-captured switch stream, appended thermal stream and reboot-witness JSON from `live-300s-20261121T075940Z-SzjtNA`. These observations **supersede the preceding summary's missing thermal-cause information**; the original returner PID/action is still not independently attributable.

**Confirmed chronology from the current-session switch log (device wall-clock/uptime):**

- 15:01:30 baseline; 15:01:31 root thermal guard arming; `P0_SHORT_PROBE_THERMAL=ARMED_ROOT_SENSOR_GUARD_NOT_PRODUCTION_CERTIFIED`. Three initial missing-`thermal.guard.heartbeat` reads were transient before positive arm receipt; not a guard-arm failure.
- 15:01:32 Framework stop request and `Watchdog: FRAMEWORK_OWNS -> TRANSFER_PENDING (legacy a:82)`. Magic-close of `/dev/watchdog` refused with `EBUSY` and bounded feeder retry; the legacy watchdog remains unqualified. Completion receipt: `Framework stopped, app groups drained and Android input absent at uptime 26346. Deadline: 26646` — an explicit **+300s return-request deadline**, not an achieved 300-second guest run. Android's `zygote` stopped; `system_server` gone.
- 15:01:45 xnuhost launch PID `18718` and display helper PID `18835`; `P0_SHORT_PROBE_TIMING=framework_stop_tick:26346 guest_pid_observed_tick:26346 ... remaining_to_reboot_request_seconds:300`. `=== ONEIOS SESSION LAUNCHED ===` marker recorded. No guest READY, first frame or high-FPS evidence in this switch log.

**New physical current-run thermal observation, after its distinct CPU90 profile line:**
```text
P0_THERMAL_PROFILE=CPU_90C_HIGH_RISK_NOT_VENDOR_CERTIFIED_GPU_DDR_55C_BAT_38C_LRP_AP_42C
P0_THERMAL_GUARD=FAIL_CLOSED soft_temperature_abort crossed=cpu cpu_mC=101100 cpu_zone=cpu-1-1-1@27 gpu_mC=51300 gpu_zone=gpuss-7@43 ddr_mC=54400 ddr_zone=ddr@47 bat_dC=294 lrp_dC=323 board_ap_dC=382
```
CPU zone 27 reported **101.1 C**, exceeding the **90 C experimental early abort by 11.1 C**. Concurrent GPU **51.3 C** (threshold 55 C), DDR **54.4 C** (55 C), battery **29.4 C** (38 C), Samsung LRP **32.3 C** (42 C) and board AP **38.2 C** (42 C) were below their respective experiment thresholds. This is an actual mapped CPU thermal-zone sample, **not** a measured external surface/battery or proof of sustained temperature. The earlier **75.2 C CPU at 55 C cutoff** and the separate `no_pid_birth` lines in append-only `thermal-guard.log` belong to **previous attempts** and must not be counted as new faults. The thermal monitor visibly detected the current CPU overrun after guest launch.

**Independent host reboot witness:** `before_boot_id=fd4647cf-85f1-407a-918d-caca56570f08`, `after_boot_id=9d240969-56b8-4adc-b3fd-5f13e6c867df`; host saw ADB `OFFLINE` at t=48.473 s and `NEW_BOOT_NORMAL_ONEUI` at t=70.541 s from its initial witness, about **22.068 s between those two host events**. Host itself did not issue reboot, stop Framework or touch watchdog. New `current_bootreason=reboot,oneios-sm8850-reboot-return` supports a OneOS-named reboot context, but `current_outcome=null`, `control_state=null`, `historical_return_record_correlated_to_pre_smoke_boot=false`: **exact responsible return process and independently verified unassisted recovery remain unproven**. The actual guest execution interval cannot be inferred exactly from witness-relative seconds without the root session timeline.

**Finding:** `P0_NEW_CPU_THERMAL_FAULT=CPU_101P1C_ZONE27_OBSERVED`; `P0_THERMAL_THRESHOLD_CPU90_EXCEEDED=YES`; `P0_THERMAL_GUARD_DETECTED_FAULT=YES`; `P0_NEW_ONEUI_BOOT=HOST_VERIFIED`; `P0_300S_GUEST_RUNTIME=NOT_ACHIEVED`; `P0_ORIGINAL_REBOOT_REQUESTER=UNKNOWN`; `P0_ACCEPTANCE=BLOCKED`.

**Safety disposition:** Do **not** raise the CPU cutoff above 90 C or re-run this hot physical profile. A 90 C early check did not constrain observed CPU peak to 90 C; the sampled point reached 101.1 C. Investigate guest CPU demand/host scheduling, loop/spin or inefficient work and restore a conservative thermal policy before any new hot execution. Do not claim vendor-critical thermal safety, independent watchdog qualification or recovery certification. Keep the exact original host switch/thermal/witness evidence archived.


## 2026-11-21 follow-up: independent thermal stream instrumentation, CPU90 profile NOT qualified

After the root-owned CPU90 monitor observed `cpu_mC=101100` (101.1 C, zone 27) during the previous real guest launch, the **source** of the independent guard was instrumented to print a bounded `P0_THERMAL_SAMPLE=OK` telemetry line once per five *successfully published* heartbeats, carrying boot/generation, uptime, CPU/GPU/DDR peaks and zones plus BAT/LRP/board-AP readings. No trigger values, sensor classification, root PID/heartbeat contract, watchdog state or reboot request handler were changed. CPU90 remains an **unqualified, high-risk historical experiment**; this telemetry is not evidence of a safer 300s guest run.

**Critical pin distinction:** the earlier CPU90 host wrapper at `eeff8fc3ff8fa26e39ae59cd7cfe241c8b82bb55` archives and executes the older, reviewed runtime source `022c0fac5ed32a3b1445717c0a384cdc458ebd5e`. That pinned source does **not** contain the later sample messages or the new parent-Oryon bench opt-in added on the conservative `feat/sm8850-p0-thermal-reader-sim` branch. The wrapper's source-drift check must not be bypassed or silently repinned. No physical follow-up has occurred.

The direct parent `akshaynexus/OneOS` is **not** the ancestral `fahadalijaved/OneOS`. The fork's special SM8850 framework stop, independent guard, abort/deadline, APFS one-shot and reboot-only return contract make a wholesale parent `oneios` merge unsafe. Only scoped portable changes have been applied to the normal P0 development branch. Keep the 600s source block and independent root guard. **Do not repeat the CPU90 experiment after the documented 101.1 C overrun just to validate the new log lines or host affinity.**
