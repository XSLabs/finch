/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* MIDI sequence editing and beat timing over Finch's AudioToolbox sequence engine. */
#import <AVFAudio/AVAudioSequencer.h>
#import <AVFAudio/AVAudioEngine.h>
#import <AVFAudio/AVAudioUnit.h>
#import <AVFAudio/AVMusicEvents.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Block.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#pragma clang diagnostic ignored "-Wincomplete-implementation"

extern OSStatus FinchMusicSequenceDetachTrack(MusicSequence, MusicTrack);

@interface AVMusicTrack (FinchMusicTrack)
- (instancetype)_finchInitWithTrack:(MusicTrack)track owner:(AVAudioSequencer *)owner;
- (MusicTrack)_finchMusicTrack;
- (void)_finchInvalidate;
@end

@interface AVAudioSequencer (FinchSequencer)
- (instancetype)_finchInit;
- (MusicSequence)_finchSequence;
- (void)_finchRegisterTrack:(AVMusicTrack *)track;
@end

@interface AVMIDIMetaEvent (FinchEventData)
- (NSData *)_finchData;
@end

@interface AVMIDISysexEvent (FinchEventData)
- (NSData *)_finchData;
@end

@interface AVMusicUserEvent (FinchEventData)
- (NSData *)_finchData;
@end

typedef struct {
    MusicSequence sequence;
    MusicPlayer player;
    NSMutableArray *tracks;
    NSMutableArray *allTracks;
    AVMusicTrack *tempoTrack;
    AVAudioEngine *engine;
    AVAudioSequencerUserCallback userCallback;
} FinchSequencerState;

typedef struct {
    MusicTrack track;
    AVAudioSequencer *owner;
    AVAudioUnit *destinationAudioUnit;
    BOOL loopingEnabled;
} FinchMusicTrackState;

static NSError *
sequencer_error(OSStatus status)
{
    if (status == noErr)
        return nil;
    return [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
}

static void
sequence_user_event(void *clientData, MusicSequence sequence, MusicTrack rawTrack,
                    MusicTimeStamp eventTime, const MusicEventUserData *eventData,
                    MusicTimeStamp startBeat, MusicTimeStamp endBeat)
{
    FinchSequencerState *state = clientData;
    if (!state || !state->userCallback || !eventData)
        return;

    AVMusicTrack *track = nil;
    for (AVMusicTrack *candidate in state->allTracks)
        if ([candidate _finchMusicTrack] == rawTrack) {
            track = [candidate retain];
            break;
        }
    if (!track)
        return;

    NSUInteger length = MIN((NSUInteger)eventData->length, (NSUInteger)UINT32_MAX);
    NSData *data = [[NSData alloc] initWithBytes:eventData->data length:length];
    AVAudioSequencerUserCallback callback = (AVAudioSequencerUserCallback)Block_copy(state->userCallback);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        callback(track, data, eventTime);
        [track release];
        [data release];
        Block_release(callback);
    });
}

static OSStatus
track_get(MusicTrack track, UInt32 property, void *value)
{
    UInt32 size = property == kSequenceTrackProperty_LoopInfo ? sizeof(MusicTrackLoopInfo) :
        property == kSequenceTrackProperty_MuteStatus || property == kSequenceTrackProperty_SoloStatus ? sizeof(Boolean) :
        property == kSequenceTrackProperty_AutomatedParameters ? sizeof(UInt32) : sizeof(MusicTimeStamp);
    return MusicTrackGetProperty(track, property, value, &size);
}

static OSStatus
track_set(MusicTrack track, UInt32 property, void *value)
{
    UInt32 size = property == kSequenceTrackProperty_LoopInfo ? sizeof(MusicTrackLoopInfo) :
        property == kSequenceTrackProperty_MuteStatus || property == kSequenceTrackProperty_SoloStatus ? sizeof(Boolean) :
        property == kSequenceTrackProperty_AutomatedParameters ? sizeof(UInt32) : sizeof(MusicTimeStamp);
    return MusicTrackSetProperty(track, property, value, size);
}

static NSData *
event_data(const void *bytes, UInt32 length)
{
    return [NSData dataWithBytes:bytes length:length];
}

