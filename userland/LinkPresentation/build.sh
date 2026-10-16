#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# LinkPresentation: page metadata fetched through Finch Foundation's URL loading, plus an AppKit card.
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/LinkPresentation"
OBJC_ARC=1 "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/LinkPresentation.framework/Versions/A/LinkPresentation 296.10 1 com.apple.linkpresentation 1.0 \
    "${HERE}/LinkPresentation.m" -- -framework AppKit -framework Foundation -framework CoreGraphics \
    -framework UniformTypeIdentifiers
