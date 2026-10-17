/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <AudioToolbox/AudioToolbox.h>
#include <CoreServices/CoreServices.h>
#include <errno.h>
#include <math.h>
#include <mach/mach_time.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

enum { kFinchMemoryFullError = -108 };

static UInt32 read_be32(const UInt8 *bytes);

typedef struct MusicEventStorage {
    MusicTimeStamp time;
    MusicEventType type;
    UInt32 size;
    void *data;
} MusicEventStorage;

struct OpaqueMusicTrack {
    MusicSequence sequence;
    CFStringRef name;
    MusicEventStorage **events;
    size_t count;
    size_t capacity;
    MusicTimeStamp length;
    MusicTrackLoopInfo loop;
    MusicTimeStamp offset;
    Boolean mute;
    Boolean solo;
    UInt32 automated;
    Boolean hasLength;
    Boolean isTempo;
    Boolean isMIDI;
    AUNode destination;
    MIDIEndpointRef endpoint;
};

struct OpaqueMusicSequence {
    MusicTrack *tracks;
    size_t count;
    size_t capacity;
    MusicTrack *derivedTracks;
    size_t derivedCount;
    size_t derivedCapacity;
    MusicTrack tempoTrack;
    MusicSequenceType type;
    UInt32 timeResolution;
    AUGraph graph;
    MusicSequenceUserCallback callback;
    void *clientData;
    size_t players;
};

struct OpaqueMusicEventIterator {
    MusicTrack track;
    size_t index;
};

struct OpaqueMusicPlayer {
    MusicSequence sequence;
    MusicTimeStamp startBeat;
    Float64 playRate;
    UInt64 startHostTime;
    Boolean playing;
    Boolean prerolled;
};

static OSStatus
validate_time(MusicTimeStamp time)
{
    return isfinite(time) && time >= 0 ? noErr : kAudio_ParamError;
}

static MusicTrack
new_track(MusicSequence sequence, Boolean tempo)
{
    MusicTrack track = calloc(1, sizeof(*track));
    if (!track)
        return NULL;
    track->sequence = sequence;
    track->isTempo = tempo;
    track->loop.numberOfLoops = 0;
    return track;
}

static void
free_event(MusicEventStorage *event)
{
    if (event->type == kMusicEventType_AUPreset && event->data) {
        AUPresetEvent *preset = event->data;
        if (preset->preset)
            CFRelease(preset->preset);
    }
    free(event->data);
    free(event);
}

static void
free_track(MusicTrack track)
{
    if (!track)
        return;
    for (size_t i = 0; i < track->count; i++)
        free_event(track->events[i]);
    free(track->events);
    if (track->name)
        CFRelease(track->name);
    free(track);
}

static MusicTimeStamp
event_end_time(const MusicEventStorage *event)
{
    MusicTimeStamp end = event->time;
    if (event->type == kMusicEventType_MIDINoteMessage)
        end += ((const MIDINoteMessage *)event->data)->duration;
    else if (event->type == kMusicEventType_ExtendedNote)
        end += ((const ExtendedNoteOnEvent *)event->data)->duration;
    return end;
}

static UInt32
event_size(MusicEventType type, const void *data)
{
    if (!data)
        return 0;
    switch (type) {
    case kMusicEventType_ExtendedNote: return sizeof(ExtendedNoteOnEvent);
    case kMusicEventType_ExtendedControl: return sizeof(ExtendedControlEvent);
    case kMusicEventType_ExtendedTempo: return sizeof(ExtendedTempoEvent);
    case kMusicEventType_User:
        return ((const MusicEventUserData *)data)->length + offsetof(MusicEventUserData, data);
    case kMusicEventType_Meta:
        return ((const MIDIMetaEvent *)data)->dataLength + offsetof(MIDIMetaEvent, data);
    case kMusicEventType_MIDINoteMessage: return sizeof(MIDINoteMessage);
    case kMusicEventType_MIDIChannelMessage: return sizeof(MIDIChannelMessage);
    case kMusicEventType_MIDIRawData:
        return ((const MIDIRawData *)data)->length + offsetof(MIDIRawData, data);
    case kMusicEventType_Parameter: return sizeof(ParameterEvent);
    case kMusicEventType_AUPreset: return sizeof(AUPresetEvent);
    default: return 0;
    }
}

static MusicEventStorage *
copy_event(MusicTimeStamp time, MusicEventType type, const void *data)
{
    UInt32 size = event_size(type, data);
    if (!size || size > 16 * 1024 * 1024)
        return NULL;
    MusicEventStorage *event = calloc(1, sizeof(*event));
    if (!event)
        return NULL;
    event->data = malloc(size);
    if (!event->data) {
        free(event);
        return NULL;
    }
    memcpy(event->data, data, size);
    event->time = time;
    event->type = type;
    event->size = size;
    if (type == kMusicEventType_AUPreset) {
        AUPresetEvent *preset = event->data;
        if (preset->preset)
            CFRetain(preset->preset);
    }
    return event;
}

static OSStatus
insert_event(MusicTrack track, MusicEventStorage *event)
{
    if (track->count == track->capacity) {
        size_t capacity = track->capacity ? track->capacity * 2 : 8;
        MusicEventStorage **events = realloc(track->events, capacity * sizeof(*events));
        if (!events)
            return kFinchMemoryFullError;
        track->events = events;
        track->capacity = capacity;
    }
    size_t index = 0;
    while (index < track->count && track->events[index]->time <= event->time)
        index++;
    memmove(&track->events[index + 1], &track->events[index], (track->count - index) * sizeof(*track->events));
    track->events[index] = event;
    track->count++;
    if (event_end_time(event) > track->length)
        track->length = event_end_time(event);
    return noErr;
}

static OSStatus
add_event(MusicTrack track, MusicTimeStamp time, MusicEventType type, const void *data)
{
    if (!track || !data || validate_time(time) != noErr)
        return kAudio_ParamError;
    MusicEventStorage *event = copy_event(time, type, data);
    if (!event)
        return kAudio_ParamError;
    OSStatus status = insert_event(track, event);
    if (status != noErr)
        free_event(event);
    return status;
}

static void
remove_event_at(MusicTrack track, size_t index)
{
    free_event(track->events[index]);
    memmove(&track->events[index], &track->events[index + 1], (track->count - index - 1) * sizeof(*track->events));
    track->count--;
    track->length = 0;
    for (size_t i = 0; i < track->count; i++)
        if (event_end_time(track->events[i]) > track->length)
            track->length = event_end_time(track->events[i]);
}

static OSStatus
append_track(MusicSequence sequence, MusicTrack track)
{
    if (sequence->count == sequence->capacity) {
        size_t capacity = sequence->capacity ? sequence->capacity * 2 : 4;
        MusicTrack *tracks = realloc(sequence->tracks, capacity * sizeof(*tracks));
        if (!tracks)
            return kFinchMemoryFullError;
        sequence->tracks = tracks;
        sequence->capacity = capacity;
    }
    sequence->tracks[sequence->count++] = track;
    return noErr;
}

OSStatus
NewMusicSequence(MusicSequence *outSequence)
{
    if (!outSequence)
        return kAudio_ParamError;
    *outSequence = NULL;
    MusicSequence sequence = calloc(1, sizeof(*sequence));
    if (!sequence)
        return kFinchMemoryFullError;
    sequence->type = kMusicSequenceType_Beats;
    sequence->timeResolution = 480;
    sequence->tempoTrack = new_track(sequence, true);
    if (!sequence->tempoTrack) {
        free(sequence);
        return kFinchMemoryFullError;
    }
    *outSequence = sequence;
    return noErr;
}

OSStatus
DisposeMusicSequence(MusicSequence sequence)
{
    if (!sequence)
        return kAudio_ParamError;
    if (sequence->players)
        return kAudioToolboxErr_CannotDoInCurrentContext;
    for (size_t i = 0; i < sequence->count; i++)
        free_track(sequence->tracks[i]);
    free(sequence->tracks);
    for (size_t i = 0; i < sequence->derivedCount; i++)
        free_track(sequence->derivedTracks[i]);
    free(sequence->derivedTracks);
    free_track(sequence->tempoTrack);
    free(sequence);
    return noErr;
}

OSStatus
MusicSequenceNewTrack(MusicSequence sequence, MusicTrack *outTrack)
{
    if (!sequence || !outTrack)
        return kAudio_ParamError;
    *outTrack = NULL;
    MusicTrack track = new_track(sequence, false);
    if (!track)
        return kFinchMemoryFullError;
    track->name = CFStringCreateWithFormat(NULL, NULL, CFSTR("Track %lu"),
        (unsigned long)(sequence->count + 1));
    OSStatus status = append_track(sequence, track);
    if (status != noErr) {
        free_track(track);
        return status;
    }
    *outTrack = track;
    return noErr;
}

