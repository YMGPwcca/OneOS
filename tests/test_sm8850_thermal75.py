#!/usr/bin/env python3
"""Offline tests of the actual OneOS shell cap policy; no root or sysfs."""
import pathlib
import subprocess
import unittest
import tempfile
import os
import shutil

ROOT = pathlib.Path(__file__).resolve().parents[1]
CAP = ROOT / "switcher/assets/oneios_sm8850_thermal_cap.sh"
GUARD = ROOT / "switcher/assets/oneios_sm8850_thermal_takeover_guard.sh"

class Thermal75(unittest.TestCase):
    def policy(self, cpu, previous=2, gpu=30000, ddr=30000, bat=300, lrp=300, ap=300):
        result = subprocess.run(["bash", str(CAP), "--policy", *map(str, (previous,cpu,gpu,ddr,bat,lrp,ap))],
                                capture_output=True, text=True, check=False)
        return result.returncode, result.stdout.strip()

    def test_cpu_breakpoints_no_temperature_return_at_75(self):
        for cpu, expected in [(30000,"2:40"),(64999,"2:40"),(65000,"3:28"),
                              (69999,"3:28"),(70000,"4:18"),(74999,"4:18"),
                              (75000,"5:12"),(75001,"5:12"),(79999,"5:12"),
                              (80000,"6:8"),(89999,"6:8")]:
            with self.subTest(cpu=cpu):
                self.assertEqual((0, expected), self.policy(cpu))

    def test_no_reboost_or_weaken_other_sensors(self):
        self.assertEqual((0,"5:12"), self.policy(60000, previous=5))
        self.assertEqual((0,"6:8"), self.policy(30000, gpu=85000))
        self.assertEqual((0,"6:8"), self.policy(30000, bat=440))
        self.assertEqual(2, self.policy(90000)[0])
        self.assertEqual(2, self.policy(30000, gpu=95000)[0])
        self.assertEqual(2, self.policy(30000, bat=480)[0])
        self.assertEqual(3, self.policy(-1)[0])
        self.assertEqual(3, self.policy(75000, previous=7)[0])

    def test_safety_contract_and_syntax(self):
        for path in (CAP, GUARD):
            subprocess.run(["bash","-n",str(path)], check=True)
        cap = CAP.read_text()
        guard = GUARD.read_text()
        self.assertIn("TARGET_30_70_THROTTLE_BY_75_MONOTONIC", cap)
        self.assertIn('[ "$CPU_MAX" -lt 90000 ]', guard)
        self.assertIn('apply_cap "" "$pct" strict', cap)
        self.assertIn('[ "$prev" -le "$level" ] || level=$prev', cap)
        self.assertIn('[ "$cur" -gt "$target" ]', cap)
        self.assertNotIn('> "$pol/scaling_min_freq"', cap)


class FastThermalReader(unittest.TestCase):
    """Execute the real reader against a disposable tree; no real sysfs or ADB."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.boot = "fixture-boot"
        self.man = self.root / "manifest"
        self.man.write_text("v1 fixture-boot 3\nz 1 cpu-0 cpu\nz 2 gpuss-0 gpu\nz 3 ddr ddr\n")
        for idx, typ, temp in ((1,"cpu-0","41000"),(2,"gpuss-0","39000"),(3,"ddr","40000")):
            self.put(f"sys/class/thermal/thermal_zone{idx}/type", typ)
            self.put(f"sys/class/thermal/thermal_zone{idx}/temp", temp)
        self.put("sys/class/power_supply/battery/temp", "296")
        self.put("sys/class/power_supply/battery/lrp", "321")
        self.put("sys/class/sec/sec-ap-thermistor/temperature", "339")
        self.put("proc/sys/kernel/random/boot_id", self.boot)

    def put(self, name, value):
        p = self.root / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(value + "\n")

    def run_reader(self):
        source = GUARD.read_text()
        body = source.split("is_uint() {", 1)[1].split("\natom() {", 1)[0]
        body = "is_uint() {" + body
        body = body.replace("/sys/class/", "${FIXTURE}/sys/class/").replace(
            "/proc/sys/kernel/random/boot_id", "${FIXTURE}/proc/sys/kernel/random/boot_id")
        # No hot-path subprocess or fallback to real sysfs.
        body = 'set -u\ncat() { echo UNEXPECTED_CAT >&2; exit 99; }\n' + body + r'''
read_all fixture-boot "$FIXTURE/manifest"
rc=$?
if [ "$rc" = 0 ]; then
    printf '%s:%s:%s:%s:%s:%s\n' "$CPU_MAX" "$GPU_MAX" "$DDR_MAX" "$BAT" "$LRP" "$AP"
fi
exit "$rc"
'''
        shells = ["/bin/sh", shutil.which("bash")]
        mksh = os.environ.get("ONEOS_TEST_MKSH") or shutil.which("mksh")
        if mksh:
            shells.append(mksh)
        return [subprocess.run([shell, "-c", body], env=dict(os.environ, FIXTURE=str(self.root)),
                               capture_output=True, text=True, timeout=5) for shell in dict.fromkeys(filter(None, shells))]

    def expect(self, rc, output=None):
        for p in self.run_reader():
            self.assertEqual(rc, p.returncode, (p.args, p.stdout, p.stderr))
            self.assertNotIn("UNEXPECTED_CAT", p.stderr)
            if output is not None:
                self.assertEqual(output, p.stdout.strip())

    def test_valid_complete_sample(self):
        self.expect(0, "41000:39000:40000:296:321:339")

    def test_invalid_and_multiline_sensor_rejected(self):
        for value in ("", "0", "garbage", "41000\n90000"):
            self.put("sys/class/thermal/thermal_zone1/temp", value)
            self.expect(1)

    def test_missing_sensor_or_identity_change_rejected(self):
        self.put("sys/class/thermal/thermal_zone1/type", "cpu-other")
        self.expect(1)
        self.put("sys/class/thermal/thermal_zone1/type", "cpu-0")
        (self.root / "sys/class/thermal/thermal_zone1/temp").unlink()
        self.expect(1)

    def test_emergency_threshold_unchanged(self):
        self.put("sys/class/thermal/thermal_zone1/temp", "90000")
        self.expect(2)

    def test_wrong_boot_or_duplicate_zone_rejected(self):
        self.put("proc/sys/kernel/random/boot_id", "wrong")
        self.expect(1)
        self.put("proc/sys/kernel/random/boot_id", self.boot)
        self.man.write_text("v1 fixture-boot 4\nz 1 cpu-0 cpu\nz 1 cpu-0 cpu\nz 2 gpuss-0 gpu\nz 3 ddr ddr\n")
        self.expect(1)

if __name__ == "__main__":
    unittest.main()
