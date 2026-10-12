/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AVAudioUnit and its kinds (effects, time effects, generators, MIDI instruments) and
 * the units AVFAudio names (delay, distortion, EQ, reverb, time-pitch, varispeed,
 * sampler), Finch's: nodes in AVAudioEngine's graph over AudioToolbox's audio units.
 *
 * A unit renders in place at its output format; a unit whose input is connected in
 * another format puts out silence, as Apple's do. A time effect pulls its input as it
 * needs it, on a timeline of its own, so the input runs at the unit's rate.
 *
 * The named units' properties are the units' parameters. Once read or set, a property
 * keeps its value (loading a preset or setting the parameter on the audio unit does not
 * change it, as with Apple's); until then it is the parameter's value.
 */
#import "AVAudioNodeInternal.h"

#define kFinchNBandEQProperty_BandLimit 0x666e626c /* (AudioToolbox's AudioUnitEffects.h) */
#define MAX_CACHED 8

static NSString *const AVFAudioErrorDomain = @"com.apple.coreaudio.avfaudio";

@interface AVAudioUnit () {
@public
    AudioComponentDescription _description;
    AudioUnit _unit;
    AVAudioFormat *_unitFormat; /* (the format the unit was initialized with) */
    UInt32 _unitFrames;
    AVAudioFramePosition _renderTime, _inputTime;
    BOOL _timeEffect;
    /* properties set by the user, standing for their parameters */
    float _cached[MAX_CACHED];
    BOOL _isSet[MAX_CACHED];
}
- (instancetype)_initWithDescription:(AudioComponentDescription)description;
@end

static void
au_set(AVAudioUnit *u, AudioUnitParameterID id, float v)
{
    if (u->_unit)
        AudioUnitSetParameter(u->_unit, id, kAudioUnitScope_Global, 0, v, 0);
}

static float
au_get(AVAudioUnit *u, AudioUnitParameterID id)
{
    AudioUnitParameterValue v = 0;
    if (u->_unit)
        AudioUnitGetParameter(u->_unit, id, kAudioUnitScope_Global, 0, &v);
    return v;
}

/* A property standing for a parameter (slot: where it is kept once read or set). */
static float
property(AVAudioUnit *u, int slot, AudioUnitParameterID id)
{
    if (!u->_isSet[slot]) {
        u->_cached[slot] = au_get(u, id);
        u->_isSet[slot] = YES;
    }
    return u->_cached[slot];
}

static void
set_property(AVAudioUnit *u, int slot, AudioUnitParameterID id, float v)
{
    u->_cached[slot] = v;
    u->_isSet[slot] = YES;
    au_set(u, id, v);
}

static NSError *
status_error(OSStatus status)
{
    return [NSError errorWithDomain:AVFAudioErrorDomain code:status userInfo:nil];
}

/* Pulls the unit's input for its audio unit. */
static OSStatus
input_proc(void *refcon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, UInt32 bus, UInt32 frames,
    AudioBufferList *data)
{
    (void)flags, (void)timestamp, (void)bus;
    AVAudioUnit *u = refcon;
    AVAudioFramePosition when = u->_timeEffect ? u->_inputTime : u->_renderTime;
    if (u->_timeEffect)
        u->_inputTime += frames;
    AVAudioPCMBuffer *in = nil;
    OSStatus e = finch_pull_input(u, 0, frames, when, &in);
    for (UInt32 i = 0; i < data->mNumberBuffers; i++) {
        float *to = data->mBuffers[i].mData;
        if (!e && in && i < in.format.channelCount && in.floatChannelData)
            memcpy(to, in.floatChannelData[i], frames * sizeof(float));
        else
            memset(to, 0, frames * sizeof(float));
    }
    return noErr;
}

@implementation AVAudioUnit

+ (void)instantiateWithComponentDescription:(AudioComponentDescription)description options:(AudioComponentInstantiationOptions)options
                         completionHandler:(void (^)(__kindof AVAudioUnit *, NSError *))completionHandler
{
    (void)options;
    AudioComponentDescription query = description;
    if (!AudioComponentFindNext(NULL, &query)) {
        completionHandler(nil, [NSError errorWithDomain:NSOSStatusErrorDomain code:-3000 userInfo:nil]);
        return;
    }
    Class kind;
    switch (description.componentType) {
    case kAudioUnitType_Effect:
    case kAudioUnitType_MusicEffect:
        kind = [AVAudioUnitEffect class];
        break;
    case kAudioUnitType_FormatConverter:
        kind = [AVAudioUnitTimeEffect class];
        break;
    case kAudioUnitType_MusicDevice:
        kind = [AVAudioUnitMIDIInstrument class];
        break;
    case kAudioUnitType_Generator:
        kind = [AVAudioUnitGenerator class];
        break;
    default:
        kind = [AVAudioUnit class];
        break;
    }
    /* (in process, so at once, as Apple's are) */
    AVAudioUnit *u = [[kind alloc] _initWithDescription:description];
    completionHandler(u, nil);
    [u release];
}

- (instancetype)_initWithDescription:(AudioComponentDescription)description
{
    AudioComponentDescription query = description;
    AudioComponent c = AudioComponentFindNext(NULL, &query);
    if (!c) {
        [self release];
        [NSException raise:AVFAudioErrorDomain format:@"required condition is false: comp != nullptr"];
    }
    if ((self = [super init])) {
        AudioComponentGetDescription(c, &_description);
        AudioComponentInstanceNew(c, &_unit);
        _timeEffect = _description.componentType == kAudioUnitType_FormatConverter;
        UInt32 n = 0, size = sizeof n;
        _inputs = AudioUnitGetProperty(_unit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &n, &size) ? 0 : n;
        size = sizeof n;
        _outputs = AudioUnitGetProperty(_unit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Output, 0, &n, &size) ? 1 : n;
        if (_inputs) {
            AURenderCallbackStruct cb = {input_proc, self};
            AudioUnitSetProperty(_unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb);
        }
    }
    return self;
}

- (void)dealloc
{
    if (_unit) {
        AudioUnitUninitialize(_unit);
        AudioComponentInstanceDispose(_unit);
    }
    [_unitFormat release];
    [super dealloc];
}

- (AudioComponentDescription)audioComponentDescription
{
    return _description;
}

- (AudioUnit)audioUnit
{
    return _unit;
}

/* The component's name, "Manufacturer: Name", in its two parts. */
- (NSArray *)_nameParts
{
    if (!_unit)
        return nil;
    CFStringRef name = NULL;
    if (AudioComponentCopyName(AudioComponentInstanceGetComponent(_unit), &name) || !name)
        return nil;
    NSString *s = [(NSString *)name autorelease];
    NSRange r = [s rangeOfString:@": "];
    if (r.location == NSNotFound)
        return @[ @"", s ];
    return @[ [s substringToIndex:r.location], [s substringFromIndex:NSMaxRange(r)] ];
}

- (NSString *)name
{
    return [self _nameParts][1];
}

- (NSString *)manufacturerName
{
    return [self _nameParts][0];
}

- (NSUInteger)version
{
    UInt32 v = 0;
    if (_unit)
        AudioComponentGetVersion(AudioComponentInstanceGetComponent(_unit), &v);
    return v;
}

- (NSTimeInterval)latency
{
    Float64 v = 0;
    UInt32 size = sizeof v;
    if (_unit)
        AudioUnitGetProperty(_unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &v, &size);
    return v;
}

- (BOOL)loadAudioUnitPresetAtURL:(NSURL *)url error:(NSError **)outError
{
    NSDictionary *preset = [NSDictionary dictionaryWithContentsOfURL:url];
    OSStatus status = preset ? kAudioUnitErr_InvalidPropertyValue : -43;
    /* (a preset of one of the unit's factory presets is loaded; saved unit state is not read yet) */
    NSNumber *number = preset[@"preset-number"];
    if (_unit && [number isKindOfClass:[NSNumber class]] && number.intValue >= 0) {
        AUPreset p = {number.intValue, NULL};
        status = AudioUnitSetProperty(_unit, kAudioUnitProperty_PresentPreset, kAudioUnitScope_Global, 0, &p, sizeof p);
    }
    if (status && outError)
        *outError = status_error(status);
    return status == noErr;
}

- (void)reset
{
    if (_unit)
        AudioUnitReset(_unit, kAudioUnitScope_Global, 0);
    _inputTime = 0;
}

- (BOOL)_bypass
{
    UInt32 v = 0, size = sizeof v;
    if (_unit)
        AudioUnitGetProperty(_unit, kAudioUnitProperty_BypassEffect, kAudioUnitScope_Global, 0, &v, &size);
    return v != 0;
}

- (void)_setBypass:(BOOL)bypass
{
    UInt32 v = bypass ? 1 : 0;
    if (_unit)
        AudioUnitSetProperty(_unit, kAudioUnitProperty_BypassEffect, kAudioUnitScope_Global, 0, &v, sizeof v);
}

/* Readies the audio unit to render frames at format. */
- (BOOL)_prepare:(AVAudioFormat *)format frames:(AVAudioFrameCount)frames
{
    if (!_unit)
        return NO;
    if (_unitFormat && [_unitFormat isEqual:format] && frames <= _unitFrames)
        return YES;
    AudioUnitUninitialize(_unit);
    UInt32 max = frames > 4096 ? frames : 4096;
    AudioUnitSetProperty(_unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &max, sizeof max);
    const AudioStreamBasicDescription *asbd = format.streamDescription;
    if (_inputs && AudioUnitSetProperty(_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, asbd, sizeof *asbd))
        return NO;
    if (AudioUnitSetProperty(_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, asbd, sizeof *asbd))
        return NO;
    if (AudioUnitInitialize(_unit))
        return NO;
    [_unitFormat release];
    _unitFormat = [format retain];
    _unitFrames = max;
    return YES;
}

- (OSStatus)_render:(AVAudioPCMBuffer *)out bus:(AVAudioNodeBus)bus at:(AVAudioFramePosition)time
{
    AVAudioFrameCount frames = out.frameLength;
    AVAudioFormat *format = out.format;
    AVAudioFormat *input = _inputs ? _in[0].format : nil;
    BOOL matches = !input || (input.channelCount == format.channelCount && input.sampleRate == format.sampleRate &&
                                 input.commonFormat == AVAudioPCMFormatFloat32 && !input.interleaved);
    if (bus != 0 || !matches || ![self _prepare:format frames:frames]) {
        zero(out, frames);
        return noErr;
    }
    _renderTime = time;
    AudioBufferList *abl = out.mutableAudioBufferList;
    for (UInt32 i = 0; i < abl->mNumberBuffers; i++)
        abl->mBuffers[i].mDataByteSize = frames * sizeof(float);
    AudioTimeStamp ts = {0};
    ts.mSampleTime = (Float64)time;
    ts.mFlags = kAudioTimeStampSampleTimeValid;
    AudioUnitRenderActionFlags flags = 0;
    OSStatus e = AudioUnitRender(_unit, &flags, &ts, 0, frames, abl);
    out.frameLength = frames;
    if (e)
        zero(out, frames);
    return noErr;
}

@end

/* --- the kinds of unit --- */

@implementation AVAudioUnitEffect

- (instancetype)initWithAudioComponentDescription:(AudioComponentDescription)description
{
    return [self _initWithDescription:description];
}

- (BOOL)bypass
{
    return [self _bypass];
}

- (void)setBypass:(BOOL)bypass
{
    [self _setBypass:bypass];
}

@end

@implementation AVAudioUnitTimeEffect

- (instancetype)initWithAudioComponentDescription:(AudioComponentDescription)description
{
    return [self _initWithDescription:description];
}

- (BOOL)bypass
{
    return [self _bypass];
}

- (void)setBypass:(BOOL)bypass
{
    [self _setBypass:bypass];
}

@end

@implementation AVAudioUnitGenerator

- (instancetype)initWithAudioComponentDescription:(AudioComponentDescription)description
{
    return [self _initWithDescription:description];
}

- (BOOL)bypass
{
    return [self _bypass];
}

- (void)setBypass:(BOOL)bypass
{
    [self _setBypass:bypass];
}

MIXING_ACCESSORS

@end

@implementation AVAudioUnitMIDIInstrument

- (instancetype)initWithAudioComponentDescription:(AudioComponentDescription)description
{
    return [self _initWithDescription:description];
}

MIXING_ACCESSORS

- (void)sendMIDIEvent:(uint8_t)midiStatus data1:(uint8_t)data1 data2:(uint8_t)data2
{
    if (_unit)
        MusicDeviceMIDIEvent(_unit, midiStatus, data1, data2, 0);
}

- (void)sendMIDIEvent:(uint8_t)midiStatus data1:(uint8_t)data1
{
    [self sendMIDIEvent:midiStatus data1:data1 data2:0];
}

- (void)startNote:(uint8_t)note withVelocity:(uint8_t)velocity onChannel:(uint8_t)channel
{
    [self sendMIDIEvent:0x90 | (channel & 0xF) data1:note data2:velocity];
}

- (void)stopNote:(uint8_t)note onChannel:(uint8_t)channel
{
    [self sendMIDIEvent:0x80 | (channel & 0xF) data1:note data2:0];
}

- (void)sendController:(uint8_t)controller withValue:(uint8_t)value onChannel:(uint8_t)channel
{
    [self sendMIDIEvent:0xB0 | (channel & 0xF) data1:controller data2:value];
}

- (void)sendPitchBend:(uint16_t)pitchbend onChannel:(uint8_t)channel
{
    [self sendMIDIEvent:0xE0 | (channel & 0xF) data1:pitchbend & 0x7F data2:(pitchbend >> 7) & 0x7F];
}

- (void)sendPressure:(uint8_t)pressure onChannel:(uint8_t)channel
{
    [self sendMIDIEvent:0xD0 | (channel & 0xF) data1:pressure];
}

- (void)sendPressureForKey:(uint8_t)key withValue:(uint8_t)value onChannel:(uint8_t)channel
{
    [self sendMIDIEvent:0xA0 | (channel & 0xF) data1:key data2:value];
}

- (void)sendProgramChange:(uint8_t)program onChannel:(uint8_t)channel
{
    [self sendMIDIEvent:0xC0 | (channel & 0xF) data1:program];
}

- (void)sendProgramChange:(uint8_t)program bankMSB:(uint8_t)bankMSB bankLSB:(uint8_t)bankLSB onChannel:(uint8_t)channel
{
    [self sendController:0 withValue:bankMSB onChannel:channel];
    [self sendController:32 withValue:bankLSB onChannel:channel];
    [self sendProgramChange:program onChannel:channel];
}

- (void)sendMIDISysExEvent:(NSData *)midiData
{
    if (_unit)
        MusicDeviceSysEx(_unit, midiData.bytes, (UInt32)midiData.length);
}

- (void)sendMIDIEventList:(const struct MIDIEventList *)eventList
{
    (void)eventList; /* (MIDI 2.0 event lists: not yet) */
}

@end

/* --- the named units --- */

static AudioComponentDescription
apple(OSType type, OSType subtype)
{
    return (AudioComponentDescription){type, subtype, kAudioUnitManufacturer_Apple, 0, 0};
}

@implementation AVAudioUnitDelay

- (instancetype)init
{
    return [self initWithAudioComponentDescription:apple(kAudioUnitType_Effect, kAudioUnitSubType_Delay)];
}

- (NSTimeInterval)delayTime { return property(self, 0, kDelayParam_DelayTime); }
- (void)setDelayTime:(NSTimeInterval)v { set_property(self, 0, kDelayParam_DelayTime, (float)v); }
- (float)feedback { return property(self, 1, kDelayParam_Feedback); }
- (void)setFeedback:(float)v { set_property(self, 1, kDelayParam_Feedback, v); }
- (float)lowPassCutoff { return property(self, 2, kDelayParam_LopassCutoff); }
- (void)setLowPassCutoff:(float)v { set_property(self, 2, kDelayParam_LopassCutoff, v); }
- (float)wetDryMix { return property(self, 3, kDelayParam_WetDryMix); }
- (void)setWetDryMix:(float)v { set_property(self, 3, kDelayParam_WetDryMix, v); }

@end

@implementation AVAudioUnitDistortion

- (instancetype)init
{
    return [self initWithAudioComponentDescription:apple(kAudioUnitType_Effect, kAudioUnitSubType_Distortion)];
}

- (void)loadFactoryPreset:(AVAudioUnitDistortionPreset)preset
{
    AUPreset p = {(SInt32)preset, NULL};
    if (_unit)
        AudioUnitSetProperty(_unit, kAudioUnitProperty_PresentPreset, kAudioUnitScope_Global, 0, &p, sizeof p);
}

- (float)preGain { return property(self, 0, kDistortionParam_SoftClipGain); }
- (void)setPreGain:(float)v { set_property(self, 0, kDistortionParam_SoftClipGain, v); }
- (float)wetDryMix { return property(self, 1, kDistortionParam_FinalMix); }
- (void)setWetDryMix:(float)v { set_property(self, 1, kDistortionParam_FinalMix, v); }

@end

@implementation AVAudioUnitReverb

- (instancetype)init
{
    if ((self = [self initWithAudioComponentDescription:apple(kAudioUnitType_Effect, kAudioUnitSubType_MatrixReverb)]))
        [self loadFactoryPreset:AVAudioUnitReverbPresetMediumHall];
    return self;
}

- (void)loadFactoryPreset:(AVAudioUnitReverbPreset)preset
{
    AUPreset p = {(SInt32)preset, NULL};
    if (_unit)
        AudioUnitSetProperty(_unit, kAudioUnitProperty_PresentPreset, kAudioUnitScope_Global, 0, &p, sizeof p);
    /* (a mix read or set stays) */
    if (_isSet[0])
        au_set(self, kReverbParam_DryWetMix, _cached[0]);
}

- (float)wetDryMix { return property(self, 0, kReverbParam_DryWetMix); }
- (void)setWetDryMix:(float)v { set_property(self, 0, kReverbParam_DryWetMix, v); }

@end

@implementation AVAudioUnitTimePitch

- (instancetype)init
{
    return [self initWithAudioComponentDescription:apple(kAudioUnitType_FormatConverter, kAudioUnitSubType_NewTimePitch)];
}

- (float)rate { return property(self, 0, kNewTimePitchParam_Rate); }
- (void)setRate:(float)v { set_property(self, 0, kNewTimePitchParam_Rate, v); }
- (float)pitch { return property(self, 1, kNewTimePitchParam_Pitch); }
- (void)setPitch:(float)v { set_property(self, 1, kNewTimePitchParam_Pitch, v); }
- (float)overlap { return property(self, 2, kNewTimePitchParam_Smoothness); }
- (void)setOverlap:(float)v { set_property(self, 2, kNewTimePitchParam_Smoothness, v); }

@end

@implementation AVAudioUnitVarispeed

- (instancetype)init
{
    return [self initWithAudioComponentDescription:apple(kAudioUnitType_FormatConverter, kAudioUnitSubType_Varispeed)];
}

- (float)rate { return property(self, 0, kVarispeedParam_PlaybackRate); }
- (void)setRate:(float)v { set_property(self, 0, kVarispeedParam_PlaybackRate, v); }

@end

/* --- the EQ --- */

@interface AVAudioUnitEQFilterParameters () {
    AVAudioUnit *_owner; /* (weak: the EQ keeps its bands) */
    int _band;
    AVAudioUnitEQFilterType _type;
    float _frequency, _bandwidth, _gain;
    BOOL _bypass;
}
- (instancetype)_initWithOwner:(AVAudioUnit *)owner band:(int)band frequency:(float)frequency;
@end

@implementation AVAudioUnitEQFilterParameters

- (instancetype)_initWithOwner:(AVAudioUnit *)owner band:(int)band frequency:(float)frequency
{
    if ((self = [super init])) {
        _owner = owner;
        _band = band;
        _type = AVAudioUnitEQFilterTypeParametric;
        _bandwidth = 0.5f;
        _bypass = YES;
        self.frequency = frequency;
    }
    return self;
}

- (void)_push:(AudioUnitParameterID)base value:(float)v
{
    if (_owner)
        au_set(_owner, base + (AudioUnitParameterID)_band, v);
}

- (AVAudioUnitEQFilterType)filterType { return _type; }
- (void)setFilterType:(AVAudioUnitEQFilterType)v { _type = v; [self _push:kAUNBandEQParam_FilterType value:(float)v]; }
- (float)frequency { return _frequency; }
- (void)setFrequency:(float)v { _frequency = v; [self _push:kAUNBandEQParam_Frequency value:v]; }
- (float)bandwidth { return _bandwidth; }
- (void)setBandwidth:(float)v { _bandwidth = v; [self _push:kAUNBandEQParam_Bandwidth value:v]; }
- (float)gain { return _gain; }
- (void)setGain:(float)v { _gain = v; [self _push:kAUNBandEQParam_Gain value:v]; }
- (BOOL)bypass { return _bypass; }
- (void)setBypass:(BOOL)v { _bypass = v; [self _push:kAUNBandEQParam_BypassBand value:v ? 1 : 0]; }

@end

@implementation AVAudioUnitEQ {
    NSArray *_bands;
}

- (instancetype)init
{
    return [self initWithNumberOfBands:16];
}

- (instancetype)initWithNumberOfBands:(NSUInteger)numberOfBands
{
    if (!(self = [self initWithAudioComponentDescription:apple(kAudioUnitType_Effect, kAudioUnitSubType_NBandEQ)]))
        return nil;
    if (numberOfBands > 64)
        numberOfBands = 64;
    UInt32 n = (UInt32)(numberOfBands ? numberOfBands : 1), limit = 64;
    AudioUnitSetProperty(_unit, kFinchNBandEQProperty_BandLimit, kAudioUnitScope_Global, 0, &limit, sizeof limit);
    AudioUnitSetProperty(_unit, kAUNBandEQProperty_NumberOfBands, kAudioUnitScope_Global, 0, &n, sizeof n);
    NSMutableArray *bands = [NSMutableArray array];
    for (NSUInteger k = 0; k < numberOfBands; k++) {
        /* (the first eight bands where the unit has them; the rest spread up to 10 kHz) */
        double frequency = k < 8 ? 40.0 * pow(250.0, k / 15.0) : 40.0 * pow(250.0, k / (double)(numberOfBands - 1));
        AVAudioUnitEQFilterParameters *b = [[AVAudioUnitEQFilterParameters alloc] _initWithOwner:self band:(int)k frequency:(float)frequency];
        [bands addObject:b];
        [b release];
    }
    _bands = [bands copy];
    return self;
}

- (void)dealloc
{
    [_bands release];
    [super dealloc];
}

- (NSArray<AVAudioUnitEQFilterParameters *> *)bands
{
    return _bands;
}

- (float)globalGain { return property(self, 0, kAUNBandEQParam_GlobalGain); }
- (void)setGlobalGain:(float)v { set_property(self, 0, kAUNBandEQParam_GlobalGain, v); }

@end

/* --- the sampler --- */

@implementation AVAudioUnitSampler

- (instancetype)init
{
    return [self initWithAudioComponentDescription:apple(kAudioUnitType_MusicDevice, kAudioUnitSubType_Sampler)];
}

static BOOL
sampler_result(OSStatus status, NSError **outError)
{
    if (status && outError)
        *outError = status_error(status);
    return status == noErr;
}

- (BOOL)loadAudioFilesAtURLs:(NSArray<NSURL *> *)audioFiles error:(NSError **)outError
{
    for (NSURL *url in audioFiles)
        if (![url checkResourceIsReachableAndReturnError:NULL])
            return sampler_result(-43, outError);
    CFArrayRef urls = (CFArrayRef)audioFiles;
    return sampler_result(AudioUnitSetProperty(_unit, kAUSamplerProperty_LoadAudioFiles, kAudioUnitScope_Global, 0, &urls, sizeof urls), outError);
}

static UInt8
instrument_type(NSURL *url)
{
    NSString *ext = url.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"sf2"])
        return kInstrumentType_SF2Preset;
    if ([ext isEqualToString:@"dls"])
        return kInstrumentType_DLSPreset;
    return kInstrumentType_AUPreset;
}

