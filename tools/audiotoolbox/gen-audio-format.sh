#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Generate userland/AudioToolbox/AudioFormatTables.c: the channel layouts, channel
# names and format names and defaults Apple's AudioToolbox on this Mac has, as an
# embedded binary property list. Only the values are taken, as data; the code that
# answers AudioFormat's properties from them is Finch's.
#   tools/audiotoolbox/gen-audio-format.sh
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
xcrun clang -o "${TMP}/dump" "${FINCH_ROOT}/tools/audiotoolbox/dump-audio-format.c" -framework AudioToolbox -framework CoreFoundation
"${TMP}/dump" "${TMP}/tables.plist"
OUT="${FINCH_ROOT}/userland/AudioToolbox/AudioFormatTables.c"
{
    echo "/* SPDX-License-Identifier: MIT OR Apache-2.0 */"
    echo "/* AudioFormat's tables (channel layouts and names, format names and defaults), with the"
    echo "   values Apple's has, as a binary property list (tools/audiotoolbox/gen-audio-format.sh). */"
    echo "#include <stddef.h>"
    echo
    echo "const unsigned char _FinchAudioFormatTables[] = {"
    xxd -i < "${TMP}/tables.plist"
    echo "};"
    echo "const size_t _FinchAudioFormatTablesSize = sizeof _FinchAudioFormatTables;"
} > "${OUT}"
echo "wrote ${OUT#"${FINCH_ROOT}/"}"
