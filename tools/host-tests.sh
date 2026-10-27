#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Run the host test suite: each comparison test against Apple's frameworks and
# against Finch's (build/root, through DYLD_FRAMEWORK_PATH), comparing all but
# the first line (which names the image used), and each Finch-only window-server
# test against its .expected file. Prints one line per test and a summary;
# exits non-zero if any differ. Machine-dependent output fields are masked in both
# outputs (tools/test-masks.txt); known failures, each with its reason, are listed in
# tools/host-test-exceptions.txt (one that passes again fails the run).
#
#   tools/host-tests.sh [NAME...]     (NAME as in finch-NAME; default: all)
#   FINCH_TRIAL=dir  puts dir first in DYLD_FRAMEWORK_PATH (a trial AppKit, say)
#
# Build the tests first (make -C userland/tests). Run this script directly:
# perl, python and /bin/sh would lose DYLD_* to SIP.
set -uo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${FINCH_ROOT}"
# Finch draws in Classic, AppKit's Aqua-compatible theme, to compare with Apple's (docs/design/FIELDWORK.md).
export FINCH_THEME=Classic
B=build/userland
R=build/root/System/Library
IOS_R=build/root/System/iOSSupport/System/Library
# The private keychain tests verify the exact loaded Security image before any call.
export FINCH_TEST_SECURITY_IMAGE="${FINCH_TRIAL:-${R}/Frameworks}/Security.framework/Security"
# (frameworks nested in umbrellas are found by their own name, so their folders are listed too)
FW="${FINCH_TRIAL:+${FINCH_TRIAL}:}${R}/Frameworks:${IOS_R}/Frameworks:${R}/PrivateFrameworks:${R}/Frameworks/Quartz.framework/Frameworks"
FW="${FW}:${R}/Frameworks/CoreServices.framework/Versions/A/Frameworks:${R}/Frameworks/ApplicationServices.framework/Versions/A/Frameworks"
FW="${FW}:${R}/Frameworks/Carbon.framework/Versions/A/Frameworks"
FW="${FW}:${R}/Frameworks/OpenDirectory.framework/Versions/A/Frameworks"
SERVER=build/root/usr/libexec/finch-windowserver
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
# Finch's standalone libraries, alone on the library path (all of build/root/usr/lib would
# swap in its libSystem as well)
mkdir -p "${TMP}/lib"
for l in libMobileGestalt libDiagnosticMessagesClient; do ln -s "${FINCH_ROOT}/build/root/usr/lib/${l}.dylib" "${TMP}/lib/"; done
ln -s "${FINCH_ROOT}/build/root/usr/lib/system/libfinchaccount.dylib" "${TMP}/lib/"
ln -s "${FINCH_ROOT}/build/root/usr/lib/system/libsystem_dnssd.dylib" "${TMP}/lib/"
ln -s "${FINCH_ROOT}/build/root/usr/lib/libsandbox.1.dylib" "${TMP}/lib/"
LIBS="build/root/usr/lib/swift:${TMP}/lib:${R}/Frameworks/OpenGL.framework/Versions/A/Libraries"