OSStatus
MusicSequenceDisposeTrack(MusicSequence sequence, MusicTrack track)
{
    if (!sequence || !track || track->sequence != sequence || track->isTempo)
        return kAudio_ParamError;
    size_t index = 0;
    while (index < sequence->count && sequence->tracks[index] != track)
        index++;
    if (index == sequence->count)
    {
        size_t derived = 0;
        while (derived < sequence->derivedCount && sequence->derivedTracks[derived] != track)
            derived++;
        if (derived == sequence->derivedCount)
            return kAudio_ParamError;
        memmove(&sequence->derivedTracks[derived], &sequence->derivedTracks[derived + 1],
            (sequence->derivedCount - derived - 1) * sizeof(*sequence->derivedTracks));
        sequence->derivedCount--;
        free_track(track);
        return noErr;
    }
    memmove(&sequence->tracks[index], &sequence->tracks[index + 1], (sequence->count - index - 1) * sizeof(*sequence->tracks));
    sequence->count--;
    free_track(track);
    return noErr;
}

OSStatus
MusicSequenceGetTrackCount(MusicSequence sequence, UInt32 *count)
{
    if (!sequence || !count)
        return kAudio_ParamError;
    *count = (UInt32)sequence->count;
    return noErr;
}

OSStatus
MusicSequenceGetIndTrack(MusicSequence sequence, UInt32 index, MusicTrack *outTrack)
{
    if (!sequence || !outTrack)
        return kAudio_ParamError;
    *outTrack = NULL;
    if (index >= sequence->count)
        return kAudioToolboxErr_TrackIndexError;
    *outTrack = sequence->tracks[index];
    return noErr;
}

OSStatus
MusicSequenceGetTrackIndex(MusicSequence sequence, MusicTrack track, UInt32 *outIndex)
{
    if (!sequence || !track || !outIndex)
        return kAudio_ParamError;
    for (size_t i = 0; i < sequence->count; i++) {
        if (sequence->tracks[i] == track) {
            *outIndex = (UInt32)i;
            return noErr;
        }
    }
    return kAudioToolboxErr_TrackNotFound;
}

OSStatus
MusicSequenceGetTempoTrack(MusicSequence sequence, MusicTrack *outTrack)
{
    if (!sequence || !outTrack)
        return kAudio_ParamError;
    *outTrack = sequence->tempoTrack;
    return noErr;
}

OSStatus
MusicSequenceSetAUGraph(MusicSequence sequence, AUGraph graph)
{
    if (!sequence)
        return kAudio_ParamError;
    sequence->graph = graph;
    return noErr;
}

OSStatus
MusicSequenceGetAUGraph(MusicSequence sequence, AUGraph *outGraph)
{
    if (!sequence || !outGraph)
        return kAudio_ParamError;
    *outGraph = sequence->graph;
    return noErr;
}

OSStatus
MusicSequenceSetMIDIEndpoint(MusicSequence sequence, MIDIEndpointRef endpoint)
{
    if (!sequence)
        return kAudio_ParamError;
    for (size_t i = 0; i < sequence->count; i++) {
        sequence->tracks[i]->isMIDI = true;
        sequence->tracks[i]->endpoint = endpoint;
    }
    return noErr;
}

OSStatus
MusicSequenceSetSequenceType(MusicSequence sequence, MusicSequenceType type)
{
    if (!sequence)
        return kAudio_ParamError;
    if (type != kMusicSequenceType_Beats && type != kMusicSequenceType_Seconds && type != kMusicSequenceType_Samples)
        return kAudioToolboxErr_InvalidSequenceType;
    if (type != kMusicSequenceType_Beats)
        for (size_t i = 0; i < sequence->tempoTrack->count; i++)
            if (sequence->tempoTrack->events[i]->type == kMusicEventType_ExtendedTempo)
                return kAudio_ParamError;
    sequence->type = type;
    return noErr;
}

OSStatus
MusicSequenceGetSequenceType(MusicSequence sequence, MusicSequenceType *outType)
{
    if (!sequence || !outType)
        return kAudio_ParamError;
    *outType = sequence->type;
    return noErr;
}

OSStatus
MusicSequenceSetUserCallback(MusicSequence sequence, MusicSequenceUserCallback callback, void *clientData)
{
    if (!sequence)
        return kAudio_ParamError;
    sequence->callback = callback;
    sequence->clientData = clientData;
    return noErr;
}

CFDictionaryRef
MusicSequenceGetInfoDictionary(MusicSequence sequence)
{
    if (!sequence)
        return CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFMutableDictionaryRef info = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!info)
        return CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    ExtendedTempoEvent *tempo = NULL;
    MIDIMetaEvent *signature = NULL;
    for (size_t i = 0; i < sequence->tempoTrack->count; i++) {
        MusicEventStorage *event = sequence->tempoTrack->events[i];
        if (event->type == kMusicEventType_ExtendedTempo && !tempo)
            tempo = event->data;
        if (event->type == kMusicEventType_Meta) {
            MIDIMetaEvent *meta = event->data;
            if (meta->metaEventType == 0x58 && meta->dataLength >= 2 && !signature)
                signature = meta;
        }
    }
    if (tempo) {
        CFNumberRef number = CFNumberCreate(NULL, kCFNumberFloat64Type, &tempo->bpm);
        if (number) {
            CFDictionarySetValue(info, CFSTR("tempo"), number);
            CFRelease(number);
        }
    }
    UInt32 numerator = signature && signature->data[0] ? signature->data[0] : 4;
    UInt32 denominator = signature ? 1u << (signature->data[1] > 6 ? 6 : signature->data[1]) : 4;
    CFStringRef signatureText = CFStringCreateWithFormat(NULL, NULL, CFSTR("%u/%u"), numerator, denominator);
    if (signatureText) {
        CFDictionarySetValue(info, CFSTR("time signature"), signatureText);
        CFRelease(signatureText);
    }
    return info;
}

OSStatus
MusicTrackGetSequence(MusicTrack track, MusicSequence *outSequence)
{
    if (!track || !outSequence)
        return kAudio_ParamError;
    *outSequence = track->sequence;
    return noErr;
}

OSStatus
MusicTrackSetDestNode(MusicTrack track, AUNode node)
{
    if (!track)
        return kAudio_ParamError;
    track->isMIDI = false;
    track->destination = node;
    track->endpoint = 0;
    return noErr;
}

OSStatus
MusicTrackGetDestNode(MusicTrack track, AUNode *outNode)
{
    if (!track || !outNode)
        return kAudio_ParamError;
    if (track->isMIDI)
        return kAudioToolboxErr_IllegalTrackDestination;
    *outNode = track->destination;
    return noErr;
}

OSStatus
MusicTrackSetDestMIDIEndpoint(MusicTrack track, MIDIEndpointRef endpoint)
{
    if (!track)
        return kAudio_ParamError;
    track->isMIDI = true;
    track->endpoint = endpoint;
    return noErr;
}

OSStatus
MusicTrackGetDestMIDIEndpoint(MusicTrack track, MIDIEndpointRef *outEndpoint)
{
    if (!track || !outEndpoint)
        return kAudio_ParamError;
    if (!track->isMIDI)
        return kAudioToolboxErr_IllegalTrackDestination;
    *outEndpoint = track->endpoint;
    return noErr;
}

static Boolean
track_property(MusicTrack track, UInt32 property, void *data)
{
    switch (property) {
    case kSequenceTrackProperty_LoopInfo: *(MusicTrackLoopInfo *)data = track->loop; return true;
    case kSequenceTrackProperty_OffsetTime: *(MusicTimeStamp *)data = track->offset; return true;
    case kSequenceTrackProperty_MuteStatus: *(Boolean *)data = track->mute; return true;
    case kSequenceTrackProperty_SoloStatus: *(Boolean *)data = track->solo; return true;
    case kSequenceTrackProperty_AutomatedParameters: *(UInt32 *)data = track->automated; return true;
    case kSequenceTrackProperty_TrackLength: {
        MusicTimeStamp length = 0;
        for (size_t i = 0; i < track->count; i++)
            if (event_end_time(track->events[i]) > length)
                length = event_end_time(track->events[i]);
        *(MusicTimeStamp *)data = track->hasLength && track->length > length ? track->length : length;
        return true;
    }
    case kSequenceTrackProperty_TimeResolution:
        if (!track->isTempo) return false;
        *(SInt16 *)data = (SInt16)track->sequence->timeResolution;
        return true;
    default: return false;
    }
}

static UInt32
track_property_size(MusicTrack track, UInt32 property)
{
    switch (property) {
    case kSequenceTrackProperty_LoopInfo: return sizeof(MusicTrackLoopInfo);
    case kSequenceTrackProperty_OffsetTime:
    case kSequenceTrackProperty_TrackLength: return sizeof(MusicTimeStamp);
    case kSequenceTrackProperty_MuteStatus:
    case kSequenceTrackProperty_SoloStatus: return sizeof(Boolean);
    case kSequenceTrackProperty_AutomatedParameters: return sizeof(UInt32);
    case kSequenceTrackProperty_TimeResolution: return track->isTempo ? sizeof(SInt16) : 0;
    default: return 0;
    }
}