static AVMusicEvent *
event_from_music_data(MusicEventType type, const void *data)
{
    if (!data)
        return nil;
    switch (type) {
    case kMusicEventType_MIDINoteMessage: {
        const MIDINoteMessage *note = data;
        return [[[AVMIDINoteEvent alloc] initWithChannel:note->channel key:note->note
            velocity:note->velocity duration:note->duration] autorelease];
    }
    case kMusicEventType_MIDIChannelMessage: {
        const MIDIChannelMessage *message = data;
        UInt32 channel = message->status & 0x0f;
        switch (message->status & 0xf0) {
        case 0xb0:
            return [[[AVMIDIControlChangeEvent alloc] initWithChannel:channel
                messageType:(AVMIDIControlChangeMessageType)message->data1 value:message->data2] autorelease];
        case 0xa0:
            return [[[AVMIDIPolyPressureEvent alloc] initWithChannel:channel key:message->data1
                pressure:message->data2] autorelease];
        case 0xc0:
            return [[[AVMIDIProgramChangeEvent alloc] initWithChannel:channel
                programNumber:message->data1] autorelease];
        case 0xd0:
            return [[[AVMIDIChannelPressureEvent alloc] initWithChannel:channel
                pressure:message->data1] autorelease];
        case 0xe0:
            return [[[AVMIDIPitchBendEvent alloc] initWithChannel:channel
                value:((UInt32)message->data2 << 7) | message->data1] autorelease];
        default:
            return nil;
        }
    }
    case kMusicEventType_ExtendedNote: {
        const ExtendedNoteOnEvent *note = data;
        return [[[AVExtendedNoteOnEvent alloc] initWithMIDINote:note->extendedParams.mPitch
            velocity:note->extendedParams.mVelocity instrumentID:note->instrumentID
            groupID:note->groupID duration:note->duration] autorelease];
    }
    case kMusicEventType_ExtendedTempo:
        return [[[AVExtendedTempoEvent alloc] initWithTempo:((const ExtendedTempoEvent *)data)->bpm] autorelease];
    case kMusicEventType_Parameter: {
        const ParameterEvent *parameter = data;
        return [[[AVParameterEvent alloc] initWithParameterID:parameter->parameterID scope:parameter->scope
            element:parameter->element value:parameter->value] autorelease];
    }
    case kMusicEventType_Meta: {
        const MIDIMetaEvent *meta = data;
        NSData *bytes = event_data(meta->data, meta->dataLength);
        return [[[AVMIDIMetaEvent alloc] initWithType:(AVMIDIMetaEventType)meta->metaEventType data:bytes] autorelease];
    }
    case kMusicEventType_User: {
        const MusicEventUserData *user = data;
        return [[[AVMusicUserEvent alloc] initWithData:event_data(user->data, user->length)] autorelease];
    }
    case kMusicEventType_MIDIRawData: {
        const MIDIRawData *raw = data;
        return [[[AVMIDISysexEvent alloc] initWithData:event_data(raw->data, raw->length)] autorelease];
    }
    case kMusicEventType_AUPreset: {
        const AUPresetEvent *preset = data;
        NSDictionary *dictionary = (NSDictionary *)preset->preset;
        return [[[AVAUPresetEvent alloc] initWithScope:preset->scope element:preset->element
            dictionary:dictionary ?: @{}] autorelease];
    }
    default:
        return nil;
    }
}

