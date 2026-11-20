#!/system/bin/sh
# SM8850 P0 independent thermal sensor reader: ONE SHOT, READ ONLY.
# This is NOT a thermal supervisor and NEVER issues a return/reboot.
# No sysfs enumeration. The three exact nodes were passively tested on
# SM-S948B/m3q/S948BXXS4BZIG, 2026-11-20, with root for BAT/LRP.
#
# --fixture-root DIR  host-only simulation from exactly the same node paths.
# --live-readonly     explicit root-only, stock One UI snapshot; does NOT run
#                     while Framework is down and does NOT install anything.
#
# TODO P0: dedicated supervisor + qualified thresholds + independent watcher.
set -u

usage() {
    echo 'usage: oneios_sm8850_thermal_reader.sh --fixture-root ABS_DIR | --live-readonly' >&2
    exit 2
}

[ "$#" -ge 1 ] || usage
ROOT=''
MODE=$1
case "$MODE" in
    --fixture-root)
        [ "$#" -eq 2 ] || usage
        ROOT=$2
        case "$ROOT" in /*) ;; *) usage ;; esac
        [ "$ROOT" != / ] && [ -d "$ROOT" ] || usage
        ;;
    --live-readonly)
        [ "$#" -eq 1 ] || usage
        [ "$(id -u)" = 0 ] || {
            echo 'THERMAL_READER=BLOCKED_NOT_ROOT' >&2
            exit 3
        }
        [ "$(getprop ro.product.model)" = SM-S948B ] &&
        [ "$(getprop ro.product.device)" = m3q ] &&
        [ "$(getprop ro.build.version.incremental)" = S948BXXS4BZIG ] &&
        [ "$(getprop sys.boot_completed)" = 1 ] &&
        [ "$(getenforce)" = Enforcing ] &&
        pidof system_server >/dev/null 2>&1 || {
            echo 'THERMAL_READER=BLOCKED_IDENTITY_OR_ONEUI' >&2
            exit 3
        }
        ;;
    *) usage ;;
esac

# Do not emit a usable snapshot until every required field is valid.
# An invalid/unavailable value never becomes zero or a previous value.
read_deci() { # one exact, caller-owned path, raw tenths of a degree
    RAW=$(cat "$ROOT$1" 2>/dev/null) || return 1
    printf '%s\n' "$RAW" | grep -Eq '^[0-9]{1,4}$' || return 1
    [ "$RAW" -gt 0 ] && [ "$RAW" -le 1200 ] || return 1
    printf '%s\n' "$RAW"
}

BOOT0=$(cat "$ROOT/proc/sys/kernel/random/boot_id" 2>/dev/null) || {
    echo 'THERMAL_READER=BLOCKED_BOOT_ID' >&2; exit 3;
}
case "$BOOT0" in
    ????????-????-????-????-????????????) ;;
    *) echo 'THERMAL_READER=BLOCKED_BOOT_ID_FORMAT' >&2; exit 3 ;;
esac
START=$(cat "$ROOT/proc/uptime" 2>/dev/null) || {
    echo 'THERMAL_READER=BLOCKED_UPTIME' >&2; exit 3;
}
BAT=$(read_deci /sys/class/power_supply/battery/temp) || {
    echo 'THERMAL_READER=UNKNOWN_BATTERY' >&2; exit 3;
}
LRP=$(read_deci /sys/class/power_supply/battery/lrp) || {
    echo 'THERMAL_READER=UNKNOWN_LRP' >&2; exit 3;
}
BOARD_AP=$(read_deci /sys/class/sec/sec-ap-thermistor/temperature) || {
    echo 'THERMAL_READER=UNKNOWN_BOARD_AP' >&2; exit 3;
}
END=$(cat "$ROOT/proc/uptime" 2>/dev/null) || {
    echo 'THERMAL_READER=BLOCKED_UPTIME' >&2; exit 3;
}
BOOT1=$(cat "$ROOT/proc/sys/kernel/random/boot_id" 2>/dev/null) || {
    echo 'THERMAL_READER=BLOCKED_BOOT_ID' >&2; exit 3;
}
[ "$BOOT0" = "$BOOT1" ] || {
    echo 'THERMAL_READER=BLOCKED_MIXED_BOOT' >&2; exit 3;
}

printf 'THERMAL_READER=READ_ONLY_SNAPSHOT_NOT_GUARD\n'
printf 'source=%s\n' "$MODE"
printf 'boot_id=%s\n' "$BOOT0"
printf 'uptime_start=%s\n' "${START%% *}"
printf 'uptime_end=%s\n' "${END%% *}"
printf 'battery_deci_c=%s\n' "$BAT"
printf 'lrp_deci_c=%s\n' "$LRP"
printf 'board_ap_deci_c=%s\n' "$BOARD_AP"