OSStatus
MusicTrackGetProperty(MusicTrack track, UInt32 property, void *outData, UInt32 *ioLength)
{
    if (!track || !ioLength)
        return kAudio_ParamError;
    UInt32 size = track_property_size(track, property);
    if (!size)
        return kAudio_ParamError;
    if (!outData) {
        *ioLength = size;
        return noErr;
    }
    if (*ioLength < size) {
        *ioLength = size;
        return kAudio_ParamError;
    }
    if (!track_property(track, property, outData))
        return kAudio_ParamError;
    *ioLength = size;
    return noErr;
}

OSStatus
MusicTrackSetProperty(MusicTrack track, UInt32 property, void *data, UInt32 length)
{
    if (!track || !data || length != track_property_size(track, property))
        return kAudio_ParamError;
    switch (property) {
    case kSequenceTrackProperty_LoopInfo: track->loop = *(MusicTrackLoopInfo *)data; break;
    case kSequenceTrackProperty_OffsetTime: track->offset = *(MusicTimeStamp *)data; break;
    case kSequenceTrackProperty_MuteStatus: track->mute = *(Boolean *)data; break;
    case kSequenceTrackProperty_SoloStatus: track->solo = *(Boolean *)data; break;
    case kSequenceTrackProperty_AutomatedParameters: track->automated = *(UInt32 *)data; break;
    case kSequenceTrackProperty_TrackLength: track->length = *(MusicTimeStamp *)data; track->hasLength = true; break;
    default: return kAudio_ParamError;
    }
    return noErr;
}

OSStatus
MusicTrackMoveEvents(MusicTrack track, MusicTimeStamp start, MusicTimeStamp end, MusicTimeStamp delta)
{
    if (!track || validate_time(start) != noErr || !isfinite(end) || end < start || !isfinite(delta))
        return kAudio_ParamError;
    for (size_t i = 0; i < track->count; i++) {
        MusicTimeStamp time = track->events[i]->time;
        if (time >= start && time < end && time + delta < 0)
            return kAudio_ParamError;
    }
    for (size_t i = 0; i < track->count; i++) {
        MusicTimeStamp time = track->events[i]->time;
        if (time >= start && time < end)
            track->events[i]->time += delta;
    }
    for (size_t i = 1; i < track->count; i++) {
        MusicEventStorage *value = track->events[i];
        size_t j = i;
        while (j && track->events[j - 1]->time > value->time) {
            track->events[j] = track->events[j - 1];
            j--;
        }
        track->events[j] = value;
    }
    return noErr;
}

OSStatus
MusicTrackClear(MusicTrack track, MusicTimeStamp start, MusicTimeStamp end)
{
    if (!track || validate_time(start) != noErr || (!isfinite(end) && end != kMusicTimeStamp_EndOfTrack) || end < start)
        return kAudio_ParamError;
    for (size_t i = 0; i < track->count;) {
        if (track->events[i]->time >= start && track->events[i]->time < end)
            remove_event_at(track, i);
        else
            i++;
    }
    return noErr;
}

OSStatus
MusicTrackCut(MusicTrack track, MusicTimeStamp start, MusicTimeStamp end)
{
    if (!track || validate_time(start) != noErr || !isfinite(end) || end < start)
        return kAudio_ParamError;
    MusicTimeStamp duration = end - start;
    for (size_t i = 0; i < track->count;) {
        if (track->events[i]->time >= start && track->events[i]->time < end)
            remove_event_at(track, i);
        else {
            if (track->events[i]->time >= end)
                track->events[i]->time -= duration;
            i++;
        }
    }
    return noErr;
}

static OSStatus
copy_range(MusicTrack source, MusicTimeStamp start, MusicTimeStamp end, MusicTrack dest, MusicTimeStamp insert, Boolean shift)
{
    if (!source || !dest || validate_time(start) != noErr || !isfinite(end) || end < start || validate_time(insert) != noErr)
        return kAudio_ParamError;
    MusicEventStorage **copies = calloc(source->count ? source->count : 1, sizeof(*copies));
    if (!copies)
        return kFinchMemoryFullError;
    size_t count = 0;
    for (size_t i = 0; i < source->count; i++) {
        MusicEventStorage *event = source->events[i];
        if (event->time >= start && event->time < end) {
            copies[count] = copy_event(insert + event->time - start, event->type, event->data);
            if (!copies[count]) {
                while (count) free_event(copies[--count]);
                free(copies);
                return kFinchMemoryFullError;
            }
            count++;
        }
    }
    MusicTimeStamp duration = end - start;
    if (shift)
        for (size_t i = 0; i < dest->count; i++)
            if (dest->events[i]->time >= insert)
                dest->events[i]->time += duration;
    for (size_t i = 0; i < count; i++) {
        OSStatus status = insert_event(dest, copies[i]);
        if (status != noErr) {
            free_event(copies[i]);
            for (size_t j = i + 1; j < count; j++) free_event(copies[j]);
            free(copies);
            return status;
        }
    }
    free(copies);
    return noErr;
}

OSStatus
MusicTrackCopyInsert(MusicTrack source, MusicTimeStamp start, MusicTimeStamp end, MusicTrack dest, MusicTimeStamp insert)
{
    return copy_range(source, start, end, dest, insert, true);
}

OSStatus
MusicTrackMerge(MusicTrack source, MusicTimeStamp start, MusicTimeStamp end, MusicTrack dest, MusicTimeStamp insert)
{
    return copy_range(source, start, end, dest, insert, false);
}

OSStatus MusicTrackNewMIDINoteEvent(MusicTrack t, MusicTimeStamp x, const MIDINoteMessage *d) { return add_event(t, x, kMusicEventType_MIDINoteMessage, d); }
OSStatus MusicTrackNewMIDIChannelEvent(MusicTrack t, MusicTimeStamp x, const MIDIChannelMessage *d) { return add_event(t, x, kMusicEventType_MIDIChannelMessage, d); }
OSStatus MusicTrackNewExtendedControlEvent(MusicTrack t, MusicTimeStamp x, const ExtendedControlEvent *d) { return add_event(t, x, kMusicEventType_ExtendedControl, d); }
OSStatus MusicTrackNewExtendedNoteEvent(MusicTrack t, MusicTimeStamp x, const ExtendedNoteOnEvent *d) { return add_event(t, x, kMusicEventType_ExtendedNote, d); }
OSStatus MusicTrackNewParameterEvent(MusicTrack t, MusicTimeStamp x, const ParameterEvent *d) { return add_event(t, x, kMusicEventType_Parameter, d); }
OSStatus MusicTrackNewExtendedTempoEvent(MusicTrack t, MusicTimeStamp x, Float64 bpm) { ExtendedTempoEvent d = { .bpm = bpm }; return add_event(t, x, kMusicEventType_ExtendedTempo, &d); }
OSStatus MusicTrackNewAUPresetEvent(MusicTrack t, MusicTimeStamp x, const AUPresetEvent *d) { return add_event(t, x, kMusicEventType_AUPreset, d); }
OSStatus MusicTrackNewMIDIRawDataEvent(MusicTrack t, MusicTimeStamp x, const MIDIRawData *d) { return add_event(t, x, kMusicEventType_MIDIRawData, d); }
OSStatus MusicTrackNewMetaEvent(MusicTrack t, MusicTimeStamp x, const MIDIMetaEvent *d) { return add_event(t, x, kMusicEventType_Meta, d); }
OSStatus MusicTrackNewUserEvent(MusicTrack t, MusicTimeStamp x, const MusicEventUserData *d) { return add_event(t, x, kMusicEventType_User, d); }

OSStatus
NewMusicEventIterator(MusicTrack track, MusicEventIterator *outIterator)
{
    if (!track || !outIterator)
        return kAudio_ParamError;
    MusicEventIterator iterator = calloc(1, sizeof(*iterator));
    if (!iterator)
        return kFinchMemoryFullError;
    iterator->track = track;
    *outIterator = iterator;
    return noErr;
}

OSStatus DisposeMusicEventIterator(MusicEventIterator iterator) { if (!iterator) return kAudio_ParamError; free(iterator); return noErr; }

OSStatus
MusicEventIteratorSeek(MusicEventIterator iterator, MusicTimeStamp time)
{
    if (!iterator || !iterator->track || (validate_time(time) != noErr && time != kMusicTimeStamp_EndOfTrack))
        return kAudio_ParamError;
    size_t index = 0;
    if (time == kMusicTimeStamp_EndOfTrack)
        index = iterator->track->count;
    else
        while (index < iterator->track->count && iterator->track->events[index]->time < time) index++;
    iterator->index = index;
    return noErr;
}

OSStatus
MusicEventIteratorNextEvent(MusicEventIterator iterator)
{
    if (!iterator || !iterator->track)
        return kAudio_ParamError;
    if (iterator->index >= iterator->track->count)
        return kAudioToolboxErr_EndOfTrack;
    iterator->index++;
    return noErr;
}

