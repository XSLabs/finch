#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Bluetooth identifiers, GATT values and honest unsupported manager state.
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/CoreBluetooth"
ROOT="${FINCH_ROOT}/build/root"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
FW="${ROOT}/System/Library/Frameworks/CoreBluetooth.framework"

[[ -f "${SDKROOT}/System/Library/Frameworks/CoreBluetooth.framework/Headers/CoreBluetooth.h" ]] || {
    echo "CoreBluetooth headers are missing from the macOS SDK" >&2
    exit 1
}
for dependency in Foundation CoreFoundation; do
    [[ -e "${ROOT}/System/Library/Frameworks/${dependency}.framework/${dependency}" ]] || {
        echo "build ${dependency} first" >&2
        exit 1
    }
done

CFLAGS="-Wno-availability -Wno-unavailable-declarations -Wno-objc-designated-initializers -F${SDKROOT}/System/Library/Frameworks" \
    "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/CoreBluetooth.framework/Versions/A/CoreBluetooth \
    1.0.0 1.0.0 com.apple.CoreBluetooth 1.0 \
    "${HERE}/CBUUID.m" "${HERE}/CBValues.m" "${HERE}/CBManagers.m" -- \
    -framework Foundation -framework CoreFoundation

rm -rf "${FW}/Headers" "${FW}/Modules" "${FW}/Versions/A/Headers" "${FW}/Versions/A/Modules"
