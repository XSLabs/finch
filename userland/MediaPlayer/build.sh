#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Local now-playing state, remote commands and artwork rendering for Finch AppKit.
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/MediaPlayer"
ROOT="${FINCH_ROOT}/build/root"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
FW="${ROOT}/System/Library/Frameworks/MediaPlayer.framework"

[[ -f "${SDKROOT}/System/Library/Frameworks/MediaPlayer.framework/Headers/MediaPlayer.h" ]] || {
    echo "MediaPlayer headers are missing from the macOS SDK" >&2
    exit 1
}
for dependency in Foundation AppKit CoreGraphics; do
    [[ -e "${ROOT}/System/Library/Frameworks/${dependency}.framework/${dependency}" ]] || {
        echo "build ${dependency} first" >&2
        exit 1
    }
done

CFLAGS="-Wno-availability -F${SDKROOT}/System/Library/Frameworks" \
    "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/MediaPlayer.framework/Versions/A/MediaPlayer \
    1.0.0 1.0.0 com.apple.MediaPlayer 1.0 \
    "${HERE}/MPConstants.m" "${HERE}/MPNowPlaying.m" "${HERE}/MPRemoteCommands.m" -- \
    -framework AppKit -framework Foundation -framework CoreGraphics

rm -rf "${FW}/Headers" "${FW}/Modules" "${FW}/Versions/A/Headers" "${FW}/Versions/A/Modules"
