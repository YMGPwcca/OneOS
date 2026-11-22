#!/system/bin/sh
# SM8850 OneiOS: throttle-first CPU ceiling for bounded full takeover (target <80 C).
# Adapted from fahadalijaved/OneOS oneos_heat_cap, NOT its SKIN=45/47/50
# thresholds. This worker reads the already-verified root thermal heartbeat.
#
# The cap only LOWERS scaling_max_freq. It never releases SSRM/KernelSU limits,
# touches thermal trips, changes GPU clocks, or raises clocks during a session.
# Never return on reaching 80 C: raise throttling instead; root guard owns last-resort runaway/invalid sensors.
# Runtime physical behavior and watchdog recovery are NOT yet qualified.
set -u
LC_ALL=C
export LC_ALL
umask 077

die() { echo "P0_CPU_CAP=BLOCKED $*" >&2; exit 4; }
uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 8 ]; }
birth() {
    sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null |
        awk '$1!="Z" && $1!="X" && $20 ~ /^[0-9]+$/ { print $20; exit }'
}
tick() {
    read -r up _ < /proc/uptime || return 1
    up=${up%%.*}
    uint "$up" || return 1
    printf '%s\n' "$up"
}
atom() {
    printf '%s\n' "$2" > "$CTL/$1.tmp.$$" && mv -f "$CTL/$1.tmp.$$" "$CTL/$1"
}
fault() {
    atom thermal.cap.fault "$BOOT $GEN $$ $BIRTH $*" || :
    echo "P0_CPU_CAP=FAIL_CLOSED $*"
    exit 4
}
# Input: previous level, CPU/GPU/DDR milli-C, battery/LRP/boardAP deci-C.
# Output: level:percent. This is a THROTTLE-FIRST candidate, not validated
# SM8850 thermal calibration. At 80 C, throttle harder; DO NOT auto-return.
# An independent emergency root guard still owns sensor loss, runaway heat
# and recovery. Caps are monotonic within one session (no mid-run reboost).
policy() {
    [ "$#" = 7 ] || return 3
    prev=$1; cpu=$2; gpu=$3; ddr=$4; bat=$5; lrp=$6; ap=$7
    for n in "$prev" "$cpu" "$gpu" "$ddr" "$bat" "$lrp" "$ap"; do
        uint "$n" || return 3
    done
    [ "$prev" -le 6 ] || return 3
    [ "$cpu" -gt 0 ] && [ "$cpu" -le 200000 ] &&
        [ "$gpu" -gt 0 ] && [ "$gpu" -le 200000 ] &&
        [ "$ddr" -gt 0 ] && [ "$ddr" -le 200000 ] || return 3
    for n in "$bat" "$lrp" "$ap"; do
        [ "$n" -gt 0 ] && [ "$n" -le 1200 ] || return 3
    done
    # Last-resort safety, not normal thermal management. We cannot guarantee
    # <80 C using frequency caps alone: a runaway still has to reboot-return.
    if [ "$cpu" -ge 90000 ] || [ "$gpu" -ge 95000 ] ||
       [ "$ddr" -ge 95000 ] || [ "$bat" -ge 480 ] ||
       [ "$lrp" -ge 500 ] || [ "$ap" -ge 700 ]; then
        return 2
    fi
    level=1
    if [ "$cpu" -ge 55000 ] || [ "$gpu" -ge 60000 ] ||
       [ "$ddr" -ge 60000 ] || [ "$bat" -ge 340 ] ||
       [ "$lrp" -ge 370 ] || [ "$ap" -ge 450 ]; then level=2; fi
    if [ "$cpu" -ge 65000 ] || [ "$gpu" -ge 70000 ] ||
       [ "$ddr" -ge 70000 ] || [ "$bat" -ge 370 ] ||
       [ "$lrp" -ge 400 ] || [ "$ap" -ge 500 ]; then level=3; fi
    if [ "$cpu" -ge 72000 ] || [ "$gpu" -ge 75000 ] ||
       [ "$ddr" -ge 75000 ] || [ "$bat" -ge 400 ] ||
       [ "$lrp" -ge 430 ] || [ "$ap" -ge 550 ]; then level=4; fi
    if [ "$cpu" -ge 77000 ] || [ "$gpu" -ge 80000 ] ||
       [ "$ddr" -ge 80000 ] || [ "$bat" -ge 420 ] ||
       [ "$lrp" -ge 450 ] || [ "$ap" -ge 600 ]; then level=5; fi
    if [ "$cpu" -ge 80000 ] || [ "$gpu" -ge 85000 ] ||
       [ "$ddr" -ge 85000 ] || [ "$bat" -ge 440 ] ||
       [ "$lrp" -ge 470 ] || [ "$ap" -ge 650 ]; then level=6; fi
    [ "$prev" -le "$level" ] || level=$prev
    case "$level" in
        1) pct=60 ;; 2) pct=40 ;; 3) pct=28 ;;
        4) pct=18 ;; 5) pct=12 ;; 6) pct=8 ;; *) return 3 ;;
    esac
    printf '%s:%s\n' "$level" "$pct"
}
# Scan the host's policies. No generic cpufreq_max_limit "-1" writes:
# One UI's old low-power or Samsung vendor vote must never be relaxed.
policies() {
    root=$1
    policies_found=0
    for pol in "$root"/sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "$pol" ] || continue
        case "${pol##*/}" in policy[0-9]*) ;; *) return 1 ;; esac
        hw=$(cat "$pol/cpuinfo_max_freq" 2>/dev/null) || return 1
        mn=$(cat "$pol/cpuinfo_min_freq" 2>/dev/null) || return 1
        active_min=$(cat "$pol/scaling_min_freq" 2>/dev/null) || return 1
        cur=$(cat "$pol/scaling_max_freq" 2>/dev/null) || return 1
        uint "$hw" && uint "$mn" && uint "$active_min" && uint "$cur" &&
          [ "$hw" -ge 200000 ] && [ "$hw" -le 6000000 ] &&
          [ "$mn" -ge 100000 ] && [ "$mn" -le "$hw" ] &&
          [ "$active_min" -ge "$mn" ] && [ "$active_min" -le "$hw" ] &&
          [ "$cur" -ge "$mn" ] && [ "$cur" -le "$hw" ] &&
          [ -w "$pol/scaling_max_freq" ] || return 1
        policies_found=$((policies_found+1))
        [ "$policies_found" -le 8 ] || return 1
    done
    [ "$policies_found" -ge 2 ]
}
# Desired cap computed from hardware maximum and clipped to BOTH the hardware
# minimum and Samsung's dynamic scaling_min_freq vote. That vote may rise while
# One UI runs (observed 384000 -> 1228800 kHz on policy0 on SM-S948B).
# Do NOT modify scaling_min_freq or Samsung's cpufreq_max_limit.
# A dynamic minimum can prevent the advertised 8% cap from being achieved:
# report the floor honestly; root thermal guard still owns runaway recovery.
# A target never raises an existing tighter cap; readback must not exceed it.
apply_cap() {
    root=$1 pct=$2 strict=${3:-lenient}
    case "$strict" in lenient|strict) ;; *) return 1 ;; esac
    policies "$root" || return 1

    # A Samsung PM QoS / performance minimum may rise independently of
    # scaling_max_freq. In LIVE mode, a claimed 28%/40% cap is unsafe if
    # the minimum vote exceeds that cap. Fail closed before writing anything.
    # The original lenient mode remains available ONLY for synthetic
    # tests of the clamping algorithm; never use it for the live worker.
    if [ "$strict" = strict ]; then
        for pol in "$root"/sys/devices/system/cpu/cpufreq/policy*; do
            [ -d "$pol" ] || continue
            hw=$(cat "$pol/cpuinfo_max_freq" 2>/dev/null) || return 1
            mn=$(cat "$pol/cpuinfo_min_freq" 2>/dev/null) || return 1
            active_min=$(cat "$pol/scaling_min_freq" 2>/dev/null) || return 1
            requested=$((hw / 100 * pct))
            [ "$requested" -ge "$mn" ] || requested=$mn
            if [ "$active_min" -gt "$requested" ]; then
                echo "P0_CPU_CAP=UNENFORCEABLE_MIN_VOTE policy=${pol##*/} pct=$pct requested_khz=$requested scaling_min_khz=$active_min boot=${BOOT:-fixture} generation=${GEN:-fixture}"
                return 2
            fi
        done
    fi

    for pol in "$root"/sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "$pol" ] || continue
        hw=$(cat "$pol/cpuinfo_max_freq" 2>/dev/null) || return 1
        mn=$(cat "$pol/cpuinfo_min_freq" 2>/dev/null) || return 1
        active_min=$(cat "$pol/scaling_min_freq" 2>/dev/null) || return 1
        cur=$(cat "$pol/scaling_max_freq" 2>/dev/null) || return 1
        uint "$hw" && uint "$mn" && uint "$active_min" && uint "$cur" &&
          [ "$active_min" -ge "$mn" ] && [ "$active_min" -le "$hw" ] || return 1
        target=$((hw / 100 * pct))
        [ "$target" -ge "$mn" ] || target=$mn
        requested=$target
        if [ "$target" -lt "$active_min" ]; then
            # Re-check in case the vendor vote rose after the strict first
            # pass. Do not silently report heartbeat OK on an impossible cap.
            if [ "$strict" = strict ]; then
                echo "P0_CPU_CAP=UNENFORCEABLE_MIN_VOTE policy=${pol##*/} pct=$pct requested_khz=$requested scaling_min_khz=$active_min boot=${BOOT:-fixture} generation=${GEN:-fixture}"
                return 2
            fi
            target=$active_min
            echo "P0_CPU_CAP=MIN_FLOOR_LIMITED policy=${pol##*/} pct=$pct requested_khz=$requested scaling_min_khz=$active_min effective_target_khz=$target boot=${BOOT:-fixture} generation=${GEN:-fixture}"
        fi
        if [ "$cur" -gt "$target" ]; then
            printf '%s\n' "$target" > "$pol/scaling_max_freq" || return 1
        fi
        got=$(cat "$pol/scaling_max_freq" 2>/dev/null) || return 1
        uint "$got" && [ "$got" -le "$target" ] && [ "$got" -ge "$mn" ] || return 1
    done
}
# A prearmed process only observes Android until Framework is REALLY down.
# The switch writes "stopped" before issuing ctl.stop, so the marker alone
# MUST NOT be treated as permission to touch cpufreq sysfs.
# This gate is shared with host-only synthetic tests.
framework_down_for_cpu_cap() {
    [ -f "$CTL/stopped" ] && [ ! -L "$CTL/stopped" ] || return 1
    [ "$(getprop init.svc.zygote)" = stopped ] || return 1
    [ "$(getprop init.svc.zygote_next)" = stopped ] || return 1
    case "$(getprop init.svc.zygote_secondary)" in ''|stopped) ;; *) return 1 ;; esac
    ! pidof system_server >/dev/null 2>&1
}
# The only nonroot write mode uses disposable synthetic sysfs, NEVER real sysfs.
# It is for CachyOS tests and cannot name / or a live Android path.
MODE=${1:-}
case "$MODE" in
    --policy)
        shift
        policy "$@"; exit $? ;;
    --fixture-step|--fixture-strict-step)
        [ "$#" = 3 ] || die fixture_args
        [ "$(id -u)" != 0 ] || die fixture_must_be_unprivileged
        case "$2" in /tmp/oneios-cpu-cap-test.*) ;; *) die fixture_path ;; esac
        [ -d "$2" ] && [ ! -L "$2" ] || die fixture_root
        case "$3" in 60|40|28|18|12|8) ;; *) die invalid_fixture_percent ;; esac
        fixture_strict=lenient
        [ "$MODE" != --fixture-strict-step ] || fixture_strict=strict
        apply_cap "$2" "$3" "$fixture_strict" || die fixture_policy_failed
        echo "P0_CPU_CAP=FIXTURE_APPLIED pct=$3 strict=$fixture_strict"
        exit 0 ;;
    --check)
        [ "$#" = 1 ] || die args
        [ "$(id -u)" = 0 ] || die root_required
        policies "" || die host_cpufreq_unavailable
        echo "P0_CPU_CAP=READ_ONLY_POLICY_AVAILABLE_NOT_CERTIFIED"
        exit 0 ;;
    --run|--run-prearmed)
        [ "$#" = 3 ] || die args
        [ "$(id -u)" = 0 ] || die root_required
        CTL=$2 GEN=$3
        [ "$CTL" = /data/adb/oneios-m3q-framework/control ] || die control_path
        [ -d "$CTL" ] && [ ! -L "$CTL" ] &&
          [ "$(stat -c %u "$CTL" 2>/dev/null)" = 0 ] || die untrusted_control
        BOOT=$(cat "$CTL/boot" 2>/dev/null) || die boot_unknown
        [ "$BOOT" = "$(cat /proc/sys/kernel/random/boot_id)" ] &&
          [ "$GEN" = "$(cat "$CTL/watchdog.generation" 2>/dev/null)" ] &&
          [ "$(cat "$CTL/framework.mode" 2>/dev/null)" = run ] || die stale_session
        policies "" || die cpufreq_unavailable
        echo $$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null
        echo -1000 > /proc/$$/oom_score_adj 2>/dev/null
        BIRTH=$(birth $$)
        [ -n "$BIRTH" ] || die no_pid_birth
        atom thermal.cap.pid "$ $BIRTH" || die cap_pid_write
        if [ "$MODE" = --run-prearmed ]; then
            # Publish trusted PID/birth identity while still read-only.
            # The switch validates this BEFORE it can stop system_server.
            atom thermal.cap.prearmed "v1 $BOOT $GEN $ $BIRTH" ||
                die cannot_publish_prearmed_pid
            standby_start=$(tick) || fault standby_monotonic_clock
            echo "P0_CPU_CAP=PREARMED_READ_ONLY boot=$BOOT generation=$GEN"
            while [ "$GEN" = "$(cat "$CTL/watchdog.generation" 2>/dev/null)" ]; do
                case "$(cat "$CTL/state" 2>/dev/null)" in
                    returning|returned|failed) exit 0 ;;
                    starting) ;;
                    *) fault prearmed_invalid_session_state ;;
                esac
                [ ! -e "${CTL%/control}/session/return.request" ] || exit 0
                [ ! -e "$CTL/thermal.guard.fault" ] ||
                    fault prearmed_root_thermal_guard_fault
                [ "$BOOT" = "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" ] ||
                    exit 0
                if framework_down_for_cpu_cap; then
                    echo "P0_CPU_CAP=FRAMEWORK_DOWN_VERIFIED_START_STRICT boot=$BOOT generation=$GEN"
                    break
                fi
                standby_now=$(tick) || fault standby_monotonic_clock
                if [ $((standby_now - standby_start)) -ge 40 ]; then
                    fault prearmed_cap_framework_stop_not_confirmed
                fi
                sleep 0.2
            done
            [ "$GEN" = "$(cat "$CTL/watchdog.generation" 2>/dev/null)" ] || exit 0
        fi
        level=0
        seq=0
        while [ "$GEN" = "$(cat "$CTL/watchdog.generation" 2>/dev/null)" ]; do
            case "$(cat "$CTL/state" 2>/dev/null)" in
                returning|returned|failed) exit 0 ;;
                starting|running) ;;
                *) fault invalid_session_state ;;
            esac
            [ ! -e "${CTL%/control}/session/return.request" ] || exit 0
            [ ! -e "$CTL/thermal.guard.fault" ] || fault thermal_guard_fault
            read -r ver hbboot hbgen pid pbirth hseq ht status cpu gpu ddr bat lrp ap extra \
                < "$CTL/thermal.guard.heartbeat" || fault missing_root_guard_heartbeat
            [ "$ver" = v1 ] && [ "$hbboot" = "$BOOT" ] &&
                [ "$hbgen" = "$GEN" ] && [ "$status" = OK ] &&
                [ -z "$extra" ] && [ "$pid $pbirth" = "$(cat "$CTL/thermal.guard.pid" 2>/dev/null)" ] ||
                fault stale_guard_identity
            for value in "$hseq" "$ht" "$cpu" "$gpu" "$ddr" "$bat" "$lrp" "$ap"; do
                uint "$value" || fault invalid_guard_sample
            done
            now=$(tick) || fault invalid_uptime
            [ "$ht" -le "$now" ] && [ $((now-ht)) -le 3 ] &&
                [ "$hseq" -gt 0 ] || fault stale_guard_sample
            choice=$(policy "$level" "$cpu" "$gpu" "$ddr" "$bat" "$lrp" "$ap") ||
                fault invalid_or_emergency_temperature
            desired=${choice%%:*}
            pct=${choice#*:}
            # Only write to sysfs on a level change. Re-validate every tick
            # that no cluster has escaped the currently demanded cap.
            # A heartbeat is NOT proof of a working thermal ceiling if a
            # vendor performance vote forces scaling_min_freq above the
            # requested ceiling. Abort through the existing independent
            # watcher before a 90 C emergency instead of silently clamping.
            apply_cap "" "$pct" strict
            cap_rc=$?
            case "$cap_rc" in
                0) ;;
                2) fault "unachievable_cpu_cap_floor level=$desired pct=$pct" ;;
                *) fault cpufreq_write_or_readback ;;
            esac
            level=$desired
            seq=$((seq+1))
            atom thermal.cap.heartbeat "v1 $BOOT $GEN $$ $BIRTH $seq $now OK $level $pct" ||
                fault cannot_publish_heartbeat
            [ "$seq" -ne 1 ] || echo "P0_CPU_CAP=ARMED_INDEPENDENT_ROOT_CAP_NOT_HARDWARE_CERTIFIED pct=$pct"
            sleep 1
        done
        exit 0 ;;
    *) die usage ;;
esac
