#!/usr/bin/env python3
"""Fixture-only tests of SM8850 thermal heartbeat / supervisor liveness.

No real Android /proc, physical device, reboot or watchdog interaction.
"""

from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parents[1]
HEALTH = HERE / "switcher/assets/oneios_sm8850_thermal_health.sh"
BOOT = "123e4567-e89b-12d3-a456-426614174000"
GEN = BOOT + ".123.456"
TOKEN = "a" * 32
PID = "2345"
BIRTH = "987654"


def put(root, relative, data):
    file = root / relative
    file.parent.mkdir(parents=True, exist_ok=True)
    file.write_text(str(data) + "\n", encoding="utf-8")
    return file


def fixture(root, *, boot=BOOT, gen=GEN, token=TOKEN, pid=PID,
            birth=BIRTH, seq=1, sample_ms=1000, status="OK"):
    ctl = "data/adb/oneios-m3q-framework/control/"
    put(root, "proc/sys/kernel/random/boot_id", boot)
    put(root, ctl + "watchdog.generation", gen)
    put(root, ctl + "framework.launch", token)
    put(root, ctl + "thermal.monitor", f"{pid} {birth}")
    put(root, ctl + "thermal.heartbeat",
        f"v1 {boot} {gen} {token} {pid} {birth} {seq} {sample_ms} {status}")
    # The process identity helper after ')' treats the 20th token as starttime.
    # 1 x state + 18 filler + 1 x birth + 1 filler.
    put(root, f"proc/{pid}/stat", f"{pid} (thermal monitor) S " +
        " ".join(["0"] * 18 + [str(birth), "0"]))


class ThermalHealthTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="oneos-thermal-health-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        fixture(self.root)

    def run_check(self, *, now="2000", ttl="3000"):
        return subprocess.run([
            "sh", str(HEALTH), "--fixture-root", str(self.root),
            BOOT, GEN, TOKEN, now, ttl,
        ], capture_output=True, text=True, timeout=3)

    def test_shell_syntax_and_inert_scope(self):
        r = subprocess.run(["sh", "-n", str(HEALTH)], capture_output=True, text=True)
        self.assertEqual(0, r.returncode, r.stderr)
        source = HEALTH.read_text()
        for token in ("sys.powerctl", "/dev/watchdog", "reboot -f",
                      "return.request", "setprop ", "kill -9", "scaling_max_freq"):
            self.assertNotIn(token, source)

    def test_healthy_matching_boot_generation_launch_and_birth(self):
        r = self.run_check()
        self.assertEqual(0, r.returncode, r.stderr)
        self.assertIn("THERMAL_HEALTH=FRESH_FIXTURE_ONLY", r.stdout)
        self.assertIn("seq=1", r.stdout)
        self.assertIn("age_ms=1000", r.stdout)
        self.assertIn("physical_action=NO", r.stdout)

    def test_stale_heartbeat_rejected(self):
        r = self.run_check(now="5000", ttl="3000")
        self.assertEqual(4, r.returncode)
        self.assertIn("stale_heartbeat", r.stderr)

    def test_future_heartbeat_rejected(self):
        r = self.run_check(now="999", ttl="3000")
        self.assertEqual(4, r.returncode)
        self.assertIn("future_or_invalid_sample", r.stderr)

    def test_wrong_boot_rejected(self):
        put(self.root, "proc/sys/kernel/random/boot_id",
            "223e4567-e89b-12d3-a456-426614174000")
        self.assertIn("boot_mismatch", self.run_check().stderr)

    def test_wrong_generation_rejected(self):
        put(self.root, "data/adb/oneios-m3q-framework/control/watchdog.generation",
            "previous-run")
        self.assertIn("generation_mismatch", self.run_check().stderr)

    def test_wrong_launch_token_rejected(self):
        put(self.root, "data/adb/oneios-m3q-framework/control/framework.launch",
            "b" * 32)
        self.assertIn("launch_mismatch", self.run_check().stderr)

    def test_heartbeat_claims_wrong_boot_or_run(self):
        fixture(self.root, boot="223e4567-e89b-12d3-a456-426614174000")
        # Reestablish outer binding, retain a heartbeat claiming the wrong boot.
        put(self.root, "proc/sys/kernel/random/boot_id", BOOT)
        self.assertIn("heartbeat_identity_mismatch", self.run_check().stderr)

    def test_monitor_pid_reused(self):
        put(self.root, f"proc/{PID}/stat", f"{PID} (thermal monitor) S " +
            " ".join(["0"] * 18 + ["987655", "0"]))
        self.assertIn("monitor_pid_reused_or_zombie", self.run_check().stderr)

    def test_monitor_exit_missing_proc_stat(self):
        (self.root / f"proc/{PID}/stat").unlink()
        self.assertIn("monitor_dead", self.run_check().stderr)

    def test_zombie_monitor_rejected(self):
        put(self.root, f"proc/{PID}/stat", f"{PID} (thermal monitor) Z " +
            " ".join(["0"] * 18 + [BIRTH, "0"]))
        self.assertIn("monitor_pid_reused_or_zombie", self.run_check().stderr)

    def test_malformed_or_multiline_heartbeat_rejected(self):
        hb = "data/adb/oneios-m3q-framework/control/thermal.heartbeat"
        with (self.root / hb).open("a", encoding="utf-8") as fp:
            fp.write("v1 forged entry\n")
        self.assertIn("heartbeat_multiline", self.run_check().stderr)

    def test_monitor_status_not_ok_rejected(self):
        fixture(self.root, status="ERROR")
        self.assertIn("invalid_heartbeat_schema", self.run_check().stderr)

    def test_missing_heartbeat_rejected(self):
        (self.root / "data/adb/oneios-m3q-framework/control/thermal.heartbeat").unlink()
        self.assertEqual(4, self.run_check().returncode)

    def test_symlink_escape_rejected(self):
        hb = self.root / "data/adb/oneios-m3q-framework/control/thermal.heartbeat"
        hb.unlink()
        hb.symlink_to("/etc/passwd")
        r = self.run_check()
        self.assertEqual(4, r.returncode)
        self.assertIn("missing_or_untrusted_file", r.stderr)

    def test_invalid_times_and_ttl_refused(self):
        for now, ttl in (("-1", "3000"), ("abc", "3000"), ("2000", "0"),
                         ("2000", "30001"), ("99999999999999", "3000")):
            with self.subTest(now=now, ttl=ttl):
                self.assertEqual(2, self.run_check(now=now, ttl=ttl).returncode)

    def test_no_live_mode_no_implicit_root(self):
        self.assertEqual(2, subprocess.run(["sh", str(HEALTH)],
                                         capture_output=True, timeout=3).returncode)
        self.assertEqual(2, subprocess.run(["sh", str(HEALTH), "--live"],
                                         capture_output=True, timeout=3).returncode)


if __name__ == "__main__":
    unittest.main()
