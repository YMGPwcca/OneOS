# SM8850 P0 thermal guard groundwork — evidence and offline contract

**OneOS | SM-S948B / m3q / SM8850 | firmware S948BXXS4BZIG**
**Status: reader prototype and policy simulator only. NOT a running guard. Full takeover remains BLOCKED.**

## Operator-verified physical evidence (2026-11-20)

With fully running One UI and SELinux Enforcing, OneiOS P0.1 collected 6 temperatures from Android `dumpsys thermalservice`: AP 28.7 C (HAL type CPU), BAT 26.6 C (BATTERY), PA 28.5 C (POWER_AMPLIFIER), SKIN 28.9 C (SKIN), SUBBAT 0 C (BATTERY), USB 25.7 C (USB_PORT). SUBBAT's 0 is **not certified as a valid cold cell reading**.

A second snapshot from Android HAL included BAT 29.5 C and SKIN 31.8 C. Unprivileged ADB reads of `battery/temp` and `battery/lrp` failed with `Permission denied`; a repeat *opt-in, exact-path* root read succeeded:

| Samsung kernel node | Raw representation | Operator root/shell sample | Status |
| --- | --- | --- | --- |
| `/sys/class/power_supply/battery/temp` | tenths C | 285 -> 28.5 C | root named-cat READ |
| `/sys/class/power_supply/battery/lrp` | tenths C | 303 -> 30.3 C | root named-cat READ |
| `/sys/class/sec/sec-ap-thermistor/temperature` | tenths C | 297 -> 29.7 C | shell named-cat READ |

The measurements were taken at different times; matching names or close values do **not** establish that HAL BAT = kernel battery or HAL SKIN = Samsung LRP, nor that any sensor can be read after `system_server` stops. OneiOS has a reusable Samsung thermal reader in `runtime/bridges/thermal/thermal.c`, but its `xnuhost` bridge is inactive during `bench/bridges=0`.

## What this branch adds

- `switcher/assets/oneios_sm8850_thermal_reader.sh`: one-shot, strict firmware-scoped, **read-only** Samsung sensor reader. It reads the three **exact named** paths, `/proc/uptime`, and boot ID, with pre/post boot consistency. `--fixture-root DIR` runs entirely from fake sysfs in host tests. `--live-readonly` requires root, a fully booted stock One UI and Enforcing SELinux; it is not automatically invoked, deployed, or started by the switcher.
- `tests/sm8850_thermal_policy_sim.py`: **Python-only simulation**, NOT production Android code, for critical return requests, sustained warning, hysteresis and fail-closed semantics on invalid/stale/missing/zero reading, wrong boot/run, missing watcher and reversed timestamps. Threshold numbers in tests are artificial fixtures, **NOT SM8850 hardware limits**.
- `tests/test_sm8850_thermal_guard_p0.py`: **14 offline regression tests**, no ADB, no root, no actual reboots.

This branch does **not** change the switcher, returner, watchdog ownership, CPU/GPU clocks or OneiOS app availability. A simulator's `RETURN_REQUESTED` is just a state label; no physical return is issued. Sensor 0 is rejected (unknown), not silently interpreted as 0 C or as the previous safe value. The shell reader exits nonzero if any required named sensor is missing, malformed or outside the conservative parser acceptance range.

## Local-first test (CachyOS)

```bash
cd ~/projects/OneOS
git fetch origin refs/heads/feat/sm8850-p0-thermal-reader-sim:refs/remotes/origin/feat/sm8850-p0-thermal-reader-sim
git worktree add --detach /tmp/oneos-p0-thermal-sim origin/feat/sm8850-p0-thermal-reader-sim
python3 /tmp/oneos-p0-thermal-sim/tests/test_sm8850_thermal_guard_p0.py -v
sh -n /tmp/oneos-p0-thermal-sim/switcher/assets/oneios_sm8850_thermal_reader.sh
```

The script's default invocation does **nothing** and refuses. The only live mode is an explicitly requested single read when One UI is up: **it is not a protective background monitor**. No new physical test is required to accept the offline work.

## Fixture-only end-to-end validation (additional 2026-11-21 work)

The original **14/14 offline regression tests passed on the operator's CachyOS** checkout at `~/projects/OneiOS/app`. That was a real user-reported local execution, not a live thermal guard.