- (BOOL)loadInstrumentAtURL:(NSURL *)instrumentURL error:(NSError **)outError
{
    if (![instrumentURL checkResourceIsReachableAndReturnError:NULL])
        return sampler_result(-43, outError);
    AUSamplerInstrumentData d = {(CFURLRef)instrumentURL, instrument_type(instrumentURL), 0, 0, 0};
    return sampler_result(AudioUnitSetProperty(_unit, kAUSamplerProperty_LoadInstrument, kAudioUnitScope_Global, 0, &d, sizeof d), outError);
}

- (BOOL)loadSoundBankInstrumentAtURL:(NSURL *)bankURL program:(uint8_t)program bankMSB:(uint8_t)bankMSB bankLSB:(uint8_t)bankLSB
                               error:(NSError **)outError
{
    if (![bankURL checkResourceIsReachableAndReturnError:NULL])
        return sampler_result(-43, outError);
    UInt8 type = instrument_type(bankURL) == kInstrumentType_SF2Preset ? kInstrumentType_SF2Preset : kInstrumentType_DLSPreset;
    AUSamplerInstrumentData d = {(CFURLRef)bankURL, type, bankMSB, bankLSB, program};
    return sampler_result(AudioUnitSetProperty(_unit, kAUSamplerProperty_LoadInstrument, kAudioUnitScope_Global, 0, &d, sizeof d), outError);
}

- (float)overallGain { return property(self, 0, kAUSamplerParam_Gain); }
- (void)setOverallGain:(float)v { set_property(self, 0, kAUSamplerParam_Gain, v); }
- (float)masterGain { return self.overallGain; }
- (void)setMasterGain:(float)v { self.overallGain = v; }
- (float)stereoPan { return property(self, 1, kAUSamplerParam_Pan); }
- (void)setStereoPan:(float)v { set_property(self, 1, kAUSamplerParam_Pan, v); }

/* (in cents: whole semitones to the coarse tuning, the rest to the fine) */
- (float)globalTuning
{
    if (!_isSet[2]) {
        _cached[2] = au_get(self, kAUSamplerParam_CoarseTuning) * 100 + au_get(self, kAUSamplerParam_FineTuning);
        _isSet[2] = YES;
    }
    return _cached[2];
}

- (void)setGlobalTuning:(float)v
{
    _cached[2] = v;
    _isSet[2] = YES;
    float semitones = truncf(v / 100);
    au_set(self, kAUSamplerParam_CoarseTuning, semitones);
    au_set(self, kAUSamplerParam_FineTuning, v - semitones * 100);
}

@end
