/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <AudioToolbox/CoreAudioClock.h>
#include <CoreMIDI/MIDIServices.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

enum { kFinchMemoryFullError = -108 };

typedef struct ClockListener {
	CAClockListenerProc proc;
	void *userData;
	struct ClockListener *next;
} ClockListener;

struct OpaqueCAClock {
	CAClockTimebase timebase;
	UInt32 timebaseSource;
	CAClockSyncMode syncMode;
	MIDIEndpointRef syncSource;
	CAClockSMPTEFormat smpteFormat;
	Float64 smpteOffset;
	Float64 mtcFreewheel;
	UInt32 sendSPP;
	UInt32 *midiDestinations;
	UInt32 midiDestinationCount;
	UInt32 *mtcDestinations;
	UInt32 mtcDestinationCount;
	CATempoMapEntry *tempos;
	UInt32 tempoCount;
	CAMeterTrackEntry *meters;
	UInt32 meterCount;
	CFStringRef name;
	ClockListener *listeners;
	Float64 positionSeconds;
	Float64 startSeconds;
	Float64 startHostSeconds;
	UInt64 startHostTime;
	Float64 playRate;
	Float64 overrideTempo;
	Float64 overrideBeat;
	Boolean overrideActive;
	Boolean playing;
	Boolean armed;
};

static Float64 hostSeconds(UInt64 hostTime)
{
	mach_timebase_info_data_t timebase = {0};
	mach_timebase_info(&timebase);
	return timebase.denom
	    ? (Float64)hostTime * timebase.numer / timebase.denom / 1000000000.0
	    : 0;
}

static UInt64 hostTicks(Float64 seconds)
{
	mach_timebase_info_data_t timebase = {0};
	mach_timebase_info(&timebase);
	if (!timebase.numer || !isfinite(seconds) || seconds <= 0)
		return 0;
	long double ticks = (long double)seconds * 1000000000.0L * timebase.denom / timebase.numer;
	if (ticks >= 18446744073709551615.0L)
		return UINT64_MAX;
	return (UInt64)(ticks + 0.5L);
}

static void notifyListeners(CAClockRef clock, CAClockMessage message)
{
	const UInt32 noParameter = 0;
	for (ClockListener *listener = clock->listeners; listener;) {
		ClockListener *next = listener->next;
		listener->proc(listener->userData, message, &noParameter);
		listener = next;
	}
}

static Float64 currentSeconds(CAClockRef clock, UInt64 now)
{
	if (!clock->playing || now <= clock->startHostTime)
		return clock->positionSeconds;
	return clock->startSeconds +
	    (hostSeconds(now) - clock->startHostSeconds) * clock->playRate;
}

static Float64 tempoForBeat(CAClockRef clock, Float64 beat, Float64 *changeBeat)
{
	Float64 tempo = 120.0, changed = 0;
	for (UInt32 i = 0; i < clock->tempoCount; i++) {
		if (clock->tempos[i].beats > beat)
			break;
		tempo = clock->tempos[i].tempoBPM;
		changed = clock->tempos[i].beats;
	}
	if (clock->overrideActive && clock->overrideBeat <= beat && clock->overrideBeat >= changed) {
		tempo = clock->overrideTempo;
		changed = clock->overrideBeat;
	}
	if (changeBeat)
		*changeBeat = changed;
	return tempo;
}

static Float64 baseSecondsForBeats(CAClockRef clock, Float64 beats)
{
	if (beats < 0)
		return beats * 0.5;
	Float64 seconds = 0, startBeat = 0, tempo = 120;
	for (UInt32 i = 0; i < clock->tempoCount; i++) {
		CATempoMapEntry entry = clock->tempos[i];
		if (entry.beats > beats)
			break;
		seconds += (entry.beats - startBeat) * 60.0 / tempo;
		startBeat = entry.beats;
		tempo = entry.tempoBPM;
	}
	return seconds + (beats - startBeat) * 60.0 / tempo;
}

static Float64 secondsForBeats(CAClockRef clock, Float64 beats)
{
	if (clock->overrideActive && beats >= clock->overrideBeat)
		return baseSecondsForBeats(clock, clock->overrideBeat) +
		    (beats - clock->overrideBeat) * 60.0 / clock->overrideTempo;
	return baseSecondsForBeats(clock, beats);
}

static Float64 baseBeatsForSeconds(CAClockRef clock, Float64 seconds)
{
	if (seconds < 0)
		return seconds * 2.0;
	Float64 elapsed = 0, beat = 0, tempo = 120;
	for (UInt32 i = 0; i < clock->tempoCount; i++) {
		CATempoMapEntry entry = clock->tempos[i];
		if (entry.beats <= beat)
			continue;
		Float64 until = (entry.beats - beat) * 60.0 / tempo;
		if (elapsed + until > seconds)
			return beat + (seconds - elapsed) * tempo / 60.0;
		elapsed += until;
		beat = entry.beats;
		tempo = entry.tempoBPM;
	}
	return beat + (seconds - elapsed) * tempo / 60.0;
}

