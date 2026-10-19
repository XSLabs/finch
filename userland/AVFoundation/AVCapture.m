/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Capture's public objects on a system with no camera or microphone driver. */
#import "AVFInternal.h"
#import <AVFoundation/AVCaptureAudioDataOutput.h>
#import <AVFoundation/AVCaptureAudioPreviewOutput.h>
#import <AVFoundation/AVCaptureDevice.h>
#import <AVFoundation/AVCaptureFileOutput.h>
#import <AVFoundation/AVCaptureInput.h>
#import <AVFoundation/AVCaptureOutput.h>
#import <AVFoundation/AVCapturePhotoOutput.h>
#import <AVFoundation/AVCaptureSession.h>
#import <AVFoundation/AVCaptureVideoDataOutput.h>
#import <AVFoundation/AVCaptureVideoPreviewLayer.h>
#import <QuartzCore/QuartzCore.h>
#include <stdatomic.h>

#pragma clang diagnostic ignored "-Wobjc-designated-initializers"
#pragma clang diagnostic ignored "-Wobjc-method-access"
#pragma clang diagnostic ignored "-Wincomplete-implementation"
#pragma clang diagnostic ignored "-Wunused-property-ivar"

@interface AVCaptureOutput (FinchInitialization)
- (instancetype)_finchInit;
@end

static NSError *
capture_error(NSInteger code)
{
    return [NSError errorWithDomain:AVFoundationErrorDomain code:code userInfo:nil];
}

#pragma mark - Device discovery

@implementation AVCaptureDevice

+ (NSArray<AVCaptureDevice *> *)devices { return @[]; }
+ (NSArray<AVCaptureDevice *> *)devicesWithMediaType:(AVMediaType)mediaType
{
    (void)mediaType;
    return @[];
}
+ (AVCaptureDevice *)defaultDeviceWithMediaType:(AVMediaType)mediaType
{
    (void)mediaType;
    return nil;
}
+ (AVCaptureDevice *)deviceWithUniqueID:(NSString *)deviceUniqueID
{
    (void)deviceUniqueID;
    return nil;
}
+ (AVCaptureDevice *)defaultDeviceWithDeviceType:(AVCaptureDeviceType)deviceType
                                      mediaType:(AVMediaType)mediaType
                                       position:(AVCaptureDevicePosition)position
{
    (void)deviceType;
    (void)mediaType;
    (void)position;
    return nil;
}
+ (AVCaptureDevice *)userPreferredCamera { return nil; }
+ (void)setUserPreferredCamera:(AVCaptureDevice *)device { (void)device; }
+ (AVCaptureDevice *)systemPreferredCamera { return nil; }
- (BOOL)hasMediaType:(AVMediaType)mediaType { (void)mediaType; return NO; }
- (AVCaptureDevicePosition)position { return AVCaptureDevicePositionUnspecified; }
- (BOOL)hasFlash { return NO; }
- (AVCaptureFlashMode)flashMode { return AVCaptureFlashModeOff; }
- (BOOL)isFlashModeSupported:(AVCaptureFlashMode)mode { (void)mode; return NO; }
- (BOOL)hasTorch { return NO; }
- (AVCaptureTorchMode)torchMode { return AVCaptureTorchModeOff; }
- (BOOL)isTorchModeSupported:(AVCaptureTorchMode)mode { (void)mode; return NO; }
- (BOOL)setTorchModeOnWithLevel:(float)level error:(NSError **)outError
{
    (void)level;
    if (outError)
        *outError = capture_error(AVErrorDeviceNotConnected);
    return NO;
}
- (BOOL)isFocusModeSupported:(AVCaptureFocusMode)mode { (void)mode; return NO; }
- (AVCaptureFocusMode)focusMode { return AVCaptureFocusModeLocked; }
- (BOOL)isFocusPointOfInterestSupported { return NO; }
- (CGPoint)focusPointOfInterest { return CGPointZero; }
- (BOOL)isAdjustingFocus { return NO; }
- (CGRect)defaultRectForFocusPointOfInterest:(CGPoint)point { (void)point; return CGRectZero; }
- (BOOL)isExposureModeSupported:(AVCaptureExposureMode)mode { (void)mode; return NO; }
- (AVCaptureExposureMode)exposureMode { return AVCaptureExposureModeLocked; }
- (BOOL)isExposurePointOfInterestSupported { return NO; }
- (CGPoint)exposurePointOfInterest { return CGPointZero; }
- (BOOL)isAdjustingExposure { return NO; }
- (CGRect)defaultRectForExposurePointOfInterest:(CGPoint)point { (void)point; return CGRectZero; }
- (BOOL)isWhiteBalanceModeSupported:(AVCaptureWhiteBalanceMode)mode { (void)mode; return NO; }
- (AVCaptureWhiteBalanceMode)whiteBalanceMode { return AVCaptureWhiteBalanceModeLocked; }
- (BOOL)isAdjustingWhiteBalance { return NO; }
- (BOOL)transportControlsSupported { return NO; }
- (AVCaptureDeviceTransportControlsPlaybackMode)transportControlsPlaybackMode { return 0; }
- (AVCaptureDeviceTransportControlsSpeed)transportControlsSpeed { return 0; }
- (NSSet<AVCaptureSceneMonitoringStatus> *)cinematicVideoCaptureSceneMonitoringStatuses { return [NSSet set]; }
- (void)setPrimaryConstituentDeviceSwitchingBehavior:(AVCapturePrimaryConstituentDeviceSwitchingBehavior)behavior restrictedSwitchingBehaviorConditions:(AVCapturePrimaryConstituentDeviceRestrictedSwitchingBehaviorConditions)conditions
{
    (void)behavior;
    (void)conditions;
    [NSException raise:NSInvalidArgumentException format:@"Capture device is not connected"];
}
- (void)performEffectForReaction:(AVCaptureReactionType)reactionType { (void)reactionType; }
+ (void)showSystemUserInterface:(AVCaptureSystemUserInterface)systemUserInterface { (void)systemUserInterface; }
- (void)setCameraLensSmudgeDetectionEnabled:(BOOL)enabled detectionInterval:(CMTime)interval { (void)enabled; (void)interval; }
- (BOOL)lockForConfiguration:(NSError **)outError
{
    if (outError)
        *outError = capture_error(AVErrorDeviceNotConnected);
    return NO;
}
- (void)unlockForConfiguration {}
- (BOOL)supportsAVCaptureSessionPreset:(AVCaptureSessionPreset)preset { (void)preset; return NO; }
+ (AVAuthorizationStatus)authorizationStatusForMediaType:(AVMediaType)mediaType
{
    if ([mediaType isEqualToString:AVMediaTypeVideo] || [mediaType isEqualToString:AVMediaTypeAudio])
        return AVAuthorizationStatusDenied;
    return AVAuthorizationStatusNotDetermined;
}
+ (void)requestAccessForMediaType:(AVMediaType)mediaType completionHandler:(void (^)(BOOL))handler
{
    (void)mediaType;
    if (handler)
        dispatch_async(dispatch_get_main_queue(), ^{ handler(NO); });
}

