#!/system/bin/sh
# The OneiOS session: One UI's framework stops and xnuhost (XNU as a process,
# from the OneiOS runtime package) starts with the staged iOS image set.
# docs/oneios.md; the contract with xnuhost is OneiOS's oneos/interface.md
# (session ABI 1). Modelled on oneos_switch.sh: every refusal comes before the
# first change, One UI's zygote is stopped and kept stopped, and the way back
# (oneios_return.sh: in place, else a reboot) is armed before the stop.
#
#   oneios_switch.sh            the session (preflight, stop, start xnuhost)
#   oneios_switch.sh --check    the preflight only; changes nothing
#   oneios_switch.sh --inner    (internal) inside the session's mount namespace
#   oneios_switch.sh --watch    (internal) the watcher that returns to One UI
#   oneios_switch.sh --keys D TOK ROLE   (internal) events from one physical volume key
#   oneios_switch.sh --keys-poll TOK UP DOWN (internal) the same chord from the keys' state (works under a grab)
#   oneios_switch.sh --feed     (internal) Samsung's software watchdog feeder
#   oneios_switch.sh --stop-loop (internal) keeps One UI's zygote stopped
#   oneios_switch.sh --bootui   (internal) the boot screen's stage line, from xnuhost's log
#   oneios_switch.sh --usb-watch (internal) keeps adb on the USB gadget through the session
#
# What a session never touches: One UI's /data beyond $STAGE (xnuhost's mount
# namespace has the stage bound over /data), vold, keystore2, gatekeeper,
# weaver, the lock-screen files, SELinux's mode, persist.* properties.
# What it changes, all undone by oneios_return.sh or a reboot: One UI's zygote
# (and zygote_secondary) stopped, the kernel wakelock oneios_session, Samsung's
# software watchdog fed while One UI is down, the cgroup oneios_session (xnuhost's own),
# OneOS's boot screen on a surfaceflinger layer until the guest's first frame,
# and, with USB debugging on, the USB watcher's repairs (sys.usb.config, adbd
# and the gadget's UDC, each only back to One UI's own value).
#
# The ways back to One UI, none of which needs anything from the guest
# (docs/oneios.md, "Getting back to One UI"):
#   1  Volume Up + Volume Down held 3 s: one reader per key device (--keys) and
#      a poll of the keys' state (--keys-poll) that a grab cannot starve.
#   2  the watcher (--watch): on a request, when xnuhost ends, when the guest
#      never reports ready. If it does not act on the keys, the key readers
#      start the return themselves.
#   3  oneios_return.sh: in place, a reboot on any doubt, and a reboot by its
#      own guard if it does not finish.
#   4  Power + Volume Down held: the phone's own forced restart, below all of this.

# Tests (OneiosScriptTest) set ONEIOS_TEST_ROOT to a folder that stands for /:
# then only the stage checks run, never as root, and no session is started.
# The watcher and the key readers (--watch, --keys, --keys-poll) can be run
# there by themselves: against that folder's proc, sys and stage, with its
# bin/ first on PATH (stand-ins for getevent, getprop, setprop, ...), and with
# its bin/kill and bin/sleep in place of the shell's, so a test never signals
# a real process.
T="${ONEIOS_TEST_ROOT:-}"
if [ -n "$T" ]; then
    [ "$(id -u)" != 0 ] || { echo "PREFLIGHT REFUSED: ONEIOS_TEST_ROOT is for tests, never as root"; exit 3; }
    PATH="$T/bin:$PATH"; export PATH
    kill() { "$T/bin/kill" "$@"; }
    sleep() { "$T/bin/sleep" "$@"; }
fi
SH=/system/bin/sh
[ -z "$T" ] || SH="${ONEIOS_TEST_SH:-/bin/sh}"
P="$T/proc"
STAGE="$T/data/local/tmp/oneios"
FRAMEWORK_STAGE=/data/adb/oneios-m3q-framework
FRAMEWORK=0
case "$0:$1" in
    "$FRAMEWORK_STAGE/oneios_switch.sh":*|*":--framework-audit"|*":--framework-audit-reboot")
        FRAMEWORK=1
        STAGE="$FRAMEWORK_STAGE" ;;
esac
if [ -n "$T" ] && [ "${ONEIOS_TEST_FRAMEWORK:-}" = 1 ]; then FRAMEWORK=1; fi
ANDROID_STAGE="$T/data/local/tmp/oneos"
# session/ is what xnuhost and the switch share (its log, its pid, ready,
# return.request, display.sock). control/ is the way back's own: the state,
# the baseline, the pids, the keys. xnuhost's namespace has it read-only, so
# nothing the guest does to its /data can change what the watcher, the key
# readers and the return read.
SESSION="$STAGE/session"
CTL="$STAGE/control"
SELF="$STAGE/oneios_switch.sh"
SELF_RETURN="$STAGE/oneios_return.sh"
ABI=1
APP="${ONEIOS_APP:-0}"
[ "$APP" = 1 ] || APP=0
MODE="${1:-session}"
# The original OneOS V watchdog strategy remains a reboot-only RETURN
# path: a full iOS guest may run for at most 600 seconds, but the return
# after it ends is a mandatory reboot, NEVER an in-place watchdog handback.
# A full-run needs a separate risk token and a recorded prior takeover smoke.
FRAMEWORK_REBOOT=0
case "$MODE:$2" in
    --framework-audit-reboot:*|--framework-check:reboot-smoke|--framework-session:reboot-smoke|--framework-check:run|--framework-session:run)
        FRAMEWORK_REBOOT=1 ;;
    --feed:*|--watch:*|--keys:*|--keys-poll:*|--framework-deadline:*|--stop-loop:*|--watchdog-health:*|--watchdog-supervise:*)
        # These are independent children of the already armed session.
        # The marker is written before they start; all must use the same
        # first-keepalive grace window (especially the early watcher).
        [ "$FRAMEWORK" != 1 ] ||
            [ "$(cat "$CTL/framework.return" 2>/dev/null)" != reboot ] || FRAMEWORK_REBOOT=1 ;;
esac
OWNER=0
[ -z "$T" ] || OWNER=$(id -u)

refuse() {
    echo "PREFLIGHT REFUSED: $*"
    echo "Nothing on the phone was changed; One UI keeps running."
    exit 2
}
# Owned by root and writable by root only (stat %A: group w is the 6th
# character, other w the 9th), and not a link.
root_only() {
    [ ! -L "$1" ] || return 1
    case "$(stat -c '%u %A' "$1" 2>/dev/null)" in
        "$OWNER "?????w*|"$OWNER "????????w*) return 1 ;;
        "$OWNER "*) return 0 ;;
    esac
    return 1
}
conf() { # <file> <key>: the value of key=value, first match
    sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}
boot_id() { cat "$T/proc/sys/kernel/random/boot_id" 2>/dev/null; }
# "dev:inode:size:mtime" of a file: what root recorded when it staged it.
file_id() { stat -c '%d:%i:%s:%Y' "$1" 2>/dev/null; }

# Only the S24 Ultra's identified Linux softdog is supported. The legacy
# misc device (10:130) and the numbered watchdog0 can represent one device.
# Resolve the holder's device number against sysfs without opening any node.
watchdog_profile() {
    if [ "$FRAMEWORK" = 1 ]; then
        framework_identity
        return
    fi
    case "$(getprop ro.product.model)" in SM-S928*) ;; *) return 1 ;; esac
    [ "$(getprop ro.product.device)" = e3q ] && [ "$(getprop ro.soc.model)" = SM8650 ]
}
watchdog_id() {
    if [ -n "$T" ]; then "$T/bin/watchdog-stat" "$1"
    elif [ -c "$1" ]; then stat -Lc '%t:%T' "$1" 2>/dev/null; else return 1; fi
}
watchdog_softdog() { # <numbered node name>; print its device number
    wd_class="$T/sys/class/watchdog/$1"
    [ "$(cat "$wd_class/identity" 2>/dev/null)" = "Software Watchdog" ] || return 1
    [ "$(cat "$wd_class/state" 2>/dev/null)" = active ] || return 1
    # The supported S24 path has at least 100 s for the return handoff.
    wd_timeout=$(cat "$wd_class/timeout" 2>/dev/null)
    case "$wd_timeout" in ''|*[!0-9]*) return 1 ;; esac
    [ "$wd_timeout" -ge 100 ] 2>/dev/null || return 1
    if [ "$FRAMEWORK" = 1 ]; then
        case "$(cat "$wd_class/nowayout" 2>/dev/null)" in 0|N|1|Y) ;; *) return 1 ;; esac
        [ "$(cat "$wd_class/pretimeout" 2>/dev/null)" = 0 ] || return 1
    fi
    wd_dev=$(cat "$wd_class/dev" 2>/dev/null)
    case "$wd_dev" in ''|:*|*:|*:*:*|*[!0-9:]*) return 1 ;; *:*) ;; *) return 1 ;; esac
    wd_expected=$(printf '%x:%x' "${wd_dev%:*}" "${wd_dev#*:}") || return 1
    [ "$(watchdog_id "$T/dev/$1")" = "$wd_expected" ] || return 1
    printf '%s\n' "$wd_expected"
}

# A separate, root-owned review record binds the handset's kernel, endpoint,
# return budget and exact native artifact. The host CLI never creates one.
framework_watchdog_plan() {
    q="$STAGE/watchdog.qualification"
    [ -f "$q" ] && root_only "$q" || return 1
    read -r q_kernel q_module q_binary q_node q_id q_mode q_timeout q_return q_extra < "$q" || return 1
    [ -z "$q_extra" ] && [ "$q_node $q_id" = "$1" ] || return 1
    [ "$(sha256sum "$T/sys/kernel/notes" 2>/dev/null | cut -d' ' -f1)" = "$q_kernel" ] &&
        [ "$(sha256sum "$T/sys/module/softdog/notes/.note.gnu.build-id" 2>/dev/null | cut -d' ' -f1)" = "$q_module" ] &&
        [ "${#q_kernel}" = 64 ] && [ "${#q_module}" = 64 ] && [ "${#q_binary}" = 64 ] || return 1
    wd_sys="$T/sys/class/watchdog/$q_node"
    case "$(cat "$wd_sys/nowayout" 2>/dev/null):$q_mode" in 0:0|N:0|1:1|Y:1) ;; *) return 1 ;; esac
    q_left=$(cat "$wd_sys/timeleft" 2>/dev/null)
    watchdog_uint "$q_timeout" && watchdog_uint "$q_return" && watchdog_uint "$q_left" &&
        [ "$q_timeout" -ge 100 ] && [ "$q_timeout" -le 65535 ] &&
        [ "$q_return" -ge 5 ] && [ "$q_return" -le 30 ] &&
        [ "$q_left" -ge 45 ] && [ "$q_left" -le "$q_timeout" ] &&
        [ "$(cat "$wd_sys/timeout" 2>/dev/null)" = "$q_timeout" ] || return 1
    printf '%s %s %s %s\n' "$q_mode" "$q_timeout" "$q_return" "$q_binary"
}
# OneOS Android-guest-compatible legacy watchdog observation. A matching
# system_server FD is evidence of ownership, NOT driver/timeout qualification.
# Never open the watchdog while Android Framework is alive.
framework_legacy_target() {
    [ "$FRAMEWORK" = 1 ] && framework_identity || return 1
    [ "$(cat "$T/sys/class/misc/watchdog/dev" 2>/dev/null)" = 10:130 ] || return 1
    [ "$(watchdog_id "$T/dev/watchdog")" = a:82 ] || return 1
    legacy_pid=$(pidof system_server 2>/dev/null)
    case "$legacy_pid" in ''|*[!0-9]*) return 1 ;; esac
    legacy_birth=$(watchdog_birth "$legacy_pid")
    [ -n "$legacy_birth" ] || return 1
    legacy_count=0
    for legacy_fd in "$P/$legacy_pid/fd/"*; do
        legacy_link=$(readlink "$legacy_fd" 2>/dev/null) || continue
        case "$legacy_link" in
            "$T/dev/watchdog")
                [ "$(watchdog_id "$legacy_fd")" = a:82 ] || return 1
                legacy_count=$((legacy_count + 1)) ;;
            "$T/dev/watchdog"[0-9]*|"$T/dev/softdog"*) return 1 ;;
        esac
    done
    [ "$legacy_count" = 1 ] && [ "$(pidof system_server 2>/dev/null)" = "$legacy_pid" ] &&
        [ "$(watchdog_birth "$legacy_pid")" = "$legacy_birth" ] || return 1
    printf 'legacy a:82\n'
}
watchdog_target() {
    if [ "$FRAMEWORK_REBOOT" = 1 ]; then
        framework_legacy_target
        return $?
    fi
    watchdog_profile || return 1
    wd_holder=$(pidof system_server 2>/dev/null)
    case "$wd_holder" in ''|*[!0-9]*) return 1 ;; esac
    wd_links=$(ls -l "$P/$wd_holder/fd" 2>/dev/null) || return 1
    wd_fds=$(printf '%s\n' "$wd_links" | awk -v prefix="$T/dev/" '
        NF >= 3 && $(NF-1) == "->" && index($NF, prefix) == 1 && $(NF-2) ~ /^[0-9]+$/ {
            node = substr($NF, length(prefix) + 1)
            if (node ~ /^(watchdog|softdog)[0-9]*$/) print $(NF-2)
        }')
    wd_held=""
    for wd_fd in $wd_fds; do
        wd_id=$(watchdog_id "$P/$wd_holder/fd/$wd_fd") || return 1
        wd_held="$wd_held $wd_id "
    done
    wd_target=""
    for wd_class in "$T"/sys/class/watchdog/watchdog*; do
        wd_name=${wd_class##*/}
        case "${wd_name#watchdog}" in ''|*[!0-9]*) continue ;; esac
        wd_id=$(watchdog_softdog "$wd_name") || continue
        if [ "$FRAMEWORK" = 0 ] && [ "$wd_name" = watchdog0 ] && [ "$(cat "$T/sys/class/misc/watchdog/dev" 2>/dev/null)" = 10:130 ]; then
            wd_alias=a:82
        else
            wd_alias=$wd_id
        fi
        case "$wd_held" in *" $wd_id "*|*" $wd_alias "*) ;; *) continue ;; esac
        [ -z "$wd_target" ] || return 1
        wd_target="$wd_name $wd_id"
    done
    [ -n "$wd_target" ] || return 1
    # An additional watchdog held by system_server would lose its owner too.
    for wd_id in $wd_held; do
        [ "$wd_id" = "${wd_target#* }" ] || {
            [ "$FRAMEWORK" = 0 ] && [ "${wd_target%% *}" = watchdog0 ] && [ "$wd_id" = a:82 ] &&
                [ "$(cat "$T/sys/class/misc/watchdog/dev" 2>/dev/null)" = 10:130 ]
        } || return 1
    done
    printf '%s\n' "$wd_target"
}
# Software supervision for the existing S24 path. These are not hardware
# expiry bounds. Whole seconds of Linux boot uptime, independent of wall time.
# The OneOS Android feeder logs transient EBUSY instead of aborting on
# the first V write. Bound that grace period for the reboot-only S26 smoke:
# no readiness or keepalive heartbeat is published until V actually succeeds.
WD_FIRST=3
[ "$FRAMEWORK_REBOOT" != 1 ] || WD_FIRST=10
WD_MAX_AGE=5
watchdog_uint() {
    case "$1" in ''|0[0-9]*|*[!0-9]*|??????????*) return 1 ;; esac
}
watchdog_now() {
    read -r wd_uptime _ < "$P/uptime" || return 1
    case "$wd_uptime" in *.[0-9][0-9]) ;; *) return 1 ;; esac
    wd_seconds=${wd_uptime%.*}
    watchdog_uint "$wd_seconds" || return 1
    printf '%s\n' "$wd_seconds"
}
watchdog_birth() {
    sed 's/^.*) //' "$P/$1/stat" 2>/dev/null | awk '$1 != "Z" && $1 != "X" && $20 ~ /^[0-9]+$/ { print $20; exit }'
}
watchdog_generation() {
    cat "$CTL/watchdog.generation" 2>/dev/null
}
publish_return_request() {
    # Link a complete record into the shared directory without replacing an
    # existing request or following a link supplied by the guest.
    [ ! -e "$SESSION/return.request" ] || return 0
    req=$(mktemp "$CTL/return.request.XXXXXX") || return 1
    printf '%s\n' "$1" > "$req" && ln -T "$req" "$SESSION/return.request" 2>/dev/null
    rm -f "$req"
}
watchdog_failed() {
    # A late feeder from an old session, or a normal close, cannot request
    # recovery. Keep the first diagnosis and never replace another request.
    [ ! -e "$CTL/feeder.off" ] && [ "$(watchdog_generation)" = "$WD_GEN" ] || return 4
    if (set -C; printf '%s\n' "$*" > "$CTL/feeder.failed") 2>/dev/null; then
        echo "$(date +%T) watchdog feeder failed: $*" >> "$CTL/watchdog_feeder.log"
        rm -f "$CTL/feeder.ready"
        publish_return_request "watchdog feeder failed: $*"
    fi
    return 4
}
watchdog_pings() {
    # Confirm the opened descriptor before sending any byte. One open for
    # the whole session, with plain keepalives and a normal close.
    if [ "$FRAMEWORK_REBOOT" = 1 ]; then
        [ "$wd_name $wd_saved" = "legacy a:82" ] &&
            [ "$(watchdog_id "$T/dev/watchdog")" = a:82 ] || return 1
        wd_keepalive=V
    else
        [ -n "$T" ] || [ "$(watchdog_id "$P/$$/fd/3")" = "$wd_saved" ] || return 1
        wd_keepalive=.
    fi
    wd_first=1
    wd_last=$wd_armed
    while [ ! -e "$CTL/feeder.off" ] && [ "$(watchdog_generation)" = "$WD_GEN" ]; do
        if [ "$FRAMEWORK_REBOOT" = 1 ]; then
            # Ported from OneOS guest_prepare.sh: attempt V open/write/close
            # repeatedly. Its feeder logs EBUSY as "refused", NOT a fatal
            # first-attempt error. Unlike OneOS's long-running Android guest,
            # our reboot-only smoke must still prove one successful V before
            # reporting ownership/readiness. EBUSY is retried only within
            # WD_FIRST; no false heartbeat is ever published.
            if [ -n "$T" ]; then
                wd_error=$("$T/bin/watchdog-io" ping V 2>&1) && wd_written=1 || wd_written=0
            else
                wd_error=$(printf V 2>&1 > "$T/dev/watchdog") && wd_written=1 || wd_written=0
            fi
            if [ "$wd_written" = 0 ]; then
                [ "$wd_first" = 1 ] || return 1
                wd_retry=$(watchdog_now) || return 1
                if [ "$((wd_retry - wd_armed))" -ge "$WD_FIRST" ]; then
                    watchdog_failed "OneOS legacy V write never succeeded within bounded handoff"
                    return 1
                fi
                printf '%s OneOS legacy /dev/watchdog V refused (%s), waiting for FD release\n' \
                    "$(date +%T)" "$wd_error" >> "$L"
                sleep 0.2 3>&-
                continue
            fi
        elif [ -n "$T" ]; then "$T/bin/watchdog-io" ping "$wd_keepalive" || return 1
        else printf '%s' "$wd_keepalive" >&3 || return 1; fi
        # Only a completed keepalive earns a new timestamp. Never publish
        # into a new session or turn a late first ping into readiness.
        [ "$(watchdog_generation)" = "$WD_GEN" ] || return 0
        wd_tick=$(watchdog_now) || return 1
        [ "$wd_tick" -ge "$wd_last" ] || return 1
        if [ "$wd_first" = 1 ]; then
            if [ "$((wd_tick - wd_armed))" -ge "$WD_FIRST" ]; then
                watchdog_failed "first keepalive missed its deadline"
                return 1
            fi
        elif [ "$((wd_tick - wd_last))" -ge "$WD_MAX_AGE" ]; then
            watchdog_failed "feeder keepalive progress stalled before write completed"
            return 1
        fi
        printf '%s %s %s %s\n' "$WD_GEN" "$$" "$wd_birth" "$wd_tick" > "$CTL/feeder.heartbeat.$WD_GEN" &&
            mv -f "$CTL/feeder.heartbeat.$WD_GEN" "$CTL/feeder.heartbeat" || return 1
        if [ "$wd_first" = 1 ]; then
            echo $$ > "$CTL/feeder.ready" || return 1
            echo "Watchdog feeder ready ($wd_name, pid $$)" >> "$L"
            wd_first=0
        fi
        wd_last=$wd_tick
        sleep 2 3>&-
    done
}
watchdog_feed() {
    watchdog_profile || return 3
    [ -e "$CTL/stopped" ] && [ ! -e "$CTL/feeder.off" ] || return 3
    wd_boot=$(boot_id)
    [ -n "$wd_boot" ] && [ "$(cat "$CTL/boot" 2>/dev/null)" = "$wd_boot" ] || return 3
    case "$(cat "$CTL/state" 2>/dev/null)" in starting|running|returning) ;; *) return 3 ;; esac
    WD_GEN=$(watchdog_generation)
    [ -n "$WD_GEN" ] && read -r wd_gen wd_armed wd_extra < "$CTL/feeder.arm" &&
        [ "$wd_gen" = "$WD_GEN" ] && [ -z "$wd_extra" ] && watchdog_uint "$wd_armed" || return 3
    wd_birth=$(watchdog_birth $$)
    [ -n "$wd_birth" ] || return 3
    mkdir "$CTL/feeder.lock" 2>/dev/null || return 3
    L="$CTL/watchdog_feeder.log"
    echo $$ > "$CTL/feeder.pid" || { watchdog_failed "could not record the feeder PID"; return; }
    read -r wd_name wd_saved wd_extra < "$CTL/watchdog.target" || { watchdog_failed "missing watchdog target"; return; }
    if [ "$FRAMEWORK_REBOOT" = 1 ]; then
        [ "$wd_name" = legacy ] ||
            { watchdog_failed "invalid legacy reboot watchdog target"; return; }
    else
        case "${wd_name#watchdog}" in
            ''|*[!0-9]*) watchdog_failed "invalid watchdog target"; return ;;
        esac
        case "$wd_name" in watchdog*) ;; *) watchdog_failed "invalid watchdog target"; return ;; esac
    fi
    [ -z "$wd_extra" ] && [ -n "$wd_saved" ] || { watchdog_failed "invalid watchdog identity"; return; }
    if pidof system_server >/dev/null 2>&1 || [ "$(getprop init.svc.zygote)" = running ]; then
        watchdog_failed "One UI still owns the watchdog"
        return
    fi
    if [ "$FRAMEWORK_REBOOT" = 1 ]; then
        [ "$wd_name $wd_saved" = "legacy a:82" ] &&
            [ "$(cat "$CTL/framework.return" 2>/dev/null)" = reboot ] &&
            [ "$(watchdog_id "$T/dev/watchdog")" = a:82 ] ||
            { watchdog_failed "legacy reboot watchdog identity changed"; return; }
        watchdog_pings 2>>"$L" && return 0
        watchdog_failed "OneOS legacy watchdog feeder stopped making progress"
        return
    fi
    if [ "$FRAMEWORK" = 1 ]; then
        wd_native="$STAGE/oneios-watchdog"
        wd_current_mode=$(cat "$T/sys/class/watchdog/$wd_name/nowayout" 2>/dev/null)
        case "$wd_current_mode" in N) wd_current_mode=0 ;; Y) wd_current_mode=1 ;; esac
        if read -r wd_mode wd_timeout wd_return wd_hash < "$CTL/watchdog.plan" &&
           [ "$wd_current_mode" = "$wd_mode" ] &&
           [ -x "$wd_native" ] && root_only "$wd_native" &&
           [ "$(sha256sum "$wd_native" | cut -d' ' -f1)" = "$wd_hash" ]; then
            exec "$wd_native" "$CTL" "/dev/$wd_name" "$wd_saved" "$WD_GEN" "$wd_birth" "$wd_armed" \
                "$wd_mode" "$wd_timeout" "$wd_return" >>"$L" 2>&1
        fi
        watchdog_failed "native supervisor or qualified plan unavailable"
        return
    fi
    [ "$(watchdog_softdog "$wd_name")" = "$wd_saved" ] ||
        { watchdog_failed "watchdog identity or timing changed"; return; }
    if [ -n "$T" ]; then
        "$T/bin/watchdog-io" open "$wd_name" 2>>"$L" && watchdog_pings 2>>"$L"
    else
        watchdog_pings 2>>"$L" 3>"$T/dev/$wd_name"
    fi && return 0
    watchdog_failed "cannot open or keep alive $wd_name"
}
# 0: a current successful ping (print the identity); 1: not armed, closing
# or still within the first-ping window; 2: lost progress (print the reason).
watchdog_health() {
    [ ! -e "$CTL/feeder.off" ] && [ "$(watchdog_generation)" = "$WD_GEN" ] || return 1
    if [ -e "$CTL/feeder.failed" ]; then
        echo "feeder already failed"
        return 2
    fi
    if [ ! -e "$CTL/feeder.arm" ]; then
        if [ -e "$CTL/feeder.ready" ] || [ -e "$CTL/feeder.heartbeat" ] ||
           { [ -e "$CTL/watchdog.target" ] && [ "$(cat "$CTL/state" 2>/dev/null)" = running ]; }; then
            echo "feeder has no current arm record"
            return 2
        fi
        return 1
    fi
    if ! read -r wd_gen wd_arm wd_extra < "$CTL/feeder.arm" ||
       [ -z "$WD_GEN" ] || [ "$wd_gen" != "$WD_GEN" ] || [ -n "$wd_extra" ] ||
       ! watchdog_uint "$wd_arm" || ! wd_now=$(watchdog_now) || [ "$wd_arm" -gt "$wd_now" ]; then
        echo "invalid feeder arm record or monotonic clock"
        return 2
    fi
    if [ ! -e "$CTL/feeder.ready" ]; then
        [ "$((wd_now - wd_arm))" -lt "$WD_FIRST" ] && return 1
        echo "first keepalive did not become ready"
        return 2
    fi
    if ! read -r wd_gen wd_live wd_start wd_tick wd_extra < "$CTL/feeder.heartbeat" ||
       [ "$wd_gen" != "$WD_GEN" ] || [ -n "$wd_extra" ] ||
       ! watchdog_uint "$wd_live" || [ "$wd_live" -le 1 ] ||
       ! watchdog_uint "$wd_tick" || [ "$wd_tick" -lt "$wd_arm" ]; then
        echo "missing or invalid feeder heartbeat"
        return 2
    fi
    # The keeper can publish a new heartbeat between the first clock read
    # and opening its record. Check its timestamp against a fresh reading.
    if ! wd_now=$(watchdog_now) || [ "$wd_tick" -gt "$wd_now" ]; then
        echo "feeder heartbeat is in the future or monotonic clock is invalid"
        return 2
    fi
    case "$wd_start" in ''|*[!0-9]*) echo "invalid feeder process identity"; return 2 ;; esac
    if [ "$(cat "$CTL/feeder.pid" 2>/dev/null)" != "$wd_live" ] ||
       [ "$(cat "$CTL/feeder.ready" 2>/dev/null)" != "$wd_live" ] ||
       [ "$(watchdog_birth "$wd_live")" != "$wd_start" ]; then
        echo "feeder exited or its process identity changed"
        return 2
    fi
    if [ "$((wd_now - wd_tick))" -ge "$WD_MAX_AGE" ]; then
        echo "feeder keepalive progress stalled"
        return 2
    fi
    printf '%s %s\n' "$wd_live" "$wd_start"
}
watchdog_lost() {
    wd_problem=$(watchdog_health)
    [ $? = 2 ] || return 1
    [ ! -e "$CTL/feeder.off" ] && [ "$(watchdog_generation)" = "$WD_GEN" ] || return 1
    watchdog_failed "$wd_problem"
    return 0
}

