#!/system/bin/sh
# SM8850 bounded GPU-3D iOS takeover thermal monitor, independently spawned
# in init's namespace and root cgroup, NEVER inside xnuhost.
# This source does not open watchdog, change thresholds, reboot, or stop UI.
# Default: fail-closed observations for OneOS's reboot-only recovery.
# Experimental --run-passive: keep sensor and generation validation plus
# root-owned telemetry/heartbeats, but do not publish a SOFT overtemperature
# fault. The cap worker handles an aggressive 28% max-frequency ceiling;
# Samsung kernel/firmware thermal protection is NEVER modified.
# Sensor loss, bad identities and failed heartbeats still fail closed.
# Throttle-first experiment: 70/75/80 C are NOT return points. The conservative
# 90 C junction threshold is a last-resort runaway escape, NOT a certified
# SM8850 critical trip. Guard still fails closed on missing sensors.
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
# Hot-path sysfs attributes are single-value text files. Read in this shell,
# rather than spawning a cat subprocess for every field at a low CPU ceiling.
# Accept a final line without newline (offline fixtures); reject extra lines,
# empty values and failed opens. Callers still validate type/range/identity.
read_single_value() {
    READ_VALUE=
    READ_TRAILING=
    IFS= read -r READ_VALUE || [ -n "$READ_VALUE" ] || return 1
    if IFS= read -r READ_TRAILING || [ -n "$READ_TRAILING" ]; then
        return 1
    fi
    [ -n "$READ_VALUE" ]
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
            read_single_value 2>/dev/null < "$tfile" && [ "$READ_VALUE" = "$typ" ] || return 1
            read_single_value 2>/dev/null < "$vfile" || return 1
            raw=$READ_VALUE
            is_uint "$raw" && [ "$raw" -gt 0 ] && [ "$raw" -le 200000 ] || return 1
            read_single_value 2>/dev/null < "$tfile" && [ "$READ_VALUE" = "$typ" ] || return 1
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
    read_single_value 2>/dev/null < /sys/class/power_supply/battery/temp || return 1
    BAT=$READ_VALUE
    read_single_value 2>/dev/null < /sys/class/power_supply/battery/lrp || return 1
    LRP=$READ_VALUE
    read_single_value 2>/dev/null < /sys/class/sec/sec-ap-thermistor/temperature || return 1
    AP=$READ_VALUE
    for val in "$BAT" "$LRP" "$AP"; do
        is_uint "$val" && [ "$val" -gt 0 ] && [ "$val" -le 1200 ] || return 1
    done
    read_single_value 2>/dev/null < /proc/sys/kernel/random/boot_id &&
        [ "$READ_VALUE" = "$HEADER_BOOT" ] || return 1
    # EARLY EXPERIMENT ABORT, not a hardware critical threshold.
    # Preserve the exact exceeded group and real-zone peak with fixed units.
    # These diagnostic tokens are appended to the existing fault record and
    # must NEVER delay or override the original fail-closed return behavior.
    crossed=
    [ "$CPU_MAX" -lt 90000 ] || crossed="${crossed}cpu,"
    [ "$GPU_MAX" -lt 95000 ] || crossed="${crossed}gpu,"
    [ "$DDR_MAX" -lt 95000 ] || crossed="${crossed}ddr,"
    [ "$BAT" -lt 480 ] || crossed="${crossed}bat,"
    [ "$LRP" -lt 500 ] || crossed="${crossed}lrp,"
    [ "$AP" -lt 700 ] || crossed="${crossed}board_ap,"
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
PASSIVE=0
[ "$MODE" != --run-passive ] || PASSIVE=1
case "$MODE" in
    --check)
        [ "$#" = 2 ] || die usage
        MAN=$2
        [ "$(id -u)" = 0 ] || die root_required
        [ "$(stat -c %u "$MAN" 2>/dev/null)" = 0 ] || die manifest_not_root
        BOOT=$(cat /proc/sys/kernel/random/boot_id) || die boot_unavailable
        read_all "$BOOT" "$MAN" || die sensor_or_soft_cutoff
        echo "P0_THERMAL_GUARD=READ_ONLY_CURRENT_BOOT_READY_NOT_CERTIFIED"
        exit 0 ;;
    --run|--run-passive)
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
        [ "$(cat "$CTL/framework.mode" 2>/dev/null)" = run ] || die non_run
        if [ "$(cat "$CTL/framework.cpu-budget" 2>/dev/null)" = cfs-v1-180s ]; then
            # The root monitor must never share the guest CPU quota.
            printf '%s\n' "$$" > /dev/cpuctl/cgroup.procs || die guard_root_cpu_group
            awk -F: '$2=="cpu" && $3=="/" {ok=1} END {exit !ok}' /proc/$$/cgroup ||
                die guard_root_cpu_membership
        fi
        echo $$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null
        echo -1000 > /proc/$$/oom_score_adj 2>/dev/null
        BIRTH=$(birth $$)
        [ -n "$BIRTH" ] || die no_pid_birth
        atom thermal.guard.pid "$$ $BIRTH" || die cannot_record_pid
        seq=0
        [ "$PASSIVE" != 1 ] || echo "P0_THERMAL_GUARD=PASSIVE_SOFT_TRIP_DISABLED SENSOR_READS_AND_HEARTBEATS_ACTIVE"
        while [ "$GEN" = "$(cat "$CTL/watchdog.generation" 2>/dev/null)" ]; do
            case "$(cat "$CTL/state" 2>/dev/null)" in
                returning|returned|failed) exit 0 ;;
            esac
            # Use the actual completed sample timestamp, never a synthetic heartbeat.
            # Record scan cost for diagnosing starvation; the freshness limit is unchanged.
            read -r scan_start _ < /proc/uptime || scan_start=
            scan_start=${scan_start%%.*}
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
                if [ "$PASSIVE" = 1 ] && [ "$rc" = 2 ]; then
                    # Experimental no-soft-trip mode: keep samples flowing
                    # for the CPU cap and the read-only host logger. No
                    # userspace thermal return is requested at 90C/95C.
                    echo "P0_THERMAL_GUARD=PASSIVE_OVERRANGE_NO_SOFT_RETURN $detail"
                else
                    atom thermal.guard.fault "$BOOT $GEN $$ $BIRTH $reason ${detail}" || :
                    echo "P0_THERMAL_GUARD=FAIL_CLOSED $reason ${detail}"
                    exit 4
                fi
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
                    echo "P0_THERMAL_SAMPLE=OK boot=$BOOT generation=$GEN seq=$seq uptime=$tick cpu_mC=$CPU_MAX cpu_zone=$CPU_MAX_ZONE gpu_mC=$GPU_MAX gpu_zone=$GPU_MAX_ZONE ddr_mC=$DDR_MAX ddr_zone=$DDR_MAX_ZONE bat_dC=$BAT lrp_dC=$LRP board_ap_dC=$AP scan_seconds=$(
                        if is_uint "$scan_start" && [ "$scan_start" -le "$tick" ]; then
                            printf '%s' "$((tick-scan_start))"
                        else
                            printf unknown
                        fi
                    )"
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
