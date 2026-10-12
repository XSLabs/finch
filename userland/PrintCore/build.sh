#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# PrintCore.framework, inside ApplicationServices as Apple's is: Finch's (PrintCore.c).
#   userland/PrintCore/build.sh
#     -> build/root/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/PrintCore.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/PrintCore"
AS=/System/Library/Frameworks/ApplicationServices.framework
"${FINCH_ROOT}/tools/build-small-framework.sh" \
    "${AS}/Versions/A/Frameworks/PrintCore.framework/Versions/A/PrintCore" 1 1 com.apple.print.framework.PrintCore 18.0 \
    "${HERE}/PrintCore.c" \
    -- -Wl,-umbrella,ApplicationServices -framework CoreFoundation -framework CoreGraphics
ln -sfn Versions/Current/Frameworks "${FINCH_ROOT}/build/root${AS}/Frameworks"