This branch now also includes:
- `tests/sm8850_thermal_e2e_dryrun.py` — connects the **actual three-node shell reader** to the pure fail-closed policy model, only from explicitly provided host fixture files. Requires exact synthetic boot ID, watchdog generation, launch token and watcher-health fixture. It checks them before and after each reading and refuses duplicate/malformed reader output, root/symlink escapes, expired or reversed sample intervals and sensor/read timeouts. Every event explicitly declares `live_thermal_guard=false` and `physical_return_issued=false`; the only proposed action is `WOULD_REQUEST_RETURN_NOT_EXECUTED`. Terminal simulations return nonzero (4).
- `tests/test_sm8850_thermal_e2e.py` — **19 additional end-to-end regression tests**, using real shell reader invocations with fake sysfs, injected errors, synthetic watcher death, critical latching and strict output admission.
- Validation on assistant-side local Linux: **14/14 original + 19/19 new tests PASS**. The operator subsequently ran **19/19 additional E2E tests PASS on CachyOS**, for **33/33 total original tests PASS**. No Android device was contacted by these changes.

All threshold values in these fixtures are fake and NOT firmware-calibrated. The Python harness requires a host Python interpreter, is not deployed as an Android process and does not guarantee live monitoring, unassisted return, independent survival after `xnuhost` death, or kernel-level throttling.

### Local CachyOS command (existing checkout remains unchanged)

```bash
(
  set -euo pipefail
  REPO="$HOME/projects/OneiOS/app"
  git -C "$REPO" fetch origin \
    refs/heads/feat/sm8850-p0-thermal-reader-sim:refs/remotes/origin/feat/sm8850-p0-thermal-reader-sim
  TEST_DIR=$(mktemp -d /tmp/oneos-sm8850-p0-e2e.XXXXXX)
  git -C "$REPO" archive origin/feat/sm8850-p0-thermal-reader-sim \
    switcher/assets/oneios_sm8850_thermal_reader.sh \
    tests/sm8850_thermal_policy_sim.py \
    tests/test_sm8850_thermal_guard_p0.py \
    tests/sm8850_thermal_e2e_dryrun.py \
    tests/test_sm8850_thermal_e2e.py | tar -xf - -C "$TEST_DIR"
  python3 "$TEST_DIR/tests/test_sm8850_thermal_guard_p0.py" -v
  python3 "$TEST_DIR/tests/test_sm8850_thermal_e2e.py" -v
  echo "THERMAL_P0_OFFLINE_E2E=PASS"
)
```

The harness must **never** be pointed to a physical root or provided real operator tokens in place of its synthetic fixture inputs. It does not open ADB, write a `return.request`, control watchdogs or reboot.

## P0.2 follow-up: source-level takeover lock + bounded shadow observer (2026-11-21)

**Physical operator CachyOS evidence:** **14/14 original + 19/19 E2E tests = 33/33 PASS** on the operator's actual Linux host, with **no phone takeover**.

Additional changes in this draft branch:

- **Fail-closed source gate** in `switcher/assets/oneios_switch.sh`: on the SM8850 `--framework-session run` path, a non-bypassable `framework_block` rejects unqualified 600-second iOS takeover **before APFS Data consumption, Framework stop, watchdog transfer, or guest start**. The gate has no environment override, acknowledgement-token override or policy fixture bypass. The read-only `--framework-check run` path remains available and now prints `P0_FULL_600S_TAKEOVER=BLOCKED_UNQUALIFIED_THERMAL_GUARD` to distinguish preflight from authorization. The gate exists **only in this source branch until reviewed and explicitly staged**; an already staged old copy on the phone is **NOT** retroactively protected.
- **`switcher/assets/oneios_sm8850_thermal_shadow.sh`**: a bounded, root-only One UI *observer* mode or isolated `/tmp` fixture mode. Both invoke the **real existing named-node shell reader** with a 3-second subprocess timeout per sample and at most ten samples. The fixture mode binds synthetic boot ID, watchdog generation, launch token and watcher-alive marker before/after each read, rejects linked/outside-root files and strictly validates all eight output fields. Live root mode is explicitly `--live-oneui-readonly`, requiring stock One UI for the underlying reader; it has no post-Framework path and no automatic launch. It pins boot ID across samples, emits telemetry only, and **never writes a return request, reboots or opens watchdog**. On faults it exits nonzero with `FAIL_CLOSED_NO_PHYSICAL_ACTION` — which is **diagnostic fail-closed, not physical safety**.
- **`tests/test_sm8850_thermal_shadow.py`** adds **17 new offline tests**: 14 observer and fake-sensor cases (tested in assistant Linux container, including real shell-reader invocations), plus 3 source-gate syntax/order/static tests. All 17 **PASS on operator's CachyOS** at commit `5185a642ab7c7d29aa0f2d758fd04ac7b2f3af15`. **The operator subsequently ran 17/17 on CachyOS at commit `5185a642ab7c7d29aa0f2d758fd04ac7b2f3af15`; the combined offline result is 50/50 PASS.** The test suite does not operate the real S26.
- No phone staging, root shell session monitoring, returner modifications, watchdog ownership modifications or physical thermal protection was performed.

