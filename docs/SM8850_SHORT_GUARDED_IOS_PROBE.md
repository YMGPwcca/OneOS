# SM8850 real short iOS takeover probe — 90 seconds (opt-in)

**Status:** integrated into the OneOS `oneios_switch.sh` takeover path on the P0 draft branch; user/device verification of this exact new revision **PENDING**. This is **not** production-certified P0 and does **not** unlock the 600-second `run` profile.

## Why this exists

Physical S26 Ultra P0 work already verified 28 live CPU/GPU/DDR zones, standalone BAT/LRP/board AP readings, root observer + independent PID supervisor, a detached trial after the initiating ADB shell ended, and historical reboot-only return markers. The 600s iOS guest had earlier caused severe warmth/stutter; repeating it without a functioning thermal return is inappropriate. The short probe exercises actual xnuhost with a smaller bounded exposure and reuses the existing reboot-only recovery path.

## Explicit one-command mode

Run from a **pinned checkout/archive of this OneOS branch** on CachyOS, with the S26 Ultra physically accessible and USB debugging already authorized:

```bash
python3 scripts/phone/sm8850-takeover-short-probe.py --run-90s \
  --adb "$HOME/Android/Sdk/platform-tools/adb" \
  --output "$HOME/projects/OneiOS/out/sm8850/short-ios-probe"
```

Default `sm8850-takeover-short-probe.py` is a **zero-ADB audit**. Optional `--prepare-probe` uploads trusted code and a newly surveyed boot-bound manifest but does **not** stop Framework. **Only `--run-90s` initiates the disruptive takeover**. It runs exactly one `--framework-session probe` using the explicit risk acknowledgment `I_ACCEPT_SM8850_SHORT_TAKEOVER_90S_RISK`.

## What the OneOS code now does

1. On intact stock SM-S948B/m3q/S948BXXS4BZIG One UI: inventory all genuine CPU/GPU/DDR thermal-zone types (nonrecursive bounded scan) and verify the full current-boot mapping. Create the same non-executable manifest used by the accepted 28-zone observer.
2. Upload a **pinned** `oneios_switch.sh`, `oneios_sm8850_thermal_takeover_guard.sh` and manifest to a fresh temporary staging directory; SHA-check, install as root under `/data/adb/oneios-m3q-framework`, verify post-install SHA and preserve a copy of the previous switcher under `logs/`. Refuse active sessions or changing device identity.
3. Call existing `--framework-check probe` and require `PREFLIGHT OK`. It checks the original iOS runtime, one-shot independent APFS Data clone, real 3D/8-core image, genuine legacy reboot-only watchdog holder, prior recovery-smoke record, protected helpers, full device identity, boot-specific sensor manifest and current temperatures. Failure is BEFORE Framework stop.
4. Start a host witness **before** the experiment. The witness records the current healthy boot ID. The user-requested real `--framework-session probe` then starts in a separate root session with redirected logs.
5. The switch stages **an independent root thermal monitor before stopping One UI's Framework**, alongside existing watcher and `framework-deadline`. The monitor reads all mapped real CPU/GPU/DDR sensors and Samsung BAT/LRP/board AP every cycle, checks types and boot, and atomically emits boot/generation/PID-birth/sequence/uptime heartbeat. The existing watcher and deadline each treat the monitor's death, stale heartbeat or fault as a **reboot-only return request**.
6. **EARLY EXPERIMENT ABORT cutoffs**, intentionally conservative *trial-specific* numbers, not vendor-certified critical temperatures: CPU/GPU/DDR 55 C, battery 38 C, LRP/board AP 42 C. Missing sensor, type mismatch and stale heartbeat also abort early; the independent existing return path triggers the reboot. These values cannot be reused to certify production thermal protection.
7. `probe` uses **90 seconds maximum from verified Framework stop**, not the previous 600 seconds. It still uses the genuine 8-vCPU iOS guest, display helper, real GPU/touch path and the APFS one-shot clone. Successful startup and first frame are **not guaranteed** within 90 seconds; preflight can decline a previously consumed clone.
8. The external host watches for ADB disconnect followed by an **independent new boot ID and fully restored One UI**, then records historical return correlation and launch-log evidence separately. Missing/uncorroborated evidence must not be called a successful guest boot. User must attest whether any physical restart keys were used.

## Hard safety boundary

- The 600-second `--framework-session run` **remains unconditionally blocked by source**. Probe does not remove that lock or grant a blanket production safety claim.
- The OneOS legacy software watchdog and physical unassisted reboot have **not** been independently qualified. Recovery could fail; the device may become unresponsive or require manual forced restart. Never call this production-safe.
- **Do not press both volume keys while USB-connected**: Samsung may enter Download Mode. If automatic return fails and the device is unresponsive, Samsung Side/Power + Volume Down for more than seven seconds is the manual last-resort forced restart, not proof of auto recovery.
- Avoid starting with a hot battery/phone; leave it on a hard ventilated surface, not covered/charging under heat. Any unexpected heat, burning smell, swelling or repeated restarts warrants stopping the experiment.
- All source modifications remain on draft PRs until the short physical probe and recovery are reviewed. No further sensor inventory loops are required as a separate user action.
