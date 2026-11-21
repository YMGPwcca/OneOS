#!/usr/bin/env bash
# OneOS / OneiOS SM8850 P0: ONE physical 300s request-deadline probe,
# with loss-resistant host evidence. Not a P0 safety certification.
# Requires authorized USB ADB, working root and a physically attended device.
set -Eeuo pipefail
umask 077

ONEIOS="${ONEIOS_DIR:-$HOME/projects/OneiOS}"
ONEOS="${ONEOS_REPO:-$ONEIOS/app}"
ADB="${ONEOS_ADB:-$HOME/Android/Sdk/platform-tools/adb}"
BRANCH="feat/sm8850-p0-thermal-reader-sim"
PIN="99b48b2cb55e7d5a893cfa32778a1d4ab154f9e2"
STAGE="/data/adb/oneios-m3q-framework"

fail() { echo "P0_PHYSICAL=BLOCKED reason=$*" >&2; exit 4; }

adb_property() {
    local serial="$1" prop="$2"
    timeout 12s "$ADB" -s "$serial" shell getprop "$prop" | tr -d '\r\n'
}

root_uid() {
    local serial="$1"
    timeout 12s "$ADB" -s "$serial" shell -T "su -c 'id -u'" 2>/dev/null | tr -d '\r\n'
}

capture_root_records() {
    local serial="$1" dest="$2" rel out
    mkdir -p "$dest"
    for rel in \
        control/boot control/framework.launch control/framework.mode \
        control/framework.deadline control/watchdog.generation control/state \
        control/thermal.guard.heartbeat control/thermal.guard.fault \
        return.outcome return.log thermal-guard.log \
        session/return.request session/xnuhost.log control/display.log; do
        out="$dest/${rel//\//_}.txt"
        if ! timeout 15s "$ADB" -s "$serial" exec-out \
            "su -c 'if test -f $STAGE/$rel && test ! -L $STAGE/$rel; then tail -c 4194304 $STAGE/$rel; else echo EVIDENCE_FILE_ABSENT; fi'" \
            > "$out" 2> "$out.stderr"; then
            printf '%s\n' 'EVIDENCE_READ_FAILED_OR_ROOT_LOST' > "$out"
        fi
        if [[ ! -s "$out.stderr" ]]; then rm -f -- "$out.stderr"; fi
    done
}