static Float64 beatsForSeconds(CAClockRef clock, Float64 seconds)
{
	if (clock->overrideActive) {
		Float64 overrideSeconds = baseSecondsForBeats(clock, clock->overrideBeat);
		if (seconds >= overrideSeconds)
			return clock->overrideBeat +
			    (seconds - overrideSeconds) * clock->overrideTempo / 60.0;
	}
	return baseBeatsForSeconds(clock, seconds);
}

static UInt32 propertySize(CAClockRef clock, CAClockPropertyID property)
{
	switch (property) {
	case kCAClockProperty_InternalTimebase: return sizeof(clock->timebase);
	case kCAClockProperty_TimebaseSource: return sizeof(clock->timebaseSource);
	case kCAClockProperty_SyncMode: return sizeof(clock->syncMode);
	case kCAClockProperty_SyncSource: return sizeof(clock->syncSource);
	case kCAClockProperty_SMPTEFormat: return sizeof(clock->smpteFormat);
	case kCAClockProperty_SMPTEOffset: return sizeof(clock->smpteOffset);
	case kCAClockProperty_MIDIClockDestinations: return clock->midiDestinationCount * sizeof(UInt32);
	case kCAClockProperty_MTCDestinations: return clock->mtcDestinationCount * sizeof(UInt32);
	case kCAClockProperty_MTCFreewheelTime: return sizeof(clock->mtcFreewheel);
	case kCAClockProperty_TempoMap: return clock->tempoCount * sizeof(CATempoMapEntry);
	case kCAClockProperty_MeterTrack: return clock->meterCount * sizeof(CAMeterTrackEntry);
	case kCAClockProperty_Name: return sizeof(CFStringRef);
	case kCAClockProperty_SendMIDISPP: return sizeof(clock->sendSPP);
	default: return UINT32_MAX;
	}
}

static const void *propertyValue(CAClockRef clock, CAClockPropertyID property)
{
	switch (property) {
	case kCAClockProperty_InternalTimebase: return &clock->timebase;
	case kCAClockProperty_TimebaseSource: return &clock->timebaseSource;
	case kCAClockProperty_SyncMode: return &clock->syncMode;
	case kCAClockProperty_SyncSource: return &clock->syncSource;
	case kCAClockProperty_SMPTEFormat: return &clock->smpteFormat;
	case kCAClockProperty_SMPTEOffset: return &clock->smpteOffset;
	case kCAClockProperty_MIDIClockDestinations: return clock->midiDestinations;
	case kCAClockProperty_MTCDestinations: return clock->mtcDestinations;
	case kCAClockProperty_MTCFreewheelTime: return &clock->mtcFreewheel;
	case kCAClockProperty_TempoMap: return clock->tempos;
	case kCAClockProperty_MeterTrack: return clock->meters;
	case kCAClockProperty_Name: return &clock->name;
	case kCAClockProperty_SendMIDISPP: return &clock->sendSPP;
	default: return NULL;
	}
}

static OSStatus getTimeSeconds(CAClockRef clock, const CAClockTime *time, Float64 *seconds)
{
	if (!time || !seconds)
		return kCAClock_InvalidTimeFormatError;
	switch (time->format) {
	case kCAClockTimeFormat_Seconds:
		*seconds = time->time.seconds;
		return noErr;
	case kCAClockTimeFormat_Beats:
		*seconds = secondsForBeats(clock, time->time.beats);
		return noErr;
	case kCAClockTimeFormat_SMPTESeconds:
		*seconds = time->time.seconds - clock->smpteOffset;
		return noErr;
	case kCAClockTimeFormat_SMPTETime: {
		CAClockSeconds value = 0;
		OSStatus status = CAClockSMPTETimeToSeconds(clock, &time->time.smpte, &value);
		if (!status)
			*seconds = value;
		return status;
	}
	case kCAClockTimeFormat_HostTime:
		if (clock->timebase != kCAClockTimebase_HostTime)
			return kCAClock_InvalidUnitError;
		if (!clock->playing)
			return kCAClock_InvalidUnitError;
		*seconds = clock->startSeconds +
		    (hostSeconds(time->time.hostTime) - clock->startHostSeconds) * clock->playRate;
		return noErr;
	case kCAClockTimeFormat_Samples:
		return kCAClock_InvalidUnitError;
	case kCAClockTimeFormat_AbsoluteSeconds:
		*seconds = time->time.seconds;
		return noErr;
	default:
		return kCAClock_InvalidTimeFormatError;
	}
}

