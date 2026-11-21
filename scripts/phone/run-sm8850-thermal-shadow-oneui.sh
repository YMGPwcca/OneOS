#!/usr/bin/env bash
# SM8850 P0: 3 bounded, root-readonly One UI thermal observations over ADB.
# NO iOS launch / Framework stop / reboot / watchdog open / kernel writes.
# Copies only the two audited reader+shadow scripts into an isolated shell
# owned /data/local/tmp directory; cleans up that exact directory afterward.
# Explicit --run-readonly is required. Without it, no device is contacted.
set -Eeuo pipefail
umask 077

MODE="${1:---audit-only}"
if [ "$#" -gt 1 ] || { [ "$MODE" != --audit-only ] && [ "$MODE" != --run-readonly ]; }; then
    echo "usage: bash run-sm8850-thermal-shadow-oneui.sh [--audit-only|--run-readonly]" >&2
    exit 2
fi

ROOT="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
ASSETS="$ROOT/switcher/assets"
FILES=(oneios_sm8850_thermal_reader.sh oneios_sm8850_thermal_shadow.sh)
for name in "${FILES[@]}"; do
    [ -f "$ASSETS/$name" ] && [ ! -L "$ASSETS/$name" ] || {
        echo "BLOCKED: required trusted source file missing or linked: $name" >&2
        exit 3
    }
    sh -n "$ASSETS/$name" || exit 3
done

if [ "$MODE" = --audit-only ]; then
    echo "THERMAL_SHADOW_AUDIT=NO_ADB_CONTACT"
    echo "Operations: exact ADB identity check, isolated /data/local/tmp staging,"
    echo "SHA-256 verification, three root read-only samples, cleanup."
    echo "Reader: BAT, LRP, BOARD_AP; never sysfs traversal or writes."
    echo "Guest/Framework control/watchdog/governors: NO ACTION"
    echo "To explicitly collect: --run-readonly"
    exit 0
fi

ADB="$HOME/Android/Sdk/platform-tools/adb"
[ -x "$ADB" ] || {
    echo "BLOCKED: missing ADB at $ADB" >&2
    exit 3
}

serials="$("$ADB" devices | awk 'NR>1 && $2=="device" {print $1}')"
if [[ ! "$serials" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    echo "BLOCKED: exactly one authorized ADB device required" >&2
    exit 3
fi
SERIAL="$serials"
prop() { "$ADB" -s "$SERIAL" shell getprop "$1" | tr -d '\r'; }
require_prop() {
    local got
    got="$(prop "$1")"
    [ "$got" = "$2" ] || {
        echo "BLOCKED: $1 mismatch" >&2
        exit 3
    }
}
require_prop ro.product.model SM-S948B
require_prop ro.product.device m3q
require_prop ro.build.version.incremental S948BXXS4BZIG
require_prop sys.boot_completed 1
[ "$("$ADB" -s "$SERIAL" shell getenforce | tr -d '\r')" = Enforcing ] || {
    echo "BLOCKED: SELinux not Enforcing" >&2
    exit 3
}
[ -n "$("$ADB" -s "$SERIAL" shell pidof system_server | tr -d '\r')" ] || {
    echo "BLOCKED: Android Framework is not fully present" >&2
    exit 3
}
BOOT="$("$ADB" -s "$SERIAL" shell cat /proc/sys/kernel/random/boot_id | tr -d '\r')"
printf '%s\n' "$BOOT" | grep -Eq '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' || {
    echo "BLOCKED: invalid boot ID" >&2
    exit 3
}

nonce="$(od -An -N8 -tx1 /dev/urandom | tr -d '[:space:]')"
REMOTE="/data/local/tmp/oneos-p0-shadow-$nonce"
STAGED=0
cleanup() {
    if [ "$STAGED" = 1 ]; then
        for name in "${FILES[@]}"; do
            "$ADB" -s "$SERIAL" shell rm -f "$REMOTE/$name" >/dev/null 2>&1 || true
        done
        "$ADB" -s "$SERIAL" shell rmdir "$REMOTE" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

OUT="$HOME/projects/OneiOS/out/sm8850/thermal-shadow-oneui"
mkdir -p "$OUT"
LOG="$(mktemp "$OUT/readonly-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX.log")"
chmod 600 "$LOG"

echo "===== STAGE 2 AUDITED READERS (NO TAKEOVER) ====="
"$ADB" -s "$SERIAL" shell mkdir "$REMOTE"
STAGED=1
"$ADB" -s "$SERIAL" shell chmod 700 "$REMOTE"
for name in "${FILES[@]}"; do
    "$ADB" -s "$SERIAL" push "$ASSETS/$name" "$REMOTE/$name" >/dev/null
    local_hash="$(sha256sum "$ASSETS/$name" | awk '{print $1}')"
    remote_hash="$("$ADB" -s "$SERIAL" shell sha256sum "$REMOTE/$name" | awk '{print $1}')"
    [ "$local_hash" = "$remote_hash" ] || {
        echo "BLOCKED: staged SHA256 mismatch for $name" >&2
        exit 4
    }
done

echo "===== THREE ROOT READ-ONLY SAMPLES (ONE UI STILL RUNNING) ====="
# One complete remote command keeps the KernelSU su -c argument intact.
# -T disables PTY/CRLF transformations that would corrupt strict receipts.
timeout 30 "$ADB" -s "$SERIAL" shell -T \
    "su -c '/system/bin/sh $REMOTE/oneios_sm8850_thermal_shadow.sh --live-oneui-readonly 3'" \
    2>&1 | tee "$LOG"

for tick in 1 2 3; do
    grep -Fxq "THERMAL_SHADOW=OBSERVED_NOT_GUARD tick=$tick boot_id=$BOOT physical_action=NO" "$LOG" || {
        echo "BLOCKED: invalid or missing sample $tick" >&2
        exit 4
    }
done
grep -Fxq 'THERMAL_SHADOW=COMPLETE_UNQUALIFIED samples=3 physical_action=NO' "$LOG" || {
    echo "BLOCKED: observer did not finish cleanly" >&2
    exit 4
}
[ "$(grep -c '^battery_deci_c=' "$LOG")" = 3 ] &&
[ "$(grep -c '^lrp_deci_c=' "$LOG")" = 3 ] &&
[ "$(grep -c '^board_ap_deci_c=' "$LOG")" = 3 ] || {
    echo "BLOCKED: missing named sensor observations" >&2
    exit 4
}

echo "===== POSTCHECK ONE UI AND BOOT ID ====="
require_prop sys.boot_completed 1
[ -n "$("$ADB" -s "$SERIAL" shell pidof system_server | tr -d '\r')" ] || exit 4
[ "$("$ADB" -s "$SERIAL" shell cat /proc/sys/kernel/random/boot_id | tr -d '\r')" = "$BOOT" ] || exit 4
echo "P0_SHADOW_ONEUI=PASS_READ_ONLY_EVIDENCE_NOT_GUARD"
echo "LOCAL_EVIDENCE=$LOG"
