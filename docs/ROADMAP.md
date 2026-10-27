# Roadmap

**Strategy: ship of Theseus.** Get a complete system booting early, then replace Apple's
proprietary parts one by one, using the originals as the reference for correct
behaviour. Every phase ends with something that boots. Libraries and frameworks are
built from Apple's open source or written by Finch; Apple's kexts (and, in the Tier 2
VM, its kernel) stay borrowed from the user's macOS until Phase 3 replaces them.

This page is the plan and the current state. The dated evidence for every finished
item (which test, which run) is in [ROADMAP-LOG.md](ROADMAP-LOG.md). An item is
checked when its stated scope is done and tested; follow-on work gets its own item.
`docs/STACK.md` shows what runs today.

## Where things stand (2026-10-27)

| Area | State |
|---|---|
| Kernel | XNU (`xnu-12377.101.15`) built from source boots Finch in QEMU (Tier 1) and in a VZ guest (Tier 2). Platform drivers are Apple's, loaded from macOS. Bare metal is paused. |
| Userland | Done for the VMs: Finch's init, libSystem, daemons, login, accounts, sandbox (Finch's SBPL compiler and kernel policy), keychains, authorization, cron, configd, Disk Arbitration, Bonjour. |
| Frameworks | 50.5% of the macOS 26.4 SDK's 535,953 public API items are present ([COMPATIBILITY.md](COMPATIBILITY.md)), with generated Apple-vs-Finch comparison tests for behaviour. Biggest gaps: LAPACK (about 30,000 items across its three dylibs), Matter, System.framework, NetworkExtension, GameKit, RealityKit, Network's Swift API. |
| Apps | Apple's apps run sandboxed in the VM; the 19 "Ready" apps launch, and 10 have scripted task tests (Calculator, TextEdit, Stickies, Script Editor, Terminal, Grapher, Digital Color Meter, Console, Magnifier, ColorSync Utility). See [APPS.md](APPS.md). |
| Desktop | Finch's window server and Fieldwork design: themed windows, controls, menus, Night mode, the Instrument Bar and the Rail. Workbenches and window behaviour are open. |
| Release | Not releasable yet: no installed system on real hardware, no switching of booted system versions, daily-use checks open. |

## Finch 1.0 release checks

Passing an import check, building a library or opening an app window does not close
a user-facing requirement. Each check needs the evidence listed.

