#!/usr/bin/env python3
"""Read-only SM8850 CPU thermal zone candidate mapper.

Explicit --run-readonly; stock One UI must be running. Unprivileged
nonrecursive thermal_zone*/type lookup (max 256 types) for exactly
cpu-0-5-1, the real S26 CPU thermal type observed on 2026-11-16.
Only its exact /temp is sampled, with optional root fallback only
after Permission denied. No root scan, Framework stop, watchdog, writes
or guest. Output is NOT safety or thermal limit qualification.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess
import sys
import time

TEMP_PATH = re.compile(r"/sys/class/thermal/thermal_zone[0-9]+/temp\Z")
BOOT_ID = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\Z")
SCAN = r"""seen=0
for f in /sys/class/thermal/thermal_zone*/type; do
    [ -f "$f" ] || continue
    seen=$((seen+1))
    [ "$seen" -le 256 ] || { echo SCAN_TOO_MANY_ZONES; exit 4; }
    kind=$(cat "$f" 2>/dev/null) || continue
    if [ "$kind" = cpu-0-5-1 ]; then
        printf 'CANDIDATE=%s/temp\n' "$(dirname "$f")"
    fi
done"""


class Blocked(Exception):
    pass


def adb_call(adb, serial, args, timeout=12):
    cmd = [adb] + (["-s", serial] if serial else []) + list(args)
    try:
        return subprocess.run(cmd, text=True, errors="replace", capture_output=True,
                              timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Blocked(f"ADB unavailable or timeout: {exc}") from exc


def get(adb, serial, args):
    result = adb_call(adb, serial, args)
    if result.returncode:
        raise Blocked(f"read failed for {args!r}")
    return result.stdout.strip()


def serial_for(adb):
    lines = get(adb, None, ("devices",)).splitlines()[1:]
    serials = [fields[0] for line in lines if len(fields := line.split()) >= 2 and fields[1] == "device"]
    if len(serials) != 1 or not re.fullmatch(r"[A-Za-z0-9._:-]+", serials[0]):
        raise Blocked("expected exactly one authorized ADB device")
    return serials[0]


def identity(adb, serial):
    requests = {
        "model": ("shell", "getprop", "ro.product.model"),
        "device": ("shell", "getprop", "ro.product.device"),
        "firmware": ("shell", "getprop", "ro.build.version.incremental"),
        "boot_completed": ("shell", "getprop", "sys.boot_completed"),
        "selinux": ("shell", "getenforce"),
        "system_server": ("shell", "pidof", "system_server"),
        "boot_id": ("shell", "cat", "/proc/sys/kernel/random/boot_id"),
    }
    found = {key: get(adb, serial, cmd) for key, cmd in requests.items()}
    required = {"model": "SM-S948B", "device": "m3q",
                "firmware": "S948BXXS4BZIG", "boot_completed": "1",
                "selinux": "Enforcing"}
    if any(found[key] != val for key, val in required.items()):
        raise Blocked("model, firmware, stock boot or enforcing mismatch")
    if not re.fullmatch(r"[0-9]+(?:\s+[0-9]+)*", found["system_server"]):
        raise Blocked("Android system_server absent")
    if not BOOT_ID.fullmatch(found["boot_id"]):
        raise Blocked("invalid boot ID")
    return found


def map_cpu_path(output):
    lines = output.strip().splitlines()
    if len(lines) != 1 or not lines[0].startswith("CANDIDATE="):
        raise Blocked("missing, ambiguous or malformed cpu-0-5-1 mapping")
    path = lines[0].removeprefix("CANDIDATE=")
    if not TEMP_PATH.fullmatch(path):
        raise Blocked("untrusted temperature path")
    return path


def read_temperature(adb, serial, path):
    if not TEMP_PATH.fullmatch(path):
        raise Blocked("path rejected")
    result = adb_call(adb, serial, ("shell", "-T", "/system/bin/cat", path))
    method = "shell_named_cat"
    if result.returncode:
        if "Permission denied" not in result.stdout + result.stderr:
            raise Blocked("named CPU temperature unavailable for reasons other than permissions")
        result = adb_call(adb, serial, ("shell", "-T", f"su -c '/system/bin/cat {path}'"))
        method = "root_named_cat"
        if result.returncode:
            raise Blocked("root named CPU temperature read failed")
    raw = result.stdout.strip()
    if not re.fullmatch(r"[0-9]{1,6}", raw):
        raise Blocked("malformed or invalid CPU temperature")
    milli = int(raw)
    if not 0 < milli < 150000:
        raise Blocked("CPU temperature sentinel/out-of-range")
    return {"raw_millidegrees_c": milli, "celsius": milli / 1000,
            "method": method, "observed_utc": datetime.now(timezone.utc).isoformat()}


def collect(adb, serial):
    before = identity(adb, serial)
    result = adb_call(adb, serial, ("shell", "-T", SCAN), timeout=20)
    if result.returncode:
        raise Blocked("bounded nonrecursive thermal type lookup failed")
    path = map_cpu_path(result.stdout)
    readings = []
    for i in range(3):
        readings.append(read_temperature(adb, serial, path))
        if i < 2:
            time.sleep(1)
    if identity(adb, serial) != before:
        raise Blocked("boot/framework identity changed during snapshot")
    return {
        "schema": 1, "kind": "SM8850_EXACT_CPU_ZONE_CANDIDATE_EVIDENCE",
        "identity": before, "cpu_type": "cpu-0-5-1",
        "temp_path": path, "samples": readings,
        "qualified_cpu_junction": False, "qualified_limits": False,
        "verified_after_framework_stop": False, "acceptance": "NOT_QUALIFIED",
        "readonly_type_enumeration": True,
        "note": "candidate only; not the maximum SoC junction and not a protective monitor",
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-readonly", action="store_true")
    parser.add_argument("--adb", default=str(Path.home() / "Android/Sdk/platform-tools/adb"))
    parser.add_argument("--output", type=Path, default=Path("out/sm8850/soc-candidate"))
    args = parser.parse_args(argv)
    if not args.run_readonly:
        print("SOC_MAP=AUDIT_NO_ADB: nonrecursive type-only scan; exact cpu-0-5-1 temp; 3 samples; no writes")
        return 0
    try:
        serial = serial_for(args.adb)
        snapshot = collect(args.adb, serial)
        args.output.mkdir(parents=True, mode=0o700, exist_ok=True)
        path = args.output / ("cpu-candidate-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + ".json")
        with path.open("x", encoding="utf-8") as f:
            json.dump(snapshot, f, ensure_ascii=False, indent=2)
            f.write("\n")
        path.chmod(0o600)
    except (Blocked, OSError) as exc:
        print(f"SOC_MAP=BLOCKED: {exc}", file=sys.stderr)
        return 4
    print("SOC_MAP=COLLECTED_NOT_QUALIFIED")
    print(f"CPU_TYPE={snapshot['cpu_type']} PATH={snapshot['temp_path']}")
    for i, sample in enumerate(snapshot["samples"], 1):
        print(f"SAMPLE_{i}={sample['celsius']:.3f}C via {sample['method']}")
    print(f"OUTPUT={path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
