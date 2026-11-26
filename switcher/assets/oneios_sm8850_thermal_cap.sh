#!/system/bin/sh
# SM8850 OneiOS: throttle-first CPU ceiling for bounded full takeover (target 30-70 C).
# Adapted from fahadalijaved/OneOS oneos_heat_cap, NOT its SKIN=45/47/50
# thresholds. This worker reads the already-verified root thermal heartbeat.
#
# The cap only LOWERS scaling_max_freq. It never releases SSRM/KernelSU limits,
# touches thermal trips, changes GPU clocks, or raises clocks during a session.
# Explicit 180s --run-prearmed-floor experiment: initial 28% ceiling clipped to
# Samsung's active minimum vote. This may exceed 28% in practice and MUST
# be reported as FLOOR_LIMITED. Firmware/kernel thermal policy is untouched.
# At 70 C anticipate heat; at 75 C tighten the cap, not return. The existing
# 90 C runaway / invalid sensor guard and bounded reboot deadline remain separate.
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
# SM8850 thermal calibration. At 70 C and 75 C throttle harder; DO NOT auto-return.
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
    # 30-70 C using frequency caps alone: a runaway still has to reboot-return.
    hot=0
    if [ "$cpu" -ge 90000 ] || [ "$gpu" -ge 95000 ] ||
       [ "$ddr" -ge 95000 ] || [ "$bat" -ge 480 ] ||
       [ "$lrp" -ge 500 ] || [ "$ap" -ge 700 ]; then
        [ "${FLOOR_MODE:-0}" = 1 ] || return 2
        hot=1
    fi
    level=1
    if [ "$cpu" -ge 55000 ] || [ "$gpu" -ge 60000 ] ||
       [ "$ddr" -ge 60000 ] || [ "$bat" -ge 340 ] ||
       [ "$lrp" -ge 370 ] || [ "$ap" -ge 450 ]; then level=2; fi
    if [ "$cpu" -ge 65000 ] || [ "$gpu" -ge 70000 ] ||
       [ "$ddr" -ge 70000 ] || [ "$bat" -ge 370 ] ||
       [ "$lrp" -ge 400 ] || [ "$ap" -ge 500 ]; then level=3; fi
    if [ "$cpu" -ge 70000 ] || [ "$gpu" -ge 75000 ] ||
       [ "$ddr" -ge 75000 ] || [ "$bat" -ge 400 ] ||
       [ "$lrp" -ge 430 ] || [ "$ap" -ge 550 ]; then level=4; fi
    if [ "$cpu" -ge 75000 ] || [ "$gpu" -ge 80000 ] ||
       [ "$ddr" -ge 80000 ] || [ "$bat" -ge 420 ] ||
       [ "$lrp" -ge 450 ] || [ "$ap" -ge 600 ]; then level=5; fi
    if [ "$cpu" -ge 80000 ] || [ "$gpu" -ge 85000 ] ||
       [ "$ddr" -ge 85000 ] || [ "$bat" -ge 440 ] ||
       [ "$lrp" -ge 470 ] || [ "$ap" -ge 650 ]; then level=6; fi
    [ "$hot" != 1 ] || level=6
    [ "$prev" -le "$level" ] || level=$prev
    case "$level" in
        1) pct=60 ;; 2) pct=40 ;; 3) pct=28 ;;
        4) pct=18 ;; 5) pct=12 ;; 6) pct=8 ;; *) return 3 ;;
    esac
    printf '%s:%s\n' "$level" "$pct"
}
# Scan the host's policies. No generic cpufreq_max_limit "-1" writes:
# One UI's old low-power or Samsung vendor vote must never be relaxed.
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
policies() {
    root=$1
    policies_found=0
    for pol in "$root"/sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "$pol" ] || continue
        case "${pol##*/}" in policy[0-9]*) ;; *) return 1 ;; esac
        read_single_value 2>/dev/null < "$pol/cpuinfo_max_freq" || return 1
        hw=$READ_VALUE
        read_single_value 2>/dev/null < "$pol/cpuinfo_min_freq" || return 1
        mn=$READ_VALUE
        read_single_value 2>/dev/null < "$pol/scaling_min_freq" || return 1
        active_min=$READ_VALUE
        read_single_value 2>/dev/null < "$pol/scaling_max_freq" || return 1
        cur=$READ_VALUE
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
# The guarded SM8850 candidate treats scaling_min_freq as an effective
# readback, not an independently owned MIN request. Lower MAX first and
# require BOTH effective bounds to fit the requested ceiling. Never write MIN.
# A stock SCMI MAX change may settle asynchronously through the policy worker.
strict_policy_values() {
    read_single_value 2>/dev/null < "$1/cpuinfo_max_freq" || return 1
    hw=$READ_VALUE
    read_single_value 2>/dev/null < "$1/cpuinfo_min_freq" || return 1
    mn=$READ_VALUE
    read_single_value 2>/dev/null < "$1/scaling_min_freq" || return 1
    active_min=$READ_VALUE
    read_single_value 2>/dev/null < "$1/scaling_max_freq" || return 1
    cur=$READ_VALUE
    uint "$hw" && uint "$mn" && uint "$active_min" && uint "$cur" &&
        [ "$hw" -ge 200000 ] && [ "$hw" -le 6000000 ] &&
        [ "$mn" -ge 100000 ] && [ "$mn" -le "$hw" ] &&
        [ "$active_min" -ge "$mn" ] && [ "$active_min" -le "$hw" ] &&
        [ "$cur" -ge "$mn" ] && [ "$cur" -le "$hw" ] || return 1
    target=$((hw / 100 * $2))
    [ "$target" -ge "$mn" ] || target=$mn
}
strict_write_ceiling() {
    printf '%s\n' "$2" > "$1/scaling_max_freq"
}
strict_apply_cap() {
    strict_base="$1/sys/devices/system/cpu/cpufreq"
    strict_pct=$2
    # This branch is SM-S948B/m3q specific. Fail before writes on a
    # missing or extra CPUFreq policy, rather than verify a partial set.
    [ "$policies_found" = 2 ] &&
        [ -d "$strict_base/policy0" ] && [ -d "$strict_base/policy6" ] || return 1
    strict_conflict=0
    for pol in "$strict_base/policy0" "$strict_base/policy6"; do
        strict_policy_values "$pol" "$strict_pct" || return 1
        if [ "$active_min" -gt "$target" ]; then
            strict_conflict=1
            echo "P0_CPU_CAP=MAX_FIRST_MIN_CONFLICT policy=${pol##*/} pct=$strict_pct requested_khz=$target scaling_min_khz=$active_min boot=${BOOT:-fixture} generation=${GEN:-fixture}"
        fi
        # Only lower an observed effective maximum; never raise an
        # already tighter ceiling. This is still a shared sysfs request.
        if [ "$cur" -gt "$target" ]; then
            strict_write_ceiling "$pol" "$target" || return 1
        fi
    done
    # Verify all policies AFTER all writes. Do not publish an OK heartbeat
    # based on a successful write or just the readback of one cluster.
    # Four observations, at most three 50ms sleeps. This is a bounded
    # settle allowance, not a grace period for an unenforceable cap.
    strict_attempt=0
    while :; do
        strict_bad=0
        strict_min_bad=0
        for pol in "$strict_base/policy0" "$strict_base/policy6"; do
            strict_policy_values "$pol" "$strict_pct" || return 1
            if [ "$active_min" -gt "$target" ] ||
                [ "$cur" -gt "$target" ] || [ "$active_min" -gt "$cur" ]; then
                strict_bad=1
                [ "$active_min" -le "$target" ] || strict_min_bad=1
                if [ "$strict_attempt" = 3 ]; then
                    echo "P0_CPU_CAP=MAX_FIRST_READBACK_FAILED policy=${pol##*/} pct=$strict_pct requested_khz=$target scaling_min_khz=$active_min scaling_max_khz=$cur boot=${BOOT:-fixture} generation=${GEN:-fixture}"
                    if [ "$active_min" -gt "$target" ]; then
                        echo "P0_CPU_CAP=UNENFORCEABLE_MIN_VOTE policy=${pol##*/} pct=$strict_pct requested_khz=$target scaling_min_khz=$active_min boot=${BOOT:-fixture} generation=${GEN:-fixture}"
                    fi
                fi
            fi
        done
        if [ "$strict_bad" = 0 ]; then
            if [ "$strict_conflict" = 1 ]; then
                echo "P0_CPU_CAP=MAX_FIRST_CONFLICT_READBACK_OK pct=$strict_pct boot=${BOOT:-fixture} generation=${GEN:-fixture}"
            fi
            return 0
        fi
        if [ "$strict_attempt" = 3 ]; then
            [ "$strict_min_bad" = 0 ] || return 2
            return 1
        fi
        strict_attempt=$((strict_attempt+1))
        sleep 0.05 || return 1
    done
}
# Strict mode lowers MAX and verifies the effective MIN/MAX pair, without
# clipping the requested ceiling up to a vendor floor. The existing
# separately selected lenient modes retain their explicit floor reporting.
apply_cap() {
    root=$1 pct=$2 strict=${3:-lenient}
    case "$strict" in lenient|strict) ;; *) return 1 ;; esac
    policies "$root" || return 1
    if [ "$strict" = strict ]; then
        strict_apply_cap "$root" "$pct"
        return $?
    fi

    for pol in "$root"/sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "$pol" ] || continue
        read_single_value 2>/dev/null < "$pol/cpuinfo_max_freq" || return 1
        hw=$READ_VALUE
        read_single_value 2>/dev/null < "$pol/cpuinfo_min_freq" || return 1
        mn=$READ_VALUE
        read_single_value 2>/dev/null < "$pol/scaling_min_freq" || return 1
        active_min=$READ_VALUE
        read_single_value 2>/dev/null < "$pol/scaling_max_freq" || return 1
        cur=$READ_VALUE
        uint "$hw" && uint "$mn" && uint "$active_min" && uint "$cur" &&
          [ "$active_min" -ge "$mn" ] && [ "$active_min" -le "$hw" ] || return 1
        target=$((hw / 100 * pct))
        [ "$target" -ge "$mn" ] || target=$mn
        requested=$target
        if [ "$target" -lt "$active_min" ]; then
            target=$active_min
            echo "P0_CPU_CAP=MIN_FLOOR_LIMITED policy=${pol##*/} pct=$pct requested_khz=$requested scaling_min_khz=$active_min effective_target_khz=$target boot=${BOOT:-fixture} generation=${GEN:-fixture}"
        fi
        if [ "$cur" -gt "$target" ]; then
            printf '%s\n' "$target" > "$pol/scaling_max_freq" || return 1
        fi
        read_single_value 2>/dev/null < "$pol/scaling_max_freq" || return 1
        got=$READ_VALUE
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
# BEGIN SM8850_HYSTERESIS_MODEL
# Pure candidate policy, no device access or clock writes. Source this file.
# One call per NEW validated thermal heartbeat. Output: state:pct:latch:dwell.
# pct is an independent guest CPU duty budget, NOT a shared cpufreq MAX vote.
# The separate sensor/emergency guard remains authoritative.
sm8850_thermal_hysteresis_step() (
    [ "$#" = 6 ] || exit 3
    pct=$1 latch=$2 dwell=$3 cpu=$4 gpu=$5 ddr=$6
    for n in "$pct" "$latch" "$dwell" "$cpu" "$gpu" "$ddr"; do
        case "$n" in ''|*[!0-9]*|0[0-9]*) exit 3 ;; esac
        [ "${#n}" -le 6 ] || exit 3
    done
    [ "$pct" -ge 10 ] && [ "$pct" -le 100 ] && [ "$latch" -le 1 ] &&
        [ "$dwell" -le 4 ] || exit 3
    for n in "$cpu" "$gpu" "$ddr"; do
        [ "$n" -gt 0 ] && [ "$n" -le 200000 ] || exit 3
    done
    # Use the hottest sampled junction; battery/skin and invalid sensor
    # limits are independently enforced by the existing root guard.
    peak=$cpu
    [ "$gpu" -le "$peak" ] || peak=$gpu
    [ "$ddr" -le "$peak" ] || peak=$ddr
    if [ "$peak" -ge 80000 ] || { [ "$latch" = 1 ] && [ "$peak" -gt 70000 ]; }; then
        printf 'HARD:10:1:0\n'
        exit 0
    fi
    if [ "$latch" = 1 ]; then
        # Release the hard latch at 70 C, but do not jump to full load.
        printf 'RECOVERY:10:0:0\n'
        exit 0
    fi
    if [ "$peak" -ge 70000 ]; then
        step=10
        [ "$peak" -lt 75000 ] || step=20
        pct=$((pct - step))
        [ "$pct" -ge 10 ] || pct=10
        printf 'SOFT:%s:0:0\n' "$pct"
    elif [ "$peak" -ge 65000 ]; then
        printf 'HOLD:%s:0:0\n' "$pct"
    else
        dwell=$((dwell + 1))
        if [ "$dwell" -ge 5 ]; then
            step=5
            [ "$peak" -ge 45000 ] || step=10
            pct=$((pct + step))
            [ "$pct" -le 100 ] || pct=100
            dwell=0
        fi
        printf 'COOL:%s:0:%s\n' "$pct" "$dwell"
    fi
)
# END SM8850_HYSTERESIS_MODEL
# BEGIN SM8850_CPU_BANDWIDTH
sm8850_cpu_quota_us() (
    [ "$#" = 1 ] || exit 2
    pct=$1
    case "$pct" in ''|*[!0-9]*|0[0-9]*) exit 2 ;; esac
    [ "${#pct}" -le 3 ] && [ "$pct" -ge 10 ] && [ "$pct" -le 100 ] || exit 2
    # 8 host cores, 20 ms period, integer quota in microseconds.
    printf '%s\n' "$((1600 * pct))"
)
sm8850_cpu_quota_write() {
    printf '%s\n' "$2" > "$1/cpu.cfs_quota_us"
}
sm8850_cpu_quota_apply() (
    [ "$#" = 2 ] || exit 2
    group=$1
    quota=$(sm8850_cpu_quota_us "$2") || exit 2
    [ -d "$group" ] && [ ! -L "$group" ] || exit 2
    for node in cpu.cfs_period_us cpu.cfs_quota_us; do
        [ -f "$group/$node" ] && [ ! -L "$group/$node" ] || exit 2
    done
    [ "$(cat "$group/cpu.cfs_period_us")" = 20000 ] || exit 2
    sm8850_cpu_quota_write "$group" "$quota" || exit 2
    [ "$(cat "$group/cpu.cfs_period_us")" = 20000 ] &&
        [ "$(cat "$group/cpu.cfs_quota_us")" = "$quota" ] || exit 2
    printf 'CPU_BUDGET_PCT=%s QUOTA_US=%s PERIOD_US=20000\n' "$2" "$quota"
)
# END SM8850_CPU_BANDWIDTH
# BEGIN SM8850_CFS_LIFECYCLE
# No shared cpufreq writes in this exact 180s profile. Only a unique child
# of the already-mounted v1 CPU hierarchy is controlled. Reboot-only
# recovery destroys this transient kernel group; never remove foreign groups.
bw_host_ready() {
    [ "$(realpath /dev/cpuctl)" = /dev/cpuctl ] &&
        awk '$2=="/dev/cpuctl" && $3=="cgroup" {n=split($4,a,","); for(i=1;i<=n;i++) if(a[i]=="cpu") ok=1} END {exit !ok}' /proc/mounts &&
        [ "$(cat /sys/devices/system/cpu/online)" = 0-7 ] &&
        [ "$(cat /dev/cpuctl/cpu.cfs_quota_us)" = -1 ] &&
        [ "$(cat /dev/cpuctl/cpu.cfs_period_us)" = 100000 ] &&
        [ -w /dev/cpuctl ]
}
bw_token_valid() {
    case "$1" in ''|*[!0-9a-f]*) return 1 ;; esac
    [ "${#1}" = 32 ]
}
bw_init() {
    framework_down_for_cpu_cap && bw_host_ready || return 1
    BW_TOKEN=$(cat "$CTL/framework.launch") || return 1
    bw_token_valid "$BW_TOKEN" || return 1
    BW_GROUP="/dev/cpuctl/oneios_guest.$BW_TOKEN"
    [ ! -e "$BW_GROUP" ] && [ ! -L "$BW_GROUP" ] || return 1
    mkdir "$BW_GROUP" || return 1
    [ "$(realpath "$BW_GROUP")" = "$BW_GROUP" ] &&
        [ -z "$(cat "$BW_GROUP/cgroup.procs")" ] &&
        [ "$(cat "$BW_GROUP/cpu.cfs_quota_us")" = -1 ] || return 1
    BW_ID=$(stat -c '%d:%i' "$BW_GROUP") || return 1
    printf '20000\n' > "$BW_GROUP/cpu.cfs_period_us" || return 1
    sm8850_cpu_quota_apply "$BW_GROUP" 40 || return 1
    atom thermal.cap.group "v1 $BOOT $GEN $BW_TOKEN $BW_ID" || return 1
    BW_PCT=40 BW_LATCH=0 BW_DWELL=0 BW_HSEQ=0 BW_STATE=START
}
bw_member() {
    awk -F: -v expected="$2" '$2=="cpu" && $3==expected {ok=1} END {exit !ok}' "$1"
}
bw_verify() {
    [ "$(stat -c '%d:%i' "$BW_GROUP" 2>/dev/null)" = "$BW_ID" ] &&
        [ "$(realpath "$BW_GROUP")" = "$BW_GROUP" ] &&
        [ "$(cat "$BW_GROUP/cpu.cfs_period_us")" = 20000 ] &&
        [ "$(cat "$BW_GROUP/cpu.cfs_quota_us")" = "$(sm8850_cpu_quota_us "$BW_PCT")" ] &&
        [ "$(cat /dev/cpuctl/cpu.cfs_quota_us)" = -1 ] &&
        [ "$(cat /dev/cpuctl/cpu.cfs_period_us)" = 100000 ] &&
        bw_member "/proc/$/cgroup" / || return 1
    # The guest joins before publishing its PID. Check its leader once
    # known; audit stable threads as well, allowing a thread to exit during
    # a read. Descendants inherit the CPU group; RT enforcement and any
    # future explicit task migration remain separate qualification work.
    bw_pid=$(cat "$CTL/xnuhost.pid" 2>/dev/null || :)
    if [ -n "$bw_pid" ]; then
        uint "$bw_pid" && [ "$bw_pid" -gt 1 ] || return 1
        bw_member "/proc/$bw_pid/cgroup" "/${BW_GROUP##*/}" || return 1
        bw_ns=$(cat "$CTL/mntns" 2>/dev/null || :)
        if [ -n "$bw_ns" ]; then
            [ "$(readlink "/proc/$bw_pid/ns/mnt")" = "$bw_ns" ] || return 1
        elif [ "$(cat "$CTL/state" 2>/dev/null)" = running ]; then
            return 1
        fi
        for bw_file in /proc/"$bw_pid"/task/[0-9]*/cgroup; do
            [ -e "$bw_file" ] || continue
            bw_seen=0
            if while IFS=: read -r bw_h bw_controller bw_path; do
                if [ "$bw_controller" = cpu ] && [ "$bw_path" = "/${BW_GROUP##*/}" ]; then
                    bw_seen=1
                fi
            done 2>/dev/null < "$bw_file"; then :; fi
            [ "$bw_seen" = 1 ] || [ ! -e "$bw_file" ] || return 1
        done
    elif [ "$(cat "$CTL/state" 2>/dev/null)" = running ]; then
        return 1
    fi
}
bw_aux_limit() {
    # Keep the old early battery/skin/board thresholds. A cold junction
    # must not authorize more load when non-junction sensors are hot.
    bw_limit=100
    if [ "$bat" -ge 340 ] || [ "$lrp" -ge 370 ] || [ "$ap" -ge 450 ]; then bw_limit=40; fi
    if [ "$bat" -ge 370 ] || [ "$lrp" -ge 400 ] || [ "$ap" -ge 500 ]; then bw_limit=28; fi
    if [ "$bat" -ge 400 ] || [ "$lrp" -ge 430 ] || [ "$ap" -ge 550 ]; then bw_limit=18; fi
    if [ "$bat" -ge 420 ] || [ "$lrp" -ge 450 ] || [ "$ap" -ge 600 ]; then bw_limit=12; fi
    if [ "$bat" -ge 440 ] || [ "$lrp" -ge 470 ] || [ "$ap" -ge 650 ]; then bw_limit=10; fi
}
bw_step() {
    # Validate the already-applied quota BEFORE considering another write.
    bw_verify || return 1
    [ "$hseq" -ge "$BW_HSEQ" ] || return 1
    [ "$hseq" != "$BW_HSEQ" ] || return 0
    # The existing independent sensor/emergency contract is not replaced.
    # policy 0 validates all six sensors and refuses last-resort thresholds.
    (policy 0 "$cpu" "$gpu" "$ddr" "$bat" "$lrp" "$ap") >/dev/null || return 1
    bw_choice=$(sm8850_thermal_hysteresis_step "$BW_PCT" "$BW_LATCH" "$BW_DWELL" "$cpu" "$gpu" "$ddr") || return 1
    bw_state=${bw_choice%%:*}
    bw_tail=${bw_choice#*:}
    bw_next=${bw_tail%%:*}
    bw_tail=${bw_tail#*:}
    bw_latch=${bw_tail%%:*}
    bw_dwell=${bw_tail#*:}
    bw_aux_limit
    if [ "$bw_next" -gt "$bw_limit" ]; then bw_next=$bw_limit; bw_dwell=0; fi
    if [ "$bw_next" != "$BW_PCT" ]; then
        sm8850_cpu_quota_apply "$BW_GROUP" "$bw_next" || return 1
    fi
    if [ "$bw_next" != "$BW_PCT" ] || [ "$bw_state" != "$BW_STATE" ] || [ "$bw_latch" != "$BW_LATCH" ]; then
        echo "P0_CPU_BUDGET=APPLIED boot=$BOOT generation=$GEN sample=$hseq cpu_mC=$cpu gpu_mC=$gpu ddr_mC=$ddr from_pct=$BW_PCT pct=$bw_next state=$bw_state hard_latch=$bw_latch auxiliary_limit=$bw_limit"
    fi
    BW_PCT=$bw_next BW_LATCH=$bw_latch BW_DWELL=$bw_dwell BW_STATE=$bw_state BW_HSEQ=$hseq
    bw_verify
}
# END SM8850_CFS_LIFECYCLE

# The only nonroot write mode uses disposable synthetic sysfs, NEVER real sysfs.
# It is for CachyOS tests and cannot name / or a live Android path.
MODE=${1:-}
FLOOR_MODE=0
[ "$MODE" != --run-prearmed-floor ] || FLOOR_MODE=1
case "$MODE" in
    --policy)
        shift
        policy "$@"; exit $? ;;
    --policy-floor)
        shift
        FLOOR_MODE=1
        policy "$@"; exit $? ;;
    --fixture-step|--fixture-strict-step|--fixture-floor-step)
        [ "$#" = 3 ] || die fixture_args
        [ "$(id -u)" != 0 ] || die fixture_must_be_unprivileged
        case "$2" in /tmp/oneios-cpu-cap-test.*) ;; *) die fixture_path ;; esac
        [ -d "$2" ] && [ ! -L "$2" ] || die fixture_root
        case "$3" in 60|40|28|18|12|8) ;; *) die invalid_fixture_percent ;; esac
        fixture_strict=lenient
        [ "$MODE" != --fixture-strict-step ] || fixture_strict=strict
        [ "$MODE" != --fixture-floor-step ] || FLOOR_MODE=1
        apply_cap "$2" "$3" "$fixture_strict" || die fixture_policy_failed
        echo "P0_CPU_CAP=FIXTURE_APPLIED pct=$3 strict=$fixture_strict"
        exit 0 ;;
    --check-bandwidth)
        [ "$#" = 1 ] && [ "$(id -u)" = 0 ] || die root_required
        bw_host_ready || die v1_cpu_bandwidth_unavailable
        echo "SM8850_CPU_THROTTLE_POLICY=CFS_V1_TARGET_45_70_HARD_80_RELEASE_70"
        echo "P0_CPU_CAP=READ_ONLY_BANDWIDTH_AVAILABLE_NOT_CERTIFIED"
        exit 0 ;;
    --check)
        [ "$#" = 1 ] || die args
        [ "$(id -u)" = 0 ] || die root_required
        policies "" || die host_cpufreq_unavailable
        echo "P0_CPU_CAP=READ_ONLY_POLICY_AVAILABLE_NOT_CERTIFIED"
        echo "SM8850_CPU_THROTTLE_POLICY=TARGET_30_70_THROTTLE_BY_75_MONOTONIC"
        exit 0 ;;
    --run-best-effort)
        # Explicit 180s no-software-thermal-guard experiment. Only the
        # post-stop helper requests 28% scaling_max_freq. It has NO thermal
        # sensor reader, guard heartbeat, or authority to request reboot.
        # A vendor min vote or sysfs error is logged, not a fatal cap fault.
        [ "$#" = 3 ] || die args
        [ "$(id -u)" = 0 ] || die root_required
        CTL=$2; GEN=$3
        [ "$CTL" = /data/adb/oneios-m3q-framework/control ] || die control_path
        [ -d "$CTL" ] && [ ! -L "$CTL" ] &&
          [ "$(stat -c %u "$CTL" 2>/dev/null)" = 0 ] || die untrusted_control
        BOOT=$(cat "$CTL/boot" 2>/dev/null) || die boot_unknown
        [ "$BOOT" = "$(cat /proc/sys/kernel/random/boot_id)" ] &&
          [ "$GEN" = "$(cat "$CTL/watchdog.generation" 2>/dev/null)" ] &&
          [ "$(cat "$CTL/framework.mode" 2>/dev/null)" = run ] &&
          [ "$(cat "$CTL/framework.duration" 2>/dev/null)" = 180 ] &&
          [ "$(cat "$CTL/framework.soft-thermal" 2>/dev/null)" = disabled-180s ] ||
            die untrusted_experimental_session
        framework_down_for_cpu_cap || die framework_not_stopped
        echo $$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null
        echo -1000 > /proc/$$/oom_score_adj 2>/dev/null
        echo "P0_CPU_CAP=BEST_EFFORT_FIXED_28_PERCENT_NO_THERMAL_GUARD_NO_REBOOT"
        seq=0
        while [ "$GEN" = "$(cat "$CTL/watchdog.generation" 2>/dev/null)" ]; do
            [ "$BOOT" = "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" ] || exit 0
            case "$(cat "$CTL/state" 2>/dev/null)" in
                starting|running) ;;
                *) exit 0 ;;
            esac
            [ ! -e "${CTL%/control}/session/return.request" ] || exit 0
            seq=$((seq + 1))
            if apply_cap "" 28 lenient; then
                printf '%s\n' "seq=$seq boot=$BOOT gen=$GEN pct=28 status=APPLIED_OR_ALREADY_TIGHTER" > "$CTL/cpu.best-effort.status" || :
                [ $((seq % 10)) -ne 1 ] || echo "P0_CPU_CAP=BEST_EFFORT_28_PERCENT_OK seq=$seq"
            else
                printf '%s\n' "seq=$seq boot=$BOOT gen=$GEN pct=28 status=UNVERIFIED_NO_RETURN" > "$CTL/cpu.best-effort.status" || :
                echo "P0_CPU_CAP=BEST_EFFORT_APPLY_FAILED_NO_RETURN seq=$seq"
            fi
            sleep 1
        done
        exit 0 ;;
    --run|--run-prearmed|--run-prearmed-floor)
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
        BW_MODE=0
        case "$(cat "$CTL/framework.cpu-budget" 2>/dev/null || :)" in
            cfs-v1-180s)
                [ "$MODE" = --run-prearmed ] && [ "$(cat "$CTL/framework.duration")" = 180 ] &&
                    bw_host_ready || die bandwidth_profile
                BW_MODE=1
                # Move only this root worker out of any inherited Android
                # CPU restriction, not an Android service or parent quota.
                printf '%s\n' "$" > /dev/cpuctl/cgroup.procs || die cap_root_cpu_group
                bw_member "/proc/$/cgroup" / || die cap_root_cpu_membership ;;
            '') policies "" || die cpufreq_unavailable ;;
            *) die unknown_cpu_budget_profile ;;
        esac
        echo $ > /sys/fs/cgroup/cgroup.procs 2>/dev/null
        echo -1000 > /proc/$$/oom_score_adj 2>/dev/null
        BIRTH=$(birth $$)
        [ -n "$BIRTH" ] || die no_pid_birth
        atom thermal.cap.pid "$$ $BIRTH" || die cap_pid_write
        if [ "$MODE" = --run-prearmed ] || [ "$MODE" = --run-prearmed-floor ]; then
            # Publish trusted PID/birth identity while still read-only.
            # The switch validates this BEFORE it can stop system_server.
            atom thermal.cap.prearmed "v1 $BOOT $GEN $$ $BIRTH" ||
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
                    if [ "$BW_MODE" = 1 ]; then
                        echo "P0_CPU_CAP=FRAMEWORK_DOWN_VERIFIED_START_CFS_V1 boot=$BOOT generation=$GEN"
                    else
                        echo "P0_CPU_CAP=FRAMEWORK_DOWN_VERIFIED_START_STRICT boot=$BOOT generation=$GEN"
                    fi
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
        # SM8850 full-guest boot is an immediate CPU burst, not an idle
        # workload. Starting at 40% rather than 60% increases thermal
        # headroom; it has NOT been proven to prevent the prior 95 C event.
        # level 2 (40%) on the first validated post-stop heartbeat.
        # Do NOT lower scaling_min_freq or relax vendor/firmware protection.
        # Subsequent cap levels remain monotonic and stricter when hot.
        level=2
        seq=0
        if [ "$BW_MODE" = 1 ]; then
            bw_init || fault isolated_cpu_group_init
            level=7
            echo "P0_CPU_BUDGET=BOOT_INITIAL pct=40 group=$BW_GROUP boot=$BOOT generation=$GEN"
        elif [ "$FLOOR_MODE" = 1 ]; then
            level=3
            echo "P0_CPU_CAP=EXPERIMENTAL_FLOOR_AWARE_INITIAL_28_PERCENT boot=$BOOT generation=$GEN"
        else
            echo "P0_CPU_CAP=BOOT_STRICT_BASELINE_REQUESTED pct=40 boot=$BOOT generation=$GEN"
        fi
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
                [ "$hseq" -gt 0 ] || fault "stale_guard_sample now=$now sample=$ht seq=$hseq"
            if [ "$BW_MODE" = 1 ]; then
                bw_step || fault isolated_cpu_bandwidth_or_membership
                desired=7
                pct=$BW_PCT
            else
            choice=$(policy "$level" "$cpu" "$gpu" "$ddr" "$bat" "$lrp" "$ap") ||
                fault invalid_or_emergency_temperature
            desired=${choice%%:*}
            pct=${choice#*:}
            # Revalidate on every tick. In strict mode a high MIN may be
            # resolved by a lower MAX, but both effective bounds must pass
            # before the existing independent watcher sees an OK heartbeat.
            # Never silently lift the strict ceiling to a vendor floor.
            if [ "$FLOOR_MODE" = 1 ]; then
                apply_cap "" "$pct" lenient
            else
                apply_cap "" "$pct" strict
            fi
            cap_rc=$?
            case "$cap_rc" in
                0) ;;
                2) fault "unachievable_cpu_cap_floor level=$desired pct=$pct" ;;
                *) fault cpufreq_write_or_readback ;;
            esac
            fi
            if [ "$FLOOR_MODE" != 1 ]; then
                # A bounded QoS settle must not turn a previously fresh
                # guard sample into an optimistic, newly stamped heartbeat.
                now=$(tick) || fault invalid_uptime
                [ "$ht" -le "$now" ] && [ $((now-ht)) -le 3 ] ||
                    fault "stale_guard_sample now=$now sample=$ht seq=$hseq"
                [ ! -e "$CTL/thermal.guard.fault" ] || fault thermal_guard_fault
                [ ! -e "${CTL%/control}/session/return.request" ] || exit 0
                [ "$GEN" = "$(cat "$CTL/watchdog.generation" 2>/dev/null)" ] || exit 0
            fi
            if [ "$BW_MODE" != 1 ] && { [ "$desired" -ne "$level" ] || [ "$seq" -eq 0 ]; }; then
                echo "P0_CPU_THROTTLE=CAP_APPLIED boot=$BOOT generation=$GEN cpu_mC=$cpu from_level=$level level=$desired pct=$pct target_c=30-70 no_reboot_at_75=YES"
            fi
            level=$desired
            seq=$((seq+1))
            atom thermal.cap.heartbeat "v1 $BOOT $GEN $$ $BIRTH $seq $now OK $level $pct" ||
                fault cannot_publish_heartbeat
            if [ "$seq" = 1 ]; then
                if [ "$BW_MODE" = 1 ]; then
                    echo "P0_CPU_BUDGET=ARMED_CFS_V1_NOT_THERMAL_CERTIFIED pct=$pct"
                else
                    echo "P0_CPU_CAP=ARMED_INDEPENDENT_ROOT_CAP_NOT_HARDWARE_CERTIFIED pct=$pct floor_aware=$FLOOR_MODE"
                fi
            fi
            sleep 1
        done
        exit 0 ;;
    *) die usage ;;
esac
