# OneiOS · iOS 27 experiment

**Galaxy S26 Ultra / SM8850 · hosted XNU · root-only Framework takeover**

[← OneOS handbook](README.md) · [Physical session status](SM8850_ONEIOS_FULL_RUN_STATUS.md) · [Device scope](SM8850_PORT.md) · [Watchdog](oneios-watchdog-recovery.md)

> [!CAUTION]
> **Not a supported OneOS app switch.** The iOS guest has physically booted and drawn on SM-S948B under a separate root-only experiment, but the user reported major lag and heat. Thermal protection at the OneiOS bridge level, independent watchdog handback and fully unassisted One UI return remain **NOT VERIFIED**.

## Current state

| Gate | Evidence |
| :--- | :--- |
| Device | Samsung **SM-S948B / m3q / SM8850**, firmware **S948BXXS4BZIG** |
| Guest | **iOS 27.0.1 / 24A446**, hosted XNU from OneiOS |
| Framework stop | **OBSERVED** in the explicitly risk-acknowledged root-only session |
| Guest startup | **OBSERVED** `session/ready`, displayed first frame, ~600.6 seconds of host execution |
| Graphics | **OBSERVED** drm2kgsl/KGSL context, imports and fence activity; not Vulkan certification |
| Memory | **OBSERVED** 4 GiB prefaulted/locked, no guest swap in captured sample |
| CPU | Eight allowed host CPUs (`0–7`), **not** independently pinned core proof |
| Performance / temperature | **NOT ACCEPTED**; lag and severe heat during physical session |
| Return | Android restarted with `reboot,oneios-sm8850-reboot-return`; exact requester and unassisted path **NOT VERIFIED** |
| Normal OneOS app | **BLOCKED** for iOS on SM8850; unchanged |

## Two completely separate paths

| Interface | Eligibility | Effect |
| :--- | :--- | :--- |
| **Ordinary OneOS app** | iOS on SM8850: **BLOCKED** by app model/UI/job policy | No new iOS switch entry granted by this research milestone |
| **Root-only lab command** | Exact firmware/SoC, trusted stage, previously recorded smoke evidence and explicit 600-second legacy-watchdog risk acknowledgment | Can stop Framework and launch the guest for a bounded experiment; not a consumer workflow |

Experimental enablement **does not loosen** the app allowlist. Likewise, the app's system cards, patch manager and Android-guest compatibility tables are not claims that this iOS image is supported.

## How the root-only session works

```text
One UI running
    │  exact device/firmware + root + stage hashes
    ▼
OneOS recovery preflight and risk acknowledgment
    │  watchdog legacy candidate + 600-second deadline
    ▼
Stop Android Framework (not the Linux kernel)
    │  private guest mount namespace
    ▼
xnuhost → hosted XNU → iOS 27.0.1
    │  SHM display helper + KGSL GPU
    ▼
Mandatory reboot-return on deadline or earlier failure
    │
    └── New Android boot (observed); unassisted cause not yet certified
```

**Guest runtime profile:** 8 vCPUs, 4 GiB guest memory, GPU auto, SHM display at requested 1080×2340/60 Hz, touch-exclusive bench configuration with `bridges=0`, and a 600-second device-side deadline. The GPU-auto choice can fall back to 2D in a different session even though KGSL activity was captured previously.

### Files and roles

| Ownership | Path / resource |
| :--- | :--- |
| OneOS switch and return | `switcher/assets/oneios_switch.sh`, `switcher/assets/oneios_return.sh` |
| OneiOS host scripts | `scripts/phone/sm8850-full-takeover.sh`, `sm8850-takeover.py` in [OneiOS](https://github.com/YMGPwcca/OneiOS/tree/feat/oneios-sm8850-m3q) |
| Root-owned experimental stage | `/data/adb/oneios-m3q-framework` |
| Guest | `runtime/xnuhost`, locally built kernel collection and APFS volumes |
| Evidence | `launches/*`, `session/xnuhost.log`, `control/display.log`, `return.log`, `return.outcome` |

## Device and data safety

- **Isolation:** root-owned staged runtime, scripts, image and control are read-only inside the guest namespace; only independent Data/session bind mounts stay writable.
- **One-shot storage:** every APFS Data clone is consumed before Framework stop. It must be freshly cloned for a new run, never silently reused.
- **Recovery:** the SM8850 root-only mode uses mandatory reboot, not an in-place return promise. USB plus both volume keys may cause Samsung Download Mode during a reboot.
- **Thermal:** `bench/bridges=0` disables the *OneiOS standalone thermal bridge*, not the kernel/vendor thermal protections. No long-session thermal qualification has been performed.
- **Trust:** iOS firmware, kexts and image assets are locally sourced, hash-verified and not distributed through OneOS.

> [!WARNING]
> Do not trigger a new 600-second takeover while the phone is hot, bypass watchdog preflight, enable all hardware bridges merely to turn on thermistors, or classify `EXIT=4` after ephemeral-root loss as failure of the already observed guest boot.

## Engineering priorities

1. **P0 — Thermal/recovery:** a scoped thermal reader/guard for the actual bench path, and read-only attribution of the saved return/watcher logs.
2. **P0 — Evidence continuity:** durable, session-matched receipts surviving root loss; distinguish first frame, Android boot and true deadline outcome.
3. **P1 — CPU:** Spotlight/indexing, syscall and page-fault frequency, host handoff latency and safe vCPU placement experiments.
4. **P2 — GPU/display:** KGSL contexts and fence completion, guest scanout and SurfaceFlinger post pacing, GPU memory lifecycle.
5. **P3 — Acceptance:** local-first CI, short matched A/B measurements, memory/thermals and eventually separate return certification.

## Current source of truth

[Physical SM8850 evidence](SM8850_ONEIOS_FULL_RUN_STATUS.md) · [Watchdog investigation](oneios-watchdog-recovery.md) · [OneiOS engineering roadmap](https://github.com/YMGPwcca/OneiOS/blob/feat/oneios-sm8850-m3q/docs/TODO.md)

For acceptance criteria rather than another live run, use the companion OneiOS [thermal-guard design](https://github.com/YMGPwcca/OneiOS/blob/feat/oneios-sm8850-m3q/docs/SM8850_THERMAL_GUARD.md), [recovery evidence matrix](https://github.com/YMGPwcca/OneiOS/blob/feat/oneios-sm8850-m3q/docs/SM8850_RECOVERY_ACCEPTANCE.md), and [performance baseline](https://github.com/YMGPwcca/OneiOS/blob/feat/oneios-sm8850-m3q/docs/SM8850_PERFORMANCE_BASELINE.md). These are proposed engineering gates, **not new physical test results**.

Historical details remain accessible in Git history; they are not the current SM8850 switching contract.
