#!/usr/bin/env python3
"""Offline-only mock tests for staging a live One UI thermal process trial.

No ADB contact, guest start, Framework stop, thermal limit or reboot occurs.
"""
import importlib.util
import hashlib
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

SRC=Path(__file__).resolve().parents[1]/'scripts/phone/sm8850-live-thermal-trial.py'
SPEC=importlib.util.spec_from_file_location('sm8850_trial_host',SRC)
MOD=importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)
BOOT='a6007f1e-4fc3-4e99-82dd-267ccb249656'
IDENT={'boot_id':BOOT,'model':'SM-S948B','device':'m3q','firmware':'S948BXXS4BZIG','boot_completed':'1','selinux':'Enforcing','system_server':'222'}
VALID_MANIFEST={'device':{'boot_id':BOOT},
                'zones':[{'index':16,'type':'cpu-0-5-1','group':'cpu'},
                         {'index':38,'type':'gpuss-2','group':'gpu'},
                         {'index':47,'type':'ddr','group':'ddr'}]}

class HostTrialTest(unittest.TestCase):
    def test_default_audit_has_no_adb(self):
        with patch.object(MOD.INVENTORY.mapper,'serial_for',side_effect=AssertionError('no ADB')):
            self.assertEqual(0,MOD.main([]))

    def test_manifest_comes_from_current_boot(self):
        with patch.object(MOD.MANIFEST,'validate',return_value=VALID_MANIFEST):
            data, boot, zones=MOD.create_line_manifest({'any':'report'})
        self.assertEqual(BOOT,boot)
        self.assertEqual(3,zones)
        self.assertIn(b'z 38 gpuss-2 gpu',data)

    def test_scope_and_source_syntax(self):
        self.assertEqual(64,len(MOD.source_hash()))
        self.assertEqual(0,subprocess.run(['sh','-n',str(MOD.SHELL)]).returncode)

    def test_full_mock_adb_including_scenario_failure_detection(self):
        calls=[]
        def fake(adb,serial,*args,timeout=12):
            calls.append(args)
            if args[:2]==('shell','sha256sum'):
                path=args[2].rsplit('/',1)[-1]
                if path=='oneios_sm8850_thermal_trial.sh':
                    value=hashlib.sha256(MOD.SHELL.read_bytes()).hexdigest()
                elif path=='manifest.v1':
                    with patch.object(MOD.MANIFEST,'validate',return_value=VALID_MANIFEST):
                        value=hashlib.sha256(MOD.create_line_manifest({})[0]).hexdigest()
                else:
                    value=fake.identity_sha
                return value+'  '+args[2]
            if args and args[0]=='push':
                if args[-1].endswith('identity.v1'):
                    fake.identity_sha=hashlib.sha256(Path(args[1]).read_bytes()).hexdigest()
                return ''
            if args[:2]==('shell','-T') and 'monitor-exit-after-two' in args[-1]:
                return ('MONITOR=INJECTED_EXIT_NO_REBOOT\n'
                        'SUPERVISOR=WOULD_REQUEST_RETURN_NOT_EXECUTED reason=monitor_dead\n'
                        'THERMAL_TRIAL=EXPECTED_MONITOR_DEATH_DETECTED_NO_PHYSICAL_RETURN\n')
            if args[:2]==('shell','-T') and 'normal' in args[-1]:
                return ('MONITOR=FINITE_SMOKE_DONE samples=3 physical_return=NO\n'
                        'SUPERVISOR=MONITOR_COMPLETED_SEPARATE_PID physical_return=NO\n'
                        'THERMAL_TRIAL=PASS_OBSERVER_SUPERVISOR_ONLY_NO_PHYSICAL_RETURN\n')
            return ''
        with patch.object(MOD.INVENTORY.mapper,'identity',return_value=IDENT), \
             patch.object(MOD.INVENTORY,'collect',return_value={'hottest_by_group':{'cpu': {'celsius':37}}}), \
             patch.object(MOD.MANIFEST,'validate',return_value=VALID_MANIFEST), \
             patch.object(MOD,'invoke',side_effect=fake):
            result=MOD.run_trial('adb','MOCK')
        self.assertEqual(2,len(result['runs']))
        self.assertFalse(result['p0_complete'])
        self.assertFalse(result['physical_return_issued'])
        self.assertTrue(any(args[:2]==('shell','-T') and 'rmdir' in args[-1] for args in calls))

    def test_remote_clean_rejects_untrusted_stage(self):
        with self.assertRaises(MOD.Refused):
            MOD.remote_clean('adb','S','/data/adb/oneios-m3q-framework')

    def test_missing_hash_result_blocks_before_running(self):
        def fake(adb,serial,*args,timeout=12):
            if args[:2]==('shell','sha256sum'):
                return 'badbad  '+args[-1]
            return ''
        with patch.object(MOD.INVENTORY.mapper,'identity',return_value=IDENT), \
             patch.object(MOD.INVENTORY,'collect',return_value={'hottest_by_group':{}}), \
             patch.object(MOD.MANIFEST,'validate',return_value=VALID_MANIFEST), \
             patch.object(MOD,'invoke',side_effect=fake):
            with self.assertRaises(MOD.Refused):
                MOD.run_trial('adb','S')

if __name__=='__main__':
    unittest.main()
