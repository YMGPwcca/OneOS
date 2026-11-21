#!/usr/bin/env python3
"""OFFLINE-only tests for the independent SM8850 iOS CPU frequency heat cap.

All sysfs writes use disposable /tmp fixtures. No ADB, root, device, governor,
thermal-trip, reboot or Framework actions are invoked by any test.
"""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CAP = ROOT / "switcher/assets/oneios_sm8850_thermal_cap.sh"
GUARD = ROOT / "switcher/assets/oneios_sm8850_thermal_takeover_guard.sh"
SWITCH = ROOT / "switcher/assets/oneios_switch.sh"
HOST = ROOT / "scripts/phone/sm8850-takeover-short-probe.py"

NOMINAL = (39000, 39000, 40000, 285, 306, 340)


def shell(*args):
    return subprocess.run(["sh", str(CAP), *map(str, args)], capture_output=True,
                          text=True, timeout=6)


def pick(previous=0, temps=NOMINAL):
    return shell("--policy", previous, *temps)


class PolicyTests(unittest.TestCase):
    def test_syntax(self):
        result = subprocess.run(["sh", "-n", str(CAP)], capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr)

    def test_initial_low_power_and_three_bands(self):
        for cpu, want in ((39000, "1:80"), (42000, "2:65"), (48000, "3:50")):
            with self.subTest(cpu=cpu):
                s = pick(0, (cpu, 39000, 40000, 285, 306, 340))
                self.assertEqual(0, s.returncode, s.stderr)
                self.assertEqual(want, s.stdout.strip())

    def test_all_three_non_cpu_groups_can_derate(self):
        for temps in ((39000, 49000, 40000, 285, 306, 340),
                      (39000, 39000, 49000, 285, 306, 340),
                      (39000, 39000, 40000, 360, 306, 340),
                      (39000, 39000, 40000, 285, 390, 340),
                      (39000, 39000, 40000, 285, 306, 390)):
            with self.subTest(temps=temps):
                self.assertEqual("3:50", pick(0, temps).stdout.strip())

    def test_no_live_relaxation_even_when_cold(self):
        self.assertEqual("3:50", pick(3).stdout.strip())
        self.assertEqual("2:65", pick(2).stdout.strip())

    def test_hard_abort_has_priority_for_every_group(self):
        boundaries = (55000, 55000, 55000, 380, 420, 420)
        for i, value in enumerate(boundaries):
            values = list(NOMINAL)
            values[i] = value
            with self.subTest(sensor=i):
                result = pick(0, values)
                self.assertEqual(2, result.returncode)
                self.assertEqual("", result.stdout)

    def test_invalid_temperature_or_level_is_not_safe(self):
        cases = [(-1, NOMINAL), (4, NOMINAL),
                 (0, (0, *NOMINAL[1:])),
                 (0, ("not-a-temp", *NOMINAL[1:])),
                 (0, (200001, *NOMINAL[1:])),
                 (0, (*NOMINAL[:3], 1201, *NOMINAL[4:]))]
        for previous, temps in cases:
            with self.subTest(previous=previous, temps=temps):
                self.assertEqual(3, pick(previous, temps).returncode)

    def test_read_only_guard_remains_separate_and_exact(self):
        src = GUARD.read_text()
        for threshold in ('"$CPU_MAX" -lt 55000', '"$GPU_MAX" -lt 55000',
                          '"$DDR_MAX" -lt 55000', '"$BAT" -lt 380',
                          '"$LRP" -lt 420', '"$AP" -lt 420'):
            self.assertIn(threshold, src)
        self.assertNotIn("scaling_max_freq", src)
        self.assertIn("P0_THERMAL_GUARD=FAIL_CLOSED", src)

    def test_source_cap_mandatory_and_started_before_guest(self):
        src = SWITCH.read_text()
        for needle in ("oneios_sm8850_thermal_cap.sh",
                       "$SH \"$CAP_SCRIPT\" --check",
                       "framework_thermal_cap_healthy()",
                       "P0_CPU_CAP=ARMED_BEFORE_XNUHOST_NOT_HARDWARE_CERTIFIED",
                       "thermal.cap.required", "thermal.cap.fault",
                       "SM8850 independent CPU frequency cap missing or stale"):
            self.assertIn(needle, src)
        self.assertLess(src.index('echo "P0_CPU_CAP=ARMED_BEFORE_XNUHOST'),
                        src.index('echo "=== [4/5]'))
        self.assertIn("P0_FULL_600S_TAKEOVER=BLOCKED_UNQUALIFIED_THERMAL_GUARD", src)
        self.assertIn("--set bridges=0 --set wifi=off", src)

    def test_host_stages_exact_cpu_cap_with_integrity(self):
        src = HOST.read_text()
        for needle in ("CAP = ROOT/", '"oneios_sm8850_thermal_cap.sh": CAP',
                       "sha(CAP)", "cap_sha256", "oneios_sm8850_thermal_cap.sh"):
            self.assertIn(needle, src)

    def test_no_overclock_or_vendor_thermal_bypass(self):
        src = CAP.read_text()
        self.assertIn('if [ "$cur" -gt "$target" ]; then', src)
        self.assertIn('[ "$got" -le "$target" ]', src)
        self.assertNotIn("echo -1 > $CFL", src)
        for command in ("setprop sys.powerctl", "reboot -f", "stop zygote",
                        "echo b > /proc/sysrq-trigger", "/sys/devices/system/cpu/cpufreq_limit/"):
            self.assertNotIn(command, src)