static OSStatus setTimeFromSeconds(CAClockRef clock, Float64 seconds, CAClockTimeFormat format, CAClockTime *out)
{
	if (!out || !isfinite(seconds))
		return kCAClock_InvalidTimeFormatError;
	memset(out, 0, sizeof(*out));
	out->format = format;
	switch (format) {
	case kCAClockTimeFormat_Seconds:
		out->time.seconds = seconds;
		return noErr;
	case kCAClockTimeFormat_Beats:
		out->time.beats = beatsForSeconds(clock, seconds);
		return noErr;
	case kCAClockTimeFormat_SMPTESeconds:
		out->time.seconds = seconds + clock->smpteOffset;
		return noErr;
	case kCAClockTimeFormat_SMPTETime:
		return CAClockSecondsToSMPTETime(clock, seconds, 80, &out->time.smpte);
	case kCAClockTimeFormat_HostTime:
		if (clock->timebase != kCAClockTimebase_HostTime || !clock->playing)
			return kCAClock_InvalidUnitError;
		out->time.hostTime = clock->startHostTime + hostTicks((seconds - clock->startSeconds) / clock->playRate);
		return noErr;
	case kCAClockTimeFormat_Samples:
		return kCAClock_InvalidUnitError;
	case kCAClockTimeFormat_AbsoluteSeconds:
		out->time.seconds = seconds;
		return noErr;
	default:
		return kCAClock_InvalidTimeFormatError;
	}
}

OSStatus CAClockNew(UInt32 flags, CAClockRef *outClock)
{
	if (!outClock || flags)
		return kAudio_ParamError;
	*outClock = NULL;
	CAClockRef clock = calloc(1, sizeof(*clock));
	if (!clock)
		return kFinchMemoryFullError;
	clock->timebase = kCAClockTimebase_HostTime;
	clock->syncMode = kCAClockSyncMode_Internal;
	clock->smpteFormat = kSMPTETimeType30;
	clock->mtcFreewheel = 1.0;
	clock->playRate = 1.0;
	clock->tempoCount = 1;
	clock->tempos = calloc(1, sizeof(*clock->tempos));
	clock->meterCount = 1;
	clock->meters = calloc(1, sizeof(*clock->meters));
	if (!clock->tempos || !clock->meters) {
		free(clock->tempos);
		free(clock->meters);
		free(clock);
		return kFinchMemoryFullError;
	}
	clock->tempos[0] = (CATempoMapEntry){0, 120};
	clock->meters[0] = (CAMeterTrackEntry){0, 4, 4};
	clock->startHostTime = mach_absolute_time();
	clock->startHostSeconds = hostSeconds(clock->startHostTime);
	*outClock = clock;
	return noErr;
}

OSStatus CAClockDispose(CAClockRef clock)
{
	if (!clock)
		return kAudio_ParamError;
	ClockListener *listener = clock->listeners;
	while (listener) {
		ClockListener *next = listener->next;
		free(listener);
		listener = next;
	}
	if (clock->name)
		CFRelease(clock->name);
	free(clock->midiDestinations);
	free(clock->mtcDestinations);
	free(clock->tempos);
	free(clock->meters);
	free(clock);
	return noErr;
}

OSStatus CAClockGetPropertyInfo(CAClockRef clock, CAClockPropertyID property,
	UInt32 *size, Boolean *writable)
{
	if (!clock)
		return kAudio_ParamError;
	UInt32 valueSize = propertySize(clock, property);
	if (valueSize == UINT32_MAX)
		return kCAClock_UnknownPropertyError;
	if (size)
		*size = valueSize;
	if (writable)
		*writable = true;
	return noErr;
}

OSStatus CAClockGetProperty(CAClockRef clock, CAClockPropertyID property,
	UInt32 *ioSize, void *output)
{
	if (!clock || !ioSize)
		return kAudio_ParamError;
	UInt32 size = propertySize(clock, property);
	if (size == UINT32_MAX)
		return kCAClock_UnknownPropertyError;
	if (*ioSize < size || (size && !output)) {
		*ioSize = size;
		return kCAClock_InvalidPropertySizeError;
	}
	if (size)
		memcpy(output, propertyValue(clock, property), size);
	*ioSize = size;
	return noErr;
}

static bool validTempoMap(const CATempoMapEntry *entries, UInt32 count)
{
	if (!count)
		return true;
	if (!entries || entries[0].beats != 0)
		return false;
	for (UInt32 i = 0; i < count; i++) {
		if (!isfinite(entries[i].beats) || !isfinite(entries[i].tempoBPM) || entries[i].tempoBPM <= 0 ||
		    (i && entries[i].beats <= entries[i - 1].beats))
			return false;
	}
	return true;
}