# --- THE WAY BACK'S OWN HELPERS ---------------------------------------------
# The watcher and the key readers must run whatever the guest does. They are
# One UI-side processes in init's mount namespace; this puts the calling shell
# in the root cgroup (which cannot be frozen, has no limits and is not killed
# with the app's group; xnuhost gets a cgroup of its own, see --inner), on
# every core, ahead of ordinary processes and out of the OOM killer's reach.
out_of_the_way() {
    # (2>/dev/null first: a path that is not there is not worth a line.)
    echo $$ 2>/dev/null > "$T/sys/fs/cgroup/cgroup.procs"
    echo -1000 2>/dev/null > "$P/$$/oom_score_adj"
    for g in /dev/cpuset /dev/cpuctl; do
        [ -w "$T$g/cgroup.procs" ] && echo $$ 2>/dev/null > "$T$g/cgroup.procs"
    done
    renice -n -10 -p $$ >/dev/null 2>&1
    return 0
}

framework_block() { refuse "$*"; }

framework_setup_failed() {
    printf "Framework setup failed: %s\n" "$*" >&2
    printf "failed\n" > "$CTL/state"
    exit 4
}

framework_identity() {
    [ "$(getprop ro.product.model):$(getprop ro.product.device):$(getprop ro.soc.model)" = SM-S948B:m3q:SM8850 ] &&
        [ "$(getprop ro.build.fingerprint)" = samsung/m3qxxx/m3q:17/CP2A.260605.016/S948BXXS4BZIG_OXM4BZIG:user/release-keys ] &&
        [ "$(uname -r)" = 6.12.69-android16-6-pb4d3caf-abogkiS948BXXS4BZIG-4k ] &&
        [ "$(getenforce)" = Enforcing ]
}

FRAMEWORK_SERVICES="surfaceflinger vendor.qti.hardware.display.composer adbd vold keystore2 servicemanager logd lmkd installd audioserver cameraserver netd"
framework_service_pids() {
    services=$FRAMEWORK_SERVICES
    [ "$(getprop init.svc.hwservicemanager)" != running ] || services="$services hwservicemanager"
    for svc in $services; do
        [ "$(getprop "init.svc.$svc")" = running ] || return 1
        svc_pid=$(getprop "init.svc_debug_pid.$svc")
        watchdog_uint "$svc_pid" && [ "$svc_pid" -gt 1 ] && [ -d "$P/$svc_pid" ] || return 1
        grep -q '^0::/apps/' "$P/$svc_pid/cgroup" && return 1
        printf '%s %s\n' "$svc" "$svc_pid"
    done
}

framework_down() {
    [ "$(getprop init.svc.zygote)" = stopped ] &&
        [ "$(getprop init.svc.zygote_next)" = stopped ] &&
        case "$(getprop init.svc.zygote_secondary)" in ''|stopped) true ;; *) false ;; esac &&
        ! pidof system_server >/dev/null 2>&1
}

framework_apps_empty() {
    # Android places app process groups under /apps. No system cgroup is
    # eligible. cgroup.events includes all descendant (PID) groups.
    for group in "$T"/sys/fs/cgroup/apps/uid_*; do
        [ -d "$group" ] || continue
        grep -qx 'populated 0' "$group/cgroup.events" || return 1
    done
}

# This opt-in is pinned to the current session and its exact 180s duration.
# Recovery deadline and watchdog remain active; only OneOS software thermal
# monitor/cap health dependencies are omitted in this experiment.
sm8850_no_userspace_thermal() {
    [ "$FRAMEWORK" = 1 ] &&
    [ "$(cat "$CTL/framework.soft-thermal" 2>/dev/null)" = disabled-180s ] &&
    [ "$(cat "$CTL/framework.mode" 2>/dev/null)" = run ] &&
    [ "$(cat "$CTL/framework.duration" 2>/dev/null)" = 180 ] &&
    [ "$(cat "$CTL/boot" 2>/dev/null)" = "$(boot_id)" ]
}

framework_deadline() {
    [ "$FRAMEWORK" = 1 ] && [ -n "$1" ] && [ "$(watchdog_generation)" = "$1" ] || return 0
    WD_GEN=$1
    out_of_the_way
    printf '%s %s\n' "$$" "$(watchdog_birth $$)" > "$CTL/framework.guard" || return 1
    while [ "$(watchdog_generation)" = "$WD_GEN" ]; do
        case "$(cat "$CTL/state" 2>/dev/null)" in returning|returned) return 0 ;; esac
        limit=$(cat "$CTL/framework.deadline" 2>/dev/null) || limit=$(cat "$CTL/framework.cutoff" 2>/dev/null)
        tick=$(watchdog_now)
        expired=0
        if ! watchdog_uint "$limit" || ! watchdog_uint "$tick"; then
            why="invalid framework deadline"
        elif ! framework_pid_alive "$CTL/framework.watcher"; then
            why="framework watcher lost"
        elif [ "$(cat "$CTL/framework.mode" 2>/dev/null)" = run ] &&
             ! sm8850_no_userspace_thermal &&
             { [ "$(cat "$CTL/thermal.guard.required" 2>/dev/null)" != "$WD_GEN" ] ||
               ! framework_thermal_guard_healthy ||
               [ "$(cat "$CTL/thermal.cap.prearm.required" 2>/dev/null)" != "$WD_GEN" ] ||
               ! framework_thermal_cap_prearmed ||
               { [ -e "$CTL/thermal.cap.required" ] &&
                 ! framework_thermal_cap_healthy; } ||
               { [ "$(cat "$CTL/state" 2>/dev/null)" = running ] &&
                 ! framework_thermal_cap_healthy; }; }; then
            why="independent thermal monitor/cap missing, stale, or exceeded emergency threshold"
        elif [ "$tick" -ge "$limit" ]; then
            expired=1
            why="framework deadline reached at $tick (deadline $limit)"
        else
            sleep 1
            continue
        fi
        echo "$(date '+%F %T') framework guard: $why"
        if [ "$expired" = 1 ] && [ "$(cat "$CTL/framework.deadline" 2>/dev/null)" = "$limit" ] &&
            [ "$(cat "$CTL/state" 2>/dev/null)" = running ] &&
            [ ! -e "$SESSION/return.request" ]; then
            mode=$(cat "$CTL/framework.mode" 2>/dev/null)
            if [ "$mode" = run ]; then
                guest_pid=$(cat "$CTL/xnuhost.pid" 2>/dev/null)
                guest_ns=$(cat "$CTL/mntns" 2>/dev/null)
                [ -n "$guest_ns" ] && [ "$(readlink "$P/$guest_pid/ns/mnt" 2>/dev/null)" = "$guest_ns" ] || mode=
            fi
            [ -z "$mode" ] || printf '%s\n' "$why" > "$CTL/framework.elapsed"
        fi
        publish_return_request "$why"
        $SH "$SELF_RETURN" framework-deadline "$WD_GEN" && return 0
        [ "$(watchdog_generation)" != "$WD_GEN" ] ||
            hard_reboot oneios-watcher-failsafe "framework deadline could not return One UI"
        return 0
    done
}

framework_pid_alive() {
    [ -r "$1" ] || return 1
    read -r checked_pid checked_birth 2>/dev/null < "$1" && watchdog_uint "$checked_pid" &&
        [ -n "$checked_birth" ] && [ "$(watchdog_birth "$checked_pid")" = "$checked_birth" ] || return 1
    [ -n "$T" ] || { grep -qx '0::/' "$P/$checked_pid/cgroup" &&
        [ "$(cat "$P/$checked_pid/oom_score_adj")" = -1000 ] &&
        [ "$(readlink "$P/$checked_pid/ns/mnt")" = "$(readlink "$P/1/ns/mnt")" ]; }
}

# Root thermal monitor and CPU cap are outside the guest's cgroup, in
# init's mount namespace. Exact boot, watchdog generation, PID birth and
# heartbeat age are verified independently of xnuhost. 80 C means throttle,
# not return; 90 C is a last-resort emergency guard fault.
framework_thermal_guard_healthy() {
    [ ! -e "$CTL/thermal.guard.fault" ] || return 1
    framework_pid_alive "$CTL/thermal.guard.pid" || return 1
    read -r th_ver th_boot th_gen th_pid th_birth th_seq th_tick th_status th_cpu th_gpu th_ddr th_bat th_lrp th_ap th_extra < "$CTL/thermal.guard.heartbeat" || return 1
    [ -z "$th_extra" ] && [ "$th_ver" = v1 ] &&
        [ "$th_boot" = "$(cat "$CTL/boot" 2>/dev/null)" ] &&
        [ "$th_gen" = "$(watchdog_generation)" ] &&
        [ "$th_pid $th_birth" = "$(cat "$CTL/thermal.guard.pid" 2>/dev/null)" ] &&
        [ "$th_status" = OK ] || return 1
    for v in "$th_seq" "$th_tick" "$th_cpu" "$th_gpu" "$th_ddr" "$th_bat" "$th_lrp" "$th_ap"; do
        watchdog_uint "$v" || return 1
    done
    [ "$th_seq" -gt 0 ] || return 1
    th_now=$(watchdog_now) || return 1
    [ "$th_tick" -le "$th_now" ] && [ $((th_now - th_tick)) -le 6 ]
}
framework_thermal_cap_prearmed() {
    [ ! -e "$CTL/thermal.cap.fault" ] || return 1
    framework_pid_alive "$CTL/thermal.cap.pid" || return 1
    read -r pre_ver pre_boot pre_gen pre_pid pre_birth pre_extra < "$CTL/thermal.cap.prearmed" || return 1
    [ "$pre_ver" = v1 ] && [ -z "$pre_extra" ] &&
        [ "$pre_boot" = "$(cat "$CTL/boot" 2>/dev/null)" ] &&
        [ "$pre_gen" = "$(watchdog_generation)" ] &&
        [ "$pre_pid $pre_birth" = "$(cat "$CTL/thermal.cap.pid" 2>/dev/null)" ]
}
# BEGIN FRAMEWORK_CPU_BUDGET_GROUP
# The root cap worker owns creation and writes. The guest may only join the
# exact session group after the verified Framework-down cap heartbeat.
framework_cpu_budget_group() (
    ctl=$1
    [ "$(cat "$ctl/framework.cpu-budget" 2>/dev/null)" = hybrid-v1-180s ] &&
        [ "$(cat "$ctl/framework.duration" 2>/dev/null)" = 180 ] || exit 1
    read -r bv bb bg bt bi bx < "$ctl/thermal.cap.group" || exit 1
    [ "$bv" = v1 ] && [ -z "$bx" ] &&
        [ "$bb" = "$(boot_id)" ] && [ "$bb" = "$(cat "$ctl/boot")" ] &&
        [ "$bg" = "$(cat "$ctl/watchdog.generation")" ] &&
        [ "$bt" = "$(cat "$ctl/framework.launch")" ] || exit 1
    case "$bt" in ''|*[!0-9a-f]*) exit 1 ;; esac
    [ "${#bt}" = 32 ] || exit 1
    group="/dev/cpuctl/oneios_guest.$bt"
    [ -d "$group" ] && [ ! -L "$group" ] &&
        [ "$(realpath "$group")" = "$group" ] &&
        [ "$(stat -c '%d:%i' "$group")" = "$bi" ] &&
        [ "$(cat "$group/cpu.cfs_period_us")" = 20000 ] || exit 1
    printf '%s\n' "$group"
)
# END FRAMEWORK_CPU_BUDGET_GROUP
framework_thermal_cap_healthy() {
    [ ! -e "$CTL/thermal.cap.fault" ] || return 1
    framework_pid_alive "$CTL/thermal.cap.pid" || return 1
    read -r cp_ver cp_boot cp_gen cp_pid cp_birth cp_seq cp_tick cp_status cp_level cp_pct cp_extra < "$CTL/thermal.cap.heartbeat" || return 1
    [ -z "$cp_extra" ] && [ "$cp_ver" = v1 ] &&
        [ "$cp_boot" = "$(cat "$CTL/boot" 2>/dev/null)" ] &&
        [ "$cp_gen" = "$(watchdog_generation)" ] &&
        [ "$cp_pid $cp_birth" = "$(cat "$CTL/thermal.cap.pid" 2>/dev/null)" ] &&
        [ "$cp_status" = OK ] || return 1
    for v in "$cp_seq" "$cp_tick" "$cp_level" "$cp_pct"; do watchdog_uint "$v" || return 1; done
    [ "$cp_seq" -gt 0 ] || return 1
    case "$(cat "$CTL/framework.cpu-budget" 2>/dev/null || :)" in
        hybrid-v1-180s)
            [ "$cp_level" = 7 ] && [ "$cp_pct" -ge 10 ] && [ "$cp_pct" -le 100 ] &&
                framework_cpu_budget_group "$CTL" >/dev/null || return 1 ;;
        '')
            case "$cp_level:$cp_pct" in 1:60|2:40|3:28|4:18|5:12|6:8) ;; *) return 1 ;; esac ;;
        *) return 1 ;;
    esac
    cp_now=$(watchdog_now) || return 1
    [ "$cp_tick" -le "$cp_now" ] && [ $((cp_now - cp_tick)) -le 4 ]
}
framework_recovery_ready() {
    framework_pid_alive "$CTL/framework.guard" && framework_pid_alive "$CTL/framework.watcher" || return 1
    if [ "$(cat "$CTL/framework.mode" 2>/dev/null)" = run ] && ! sm8850_no_userspace_thermal; then
        [ "$(cat "$CTL/thermal.guard.required" 2>/dev/null)" = "$(watchdog_generation)" ] &&
            framework_thermal_guard_healthy || return 1
        # The CPU-cap PROCESS is prearmed before Framework stop but
        # remains read-only until the independent "Framework down" gate.
        # Stop admission requires its generation-pinned live PID even
        # though there is intentionally no active cap heartbeat yet.
        [ "$(cat "$CTL/thermal.cap.prearm.required" 2>/dev/null)" = "$(watchdog_generation)" ] &&
            framework_thermal_cap_prearmed || return 1
        if [ -e "$CTL/thermal.cap.required" ] ||
           [ "$(cat "$CTL/state" 2>/dev/null)" = running ]; then
            [ "$(cat "$CTL/thermal.cap.required" 2>/dev/null)" = "$(watchdog_generation)" ] &&
                framework_thermal_cap_healthy || return 1
        fi
    fi
    [ "$(grep -c . "$CTL/keys/pids" 2>/dev/null)" = 3 ] || return 1
    for reader in $(cat "$CTL/keys/pids"); do
        framework_pid_alive "$CTL/keys/reader.$reader" || return 1
    done
    case " $(cat "$T/sys/power/wake_lock" 2>/dev/null) " in *" oneios_session "*) ;; *) return 1 ;; esac
}

stop_android_framework() {
    [ "$FRAMEWORK" = 0 ] || framework_recovery_ready || return 1
    if [ "$FRAMEWORK" = 1 ] && [ "${FW_SOFT_THERMAL_OFF:-0}" = 1 ]; then
        # This is the last Android input action, while system_server exists.
        # The device's lock screen can auto-sleep ~5s after an earlier pulse.
        # Never run input AFTER setprop ctl.stop zygote: the InputManager
        # binder belongs to system_server and is no longer available.
        if ! timeout 5 input keyevent KEYCODE_WAKEUP >/dev/null 2>&1; then
            echo "FRAMEWORK_FINAL_WAKE=FAILED_BEFORE_FRAMEWORK_STOP"
            return 1
        fi
        echo "FRAMEWORK_FINAL_WAKE=KEYCODE_WAKEUP_IMMEDIATELY_PRE_STOP"
    fi
    printf '%s\n' "$(date +%s)" > "$CTL/stopped" || return 1
    setprop ctl.stop zygote
    [ -n "$(getprop init.svc.zygote_secondary)" ] && setprop ctl.stop zygote_secondary
    [ "$FRAMEWORK" = 0 ] || setprop ctl.stop zygote_next
    n=0
    while [ "$n" -lt 50 ] && pidof system_server >/dev/null 2>&1; do
        sleep 0.2; n=$((n + 1))
    done
    kill -9 $(pidof system_server) 2>/dev/null
    kill -9 $(pidof zygote64) $(pidof zygote) 2>/dev/null
    [ "$FRAMEWORK" = 1 ] || return 0
    n=0
    until framework_down; do
        [ "$n" -lt 5 ] || return 1
        sleep 0.2; n=$((n + 1))
    done
}

framework_probe() {
    fw_bad=0
    framework_identity && echo "framework target: SM-S948B/m3q/SM8850 S948BXXS4BZIG enforcing" ||
        { echo "BLOCKED: experimental firmware or SELinux mismatch"; fw_bad=1; }
    KDEVS=$(volume_key_devices) && printf 'physical recovery inputs: %s\n' "$(echo $KDEVS)" ||
        { echo "BLOCKED: physical recovery keys are ambiguous or missing"; fw_bad=1; }
    if [ "$FRAMEWORK_REBOOT" = 1 ]; then
        WD_TARGET=$(framework_legacy_target) &&
            echo "watchdog: $WD_TARGET (OneOS legacy candidate; reboot-only smoke)" ||
            { echo "BLOCKED: no stable legacy /dev/watchdog holder matching this SM8850 boot"; fw_bad=1; }
        echo "WATCHDOG_QUALIFICATION=UNVERIFIED_REBOOT_ONLY"
    else
        WD_TARGET=$(watchdog_target) && echo "watchdog: $WD_TARGET" ||
            { echo "BLOCKED: watchdog needs a directly held numbered softdog, active metadata, known nowayout, no pretimeout and >=100s timeout"; fw_bad=1; }
        if [ -z "$WD_TARGET" ] || ! framework_watchdog_plan "$WD_TARGET" >/dev/null; then
            echo "BLOCKED: no independently qualified watchdog plan with readable time remaining"
            fw_bad=1
        fi
    fi
    printf 'watchdog sysfs: '
    printf '%s\n' "$T"/sys/class/watchdog/watchdog*/{identity,state,timeout,nowayout,pretimeout} |
        while read -r node; do [ ! -r "$node" ] || printf '%s=%s ' "${node##*/}" "$(cat "$node")"; done
    echo
    SS=$(pidof system_server)
    if [ -n "$SS" ] && [ "$(timeout 4 dumpsys --pid inputflinger)" = "$SS" ] &&
        [ "$(timeout 4 dumpsys --pid input)" = "$SS" ]; then
        echo "inputflinger and input owned by system_server $SS"
    else
        echo "BLOCKED: could not attribute both Android input services to system_server"
        fw_bad=1
    fi
    if fw_services=$(framework_service_pids); then
        printf 'protected services:\n%s\n' "$fw_services"
    else
        echo "BLOCKED: required Android service PID missing or in the app cgroup"
        fw_bad=1
    fi
    [ -d "$T/sys/fs/cgroup/apps" ] || { echo "BLOCKED: Android app cgroup missing"; fw_bad=1; }
    for group in "$T"/sys/fs/cgroup/apps/uid_*; do
        [ -d "$group" ] || continue
        [ -w "$group/cgroup.kill" ] && [ -r "$group/cgroup.events" ] ||
            { echo "BLOCKED: the app cgroup cannot be checked and drained"; fw_bad=1; break; }
    done
    printf 'vm.max_map_count=%s\n' "$(cat "$P/sys/vm/max_map_count" 2>/dev/null)"
    printf 'data fs=%s free KiB=%s\n' "$(stat -f -c %T /data/adb)" "$(df -Pk /data/adb | awk 'NR==2 {print $4}')"
    for dir in /data/local/tmp/oneios/image "$FRAMEWORK_STAGE/image" /data/local/tmp/oneios-m3q-ios27-bench/image; do
        if [ -d "$dir" ]; then printf 'image present: %s\n' "$dir"; else printf 'image absent: %s\n' "$dir"; fi
    done
    return "$fw_bad"
}

