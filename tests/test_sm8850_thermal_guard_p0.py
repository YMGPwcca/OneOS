#!/usr/bin/env python3
"""Local, offline-only tests for independent SM8850 P0 groundwork."""

import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
READER = ROOT / "switcher/assets/oneios_sm8850_thermal_reader.sh"
POLICY = Path(__file__).with_name("sm8850_thermal_policy_sim.py")
SPEC = importlib.util.spec_from_file_location("thermal_guard_sim", POLICY)
S = importlib.util.module_from_spec(SPEC)
# dataclasses looks for the defining module in sys.modules.
import sys
sys.modules[SPEC.name] = S
SPEC.loader.exec_module(S)
BOOT = "123e4567-e89b-12d3-a456-426614174000"
GEN = "trusted-boot.1234.5678"


def limits():
    # SIMULATED ONLY. These are arbitrary fixtures, not S26 thresholds.
    return S.Limits(lrp_warn=400, lrp_critical=460,
                    battery_warn=420, battery_critical=480,
                    board_ap_warn=600, board_ap_critical=700,
                    hysteresis=20, warning_dwell_ms=1000,
                    max_sample_age_ms=2000)


def monitor():
    return S.Monitor(boot_id=BOOT, generation=GEN, limits=limits())


def sample(ms, **kwargs):
    data = dict(sampled_ms=ms, lrp=300, battery=280, board_ap=310)
    data.update(kwargs)
    return data


def update(m, ms, data=None, **kwargs):
    return m.update(now_ms=ms, sample=sample(ms) if data is None else data,
                    observed_boot_id=kwargs.pop("boot", BOOT),
                    observed_generation=kwargs.pop("gen", GEN),
                    watcher_alive=kwargs.pop("watcher", True))


class SensorReaderTest(unittest.TestCase):
    def fixture(self, folder, readings=(285, 303, 297)):
        root = Path(folder)
        for name, value in zip((
            "sys/class/power_supply/battery/temp",
            "sys/class/power_supply/battery/lrp",
            "sys/class/sec/sec-ap-thermistor/temperature",
        ), readings):
            dest = root / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text(str(value) + "\n")
        boot = root / "proc/sys/kernel/random/boot_id"
        boot.parent.mkdir(parents=True, exist_ok=True)
        boot.write_text(BOOT + "\n")
        up = root / "proc/uptime"
        up.parent.mkdir(parents=True, exist_ok=True)
        up.write_text("123.45 1234.56\n")

    def run_reader(self, root):
        return subprocess.run(["sh", str(READER), "--fixture-root", str(root)],
                              text=True, capture_output=True, timeout=5)

    def test_shell_parses_and_only_allowed_paths(self):
        result = subprocess.run(["sh", "-n", str(READER)], capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr)
        source = READER.read_text()
        for p in ("/sys/class/power_supply/battery/temp", "/sys/class/power_supply/battery/lrp",
                  "/sys/class/sec/sec-ap-thermistor/temperature"):
            self.assertIn(p, source)
        for forbidden in ("/dev/watchdog", "sys.powerctl", "setprop", "reboot ", "scaling_max_freq", "su -c", "find /sys"):
            self.assertNotIn(forbidden, source)

    def test_good_readings_and_units(self):
        with tempfile.TemporaryDirectory() as folder:
            self.fixture(folder)
            result = self.run_reader(folder)
            self.assertEqual(0, result.returncode, result.stderr)
            for line in ("THERMAL_READER=READ_ONLY_SNAPSHOT_NOT_GUARD", "battery_deci_c=285",
                         "lrp_deci_c=303", "board_ap_deci_c=297", "boot_id=" + BOOT):
                self.assertIn(line, result.stdout)

    def test_unavailable_is_not_safe_zero(self):
        with tempfile.TemporaryDirectory() as folder:
            self.fixture(folder)
            (Path(folder) / "sys/class/power_supply/battery/lrp").unlink()
            result = self.run_reader(folder)
            self.assertEqual(3, result.returncode)
            self.assertIn("UNKNOWN_LRP", result.stderr)
            self.assertNotIn("READ_ONLY_SNAPSHOT_NOT_GUARD", result.stdout)

    def test_zero_and_hardware_trip_are_not_accepted(self):
        for readings in ((285, 0, 297), (285, 303, 105000), ("invalid", 303, 297)):
            with self.subTest(readings=readings), tempfile.TemporaryDirectory() as folder:
                self.fixture(folder, readings)
                self.assertEqual(3, self.run_reader(folder).returncode)

    def test_no_implicit_live_mode_and_no_root_fixture(self):
        result = subprocess.run(["sh", str(READER)], capture_output=True, text=True)
        self.assertEqual(2, result.returncode)
        result = subprocess.run(["sh", str(READER), "--fixture-root", "/"], capture_output=True, text=True)
        self.assertEqual(2, result.returncode)


