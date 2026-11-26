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