OSStatus
MusicEventIteratorPreviousEvent(MusicEventIterator iterator)
{
    if (!iterator || !iterator->track)
        return kAudio_ParamError;
    if (!iterator->index)
        return kAudioToolboxErr_StartOfTrack;
    iterator->index--;
    return noErr;
}

OSStatus
MusicEventIteratorGetEventInfo(MusicEventIterator iterator, MusicTimeStamp *time, MusicEventType *type, const void **data, UInt32 *size)
{
    if (!iterator || !iterator->track || iterator->index >= iterator->track->count)
        return kAudioToolboxErr_EndOfTrack;
    MusicEventStorage *event = iterator->track->events[iterator->index];
    if (time) *time = event->time;
    if (type) *type = event->type;
    if (data) *data = event->data;
    if (size) *size = event->size;
    return noErr;
}

OSStatus
MusicEventIteratorSetEventInfo(MusicEventIterator iterator, MusicEventType type, const void *data)
{
    if (!iterator || !iterator->track || iterator->index >= iterator->track->count || !data)
        return kAudio_ParamError;
    MusicEventStorage *event = copy_event(iterator->track->events[iterator->index]->time, type, data);
    if (!event)
        return kAudioToolboxErr_InvalidEventType;
    free_event(iterator->track->events[iterator->index]);
    iterator->track->events[iterator->index] = event;
    return noErr;
}

OSStatus
MusicEventIteratorSetEventTime(MusicEventIterator iterator, MusicTimeStamp time)
{
    if (!iterator || !iterator->track || iterator->index >= iterator->track->count || validate_time(time) != noErr)
        return kAudio_ParamError;
    MusicTrack track = iterator->track;
    MusicEventStorage *event = track->events[iterator->index];
    memmove(&track->events[iterator->index], &track->events[iterator->index + 1], (track->count - iterator->index - 1) * sizeof(*track->events));
    track->count--;
    event->time = time;
    OSStatus status = insert_event(track, event);
    if (status != noErr)
        return status;
    for (iterator->index = 0; iterator->index < track->count && track->events[iterator->index] != event; iterator->index++) {}
    return noErr;
}

OSStatus
MusicEventIteratorDeleteEvent(MusicEventIterator iterator)
{
    if (!iterator || !iterator->track)
        return kAudio_ParamError;
    if (iterator->index >= iterator->track->count)
        return kAudioToolboxErr_EndOfTrack;
    remove_event_at(iterator->track, iterator->index);
    return noErr;
}

OSStatus
MusicEventIteratorHasPreviousEvent(MusicEventIterator iterator, Boolean *outHas)
{
    if (!iterator || !iterator->track || !outHas)
        return kAudio_ParamError;
    *outHas = iterator->index > 0;
    return noErr;
}

OSStatus
MusicEventIteratorHasNextEvent(MusicEventIterator iterator, Boolean *outHas)
{
    if (!iterator || !iterator->track || !outHas)
        return kAudio_ParamError;
    *outHas = iterator->index + 1 < iterator->track->count;
    return noErr;
}

OSStatus
MusicEventIteratorHasCurrentEvent(MusicEventIterator iterator, Boolean *outHas)
{
    if (!iterator || !iterator->track || !outHas)
        return kAudio_ParamError;
    *outHas = iterator->index < iterator->track->count;
    return noErr;
}

static Float64
seconds_for_beats(MusicSequence sequence, MusicTimeStamp beats)
{
    if (beats < 0)
        return beats * 0.5;
    Float64 seconds = 0, start = 0, bpm = 120.0;
    for (size_t i = 0; i < sequence->tempoTrack->count; i++) {
        MusicEventStorage *event = sequence->tempoTrack->events[i];
        if (event->type != kMusicEventType_ExtendedTempo || event->time > beats)
            continue;
        Float64 next = ((ExtendedTempoEvent *)event->data)->bpm;
        if (next <= 0 || !isfinite(next)) continue;
        seconds += (event->time - start) * 60.0 / bpm;
        start = event->time;
        bpm = next;
    }
    return seconds + (beats - start) * 60.0 / bpm;
}

OSStatus
MusicSequenceGetSecondsForBeats(MusicSequence sequence, MusicTimeStamp beats, Float64 *outSeconds)
{
    if (!sequence || !outSeconds || !isfinite(beats))
        return kAudio_ParamError;
    *outSeconds = seconds_for_beats(sequence, beats);
    return noErr;
}

OSStatus
MusicSequenceGetBeatsForSeconds(MusicSequence sequence, Float64 seconds, MusicTimeStamp *outBeats)
{
    if (!sequence || !outBeats || !isfinite(seconds))
        return kAudio_ParamError;
    if (seconds < 0) {
        *outBeats = seconds * 2.0;
        return noErr;
    }
    Float64 elapsed = 0, beat = 0, bpm = 120.0;
    for (size_t i = 0; i < sequence->tempoTrack->count; i++) {
        MusicEventStorage *event = sequence->tempoTrack->events[i];
        if (event->type != kMusicEventType_ExtendedTempo) continue;
        Float64 next = ((ExtendedTempoEvent *)event->data)->bpm;
        if (next <= 0 || !isfinite(next)) continue;
        Float64 until = (event->time - beat) * 60.0 / bpm;
        if (elapsed + until > seconds) break;
        elapsed += until;
        beat = event->time;
        bpm = next;
    }
    *outBeats = beat + (seconds - elapsed) * bpm / 60.0;
    return noErr;
}

static void
meter_at(MusicSequence sequence, MusicTimeStamp beat, UInt32 *numerator, UInt32 *denominator)
{
    *numerator = 4;
    *denominator = 4;
    for (size_t i = 0; i < sequence->tempoTrack->count; i++) {
        MusicEventStorage *event = sequence->tempoTrack->events[i];
        if (event->type != kMusicEventType_Meta || event->time > beat)
            continue;
        MIDIMetaEvent *meta = event->data;
        if (meta->metaEventType == 0x58 && meta->dataLength >= 2) {
            *numerator = meta->data[0] ? meta->data[0] : 4;
            *denominator = 1u << (meta->data[1] > 6 ? 6 : meta->data[1]);
        }
    }
}

OSStatus
MusicSequenceBeatsToBarBeatTime(MusicSequence sequence, MusicTimeStamp beats, UInt32 divisor, CABarBeatTime *outTime)
{
    if (!sequence || !outTime || !divisor || !isfinite(beats) || beats < 0)
        return kAudio_ParamError;
    UInt32 numerator, denominator;
    meter_at(sequence, beats, &numerator, &denominator);
    Float64 beatUnit = 4.0 / denominator;
    Float64 barLength = numerator * beatUnit;
    Float64 bars = floor(beats / barLength);
    Float64 intoBar = beats - bars * barLength;
    UInt32 beat = (UInt32)floor(intoBar / beatUnit);
    Float64 fraction = intoBar / beatUnit - beat;
    UInt32 subbeat = (UInt32)llround(fraction * divisor);
    if (subbeat >= divisor) { beat++; subbeat = 0; }
    if (beat >= numerator) { bars++; beat = 0; }
    outTime->bar = (SInt32)bars + 1;
    outTime->beat = (UInt16)beat + 1;
    outTime->subbeat = (UInt16)subbeat;
    outTime->subbeatDivisor = (UInt16)divisor;
    outTime->reserved = 0;
    return noErr;
}

OSStatus
MusicSequenceBarBeatTimeToBeats(MusicSequence sequence, const CABarBeatTime *time, MusicTimeStamp *outBeats)
{
    if (!sequence || !time || !outBeats || time->bar < 1 || time->beat < 1 || !time->subbeatDivisor)
        return kAudio_ParamError;
    UInt32 numerator, denominator;
    meter_at(sequence, 0, &numerator, &denominator);
    Float64 beatUnit = 4.0 / denominator;
    *outBeats = ((Float64)(time->bar - 1) * numerator + time->beat - 1 + (Float64)time->subbeat / time->subbeatDivisor) * beatUnit;
    return noErr;
}

OSStatus
MusicSequenceReverse(MusicSequence sequence)
{
    if (!sequence)
        return kAudio_ParamError;
    for (size_t t = 0; t <= sequence->count; t++) {
        MusicTrack track = t == sequence->count ? sequence->tempoTrack : sequence->tracks[t];
        MusicTimeStamp end = 0;
        for (size_t i = 0; i < track->count; i++) {
            MusicEventStorage *event = track->events[i];
            MusicTimeStamp eventEnd = event->time;
            if (event->type == kMusicEventType_MIDINoteMessage)
                eventEnd += ((MIDINoteMessage *)event->data)->duration;
            else if (event->type == kMusicEventType_ExtendedNote)
                eventEnd += ((ExtendedNoteOnEvent *)event->data)->duration;
            if (eventEnd > end) end = eventEnd;
        }
        for (size_t i = 0; i < track->count; i++) {
            MusicEventStorage *event = track->events[i];
            MusicTimeStamp duration = 0;
            if (event->type == kMusicEventType_MIDINoteMessage)
                duration = ((MIDINoteMessage *)event->data)->duration;
            else if (event->type == kMusicEventType_ExtendedNote)
                duration = ((ExtendedNoteOnEvent *)event->data)->duration;
            event->time = end - event->time - duration;
        }
        for (size_t i = 1; i < track->count; i++) {
            MusicEventStorage *value = track->events[i];
            size_t j = i;
            while (j && track->events[j - 1]->time > value->time) {
                track->events[j] = track->events[j - 1];
                j--;
            }
            track->events[j] = value;
        }
    }
    return noErr;
}

