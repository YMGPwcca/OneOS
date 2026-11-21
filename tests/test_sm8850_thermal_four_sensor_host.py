#!/usr/bin/env python3
"""Offline mock tests for opt-in, dynamically mapped 4-node One UI probe."""

import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / "scripts/phone/sm8850-four-sensor-oneui.py"
SPEC = importlib.util.spec_from_file_location("sm8850_four_sensor_oneui", SOURCE)
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)
BOOT = "123e4567-e89b-12d3-a456-426614174000"
PATH = "/sys/class/thermal/thermal_zone16/temp"
IDENTITY = {
    "model": "SM-S948B", "device": "m3q", "firmware": "S948BXXS4BZIG",
    "boot_completed": "1", "selinux": "Enforcing",
    "system_server": "222", "boot_id": BOOT
}


def output(**changes):
    fields = {
        "THERMAL_PINNED": "FOUR_SENSOR_READ_ONLY_NOT_GUARD",
        "source": "--live-oneui-readonly", "boot_id": BOOT,
        "cpu_zone_type": "cpu-0-5-1", "cpu_zone_path": PATH,
        "cpu_milli_c": "29600", "cpu_deci_c": "296",
        "battery_deci_c": "266", "lrp_deci_c": "285",
        "board_ap_deci_c": "270", "uptime_start": "100.0",
        "uptime_end": "100.1", "after_framework_available": "NOT_VERIFIED",
    }
    fields.update(changes)
    return "\n".join(f"{k}={v}" for k, v in fields.items())


