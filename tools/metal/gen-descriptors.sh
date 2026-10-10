#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Regenerates userland/Metal/MTLDescriptors.m from Apple's Metal on this Mac: lists the
# SDK's public Metal classes, probes each (in its own process: a few abort on init),
# and writes the implementations (tools/metal/gen-descriptors.py).
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
H="$(xcrun --show-sdk-path)/System/Library/Frameworks/Metal.framework/Headers"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
cat "${H}"/*.h > "${T}/all.h"
grep -ho "^@interface [A-Za-z0-9_]* *: *[A-Za-z0-9_]*" "${H}"/*.h | sed 's/@interface //; s/ *: */ /' | sort -u > "${T}/classes"
clang -fobjc-arc "${FINCH_ROOT}/tools/metal/probe.m" -framework Metal -framework Foundation -o "${T}/probe"
: > "${T}/probe.txt"
while read -r line; do
    echo "${line}" > "${T}/one"
    "${T}/probe" "${T}/one" >> "${T}/probe.txt" 2>/dev/null || { set -- ${line}; printf 'C\t%s\t%s\tcrash\t0\n' "$1" "$2" >> "${T}/probe.txt"; }
done < "${T}/classes"
python3 "${FINCH_ROOT}/tools/metal/gen-descriptors.py" "${T}/probe.txt" "${T}/all.h" "${FINCH_ROOT}/userland/Metal/MTLDescriptors.m"
echo "wrote userland/Metal/MTLDescriptors.m"
