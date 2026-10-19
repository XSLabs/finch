/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* MIDI file timing and transport over Finch's AudioToolbox sequence engine. */
#import <AVFAudio/AVMIDIPlayer.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Block.h>
#include <math.h>
#include <stdlib.h>

typedef struct {
    MusicSequence sequence;
    MusicPlayer player;
    NSTimeInterval duration;
    float rate;
    NSUInteger playGeneration;
} FinchMIDIPlayerState;

static NSError *
midi_player_error(OSStatus status)
{
    return status == noErr ? nil : [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
}

static NSTimeInterval
sequence_duration(MusicSequence sequence)
{
    UInt32 count = 0;
    if (MusicSequenceGetTrackCount(sequence, &count) != noErr)
        return 0;
    MusicTimeStamp end = 0;
    for (UInt32 index = 0; index < count; index++) {
        MusicTrack track = NULL;
        MusicTimeStamp length = 0;
        if (MusicSequenceGetIndTrack(sequence, index, &track) == noErr &&
            MusicTrackGetProperty(track, kSequenceTrackProperty_TrackLength, &length, &(UInt32){sizeof(length)}) == noErr &&
            isfinite(length) && length > end)
            end = length;
    }
    Float64 seconds = 0;
    return MusicSequenceGetSecondsForBeats(sequence, end, &seconds) == noErr && isfinite(seconds) && seconds > 0 ? seconds : 0;
}

@implementation AVMIDIPlayer

- (instancetype)_finchInitWithLoadStatus:(OSStatus)status error:(NSError **)outError
{
    if (status) {
        if (outError) *outError = midi_player_error(status);
        [self release];
        return nil;
    }
    FinchMIDIPlayerState *state = _impl;
    status = NewMusicPlayer(&state->player);
    if (!status)
        status = MusicPlayerSetSequence(state->player, state->sequence);
    if (status) {
        if (outError) *outError = midi_player_error(status);
        [self release];
        return nil;
    }
    state->duration = sequence_duration(state->sequence);
    state->rate = 1.0f;
    if (outError) *outError = nil;
    return self;
}

- (instancetype)initWithContentsOfURL:(NSURL *)url soundBankURL:(NSURL *)bankURL error:(NSError **)outError
{
    (void)bankURL;
    if (!(self = [super init]))
        return nil;
    _impl = calloc(1, sizeof(FinchMIDIPlayerState));
    if (!_impl) {
        [self release];
        if (outError) *outError = midi_player_error(memFullErr);
        return nil;
    }
    FinchMIDIPlayerState *state = _impl;
    OSStatus status = NewMusicSequence(&state->sequence);
    if (!status)
        status = MusicSequenceFileLoad(state->sequence, (CFURLRef)url, kMusicSequenceFile_MIDIType, kMusicSequenceLoadSMF_PreserveTracks);
    return [self _finchInitWithLoadStatus:status error:outError];
}

- (instancetype)initWithData:(NSData *)data soundBankURL:(NSURL *)bankURL error:(NSError **)outError
{
    (void)bankURL;
    if (!(self = [super init]))
        return nil;
    _impl = calloc(1, sizeof(FinchMIDIPlayerState));
    if (!_impl) {
        [self release];
        if (outError) *outError = midi_player_error(memFullErr);
        return nil;
    }
    FinchMIDIPlayerState *state = _impl;
    OSStatus status = NewMusicSequence(&state->sequence);
    if (!status)
        status = MusicSequenceFileLoadData(state->sequence, (CFDataRef)data, kMusicSequenceFile_MIDIType, kMusicSequenceLoadSMF_PreserveTracks);
    return [self _finchInitWithLoadStatus:status error:outError];
}

- (void)dealloc
{
    FinchMIDIPlayerState *state = _impl;
    if (state) {
        state->playGeneration++;
        if (state->player) {
            MusicPlayerStop(state->player);
            DisposeMusicPlayer(state->player);
        }
        if (state->sequence)
            DisposeMusicSequence(state->sequence);
        free(state);
    }
    [super dealloc];
}

- (NSTimeInterval)duration { return ((FinchMIDIPlayerState *)_impl)->duration; }
- (BOOL)isPlaying
{
    Boolean playing = false;
    MusicPlayerIsPlaying(((FinchMIDIPlayerState *)_impl)->player, &playing);
    return playing;
}
- (float)rate { return ((FinchMIDIPlayerState *)_impl)->rate; }
- (void)setRate:(float)rate
{
    if (!isfinite(rate) || rate <= 0)
        return;
    FinchMIDIPlayerState *state = _impl;
    OSStatus status = MusicPlayerSetPlayRateScalar(state->player, rate);
    if (!status)
        state->rate = rate;
}
- (NSTimeInterval)currentPosition
{
    MusicTimeStamp beats = 0;
    FinchMIDIPlayerState *state = _impl;
    if (MusicPlayerGetTime(state->player, &beats) != noErr)
        return 0;
    Float64 seconds = 0;
    return MusicSequenceGetSecondsForBeats(state->sequence, beats, &seconds) == noErr ? seconds : 0;
}
- (void)setCurrentPosition:(NSTimeInterval)seconds
{
    if (!isfinite(seconds))
        return;
    FinchMIDIPlayerState *state = _impl;
    MusicTimeStamp beats = 0;
    if (MusicSequenceGetBeatsForSeconds(state->sequence, seconds, &beats) == noErr)
        MusicPlayerSetTime(state->player, beats);
}
- (void)prepareToPlay { MusicPlayerPreroll(((FinchMIDIPlayerState *)_impl)->player); }
- (void)play:(AVMIDIPlayerCompletionHandler)completionHandler
{
    FinchMIDIPlayerState *state = _impl;
    MusicPlayerSetPlayRateScalar(state->player, state->rate);
    if (MusicPlayerPreroll(state->player) != noErr || MusicPlayerStart(state->player) != noErr)
        return;
    if (!completionHandler)
        return;
    NSUInteger generation = ++state->playGeneration;
    NSTimeInterval remaining = MAX(0, state->duration - self.currentPosition) / state->rate;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        AVMIDIPlayer *player = self;
        FinchMIDIPlayerState *current = player->_impl;
        if (current->playGeneration != generation || !player.isPlaying)
            return;
        MusicPlayerStop(current->player);
        current->playGeneration++;
        AVMIDIPlayerCompletionHandler handler = [completionHandler copy];
        handler();
        [handler release];
    });
}
- (void)stop
{
    FinchMIDIPlayerState *state = _impl;
    state->playGeneration++;
    MusicPlayerStop(state->player);
}

@end