@end

@implementation AVCaptureDeviceDiscoverySession {
    NSArray *_deviceTypes;
    AVMediaType _mediaType;
    AVCaptureDevicePosition _position;
}

+ (instancetype)discoverySessionWithDeviceTypes:(NSArray<AVCaptureDeviceType> *)deviceTypes
                                       mediaType:(AVMediaType)mediaType
                                        position:(AVCaptureDevicePosition)position
{
    AVCaptureDeviceDiscoverySession *session = [[self alloc] init];
    session->_deviceTypes = [deviceTypes copy] ?: @[];
    session->_mediaType = [mediaType copy];
    session->_position = position;
    return session;
}
- (NSArray<AVCaptureDevice *> *)devices { return @[]; }
- (NSArray<NSSet<AVCaptureDevice *> *> *)supportedMultiCamDeviceSets { return @[]; }
@end

#pragma mark - Inputs and outputs

@implementation AVCaptureInput
- (NSArray<AVCaptureInputPort *> *)ports { return @[]; }
- (void)followExternalSyncDevice:(AVExternalSyncDevice *)device videoFrameDuration:(CMTime)duration delegate:(id<AVExternalSyncDeviceDelegate>)delegate
{
    (void)device;
    (void)duration;
    (void)delegate;
}
- (void)unfollowExternalSyncDevice {}
- (BOOL)isMultichannelAudioModeSupported:(AVCaptureMultichannelAudioMode)mode { (void)mode; return NO; }
@end

/* There are no input ports to vend until Finch has a capture source. */
@implementation AVCaptureInputPort
- (instancetype)init { return nil; }
@end

@implementation AVCaptureDeviceInput {
    AVCaptureDevice *_device;
}

