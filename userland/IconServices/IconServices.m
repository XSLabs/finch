/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * IconServices (private): icons for apps, files and types, as images of a requested
 * size. Finch's own, under Apple's API: an ISIcon is made for a bundle (by identifier
 * or URL), a file, a type, a file extension or MIME type, or ready-made images, and
 * gives an ISImage (a CGImage at a scale) for an ISImageDescriptor (a size, a scale and
 * a shape; Apple's named ones keep their sizes), made at the next of the Mac's icon sizes
 * as Apple's are.
 *
 * Where icons come from: an app's own icon file (CFBundleIconFile, an .icns read by
 * ImageIO) or its asset catalog's icon (CFBundleIconName, through CoreUI); anything else
 * gets Finch's generic icons (application, document, folder, volume), drawn here in the
 * same art as AppKit's (NSWorkspace.m). Images are made at the descriptor's pixel size
 * from the nearest larger representation and kept per icon.
 */
#import <CoreGraphics/CoreGraphics.h>
#import <CoreServices/CoreServices.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <dlfcn.h>
#import <objc/message.h>

#define IS_EXPORT __attribute__((visibility("default")))

#pragma mark - Descriptor names

IS_EXPORT NSString *const kISImageDescriptorActivity = @"com.apple.IconServices.ImageDescriptor.Activity";
IS_EXPORT NSString *const kISImageDescriptorBadgedDocumentScalableSize = @"com.apple.IconServices.ImageDescriptor.BadgedDocumentScalableSize";
IS_EXPORT NSString *const kISImageDescriptorBadgedDocumentSize = @"com.apple.IconServices.ImageDescriptor.BadgedDocumentSize";
IS_EXPORT NSString *const kISImageDescriptorCarLauncher = @"com.apple.IconServices.ImageDescriptor.CarLauncher";
IS_EXPORT NSString *const kISImageDescriptorCarNotification = @"com.apple.IconServices.ImageDescriptor.CarNotification";
IS_EXPORT NSString *const kISImageDescriptorCustomDocumentCompact = @"com.apple.IconServices.ImageDescriptor.CustomDocumentCompact";
IS_EXPORT NSString *const kISImageDescriptorCustomDocumentRegular = @"com.apple.IconServices.ImageDescriptor.CustomDocumentRegular";
IS_EXPORT NSString *const kISImageDescriptorCustomDocumentScalableSize = @"com.apple.IconServices.ImageDescriptor.CustomDocumentScalableSize";
IS_EXPORT NSString *const kISImageDescriptorCustomDocumentSize = @"com.apple.IconServices.ImageDescriptor.CustomDocumentSize";
IS_EXPORT NSString *const kISImageDescriptorCustomDocumentTable = @"com.apple.IconServices.ImageDescriptor.CustomDocumentTable";
IS_EXPORT NSString *const kISImageDescriptorHomeScreen = @"com.apple.IconServices.ImageDescriptor.HomeScreen";
IS_EXPORT NSString *const kISImageDescriptorLargeHomeScreen = @"com.apple.IconServices.ImageDescriptor.LargeHomeScreen";
IS_EXPORT NSString *const kISImageDescriptorMessagesExtensionBadge = @"com.apple.IconServices.ImageDescriptor.MessagesExtensionBadge";
IS_EXPORT NSString *const kISImageDescriptorMessagesExtensionLauncher = @"com.apple.IconServices.ImageDescriptor.MessagesExtensionLauncher";
IS_EXPORT NSString *const kISImageDescriptorMessagesExtensionStatus = @"com.apple.IconServices.ImageDescriptor.MessagesExtensionStatus";
IS_EXPORT NSString *const kISImageDescriptorNotification = @"com.apple.IconServices.ImageDescriptor.Notification";
IS_EXPORT NSString *const kISImageDescriptorSpotlight = @"com.apple.IconServices.ImageDescriptor.Spotlight";
IS_EXPORT NSString *const kISImageDescriptorTableUIName = @"com.apple.IconServices.ImageDescriptor.TableUIName";
IS_EXPORT NSString *const kISImageDescriptorWidgetAddGallery = @"com.apple.IconServices.ImageDescriptor.WidgetAddGallery";

#pragma mark - Image descriptors

IS_EXPORT
@interface ISImageDescriptor : NSObject <NSCopying, NSSecureCoding>
@property CGSize size;
@property double scale;
@property unsigned long long shape;
@property unsigned long long appearance;
@property unsigned long long background;
@property unsigned long long backgroundStyle;
@property unsigned long long layoutDirection;
@property unsigned long long platform;
@property BOOL drawBorder;
@property (strong) id tintColor;
@end

@implementation ISImageDescriptor

+ (BOOL)supportsSecureCoding { return YES; }

