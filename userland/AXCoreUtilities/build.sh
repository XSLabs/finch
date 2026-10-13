#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# AXCoreUtilities.framework (private): Finch's (AXCoreUtilities.swift).
#
#   userland/AXCoreUtilities/build.sh -> build/root/System/Library/PrivateFrameworks/AXCoreUtilities.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FINCH_PRIVATE_FRAMEWORK=1 exec "${FINCH_ROOT}/tools/build-swift-framework.sh" AXCoreUtilities 1 \
    "${FINCH_ROOT}/userland/AXCoreUtilities/AXCoreUtilities.swift" -- -framework Foundation