framework_configure() {
    fw_old=$(cat "$P/sys/vm/max_map_count") && watchdog_uint "$fw_old" || return 1
    fw_map=$fw_old
    [ "$fw_map" -ge 1048576 ] || fw_map=1048576
    printf '%s %s\n' "$fw_old" "$fw_map" > "$B/max_map_count.tmp" &&
        mv -f "$B/max_map_count.tmp" "$B/max_map_count" || return 1
    [ "$fw_map" = "$fw_old" ] ||
        echo "$fw_map" > "$P/sys/vm/max_map_count" || return 1
    [ "$(cat "$P/sys/vm/max_map_count")" = "$fw_map" ] || return 1
    echo "vm.max_map_count: $fw_old -> $fw_map"
}

framework_capture() {
    [ -e "$SESSION/ready" ] && grep -q 'first frame posted' "$CTL/display.log" 2>/dev/null || return 0
    elapsed=$((t - ready_at))
    case "$elapsed" in 0|30|60|120|180)
        timeout 3 screencap -p "$CTL/captures/frame-$elapsed.png" >> "$CTL/display.log" 2>&1 ;;
    esac
}
# The measured S24 Ultra and S26 Ultra input layouts have the same two
# physical key drivers. Match the name and the reported key on each node;
# a Bluetooth consumer-control device can advertise both volume keys.
volume_key_devices() {
    key_report=$(getevent -pl 2>/dev/null) || return 1
    printf '%s\n' "$key_report" | awk '
        function record() {
            if (dev !~ /^\/dev\/input\/event[0-9]+$/) return
            if (name == "gpio-keys" && up) { up_dev = dev; up_count++ }
            if (name == "pmic_resin" && down) { down_dev = dev; down_count++ }
        }
        /^add device / { record(); dev = $NF; name = ""; up = down = keys = 0; next }
        /^[[:space:]]+name:[[:space:]]+"gpio-keys"[[:space:]]*$/ { name = "gpio-keys"; next }
        /^[[:space:]]+name:[[:space:]]+"pmic_resin"[[:space:]]*$/ { name = "pmic_resin"; next }
        $2 ~ /^\([[:xdigit:]]+\):$/ { keys = ($1 == "KEY" && $2 == "(0001):") }
        keys {
            for (i = ($1 == "KEY" ? 3 : 1); i <= NF; i++) {
                if ($i == "KEY_VOLUMEUP" || $i == "KEY_VOLUMEUP*") up = 1
                if ($i == "KEY_VOLUMEDOWN" || $i == "KEY_VOLUMEDOWN*") down = 1
            }
        }
        END {
            record()
            if (up_count != 1 || down_count != 1 || up_dev == down_dev) exit 1
            print up_dev
            print down_dev
        }
    '
}
# The keys ask the watcher, which acts within a second. A session that is
# still not returning 5 s later has no working watcher (killed, or stuck): the
# return then starts from the key reader itself. oneios_return.sh takes one
# caller at a time, so the two can meet.
ask_return() { # <why>
    publish_return_request "$1 at $(date '+%F %T')"
    sleep 5
    [ "$(cat "$CTL/keys/session" 2>/dev/null)" = "$tok" ] || return 0
    case "$(cat "$CTL/state" 2>/dev/null)" in
        starting|running)
            echo "$(date '+%F %T') keys: the watcher did not start the return within 5 s of '$1'; starting it from the key reader" >> "$STAGE/return.log"
            # In a session of its own: the return ends the key readers by
            # their process groups, and this is one of them.
            if [ -n "$BB" ]; then exec "$BB" setsid $SH "$STAGE/oneios_return.sh" keys-direct >> "$STAGE/return.log" 2>&1
            else exec $SH "$STAGE/oneios_return.sh" keys-direct >> "$STAGE/return.log" 2>&1; fi ;;
    esac
    return 0
}
# A key reader is started in a session of its own (setsid), so it leads a
# process group that holds only itself, its getevent and its timers: the
# return, and a reader that finds it is no longer this session's, end the
# whole group at once. The reader lists itself for the return.
reader_start() {
    echo $$ >> "$CTL/keys/pids"
    OWN_GROUP=0
    [ "$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')" = "$$" ] && OWN_GROUP=1
    out_of_the_way
    if [ "$FRAMEWORK" = 1 ]; then
        printf '%s %s\n' "$$" "$(watchdog_birth $$)" > "$CTL/keys/reader.$$"
    fi
}
reader_end() {
    [ "$OWN_GROUP" = 1 ] && kill -9 -- "-$$" 2>/dev/null
    exit 0
}
# The display helper (OneiOS's runtime/display, bin/oneios-display): a One
# UI-side process that shows the guest's frames (session/display.sock) on a
# surfaceflinger layer. Ended by its pid, never waited for: surfaceflinger
# drops a dead client's layers, and the return restarts the composer anyway.
end_display() {
    for dp in $(cat "$CTL/display.pid" 2>/dev/null); do
        # (cat, then tr: toybox's tr never ends on a failed read, and a read of
        # the cmdline of a process that just ended fails. oneios_return.sh.)
        case "$(cat "$P/$dp/cmdline" 2>/dev/null | tr '\0' ' ')" in
            *OneiOSDisplay*|*oneios-display*) kill -9 "$dp" 2>/dev/null ;;
        esac
    done
    return 0
}
# --- THE BOOT SCREEN -------------------------------------------------------
# OneOS's own boot screen, the one an Android guest's switch shows
# (boot_status.sh, its renderer OneOSBootStatus.dex, the OneOS icon;
# docs/boot-status.md), from $STAGE/bin, which xnuhost's namespace has
# read-only. From the stop of One UI's framework until the guest's first frame
# it shows "Starting iOS 27", the boot stage read from xnuhost's log, and the
# way back. Optional, like OneOS's: every failure here leaves the switch and
# the way back exactly as they are without it. It reads no key and takes no
# input device; its status files are in control/, where the guest cannot write.
BOOTUI="$CTL/bootui"
BOOTBIN="$STAGE/bin"
bootui() { # <a function of boot_status.sh> [arguments]
    [ -d "$BOOTUI" ] && [ -f "$BOOTBIN/boot_status.sh" ] || return 0
    ( ONEOS_BOOT_DIR=$BOOTUI; ONEOS_BOOT_HOME=$BOOTBIN; . "$BOOTBIN/boot_status.sh" && "$@" ) >/dev/null 2>&1
    return 0
}
# What is drawn comes from a log the guest writes: printable ASCII, one line, cut.
plain() { printf '%s' "$1" | LC_ALL=C tr -c ' -~' ' ' | cut -c1-"${2:-200}"; }
screen() { # <title|status> <text>
    bootui oneos_boot_write "$1" "$(plain "$2")"
}
# Starts the screen (the session only). The renderer gets 3 s for its first
# frame; with or without one the switch goes on.
bootui_begin() {
    [ "$FRAMEWORK" = 0 ] || return 0
    [ "${ONEIOS_BOOTUI:-1}" != 0 ] || { echo "Boot screen: off (ONEIOS_BOOTUI=0)"; return 0; }
    for f in boot_status.sh OneOSBootStatus.dex oneos_boot_icon.png; do
        [ -f "$BOOTBIN/$f" ] && root_only "$BOOTBIN/$f" ||
            { echo "Boot screen: $BOOTBIN/$f is not staged or not root's; the screen stays dark until iOS draws"; return 0; }
    done
    command -v app_process >/dev/null 2>&1 || { echo "Boot screen: no app_process; the screen stays dark until iOS draws"; return 0; }
    (
        ONEOS_BOOT_DIR=$BOOTUI; ONEOS_BOOT_HOME=$BOOTBIN; ONEOS_BOOT_MAX=1800
        export ONEOS_BOOT_DIR ONEOS_BOOT_HOME ONEOS_BOOT_MAX
        . "$BOOTBIN/boot_status.sh" || exit 1
        oneos_boot_begin ios
        oneos_boot_write status "Stopping One UI's framework"
        oneos_boot_wait_ready 3
    ) </dev/null >>"$CTL/bootui.log" 2>&1
    rc=$?
    [ -s "$BOOTUI/generation" ] || { echo "Boot screen: could not be started (log $CTL/bootui.log); the screen stays dark until iOS draws"; return 0; }
    "$BB" setsid $SH "$SELF" --bootui </dev/null >>"$CTL/bootui.log" 2>&1 &
    if [ $rc = 0 ]; then echo "Boot screen: up (renderer $(cut -d' ' -f1 "$BOOTUI/ready" 2>/dev/null), log $BOOTUI/renderer.log)"
    else echo "Boot screen: the renderer posted no frame within 3 s (log $BOOTUI/renderer.log); the switch goes on"; fi
    return 0
}
# xnuhost's log from byte $1 on (1 MiB at most): how far the boot got ($2 is the
# stage so far) and what ended it. The stage markers are the Session logs
# screen's nine (OneiosLogs.kt; docs/oneios.md, "Session logs"; OneiOS's
# oneos/interface.md section 8), with the kernel's "OneiOS Data: first start"
# between the root mount and launchd, where a new Data volume takes minutes.
# Prints "S <stage>", "B" (a new boot began: xnuhost started the guest again
# in place), "P <panic text>", "W <why xnuhost stops>", "X <exit code>",
# "E <xnuhost's last error line>".
log_scan() { # <first byte, from 1> <stage so far>
    [ -f "$SESSION/xnuhost.log" ] && [ ! -L "$SESSION/xnuhost.log" ] || return 0
    $TMO tail -c "+$1" "$SESSION/xnuhost.log" 2>/dev/null | head -c 1048576 | LC_ALL=C tr -d '\000' | LC_ALL=C awk -v st="$2" '
        function s(n) { if (n > st) st = n }
        { line = $0; sub(/^\[ *[0-9]+\.[0-9][0-9][0-9]\] /, "", line) }
        line ~ /^guest / {
            t = line; sub(/^guest +/, "", t)
            if (index(t, "Darwin Kernel Version") == 1) s(3)
            else if (index(t, "BSD root: ") == 1) s(4)
            else if (index(t, "OneiOS Data: first start") == 1 || index(t, "OneiOS Data: unpacking the seed") == 1) s(5)
            else if (index(t, "load_init_program: attempting to load") == 1) s(6)
            else if (index(t, "com.apple.xpc.launchd|") == 1) s(7)
            else if (panic == "" && t ~ /^panic\(cpu [0-9]+ caller 0x[0-9a-f]+\): /) { panic = t; sub(/^panic\([^)]*\): /, "", panic) }
            if (index(t, "backboardd[")) s(8)
            if (index(t, "SpringBoard[") || index(t, "crashed: SpringBoard.")) s(9)
            next
        }
        line ~ /^xnuhost I / {
            t = substr(line, 11)
            if (index(t, "xnuhost: session ABI ") == 1) { st = 1; boot = 1; panic = ""; why = ""; code = ""; err = "" }
            else if (index(t, "cpu0: entering the kernel at ") == 1) s(2)
            else if (index(t, "guest ready: first frame") == 1) s(10)
            else if (index(t, "stopping: ") == 1) { why = substr(t, 11); sub(/ \(reason [0-9]+, code [0-9]+\)$/, "", why) }
            else if (t ~ /^exit [0-9]+$/) code = substr(t, 6)
            next
        }
        line ~ /^xnuhost E / { err = substr(line, 11) }
        END {
            print "S " st
            if (boot) print "B"
            if (panic != "") print "P " panic
            if (why != "") print "W " why
            if (code != "") print "X " code
            if (err != "") print "E " err
        }'
}
stage_text() { # <stage of log_scan>
    case "$1" in
        1) echo "xnuhost is loading the kernel" ;;
        2) echo "Entering the kernel" ;;
        3) echo "Kernel started" ;;
        4) echo "Root volume mounted" ;;
        5) echo "Data volume: first start (this can take a few minutes)" ;;
        6) echo "Loading launchd" ;;
        7) echo "launchd is running" ;;
        8) echo "backboardd started" ;;
        9) echo "SpringBoard started" ;;
        10) echo "iOS is up: waiting for its first frame" ;;
    esac
}
# One line on why xnuhost ended, from the last 64 KiB of its log.
why_ended() {
    sz=$(stat -c %s "$SESSION/xnuhost.log" 2>/dev/null)
    # (awk, not the shell: Android's sh counts in 32 bits.)
    from=$(awk -v s="${sz:-0}" 'BEGIN { print (s + 0 > 65536) ? s - 65535 : 1 }')
    log_scan "$from" 0 | awk '
        /^P / { p = substr($0, 3) } /^W / { w = substr($0, 3) } /^X / { x = substr($0, 3) } /^E / { e = substr($0, 3) }
        END {
            if (p != "") print "iOS stopped: kernel panic: " p
            else if (w != "") print "iOS stopped: " w (x != "" ? " (xnuhost exit " x ")" : "")
            else if (x != "") print "xnuhost ended with exit " x (e != "" ? ": " e : "")
            else if (e != "") print "xnuhost ended: " e
            else print "xnuhost ended"
        }'
}
# The display helper runs and has the guest's picture: its first frame is
# posted, or xnuhost reported ready and the helper's layer is up. Its layer is
# above the boot screen's, so the picture covers the boot screen first and the
# boot screen is taken away under it.
display_up() {
    for dp in $(cat "$CTL/display.pid" 2>/dev/null); do
        case "$(cat "$P/$dp/cmdline" 2>/dev/null | tr '\0' ' ')" in
            *OneiOSDisplay*|*oneios-display*) ;;
            *) continue ;;
        esac
        grep -q 'oneios-display: first frame posted' "$CTL/display.log" 2>/dev/null && return 0
        [ -e "$SESSION/ready" ] && grep -q 'oneios-display: layer up' "$CTL/display.log" 2>/dev/null && return 0
    done
    return 1
}
TMO=""
command -v timeout >/dev/null 2>&1 && TMO="timeout 5"

# sync, waited for 5 s at most: a sync that stands still (a stuck disk or
# FUSE) must not keep the reboot's last resorts from running.
sync_bounded() {
    sync &
    sb=$!; sn=0
    while [ $sn -lt 25 ] && [ -d "$P/$sb" ]; do sleep 0.2; sn=$((sn + 1)); done
}
# The reboot return without oneios_return.sh, for the watcher when that script
# cannot be run or ends with an error: the same three steps as its failsafe.
hard_reboot() { # <reason word> <why>
    echo "$(date '+%F %T') watcher: $2 - rebooting into One UI"
    bootui oneos_boot_stop
    if [ "$FRAMEWORK" = 0 ] || ! grep -q '^failsafe ' "$STAGE/return.outcome" 2>/dev/null; then
        echo "failsafe $(date +%s) $2" > "$STAGE/return.outcome"
    fi
    sync_bounded
    setprop sys.powerctl "reboot,$1"
    sleep 20
    # init did not reboot: Android's own reboot, then busybox's (a root manager's busybox may have no reboot
    # applet: then it only prints that), then sysrq.
    sync_bounded
    # (In the background: Android's reboot waits for init for ever once it set the property.)
    [ -x "$T/system/bin/reboot" ] && "$T/system/bin/reboot" "$1" </dev/null >/dev/null 2>&1 &
    sleep 5
    [ -n "$BB" ] && "$BB" reboot -f
    sleep 5
    echo 1 > "$P/sys/kernel/sysrq" 2>/dev/null
    echo s > "$P/sysrq-trigger" 2>/dev/null
    sleep 2
    echo b > "$P/sysrq-trigger" 2>/dev/null
    exit 1
}

# --- THE STAGE (no root tools needed; also what the tests run) -------------
# The runtime package and the image set as oneios_root.sh staged them. A
# missing runtime or image is the usual refusal: one line that says which.
stage_checks() {
    [ -d "$STAGE" ] && [ ! -L "$STAGE" ] || refuse "OneiOS is not set up on this phone ($STAGE is missing)"
    root_only "$STAGE" || refuse "$STAGE is not root's or is writable by others"
    for f in oneios_switch.sh oneios_return.sh; do
        [ -f "$STAGE/$f" ] && root_only "$STAGE/$f" || refuse "$STAGE/$f is missing or not root's"
    done

    # The runtime: runtime.conf (written by root from the checked runtime.json),
    # runtime.sha256 (every file root wrote), and xnuhost itself.
    RC="$STAGE/runtime.conf"
    [ -f "$RC" ] && [ -d "$STAGE/runtime" ] && [ ! -L "$STAGE/runtime" ] ||
        refuse "no OneiOS runtime is staged: xnuhost, the program that runs iOS, comes with it (download or import the runtime in the OneOS app)"
    root_only "$RC" && root_only "$STAGE/runtime" || refuse "the staged runtime is not root's"
    R_VERSION=$(conf "$RC" version)
    R_ABI=$(conf "$RC" session_abi)
    R_XNUHOST=$(conf "$RC" xnuhost)
    R_FORMATS=$(conf "$RC" image_formats)
    case "$R_XNUHOST" in
        ''|/*|*..*|*[!A-Za-z0-9._/+-]*) refuse "the runtime ${R_VERSION:-?} names no xnuhost (runtime.conf: '${R_XNUHOST}')" ;;
    esac
    [ "$R_ABI" = "$ABI" ] ||
        refuse "the runtime ${R_VERSION:-?} speaks session ABI ${R_ABI:-none}, this OneOS speaks $ABI: update the OneOS app or the runtime"
    X="$STAGE/runtime/$R_XNUHOST"
    [ -f "$X" ] && [ ! -L "$X" ] ||
        refuse "the runtime ${R_VERSION:-?} has no xnuhost ($R_XNUHOST): it cannot start iOS yet"
    root_only "$X" && [ -x "$X" ] || refuse "xnuhost is not root's, or not executable"
    # OneiOS's packages carry a stand-in that only prints "not built yet" until
    # xnuhost is built (runtime.json "placeholder": true). One UI is not stopped for it.
    [ "$(conf "$RC" placeholder)" != 1 ] ||
        refuse "the runtime ${R_VERSION:-?} carries a placeholder instead of xnuhost (OneiOS has not built xnuhost yet): it cannot start iOS"
    # An arm64 ELF executable: "\177ELF", class 2 (64-bit), e_machine 0xb7.
    [ "$(od -An -tx1 -N5 "$X" 2>/dev/null | tr -d ' \n')" = 7f454c4602 ] &&
        [ "$(od -An -tx1 -j18 -N2 "$X" 2>/dev/null | tr -d ' \n')" = b700 ] ||
        refuse "xnuhost is not an arm64 program"
    check_list runtime full

    # The image set: its format must be one this runtime boots.
    IC="$STAGE/image.conf"
    [ -f "$IC" ] && [ -d "$STAGE/image" ] && [ ! -L "$STAGE/image" ] ||
        refuse "no iOS image set is staged: import the one you built with OneiOS's scripts in the OneOS app"
    root_only "$IC" && root_only "$STAGE/image" || refuse "the staged image set is not root's"
    I_FORMAT=$(conf "$IC" format)
    I_VERSION=$(conf "$IC" version)
    I_BUILD=$(conf "$IC" build)
    case "$I_FORMAT" in ''|*[!0-9]*) refuse "the image set has no format number (image.conf)" ;; esac
    case ",$R_FORMATS," in
        *",$I_FORMAT,"*) ;;
        *) refuse "the image set is format $I_FORMAT, the runtime ${R_VERSION:-?} boots format(s) ${R_FORMATS:-none}: build the image again or take a matching runtime" ;;
    esac
    check_list image ids
}
# <runtime|image> <full|ids>: $STAGE/<kind>.sha256 lists exactly the files of
# $STAGE/<kind>, each root's. full: every SHA-256 again (the runtime is small).
# ids: each file is the one root hashed at staging (dev:inode:size:mtime in
# <kind>.ids); files under 64 MiB are hashed again, and all of them with
# ONEIOS_VERIFY_IMAGE=1 (minutes for an image of several GB).
check_list() {
    kind=$1 how=$2
    SUMS="$STAGE/$kind.sha256"
    [ -f "$SUMS" ] && root_only "$SUMS" || refuse "$kind.sha256 is missing or not root's: stage the $kind again"
    bad=$(awk 'NF != 2 || length($1) != 64 || $1 ~ /[^0-9a-f]/ || $2 !~ /^[A-Za-z0-9_][A-Za-z0-9._+\/-]*$/ || $2 ~ /\.\./ ||
               seen[$2]++ { print NR ": " $0 }' "$SUMS" | head -n 3)
    [ -z "$bad" ] || refuse "$kind.sha256 has malformed lines: $bad"
    [ -s "$SUMS" ] || refuse "$kind.sha256 is empty"
    if [ "$how" = ids ]; then
        IDS="$STAGE/$kind.ids"
        [ -f "$IDS" ] && root_only "$IDS" || refuse "$kind.ids is missing or not root's: stage the $kind again"
    fi
    while read -r sum name || [ -n "$sum" ]; do
        f="$STAGE/$kind/$name"
        [ -f "$f" ] && [ ! -L "$f" ] || refuse "$kind/$name is missing or a link: stage the $kind again"
        root_only "$f" || refuse "$kind/$name is not root's or is writable by others"
        hash=1
        if [ "$how" = ids ]; then
            want=$(awk -v n="$name" '$2 == n { print $1 }' "$IDS")
            [ -n "$want" ] && [ "$(file_id "$f")" = "$want" ] ||
                refuse "$kind/$name changed since it was staged: stage the $kind again"
            # (awk, not the shell: Android's sh counts in 32 bits, and an image of several GB wraps.)
            [ "${ONEIOS_VERIFY_IMAGE:-0}" = 1 ] || awk -v b="$(stat -c %s "$f" 2>/dev/null)" 'BEGIN { exit !(b + 0 < 67108864) }' || hash=0
        fi
        if [ $hash = 1 ]; then
            [ "$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)" = "$sum" ] ||
                refuse "$kind/$name does not match its SHA-256: stage the $kind again"
        fi
    done < "$SUMS"
    # Nothing the list does not name (a leftover would be visible to xnuhost).
    extra=$(cd "$STAGE/$kind" && find . ! -type d | sed 's|^\./||' | while read -r n; do
        awk -v n="$n" '$2 == n { f = 1 } END { exit !f }' "$SUMS" || echo "$n"
    done | head -n 3 | tr '\n' ' ')
    [ -z "$extra" ] || refuse "$kind/ holds files its list does not name ($extra): stage the $kind again"
}

# --- ONE UI'S CLOCK CAPS ----------------------------------------------------
# One UI (Samsung's SSRM in system_server, and the HALs it drives) caps the CPU and
# GPU clocks when the phone is warm, and its power HAL raises the CPUs' floors in
# bursts. The switch stops system_server, so whatever it last wrote stayed for the
# whole session: 1.7-2.0 GHz CPUs and a 500 MHz GPU after a warm One UI (the S24
# Ultra, 2026-11-12; OneiOS docs/hardware.md 7d). These nodes are saved while One
# UI is whole (clocks_save, into control/base/clocks: node, One UI's value, the
# session's) and the hardware's range is written once system_server is gone
# (clocks_tops); the return writes One UI's values back before its zygote starts,
# on every path that stopped One UI, a killed xnuhost's too. The kernel's thermal
# zones, trips and cooling devices are never written: they, LMh and xnuhost's own
# thermal step (OneiOS runtime/bridges/thermal) cap the session. Nothing under
# /sys/power.
clock_top() { # <list of numbers>: the largest
    awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/ && $i + 0 > m) m = $i + 0 } END { if (m) print m }'
}
clocks_save() {
    out="$CTL/base/clocks"
    true > "$out"
    # Samsung's cpufreq_limit (drivers/cpufreq/cpufreq_limit.c of the SM8650 kernel): SSRM's one value for every
    # cluster, held as a freq QoS request of its own above scaling_max_freq and scaling_min_freq (so a write there
    # does not lift it: the phone, 2026-11-12, 2035200 kept); -1 releases it. First in the file: released first,
    # put back last.
    for n in cpufreq_max_limit cpufreq_min_limit; do
        v=$(cat "$T/sys/devices/system/cpu/cpufreq_limit/$n" 2>/dev/null)
        case "${v#-}" in ''|*[!0-9]*) ;; *) echo "/sys/devices/system/cpu/cpufreq_limit/$n $v -1" >> "$out" ;; esac
    done
    for pol in "$T"/sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "$pol" ] || continue
        lo=$(cat "$pol/cpuinfo_min_freq" 2>/dev/null); hi=$(cat "$pol/cpuinfo_max_freq" 2>/dev/null)
        mn=$(cat "$pol/scaling_min_freq" 2>/dev/null); mx=$(cat "$pol/scaling_max_freq" 2>/dev/null)
        case "$lo$hi$mn$mx" in ''|*[!0-9]*) continue ;; esac
        echo "${pol#"$T"}/scaling_min_freq $mn $lo" >> "$out"
        echo "${pol#"$T"}/scaling_max_freq $mx $hi" >> "$out"
    done
    g="$T/sys/kernel/gpu"
    v=$(cat "$g/gpu_max_clock" 2>/dev/null); top=$(clock_top < "$g/gpu_freq_table" 2>/dev/null)
    case "$v" in ''|*[!0-9]*) ;; *) [ -z "$top" ] || echo "/sys/kernel/gpu/gpu_max_clock $v $top" >> "$out" ;; esac
    k="$T/sys/class/kgsl/kgsl-3d0"
    v=$(cat "$k/max_gpuclk" 2>/dev/null); top=$(clock_top < "$k/gpu_available_frequencies" 2>/dev/null)
    case "$v" in ''|*[!0-9]*) ;; *) [ -z "$top" ] || echo "/sys/class/kgsl/kgsl-3d0/max_gpuclk $v $top" >> "$out" ;; esac
    pl=""
    [ ! -e "$k/thermal_pwrlevel" ] || pl="; KGSL thermal_pwrlevel $(cat "$k/thermal_pwrlevel" 2>/dev/null)"
    echo "Clocks of One UI: $(awk '{ printf "%s %s, ", $1, $2 }' "$out" | sed 's/, $//')$pl"
}
clocks_tops() {
    # The mark first: from here the return writes One UI's values back.
    echo "$(date +%s)" > "$CTL/clocks.set"
    while read -r node old new; do
        case "$node" in /sys/devices/system/cpu/cpufreq/policy*/scaling_m??_freq|/sys/kernel/gpu/gpu_max_clock|/sys/class/kgsl/kgsl-3d0/max_gpuclk) ;;
            /sys/devices/system/cpu/cpufreq_limit/cpufreq_max_limit|/sys/devices/system/cpu/cpufreq_limit/cpufreq_min_limit) ;; *) continue ;; esac
        case "${old#-}${new#-}" in ''|*[!0-9]*) continue ;; esac
        if echo "$new" > "$T$node" 2>/dev/null; then
            echo "clocks: $node $old -> $new (reads $(cat "$T$node" 2>/dev/null))"
        else
            echo "clocks: $node $old -> $new not written (left at $(cat "$T$node" 2>/dev/null))"
        fi
    done < "$CTL/base/clocks"
    l="$T/sys/devices/system/cpu/cpufreq_limit/limit_stat"
    [ ! -e "$l" ] || echo "clocks: cpufreq_limit limit_stat: $(awk '{ printf "%s ", $0 }' "$l" 2>/dev/null | cut -c1-300)"
    k="$T/sys/class/kgsl/kgsl-3d0"
    [ ! -e "$k/thermal_pwrlevel" ] || echo "clocks: KGSL thermal_pwrlevel $(cat "$k/thermal_pwrlevel" 2>/dev/null), max_gpuclk $(cat "$k/max_gpuclk" 2>/dev/null)"
}

