/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Immutable event values used by AVAudioSequencer's MusicSequence bridge. */
#import <AVFAudio/AVMusicEvents.h>

@implementation AVMusicEvent
@end

@implementation AVMIDINoteEvent {
    UInt32 _channel, _key, _velocity;
    AVMusicTimeStamp _duration;
}
- (instancetype)initWithChannel:(UInt32)channel key:(UInt32)key velocity:(UInt32)velocity duration:(AVMusicTimeStamp)duration
{
    if ((self = [super init])) {
        _channel = channel;
        _key = key;
        _velocity = velocity;
        _duration = duration;
    }
    return self;
}
- (UInt32)channel { return _channel; }
- (void)setChannel:(UInt32)value { _channel = value; }
- (UInt32)key { return _key; }
- (void)setKey:(UInt32)value { _key = value; }
- (UInt32)velocity { return _velocity; }
- (void)setVelocity:(UInt32)value { _velocity = value; }
- (AVMusicTimeStamp)duration { return _duration; }
- (void)setDuration:(AVMusicTimeStamp)value { _duration = value; }
@end

@implementation AVMIDIChannelEvent {
    UInt32 _channel;
}
- (UInt32)channel { return _channel; }
- (void)setChannel:(UInt32)value { _channel = value; }
@end

@implementation AVMIDIControlChangeEvent {
    AVMIDIControlChangeMessageType _messageType;
    UInt32 _value;
}
- (instancetype)initWithChannel:(UInt32)channel messageType:(AVMIDIControlChangeMessageType)type value:(UInt32)value
{
    if ((self = [super init])) {
        self.channel = channel;
        _messageType = type;
        _value = value;
    }
    return self;
}
- (AVMIDIControlChangeMessageType)messageType { return _messageType; }
- (UInt32)value { return _value; }
@end

@implementation AVMIDIPolyPressureEvent {
    UInt32 _key, _pressure;
}
- (instancetype)initWithChannel:(UInt32)channel key:(UInt32)key pressure:(UInt32)pressure
{
    if ((self = [super init])) {
        self.channel = channel;
        _key = key;
        _pressure = pressure;
    }
    return self;
}
- (UInt32)key { return _key; }
- (void)setKey:(UInt32)value { _key = value; }
- (UInt32)pressure { return _pressure; }
- (void)setPressure:(UInt32)value { _pressure = value; }
@end

@implementation AVMIDIProgramChangeEvent {
    UInt32 _programNumber;
}
- (instancetype)initWithChannel:(UInt32)channel programNumber:(UInt32)programNumber
{
    if ((self = [super init])) {
        self.channel = channel;
        _programNumber = programNumber;
    }
    return self;
}
- (UInt32)programNumber { return _programNumber; }
- (void)setProgramNumber:(UInt32)value { _programNumber = value; }
@end

@implementation AVMIDIChannelPressureEvent {
    UInt32 _pressure;
}
- (instancetype)initWithChannel:(UInt32)channel pressure:(UInt32)pressure
{
    if ((self = [super init])) {
        self.channel = channel;
        _pressure = pressure;
    }
    return self;
}
- (UInt32)pressure { return _pressure; }
- (void)setPressure:(UInt32)value { _pressure = value; }
@end

@implementation AVMIDIPitchBendEvent {
    UInt32 _value;
}
- (instancetype)initWithChannel:(UInt32)channel value:(UInt32)value
{
    if ((self = [super init])) {
        self.channel = channel;
        _value = value;
    }
    return self;
}
- (UInt32)value { return _value; }
- (void)setValue:(UInt32)value { _value = value; }
@end

@implementation AVMIDISysexEvent {
    NSData *_data;
}
- (instancetype)initWithData:(NSData *)data
{
    if ((self = [super init]))
        _data = [data copy];
    return self;
}
- (void)dealloc { [_data release]; [super dealloc]; }
- (UInt32)sizeInBytes { return (UInt32)MIN(_data.length, UINT32_MAX); }
- (NSData *)_finchData { return _data; }
@end

