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

### SM8850 display handoff — Samsung boot animation suppression

The 2026-11-28 passive Framework OFF observation on SM-S948B
(S948BXXS4BZIG) saw bootanim running and a samsungani565 SurfaceFlinger
layer. The prior Framework=1 branch suppressed zygote_next but skipped
bootanim, unlike OneOS Android takeover. Upstream reference:
fahadalijaved/OneOS 5d0cddf6c063527522b201e4359172071d9d4178
switcher/assets/oneos_switch.sh:1537,1558-1569.

The existing boot-pinned, recovery-admitted stop-loop now also stops
the init-managed bootanim service when running/restarting in SM8850
Framework mode. It samples immediately then every five existing 200ms
iterations; zygote polling is unchanged. The extra stop is suppressed
once a return request or stop-loop.off is visible, including a second
check just before writing ctl.stop. Existing return Gate B already
ends the loop before it restores bootanim. The non-Framework branch
is unchanged. Do not copy upstream's host compositor freeze/restart or
blanket bootanimation PID kill into hosted iOS: the host compositor is
the actual display provider. No new guest splash renderer is enabled:
the existing renderer redraws every 150ms and SM8850 stages have not
qualified its assets/handoff. A blank or retained frame during startup
is possible; a low-overhead change-driven splash belongs to the future
display integration. This is source-only, not a physical verification
of layer exit or a performance/thermal claim. No admission, thermal,
watchdog, deadline, recovery or APFS change. Run
python3 tests/test_sm8850_bootanim.py offline to exercise the real
loop body with inert property/sleep stand-ins.