+ (instancetype)deviceInputWithDevice:(AVCaptureDevice *)device error:(NSError **)outError
{
    return [[self alloc] initWithDevice:device error:outError];
}
- (instancetype)initWithDevice:(AVCaptureDevice *)device error:(NSError **)outError
{
    (void)device;
    if (outError)
        *outError = capture_error(AVErrorDeviceNotConnected);
    return nil;
}
- (AVCaptureDevice *)device { return _device; }
@end

@implementation AVCaptureOutput
- (instancetype)_finchInit { return [super init]; }
- (NSArray<AVCaptureConnection *> *)connections { return @[]; }
- (AVCaptureConnection *)connectionWithMediaType:(AVMediaType)mediaType
{
    (void)mediaType;
    return nil;
}
- (AVMetadataObject *)transformedMetadataObjectForMetadataObject:(AVMetadataObject *)object connection:(AVCaptureConnection *)connection
{
    (void)object;
    (void)connection;
    return nil;
}
- (CGRect)metadataOutputRectOfInterestForRect:(CGRect)rect { (void)rect; return CGRectZero; }
- (CGRect)rectForMetadataOutputRectOfInterest:(CGRect)rect { (void)rect; return CGRectZero; }
@end

@implementation AVCaptureConnection
{
    NSArray *_fInputPorts;
    AVCaptureOutput *_fOutput;
    AVCaptureVideoPreviewLayer *_fVideoPreviewLayer;
}
+ (instancetype)connectionWithInputPorts:(NSArray<AVCaptureInputPort *> *)ports output:(AVCaptureOutput *)output
{
    return [[self alloc] initWithInputPorts:ports output:output];
}
- (instancetype)initWithInputPorts:(NSArray<AVCaptureInputPort *> *)ports output:(AVCaptureOutput *)output
{
    if (ports.count == 0 || !output) {
        return nil;
    }
    if ((self = [super init])) {
        _fInputPorts = [ports copy];
        _fOutput = output;
        _enabled = YES;
    }
    return self;
}
+ (instancetype)connectionWithInputPort:(AVCaptureInputPort *)port videoPreviewLayer:(AVCaptureVideoPreviewLayer *)layer
{
    return [[self alloc] initWithInputPort:port videoPreviewLayer:layer];
}
- (instancetype)initWithInputPort:(AVCaptureInputPort *)port videoPreviewLayer:(AVCaptureVideoPreviewLayer *)layer
{
    if (!port || !layer) {
        return nil;
    }
    if ((self = [super init])) {
        _fInputPorts = @[ port ];
        _fVideoPreviewLayer = layer;
        _enabled = YES;
    }
    return self;
}
- (NSArray<AVCaptureInputPort *> *)inputPorts { return _fInputPorts ?: @[]; }
- (AVCaptureOutput *)output { return _fOutput; }
- (AVCaptureVideoPreviewLayer *)videoPreviewLayer { return _fVideoPreviewLayer; }
- (BOOL)isActive { return NO; }
- (NSArray<AVCaptureAudioChannel *> *)audioChannels { return @[]; }
- (BOOL)supportsVideoMirroring { return NO; }
- (BOOL)isVideoRotationAngleSupported:(CGFloat)angle { (void)angle; return NO; }
- (BOOL)supportsVideoOrientation { return NO; }
- (BOOL)supportsVideoMinFrameDuration { return NO; }
- (BOOL)supportsVideoMaxFrameDuration { return NO; }
- (BOOL)supportsVideoStabilization { return NO; }
- (CGFloat)videoMaxScaleAndCropFactor { return 1.0; }
- (AVCaptureVideoStabilizationMode)activeVideoStabilizationMode { return AVCaptureVideoStabilizationModeOff; }
- (BOOL)isCameraIntrinsicMatrixDeliverySupported { return NO; }
@end

