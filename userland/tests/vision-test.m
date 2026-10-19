// SPDX-License-Identifier: MIT OR Apache-2.0
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>
#import <Foundation/Foundation.h>
#import <Vision/Vision.h>
#import <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void printImagePath(void)
{
    Dl_info info = {0};
    if (dladdr((const void *)[VNImageRequestHandler class], &info) && info.dli_fname)
        puts(info.dli_fname);
    else
        puts("(Vision image unavailable)");
}

static CGFloat rounded(CGFloat value)
{
    return fabs(value) < 0.0005 ? 0.0 : round(value * 1000.0) / 1000.0;
}

static void releasePixelBytes(void *info, const void *data, size_t size)
{
    (void)info;
    (void)size;
    free((void *)data);
}

static CGImageRef makeGrayImage(size_t width, size_t height, const uint8_t *pixels)
{
    uint8_t *copy = malloc(width * height);
    if (!copy) return NULL;
    memcpy(copy, pixels, width * height);
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, copy, width * height, releasePixelBytes);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceGray();
    CGImageRef image = CGImageCreate(width, height, 8, 8, width, space,
                                     (CGBitmapInfo)kCGImageAlphaNone, provider, NULL, false,
                                     kCGRenderingIntentDefault);
    CGColorSpaceRelease(space);
    CGDataProviderRelease(provider);
    return image;
}

