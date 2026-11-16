# OneiOS on Galaxy S26 Ultra (SM8850 / m3q)

Status: **hardware diagnostics only**. This fork does **not** enable an iOS session or guarantee One UI 9.0 recovery.

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
- The root oneios_switch.sh model/device/SoC gate remains unchanged. It will refuse an SM8850 switch even if the app is modified.
- Android host hardware tests do not prove full iOS Metal/SpringBoard operation or recovery.

## Next milestones

1. Build the Android app and run Kotlin/JUnit tests; verify S24 functionality remains unchanged.
2. Run selected display, touch, haptics, audio and vendor HAL diagnostics while One UI remains running. Avoid modifying wireless state without a verified restore procedure.
3. Investigate CPU scheduling/thermal behavior and validate the companion OneiOS CPU regression fixture.
4. Implement and validate One UI 9.0 recovery, ADB continuity and rollback independently before considering an SM8850 session allowlist.
5. Only after recovery validation, evaluate hosted XNU, image set, Metal and SpringBoard.

Companion: https://github.com/YMGPwcca/OneiOS/tree/feat/oneios-sm8850-m3q