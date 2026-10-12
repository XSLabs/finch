/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AVAudioUnitComponent and its manager, Finch's: the audio components AudioToolbox has,
 * described as Apple's describes them (type names, versions, tags, configurations).
 * Finch has no audio unit views, icons or user tags yet.
 */
#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>

@interface AVAudioUnitComponent ()
- (instancetype)_initWithComponent:(AudioComponent)component;
@end

static NSString *
type_name(OSType type)
{
    switch (type) {
    case kAudioUnitType_Output:
        return AVAudioUnitTypeOutput;
    case kAudioUnitType_MusicDevice:
        return AVAudioUnitTypeMusicDevice;
    case kAudioUnitType_MusicEffect:
        return AVAudioUnitTypeMusicEffect;
    case kAudioUnitType_FormatConverter:
        return AVAudioUnitTypeFormatConverter;
    case kAudioUnitType_Effect:
        return AVAudioUnitTypeEffect;
    case kAudioUnitType_Mixer:
        return AVAudioUnitTypeMixer;
    case kAudioUnitType_Panner:
        return AVAudioUnitTypePanner;
    case kAudioUnitType_Generator:
        return AVAudioUnitTypeGenerator;
    case kAudioUnitType_OfflineEffect:
        return AVAudioUnitTypeOfflineEffect;
    case kAudioUnitType_MIDIProcessor:
        return AVAudioUnitTypeMIDIProcessor;
    default:
        return @"Unknown";
    }
}

/* The tags Apple's units carry. */
static NSArray *
tags(AudioComponentDescription d)
{
    static const struct {
        OSType type, subtype;
        NSString *first, *second, *third;
    } known[] = {
        {'aufx', 'dely', @"Effects", @"Delay", nil},
        {'aufx', 'sdly', @"Effects", @"Delay", nil},
        {'aufx', 'dist', @"Effects", @"Distortion", nil},
        {'aufx', 'nbeq', @"Effects", @"Equalizer", nil},
        {'aufx', 'mrev', @"Effects", @"Reverb", nil},
        {'aufx', 'rvb2', @"Effects", @"Reverb", nil},
        {'aufx', 'lpas', @"Effects", @"Filter", @"Equalizer"},
        {'aufx', 'hpas', @"Effects", @"Filter", @"Equalizer"},
        {'aufx', 'bpas', @"Effects", @"Filter", @"Equalizer"},
        {'aufx', 'lshf', @"Effects", @"Filter", @"Equalizer"},
        {'aufx', 'hshf', @"Effects", @"Filter", @"Equalizer"},
        {'aufx', 'pmeq', @"Effects", @"Filter", @"Equalizer"},
        {'aufx', 'lmtr', @"Effects", @"Dynamics Processor", nil},
        {'aufx', 'dcmp', @"Effects", @"Dynamics Processor", nil},
        {'aufx', 'nutp', @"Time Effect", @"Pitch", nil},
        {'aufc', 'nutp', @"Time Effect", @"Pitch", nil},
        {'aufc', 'vari', @"Time Effect", nil, nil},
        {'aumu', 'samp', @"Sampler", @"Synthesizer", nil},
    };
    for (size_t i = 0; i < sizeof known / sizeof known[0]; i++)
        if (known[i].type == d.componentType && known[i].subtype == d.componentSubType) {
            NSMutableArray *a = [NSMutableArray arrayWithObject:known[i].first];
            if (known[i].second)
                [a addObject:known[i].second];
            if (known[i].third)
                [a addObject:known[i].third];
            return a;
        }
    switch (d.componentType) {
    case kAudioUnitType_Effect:
        return @[ @"Effects" ];
    case kAudioUnitType_MusicDevice:
        return @[ @"Synthesizer" ];
    default:
        return @[ type_name(d.componentType) ];
    }
}

@implementation AVAudioUnitComponent {
    AudioComponent _component;
    AudioComponentDescription _description;
    NSString *_name, *_manufacturer;
    UInt32 _version;
    NSArray *_userTags;
}

