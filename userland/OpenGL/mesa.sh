#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Mesa (MIT; docs/LICENSING.md), the OpenGL implementation under Finch's OpenGL.framework:
# its software renderer only (gallium softpipe, through the OSMesa front end), no LLVM, no
# window-system platforms. Pinned to the mesa-25.0.7 tag's commit, the last series with
# OSMesa. Built against the SDK for arm64e; installed as OpenGL.framework's
# Libraries/libGL.dylib, with Mesa's licences. Every source file compiled is checked for a
# GPL licence (the bison parsers' GPL text carries Bison's exception, which is allowed).
#
# Needs meson and ninja, and a Python with mako (MacPorts: meson, ninja, py314-mako);
# PyYAML is fetched at a pinned release.
#
#   userland/OpenGL/mesa.sh   -> build/root/.../OpenGL.framework/Versions/A/Libraries/libGL.dylib
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MESA_COMMIT=742a20f48c59e8649533c84c4d49dd95b403f5da   # mesa-25.0.7
PYYAML_SHA256=d584d9ec91ad65861cc08d42e834324ef890a082e591037abe114850ff7bbc3e  # pyyaml-6.0.2
SRC="${FINCH_ROOT}/build/src/mesa"
OBJ="${FINCH_ROOT}/build/obj/mesa"
TOOLS="${FINCH_ROOT}/build/tools"
ROOT="${FINCH_ROOT}/build/root"
FW="${ROOT}/System/Library/Frameworks/OpenGL.framework/Versions/A"
PYTHON="${MESA_PYTHON:-/opt/local/bin/python3.14}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
log() { echo "==> $*"; }

if [[ "$(git -C "${SRC}" rev-parse HEAD 2>/dev/null)" != "${MESA_COMMIT}" ]]; then
    log "fetching mesa ${MESA_COMMIT:0:12}"
    rm -rf "${SRC}" && mkdir -p "${SRC}"
    git -C "${SRC}" init -q
    git -C "${SRC}" fetch -q --depth 1 https://gitlab.freedesktop.org/mesa/mesa.git "${MESA_COMMIT}"
    git -C "${SRC}" -c advice.detachedHead=false checkout -q FETCH_HEAD
fi
if [[ ! -f "${TOOLS}/pyyaml/lib/yaml/__init__.py" ]]; then
    log "fetching PyYAML 6.0.2"
    mkdir -p "${TOOLS}/pyyaml"
    curl -sSL -o "${TOOLS}/pyyaml.tar.gz" https://files.pythonhosted.org/packages/source/P/PyYAML/pyyaml-6.0.2.tar.gz
    echo "${PYYAML_SHA256}  ${TOOLS}/pyyaml.tar.gz" | shasum -a 256 -c -
    tar -xzf "${TOOLS}/pyyaml.tar.gz" -C "${TOOLS}/pyyaml" --strip-components 1
fi
"${PYTHON}" -c 'import mako' || { echo "mesa: ${PYTHON} has no mako (MacPorts: py314-mako)" >&2; exit 1; }

if [[ ! -f "${OBJ}/build.ninja" ]]; then
    log "configuring mesa"
    mkdir -p "${OBJ%/*}"
    CC="$(xcrun -f clang)" CXX="$(xcrun -f clang++)"
    FLAGS="'-arch', 'arm64e', '-isysroot', '${SDK}', '-mmacosx-version-min=26.0'"
    cat > "${OBJ}.ini" <<INI
[binaries]
c = ['${CC}', ${FLAGS}]
cpp = ['${CXX}', ${FLAGS}]
objc = ['${CC}', ${FLAGS}]
ar = '$(xcrun -f ar)'
strip = '$(xcrun -f strip)'
pkg-config = 'false'
python = '${PYTHON}'
INI
    PYTHONPATH="${TOOLS}/pyyaml/lib" PKG_CONFIG_PATH= meson setup "${OBJ}" "${SRC}" --native-file "${OBJ}.ini" \
        -Dbuildtype=release -Dplatforms= -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dgallium-drivers=softpipe \
        -Dvulkan-drivers= -Dosmesa=true -Dllvm=disabled -Dshared-glapi=enabled -Dgles1=disabled -Dgles2=disabled \
        -Dopengl=true -Dvideo-codecs= -Dzstd=disabled -Dexpat=disabled -Dvalgrind=disabled -Dlibunwind=disabled \
        -Dlmsensors=disabled -Dbuild-tests=false > "${OBJ}.configure.log"
fi
log "building mesa"
PYTHONPATH="${TOOLS}/pyyaml/lib" ninja -C "${OBJ}" > "${OBJ}.build.log"

log "checking licences"
python3 - "${OBJ}" <<'PY'
import json, os, re, sys
obj = sys.argv[1]
bad = []
for e in json.load(open(os.path.join(obj, 'compile_commands.json'))):
    f = e['file'] if os.path.isabs(e['file']) else os.path.normpath(os.path.join(e['directory'], e['file']))
    if '/gtest/' in f:
        continue
    head = open(f, errors='ignore').read(6000)
    spdx = re.search(r'SPDX-License-Identifier:\s*([^\n*]+)', head)
    gpl = (spdx and 'GPL' in spdx.group(1)) or (not spdx and 'GNU General Public' in head)
    if gpl and 'As a special exception' not in head:
        bad.append(f)
if bad:
    print('mesa: GPL-licensed sources were compiled:\n  ' + '\n  '.join(bad), file=sys.stderr)
    sys.exit(1)
PY

log "installing libGL.dylib"
mkdir -p "${FW}/Libraries"
cp "${OBJ}/src/gallium/targets/osmesa/libOSMesa.8.dylib" "${FW}/Libraries/libGL.dylib"
install_name_tool -id /System/Library/Frameworks/OpenGL.framework/Versions/A/Libraries/libGL.dylib "${FW}/Libraries/libGL.dylib" 2> /dev/null
codesign -f -s - "${FW}/Libraries/libGL.dylib" 2> /dev/null
LIC="${ROOT}/usr/share/finch/licenses/mesa"
rm -rf "${LIC}" && mkdir -p "${LIC}"
cp "${SRC}/docs/license.rst" "${LIC}/"
cp -R "${SRC}/licenses/MIT" "${SRC}/licenses/BSL-1.0" "${SRC}/licenses/SGI-B-2.0" "${SRC}/licenses/Apache-2.0" "${LIC}/" 2> /dev/null || true
echo "mesa 25.0.7 (${MESA_COMMIT})" > "${LIC}/VERSION"
log "installed ${FW}/Libraries/libGL.dylib"