static OSStatus
add_music_event(MusicTrack track, AVMusicEvent *event, MusicTimeStamp beat, BOOL tempoTrack, BOOL automated)
{
    if ([event isKindOfClass:[AVMIDINoteEvent class]]) {
        AVMIDINoteEvent *source = (AVMIDINoteEvent *)event;
        MIDINoteMessage note = { (UInt8)source.channel, (UInt8)source.key, (UInt8)source.velocity, 0, (Float32)source.duration };
        return MusicTrackNewMIDINoteEvent(track, beat, &note);
    }
    if ([event isKindOfClass:[AVMIDIControlChangeEvent class]]) {
        AVMIDIControlChangeEvent *source = (AVMIDIControlChangeEvent *)event;
        MIDIChannelMessage message = { (UInt8)(0xb0 | (source.channel & 0x0f)), (UInt8)source.messageType, (UInt8)source.value, 0 };
        return MusicTrackNewMIDIChannelEvent(track, beat, &message);
    }
    if ([event isKindOfClass:[AVMIDIPolyPressureEvent class]]) {
        AVMIDIPolyPressureEvent *source = (AVMIDIPolyPressureEvent *)event;
        MIDIChannelMessage message = { (UInt8)(0xa0 | (source.channel & 0x0f)), (UInt8)source.key, (UInt8)source.pressure, 0 };
        return MusicTrackNewMIDIChannelEvent(track, beat, &message);
    }
    if ([event isKindOfClass:[AVMIDIProgramChangeEvent class]]) {
        AVMIDIProgramChangeEvent *source = (AVMIDIProgramChangeEvent *)event;
        MIDIChannelMessage message = { (UInt8)(0xc0 | (source.channel & 0x0f)), (UInt8)source.programNumber, 0, 0 };
        return MusicTrackNewMIDIChannelEvent(track, beat, &message);
    }
    if ([event isKindOfClass:[AVMIDIChannelPressureEvent class]]) {
        AVMIDIChannelPressureEvent *source = (AVMIDIChannelPressureEvent *)event;
        MIDIChannelMessage message = { (UInt8)(0xd0 | (source.channel & 0x0f)), (UInt8)source.pressure, 0, 0 };
        return MusicTrackNewMIDIChannelEvent(track, beat, &message);
    }
    if ([event isKindOfClass:[AVMIDIPitchBendEvent class]]) {
        AVMIDIPitchBendEvent *source = (AVMIDIPitchBendEvent *)event;
        MIDIChannelMessage message = { (UInt8)(0xe0 | (source.channel & 0x0f)), (UInt8)(source.value & 0x7f),
            (UInt8)((source.value >> 7) & 0x7f), 0 };
        return MusicTrackNewMIDIChannelEvent(track, beat, &message);
    }
    if ([event isKindOfClass:[AVExtendedNoteOnEvent class]]) {
        AVExtendedNoteOnEvent *source = (AVExtendedNoteOnEvent *)event;
        ExtendedNoteOnEvent note = {0};
        note.instrumentID = source.instrumentID;
        note.groupID = source.groupID;
        note.duration = (Float32)source.duration;
        note.extendedParams.argCount = 2;
        note.extendedParams.mPitch = source.midiNote;
        note.extendedParams.mVelocity = source.velocity;
        return MusicTrackNewExtendedNoteEvent(track, beat, &note);
    }
    if ([event isKindOfClass:[AVExtendedTempoEvent class]])
        return tempoTrack ? MusicTrackNewExtendedTempoEvent(track, beat, ((AVExtendedTempoEvent *)event).tempo) : kAudioToolboxErr_InvalidEventType;
    if ([event isKindOfClass:[AVParameterEvent class]]) {
        if (!automated)
            return kAudioToolboxErr_InvalidEventType;
        AVParameterEvent *source = (AVParameterEvent *)event;
        ParameterEvent parameter = { source.parameterID, source.scope, source.element, source.value };
        return MusicTrackNewParameterEvent(track, beat, &parameter);
    }
    if ([event isKindOfClass:[AVMIDIMetaEvent class]]) {
        if (tempoTrack && !((AVMIDIMetaEvent *)event).type) { /* sequence number is valid on the tempo track */ }
        NSData *bytes = [(AVMIDIMetaEvent *)event _finchData];
        NSUInteger length = MIN(bytes.length, UINT32_MAX);
        MIDIMetaEvent *meta = calloc(1, offsetof(MIDIMetaEvent, data) + length);
        if (!meta)
            return memFullErr;
        meta->metaEventType = (UInt8)((AVMIDIMetaEvent *)event).type;
        meta->dataLength = (UInt32)length;
        if (length)
            memcpy(meta->data, bytes.bytes, length);
        OSStatus status = MusicTrackNewMetaEvent(track, beat, meta);
        free(meta);
        return status;
    }
    if ([event isKindOfClass:[AVMIDISysexEvent class]] || [event isKindOfClass:[AVMusicUserEvent class]]) {
        NSData *bytes = [(id)event _finchData];
        NSUInteger length = MIN(bytes.length, UINT32_MAX);
        size_t header = [event isKindOfClass:[AVMIDISysexEvent class]] ? offsetof(MIDIRawData, data) : offsetof(MusicEventUserData, data);
        void *storage = calloc(1, header + length);
        if (!storage)
            return memFullErr;
        OSStatus status;
        if ([event isKindOfClass:[AVMIDISysexEvent class]]) {
            MIDIRawData *raw = storage;
            raw->length = (UInt32)length;
            if (length) memcpy(raw->data, bytes.bytes, length);
            status = MusicTrackNewMIDIRawDataEvent(track, beat, raw);
        } else {
            MusicEventUserData *user = storage;
            user->length = (UInt32)length;
            if (length) memcpy(user->data, bytes.bytes, length);
            status = MusicTrackNewUserEvent(track, beat, user);
        }
        free(storage);
        return status;
    }
    if ([event isKindOfClass:[AVAUPresetEvent class]]) {
        AVAUPresetEvent *source = (AVAUPresetEvent *)event;
        AUPresetEvent preset = { source.scope, source.element, (CFPropertyListRef)source.presetDictionary };
        return MusicTrackNewAUPresetEvent(track, beat, &preset);
    }
    return kAudioToolboxErr_InvalidEventType;
}

@implementation AVAudioSequencer

- (instancetype)_finchInit
{
    if (!(self = [super init]))
        return nil;
    FinchSequencerState *state = calloc(1, sizeof(*state));
    if (!state) {
        [self release];
        return nil;
    }
    _impl = state;
    state->tracks = [NSMutableArray new];
    state->allTracks = [NSMutableArray new];
    OSStatus status = NewMusicSequence(&state->sequence);
    if (!status)
        status = NewMusicPlayer(&state->player);
    if (!status)
        status = MusicPlayerSetSequence(state->player, state->sequence);
    if (status) {
        [self release];
        return nil;
    }
    MusicTrack tempo = NULL;
    if (MusicSequenceGetTempoTrack(state->sequence, &tempo) == noErr) {
        state->tempoTrack = [[AVMusicTrack alloc] _finchInitWithTrack:tempo owner:self];
        [self _finchRegisterTrack:state->tempoTrack];
    }
    return self;
}

- (instancetype)init { return [self _finchInit]; }

