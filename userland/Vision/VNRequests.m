// SPDX-License-Identifier: MIT OR Apache-2.0
#import "VNPrivate.h"
#import <objc/runtime.h>

NSError *VNMakeError(VNErrorCode code, NSString *description)
{
    return [NSError errorWithDomain:VNErrorDomain code:code
                            userInfo:@{ NSLocalizedDescriptionKey: description ?: @"Vision request failed." }];
}

@implementation VNRequest {
    VNRequestCompletionHandler _completionHandler;
    VNRequestProgressHandler _progressHandler;
    NSArray *_results;
    NSMutableDictionary *_computeDevices;
    NSUInteger _revision;
    BOOL _preferBackgroundProcessing;
    BOOL _usesCPUOnly;
    BOOL _cancelled;
}

+ (NSIndexSet *)supportedRevisions
{
    return [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, [self currentRevision])];
}

+ (NSUInteger)currentRevision
{
    NSString *name = NSStringFromClass(self);
    if ([name isEqualToString:@"VNDetectBarcodesRequest"]) return 4;
    if ([name isEqualToString:@"VNDetectFaceRectanglesRequest"] ||
        [name isEqualToString:@"VNDetectFaceLandmarksRequest"]) return 3;
    if ([name isEqualToString:@"VNGenerateAttentionBasedSaliencyImageRequest"]) return 2;
    return 1;
}

+ (NSUInteger)defaultRevision { return [self currentRevision]; }

- (instancetype)init
{
    return [self initWithCompletionHandler:nil];
}

