#!/usr/bin/env python3
"""Offline-only thermal shadow observer + source admission lock tests."""

import os
from pathlib import Path
import shutil
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SHADOW = ROOT / "switcher/assets/oneios_sm8850_thermal_shadow.sh"
SWITCH = ROOT / "switcher/assets/oneios_switch.sh"
BOOT = "123e4567-e89b-12d3-a456-426614174000"
GEN = BOOT + ".111.222"
LAUNCH = "a" * 32


def write(root, relative, value):
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(str(value) + "\n")
    return path


def fixture(root):
    write(root, "proc/sys/kernel/random/boot_id", BOOT)
    write(root, "proc/uptime", "100.00 1000.00")
    write(root, "sys/class/power_supply/battery/temp", 285)
    write(root, "sys/class/power_supply/battery/lrp", 303)
    write(root, "sys/class/sec/sec-ap-thermistor/temperature", 297)
    control = "data/adb/oneios-m3q-framework/control/"
    write(root, control + "watchdog.generation", GEN)
    write(root, control + "framework.launch", LAUNCH)
    write(root, control + "thermal.sim.watcher-alive", 1)


class ShadowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="oneos-thermal-shadow-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        fixture(self.root)

    def run_shadow(self):
        return subprocess.run(["sh", str(SHADOW), "--fixture-root", str(self.root),
                               BOOT, GEN, LAUNCH, "2"], capture_output=True,
                              text=True, timeout=7)

    def test_syntax(self):
        result = subprocess.run(["sh", "-n", str(SHADOW)], capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr)

    def test_two_bounded_reads_no_action(self):
        result = self.run_shadow()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(2, result.stdout.count("THERMAL_SHADOW=OBSERVED_NOT_GUARD"))
        self.assertIn("THERMAL_SHADOW=COMPLETE_UNQUALIFIED samples=2", result.stdout)
        self.assertNotIn("physical_action=YES", result.stdout)
        self.assertIn("lrp_deci_c=303", result.stdout)

    def test_missing_sensor_fails_closed(self):
        (self.root / "sys/class/power_supply/battery/lrp").unlink()
        result = self.run_shadow()
        self.assertEqual(4, result.returncode)
        self.assertIn("FAIL_CLOSED_NO_PHYSICAL_ACTION", result.stderr)
        self.assertNotIn("COMPLETE_UNQUALIFIED", result.stdout)

    def test_stale_generation_fails_closed(self):
        write(self.root, "data/adb/oneios-m3q-framework/control/watchdog.generation", "other")
        self.assertIn("stale_boot_run_or_watcher", self.run_shadow().stderr)

    def test_stale_launch_token_fails_closed(self):
        write(self.root, "data/adb/oneios-m3q-framework/control/framework.launch", "b" * 32)
        self.assertEqual(4, self.run_shadow().returncode)

    def test_watcher_dead_fails_closed(self):
        write(self.root, "data/adb/oneios-m3q-framework/control/thermal.sim.watcher-alive", 0)
        self.assertEqual(4, self.run_shadow().returncode)

    def test_boot_mismatch_fails_closed(self):
        write(self.root, "proc/sys/kernel/random/boot_id", "999e4567-e89b-12d3-a456-426614174000")
        self.assertEqual(4, self.run_shadow().returncode)

    def test_reader_path_missing_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            shadow = Path(tmp) / SHADOW.name
            shutil.copyfile(SHADOW, shadow)
            result = subprocess.run(["sh", str(shadow), "--fixture-root", str(self.root),
                                     BOOT, GEN, LAUNCH, "1"], capture_output=True,
                                    text=True, timeout=3)
            self.assertEqual(4, result.returncode)
            self.assertIn("reader_missing", result.stderr)

    def test_symlinked_sensor_fails_closed_before_read(self):
        path = self.root / "sys/class/power_supply/battery/lrp"
        path.unlink()
        path.symlink_to("/etc/passwd")
        result = self.run_shadow()
        self.assertEqual(4, result.returncode)
        self.assertIn("missing_or_linked_fixture", result.stderr)

    def test_reader_timeout_fails_closed_without_physical_action(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / "timeout"
            fake.write_text("#!/bin/sh\nexit 124\n")
            fake.chmod(0o755)
            env = dict(os.environ, PATH=str(tmp) + os.pathsep + os.environ["PATH"])
            result = subprocess.run(["sh", str(SHADOW), "--fixture-root", str(self.root),
                                     BOOT, GEN, LAUNCH, "1"], capture_output=True, text=True,
                                    timeout=3, env=env)
            self.assertEqual(4, result.returncode)
            self.assertIn("sensor_read_timeout_or_error", result.stderr)
            self.assertNotIn("physical_action=YES", result.stdout + result.stderr)

    def test_fixture_root_cannot_resolve_to_slash(self):
        result = subprocess.run(["sh", str(SHADOW), "--fixture-root", "/tmp/..",
                                 BOOT, GEN, LAUNCH, "1"], capture_output=True, text=True,
                                timeout=3)
        self.assertEqual(2, result.returncode)

    def test_duplicate_or_extra_reader_lines_fail_closed(self):
        correct = subprocess.run(["sh", str(ROOT / "switcher/assets/oneios_sm8850_thermal_reader.sh"),
                                  "--fixture-root", str(self.root)],
                                 capture_output=True, text=True, timeout=3)
        self.assertEqual(0, correct.returncode, correct.stderr)
        for suffix in ("battery_deci_c=285\n", "unknown_sensor=280\n"):
            with self.subTest(suffix=suffix), tempfile.TemporaryDirectory() as tmp:
                where = Path(tmp)
                shutil.copyfile(SHADOW, where / SHADOW.name)
                fake_reader = where / "oneios_sm8850_thermal_reader.sh"
                fake_reader.write_text("#!/bin/sh\nprintf %s " +
                                       shlex.quote(correct.stdout + suffix) + "\n")
                result = subprocess.run(["sh", str(where / SHADOW.name), "--fixture-root",
                                         str(self.root), BOOT, GEN, LAUNCH, "1"],
                                        capture_output=True, text=True, timeout=3)
                self.assertEqual(4, result.returncode)
                self.assertIn("invalid_reader_result", result.stderr)

    def test_no_unbounded_or_implicit_session_mode(self):
        for count in ("0", "11", "invalid"):
            result = subprocess.run(["sh", str(SHADOW), "--fixture-root", str(self.root),
                                     BOOT, GEN, LAUNCH, count], capture_output=True, text=True,
                                    timeout=3)
            self.assertEqual(2, result.returncode)
        self.assertEqual(2, subprocess.run(["sh", str(SHADOW)], capture_output=True).returncode)

    def test_no_reboot_or_stop_in_source(self):
        source = SHADOW.read_text()
        for fragment in ("/dev/watchdog", "sys.powerctl", "setprop ", "reboot ",
                         "return.request", "scaling_max_freq", "cpufreq/", "find /sys",
                         "kill -", "killall ", "stop zygote"):
            self.assertNotIn(fragment, source)


class SourceAdmissionGateTests(unittest.TestCase):
    def test_full_run_block_before_data_consumption_and_framework_stop(self):
        source = SWITCH.read_text()
        self.assertIn("P0_FULL_600S_TAKEOVER=BLOCKED_UNQUALIFIED_THERMAL_GUARD", source)
        gate = 'framework_block "P0_FULL_600S_TAKEOVER=BLOCKED_UNQUALIFIED_THERMAL_GUARD'
        self.assertIn(gate, source)
        self.assertLess(source.index(gate),
                        source.index('echo "APFS_DATA_CLONE=CONSUMED_ONE_SHOT_BEFORE_FRAMEWORK_STOP"'))
        self.assertLess(source.index(gate),
                        source.index('if ! stop_android_framework; then'))
        self.assertIn('if [ "$FRAMEWORK" = 1 ] && [ "$FW_MODE" = run ]; then\n'
                      '    # Source-level P0 admission lock.', source)
        # A genuine, time-limited guest experiment may be opt-in, but it must
        # not weaken the 600-second source refusal or omit its root monitor.
        self.assertIn("--framework-session:probe", source)
        self.assertIn("I_ACCEPT_SM8850_SHORT_TAKEOVER_90S_RISK", source)
        self.assertIn('fw_seconds=90', source)
        self.assertIn('framework_thermal_guard_healthy()', source)
        self.assertIn('P0_SHORT_PROBE_THERMAL=ARMED_ROOT_SENSOR_GUARD_NOT_PRODUCTION_CERTIFIED', source)
        self.assertIn('oneios_sm8850_thermal_takeover_guard.sh', source)
        thermal_guard = (ROOT / "switcher/assets/oneios_sm8850_thermal_takeover_guard.sh").read_text()
        # Physical 90s probe crossed an experimental cutoff after xnuhost
        # launched. Keep exact soft cutoffs and future fault provenance.
        for threshold in (
            '"$CPU_MAX" -lt 55000', '"$GPU_MAX" -lt 55000',
            '"$DDR_MAX" -lt 55000', '"$BAT" -lt 380',
            '"$LRP" -lt 420', '"$AP" -lt 420',
        ):
            self.assertIn(threshold, thermal_guard)
        self.assertIn('SOFT_FAULT_DETAIL="crossed=', thermal_guard)
        self.assertIn('CPU_MAX_ZONE=$typ@$idx', thermal_guard)
        self.assertIn('atom thermal.guard.fault "$BOOT $GEN $ $BIRTH $reason ${detail}"', thermal_guard)
        self.assertIn('if [ "$FRAMEWORK" = 1 ] && { [ "$FW_MODE" = run ] || [ "$FW_MODE" = probe ]; }; then', source)

    def test_check_only_continues_to_allow_passive_preflight(self):
        source = SWITCH.read_text()
        section = source[source.index('if [ "$MODE" = --check ] || [ "$MODE" = --framework-check ]; then'):]
        self.assertLess(section.index('echo "PREFLIGHT OK"'),
                        section.index('framework_block "P0_FULL_600S_TAKEOVER=BLOCKED'))
        self.assertIn('P0_RECOVERY=UNASSISTED_REBOOT_AND_WATCHDOG_NOT_CERTIFIED', section)

    def test_switch_syntax_unchanged(self):
        proc = subprocess.run(["sh", "-n", str(SWITCH)], capture_output=True, text=True, timeout=10)
        self.assertEqual(0, proc.returncode, proc.stderr)


if __name__ == "__main__":
    unittest.main()
