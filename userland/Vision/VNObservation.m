// SPDX-License-Identifier: MIT OR Apache-2.0
#import "VNPrivate.h"
#include <math.h>

@interface VNObservation (FinchStorage)
- (instancetype)_initWithRevision:(NSUInteger)revision confidence:(VNConfidence)confidence;
@end

@interface VNDetectedObjectObservation (FinchStorage)
- (instancetype)_initWithRevision:(NSUInteger)revision boundingBox:(CGRect)boundingBox confidence:(VNConfidence)confidence;
@end

@interface VNRectangleObservation (FinchStorage)
- (instancetype)_initWithRequestRevision:(NSUInteger)revision topLeft:(CGPoint)topLeft
                                 topRight:(CGPoint)topRight bottomRight:(CGPoint)bottomRight
                                bottomLeft:(CGPoint)bottomLeft confidence:(VNConfidence)confidence;
@end

@interface VNBarcodeObservation (FinchStorage)
- (instancetype)_initWithRequestRevision:(NSUInteger)revision topLeft:(CGPoint)topLeft
                                 topRight:(CGPoint)topRight bottomRight:(CGPoint)bottomRight
                                bottomLeft:(CGPoint)bottomLeft symbology:(VNBarcodeSymbology)symbology
                                   payload:(NSData *)payload string:(NSString *)string confidence:(VNConfidence)confidence;
@end

@interface VNHorizonObservation (FinchStorage)
- (instancetype)_initWithAngle:(CGFloat)angle imageWidth:(size_t)width imageHeight:(size_t)height revision:(NSUInteger)revision;
@end

@interface VNImageTranslationAlignmentObservation (FinchStorage)
- (instancetype)_initWithTransform:(CGAffineTransform)transform revision:(NSUInteger)revision confidence:(VNConfidence)confidence;
@end

@interface VNImageHomographicAlignmentObservation (FinchStorage)
- (instancetype)_initWithTransform:(matrix_float3x3)transform revision:(NSUInteger)revision confidence:(VNConfidence)confidence;
@end

@interface VNFeaturePrintObservation (FinchStorage)
- (instancetype)_initWithData:(NSData *)data elementType:(VNElementType)elementType revision:(NSUInteger)revision;
@end

@implementation VNObservation {
    NSUUID *_uuid;
    VNConfidence _confidence;
    NSUInteger _revision;
    CMTimeRange _timeRange;
}

- (instancetype)init { return [self _initWithRevision:1 confidence:0.0f]; }
- (instancetype)_initWithRevision:(NSUInteger)revision confidence:(VNConfidence)confidence
{
    if ((self = [super init])) {
        _uuid = [[NSUUID UUID] retain];
        _revision = revision;
        _confidence = confidence;
        _timeRange = CMTimeRangeMake(CMTimeMake(0, 1), CMTimeMake(0, 1));
    }
    return self;
}
- (void)dealloc { [_uuid release]; [super dealloc]; }
- (NSUUID *)uuid { return _uuid; }
- (VNConfidence)confidence { return _confidence; }
- (NSUInteger)revision { return _revision; }
- (NSUInteger)requestRevision { return _revision; }
- (CMTimeRange)timeRange { return _timeRange; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_uuid forKey:@"uuid"];
    [coder encodeFloat:_confidence forKey:@"confidence"];
    [coder encodeInteger:(NSInteger)_revision forKey:@"revision"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [self _initWithRevision:(NSUInteger)[coder decodeIntegerForKey:@"revision"]
                        confidence:[coder decodeFloatForKey:@"confidence"]];
    if (self) {
        NSUUID *uuid = [coder decodeObjectOfClass:NSUUID.class forKey:@"uuid"];
        if (uuid) { [_uuid release]; _uuid = [uuid retain]; }
    }
    return self;
}
@end

@implementation VNDetectedObjectObservation {
    CGRect _boundingBox;
}
+ (instancetype)observationWithBoundingBox:(CGRect)boundingBox
{
    return [self observationWithRequestRevision:1 boundingBox:boundingBox];
}
+ (instancetype)observationWithRequestRevision:(NSUInteger)revision boundingBox:(CGRect)boundingBox
{
    return [[[self alloc] _initWithRevision:revision boundingBox:boundingBox confidence:1.0f] autorelease];
}
- (instancetype)_initWithRevision:(NSUInteger)revision boundingBox:(CGRect)boundingBox confidence:(VNConfidence)confidence
{
    if ((self = [super _initWithRevision:revision confidence:confidence]))
        _boundingBox = boundingBox;
    return self;
}
- (CGRect)boundingBox { return _boundingBox; }
- (VNPixelBufferObservation *)globalSegmentationMask { return nil; }
@end

