#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Network.framework: Finch's, to Apple's Swift ABI (Network.swift): the path monitor so far.
#   userland/Network/build.sh -> build/root/System/Library/Frameworks/Network.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec "${FINCH_ROOT}/tools/build-swift-framework.sh" Network 5812 \
    "${FINCH_ROOT}/userland/Network/Network.swift" -- -framework Foundation