physical_child() {
    local out="$1" source serial model device soc firmware boot uid clone_state
    [[ -x "$ADB" ]] || fail "ADB_NOT_FOUND=$ADB"
    [[ -f "$ONEIOS/scripts/phone/sm8850-takeover.py" ]] || fail 'ONEIOS_REARM_TOOL_MISSING'
    [[ -f "$ONEIOS/scripts/phone/framework-stage.sh" ]] || fail 'ONEIOS_REARM_SOURCE_MISSING'
    grep -Fq 'APFS_DATA_REARMED=YES' "$ONEIOS/scripts/phone/framework-stage.sh" || fail 'REARM_SAFETY_CONTRACT_MISSING'
    grep -Fq 'PREVIOUS_DATA_ARCHIVED=' "$ONEIOS/scripts/phone/framework-stage.sh" || fail 'REARM_ARCHIVE_CONTRACT_MISSING'
    git -C "$ONEOS" rev-parse --is-inside-work-tree >/dev/null || fail 'ONEOS_GIT_MISSING'
    echo "===== PIN EXACT ONEOS SOURCE ====="
    git -C "$ONEOS" fetch --no-tags origin "$BRANCH" </dev/null
    # The published evidence script itself adds one commit after PIN.
    # Pin the actual takeover implementation to PIN, and permit only later
    # ancestry whose safety-critical runtime files remain identical.
    git -C "$ONEOS" merge-base --is-ancestor "$PIN" FETCH_HEAD ||
        fail 'ONEOS_BRANCH_NO_LONGER_DESCENDS_FROM_REVIEWED_PIN'
    git -C "$ONEOS" diff --quiet "$PIN" FETCH_HEAD -- \
        switcher/assets/oneios_switch.sh \
        switcher/assets/oneios_sm8850_thermal_takeover_guard.sh \
        scripts/phone/sm8850-takeover-short-probe.py \
        scripts/phone/sm8850-reboot-witness.py \
        scripts/phone/sm8850-thermal-junction-inventory.py \
        scripts/phone/sm8850-thermal-manifest.py ||
        fail 'P0_RUNTIME_CHANGED_SINCE_REVIEWED_PIN'
    echo "ONEOS_REMOTE_HEAD=$(git -C "$ONEOS" rev-parse FETCH_HEAD)"
    source="$(mktemp -d /tmp/oneos-p0-live-source.XXXXXX)"
    P0_TMP_SOURCE="$source"
    git -C "$ONEOS" archive "$PIN" | tar -xf - -C "$source"
    [[ -f "$source/scripts/phone/sm8850-takeover-short-probe.py" ]] || fail 'PINNED_PROBE_MISSING'
    grep -Fq 'actions.add_argument("--run-300s"' "$source/scripts/phone/sm8850-takeover-short-probe.py" || fail 'PINNED_300S_MODE_MISSING'
    grep -Fq 'P0_FULL_600S_TAKEOVER=BLOCKED_UNQUALIFIED_THERMAL_GUARD' "$source/switcher/assets/oneios_switch.sh" || fail 'FULL_600S_SOURCE_LOCK_MISSING'
    echo "ONEOS_SOURCE_SHA=$PIN"
    echo "ONEIOS_SOURCE_SHA=$(git -C "$ONEIOS" rev-parse HEAD)"
    [[ "$(git -C "$ONEIOS" rev-parse --is-inside-work-tree)" == true ]] ||
        fail 'ONEIOS_CHECKOUT_NOT_GIT'
    printf '%s\n' "$PIN" > "$out/oneos-source-sha.txt"
    git -C "$ONEIOS" rev-parse HEAD > "$out/oneios-source-sha.txt"

    echo '===== EXACT PHONE IDENTITY ====='
    mapfile -t devices < <("$ADB" devices -l | awk '$2=="device" && /usb:/ {print $1}')
    [[ "${#devices[@]}" -eq 1 ]] || fail 'REQUIRE_EXACTLY_ONE_AUTHORIZED_USB_ADB_DEVICE'
    serial="${devices[0]}"
    printf '%s\n' "$serial" > "$out/serial.txt"
    model="$(adb_property "$serial" ro.product.model)"
    device="$(adb_property "$serial" ro.product.device)"
    soc="$(adb_property "$serial" ro.soc.model)"
    firmware="$(adb_property "$serial" ro.build.version.incremental)"
    boot="$(timeout 12s "$ADB" -s "$serial" shell -T 'cat /proc/sys/kernel/random/boot_id' | tr -d '\r\n')"
    uid="$(root_uid "$serial")" || fail 'ROOT_UNAVAILABLE'
    {
        printf 'serial=%s\nmodel=%s\ndevice=%s\nsoc=%s\nfirmware=%s\n' "$serial" "$model" "$device" "$soc" "$firmware"
        printf 'boot_id=%s\nroot_uid=%s\n' "$boot" "$uid"
        printf 'boot_completed=%s\n' "$(adb_property "$serial" sys.boot_completed)"
        printf 'selinux=%s\n' "$(timeout 12s "$ADB" -s "$serial" shell -T getenforce | tr -d '\r\n')"
    } > "$out/pre-oneui.txt"
    cat "$out/pre-oneui.txt"
    [[ "$model:$device:$soc:$firmware" == 'SM-S948B:m3q:SM8850:S948BXXS4BZIG' ]] || fail 'WRONG_DEVICE_OR_FIRMWARE'
    [[ "$uid" == 0 ]] || fail 'ROOT_NOT_ACTIVE_ON_CURRENT_BOOT'
    [[ "$(adb_property "$serial" sys.boot_completed)" == 1 ]] || fail 'ONEUI_NOT_FULLY_BOOTED'

    echo '===== PRESERVE PREVIOUS CONTROL RECORDS BEFORE SESSION ROTATION ====='
    capture_root_records "$serial" "$out/previous-root-records"

    clone_state="$(timeout 12s "$ADB" -s "$serial" shell -T \
       "su -c 'if test -e $STAGE/data.consumed || test -L $STAGE/data.consumed; then echo CONSUMED; elif test -e $STAGE/image.ready.rearm-pending || test -L $STAGE/image.ready.rearm-pending; then echo REARM_INCOMPLETE; else echo UNUSED; fi'" \
       | tr -d '\r\n')" || fail 'APFS_CLONE_STATUS_UNREADABLE'
    echo "APFS_CLONE_BEFORE=$clone_state"
    case "$clone_state" in
        CONSUMED)
            echo '===== REAL APFS REARM (ARCHIVE CONSUMED CLONE; NO FRAMEWORK STOP) ====='
            # These existing OneiOS tools have their own file ownership, hash,
            # one-shot clone, mount-namespace and storage fail-closed gates.
            python3 "$ONEIOS/scripts/phone/sm8850-takeover.py" \
                --reboot-stage-check --confirm --serial "$serial" \
                --output "$out/rearm-stage-check"
            python3 "$ONEIOS/scripts/phone/sm8850-takeover.py" \
                --rearm-data --confirm --serial "$serial"
            ;;
        UNUSED)
            echo 'APFS_REARM=NOT_NEEDED_ALREADY_UNUSED'
            ;;
        *) fail "APFS_CLONE=$clone_state" ;;
    esac
    clone_state="$(timeout 12s "$ADB" -s "$serial" shell -T \
       "su -c 'if test -e $STAGE/data.consumed || test -L $STAGE/data.consumed; then echo CONSUMED; elif test -e $STAGE/image.ready.rearm-pending || test -L $STAGE/image.ready.rearm-pending; then echo REARM_INCOMPLETE; else echo UNUSED; fi'" \
       | tr -d '\r\n')" || fail 'APFS_REARM_STATUS_UNREADABLE'
    [[ "$clone_state" == UNUSED ]] || fail "APFS_CLONE_POST_REARM=$clone_state"
    echo 'APFS_CLONE_READY=UNUSED_ONE_SHOT'

    # Mirror the root thermal abort message to the host BEFORE the reboot.
    # Unlike session/control and return.log, thermal-guard.log is append-only
    # on this source path. Do not write any log or thermal node on the device.
    if timeout 12s "$ADB" -s "$serial" shell -T \
       "su -c 'test -f $STAGE/thermal-guard.log && test ! -L $STAGE/thermal-guard.log'" \
       >/dev/null 2>&1; then
        "$ADB" -s "$serial" shell -T \
            "su -c 'echo PREBOOT_THERMAL_STREAM_READY; exec /system/bin/tail -n 0 -f $STAGE/thermal-guard.log'" \
            > "$out/thermal-guard-preboot-stream.log" 2>&1 &
        P0_THERMAL_STREAM_PID=$!
        echo "PREBOOT_THERMAL_HOST_STREAM=STARTED pid=$P0_THERMAL_STREAM_PID"
    else
        echo 'PREBOOT_THERMAL_HOST_STREAM=UNAVAILABLE; root-log postboot capture will be attempted'
    fi

    echo '===== ONE ACTUAL PHYSICAL P0 PROBE: 300S RETURN-REQUEST DEADLINE ====='
    echo 'WARNING=ANDROID_FRAMEWORK_WILL_STOP; THERMAL_GUARD_CAN_ABORT_EARLY'
    echo 'WARNING=UNASSISTED_WATCHDOG_RECOVERY_NOT_CERTIFIED'
    echo 'NO_SECOND_PROBE_OR_AUTOMATIC_RETRY'
    python3 "$source/scripts/phone/sm8850-takeover-short-probe.py" \
        --run-300s --adb "$ADB" --output "$out/probe"
}