class FourSensorOneUITests(unittest.TestCase):
    def test_no_adb_on_audit(self):
        with patch.object(M.MAPPER, "serial_for", side_effect=AssertionError("no ADB")):
            self.assertEqual(0, M.main([]))

    def test_valid_four_sensor_output_units(self):
        values = M.parse_sample(output(), BOOT, PATH)
        self.assertEqual(29600, values["cpu_milli_c"])
        self.assertEqual((266,285,270),
                         tuple(values[key] for key in ("battery_deci_c","lrp_deci_c","board_ap_deci_c")))

    def test_field_smuggling_rejected(self):
        for bad in (output()+"\ncpu_milli_c=25000", output()+"\nmalicious=1",
                    output().replace("cpu_deci_c=296", "cpu_deci_c=295"),
                    output().replace("source=--live-oneui-readonly", "source=--fixture-root"),
                    output().replace("cpu_zone_type=cpu-0-5-1", "cpu_zone_type=cpu-hw-trip-1"),
                    output().replace("cpu_zone_path="+PATH, "cpu_zone_path=/dev/watchdog"),
                    output().replace("boot_id="+BOOT, "boot_id=wrong")):
            with self.subTest(text=bad[-50:]), self.assertRaises(M.Refused):
                M.parse_sample(bad, BOOT, PATH)

    def test_hot_real_cpu_above_120c_is_not_suppressed(self):
        sample = output(cpu_milli_c="130000", cpu_deci_c="1300")
        values = M.parse_sample(sample, BOOT, PATH)
        self.assertEqual(130000, values["cpu_milli_c"])
        self.assertEqual(1300, values["cpu_deci_c"])
    def test_bad_sensor_or_clock_rejected(self):
        for mutation in ({"battery_deci_c":"0"}, {"lrp_deci_c":"1201"},
                         {"board_ap_deci_c":"nan"}, {"cpu_milli_c":"-273000"},
                         {"cpu_milli_c":"160000"}, {"uptime_start":"NaN"},
                         {"uptime_end":"99.0"}, {"uptime_end":"104.0"}):
            with self.subTest(mutation=mutation), self.assertRaises(M.Refused):
                M.parse_sample(output(**mutation), BOOT, PATH)

    def test_unique_zone_is_validated_and_bounded(self):
        with patch.object(M.MAPPER, "identity", return_value=IDENTITY), \
             patch.object(M.MAPPER, "adb_call") as call:
            call.return_value = subprocess.CompletedProcess([], 0, "CANDIDATE="+PATH+"\n", "")
            before, index, path = M.identity_and_cpu_zone("adb","S")
        self.assertEqual(("16",PATH),(index,path))
        self.assertEqual(BOOT,before["boot_id"])
        self.assertEqual(1,call.call_count)

    def test_ambiguous_or_out_of_allowlist_zone_rejected(self):
        for data in ("CANDIDATE=/sys/class/thermal/thermal_zone16/temp\n"
                     "CANDIDATE=/sys/class/thermal/thermal_zone17/temp\n",
                     "CANDIDATE=/sys/class/thermal/thermal_zone300/temp\n"):
            with self.subTest(data=data), \
                 patch.object(M.MAPPER, "identity", return_value=IDENTITY), \
                 patch.object(M.MAPPER, "adb_call",
                     return_value=subprocess.CompletedProcess([],0,data,"")):
                with self.assertRaises((M.Refused,M.MAPPER.Blocked)):
                    M.identity_and_cpu_zone("adb","S")

    def simulate(self, *, sha_good=True, read_good=True, cleanup_good=True, identity_good=True):
        calls=[]
        sha="a"*64
        def fake(adb_path, serial, *args, timeout=10):
            calls.append(args)
            if args[:2]==("shell","sha256sum"):
                return (sha if sha_good else "b"*64)+"  "+args[-1]
            if len(args)>=3 and args[:2]==("shell","-T"):
                if not read_good:
                    raise M.Refused("mock root reader failure")
                return output()
            if args[:2]==("shell","rmdir") and not cleanup_good:
                raise M.Refused("mock rmdir failure")
            return ""
        with patch.object(M, "trusted_source", return_value=sha), \
             patch.object(M, "identity_and_cpu_zone", return_value=(IDENTITY,"16",PATH)), \
             patch.object(M.MAPPER, "identity", return_value=IDENTITY if identity_good else {"boot_id":"wrong"}), \
             patch.object(M, "adb", side_effect=fake), \
             patch.object(M.time, "sleep"):
            if all((sha_good,read_good,cleanup_good,identity_good)):
                result = M.collect("adb","S",Path("/test/reader.sh"))
                return calls,result
            with self.assertRaises(M.Refused):
                M.collect("adb","S",Path("/test/reader.sh"))
        return calls,None

    def test_complete_three_sample_flow_has_exact_cleanup(self):
        calls,result=self.simulate()
        self.assertEqual(3,len(result["samples"]))
        self.assertFalse(result["guard_active"])
        self.assertFalse(result["qualified_thermal_limits"])
        self.assertEqual(3,sum(args[:2]==("shell","-T") for args in calls))
        self.assertEqual(1,sum(args[:2]==("shell","sha256sum") for args in calls))
        self.assertEqual(1,sum(args[:2]==("shell","rmdir") for args in calls))
        self.assertFalse(any("reboot" in repr(args) or "sys.powerctl" in repr(args)
                             for args in calls))

    def test_hash_mismatch_refuses_and_cleans_up(self):
        calls,_=self.simulate(sha_good=False)
        self.assertEqual(1,sum(args[:2]==("shell","rmdir") for args in calls))
        self.assertFalse(any(args[:2]==("shell","-T") for args in calls))

    def test_reader_failure_refuses_and_cleans_up(self):
        calls,_=self.simulate(read_good=False)
        self.assertEqual(1,sum(args[:2]==("shell","rmdir") for args in calls))

    def test_cleanup_failure_is_not_pass(self):
        calls,_=self.simulate(cleanup_good=False)
        self.assertEqual(3,sum(args[:2]==("shell","-T") for args in calls))

    def test_end_identity_mismatch_refuses(self):
        calls,_=self.simulate(identity_good=False)
        self.assertEqual(1,sum(args[:2]==("shell","rmdir") for args in calls))

    def test_source_symlink_refused_before_device(self):
        with tempfile.TemporaryDirectory() as d:
            link=Path(d)/"reader.sh"
            link.symlink_to("/etc/passwd")
            with self.assertRaises(M.Refused):
                M.trusted_source(link)


if __name__=="__main__":
    unittest.main()
