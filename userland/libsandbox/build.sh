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

# The SBPL compiler (sbpl.c, sbpl_regex.c) and the profile evaluator its
# output is checked with, shared with the kernel (kernel/sandbox).
CFLAGS="-Wno-deprecated-declarations -I${HERE} -I${FINCH_ROOT}/kernel/sandbox -I${FINCH_ROOT}/kernel/include" \
    "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /usr/lib/libsandbox.1.dylib 1.0.0 1.0.0 - 1.0 \
    "${HERE}/libsandbox.c" "${HERE}/sbpl.c" "${HERE}/sbpl_regex.c" \
    "${FINCH_ROOT}/kernel/sandbox/fsb_eval.c" -- \
    -Wl,-unexported_symbol,'_sbpl_*' -Wl,-unexported_symbol,'_fsb_*' 
