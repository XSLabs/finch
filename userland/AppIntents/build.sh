#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# AppIntents.framework: Finch's, to Apple's interface (AppIntents.swift).
#
#   userland/AppIntents/build.sh -> build/root/System/Library/Frameworks/AppIntents.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec "${FINCH_ROOT}/tools/build-swift-framework.sh" AppIntents 1 "${FINCH_ROOT}/userland/AppIntents/AppIntents.swift" -- \
    -framework Foundation
