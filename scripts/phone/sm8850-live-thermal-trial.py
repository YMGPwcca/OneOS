#!/usr/bin/env python3
"""One UI-only root thermal monitor + separate supervisor trial (FINITE).

Defaults to no-ADB audit. Explicit --run-readonly performs a fresh bounded
CPU/GPU/DDR survey on intact SM-S948B/m3q stock One UI, stages one rooted
read-only shell observer in private /data/local/tmp, verifies SHA256, runs
NORMAL and a safe WORKER-EXITS-EARLY scenario, requires independent watcher
alert *without* invoking return/reboot, and removes only its staging files.

NOT a production guard, no Framework stop, no watchdog, no return.request,
no governor/sysfs writes or 600-second takeover.
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
import time

HERE=Path(__file__).resolve().parent
ROOT=HERE.parent.parent
SHELL=ROOT/'switcher/assets/oneios_sm8850_thermal_trial.sh'

def load(path, name):
    spec=importlib.util.spec_from_file_location(name,path)
    mod=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

INVENTORY=load(HERE/'sm8850-thermal-junction-inventory.py','sm8850_trial_inventory')
MANIFEST=load(HERE/'sm8850-thermal-manifest.py','sm8850_trial_manifest')

class Refused(Exception): pass

def invoke(adb, serial, *args, timeout=12):
    result=INVENTORY.mapper.adb_call(adb,serial,args,timeout=timeout)
    if result.returncode:
        raise Refused('ADB failure %s exit=%d %s' % (repr(args[:2]),result.returncode,(result.stderr or '')[:180]))
    return result.stdout.strip()

def create_line_manifest(report):
    """Validate complete survey first, then use strict non-executable text."""
    manifest=MANIFEST.validate(report)
    boot=manifest['device']['boot_id']
    rows=manifest['zones']
    lines=[f'v1 {boot} {len(rows)}']
    for z in rows:
        lines.append(f"z {z['index']} {z['type']} {z['group']}")
    return ('\n'.join(lines)+'\n').encode(),boot,len(rows)

def source_hash(path=SHELL):
    if not path.is_file() or path.is_symlink():
        raise Refused('audited observer source missing or symlinked')
    data=path.read_bytes()
    if not data.startswith(b'#!/system/bin/sh\n'):
        raise Refused('audited observer header mismatch')
    check=subprocess.run(['sh','-n',str(path)],capture_output=True,text=True,timeout=5)
    if check.returncode:
        raise Refused('observer POSIX syntax failed')
    return hashlib.sha256(data).hexdigest()

def remote_clean(adb, serial, stage):
    # The controlled nonce constrains all paths. Remove only the private files
    # created by this diagnostic, not arbitrary /data/adb or OneOS control.
    if not re.fullmatch(r'/data/local/tmp/oneos-p0-live-[a-f0-9]{16}',stage):
        raise Refused('unsafe cleanup stage path')
    names=('oneios_sm8850_thermal_trial.sh','manifest.v1','identity.v1',
           'monitor.identity','monitor.snapshot','monitor.heartbeat','monitor.done','monitor.fault',
           'supervisor.identity','trial.identity','trial.out','trial.parent')
    files=' '.join(stage+'/'+name for name in names)
    # Temporary writes have suffix .tmp.<pid>; remove only manifest-defined
    # tmp artifacts in this private staging directory.
    command=f"su -c 'rm -f {files} {stage}/monitor.*.tmp.* && rmdir {stage}'"
    invoke(adb,serial,'shell','-T',command,timeout=20)

def run_trial(adb, serial, source=SHELL, detached=False):
    source_sha=source_hash(source)
    before=INVENTORY.mapper.identity(adb,serial)
    survey=INVENTORY.collect(adb,serial)
    lines,boot,zones=create_line_manifest(survey)
    if INVENTORY.mapper.identity(adb,serial)!=before or boot!=before['boot_id']:
        raise Refused('Android identity drifted across sensor discovery')
    nonce=secrets.token_hex(8)
    stage='/data/local/tmp/oneos-p0-live-'+nonce
    launched=False
    clean_error=None
    results=[]
    with tempfile.TemporaryDirectory(prefix='oneos-p0-live-host-') as tmp:
        folder=Path(tmp)
        manifest=folder/'manifest.v1'
        manifest.write_bytes(lines)
        identity=folder/'identity.v1'
        identity.write_text(f'v1 {boot} shadow-{nonce} {secrets.token_hex(16)}\n')
        sources=[(source,'oneios_sm8850_thermal_trial.sh'),
                 (manifest,'manifest.v1'),(identity,'identity.v1')]
        try:
            invoke(adb,serial,'shell','mkdir',stage)
            launched=True
            invoke(adb,serial,'shell','chmod','700',stage)
            for file,name in sources:
                remote=f'{stage}/{name}'
                invoke(adb,serial,'push',str(file),remote,timeout=15)
                expected=hashlib.sha256(file.read_bytes()).hexdigest()
                digest_fields=invoke(adb,serial,'shell','sha256sum',remote).split()
                if not digest_fields or expected!=digest_fields[0]:
                    raise Refused('stage SHA mismatch or empty hash for '+name)
            # Shell owns the directory only while staging. Transfer ownership
            # to root before ANY monitor starts; otherwise uid=shell could
            # replace a live heartbeat/manifest and spoof supervisor health.
            # Avoid recursive chown: only these four exact, nonce-bound paths.
            paths=' '.join([stage]+[stage+'/'+name for _,name in sources])
            invoke(adb,serial,'shell','-T',
                   "su -c 'chown 0:0 "+paths+
                   " && chmod 700 "+stage+' '+stage+'/oneios_sm8850_thermal_trial.sh'+
                   " && chmod 600 "+stage+'/manifest.v1 '+stage+"/identity.v1'",
                   timeout=12)
            for _,name in sources:
                remote=f'{stage}/{name}'
                uid=invoke(adb,serial,'shell','-T',
                           "su -c 'stat -c %u "+remote+"'")
                if uid!='0':
                    raise Refused('root ownership verification failed: '+name)
                # Re-hash after ownership transfer in the root-owned stage.
                # Pre-chown ADB validation alone permits a replacement race.
                root_digest=invoke(adb,serial,'shell','-T',
                    "su -c 'sha256sum "+remote+"'").split()
                local_source=next(path for path, source_name in sources if source_name==name)
                if not root_digest or root_digest[0]!=hashlib.sha256(local_source.read_bytes()).hexdigest():
                    raise Refused('root-owned staged SHA-256 changed: '+name)
            if invoke(adb,serial,'shell','-T',
                      "su -c 'stat -c %u "+stage+"'")!='0':
                raise Refused('root staging directory ownership check failed')
            if detached:
                # Launch a bounded root-only trial in a NEW session with
                # stdin/out/err disconnected from its original adb shell.
                # Reconnect separately to read the completion receipts.
                cmd=(f"su -c 'command -v setsid >/dev/null 2>&1 || exit 10; "
                     f"setsid /system/bin/sh {stage}/oneios_sm8850_thermal_trial.sh "
                     f"--live-oneui-readonly {stage} 4 normal >{stage}/trial.out "
                     f"2>&1 </dev/null & echo $! >{stage}/trial.parent'")
                invoke(adb,serial,'shell','-T',cmd,timeout=12)
                accepted='THERMAL_TRIAL=PASS_OBSERVER_SUPERVISOR_ONLY_NO_PHYSICAL_RETURN'
                output=''
                for _ in range(35):
                    result=INVENTORY.mapper.adb_call(adb,serial,
                        ('shell','-T',f"su -c 'cat {stage}/trial.out'"),timeout=7)
                    if result.returncode == 0:
                        output=result.stdout.strip()
                        if accepted in output:
                            break
                        if 'THERMAL_TRIAL=BLOCKED_' in output:
                            raise Refused('detached worker reported failure')
                    time.sleep(1)
                else:
                    raise Refused('detached root trial has no bounded completion receipt')
                if ('MONITOR=FINITE_SMOKE_DONE samples=4 physical_return=NO' not in output
                    or 'SUPERVISOR=MONITOR_COMPLETED_SEPARATE_PID samples=4 physical_return=NO' not in output):
                    raise Refused('detached worker/supervisor receipt absent')
                def receipt(name):
                    return invoke(adb,serial,'shell','-T',
                        f"su -c 'cat {stage}/{name}'").split()
                parent=receipt('trial.identity')
                monitor=receipt('monitor.identity')
                supervisor=receipt('supervisor.identity')
                if (len(parent)!=3 or len(monitor)!=2 or len(supervisor)!=2 or
                    not all(part.isdecimal() for part in parent+monitor+supervisor) or
                    parent[0]!=parent[2] or  # setsid: new leader SID == PID
                    len({parent[0],monitor[0],supervisor[0]})!=3):
                    raise Refused('detached session or distinct PID evidence invalid')
                results=[{'scenario':'detached-normal','stdout':output,
                          'evidence':accepted,'trial_pid':parent[0],
                          'worker_pid':monitor[0],'supervisor_pid':supervisor[0]}]
            else:
                for fault,ticks,marker in (
                    ('normal',3,'THERMAL_TRIAL=PASS_OBSERVER_SUPERVISOR_ONLY_NO_PHYSICAL_RETURN'),
                    ('monitor-exit-after-two',4,'THERMAL_TRIAL=EXPECTED_MONITOR_DEATH_DETECTED_NO_PHYSICAL_RETURN'),
                ):
                    # The two scenarios need distinct stages to avoid stale
                    # monitor.done, fault and heartbeat metadata from a prior run.
                    # Remove own control outputs before each scenario only.
                    if results:
                        invoke(adb,serial,'shell','-T',
                               "su -c 'rm -f "+' '.join(stage+'/'+n for n in
                               ('monitor.identity','monitor.snapshot','monitor.heartbeat','monitor.done','monitor.fault'))+"'",
                               timeout=12)
                    cmd=f"su -c '/system/bin/sh {stage}/oneios_sm8850_thermal_trial.sh --live-oneui-readonly {stage} {ticks} {fault}'"
                    output=invoke(adb,serial,'shell','-T',cmd,timeout=90)
                    if marker not in output:
                        raise Refused('expected observer/supervisor result absent: '+fault)
                    if fault == 'normal':
                        if ('MONITOR=FINITE_SMOKE_DONE samples=3 physical_return=NO' not in output or
                            'SUPERVISOR=MONITOR_COMPLETED_SEPARATE_PID' not in output):
                            raise Refused('normal monitor/supervisor proof absent')
                    else:
                        if ('MONITOR=INJECTED_EXIT_NO_REBOOT' not in output or
                            'SUPERVISOR=WOULD_REQUEST_RETURN_NOT_EXECUTED reason=monitor_dead' not in output):
                            raise Refused('monitor death did not trigger supervisor alert')
                    results.append({'scenario':fault,'stdout':output,'evidence':marker})
            if INVENTORY.mapper.identity(adb,serial)!=before:
                raise Refused('Android identity changed after live trial')
        finally:
            if launched:
                try: remote_clean(adb,serial,stage)
                except (Refused,INVENTORY.mapper.Blocked) as exc: clean_error=exc
    if clean_error:
        raise Refused('diagnostic staging cleanup not verified') from clean_error
    return {'schema':1,'kind':'SM8850_ROOT_THERMAL_SIBLING_PROCESSES_READONLY_SMOKE',
            'device':before,'zone_count':zones,'source_sha256':source_sha,
            'sensor_group_peaks':survey['hottest_by_group'],'runs':results,
            'monitor_and_supervisor_are_sibling_processes':True,
            'launcher_adb_command_detach_tested':detached,
            'independent_after_framework_stop_proven':False,
            'supervisor_death_watchdog_proven':False,
            'vendor_thermal_limits_qualified':False,
            'physical_return_issued':False,'recovery_certified':False,
            'p0_complete':False,'long_takeover_allowed':False,
            'acceptance':'LIVE_ROOT_SHADOW_ONLY_NOT_RECOVERY_QUALIFIED'}

def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__)
    mode=p.add_mutually_exclusive_group()
    mode.add_argument('--run-readonly',action='store_true')
    mode.add_argument('--run-detached-readonly',action='store_true')
    p.add_argument('--adb',default=str(Path.home()/'Android/Sdk/platform-tools/adb'))
    p.add_argument('--output',type=Path,default=Path('out/sm8850/live-thermal-trial'))
    args=p.parse_args(argv)
    if not args.run_readonly and not args.run_detached_readonly:
        print('LIVE_THERMAL=AUDIT_ONLY_NO_ADB; real root monitor and sibling heartbeat supervisor')
        print('3 normal snapshots + safe monitor-exit fault; no return/reboot/watchdog/Framework stop')
        return 0
    try:
        serial=INVENTORY.mapper.serial_for(args.adb)
        report=run_trial(args.adb,serial,detached=args.run_detached_readonly)
        args.output.mkdir(parents=True,exist_ok=True,mode=0o700)
        file=args.output/('root-thermal-smoke-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+secrets.token_hex(3)+'.json')
        with file.open('x',encoding='utf-8') as fh:
            json.dump(report,fh,indent=2)
            fh.write('\n')
        file.chmod(0o600)
    except (Refused,INVENTORY.mapper.Blocked,MANIFEST.Refused,subprocess.SubprocessError,OSError,ValueError) as e:
        print('LIVE_THERMAL=BLOCKED_NOT_QUALIFIED '+str(e),file=sys.stderr)
        return 4
    print('LIVE_THERMAL=ROOT_OBSERVER_AND_SUPERVISOR_TESTED_NO_PHYSICAL_RETURN')
    print('ZONES='+str(report['zone_count']))
    for run in report['runs']:
        print('SCENARIO='+run['scenario'])
        print(run['stdout'])
    print('P0_RECOVERY=NOT_QUALIFIED')
    print('OUTPUT='+str(file))
    return 0

if __name__=='__main__':
    raise SystemExit(main())
