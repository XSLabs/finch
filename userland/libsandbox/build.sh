#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# A small sandbox ABI for Finch's current unsandboxed user processes.
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/libsandbox"
ROOT="${FINCH_ROOT}/build/root"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"

[[ -f "${SDKROOT}/usr/include/sandbox.h" ]] || {
    echo "sandbox.h is missing from the macOS SDK" >&2
    exit 1
}

CFLAGS="-Wno-deprecated-declarations" "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /usr/lib/libsandbox.1.dylib 1.0.0 1.0.0 - 1.0 \
    "${HERE}/libsandbox.c" --
