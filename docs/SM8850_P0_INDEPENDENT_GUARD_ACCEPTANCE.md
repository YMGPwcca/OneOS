# SM8850 P0.2 — Independent thermal recovery acceptance contract

**Target:** SM-S948B / m3q / S948BXXS4BZIG. **Current status: DESIGN / EVIDENCE ONLY — NO LIVE GUARD.**

## Physical facts and unresolved risks

- Operator-verified OneOS source revision `a8042e3dd6ff5a1e55ad436a75b52df0b16fb0b4`: **107/107 CachyOS offline PASS**. On intact One UI, a combined four-sensor read-only run yielded CPU 35.8/36.2/36.2 C, BAT 29.6 C, LRP 31.5 C and BOARD_AP 31.3 C. This establishes named-node access, **not thermal recovery**.
- Existing `runtime/bridges/thermal/thermal.c` in OneiOS groups the highest genuine `cpu-*`/`cpuss-*`, `gpuss-*`, and `ddr` readings (optional `xo-therm`) and excludes `cpu-hw-trip-*` constants. One CPU candidate `cpu-0-5-1` is not sufficient to protect the SoC. The existing bridge runs **inside `xnuhost`** and is not active with `bridges=0`.
- The OneiOS bridge's present temperature thresholds and hysteresis are implementation policy with some explicitly documented guesses. **Do not promote these values into P0.2 reboot thresholds** without independent firmware/thermal-team validation.
- OneOS's current `oneios_switch.sh` already has an unconditional source refusal for actual `--framework-session run`, before APFS Data consumption and Framework stop. **Old scripts staged on the phone are not updated by this PR.**

## Proposed process ownership (not yet implemented)

1. **Admission:** root-owned OneOS switcher verifies exact model/build, SELinux Enforcing, current boot ID, independent APFS Data clone, current-boot sensor-type manifest, all required CPU/GPU/DDR + BAT/LRP/AP sensor availability, watchdog/return provenance, and both supervisor binaries' hashes. Fail if **any** check is unknown. Arm separately from `xnuhost` **before** stopping Framework; no permissive environment bypass.
2. **Root monitor:** separate process outside guest mount namespace, guest cgroup, One UI app cgroups and `xnuhost` PID tree. Acquire the genuine sensor manifest from the verified boot, sample all required live junctions and the three Samsung nodes, publish atomic heartbeat and event records under root-only control. Never rely on HAL, `dumpsys` or a Framework service after stop.
3. **Independent deadline/health supervisor:** owns the hard monotonic deadline and monitors **PID + `/proc/PID/stat` birth ticks**, the verified boot ID, `watchdog.generation`, launch token, strictly increasing heartbeat sequence and clock, freshness TTL, and `xnuhost`/return-path state. `oneios_sm8850_thermal_health.sh` currently tests only a **fixture contract**; it is not this running process.
4. **Fail-safe return:** any critical genuine sensor temperature, missing/invalid sensor, failed per-boot type revalidation, stale heartbeat, monitor exit/reuse, generation mismatch or deadline expiration causes a single generation-bound `return.request`, with durable event evidence, and enters the existing **reboot-only** OneOS `oneios_return.sh` path. Do not open another `/dev/watchdog`, modify kernel trips/governors, or assume in-place Android Framework restore is supported.
5. **Return proof:** persist request, escalation, reboot attempt and next-boot receipt with previous and new boot IDs; check normal boot completion and the absence of leftover unsafe guest/process/lock artifacts. A request to reboot or a changed boot ID alone is **not** a proven successful return. Root loss from DirtyFrag must be called out separately rather than silently accepted.

## Failure contract (minimum behavior)

| Event | P0.2 required outcome |
| --- | --- |
| Missing CPU/GPU/DDR required group at admission | Block launch; leave One UI running |
| Wrong zone type or invalid/sentinel/stale value | Block launch, or request return if Framework is already stopped |
| Critical threshold crossed | Request return immediately; no cooldown masking; threshold must be firmware-qualified |
| Monitor PID died, zombie, or PID reused | Independent supervisor requests return |
| Supervisor stalled or killed | Separately proven last-resort deadline/watchdog performs return; otherwise **NOT ACCEPTED** |
| Wrong boot ID, watchdog generation or launch token | Ignore stale worker, deny new admission, log identity mismatch |
| Returner did not produce verified normal One UI reboot | Mark recovery failed, never report P0 acceptance |

## Gates to close in order

- **P0.2-A — Sensor set:** run the read-only CPU/GPU/DDR/XO inventory with all errors preserved. Verify that the OneOS sensor-set classification and OneiOS bridge agree. No root enumeration; all temperature accesses must be exact type-validated paths.
- **P0.2-B — Vendor policy:** inspect firmware/DT thermal trips and Samsung LRP/battery protection; agree critical limits and sampling interval with grounded evidence. The bridge's present `skin`, `soc`, `battery` test policies are **not certification**.
- **P0.2-C — Monitor implementation:** deterministic fixture-mode lifecycle, atomic heartbeat, independent cgroup/namespace, bounded reads, strict boot/run token, fail-closed sensor semantics and death supervision. Run local fault injection first.
- **P0.2-D — Recovery implementation:** thread monitor event to the **existing** reboot-only return path while keeping source 600s block unconditional. Verify receipts, no duplicate/stale return, and actual unassisted reboot on a separately authorized, short recovery smoke test.
- **P0.2-E — Admission acceptance:** prove full independent monitor survives loss of `xnuhost` and Android Framework and that every failure reliably returns normal One UI. Only then create an explicit reviewed change to the source admission block; do not use a runtime flag/ACK to bypass.

