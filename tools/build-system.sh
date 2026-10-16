#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build Finch's system layer from source, in dependency order, into
# build/root: Apple's open-source libSystem projects, Finch's own libraries,
# the LLVM runtimes, libobjc and dyld. The kernel (tools/build-kernel.sh) and
# the SDK overlay (tools/mksdk.sh) come first. Then the image is built with
# tools/vm/mkramdisk.sh.
#
#   tools/build-system.sh            # everything
#   tools/build-system.sh libmalloc  # one step (names below)
#   tools/build-system.sh Foundation CFNetwork  # selected steps, in build order
#
# Stops at the first step that fails, and prints where its log is.
set -uo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${FINCH_ROOT}"

oss() {   # oss <project> <targets...>: build, then fail on any compile/link error
    local out status
    out=$(tools/build-oss.sh "$@" 2>&1)
    status=$?
    echo "${out}"
    [[ "${status}" -eq 0 ]] && grep -q "(build exit 0)" <<<"${out}" \
        && ! grep -q "failed in:" <<<"${out}" \
        && ! grep -q "linker command failed" "build/logs/$1.log"
}

# Like oss, for command projects: the tools listed in userland/oss/<project>.deferred
# (userland/INVENTORY.md) may fail; anything else failing stops the build.
oss_cmds() {   # oss_cmds <project> <targets...>
    local out failed allowed f status
    out=$(tools/build-oss.sh "$@" 2>&1)
    status=$?
    echo "${out}"
    [[ "${status}" -eq 0 ]] || return 1
    failed=$(sed -n 's/^  failed in: \(.*\)  (see.*/\1/p' <<<"${out}")
    if ! grep -q "(build exit 0)" <<<"${out}" && [[ -z "${failed}" ]] \
        && ! grep -q "failed only in test targets" <<<"${out}"; then
        echo "error: $1 failed without a known deferred target; see build/logs/$1.log" >&2
        return 1
    fi
    allowed=$(grep -v '^\s*#' "userland/oss/$1.deferred" 2>/dev/null)
    for f in ${failed}; do
        grep -qx "${f}" <<<"${allowed}" || { echo "error: $1: ${f} failed and isn't deferred" >&2; return 1; }
    done
}

