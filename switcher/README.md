# OneOS switcher — Android guests and experimental OneiOS

**OneOS · switcher source and operational scope · Samsung Galaxy S26 Ultra is research-only for OneiOS**

[← OneOS documentation](../docs/README.md) · [Project home](../README.md) · [SM8850 physical evidence](../docs/SM8850_ONEIOS_FULL_RUN_STATUS.md) · [Watchdog and recovery](../docs/oneios-watchdog-recovery.md)

> [!CAUTION]
> **Do not follow historical OneLineage switch commands on the S26 Ultra.** The Android-guest switcher and the OneiOS root-only Framework experiment are separate paths. The OneOS app does **not** authorize OneiOS switching on SM-S948B. Never disable SELinux, change system-wide governors, open watchdog character devices for testing, or interpret a new Android boot as independently verified recovery.

## Source layout

| Component | Intended function |
| :--- | :--- |
| `assets/oneos_switch.sh` | Normal OneOS **Android guest** transition; not the OneiOS SM8850 admission gate |
| `assets/guest_prepare.sh`, `assets/guest_start.sh` | Prepare and start the Android guest's userspace and storage |
| `assets/oneios_switch.sh`, `assets/oneios_return.sh` | Separate OneiOS session and return implementation; its **exact SM8850 root-only** experiment requires strict device/firmware checks, trusted stage, independent recovery supervision and explicit legacy-watchdog risk acknowledgment |
| `../app-android/` | The OneOS Android app, device eligibility, package selection and UI/job gates; OneiOS on SM8850 remains blocked |

## S26 Ultra / SM8850 · what actually ran

- Device: **SM-S948B / m3q / SM8850**, firmware **S948BXXS4BZIG**, Android 17 / One UI 9 and SELinux enforcing.
- The isolated root-only stage is **`/data/adb/oneios-m3q-framework`**, not the ordinary OneOS Android-guest stage `/data/local/tmp/oneos` or the historical iOS app stage `/data/local/tmp/oneios`.
- The physical OneiOS experiment stopped Android Framework without replacing the Linux kernel, launched a hosted XNU guest with eight **allowed** CPUs, and observed guest-ready, the first displayed frame, KGSL 3D traffic and approximately 600.6 seconds of `xnuhost` execution.
- Severe lag and heat were reported. The `bench/bridges=0` profile **does not run OneiOS's regular thermal bridge**. The independent watchdog identity/timeout and fully unattended One UI return remain unverified.
- The experiment uses **mandatory reboot-return**; there is no demonstrated SM8850 in-place handback. A USB-connected Volume Up + Volume Down chord may enter Samsung Download Mode.

See [current physical evidence](../docs/SM8850_ONEIOS_FULL_RUN_STATUS.md), [root-only session contract](../docs/oneios.md), and the [OneiOS engineering backlog](https://github.com/YMGPwcca/OneiOS/blob/feat/oneios-sm8850-m3q/docs/TODO.md) before proposing a new test. Do not repeat the long full takeover until thermal and recovery gates are independently satisfied.

## Historical origin and attribution

OneOS grew from **WeWaffles' OneLineage**, a Samsung Android GSI switcher. Earlier versions used `switch_to_lineage.sh`, `master_prepare.sh`, `master_inner.sh` and a stage named `/data/local/tmp/lineage_stage`. Those names and the original OneLineage build instructions are **historical**, not the current repository's operational interface.

Original project and historical instructions: [WeWaffles/OneLineage](https://github.com/WeWaffles/OneLineage). Retain this credit when discussing derivative code; the exact changes from the original remain visible in Git history. The original project's commands and device claims must not be transplanted to the SM8850 OneiOS experiment.