- (instancetype)initWithCompletionHandler:(VNRequestCompletionHandler)completionHandler
{
    if ((self = [super init])) {
        _completionHandler = [completionHandler copy];
        _revision = [[self class] defaultRevision];
        _computeDevices = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [_completionHandler release];
    [_progressHandler release];
    [_results release];
    [_computeDevices release];
    [super dealloc];
}

- (BOOL)preferBackgroundProcessing { return _preferBackgroundProcessing; }
- (void)setPreferBackgroundProcessing:(BOOL)value { _preferBackgroundProcessing = value; }
- (BOOL)usesCPUOnly { return _usesCPUOnly; }
- (void)setUsesCPUOnly:(BOOL)value { _usesCPUOnly = value; }
- (NSUInteger)revision { return _revision; }
- (void)setRevision:(NSUInteger)value { _revision = value; }
- (NSArray *)results { @synchronized(self) { return [[_results copy] autorelease]; } }
- (VNRequestCompletionHandler)completionHandler { return _completionHandler; }
- (void)setProgressHandler:(VNRequestProgressHandler)value
{
    @synchronized(self) {
        [_progressHandler release];
        _progressHandler = [value copy];
    }
}
- (VNRequestProgressHandler)progressHandler { return _progressHandler; }
- (BOOL)indeterminate { return YES; }

- (void)_setResults:(NSArray *)results
{
    @synchronized(self) {
        [_results release];
        _results = [results copy];
    }
}

- (void)cancel
{
    @synchronized(self) { _cancelled = YES; }
}

- (BOOL)_isCancelled
{
    @synchronized(self) { return _cancelled; }
}

- (id<MLComputeDeviceProtocol>)computeDeviceForComputeStage:(VNComputeStage)stage
{
    @synchronized(self) { return [_computeDevices objectForKey:stage]; }
}

- (void)setComputeDevice:(id<MLComputeDeviceProtocol>)device forComputeStage:(VNComputeStage)stage
{
    @synchronized(self) {
        if (device)
            [_computeDevices setObject:device forKey:stage];
        else
            [_computeDevices removeObjectForKey:stage];
    }
}

- (NSDictionary *)supportedComputeStageDevicesAndReturnError:(NSError **)error
{
    if (error) *error = nil;
    return @{};
}

- (BOOL)_performOnImage:(CGImageRef)image targetedImage:(CGImageRef)targetedImage error:(NSError **)error
{
    if (error) *error = VNMakeError(VNErrorUnsupportedRequest,
                                     [NSString stringWithFormat:@"%@ needs a model that Finch does not include.", NSStringFromClass([self class])]);
    return NO;
}

- (id)copyWithZone:(NSZone *)zone
{
    VNRequest *copy = [[[self class] allocWithZone:zone] initWithCompletionHandler:_completionHandler];
    copy.preferBackgroundProcessing = self.preferBackgroundProcessing;
    copy.usesCPUOnly = self.usesCPUOnly;
    copy.revision = self.revision;
    if ([self isKindOfClass:VNImageBasedRequest.class])
        ((VNImageBasedRequest *)copy).regionOfInterest = ((VNImageBasedRequest *)self).regionOfInterest;
    return copy;
}

@end

@implementation VNImageBasedRequest {
    CGRect _regionOfInterest;
}

- (instancetype)init
{
    if ((self = [super init]))
        _regionOfInterest = VNNormalizedIdentityRect;
    return self;
}

- (instancetype)initWithCompletionHandler:(VNRequestCompletionHandler)completionHandler
{
    if ((self = [super initWithCompletionHandler:completionHandler]))
        _regionOfInterest = VNNormalizedIdentityRect;
    return self;
}

- (CGRect)regionOfInterest { return _regionOfInterest; }
- (void)setRegionOfInterest:(CGRect)value { _regionOfInterest = value; }

@end

@implementation VNTrackingRequest {
    VNDetectedObjectObservation *_inputObservation;
    VNRequestTrackingLevel _trackingLevel;
    BOOL _lastFrame;
}

- (instancetype)_initForTrackingWithCompletionHandler:(VNRequestCompletionHandler)handler
{
    return [super initWithCompletionHandler:handler];
}
- (void)dealloc
{
    [_inputObservation release];
    [super dealloc];
}
- (VNDetectedObjectObservation *)inputObservation { return _inputObservation; }
- (void)setInputObservation:(VNDetectedObjectObservation *)observation
{
    if (_inputObservation != observation) {
        [_inputObservation release];
        _inputObservation = [observation retain];
    }
}
- (VNRequestTrackingLevel)trackingLevel { return _trackingLevel; }
- (void)setTrackingLevel:(VNRequestTrackingLevel)value { _trackingLevel = value; }
- (BOOL)isLastFrame { return _lastFrame; }
- (void)setLastFrame:(BOOL)value { _lastFrame = value; }
- (NSUInteger)supportedNumberOfTrackersAndReturnError:(NSError **)error
{
    if (error) *error = nil;
    return 0;
}

@end

@implementation VNStatefulRequest {
    CMTime _frameAnalysisSpacing;
}

- (instancetype)initWithFrameAnalysisSpacing:(CMTime)frameAnalysisSpacing completionHandler:(VNRequestCompletionHandler)completionHandler
{
    if ((self = [super initWithCompletionHandler:completionHandler]))
        _frameAnalysisSpacing = frameAnalysisSpacing;
    return self;
}

- (NSInteger)minimumLatencyFrameCount { return 0; }
- (CMTime)frameAnalysisSpacing { return _frameAnalysisSpacing; }

@end

@implementation VNTargetedImageRequest {
    CGImageRef _targetImage;
}

- (void)dealloc
{
    CGImageRelease(_targetImage);
    [super dealloc];
}

- (instancetype)_initWithCGImage:(CGImageRef)image orientation:(CGImagePropertyOrientation)orientation options:(NSDictionary *)options completionHandler:(VNRequestCompletionHandler)handler
{
    if (!image) { [self release]; return nil; }
    if ((self = [super initWithCompletionHandler:handler]))
        _targetImage = VNCreateOrientedCGImage(image, orientation);
    return _targetImage ? self : ([(id)self release], (id)nil);
}

- (instancetype)initWithTargetedCGImage:(CGImageRef)image options:(NSDictionary *)options
{
    return [self _initWithCGImage:image orientation:kCGImagePropertyOrientationUp options:options completionHandler:nil];
}
- (instancetype)initWithTargetedCGImage:(CGImageRef)image options:(NSDictionary *)options completionHandler:(VNRequestCompletionHandler)handler
{
    return [self _initWithCGImage:image orientation:kCGImagePropertyOrientationUp options:options completionHandler:handler];
}
- (instancetype)initWithTargetedCGImage:(CGImageRef)image orientation:(CGImagePropertyOrientation)orientation options:(NSDictionary *)options
{
    return [self _initWithCGImage:image orientation:orientation options:options completionHandler:nil];
}
- (instancetype)initWithTargetedCGImage:(CGImageRef)image orientation:(CGImagePropertyOrientation)orientation options:(NSDictionary *)options completionHandler:(VNRequestCompletionHandler)handler
{
    return [self _initWithCGImage:image orientation:orientation options:options completionHandler:handler];
}

- (instancetype)initWithTargetedCIImage:(CIImage *)image options:(NSDictionary *)options
{
    return [self initWithTargetedCIImage:image orientation:kCGImagePropertyOrientationUp options:options];
}
- (instancetype)initWithTargetedCIImage:(CIImage *)image options:(NSDictionary *)options completionHandler:(VNRequestCompletionHandler)handler
{
    return [self initWithTargetedCIImage:image orientation:kCGImagePropertyOrientationUp options:options completionHandler:handler];
}
- (instancetype)initWithTargetedCIImage:(CIImage *)image orientation:(CGImagePropertyOrientation)orientation options:(NSDictionary *)options
{
    return [self initWithTargetedCIImage:image orientation:orientation options:options completionHandler:nil];
}
- (instancetype)initWithTargetedCIImage:(CIImage *)image orientation:(CGImagePropertyOrientation)orientation options:(NSDictionary *)options completionHandler:(VNRequestCompletionHandler)handler
{
    if (!image) { [self release]; return nil; }
    CIContext *context = [CIContext context];
    CGImageRef cg = [context createCGImage:image fromRect:image.extent];
    self = [self _initWithCGImage:cg orientation:orientation options:options completionHandler:handler];
    if (cg) CGImageRelease(cg);
    return self;
}

- (instancetype)initWithTargetedCVPixelBuffer:(CVPixelBufferRef)buffer options:(NSDictionary *)options
{
    return [self initWithTargetedCVPixelBuffer:buffer orientation:kCGImagePropertyOrientationUp options:options];
}
- (instancetype)initWithTargetedCVPixelBuffer:(CVPixelBufferRef)buffer options:(NSDictionary *)options completionHandler:(VNRequestCompletionHandler)handler
{
    return [self initWithTargetedCVPixelBuffer:buffer orientation:kCGImagePropertyOrientationUp options:options completionHandler:handler];
}
- (instancetype)initWithTargetedCVPixelBuffer:(CVPixelBufferRef)buffer orientation:(CGImagePropertyOrientation)orientation options:(NSDictionary *)options
{
    return [self initWithTargetedCVPixelBuffer:buffer orientation:orientation options:options completionHandler:nil];
}
- (instancetype)initWithTargetedCVPixelBuffer:(CVPixelBufferRef)buffer orientation:(CGImagePropertyOrientation)orientation options:(NSDictionary *)options completionHandler:(VNRequestCompletionHandler)handler
{
    CGImageRef cg = VNCreateCGImageFromPixelBuffer(buffer);
    self = [self _initWithCGImage:cg orientation:orientation options:options completionHandler:handler];
    if (cg) CGImageRelease(cg);
    return self;
}

- (instancetype)initWithTargetedImageURL:(NSURL *)url options:(NSDictionary *)options
{
    return [self initWithTargetedImageURL:url orientation:kCGImagePropertyOrientationUp options:options];
}
- (instancetype)initWithTargetedImageURL:(NSURL *)url options:(NSDictionary *)options completionHandler:(VNRequestCompletionHandler)handler
{
    return [self initWithTargetedImageURL:url orientation:kCGImagePropertyOrientationUp options:options completionHandler:handler];
}
- (instancetype)initWithTargetedImageURL:(NSURL *)url orientation:(CGImagePropertyOrientation)orientation options:(NSDictionary *)options
{
    return [self initWithTargetedImageURL:url orientation:orientation options:options completionHandler:nil];
}
- (instancetype)initWithTargetedImageURL:(NSURL *)url orientation:(CGImagePropertyOrientation)orientation options:(NSDictionary *)options completionHandler:(VNRequestCompletionHandler)handler
{
    CGImageSourceRef source = url ? CGImageSourceCreateWithURL((CFURLRef)url, NULL) : NULL;
    CGImageRef cg = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
    self = [self _initWithCGImage:cg orientation:orientation options:options completionHandler:handler];
    if (cg) CGImageRelease(cg);
    if (source) CFRelease(source);
    return self;
}

- (instancetype)initWithTargetedImageData:(NSData *)data options:(NSDictionary *)options
{
    return [self initWithTargetedImageData:data orientation:kCGImagePropertyOrientationUp options:options];
}
- (instancetype)initWithTargetedImageData:(NSData *)data options:(NSDictionary *)options completionHandler:(VNRequestCompletionHandler)handler
{
    return [self initWithTargetedImageData:data orientation:kCGImagePropertyOrientationUp options:options completionHandler:handler];
}
- (instancetype)initWithTargetedImageData:(NSData *)data orientation:(CGImagePropertyOrientation)orientation options:(NSDictionary *)options
{
    return [self initWithTargetedImageData:data orientation:orientation options:options completionHandler:nil];
}
- (instancetype)initWithTargetedImageData:(NSData *)data orientation:(CGImagePropertyOrientation)orientation options:(NSDictionary *)options completionHandler:(VNRequestCompletionHandler)handler
{
    CGImageSourceRef source = data ? CGImageSourceCreateWithData((CFDataRef)data, NULL) : NULL;
    CGImageRef cg = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
    self = [self _initWithCGImage:cg orientation:orientation options:options completionHandler:handler];
    if (cg) CGImageRelease(cg);
    if (source) CFRelease(source);
    return self;
}

- (instancetype)_initWithTargetedCMSampleBuffer:(CMSampleBufferRef)sampleBuffer
                                    orientation:(CGImagePropertyOrientation)orientation
                                        options:(NSDictionary *)options
                               completionHandler:(VNRequestCompletionHandler)handler
{
    CVImageBufferRef pixelBuffer = sampleBuffer ? CMSampleBufferGetImageBuffer(sampleBuffer) : NULL;
    CGImageRef cg = VNCreateCGImageFromPixelBuffer(pixelBuffer);
    self = [self _initWithCGImage:cg orientation:orientation options:options completionHandler:handler];
    if (cg) CGImageRelease(cg);
    return self;
}

- (instancetype)initWithTargetedCMSampleBuffer:(CMSampleBufferRef)sampleBuffer options:(NSDictionary *)options
{
    return [self initWithTargetedCMSampleBuffer:sampleBuffer orientation:kCGImagePropertyOrientationUp options:options];
}
- (instancetype)initWithTargetedCMSampleBuffer:(CMSampleBufferRef)sampleBuffer options:(NSDictionary *)options completionHandler:(VNRequestCompletionHandler)handler
{
    return [self initWithTargetedCMSampleBuffer:sampleBuffer orientation:kCGImagePropertyOrientationUp options:options completionHandler:handler];
}
- (instancetype)initWithTargetedCMSampleBuffer:(CMSampleBufferRef)sampleBuffer orientation:(CGImagePropertyOrientation)orientation options:(NSDictionary *)options
{
    return [self initWithTargetedCMSampleBuffer:sampleBuffer orientation:orientation options:options completionHandler:nil];
}
- (instancetype)initWithTargetedCMSampleBuffer:(CMSampleBufferRef)sampleBuffer orientation:(CGImagePropertyOrientation)orientation options:(NSDictionary *)options completionHandler:(VNRequestCompletionHandler)handler
{
    return [self _initWithTargetedCMSampleBuffer:sampleBuffer orientation:orientation options:options completionHandler:handler];
}

- (CGImageRef)_copyTargetedImage { return CGImageRetain(_targetImage); }

@end

@implementation VNImageRegistrationRequest
@end

@implementation VNTranslationalImageRegistrationRequest
@end

@implementation VNHomographicImageRegistrationRequest
@end

@implementation VNTrackTranslationalImageRegistrationRequest
- (instancetype)init
{
    return [self initWithCompletionHandler:nil];
}
- (instancetype)initWithCompletionHandler:(VNRequestCompletionHandler)completionHandler
{
    return [super initWithFrameAnalysisSpacing:kCMTimeZero completionHandler:completionHandler];
}
@end

@implementation VNTrackHomographicImageRegistrationRequest
- (instancetype)init
{
    return [self initWithCompletionHandler:nil];
}
- (instancetype)initWithCompletionHandler:(VNRequestCompletionHandler)completionHandler
{
    return [super initWithFrameAnalysisSpacing:kCMTimeZero completionHandler:completionHandler];
}
@end

@implementation VNDetectRectanglesRequest {
    VNAspectRatio _minimumAspectRatio;
    VNAspectRatio _maximumAspectRatio;
    VNDegrees _quadratureTolerance;
    float _minimumSize;
    VNConfidence _minimumConfidence;
    NSUInteger _maximumObservations;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _minimumAspectRatio = 0.3f;
        _maximumAspectRatio = 1.0f;
        _quadratureTolerance = 30.0f;
        _minimumSize = 0.2f;
        _minimumConfidence = 0.0f;
        _maximumObservations = 1;
    }
    return self;
}
- (VNAspectRatio)minimumAspectRatio { return _minimumAspectRatio; }
- (void)setMinimumAspectRatio:(VNAspectRatio)value { _minimumAspectRatio = value; }
- (VNAspectRatio)maximumAspectRatio { return _maximumAspectRatio; }
- (void)setMaximumAspectRatio:(VNAspectRatio)value { _maximumAspectRatio = value; }
- (VNDegrees)quadratureTolerance { return _quadratureTolerance; }
- (void)setQuadratureTolerance:(VNDegrees)value { _quadratureTolerance = value; }
- (float)minimumSize { return _minimumSize; }
- (void)setMinimumSize:(float)value { _minimumSize = value; }
- (VNConfidence)minimumConfidence { return _minimumConfidence; }
- (void)setMinimumConfidence:(VNConfidence)value { _minimumConfidence = value; }
- (NSUInteger)maximumObservations { return _maximumObservations; }
- (void)setMaximumObservations:(NSUInteger)value { _maximumObservations = value; }

