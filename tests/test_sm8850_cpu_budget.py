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
