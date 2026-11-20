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


## Next root-side acceptance: protected staging + detached ADB launcher (2026-11-21)

The operator physically confirmed **154/154 offline P0 tests PASS** on exact OneOS `906309940e7fcd4b75a634c1feca5eecfa475768` and ran the real finite root sensor worker plus separate sibling supervisor on intact SM-S948B stock One UI. **28 genuine type-validated CPU/GPU/DDR zones** sampled successfully. A normal 3-sample trial completed; an intentional two-sample worker exit was detected as `SUPERVISOR=WOULD_REQUEST_RETURN_NOT_EXECUTED reason=monitor_dead`. The observer reported `P0_RECOVERY=NOT_QUALIFIED` and never rebooted or issued a return request. The physical host evidence path was `out/sm8850/live-thermal-trial/root-thermal-smoke-20261120T193146Z-da448d.json` (JSON not directly inspected).

**New source (awaiting operator CachyOS and phone test):**
- The live-trial host now transfers ownership of its random temporary stage, root observer script, manifest and identity to **UID 0** before launching the child processes. It verifies root ownership and then rechecks their **SHA256 as root**. This closes the prior shell-owned staging replacement window; a failed hash/owner check refuses a run and tries bounded stage cleanup.
- The shell trial records the parent process' PID, process birth and Linux **session ID**, and the supervisor's PID and birth separately from the worker. A new, explicitly opt-in **`--run-detached-readonly`** mode launches a **4-tick finite trial** with the root manager's BusyBox `setsid` and redirected file descriptors. The original ADB shell command terminates; the host then reconnects through **new** ADB shell commands to inspect real completion records and to verify the parent SID/PID binding and three distinct process IDs. It deletes its own temporary stage afterward.
- The original **`--run-readonly`** normal/fault smoke remains available. The two modes are mutually exclusive and **default to a no-device audit**. Neither controls Framework, kills Android services, changes thermal limits, touches `/dev/watchdog`, issues `return.request`, reboots nor launches iOS.
- Five new source-level/fixture/mock host test cases were added compared with the operator's previous 154-test checkpoint, so `tests/run_sm8850_thermal_local.sh` now requires **159 tests**. The impacted 20-case live-trial test subset (including detached and ownership cases) **PASS in assistant Linux**, but **159/159 has not yet been executed by the operator's CachyOS**.
- A successful detached trial would prove independence from **the initiating ADB shell command/session only**. `setsid` does **NOT** establish independent cgroup/namespace ownership, survival after `adbd` or Android Framework stop, or safety if the supervisor itself dies.

**P0 remains OPEN.** Before lifting the unconditional 600-second source lock, we still need a real independent deadline that survives Framework and supervisor failure, vendor-grounded critical temperatures, authenticated reboot-only return generation binding, and a recorded physical **unassisted reboot into healthy One UI**. No passing test or new stage manifest authorizes a full takeover.


## P0 detached trial regression found by operator (2026-11-21)

- User's CachyOS fetched exact OneOS source revision `77761d26f774b3e63d6c084de2ce5f7c8ac8a6e0` and started strict 159-case local CI. **154 tests succeeded; five fixture live-trial tests FAILED** before any phone trial, with `THERMAL_TRIAL=BLOCKED reason=parent_identity_unavailable`.
- Root cause in the newly added PID/SID receipt source: POSIX shell `$$` was accidentally collapsed to a single `$` in five places in the parent/supervisor identity code. As a result the attempted parent path was `/proc/$/stat`, not `/proc/<actual-pid>/stat`. Those five observed failures stemmed from this source defect; there is no evidence of a physical sensor/reboot failure.
- **Fixed source**: restore `$$` in both `birth_ticks` calls, both identity records and the parent `/proc/$$/stat` SID path. Strengthened existing `test_syntax` to assert all exact required PID tokens, without increasing the 159-case count. Verified updated GitHub blob contains the intended five `$$` sites and test assertions; **combined 159/159 and detached physical run must still be confirmed on operator CachyOS**.
- Important: prior physical root worker + supervisor test **154/154 local PASS** and actual One UI 28-zone read with safe monitor death injection remain valid. No 600-second Framework takeover, thermal return/reboot or watchdog action was initiated by this failed CI; source P0 admission lock stays unconditional.

## 2026-11-21 operator: detached root process accepted on physical S26 Ultra

