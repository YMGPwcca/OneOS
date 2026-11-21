# SM8850 throttle-first P0 experiment (NOT phone-qualified)

Target: keep S26 Ultra CPU junction temperature **below 80°C when possible** by
starting to reduce effective CPU ceilings well before 80°C. The requested
behavior is **throttle, not return**, at 80°C. No software-only scheme can
promise a hard upper bound under rapid load, sensor latency or firmware faults.

This **draft branch** is based on `feat/sm8850-p0-thermal-reader-sim`.
It is NOT the S26 600-second `feat/sm8850-600s-gpu3d-required` stage, and
must not be installed or used to authorize a full takeover. The existing
short-probe independent root guard and deadline-return remain; no active
phone validation has been performed. All simulated safety thresholds require
device-specific qualification and review before using them in a live session.

## Monotonic CPU frequency policy

When at or above the threshold, the independent root CPU-cap worker sets
`scaling_max_freq` no higher than the following *percentage of hardware
maximum*, clipped to the policy's verified `cpuinfo_min_freq`.
An existing lower cap is never raised. Each session only goes to stricter
tiers; reboot resets the changes. Other hot sensors can escalate earlier.

| CPU junction | Tier | Maximum percentage |
| --- | ---: | ---: |
| under 55°C | 1 | 60% |
| 55–64.99°C | 2 | 40% |
| 65–71.99°C | 3 | 28% |
| 72–76.99°C | 4 | 18% |
| 77–79.99°C | 5 | 12% |
| 80–89.99°C | 6 | 8% (bounded by hardware min) |
| 90°C and above | emergency | independent return; **not** standard 80°C policy |

The monitor remains outside guest cgroups and tracks exact boot, process birth,
generation, and heartbeat. The 90°C emergency cannot be removed merely because
the preferred thermal action is throttling. This threshold is **not hardware
certified** and requires a guard reaction-time/sampling audit; a rapid spike
can exceed 80°C before the guard responds. Kernel/firmware thermal trips must
never be disabled. Other emergency groups (GPU, DDR, board, cell, LRP) are
deliberately separate from the 80°C CPU control target.

## Local-first verification (CachyOS)

```bash
cd ~/projects/OneiOS/app
git fetch origin feat/sm8850-throttle80-first
git worktree add /tmp/oneos-throttle80-local FETCH_HEAD
(
  cd /tmp/oneos-throttle80-local
  sh -n switcher/assets/oneios_sm8850_thermal_cap.sh
  sh -n switcher/assets/oneios_sm8850_thermal_takeover_guard.sh
  sh -n switcher/assets/oneios_switch.sh
  python3 -m unittest discover -s tests -p 'test_sm8850_thermal_cap.py' -v
)
```

No ADB command, live `--run`, clock mutation, or framework stop is part of
the above. Full fixture tests, missing-sensor tests, initial min-frequency
readback, root-owned staging validation and no-device session fault injection
must pass before any controlled phone experiment.

## Why the previous 600-second session lagged

The recorded 600-second S26 logs show:

* `display: shm, guest frame 1080x2340 at 60 Hz`, kernel boot args
  `sheng-vsync=60`. The guest is **not configured at 120 Hz** even though
  the physical panel supports 120 Hz.
* 12,876,415 task traps across ~601 s (~21,426/s), including 7,250,648
  fault traps; high 30-second windows approached ~70,000 traps/s.
* Some cold-boot 10-second guest-CPU windows reached 800%, with SpringBoard,
  backboardd and iconservicesagent busy. Thus delays are a combination of
  guest workload, VMM fault/handoff overhead and scheduling contention.
* GPU fences retired with zero guest-report timeouts; this does not prove
  the frame pipeline is 60 FPS. In 5-second windows the peak observed
  posted rate was only 36.52/s, and long idle periods had no new posts.
* `ONEIOS_CPU_PLACEMENT_BRIDGE=INACTIVE`, `bridges=0`, and
  `setway-skip=1` were logged. The parent repo's old trapped cache
  set/way fix is already enabled. The `uclamp.min 1024` GPU request is
  not proof of an effective Linux scheduler clamp.

More aggressive throttling **will reduce throughput and may make UI lag
worse**, especially during initial indexing. Treat cooler operation as P0;
only afterward optimize background jobs, trap/fault throughput and display
pacing. Do not simply set guest 120 Hz without confirming the complete
render-to-panel pipeline can sustain it.

## Production blockers

1. The 600-second branch does not stage/start this policy; do not mistake a
   draft short-probe policy for a deployed 600-second guard.
2. Android's effective cpufreq limits may have vendor QoS/rounding; verify
   every actual readback and whether minimum frequencies obstruct caps.
3. One-second root-guard sampling and shell reads of the pinned sensor
   manifest have not been latency-qualified under load.
4. `scaling_max_freq` alone does not guarantee a maximum **CPU duty cycle**.
   Evaluate isolated guest cgroup `cpu.max` quotas when present (without
   throttling watchdog, kernel thermal services or Android system processes).
5. The legacy watchdog was reboot-only qualified for one observed session,
   not as an independent hardware recovery.
