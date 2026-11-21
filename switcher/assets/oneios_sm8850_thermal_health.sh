#!/system/bin/sh
# SM8850 P0: FIXTURE-ONLY thermal heartbeat / monitor PID-birth validator.
#
# This is a testable contract for the independent OneOS framework deadline
# supervisor. It does not execute a guest, open a watchdog, issue a return,
# restart a process or run on a live phone. It never accesses real /proc or
# /sys. No live mode exists until all P0 admission gates are qualified.
#
# Usage: --fixture-root /tmp/fixture BOOT GEN LAUNCH NOW_MS MAX_AGE_MS
set -u
usage() {
    echo 'usage: oneios_sm8850_thermal_health.sh --fixture-root DIR BOOT GEN LAUNCH NOW_MS MAX_AGE_MS' >&2
    exit 2
}
fail() {
    echo "THERMAL_HEALTH=FAIL_CLOSED_FIXTURE_ONLY reason=$1 physical_action=NO" >&2
    exit 4
}
[ "$#" -eq 7 ] && [ "$1" = --fixture-root ] || usage
ROOT=$2
BOOT_EXPECTED=$3
GEN_EXPECTED=$4
LAUNCH_EXPECTED=$5
NOW_MS=$6
MAX_AGE_MS=$7

case "$ROOT" in /tmp/*) ;; *) usage ;; esac
[ -d "$ROOT" ] && [ ! -L "$ROOT" ] || usage
ROOT=$(realpath "$ROOT" 2>/dev/null) || usage
case "$ROOT" in /tmp/?*) ;; *) usage ;; esac
case "$BOOT_EXPECTED" in ????????-????-????-????-????????????) ;; *) usage ;; esac
case "$GEN_EXPECTED" in ''|*[!a-zA-Z0-9._:-]*) usage ;; esac
case "$LAUNCH_EXPECTED" in ''|*[!a-f0-9]*) usage ;; esac
[ "${#LAUNCH_EXPECTED}" -eq 32 ] || usage

# All fixture quantities are conservative decimal integers, without an octal
# prefix, shell overflow or host-provided scripting. Limits are in milliseconds.
is_num() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 13 ] || return 1
    return 0
}
is_num "$NOW_MS" && is_num "$MAX_AGE_MS" || usage
[ "$MAX_AGE_MS" -gt 0 ] && [ "$MAX_AGE_MS" -le 30000 ] || usage

CTL="$ROOT/data/adb/oneios-m3q-framework/control"
HB="$CTL/thermal.heartbeat"
MON="$CTL/thermal.monitor"
BOOT="$ROOT/proc/sys/kernel/random/boot_id"
GEN="$CTL/watchdog.generation"
LAUNCH="$CTL/framework.launch"

# Canonical path containment, including symlinked parents. No general path
# scanning or access to the physical root filesystem is possible from here.
trusted_file() {
    [ -f "$1" ] && [ ! -L "$1" ] || return 1
    resolved=$(realpath "$1" 2>/dev/null) || return 1
    case "$resolved" in "$ROOT"/*) return 0 ;; *) return 1 ;; esac
}
for file in "$HB" "$MON" "$BOOT" "$GEN" "$LAUNCH"; do
    trusted_file "$file" || fail missing_or_untrusted_file
done

[ "$(cat "$BOOT" 2>/dev/null)" = "$BOOT_EXPECTED" ] || fail boot_mismatch
[ "$(cat "$GEN" 2>/dev/null)" = "$GEN_EXPECTED" ] || fail generation_mismatch
[ "$(cat "$LAUNCH" 2>/dev/null)" = "$LAUNCH_EXPECTED" ] || fail launch_mismatch
[ "$(awk 'END{print NR}' "$HB")" = 1 ] || fail heartbeat_multiline
[ "$(awk 'END{print NR}' "$MON")" = 1 ] || fail monitor_record_multiline

# Exact whitespace-delimited heartbeat schema:
# v1 boot-id generation launch-token pid birth sequence sample-ms status
read -r hv hb_boot hb_gen hb_launch hb_pid hb_birth hb_seq hb_ms hb_status hb_extra < "$HB" || fail heartbeat_unreadable
[ "$hv" = v1 ] && [ -z "$hb_extra" ] && [ "$hb_status" = OK ] || fail invalid_heartbeat_schema
[ "$hb_boot" = "$BOOT_EXPECTED" ] && [ "$hb_gen" = "$GEN_EXPECTED" ] &&
    [ "$hb_launch" = "$LAUNCH_EXPECTED" ] || fail heartbeat_identity_mismatch

read -r mon_pid mon_birth mon_extra < "$MON" || fail monitor_unreadable
[ -z "$mon_extra" ] && is_num "$mon_pid" && is_num "$mon_birth" &&
    is_num "$hb_pid" && is_num "$hb_birth" && is_num "$hb_seq" && is_num "$hb_ms" || fail invalid_monitor_identity
[ "$mon_pid" -gt 1 ] && [ "$mon_birth" -gt 0 ] &&
    [ "$mon_pid" = "$hb_pid" ] && [ "$mon_birth" = "$hb_birth" ] &&
    [ "$hb_seq" -gt 0 ] || fail stale_or_reused_monitor

PROCSTAT="$ROOT/proc/$mon_pid/stat"
trusted_file "$PROCSTAT" || fail monitor_dead
# Linux /proc/PID/stat: after the closing ')' in comm, field #22 is the
# 20th whitespace token (state is #3). A fixture may use a fake process.
live_birth=$(sed 's/^.*) //' "$PROCSTAT" | awk '$1 != "Z" && $1 != "X" && $20 ~ /^[0-9]+$/ {print $20; exit}')
[ -n "$live_birth" ] && [ "$live_birth" = "$mon_birth" ] || fail monitor_pid_reused_or_zombie

# Awk for non-overflowing decimal comparisons; age/future bounds are exact
# for 13-digit integers (< 2^53). Missing/stale samples are not healthy.
age=$(awk -v now="$NOW_MS" -v sample="$hb_ms" '
BEGIN {
    if (sample > now) exit 2
    age = now - sample
    if (age < 0 || age > 30000) exit 2
    printf "%.0f", age
}') || fail future_or_invalid_sample
[ "$age" -le "$MAX_AGE_MS" ] || fail stale_heartbeat

# Second read detects generation/boot changes inside this single check.
[ "$(cat "$BOOT" 2>/dev/null)" = "$BOOT_EXPECTED" ] &&
    [ "$(cat "$GEN" 2>/dev/null)" = "$GEN_EXPECTED" ] &&
    [ "$(cat "$LAUNCH" 2>/dev/null)" = "$LAUNCH_EXPECTED" ] || fail identity_changed_during_check
printf 'THERMAL_HEALTH=FRESH_FIXTURE_ONLY seq=%s age_ms=%s physical_action=NO\n' "$hb_seq" "$age"
