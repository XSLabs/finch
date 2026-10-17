#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Smart-card token values, BER/Simple/Compact TLV records and empty reader discovery.
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/CryptoTokenKit"
ROOT="${FINCH_ROOT}/build/root"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
FW="${ROOT}/System/Library/Frameworks/CryptoTokenKit.framework"

[[ -f "${SDKROOT}/System/Library/Frameworks/CryptoTokenKit.framework/Headers/CryptoTokenKit.h" ]] || {
    echo "CryptoTokenKit headers are missing from the macOS SDK" >&2
    exit 1
}
for dependency in Foundation Security; do
    [[ -e "${ROOT}/System/Library/Frameworks/${dependency}.framework/${dependency}" ]] || {
        echo "build ${dependency} first" >&2
        exit 1
    }
done

CFLAGS="-Wno-availability -F${SDKROOT}/System/Library/Frameworks" \
    "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/CryptoTokenKit.framework/Versions/A/CryptoTokenKit \
    1.0.0 1.0.0 com.apple.CryptoTokenKit 1.0 \
    "${HERE}/TKTLVRecord.m" "${HERE}/TKTokenWatcher.m" "${HERE}/TKTokenValues.m" -- \
    -framework Security -framework Foundation

rm -rf "${FW}/Headers" "${FW}/Modules" "${FW}/Versions/A/Headers" "${FW}/Versions/A/Modules"
