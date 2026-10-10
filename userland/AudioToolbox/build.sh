#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# AudioToolbox.framework: Finch's. System sounds (AudioServices.c), silent until Finch
# has audio output; AudioFormat's properties (AudioFormat.c, over AudioFormatTables.c:
# Apple's values, tools/audiotoolbox/gen-audio-format.sh); audio files, read and written
# as Apple's writes them (AudioFile.c).
#   userland/AudioToolbox/build.sh -> build/root/System/Library/Frameworks/AudioToolbox.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/AudioToolbox.framework/Versions/A/AudioToolbox 1000 1 com.apple.audio.toolbox.AudioToolbox 1.14 \
    "${FINCH_ROOT}/userland/AudioToolbox/AudioServices.c" "${FINCH_ROOT}/userland/AudioToolbox/AudioFormat.c" \
    "${FINCH_ROOT}/userland/AudioToolbox/AudioFormatTables.c" "${FINCH_ROOT}/userland/AudioToolbox/AudioFile.c" \
    -- -framework CoreFoundation -framework CoreAudio