static CGImageRef makeRectangleImage(void)
{
    const size_t width = 160, height = 120;
    uint8_t *pixels = malloc(width * height);
    memset(pixels, 245, width * height);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceGray();
    CGContextRef context = CGBitmapContextCreate(pixels, width, height, 8, width, space,
                                                (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(space);
    if (!context) { free(pixels); return NULL; }
    CGContextSetGrayStrokeColor(context, 0.0, 1.0);
    CGContextSetLineWidth(context, 3.0);
    CGContextStrokeRect(context, CGRectMake(34, 28, 92, 64));
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    free(pixels);
    return image;
}

static CGImageRef makeBlankImage(void)
{
    const size_t width = 160, height = 120;
    uint8_t *pixels = malloc(width * height);
    if (!pixels) return NULL;
    memset(pixels, 255, width * height);
    CGImageRef image = makeGrayImage(width, height, pixels);
    free(pixels);
    return image;
}

static CGImageRef makeHorizonImage(void)
{
    const size_t width = 160, height = 120;
    uint8_t *pixels = malloc(width * height);
    memset(pixels, 245, width * height);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceGray();
    CGContextRef context = CGBitmapContextCreate(pixels, width, height, 8, width, space,
                                                (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(space);
    if (!context) { free(pixels); return NULL; }
    CGContextSetGrayStrokeColor(context, 0.0, 1.0);
    CGContextSetLineWidth(context, 3.0);
    CGContextMoveToPoint(context, 18, 45);
    CGContextAddLineToPoint(context, 142, 72);
    CGContextStrokePath(context);
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    free(pixels);
    return image;
}

static void makeShiftedPair(CGImageRef *sourceOut, CGImageRef *shiftedOut)
{
    const size_t width = 128, height = 96;
    const int dx = 6, dy = 4;
    uint8_t *source = malloc(width * height);
    uint8_t *shifted = malloc(width * height);
    memset(shifted, 255, width * height);
    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            uint32_t v = (uint32_t)(x * 73 + y * 41 + x * y * 13) ^ (uint32_t)(x * 17 + y * 97);
            source[y * width + x] = (uint8_t)(v & 0xff);
        }
    }
    for (size_t y = 0; y + dy < height; y++)
        for (size_t x = 0; x + dx < width; x++)
            shifted[(y + dy) * width + x + dx] = source[y * width + x];
    *sourceOut = makeGrayImage(width, height, source);
    *shiftedOut = makeGrayImage(width, height, shifted);
    free(source);
    free(shifted);
}

static CGImageRef makeQRCodeImage(void)
{
    // Core Image on Finch lacks CIQRCodeGenerator, so use the same fixed test pattern there.
    static const char *const rows[] = {
        ".......................",
        ".#######....#..#######.",
        ".#.....#.#...#.#.....#.",
        ".#.###.#....##.#.###.#.",
        ".#.###.#..##...#.###.#.",
        ".#.###.#.##.##.#.###.#.",
        ".#.....#..#.#..#.....#.",
        ".#######.#.#.#.#######.",
        "..........##...........",
        ".#.#.#.#..##.#...#..#..",
        ".#.#.#..#...#.#.#.##...",
        ".#..#..#.#..#.###..###.",
        "...####..##.###.###..#.",
        ".#####.#..#.#.###......",
        ".........#.#...#...###.",
        ".#######...#.#...#.....",
        ".#.....#..#....#..####.",
        ".#.###.#.#.#.#.#.#.#.#.",
        ".#.###.#..#.#.#.#.###..",
        ".#.###.#.##.#.###..#.#.",
        ".#.....#....###.###.##.",
        ".#######.#..#.###..#.#.",
        "......................."
    };
    if (![CIFilter filterWithName:@"CIQRCodeGenerator"]) {
        const size_t width = 160, height = 160, moduleSize = 5, originX = 27, originY = 18;
        uint8_t *pixels = malloc(width * height);
        if (!pixels) return NULL;
        memset(pixels, 255, width * height);
        for (size_t row = 0; row < sizeof(rows) / sizeof(rows[0]); row++) {
            for (size_t column = 0; column < 23; column++) {
                if (rows[row][column] != '#') continue;
                for (size_t y = 0; y < moduleSize; y++)
                    memset(pixels + (originY + (22 - row) * moduleSize + y) * width + originX + column * moduleSize,
                           0, moduleSize);
            }
        }
        CGImageRef image = makeGrayImage(width, height, pixels);
        free(pixels);
        return image;
    }
    CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [filter setValue:[NSData dataWithBytes:"FINCH" length:5] forKey:@"inputMessage"];
    [filter setValue:@"M" forKey:@"inputCorrectionLevel"];
    CIImage *code = [filter valueForKey:@"outputImage"];
    if (!code) return NULL;
    code = [code imageByApplyingTransform:CGAffineTransformMakeScale(5.0, 5.0)];
    code = [code imageByApplyingTransform:CGAffineTransformMakeTranslation(27.5, 27.5)];
    CGRect extent = CGRectMake(0, 0, 160, 160);
    CIImage *white = [[CIImage imageWithColor:[CIColor colorWithRed:1 green:1 blue:1 alpha:1]]
                      imageByCroppingToRect:extent];
    CIImage *image = [code imageByCompositingOverImage:white];
    CIContext *context = [CIContext context];
    return [context createCGImage:image fromRect:extent];
}

static void printRectangleResults(CGImageRef image)
{
    VNDetectRectanglesRequest *request = [[VNDetectRectanglesRequest alloc] init];
    request.usesCPUOnly = YES;
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    NSError *error = nil;
    BOOL ok = [handler performRequests:@[ request ] error:&error];
    printf("rectangles.ok=%d error=%ld count=%lu\n", ok, (long)error.code, (unsigned long)request.results.count);
    for (VNRectangleObservation *value in request.results) {
        CGRect box = value.boundingBox;
        printf("rectangles.box=%.3f,%.3f,%.3f,%.3f corners=%.3f,%.3f;%.3f,%.3f;%.3f,%.3f;%.3f,%.3f confidence=%.3f\n",
               rounded(box.origin.x), rounded(box.origin.y), rounded(box.size.width), rounded(box.size.height),
               rounded(value.topLeft.x), rounded(value.topLeft.y), rounded(value.topRight.x), rounded(value.topRight.y),
               rounded(value.bottomRight.x), rounded(value.bottomRight.y), rounded(value.bottomLeft.x), rounded(value.bottomLeft.y),
               rounded(value.confidence));
    }
    [handler release];
    [request release];
}

static void printBarcodeResults(CGImageRef image)
{
    VNDetectBarcodesRequest *request = [[VNDetectBarcodesRequest alloc] init];
    request.usesCPUOnly = YES;
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    NSError *error = nil;
    BOOL ok = [handler performRequests:@[ request ] error:&error];
    printf("barcode.ok=%d error=%ld count=%lu\n", ok, (long)error.code, (unsigned long)request.results.count);
    for (VNBarcodeObservation *value in request.results)
        printf("barcode.value=%s symbology=%s confidence=%.3f box=%.3f,%.3f,%.3f,%.3f\n",
               value.payloadStringValue.UTF8String ?: "(nil)", value.symbology.UTF8String ?: "(nil)",
               rounded(value.confidence), rounded(value.boundingBox.origin.x), rounded(value.boundingBox.origin.y),
               rounded(value.boundingBox.size.width), rounded(value.boundingBox.size.height));
    [handler release];
    [request release];
}

static void printContourResults(CGImageRef image)
{
    VNDetectContoursRequest *request = [[VNDetectContoursRequest alloc] init];
    request.usesCPUOnly = YES;
    request.maximumImageDimension = 512;
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    NSError *error = nil;
    BOOL ok = [handler performRequests:@[ request ] error:&error];
    VNContoursObservation *observation = request.results.firstObject;
    printf("contours.ok=%d error=%ld observations=%lu top=%ld total=%ld\n", ok, (long)error.code,
           (unsigned long)request.results.count, (long)observation.topLevelContourCount,
           (long)observation.contourCount);
    if (observation.topLevelContourCount) {
        VNContour *contour = [observation topLevelContours].firstObject;
        printf("contours.first=points:%ld aspect:%.3f path:%s\n", (long)contour.pointCount,
               rounded(contour.aspectRatio), CGPathIsEmpty(contour.normalizedPath) ? "empty" : "present");
    }
    [handler release];
    [request release];
}

static void printHorizonResults(CGImageRef image)
{
    VNDetectHorizonRequest *request = [[VNDetectHorizonRequest alloc] init];
    request.usesCPUOnly = YES;
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    NSError *error = nil;
    BOOL ok = [handler performRequests:@[ request ] error:&error];
    printf("horizon.ok=%d error=%ld count=%lu\n", ok, (long)error.code, (unsigned long)request.results.count);
    for (VNHorizonObservation *value in request.results)
        printf("horizon.angle=%.3f transform=%.3f,%.3f,%.3f,%.3f\n", rounded(value.angle),
               rounded(value.transform.a), rounded(value.transform.b), rounded(value.transform.c), rounded(value.transform.d));
    [handler release];
    [request release];
}

static void printAlignmentResults(CGImageRef source, CGImageRef shifted)
{
    VNTranslationalImageRegistrationRequest *request = [[VNTranslationalImageRegistrationRequest alloc]
        initWithTargetedCGImage:shifted options:@{}];
    request.usesCPUOnly = YES;
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:source options:@{}];
    NSError *error = nil;
    BOOL ok = [handler performRequests:@[ request ] error:&error];
    printf("alignment.ok=%d error=%ld count=%lu\n", ok, (long)error.code, (unsigned long)request.results.count);
    for (VNImageTranslationAlignmentObservation *value in request.results) {
        CGAffineTransform t = value.alignmentTransform;
        printf("alignment.transform=%.3f,%.3f,%.3f,%.3f,%.3f,%.3f confidence=%.3f\n",
               rounded(t.a), rounded(t.b), rounded(t.c), rounded(t.d), rounded(t.tx), rounded(t.ty),
               rounded(value.confidence));
    }
    [handler release];
    [request release];
}

static void printSequenceResults(CGImageRef source, CGImageRef shifted)
{
    VNSequenceRequestHandler *handler = [[VNSequenceRequestHandler alloc] init];
    VNTrackTranslationalImageRegistrationRequest *request = [[VNTrackTranslationalImageRegistrationRequest alloc] init];
    request.usesCPUOnly = YES;
    NSError *error = nil;
    BOOL first = [handler performRequests:@[ request ] onCGImage:source error:&error];
    printf("sequence.first=%d error=%ld count=%lu\n", first, (long)error.code, (unsigned long)request.results.count);
    error = nil;
    BOOL second = [handler performRequests:@[ request ] onCGImage:shifted error:&error];
    printf("sequence.second=%d error=%ld count=%lu\n", second, (long)error.code, (unsigned long)request.results.count);
    for (VNImageTranslationAlignmentObservation *value in request.results) {
        CGAffineTransform t = value.alignmentTransform;
        printf("sequence.transform=%.3f,%.3f,%.3f,%.3f,%.3f,%.3f confidence=%.3f\n",
               rounded(t.a), rounded(t.b), rounded(t.c), rounded(t.d), rounded(t.tx), rounded(t.ty),
               rounded(value.confidence));
    }
    [handler release];
    [request release];
}

int main(void)
{
    @autoreleasepool {
        printImagePath();
        printf("revision.barcode=%lu face=%lu horizon=%lu contours=%lu\n",
               (unsigned long)[VNDetectBarcodesRequest currentRevision],
               (unsigned long)[VNDetectFaceRectanglesRequest currentRevision],
               (unsigned long)[VNDetectHorizonRequest currentRevision],
               (unsigned long)[VNDetectContoursRequest currentRevision]);
        VNPoint *point = [[VNPoint alloc] initWithX:0.25 y:0.75];
        VNVector *vector = [[VNVector alloc] initWithR:2.0 theta:0.0];
        VNCircle *circle = [[VNCircle alloc] initWithCenter:point radius:2.0];
        printf("geometry.distance=%.3f vector=%.3f,%.3f circle=%.3f\n",
               rounded([point distanceToPoint:[VNPoint zeroPoint]]), rounded(vector.x), rounded(vector.y),
               rounded(circle.diameter));
        [circle release]; [vector release]; [point release];

        CGImageRef rectangle = makeRectangleImage();
        CGImageRef blank = makeBlankImage();
        CGImageRef horizon = makeHorizonImage();
        CGImageRef qr = makeQRCodeImage();
        CGImageRef source = NULL, shifted = NULL;
        makeShiftedPair(&source, &shifted);
        printRectangleResults(rectangle);
        printBarcodeResults(qr);
        printContourResults(blank);
        printHorizonResults(horizon);
        printAlignmentResults(source, shifted);
        printSequenceResults(source, shifted);
        VNDetectBarcodesRequest *invalidRevision = [[VNDetectBarcodesRequest alloc] init];
        invalidRevision.revision = 999;
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:rectangle options:@{}];
        NSError *error = nil;
        BOOL ok = [handler performRequests:@[ invalidRevision ] error:&error];
        printf("barcode.invalidRevision=%d code=%ld domain=%s\n", ok, (long)error.code,
               error.domain.UTF8String ?: "(null)");
        [handler release]; [invalidRevision release];
        CGImageRelease(rectangle); CGImageRelease(blank); CGImageRelease(horizon); CGImageRelease(qr);
        CGImageRelease(source); CGImageRelease(shifted);
    }
    return 0;
}
