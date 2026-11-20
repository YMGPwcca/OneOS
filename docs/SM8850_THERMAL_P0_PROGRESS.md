# SM8850 P0 thermal guard groundwork — evidence and offline contract

**OneOS | SM-S948B / m3q / SM8850 | firmware S948BXXS4BZIG**
**Status: reader prototype and policy simulator only. NOT a running guard. Full takeover remains BLOCKED.**

## Operator-verified physical evidence (2026-11-20)

With fully running One UI and SELinux Enforcing, OneiOS P0.1 collected 6 temperatures from Android \`dumpsys thermalservice\`: AP 28.7 C (HAL type CPU), BAT 26.6 C (BATTERY), PA 28.5 C (POWER_AMPLIFIER), SKIN 28.9 C (SKIN), SUBBAT 0 C (BATTERY), USB 25.7 C (USB_PORT). SUBBAT's 0 is **not certified as a valid cold cell reading**.

A second snapshot from Android HAL included BAT 29.5 C and SKIN 31.8 C. Unprivileged ADB reads of \`battery/temp\` and \`battery/lrp\` failed with \`Permission denied\`; a repeat *opt-in, exact-path* root read succeeded:

| Samsung kernel node | Raw representation | Operator root/shell sample | Status |
| --- | --- | --- | --- |
| \`/sys/class/power_supply/battery/temp\` | tenths C | 285 -> 28.5 C | root named-cat READ |
| \`/sys/class/power_supply/battery/lrp\` | tenths C | 303 -> 30.3 C | root named-cat READ |
| \`/sys/class/sec/sec-ap-thermistor/temperature\` | tenths C | 297 -> 29.7 C | shell named-cat READ |

The measurements were taken at different times; matching names or close values do **not** establish that HAL BAT = kernel battery or HAL SKIN = Samsung LRP, nor that any sensor can be read after \`system_server\` stops. OneiOS has a reusable Samsung thermal reader in \`runtime/bridges/thermal/thermal.c\`, but its \`xnuhost\` bridge is inactive during \`bench/bridges=0\`.

## What this branch adds

- \`switcher/assets/oneios_sm8850_thermal_reader.sh\`: one-shot, strict firmware-scoped, **read-only** Samsung sensor reader. It reads the three **exact named** paths, \`/proc/uptime\`, and boot ID, with pre/post boot consistency. \`--fixture-root DIR\` runs entirely from fake sysfs in host tests. \`--live-readonly\` requires root, a fully booted stock One UI and Enforcing SELinux; it is not automatically invoked, deployed, or started by the switcher.
- \`tests/sm8850_thermal_policy_sim.py\`: **Python-only simulation**, NOT production Android code, for critical return requests, sustained warning, hysteresis and fail-closed semantics on invalid/stale/missing/zero reading, wrong boot/run, missing watcher and reversed timestamps. Threshold numbers in tests are artificial fixtures, **NOT SM8850 hardware limits**.
- \`tests/test_sm8850_thermal_guard_p0.py\`: **14 offline regression tests**, no ADB, no root, no actual reboots.

This branch does **not** change the switcher, returner, watchdog ownership, CPU/GPU clocks or OneiOS app availability. A simulator's \`RETURN_REQUESTED\` is just a state label; no physical return is issued. Sensor 0 is rejected (unknown), not silently interpreted as 0 C or as the previous safe value. The shell reader exits nonzero if any required named sensor is missing, malformed or outside the conservative parser acceptance range.

## Local-first test (CachyOS)

\`\`\`bash
cd ~/projects/OneOS
git fetch origin refs/heads/feat/sm8850-p0-thermal-reader-sim:refs/remotes/origin/feat/sm8850-p0-thermal-reader-sim
git worktree add --detach /tmp/oneos-p0-thermal-sim origin/feat/sm8850-p0-thermal-reader-sim
python3 /tmp/oneos-p0-thermal-sim/tests/test_sm8850_thermal_guard_p0.py -v
sh -n /tmp/oneos-p0-thermal-sim/switcher/assets/oneios_sm8850_thermal_reader.sh
\`\`\`

The script's default invocation does **nothing** and refuses. The only live mode is an explicitly requested single read when One UI is up: **it is not a protective background monitor**. No new physical test is required to accept the offline work.

## Mandatory gaps before P0 acceptance and any 600-second run

1. Validate targeted kernel reader availability **while One UI Framework is absent**, in an authorized short recovery-qualified trial; previous reads were on intact Android only.
2. Review real SM8850 firmware evidence for thermal sensor provenance, genuine SoC junction zones, calibrated warning/critical thresholds, valid ranges, cadence and hysteresis. Never reuse S24-derived estimates or the test simulator's arbitrary threshold values as physical policy.
3. Implement a separate root-owned **live** monitor outside guest namespace/cgroup; bind exact boot ID and \`watchdog.generation\` + session token, run pre-stop, publish bounded heartbeat and persistent event timeline. Do not read through \`dumpsys\`, \`system_server\` or the \`xnuhost\` bridge after Framework stop.
4. Integrate a **separately supervised** failure/thermal return with the existing \`framework_deadline\` and \`oneios_return.sh\` reboot-only path; no extra \`/dev/watchdog*\` open, no governor/trip writes. Independently detect guard death, blocked named sysfs reads, stale heartbeat and watcher death.
5. Confirm last-resort reboot, root outcome provenance and post-reboot persisted evidence; \`DirtyFrag\` root loss must not make a successful boot count as authenticated return proof. Run local fault injections before a separately authorized physical short session.
6. Only then consider explicit admission of a full Framework takeover. Keep current \`FULL_TAKEOVER=BLOCKED\` and app \`OneiosSystem.canSwitchOn=BLOCKED\`.

**Current milestone:** P0.1 physical sensor **access** observed, firmware/threshold and after-Framework semantics unqualified; P0.2 offline **reference implementation** only; independent physical thermal protection **NOT IMPLEMENTED**.

Related OneiOS draft: https://github.com/YMGPwcca/OneiOS/pull/8
