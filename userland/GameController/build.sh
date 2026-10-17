#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# GameController profiles over Finch AppKit events, using only Apple's public SDK headers.
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/GameController"
ROOT="${FINCH_ROOT}/build/root"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
FW="${ROOT}/System/Library/Frameworks/GameController.framework"

[[ -f "${SDKROOT}/System/Library/Frameworks/GameController.framework/Headers/GameController.h" ]] || {
    echo "GameController headers are missing from the macOS SDK" >&2
    exit 1
}

for dependency in Foundation AppKit IOKit; do
    [[ -f "${ROOT}/System/Library/Frameworks/${dependency}.framework/${dependency}" ]] || {
        echo "build ${dependency} first" >&2
        exit 1
    }
done

CFLAGS="-F${SDKROOT}/System/Library/Frameworks" \
    "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/GameController.framework/Versions/A/GameController \
    13.4.9 1.0 com.apple.GameController 1.0 \
    "${HERE}/GCConstants.m" \
    "${HERE}/GCController.m" \
    "${HERE}/GCGamepadProfiles.m" \
    "${HERE}/GCInput.m" \
    "${HERE}/GCProfiles.m" \
    "${HERE}/GCSnapshots.m" \
    -- -framework AppKit -framework IOKit -framework Foundation

# The SDK supplies public declarations to Finch builds. Do not ship Apple headers.
rm -rf "${FW}/Headers" "${FW}/Modules" "${FW}/Versions/A/Headers" "${FW}/Versions/A/Modules"
