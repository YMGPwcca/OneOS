#!/usr/bin/env python3
"""Read-only P0 inventory for real SM8850 CPU/GPU/DDR thermal zones.

OneiOS thermal.c group rules: cpu-*, cpuss-*, gpuss-*, ddr, xo-therm.
Explicitly excludes cpu-hw-trip-* pseudo-zones. Defaults to zero-ADB audit.
On opt-in: bounded (256) unprivileged thermal_zone*/type enumeration;
read only exact /temp paths after validating type, with root fallback solely
on permission denial for that named /temp. No writes/guest/reboot/watchdog.
This is EVIDENCE ONLY, never thermal protection or takeover authorization.
"""
import argparse
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import re
import secrets
import sys
import time

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("sm8850_mapper", HERE / "sm8850-soc-candidate-map.py")
mapper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mapper)

SCAN = r"""seen=0
for f in /sys/class/thermal/thermal_zone*/type; do
    [ -f "$f" ] || continue
    seen=$((seen+1))
    [ "$seen" -le 256 ] || { echo SCAN_LIMIT_EXCEEDED; exit 4; }
    idx=@{f#/sys/class/thermal/thermal_zone}
    idx=@{idx%/type}
    case "$idx" in ''|*[!0-9]*) exit 4 ;; esac
    t=$(cat "$f" 2>/dev/null) || { printf 'TYPE_UNREADABLE\t%s\n' "$idx"; continue; }
    printf 'ZONE\t%s\t%s\n' "$idx" "$t"
done""".replace("@{",chr(36)+"{")
ZONE_RE = re.compile(r"ZONE\t(0|[1-9][0-9]{0,2})\t([A-Za-z0-9._-]{1,63})\Z")
ERR_RE = re.compile(r"TYPE_UNREADABLE\t(0|[1-9][0-9]{0,2})\Z")
TEMP_RE = re.compile(r"/sys/class/thermal/thermal_zone(0|[1-9][0-9]{0,2})/temp\Z")
NUM_RE = re.compile(r"-?[0-9]{1,7}\Z")


class Blocked(Exception):
    pass


def group_of(name):
    if name.startswith("cpu-hw-trip-"):
        return None
    if name.startswith(("cpu-", "cpuss-")):
        return "cpu"
    if name.startswith("gpuss-"):
        return "gpu"
    if name == "ddr":
        return "ddr"
    if name == "xo-therm":
        return "xo"
    return None


def parse_listing(stdout):
    seen, selected, unreadable = set(), [], []
    lines = stdout.splitlines()
    if not lines or len(lines) > 256:
        raise Blocked("empty/oversized thermal zone inventory")
    for line in lines:
        m, e = ZONE_RE.fullmatch(line), ERR_RE.fullmatch(line)
        if not m and not e:
            raise Blocked("untrusted or malformed zone entry")
        index = int((m or e).group(1))
        if index > 255 or index in seen:
            raise Blocked("out-of-range or duplicate zone index")
        seen.add(index)
        if e:
            unreadable.append(index)
            continue
        name = m.group(2)
        group = group_of(name)
        if group:
            selected.append((index, name, group))
    if not selected or len(selected) > 96:  # BR_THERMAL_MAX_ZONES
        raise Blocked("zero valid groups or >96 selected zones")
    return selected, unreadable


def check_type(adb, serial, index, expected):
    path = f"/sys/class/thermal/thermal_zone{index}/type"
    result = mapper.adb_call(adb, serial, ("shell", "-T", "/system/bin/cat", path), timeout=5)
    if result.returncode or result.stdout.strip() != expected:
        raise Blocked("zone type changed or inaccessible")


def read_zone(adb, serial, index, name, group):
    path = f"/sys/class/thermal/thermal_zone{index}/temp"
    if not TEMP_RE.fullmatch(path) or index > 255 or group_of(name) != group:
        raise Blocked("untrusted thermal path or type")
    check_type(adb, serial, index, name)
    result = mapper.adb_call(adb, serial, ("shell", "-T", "/system/bin/cat", path), timeout=5)
    method = "shell_named_cat"
    if result.returncode:
        if "Permission denied" not in result.stdout + result.stderr:
            raise Blocked("named temperature unavailable for non-permission reason")
        result = mapper.adb_call(adb, serial,
                                 ("shell", "-T", f"su -c '/system/bin/cat {path}'"), timeout=5)
        method = "root_named_cat"
        if result.returncode:
            raise Blocked("root named sensor read failed")
    check_type(adb, serial, index, name)
    raw = result.stdout.strip()
    if not NUM_RE.fullmatch(raw):
        raise Blocked("malformed temperature")
    milli = int(raw)
    if not -40000 <= milli <= 200000:
        raise Blocked("invalid/sentinel temperature")
    return {"index": index, "type": name, "group": group, "path": path,
            "raw_millidegrees_c": milli, "celsius": milli / 1000, "method": method}


