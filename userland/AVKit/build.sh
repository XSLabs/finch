#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# AVKit: Finch's player and route views over AVFoundation and AppKit. Picture-in-picture
# reports unsupported because Finch has no compositor service for it.
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/AVKit"
ROOT="${FINCH_ROOT}/build/root"
FW="${ROOT}/System/Library/Frameworks/AVKit.framework"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"

[[ -f "${SDKROOT}/System/Library/Frameworks/AVKit.framework/Headers/AVKit.h" ]] || {
    echo "AVKit headers are missing from the macOS SDK" >&2
    exit 1
}

for dependency in AppKit AVFoundation QuartzCore; do
    [[ -f "${ROOT}/System/Library/Frameworks/${dependency}.framework/${dependency}" ]] || {
        echo "build ${dependency} first" >&2
        exit 1
    }
done

CFLAGS="-F${SDKROOT}/System/Library/Frameworks" "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/AVKit.framework/Versions/A/AVKit 1.0 1.0 com.apple.AVKit 1.0 \
    "${HERE}/AVKit.m" -- -framework AppKit -framework AVFoundation -framework QuartzCore -framework Foundation

# Public declarations and module metadata come from the SDK at build time. Finch does
# not redistribute those files in its framework image.
rm -rf "${FW}/Headers" "${FW}/Modules" "${FW}/Versions/A/Headers" "${FW}/Versions/A/Modules"
