#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Calculate.framework (private): Finch's calculation engine to the interface of Apple's, which
# Calculator links. Objective-C (results, units, the currency cache; Calculate.h is its
# clang module) with the Swift half (CalculateExpression: keys, evaluation, display tokens).
#
#   userland/Calculate/build.sh -> build/root/System/Library/PrivateFrameworks/Calculate.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/Calculate"
FINCH_PRIVATE_FRAMEWORK=1 FINCH_FRAMEWORK_INCLUDE="${HERE}/include" FINCH_OBJC_ARC=1 \
"${FINCH_ROOT}/tools/build-swift-framework.sh" Calculate 1 \
    "${HERE}/Calculate.m" "${HERE}/Expression.swift" "${HERE}/Operations.swift" "${HERE}/Node.swift" \
    "${HERE}/State.swift" "${HERE}/Keys.swift" "${HERE}/Evaluate.swift" -- \
    -framework Foundation -framework CoreFoundation -lobjc

# the module, for frameworks built on it (CalculateUI): build/obj/Calculate-module
M="${FINCH_ROOT}/build/obj/Calculate-module/Calculate.framework"
rm -rf "${M}" && mkdir -p "${M}/Headers" "${M}/Modules/Calculate.swiftmodule"
cp "${HERE}/include/Calculate.h" "${M}/Headers/"
printf 'framework module Calculate {\n  umbrella header "Calculate.h"\n  export *\n}\n' > "${M}/Modules/module.modulemap"
cp "${FINCH_ROOT}/build/obj/Calculate/Calculate.swiftinterface" "${M}/Modules/Calculate.swiftmodule/arm64e-apple-macos.swiftinterface"
