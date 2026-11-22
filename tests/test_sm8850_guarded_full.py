#!/usr/bin/env python3
"""Host-only safety contract for SM8850 GPU3D full-run throttle and duration.

No ADB, root, sysfs mutation, watchdog open or Framework stop.
"""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ASSET = ROOT / "switcher/assets"
CAP = ASSET / "oneios_sm8850_thermal_cap.sh"
GUARD = ASSET / "oneios_sm8850_thermal_takeover_guard.sh"
SWITCH = ASSET / "oneios_switch.sh"

NORMAL = [39000, 39000, 40000, 285, 306, 340]


def policy(cpu, prev=0):
    sample = [cpu, *NORMAL[1:]]
    return subprocess.run(
        ["sh", str(CAP), "--policy", str(prev), *map(str, sample)],
        capture_output=True, text=True, timeout=6,
    )


class FullRunThermalContract(unittest.TestCase):
    def test_shell_syntax(self):
        for source in [CAP, GUARD, SWITCH]:
            with self.subTest(source=source):
                p = subprocess.run(["sh", "-n", str(source)], capture_output=True, text=True)
                self.assertEqual(0, p.returncode, p.stderr)

    def test_throttle_bands_and_80c_is_not_return(self):
        for temp, band in [(39000, "1:60"), (55000, "2:40"),
                           (65000, "3:28"), (72000, "4:18"),
                           (77000, "5:12"), (80000, "6:8"),
                           (89999, "6:8")]:
            with self.subTest(temp=temp):
                p = policy(temp)
                self.assertEqual(0, p.returncode, p.stderr)
                self.assertEqual(band, p.stdout.strip())

    def test_emergency_remains_distinct(self):
        self.assertEqual(2, policy(90000).returncode)
        self.assertNotEqual(0, policy(0).returncode)
        self.assertEqual("6:8", policy(39000, prev=6).stdout.strip())

    def test_root_guard_is_fullrun_only(self):
        guard = GUARD.read_text()
        cap = CAP.read_text()
        self.assertIn('[ "$(cat "$CTL/framework.mode" 2>/dev/null)" = run ]', guard)
        self.assertIn('[ "$(cat "$CTL/framework.mode" 2>/dev/null)" = run ]', cap)
        for token in ("cpu-hw-trip-*", '"$CPU_MAX" -lt 90000',
                      '"$GPU_MAX" -lt 95000', "thermal.guard.fault"):
            self.assertIn(token, guard)
        self.assertNotIn("setprop sys.powerctl", guard)
        self.assertIn('target=$mn', cap)
        self.assertIn('if [ "$cur" -gt "$target" ]; then', cap)
        self.assertIn('"$got" -le "$target"', cap)

    def test_bounded_duration_and_affinity(self):
        s = SWITCH.read_text()
        self.assertIn('FW_DURATION=600', s)
        self.assertIn('FW_DURATION=${6:-600}', s)
        self.assertIn('"$FW_DURATION" -ge 60', s)
        self.assertIn('"$FW_DURATION" -le 600', s)
        self.assertIn('fw_seconds=$FW_DURATION', s)
        self.assertIn('--set bridges=0 --set cpu-affinity-bench=1 --set cpu-pin=1', s)
        self.assertIn('framework_thermal_guard_healthy()', s)
        self.assertIn('framework_thermal_cap_healthy()', s)
        self.assertIn('"$CTL/thermal.guard.required"', s)
        self.assertIn('"$CTL/thermal.cap.required"', s)
        self.assertIn('--run "$CTL" "$STAGE/thermal.guard.manifest" "$WD_GEN"', s)
        self.assertIn('--run "$CTL" "$WD_GEN"', s)
        self.assertIn('ONEIOS_GPU_3D_MODE=REQUIRED_FAIL_CLOSED_NO_2D_FALLBACK', s)

    def test_thermal_arms_before_framework_stop(self):
        s = SWITCH.read_text()
        self.assertLess(
            s.index('THERMAL_GUARD=ARMED_ROOT'),
            s.index('=== [3/5]'),
        )
        self.assertIn('independent thermal monitor/cap missing, stale', s)
        self.assertIn('root thermal sensor manifest not qualified on current boot', s)
        self.assertLess(s.index('=== [3/5]'), s.index('CPU_THROTTLE=ARMED_POST_STOP'))


@unittest.skipIf(os.geteuid() == 0, "root may not use the fixture write mode")
class SyntheticCpufreqTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="oneios-cpu-cap-test.", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.policies = {}
        for name, max_hz, min_hz, current in (
            ("policy0", 3600000, 384000, 3600000),
            ("policy6", 4742400, 768000, 2200000),
        ):
            folder = self.root / "sys/devices/system/cpu/cpufreq" / name
            folder.mkdir(parents=True)
            (folder / "cpuinfo_max_freq").write_text(str(max_hz))
            (folder / "cpuinfo_min_freq").write_text(str(min_hz))
            (folder / "scaling_max_freq").write_text(str(current))
            self.policies[name] = folder

    def apply(self, pct):
        return subprocess.run(["sh", str(CAP), "--fixture-step",
                               str(self.root), str(pct)],
                              capture_output=True, text=True, timeout=7)

    def read(self, name):
        return int((self.policies[name] / "scaling_max_freq").read_text())

    def test_monotonic_never_raise_and_minimum_floor(self):
        for percentage in (60, 40, 28, 18, 12, 8, 60):
            with self.subTest(pct=percentage):
                p = self.apply(percentage)
                self.assertEqual(0, p.returncode, p.stderr)
        self.assertEqual(384000, self.read("policy0"))
        self.assertEqual(768000, self.read("policy6"))

    def test_external_tighter_vote_is_not_lifted(self):
        p = self.apply(60)
        self.assertEqual(0, p.returncode, p.stderr)
        self.assertEqual(2160000, self.read("policy0"))
        self.assertEqual(2200000, self.read("policy6"))

    def test_invalid_policy_and_live_root_are_blocked(self):
        self.assertNotEqual(0, subprocess.run(
            ["sh", str(CAP), "--fixture-step", "/sys", "60"],
            capture_output=True, text=True, timeout=7).returncode)
        (self.policies["policy6"] / "cpuinfo_min_freq").unlink()
        self.assertNotEqual(0, self.apply(60).returncode)


if __name__ == "__main__":
    unittest.main()
