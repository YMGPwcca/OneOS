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
- **`tests/test_sm8850_thermal_shadow.py`** adds **17 new offline tests**: 14 observer and fake-sensor cases (tested in assistant Linux container, including real shell-reader invocations), plus 3 source-gate syntax/order/static tests. All 17 require local CachyOS execution on the exact new GitHub commit. The test suite does not operate the real S26.
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

## Mandatory gaps before P0 acceptance and any 600-second run

1. Validate targeted kernel reader availability **while One UI Framework is absent**, in an authorized short recovery-qualified trial; previous reads were on intact Android only.
2. Review real SM8850 firmware evidence for thermal sensor provenance, genuine SoC junction zones, calibrated warning/critical thresholds, valid ranges, cadence and hysteresis. Never reuse S24-derived estimates or the test simulator's arbitrary threshold values as physical policy.
3. Implement a separate root-owned **live** monitor outside guest namespace/cgroup; bind exact boot ID and `watchdog.generation` + session token, run pre-stop, publish bounded heartbeat and persistent event timeline. Do not read through `dumpsys`, `system_server` or the `xnuhost` bridge after Framework stop.
4. Integrate a **separately supervised** failure/thermal return with the existing `framework_deadline` and `oneios_return.sh` reboot-only path; no extra `/dev/watchdog*` open, no governor/trip writes. Independently detect guard death, blocked named sysfs reads, stale heartbeat and watcher death.
5. Confirm last-resort reboot, root outcome provenance and post-reboot persisted evidence; `DirtyFrag` root loss must not make a successful boot count as authenticated return proof. Run local fault injections before a separately authorized physical short session.
6. Only then consider explicit admission of a full Framework takeover. Keep current `FULL_TAKEOVER=BLOCKED` and app `OneiosSystem.canSwitchOn=BLOCKED`.

**Current milestone:** P0.1 physical sensor **access** observed, firmware/threshold and after-Framework semantics unqualified; P0.2 offline **reference implementation** only; independent physical thermal protection **NOT IMPLEMENTED**.

Related OneiOS draft: https://github.com/YMGPwcca/OneiOS/pull/8
