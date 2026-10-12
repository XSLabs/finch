/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AVAudioSession (for Mac Catalyst apps; the SDK marks it unavailable to macOS code,
 * so its interfaces are declared here), AVAudioApplication and AVAudioRoutingArbiter,
 * Finch's. Finch has no audio devices yet: the route has no inputs or outputs, input
 * isn't available, and recording permission can't be granted.
 */
#import <Foundation/Foundation.h>
#import <Block.h>
#import <AVFAudio/AVAudioChannelLayout.h>
#import <AVFAudio/AVAudioApplication.h>
#import <AVFAudio/AVAudioRoutingArbiter.h>

typedef NSString *AVAudioSessionCategory_;

@interface AVAudioSessionChannelDescription : NSObject {
@private
    void *_impl;
}
@end

@interface AVAudioSessionDataSourceDescription : NSObject {
@private
    void *_impl;
}
@end

@interface AVAudioSessionCapability : NSObject
@end

@interface AVAudioSessionPortExtensionBluetoothMicrophone : NSObject
@end

@interface AVAudioSessionPortDescription : NSObject {
@private
    void *_impl;
}
@end

@interface AVAudioSessionRouteDescription : NSObject {
@private
    void *_impl;
}
@end

@interface AVAudioSession : NSObject {
@private
    void *_impl;
}
@end

/* --- descriptions (none are made while there are no devices) --- */

@implementation AVAudioSessionChannelDescription
- (NSString *)channelName { return @""; }
- (NSString *)owningPortUID { return @""; }
- (NSUInteger)channelNumber { return 0; }
- (AudioChannelLabel)channelLabel { return kAudioChannelLabel_Unknown; }
@end

@implementation AVAudioSessionDataSourceDescription
- (NSNumber *)dataSourceID { return @0; }
- (NSString *)dataSourceName { return @""; }
- (NSString *)location { return nil; }
- (NSString *)orientation { return nil; }
- (NSArray *)supportedPolarPatterns { return nil; }
- (NSString *)selectedPolarPattern { return nil; }
- (NSString *)preferredPolarPattern { return nil; }
- (BOOL)setPreferredPolarPattern:(NSString *)pattern error:(NSError **)outError { return NO; }
@end

@implementation AVAudioSessionCapability
- (BOOL)isSupported { return NO; }
- (BOOL)isEnabled { return NO; }
@end

@implementation AVAudioSessionPortExtensionBluetoothMicrophone
- (AVAudioSessionCapability *)highQualityRecording { return [[AVAudioSessionCapability new] autorelease]; }
- (AVAudioSessionCapability *)farFieldCapture { return [[AVAudioSessionCapability new] autorelease]; }
@end

@implementation AVAudioSessionPortDescription
- (NSString *)portType { return @""; }
- (NSString *)portName { return @""; }
- (NSString *)UID { return @""; }
- (BOOL)hasHardwareVoiceCallProcessing { return NO; }
- (BOOL)isSpatialAudioEnabled { return NO; }
- (NSArray *)channels { return nil; }
- (NSArray *)dataSources { return nil; }
- (AVAudioSessionDataSourceDescription *)selectedDataSource { return nil; }
- (AVAudioSessionDataSourceDescription *)preferredDataSource { return nil; }
- (BOOL)setPreferredDataSource:(AVAudioSessionDataSourceDescription *)dataSource error:(NSError **)outError { return NO; }
- (AVAudioSessionPortExtensionBluetoothMicrophone *)bluetoothMicrophoneExtension { return nil; }
@end

@implementation AVAudioSessionRouteDescription
- (NSArray *)inputs { return @[]; }
- (NSArray *)outputs { return @[]; }
- (NSString *)description
{
    return [NSString stringWithFormat:@"<AVAudioSessionRouteDescription: %p, \ninputs = (\n); \noutputs = (\n)>", self];
}
@end

/* --- the session --- */

typedef struct {
    NSString *category, *mode;
    NSUInteger options, policy;
    BOOL active, allowHaptics, noAlertInterruptions, echoCancelled, outputMuted, multichannel, interruptOnDisconnect, nowPlaying;
    double preferredRate;
    NSTimeInterval preferredBuffer;
    NSInteger preferredInputs, preferredOutputs, preferredOrientation, injection, spatial;
} Session;

static NSError *
no_device(void)
{
    /* (AVAudioSessionErrorCodeCannotStartRecording: there's nothing to record from) */
    return [NSError errorWithDomain:NSOSStatusErrorDomain code:'!rec' userInfo:nil];
}

