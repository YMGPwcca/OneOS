#!/usr/bin/env python3
"""Explicit, bounded 3x four-sensor read on intact SM8850 One UI.

Default audit prints scope without ADB. Live mode requires the genuine stock
firmware, Enforcing, system_server, a unique current-boot cpu-0-5-1 thermal
type mapping and a vetted reader SHA-256. Only one named script is staged
under /data/local/tmp and always cleaned. No guest/Framework stop, governor,
watchdog, sysfs write, thermal threshold or reboot action. NOT A GUARD.
"""
import argparse
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import secrets
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
READER = HERE.parent.parent / "switcher/assets/oneios_sm8850_thermal_pinned_reader.sh"
MAPPER_FILE = HERE / "sm8850-soc-candidate-map.py"
SPEC = importlib.util.spec_from_file_location("sm8850_cpu_mapping", MAPPER_FILE)
MAPPER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MAPPER)

EXPECTED_KEYS = frozenset({
    "THERMAL_PINNED", "source", "boot_id", "cpu_zone_type",
    "cpu_zone_path", "cpu_milli_c", "cpu_deci_c", "battery_deci_c",
    "lrp_deci_c", "board_ap_deci_c", "uptime_start", "uptime_end",
    "after_framework_available",
})
CPU_PATH = re.compile(r"/sys/class/thermal/thermal_zone(0|[1-9][0-9]{0,2})/temp\Z")
DECIMAL = re.compile(r"[1-9][0-9]{0,3}\Z")


class Refused(RuntimeError):
    pass


def adb(adb_path, serial, *args, timeout=10):
    r = MAPPER.adb_call(adb_path, serial, args, timeout=timeout)
    if r.returncode:
        raise Refused("ADB operation failed: " + repr(args[:2]) +
                      " (status=" + str(r.returncode) + ")")
    return r.stdout.strip()


def identity_and_cpu_zone(adb_path, serial):
    before = MAPPER.identity(adb_path, serial)
    mapped = MAPPER.adb_call(adb_path, serial, ("shell", "-T", MAPPER.SCAN), timeout=20)
    if mapped.returncode:
        raise Refused("bounded unprivileged type mapping failed")
    path = MAPPER.map_cpu_path(mapped.stdout)
    m = CPU_PATH.fullmatch(path)
    if not m or int(m.group(1)) > 255:
        raise Refused("candidate zone outside approved 0..255 range")
    return before, str(int(m.group(1))), path


def parse_sample(text, expected_boot, expected_path):
    fields = {}
    for line in text.splitlines():
        if "=" not in line:
            raise Refused("malformed sample line")
        key, value = line.split("=", 1)
        if key in fields or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            raise Refused("duplicate or invalid sample field")
        fields[key] = value
    if fields.keys() != EXPECTED_KEYS:
        raise Refused("sample fields missing, duplicated or unexpected")
    required = {
        "THERMAL_PINNED": "FOUR_SENSOR_READ_ONLY_NOT_GUARD",
        "source": "--live-oneui-readonly",
        "boot_id": expected_boot,
        "cpu_zone_type": "cpu-0-5-1",
        "cpu_zone_path": expected_path,
        "after_framework_available": "NOT_VERIFIED",
    }
    for key, expected in required.items():
        if fields[key] != expected:
            raise Refused("untrusted " + key)
    values = {}
    for key in ("battery_deci_c", "lrp_deci_c", "board_ap_deci_c", "cpu_deci_c"):
        value = fields[key]
        max_deci = 1500 if key == "cpu_deci_c" else 1200
        if not DECIMAL.fullmatch(value) or int(value) > max_deci:
            raise Refused("invalid " + key)
        values[key] = int(value)
    raw = fields["cpu_milli_c"]
    if not re.fullmatch(r"[1-9][0-9]{0,5}", raw) or int(raw) >= 150000:
        raise Refused("invalid CPU millidegrees")
    milli = int(raw)
    if values["cpu_deci_c"] != (milli + 50) // 100:
        raise Refused("CPU units mismatch")
    try:
        first, last = (Decimal(fields[key]) for key in ("uptime_start", "uptime_end"))
    except InvalidOperation as exc:
        raise Refused("invalid uptime") from exc
    if not (first.is_finite() and last.is_finite()
            and first >= 0 and first <= last and last-first <= 3):
        raise Refused("invalid sample time bounds")
    values["cpu_milli_c"] = milli
    values["uptime_start"] = str(first)
    values["uptime_end"] = str(last)
    return values


