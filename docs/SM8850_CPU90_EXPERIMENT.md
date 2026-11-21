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
