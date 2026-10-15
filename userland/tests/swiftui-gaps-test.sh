#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Exercise Finch's SwiftUI additions in a small app on the headless window server.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUNNER="${ROOT}/build/userland/finch-app-test"
SERVER="${ROOT}/build/root/usr/libexec/finch-windowserver"
APP="${ROOT}/build/userland/apps/SwiftUIMore.app/Contents/MacOS/SwiftUIMore"
LIBRARY="${ROOT}/build/root/System/Library"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

run() {
    local stage="$1"
    shift
    FINCH_THEME=Classic SWIFTUI_GAPS_TEST=1 SWIFTUI_GAPS_STAGE="${stage}" \
        DYLD_FRAMEWORK_PATH="${LIBRARY}/Frameworks:${LIBRARY}/PrivateFrameworks" \
        DYLD_LIBRARY_PATH="${ROOT}/build/root/usr/lib/swift" \
        FINCH_FONT_DIRS="${LIBRARY}/Fonts" \
        "${RUNNER}" "${SERVER}" "${APP}" "window:SwiftUI More" wait:300 "$@" \
        > "${TMP}/${stage}.out" 2>&1
}

has() {
    grep -Fq "$2" "${TMP}/$1.out" || {
        cat "${TMP}/$1.out"
        echo "$1: expected output containing '$2'" >&2
        return 1
    }
}

run canvas-fill sample:150,182,canvas
awk '/^canvas:/ { if ($2 >= 200 && $2 > 2 * $3 && $2 > 2 * $4) found = 1 } END { exit !found }' \
    "${TMP}/canvas-fill.out" || {
        cat "${TMP}/canvas-fill.out"
        echo "canvas-fill: sampled pixel was not red" >&2
        exit 1
    }

run stepper click:180,176 click:180,186 output
has stepper "stepper: 1"
has stepper "stepper: 0"
has stepper "editing: true"

run checkbox click:118,182 output
has checkbox "checkbox: true"

run editor click:60,150 type:Finch output
has editor "editor: FinchEdit me"

run scroll scroll:150,166,0,-90 output
has scroll "scroll: false -> true"

run bounce-default scroll:150,166,0,90 wait:250 output
if grep -Fq 'bounce:' "${TMP}/bounce-default.out"; then
    cat "${TMP}/bounce-default.out"
    echo "bounce-default: short content should not bounce automatically" >&2
    exit 1
fi

run bounce-size scroll:150,166,0,90 wait:250 output
if grep -Fq 'bounce:' "${TMP}/bounce-size.out"; then
    cat "${TMP}/bounce-size.out"
    echo "bounce-size: short content should not bounce when based on size" >&2
    exit 1
fi

run bounce-always scroll:150,166,0,90 wait:250 output
has bounce-always "bounce: false -> true"
has bounce-always "bounce: true -> false"

run move click:150,172 output
has move "move: ACB"

run hover move:150,172 move:165,176 move:240,240 output
has hover "hover: active"
has hover "hover: ended"
active_count="$(grep -Fc 'hover: active' "${TMP}/hover.out" || true)"
[[ "${active_count}" -ge 2 ]] || {
    cat "${TMP}/hover.out"
    echo "hover: expected another update as the pointer moved" >&2
    exit 1
}

echo "SwiftUI gaps: Canvas fill, Stepper, TextEditor, scroll geometry and bounce, checkbox style, collection move, and continuous hover passed"
