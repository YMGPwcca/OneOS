# OneiOS watchdog recovery

## New SM8850 physical evidence (2026-11-20)

**The original preflight-only SM8850 limitations below are historical, not
proof that an iOS guest was never booted.** The explicit root-only legacy
watchdog profile has now stopped Android Framework, booted hosted iOS 27.0.1
and shown the guest's first frame. The captured `xnuhost` process ran
~600.6 s; after it stopped, the Android boot reason was
`reboot,oneios-sm8850-reboot-return`. A prior first full-run attempt
failed in the inner mount namespace and requested an immediate
`switch-failed` reboot; later F2FS/BusyBox isolated mount testing passed
and that launch bug was repaired.

**This evidence does NOT identify the SM8850 watchdog driver/timeout, prove
its first-ping or handback properties, prove the exact deadline requester,
or exclude a human/manual return step.** Following the latest real full
run, DirtyFrag's ephemeral root was lost, so the unprivileged ADB receipt
could not read the root-owned `return.outcome`. Keep
`WATCHDOG_QUALIFICATION=UNVERIFIED_REBOOT_ONLY` and
`UNASSISTED_RETURN_TO_ONEUI=NOT_VERIFIED`.
Do not replace the device-side deadline, lower thermal guard, relax the
root app restrictions or open watchdog nodes just to claim qualification.

The exact root-only SM8850 mode is **separate** from the normal S24
switch path and OneOS Android **app/UI/job**, which remain blocked for
SM8850. The full run uses `xnuhost --mode bench --set bridges=0`, so its
OneiOS thermal bridge is **inactive** while the Linux kernel/firmware
thermal protection persists. The user reported considerable heat.
See [the 2026-11-20 experiment ledger](SM8850_ONEIOS_FULL_RUN_STATUS.md).



## SM-S948B source provenance