static bool validMeterMap(const CAMeterTrackEntry *entries, UInt32 count)
{
	if (!count)
		return true;
	if (!entries || entries[0].beats != 0)
		return false;
	for (UInt32 i = 0; i < count; i++) {
		UInt16 denom = entries[i].meterDenom;
		if (!isfinite(entries[i].beats) || !entries[i].meterNumer || !denom || (denom & (denom - 1)) ||
		    (i && entries[i].beats <= entries[i - 1].beats))
			return false;
	}
	return true;
}

OSStatus CAClockSetProperty(CAClockRef clock, CAClockPropertyID property,
	UInt32 size, const void *data)
{
	if (!clock || (size && !data))
		return kAudio_ParamError;
	UInt32 expected = propertySize(clock, property);
	if (expected == UINT32_MAX)
		return kCAClock_UnknownPropertyError;
	switch (property) {
	case kCAClockProperty_InternalTimebase:
		if (size != sizeof(clock->timebase)) return kCAClock_InvalidPropertySizeError;
		if (*(const CAClockTimebase *)data != kCAClockTimebase_HostTime)
			return kCAClock_InvalidTimebaseError;
		clock->timebase = *(const CAClockTimebase *)data;
		clock->timebaseSource = 0;
		break;
	case kCAClockProperty_TimebaseSource:
		if (size != sizeof(clock->timebaseSource)) return kCAClock_InvalidPropertySizeError;
		if (*(const UInt32 *)data) return kCAClock_InvalidTimebaseSourceError;
		clock->timebaseSource = 0;
		break;
	case kCAClockProperty_SyncMode:
		if (size != sizeof(clock->syncMode)) return kCAClock_InvalidPropertySizeError;
		if (*(const CAClockSyncMode *)data < kCAClockSyncMode_Internal ||
		    *(const CAClockSyncMode *)data > kCAClockSyncMode_MTCTransport)
			return kCAClock_InvalidSyncModeError;
		clock->syncMode = *(const CAClockSyncMode *)data;
		break;
	case kCAClockProperty_SyncSource:
		if (size != sizeof(clock->syncSource)) return kCAClock_InvalidPropertySizeError;
		clock->syncSource = *(const MIDIEndpointRef *)data;
		break;
	case kCAClockProperty_SMPTEFormat:
		if (size != sizeof(clock->smpteFormat)) return kCAClock_InvalidPropertySizeError;
		if (*(const CAClockSMPTEFormat *)data > kSMPTETimeType2398)
			return kCAClock_InvalidSMPTEFormatError;
		clock->smpteFormat = *(const CAClockSMPTEFormat *)data;
		break;
	case kCAClockProperty_SMPTEOffset:
		if (size != sizeof(clock->smpteOffset)) return kCAClock_InvalidPropertySizeError;
		if (!isfinite(*(const Float64 *)data)) return kCAClock_InvalidSMPTEOffsetError;
		clock->smpteOffset = *(const Float64 *)data;
		break;
	case kCAClockProperty_MIDIClockDestinations:
	case kCAClockProperty_MTCDestinations: {
		if (size % sizeof(UInt32)) return kCAClock_InvalidPropertySizeError;
		UInt32 count = size / sizeof(UInt32);
		UInt32 *copy = count ? malloc(size) : NULL;
		if (count && !copy) return kFinchMemoryFullError;
		if (size) memcpy(copy, data, size);
		if (property == kCAClockProperty_MIDIClockDestinations) {
			free(clock->midiDestinations);
			clock->midiDestinations = copy;
			clock->midiDestinationCount = count;
		} else {
			free(clock->mtcDestinations);
			clock->mtcDestinations = copy;
			clock->mtcDestinationCount = count;
		}
		break;
	}
	case kCAClockProperty_MTCFreewheelTime:
		if (size != sizeof(clock->mtcFreewheel)) return kCAClock_InvalidPropertySizeError;
		if (!isfinite(*(const Float64 *)data) || *(const Float64 *)data < 0)
			return kCAClock_InvalidPropertySizeError;
		clock->mtcFreewheel = *(const Float64 *)data;
		break;
	case kCAClockProperty_TempoMap: {
		if (size % sizeof(CATempoMapEntry)) return kCAClock_InvalidPropertySizeError;
		UInt32 count = size / sizeof(CATempoMapEntry);
		const CATempoMapEntry *entries = data;
		if (!validTempoMap(entries, count)) return kCAClock_InvalidPropertySizeError;
		CATempoMapEntry *copy = count ? malloc(size) : malloc(sizeof(*copy));
		if (!copy) return kFinchMemoryFullError;
		if (count) memcpy(copy, entries, size);
		else copy[0] = (CATempoMapEntry){0, 120};
		free(clock->tempos);
		clock->tempos = copy;
		clock->tempoCount = count ? count : 1;
		clock->overrideActive = false;
		break;
	}
	case kCAClockProperty_MeterTrack: {
		if (size % sizeof(CAMeterTrackEntry)) return kCAClock_InvalidPropertySizeError;
		UInt32 count = size / sizeof(CAMeterTrackEntry);
		const CAMeterTrackEntry *entries = data;
		if (!validMeterMap(entries, count)) return kCAClock_InvalidPropertySizeError;
		CAMeterTrackEntry *copy = count ? malloc(size) : malloc(sizeof(*copy));
		if (!copy) return kFinchMemoryFullError;
		if (count) memcpy(copy, entries, size);
		else copy[0] = (CAMeterTrackEntry){0, 4, 4};
		free(clock->meters);
		clock->meters = copy;
		clock->meterCount = count ? count : 1;
		break;
	}
	case kCAClockProperty_Name: {
		if (size != sizeof(CFStringRef)) return kCAClock_InvalidPropertySizeError;
		CFStringRef name = *(CFStringRef const *)data;
		if (name && CFGetTypeID(name) != CFStringGetTypeID()) return kAudio_ParamError;
		if (clock->name) CFRelease(clock->name);
		clock->name = name ? CFRetain(name) : NULL;
		break;
	}
	case kCAClockProperty_SendMIDISPP:
		if (size != sizeof(clock->sendSPP)) return kCAClock_InvalidPropertySizeError;
		clock->sendSPP = *(const UInt32 *)data != 0;
		break;
	default:
		return kCAClock_UnknownPropertyError;
	}
	notifyListeners(clock, kCAClockMessage_PropertyChanged);
	return noErr;
}

