#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Generate userland/CoreVideo/CVPixelFormats.c: the pixel format descriptions Apple's
# CoreVideo on this Mac has (bits per block, planes, subsampling, black blocks, the
# Core Graphics and OpenGL equivalents), as an embedded binary property list. Only the
# values are taken, as data; the code that uses them is Finch's.
#   tools/corevideo/gen-pixel-formats.sh
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
xcrun clang -o "${TMP}/dump" "${FINCH_ROOT}/tools/corevideo/dump-pixel-formats.c" -framework CoreVideo -framework CoreFoundation
"${TMP}/dump" "${TMP}/formats.plist"
OUT="${FINCH_ROOT}/userland/CoreVideo/CVPixelFormats.c"
{
    echo "/* SPDX-License-Identifier: MIT OR Apache-2.0 */"
    echo "/* The pixel format descriptions, with the values Apple's have, as a binary property"
    echo "   list (tools/corevideo/gen-pixel-formats.sh). */"
    echo "#include <stddef.h>"
    echo
    echo "const unsigned char _FinchCVPixelFormats[] = {"
    xxd -i < "${TMP}/formats.plist"
    echo "};"
    echo "const size_t _FinchCVPixelFormatsSize = sizeof _FinchCVPixelFormats;"
} > "${OUT}"
echo "wrote ${OUT#"${FINCH_ROOT}/"}"
