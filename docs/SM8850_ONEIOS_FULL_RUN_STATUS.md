# OneOS SM8850 / OneiOS Framework experiment: physical status (2026-11-20)

**OneOS · Galaxy S26 Ultra / SM8850 · current research evidence**

[← Docs hub](README.md) · [Port](SM8850_PORT.md) · [OneiOS manual](oneios.md) · [Watchdog](oneios-watchdog-recovery.md)

> **Root-only research path, not the normal OneOS Android app switch.**
> Verified device scope: Samsung SM-S948B / m3q / SM8850, firmware
> S948BXXS4BZIG, Android 17 / One UI 9, SELinux enforcing, ephemeral
> KernelSU/DirtyFrag root. Companion OneiOS branch:
> [feat/oneios-sm8850-m3q](https://github.com/YMGPwcca/OneiOS/tree/feat/oneios-sm8850-m3q).
> Full cross-repository metrics and P0–P3 work items:
> [OneiOS 2026-11-20 ledger](https://github.com/YMGPwcca/OneiOS/blob/feat/oneios-sm8850-m3q/docs/SM8850_LIVE_STATUS_2026-11-20.md).

## Experimental real hardware bridges=1 (source branch, not staged)

The SM8850 GPU3D full-run previously passed `bridges=0` to
protect touch-exclusive CPU-affinity benchmark isolation. On
request, this branch switches the actual xnuhost invocation to
`--set bridges=1 --set sm8850-full-bridges=1 --set touch-sleep=0`
and turns off the *separate* `cpu-affinity-bench`. It keeps
8 vCPUs, GPU 3D, `cpu-pin=1`, raw exclusive touchscreen and all
independent root thermal/CPU cap/reboot return guards.

The real `config.bridges` path now starts CPU topology and
cpufreq virtio MMIO, Samsung brightness/TSP and power key wake,
battery and thermal guest notification. `wifi=off`,
`haptics=off`, `bluetooth=virtual` and `encoder=off` stay
individually disabled for this first experiment. This is
**bridges=1**, not an isolated brightness-only stand-in.

An explicit `sm8850-full-bridges=1` flag is mandatory for allowing
`bridges=1` alongside the touch-exclusive bench. Before
opening any generic hardware bridge or grabbing the touchscreen,
xnuhost independently verifies the matching current rooted OneOS
Framework session, correct boot and generation, reboot-only return,
guard/cap requirements, stopped zygotes, missing system_server and
separate mount namespace. Missing critical real hardware channel
causes a fail-closed setup error. Existing ordinary preview and
production app switch restrictions remain unchanged.

OneOS also rejects a stale native runtime **before** one-shot APFS
Data consumption unless xnuhost contains
`SM8850_FULL_BRIDGES=ACTIVE`. This source branch alone does not
supply a built native runtime, so it must not be staged as a
ready-to-takeover package until the separate ARM64 artifact exists
and local CachyOS CI passes.

**No thermal threshold was relaxed. No live phone takeover was
run.** The independently qualified watchdog/unassisted recovery
remains unverified.

## Three distinct security/operational states

| Interface | SM8850 status |
| --- | --- |
| OneOS Android **app**, `OneiosSystem.canSwitchOn` and UI/job model gate | **BLOCKED** for OneiOS, intentionally unchanged; a card/diagnostic allowance is not permission to switch |
| Explicit `oneios_switch.sh --framework-session run` from authorized, root-owned experimental stage | **ALLOW only after strict model/firmware, image, watchdog legacy-risk and separate full-600s operator-ack gates**; not a generally supported device |
| Independently qualified production watchdog, thermal and unassisted return | **NOT ACCEPTED / NOT CERTIFIED**; root-only success cannot remove the app gate |

## Exact on-phone sequence and evidence

1. The original **20-second Framework-only smoke** confirmed a Framework-stop marker and an intentional deadline reboot request. One UI subsequently booted with reason `reboot,oneios-sm8850-reboot-return`. This verified the named reboot *request*, not the kernel driver's identity/timeout or a wholly unassisted return.
2. The **first full-run attempt** failed at inner BusyBox single-file bind-remount; `xnuhost` did not execute. `oneios_return.sh` selected early `switch-failed` reboot. This was corrected by self-bind-mounting the isolated guest Data/session directories writable and read-only remounting their parent stage directory with explicit SOURCE/TARGET.
3. An **isolated F2FS/BusyBox mount-namespace probe on the actual phone** passed, together with APFS Data-only hash-verified rearm and a passive full-run admission check. Previous consumed Data was archived. These operations did **not** stop Android Framework.
4. The **second live full Framework experiment** emitted `FRAMEWORK_TAKEOVER=CONFIRMED`, `IOS_GUEST_READY=OBSERVED`, `IOS_DISPLAY_FIRST_FRAME=OBSERVED`, `IOS_HOST_CPU_MASK=0-7`. Hosted XNU ran for **~600.6 seconds** according to the saved `xnuhost` shutdown log. The user's filtered telemetry shows active KGSL/drm2kgsl GPU acceleration (imports, one retired backboardd fence) plus severe CPU overhead, poor/irregular buffer pacing and reported lag/heat.
5. After the session, unprivileged ADB found **a new Android boot**, `sys.boot_completed=1` and `ro.boot.bootreason=reboot,oneios-sm8850-reboot-return`. Ephemeral root was gone. The host returned **exit 4**, because it could not authenticate the root-owned outcome of the exact deadline and return sequence. This **does not** revoke already observed guest-ready or displayed-frame evidence, but **does not** certify unassisted return.

The last physical full-run revisions: OneiOS `21b88f7`, OneOS
`349c029`. Subsequent documentation/diagnostic changes have not been
verified by another destructive full run.

## What OneOS explicitly does — and does not do — in this experiment

- The physical SM8850 profile uses a **mandatory reboot to One UI**, not an in-place Android Framework handback. It keeps the existing device-side deadline, stop watcher, legacy watchdog feeder and recovery fallbacks, but the legacy watchdog node/driver and timeout remain **UNVERIFIED_REBOOT_ONLY**.
- `--framework-session run` keeps the exact current **8 vCPU / 4 GiB / GPU auto / SHM display / 1080x2340 @ 60 / 600s** configuration; `GPU auto` is not a guarantee of 3D in every subsequent run.
- Its `xnuhost` command is `--mode bench` with `--set bridges=0` to preserve exclusive-touch safety. **OneiOS's thermal bridge and normal CPU placement bridge are therefore inactive**. Linux kernel/firmware thermal limits are still active. OneOS does **not** yet carry a separate scoped thermal guard for the bench path, so another long full-run should not be called thermally accepted.
- The allowed CPU mask `0-7` is an admission check, **not eight distinct CPU affinities**. A guest framebuffer post is **not measured animation FPS**.
- DirtyFrag's ephemeral root can disappear after a real reboot. The host can keep previously observed guest/first-frame markers and report the unprivileged new boot, while continuing to report `FULL_TAKEOVER_DEADLINE_RETURN=NOT_VERIFIED_NO_ROOT_OUTCOME`.
- During USB-connected reboot, pressing Volume Up + Volume Down together can enter Samsung Download Mode; it is **not** a safe SM8850 in-place-return promise.

## Required work before another long full-run

- **P0:** implement and validate a separate read-only thermal telemetry/guard path and fail-safe response for `bench/bridges=0`, without enabling other hardware bridges, disabling thermal protection or writing global CPU/GPU governors.
- **P0:** inspect preserved `return.log`, `return.outcome`, per-launch `switch.log`, watchdog supervisor logs and host boot timeline **read-only** after an authorized root restoration; attribute the actual deadline/reboot request and independently qualify watchdog behavior.
- **P0:** ensure evidence survives ephemeral-root loss, session tokens are matched and no stale log is accepted.
- **P1:** profile the full-run scheduler/host trap/Spotlight cost before considering an opt-in CPU affinity experiment; maintain 8-vCPU admission and all existing recovery gates.
- **P2:** correlate KGSL/guest fences, frame damage, SurfaceFlinger post cadence and touch-to-frame latency; investigate GPU blob/import memory and frame copies before claiming graphics throughput.
- **P3:** local CachyOS regression, short bounded and matched A/B trials, memory/page-table study, and a separate final recovery certification. Do not infer 60 FPS or production readiness from the 600-second host duration.

## References

- OneiOS: [full run and prior BusyBox failure](https://github.com/YMGPwcca/OneiOS/blob/feat/oneios-sm8850-m3q/docs/SM8850_FULL_IOS_10MIN.md)
- OneOS: [watchdog provenance and remaining hardware gaps](oneios-watchdog-recovery.md)
- OneOS: [port boundary and Android app allowlist](SM8850_PORT.md)
- OneiOS: [thermal guard — proposed design, not accepted](https://github.com/YMGPwcca/OneiOS/blob/feat/oneios-sm8850-m3q/docs/SM8850_THERMAL_GUARD.md)
- OneiOS: [recovery acceptance — independent evidence requirements](https://github.com/YMGPwcca/OneiOS/blob/feat/oneios-sm8850-m3q/docs/SM8850_RECOVERY_ACCEPTANCE.md)
- OneiOS: [performance baseline — observed sample versus missing measurements](https://github.com/YMGPwcca/OneiOS/blob/feat/oneios-sm8850-m3q/docs/SM8850_PERFORMANCE_BASELINE.md)
- OneOS assets: `switcher/assets/oneios_switch.sh` and `switcher/assets/oneios_return.sh`.

**Documentation updates are not evidence of another physical test.** Do not
run a new reboot-smoke or full takeover solely to populate this ledger.


## 2026-11-23: rejected live 180s takeover (One UI never stopped)

The host requested the **explicit 180-second no-userspace-thermal** mode.
The preflight and host console stated software thermal guard OFF, but the
detached device-side `--framework-session run` entered the *guarded* branch.
The preserved `launches/a0e6b35a369b4f3b95e79ab62429f0f0/switch.log`
contains `THERMAL_GUARD=ARMED_ROOT_BEFORE_FRAMEWORK_STOP`, followed by:

```text
FRAMEWORK_PANEL_WAKE=BLOCKED_BEFORE_FRAMEWORK_STOP
REASON=switch-panel-wake-refused: CPU floor or thermal sample unsettled
CPU0_MIN=3628800 CPU6_MIN=4185600 CPU_MC=61500 elapsed=20s
```

The independent OneOS return reported
`inplace ... One UI was never stopped`; the same boot and
`system_server` remained alive. The guest had **not** launched. The APFS
Data clone was nevertheless marked consumed before stage initialization
and must be rearmed for any future trial. Exit 4 is the intentional
recovery/refusal result, not a GPU failure.

**Correction:** a detached live session now selects the no-soft-guard mode
only with a 7th exact positional
`I_ACCEPT_SOFT_GUARD_OFF_180S` token. The read-only preflight can
also take the same token as its 4th argument. The old env flag is
supported for legacy preflight, but no longer silently selects no-guard
in a detached live session without the explicit token. A mismatch
fails before one-shot APFS consumption and before Framework stop.
The switch logs `SM8850_LIVE_THERMAL_PROFILE` with the effective mode.
Recovery, independent watchdog qualification and the previous
CPU >100 C measurements are unchanged; this fix is NOT a new thermal
safety certification. Verify local CI and stage matching OneOS revision
before any further experiment.


## 2026-11-24 addendum: latest **uncapped** 180s experiment supersedes historical “source only” profile descriptions above

The previous sections describe **historical** configurations, including `bridges=0`/600s and a separate experimental 28% root CPU cap. The **later actual physical** 180s run pinned OneOS `f5c1b4a44fc45d78987694a230f7ffabb213e99c` plus OneiOS `f244b5cdfdedd592cc68bcbbb0770762def9e140`, chose **bridges=1, 8 guest vCPUs, GPU3D, root software thermal guard OFF and root CPU cap OFF**, while kernel/vendor/firmware controls were not intentionally modified.

- Stage-only and fresh APFS one-shot clone rearm **PASS** without Framework stop. F2FS sparse copy was used after unsupported FICLONE, with verified `data.img`/`unique-chip-id` and archived consumed Data.
- **Explicit, read-only actual-profile preflight PASS:** `SM8850_SOFT_THERMAL_GUARD=OFF_NOT_SPAWNED`, `SM8850_CPU_CAP=DISABLED_NO_ROOT_WORKER`, `NO_USERSPACE_THERMAL_180S_PREFLIGHT=PASS_NO_FRAMEWORK_STOP_NO_DATA_CONSUMPTION`.
- **Live guest observed:** real Framework takeover, iOS ready, first frame, brightness physical change with slight slider stutter, KGSL 3D. The current archived session `7434ae27f8e84b76806f7a4b506e90c9` includes exact-paired nonempty XNUHost/display logs; no logged EPROTO, BackBoardD exit or SpringBoard exit in this session.
- **Unsafe thermal:** earlier host-side passive telemetry summary cited a CPU internal junction **104.8°C** around T+61s (raw thermal series not re-parsed into the GitHub note). The absent root guard/cap provides **no** root-side software heat abort.
- **Return only partially witnessed:** host observed a new normal Android boot with reason `reboot,oneios-sm8850-reboot-return` but `BOUNDED_TAKEOVER_RESULT=POST_REBOOT_OBSERVED_SESSION_CAUSE_NOT_PROVEN` and host exit **4**. The original authenticated root requester, independent watchdog and unattended One UI return remain **UNVERIFIED**.

The earlier 28%-capped 180s experiment with `GPU_COMMAND EPROTO` and BackBoardD/SpringBoard respring belongs to another session. No controlled A/B performance gain or definitive GPU patch cure is established.

**Current source-of-truth:** [OneOS root-policy findings](SM8850_180S_UNCAPPED_ROOT_POLICY_2026_11_24.md), [root-side P0 issue tracker](SM8850_180S_UNCAPPED_ROOT_TRACKER_2026_11_24.md) and [OneiOS detailed per-frame/CPU findings](https://github.com/YMGPwcca/OneiOS/blob/feat/oneios-sm8850-m3q/docs/SM8850_180S_UNCAPPED_SESSION_FINDINGS_2026_11_24.md). **Do not rerun the no-guard/no-cap takeover; P0 thermal and independent recovery remain BLOCKED.**
