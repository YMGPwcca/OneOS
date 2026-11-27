# SM8850 Framework ON/OFF: native thermal and display findings

Evidence series 2026-11-27–28; consolidated after the operator's final fan-cooled
20-second Framework-only smoke. This is a retrospective measurement record, not
a new experiment request, a live-run procedure, or a production thermal
qualification. The operator's immediate goal was to suppress the stock Samsung
boot animation and compare temperatures with Framework ON versus OFF.

## 1. Disposition

| Question | Finding |
| --- | --- |
| Does the native thermal reader work in One UI? | PASS, observed |
| Does the same native thermal/power stack remain accessible with Framework OFF? | PASS at sampled low load; all five service PID/birth pairs unchanged within each run |
| Did stock Samsung bootanim restart during the old Framework OFF path? | YES, observed process plus samsungani565 layer |
| Is the bootanim suppression fix effective on SM-S948B? | PASS in two post-fix physical observations |
| Are host SurfaceFlinger and Qualcomm Display Composer retained? | YES, same PID/birth; zero additional direct CPU ticks in both post-fix OFF sample windows |
| Does removing bootanim eliminate the CPU junction rise? | NO; +4.3 C in the first retest and +1.2 C with the fan |
| Does removing bootanim reduce all-device CPU load? | Lower sampled OFF utilization in both retests, but not a controlled causal A/B |
| Is native mitigation under sustained iOS load proven? | NOT QUALIFIED |
| Was normal One UI observed after the 20-second deadline request? | YES in both post-fix logs |
| Independent watchdog / unassisted return / physical-key recovery? | NOT VERIFIED |
| iOS boot, guest FPS or 60 FPS acceptance? | NOT TESTED in these smokes |

The boot-animation task is closed on the supplied physical evidence. No further
standalone smoke is required for that finding. Do not turn this receipt into
another peripheral or recovery milestone, or authorize a new live run from it.

## 2. Scope, device, method and provenance

- SM-S948B / m3q / SM8850, S948BXXS4BZIG, Android 17 / One UI 9.
  Root via KernelSU/DirtyFrag, uid/gid 0, context u:r:ksu:s0; SELinux
  Enforcing. Legacy a:82 watchdog, explicitly unqualified reboot-only path.
- OneiOS `scripts/phone/sm8850-native-thermal-observe.py --display-probe`
  uses the existing admitted Framework-only smoke. It reads stock ON first,
  then performs preflight, updates compatibility/recovery scripts with backup,
  stops Framework, and samples OFF within the existing 20-second deadline.
  No XNUHost/iOS guest startup, APFS Data rearm, new recovery path, deadline
  extension, or observer thermal-control writes. The bootanim change itself
  uses init service control, not a frequency/thermal write.
- Raw sensor probe reports 28 accepted zones (16 CPU, 11 GPU, 1 DDR),
  CPU/GPU/DDR maxima in millidegrees C and battery/LRP/board AP in
  deci-degrees C. XO unavailable; missing values are not zero. HAL AIDL
  version 3 reports AP, BAT, PA, SKIN, SUBBAT, USB in degrees C. AP as
  type CPU is a Samsung reported sensor, not the maximum raw CPU junction.
  SUBBAT=0 is invalid. HAL maximum qualified severity is 0 in these idle
  observations; it does not establish behavior under thermal stress.
- Each phase includes two /proc/stat and PID/birth-paired process snapshots
  about three seconds apart. Aggregate CPU busy is derived from deltas of
  the first eight CPU counters, excluding idle and iowait. A process's
  aggregate percentage is its utime+stime delta divided by all CPU tick
  deltas, not percentage of a single core or electrical power.
  bootanim and bootanimation may be aliases for one PID; never sum twice.
- After the window, a bounded `dumpsys SurfaceFlinger --list` records
  layers if enough deadline remains. Raw KGSL and backlight values are
  sampled, not continuously recorded. No screenshots, forced heating,
  brightness/refresh changes or guest frame measurements.
