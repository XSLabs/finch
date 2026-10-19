// SPDX-License-Identifier: MIT OR Apache-2.0
#import "VNPrivate.h"

CGRect VNNormalizedRectForImageRect(CGRect imageRect, size_t imageWidth, size_t imageHeight)
{
    if (!imageWidth || !imageHeight)
        return CGRectZero;
    return CGRectMake(imageRect.origin.x / imageWidth,
                      1.0 - CGRectGetMaxY(imageRect) / imageHeight,
                      imageRect.size.width / imageWidth,
                      imageRect.size.height / imageHeight);
}

CGRect VNImageRectForNormalizedRect(CGRect normalizedRect, size_t imageWidth, size_t imageHeight)
{
    return CGRectMake(normalizedRect.origin.x * imageWidth,
                      (1.0 - CGRectGetMaxY(normalizedRect)) * imageHeight,
                      normalizedRect.size.width * imageWidth,
                      normalizedRect.size.height * imageHeight);
}

CGRect VNNormalizedRectForImageRectUsingRegionOfInterest(CGRect imageRect, size_t imageWidth,
                                                          size_t imageHeight, CGRect roi)
{
    if (!imageWidth || !imageHeight || CGRectIsEmpty(roi))
        return CGRectZero;
    CGRect roiImage = VNImageRectForNormalizedRect(roi, imageWidth, imageHeight);
    CGRect relative = CGRectOffset(imageRect, -roiImage.origin.x, -roiImage.origin.y);
    CGRect result = VNNormalizedRectForImageRect(relative, (size_t)roiImage.size.width,
                                                  (size_t)roiImage.size.height);
    return result;
}

CGRect VNImageRectForNormalizedRectUsingRegionOfInterest(CGRect normalizedRect, size_t imageWidth,
                                                          size_t imageHeight, CGRect roi)
{
    CGRect roiImage = VNImageRectForNormalizedRect(roi, imageWidth, imageHeight);
    CGRect local = VNImageRectForNormalizedRect(normalizedRect,
                                                 (size_t)roiImage.size.width,
                                                 (size_t)roiImage.size.height);
    return CGRectOffset(local, roiImage.origin.x, roiImage.origin.y);
}

BOOL VNNormalizedRectIsIdentityRect(CGRect normalizedRect)
{
    return CGRectEqualToRect(normalizedRect, VNNormalizedIdentityRect);
}

CGPoint VNNormalizedPointForImagePoint(CGPoint imagePoint, size_t imageWidth, size_t imageHeight)
{
    if (!imageWidth || !imageHeight)
        return CGPointZero;
    return CGPointMake(imagePoint.x / imageWidth, 1.0 - imagePoint.y / imageHeight);
}

CGPoint VNImagePointForNormalizedPoint(CGPoint normalizedPoint, size_t imageWidth, size_t imageHeight)
{
    return CGPointMake(normalizedPoint.x * imageWidth, (1.0 - normalizedPoint.y) * imageHeight);
}

CGPoint VNNormalizedPointForImagePointUsingRegionOfInterest(CGPoint imagePoint, size_t imageWidth,
                                                             size_t imageHeight, CGRect roi)
{
    CGRect roiImage = VNImageRectForNormalizedRect(roi, imageWidth, imageHeight);
    CGPoint relative = CGPointMake(imagePoint.x - roiImage.origin.x,
                                   imagePoint.y - roiImage.origin.y);
    return VNNormalizedPointForImagePoint(relative, (size_t)roiImage.size.width,
                                           (size_t)roiImage.size.height);
}

CGPoint VNImagePointForNormalizedPointUsingRegionOfInterest(CGPoint normalizedPoint, size_t imageWidth,
                                                             size_t imageHeight, CGRect roi)
{
    CGRect roiImage = VNImageRectForNormalizedRect(roi, imageWidth, imageHeight);
    CGPoint local = VNImagePointForNormalizedPoint(normalizedPoint,
                                                    (size_t)roiImage.size.width,
                                                    (size_t)roiImage.size.height);
    return CGPointMake(local.x + roiImage.origin.x, local.y + roiImage.origin.y);
}

CGPoint VNNormalizedFaceBoundingBoxPointForLandmarkPoint(vector_float2 landmark,
                                                          CGRect faceBoundingBox,
                                                          size_t imageWidth, size_t imageHeight)
{
    CGPoint point = CGPointMake(faceBoundingBox.origin.x + landmark.x * faceBoundingBox.size.width,
                                faceBoundingBox.origin.y + landmark.y * faceBoundingBox.size.height);
    return VNImagePointForNormalizedPoint(point, imageWidth, imageHeight);
}

CGPoint VNImagePointForFaceLandmarkPoint(vector_float2 landmark, CGRect faceBoundingBox,
                                          size_t imageWidth, size_t imageHeight)
{
    return VNNormalizedFaceBoundingBoxPointForLandmarkPoint(landmark, faceBoundingBox,
                                                             imageWidth, imageHeight);
}

NSUInteger VNElementTypeSize(VNElementType elementType)
{
    switch (elementType) {
        case VNElementTypeFloat: return sizeof(float);
        case VNElementTypeDouble: return sizeof(double);
        default: return 0;
    }
}
