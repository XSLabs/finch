#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# SkyLight.framework (private): Finch's SLS calls over CoreGraphics (SkyLight.c).
#   userland/SkyLight/build.sh -> build/root/System/Library/PrivateFrameworks/SkyLight.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight 1 1 com.apple.SkyLight 1.0 \
    "${FINCH_ROOT}/userland/SkyLight/SkyLight.c" -- -framework CoreFoundation -framework CoreGraphics
