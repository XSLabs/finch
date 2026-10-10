#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# CoreMedia.framework: Finch's. Times, ranges and mappings (CMTime.c), block buffers
# (CMBlockBuffer.c), format descriptions (CMFormatDescription.c), sample buffers
# (CMSampleBuffer.c), attachments (CMAttachment.c), the notification center
# (CMNotificationCenter.c), clocks, timebases and their synchronisation (CMSync.c),
# simple and buffer queues and memory pools (CMQueues.c), format descriptions from
# H.264 and HEVC parameter sets (CMParameterSets.c), metadata identifiers, data types and
# format descriptions (CMMetadata.c over CMMetadataTypes.c, Apple's values), tags, tag
# collections and tagged buffer groups (CMTag.c), QuickTime and ISO image descriptions
# (CMSampleDescriptions.c); CMConstants.m has Apple's constants.
#   userland/CoreMedia/build.sh -> build/root/System/Library/Frameworks/CoreMedia.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/CoreMedia"
SOURCES=()
for f in CMConstants.m CMTime.c CMBlockBuffer.c CMFormatDescription.c CMSampleBuffer.c CMAttachment.c CMNotificationCenter.c CMSync.c CMQueues.c CMParameterSets.c CMMetadata.c CMMetadataTypes.c CMTag.c CMSampleDescriptions.c; do
    [ -f "${HERE}/${f}" ] && SOURCES+=("${HERE}/${f}")
done
OBJC_ARC=1 CFLAGS="-Wno-deprecated-declarations -fblocks" \
    "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/CoreMedia.framework/Versions/A/CoreMedia 3305.24.5 1 com.apple.CoreMedia 1.0 \
    "${SOURCES[@]}" -- -framework Foundation -framework CoreFoundation -framework CoreVideo
