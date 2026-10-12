#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Quick Look, Finch's own: QuickLook (thumbnails of files: QuickLook.m),
# QuickLookThumbnailing (QLThumbnailGenerator: QuickLookThumbnailing.m) and QuickLookUI
# (the preview panel and view: QuickLookUI.m).
#   userland/QuickLook/build.sh -> build/root/System/Library/Frameworks/QuickLook{,Thumbnailing,UI}.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/QuickLook"
B="${FINCH_ROOT}/tools/build-small-framework.sh"
F=/System/Library/Frameworks
QL="${FINCH_ROOT}/build/root${F}/QuickLook.framework/Versions/A/QuickLook"
OBJC_ARC=1 "$B" $F/QuickLook.framework/Versions/A/QuickLook 1 1 com.apple.QuickLookFramework 1.0 "${HERE}/QuickLook.m" \
    -- -framework Foundation -framework CoreGraphics -framework CoreText -framework ImageIO -framework UniformTypeIdentifiers
OBJC_ARC=1 "$B" $F/QuickLookThumbnailing.framework/Versions/A/QuickLookThumbnailing 1 1 com.apple.QuickLookThumbnailing 1.0 \
    "${HERE}/QuickLookThumbnailing.m" -- -framework AppKit -framework ImageIO -framework UniformTypeIdentifiers "${QL}"
OBJC_ARC=1 "$B" $F/QuickLookUI.framework/Versions/A/QuickLookUI 1 1 com.apple.QuickLookUIFramework 1.0 "${HERE}/QuickLookUI.m" \
    -- -framework AppKit -framework UniformTypeIdentifiers "${QL}"
