#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# CoreSpotlight: Finch's local searchable-item index and query engine.
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/CoreSpotlight"
OBJ="${FINCH_ROOT}/build/obj/CoreSpotlight"
ROOT="${FINCH_ROOT}/build/root"
FW="${ROOT}/System/Library/Frameworks/CoreSpotlight.framework"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"
SWIFTC="$(xcrun -f swiftc)"
INSTALL_NAME=/System/Library/Frameworks/CoreSpotlight.framework/Versions/A/CoreSpotlight

log() { echo "==> $*"; }

log "compiling Objective-C and Swift"
rm -rf "${OBJ}"
mkdir -p "${OBJ}" "${FW}/Versions/A"
FLAGS=(-arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -Os -g -fblocks -fobjc-arc -fobjc-weak
    -Wall -Wextra -Werror -Wno-unused-parameter -Wno-deprecated-declarations -I"${HERE}")
for source in "${HERE}"/*.m; do
    "${CC}" "${FLAGS[@]}" -c "${source}" -o "${OBJ}/$(basename "${source%.m}").o"
done
"${SWIFTC}" -target arm64e-apple-macos26.0 -sdk "${SDKROOT}" -module-name CoreSpotlight \
    -import-underlying-module -parse-as-library -enable-library-evolution -swift-version 5 -O \
    -emit-object -o "${OBJ}/CoreSpotlightSwift.o" "${HERE}/CoreSpotlightSwift.swift"

log "linking"
"${SWIFTC}" -target arm64e-apple-macos26.0 -sdk "${SDKROOT}" -module-name CoreSpotlight \
    -emit-library "${OBJ}"/*.o -o "${FW}/Versions/A/CoreSpotlight" \
    -Xlinker -install_name -Xlinker "${INSTALL_NAME}" \
    -Xlinker -current_version -Xlinker 2418.4.13 -Xlinker -compatibility_version -Xlinker 1 \
    -F"${ROOT}/System/Library/Frameworks" -F"${ROOT}/System/Library/PrivateFrameworks" \
    -framework Foundation -framework UniformTypeIdentifiers -framework CoreServices \
    -Xlinker -reexport_framework -Xlinker CoreServices -lobjc
ln -sfn A "${FW}/Versions/Current"
ln -sfn Versions/Current/CoreSpotlight "${FW}/CoreSpotlight"
"${FINCH_ROOT}/tools/mkframeworkplist.sh" "${FW}" A CoreSpotlight com.apple.corespotlight CoreSpotlight 1.0 2418.4.13 English
codesign -f -s - -i com.apple.corespotlight "${FW}/Versions/A/CoreSpotlight" 2>/dev/null
log "installed ${FW#"${FINCH_ROOT}/"}"