OSStatus CAClockAddListener(CAClockRef clock, CAClockListenerProc proc, void *userData)
{
	if (!clock || !proc)
		return kAudio_ParamError;
	ClockListener *listener = malloc(sizeof(*listener));
	if (!listener)
		return kFinchMemoryFullError;
	listener->proc = proc;
	listener->userData = userData;
	listener->next = clock->listeners;
	clock->listeners = listener;
	return noErr;
}

OSStatus CAClockRemoveListener(CAClockRef clock, CAClockListenerProc proc, void *userData)
{
	if (!clock || !proc)
		return kAudio_ParamError;
	ClockListener **cursor = &clock->listeners;
	while (*cursor && ((*cursor)->proc != proc || (*cursor)->userData != userData))
		cursor = &(*cursor)->next;
	if (!*cursor)
		return kAudio_ParamError;
	ClockListener *listener = *cursor;
	*cursor = listener->next;
	free(listener);
	return noErr;
}

OSStatus CAClockSetCurrentTime(CAClockRef clock, const CAClockTime *time)
{
	if (!clock || !time)
		return kAudio_ParamError;
	if (clock->playing)
		return kCAClock_CannotSetTimeError;
	Float64 seconds = 0;
	OSStatus status = getTimeSeconds(clock, time, &seconds);
	if (status)
		return status;
	clock->positionSeconds = seconds;
	clock->startSeconds = seconds;
	clock->startHostTime = mach_absolute_time();
	clock->startHostSeconds = hostSeconds(clock->startHostTime);
	notifyListeners(clock, kCAClockMessage_StartTimeSet);
	return noErr;
}

OSStatus CAClockGetCurrentTime(CAClockRef clock, CAClockTimeFormat format, CAClockTime *out)
{
	if (!clock || !out)
		return kAudio_ParamError;
	return setTimeFromSeconds(clock, currentSeconds(clock, mach_absolute_time()), format, out);
}

OSStatus CAClockGetStartTime(CAClockRef clock, CAClockTimeFormat format, CAClockTime *out)
{
	if (!clock || !out)
		return kAudio_ParamError;
	return setTimeFromSeconds(clock, clock->startSeconds, format, out);
}

OSStatus CAClockTranslateTime(CAClockRef clock, const CAClockTime *time,
	CAClockTimeFormat format, CAClockTime *out)
{
	if (!clock || !time || !out)
		return kAudio_ParamError;
	Float64 seconds = 0;
	OSStatus status = getTimeSeconds(clock, time, &seconds);
	return status ? status : setTimeFromSeconds(clock, seconds, format, out);
}

OSStatus CAClockStart(CAClockRef clock)
{
	if (!clock)
		return kAudio_ParamError;
	if (clock->playing)
		return noErr;
	clock->startSeconds = clock->positionSeconds;
	clock->startHostTime = mach_absolute_time();
	clock->startHostSeconds = hostSeconds(clock->startHostTime);
	clock->playing = true;
	clock->overrideActive = false;
	notifyListeners(clock, kCAClockMessage_Started);
	return noErr;
}

