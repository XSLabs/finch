#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# CloudKit records, sharing, subscriptions, sync state and no-account callbacks.
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/CloudKit"
ROOT="${FINCH_ROOT}/build/root"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
HEADERS="${SDKROOT}/System/Library/Frameworks/CloudKit.framework/Headers"
GENERATED="${FINCH_ROOT}/build/generated/CloudKitProperties_Generated.m"

[[ -f "${HEADERS}/CloudKit.h" ]] || { echo "CloudKit SDK headers are missing" >&2; exit 1; }
for dependency in Foundation CoreFoundation; do
    [[ -f "${ROOT}/System/Library/Frameworks/${dependency}.framework/${dependency}" ]] || {
        echo "build ${dependency} first" >&2
        exit 1
    }
done

python3 "${HERE}/generate-properties.py" "${HEADERS}" "${GENERATED}"
# Import CloudKit and Foundation's public SDK modules while compiling the overlay.
# Put the Finch frameworks after the SDK so their incomplete header sets do not
# hide the SDK headers needed by CloudKit's module map.
# The Swift search path loads the SDK's CloudKit overlay declarations. Clang
# needs its own framework path too, so SDK headers win over Finch's headerless
# runtime libraries when those declarations import Foundation.
FINCH_SWIFT_FLAGS="-F${SDKROOT}/System/Library/Frameworks -Xcc -F${SDKROOT}/System/Library/Frameworks -F${ROOT}/System/Library/Frameworks" \
FINCH_OBJC_FLAGS="-fobjc-weak -Wno-deprecated-declarations -Wno-incomplete-implementation -Wno-protocol -Wno-nullability -Wno-objc-protocol-method-implementation" \
    "${FINCH_ROOT}/tools/build-swift-framework.sh" CloudKit 2350.34 \
    "${HERE}/CloudKitOverlay.swift" \
    "${HERE}/CloudKitConstants.m" \
    "${HERE}/CloudKitModels.m" \
    "${HERE}/CloudKitOperations.m" \
    "${HERE}/CloudKitClient.m" \
    "${HERE}/CloudKitSharing.m" \
    "${HERE}/CloudKitSyncEngine.m" \
    "${GENERATED}" \
    -- -framework Foundation -framework CoreFoundation
