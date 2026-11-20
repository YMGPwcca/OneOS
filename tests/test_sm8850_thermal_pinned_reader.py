#!/usr/bin/env python3
"""Offline-only sensor reader tests: exact cpu type and pinned boot mapping."""

from pathlib import Path
import subprocess
import tempfile
import unittest

READER = Path(__file__).resolve().parents[1] / "switcher/assets/oneios_sm8850_thermal_pinned_reader.sh"
BOOT = "123e4567-e89b-12d3-a456-426614174000"


def put(root, name, content):
    f = root / name
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(str(content) + "\n", encoding="utf-8")
    return f


def make_fixture(root, zone=16):
    put(root, "proc/sys/kernel/random/boot_id", BOOT)
    put(root, "proc/uptime", "100.0 200.0")
    put(root, f"sys/class/thermal/thermal_zone{zone}/type", "cpu-0-5-1")
    put(root, f"sys/class/thermal/thermal_zone{zone}/temp", 29600)
    put(root, "sys/class/power_supply/battery/temp", 266)
    put(root, "sys/class/power_supply/battery/lrp", 285)
    put(root, "sys/class/sec/sec-ap-thermistor/temperature", 270)


class ThermalPinnedTests(unittest.TestCase):
    def setUp(self):
        self.ctx = tempfile.TemporaryDirectory(prefix="oneos-sm8850-pinned-")
        self.addCleanup(self.ctx.cleanup)
        self.root = Path(self.ctx.name)
        make_fixture(self.root)

    def call(self, idx="16", boot=BOOT):
        return subprocess.run(["sh", str(READER), "--fixture-root", str(self.root), idx, boot],
                              capture_output=True, text=True, timeout=3)

    def test_syntax_and_zero_actions(self):
        self.assertEqual(0, subprocess.run(["sh", "-n", str(READER)]).returncode)
        source = READER.read_text()
        for term in ("/dev/watchdog", "sys.powerctl", "return.request", "reboot ",
                     "setprop ", "scaling_max_freq", "find /sys", "rm -rf", "stop zygote"):
            self.assertNotIn(term, source)

    def test_four_realistic_readings_with_units_and_boot(self):
        r = self.call()
        self.assertEqual(0, r.returncode, r.stderr)
        for expected in ("THERMAL_PINNED=FOUR_SENSOR_READ_ONLY_NOT_GUARD",
                         "source=--fixture-root", f"boot_id={BOOT}",
                         "cpu_zone_type=cpu-0-5-1", "cpu_zone_path=/sys/class/thermal/thermal_zone16/temp",
                         "cpu_milli_c=29600", "cpu_deci_c=296", "battery_deci_c=266",
                         "lrp_deci_c=285", "board_ap_deci_c=270",
                         "after_framework_available=NOT_VERIFIED"):
            self.assertIn(expected, r.stdout)

    def test_wrong_type_blocks_pseudo_zone(self):
        put(self.root, "sys/class/thermal/thermal_zone16/type", "cpu-hw-trip-0")
        r = self.call()
        self.assertEqual(4, r.returncode)
        self.assertIn("cpu_type_mismatch", r.stderr)
        self.assertNotIn("FOUR_SENSOR_READ_ONLY", r.stdout)

    def test_type_mismatch_on_other_zone_blocks(self):
        make_fixture(self.root, zone=17)
        put(self.root, "sys/class/thermal/thermal_zone16/type", "gpuss-0-0")
        self.assertEqual(4, self.call().returncode)
        self.assertEqual(0, self.call("17").returncode)

    def test_wrong_boot_binding_blocks(self):
        r = self.call(boot="223e4567-e89b-12d3-a456-426614174000")
        self.assertEqual(4, r.returncode)
        self.assertIn("wrong_boot", r.stderr)

    def test_malformed_index_rejected(self):
        for index in ("", "-1", "0016", "999", "16/../../dev", "16x", "16 17"):
            with self.subTest(index=index):
                self.assertEqual(2, self.call(idx=index).returncode)

    def test_zero_or_negative_cpu_sentinel_fails(self):
        for raw in (0, -273000, "garbage", 160000, "29000 30000"):
            with self.subTest(raw=raw):
                put(self.root, "sys/class/thermal/thermal_zone16/temp", raw)
                self.assertEqual(4, self.call().returncode)

    def test_cpu_above_105c_is_not_hidden_by_pseudo_filter(self):
        put(self.root, "sys/class/thermal/thermal_zone16/temp", 106000)
        r = self.call()
        self.assertEqual(0, r.returncode, r.stderr)
        self.assertIn("cpu_milli_c=106000", r.stdout)
        self.assertIn("cpu_deci_c=1060", r.stdout)

    def test_battery_lrp_board_errors_fail_without_partial_output(self):
        files = ("sys/class/power_supply/battery/temp",
                 "sys/class/power_supply/battery/lrp",
                 "sys/class/sec/sec-ap-thermistor/temperature")
        for rel in files:
            with self.subTest(rel=rel):
                put(self.root, rel, 0)
                r = self.call()
                self.assertEqual(4, r.returncode)
                self.assertEqual("", r.stdout)
                put(self.root, rel, 285)

    def test_missing_cpu_path_blocks(self):
        (self.root / "sys/class/thermal/thermal_zone16/temp").unlink()
        self.assertEqual(4, self.call().returncode)

    def test_symlink_escape_fixture_blocks_before_read(self):
        f = self.root / "sys/class/thermal/thermal_zone16/temp"
        f.unlink()
        f.symlink_to("/proc/sys/kernel/random/boot_id")
        self.assertEqual(4, self.call().returncode)

    def test_fixture_root_not_slash(self):
        r = subprocess.run(["sh", str(READER), "--fixture-root", "/tmp/..", "16", BOOT],
                           capture_output=True, text=True, timeout=3)
        self.assertEqual(2, r.returncode)

    def test_no_implicit_live_mode(self):
        r = subprocess.run(["sh", str(READER)], capture_output=True, timeout=3)
        self.assertEqual(2, r.returncode)


if __name__ == "__main__":
    unittest.main()
