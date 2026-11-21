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
