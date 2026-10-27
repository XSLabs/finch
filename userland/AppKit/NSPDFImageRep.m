/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSPDFImageRep: an image from PDF data, one page at a time, drawn by Finch's
 * CoreGraphics (its own PDF reader). As Apple's (macOS 26.4, pdf-image-rep-test.m):
 *   - Data starting "%PDF" can make one; any non-nil data makes a rep (with no pages
 *     if CoreGraphics can't read it), and NSImage takes PDF data as this rep before
 *     a bitmap.
 *   - The bounds and size are the current page's crop box; pages out of range are
 *     ignored. It has no pixels, no alpha, 0 bits per sample, calibrated RGB.
 *   - The type is com.adobe.pdf (files: pdf, PDF, 'PDF '); archives keep the data
 *     under NSPDFData.
 */
#import <AppKit/AppKit.h>

@implementation NSPDFImageRep {
    NSData *_data;
    CGPDFDocumentRef _doc;
    NSInteger _page;
}

+ (BOOL)supportsSecureCoding { return YES; }

+ (NSArray<NSString *> *)imageUnfilteredTypes { return @[ @"com.adobe.pdf" ]; }
+ (NSArray<NSPasteboardType> *)imageUnfilteredPasteboardTypes { return @[ NSPDFPboardType ]; }
+ (NSArray<NSString *> *)imageUnfilteredFileTypes { return @[ @"pdf", @"PDF", @"'PDF '" ]; }

+ (BOOL)canInitWithData:(NSData *)data
{
    static const char magic[] = "%PDF";
    return [data length] >= 4 && memcmp([data bytes], magic, 4) == 0;
}

+ (instancetype)imageRepWithData:(NSData *)pdfData
{
    return [[[self alloc] initWithData:pdfData] autorelease];
}

+ (NSArray<NSImageRep *> *)imageRepsWithData:(NSData *)data
{
    NSPDFImageRep *r = [self imageRepWithData:data];
    return r ? @[ r ] : @[];
}

+ (id)imageRepWithContentsOfFile:(NSString *)filename
{
    NSData *d = [NSData dataWithContentsOfFile:filename];
    return d ? [self imageRepWithData:d] : nil;
}

- (instancetype)initWithData:(NSData *)pdfData
{
    if (!pdfData) {
        [self release];
        return nil;
    }
    if ((self = [super init])) {
        _data = [pdfData copy];
        CGDataProviderRef p = CGDataProviderCreateWithCFData((CFDataRef)_data);
        _doc = p ? CGPDFDocumentCreateWithProvider(p) : NULL;
        CGDataProviderRelease(p);
        [self _finchPageChanged];
    }
    return self;
}

- (void)dealloc
{
    CGPDFDocumentRelease(_doc);
    [_data release];
    [super dealloc];
}

- (CGPDFPageRef)_finchPage
{
    return _doc && [self pageCount] ? CGPDFDocumentGetPage(_doc, (size_t)_page + 1) : NULL;
}

- (void)_finchPageChanged
{
    [self setSize:[self bounds].size];
    [self setAlpha:NO];
    [self setOpaque:NO];
    [self setBitsPerSample:0];
    [self setPixelsWide:0];
    [self setPixelsHigh:0];
}

- (NSData *)PDFRepresentation { return _data; }
- (NSInteger)pageCount { return _doc ? (NSInteger)CGPDFDocumentGetNumberOfPages(_doc) : 0; }
- (NSInteger)currentPage { return _page; }

- (void)setCurrentPage:(NSInteger)page
{
    if (page < 0 || page >= [self pageCount])
        return;
    _page = page;
    [self _finchPageChanged];
}

- (NSRect)bounds
{
    CGPDFPageRef p = [self _finchPage];
    if (!p)
        return NSZeroRect;
    return NSRectFromCGRect(CGPDFPageGetBoxRect(p, kCGPDFCropBox));
}

- (BOOL)draw
{
    CGPDFPageRef p = [self _finchPage];
    NSGraphicsContext *g = [NSGraphicsContext currentContext];
    CGContextRef c = [g CGContext];
    if (!p || !c)
        return NO;
    CGRect box = CGPDFPageGetBoxRect(p, kCGPDFCropBox);
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, -box.origin.x, -box.origin.y);
    CGContextClipToRect(c, box);
    CGContextDrawPDFPage(c, p);
    CGContextRestoreGState(c);
    return YES;
}

- (id)copyWithZone:(NSZone *)zone
{
    NSPDFImageRep *r = [[[self class] allocWithZone:zone] initWithData:_data];
    [r setCurrentPage:_page];
    return r;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSData *d = [coder allowsKeyedCoding] ? [coder decodeObjectOfClass:[NSData class] forKey:@"NSPDFData"] : [coder decodeObject];
    return [self initWithData:d ?: [NSData data]];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    if ([coder allowsKeyedCoding])
        [coder encodeObject:_data forKey:@"NSPDFData"];
    else
        [coder encodeObject:_data];
}

@end
