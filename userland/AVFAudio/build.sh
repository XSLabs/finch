#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Audio format, channel layout and PCM buffer objects.
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/AVFAudio.framework/Versions/A/AVFAudio 1 1 com.apple.audio.AVFAudio 1.0 \
    "${FINCH_ROOT}/userland/AVFAudio/AVAudioFormat.m" \
    "${FINCH_ROOT}/userland/AVFAudio/AVAudioBuffer.m" \
    "${FINCH_ROOT}/userland/AVFAudio/AVAudioFile.m" \
    "${FINCH_ROOT}/userland/AVFAudio/AVAudioConverter.m" \
    "${FINCH_ROOT}/userland/AVFAudio/AVAudioTime.m" \
    "${FINCH_ROOT}/userland/AVFAudio/AVAudioEngine.m" \
    "${FINCH_ROOT}/userland/AVFAudio/AVAudioUnit.m" \
    "${FINCH_ROOT}/userland/AVFAudio/AVAudioUnitComponent.m" \
    "${FINCH_ROOT}/userland/AVFAudio/AVAudioPlayer.m" \
    "${FINCH_ROOT}/userland/AVFAudio/AVFConstants.m" \
    "${FINCH_ROOT}/userland/AVFAudio/AVAudioSession.m" \
    "${FINCH_ROOT}/userland/AVFAudio/AVAudioRecorder.m" \
    "${FINCH_ROOT}/userland/AVFAudio/AVSpeechSynthesis.m" \
    "${FINCH_ROOT}/userland/AVFAudio/AVMusicEvents.m" \
    "${FINCH_ROOT}/userland/AVFAudio/AVAudioSequencer.m" \
    "${FINCH_ROOT}/userland/AVFAudio/AVMIDIPlayer.m" \
    "${FINCH_ROOT}/userland/AVFAudio/AVProtocolReferences.m" \
    -- -framework Foundation -framework AudioToolbox -framework CoreMedia