OSStatus CAClockStop(CAClockRef clock)
{
	if (!clock)
		return kAudio_ParamError;
	if (!clock->playing)
		return noErr;
	clock->positionSeconds = currentSeconds(clock, mach_absolute_time());
	clock->playing = false;
	clock->overrideActive = false;
	notifyListeners(clock, kCAClockMessage_Stopped);
	return noErr;
}

OSStatus CAClockArm(CAClockRef clock)
{
	if (!clock)
		return kAudio_ParamError;
	if (!clock->armed) {
		clock->armed = true;
		notifyListeners(clock, kCAClockMessage_Armed);
	}
	return noErr;
}

OSStatus CAClockDisarm(CAClockRef clock)
{
	if (!clock)
		return kAudio_ParamError;
	if (clock->armed) {
		clock->armed = false;
		notifyListeners(clock, kCAClockMessage_Disarmed);
	}
	return noErr;
}

OSStatus CAClockSetPlayRate(CAClockRef clock, Float64 rate)
{
	if (!clock || !isfinite(rate) || rate <= 0)
		return kCAClock_InvalidPlayRateError;
	if (clock->playing) {
		clock->positionSeconds = currentSeconds(clock, mach_absolute_time());
		clock->startSeconds = clock->positionSeconds;
		clock->startHostTime = mach_absolute_time();
		clock->startHostSeconds = hostSeconds(clock->startHostTime);
	}
	clock->playRate = rate;
	return noErr;
}

OSStatus CAClockGetPlayRate(CAClockRef clock, Float64 *outRate)
{
	if (!clock || !outRate)
		return kAudio_ParamError;
	*outRate = clock->playRate;
	return noErr;
}

OSStatus CAClockGetCurrentTempo(CAClockRef clock, CAClockTempo *outTempo, CAClockTime *timestamp)
{
	if (!clock || !outTempo)
		return kAudio_ParamError;
	Float64 beat = beatsForSeconds(clock, currentSeconds(clock, mach_absolute_time()));
	Float64 changed = 0;
	*outTempo = tempoForBeat(clock, beat, &changed);
	if (timestamp) {
		memset(timestamp, 0, sizeof(*timestamp));
		timestamp->format = kCAClockTimeFormat_Beats;
		timestamp->time.beats = changed;
	}
	return noErr;
}

OSStatus CAClockSetCurrentTempo(CAClockRef clock, CAClockTempo tempo, const CAClockTime *timestamp)
{
	if (!clock || !isfinite(tempo) || tempo <= 0)
		return kAudio_ParamError;
	if (!clock->playing)
		return kCAClock_CannotSetTimeError;
	Float64 beat = beatsForSeconds(clock, currentSeconds(clock, mach_absolute_time()));
	if (timestamp) {
		Float64 seconds = 0;
		OSStatus status = getTimeSeconds(clock, timestamp, &seconds);
		if (status)
			return status;
		beat = beatsForSeconds(clock, seconds);
	}
	clock->overrideTempo = tempo;
	clock->overrideBeat = beat;
	clock->overrideActive = true;
	return noErr;
}

static Float64 framesPerSecond(CAClockSMPTEFormat format)
{
	switch (format) {
	case kSMPTETimeType24: return 24;
	case kSMPTETimeType25: return 25;
	case kSMPTETimeType30Drop: return 30000.0 / 1001.0;
	case kSMPTETimeType30: return 30;
	case kSMPTETimeType2997: return 30000.0 / 1001.0;
	case kSMPTETimeType2997Drop: return 30000.0 / 1001.0;
	case kSMPTETimeType60: return 60;
	case kSMPTETimeType5994: return 60000.0 / 1001.0;
	case kSMPTETimeType60Drop: return 60000.0 / 1001.0;
	case kSMPTETimeType5994Drop: return 60000.0 / 1001.0;
	case kSMPTETimeType50: return 50;
	case kSMPTETimeType2398: return 24000.0 / 1001.0;
	default: return 0;
	}
}

static UInt32 nominalFrames(CAClockSMPTEFormat format)
{
	return format == kSMPTETimeType24 ? 24 :
	    format == kSMPTETimeType25 || format == kSMPTETimeType50 ?
	        (format == kSMPTETimeType50 ? 50 : 25) :
	    format == kSMPTETimeType60 || format == kSMPTETimeType60Drop ? 60 :
	    format == kSMPTETimeType5994 || format == kSMPTETimeType5994Drop ? 60 :
	    format == kSMPTETimeType2398 ? 24 :
	    format == kSMPTETimeType2997 || format == kSMPTETimeType2997Drop ? 30 : 30;
}