### Run only the new 17 tests on CachyOS

```bash
(
  set -euo pipefail
  REPO="$HOME/projects/OneiOS/app"
  git -C "$REPO" fetch origin \
    refs/heads/feat/sm8850-p0-thermal-reader-sim:refs/remotes/origin/feat/sm8850-p0-thermal-reader-sim
  TEST_DIR=$(mktemp -d /tmp/oneos-sm8850-p0-shadow.XXXXXX)
  git -C "$REPO" archive origin/feat/sm8850-p0-thermal-reader-sim \
    switcher/assets/oneios_switch.sh \
    switcher/assets/oneios_sm8850_thermal_reader.sh \
    switcher/assets/oneios_sm8850_thermal_shadow.sh \
    tests/test_sm8850_thermal_shadow.py | tar -xf - -C "$TEST_DIR"
  sh -n "$TEST_DIR/switcher/assets/oneios_switch.sh"
  sh -n "$TEST_DIR/switcher/assets/oneios_sm8850_thermal_shadow.sh"
  python3 "$TEST_DIR/tests/test_sm8850_thermal_shadow.py" -v
  echo "P0_THERMAL_SHADOW_OFFLINE=PASS"
)
```

**Do not run the root-only live observer or stage the updated switcher for takeover to complete these tests.** The new code is a bounded measurement primitive and a conservative source block, **not** the mandatory independently supervised thermal return guard required to proceed.

### Remaining before any thermal guard acceptance

The live root-owned process must run outside the iOS guest namespace and be independently supervised, with pre-stop binding to actual boot/run identities, a real, trusted **SoC junction sensor** in addition to battery/case/board, firmware-qualified limits, bounded monitor-death response and an independently audited reboot-only return request with durable evidence. This has **not been implemented**. The existing switcher may still need a separate safe staging/update path to enforce the new source-level block on the actual device; no such deployment happened here.


## Independent thermal process-health *contract* (fixture-only; 2026-11-21)

New `switcher/assets/oneios_sm8850_thermal_health.sh` defines the **future** return-guard-side admission check, currently supported **only** as `--fixture-root` under `/tmp`. It binds:

