#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# AudioToolbox.framework: Finch's. System sounds (AudioServices.c), silent until Finch
# has audio output; AudioFormat's properties (AudioFormat.c, over AudioFormatTables.c:
# Apple's values, tools/audiotoolbox/gen-audio-format.sh); audio files, read and written
# as Apple's writes them (AudioFile.c), and PCM/G.711 sample conversion (AudioConverter.c).
# Audio units (AudioUnit.c): output, converter and mixer, and the effect, time and
# instrument units (AudioUnitEffects.c, over AudioUnitEffectTables.c: Apple's parameters
# and presets, tools/audiotoolbox/gen-effect-tables.sh).
#   userland/AudioToolbox/build.sh -> build/root/System/Library/Frameworks/AudioToolbox.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/AudioToolbox.framework/Versions/A/AudioToolbox 1000 1 com.apple.audio.toolbox.AudioToolbox 1.14 \
    "${FINCH_ROOT}/userland/AudioToolbox/AudioServices.c" "${FINCH_ROOT}/userland/AudioToolbox/AudioFormat.c" \
    "${FINCH_ROOT}/userland/AudioToolbox/AudioConverter.c" \
    "${FINCH_ROOT}/userland/AudioToolbox/ExtendedAudioFile.c" "${FINCH_ROOT}/userland/AudioToolbox/AudioUnit.c" \
    "${FINCH_ROOT}/userland/AudioToolbox/AudioQueue.c" "${FINCH_ROOT}/userland/AudioToolbox/AudioUnitEffects.c" \
    "${FINCH_ROOT}/userland/AudioToolbox/AudioUnitEffectTables.c" \
    "${FINCH_ROOT}/userland/AudioToolbox/AudioFormatTables.c" "${FINCH_ROOT}/userland/AudioToolbox/AudioFile.c" \
    -- -framework CoreFoundation -framework CoreAudio
