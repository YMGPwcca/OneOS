#!/usr/bin/env python3
"""Offline tests of the actual OneOS shell cap policy; no root or sysfs."""
import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
CAP = ROOT / "switcher/assets/oneios_sm8850_thermal_cap.sh"
GUARD = ROOT / "switcher/assets/oneios_sm8850_thermal_takeover_guard.sh"

class Thermal75(unittest.TestCase):
    def policy(self, cpu, previous=2, gpu=30000, ddr=30000, bat=300, lrp=300, ap=300):
        result = subprocess.run(["bash", str(CAP), "--policy", *map(str, (previous,cpu,gpu,ddr,bat,lrp,ap))],
                                capture_output=True, text=True, check=False)
        return result.returncode, result.stdout.strip()

    def test_cpu_breakpoints_no_temperature_return_at_75(self):
        for cpu, expected in [(30000,"2:40"),(64999,"2:40"),(65000,"3:28"),
                              (69999,"3:28"),(70000,"4:18"),(74999,"4:18"),
                              (75000,"5:12"),(75001,"5:12"),(79999,"5:12"),
                              (80000,"6:8"),(89999,"6:8")]:
            with self.subTest(cpu=cpu):
                self.assertEqual((0, expected), self.policy(cpu))

    def test_no_reboost_or_weaken_other_sensors(self):
        self.assertEqual((0,"5:12"), self.policy(60000, previous=5))
        self.assertEqual((0,"6:8"), self.policy(30000, gpu=85000))
        self.assertEqual((0,"6:8"), self.policy(30000, bat=440))
        self.assertEqual(2, self.policy(90000)[0])
        self.assertEqual(2, self.policy(30000, gpu=95000)[0])
        self.assertEqual(2, self.policy(30000, bat=480)[0])
        self.assertEqual(3, self.policy(-1)[0])
        self.assertEqual(3, self.policy(75000, previous=7)[0])

    def test_safety_contract_and_syntax(self):
        for path in (CAP, GUARD):
            subprocess.run(["bash","-n",str(path)], check=True)
        cap = CAP.read_text()
        guard = GUARD.read_text()
        self.assertIn("TARGET_30_70_THROTTLE_BY_75_MONOTONIC", cap)
        self.assertIn('[ "$CPU_MAX" -lt 90000 ]', guard)
        self.assertIn('apply_cap "" "$pct" strict', cap)
        self.assertIn('[ "$prev" -le "$level" ] || level=$prev', cap)
        self.assertIn('[ "$cur" -gt "$target" ]', cap)
        self.assertNotIn('> "$pol/scaling_min_freq"', cap)

if __name__ == "__main__":
    unittest.main()
