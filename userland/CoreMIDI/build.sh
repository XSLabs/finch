#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# CoreMIDI's client API uses a local graph of virtual ports and endpoints. No hardware
# devices are reported; virtual MIDI sources and destinations exchange packets in process.
#   userland/CoreMIDI/build.sh -> build/root/System/Library/Frameworks/CoreMIDI.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/CoreMIDI.framework/Versions/A/CoreMIDI 69 1 com.apple.audio.CoreMIDI 1.0 \
    "${FINCH_ROOT}/userland/CoreMIDI/CoreMIDI.c" -- -framework CoreFoundation