class PolicySimulationTest(unittest.TestCase):
    def test_nominal_and_warning_dwell(self):
        m = monitor()
        self.assertEqual(S.State.MONITORING, update(m, 0))
        self.assertEqual(S.State.MONITORING, update(m, 100, sample(100, lrp=401)))
        self.assertEqual(S.State.MONITORING, update(m, 1099, sample(1099, lrp=420)))
        self.assertEqual(S.State.WARNING, update(m, 1100, sample(1100, lrp=420)))

    def test_warning_recovers_after_hysteresis_and_dwell(self):
        m = monitor()
        update(m, 0, sample(0, lrp=410))
        update(m, 1000, sample(1000, lrp=410))
        self.assertEqual(S.State.WARNING, m.state)
        self.assertEqual(S.State.WARNING, update(m, 2000, sample(2000, lrp=385)))
        self.assertEqual(S.State.WARNING, update(m, 2100, sample(2100, lrp=370)))
        self.assertEqual(S.State.MONITORING, update(m, 3100, sample(3100, lrp=370)))

    def test_critical_is_immediate_and_latched(self):
        m = monitor()
        self.assertEqual(S.State.RETURN_REQUESTED, update(m, 1, sample(1, battery=480)))
        self.assertEqual("critical battery", m.reason)
        self.assertEqual(S.State.RETURN_REQUESTED, update(m, 2))

    def test_fail_closed_invalid_or_missing_sensor(self):
        for change in ({"lrp": 0}, {"battery": None}, {"board_ap": "321"}, {"lrp": -2730}):
            with self.subTest(change=change):
                m = monitor()
                self.assertEqual(S.State.FAIL_CLOSED, update(m, 100, sample(100, **change)))

    def test_fail_closed_stale_and_future_sample(self):
        for ms in (-1, 1000, 5000):
            with self.subTest(sample_ms=ms):
                m = monitor()
                self.assertEqual(S.State.FAIL_CLOSED, update(m, 4000, sample(ms)))

    def test_fail_closed_generation_and_boot_mismatch(self):
        for kwargs in ({"boot": "oldboot"}, {"gen": "oldgeneration"}):
            with self.subTest(kwargs=kwargs):
                self.assertEqual(S.State.FAIL_CLOSED, update(monitor(), 100, **kwargs))

    def test_fail_closed_lost_watcher(self):
        self.assertEqual(S.State.FAIL_CLOSED, update(monitor(), 100, watcher=False))

    def test_replayed_and_nonmonotonic_clock(self):
        m = monitor()
        update(m, 1000, sample(1000))
        self.assertEqual(S.State.FAIL_CLOSED, update(m, 1001, sample(999)))
        m = monitor()
        update(m, 1000, sample(1000))
        self.assertEqual(S.State.FAIL_CLOSED, update(m, 900, sample(900)))

    def test_invalid_policy_is_rejected(self):
        with self.assertRaises(ValueError):
            S.Limits(500, 400, 420, 480, 600, 700, 20, 1000, 2000)


if __name__ == "__main__":
    unittest.main()