/* Apple's named descriptors, with their sizes, scales and shapes. */
+ (instancetype)imageDescriptorNamed:(NSString *)name
{
    static NSDictionary *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            kISImageDescriptorActivity : @[ @76, @76, @0 ],
            kISImageDescriptorBadgedDocumentScalableSize : @[ @246.5, @320, @3 ],
            kISImageDescriptorBadgedDocumentSize : @[ @37, @48, @3 ],
            kISImageDescriptorCarLauncher : @[ @60, @60, @0 ],
            kISImageDescriptorCarNotification : @[ @29, @29, @0 ],
            kISImageDescriptorCustomDocumentCompact : @[ @64, @84, @3 ],
            kISImageDescriptorCustomDocumentRegular : @[ @96, @128, @3 ],
            kISImageDescriptorCustomDocumentScalableSize : @[ @246.5, @320, @3 ],
            kISImageDescriptorCustomDocumentSize : @[ @37, @48, @3 ],
            kISImageDescriptorCustomDocumentTable : @[ @34, @44, @3 ],
            kISImageDescriptorHomeScreen : @[ @60, @60, @0 ],
            kISImageDescriptorLargeHomeScreen : @[ @60, @60, @0 ],
            kISImageDescriptorMessagesExtensionBadge : @[ @32, @24, @4 ],
            kISImageDescriptorMessagesExtensionLauncher : @[ @60, @45, @4 ],
            kISImageDescriptorMessagesExtensionStatus : @[ @27, @20, @4 ],
            kISImageDescriptorNotification : @[ @20, @20, @0 ],
            kISImageDescriptorSpotlight : @[ @40, @40, @0 ],
            kISImageDescriptorTableUIName : @[ @28, @28, @0 ],
            kISImageDescriptorWidgetAddGallery : @[ @32, @32, @1 ],
        };
    });
    NSArray *v = name ? table[name] : nil;
    if (!v)
        return nil;
    ISImageDescriptor *d = [[self alloc] initWithSize:CGSizeMake([v[0] doubleValue], [v[1] doubleValue]) scale:2];
    d.shape = [v[2] unsignedLongLongValue];
    return d;
}

- (instancetype)init
{
    return [self initWithSize:CGSizeMake(32, 32) scale:1];
}

