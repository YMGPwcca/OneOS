# OneOS SM8850 direct-parent integration: source and safety ledger

**2026-11-21.** Immediate parent of this repo is [akshaynexus/OneOS](https://github.com/akshaynexus/OneOS), specifically its OneiOS-focused `oneios` branch at reviewed commit `53abb04e7bd87c785fff7a1db3ebd0742e777eb5`. The more distant `fahadalijaved/OneOS` is **not** the requested source.

The accompanying OneiOS fork's immediate parent is [akshaynexus/OneiOS](https://github.com/akshaynexus/OneiOS) main at reviewed commit `92886287724d3f9aa097dc17157281e585457500`. The complete per-component matrix, inherited/ported/excluded source paths and one-command build gate live in [OneiOS: SM8850 direct-parent parity](https://github.com/YMGPwcca/OneiOS/blob/feat/oneios-sm8850-m3q/docs/SM8850_DIRECT_PARENT_PARITY.md).

## What OneOS contributes for the S26 Ultra

- `switcher/assets/oneios_switch.sh`: the genuine isolated SM8850 `--framework-session probe` (not the standard Android guest manager); APFS one-shot claim, independent root thermal guard, 8-vCPU iOS guest, host USB witness, and monotonic reboot-return deadline. **600s full-run source admission remains unconditionally BLOCKED**.
- Conservative current bench argv explicitly selects the parent-compatible `cpu-affinity-bench=1`, `cpu-pin=1`, `gpu-level=deadline`, `gpu-priority=1`, `setway-skip=1`, `spin-host=0`, `spin-task=0`, fixed/prefaulted/locked 4G RAM, `bridges=0`. This activates **guest-only host-core placement** and avoids the parent GPU top-clock hold policy, but does **not** enable any wider device bridge.
- `switcher/assets/oneios_sm8850_thermal_takeover_guard.sh`: once per successful heartbeat it samples the complete pinned 28-zone CPU/GPU/DDR/board/BAT/LRP manifest; once per five heartbeats prints session-bound `P0_THERMAL_SAMPLE` and `P0_XNUHOST_LOAD`. Source CPU soft abort 55 C, GPU/DDR 55 C, BAT 38 C and board/LRP 42 C remain unchanged, without touching governors or watchdog.
- `tests/run_sm8850_thermal_local.sh` plus source tests include the new parent-parity source assertions (179 test functions expected in the thermal group).
- The parent `oneios_return.sh` cannot be replaced wholesale: the S26 Ultra fork's root state, watchdog generation/PID-birth, reboot-only fallback and P0 proven/unproven distinctions are not the same as those in its Samsung S24/S25 source.

## What is deliberately not activated

The OneOS **Android GSI switch** and the full Android APK are a different operation; no OneOS application click authorizes iOS takeover on SM8850. Parent watchdog `/dev/watchdog` admission, in-place return, clock-top writes or Android hardware vendor thermal assumptions are not certified on S948BXXS4BZIG. In particular, the previous isolated **CPU90 experimental** reboot followed a CPU zone reaching **101.1 C**, despite an experimental 90 C abort; never raise that threshold or run another hot takeover to "prove" these code changes.

## Operator workflow

The OneiOS repo now provides a single `scripts/sm8850-parent-integration-all.sh` runner. It fetches the two forks and **their immediate parents only**, creates clean detached build worktrees, runs OneOS's complete thermal P0 offline tests and OneiOS's complete GPU3D-required ARM64 CI, builds the read-only OneOS Probe debug APK, attempts the Metal/Turnip bundle for iOS27, retains source hashes/artifacts and emits one combined `report.json`. It does not access the phone, stop Framework, use ADB or issue a reboot. Missing build dependencies or unreviewed upstream changes are **not** counted as PASS.

The earlier combined **host-only** CI PASS was reported **before** these new GPU/Metal ports; this new integrated build has **not** been executed on CachyOS yet. No physical thermal safety, watchdog recovery or completed 300s runtime claim is made.
