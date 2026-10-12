/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * QuickLook: thumbnails of files, Finch's own (Apple's makes them with generator
 * plug-ins; Finch's draws the common kinds itself). An image is scaled down through
 * ImageIO; a PDF shows its first page; plain text and source code show their first lines
 * on a page; anything else (or with the icon mode option) shows its icon from
 * IconServices. FinchQuickLookThumbnail is shared with QuickLookThumbnailing and
 * QuickLookUI.
 */
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/message.h>
#include <dlfcn.h>

#define QL_EXPORT __attribute__((visibility("default")))

QL_EXPORT const CFStringRef kQLThumbnailOptionIconModeKey = CFSTR("IconMode");
QL_EXPORT const CFStringRef kQLThumbnailOptionScaleFactorKey = CFSTR("QLThumbnailOptionScaleFactor");
QL_EXPORT const CFStringRef kQLThumbnailOptionContentTypeUTI = CFSTR("ContentTypeUTI");
QL_EXPORT NSString *const QLSeamlessOpeningDisplayStateContentsEDRStrengthKey = @"DisplayStateContentsEDRStrength";
QL_EXPORT NSString *const QLSeamlessOpeningDisplayStatePageKey = @"DisplayStatePage";
QL_EXPORT NSString *const QLSeamlessOpeningDisplayStatePasswordKey = @"DisplayStatePassword";
QL_EXPORT NSString *const QLSeamlessOpeningDisplayStateScreenFrameKey = @"DisplayStateScreenFrame";
QL_EXPORT NSString *const QLSeamlessOpeningDisplayStateTimeKey = @"DisplayStateTime";

static CGContextRef
bitmap(size_t w, size_t h)
{
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(NULL, w, h, 8, 0, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(cs);
    return c;
}

static CGImageRef
image_thumbnail(NSURL *url, size_t maxPixels)
{
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src)
        return NULL;
    NSDictionary *o = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize : @(maxPixels),
        (id)kCGImageSourceCreateThumbnailWithTransform : @YES,
    };
    CGImageRef im = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)o);
    CFRelease(src);
    return im;
}

/* A page: white, with a hairline edge; the content drawn into its inset by `draw`. */
static CGImageRef
page(CGSize pixels, void (^draw)(CGContextRef c, CGRect content))
{
    CGContextRef c = bitmap((size_t)pixels.width, (size_t)pixels.height);
    if (!c)
        return NULL;
    CGRect r = CGRectMake(0, 0, pixels.width, pixels.height);
    CGContextSetRGBFillColor(c, 1, 1, 1, 1);
    CGContextFillRect(c, r);
    CGContextSetRGBStrokeColor(c, 0.75, 0.76, 0.78, 1);
    CGContextSetLineWidth(c, MAX(1, pixels.width / 256));
    CGContextStrokeRect(c, CGRectInset(r, 0.5, 0.5));
    draw(c, CGRectInset(r, pixels.width * 0.07, pixels.height * 0.06));
    CGImageRef im = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    return im;
}

static CGImageRef
pdf_thumbnail(NSURL *url, size_t maxPixels)
{
    CGPDFDocumentRef doc = CGPDFDocumentCreateWithURL((__bridge CFURLRef)url);
    CGPDFPageRef p = doc ? CGPDFDocumentGetPage(doc, 1) : NULL;
    if (!p) {
        CGPDFDocumentRelease(doc);
        return NULL;
    }
    CGRect box = CGPDFPageGetBoxRect(p, kCGPDFCropBox);
    double s = (double)maxPixels / MAX(box.size.width, box.size.height);
    CGSize px = CGSizeMake(MAX(1, round(box.size.width * s)), MAX(1, round(box.size.height * s)));
    CGImageRef im = page(px, ^(CGContextRef c, CGRect content) {
        CGContextSaveGState(c);
        CGContextConcatCTM(c, CGPDFPageGetDrawingTransform(p, kCGPDFCropBox, CGRectMake(0, 0, px.width, px.height), 0, true));
        CGContextDrawPDFPage(c, p);
        CGContextRestoreGState(c);
    });
    CGPDFDocumentRelease(doc);
    return im;
}

