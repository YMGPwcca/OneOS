# SM8850 adaptive thermal redesign — source-only candidate

The operator's requirements are in [AGENTS.md](../AGENTS.md). This document
supersedes the former full-run hybrid/fixed-40% admission. All new full
Framework runs (including old no-guard opt-ins) are blocked at the root
switcher; no Data claim, Framework stop, or thermal-driven return is initiated
by that admission. Existing active-session recovery and archived evidence
remain intact; a separate benchmark deadline is not a thermal policy.

The pure model in `tools/sm8850_adaptive_thermal.py` implements:
- soft reduction from 70 C, stronger reduction from 75 C;
- hard minimum CPU-time and qualified frequency request at 80 C until <=70 C;
- gradual cool recovery, including frequency request increases above 40%;
- severe-temperature guest-quiesce request (not reboot/return), cooling
  hysteresis, fault latch and auxiliary-sensor budgets.

This is an executable **offline specification**, not a device actuator.
Starting budgets and the frequency floor are inputs, not an unconditional
40% ceiling. The exact increments, dwell and pause/resume thresholds are
provisional engineering choices, not calibrated hardware guarantees. Percent
is a requested ceiling relative to hardware max, not measured GHz or power.

The next integration must demonstrate independent ownership of reversible
frequency constraints (or explicitly negotiate a different actuator with the
operator), and bounded guest quiescence including GPU work, startup, faults,
resume, and deadline cleanup. It must not write/raise shared cpufreq votes
or disable Samsung/Qualcomm protections. A previous CFS-only startup reached
95.7 C; simply deleting the ceiling and emergency return from the former
live controller is not safe. The replacement is deliberately not launchable
until those constraints are satisfied. Do not remove the admission block
merely to run a benchmark. No Android kernel or module work is authorized.

Offline test: `python3 tools/test_sm8850_adaptive_thermal.py -v` from OneOS.
No new physical test, watchdog investigation, APFS rearm, or rebuild is
required for this source change.

## Local offline receipt (2026-11-26)

Operator WSL log at OneOS `42478a784a0e26df88951066a1f36d3ab0ae1502`, OneiOS
`174fc79f31cd461f223877faee98ba82bda3a23c`: `python3 app/tools/test_sm8850_adaptive_thermal.py -v`
**9/9 passed**; OneiOS's four Python suites 74/74 passed (35 takeover,
16 full takeover, 21 guarded duration, 2 interaction); total 83/83.
No device access. Prior XNUHost native CI passed separately at 143361d
(19,742 checks, zero failed). This validates the offline model and
retired-admission regressions, not hardware thermal behavior.

## Next implementation boundary (source inspection, not device qualification)

Reuse rather than duplicate existing lifecycle pieces:
- `oneios_sm8850_thermal_cap.sh` already creates and verifies a
  session-token-owned v1 CPU bandwidth cgroup. The adaptive quota can
  be scoped to that group; the old fixed shared cpufreq vote must not be
  carried into a replacement.
- `oneios_switch.sh --inner` places xnuhost and its descendants in
  `/sys/fs/cgroup/oneios_session` (when available); the display helper
  joins it separately. The root watcher/key readers/return stay outside.
  A future bounded quiesce actuator can use a session-owned v2 freezer
  if supported and verified. Pin identity and membership, check frozen
  acknowledgement, prevent late joins/launch races, preserve root
  monitor/deadline control, account for in-flight GPU/IO work and
  resume/cleanup races. A freezer request alone is not proof of drained GPU
  work. Do not freeze system services or the root monitor.
- OneiOS `runtime/xnuhost/src/task.c` already sets per-task scheduler
  utilization clamps; `cpu.c` has GPU-driven vCPU minimum boosts.
  A thermal throughput controller must coordinate its own budgets with
  those boosts, not overwrite unrelated tasks or imply that utilization
  clamps are an exact hardware frequency cap. Existing affinity and
  stock thermal protections are unchanged.
- No independently owned and verified reversible frequency-maximum
  interface has been demonstrated by these source files. Do not use a
  read/modify/write of shared `scaling_max_freq` as a substitute: even a
  readback cannot establish ownership of the vote. No raw PerfLock ID
  guess, kernel module, kernel audit, or flash is a next task.
