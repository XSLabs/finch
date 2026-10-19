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
    "${HERE}/AVFConstants.m" "${HERE}/AVFTypes.m" "${HERE}/AVMetadataTables.m" "${HERE}/AVMetadataItem.m" "${HERE}/AVProtocolReferences.m" "${HERE}/AVCapture.m" "${HERE}/AVComposition.m" "${HERE}/AVAudioMix.m" "${HERE}/AVVideoComposition.m" "${HERE}/AVMediaSelection.m" "${HERE}/AVAssetWriterInputGroup.m" "${HERE}/AVAssetWriterInputMetadataAdaptor.m" "${HERE}/AVCaption.m" "${HERE}/AVCaptionRenderer.m" "${HERE}/AVCaptionConversion.m" "${HERE}/AVSampleCursor.m" "${HERE}/AVSampleBufferGenerator.m" "${HERE}/AVSampleBufferDisplayLayer.m" "${HERE}/AVSampleBufferAudioRenderer.m" "${HERE}/AVTimedMetadataGroup.m" "${HERE}/AVTextStyleRule.m" "${HERE}/AVAssetDownloadValues.m" "${HERE}/AVRouteDetector.m" "${HERE}/AVAssetReaderAudioMixOutput.m" "${HERE}/AVTimeFormatter.m" "${HERE}/AVPlayerItemMediaDataCollector.m" \
    "${HERE}/AVFMovie.m" "${HERE}/AVAsset.m" "${HERE}/AVMovie.m" "${HERE}/AVAssetVariant.m" "${HERE}/AVSampleBufferRenderSynchronizer.m" "${HERE}/AVAssetReader.m" "${HERE}/AVAssetWriter.m" "${HERE}/AVAssetExportSession.m" "${HERE}/AVAssetImageGenerator.m" "${HERE}/AVTime.m" "${HERE}/AVPlayer.m" \
    -- -framework Foundation -framework CoreMedia -framework CoreGraphics -framework CoreText -framework CoreVideo -framework UniformTypeIdentifiers -framework AudioToolbox -framework ImageIO -framework QuartzCore \
    -Wl,-reexport_framework,AVFAudio