# name|arguments: comparison tests (arguments are relative to the repo root)
COMPARE=(
    "appkit-misc2-test|" "forward-test|" "runtime-test|"
    "iokit-test|" "pdfkit-test|" "avkit-test|" "intents-test|" "gamecontroller-test|" "vision-test|" "cloudkit-test|"
    "avcapture-test|" "coreaudio-hal-test|" "avcomposition-test|" "avaudiomix-test|" "avmetadata-group-test|" "avaudiomix-output-test|" "avvideocomposition-test|" "avmedia-selection-test|" "avwriter-media-test|" "avmovie-test|" "avrender-sync-test|" "avasset-compat-test|" "avvariant-test|" "avmusic-event-test|" "avaudio-recorder-test|" "avaudio-sequencer-test|" "avaudio-midi-player-test|" "avcaption-test|" "avcaption-group-test|" "avcaption-conformer-test|" "avcaption-validator-test|" "avcaption-renderer-test|" "avsample-cursor-test|" "avsample-buffer-generator-test|" "avsample-buffer-layer-test|" "avsample-reference-test|" "avvideo-composition-reader-test|" "avtext-style-test|" "avdownload-values-test|" "avtimeformatter-test|" "avmedia-data-collector-test|" "avcontent-auth-test|" "avaudio-renderer-test|"
    "media-player-test|" "media-accessibility-test|" "corebluetooth-test|" "libsandbox-test|" "cryptotokenkit-test|" "widgetkit-test|"
    "constants-test|" "calculate-test|" "swiftdata-test|" "tipkit-test|" "avaudio-file-test|" "avaudio-compressed-buffer-test|" "avaudio-converter-test|" "avaudio-engine-test|" "avaudio-player-test|" "avaudio-unit-test|" "audiounit-effects-test|" "itemprovider-test|" "formatters2-test|" "urlcache-test|" "appkit-small3-test|" "compositional-test|" "filepromise-test|" "appkit-swift2-test|" "private-calls-test|" "mobilegestalt-test|" "utilities-test|" "foundation-audit-test|" "tree-test|" "outline-bindings-test|" "typeselect-test|" "screencapturekit-test|" "appkit-compat-test|" "pdf-image-rep-test|" "sounddesc-test|" "avasset-test|" "avexport-test|" "avfoundation-overlay-test|" "avreader-test|" "avwriter-test|" "avimage-test|" "avplayer-test|" "opengl-test|" "appkit-typedstream-test|" "system-images-test|" "quartzfilters-test|" "printcore-test|" "symbols-test|" "xml-test|" "document-more-test|" "textview-more-test|" "windowing-more-test|" "contacts-search-links-test|" "contacts-search-links-swift-test|"
    "cf-test|" "foundation-test|" "foundation-gaps-test|" "intl-test|" "misc-test|" "data-test|" "collections-test|" "kvc-test|" "typedstream-test|" "tiff-test|" "colorsync-test|" "colorsync-devices-test|" "iconservices-test|" "smallprivate-test|" "quicklook-test|" "exports-test|" "cookies-test|" "foundation-more-test|" "appkit-values-test|" "hiservices-test|" "scripting-test|" "cfnetwork-test|" "coreimage-test|" "cgevent-test|" "keylayout-test|" "contacts-test|" "accounts-test|" "opendirectory-objects-test|" "metal-test|" "metalkit-test|" "audiounit-framework-test|" "coremidi-test|" "iosurface-test|" "gss-test|" "cfurl-test|" "pasteboard-test|" "coremedia-test|" "corevideo-test|" "audiotoolbox-test|" "audioconverter-test|" "extaudiofile-test|" "extaudiofile-test|--src-check" "applescript-test|" "fileversion-test|" "textformats-test|" "worddoc-test|" "network-test|" "coredata-test|" "coredata-stores-test|" "coredata-classes-test|" "coredata-migration-test|" "coredata-hash-test|" "coredata-xml-test|" "cfxml-test|" "cf-bundle-arch-test|" "cf-preferences-container-test|" "videotoolbox-test|" "appintents-test|" "appintents-local-test|" "appintents-swiftui-test|"
    "cf-classes-test|" "distnotify-test|" "file-replace-test|" "new-classes-test|" "websocket-test|" "do-test|" "foundation-edges-test|" "appkit-edges-test|" "appkit-classes-test|" "archive-test|" "predicate-test|" "measurement-test|" "bridge-test|" "streams-test|" "documents-test|"
    "files-test|" "xmlparser-test|" "cfnotify-test|" "l10n-test|" "uti-test|" "cg-test|" "cg-overlay-test|" "cg-private-test|" "cg-region-test|" "foundation-overlay-test|" \
    "cg-draw-test|userland/tests/cg-draw-reference.bin" "cgpdf-test|" "imageio-test|"
    "ct-test|" "quartzcore-test|" "calayer-test|" "uifoundation-test|userland/tests/uifoundation-reference.bin" "appkit-core-test|" "appkit-gaps-test|" "appkit-draw-test|userland/tests/appkit-draw-reference.bin" "accelerate-test|"
    "appkit-containers-test|" "appkit-controls-test|${B}/controls-test.nib" "appkit-menu-test|${B}/menu-test.nib"
    "appkit-text-test|${B}/appkit-text-test.nib" "appkit-document-test|${B}" "nib-test|${B}/nib-test.nib"
    "appkit-layout-test|${B}" "appkit-bindings-test|${B}/appkit-bindings-test.nib" "appkit-panels-test|"
    "textkit2-test|" "appkit-tables-test|" "appkit-containers2-test|" "appkit-controls2-test|" "imagekit-test|"
    "coreservices-test|build/coreservices-test" "coreservices-additions-test|" "coreservices-locales-test|--locales" "coreservices-threads-test|--threads" "coreservices-time-manager-test|--time-manager" "coreservices-mp-timers-test|--mp-timers" "coreservices-identity-test|--identity" "coreservices-option-keys-test|--only-option-keys" "security-test|build/userland/apps/SecurityResourceTest.app" "sysconfig-test|" "markdown-test|" "rtf-test|" "filecoordinator-test|" "textfinder-test|" "ruler-test|" "textblock-test|" "combine-test|" "cryptokit-test|" "cftokenizer-test|" "urlsession-trust-test|" "urlsession-test|" "swift-overlay-test|" "swift-runtime-test|" "auth-frameworks-test|"
)
# Finch-only window-server tests and their expected output
EXPECT=(window controls-window menu-window text-window panels-window tables-window statusbar drag-window screencapture avplayer opengl)
FINCH_ONLY=("ws-test|${SERVER}" "cloudkit-unavailable-test|" "contacts-search-links-fetch-test|--fetch-local" "quartzcore-renderer-test|" "security-core-test|" "security-keychain-encryption-test|" "keychain-crypto-test|" "security-keychain-storage-test|" "security-trust-settings-test|" "security-roots-test|userland/tests/security-https-chain.pem" "audiounit-test|" "audioqueue-test|" "avaudio-buffer-test|" "avaudio-services-test|" "configd-daemon-test|" "console-policy-test|" "corebluetooth-unsupported-test|" "cryptotokenkit-empty-test|")

