#!/usr/bin/env python3
"""Read-only stock One UI recovery provenance inspection for SM8850 P0.

AUDIT by default: no ADB. Explicit --run-readonly reads only fixed,
allowlisted OneOS Framework control and return outcome files with root cat.
No device writes, no reboot, no Framework stop, no watchdog operations.
A previous request/return marker or bootreason is *not* proof of an
unassisted recovery. This tool never grants P0 admission.
"""
import argparse
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import re
import secrets
import sys

HERE=Path(__file__).resolve().parent
SPEC=importlib.util.spec_from_file_location("sm8850_recovery_mapper",HERE/"sm8850-soc-candidate-map.py")
MAPPER=importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MAPPER)
STAGE="/data/adb/oneios-m3q-framework"
ALLOWED={
    "root_stage": STAGE,
    "current_outcome": STAGE+"/return.outcome",
    "control_boot": STAGE+"/control/boot",
    "control_state": STAGE+"/control/state",
    "control_return_mode": STAGE+"/control/framework.return",
    "control_generation": STAGE+"/control/watchdog.generation",
    "session_return_request": STAGE+"/session/return.request",
}
BOOT=re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\Z")


class Blocked(RuntimeError):
    pass


def safe_remote_read(adb,serial,name):
    if name not in ALLOWED or name=="root_stage":
        raise Blocked("unapproved recovery evidence path")
    path=ALLOWED[name]
    r=MAPPER.adb_call(adb,serial,("shell","-T",f"su -c '/system/bin/cat {path}'"),timeout=6)
    if r.returncode:
        # Missing/retired evidence is UNKNOWN rather than an implicit pass.
        return None
    if len(r.stdout)>4096 or "\x00" in r.stdout:
        raise Blocked("untrusted oversized recovery evidence")
    return r.stdout.strip()


def inspect(adb,serial,*,read=safe_remote_read):
    before=MAPPER.identity(adb,serial)
    # This probe is permitted only when Android is already fully booted.
    zygote=MAPPER.adb_call(adb,serial,("shell","getprop","init.svc.zygote"),timeout=6)
    if zygote.returncode or zygote.stdout.strip()!="running":
        raise Blocked("normal One UI zygote not running")
    bootreason=MAPPER.adb_call(adb,serial,("shell","getprop","ro.boot.bootreason"),timeout=6)
    if bootreason.returncode:
        raise Blocked("bootreason unavailable")
    raw={key:read(adb,serial,key) for key in ALLOWED if key!="root_stage"}
    after=MAPPER.identity(adb,serial)
    if before!=after:
        raise Blocked("One UI/boot identity changed during evidence inspection")
    previous=raw["control_boot"]
    previous_valid=isinstance(previous,str) and BOOT.fullmatch(previous) is not None
    boot_changed=previous_valid and previous!=after["boot_id"]
    request=raw["session_return_request"]
    outcome=raw["current_outcome"]
    return_mode=raw["control_return_mode"]
    consistent=(
        boot_changed and return_mode=="reboot" and
        isinstance(outcome,str) and outcome.startswith("reboot-") and
        ("who=framework-deadline" in outcome or "who=keys" in outcome or
         "who=watcher" in outcome)
    )
    # "consistent" is a correlation, not trusted attribution. Root path may
    # have been overwritten and even a named deadline can coincide with a
    # manual reboot/power-button event.
    return {
        "schema":1,
        "kind":"SM8850_READ_ONLY_REBOOT_RETURN_PROVENANCE",
        "device":after,
        "current_zygote":zygote.stdout.strip(),
        "current_bootreason":bootreason.stdout.strip(),
        "evidence":raw,
        "recorded_previous_boot_id":previous if previous_valid else None,
        "old_and_current_boot_different":bool(boot_changed),
        "recorded_outcome_consistent_with_reboot_return":bool(consistent),
        "return_request_present":bool(request),
        "normal_oneui_currently_observed":True,
        "unassisted_return_proven":False,
        "hardware_watchdog_qualified":False,
        "monitor_survival_after_framework_stop_proven":False,
        "recovery_certified":False,
        "p0_complete":False,
        "full_takeover_allowed":False,
        "classification":"HISTORICAL_READ_ONLY_EVIDENCE_NOT_RECOVERY_ACCEPTANCE",
    }


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--run-readonly",action="store_true")
    p.add_argument("--adb",default=str(Path.home()/"Android/Sdk/platform-tools/adb"))
    p.add_argument("--output",type=Path,default=Path("out/sm8850/recovery-provenance"))
    a=p.parse_args(argv)
    if not a.run_readonly:
        print("RECOVERY_PROVENANCE=AUDIT_NO_ADB; fixed root-owned control files only; no writes or reboot")
        print("A return.outcome/bootreason match never proves unassisted reboot.")
        return 0
    try:
        serial=MAPPER.serial_for(a.adb)
        snapshot=inspect(a.adb,serial)
        if a.output.is_symlink():
            raise Blocked("output directory symlink")
        a.output.mkdir(parents=True,exist_ok=True,mode=0o700)
        target=a.output/("recovery-evidence-"+datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")+
                         "-"+secrets.token_hex(3)+".json")
        with target.open("x",encoding="utf-8") as f:
            json.dump(snapshot,f,indent=2,ensure_ascii=False)
            f.write("\n")
        target.chmod(0o600)
    except (Blocked,MAPPER.Blocked,OSError) as e:
        print("RECOVERY_PROVENANCE=BLOCKED "+str(e),file=sys.stderr)
        return 4
    print("RECOVERY_PROVENANCE=READ_ONLY_NOT_CERTIFIED")
    print("NORMAL_ONEUI_NOW=YES")
    print("PREVIOUS_BOOT_DIFFERENT="+str(snapshot["old_and_current_boot_different"]).upper())
    print("HISTORICAL_REBOOT_RETURN_CORRELATION="+
          str(snapshot["recorded_outcome_consistent_with_reboot_return"]).upper())
    print("UNASSISTED_RETURN=NOT_PROVEN")
    print("P0_RECOVERY=NOT_QUALIFIED")
    print("OUTPUT="+str(target))
    return 0


if __name__=="__main__":
    raise SystemExit(main())