# --- USB AND ADB DURING A SESSION ---------------------------------------------
# (docs/oneios.md, "USB and adb during a session"; OneiOS's oneos/interface.md.)
# One UI's framework is what sets the USB gadget's functions: UsbDeviceManager in
# system_server, through the USB gadget HAL or init's sys.usb.config triggers, on
# every plug-in and unplug. The switch stops system_server, so for the whole
# session nobody re-arms the gadget: whatever unbinds it, or drops adb from it,
# stays (the S24 Ultra, 2026-11-13: a cable plugged in during the session, and
# the Mac saw no USB device at all). usb_save records it while One UI is whole
# (control/base/usb); the session's USB watcher (--usb-watch) keeps adb on it,
# with One UI's own values only; the return puts back what differs.
# Only named files and properties: sys.usb.controller names the UDC, and
# /sys/class/udc is never listed. Nothing is written but sys.usb.config (One
# UI's value), ctl.start adbd and the gadget's UDC file (One UI's controller).
UDC_FILE="$T/config/usb_gadget/g1/UDC"
usb_read() { head -c 64 "$1" 2>/dev/null | tr -d '\n'; }      # one named file, one line
usb_name() { # a controller name that is one path component, else nothing
    case "$1" in ''|.|..|*/*|*[!A-Za-z0-9._:-]*) echo "" ;; *) echo "$1" ;; esac
}
usb_has_adb() { case ",$1," in *,adb,*) return 0 ;; esac; return 1; }
usb_now() { # the gadget as it is now, on one line
    _uc=$(usb_name "$(getprop sys.usb.controller)")
    _us=""; [ -z "$_uc" ] || _us=$(usb_read "$T/sys/class/udc/$_uc/state")
    echo "state $(getprop sys.usb.state), config $(getprop sys.usb.config), UDC ${_uc:-?} ${_us:-?}; bound '$(usb_read "$UDC_FILE")', adbd $(getprop init.svc.adbd), ffs.ready $(getprop sys.usb.ffs.ready), cable $(usb_read "$T/sys/class/power_supply/usb/online")"
}
usb_save() {
    _cfg=$(getprop sys.usb.config)
    _adb=0
    usb_has_adb "$_cfg" && _adb=1
    usb_has_adb "$(getprop persist.sys.usb.config)" && _adb=1
    [ "$(settings get global adb_enabled 2>/dev/null)" = 1 ] && _adb=1
    {
        echo "adb=$_adb"
        echo "config=$_cfg"
        echo "state=$(getprop sys.usb.state)"
        echo "persist=$(getprop persist.sys.usb.config)"
        echo "controller=$(usb_name "$(getprop sys.usb.controller)")"
        echo "udc=$(usb_read "$UDC_FILE")"
        echo "adbd=$(getprop init.svc.adbd)"
        echo "configfs=$(getprop sys.usb.configfs)"
        # The repairs of the USB watcher and the return: only with $STAGE/usb-repair (or ONEIOS_USB_REPAIR=1)
        _rep=0; { [ -e "$STAGE/usb-repair" ] || [ "${ONEIOS_USB_REPAIR:-0}" = 1 ]; } && _rep=1
        echo "repair=$_rep"
    } > "$CTL/base/usb"
    echo "USB of One UI: $(usb_now); USB debugging $([ $_adb = 1 ] && echo on || echo off)"
}

# --- INTERNAL MODES --------------------------------------------------------
case "$MODE" in
    --watchdog-probe)
        watchdog_target || refuse "watchdog recovery could not identify One UI's active software watchdog"
        exit 0 ;;
    --watchdog-health)
        WD_GEN=$(watchdog_generation)
        watchdog_health
        exit $? ;;
    --watchdog-supervise)
        WD_GEN=$2
        [ -n "$WD_GEN" ] || exit 1
        watchdog_lost
        exit $? ;;
    --watchdog-test)
        [ -n "$T" ] && [ "$2" = feed ] || exit 3
        watchdog_feed
        exit $? ;;
    --key-devices)
        [ -n "$T" ] || { echo "$MODE: for the tests only"; exit 2; }
        volume_key_devices || refuse "could not validate physical volume keys in getevent (gpio-keys Volume Up, pmic_resin Volume Down)"
        exit 0 ;;
    --clocks-save|--clocks-tops)
        # The tests' way in (OneiosScriptTest, against a fake sysfs): the same two steps the session takes.
        [ -n "$T" ] || { echo "$MODE: for the tests only"; exit 2; }
        mkdir -p "$CTL/base"
        if [ "$MODE" = --clocks-save ]; then clocks_save; else clocks_tops; fi
        exit 0 ;;
    --usb-save)
        # The tests' way in (against a fake phone): the step the session takes at its baseline.
        [ -n "$T" ] || { echo "$MODE: for the tests only"; exit 2; }
        mkdir -p "$CTL/base"
        usb_save
        exit 0 ;;
    --usb-watch)
        # The session's USB watcher, started once One UI's framework is stopped
        # (above, "USB AND ADB DURING A SESSION"); its lines go to control/usb.log.
        # Every 3 s it reads the gadget and logs it when it changed; at most one
        # repair every 21 s, in this order: adbd not running (ctl.start adbd); adb
        # gone from sys.usb.config (One UI's value again); the UDC file empty while
        # One UI had it bound (One UI's controller written); a cable in for 15 s
        # with the UDC still "not attached", "attached" or "powered" (sys.usb.config
        # none, then One UI's: init or the HAL binds it again; twice per plug-in at
        # most, so a charger that never enumerates is left alone). Not with USB
        # debugging off at the switch. Ends on control/usb-watch.off, or when the
        # session is over. Not the way back: nothing of the return waits for it.
        echo $$ > "$CTL/usb-watch.pid"
        U="$CTL/base/usb"
        usay() { echo "$(date '+%F %T') usb: $*"; }
        [ "$(conf "$U" adb)" = 1 ] || { usay "One UI had USB debugging off at the switch (or no $U): nothing to keep"; exit 0; }
        CFG=$(conf "$U" config)
        usb_has_adb "$CFG" || CFG=$(conf "$U" persist)
        usb_has_adb "$CFG" || CFG=adb
        CTRL=$(usb_name "$(conf "$U" controller)")
        BOUND=$(conf "$U" udc)
        [ "$BOUND" != none ] || BOUND=""
        EVERY=3
        # Repairs only where the stage asks for them (usb-repair, recorded at the switch as repair=1): not run on the
        # phone yet, so off by default; off, every repair is logged and nothing is written.
        REPAIR=$(conf "$U" repair)
        OFF=""; [ "$REPAIR" = 1 ] || OFF=" (repairs are off: logged only; $STAGE/usb-repair turns them on)"
        act() { [ "$REPAIR" = 1 ] || return 0; "$@"; }
        udc_put() { [ "$REPAIR" = 1 ] || return 0; echo "$1" 2>/dev/null > "$UDC_FILE"; }
        usay "watching every ${EVERY} s: keeps config $CFG, adbd and UDC ${CTRL:-?} (bound '${BOUND}' at the switch), repairs $([ "$REPAIR" = 1 ] && echo on || echo off)"
        last=""; n=0; fix=-100; plug=0; tries=0; cable0=""
        while [ ! -e "$CTL/usb-watch.off" ]; do
            case "$(cat "$CTL/state" 2>/dev/null)" in returning|returned|failed) usay "the session is over: the watcher ends"; exit 0 ;; esac
            now=$(usb_now)
            [ "$now" = "$last" ] || { usay "$now"; last=$now; }
            cable=$(usb_read "$T/sys/class/power_supply/usb/online")
            if [ "$cable" = 1 ] && [ "$cable0" != 1 ]; then plug=$n; tries=0; fi
            cable0=$cable
            if [ $((n - fix)) -ge 7 ]; then
                cfg=$(getprop sys.usb.config)
                b=$(usb_read "$UDC_FILE"); [ "$b" != none ] || b=""
                if [ "$(getprop init.svc.adbd)" != running ]; then
                    usay "adbd is '$(getprop init.svc.adbd)': ctl.start adbd$OFF"
                    act setprop ctl.start adbd; fix=$n
                elif ! usb_has_adb "$cfg"; then
                    usay "adb is gone from the gadget (config '$cfg'): sys.usb.config $CFG again$OFF"
                    act setprop sys.usb.config "$CFG"; fix=$n
                elif [ -n "$CTRL" ] && [ -n "$BOUND" ] && [ -z "$b" ]; then
                    if udc_put "$CTRL"; then usay "the gadget was unbound: UDC $CTRL written$OFF"
                    else usay "the gadget was unbound: UDC $CTRL could not be written (adbd's endpoints not ready yet?)"; fi
                    fix=$n
                elif [ "$cable" = 1 ] && [ -n "$CTRL" ] && [ $tries -lt 2 ] && [ $((n - plug)) -ge 5 ]; then
                    st=$(usb_read "$T/sys/class/udc/$CTRL/state")
                    case "$st" in
                        "not attached"|attached|powered)
                            tries=$((tries + 1)); fix=$n
                            usay "a cable is in for $(((n - plug) * EVERY)) s and UDC $CTRL is '$st': re-armed (sys.usb.config none, then $CFG; $tries of 2 for this plug-in)$OFF"
                            act setprop sys.usb.config none
                            sleep 1
                            act setprop sys.usb.config "$CFG"
                            sleep 2
                            b=$(usb_read "$UDC_FILE"); [ "$b" != none ] || b=""
                            if [ -n "$BOUND" ] && [ -z "$b" ]; then
                                if udc_put "$CTRL"; then usay "UDC $CTRL written after the re-arm$OFF"
                                else usay "UDC $CTRL could not be written after the re-arm"; fi
                            fi ;;
                    esac
                fi
            fi
            sleep $EVERY; n=$((n + 1))
        done
        usay "ended (control/usb-watch.off)"
        exit 0 ;;
    --framework-audit|--framework-audit-reboot)
        [ -z "$T" ] && [ "$FRAMEWORK" = 1 ] && [ "$(id -u)" = 0 ] || exit 3
        framework_probe
        exit $? ;;
    --framework-test-stop)
        [ -n "$T" ] && [ "$FRAMEWORK" = 1 ] || exit 3
        stop_android_framework
        exit $? ;;
    --framework-deadline)
        framework_deadline "$2"
        exit $? ;;
    --framework-return)
        [ "$FRAMEWORK" = 1 ] && [ -z "$T" ] && [ "$(id -u)" = 0 ] || exit 3
        [ "$(cat "$CTL/boot" 2>/dev/null)" = "$(boot_id)" ] || exit 0
        case "$(cat "$CTL/state" 2>/dev/null)" in
            starting|running) publish_return_request "operator requested return"
                exec $SH "$SELF_RETURN" framework-deadline "$(watchdog_generation)" ;;
            returning|returned) exit 0 ;;
            *) exit 3 ;;
        esac ;;
    --inner)
        # Inside the new mount namespace (unshare -m), still root. The stage
        # becomes /data: nothing else of One UI's /data exists in here.
        [ -z "$T" ] || exit 3
        # Every step says so in xnuhost's log before it is taken, and however
        # this shell ends before xnuhost starts, its last line says with what
        # status and in which step. (The S24 Ultra, 2026-11-11, 0.4.77 to
        # 0.4.80: it ended here without a word, in the check that control/ is
        # read-only. That check wrote with ":", a special builtin, and
        # Android's sh ends the script when a special builtin's redirection
        # fails; with 2>/dev/null before it, silently. The check succeeded,
        # and that was the end. Never ":" with a redirection: "true".)
        AT="start"
        at() { AT=$*; echo "oneios inner: $(date +%T) $*"; }
        trap 'echo "oneios inner: $(date +%T) ended with status $? in step: $AT"' EXIT
        die_inner() { echo "oneios inner: $*"; exit 70; }
        if [ "$FRAMEWORK" = 1 ] && [ "$(cat "$CTL/framework.cpu-budget" 2>/dev/null)" = hybrid-v1-180s ]; then
            at "joining isolated guest CPU bandwidth group before publishing PID"
            framework_thermal_cap_healthy || die_inner "CPU budget heartbeat not healthy"
            guest_cpu_group=$(framework_cpu_budget_group "$CTL") || die_inner "CPU bandwidth group identity invalid"
            printf '%s\n' "$$" > "$guest_cpu_group/cgroup.procs" || die_inner "cannot join guest CPU group"
            awk -F: -v expected="/${guest_cpu_group##*/}" '$2=="cpu" && $3==expected {ok=1} END {exit !ok}' /proc/$$/cgroup ||
                die_inner "guest CPU group membership not verified"
            echo "ONEIOS_CPU_BUDGET_GROUP=$guest_cpu_group MEMBERSHIP=VERIFIED"
        fi
        echo $$ 2>/dev/null > "$CTL/inner.pid"
        at "pid $$, mount namespace $(readlink /proc/$$/ns/mnt 2>/dev/null)"
        R_XNUHOST=$(conf "$STAGE/runtime.conf" xnuhost)
        [ -n "$BB" ] && [ -x "$BB" ] || die_inner "no busybox"
        [ "$(readlink /proc/$$/ns/mnt)" != "$(readlink /proc/1/ns/mnt)" ] || die_inner "still in init's mount namespace"
        # The root manager's busybox is in One UI's /data (/data/adb), which the bind below hides: the rest of
        # this namespace's setup runs a copy in the way back's control folder (root's, read-only in here), as
        # OneOS's guest_prepare.sh copies busybox into the guest's /data. It keeps the name busybox (a
        # multi-call busybox goes by its name).
        at "copying busybox to $CTL/busybox"
        cp "$BB" "$CTL/busybox" && chmod 0700 "$CTL/busybox" || die_inner "could not copy $BB to $CTL/busybox"
        at "making the mounts private"
        "$BB" mount --make-rprivate / || die_inner "could not make the mounts private"
        at "binding the stage over /data"
        "$BB" mount --bind "$STAGE" /data || die_inner "could not bind the stage over /data"
        BB=/data/control/busybox
        at "running busybox from the stage"
        "$BB" true 2>/dev/null || die_inner "busybox does not run from the stage ($BB)"
        # Android BusyBox can remount bind-mounted DIRECTORIES read-only,
        # but not self-bind-mounted FILES: mount -o remount,bind,ro on
        # /data/oneios_switch.sh failed with "can't find ... in /proc/mounts"
        # on real SM-S948B, before xnuhost could be exec'd (2026-11-20).
        #
        # Make the entire stage root read-only instead, which also protects
        # both shell scripts, runtime.conf, image.conf and all trust sidecars.
        # Separate writable Data/session bind mounts FIRST: their per-mount
        # flags remain writable after the parent /data bind is remounted ro.
        # Android's original /data stays untouched in init's namespace.
        at "preparing writable Data and session islands"
        [ -d /data/data ] && [ -d /data/session/tmp ] ||
            die_inner "staged Data/session writable islands are missing"
        for d in data session; do
            "$BB" mount --bind "/data/$d" "/data/$d" ||
                die_inner "could not isolate writable /data/$d mount"
        done
        # BusyBox mount with only a TARGET does an /proc/mounts lookup,
        # which failed even for a fresh directory bind on the S26 Ultra.
        # Explicit SOURCE+TARGET bypasses that lookup; the on-device
        # preflight uses the same two-operand syntax before any Framework stop.
        at "making entire staged /data read-only"
        "$BB" mount -o remount,bind,ro /data /data ||
            die_inner "could not remount staged /data read-only"
        # Actual negative write probes, not access(2)/test -w: host root
        # could otherwise appear writable even on a protected mount.
        at "checking staged root and control are read-only"
        if true 2>/dev/null > /data/.oneios-stage-write-check; then
            rm -f /data/.oneios-stage-write-check
            die_inner "the staged /data root is writable in the session namespace"
        fi
        at "checking that /data/control is read-only"
        if true 2>/dev/null > /data/control/.w; then
            rm -f /data/control/.w
            die_inner "the way back's control folder is writable in the session's namespace"
        fi
        # Fail BEFORE reporting a guest PID if remounting the parent also
        # accidentally made the two intended write areas read-only.
        at "checking writable guest Data/session islands"
        for check in /data/data /data/session/tmp; do
            probe="$check/.oneios-write-check.$$"
            if ! (set -C; true 2>/dev/null > "$probe"); then
                die_inner "guest writable island is read-only: $check"
            fi
            rm -f "$probe" || die_inner "could not remove guest write probe: $check"
        done
        # The guard this session rests on: One UI's data is not reachable here.
        at "checking that One UI's /data is not visible"
        [ ! -e /data/system ] && [ ! -e /data/misc ] && [ ! -e /data/user ] && [ -f /data/runtime.conf ] ||
            die_inner "One UI's /data is still visible in the session's namespace"
        cd /data || die_inner "cd /data"
        at "session folders and the pid"
        mkdir -p /data/data /data/session/tmp && chmod 0700 /data/data /data/session/tmp || die_inner "could not make /data/data"
        echo $$ > /data/session/xnuhost.pid || die_inner "could not write the pid"
        # A cgroup of its own for xnuhost and everything it starts (cgroup v2,
        # no controller needed): the watcher, the key readers and the return
        # are in the root group, never in the guest's, and the return ends the
        # whole group at once (cgroup.kill) wherever a task of it went. Without
        # cgroup v2 (its root has cgroup.controllers) the return has the mount
        # namespace alone, as before.
        at "the session's cgroup"
        CG=/sys/fs/cgroup/oneios_session
        if [ -f /sys/fs/cgroup/cgroup.controllers ] && mkdir -p "$CG" 2>/dev/null && echo $$ > "$CG/cgroup.procs" 2>/dev/null; then
            echo "oneios inner: cgroup $CG"
        else
            echo "oneios inner: no cgroup of its own ($CG); the return ends the session by its mount namespace"
        fi
        # Every core for the guest's vCPUs. Android's v1 cpusets (/dev/cpuset) still
        # apply under the v2 group above: this shell kept the cpuset of the root
        # shell the app started (top-app while the app was in front, background
        # once it was not), and background and system-background allow the
        # A520s only, where xnuhost's cpu-pin cannot put a vCPU on the X4 or an
        # A720 (sched_setaffinity is limited to the cpuset). The cpuset's root has
        # every core, as for the watcher and the key readers (out_of_the_way).
        # xnuhost logs the cpuset it runs in ("cpu: xnuhost's cpuset ...").
        if [ -w /dev/cpuset/cgroup.procs ] && echo $$ > /dev/cpuset/cgroup.procs 2>/dev/null; then
            echo "oneios inner: cpuset / (cpus $(cat /dev/cpuset/cpus 2>/dev/null))"
        else
            echo "oneios inner: cpuset kept: $(cat /proc/$$/cpuset 2>/dev/null) (cpus $(grep Cpus_allowed_list /proc/$$/status 2>/dev/null | awk '{print $2}'))"
        fi
        # The switch is exempt from the OOM killer (-1000) and xnuhost would
        # inherit that: with memory gone the kernel would then end One UI's
        # daemons, or panic. The guest is what goes first; its end is a return.
        echo 500 > /proc/$$/oom_score_adj 2>/dev/null
        export ONEIOS_SESSION_ABI=$ABI ONEIOS_MODE=takeover ONEIOS_RUNTIME=/data/runtime ONEIOS_IMAGE=/data/image \
               ONEIOS_DATA=/data/data ONEIOS_SESSION=/data/session TMPDIR=/data/session/tmp
        unset BB ONEIOS_APP ONEIOS_TEST_ROOT
        # A switch that gave up on this shell meanwhile is returning to One
        # UI: nothing starts under it. "running" is not giving up: the outer
        # switch writes it as soon as it reads the pid this shell wrote above,
        # which can be before this line (a race the phone hit on 2026-11-11).
        ST=$(cat /data/control/state 2>/dev/null)
        case "$ST" in
            starting|running) ;;
            *) die_inner "the switch is no longer starting (state '$ST'): xnuhost is not started" ;;
        esac
        AT="exec of /data/runtime/$R_XNUHOST"
        echo "oneios inner: $(date '+%F %T') starting /data/runtime/$R_XNUHOST (pid $$)"
        if [ "$FRAMEWORK" = 1 ]; then
            [ "$(cat /data/control/framework.mode)" = run ] || die_inner "no full-session admission"
            # S26 Ultra has 8 online CPUs. A kernel cpuset may restrict our
            # thread affinity even if xnuhost creates eight vCPU threads.
            # Do not claim full-core execution unless the guest's *inherited*
            # CPU mask actually includes CPUs 0-7. No governor or cpufreq writes.
            host_online=$(cat /sys/devices/system/cpu/online 2>/dev/null)
            # The awk child inherits this shell's cpuset and affinity. Reading
            # /proc/self/status avoids PID expansion issues in Android mksh.
            host_allowed=$(awk '/^Cpus_allowed_list:/ {print $2}' /proc/self/status)
            [ "$host_online" = 0-7 ] && [ "$host_allowed" = 0-7 ] ||
                die_inner "all 8 SM8850 host cores not accessible (online=$host_online allowed=$host_allowed)"
            echo "ONEIOS_TAKEOVER_CPU=8 host_online=$host_online host_allowed=$host_allowed"
            # Presence in the allowed mask is not per-vCPU affinity proof.
            # Explicit, admitted SM8850 full-bridges profile: the guest uses
            # the real CPU topology/cpufreq virtio MMIO, brightness/TSP,
            # battery and thermal bridge, not the former affinity-only bench.
            # Radio, haptics and encoder remain separately disabled on this
            # first integration. The root thermal guard/cap NEVER relax.
            if [ "$(cat /data/control/framework.soft-thermal 2>/dev/null)" = disabled-180s ]; then
                echo "ONEIOS_BENCH_THERMAL_BRIDGE=ACTIVE_WITH_NO_ROOT_THERMAL_MONITOR"
            else
                echo "ONEIOS_BENCH_THERMAL_BRIDGE=ACTIVE_READ_ONLY_ROOT_GUARD_SEPARATE"
            fi
            echo "ONEIOS_CPU_PLACEMENT_BRIDGE=ACTIVE_BRIDGES_1_CPU_PIN_1"
            echo "ONEIOS_GPU_3D=RUNTIME_KGSL_PROOF_REQUIRED"
            echo "ONEIOS_GPU_3D_MODE=REQUIRED_FAIL_CLOSED_NO_2D_FALLBACK"
            # Root-owned, session-local control metadata survives detach and
            # namespace creation. Never inherit a previous session's choice.
            # BEGIN FRAMEWORK_PERF_RUNTIME_ARGS
            perf_profile=$(cat /data/control/framework.perf-profile 2>/dev/null) ||
                die_inner "missing full-session performance profile"
            case "$perf_profile" in
                off) set -- ;;
                frame) set -- --set frame-trace=1 ;;
                task) set -- --set perf-task=1 ;;
                frame-task) set -- --set frame-trace=1 --set perf-task=1 ;;
                *) die_inner "invalid full-session performance profile" ;;
            esac
            if [ "$perf_profile" != off ]; then
                unset ONEIOS_GPU_TRACE
                echo "ONEIOS_PERF_VERBOSE_GPU_TRACE=OFF"
            fi
            echo "ONEIOS_PERF_PROFILE=$perf_profile"
            # END FRAMEWORK_PERF_RUNTIME_ARGS
            cpu_profile=$(cat /data/control/framework.cpu-profile 2>/dev/null) ||
                die_inner "missing full-session CPU profile"
            case "$cpu_profile" in
                default) ;;
                prime-first) set -- "$@" --set sm8850-prime-first=1 ;;
                *) die_inner "invalid full-session CPU profile" ;;
            esac
            echo "ONEIOS_CPU_PROFILE_REQUESTED=$cpu_profile"
            own_presence=$(cat /data/control/framework.own-presence 2>/dev/null) ||
                die_inner "missing full-session own-presence profile"
            own_boot_arg=
            case "$own_presence" in
                0) ;;
                1) own_boot_arg=' oneios-own-presence=1' ;;
                *) die_inner "invalid full-session own-presence profile" ;;
            esac
            echo "ONEIOS_OWN_PRESENCE_REQUESTED=$own_presence"
            interaction_profile=$(cat /data/control/framework.interaction-profile 2>/dev/null) ||
                die_inner "missing full-session interaction profile"
            case "$interaction_profile" in
                off) ;;
                swipe-60s) set -- "$@" --input-script @sm8850-swipe-60s ;;
                *) die_inner "invalid full-session interaction profile" ;;
            esac
            echo "ONEIOS_INTERACTION_PROFILE=$interaction_profile"
            ulimit -c 0
            exec "/data/runtime/$R_XNUHOST" --session-abi 1 --mode bench \
                --runtime /data/runtime --image /data/image --data /data/data --session /data/session \
                --cpus 8 --ram 4G --set ram-giveback=0 --set ram-prefault=1 --set ram-lock=1 \
                --set ram-huge=0 --set host-mem-log=5 --set bridges=1 --set sm8850-full-bridges=1 --set touch-sleep=0 --set cpu-affinity-bench=0 --set cpu-pin=1 --set wifi=off \
                --set bluetooth=virtual --set haptics=off --set encoder=off --set return-graceful-ms=0 \
                --gpu 3d --display shm --set touch-exclusive=1 --width 1080 --height 2340 --hz 60 "$@" \
                --boot-args 'debug=0x14e serial=3 -v kt_fixed_zones=120 -no_slto_panic ml-timeout-lock-panic-scale=40 tlto_us=0 armcpu-self-ipi=1 armcpu-spi-ipi=1 use_contiguous_hint=0 interrupt-masked-debug-mode=0 sched_preemption_disable_debug_mode=0 wdt=-1 sheng-smp=1 oneios-data-wait=3000'"$own_boot_arg"
            die_inner "could not exec the GPU-3D benchmark runtime"
        fi
        exec "/data/runtime/$R_XNUHOST" --session-abi $ABI --mode takeover \
            --runtime /data/runtime --image /data/image --data /data/data --session /data/session
        echo "oneios inner: could not exec xnuhost"
        exit 71
        ;;
    --stop-loop)
        # One UI's zygote must stay stopped: other services restart it
        # (onrestart), and a zygote that starts would bring system_server back
        # next to the guest. oneios_return.sh ends this loop before it starts
        # One UI ($CTL/stop-loop.off, then the pid).
        [ -z "$T" ] || exit 3
        if [ "$FRAMEWORK" = 1 ]; then
            [ "$(id -u)" = 0 ] && [ "$(boot_id)" = "$(cat "$CTL/boot" 2>/dev/null)" ] &&
                [ -s "$CTL/stopped" ] && framework_recovery_ready || exit 3
            printf '%s %s\n' "$$" "$(watchdog_birth $$)" > "$CTL/framework.stoploop" || exit 3
        fi
        # SM8850 retains host SurfaceFlinger and the display composer.
        # Samsung's bootanim can restart after system_server goes away.
        # Stop only that init-managed service, never the compositor or HAL.
        # Check immediately, then every five 200ms ticks (as upstream
        # OneOS does for bootanim); preserve the zygote polling cadence.
        bootanim_tick=0
        while [ ! -e "$CTL/stop-loop.off" ]; do
            [ "$(getprop init.svc.zygote)" = running ] && setprop ctl.stop zygote
            [ "$(getprop init.svc.zygote_secondary)" = running ] && setprop ctl.stop zygote_secondary
            if [ "$FRAMEWORK" = 1 ]; then
                [ "$(getprop init.svc.zygote_next)" = running ] && setprop ctl.stop zygote_next
                if [ "$bootanim_tick" = 0 ] && [ ! -e "$SESSION/return.request" ]; then
                    case "$(getprop init.svc.bootanim)" in
                        running|restarting)
                            # Return already waits for this loop to leave
                            # before restoring its own boot animation.
                            if [ ! -e "$CTL/stop-loop.off" ] && [ ! -e "$SESSION/return.request" ]; then
                                setprop ctl.stop bootanim
                            fi ;;
                    esac
                fi
                bootanim_tick=$(( (bootanim_tick + 1) % 5 ))
            else
                [ "$(getprop init.svc.bootanim)" = running ] && setprop ctl.stop bootanim
            fi
            sleep 0.2
        done
        exit 0
        ;;
    --feed)
        [ -z "$T" ] && [ "$(id -u 2>/dev/null)" = 0 ] || exit 3
        watchdog_feed
        exit $?
        ;;
    --bootui)
        # The boot screen's status line (bootui_begin starts this beside the
        # renderer): once a second, the furthest boot stage in what xnuhost's
        # log gained, a kernel panic, or why xnuhost ended. It hands the screen
        # to the display helper when the guest's picture is up (display_up)
        # and leaves when a return begins: the return ends the screen. It
        # reads the log and control/, and writes only $BOOTUI.
        gen=$(cat "$BOOTUI/generation" 2>/dev/null)
        [ -n "$gen" ] || exit 0
        echo $$ > "$BOOTUI/feeder.pid"
        live() { [ "$(cat "$BOOTUI/generation" 2>/dev/null)" = "$gen" ] && [ ! -e "$BOOTUI/stop" ]; }
        show() {
            [ "$1" = "$shown" ] && return 0
            shown=$1
            screen status "$1"
            echo "$(date '+%F %T') boot screen: $(plain "$1")"
        }
        off=0 st=0 shown="" panic="" t=0 drawn=0 native=0
        while live; do
            state=$(cat "$CTL/state" 2>/dev/null)
            case "$state" in starting|running) ;; *) break ;; esac
            if display_up; then
                echo "$(date '+%F %T') boot screen: the guest's picture is on the display helper's layer; the boot screen ends"
                bootui oneos_boot_stop
                break
            fi
            # The display helper, once it connects in a takeover, sets the
            # display's projection to the panel's own mode and leaves it so
            # (One UI's resolution setting may be smaller). The boot screen
            # then draws for that size: the renderer reads this file.
            if [ $native = 0 ] && grep -q 'oneios-display: display projection set to the active mode' "$CTL/display.log" 2>/dev/null; then
                native=1
                bootui oneos_boot_write native 1
                echo "$(date '+%F %T') boot screen: the display helper set the projection to the panel's mode; drawing at that size"
            fi
            # A renderer that never posted a frame is not retried for the whole session.
            [ -s "$BOOTUI/ready" ] && drawn=1
            if [ $drawn = 0 ] && [ $t -ge 30 ]; then
                echo "$(date '+%F %T') boot screen: the renderer posted no frame in 30 s (log $BOOTUI/renderer.log); the boot screen ends"
                bootui oneos_boot_stop
                break
            fi
            # What the log gained since the last look, with 511 bytes before it
            # (a marker cut in two by the last read; a stage is only ever raised).
            size=$(stat -c %s "$SESSION/xnuhost.log" 2>/dev/null)
            set -- $(awk -v s="${size:-0}" -v o="$off" 'BEGIN {
                s += 0; o += 0; if (s < o) o = 0
                if (s == o) { print "-", o; exit }
                f = (o > 511) ? o - 510 : 1
                e = (s - f + 1 > 1048576) ? f + 1048575 : s
                print f, e }')
            if [ "$1" != - ]; then
                out=$(log_scan "$1" "$st")
                off=$2
                n=$(printf '%s\n' "$out" | sed -n 's/^S //p' | head -n 1)
                case "$n" in ''|*[!0-9]*) ;; *) st=$n ;; esac
                printf '%s\n' "$out" | grep -q -x B && panic=""
                found=$(printf '%s\n' "$out" | sed -n 's/^P //p' | head -n 1)
                [ -z "$found" ] || panic=$found
            else
                off=$2
            fi
            gone=0
            if [ "$state" = running ]; then
                xp=$(cat "$CTL/xnuhost.pid" 2>/dev/null)
                [ -n "$xp" ] && [ "$(readlink "$P/$xp/ns/mnt" 2>/dev/null)" = "$(cat "$CTL/mntns" 2>/dev/null)" ] || gone=1
            fi
            if [ $gone = 1 ]; then show "$(why_ended)"
            elif [ -n "$panic" ]; then show "Kernel panic: $panic"
            elif [ "$st" -gt 0 ]; then show "$(stage_text "$st")"
            fi
            sleep 1; t=$((t + 1))
        done
        exit 0
        ;;
    --keys)
        # Volume Up + Volume Down held 3 s, from one key device's events.
        # getevent only reads: it never grabs (EVIOCGRAB), so the guest still
        # gets the keys, and it is a One UI-side process the guest cannot
        # block. It only asks for the return (ask_return). A later session
        # (another token) ends this reader, with its getevent, on its next event.
        [ -n "$2" ] && [ -n "$3" ] || exit 3
        kd=$2 tok=$3
        case "$4" in
            up) k=up; key=KEY_VOLUMEUP ;;
            down) k=down; key=KEY_VOLUMEDOWN ;;
            *) exit 3 ;;
        esac
        KS="$CTL/keys"
        reader_start
        getevent -lq "$kd" 2>/dev/null | while read -r typ code val rest; do
            [ "$(cat "$KS/session" 2>/dev/null)" = "$tok" ] || reader_end
            [ "$typ" = EV_KEY ] && [ "$code" = "$key" ] || continue
            # DOWN and UP only (getevent -l's names, or the bare values). The
            # auto-repeat of a held key (REPEAT, on a device with EV_REP) is
            # not a release: taken as one, a hold would never reach 3 s.
            case "$val" in DOWN|00000001) v=DOWN ;; UP|00000000) v=UP ;; *) continue ;; esac
            echo "$v" > "$KS/$k"
            # Both down: a timer looks at the two keys every 0.25 s for 3 s.
            # The S24 Ultra's volume keys are one rocker, and pressing both of
            # its ends chatters: one end lifts for a moment and comes back
            # (session of 2026-11-12: 6 key events in 3 s, no 3 s without a
            # release). A release of 0.5 s or more ends the hold; a shorter one
            # does not. The timer reads only the two keys' files: there is no
            # shared token for the other reader to clear (two readers that both
            # see the chord start a timer each, and ask_return asks once).
            if [ "$v" = DOWN ] && [ "$(cat "$KS/up" 2>/dev/null)" = DOWN ] && [ "$(cat "$KS/down" 2>/dev/null)" = DOWN ]; then
                ( n=0 miss=0
                  while [ $n -lt 12 ] && [ $miss -lt 2 ]; do
                      sleep 0.25; n=$((n + 1))
                      if [ "$(cat "$KS/up" 2>/dev/null)" = DOWN ] && [ "$(cat "$KS/down" 2>/dev/null)" = DOWN ]; then miss=0; else miss=$((miss + 1)); fi
                  done
                  [ $miss -lt 2 ] && [ "$(cat "$KS/session" 2>/dev/null)" = "$tok" ] &&
                      ask_return "keys: Volume Up + Volume Down held 3 s" ) &
            fi
        done
        exit 0
        ;;
    --keys-poll)
        # The same chord without the event stream. "getevent -pl DEVICE" asks
        # the device for its keys' state (EVIOCGKEY) and marks a key that is
        # down with "*". A program that grabs a device (EVIOCGRAB) takes its
        # events from every other reader, the one above included, but not this
        # state: so the chord works even if xnuhost grabs the keys, which its
        # contract forbids (OneiOS docs/agents.md). Twice a second; seven
        # samples with both keys down are 3 s. One sample without them in
        # between does not end the hold (the rocker's chatter, see --keys); two
        # in a row do.
        [ -n "$2" ] && [ -n "$3" ] && [ -n "$4" ] || exit 3
        tok=$2 updev=$3 downdev=$4
        KS="$CTL/keys"
        reader_start
        TMO=""
        command -v timeout >/dev/null 2>&1 && TMO="timeout 2"
        n=0 miss=0
        while [ "$(cat "$KS/session" 2>/dev/null)" = "$tok" ]; do
            up=$($TMO getevent -pl "$updev" 2>/dev/null) || up=""
            down=$($TMO getevent -pl "$downdev" 2>/dev/null) || down=""
            held=0
            case "$up" in *"KEY_VOLUMEUP*"*) case "$down" in *"KEY_VOLUMEDOWN*"*) held=1 ;; esac ;; esac
            if [ $held = 1 ]; then n=$((n + 1)); miss=0
            elif [ $n -gt 0 ]; then miss=$((miss + 1)); [ $miss -lt 2 ] || { n=0; miss=0; }
            fi
            if [ $n -ge 7 ]; then
                n=0 miss=0
                [ "$(cat "$KS/session" 2>/dev/null)" = "$tok" ] || break
                ask_return "keys: Volume Up + Volume Down down for 3 s (polled)"
            fi
            sleep 0.5
        done
        exit 0
        ;;
    --watch)
        # The way back, armed before One UI's zygote stops. A One UI-side
        # process: init's mount namespace, its own session (setsid), the root
        # cgroup, never the OOM killer's, so nothing the guest does can stop
        # or freeze it. It returns to One UI when: the switch did not get as
        # far as starting xnuhost (60 s), xnuhost ended, a return was asked
        # ($SESSION/return.request: the volume keys, the guest, adb), or the
        # guest never said it is up ($SESSION/ready) within ONEIOS_RETURN_MAX
        # seconds of its start (600; 0 = no limit).
        WD_GEN=$(watchdog_generation)
        echo $$ > "$CTL/watcher.pid"
        out_of_the_way
        if [ "$FRAMEWORK" = 1 ]; then
            printf '%s %s\n' "$$" "$(watchdog_birth $$)" > "$CTL/framework.watcher" || exit 1
        fi
        MAX="${ONEIOS_RETURN_MAX:-600}"
        case "$MAX" in ''|*[!0-9]*) MAX=600 ;; esac
        awake() { echo oneios_session 2>/dev/null > "$T/sys/power/wake_lock"; }
        SCREEN=""
        go() {
            [ "$(watchdog_generation)" = "$WD_GEN" ] || exit 0
            echo "$(date '+%F %T') watcher: $*; returning to One UI"
            # The boot screen, while it is still up, says so (and why, in
            # $SCREEN) until the return ends it.
            screen title 'Returning to One UI'
            [ -z "$SCREEN" ] || screen status "$SCREEN"
            # The guest's picture goes first: nothing of the return waits for it.
            end_display
            # Not exec: a return script that cannot be run (gone, damaged) or
            # that ends with an error must still end in One UI, by the reboot.
            # A return that hangs is its own guard's to end (oneios_return.sh).
            $SH "$STAGE/oneios_return.sh" watcher "$WD_GEN"
            rc=$?
            [ $rc = 0 ] && exit 0
            [ "$(watchdog_generation)" = "$WD_GEN" ] || exit 0
            hard_reboot oneios-watcher-failsafe "oneios_return.sh ended with $rc in state '$(cat "$CTL/state" 2>/dev/null)'"
        }
        t=0
        while [ "$(cat "$CTL/state" 2>/dev/null)" = starting ]; do
            [ "$(watchdog_generation)" = "$WD_GEN" ] || exit 0
            watchdog_lost && SCREEN="The watchdog feeder failed" && go "watchdog feeder failed"
            [ -e "$SESSION/return.request" ] && SCREEN="A return to One UI was asked for" && go "return asked before xnuhost started ($(head -c 200 "$SESSION/return.request" 2>/dev/null))"
            [ $t -lt 60 ] || { SCREEN="iOS did not start within 60 s"; go "the switch did not start xnuhost within 60 s"; }
            sleep 1; t=$((t + 1))
        done
        case "$(cat "$CTL/state" 2>/dev/null)" in
            running) ;;
            # A return someone else started (the app, adb, the key readers): theirs.
            returning|returned) echo "$(date '+%F %T') watcher: a return is under way or done; nothing to do"; exit 0 ;;
            # (The switch wrote why on the boot screen.)
            *) go "the switch ended in state '$(cat "$CTL/state" 2>/dev/null)'" ;;
        esac
        pid=$(cat "$CTL/xnuhost.pid" 2>/dev/null)
        ns=$(cat "$CTL/mntns" 2>/dev/null)
        fw_mode=$(cat "$CTL/framework.mode" 2>/dev/null)
        t=0
        ready_at=-1
        while :; do
            # A return someone else started (the app, adb, the key readers) is
            # theirs, with its own guard. Any other state, an unreadable one
            # included, is still this session.
            case "$(cat "$CTL/state" 2>/dev/null)" in
                returning|returned) echo "$(date '+%F %T') watcher: a return is under way or done; nothing to do"; exit 0 ;;
            esac
            [ "$(watchdog_generation)" = "$WD_GEN" ] || exit 0
            watchdog_lost && SCREEN="The watchdog feeder failed" && go "watchdog feeder failed"
            [ -e "$SESSION/return.request" ] && SCREEN="A return to One UI was asked for" && go "return asked ($(head -c 200 "$SESSION/return.request" 2>/dev/null))"
            if [ "$FRAMEWORK" = 1 ]; then
                framework_recovery_ready && framework_pid_alive "$CTL/framework.stoploop" ||
                    go "a framework recovery helper exited"
                framework_down || go "Android Framework restarted unexpectedly"
                [ "$fw_mode" != smoke ] || { sleep 1; continue; }
                if [ $((t % 5)) = 0 ]; then
                    mem=$(awk '/^MemAvailable:/ {print $2}' "$P/meminfo")
                    swap=$(awk '/^SwapFree:/ {print $2}' "$P/meminfo")
                    disk=$(df -Pk "$STAGE" | awk 'NR==2 {print $4}')
                    [ "${mem:-0}" -ge 2097152 ] && [ "${swap:-0}" -ge 524288 ] &&
                        [ "${disk:-0}" -ge 26214400 ] || go "bench resource guard (RAM=$mem swap=$swap disk=$disk KiB)"
                    if grep -Eq "memory: the guest.s RAM is held: .*not (locked|prefaulted further)" "$SESSION/xnuhost.log"; then
                        go "benchmark guest RAM locking or prefaulting failed"
                    fi
                    if [ "$t" -ge 20 ]; then
                        grep -Fq 'locked (mlock: the host cannot swap it)' "$SESSION/xnuhost.log" ||
                            go "locked guest RAM was not confirmed"
                    fi
                    if [ "$t" -ge 35 ]; then
                        kill -0 "$(cat "$CTL/display.pid" 2>/dev/null)" 2>/dev/null || go "display helper exited"
                    fi
                fi
                if [ "$ready_at" = -1 ] && [ -e "$SESSION/ready" ] &&
                    grep -q 'first frame posted' "$CTL/display.log" 2>/dev/null; then ready_at=$t; fi
                [ "$ready_at" = -1 ] || framework_capture
            fi
            if ! { [ -n "$pid" ] && [ "$(readlink "$P/$pid/ns/mnt" 2>/dev/null)" = "$ns" ]; }; then
                SCREEN=$(why_ended)
                go "xnuhost $pid ended (last log lines: $(tail -n 3 "$SESSION/xnuhost.log" 2>/dev/null | tr '\n' '|' | cut -c1-300))"
            fi
            if [ "$MAX" -gt 0 ] && [ ! -e "$SESSION/ready" ] && [ $t -ge "$MAX" ]; then
                SCREEN="iOS did not come up within ${MAX} s"
                go "the guest did not report ready within ${MAX}s"
            fi
            # Nothing else keeps the phone awake with One UI's framework gone:
            # the session's wakelock again every 10 s, whoever released it.
            [ $((t % 10)) = 0 ] && awake
            sleep 1; t=$((t + 1))
        done
        ;;
    --framework-check|--framework-session) ;;
    session|--check) ;;
    *) echo "usage: oneios_switch.sh [--check]"; exit 3 ;;
