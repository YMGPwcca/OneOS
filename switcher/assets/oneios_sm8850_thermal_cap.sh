#!/system/bin/sh
# SM8850 OneiOS: independent CPU frequency cap for the short Framework probe.
# Adapted from fahadalijaved/OneOS oneos_heat_cap, NOT its SKIN=45/47/50
# thresholds. This worker reads the already-verified root thermal heartbeat.
#
# The cap only LOWERS scaling_max_freq. It never releases SSRM/KernelSU limits,
# touches thermal trips, changes GPU clocks, or raises clocks during a session.
# The original root thermal guard and reboot-return still decide emergency abort.
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
# Input: previous level, CPU/GPU/DDR milliC, battery/LRP/boardAP deciC.
# Output: one of 1:80, 2:65, 3:50. A new session starts at level 1 (80%).
# Conservative source-only candidate: these are NOT hardware-certified values.
# Levels are monotonic during a session; no clock is raised until phone reboot.
policy() {
    [ "$#" = 7 ] || return 3
    prev=$1; cpu=$2; gpu=$3; ddr=$4; bat=$5; lrp=$6; ap=$7
    for n in "$prev" "$cpu" "$gpu" "$ddr" "$bat" "$lrp" "$ap"; do
        uint "$n" || return 3
    done
    [ "$prev" -le 3 ] || return 3
    [ "$cpu" -gt 0 ] && [ "$cpu" -le 200000 ] &&
        [ "$gpu" -gt 0 ] && [ "$gpu" -le 200000 ] &&
        [ "$ddr" -gt 0 ] && [ "$ddr" -le 200000 ] || return 3
    for n in "$bat" "$lrp" "$ap"; do
        [ "$n" -gt 0 ] && [ "$n" -le 1200 ] || return 3
    done
    # Emergency still belongs to the independent guard: never treat a CPU
    # reduction as permission to continue beyond any of these abort cutoffs.
    if [ "$cpu" -ge 55000 ] || [ "$gpu" -ge 55000 ] ||
       [ "$ddr" -ge 55000 ] || [ "$bat" -ge 380 ] ||
       [ "$lrp" -ge 420 ] || [ "$ap" -ge 420 ]; then
        return 2
    fi
    level=1
    if [ "$cpu" -ge 42000 ] || [ "$gpu" -ge 43000 ] ||
       [ "$ddr" -ge 43000 ] || [ "$bat" -ge 330 ] ||
       [ "$lrp" -ge 350 ] || [ "$ap" -ge 350 ]; then level=2; fi
    if [ "$cpu" -ge 48000 ] || [ "$gpu" -ge 49000 ] ||
       [ "$ddr" -ge 49000 ] || [ "$bat" -ge 360 ] ||
       [ "$lrp" -ge 390 ] || [ "$ap" -ge 390 ]; then level=3; fi
    [ "$prev" -le "$level" ] || level=$prev
    case "$level" in 1) pct=80 ;; 2) pct=65 ;; 3) pct=50 ;; *) return 3 ;; esac
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
        cur=$(cat "$pol/scaling_max_freq" 2>/dev/null) || return 1
        uint "$hw" && uint "$cur" && [ "$hw" -ge 200000 ] &&
          [ "$hw" -le 6000000 ] && [ "$cur" -ge 100000 ] &&
          [ "$cur" -le "$hw" ] && [ -w "$pol/scaling_max_freq" ] || return 1
        policies_found=$((policies_found+1))
        [ "$policies_found" -le 8 ] || return 1
    done
    [ "$policies_found" -ge 2 ]
}
# Desired cap computed from hardware maximum; actual target is NEVER greater
# than the CURRENT cap, so no external lower cap is undone.
apply_cap() {
    root=$1 pct=$2
    policies "$root" || return 1
    for pol in "$root"/sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "$pol" ] || continue
        hw=$(cat "$pol/cpuinfo_max_freq" 2>/dev/null) || return 1
        cur=$(cat "$pol/scaling_max_freq" 2>/dev/null) || return 1
        target=$((hw / 100 * pct))
        [ "$target" -ge 100000 ] || return 1
        if [ "$cur" -gt "$target" ]; then
            printf '%s\n' "$target" > "$pol/scaling_max_freq" || return 1
            got=$(cat "$pol/scaling_max_freq" 2>/dev/null) || return 1
            uint "$got" && [ "$got" -le "$target" ] || return 1
        fi
    done
}
# The only nonroot write mode uses disposable synthetic sysfs, NEVER real sysfs.
# It is for CachyOS tests and cannot name / or a live Android path.
MODE=${1:-}
case "$MODE" in
    --policy)
        shift
        policy "$@"; exit $? ;;
    --fixture-step)
        [ "$#" = 3 ] || die fixture_args
        [ "$(id -u)" != 0 ] || die fixture_must_be_unprivileged
        case "$2" in /tmp/oneios-cpu-cap-test.*) ;; *) die fixture_path ;; esac
        [ -d "$2" ] && [ ! -L "$2" ] || die fixture_root
        case "$3" in 80|65|50) ;; *) die invalid_fixture_percent ;; esac
        apply_cap "$2" "$3" || die fixture_policy_failed
        echo "P0_CPU_CAP=FIXTURE_APPLIED pct=$3"
        exit 0 ;;
    --check)
        [ "$#" = 1 ] || die args
        [ "$(id -u)" = 0 ] || die root_required
        policies "" || die host_cpufreq_unavailable
        echo "P0_CPU_CAP=READ_ONLY_POLICY_AVAILABLE_NOT_CERTIFIED"
        exit 0 ;;
    --run)
        [ "$#" = 3 ] || die args
        [ "$(id -u)" = 0 ] || die root_required
        CTL=$2 GEN=$3
        [ "$CTL" = /data/adb/oneios-m3q-framework/control ] || die control_path
        [ -d "$CTL" ] && [ ! -L "$CTL" ] &&
          [ "$(stat -c %u "$CTL" 2>/dev/null)" = 0 ] || die untrusted_control
        BOOT=$(cat "$CTL/boot" 2>/dev/null) || die boot_unknown
        [ "$BOOT" = "$(cat /proc/sys/kernel/random/boot_id)" ] &&
          [ "$GEN" = "$(cat "$CTL/watchdog.generation" 2>/dev/null)" ] &&
          [ "$(cat "$CTL/framework.mode" 2>/dev/null)" = probe ] || die stale_session
        policies "" || die cpufreq_unavailable
        echo $$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null
        echo -1000 > /proc/$$/oom_score_adj 2>/dev/null
        BIRTH=$(birth $$)
        [ -n "$BIRTH" ] || die no_pid_birth
        atom thermal.cap.pid "$$ $BIRTH" || die cap_pid_write
        level=0
        seq=0
        while [ "$GEN" = "$(cat "$CTL/watchdog.generation" 2>/dev/null)" ]; do
            case "$(cat "$CTL/state" 2>/dev/null)" in
                returning|returned|failed) exit 0 ;;
                starting|running) ;;
                *) fault invalid_session_state ;;
            esac
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
            apply_cap "" "$pct" || fault cpufreq_write_or_readback
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