- (instancetype)initWithSize:(CGSize)size scale:(double)scale
{
    if ((self = [super init])) {
        _size = size;
        _scale = scale > 0 ? scale : 1;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone
{
    ISImageDescriptor *d = [[[self class] alloc] initWithSize:_size scale:_scale];
    d.shape = _shape;
    d.appearance = _appearance;
    d.background = _background;
    d.backgroundStyle = _backgroundStyle;
    d.layoutDirection = _layoutDirection;
    d.platform = _platform;
    d.drawBorder = _drawBorder;
    d.tintColor = _tintColor;
    return d;
}

- (instancetype)initWithCoder:(NSCoder *)c
{
    if ((self = [self initWithSize:CGSizeMake([c decodeDoubleForKey:@"width"], [c decodeDoubleForKey:@"height"])
                             scale:[c decodeDoubleForKey:@"scale"]])) {
        _shape = (unsigned long long)[c decodeInt64ForKey:@"shape"];
        _appearance = (unsigned long long)[c decodeInt64ForKey:@"appearance"];
        _drawBorder = [c decodeBoolForKey:@"drawBorder"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)c
{
    [c encodeDouble:_size.width forKey:@"width"];
    [c encodeDouble:_size.height forKey:@"height"];
    [c encodeDouble:_scale forKey:@"scale"];
    [c encodeInt64:(int64_t)_shape forKey:@"shape"];
    [c encodeInt64:(int64_t)_appearance forKey:@"appearance"];
    [c encodeBool:_drawBorder forKey:@"drawBorder"];
}

- (BOOL)isEqual:(id)o
{
    if (![o isKindOfClass:[ISImageDescriptor class]])
        return NO;
    ISImageDescriptor *d = o;
    return CGSizeEqualToSize(d.size, _size) && d.scale == _scale && d.shape == _shape && d.appearance == _appearance &&
           d.drawBorder == _drawBorder;
}

- (NSUInteger)hash
{
    return (NSUInteger)(_size.width * 31 + _size.height) ^ (NSUInteger)(_scale * 7) ^ (NSUInteger)_shape;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p> %gx%g @%gx shape %llu", [self class], self, _size.width, _size.height, _scale, _shape];
}

@end

#pragma mark - Images

IS_EXPORT
@interface IFImage : NSObject <NSSecureCoding>
- (instancetype)initWithCGImage:(CGImageRef)image scale:(double)scale;
@property (readonly) CGImageRef CGImage;
@property (readonly) double scale;
@property (readonly) CGSize size;
@property (readonly) CGSize pixelSize;
@property (readonly) BOOL placeholder;
@end

@implementation IFImage {
    CGImageRef _image;
    double _scale;
    BOOL _placeholder;
}

+ (BOOL)supportsSecureCoding { return YES; }

+ (instancetype)imageWithContentsOfURL:(NSURL *)url
{
    return [[self alloc] initWithContentsOfURL:url];
}

- (instancetype)initWithCGImage:(CGImageRef)image scale:(double)scale
{
    if (!image)
        return nil;
    if ((self = [super init])) {
        _image = CGImageRetain(image);
        _scale = scale > 0 ? scale : 1;
    }
    return self;
}

- (instancetype)initWithCGImage:(CGImageRef)image scale:(double)scale minimumSize:(CGSize)minimum placeholder:(BOOL)placeholder
{
    if ((self = [self initWithCGImage:image scale:scale]))
        _placeholder = placeholder;
    return self;
}

- (instancetype)initWithContentsOfURL:(NSURL *)url scale:(double)scale
{
    CGImageSourceRef src = url ? CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL) : NULL;
    CGImageRef im = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
    if (src)
        CFRelease(src);
    self = [self initWithCGImage:im scale:scale];
    CGImageRelease(im);
    return self;
}

- (instancetype)initWithContentsOfURL:(NSURL *)url
{
    return [self initWithContentsOfURL:url scale:1];
}

- (void)dealloc
{
    CGImageRelease(_image);
}

- (CGImageRef)CGImage { return _image; }
- (double)scale { return _scale; }
- (BOOL)placeholder { return _placeholder; }
- (CGSize)pixelSize { return CGSizeMake(CGImageGetWidth(_image), CGImageGetHeight(_image)); }
- (CGSize)size { return CGSizeMake(CGImageGetWidth(_image) / _scale, CGImageGetHeight(_image) / _scale); }
- (double)dimension { return MAX(self.size.width, self.size.height); }

- (instancetype)imageForSize:(CGSize)size scale:(double)scale
{
    return self;
}

- (BOOL)writeToURL:(NSURL *)url
{
    CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
    if (!d)
        return NO;
    CGImageDestinationAddImage(d, _image, NULL);
    BOOL ok = CGImageDestinationFinalize(d);
    CFRelease(d);
    return ok;
}

- (instancetype)initWithCoder:(NSCoder *)c
{
    NSData *png = [c decodeObjectOfClass:[NSData class] forKey:@"png"];
    CGImageSourceRef src = png ? CGImageSourceCreateWithData((__bridge CFDataRef)png, NULL) : NULL;
    CGImageRef im = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
    if (src)
        CFRelease(src);
    self = [self initWithCGImage:im scale:[c decodeDoubleForKey:@"scale"]];
    CGImageRelease(im);
    return self;
}

- (void)encodeWithCoder:(NSCoder *)c
{
    NSMutableData *png = [NSMutableData data];
    CGImageDestinationRef d = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)png, CFSTR("public.png"), 1, NULL);
    if (d) {
        CGImageDestinationAddImage(d, _image, NULL);
        CGImageDestinationFinalize(d);
        CFRelease(d);
    }
    [c encodeObject:png forKey:@"png"];
    [c encodeDouble:_scale forKey:@"scale"];
}

@end

IS_EXPORT
@interface ISImage : IFImage
@end

@implementation ISImage
@end

#pragma mark - Drawing

static CGContextRef
bitmap(size_t w, size_t h)
{
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(NULL, w, h, 8, 0, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(cs);
    if (c)
        CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
    return c;
}

static void
fill_round(CGContextRef c, CGRect r, CGFloat radius, CGFloat red, CGFloat green, CGFloat blue)
{
    CGPathRef p = CGPathCreateWithRoundedRect(r, MIN(radius, r.size.width / 2), MIN(radius, r.size.height / 2), NULL);
    CGContextSetRGBFillColor(c, red, green, blue, 1);
    CGContextAddPath(c, p);
    CGContextFillPath(c);
    CGPathRelease(p);
}

typedef enum { GenericApplication, GenericDocument, GenericFolder, GenericVolume, GenericTransparent } Generic;

/* Finch's generic icons, as AppKit draws them (NSWorkspace.m's draw_icon), in a square. */
static void
draw_generic(CGContextRef c, Generic kind, CGFloat x, CGFloat y, CGFloat s)
{
    switch (kind) {
    case GenericApplication: {
        CGRect tile = CGRectMake(x + s * 0.09, y + s * 0.09, s * 0.82, s * 0.82);
        CGPathRef p = CGPathCreateWithRoundedRect(tile, s * 0.19, s * 0.19, NULL);
        CGContextSaveGState(c);
        CGContextAddPath(c, p);
        CGContextClip(c);
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGFloat comps[] = {0.36, 0.66, 1.0, 1, 0.0, 0.40, 0.88, 1};
        CGGradientRef g = CGGradientCreateWithColorComponents(cs, comps, NULL, 2);
        CGContextDrawLinearGradient(c, g, CGPointMake(0, CGRectGetMaxY(tile)), CGPointMake(0, tile.origin.y), 0);
        CGGradientRelease(g);
        CGColorSpaceRelease(cs);
        CGContextRestoreGState(c);
        CGPathRelease(p);
        CGRect win = CGRectMake(x + s * 0.25, y + s * 0.28, s * 0.50, s * 0.42);
        fill_round(c, win, s * 0.05, 1, 1, 1);
        fill_round(c, CGRectMake(win.origin.x, CGRectGetMaxY(win) - s * 0.09, win.size.width, s * 0.09), s * 0.04, 0.80, 0.88, 1.0);
        CGContextSetRGBFillColor(c, 0.0, 0.40, 0.88, 1);
        CGContextFillRect(c, CGRectMake(win.origin.x + s * 0.07, win.origin.y + s * 0.20, s * 0.30, s * 0.035));
        CGContextFillRect(c, CGRectMake(win.origin.x + s * 0.07, win.origin.y + s * 0.12, s * 0.22, s * 0.035));
        break;
    }
    case GenericFolder:
        fill_round(c, CGRectMake(x + s * 0.08, y + s * 0.62, s * 0.36, s * 0.14), s * 0.04, 0.42, 0.68, 0.95);
        fill_round(c, CGRectMake(x + s * 0.08, y + s * 0.16, s * 0.84, s * 0.54), s * 0.06, 0.42, 0.68, 0.95);
        fill_round(c, CGRectMake(x + s * 0.08, y + s * 0.16, s * 0.84, s * 0.48), s * 0.06, 0.55, 0.78, 0.99);
        break;
    case GenericDocument: {
        CGFloat l = x + s * 0.20, r = x + s * 0.80, t = y + s * 0.92, b = y + s * 0.08, fold = s * 0.18, lw = MAX(1, s / 64);
        CGMutablePathRef p = CGPathCreateMutable();
        CGPathMoveToPoint(p, NULL, l, b);
        CGPathAddLineToPoint(p, NULL, r, b);
        CGPathAddLineToPoint(p, NULL, r, t - fold);
        CGPathAddLineToPoint(p, NULL, r - fold, t);
        CGPathAddLineToPoint(p, NULL, l, t);
        CGPathCloseSubpath(p);
        CGContextSetRGBFillColor(c, 1, 1, 1, 1);
        CGContextAddPath(c, p);
        CGContextFillPath(c);
        CGContextSetRGBStrokeColor(c, 0.70, 0.72, 0.76, 1);
        CGContextSetLineWidth(c, lw);
        CGContextAddPath(c, p);
        CGContextStrokePath(c);
        CGPathRelease(p);
        CGMutablePathRef f = CGPathCreateMutable();
        CGPathMoveToPoint(f, NULL, r - fold, t);
        CGPathAddLineToPoint(f, NULL, r - fold, t - fold);
        CGPathAddLineToPoint(f, NULL, r, t - fold);
        CGPathCloseSubpath(f);
        CGContextSetRGBFillColor(c, 0.86, 0.87, 0.90, 1);
        CGContextAddPath(c, f);
        CGContextFillPath(c);
        CGContextAddPath(c, f);
        CGContextStrokePath(c);
        CGPathRelease(f);
        CGContextSetRGBFillColor(c, 0.78, 0.80, 0.84, 1);
        for (int i = 0; i < 5; i++)
            CGContextFillRect(c, CGRectMake(l + s * 0.10, b + s * (0.18 + 0.11 * i), s * (i == 4 ? 0.25 : 0.40), MAX(1, s * 0.03)));
        break;
    }
    case GenericVolume:
        fill_round(c, CGRectMake(x + s * 0.08, y + s * 0.28, s * 0.84, s * 0.44), s * 0.08, 0.62, 0.65, 0.70);
        fill_round(c, CGRectMake(x + s * 0.08, y + s * 0.28, s * 0.84, s * 0.20), s * 0.08, 0.50, 0.53, 0.58);
        fill_round(c, CGRectMake(x + s * 0.74, y + s * 0.34, s * 0.08, s * 0.08), s * 0.04, 0.30, 0.85, 0.40);
        break;
    case GenericTransparent:
        break;
    }
}

/* The representation of an image source nearest above a pixel size (else the largest). */
static CGImageRef
best_from_source(CGImageSourceRef src, size_t want)
{
    size_t n = CGImageSourceGetCount(src), pick = 0, pickSize = 0;
    BOOL above = NO;
    for (size_t i = 0; i < n; i++) {
        NSDictionary *p = (__bridge_transfer NSDictionary *)CGImageSourceCopyPropertiesAtIndex(src, i, NULL);
        size_t w = [p[(id)kCGImagePropertyPixelWidth] unsignedLongValue];
        BOOL isAbove = w >= want;
        if (pickSize == 0 || (isAbove && (!above || w < pickSize)) || (!isAbove && !above && w > pickSize)) {
            pick = i;
            pickSize = w;
            above = isAbove;
        }
    }
    return n ? CGImageSourceCreateImageAtIndex(src, pick, NULL) : NULL;
}

/* An image drawn to exactly w x h pixels, aspect kept and centred. */
static CGImageRef
fit(CGImageRef im, size_t w, size_t h)
{
    if (!im)
        return NULL;
    if (CGImageGetWidth(im) == w && CGImageGetHeight(im) == h)
        return CGImageRetain(im);
    CGContextRef c = bitmap(w, h);
    if (!c)
        return NULL;
    double sw = (double)w / CGImageGetWidth(im), sh = (double)h / CGImageGetHeight(im), s = MIN(sw, sh);
    double dw = CGImageGetWidth(im) * s, dh = CGImageGetHeight(im) * s;
    CGContextDrawImage(c, CGRectMake((w - dw) / 2, (h - dh) / 2, dw, dh), im);
    CGImageRef out = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    return out;
}

#pragma mark - Icons

typedef CGImageRef (^ISRender)(size_t w, size_t h, double scale, BOOL *placeholder); /* +1 */

static NSURL *
app_url_for_identifier(NSString *bid)
{
    if (!bid.length)
        return nil;
    NSArray *urls = (__bridge_transfer NSArray *)LSCopyApplicationURLsForBundleIdentifier((__bridge CFStringRef)bid, NULL);
    if (urls.count)
        return urls.firstObject;
    for (NSString *dir in @[ @"/Applications", @"/System/Applications", @"/System/Applications/Utilities", @"/Applications/Utilities",
                             @"/System/Library/CoreServices" ]) {
        for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL]) {
            if (![name.pathExtension isEqualToString:@"app"])
                continue;
            NSString *path = [dir stringByAppendingPathComponent:name];
            if ([[NSBundle bundleWithPath:path].bundleIdentifier isEqualToString:bid])
                return [NSURL fileURLWithPath:path];
        }
    }
    return nil;
}

