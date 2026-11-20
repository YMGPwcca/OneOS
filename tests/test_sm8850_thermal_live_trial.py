#!/usr/bin/env python3
"""Offline test: independent sibling root thermal monitor + liveness supervisor.

Never contacts ADB or triggers any physical reboot. All fake sensor files
live under /tmp and all injected failures target only our own fake worker.
"""
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'switcher/assets/oneios_sm8850_thermal_trial.sh'
BOOT = 'a6007f1e-4fc3-4e99-82dd-267ccb249656'
GEN = 'shadow-' + 'a' * 16
LAUNCH = 'b' * 32
ZONES = [(16,'cpu-0-5-1','cpu',37000), (18,'cpuss-0','cpu',35000),
         (38,'gpuss-2','gpu',35100), (47,'ddr','ddr',35100)]

def put(root, name, value):
    p = root/name
    p.parent.mkdir(parents=True,exist_ok=True)
    p.write_text(str(value)+'\n')
    return p

class LiveTrialTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='oneos-p0-live-fixture-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.sys = self.root / 'sysroot'
        self.stage = self.root / 'oneos-p0-live-stage'
        self.stage.mkdir()
        put(self.sys,'proc/sys/kernel/random/boot_id',BOOT)
        for idx,name,group,temp in ZONES:
            put(self.sys,f'sys/class/thermal/thermal_zone{idx}/type',name)
            put(self.sys,f'sys/class/thermal/thermal_zone{idx}/temp',temp)
        put(self.sys,'sys/class/power_supply/battery/temp',296)
        put(self.sys,'sys/class/power_supply/battery/lrp',315)
        put(self.sys,'sys/class/sec/sec-ap-thermistor/temperature',313)
        put(self.stage,'identity.v1',f'v1 {BOOT} {GEN} {LAUNCH}')
        put(self.stage,'manifest.v1','v1 '+BOOT+' '+str(len(ZONES))+'\n'+'\n'.join(
            f'z {idx} {name} {group}' for idx,name,group,temp in ZONES))

    def run_trial(self,fault='normal',ticks=3):
        return subprocess.run(['sh',str(SCRIPT),'--fixture-root',str(self.sys),str(self.stage),str(ticks),fault],
                              capture_output=True,text=True,timeout=22)

    def test_syntax(self):
        r=subprocess.run(['sh','-n',str(SCRIPT)],capture_output=True,text=True)
        self.assertEqual(0,r.returncode,r.stderr)

    def test_real_two_pid_siblings_and_3_snapshots(self):
        r=self.run_trial()
        self.assertEqual(0,r.returncode,r.stdout+r.stderr)
        self.assertIn('MONITOR=FINITE_SMOKE_DONE samples=3 physical_return=NO',r.stdout)
        self.assertIn('SUPERVISOR=MONITOR_COMPLETED_SEPARATE_PID',r.stdout)
        self.assertIn('THERMAL_TRIAL=PASS_OBSERVER_SUPERVISOR_ONLY_NO_PHYSICAL_RETURN',r.stdout)
        self.assertEqual(3,r.stdout.count('MONITOR=OBSERVED tick='))
        self.assertEqual('3', (self.stage/'monitor.heartbeat').read_text().split()[6])

    def test_worker_exit_is_independently_detected(self):
        r=self.run_trial('monitor-exit-after-two',ticks=4)
        self.assertEqual(0,r.returncode,r.stdout+r.stderr)
        self.assertIn('MONITOR=INJECTED_EXIT_NO_REBOOT',r.stdout)
        self.assertIn('SUPERVISOR=WOULD_REQUEST_RETURN_NOT_EXECUTED reason=monitor_dead',r.stdout)
        self.assertIn('EXPECTED_MONITOR_DEATH_DETECTED_NO_PHYSICAL_RETURN',r.stdout)

    def test_wrong_zone_type_refuses_sampling(self):
        put(self.sys,'sys/class/thermal/thermal_zone16/type','cpu-hw-trip-0')
        r=self.run_trial()
        self.assertNotEqual(0,r.returncode)
        self.assertIn('MONITOR=FAIL_CLOSED_SAMPLE',r.stdout)
        self.assertIn('SUPERVISOR=WOULD_REQUEST_RETURN_NOT_EXECUTED',r.stdout)
        self.assertNotIn('PASS_OBSERVER',r.stdout)

    def test_missing_ddr_refuses_sampling(self):
        (self.sys/'sys/class/thermal/thermal_zone47/temp').unlink()
        r=self.run_trial()
        self.assertNotEqual(0,r.returncode)
        self.assertIn('MONITOR=FAIL_CLOSED_SAMPLE',r.stdout)

    def test_missing_bat_refuses(self):
        put(self.sys,'sys/class/power_supply/battery/temp',0)
        r=self.run_trial()
        self.assertNotEqual(0,r.returncode)

    def test_wrong_boot_refuses_before_child_launch(self):
        put(self.sys,'proc/sys/kernel/random/boot_id','eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee')
        r=self.run_trial()
        self.assertEqual(4,r.returncode)
        self.assertIn('stale_boot',r.stderr)
        self.assertFalse((self.stage/'monitor.heartbeat').exists())

    def test_malicious_manifest_rejected(self):
        put(self.stage,'manifest.v1','v1 '+BOOT+' 1\nz 0 cpu-hw-trip-0 cpu')
        r=self.run_trial()
        self.assertNotEqual(0,r.returncode)

    def test_no_physical_actions_in_script(self):
        src="\n".join(line for line in SCRIPT.read_text().splitlines()
                      if not line.lstrip().startswith("#"))
        for x in ('sys.powerctl','/dev/watchdog','return.request','oneios_return.sh',
                  'cpufreq/scaling','stop zygote','setprop ', 'reboot ', 'rm -rf'):
            self.assertNotIn(x,src)

if __name__=='__main__':
    unittest.main()
