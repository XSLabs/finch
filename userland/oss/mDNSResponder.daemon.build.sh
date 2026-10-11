#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build Apple's portable POSIX responder for Finch. Apple does not publish the
# macOS daemon source with its system-configuration integrations.
set -euo pipefail

FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${SRC:?tools/build-oss.sh must set SRC}"
OBJ="${OBJ:?tools/build-oss.sh must set OBJ}"
STAGE="${STAGE:?tools/build-oss.sh must set STAGE}"
SDKROOT="${SDKROOT:?tools/build-oss.sh must set SDKROOT}"
DAEMON_OBJ="${OBJ}/mdnsd"
PRODUCTS="${DAEMON_OBJ}/products"

mkdir -p "${PRODUCTS}" "${STAGE}/usr/sbin"

# The POSIX build needs the public macOS headers and Finch's SDK additions. It
# does not need the XNU private-header overlay used by a few other projects.
# launchd tracks the process, so no root-owned PID file needs cleanup after
# the responder drops to the nobody account.
platform_flags=(
    -DHAVE_IPV6
    -D__MAC_OS_X_VERSION_MIN_REQUIRED=__MAC_OS_X_VERSION_10_4
    -DHAVE_STRLCPY=1 -DTARGET_OS_MAC=1 -D__APPLE_USE_RFC_2292
    -DNO_PID_FILE=1
    -Wno-declaration-after-statement -Wno-unused-but-set-variable
)
compiler_flags="-arch arm64e -mmacosx-version-min=26.0 -isysroot ${SDKROOT} -Os -fwrapv ${FINCH_SDK_CFLAGS:-}"
linker_flags="-arch arm64e -mmacosx-version-min=26.0 -isysroot ${SDKROOT}"

make -C "${SRC}/mDNSPosix" os=x Daemon \
    FINCH=1 \
    CC="xcrun -sdk macosx clang" \
    OBJDIR="${DAEMON_OBJ}/objects" BUILDDIR="${PRODUCTS}" \
    CFLAGS="${compiler_flags}" \
    CFLAGS_OS="${platform_flags[*]}" \
    LINKOPTS="${linker_flags}" \
    > "${DAEMON_OBJ}/build.log" 2>&1 || {
        tail -n 80 "${DAEMON_OBJ}/build.log" >&2
        exit 1
    }

[[ -x "${PRODUCTS}/mdnsd" ]] || {
    echo "mDNSResponder POSIX build did not make mdnsd" >&2
    exit 1
}

install -m 0755 "${PRODUCTS}/mdnsd" "${STAGE}/usr/sbin/mdnsd"