want() {
    [[ $# -eq 0 || -z "${SELECTED}" ]] && return 0
    [[ " ${SELECTED} " == *" $1 "* ]]
}
SELECTED="$*"
for selected in "$@"; do
    known=0
    for entry in "${COMPARE[@]}" "${FINCH_ONLY[@]}"; do
        [[ "${entry%%|*}" == "${selected}" ]] && known=1
    done
    for name in "${EXPECT[@]}"; do
        [[ "appkit-${name}-test" == "${selected}" ]] && known=1
    done
    case "${selected}" in contacts-store-test|metal-devices-test|hello-test) known=1 ;; esac
    if [[ "${known}" -eq 0 ]]; then
        echo "unknown test: ${selected}" >&2
        exit 1
    fi
done
# Known failures (tools/host-test-exceptions.txt): "test: reason", or "test (1x display):
# reason" for one that fails when this Mac's main display isn't Retina (Apple's AppKit then
# rounds frames to whole points; with a Retina display attached too, its window may land on
# either, so such a test may pass). One that passes fails the run until it's removed, but
# for a display exception.
MAIN_1X=0
system_profiler SPDisplaysDataType 2>/dev/null | awk '/Resolution:/ { r = $0 } /Main Display: Yes/ { print r }' |
    grep -q Retina || MAIN_1X=1
# A nib can restore its window onto an attached 1x display even when the main display is
# Retina. Finch has no display list, so that window's saved screen position cannot match.
ATTACHED_1X=0
if system_profiler SPDisplaysDataType 2>/dev/null | awk '
    /Resolution:/ {
        split($0, size, /[^0-9]+/)
        width = size[2]
        height = size[3]
        matches = 0
    }
    /UI Looks like:/ {
        split($0, size, /[^0-9]+/)
        if (width == size[2] && height == size[3]) matches = 1
    }
    /Online: Yes/ {
        if (matches) found = 1
        matches = 0
    }
    END { exit !found }
'; then
    ATTACHED_1X=1
fi
exception() {
    local line name rest
    while IFS= read -r line; do
        [[ -z "${line}" || "${line}" == \#* ]] && continue
        name="${line%%:*}"
        rest="${line#*:}"
        if [[ "${name}" == "$1 (1x display)" ]]; then
            if [[ "${MAIN_1X}" -eq 1 || "${ATTACHED_1X}" -eq 1 ]]; then
                echo "display:${rest# }"
                return 0
            fi
        fi
        if [[ "${name}" == "$1" ]]; then
            echo "${rest# }"
            return 0
        fi
    done < tools/host-test-exceptions.txt
    return 1
}
# Machine-dependent output fields (tools/test-masks.txt), masked in both outputs
masked() {
    local expr=()
    while read -r test sub; do
        [[ "${test}" == "$1" ]] && expr+=(-e "${sub}")
    done < <(grep -v '^#' tools/test-masks.txt)
    if [[ ${#expr[@]} -gt 0 ]]; then sed -E "${expr[@]}" "$2"; else cat "$2"; fi
}
pass=0
fail=0
skip=0
known=0
excused=""  # set by report: what the last failure is known for
if want vision-test; then rm -f build/compat-results/Vision.json; fi
report() {
    local why
    excused=""
    if why=$(exception "$1"); then
        case "$2" in
        ok*)
            if [[ "${why}" == display:* ]]; then
                printf '%-34s %s\n' "$1" "$2"
                return
            fi
            printf '%-34s %s\n' "$1" "passes now: remove its exception"
            excused="pass"
            ;;
        *)
            printf '%-34s %s\n' "$1" "known: $2 (${why#display:})"
            excused="fail"
            ;;
        esac
        return
    fi
    printf '%-34s %s\n' "$1" "$2"
}
count_fail() {
    if [[ "${excused}" == "fail" ]]; then known=$((known + 1)); else fail=$((fail + 1)); fi
}
count_pass() {
    if [[ "${excused}" == "pass" ]]; then fail=$((fail + 1)); else pass=$((pass + 1)); fi
}

for entry in "${COMPARE[@]}"; do
    name="${entry%%|*}"
    args="${entry#*|}"
    want "${name}" || continue
    bin="${B}/finch-${name}"
    if [[ ! -x "${bin}" ]]; then
        report "${name}" "not built"
        skip=$((skip + 1))
        continue
    fi
    if [[ "${name}" == coredata-test || "${name}" == coredata-xml-test ]]; then
        apple_store="${TMP}/${name}-apple.store"
        finch_store="${TMP}/${name}-finch.store"
        model="${B}/CoreDataTest.momd"
        "${bin}" write "${apple_store}" "${model}" > "${TMP}/apple" 2> "${TMP}/apple.err"
        apple_status=$?
        DYLD_FRAMEWORK_PATH="${FW}" DYLD_LIBRARY_PATH="${LIBS}" "${bin}" read "${apple_store}" "${model}" > "${TMP}/finch" 2> "${TMP}/finch.err"
        finch_status=$?
        if [[ "${apple_status}" -eq 0 && "${finch_status}" -eq 0 ]]; then
            DYLD_FRAMEWORK_PATH="${FW}" DYLD_LIBRARY_PATH="${LIBS}" "${bin}" write "${finch_store}" "${model}" > /dev/null 2> "${TMP}/finch-write.err"
            finch_write_status=$?
            if [[ "${finch_write_status}" -eq 0 ]]; then
                "${bin}" read "${finch_store}" "${model}" > "${TMP}/apple-read" 2> "${TMP}/apple-read.err"
                apple_read_status=$?
                if [[ "${apple_read_status}" -eq 0 ]] && ! diff <(tail -n +2 "${TMP}/finch") <(tail -n +2 "${TMP}/apple-read") > "${TMP}/cross-store.diff"; then
                    apple_read_status=1
                fi
            else
                apple_read_status=1
            fi
            if [[ "${finch_write_status}" -ne 0 || "${apple_read_status}" -ne 0 ]]; then
                printf 'cross-store check failed (Finch write %s, Apple read %s)\n' "${finch_write_status}" "${apple_read_status}" > "${TMP}/finch.err"
                cat "${TMP}/finch-write.err" "${TMP}/apple-read.err" >> "${TMP}/finch.err"
                if [[ -s "${TMP}/cross-store.diff" ]]; then cat "${TMP}/cross-store.diff" >> "${TMP}/finch.err"; fi
                finch_status=1
            fi
        fi
    else
        # shellcheck disable=SC2086
        if [[ "${name}" == cf-preferences-container-test ]]; then
            CFFIXED_USER_HOME="${FINCH_ROOT}/build/cf-pref-test-home" "${bin}" ${args} > "${TMP}/apple" 2> "${TMP}/apple.err"
            apple_status=$?
            CFFIXED_USER_HOME="${FINCH_ROOT}/build/cf-pref-test-home" DYLD_FRAMEWORK_PATH="${FW}" DYLD_LIBRARY_PATH="${LIBS}" \
                FINCH_FILTER_DIRS="build/root/System/Library/Filters" FINCH_FONT_DIRS="${R}/Fonts" "${bin}" ${args} > "${TMP}/finch" 2> "${TMP}/finch.err"
            finch_status=$?
        else
            "${bin}" ${args} > "${TMP}/apple" 2> "${TMP}/apple.err"
            apple_status=$?
            DYLD_FRAMEWORK_PATH="${FW}" DYLD_LIBRARY_PATH="${LIBS}" FINCH_FILTER_DIRS="build/root/System/Library/Filters" FINCH_FONT_DIRS="${R}/Fonts" "${bin}" ${args} > "${TMP}/finch" 2> "${TMP}/finch.err"
            finch_status=$?
        fi
    fi
    if [[ "${name}" == constants-test ]]; then
        python3 tools/constants/record-results.py "${TMP}/apple" "${TMP}/finch"
    fi
    n=$(tail -n +2 "${TMP}/apple" | wc -l | tr -d ' ')
    tail -n +2 "${TMP}/apple" > "${TMP}/a"
    tail -n +2 "${TMP}/finch" > "${TMP}/f"
    masked "${name}" "${TMP}/a" > "${TMP}/a.masked"
    masked "${name}" "${TMP}/f" > "${TMP}/f.masked"
    if [[ "${name}" == videotoolbox-test ]]; then
        # H.264 is lossy: allow the average RGB channels to differ by up to 16 levels.
        python3 tools/video_comparison.py "${TMP}/a.masked" "${TMP}/f.masked"
        d=$?
        [[ "${d}" -eq 0 ]] && d=0 || d=1
    elif [[ "${name}" == vision-test ]]; then
        # Rectangle and QR coordinates vary slightly between the two CPU paths;
        # every other Vision field must match exactly.
        python3 - "${TMP}/a.masked" "${TMP}/f.masked" <<'PY'
import re, sys
from pathlib import Path

apple = Path(sys.argv[1]).read_text().splitlines()
finch = Path(sys.argv[2]).read_text().splitlines()
if len(apple) != len(finch):
    raise SystemExit(f"Vision output line counts differ: {len(apple)} / {len(finch)}")

rect = re.compile(r"^rectangles\.box=")
barcode = re.compile(r"^barcode\.value=(\S+) symbology=(\S+) confidence=([0-9.]+) box=([0-9.,-]+)$")
for line_number, (left, right) in enumerate(zip(apple, finch), 1):
    if rect.match(left) and rect.match(right):
        a, f = [float(value) for value in re.findall(r"-?[0-9]+\.[0-9]+", left)], \
               [float(value) for value in re.findall(r"-?[0-9]+\.[0-9]+", right)]
        if len(a) != 13 or len(f) != 13 or any(abs(x - y) > (0.03 if i == 12 else 0.015)
                                               for i, (x, y) in enumerate(zip(a, f))):
            raise SystemExit(f"rectangle observation differs beyond its documented tolerance at line {line_number}: {left} / {right}")
    elif left.startswith("barcode.value=") and right.startswith("barcode.value="):
        a, f = barcode.fullmatch(left), barcode.fullmatch(right)
        if not a or not f or a.group(1, 2) != f.group(1, 2):
            raise SystemExit(f"barcode payload or symbology differs at line {line_number}: {left} / {right}")
        av = [float(a.group(3)), *[float(value) for value in a.group(4).split(",")]]
        fv = [float(f.group(3)), *[float(value) for value in f.group(4).split(",")]]
        if len(av) != 5 or len(fv) != 5 or abs(av[0] - fv[0]) > 0.005 or any(
            abs(x - y) > 0.005 for x, y in zip(av[1:], fv[1:])
        ):
            raise SystemExit(f"barcode observation differs beyond its documented tolerance at line {line_number}: {left} / {right}")
    elif left != right:
        raise SystemExit(f"Vision output differs at line {line_number}: {left} / {right}")
PY
        d=$?
        [[ "${d}" -eq 0 ]] && d=0 || d=1
    else
        d=$(diff "${TMP}/a.masked" "${TMP}/f.masked" | grep -c '^[<>]')
    fi
    if [[ "${apple_status}" -ne 0 || "${finch_status}" -ne 0 ]]; then
        report "${name}" "FAILED (Apple exit ${apple_status}, Finch exit ${finch_status})"
        cat "${TMP}/apple.err" "${TMP}/finch.err" >&2
        count_fail
    elif [[ "${n}" -eq 0 ]]; then
        report "${name}" "no output from Apple's run"
        count_fail
    elif [[ "${d}" -eq 0 ]]; then
        report "${name}" "ok (${n} lines)"
        count_pass
        if [[ "${name}" == vision-test && "${excused}" != "pass" ]]; then
            mkdir -p build/compat-results
            cp userland/tests/vision-api-verified.json build/compat-results/Vision.json
        fi
    else
        report "${name}" "DIFFERS (${d} lines of ${n})"
        diff -u "${TMP}/a.masked" "${TMP}/f.masked" | head -80
        count_fail
    fi
done

for name in "${EXPECT[@]}"; do
    want "appkit-${name}-test" || continue
    bin="${B}/finch-appkit-${name}-test"
    expected="userland/tests/appkit-${name}-test.expected"
    if [[ ! -x "${bin}" || ! -f "${expected}" ]]; then
        report "appkit-${name}-test" "not built"
        skip=$((skip + 1))
        continue
    fi
    DYLD_FRAMEWORK_PATH="${FW}" DYLD_LIBRARY_PATH="${LIBS}" FINCH_FILTER_DIRS="build/root/System/Library/Filters" FINCH_FONT_DIRS="${R}/Fonts" "${bin}" "${SERVER}" > "${TMP}/finch" 2> "${TMP}/finch.err"
    finch_status=$?
    d=$(diff "${TMP}/finch" "${expected}" | grep -c '^[<>]')
    if [[ "${finch_status}" -ne 0 ]]; then
        report "appkit-${name}-test" "FAILED (exit ${finch_status})"
        cat "${TMP}/finch.err" >&2
        count_fail
    elif [[ "${d}" -eq 0 ]]; then
        report "appkit-${name}-test" "ok (expected)"
        count_pass
    else
        report "appkit-${name}-test" "DIFFERS from expected (${d} lines)"
        count_fail
    fi
done

for entry in "${FINCH_ONLY[@]}"; do
    name="${entry%%|*}"
    args="${entry#*|}"
    want "${name}" || continue
    bin="${B}/finch-${name}"
    expected="userland/tests/${name}.expected"
    if [[ ! -x "${bin}" || ! -f "${expected}" ]]; then
        report "${name}" "not built"
        skip=$((skip + 1))
        continue
    fi
    # shellcheck disable=SC2086
    DYLD_FRAMEWORK_PATH="${FW}" DYLD_LIBRARY_PATH="${LIBS}" "${bin}" ${args} > "${TMP}/finch" 2> "${TMP}/finch.err"
    finch_status=$?
    if [[ "${finch_status}" -ne 0 ]]; then
        report "${name}" "FAILED (exit ${finch_status})"
        cat "${TMP}/finch.err" >&2
        count_fail
    elif diff -q "${TMP}/finch" "${expected}" > /dev/null; then
        report "${name}" "ok (expected)"
        count_pass
    else
        report "${name}" "DIFFERS from expected"
        count_fail
    fi
done

if want contacts-store-test; then
    # (Finch-only: Apple's store asks the user for access)
    DYLD_FRAMEWORK_PATH="${FW}" "${B}/finch-contacts-test" store > "${TMP}/raw" 2> "${TMP}/finch.err"
    finch_status=$?
    tail -n +2 "${TMP}/raw" > "${TMP}/finch"
    if [[ "${finch_status}" -eq 0 ]] && diff -q "${TMP}/finch" userland/tests/contacts-store-test.expected > /dev/null; then
        report contacts-store-test "ok (expected)"
        count_pass
    else
        report contacts-store-test "DIFFERS from expected"
        count_fail
    fi
fi

if want metal-devices-test; then
    # (Finch-only: no GPU is driven yet, so there are no devices)
    DYLD_FRAMEWORK_PATH="${FW}" "${B}/finch-metal-test" devices > "${TMP}/raw" 2> "${TMP}/finch.err"
    finch_status=$?
    tail -n +2 "${TMP}/raw" > "${TMP}/finch"
    if [[ "${finch_status}" -eq 0 ]] && diff -q "${TMP}/finch" userland/tests/metal-devices-test.expected > /dev/null; then
        report metal-devices-test "ok (expected)"
        count_pass
    else
        report metal-devices-test "DIFFERS from expected"
        count_fail
    fi
fi

if want hello-test; then
    DYLD_FRAMEWORK_PATH="${FW}" FINCH_FONT_DIRS="${R}/Fonts" "${B}/finch-app-test" "${SERVER}" \
        "${B}/apps/Hello.app/Contents/MacOS/Hello" "window:Hello, Finch" wait:1500 windows output sample:5,40,content \
        sample:180,16,titlebar click:222,68 type:Finch click:111,99 click:298,132 output sample:298,132,button cmd:q \
        output > "${TMP}/finch" 2> "${TMP}/finch.err"
    finch_status=$?
    if [[ "${finch_status}" -eq 0 ]] && diff -q "${TMP}/finch" userland/tests/hello-test.expected > /dev/null; then
        report hello-test "ok (expected)"
        count_pass
    else
        report hello-test "DIFFERS from expected"
        count_fail
    fi
fi

echo "${pass} passed, ${fail} failed, ${known} known failures, ${skip} not built"
[[ "${fail}" -eq 0 && ( $# -eq 0 || "${skip}" -eq 0 ) ]]