- Keep the no-live-admission marker until a compliant controller exists.
  Continue userspace implementation and offline tests; a throughput-only
  design must be identified as such rather than silently advertised as
  a strict adaptive frequency ceiling. No more repeating completed tests
  solely for documentation changes.

The cgroup and scheduler paths above are source-supported implementation
candidates, not proof that every required operation is supported on this
specific firmware. No stage, rearm, live run, or recovery test follows
from this receipt.


## G24.1 native owned-group actuator candidate

`switcher/native/sm8850_owned_groups.{c,h}` is a native userspace library,
not a launch command. It binds exactly two token-named, root-owned leaf
cgroups using creator-supplied device/inode identities: v1 CPU bandwidth
under /dev/cpuctl and v2 CPU freezer under /sys/fs/cgroup. The production
backend checks filesystem type, current name vs held directory identity,
leaf-only structure, and that the independent caller stays outside the
groups. It changes only its leaf quota and freeze nodes, with readback;
no shared CPU/GPU clock or vendor thermal writes. Quota range 10–100% of
eight cores, 20ms period, no fixed frequency ceiling. Closing a handle
does not change a group or thaw it. A quota/readback failure latches a
fault without preventing a verified freeze; thaw is explicit, requires
an acknowledged freeze and verified quota, and is forbidden after a
fault. Freeze/thaw have a bounded 2s maximum acknowledgement polling window;
blocking kernel syscalls themselves are not proven bounded by that timer.
A failed thaw attempts to reassert freeze on the same verified group;
that is not a confirmed freeze.

Local test (ordinary temporary files + asynchronous mock kernel events):
```sh
D=$(mktemp -d)
cc -std=c11 -O2 -Wall -Wextra -Werror -c switcher/native/sm8850_owned_groups.c -o "$D/owned.o"
cc -std=c11 -O2 -Wall -Wextra -Werror -pthread tests/test_sm8850_owned_groups.c -o "$D/test-owned"
"$D/test-owned"
```

Pending: local compile/test, session creator and verified membership
lifecycle, sensor/policy and actuator integration, GPU/IO quiescence
proof, and an independent owned adaptive frequency actuator. The
library is not staged, invoked by the current root switcher, or an
admission substitute. A cgroup freeze acknowledges stopped userspace
execution only; it does not drain GPU work, prove temperature control,
or authorize resume. No change to legacy recovery paths; no live run.


## G24.1 local receipt (2026-11-26)

Operator WSL at OneOS `7fa70488c1681679386d80c6cc6359fd6d5b5f6a`, OneiOS
`e4db1508b0534c8af2db92a9c8dcba675011b291`: host production compile PASS,
native owned-group fixture 284 checks PASS, Android ARM64 object compile
PASS, DEVICE_ACCESS=NONE, evidence `/tmp/oneios-g241.SIUBOr`.
This is not physical cgroupfs or GPU qualification.

## G24.2 native thermal policy/controller integration — offline candidate

`switcher/native/sm8850_thermal_controller.{c,h}` ports the existing
45–70 C / hard-80-until-70 policy to native code and connects it to the
actual owned-group API. It requires explicit trusted providers for
session/membership verification, BOOTTIME, independently owned frequency
votes/readback, and GPU submission gating/drain/verification/resume. There
is no stock-firmware frequency provider or live GPU provider in this
commit. No no-op fallback or shared-frequency write is implemented.

The coordinator checks exact session identity, freshness (provisional
2 s maximum sample age), monotonic sequence and conflicting duplicates.
Reductions precede increases; before increasing or resuming it checks
freshness and session ownership. Severe temperatures request GPU gate
closure and drain before CPU freeze, then independently check both. On
resume, keep the GPU gate closed through verified thaw at minimum
budgets. On stale/invalid data, readback drift, or actuator failure, latch
fault, attempt minimum owned limits and bounded quiesce when identity is
still verified. If the identity is no longer valid do not write anything;
if drain or freeze cannot be confirmed, report FAULT_UNCONFIRMED rather
than claiming the guest is quiesced. No thermal-triggered reboot/return.
Faults do not authorize automatic resume. The 1 s ACK argument is a
provisional polling/request contract, not proof that a kernel or provider
call cannot block. An independent runner and bounded provider
implementations are still required. The CFS/freezer API now also verifies
current request and ACK without changing them.

