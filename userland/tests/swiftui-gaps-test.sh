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
# Finch's standalone libraries, alone on the library path, as tools/host-tests.sh has them
# (all of usr/lib/system would swap in Finch's libSystem under the host app)
mkdir -p "${TMP}/lib"
for l in usr/lib/libMobileGestalt usr/lib/libDiagnosticMessagesClient usr/lib/libsandbox.1 \
         usr/lib/system/libfinchaccount usr/lib/system/libsystem_dnssd; do
    ln -s "${ROOT}/build/root/${l}.dylib" "${TMP}/lib/"
done

run() {
    local stage="$1"
    shift
    if ! FINCH_THEME=Classic SWIFTUI_GAPS_TEST=1 SWIFTUI_GAPS_STAGE="${stage}" \
        DYLD_FRAMEWORK_PATH="${LIBRARY}/Frameworks:${LIBRARY}/PrivateFrameworks" \
        DYLD_LIBRARY_PATH="${ROOT}/build/root/usr/lib/swift:${TMP}/lib" \
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

run canvas-stroke sample:150,182,canvas
awk '/^canvas:/ { if ($4 >= 200 && $4 > 2 * $2 && $4 > 2 * $3) found = 1 } END { exit !found }' \
    "${TMP}/canvas-stroke.out" || {
        cat "${TMP}/canvas-stroke.out"
        echo "canvas-stroke: sampled pixel was not blue" >&2
        exit 1
    }

run stepper click:180,176 click:180,186 output
has stepper "stepper: 1"
has stepper "stepper: 0"
has stepper "editing: true"

run task-id click:120,182 wait:250 output
has task-id "task-id: 0"
has task-id "task-id: 1"

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

run any-shape output
has any-shape "any-shape: 80x32"

run shape-operations output
has shape-operations "shape-operations: pass"

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

run secure-field click:120,180 type:Secret output
has secure-field "secure-field: received 6 characters"

run help-link click:150,149 output
has help-link "help-link: activated"

run accessory-bar click:120,182 output
has accessory-bar "accessory-bar: activated"

run toolbar-spacer output
has toolbar-spacer "toolbar-spacer: ready"

run toolbar-spacer-fixed output
has toolbar-spacer-fixed "toolbar-spacer: ready"

run scroll scroll:150,166,0,-90 output
has scroll "scroll: false -> true"

run scroll-position wait:250 output
awk '/^scroll-position:/ { if ($2 >= 120) found = 1 } END { exit !found }' \
    "${TMP}/scroll-position.out" || {
        cat "${TMP}/scroll-position.out"
        echo "scroll-position: binding did not move to the requested target" >&2
        exit 1
    }

run scroll-default-anchor wait:250 scroll:150,166,0,90 wait:200 scroll:150,166,0,-90 wait:250 output
awk '/^scroll-default-anchor:/ { if ($2 >= 200) found = 1 } END { exit !found }' \
    "${TMP}/scroll-default-anchor.out" || {
        cat "${TMP}/scroll-default-anchor.out"
        echo "scroll-default-anchor: the initial bottom anchor was not applied" >&2
        exit 1
    }

run scroll-anchor-role wait:250 scroll:150,166,0,90 wait:200 scroll:150,166,0,-90 wait:250 output
awk '/^scroll-anchor-role:/ { if ($2 >= 200) found = 1 } END { exit !found }' \
    "${TMP}/scroll-anchor-role.out" || {
        cat "${TMP}/scroll-anchor-role.out"
        echo "scroll-anchor-role: the initial-offset role did not override the default" >&2
        exit 1
    }

run scroll-paging scroll:150,166,0,-40 wait:250 output
has scroll-paging "scroll-paging: 60"

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

echo "SwiftUI gaps: Canvas fill and stroke, AnyShape, Stepper, TextEditor, file importer, exit command, date picker, image rendering, button repeat and toggle styles, table and control group styles, Gauge, HelpLink, toolbar spacers, scroll position, default anchor and anchor roles, paging, scroll geometry and bounce, collection move, and continuous hover passed"
