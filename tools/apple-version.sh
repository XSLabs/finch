#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# The versions of Apple's framework on this Mac, for a Finch replacement to carry:
#   tools/apple-version.sh <Framework>  ->  current compatibility short-version bundle-version
set -euo pipefail
fw="$1"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
cat > "${tmp}/v.c" <<'C'
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <string.h>
int main(int c, char **v) {
    if (!dlopen(v[1], RTLD_NOW)) return 1;
    int32_t r = NSVersionOfRunTimeLibrary(v[2]);
    if (r == -1) return 1;
    printf("%d.%d.%d\n", r >> 16, (r >> 8) & 255, r & 255);
    return 0;
}
C
clang -w "${tmp}/v.c" -o "${tmp}/v"
cur="$("${tmp}/v" "/System/Library/Frameworks/${fw}.framework/${fw}" "${fw}" 2>/dev/null || echo 1)"
sdk="$(xcrun --show-sdk-path)"
compat="$(grep -m1 'compatibility-version' "${sdk}/System/Library/Frameworks/${fw}.framework/${fw}.tbd" 2>/dev/null | awk '{print $2}' || true)"
plist="/System/Library/Frameworks/${fw}.framework/Resources/Info.plist"
short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${plist}" 2>/dev/null || echo 1.0)"
bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${plist}" 2>/dev/null || echo "${cur}")"
echo "${cur} ${compat:-1} ${short} ${bundle}"
