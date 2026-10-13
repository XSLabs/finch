#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# OSAKit.framework: Finch's, over Finch's OpenScripting (the OSA calls in Carbon): languages
# and scripts (OSAScript.m), the script controller (OSAScriptController.m), the script view
# and its text storage (OSAScriptView.m), the outline parser (OSAScriptParser.m), and what it
# adds to Foundation and AppKit classes (OSACategories.m).
#   userland/OSAKit/build.sh -> build/root/System/Library/Frameworks/OSAKit.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/OSAKit"
CFLAGS="-I${HERE}" OBJC_ARC=1 "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/OSAKit.framework/Versions/A/OSAKit 114 1 com.apple.OSAKit 1.6 \
    "${HERE}/OSAScript.m" "${HERE}/OSAScriptController.m" "${HERE}/OSAScriptView.m" "${HERE}/OSAScriptParser.m" "${HERE}/OSACategories.m" \
    -- -framework AppKit -framework Carbon -framework CoreServices -framework Foundation
