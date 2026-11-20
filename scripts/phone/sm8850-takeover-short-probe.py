#!/usr/bin/env python3
"""OneOS SM8850 single-entry SHORT real iOS takeover probe (90s maximum).

AUDIT by default; --prepare-probe stages verified switch + root thermal
guard + current-boot CPU/GPU/DDR manifest without stopping One UI.
Explicit --run-90s: same preparation, mandatory original OneOS passive
preflight, then starts real xnuhost in a bounded 90s Framework session.
The existing framework-deadline and watcher own mandatory reboot-only
return; this host process never invokes reboot, watchdog, governor writes
or Android Framework stop directly. Host witness independently watches
for new normal One UI boot.

IMPORTANT: this is a disruptive experimental takeover. Return paths,
legacy watchdog and vendor thermal limits are NOT production certified.
No 600s run, no --framework-session run bypass.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import secrets
import subprocess
import sys
import tempfile
import threading
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
STAGE = "/data/adb/oneios-m3q-framework"
SWITCH = ROOT/"switcher/assets/oneios_switch.sh"
GUARD = ROOT/"switcher/assets/oneios_sm8850_thermal_takeover_guard.sh"
RISK = "I_ACCEPT_SM8850_SHORT_TAKEOVER_90S_RISK"
ACK = "I_ACCEPT_SM8850_FRAMEWORK_TAKEOVER"

def load(path,name):
    s=importlib.util.spec_from_file_location(name,path)
    m=importlib.util.module_from_spec(s)
    s.loader.exec_module(m)
    return m

INVENTORY=load(HERE/"sm8850-thermal-junction-inventory.py","probe_junction_inventory")
MANIFEST=load(HERE/"sm8850-thermal-manifest.py","probe_manifest")
WITNESS=load(HERE/"sm8850-reboot-witness.py","probe_reboot_witness")

class Refused(Exception):
    pass

def adb(adb_path,serial,*args,timeout=18,allow_failure=False):
    result=INVENTORY.mapper.adb_call(adb_path,serial,args,timeout=timeout)
    if result.returncode and not allow_failure:
        raise Refused("ADB operation failed "+repr(args[:2])+" status="+str(result.returncode)+
                      " error="+str(result.stderr or "")[:180])
    return result.stdout.strip()

def remote_root(adb_path,serial,script,*,timeout=25):
    if "\n" in script or "'" in script:
        raise Refused("unexpected untrusted shell command")
    return adb(adb_path,serial,"shell","-T","su -c '"+script+"'",timeout=timeout)

def sha(path):
    if not path.is_file() or path.is_symlink():
        raise Refused("source absent or symlinked")
    data=path.read_bytes()
    if not data.startswith(b"#!/system/bin/sh\n"):
        raise Refused("unexpected root shell source")
    status=subprocess.run(["sh","-n",str(path)],capture_output=True,text=True,timeout=5)
    if status.returncode:
        raise Refused("shell syntax failed: "+str(path))
    return hashlib.sha256(data).hexdigest()

def line_manifest(snapshot):
    checked=MANIFEST.validate(snapshot)
    boot=checked["device"]["boot_id"]
    rows=checked["zones"]
    return ("\n".join([f"v1 {boot} {len(rows)}"]+
                      [f"z {z['index']} {z['type']} {z['group']}" for z in rows])+"\n").encode(),boot,len(rows)

def prepare(adb_path,serial):
    sha(SWITCH); sha(GUARD)
    before=INVENTORY.mapper.identity(adb_path,serial)
    snapshot=INVENTORY.collect(adb_path,serial)
    manifest,boot,zones=line_manifest(snapshot)
    if before!=INVENTORY.mapper.identity(adb_path,serial) or boot!=before["boot_id"]:
        raise Refused("stock One UI identity changed during current-boot sensor survey")
    nonce=secrets.token_hex(8)
    temp=f"/data/local/tmp/oneos-short-probe-{nonce}"
    installer_names={
        "oneios_switch.sh": SWITCH,
        "oneios_sm8850_thermal_takeover_guard.sh": GUARD,
    }
    made=False
    try:
        adb(adb_path,serial,"shell","mkdir",temp)
        made=True
        adb(adb_path,serial,"shell","chmod","700",temp)
        with tempfile.TemporaryDirectory(prefix="oneos-p0-short-host-") as d:
            manifest_source=Path(d)/"thermal.guard.manifest"
            manifest_source.write_bytes(manifest)
            all_sources={**installer_names,"thermal.guard.manifest":manifest_source}
            for filename,path in all_sources.items():
                remote=temp+"/"+filename
                adb(adb_path,serial,"push",str(path),remote,timeout=20)
                actual=adb(adb_path,serial,"shell","sha256sum",remote).split()
                if not actual or actual[0]!=hashlib.sha256(path.read_bytes()).hexdigest():
                    raise Refused("temporary upload hash mismatch "+filename)
            # Stop if any return/takeover session is still active on THIS boot.
            # Exactly limited root-owned files, paths and nonce.
            setup=(
                "set -e; "
                f"test -d {STAGE}; test ! -L {STAGE}; "
                f"test -f {STAGE}/oneios_switch.sh; test -f {STAGE}/oneios_return.sh; "
                f"test ! -L {STAGE}/oneios_return.sh; "
                f"mkdir -p {STAGE}/logs; "
                f"if test -f {STAGE}/control/boot && "
                f"test \"$(cat {STAGE}/control/boot)\" = \"$(cat /proc/sys/kernel/random/boot_id)\"; then "
                f"case \"$(cat {STAGE}/control/state)\" in starting|running|returning) exit 22;; esac; fi; "
                f"cp {STAGE}/oneios_switch.sh {STAGE}/logs/oneios_switch.before_probe.{nonce}; "
                f"cp {temp}/oneios_switch.sh {STAGE}/.switch.{nonce}; "
                f"cp {temp}/oneios_sm8850_thermal_takeover_guard.sh {STAGE}/.guard.{nonce}; "
                f"cp {temp}/thermal.guard.manifest {STAGE}/.manifest.{nonce}; "
                f"chown 0:0 {STAGE}/.switch.{nonce} {STAGE}/.guard.{nonce} {STAGE}/.manifest.{nonce}; "
                f"chmod 700 {STAGE}/.switch.{nonce} {STAGE}/.guard.{nonce}; "
                f"chmod 600 {STAGE}/.manifest.{nonce}; "
                f"mv -f {STAGE}/.switch.{nonce} {STAGE}/oneios_switch.sh; "
                f"mv -f {STAGE}/.guard.{nonce} {STAGE}/oneios_sm8850_thermal_takeover_guard.sh; "
                f"mv -f {STAGE}/.manifest.{nonce} {STAGE}/thermal.guard.manifest; "
                f"chmod 700 {STAGE}/oneios_switch.sh {STAGE}/oneios_sm8850_thermal_takeover_guard.sh; "
                f"chmod 600 {STAGE}/thermal.guard.manifest"
            )
            remote_root(adb_path,serial,setup,timeout=25)
            for filename,path in all_sources.items():
                check=remote_root(adb_path,serial,
                   f"sha256sum {STAGE}/{filename}",timeout=10).split()
                if not check or check[0]!=hashlib.sha256(path.read_bytes()).hexdigest():
                    raise Refused("root-staged SHA mismatch "+filename)
    finally:
        if made:
            # This is only the disposable ADB upload folder; installed
            # trusted files in /data/adb are intentionally not removed.
            try:
                remote_root(adb_path,serial,
                    f"rm -f {temp}/oneios_switch.sh {temp}/oneios_sm8850_thermal_takeover_guard.sh "
                    f"{temp}/thermal.guard.manifest; rmdir {temp}",timeout=15)
            except (Refused,INVENTORY.mapper.Blocked):
                raise Refused("temporary ADB upload cleanup unverified")
    return {"source_boot":boot,"zones":zones,"stage":STAGE,
            "switch_sha256":hashlib.sha256(SWITCH.read_bytes()).hexdigest(),
            "guard_sha256":hashlib.sha256(GUARD.read_bytes()).hexdigest(),
            "manifest_sha256":hashlib.sha256(manifest).hexdigest(),
            "preflight_passed":False}

def preflight(adb_path,serial):
    cmd=f"/system/bin/sh {STAGE}/oneios_switch.sh --framework-check probe"
    output=remote_root(adb_path,serial,cmd,timeout=90)
    if "PREFLIGHT OK" not in output or "P0_FULL_600S_TAKEOVER=BLOCKED" in output:
        raise Refused("short probe preflight did not pass: "+output[-800:])
    return output

def run(adb_path,serial,output_dir):
    artifact=prepare(adb_path,serial)
    print("SHORT_PROBE_PREPARED zones="+str(artifact["zones"]),flush=True)
    check=preflight(adb_path,serial)
    artifact["preflight_passed"]=True
    print("SHORT_PROBE_PREFLIGHT=PASS",flush=True)
    if output_dir.is_symlink():
        raise Refused("unsafe output directory symlink")
    output_dir.mkdir(mode=0o700,parents=True,exist_ok=True)
    boot=artifact["source_boot"]
    token=secrets.token_hex(16)
    witness_ready=threading.Event()
    witness_result={}
    def initial_identity(adb_path,serial):
        state=WITNESS.MAPPER.identity(adb_path,serial)
        if state["boot_id"]!=boot:
            raise Refused("witness saw different preprobe boot")
        witness_ready.set()
        return state
    def witness_thread():
        try:
            witness_result["report"]=WITNESS.observe(
                adb_path,serial,max_seconds=300,identity=initial_identity)
        except Exception as e:
            witness_result["error"]=str(e)
    watcher=threading.Thread(target=witness_thread,daemon=True)
    watcher.start()
    if not witness_ready.wait(timeout=25):
        raise Refused("host reboot witness could not establish preprobe boot")
    # The risk token is intentionally explicit. This is a real disruptive
    # command: Framework stop, XNU guest start, and mandatory reboot return.
    # Run in its own session, not within ADB's process group.
    launch=(
        "set -e; bb=; "
        "for p in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox "
        "/data/adb/magisk/busybox; do "
        "if test -x \"$p\"; then bb=\"$p\"; break; fi; done; "
        "test -n \"$bb\"; "
        f"\"$bb\" setsid /system/bin/sh {STAGE}/oneios_switch.sh "
        f"--framework-session probe {ACK} {token} {RISK} "
        f"</dev/null >{STAGE}/logs/probe-{token}.log 2>&1 &"
    )
    print("SHORT_PROBE_LAUNCHING_REAL_IOS_GUEST_90S",flush=True)
    try:
        remote_root(adb_path,serial,launch,timeout=12)
    except (Refused,INVENTORY.mapper.Blocked) as exc:
        # ADB may drop while Framework/reboot transitions, never silently
        # turn launch transport errors into a successful guest test.
        print("SHORT_PROBE_LAUNCH_TRANSPORT_UNCERTAIN "+str(exc),flush=True)
    deadline=time.monotonic()+305
    while watcher.is_alive() and time.monotonic()<deadline:
        watcher.join(timeout=2)
        # If switch rejected preflight before stopping Framework, stop early.
        try:
            log=remote_root(adb_path,serial,f"tail -n 12 {STAGE}/logs/probe-{token}.log",timeout=6)
            if "PREFLIGHT REFUSED" in log or "PREFLIGHT REFUSED:" in log:
                raise Refused("switch refused before Framework stop:\n"+log[-1200:])
        except (INVENTORY.mapper.Blocked,Refused) as exc:
            if "switch refused" in str(exc):
                raise
    if "report" not in witness_result:
        raise Refused("no independently observed healthy new One UI boot: "+
                      witness_result.get("error","host witness timeout"))
    artifact["witness"]=witness_result["report"]
    artifact["recovery_certified"]=False
    artifact["unassisted_return_proven"]=False
    artifact["p0_completed"]=False
    artifact["full_600s_takeover_allowed"]=False
    out=output_dir/("short-probe-"+datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")+
                    "-"+secrets.token_hex(3)+".json")
    with out.open("x",encoding="utf-8") as f:
        json.dump(artifact,f,indent=2,ensure_ascii=False)
        f.write("\n")
    out.chmod(0o600)
    print("SHORT_PROBE=NEW_NORMAL_ONEUI_BOOT_OBSERVED_AFTER_REAL_GUEST_ATTEMPT")
    print("HISTORICAL_RETURN_CORRELATED="+str(
        artifact["witness"]["historical_return_record_correlated_to_pre_smoke_boot"]).upper())
    print("UNASSISTED_RETURN=OPERATOR_ATTESTATION_REQUIRED")
    print("OUTPUT="+str(out))
    return 0

def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__)
    actions=p.add_mutually_exclusive_group()
    actions.add_argument("--prepare-probe",action="store_true")
    actions.add_argument("--run-90s",action="store_true")
    p.add_argument("--adb",default=str(Path.home()/"Android/Sdk/platform-tools/adb"))
    p.add_argument("--output",type=Path,default=Path("out/sm8850/short-ios-probe"))
    a=p.parse_args(argv)
    if not a.prepare_probe and not a.run_90s:
        print("SHORT_PROBE=AUDIT_NO_ADB. --prepare-probe stages guarded source without Framework stop.")
        print("Explicit --run-90s executes a real, bounded 90-second iOS takeover and mandatory reboot-only return.")
        print("Hardware watchdog/thermal critical limits and unassisted return are not yet certified.")
        return 0
    try:
        serial=INVENTORY.mapper.serial_for(a.adb)
        if a.prepare_probe:
            result=prepare(a.adb,serial)
            print("SHORT_PROBE_PREPARED_SOURCE_ONLY zones="+str(result["zones"]))
            print("PREFLIGHT=NOT_RUN; FRAMEWORK=NOT_STOPPED")
        else:
            return run(a.adb,serial,a.output)
    except (Refused,INVENTORY.mapper.Blocked,MANIFEST.Refused,
            WITNESS.MAPPER.Blocked,OSError,ValueError,subprocess.SubprocessError) as exc:
        print("SHORT_PROBE=BLOCKED_OR_UNVERIFIED "+str(exc),file=sys.stderr)
        return 4
    return 0

if __name__=="__main__":
    raise SystemExit(main())