capture_postboot() {
    local out="$1" serial uid
    [[ -f "$out/serial.txt" ]] || return 0
    serial="$(cat "$out/serial.txt")"
    echo '===== POST-ATTEMPT PHONE STATE (READ ONLY, IF REACHABLE) ====='
    if timeout 15s "$ADB" -s "$serial" shell -T '
      printf "boot_id="; cat /proc/sys/kernel/random/boot_id
      printf "boot_completed="; getprop sys.boot_completed
      printf "boot_reason="; getprop ro.boot.bootreason
      printf "zygote="; getprop init.svc.zygote
      printf "system_server="; pidof system_server || true
    ' > "$out/post-oneui.txt" 2> "$out/post-oneui.stderr"; then
        cat "$out/post-oneui.txt"
    else
        echo 'POST_ONEUI=UNAVAILABLE_OR_ADB_DISCONNECTED' | tee "$out/post-oneui.status"
    fi
    uid="$(root_uid "$serial")" || uid='UNAVAILABLE'
    if [[ "$uid" == 0 ]]; then
        echo 'POSTBOOT_ROOT=AVAILABLE; READ_ONLY_CONTROL_CAPTURE'
        capture_root_records "$serial" "$out/post-root-records"
    else
        echo 'POSTBOOT_ROOT=UNAVAILABLE; HOST_PREBOOT_LOGS_RETAINED'
        printf '%s\n' 'ROOT_UNAVAILABLE_NO_PROVENANCE_INFERRED' > "$out/post-root.status"
    fi
}