esac

# --- PREFLIGHT ------------------------------------------------------------
# Every refusal comes before the first change to the phone, so a refused
# switch leaves One UI exactly as it was.
if [ -n "$T" ]; then
    stage_checks
    echo "TEST ROOT: stage checks passed (runtime $R_VERSION, xnuhost $R_XNUHOST, image $I_VERSION $I_BUILD format $I_FORMAT); nothing was started"
    exit 0
fi
[ "$(id -u 2>/dev/null)" = 0 ] || refuse "not running as root"
command -v sha256sum >/dev/null 2>&1 || refuse "no sha256sum"

# SM8850's One UI 9 recovery gates have not been validated. This is a
# fail-closed root permission boundary, separate from app-side diagnostics:
# even an experimental or not-this-phone acknowledgement cannot override it.
P_MODEL=$(getprop ro.product.model)
P_DEVICE=$(getprop ro.product.device)
P_SOC=$(getprop ro.soc.model)
if [ "$FRAMEWORK" = 1 ]; then
    case "$MODE:$2" in
        --framework-check:smoke|--framework-check:run|--framework-session:smoke|--framework-session:run|--framework-check:reboot-smoke|--framework-session:reboot-smoke) ;;
        *) framework_block "use the explicit SM8850 experimental Framework profile" ;;
    esac
    FW_MODE=$2
    [ "$FW_MODE" != reboot-smoke ] || FW_MODE=smoke
    # The operator withdrew the old hybrid/fixed-frequency and
    # thermal-emergency-return policy. Refuse BOTH read-only full-run
    # admission and live sessions before claiming Data or stopping Android.
    # Existing active-session recovery and separately requested smoke are
    # deliberately not changed. No environment/risk-token bypass.
    if [ "$FW_MODE" = run ]; then
        framework_block "SM8850_THERMAL_POLICY=BLOCKED_LEGACY_RETIRED; stock-managed thermal runner and non-reboot guest quiesce not integrated/qualified"
    fi
    # Bounded, operator-selected duration measured from Framework stop.
    FW_DURATION=600
    FW_SMOKE_SECONDS=20
    # Optional fixed 30-second headless CPU measurement window. Ordinary
    # reboot-smoke remains 20s; retain the initial cutoff, all guards and
    # full iOS profile. The duration is selected before stopping Framework.
    if [ "$2" = reboot-smoke ]; then
        if [ "$MODE" = --framework-check ]; then
            [ "$#" -le 3 ] || framework_block "unexpected reboot-smoke arguments"
            FW_SMOKE_SECONDS=${3:-20}
        else
            [ "$#" -le 5 ] || framework_block "unexpected reboot-smoke arguments"
            FW_SMOKE_SECONDS=${5:-20}
        fi
        case "$FW_SMOKE_SECONDS" in 20|30) ;; *) framework_block "reboot-smoke duration must be 20 or 30 seconds" ;; esac
        echo "SM8850_FRAMEWORK_SMOKE_SECONDS=$FW_SMOKE_SECONDS"
    fi
    FW_PERF_PROFILE=off
    FW_CPU_PROFILE=default
    FW_OWN_PRESENCE=0
    FW_INTERACTION_PROFILE=off
    if [ "$FW_MODE" = run ]; then
        # BEGIN FRAMEWORK_INTERACTION_ARGS
        # Consume a fixed final token before the older profile suffixes.
        interaction_arg=
        for interaction_arg in "$@"; do :; done
        if [ "$interaction_arg" = interaction-swipe-60s ]; then
            FW_INTERACTION_PROFILE=swipe-60s
            interaction_n=$#
            for interaction_item in "$@"; do
                shift
                interaction_n=$((interaction_n - 1))
                [ "$interaction_n" = 0 ] || set -- "$@" "$interaction_item"
            done
        fi
        # END FRAMEWORK_INTERACTION_ARGS
        # BEGIN FRAMEWORK_OWN_PRESENCE_ARGS
        # Strip only an explicit, final opt-in token; the rest is validated
        # by the existing CPU/perf/duration/thermal/risk argument parser.
        own_arg=
        for own_arg in "$@"; do :; done
        if [ "$own_arg" = own-presence-1 ]; then
            FW_OWN_PRESENCE=1
            own_n=$#
            for own_item in "$@"; do
                shift
                own_n=$((own_n - 1))
                [ "$own_n" = 0 ] || set -- "$@" "$own_item"
            done
        fi
        # END FRAMEWORK_OWN_PRESENCE_ARGS
        # CPU placement is independent of instrumentation and thermal choice.
        # BEGIN FRAMEWORK_CPU_PROFILE_ARGS
        cpu_arg=
        case "$MODE:$#" in
            --framework-check:4) cpu_arg=$4 ;;
            --framework-check:5) cpu_arg=$5 ;;
            --framework-check:6) cpu_arg=$6 ;;
            --framework-session:7) cpu_arg=$7 ;;
            --framework-session:8) cpu_arg=$8 ;;
            --framework-session:9) cpu_arg=$9 ;;
        esac
        if [ "$cpu_arg" = cpu-prime-first ]; then
            FW_CPU_PROFILE=prime-first
            case "$MODE:$#" in
                --framework-check:4) set -- "$1" "$2" "$3" ;;
                --framework-check:5) set -- "$1" "$2" "$3" "$4" ;;
                --framework-check:6) set -- "$1" "$2" "$3" "$4" "$5" ;;
                --framework-session:7) set -- "$1" "$2" "$3" "$4" "$5" "$6" ;;
                --framework-session:8) set -- "$1" "$2" "$3" "$4" "$5" "$6" "$7" ;;
                --framework-session:9) set -- "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" ;;
            esac
        fi
        # END FRAMEWORK_CPU_PROFILE_ARGS
        echo "SM8850_CPU_PROFILE_REQUESTED=$FW_CPU_PROFILE"
        # Optional final performance token, independent of the existing thermal
        # profile. Strip only a recognized token at the final argument position;
        # the original duration, thermal and risk validation remains unchanged.
        # BEGIN FRAMEWORK_PERF_PROFILE_ARGS
        FW_PERF_ARG=
        case "$MODE:$#" in
            --framework-check:4) FW_PERF_ARG=$4 ;;
            --framework-check:5) FW_PERF_ARG=$5 ;;
            --framework-session:7) FW_PERF_ARG=$7 ;;
            --framework-session:8) FW_PERF_ARG=$8 ;;
        esac
        case "$FW_PERF_ARG" in
            perf-off|perf-frame|perf-task|perf-frame-task)
                FW_PERF_PROFILE=${FW_PERF_ARG#perf-}
                case "$MODE:$#" in
                    --framework-check:4) set -- "$1" "$2" "$3" ;;
                    --framework-check:5) set -- "$1" "$2" "$3" "$4" ;;
                    --framework-session:7) set -- "$1" "$2" "$3" "$4" "$5" "$6" ;;
                    --framework-session:8) set -- "$1" "$2" "$3" "$4" "$5" "$6" "$7" ;;
                esac ;;
        esac
        # END FRAMEWORK_PERF_PROFILE_ARGS
        echo "SM8850_PERF_PROFILE=$FW_PERF_PROFILE"
        if [ "$MODE" = --framework-check ]; then
            # Optional fourth argument pins the no-soft-guard experiment,
            # independent of whether su preserves command-scoped environment.
            [ "$#" -le 4 ] || framework_block "unexpected duration/profile arguments"
            FW_DURATION=${3:-600}
        else
            # Optional seventh argument pins the live thermal profile. A
            # missing/mismatched token MUST NOT silently select another mode.
            [ "$#" -le 7 ] || framework_block "unexpected duration/profile arguments"
            FW_DURATION=${6:-600}
        fi
        case "$FW_DURATION" in ''|0*|*[!0-9]*) framework_block "invalid numeric Framework duration" ;; esac
        [ "${#FW_DURATION}" -le 3 ] && [ "$FW_DURATION" -ge 60 ] && [ "$FW_DURATION" -le 600 ] ||
            framework_block "Framework duration must be 60..600 seconds"
    fi
    # User-requested, one-session-only no-soft-thermal-trip experiment.
    # No persistent property, Android thermal node, firmware limit or
    # watchdog policy is changed. Only accepted for 180s full bridges=1.
    FW_SOFT_THERMAL_OFF=0
    if [ "$FW_MODE" = run ]; then
        # A preflight may still use the historical command-scoped env flag.
        # The detached live session MUST carry its thermal selection as a
        # positional argument: su -> setsid -> sh -c can lose the env flag.
        # Otherwise a no-guard preflight can silently launch the guarded
        # CPU-floor/60C wake gate, exactly as seen on SM-S948B 2026-11-23.
        case "${ONEIOS_SM8850_EXPERIMENT_NO_SOFT_THERMAL:-}" in
            ''|I_ACCEPT_SOFT_GUARD_OFF_180S) ;;
            *) framework_block "unrecognized thermal profile environment" ;;
        esac
        if [ "$MODE" = --framework-check ]; then
            FW_PROFILE_ARG=${4:-}
            [ "$#" -lt 4 ] || [ "$FW_PROFILE_ARG" = I_ACCEPT_SOFT_GUARD_OFF_180S ] ||
                framework_block "invalid explicit preflight thermal profile"
        else
            FW_PROFILE_ARG=${7:-}
            [ "$#" -lt 7 ] || [ "$FW_PROFILE_ARG" = I_ACCEPT_SOFT_GUARD_OFF_180S ] ||
                framework_block "invalid explicit live thermal profile"
        fi
        if [ "$FW_PROFILE_ARG" = I_ACCEPT_SOFT_GUARD_OFF_180S ]; then
            FW_SOFT_THERMAL_OFF=1
        elif [ "$MODE" = --framework-check ] &&
             [ "${ONEIOS_SM8850_EXPERIMENT_NO_SOFT_THERMAL:-}" = I_ACCEPT_SOFT_GUARD_OFF_180S ]; then
            # Backward-compatible read-only preflight; the new host sends
            # both the explicit token and the env flag for cross-checking.
            FW_SOFT_THERMAL_OFF=1
        elif [ "$MODE" = --framework-session ] &&
             [ "${ONEIOS_SM8850_EXPERIMENT_NO_SOFT_THERMAL:-}" = I_ACCEPT_SOFT_GUARD_OFF_180S ]; then
            framework_block "no-soft-guard env was set but live thermal profile token is missing"
        fi
        if [ "$FW_SOFT_THERMAL_OFF" = 1 ]; then
            [ "$FW_DURATION" = 180 ] ||
                framework_block "passive thermal trial is restricted to 180 seconds"
            echo "SM8850_SOFT_THERMAL_GUARD=OFF_NOT_SPAWNED"
            echo "SM8850_CPU_CAP=DISABLED_NO_ROOT_WORKER"
            echo "SM8850_KERNEL_FIRMWARE_THERMAL_PROTECTION=UNCHANGED"
            echo "WARNING=NO_ROOT_THERMAL_GUARD_OR_CPU_CAP_HIGH_HEAT_RISK"
        fi
        if [ "$FW_INTERACTION_PROFILE" != off ]; then
            [ "$FW_DURATION" = 180 ] && [ "$FW_SOFT_THERMAL_OFF" = 0 ] ||
                framework_block "interaction requires guarded 180s run"
            case "$FW_PERF_PROFILE" in frame|frame-task) ;; *) framework_block "interaction requires frame tracing" ;; esac
        fi
        if [ "$FW_OWN_PRESENCE" = 1 ]; then
            [ "$FW_DURATION" = 180 ] && [ "$FW_SOFT_THERMAL_OFF" = 0 ] ||
                framework_block "own-presence requires guarded 180s run"
        fi
        if [ "$MODE" = --framework-session ]; then
            if [ "$FW_SOFT_THERMAL_OFF" = 1 ]; then
                echo "SM8850_LIVE_THERMAL_PROFILE=NO_SOFT_GUARD_EXPLICIT_180S"
            else
                echo "SM8850_LIVE_THERMAL_PROFILE=ROOT_GUARD_DEFAULT"
            fi
        fi
    fi
    [ "$APP" = 0 ] && framework_identity || framework_block "experimental profile requires SM-S948B/m3q/SM8850 firmware S948BXXS4BZIG with SELinux enforcing"
    if [ "$MODE" = --framework-session ]; then
        [ "$3" = I_ACCEPT_SM8850_FRAMEWORK_TAKEOVER ] || framework_block "explicit SM8850 framework takeover acknowledgement required"
        if [ "$FW_MODE" = run ]; then
            [ "$5" = I_ACCEPT_LEGACY_WATCHDOG_FULL_600S_RISK ] ||
                framework_block "600-second legacy-watchdog guest requires separate explicit risk acknowledgement"
        fi
        FW_LAUNCH=$4
        case "$FW_LAUNCH" in ''|*[!a-f0-9]*) framework_block "invalid experiment log identifier" ;; esac
        [ "${#FW_LAUNCH}" -eq 32 ] || framework_block "invalid experiment log identifier"
    fi
