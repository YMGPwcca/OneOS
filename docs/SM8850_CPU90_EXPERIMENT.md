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

## 2026-11-21 observed CPU90 attempt: no new boot witness; cause pending log forensics

The operator invoked the CPU90 high-risk wrapper from experiment branch at commit `10b18f38df0a9f116c4b8a0e1bd7b5314dd2462f`, pinned to runtime source `fa6cd88610c031c13288432476838e8b7b5a68f3`; local OneiOS source `4ae8874bac37c66e1214f68bc2606543ad941a1b`. Target model/firmware matched SM-S948B/m3q/SM8850/S948BXXS4BZIG with root and SELinux Enforcing. A targeted source regression passed.

The first on-device action rearmed the previous consumed APFS Data clone, preserving it at `/data/adb/oneios-m3q-framework/.retired-data/consumed.vSWdiVfs` and reporting `SM8850_MOUNT_NAMESPACE_PROBE=PASS_NO_FRAMEWORK_STOP`, `APFS_DATA_REARMED=YES`, `APFS_CLONE_READY=UNUSED_ONE_SHOT`. The host then reported 28-zone prepare PASS, passive probe preflight PASS, and printed `SHORT_PROBE_REQUESTING_REAL_IOS_GUEST` and `SHORT_PROBE_TIMEBASE=REBOOT_REQUEST_DEADLINE_300S_AFTER_FRAMEWORK_STOP`.

**Outcome:** `SHORT_PROBE=BLOCKED_OR_UNVERIFIED no independently observed healthy new One UI boot: no new healthy One UI boot observed after an ADB loss within bounded window`. The operator additionally reported **no visible Android Framework stop, no iOS screen and no reboot**. This is **NOT** a successful 300-second Framework takeover. The host's printed request marker precedes the actual remote `setsid` launch; it cannot alone prove switch execution. A missing new-boot witness likewise **cannot prove the switch never started** or that APFS Data remains unused. The exact on-device cause is unresolved until saved per-token `preboot-switch-*.log` / `logs/probe-<token>.log`, thermal stream, `control/state` and `data.consumed` are inspected.

**Collector deficiency found in source:** `sm8850-takeover-short-probe.py` raises when no postboot witness exists *before* writing the normal JSON artifact and milestone summary. Host filesystem logs are nevertheless written. Do **not** repeat the physical probe merely to obtain the missing JSON. The isolated experiment now includes `scripts/phone/sm8850-cpu90-failed-launch-forensics.sh` to read the saved host files and fixed on-device receipts **without** rearm, guest launch, watchdog opens or reboot.

The original conservative P0 branch retains CPU 55 C; its prior 75.2 C CPU fault is separate physical evidence. CPU 90 C remains **vendor-unqualified**, recovery and watchdog independence are not certified, and the 600s full run stays blocked. Next action is read-only log forensics only; do not automatically rearm or retry.