@implementation AVCaptureVideoDataOutput {
    NSDictionary *_videoSettings;
    id<AVCaptureVideoDataOutputSampleBufferDelegate> _sampleBufferDelegate;
    dispatch_queue_t _sampleBufferCallbackQueue;
    BOOL _alwaysDiscardsLateVideoFrames;
}
- (instancetype)init
{
    if ((self = [self _finchInit]))
        _alwaysDiscardsLateVideoFrames = YES;
    return self;
}
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue
{
    _sampleBufferDelegate = delegate;
    _sampleBufferCallbackQueue = queue;
}
- (id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate { return _sampleBufferDelegate; }
- (dispatch_queue_t)sampleBufferCallbackQueue { return _sampleBufferCallbackQueue; }
- (NSDictionary *)videoSettings { return _videoSettings ?: @{}; }
- (void)setVideoSettings:(NSDictionary *)settings { _videoSettings = [settings copy] ?: @{}; }
- (BOOL)alwaysDiscardsLateVideoFrames { return _alwaysDiscardsLateVideoFrames; }
- (void)setAlwaysDiscardsLateVideoFrames:(BOOL)flag { _alwaysDiscardsLateVideoFrames = flag; }
- (NSArray<NSNumber *> *)availableVideoCVPixelFormatTypes { return @[]; }
- (NSArray<AVVideoCodecType> *)availableVideoCodecTypes { return @[]; }
- (CMTimeScale)recommendedMediaTimeScaleForAssetWriter { return 0; }
- (NSDictionary *)recommendedVideoSettingsForAssetWriterWithOutputFileType:(AVFileType)type
{
    (void)type;
    return nil;
}
- (NSArray<AVVideoCodecType> *)availableVideoCodecTypesForAssetWriterWithOutputFileType:(AVFileType)type
{
    (void)type;
    return @[];
}
- (NSDictionary *)recommendedVideoSettingsForVideoCodecType:(AVVideoCodecType)codec assetWriterOutputFileType:(AVFileType)type
{
    (void)codec;
    (void)type;
    return nil;
}
- (NSDictionary *)recommendedVideoSettingsForVideoCodecType:(AVVideoCodecType)codec assetWriterOutputFileType:(AVFileType)type outputFileURL:(NSURL *)URL
{
    (void)URL;
    return [self recommendedVideoSettingsForVideoCodecType:codec assetWriterOutputFileType:type];
}
- (NSArray<AVMetadataItem *> *)recommendedMovieMetadataForVideoCodecType:(AVVideoCodecType)codec assetWriterOutputFileType:(AVFileType)type
{
    (void)codec;
    (void)type;
    return @[];
}
@end

@implementation AVCaptureAudioDataOutput {
    NSDictionary *_audioSettings;
    id<AVCaptureAudioDataOutputSampleBufferDelegate> _sampleBufferDelegate;
    dispatch_queue_t _sampleBufferCallbackQueue;
    AudioChannelLayoutTag _spatialAudioChannelLayoutTag;
}
- (instancetype)init { return [self _finchInit]; }
- (void)setSampleBufferDelegate:(id<AVCaptureAudioDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue
{
    _sampleBufferDelegate = delegate;
    _sampleBufferCallbackQueue = queue;
}
- (id<AVCaptureAudioDataOutputSampleBufferDelegate>)sampleBufferDelegate { return _sampleBufferDelegate; }
- (dispatch_queue_t)sampleBufferCallbackQueue { return _sampleBufferCallbackQueue; }
- (NSDictionary *)audioSettings { return _audioSettings ?: @{}; }
- (void)setAudioSettings:(NSDictionary *)settings { _audioSettings = [settings copy] ?: @{}; }
- (AudioChannelLayoutTag)spatialAudioChannelLayoutTag { return _spatialAudioChannelLayoutTag; }
- (NSDictionary *)recommendedAudioSettingsForAssetWriterWithOutputFileType:(AVFileType)type
{
    (void)type;
    return nil;
}
@end

@implementation AVCaptureAudioPreviewOutput {
    NSString *_outputDeviceUniqueID;
    float _volume;
}
- (instancetype)init
{
    if ((self = [self _finchInit]))
        _volume = 1.0f;
    return self;
}
- (NSString *)outputDeviceUniqueID { return _outputDeviceUniqueID; }
- (void)setOutputDeviceUniqueID:(NSString *)identifier { _outputDeviceUniqueID = [identifier copy]; }
- (float)volume { return _volume; }
- (void)setVolume:(float)volume { _volume = fminf(1.0f, fmaxf(0.0f, volume)); }
@end

#pragma mark - Photo settings and output

@implementation AVCapturePhotoSettings {
    int64_t _uniqueID;
    NSDictionary *_format;
    AVCaptureFlashMode _flashMode;
    AVCapturePhotoQualityPrioritization _photoQualityPrioritization;
    CMVideoDimensions _maxPhotoDimensions;
    BOOL _highResolutionPhotoEnabled;
    BOOL _autoRedEyeReductionEnabled;
    NSArray *_livePhotoMovieMetadata;
}

+ (instancetype)photoSettings { return [[self alloc] init]; }
+ (instancetype)photoSettingsWithFormat:(NSDictionary<NSString *,id> *)format
{
    AVCapturePhotoSettings *settings = [[self alloc] init];
    settings->_format = [format copy];
    return settings;
}
+ (instancetype)photoSettingsFromPhotoSettings:(AVCapturePhotoSettings *)other
{
    if (!other)
        return nil;
    AVCapturePhotoSettings *copy = [[self alloc] init];
    copy->_format = [other->_format copy];
    copy->_flashMode = other->_flashMode;
    copy->_photoQualityPrioritization = other->_photoQualityPrioritization;
    copy->_maxPhotoDimensions = other->_maxPhotoDimensions;
    copy->_highResolutionPhotoEnabled = other->_highResolutionPhotoEnabled;
    copy->_autoRedEyeReductionEnabled = other->_autoRedEyeReductionEnabled;
    return copy;
}
- (instancetype)init
{
    if ((self = [super init])) {
        static atomic_int_fast64_t nextID = 1;
        _uniqueID = atomic_fetch_add(&nextID, 1);
        _flashMode = AVCaptureFlashModeOff;
        _photoQualityPrioritization = AVCapturePhotoQualityPrioritizationBalanced;
    }
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return [[self class] photoSettingsFromPhotoSettings:self]; }
- (int64_t)uniqueID { return _uniqueID; }
- (NSDictionary *)format { return _format; }
- (AVCaptureFlashMode)flashMode { return _flashMode; }
- (void)setFlashMode:(AVCaptureFlashMode)mode { _flashMode = mode; }
- (AVCapturePhotoQualityPrioritization)photoQualityPrioritization { return _photoQualityPrioritization; }
- (void)setPhotoQualityPrioritization:(AVCapturePhotoQualityPrioritization)value { _photoQualityPrioritization = value; }
- (CMVideoDimensions)maxPhotoDimensions { return _maxPhotoDimensions; }
- (void)setMaxPhotoDimensions:(CMVideoDimensions)value { _maxPhotoDimensions = value; }
- (BOOL)isHighResolutionPhotoEnabled { return _highResolutionPhotoEnabled; }
- (void)setHighResolutionPhotoEnabled:(BOOL)value { _highResolutionPhotoEnabled = value; }
- (BOOL)isAutoRedEyeReductionEnabled { return _autoRedEyeReductionEnabled; }
- (void)setAutoRedEyeReductionEnabled:(BOOL)value { _autoRedEyeReductionEnabled = value; }
- (NSArray<AVMetadataItem *> *)livePhotoMovieMetadata { return _livePhotoMovieMetadata ?: @[]; }
- (void)setLivePhotoMovieMetadata:(NSArray<AVMetadataItem *> *)metadata { _livePhotoMovieMetadata = [metadata copy] ?: @[]; }
@end

@implementation AVCapturePhotoOutput
- (instancetype)init { return [self _finchInit]; }
- (NSArray<NSNumber *> *)availablePhotoPixelFormatTypes { return @[]; }
- (NSArray<AVVideoCodecType> *)availablePhotoCodecTypes { return @[]; }
- (NSArray<AVFileType> *)availablePhotoFileTypes { return @[]; }
- (NSArray<AVFileType> *)availableRawPhotoFileTypes { return @[]; }
- (NSArray<NSNumber *> *)supportedPhotoPixelFormatTypesForFileType:(AVFileType)fileType
{
    (void)fileType;
    return @[];
}
- (NSArray<AVVideoCodecType> *)supportedPhotoCodecTypesForFileType:(AVFileType)fileType
{
    (void)fileType;
    return @[];
}
- (NSArray<NSNumber *> *)supportedFlashModes { return @[@(AVCaptureFlashModeOff)]; }
- (AVCapturePhotoQualityPrioritization)maxPhotoQualityPrioritization { return AVCapturePhotoQualityPrioritizationBalanced; }
- (void)setMaxPhotoQualityPrioritization:(AVCapturePhotoQualityPrioritization)value { (void)value; }
- (BOOL)isFastCapturePrioritizationSupported { return NO; }
- (BOOL)isFastCapturePrioritizationEnabled { return NO; }
- (void)setFastCapturePrioritizationEnabled:(BOOL)value { (void)value; }
- (BOOL)isHighResolutionCaptureEnabled { return NO; }
- (void)setHighResolutionCaptureEnabled:(BOOL)value { (void)value; }
- (CMVideoDimensions)maxPhotoDimensions { return (CMVideoDimensions){0, 0}; }
- (void)setMaxPhotoDimensions:(CMVideoDimensions)value { (void)value; }
- (BOOL)isZeroShutterLagSupported { return NO; }
- (BOOL)isZeroShutterLagEnabled { return NO; }
- (void)setZeroShutterLagEnabled:(BOOL)value { (void)value; }
- (BOOL)isResponsiveCaptureSupported { return NO; }
- (BOOL)isResponsiveCaptureEnabled { return NO; }
- (void)setResponsiveCaptureEnabled:(BOOL)value { (void)value; }
- (AVCapturePhotoOutputCaptureReadiness)captureReadiness { return AVCapturePhotoOutputCaptureReadinessNotReadyMomentarily; }
- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id<AVCapturePhotoCaptureDelegate>)delegate
{
    if (!settings || !delegate)
        [NSException raise:NSInvalidArgumentException format:@"Capture settings and delegate are required"];
    /* There is no input device from which this output could produce a photo. */
}
@end

#pragma mark - Session state

@implementation AVCaptureSession {
    NSMutableArray *_inputs;
    NSMutableArray *_outputs;
    NSMutableArray *_connections;
    NSMutableArray *_controls;
    AVCaptureSessionPreset _sessionPreset;
    BOOL _running;
    NSUInteger _configurationDepth;
    id<AVCaptureSessionControlsDelegate> _controlsDelegate;
    dispatch_queue_t _controlsDelegateCallbackQueue;
    id<AVCaptureSessionDeferredStartDelegate> _deferredStartDelegate;
    dispatch_queue_t _deferredStartDelegateCallbackQueue;
    BOOL _automaticallyRunsDeferredStart;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _inputs = [NSMutableArray array];
        _outputs = [NSMutableArray array];
        _connections = [NSMutableArray array];
        _controls = [NSMutableArray array];
        _sessionPreset = [AVCaptureSessionPresetHigh copy];
    }
    return self;
}
- (BOOL)canSetSessionPreset:(AVCaptureSessionPreset)preset
{
    static NSSet *presets;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        presets = [NSSet setWithArray:@[ AVCaptureSessionPresetPhoto, AVCaptureSessionPresetHigh,
            AVCaptureSessionPresetMedium, AVCaptureSessionPresetLow, AVCaptureSessionPreset320x240,
            AVCaptureSessionPreset352x288, AVCaptureSessionPreset640x480, AVCaptureSessionPreset1280x720,
            AVCaptureSessionPreset1920x1080, AVCaptureSessionPreset3840x2160 ]];
    });
    return [presets containsObject:preset];
}
- (AVCaptureSessionPreset)sessionPreset { return _sessionPreset; }
- (void)setSessionPreset:(AVCaptureSessionPreset)preset
{
    if (![self canSetSessionPreset:preset])
        [NSException raise:NSInvalidArgumentException format:@"Unsupported capture session preset"];
    _sessionPreset = [preset copy];
}
- (NSArray *)inputs { return [_inputs copy]; }
- (NSArray *)outputs { return [_outputs copy]; }
- (NSArray *)connections { return [_connections copy]; }
- (BOOL)canAddInput:(AVCaptureInput *)input { return input && ![_inputs containsObject:input]; }
- (void)addInput:(AVCaptureInput *)input
{
    if (![self canAddInput:input])
        [NSException raise:NSInvalidArgumentException format:@"Input cannot be added to this session"];
    [_inputs addObject:input];
}
- (void)addInputWithNoConnections:(AVCaptureInput *)input { [self addInput:input]; }
- (void)removeInput:(AVCaptureInput *)input { [_inputs removeObject:input]; }
- (BOOL)canAddOutput:(AVCaptureOutput *)output { return output && ![_outputs containsObject:output]; }
- (void)addOutput:(AVCaptureOutput *)output
{
    if (![self canAddOutput:output])
        [NSException raise:NSInvalidArgumentException format:@"Output cannot be added to this session"];
    [_outputs addObject:output];
}
- (void)addOutputWithNoConnections:(AVCaptureOutput *)output { [self addOutput:output]; }
- (void)removeOutput:(AVCaptureOutput *)output { [_outputs removeObject:output]; }
- (BOOL)canAddConnection:(AVCaptureConnection *)connection { return connection && ![_connections containsObject:connection]; }
- (void)addConnection:(AVCaptureConnection *)connection
{
    if (![self canAddConnection:connection])
        [NSException raise:NSInvalidArgumentException format:@"Connection cannot be added to this session"];
    [_connections addObject:connection];
}
- (void)removeConnection:(AVCaptureConnection *)connection { [_connections removeObject:connection]; }
- (void)beginConfiguration { _configurationDepth++; }
- (void)commitConfiguration
{
    if (_configurationDepth == 0)
        [NSException raise:NSInternalInconsistencyException format:@"No configuration transaction is active"];
    _configurationDepth--;
}
- (BOOL)isRunning { return _running; }
- (BOOL)isInterrupted { return NO; }
- (BOOL)supportsControls { return NO; }
- (NSInteger)maxControlsCount { return 0; }
- (NSArray *)controls { return @[]; }
- (BOOL)canAddControl:(AVCaptureControl *)control { (void)control; return NO; }
- (void)addControl:(AVCaptureControl *)control { (void)control; }
- (void)removeControl:(AVCaptureControl *)control { (void)control; }
- (id<AVCaptureSessionControlsDelegate>)controlsDelegate { return _controlsDelegate; }
- (dispatch_queue_t)controlsDelegateCallbackQueue { return _controlsDelegateCallbackQueue; }
- (void)setControlsDelegate:(id<AVCaptureSessionControlsDelegate>)delegate queue:(dispatch_queue_t)queue
{
    _controlsDelegate = delegate;
    _controlsDelegateCallbackQueue = queue;
}
- (BOOL)isManualDeferredStartSupported { return NO; }
- (BOOL)automaticallyRunsDeferredStart { return _automaticallyRunsDeferredStart; }
- (void)setAutomaticallyRunsDeferredStart:(BOOL)value { _automaticallyRunsDeferredStart = value; }
- (id<AVCaptureSessionDeferredStartDelegate>)deferredStartDelegate { return _deferredStartDelegate; }
- (dispatch_queue_t)deferredStartDelegateCallbackQueue { return _deferredStartDelegateCallbackQueue; }
- (void)setDeferredStartDelegate:(id<AVCaptureSessionDeferredStartDelegate>)delegate deferredStartDelegateCallbackQueue:(dispatch_queue_t)queue
{
    _deferredStartDelegate = delegate;
    _deferredStartDelegateCallbackQueue = queue;
}
- (void)runDeferredStartWhenNeeded {}
- (void)startRunning
{
    if (_running)
        return;
    _running = YES;
    [[NSNotificationCenter defaultCenter] postNotificationName:AVCaptureSessionDidStartRunningNotification object:self];
}
- (void)stopRunning
{
    if (!_running)
        return;
    _running = NO;
    [[NSNotificationCenter defaultCenter] postNotificationName:AVCaptureSessionDidStopRunningNotification object:self];
}
@end