- expected verified boot ID;
- watchdog generation (the switcher's exact run-generation record);
- 32-hex launch token (`framework.launch`);
- `control/thermal.monitor` as monitored PID + Linux process-birth start ticks;
- `control/thermal.heartbeat` as exact `v1 boot generation launch pid birth sequence sample_ms OK`;
- a monotonic-now timestamp and a bounded age allowance (1..30000 ms).

It rechecks current boot/run, rejects missing or symlink-escaping fixture files, mismatched/reused monitor PID, missing or zombie proc state, malformed/multiline heartbeat, future/stale samples, bad status and changed identity during inspection. The only possible outputs are `THERMAL_HEALTH=FRESH_FIXTURE_ONLY` or `FAIL_CLOSED_FIXTURE_ONLY` **without a physical action**. It never opens `/dev/watchdog*`, calls the returner or runs outside host fixtures; it does **not** publish or supervise actual heartbeat files on the phone. This explicitly tests the **contract**, not a live independent watchdog.

`tests/test_sm8850_thermal_health.py` adds **17 offline cases** (healthy, stale/future, missing/forged boot, generation, launch, PID birth reuse, process death/zombie, malformed heartbeat, symlink escape, bad TTL and disabled live mode). All 17 **PASS on operator's CachyOS** at exact commit `d8759313e90da0f2af849b7150bc9aede36dcbf2`, bringing the combined verified offline suite to **67/67 PASS**.

The next P0 work remains: a real, independently run and supervised root-side monitor that continuously publishes this heartbeat outside the guest namespace/cgroup, firmware-source-qualified sensor/threshold policy including a genuine SoC junction, and an independently proven mandatory reboot-only recovery path. No bypass to the 600-second source gate exists in this branch.



### Single local CI entrypoint (67 cases)

The branch now provides `tests/run_sm8850_thermal_local.sh` to prevent the earlier false PASS caused by a malformed Git refspec and a shell that continued after extraction failed. It validates the **four** POSIX shell files with `sh -n`, runs all four `test_sm8850_thermal_*.py` regression modules with Python unittest discovery, checks the exact expected 67 tests and `OK`, then emits `ONEOS_P0_OFFLINE_67=PASS` **only after every prerequisite succeeds**. There is no ADB, root, watchdog or phone action in this runner.

To run after the branch has been fetched on CachyOS, export the exact current HEAD into a fresh scratch directory and invoke the script there; never replace an existing checkout or staged phone files:

```bash
bash -c '
set -Eeuo pipefail
REPO="$HOME/projects/OneiOS/app"
BRANCH="feat/sm8850-p0-thermal-reader-sim"
git -C "$REPO" fetch --no-tags origin "$BRANCH"
REV=$(git -C "$REPO" rev-parse --verify "FETCH_HEAD^{commit}")
echo "ONEOS_HEAD=$REV"
SCRATCH=$(mktemp -d /tmp/oneos-p0-local.XXXXXX)
git -C "$REPO" archive "$REV" \
    switcher/assets/oneios_switch.sh \
    switcher/assets/oneios_sm8850_thermal_reader.sh \
    switcher/assets/oneios_sm8850_thermal_shadow.sh \
    switcher/assets/oneios_sm8850_thermal_health.sh \
    tests/sm8850_thermal_policy_sim.py \
    tests/sm8850_thermal_e2e_dryrun.py \
    tests/test_sm8850_thermal_guard_p0.py \
    tests/test_sm8850_thermal_e2e.py \
    tests/test_sm8850_thermal_shadow.py \
    tests/test_sm8850_thermal_health.py \
    tests/run_sm8850_thermal_local.sh \
    | tar -xf - -C "$SCRATCH"
bash "$SCRATCH/tests/run_sm8850_thermal_local.sh"
'
```

**Current verification:** previous 50/50 cases PASS on CachyOS at `5185a642ab7c7d29aa0f2d758fd04ac7b2f3af15`; the 17 heartbeat checks and the 67-case combined runner **all PASS on operator's CachyOS** at `d8759313e90da0f2af849b7150bc9aede36dcbf2`. This is not a claim of live physical guard qualification.


## Mandatory gaps before P0 acceptance and any 600-second run

1. Validate targeted kernel reader availability **while One UI Framework is absent**, in an authorized short recovery-qualified trial; previous reads were on intact Android only.
2. Review real SM8850 firmware evidence for thermal sensor provenance, genuine SoC junction zones, calibrated warning/critical thresholds, valid ranges, cadence and hysteresis. Never reuse S24-derived estimates or the test simulator's arbitrary threshold values as physical policy.
3. Implement a separate root-owned **live** monitor outside guest namespace/cgroup; bind exact boot ID and `watchdog.generation` + session token, run pre-stop, publish bounded heartbeat and persistent event timeline. Do not read through `dumpsys`, `system_server` or the `xnuhost` bridge after Framework stop.
4. Integrate a **separately supervised** failure/thermal return with the existing `framework_deadline` and `oneios_return.sh` reboot-only path; no extra `/dev/watchdog*` open, no governor/trip writes. Independently detect guard death, blocked named sysfs reads, stale heartbeat and watcher death.
5. Confirm last-resort reboot, root outcome provenance and post-reboot persisted evidence; `DirtyFrag` root loss must not make a successful boot count as authenticated return proof. Run local fault injections before a separately authorized physical short session.
6. Only then consider explicit admission of a full Framework takeover. Keep current `FULL_TAKEOVER=BLOCKED` and app `OneiosSystem.canSwitchOn=BLOCKED`.

**Current milestone:** P0.1 physical sensor **access** observed, firmware/threshold and after-Framework semantics unqualified; P0.2 offline **reference implementation** only; independent physical thermal protection **NOT IMPLEMENTED**.

Related OneiOS draft: https://github.com/YMGPwcca/OneiOS/pull/8

## Operator local milestone — 2026-11-21

At exact OneOS revision `5185a642ab7c7d29aa0f2d758fd04ac7b2f3af15`, the operator ran syntax checks, 14 original reader/policy tests, 19 reader-to-policy E2E tests and 17 shadow/safety-gate tests successfully: **50/50 local PASS**. Full log showed no test exceptions. This establishes **offline test acceptance only**, not functioning in-phone recovery, guard death handling, firmware-qualified thresholds or sensor access after framework shutdown. These tests were run without a new physical iOS takeover.

## Operator milestone — full 67/67 PASS (2026-11-21)

The operator reran the exact OneOS revision `d8759313e90da0f2af849b7150bc9aede36dcbf2` in a fresh extracted archive on CachyOS: `bash tests/run_sm8850_thermal_local.sh` executed 67 cases (14 reader/policy + 19 E2E + 17 shadow/source gate + 17 heartbeat) with `Ran 67 tests ... OK`, and emitted `ONEOS_P0_OFFLINE_67=PASS` and `P0_SAFETY_STATUS=OFFLINE_SIMULATION_ONLY_NO_PHYSICAL_GUARD`. This is the **local offline acceptance checkpoint** for that exact commit only. There was **no** new physical Android Framework stop, iOS guest run, watchdog operation or live thermal guard installed by this command.


## P0.1 passive physical next step: three One UI-only shadow samples

The operator's CachyOS host verified **67/67** offline tests at `d8759313e90da0f2af849b7150bc9aede36dcbf2`. These do not establish whether the actual phone can continuously read three kernel nodes.

A new **explicit opt-in** host collector exists at `scripts/phone/run-sm8850-thermal-shadow-oneui.sh`:
- Default `--audit-only`: **zero ADB contact**. Explicit `--run-readonly` requires exactly one authorized ADB device, correct SM-S948B/m3q/S948BXXS4BZIG model/firmware, boot completion, `system_server`, and SELinux Enforcing.
- Copies **only** the two audited thermal reader/shadow scripts into a fresh, private temporary `/data/local/tmp/oneos-p0-shadow-<random>` directory. Checks SHA-256 of each remote file, runs **exactly three** root read-only sensor samples through `adb shell -T` with a host-side 30s deadline, confirms each tick and boot identity, and rechecks intact One UI before deleting both staged files.
- Saves raw output in `~/projects/OneiOS/out/sm8850/thermal-shadow-oneui` with restrictive permissions; raw log contains boot ID and sensor values, so review before sharing.
- Does **not** touch the root-owned experiment stage, iOS launch, Framework control, watchdog, governors, thermal sysfs writes or reboot. The only on-phone changes are temporary diagnostic script files.
- `P0_SHADOW_ONEUI=PASS_READ_ONLY_EVIDENCE_NOT_GUARD` denotes **three accepted read-only snapshots**, never thermal guard acceptance.

Five added fake-ADB host regression tests in `tests/test_sm8850_thermal_phone_host.py` verify no-device audit, wrong-model refusal, staged hash/cleanup, root denial and truncated output. The strict local runner now requires **72 tests** and syntax-checks/audits the host collector. These five new cases require operator CachyOS verification.

**Run order:** fetch a pinned revision into a scratch directory, run `tests/run_sm8850_thermal_local.sh`, run host collector `--audit-only`, then explicitly `--run-readonly` while stock One UI is fully booted. A successful three-sample reading does not prove post-Framework sensor availability, real SoC junction coverage, trusted thresholds, or reboot safety. Full 600s takeover remains BLOCKED.


## Verified 72-test local CI and physical three-sample thermal shadow (2026-11-21)

- **Exact OneOS revision:** `79e04bafd0f897551eacdee301f56fe18809be4f` checked on the operator's CachyOS.
- **Offline:** all `72/72` local tests PASS (67 previous + 5 fake-ADB collector cases); strict runner printed `ONEOS_P0_OFFLINE_72=PASS` and `P0_SAFETY_STATUS=OFFLINE_SIMULATION_ONLY_NO_PHYSICAL_GUARD`.
- **Physical:** the explicit `--run-readonly` One UI-only observer completed 3/3 read-only, root-sourced samples, all with same boot ID `a6007f1e-4fc3-4e99-82dd-267ccb249656` and `physical_action=NO`.
- **Temperatures (all three ticks, deci-C):** `battery=266` (26.6 C), `lrp=285` (28.5 C), `board_ap=270` (27.0 C). These are reported values, not firmware thresholds.
- **Post-check:** `P0_SHADOW_ONEUI=PASS_READ_ONLY_EVIDENCE_NOT_GUARD`; One UI and original boot ID still present. Host evidence was saved at `out/sm8850/thermal-shadow-oneui/readonly-20261120T180943Z-m4etYr.log`.
- Identical three samples over the observer's short interval demonstrate repeatable reads, **not** sensor refresh dynamics under heating, physical equivalence to HAL channels, independent reachability after Framework stop, or calibrated limits.
- The operator's log shows two audited scripts were staged and the host-script reported successful post-check; cleanup is designed into the host script, but the log alone does **not** prove the temporary directory was removed. No watchdog/governor/reboot path was intentionally invoked.
- **Next sensor mapping:** the existing OneiOS thermal backend documents 28 genuine zones including real CPU zone `cpu-0-5-1` around 40.5 C on a 2026-11-16 S26 Ultra pass, while `cpu-hw-trip-0/1` were constant 105 C pseudo-zones and must never be treated as live sensors. The three battery/LRP/board paths do **not** cover the SoC junction. Before expanding the OneOS reader, positively map the exact firmware thermal-zone path for a genuine CPU sensor and verify stable units/sampling with read-only, bounded access; do not attempt root recursive sysfs scans.
- **Safety gate:** the `--framework-session run` source refusal remains on the draft branch only; the phone's prior staged switch is unchanged. Independent thermal protection and unassisted reboot-return are still NOT QUALIFIED. Full 600-second takeover remains BLOCKED.


## Next: identify a previously verified genuine CPU thermal zone (read-only)

The OneiOS thermal backend already lists real CPU/GPU/DDR zones. Its 2026-11-16 SM8850 report observed `cpu-0-5-1` around 40.5 C as the hottest CPU zone in that sample, after excluding bogus constant 105 C `cpu-hw-trip-0/1` pseudo-zones. The newly added **explicit opt-in** host mapper at `scripts/phone/sm8850-soc-candidate-map.py` searches **only immediate** `/sys/class/thermal/thermal_zone*/type` attributes, unprivileged, bounded at 256 zones, for **exactly** `cpu-0-5-1`. It then reads **only the one matched `thermal_zoneNN/temp`** three times, with root fallback only if direct named reads are denied. It rechecks exact model, firmware, running One UI/`system_server`, SELinux and boot identity; outputs JSON marked `acceptance=NOT_QUALIFIED`.

This does **not** claim `cpu-0-5-1` is the universal maximum SoC junction sensor or that it is available with Framework stopped. Neither its temperature nor the values in simulated tests provide a validated warning/critical policy. It will **never** read the `cpu-hw-trip-*` temperature pseudo-zones. Root is never used to enumerate sysfs and there is no recursive traversal.

`tests/test_sm8850_thermal_soc_map.py` adds nine offline mock-based regression cases (audit does not contact ADB, exact mapping, rejected spoof/duplicate, named root fallback, denied/malformed node, 3-sample verification, boot change refusal). The strict local runner now expects **81** tests in total: the previous **72/72 operator PASS** plus 9 **pending CachyOS verification**. Do not claim a new P0 guard acceptance merely from this evidence.

Once the latest revision passes local CI, the operator can explicitly execute:

```bash
python3 scripts/phone/sm8850-soc-candidate-map.py  # audit only, no ADB
python3 scripts/phone/sm8850-soc-candidate-map.py --run-readonly \
  --adb "$HOME/Android/Sdk/platform-tools/adb" \
  --output "$HOME/projects/OneiOS/out/sm8850/soc-candidate"
```

Run from an isolated extracted/checked revision and keep One UI fully present. If `cpu-0-5-1` cannot be uniquely identified as a thermal-zone type, stop; do not broaden the root scan or invent a substitute without a new source review. No Framework takeover is permitted.

## 2026-11-21 verified CPU candidate mapping checkpoint

- Operator's CachyOS: exact OneOS revision `289b306a0315d448a3d6be7cb4da96882a47bf32`, **81/81 offline tests PASS** (previous 72 plus 9 exact SoC type mapping tests); shell syntax and audit modes passed.
- Physical One UI read-only candidate: `CPU_TYPE=cpu-0-5-1` matched **`/sys/class/thermal/thermal_zone16/temp`** on the current boot, three **unprivileged** reads of **30.0 C / 30.0 C / 29.6 C**, output `SOC_MAP=COLLECTED_NOT_QUALIFIED`.
- Local operator JSON: `out/sm8850/soc-candidate/cpu-candidate-20261120T181955Z.json` (its raw JSON was not uploaded here). This is source-supported output only, not a review of JSON internals.
- Thermal-zone number 16 is **not stable across boots**; future thermal reads must validate exact `type=cpu-0-5-1`, unchanged boot identity and plausible millidegree values rather than trusting the index alone.
- The candidate is a **genuine changing CPU temperature read** in this short sample, not certified as the hottest SoC junction or the only needed CPU/GPU thermal input. No safety thresholds or post-Framework availability are accepted. Full 600s takeover remains blocked.

## Boot-pinned four-sensor reader prototype — P0.2 groundwork

Based on the operator's **81/81 CachyOS PASS** at `289b306a0315d448a3d6be7cb4da96882a47bf32` and real `cpu-0-5-1` readings **30.0/30.0/29.6 C** from `/sys/class/thermal/thermal_zone16/temp`, the branch adds `switcher/assets/oneios_sm8850_thermal_pinned_reader.sh`.

This is a **one-shot, read-only, not-enabled prototype** which combines battery, LRP, board AP (deci-C) and **one CPU candidate** (`cpu-0-5-1`, millidegrees C). It deliberately **does not hardcode thermal_zone16 as a permanent sensor**. The caller must pin a **current-boot UUID and zone index**. Before and after each four-sensor read the reader verifies `type=cpu-0-5-1`, and rechecks boot UUID. In live opt-in mode it also validates exact model/device/firmware, SELinux Enforcing and fully running One UI before/after the read. Wrong type, missing/sentinel sensor, changed boot, impossible sample duration or fixture symlink escapes yield nonzero failure without a partial success record. A real temperature above 105 C is **not** hidden by the pseudo-zone filter if the type is genuinely `cpu-0-5-1`.

The only two explicit modes are `--fixture-root /tmp/DIR ZONE_INDEX BOOT_UUID` (offline synthetic files) and `--live-oneui-readonly ZONE_INDEX BOOT_UUID` (root, One UI fully running, opt-in; **not authorized after Framework stop**). No root enumeration, no sysfs writes, no watchdog, no guest, no thermal limits, no reboot or switcher integration.

**Tests:** `tests/test_sm8850_thermal_pinned_reader.py` adds **13** offline cases. The exact source/test GitHub blobs match the versions executed in assistant-side Linux with **13/13 PASS**, plus `sh -n` PASS. The strict branch runner now expects **94** cases total. **Operator's CachyOS has not yet run these new 13**, so current confirmed user CI remains **81/81**; do not claim 94/94 before the operator tests it.

The CPU candidate is not a substitute for **hottest genuine CPU/GPU/DDR junction** monitoring. The next safety-design step is a verified per-boot allowlist of all essential junction sensors, firmware-calibrated policy, independent root supervisor, real bounded recovery and independently verified return. Full 600-second takeover remains blocked.


## 2026-11-21 operator confirmation: 94/94 local offline PASS

- At exact OneOS commit `934988c9b493cf37d18dd72a1e4f09e1cd6928de`, CachyOS fetched and unpacked the branch, ran the strict local CI runner and reported **`Ran 94 tests ... OK`**, `ONEOS_P0_OFFLINE_94=PASS`, and `ONEOS_FOUR_SENSOR_CI=PASS`.
- The new 13 `test_sm8850_thermal_pinned_reader.py` cases ALL PASS on the operator's own host, in addition to previous 81. This validates the fixture-mode four-sensor prototype and source syntax on Linux, NOT an actual four-sensor run on the phone.
- No live four-sensor sample was collected in that command. The last physical CPU mapping remains `cpu-0-5-1` -> `thermal_zone16/temp` on a prior verified boot, with 30.0/30.0/29.6 C. A numeric zone index must be freshly rediscovered and checked per boot.
- The physical 3-node BAT/LRP/board sampler and offline policy are evidenced separately. Independent post-Framework sensor access, full SoC hottest-junction coverage, vendor-calibrated thresholds, root monitor/supervisor lifecycle, recovery and unassisted reboot are still **NOT QUALIFIED**; full 600-second takeover remains BLOCKED.