@end

@implementation VNDetectBarcodesRequest {
    NSArray *_symbologies;
    BOOL _coalesceCompositeSymbologies;
}

+ (NSArray<VNBarcodeSymbology> *)supportedSymbologies { return @[ VNBarcodeSymbologyQR ]; }
- (instancetype)init
{
    if ((self = [super init]))
        _symbologies = [@[ VNBarcodeSymbologyQR ] copy];
    return self;
}
- (void)dealloc { [_symbologies release]; [super dealloc]; }
- (NSArray *)symbologies { return _symbologies; }
- (void)setSymbologies:(NSArray *)value
{
    [_symbologies release];
    _symbologies = [value copy];
}
- (BOOL)coalesceCompositeSymbologies { return _coalesceCompositeSymbologies; }
- (void)setCoalesceCompositeSymbologies:(BOOL)value { _coalesceCompositeSymbologies = value; }
- (NSArray<VNBarcodeSymbology> *)supportedSymbologiesAndReturnError:(NSError **)error
{
    if (error) *error = nil;
    return @[ VNBarcodeSymbologyQR ];
}

@end

@implementation VNDetectContoursRequest {
    float _contrastAdjustment;
    NSNumber *_contrastPivot;
    BOOL _detectsDarkOnLight;
    NSUInteger _maximumImageDimension;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _contrastAdjustment = 1.0f;
        _detectsDarkOnLight = YES;
        _maximumImageDimension = 512;
    }
    return self;
}
- (void)dealloc { [_contrastPivot release]; [super dealloc]; }
- (float)contrastAdjustment { return _contrastAdjustment; }
- (void)setContrastAdjustment:(float)value { _contrastAdjustment = value; }
- (NSNumber *)contrastPivot { return _contrastPivot; }
- (void)setContrastPivot:(NSNumber *)value
{
    [_contrastPivot release];
    _contrastPivot = [value retain];
}
- (BOOL)detectsDarkOnLight { return _detectsDarkOnLight; }
- (void)setDetectsDarkOnLight:(BOOL)value { _detectsDarkOnLight = value; }
- (BOOL)detectDarkOnLight { return _detectsDarkOnLight; }
- (void)setDetectDarkOnLight:(BOOL)value { self.detectsDarkOnLight = value; }
- (NSUInteger)maximumImageDimension { return _maximumImageDimension; }
- (void)setMaximumImageDimension:(NSUInteger)value { _maximumImageDimension = value; }