| Check | Evidence needed | State |
|---|---|---|
| Installation and boot | Install on the dedicated target, boot Finch's kernel and userland, create the first user and log in without a donor macOS. Keep the recovery route. | **Open.** First-user setup and login pass on the persistent VM; no install on hardware. |
| Stored data | Home files, accounts, passwords and network settings survive two restarts with the same access rules. A RAM disk does not count. | **Partial.** Passes on the persistent VM's data disk; the system image still loads into RAM. |
| Updates and recovery | Signed updates, switching system versions, rollback keeping user edits, recovery from interruption at each step ([design](design/RELEASE.md#installed-system-design-required-for-10)). | **Partial.** Signed, resumable, staged updates and rollback work on a system folder; switching the booted system is open. |
| Devices and services | Display, input, sound, network and storage of the target through normal apps; service failure and restart without data loss. | **Partial.** Services, restart and recovery pass in the VM; real devices need Phase 3. |
| User isolation | One user can't read another's files or change system files; login, locked accounts, keychains, privileged operations. | **Done in the VM.** Sandbox, App Sandbox, keychains, authorization and trust settings pass; to repeat on the installed system. |
| Applications | Per supported app: recorded tasks with expected results (open, edit, save, reopen, quit). | **Partial.** 10 apps scripted; the pinned set's remaining apps open. |
| Release contents | Build and check the exact payload, record sources and tools, run the full suites, repeat install and recovery with it. | **Partial.** Payload checks, provenance (`/usr/share/finch/SOURCES.txt`) and full host/VM suites exist; no install to repeat yet. |

## Open work for 1.0

### Install and boot
- [ ] The isolated Finch APFS container on the M4, with permissive security for it only (paused).
- [ ] The Finch root image on its own APFS volume (bare metal).
- [ ] Open drivers, boot path first: AIC and DART; ANS (NVMe); DCP (displays); SMC and PMGR (power, sleep, battery); USB, keyboard, trackpad, audio; Wi-Fi and Bluetooth; AGX with Mesa's asahi driver.
- [ ] Standalone install with no macOS on the Mac, offline as far as the hardware allows, run from recoveryOS, with a working recovery path.
- [ ] Switching the booted system version (updates).
- [ ] POSIX conformance runs, alongside the bare-metal userland.

### Frameworks
Measured per framework against the SDK baseline ([COMPATIBILITY.md](COMPATIBILITY.md)).
- [ ] Accelerate: LAPACK in full (needs a permissively licensed implementation built in), BNNS, sparse solvers. Done: vDSP, vMisc and BLAS in every ABI, all of vImage, Quadrature, LinearAlgebra, Sparse BLAS.
- [ ] Foundation: the rest of the public API, by what apps use.
- [ ] CoreGraphics, CoreText, ImageIO: tagged PDF; HEIF reading, XMP, GIF writing; CoreText justification as Apple's, colour glyphs, font fallback details.
- [ ] AppKit: `NSTreeController`, outline-view bindings, Core Data's controllers; every public class and method, as Apple's answer them.
- [ ] QuartzCore: on-screen animation playback and a render server.
- [ ] Metal through Mesa: a device (software, then the M4's GPU), and OpenGL core profiles.
- [ ] SwiftUI (OpenSwiftUI): ABI parity, then the system apps, smallest first.
- [ ] Networking: NTLM, HTTP/2; Network's newer Swift API (NetworkConnection, QUIC, WebSocket, framers); NetworkExtension.
- [ ] Media: AVFoundation export sessions, compositions, audio mixes, AVMovie; compressed audio conversion; ScreenCaptureKit audio and HDR; screen recording.
- [ ] Missing frameworks apps import, in [APPS.md](APPS.md)'s blocking order (WebKit, VideoToolbox's codecs, MetalKit, ...).
- [ ] Cameras and scanners (device modules, with Phase 3 USB).

### Apps
- [ ] Pin the 1.0 app set (Apple's apps and the build Mac's most-used, [APPS.md](APPS.md)) and record what works in each: launch, open and save, clipboard, printing, network and media where used.
- [ ] Calculator and the other "Ready" apps through every recorded task, not just launch.

### Fieldwork desktop ([design](design/FIELDWORK.md))
- [ ] The remaining controls: buttons, pop-ups, segmented controls, check boxes, sliders.
- [ ] A system process owning the Instrument Bar (network, battery, the launcher).
- [ ] The Rail: hover names, drag to pin, retracting for full-screen apps.
- [ ] Workbenches: named, persistent, defined in text files.
- [ ] Window behaviour: alignment guides, layout zones, fill the workbench.
- [ ] Illustrated icons, and the mascot in onboarding, empty states and About.

### Daily use
- [ ] Accessibility, keyboard navigation, sleep and wake, shutdown, storage errors and low-space recovery, on the M4.

## Phases

| Phase | Goal | State |
|---|---|---|
| 0. Our kernel boots | XNU from source boots on the targets | Done in the VMs; the M4's container is paused |
| 1. Our userland boots | Finch's init, libSystem and daemons to a login | Done in the VMs; bare-metal volume open |
| 2. Open graphics stack and first app | CF, Foundation, CoreGraphics, the window server, AppKit, unmodified apps | Mostly done; API gaps above |
| 3. Open drivers | Finch's own drivers for the M4, standalone install | Not started (bare metal paused) |
| 4. Open frameworks | The rest of the frameworks apps use | In progress; see Frameworks above |
| 5. Finch 1.0 | Installer, updates, security model, Fieldwork, the release checks | In progress; see the checks above |
| 6. Windows software | Wine, ARM64 first, then x86-64 through an open translator (FEX or Box64); DXVK and vkd3d on Mesa's Vulkan | After 1.0 |
| 7. Linux binaries | arm64 Linux programs directly on XNU through a syscall translation layer (as FreeBSD's Linuxulator), not a VM; no Linux kernel code | After 1.0 |
| Beyond | Finch for iPhone and iPad | Research only: needs a way to run unsigned code at boot |
