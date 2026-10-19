// SPDX-License-Identifier: MIT OR Apache-2.0
#import "VNPrivate.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    size_t width;
    size_t height;
    uint8_t *gray;
} VNGrayImage;

typedef struct {
    size_t minX, minY, maxX, maxY;
    size_t count;
    double sumX, sumY, sumXX, sumYY, sumXY;
} VNComponent;

static void VNGrayImageFree(VNGrayImage *image)
{
    free(image->gray);
    memset(image, 0, sizeof(*image));
}

static BOOL VNGrayImageCreate(CGImageRef image, VNGrayImage *out)
{
    memset(out, 0, sizeof(*out));
    if (!image) return NO;
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    if (!width || !height || width > SIZE_MAX / height) return NO;
    uint8_t *gray = calloc(width, height);
    if (!gray) return NO;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceGray();
    CGContextRef context = CGBitmapContextCreate(gray, width, height, 8, width, space, (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(space);
    if (!context) { free(gray); return NO; }
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context);
    out->width = width; out->height = height; out->gray = gray;
    return YES;
}

static BOOL VNIsDark(const VNGrayImage *image, size_t x, size_t y, uint8_t threshold)
{
    return image->gray[y * image->width + x] < threshold;
}

static size_t VNFindComponents(const VNGrayImage *image, uint8_t threshold, VNComponent **outComponents)
{
    size_t pixelCount = image->width * image->height;
    uint8_t *seen = calloc(pixelCount, 1);
    size_t *queue = malloc(pixelCount * sizeof(size_t));
    VNComponent *components = malloc(pixelCount * sizeof(VNComponent));
    if (!seen || !queue || !components) {
        free(seen); free(queue); free(components); *outComponents = NULL; return 0;
    }
    size_t count = 0;
    for (size_t start = 0; start < pixelCount; start++) {
        if (seen[start] || image->gray[start] >= threshold) continue;
        size_t head = 0, tail = 0;
        queue[tail++] = start; seen[start] = 1;
        VNComponent c = { .minX = image->width, .minY = image->height, .maxX = 0, .maxY = 0 };
        while (head < tail) {
            size_t index = queue[head++];
            size_t x = index % image->width, y = index / image->width;
            c.minX = MIN(c.minX, x); c.maxX = MAX(c.maxX, x);
            c.minY = MIN(c.minY, y); c.maxY = MAX(c.maxY, y);
            c.count++;
            c.sumX += x; c.sumY += y;
            c.sumXX += (double)x * x; c.sumYY += (double)y * y; c.sumXY += (double)x * y;
            size_t minNX = x ? x - 1 : x, maxNX = MIN(x + 1, image->width - 1);
            size_t minNY = y ? y - 1 : y, maxNY = MIN(y + 1, image->height - 1);
            for (size_t ny = minNY; ny <= maxNY; ny++) {
                for (size_t nx = minNX; nx <= maxNX; nx++) {
                    size_t next = ny * image->width + nx;
                    if (!seen[next] && image->gray[next] < threshold) {
                        seen[next] = 1;
                        queue[tail++] = next;
                    }
                }
            }
        }
        components[count++] = c;
    }
    free(seen); free(queue);
    *outComponents = components;
    return count;
}

static BOOL VNComponentInROI(VNComponent c, VNGrayImage image, CGRect roi)
{
    CGRect pixels = VNImageRectForNormalizedRect(roi, image.width, image.height);
    double cx = ((double)c.minX + c.maxX + 1.0) / 2.0;
    double cy = ((double)c.minY + c.maxY + 1.0) / 2.0;
    return cx >= CGRectGetMinX(pixels) && cx <= CGRectGetMaxX(pixels) &&
           cy >= CGRectGetMinY(pixels) && cy <= CGRectGetMaxY(pixels);
}

static CGPoint VNNormalizedTopLeftPoint(double x, double y, size_t width, size_t height)
{
    return CGPointMake(x / width, 1.0 - y / height);
}

@interface VNRectangleObservation (VNAlgorithmInit)
- (instancetype)_initWithRequestRevision:(NSUInteger)revision topLeft:(CGPoint)topLeft
                                 topRight:(CGPoint)topRight bottomRight:(CGPoint)bottomRight
                                bottomLeft:(CGPoint)bottomLeft confidence:(VNConfidence)confidence;
@end

@interface VNBarcodeObservation (VNAlgorithmInit)
- (instancetype)_initWithRequestRevision:(NSUInteger)revision topLeft:(CGPoint)topLeft
                                 topRight:(CGPoint)topRight bottomRight:(CGPoint)bottomRight
                                bottomLeft:(CGPoint)bottomLeft symbology:(VNBarcodeSymbology)symbology
                                   payload:(NSData *)payload string:(NSString *)string confidence:(VNConfidence)confidence;
@end

@interface VNHorizonObservation (VNAlgorithmInit)
- (instancetype)_initWithAngle:(CGFloat)angle imageWidth:(size_t)width imageHeight:(size_t)height revision:(NSUInteger)revision;
@end

@interface VNImageTranslationAlignmentObservation (VNAlgorithmInit)
- (instancetype)_initWithTransform:(CGAffineTransform)transform revision:(NSUInteger)revision confidence:(VNConfidence)confidence;
@end

@interface VNImageHomographicAlignmentObservation (VNAlgorithmInit)
- (instancetype)_initWithTransform:(matrix_float3x3)transform revision:(NSUInteger)revision confidence:(VNConfidence)confidence;
@end

@interface VNContoursObservation (VNAlgorithmInit)
- (instancetype)_initWithContours:(NSArray<VNContour *> *)contours revision:(NSUInteger)revision;
@end

static BOOL VNInsideFunctionPattern(int row, int column, int size)
{
    if ((row <= 8 && column <= 8) || (row <= 8 && column >= size - 9) ||
        (row >= size - 9 && column <= 8)) return YES;
    if (row == 6 || column == 6) return YES;
    return NO;
}

static int VNQRMaskBit(int mask, int row, int column)
{
    switch (mask) {
        case 0: return (row + column) % 2 == 0;
        case 1: return row % 2 == 0;
        case 2: return column % 3 == 0;
        case 3: return (row + column) % 3 == 0;
        case 4: return (row / 2 + column / 3) % 2 == 0;
        case 5: return (row * column) % 2 + (row * column) % 3 == 0;
        case 6: return ((row * column) % 2 + (row * column) % 3) % 2 == 0;
        case 7: return ((row + column) % 2 + (row * column) % 3) % 2 == 0;
        default: return 0;
    }
}

static unsigned VNQRFormatCode(unsigned value)
{
    unsigned remainder = value << 10;
    const unsigned polynomial = 0x537;
    for (int bit = 14; bit >= 10; bit--)
        if (remainder & (1U << bit)) remainder ^= polynomial << (bit - 10);
    return ((value << 10) | remainder) ^ 0x5412;
}

static unsigned VNReadQRFormat(const uint8_t matrix[177][177], int size)
{
    int first[15][2] = {{8,0},{8,1},{8,2},{8,3},{8,4},{8,5},{8,7},{8,8},{7,8},
                        {5,8},{4,8},{3,8},{2,8},{1,8},{0,8}};
    unsigned firstBits = 0, secondBits = 0;
    for (int i = 0; i < 15; i++)
        firstBits |= matrix[first[i][0]][first[i][1]] << i;
    int bit = 0;
    for (int column = size - 1; column >= size - 8; column--)
        secondBits |= matrix[8][column] << bit++;
    for (int row = size - 7; row < size; row++)
        secondBits |= matrix[row][8] << bit++;

    unsigned bestValue = 0, bestDistance = 16;
    unsigned copies[2] = { firstBits, secondBits };
    for (int copy = 0; copy < 2; copy++) {
        for (unsigned value = 0; value < 32; value++) {
            unsigned difference = VNQRFormatCode(value) ^ copies[copy], distance = 0;
            while (difference) { distance += difference & 1; difference >>= 1; }
            if (distance < bestDistance) { bestDistance = distance; bestValue = value; }
        }
    }
    return bestDistance <= 3 ? bestValue : UINT_MAX;
}

static NSData *VNDecodeSimpleQR(const VNGrayImage *image, VNComponent bounds)
{
    size_t width = bounds.maxX - bounds.minX + 1, height = bounds.maxY - bounds.minY + 1;
    if (width < 21 || height < 21 || width != height) return nil;
    uint8_t *firstRow = image->gray + bounds.minY * image->width + bounds.minX;
    size_t run = 0;
    while (run < width && firstRow[run] < 128) run++;
    if (run < 7 || run % 7) return nil;
    size_t module = run / 7;
    int size = (int)llround((double)width / module);
    if (size < 21 || size > 177 || (size - 21) % 4 || fabs((double)width / size - module) > 1.0)
        return nil;

    uint8_t matrix[177][177] = {{0}};
    for (int row = 0; row < size; row++) {
        for (int column = 0; column < size; column++) {
            size_t x = bounds.minX + (size_t)llround((column + 0.5) * width / size);
            size_t y = bounds.minY + (size_t)llround((row + 0.5) * height / size);
            if (x >= image->width || y >= image->height) return nil;
            matrix[row][column] = VNIsDark(image, x, y, 128);
        }
    }
    uint8_t rotated[177][177] = {{0}};
    for (int row = 0; row < size; row++) {
        for (int column = 0; column < size; column++)
            rotated[size - row - 1][column] = matrix[row][column];
    }
    memcpy(matrix, rotated, sizeof(matrix));
    unsigned format = VNReadQRFormat(matrix, size);
    if (format == UINT_MAX) return nil;
    int level = (format >> 3) & 3, mask = format & 7;
    int dataCodewords = size == 21 ? (level == 1 ? 19 : level == 0 ? 16 : level == 3 ? 13 : 9) : 0;
    if (!dataCodewords) return nil;

    uint8_t codewords[4096] = {0};
    size_t bitCount = 0;
    int direction = -1;
    for (int right = size - 1; right >= 1; right -= 2) {
        if (right == 6) right--;
        for (int step = 0; step < size; step++) {
            int row = direction < 0 ? size - 1 - step : step;
            for (int offset = 0; offset < 2; offset++) {
                int column = right - offset;
                if (VNInsideFunctionPattern(row, column, size)) continue;
                int bit = matrix[row][column] ^ VNQRMaskBit(mask, row, column);
                if (bit) codewords[bitCount / 8] |= (uint8_t)(1U << (7 - bitCount % 8));
                bitCount++;
            }
        }
        direction = -direction;
    }
    size_t bytes = MIN((size_t)dataCodewords, bitCount / 8);
    size_t cursor = 0;
#define VNQR_READ(count, output) do { \
    if (cursor + (count) > bytes * 8) return nil; \
    (output) = 0; \
    for (unsigned _i = 0; _i < (count); _i++, cursor++) \
        (output) = ((output) << 1) | ((codewords[cursor / 8] >> (7 - cursor % 8)) & 1); \
} while (0)
    unsigned mode = 0;
    VNQR_READ(4, mode);
    if (mode == 0) return [NSData data];
    unsigned count = 0;
    if (mode == 4) {
        VNQR_READ(8, count);
        if (cursor + (size_t)count * 8 > bytes * 8) return nil;
        NSMutableData *payload = [NSMutableData dataWithLength:count];
        uint8_t *out = payload.mutableBytes;
        for (unsigned i = 0; i < count; i++) VNQR_READ(8, out[i]);
        return payload;
    }
    if (mode == 1) {
        VNQR_READ(10, count);
        NSMutableString *text = [NSMutableString string];
        while (count >= 3) { unsigned v; VNQR_READ(10, v); if (v >= 1000) return nil; [text appendFormat:@"%03u", v]; count -= 3; }
        if (count == 2) { unsigned v; VNQR_READ(7, v); if (v >= 100) return nil; [text appendFormat:@"%02u", v]; }
        if (count == 1) { unsigned v; VNQR_READ(4, v); if (v >= 10) return nil; [text appendFormat:@"%u", v]; }
        return [text dataUsingEncoding:NSUTF8StringEncoding];
    }
    if (mode == 2) {
        static const char alphabet[] = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:";
        VNQR_READ(9, count);
        NSMutableString *text = [NSMutableString string];
        while (count >= 2) { unsigned v; VNQR_READ(11, v); if (v >= 45 * 45) return nil; [text appendFormat:@"%c%c", alphabet[v / 45], alphabet[v % 45]]; count -= 2; }
        if (count == 1) { unsigned v; VNQR_READ(6, v); if (v >= 45) return nil; [text appendFormat:@"%c", alphabet[v]]; }
        return [text dataUsingEncoding:NSUTF8StringEncoding];
    }
#undef VNQR_READ
    return nil;
}

