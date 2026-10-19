#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Vision's CPU requests and observations, built against the public macOS SDK.
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/Vision"
ROOT="${FINCH_ROOT}/build/root"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
FW="${ROOT}/System/Library/Frameworks/Vision.framework"

[[ -f "${SDKROOT}/System/Library/Frameworks/Vision.framework/Headers/Vision.h" ]] || {
    echo "Vision headers are missing from the macOS SDK" >&2
    exit 1
}

for dependency in Foundation CoreGraphics CoreMedia CoreVideo ImageIO CoreImage; do
    [[ -f "${ROOT}/System/Library/Frameworks/${dependency}.framework/${dependency}" ]] || {
        echo "build ${dependency} first" >&2
        exit 1
    }
done

CFLAGS="-F${SDKROOT}/System/Library/Frameworks -I${HERE}" \
    "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/Vision.framework/Versions/A/Vision \
    1.0 1.0 com.apple.Vision 1.0 \
    "${HERE}/VNConstants.m" \
    "${HERE}/VNTypesConstants.m" \
    "${HERE}/VNUtils.m" \
    "${HERE}/VNGeometry.m" \
    "${HERE}/VNObservation.m" \
    "${HERE}/VNRequests.m" \
    "${HERE}/VNImageRequestHandler.m" \
    "${HERE}/VNAlgorithms.m" \
    -- -framework Foundation -framework CoreGraphics -framework CoreMedia -framework CoreVideo \
       -framework ImageIO -framework CoreImage

# The SDK supplies public declarations to Finch builds. They are never installed.
rm -rf "${FW}/Headers" "${FW}/Modules" "${FW}/Versions/A/Headers" "${FW}/Versions/A/Modules"