/* A bundle's own icon at a pixel size: its .icns, else its asset catalog's icon. */
static CGImageRef
bundle_icon(NSURL *bundleURL, size_t want)
{
    NSBundle *b = bundleURL ? [NSBundle bundleWithURL:bundleURL] : nil;
    if (!b)
        return NULL;
    NSDictionary *info = b.infoDictionary;
    NSString *file = info[@"CFBundleIconFile"];
    if ([file isKindOfClass:[NSString class]] && file.length) {
        NSString *path = [b pathForResource:file.stringByDeletingPathExtension ofType:file.pathExtension.length ? file.pathExtension : @"icns"];
        CGImageSourceRef src = path ? CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL) : NULL;
        if (src) {
            CGImageRef im = best_from_source(src, want);
            CFRelease(src);
            if (im)
                return im;
        }
    }
    NSString *name = info[@"CFBundleIconName"];
    if ([name isKindOfClass:[NSString class]] && name.length) {
        /* (CoreUI is Finch's too; looked up when first needed, as it sits above us) */
        static Class catalogClass;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_LAZY);
            catalogClass = NSClassFromString(@"CUICatalog");
        });
        NSURL *car = [b URLForResource:@"Assets" withExtension:@"car"];
        id catalog = car && catalogClass ? [[catalogClass alloc] initWithURL:car error:NULL] : nil;
        id named = nil;
        if ([catalog respondsToSelector:@selector(imageWithName:scaleFactor:)])
            named = ((id(*)(id, SEL, NSString *, CGFloat))objc_msgSend)(catalog, @selector(imageWithName:scaleFactor:), name, 2);
        if ([named respondsToSelector:@selector(image)]) {
            CGImageRef im = ((CGImageRef(*)(id, SEL))objc_msgSend)(named, @selector(image));
            if (im)
                return CGImageRetain(im);
        }
    }
    return NULL;
}

