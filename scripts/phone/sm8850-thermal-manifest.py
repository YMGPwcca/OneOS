#!/usr/bin/env python3
"""Build a boot-bound, NON-AUTHORIZING sensor manifest from P0 junction JSON.

Default: audit only, zero ADB and zero writes. Explicit --build requires an
existing verified OneUI-only inventory JSON from this OneOS branch. This is
untrusted evidence, never a vendor signature, production policy or admission
token. It will NOT operate a phone, watchdog, governor, returner or guest.

The future independent root monitor must revalidate all zone types, process
identities, boot ID, complete coverage and calibrated limits itself BEFORE
trusting any of these paths. Do not use it to bypass the 600s source gate.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import secrets
import sys

MODEL = "SM-S948B"
DEVICE = "m3q"
FIRMWARE = "S948BXXS4BZIG"
PATH = re.compile(r"/sys/class/thermal/thermal_zone(0|[1-9][0-9]{0,2})/temp\Z")
BOOT = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\Z")
SAFE_TYPE = re.compile(r"[a-zA-Z0-9._-]{1,63}\Z")
MAX_SOURCE_BYTES = 512 * 1024


class Refused(Exception):
    pass


def group(name):
    if not isinstance(name, str) or not SAFE_TYPE.fullmatch(name):
        return None
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


def value_is_int(value):
    return type(value) is int


def validate(report):
    if not isinstance(report, dict) or report.get("schema") != 1 or \
            report.get("kind") != "SM8850_REAL_CPU_GPU_DDR_XO_READONLY_SURVEY":
        raise Refused("unexpected survey format")
    if report.get("acceptance") != "NOT_QUALIFIED" or \
            report.get("scan_coverage_complete") is not True or \
            report.get("vendor_thresholds_qualified") is not False or \
            report.get("verified_after_framework_stop") is not False or \
            report.get("independent_guard_active") is not False:
        raise Refused("survey coverage or safety status is not acceptable as evidence")
    if report.get("sensor_errors") != [] or report.get("unreadable_type_indices") != []:
        raise Refused("incomplete or failed sensor inventory")
    identity = report.get("identity")
    if not isinstance(identity, dict):
        raise Refused("missing device identity")
    for key, expected in (("model", MODEL), ("device", DEVICE),
                          ("firmware", FIRMWARE), ("boot_completed", "1"),
                          ("selinux", "Enforcing")):
        if identity.get(key) != expected:
            raise Refused("device identity mismatch")
    boot = identity.get("boot_id")
    if not isinstance(boot, str) or not BOOT.fullmatch(boot):
        raise Refused("missing or invalid boot ID")
    if not isinstance(identity.get("system_server"), str) or \
            not re.fullmatch(r"[0-9]+(?:\s+[0-9]+)*", identity["system_server"]):
        raise Refused("unverified One UI system_server")
    rows = report.get("readings")
    if not isinstance(rows, list) or not 3 <= len(rows) <= 96 or \
            not value_is_int(report.get("selected_count")) or \
            report["selected_count"] != len(rows):
        raise Refused("missing, oversized or inconsistent selected zone list")
    selected = []
    indices = set()
    for item in rows:
        if not isinstance(item, dict):
            raise Refused("bad zone row")
        name, idx, path, kind = (item.get(k) for k in ("type", "index", "path", "group"))
        if not value_is_int(idx) or not 0 <= idx <= 255 or idx in indices:
            raise Refused("duplicate or invalid zone index")
        if group(name) != kind or kind is None:
            raise Refused("zone type/group mismatch or pseudo-trip zone")
        m = PATH.fullmatch(path) if isinstance(path, str) else None
        if not m or int(m.group(1)) != idx:
            raise Refused("zone path not bound to zone index")
        raw = item.get("raw_millidegrees_c")
        celsius = item.get("celsius")
        if not value_is_int(raw) or not -40000 <= raw <= 200000 or \
                type(celsius) not in (int, float) or not math.isfinite(celsius) or \
                not math.isclose(celsius, raw / 1000, abs_tol=0.001, rel_tol=0):
            raise Refused("bad or inconsistent temperature units")
        if item.get("method") not in ("shell_named_cat", "root_named_cat"):
            raise Refused("untrusted sensor read method")
        indices.add(idx)
        selected.append({"index": idx, "type": name, "group": kind, "path": path})
    groups = {name for name in ("cpu", "gpu", "ddr") if any(x["group"] == name for x in selected)}
    if groups != {"cpu", "gpu", "ddr"}:
        raise Refused("missing required CPU/GPU/DDR zone group")
    claimed = report.get("hottest_by_group")
    if not isinstance(claimed, dict):
        raise Refused("missing peaks report")
    for name in ("cpu", "gpu", "ddr", "xo"):
        measured = [r for r in rows if r["group"] == name]
        peak = claimed.get(name)
        if not measured:
            if name != "xo" or peak is not None:
                raise Refused("unexplained missing group")
            continue
        maximum = max(r["raw_millidegrees_c"] for r in measured)
        tied = [r for r in measured if r["raw_millidegrees_c"] == maximum]
        if not isinstance(peak, dict) or not any(
            peak.get("index") == item["index"] and
            peak.get("path") == item["path"] and
            peak.get("type") == item["type"] and
            peak.get("celsius") == item["celsius"] for item in tied
        ):
            raise Refused("reported group maximum does not match all selected readings")
    selected.sort(key=lambda x: x["index"])
    return {
        "schema": 1,
        "kind": "SM8850_SENSOR_MANIFEST_UNATTESTED_EVIDENCE_ONLY",
        "device": {"model": MODEL, "device": DEVICE, "firmware": FIRMWARE,
                   "boot_id": boot, "selinux": "Enforcing"},
        "zones": selected,
        "required_groups": ["cpu", "gpu", "ddr"],
        "xo_optional": True,
        "zone_count": len(selected),
        "real_device_manifest_revalidated": False,
        "firmware_limits_qualified": False,
        "independent_guard_running": False,
        "recovery_certified": False,
        "takeover_admission_granted": False,
        "evidence_status": "NOT_QUALIFIED",
        "notes": "Zone indices are valid only for the source boot. No trust beyond offline report consistency.",
    }


def build_manifest(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_SOURCE_BYTES:
        raise Refused("survey input missing, symlinked or oversized")
    report = json.loads(path.read_text(encoding="utf-8"))
    return validate(report)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--build", action="store_true")
    p.add_argument("--inventory", type=Path)
    p.add_argument("--output-dir", type=Path,
                   default=Path("out/sm8850/thermal-manifests"))
    a = p.parse_args(argv)
    if not a.build:
        print("P0_MANIFEST=AUDIT_ONLY_NO_ADB_NO_WRITE")
        print("Requires complete exact-boot CPU/GPU/DDR junction survey JSON.")
        print("Manifest is NOT trusted for Framework takeover or thermal recovery.")
        return 0
    if a.inventory is None:
        p.error("--build requires --inventory")
    try:
        payload = build_manifest(a.inventory)
        packed = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
        digest = hashlib.sha256(packed).hexdigest()
        envelope = {"manifest": payload, "sha256_of_manifest_payload": digest,
                    "hash_is_not_a_signature": True}
        if a.output_dir.is_symlink():
            raise Refused("output directory is a symlink")
        a.output_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        name = ("boot-manifest-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
                + "-" + secrets.token_hex(4) + ".json")
        output = a.output_dir / name
        with output.open("x", encoding="utf-8") as f:
            os.chmod(output, 0o600)
            json.dump(envelope, f, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
    except (Refused, OSError, ValueError, UnicodeError, KeyError, TypeError) as exc:
        print("P0_MANIFEST=BLOCKED " + str(exc), file=sys.stderr)
        return 4
    print("P0_MANIFEST=VALIDATED_REPORT_ONLY_NOT_ADMISSION")
    print("ZONE_COUNT=" + str(payload["zone_count"]))
    print("SOURCE_BOOT_ID=" + payload["device"]["boot_id"])
    print("MANIFEST_SHA256=" + digest)
    print("OUTPUT=" + str(output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
