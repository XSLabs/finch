#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# CFNetwork.framework: Finch's. HTTP messages and authentication (Basic, Digest), the
# HTTP read stream (CFHTTPStream.c), socket streams (which CoreFoundation's
# CFStreamCreatePairWithSocketToHost comes to, as on macOS), CFHost, Bonjour
# (CFNetServices.c, over dns_sd), proxies (SystemConfiguration's settings), FTP and
# CFNetDiagnostics. TLS is OpenSSL (corecrypto's build), linked in with its symbols
# hidden, as Foundation's. CFNetworkConstants.c has Apple's constant values.
#   userland/CFNetwork/build.sh -> build/root/System/Library/Frameworks/CFNetwork.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/CFNetwork"
OPENSSL="${FINCH_ROOT}/build/obj/corecrypto-openssl"
FW="${FINCH_ROOT}/build/root/System/Library/Frameworks/CFNetwork.framework"
[[ -f "${OPENSSL}/libssl.a" ]] || { echo "build corecrypto first (make -C userland/corecrypto install)" >&2; exit 1; }
[[ -f "${FINCH_ROOT}/build/root/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration" ]] ||
    { echo "build SystemConfiguration first: userland/SystemConfiguration/build.sh" >&2; exit 1; }
CFLAGS="-I${OPENSSL}/include -I${FINCH_ROOT}/build/src/openssl/include" \
"${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/CFNetwork.framework/Versions/A/CFNetwork 3860.255.112 1 com.apple.CFNetwork 1.0 \
    "${HERE}"/CFNetworkConstants.c "${HERE}"/CFHTTPMessage.c "${HERE}"/CFHTTPAuthentication.c \
    "${HERE}"/CFHTTPStream.c "${HERE}"/CFSocketStream.c "${HERE}"/CFHost.c "${HERE}"/CFNetServices.c \
    "${HERE}"/CFProxySupport.c "${HERE}"/CFFTPStream.c "${HERE}"/CFNetDiagnostics.c \
    -- -framework CoreFoundation -framework SystemConfiguration \
    -L"${OPENSSL}" -Wl,-hidden-lssl -Wl,-hidden-lcrypto -Wl,-no_warn_inits
# Apple's bundle version (its User-Agent's "CFNetwork/..."), apart from the dylib's.
plutil -replace CFBundleVersion -string 3860.500.112 "${FW}/Versions/A/Resources/Info.plist"
NOTICES="${FINCH_ROOT}/build/root/usr/share/finch/licenses/openssl"
mkdir -p "${NOTICES}"
cp "${FINCH_ROOT}/build/src/openssl/LICENSE.txt" "${NOTICES}/"
