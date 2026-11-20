# OneOS documentation

**Android guest systems · experimental OneiOS companion · developer references**

[← Project home](../README.md) · [OneiOS physical results](SM8850_ONEIOS_FULL_RUN_STATUS.md) · [Device catalog](devices.md) · [Compatibility](compatibility.md)

> [!IMPORTANT]
> The **normal OneOS Android app** supports many Android guest devices and profiles. The **OneiOS SM8850 full Framework takeover** is a separate root-only research experiment. Its success at showing an iOS frame does **not** lift the app-side iOS switch block or certify unattended recovery.

## Browse by topic

### OneiOS · S26 Ultra experimental track

| Document | Focus |
| :--- | :--- |
| [SM8850_ONEIOS_FULL_RUN_STATUS](SM8850_ONEIOS_FULL_RUN_STATUS.md) | Current physical evidence · ~600 s guest, KGSL, heat and recovery limits |
| [SM8850_PORT](SM8850_PORT.md) | Exact SM8850 device scope and app/root-only boundary |
| [oneios](oneios.md) | iOS 27 root-only experiment, compatibility limits and session flow |
| [oneios watchdog recovery](oneios-watchdog-recovery.md) | Legacy watchdog provenance and unverified recovery requirements |

The companion [OneiOS thermal guard](https://github.com/YMGPwcca/OneiOS/blob/feat/oneios-sm8850-m3q/docs/SM8850_THERMAL_GUARD.md), [recovery acceptance](https://github.com/YMGPwcca/OneiOS/blob/feat/oneios-sm8850-m3q/docs/SM8850_RECOVERY_ACCEPTANCE.md) and [performance baseline](https://github.com/YMGPwcca/OneiOS/blob/feat/oneios-sm8850-m3q/docs/SM8850_PERFORMANCE_BASELINE.md) are **proposed acceptance contracts**, not evidence that thermal protection or unattended return has passed.

### OneOS · Android guest behavior

| Document | Focus |
| :--- | :--- |
| [compatibility](compatibility.md) | Community and device test results for Android guest systems |
| [devices](devices.md) | App device catalog and supported Android guest profiles |
| [guest runtime](guest-runtime.md) | How an Android guest is staged and started |
| [inplace return](inplace-return.md) | Android guest handback and recovery design |
| [guest screen lock](guest-screen-lock.md) | Lock-screen compatibility and safety |
| [guest root provider compatibility](guest-root-provider-compatibility.md) | Supported root-provider integration |
| [boot status](boot-status.md) | Boot-status renderer and transition lifecycle |
| [download images](download-images.md) | Download/import and package guidance |
| [new guest systems](new-guest-systems.md) | Adding and validating a new Android guest |
| [zygote sockets](zygote-sockets.md) | Service/socket setup notes |

### Platform and guest-specific engineering

| Document | Focus |
| :--- | :--- |
| [coloros google](coloros-google.md) | ColorOS Google integration |
| [coloros on fold](coloros-on-fold.md) | ColorOS on foldables |
| [exynos hosts](exynos-hosts.md) | Exynos host compatibility |
| [exynos](exynos.md) | Exynos notes |
| [fold8 coloros](fold8-coloros.md) | Foldable ColorOS implementation |
| [fold8 patch channels](fold8-patch-channels.md) | Foldable patch channels |
| [fold8 pixel hinge](fold8-pixel-hinge.md) | Pixel Fold hinge implementation |
| [hyperos](hyperos.md) | HyperOS guest |
| [nothing](nothing.md) | Nothing OS guest |
| [originos](originos.md) | OriginOS guest |
| [pixel guest](pixel-guest.md) | Pixel guest integration |
| [retained coloros apks](retained-coloros-apks.md) | Retained guest APK inventory |
| [samsung ims in guest](samsung-ims-in-guest.md) | Samsung IMS bridge |
| [patch notes/2026 10 31 coloros fold8](patch-notes/2026-10-31-coloros-fold8.md) | Historic foldable patch note |

### App UI and maintenance

| Document | Focus |
| :--- | :--- |
| [DESIGN](app/DESIGN.md) | App design system and implementation notes |
| [ui redesign](app/ui-redesign.md) | UI redesign specification |
| [redesign 2](app/redesign-2.md) | Newer design iterations |
| [redesign 2 systems](app/redesign-2-systems.md) | System card UI |
| [redesign gallery](app/redesign-gallery.md) | Reference gallery |
| [redesign home](app/redesign-home.md) | Home screen concepts |
| [patch engine](app/patch-engine.md) | Patch workflow |
| [patch catalog](app/patch-catalog.md) | Patch catalog |
| [compat safety logs](app/compat-safety-logs.md) | Compatibility and safety logging |

---

## Status vocabulary

- **PASS** — exact named check and tested scope.
- **OBSERVED** — direct evidence, not an automatic certification of related behavior.
- **BLOCKED** — a safety or compatibility gate prevents use.
- **NOT VERIFIED** — evidence missing; do not infer success.
- **HISTORICAL** — older diagnostic/decision context retained for research.

Documentation formatting follows GitHub-flavored Markdown: direct links, compact tables, clear command fences, and native caution/note callouts. Always distinguish Android app support from root-only OneiOS experiments.