class SyntheticCpufreqTests(unittest.TestCase):
    def setUp(self):
        if os.geteuid() == 0:
            self.skipTest("fixture write modes deliberately refuse root")
        self.tmp = tempfile.TemporaryDirectory(prefix="oneios-cpu-cap-test.", dir="/tmp")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.policies = {}
        for name, hw, curr in (("policy0", 3600000, 3600000),
                               ("policy4", 4000000, 2500000),
                               ("policy6", 4742400, 4742400)):
            d = self.root / "sys/devices/system/cpu/cpufreq" / name
            d.mkdir(parents=True)
            (d / "cpuinfo_max_freq").write_text(f"{hw}\n")
            (d / "scaling_max_freq").write_text(f"{curr}\n")
            self.policies[name] = d

    def cap(self, pct):
        return shell("--fixture-step", self.root, pct)

    def value(self, name):
        return int((self.policies[name] / "scaling_max_freq").read_text())

    def test_clamp_and_external_low_power_vote_preserved(self):
        proc = self.cap(80)
        self.assertEqual(0, proc.returncode, proc.stderr)
        self.assertEqual(2880000, self.value("policy0"))
        self.assertEqual(2500000, self.value("policy4"))  # pre-existing 62.5% cap
        self.assertEqual(3793920, self.value("policy6"))

    def test_cap_monotonic_80_65_50_and_never_raises(self):
        for pct in (80, 65, 50, 80):
            with self.subTest(pct=pct):
                self.assertEqual(0, self.cap(pct).returncode)
        self.assertEqual(1800000, self.value("policy0"))
        self.assertEqual(2000000, self.value("policy4"))
        self.assertEqual(2371200, self.value("policy6"))

    def test_missing_or_inconsistent_policy_blocks(self):
        (self.policies["policy6"] / "cpuinfo_max_freq").unlink()
        proc = self.cap(80)
        self.assertNotEqual(0, proc.returncode)
        self.assertIn("P0_CPU_CAP=BLOCKED", proc.stderr)

    def test_fixture_cannot_target_live_sysfs(self):
        self.assertNotEqual(0, shell("--fixture-step", "/sys", 80).returncode)
        self.assertNotEqual(0, shell("--fixture-step", "/", 80).returncode)


if __name__ == "__main__":
    unittest.main()