static Generic
generic_for_type(NSString *type)
{
    UTType *t = type ? [UTType typeWithIdentifier:type] : nil;
    if (!t)
        return GenericDocument;
    if ([t conformsToType:UTTypeApplicationBundle] || [t conformsToType:UTTypeApplication])
        return GenericApplication;
    if ([t conformsToType:UTTypeVolume])
        return GenericVolume;
    if (([t conformsToType:UTTypeFolder] || [t conformsToType:UTTypeDirectory]) && ![t conformsToType:UTTypePackage])
        return GenericFolder;
    return GenericDocument;
}

IS_EXPORT
@interface ISIcon : NSObject <NSSecureCoding>
@end

@implementation ISIcon {
    ISRender _render;
    NSMutableDictionary<NSString *, ISImage *> *_images;
    NSString *_identity; /* for coding and equality */
}

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)_initWithIdentity:(NSString *)identity render:(ISRender)render
{
    if ((self = [super init])) {
        _identity = [identity copy];
        _render = [render copy];
        _images = [NSMutableDictionary dictionary];
    }
    return self;
}

static ISRender
generic_render(Generic kind)
{
    return ^CGImageRef(size_t w, size_t h, double scale, BOOL *placeholder) {
        CGContextRef c = bitmap(w, h);
        if (!c)
            return NULL;
        CGFloat s = MIN(w, h);
        draw_generic(c, kind, (w - s) / 2, (h - s) / 2, s);
        CGImageRef im = CGBitmapContextCreateImage(c);
        CGContextRelease(c);
        return im;
    };
}

