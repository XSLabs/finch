#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build Apple's Disk Arbitration daemon against Finch's own frameworks.
# The public DiskArbitration client framework is built by userland/DiskArbitration.
set -euo pipefail

FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${SRC:-${FINCH_ROOT}/build/src/DiskArbitration}"
OBJ="${OBJ:-${FINCH_ROOT}/build/obj/DiskArbitration}"
STAGE="${STAGE:-${FINCH_ROOT}/build/root}"
SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
SDK="${FINCH_ROOT}/build/sdk"
DAEMON_OBJ="${OBJ}/daemon"
PRODUCTS="${DAEMON_OBJ}/products"
PUBLIC_OVERLAY="${DAEMON_OBJ}/framework-overlay/System/Library/Frameworks"
PRIVATE_OVERLAY="${DAEMON_OBJ}/framework-overlay/System/Library/PrivateFrameworks"
CONFIG="${DAEMON_OBJ}/finch.xcconfig"

mkdir -p "${DAEMON_OBJ}" "${PRODUCTS}"

# tools/build-oss.sh usually applies these first. Keep the recipe usable on its
# own too, while refusing an edited or mismatched source checkout.
for patch in "${FINCH_ROOT}/userland/patches/DiskArbitration"/*.patch; do
    [[ -f "${patch}" ]] || continue
    if git -C "${SRC}" apply --check "${patch}" 2>/dev/null; then
        git -C "${SRC}" apply "${patch}"
    elif ! git -C "${SRC}" apply --check --reverse "${patch}" 2>/dev/null; then
        echo "error: DiskArbitration patch does not apply: ${patch}" >&2
        exit 1
    fi
done

# Create framework wrappers that use Finch binaries but Apple's public SDK
# headers. This makes the link fail if Finch is missing an API the daemon needs.
rm -rf "${DAEMON_OBJ}/framework-overlay"
for framework in CoreFoundation Foundation IOKit Security SystemConfiguration; do
    finch_framework="${FINCH_ROOT}/build/root/System/Library/Frameworks/${framework}.framework"
    sdk_framework="${SDKROOT}/System/Library/Frameworks/${framework}.framework"
    wrapper="${PUBLIC_OVERLAY}/${framework}.framework"
    [[ -e "${finch_framework}/${framework}" ]] || {
        echo "error: Finch ${framework} framework is missing; build it before DiskArbitration" >&2
        exit 1
    }
    [[ -d "${sdk_framework}/Headers" ]] || {
        echo "error: public ${framework} headers are missing from ${SDKROOT}" >&2
        exit 1
    }
    mkdir -p "${wrapper}"
    ln -s "${finch_framework}/${framework}" "${wrapper}/${framework}"
    ln -s "${sdk_framework}/Headers" "${wrapper}/Headers"
    if [[ -d "${sdk_framework}/Modules" ]]; then
        ln -s "${sdk_framework}/Modules" "${wrapper}/Modules"
    fi
done

# Finch's CoreAnalytics library intentionally drops events. Apple does not ship
# its private header in the public SDK, so give this target the small API shape
# used by DATelemetry.m and link it to Finch's real framework binary.
CORE_ANALYTICS="${FINCH_ROOT}/build/root/System/Library/PrivateFrameworks/CoreAnalytics.framework/CoreAnalytics"
[[ -e "${CORE_ANALYTICS}" ]] || {
    echo "error: Finch CoreAnalytics framework is missing; build it before DiskArbitration" >&2
    exit 1
}
mkdir -p "${DAEMON_OBJ}/include/CoreAnalytics" "${PRIVATE_OVERLAY}/CoreAnalytics.framework"
cat > "${DAEMON_OBJ}/include/CoreAnalytics/CoreAnalytics.h" <<'EOF'
#ifndef FINCH_CORE_ANALYTICS_H
#define FINCH_CORE_ANALYTICS_H

#include <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>

CF_EXPORT void AnalyticsSendEvent(CFStringRef eventName, NSDictionary<NSString *, NSObject *> *payload);
CF_EXPORT void AnalyticsSendEventLazy(CFStringRef eventName,
    NSDictionary<NSString *, NSObject *> * _Nullable (^builder)(void));
CF_EXPORT void AnalyticsSendExplicitEvent(CFStringRef eventName,
    NSDictionary<NSString *, NSObject *> *payload);

#endif
EOF
ln -s "${CORE_ANALYTICS}" "${PRIVATE_OVERLAY}/CoreAnalytics.framework/CoreAnalytics"
ln -s "${DAEMON_OBJ}/include/CoreAnalytics" "${PRIVATE_OVERLAY}/CoreAnalytics.framework/Headers"

# The daemon uses two private headers Apple normally supplies inside its build.
# Keep those additions local to this target.
mkdir -p "${DAEMON_OBJ}/include/SystemConfiguration"
private_sc_header="${FINCH_ROOT}/build/src/configd/SystemConfiguration.fproj/SCDynamicStoreCopySpecificPrivate.h"
[[ -f "${private_sc_header}" ]] || {
    echo "error: SystemConfiguration private header is missing; build configd first" >&2
    exit 1
}
install -m 0644 "${private_sc_header}" \
    "${DAEMON_OBJ}/include/SystemConfiguration/SCDynamicStoreCopySpecificPrivate.h"

cat > "${CONFIG}" <<EOF
// Finch flags for DiskArbitration's daemon target.
FRAMEWORK_SEARCH_PATHS = ${PUBLIC_OVERLAY} ${SDKROOT}/System/Library/Frameworks
SYSTEM_FRAMEWORK_SEARCH_PATHS = ${PRIVATE_OVERLAY} ${SDKROOT}/System/Library/PrivateFrameworks
HEADER_SEARCH_PATHS = \$(inherited) ${FINCH_ROOT}/build/obj/IOKit/hdr ${FINCH_ROOT}/build/src/configd/SystemConfiguration.fproj ${DAEMON_OBJ}/include
LIBRARY_SEARCH_PATHS = \$(inherited) ${FINCH_ROOT}/build/userland/lib
GCC_PREPROCESSOR_DEFINITIONS = \$(inherited) FINCH_NO_FSKIT SANDBOX_CHECK_ALLOW_APPROVAL=0x08000000
OTHER_CFLAGS = \$(inherited) -Wno-error -idirafter ${SDK}/include -idirafter ${SDK}/override -idirafter ${SDK}/availability -I${FINCH_ROOT}/build/obj/IOKit/hdr -I${FINCH_ROOT}/build/src/configd/SystemConfiguration.fproj -I${FINCH_ROOT}/userland/corecrypto/compat -I${DAEMON_OBJ}/include -F${SDK}/Frameworks
OTHER_MIGFLAGS = \$(inherited) -I${SDK}/override -I${SDK}/include
OTHER_LDFLAGS = -Wl,-dead_strip_dylibs -lutil
EXCLUDED_SOURCE_FILE_NAMES = \$(inherited) DAUserFSMount.m
ENABLE_USER_SCRIPT_SANDBOXING = NO
EOF

xcodebuild build -scheme diskarbitrationd \
    -project "${SRC}/DiskArbitration.xcodeproj" \
    -configuration Release -xcconfig "${CONFIG}" -sdk macosx \
    -derivedDataPath "${DAEMON_OBJ}/derived" \
    ARCHS=arm64e ONLY_ACTIVE_ARCH=NO SDKROOT="${SDKROOT}" \
    OBJROOT="${DAEMON_OBJ}/obj" SYMROOT="${DAEMON_OBJ}/sym" \
    SHARED_PRECOMPS_DIR="${DAEMON_OBJ}/precompiled" \
    CONFIGURATION_BUILD_DIR="${PRODUCTS}" \
    CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO GCC_TREAT_WARNINGS_AS_ERRORS=NO \
    > "${DAEMON_OBJ}/xcodebuild.log" 2>&1 || {
        tail -n 100 "${DAEMON_OBJ}/xcodebuild.log" >&2
        exit 1
    }

[[ -x "${PRODUCTS}/diskarbitrationd" ]] || {
    echo "error: DiskArbitration did not build diskarbitrationd" >&2
    exit 1
}

mkdir -p "${STAGE}/usr/libexec" "${STAGE}/System/Library/LaunchDaemons" \
    "${STAGE}/usr/share/man/man8" "${STAGE}/usr/local/OpenSourceLicenses"
install -m 0755 "${PRODUCTS}/diskarbitrationd" "${STAGE}/usr/libexec/diskarbitrationd"
install -m 0644 "${FINCH_ROOT}/userland/LaunchDaemons/com.apple.diskarbitrationd.plist" \
    "${STAGE}/System/Library/LaunchDaemons/com.apple.diskarbitrationd.plist"
install -m 0644 "${SRC}/diskarbitrationd/diskarbitrationd.8" \
    "${STAGE}/usr/share/man/man8/diskarbitrationd.8"
install -m 0444 "${SRC}/APPLE_LICENSE" \
    "${STAGE}/usr/local/OpenSourceLicenses/DiskArbitration.txt"