@end

@implementation VNDetectHorizonRequest
@end

// These requests have public configuration and result types, but their matching
// classifiers and segmenters require model files that Finch does not ship. They
// inherit VNRequest's explicit unsupported-request error.
@implementation VNDetectFaceRectanglesRequest
@end

@implementation VNDetectFaceLandmarksRequest {
    NSArray *_inputFaceObservations;
    VNRequestFaceLandmarksConstellation _constellation;
}
+ (BOOL)revision:(NSUInteger)requestRevision supportsConstellation:(VNRequestFaceLandmarksConstellation)constellation
{
    if (constellation == VNRequestFaceLandmarksConstellation65Points)
        return requestRevision >= 1 && requestRevision <= 3;
    if (constellation == VNRequestFaceLandmarksConstellation76Points)
        return requestRevision == 3;
    return NO;
}
- (void)dealloc { [_inputFaceObservations release]; [super dealloc]; }
- (NSArray<VNFaceObservation *> *)inputFaceObservations { return _inputFaceObservations; }
- (void)setInputFaceObservations:(NSArray<VNFaceObservation *> *)observations
{
    if (_inputFaceObservations != observations) {
        [_inputFaceObservations release];
        _inputFaceObservations = [observations copy];
    }
}
- (VNRequestFaceLandmarksConstellation)constellation { return _constellation; }
- (void)setConstellation:(VNRequestFaceLandmarksConstellation)value { _constellation = value; }
@end

@implementation VNGenerateAttentionBasedSaliencyImageRequest
@end

@implementation VNGenerateObjectnessBasedSaliencyImageRequest
@end

