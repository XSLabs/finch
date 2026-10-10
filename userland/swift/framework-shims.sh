#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# The Swift overlays that now live in their frameworks: as Apple's,
# /usr/lib/swift/libswift<Module>.dylib only re-exports the framework (which carries
# the Swift half and its __swift_FORCE_LOAD_$_swift<Module> symbol). Apps built before
# the move link these paths. libswiftFoundation also has the overlay's version symbols.
# Built after the frameworks (tools/build-system.sh).
#
#   userland/swift/framework-shims.sh -> build/root/usr/lib/swift/libswift{Foundation,AppKit,CoreGraphics}.dylib
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ROOT="${FINCH_ROOT}/build/root"
OBJ="${FINCH_ROOT}/build/obj/swift-framework-shims"
L="${ROOT}/usr/lib/swift"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"
log() { echo "==> $*"; }

# shim <module> <current version> <framework binary> <C source>
shim() {
    local out="${OBJ}/$1"
    [[ -f "${ROOT}$3" ]] || { echo "build $(basename "$3") first" >&2; exit 1; }
    rm -rf "${out}" && mkdir -p "${out}" "${L}"
    printf '%s\n' "$4" > "${out}/shim.c"
    log "libswift$1"
    "${CC}" -target arm64e-apple-macos26.0 -isysroot "${SDKROOT}" -dynamiclib "${out}/shim.c" -o "${out}/libswift$1.dylib" \
        -install_name "/usr/lib/swift/libswift$1.dylib" -current_version "$2" -compatibility_version 1 \
        -Wl,-reexport_library,"${ROOT}$3"
    install -m 0755 "${out}/libswift$1.dylib" "${L}/"
    codesign -f -s - "${L}/libswift$1.dylib" 2>/dev/null
}

shim Foundation 120.100 /System/Library/Frameworks/Foundation.framework/Versions/C/Foundation \
'__attribute__((visibility("default"))) const double FoundationVersionNumber = 120.1;
__attribute__((visibility("default"))) const unsigned char FoundationVersionString[] =
    "@(#)PROGRAM:Foundation  PROJECT:Foundation-swiftoverlay-120.100\n";'
shim AppKit 2685.50.120 /System/Library/Frameworks/AppKit.framework/Versions/C/AppKit ''
shim CoreGraphics 17 /System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics ''
