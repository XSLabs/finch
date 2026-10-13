#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# MagnifierSupport.framework (private): Finch's Magnifier, in SwiftUI, to the ABI Apple's
# Magnifier.app links (MagnifierSupport.swift).
#
#   userland/MagnifierSupport/build.sh
#     -> build/root/System/Library/PrivateFrameworks/MagnifierSupport.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FINCH_PRIVATE_FRAMEWORK=1 exec "${FINCH_ROOT}/tools/build-swift-framework.sh" MagnifierSupport 1 \
    "${FINCH_ROOT}/userland/MagnifierSupport/MagnifierSupport.swift" -- \
    -framework Foundation -framework AppKit -framework SwiftUI -framework Combine -framework CoreGraphics
