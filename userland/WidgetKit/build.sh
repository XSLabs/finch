#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Timeline value types and WidgetCenter's honest no-host behavior.
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/WidgetKit"
ROOT="${FINCH_ROOT}/build/root"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
FW="${ROOT}/System/Library/Frameworks/WidgetKit.framework"

[[ -f "${SDKROOT}/System/Library/Frameworks/WidgetKit.framework/Modules/WidgetKit.swiftmodule/arm64e-apple-macos.swiftinterface" ]] || {
    echo "WidgetKit Swift interface is missing from the macOS SDK" >&2
    exit 1
}
for dependency in Foundation Intents; do
    [[ -e "${ROOT}/System/Library/Frameworks/${dependency}.framework/${dependency}" ]] || {
        echo "build ${dependency} first" >&2
        exit 1
    }
done

FINCH_SWIFT_FLAGS="-module-cache-path ${FINCH_ROOT}/build/obj/WidgetKit/module-cache -F${SDKROOT}/System/Library/Frameworks" \
FINCH_OBJC_FLAGS="-Wno-availability -F${SDKROOT}/System/Library/Frameworks" \
    "${FINCH_ROOT}/tools/build-swift-framework.sh" WidgetKit 664.4.42.100 \
    "${HERE}/WidgetKit.swift" "${HERE}/WidgetKitConstants.m" -- \
    -framework Intents -framework Foundation

# The SDK supplies declarations during compilation; Finch does not install Apple's headers.
rm -rf "${FW}/Headers" "${FW}/Versions/A/Headers"
