#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Metal.framework: Finch's. No GPU is driven yet, so there are no devices (as on a Mac
# without one); descriptors are values with Apple's defaults (MTLDescriptors.m,
# generated); MTLConstants.m has Apple's values.
#   userland/Metal/build.sh -> build/root/System/Library/Frameworks/Metal.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/Metal"
OBJC_ARC=1 CFLAGS="-Wno-incomplete-implementation -Wno-objc-designated-initializers -Wno-deprecated-declarations -Wno-deprecated-implementations -Wno-objc-property-synthesis -Wno-unguarded-availability-new -Wno-objc-protocol-method-implementation" \
    "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/Metal.framework/Versions/A/Metal 372.16.0 1 com.apple.Metal 372.16 \
    "${HERE}/MTLConstants.m" "${HERE}/MTLRuntime.m" "${HERE}/MTLDescriptors.m" "${HERE}/MTLMethods.m" -- -framework Foundation
