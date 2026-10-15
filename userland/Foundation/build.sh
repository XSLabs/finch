#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Foundation.framework: Finch's Foundation (docs/design/FOUNDATION.md),
# Objective-C over Finch's CoreFoundation, compiled against the SDK's
# Foundation headers so every method has Apple's signature.
#
# Linked as Apple ships it: Versions/C, current version 4424.1.255,
# compatibility version 300, re-exporting libobjc and CoreFoundation, and
# linking libicucore (measurement formats) and libxml2 (NSXMLParser) as
# Apple's does, and Combine (its publishers) as Apple's does. OpenSSL (corecrypto's build) is linked in with its symbols
# hidden, for the URL loading system's TLS (Apple's is in CFNetwork).
#
#   userland/Foundation/build.sh
#     -> build/root/System/Library/Frameworks/Foundation.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/Foundation"
OBJ="${FINCH_ROOT}/build/obj/Foundation"
ROOT="${FINCH_ROOT}/build/root"
FW="${ROOT}/System/Library/Frameworks/Foundation.framework"
CFFW="${ROOT}/System/Library/Frameworks/CoreFoundation.framework"
OPENSSL="${FINCH_ROOT}/build/obj/corecrypto-openssl"
CMARK_SRC="${FINCH_ROOT}/build/src/cmark-gfm"
CMARK_BUILD="${FINCH_ROOT}/build/obj/cmark-gfm"
CMARK_CORE="${CMARK_BUILD}/src/libcmark-gfm.a"
CMARK_EXTENSIONS="${CMARK_BUILD}/extensions/libcmark-gfm-extensions.a"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"
log() { echo "==> $*"; }

[[ -f "${ROOT}/System/Library/Frameworks/Combine.framework/Combine" ]] || { echo "build Combine first: userland/Combine/build.sh" >&2; exit 1; }
[[ -f "${OPENSSL}/libssl.a" ]] || { echo "build corecrypto first (make -C userland/corecrypto install)" >&2; exit 1; }
[[ -f "${CFFW}/Versions/A/CoreFoundation" ]] || { echo "build CoreFoundation first: userland/CoreFoundation/build.sh" >&2; exit 1; }
# As Apple's, Foundation re-exports Auto Layout's classes from the private
# CoreAutoLayout (the symbols in CoreAutoLayout.reexports), weakly linked.
[[ -f "${ROOT}/System/Library/PrivateFrameworks/CoreAutoLayout.framework/CoreAutoLayout" ]] || { echo "build CoreAutoLayout first: userland/CoreAutoLayout/build.sh" >&2; exit 1; }

# Foundation implements classes the SDK declares: the methods it doesn't have
# yet, and the protocol methods it gets from CoreFoundation, aren't errors.
CFLAGS=(-arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -Os -g
    -fno-objc-arc -fobjc-weak -fobjc-exceptions -fblocks -fno-common
    -Wall -Wextra -Werror -Wno-unused-parameter -Wno-incomplete-implementation
    -Wno-objc-property-implementation -Wno-protocol -Wno-objc-protocol-method-implementation
    -Wno-deprecated-declarations -Wno-deprecated-implementations -Wno-objc-designated-initializers
    -Wno-objc-missing-super-calls -Wno-sign-compare -Wno-objc-method-access
    -I"${SDKROOT}/usr/include/libxml2" -I"${OPENSSL}/include" -I"${FINCH_ROOT}/build/src/openssl/include"
    -I"${CMARK_SRC}/src" -I"${CMARK_BUILD}/src" -I"${CMARK_SRC}/extensions" -I"${CMARK_BUILD}/extensions")

# CommonMark parsing for NSAttributedString's Markdown constructors. cmark-gfm
# is pinned in userland/third-party-projects.txt and its notice ships in the image.
"${FINCH_ROOT}/tools/fetch-src.sh" cmark-gfm
cmake -S "${CMARK_SRC}" -B "${CMARK_BUILD}" -DCMARK_TESTS=OFF -DCMARK_STATIC=ON -DCMARK_SHARED=OFF \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER="${CC}" -DCMAKE_C_FLAGS=-fvisibility=hidden \
    -DCMAKE_OSX_ARCHITECTURES=arm64e -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DCMAKE_POLICY_VERSION_MINIMUM=3.10