static Float64
host_seconds(UInt64 hostTime)
{
    mach_timebase_info_data_t timebase = {0};
    mach_timebase_info(&timebase);
    if (!timebase.denom)
        return 0;
    return (Float64)hostTime * timebase.numer / timebase.denom / 1000000000.0;
}

static UInt64
host_time_for_seconds(Float64 seconds)
{
    mach_timebase_info_data_t timebase = {0};
    mach_timebase_info(&timebase);
    if (!timebase.numer)
        return 0;
    long double ticks = (long double)seconds * 1000000000.0L * timebase.denom / timebase.numer;
    if (ticks <= 0)
        return 0;
    if (ticks >= 18446744073709551615.0L)
        return UINT64_MAX;
    return (UInt64)(ticks + 0.5L);
}

static MusicTimeStamp
player_current_beat(MusicPlayer player, UInt64 now)
{
    if (!player->playing || !player->sequence || now <= player->startHostTime)
        return player->startBeat;
    Float64 startSeconds = seconds_for_beats(player->sequence, player->startBeat);
    Float64 elapsed = host_seconds(now) - host_seconds(player->startHostTime);
    MusicTimeStamp beat = player->startBeat;
    MusicSequenceGetBeatsForSeconds(player->sequence,
        startSeconds + elapsed * player->playRate, &beat);
    return beat;
}

static void
player_reanchor(MusicPlayer player, MusicTimeStamp beat)
{
    player->startBeat = beat;
    player->startHostTime = mach_absolute_time();
}

OSStatus
NewMusicPlayer(MusicPlayer *outPlayer)
{
    if (!outPlayer)
        return kAudio_ParamError;
    *outPlayer = NULL;
    MusicPlayer player = calloc(1, sizeof(*player));
    if (!player)
        return kFinchMemoryFullError;
    player->playRate = 1.0;
    player->startHostTime = mach_absolute_time();
    *outPlayer = player;
    return noErr;
}

OSStatus
DisposeMusicPlayer(MusicPlayer player)
{
    if (!player)
        return kAudio_ParamError;
    if (player->playing)
        MusicPlayerStop(player);
    if (player->sequence && player->sequence->players)
        player->sequence->players--;
    free(player);
    return noErr;
}

OSStatus
MusicPlayerSetSequence(MusicPlayer player, MusicSequence sequence)
{
    if (!player)
        return kAudio_ParamError;
    if (player->playing)
        return kAudioToolboxErr_CannotDoInCurrentContext;
    if (player->sequence && player->sequence->players)
        player->sequence->players--;
    player->sequence = sequence;
    if (sequence)
        sequence->players++;
    player->startBeat = 0;
    player->startHostTime = mach_absolute_time();
    player->prerolled = false;
    return noErr;
}

OSStatus
MusicPlayerGetSequence(MusicPlayer player, MusicSequence *outSequence)
{
    if (!player || !outSequence)
        return kAudio_ParamError;
    *outSequence = player->sequence;
    return player->sequence ? noErr : kAudioToolboxErr_NoSequence;
}

OSStatus
MusicPlayerSetTime(MusicPlayer player, MusicTimeStamp time)
{
    if (!player || !isfinite(time))
        return kAudio_ParamError;
    player_reanchor(player, time);
    return noErr;
}

OSStatus
MusicPlayerGetTime(MusicPlayer player, MusicTimeStamp *outTime)
{
    if (!player || !outTime)
        return kAudio_ParamError;
    *outTime = player_current_beat(player, mach_absolute_time());
    return noErr;
}

OSStatus
MusicPlayerGetHostTimeForBeats(MusicPlayer player, MusicTimeStamp beats, UInt64 *outHostTime)
{
    if (!player || !outHostTime || !isfinite(beats))
        return kAudio_ParamError;
    if (!player->sequence)
        return kAudioToolboxErr_NoSequence;
    if (!player->playing || beats < player->startBeat)
        return kAudio_ParamError;
    Float64 startSeconds = seconds_for_beats(player->sequence, player->startBeat);
    Float64 targetSeconds = seconds_for_beats(player->sequence, beats);
    *outHostTime = player->startHostTime + host_time_for_seconds((targetSeconds - startSeconds) / player->playRate);
    return noErr;
}

OSStatus
MusicPlayerGetBeatsForHostTime(MusicPlayer player, UInt64 hostTime, MusicTimeStamp *outBeats)
{
    if (!player || !outBeats)
        return kAudio_ParamError;
    if (!player->sequence)
        return kAudioToolboxErr_NoSequence;
    if (!player->playing || hostTime < player->startHostTime)
        return kAudio_ParamError;
    Float64 startSeconds = seconds_for_beats(player->sequence, player->startBeat);
    Float64 elapsed = host_seconds(hostTime) - host_seconds(player->startHostTime);
    return MusicSequenceGetBeatsForSeconds(player->sequence,
        startSeconds + elapsed * player->playRate, outBeats);
}

OSStatus
MusicPlayerPreroll(MusicPlayer player)
{
    if (!player)
        return kAudio_ParamError;
    if (!player->sequence)
        return kAudioToolboxErr_NoSequence;
    if (player->sequence->graph) {
        Boolean open = false, initialized = false;
        OSStatus status = AUGraphIsOpen(player->sequence->graph, &open);
        if (status)
            return status;
        if (!open && (status = AUGraphOpen(player->sequence->graph)))
            return status;
        status = AUGraphIsInitialized(player->sequence->graph, &initialized);
        if (status)
            return status;
        if (!initialized && (status = AUGraphInitialize(player->sequence->graph)))
            return status;
    }
    player->prerolled = true;
    return noErr;
}

OSStatus
MusicPlayerStart(MusicPlayer player)
{
    if (!player)
        return kAudio_ParamError;
    if (!player->sequence)
        return kAudioToolboxErr_NoSequence;
    if (player->playing)
        return noErr;
    if (player->sequence->graph) {
        OSStatus status = AUGraphStart(player->sequence->graph);
        if (status)
            return status;
    }
    player_reanchor(player, player->startBeat);
    player->playing = true;
    player->prerolled = false;
    return noErr;
}

OSStatus
MusicPlayerStop(MusicPlayer player)
{
    if (!player)
        return kAudio_ParamError;
    if (!player->playing)
        return noErr;
    MusicTimeStamp beat = player_current_beat(player, mach_absolute_time());
    if (player->sequence && player->sequence->graph) {
        OSStatus status = AUGraphStop(player->sequence->graph);
        if (status)
            return status;
    }
    player->playing = false;
    player_reanchor(player, beat);
    return noErr;
}

OSStatus
MusicPlayerIsPlaying(MusicPlayer player, Boolean *outIsPlaying)
{
    if (!player || !outIsPlaying)
        return kAudio_ParamError;
    *outIsPlaying = player->playing;
    return noErr;
}

OSStatus
MusicPlayerSetPlayRateScalar(MusicPlayer player, Float64 scale)
{
    if (!player || !isfinite(scale) || scale <= 0)
        return kAudio_ParamError;
    if (player->playing)
        player_reanchor(player, player_current_beat(player, mach_absolute_time()));
    player->playRate = scale;
    return noErr;
}

OSStatus
MusicPlayerGetPlayRateScalar(MusicPlayer player, Float64 *outScale)
{
    if (!player || !outScale)
        return kAudio_ParamError;
    *outScale = player->playRate;
    return noErr;
}

typedef struct {
    UInt8 *bytes;
    size_t length;
    size_t capacity;
} MIDIBytes;

typedef struct {
    UInt64 tick;
    UInt8 *bytes;
    size_t length;
    size_t order;
} MIDIOutEvent;

typedef struct {
    MIDIOutEvent *events;
    size_t count;
    size_t capacity;
} MIDIOutTrack;

static bool
midi_put(MIDIBytes *bytes, const void *source, size_t length)
{
    if (length > SIZE_MAX - bytes->length)
        return false;
    size_t needed = bytes->length + length;
    if (needed > bytes->capacity) {
        size_t capacity = bytes->capacity ? bytes->capacity : 128;
        while (capacity < needed) {
            if (capacity > SIZE_MAX / 2)
                return false;
            capacity *= 2;
        }
        UInt8 *next = realloc(bytes->bytes, capacity);
        if (!next)
            return false;
        bytes->bytes = next;
        bytes->capacity = capacity;
    }
    if (length)
        memcpy(bytes->bytes + bytes->length, source, length);
    bytes->length = needed;
    return true;
}

