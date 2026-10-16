# Finch software stack

What runs on Finch today and where each piece comes from, bottom to top.
`docs/ARCHITECTURE.md` explains the layers. `docs/ROADMAP.md` covers what comes next.
These diagrams are updated in every commit that changes the stack, and
`tools/render-stack.sh` checks that they render.

**As of 2026-10-15:** CryptoKit is built from swift-crypto 5.0.1, with BoringSSL
and XKCP linked privately; fixed-key host comparisons cover its hashes, HMAC, HKDF,
AES-GCM, ChaChaPoly, and P-256, P-384 and Curve25519 keys and signatures. Nothing
Finch builds links a closed library
(`tools/check-closed.py`). Finch's own Foundation covers about 140 of Apple's
classes, on a CoreFoundation that dispatches to Objective-C objects as Apple's
does (`docs/design/FOUNDATION.md`); its Markdown constructors use cmark-gfm,
linked privately into Foundation, and its NSXMLParser and NSXMLDocument read
with Apple's libxml2, built by Finch. Finch's CoreGraphics has begun, over Skia
(`docs/design/COREGRAPHICS.md`): bitmap contexts draw paths, images,
clips, shadows and transparency layers as Apple's do, PDF contexts write
through Skia's PDF backend, and Finch's own parser reads and draws PDF. Finch's ImageIO reads
PNG, JPEG, GIF, BMP, ICO and WebP and writes PNG and JPEG over the open
codecs Skia builds, and reads and writes TIFF with its own codec, returning the CGImages and properties Apple's does. CoreText lays out text with HarfBuzz, FreeType and ICU, as Apple's does,
in open fonts Finch ships in place of Apple's (Inter for the system
font, Open Runde for rounded text, Fragment Mono for SF Mono, XCharter for
Charter, and TeX Gyre Pagella for Palatino). Liberation stays for Helvetica,
Arial, Times and Courier; DejaVu for Menlo; Noto for other scripts and emoji.
DejaVu bold fills SF Mono's bold styles, which Fragment Mono lacks.
Finch's window server composites windows that apps draw with CoreGraphics
into shared memory, and routes input to them (`docs/design/WINDOWSERVER.md`).
Finch's AppKit (`docs/design/APPKIT.md`), split as Apple's is with a private
UIFoundation under it, runs windows on that server: views draw, events reach
them, nibs and storyboards load, and full-size content windows show their title
bars and nib-loaded toolbars. `NSTextView` uses TextKit 2 by default, with TextKit 1
available. Auto Layout solves constraints with Finch's own Cassowary solver, in
a private CoreAutoLayout that Foundation re-exports. Cocoa bindings, controllers,
alerts, sheets, open/save panels and NSWorkspace work. Their comparison tests,
including TextKit 2 and Auto Layout, match Apple's on the host and in the VM.
AppKit and the window server draw in Fieldwork, Finch's own design language
(`docs/design/FIELDWORK.md`), from a theme file of tokens; the Classic theme keeps
Aqua-compatible values for apps that need them and for the comparison tests.
Combine is open code (OpenCombine with Finch's additions) built to Apple's ABI
(`docs/design/COMBINE.md`), as is Swift System (swift-system, all of Apple's
`libswiftSystem` exports). SwiftUI is built from OpenSwiftUI, renamed to Apple's
modules, on Compute's attribute graph and the Swift runtime's Observation (apps'
`@Observable` types work with it); an unmodified SwiftUI app built with Xcode draws
its window on Finch's frameworks (`docs/design/SWIFTUI.md`); the frameworks it links that Apple keeps closed are Finch's own:
CoreVideo's display link, Accessibility, CoreTransferable and DeveloperToolsSupport. Terminal's need brought
CoreAudio (no devices until there's an audio driver), AudioToolbox's system sounds, Carbon with HIToolbox's
Carbon events and key translation, CoreAnalytics (which collects nothing), libScreenReader and
ColorSync (ICC profiles, Apple's named ones written by Finch and installed as the system's profiles, a device registry, and transforms over skcms),
HIServices (the accessibility client API, which reports no trust until Finch has an
accessibility server, Universal Access settings and the Process Manager) and
DataDetectorsCore (links, addresses, phone numbers and IP addresses found in text). With them, Apple's Terminal runs on Finch. Foundation carries the URL loading system
(file, data and HTTP(S) loading over OpenSSL, with cookies), and CFNetwork is Finch's own: HTTP
messages, authentication and streams, socket streams, CFHost, Bonjour over dns_sd,
proxy settings and FTP, matching Apple's in its comparison test. CoreImage is Finch's
own too: images are recipes rendered on the CPU in Apple's working space, and about seventy
of Apple's filters give Apple's pixels. Apps' status items, global hot keys and posted
Quartz events work through the window server; frameworks for services Finch doesn't have
yet (location, biometrics, Wi-Fi, Bluetooth, the App Store) answer as a Mac without them
would, so apps that link them run. CoreVideo's pixel buffers and pools are Finch's, laid out
byte for byte as Apple's are (in memory of their own or an IOSurface's), and CoreMedia's
times, block buffers, format descriptions (including those from H.264 and HEVC
parameter sets), sample buffers, clocks, timebases, queues, memory pools, metadata
identifiers and tags match Apple's in their comparison tests. OpenGL is Mesa's software
renderer (softpipe through OSMesa, built by Finch) under Finch's own CGL and GLU, and
AppKit's NSOpenGL views draw with it; AppKit's named system images and symbol images are Finch's own artwork; PrintCore is Finch's own (sessions, settings, page formats and papers, printing to PDF; no printers until there's a printing system), as are Quartz filters, which change a context's colours through CoreGraphics; windows draw into a back buffer that each flush copies to the window server; typedstream archives (NSArchiver) of AppKit's
colours, fonts, images, paragraph styles, shadows, paths and print info match Apple's. AppleScript is Finch's own
(`userland/OpenScripting`): a parser and interpreter for AppleScript's English dialect behind the Open
Scripting Architecture's calls, with OSAKit's script view and controller and NSAppleScript over them, and
`osascript`; compiled source, results, errors and their ranges match Apple's in their comparison test.
SwiftUI gained Settings scenes, group boxes, tab views, canvases (drawing through CoreGraphics),
outline lists, scene storage, search fields, inspectors, drop delegates and file exporters, and
NSFontCollection is in CoreText as Apple's is. The desktop's frame is the Instrument Bar (each app's menu bar) and the Rail, a
Finch app down the left edge that replaces the Dock.

CoreFoundation's local notification center shares observers with Foundation's
default `NSNotificationCenter`. Bundles read `.loctable` files and choose their
language using `AppleLanguages` and Apple's ICU matching. QuartzCore has layers
drawn through CoreGraphics, and AppKit's views can be layer-backed, animation objects and transactions. The layer test
matches Apple's on the host and in the VM; on-screen animation playback still
needs a render server.

CoreServices now includes local app lookup and launching, Apple event values
and local handlers, and filesystem helpers (`docs/design/CORESERVICES.md`).
CoreUI reads compiled asset catalogs for AppKit's named colors and images
(`docs/design/ASSETS.md`). Foundation also contains its Swift value types and
bridges, built from pinned Swift Foundation and Swift Collections sources.
The Darwin Swift overlays and AppKit's first Swift extensions build alongside it.
Security supplies keys, certificates, web and caller-root trust checks, file keychains,
code-signature checks and Secure Transport (TLS) over OpenSSL. Web roots come from
a pinned Mozilla bundle. New file keychains encrypt their contents and require a
password; process-local locking, unsafe-path refusal, changed-file rejection and
concurrent saves pass focused host and QEMU checks (2026-10-13). The per-user
keychain service also passes a QEMU check in which a second app reads an unlocked
keychain and locks out the first app. Login password integration and shared
authorization remain open.
SystemConfiguration reads local preferences and network state. Finch configd
shares store values and sends change callbacks between processes; user access
checks pass in QEMU. Settings watches recover after service restart; saved files
also survive service restart in a private test root. Disk Arbitration starts
and accepts client sessions. Apple's open-source FAT tools and basic mount/fsck
dispatchers now build. Manual loopback IPv4 and DNS apply pass in QEMU, including repeat apply.
Failed requests try to remove only newly added addresses; full undo remains open.
Local account tools share password checks with PAM and OpenDirectory; correct,
wrong and locked passwords pass in a private QEMU test folder. The real login
program also passes wrong-password refusal, user identity, home and logout checks
under a temporary setup shell (2026-10-13). A separate image now also passes
normal startup, password refusal, user login and return to login after logout.
The install archive records file owners, permissions and hashes and passes
required-library checks. Reboot persistence, broader network setup, real disk
mounting, first-user setup, login password integration with the keychain, and the
authorization service remain unfinished (`docs/design/SECURITY.md`).

Image Capture's frameworks are Finch's own
(`docs/design/IMAGECAPTURE.md`): ImageCaptureCore's browser finds no cameras or
scanners yet, and Quartz re-exports QuartzCore and ImageKit's device views
(PDFKit and Quick Look come later). The unmodified Image Capture app launches
on the host with Finch's frameworks and headless window server. It shows English
strings, its title bar, an empty toolbar and an empty device list. The framework
comparison also passes in the VM; the Tier 2 display and input work remains.

```mermaid
block-beta
    columns 1
    block:L7
        columns 4
        t7["Apps and desktop"]
        apps["Unmodified Mac apps on Finch's<br/>frameworks: Terminal, Stickies,<br/>TextEdit, Apps, Digital Color<br/>Meter, Grapher (in the VM),<br/>Image Capture (on the host;<br/>no devices yet); docs/APPS.md"]
        desktop["finch-windowserver<br/>windows over shared memory,<br/>Skia compositor, cursor,<br/>input routing (headless, viewer),<br/>captures of chosen windows;<br/>the desktop listed as a window"]
        shell["Fieldwork shell: the Rail<br/>(pinned and running apps,<br/>workbench switcher, app launcher;<br/>hears the Dock's requests);<br/>file manager to come"]
    end
    block:L6
        columns 4
        t6["App frameworks"]
        appkit["AppKit<br/>apps, windows, views, events,<br/>title bars, nib-loaded toolbars,<br/>drawing, nibs, storyboards,<br/>Auto Layout, stack views, text views and<br/>scrolling, tables, outlines and<br/>collection views (flow, grid and<br/>compositional layouts), menus and a menu bar,<br/>alerts, sheets, open and save panels,<br/>NSWorkspace (on the window server);<br/>Cocoa bindings and controllers,<br/>font and color panels, search/token/date controls,<br/>grids, popovers, drawers and rule editors;<br/>rulers, the find bar, text tables;<br/>animation groups and Touch Bar state;<br/>toolbar items, titlebar accessories,<br/>row actions, scrubbers, NSPreferences,<br/>file promises, glass views (slate);<br/>drag and drop (between apps<br/>through the window server);<br/>system and symbol images<br/>(Finch's own art);<br/>Fieldwork theme (Classic for Aqua compatibility);<br/>UIFoundation: fonts, string drawing,<br/>TextKit 1 and 2; Cocoa and<br/>ApplicationServices umbrellas"]
        cg["CoreGraphics<br/>bitmap contexts, paths, images,<br/>gradients, patterns, fonts, text,<br/>shadows (over Skia, skcms);<br/>PDF writing (SkPDF), PDF reading<br/>and drawing (own parser);<br/>window server client, displays,<br/>Quartz events (posting, sources)"]
        imageio["ImageIO<br/>image sources, thumbnails,<br/>destinations, property keys<br/>(libpng, libjpeg-turbo, libwebp,<br/>wuffs, via Skia); TIFF (own codec)"]
        coreimage["CoreImage<br/>images as recipes, CPU rendering<br/>in linear light, ~70 filters"]
        services["UserNotifications (local),<br/>ServiceManagement (launchd jobs),<br/>CoreLocation, LocalAuthentication,<br/>CoreWLAN, IOBluetooth (and its<br/>UI's panels), StoreKit,<br/>Accounts, GSS (answering as a Mac<br/>without those services would)"]
        contacts["Contacts<br/>the user's contacts in Finch's<br/>own store, groups, change history;<br/>name and address formatters, vCard"]
        ctio["CoreText<br/>fonts, shaping, lines, frames<br/>(HarfBuzz, FreeType, ICU)"]
        quartzcore["QuartzCore<br/>layers drawn through CoreGraphics,<br/>animation objects, transactions;<br/>animation playback still to come"]
        imagecap["ImageCaptureCore (device<br/>browser, finds no devices yet),<br/>ICADevices; Quartz umbrella<br/>with ImageKit's device views<br/>and save options, QuartzFilters<br/>(Finch's own filters)"]
        avplanned["VideoToolbox, AVKit,<br/>AVFoundation codecs (planned:<br/>docs/design/MEDIA.md)"]
        opengl["OpenGL<br/>CGL contexts and GLU (Finch's),<br/>NSOpenGL views; software<br/>rendering by Mesa"]
        coreservices["CoreServices<br/>app lookup and launch,<br/>local Apple events, files"]
        later["Metal (no GPU driven yet:<br/>no devices, descriptors<br/>as values)"]
        coreui["CoreUI<br/>compiled asset catalogs,<br/>named images and colors"]
        appsupport["CoreVideo (display link),<br/>Accessibility, CoreTransferable,<br/>DeveloperToolsSupport; CoreAudio,<br/>AudioToolbox (system sounds,<br/>Finch's own alert sound,<br/>AudioFormat properties, audio files,<br/>PCM/G.711 conversion,<br/>ExtAudioFile, software audio units:<br/>effects, EQ, reverbs, time-pitch,<br/>varispeed, sampler; offline<br/>PCM queues); AVFAudio<br/>(formats, layouts, PCM buffers,<br/>PCM/G.711 files and conversion,<br/>times, the engine graph:<br/>players, mixer, effect and<br/>instrument units, offline render;<br/>AVAudioPlayer, constants,<br/>session, silent speech),<br/>Carbon/HIToolbox (events, keys),<br/>OpenScripting (Finch's AppleScript:<br/>the OSA calls, osascript), OSAKit<br/>(script view and controller),<br/>ATS and FontServices (font<br/>registry; no validator yet),<br/>Network (path monitor),<br/>MobileAsset (empty catalogs),<br/>CoreAnalytics, libScreenReader;<br/>FeatureFlags, libMobileGestalt<br/>(the device's answers),<br/>libDiagnosticMessagesClient<br/>(messages sent nowhere);<br/>SkyLight's SLS calls (window<br/>capture, display queries);<br/>ScreenCaptureKit (shareable content,<br/>filters, screenshots, streams);<br/>ColorSync (profiles, devices,<br/>transforms);<br/>HIServices (AX client, Process Manager),<br/>PrintCore (sessions, settings, page<br/>formats, papers; print to PDF; no<br/>printers yet), SystemAdministration (empty);<br/>IconServices (app, file and type<br/>icons at the Mac's icon sizes);<br/>small private frameworks (SoftLinking,<br/>AppSupport, UserManagement, ...);<br/>OnBoardingKit (welcome and<br/>privacy screens);<br/>MagnifierSupport (Finch's<br/>Magnifier: the screen enlarged);<br/>ConsoleKit (live logs from the<br/>log store, log reports) and<br/>OSAnalytics (diagnostic reports);<br/>AppleSRP (SRP-6a client),<br/>AOSKit (no iCloud account);<br/>Quick Look (thumbnails, the<br/>preview panel and view);<br/>DataDetectorsCore (links in text);<br/>Text Input Sources, UCKeyTranslate,<br/>Carbon event handlers, hot keys;<br/>IOSurface (shared pixel buffers);<br/>CoreVideo pixel buffers and pools;<br/>CoreMedia (times, block, format<br/>and sample buffers, clocks,<br/>timebases, queues, metadata, tags,<br/>image and sound descriptions);<br/>AVFoundation (assets, tracks,<br/>metadata, readers, writers, image<br/>generation, playback and player<br/>layers over Finch's QuickTime/<br/>ISO reader and muxer; JPEG, PCM)"]
        swiftui["SwiftUI, SwiftUICore<br/>(OpenSwiftUI on Compute's<br/>attribute graph; first app draws)"]
    end
    block:L5
        columns 4
        t5["Foundation layer"]
        foundation["Foundation<br/>strings, numbers, decimals, threads,<br/>files, bundles, formatters, queues,<br/>KVC/KVO, JSON, archiving, regexes,<br/>attributed strings and Markdown,<br/>map/hash tables, undo, proxies,<br/>transforms, file handles, pipes, tasks,<br/>predicates, progress, file wrappers,<br/>units and measurements, XML parsing,<br/>list, relative-date, interval and name formatters,<br/>linguistic tagging, metadata queries,<br/>item providers, URL resource values,<br/>NSXPCConnection, URL loading (HTTP/1.1,<br/>TLS via OpenSSL, cache, cookies,<br/>custom protocols)"]
        uti["UniformTypeIdentifiers<br/>UTType, declared and<br/>dynamic types"]
        cfnetwork["CFNetwork<br/>HTTP messages and streams,<br/>socket streams (TLS via OpenSSL),<br/>CFHost, Bonjour (dns_sd),<br/>proxies, FTP"]
        cf["CoreFoundation<br/>swift-corelibs CF + Finch ObjC:<br/>toll-free dispatch, collections,<br/>ordered sets, NSCache, NSData, NSDate,<br/>NSURL, locales, calendars, defaults,<br/>run loops, attributed strings,<br/>streams, Mach ports, notifications;<br/>bundle languages and .loctable files"]
        security["Security<br/>keys, certificates, web roots,<br/>file keychains, signature checks,<br/>Secure Transport (OpenSSL);<br/>SecurityFoundation (SFAuthorization,<br/>certificate summaries)"]
        cryptokit["CryptoKit<br/>hashes, HMAC, HKDF,<br/>AES-GCM, ChaChaPoly,<br/>P-256, P-384, Curve25519"]
        od["OpenDirectory<br/>CFOpenDirectory,<br/>local account password checks"]
        icu["libicucore<br/>ICU-76142.4.7"]
        objc["libobjc (objc4)"]
        autolayout["CoreAutoLayout (private)<br/>constraints, anchors, VFL,<br/>Cassowary solver"]
        swift["Swift 6.3.1 runtimes<br/>Darwin overlays,<br/>Foundation and AppKit Swift<br/>(diffable data sources,<br/>suggestions, invalidation);<br/>Combine (OpenCombine + Finch);<br/>Swift System (swift-system)"]
        iokit["IOKit.framework<br/>(IOKitUser)"]
        gcore["GCoreFramework<br/>(gcore, on Finch Foundation)"]
        sysconfig["SystemConfiguration<br/>preferences and network reads;<br/>shared store via Finch configd;<br/>manual IPv4 and DNS apply"]
    end
    block:L4
        columns 4
        t4["Libraries"]
        comp["libcompression<br/>LZFSE, LZ4, Brotli, zlib, LZMA"]
        codecs["lzfse, lz4, brotli,<br/>liblzma, libxo, libsbuf"]
        osslibs["zlib, bzip2, libedit, libresolv,<br/>libiconv, ncurses (+ terminfo), OpenBSM,<br/>libxml2"]
        cmark["cmark-gfm 0.29.0.gfm.13<br/>(static, Foundation Markdown)"]
        pam["OpenPAM + pam_modules"]
        pamunix["pam_unix, Finch pam.d<br/>libfinchaccount, accountctl"]
        ess["libEndpointSecuritySystem"]
        mesa["Mesa 25.0.7<br/>(softpipe, OSMesa)<br/>for OpenGL"]
        tz["tzdata 2026c (IANA)"]
        skia["Skia m155 + FreeType, HarfBuzz,<br/>libpng, libjpeg-turbo, libwebp, wuffs<br/>(static, for CoreGraphics,<br/>ImageIO and ColorSync)"]
        fonts["Open fonts (data, not code)<br/>Inter, Open Runde, Fragment Mono,<br/>XCharter, Pagella, Liberation, DejaVu,<br/>Noto for other scripts and emoji,<br/>in place of Apple's, which can't ship"]
    end
    block:L3
        columns 4
        t3["libSystem"]
        libc["Libc, libmalloc, libpthread,<br/>libplatform, libdispatch, Libinfo,<br/>Libnotify, asl, copyfile"]
        kernlib["libsystem_kernel<br/>(libsyscall)"]
        dyld["dyld + Finch shared cache"]
        space3[" "]
        xpc["libxpc<br/>Apple's wire protocol"]
        cc["libcorecrypto<br/>over OpenSSL 3.5.9"]
        stubs["libsystem_* (sandbox, trace,<br/>featureflags, quarantine...), libm"]
        space3b[" "]
        cxx["libc++, compiler-rt<br/>(LLVM runtimes)"]
        space3c[" "]
        space3d[" "]
    end
    block:L2
        columns 4
        t2["Processes"]
        init["finch-init (PID 1)<br/>bootstrap server,<br/>system + user domains"]
        logd["finch-logd, finch-pboardd<br/>(pasteboards), pbcopy and pbpaste,<br/>finch-update (signed,<br/>resumable updates),<br/>screencapture and its service,<br/>launchctl, sh, mount_tmpfs, devtools"]
        daemons["notifyd, syslogd, aslmanager,<br/>newsyslog, dynamic_pager, atrun,<br/>cron, mDNSPosix, configd,<br/>diskarbitrationd"]
        space2[" "]
        cmds["file/shell/text/adv/system_cmds,<br/>bash, zsh, bc, su, login,<br/>mount, fsck, FAT helpers"]
        space2b[" "]
        space2c[" "]
    end
    block:L1
        columns 4
        t1["Kernel"]
        xnu["XNU xnu-12377.101.15<br/>+ Finch patches"]
        kexts["Platform drivers<br/>(Finch's later)"]
        space1[" "]
    end
    block:L0
        columns 4
        t0["Machines"]
        qemu["Tier 1: QEMU darwin-vm"]
        vz["Tier 2: Virtualization.framework<br/>guest, own kernel"]
        metal["Tier 3: M4 bare metal<br/>(deferred)"]
    end

    classDef layer fill:#111827,stroke:#111827,color:#ffffff,font-weight:bold
    classDef apple fill:#dbeafe,stroke:#1d4ed8,color:#0b1b3f
    classDef finch fill:#fde68a,stroke:#b45309,color:#3b2300
    classDef upstream fill:#dcfce7,stroke:#15803d,color:#052e12
    classDef planned fill:#f3f4f6,stroke:#9ca3af,color:#6b7280,stroke-dasharray:4 3
    classDef firmware fill:#fee2e2,stroke:#b91c1c,color:#450a0a
    classDef testapp fill:#ede9fe,stroke:#7c3aed,color:#4c1d95
    classDef blank fill:none,stroke:none
    class t7,t6,t5,t4,t3,t2,t1,t0 layer
    class avplanned,kexts,metal planned
    class apps testapp
    class opengl,later,coreimage,services,contacts,cfnetwork,appsupport,shell,uti,appkit,quartzcore,coreservices,coreui,security,cryptokit,sysconfig,imagecap,desktop,cg,imageio,ctio,cf,autolayout,foundation,od,comp,pamunix,ess,xpc,cc,stubs,init,logd finch
    class icu,objc,iokit,gcore,osslibs,pam,libc,kernlib,dyld,daemons,cmds,xnu apple
    class swift,codecs,cxx,qemu,tz,skia,mesa,fonts,swiftui,cmark upstream
    class vz firmware
    class space3,space3b,space3c,space3d,space2,space2b,space2c,space1 blank
```

| Colour | Meaning |
|---|---|
| Blue | Apple's open source, built by Finch (pinned tags, `userland/projects.txt`) |
| Yellow | Written by Finch |
| Green | Third-party upstream, built by Finch |
| Red | Apple firmware, boot chain or host software (the VZ hypervisor), used as shipped (never redistributed) |
| Purple | Unmodified Mac app, supplied from macOS for testing |
| Grey, dashed | Planned |

## How the libraries link

The edges shown are load-time links (`otool -L`); common links to libSystem and
libobjc are omitted for most frameworks. CoreFoundation's upward link to
Foundation follows Apple's layout.

```mermaid
flowchart LR
    classDef apple fill:#dbeafe,stroke:#1d4ed8,color:#0b1b3f
    classDef finch fill:#fde68a,stroke:#b45309,color:#3b2300
    classDef upstream fill:#dcfce7,stroke:#15803d,color:#052e12
    classDef planned fill:#f3f4f6,stroke:#9ca3af,color:#6b7280,stroke-dasharray:4 3
    classDef closed fill:#ffffff,stroke:#b91c1c,color:#b91c1c,stroke-width:2px

    swiftui["SwiftUI"]:::upstream
    swiftuicore["SwiftUICore<br/>(OpenSwiftUI, Compute,<br/>Swift's Observation)"]:::upstream
    combine["Combine<br/>(OpenCombine + Finch)"]:::upstream
    gcore["GCoreFramework"]:::apple
    appkit["AppKit"]:::finch
    uif["UIFoundation<br/>TextKit 1 and 2"]:::finch
    appservices["ApplicationServices"]:::finch
    quartz["Quartz"]:::finch
    qc["QuartzCore"]:::finch
    imagekit["ImageKit"]:::finch
    imagecapture["ImageCaptureCore"]:::finch
    icadevices["ICADevices"]:::finch
    ffound["Foundation"]:::finch
    cgfw["CoreGraphics"]:::finch
    ctfw["CoreText"]:::finch
    imageio["ImageIO"]:::finch
    coreimagefw["CoreImage"]:::finch
    servicesfw["UserNotifications, CoreLocation,<br/>ServiceManagement, StoreKit, ..."]:::finch
    contactsfw["Contacts"]:::finch
    metalfw["Metal"]:::finch
    iosurfacefw["IOSurface"]:::finch
    coremediafw["CoreMedia"]:::finch
    audiotoolbox["AudioToolbox"]:::finch
    avfaudio["AVFAudio"]:::finch
    avfoundation["AVFoundation"]:::finch
    openglfw["OpenGL<br/>(CGL, GLU)"]:::finch
    mesalib["Mesa libGL<br/>(OSMesa, softpipe)"]:::upstream
    devicefw["FeatureFlags,<br/>libMobileGestalt,<br/>libDiagnosticMessagesClient"]:::finch
    calculatefw["Calculate (Calculator's<br/>engine: keys, RPN,<br/>programmer, units),<br/>CalculateUI (its views)"]:::finch
    appdatafw["SwiftData (models in a<br/>JSON store), TipKit<br/>(events, rules, tips),<br/>AppIntents (declared,<br/>not run)"]:::finch
    skylight["SkyLight"]:::finch
    secfound["SecurityFoundation"]:::finch
    btui["IOBluetoothUI"]:::finch
    sck["ScreenCaptureKit"]:::finch
    colorsync["ColorSync"]:::finch
    hiservices["HIServices"]:::finch
    printcore["PrintCore"]:::finch
    quartzfilters["QuartzFilters"]:::finch
    coreui["CoreUI"]:::finch
    coreservices["CoreServices"]:::finch
    uti["UniformTypeIdentifiers"]:::finch
    security["Security"]:::finch
    cryptokitfw["CryptoKit"]:::finch
    sysconfig["SystemConfiguration"]:::finch
    cfnetwork["CFNetwork"]:::finch
    openssl["OpenSSL (static)"]:::upstream
    swiftcrypto["swift-crypto 5.0.1<br/>BoringSSL + XKCP (static)"]:::upstream
    skialib["Skia, FreeType<br/>(static)"]:::upstream
    cmark["cmark-gfm 0.29.0.gfm.13<br/>(static)"]:::upstream
    cxxlib["libc++"]:::upstream
    cf["CoreFoundation"]:::finch
    cal["CoreAutoLayout"]:::finch
    iokit["IOKit"]:::apple
    od["OpenDirectory"]:::finch
    objc["libobjc"]:::apple
    swift["Swift runtimes and overlays"]:::upstream
    icu["libicucore"]:::apple
    xml["libxml2"]:::apple
    comp["libcompression"]:::finch
    codecs["lzfse / lz4 / brotli<br/>(static)"]:::upstream
    lzma["liblzma"]:::upstream
    z["libz"]:::apple
    pamlib["libpam (OpenPAM)"]:::apple
    pammods["pam_unix, pam_launchd, ..."]:::finch
    account["libfinchaccount<br/>accountctl"]:::finch
    su["su, login"]:::apple
    xpc["libxpc"]:::finch
    init["finch-init"]:::finch
    sys["libSystem.B"]:::apple
    kern["libsystem_kernel"]:::apple
    xnu["XNU"]:::apple

    swiftui -->|"re-exports"| swiftuicore
    swiftui --> appkit
    swiftuicore --> appkit
    swiftuicore --> qc
    swiftuicore --> ctfw
    swiftuicore --> combine
    swiftuicore --> appsup
    swiftui --> appsup
    appsup["CoreVideo, Accessibility,<br/>CoreTransferable,<br/>DeveloperToolsSupport"]:::finch
    ffound --> combine
    ffound --> openssl
    ffound --> cmark
    gcore --> ffound
    gcore -.->|"linked, unused"| comp
    appkit -->|"re-exports"| ffound
    appkit -->|"re-exports"| uif
    appkit -->|"re-exports"| appservices
    appkit --> cal
    appkit --> coreui
    coreui --> ffound
    coreui --> cgfw
    coreui --> imageio
    coreui --> comp
    coreui --> z
    coreservices --> ffound
    coreservices -->|"re-exports"| cfnetwork
    servicesfw --> ffound
    contactsfw --> ffound
    contactsfw --> imageio
    metalfw --> ffound
    iosurfacefw --> ffound
    coremediafw --> ffound
    avfaudio --> audiotoolbox
    avfoundation -->|"re-exports"| avfaudio
    avfoundation --> coremediafw
    avfoundation --> ffound
    openglfw -->|"re-exports"| mesalib
    openglfw --> iosurfacefw
    mesalib --> z
    mesalib --> cxxlib
    avfaudio --> ffound
    avfaudio --> coremediafw
    devicefw --> cf
    devicefw --> iokit
    calculatefw --> ffound
    calculatefw --> swiftui
    appdatafw --> ffound
    appdatafw --> swiftui
    skylight --> cgfw
    secfound --> security
    secfound --> ffound
    btui --> appkit
    sck --> appkit
    sck --> coremediafw
    sck --> cgfw
    sck --> imageio
    btui --> servicesfw
    audiotoolbox --> cf
    coreimagefw --> ffound
    coreimagefw --> cgfw
    coreimagefw --> imageio
    cfnetwork --> cf
    cfnetwork --> sysconfig
    cfnetwork --> openssl
    coreservices --> uti
    uti --> ffound
    security --> cf
    security --> openssl
    cryptokitfw --> swiftcrypto
    sysconfig --> cf
    uif --> ffound
    uif --> cgfw
    uif --> ctfw
    appservices -->|"re-exports"| cgfw
    appservices -->|"re-exports"| ctfw
    appservices -->|"re-exports"| imageio
    appservices -->|"re-exports"| colorsync
    appservices -->|"re-exports"| hiservices
    appservices -->|"re-exports"| printcore
    printcore --> cgfw
    hiservices --> cf
    colorsync --> cf
    colorsync --> skialib
    quartz -->|"re-exports"| qc
    quartz -->|"re-exports"| imagekit
    quartz -->|"re-exports"| quartzfilters
    quartzfilters --> appkit
    quartzfilters --> cgfw
    qc --> ffound
    qc --> cgfw
    qc --> ctfw
    imagekit --> appkit
    imagekit --> imagecapture
    imagecapture --> ffound
    imagecapture --> cgfw
    icadevices --> cf
    icadevices --> cgfw
    ffound -->|"re-exports"| cf
    cf -.->|"upward, as Apple's"| ffound
    ffound -.->|"weak, re-exports its classes"| cal
    cal -.->|"upward"| ffound
    cf --> objc --> swift
    cf --> icu
    ffound --> icu
    ffound --> xml
    xml --> icu
    xml --> z
    iokit --> cf
    cgfw --> cf
    ctfw --> cgfw
    ctfw --> cf
    ctfw --> icu
    ctfw --> skialib
    cgfw --> skialib
    cgfw --> cxxlib
    imageio --> cgfw
    imageio --> cf
    imageio --> skialib
    imageio --> cxxlib
    od --> cf
    comp --> codecs
    comp --> lzma
    comp --> z
    su --> pamlib --> pammods
    pammods --> xpc
    pammods --> account
    od --> account
    init --> xpc
    cf --> sys
    objc --> sys
    xpc --> sys
    sys --> kern --> xnu
```

App import checks now stop on failed or unreadable inspection output. They do not
count an inspection error as an app with no missing imports. The app test runner
also returns failure for a crashed app, a required window that never appears, an
unknown test step or a failed screenshot. Focused host checks pass (2026-10-13).