static ISRender
bundle_render(NSURL *url, Generic fallback)
{
    return ^CGImageRef(size_t w, size_t h, double scale, BOOL *placeholder) {
        CGImageRef own = bundle_icon(url, MAX(w, h));
        if (own) {
            CGImageRef out = fit(own, w, h);
            CGImageRelease(own);
            return out;
        }
        if (placeholder)
            *placeholder = YES;
        return generic_render(fallback)(w, h, scale, NULL);
    };
}

+ (instancetype)genericApplicationIcon
{
    return [[self alloc] _initWithIdentity:@"generic:app" render:generic_render(GenericApplication)];
}

+ (instancetype)genericDocumentIcon
{
    return [[self alloc] _initWithIdentity:@"generic:document" render:generic_render(GenericDocument)];
}

+ (instancetype)placeholderIcon
{
    return [self genericApplicationIcon];
}

+ (instancetype)transparentIcon
{
    return [[self alloc] _initWithIdentity:@"generic:transparent" render:generic_render(GenericTransparent)];
}

/* This process's own app's icon. */
+ (instancetype)applicationIcon
{
    NSURL *u = [NSBundle mainBundle].bundleURL;
    return [[self alloc] _initWithIdentity:[@"bundle:" stringByAppendingString:u.path ?: @""] render:bundle_render(u, GenericApplication)];
}

- (instancetype)initWithBundleURL:(NSURL *)url
{
    BOOL isApp = [url.pathExtension isEqualToString:@"app"];
    return [self _initWithIdentity:[@"bundle:" stringByAppendingString:url.path ?: @""]
                            render:bundle_render(url, isApp ? GenericApplication : GenericFolder)];
}

- (instancetype)initWithBundleIdentifier:(NSString *)bid
{
    NSURL *u = app_url_for_identifier(bid);
    return [self _initWithIdentity:[@"id:" stringByAppendingString:bid ?: @""] render:bundle_render(u, GenericApplication)];
}

- (instancetype)initWithApplicationBundleIdentifier:(NSString *)bid
{
    return [self initWithBundleIdentifier:bid];
}

- (instancetype)initWithApplicationExtensionBundleIdentifier:(NSString *)bid
{
    return [self initWithBundleIdentifier:bid];
}

- (instancetype)initWithBundleURL:(NSURL *)url type:(NSString *)type
{
    return [self initWithType:type];
}

- (instancetype)initWithBundleURL:(NSURL *)url fileExtension:(NSString *)ext
{
    return [self initWithFileExtension:ext];
}

- (instancetype)initWithType:(NSString *)type
{
    return [self _initWithIdentity:[@"type:" stringByAppendingString:type ?: @""] render:generic_render(generic_for_type(type))];
}

- (instancetype)initWithType:(NSString *)type iconConfiguration:(id)configuration
{
    return [self initWithType:type];
}

- (instancetype)initWithTypeIdentifier:(NSString *)type layerGroups:(id)groups
{
    return [self initWithType:type];
}

- (instancetype)initWithFileExtension:(NSString *)ext
{
    return [self initWithType:[UTType typeWithFilenameExtension:ext ?: @""].identifier ?: @"public.data"];
}

- (instancetype)initWithMIMEType:(NSString *)mime
{
    return [self initWithType:[UTType typeWithMIMEType:mime ?: @""].identifier ?: @"public.data"];
}