# name | command
steps=(
    "sdk|tools/mksdk.sh"
    "crashreporter|make -s -C userland/CrashReporterClient"
    "libsyscall|oss libsyscall"
    "libplatform|oss libplatform"
    "libpthread|oss libpthread libsystem_pthread"
    "libpthread-dyld|oss libpthread 'libpthread dyld'"
    "libmalloc|oss libmalloc libsystem_malloc"
    "Libc|oss Libc libsystem_c.dylib"
    "libdarwin|oss Libc libsystem_darwin.dylib"
    "libc-dyld|oss Libc libc_dyld"
    "collections|oss Libc libsystem_collections"
    "libclosure|oss libclosure Blocks-dynamic"
    # (Xcode 26.4.1 builds the static variants too, as dependencies; they stay out of the image)
    "libdispatch|oss libdispatch libdispatch && rm -f build/root/usr/lib/system/liblibdispatch.a build/root/usr/lib/system/liblibdispatch_debug.a build/root/usr/lib/system/liblibfirehose_server.a"
    "Libinfo|oss Libinfo Libinfo"
    "libxpc|make -s -C userland/libxpc"
    "Libnotify|oss Libnotify libnotify notifyd notifyutil"
    "keymgr|oss keymgr libkeymgr.dylib"
    "removefile|oss removefile removefile"
    "copyfile|oss copyfile copyfile"
    "syslog|oss syslog libsystem_asl syslogd util aslmanager newsyslog"
    "configd|oss configd libsystem_configuration"
    "dnssd|oss mDNSResponder"
    "libmacho|oss cctools"
    "libiconv|oss libiconv charset libiconv iconv mkesdb mkcsmapper iconv_modules"
    "libutil|oss libutil util"
    "libmd|oss libmd libmd"
    "OpenBSM|oss OpenBSM bsm.0"
    "ncurses|oss ncurses libncurses"
    # its terminfo database, compiled from the same source
    "terminfo|userland/terminfo/build.sh"
    "OpenPAM|oss OpenPAM OpenPAM"
    # (the other pam_modules need closed frameworks: OpenDirectory, Heimdal, LocalAuthentication)
    # ICU (libicucore + data), for CoreFoundation (docs/design/COREFOUNDATION.md)
    "ICU|oss ICU"
    "tzdata|userland/tzdata/build.sh"
    "ca-certificates|userland/certificates/build.sh"
    "CoreFoundation|userland/CoreFoundation/build.sh"
    "SystemConfiguration|userland/SystemConfiguration/build.sh"
    "configd|userland/oss/configd.daemon.build.sh"
    # libxml2, for Foundation's NSXMLParser
    "libxml2|oss libxml2"
    # SQLite's pinned public-domain amalgamation, shared by CoreData.
    "libsqlite3|userland/libsqlite3/build.sh"
    # Auto Layout's private framework, which Foundation re-exports (docs/design/APPKIT.md)
    "CoreAutoLayout|userland/CoreAutoLayout/build.sh"
    # Foundation and CoreData both use the Combine framework's public API.
    "Combine|userland/Combine/build.sh"
    # Finch's Foundation (CF links it upward; docs/design/FOUNDATION.md)
    "Foundation|userland/Foundation/build.sh"
    # Finch's CoreData implementation (models, contexts, SQLite and memory stores).
    "CoreData|userland/CoreData/build.sh"
    # CFNetwork (HTTP, sockets, hosts, Bonjour, proxies), which CoreServices re-exports
    "CFNetwork|userland/CFNetwork/build.sh"
    "UniformTypeIdentifiers|userland/UniformTypeIdentifiers/build.sh"
    "CoreServices|userland/CoreServices/build.sh"
    # CoreSpotlight: a local searchable-item index and query engine over Finch's Metadata layer.
    "CoreSpotlight|userland/CoreSpotlight/build.sh"
    "IOKit|userland/IOKit/build.sh"
    # Finch's CoreGraphics over Skia (docs/design/COREGRAPHICS.md)
    "skia|userland/skia/build.sh"
    "CoreGraphics|userland/CoreGraphics/build.sh"
    "QuartzCore|userland/QuartzCore/build.sh"
    # SkyLight's SLS calls apps import directly, over CoreGraphics
    "SkyLight|userland/SkyLight/build.sh"
    # The open fonts Finch ships for Apple's (userland/fonts)
    "fonts|userland/fonts/build.sh"
    "CoreText|userland/CoreText/build.sh"
    "WindowServer|userland/WindowServer/build.sh"
    "ImageIO|userland/ImageIO/build.sh"
    # The app-imported CPU parts of Accelerate, over CoreGraphics and CoreFoundation.
    "Accelerate|userland/Accelerate/build.sh"
    # CoreImage: images as recipes, filters rendered on the CPU
    "CoreImage|userland/CoreImage/build.sh"
    # ColorSync (over skcms) and HIServices, which ApplicationServices re-exports
    "ColorSync|userland/ColorSync/build.sh"
    "HIServices|userland/HIServices/build.sh"
    "PrintCore|userland/PrintCore/build.sh"
    # ATS (font validation keys, libFontRegistry) and FontServices (libFontParser): for font managers
    "ATS|userland/ATS/build.sh"
    "SystemAdministration|userland/SystemAdministration/build.sh"
    # IconServices (private): icons for apps, files and types
    "IconServices|userland/IconServices/build.sh"
    # small private frameworks apps link for a few symbols (SoftLinking, AppSupport, ...)
    "SmallPrivate|userland/SmallPrivate/build.sh"
    # OnBoardingKit (private): welcome and privacy screens, the AppKit side
    "OnBoardingKit|userland/OnBoardingKit/build.sh"
    # Quick Look: thumbnails, the thumbnail generator, the preview panel and view
    "QuickLook|userland/QuickLook/build.sh"
    # AppKit and the frameworks around it (docs/design/APPKIT.md)
    "ApplicationServices|userland/ApplicationServices/build.sh"
    "UIFoundation|userland/UIFoundation/build.sh"
    "CoreUI|userland/CoreUI/build.sh"
    "AppKit|userland/AppKit/build.sh"
    "RecapPerformanceTesting|userland/RecapPerformanceTesting/build.sh"
    "Cocoa|userland/Cocoa/build.sh"
    # OSAnalytics (private): diagnostic reports; ConsoleKit (private): what Console is built on
    "OSAnalytics|userland/OSAnalytics/build.sh"
    "ConsoleKit|userland/ConsoleKit/build.sh"
    # AOSKit (private): iCloud account calls, with no account; AppleSRP (private): SRP-6a client
    "AOSKit|userland/AOSKit/build.sh"
    "AppleSRP|userland/AppleSRP/build.sh"
    # MagnifierSupport (private): Finch's Magnifier, in SwiftUI (needs userland/SwiftUI/build.sh)
    "MagnifierSupport|userland/MagnifierSupport/build.sh"
    # Calculate (private): Calculator's engine (keys, evaluation, units)
    "Calculate|userland/Calculate/build.sh"
    # what Calculator links besides: CalculateUI (private: its expression views), SwiftData,
    # TipKit, AppIntents, AXCoreUtilities (private)
    "CalculateUI|userland/CalculateUI/build.sh"
    "SwiftData|userland/SwiftData/build.sh"
    "TipKit|userland/TipKit/build.sh"
    "AppIntents|userland/AppIntents/build.sh"
    "AXCoreUtilities|userland/AXCoreUtilities/build.sh"
    # Network (the path monitor) and MobileAsset (empty asset catalogs): what Font Book links besides
    "Network|userland/Network/build.sh"
    "MobileAsset|userland/MobileAsset/build.sh"
    # libswiftFoundation, libswiftAppKit, libswiftCoreGraphics: re-exports, for older Swift apps
    "swift-framework-shims|userland/swift/framework-shims.sh"
    # What Terminal links besides: Carbon (HIToolbox, and OpenScripting: Finch's AppleScript
    # and the OSA calls, with osascript), audio, analytics, data detectors
    "Carbon|userland/Carbon/build.sh"
    # OSAKit: scripts, the script view and controller (Script Editor), over OpenScripting
    "OSAKit|userland/OSAKit/build.sh"
    "CoreAudio|userland/CoreAudio/build.sh"
    "AudioToolbox|userland/AudioToolbox/build.sh"
    "AudioUnit|userland/AudioUnit/build.sh"
    "CoreMIDI|userland/CoreMIDI/build.sh"
    "CoreAnalytics|userland/CoreAnalytics/build.sh"
    "libScreenReader|userland/libScreenReader/build.sh"
    "DataDetectorsCore|userland/DataDetectorsCore/build.sh"
    # Frameworks apps link for services Finch answers as a Mac without them would
    # (no location, biometrics, Wi-Fi, Bluetooth or App Store yet); notifications and
    # login items work in the app and through launchd
    "UserNotifications|userland/UserNotifications/build.sh"
    "CoreLocation|userland/CoreLocation/build.sh"
    "LocalAuthentication|userland/LocalAuthentication/build.sh"
    "ServiceManagement|userland/ServiceManagement/build.sh"
    "CoreWLAN|userland/CoreWLAN/build.sh"
    "IOBluetooth|userland/IOBluetooth/build.sh"
    "IOBluetoothUI|userland/IOBluetoothUI/build.sh"
    "ScreenCaptureKit|userland/ScreenCaptureKit/build.sh"
    "StoreKit|userland/StoreKit/build.sh"
    "Contacts|userland/Contacts/build.sh"
    # Contact pickers and cards over Finch Contacts and AppKit.
    "ContactsUI|userland/ContactsUI/build.sh"
    "Accounts|userland/Accounts/build.sh"
    "Metal|userland/Metal/build.sh"
    "MetalKit|userland/MetalKit/build.sh"
    "IOSurface|userland/IOSurface/build.sh"
    "GSS|userland/GSS/build.sh"
    "CoreMedia|userland/CoreMedia/build.sh"
    "VideoToolbox|userland/VideoToolbox/build.sh"
    "AVFAudio|userland/AVFAudio/build.sh"
    "AVFoundation|userland/AVFoundation/build.sh"
    # Link metadata fetched by Finch Foundation's URL loader and shown with AppKit.
    "LinkPresentation|userland/LinkPresentation/build.sh"
    "OpenGL|userland/OpenGL/build.sh"
    # Feature flags (os_feature_enabled's Swift face) and the device's answers (libMobileGestalt)
    "FeatureFlags|userland/FeatureFlags/build.sh"
    "libMobileGestalt|userland/libMobileGestalt/build.sh"
    # message tracer messages (built, sent nowhere: Finch collects nothing)
    "libDiagnosticMessagesClient|userland/libDiagnosticMessagesClient/build.sh"
    # Image Capture's frameworks: ImageCaptureCore, ICADevices, and Quartz with ImageKit
    # (docs/design/IMAGECAPTURE.md)
    "ImageCaptureCore|userland/ImageCaptureCore/build.sh"
    "ICADevices|userland/ICADevices/build.sh"
    "Quartz|userland/Quartz/build.sh"
    # Libraries Apple publishes that Finch's commands link (tools/check-closed.py).
    # libedit's generated headers come from its "make lists" target first.
    "zlib|oss zlib libz"
    "bzip2|oss bzip2 All"
    "libedit|oss libedit 'make lists' && oss libedit libedit"
    "libresolv|oss libresolv libresolv"
    # The same from upstream, where Apple doesn't publish its copy for 26.4.
    "xz|userland/xz/build.sh"
    "libxo|userland/libxo/build.sh"
    "libsbuf|userland/libsbuf/build.sh"
    # Closed on macOS; Finch's, over open codecs (needs zlib and xz first).
    "libcompression|userland/libcompression/build.sh"
    # Account checks use CommonCrypto, installed with Finch's corecrypto.
    "corecrypto|make -s -C userland/corecrypto install"
    "account-tools|make -s -C userland/account-tools"
    "OpenDirectory|make -s -C userland/OpenDirectory"
    # The Swift runtime (libobjc links it, as Apple's does)
    "swift|userland/swift/build.sh"
    "swift-overlays|userland/swift/overlays.sh"
    "CryptoKit|userland/CryptoKit/build.sh"
    "pam_modules|oss pam_modules rootok uwtmp self env group nologin sacl launchd"
    "pam|make -s -C userland/pam"
    "libsystem-finch|make -s -C userland/libsystem"
    "libm|make -s -C userland/libm"
    "Security|userland/Security/build.sh"
    "securityd|userland/securityd/build.sh"
    "pam-keychain|make -s -C userland/pam keychain"
    "SecurityFoundation|userland/SecurityFoundation/build.sh"
    # Certificate, identity, keychain, and authorization panels over AppKit/Security.
    "SecurityInterface|userland/SecurityInterface/build.sh"
    # Web sign-in, Apple ID, and passkey request types; system services report unavailable.
    "AuthenticationServices|userland/AuthenticationServices/build.sh"
    # DiskArbitration's client and daemon, from Apple's source.
    "DiskArbitration|userland/DiskArbitration/build.sh"
    "diskarbitrationd|userland/oss/DiskArbitration.daemon.build.sh"
    "diskdev_cmds|userland/oss/diskdev_cmds.build.sh"
    "msdosfs|userland/oss/msdosfs.build.sh"
    "trace|make -s -C userland/libsystem/trace install"
    "Libsystem|oss Libsystem Libsystem"
    "llvm-runtimes|tools/build-llvm-runtimes.sh"
    "objc4|oss objc4 objc-env objc"
    "dyld|oss dyld dyld libdyld"
    "libsysmon|make -s -C userland/libsysmon"
    # libdispatch's firehose server for finch-logd: a static archive (named by Xcode's
    # lib prefix on its target name), moved out of the image tree.
    "firehose|oss libdispatch libfirehose_server && mkdir -p build/userland/lib && mv -f build/root/usr/lib/system/liblibfirehose_server.a build/userland/lib/libfirehose_server.a"
    "logd|make -s -C userland/logd"
    "pboard|make -s -C userland/pboard"
    # pbcopy and pbpaste (the pasteboard from the command line)
    "pbcopy|make -s -C userland/pbcopy"
    # Finch's alert sound (made by userland/sounds/mksound.py)
    "sounds|make -s -C userland/sounds"
    # finch-update (signed updates, checked with Finch's Security)
    "update|make -s -C userland/update"
    # screencapture and its service (Apple's Screenshot app asks the service)
    "screencapture|make -s -C userland/screencapture"
    # Commands (userland/INVENTORY.md lists the deferred ones that don't build yet)
    "file_cmds|oss_cmds file_cmds executables"
    "shell_cmds|oss_cmds shell_cmds All_OSX"
    "text_cmds|oss_cmds text_cmds executables"
    "adv_cmds|oss_cmds adv_cmds Desktop"
    "system_cmds|oss_cmds system_cmds All_MacOSX"
    "bash|oss bash bash"
    "zsh|oss zsh"
    "bc|oss bc"
    "cron|oss cron"
    # Finch's own, after the commands so they're what the image gets
    "sh|make -s -C userland/sh"
    "mount_tmpfs|make -s -C userland/mount_tmpfs"
)

selected="$*"
for requested in "$@"; do
    known=0
    for s in "${steps[@]}"; do
        [[ "${s%%|*}" == "${requested}" ]] && known=1
    done
    if [[ "${known}" -eq 0 ]]; then
        echo "error: unknown build step '${requested}'" >&2
        exit 1
    fi
done
for s in "${steps[@]}"; do
    name="${s%%|*}" cmd="${s#*|}"
    [[ -n "${selected}" && " ${selected} " != *" ${name} "* ]] && continue
    echo "==> ${name}"
    if ! eval "${cmd}"; then
        echo "error: step '${name}' failed (logs in build/logs/)" >&2
        exit 1
    fi
done
echo "==> done; next: tools/vm/mkramdisk.sh"