@implementation VNFaceObservation {
    VNFaceLandmarks2D *_landmarks;
    NSNumber *_faceCaptureQuality;
    NSNumber *_roll;
    NSNumber *_yaw;
    NSNumber *_pitch;
}
+ (instancetype)faceObservationWithRequestRevision:(NSUInteger)revision boundingBox:(CGRect)boundingBox
                                               roll:(NSNumber *)roll yaw:(NSNumber *)yaw
{
    return [self faceObservationWithRequestRevision:revision boundingBox:boundingBox roll:roll yaw:yaw pitch:nil];
}
+ (instancetype)faceObservationWithRequestRevision:(NSUInteger)revision boundingBox:(CGRect)boundingBox
                                               roll:(NSNumber *)roll yaw:(NSNumber *)yaw pitch:(NSNumber *)pitch
{
    VNFaceObservation *observation = [[[self alloc] _initWithRevision:revision boundingBox:boundingBox confidence:1.0f] autorelease];
    if (observation) {
        observation->_roll = [roll copy];
        observation->_yaw = [yaw copy];
        observation->_pitch = [pitch copy];
    }
    return observation;
}
- (void)dealloc
{
    [_landmarks release]; [_faceCaptureQuality release];
    [_roll release]; [_yaw release]; [_pitch release];
    [super dealloc];
}
- (VNFaceLandmarks2D *)landmarks { return _landmarks; }
- (NSNumber *)faceCaptureQuality { return _faceCaptureQuality; }
- (NSNumber *)roll { return _roll; }
- (NSNumber *)yaw { return _yaw; }
- (NSNumber *)pitch { return _pitch; }
@end

@implementation VNRectangleObservation {
    CGPoint _topLeft;
    CGPoint _topRight;
    CGPoint _bottomLeft;
    CGPoint _bottomRight;
}
+ (instancetype)rectangleObservationWithRequestRevision:(NSUInteger)revision topLeft:(CGPoint)topLeft
                                                 topRight:(CGPoint)topRight bottomRight:(CGPoint)bottomRight
                                               bottomLeft:(CGPoint)bottomLeft
{
    return [[[self alloc] _initWithRequestRevision:revision topLeft:topLeft topRight:topRight
                                       bottomRight:bottomRight bottomLeft:bottomLeft confidence:1.0f] autorelease];
}
+ (instancetype)rectangleObservationWithRequestRevision:(NSUInteger)revision topLeft:(CGPoint)topLeft
                                              bottomLeft:(CGPoint)bottomLeft bottomRight:(CGPoint)bottomRight
                                                 topRight:(CGPoint)topRight
{
    return [self rectangleObservationWithRequestRevision:revision topLeft:topLeft topRight:topRight
                                             bottomRight:bottomRight bottomLeft:bottomLeft];
}
- (instancetype)_initWithRequestRevision:(NSUInteger)revision topLeft:(CGPoint)topLeft
                                 topRight:(CGPoint)topRight bottomRight:(CGPoint)bottomRight
                                bottomLeft:(CGPoint)bottomLeft confidence:(VNConfidence)confidence
{
    CGFloat minX = MIN(MIN(topLeft.x, topRight.x), MIN(bottomLeft.x, bottomRight.x));
    CGFloat minY = MIN(MIN(topLeft.y, topRight.y), MIN(bottomLeft.y, bottomRight.y));
    CGFloat maxX = MAX(MAX(topLeft.x, topRight.x), MAX(bottomLeft.x, bottomRight.x));
    CGFloat maxY = MAX(MAX(topLeft.y, topRight.y), MAX(bottomLeft.y, bottomRight.y));
    if ((self = [super _initWithRevision:revision boundingBox:CGRectMake(minX, minY, maxX-minX, maxY-minY) confidence:confidence])) {
        _topLeft = topLeft; _topRight = topRight;
        _bottomLeft = bottomLeft; _bottomRight = bottomRight;
    }
    return self;
}
- (CGPoint)topLeft { return _topLeft; }
- (CGPoint)topRight { return _topRight; }
- (CGPoint)bottomLeft { return _bottomLeft; }
- (CGPoint)bottomRight { return _bottomRight; }
@end

