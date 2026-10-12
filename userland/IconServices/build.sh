#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# IconServices.framework (private): Finch's own icons for apps, files and types, at the
# sizes apps ask for (IconServices.m).
#   userland/IconServices/build.sh -> build/root/System/Library/PrivateFrameworks/IconServices.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/IconServices"
OBJC_ARC=1 "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/PrivateFrameworks/IconServices.framework/Versions/A/IconServices 1 1 com.apple.IconServices 1.0 \
    "${HERE}/IconServices.m" \
    -- -framework Foundation -framework CoreGraphics -framework ImageIO -framework CoreServices -framework UniformTypeIdentifiers
