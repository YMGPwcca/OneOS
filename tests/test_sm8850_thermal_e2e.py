#!/usr/bin/env python3
"""Offline E2E tests that use the REAL shell sensor reader and fake files."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("sm8850_e2e", HERE / "sm8850_thermal_e2e_dryrun.py")
E = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = E
SPEC.loader.exec_module(E)
BOOT = "123e4567-e89b-12d3-a456-426614174000"
GEN = "123e4567-e89b-12d3-a456-426614174000.111.222"
LAUNCH = "e" * 32


def limits():
    # This is made-up test data, not an SM8850 thermal policy.
    return E.POLICY.Limits(400, 460, 420, 480, 600, 700, 20, 1000, 2000)


def put(base, name, value):
    f = base / name
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(str(value) + "\n")
    return f


def fixture(base):
    put(base, "proc/sys/kernel/random/boot_id", BOOT)
    put(base, "proc/uptime", "100.00 900.00")
    put(base, "sys/class/power_supply/battery/temp", 285)
    put(base, "sys/class/power_supply/battery/lrp", 303)
    put(base, "sys/class/sec/sec-ap-thermistor/temperature", 297)
    put(base, f"{E.CONTROL}/watchdog.generation", GEN)
    put(base, f"{E.CONTROL}/framework.launch", LAUNCH)
    put(base, f"{E.CONTROL}/thermal.sim.watcher-alive", 1)


def engine(root, **kwargs):
    return E.Engine(root, boot_id=BOOT, generation=GEN, launch_token=LAUNCH,
                    limits=limits(), **kwargs)


class ThermalEndToEnd(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="sm8850-p0-e2e-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        fixture(self.root)

    def test_genuine_shell_reader_yields_nominal_observation(self):
        e = engine(self.root)
        first = e.step(100)
        self.assertEqual("MONITORING", first["state"])
        self.assertEqual({"lrp": 303, "battery": 285, "board_ap": 297}, first["sensor_deci_c"])
        self.assertFalse(first["physical_return_issued"])
        self.assertFalse(first["live_thermal_guard"])
        self.assertEqual("NONE", first["action"])

    def test_reader_warning_dwell_and_hysteresis_are_end_to_end(self):
        put(self.root, "sys/class/power_supply/battery/lrp", 410)
        e = engine(self.root)
        self.assertEqual("MONITORING", e.step(0)["state"])
        self.assertEqual("MONITORING", e.step(999)["state"])
        self.assertEqual("WARNING", e.step(1000)["state"])
        put(self.root, "sys/class/power_supply/battery/lrp", 379)
        self.assertEqual("WARNING", e.step(1001)["state"])
        self.assertEqual("MONITORING", e.step(2001)["state"])

    def test_critical_issues_only_simulated_single_action(self):
        put(self.root, "sys/class/power_supply/battery/temp", 480)
        e = engine(self.root)
        first = e.step(0)
        self.assertEqual("RETURN_REQUESTED", first["state"])
        self.assertEqual("WOULD_REQUEST_RETURN_NOT_EXECUTED", first["action"])
        next_ = e.step(1000)
        self.assertEqual("RETURN_REQUESTED", next_["state"])
        self.assertEqual("NONE", next_["action"])

    def test_missing_kernel_node_after_initialization_fails_closed(self):
        e = engine(self.root)
        put(self.root, "sys/class/power_supply/battery/temp", 285).unlink()
        event = e.step(100)
        self.assertEqual("FAIL_CLOSED", event["state"])
        self.assertEqual("WOULD_REQUEST_RETURN_NOT_EXECUTED", event["action"])

    def test_zero_sensor_is_failure_not_cooled(self):
        e = engine(self.root)
        put(self.root, "sys/class/power_supply/battery/lrp", 0)
        self.assertEqual("FAIL_CLOSED", e.step(100)["state"])

    def test_malformed_sensor_is_failure(self):
        e = engine(self.root)
        put(self.root, "sys/class/sec/sec-ap-thermistor/temperature", "?broken")
        self.assertEqual("FAIL_CLOSED", e.step(100)["state"])

    def test_wrong_boot_id_fails_closed(self):
        e = engine(self.root)
        put(self.root, "proc/sys/kernel/random/boot_id", "f" * 32)
        self.assertEqual("FAIL_CLOSED", e.step(100)["state"])

    def test_wrong_watchdog_generation_fails_closed(self):
        e = engine(self.root)
        put(self.root, f"{E.CONTROL}/watchdog.generation", "previous.run")
        self.assertEqual("FAIL_CLOSED", e.step(100)["state"])

    def test_wrong_launch_token_fails_closed(self):
        e = engine(self.root)
        put(self.root, f"{E.CONTROL}/framework.launch", "a" * 32)
        self.assertEqual("FAIL_CLOSED", e.step(100)["state"])

    def test_synthetic_watcher_death_fails_closed(self):
        e = engine(self.root)
        put(self.root, f"{E.CONTROL}/thermal.sim.watcher-alive", 0)
        self.assertEqual("FAIL_CLOSED", e.step(100)["state"])

    def test_reader_timeout_fails_closed(self):
        def timed_out(*args, **kwargs):
            raise subprocess.TimeoutExpired(args[0], kwargs.get("timeout"))
        e = engine(self.root, runner=timed_out)
        event = e.step(100)
        self.assertEqual("FAIL_CLOSED", event["state"])
        self.assertFalse(event["physical_return_issued"])

    def test_duplicate_reader_key_fails_closed(self):
        correct = subprocess.run(
            ["sh", str(E.READER), "--fixture-root", str(self.root)],
            capture_output=True, text=True, timeout=1,
        )
        self.assertEqual(0, correct.returncode)
        mocked = Mock(return_value=subprocess.CompletedProcess([], 0, correct.stdout + "lrp_deci_c=001\n", ""))
        event = engine(self.root, runner=mocked).step(100)
        self.assertEqual("FAIL_CLOSED", event["state"])

    def test_reader_wrong_mode_fails_closed(self):
        good = subprocess.run(["sh", str(E.READER), "--fixture-root", str(self.root)],
                              capture_output=True, text=True, timeout=1)
        bad = good.stdout.replace("READ_ONLY_SNAPSHOT_NOT_GUARD", "READ_ONLY_SNAPSHOT_LIVE")
        fake = Mock(return_value=subprocess.CompletedProcess([], 0, bad, ""))
        self.assertEqual("FAIL_CLOSED", engine(self.root, runner=fake).step(100)["state"])

    def test_symlink_escape_rejected_before_any_reader_is_invoked(self):
        (self.root / "sys/class/power_supply/battery/lrp").unlink()
        (self.root / "sys/class/power_supply/battery/lrp").symlink_to("/etc/passwd")
        fake = Mock(side_effect=AssertionError("must not execute reader"))
        with self.assertRaises(E.FixtureError):
            engine(self.root, runner=fake)
        fake.assert_not_called()

    def test_missing_or_invalid_fixture_refused_without_live_fallback(self):
        with self.assertRaises(E.FixtureError):
            engine(Path("/"))
        (self.root / "sys/class/sec/sec-ap-thermistor/temperature").unlink()
        with self.assertRaises(E.FixtureError):
            engine(self.root)

    def test_resolved_root_cannot_be_slash(self):
        with self.assertRaises(E.FixtureError):
            engine(Path("/tmp/.."))

    def test_cli_fail_closed_result_is_nonzero_and_no_action(self):
        put(self.root, "sys/class/power_supply/battery/lrp", 0)
        proc = subprocess.run([
            sys.executable, str(HERE / "sm8850_thermal_e2e_dryrun.py"),
            "--fixture-root", str(self.root),
            "--boot-id", BOOT, "--generation", GEN, "--launch-token", LAUNCH,
        ], capture_output=True, text=True, timeout=5)
        self.assertEqual(4, proc.returncode, proc.stderr)
        event = json.loads(proc.stdout.splitlines()[0])
        self.assertEqual("FAIL_CLOSED", event["state"])
        self.assertFalse(event["physical_return_issued"])

    def test_reader_output_stale_uptime_or_negative_rejected(self):
        valid = subprocess.run(["sh", str(E.READER), "--fixture-root", str(self.root)],
                               capture_output=True, text=True, timeout=1)
        for old, new in (("uptime_end=100.00", "uptime_end=99.00"),
                         ("uptime_start=100.00", "uptime_start=NaN"),
                         ("uptime_end=100.00", "uptime_end=102.00")):
            with self.subTest(new=new), self.assertRaises(E.FixtureError):
                E.parse_reader(valid.stdout.replace(old, new), BOOT, max_elapsed_ms=1000)

    def test_cli_is_explicit_fixture_only_and_json_contains_no_physical_action(self):
        proc = subprocess.run([
            sys.executable, str(HERE / "sm8850_thermal_e2e_dryrun.py"),
            "--fixture-root", str(self.root),
            "--boot-id", BOOT, "--generation", GEN, "--launch-token", LAUNCH,
            "--ticks", "2", "--step-ms", "1000",
        ], capture_output=True, text=True, timeout=5)
        self.assertEqual(0, proc.returncode, proc.stderr)
        events = [json.loads(line) for line in proc.stdout.splitlines()]
        self.assertEqual(2, len(events))
        self.assertTrue(all(event["kind"] == "SM8850_P0_OFFLINE_FIXTURE_SIMULATION_ONLY" for event in events))
        self.assertTrue(all(event["physical_return_issued"] is False for event in events))
        self.assertTrue(all(event["live_thermal_guard"] is False for event in events))


if __name__ == "__main__":
    unittest.main()