- Operator's CachyOS fetched **exact OneOS `98ca3482c762677b76c1fb3dd6f24ef626e76059`**, executed the strict suite: **`ONEOS_P0_OFFLINE_159=PASS`**. All previously failing parent/session identity tests now pass.
- Explicit `--run-detached-readonly` on physical SM-S948B/m3q (One UI intact): `ZONES=28`; four root-side sensor ticks, followed by `MONITOR=FINITE_SMOKE_DONE samples=4 physical_return=NO` and `SUPERVISOR=MONITOR_COMPLETED_SEPARATE_PID samples=4 physical_return=NO`. Host reported `LIVE_THERMAL=ROOT_OBSERVER_AND_SUPERVISOR_TESTED_NO_PHYSICAL_RETURN`, scenario `detached-normal` and `P0_RECOVERY=NOT_QUALIFIED`.
- Four ticks (C): CPU peak **34.2, 31.9, 30.7, 31.5**; GPU peak **30.1, 30.1, 29.7, 29.7**; DDR peak **30.1, 30.1, 29.7, 30.1**.
- Physical evidence path (not uploaded as raw JSON): `out/sm8850/live-thermal-trial/root-thermal-smoke-20261120T195642Z-c3d826.json`.
- **Accepted for only this subgate:** root-owned staging, independent PID/SID identities, and monitor/supervisor completion after the initiating ADB shell disconnects under stock One UI. This does not prove actual Framework-stop independence, supervisor death fallback, hardware watchdog, or reboot-to-OneUI recovery; no return/reboot action occurred.
- P0 remains incomplete. Source P0 full 600s Framework takeover refusal remains unconditional. Next work must focus on recovery contract/provenance and independent deadline rather than expanding thermal readers.


## P0 recovery provenance read-only inspector (2026-11-21)

- **Operator-verified:** exact OneOS `98ca3482c762677b76c1fb3dd6f24ef626e76059` completed **159/159 CachyOS offline PASS** and an actual detached `setsid` four-tick thermal root monitor/supervisor trial across all **28** selected CPU/GPU/DDR zones: finite monitor completed, separate-PID supervisor completed, no physical return/reboot. The initiating ADB shell disconnected successfully; the result still reported `P0_RECOVERY=NOT_QUALIFIED`. Original host evidence: `out/sm8850/live-thermal-trial/root-thermal-smoke-20261120T195642Z-c3d826.json`.
- **New OneOS source**: `scripts/phone/sm8850-recovery-provenance.py` (default **audit-only**, zero ADB). The explicitly opt-in `--run-readonly` path checks current stock One UI boot identity, `init.svc.zygote`, boot reason and **only fixed** historical root-owned OneOS control/return evidence paths under `/data/adb/oneios-m3q-framework`; emits a restricted-permission JSON. Missing/unreadable historical files remain **unknown** rather than PASS. It does not write phone state, operate guest/watchdog or reboot.
- It can report that an old reboot-outcome marker and a changed boot ID are **consistent** with a historical reboot-only return. **This cannot establish unassisted recovery, intact root across reboot, independent guard survival or hardware watchdog certification**, even when a correlation exists; `unassisted_return_proven=false`, `recovery_certified=false` and `full_takeover_allowed=false` are unconditional.
- **Nine new offline test cases** in `tests/test_sm8850_thermal_recovery_provenance.py` passed 9/9 in the assistant's Linux container using mocked Android property and ADB responses. Strict combined runner now expects **168**, with the operator's accepted baseline at 159/159; operator CachyOS validation of new 9 and physical read-only provenance inspection **pending**.
- **Next mandatory P0 gate:** independently observed short **reboot-only** recovery with the physical device, plus verified next-boot One UI, and separately qualified thermal deadlines/guard survival. This historical inspector deliberately does not and cannot replace that disruptive acceptance.


## 2026-11-21 P0 historic reboot-only marker correlation verified on physical phone

- Operator fetched exact OneOS commit `a46074ded2a33dfdcf6ff57feff12b5ca1c5039d`, executed the **9 new offline provenance tests** on CachyOS: **9/9 PASS**. This was a targeted test run, not the full proposed 168-case suite.
- The opt-in live **read-only** provenance inspector on intact S26 Ultra reported: `NORMAL_ONEUI_NOW=YES`, `PREVIOUS_BOOT_DIFFERENT=TRUE`, `HISTORICAL_REBOOT_RETURN_CORRELATION=TRUE`, `UNASSISTED_RETURN=NOT_PROVEN` and `P0_RECOVERY=NOT_QUALIFIED`. Evidence path reported as `out/sm8850/recovery-provenance/recovery-evidence-20261120T200612Z-c6706c.json` (raw JSON was not uploaded for direct inspection).
- The historical markers are consistent with the phone having rebooted through the OneOS reboot-only pathway on a previous boot. Neither the marker nor a different current boot proves it occurred without human intervention, that it was caused by the independent deadline, or that a thermal sensor failure triggers an actual reboot.