static bool
midi_put_vlq(MIDIBytes *bytes, UInt64 value)
{
    if (value > 0x0fffffff)
        return false;
    UInt8 encoded[4];
    size_t count = 1;
    encoded[3] = value & 0x7f;
    while ((value >>= 7) != 0)
        encoded[3 - count++] = (UInt8)(0x80 | (value & 0x7f));
    return midi_put(bytes, encoded + 4 - count, count);
}

static void
midi_free_out_track(MIDIOutTrack *track)
{
    for (size_t i = 0; i < track->count; i++)
        free(track->events[i].bytes);
    free(track->events);
    memset(track, 0, sizeof(*track));
}

static bool
midi_add_out_event(MIDIOutTrack *track, UInt64 tick, const UInt8 *bytes, size_t length)
{
    if (track->count == track->capacity) {
        size_t capacity = track->capacity ? track->capacity * 2 : 8;
        MIDIOutEvent *events = realloc(track->events, capacity * sizeof(*events));
        if (!events)
            return false;
        track->events = events;
        track->capacity = capacity;
    }
    UInt8 *copy = malloc(length ? length : 1);
    if (!copy)
        return false;
    if (length)
        memcpy(copy, bytes, length);
    track->events[track->count] = (MIDIOutEvent){tick, copy, length, track->count};
    track->count++;
    return true;
}

static int
midi_event_order(const void *left, const void *right)
{
    const MIDIOutEvent *a = left, *b = right;
    if (a->tick < b->tick)
        return -1;
    if (a->tick > b->tick)
        return 1;
    return a->order < b->order ? -1 : a->order > b->order;
}

static bool
midi_event_tick(MusicSequence sequence, MusicTrack track, MusicEventStorage *event,
    UInt16 resolution, UInt64 *outTick)
{
    MusicTimeStamp time = event->time + track->offset;
    if (!isfinite(time) || time < 0 || time * resolution > 0x0fffffff)
        return false;
    (void)sequence;
    *outTick = (UInt64)llround(time * resolution);
    return true;
}

static bool
midi_encode_track(MusicSequence sequence, MusicTrack track, UInt16 resolution, bool tempoTrack,
    MIDIBytes *out)
{
    MIDIOutTrack events = {0};
    bool hasTempo = false;
    if (!tempoTrack && track->name) {
        CFIndex capacity = CFStringGetMaximumSizeForEncoding(CFStringGetLength(track->name), kCFStringEncodingUTF8) + 1;
        char *name = capacity > 0 ? malloc((size_t)capacity) : NULL;
        if (!name || !CFStringGetCString(track->name, name, capacity, kCFStringEncodingUTF8)) {
            free(name);
            goto fail;
        }
        size_t length = strlen(name);
        MIDIBytes encodedName = {0};
        if (!midi_put(&encodedName, (const UInt8[]){0xff, 0x03}, 2) ||
            !midi_put_vlq(&encodedName, length) || !midi_put(&encodedName, name, length) ||
            !midi_add_out_event(&events, 0, encodedName.bytes, encodedName.length)) {
            free(name);
            free(encodedName.bytes);
            goto fail;
        }
        free(name);
        free(encodedName.bytes);
    }
    for (size_t i = 0; i < track->count; i++) {
        MusicEventStorage *event = track->events[i];
        UInt64 tick = 0;
        if (!midi_event_tick(sequence, track, event, resolution, &tick))
            goto fail;
        if (event->type == kMusicEventType_ExtendedTempo) {
            Float64 bpm = ((ExtendedTempoEvent *)event->data)->bpm;
            if (!isfinite(bpm) || bpm <= 0)
                goto fail;
            UInt32 micros = (UInt32)llround(60000000.0 / bpm);
            UInt8 meta[] = {0xff, 0x51, 0x03, (UInt8)(micros >> 16), (UInt8)(micros >> 8), (UInt8)micros};
            if (!midi_add_out_event(&events, tick, meta, sizeof(meta)))
                goto fail;
            hasTempo = true;
        } else if (!tempoTrack && event->type == kMusicEventType_MIDINoteMessage) {
            MIDINoteMessage *note = event->data;
            if (note->channel > 15 || note->note > 127 || note->velocity > 127 ||
                !isfinite(note->duration) || note->duration < 0)
                goto fail;
            UInt8 on[] = {(UInt8)(0x90 | note->channel), note->note, note->velocity};
            UInt8 off[] = {(UInt8)(0x80 | note->channel), note->note, note->releaseVelocity & 0x7f};
            UInt64 endTick = tick + (UInt64)llround(note->duration * resolution);
            if (endTick > 0x0fffffff || !midi_add_out_event(&events, tick, on, sizeof(on)) ||
                !midi_add_out_event(&events, endTick, off, sizeof(off)))
                goto fail;
        } else if (!tempoTrack && event->type == kMusicEventType_MIDIChannelMessage) {
            MIDIChannelMessage *message = event->data;
            UInt8 midi[] = {message->status, message->data1, message->data2};
            if (!midi_add_out_event(&events, tick, midi, sizeof(midi)))
                goto fail;
        } else if (!tempoTrack && event->type == kMusicEventType_Meta) {
            MIDIMetaEvent *meta = event->data;
            MIDIBytes encoded = {0};
            UInt8 prefix[] = {0xff, meta->metaEventType};
            if (!midi_put(&encoded, prefix, sizeof(prefix)) || !midi_put_vlq(&encoded, meta->dataLength) ||
                !midi_put(&encoded, meta->data, meta->dataLength) ||
                !midi_add_out_event(&events, tick, encoded.bytes, encoded.length)) {
                free(encoded.bytes);
                goto fail;
            }
            free(encoded.bytes);
        } else if (!tempoTrack && event->type == kMusicEventType_MIDIRawData) {
            MIDIRawData *raw = event->data;
            if (!midi_add_out_event(&events, tick, raw->data, raw->length))
                goto fail;
        }
    }
    if (tempoTrack && !hasTempo) {
        UInt8 defaultTempo[] = {0xff, 0x51, 0x03, 0x07, 0xa1, 0x20};
        if (!midi_add_out_event(&events, 0, defaultTempo, sizeof(defaultTempo)))
            goto fail;
    }
    qsort(events.events, events.count, sizeof(*events.events), midi_event_order);
    UInt64 previous = 0;
    for (size_t i = 0; i < events.count; i++) {
        MIDIOutEvent *event = &events.events[i];
        if (event->tick < previous || !midi_put_vlq(out, event->tick - previous) ||
            !midi_put(out, event->bytes, event->length))
            goto fail;
        previous = event->tick;
    }
    if (!midi_put(out, (const UInt8[]){0, 0xff, 0x2f, 0}, 4))
        goto fail;
    midi_free_out_track(&events);
    return true;
fail:
    midi_free_out_track(&events);
    return false;
}

static OSStatus
midi_create_data(MusicSequence sequence, MusicSequenceFileTypeID fileType, SInt16 resolution,
    CFDataRef *outData)
{
    if (!sequence || !outData)
        return kAudio_ParamError;
    *outData = NULL;
    if (fileType != kMusicSequenceFile_MIDIType)
        return kAudioFileUnsupportedFileTypeError;
    UInt16 division = resolution > 0 ? (UInt16)resolution :
        sequence->timeResolution > 0 && sequence->timeResolution <= UINT16_MAX ? (UInt16)sequence->timeResolution : 480;
    if (sequence->type == kMusicSequenceType_Samples || division == 0)
        return kAudio_ParamError;
    size_t trackCount = sequence->count > 1 ? sequence->count + 1 : 1;
    if (trackCount > UINT16_MAX)
        return kAudio_ParamError;
    MIDIBytes file = {0};
    UInt8 header[] = {'M','T','h','d', 0,0,0,6, 0,(UInt8)(trackCount > 1),
        (UInt8)(trackCount >> 8), (UInt8)trackCount, (UInt8)(division >> 8), (UInt8)division};
    if (!midi_put(&file, header, sizeof(header)))
        goto memoryError;
    for (size_t i = 0; i < trackCount; i++) {
        MIDIBytes trackData = {0};
        MusicTrack track = NULL;
        bool tempoTrack = false;
        if (!sequence->count) {
            track = sequence->tempoTrack;
            tempoTrack = true;
        } else if (sequence->count == 1) {
            track = sequence->tracks[0];
        } else if (i == 0) {
            track = sequence->tempoTrack;
            tempoTrack = true;
        } else {
            track = sequence->tracks[i - 1];
        }
        MusicTrack combined = NULL;
        if (sequence->count == 1) {
            MusicTrack source = sequence->tracks[0];
            combined = calloc(1, sizeof(*combined));
            if (!combined) {
                free(file.bytes);
                return kFinchMemoryFullError;
            }
            *combined = *source;
            combined->count = source->count + sequence->tempoTrack->count;
            combined->events = calloc(combined->count, sizeof(*combined->events));
            if (combined->count && !combined->events) {
                free(combined);
                free(file.bytes);
                return kFinchMemoryFullError;
            }
            for (size_t j = 0; j < sequence->tempoTrack->count; j++)
                combined->events[j] = sequence->tempoTrack->events[j];
            for (size_t j = 0; j < source->count; j++)
                combined->events[sequence->tempoTrack->count + j] = source->events[j];
            track = combined;
        }
        bool encoded = midi_encode_track(sequence, track, division, tempoTrack, &trackData);
        if (combined) {
            free(combined->events);
            free(combined);
        }
        if (!encoded || trackData.length > UINT32_MAX) {
            free(trackData.bytes);
            free(file.bytes);
            return kAudio_ParamError;
        }
        UInt32 length = (UInt32)trackData.length;
        UInt8 trackHeader[] = {'M','T','r','k', (UInt8)(length >> 24), (UInt8)(length >> 16),
            (UInt8)(length >> 8), (UInt8)length};
        if (!midi_put(&file, trackHeader, sizeof(trackHeader)) ||
            !midi_put(&file, trackData.bytes, trackData.length)) {
            free(trackData.bytes);
            goto memoryError;
        }
        free(trackData.bytes);
    }
    *outData = CFDataCreate(NULL, file.bytes, (CFIndex)file.length);
    free(file.bytes);
    return *outData ? noErr : kFinchMemoryFullError;
memoryError:
    free(file.bytes);
    return kFinchMemoryFullError;
}