- (instancetype)initWithAudioEngine:(AVAudioEngine *)engine
{
    if (!(self = [self _finchInit]))
        return nil;
    ((FinchSequencerState *)_impl)->engine = [engine retain];
    return self;
}

- (void)dealloc
{
    FinchSequencerState *state = _impl;
    if (state) {
        for (AVMusicTrack *track in state->allTracks)
            [track _finchInvalidate];
        if (state->player) {
            MusicPlayerStop(state->player);
            DisposeMusicPlayer(state->player);
        }
        if (state->sequence)
            DisposeMusicSequence(state->sequence);
        [state->tracks release];
        [state->allTracks release];
        [state->tempoTrack release];
        [state->engine release];
        if (state->userCallback)
            Block_release(state->userCallback);
        free(state);
    }
    [super dealloc];
}

- (MusicSequence)_finchSequence { return ((FinchSequencerState *)_impl)->sequence; }

- (void)_finchRegisterTrack:(AVMusicTrack *)track
{
    FinchSequencerState *state = _impl;
    if (track && ![state->allTracks containsObject:track])
        [state->allTracks addObject:track];
}

- (NSArray<AVMusicTrack *> *)tracks
{
    FinchSequencerState *state = _impl;
    NSMutableArray *current = [NSMutableArray new];
    UInt32 count = 0;
    if (MusicSequenceGetTrackCount(state->sequence, &count) == noErr) {
        for (UInt32 index = 0; index < count; index++) {
            MusicTrack raw = NULL;
            if (MusicSequenceGetIndTrack(state->sequence, index, &raw) != noErr)
                continue;
            AVMusicTrack *found = nil;
            for (AVMusicTrack *track in state->allTracks)
                if ([track _finchMusicTrack] == raw) { found = track; break; }
            if (!found) {
                found = [[AVMusicTrack alloc] _finchInitWithTrack:raw owner:self];
                [self _finchRegisterTrack:found];
                [found release];
            }
            [current addObject:found];
        }
    }
    [state->tracks release];
    state->tracks = current;
    return state->tracks;
}

- (AVMusicTrack *)tempoTrack { return ((FinchSequencerState *)_impl)->tempoTrack; }

- (NSDictionary<NSString *, id> *)userInfo
{
    CFDictionaryRef info = MusicSequenceGetInfoDictionary(((FinchSequencerState *)_impl)->sequence);
    return [(NSDictionary *)info autorelease];
}

- (BOOL)loadFromURL:(NSURL *)url options:(AVMusicSequenceLoadOptions)options error:(NSError **)outError
{
    if (!url.isFileURL) {
        if (outError) *outError = sequencer_error(kAudio_ParamError);
        return NO;
    }
    MusicSequenceLoadFlags flags = (options & AVMusicSequenceLoadSMF_ChannelsToTracks) ? kMusicSequenceLoadSMF_ChannelsToTracks : 0;
    OSStatus status = MusicSequenceFileLoad(((FinchSequencerState *)_impl)->sequence,
        (CFURLRef)url, kMusicSequenceFile_MIDIType, flags);
    if (outError) *outError = sequencer_error(status);
    return status == noErr;
}

- (BOOL)loadFromData:(NSData *)data options:(AVMusicSequenceLoadOptions)options error:(NSError **)outError
{
    MusicSequenceLoadFlags flags = (options & AVMusicSequenceLoadSMF_ChannelsToTracks) ? kMusicSequenceLoadSMF_ChannelsToTracks : 0;
    OSStatus status = MusicSequenceFileLoadData(((FinchSequencerState *)_impl)->sequence,
        (CFDataRef)data, kMusicSequenceFile_MIDIType, flags);
    if (outError) *outError = sequencer_error(status);
    return status == noErr;
}

- (BOOL)writeToURL:(NSURL *)url SMPTEResolution:(NSInteger)resolution replaceExisting:(BOOL)replace error:(NSError **)outError
{
    if (!url.isFileURL || resolution < SHRT_MIN || resolution > SHRT_MAX) {
        if (outError) *outError = sequencer_error(kAudio_ParamError);
        return NO;
    }
    MusicSequenceFileFlags flags = replace ? kMusicSequenceFileFlags_EraseFile : kMusicSequenceFileFlags_Default;
    OSStatus status = MusicSequenceFileCreate(((FinchSequencerState *)_impl)->sequence,
        (CFURLRef)url, kMusicSequenceFile_MIDIType, flags, (SInt16)resolution);
    if (outError) *outError = sequencer_error(status);
    return status == noErr;
}

- (NSData *)dataWithSMPTEResolution:(NSInteger)resolution error:(NSError **)outError
{
    if (resolution < SHRT_MIN || resolution > SHRT_MAX) {
        if (outError) *outError = sequencer_error(kAudio_ParamError);
        return nil;
    }
    CFDataRef data = NULL;
    OSStatus status = MusicSequenceFileCreateData(((FinchSequencerState *)_impl)->sequence,
        kMusicSequenceFile_MIDIType, kMusicSequenceFileFlags_Default, (SInt16)resolution, &data);
    if (outError) *outError = sequencer_error(status);
    if (status || !data)
        return nil;
    NSData *result = [[NSData alloc] initWithBytes:CFDataGetBytePtr(data) length:(NSUInteger)CFDataGetLength(data)];
    CFRelease(data);
    return [result autorelease];
}

