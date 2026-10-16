#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# AuthenticationServices.framework: Finch's authorization request and value API.
# Apple account, passkey, and system web-authentication services are not present;
# requests that need them report that absence instead of returning credentials.
#   userland/AuthenticationServices/build.sh
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/AuthenticationServices"
OBJ="${FINCH_ROOT}/build/obj/AuthenticationServices"
ROOT="${FINCH_ROOT}/build/root"
FW="${ROOT}/System/Library/Frameworks/AuthenticationServices.framework"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"
SWIFTC="$(xcrun -f swiftc)"
INSTALL_NAME=/System/Library/Frameworks/AuthenticationServices.framework/Versions/A/AuthenticationServices
log() { echo "==> $*"; }

for dep in Foundation AppKit Security; do
    [[ -f "${ROOT}/System/Library/Frameworks/${dep}.framework/${dep}" ]] || { echo "build ${dep} first" >&2; exit 1; }
done

FLAGS=(-arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -Os -g
    -fno-objc-arc -fobjc-exceptions -fblocks -fno-common
    -Wall -Wextra -Werror -Wno-unused-parameter -Wno-incomplete-implementation
    -Wno-objc-property-implementation -Wno-protocol -Wno-objc-protocol-method-implementation
    -Wno-deprecated-declarations -Wno-deprecated-implementations
    -Wno-objc-designated-initializers -Wno-objc-missing-super-calls
    -Wno-objc-method-access -Wno-objc-protocol-property-synthesis -Wno-nullability
    -I"${FINCH_ROOT}/userland")

log "compiling Objective-C"
rm -rf "${OBJ}"
mkdir -p "${OBJ}" "${FW}/Versions/A"
"${CC}" "${FLAGS[@]}" -c "${HERE}/AuthenticationServices.m" -o "${OBJ}/AuthenticationServices.o"

log "compiling Swift ABI overlay"
"${SWIFTC}" -target arm64e-apple-macos26.0 -sdk "${SDKROOT}" -module-name AuthenticationServices \
    -I "${HERE}" -enable-library-evolution -swift-version 5 -O -parse-as-library \
    -emit-object -o "${OBJ}/AuthenticationServices-swift.o" "${HERE}/AuthenticationServices.swift"

log "linking"
"${SWIFTC}" -target arm64e-apple-macos26.0 -sdk "${SDKROOT}" -module-name AuthenticationServices \
    -emit-library "${OBJ}/AuthenticationServices.o" "${OBJ}/AuthenticationServices-swift.o" \
    -o "${FW}/Versions/A/AuthenticationServices" \
    -Xlinker -install_name -Xlinker "${INSTALL_NAME}" \
    -Xlinker -current_version -Xlinker 624.1.16 -Xlinker -compatibility_version -Xlinker 1 \
    -F"${ROOT}/System/Library/Frameworks" -F"${ROOT}/System/Library/PrivateFrameworks" \
    -framework Foundation -framework Security -framework AppKit -lobjc
ln -sfn A "${FW}/Versions/Current"
ln -sfn Versions/Current/AuthenticationServices "${FW}/AuthenticationServices"
"${FINCH_ROOT}/tools/mkframeworkplist.sh" "${FW}" A AuthenticationServices \
    com.apple.AuthenticationServices AuthenticationServices 1.0 624.1.16 English
codesign -f -s - -i com.apple.AuthenticationServices "${FW}/Versions/A/AuthenticationServices" 2>/dev/null
log "installed ${FW#"${FINCH_ROOT}/"}"
