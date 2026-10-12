#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# AVFoundation.framework: Finch's (docs/design/MEDIA.md). Assets, tracks and metadata over
# Finch's own QuickTime/ISO reader (AVFMovie.m); Apple's constants (AVFConstants.m) and
# metadata identifiers (AVMetadataTables.m) as data. It re-exports AVFAudio, as Apple's.
#   userland/AVFoundation/build.sh -> build/root/System/Library/Frameworks/AVFoundation.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/AVFoundation"
OBJC_ARC=1 exec "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/AVFoundation.framework/Versions/A/AVFoundation 2 1 com.apple.avfoundation 2.0 \
    "${HERE}/AVFConstants.m" "${HERE}/AVFTypes.m" "${HERE}/AVMetadataTables.m" "${HERE}/AVMetadataItem.m" \
    "${HERE}/AVFMovie.m" "${HERE}/AVAsset.m" "${HERE}/AVAssetReader.m" "${HERE}/AVAssetWriter.m" "${HERE}/AVAssetImageGenerator.m" "${HERE}/AVTime.m" "${HERE}/AVPlayer.m" \
    -- -framework Foundation -framework CoreMedia -framework CoreGraphics -framework CoreVideo -framework UniformTypeIdentifiers -framework AudioToolbox -framework ImageIO -framework QuartzCore \
    -Wl,-reexport_framework,AVFAudio