- (instancetype)_initWithComponent:(AudioComponent)component
{
    if ((self = [super init])) {
        _component = component;
        AudioComponentGetDescription(component, &_description);
        AudioComponentGetVersion(component, &_version);
        CFStringRef full = NULL;
        AudioComponentCopyName(component, &full);
        NSString *s = full ? [(NSString *)full autorelease] : @"";
        NSRange r = [s rangeOfString:@": "];
        _manufacturer = [(r.location == NSNotFound ? @"" : [s substringToIndex:r.location]) copy];
        _name = [(r.location == NSNotFound ? s : [s substringFromIndex:NSMaxRange(r)]) copy];
        _userTags = [NSArray new];
    }
    return self;
}

- (void)dealloc
{
    [_name release];
    [_manufacturer release];
    [_userTags release];
    [super dealloc];
}

- (NSString *)name { return _name; }
- (NSString *)manufacturerName { return _manufacturer; }
- (NSString *)typeName { return type_name(_description.componentType); }
- (NSString *)localizedTypeName { return self.typeName; }
- (NSUInteger)version { return _version; }
- (AudioComponent)audioComponent { return _component; }
- (AudioComponentDescription)audioComponentDescription { return _description; }
- (BOOL)isSandboxSafe { return (_description.componentFlags & kAudioComponentFlag_SandboxSafe) != 0; }
- (BOOL)passesAUVal { return YES; }
- (BOOL)hasCustomView { return NO; }
- (NSURL *)iconURL { return nil; }
- (NSURL *)componentURL { return nil; }
- (id)icon { return nil; }

- (NSString *)versionString
{
    return [NSString stringWithFormat:@"%u.%u.%u", _version >> 16, (_version >> 8) & 0xFF, _version & 0xFF];
}

- (NSArray<NSNumber *> *)availableArchitectures
{
    return @[ @(NSBundleExecutableArchitectureARM64) ];
}

- (BOOL)_takesMIDI
{
    OSType t = _description.componentType;
    return t == kAudioUnitType_MusicDevice || t == kAudioUnitType_MusicEffect || t == kAudioUnitType_MIDIProcessor;
}

- (BOOL)hasMIDIInput { return [self _takesMIDI]; }
- (BOOL)hasMIDIOutput { return [self _takesMIDI]; }

- (NSArray<NSString *> *)userTagNames
{
    @synchronized(self) {
        return [[_userTags retain] autorelease];
    }
}

- (void)setUserTagNames:(NSArray<NSString *> *)names
{
    @synchronized(self) {
        [_userTags release];
        _userTags = [names copy] ?: [NSArray new];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:AVAudioUnitComponentTagsDidChangeNotification object:self];
}

- (NSArray<NSString *> *)allTagNames
{
    NSMutableArray *all = [NSMutableArray arrayWithArray:self.userTagNames];
    for (NSString *t in tags(_description))
        if (![all containsObject:t])
            [all addObject:t];
    return all;
}

/* The unit's buses as it starts. */
- (void)_inputs:(NSMutableArray *)inputs outputs:(NSMutableArray *)outputs
{
    AudioUnit unit = NULL;
    if (AudioComponentInstanceNew(_component, &unit) || !unit)
        return;
    const AudioUnitScope scopes[] = {kAudioUnitScope_Input, kAudioUnitScope_Output};
    for (int s = 0; s < 2; s++) {
        UInt32 count = 0, size = sizeof count;
        if (AudioUnitGetProperty(unit, kAudioUnitProperty_ElementCount, scopes[s], 0, &count, &size))
            continue;
        for (UInt32 bus = 0; bus < count; bus++) {
            AudioStreamBasicDescription f;
            size = sizeof f;
            if (!AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, scopes[s], bus, &f, &size))
                [s ? outputs : inputs addObject:@(f.mChannelsPerFrame)];
        }
    }
    AudioComponentInstanceDispose(unit);
}