static UInt32 dropFrames(CAClockSMPTEFormat format)
{
	return format == kSMPTETimeType30Drop || format == kSMPTETimeType2997Drop ? 2 :
	    format == kSMPTETimeType60Drop || format == kSMPTETimeType5994Drop ? 4 : 0;
}

OSStatus CAClockSecondsToSMPTETime(CAClockRef clock, CAClockSeconds seconds,
	UInt16 subframeDivisor, SMPTETime *outTime)
{
	if (!clock || !outTime || !isfinite(seconds) || !subframeDivisor)
		return kCAClock_InvalidSMPTEFormatError;
	Float64 fps = framesPerSecond(clock->smpteFormat);
	if (!fps)
		return kCAClock_InvalidSMPTEFormatError;
	Float64 absolute = seconds + clock->smpteOffset;
	if (absolute < 0)
		return kCAClock_InvalidSMPTEOffsetError;
	UInt32 nominal = nominalFrames(clock->smpteFormat);
	UInt32 drop = dropFrames(clock->smpteFormat);
	UInt64 frame = (UInt64)floor(absolute * fps + 0.5);
	UInt64 labelFrame = frame;
	if (drop) {
		UInt64 perTenMinutes = (UInt64)nominal * 600 - (UInt64)drop * 9;
		UInt64 d = frame / perTenMinutes;
		UInt64 m = frame % perTenMinutes;
		labelFrame += (UInt64)drop * 9 * d;
		if (m >= drop)
			labelFrame += (UInt64)drop * ((m - drop) / ((UInt64)nominal * 60 - drop));
	}
	memset(outTime, 0, sizeof(*outTime));
	outTime->mType = clock->smpteFormat;
	outTime->mFlags = kSMPTETimeValid;
	outTime->mSubframeDivisor = subframeDivisor;
	outTime->mHours = (SInt16)(labelFrame / ((UInt64)nominal * 3600) % 24);
	labelFrame %= (UInt64)nominal * 3600;
	outTime->mMinutes = (SInt16)(labelFrame / ((UInt64)nominal * 60));
	labelFrame %= (UInt64)nominal * 60;
	outTime->mSeconds = (SInt16)(labelFrame / nominal);
	outTime->mFrames = (SInt16)(labelFrame % nominal);
	return noErr;
}

OSStatus CAClockSMPTETimeToSeconds(CAClockRef clock, const SMPTETime *time, CAClockSeconds *outSeconds)
{
	if (!clock || !time || !outSeconds)
		return kAudio_ParamError;
	Float64 fps = framesPerSecond(time->mType);
	UInt32 nominal = nominalFrames(time->mType);
	if (!fps || time->mHours < 0 || time->mMinutes < 0 || time->mMinutes >= 60 ||
	    time->mSeconds < 0 || time->mSeconds >= 60 || time->mFrames < 0 ||
	    time->mFrames >= (SInt16)nominal)
		return kCAClock_InvalidSMPTEFormatError;
	UInt64 frame = (((UInt64)time->mHours * 3600 + (UInt64)time->mMinutes * 60 +
	    (UInt64)time->mSeconds) * nominal) + (UInt64)time->mFrames;
	UInt32 drop = dropFrames(time->mType);
	if (drop) {
		UInt64 totalMinutes = (UInt64)time->mHours * 60 + (UInt64)time->mMinutes;
		UInt64 dropped = (UInt64)drop * (totalMinutes - totalMinutes / 10);
		frame -= dropped;
	}
	Float64 subframe = time->mSubframeDivisor
	    ? (Float64)time->mSubframes / time->mSubframeDivisor
	    : 0;
	*outSeconds = (Float64)frame / fps + subframe / fps - clock->smpteOffset;
	return noErr;
}

