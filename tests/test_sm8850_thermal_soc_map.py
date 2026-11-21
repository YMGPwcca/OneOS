#!/usr/bin/env python3
"""Offline-only CPU candidate mapper regression; never contacts ADB."""

import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / "scripts/phone/sm8850-soc-candidate-map.py"
SPEC = importlib.util.spec_from_file_location("sm8850_soc_candidate", SOURCE)
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)
NODE = "/sys/class/thermal/thermal_zone27/temp"
BOOT = "123e4567-e89b-12d3-a456-426614174000"


def completed(stdout="", status=0, stderr=""):
    return subprocess.CompletedProcess([], status, stdout=stdout, stderr=stderr)


class SoCCandidateTests(unittest.TestCase):
    def test_audit_mode_makes_zero_adb_calls(self):
        with patch.object(MOD, "adb_call", side_effect=AssertionError("no ADB allowed")):
            self.assertEqual(0, MOD.main([]))

    def test_exact_mapping_only_no_pseudo_zone_or_duplicates(self):
        self.assertEqual(NODE, MOD.map_cpu_path(f"CANDIDATE={NODE}\n"))
        for value in ("", "CANDIDATE=/sys/class/thermal/thermal_zone1/type",
                      "CANDIDATE=/sys/class/thermal/thermal_zone1/../../dev/watchdog",
                      "CANDIDATE=/sys/class/thermal/thermal_zone27/temp\nCANDIDATE=/sys/class/thermal/thermal_zone28/temp",
                      "CANDIDATE=/sys/class/thermal/thermal_zone1/temp\ncpu-hw-trip-0"):
            with self.subTest(value=value), self.assertRaises(MOD.Blocked):
                MOD.map_cpu_path(value)

    def test_scan_is_bounded_unprivileged_and_exact_type_only(self):
        self.assertIn('for f in /sys/class/thermal/thermal_zone*/type', MOD.SCAN)
        self.assertIn('= cpu-0-5-1', MOD.SCAN)
        self.assertIn('"$seen" -le 256', MOD.SCAN)
        for text in ("find /sys", "/dev/watchdog", "reboot", "setprop",
                     "su -c", "/trip_point", "/temp; do"):
            self.assertNotIn(text, MOD.SCAN)

    def test_unprivileged_valid_millidegrees(self):
        calls = []
        def fake(adb, serial, args, timeout=12):
            calls.append(args)
            return completed("40500\n")
        with patch.object(MOD, "adb_call", side_effect=fake):
            out = MOD.read_temperature("adb", "serial", NODE)
        self.assertEqual(40.5, out["celsius"])
        self.assertEqual("shell_named_cat", out["method"])
        self.assertEqual(1, len(calls))
        self.assertNotIn("su", repr(calls))

    def test_permission_denied_only_exact_path_root_fallback(self):
        calls = []
        def fake(adb, serial, args, timeout=12):
            calls.append(args)
            return completed("", 1, "cat: Permission denied") if len(calls) == 1 else completed("41120\n")
        with patch.object(MOD, "adb_call", side_effect=fake):
            out = MOD.read_temperature("adb", "serial", NODE)
        self.assertEqual("root_named_cat", out["method"])
        self.assertAlmostEqual(41.12, out["celsius"])
        self.assertEqual(2, len(calls))
        self.assertIn(NODE, calls[-1][-1])

    def test_nonpermission_denial_never_escalates(self):
        with patch.object(MOD, "adb_call", return_value=completed("", 1, "No such file or directory")) as mock:
            with self.assertRaises(MOD.Blocked):
                MOD.read_temperature("adb", "serial", NODE)
            self.assertEqual(1, mock.call_count)

    def test_three_samples_recheck_identity_and_no_modifications(self):
        original = {"boot_id": BOOT, "system_server": "123"}
        calls = []
        def fake(adb, serial, args, timeout=12):
            calls.append(args)
            return completed(f"CANDIDATE={NODE}\n")
        with patch.object(MOD, "identity", return_value=original) as ident, \
             patch.object(MOD, "adb_call", side_effect=fake), \
             patch.object(MOD, "read_temperature", return_value={"celsius": 36.5}) as temp, \
             patch.object(MOD.time, "sleep"):
            result = MOD.collect("adb", "serial")
        self.assertEqual("NOT_QUALIFIED", result["acceptance"])
        self.assertEqual(NODE, result["temp_path"])
        self.assertEqual(3, temp.call_count)
        self.assertEqual(2, ident.call_count)
        self.assertEqual(1, len(calls))
        self.assertEqual(("shell", "-T", MOD.SCAN), calls[0])

    def test_identity_change_refused(self):
        with patch.object(MOD, "identity", side_effect=[{"boot_id": BOOT}, {"boot_id": "other"}]), \
             patch.object(MOD, "adb_call", return_value=completed(f"CANDIDATE={NODE}\n")), \
             patch.object(MOD, "read_temperature", return_value={"celsius": 33.0}), \
             patch.object(MOD.time, "sleep"):
            with self.assertRaisesRegex(MOD.Blocked, "identity changed"):
                MOD.collect("adb", "serial")

    def test_sentinel_or_malformed_temperature_refused(self):
        for raw in ("-273000", "nan", "0", "1050000", "1 2"):
            with self.subTest(raw=raw), patch.object(MOD, "adb_call", return_value=completed(raw + "\n")):
                with self.assertRaises(MOD.Blocked):
                    MOD.read_temperature("adb", "serial", NODE)


if __name__ == "__main__":
    unittest.main()
