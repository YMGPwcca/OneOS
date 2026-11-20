# Watchdog and reboot-return · SM8850

**Galaxy S26 Ultra / OneiOS 27 · recovery research, not certification**

[← Handbook](README.md) · [Full-run evidence](SM8850_ONEIOS_FULL_RUN_STATUS.md) · [Device facts](SM8850_PORT.md) · [OneiOS experiment](oneios.md)

> [!CAUTION]
> **WATCHDOG_QUALIFICATION=UNVERIFIED_REBOOT_ONLY.** Device-side watchdog and reboot requests have been observed. The actual driver mapping, hardware timeout, post-transfer keepalive and independently unassisted return have **not** been certified. Avoid opening watchdog devices for casual inspection: an open/close can change their state.

## Latest physical observations

| Event | Evidence | Interpretation |
| :--- | :--- | :--- |
| Earlier reboot-only Framework smoke | Framework-stop marker and a device-side deadline request; later Android returned | **Observed reboot request**, not driver/timeout qualification |
| First full takeover | BusyBox remount failed before `xnuhost` exec; OneOS requested `switch-failed` return | Recovery script activated early, not an iOS crash |
| Fixed staging | On-device F2FS/BusyBox private mount probe and hash-verified APFS Data rearm PASS | Stage safety verified for those exact checks |
| Second full takeover | iOS guest ready, first frame, and ~600.6 s host execution | Guest ran; no proof of exactly which return path completed |
| New Android boot | `sys.boot_completed=1`, reason `reboot,oneios-sm8850-reboot-return` | Named reboot was observed; ephemeral root loss blocked the root-owned outcome check |

## What the watchdog inventory established

| Evidence | Interpretation and limitation |
| :--- | :--- |
| `system_server` holds `/dev/watchdog` (`10:130`) | The legacy userspace character node has an active owner; not proof of its kernel driver |
| `/dev/watchdog0` appears as `242:0` | Could be a watchdog-core numbered alias; shared backend not verified |
| Modules include `watchdog`, `softdog`, `qcom_soc_wdt`, `qcom_wdt_core`, `sec_qc_qcom_wdt_core` | Multiple software/Qualcomm components coexist; module names alone cannot map the endpoint |
| `msm_watchdog_data` pets about 9.472 s apart | Evidence of Qualcomm SoC watchdog activity, **not** the userspace node's configured timeout |
| MAX77775 charger watchdog traces | A separate charger watchdog mechanism, not proof of the system watchdog alias |
| `identity`, `timeout`, `state`, `nowayout` unavailable in sampled sysfs | Driver ownership and safe handoff policy remain unknown |

### Why opening the node is not a passive test

The Linux watchdog core may have exclusive-open semantics. A successful `open()` can activate the timer; writes can request keepalives; writing `V` may authorize a **magic close** and stopping on release if supported. In other configurations the timer remains running. A failed `open()` can report `EBUSY` when another owner already holds the same device. Actual behavior on this firmware must be established from source, owner descriptors and controlled evidence, **not assumed from generic Linux examples**.

Relevant upstream documentation: [Linux watchdog userspace API](https://www.kernel.org/doc/html/latest/watchdog/watchdog-api.html) and kernel watchdog-core source. The exact matching Samsung vendor archive and module build configuration are still unavailable for independent verification.

## Current OneOS experiment

1. The strict device/firmware, image, root and recovery checks run while One UI is intact.
2. A separately acknowledged **legacy watchdog candidate** is used only in the exact SM8850 experimental path; the normal OneOS app's OneiOS device gate remains blocked.
3. The Framework stop, watcher, independent deadline and OneOS reboot-return path are armed as a bounded session.
4. Root-only guest launch uses 8 vCPUs, 4 GiB memory, GPU auto, SHM display, and `bench/bridges=0` for isolated touch. **OneiOS's thermal bridge is inactive in this profile**; kernel/vendor thermal limits remain.
5. On deadline or failure, the path requests mandatory named reboot (`oneios-sm8850-reboot-return`); no in-place SM8850 handback is promised.
6. After reboot, a rootless ADB receipt can establish a new Android boot. It **cannot** prove the exact authenticated requester, independent watchdog handback or no human intervention when DirtyFrag root is absent.

## Remaining evidence required

- [ ] Map the exact held character device through its major/minor, sysfs parent driver, firmware-matched module build ID and source implementation.
- [ ] Establish its true timeout and semantics for `open`, keepalive, magic close, stop and reboot without disturbing a live owner.
- [ ] Inspect the existing, root-owned `return.outcome`, `return.log`, watchdog feeder/watcher logs and original run token **read-only**.
- [ ] Establish which helper actually triggered the final reboot and its elapsed time relative to Framework stop.
- [ ] Demonstrate normal One UI boot without a manual Download Mode detour; rootless boot reason alone is insufficient.
- [ ] Implement and validate a scoped thermal monitor/guard before another long or hot iOS run.

> [!WARNING]
> Pressing both volume keys while Samsung USB is attached may enter Download Mode during reboot. Never treat the volume chord as a safe in-place SM8850 return procedure. Keep one-shot Data isolation and the independent deadline intact.

## Verification strategy

The [cross-repository recovery acceptance matrix](https://github.com/YMGPwcca/OneiOS/blob/feat/oneios-sm8850-m3q/docs/SM8850_RECOVERY_ACCEPTANCE.md) tracks the independently required receipts and fail-closed outcomes. Documentation itself cannot satisfy those checks.

Prioritize the saved logs and local CachyOS tests. When available, read `/proc/<holder>/fdinfo`, `/sys/dev/char` metadata and firmware module provenance without opening the watchdog character device. Distinguish independent hardware acceptance from a script's own confirmation marker. New destructive tests require separate user authorization and completed thermal gating.

---

**Next:** [Physical experiment status](SM8850_ONEIOS_FULL_RUN_STATUS.md) · [OneiOS safety backlog](https://github.com/YMGPwcca/OneiOS/blob/feat/oneios-sm8850-m3q/docs/TODO.md)
