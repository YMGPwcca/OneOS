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