@implementation VNDetectRectanglesRequest (FinchCPU)
- (BOOL)_performOnImage:(CGImageRef)image targetedImage:(CGImageRef)targetedImage error:(NSError **)error
{
    VNGrayImage gray;
    if (!VNGrayImageCreate(image, &gray)) { if (error) *error = VNMakeError(VNErrorInvalidImage, @"The image could not be read as pixels."); return NO; }
    VNComponent *components = NULL;
    size_t count = VNFindComponents(&gray, 128, &components);
    NSMutableArray *results = [NSMutableArray array];
    CGRect roi = self.regionOfInterest;
    for (size_t i = 0; i < count; i++) {
        VNComponent c = components[i];
        size_t width = c.maxX - c.minX + 1, height = c.maxY - c.minY + 1;
        size_t minimum = (size_t)(self.minimumSize * MIN(gray.width, gray.height));
        if (width < minimum || height < minimum || !VNComponentInROI(c, gray, roi)) continue;
        CGFloat aspect = (CGFloat)MIN(width, height) / MAX(width, height);
        if (aspect < self.minimumAspectRatio || aspect > self.maximumAspectRatio) continue;
        double edgePixels = 0.0;
        size_t thickness = MAX((size_t)1, MIN(width, height) / 40);
        for (size_t x = c.minX; x <= c.maxX; x++) {
            for (size_t t = 0; t < thickness; t++) {
                if (VNIsDark(&gray, x, MIN(c.minY + t, gray.height - 1), 180)) edgePixels++;
                if (VNIsDark(&gray, x, c.maxY >= t ? c.maxY - t : 0, 180)) edgePixels++;
            }
        }
        for (size_t y = c.minY; y <= c.maxY; y++) {
            for (size_t t = 0; t < thickness; t++) {
                if (VNIsDark(&gray, MIN(c.minX + t, gray.width - 1), y, 180)) edgePixels++;
                if (VNIsDark(&gray, c.maxX >= t ? c.maxX - t : 0, y, 180)) edgePixels++;
            }
        }
        double edgeLength = 2.0 * (width + height) * thickness;
        VNConfidence confidence = (VNConfidence)MIN(1.0, edgePixels / MAX(1.0, edgeLength));
        if (confidence < self.minimumConfidence || confidence < 0.30f) continue;
        CGPoint tl = VNNormalizedTopLeftPoint(c.minX, c.minY, gray.width, gray.height);
        CGPoint tr = VNNormalizedTopLeftPoint(c.maxX + 1, c.minY, gray.width, gray.height);
        CGPoint br = VNNormalizedTopLeftPoint(c.maxX + 1, c.maxY + 1, gray.width, gray.height);
        CGPoint bl = VNNormalizedTopLeftPoint(c.minX, c.maxY + 1, gray.width, gray.height);
        VNRectangleObservation *observation = [[[VNRectangleObservation alloc]
            _initWithRequestRevision:self.revision topLeft:tl topRight:tr bottomRight:br bottomLeft:bl confidence:confidence] autorelease];
        [results addObject:observation];
    }
    free(components);
    VNGrayImageFree(&gray);
    [self _setResults:results];
    if (error) *error = nil;
    return YES;
}
@end