OSStatus CAClockBeatsToBarBeatTime(CAClockRef clock, CAClockBeats beats,
	UInt16 divisor, CABarBeatTime *outTime)
{
	if (!clock || !outTime || !isfinite(beats) || beats < 0 || !divisor)
		return kAudio_ParamError;
	UInt64 bars = 0;
	Float64 start = 0;
	UInt16 numerator = 4, denominator = 4;
	for (UInt32 i = 0; i < clock->meterCount; i++) {
		CAMeterTrackEntry entry = clock->meters[i];
		if (entry.beats <= start)
			continue;
		if (beats < entry.beats)
			break;
		Float64 barLength = numerator * 4.0 / denominator;
		bars += (UInt64)floor((entry.beats - start) / barLength);
		start = entry.beats;
		numerator = entry.meterNumer;
		denominator = entry.meterDenom;
	}
	Float64 barLength = numerator * 4.0 / denominator;
	Float64 position = beats - start;
	if (position < 0)
		position = 0;
	UInt64 inBars = (UInt64)floor(position / barLength);
	bars += inBars;
	position -= inBars * barLength;
	Float64 beatLength = 4.0 / denominator;
	UInt64 beat = (UInt64)floor(position / beatLength);
	Float64 fraction = position / beatLength - beat;
	UInt64 subbeat = (UInt64)floor(fraction * divisor + 0.5);
	if (subbeat >= divisor) {
		beat++;
		subbeat = 0;
	}
	if (beat >= numerator) {
		bars++;
		beat = 0;
	}
	if (bars >= INT32_MAX)
		return kAudio_ParamError;
	memset(outTime, 0, sizeof(*outTime));
	outTime->bar = (SInt32)bars + 1;
	outTime->beat = (UInt16)beat + 1;
	outTime->subbeat = (UInt16)subbeat;
	outTime->subbeatDivisor = divisor;
	return noErr;
}

OSStatus CAClockBarBeatTimeToBeats(CAClockRef clock, const CABarBeatTime *time,
	CAClockBeats *outBeats)
{
	if (!clock || !time || !outBeats || time->bar < 1 || time->beat < 1 || !time->subbeatDivisor)
		return kAudio_ParamError;
	UInt64 remainingBars = (UInt64)time->bar - 1;
	UInt16 numerator = 4, denominator = 4;
	Float64 startBeat = 0;
	for (UInt32 i = 1; i < clock->meterCount; i++) {
		CAMeterTrackEntry entry = clock->meters[i];
		Float64 barLength = numerator * 4.0 / denominator;
		UInt64 barsUntilChange = (UInt64)floor((entry.beats - startBeat) / barLength);
		if (remainingBars < barsUntilChange)
			break;
		remainingBars -= barsUntilChange;
		startBeat = entry.beats;
		numerator = entry.meterNumer;
		denominator = entry.meterDenom;
	}
	if (time->beat > numerator)
		return kAudio_ParamError;
	Float64 unit = 4.0 / denominator;
	*outBeats = startBeat + remainingBars * numerator * unit +
	    (time->beat - 1 + (Float64)time->subbeat / time->subbeatDivisor) * unit;
	return noErr;
}

static void applyExternalStart(CAClockRef clock, Float64 beat)
{
	clock->positionSeconds = secondsForBeats(clock, beat);
	clock->startSeconds = clock->positionSeconds;
	clock->startHostTime = mach_absolute_time();
	clock->startHostSeconds = hostSeconds(clock->startHostTime);
	clock->playing = true;
	clock->armed = false;
	notifyListeners(clock, kCAClockMessage_StartTimeSet);
	notifyListeners(clock, kCAClockMessage_Started);
}

OSStatus CAClockParseMIDI(CAClockRef clock, const MIDIPacketList *packets)
{
	if (!clock || !packets)
		return kAudio_ParamError;
	const MIDIPacket *packet = &packets->packet[0];
	for (UInt32 p = 0; p < packets->numPackets; p++) {
		for (UInt16 i = 0; i < packet->length; i++) {
			UInt8 message = packet->data[i];
			if (message == 0xFA || message == 0xFB) {
				if (clock->syncMode == kCAClockSyncMode_MIDIClockTransport &&
				    (clock->armed || message == 0xFB))
					applyExternalStart(clock, message == 0xFA ? 0 : beatsForSeconds(clock, clock->positionSeconds));
			} else if (message == 0xFC && clock->syncMode == kCAClockSyncMode_MIDIClockTransport) {
				CAClockStop(clock);
			} else if (message == 0xF8 && clock->playing &&
			    clock->syncMode == kCAClockSyncMode_MIDIClockTransport) {
				Float64 beat = beatsForSeconds(clock, currentSeconds(clock, packet->timeStamp));
				clock->positionSeconds = secondsForBeats(clock, beat + 1.0 / 24.0);
				clock->startSeconds = clock->positionSeconds;
				clock->startHostTime = packet->timeStamp;
				clock->startHostSeconds = hostSeconds(packet->timeStamp);
			} else if (message == 0xF2 && i + 2 < packet->length &&
			    clock->syncMode == kCAClockSyncMode_MIDIClockTransport) {
				UInt32 position = packet->data[i + 1] | ((UInt32)packet->data[i + 2] << 7);
				clock->positionSeconds = secondsForBeats(clock, position / 4.0);
				if (!clock->playing)
					clock->startSeconds = clock->positionSeconds;
				i += 2;
			}
		}
		if (p + 1 < packets->numPackets)
			packet = MIDIPacketNext(packet);
	}
	return noErr;
}