#pragma mark - Preview layer

@implementation AVCaptureVideoPreviewLayer {
    AVCaptureSession *_session;
    AVLayerVideoGravity _videoGravity;
}
+ (instancetype)layerWithSession:(AVCaptureSession *)session { return [[self alloc] initWithSession:session]; }
- (instancetype)initWithSession:(AVCaptureSession *)session
{
    if ((self = [super init])) {
        _session = session;
        _videoGravity = [AVLayerVideoGravityResizeAspect copy];
    }
    return self;
}
+ (instancetype)layerWithSessionWithNoConnection:(AVCaptureSession *)session { return [self layerWithSession:session]; }
- (instancetype)initWithSessionWithNoConnection:(AVCaptureSession *)session { return [self initWithSession:session]; }
- (AVCaptureSession *)session { return _session; }
- (void)setSession:(AVCaptureSession *)session { _session = session; }
- (void)setSessionWithNoConnection:(AVCaptureSession *)session { _session = session; }
- (AVCaptureConnection *)connection { return nil; }
- (AVLayerVideoGravity)videoGravity { return _videoGravity; }
- (void)setVideoGravity:(AVLayerVideoGravity)value { _videoGravity = [value copy]; }
- (BOOL)isPreviewing { return NO; }
- (BOOL)isOrientationSupported { return NO; }
- (BOOL)isMirroringSupported { return NO; }
- (CGPoint)captureDevicePointOfInterestForPoint:(CGPoint)point { (void)point; return CGPointZero; }
- (CGPoint)pointForCaptureDevicePointOfInterest:(CGPoint)point { (void)point; return CGPointZero; }
- (CGRect)metadataOutputRectOfInterestForRect:(CGRect)rect { (void)rect; return CGRectZero; }
- (CGRect)rectForMetadataOutputRectOfInterest:(CGRect)rect { (void)rect; return CGRectZero; }
- (AVMetadataObject *)transformedMetadataObjectForMetadataObject:(AVMetadataObject *)object { (void)object; return nil; }
@end