@implementation VNDetectBarcodesRequest (FinchCPU)
- (BOOL)_performOnImage:(CGImageRef)image targetedImage:(CGImageRef)targetedImage error:(NSError **)error
{
    for (VNBarcodeSymbology symbology in self.symbologies) {
        if (![symbology isEqualToString:VNBarcodeSymbologyQR]) {
            if (error) *error = VNMakeError(VNErrorUnsupportedRequest, [NSString stringWithFormat:@"Finch can decode QR codes, not %@.", symbology]);
            return NO;
        }
    }
    VNGrayImage gray;
    if (!VNGrayImageCreate(image, &gray)) { if (error) *error = VNMakeError(VNErrorInvalidImage, @"The image could not be read as pixels."); return NO; }
    size_t minX = gray.width, minY = gray.height, maxX = 0, maxY = 0;
    size_t darkCount = 0;
    for (size_t y = 0; y < gray.height; y++) {
        for (size_t x = 0; x < gray.width; x++) {
            if (VNIsDark(&gray, x, y, 128)) {
                minX = MIN(minX, x); maxX = MAX(maxX, x);
                minY = MIN(minY, y); maxY = MAX(maxY, y); darkCount++;
            }
        }
    }
    NSMutableArray *results = [NSMutableArray array];
    if (darkCount && minX < maxX && minY < maxY) {
        VNComponent bounds = { .minX=minX, .minY=minY, .maxX=maxX, .maxY=maxY, .count=darkCount };
        CGRect normalized = VNNormalizedRectForImageRect(CGRectMake(minX, minY, maxX-minX+1, maxY-minY+1), gray.width, gray.height);
        if (CGRectIntersectsRect(normalized, self.regionOfInterest)) {
            NSData *payload = VNDecodeSimpleQR(&gray, bounds);
            NSString *text = payload ? [[[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding] autorelease] : nil;
            CGPoint tl = VNNormalizedTopLeftPoint(minX, minY, gray.width, gray.height);
            CGPoint tr = VNNormalizedTopLeftPoint(maxX + 1, minY, gray.width, gray.height);
            CGPoint br = VNNormalizedTopLeftPoint(maxX + 1, maxY + 1, gray.width, gray.height);
            CGPoint bl = VNNormalizedTopLeftPoint(minX, maxY + 1, gray.width, gray.height);
            VNBarcodeObservation *observation = [[[VNBarcodeObservation alloc]
                _initWithRequestRevision:self.revision topLeft:tl topRight:tr bottomRight:br bottomLeft:bl
                symbology:VNBarcodeSymbologyQR payload:payload string:text confidence:1.0f] autorelease];
            [results addObject:observation];
        }
    }
    VNGrayImageFree(&gray);
    [self _setResults:results];
    if (error) *error = nil;
    return YES;
}
@end

@implementation VNDetectContoursRequest (FinchCPU)
- (BOOL)_performOnImage:(CGImageRef)image targetedImage:(CGImageRef)targetedImage error:(NSError **)error
{
    VNGrayImage gray;
    if (!VNGrayImageCreate(image, &gray)) { if (error) *error = VNMakeError(VNErrorInvalidImage, @"The image could not be read as pixels."); return NO; }
    size_t largest = MAX(gray.width, gray.height);
    double scale = self.maximumImageDimension && largest > self.maximumImageDimension ?
        (double)self.maximumImageDimension / largest : 1.0;
    uint8_t *thresholded = malloc(gray.width * gray.height);
    if (!thresholded) { VNGrayImageFree(&gray); if (error) *error = VNMakeError(VNErrorOutOfMemory, @"Contour work space could not be allocated."); return NO; }
    double pivot = self.contrastPivot ? self.contrastPivot.doubleValue : 0.5;
    for (size_t i = 0; i < gray.width * gray.height; i++) {
        double value = gray.gray[i] / 255.0;
        value = (value - pivot) * self.contrastAdjustment + pivot;
        thresholded[i] = (uint8_t)(MIN(1.0, MAX(0.0, value)) * 255.0);
    }
    VNGrayImage source = gray;
    gray.gray = thresholded;
    VNComponent *components = NULL;
    size_t count = VNFindComponents(&gray, self.detectsDarkOnLight ? 128 : 128, &components);
    NSMutableArray *contours = [NSMutableArray array];
    for (size_t i = 0; i < count; i++) {
        VNComponent c = components[i];
        if (c.count < 8 || !VNComponentInROI(c, gray, self.regionOfInterest)) continue;
        size_t w = c.maxX - c.minX + 1, h = c.maxY - c.minY + 1;
        simd_float2 points[4] = {
            { (float)c.minX / gray.width, 1.0f - (float)c.minY / gray.height },
            { (float)(c.maxX + 1) / gray.width, 1.0f - (float)c.minY / gray.height },
            { (float)(c.maxX + 1) / gray.width, 1.0f - (float)(c.maxY + 1) / gray.height },
            { (float)c.minX / gray.width, 1.0f - (float)(c.maxY + 1) / gray.height }
        };
        if (scale < 1.0) {
            for (int j = 0; j < 4; j++) { points[j].x *= scale; points[j].y *= scale; }
        }
        NSIndexPath *path = [NSIndexPath indexPathWithIndex:contours.count];
        VNContour *contour = [[[VNContour alloc] _initWithPoints:points pointCount:4 indexPath:path
                                                      aspectRatio:(float)gray.width/gray.height revision:self.revision] autorelease];
        [contours addObject:contour];
        (void)w; (void)h;
    }
    free(components);
    free(thresholded);
    gray = source;
    VNGrayImageFree(&gray);
    VNContoursObservation *observation = [[[VNContoursObservation alloc] _initWithContours:contours revision:self.revision] autorelease];
    [self _setResults:@[ observation ]];
    if (error) *error = nil;
    return YES;
}
@end

@implementation VNDetectHorizonRequest (FinchCPU)
- (BOOL)_performOnImage:(CGImageRef)image targetedImage:(CGImageRef)targetedImage error:(NSError **)error
{
    VNGrayImage gray;
    if (!VNGrayImageCreate(image, &gray)) { if (error) *error = VNMakeError(VNErrorInvalidImage, @"The image could not be read as pixels."); return NO; }
    VNComponent *components = NULL;
    size_t count = VNFindComponents(&gray, 96, &components);
    VNComponent best = {0};
    double bestScore = 0.0;
    for (size_t i = 0; i < count; i++) {
        VNComponent c = components[i];
        size_t width = c.maxX - c.minX + 1, height = c.maxY - c.minY + 1;
        if (width < gray.width / 3 || width < height * 4 || !VNComponentInROI(c, gray, self.regionOfInterest)) continue;
        double score = (double)width / MAX((size_t)1, height) + c.count / (double)gray.width;
        if (score > bestScore) { best = c; bestScore = score; }
    }
    if (bestScore > 0.0) {
        size_t boundary = (best.minY + best.maxY + 1) / 2;
        double upper = 0.0, lower = 0.0;
        size_t upperCount = 0, lowerCount = 0;
        for (size_t y = 0; y < gray.height; y++) {
            for (size_t x = 0; x < gray.width; x++) {
                if (y < boundary) { upper += gray.gray[y * gray.width + x]; upperCount++; }
                else { lower += gray.gray[y * gray.width + x]; lowerCount++; }
            }
        }
        double upperMean = upperCount ? upper / upperCount : 0.0;
        double lowerMean = lowerCount ? lower / lowerCount : 0.0;
        if (fabs(upperMean - lowerMean) < 20.0) bestScore = 0.0;
    }
    free(components);
    NSMutableArray *results = [NSMutableArray array];
    if (bestScore > 0.0) {
        double n = best.count;
        double meanX = best.sumX / n, meanY = best.sumY / n;
        double covXX = best.sumXX / n - meanX * meanX;
        double covYY = best.sumYY / n - meanY * meanY;
        double covXY = best.sumXY / n - meanX * meanY;
        CGFloat angle = (CGFloat)-0.5 * atan2(2.0 * covXY, covXX - covYY);
        VNHorizonObservation *observation = [[[VNHorizonObservation alloc]
            _initWithAngle:angle imageWidth:gray.width imageHeight:gray.height revision:self.revision] autorelease];
        [results addObject:observation];
    }
    VNGrayImageFree(&gray);
    [self _setResults:results];
    if (error) *error = nil;
    return YES;
}
@end

static BOOL VNAlignImages(CGImageRef floating, CGImageRef reference, int *outX, int *outY, float *confidence)
{
    VNGrayImage a, b;
    if (!VNGrayImageCreate(floating, &a)) return NO;
    if (!VNGrayImageCreate(reference, &b)) { VNGrayImageFree(&a); return NO; }
    if (a.width != b.width || a.height != b.height || a.width < 8 || a.height < 8) {
        VNGrayImageFree(&a); VNGrayImageFree(&b); return NO;
    }
    int limitX = (int)MIN((size_t)64, a.width / 4), limitY = (int)MIN((size_t)64, a.height / 4);
    size_t step = MAX((size_t)1, MAX(a.width, a.height) / 160);
    double best = -DBL_MAX;
    int bestX = 0, bestY = 0;
    for (int dy = -limitY; dy <= limitY; dy++) {
        for (int dx = -limitX; dx <= limitX; dx++) {
            double sumA = 0.0, sumB = 0.0, sumAA = 0.0, sumBB = 0.0, sumAB = 0.0;
            size_t n = 0;
            size_t y0 = dy < 0 ? (size_t)-dy : 0;
            size_t y1 = dy > 0 ? a.height - (size_t)dy : a.height;
            size_t x0 = dx < 0 ? (size_t)-dx : 0;
            size_t x1 = dx > 0 ? a.width - (size_t)dx : a.width;
            for (size_t y = y0; y < y1; y += step) {
                for (size_t x = x0; x < x1; x += step) {
                    double av = a.gray[y * a.width + x];
                    double bv = b.gray[(size_t)((int)y + dy) * b.width + (size_t)((int)x + dx)];
                    sumA += av; sumB += bv; sumAA += av * av; sumBB += bv * bv; sumAB += av * bv; n++;
                }
            }
            if (n < 16) continue;
            double numerator = sumAB - sumA * sumB / n;
            double varianceA = sumAA - sumA * sumA / n;
            double varianceB = sumBB - sumB * sumB / n;
            double score = numerator / sqrt(MAX(1.0, varianceA * varianceB));
            if (score > best) { best = score; bestX = dx; bestY = dy; }
        }
    }
    VNGrayImageFree(&a); VNGrayImageFree(&b);
    if (best == -DBL_MAX) return NO;
    *outX = bestX; *outY = bestY;
    *confidence = (float)MAX(0.0, MIN(1.0, (best + 1.0) / 2.0));
    return YES;
}

@implementation VNTranslationalImageRegistrationRequest (FinchCPU)
- (BOOL)_performOnImage:(CGImageRef)image targetedImage:(CGImageRef)targetedImage error:(NSError **)error
{
    if (!targetedImage) { if (error) *error = VNMakeError(VNErrorMissingOption, @"Image registration needs a target image."); return NO; }
    int x = 0, y = 0; float confidence = 0.0f;
    if (!VNAlignImages(image, targetedImage, &x, &y, &confidence)) {
        if (error) *error = VNMakeError(VNErrorInvalidFormat, @"The source and target image sizes must match.");
        return NO;
    }
    CGAffineTransform transform = CGAffineTransformMakeTranslation(-x, y);
    VNImageTranslationAlignmentObservation *observation = [[[VNImageTranslationAlignmentObservation alloc]
        _initWithTransform:transform revision:self.revision confidence:confidence] autorelease];
    [self _setResults:@[ observation ]];
    if (error) *error = nil;
    return YES;
}
@end

@implementation VNHomographicImageRegistrationRequest (FinchCPU)
- (BOOL)_performOnImage:(CGImageRef)image targetedImage:(CGImageRef)targetedImage error:(NSError **)error
{
    if (!targetedImage) { if (error) *error = VNMakeError(VNErrorMissingOption, @"Image registration needs a target image."); return NO; }
    int x = 0, y = 0; float confidence = 0.0f;
    if (!VNAlignImages(image, targetedImage, &x, &y, &confidence)) {
        if (error) *error = VNMakeError(VNErrorInvalidFormat, @"The source and target image sizes must match.");
        return NO;
    }
    matrix_float3x3 matrix = matrix_identity_float3x3;
    matrix.columns[2].x = -x; matrix.columns[2].y = y;
    VNImageHomographicAlignmentObservation *observation = [[[VNImageHomographicAlignmentObservation alloc]
        _initWithTransform:matrix revision:self.revision confidence:confidence] autorelease];
    [self _setResults:@[ observation ]];
    if (error) *error = nil;
    return YES;
}
@end

@implementation VNTrackTranslationalImageRegistrationRequest (FinchCPU)
- (BOOL)_performOnImage:(CGImageRef)image targetedImage:(CGImageRef)targetedImage error:(NSError **)error
{
    if (!targetedImage) { [self _setResults:@[]]; if (error) *error = nil; return YES; }
    int x = 0, y = 0; float confidence = 0.0f;
    if (!VNAlignImages(image, targetedImage, &x, &y, &confidence)) {
        if (error) *error = VNMakeError(VNErrorInvalidFormat, @"The source and prior image sizes must match.");
        return NO;
    }
    VNImageTranslationAlignmentObservation *observation = [[[VNImageTranslationAlignmentObservation alloc]
        _initWithTransform:CGAffineTransformMakeTranslation(x, -y) revision:self.revision confidence:confidence] autorelease];
    [self _setResults:@[ observation ]];
    if (error) *error = nil;
    return YES;
}
@end

@implementation VNTrackHomographicImageRegistrationRequest (FinchCPU)
- (BOOL)_performOnImage:(CGImageRef)image targetedImage:(CGImageRef)targetedImage error:(NSError **)error
{
    if (!targetedImage) { [self _setResults:@[]]; if (error) *error = nil; return YES; }
    int x = 0, y = 0; float confidence = 0.0f;
    if (!VNAlignImages(image, targetedImage, &x, &y, &confidence)) {
        if (error) *error = VNMakeError(VNErrorInvalidFormat, @"The source and prior image sizes must match.");
        return NO;
    }
    matrix_float3x3 matrix = matrix_identity_float3x3;
    matrix.columns[2].x = x; matrix.columns[2].y = -y;
    VNImageHomographicAlignmentObservation *observation = [[[VNImageHomographicAlignmentObservation alloc]
        _initWithTransform:matrix revision:self.revision confidence:confidence] autorelease];
    [self _setResults:@[ observation ]];
    if (error) *error = nil;
    return YES;
}
@end