Host test: compile the two native sources, run
`tests/test_sm8850_owned_groups.c` and
`tests/test_sm8850_thermal_controller.c` (the latter links the controller
with mock provider and group functions), cross-compile both production
objects with the pinned Android NDK. No phone access. Controller tests
are pending local execution and do not prove thermal hardware behavior.
The legacy admission remains blocked. Remaining work: actual independent
frequency provider, GPU/IO gate+drain provider, session creator/membership
and independent sensor/runner lifecycle. No new recovery audit or kernel
work follows from this change.

The host controller fixture also supports a batch pure-policy trace mode.
Run `python3 tests/test_sm8850_thermal_policy_parity.py HOST_TEST_BINARY`
to compare native and Python decisions/state over 8,640 deterministic
valid samples, including duplicates, auxiliary limits and hysteresis.
This is an offline parity test; invalid identity/freshness and provider
failures are checked separately by the native controller fixture.


## G24.2 local receipt (2026-11-26)

Operator WSL at OneOS `25ae4473711265d13a5bbde5df1f271ddf7708ae`, OneiOS
`122c88728c2cd0bc07c5bef06422750b13a25a6b`: host production compile PASS,
owned-group fixture 330 checks PASS, native controller 239 checks PASS,
C/Python parity 8,640 samples PASS, both Android ARM64 object compiles
PASS. DEVICE_ACCESS=NONE; evidence `/tmp/oneios-g242.ijjF7A`.
No new device qualification. Next implement the actual XNUHost GPU
ingress/drain path and provider ownership; do not repeat unchanged policy
tests or weaken the retired-admission block.


## G24.3–G24.5 local receipts (2026-11-26)

OneiOS G24.3 `cce950cd256db9cf7e49c3e3680a4301e6983719`:
19,759 native checks, zero failed, Android ARM64 compile/link PASS.
G24.4 `5c4dc620b90e5ddb7dbbd2a3baed992526f08d9f`: 159 accepted-
timestamp ledger checks PASS at 40c3472, then full Android patch/build/link
and the three KGSL drain symbols PASS after the hunk-only fix.
G24.5 `4b12df8e7f2617238087f9a3adbb322a50211b29`: 19,824 native
checks / 0 failed; Android ARM64 compile/link and all three combined
quiesce symbols PASS. Runtime SHA256
`c36826976b9763d5874412fb89a7e3fb99d23095f58b28180f69105699a7e2e4`.
Operator local evidence `/tmp/oneios-g245.SNrfRT`. All runs offline,
DEVICE_ACCESS=NONE. No actual KGSL retirement/thermal or IO qualification.

Next investigate the exact SM-S948B/S948BXXS4BZIG stock frequency-vote
interface before further controller layers are added. Linux
scaling_max_freq readback is the aggregate policy limit, not ownership
of the sysfs user's request (see Linux CPUFreq documentation and
https://lists.openwall.net/linux-kernel/2026/03/26/2397).
A handle-based vendor API is only a candidate: existence of acquire/
release symbols or a MAX_FREQ name does not prove max-vote aggregation,
ownership, expiry/death handling, service survival after Framework stop,
or readback. Do not try numeric IDs from other firmware. The OneiOS
frequency inventory is read-only and deliberately does not execute a
vendor library, change any vote, mount, module, property, or service.
Retain the admission block and existing stock protections. No kernel,
watchdog, recovery or physical takeover experiment is a prerequisite for
this inventory.


## G24.6 exact-firmware inventory receipt (2026-11-26)

Operator read-only inventory: OneiOS 0d705281ffca5e1c52a9c9a03efcc4be030361d5,
OneOS b4ecf46783b0ef7e20f8b42c525eea1bf75c82e2; SM-S948B/S948BXXS4BZIG, stock boot complete,
xnuhost absent. Evidence /tmp/oneios-g246-frequency.nIpqAc.txt.
Reported FREQUENCY_INVENTORY=READ_ONLY_COMPLETE,
FREQUENCY_PROVIDER=NOT_QUALIFIED, DEVICE_WRITES=NONE.

- policy0 CPUs 0–5, SCMI/WALT, min 384000 and cpuinfo/effective max
  3628800 kHz. policy6 CPUs 6–7, SCMI/WALT, min 768000 and
  cpuinfo/effective max 4742400 kHz. Listed policy6 OPPs end at
  4396800 kHz, not 4742400; do not assume the advertised max is an
  available OPP or blindly reuse percent-to-frequency rounding.