- (NSTimeInterval)secondsForBeats:(AVMusicTimeStamp)beats
{
    Float64 seconds = 0;
    MusicSequenceGetSecondsForBeats(((FinchSequencerState *)_impl)->sequence, beats, &seconds);
    return seconds;
}

- (AVMusicTimeStamp)beatsForSeconds:(NSTimeInterval)seconds
{
    MusicTimeStamp beats = 0;
    MusicSequenceGetBeatsForSeconds(((FinchSequencerState *)_impl)->sequence, seconds, &beats);
    return beats;
}

- (void)reverseEvents { MusicSequenceReverse(((FinchSequencerState *)_impl)->sequence); }

- (AVMusicTrack *)createAndAppendTrack
{
    MusicTrack raw = NULL;
    if (MusicSequenceNewTrack(((FinchSequencerState *)_impl)->sequence, &raw) != noErr)
        return nil;
    AVMusicTrack *track = [[AVMusicTrack alloc] _finchInitWithTrack:raw owner:self];
    [self _finchRegisterTrack:track];
    return [track autorelease];
}

- (BOOL)removeTrack:(AVMusicTrack *)track
{
    FinchSequencerState *state = _impl;
    if (!track || [track _finchMusicTrack] == NULL || state->player == NULL)
        return NO;
    Boolean playing = false;
    MusicPlayerIsPlaying(state->player, &playing);
    if (playing)
        return NO;
    return FinchMusicSequenceDetachTrack(state->sequence, [track _finchMusicTrack]) == noErr;
}

- (NSTimeInterval)currentPositionInBeats
{
    MusicTimeStamp beat = 0;
    MusicPlayerGetTime(((FinchSequencerState *)_impl)->player, &beat);
    return beat;
}

- (void)setCurrentPositionInBeats:(NSTimeInterval)beat
{
    MusicPlayerSetTime(((FinchSequencerState *)_impl)->player, beat);
}

- (NSTimeInterval)currentPositionInSeconds { return [self secondsForBeats:self.currentPositionInBeats]; }
- (void)setCurrentPositionInSeconds:(NSTimeInterval)seconds { [self setCurrentPositionInBeats:[self beatsForSeconds:seconds]]; }

- (BOOL)isPlaying
{
    Boolean playing = false;
    MusicPlayerIsPlaying(((FinchSequencerState *)_impl)->player, &playing);
    return playing;
}

- (float)rate
{
    Float64 rate = 1;
    MusicPlayerGetPlayRateScalar(((FinchSequencerState *)_impl)->player, &rate);
    return (float)rate;
}

- (void)setRate:(float)rate
{
    MusicPlayerSetPlayRateScalar(((FinchSequencerState *)_impl)->player, rate);
}

- (UInt64)hostTimeForBeats:(AVMusicTimeStamp)beats error:(NSError **)outError
{
    UInt64 time = 0;
    OSStatus status = MusicPlayerGetHostTimeForBeats(((FinchSequencerState *)_impl)->player, beats, &time);
    if (outError) *outError = sequencer_error(status);
    return status ? 0 : time;
}

- (AVMusicTimeStamp)beatsForHostTime:(UInt64)hostTime error:(NSError **)outError
{
    MusicTimeStamp beats = 0;
    OSStatus status = MusicPlayerGetBeatsForHostTime(((FinchSequencerState *)_impl)->player, hostTime, &beats);
    if (outError) *outError = sequencer_error(status);
    return status ? 0 : beats;
}

- (void)prepareToPlay { MusicPlayerPreroll(((FinchSequencerState *)_impl)->player); }

- (BOOL)startAndReturnError:(NSError **)outError
{
    OSStatus status = MusicPlayerStart(((FinchSequencerState *)_impl)->player);
    if (outError) *outError = sequencer_error(status);
    return status == noErr;
}

- (void)stop { MusicPlayerStop(((FinchSequencerState *)_impl)->player); }

- (void)setUserCallback:(AVAudioSequencerUserCallback)userCallback
{
    FinchSequencerState *state = _impl;
    AVAudioSequencerUserCallback replacement = userCallback ? (AVAudioSequencerUserCallback)Block_copy(userCallback) : NULL;
    OSStatus status = MusicSequenceSetUserCallback(state->sequence, replacement ? sequence_user_event : NULL,
        replacement ? state : NULL);
    if (status != noErr) {
        if (replacement)
            Block_release(replacement);
        return;
    }
    if (state->userCallback)
        Block_release(state->userCallback);
    state->userCallback = replacement;
}

@end

@implementation AVMusicTrack