@implementation VNGenerateForegroundInstanceMaskRequest
@end

@implementation VNCalculateImageAestheticsScoresRequest
@end

@implementation VNClassifyImageRequest
+ (NSArray<VNClassificationObservation *> *)knownClassificationsForRevision:(NSUInteger)requestRevision error:(NSError **)error
{
    if (error) *error = VNMakeError(VNErrorUnsupportedRequest, @"Finch does not include the image classification model.");
    return nil;
}
- (NSArray<NSString *> *)supportedIdentifiersAndReturnError:(NSError **)error
{
    if (error) *error = VNMakeError(VNErrorUnsupportedRequest, @"Finch does not include the image classification model.");
    return nil;
}
@end

@implementation VNCoreMLModel {
    NSString *_inputImageFeatureName;
    id _featureProvider;
}
- (instancetype)init { [self release]; return nil; }
+ (instancetype)modelForMLModel:(MLModel *)model error:(NSError **)error
{
    if (error) *error = VNMakeError(VNErrorUnsupportedRequest, @"Core ML models are not available in Finch Vision.");
    return nil;
}
- (void)dealloc { [_inputImageFeatureName release]; [_featureProvider release]; [super dealloc]; }
- (NSString *)inputImageFeatureName { return _inputImageFeatureName; }
- (void)setInputImageFeatureName:(NSString *)name
{
    if (_inputImageFeatureName != name) {
        [_inputImageFeatureName release];
        _inputImageFeatureName = [name copy];
    }
}
- (id<MLFeatureProvider>)featureProvider { return _featureProvider; }
- (void)setFeatureProvider:(id<MLFeatureProvider>)provider
{
    if (_featureProvider != provider) {
        [_featureProvider release];
        _featureProvider = [(id)provider retain];
    }
}
@end

@implementation VNCoreMLRequest {
    VNCoreMLModel *_model;
    VNImageCropAndScaleOption _imageCropAndScaleOption;
}
- (instancetype)initWithModel:(VNCoreMLModel *)model
{
    return [self initWithModel:model completionHandler:nil];
}
- (instancetype)initWithModel:(VNCoreMLModel *)model completionHandler:(VNRequestCompletionHandler)handler
{
    if ((self = [super initWithCompletionHandler:handler])) {
        _model = [model retain];
        _imageCropAndScaleOption = VNImageCropAndScaleOptionScaleFit;
    }
    return self;
}
- (void)dealloc { [_model release]; [super dealloc]; }
- (VNCoreMLModel *)model { return _model; }
- (VNImageCropAndScaleOption)imageCropAndScaleOption { return _imageCropAndScaleOption; }
- (void)setImageCropAndScaleOption:(VNImageCropAndScaleOption)value { _imageCropAndScaleOption = value; }
@end

@implementation VNDetectAnimalBodyPoseRequest
- (NSArray<VNAnimalBodyPoseObservationJointName> *)supportedJointNamesAndReturnError:(NSError **)error
{
    if (error) *error = nil;
    return @[ VNAnimalBodyPoseObservationJointNameLeftBackElbow, VNAnimalBodyPoseObservationJointNameLeftBackKnee,
              VNAnimalBodyPoseObservationJointNameLeftBackPaw, VNAnimalBodyPoseObservationJointNameLeftEarBottom,
              VNAnimalBodyPoseObservationJointNameLeftEarMiddle, VNAnimalBodyPoseObservationJointNameLeftEarTop,
              VNAnimalBodyPoseObservationJointNameLeftEye, VNAnimalBodyPoseObservationJointNameLeftFrontElbow,
              VNAnimalBodyPoseObservationJointNameLeftFrontKnee, VNAnimalBodyPoseObservationJointNameLeftFrontPaw,
              VNAnimalBodyPoseObservationJointNameNeck, VNAnimalBodyPoseObservationJointNameNose,
              VNAnimalBodyPoseObservationJointNameRightBackElbow, VNAnimalBodyPoseObservationJointNameRightBackKnee,
              VNAnimalBodyPoseObservationJointNameRightBackPaw, VNAnimalBodyPoseObservationJointNameRightEarBottom,
              VNAnimalBodyPoseObservationJointNameRightEarMiddle, VNAnimalBodyPoseObservationJointNameRightEarTop,
              VNAnimalBodyPoseObservationJointNameRightEye, VNAnimalBodyPoseObservationJointNameRightFrontElbow,
              VNAnimalBodyPoseObservationJointNameRightFrontKnee, VNAnimalBodyPoseObservationJointNameRightFrontPaw,
              VNAnimalBodyPoseObservationJointNameTailBottom, VNAnimalBodyPoseObservationJointNameTailMiddle,
              VNAnimalBodyPoseObservationJointNameTailTop ];
}
- (NSArray<VNAnimalBodyPoseObservationJointsGroupName> *)supportedJointsGroupNamesAndReturnError:(NSError **)error
{
    if (error) *error = nil;
    return @[ VNAnimalBodyPoseObservationJointsGroupNameAll, VNAnimalBodyPoseObservationJointsGroupNameForelegs,
              VNAnimalBodyPoseObservationJointsGroupNameHead, VNAnimalBodyPoseObservationJointsGroupNameHindlegs,
              VNAnimalBodyPoseObservationJointsGroupNameTail, VNAnimalBodyPoseObservationJointsGroupNameTrunk ];
}
@end

@implementation VNDetectDocumentSegmentationRequest
@end

