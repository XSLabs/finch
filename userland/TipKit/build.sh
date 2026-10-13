#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# TipKit.framework: Finch's, to Apple's interface (TipKit.swift: events, parameters, rules,
# tips; TipViews.swift: tips on screen).
#
#   userland/TipKit/build.sh -> build/root/System/Library/Frameworks/TipKit.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/TipKit"
exec "${FINCH_ROOT}/tools/build-swift-framework.sh" TipKit 1 "${HERE}/TipKit.swift" "${HERE}/TipViews.swift" -- \
    -framework Foundation -framework AppKit -framework SwiftUI -framework Combine
