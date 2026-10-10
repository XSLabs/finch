#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Generate userland/CoreMedia/CMMetadataTypes.c: the metadata data types Apple's
# CoreMedia on this Mac registers (descriptions, conformance), as an embedded binary
# property list. Only the values are taken, as data; the registry is Finch's code.
#   tools/coremedia/gen-metadata-types.sh
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
xcrun clang -o "${TMP}/dump" "${FINCH_ROOT}/tools/coremedia/dump-metadata-types.c" -framework CoreMedia -framework CoreFoundation
"${TMP}/dump" "${TMP}/types.plist"
OUT="${FINCH_ROOT}/userland/CoreMedia/CMMetadataTypes.c"
{
    echo "/* SPDX-License-Identifier: MIT OR Apache-2.0 */"
    echo "/* The metadata data types registered from the start, with the values Apple's has, as a"
    echo "   binary property list (tools/coremedia/gen-metadata-types.sh). */"
    echo "#include <stddef.h>"
    echo
    echo "const unsigned char _FinchCMMetadataTypes[] = {"
    xxd -i < "${TMP}/types.plist"
    echo "};"
    echo "const size_t _FinchCMMetadataTypesSize = sizeof _FinchCMMetadataTypes;"
} > "${OUT}"
echo "wrote ${OUT#"${FINCH_ROOT}/"}"