else
    case "$MODE" in session|--check) ;; *) framework_block "experimental profile requires its separate root stage" ;; esac
    case "$P_MODEL:$P_DEVICE:$P_SOC" in
        SM-S928*:e3q:SM8650) ;;
        *) refuse "OneiOS switch is currently limited to the S24 Ultra (SM-S928/e3q/SM8650); this phone is ${P_MODEL:-unknown}/${P_DEVICE:-unknown}/${P_SOC:-unknown}; SM8850 hardware diagnostics do not certify recovery" ;;
    esac
fi

# The stage first: without a runtime that has xnuhost, that one line is the answer.
if [ "$FRAMEWORK" = 0 ] || [ "$FW_MODE" = run ]; then
    stage_checks
else
    root_only "$STAGE" && root_only "$SELF" && root_only "$SELF_RETURN" ||
        framework_block "no trusted experimental recovery scripts staged"
fi

# Root tools: the root manager's own busybox and resetprop, as oneos_switch.sh.
BB=""
for c in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
    [ -x "$c" ] && { BB=$c; break; }
done
RP=""
for c in /data/adb/ksu/bin/resetprop /data/adb/ap/bin/resetprop /debug_ramdisk/resetprop /sbin/resetprop; do
    [ -x "$c" ] && { RP=$c; break; }
done
[ -n "$BB" ] || refuse "no busybox at the root manager's paths (/data/adb/ksu/bin, /data/adb/ap/bin, /data/adb/magisk)"
APPLETS=" $("$BB" --list 2>/dev/null | tr '\n' ' ') "
missing=""
# No reboot applet: KernelSU's busybox has none, and oneos_switch.sh asks for none. The way back's reboot is
# init's (sys.powerctl), then Android's own reboot, then busybox's where it has one, then sysrq (hard_reboot).
for a in sh mount umount unshare nsenter setsid awk grep sed; do
    case "$APPLETS" in *" $a "*) ;; *) missing="$missing $a" ;; esac
done
[ -z "$missing" ] || refuse "$BB lacks the applets:$missing"
[ -n "$RP" ] || refuse "no resetprop at the root manager's paths: One UI's boot counters could not be put back on the return"

# init's mount namespace: the session's own namespace is made from it, and the
# return checks init's mount table.
SELF_NS=$(readlink /proc/$$/ns/mnt 2>/dev/null)
INIT_NS=$(readlink /proc/1/ns/mnt 2>/dev/null)
if [ -z "$SELF_NS" ] || [ "$SELF_NS" != "$INIT_NS" ]; then
    if [ "$APP" != 1 ] && [ -z "$ONEIOS_NS_REENTERED" ]; then
        echo "Not in init's mount namespace: running again in init's"
        export ONEIOS_NS_REENTERED=1
        # The parser consumed the optional profile suffixes. Reconstruct
        # them in canonical order before re-entering init's namespace.
        if [ "$FRAMEWORK" = 1 ] && [ "$FW_MODE" = run ]; then
            [ "$FW_PERF_PROFILE" = off ] || set -- "$@" "perf-$FW_PERF_PROFILE"
            [ "$FW_CPU_PROFILE" = default ] || set -- "$@" cpu-prime-first
            [ "$FW_OWN_PRESENCE" = 0 ] || set -- "$@" own-presence-1
            [ "$FW_INTERACTION_PROFILE" = off ] || set -- "$@" interaction-swipe-60s
        fi
        exec "$BB" nsenter -t 1 -m -- /system/bin/sh "$SELF" "$@"
    fi
    refuse "not in init's mount namespace (this shell: ${SELF_NS:-unreadable}, init: ${INIT_NS:-unreadable})"
fi

# One UI must be whole and no session of either kind may be up.
[ "$(getprop sys.boot_completed)" = 1 ] || refuse "One UI has not finished starting"
[ "$(getprop init.svc.zygote)" = running ] && pidof system_server >/dev/null 2>&1 ||
    refuse "One UI's framework is not running (another session, or a return in progress): restart the phone first"
pidof surfaceflinger >/dev/null 2>&1 || refuse "One UI's surfaceflinger is not running"
if [ "$FRAMEWORK" = 1 ]; then
    command -v flock >/dev/null && command -v timeout >/dev/null || framework_block "flock or timeout missing"
    [ -d /data/adb ] && root_only /data/adb || framework_block "untrusted root stage parent"
    case "$(cat /data/local/tmp/oneios/control/state 2>/dev/null):$(cat /data/local/tmp/oneos/control/state 2>/dev/null)" in
        *starting*|*running*|*returning*) framework_block "another OneOS stage is active" ;;
    esac
    if pidof xnuhost xnuhost-gui-bench xnuhost-tasks OneiOSDisplay oneios-display >/dev/null 2>&1; then
        framework_block "another xnuhost or display helper is running"
    fi
    if [ "$MODE" = --framework-session ]; then
        [ ! -L "$STAGE/start.lock" ] || framework_block "invalid start lock"
        # Android mksh hides exec-opened fd 8 from external commands.
        # Redirect the same open file description through fd 0 for flock;
        # the shell retains fd 8 (and the lock) throughout the switch.
        exec 8>>"$STAGE/start.lock"
    flock -n 0 0<&8 || framework_block "another experimental switch is starting"
    fi
fi
left=$(awk -v s="$STAGE" -v o="$ANDROID_STAGE" '$5 == s || index($5, s "/") == 1 || index($5, o "/") == 1 { print $5 }' /proc/self/mountinfo | head -n 3 | tr '\n' ' ')
[ -z "$left" ] || refuse "mounted under a stage ($left): a session is running or never returned; restart the phone first"
if [ "$(cat "$CTL/boot" 2>/dev/null)" = "$(boot_id)" ]; then
    case "$(cat "$CTL/state" 2>/dev/null)" in
        starting|running|returning) refuse "an iOS session of this boot is still open ($(cat "$CTL/state")): restart the phone first" ;;
    esac
fi
op=$(cat "$CTL/xnuhost.pid" 2>/dev/null)
on=$(cat "$CTL/mntns" 2>/dev/null)
[ -z "$op" ] || [ -z "$on" ] || [ "$(readlink "/proc/$op/ns/mnt" 2>/dev/null)" != "$on" ] ||
    refuse "xnuhost of an earlier session is still running (pid $op): restart the phone first"
old=""
for p in $(head -n 3 /sys/fs/cgroup/oneios_session/cgroup.procs 2>/dev/null); do [ -d "/proc/$p" ] && old="$old$p "; done
[ -z "$old" ] || refuse "processes of an earlier iOS session are still running (cgroup oneios_session: $old): restart the phone first"

# The ways back: the volume keys, and enough battery to get there.
command -v getevent >/dev/null 2>&1 || refuse "no getevent: Volume Up + Volume Down could not return to One UI"
command -v ps >/dev/null 2>&1 || refuse "no ps: the key readers could not be told apart"
KDEVS=$(volume_key_devices) || refuse "could not validate physical volume keys in getevent (gpio-keys Volume Up, pmic_resin Volume Down)"
if [ "$FRAMEWORK" = 1 ]; then
    framework_probe || framework_block "SM8850 recovery cannot be armed"
    if [ "$FRAMEWORK_REBOOT" = 1 ]; then
        [ "$WD_TARGET" = "legacy a:82" ] ||
            framework_block "the legacy watchdog holder does not match the reboot-only profile"
        qualified=legacy-reboot-only
    else
        qualified=$(framework_watchdog_plan "$WD_TARGET") || framework_block "watchdog qualification changed"
    [ -x "$STAGE/oneios-watchdog" ] && root_only "$STAGE/oneios-watchdog" &&
        [ "$(sha256sum "$STAGE/oneios-watchdog" | cut -d' ' -f1)" = "${qualified##* }" ] ||
        framework_block "the qualified native watchdog supervisor is not staged"
    fi
    [ "$(getprop init.svc.zygote_next)" = running ] || framework_block "the expected zygote_next service is not running"
    if [ "$FW_MODE" = run ]; then
        [ "$(cat "$STAGE/image.ready" 2>/dev/null)" = sm8850-ios27-3d-8cpu-600s ] ||
            framework_block "the attested 3D, 8-vCPU, 600s guest stage was not finalized"
        # This exact phone already passed a Framework-only smoke; the
        # first attempted full run has since replaced control/ with its own
        # mode=run marker. The switch archives the previous session in
        # logs/session.XXXXXXXX before replacing control/. Accept only the
        # verified ORIGINAL smoke record, whether still live or archived.
        # No need for a second destructive smoke after a guest-launch bug.
        sm8850_old_smoke_valid() {
            sr_ctl=$1 sr_outcome_path=$2
            root_only "$sr_ctl" && root_only "$sr_outcome_path" || return 1
            sr_boot=$(cat "$sr_ctl/boot" 2>/dev/null)
            sr_marker=$(cat "$sr_ctl/framework.takeover-confirmed" 2>/dev/null)
            [ -n "$sr_boot" ] && [ "$sr_boot" != "$(boot_id)" ] &&
                [ "${sr_marker%%.*}" = "$sr_boot" ] &&
                [ "$(cat "$sr_ctl/framework.mode" 2>/dev/null)" = smoke ] &&
                [ "$(cat "$sr_ctl/framework.return" 2>/dev/null)" = reboot ] || return 1
            sr_outcome=$(cat "$sr_outcome_path" 2>/dev/null)
            case "$sr_outcome" in
                reboot-deadline-or-manual*"who=framework-deadline"*"framework deadline reached"*) return 0 ;;
            esac
            return 1
        }
        smoke_proof=
        if sm8850_old_smoke_valid "$CTL" "$STAGE/return.outcome"; then
            smoke_proof=control
        else
            for sr_archive in "$STAGE"/logs/session.*; do
                [ -d "$sr_archive" ] && [ ! -L "$sr_archive" ] &&
                    root_only "$sr_archive" || continue
                if sm8850_old_smoke_valid "$sr_archive/control" "$sr_archive/return.outcome"; then
                    smoke_proof=archived
                    break
                fi
            done
        fi
        # Historical smoke evidence is pinned to its OWN boot and recorded
        # completion. ro.boot.bootreason describes the CURRENT boot, which
        # may legitimately be an operator-initiated ordinary reboot.
        # Requiring the old custom reboot reason on every later boot
        # erroneously invalidates a genuine archived smoke session.
        # Keep the prior-session proof mandatory; never substitute a
        # current reboot reason for missing smoke records.
        [ -n "$smoke_proof" ] ||
            framework_block "verified original smoke proof missing from root-owned current or archived session; full run refused"
        echo "SM8850_PREVIOUS_REBOOT_SMOKE=VERIFIED_DEADLINE_REQUEST_ONLY"
        echo "SM8850_SMOKE_PROOF_SOURCE=$smoke_proof"
        echo "SM8850_CURRENT_BOOT_REASON=INFORMATIONAL_ONLY:$(getprop ro.boot.bootreason)"
        echo "SM8850_MANUAL_REBOOT=DOES_NOT_INVALIDATE_HISTORIC_SMOKE_PROOF"
        echo "UNASSISTED_RETURN_TO_ONEUI=UNVERIFIED"
        echo "SM8850_FULL_RUN=EXPLICIT_RISK_ACCEPTED_WITH_REBOOT_ONLY_RETURN"
        # The 2026-11-20 SM-S948B physical run did execute xnuhost for
        # ~600.6 s and show guest-ready/first-frame with real KGSL traffic.
        # That is NOT proof of fast UI, independent watchdog qualification,
        # thermal safety or an unassisted return to One UI. The full-run
        # remains bench/bridges=0 for exclusive touch: the OneiOS thermal
        # bridge and CPU topology/affinity bridge are not started here.
        echo "SM8850_FULL_RUN_GUEST_BOOT=PRIOR_PHYSICAL_OBSERVATION_NOT_A_NEW_SESSION_PASS"
        if [ "$FW_SOFT_THERMAL_OFF" = 1 ]; then
            echo "SM8850_FULL_RUN_THERMAL_BRIDGE=NO_ROOT_THERMAL_GUARD; HOST_READ_ONLY_TELEMETRY_ONLY"
            echo "SM8850_FULL_RUN_CPU_CAP=DISABLED_NO_ROOT_WORKER"
        else
            echo "SM8850_FULL_RUN_THERMAL_BRIDGE=ACTIVE_BRIDGES_1_ROOT_MONITOR_MANDATORY"
        fi
        echo "SM8850_FULL_RUN_CPU_AFFINITY=REQUIRES_XNUHOST_BENCH_AFFINITY_8_DISTINCT_CORES_LOG"
        echo "SM8850_FULL_RUN_GPU_3D=KGSL_OBSERVED_PRIOR_RUN_AUTO_FALLBACK_POSSIBLE"
        echo "SM8850_FULL_RUN_RECOVERY=DEADLINE_AND_UNASSISTED_RETURN_NOT_FULLY_VERIFIED"
        if [ "$FW_SOFT_THERMAL_OFF" = 1 ]; then
            # Exact 180s experimental mode only: no root thermal guard and
            # no root CPU cap worker; kernel/vendor thermal policy is unchanged.
            echo "SM8850_SOFTWARE_THERMAL_MONITOR=DISABLED_FOR_180S"
            echo "SM8850_CPU_CAP_ADMISSION=DISABLED_NO_ROOT_WORKER"
        else
            for th_file in oneios_sm8850_thermal_takeover_guard.sh oneios_sm8850_thermal_cap.sh thermal.guard.manifest; do
                root_only "$STAGE/$th_file" || framework_block "untrusted or missing independent thermal asset $th_file"
            done
            $SH "$STAGE/oneios_sm8850_thermal_takeover_guard.sh" --check "$STAGE/thermal.guard.manifest" ||
                framework_block "root thermal sensor manifest not qualified on current boot"
            if [ "$FW_DURATION" = 180 ]; then
                $SH "$STAGE/oneios_sm8850_thermal_cap.sh" --check-bandwidth ||
                    framework_block "hybrid frequency ceiling or isolated v1 CPU bandwidth unavailable"
            else
                $SH "$STAGE/oneios_sm8850_thermal_cap.sh" --check ||
                    framework_block "root CPU cap policy nodes not writable or unverifiable"
            fi
        fi
        root_only "$STAGE/data" && root_only "$STAGE/data/data.img" && root_only "$STAGE/data/unique-chip-id" &&
            [ "$(stat -c '%s:%h' "$STAGE/data/data.img")" = 8589934592:1 ] &&
            [ "$(stat -c '%s:%h' "$STAGE/data/unique-chip-id")" = 8:1 ] ||
            framework_block "the independent APFS Data snapshot is missing or unsafe"
        [ -w "$P/sys/vm/max_map_count" ] || framework_block "vm.max_map_count cannot be restored"
        [ -x "$STAGE/runtime/bin/oneios-display" ] || framework_block "the benchmark display helper is missing"
        # A stage-only OneOS update must NOT point the next live run at an
        # older xnuhost binary that lacks panel-bridge=1; fail before the
        # independent APFS Data clone can be consumed.
        grep -Fq 'SM8850_FULL_BRIDGES=ACTIVE' "$X" 2>/dev/null ||
            framework_block "staged xnuhost lacks full bridges=1 Framework profile; rebuild and upgrade the native runtime before rearming Data"
        if [ "$FW_OWN_PRESENCE" = 1 ]; then
            "$BB" grep -aFq 'oneios-own-presence' "$STAGE/image/kernel.kc" 2>/dev/null ||
                framework_block "staged kernel lacks readable 0082 own-presence marker"
        fi
        echo "SM8850_OWN_PRESENCE=$FW_OWN_PRESENCE"
        if [ "$FW_INTERACTION_PROFILE" != off ]; then
            grep -Fq 'SM8850_INTERACTION_V1' "$X" 2>/dev/null ||
                framework_block "staged xnuhost lacks bounded interaction profile; build and stage runtime before rearm"
        fi
        echo "SM8850_INTERACTION_PROFILE=$FW_INTERACTION_PROFILE"
        if [ "$FW_CPU_PROFILE" = prime-first ]; then
            grep -Fq 'SM8850_CPU_PROFILE=PRIME_FIRST_ACTIVE' "$X" 2>/dev/null ||
                framework_block "staged xnuhost lacks opt-in Prime-first placement"
        fi
        case "$FW_PERF_PROFILE" in frame|frame-task)
            grep -Fq 'frame-trace' "$X" 2>/dev/null ||
                framework_block "staged xnuhost lacks frame tracing" ;;
        esac
        case "$FW_PERF_PROFILE" in task|frame-task)
            grep -Fq 'perf-task: enabled' "$X" 2>/dev/null ||
                framework_block "staged xnuhost lacks task profiling" ;;
        esac
        if [ "$FW_SOFT_THERMAL_OFF" = 1 ]; then
            grep -Fq 'SM8850_FULL_BRIDGES=ADMITTED_NO_USERSPACE_THERMAL_180S' "$X" 2>/dev/null ||
                framework_block "staged xnuhost lacks current 180s no-thermal-guard admission; rebuild and stage the native runtime BEFORE rearming APFS Data"
            echo "SM8850_NO_GUARD_XNUHOST_ADMISSION=STAGED_RUNTIME_COMPATIBLE"
        fi
        cap=$(awk '/^CapEff:/ {print $2}' "$P/$$/status")
        [ "$((0x${cap:-0} & 16384))" -ne 0 ] || framework_block "CAP_IPC_LOCK is absent"
        [ "$(df -Pk "$STAGE" | awk 'NR==2 {print $4}')" -ge 31457280 ] ||
            framework_block "the staged bench requires at least 30 GiB of free storage"
    fi
