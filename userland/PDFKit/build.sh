#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# PDFKit: document, page, outline, selection and view objects over Finch CoreGraphics,
# CoreText and AppKit. It compiles against the macOS SDK's public headers.
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/PDFKit"
ROOT="${FINCH_ROOT}/build/root"
FW="${ROOT}/System/Library/Frameworks/PDFKit.framework"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"

[[ -f "${SDKROOT}/System/Library/Frameworks/PDFKit.framework/Headers/PDFKit.h" ]] || {
    echo "PDFKit headers are missing from the macOS SDK" >&2
    exit 1
}

for dependency in AppKit CoreGraphics CoreText Foundation; do
    [[ -f "${ROOT}/System/Library/Frameworks/${dependency}.framework/${dependency}" ]] || {
        echo "build ${dependency} first" >&2
        exit 1
    }
done

CFLAGS="-Wno-incomplete-implementation -F${SDKROOT}/System/Library/Frameworks" \
    "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/PDFKit.framework/Versions/A/PDFKit 1451.4.2 1.0 com.apple.PDFKit 1.0 \
    "${HERE}/PDFKit.m" "${HERE}/PDFView.m" -- -framework AppKit -framework CoreGraphics -framework CoreText -framework Foundation

# Public declarations and module metadata come from the SDK at build time. Finch does
# not redistribute those files in its framework image.
rm -rf "${FW}/Headers" "${FW}/Modules" "${FW}/Versions/A/Headers" "${FW}/Versions/A/Modules"