OSStatus
MusicSequenceFileCreateData(MusicSequence sequence, MusicSequenceFileTypeID fileType,
    MusicSequenceFileFlags flags, SInt16 resolution, CFDataRef *outData)
{
    if (flags != kMusicSequenceFileFlags_Default)
        return kAudio_ParamError;
    return midi_create_data(sequence, fileType, resolution, outData);
}

OSStatus
MusicSequenceSaveSMFData(MusicSequence sequence, CFDataRef *outData, UInt16 resolution)
{
    return midi_create_data(sequence, kMusicSequenceFile_MIDIType, resolution, outData);
}

static bool
midi_read_vlq(const UInt8 *bytes, size_t length, size_t *cursor, UInt32 *value)
{
    UInt32 result = 0;
    for (unsigned i = 0; i < 4; i++) {
        if (*cursor >= length)
            return false;
        UInt8 byte = bytes[(*cursor)++];
        result = (result << 7) | (byte & 0x7f);
        if (!(byte & 0x80)) {
            *value = result;
            return true;
        }
    }
    return false;
}

typedef struct {
    UInt64 tick;
    UInt8 channel, note, velocity, release;
    bool used;
} MIDIPendingNote;

static OSStatus
midi_parse_track(MusicSequence sequence, MusicTrack track, const UInt8 *bytes, size_t length,
    UInt16 division)
{
    size_t cursor = 0;
    UInt64 tick = 0;
    UInt8 running = 0;
    MIDIPendingNote *pending = NULL;
    size_t pendingCount = 0, pendingCapacity = 0;
    OSStatus status = noErr;
    while (cursor < length) {
        UInt32 delta = 0;
        if (!midi_read_vlq(bytes, length, &cursor, &delta)) {
            status = kAudioFileInvalidFileError;
            break;
        }
        tick += delta;
        if (cursor >= length) {
            status = kAudioFileInvalidFileError;
            break;
        }
        UInt8 first = bytes[cursor++];
        UInt8 eventStatus = first;
        bool hasFirstData = first < 0x80;
        if (hasFirstData) {
            if (!running) {
                status = kAudioFileInvalidFileError;
                break;
            }
            eventStatus = running;
            cursor--;
        } else if (first < 0xf0) {
            running = first;
        } else {
            running = 0;
        }
        MusicTimeStamp time = (MusicTimeStamp)tick / division;
        if (eventStatus == 0xff) {
            if (cursor >= length) {
                status = kAudioFileInvalidFileError;
                break;
            }
            UInt8 type = bytes[cursor++];
            UInt32 dataLength = 0;
            if (!midi_read_vlq(bytes, length, &cursor, &dataLength) || dataLength > length - cursor) {
                status = kAudioFileInvalidFileError;
                break;
            }
            if (type == 0x2f) {
                cursor += dataLength;
                break;
            }
            if (type == 0x03) {
                CFStringRef name = CFStringCreateWithBytes(NULL, bytes + cursor, dataLength,
                    kCFStringEncodingUTF8, false);
                if (!name) {
                    status = kAudioFileInvalidFileError;
                    break;
                }
                if (track->name)
                    CFRelease(track->name);
                track->name = name;
                cursor += dataLength;
                continue;
            }
            if (type == 0x51 && dataLength == 3) {
                UInt32 micros = (UInt32)bytes[cursor] << 16 | (UInt32)bytes[cursor + 1] << 8 | bytes[cursor + 2];
                if (micros) {
                    ExtendedTempoEvent tempo = {60000000.0 / micros};
                    status = add_event(sequence->tempoTrack, time, kMusicEventType_ExtendedTempo, &tempo);
                }
            } else {
                size_t total = offsetof(MIDIMetaEvent, data) + dataLength;
                MIDIMetaEvent *meta = calloc(1, total);
                if (!meta) {
                    status = kFinchMemoryFullError;
                    break;
                }
                meta->metaEventType = type;
                meta->dataLength = dataLength;
                memcpy(meta->data, bytes + cursor, dataLength);
                status = add_event(track, time, kMusicEventType_Meta, meta);
                free(meta);
            }
            cursor += dataLength;
            if (status)
                break;
        } else if (eventStatus == 0xf0 || eventStatus == 0xf7) {
            UInt32 dataLength = 0;
            if (!midi_read_vlq(bytes, length, &cursor, &dataLength) || dataLength > length - cursor) {
                status = kAudioFileInvalidFileError;
                break;
            }
            size_t total = offsetof(MIDIRawData, data) + dataLength;
            MIDIRawData *raw = calloc(1, total);
            if (!raw) {
                status = kFinchMemoryFullError;
                break;
            }
            raw->length = dataLength;
            memcpy(raw->data, bytes + cursor, dataLength);
            status = add_event(track, time, kMusicEventType_MIDIRawData, raw);
            free(raw);
            cursor += dataLength;
            if (status)
                break;
        } else if (eventStatus >= 0x80 && eventStatus <= 0xef) {
            UInt8 command = eventStatus & 0xf0, channel = eventStatus & 0x0f;
            size_t dataCount = (command == 0xc0 || command == 0xd0) ? 1 : 2;
            UInt8 data[2] = {0};
            if (hasFirstData)
                data[0] = bytes[cursor++];
            else {
                if (cursor >= length) { status = kAudioFileInvalidFileError; break; }
                data[0] = bytes[cursor++];
            }
            if (dataCount == 2) {
                if (cursor >= length) { status = kAudioFileInvalidFileError; break; }
                data[1] = bytes[cursor++];
            }
            if (command == 0x90 && dataCount == 2 && data[1] != 0) {
                if (pendingCount == pendingCapacity) {
                    size_t capacity = pendingCapacity ? pendingCapacity * 2 : 8;
                    MIDIPendingNote *next = realloc(pending, capacity * sizeof(*next));
                    if (!next) { status = kFinchMemoryFullError; break; }
                    pending = next;
                    pendingCapacity = capacity;
                }
                pending[pendingCount++] = (MIDIPendingNote){tick, channel, data[0], data[1], 0, false};
            } else if ((command == 0x80 || (command == 0x90 && dataCount == 2 && data[1] == 0)) && dataCount == 2) {
                size_t match = pendingCount;
                for (size_t i = 0; i < pendingCount; i++)
                    if (!pending[i].used && pending[i].channel == channel && pending[i].note == data[0]) {
                        match = i;
                        break;
                    }
                if (match < pendingCount) {
                    MIDIPendingNote *note = &pending[match];
                    MIDINoteMessage message = {note->channel, note->note, note->velocity, data[1],
                        (Float32)(tick - note->tick) / division};
                    status = add_event(track, (MusicTimeStamp)note->tick / division,
                        kMusicEventType_MIDINoteMessage, &message);
                    note->used = true;
                } else {
                    MIDIChannelMessage message = {eventStatus, data[0], data[1], 0};
                    status = add_event(track, time, kMusicEventType_MIDIChannelMessage, &message);
                }
                if (status)
                    break;
            } else {
                MIDIChannelMessage message = {eventStatus, data[0], data[1], 0};
                status = add_event(track, time, kMusicEventType_MIDIChannelMessage, &message);
                if (status)
                    break;
            }
        } else {
            status = kAudioFileInvalidFileError;
            break;
        }
    }
    free(pending);
    return status;
}

