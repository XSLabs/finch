#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Generate userland/AudioToolbox/AudioUnitEffectTables.c: the parameters (names, units,
# ranges, defaults), latency, tail time and factory presets Apple's effect units on
# this Mac have. Only the values are taken, as data; the units' DSP is Finch's.
#   tools/audiotoolbox/gen-effect-tables.sh
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
xcrun clang -o "${TMP}/dump" "${FINCH_ROOT}/tools/audiotoolbox/dump-effects.c" -framework AudioToolbox -framework CoreFoundation
"${TMP}/dump" > "${TMP}/tables.c"
OUT="${FINCH_ROOT}/userland/AudioToolbox/AudioUnitEffectTables.c"
{
    echo "/* SPDX-License-Identifier: MIT OR Apache-2.0 */"
    echo "/* The effect units' parameters, latencies, tails and factory presets, with the values"
    echo "   Apple's have (tools/audiotoolbox/gen-effect-tables.sh). */"
    echo "#include \"AudioUnitEffects.h\""
    echo
    cat "${TMP}/tables.c"
    echo "const struct EffectTable _FinchEffectTables[] = {"
    sed -n 's/^#define \([a-z0-9_]*_TABLE\) .*/    \1,/p' "${TMP}/tables.c"
    echo "};"
    echo "const size_t _FinchEffectTableCount = sizeof _FinchEffectTables / sizeof _FinchEffectTables[0];"
} > "${OUT}"
echo "wrote ${OUT#"${FINCH_ROOT}/"}"
