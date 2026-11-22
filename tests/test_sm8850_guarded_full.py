#!/usr/bin/env python3
"""Host-only safety contract for SM8850 GPU3D full-run throttle and duration.

No ADB, root, sysfs mutation, watchdog open or Framework stop.
"""
from pathlib import Path
import os
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]
ASSET = ROOT / "switcher/assets"
CAP = ASSET / "oneios_sm8850_thermal_cap.sh"
GUARD = ASSET / "oneios_sm8850_thermal_takeover_guard.sh"
SWITCH = ASSET / "oneios_switch.sh"

NORMAL = [39000, 39000, 40000, 285, 306, 340]


def policy(cpu, prev=0):
    sample = [cpu, *NORMAL[1:]]
    return subprocess.run(
        ["sh", str(CAP), "--policy", str(prev), *map(str, sample)],
        capture_output=True, text=True, timeout=6,
    )


class FullRunThermalContract(unittest.TestCase):
    def test_shell_syntax(self):
        for source in [CAP, GUARD, SWITCH]:
            with self.subTest(source=source):
                p = subprocess.run(["sh", "-n", str(source)], capture_output=True, text=True)
                self.assertEqual(0, p.returncode, p.stderr)

    def test_throttle_bands_and_80c_is_not_return(self):
        for temp, band in [(39000, "1:60"), (55000, "2:40"),
                           (65000, "3:28"), (72000, "4:18"),
                           (77000, "5:12"), (80000, "6:8"),
                           (89999, "6:8")]:
            with self.subTest(temp=temp):
                p = policy(temp)
                self.assertEqual(0, p.returncode, p.stderr)
                self.assertEqual(band, p.stdout.strip())

    def test_emergency_remains_distinct(self):
        self.assertEqual(2, policy(90000).returncode)
        self.assertNotEqual(0, policy(0).returncode)
        self.assertEqual("6:8", policy(39000, prev=6).stdout.strip())

    def test_root_guard_is_fullrun_only(self):
        guard = GUARD.read_text()
        cap = CAP.read_text()
        self.assertIn('[ "$(cat "$CTL/framework.mode" 2>/dev/null)" = run ]', guard)
        self.assertIn('[ "$(cat "$CTL/framework.mode" 2>/dev/null)" = run ]', cap)
        for token in ("cpu-hw-trip-*", '"$CPU_MAX" -lt 90000',
                      '"$GPU_MAX" -lt 95000', "thermal.guard.fault"):
            self.assertIn(token, guard)
        self.assertNotIn("setprop sys.powerctl", guard)
        self.assertIn('target=$mn', cap)
        self.assertIn('active_min=$(cat "$pol/scaling_min_freq"', cap)
        self.assertIn('target=$active_min', cap)
        self.assertIn('P0_CPU_CAP=MIN_FLOOR_LIMITED', cap)
        # Appended thermal-cap logs span multiple boots, so each floor-limited
        # line must now carry the exact owner boot and watcher generation.
        self.assertIn('boot=${BOOT:-fixture} generation=${GEN:-fixture}', cap)
        self.assertIn('if [ "$cur" -gt "$target" ]; then', cap)
        self.assertIn('"$got" -le "$target"', cap)
        self.assertNotIn('> "$pol/scaling_min_freq"', cap)
        self.assertIn('apply_cap "" "$pct" strict', cap)
        self.assertIn('fault "unachievable_cpu_cap_floor level=$desired pct=$pct"', cap)
        self.assertIn('P0_CPU_CAP=UNENFORCEABLE_MIN_VOTE', cap)

    def test_bounded_duration_and_affinity(self):
        s = SWITCH.read_text()
        self.assertIn('FW_DURATION=600', s)
        self.assertIn('FW_DURATION=${6:-600}', s)
        self.assertIn('"$FW_DURATION" -ge 60', s)
        self.assertIn('"$FW_DURATION" -le 600', s)
        self.assertIn('fw_seconds=$FW_DURATION', s)
        self.assertIn('--set bridges=0 --set cpu-affinity-bench=1 --set cpu-pin=1', s)
        self.assertIn('framework_thermal_guard_healthy()', s)
        self.assertIn('framework_thermal_cap_healthy()', s)
        self.assertIn('"$CTL/thermal.guard.required"', s)
        self.assertIn('"$CTL/thermal.cap.required"', s)
        self.assertIn('--run "$CTL" "$STAGE/thermal.guard.manifest" "$WD_GEN"', s)
        self.assertIn('--run "$CTL" "$WD_GEN"', s)
        self.assertIn('ONEIOS_GPU_3D_MODE=REQUIRED_FAIL_CLOSED_NO_2D_FALLBACK', s)

    def test_wake_boost_settles_before_framework_cutoff(self):
        source = SWITCH.read_text()
        wake = source.index('# SM8850: the Android KEYCODE_WAKEUP request')
        cutoff = source.index('printf \'%s\\n\' "$((fw_start + 45))" > "$CTL/framework.cutoff"')
        stop = source.index('if ! stop_android_framework; then')
        self.assertLess(wake, cutoff)
        self.assertLess(cutoff, stop)
        self.assertEqual(1, source.count('input keyevent KEYCODE_WAKEUP'))
        self.assertIn('CPU_MIN_COOLDOWN=THREE_HEALTHY_SAMPLES', source)
        self.assertIn('switch-panel-wake-refused', source)
        self.assertIn('[ "$wake_stable" -ge 3 ]', source)
        self.assertIn('[ "$wake_elapsed" -ge 8 ]', source)
        self.assertIn('[ "$wake_elapsed" -lt 20 ]', source)

    def test_wake_boost_cooldown_synthetic_without_phone_access(self):
        source = SWITCH.read_text()
        marker = '# SM8850: the Android KEYCODE_WAKEUP request'
        stop = 'if [ "$FRAMEWORK" = 1 ] && [ -z "$armed" ]; then\n    if fw_start='
        self.assertEqual(1, source.count(marker))
        self.assertEqual(1, source.count(stop))
        fragment = marker + source.split(marker, 1)[1].split(stop, 1)[0]
        fragment = fragment.replace(
            '/sys/devices/system/cpu/cpufreq/policy0',
            '$TEST_ROOT/policy0',
        ).replace(
            '/sys/devices/system/cpu/cpufreq/policy6',
            '$TEST_ROOT/policy6',
        )
        # There are no shell calls to the phone: all sysfs is fake and all
        # Android commands (wake, pidof, getprop, sleep) are stubbed.
        fixture = textwrap.dedent("""\
            #!/bin/sh
            set -eu
            FRAMEWORK=1 FW_MODE=run armed=
            SESSION="$TEST_ROOT/session"
            mkdir -p "$SESSION"
            watchdog_uint() {
                case "$1" in ''|*[!0-9]*) return 1;; esac
                return 0
            }
            framework_thermal_guard_healthy() {
                th_cpu="${TEST_HOT_CPU:-40000}"
                th_gpu=40000 th_ddr=40000
                return 0
            }
            getprop() { printf 'running\\n'; }
            pidof() { [ "$1" = system_server ]; }
            timeout() {
                [ "$1" = 5 ] && [ "$2" = input ] &&
                    [ "$3" = keyevent ] && [ "$4" = KEYCODE_WAKEUP ] || return 1
                printf '1228800\\n' > "$TEST_ROOT/policy0/scaling_min_freq"
                printf '883200\\n' > "$TEST_ROOT/policy6/scaling_min_freq"
            }
            sleep() {
                n=$(cat "$TEST_ROOT/count")
                n=$((n + 1))
                echo "$n" > "$TEST_ROOT/count"
                if [ "${TEST_NEVER_RELEASE:-0}" = 0 ] && [ "$n" -ge 6 ]; then
                    printf '384000\\n' > "$TEST_ROOT/policy0/scaling_min_freq"
                    printf '768000\\n' > "$TEST_ROOT/policy6/scaling_min_freq"
                fi
            }
            __FRAGMENT__
            echo "MOCK_ARMED=$armed"
            """).replace("__FRAGMENT__", fragment)
        for never_release, hot_cpu, expected in (
            ("0", "40000", "CPU_MIN_COOLDOWN=THREE_HEALTHY_SAMPLES"),
            ("1", "40000", "BLOCKED_BEFORE_FRAMEWORK_STOP"),
            ("0", "65000", "BLOCKED_BEFORE_FRAMEWORK_STOP"),
        ):
            with self.subTest(never_release=never_release, hot_cpu=hot_cpu), tempfile.TemporaryDirectory() as td:
                root = Path(td)
                for policy, floor in (("policy0", 384000), ("policy6", 768000)):
                    p = root / policy
                    p.mkdir()
                    for name in ("cpuinfo_min_freq", "scaling_min_freq"):
                        (p / name).write_text(str(floor) + "\n")
                (root / "count").write_text("0\n")
                for shell in ("sh",):
                    proc = subprocess.run([shell, "-c", fixture],
                        env={**os.environ, "TEST_ROOT": str(root),
                             "TEST_NEVER_RELEASE": never_release, "TEST_HOT_CPU": hot_cpu},
                        capture_output=True, text=True, timeout=10)
                    self.assertEqual(0, proc.returncode, (proc.stdout, proc.stderr))
                    self.assertIn(expected, proc.stdout)
                    if never_release == "0" and hot_cpu == "40000":
                        self.assertIn("MOCK_ARMED=\n", proc.stdout)
                    else:
                        self.assertIn("MOCK_ARMED=switch-panel-wake-refused", proc.stdout)

    def test_thermal_arms_before_framework_stop(self):
        s = SWITCH.read_text()
        self.assertLess(
            s.index('THERMAL_GUARD=ARMED_ROOT'),
            s.index('=== [3/5]'),
        )
        self.assertIn('independent thermal monitor/cap missing, stale', s)
        self.assertIn('root thermal sensor manifest not qualified on current boot', s)
        self.assertLess(s.index('=== [3/5]'), s.index('CPU_THROTTLE=ARMED_POST_STOP'))


