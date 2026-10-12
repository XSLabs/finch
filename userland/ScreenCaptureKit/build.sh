#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# ScreenCaptureKit.framework: Finch's screen capture over its window server
# (ScreenCaptureKit.m: content and filters; SCStream.m; SCScreenshotManager.m;
# SCContentSharingPicker.m).
#   userland/ScreenCaptureKit/build.sh -> build/root/System/Library/Frameworks/ScreenCaptureKit.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/ScreenCaptureKit"
exec "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/ScreenCaptureKit.framework/Versions/A/ScreenCaptureKit 1 1 com.apple.ScreenCaptureKit 1.0 \
    "${HERE}/ScreenCaptureKit.m" "${HERE}/SCStream.m" "${HERE}/SCScreenshotManager.m" "${HERE}/SCContentSharingPicker.m" \
    -- -framework AppKit -framework CoreMedia -framework CoreVideo -framework ImageIO -framework UniformTypeIdentifiers \
    -framework CoreGraphics
