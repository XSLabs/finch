#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# MetalKit's CPU-side view state is available without a Metal device. Drawables,
# textures, and mesh buffers remain unavailable while Metal has no device.
#   userland/MetalKit/build.sh -> build/root/System/Library/Frameworks/MetalKit.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/MetalKit"
OBJC_ARC=1 CFLAGS="-Wno-incomplete-implementation -Wno-objc-designated-initializers -Wno-nonnull -Wno-deprecated-declarations" \
    "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/MetalKit.framework/Versions/A/MetalKit 173.7 1 com.apple.MetalKit 1.0 \
    "${HERE}/MTKView.m" "${HERE}/MTKTextureLoader.m" "${HERE}/MTKMesh.m" \
    -- -framework AppKit -framework Metal -framework QuartzCore