@implementation VNDetectFaceCaptureQualityRequest {
    NSArray *_inputFaceObservations;
}
- (void)dealloc { [_inputFaceObservations release]; [super dealloc]; }
- (NSArray<VNFaceObservation *> *)inputFaceObservations { return _inputFaceObservations; }
- (void)setInputFaceObservations:(NSArray<VNFaceObservation *> *)observations
{
    if (_inputFaceObservations != observations) {
        [_inputFaceObservations release];
        _inputFaceObservations = [observations copy];
    }
}
@end

@implementation VNDetectHumanBodyPose3DRequest
- (instancetype)init { return [self initWithCompletionHandler:nil]; }
- (instancetype)initWithCompletionHandler:(VNRequestCompletionHandler)handler
{
    return [super initWithFrameAnalysisSpacing:kCMTimeZero completionHandler:handler];
}
- (NSArray<VNHumanBodyPose3DObservationJointName> *)supportedJointNamesAndReturnError:(NSError **)error
{
    if (error) *error = nil;
    return @[ VNHumanBodyPose3DObservationJointNameCenterHead, VNHumanBodyPose3DObservationJointNameCenterShoulder,
              VNHumanBodyPose3DObservationJointNameLeftAnkle, VNHumanBodyPose3DObservationJointNameLeftElbow,
              VNHumanBodyPose3DObservationJointNameLeftHip, VNHumanBodyPose3DObservationJointNameLeftKnee,
              VNHumanBodyPose3DObservationJointNameLeftShoulder, VNHumanBodyPose3DObservationJointNameLeftWrist,
              VNHumanBodyPose3DObservationJointNameRightAnkle, VNHumanBodyPose3DObservationJointNameRightElbow,
              VNHumanBodyPose3DObservationJointNameRightHip, VNHumanBodyPose3DObservationJointNameRightKnee,
              VNHumanBodyPose3DObservationJointNameRightShoulder, VNHumanBodyPose3DObservationJointNameRightWrist,
              VNHumanBodyPose3DObservationJointNameRoot, VNHumanBodyPose3DObservationJointNameSpine,
              VNHumanBodyPose3DObservationJointNameTopHead ];
}
- (NSArray<VNHumanBodyPose3DObservationJointsGroupName> *)supportedJointsGroupNamesAndReturnError:(NSError **)error
{
    if (error) *error = nil;
    return @[ VNHumanBodyPose3DObservationJointsGroupNameAll, VNHumanBodyPose3DObservationJointsGroupNameHead,
              VNHumanBodyPose3DObservationJointsGroupNameLeftArm, VNHumanBodyPose3DObservationJointsGroupNameLeftLeg,
              VNHumanBodyPose3DObservationJointsGroupNameRightArm, VNHumanBodyPose3DObservationJointsGroupNameRightLeg,
              VNHumanBodyPose3DObservationJointsGroupNameTorso ];
}
@end

@implementation VNDetectHumanBodyPoseRequest
+ (NSArray<VNHumanBodyPoseObservationJointName> *)supportedJointNamesForRevision:(NSUInteger)revision error:(NSError **)error
{
    if (revision < 1 || revision > 3) {
        if (error) *error = VNMakeError(VNErrorUnsupportedRevision, @"The body pose revision is not supported.");
        return nil;
    }
    if (error) *error = nil;
    return @[ VNHumanBodyPoseObservationJointNameLeftAnkle, VNHumanBodyPoseObservationJointNameLeftEar,
              VNHumanBodyPoseObservationJointNameLeftElbow, VNHumanBodyPoseObservationJointNameLeftEye,
              VNHumanBodyPoseObservationJointNameLeftHip, VNHumanBodyPoseObservationJointNameLeftKnee,
              VNHumanBodyPoseObservationJointNameLeftShoulder, VNHumanBodyPoseObservationJointNameLeftWrist,
              VNHumanBodyPoseObservationJointNameNeck, VNHumanBodyPoseObservationJointNameNose,
              VNHumanBodyPoseObservationJointNameRightAnkle, VNHumanBodyPoseObservationJointNameRightEar,
              VNHumanBodyPoseObservationJointNameRightElbow, VNHumanBodyPoseObservationJointNameRightEye,
              VNHumanBodyPoseObservationJointNameRightHip, VNHumanBodyPoseObservationJointNameRightKnee,
              VNHumanBodyPoseObservationJointNameRightShoulder, VNHumanBodyPoseObservationJointNameRightWrist,
              VNHumanBodyPoseObservationJointNameRoot ];
}
+ (NSArray<VNHumanBodyPoseObservationJointsGroupName> *)supportedJointsGroupNamesForRevision:(NSUInteger)revision error:(NSError **)error
{
    if (revision < 1 || revision > 3) {
        if (error) *error = VNMakeError(VNErrorUnsupportedRevision, @"The body pose revision is not supported.");
        return nil;
    }
    if (error) *error = nil;
    return @[ VNHumanBodyPoseObservationJointsGroupNameAll, VNHumanBodyPoseObservationJointsGroupNameFace,
              VNHumanBodyPoseObservationJointsGroupNameLeftArm, VNHumanBodyPoseObservationJointsGroupNameLeftLeg,
              VNHumanBodyPoseObservationJointsGroupNameRightArm, VNHumanBodyPoseObservationJointsGroupNameRightLeg,
              VNHumanBodyPoseObservationJointsGroupNameTorso ];
}
- (NSArray<VNHumanBodyPoseObservationJointName> *)supportedJointNamesAndReturnError:(NSError **)error
{
    return [[self class] supportedJointNamesForRevision:self.revision error:error];
}
- (NSArray<VNHumanBodyPoseObservationJointsGroupName> *)supportedJointsGroupNamesAndReturnError:(NSError **)error
{
    return [[self class] supportedJointsGroupNamesForRevision:self.revision error:error];
}
@end

