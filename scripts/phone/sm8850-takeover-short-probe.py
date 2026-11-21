#!/usr/bin/env python3
"""OneOS SM8850 bounded real iOS takeover probe (90s/300s profiles).

AUDIT by default; --prepare-probe stages verified switch + root thermal
guard + current-boot CPU/GPU/DDR manifest without stopping One UI.
Explicit --run-90s/--run-300s: same preparation, mandatory original
OneOS passive preflight, then starts real xnuhost behind a bounded
Framework-stop reboot-request deadline (NOT guest runtime).
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
CAP = ROOT/"switcher/assets/oneios_sm8850_thermal_cap.sh"
TELEMETRY = ROOT/"switcher/assets/oneios_sm8850_telemetry.sh"
RISK = "I_ACCEPT_SM8850_SHORT_TAKEOVER_90S_RISK"
RISK_300 = "I_ACCEPT_SM8850_SHORT_TAKEOVER_300S_RISK"
RISK_600 = "I_ACCEPT_SM8850_MONITOR_ONLY_600S_RISK"
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
    sha(SWITCH); sha(GUARD); sha(CAP); sha(TELEMETRY)
    before=INVENTORY.mapper.identity(adb_path,serial)
    # Guard the one-shot clone BEFORE uploading or changing any staged
    # switch/monitor source. Preflight-only validation used to miss this.
    clone_state=remote_root(adb_path,serial,(
        f"if test -e {STAGE}/data.consumed || test -L {STAGE}/data.consumed; "
        "then echo CONSUMED; "
        f"elif test -e {STAGE}/image.ready.rearm-pending || "
        f"test -L {STAGE}/image.ready.rearm-pending; "
        "then echo REARM_INCOMPLETE; else echo UNUSED; fi"
    ),timeout=10)
    if clone_state=="CONSUMED":
        raise Refused("APFS_DATA_CLONE=CONSUMED: rearm from the verified untouched "
                      "source in OneiOS; preserve consumed snapshot+marker. "
                      "Do not delete data.consumed or rerun either probe mode yet.")
    if clone_state!="UNUSED":
        raise Refused("APFS_DATA_CLONE="+clone_state+
                      ": stage requires manual integrity recovery before takeover.")
    snapshot=INVENTORY.collect(adb_path,serial)
    manifest,boot,zones=line_manifest(snapshot)
    if before!=INVENTORY.mapper.identity(adb_path,serial) or boot!=before["boot_id"]:
        raise Refused("stock One UI identity changed during current-boot sensor survey")
    nonce=secrets.token_hex(8)
    temp=f"/data/local/tmp/oneos-short-probe-{nonce}"
    installer_names={
        "oneios_switch.sh": SWITCH,
        "oneios_sm8850_thermal_takeover_guard.sh": GUARD,
        "oneios_sm8850_thermal_cap.sh": CAP,
        "oneios_sm8850_telemetry.sh": TELEMETRY,
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
                f"cp {temp}/oneios_sm8850_thermal_cap.sh {STAGE}/.cap.{nonce}; "
                f"cp {temp}/oneios_sm8850_telemetry.sh {STAGE}/.telemetry.{nonce}; "
                f"cp {temp}/thermal.guard.manifest {STAGE}/.manifest.{nonce}; "
                f"chown 0:0 {STAGE}/.switch.{nonce} {STAGE}/.guard.{nonce} {STAGE}/.cap.{nonce} {STAGE}/.telemetry.{nonce} {STAGE}/.manifest.{nonce}; "
                f"chmod 700 {STAGE}/.switch.{nonce} {STAGE}/.guard.{nonce} {STAGE}/.cap.{nonce} {STAGE}/.telemetry.{nonce}; "
                f"chmod 600 {STAGE}/.manifest.{nonce}; "
                f"mv -f {STAGE}/.switch.{nonce} {STAGE}/oneios_switch.sh; "
                f"mv -f {STAGE}/.guard.{nonce} {STAGE}/oneios_sm8850_thermal_takeover_guard.sh; "
                f"mv -f {STAGE}/.cap.{nonce} {STAGE}/oneios_sm8850_thermal_cap.sh; "
                f"mv -f {STAGE}/.telemetry.{nonce} {STAGE}/oneios_sm8850_telemetry.sh; "
                f"mv -f {STAGE}/.manifest.{nonce} {STAGE}/thermal.guard.manifest; "
                f"chmod 700 {STAGE}/oneios_switch.sh {STAGE}/oneios_sm8850_thermal_takeover_guard.sh {STAGE}/oneios_sm8850_thermal_cap.sh {STAGE}/oneios_sm8850_telemetry.sh; "
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
                    f"{temp}/oneios_sm8850_thermal_cap.sh {temp}/oneios_sm8850_telemetry.sh "
                    f"{temp}/thermal.guard.manifest; rmdir {temp}",timeout=15)
            except (Refused,INVENTORY.mapper.Blocked):
                raise Refused("temporary ADB upload cleanup unverified")
    return {"source_boot":boot,"zones":zones,"stage":STAGE,
            "switch_sha256":hashlib.sha256(SWITCH.read_bytes()).hexdigest(),
            "guard_sha256":hashlib.sha256(GUARD.read_bytes()).hexdigest(),
            "cap_sha256":hashlib.sha256(CAP.read_bytes()).hexdigest(),
            "telemetry_sha256":hashlib.sha256(TELEMETRY.read_bytes()).hexdigest(),
            "manifest_sha256":hashlib.sha256(manifest).hexdigest(),
            "preflight_passed":False}

def preflight(adb_path,serial):
    cmd=f"/system/bin/sh {STAGE}/oneios_switch.sh --framework-check probe"
    output=remote_root(adb_path,serial,cmd,timeout=90)
    if ("PREFLIGHT OK" not in output or
        "P0_THERMAL_GUARD=READ_ONLY_CURRENT_BOOT_READY_NOT_CERTIFIED" not in output or
        "P0_CPU_CAP=READ_ONLY_POLICY_AVAILABLE_NOT_CERTIFIED" not in output or
        "P0_FULL_600S_TAKEOVER=BLOCKED" in output):
        raise Refused("short probe thermal admission did not pass: "+output[-1000:])
    return output

def telemetry_comparison(raw_lines):
    """Pure, offline parse of the root read-only telemetry from current session.

    The first snapshot is valid only with *both* guest process log markers.
    The final snapshot is valid only when recorded at >=590 seconds after
    VERIFIED Framework stop; missing samples are never interpolated.
    """
    parsed={}
    order=[]
    for line in raw_lines:
        if not line.startswith("P0_TELEMETRY_"):
            continue
        name,sep,rest=line.partition(" ")
        if not sep:
            continue
        fields=dict(re.findall(r"([A-Za-z][A-Za-z_0-9]*)=([^\\s]+)",rest))
        try:
            seq=int(fields.get("seq","-1"))
        except ValueError:
            continue
        if seq<1:
            continue
        item=parsed.setdefault(seq,{"temperatures":{},"cpu":{},"gpu":{},"phase":None,"elapsed":None})
        if name=="P0_TELEMETRY_BEGIN":
            item["phase"]=fields.get("phase")
            try: item["elapsed"]=int(fields.get("elapsed_framework_s","-1"))
            except ValueError: item["elapsed"]=-1
            order.append(seq)
        elif name=="P0_TELEMETRY_TEMP":
            item["temperatures"][fields.get("zone","unknown")]={
                "type":fields.get("type","unknown"),"milli_c":fields.get("mc","UNAVAILABLE")}
        elif name=="P0_TELEMETRY_CPU":
            item["cpu"][fields.get("policy","unknown")]={
                "cur_khz":fields.get("cur_khz","UNAVAILABLE"),
                "max_khz":fields.get("max_khz","UNAVAILABLE"),
                "hwmax_khz":fields.get("hwmax_khz","UNAVAILABLE")}
        elif name=="P0_TELEMETRY_GPU":
            item["gpu"]=fields
    seqs=sorted(set(order))
    bases=[parsed[n] for n in seqs if parsed[n]["phase"]=="BASELINE"]
    ends=[parsed[n] for n in seqs if parsed[n]["phase"]=="FINAL" and parsed[n]["elapsed"] is not None and parsed[n]["elapsed"]>=590]
    baseline=bases[0] if bases else None
    final=ends[-1] if ends else None
    diffs=[]
    if baseline and final:
        def change(kind,key,first,last):
            try:
                av=int(first); bv=int(last)
                diffs.append(f"{kind} {key} initial={av} final={bv} delta={bv-av:+d}")
            except (TypeError,ValueError):
                diffs.append(f"{kind} {key} initial={first} final={last} delta=UNAVAILABLE")
        for zone,first in sorted(baseline["temperatures"].items()):
            last=final["temperatures"].get(zone,{})
            change("THERMAL",f"{zone}/{first['type']}",first["milli_c"],last.get("milli_c","UNAVAILABLE"))
        for pol,first in sorted(baseline["cpu"].items()):
            last=final["cpu"].get(pol,{})
            for key in ("cur_khz","max_khz"):
                change("CPU",f"{pol}/{key}",first[key],last.get(key,"UNAVAILABLE"))
        for key in ("clk","busy_pct","devfreq_cur","devfreq_max"):
            if key in baseline["gpu"] or key in final["gpu"]:
                change("GPU",key,baseline["gpu"].get(key,"UNAVAILABLE"),final["gpu"].get(key,"UNAVAILABLE"))
    return {"sample_count":len(seqs),"baseline":baseline,
            "final":final,"deltas":diffs,"comparison_complete":bool(baseline and final)}


def begin_preboot_host_log_stream(adb_path,serial,token,output_dir):
    """Capture the root-only switch log to the Linux host BEFORE reboot.

    DirtyFrag may lose su after the Framework stops or after kernel reboot.
    This root reader is established while stock One UI and su still work.
    Only the host-side output file is persistent; the reader never asks
    Android to reboot, stop Framework or modify watchdog/thermal settings.
    """
    if not re.fullmatch(r"[a-f0-9]{32}",token):
        raise Refused("invalid log token")
    remote=f"{STAGE}/logs/probe-{token}.log"
    local=output_dir/f"preboot-switch-{token}.log"
    # Create an empty, private, one-session log before starting the reader.
    # The switch's original > redirection then writes this exact inode.
    remote_root(adb_path,serial,f"umask 077; set -C; : > {remote}",timeout=10)
    sink=local.open("xb")
    try:
        proc=subprocess.Popen(
            [str(adb_path),"-s",serial,"shell","-T",
             f"su -c 'echo PREBOOT_ROOT_LOG_STREAM_READY; exec /system/bin/tail -n +1 -f {remote}'"],
            stdin=subprocess.DEVNULL,stdout=sink,stderr=subprocess.STDOUT)
    except BaseException:
        sink.close()
        raise
    # Popen alone is not proof the root reader survived su permission
    # checks: demand its own READY receipt while One UI is still intact.
    ready=False
    end=time.monotonic()+7
    while time.monotonic()<end:
        if proc.poll() is not None:
            break
        if local.stat().st_size:
            head=local.read_bytes()[:160]
            if b"PREBOOT_ROOT_LOG_STREAM_READY" in head:
                ready=True
                break
        time.sleep(0.2)
    if not ready:
        if proc.poll() is None:
            proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=3)
        sink.close()
        raise Refused("root ADB log stream never became ready while One UI was intact; NO guest launched")
    return proc,sink,local


def end_preboot_host_log_stream(proc,sink):
    if proc.poll() is None:
        proc.terminate()
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=3)
    sink.flush()
    sink.close()


def run(adb_path,serial,output_dir,duration_seconds=90):
    if duration_seconds not in (90,300,600):
        raise Refused("unsupported probe deadline")
    risk={90:RISK,300:RISK_300,600:RISK_600}[duration_seconds]
    artifact=prepare(adb_path,serial)
    artifact["reboot_request_deadline_after_framework_stop_seconds"]=duration_seconds
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
        if not witness_ready.is_set():
            if state["boot_id"]!=boot:
                raise Refused("witness saw different preprobe boot")
            witness_ready.set()
        return state
    def witness_thread():
        try:
            witness_result["report"]=WITNESS.observe(
                adb_path,serial,max_seconds=max(300,duration_seconds+250),identity=initial_identity)
        except Exception as e:
            witness_result["error"]=str(e)
    watcher=threading.Thread(target=witness_thread,daemon=True)
    watcher.start()
    if not witness_ready.wait(timeout=25):
        raise Refused("host reboot witness could not establish preprobe boot")
    # Root log capture must be opened BEFORE the guest can stop Framework.
    # The host file survives reboot and loss of ephemeral DirtyFrag su.
    stream_proc,stream_sink,stream_file=begin_preboot_host_log_stream(
        adb_path,serial,token,output_dir)
    artifact["preboot_host_log_path"]=str(stream_file)
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
        f"--framework-session probe {ACK} {token} {risk} "
        f"</dev/null >{STAGE}/logs/probe-{token}.log 2>&1 &"
    )
    try:
        print("SHORT_PROBE_REQUESTING_REAL_IOS_GUEST",flush=True)
        print(f"SHORT_PROBE_TIMEBASE=REBOOT_REQUEST_DEADLINE_{duration_seconds}S_AFTER_FRAMEWORK_STOP",flush=True)
        try:
            remote_root(adb_path,serial,launch,timeout=12)
        except (Refused,INVENTORY.mapper.Blocked) as exc:
            # ADB may drop while Framework/reboot transitions, never silently
            # turn launch transport errors into a successful guest test.
            print("SHORT_PROBE_LAUNCH_TRANSPORT_UNCERTAIN "+str(exc),flush=True)
        # Collect positive progress evidence WHILE the original boot/root may
        # still be available. After a real reboot temporary DirtyFrag su may be
        # unavailable, so a postboot tail alone is not a reliable guest verdict.
        milestones = {
            "thermal_guard_armed": False,
            "framework_stop": False,
            "xnuhost_launch": False,
        }
        live_log_excerpt = ""
        def observe_log(text):
            milestones["thermal_guard_armed"] |= (
                "P0_SHORT_PROBE_THERMAL=ARMED_ROOT_SENSOR_GUARD_NOT_PRODUCTION_CERTIFIED" in text
            )
            milestones["framework_stop"] |= (
                "Framework stopped, app groups drained" in text
            )
            milestones["xnuhost_launch"] |= (
                "=== ONEIOS SESSION LAUNCHED ===" in text
            )
    
        deadline=time.monotonic()+max(305,duration_seconds+250)
        while watcher.is_alive() and time.monotonic()<deadline:
            watcher.join(timeout=2)
            # If switch rejected preflight before stopping Framework, stop early.
            try:
                log=remote_root(adb_path,serial,f"tail -n 400 {STAGE}/logs/probe-{token}.log",timeout=6)
                observe_log(log)
                if log:
                    live_log_excerpt=log[-16000:]
                if "PREFLIGHT REFUSED" in log or "PREFLIGHT REFUSED:" in log:
                    raise Refused("switch refused before Framework stop:\n"+log[-1200:])
            except (INVENTORY.mapper.Blocked,Refused) as exc:
                if "switch refused" in str(exc):
                    raise
    finally:
        end_preboot_host_log_stream(stream_proc,stream_sink)
    streamed_log=stream_file.read_text(encoding="utf-8",errors="replace")
    artifact["preboot_host_log_bytes"]=stream_file.stat().st_size
    artifact["preboot_host_log_tail"]=streamed_log[-30000:]
    observe_log(streamed_log)
    if "report" not in witness_result:
        raise Refused("no independently observed healthy new One UI boot: "+
                      witness_result.get("error","host witness timeout"))
    # A healthy postboot alone does not demonstrate that xnuhost started.
    # Preserve source launch evidence separately from reboot observations.
    # DirtyFrag/root availability may change after an actual reboot. Host
    # witness of healthy One UI is still valid even if postboot su is gone.
    try:
        launch_log=remote_root(adb_path,serial,
                               f"tail -n 650 {STAGE}/logs/probe-{token}.log",timeout=12)
        artifact["postboot_root_log_accessible"]=True
    except (Refused,INVENTORY.mapper.Blocked):
        launch_log=""
        artifact["postboot_root_log_accessible"]=False
    observe_log(launch_log)
    artifact["switch_launch_log_tail"]=launch_log[-30000:]
    artifact["live_root_log_excerpt"]=live_log_excerpt
    artifact["framework_stop_confirmed_in_log"]=milestones["framework_stop"]
    artifact["xnuhost_launch_marker_observed"]=milestones["xnuhost_launch"]
    artifact["thermal_guard_armed_marker_observed"]=milestones["thermal_guard_armed"]
    artifact["guest_launch_evidence_complete"]=all(milestones.values())
    artifact["milestone_evidence_source"]=(
        "live_or_postboot_root_log" if all(milestones.values()) else
        "insufficient_log_evidence"
    )
    artifact["witness"]=witness_result["report"]
    artifact["recovery_certified"]=False
    artifact["unassisted_return_proven"]=False
    artifact["p0_completed"]=False
    artifact["full_600s_takeover_allowed"]=False
    artifact["monitor_only_600s_requested"]=duration_seconds==600
    artifact["script_temperature_abort_disabled"]=duration_seconds==600
    artifact["stock_kernel_or_firmware_thermal_modified"]=False
    out=output_dir/("short-probe-"+datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")+
                    "-"+secrets.token_hex(3)+".json")
    with out.open("x",encoding="utf-8") as f:
        json.dump(artifact,f,indent=2,ensure_ascii=False)
        f.write("\n")
    out.chmod(0o600)
    print("ONEUI_NEW_BOOT=OBSERVED_AFTER_PROBE_REQUEST")
    print("PREBOOT_HOST_LOG_CAPTURED_BYTES="+str(artifact["preboot_host_log_bytes"]))
    print("PREBOOT_HOST_LOG="+str(stream_file))
    print("POSTBOOT_ROOT_LOG_ACCESSIBLE="+str(
        artifact["postboot_root_log_accessible"]).upper())
    print("THERMAL_GUARD_ARMED="+str(artifact["thermal_guard_armed_marker_observed"]).upper())
    print("FRAMEWORK_STOP_MARKER="+str(artifact["framework_stop_confirmed_in_log"]).upper())
    print("XNUHOST_LAUNCH_MARKER="+str(artifact["xnuhost_launch_marker_observed"]).upper())
    print("HISTORICAL_RETURN_CORRELATED="+str(
        artifact["witness"]["historical_return_record_correlated_to_pre_smoke_boot"]).upper())
    print("UNASSISTED_RETURN=OPERATOR_ATTESTATION_REQUIRED")
    print("OUTPUT="+str(out))
    if not artifact["guest_launch_evidence_complete"]:
        print("SHORT_PROBE=INSUFFICIENT_GUEST_LAUNCH_EVIDENCE_NOT_PASS")
        return 4
    print("SHORT_PROBE=GUEST_LAUNCH_MARKERS_OBSERVED_RECOVERY_NOT_CERTIFIED")
    return 0

def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__)
    actions=p.add_mutually_exclusive_group()
    actions.add_argument("--prepare-probe",action="store_true")
    actions.add_argument("--run-90s",action="store_true")
    actions.add_argument("--run-300s",action="store_true")
    actions.add_argument("--run-600s",action="store_true")
    p.add_argument("--adb",default=str(Path.home()/"Android/Sdk/platform-tools/adb"))
    p.add_argument("--output",type=Path,default=Path("out/sm8850/short-ios-probe"))
    a=p.parse_args(argv)
    if not a.prepare_probe and not a.run_90s and not a.run_300s and not a.run_600s:
        print("SHORT_PROBE=AUDIT_NO_ADB. --prepare-probe stages guarded source without Framework stop.")
        print("90/300s: original software-temperature-abort profile. 600s: explicit software-temperature-LOG-ONLY profile.")
        print("These durations are reboot-request deadlines since verified Framework stop, NOT full iOS interactive uptime.")
        print("Kernel/firmware thermal controls remain intact but some Samsung user-space thermal HAL may stop with Android Framework.")
        print("Legacy watchdog, unassisted recovery and thermal control remain unqualified on SM8850.")
        return 0
    try:
        serial=INVENTORY.mapper.serial_for(a.adb)
        if a.prepare_probe:
            result=prepare(a.adb,serial)
            print("SHORT_PROBE_PREPARED_SOURCE_ONLY zones="+str(result["zones"]))
            print("PREFLIGHT=NOT_RUN; FRAMEWORK=NOT_STOPPED")
        else:
            return run(a.adb,serial,a.output,600 if a.run_600s else (300 if a.run_300s else 90))
    except (Refused,INVENTORY.mapper.Blocked,MANIFEST.Refused,
            WITNESS.MAPPER.Blocked,OSError,ValueError,subprocess.SubprocessError) as exc:
        print("SHORT_PROBE=BLOCKED_OR_UNVERIFIED "+str(exc),file=sys.stderr)
        return 4
    return 0

if __name__=="__main__":
    raise SystemExit(main())
