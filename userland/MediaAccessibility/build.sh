#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Caption preferences and image-caption metadata over Finch's CoreFoundation, CoreText and ImageIO.
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/MediaAccessibility"
ROOT="${FINCH_ROOT}/build/root"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
FW="${ROOT}/System/Library/Frameworks/MediaAccessibility.framework"

[[ -f "${SDKROOT}/System/Library/Frameworks/MediaAccessibility.framework/Headers/MediaAccessibility.h" ]] || {
    echo "MediaAccessibility headers are missing from the macOS SDK" >&2
    exit 1
}
for dependency in Foundation CoreFoundation CoreGraphics CoreText ImageIO; do
    [[ -e "${ROOT}/System/Library/Frameworks/${dependency}.framework/${dependency}" ]] || {
        echo "build ${dependency} first" >&2
        exit 1
    }
done

CFLAGS="-Wno-availability -F${SDKROOT}/System/Library/Frameworks" \
    "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/MediaAccessibility.framework/Versions/A/MediaAccessibility \
    1.0.0 1.0.0 com.apple.MediaAccessibility 1.0 \
    "${HERE}/MediaAccessibility.m" -- -framework ImageIO -framework CoreText -framework CoreGraphics -framework Foundation -framework CoreFoundation

# SDK headers describe the ABI but are not part of Finch's installed framework.
rm -rf "${FW}/Headers" "${FW}/Modules" "${FW}/Versions/A/Headers" "${FW}/Versions/A/Modules"