@implementation VNBarcodeObservation {
    VNBarcodeSymbology _symbology;
    NSData *_payloadData;
    NSString *_payloadStringValue;
}
- (instancetype)_initWithRequestRevision:(NSUInteger)revision topLeft:(CGPoint)topLeft
                                 topRight:(CGPoint)topRight bottomRight:(CGPoint)bottomRight
                                bottomLeft:(CGPoint)bottomLeft symbology:(VNBarcodeSymbology)symbology
                                   payload:(NSData *)payload string:(NSString *)string confidence:(VNConfidence)confidence
{
    if ((self = [super _initWithRequestRevision:revision topLeft:topLeft topRight:topRight
                                     bottomRight:bottomRight bottomLeft:bottomLeft confidence:confidence])) {
        _symbology = [symbology copy];
        _payloadData = [payload copy];
        _payloadStringValue = [string copy];
    }
    return self;
}
- (void)dealloc { [_symbology release]; [_payloadData release]; [_payloadStringValue release]; [super dealloc]; }
- (VNBarcodeSymbology)symbology { return _symbology; }
- (CIBarcodeDescriptor *)barcodeDescriptor { return nil; }
- (NSString *)payloadStringValue { return _payloadStringValue; }
- (NSData *)payloadData { return _payloadData; }
- (BOOL)isGS1DataCarrier { return NO; }
- (BOOL)isColorInverted { return NO; }
- (VNBarcodeCompositeType)supplementalCompositeType { return VNBarcodeCompositeTypeNone; }
- (NSString *)supplementalPayloadString { return nil; }
- (NSData *)supplementalPayloadData { return nil; }
@end

@implementation VNHorizonObservation {
    CGAffineTransform _transform;
    CGFloat _angle;
    size_t _imageWidth;
    size_t _imageHeight;
}
- (instancetype)_initWithAngle:(CGFloat)angle imageWidth:(size_t)width imageHeight:(size_t)height revision:(NSUInteger)revision
{
    if ((self = [super _initWithRevision:revision confidence:1.0f])) {
        _angle = angle; _imageWidth = width; _imageHeight = height;
        _transform = CGAffineTransformMakeRotation(-angle);
    }
    return self;
}
- (CGAffineTransform)transform { return _transform; }
- (CGFloat)angle { return _angle; }
- (CGAffineTransform)transformForImageWidth:(size_t)width height:(size_t)height
{
    if (!width || !height) return CGAffineTransformIdentity;
    CGFloat cx = width / 2.0, cy = height / 2.0;
    CGAffineTransform t = CGAffineTransformMakeTranslation(-cx, -cy);
    t = CGAffineTransformRotate(t, -_angle);
    return CGAffineTransformTranslate(t, cx, cy);
}
@end

@implementation VNImageAlignmentObservation
@end

@implementation VNImageTranslationAlignmentObservation {
    CGAffineTransform _alignmentTransform;
}
- (instancetype)_initWithTransform:(CGAffineTransform)transform revision:(NSUInteger)revision confidence:(VNConfidence)confidence
{
    if ((self = [super _initWithRevision:revision confidence:confidence])) _alignmentTransform = transform;
    return self;
}
- (CGAffineTransform)alignmentTransform { return _alignmentTransform; }
@end

@implementation VNImageHomographicAlignmentObservation {
    matrix_float3x3 _warpTransform;
}
- (instancetype)_initWithTransform:(matrix_float3x3)transform revision:(NSUInteger)revision confidence:(VNConfidence)confidence
{
    if ((self = [super _initWithRevision:revision confidence:confidence])) _warpTransform = transform;
    return self;
}
- (matrix_float3x3)warpTransform { return _warpTransform; }
@end