static OSStatus
midi_load_data(MusicSequence sequence, CFDataRef data, MusicSequenceFileTypeID hint,
    MusicSequenceLoadFlags flags)
{
    if (!sequence || !data || CFGetTypeID(data) != CFDataGetTypeID())
        return kAudio_ParamError;
    if (hint && hint != kMusicSequenceFile_MIDIType)
        return kAudioFileUnsupportedFileTypeError;
    if (flags & ~kMusicSequenceLoadSMF_ChannelsToTracks)
        return kAudio_ParamError;
    const UInt8 *bytes = CFDataGetBytePtr(data);
    size_t length = (size_t)CFDataGetLength(data);
    if (length < 14 || memcmp(bytes, "MThd", 4) || read_be32(bytes + 4) < 6)
        return kAudioFileInvalidFileError;
    UInt32 headerLength = read_be32(bytes + 4);
    if (headerLength > length - 8)
        return kAudioFileInvalidFileError;
    UInt16 format = (UInt16)(bytes[8] << 8 | bytes[9]);
    UInt16 tracks = (UInt16)(bytes[10] << 8 | bytes[11]);
    UInt16 division = (UInt16)(bytes[12] << 8 | bytes[13]);
    if (format > 1 || !tracks || !division || (division & 0x8000))
        return kAudioFileInvalidFileError;
    sequence->timeResolution = division;
    sequence->type = kMusicSequenceType_Beats;
    size_t cursor = 8 + headerLength;
    for (UInt16 i = 0; i < tracks; i++) {
        if (cursor > length || length - cursor < 8 || memcmp(bytes + cursor, "MTrk", 4))
            return kAudioFileInvalidFileError;
        UInt32 trackLength = read_be32(bytes + cursor + 4);
        cursor += 8;
        if (trackLength > length - cursor)
            return kAudioFileInvalidFileError;
        MusicTrack track = NULL;
        OSStatus status = noErr;
        if (format == 1 && i == 0) {
            track = sequence->tempoTrack;
        } else {
            status = MusicSequenceNewTrack(sequence, &track);
            if (status)
                return status;
        }
        status = midi_parse_track(sequence, track, bytes + cursor, trackLength, division);
        if (status)
            return status;
        cursor += trackLength;
    }
    return noErr;
}

OSStatus
MusicSequenceFileLoadData(MusicSequence sequence, CFDataRef data,
    MusicSequenceFileTypeID fileTypeHint, MusicSequenceLoadFlags flags)
{
    return midi_load_data(sequence, data, fileTypeHint, flags);
}

OSStatus
MusicSequenceLoadSMFDataWithFlags(MusicSequence sequence, CFDataRef data, MusicSequenceLoadFlags flags)
{
    return midi_load_data(sequence, data, kMusicSequenceFile_MIDIType, flags);
}

static OSStatus
midi_read_url(CFURLRef url, CFDataRef *outData)
{
    char path[PATH_MAX];
    if (!url || !CFURLGetFileSystemRepresentation(url, true, (UInt8 *)path, sizeof(path)))
        return kAudio_ParamError;
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return kAudioFileUnspecifiedError;
    MIDIBytes bytes = {0};
    UInt8 buffer[4096];
    OSStatus status = noErr;
    for (;;) {
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count < 0) { status = kAudioFileUnspecifiedError; break; }
        if (!count) break;
        if (!midi_put(&bytes, buffer, (size_t)count)) { status = kFinchMemoryFullError; break; }
    }
    close(fd);
    if (!status) {
        *outData = CFDataCreate(NULL, bytes.bytes, (CFIndex)bytes.length);
        if (!*outData)
            status = kFinchMemoryFullError;
    }
    free(bytes.bytes);
    return status;
}

OSStatus
MusicSequenceFileLoad(MusicSequence sequence, CFURLRef url,
    MusicSequenceFileTypeID fileTypeHint, MusicSequenceLoadFlags flags)
{
    CFDataRef data = NULL;
    OSStatus status = midi_read_url(url, &data);
    if (!status)
        status = midi_load_data(sequence, data, fileTypeHint, flags);
    if (data)
        CFRelease(data);
    return status;
}

OSStatus
MusicSequenceLoadSMFWithFlags(MusicSequence sequence, const struct FSRef *fileRef,
    MusicSequenceLoadFlags flags)
{
    if (!fileRef)
        return kAudio_ParamError;
    char path[PATH_MAX];
    if (FSRefMakePath(fileRef, (UInt8 *)path, sizeof(path)) != noErr)
        return kAudio_ParamError;
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
    OSStatus status = url ? MusicSequenceFileLoad(sequence, url, kMusicSequenceFile_MIDIType, flags) : kAudio_ParamError;
    if (url)
        CFRelease(url);
    return status;
}

static OSStatus
midi_write_url(CFURLRef url, CFDataRef data, MusicSequenceFileFlags flags)
{
    char path[PATH_MAX];
    if (!url || !CFURLGetFileSystemRepresentation(url, true, (UInt8 *)path, sizeof(path)))
        return kAudio_ParamError;
    int openFlags = O_WRONLY | O_CREAT | O_CLOEXEC |
        ((flags & kMusicSequenceFileFlags_EraseFile) ? O_TRUNC : O_EXCL);
    int fd = open(path, openFlags, 0644);
    if (fd < 0)
        return errno == EEXIST ? kAudioFilePermissionsError : kAudioFilePermissionsError;
    const UInt8 *bytes = CFDataGetBytePtr(data);
    size_t left = (size_t)CFDataGetLength(data);
    while (left) {
        ssize_t count = write(fd, bytes, left);
        if (count <= 0) { close(fd); return kAudioFileUnspecifiedError; }
        bytes += count;
        left -= (size_t)count;
    }
    close(fd);
    return noErr;
}

OSStatus
MusicSequenceFileCreate(MusicSequence sequence, CFURLRef url, MusicSequenceFileTypeID fileType,
    MusicSequenceFileFlags flags, SInt16 resolution)
{
    if (flags & ~kMusicSequenceFileFlags_EraseFile)
        return kAudio_ParamError;
    CFDataRef data = NULL;
    OSStatus status = midi_create_data(sequence, fileType, resolution, &data);
    if (!status)
        status = midi_write_url(url, data, flags);
    if (data)
        CFRelease(data);
    return status;
}

OSStatus
MusicSequenceSaveMIDIFile(MusicSequence sequence, const struct FSRef *parent,
    CFStringRef fileName, UInt16 resolution, UInt32 flags)
{
    if (!parent || !fileName || flags)
        return kAudio_ParamError;
    char directory[PATH_MAX], name[PATH_MAX], path[PATH_MAX];
    if (FSRefMakePath(parent, (UInt8 *)directory, sizeof(directory)) != noErr ||
        !CFStringGetCString(fileName, name, sizeof(name), kCFStringEncodingUTF8))
        return kAudio_ParamError;
    int count = snprintf(path, sizeof(path), "%s/%s", directory, name);
    if (count < 0 || (size_t)count >= sizeof(path))
        return kAudio_ParamError;
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, count, false);
    OSStatus status = url ? MusicSequenceFileCreate(sequence, url, kMusicSequenceFile_MIDIType,
        kMusicSequenceFileFlags_Default, resolution) : kAudio_ParamError;
    if (url)
        CFRelease(url);
    return status;
}

OSStatus
NewMusicTrackFrom(MusicTrack source, MusicTimeStamp startTime, MusicTimeStamp endTime, MusicTrack *outTrack)
{
    if (!source || !outTrack || validate_time(startTime) || validate_time(endTime) || endTime < startTime)
        return kAudio_ParamError;
    *outTrack = NULL;
    MusicTrack track = NULL;
    track = new_track(source->sequence, false);
    if (!track)
        return kFinchMemoryFullError;
    if (source->name)
        track->name = CFRetain(source->name);
    OSStatus status = noErr;
    for (size_t i = 0; i < source->count; i++) {
        MusicEventStorage *event = source->events[i];
        if (event->time < startTime || event->time > endTime)
            continue;
        MusicEventStorage *copy = copy_event(event->time, event->type, event->data);
        if (!copy || (status = insert_event(track, copy)) != noErr) {
            if (copy)
                free_event(copy);
            free_track(track);
            return copy ? status : kFinchMemoryFullError;
        }
    }
    MusicSequence sequence = source->sequence;
    if (sequence->derivedCount == sequence->derivedCapacity) {
        size_t capacity = sequence->derivedCapacity ? sequence->derivedCapacity * 2 : 4;
        MusicTrack *tracks = realloc(sequence->derivedTracks, capacity * sizeof(*tracks));
        if (!tracks) {
            free_track(track);
            return kFinchMemoryFullError;
        }
        sequence->derivedTracks = tracks;
        sequence->derivedCapacity = capacity;
    }
    sequence->derivedTracks[sequence->derivedCount++] = track;
    *outTrack = track;
    return noErr;
}

static UInt32
read_be32(const UInt8 *bytes)
{
    return (UInt32)bytes[0] << 24 | (UInt32)bytes[1] << 16 | (UInt32)bytes[2] << 8 | bytes[3];
}
