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
    if ! FINCH_THEME=Classic SWIFTUI_GAPS_TEST=1 SWIFTUI_GAPS_STAGE="${stage}" \
        DYLD_FRAMEWORK_PATH="${LIBRARY}/Frameworks:${LIBRARY}/PrivateFrameworks" \
        DYLD_LIBRARY_PATH="${ROOT}/build/root/usr/lib/swift" \
        FINCH_FONT_DIRS="${LIBRARY}/Fonts" \
        "${RUNNER}" "${SERVER}" "${APP}" "window:SwiftUI More" wait:300 "$@" \
        > "${TMP}/${stage}.out" 2>&1; then
        cat "${TMP}/${stage}.out"
        echo "${stage}: app runner failed" >&2
        exit 1
    fi
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

run button-toggle click:120,182 output
has button-toggle "button-toggle: false"
has button-toggle "button-toggle: true"

run button-repeat hold:120,182,750 output
awk '/^button-repeat:/ { if ($2 >= 2) found = 1 } END { exit !found }' \
    "${TMP}/button-repeat.out" || {
        cat "${TMP}/button-repeat.out"
        echo "button-repeat: holding the button did not repeat its action" >&2
        exit 1
    }

run date-picker click:125,150 type:12/20/2023 key:36,13 wait:200 output
grep -Fq 'date-picker:' "${TMP}/date-picker.out" || {
    cat "${TMP}/date-picker.out"
    echo "date-picker: expected the picker to report its selected date" >&2
    exit 1
}

run file-importer click:120,182 wait:200 key:53,27 wait:200 output
has file-importer "file-importer: cancelled"

run exit-command key:53,27 output
has exit-command "exit-command: handled"

run table-style sample:31,150,table sample:150,150,table-row output
has table-style "table-style: bordered"
awk '/^table:/ { if ($2 > 0 || $3 > 0 || $4 > 0) found = 1 } END { exit !found }' \
    "${TMP}/table-style.out" || {
        cat "${TMP}/table-style.out"
        echo "table-style: the bordered table did not draw at its sample point" >&2
        exit 1
    }

run table-column-sort output
has table-column-sort "table-column-sort: Alpha,Zebra"

run image-renderer output
has image-renderer "image-renderer: 20x40"

run shape-style-gradients output
has shape-style-gradients "shape-style-gradients: 80x20"

run shape-style-types output
has shape-style-types "shape-style-types: 180x24"

run font-size output
grep -Fq 'font-size:' "${TMP}/font-size.out" || {
    cat "${TMP}/font-size.out"
    echo "font-size: the font modifiers did not render" >&2
    exit 1
}

run gauge output
has gauge "gauge: 100x70"

run control-group-style output
has control-group-style "control-group-style: 100x36"

run text-accessibility output
has text-accessibility "text-accessibility: ready"

run localized-accessibility output
has localized-accessibility "localized-accessibility: ready"

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

echo "SwiftUI gaps: Canvas fill, Stepper, TextEditor, file importer, exit command, date picker, image rendering, button repeat and toggle styles, table and control group styles, Gauge, scroll geometry and bounce, collection move, and continuous hover passed"