#pragma mark - File output

@implementation AVCaptureFileOutput {
    NSURL *_outputFileURL;
    CMTime _maxRecordedDuration;
    int64_t _maxRecordedFileSize;
    int64_t _minFreeDiskSpaceLimit;
    BOOL _recordingPaused;
}
- (instancetype)init { return [self _finchInit]; }
- (NSURL *)outputFileURL { return _outputFileURL; }
- (BOOL)isRecording { return NO; }
- (BOOL)isRecordingPaused { return _recordingPaused; }
- (CMTime)recordedDuration { return kCMTimeZero; }
- (int64_t)recordedFileSize { return 0; }
- (CMTime)maxRecordedDuration { return _maxRecordedDuration; }
- (void)setMaxRecordedDuration:(CMTime)value { _maxRecordedDuration = value; }
- (int64_t)maxRecordedFileSize { return _maxRecordedFileSize; }
- (void)setMaxRecordedFileSize:(int64_t)value { _maxRecordedFileSize = value; }
- (int64_t)minFreeDiskSpaceLimit { return _minFreeDiskSpaceLimit; }
- (void)setMinFreeDiskSpaceLimit:(int64_t)value { _minFreeDiskSpaceLimit = value; }
- (void)startRecordingToOutputFileURL:(NSURL *)URL recordingDelegate:(id<AVCaptureFileOutputRecordingDelegate>)delegate
{
    if (!URL.isFileURL)
        [NSException raise:NSInvalidArgumentException format:@"Output URL must be a file URL"];
    NSError *error = capture_error(AVErrorDeviceNotConnected);
    if ([delegate respondsToSelector:@selector(captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:)])
        dispatch_async(dispatch_get_main_queue(), ^{
            [delegate captureOutput:self didFinishRecordingToOutputFileAtURL:URL fromConnections:@[] error:error];
        });
}
- (void)stopRecording {}
- (void)pauseRecording { _recordingPaused = YES; }
- (void)resumeRecording { _recordingPaused = NO; }
@end