- (instancetype)_finchInitWithTrack:(MusicTrack)track owner:(AVAudioSequencer *)owner
{
    if (!(self = [super init]))
        return nil;
    FinchMusicTrackState *state = calloc(1, sizeof(*state));
    if (!state) {
        [self release];
        return nil;
    }
    state->track = track;
    state->owner = owner;
    MusicTrackLoopInfo loop = {0};
    track_get(track, kSequenceTrackProperty_LoopInfo, &loop);
    state->loopingEnabled = loop.loopDuration > 0;
    _impl = state;
    return self;
}

- (MusicTrack)_finchMusicTrack { return ((FinchMusicTrackState *)_impl)->track; }
- (void)_finchInvalidate { ((FinchMusicTrackState *)_impl)->track = NULL; ((FinchMusicTrackState *)_impl)->owner = nil; }

- (void)dealloc
{
    FinchMusicTrackState *state = _impl;
    [state->destinationAudioUnit release];
    free(state);
    [super dealloc];
}

- (MIDIEndpointRef)destinationMIDIEndpoint
{
    MIDIEndpointRef endpoint = 0;
    MusicTrackGetDestMIDIEndpoint(((FinchMusicTrackState *)_impl)->track, &endpoint);
    return endpoint;
}
- (void)setDestinationMIDIEndpoint:(MIDIEndpointRef)endpoint
{
    FinchMusicTrackState *state = _impl;
    if (state->track) {
        MusicTrackSetDestMIDIEndpoint(state->track, endpoint);
        [state->destinationAudioUnit release];
        state->destinationAudioUnit = nil;
    }
}

- (AVBeatRange)loopRange
{
    FinchMusicTrackState *state = _impl;
    MusicTrackLoopInfo loop = {0};
    MusicTimeStamp length = 0;
    track_get(state->track, kSequenceTrackProperty_LoopInfo, &loop);
    track_get(state->track, kSequenceTrackProperty_TrackLength, &length);
    return AVMakeBeatRange(MAX(0, length - loop.loopDuration), loop.loopDuration);
}
- (void)setLoopRange:(AVBeatRange)range
{
    FinchMusicTrackState *state = _impl;
    if (!state->track)
        return;
    MusicTrackLoopInfo loop = { range.length, 0 };
    track_set(state->track, kSequenceTrackProperty_LoopInfo, &loop);
    MusicTimeStamp length = 0;
    track_get(state->track, kSequenceTrackProperty_TrackLength, &length);
    if (range.start + range.length > length) {
        length = range.start + range.length;
        track_set(state->track, kSequenceTrackProperty_TrackLength, &length);
    }
}
- (BOOL)isLoopingEnabled { return ((FinchMusicTrackState *)_impl)->loopingEnabled; }
- (void)setLoopingEnabled:(BOOL)enabled
{
    ((FinchMusicTrackState *)_impl)->loopingEnabled = enabled;
}
- (NSInteger)numberOfLoops
{
    MusicTrackLoopInfo loop = {0};
    track_get(((FinchMusicTrackState *)_impl)->track, kSequenceTrackProperty_LoopInfo, &loop);
    return loop.numberOfLoops == 0 ? AVMusicTrackLoopCountForever : loop.numberOfLoops;
}
- (void)setNumberOfLoops:(NSInteger)value
{
    MusicTrackLoopInfo loop = {0};
    FinchMusicTrackState *state = _impl;
    track_get(state->track, kSequenceTrackProperty_LoopInfo, &loop);
    loop.numberOfLoops = (SInt32)(value == AVMusicTrackLoopCountForever ? 0 : MAX(1, value));
    track_set(state->track, kSequenceTrackProperty_LoopInfo, &loop);
}
- (AVMusicTimeStamp)offsetTime
{
    MusicTimeStamp value = 0;
    track_get(((FinchMusicTrackState *)_impl)->track, kSequenceTrackProperty_OffsetTime, &value);
    return value;
}
- (void)setOffsetTime:(AVMusicTimeStamp)value { track_set(((FinchMusicTrackState *)_impl)->track, kSequenceTrackProperty_OffsetTime, &value); }
- (BOOL)isMuted
{
    Boolean value = false;
    track_get(((FinchMusicTrackState *)_impl)->track, kSequenceTrackProperty_MuteStatus, &value);
    return value;
}
- (void)setMuted:(BOOL)value
{
    Boolean muted = value;
    track_set(((FinchMusicTrackState *)_impl)->track, kSequenceTrackProperty_MuteStatus, &muted);
}
- (BOOL)isSoloed
{
    Boolean value = false;
    track_get(((FinchMusicTrackState *)_impl)->track, kSequenceTrackProperty_SoloStatus, &value);
    return value;
}
- (void)setSoloed:(BOOL)value
{
    Boolean solo = value;
    track_set(((FinchMusicTrackState *)_impl)->track, kSequenceTrackProperty_SoloStatus, &solo);
}
- (AVMusicTimeStamp)lengthInBeats
{
    MusicTimeStamp length = 0;
    track_get(((FinchMusicTrackState *)_impl)->track, kSequenceTrackProperty_TrackLength, &length);
    return length;
}
- (void)setLengthInBeats:(AVMusicTimeStamp)value { track_set(((FinchMusicTrackState *)_impl)->track, kSequenceTrackProperty_TrackLength, &value); }
- (NSTimeInterval)lengthInSeconds
{
    FinchMusicTrackState *state = _impl;
    return [state->owner secondsForBeats:self.lengthInBeats];
}
- (void)setLengthInSeconds:(NSTimeInterval)value
{
    FinchMusicTrackState *state = _impl;
    self.lengthInBeats = [state->owner beatsForSeconds:value];
}
- (NSUInteger)timeResolution
{
    SInt16 resolution = 0;
    UInt32 size = sizeof(resolution);
    MusicTrackGetProperty(((FinchMusicTrackState *)_impl)->track, kSequenceTrackProperty_TimeResolution, &resolution, &size);
    return (NSUInteger)resolution;
}
- (BOOL)usesAutomatedParameters
{
    UInt32 value = 0;
    track_get(((FinchMusicTrackState *)_impl)->track, kSequenceTrackProperty_AutomatedParameters, &value);
    return value != 0;
}
- (void)setUsesAutomatedParameters:(BOOL)value
{
    UInt32 automated = value ? 1 : 0;
    track_set(((FinchMusicTrackState *)_impl)->track, kSequenceTrackProperty_AutomatedParameters, &automated);
}

