#!/system/bin/sh
# OneOS SM8850 P0: real ROOT thermal observer + separate heartbeat supervisor.
# Purpose: safely qualify process independence and liveness on *running* One UI.
# NO reboot, return.request, Framework stop, watchdog, governor or sysfs writes.
# This is a deliberately FINITE live smoke, NOT a production safety guard.
set -u
LC_ALL=C; export LC_ALL

usage() {
    echo 'usage: thermal_trial.sh --live-oneui-readonly STAGE TICKS [normal|monitor-exit-after-two] | --fixture-root ROOT STAGE TICKS [normal|monitor-exit-after-two]' >&2
    exit 2
}
blocked() { echo "THERMAL_TRIAL=BLOCKED reason=$1 physical_return=NO" >&2; exit 4; }
[ "$#" -ge 1 ] || usage
MODE=$1
case "$MODE" in
    --live-oneui-readonly)
        [ "$#" -ge 4 ] && [ "$#" -le 6 ] || usage
        ROOT=''; STAGE=$2; TICKS=$3; FAULT=$4
        INTERNAL=${5:-}; TARGET=${6:-}
        case "$STAGE" in /data/local/tmp/oneos-p0-live-*) ;; *) usage ;; esac
        [ "$(id -u)" = 0 ] || blocked root_required
        [ "$(getprop ro.product.model)" = SM-S948B ] &&
        [ "$(getprop ro.product.device)" = m3q ] &&
        [ "$(getprop ro.build.version.incremental)" = S948BXXS4BZIG ] &&
        [ "$(getprop sys.boot_completed)" = 1 ] &&
        [ "$(getenforce)" = Enforcing ] &&
        pidof system_server >/dev/null 2>&1 || blocked requires_stock_oneui
        ;;
    --fixture-root)
        [ "$#" -ge 5 ] && [ "$#" -le 7 ] || usage
        ROOT=$2; STAGE=$3; TICKS=$4; FAULT=$5
        INTERNAL=${6:-}; TARGET=${7:-}
        case "$ROOT" in /tmp/*) ;; *) usage ;; esac
        case "$STAGE" in /tmp/oneos-p0-live-*) ;; *) usage ;; esac
        [ -d "$ROOT" ] && [ ! -L "$ROOT" ] || usage
        ROOT=$(realpath "$ROOT" 2>/dev/null) || usage
        case "$ROOT" in /tmp/?*) ;; *) usage ;; esac
        ;;
    *) usage ;;
esac
case "$TICKS" in 2|3|4|5|6) ;; *) usage ;; esac
case "$FAULT" in normal|monitor-exit-after-two) ;; *) usage ;; esac
[ -d "$STAGE" ] && [ ! -L "$STAGE" ] || blocked invalid_stage
[ -f "$STAGE/manifest.v1" ] && [ ! -L "$STAGE/manifest.v1" ] || blocked manifest_missing
[ -f "$STAGE/identity.v1" ] && [ ! -L "$STAGE/identity.v1" ] || blocked identity_missing
if [ "$MODE" = --fixture-root ]; then
    for f in "$STAGE/manifest.v1" "$STAGE/identity.v1"; do
        case "$(realpath "$f" 2>/dev/null)" in "$STAGE"/*) ;; *) blocked fixture_file_escape ;; esac
    done
fi
SELF=$0
[ -f "$SELF" ] || blocked source_missing
if [ "$MODE" = --live-oneui-readonly ]; then
    # The stage and source must be root-owned BEFORE any monitor starts.
    # A shell-owned directory can replace heartbeat or sensor mapping.
    [ "$(stat -c %u "$STAGE" 2>/dev/null)" = 0 ] &&
    [ "$(stat -c %u "$STAGE/manifest.v1" 2>/dev/null)" = 0 ] &&
    [ "$(stat -c %u "$STAGE/identity.v1" 2>/dev/null)" = 0 ] &&
    [ "$(stat -c %u "$SELF" 2>/dev/null)" = 0 ] || blocked untrusted_stage_owner
fi

# A random private stage from the host has a fake, never-production launch ID.
set -f
IDENT=$(cat "$STAGE/identity.v1" 2>/dev/null) || blocked invalid_identity
set -- $IDENT
[ "$#" = 4 ] && [ "$1" = v1 ] || blocked identity_schema
EXPECTED_BOOT=$2; GEN=$3; LAUNCH=$4
printf '%s\n' "$EXPECTED_BOOT" | grep -Eq '^[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' || blocked boot_format
case "$GEN" in shadow-[a-f0-9]*) ;; *) blocked bad_generation ;; esac
case "$LAUNCH" in *[!a-f0-9]*|'') blocked bad_launch ;; esac
[ "${#LAUNCH}" = 32 ] || blocked launch_length

BOOTFILE="$ROOT/proc/sys/kernel/random/boot_id"
[ "$(cat "$BOOTFILE" 2>/dev/null)" = "$EXPECTED_BOOT" ] || blocked stale_boot
uptime_ms() {
    # Fixture timer intentionally uses host /proc/uptime, not a user-supplied clock.
    awk 'NR==1 { printf "%.0f", $1 * 1000 }' /proc/uptime
}
birth_ticks() {
    # Linux starttime, field 22; proc comm may contain whitespace/parentheses.
    sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | awk '$1!="Z" && $1!="X" && $20 ~ /^[0-9]+$/ {print $20; exit}'
}
num() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 13 ] || return 1
    return 0
}
valid_name() {
    case "$1" in
        cpu-hw-trip-*) return 1 ;;
        cpu-*|cpuss-*) [ "$2" = cpu ] ;;
        gpuss-*) [ "$2" = gpu ] ;;
        ddr) [ "$2" = ddr ] ;;
        xo-therm) [ "$2" = xo ] ;;
        *) return 1 ;;
    esac
}

sample_all() {
    BEFORE=$(cat "$BOOTFILE" 2>/dev/null) || return 1
    [ "$BEFORE" = "$EXPECTED_BOOT" ] || return 1
    TEMP_MANIFEST="$STAGE/manifest.v1"
    count=0; seen_indices=" "; cpu=0; gpu=0; ddr=0; cpu_peak=0; gpu_peak=0; ddr_peak=0
    # Read from one FD without a pipeline or subshell: group counters persist.
    {
        IFS= read -r HEADER || return 1
        set -- $HEADER
        [ "$#" = 3 ] && [ "$1" = v1 ] && [ "$2" = "$EXPECTED_BOOT" ] || return 1
        EXPECTED_COUNT=$3
        num "$EXPECTED_COUNT" && [ "$EXPECTED_COUNT" -ge 3 ] && [ "$EXPECTED_COUNT" -le 96 ] || return 1
        while read -r MARK IDX NAME GROUP EXTRA; do
            [ "$MARK" = z ] && [ -z "$EXTRA" ] && num "$IDX" && [ "$IDX" -le 255 ] || return 1
            case "$seen_indices" in *" $IDX "*) return 1 ;; esac
            seen_indices="$seen_indices$IDX "
            case "$NAME" in ''|*[!a-zA-Z0-9._-]*) return 1 ;; esac
            valid_name "$NAME" "$GROUP" || return 1
            TYPE_FILE="$ROOT/sys/class/thermal/thermal_zone$IDX/type"
            TEMP_FILE="$ROOT/sys/class/thermal/thermal_zone$IDX/temp"
            [ "$(cat "$TYPE_FILE" 2>/dev/null)" = "$NAME" ] || return 1
            RAW=$(cat "$TEMP_FILE" 2>/dev/null) || return 1
            num "$RAW" && [ "$RAW" -gt 0 ] && [ "$RAW" -le 200000 ] || return 1
            [ "$(cat "$TYPE_FILE" 2>/dev/null)" = "$NAME" ] || return 1
            case "$GROUP" in
                cpu) cpu=$((cpu+1)); [ "$RAW" -le "$cpu_peak" ] || cpu_peak=$RAW ;;
                gpu) gpu=$((gpu+1)); [ "$RAW" -le "$gpu_peak" ] || gpu_peak=$RAW ;;
                ddr) ddr=$((ddr+1)); [ "$RAW" -le "$ddr_peak" ] || ddr_peak=$RAW ;;
                xo) : ;;
                *) return 1 ;;
            esac
            count=$((count+1))
            [ "$count" -le 96 ] || return 1
        done
        [ "$count" -eq "$EXPECTED_COUNT" ] && [ "$cpu" -gt 0 ] && [ "$gpu" -gt 0 ] && [ "$ddr" -gt 0 ] || return 1
    } < "$TEMP_MANIFEST" || return 1
    for WHICH in /sys/class/power_supply/battery/temp /sys/class/power_supply/battery/lrp /sys/class/sec/sec-ap-thermistor/temperature; do
        VALUE=$(cat "$ROOT$WHICH" 2>/dev/null) || return 1
        num "$VALUE" && [ "$VALUE" -gt 0 ] && [ "$VALUE" -le 1200 ] || return 1
    done
    [ "$(cat "$BOOTFILE" 2>/dev/null)" = "$EXPECTED_BOOT" ] || return 1
    if [ "$MODE" = --live-oneui-readonly ]; then
        [ "$(getprop sys.boot_completed)" = 1 ] && pidof system_server >/dev/null 2>&1 || return 1
    fi
    printf 'CPU_MAX_MILLI=%s GPU_MAX_MILLI=%s DDR_MAX_MILLI=%s ZONES=%s\n' "$cpu_peak" "$gpu_peak" "$ddr_peak" "$count"
}

atomic() {
    printf '%s\n' "$2" > "$STAGE/$1.tmp.$$" || return 1
    mv -f "$STAGE/$1.tmp.$$" "$STAGE/$1" || return 1
}
worker() {
    PID=$$
    BIRTH=$(birth_ticks "$PID")
    [ -n "$BIRTH" ] || blocked worker_birth_unavailable
    atomic monitor.identity "$PID $BIRTH" || blocked monitor_identity_write
    n=1
    while [ "$n" -le "$TICKS" ]; do
        if ! VALUES=$(sample_all); then
            atomic monitor.fault "sample_failed_at_$n" || :
            echo "MONITOR=FAIL_CLOSED_SAMPLE tick=$n physical_return=NO"
            exit 4
        fi
        NOW=$(uptime_ms)
        atomic monitor.snapshot "tick=$n $VALUES" || blocked sample_write
        atomic monitor.heartbeat "v1 $EXPECTED_BOOT $GEN $LAUNCH $PID $BIRTH $n $NOW OK" || blocked heartbeat_write
        echo "MONITOR=OBSERVED tick=$n $VALUES"
        if [ "$FAULT" = monitor-exit-after-two ] && [ "$n" = 2 ]; then
            echo 'MONITOR=INJECTED_EXIT_NO_REBOOT'
            exit 44
        fi
        n=$((n+1))
        [ "$n" -gt "$TICKS" ] || sleep 2
    done
    atomic monitor.done "$TICKS $PID $BIRTH" || blocked done_write
    echo "MONITOR=FINITE_SMOKE_DONE samples=$TICKS physical_return=NO"
}
supervisor() {
    target=$1
    [ "$target" -gt 1 ] 2>/dev/null || blocked invalid_monitored_pid
    supervisor_birth=$(birth_ticks "$$")
    [ -n "$supervisor_birth" ] || blocked supervisor_birth_unavailable
    atomic supervisor.identity "$$ $supervisor_birth" || blocked supervisor_identity_write
    BIRTH=$(birth_ticks "$target")
    [ -n "$BIRTH" ] || blocked monitor_disappeared_before_start
    last_seq=0; last_change=$(uptime_ms); attempts=0
    while [ "$attempts" -lt 45 ]; do
        attempts=$((attempts+1))
        [ "$(cat "$BOOTFILE" 2>/dev/null)" = "$EXPECTED_BOOT" ] || blocked supervisor_boot_changed
        current_birth=$(birth_ticks "$target")
        if [ -f "$STAGE/monitor.identity" ] && [ "$(cat "$STAGE/monitor.identity" 2>/dev/null)" != "$target $BIRTH" ]; then
            echo 'SUPERVISOR=WOULD_REQUEST_RETURN_NOT_EXECUTED reason=monitor_identity_changed'
            exit 4
        fi
        if [ -n "$current_birth" ] && [ "$current_birth" != "$BIRTH" ]; then
            echo 'SUPERVISOR=WOULD_REQUEST_RETURN_NOT_EXECUTED reason=pid_reuse'
            exit 4
        fi
        if [ -f "$STAGE/monitor.fault" ]; then
            echo 'SUPERVISOR=WOULD_REQUEST_RETURN_NOT_EXECUTED reason=monitor_sample_fault'
            exit 4
        fi
        if [ -f "$STAGE/monitor.heartbeat" ]; then
            line=$(cat "$STAGE/monitor.heartbeat" 2>/dev/null) || blocked heartbeat_unreadable
            set -- $line
            if [ "$#" != 9 ] || [ "$1" != v1 ] || [ "$2" != "$EXPECTED_BOOT" ] ||
               [ "$3" != "$GEN" ] || [ "$4" != "$LAUNCH" ] || [ "$5" != "$target" ] ||
               [ "$6" != "$BIRTH" ] || [ "$9" != OK ]; then
                echo 'SUPERVISOR=WOULD_REQUEST_RETURN_NOT_EXECUTED reason=identity_bad'
                exit 4
            fi
            seq=$7; sampled=$8
            num "$seq" && num "$sampled" || blocked heartbeat_format
            [ "$seq" -ge "$last_seq" ] || blocked heartbeat_replay
            NOW=$(uptime_ms)
            age=$((NOW-sampled))
            if [ "$age" -lt 0 ] || [ "$age" -gt 12000 ]; then
                echo 'SUPERVISOR=WOULD_REQUEST_RETURN_NOT_EXECUTED reason=stale_heartbeat'
                exit 4
            fi
            if [ "$seq" -gt "$last_seq" ]; then
                last_seq=$seq; last_change=$NOW
            fi
        fi
        if [ -f "$STAGE/monitor.done" ]; then
            done_line=$(cat "$STAGE/monitor.done" 2>/dev/null) || blocked done_unreadable
            [ "$done_line" = "$TICKS $target $BIRTH" ] && [ "$last_seq" = "$TICKS" ] || blocked forged_done
            echo "SUPERVISOR=MONITOR_COMPLETED_SEPARATE_PID samples=$TICKS physical_return=NO"
            return 0
        fi
        if [ -z "$current_birth" ]; then
            echo 'SUPERVISOR=WOULD_REQUEST_RETURN_NOT_EXECUTED reason=monitor_dead'
            return 4
        fi
        NOW=$(uptime_ms)
        if [ $((NOW-last_change)) -gt 12000 ]; then
            echo 'SUPERVISOR=WOULD_REQUEST_RETURN_NOT_EXECUTED reason=heartbeat_stall'
            return 4
        fi
        sleep 1
    done
    echo 'SUPERVISOR=WOULD_REQUEST_RETURN_NOT_EXECUTED reason=hard_watch_limit'
    return 4
}
case "$INTERNAL" in
    __worker) worker; exit $? ;;
    __supervisor) [ -n "$TARGET" ] || usage; supervisor "$TARGET"; exit $? ;;
    '') : ;;
    *) usage ;;
esac
# Finite smoke only; two SIBLING root processes, outside xnuhost.
# The setsid parent record proves the trial persisted after its ADB
# launch command ended. It does not prove survival of Framework stop.
parent_birth=$(birth_ticks "$$")
parent_sid=$(sed 's/^.*) //' "/proc/$$/stat" 2>/dev/null | awk '$4 ~ /^[0-9]+$/ {print $4; exit}')
[ -n "$parent_birth" ] && [ -n "$parent_sid" ] || blocked parent_identity_unavailable
atomic trial.identity "$$ $parent_birth $parent_sid" || blocked trial_identity_write
if [ "$MODE" = --fixture-root ]; then
    sh "$SELF" --fixture-root "$ROOT" "$STAGE" "$TICKS" "$FAULT" __worker &
    MONPID=$!
    sh "$SELF" --fixture-root "$ROOT" "$STAGE" "$TICKS" "$FAULT" __supervisor "$MONPID" &
    SUPID=$!
else
    sh "$SELF" --live-oneui-readonly "$STAGE" "$TICKS" "$FAULT" __worker &
    MONPID=$!
    sh "$SELF" --live-oneui-readonly "$STAGE" "$TICKS" "$FAULT" __supervisor "$MONPID" &
    SUPID=$!
fi
wait "$MONPID"; monitor_rc=$?
wait "$SUPID"; supervisor_rc=$?
if [ "$FAULT" = normal ] && [ "$monitor_rc" = 0 ] && [ "$supervisor_rc" = 0 ]; then
    echo 'THERMAL_TRIAL=PASS_OBSERVER_SUPERVISOR_ONLY_NO_PHYSICAL_RETURN'
    exit 0
fi
if [ "$FAULT" = monitor-exit-after-two ] && [ "$monitor_rc" = 44 ] && [ "$supervisor_rc" = 4 ]; then
    echo 'THERMAL_TRIAL=EXPECTED_MONITOR_DEATH_DETECTED_NO_PHYSICAL_RETURN'
    exit 0
fi
echo "THERMAL_TRIAL=BLOCKED_UNEXPECTED monitor_rc=$monitor_rc supervisor_rc=$supervisor_rc physical_return=NO"
exit 4
