#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# AppIntents' local AppKit metadata, built over Finch's AppKit and AppIntents.
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FINCH_SWIFT_FLAGS="-I ${FINCH_ROOT}/build/obj/AppIntents" \
    "${FINCH_ROOT}/tools/build-swift-framework.sh" _AppIntents_AppKit 1 \
    "${FINCH_ROOT}/userland/_AppIntents_AppKit/_AppIntents_AppKit.swift" -- \
    -framework AppKit -framework AppIntents
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc -target arm64e-apple-macos26.0 -sdk "${SDKROOT}" -swift-version 5 -O \
    -parse-as-library -enable-library-evolution -emit-module -module-name _AppIntents_AppKit \
    -I "${FINCH_ROOT}/build/obj/AppIntents" \
    -emit-module-path "${FINCH_ROOT}/build/obj/_AppIntents_AppKit/_AppIntents_AppKit.swiftmodule" \
    "${FINCH_ROOT}/userland/_AppIntents_AppKit/_AppIntents_AppKit.swift"
