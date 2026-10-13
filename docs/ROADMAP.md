# Roadmap

Strategy: **ship of Theseus.** Get a complete, booting system as early as possible, then
replace Apple's proprietary parts one by one, using the originals as the reference for
correct behavior. Every phase ends with something that boots. Since 2026-10-08, nothing
closed is borrowed above the kernel: each closed library or framework is built from
Apple's open source or written by Finch when something needs it. Apple's kexts (and, in
the Tier 2 VM, its kernel) stay borrowed until Phase 3 replaces them.

**How this list is kept:** an item is checked when the scope it states is done and
tested. Follow-on work gets its own unchecked item rather than a "Next:" appended to a
finished one, and each commit that finishes or adds work updates this file and
`docs/STACK.md` together.

## Progress saved on 2026-10-11

This batch adds working software audio conversion and file handling, more system
services, web certificate roots, local account tools and a checked install archive.
Finch 1.0 is still open. The checks below cover specific parts of the system.

- Audio conversion, audio files, software audio units (now with Apple's effect,
  time and instrument units), offline queues and AVFAudio through the engine,
  players and effect units pass focused host checks. Sound hardware and
  compressed audio codecs remain open.
- Cron, one-time jobs, local Bonjour discovery and Disk Arbitration sessions pass
  in QEMU. FAT32 formatting and checking pass on a disposable disk image in VZ;
  real disk mounting under Finch remains open.
- Shared settings, user access rules and recovery after a service restart pass
  in QEMU. Manual loopback IPv4 and DNS settings also pass, including repeat
  apply. Failed requests try to remove newly added addresses; full undo, DHCP,
  Wi-Fi and settings that survive reboot remain open.
- Local account creation and password changes pass host and QEMU checks. Correct,
  wrong and locked passwords pass through PAM and OpenDirectory in a private
  QEMU test folder. A full console login and first-user setup remain open.
- The install archive passes file, owner, permission and required-library checks.
  Test runners now reject failed programs even when their partial output matches.
  A clean installation, signed updates and a full release test run remain open.
- HTTPS uses pinned Mozilla roots. File keychains still store secrets without
  encryption; keychain file-access hardening is deferred to the next batch.

## Phase 0: Our kernel boots
Build XNU from source and boot it on real Apple Silicon with Apple's own kexts.
- [x] Reproducible XNU build for `xnu-12377.101.15` (matches dev machine) with KDK: `tools/build-kernel.sh`
- [x] Build a kernel collection: our XNU + BORROWED kexts (KDK 25E253; 308/310 link, see `boot/kc/excluded-kexts.txt`)
- [x] Boot stock Darwin in darwin-vm (emulated M4) — see docs/DEV_VM.md
- [x] Boot our XNU in darwin-vm (2026-10-06)
- [ ] Create the isolated Finch APFS container on the M4. Permissive Security for that
      OS only. Boot our kernel collection on bare metal. **Deferred (2026-10-07):** QEMU
      covers Phases 0–1 and Virtualization.framework covers Phase 2, so metal waits. When it
      comes, it uses a boot stub, not a full macOS donor install (see "Standalone install"
      in Phase 3).
- [x] A visible Finch fingerprint: `uname -v` reports `finch:finch-0.0.1/xnu-12377.101.15/…`

**Exit:** macOS userland runs on a kernel we compiled.

## Phase 1: Our userland boots
Replace the userland with Darwin built from Apple's open source, plus Finch code where
Apple's is closed. Developed in the emulated M4 first. The map is
`userland/INVENTORY.md`.
- [x] **1.1 Finch PID 1.** `finch-init` replaces the closed launchd: console, OS version
      sysctls, rc script, respawning shell, orphan reaping. The default PID 1 of Finch's VM image
      (2026-10-06).
