#!/usr/bin/env python3
"""P0 read-only thermal junction survey regression: no real ADB contact."""
import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / "scripts/phone/sm8850-thermal-junction-inventory.py"
SPEC = importlib.util.spec_from_file_location("junction_survey", SOURCE)
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)

SCAN_GOOD = "\n".join([
    "ZONE\t1\tcpu-hw-trip-0",  # ignored pseudo-105C thermal threshold
    "ZONE\t2\tcpu-0-5-1", "ZONE\t3\tcpuss-1",
    "ZONE\t4\tgpuss-0", "ZONE\t5\tddr", "ZONE\t6\txo-therm",
])


def done(value="", status=0, stderr=""):
    return subprocess.CompletedProcess([], status, value, stderr)


def reading(idx, name, group, value):
    return {"index": idx, "type": name, "group": group,
            "path": f"/sys/class/thermal/thermal_zone{idx}/temp",
            "raw_millidegrees_c": value, "celsius": value/1000,
            "method": "shell_named_cat"}


class JunctionInventoryTests(unittest.TestCase):
    def test_audit_does_not_contact_device(self):
        with patch.object(M.mapper, "serial_for", side_effect=AssertionError("no ADB")):
            self.assertEqual(0, M.main([]))

    def test_match_exact_backend_groups_and_exclude_pseudotrip(self):
        for name, kind in [("cpu-0-5-1","cpu"), ("cpuss-1","cpu"),
                           ("gpuss-0","gpu"), ("ddr","ddr"),
                           ("xo-therm","xo"), ("cpu-hw-trip-0",None),
                           ("cpu-hw-trip-1",None), ("skin",None)]:
            with self.subTest(name=name):
                self.assertEqual(kind, M.group_of(name))

    def test_unprivileged_scan_is_bounded_type_only(self):
        self.assertIn("thermal_zone*/type", M.SCAN)
        self.assertIn('[ "$seen" -le 256 ]', M.SCAN)
        self.assertNotIn("/dev/watchdog", M.SCAN)
        self.assertNotIn("su -c", M.SCAN)
        self.assertNotIn("find /sys", M.SCAN)
        self.assertNotIn("*/temp", M.SCAN)

    def test_listing_selects_only_real_sensors(self):
        selected, unreadable = M.parse_listing(SCAN_GOOD)
        self.assertEqual([], unreadable)
        self.assertEqual(5, len(selected))
        self.assertNotIn("cpu-hw-trip-0", [row[1] for row in selected])
        self.assertIn((4, "gpuss-0", "gpu"), selected)

    def test_unreadable_types_never_become_complete(self):
        selected, errors = M.parse_listing(SCAN_GOOD + "\nTYPE_UNREADABLE\t7")
        self.assertEqual([7], errors)
        vals=[reading(idx,n,g,30000) for idx,n,g in selected]
        _, complete = M.summarize(vals, [], errors)
        self.assertFalse(complete)

    def test_untrusted_duplicate_bad_number_and_extra_lines_block(self):
        cases = ["", "ZONE\t1\tcpu-0-1\nZONE\t1\tddr",
                 "ZONE\t999\tcpu-0-1",
                 "ZONE\t1\tcpu-0-1\ncat /dev/watchdog",
                 "ZONE\t1\tcpu-0-1;reboot",
                 "TYPE_UNREADABLE\t0\nZONE\t0\tcpu-1",
                 "ZONE\t1\tcpu-0-1\n" * 257]
        for value in cases:
            with self.subTest(value=value[:30]), self.assertRaises(M.Blocked):
                M.parse_listing(value)

    def test_read_only_named_cpu_millidegrees(self):
        requests=[]
        def fake(adb, serial, args, timeout=5):
            requests.append(args)
            return done("cpu-0-5-1\n" if args[-1].endswith("/type") else "35800\n")
        with patch.object(M.mapper, "adb_call", side_effect=fake):
            output=M.read_zone("adb", "S", 16, "cpu-0-5-1", "cpu")
        self.assertEqual(35.8, output["celsius"])
        self.assertEqual("shell_named_cat", output["method"])
        self.assertEqual(3, len(requests))
        self.assertNotIn("su -c", repr(requests))

    def test_root_only_after_permission_denial_on_exact_temp(self):
        calls=[]
        def fake(adb, serial, args, timeout=5):
            calls.append(args)
            if args[-1].endswith("/type"):
                return done("gpuss-1\n")
            if "su -c" in args[-1]:
                return done("39500\n")
            return done("", 1, "Permission denied")
        with patch.object(M.mapper, "adb_call", side_effect=fake):
            record=M.read_zone("adb", "S", 8, "gpuss-1", "gpu")
        self.assertEqual(39.5, record["celsius"])
        self.assertEqual("root_named_cat", record["method"])
        self.assertIn("/sys/class/thermal/thermal_zone8/temp", calls[-2][-1])
        self.assertEqual(4, len(calls))

    def test_no_root_retry_for_nonpermission_error(self):
        calls=[]
        def fake(adb, serial, args, timeout=5):
            calls.append(args)
            return done("ddr\n" if args[-1].endswith("/type") else "", 0 if args[-1].endswith("/type") else 1,
                        "" if args[-1].endswith("/type") else "No such file")
        with patch.object(M.mapper, "adb_call", side_effect=fake):
            with self.assertRaises(M.Blocked):
                M.read_zone("adb", "S", 9, "ddr", "ddr")
        self.assertEqual(2, len(calls))

    def test_type_changed_between_reads_blocks(self):
        count=[0]
        def fake(adb, serial, args, timeout=5):
            if args[-1].endswith("/temp"):
                return done("40500\n")
            count[0]+=1
            return done("cpu-0-5-1\n" if count[0] == 1 else "cpu-hw-trip-1\n")
        with patch.object(M.mapper, "adb_call", side_effect=fake):
            with self.assertRaises(M.Blocked):
                M.read_zone("adb", "S", 16, "cpu-0-5-1", "cpu")

    def test_sentinel_malformed_sensor_fails_closed(self):
        for raw in ("-273000", "nan", "", "9999999", "abc"):
            with self.subTest(raw=raw):
                def fake(adb, serial, args, timeout=5):
                    return done("ddr\n" if args[-1].endswith("/type") else raw)
                with patch.object(M.mapper, "adb_call", side_effect=fake):
                    with self.assertRaises(M.Blocked):
                        M.read_zone("adb", "S", 5, "ddr", "ddr")

    def test_hottest_group_maxima_never_use_pseudotrips(self):
        vals=[reading(2,"cpu-0-5-1","cpu",35800),
              reading(3,"cpuss-1","cpu",72000),
              reading(4,"gpuss-0","gpu",68000),
              reading(5,"ddr","ddr",41000)]
        top, complete = M.summarize(vals, [], [])
        self.assertTrue(complete)
        self.assertEqual("cpuss-1", top["cpu"]["type"])
        self.assertEqual(68.0, top["gpu"]["celsius"])
        self.assertIsNone(top["xo"])
        self.assertFalse(M.summarize(vals, [{"type":"cpu-0-1"}], [])[1])

    def test_missing_ddr_is_incomplete_not_safe(self):
        vals=[reading(2,"cpu-0-5-1","cpu",35800),
              reading(4,"gpuss-0","gpu",68000)]
        top, complete=M.summarize(vals, [], [])
        self.assertIsNone(top["ddr"])
        self.assertFalse(complete)

    def test_collect_records_errors_and_rechecks_identity(self):
        info={"boot_id":"testboot","system_server":"1"}
        with patch.object(M.mapper, "identity", return_value=info) as id_mock, \
             patch.object(M.mapper, "adb_call", return_value=done(SCAN_GOOD)) as scan_mock, \
             patch.object(M, "read_zone", side_effect=lambda a,b,idx,n,g: reading(idx,n,g,30000)):
            result=M.collect("adb", "S", clock=lambda: 1)
        self.assertEqual(5, result["selected_count"])
        self.assertTrue(result["scan_coverage_complete"])
        self.assertEqual("NOT_QUALIFIED", result["acceptance"])
        self.assertFalse(result["independent_guard_active"])
        self.assertEqual(2, id_mock.call_count)
        self.assertEqual(1, scan_mock.call_count)

    def test_any_failed_sensor_causes_incomplete_coverage(self):
        info={"boot_id":"test"}
        with patch.object(M.mapper, "identity", return_value=info), \
             patch.object(M.mapper, "adb_call", return_value=done(SCAN_GOOD)), \
             patch.object(M, "read_zone", side_effect=M.Blocked("permission")):
            result=M.collect("adb", "S", clock=lambda: 1)
        self.assertFalse(result["scan_coverage_complete"])
        self.assertEqual(5,len(result["sensor_errors"]))

    def test_identity_change_fails_closed(self):
        with patch.object(M.mapper, "identity", side_effect=[{"boot_id":"a"},{"boot_id":"b"}]), \
             patch.object(M.mapper, "adb_call", return_value=done(SCAN_GOOD)), \
             patch.object(M, "read_zone", side_effect=lambda a,b,idx,n,g: reading(idx,n,g,30000)):
            with self.assertRaises(M.Blocked):
                M.collect("adb", "S", clock=lambda: 1)


if __name__ == "__main__":
    unittest.main()
