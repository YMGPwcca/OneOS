#!/usr/bin/env python3
"""Fixture-only sensor-manifest validation; no phone, root or ADB."""

import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1] / "scripts/phone/sm8850-thermal-manifest.py"
SPEC = importlib.util.spec_from_file_location("sm8850_manifest", MODULE)
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)

BOOT = "a6007f1e-4fc3-4e99-82dd-267ccb249656"


def zone(idx, name, group, milli):
    return {
        "index": idx, "type": name, "group": group,
        "path": f"/sys/class/thermal/thermal_zone{idx}/temp",
        "raw_millidegrees_c": milli, "celsius": milli / 1000.0,
        "method": "shell_named_cat",
    }


def fixture():
    readings = [
        zone(16, "cpu-0-5-1", "cpu", 37000),
        zone(17, "cpuss-1", "cpu", 32000),
        zone(38, "gpuss-2", "gpu", 35100),
        zone(47, "ddr", "ddr", 35100),
    ]
    peak = {}
    for group in ("cpu", "gpu", "ddr", "xo"):
        eligible = [z for z in readings if z["group"] == group]
        item = max(eligible, key=lambda z: z["raw_millidegrees_c"]) if eligible else None
        peak[group] = (
            {"index": item["index"], "type": item["type"],
             "path": item["path"], "celsius": item["celsius"]}
            if item is not None else None
        )
    return {
        "schema": 1, "kind": "SM8850_REAL_CPU_GPU_DDR_XO_READONLY_SURVEY",
        "identity": {
            "model": "SM-S948B", "device": "m3q",
            "firmware": "S948BXXS4BZIG", "boot_completed": "1",
            "selinux": "Enforcing", "system_server": "234",
            "boot_id": BOOT,
        },
        "selected_count": len(readings), "readings": readings,
        "sensor_errors": [], "unreadable_type_indices": [],
        "hottest_by_group": peak, "scan_coverage_complete": True,
        "acceptance": "NOT_QUALIFIED",
        "vendor_thresholds_qualified": False,
        "verified_after_framework_stop": False,
        "independent_guard_active": False,
    }