- (instancetype)initWithTypeCode:(unsigned int)code
{
    return [self initWithType:@"public.data"];
}

/* A file: an app's or other bundle's own icon, else its type's. */
- (instancetype)initWithURL:(NSURL *)url
{
    NSNumber *dir = nil, *pkg = nil, *app = nil;
    [url getResourceValue:&dir forKey:NSURLIsDirectoryKey error:NULL];
    [url getResourceValue:&pkg forKey:NSURLIsPackageKey error:NULL];
    [url getResourceValue:&app forKey:NSURLIsApplicationKey error:NULL];
    if (app.boolValue || [url.pathExtension isEqualToString:@"app"])
        return [self initWithBundleURL:url];
    if ([url.path isEqualToString:@"/"])
        return [self _initWithIdentity:@"url:/" render:generic_render(GenericVolume)];
    if (dir.boolValue && !pkg.boolValue)
        return [self _initWithIdentity:[@"url:" stringByAppendingString:url.path ?: @""] render:generic_render(GenericFolder)];
    UTType *t = nil;
    [url getResourceValue:&t forKey:NSURLContentTypeKey error:NULL];
    return [self initWithType:t.identifier ?: [UTType typeWithFilenameExtension:url.pathExtension].identifier ?: @"public.data"];
}

- (instancetype)initWithURL:(NSURL *)url options:(unsigned long long)options
{
    return [self initWithURL:url];
}

- (instancetype)initWithURL:(NSURL *)url iconConfiguration:(id)configuration
{
    return [self initWithURL:url];
}

- (instancetype)initWithContentOfURL:(NSURL *)url
{
    CGImageSourceRef src = url ? CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL) : NULL;
    if (!src)
        return [self initWithURL:url];
    CFRelease(src);
    return [self _initWithIdentity:[@"content:" stringByAppendingString:url.path ?: @""]
                            render:^CGImageRef(size_t w, size_t h, double scale, BOOL *placeholder) {
                                CGImageSourceRef s = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
                                CGImageRef im = s ? best_from_source(s, MAX(w, h)) : NULL;
                                if (s)
                                    CFRelease(s);
                                CGImageRef out = fit(im, w, h);
                                CGImageRelease(im);
                                return out;
                            }];
}

- (instancetype)initWithIcnsData:(NSData *)data
{
    if (!data)
        return nil;
    return [self _initWithIdentity:[NSString stringWithFormat:@"icns:%lu", (unsigned long)data.hash]
                            render:^CGImageRef(size_t w, size_t h, double scale, BOOL *placeholder) {
                                CGImageSourceRef s = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
                                CGImageRef im = s ? best_from_source(s, MAX(w, h)) : NULL;
                                if (s)
                                    CFRelease(s);
                                CGImageRef out = fit(im, w, h);
                                CGImageRelease(im);
                                return out;
                            }];
}

- (instancetype)initWithIcns:(id)icns
{
    return [icns isKindOfClass:[NSData class]] ? [self initWithIcnsData:icns] : [self initWithType:@"public.data"];
}

/* Ready-made images (ISImage or IFImage): the nearest in size. */
- (instancetype)initWithImages:(NSArray *)images
{
    NSArray *copy = [images copy];
    return [self _initWithIdentity:[NSString stringWithFormat:@"images:%lu", (unsigned long)copy.hash]
                            render:^CGImageRef(size_t w, size_t h, double scale, BOOL *placeholder) {
                                IFImage *best = nil;
                                for (IFImage *i in copy) {
                                    if (![i isKindOfClass:[IFImage class]])
                                        continue;
                                    if (!best || (best.pixelSize.width < w && i.pixelSize.width > best.pixelSize.width) ||
                                        (i.pixelSize.width >= w && i.pixelSize.width < best.pixelSize.width))
                                        best = i;
                                }
                                return best ? fit(best.CGImage, w, h) : NULL;
                            }];
}

- (instancetype)initWithSymbolName:(NSString *)name
{
    return [self initWithType:@"public.data"];
}

- (instancetype)initWithSymbolName:(NSString *)name configuration:(id)configuration
{
    return [self initWithSymbolName:name];
}

#pragma mark Images

