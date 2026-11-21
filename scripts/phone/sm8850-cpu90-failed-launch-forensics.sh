#!/usr/bin/env bash
# Read-only diagnosis of an existing CPU90 physical attempt.
# Reads local host logs and fixed on-phone root-owned evidence files.
# NO rearm, NO Framework stop, NO reboot, NO guest, NO watchdog opens.
set -Eeuo pipefail
umask 077
[[ $# -eq 1 ]] || { echo "Usage: bash -s -- /path/to/live-300s-attempt" >&2; exit 2; }
OUT=$(realpath -e -- "$1")
case "$OUT" in
  "$HOME"/projects/OneiOS/out/sm8850/p0-physical/live-300s-*) ;;
  *) echo "REFUSED=UNEXPECTED_EVIDENCE_PATH" >&2; exit 2 ;;
esac
[[ -d "$OUT/probe" && -f "$OUT/serial.txt" ]] || {
  echo "REFUSED=INCOMPLETE_ATTEMPT_FOLDER" >&2
  exit 2
}
SERIAL=$(tr -d '\r\n' < "$OUT/serial.txt")
case "$SERIAL" in
  ''|*[!a-zA-Z0-9_-]*) echo "REFUSED=INVALID_SAVED_SERIAL" >&2; exit 2 ;;
esac
STAGE=/data/adb/oneios-m3q-framework
ADB="${ONEOS_ADB:-$HOME/Android/Sdk/platform-tools/adb}"
REPORT="$OUT/cpu90-readonly-forensics-$(date -u +%Y%m%dT%H%M%SZ).log"
{
  echo "===== HOST-SIDE P0 EVIDENCE ====="
  echo "PHONE_WRITES=NONE; FRAMEWORK_STOP=NONE; APFS_REARM=NONE; REBOOT=NONE"
  for f in "$OUT"/probe/preboot-switch-*.log \
           "$OUT"/thermal-guard-preboot-stream.log \
           "$OUT"/console.log "$OUT"/post-oneui.txt \
           "$OUT"/post-root-records/control_state.txt \
           "$OUT"/post-root-records/control_thermal.guard.fault.txt; do
    [[ -f "$f" ]] || continue
    echo "----- HOST FILE: ${f#"$OUT"/} -----"
    tail -n 120 "$f" || :
  done
  echo "===== CURRENT PHONE READ-ONLY RECEIPTS ====="
  if [[ ! -x "$ADB" ]]; then
    echo "ADB_NOT_FOUND"
  elif ! timeout 10s "$ADB" -s "$SERIAL" get-state 2>/dev/null | grep -qx device; then
    echo "ADB_NOT_CONNECTED"
  else
    echo "ADB_CONNECTED"
    timeout 10s "$ADB" -s "$SERIAL" shell -T \
      'printf "current_boot="; cat /proc/sys/kernel/random/boot_id; printf "boot_completed="; getprop sys.boot_completed; printf "zygote="; getprop init.svc.zygote; printf "system_server="; pidof system_server || true' || :
    if timeout 10s "$ADB" -s "$SERIAL" shell -T "su -c 'id -u'" 2>/dev/null |
       tr -d '\r\n' | grep -qx 0; then
      echo "ROOT_AVAILABLE_READ_ONLY"
      timeout 15s "$ADB" -s "$SERIAL" shell -T \
        "su -c 'if test -e $STAGE/data.consumed; then echo APFS_CLONE=CONSUMED; elif test -e $STAGE/image.ready.rearm-pending; then echo APFS_CLONE=REARM_INCOMPLETE; else echo APFS_CLONE=NO_CONSUMED_MARKER; fi; sha256sum $STAGE/oneios_sm8850_thermal_takeover_guard.sh'" || :
      for f in "$OUT"/probe/preboot-switch-*.log; do
        [[ -f "$f" ]] || continue
        token=$(basename "$f")
        token=${token#preboot-switch-}
        token=${token%.log}
        [[ "$token" =~ ^[a-f0-9]{32}$ ]] || continue
        echo "===== STAGED PROBE LOG (CURRENT ROOT) ====="
        timeout 15s "$ADB" -s "$SERIAL" shell -T \
          "su -c 'if test -f $STAGE/logs/probe-$token.log && test ! -L $STAGE/logs/probe-$token.log; then tail -c 32768 $STAGE/logs/probe-$token.log; else echo STAGED_LOG_ABSENT; fi'" || :
      done
      for rel in control/boot control/state control/framework.mode \
                 control/framework.launch control/framework.deadline \
                 control/framework.cutoff control/watchdog.phase \
                 control/thermal.guard.fault session/return.request \
                 return.outcome return.log; do
        echo "----- ROOT RECORD: $rel -----"
        timeout 12s "$ADB" -s "$SERIAL" shell -T \
          "su -c 'if test -f $STAGE/$rel && test ! -L $STAGE/$rel; then tail -c 2048 $STAGE/$rel; else echo RECORD_ABSENT; fi'" || :
      done
    else
      echo "ROOT_UNAVAILABLE"
    fi
  fi
  echo "NO_REBOOT_OBSERVED_DOES_NOT_PROVE_SWITCH_NEVER_STARTED"
  echo "APFS_CONSUMED_DOES_NOT_PROVE_GUEST_EXECUTED"
  echo "READ_ONLY_FORENSICS=COMPLETE"
} 2>&1 | tee "$REPORT"
echo "LOCAL_FORENSICS_LOG=$REPORT"
