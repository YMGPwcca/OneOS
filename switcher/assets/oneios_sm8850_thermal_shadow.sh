#!/system/bin/sh
# SM8850 independent thermal SHADOW sampler (read-only, NOT a guard).
# No return request, reboot, sysfs scan, watchdog open or host clock writes.
# Explicit, bounded execution. It is NOT enabled by oneios_switch.sh.
# Modes:
# --fixture-root DIR BOOT GENERATION LAUNCH SAMPLES: offline, fake paths only
# --live-oneui-readonly SAMPLES: stock Android with root, no session takeover
set -u

usage() { echo 'usage: shadow --fixture-root DIR BOOT GENERATION LAUNCH SAMPLES | --live-oneui-readonly SAMPLES' >&2; exit 2; }
failed() { echo "THERMAL_SHADOW=FAIL_CLOSED_NO_PHYSICAL_ACTION reason=$1" >&2; exit 4; }
[ "$#" -ge 1 ] || usage
MODE=$1
ROOT=''
BOOT_EXPECTED=''
GEN_EXPECTED=''
LAUNCH_EXPECTED=''
case "$MODE" in
    --fixture-root)
        [ "$#" -eq 6 ] || usage
        ROOT=$2 BOOT_EXPECTED=$3 GEN_EXPECTED=$4 LAUNCH_EXPECTED=$5 SAMPLES=$6
        case "$ROOT" in /*) ;; *) usage ;; esac
        [ -d "$ROOT" ] && [ ! -L "$ROOT" ] || usage
        ROOT=$(realpath "$ROOT") || usage
        case "$ROOT" in /tmp/*) ;; *) usage ;; esac
        case "$BOOT_EXPECTED" in ????????-????-????-????-????????????) ;; *) usage ;; esac
        case "$GEN_EXPECTED" in ''|*[!a-zA-Z0-9._:-]*) usage ;; esac
        case "$LAUNCH_EXPECTED" in ''|*[!a-f0-9]*) usage ;; esac
        [ "${#LAUNCH_EXPECTED}" -eq 32 ] || usage
        ;;
    --live-oneui-readonly)
        [ "$#" -eq 2 ] || usage
        SAMPLES=$2
        [ "$(id -u)" = 0 ] || failed not_root
        ;;
    *) usage ;;
esac
case "$SAMPLES" in 1|2|3|4|5|6|7|8|9|10) ;; *) usage ;; esac
command -v timeout >/dev/null 2>&1 || failed missing_timeout

# Read exact session evidence in fixture only. No implicit live file path.
check_fixture() {
    for rel in \
        /proc/sys/kernel/random/boot_id \
        /proc/uptime \
        /sys/class/power_supply/battery/temp \
        /sys/class/power_supply/battery/lrp \
        /sys/class/sec/sec-ap-thermistor/temperature \
        /data/adb/oneios-m3q-framework/control/watchdog.generation \
        /data/adb/oneios-m3q-framework/control/framework.launch \
        /data/adb/oneios-m3q-framework/control/thermal.sim.watcher-alive; do
        [ -f "$ROOT$rel" ] && [ ! -L "$ROOT$rel" ] || failed missing_or_linked_fixture
        case "$(realpath "$ROOT$rel")" in "$ROOT"/*) ;; *) failed fixture_escape ;; esac
    done
    boot=$(cat "$ROOT/proc/sys/kernel/random/boot_id" 2>/dev/null) || failed boot_read
    gen=$(cat "$ROOT/data/adb/oneios-m3q-framework/control/watchdog.generation" 2>/dev/null) || failed generation_read
    launch=$(cat "$ROOT/data/adb/oneios-m3q-framework/control/framework.launch" 2>/dev/null) || failed launch_read
    watcher=$(cat "$ROOT/data/adb/oneios-m3q-framework/control/thermal.sim.watcher-alive" 2>/dev/null) || failed watcher_read
    [ "$boot" = "$BOOT_EXPECTED" ] && [ "$gen" = "$GEN_EXPECTED" ] && \
        [ "$launch" = "$LAUNCH_EXPECTED" ] && [ "$watcher" = 1 ] || failed stale_boot_run_or_watcher
}

readfile="$(dirname "$0")/oneios_sm8850_thermal_reader.sh"
[ -f "$readfile" ] && [ ! -L "$readfile" ] || failed reader_missing_or_linked
n=1
while [ "$n" -le "$SAMPLES" ]; do
    [ "$MODE" != --fixture-root ] || check_fixture
    if [ "$MODE" = --fixture-root ]; then
        output=$(timeout 3 sh "$readfile" --fixture-root "$ROOT") || failed sensor_read_timeout_or_error
    else
        output=$(timeout 3 sh "$readfile" --live-readonly) || failed sensor_read_timeout_or_error
    fi
    # The one-shot reader already rejects missing/malformed/zero sensor values;
    # strict re-admission here avoids treating its warnings as a good reading.
    first=$(printf '%s\n' "$output" | sed -n '1p')
    [ "$first" = 'THERMAL_READER=READ_ONLY_SNAPSHOT_NOT_GUARD' ] || failed invalid_reader_result
    reader_boot=$(printf '%s\n' "$output" | sed -n 's/^boot_id=//p')
    [ -n "$reader_boot" ] || failed missing_reader_boot
    if [ "$MODE" = --fixture-root ]; then
        [ "$reader_boot" = "$BOOT_EXPECTED" ] || failed reader_boot_mismatch
        check_fixture
    fi
    # Emit only informational text. No unqualified thermal threshold applied.
    printf 'THERMAL_SHADOW=OBSERVED_NOT_GUARD tick=%s boot_id=%s physical_action=NO\n' "$n" "$reader_boot"
    printf '%s\n' "$output" | sed -n '/^battery_deci_c=/p; /^lrp_deci_c=/p; /^board_ap_deci_c=/p'
    n=$((n + 1))
    if [ "$n" -le "$SAMPLES" ]; then
        if [ "$MODE" = --fixture-root ]; then sleep 0.1; else sleep 2; fi
    fi
done
printf 'THERMAL_SHADOW=COMPLETE_UNQUALIFIED samples=%s physical_action=NO\n' "$SAMPLES"