def summarize(readings, failures, unreadable):
    peaks = {}
    for group in ("cpu", "gpu", "ddr", "xo"):
        items = [item for item in readings if item["group"] == group]
        if items:
            top = max(items, key=lambda z: z["raw_millidegrees_c"])
            peaks[group] = {"type": top["type"], "path": top["path"],
                            "celsius": top["celsius"], "index": top["index"]}
        else:
            peaks[group] = None
    complete = (not failures and not unreadable and
                all(peaks[key] is not None for key in ("cpu", "gpu", "ddr")))
    return peaks, complete


def collect(adb, serial, *, clock=time.monotonic):
    started = clock()
    before = mapper.identity(adb, serial)
    found = mapper.adb_call(adb, serial, ("shell", "-T", SCAN), timeout=20)
    if found.returncode:
        raise Blocked("bounded unprivileged type scan failed")
    selected, unreadable = parse_listing(found.stdout)
    readings, failures = [], []
    for idx, name, group in selected:
        if clock() - started > 120:
            raise Blocked("inventory exceeded 120-second host budget")
        try:
            readings.append(read_zone(adb, serial, idx, name, group))
        except (Blocked, mapper.Blocked) as exc:
            failures.append({"index": idx, "type": name, "error": str(exc)})
    if mapper.identity(adb, serial) != before:
        raise Blocked("One UI or boot identity changed mid-survey")
    peaks, complete = summarize(readings, failures, unreadable)
    return {
        "schema": 1, "kind": "SM8850_REAL_CPU_GPU_DDR_XO_READONLY_SURVEY",
        "identity": before, "selected_count": len(selected), "readings": readings,
        "sensor_errors": failures, "unreadable_type_indices": unreadable,
        "hottest_by_group": peaks, "scan_coverage_complete": complete,
        "acceptance": "NOT_QUALIFIED", "vendor_thresholds_qualified": False,
        "verified_after_framework_stop": False, "independent_guard_active": False,
    }


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--run-readonly", action="store_true")
    p.add_argument("--adb", default=str(Path.home() / "Android/Sdk/platform-tools/adb"))
    p.add_argument("--output", type=Path, default=Path("out/sm8850/thermal-junction-inventory"))
    a = p.parse_args(argv)
    if not a.run_readonly:
        print("JUNCTION_INVENTORY=AUDIT_NO_ADB; type-only nonrecursive scan;")
        print("exact CPU/GPU/DDR/XO named temperature reads; no actions")
        return 0
    try:
        serial = mapper.serial_for(a.adb)
        result = collect(a.adb, serial)
        a.output.mkdir(parents=True, mode=0o700, exist_ok=True)
        out = a.output / ("junction-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") +
                          "-" + secrets.token_hex(3) + ".json")
        with out.open("x", encoding="utf-8") as f:
            json.dump(result, f, indent=2)
            f.write("\n")
        out.chmod(0o600)
    except (Blocked, mapper.Blocked, OSError) as exc:
        print("JUNCTION_INVENTORY=BLOCKED " + str(exc), file=sys.stderr)
        return 4
    print("JUNCTION_INVENTORY=EVIDENCE_ONLY_NOT_GUARD")
    print("SELECTED=%d ERRORS=%d UNREADABLE_TYPES=%d" % (
        result["selected_count"], len(result["sensor_errors"]),
        len(result["unreadable_type_indices"])))
    for group, val in result["hottest_by_group"].items():
        print(group.upper() + "_PEAK=" +
              ("%.1fC %s %s" % (val["celsius"], val["type"], val["path"])
               if val else "UNAVAILABLE"))
    print("COVERAGE_COMPLETE=" + ("YES" if result["scan_coverage_complete"] else "NO"))
    print("OUTPUT=" + str(out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
