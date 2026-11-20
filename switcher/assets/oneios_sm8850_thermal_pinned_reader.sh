#!/system/bin/sh
# SM8850 4-node THERMAL READER PROTOTYPE. One shot; no thermal actions.
# A caller must pin the current boot ID and a previously mapped zone index.
# The index is NEVER trusted as a thermal sensor identity by itself: its
# sysfs /type must equal cpu-0-5-1 both before and after the sample.
# No enumeration, guest, watcher, watchdog, return, or kernel writes.
# Not qualified for use when Android Framework is stopped.
set -u
LC_ALL=C
export LC_ALL

usage() {
    echo 'usage: pinned_reader --fixture-root /tmp/FIXTURE ZONE_INDEX BOOT_UUID | --live-oneui-readonly ZONE_INDEX BOOT_UUID' >&2
    exit 2
}
blocked() {
    echo "THERMAL_PINNED=BLOCKED_NOT_GUARD reason=$1" >&2
    exit 4
}
[ "$#" -ge 1 ] || usage
MODE=$1
ROOT=''
case "$MODE" in
    --fixture-root)
        [ "$#" -eq 4 ] || usage
        ROOT=$2
        IDX=$3
        EXPECTED_BOOT=$4
        case "$ROOT" in /tmp/*) ;; *) usage ;; esac
        [ -d "$ROOT" ] && [ ! -L "$ROOT" ] || usage
        ROOT=$(realpath "$ROOT" 2>/dev/null) || usage
        case "$ROOT" in /tmp/?*) ;; *) usage ;; esac
        ;;
    --live-oneui-readonly)
        [ "$#" -eq 3 ] || usage
        IDX=$2
        EXPECTED_BOOT=$3
        [ "$(id -u 2>/dev/null)" = 0 ] || blocked not_root
        [ "$(getprop ro.product.model)" = SM-S948B ] &&
        [ "$(getprop ro.product.device)" = m3q ] &&
        [ "$(getprop ro.build.version.incremental)" = S948BXXS4BZIG ] &&
        [ "$(getprop sys.boot_completed)" = 1 ] &&
        [ "$(getenforce)" = Enforcing ] &&
        pidof system_server >/dev/null 2>&1 || blocked device_or_oneui_mismatch
        ;;
    *) usage ;;
esac

# Do not interpolate arbitrary caller-supplied paths into shell commands.
case "$IDX" in ''|*[!0-9]*) usage ;; esac
[ "${#IDX}" -le 3 ] || usage
[ "$IDX" -ge 0 ] && [ "$IDX" -le 255 ] || usage
case "$IDX" in 0|[1-9]|[1-9][0-9]|[1-2][0-9][0-9]) ;; *) usage ;; esac
printf '%s\n' "$EXPECTED_BOOT" | grep -Eq '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' || usage

BOOTFILE="$ROOT/proc/sys/kernel/random/boot_id"
UPTIMEFILE="$ROOT/proc/uptime"
CPU_DIR="$ROOT/sys/class/thermal/thermal_zone$IDX"
CPU_TYPE_FILE="$CPU_DIR/type"
CPU_TEMP_FILE="$CPU_DIR/temp"
BAT_FILE="$ROOT/sys/class/power_supply/battery/temp"
LRP_FILE="$ROOT/sys/class/power_supply/battery/lrp"
AP_FILE="$ROOT/sys/class/sec/sec-ap-thermistor/temperature"

# For host fixture mode, reject any symlink escaping the fixture directory.
# Sysfs /sys/class/thermal links are normal in live mode, so this restriction
# applies only to test fixtures (never to live root mounts).
if [ "$MODE" = --fixture-root ]; then
    for path in "$BOOTFILE" "$UPTIMEFILE" "$CPU_TYPE_FILE" "$CPU_TEMP_FILE" "$BAT_FILE" "$LRP_FILE" "$AP_FILE"; do
        [ -f "$path" ] && [ ! -L "$path" ] || blocked fixture_missing_or_linked
        resolved=$(realpath "$path" 2>/dev/null) || blocked fixture_canonicalization
        case "$resolved" in "$ROOT"/*) ;; *) blocked fixture_path_escape ;; esac
    done
fi

BOOT0=$(cat "$BOOTFILE" 2>/dev/null) || blocked boot_unavailable
[ "$BOOT0" = "$EXPECTED_BOOT" ] || blocked wrong_boot
TYPE0=$(cat "$CPU_TYPE_FILE" 2>/dev/null) || blocked cpu_type_unavailable
[ "$TYPE0" = cpu-0-5-1 ] || blocked cpu_type_mismatch
START=$(cat "$UPTIMEFILE" 2>/dev/null) || blocked uptime_unavailable
START=${START%% *}
printf '%s\n' "$START" | grep -Eq '^[0-9]+([.][0-9]+)?$' || blocked invalid_uptime

read_deci() {
    VALUE=$(cat "$1" 2>/dev/null) || return 1
    printf '%s\n' "$VALUE" | grep -Eq '^[1-9][0-9]{0,3}$' || return 1
    [ "$VALUE" -le 1200 ] || return 1
    printf '%s\n' "$VALUE"
}
BAT=$(read_deci "$BAT_FILE") || blocked invalid_battery
LRP=$(read_deci "$LRP_FILE") || blocked invalid_lrp
AP=$(read_deci "$AP_FILE") || blocked invalid_board_ap
CPU=$(cat "$CPU_TEMP_FILE" 2>/dev/null) || blocked cpu_unavailable
printf '%s\n' "$CPU" | grep -Eq '^[1-9][0-9]{0,5}$' || blocked invalid_cpu_millidegrees
[ "$CPU" -le 149999 ] || blocked invalid_cpu_millidegrees

TYPE1=$(cat "$CPU_TYPE_FILE" 2>/dev/null) || blocked cpu_type_unavailable_after_read
[ "$TYPE1" = cpu-0-5-1 ] || blocked cpu_type_changed
END=$(cat "$UPTIMEFILE" 2>/dev/null) || blocked uptime_unavailable_after_read
END=${END%% *}
printf '%s\n' "$END" | grep -Eq '^[0-9]+([.][0-9]+)?$' || blocked invalid_uptime_after_read
awk -v start="$START" -v end="$END" 'BEGIN {if (end < start || end - start > 3) exit 1}' || blocked invalid_sample_duration
BOOT1=$(cat "$BOOTFILE" 2>/dev/null) || blocked boot_unavailable_after_read
[ "$BOOT1" = "$EXPECTED_BOOT" ] || blocked boot_changed
if [ "$MODE" = --live-oneui-readonly ]; then
    [ "$(getprop sys.boot_completed)" = 1 ] &&
    [ "$(getenforce)" = Enforcing ] &&
    pidof system_server >/dev/null 2>&1 || blocked oneui_changed
fi
# No partial-success output is emitted until all four sensors and identities pass.
printf 'THERMAL_PINNED=FOUR_SENSOR_READ_ONLY_NOT_GUARD\n'
printf 'source=%s\n' "$MODE"
printf 'boot_id=%s\n' "$EXPECTED_BOOT"
printf 'cpu_zone_type=cpu-0-5-1\n'
printf 'cpu_zone_path=/sys/class/thermal/thermal_zone%s/temp\n' "$IDX"
printf 'cpu_milli_c=%s\n' "$CPU"
printf 'cpu_deci_c=%s\n' "$(((CPU + 50) / 100))"
printf 'battery_deci_c=%s\n' "$BAT"
printf 'lrp_deci_c=%s\n' "$LRP"
printf 'board_ap_deci_c=%s\n' "$AP"
printf 'uptime_start=%s\n' "$START"
printf 'uptime_end=%s\n' "$END"
printf 'after_framework_available=NOT_VERIFIED\n'