class ManifestTest(unittest.TestCase):
    def assert_refused(self, obj):
        with self.assertRaises(M.Refused):
            M.validate(obj)

    def test_nominal_complete_evidence_manifest(self):
        result = M.validate(fixture())
        self.assertEqual(BOOT, result["device"]["boot_id"])
        self.assertEqual(4, result["zone_count"])
        self.assertEqual(["cpu", "gpu", "ddr"], result["required_groups"])
        self.assertEqual([16, 17, 38, 47], [z["index"] for z in result["zones"]])

    def test_manifest_cannot_authorize_guard_or_takeover(self):
        result = M.validate(fixture())
        for key in ("real_device_manifest_revalidated", "firmware_limits_qualified",
                    "independent_guard_running", "recovery_certified",
                    "takeover_admission_granted"):
            self.assertIs(result[key], False)
        self.assertEqual("NOT_QUALIFIED", result["evidence_status"])

    def test_audit_does_not_read_or_write(self):
        with patch.object(M, "build_manifest", side_effect=AssertionError("no IO")):
            self.assertEqual(0, M.main([]))

    def test_reject_error_list_or_unreadable_zone(self):
        for key, value in (("sensor_errors", [{"type": "gpuss-2"}]),
                           ("unreadable_type_indices", [5])):
            with self.subTest(key=key):
                info = fixture()
                info[key] = value
                self.assert_refused(info)

    def test_reject_false_coverage_and_unsafe_qualification(self):
        for key, value in (("scan_coverage_complete", False),
                           ("vendor_thresholds_qualified", True),
                           ("verified_after_framework_stop", True),
                           ("independent_guard_active", True),
                           ("acceptance", "PASS")):
            with self.subTest(key=key):
                info = fixture()
                info[key] = value
                self.assert_refused(info)

    def test_reject_wrong_device_or_firmware_or_boot(self):
        for key, value in (("model", "UNKNOWN"), ("firmware", "UNVERIFIED"),
                           ("boot_id", "invalid"), ("selinux", "Permissive"),
                           ("system_server", "")):
            with self.subTest(key=key):
                info = fixture()
                info["identity"][key] = value
                self.assert_refused(info)

    def test_reject_pseudo_trip_and_wrong_type_group(self):
        for name, group in (("cpu-hw-trip-0", "cpu"),
                            ("gpuss-2", "cpu"), ("skin", "cpu"),
                            ("ddr", "gpu")):
            with self.subTest(name=name):
                info = fixture()
                info["readings"][0]["type"] = name
                info["readings"][0]["group"] = group
                self.assert_refused(info)

    def test_reject_duplicate_zone_index(self):
        info = fixture()
        info["readings"][1]["index"] = 16
        info["readings"][1]["path"] = "/sys/class/thermal/thermal_zone16/temp"
        self.assert_refused(info)

    def test_reject_path_traversal_and_wrong_path_index(self):
        for path in ("/sys/class/thermal/thermal_zone16/../dev/watchdog",
                     "/sys/class/thermal/thermal_zone16/type",
                     "/sys/class/thermal/thermal_zone88/temp"):
            with self.subTest(path=path):
                info = fixture()
                info["readings"][0]["path"] = path
                self.assert_refused(info)

    def test_reject_missing_gpu_or_ddr(self):
        for missing in ("gpu", "ddr"):
            info = fixture()
            info["readings"] = [r for r in info["readings"] if r["group"] != missing]
            info["selected_count"] = len(info["readings"])
            info["hottest_by_group"][missing] = None
            with self.subTest(missing=missing):
                self.assert_refused(info)

    def test_reject_mismatched_reported_hottest(self):
        info = fixture()
        info["hottest_by_group"]["cpu"]["type"] = "cpuss-1"
        self.assert_refused(info)

    def test_reject_bad_millidegree_units(self):
        for val in (None, True, 370000, -273000, "37000"):
            info = fixture()
            info["readings"][0]["raw_millidegrees_c"] = val
            with self.subTest(value=val):
                self.assert_refused(info)

    def test_reject_disagreeing_float_celsius(self):
        info = fixture()
        info["readings"][0]["celsius"] = 999.0
        self.assert_refused(info)

    def test_reject_untrusted_read_method(self):
        info = fixture()
        info["readings"][0]["method"] = "unverified_kernel_write"
        self.assert_refused(info)

    def test_file_size_and_symlink_rejected(self):
        with tempfile.TemporaryDirectory(prefix="oneos-p0-manifest-") as d:
            root = Path(d)
            data = root / "source.json"
            data.write_text(json.dumps(fixture()), encoding="utf-8")
            self.assertEqual(4, M.build_manifest(data)["zone_count"])
            link = root / "alias.json"
            link.symlink_to(data)
            with self.assertRaises(M.Refused):
                M.build_manifest(link)
            data.write_bytes(b" " * (M.MAX_SOURCE_BYTES + 1))
            with self.assertRaises(M.Refused):
                M.build_manifest(data)

    def test_build_cli_emits_non_authorizing_file(self):
        with tempfile.TemporaryDirectory(prefix="oneos-p0-manifest-") as d:
            root = Path(d)
            inventory = root / "input.json"
            inventory.write_text(json.dumps(fixture()), encoding="utf-8")
            target = root / "output"
            self.assertEqual(0, M.main(["--build", "--inventory", str(inventory),
                                        "--output-dir", str(target)]))
            files = list(target.glob("*.json"))
            self.assertEqual(1, len(files))
            artifact = json.loads(files[0].read_text(encoding="utf-8"))
            self.assertIs(artifact["hash_is_not_a_signature"], True)
            self.assertEqual("NOT_QUALIFIED", artifact["manifest"]["evidence_status"])
            self.assertIs(artifact["manifest"]["takeover_admission_granted"], False)


if __name__ == "__main__":
    unittest.main()