fi
WD_TARGET=$(watchdog_target) || refuse "watchdog recovery could not identify One UI's active software watchdog"
watchdog_now >/dev/null || refuse "watchdog recovery could not read monotonic boot uptime"
WD_BOOT=$(boot_id)
WD_BIRTH=$(watchdog_birth $$)
[ -n "$WD_BOOT" ] && [ -n "$WD_BIRTH" ] || refuse "watchdog recovery could not identify the switch process and boot"
BAT=/sys/class/power_supply/battery
CAP=$(cat $BAT/capacity 2>/dev/null)
BST=$(cat $BAT/status 2>/dev/null)
BTEMP=$(cat $BAT/temp 2>/dev/null)
case "$CAP" in ''|*[!0-9]*) refuse "battery not readable" ;; esac
case "${BTEMP#-}" in ''|*[!0-9]*) refuse "battery temperature not readable" ;; esac
[ "$CAP" -ge 30 ] || [ "$BST" = Charging ] || [ "$BST" = Full ] || refuse "battery at $CAP% and not charging"
[ "$BTEMP" -lt 420 ] || refuse "battery too warm ($((BTEMP / 10)) C)"
# Room for the guest's data store to grow (2 GiB).
set -- $(stat -f -c '%a %S' /data 2>/dev/null)
[ $# -eq 2 ] && [ "$(awk -v a="$1" -v s="$2" 'BEGIN { print (a * s >= 2147483648) ? 1 : 0 }')" = 1 ] ||
    refuse "less than 2 GiB free on /data"
[ -w /sys/power/wake_lock ] || refuse "no /sys/power/wake_lock: the phone would sleep with One UI's framework stopped"
# The app's experimental tick (root's switch verb passes it on).
[ "$APP" != 1 ] || [ "${ONEIOS_ACK_EXPERIMENTAL:-0}" = 1 ] || refuse "the experimental tick was not given"

echo "Preflight passed (runtime $R_VERSION, xnuhost $R_XNUHOST, image iOS $I_VERSION $I_BUILD format $I_FORMAT, busybox $BB, SELinux $(getenforce 2>/dev/null))"
if [ "$MODE" = --check ] || [ "$MODE" = --framework-check ]; then
    echo "PREFLIGHT OK"
    exit 0
fi
if [ "$FRAMEWORK" = 1 ] && [ "$FW_MODE" = run ]; then
    # The Framework session holds start.lock. Refuse used Data before
    # creating any session helpers, but do not spend a fresh clone on
    # pre-stop wake/cooldown or recovery admission failures.
    [ ! -L "$STAGE/data.consumed" ] && [ ! -e "$STAGE/data.consumed" ] ||
        framework_block "isolated APFS Data clone was already consumed"
fi

# --- THE SESSION -----------------------------------------------------------
# From here on something changes. Out of the launching app's cgroup and away
# from the OOM killer first: ActivityManager kills an app's whole cgroup when
# the app dies, and a switch killed half way leaves One UI stopped.
echo $$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null
echo -1000 > /proc/$$/oom_score_adj 2>/dev/null
trap '' HUP PIPE
export BB

echo "=== [1/5] $(date +%T) Session folder and baseline ==="
# The last session's log is kept (five of them); its folder is this session's.
[ ! -L "$SESSION" ] || refuse "$SESSION is a symlink"
[ ! -L "$CTL" ] || refuse "$CTL is a symlink"
mkdir -p "$STAGE/logs" && chmod 0700 "$STAGE/logs"
if [ "$FRAMEWORK" = 1 ]; then
    archive=$(mktemp -d "$STAGE/logs/session.XXXXXX") || framework_setup_failed "could not archive the previous session"
    for name in session control return.log return.outcome; do
        [ ! -e "$STAGE/$name" ] || mv "$STAGE/$name" "$archive/$name" || framework_setup_failed "could not retain $name"
    done
    [ "$FW_MODE" != smoke ] || rm -f "$STAGE/smoke.accepted" || framework_setup_failed "could not clear stale smoke evidence"
else
    [ -s "$SESSION/xnuhost.log" ] && mv -f "$SESSION/xnuhost.log" "$STAGE/logs/xnuhost-$(date +%s).log"
    ls -1t "$STAGE/logs"/xnuhost-*.log 2>/dev/null | tail -n +6 | while read -r old; do rm -f "$old"; done
fi
rm -rf "$SESSION" "$CTL"
mkdir -p "$CTL/base" "$CTL/keys" "$SESSION/tmp" "$STAGE/data" && chown -R 0:0 "$SESSION" "$CTL" && chmod -R go-rwx "$SESSION" "$CTL" &&
    chmod 0700 "$STAGE/data" || refuse "could not make $SESSION"
true > "$SESSION/xnuhost.log"
boot_id > "$CTL/boot"
echo starting > "$CTL/state"
# What the in-place return compares against (oneios_return.sh), read while
# One UI is whole. Nothing here is changed by the session; the return only
# proves that.
B="$CTL/base"
boot_id > "$B/boot_id"
getenforce > "$B/selinux" 2>&1
getprop > "$B/props"
for n in vold keystore2 surfaceflinger servicemanager; do echo "$n $(pidof $n 2>/dev/null | tr ' ' ',')"; done > "$B/pids"
case "$(settings get global wifi_on 2>/dev/null)" in 1|2) echo 1 ;; *) echo 0 ;; esac > "$B/wifi_on"
awk '{ print $5 }' /proc/1/mountinfo | sort > "$B/mounts"
# The panel's brightness as One UI has it: xnuhost's brightness bridge writes
# the backlight node, and a session it cannot end itself (SIGKILL) would leave
# iOS's last level, possibly the dimmest. The return writes these back.
for bl in "$T"/sys/class/backlight/*/brightness; do
    [ -f "$bl" ] && echo "${bl#"$T"} $(cat "$bl" 2>/dev/null)"
done > "$B/backlight" 2>/dev/null
if [ "$FRAMEWORK" = 1 ]; then
    framework_service_pids > "$B/framework_services" || framework_setup_failed "essential service baseline changed"
    mkdir "$CTL/captures" || framework_setup_failed "could not prepare screenshot directory"
    printf '%s\n' "$FW_MODE" > "$CTL/framework.mode" || framework_setup_failed "could not record framework mode"
    printf '%s\n' "$FW_LAUNCH" > "$CTL/framework.launch" || framework_setup_failed "could not record framework log identifier"
    if [ "$FW_MODE" = run ]; then
        printf '%s\n' "$FW_DURATION" > "$CTL/framework.duration" ||
            framework_setup_failed "could not record bounded duration"
        printf '%s\n' "$FW_PERF_PROFILE" > "$CTL/framework.perf-profile" ||
            framework_setup_failed "could not record performance instrumentation profile"
        printf '%s\n' "$FW_CPU_PROFILE" > "$CTL/framework.cpu-profile" ||
            framework_setup_failed "could not record CPU placement profile"
        printf '%s\n' "$FW_OWN_PRESENCE" > "$CTL/framework.own-presence" ||
            framework_setup_failed "could not record own-presence profile"
        printf '%s\n' "$FW_INTERACTION_PROFILE" > "$CTL/framework.interaction-profile" ||
            framework_setup_failed "could not record interaction profile"
        if [ "$FW_SOFT_THERMAL_OFF" = 0 ] && [ "$FW_DURATION" = 180 ]; then
            printf 'hybrid-v1-180s\n' > "$CTL/framework.cpu-budget" ||
                framework_setup_failed "could not record isolated CPU bandwidth profile"
        fi
        if [ "$FW_SOFT_THERMAL_OFF" = 1 ]; then
            printf 'disabled-180s\n' > "$CTL/framework.soft-thermal" ||
                framework_setup_failed "could not record explicitly accepted no-software-guard mode"
        fi
    fi
    if [ "$FRAMEWORK_REBOOT" = 1 ]; then
        if [ "$FW_MODE" = smoke ]; then
            printf '%s\n' "$FW_SMOKE_SECONDS" > "$CTL/framework.duration" ||
                framework_setup_failed "could not record smoke duration"
        fi
        printf 'reboot\n' > "$CTL/framework.return" ||
            framework_setup_failed "cannot record mandatory reboot-only return"
    fi
else
    clocks_save
fi
# The USB gadget and adbd as One UI has them (control/base/usb), for the
# session's USB watcher and the return.
usb_save
echo "Baseline: boot $(cat "$B/boot_id"), SELinux $(cat "$B/selinux"), $(tr '\n' ' ' < "$B/pids")wifi $(cat "$B/wifi_on")"

echo "=== [2/5] $(date +%T) Arming the way back ==="
# Before the stop: the watcher returns to One UI by itself if this script
# does not get as far as a running xnuhost. The watcher, the key readers and
# the poll are started here, in init's mount namespace, before xnuhost's
# namespace and cgroup exist: they are never part of either.
# Each of them writes its own pid (watcher.pid, keys/pids) once it runs.
WD_GEN="$WD_BOOT.$$.$WD_BIRTH"
if ! printf '%s\n' "$WD_GEN" > "$CTL/watchdog.generation"; then
    echo "Could not record the watchdog generation. One UI was left running."
    echo failed > "$CTL/state"
    exit 4
fi
"$BB" setsid $SH "$SELF" --watch 8>&- </dev/null >>"$STAGE/return.log" 2>&1 &
KTOK="$$.$(date +%s)"
echo "$KTOK" > "$CTL/keys/session"
readers=1
role=up
for kd in $KDEVS; do
    "$BB" setsid $SH "$SELF" --keys "$kd" "$KTOK" "$role" 8>&- </dev/null >/dev/null 2>&1 &
    role=down
    readers=$((readers + 1))
done
"$BB" setsid $SH "$SELF" --keys-poll "$KTOK" $KDEVS 8>&- </dev/null >/dev/null 2>&1 &
# With One UI's power manager gone nothing would keep the phone awake.
echo oneios_session > /sys/power/wake_lock 2>/dev/null
# One UI is stopped only with the way back in place: the watcher, a reader
# for every key device and the poll running, the wakelock held. Otherwise this
# is where the switch ends, with One UI untouched (the return only ends the
# helpers: there is no stop mark yet).
n=0
while [ $n -lt 25 ]; do
    [ -s "$CTL/watcher.pid" ] && [ "$(grep -c . "$CTL/keys/pids" 2>/dev/null)" = "$readers" ] &&
        { [ "$FRAMEWORK" = 0 ] || [ "$(find "$CTL/keys" -name 'reader.*' | wc -l | tr -d ' ')" = "$readers" ]; } && break
    sleep 0.2; n=$((n + 1))
done
armed=""
kill -0 "$(cat "$CTL/watcher.pid" 2>/dev/null)" 2>/dev/null || armed="the watcher is not running"
[ "$(grep -c . "$CTL/keys/pids" 2>/dev/null)" = "$readers" ] || armed="${armed:+$armed, }$(grep -c . "$CTL/keys/pids" 2>/dev/null) of $readers key readers started"
for p in $(cat "$CTL/keys/pids" 2>/dev/null); do
    kill -0 "$p" 2>/dev/null || armed="${armed:+$armed, }key reader $p is not running"
    if [ "$FRAMEWORK" = 1 ]; then
        framework_pid_alive "$CTL/keys/reader.$p" || armed="key reader $p is not in the protected recovery context"
    fi
done
if [ "$FRAMEWORK" = 1 ] && [ "$FW_MODE" = run ] && [ -z "$armed" ]; then
    # Arm both root-side workers BEFORE Framework stops. Their PIDs,
    # birth tokens, heartbeat and emergency faults stay OUTSIDE the guest
    # cgroup. A failed admission never proceeds to stop system_server.
    if [ "$FW_SOFT_THERMAL_OFF" = 1 ]; then
        # Intentional: no thermal guard process is started, and no
        # temperature fault/heartbeat is required by the independent watcher.
        echo "THERMAL_GUARD=OFF_NO_PROCESS_NO_HEARTBEAT_NO_SOFT_RETURN"
        echo "CPU_CAP=DISABLED_NO_ROOT_WORKER"
    else
        "$BB" setsid $SH "$STAGE/oneios_sm8850_thermal_takeover_guard.sh" --run "$CTL" "$STAGE/thermal.guard.manifest" "$WD_GEN" \
            8>&- </dev/null >>"$STAGE/thermal-guard.log" 2>&1 &
        n=0
        until framework_thermal_guard_healthy; do
            [ "$n" -lt 25 ] || break
            sleep 0.2; n=$((n + 1))
        done
        if ! framework_thermal_guard_healthy; then
            armed="independent root thermal monitor did not start"
        fi
        [ -n "$armed" ] || printf '%s\n' "$WD_GEN" > "$CTL/thermal.guard.required" ||
            armed="could not require independent thermal guard"
        [ -n "$armed" ] || echo "THERMAL_GUARD=ARMED_ROOT_BEFORE_FRAMEWORK_STOP; CPU_THROTTLE=PREARM_BEFORE_STOP; LAST_RESORT_CPU=90C"
    fi
fi
if [ "$FRAMEWORK" = 1 ] && [ "$FW_MODE" = run ] && [ -z "$armed" ]; then
    # Launch the independent root CPU cap before stopping system_server,
    # but do NOT allow ANY sysfs clock writes while One UI is still alive.
    # The cap publishes PID/birth immediately, then only monitors until:
    # stopped marker + stopped zygote(s) + absent system_server.
    if [ "$FW_SOFT_THERMAL_OFF" = 1 ]; then
        echo "CPU_CAP=NO_PREARM_NO_HEALTH_DEPENDENCY; NO_POST_STOP_WORKER"
    else
        "$BB" setsid $SH "$STAGE/oneios_sm8850_thermal_cap.sh" --run-prearmed "$CTL" "$WD_GEN" \
            8>&- </dev/null >>"$STAGE/thermal-cap.log" 2>&1 &
        n=0
        until framework_thermal_cap_prearmed; do
            [ "$n" -lt 25 ] || break
            sleep 0.2; n=$((n + 1))
        done
        if ! framework_thermal_cap_prearmed; then
            armed="independent root CPU cap could not prearm read-only"
        fi
        [ -n "$armed" ] || printf '%s\n' "$WD_GEN" > "$CTL/thermal.cap.prearm.required" ||
            armed="could not require prearmed independent CPU cap"
        [ -n "$armed" ] || echo "CPU_THROTTLE=PREARMED_READ_ONLY_NO_SYSFS_WRITES_BEFORE_FRAMEWORK_STOP"
    fi
fi
# SM8850: the Android KEYCODE_WAKEUP request briefly raises both CPU
# clusters' minimum-frequency votes on real One UI 9 hardware (~8 seconds).
# If system_server is killed within that boost, Samsung's vendor minimum may
# remain elevated and the post-stop CPU cap cannot enforce a lower ceiling.
# Do this with One UI still alive, BEFORE the 45s framework-start cutoff.
# Do not change kernel votes, thermal trips, or the CPU-cap fail-safe.
if [ "$FRAMEWORK" = 1 ] && [ "$FW_MODE" = run ] && [ -z "$armed" ]; then
    if [ "$FW_SOFT_THERMAL_OFF" = 1 ]; then
        # Android lock screen may darken the panel after ~5s. Send
        # KEYCODE_WAKEUP every 2s while system_server still owns input.
        # This is a bounded PRE-STOP pulse train, NOT a 180s ADB spammer.
        # Samsung may boost CPU minimum votes after each pulse; the
        # experimental 28% cap is best-effort and cannot be certified here.
        wake_pulses=0
        while [ "$wake_pulses" -lt 4 ]; do
            if [ -e "$SESSION/return.request" ] ||
               [ "$(getprop init.svc.zygote)" != running ] ||
               ! pidof system_server >/dev/null 2>&1; then
                armed="switch-panel-wake-refused: One UI input no longer available before Framework stop"
                break
            fi
            if ! timeout 5 input keyevent KEYCODE_WAKEUP >/dev/null 2>&1; then
                armed="switch-panel-wake-refused: Android KEYCODE_WAKEUP failed at pulse $wake_pulses"
                break
            fi
            wake_pulses=$((wake_pulses + 1))
            [ "$wake_pulses" -ge 4 ] || sleep 2
        done
        [ -n "$armed" ] || echo "FRAMEWORK_PANEL_WAKE=EXPERIMENTAL_4_WAKEUP_PULSES_EVERY_2S_PRE_STOP; FINAL_PULSE=IMMEDIATELY_BEFORE_ZYGOTE_STOP; NO_SOFTWARE_THERMAL_GATE"
    else
    wake_cpu0=/sys/devices/system/cpu/cpufreq/policy0
    wake_cpu6=/sys/devices/system/cpu/cpufreq/policy6
    wake_floor0=$(cat "$wake_cpu0/cpuinfo_min_freq" 2>/dev/null) || wake_floor0=
    wake_floor6=$(cat "$wake_cpu6/cpuinfo_min_freq" 2>/dev/null) || wake_floor6=
    if ! watchdog_uint "$wake_floor0" || ! watchdog_uint "$wake_floor6" ||
       [ "$wake_floor0" -lt 100000 ] || [ "$wake_floor6" -lt 100000 ]; then
        armed="switch-panel-wake-refused: CPU hardware minimum frequencies unreadable"
    elif ! timeout 5 input keyevent KEYCODE_WAKEUP >/dev/null 2>&1; then
        armed="switch-panel-wake-refused: Android KEYCODE_WAKEUP failed"
    else
        # Three consecutive guard-healthy observations at/below the *hardware*
        # CPU minimum and <60 C CPU/GPU/DDR. A boost, stale sample, missing
        # input service, or high temperature must refuse before Framework stop.
        wake_ok=0
        wake_stable=0
        wake_elapsed=0
        while [ "$wake_elapsed" -lt 20 ]; do
            if [ -e "$SESSION/return.request" ] ||
               [ "$(getprop init.svc.zygote)" != running ] ||
               ! pidof system_server >/dev/null 2>&1; then
                break
            fi
            if ! framework_thermal_guard_healthy; then
                break
            fi
            wake_min0=$(cat "$wake_cpu0/scaling_min_freq" 2>/dev/null) || break
            wake_min6=$(cat "$wake_cpu6/scaling_min_freq" 2>/dev/null) || break
            if ! watchdog_uint "$wake_min0" || ! watchdog_uint "$wake_min6"; then
                break
            fi
            if [ "$wake_min0" -le "$wake_floor0" ] &&
               [ "$wake_min6" -le "$wake_floor6" ] &&
               [ "$th_cpu" -lt 60000 ] &&
               [ "$th_gpu" -lt 60000 ] &&
               [ "$th_ddr" -lt 60000 ]; then
                wake_stable=$((wake_stable + 1))
                # Even if a minimum vote appears settled immediately,
                # allow delayed Samsung power/performance votes to appear.
                if [ "$wake_stable" -ge 3 ] && [ "$wake_elapsed" -ge 8 ]; then
                    wake_ok=1
                    break
                fi
            else
                wake_stable=0
            fi
            sleep 1
            wake_elapsed=$((wake_elapsed + 1))
        done
        if [ "$wake_ok" = 1 ]; then
            echo "FRAMEWORK_PANEL_WAKE=ANDROID_KEYCODE_WAKEUP_PRE_STOP; CPU_MIN_COOLDOWN=THREE_HEALTHY_SAMPLES; CPU0_MIN_KHZ=$wake_min0; CPU6_MIN_KHZ=$wake_min6; CPU_PEAK_MC=$th_cpu; TOUCH_PANEL_POWER_NOT_CERTIFIED"
        else
            armed="switch-panel-wake-refused: CPU floor or thermal sample unsettled (CPU0_MIN=${wake_min0:-unreadable}, CPU6_MIN=${wake_min6:-unreadable}, CPU_MC=${th_cpu:-unreadable}, elapsed=${wake_elapsed}s)"
        fi
    fi
    fi
    if [ -n "$armed" ]; then
        echo "FRAMEWORK_PANEL_WAKE=BLOCKED_BEFORE_FRAMEWORK_STOP; REASON=$armed"
    fi
fi
if [ "$FRAMEWORK" = 1 ] && [ -z "$armed" ]; then
    if fw_start=$(watchdog_now) && framework_pid_alive "$CTL/framework.watcher" &&
        printf '%s\n' "$((fw_start + 45))" > "$CTL/framework.cutoff"; then
        "$BB" setsid $SH "$SELF" --framework-deadline "$WD_GEN" 8>&- </dev/null >>"$STAGE/return.log" 2>&1 &
        n=0
        until framework_pid_alive "$CTL/framework.guard" 2>/dev/null; do
            [ "$n" -lt 20 ] || break
            sleep 0.2; n=$((n + 1))
        done
        framework_pid_alive "$CTL/framework.guard" 2>/dev/null || armed="independent deadline guard did not start"
    else
        armed="watcher identity or monotonic uptime could not be confirmed"
    fi
fi
case " $(cat /sys/power/wake_lock 2>/dev/null) " in
    *" oneios_session "*) ;;
    *) armed="${armed:+$armed, }the wakelock oneios_session is not held" ;;
esac
if [ -n "$armed" ]; then
    echo "!!! The way back to One UI could not be armed ($armed): One UI was not stopped, nothing was changed"
    echo failed > "$CTL/state"
    $SH "$STAGE/oneios_return.sh" switch-not-armed
    exit 4
fi
if [ "$FRAMEWORK_REBOOT" = 1 ]; then
    echo "SM8850 USB safety: DO NOT press Volume Up + Volume Down during the experimental session."
    echo "Samsung may enter Download Mode if the phone restarts while both volume keys are held with USB connected."
    if [ "$FW_MODE" = run ]; then
        if [ "$FW_SOFT_THERMAL_OFF" = 1 ]; then
            echo "FULL iOS guest, 8 vCPUs, GPU 3D and touch: ${FW_DURATION}s reboot deadline; NO software thermal guard, CPU cap best effort only."
        else
            echo "FULL iOS guest, 8 vCPUs, GPU 3D and touch: independent ${FW_DURATION}s deadline from Framework stop; root throttle guard ACTIVE."
        fi
        echo "Legacy watchdog a:82 and normal One UI boot are NOT independently qualified. Explicit-risk experiment."
    else
        echo "Framework-only smoke: independent ${FW_SMOKE_SECONDS}s deadline requests reboot after Framework stop."
    fi
    echo "If frozen, Samsung Side/Power + Volume Down for >7s forces restart; this does NOT verify key watcher."
else
    echo "Return to One UI: hold Volume Up + Volume Down for 3 s (key devices: $(echo $KDEVS)); watcher $(cat "$CTL/watcher.pid"), key readers $(tr '\n' ' ' < "$CTL/keys/pids")"
    echo "If that does nothing: hold Power + Volume Down until the phone restarts (about 7 s). It restarts into One UI."
fi

# A return asked while the switch runs (the watcher, the key readers, the app,
# adb) wins. The switch and the return meet at one lock, $CTL/stop.lock: the
# switch holds it while saving and changing shmem and stopping One UI, the
# return takes it and never gives it back. So a return either sees the stop
# done (the "stopped" mark) and restores One UI in place, or the switch never
# stops anything (2026-11-12 11:04: a return during step 3 found no mark yet,
# tidied up and ended; the switch then stopped the framework, xnuhost did not
# start, and nothing returned).
return_asked() { # true when a return was asked or has begun
    [ -e "$SESSION/return.request" ] && return 0
    [ "$(cat "$CTL/state" 2>/dev/null)" = starting ] || return 0
    return 1
}
end_for_return() { # <step>: the switch ends; the return (already under way, or the watcher's) restores
    if [ "$FRAMEWORK" = 1 ] && [ "$(cat "$CTL/stop.lock/switch" 2>/dev/null)" = "$$" ]; then
        release_stop_lock
    fi
    echo "A return to One UI was asked before $1 ($(head -c 200 "$SESSION/return.request" 2>/dev/null)): the switch ends here; the return restores One UI"
    exit 4
}
release_stop_lock() {
    rm -f "$CTL/stop.lock/switch"
    rmdir "$CTL/stop.lock" 2>/dev/null
}
return_asked && end_for_return "One UI's framework was stopped"

echo "=== [3/5] $(date +%T) Stopping the One UI framework ==="
# The boot screen first, so that it is up when One UI's windows go.
bootui_begin
# The stop lock (above): 15 s at most; a return holds it for good.
n=0
until mkdir "$CTL/stop.lock" 2>/dev/null; do
    [ ! -e "$CTL/stop.lock/return" ] || end_for_return "One UI's framework was stopped (a return holds the stop lock)"
    [ $n -lt 75 ] || end_for_return "One UI's framework was stopped (a return holds the stop lock)"
    sleep 0.2; n=$((n + 1))
done
if ! echo $$ 2>/dev/null > "$CTL/stop.lock/switch"; then
    release_stop_lock
    echo "Could not record the stop lock's owner. One UI's framework was left running."
    exit 4
fi
return_asked && { release_stop_lock; end_for_return "One UI's framework was stopped"; }
if [ "$(watchdog_target)" != "$WD_TARGET" ] || ! printf '%s\n' "$WD_TARGET" > "$CTL/watchdog.target" ||
    { [ "$FRAMEWORK" = 1 ] && ! { framework_recovery_ready && [ "$(volume_key_devices)" = "$KDEVS" ] &&
        [ "$(framework_service_pids)" = "$(cat "$B/framework_services")" ] &&
        { [ "$FRAMEWORK_REBOOT" = 1 ] ||
            [ "$(framework_watchdog_plan "$WD_TARGET")" = "$qualified" ]; } &&
        watchdog_uint "$(pidof system_server)" &&
        pidof system_server > "$CTL/watchdog.owner" &&
        { [ "$FRAMEWORK_REBOOT" = 1 ] ||
            printf '%s\n' "$qualified" > "$CTL/watchdog.plan"; } &&
        printf '%s FRAMEWORK_OWNS\n' "$WD_GEN" > "$CTL/watchdog.phase"; }; }; then
    release_stop_lock
    echo "The watchdog recovery target could not be recorded. One UI's framework was left running."
    $SH "$STAGE/oneios_return.sh" switch-watchdog-not-ready
    exit 4
fi
# xnuhost uses advise for MADV_HUGEPAGE on the guest's RAM. Save the bare
# active mode before writing and hold the stop lock through both operations
# so an early return can restore it even if the framework was never stopped.
SHMEM_EN="$T/sys/kernel/mm/transparent_hugepage/shmem_enabled"
shmem_mode=$(sed -n 's/.*\[\([a-z_]*\)\].*/\1/p' "$SHMEM_EN" 2>/dev/null)
case "$FRAMEWORK:$shmem_mode" in
    0:always|0:within_size|0:advise|0:never|0:deny|0:force)
        if printf '%s\n' "$shmem_mode" 2>/dev/null > "$B/shmem_enabled.tmp" &&
            mv -f "$B/shmem_enabled.tmp" "$B/shmem_enabled" &&
            [ "$shmem_mode" != advise ] && echo advise 2>/dev/null > "$SHMEM_EN"; then
            echo "shmem_enabled: $shmem_mode -> advise"
        fi ;;
