#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# What a framework's public headers declare that Apple's classes answer and Finch's
# don't: missing classes and missing methods, one per line, then a count.
#
#   tools/api-audit.sh Foundation [AppKit ...]      (headers of these frameworks)
#   tools/api-audit.sh --summary Foundation          (counts only)
#
# Run it directly (not through a shell script SIP strips DYLD_* from).
set -uo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUMMARY=0
[[ "${1:-}" == "--summary" ]] && SUMMARY=1 && shift
OUT="${FINCH_ROOT}/build/tools"
mkdir -p "${OUT}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
LINK=()
for fw in "$@"; do LINK+=(-framework "${fw}"); done
xcrun clang -fobjc-arc -o "${OUT}/api-audit-responds" "${FINCH_ROOT}/tools/api-audit/responds.m" -framework Foundation "${LINK[@]}"
python3 "${FINCH_ROOT}/tools/api-audit/headers.py" "$@" > "${TMP}/declared"
"${OUT}/api-audit-responds" < "${TMP}/declared" 2>/dev/null | sort > "${TMP}/apple"
R="${FINCH_ROOT}/build/root/System/Library"
DYLD_FRAMEWORK_PATH="${R}/Frameworks:${R}/PrivateFrameworks:${R}/Frameworks/Quartz.framework/Frameworks:${R}/Frameworks/CoreServices.framework/Versions/A/Frameworks:${R}/Frameworks/ApplicationServices.framework/Versions/A/Frameworks:${R}/Frameworks/Carbon.framework/Versions/A/Frameworks" \
    DYLD_LIBRARY_PATH="${FINCH_ROOT}/build/root/usr/lib/swift" FINCH_THEME=Classic \
    "${OUT}/api-audit-responds" < "${TMP}/declared" 2>/dev/null | sort > "${TMP}/finch"
comm -13 "${TMP}/apple" "${TMP}/finch" > "${TMP}/gaps"
[[ "${SUMMARY}" -eq 0 ]] && cat "${TMP}/gaps"
classes=$(grep "(no class)" "${TMP}/gaps" | awk '{print $1}' | sort -u | wc -l | tr -d ' ')
methods=$(grep -vc "(no class)" "${TMP}/gaps")
echo "$* : ${classes} classes missing, ${methods} methods missing from classes Finch has"
