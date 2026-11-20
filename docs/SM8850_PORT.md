# OneiOS on Galaxy S26 Ultra (SM8850 / m3q)

Status (2026-11-20): **physical iOS 27.0.1 guest boot and first frame OBSERVED through the separately authorized root-only Framework experiment**; `xnuhost` ran ~600.6 s with real KGSL activity. **OneOS app switching stays BLOCKED** for this device. The user reported severe lag/heat; independent watchdog, thermal safety and unassisted reboot-return remain **NOT VERIFIED**. Read [the full current evidence ledger](SM8850_ONEIOS_FULL_RUN_STATUS.md).

## Verified target (2026-11-16)

- Model SM-S948B, device m3q, SoC SM8850, board canoe.
- Android 17 / One UI 9.0, Linux 6.12.69, 4096-byte pages, KernelSU with SELinux Enforcing.
- Eight CPUs: CPU0-5 capacity 741, 3628800 kHz max; CPU6-7 capacity 1024, 4742400 kHz max. Generic OneiOS classifier reports 6E/2P; this does not imply six physical E-cores.
- GPU diagnostics with verified OneiOS runtime v0.1.9: gpuctl nodes/routes/probe/submit/large all returned ok.
- KGSL chip 0x44050a00, GPU ID 6860, usable 192 GiB VBO, udmabuf limit 64 MiB/1024 runs.
- GPU command submissions completed fences without GPU faults or async errors; both 96 MiB split buffer and 1100-page fragmented case succeeded.
- KernelSU BusyBox/resetprop present and tested; One UI zygote, system_server and surfaceflinger running. Display/input/recovery/guest Metal not yet tested.

## Safety boundaries

- OneiosSystem.offeredOn includes the existing s-ultra-8850 profile for card visibility and hardware diagnostics.
- OneiosSystem.canSwitchOn allows only s-ultra-8650 (S24 Ultra). This is intentionally separate from offeredOn.
- The experimental acknowledgement cannot override the SM8850 BLOCK gate.
- The UI flow cannot offer SWITCH when switchAllowed=false; OneiosJob separately checks OneiosSystem.gate before running scripts.
- The normal `oneios_switch.sh session/--check` path remains scoped to the S24 profile and refuses SM8850. **Separate, root-owned, firmware-exact** `--framework-check run` / `--framework-session run` experimental entrypoints exist for SM8850 and require their own full-risk acknowledgment. This is not an Android app allowlist change.
- The 2026-11-20 guest ready and first-frame markers establish that a hosted iOS session drew to the panel; they do **not** prove fully working Metal/Vulkan, smooth SpringBoard UI, thermal safety or a complete unassisted return.

## Next milestones (2026-11-20; live guest has been observed)

1. **P0:** independent thermal telemetry/guard for the actual
   `bench/bridges=0` root-only session; retain Samsung kernel limits, no
   broad `bridges=1` or global governor edits.
2. **P0:** read-only analysis of the archived `return.outcome`, watcher and
   feeder logs after root is available; qualify actual watchdog ownership,
   600-second requester, and **unassisted** One UI reboot separately.
3. **P1:** investigate Spotlight and host trap/futex overhead, and only
   consider an opt-in host-affinity A/B after local tests; the mask 0–7
   is not proof of eight distinct per-vCPU cores.
4. **P2:** correlate actual 3D KGSL fences with posted buffer gaps; do not
   equate a first frame or `posts/s` with sustained 60 FPS.
5. **P3:** run local CachyOS builds/tests before further controlled,
   short device verification; do not change the OneOS Android app
   safety allowlist on the basis of this experimental session.

For the complete timeline, measured data, exact commands and acceptance
limits see [SM8850_ONEIOS_FULL_RUN_STATUS.md](SM8850_ONEIOS_FULL_RUN_STATUS.md).

Companion: https://github.com/YMGPwcca/OneiOS/tree/feat/oneios-sm8850-m3q