- (ISImage *)imageForDescriptor:(ISImageDescriptor *)d
{
    if (![d isKindOfClass:[ISImageDescriptor class]])
        return nil;
    /* as Apple's on the Mac: the size goes up to the next of the icon sizes, 16, 32, 128,
       256 and 512 points (512 at most) */
    static const double sizes[] = {16, 32, 128, 256, 512};
    double want = MAX(d.size.width, d.size.height), points = 512;
    for (size_t k = 0; k < sizeof sizes / sizeof *sizes; k++)
        if (want <= sizes[k]) {
            points = sizes[k];
            break;
        }
    size_t w = (size_t)lround(points * d.scale), h = w;
    NSString *key = [NSString stringWithFormat:@"%zux%zu@%g", w, h, d.scale];
    @synchronized(self) {
        ISImage *have = _images[key];
        if (have)
            return have;
    }
    BOOL placeholder = NO;
    CGImageRef im = _render ? _render(w, h, d.scale, &placeholder) : NULL;
    ISImage *i = im ? [[ISImage alloc] initWithCGImage:im scale:d.scale minimumSize:CGSizeZero placeholder:placeholder] : nil;
    CGImageRelease(im);
    if (i) {
        @synchronized(self) {
            _images[key] = i;
        }
    }
    return i;
}

- (ISImage *)prepareImageForDescriptor:(ISImageDescriptor *)d { return [self imageForDescriptor:d]; }

- (void)prepareImagesForImageDescriptors:(NSArray<ISImageDescriptor *> *)descriptors
{
    for (ISImageDescriptor *d in descriptors)
        [self imageForDescriptor:d];
}

- (void)prepareImagesForDescriptors:(NSArray<ISImageDescriptor *> *)descriptors
{
    [self prepareImagesForImageDescriptors:descriptors];
}

/* (the image stays the icon's: not retained for the caller) */
- (CGImageRef)CGImageForDescriptor:(ISImageDescriptor *)d { return [self imageForDescriptor:d].CGImage; }
- (CGImageRef)CGImageForImageDescriptor:(ISImageDescriptor *)d { return [self CGImageForDescriptor:d]; }

- (void)getCGImageForImageDescriptor:(ISImageDescriptor *)d completion:(void (^)(CGImageRef image))completion
{
    if (!completion)
        return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        completion([self CGImageForDescriptor:d]);
    });
}

- (ISImage *)imageForSize:(CGSize)size scale:(double)scale
{
    return [self imageForDescriptor:[[ISImageDescriptor alloc] initWithSize:size scale:scale]];
}

- (instancetype)iconWithDecorations:(NSArray *)decorations { return self; }
- (NSArray *)decorations { return @[]; }
- (id)symbol { return nil; }
- (unsigned long long)badgeOptions { return 0; }
- (unsigned long long)variantOptions { return 0; }
- (double)_aspectRatio { return 1; }

#pragma mark Coding

- (instancetype)initWithCoder:(NSCoder *)c
{
    NSString *identity = [c decodeObjectOfClass:[NSString class] forKey:@"identity"] ?: @"generic:document";
    if ([identity hasPrefix:@"bundle:"])
        return [self initWithBundleURL:[NSURL fileURLWithPath:[identity substringFromIndex:7]]];
    if ([identity hasPrefix:@"id:"])
        return [self initWithBundleIdentifier:[identity substringFromIndex:3]];
    if ([identity hasPrefix:@"type:"])
        return [self initWithType:[identity substringFromIndex:5]];
    if ([identity hasPrefix:@"url:"])
        return [self initWithURL:[NSURL fileURLWithPath:[identity substringFromIndex:4]]];
    if ([identity isEqualToString:@"generic:app"])
        return [self _initWithIdentity:identity render:generic_render(GenericApplication)];
    if ([identity isEqualToString:@"generic:transparent"])
        return [self _initWithIdentity:identity render:generic_render(GenericTransparent)];
    return [self _initWithIdentity:identity render:generic_render(GenericDocument)];
}

- (void)encodeWithCoder:(NSCoder *)c
{
    [c encodeObject:_identity forKey:@"identity"];
}

- (BOOL)isEqual:(id)o
{
    return [o isKindOfClass:[ISIcon class]] && [((ISIcon *)o)->_identity isEqualToString:_identity];
}

- (NSUInteger)hash { return _identity.hash; }

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p> %@", [self class], self, _identity];
}

@end

#pragma mark - Symbols

/* Type symbols (SF Symbols for UTTypes): none on Finch yet; the calls say so. */
IS_EXPORT
@interface ISSymbol : NSObject
@property (readonly, copy) NSString *name;
@end

@implementation ISSymbol

+ (instancetype)symbolForTypeIdentifier:(NSString *)type error:(NSError **)error
{
    if (error)
        *error = [NSError errorWithDomain:@"ISErrorDomain" code:-1
                                 userInfo:@{NSLocalizedDescriptionKey : @"No symbol for this type on Finch"}];
    return nil;
}

+ (instancetype)symbolForTypeIdentifier:(NSString *)type withResolutionStrategy:(unsigned long long)strategy
                         variantOptions:(unsigned long long)options error:(NSError **)error
{
    return [self symbolForTypeIdentifier:type error:error];
}

@end
