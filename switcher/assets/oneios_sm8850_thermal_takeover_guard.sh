#!/system/bin/sh
# SM8850 short iOS takeover PROBE thermal monitor, independently spawned
# in init's namespace and root cgroup, NEVER inside xnuhost.
# This source does not open watchdog, change thresholds, reboot, or stop UI.
# It publishes fail-closed observations for OneOS's existing reboot-only
# framework-deadline and watcher, which own all return/recovery actions.
# Cutoffs below are deliberately EARLY ABORT points for one short experiment,
# NOT validated hardware critical temperatures or production thermal policy.
set -u
LC_ALL=C; export LC_ALL
umask 077

die() { echo "P0_THERMAL_GUARD=BLOCKED $1" >&2; exit 4; }
is_uint() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 7 ]
}
birth() {
    sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null |
        awk '$1!="Z" && $1!="X" && $20 ~ /^[0-9]+$/ {print $20; exit}'
}
mono_seconds() {
    read -r up rem < /proc/uptime || return 1
    now=${up%%.*}
    is_uint "$now" || return 1
    printf '%s\n' "$now"
}
type_group() {
    case "$1:$2" in
        cpu-hw-trip-*:*) return 1 ;;
        cpu-*:cpu|cpuss-*:cpu|gpuss-*:gpu|ddr:ddr|xo-therm:xo) return 0 ;;
        *) return 1 ;;
    esac
}
read_all() {
    HEADER_BOOT=$1
    FILE=$2
    [ -f "$FILE" ] && [ ! -L "$FILE" ] || return 1
    idx_seen=" "; count=0; cpu_count=0; gpu_count=0; ddr_count=0
    CPU_MAX=0; GPU_MAX=0; DDR_MAX=0
    CPU_MAX_ZONE=none; GPU_MAX_ZONE=none; DDR_MAX_ZONE=none
    SOFT_FAULT_DETAIL=
    {
        IFS=' ' read -r version boot claimed extra || return 1
        [ "$version" = v1 ] && [ "$boot" = "$HEADER_BOOT" ] &&
            [ -z "$extra" ] && is_uint "$claimed" &&
            [ "$claimed" -ge 3 ] && [ "$claimed" -le 96 ] || return 1
        while IFS=' ' read -r flag idx typ grp extra; do
            [ "$flag" = z ] && [ -z "$extra" ] &&
                is_uint "$idx" && [ "$idx" -le 255 ] || return 1
            case "$idx_seen" in *" $idx "*) return 1 ;; esac
            idx_seen="$idx_seen$idx "
            case "$typ" in ''|*[!a-zA-Z0-9._-]*) return 1 ;; esac
            type_group "$typ" "$grp" || return 1
            tfile="/sys/class/thermal/thermal_zone$idx/type"
            vfile="/sys/class/thermal/thermal_zone$idx/temp"
            [ "$(cat "$tfile" 2>/dev/null)" = "$typ" ] || return 1
            raw=$(cat "$vfile" 2>/dev/null) || return 1
            is_uint "$raw" && [ "$raw" -gt 0 ] && [ "$raw" -le 200000 ] || return 1
            [ "$(cat "$tfile" 2>/dev/null)" = "$typ" ] || return 1
            case "$grp" in
                cpu) cpu_count=$((cpu_count+1))
                     if [ "$raw" -gt "$CPU_MAX" ]; then
                         CPU_MAX=$raw; CPU_MAX_ZONE=$typ@$idx
                     fi ;;
                gpu) gpu_count=$((gpu_count+1))
                     if [ "$raw" -gt "$GPU_MAX" ]; then
                         GPU_MAX=$raw; GPU_MAX_ZONE=$typ@$idx
                     fi ;;
                ddr) ddr_count=$((ddr_count+1))
                     if [ "$raw" -gt "$DDR_MAX" ]; then
                         DDR_MAX=$raw; DDR_MAX_ZONE=$typ@$idx
                     fi ;;
            esac
            count=$((count+1))
            [ "$count" -le 96 ] || return 1
        done
        [ "$count" -eq "$claimed" ] && [ "$cpu_count" -gt 0 ] &&
            [ "$gpu_count" -gt 0 ] && [ "$ddr_count" -gt 0 ] || return 1
    } < "$FILE" || return 1
    BAT=$(cat /sys/class/power_supply/battery/temp 2>/dev/null) || return 1
    LRP=$(cat /sys/class/power_supply/battery/lrp 2>/dev/null) || return 1
    AP=$(cat /sys/class/sec/sec-ap-thermistor/temperature 2>/dev/null) || return 1
    for val in "$BAT" "$LRP" "$AP"; do
        is_uint "$val" && [ "$val" -gt 0 ] && [ "$val" -le 1200 ] || return 1
    done
    [ "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" = "$HEADER_BOOT" ] || return 1
    # HIGH-RISK EXPERIMENT ONLY (operator-requested CPU abort 90 C).
    # 90000 is not firmware/vendor-qualified for this SM8850 build.
    # Other cutoffs and ALL invalid/missing/stale-sensor fail-closed paths
    # remain unchanged. Not a P0 thermal/recovery acceptance profile.
    # EARLY EXPERIMENT ABORT, not a hardware critical threshold.
    # Preserve the exact exceeded group and real-zone peak with fixed units.
    # These diagnostic tokens are appended to the existing fault record and
    # must NEVER delay or override the original fail-closed return behavior.
    crossed=
    [ "$CPU_MAX" -lt 90000 ] || crossed="${crossed}cpu,"
    [ "$GPU_MAX" -lt 55000 ] || crossed="${crossed}gpu,"
    [ "$DDR_MAX" -lt 55000 ] || crossed="${crossed}ddr,"
    [ "$BAT" -lt 380 ] || crossed="${crossed}bat,"
    [ "$LRP" -lt 420 ] || crossed="${crossed}lrp,"
    [ "$AP" -lt 420 ] || crossed="${crossed}board_ap,"
    if [ -n "$crossed" ]; then
        SOFT_FAULT_DETAIL="crossed=${crossed%,} cpu_mC=$CPU_MAX cpu_zone=$CPU_MAX_ZONE gpu_mC=$GPU_MAX gpu_zone=$GPU_MAX_ZONE ddr_mC=$DDR_MAX ddr_zone=$DDR_MAX_ZONE bat_dC=$BAT lrp_dC=$LRP board_ap_dC=$AP"
        return 2
    fi
    return 0
}
atom() {
    printf '%s\n' "$2" > "$CTL/$1.tmp.$$" || return 1
    mv -f "$CTL/$1.tmp.$$" "$CTL/$1"
}
MODE=${1:-}
case "$MODE" in
    --pid-birth-selftest)
        # Read-only, no root/Framework/session requirement: exercise the
        # same birth($$) parser before consuming a one-shot APFS Data clone.
        [ "$#" = 1 ] || die usage
        SELF_BIRTH=$(birth $$) || die no_pid_birth
        case "$SELF_BIRTH" in ''|*[!0-9]*) die no_pid_birth ;; esac
        [ "$SELF_BIRTH" -gt 0 ] || die no_pid_birth
        echo "P0_THERMAL_PID_BIRTH=PASS_READ_ONLY"
        exit 0 ;;
    --check)
        [ "$#" = 2 ] || die usage
        MAN=$2
        [ "$(id -u)" = 0 ] || die root_required
        [ "$(stat -c %u "$MAN" 2>/dev/null)" = 0 ] || die manifest_not_root
        BOOT=$(cat /proc/sys/kernel/random/boot_id) || die boot_unavailable
        read_all "$BOOT" "$MAN" || die sensor_or_soft_cutoff
        echo "P0_THERMAL_GUARD=READ_ONLY_CURRENT_BOOT_READY_NOT_CERTIFIED"
        exit 0 ;;
    --run)
        [ "$#" = 4 ] || die usage
        CTL=$2; MAN=$3; GEN=$4
        [ "$(id -u)" = 0 ] || die root_required
        case "$CTL" in /data/adb/oneios-m3q-framework/control) ;; *) die stage_path ;; esac
        case "$MAN" in /data/adb/oneios-m3q-framework/thermal.guard.manifest) ;; *) die manifest_path ;; esac
        [ "$(stat -c %u "$CTL" 2>/dev/null)" = 0 ] &&
        [ "$(stat -c %u "$MAN" 2>/dev/null)" = 0 ] || die root_stage_required
        BOOT=$(cat "$CTL/boot" 2>/dev/null) || die no_session_boot
        [ "$BOOT" = "$(cat /proc/sys/kernel/random/boot_id)" ] || die stale_session
        [ "$GEN" = "$(cat "$CTL/watchdog.generation" 2>/dev/null)" ] || die generation_mismatch
        [ "$(cat "$CTL/framework.mode" 2>/dev/null)" = probe ] || die non_probe
        echo $$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null
        echo -1000 > /proc/$$/oom_score_adj 2>/dev/null
        BIRTH=$(birth $$)
        [ -n "$BIRTH" ] || die no_pid_birth
        echo "P0_THERMAL_PROFILE=CPU_90C_HIGH_RISK_NOT_VENDOR_CERTIFIED_GPU_DDR_55C_BAT_38C_LRP_AP_42C"
        atom thermal.guard.pid "$$ $BIRTH" || die cannot_record_pid
        seq=0
        while [ "$GEN" = "$(cat "$CTL/watchdog.generation" 2>/dev/null)" ]; do
            case "$(cat "$CTL/state" 2>/dev/null)" in
                returning|returned|failed) exit 0 ;;
            esac
            if read_all "$BOOT" "$MAN"; then
                :
            else
                rc=$?
                case "$rc" in
                    2) reason=soft_temperature_abort
                       detail=$SOFT_FAULT_DETAIL ;;
                    *) reason=missing_or_invalid_sensor
                       detail= ;;
                esac
                atom thermal.guard.fault "$BOOT $GEN $$ $BIRTH $reason ${detail}" || :
                echo "P0_THERMAL_GUARD=FAIL_CLOSED $reason ${detail}"
                exit 4
            fi
            seq=$((seq+1))
            tick=$(mono_seconds) || {
                atom thermal.guard.fault "$BOOT $GEN $$ $BIRTH invalid_monotonic_clock" || :
                exit 4
            }
            atom thermal.guard.heartbeat "v1 $BOOT $GEN $$ $BIRTH $seq $tick OK $CPU_MAX $GPU_MAX $DDR_MAX $BAT $LRP $AP" ||
                die heartbeat_write_failure
            # Bounded root-owned thermal telemetry survives xnuhost bridges=0.
            # Boot/generation distinguish new samples from appended older runs.
            # Never delay or replace the fail-closed fault branch above.
            case $((seq % 5)) in
                1)
                    echo "P0_THERMAL_SAMPLE=OK boot=$BOOT generation=$GEN seq=$seq uptime=$tick cpu_mC=$CPU_MAX cpu_zone=$CPU_MAX_ZONE gpu_mC=$GPU_MAX gpu_zone=$GPU_MAX_ZONE ddr_mC=$DDR_MAX ddr_zone=$DDR_MAX_ZONE bat_dC=$BAT lrp_dC=$LRP board_ap_dC=$AP"
                    # Parent OneiOS's thermal bridge reports host CPU and
                    # xnuhost load; bridges=0 cannot use that bridge. Read
                    # cumulative /proc counters from the independent guard
                    # instead. Never signal, renice, pin, open watchdog or
                    # block a return: this is diagnostic data only.
                    guest_pid=$(cat "$CTL/xnuhost.pid" 2>/dev/null)
                    if is_uint "$guest_pid" && [ "$guest_pid" -gt 1 ]; then
                        guest_cpu=$(sed 's/^.*) //' "/proc/$guest_pid/stat" 2>/dev/null |
                            awk '$1 != "Z" && $1 != "X" && $12 ~ /^[0-9]+$/ && $13 ~ /^[0-9]+$/ && $20 ~ /^[0-9]+$/ { printf "user_ticks=%s system_ticks=%s birth_ticks=%s", $12, $13, $20; exit }')
                        if [ -n "$guest_cpu" ]; then
                            host_cpu_ticks=$(awk '/^cpu / { printf "%.0f", $2+$3+$4+$5+$6+$7+$8+$9; exit }' /proc/stat 2>/dev/null)
                            echo "P0_XNUHOST_LOAD=READ_ONLY boot=$BOOT generation=$GEN uptime=$tick pid=$guest_pid $guest_cpu host_allcpu_ticks=${host_cpu_ticks:-unavailable}"
                        fi
                    fi
                    ;;
            esac
            sleep 1
        done
        exit 0 ;;
    *) die usage ;;
esac