The target is Samsung Galaxy S26 Ultra **SM-S948B / m3q / SM8850**, One UI 9.0
on Android 17, build **S948BXXS4BZIG**, with kernel release
`6.12.69-android16-6-pb4d3caf-abogkiS948BXXS4BZIG-4k`. Samsung lists that
firmware and Android version in its [official release notes](https://doc.samsungmobile.com/SM-S948B/037159260310/wel.html).

The Samsung Open Source Release Center returned a Cloudflare challenge (HTTP
403) for searches by both [model](https://opensource.samsung.com/uploadSearch?searchValue=SM-S948B)
and [complete build](https://opensource.samsung.com/uploadSearch?searchValue=S948BXXS4BZIG).
The exact Samsung archive, archive checksum, corresponding build manifest,
device tree and configuration, and build IDs of the deployed modules remain
unverified. A firmware release number and Android GKI family cannot establish
which vendor driver registered a particular watchdog. The Linux and SM8650
references below explain their own implementations only.

| Owner-supplied evidence from S948BXXS4BZIG | What it establishes |
| --- | --- |
| `system_server` holds `/dev/watchdog` (`10:130`). The numbered node `/dev/watchdog0` is `242:0`, with a `watchdog0` sysfs entry. | The process holds the legacy character node. The numbers are consistent with Linux watchdog-core aliasing. They identify neither the S26 driver nor a separate second watchdog. |
| The loaded modules include `watchdog`, `softdog`, `qcom_soc_wdt`, `qcom_wdt_core`, and `sec_qc_qcom_wdt_core`. | Software and Qualcomm watchdog components coexist. The module list alone does not map either node to its operations. |
| `msm_watchdog_data` reports pets about 9.472 s apart. | This is evidence of the Qualcomm SoC watchdog activity. The interval is neither the watchdog timeout nor a userspace feeding schedule for `/dev/watchdog`. |
| `max77775_chg_set_wdtmr_kick` appears in the charger evidence. | This is a separate MAX77775 charger watchdog path. It does not identify a system watchdog character device. |
| `identity`, `state`, `timeout` and `nowayout` were unavailable. | The active driver and its release policy remain unknown. Upstream can omit the attributes when built without `CONFIG_WATCHDOG_SYSFS`. |
| USB ADB and the physical volume chord were verified. `cgroup.kill` is absent. | These establish transport and input observations. Phase 1 tested process cleanup without `cgroup.kill` in a fake phone. Hardware watchdog handoff and full return remain open. |

Confidence is high in the observed userspace holder and in distinguishing the
SoC and charger activity. The device-number relationship is consistent with,
but does not prove, the Linux alias mapping on this build. Confidence in the
S26 endpoint's driver, timeout, and stop policy is insufficient for a handoff.

## Linux watchdog reference behavior

The reference is upstream Linux [v6.12 `watchdog_dev.c`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/watchdog/watchdog_dev.c?h=v6.12),
[`watchdog_core.c`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/watchdog/watchdog_core.c?h=v6.12)
and [`softdog.c`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/watchdog/softdog.c?h=v6.12).
The separate [SM8650 tree at `809f7edaad95be2f60ce09f577fe5104d8940214`](https://github.com/samsung-sm8650/android_kernel_samsung_sm8650/tree/809f7edaad95be2f60ce09f577fe5104d8940214)
contains byte-identical `softdog.c` and a watchdog core with the same open,
write and close rules. The SHA-256 of the two `softdog.c` files was
`1ac2045ce916045b9e7f608e583c673ef230dcec39ae5218ff70b29e066dc6ad`.
Its [e3q defconfig](https://github.com/samsung-sm8650/android_kernel_samsung_sm8650/blob/809f7edaad95be2f60ce09f577fe5104d8940214/arch/arm64/configs/oem/e3q_defconfig)
selects the software watchdog module but does not select `CONFIG_WATCHDOG_SYSFS`.
This reference does not establish the final configuration or source of the
deployed S24 or S26 binaries.

- `watchdog_dev_register` publishes `watchdogN` for a registered driver.
  Device 0 can additionally register the legacy misc node. Both routes
  share `watchdog_core_data` and an exclusive-open bit. A second open can
  return `EBUSY` across aliases. A successful open itself can start or
  refresh the timer, including an open made only to query an ioctl.
- `watchdog_write` clears any previously recorded magic-close permission,
  scans a nonempty write for the byte `V`, and invokes the keepalive path.
  An ordinary nonempty write can therefore ping without authorizing a stop.
  `WDIOC_KEEPALIVE` also requests a ping where the driver advertises it.
  The core uses the driver's ping operation or its start operation as a
  fallback. The reference softdog uses `softdog_ping` to rearm an hrtimer.
- `watchdog_release` can call the stop operation after a magic close or on
  a driver without `WDIOF_MAGICCLOSE`. `nowayout` blocks the ordinary stop
  path. If an active watchdog does not stop, the reference release path
  attempts a keepalive and leaves it armed. A shell redirection closes the
  descriptor immediately after the write, so a successful write of `V` can
  end with the timer stopped.
- Reference softdog advertises `WDIOF_MAGICCLOSE` and requests
  stop-on-reboot. The watchdog core can override that setting using its
  `stop_on_reboot` parameter. Its registered reboot notifier calls the
  driver's stop operation directly on the applicable orderly reboot, halt
  or poweroff events. That behavior is separate from closing a userspace
  descriptor, and does not establish behavior during a panic or emergency
  reset on the S26.

## OneiOS behavior

The old script tried default watchdog paths, paths inferred from
`system_server` file descriptors, and sysfs identities containing “soft.”
It repeatedly opened, wrote `V` and closed each path. Duplicate names could
refer to one endpoint, the opens could race a live owner, a successful write
could disarm a timer at close, and failures could leave the session running.
The return treated the presence of a new `system_server` PID as the end of
the watchdog handoff.

The new path supports only the existing S24 Ultra switch profile. A read-only
preflight requires one active endpoint labeled `Software Watchdog`, a
matching numbered character device and sysfs device number, proof of a
`system_server` descriptor, and a reported timeout of at least 100 seconds.
The minimum comes from the historical S24 100-second softdog window. The
selector accepts the legacy alias for watchdog0 only when the misc device
metadata also matches. Extra watchdog descriptors or unavailable evidence
cause refusal before stopping One UI.

The switch rechecks the selection under the stop lock. Once One UI has
stopped, the feeder opens one numbered node, verifies the opened descriptor,
and uses an ordinary nonempty write every two seconds. Each successful write
atomically publishes a heartbeat with the session generation, PID, process
start ticks and whole seconds from Linux boot uptime. Readiness follows the
first timely success. A failed or blocked write cannot advance the heartbeat.
The watcher treats a missing or invalid heartbeat after readiness, a changed
PID identity, a late first ping, and lost progress as recovery requests.
The first-ping threshold is three uptime seconds and the freshness threshold
is five uptime seconds. These are S24 software supervision thresholds, with
whole-second resolution and poll and scheduling latency. They establish no
SM8850 deadline. The first fault and existing return request are preserved.
While the return is in progress its guard continues to record lost progress
until the handoff disarms supervision. Early cancellation leaves the
running framework in control.
The normal return releases the feeder before a command that could restart
zygote, with a bounded wait, and confirms the returned `system_server`
holds the same active watchdog before recording in-place success. The
`--watchdog-probe` read-only mode applies the same S24 scope and metadata
checks. The OneiOS code does not send magic close or change watchdog
settings, including `nowayout` and `stop_on_reboot`.

The fake-phone tests exercise alias selection, refusal, failure, stop lock
and handback logic. Hardware remains necessary to verify S24 metadata
availability, SELinux access to the numbered node, scheduling margin, and
actual resumed keepalives. S24 builds that hide the required attributes now
refuse the switch. The heartbeat can detect a stall, but a blocked operation
can still outlive the timeout. A recovery request cannot guarantee timely
recovery. The SM8850 root and app restrictions stay in place.

## Safest next physical validation

With separate authorization and One UI running, passively correlate the
already-open `system_server` descriptor via `readlink`, descriptor
`fdinfo`, and device numbers from `stat` with `/sys/dev/char`,
`/sys/class/misc/watchdog`, the numbered watchdog's parent driver link
where present, and the vendor module build IDs. Compare with the Samsung
archive for the **full** build and kernel release when available. Capture
already exposed boot logs and module metadata. Avoid opening any watchdog
node, including through `wdctl`, to collect the inventory. The next
milestone is an attributable driver-to-node map while the existing owner
continues feeding.
