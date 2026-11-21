#!/usr/bin/env python3
"""SM8850 thermal reader -> policy end-to-end HOST FIXTURE ONLY.

This is a deterministic integration harness. It does not monitor a phone,
install a service, write a return request, reboot, or implement a production
watchdog. Its time axis and watcher health are **synthetic**. Test thresholds
are NOT firmware thresholds. Requires an explicit fixture root and exact
boot / watchdog generation / launch token. Never pass physical device paths.
"""

import argparse
from decimal import Decimal, InvalidOperation
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys


HERE = Path(__file__).resolve().parent
READER = HERE.parent / "switcher/assets/oneios_sm8850_thermal_reader.sh"
SPEC = importlib.util.spec_from_file_location("sm8850_p0_thermal_policy", HERE / "sm8850_thermal_policy_sim.py")
POLICY = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = POLICY
SPEC.loader.exec_module(POLICY)

CONTROL = "data/adb/oneios-m3q-framework/control"
FIXTURE_FILES = (
    "proc/sys/kernel/random/boot_id", "proc/uptime",
    "sys/class/power_supply/battery/temp", "sys/class/power_supply/battery/lrp",
    "sys/class/sec/sec-ap-thermistor/temperature",
    f"{CONTROL}/watchdog.generation", f"{CONTROL}/framework.launch",
    f"{CONTROL}/thermal.sim.watcher-alive",
)
REQUIRED = frozenset({
    "THERMAL_READER", "source", "boot_id", "uptime_start", "uptime_end",
    "battery_deci_c", "lrp_deci_c", "board_ap_deci_c",
})
HEX_TOKEN = re.compile(r"[a-f0-9]{32}\Z")
GENERATION = re.compile(r"[a-zA-Z0-9._:-]{1,160}\Z")
BOOT = re.compile(r"[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\Z")


class FixtureError(ValueError):
    """An invalid or ambiguous fixture is never interpreted as safe."""


def read_exact(root, name):
    path = root / name
    if not path.is_file() or path.is_symlink():
        raise FixtureError("missing or linked fixture: " + name)
    return path.read_text(encoding="utf-8").strip()


def validate_fixture(root):
    """Prevent fixtures from resolving to real sysfs, proc or outside files."""
    root = Path(root)
    if str(root) == "/" or not root.is_dir() or root.is_symlink():
        raise FixtureError("fixture root must be a real directory other than /")
    base = root.resolve(strict=True)
    if base == Path("/"):
        raise FixtureError("fixture root cannot resolve to / or real host sysfs")
    for rel in FIXTURE_FILES:
        path = root / rel
        if not path.is_file():
            raise FixtureError("missing fixture: " + rel)
        try:
            path.resolve(strict=True).relative_to(base)
        except ValueError as exc:
            raise FixtureError("fixture escapes its own root: " + rel) from exc
        if path.is_symlink():
            raise FixtureError("symlink fixture prohibited: " + rel)
    return root


def parse_reader(stdout, expected_boot, *, max_elapsed_ms):
    """Strictly admit the specific one-shot reader's complete output."""
    parts = {}
    for line in stdout.splitlines():
        if "=" not in line:
            raise FixtureError("malformed output line")
        key, value = line.split("=", 1)
        if not re.fullmatch(r"[a-zA-Z0-9_]+", key) or key in parts:
            raise FixtureError("duplicate or malformed output key")
        parts[key] = value
    if parts.keys() != REQUIRED:
        raise FixtureError("reader output missing or unexpected keys")
    if parts["THERMAL_READER"] != "READ_ONLY_SNAPSHOT_NOT_GUARD" or parts["source"] != "--fixture-root":
        raise FixtureError("wrong reader mode")
    if parts["boot_id"] != expected_boot:
        raise FixtureError("reader boot ID changed")
    try:
        start, end = (Decimal(parts[name]) for name in ("uptime_start", "uptime_end"))
    except InvalidOperation as exc:
        raise FixtureError("invalid uptime in reader output") from exc
    if not start.is_finite() or not end.is_finite() or start < 0 or end < start:
        raise FixtureError("invalid read time interval")
    if (end - start) * 1000 > max_elapsed_ms:
        raise FixtureError("reader sample duration exceeded limit")
    data = {}
    for name in ("lrp", "battery", "board_ap"):
        val = parts[name + "_deci_c"]
        if not re.fullmatch(r"[1-9][0-9]{0,3}", val) or not 0 < int(val) <= 1200:
            raise FixtureError("invalid reader value: " + name)
        data[name] = int(val)
    return data


