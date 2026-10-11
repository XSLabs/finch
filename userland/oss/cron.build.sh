#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build Apple's pinned cron-52 with its open IOKit and CoreFoundation calls.
# The Xcode install phase targets macOS paths that do not match Finch, so build
# the targets here and put their outputs into the Finch staging tree ourselves.
set -euo pipefail

FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${SRC:?tools/build-oss.sh must set SRC}"
OBJ="${OBJ:?tools/build-oss.sh must set OBJ}"
STAGE="${STAGE:?tools/build-oss.sh must set STAGE}"
SDKROOT="${SDKROOT:?tools/build-oss.sh must set SDKROOT}"
SDK="${FINCH_ROOT}/build/sdk"
XCODE_OBJ="${OBJ}/xcode"
PRODUCTS="${XCODE_OBJ}/products"
CONFIG="${OBJ}/finch.xcconfig"

mkdir -p "${XCODE_OBJ}" "${PRODUCTS}"
cat > "${CONFIG}" <<EOF
// Finch flags for cron-52.
FINCH_ROOT = ${FINCH_ROOT}
LIBRARY_SEARCH_PATHS = \$(inherited) ${FINCH_ROOT}/build/userland/lib
ENABLE_USER_SCRIPT_SANDBOXING = NO
OTHER_LDFLAGS = \$(inherited) \$(FINCH_PROJECT_LDFLAGS) \$(FINCH_DEAD_STRIP_\$(MACH_O_TYPE))
OTHER_CFLAGS = \$(inherited) -Wno-error -idirafter ${SDK}/include -idirafter ${SDK}/override -idirafter ${SDK}/availability -F${SDK}/Frameworks
EOF

xcodebuild build -scheme All -project "${SRC}/cron.xcodeproj" \
    -configuration Release -xcconfig "${CONFIG}" -sdk macosx \
    -derivedDataPath "${XCODE_OBJ}/derived" \
    ARCHS=arm64e ONLY_ACTIVE_ARCH=NO SDKROOT="${SDKROOT}" \
    OBJROOT="${XCODE_OBJ}/obj" SYMROOT="${XCODE_OBJ}/sym" \
    SHARED_PRECOMPS_DIR="${XCODE_OBJ}/precompiled" \
    CONFIGURATION_BUILD_DIR="${PRODUCTS}" \
    CODE_SIGNING_ALLOWED=NO GCC_TREAT_WARNINGS_AS_ERRORS=NO \
    > "${XCODE_OBJ}/xcodebuild.log" 2>&1 || {
        tail -n 80 "${XCODE_OBJ}/xcodebuild.log" >&2
        exit 1
    }

for product in cron crontab; do
    [[ -x "${PRODUCTS}/${product}" ]] || {
        echo "cron build did not make ${product}" >&2
        exit 1
    }
done

mkdir -p "${STAGE}/usr/sbin" "${STAGE}/usr/bin" \
    "${STAGE}/usr/lib/cron/tabs" "${STAGE}/usr/lib/cron/tmp" \
    "${STAGE}/usr/lib/cron/jobs" "${STAGE}/usr/lib/cron/spool" \
    "${STAGE}/usr/share/man/man1" "${STAGE}/usr/share/man/man5" \
    "${STAGE}/usr/share/man/man8" \
    "${STAGE}/usr/local/OpenSourceVersions" \
    "${STAGE}/usr/local/OpenSourceLicenses"
chmod 0755 "${STAGE}/usr/lib/cron" "${STAGE}/usr/lib/cron/jobs" \
    "${STAGE}/usr/lib/cron/spool"
chmod 0700 "${STAGE}/usr/lib/cron/tabs" \
    "${STAGE}/usr/lib/cron/tmp"
if [[ "${EUID}" -eq 0 ]]; then
    chown daemon:daemon "${STAGE}/usr/lib/cron/jobs" "${STAGE}/usr/lib/cron/spool"
fi
touch "${STAGE}/usr/lib/cron/at.deny"
chmod 0644 "${STAGE}/usr/lib/cron/at.deny"

install -m 0755 "${PRODUCTS}/cron" "${STAGE}/usr/sbin/cron"
install -m 0755 "${PRODUCTS}/crontab" "${STAGE}/usr/bin/crontab"
if [[ "${EUID}" -eq 0 ]]; then
    chown root:wheel "${STAGE}/usr/bin/crontab"
    chmod 04755 "${STAGE}/usr/bin/crontab"
else
    chmod 0755 "${STAGE}/usr/bin/crontab"
    echo "note: crontab is not root-owned in this staging tree; build the release image as root for setuid use" >&2
fi
install -m 0644 "${SRC}/cron.deny" "${STAGE}/usr/lib/cron/cron.deny"
install -m 0644 "${SRC}/cron/cron.8" "${STAGE}/usr/share/man/man8/cron.8"
install -m 0644 "${SRC}/crontab/crontab.1" "${STAGE}/usr/share/man/man1/crontab.1"
install -m 0644 "${SRC}/crontab/crontab.5" "${STAGE}/usr/share/man/man5/crontab.5"
install -m 0444 "${SRC}/cron.plist" "${STAGE}/usr/local/OpenSourceVersions/cron.plist"
install -m 0444 "${SRC}/LICENSE" "${STAGE}/usr/local/OpenSourceLicenses/cron.txt"
