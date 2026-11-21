#!/usr/bin/env python3
"""Offline fixtures for host reboot witness; no device or reboot operations."""
import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

SOURCE=Path(__file__).resolve().parents[1]/"scripts/phone/sm8850-reboot-witness.py"
SPEC=importlib.util.spec_from_file_location("sm8850_reboot_witness",SOURCE)
M=importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)
BEFORE="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
AFTER="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
IDENT={"model":"SM-S948B","device":"m3q","firmware":"S948BXXS4BZIG",
       "boot_completed":"1","selinux":"Enforcing","system_server":"112","boot_id":BEFORE}
NEXT={**IDENT,"boot_id":AFTER,"system_server":"222"}
EVENTS=[{"status":"INITIAL_NORMAL_ONEUI","t_seconds":0},
        {"status":"OFFLINE","t_seconds":4},
        {"status":"NEW_BOOT_NORMAL_ONEUI","t_seconds":42}]
CORRELATION={"recorded_previous_boot_id":BEFORE,
             "old_and_current_boot_different":True,
             "recorded_outcome_consistent_with_reboot_return":True,
             "current_zygote":"running","normal_oneui_currently_observed":True}


class WitnessTest(unittest.TestCase):
    def test_default_audit_zero_adb(self):
        with patch.object(M.MAPPER,"serial_for",side_effect=AssertionError("ADB call")):
            self.assertEqual(0,M.main([]))

    def test_new_boot_and_marker_correlation_never_certifies_recovery(self):
        report=M.evaluate(BEFORE,AFTER,EVENTS,CORRELATION)
        self.assertTrue(report["historical_return_record_correlated_to_pre_smoke_boot"])
        self.assertTrue(report["new_normal_oneui_boot_observed"])
        self.assertFalse(report["unassisted_return_proven"])
        self.assertFalse(report["full_600s_takeover_allowed"])
        self.assertFalse(report["p0_complete"])
        self.assertFalse(report["absence_of_physical_key_use_proven"])

    def test_missing_offline_transition_refused(self):
        with self.assertRaises(M.Refused):
            M.evaluate(BEFORE,AFTER,[EVENTS[0],EVENTS[2]],CORRELATION)

    def test_missing_normal_boot_confirmation_refused(self):
        with self.assertRaises(M.Refused):
            M.evaluate(BEFORE,AFTER,EVENTS[:2],CORRELATION)

    def test_same_boot_never_counted_as_recovery(self):
        with self.assertRaises(M.Refused):
            M.evaluate(BEFORE,BEFORE,EVENTS,CORRELATION)

    def test_old_or_missing_markers_are_only_uncorrelated(self):
        for provenance in (None,{}, {**CORRELATION,"recorded_previous_boot_id":AFTER},
                           {**CORRELATION,"recorded_outcome_consistent_with_reboot_return":False}):
            with self.subTest(provenance=provenance):
                report=M.evaluate(BEFORE,AFTER,EVENTS,provenance)
                self.assertFalse(report["historical_return_record_correlated_to_pre_smoke_boot"])
                self.assertFalse(report["recovery_certified"])

    def test_bounded_observe_uses_reconnected_new_boot(self):
        now=[0]
        seq=iter([("ONLINE",BEFORE),("OFFLINE",None),("ONLINE",AFTER)])
        identities=iter([IDENT,NEXT])
        def clock(): return now[0]
        def sleep(seconds): now[0]+=seconds
        report=M.observe("adb","SERIAL",max_seconds=30,clock=clock,sleep=sleep,
                         probe_func=lambda *args:next(seq),
                         identity=lambda *args:next(identities),
                         inspector=lambda *args:CORRELATION)
        self.assertEqual(AFTER,report["after_boot_id"])
        self.assertTrue(report["historical_return_record_correlated_to_pre_smoke_boot"])
        self.assertEqual(1,len([x for x in report["witness_events"] if x["status"]=="OFFLINE"]))
        self.assertFalse(report["observer_issued_reboot"])

    def test_no_new_boot_with_transient_usb_loss_is_failure(self):
        now=[0]
        def clock(): return now[0]
        def sleep(seconds): now[0]+=seconds
        seq=iter([("OFFLINE",None)]+[("ONLINE",BEFORE)]*20)
        with self.assertRaisesRegex(M.Refused,"no new healthy One UI"):
            M.observe("adb","SERIAL",max_seconds=30,clock=clock,sleep=sleep,
                      probe_func=lambda *args:next(seq),
                      identity=lambda *args:IDENT, inspector=lambda *args:CORRELATION)

    def test_inconsistent_postboot_identity_refused(self):
        now=[0]
        seq=iter([("OFFLINE",None),("ONLINE",AFTER)])
        identity=iter([IDENT,{**NEXT,"boot_id":BEFORE}])
        with self.assertRaisesRegex(M.Refused,"boot identity inconsistent"):
            M.observe("adb","SERIAL",max_seconds=30,clock=lambda:now[0],
                      sleep=lambda s:now.__setitem__(0,now[0]+s),
                      probe_func=lambda *args:next(seq),
                      identity=lambda *args:next(identity),
                      inspector=lambda *args:CORRELATION)

    def test_observer_never_initiates_return_or_watchdog(self):
        source=SOURCE.read_text()
        for dangerous in ("sys.powerctl","reboot -f","/dev/watchdog",
                          "oneios_return.sh","--framework-session","setprop "):
            self.assertNotIn(dangerous,source)
        self.assertIn("AUDIT_NO_ADB_NO_REBOOT",source)


if __name__=="__main__":
    unittest.main()