- [ ] **1.2 Commands from source.** Build shell_cmds, file_cmds, text_cmds, system_cmds and
      bash/zsh ourselves, replacing darwin-vm's prebuilt sysroot.
  - [x] file_cmds, shell_cmds, text_cmds, adv_cmds, system_cmds: 188 binaries build and
        run under finch-init (`tools/build-oss.sh`, 2026-10-06)
  - [x] bash 3.2 (bash-144), zsh 5.9 + modules (zsh-118, via `userland/oss/zsh.build.sh`),
        bc/dc. zsh is the console shell.
  - [x] libiconv, libcharset and the i18n modules and tables (`/usr/lib/i18n`, `/usr/share/i18n`)
  - [ ] Deferred tools (see `userland/INVENTORY.md`)
  - [x] `reboot` / `halt` / `shutdown` from system_cmds, through finch-init's shutdown
        sequence (`reboot3`)
  - [x] Ramdisk grown to 600 MiB without sudo (raw APFS resize); writable tmpfs for /tmp
        and /var/{tmp,run,log,root}
  - [ ] Root-owned files in dev images (they arrive as uid 99; the root fs can't be
        remounted read-write). Build release images with root.
  - [x] Writable /var/db: System Policy (the sandbox's platform profile) refuses a mount
        there, so it's a link into a tmpfs at `/private/var/rw` (2026-10-08)
- [x] **1.3 Open libSystem from source.** Swap dylibs one at a time, starting with
      libsystem_kernel from our own xnu build.
  - [x] libsystem_kernel (xnu libsyscall + patch 0003), running in the VM (2026-10-06).
        Missing vs Apple's build: 7 legacy `__stat`-family stubs, `register_uexc_handler`,
        and 2 version symbols; nothing imports them.
  - [x] libsystem_platform (libplatform; recipe from its published xcconfigs, plus Finch
        `ffs`/`fls`, SME-safe string routines and one Swift tracing no-op). 185/185 exports.
  - [x] libsystem_pthread (libpthread + `userland/patches/libpthread`; Finch
        `<os/thread_self_restrict.h>` for the JIT write-protect toggle). 209/209 exports.
  - [x] libsystem_malloc (libmalloc; Finch `<os/feature_private.h>` ABI-compatible with
        Apple's libsystem_featureflags; header-only Finch SHA-256 replaces the libcorecrypto
        dependency). 118/118 exports.
  - [x] libdispatch (config reconstructed: Apple publishes libdispatch.xcconfig nearly
        empty). 410/411 exports (missing: an unused watchdog helper).
  - [x] `finch-libsystem-test` (userland/tests) passes in the VM: malloc, pthread, dispatch,
        string/bit ops. The JIT toggle is untestable in QEMU (no SPRR); verify on bare metal.
  - [x] libsystem_blocks (libclosure). 19/19 exports.
  - [x] libsystem_c (Libc). 1328/1328 exports. Finch `os/log_private.h` (ABI of the
        closed libsystem_trace), header-only `corecrypto/ccrng.h` over getentropy(2)
        (no libcorecrypto), generated dyld version constants, `_atexit_receipt`
        (App Store exit hook recorded, not run).
  - [x] libsystem_darwin, libsystem_info (on Finch libxpc)
  - [x] libsystem_notify and notifyd (Libnotify), with notifyd run on demand by finch-init
  - [x] dyld shared cache, built by Finch from the image (`docs/design/DYLD_CACHE.md`):
        process launch about 50× faster in the VM (3 s → 61 ms for `/usr/bin/true`)
  - [x] libsystem_m (CORE-MATH and FreeBSD msun), dyld, libcorecrypto and CommonCrypto,
        libsystem_trace, libutil, libbsm, libncurses (2026-10-07)
  - [x] Finch CrashReporterClient (`__crash_info` annotations), linked by Libc and notifyd
- [ ] **1.4 Finch replacements for closed libSystem pieces** (libxpc, libsystem_trace,
      sandbox, quarantine, …). Start with the subset our binaries actually import.
  - [x] **libxpc**: Apple-ABI-compatible XPC objects and
        connections, with the Mach bootstrap/service registry in finch-init. Mac apps and
        most of libSystem's upper half depend on it. Plan and progress:
        `docs/design/XPC.md`.
    - [x] X1 object model and value types (100/462 imported symbols)
    - [x] X2 wire format, byte-compatible with Apple's (checked against captured samples,
          fuzzed under ASan)
    - [x] X3 Mach transport: pipes and connections, interoperating with Apple's libxpc in
          both directions (144/462 imported symbols)
    - [x] X4 finch-init bootstrap server, X5 swap in (the VM runs on Finch libxpc)
  - [x] libsystem_info and libsystem_darwin built from source on Finch libxpc
  - [x] **Service manager** in finch-init: launchd job plists, MachServices with launch on
        demand, KeepAlive, run as another user (`docs/design/SERVICES.md`)
    - [x] `launchctl` (Finch's own: list, print, start/stop, kickstart, kill, load/unload)
    - [x] Sockets, StartInterval, StartCalendarInterval, WatchPaths, QueueDirectories,
          `launch_activate_socket` and `launch_msg` check-in (2026-10-07)
    - [x] LaunchAgents and per-user domains (`user/<uid>`, entered through Apple's
          pam_launchd by `login` and `su -l`, or `launchctl asuser`; 2026-10-08)
    - [ ] Run Apple's open-source daemons under it (notifyd, syslogd, configd, ...)
      - [x] notifyd; syslogd (checks in with `launch_msg`, which Finch's libxpc
            answers from finch-init's job; 2026-10-07)
      - [x] finch-logd and `log show`/`log stream`: os_log over libdispatch's open-source
            firehose server (`docs/design/LOGD.md`, 2026-10-08)
      - [x] aslmanager (on demand), newsyslog, dynamic_pager (2026-10-08)
      - [ ] Finish configd and diskarbitrationd. Cron and mDNSPosix now run in QEMU.
            Their supporting frameworks come from source (nothing closed is borrowed):
            `docs/design/COREFOUNDATION.md`
        - [x] libicucore (ICU-76142.4.7; all 8,979 exports)
        - [ ] CoreFoundation (swift-corelibs base; C API, then the ObjC collection classes)
          - [x] C API and CF objects as ObjC objects: `finch-cf-test` output identical to
                Apple's, on the host and in the VM (2026-10-08)
          - [ ] ObjC-to-CF dispatch and the collection classes. In progress: CF compiles
                as Objective-C with Apple's dispatch, and hosts NSException, the array,
                dictionary and set clusters, NSData and NSDate, identical to Apple's in
                `finch-bridge-test`; message forwarding and NSInvocation, identical to
                Apple's in `finch-forward-test` (`docs/design/FOUNDATION.md`). Since
                then: ordered sets, NSCache, streams, ports and the CFError and
                CFAttributedString bridges. Left of Apple's CF classes: NSFileSecurity,
                NSSharedKeySet, the constant data and date classes, tagged-pointer strings.
        - [x] libswiftCore from Swift's open source (libobjc links it; 14,885/15,043 exports)
        - [x] zlib, bzip2, libedit, libresolv, libxml2 (Apple's sources) and liblzma, libxo, libsbuf
              (upstream, where Apple doesn't publish its copy), each with Apple's exports
              exactly (2026-10-08)
        - [x] OpenDirectory (CFOpenDirectory's C API over the local node),
              libEndpointSecuritySystem, and libcompression (Apple's API over LZFSE, LZ4,
              Brotli, zlib and LZMA; cross-checked against Apple's): Finch's own (2026-10-08)
        - [x] su and login authenticate through Finch's PAM stacks (OpenPAM's pam_unix
              with Apple's pam_launchd; 2026-10-08)
        - [x] Foundation: Finch's own (Phase 2's first item, below). Since 2026-10-08,
              `tools/check-closed.py` finds no closed library in anything Finch builds.
        - [x] IOKit.framework from IOKitUser: IOKitLib, power management, power sources
              (`userland/IOKit`; nvram, iostat and shutdown run on it, 2026-10-08)
        - [x] SystemConfiguration's local preference and network-state reads, schema keys,
              and synchronous route checks (2026-10-09). Shared store writes,
              subscriptions, user access rules and temporary-key cleanup now pass
              in QEMU through Finch's configd (2026-10-11). Watches recover after
              service restart. Preference file writes and readback pass in a
              private VM test root. Manual loopback IPv4 and DNS apply also pass,
              including repeat apply and host checks of address cleanup on failure;
              reboot persistence and broader network setup remain open. See
              [Security and SystemConfiguration](design/SECURITY.md).
        - [x] DiskArbitration.framework, the client, from Apple's source (2026-10-10);
              without diskarbitrationd a session can't be made, as when the daemon is down
        - [x] finch-pboardd, the pasteboard server: each user's pasteboards shared by their
              processes, promised data asked of the writer (2026-10-10); NSPasteboard and the
              Pasteboard Manager on it
        - [x] cron: root and non-root reboot jobs; mDNSPosix: local-only registration
              and discovery. Both pass in QEMU (2026-10-11).
        - [x] at/atrun: root and non-root one-time jobs pass in QEMU. The
              development check uses a temporary root-owned `at`; release
              ownership and persistent job storage remain open (2026-10-11).
        - [x] diskarbitrationd runs and accepts client sessions in QEMU (2026-10-11).
        - [x] FAT32 formatting and a read-only filesystem check pass on a new
              guest-local image in VZ with Finch's tools (2026-10-11). This uses
              Apple's guest kernel and does not prove mounting under Finch.
        - [ ] Finish configd preference storage and network apply, and prove
              disk probing and mounting.
  - [x] libmalloc no longer depends on libcorecrypto
  - [x] libsystem_featureflags, coreservices, darwindirectory, eligibility, symptoms,
        trial, secinit, sanitizers, libRosetta: Finch's own (`userland/libsystem`)
  - [x] The rest of the strict Phase 1 exit: `docs/design/PHASE1-EXIT.md`
        (2026-10-07; `tools/check-boot-path.py`: 94/94 boot-path images Finch-built)
- [x] **1.5 dyld from source.** dyld-1376.6 boots the VM (`tools/build-system.sh`)
- [ ] Finch root image on its own APFS volume (bare-metal Tier 3)

**Exit:** the VM boots to a shell with no closed-source Apple binaries above the kernel.
**Reached 2026-10-07** (`docs/design/PHASE1-EXIT.md`). The unchecked items above
continue alongside Phase 2.

## Phase 2: Open graphics stack and first app
Nothing closed is borrowed (2026-10-08). Unmodified Mac apps need Foundation,
CoreGraphics and AppKit, so Finch builds open ones before running any app
(work that Phase 4 had). Most of it is built and tested on the host (against
Apple's, for behaviour) and in Tier 1. The display is Tier 2's
(`docs/design/TIER2-VZ.md`): a Virtualization.framework guest that boots
normally on its own kernel, until Finch's kernel runs on bare metal. The guest
is set up and reachable with `tools/vz/ssh` (2026-10-08).
- [x] The open libraries Finch's binaries link: all of them, Foundation included
      (`tools/check-closed.py`, 2026-10-08). IOKit is done.
- [ ] CoreFoundation: the ObjC bridge works; remaining hosted classes are listed above
  - [x] `CFNotificationCenter`: the local center shares observers with Foundation's
        default `NSNotificationCenter`; posts through either reach both in observer order.
        The Darwin center uses notify(3). `finch-cfnotify-test` matches Apple's on the host
        and in the VM (2026-10-09). Distributed notifications still stay within the process.
  - [x] Bundle localization: `.loctable` files, the `AppleLanguages` preference and
        Apple's ICU language matching. Image Capture now picks English instead of Korean.
        `finch-l10n-test` matches Apple's on the host (2026-10-09).
- [ ] Foundation, Finch's own in Objective-C over Finch's CF, class for class where
      Apple's is (`docs/design/FOUNDATION.md`). Behaviour is checked against Apple's
      on the host; swift-corelibs-foundation is the reference implementation.
  - [x] The framework, linked as Apple's, with CF linked to it upward; NSString,
        NSNumber/NSValue and literals, NSCharacterSet, NSError, NSAutoreleasePool,
        NSLog and the common functions. `finch-foundation-test` is identical to
        Apple's, and GCoreFramework (gcore) runs on it (2026-10-08).
  - [x] Collection descriptions; NSRunLoop/NSTimer, NSThread, locks, notifications,
        operation queues, NSProcessInfo, performSelector variants (2026-10-08)
  - [x] NSURL and NSURLComponents, NSFileManager, NSBundle, property lists (2026-10-08)
  - [x] NSLocale, NSTimeZone, NSCalendar, the date and number formatters,
        NSUserDefaults, the time-zone database (2026-10-08)
  - [x] KVC and KVO, NSIndexSet, geometry functions and NSValue boxes (2026-10-08)
  - [x] NSDecimalNumber, NSScanner, NSJSONSerialization, NSUUID, NSSortDescriptor (2026-10-08)
  - [x] NSCoder, NSKeyedArchiver/NSKeyedUnarchiver in Apple's format (2026-10-08)
  - [x] NSAttributedString, NSRegularExpression, NSOrderedSet, NSCache, pointer
        collections, NSCountedSet (2026-10-08)
  - [x] NSProxy, NSAssertionHandler, NSIndexPath, NSUndoManager, NSValueTransformer,
        NSNotificationQueue, NSAffineTransform, NSDateInterval (2026-10-08)
  - [x] Streams, ports, file handles, pipes, tasks, hosts (2026-10-08)
  - [x] NSPredicate and NSExpression (2026-10-08)
  - [x] NSProgress, NSFileWrapper, byte-count, ISO 8601 and date-components formatters,
        collection differences (2026-10-08)
  - [x] Units and measurements (NSUnit and its 22 dimensions, NSMeasurement,
        NSMeasurementFormatter over ICU) and NSXMLParser over Apple's libxml2
        (libxml2-39.10, built by Finch with Apple's exports) (2026-10-08)
  - [x] NSXPCConnection, NSXPCListener, NSXPCInterface and NSXPCCoder over Finch's
        libxpc; `finch-nsxpc-test` and its bundled XPC service match Apple's on the
        host and in the VM (2026-10-09). App-bundled `.xpc` services still need a job
        plist (finch-init doesn't look in apps' `Contents/XPCServices` yet).
  - [ ] The rest, by what apps use (`tools/check-framework-api.py` lists it):
        the URL loading system (Phase 4), a system-wide distributed notification
        center, NSFileVersion.
  - [x] Swift Foundation and AppKit overlays, the Darwin overlay libraries, and Swift's
        runtime built from pinned open source (2026-10-09). The combined host build
        matches Apple's 78-line overlay check and 12-line runtime check, including
        generic classes, protocol calls, tasks, regexes and backtraces. Export coverage
        is still partial; see [Foundation](design/FOUNDATION.md#the-swift-overlays).
- [x] CoreServices' local app lookup and launch, type and filesystem APIs, Apple event
      values and local dispatch, and Foundation's event/activity wrappers (2026-10-09).
      The host check matches Apple's 1,366 body lines. Interprocess Apple events,
      Handoff and DictionaryServices remain unfinished; see [CoreServices](design/CORESERVICES.md).
- [x] Security's supported RSA/EC keys, certificate reads, web and caller-supplied trust
      roots, file keychain and code-signature checks. Tests check signing, tampering,
      encryption and refused trust/rights. Keychain encryption, shared authorization
      and enforced app restrictions remain open; see [Security](design/SECURITY.md).
- [ ] CoreGraphics, CoreText, ImageIO over open renderers (`docs/design/COREGRAPHICS.md`)
  - [x] Skia (chrome/m155) builds for arm64e with FreeType and the open codecs, and
        without Apple's graphics frameworks (`userland/skia`, 2026-10-08)
  - [x] CoreGraphics' drawing half: geometry, paths, colour spaces, bitmap contexts,
        images, gradients, then shadings, patterns, layers and PDF writing. Geometry,
        affine transforms, paths, colour spaces, colours, data providers, images,
        bitmap contexts and drawing (fills, strokes, dashes, clips, masks, images,
        blend modes, shadows, transparency layers) are done: `finch-cg-test` is
        identical to Apple's, and `finch-cg-draw-test` matches Apple's renders, on
        the host and in the VM (2026-10-08). Gradients (linear, radial, conic),
        shadings, patterns and CGLayer, and CGFont and glyph drawing
        (font smoothing as Apple's) too (2026-10-08). PDF: CGPDFContext writes
        through Skia's PDF backend (page boxes, links, destinations, outlines,
        metadata, output intents, AES-128 encryption added in a final pass), and
        CGPDFDocument, CGPDFScanner and CGContextDrawPDFPage run on Finch's own
        parser and interpreter (fonts through FreeType); `finch-cgpdf-test` is
        identical to Apple's on the host, and each CG reads the other's PDFs as
        its own (2026-10-08).
  - [ ] CoreGraphics PDF: tagged PDF (structure for accessibility), and the PDF
        comparison run in the VM.
  - [x] ImageIO over Skia's codecs. Image sources (PNG, JPEG, GIF, BMP, ICO,
        WebP; properties, images, thumbnails, incremental loading), PNG and JPEG
        destinations, and all 750 public property keys are done: `finch-imageio-test`
        is identical to Apple's on the host and in the VM (2026-10-08). TIFF reading
        and writing, the writer byte for byte Apple's (`finch-tiff-test`, 2026-10-10).
  - [ ] ImageIO: HEIF reading, XMP metadata, GIF writing.
  - [x] CoreText over HarfBuzz and FreeType, with open fonts in place of Apple's.
        Fonts, lines, runs, typesetting and frames are done: `finch-ct-test` is
        identical to Apple's on the host and in the VM (2026-10-08). The open
        fonts (`userland/fonts`: Inter, Open Runde, Fragment Mono,
        XCharter, Pagella, Inter, Liberation, DejaVu Sans Mono, Noto; about 67 MB)
        ship with Apple's font names aliased onto them, the UI fonts, the
        default font and a fallback cascade for other scripts and emoji
        (`finch-ctfonts-test`, Finch-only, 2026-10-08).
  - [ ] CoreText: justification as Apple's, colour glyphs (emoji) when drawing, font
        stylistic classes.
  - [x] The window-server half of CoreGraphics: the window server's client, displays,
        the window list, and Quartz events (posting, event sources, taps), with
        `finch-ws-test` and `finch-cgevent-test` (2026-10-10)
- [ ] Finch window server and compositor (software rendering), on the Tier 2 display
  - Display and input paths in Tier 2: [`docs/design/WINDOWSERVER-DISPLAY.md`](design/WINDOWSERVER-DISPLAY.md)
  - [x] `finch-windowserver` (`docs/design/WINDOWSERVER.md`): windows over shared
        memory, levels and ordering, alpha and shadows, a Skia compositor, the
        cursor, input routing (capture, click counts, key window), the window list,
        and a headless backend; CoreGraphics' `FWS*` client and its display and
        window-list API. `finch-ws-test` passes on the host and in the VM (2026-10-08).
  - [x] The host viewer (`tools/vz/finch-viewer`) for the TCP backend: frames into
        a host window at the display's scale, mouse, scroll and key input back,
        reconnecting; tested end to end on the host (2026-10-08).
  - [x] Finch's desktop live from the emulated M4: `tools/vm/desktop.sh [APP ...]` runs the
        window server on the guest's tunnel UART and shows it in `finch-viewer` on the host,
        input going back the same way (2026-10-10). A click sent from the viewer
        (`--test-input X,Y --test-after N`) unchecks the gallery's toggle in the VM.
  - [x] CGEvent (Quartz Event Services; `finch-cgevent-test`, 2026-10-10)
  - [ ] The server on the Tier 2 (VZ) display, with its input
- [ ] AppKit ([`docs/design/APPKIT.md`](design/APPKIT.md))
  - [x] Framework skeletons as Apple splits them: AppKit re-exporting a private
        UIFoundation, ApplicationServices and Foundation; the Cocoa umbrella
  - [x] UIFoundation: fonts, paragraph styles, shadows, string drawing, TextKit 1 and 2.
        `finch-uifoundation-test` matches Apple's on the host and in the VM (2026-10-08).
        TextKit 2 (`NSTextLayoutManager`,
        `NSTextContentStorage`, layout and line fragments, the viewport, selection navigation) over
        the same layout, and `NSTextView` on TextKit 2 by default with Apple's switch to TextKit 1:
        `finch-textkit2-test` matches Apple's on the host and in the VM (2026-10-09); document formats to come.
  - [x] Drawing: colours, colour spaces, Bézier paths, gradients, images, graphics contexts.
        `finch-appkit-draw-test` matches Apple's on the host and in the VM (2026-10-08);
        dark-appearance colours to come. Asset catalogs now use Finch's CoreUI reader:
        486 host comparison lines match Apple, plus catalog metadata checked in five
        shipped apps (2026-10-09; [assets](design/ASSETS.md)).
  - [x] Applications, windows, views, events and the responder chain, on the window server:
        `finch-appkit-core-test` matches Apple's on the host and in the VM; `finch-appkit-window-test`
        drives a window through the server (drawing, clicks, keys, dragging, closing) (2026-10-08)
  - [x] Title bars and toolbars over full-size content windows, including toolbars loaded
        from nibs. Image Capture now shows both. Copying a custom image rep keeps its drawing
        handler; `NSFontEffectsBox` loads as a plain box for nibs such as Stickies' (2026-10-09).
  - [x] Controls and cells, menus, nib loading. Nibs load (ibtool's NIBArchive format and keyed
        archives; custom objects and views, outlets, actions, windows): `finch-nib-test` matches
        Apple's (2026-10-08); controls and cells (buttons, text fields, sliders, steppers, progress
        and level indicators, segmented controls, colour wells, image views, boxes) load from nibs
        and work: `finch-appkit-controls-test` matches Apple's on the host and in the VM,
        `finch-appkit-controls-window-test` drives them through the server (2026-10-08); menus
        (`NSMenu`, `NSMenuItem`, validation, key equivalents, nib main menus), a Finch-drawn menu bar,
        context and pop-up menus, `NSPopUpButton`: `finch-appkit-menu-test` matches Apple's on the
        host and in the VM, `finch-appkit-menu-window-test` drives them through the server (2026-10-08)
  - [x] Text editing and scrolling: `NSTextView` and the field editor (TextKit 2, or 1 on request), `NSScrollView`,
        `NSClipView`, `NSScroller`, an in-process `NSPasteboard`. `finch-appkit-text-test` matches
        Apple's on the host and in the VM; `finch-appkit-text-window-test` types, clicks and scrolls
        through the server (2026-10-08); rich-text pasteboard types, find and spelling to come
  - [x] Panels, alerts and the workspace: `NSAlert` (modal and as window-modal sheets), Finch's own
        `NSSavePanel`/`NSOpenPanel` browser, `NSWorkspace` and `NSRunningApplication` without
        LaunchServices (apps found by their Info.plist, launched by spawning their executable).
        `finch-appkit-panels-test` matches Apple's on the host and in the VM;
        `finch-appkit-panels-window-test` answers alerts, browses, chooses, saves and launches an
        app through the server (2026-10-09); Apple events, column views and sheet animation to come
  - [x] Bindings and controllers: Cocoa bindings (`NSKeyValueBinding`: bind/unbind/info, markers
        and placeholders, transformers, `NSEditor` commits) for text fields, checkboxes, sliders,
        pop-up buttons, text views and views; `NSObjectController`, `NSArrayController`,
        `NSUserDefaultsController`; nib binding connectors; `NSFontManager` and a Finch-look
        `NSFontPanel`. `finch-appkit-bindings-test` matches Apple's on the host and in the VM (2026-10-09);
        (table bindings: below)
  - [ ] `NSTreeController`, outline view bindings and Core Data's controllers
    - [x] `NSTreeNode` and `NSTreeController`: nodes kept by identity, children by key path
          (leaf and count key paths, KVO on children), index-path selection, insertion,
          removal, moves, sorting and rearranging, add/insert/addChild/insertChild, the
          content, selection-index-paths and sort-descriptor bindings and nib keys;
          `tree-test` matches Apple's (2026-10-12).
    - [x] Outline view bindings to a tree controller (content, selection index paths,
          sort descriptors, column values, view-based rows' objects); the controller's
          selection expands the items above it. `outline-bindings-test` matches Apple's
          on the host and in the VM (2026-10-12).
    - [ ] Core Data's controllers (entity names, fetch predicates, managed object contexts).
  - [x] Auto Layout and storyboards: `NSLayoutConstraint`, the visual format language, anchors and
        guides in a private CoreAutoLayout that Foundation re-exports, solved by Finch's own Cassowary
        simplex; views' constraint API, autoresizing masks as constraints, intrinsic sizes, fitting
        sizes, windows sized by their constraints; `NSStackView`; constraint nibs; `NSStoryboard`,
        segues and `NSMainStoryboardFile`. `finch-appkit-layout-test` matches Apple's on the host
        and in the VM (2026-10-09); popovers, storyboard references and right-to-left layout to come
  - [x] Tables, outlines and collections: `NSTableView` (cell- and view-based, Apple's geometry in every
        style, selection, sorting, editing, column resizing and autoresizing, row views and cell views
        with nib prototypes), `NSTableColumn`, the header and corner views, `NSOutlineView`,
        `NSCollectionView` with flow and grid layouts (and the older content/prototype API), table
        bindings (content, selection indexes, sort descriptors, column values) and their nib keys;
        scroll views' automatic insets under full-size content windows' bars.
        `finch-appkit-tables-test` matches Apple's on the host and in the VM; `finch-appkit-tables-window-test` clicks,
        types, sorts, resizes, edits and expands through the server (2026-10-09); drag and drop and
        outline bindings to `NSTreeController` and type select since (2026-10-12)
  - [x] Search, combo, token, date and path controls, switches, combo buttons, matrices
        and forms: 730 comparison lines match Apple, with drawing and typing/click checks
        (2026-10-09). Path drag sessions and some completion/dropdown details remain.
  - [x] Grids, page controllers, popovers, drawers, rule/predicate editors, the colour panel
        and browser: 77 comparison lines match Apple, with saved-interface, drawing and
        window-event checks (2026-10-09). See AppKit's status for each remaining limit.
  - [x] Animation grouping, Touch Bar state, basic mouse gestures, slider accessories,
        visual-effect views and context-help storage (2026-10-09). Animators still jump
        to final values, visual effects have no blur, and Touch Bar hardware and Help
        Viewer remain unfinished; 26 small-feature comparison lines match Apple.
- [ ] Unmodified Mac apps: launched and working on Finch's frameworks. Remaining: the
      two sub-items below marked open (TextEdit's whole scope, Calculator) and a check
      that an arbitrary app dropped in launches or reports exactly what it lacks.
  - [ ] TextEdit, its whole scope checked in the VM: new, type, format, save, close,
        reopen, revert, find, rulers, tables, print to PDF, autosave and versions
        (NSFileVersion is missing).
  - [ ] Calculator: needs Finch's own Calculate, CalculateUI, SwiftData, TipKit,
        AppIntents and Network, and 101 more SwiftUI symbols
        (`tools/check-imports.py`).
  - [x] Drop-in check: `tools/app-sweep.py` runs the import check over every app and the
        frameworks it carries, and ranks what's missing by apps blocked. Apple's apps are
        recorded in [`docs/APPS.md`](APPS.md) (2026-10-12: 11 of 65 have every import;
        gaps in AppKit, Foundation and CoreGraphics block the most, then AppIntents and
        AVFoundation). The next frameworks are picked from it.
  - [ ] Close the symbol gaps in Finch's own frameworks that block the most apps
        (AppKit, Foundation, CoreGraphics, QuartzCore, CoreFoundation).
    - [x] IconServices (private; 14 apps link it), Finch's own (2026-10-12): icons for
          apps (their .icns or asset catalog icon), files, folders and types (Finch's
          generic art), as images at the Mac's icon sizes (16, 32, 128, 256 and 512
          points, as Apple's snap them), and Apple's named image descriptors;
          `iconservices-test` matches Apple's.
    - [x] Small exports for Activity Monitor, Audio MIDI Setup, System Information and
          Migration Assistant (2026-10-12): CoreGraphics' display modes (Apple's 212-byte
          descriptions), display info and UUIDs, all sessions' properties, app
          responsiveness; AppKit's accent-colour calls, width factor, Help book name and
          `NSSubTextStorage` (Script Editor's text). They still link private frameworks
          Finch doesn't have (LaunchServicesSupport, caulk, DeviceRegulatoryInfo).
    - [x] Small private frameworks apps link for a few symbols (2026-10-12,
          `userland/SmallPrivate`): SoftLinking (`_sl_dlopen`), AppSupport (CPBitmap files,
          no city database, no radios), PerformanceAnalysis, ConfigurationProfiles,
          UIKitMacHelper, ChronoServices and UserManagement; `smallprivate-test` matches
          Apple's.
    - [x] OnBoardingKit's AppKit side (2026-10-12): the welcome template view, its container
          controller (button tray, spinner, status), the bullet list and the privacy
          screens, in Fieldwork's style; Finch has no Apple privacy bundles, so the
          privacy screens give Finch's own statement. App Store, Freeform, Migration
          Assistant, Music, Photos, Shortcuts and TV use it. AppKit now tells a view
          controller before and after its view lays out (`viewWillLayout`, `viewDidLayout`).
    - [x] Quick Look, Finch's own (2026-10-12; 9 apps link QuickLookUI): QuickLook's
          thumbnails (images through ImageIO, a PDF's first page, text on a page, else the
          icon), QuickLookThumbnailing's generator and requests, and QuickLookUI's preview
          panel (the responder chain's controller, arrow keys between items) and preview
          view (images, PDFs, text, else icon, name, kind and size); `quicklook-test`
          matches Apple's.
    - [x] AppKit's and Foundation's missing constants (84, with Apple's values) and small
          functions (`NSStringFromBOOL`, `_NSFullMethodName`, `NSRequestConcreteImplementation`,
          the autorelease-pool calls, `_NSCenteredRectForImage`, UIKit's rounding helpers,
          accessibility entry points) apps import (2026-10-12); `exports-test` matches
          Apple's.
    - [x] HTTP cookies (2026-10-12): NSHTTPCookie (properties, Set-Cookie parsing with
          Apple's 400-day cap) and NSHTTPCookieStorage (matching, replacement, persistence
          per app); URL loading sends and keeps cookies through the session's storage;
          `cookies-test` matches Apple's, a round trip included.
    - [x] Foundation's remaining service classes (2026-10-12): NSDateIntervalFormatter over
          ICU's interval formats; NSOrthography and NSLinguisticTagger (token types,
          sentences, paragraphs, languages and scripts by rule; CoreFoundation's
          tokenizer now guesses languages); NSFileVersion (the current version);
          NSMetadataItem and NSMetadataQuery (file-system attributes, queries walk their
          scopes); NSUbiquitousKeyValueStore kept per app on the Mac; NSBackgroundActivityScheduler
          (on time); NSAppleScript (now runs scripts: see AppleScript below); 220 more of Apple's
          constants; "UTC" names the GMT zone as on macOS. `foundation-more-test` matches
          Apple's.
    - [x] The Swift overlay's notifications as async sequences
          (`NotificationCenter.notifications(named:)`) and the typed undo-manager and
          cookie-storage messages (2026-10-12); `swift-overlay-test` matches Apple's.
    - [x] Swift System (2026-10-12): swift-system 1.8.1 built as Apple's
          `libswiftSystem` (every one of its exports, two through Finch's compatibility
          entry points), and Foundation's `FilePath`/`URL` conversions;
          `swift-overlay-test` matches Apple's.
    - [x] AppKit's value classes (2026-10-12): the Objective-C diffable data source
          snapshot and collection view data source (Apple's exceptions included), menu
          item badges, pressure and tint configurations, compression options, scroll edge
          effect styles, NSPDFInfo and NSPDFPanel, NSCIImageRep, and NSFontCollection
          (reading and writing macOS's own .collection files; CoreText's collections now
          match symbolic traits and languages); `appkit-values-test` matches Apple's.
    - [x] Magnifier runs (2026-10-12): Apple's Magnifier.app is a shell over the
          private MagnifierSupport, which Finch now has as its own SwiftUI app to the same
          ABI: the screen around the pointer enlarged (Finch has no cameras yet), with
          zoom, follow, freeze and invert. AppKit opens an untitled document at launch only
          when a document type names a document class, as Apple's does.
    - [x] Console runs (2026-10-13): Finch's ConsoleKit and OSAnalytics (Console.app's
          private frameworks, written from how Console calls them). The Mac's live log
          streams from Finch's log store with Console's columns, colours, details pane and
          search tokens; the sidebar lists the log report folders. Along the way, AppKit:
          views, windows, cells and menus answer the whole NSAccessibility protocol; controls
          report Apple's text baselines to Auto Layout; split views refit when Auto Layout
          sizes them, keep sidebars and content lists at their width, and take child view
          controllers as items. Foundation: directory enumerators for missing folders, the
          computer's name for NSHost. In the VM, finch-app-test can read the system apps'
          crashes, and FINCH_HOST_APPS_DEBUG re-signs host apps' copies for full backtraces.
          Still to do: the column headers under the toolbar, log archives (Apple's tracev3).
    - [x] AirPort Utility runs (2026-10-13): Finch's AppleSRP (the SRP-6a client with
          libsrp's API, RFC 5054 over OpenSSL) and AOSKit (iCloud account calls, no account).
          Core Animation gained a subclass's @dynamic layer properties (stored with the
          layer's values) and sublayer geometry flipping. Still to do: its window opens
          partly below the screen, and text a layer draws in a flipped view is upside down
          (Apple's AppKit flips a backing layer's geometry; Finch's SwiftUI expects it not
          to yet).
    - [x] AppleScript (2026-10-13, `userland/OpenScripting`, `userland/OSAKit`): Finch's own
          parser and interpreter for AppleScript's English dialect (values, coercions,
          references and elements, handlers, script objects, try/error, considering case,
          text item delimiters, the standard additions) behind the Open Scripting
          Architecture's calls in Carbon's OpenScripting (compile, execute, display, errors
          with their source ranges, descriptors both ways, events to scripts, source styles,
          load and store); `osascript`; NSAppleScript over them; and OSAKit (languages,
          scripts, the script view, text storage and controller, the outline parser).
          Compiled source is formatted and styled as Apple's is. `applescript-test`
          matches Apple's. Script Editor runs: scripts compile, styled, and run, with their
          results. Along the way, AppKit: a layout manager's replaced text storage reaches
          its text views, and a split view's collapsed pane stays out of Auto Layout (its
          contents had pushed Script Editor's window ever wider); Verdana maps to Liberation
          Sans; toolbar items pass their image, action, target and state on to a control
          view, as Apple's do (Script Editor's toolbar buttons); hammer and
          rectangle.bottomthird.inset symbols. Still to do: telling applications (Apple
          event terminology and sending), reading scripts Apple's AppleScript compiled
          ("FasdUAS"), applets, recording, AppleScriptObjC.
    - [x] Font Book runs (2026-10-13): its window, sidebar (fonts, languages, collections)
          and toolbar; the font grid still loads slowly. SwiftUI gained what it calls (Settings
          scenes, sidebar commands, group boxes and their styles, tab views, colour pickers,
          help buttons, canvases drawing through CoreGraphics, text renderers, outline groups
          and hierarchical lists, scene storage, search fields in the toolbar, inspectors,
          drop delegates, file documents and exporters, presented-value window groups,
          navigation split view styles, slider marks, and smaller modifiers and values;
          `userland/tests/apps/SwiftUIMore` shows them), and: an @Observable model or onChange
          in a scene's body runs in the app's graph; collapsed split panes stay out of
          layout. CoreText has NSFontCollection (moved from AppKit, as Apple's is; CoreText's
          collection calls take one) and the private calls font managers make (samples,
          names by ID, glyph strings, visibility, validation). New: ATS with libFontRegistry,
          FontServices with libFontParser, Network (the path monitor), MobileAsset (empty
          catalogs); CarbonCore's mapped resource-file calls (no resource forks yet);
          NSToolbar's inline title width; NSFileManager's trash; NSLocale's language names;
          AppKit keeps a layout engine alive while resizing its window re-enters layout.
          Then (2026-10-13): SwiftUI's named and symbol images without CoreUI (AppKit's
          images, drawn at twice their size; symbols as tinted templates), with Core
          Animation's contents properties (swizzle, multiply colour, scaling, EDR);
          a layer composites as a group only when it must (transparent, shadowed or
          masked), which made redrawing a SwiftUI window about three times cheaper;
          NSFileManager's private user-home domain (0x10000); the font-matching progress
          call; NSParagraphStyle's and NSAttributedString's private text calls; switches
          for finding a stalled app (`docs/DEV_VM.md`).
    - [x] Font Book's font grid (2026-10-13): families with their samples. It had kept
          its spinner because Font Book files fonts by URL and priority, which CoreText now
          gives (`kCTFontURLAttribute` from the registry, `kCTFontPriorityAttribute` from
          where the file is). Then: content hosted apart (a scroll view's document, sheets,
          popovers) inherits the presenter's environment objects and the app's own
          environment keys; safe-area insets in lists; focusable views draw their content;
          inset rounded rectangles, capsules, ellipses and circles; lazy grids in a scroll
          view; NSFont's lineHeight. Then plural strings: a table entry with plural rules
          (stringsdict, in .stringsdict or .loctable) comes back as __NSLocalizedString,
          and formatting it picks each variable's variant by ICU's plural rules (Apple's
          open-source CF parses %#@variable@ but has no engine for it); attributed
          formats keep it; String.LocalizationValue keeps a literal key's %, as Apple's.
          Controls in a toolbar take its forms, as Apple's: labels hidden, toggles as
          icon buttons; and labelsHidden() hides Finch's controls' labels (toggles,
          pickers, sliders, colour pickers). Still to do: the toolbar's segmented picker
          is wider than its slot, samples and the font detail
          view, installing and validating fonts; menu commands' `@Environment` values.
    - [ ] Next: measurement format styles, AppKit's private classes apps link
          (NSTokenAttachment, NSTouchDevice, NSButtonGroupTouchBarItem, ...), among others
          ([`APPS.md`](APPS.md)). Later: a Spotlight-style index
          for metadata queries, a version store for NSFileVersion, lexical classes for
          the tagger, and Automator (its private framework and ViewBridge).
    - [ ] Every class and method the public headers declare, as Apple's answers them:
          `tools/api-audit.sh` lists what Finch lacks. 2026-10-12: Foundation 48 classes
          and 136 methods (from 67 and 225), AppKit 48 classes and 115 methods (from 50 and 562).
    - [x] Foundation, first audit batch: collection searches, tests with options,
          sorted keys and removals; KVC's set and ordered-set proxies (changes now reach
          the object; set mutations report the objects changed, as Apple's) and its
          deprecated names; dependent keys by +setKeys:...; string transforms, folding,
          validated formats, encoding detection, path completion and property lists;
          data compression and search; calendar-format dates and NSCalendarDate;
          formats honour their locale (separators, grouping, numbers' descriptions);
          `foundation-audit-test` matches Apple's (2026-10-12).
    - [x] NSPDFImageRep: PDF data as an image, a page at a time (bounds, current page,
          drawing through Finch's PDF reader), registered so NSImage takes PDF data and
          files as Apple's does; `pdf-image-rep-test` matches Apple's on the host and in
          the VM (2026-10-12). ImageIO reading PDF as a bitmap (Apple's can) is to come.
    - [x] NSXMLDocument, NSXMLElement, NSXMLNode, NSXMLDTD and NSXMLDTDNode: read by
          libxml2 (its error codes, as Apple's), written to Apple's rules (declarations,
          empty elements, quoting, pretty printing, HTML and XHTML output, canonical
          form), XPath on a libxml2 mirror, DTD declarations and validation;
          `xml-test` matches Apple's (2026-10-12). XSLT waits for libxslt.
    - [x] NSDocument and NSDocumentController, all their declared methods: the deprecated
          file-name API (the current methods call an app's overrides of the old ones, as
          Apple's), synchronous saving, locking by the file's immutable flag, moving and
          renaming, duplicating, printing and page layout, Export as PDF, file-presenter
          callbacks, scripting commands, the document user activity and restoration;
          `document-more-test` matches Apple's (2026-10-12).
    - [x] The text system's declared methods: NSTextView's Format commands (underline,
          superscript, baseline, kerning, ligatures, outline, Copy/Paste Style and Ruler,
          writing direction), the substitution toggles and their defaults from the
          user's Text Input settings, smart insert and delete, completion, text checking,
          links, the format panels, dragging and highlights; NSText's own actions;
          NSLayoutManager's ruler markers (NSTextView now asks it, as Apple's), glyph
          storage, underline and strikethrough drawing; NSGlyphGenerator; NSTextStorage's
          scripting collections. `textview-more-test` matches Apple's (2026-10-12).
    - [x] Windows, views and controllers: view-controller presentation through animators
          (sheets are sheets now, and presenting and presented controllers are tracked),
          transitions, safe areas and their guides, full-screen views, updateLayer for
          layer-backed views, window content borders, PDF of a window, cursor rects, the
          newer cursors, mnemonics, table grids, the object controllers' Core Data
          settings, application search and document order, event touches, split-view
          accessories and tab toolbars; `windowing-more-test` matches Apple's (2026-10-12).
  - [x] Drag and drop: within an app, and between apps through the window server and
        the pasteboard server.
    - [x] Within an app: NSDraggingSession runs the drag once the event that began it is
          handled (the drag image follows the pointer; the frontmost view registered for
          the pasteboard's types, or its window, gets the NSDraggingDestination calls;
          Escape cancels), the older dragImage: API runs it synchronously, text views
          drag their selection and take drops (smart insert and delete on moves), and
          strings, attributed strings and URLs write and read themselves on pasteboards
          as Apple's do. `appkit-drag-window-test` checks it on the window server
          (2026-10-12).
    - [x] Table, outline and collection views as drag sources and destinations: their
          data sources' and delegates' pasteboard writers (and the older write-to-
          pasteboard forms), proposed rows, items and index paths validated and
          retargeted, drops accepted, and a line or outline showing where; the drag test
          reorders a table and a collection and moves an outline item (2026-10-12).
    - [x] Between apps: over another app's window the drag sends it enter, update, exit,
          drop and end messages through the window server (FWS_DRAG), and that app runs
          its destination and answers; the drag pasteboard is the pasteboard server's.
          `tools/vm/test-drag.sh` drags a string and text from one process to another in
          the VM (2026-10-12).
    - [x] Foundation: NSItemProvider (with NSString's and NSURL's item-provider
          conformance, and UniformTypeIdentifiers' UTType methods), NSListFormatter,
          NSRelativeDateTimeFormatter, NSPersonNameComponentsFormatter,
          NSLocalizedFileSizeDescription, NSURLCache and NSURLProtocol; byte counts
          zero-pad and add the actual count as Apple's. Their comparison tests match
          Apple's (2026-10-11).
    - [x] AppKit's smaller classes: the menu, separator and tracking-separator toolbar
          items, titlebar accessories (kept by the window; not yet drawn in the title
          bar) and split-view item accessories, row actions, attachment cells and view
          providers, preview activity items, the scrubber family, the speech
          synthesizer (silent), NSPreferences, and OpenGL's classes (stand-ins until
          OpenGL came, below);
          `appkit-small3-test` matches Apple's (2026-10-11).
    - [x] NSCollectionViewCompositionalLayout with its dimensions, sizes, items, groups
          (repeating, counted, nested), spacing, sections, boundary and decoration
          items, section providers and horizontal scrolling; `compositional-test`
          matches Apple's frames (2026-10-12). Pinned headers, anchored item
          supplementaries and self-sizing (estimated) items are still to do.
    - [x] File promises (NSFilePromiseProvider, NSFilePromiseReceiver; promises are kept
          within the process until there's a drag server), and pasteboards read any
          NSPasteboardReading class, not only strings and URLs; `filepromise-test`
          matches Apple's (2026-10-12).
    - [x] Glass (NSGlassEffectView, the private NSGlassView, NSGlassEffectContainerView):
          slate panels in Fieldwork, a translucent stand-in in Classic; row actions take
          the theme's colours (2026-10-12).
    - [x] AppKit's Swift overlay, its newer half (`AppKitOverlayModern.swift`): diffable
          data source snapshots and the collection and table view data sources, text
          suggestions, @NSView.Invalidating, frame-resize cursors, pull-down pop-up
          buttons, storyboard creators and the AppKit attribute scope's plain keys;
          `appkit-swift2-test` matches Apple's (2026-10-12). Symbol effects (they need a
          Symbols framework) and `NSImage(resource:)` are still to come.
    - [x] Private CoreGraphics, Core Animation and CoreFoundation calls Apple's apps use:
          window-server regions, connections, displays and session; shadow styles;
          colour spaces by ID; Core Animation's private constants, portal layers,
          packages, states and contexts; CF's version number, container preferences,
          XML entities and bidi levels; `private-calls-test` matches Apple's
          (2026-10-12).
    - [x] libswiftDispatch: DispatchQueue's conformance to Combine's Scheduler, from
          Apple's overlay source, weak-linking Finch's Combine (2026-10-11); 19 apps
          imported it.
    - [x] Apps, Mission Control and Time Machine: `CoreDockSendNotification` (HIServices;
          the Rail hears it, and answers Apps' Launchpad request with its launcher) and
          Time Machine's backup-server calls (CarbonCore; no backup server yet). Apps
          opens the launcher in QEMU (2026-10-11).
    - [x] Bluetooth File Exchange runs in the VM and, finding no Bluetooth controller,
          shows Apple's own "Bluetooth isn't available" alert (2026-10-12). Siri.app is
          a launcher for the assistant in CoreServices, which Finch doesn't have: it
          runs and exits, as Apps does without Launchpad.
    - [x] Screenshot runs in the VM (2026-10-12): it asks the
          `com.apple.screencapture.connection` service to run `screencapture -uUpi`.
          Both are Finch's own (`userland/screencapture`): the service runs the tool as
          the caller, with the caller's window server; the tool takes Apple's options
          (screen, display, rectangle, window, format, delay, clipboard, the
          `com.apple.screencapture` location and type) and, interactively, shows the
          frozen screen dimmed with a selection, window picking (space) and a mode bar
          (`-U`). A drag saves `Screenshot <date> at <time>.png` to the Desktop.
      - [ ] Screen recording (`-v`, and the service's start/stop messages), and the
            thumbnail and markup after a capture (`-u`).
    - [x] FeatureFlags (private; `isFeatureEnabled` over libsystem's feature table) and
          libMobileGestalt: a Mac's answers (device class, product, versions, serial,
          device ID from the chip IDs, architecture, screen scale, disk usage);
          `mobilegestalt-test` matches Apple's (2026-10-12).
    - [x] What the Utilities apps import beyond the rest: CoreGraphics' headroom copies,
          image writing, on-screen window lists and pointer; Core Animation's tone
          mapping; AppKit's legacy alert panels, voice keys and image names; CFFileSecurity
          (NSFileSecurity moves to CoreFoundation, as Apple's) and the file-security
          resource; scripting coercions; LaunchServices' weak bindings; and new
          SecurityFoundation, SkyLight (its SLS calls, over CoreGraphics), IOBluetoothUI
          and libDiagnosticMessagesClient. `utilities-test` matches Apple's
          (2026-10-12); Bluetooth File Exchange has every import (10 of 65 apps).
  - [x] AppKit's system images (NSAddTemplate, NSPauseTemplate, the toolbar and status
        images): Finch draws its own set in the Fieldwork style (`NSSystemImages.m`: ink
        line glyphs for the templates, small illustrated icons for the 32-point ones), and
        `+imageNamed:` finds all 140 names, including the private disclosure triangles,
        at Apple's sizes and with Apple's template flags; `system-images-test` matches
        Apple's (2026-10-12).
  - [x] Symbol images (`+imageWithSystemSymbolName:`, SF Symbols' names): Finch's own
        glyphs for the 143 base names apps use most, drawn in the Fieldwork line style,
        with the `.fill`, `.circle`, `.square`, `.slash` and `.badge.plus/minus/checkmark`
        variants; symbol configurations (point size, weight, scale) size and weigh them as
        Apple's do. Names Finch has no glyph for return nil. `symbols-test` matches Apple's
        (2026-10-12).
  - [x] A Cocoa app bundle built the usual way (`userland/tests/apps/Hello`: NSApplicationMain,
        a MainMenu nib from ibtool, outlets and actions) launches on Finch's frameworks and window
        server, shows its menu bar and window, and responds to clicks and typing
        (`tools/run-app.sh`, 2026-10-09)
  - [x] Apple's unmodified Image Capture launches on Finch's frameworks (ImageCaptureCore,
        ICADevices, Quartz with ImageKit's device views; `docs/design/IMAGECAPTURE.md`).
        It shows English strings, its title bar and an empty toolbar and device list
        (host, Finch's headless window server, 2026-10-09). `finch-imagekit-test` matches
        Apple's on the host and in the VM.
  - [ ] Cameras and scanners: device modules and Phase 3 USB support.
  - [x] Apple's unmodified Terminal runs in the Finch VM (`FINCH_HOST_APPS=Terminal`): it opens
        its window with a login shell at the prompt (2026-10-10). What it needed: ColorSync,
        HIServices, DataDetectorsCore, Carbon/HIToolbox, CoreAudio, AudioToolbox and the
        terminfo database; Cocoa scripting, Bonjour, bookmarks, window tabs, text input
        contexts and a run of fixes in bindings and key-value observing. Commands typed into
        it run in the shell and their output shows (`echo`, `uname -sr`), in its profile's
        monospaced font (an app's own fonts, under ATSApplicationFontsPath, are now found).
  - [x] Apple's unmodified Stickies runs in the Finch VM (`FINCH_HOST_APPS=Stickies`): its
        XPC migration service starts on demand from the app bundle, NSUnarchiver is there
        for its old database, and it loads its sample notes from RTFD with their text and
        colours (2026-10-10). Its notes are untitled windows, placed where its saved state
        puts them (as on a Mac); titled windows now keep below the menu bar as they appear.
  - [x] Apple's unmodified TextEdit launches in the Finch VM (copied from the Mac at image
        build time with `FINCH_HOST_APPS=TextEdit tools/vm/mkramdisk.sh`; nothing of Apple's
        is committed), opens an untitled document and takes typing (2026-10-09). It reads and saves RTF;
        NSFileCoordinator (presenters in-process) and NSTextFinder's find bar match Apple's
        behaviour (`finch-filecoordinator-test`, `finch-textfinder-test`), and Show Ruler
        brings up NSRulerView with its markers and format bar (`finch-ruler-test`). Tables
        read from and write to RTF as Apple's do, and draw with their backgrounds and borders
        and cells' vertical alignment (2026-10-09). Sharing services and their picker (Copy, Open,
        Email) back SwiftUI's ShareLink (2026-10-10). Next: NSFileVersion, NSSound.
  - [x] App test tools: `finch-app-test` accepts `screenshot:PATH` to save a screen PNG and `screenshot64` to print one over the VM console; `tools/host-tests.sh` runs the host comparison suite;
        `tools/check-imports.py` finds libraries such as libxpc through the VM overlay list,
        including builds outside `build/root` (2026-10-09). `finch-app-test` reports an app's
        crash with a backtrace, `tools/vm/symbolize-crash.py` symbolizes it on the host, and a
        `scroll:` step scrolls (2026-10-10).

**Exit:** an unmodified Mac app draws a window on Finch's own frameworks and
window server.

**App milestone reached on the host, 2026-10-09:** Image Capture draws through Finch's
frameworks and headless window server. The Tier 2 display and input work above remains.

## Phase 3: Open drivers
Replace BORROWED kexts with Finch kexts on the M4 (Mac16,1, T8132), the only machine
available. Asahi's M1–M3 work is the reference; M4 differences are found by tracing
macOS on the M4 itself (m1n1 hypervisor).
- [ ] AIC, DART
- [ ] ANS (NVMe storage)
- [ ] DCP (displays, brightness, external monitors)
- [ ] SMC, PMGR (power, sleep, battery)
- [ ] USB, keyboard/trackpad, audio
- [ ] Wi-Fi/Bluetooth
- [ ] AGX kernel driver + Mesa asahi userspace
- [ ] **POSIX conformance** (after the GUI stack, alongside the bare-metal userland;
      see [design/POSIX.md](design/POSIX.md)). A correctness and portability baseline
      that doesn't move the way macOS does. Not formal certification.
  - Run an open POSIX conformance suite (Open POSIX Test Suite, plus the shell and
    utility checks) on Finch's own code: finch-init, the launchd replacements, Libc
    patches, the commands.
  - Fix failures where Finch diverges from both POSIX and Apple. Where they disagree,
    keep Apple's default (`$UNIX2003` variants, `COMMAND_MODE`).
  - Unpatched Unix software builds on Finch: autotools projects, POSIX `sh` scripts,
    Homebrew-style build systems.
- [ ] **Standalone install: no macOS on the Mac.** The end goal for installing Finch.
  - The Finch container holds only a boot stub plus Finch. The stub is Apple's
    second-stage iBoot and device firmware, downloaded from Apple's restore image at
    install time and never redistributed.
  - The boot policy is created for the Finch container, and no macOS volume is needed.
  - The Mac keeps what it can't do without: system firmware and the system recoveryOS.
  - To prove on hardware: the installer runs from the system recoveryOS, so not even
    installing needs macOS.
  - [ ] Offline install, as far as the hardware allows. The stub's boot firmware must
    carry an Apple-signed ticket for that Mac (the boot ROM and SEP enforce it), which
    normally means one request to Apple's signing server. Finch's own kernel and system
    are authorised by the Mac's local policy, so reinstalls and updates need no network.
    To find out: whether a Mac that still has its factory macOS can lend its existing,
    already-personalized firmware to Finch's stub (no network at all), and whether a
    boot policy for a custom kernel is allowed on an external drive (the Tier 3 test on
    the external Finch volume will show).
  - Needs Finch drivers for the whole boot path (ANS, SEP, DCP, input, SMC/PMGR), because
    there are no Apple kexts to borrow.

**Exit:** Finch installs and boots on the M4 with zero Apple kexts and no macOS
installed.

## Phase 4: Open frameworks
The rest of the frameworks, ordered by app coverage (Foundation, CoreGraphics
and AppKit come in Phase 2).
- [ ] QuartzCore (Core Animation): on-screen animation playback and a render server
  - [x] Layers and their drawing through CoreGraphics, animation objects and transactions.
        `finch-calayer-test` matches Apple's on the host and in the VM (2026-10-09).
        Animations keep their values but do not yet play; without a render server, added
        animations end on the next run-loop turn, as on Apple's off-screen layers.
- [ ] PDFKit (Apple's Quartz re-exports it; Finch's Quartz re-exports only QuartzCore and ImageKit
      so far), Quick Look UI, the rest of ImageKit (image browser and view, picture taker, slideshow)
- [ ] Metal → Mesa
  - [x] Metal.framework without a device: descriptors as values with Apple's defaults,
        no devices (as on a Mac without a Metal GPU); CAMetalLayer hands out no drawables
        (2026-10-10). Apps that need a GPU (wgpu: PhotoCraft) stop with "no adapter".
  - [x] Apple's unmodified Digital Color Meter runs in the Finch VM: its magnifier follows
        the pointer and it reads out the pixel's values (2026-10-12). What it needed:
        ScreenCaptureKit, Finch's own (shareable content from the window list, content
        filters, screenshots, streams of sample buffers in BGRA or 4:2:0, the sharing
        picker), over a new window-server capture of chosen windows; the desktop listed
        as a window, as macOS's wallpaper window is, so captures and filters include or
        leave it out; window occlusion notifications; views that update their layers
        (`wantsUpdateLayer` as Apple's); immortal standard colours; CFGetTypeID of any
        object; text fields' intrinsic widths and sizes following their values; border and
        bezel flags as Apple's; custom-class views from nibs keeping their constraints.
        `screencapturekit-test` and `appkit-compat-test` match Apple's;
        `appkit-screencapture-test` captures on the window server; all three pass in the VM.
  - [ ] ScreenCaptureKit's remaining parts: audio and microphone samples, HDR captures
        (an HDR screenshot is the SDR pixels today), recording to a file (needs a video
        encoder), idle frames.
  - [ ] A device: software rendering, or a GPU driver (the M4's on metal)
- [x] OpenGL (2026-10-12): Mesa 25.0.7's softpipe renderer through OSMesa, built by Finch,
      as OpenGL.framework's libGL, under Finch's own CGL (pixel formats, contexts, renderer
      info; drawing into the app's memory refused, as on Apple silicon) and GLU
      (projections, quadrics, mipmaps); AppKit's NSOpenGLPixelFormat, NSOpenGLContext and
      NSOpenGLView draw into windows. `opengl-test` matches Apple's and
      `appkit-opengl-test` draws on the window server; both pass in the VM.
  - [x] Apple's unmodified Grapher runs in the VM: its new-graph chooser and a 2D
        graph's window draw (2026-10-12). What it needed besides OpenGL: typedstream
        (NSArchiver) coding of colours, fonts, named images, paragraph styles and tabs,
        shadows, Bézier paths, print info and transforms, byte for byte as Apple's;
        class versions set with `+setVersion:` reaching archives; Apple's type tolerances
        (a char read as a BOOL, a long as an int) and allowed classes; cell highlight
        colours chosen by the control view; image views keeping their own target and
        action; the cell and font SPI it calls. `appkit-typedstream-test`,
        `typedstream-test` and `appkit-compat-test` match Apple's.
  - [x] Grapher plots equations typed into a 2D graph, in the VM (2026-10-12). It needed
        Finch's system images (below), NSScanner subclasses that supply only their string
        and location, `-[NSImage initWithImageRep:]`, images' old `flipped` flag (it flips
        only drawing into the image) and compositing right side up in flipped views, and
        smaller methods its selectors reference (found by diffing them against Apple's
        AppKit and Foundation: NSArray and NSMutableDictionary conveniences, NSNumberFormatter's
        combined `format`, attribute subsets, the window's undo actions and cancel key, the
        zoom cursors). `data-test` and `appkit-compat-test` match Apple's.
  - [x] Grapher's 3D graphs draw in the VM: a typed surface, lit and checkered, with its
        axes (2026-10-12). They needed backing-coordinate conversions as Apple's (scaled
        view coordinates, no translation; the old "base" ones stay window-relative), GL
        surfaces shown above the window's other views as macOS orders them (surface order
        -1 puts one below), non-opaque GL views composited with alpha, and windows drawn
        into a back buffer that a flush copies to the window server, so it never shows a
        half-drawn frame. `appkit-compat-test`, `opengl-test` and `appkit-opengl-test`
        cover them.
  - [ ] Core-profile contexts (Apple's 3.2 and 4.1) and hardware rendering (with a device)
- [ ] Apple's unmodified ColorSync Utility in the VM
  - [x] Every import it makes (2026-10-12): Finch's PrintCore (sessions, print settings,
        page formats and papers, the generic printer, printing to PDF through a session,
        the colour-matching calls), QuartzFilters (filters, the manager and its view,
        Finch's own filter files whose colour effects apply through a CoreGraphics colour
        filter), ImageKit's save options, CoreGraphics' colour transforms and the private
        calls it makes (context types, interpolation ranges, process models, intents),
        ColorSync's signatures and localized strings, and an empty SystemAdministration.
        Gray bitmap contexts now convert images and text as Apple's do (luminance in linear
        light; text reached work-buffer contexts only through a fill copied too early).
        `printcore-test`, `quartzfilters-test`, `colorsync-test` and `private-calls-test`
        match Apple's, and pass in the VM.
  - [x] Its window, with all five utilities (2026-10-12): Profile First Aid with its help
        text, Profiles, Devices, Filters (Finch's filters listed) and Calculator with the
        installed profiles. What they needed: symbol images, `+bundleForClass:` finding a
        plug-in bundle of any extension (`.csutil`), `+loadNibNamed:owner:` taking a name
        with `.nib` (as `NSMainNibFile` gives it), a pop-up button cell taking its
        button's bindings, `NSByteCountFormatter` declining to parse, SkyLight's capture,
        cursor and notification calls, and ColorSync's chromatic adaptation. Finch's
        ColorSync now writes the standard profiles into `/System/Library/ColorSync/Profiles`,
        and `tools/app-sweep.py` counts the plug-in bundles an app loads (not its app
        extensions) against Finch as well.
  - [x] Its browsers and tools (2026-10-12): Profiles lists the installed profiles with
        their details, Devices its device groups, Calculator's wells show the colour, and
        the toolbar shows each utility's symbol (`doc.badge.gearshape`, and `calculator`,
        one of Apple's private symbols). What they needed: a nib's custom view swapped for
        its class taking the placeholder's place in a superview decoded first, subviews
        kept in archived order, `NSColorWell` taking nil as black, and field editors that
        lay out centred and right-aligned text within the field (a focused number field
        showed nothing) and highlight only the selected text.
  - [x] Devices lists the display with its factory and current profiles (2026-10-12):
        Finch's ColorSync keeps a device registry (registration, custom profiles, device
        profiles, iteration as Apple's; `colorsync-devices-test`), the main display
        always in it with sRGB; `CGSDisplayStatusQuery` answers as Apple's. Its details
        pane needed nib constraints to keep their symbolic NSSpace when a custom view is
        swapped in, a separator box's intrinsic size and alignment insets, labels'
        alignment insets and the help button's size.
  - [ ] The selected profile's 3D Lab plot (OpenGL). It draws (2026-10-12: `glFlush` and
        `glFinish` now show a single-buffered context's frame, as Apple's do, and
        ColorSync does gamut checks, the 1-bit destination with
        `kColorSyncTransformGamutCheck`), but the solid comes out far too close: the
        viewport and projection match Apple's, so the vertices the app builds from the
        profile's tags differ; to trace.
- [x] Combine: OpenCombine (MIT) adapted to Apple's ABI, with Finch's Merge, CombineLatest
      and collecting by time; every Combine symbol the system apps import (2026-10-09)
- [ ] SwiftUI: OpenSwiftUI (MIT) built as SwiftUI and SwiftUICore (`docs/design/SWIFTUI.md`)
  - [x] Both frameworks build and link against Finch's frameworks alone (2026-10-09)
  - [x] A minimal app draws and responds on the host, then in the VM (2026-10-09)
  - [ ] ABI parity, then the system apps, smallest first
- [x] CFNetwork, Finch's own: HTTP messages, authentication (Basic, Digest) and the HTTP
      stream, socket streams (CoreFoundation's and NSStream's), CFHost, Bonjour over dns_sd,
      proxy settings, FTP and CFNetDiagnostics; its comparison test matches Apple's on the
      host and in the VM (2026-10-10). Still to come: a JavaScript engine for PAC files
- [x] CoreImage, Finch's own: CIImage recipes rendered on the CPU in extended linear sRGB,
      CIContext output to memory, CGImages and files, and about seventy of Apple's filters
      (colour, compositing and blend modes, blurs, geometry, generators, reductions) whose
      pixels match Apple's on the host and in the VM (2026-10-10). Still to come: kernels
      in Core Image's kernel language or Metal, detectors, the remaining filters, GPU rendering
- [x] The frameworks third-party apps link most (measured over the apps on the build Mac):
      UserNotifications (local notifications), ServiceManagement (login items and agents as
      the user's launchd jobs), CoreLocation, LocalAuthentication, CoreWLAN, IOBluetooth and
      StoreKit (answering as a Mac without those services), NSStatusBar, NSSound,
      NSUserNotification, Quartz Event Services, Carbon hot keys and event handlers, Text
      Input Sources and UCKeyTranslate on a 'uchr' U.S. layout (matching Apple's
      translation). Amphetamine runs in the VM with its status item (2026-10-10)
- [ ] The URL loading system (Apple's is in CFNetwork; Finch's is in Foundation)
  - [x] Requests, responses, sessions; file, data and HTTP/1.1 loading; TLS over OpenSSL;
        Swift's URLRequest and async methods (2026-10-09)
  - [x] Pinned Mozilla CA bundle in the image; HTTPS trust checks pass on the host
        and in QEMU (2026-10-11).
  - [x] NSURLCache (memory and disk, by URL, with the request cache policies) and
        NSURLProtocol (per configuration and registered, redirects followed);
        `urlcache-test` matches Apple's (2026-10-11)
  - [ ] Cookies, authentication, HTTP/2, streaming delegate data, WebSocket and
        stream tasks
- [ ] AVFoundation / CoreAudio / CoreMedia ([media plan](design/MEDIA.md))
  - [x] CoreMedia and CoreVideo's buffer, time and format operations (2026-10-10).
  - [x] AudioToolbox format properties and PCM audio files (2026-10-10).
  - [x] Packed/unpacked PCM and G.711 conversion, channel maps, planar channels,
        callback reads, dithering and sample-rate conversion. Host and QEMU checks
        pass (2026-10-11); the resampling filter is Finch’s own.
  - [x] ExtAudioFile PCM/G.711 reads and writes, seek and sample-rate conversion;
        software AudioUnit converter/mixer paths. Host and QEMU checks pass
        (2026-10-11). Hardware output reports no connection.
  - [x] Offline interleaved PCM queues; AVFAudio formats, channel layouts and
        PCM buffers, including copies and caller-owned memory. Host, QEMU and
        VZ checks pass (2026-10-11).
  - [x] AVAudioFile PCM/G.711 reads and writes, seeks and short reads;
        AVAudioConverter software conversion, resampling and reset. Host,
        QEMU and VZ results match the focused native tests (2026-10-11).
  - [x] AVFAudio's engine graph (players, mixer, source/sink nodes, taps, offline
        rendering), AVAudioPlayer, the session, speech timing, AVAudioUnit with the
        delay, distortion, EQ, reverb, time-pitch, varispeed and sampler units over
        Finch's own effect DSP, and unit components. Host comparisons match Apple's
        (2026-10-11).
  - [x] CoreMedia's sound descriptions: QuickTime version 0, 1 and 2 and ISO audio
        sample entries to and from audio format descriptions ('wave'/'frma'/'enda',
        'esds' cookies with AAC's AudioSpecificConfig, 'chan', 'pcmC', 'chnl'), byte
        for byte as Apple's; `sounddesc-test` matches on the host and in the VM
        (2026-10-12).
  - [x] AVFoundation, first stage: the framework (re-exporting AVFAudio, with Apple's
        constants and metadata identifiers as data), Finch's own QuickTime/ISO reader,
        AVAsset/AVURLAsset/AVAssetTrack/AVAssetTrackSegment and AVMetadataItem: durations,
        tracks' times, sizes, rates and format descriptions, user data and common
        metadata, loading by key and its errors; `avasset-test` (a movie the test writes
        itself) matches Apple's on the host and in the VM (2026-10-12).
  - [x] AVFoundation, second stage: AVAssetReader (stored samples with Apple's marker
        buffers, JPEG decoded through ImageIO, PCM converted), AVAssetWriter with its
        inputs and pixel buffer adaptor (Finch's own QuickTime/MPEG-4 muxer; JPEG
        encoded through ImageIO, PCM, stored samples; QuickTime metadata and user data),
        AVAssetImageGenerator, and AVTime's NSValue and NSCoder additions. `avreader-test`,
        `avwriter-test` and `avimage-test` match Apple's on the host and in the VM, and
        Apple's AVFoundation reads and decodes the files Finch writes (2026-10-12).
  - [x] AVFoundation, playback: AVPlayer, AVPlayerItem (and its tracks), AVQueuePlayer,
        AVPlayerLooper, AVPlayerItemVideoOutput and AVPlayerLayer on the host clock:
        loading and status, play/pause and timeControlStatus, seeking, periodic and
        boundary observers, the end notification and action, frames on screen through
        Finch's window server. `avplayer-test` matches Apple's and
        `appkit-avplayer-test` shows the frames, on the host and in the VM (2026-10-12).
        Audio isn't heard until Finch has an audio device.
  - [ ] AVFoundation, next: export sessions, compositions and audio mixes, AVMovie,
        capture (with no devices), AVTimeFormatter, route detection; H.264, HEVC and AAC
        through VideoToolbox and AudioToolbox (the writer can't apply settings for them
        until then).
  - [ ] Compressed conversion, remaining audio properties and queue operations,
        remaining AVFAudio pieces (environment node, sequencer, recorder,
        AUAudioUnit), VideoToolbox and AVKit. Real audio output needs Phase 3.

**Exit:** a defined app corpus (e.g., top 50 non-App-Store Mac apps) runs with no Apple
binaries.

## Phase 5: Finch 1.0
Installer (the standalone install from Phase 3, run from recoveryOS), updates, Finch desktop polish, security model (code signing, sandbox, SIP-like
protections under Finch's own keys).

Earlier unchecked work remains part of the release. A completed framework entry means
its listed operations work; exported names and passing small tests do not establish
that every app works. These release checks were missing from the Phase 5 list:

- [ ] **Boot and install:** finish Phase 3's open boot-path drivers and prove a clean
      install from recoveryOS on the dedicated Finch container. Keep a working recovery
      path. The borrowed-kernel VM is a development target, not this release check.
- [ ] **Release image:** root-owned files, persistent user data, the deferred commands
      needed by the installer and desktop, and a repeatable build with source versions
      and licence notices recorded. Phase 1's remaining items stay open until checked.
      The [install payload](design/RELEASE.md) now records owners, permissions and
      file hashes. Archive checks and required-library checks pass. This is still
      an unsigned development payload; installation and persistent accounts remain open.
- [ ] **System services:** cron, configd, disk mounting and Bonjour; network settings
      that persist and notify apps when they change. Framework clients alone do not
      complete these services. See [Security and SystemConfiguration](design/SECURITY.md).
- [ ] **Trust and access:** a maintained system certificate store, persistent key storage,
      authorization, code-signature checks and enforced app restrictions. Test refused
      access as well as allowed access. Finch now has pinned web roots, a file
      keychain and signature checks. Keychain encryption, shared authorization,
      certificate updates and enforced app restrictions remain open.
- [ ] **Updates:** signed update files, interrupted-download recovery, safe installation,
      rollback to a working system and preservation of user files and settings.
- [ ] **App checks:** name and pin the Phase 4 app set, record what works in each app,
      and test launch, open/save, clipboard, printing, network access and media where
      used. Track missing APIs and failed checks rather than counting exported names.
- [ ] **Daily use:** persistent accounts and settings, accessibility, keyboard navigation,
      sleep/wake, shutdown, storage errors and low-space recovery on the target M4.
- [ ] **Test runner:** a failed program must fail the run even if its partial output
      matches. Exit checks are added and checked on the host (2026-10-11); the full
      host and VM suites still need a release pass, with each exception recorded.

- [ ] Fieldwork, Finch's design language (`docs/design/FIELDWORK.md`). Its parts:
  - [x] Theme tokens: Day and Night system colours, palette and metrics, in a theme file.
        A theme switch: Fieldwork by default, Classic (Aqua-compatible) for the comparison
        tests and per app (2026-10-09).
  - [x] The window frame: the window server shapes windows (6 pt top corners, 2 pt
        bottom), with an outline and a shallow shadow on a chalk desktop. The title bar is
        slate, with a top highlight, the key window's green mark, and the left control
        cluster (2026-10-09).
  - [ ] Controls: buttons, pop-ups, segmented controls, check boxes, sliders, fields,
        scrollers, tabs, menus.
    - [x] The shared control colours and bezels, and menus (2026-10-09).
    - [x] Scrollers: a slim graphite bar with nearly square ends (2026-10-09).
    - [ ] Tabs, fields' focus rings, table headers.
  - [x] Night: `AppleInterfaceStyle` Dark makes apps' appearance DarkAqua, as on macOS,
        and Fieldwork draws it in Night's values. Views draw in their effective appearance,
        uncoloured text in text views is textColor, and the window server's desktop and
        outlines follow `FINCH_APPEARANCE` (2026-10-09). The session setting it for both
        comes with Settings.
  - [ ] The Instrument Bar: app menus on the left, system context on the right.
    - [x] Drawn by each app's menu bar: FINCH, the menus, the workbench and the clock (2026-10-09).
    - [ ] A system process owning it (network, battery, the launcher behind FINCH). The
          launcher itself is the Rail's for now: a menu of every app, opened by Apple's
          Apps (Launchpad) app (2026-10-11).
  - [ ] The Rail, in place of the Dock.
    - [x] `Rail.app` (`userland/shell/Rail`): the finch mark, pinned and running apps with
          per-window marks, the workbench switcher. Apps' visible frame leaves it out, and
          `FINCH_SHELL` starts it with the session in the VM (2026-10-09).
    - [ ] Hover names, drag to pin, retracting for full-screen apps.
  - [ ] Workbenches: named, persistent, defined in text files.
  - [ ] Window behaviour: alignment guides, layout zones, fill the workbench.
  - [ ] Illustrated icons, and the mascot in onboarding, empty states and About.

## Phase 6: Windows software
Run Windows applications on Finch, as CrossOver and Game Porting Toolkit do on macOS.
- **Wine** (LGPL-2.1, dynamically linked component) for the Win32/Win64 API layer.
- **ARM64 Windows apps** first: they need no CPU translation.
- **x86-64 apps:** BORROW Rosetta 2 from the user's macOS install at first. The open
  replacement is an x86 translator ported to Darwin: FEX-Emu or Box64 (MIT), or Wine's
  ARM64EC path with FEX.
- **Graphics:** DXVK / vkd3d-proton (Direct3D → Vulkan) on Mesa's Vulkan driver for AGX,
  which Phase 3/4 bring up anyway.

**Exit:** a defined corpus of Windows apps (ARM64 and x86-64) runs on Finch with no
Apple binaries.

## Phase 7: Linux binaries
Run arm64 Linux programs directly on XNU, as FreeBSD's Linuxulator and the original WSL 1
do: a syscall translation layer, not a VM.
- An ELF loader beside the Mach-O one, and a Linux syscall table mapped onto XNU's
  calls.
- Emulate the Linux-only interfaces:
  - futex, epoll, clone and its flags, inotify, eventfd and signalfd;
  - `/proc` and `/sys`;
  - later, namespaces and cgroups for containers.
- **Licensing:** FreeBSD's Linuxulator is BSD-licensed and shares XNU's BSD heritage, so
  it's a legitimate reference. Linux kernel code is GPL-only and can't be copied in: the
  same rule that keeps Darling out (`docs/LICENSING.md`).
- **Apple Silicon:**
  - 16K pages: most arm64 Linux software copes, as Asahi shows, but some binaries
    assume 4K pages.
  - Only arm64 Linux binaries run natively. x86 Linux binaries need a translator, FEX
    or box64, the same family as Phase 6's.

**Exit:** a defined set of arm64 Linux command-line programs and services runs unmodified
on Finch.

## Beyond: Finch for iPhone/iPad
Depends on a bootrom/iBoot path to unsigned code on target devices, which is not
available on current iPhones without exploits. This is a research track, not a schedule.