#define S ((Session *)_impl)

@implementation AVAudioSession

+ (AVAudioSession *)sharedInstance
{
    static AVAudioSession *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      shared = [AVAudioSession new];
    });
    return shared;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _impl = calloc(1, sizeof(Session));
        S->category = @"AVAudioSessionCategorySoloAmbient";
        S->mode = @"AVAudioSessionModeDefault";
    }
    return self;
}

- (NSArray *)availableCategories
{
    return @[ @"AVAudioSessionCategoryAmbient", @"AVAudioSessionCategorySoloAmbient", @"AVAudioSessionCategoryPlayback", @"AVAudioSessionCategoryRecord",
              @"AVAudioSessionCategoryPlayAndRecord", @"AVAudioSessionCategoryMultiRoute" ];
}

- (NSArray *)availableModes
{
    return @[ @"AVAudioSessionModeDefault", @"AVAudioSessionModeVoiceChat", @"AVAudioSessionModeGameChat", @"AVAudioSessionModeVideoRecording",
              @"AVAudioSessionModeMeasurement", @"AVAudioSessionModeMoviePlayback", @"AVAudioSessionModeVideoChat", @"AVAudioSessionModeSpokenAudio",
              @"AVAudioSessionModeVoicePrompt" ];
}

- (BOOL)_setCategory:(NSString *)category mode:(NSString *)mode policy:(NSUInteger)policy options:(NSUInteger)options error:(NSError **)outError
{
    if (!category || ![self.availableCategories containsObject:category]) {
        if (outError)
            *outError = [NSError errorWithDomain:NSOSStatusErrorDomain code:-50 userInfo:nil];
        return NO;
    }
    [S->category autorelease];
    S->category = [category copy];
    if (mode) {
        [S->mode autorelease];
        S->mode = [mode copy];
    }
    S->policy = policy;
    S->options = options;
    return YES;
}

- (BOOL)setCategory:(NSString *)category error:(NSError **)outError
{
    return [self _setCategory:category mode:nil policy:S->policy options:0 error:outError];
}

- (BOOL)setCategory:(NSString *)category withOptions:(NSUInteger)options error:(NSError **)outError
{
    return [self _setCategory:category mode:nil policy:S->policy options:options error:outError];
}

- (BOOL)setCategory:(NSString *)category mode:(NSString *)mode options:(NSUInteger)options error:(NSError **)outError
{
    return [self _setCategory:category mode:mode policy:S->policy options:options error:outError];
}

- (BOOL)setCategory:(NSString *)category mode:(NSString *)mode routeSharingPolicy:(NSUInteger)policy options:(NSUInteger)options error:(NSError **)outError
{
    return [self _setCategory:category mode:mode policy:policy options:options error:outError];
}

- (NSString *)category { return S->category; }
- (NSUInteger)categoryOptions { return S->options; }
- (NSUInteger)routeSharingPolicy { return S->policy; }
- (NSString *)mode { return S->mode; }

- (BOOL)setMode:(NSString *)mode error:(NSError **)outError
{
    [S->mode autorelease];
    S->mode = [mode copy];
    return YES;
}

- (BOOL)setAllowHapticsAndSystemSoundsDuringRecording:(BOOL)v error:(NSError **)outError { S->allowHaptics = v; return YES; }
- (BOOL)allowHapticsAndSystemSoundsDuringRecording { return S->allowHaptics; }
- (NSUInteger)recordPermission { return 'undt'; }

- (void)requestRecordPermission:(void (^)(BOOL))response
{
    if (response) {
        void (^r)(BOOL) = [[response copy] autorelease];
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
          r(NO);
        });
    }
}

- (BOOL)overrideOutputAudioPort:(NSUInteger)portOverride error:(NSError **)outError { return YES; }

- (BOOL)setPreferredInput:(AVAudioSessionPortDescription *)inPort error:(NSError **)outError
{
    if (!inPort)
        return YES;
    if (outError)
        *outError = no_device();
    return NO;
}