class Engine:
    """Offline E2E evaluator; emits descriptive events, no external actions."""

    def __init__(self, fixture_root, *, boot_id, generation, launch_token, limits,
                 reader_timeout_ms=1000, runner=subprocess.run):
        if not BOOT.fullmatch(boot_id):
            raise FixtureError("invalid expected boot ID")
        if not GENERATION.fullmatch(generation):
            raise FixtureError("invalid expected watchdog generation")
        if not HEX_TOKEN.fullmatch(launch_token):
            raise FixtureError("invalid expected launch token")
        if not 100 <= reader_timeout_ms <= 3000:
            raise FixtureError("reader timeout must be 100..3000 ms")
        self.root = validate_fixture(fixture_root)
        self.monitor = POLICY.Monitor(boot_id=boot_id, generation=generation, limits=limits)
        self.launch_token = launch_token
        self.reader_timeout_ms = reader_timeout_ms
        self.runner = runner
        self.action_emitted = False
        self.tick = 0

    def _identities(self):
        validate_fixture(self.root)
        boot = read_exact(self.root, "proc/sys/kernel/random/boot_id")
        gen = read_exact(self.root, f"{CONTROL}/watchdog.generation")
        launch = read_exact(self.root, f"{CONTROL}/framework.launch")
        watcher = read_exact(self.root, f"{CONTROL}/thermal.sim.watcher-alive")
        if boot != self.monitor.boot_id or gen != self.monitor.generation or launch != self.launch_token:
            raise FixtureError("boot, watchdog generation or launch token mismatch")
        if watcher != "1":
            raise FixtureError("synthetic watcher not alive")
        return boot, gen

    def step(self, now_ms):
        """One simulated monotonic tick. Terminal states stay latched."""
        self.tick += 1
        data = None
        if self.monitor.state not in (POLICY.State.FAIL_CLOSED, POLICY.State.RETURN_REQUESTED):
            try:
                pre_boot, pre_gen = self._identities()
                result = self.runner(
                    ["sh", str(READER), "--fixture-root", str(self.root)],
                    capture_output=True, text=True, timeout=self.reader_timeout_ms / 1000,
                    check=False,
                )
                if result.returncode:
                    raise FixtureError("sensor reader returned nonzero")
                data = parse_reader(result.stdout, pre_boot, max_elapsed_ms=self.reader_timeout_ms)
                post_boot, post_gen = self._identities()
                if (post_boot, post_gen) != (pre_boot, pre_gen):
                    raise FixtureError("boot or generation changed during reading")
                # This is a *synthetic* time from the host test, not a physical timestamp.
                data["sampled_ms"] = now_ms
                self.monitor.update(now_ms=now_ms, sample=data, observed_boot_id=post_boot,
                                    observed_generation=post_gen, watcher_alive=True)
            except (FixtureError, OSError, subprocess.TimeoutExpired, UnicodeError) as exc:
                self.monitor._terminal(POLICY.State.FAIL_CLOSED, "offline reader / identity failure: " + str(exc)[:100])
        terminal = self.monitor.state in (POLICY.State.FAIL_CLOSED, POLICY.State.RETURN_REQUESTED)
        action = "NONE"
        if terminal and not self.action_emitted:
            action = "WOULD_REQUEST_RETURN_NOT_EXECUTED"
            self.action_emitted = True
        return {
            "kind": "SM8850_P0_OFFLINE_FIXTURE_SIMULATION_ONLY",
            "tick": self.tick, "synthetic_monotonic_ms": now_ms,
            "state": self.monitor.state.value, "reason": self.monitor.reason,
            "action": action, "physical_return_issued": False,
            "live_thermal_guard": False,
            "sensor_deci_c": {k: data[k] for k in ("lrp", "battery", "board_ap")}
            if data is not None else None,
        }


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--fixture-root", type=Path, required=True)
    p.add_argument("--boot-id", required=True)
    p.add_argument("--generation", required=True)
    p.add_argument("--launch-token", required=True)
    p.add_argument("--ticks", type=int, default=2)
    p.add_argument("--step-ms", type=int, default=1000)
    args = p.parse_args(argv)
    if not (1 <= args.ticks <= 100 and 1 <= args.step_ms <= 30000):
        p.error("invalid fixture tick count or synthetic step")
    # Literal arbitrary numbers; this CLI NEVER accepts production threshold overrides.
    hypothetical = POLICY.Limits(
        lrp_warn=400, lrp_critical=460,
        battery_warn=420, battery_critical=480,
        board_ap_warn=600, board_ap_critical=700,
        hysteresis=20, warning_dwell_ms=1000,
        max_sample_age_ms=2000,
    )
    try:
        engine = Engine(args.fixture_root, boot_id=args.boot_id,
                        generation=args.generation, launch_token=args.launch_token,
                        limits=hypothetical)
    except (FixtureError, OSError) as exc:
        print("THERMAL_E2E=BLOCKED_FIXTURE: " + str(exc), file=sys.stderr)
        return 2
    for i in range(args.ticks):
        event = engine.step(i * args.step_ms)
        print(json.dumps(event, sort_keys=True))
        if event["state"] in ("FAIL_CLOSED", "RETURN_REQUESTED"):
            return 4  # simulated fail-closed or return request, never a physical action
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