@implementation VNFeaturePrintObservation {
    NSData *_data;
    VNElementType _elementType;
}
- (instancetype)_initWithData:(NSData *)data elementType:(VNElementType)elementType revision:(NSUInteger)revision
{
    if ((self = [super _initWithRevision:revision confidence:1.0f])) {
        _data = [data copy]; _elementType = elementType;
    }
    return self;
}
- (void)dealloc { [_data release]; [super dealloc]; }
- (VNElementType)elementType { return _elementType; }
- (NSUInteger)elementCount { NSUInteger n = VNElementTypeSize(_elementType); return n ? _data.length / n : 0; }
- (NSData *)data { return _data; }
- (BOOL)computeDistance:(float *)outDistance toFeaturePrintObservation:(VNFeaturePrintObservation *)other error:(NSError **)error
{
    if (!outDistance || !other || _elementType != other.elementType || self.elementCount != other.elementCount || !VNElementTypeSize(_elementType)) {
        if (error) *error = VNMakeError(VNErrorInvalidArgument, @"Feature prints must have matching numeric formats and lengths.");
        return NO;
    }
    double sum = 0.0;
    if (_elementType == VNElementTypeFloat) {
        const float *a = _data.bytes, *b = other.data.bytes;
        for (NSUInteger i = 0; i < self.elementCount; i++) { double d = (double)a[i] - b[i]; sum += d * d; }
    } else {
        const double *a = _data.bytes, *b = other.data.bytes;
        for (NSUInteger i = 0; i < self.elementCount; i++) { double d = a[i] - b[i]; sum += d * d; }
    }
    *outDistance = (float)sqrt(sum);
    if (error) *error = nil;
    return YES;
}
@end