esac
return_asked && { release_stop_lock; end_for_return "One UI's framework was stopped"; }
# BEGIN SM8850_DATA_CLAIM_AT_STOP_GATE
# Both start.lock and stop.lock are held. All panel wake, recovery readiness
# and return-request gates have passed. No writable guest mount/open or
# Framework stop has occurred. Spend the clone now, before crossing the
# stop boundary. A failure from this point on never clears the marker.
if [ "$FRAMEWORK" = 1 ] && [ "$FW_MODE" = run ]; then
    if [ -L "$STAGE/data.consumed" ] || [ -e "$STAGE/data.consumed" ] ||
        ! (umask 077; set -C; printf '%s %s\n' "$(boot_id)" "$FW_LAUNCH" > "$STAGE/data.consumed") ||
        ! chmod 600 "$STAGE/data.consumed"; then
        release_stop_lock
        echo "APFS_DATA_CLAIM=BLOCKED_BEFORE_FRAMEWORK_STOP"
        $SH "$SELF_RETURN" switch-data-claim-failed
        exit 4
    fi
    echo "APFS_DATA_CLONE=CONSUMED_ONE_SHOT_BEFORE_FRAMEWORK_STOP"
    # A cancellation racing the claim is still fail-closed: no stop,
    # and no permission to reuse the just-claimed Data.
    return_asked && { release_stop_lock; end_for_return "One UI's framework was stopped"; }
fi
# END SM8850_DATA_CLAIM_AT_STOP_GATE
# From here One UI's framework is down: the return starts it again. Without
# this mark the return only tidies up (a switch that ended before the stop).
if [ "$FRAMEWORK" = 1 ] &&
   ! printf '%s TRANSFER_PENDING\n' "$WD_GEN" > "$CTL/watchdog.phase"; then
    release_stop_lock
    $SH "$SELF_RETURN" switch-watchdog-not-ready
    exit 4
fi
[ "$FRAMEWORK" = 0 ] || echo "Watchdog: FRAMEWORK_OWNS -> TRANSFER_PENDING ($WD_TARGET)"
if ! stop_android_framework; then
    release_stop_lock
    echo "Framework stop failed. Starting guarded return."
    publish_return_request "Framework stop failed"
    $SH "$SELF_RETURN" switch-stop-failed
    exit 4
fi
if [ "$FRAMEWORK_REBOOT" = 1 ]; then
    # Exact first action of OneOS Android after stopping system_server,
    # oneos_switch.sh:1396-1398. A refused first magic close is logged and
    # the bounded feeder gets a chance to acquire the released FD. No
    # persist.vendor.softdog mutation: OneiOS has no safe persistent
    # post-reboot rollback for the original OneOS property fallback.
    if [ -n "$T" ]; then
        legacy_error=$("$T/bin/watchdog-io" ping V 2>&1) && legacy_written=1 || legacy_written=0
    else
        legacy_error=$(printf V 2>&1 > "$T/dev/watchdog") && legacy_written=1 || legacy_written=0
    fi
    if [ "$legacy_written" = 1 ]; then
        echo "OneOS legacy /dev/watchdog magic close: V written after Framework stop"
    else
        echo "OneOS legacy /dev/watchdog magic close refused ($legacy_error); feeder will retry for at most ${WD_FIRST}s"
    fi
fi
watchdog_started() {
    wd_begin=$(watchdog_now) || return 1
    printf '%s %s\n' "$WD_GEN" "$wd_begin" > "$CTL/feeder.arm.tmp" &&
        mv -f "$CTL/feeder.arm.tmp" "$CTL/feeder.arm" || return 1
    "$BB" setsid $SH "$SELF" --feed 8>&- </dev/null >/dev/null 2>&1 &
    wd_pid=$!
    while kill -0 "$wd_pid" 2>/dev/null; do
        watchdog_health >/dev/null
        case $? in 0) return 0 ;; 1) ;; *) return 1 ;; esac
        [ ! -e "$CTL/feeder.off" ] || return 1
        [ "$(watchdog_generation)" = "$WD_GEN" ] || return 1
        sleep 0.2
    done
    return 1
}
if ! watchdog_started; then
    watchdog_failed "the feeder did not become ready after stopping One UI"
    release_stop_lock
    $SH "$STAGE/oneios_return.sh" switch-watchdog-failed
    exit 4
fi
if [ "$FRAMEWORK" = 1 ]; then
    "$BB" setsid /system/bin/sh "$SELF" --stop-loop 8>&- </dev/null >/dev/null 2>&1 &
    echo $! > "$CTL/stop-loop.pid"
    fw_recover() {
        echo "Framework preparation failed: $*"
        publish_return_request "$*"
        release_stop_lock
        $SH "$SELF_RETURN" framework-deadline "$WD_GEN"
        exit 4
    }
    n=0
    until framework_pid_alive "$CTL/framework.stoploop"; do
        [ "$n" -lt 10 ] || fw_recover "the framework stop loop did not arm"
        sleep 0.2; n=$((n + 1))
    done
    framework_down || fw_recover "zygote services or system_server did not stop"
    for group in /sys/fs/cgroup/apps/uid_*; do
        [ -d "$group" ] || continue
        echo 1 > "$group/cgroup.kill" || fw_recover "could not drain $group"
    done
    n=0
    until framework_apps_empty; do
        [ "$n" -lt 15 ] || fw_recover "Android app process groups did not drain"
        sleep 0.2; n=$((n + 1))
    done
    [ "$(framework_service_pids)" = "$(cat "$B/framework_services")" ] ||
        fw_recover "an essential Android service changed"
    [ "$(timeout 3 service check inputflinger)" = 'Service inputflinger: not found' ] &&
        [ "$(timeout 3 service check input)" = 'Service input: not found' ] ||
        fw_recover "Android input services did not stop with system_server"
    grep -E '^(MemAvailable|SwapFree):' "$P/meminfo"
    # Capture the verified stop/drain milestone NOW, before the independent
    # CPU cap worker is started. Worker startup must never extend a 300s
    # request by several seconds.
    fw_tick=$(watchdog_now) || fw_recover "cannot timestamp verified Framework stop"
    fw_seconds=10
    if [ "$FRAMEWORK_REBOOT" = 1 ] && [ "$FW_MODE" = smoke ]; then
        [ "$(cat "$CTL/framework.duration" 2>/dev/null)" = "$FW_SMOKE_SECONDS" ] ||
            fw_recover "smoke duration marker missing or mismatched"
        fw_seconds=$FW_SMOKE_SECONDS
    fi
    if [ "$FW_MODE" = run ]; then
        # Exactly the requested 60..600s from verified Framework stop.
        # Independent framework-deadline survives guest/USB failures.
        fw_seconds=$FW_DURATION
        [ "$(cat "$CTL/framework.duration" 2>/dev/null)" = "$FW_DURATION" ] ||
            fw_recover "bounded duration marker missing or mismatched"
        [ "$(awk '/^MemAvailable:/ {print $2}' "$P/meminfo")" -ge 5500000 ] ||
            fw_recover "available memory is below the benchmark minimum"
        framework_configure || fw_recover "could not set and verify vm.max_map_count"
    fi
    # The prearmed root worker has already been observing Framework state;
    # it can set its FIRST strict CPU ceiling immediately when
    # system_server is absent, before app-group drain and watchdog handoff.
    # Here only confirm its current, enforced heartbeat before guest launch.
    if [ "$FW_MODE" = run ]; then
        if [ "$FW_SOFT_THERMAL_OFF" = 1 ]; then
            # Explicit no-guard 180s: no root CPU cap worker is launched.
            # The kernel/vendor/firmware may still throttle the CPU.
            echo "CPU_THROTTLE=OFF_NO_ROOT_CAP_WORKER"
        else
            n=0
            until framework_thermal_cap_healthy; do
                [ "$n" -lt 25 ] || break
                sleep 0.2; n=$((n + 1))
            done
            framework_thermal_cap_healthy ||
                fw_recover "prearmed root CPU throttle did not activate after Framework stop"
            printf '%s\n' "$WD_GEN" > "$CTL/thermal.cap.required" ||
                fw_recover "could not mark mandatory CPU thermal throttle"
            if [ "$(cat "$CTL/framework.cpu-budget" 2>/dev/null)" = hybrid-v1-180s ]; then
                echo "CPU_THROTTLE=PREARMED_ACTIVATED_POST_STOP_CFS_V1; HYBRID_FREQ_CEILING_40_PERCENT; TARGET_45_70C; HARD_80C_RELEASE_70C; EMERGENCY_GUARD_SEPARATE"
            else
                echo "CPU_THROTTLE=PREARMED_ACTIVATED_POST_STOP_STRICT_60_40_28_18_12_8; TARGET_30_70C; CPU_75C_THROTTLE_NOT_RETURN"
            fi
        fi
    fi
    printf '%s\n' "$((fw_tick + fw_seconds))" > "$CTL/framework.deadline.tmp" &&
        mv -f "$CTL/framework.deadline.tmp" "$CTL/framework.deadline" ||
        fw_recover "could not arm the phase deadline"
    echo "Framework stopped, app groups drained and Android input absent at uptime $fw_tick. Deadline: $((fw_tick + fw_seconds))"
    if [ "$FRAMEWORK_REBOOT" = 1 ]; then
        printf '%s\n' "$WD_GEN" > "$CTL/framework.takeover-confirmed" ||
            fw_recover "could not record verified Framework stop"
    fi
    if [ "$FW_MODE" = smoke ]; then
        echo running > "$CTL/state" || fw_recover "could not record smoke state"
        release_stop_lock
        exit 0
    fi
else
    release_stop_lock
    # system_server is gone, so nothing of One UI writes the clock caps any more.
    clocks_tops
    "$BB" setsid /system/bin/sh "$SELF" --stop-loop </dev/null >/dev/null 2>&1 &
    echo $! > "$CTL/stop-loop.pid"
fi
# UsbDeviceManager went with system_server: from here the USB watcher keeps
# adb on the gadget, across unplug and replug (control/usb.log).
if [ "$FRAMEWORK" = 1 ]; then
    echo "USB watcher: existing adbd and USB state retained"
elif [ "$(conf "$CTL/base/usb" adb)" = 1 ]; then
    "$BB" setsid /system/bin/sh "$SELF" --usb-watch </dev/null >>"$CTL/usb.log" 2>&1 &
    echo "USB watcher: started (log $CTL/usb.log)"
else
    echo "USB watcher: not started (USB debugging was off in One UI)"
fi
echo "One UI's zygote: $(getprop init.svc.zygote); system_server: $(pidof system_server 2>/dev/null || echo gone); surfaceflinger $(pidof surfaceflinger) kept"

# From here a return finds the mark and restores One UI in place.
return_asked && end_for_return "xnuhost was started"

echo "=== [4/5] $(date +%T) Starting xnuhost ==="
screen status "Starting xnuhost"
# A new mount namespace made from init's; --inner binds the stage over /data
# there and execs xnuhost, so the pid it writes is xnuhost's own.
"$BB" setsid "$BB" unshare -m /system/bin/sh "$SELF" --inner 8>&- </dev/null >>"$SESSION/xnuhost.log" 2>&1 &
# Waited for by its progress, not for a fixed time: until it wrote the pid, for
# as long as that shell runs (control/inner.pid), 30 s at most. A shell that
# ended is not waited for; its trace in the log says where it stopped.
n=0
inner_wait=150
[ "$FRAMEWORK" = 0 ] || inner_wait=40
while [ $n -lt "$inner_wait" ] && [ ! -s "$SESSION/xnuhost.pid" ]; do
    [ "$FRAMEWORK" = 0 ] || ! return_asked || end_for_return "xnuhost was ready"
    if [ $n -ge 10 ]; then
        ip=$(cat "$CTL/inner.pid" 2>/dev/null)
        [ -n "$ip" ] && kill -0 "$ip" 2>/dev/null || break
    fi
    sleep 0.2; n=$((n + 1))
done
XP=$(cat "$SESSION/xnuhost.pid" 2>/dev/null)
XNS=$(readlink "/proc/$XP/ns/mnt" 2>/dev/null)
if [ -z "$XP" ] || [ -z "$XNS" ] || [ "$XNS" = "$INIT_NS" ]; then
    echo "!!! xnuhost did not start after $((n / 5)) s (pid '${XP}', namespace '${XNS}'); the last lines of $SESSION/xnuhost.log: $(tail -n 6 "$SESSION/xnuhost.log" | tr '\n' '|')"
    screen status "xnuhost did not start: $(grep . "$SESSION/xnuhost.log" 2>/dev/null | tail -n 1)"
    echo failed > "$CTL/state"
    [ "$FRAMEWORK" = 0 ] || release_stop_lock
    # One UI's framework is down: never left so. The return, from here (the
    # watcher returns too on this state, or may have ended already; the return
    # takes one caller at a time).
    $SH "$STAGE/oneios_return.sh" switch-failed
    exit 4
fi
# The switch's own record of the two, where the guest cannot write: what the
# watcher and the return go by.
echo "$XP" > "$CTL/xnuhost.pid"
echo "$XNS" > "$CTL/mntns"
[ "$FRAMEWORK" = 1 ] || echo running > "$CTL/state"
echo "xnuhost: pid $XP in mount namespace $XNS, log $SESSION/xnuhost.log"

# The guest's screen: the runtime's display helper, when it carries one. It
# runs here, on One UI's side (it needs surfaceflinger's binder and the
# framework's classes, which xnuhost's namespace is not for), as root, from
# the runtime the preflight hashed. It waits for xnuhost's display.sock, shows
# the frames on a top layer and leaves when the socket closes. It is in the
# session's cgroup, so the return ends it with the rest, and by its pid
# (control/, where the guest cannot write; its log is there too). Nothing
# waits for it: without it the session runs with a dark screen.
DH="$STAGE/runtime/bin/oneios-display"
if [ -f "$DH" ] && [ ! -L "$DH" ] && [ -x "$DH" ] && root_only "$DH"; then
    # This session's log only: the boot screen's hand-off (display_up) reads its markers, and a
    # "first frame posted" of an earlier session must not end this session's boot screen early.
    [ -f "$CTL/display.log" ] && mv -f "$CTL/display.log" "$CTL/display.log.1" 2>/dev/null
    if [ "$FRAMEWORK" = 1 ]; then
        "$BB" setsid "$DH" --socket "$SESSION/display.sock" --wait 30 8>&- </dev/null >>"$CTL/display.log" 2>&1 &
    else
        "$BB" setsid "$DH" --session "$SESSION" --takeover --wait 60 </dev/null >>"$CTL/display.log" 2>&1 &
    fi
    DP=$!
    echo "$DP" > "$CTL/display.pid"
    echo 0 2>/dev/null > "/proc/$DP/oom_score_adj"
    echo "$DP" 2>/dev/null > /sys/fs/cgroup/oneios_session/cgroup.procs
    echo "Display helper: pid $DP, log $CTL/display.log"
else
    echo "Display helper: the runtime has none (bin/oneios-display); the guest's screen is not shown"
fi

if [ "$FRAMEWORK" = 1 ]; then
    return_asked && end_for_return "the experimental display was ready"
    echo running > "$CTL/state" || fw_recover "could not record running guest"
    release_stop_lock
fi
echo "=== [5/5] $(date +%T) Session running ==="
echo "Auto-return to One UI: when xnuhost ends, on $SESSION/return.request, or without $SESSION/ready after ${ONEIOS_RETURN_MAX:-600}s"
echo "=== ONEIOS SESSION LAUNCHED ==="
