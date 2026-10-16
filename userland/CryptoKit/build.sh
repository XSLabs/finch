#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# CryptoKit.framework from the pinned swift-crypto source, with its BoringSSL and
# XKCP implementations linked inside the framework under Apple's Swift module name.
#   userland/CryptoKit/build.sh -> build/root/System/Library/Frameworks/CryptoKit.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/CryptoKit"
SRC="${FINCH_ROOT}/build/src/swift-crypto"
TAG=5.0.1
OBJ="${FINCH_ROOT}/build/obj/CryptoKit"
PKG="${OBJ}/package"
SCRATCH="${OBJ}/build"
ROOT="${FINCH_ROOT}/build/root"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
TARGET=arm64e-apple-macosx26.0
VERSION=324.100.35
log() { echo "==> $*"; }

if [[ "$(git -C "${SRC}" describe --tags --exact-match 2>/dev/null || true)" != "${TAG}" ]]; then
    echo "missing build/src/swift-crypto ${TAG}; run tools/fetch-src.sh swift-crypto" >&2
    exit 1
fi

log "staging swift-crypto ${TAG}"
mkdir -p "${PKG}/Sources"
for project in CCryptoBoringSSL CXKCP CXKCPShims CryptoBoringWrapper Crypto; do
    rsync -a --delete "${SRC}/Sources/${project}/" "${PKG}/Sources/${project}/"
done
cp "${HERE}/Package.swift" "${PKG}/Package.swift"
python3 "${HERE}/adapt.py" "${PKG}/Sources/Crypto"

log "building CryptoKit and its private crypto backends"
rm -rf "${SCRATCH}"
if ! swift build --package-path "${PKG}" -c release --triple "${TARGET}" \
    --scratch-path "${SCRATCH}" --target CryptoKit > "${OBJ}/build.log" 2>&1; then
    tail -n 80 "${OBJ}/build.log" >&2
    exit 1
fi
BUILD="${SCRATCH}/arm64e-apple-macosx/release"

# SwiftPM compiles each helper target separately. Link its objects into one
# framework image so BoringSSL and XKCP never become public Finch libraries.
objects=()
crypto_objects=()
for module in CryptoKit CryptoBoringWrapper CCryptoBoringSSL CXKCP CXKCPShims; do
    dir="${BUILD}/${module}.build"
    [[ -d "${dir}" ]] || { echo "missing SwiftPM objects for ${module}" >&2; exit 1; }
    while IFS= read -r object; do
        objects+=("${object}")
        [[ "${module}" != CryptoKit ]] || crypto_objects+=("${object}")
    done < <(python3 - "${dir}" <<'PY'
import json, os, sys
d = sys.argv[1]
current = set()
mapping = os.path.join(d, "output-file-map.json")
if os.path.exists(mapping):
    for outputs in json.load(open(mapping)).values():
        obj = outputs.get("object")
        if obj:
            current.add(os.path.normpath(obj))
for root, _, files in os.walk(d):
    for name in files:
        path = os.path.join(root, name)
        if name.endswith(".o") and (not name.endswith(".swift.o") or os.path.normpath(path) in current):
            print(path)
PY
    )
done

mkdir -p "${OBJ}"
xcrun nm -gU "${crypto_objects[@]}" | awk '{print $NF}' | \
    grep -E '^(_\$s|_symbolic)' | sort -u > "${OBJ}/exports.txt"
[[ -s "${OBJ}/exports.txt" ]] || { echo "no CryptoKit Swift exports found" >&2; exit 1; }

FW="${ROOT}/System/Library/Frameworks/CryptoKit.framework"
mkdir -p "${FW}/Versions/A/Modules"
log "linking the CryptoKit framework"
xcrun clang++ -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib \
    -install_name /System/Library/Frameworks/CryptoKit.framework/Versions/A/CryptoKit \
    -current_version "${VERSION}" -compatibility_version 1 \
    "${objects[@]}" -L"${SDKROOT}/usr/lib/swift" \
    -F"${ROOT}/System/Library/Frameworks" -framework Foundation \
    -Wl,-dead_strip_dylibs -Wl,-exported_symbols_list,"${OBJ}/exports.txt" \
    -o "${FW}/Versions/A/CryptoKit"

MODULE="${BUILD}/Modules"
[[ -f "${MODULE}/CryptoKit.swiftinterface" ]] || {
    echo "SwiftPM did not emit CryptoKit's arm64e interface" >&2; exit 1;
}
MODULES="${FW}/Versions/A/Modules/CryptoKit.swiftmodule"
mkdir -p "${MODULES}"
for suffix in abi.json package.swiftinterface private.swiftinterface swiftinterface swiftdoc swiftmodule swiftsourceinfo; do
    source="${MODULE}/CryptoKit.${suffix}"
    [[ -f "${source}" ]] && cp "${source}" "${MODULES}/arm64e-apple-macos.${suffix}"
done
ln -sfn A "${FW}/Versions/Current"
ln -sfn Versions/Current/CryptoKit "${FW}/CryptoKit"
ln -sfn Versions/Current/Modules "${FW}/Modules"
"${FINCH_ROOT}/tools/mkframeworkplist.sh" "${FW}" A CryptoKit \
    com.apple.CryptoKit CryptoKit 1.0 "${VERSION}" English
codesign -f -s - -i com.apple.CryptoKit "${FW}/Versions/A/CryptoKit" 2>/dev/null

# Keep the project notices and the notices on the exact vendored files used here.
LICENSES="${ROOT}/usr/share/finch/licenses/swift-crypto"
mkdir -p "${LICENSES}"
install -m 644 "${SRC}/LICENSE.txt" "${LICENSES}/LICENSE.txt"
install -m 644 "${SRC}/NOTICE.txt" "${LICENSES}/NOTICE.txt"
install -m 644 "${SRC}/Sources/CCryptoBoringSSL/hash.txt" "${LICENSES}/BoringSSL-source.txt"
install -m 644 "${SRC}/Sources/CXKCP/vendored-sources.txt" "${LICENSES}/XKCP-sources.txt"
notice_sources=()
while IFS= read -r source; do notice_sources+=("${source}"); done < <(
    find "${PKG}/Sources/Crypto" "${PKG}/Sources/CryptoBoringWrapper" \
        "${PKG}/Sources/CCryptoBoringSSL" "${PKG}/Sources/CXKCP" "${PKG}/Sources/CXKCPShims" \
        -type f \( -name '*.swift' -o -name '*.c' -o -name '*.cc' -o -name '*.cpp' \) -print
)
python3 -I "${FINCH_ROOT}/tools/collect-notices.py" \
    "swift-crypto ${TAG}, BoringSSL and XKCP, in CryptoKit.framework" \
    "${LICENSES}/BUILT-SOURCE-NOTICES.txt" "${notice_sources[@]}"
log "installed ${FW#"${FINCH_ROOT}/"}"
