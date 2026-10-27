#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# CoreSymbolication.framework (private), Finch's own: the running kernel's symbols
# (CoreSymbolication.c), for zprint and zlog. Its header goes into the build SDK's
# include folder (build/sdk/include): the public SDK has the framework's .tbd, which
# they link against, but no headers, and clang stops at a framework it finds.
#   userland/CoreSymbolication/build.sh -> build/root/System/Library/PrivateFrameworks/CoreSymbolication.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/CoreSymbolication"
mkdir -p "${FINCH_ROOT}/build/sdk/include/CoreSymbolication"
cp "${HERE}/include/CoreSymbolication/CoreSymbolication.h" "${FINCH_ROOT}/build/sdk/include/CoreSymbolication/"
CFLAGS="-I${HERE}/include -fblocks" \
"${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/PrivateFrameworks/CoreSymbolication.framework/Versions/A/CoreSymbolication 64575.51.1 1 \
    com.apple.CoreSymbolication 1.0 "${HERE}/CoreSymbolication.c" -- -framework CoreFoundation -F"${FINCH_ROOT}/build/root/System/Library/Frameworks" -framework IOKit
