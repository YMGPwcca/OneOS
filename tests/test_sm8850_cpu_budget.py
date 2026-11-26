#!/usr/bin/env python3
"""Offline contracts for exact 180s isolated CPU bandwidth integration."""
from pathlib import Path
import subprocess
import unittest

ASSETS = Path(__file__).resolve().parents[1] / "switcher/assets"
CAP = (ASSETS / "oneios_sm8850_thermal_cap.sh").read_text()
SW = (ASSETS / "oneios_switch.sh").read_text()
GUARD = (ASSETS / "oneios_sm8850_thermal_takeover_guard.sh").read_text()


class CpuBudgetIntegration(unittest.TestCase):
    def test_shell_syntax(self):
        for name in ("oneios_sm8850_thermal_cap.sh", "oneios_switch.sh",
                     "oneios_sm8850_thermal_takeover_guard.sh"):
            p = subprocess.run(["sh", "-n", str(ASSETS / name)],
                               capture_output=True, text=True)
            self.assertEqual(0, p.returncode, p.stderr)

    def test_profile_and_guest_join_order(self):
        early = SW.index('--check-bandwidth ||')
        profile = SW.index("printf 'cfs-v1-180s\\n'")
        prearm = SW.index('--run-prearmed "$CTL" "$WD_GEN"')
        claim = SW.index('APFS_DATA_CLONE=CONSUMED_ONE_SHOT_BEFORE_FRAMEWORK_STOP')
        stop = SW.index('if ! stop_android_framework; then')
        ready = SW.index('CPU_THROTTLE=PREARMED_ACTIVATED_POST_STOP_CFS_V1')
        launch = SW.index('unshare -m /system/bin/sh "$SELF" --inner', stop)
        self.assertEqual(sorted((early, profile, prearm, claim, stop, ready, launch)),
                         [early, profile, prearm, claim, stop, ready, launch])
        inner = SW.split('    --inner)\n', 1)[1].split('    --stop-loop)', 1)[0]
        self.assertLess(inner.index('> "$guest_cpu_group/cgroup.procs"'),
                        inner.index('> "$CTL/inner.pid"'))
        self.assertLess(inner.index('MEMBERSHIP=VERIFIED'),
                        inner.index('> /data/session/xnuhost.pid'))
        self.assertIn('[ "$cp_level" = 7 ]', SW)
        self.assertIn('framework_cpu_budget_group "$CTL" >/dev/null', SW)

    def test_actual_budget_step_and_sample_identity(self):
        # Execute the actual policy + actuator transition logic, replacing
        # only cgroup validation/writes with a mock. No real sysfs or root.
        model = CAP.split("# BEGIN SM8850_HYSTERESIS_MODEL\n", 1)[1].split(
            "# END SM8850_HYSTERESIS_MODEL", 1)[0]
        lifecycle = CAP.split("# BEGIN SM8850_CFS_LIFECYCLE\n", 1)[1].split(
            "# END SM8850_CFS_LIFECYCLE", 1)[0]
        validator = CAP[CAP.index("uint() {"):CAP.index("birth() {")]
        policy = CAP[CAP.index("policy() {"):CAP.index("# Scan the host's policies.")]
        fixture = model + lifecycle + validator + policy + r'''
BOOT=mock GEN=mock BW_GROUP=/not-a-real-group
BW_PCT=40 BW_LATCH=0 BW_DWELL=0 BW_HSEQ=0 BW_STATE=START
FLOOR_MODE=0 writes=0 verify_fail=0 apply_fail=0
gpu=40000 ddr=40000 bat=300 lrp=320 ap=350
bw_verify() { [ "$verify_fail" = 0 ]; }
sm8850_cpu_quota_apply() {
    [ "$apply_fail" = 0 ] || return 1
    writes=$((writes+1))
}
sample() {
    hseq=$1 cpu=$2
    bw_step || { echo REFUSED; return 1; }
    printf 'STEP=%s:%s:%s:%s:%s:%s\n' "$hseq" "$BW_PCT" "$BW_LATCH" "$BW_DWELL" "$BW_STATE" "$writes"
}
sample 1 80000
sample 2 75000
sample 3 70000
sample 4 40000
sample 4 40000
sample 5 40000
sample 6 40000
sample 7 40000
sample 8 40000
sample 7 40000 && exit 9
bat=440
sample 9 40000
bat=300
verify_fail=1
sample 10 40000 && exit 9
verify_fail=0
# Test actual write refusal without updating the prior applied state.
BW_PCT=40
apply_fail=1
sample 10 80000 && exit 9
[ "$BW_PCT" = 40 ] && [ "$BW_HSEQ" = 9 ] || exit 9
exit 0
'''
        p = subprocess.run(["sh", "-c", fixture], capture_output=True,
                           text=True, timeout=5)
        self.assertEqual(0, p.returncode, (p.stdout, p.stderr))
        self.assertEqual([
            "STEP=1:10:1:0:HARD:1", "STEP=2:10:1:0:HARD:1",
            "STEP=3:10:0:0:RECOVERY:1", "STEP=4:10:0:1:COOL:1",
            "STEP=4:10:0:1:COOL:1", "STEP=5:10:0:2:COOL:1",
            "STEP=6:10:0:3:COOL:1", "STEP=7:10:0:4:COOL:1",
            "STEP=8:20:0:0:COOL:2", "REFUSED", "STEP=9:10:0:0:COOL:3",
            "REFUSED", "REFUSED"
        ], [line for line in p.stdout.splitlines()
            if line.startswith("STEP=") or line == "REFUSED"])

    def test_independent_guards_and_separate_profile(self):
        body = CAP.split("# BEGIN SM8850_CFS_LIFECYCLE\n", 1)[1].split(
            "# END SM8850_CFS_LIFECYCLE", 1)[0]
        self.assertNotIn("scaling_max_freq", body)
        self.assertNotIn("scaling_min_freq", body)
        self.assertNotIn("> /dev/cpuctl/cpu.cfs_", CAP)
        self.assertIn('framework_down_for_cpu_cap && bw_host_ready', body)
        self.assertIn('bw_verify || return 1', body)
        self.assertIn('[ "$hseq" != "$BW_HSEQ" ] || return 0', body)
        self.assertIn('policy 0 "$cpu" "$gpu" "$ddr" "$bat" "$lrp" "$ap"', body)
        self.assertIn('bw_step || fault isolated_cpu_bandwidth_or_membership', CAP)
        self.assertIn('apply_cap "" "$pct" strict', CAP)
        self.assertIn('guard_root_cpu_membership', GUARD)
        self.assertIn('"$CPU_MAX" -lt 90000', GUARD)
        self.assertIn('framework deadline reached at $tick', SW)
        self.assertIn('thermal.cap.required', SW)

if __name__ == "__main__":
    unittest.main()
