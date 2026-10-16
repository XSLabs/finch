#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# AppIntents.framework: Finch's, to Apple's interface (AppIntents.swift).
#
#   userland/AppIntents/build.sh -> build/root/System/Library/Frameworks/AppIntents.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
"${FINCH_ROOT}/tools/build-swift-framework.sh" AppIntents 1 "${FINCH_ROOT}/userland/AppIntents/AppIntents.swift" -- \
    -framework Foundation -framework CoreGraphics -framework CoreSpotlight -framework UniformTypeIdentifiers
xcrun swiftc -target arm64e-apple-macos26.0 -sdk "${SDKROOT}" -swift-version 5 -O \
    -parse-as-library -enable-library-evolution -emit-module -module-name AppIntents \
    -emit-module-path "${FINCH_ROOT}/build/obj/AppIntents/AppIntents.swiftmodule" \
    "${FINCH_ROOT}/userland/AppIntents/AppIntents.swift"