finalize_evidence() {
    local out="$1" rc="$2" dir archive
    printf '%s\n' "$rc" > "$out/host-probe-exit-code.txt"
    python3 - "$out" "$rc" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1]); rc = int(sys.argv[2])
console = (root/'console.log').read_text(errors='replace') if (root/'console.log').exists() else ''
reports = sorted((root/'probe').glob('short-probe-*.json')) if (root/'probe').is_dir() else []
report = None
if reports:
    try: report = json.loads(reports[-1].read_text())
    except (ValueError, OSError): pass
lines = [
'# SM8850 P0 physical experiment evidence',
'',
'- Scope: OneOS SM-S948B/m3q/SM8850, firmware S948BXXS4BZIG.',
'- Requested mode: one `--run-300s` real Framework takeover, after any necessary APFS rearm.',
'- Deadline meaning: REQUEST reboot at verified Framework stop + 300 seconds; NOT guest-runtime guarantee.',
'- OneOS source: `99b48b2cb55e7d5a893cfa32778a1d4ab154f9e2`.',
'- OneiOS local source: `' + (root/'oneios-source-sha.txt').read_text().strip() + '`.' if (root/'oneios-source-sha.txt').exists() else '- OneiOS local source: UNAVAILABLE.',
'- Host process exit code: `' + str(rc) + '` (does NOT itself certify P0).',
'- Physical dispatch observed in console: `' + ('YES' if 'SHORT_PROBE_REQUESTING_REAL_IOS_GUEST' in console else 'NO') + '`.',
'- Host-visible new OneUI boot marker: `' + ('YES' if 'ONEUI_NEW_BOOT=OBSERVED_AFTER_PROBE_REQUEST' in console else 'NO_OR_UNVERIFIED') + '`.',
'- Operator physical-key intervention: `UNKNOWN`, must be recorded by operator separately.',
'- `P0_ACCEPTANCE=OPEN_NOT_CERTIFIED`.',
'- `UNASSISTED_RECOVERY=NOT_PROVEN`.',
'- `WATCHDOG_INDEPENDENCE=NOT_QUALIFIED`.',
'- `FULL_600S_TAKEOVER=BLOCKED`.',
'',
'## Session evidence',
'',
'- Complete host console: `console.log`.',
'- Pre/post Android properties: `pre-oneui.txt`, `post-oneui.txt` when reachable.',
'- Archived previous root receipts and postboot root receipts: `previous-root-records/`, `post-root-records/` when accessible.',
'- Pre-reboot live switch stream and witness: `probe/` (when launched).',
'- `SHA256SUMS` authenticates bytes within this bundle, not the device return requester.',
]
if report:
    for key in ['thermal_guard_armed_marker_observed', 'framework_stop_confirmed_in_log', 'xnuhost_launch_marker_observed', 'guest_launch_evidence_complete', 'reboot_request_deadline_after_framework_stop_seconds', 'postboot_root_log_accessible', 'recovery_certified', 'unassisted_return_proven']:
        lines.append(f'- `{key}`: `{report.get(key, "NOT_RECORDED")}`.')
    if 'preboot_host_log_path' in report:
        lines.append('- Local host stream path recorded by probe: `' + str(report['preboot_host_log_path']) + '`.')