@implementation VNDetectHumanHandPoseRequest
+ (NSArray<VNHumanHandPoseObservationJointName> *)supportedJointNamesForRevision:(NSUInteger)revision error:(NSError **)error
{
    if (revision < 1 || revision > 2) {
        if (error) *error = VNMakeError(VNErrorUnsupportedRevision, @"The hand pose revision is not supported.");
        return nil;
    }
    if (error) *error = nil;
    return @[ VNHumanHandPoseObservationJointNameIndexDIP, VNHumanHandPoseObservationJointNameIndexMCP,
              VNHumanHandPoseObservationJointNameIndexPIP, VNHumanHandPoseObservationJointNameIndexTip,
              VNHumanHandPoseObservationJointNameLittleDIP, VNHumanHandPoseObservationJointNameLittleMCP,
              VNHumanHandPoseObservationJointNameLittlePIP, VNHumanHandPoseObservationJointNameLittleTip,
              VNHumanHandPoseObservationJointNameMiddleDIP, VNHumanHandPoseObservationJointNameMiddleMCP,
              VNHumanHandPoseObservationJointNameMiddlePIP, VNHumanHandPoseObservationJointNameMiddleTip,
              VNHumanHandPoseObservationJointNameRingDIP, VNHumanHandPoseObservationJointNameRingMCP,
              VNHumanHandPoseObservationJointNameRingPIP, VNHumanHandPoseObservationJointNameRingTip,
              VNHumanHandPoseObservationJointNameThumbCMC, VNHumanHandPoseObservationJointNameThumbIP,
              VNHumanHandPoseObservationJointNameThumbMP, VNHumanHandPoseObservationJointNameThumbTip,
              VNHumanHandPoseObservationJointNameWrist ];
}
+ (NSArray<VNHumanHandPoseObservationJointsGroupName> *)supportedJointsGroupNamesForRevision:(NSUInteger)revision error:(NSError **)error
{
    if (revision < 1 || revision > 2) {
        if (error) *error = VNMakeError(VNErrorUnsupportedRevision, @"The hand pose revision is not supported.");
        return nil;
    }
    if (error) *error = nil;
    return @[ VNHumanHandPoseObservationJointsGroupNameAll, VNHumanHandPoseObservationJointsGroupNameIndexFinger,
              VNHumanHandPoseObservationJointsGroupNameLittleFinger, VNHumanHandPoseObservationJointsGroupNameMiddleFinger,
              VNHumanHandPoseObservationJointsGroupNameRingFinger, VNHumanHandPoseObservationJointsGroupNameThumb ];
}
- (NSArray<VNHumanHandPoseObservationJointName> *)supportedJointNamesAndReturnError:(NSError **)error
{
    return [[self class] supportedJointNamesForRevision:self.revision error:error];
}
- (NSArray<VNHumanHandPoseObservationJointsGroupName> *)supportedJointsGroupNamesAndReturnError:(NSError **)error
{
    return [[self class] supportedJointsGroupNamesForRevision:self.revision error:error];
}
@end

@implementation VNDetectHumanRectanglesRequest
@end

@implementation VNDetectTextRectanglesRequest
@end

@implementation VNDetectTrajectoriesRequest {
    NSInteger _trajectoryLength;
    float _minimumRadius;
    float _maximumRadius;
    CMTime _targetFrameTime;
}
- (instancetype)initWithFrameAnalysisSpacing:(CMTime)frameAnalysisSpacing trajectoryLength:(NSInteger)trajectoryLength
                          completionHandler:(VNRequestCompletionHandler)handler
{
    if ((self = [super initWithFrameAnalysisSpacing:frameAnalysisSpacing completionHandler:handler])) {
        _trajectoryLength = trajectoryLength;
        _maximumRadius = 1.0f;
        _targetFrameTime = kCMTimeInvalid;
    }
    return self;
}
- (NSInteger)trajectoryLength { return _trajectoryLength; }
- (float)objectMinimumNormalizedRadius { return _minimumRadius; }
- (void)setObjectMinimumNormalizedRadius:(float)value { _minimumRadius = value; }
- (float)minimumObjectSize { return self.objectMinimumNormalizedRadius; }
- (void)setMinimumObjectSize:(float)value { self.objectMinimumNormalizedRadius = value; }
- (float)objectMaximumNormalizedRadius { return _maximumRadius; }
- (void)setObjectMaximumNormalizedRadius:(float)value { _maximumRadius = value; }
- (float)maximumObjectSize { return self.objectMaximumNormalizedRadius; }
- (void)setMaximumObjectSize:(float)value { self.objectMaximumNormalizedRadius = value; }
- (CMTime)targetFrameTime { return _targetFrameTime; }
- (void)setTargetFrameTime:(CMTime)value { _targetFrameTime = value; }
@end

@implementation VNGenerateImageFeaturePrintRequest
@end

@implementation VNGenerateOpticalFlowRequest
@end

@implementation VNGeneratePersonInstanceMaskRequest
@end

@implementation VNGeneratePersonSegmentationRequest {
    VNGeneratePersonSegmentationRequestQualityLevel _qualityLevel;
    OSType _outputPixelFormat;
}
+ (instancetype)new { return nil; }
- (instancetype)init { return [self initWithCompletionHandler:nil]; }
- (instancetype)initWithCompletionHandler:(VNRequestCompletionHandler)handler
{
    if ((self = [super initWithFrameAnalysisSpacing:kCMTimeZero completionHandler:handler]))
        _outputPixelFormat = kCVPixelFormatType_OneComponent8;
    return self;
}
- (VNGeneratePersonSegmentationRequestQualityLevel)qualityLevel { return _qualityLevel; }
- (void)setQualityLevel:(VNGeneratePersonSegmentationRequestQualityLevel)value { _qualityLevel = value; }
- (OSType)outputPixelFormat { return _outputPixelFormat; }
- (void)setOutputPixelFormat:(OSType)value { _outputPixelFormat = value; }
- (NSArray<NSNumber *> *)supportedOutputPixelFormatsAndReturnError:(NSError **)error
{
    if (error) *error = nil;
    return @[ @(kCVPixelFormatType_OneComponent32Float), @(kCVPixelFormatType_OneComponent16Half),
              @(kCVPixelFormatType_OneComponent8) ];
}
@end

