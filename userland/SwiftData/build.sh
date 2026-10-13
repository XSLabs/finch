#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# SwiftData.framework: Finch's, to Apple's interface (SwiftData.swift).
#
#   userland/SwiftData/build.sh -> build/root/System/Library/Frameworks/SwiftData.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec "${FINCH_ROOT}/tools/build-swift-framework.sh" SwiftData 1 "${FINCH_ROOT}/userland/SwiftData/SwiftData.swift" -- \
    -framework Foundation