**No change in this document authorizes a 600s full takeover.** Until P0.2-D/E and vendor thresholds are accepted, the old staged phone script must be considered unsafe regardless of passing offline CI.


## P0.2-A progress — One UI sensor inventory complete, production admission not qualified

- CachyOS offline 123/123 PASS on `cdcc89d211fe8af4b10833dd248aad0405897664` and physical One UI survey: 28 selected real zones, no read or type errors, required CPU/GPU/DDR present; XO optional unavailable. Group peaks CPU 37.0 C, GPU 35.1 C, DDR 35.1 C. This closes the **snapshot discovery subtask only**.
- A new explicit offline manifest builder validates that 28-zone JSON evidence, binds discovered paths to the source boot ID and fingerprints content without claiming a signature. New 16 regression tests (139 proposed total) are pending CachyOS.
- **Still required for P0.2-A admission:** independently recheck current-boot sensor-type mappings and all required zones from the actual root monitor, prove sensor accessibility after Framework stop without depending on Android HAL/system_server, and bound missing sensor/read errors. Complete inventory with One UI up does not satisfy these conditions.
- P0.2-B through P0.2-E remain open; the unconditional source 600s run block is unchanged.


## 2026-11-21: finite live One UI root monitor + separate supervisor smoke

The operator's last accepted baseline is **139/139 offline tests PASS** at OneOS commit `efe371475b92f5d7e27abfbb8f1b2983bfb16ca6`. The offline manifest builder accepted all **28 real CPU/GPU/DDR thermal zone** records from the physical One UI survey, returned source boot ID `a6007f1e-4fc3-4e99-82dd-267ccb249656`, and wrote a fingerprinted **non-authorizing** JSON. It did not run a production guard or authorize takeover.

**Now implemented for separate physical validation:**

- `switcher/assets/oneios_sm8850_thermal_trial.sh`: a **FINITE, opt-in, read-only** root process trial. It runs a sampling worker and a sibling supervisor as **two separate process IDs**, uses `boot ID / shadow generation / random launch token / worker PID / process birth ticks / heartbeat sequence / monotonic age`, reads all selected genuine CPU/GPU/DDR sensors by exact type-bound paths plus BAT/LRP/board AP, and emits peak temperatures. It rejects missing sensors, type changes, a stale boot, bad heartbeat, monitor death, PID reuse, or heartbeat timeout. All records are limited to a fresh private `/data/local/tmp` stage and written using same-directory atomic rename.
- `scripts/phone/sm8850-live-thermal-trial.py`: default audit makes **zero ADB calls**. The operator must use explicit `--run-readonly`; it re-inventories the real stock One UI zones, validates an exact current-boot manifest in memory, verifies SHA256 of the staged source and manifest, and runs **two finite scenarios**: 3 normal samples; then a controlled worker self-exit after 2 samples, which the sibling supervisor must detect. A monitored worker exit is not a real Android/guest kill and requires no reboot. Cleanup targets only its own randomized stage and fails closed if it cannot verify stage removal.
- `tests/test_sm8850_thermal_live_trial.py` (9 fixture tests) and `tests/test_sm8850_thermal_live_host.py` (6 no-device host tests) are new. They **PASS on assistant Linux fixtures/mocks**, but remain **PENDING operator CachyOS** on the exact new GitHub revision. Runner now requires **154 total**. No physical live trial has yet been performed.

### Explicit limitation: this is **not P0.2-C/D/E acceptance**

The worker and supervisor are siblings within one root `su` diagnostic session, not yet independently owned/surviving OneOS's Framework-stop cgroup/namespace transfer. The supervisor only prints `WOULD_REQUEST_RETURN_NOT_EXECUTED` on failure; **there is no return.request write, no watchdog manipulation and no reboot**. Firmware-calibrated critical limits are intentionally not fabricated. A third-level fail-safe for supervisor death and a verified unassisted reboot into One UI remain unproven. These must be implemented, tested under bounded short recovery conditions, and independently audited before removing the unconditional 600-second source gate.

Operator smoke command after exact source revision and complete local CI:

```bash
python3 scripts/phone/sm8850-live-thermal-trial.py  # audit only, no ADB
python3 scripts/phone/sm8850-live-thermal-trial.py --run-readonly \
  --adb "$HOME/Android/Sdk/platform-tools/adb" \
  --output "$HOME/projects/OneiOS/out/sm8850/live-thermal-trial"
```

**Do not stage the old switcher or run a full iOS takeover to execute this diagnostic.**