### New host-only active-witness groundwork (not yet operator verified)

- Added `scripts/phone/sm8850-reboot-witness.py` with **default zero-ADB audit**. Explicit `--observe-only` performs ONLY host ADB reads: saves intact One UI identity and boot ID **before** a separately authorized short recovery smoke, observes an ADB transport interruption, then requires a **new boot ID and fully running One UI** within a bounded interval (30–600 sec). It can afterward correlate historical control/outcome evidence to the exact pre-smoke boot.
- This observer **does not trigger reboot, Framework stop, guest, watchdog or return.request**. A USB disconnect alone cannot count as a new healthy boot. Even with a postboot and matching marker, output always includes `unassisted_return_proven=false`, `recovery_certified=false`, `p0_complete=false`, and `full_600s_takeover_allowed=false` because physical key use cannot be ruled out from ADB alone.
- Ten new offline-only fault cases verify mode audit, transport loss, postboot identity, marker mismatch, missing events, false USB flaps, and mandatory non-certification. Strict test runner now requires **178** total. **These new 10 have not yet run on the operator's CachyOS**. Only start a future witness just before a separately approved short reboot-only recovery smoke; do not use a 600-second full takeover for this validation.
- Remaining P0 blockers remain a real Framework-independent thermal monitor/deadline, vendor-grounded critical temperatures, supervisor-death last resort, and a **witnessed unassisted** successful reboot-only return. No source full-takeover bypass was added; PRs stay draft.


## 2026-11-21 opt-in REAL iOS takeover short probe integrated in OneOS

- The S26 Ultra owner explicitly requested a physical iOS takeover experiment, rather than further blocked fixture tests. The OneOS P0 draft branch now introduces `--framework-session probe`: a REAL xnuhost/iOS guest session, not just a Framework-only smoke, bounded to **90 s after verified Framework stop** and followed by existing **mandatory reboot-only** return. Source `--framework-session run` **600 s remains blocked unconditionally**.
- `switcher/assets/oneios_sm8850_thermal_takeover_guard.sh` reads the **current boot's complete mapped CPU/GPU/DDR sensor set plus BAT/LRP/board AP** once per loop, from init's namespace/root cgroup outside xnuhost. The script uses root-only stage manifest, exact per-zone type and boot checks, and publishes atomic generation/PID-birth/sequence/monotonic heartbeat. It **does not itself reboot or touch watchdog/governors**. The already-existing independent `framework-deadline` and watcher each check liveness/heartbeat, triggering the **existing OneOS reboot-return** when sensor read fails, values exceed early-abort cutoffs, worker dies, or heartbeat stalls.
- **Deliberate experimental early-abort cutoffs, NOT vendor-qualified hardware critical limits:** real CPU/GPU/DDR peak >=55 C, battery >=38 C, LRP/board AP >=42 C. If a sensor vanishes after Framework stop the guardian fails closed and recovery helpers should request immediate return. This is not production safety certification.
- New `scripts/phone/sm8850-takeover-short-probe.py` has default **zero-ADB audit**. The explicit `--run-90s` action re-inventories sensors on intact One UI, creates a fresh boot-bound manifest, root/SHA-verifies and backs up the staged switch, checks the original OneOS image/runtime/APFS one-shot clone/legacy-watchdog/previous smoke preflight, starts an independent host reboot witness, and **then intentionally starts the REAL disruptive iOS guest** via root setsid. `--prepare-probe` only stages sources and does not change Framework. After a new normal One UI boot, it records host witness and launch markers separately; no guest-start PASS is inferred merely from reboot.
- `docs/SM8850_SHORT_GUARDED_IOS_PROBE.md` documents the single command, actual phone reboot risks, emergency hardware restart, and data clone preconditions.
- **Important validation distinction:** the previously confirmed 159/159 CachyOS and live 28-zone detached trial/9+10 target tests were for earlier source. This new takeover integration has **NOT** been executed on the operator's CachyOS or S26; all physical results from the new probe are **pending**. Existing 178-case CI runner now syntax-checks the two new files without adding more test methods; it continues to require the original 178 cases.
- This is **experimental opt-in enablement**, not closure of P0 production acceptance: real Framework stop + rebinding risks remain, vendor watchdog and unassisted physical recovery not yet independently certified. But unlike the 600s branch, the short iOS probe is source-enabled and may be exercised at the owner's explicit request.