/* The first lines of a text file, on a page in proportion to a letter sheet. */
static CGImageRef
text_thumbnail(NSURL *url, size_t maxPixels)
{
    NSData *d = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:NULL];
    if (!d)
        return NULL;
    NSString *s = [[NSString alloc] initWithData:[d subdataWithRange:NSMakeRange(0, MIN(d.length, (NSUInteger)4096))]
                                        encoding:NSUTF8StringEncoding];
    if (!s)
        s = [[NSString alloc] initWithData:[d subdataWithRange:NSMakeRange(0, MIN(d.length, (NSUInteger)4096))]
                                  encoding:NSISOLatin1StringEncoding];
    if (!s)
        return NULL;
    CGSize px = CGSizeMake(round(maxPixels * 0.77), maxPixels);
    return page(px, ^(CGContextRef c, CGRect content) {
        CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontUserFixedPitch, MAX(4, px.height / 40), NULL);
        CGColorRef ink = CGColorCreateSRGB(0.15, 0.15, 0.15, 1);
        NSDictionary *a = @{(id)kCTFontAttributeName : (__bridge id)font, (id)kCTForegroundColorAttributeName : (__bridge id)ink};
        NSAttributedString *as = [[NSAttributedString alloc] initWithString:s attributes:a];
        CTFramesetterRef fs = CTFramesetterCreateWithAttributedString((__bridge CFAttributedStringRef)as);
        CGPathRef path = CGPathCreateWithRect(content, NULL);
        CTFrameRef frame = CTFramesetterCreateFrame(fs, CFRangeMake(0, 0), path, NULL);
        CTFrameDraw(frame, c);
        CFRelease(frame);
        CGPathRelease(path);
        CFRelease(fs);
        CGColorRelease(ink);
        if (font)
            CFRelease(font);
    });
}

/* The file's icon from IconServices, at the pixel size. */
static CGImageRef
icon_thumbnail(NSURL *url, size_t maxPixels)
{
    static Class iconClass, descClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/IconServices.framework/IconServices", RTLD_LAZY);
        iconClass = NSClassFromString(@"ISIcon");
        descClass = NSClassFromString(@"ISImageDescriptor");
    });
    if (!iconClass || !descClass)
        return NULL;
    id icon = ((id(*)(id, SEL, id))objc_msgSend)([iconClass alloc], sel_registerName("initWithURL:"), url);
    id d = ((id(*)(id, SEL, CGSize, double))objc_msgSend)([descClass alloc], sel_registerName("initWithSize:scale:"),
                                                          CGSizeMake(maxPixels, maxPixels), 1);
    CGImageRef im = ((CGImageRef(*)(id, SEL, id))objc_msgSend)(icon, sel_registerName("CGImageForDescriptor:"), d);
    return im ? CGImageRetain(im) : NULL;
}

/* The thumbnail of a file, no larger than maxPixels on its longer side (+1). iconMode:
   the icon, whatever the file is. */
/* (SPI for QuickLookThumbnailing and QuickLookUI) */
QL_EXPORT CGImageRef
FinchQuickLookThumbnail(NSURL *url, size_t maxPixels, BOOL iconMode, BOOL *isIcon)
{
    if (isIcon)
        *isIcon = NO;
    if (!url || maxPixels < 1)
        return NULL;
    if (!iconMode) {
        UTType *t = nil;
        [url getResourceValue:&t forKey:NSURLContentTypeKey error:NULL];
        if (!t)
            t = [UTType typeWithFilenameExtension:url.pathExtension];
        CGImageRef im = NULL;
        if ([t conformsToType:UTTypePDF])
            im = pdf_thumbnail(url, maxPixels);
        else if ([t conformsToType:UTTypeImage])
            im = image_thumbnail(url, maxPixels);
        else if ([t conformsToType:UTTypePlainText] || [t conformsToType:UTTypeSourceCode] || [t conformsToType:UTTypeJSON] ||
                 [t conformsToType:UTTypeXML])
            im = text_thumbnail(url, maxPixels);
        if (im)
            return im;
    }
    if (isIcon)
        *isIcon = YES;
    return icon_thumbnail(url, maxPixels);
}

/* The C call: maxSize in points, scaled by the options' scale factor. */
QL_EXPORT CGImageRef
QLThumbnailImageCreate(CFAllocatorRef allocator, CFURLRef url, CGSize maxSize, CFDictionaryRef options)
{
    NSDictionary *o = (__bridge NSDictionary *)options;
    double scale = [o[(__bridge NSString *)kQLThumbnailOptionScaleFactorKey] doubleValue];
    if (scale <= 0)
        scale = 1;
    BOOL iconMode = [o[(__bridge NSString *)kQLThumbnailOptionIconModeKey] boolValue];
    size_t px = (size_t)lround(MAX(maxSize.width, maxSize.height) * scale);
    return FinchQuickLookThumbnail((__bridge NSURL *)url, px, iconMode, NULL);
}
