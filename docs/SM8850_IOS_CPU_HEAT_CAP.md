# SM8850 OneiOS CPU heat-cap: selective port from original OneOS

**Status 2026-11-21:** source implemented on `feat/sm8850-p0-thermal-reader-sim`; **offline unit/simulator and physical verification of this new change are pending.** Not enabled on the operator's phone by a Git commit. Never infer P0 safety certification from offline CI alone.

## Correct upstream provenance

The *original* [fahadalijaved/OneOS](https://github.com/fahadalijaved/OneOS) `main` at `813cc976475c65dc271f1adfcd6dae566143535c` contains **tested Android guest support** for Galaxy S26 Ultra (`docs/devices.md`), SM8850-specific `scripts/originos/session-s-ultra-8850.env` with `ONEOS_HEAT_CAP=1`, and the generic `oneos_heat_cap` in `switcher/assets/oneos_switch.sh`. The immediate parent of *our fork* remains `akshaynexus/OneOS` (`oneios` branch), not the ancestral source. We reviewed **both**. This port is **not** a claim that upstream ever ran iOS/XNU safely on S26 Ultra.

Original OneOS caps `scaling_max_freq` to **80/65/50% of cpuinfo_max_freq** when Android guest SKIN reaches **45/47/50 C**, with **2 C hysteresis**, and releases the caps during return. Fold8 has a *separate* GPU clock cap code path (`fold8_coloros.sh`) gated to its own profile, which is **not** assumed to exist or be appropriate on SM-S948B.

## iOS-specific host-root adaptation

The isolated SM8850 Framework probe uses `bridges=0`; it has **no Android guest Thermal HAL or SKIN telemetry**. Reusing the exact upstream SKIN thresholds would leave CPU hotspots unguarded. Our `oneios_sm8850_thermal_cap.sh` instead consumes the already trusted root monitor's same-boot/generation CPU, GPU, DDR, battery, LRP and board AP heartbeat.

The new worker is independent from `xnuhost`, XNU scheduler, the emergency sensor guard, UI renderer and Samsung's software watchdog. `oneios_switch.sh` refuses a short Framework probe before stopping anything unless the worker is root-owned/executable and all host CPU policies can be inspected and written. The worker is started **after Framework stop is confirmed but before any xnuhost execution**. It publishes root-owned PID+birth and monotonic heartbeats; losing it after guest startup triggers the existing deadline/watch/return path. Failure to arm it before guest launch triggers the existing `fw_recover` return, **not** an unthrottled guest.

**Source-only candidate policy, deliberately not yet hardware calibrated:**

| Root sensor observation | CPU cap |
|---|---:|
| All monitored groups cool / first heartbeat | 80% of cpuinfo_max_freq |
| CPU >=42 C, GPU/DDR >=43 C, battery >=33 C, LRP/AP >=35 C | 65% |
| CPU >=48 C, GPU/DDR >=49 C, battery >=36 C, LRP/AP >=39 C | 50% |
| CPU or GPU or DDR >=55 C; battery >=38 C; LRP or AP >=42 C | **Emergency root guard abort; do not continue** |

All six source emergency thresholds are unchanged. This policy uses hotspot and board sensors **not SKIN**, so numeric thresholds are **not directly comparable to upstream**. It never touches Qualcomm thermal trips, vendor governor, `/sys/devices/system/cpu/cpufreq_limit/cpufreq_max_limit` or GPU clock nodes. A cap is only written when it is **lower than the current** `scaling_max_freq`; an existing lower Samsung/power-save cap is respected. The new worker only increases severity, never raises CPU clocks during one experimental session; the mandatory reboot resets the policy to the vendor's boot behavior.

**No full takeover permission:** `--framework-session run` / 600s remains source-BLOCKED; `bridges=0` remains. This cap is for the separately acknowledged, strictly timed experimental short probe only. A 101.1 C CPU zone was recorded during the former CPU90 experiment, even after the monitor requested abort. This is evidence that lowering clocks and retaining a CPU55 cutoff are **not proof** the device will stay cool or return unassisted. Hardware watchdog, complete reboot attribution, and safe thermal dynamics still need independent validation before any further physical session.

## Offline acceptance and artifact boundaries

Run the fork's `tests/run_sm8850_thermal_local.sh` on CachyOS (host-only): it includes `test_sm8850_thermal_cap.py` with 14 shell/policy/synthetic-sysfs tests alongside the prior 179 P0 tests, plus `sh -n` on all recovery and cap scripts. The OneiOS cross-fork static parity check additionally insists on the cap worker, source lock and SHA-pinned staging.

The Android OneOS Probe APK must **not** include `oneios_sm8850_thermal_cap.sh`; `app/build.gradle.kts` excludes it and `PackagesTest` asserts that exclusion. Only `scripts/phone/sm8850-takeover-short-probe.py --prepare-probe` is permitted to stage the new root worker after physical prerequisites and APFS clone provenance have passed; **do not use** the `--run-90s` / `--run-300s` flags just to test the cap, especially after the prior 101.1 C failure. The host runner's no-ADB `--audit-only` path is available to check source without touching a device.

**Acceptance boundary:** passing 193 offline tests demonstrates only source-level decision logic and synthetic sysfs interactions. It does not prove that `scaling_max_freq` writes are accepted by the SM8850 vendor kernel under SELinux, that root workers meet wall-clock thermal deadlines, or that a new CPU cap prevents a 101.1 C hotspot.
