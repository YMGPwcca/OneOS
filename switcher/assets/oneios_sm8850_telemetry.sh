#!/system/bin/sh
# Read-only SM8850 sysfs sampler. No sysfs writes, reboot, or watchdog calls.
set -u
umask 077
die() { echo "P0_TELEMETRY=BLOCKED_$1" >&2; exit 4; }
readn() { if [ -r "$1" ]; then cat "$1" 2>/dev/null || echo UNAVAILABLE; else echo UNAVAILABLE; fi; }
mono() { read -r time rest < /proc/uptime || return 1; echo "${time%%.*}"; }
emit() { printf '%s\n' "$*" >> "$LOG" && printf '%s\n' "$*"; }
snapshot() {
    phase=$1 sec=$2
    SEQ=$((SEQ+1))
    bb=NO; sb=NO; ready=NO
    grep -Fq 'backboardd[' "$SESSION/xnuhost.log" 2>/dev/null && bb=LOG_MARKER
    grep -Fq 'SpringBoard[' "$SESSION/xnuhost.log" 2>/dev/null && sb=LOG_MARKER
    [ ! -f "$SESSION/ready" ] || ready=READY_MARKER
    emit "P0_TELEMETRY_BEGIN seq=$SEQ phase=$phase elapsed_framework_s=$sec backboardd=$bb SpringBoard=$sb first_frame=$ready"
    emit "P0_TELEMETRY_STATE seq=$SEQ guard=$(readn "$CTL/thermal.guard.heartbeat") cap=$(readn "$CTL/thermal.cap.heartbeat")"
    count=0
    for z in /sys/class/thermal/thermal_zone[0-9]*; do
        [ -d "$z" ] || continue
        count=$((count+1))
        [ "$count" -le 256 ] || break
        emit "P0_TELEMETRY_TEMP seq=$SEQ zone=${z##*/} type=$(readn "$z/type") mc=$(readn "$z/temp")"
    done
    count=0
    for p in /sys/devices/system/cpu/cpufreq/policy[0-9]*; do
        [ -d "$p" ] || continue
        count=$((count+1))
        [ "$count" -le 16 ] || break
        emit "P0_TELEMETRY_CPU seq=$SEQ policy=${p##*/} cores=$(readn "$p/affected_cpus") cur_khz=$(readn "$p/scaling_cur_freq") max_khz=$(readn "$p/scaling_max_freq") min_khz=$(readn "$p/scaling_min_freq") hwmax_khz=$(readn "$p/cpuinfo_max_freq")"
    done
    g=/sys/class/kgsl/kgsl-3d0
    emit "P0_TELEMETRY_GPU seq=$SEQ clk=$(readn "$g/gpuclk") busy_pct=$(readn "$g/gpu_busy_percentage") devfreq_cur=$(readn "$g/devfreq/cur_freq") devfreq_max=$(readn "$g/devfreq/max_freq")"
    for d in /sys/class/devfreq/*; do
        [ -d "$d" ] || continue
        case "${d##*/}" in *kgsl*|*gpu*|*3d*) emit "P0_TELEMETRY_GPU_DF seq=$SEQ dev=${d##*/} cur=$(readn "$d/cur_freq") max=$(readn "$d/max_freq")" ;; esac
    done
    emit "P0_TELEMETRY_END seq=$SEQ phase=$phase"
}
case "${1:-}" in
  --audit) [ "$#" = 1 ] || die args; echo "P0_TELEMETRY=AUDIT_NO_ADB_NO_SYSFS_WRITES"; exit 0 ;;
  --run)
    [ "$#" = 5 ] && [ "$(id -u)" = 0 ] || die args_or_root
    CTL=$2; GEN=$3; TOKEN=$4; DURATION=$5
    [ "$CTL" = /data/adb/oneios-m3q-framework/control ] && [ "$DURATION" = 600 ] || die scope
    case "$TOKEN" in ''|*[!0-9a-f]*) die token ;; esac
    [ "${#TOKEN}" -eq 32 ] || die token
    [ -d "$CTL" ] && [ ! -L "$CTL" ] && [ "$(stat -c %u "$CTL")" = 0 ] || die untrusted_control
    BOOT=$(readn "$CTL/boot")
    [ "$BOOT" = "$(readn /proc/sys/kernel/random/boot_id)" ] &&
      [ "$GEN" = "$(readn "$CTL/watchdog.generation")" ] &&
      [ "$(readn "$CTL/framework.mode")" = probe ] || die identity
    SESSION=/data/adb/oneios-m3q-framework/session
    LOG=/data/adb/oneios-m3q-framework/logs/telemetry-$TOKEN.log
    [ -d "$SESSION" ] && [ ! -L "$SESSION" ] && [ ! -L "$LOG" ] && [ ! -e "$LOG" ] || die unsafe_log
    : > "$LOG" && chmod 600 "$LOG" || die logfile
    deadline=$(readn "$CTL/framework.deadline")
    case "$deadline" in ''|*[!0-9]*) die deadline ;; esac
    start=$((deadline-600))
    [ "$start" -ge 1 ] || die start
    emit "P0_TELEMETRY_START every_s=15 first=SpringBoard_and_backboardd final=framework_stop_plus_590 log=$LOG"
    SEQ=0; NEXT=$start; BASE=0; FINAL=0
    while [ "$GEN" = "$(readn "$CTL/watchdog.generation")" ]; do
      case "$(readn "$CTL/state")" in starting|running) ;; *) break ;; esac
      now=$(mono) || break
      elapsed=$((now-start))
      [ "$elapsed" -lt 600 ] || break
      if [ "$BASE" = 0 ] && grep -Fq 'backboardd[' "$SESSION/xnuhost.log" 2>/dev/null &&
         grep -Fq 'SpringBoard[' "$SESSION/xnuhost.log" 2>/dev/null; then
         snapshot BASELINE "$elapsed" || break; BASE=1
      fi
      if [ "$FINAL" = 0 ] && [ "$elapsed" -ge 590 ]; then
         snapshot FINAL "$elapsed" || break; FINAL=1
      fi
      if [ "$now" -ge "$NEXT" ]; then
         snapshot PERIODIC "$elapsed" || break; NEXT=$((now+15))
      fi
      sleep 1
    done
    emit "P0_TELEMETRY_STOP samples=$SEQ baseline=$BASE final=$FINAL"
    exit 0 ;;
  *) die usage ;;
esac