@unittest.skipIf(os.geteuid() == 0, "root may not use the fixture write mode")
class SyntheticCpufreqTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="oneios-cpu-cap-test.", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.policies = {}
        for name, max_hz, min_hz, current in (
            ("policy0", 3600000, 384000, 3600000),
            ("policy6", 4742400, 768000, 2200000),
        ):
            folder = self.root / "sys/devices/system/cpu/cpufreq" / name
            folder.mkdir(parents=True)
            (folder / "cpuinfo_max_freq").write_text(str(max_hz))
            (folder / "cpuinfo_min_freq").write_text(str(min_hz))
            (folder / "scaling_min_freq").write_text(str(min_hz))
            (folder / "scaling_max_freq").write_text(str(current))
            self.policies[name] = folder

    def apply(self, pct):
        return subprocess.run(["sh", str(CAP), "--fixture-step",
                               str(self.root), str(pct)],
                              capture_output=True, text=True, timeout=7)

    def read(self, name):
        return int((self.policies[name] / "scaling_max_freq").read_text())

    def apply_strict(self, pct):
        return subprocess.run(["sh", str(CAP), "--fixture-strict-step",
                               str(self.root), str(pct)],
                              capture_output=True, text=True, timeout=7)

    def test_monotonic_never_raise_and_minimum_floor(self):
        for percentage in (60, 40, 28, 18, 12, 8, 60):
            with self.subTest(pct=percentage):
                p = self.apply(percentage)
                self.assertEqual(0, p.returncode, p.stderr)
        self.assertEqual(384000, self.read("policy0"))
        self.assertEqual(768000, self.read("policy6"))

    def test_external_tighter_vote_is_not_lifted(self):
        p = self.apply(60)
        self.assertEqual(0, p.returncode, p.stderr)
        self.assertEqual(2160000, self.read("policy0"))
        self.assertEqual(2200000, self.read("policy6"))

    def test_dynamic_samsung_scaling_min_floor_and_recovery(self):
        # On the actual SM-S948B, policy0 scaling_min varied from 384000
        # to 1228800 kHz while the vendor max stayed at 2112000 kHz.
        (self.policies["policy0"] / "scaling_min_freq").write_text("1228800")
        (self.policies["policy6"] / "scaling_min_freq").write_text("2112000")
        p = self.apply(8)
        self.assertEqual(0, p.returncode, p.stderr)
        self.assertEqual(1228800, self.read("policy0"))
        self.assertEqual(2112000, self.read("policy6"))
        self.assertIn("MIN_FLOOR_LIMITED policy=policy0", p.stdout)
        self.assertIn("MIN_FLOOR_LIMITED policy=policy6", p.stdout)
        # When Samsung lowers its minimum vote, a subsequent cap tick can
        # throttle further without ever writing to scaling_min_freq itself.
        (self.policies["policy0"] / "scaling_min_freq").write_text("384000")
        (self.policies["policy6"] / "scaling_min_freq").write_text("768000")
        p = self.apply(8)
        self.assertEqual(0, p.returncode, p.stderr)
        self.assertEqual(384000, self.read("policy0"))
        self.assertEqual(768000, self.read("policy6"))

    def test_strict_rejects_dangerous_samsung_votes_before_any_cap_write(self):
        # Read-only phone sample 19 and sample 23 (not a synthetic guess):
        # Samsung raised both minimums to 2.112 GHz, then briefly fixed
        # the entire policy range near 3.4 / 3.76 GHz on One UI.
        for floor0, floor6, pct in (
            (2112000, 2112000, 40),
            (3398400, 3763200, 60),
        ):
            with self.subTest(floor0=floor0, floor6=floor6, pct=pct):
                (self.policies["policy0"] / "scaling_min_freq").write_text(str(floor0))
                (self.policies["policy6"] / "scaling_min_freq").write_text(str(floor6))
                old = {n: self.read(n) for n in self.policies}
                p = self.apply_strict(pct)
                self.assertNotEqual(0, p.returncode)
                self.assertIn("P0_CPU_CAP=UNENFORCEABLE_MIN_VOTE", p.stdout)
                self.assertIn("P0_CPU_CAP=BLOCKED fixture_policy_failed", p.stderr)
                self.assertEqual(old, {n: self.read(n) for n in self.policies})

    def test_strict_allows_real_throttling_after_minimum_vote_releases(self):
        (self.policies["policy0"] / "scaling_min_freq").write_text("384000")
        (self.policies["policy6"] / "scaling_min_freq").write_text("768000")
        p = self.apply_strict(40)
        self.assertEqual(0, p.returncode, (p.stdout, p.stderr))
        self.assertEqual(1440000, self.read("policy0"))
        self.assertEqual(1896960, self.read("policy6"))
        self.assertIn("FIXTURE_APPLIED pct=40 strict=strict", p.stdout)

    def test_invalid_or_missing_active_scaling_min_is_rejected(self):
        scaling_min = self.policies["policy0"] / "scaling_min_freq"
        scaling_min.unlink()
        self.assertNotEqual(0, self.apply(8).returncode)
        scaling_min.write_text("9999999")
        self.assertNotEqual(0, self.apply(8).returncode)
        scaling_min.write_text("100000")
        self.assertNotEqual(0, self.apply(8).returncode)

    def test_invalid_policy_and_live_root_are_blocked(self):
        self.assertNotEqual(0, subprocess.run(
            ["sh", str(CAP), "--fixture-step", "/sys", "60"],
            capture_output=True, text=True, timeout=7).returncode)
        (self.policies["policy6"] / "cpuinfo_min_freq").unlink()
        self.assertNotEqual(0, self.apply(60).returncode)


if __name__ == "__main__":
    unittest.main()