- Qualcomm perf2 HAL and vendor perfservice running in normal One UI.
  Both vendor and system_ext client ELFs export perf_lock_acq,
  perf_lock_rel and perf_lock_acq_rel. libqti-perfd exports
  ActiveRequestList::DumpActive, ResetClientRequests, request timer,
  resource queue add/remove and apply functions. These symbols indicate
  infrastructure, NOT a proved max-vote ordering or caller ownership ABI.
- Firmware commonresourceconfigs maps major 0x2/minor 0x1 to CPU max
  frequency. targetresourceconfigs overrides its node to
  /sys/kernel/msm_performance/parameters/cpu_max_freq.
  The original inventory checked /sys/module/... but missed this
  overridden path. Its absence from the node receipt is not evidence
  that the target path does not exist.
- targetconfig contains canoe/alor variants with six big and two prime
  cores; need exact SoC selection and full packed resource values, not
  inferred cluster selectors from generic test comments. The grep-only
  perfboostsconfig output showed max-frequency resource comments but
  omitted actual resource pairs. Samsung cpufreq_max_limit read -1;
  this is a shared limit, not a private handle.
- Next focused read-only receipt: actual overridden nodes; SoC ID;
  complete relevant perfboostsconfig blocks; native perf2 init
  service definition and process cgroup; default binder dump if
  available. The takeover source stops zygotes/system_server and kills
  app UID cgroups; a native HAL outside those groups is a candidate
  for survival, not physical proof. Do not stop any service to test it.

The next receipt must not invoke acquire/release, change a property,
write sysfs, alter protections, or run a live takeover. No numeric
opcode, units, competing-client aggregation, independent readback,
expiry/death cleanup, or takeover lifetime is certified yet.
Legacy admission remains blocked. Do not build a fake provider or
relax a shared vote while these remain unresolved.


### G24.6 targeted PerfLock receipt (2026-11-27 ICT)

Exact operator evidence /tmp/oneios-g246-perflock.sqOJGh.txt at OneiOS
7fa7f9f815a1df416ae9d4f9a83e62310cc66eb7, OneOS 2332c069eb207de9668fdc3795ef8056db66c03a.
SM8850 SoC ID 660 selects canoe. Actual target CPU max/min nodes exist
under /sys/kernel/msm_performance/parameters/, SELinux type
vendor_sysfs_msm_perf. At the sampled instant all eight max values were
2147483647 (INT_MAX) and all eight min values zero. The /sys/module
max path is absent. These are msm_performance node values, not
per-client handles nor evidence that other thermal constraints are absent.

Firmware perfboostsconfig.xml canoe launch/animation blocks establish
packed resource IDs: CPU MAX big 0x40804000, MAX prime 0x40804200,
MIN big 0x40800000, MIN prime 0x40800200. Do not submit the stock launch
or animation bundles: they also request minimum clocks, scheduler and
other resources. The MAX values 0xEFFF/0xFFF in those bundles and vendor
test XML MHz-looking values do not establish finite max conversion,
sentinel handling, or lower-wins arbitration on this build.

Native perf2-hal-1-0 init class hal, uid 0, cgroup
/system/uid_0/pid_2109; vendor.perfservice class main, uid system,
cgroup /system/uid_1000/pid_2680. Both outside the current takeover
/apps/uid_* kill scope in the sampled stock boot. This is not a proof
of service availability, binder access or client lifetime after stop.
Default perf2 diagnostic dump section was empty; no active-handle
readback demonstrated. No acquire, release or sysfs writes were tested.

Next use the exact firmware's client and server ELF for static ABI,
packed resource/units and sentinel parsing, MAX comparator and queue
arbitration, handle/timer/client cleanup and diagnostic-query analysis.
Read into host only; no vendor binaries checked into either repository,
no execution or modification of vendor files, no undocumented query or
resource calls. Generic Qualcomm kernel source and older Android
callers can explain the architecture, not qualify this proprietary
build. If static analysis cannot establish noninterference and ownership,
record the provider as unsupported/unqualified rather than silently
falling back to shared sysfs writes. Any subsequent stock-One-UI,
restrictive-only, finite-duration qualification requires an independent
operator decision, no guest workload, and verified noninterference.
No admission or live-run change.
