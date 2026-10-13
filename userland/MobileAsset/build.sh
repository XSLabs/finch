#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# MobileAsset.framework (private): Finch's, with empty catalogs (MobileAsset.m).
#   userland/MobileAsset/build.sh -> build/root/System/Library/PrivateFrameworks/MobileAsset.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
"${FINCH_ROOT}/tools/build-small-framework.sh" /System/Library/PrivateFrameworks/MobileAsset.framework/Versions/A/MobileAsset 1 1 \
    com.apple.MobileAsset 1.0 "${FINCH_ROOT}/userland/MobileAsset/MobileAsset.m" -- -framework Foundation
