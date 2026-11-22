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

    def test_live_boot_baseline_starts_strict_at_40_percent(self):
        # Production uses previous level=2 at its FIRST post-stop sample,
        # even if the temperature is initially only 39 C. It must never
        # write the CPU minimum or bypass the independent emergency guard.
        source = CAP.read_text()
        self.assertIn('level=2\n        seq=0', source)
        self.assertIn('P0_CPU_CAP=BOOT_STRICT_BASELINE_REQUESTED pct=40', source)
        self.assertLess(
            source.index('if framework_down_for_cpu_cap; then'),
            source.index('P0_CPU_CAP=BOOT_STRICT_BASELINE_REQUESTED pct=40'),
        )
        self.assertEqual("2:40", policy(39000, prev=2).stdout.strip())
        for temp, level in ((55000, "2:40"),
                            (65000, "3:28"),
                            (72000, "4:18"),
                            (77000, "5:12"),
                            (80000, "6:8"),
                            (89999, "6:8")):
            with self.subTest(temp=temp):
                p = policy(temp, prev=2)
                self.assertEqual(0, p.returncode, p.stderr)
                self.assertEqual(level, p.stdout.strip())
        self.assertEqual(2, policy(90000, prev=2).returncode)

    def test_emergency_remains_distinct(self):
        self.assertEqual(2, policy(90000).returncode)
        self.assertNotEqual(0, policy(0).returncode)
        self.assertEqual("6:8", policy(39000, prev=6).stdout.strip())

    def test_experimental_policy_keeps_throttling_without_software_temp_abort(self):
        # The default mode still returns 2 at 90 C. The separately opted-in
        # mode requests 8% rather than a userspace reboot for the same input.
        for temp, expected in ((39000, "3:28"), (80000, "6:8"),
                               (90000, "6:8"), (101100, "6:8")):
            with self.subTest(temp=temp):
                p = subprocess.run([
                    "sh", str(CAP), "--policy-floor", "3", str(temp),
                    *map(str, NORMAL[1:])
                ], capture_output=True, text=True, timeout=6)
                self.assertEqual(0, p.returncode, p.stderr)
                self.assertEqual(expected, p.stdout.strip())
        self.assertEqual(2, policy(90000).returncode)

    def test_no_userspace_guard_or_cap_abort_only_on_explicit_180s(self):
        switch = SWITCH.read_text()
        cap = CAP.read_text()
        self.assertIn('I_ACCEPT_SOFT_GUARD_OFF_180S', switch)
        self.assertIn('[ "$FW_DURATION" = 180 ]', switch)
        self.assertIn('SM8850_SOFT_THERMAL_GUARD=OFF_NOT_SPAWNED', switch)
        self.assertIn('THERMAL_GUARD=OFF_NO_PROCESS_NO_HEARTBEAT_NO_SOFT_RETURN', switch)
        self.assertIn('CPU_THROTTLE=POST_STOP_BEST_EFFORT_28_PERCENT_NO_FATAL_CAP_ERROR', switch)
        self.assertIn('sm8850_no_userspace_thermal() {', switch)
        self.assertIn('! sm8850_no_userspace_thermal', switch)
        self.assertIn("printf 'disabled-180s\\n'", switch)
        self.assertIn('--run-best-effort "$CTL" "$WD_GEN"', switch)
        self.assertIn('P0_CPU_CAP=BEST_EFFORT_APPLY_FAILED_NO_RETURN', cap)
        self.assertIn('apply_cap "" 28 lenient', cap)
        # A new fixed-frequency helper has NO thermal guard heartbeat.
        helper = cap.split('    --run-best-effort)', 1)[1].split(
            '    --run|--run-prearmed|--run-prearmed-floor)', 1)[0]
        self.assertNotIn('thermal.guard.heartbeat', helper)
        self.assertNotIn('thermal.cap.fault', helper)
        self.assertNotIn('fault ', helper)
        self.assertIn('framework_down_for_cpu_cap', helper)
        self.assertNotIn('> "$pol/scaling_min_freq"', cap)
        # The protected mode must still exist and remain strict.
        self.assertIn('apply_cap "" "$pct" strict', cap)
        self.assertIn('framework_thermal_guard_healthy', switch)
        self.assertIn('framework_thermal_cap_healthy', switch)

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
        self.assertIn('framework_down_for_cpu_cap() {', cap)
        # The default prearm and the experimental floor-aware prearm
        # share the same live worker; assert the combined case-arm.
        self.assertIn('--run|--run-prearmed|--run-prearmed-floor)', cap)
        self.assertIn(
            'if [ "$MODE" = --run-prearmed ] || [ "$MODE" = --run-prearmed-floor ]; then',
            cap,
        )
        self.assertIn('atom thermal.cap.prearmed "v1 $BOOT $GEN $$ $BIRTH"', cap)
        self.assertIn('if framework_down_for_cpu_cap; then', cap)
        self.assertIn('P0_CPU_CAP=PREARMED_READ_ONLY', cap)
        self.assertIn('P0_CPU_CAP=FRAMEWORK_DOWN_VERIFIED_START_STRICT', cap)
        self.assertLess(
            cap.index('if framework_down_for_cpu_cap; then'),
            cap.index('apply_cap "" "$pct" strict'),
        )
        self.assertIn('fault "unachievable_cpu_cap_floor level=$desired pct=$pct"', cap)
        self.assertIn('P0_CPU_CAP=UNENFORCEABLE_MIN_VOTE', cap)

    def test_bounded_duration_and_affinity(self):
        s = SWITCH.read_text()
        self.assertIn('FW_DURATION=600', s)
        self.assertIn('FW_DURATION=${6:-600}', s)
        self.assertIn('"$FW_DURATION" -ge 60', s)
        self.assertIn('"$FW_DURATION" -le 600', s)
        self.assertIn('fw_seconds=$FW_DURATION', s)
        self.assertIn('--set bridges=1 --set sm8850-full-bridges=1 --set touch-sleep=0 --set cpu-affinity-bench=0 --set cpu-pin=1', s)
        self.assertIn('framework_thermal_guard_healthy()', s)
        self.assertIn('framework_thermal_cap_healthy()', s)
        self.assertIn('"$CTL/thermal.guard.required"', s)
        self.assertIn('"$CTL/thermal.cap.required"', s)
        self.assertIn('--run "$CTL" "$STAGE/thermal.guard.manifest" "$WD_GEN"', s)
        self.assertIn('--run-prearmed "$CTL" "$WD_GEN"', s)
        self.assertNotIn('--run "$CTL" "$WD_GEN"', s)
        self.assertIn('framework_thermal_cap_prearmed()', s)
        self.assertIn('thermal.cap.prearm.required', s)
        self.assertIn('CPU_THROTTLE=PREARMED_ACTIVATED_POST_STOP_STRICT', s)
        self.assertLess(
            s.index('CPU_THROTTLE=PREARMED_READ_ONLY_NO_SYSFS_WRITES_BEFORE_FRAMEWORK_STOP'),
            s.index('if ! stop_android_framework; then'),
        )
        self.assertLess(
            s.index('if ! stop_android_framework; then'),
            s.index('CPU_THROTTLE=PREARMED_ACTIVATED_POST_STOP_STRICT'),
        )
        self.assertIn('ONEIOS_GPU_3D_MODE=REQUIRED_FAIL_CLOSED_NO_2D_FALLBACK', s)

    def test_archived_smoke_remains_valid_after_manual_android_reboot(self):
        source = SWITCH.read_text()
        gate = source.split("sm8850_old_smoke_valid() {", 1)[1].split(
            'SM8850_PREVIOUS_REBOOT_SMOKE=VERIFIED_DEADLINE_REQUEST_ONLY', 1
        )[0]
        # Preserve rooted, original-boot smoke provenance checks and the
        # mandatory presence of a verified historical session.
        self.assertIn('root_only "$sr_ctl" && root_only "$sr_outcome_path"', gate)
        self.assertIn('[ "${sr_marker%%.*}" = "$sr_boot" ]', gate)
        self.assertIn('[ "$(cat "$sr_ctl/framework.mode" 2>/dev/null)" = smoke ]', gate)
        self.assertIn('sm8850_old_smoke_valid "$sr_archive/control" "$sr_archive/return.outcome"', gate)
        self.assertIn('[ -n "$smoke_proof" ] ||', gate)
        # A manual reboot can report "reboot". It is not evidence about
        # the historical smoke run and cannot invalidate it.
        self.assertNotIn(
            '[ "$(getprop ro.boot.bootreason)" = reboot,oneios-sm8850-reboot-return ]',
            gate,
        )
        self.assertIn(
            'SM8850_CURRENT_BOOT_REASON=INFORMATIONAL_ONLY:',
            source,
        )

    def test_full_hardware_bridges_enable_explicitly_and_require_matching_runtime(self):
        source = SWITCH.read_text()
        # Explicitly activate the REAL bridges=1 profile, not the prior
        # brightness-only surrogate. The generic CPU topology, battery and
        # thermal host bridges now execute along with display/TSP control.
        self.assertIn(
            '--set bridges=1 --set sm8850-full-bridges=1 --set touch-sleep=0',
            source,
        )
        self.assertIn('--set cpu-affinity-bench=0 --set cpu-pin=1', source)
        self.assertNotIn('--set bridges=0 --set panel-bridge=1', source)
        self.assertIn('ONEIOS_CPU_PLACEMENT_BRIDGE=ACTIVE_BRIDGES_1_CPU_PIN_1', source)
        self.assertIn('SM8850_FULL_BRIDGES=ACTIVE', source)
        self.assertIn('staged xnuhost lacks full bridges=1 Framework profile', source)
        # If the native artifact is stale, fail before the one-shot Data
        # consumption, the Framework stop and any root bridge mutation.
        self.assertLess(
            source.index("grep -Fq 'SM8850_FULL_BRIDGES=ACTIVE'"),
            source.index('APFS_DATA_CLONE=CONSUMED_ONE_SHOT_BEFORE_FRAMEWORK_STOP'),
        )
        self.assertLess(
            source.index("grep -Fq 'SM8850_FULL_BRIDGES=ACTIVE'"),
            source.index('if ! stop_android_framework; then'),
        )

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

    def test_cpu_cap_framework_down_gate_synthetic(self):
        # Execute the REAL gate on a fake control directory. No phone,
        # no root privileges, and no cpufreq writes.
        source = CAP.read_text()
        begin = source.index('framework_down_for_cpu_cap() {')
        end = source.index('\n}', begin) + 2
        func = source[begin:end]
        script = textwrap.dedent("""\
            #!/bin/sh
            CTL="$TEST_ROOT/control"
            getprop() {
                case "$1" in
                    init.svc.zygote) printf '%s\\n' "$TEST_ZYGOTE" ;;
                    init.svc.zygote_next) printf '%s\\n' "$TEST_ZYGOTE_NEXT" ;;
                    init.svc.zygote_secondary) printf '%s\\n' "$TEST_ZYGOTE_SECONDARY" ;;
                    *) return 2 ;;
                esac
            }
            pidof() {
                [ "$1" = system_server ] && [ "$TEST_SYSTEM_SERVER" = 1 ]
            }
            __GATE__
            if framework_down_for_cpu_cap; then
                echo CPU_CAP_STOP_GATE=PASS
            else
                echo CPU_CAP_STOP_GATE=BLOCKED
            fi
            """).replace("__GATE__", func)
        cases = (
            ("0", "stopped", "stopped", "stopped", "0", "BLOCKED"),
            ("1", "running", "stopped", "stopped", "0", "BLOCKED"),
            ("1", "stopped", "running", "stopped", "0", "BLOCKED"),
            ("1", "stopped", "stopped", "running", "0", "BLOCKED"),
            ("1", "stopped", "stopped", "stopped", "1", "BLOCKED"),
            ("1", "stopped", "stopped", "stopped", "0", "PASS"),
            ("1", "stopped", "stopped", "", "0", "PASS"),
        )
        for marker, zygote, znext, secondary, server, result in cases:
            with self.subTest(marker=marker, zygote=zygote, server=server), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                ctl = root / "control"
                ctl.mkdir()
                if marker == "1":
                    (ctl / "stopped").write_text("test marker\n")
                env = {**os.environ, "TEST_ROOT": str(root),
                       "TEST_ZYGOTE": zygote, "TEST_ZYGOTE_NEXT": znext,
                       "TEST_ZYGOTE_SECONDARY": secondary,
                       "TEST_SYSTEM_SERVER": server}
                res = subprocess.run(["sh", "-c", script], env=env,
                                     capture_output=True, text=True, timeout=5)
                self.assertEqual(0, res.returncode, (res.stdout, res.stderr))
                self.assertIn(f"CPU_CAP_STOP_GATE={result}", res.stdout)

    def test_thermal_arms_before_framework_stop(self):
        s = SWITCH.read_text()
        self.assertLess(
            s.index('THERMAL_GUARD=ARMED_ROOT'),
            s.index('=== [3/5]'),
        )
        self.assertIn('independent thermal monitor/cap missing, stale', s)
        self.assertIn('root thermal sensor manifest not qualified on current boot', s)
        self.assertLess(s.index('=== [3/5]'), s.index('CPU_THROTTLE=PREARMED_ACTIVATED_POST_STOP_STRICT'))


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
                if pct == 60:
                    # The actual samples reported min=max on both clusters.
                    (self.policies["policy0"] / "scaling_max_freq").write_text(str(floor0))
                    (self.policies["policy6"] / "scaling_max_freq").write_text(str(floor6))
                old = {n: self.read(n) for n in self.policies}
                p = self.apply_strict(pct)
                self.assertNotEqual(0, p.returncode)
                self.assertIn("P0_CPU_CAP=UNENFORCEABLE_MIN_VOTE", p.stdout)
                self.assertIn("P0_CPU_CAP=BLOCKED fixture_policy_failed", p.stderr)
                self.assertEqual(old, {n: self.read(n) for n in self.policies})

    def test_strict_only_rejects_an_actual_ceiling_conflict(self):
        # At 60%, 2.112 GHz is below the requested limit on both
        # clusters; the cap is still enforceable at this temperature.
        (self.policies["policy0"] / "scaling_min_freq").write_text("2112000")
        (self.policies["policy6"] / "scaling_min_freq").write_text("2112000")
        p = self.apply_strict(60)
        self.assertEqual(0, p.returncode, (p.stdout, p.stderr))
        self.assertEqual(2160000, self.read("policy0"))
        self.assertEqual(2200000, self.read("policy6"))

    def test_strict_allows_real_throttling_after_minimum_vote_releases(self):
        (self.policies["policy0"] / "scaling_min_freq").write_text("384000")
        (self.policies["policy6"] / "scaling_min_freq").write_text("768000")
        p = self.apply_strict(40)
        self.assertEqual(0, p.returncode, (p.stdout, p.stderr))
        self.assertEqual(1440000, self.read("policy0"))
        self.assertEqual(1896960, self.read("policy6"))
        self.assertIn("FIXTURE_APPLIED pct=40 strict=strict", p.stdout)

    def test_experimental_floor_aware_underclock_keeps_vendor_vote(self):
        (self.policies["policy0"] / "scaling_min_freq").write_text("2112000")
        (self.policies["policy6"] / "scaling_min_freq").write_text("2112000")
        p = subprocess.run(["sh", str(CAP), "--fixture-floor-step",
                            str(self.root), "28"],
                           capture_output=True, text=True, timeout=7)
        self.assertEqual(0, p.returncode, (p.stdout, p.stderr))
        self.assertEqual(2112000, self.read("policy0"))
        self.assertEqual(2112000, self.read("policy6"))
        self.assertIn("MIN_FLOOR_LIMITED policy=policy0", p.stdout)
        self.assertIn("MIN_FLOOR_LIMITED policy=policy6", p.stdout)
        # Later Samsung release permits a genuinely lower effective ceiling.
        (self.policies["policy0"] / "scaling_min_freq").write_text("384000")
        (self.policies["policy6"] / "scaling_min_freq").write_text("768000")
        p = subprocess.run(["sh", str(CAP), "--fixture-floor-step",
                            str(self.root), "28"],
                           capture_output=True, text=True, timeout=7)
        self.assertEqual(0, p.returncode, (p.stdout, p.stderr))
        self.assertEqual(1008000, self.read("policy0"))
        self.assertEqual(1327872, self.read("policy6"))

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