@implementation AVCaptureMovieFileOutput {
    CMTime _movieFragmentInterval;
    NSArray *_metadata;
}
- (instancetype)init { return [self _finchInit]; }
- (CMTime)movieFragmentInterval { return _movieFragmentInterval; }
- (void)setMovieFragmentInterval:(CMTime)value { _movieFragmentInterval = value; }
- (NSArray<AVMetadataItem *> *)metadata { return _metadata ?: @[]; }
- (void)setMetadata:(NSArray<AVMetadataItem *> *)metadata { _metadata = [metadata copy] ?: @[]; }
- (NSArray<AVVideoCodecType> *)availableVideoCodecTypes { return @[]; }
- (NSDictionary<NSString *,id> *)outputSettingsForConnection:(AVCaptureConnection *)connection
{
    (void)connection;
    return nil;
}
- (void)setOutputSettings:(NSDictionary<NSString *,id> *)outputSettings forConnection:(AVCaptureConnection *)connection
{
    (void)outputSettings;
    (void)connection;
}
@end

@implementation AVCaptureAudioFileOutput {
    NSArray *_metadata;
    NSDictionary *_audioSettings;
}
- (instancetype)init { return [self _finchInit]; }
+ (NSArray<AVFileType> *)availableOutputFileTypes
{
    return @[ AVFileTypeWAVE, AVFileTypeAIFF, AVFileTypeCoreAudioFormat, AVFileTypeAIFC ] ?: @[];
}
- (NSArray<AVMetadataItem *> *)metadata { return _metadata ?: @[]; }
- (void)setMetadata:(NSArray<AVMetadataItem *> *)metadata { _metadata = [metadata copy] ?: @[]; }
- (NSDictionary<NSString *,id> *)audioSettings { return _audioSettings ?: @{}; }
- (void)setAudioSettings:(NSDictionary<NSString *,id> *)settings { _audioSettings = [settings copy] ?: @{}; }
- (void)startRecordingToOutputFileURL:(NSURL *)URL outputFileType:(AVFileType)fileType recordingDelegate:(id<AVCaptureFileOutputRecordingDelegate>)delegate
{
    if (![[AVCaptureAudioFileOutput availableOutputFileTypes] containsObject:fileType])
        [NSException raise:NSInvalidArgumentException format:@"Unsupported output file type"];
    [super startRecordingToOutputFileURL:URL recordingDelegate:delegate];
}
@end