- (NSDictionary<NSString *, id> *)configurationDictionary
{
    NSMutableArray *inputs = [NSMutableArray array], *outputs = [NSMutableArray array];
    [self _inputs:inputs outputs:outputs];
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"AvailableArchitectures"] = @[ @"arm64" ];
    d[@"HasCustomView"] = @NO;
    d[@"MIDIProtocol"] = @0;
    d[@"SupportedChannelLayoutTags"] = @{};
    d[@"ValidationResult"] = @{@"arm64" : @YES};
    if (inputs.count)
        d[@"InitialInputs"] = inputs;
    if (outputs.count)
        d[@"InitialOutputs"] = outputs;
    /* (-1: any number of channels; -1, -1: as many out as in; -2: any, independently) */
    switch (_description.componentType) {
    case kAudioUnitType_Effect:
    case kAudioUnitType_FormatConverter:
        d[@"ChannelConfigurations"] = _description.componentSubType == kAudioUnitSubType_AUConverter ? @[ @[ @-1, @-2 ] ] : @[ @[ @-1, @-1 ] ];
        break;
    case kAudioUnitType_Mixer:
        d[@"ChannelConfigurations"] = @[ @[ @-1, @-2 ] ];
        break;
    case kAudioUnitType_MusicDevice:
        d[@"ChannelConfigurations"] = @[ @[ @0, @-16 ] ];
        break;
    default:
        break;
    }
    return d;
}

/* (as Apple's answers: only the channels the unit starts with) */
- (BOOL)supportsNumberInputChannels:(NSInteger)numInputChannels outputChannels:(NSInteger)numOutputChannels
{
    NSMutableArray *inputs = [NSMutableArray array], *outputs = [NSMutableArray array];
    [self _inputs:inputs outputs:outputs];
    return inputs.count && outputs.count && [inputs[0] integerValue] == numInputChannels &&
           [outputs[0] integerValue] == numOutputChannels;
}

@end

@implementation AVAudioUnitComponentManager

+ (instancetype)sharedAudioUnitComponentManager
{
    static AVAudioUnitComponentManager *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      shared = [AVAudioUnitComponentManager new];
    });
    return shared;
}

- (NSArray<AVAudioUnitComponent *> *)componentsMatchingDescription:(AudioComponentDescription)desc
{
    NSMutableArray *found = [NSMutableArray array];
    AudioComponent c = NULL;
    while ((c = AudioComponentFindNext(c, &desc))) {
        AVAudioUnitComponent *component = [[AVAudioUnitComponent alloc] _initWithComponent:c];
        [found addObject:component];
        [component release];
    }
    return found;
}

- (NSArray<AVAudioUnitComponent *> *)_all
{
    AudioComponentDescription any = {0, 0, 0, 0, 0};
    return [self componentsMatchingDescription:any];
}

- (NSArray<AVAudioUnitComponent *> *)componentsMatchingPredicate:(NSPredicate *)predicate
{
    return [[self _all] filteredArrayUsingPredicate:predicate];
}

- (NSArray<AVAudioUnitComponent *> *)componentsPassingTest:(BOOL (^)(AVAudioUnitComponent *, BOOL *))testHandler
{
    NSMutableArray *found = [NSMutableArray array];
    BOOL stop = NO;
    for (AVAudioUnitComponent *c in [self _all]) {
        if (testHandler(c, &stop))
            [found addObject:c];
        if (stop)
            break;
    }
    return found;
}

- (NSArray<NSString *> *)tagNames
{
    NSMutableOrderedSet *all = [NSMutableOrderedSet orderedSet];
    for (AVAudioUnitComponent *c in [self _all])
        [all addObjectsFromArray:c.allTagNames];
    return all.array;
}

- (NSArray<NSString *> *)standardLocalizedTagNames
{
    return @[ @"Effects", @"Equalizer", @"Filter", @"Dynamics Processor", @"Reverb", @"Distortion", @"Delay", @"Time Effect",
        @"Synthesizer", @"Sampler", @"Drums", @"Guitar", @"Vocal", @"Bass", @"MIDI", @"Pitch", @"Panner", @"Imaging", @"Mixer",
        @"Format Converter", @"Output", @"Offline Effect" ];
}

@end