- (AVAudioSessionPortDescription *)preferredInput { return nil; }
- (BOOL)setPrefersNoInterruptionsFromSystemAlerts:(BOOL)v error:(NSError **)outError { S->noAlertInterruptions = v; return YES; }
- (BOOL)prefersNoInterruptionsFromSystemAlerts { return S->noAlertInterruptions; }
- (NSInteger)renderingMode { return 0; }
- (BOOL)setPrefersEchoCancelledInput:(BOOL)v error:(NSError **)outError { S->echoCancelled = v; return YES; }
- (BOOL)prefersEchoCancelledInput { return S->echoCancelled; }
- (BOOL)isEchoCancelledInputEnabled { return NO; }
- (BOOL)isEchoCancelledInputAvailable { return NO; }
- (BOOL)setOutputMuted:(BOOL)v error:(NSError **)outError { S->outputMuted = v; return YES; }
- (BOOL)isOutputMuted { return S->outputMuted; }

/* activation */

- (BOOL)setActive:(BOOL)active error:(NSError **)outError { S->active = active; return YES; }
- (BOOL)setActive:(BOOL)active withOptions:(NSUInteger)options error:(NSError **)outError { S->active = active; return YES; }

- (void)activateWithOptions:(NSUInteger)options completionHandler:(void (^)(BOOL, NSError *))handler
{
    S->active = YES;
    if (handler) {
        void (^h)(BOOL, NSError *) = [[handler copy] autorelease];
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
          h(YES, nil);
        });
    }
}

/* hardware (as preferences: there's no hardware to configure) */

- (BOOL)setPreferredSampleRate:(double)v error:(NSError **)outError { S->preferredRate = v; return YES; }
- (double)preferredSampleRate { return S->preferredRate; }
- (BOOL)setPreferredIOBufferDuration:(NSTimeInterval)v error:(NSError **)outError { S->preferredBuffer = v; return YES; }
- (NSTimeInterval)preferredIOBufferDuration { return S->preferredBuffer; }
- (BOOL)setPreferredInputNumberOfChannels:(NSInteger)v error:(NSError **)outError { S->preferredInputs = v; return YES; }
- (NSInteger)preferredInputNumberOfChannels { return S->preferredInputs; }
- (BOOL)setPreferredOutputNumberOfChannels:(NSInteger)v error:(NSError **)outError { S->preferredOutputs = v; return YES; }
- (NSInteger)preferredOutputNumberOfChannels { return S->preferredOutputs; }
- (BOOL)setPreferredInputOrientation:(NSInteger)v error:(NSError **)outError { S->preferredOrientation = v; return YES; }
- (NSInteger)preferredInputOrientation { return S->preferredOrientation; }
- (NSInteger)inputOrientation { return 0; }
- (NSInteger)maximumInputNumberOfChannels { return 0; }
- (NSInteger)maximumOutputNumberOfChannels { return 2; }

- (BOOL)setInputGain:(float)gain error:(NSError **)outError
{
    if (outError)
        *outError = no_device();
    return NO;
}

- (float)inputGain { return 0; }
- (BOOL)isInputGainSettable { return NO; }
- (BOOL)isInputAvailable { return NO; }
- (NSArray *)inputDataSources { return nil; }
- (AVAudioSessionDataSourceDescription *)inputDataSource { return nil; }
- (BOOL)setInputDataSource:(AVAudioSessionDataSourceDescription *)d error:(NSError **)outError { return d == nil; }
- (NSArray *)outputDataSources { return nil; }
- (AVAudioSessionDataSourceDescription *)outputDataSource { return nil; }
- (BOOL)setOutputDataSource:(AVAudioSessionDataSourceDescription *)d error:(NSError **)outError { return d == nil; }
- (double)sampleRate { return S->preferredRate > 0 ? S->preferredRate : 44100; }
- (NSInteger)inputNumberOfChannels { return 0; }
- (NSInteger)outputNumberOfChannels { return 2; }
- (NSTimeInterval)inputLatency { return 0; }
- (NSTimeInterval)outputLatency { return 0; }
- (NSTimeInterval)IOBufferDuration { return S->preferredBuffer > 0 ? S->preferredBuffer : 0.0116; }
- (NSArray<AVAudioChannelLayout *> *)supportedOutputChannelLayouts { return @[]; }

/* observation */

- (BOOL)isOtherAudioPlaying { return NO; }
- (BOOL)secondaryAudioShouldBeSilencedHint { return NO; }
- (float)outputVolume { return 1; }
- (NSInteger)promptStyle { return 'norm'; }

/* routing */

- (NSArray *)availableInputs { return @[]; }

- (AVAudioSessionRouteDescription *)currentRoute
{
    return [[AVAudioSessionRouteDescription new] autorelease];
}

