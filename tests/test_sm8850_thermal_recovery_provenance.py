#!/usr/bin/env python3
"""Offline-only recovery-provenance tests. No real ADB or reboot."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

MODULE=Path(__file__).resolve().parents[1]/"scripts/phone/sm8850-recovery-provenance.py"
SPEC=importlib.util.spec_from_file_location("sm8850_recovery_provenance",MODULE)
M=importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)

BEFORE="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
NOW="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
DEVICE={
    "model":"SM-S948B","device":"m3q","firmware":"S948BXXS4BZIG",
    "boot_completed":"1","selinux":"Enforcing","system_server":"123","boot_id":NOW
}

def done(output="",status=0):
    return subprocess.CompletedProcess([],status,output,"")


class RecoveryProvenanceTest(unittest.TestCase):
    def test_audit_is_zero_adb_and_no_write(self):
        with patch.object(M.MAPPER,"serial_for",side_effect=AssertionError("NO ADB")):
            self.assertEqual(0,M.main([]))

    def test_no_untrusted_paths_are_read(self):
        with self.assertRaises(M.Blocked):
            M.safe_remote_read("adb","S","/data/adb/oneios-m3q-framework/../../dev/watchdog")

    def run_inspect(self,readings=None,*,zygote="running",boot_reason="reboot,oneios-sm8850-reboot-return",
                    identities=None):
        readings=readings if readings is not None else {
            "control_boot":BEFORE,"control_return_mode":"reboot",
            "current_outcome":"reboot-deadline-or-manual 100 who=framework-deadline reason=deadline",
            "session_return_request":"framework deadline reached",
            "control_generation":"token", "control_state":"returned",
        }
        def fake_call(adb,serial,args,timeout=6):
            if "zygote" in args:
                return done(zygote)
            return done(boot_reason)
        with patch.object(M.MAPPER,"identity",side_effect=identities or [DEVICE,DEVICE]), \
             patch.object(M.MAPPER,"adb_call",side_effect=fake_call):
            return M.inspect("adb","S",read=lambda adb,serial,name:readings.get(name))

    def test_older_boot_and_return_marker_are_only_correlation(self):
        result=self.run_inspect()
        self.assertTrue(result["old_and_current_boot_different"])
        self.assertTrue(result["recorded_outcome_consistent_with_reboot_return"])
        self.assertTrue(result["normal_oneui_currently_observed"])
        self.assertFalse(result["unassisted_return_proven"])
        self.assertFalse(result["recovery_certified"])
        self.assertFalse(result["full_takeover_allowed"])

    def test_same_boot_does_not_count_as_postboot(self):
        report=self.run_inspect({"control_boot":NOW,
             "control_return_mode":"reboot","current_outcome":"reboot-deadline who=framework-deadline"})
        self.assertFalse(report["old_and_current_boot_different"])
        self.assertFalse(report["recorded_outcome_consistent_with_reboot_return"])

    def test_absent_evidence_never_passes(self):
        report=self.run_inspect({})
        self.assertIsNone(report["recorded_previous_boot_id"])
        self.assertFalse(report["old_and_current_boot_different"])
        self.assertFalse(report["recorded_outcome_consistent_with_reboot_return"])
        self.assertFalse(report["recovery_certified"])

    def test_bad_outcome_or_mode_is_not_consistent(self):
        for changed in (
            {"control_return_mode":"inplace"},
            {"current_outcome":"inplace 100 a"},
            {"current_outcome":"reboot-manual 100 who=manual"},
        ):
            with self.subTest(changed=changed):
                rows={"control_boot":BEFORE,"control_return_mode":"reboot",
                      "current_outcome":"reboot-deadline who=framework-deadline"}
                rows.update(changed)
                self.assertFalse(self.run_inspect(rows)["recorded_outcome_consistent_with_reboot_return"])

    def test_zygote_stopped_refuses_postboot_claim(self):
        with self.assertRaises(M.Blocked):
            self.run_inspect(zygote="stopped")

    def test_boot_or_oneui_identity_change_refuses(self):
        with self.assertRaises(M.Blocked):
            self.run_inspect(identities=[DEVICE,{**DEVICE,"boot_id":BEFORE}])

    def test_no_implied_reboot_code_in_inspector(self):
        src=MODULE.read_text()
        for prohibited in ("sys.powerctl","reboot -f","/dev/watchdog","return.request' >",
                           "stop zygote","setprop "):
            self.assertNotIn(prohibited,src)

if __name__=="__main__":
    unittest.main()