cmake --build "${CMARK_BUILD}" --target libcmark-gfm_static libcmark-gfm-extensions_static --parallel 8

log "compiling"
rm -rf "${OBJ}" && mkdir -p "${OBJ}"
for f in "${HERE}"/*.m; do
    "${CC}" "${CFLAGS[@]}" -c "$f" -o "${OBJ}/$(basename "${f%.m}").o"
done

# The Swift half (Data, URL, the bridging of the collections, ...), which
# Apple's Foundation carries too: userland/Foundation/swift/overlay.sh.
"${HERE}/swift/overlay.sh"
SWIFTOBJ="${FINCH_ROOT}/build/obj/Foundation-swift"

log "linking"
mkdir -p "${FW}/Versions/C"
"${CC}" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib \
    -install_name /System/Library/Frameworks/Foundation.framework/Versions/C/Foundation \
    -current_version 4424.1.255 -compatibility_version 300 \
    "${OBJ}"/*.o "${SWIFTOBJ}/Foundation-swift.o" "${SWIFTOBJ}"/cshims/*.o -o "${FW}/Versions/C/Foundation" -licucore -lxml2 -lcompression -Wl,-no_warn_inits \
    "${CMARK_EXTENSIONS}" "${CMARK_CORE}" \
    -L"${OPENSSL}" -Wl,-hidden-lssl -Wl,-hidden-lcrypto \
    -L"${SWIFTOBJ}/coll" -Wl,-hidden-lCollectionsInternal -L"${SDKROOT}/usr/lib/swift" \
    -F"${ROOT}/System/Library/Frameworks" -Wl,-reexport_framework,CoreFoundation -Wl,-reexport-lobjc -lSystem -framework Combine -framework Security \
    -F"${ROOT}/System/Library/PrivateFrameworks" -Wl,-weak_framework,CoreAutoLayout \
    -Wl,-reexported_symbols_list,"${HERE}/CoreAutoLayout.reexports"
# Foundation carries the URL loading system itself: nothing may come from Apple's CFNetwork.
if otool -L "${FW}/Versions/C/Foundation" | grep -q CFNetwork.framework; then
    echo "error: Foundation links CFNetwork for:" >&2
    dyld_info -imports "${FW}/Versions/C/Foundation" | grep "from CFNetwork" >&2
    exit 1
fi
ln -sfn C "${FW}/Versions/Current"
ln -sfn Versions/Current/Foundation "${FW}/Foundation"
"${FINCH_ROOT}/tools/mkframeworkplist.sh" "${FW}" C Foundation com.apple.Foundation Foundation 6.9 4424.1.402 en_US
codesign -f -s - -i com.apple.Foundation "${FW}/Versions/C/Foundation" 2>/dev/null
NOTICES="${ROOT}/usr/share/finch/licenses"
mkdir -p "${NOTICES}/openssl" "${NOTICES}/swift-foundation" "${NOTICES}/swift-collections" "${NOTICES}/swift-foundation-overlay" "${NOTICES}/cmark-gfm"
cp "${FINCH_ROOT}/build/src/swift-foundation/"{LICENSE.md,NOTICE.txt} "${NOTICES}/swift-foundation/"
cp "${FINCH_ROOT}/build/src/swift-collections/LICENSE.txt" "${NOTICES}/swift-collections/"
cp "${FINCH_ROOT}/build/src/openssl/LICENSE.txt" "${NOTICES}/openssl/"
cp "${CMARK_SRC}/COPYING" "${NOTICES}/cmark-gfm/"
cp "${HERE}/swift/Darwin/LICENSE.txt" "${NOTICES}/swift-foundation-overlay/"
log "installed ${FW#"${FINCH_ROOT}/"}"
