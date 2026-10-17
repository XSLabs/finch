#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Intents.framework: local value objects and a Finch-owned interaction store.
# The macOS SDK supplies declarations at build time; its headers stay out of build/root.
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/Intents"
ROOT="${FINCH_ROOT}/build/root"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
HEADERS="${SDKROOT}/System/Library/Frameworks/Intents.framework/Headers/Intents.h"
GENERATED="${FINCH_ROOT}/build/IntentsGenerated.m"

[[ -f "${HEADERS}" ]] || { echo "Intents headers are missing from the macOS SDK" >&2; exit 1; }
[[ -f "${ROOT}/System/Library/Frameworks/Foundation.framework/Foundation" ]] || {
    echo "build Foundation first" >&2
    exit 1
}

python3 "${HERE}/generate.py" --sdk "${SDKROOT}" --output "${GENERATED}"
CFLAGS="-Wno-incomplete-implementation -Wno-availability -Wno-objc-designated-initializers -Wno-error=objc-designated-initializers -Wno-objc-property-implementation -Wno-objc-protocol-method-implementation -Wno-objc-protocol-property-synthesis -Wno-protocol -F${SDKROOT}/System/Library/Frameworks" \
    "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/Intents.framework/Versions/A/Intents 1.0 1 com.apple.Intents 1.0 \
    "${HERE}/Intents.m" "${GENERATED}" -- -framework Foundation

# The framework uses SDK declarations to compile but never ships Apple's headers.
FW="${ROOT}/System/Library/Frameworks/Intents.framework"
rm -rf "${FW}/Headers" "${FW}/Modules" "${FW}/Versions/A/Headers" "${FW}/Versions/A/Modules"
