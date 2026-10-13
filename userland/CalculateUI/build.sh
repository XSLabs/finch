#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# CalculateUI.framework (private): the views Calculator shows expressions in, in SwiftUI, to
# the interface of Apple's (CalculateUI.swift). Needs userland/Calculate/build.sh first.
#
#   userland/CalculateUI/build.sh -> build/root/System/Library/PrivateFrameworks/CalculateUI.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FINCH_PRIVATE_FRAMEWORK=1 FINCH_SWIFT_FLAGS="-F ${FINCH_ROOT}/build/obj/Calculate-module" \
exec "${FINCH_ROOT}/tools/build-swift-framework.sh" CalculateUI 1 \
    "${FINCH_ROOT}/userland/CalculateUI/CalculateUI.swift" -- \
    -framework Foundation -framework AppKit -framework SwiftUI -framework Calculate