@implementation VNRecognizeAnimalsRequest
+ (NSArray<VNAnimalIdentifier> *)knownAnimalIdentifiersForRevision:(NSUInteger)requestRevision error:(NSError **)error
{
    if (requestRevision != 1) {
        if (error) *error = VNMakeError(VNErrorUnsupportedRevision, @"The animal recognition revision is not supported.");
        return nil;
    }
    if (error) *error = nil;
    return @[ VNAnimalIdentifierCat, VNAnimalIdentifierDog ];
}
- (NSArray<VNAnimalIdentifier> *)supportedIdentifiersAndReturnError:(NSError **)error
{
    return [[self class] knownAnimalIdentifiersForRevision:self.revision error:error];
}
@end

@implementation VNRecognizeTextRequest
+ (NSArray<NSString *> *)supportedRecognitionLanguagesForTextRecognitionLevel:(VNRequestTextRecognitionLevel)level
                                                                      revision:(NSUInteger)requestRevision error:(NSError **)error
{
    if (error) *error = VNMakeError(VNErrorUnsupportedRequest, @"Finch does not include an optical character recognition model.");
    return nil;
}
- (NSArray<NSString *> *)supportedRecognitionLanguagesAndReturnError:(NSError **)error
{
    if (error) *error = VNMakeError(VNErrorUnsupportedRequest, @"Finch does not include an optical character recognition model.");
    return nil;
}
- (VNRequestProgressHandler)progressHandler { return [super progressHandler]; }
- (void)setProgressHandler:(VNRequestProgressHandler)handler { [super setProgressHandler:handler]; }
- (BOOL)indeterminate { return YES; }
@end

@implementation VNTrackObjectRequest
- (instancetype)initWithDetectedObjectObservation:(VNDetectedObjectObservation *)observation
{
    return [self initWithDetectedObjectObservation:observation completionHandler:nil];
}
- (instancetype)initWithDetectedObjectObservation:(VNDetectedObjectObservation *)observation completionHandler:(VNRequestCompletionHandler)handler
{
    if ((self = [self _initForTrackingWithCompletionHandler:handler])) self.inputObservation = observation;
    return self;
}
@end

@implementation VNTrackOpticalFlowRequest
- (instancetype)init { return [self initWithCompletionHandler:nil]; }
- (instancetype)initWithCompletionHandler:(VNRequestCompletionHandler)handler
{
    return [super initWithFrameAnalysisSpacing:kCMTimeZero completionHandler:handler];
}
@end

// VNTrackingRequest hides its initializer because it is abstract. The private
// helper still calls its VNImageBasedRequest initializer before setting state.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-designated-initializers"
@implementation VNTrackRectangleRequest
- (instancetype)initWithRectangleObservation:(VNRectangleObservation *)observation
{
    return [self initWithRectangleObservation:observation completionHandler:nil];
}
- (instancetype)initWithRectangleObservation:(VNRectangleObservation *)observation completionHandler:(VNRequestCompletionHandler)handler
{
    if ((self = [self _initForTrackingWithCompletionHandler:handler])) self.inputObservation = observation;
    return self;
}
@end
#pragma clang diagnostic pop

@interface VNTrackLegacyFaceCoreObjectRequest : VNTrackingRequest
@end

@implementation VNTrackLegacyFaceCoreObjectRequest
@end

BOOL VNPerformRequestsWithCGImage(NSArray<VNRequest *> *requests, CGImageRef image,
                                  CGImageRef targetedImage, NSError **error)
{
    if (error) *error = nil;
    if (!image) {
        if (error) *error = VNMakeError(VNErrorInvalidImage, @"The image handler has no valid image.");
        return NO;
    }
    for (id candidate in requests) {
        if (![candidate isKindOfClass:VNRequest.class]) {
            if (error) *error = VNMakeError(VNErrorInvalidArgument, @"Every request must be a VNRequest.");
            return NO;
        }
        VNRequest *request = candidate;
        NSError *requestError = nil;
        if ([request _isCancelled]) {
            requestError = VNMakeError(VNErrorRequestCancelled, @"The request was cancelled.");
        } else if (![[[request class] supportedRevisions] containsIndex:request.revision]) {
            requestError = VNMakeError(VNErrorUnsupportedRevision, @"The requested revision is not supported.");
        } else {
            [request _setResults:nil];
            CGImageRef requestTarget = targetedImage;
            BOOL releaseTarget = NO;
            if ([request isKindOfClass:VNTargetedImageRequest.class]) {
                CGImageRef explicitTarget = [(VNTargetedImageRequest *)request _copyTargetedImage];
                if (explicitTarget) {
                    requestTarget = explicitTarget;
                    releaseTarget = YES;
                }
            }
            [request _performOnImage:image targetedImage:requestTarget error:&requestError];
            if (releaseTarget && requestTarget) CGImageRelease(requestTarget);
        }
        if (request.completionHandler)
            request.completionHandler(request, requestError);
        if (requestError) {
            if (error) *error = requestError;
            return NO;
        }
    }
    return YES;
}