else:
    lines.append('- Probe JSON: NOT_AVAILABLE; cannot infer guest execution or recovery from a missing report.')
fault = root/'post-root-records'/'control_thermal.guard.fault.txt'
if fault.exists():
    body = fault.read_text(errors='replace').strip()
    if body and body != 'EVIDENCE_FILE_ABSENT' and body != 'EVIDENCE_READ_FAILED_OR_ROOT_LOST':
        lines.append('- Recorded thermal guard fault (raw): `' + body[:1500].replace('`', "'") + '`.')
lines += ['', '## Review before publishing', '', 'Do not publish the private raw archive to GitHub. The bundle may contain boot IDs, session tokens, device details and log data. Publish a reviewed and redacted summary after inspecting it.']
(root/'P0_EVIDENCE_REPORT.md').write_text('\n'.join(lines)+'\n')
PY
    (cd "$out" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 -r sha256sum > SHA256SUMS)
    dir="$(dirname -- "$out")"
    archive="$out.tar.gz"
    tar -C "$dir" -czf "$archive" "$(basename -- "$out")"
    sha256sum "$archive" > "$archive.sha256"
    chmod 600 "$archive" "$archive.sha256"
    echo "===== PRESERVED P0 EVIDENCE ====="
    echo "P0_EVIDENCE_DIR=$out"
    echo "P0_EVIDENCE_REPORT=$out/P0_EVIDENCE_REPORT.md"
    echo "P0_EVIDENCE_ARCHIVE=$archive"
    echo "P0_EVIDENCE_SHA256=$(cut -d' ' -f1 "$archive.sha256")"
    echo 'P0_ACCEPTANCE=OPEN_NOT_CERTIFIED'
    echo 'PHONE_RETRY=NO'
}

[[ $# -eq 0 ]] || { echo 'Usage: bash oneos-p0-live-300s-evidence.sh' >&2; exit 2; }
mkdir -p "$ONEIOS/out/sm8850/p0-physical"
OUT="$(mktemp -d "$ONEIOS/out/sm8850/p0-physical/live-300s-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
chmod 700 "$OUT"
printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$OUT/requested-at-utc.txt"
set +e
(
    # Run in an isolated strict-mode subshell, not via bash "$0":
    # stdin-based invocation makes $0=/usr/bin/bash (an ELF binary).
    set -Eeuo pipefail
    P0_TMP_SOURCE=''
    P0_THERMAL_STREAM_PID=''
    cleanup_child() {
        if [[ -n "$P0_THERMAL_STREAM_PID" ]]; then
            kill "$P0_THERMAL_STREAM_PID" 2>/dev/null || true
            wait "$P0_THERMAL_STREAM_PID" 2>/dev/null || true
        fi
        if [[ -n "$P0_TMP_SOURCE" ]]; then
            rm -rf -- "$P0_TMP_SOURCE"
        fi
    }
    trap cleanup_child EXIT
    physical_child "$OUT"
) 2>&1 | tee "$OUT/console.log"
RC=${PIPESTATUS[0]}
set -e
capture_postboot "$OUT" || true
finalize_evidence "$OUT" "$RC"
echo "HOST_PROBE_EXIT=$RC"
exit "$RC"