@implementation VNContour {
    NSData *_pointData;
    NSIndexPath *_indexPath;
    NSArray *_children;
    CGPathRef _path;
    NSUInteger _revision;
    float _aspectRatio;
}
- (instancetype)_initWithPoints:(const simd_float2 *)points pointCount:(NSUInteger)pointCount
                        indexPath:(NSIndexPath *)indexPath aspectRatio:(float)aspectRatio revision:(NSUInteger)revision
{
    if (!points || !pointCount) { [self release]; return nil; }
    if ((self = [super init])) {
        _pointData = [[NSData alloc] initWithBytes:points length:pointCount * sizeof(simd_float2)];
        _indexPath = [indexPath copy]; _children = [[NSArray alloc] init];
        _revision = revision; _aspectRatio = aspectRatio;
        CGMutablePathRef path = CGPathCreateMutable();
        const simd_float2 *values = _pointData.bytes;
        CGPathMoveToPoint(path, NULL, values[0].x, values[0].y);
        for (NSUInteger i = 1; i < pointCount; i++) CGPathAddLineToPoint(path, NULL, values[i].x, values[i].y);
        if (pointCount > 2) CGPathCloseSubpath(path);
        _path = path;
    }
    return self;
}
- (void)dealloc { [_pointData release]; [_indexPath release]; [_children release]; CGPathRelease(_path); [super dealloc]; }
- (NSIndexPath *)indexPath { return _indexPath; }
- (NSInteger)childContourCount { return (NSInteger)_children.count; }
- (NSArray<VNContour *> *)childContours { return _children; }
- (VNContour *)childContourAtIndex:(NSUInteger)index error:(NSError **)error
{
    if (index >= _children.count) { if (error) *error = VNMakeError(VNErrorOutOfBoundsError, @"The child contour index is out of range."); return nil; }
    if (error) *error = nil;
    return [_children objectAtIndex:index];
}
- (NSInteger)pointCount { return (NSInteger)(_pointData.length / sizeof(simd_float2)); }
- (const simd_float2 *)normalizedPoints { return _pointData.bytes; }
- (CGPathRef)normalizedPath { return _path; }
- (float)aspectRatio { return _aspectRatio; }
- (NSUInteger)revision { return _revision; }
- (NSUInteger)requestRevision { return _revision; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
- (VNContour *)polygonApproximationWithEpsilon:(float)epsilon error:(NSError **)error
{
    if (epsilon < 0.0f || self.pointCount < 3) { if (error) *error = VNMakeError(VNErrorInvalidArgument, @"A non-negative tolerance and at least three points are required."); return nil; }
    if (error) *error = nil;
    return [self retain];
}
@end

@implementation VNContoursObservation {
    NSArray *_contours;
    NSArray *_topLevelContours;
    CGPathRef _normalizedPath;
}
- (instancetype)_initWithContours:(NSArray<VNContour *> *)contours revision:(NSUInteger)revision
{
    if ((self = [super _initWithRevision:revision confidence:1.0f])) {
        _contours = [contours copy]; _topLevelContours = [_contours copy];
        CGMutablePathRef path = CGPathCreateMutable();
        for (VNContour *contour in _contours) CGPathAddPath(path, NULL, contour.normalizedPath);
        _normalizedPath = path;
    }
    return self;
}
- (void)dealloc { [_contours release]; [_topLevelContours release]; CGPathRelease(_normalizedPath); [super dealloc]; }
- (NSInteger)contourCount { return (NSInteger)_contours.count; }
- (NSInteger)topLevelContourCount { return (NSInteger)_topLevelContours.count; }
- (NSArray<VNContour *> *)topLevelContours { return _topLevelContours; }
- (VNContour *)contourAtIndex:(NSInteger)index error:(NSError **)error
{
    if (index < 0 || (NSUInteger)index >= _contours.count) { if (error) *error = VNMakeError(VNErrorOutOfBoundsError, @"The contour index is out of range."); return nil; }
    if (error) *error = nil;
    return [_contours objectAtIndex:(NSUInteger)index];
}
- (VNContour *)contourAtIndexPath:(NSIndexPath *)indexPath error:(NSError **)error
{
    if (indexPath.length != 1) { if (error) *error = VNMakeError(VNErrorOutOfBoundsError, @"The contour path is not present."); return nil; }
    return [self contourAtIndex:(NSInteger)[indexPath indexAtPosition:0] error:error];
}
- (CGPathRef)normalizedPath { return _normalizedPath; }
@end

@implementation VNInstanceMaskObservation
- (CVPixelBufferRef)instanceMask { return NULL; }
- (NSIndexSet *)allInstances { return [NSIndexSet indexSet]; }
- (CVPixelBufferRef)generateMaskForInstances:(NSIndexSet *)instances error:(NSError **)error
{
    if (error) *error = VNMakeError(VNErrorUnsupportedRequest, @"This observation has no segmentation mask.");
    return NULL;
}
- (CVPixelBufferRef)generateMaskedImageOfInstances:(NSIndexSet *)instances
                                fromRequestHandler:(VNImageRequestHandler *)requestHandler
                      croppedToInstancesExtent:(BOOL)cropResult error:(NSError **)error
{
    if (error) *error = VNMakeError(VNErrorUnsupportedRequest, @"This observation has no segmentation mask.");
    return NULL;
}
- (CVPixelBufferRef)generateScaledMaskForImageForInstances:(NSIndexSet *)instances
                                       fromRequestHandler:(VNImageRequestHandler *)requestHandler
                                                    error:(NSError **)error
{
    if (error) *error = VNMakeError(VNErrorUnsupportedRequest, @"This observation has no segmentation mask.");
    return NULL;
}
@end

// Model-backed output types are registered as classes, but Finch does not
// create empty detections. Their instances can only come from real model output.
#define VN_MODEL_RESULT(name) \
    @implementation name \
    - (instancetype)init { [self release]; return nil; } \
    - (NSUInteger)requestRevision { return 0; } \
    - (id)copyWithZone:(NSZone *)zone { return [self retain]; } \
    + (BOOL)supportsSecureCoding { return YES; } \
    - (void)encodeWithCoder:(NSCoder *)coder { (void)coder; } \
    - (instancetype)initWithCoder:(NSCoder *)coder { (void)coder; [self release]; return nil; } \
    @end

VN_MODEL_RESULT(VNDetectedPoint)
VN_MODEL_RESULT(VNRecognizedPoint)
VN_MODEL_RESULT(VNFaceLandmarkRegion)
@implementation VNFaceLandmarkRegion2D
- (instancetype)init { [self release]; return nil; }
- (NSUInteger)requestRevision { return 0; }
- (const CGPoint *)pointsInImageOfSize:(CGSize)imageSize { return NULL; }
@end
VN_MODEL_RESULT(VNFaceLandmarks)
VN_MODEL_RESULT(VNClassificationObservation)
VN_MODEL_RESULT(VNRecognizedObjectObservation)
VN_MODEL_RESULT(VNCoreMLFeatureValueObservation)
VN_MODEL_RESULT(VNPixelBufferObservation)
VN_MODEL_RESULT(VNTrajectoryObservation)
VN_MODEL_RESULT(VNTextObservation)
VN_MODEL_RESULT(VNSaliencyImageObservation)
VN_MODEL_RESULT(VNImageAestheticsScoresObservation)
VN_MODEL_RESULT(VNHumanObservation)
VN_MODEL_RESULT(VNRecognizedPoint3D)
VN_MODEL_RESULT(VNHumanBodyRecognizedPoint3D)

#undef VN_MODEL_RESULT
