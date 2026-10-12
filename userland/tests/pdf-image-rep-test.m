/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSPDFImageRep: a three-page PDF made by CoreGraphics, read as a rep (pages, bounds,
 * the current page, drawing each page's pixels), through NSImage from data and from a
 * file, bad data, copies and archives. Compared with Apple's.
 */
#import <AppKit/AppKit.h>
static NSData *make_pdf(void) {
    NSMutableData *d = [NSMutableData data];
    CGDataConsumerRef c = CGDataConsumerCreateWithCFData((__bridge CFMutableDataRef)d);
    CGRect box = CGRectMake(0, 0, 200, 100);
    CGContextRef ctx = CGPDFContextCreate(c, &box, NULL);
    for (int i = 0; i < 3; i++) {
        CGRect mb = CGRectMake(0, 0, 200 + i * 50, 100 + i * 20);
        NSDictionary *pi = @{(id)kCGPDFContextMediaBox : [NSData dataWithBytes:&mb length:sizeof mb]};
        CGPDFContextBeginPage(ctx, (__bridge CFDictionaryRef)pi);
        CGContextSetRGBFillColor(ctx, i == 0, i == 1, i == 2, 1);
        CGContextFillRect(ctx, CGRectMake(0, 0, 100, 50));
        CGPDFContextEndPage(ctx);
    }
    CGPDFContextClose(ctx); CGContextRelease(ctx); CGDataConsumerRelease(c);
    return d;
}
static NSString *px(NSImageRep *r, NSSize sz, NSPoint at) {
    NSBitmapImageRep *b = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:sz.width pixelsHigh:sz.height bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:b]];
    [r drawInRect:NSMakeRect(0, 0, sz.width, sz.height)];
    [NSGraphicsContext restoreGraphicsState];
    NSUInteger p[4]; [b getPixel:p atX:at.x y:at.y];
    return [NSString stringWithFormat:@"%lu,%lu,%lu,%lu", p[0], p[1], p[2], p[3]];
}
int main(void) { @autoreleasepool {
    NSData *pdf = make_pdf();
    printf("registered: pdf %d\n", [[NSImageRep registeredImageRepClasses] containsObject:[NSPDFImageRep class]]);
    printf("types: %s\n", [[NSPDFImageRep imageUnfilteredTypes] componentsJoinedByString:@" "].UTF8String);
    printf("file types: %s\n", [[NSPDFImageRep imageUnfilteredFileTypes] componentsJoinedByString:@" "].UTF8String);
    printf("can init: %d, class for data %s\n", [NSPDFImageRep canInitWithData:pdf], NSStringFromClass([NSImageRep imageRepClassForData:pdf]).UTF8String);
    NSPDFImageRep *r = [NSPDFImageRep imageRepWithData:pdf];
    printf("rep: pages %ld current %ld bounds %s size %s pixels %ldx%ld alpha %d opaque %d bps %ld colorspace %s\n", (long)r.pageCount, (long)r.currentPage, NSStringFromRect(r.bounds).UTF8String, NSStringFromSize(r.size).UTF8String, (long)r.pixelsWide, (long)r.pixelsHigh, r.hasAlpha, r.isOpaque, (long)r.bitsPerSample, r.colorSpaceName.UTF8String);
    printf("same data %d\n", [r.PDFRepresentation isEqualToData:pdf]);
    r.currentPage = 2;
    printf("page 2: bounds %s size %s\n", NSStringFromRect(r.bounds).UTF8String, NSStringFromSize(r.size).UTF8String);
    printf("  pixel at 10,10 of 300x140: %s; at 200,10 %s\n", px(r, NSMakeSize(300, 140), NSMakePoint(10, 130)).UTF8String, px(r, NSMakeSize(300, 140), NSMakePoint(200, 130)).UTF8String);
    r.currentPage = 0;
    printf("page 0 pixel: %s\n", px(r, NSMakeSize(200, 100), NSMakePoint(10, 90)).UTF8String);
    @try { r.currentPage = 9; printf("page 9: current %ld\n", (long)r.currentPage); } @catch (NSException *e) { printf("page 9: %s\n", e.name.UTF8String); }
    NSImage *im = [[NSImage alloc] initWithData:pdf];
    printf("image: size %s reps %lu %s\n", NSStringFromSize(im.size).UTF8String, (unsigned long)im.representations.count, NSStringFromClass([im.representations.firstObject class]).UTF8String);
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"rep-test.pdf"];
    [pdf writeToFile:path atomically:YES];
    NSArray *reps = [NSImageRep imageRepsWithContentsOfFile:path];
    printf("imageRepsWithContentsOfFile: %lu %s\n", (unsigned long)reps.count, NSStringFromClass([reps.firstObject class]).UTF8String);
    NSImage *f = [[NSImage alloc] initWithContentsOfFile:path];
    printf("file image: size %s rep %s\n", NSStringFromSize(f.size).UTF8String, NSStringFromClass([f.representations.firstObject class]).UTF8String);
    NSPDFImageRep *bad = [NSPDFImageRep imageRepWithData:[@"hello" dataUsingEncoding:NSUTF8StringEncoding]];
    printf("bad data: rep %d pages %ld size %s, can init %d, %%PDF junk can %d, image %d\n", bad != nil, (long)bad.pageCount, NSStringFromSize(bad.size).UTF8String,
        [NSPDFImageRep canInitWithData:[@"hello" dataUsingEncoding:NSUTF8StringEncoding]], [NSPDFImageRep canInitWithData:[@"%PDF-1.4 junk" dataUsingEncoding:NSUTF8StringEncoding]],
        [[NSImage alloc] initWithData:[@"hello" dataUsingEncoding:NSUTF8StringEncoding]] != nil);
    NSPDFImageRep *c = [r copy]; printf("copy: pages %ld current %ld same %d\n", (long)c.pageCount, (long)c.currentPage, c == r);
    NSData *arch = [NSKeyedArchiver archivedDataWithRootObject:r requiringSecureCoding:NO error:nil];
    NSPDFImageRep *u = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSPDFImageRep class] fromData:arch error:nil];
    printf("archived: %s pages %ld\n", NSStringFromClass(u.class).UTF8String, (long)u.pageCount);
    unlink(path.fileSystemRepresentation);
}}
