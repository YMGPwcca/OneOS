# Galaxy S26 Ultra · SM8850 port

**OneOS companion / OneiOS 27 · Samsung SM-S948B / m3q**

[← Handbook](README.md) · [Physical run](SM8850_ONEIOS_FULL_RUN_STATUS.md) · [OneiOS workflow](oneios.md) · [Watchdog evidence](oneios-watchdog-recovery.md)

> [!IMPORTANT]
> **Root-only experiment observed; app still blocked.** The iOS 27.0.1 guest reached first frame and ran about 600.6 s. The phone lagged and overheated noticeably. Normal OneOS app activation remains **BLOCKED**; independent watchdog and unassisted recovery are still **NOT VERIFIED**.

## Target identity

| Attribute | Observed configuration |
| :--- | :--- |
| Device | Samsung Galaxy S26 Ultra **SM-S948B**, codename **m3q**, board canoe |
| Firmware | **S948BXXS4BZIG**, Android 17 / One UI 9 |
| Kernel | **6.12.69** (Android GKI branch); 4 KiB pages |
| Root/security | KernelSU/DirtyFrag experimental root, SELinux enforcing |
| CPU | 8 host CPUs: IDs 0–5 capacity 741; IDs 6–7 capacity 1024 |
| Reported CPU limits | 0–5: `3628800` kHz; 6–7: `4742400` kHz **cpuinfo** maxima, not operating clocks under load |
| GPU | KGSL chip `0x44050a00`, GPU ID 6860; real 3D traffic observed in guest experiment |

## Validation matrix

| Capability | Status | What this proves |
| :--- | :--- | :--- |
| GPU hardware diagnostics | **PASS (device probes)** | KGSL routes, submissions and large/fragmented memory tests completed without recorded GPU faults |
| Framework stop | **OBSERVED** | The root-only OneOS supervisor stopped Android Framework |
| Guest startup | **OBSERVED** | iOS 27.0.1 ready marker, first frame and ~600.6 s hosted process lifetime |
| GPU guest acceleration | **OBSERVED** | KGSL memory imports and retired backboardd fence; not comprehensive Vulkan support |
| Memory | **OBSERVED** | 4 GiB guest prefaulted/locked; no guest swap in captured sample |
| User experience | **NOT ACCEPTED** | Severe lag and heat; FPS and throttling timeline not fully measured |
| Recovery | **PARTIAL EVIDENCE** | A new Android boot and named reboot reason were seen; requester/unassisted path not verified |
| OneOS app / UI switching | **BLOCKED** | Device model and job checks do not allow normal iOS switch |

## Explicit safety boundaries

- The experimental root command is scoped to the exact model, firmware, signed stage and separately acknowledged legacy-watchdog risk.
- The normal OneOS app's OneiOS device allowlist remains independent. Discovering hardware or displaying an iOS card is not authorization to switch.
- A permitted host CPU mask `0–7` is not evidence that eight vCPUs were pinned to distinct cores.
- The `bench/bridges=0` full session does not initialize OneiOS's separate thermal bridge or normal CPU placement bridge. Qualcomm/Samsung kernel and firmware thermal controls remain present.
- The root-only SM8850 return mechanism is **mandatory reboot**. It cannot be treated as a proven in-place handback.
- A fresh APFS Data clone is required per session; consumed snapshots remain preserved and are never reused.

## Next acceptance milestones

1. **P0:** independent thermal measurements and bounded guard without activating unrelated hardware bridges.
2. **P0:** inspect archived watcher/return outcome with root read-only; attribute the actual 600-second return and qualify the watchdog separately.
3. **P1:** profile Spotlight, host task traps, page faults and controlled CPU pairing.
4. **P2:** correlate GPU fences, display posts and input-to-frame timing.
5. **P3:** run local CI, short controlled trials and explicit independent recovery acceptance before considering UI enablement.

---

**Source of truth:** [SM8850 experiment ledger](SM8850_ONEIOS_FULL_RUN_STATUS.md) · [OneiOS performance backlog](https://github.com/YMGPwcca/OneiOS/blob/feat/oneios-sm8850-m3q/docs/TODO.md)
