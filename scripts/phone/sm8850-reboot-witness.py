#!/usr/bin/env python3
"""Host-only observer for ONE explicitly authorized short reboot-only smoke.

Default AUDIT: zero ADB access. --observe-only has NO reboot/stop/return
commands. It records an initial normal One UI boot ID, then observes a
loss of ADB transport and a NEW normal One UI boot, and correlates fixed
historical return evidence using sm8850-recovery-provenance.py.

Neither ADB loss nor a changed boot alone establishes automatic recovery.
The witness cannot prove absence of physical key use and cannot qualify
legacy watchdog or thermal/Framework independence. It never permits 600s.
"""
import argparse
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import secrets
import sys
import time

HERE = Path(__file__).resolve().parent


def import_module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


MAPPER = import_module(HERE / "sm8850-soc-candidate-map.py", "sm8850_witness_mapper")
PROVENANCE = import_module(HERE / "sm8850-recovery-provenance.py", "sm8850_witness_provenance")


class Refused(RuntimeError):
    pass


def probe(adb, serial):
    """Return status and new boot identifier without changing phone state."""
    r = MAPPER.adb_call(adb, serial, ("get-state",), timeout=4)
    if r.returncode or r.stdout.strip() != "device":
        return "OFFLINE", None
    r = MAPPER.adb_call(adb, serial, ("shell", "cat", "/proc/sys/kernel/random/boot_id"), timeout=4)
    if r.returncode or not MAPPER.BOOT_ID.fullmatch(r.stdout.strip()):
        return "STARTING_OR_INACCESSIBLE", None
    return "ONLINE", r.stdout.strip()


def evaluate(before, after, events, provenance):
    """Never turn an observer-only trace into a certified recovery result."""
    if not before or not after or before == after:
        raise Refused("missing or unchanged boot identity")
    if not any(e["status"] == "OFFLINE" for e in events):
        raise Refused("no observed ADB transport interruption")
    if not any(e["status"] == "NEW_BOOT_NORMAL_ONEUI" for e in events):
        raise Refused("no verified normal One UI on a distinct boot")
    correlated = (
        isinstance(provenance, dict)
        and provenance.get("recorded_previous_boot_id") == before
        and provenance.get("old_and_current_boot_different") is True
        and provenance.get("recorded_outcome_consistent_with_reboot_return") is True
        and provenance.get("current_zygote") == "running"
        and provenance.get("normal_oneui_currently_observed") is True
    )
    return {
        "schema": 1,
        "kind": "SM8850_HOST_OBSERVED_REBOOT_RETURN_NOT_SAFETY_CERTIFICATION",
        "before_boot_id": before,
        "after_boot_id": after,
        "witness_events": events,
        "historical_return_record_correlated_to_pre_smoke_boot": bool(correlated),
        "source": "passive_external_host_adb_observation",
        "observer_issued_reboot": False,
        "observer_stopped_framework": False,
        "observer_touched_watchdog": False,
        "new_normal_oneui_boot_observed": True,
        "absence_of_physical_key_use_proven": False,
        "unassisted_return_proven": False,
        "framework_independent_thermal_guard_qualified": False,
        "vendor_thermal_limits_qualified": False,
        "hardware_watchdog_qualified": False,
        "recovery_certified": False,
        "p0_complete": False,
        "full_600s_takeover_allowed": False,
        "classification": "HOST_OBSERVATION_WITH_UNASSISTED_RETURN_STILL_UNPROVEN",
    }


def observe(adb, serial, *, max_seconds=240, clock=time.monotonic, sleep=time.sleep,
            probe_func=probe, identity=MAPPER.identity, inspector=PROVENANCE.inspect):
    if not 30 <= max_seconds <= 600:
        raise Refused("invalid hard witness deadline")
    baseline = identity(adb, serial)
    before = baseline["boot_id"]
    started = clock()
    events = [{"t_seconds": 0.0, "status": "INITIAL_NORMAL_ONEUI"}]
    disconnected = False
    next_boot = None
    while clock() - started < max_seconds:
        try:
            status, boot_id = probe_func(adb, serial)
        except (MAPPER.Blocked, OSError):
            status, boot_id = "OFFLINE", None
        elapsed = round(clock() - started, 3)
        if status == "OFFLINE":
            if not disconnected:
                events.append({"t_seconds": elapsed, "status": "OFFLINE"})
            disconnected = True
        elif status == "ONLINE" and boot_id and boot_id != before:
            try:
                recovered = identity(adb, serial)
                if recovered.get("boot_id") != boot_id:
                    raise Refused("boot identity inconsistent")
                if disconnected:
                    events.append({"t_seconds": elapsed, "status": "NEW_BOOT_NORMAL_ONEUI"})
                    next_boot = boot_id
                    break
            except MAPPER.Blocked:
                # The kernel is booted but system_server has not yet returned.
                pass
        sleep(2)
    if not next_boot:
        raise Refused("no new healthy One UI boot observed after an ADB loss within bounded window")
    # Source-backed historical correlation is deliberately non-authorizing.
    try:
        evidence = inspector(adb, serial)
    except (MAPPER.Blocked, PROVENANCE.Blocked, OSError):
        evidence = None
    report = evaluate(before, next_boot, events, evidence)
    report["observation_duration_seconds"] = round(clock()-started, 3)
    report["historical_provenance_snapshot"] = evidence
    return report


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--observe-only", action="store_true")
    ap.add_argument("--adb", default=str(Path.home() / "Android/Sdk/platform-tools/adb"))
    ap.add_argument("--max-seconds", type=int, default=240)
    ap.add_argument("--output", type=Path, default=Path("out/sm8850/reboot-witness"))
    args = ap.parse_args(argv)
    if not args.observe_only:
        print("REBOOT_WITNESS=AUDIT_NO_ADB_NO_REBOOT")
        print("Observer makes only read-only ADB calls. It cannot trigger a recovery.")
        print("Run it BEFORE a separately reviewed, explicitly authorized SHORT smoke.")
        return 0
    try:
        serial = MAPPER.serial_for(args.adb)
        report = observe(args.adb, serial, max_seconds=args.max_seconds)
        if args.output.is_symlink():
            raise Refused("symlinked evidence output directory")
        args.output.mkdir(mode=0o700, parents=True, exist_ok=True)
        output = args.output / (
            "witness-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
            + "-" + secrets.token_hex(4) + ".json"
        )
        with output.open("x", encoding="utf-8") as f:
            json.dump(report, f, ensure_ascii=False, indent=2)
            f.write("\n")
        output.chmod(0o600)
    except (Refused, MAPPER.Blocked, OSError) as exc:
        print("REBOOT_WITNESS=BLOCKED " + str(exc), file=sys.stderr)
        return 4
    print("REBOOT_WITNESS=NEW_NORMAL_ONEUI_BOOT_OBSERVED")
    print("PRE_SMOKE_BOOT=" + report["before_boot_id"])
    print("POST_SMOKE_BOOT=" + report["after_boot_id"])
    print("HISTORICAL_RETURN_MARKER_CORRELATED=" +
          str(report["historical_return_record_correlated_to_pre_smoke_boot"]).upper())
    print("UNASSISTED_RETURN=NOT_PROVEN")
    print("P0_RECOVERY=NOT_QUALIFIED")
    print("OUTPUT=" + str(output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
