#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# AppleSRP.framework (private), Finch's own: the SRP-6a client with libsrp's API
# (AppleSRP.c), over the corecrypto build's OpenSSL, linked in with its symbols hidden.
#   userland/AppleSRP/build.sh -> build/root/System/Library/PrivateFrameworks/AppleSRP.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/AppleSRP"
OPENSSL="${FINCH_ROOT}/build/obj/corecrypto-openssl"
[[ -f "${OPENSSL}/libcrypto.a" ]] || { echo "build corecrypto first (make -C userland/corecrypto install)" >&2; exit 1; }
CFLAGS="-I${OPENSSL}/include -I${FINCH_ROOT}/build/src/openssl/include -Wno-deprecated-declarations" \
"${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/PrivateFrameworks/AppleSRP.framework/Versions/A/AppleSRP 1 1 com.apple.AppleSRP 1.0 \
    "${HERE}/AppleSRP.c" -- "${OPENSSL}/libcrypto.a" -Wl,-exported_symbols_list,"${HERE}/exports.txt"
