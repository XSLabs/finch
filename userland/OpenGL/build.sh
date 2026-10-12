#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# OpenGL.framework: Finch's CGL (CGL.c) over Mesa's software OpenGL (mesa.sh, in
# Libraries/libGL.dylib) and Finch's own GLU (GLU.c, Libraries/libGLU.dylib); the OpenGL
# binary re-exports both, as Apple's re-exports its libraries.
#   userland/OpenGL/build.sh -> build/root/System/Library/Frameworks/OpenGL.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/OpenGL"
FW="${FINCH_ROOT}/build/root/System/Library/Frameworks/OpenGL.framework/Versions/A"
[[ -f "${FW}/Libraries/libGL.dylib" ]] || "${HERE}/mesa.sh"
"${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/OpenGL.framework/Versions/A/Libraries/libGLU.dylib 1 1 - - \
    "${HERE}/GLU.c" -- "${FW}/Libraries/libGL.dylib"
# (a library inside the framework has no link at the top)
rm -f "${FW}/../../libGLU.dylib" "${FW}/libGLU.dylib"
exec "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/OpenGL.framework/Versions/A/OpenGL 1 1 com.apple.opengl 1.0 \
    "${HERE}/CGL.c" -- -Wl,-reexport_library,"${FW}/Libraries/libGL.dylib" -Wl,-reexport_library,"${FW}/Libraries/libGLU.dylib" \
    -framework IOSurface