def trusted_source(reader):
    if not reader.is_file() or reader.is_symlink():
        raise Refused("reader missing or symlinked")
    source = reader.read_bytes()
    if not source.startswith(b"#!/system/bin/sh\n"):
        raise Refused("reader shell header unrecognized")
    # Syntax test in the host before any device action.
    subprocess.run(["sh", "-n", str(reader)], check=True, timeout=3, capture_output=True)
    return hashlib.sha256(source).hexdigest()


def collect(adb_path, serial, reader=READER):
    checksum = trusted_source(reader)
    before, index, temp_path = identity_and_cpu_zone(adb_path, serial)
    boot = before["boot_id"]
    remote = "/data/local/tmp/oneos-p0-four-sensor-" + secrets.token_hex(8)
    filename = remote + "/oneios_sm8850_thermal_pinned_reader.sh"
    created = False
    cleanup_error = None
    samples = []
    try:
        adb(adb_path, serial, "shell", "mkdir", remote)
        created = True
        adb(adb_path, serial, "shell", "chmod", "700", remote)
        adb(adb_path, serial, "push", str(reader), filename, timeout=12)
        remote_sum = adb(adb_path, serial, "shell", "sha256sum", filename).split()
        if not remote_sum or remote_sum[0] != checksum:
            raise Refused("remote reader SHA-256 mismatch")
        for i in range(3):
            # All interpolated fields are constrained to a hex nonce, one
            # 0..255 integer and the validated UUID: no untrusted commands.
            command = ("su -c '/system/bin/sh " + filename +
                       " --live-oneui-readonly " + index + " " + boot + "'")
            output = adb(adb_path, serial, "shell", "-T", command, timeout=9)
            values = parse_sample(output, boot, temp_path)
            samples.append(values)
            if i < 2:
                time.sleep(1)
        after = MAPPER.identity(adb_path, serial)
        if after != before:
            raise Refused("boot/firmware/One UI identity changed during sampling")
    finally:
        if created:
            # Delete only this script and its own randomized directory.
            try:
                adb(adb_path, serial, "shell", "rm", "-f", filename)
                adb(adb_path, serial, "shell", "rmdir", remote)
            except (Refused, MAPPER.Blocked, OSError) as exc:
                cleanup_error = exc
    if cleanup_error is not None:
        raise Refused("temporary staging cleanup not verified") from cleanup_error
    return {
        "schema": 1, "kind": "SM8850_FOUR_SENSOR_ONEUI_EVIDENCE_NOT_GUARD",
        "identity": before, "cpu_type": "cpu-0-5-1", "zone_path": temp_path,
        "reader_sha256": checksum, "samples": samples,
        "read_only": True, "qualified_after_framework_stop": False,
        "qualified_thermal_limits": False, "guard_active": False,
        "acceptance": "COLLECTED_NOT_QUALIFIED",
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-readonly", action="store_true")
    parser.add_argument("--adb", default=str(Path.home() / "Android/Sdk/platform-tools/adb"))
    parser.add_argument("--output", type=Path, default=Path("out/sm8850/four-sensor-oneui"))
    args = parser.parse_args(argv)
    if not args.run_readonly:
        print("FOUR_SENSOR=AUDIT_NO_ADB; stock One UI only; exact CPU type and boot;")
        print("3 rooted read-only snapshots; isolated SHA-verified temporary staging;")
        print("strict cleanup and same-boot postcheck; no watchdog, reboot or guest")
        return 0
    try:
        serial = MAPPER.serial_for(args.adb)
        evidence = collect(args.adb, serial)
        args.output.mkdir(parents=True, exist_ok=True, mode=0o700)
        outfile = args.output / ("four-sensor-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
                                + "-" + secrets.token_hex(3) + ".json")
        with outfile.open("x", encoding="utf-8") as f:
            json.dump(evidence, f, indent=2, ensure_ascii=False)
            f.write("\n")
        outfile.chmod(0o600)
    except (Refused, MAPPER.Blocked, subprocess.SubprocessError, OSError) as exc:
        print("FOUR_SENSOR=BLOCKED_NOT_GUARD " + str(exc), file=sys.stderr)
        return 4
    print("FOUR_SENSOR=COLLECTED_NOT_QUALIFIED")
    print("CPU_ZONE=" + evidence["zone_path"])
    for i, sample in enumerate(evidence["samples"], 1):
        print("SAMPLE_%d CPU=%.1fC BAT=%.1fC LRP=%.1fC BOARD_AP=%.1fC" % (
            i, sample["cpu_deci_c"]/10, sample["battery_deci_c"]/10,
            sample["lrp_deci_c"]/10, sample["board_ap_deci_c"]/10))
    print("OUTPUT=" + str(outfile))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