@implementation AVMIDIMetaEvent {
    AVMIDIMetaEventType _type;
    NSData *_data;
}
- (instancetype)initWithType:(AVMIDIMetaEventType)type data:(NSData *)data
{
    if ((self = [super init])) {
        _type = type;
        _data = [data copy];
    }
    return self;
}
- (void)dealloc { [_data release]; [super dealloc]; }
- (AVMIDIMetaEventType)type { return _type; }
- (NSData *)_finchData { return _data; }
@end

@implementation AVMusicUserEvent {
    NSData *_data;
}
- (instancetype)initWithData:(NSData *)data
{
    if ((self = [super init]))
        _data = [data copy];
    return self;
}
- (void)dealloc { [_data release]; [super dealloc]; }
- (UInt32)sizeInBytes { return (UInt32)MIN(_data.length, UINT32_MAX); }
- (NSData *)_finchData { return _data; }
@end

@implementation AVExtendedNoteOnEvent {
    float _midiNote, _velocity;
    UInt32 _instrumentID, _groupID;
    AVMusicTimeStamp _duration;
}
- (instancetype)initWithMIDINote:(float)note velocity:(float)velocity groupID:(UInt32)groupID duration:(AVMusicTimeStamp)duration
{
    return [self initWithMIDINote:note velocity:velocity instrumentID:AVExtendedNoteOnEventDefaultInstrument groupID:groupID duration:duration];
}
- (instancetype)initWithMIDINote:(float)note velocity:(float)velocity instrumentID:(UInt32)instrumentID groupID:(UInt32)groupID duration:(AVMusicTimeStamp)duration
{
    if ((self = [super init])) {
        _midiNote = note;
        _velocity = velocity;
        _instrumentID = instrumentID;
        _groupID = groupID;
        _duration = duration;
    }
    return self;
}
- (float)midiNote { return _midiNote; }
- (void)setMidiNote:(float)value { _midiNote = value; }
- (float)velocity { return _velocity; }
- (void)setVelocity:(float)value { _velocity = value; }
- (UInt32)instrumentID { return _instrumentID; }
- (void)setInstrumentID:(UInt32)value { _instrumentID = value; }
- (UInt32)groupID { return _groupID; }
- (void)setGroupID:(UInt32)value { _groupID = value; }
- (AVMusicTimeStamp)duration { return _duration; }
- (void)setDuration:(AVMusicTimeStamp)value { _duration = value; }
@end

@implementation AVParameterEvent {
    UInt32 _parameterID, _scope, _element;
    float _value;
}
- (instancetype)initWithParameterID:(UInt32)parameterID scope:(UInt32)scope element:(UInt32)element value:(float)value
{
    if ((self = [super init])) {
        _parameterID = parameterID;
        _scope = scope;
        _element = element;
        _value = value;
    }
    return self;
}
- (UInt32)parameterID { return _parameterID; }
- (void)setParameterID:(UInt32)value { _parameterID = value; }
- (UInt32)scope { return _scope; }
- (void)setScope:(UInt32)value { _scope = value; }
- (UInt32)element { return _element; }
- (void)setElement:(UInt32)value { _element = value; }
- (float)value { return _value; }
- (void)setValue:(float)value { _value = value; }
@end

@implementation AVAUPresetEvent {
    UInt32 _scope, _element;
    NSDictionary *_presetDictionary;
}
- (instancetype)initWithScope:(UInt32)scope element:(UInt32)element dictionary:(NSDictionary *)dictionary
{
    if ((self = [super init])) {
        _scope = scope;
        _element = element;
        _presetDictionary = [dictionary copy];
    }
    return self;
}
- (void)dealloc { [_presetDictionary release]; [super dealloc]; }
- (UInt32)scope { return _scope; }
- (void)setScope:(UInt32)value { _scope = value; }
- (UInt32)element { return _element; }
- (void)setElement:(UInt32)value { _element = value; }
- (NSDictionary *)presetDictionary { return _presetDictionary; }
@end

@implementation AVExtendedTempoEvent {
    double _tempo;
}
- (instancetype)initWithTempo:(double)tempo
{
    if ((self = [super init]))
        _tempo = tempo;
    return self;
}
- (double)tempo { return _tempo; }
- (void)setTempo:(double)value { _tempo = value; }
@end
