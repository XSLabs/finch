#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# CoreVideo.framework: Finch's CoreVideo. The display link and the host clock
# (CVDisplayLink.c); buffers and their attachments (CVBuffer.c); pixel buffers laid out
# as Apple's are, in memory of their own, an IOSurface's or the caller's
# (CVPixelBuffer.c), and their pools (CVPixelBufferPool.c); pixel format descriptions
# (CVPixelFormatDescription.c over CVPixelFormats.c, Apple's values); color code points
# and the Metal texture cache (CVMisc.m). CVConstants.m has Apple's constants.
#
# Linked as Apple ships it: Versions/A, current version 734.4, compatibility version 1.2.
#
#   userland/CoreVideo/build.sh -> build/root/System/Library/Frameworks/CoreVideo.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/CoreVideo"
[[ -f "${FINCH_ROOT}/build/root/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics" ]] || { echo "build CoreGraphics first" >&2; exit 1; }
OBJC_ARC=1 CFLAGS="-Wno-deprecated-declarations -fblocks" \
    "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/CoreVideo.framework/Versions/A/CoreVideo 734.4 1.2 com.apple.CoreVideo 1.8 \
    "${HERE}/CVConstants.m" "${HERE}/CVDisplayLink.c" "${HERE}/CVBuffer.c" "${HERE}/CVPixelBuffer.c" "${HERE}/CVPixelBufferPool.c" \
    "${HERE}/CVPixelFormatDescription.c" "${HERE}/CVPixelFormats.c" "${HERE}/CVMisc.m" \
    -- -framework Foundation -framework CoreFoundation -framework CoreGraphics -framework IOSurface