- Operator requested a fan throughout cooldown and both phases of the final
  run. Fan speed, distance, ambient temperature and steady-state equilibrium
  were not logged. First post-fix run is the earlier retest, not a calibrated
  no-fan control. Distinct boot IDs and initial temperatures must remain
  separate. Filenames use 20261127; earlier repository receipts use 2026-11-28.

### Evidence identifiers

| ID | Source | Local evidence |
| --- | --- | --- |
| S | Initial stock One UI diagnostic | /tmp/oneios-stock-thermal.GU1Pan |
| A | Initial native OFF reader observation | /tmp/oneios-native-observer.LRoHZE; /tmp/oneios-native-off.68qg01ry |
| B | Pre-fix display attribution | /tmp/oneios-display-observer.e488Ws; /tmp/oneios-native-off.xh16d3di |
| C | First post-fix 20s retest, Pasted text(20261127-202554).txt | /tmp/oneios-native-off.l9qnhzl9; /tmp/oneios-bootanim-retest.XyDbSi.log |
| D | Fan-cooled 20s retest, Pasted text(20261127-203200).txt | /tmp/oneios-native-off.t6rqu73s; /tmp/oneios-cooled-framework.f9NCW9.log |

Historical S/A/B evidence is already recorded in the pinned
[OneiOS performance tracker](https://github.com/YMGPwcca/OneiOS/blob/46ea0957e4712b5b456b10e9c812e4e8e1b3264a/docs/SM8850_60FPS_XNUHOST_PERFORMANCE_TRACKER.md)
under native reader stock/OFF and Samsung animation reactivation receipts.
C/D values below come from the two operator-pasted logs, with complete
ON/OFF sections and successful layer-list commands.

| ID | Same-boot identifier for ON and OFF | OFF launch | Deadline, BOOTTIME s |
| --- | --- | --- | ---: |
| A | 99e016d0-42e9-451f-bfc1-973ac7fb32d7 | a6e025952b1d4256bed0fdf362235224 | 29478 |
| B | 4b8ed790-7970-459d-a490-457aa5a6d78e | fd5edf65ed1443029941193ed0a3e848 | See historical evidence |
| C | 0830222c-c273-4a76-8438-5ddf1a07398b | 0ff5490c883446eba122a8e81c82ef87 | 3281 |
| D | f2497b9e-f3da-4051-bdba-522b9d984017 | 12b64778bee94c90a8529f3f63fe2652 | 381 |

C generation: `0830222c-c273-4a76-8438-5ddf1a07398b.16927.321574`.
D generation: `f2497b9e-f3da-4051-bdba-522b9d984017.4205.32057`.
C/D both report `NATIVE_ROOT_COPY_VERIFIED`, 2,526,648-byte diagnostic
push, `ONEOS_STAGE_UPGRADE=PASS_BACKUP_PRESERVED`,
`SM8850_FRAMEWORK_SMOKE_SECONDS=20`, `PREFLIGHT OK`,
`TAKEOVER_CONFIRMED=YES`, `NATIVE_ON/OFF=READERS_OK`, raw and HAL RC=0,
and `DISPLAY_ON/OFF=SAMPLED`. Compatibility backups:
`.rollback/oneos-compat.cS6OoL0D` (C) and
`.rollback/oneos-compat.PvGMnaYK` (D), under the stage.
The commands checked OneOS 497d4cc42b958b587418d591ed7f9764ecfaeb28,
which contains the bootanim fix. The exact parent HEAD and new diagnostic
SHA256 are not independently printed in C/D logs; do not invent them.
The observer source is unchanged between 6044782 and the latest
pre-receipt parent 46ea095. Earlier binary was 2,521,920 bytes with
SHA256 52dcece4826a716bbdc8a2d5149d63f17c13379dfaf8792f56d86cd6438d40a8;
do not assign that hash to the newly rebuilt larger binary.

## 3. Why boot animation returned; upstream and implemented fix

Original [fahadalijaved/OneOS 5d0cddf](https://github.com/fahadalijaved/OneOS/blob/5d0cddf6c063527522b201e4359172071d9d4178/switcher/assets/oneos_switch.sh#L1536-L1569)
explicitly kills the stock bootanimation at handoff and polls init.svc.bootanim
to stop it if restarted, with a roughly one-second cadence in the inspected
revision. The intermediate akshaynexus/OneOS fork (38622248e85a68434f764f71581835121fe6006b)
also has suppression. Source inspection establishes a mechanism, not a physical
upstream test or proof no other Samsung device ever exhibits the issue.

Prior OneOS d1ff949 `switcher/assets/oneios_switch.sh`:
`bootui_begin()` returned early for FRAMEWORK=1; --stop-loop stopped bootanim
only for FRAMEWORK=0. The hosted iOS path intentionally retains the host
SurfaceFlinger and Qualcomm composer; the Framework-only smoke ends before
starting guest/display helpers. B confirmed the predicted reactivation:
bootanim PID 4013 / birth 141053, service.bootanim.exit=0 and only the
`samsungani565#193 z=3000000` layer after Framework stop.

[OneOS 95f0efa](https://github.com/YMGPwcca/OneOS/commit/95f0efa0a2306d9c24ba0b9a0ac40ed5aa62548b)
adds immediate and every-five-200ms-ticks polling of bootanim for FRAMEWORK=1;
running or restarting triggers `setprop ctl.stop bootanim` only while neither
return.request nor stop-loop.off is visible, with a repeated check just before
the write. Zygote cadence and FRAMEWORK=0 behavior unchanged. Existing return
Gate B retires stop-loop before restarting bootanim. No blanket PID SIGKILL,
SurfaceFlinger freeze/restart or display composer restart was ported.
The upstream gap splash freezes the compositor; that is incompatible with
using the host compositor as the iOS display provider. The old custom splash
redraws at 150 ms intervals and is not enabled as a substitute. A blank or
retained frame during preparation is possible; there is no new splash claim.

Operator's pinned local test of OneiOS 57ba9b411802a4d7359c318b0633d6fa68330a1e /
OneOS 95f0efa: shell syntax PASS, 5/5 bootanim tests, 5/5 profile tests,
34/34 guarded-full tests (44 total). C and D then give physical confirmation
of suppression, not merely fixture success.

## 4. Thermal observations

All values in degrees C, as logged, not a thermal-equilibrium experiment.
An em dash indicates not included in the corresponding historical receipt.

| Sensor | S stock only | A ON -> OFF | B ON -> OFF | C ON -> OFF (delta) | D ON -> OFF (delta) |
| --- | ---: | --- | --- | --- | --- |
| CPU junction max | 31.9 | 32.7 -> 37.0 | 40.5 -> 41.3 | 34.6 -> 38.9 (+4.3) | 37.7 -> 38.9 (+1.2) |
| GPU junction max | 30.8 | 30.8 -> 33.6 | 39.3 -> 38.6 | 33.2 -> 36.3 (+3.1) | 36.3 -> 34.3 (-2.0) |
| DDR | 30.8 | 30.8 -> 33.6 | 39.3 -> 39.0 | 33.6 -> 36.3 (+2.7) | 36.3 -> 34.7 (-1.6) |
| Battery raw | 26.5 | 26.1 -> 26.4 | 31.3 -> 29.9 | 28.2 -> 28.3 (+0.1) | 29.7 -> 27.8 (-1.9) |
| LRP raw | 28.6 | 28.3 -> 28.7 | — | 30.3 -> 30.5 (+0.2) | 33.0 -> 29.9 (-3.1) |
| Board AP raw | 27.2 | 27.2 -> 29.5 | — | 29.9 -> 32.2 (+2.3) | 32.6 -> 30.4 (-2.2) |
| HAL AP | 27.2 | 27.0 -> 28.3 | — | 29.9 -> 31.1 (+1.2) | 32.9 -> 30.5 (-2.4) |
| HAL BAT | 26.5 | — | — | 28.2 -> 28.2 (0.0) | 29.6 -> 27.8 (-1.8) |
| HAL PA | 27.4 | — | — | 30.3 -> 30.6 (+0.3) | 33.6 -> 29.9 (-3.7) |
| HAL SKIN | 28.5 | 28.3 -> 28.7 | 34.4 -> 32.6 | 30.3 -> 30.5 (+0.2) | 32.0 -> 29.9 (-2.1) |
| HAL USB | 26.1 | — | — | 28.3 -> 28.2 (-0.1) | 28.2 -> 27.7 (-0.5) |
| HAL max severity | 0 | 0 -> 0 | — | 0 -> 0 | 0 -> 0 |

### Acquisition timestamps

All timestamps below are CLOCK_BOOTTIME milliseconds, within each run's
own boot. Raw/HAL reads are sequential, before the display CPU windows.

| ID | Raw ON start..end | HAL ON start..end | Raw OFF start..end | HAL OFF start..end | Raw ON-to-OFF separation |
| --- | --- | --- | --- | --- | ---: |
| S | 24471901..24471910 | 24471952..24471953 | — | — | — |
| A | 29358068..29358071 | 29358192..29358193 | 29460734..29460737 | 29460893..29460894 | 102.666 s |
| B | 1328089..1328094 | — | 1414220..1414223 | — | 86.131 s |
| C | 3161612..3161621 | 3161747..3161748 | 3263178..3263181 | 3263317..3263317 | 101.566 s |
| D | 273529..273534 | 273673..273677 | 363021..363024 | 363146..363146 | 89.492 s |

The 20s deadline applies after Framework takeover, not to the entire command.
Using the integer deadline minus 20s as the approximate start, C/D raw OFF
read began about 2.18/2.02s into the window. This is transition/early-OFF
data, NOT a measurement after 20 seconds of stable OFF idle. Temperature
during preflight/staging and the remainder of the window is not continuously
recorded. Both raw/HAL queries completed within their respective deadlines.

In C, CPU/GPU/DDR rose despite suppressed boot animation. In D, with fan
cooling across the procedure, most sensors fell while CPU maximum rose 1.2 C.
The OFF CPU maximum is 38.9 C in both, not evidence of an identical
steady-state temperature. Different starting temperature, uptime, workload
and ambient/cooling conditions confound direct C/D comparisons. Temperature
inertia, teardown and retained services are plausible contributors; the log
does not isolate their causal shares. The old animation is a confirmed
unnecessary display workload, but not the sole cause of the observed hotspot
rise. No inference about temperature or throughput during sustained iOS load.

## 5. Native thermal/power services and operating limits

The five PID/birth pairs below were each identical ON and OFF within the run.
All states running. The retained services do not prove autonomous mitigation
under stress after system_server disappears.

| Service | A | C | D |
| --- | --- | --- | --- |
| thermal-engine | 9927/93576 | 12315/2927 | 11945/2856 |
| vendor.samsung.hardware.thermal-default | 2411/1119 | 2167/461 | 2086/459 |
| vendor.samsung.power-default | 2385/1117 | 2140/459 | 2058/457 |
| poweropt-service | 2387/1117 | 2141/459 | 2059/457 |
| perf2-hal-1-0 | 2399/1119 | 2151/460 | 2078/459 |

B also retained all five PID/birth identities (see historical receipt).
C/D current CPU clocks and effective limits, in kHz; GPU in Hz:

| Field | C ON | C OFF | D ON | D OFF |
| --- | ---: | ---: | ---: | ---: |
| policy0 scaling_cur_freq | 1324800 | 1900800 | 1440000 | 2745600 |
| policy0 scaling_min_freq | 787200 | 787200 | 787200 | 787200 |
| policy0 scaling_max_freq | 3187200 | 3187200 | 3187200 | 3187200 |
| policy0 cpuinfo_min/max_freq | 384000/3628800 | same | same | same |
| policy6 scaling_cur_freq | 883200 | 883200 | 883200 | 883200 |
| policy6 scaling_min_freq | 883200 | 883200 | 883200 | 883200 |
| policy6 scaling_max_freq | 3398400 | 3398400 | 3398400 | 3398400 |
| policy6 cpuinfo_min/max_freq | 768000/4742400 | same | same | same |
| Samsung cpufreq_max_limit | 3398400 | 3398400 | 3398400 | 3398400 |
| Samsung cpufreq_min_limit | -1 | -1 | -1 | -1 |
| KGSL gpuclk | 222000000 | 222000000 | 222000000 | 222000000 |
| KGSL max_gpuclk | 902000000 | 902000000 | 902000000 | 902000000 |
| KGSL thermal_pwrlevel | 5 | 5 | 5 | 5 |

Current frequency differs on policy0; a sampled current frequency is neither
a workload average nor proof of a thermal boost. The effective ceilings are
unchanged in these low-load snapshots. In the separate stock gaming handoff,
moderate SKIN 42.8 C had effective policy0 1555200 kHz, policy6 1497600 kHz,
and GPU 500 then 422 MHz. That supports native adaptive DVFS in stock One UI,
not a demonstrated stress response with Framework OFF. The historical
104.8 C iOS peak belongs to a different session, not these smokes.

Maintain stock Samsung/Qualcomm authority and independent raw protection;
the controller's guest demand budgets are not MHz. Existing 70/80/70 C policy
and fault distinctions remain unchanged. No requirement to heat a cool
device, no fixed 40% clock cap, no new PerfLock requirement, and no
temperature-only return/reboot in the proposed replacement.

## 6. CPU/display measurements and physical bootanim result

| Metric | B before fix | C after fix | D after fix, fan |
| --- | --- | --- | --- |
| Display window ON duration | 3.300 s | 3.300 s | 3.280 s |
| Display window OFF duration | 3.180 s | 3.200 s | 3.210 s |
| Total CPU busy ON | 3.58% | 3.19% | 3.63% |
| Total CPU busy OFF | 12.57% | 8.17% | 8.73% |
| OFF minus ON | +8.99 pp | +4.98 pp | +5.10 pp |
| Bootanim ON | stopped | stopped | stopped |
| Bootanim OFF | running, PID 4013 | stopped, no PID in both samples | stopped, no PID in both samples |
| service.bootanim.exit ON/OFF | 1/0 | 1/0 | 1/0 |
| OFF layer list | samsungani565#193 | empty, RC=0 | empty, RC=0 |
| SurfaceFlinger OFF | running | running, unchanged PID/birth | running, unchanged PID/birth |
| Composer OFF | running | running, unchanged PID/birth | running, unchanged PID/birth |
| KGSL raw busy percentage | 0 % | 0 % | 0 % |
| KGSL raw gpubusy | 0 0 | 0 0 | 0 0 |
| Actual backlight nodes ON/OFF | 0/0 | 0/0 | 0/0 |
| Requested panel0-backlight ON/OFF | 493/493 | 503/503 | 0/0 |

OFF CPU load is lower than B by 4.40 percentage points (~35.0% relative)
in C and 3.84 pp (~30.5% relative) in D. This is a descriptive comparison
of three short windows across distinct boots, not a measured causal
improvement of all-system workload. The ON/OFF difference within each run
also remains positive. The observed stock animation suppression is the
stronger conclusion. service.bootanim.exit remains 0 in OFF even when
init reports stopped: that property alone is not a liveness criterion.
Both post-fix OFF lists returned zero lines with DISPLAY_LAYERS_RC=0,
not a timed-out list or missing observation.

### Process attribution: OFF only

Each cell is direct CPU tick delta / aggregate all-CPU utilization.
A dash is an absent process/measurement, not an assigned zero.

| Process | B | C | D |
| --- | --- | --- | --- |
| bootanim (bootanimation alias counted once) | 25 / 0.99% | absent | absent |
| surfaceflinger | 6 / 0.24% | 0 / 0.00% | 0 / 0.00% |
| vendor.qti.hardware.display.composer | 5 / 0.20% | 0 / 0.00% | 0 / 0.00% |
| watcher | 6 / 0.24% | 4 / 0.16% | 4 / 0.16% |
| feeder | 0 / 0.00% | 2 / 0.08% | 2 / 0.08% |
| stop-loop | 4 / 0.16% | 4 / 0.16% | 5 / 0.19% |

C SurfaceFlinger PID/birth 9238/1629, composer 2149/460; D 8946/1573,
2075/458, unchanged between ON and OFF and across OFF A/B. ON
system_server 9565/1689 (C) and 9260/1632 (D); OFF no system_server,
per verified Framework stop and snapshot. C OFF CPU window uptime
3263.55..3266.75, D 363.36..366.57. C/D zero additional compositor
process ticks do not prove zero hardware display power or all GPU idle;
the raw KGSL readings are instantaneous and the diagnostic integer
gpu_busy_percentage parser marks its formatted string invalid. Keep
the raw strings instead of fabricating a parsed numeric sample. The
brightness nodes do not independently establish panel luminance or power.

Before the fix the three display processes accounted for ~1.43%
aggregate CPU, not the whole +8.99 pp ON/OFF difference. Their absence
of direct load in the post-fix windows cannot explain every CPU tick
or all temperature changes; child processes, kernel work and other
retained services were not exhaustively attributed.

## 7. Recovery and limits of acceptance

Both C and D end with:
```text
FRAME_STALL_REPORT=SKIPPED_MISSING_GUEST_TRACE missing=control/display.log
REBOOT_SMOKE=DEADLINE_REQUEST_CONFIRMED_ONEUI_OBSERVED
UNASSISTED_RETURN_TO_ONEUI=NOT_VERIFIED
PHYSICAL_KEY_REBOOT=NOT_VERIFIED
NATIVE_OFF_OBSERVATION=READERS_OK
EXISTING_SMOKE_EXIT=4
NATIVE_MITIGATION_AFTER_FRAMEWORK_OFF=NOT_QUALIFIED
DEVICE_THERMAL_CONTROL_WRITES=NONE_BY_OBSERVER
NATIVE_TRANSFER_STEP=REMOVE_ROOT_DIAGNOSTIC
OBSERVER_EXIT=4
```
Deadline request plus later One UI was observed; the logs cannot rule
out a Download Mode detour or manual force restart. This does not mean
the suppression or reader failed, and it must not be relabeled as
independent recovery PASS or observer exit 0. Root temporary cleanup
returned without an unverified warning in C/D; no independent post-reboot
filesystem audit was supplied. The previous A observation had an explicit
cleanup-unverified warning after loss of root. The current handset state
cannot be established indefinitely from a completed log.

## 8. Related source/CI receipts and outstanding scope

- Initial read-only thermalctl/native stock controller batch:
  OneiOS 99f40bb4 / OneOS d1ff949, 120 thermal checks, raw fixture PASS,
  414 controller checks, 8640 parity samples, 35+16 admission tests and
  Android compile PASS. Stock reader succeeded; first two observer
  transfer attempts failed before Framework stop (stdin streaming then
  ADB push completion timeout). File-backed subprocess capture and verified
  root-copy readback resolved the path. A third pre-fix display run had
  an ADB push timeout but independent root hash/ownership receipt passed.
  Details and evidence paths are retained in the OneiOS tracker.
- Bootanim 44/44 local checks as recorded above.
- Consolidated OneiOS fe11aeef321ac64da1dddbb03b4897e784d494b6 /
  OneOS 497d4cc42b958b587418d591ed7f9764ecfaeb28:
  /tmp/oneios-stock-ci.PbVsji.log, exit 0, 335.222s,
  STOCK_SOURCE_BATCH_OFFLINE=PASS, DEVICE_ACCESS=NONE,
  LIVE_TAKEOVER_AUTHORIZED=NO. 7 dynamic / 9 static ELF, zero failures.
  Runtime-only archive `out/release/oneios-runtime-0.0.0-stock.fe11aee-arm64.tar.zst`,
  5,817,926 bytes, SHA256
  `cc85b886c3181a6710dc2cf30e7001888d36c745c96a8c7b7c9d41b914068efa`.
  No kernel built; explicit kernel-source and Mac-only checks skipped.
  Companion tool 14,795,432 bytes, SHA256
  `bf5f255b2bf668819b9b9d5b680793095677d0fc8cdf2fa526210d8f9aee7aa2`.
  Two Rust dead_code warnings do not indicate build failure.
- Production supervisor/root creator/verified cgroup membership and real
  runtime park/resume integration are still incomplete; source and fixture
  success does not mean installed runtime control. Existing full-run gate
  remains retired. Wi-Fi and encoder already disabled in the benchmark
  configuration; camera can still map, audio capture is not qualified.
  No silent peripheral configuration change or claim of complete port.
- No new build, device action, source modification, safety policy change
  or GitHub Actions is implied by this documentation update. Do not rerun
  CI just for the evidence receipt. Preserve the user's local raw logs;
  this report retains measured findings, identifiers and evidence paths,
  not the complete raw logs with unrelated installed-app layer names.

## Appendix: exact zone temperatures for the two post-fix retests

Raw millidegrees C; these are four individual snapshots, not a time series.
Each named zone in the operator logs occurs once per snapshot.

| Zone | C ON | C OFF | D ON | D OFF |
| --- | ---: | ---: | ---: | ---: |
| cpu-0-0-0 | 33800 | 38100 | 37700 | 37400 |
| cpu-0-0-1 | 34200 | 37700 | 37700 | 38900 |
| cpu-0-1-0 | 33800 | 38500 | 37000 | 36600 |
| cpu-0-1-1 | 34600 | 38900 | 37700 | 38500 |
| cpu-0-2-0 | 34200 | 37700 | 37400 | 35800 |
| cpu-0-2-1 | 33800 | 37400 | 37000 | 35400 |
| cpu-0-3-0 | 33500 | 37000 | 36600 | 35000 |
| cpu-0-3-1 | 33800 | 38100 | 37000 | 35800 |
| cpu-0-4-0 | 34600 | 38500 | 37400 | 37400 |
| cpu-0-4-1 | 34200 | 38500 | 37000 | 38500 |
| cpu-0-5-0 | 33800 | 38500 | 37400 | 36600 |
| cpu-0-5-1 | 34200 | 38900 | 37000 | 37700 |
| cpu-1-0-0 | 32800 | 35900 | 35500 | 33900 |
| cpu-1-0-1 | 33600 | 36300 | 36300 | 34300 |
| cpu-1-1-0 | 33600 | 36600 | 36300 | 34300 |
| cpu-1-1-1 | 33200 | 37000 | 36300 | 34700 |
| gpuss-0 | 32800 | 35100 | 35900 | 33600 |
| gpuss-1 | 33200 | 35500 | 35900 | 33900 |
| gpuss-2 | 33200 | 35500 | 36300 | 34300 |
| gpuss-3 | 33200 | 35100 | 35900 | 33600 |
| gpuss-4 | 32800 | 34700 | 35900 | 33200 |
| gpuss-5 | 33200 | 35500 | 35900 | 33900 |
| gpuss-6 | 33200 | 36300 | 35900 | 33900 |
| gpuss-7 | 33200 | 36300 | 36300 | 34300 |
| gpuss-8 | 33200 | 35500 | 35900 | 33900 |
| gpuss-9 | 33200 | 35900 | 36300 | 34300 |
| gpuss-10 | 32800 | 35100 | 35500 | 33200 |
| ddr | 33600 | 36300 | 36300 | 34700 |
