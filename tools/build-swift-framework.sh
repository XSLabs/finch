#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build one of Finch's Swift frameworks to Apple's ABI: the sources compiled as the module
# Apple's has, with library evolution as Apple's is, linked into
# build/root/System/Library/Frameworks/NAME.framework (Versions/A) against Finch's frameworks.
#
#   tools/build-swift-framework.sh NAME CURRENT-VERSION source.swift|source.m... [-- link flags]
#   (FINCH_PRIVATE_FRAMEWORK=1 builds it into PrivateFrameworks, as Apple's private ones are;
#   FINCH_FRAMEWORK_INCLUDE=DIR finds the framework's clang module there, for a framework the
#   SDK has no headers for; FINCH_OBJC_ARC=1 compiles the Objective-C with ARC;
#   FINCH_SWIFT_FLAGS adds swiftc flags, such as -F for a Finch framework's module;
#   FINCH_OBJ_DIR and FINCH_OUTPUT_ROOT keep a trial build separate from build/root)
#
# Objective-C sources (.m, manual retain/release) are compiled into the same framework, and
# the Swift imports the framework's clang module (the SDK's headers) as its underlying
# module, as a mixed framework's overlay does.
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="$1" VERSION="$2"; shift 2
sources=() objc=()
while [[ $# -gt 0 && "$1" != "--" ]]; do
    case "$1" in *.m) objc+=("$1") ;; *) sources+=("$1") ;; esac
    shift
done
[[ $# -gt 0 ]] && shift

source_dirs=()
for source in "${sources[@]}" ${objc[@]+"${objc[@]}"}; do
    [[ -n "${source}" ]] && source_dirs+=("$(dirname "${source}")")
done
for source_dir in "${source_dirs[@]}"; do
    generated="${source_dir}/${NAME}Constants_Generated.m"
    if [[ -f "${generated}" ]]; then
        already_added=0
        for source in ${objc[@]+"${objc[@]}"}; do [[ "${source}" == "${generated}" ]] && already_added=1; done
        [[ "${already_added}" -eq 1 ]] || objc+=("${generated}")
        break
    fi
done
OBJ="${FINCH_OBJ_DIR:-${FINCH_ROOT}/build/obj/${NAME}}"
ROOT="${FINCH_OUTPUT_ROOT:-${FINCH_ROOT}/build/root}"
DIR=Frameworks
[[ "${FINCH_PRIVATE_FRAMEWORK:-}" == 1 ]] && DIR=PrivateFrameworks
FW="${ROOT}/System/Library/${DIR}/${NAME}.framework"
INSTALL_NAME="${FINCH_INSTALL_NAME:-/System/Library/${DIR}/${NAME}.framework/Versions/A/${NAME}}"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
log() { echo "==> $*"; }

log "compiling ${NAME}"
rm -rf "${OBJ}" && mkdir -p "${OBJ}"
objects=("${OBJ}/${NAME}-swift.o")
underlying=()
includes=() swift_includes=() arc=-fno-objc-arc
if [[ -n "${FINCH_FRAMEWORK_INCLUDE:-}" ]]; then
    includes=(-I "${FINCH_FRAMEWORK_INCLUDE}")
    swift_includes=(-I "${FINCH_FRAMEWORK_INCLUDE}" -Xcc -I"${FINCH_FRAMEWORK_INCLUDE}")
fi
[[ "${FINCH_OBJC_ARC:-}" == 1 ]] && arc=-fobjc-arc
for m in ${objc[@]+"${objc[@]}"}; do
    o="${OBJ}/$(basename "${m%.m}").o"
    xcrun clang -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -Os -g "${arc}" -fobjc-exceptions ${includes[@]+"${includes[@]}"} \
        -fblocks -Wall -Wextra -Werror -Wno-unused-parameter ${FINCH_OBJC_FLAGS:-} -Wno-objc-designated-initializers \
        -Wno-objc-property-implementation -c "${m}" -o "${o}"
    objects+=("${o}")
    underlying=(-import-underlying-module)
done
"$(xcrun -f swiftc)" -c -wmo -module-name "${NAME}" -parse-as-library -enable-library-evolution \
    -target arm64e-apple-macos26.0 -sdk "${SDKROOT}" -swift-version 5 -O ${underlying[@]+"${underlying[@]}"} ${swift_includes[@]+"${swift_includes[@]}"} ${FINCH_SWIFT_FLAGS:-} \
    "${sources[@]}" -o "${OBJ}/${NAME}-swift.o" -emit-module-interface-path "${OBJ}/${NAME}.swiftinterface"

# libswiftCore first: the standard library's symbols bind to it, not to a Finch framework
# that also exports some (CoreGraphics and CoreText do)
log "linking"
mkdir -p "${FW}/Versions/A"
xcrun clang -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib \
    -install_name "${INSTALL_NAME}" \
    -current_version "${VERSION}" -compatibility_version 1 \
    "${objects[@]}" -o "${FW}/Versions/A/${NAME}" -L"${SDKROOT}/usr/lib/swift" -lswiftCore \
    -F"${ROOT}/System/Library/Frameworks" -F"${ROOT}/System/Library/PrivateFrameworks" \
    -F"${FINCH_ROOT}/build/root/System/Library/Frameworks" \
    -F"${FINCH_ROOT}/build/root/System/Library/PrivateFrameworks" "$@"
ln -sfn A "${FW}/Versions/Current"
ln -sfn "Versions/Current/${NAME}" "${FW}/${NAME}"
"${FINCH_ROOT}/tools/mkframeworkplist.sh" "${FW}" A "${NAME}" "com.apple.${NAME}" "${NAME}" 1.0 "${VERSION}" English
codesign -f -s - -i "com.apple.${NAME}" "${FW}/Versions/A/${NAME}" 2>/dev/null
log "installed ${FW#"${FINCH_ROOT}/"}"