- (BOOL)setAggregatedIOPreference:(NSUInteger)type error:(NSError **)outError { return YES; }
- (BOOL)setSupportsMultichannelContent:(BOOL)v error:(NSError **)outError { S->multichannel = v; return YES; }
- (BOOL)supportsMultichannelContent { return S->multichannel; }
- (BOOL)setPrefersInterruptionOnRouteDisconnect:(BOOL)v error:(NSError **)outError { S->interruptOnDisconnect = v; return YES; }
- (BOOL)prefersInterruptionOnRouteDisconnect { return S->interruptOnDisconnect; }
- (BOOL)setPreferredMicrophoneInjectionMode:(NSInteger)v error:(NSError **)outError { S->injection = v; return YES; }
- (NSInteger)preferredMicrophoneInjectionMode { return S->injection; }
- (BOOL)isMicrophoneInjectionAvailable { return NO; }
- (BOOL)setIntendedSpatialExperience:(NSInteger)v options:(NSDictionary *)options error:(NSError **)outError { S->spatial = v; return YES; }
- (NSInteger)intendedSpatialExperience { return S->spatial; }
- (NSDictionary *)intendedSpatialExperienceOptions { return nil; }
- (BOOL)isNowPlayingCandidate { return S->nowPlaying; }
- (BOOL)setIsNowPlayingCandidate:(BOOL)v error:(NSError **)outError { S->nowPlaying = v; return YES; }

@end

/* --- the application --- */

@implementation AVAudioApplication {
    BOOL _muted;
    BOOL (^_handler)(BOOL);
}

+ (AVAudioApplication *)sharedInstance
{
    static AVAudioApplication *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      shared = [[AVAudioApplication alloc] _init];
    });
    return shared;
}

- (instancetype)_init
{
    return [super init];
}

/* (muting needs a handler to mute the app's input, as with Apple's) */
- (BOOL)setInputMuted:(BOOL)muted error:(NSError **)outError
{
    if (!_handler) {
        if (outError)
            *outError = [NSError errorWithDomain:NSOSStatusErrorDomain code:-50 userInfo:nil];
        return NO;
    }
    if (!_handler(muted)) {
        if (outError)
            *outError = [NSError errorWithDomain:NSOSStatusErrorDomain code:-50 userInfo:nil];
        return NO;
    }
    _muted = muted;
    [[NSNotificationCenter defaultCenter] postNotificationName:AVAudioApplicationInputMuteStateChangeNotification object:self
                                                      userInfo:@{AVAudioApplicationMuteStateKey : @(muted)}];
    return YES;
}

- (BOOL)isInputMuted
{
    return _muted;
}

- (BOOL)setInputMuteStateChangeHandler:(BOOL (^)(BOOL))inputMuteHandler error:(NSError **)outError
{
    if (_handler)
        Block_release(_handler);
    _handler = inputMuteHandler ? Block_copy(inputMuteHandler) : NULL;
    return YES;
}

- (AVAudioApplicationRecordPermission)recordPermission
{
    return AVAudioApplicationRecordPermissionUndetermined;
}

+ (void)requestRecordPermissionWithCompletionHandler:(void (^)(BOOL))response
{
    if (response) {
        void (^r)(BOOL) = [[response copy] autorelease];
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
          r(NO);
        });
    }
}

- (AVAudioApplicationMicrophoneInjectionPermission)microphoneInjectionPermission
{
    return AVAudioApplicationMicrophoneInjectionPermissionServiceDisabled;
}

+ (void)requestMicrophoneInjectionPermissionWithCompletionHandler:(void (^)(AVAudioApplicationMicrophoneInjectionPermission))response
{
    if (response) {
        void (^r)(AVAudioApplicationMicrophoneInjectionPermission) = [[response copy] autorelease];
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
          r(AVAudioApplicationMicrophoneInjectionPermissionServiceDisabled);
        });
    }
}

@end

/* --- the routing arbiter --- */

@implementation AVAudioRoutingArbiter

+ (AVAudioRoutingArbiter *)sharedRoutingArbiter
{
    static AVAudioRoutingArbiter *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      shared = [[AVAudioRoutingArbiter alloc] _init];
    });
    return shared;
}

- (instancetype)_init
{
    return [super init];
}

/* (one Mac, one set of devices: the default device never changes) */
- (void)beginArbitrationWithCategory:(AVAudioRoutingArbitrationCategory)category completionHandler:(void (^)(BOOL, NSError *))handler
{
    if (handler) {
        void (^h)(BOOL, NSError *) = [[handler copy] autorelease];
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
          h(NO, nil);
        });
    }
}

- (void)leaveArbitration
{
}

@end
