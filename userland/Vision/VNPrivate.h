// SPDX-License-Identifier: MIT OR Apache-2.0
#import <Vision/Vision.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <simd/simd.h>

NSError *VNMakeError(VNErrorCode code, NSString *description);
BOOL VNPerformRequestsWithCGImage(NSArray<VNRequest *> *requests,
                                  CGImageRef image,
                                  CGImageRef targetedImage,
                                  NSError **error);
CGImageRef VNCreateCGImageFromPixelBuffer(CVPixelBufferRef buffer);
CGImageRef VNCreateOrientedCGImage(CGImageRef image, CGImagePropertyOrientation orientation);

@interface VNRequest (FinchPrivate)
- (BOOL)_performOnImage:(CGImageRef)image targetedImage:(CGImageRef)targetedImage error:(NSError **)error;
- (void)_setResults:(NSArray *)results;
- (BOOL)_isCancelled;
@end

@interface VNTargetedImageRequest (FinchPrivate)
- (CGImageRef)_copyTargetedImage;
@end

@interface VNImageRequestHandler (FinchPrivate)
- (CGImageRef)_copyImageWithError:(NSError **)error;
@end

@interface VNContour (FinchPrivate)
- (instancetype)_initWithPoints:(const simd_float2 *)points
                      pointCount:(NSUInteger)pointCount
                        indexPath:(NSIndexPath *)indexPath
                       aspectRatio:(float)aspectRatio
                          revision:(NSUInteger)revision;
@end

@interface VNContoursObservation (FinchPrivate)
- (instancetype)_initWithContours:(NSArray<VNContour *> *)contours revision:(NSUInteger)revision;
@end
