#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build Finch's configd replacement and stage it where launchd expects it.
set -euo pipefail

FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OBJ="${OBJ:-${FINCH_ROOT}/build/obj/configd}"
STAGE="${STAGE:-${FINCH_ROOT}/build/root}"
SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
CC="$(xcrun -f clang)"

mkdir -p "${OBJ}/configd" "${STAGE}/usr/libexec"

flags=(
    -arch arm64e
    -mmacosx-version-min=26.0
    -isysroot "${SDKROOT}"
    -Os -g -fblocks -fno-common
    -Wall -Wextra -Werror
    -Wno-unused-parameter -Wno-deprecated-declarations -Wno-nonnull
    ${FINCH_SDK_CFLAGS:-}
)

"${CC}" "${flags[@]}" \
    -c "${FINCH_ROOT}/userland/oss/configd.daemon.c" -o "${OBJ}/configd/configd.o"
"${CC}" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" \
    "${OBJ}/configd/configd.o" \
    -F"${FINCH_ROOT}/build/root/System/Library/Frameworks" -framework CoreFoundation \
    -L"${FINCH_ROOT}/build/userland/libxpc" -lxpc \
    -o "${OBJ}/configd/finch-configd"

install -m 0755 "${OBJ}/configd/finch-configd" "${STAGE}/usr/libexec/configd"
codesign -f -s - -i org.finch.configd "${STAGE}/usr/libexec/configd"
