#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# ATS.framework (in ApplicationServices) with libFontRegistry.dylib, and the private
# FontServices.framework with libFontParser.dylib: what font managers link (Font Book).
#   userland/ATS/build.sh
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/ATS"
AS=/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks
B="${FINCH_ROOT}/tools/build-small-framework.sh"
"${B}" "${AS}/ATS.framework/Versions/A/Resources/libFontRegistry.dylib" 1 1 - - "${HERE}/FontRegistry.c" -- \
    -framework CoreFoundation -framework CoreText
"${B}" "${AS}/ATS.framework/Versions/A/ATS" 236 1 com.apple.ATS 236 "${HERE}/ATS.c" -- \
    -Wl,-umbrella,ApplicationServices -framework CoreFoundation
"${B}" /System/Library/PrivateFrameworks/FontServices.framework/Versions/A/FontServices 1 1 com.apple.FontServices 1.0 \
    "${HERE}/FontServices.c"
"${B}" /System/Library/PrivateFrameworks/FontServices.framework/libFontParser.dylib 1 1 - - "${HERE}/FontParser.c"