- (void)addEvent:(AVMusicEvent *)event atBeat:(AVMusicTimeStamp)beat
{
    FinchMusicTrackState *state = _impl;
    if (!state->track || !event || !isfinite(beat) || beat < 0)
        [NSException raise:NSInvalidArgumentException format:@"An event needs a live track and a non-negative beat"];
    MusicTrack tempo = NULL;
    MusicSequenceGetTempoTrack([state->owner _finchSequence], &tempo);
    OSStatus status = add_music_event(state->track, event, beat, state->track == tempo, self.usesAutomatedParameters);
    if (status)
        [NSException raise:NSInvalidArgumentException format:@"AudioToolbox could not add this event (%d)", (int)status];
}

- (void)moveEventsInRange:(AVBeatRange)range byAmount:(AVMusicTimeStamp)amount
{
    MusicTrackMoveEvents(((FinchMusicTrackState *)_impl)->track, range.start,
        range.length == AVMusicTimeStampEndOfTrack ? kMusicTimeStamp_EndOfTrack : range.start + range.length, amount);
}
- (void)clearEventsInRange:(AVBeatRange)range
{
    MusicTrackClear(((FinchMusicTrackState *)_impl)->track, range.start,
        range.length == AVMusicTimeStampEndOfTrack ? kMusicTimeStamp_EndOfTrack : range.start + range.length);
}
- (void)cutEventsInRange:(AVBeatRange)range
{
    MusicTrackCut(((FinchMusicTrackState *)_impl)->track, range.start,
        range.length == AVMusicTimeStampEndOfTrack ? kMusicTimeStamp_EndOfTrack : range.start + range.length);
}
- (void)copyEventsInRange:(AVBeatRange)range fromTrack:(AVMusicTrack *)source insertAtBeat:(AVMusicTimeStamp)beat
{
    MusicTrackCopyInsert([source _finchMusicTrack], range.start,
        range.length == AVMusicTimeStampEndOfTrack ? kMusicTimeStamp_EndOfTrack : range.start + range.length,
        ((FinchMusicTrackState *)_impl)->track, beat);
}
- (void)copyAndMergeEventsInRange:(AVBeatRange)range fromTrack:(AVMusicTrack *)source mergeAtBeat:(AVMusicTimeStamp)beat
{
    MusicTrackMerge([source _finchMusicTrack], range.start,
        range.length == AVMusicTimeStampEndOfTrack ? kMusicTimeStamp_EndOfTrack : range.start + range.length,
        ((FinchMusicTrackState *)_impl)->track, beat);
}

