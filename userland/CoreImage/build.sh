#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# CoreImage.framework: Finch's. Images are recipes rendered on the CPU in Apple's
# working space (extended linear sRGB, premultiplied); CIContext writes them to memory,
# CGImages, CGContexts and files (ImageIO); about seventy of Apple's built-in filters
# (CIFilterTable.m, their interfaces generated from the published attributes in
# CIFilterSpecs.inc). CIConstants.m has Apple's constant values.
#   userland/CoreImage/build.sh -> build/root/System/Library/Frameworks/CoreImage.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/CoreImage"
FW="${FINCH_ROOT}/build/root/System/Library/Frameworks/CoreImage.framework"
CFLAGS="-Wno-incomplete-implementation -Wno-objc-property-implementation -Wno-deprecated-implementations -Wno-protocol \
-Wno-objc-designated-initializers -Wno-objc-missing-super-calls -Wno-sign-compare -Wno-unused-function" \
"${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/CoreImage.framework/Versions/A/CoreImage 7 1.0.1 com.apple.CoreImage 19.0.0 \
    "${HERE}"/CIConstants.m "${HERE}"/CIColor.m "${HERE}"/CIImage.m "${HERE}"/CIContext.m "${HERE}"/CIFilter.m \
    "${HERE}"/CIFilterTable.m "${HERE}"/CIMisc.m \
    -- -framework Foundation -framework CoreGraphics -framework ImageIO -lobjc
plutil -replace CFBundleVersion -string 1592.80.2 "${FW}/Versions/A/Resources/Info.plist"