- (void)enumerateEventsInRange:(AVBeatRange)range usingBlock:(NS_NOESCAPE AVMusicEventEnumerationBlock)block
{
    if (!block)
        return;
    MusicTrack track = ((FinchMusicTrackState *)_impl)->track;
    MusicEventIterator iterator = NULL;
    if (!track || NewMusicEventIterator(track, &iterator) != noErr)
        return;
    MusicTimeStamp end = range.length == AVMusicTimeStampEndOfTrack ? kMusicTimeStamp_EndOfTrack : range.start + range.length;
    MusicEventIteratorSeek(iterator, range.start);
    Boolean has = false;
    MusicEventIteratorHasCurrentEvent(iterator, &has);
    while (has) {
        MusicTimeStamp time = 0;
        MusicEventType type = 0;
        const void *data = NULL;
        UInt32 size = 0;
        if (MusicEventIteratorGetEventInfo(iterator, &time, &type, &data, &size) != noErr || time > end)
            break;
        AVMusicEvent *event = event_from_music_data(type, data);
        AVMusicTimeStamp newTime = time;
        BOOL remove = NO;
        if (event)
            block(event, &newTime, &remove);
        if (remove) {
            MusicEventIteratorDeleteEvent(iterator);
        } else {
            if (event) {
                MusicSequence sequence = NULL;
                MusicTrackGetSequence(track, &sequence);
                MusicTrack tempo = NULL;
                if (sequence) MusicSequenceGetTempoTrack(sequence, &tempo);
                BOOL automated = self.usesAutomatedParameters;
                MusicEventType originalType = type;
                if ([event isKindOfClass:[AVMIDINoteEvent class]]) originalType = kMusicEventType_MIDINoteMessage;
                else if ([event isKindOfClass:[AVExtendedTempoEvent class]]) originalType = kMusicEventType_ExtendedTempo;
                else if ([event isKindOfClass:[AVParameterEvent class]]) originalType = kMusicEventType_Parameter;
                if (newTime != time)
                    MusicEventIteratorSetEventTime(iterator, newTime);
                if (originalType == type) {
                    /* Replacing an event uses the same copy path as an insertion. */
                    MusicEventType replacement = 0;
                    void *payload = NULL;
                    MIDINoteMessage note = {0};
                    MIDIChannelMessage message = {0};
                    ExtendedTempoEvent tempoValue = {0};
                    ParameterEvent parameter = {0};
                    if ([event isKindOfClass:[AVMIDINoteEvent class]]) {
                        AVMIDINoteEvent *v = (AVMIDINoteEvent *)event;
                        note = (MIDINoteMessage){(UInt8)v.channel,(UInt8)v.key,(UInt8)v.velocity,0,(Float32)v.duration};
                        replacement = kMusicEventType_MIDINoteMessage; payload = &note;
                    } else if ([event isKindOfClass:[AVMIDIControlChangeEvent class]]) {
                        AVMIDIControlChangeEvent *v = (AVMIDIControlChangeEvent *)event;
                        message = (MIDIChannelMessage){(UInt8)(0xb0 | (v.channel & 15)),(UInt8)v.messageType,(UInt8)v.value,0};
                        replacement = kMusicEventType_MIDIChannelMessage; payload = &message;
                    } else if ([event isKindOfClass:[AVMIDIPolyPressureEvent class]]) {
                        AVMIDIPolyPressureEvent *v = (AVMIDIPolyPressureEvent *)event;
                        message = (MIDIChannelMessage){(UInt8)(0xa0 | (v.channel & 15)),(UInt8)v.key,(UInt8)v.pressure,0};
                        replacement = kMusicEventType_MIDIChannelMessage; payload = &message;
                    } else if ([event isKindOfClass:[AVMIDIProgramChangeEvent class]]) {
                        AVMIDIProgramChangeEvent *v = (AVMIDIProgramChangeEvent *)event;
                        message = (MIDIChannelMessage){(UInt8)(0xc0 | (v.channel & 15)),(UInt8)v.programNumber,0,0};
                        replacement = kMusicEventType_MIDIChannelMessage; payload = &message;
                    } else if ([event isKindOfClass:[AVMIDIChannelPressureEvent class]]) {
                        AVMIDIChannelPressureEvent *v = (AVMIDIChannelPressureEvent *)event;
                        message = (MIDIChannelMessage){(UInt8)(0xd0 | (v.channel & 15)),(UInt8)v.pressure,0,0};
                        replacement = kMusicEventType_MIDIChannelMessage; payload = &message;
                    } else if ([event isKindOfClass:[AVMIDIPitchBendEvent class]]) {
                        AVMIDIPitchBendEvent *v = (AVMIDIPitchBendEvent *)event;
                        message = (MIDIChannelMessage){(UInt8)(0xe0 | (v.channel & 15)),(UInt8)(v.value & 127),(UInt8)((v.value >> 7) & 127),0};
                        replacement = kMusicEventType_MIDIChannelMessage; payload = &message;
                    } else if ([event isKindOfClass:[AVExtendedTempoEvent class]] && track == tempo) {
                        tempoValue.bpm = ((AVExtendedTempoEvent *)event).tempo;
                        replacement = kMusicEventType_ExtendedTempo; payload = &tempoValue;
                    } else if ([event isKindOfClass:[AVParameterEvent class]] && automated) {
                        AVParameterEvent *v = (AVParameterEvent *)event;
                        parameter = (ParameterEvent){v.parameterID,v.scope,v.element,v.value};
                        replacement = kMusicEventType_Parameter; payload = &parameter;
                    }
                    if (payload && replacement == type)
                        MusicEventIteratorSetEventInfo(iterator, replacement, payload);
                }
            }
            MusicEventIteratorNextEvent(iterator);
        }
        MusicEventIteratorHasCurrentEvent(iterator, &has);
    }
    DisposeMusicEventIterator(iterator);
}

@end
