/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * QuickLookThumbnailing: QLThumbnailGenerator and its requests, over QuickLook's
 * thumbnails (QuickLook.m). Requests are served on a background queue: the best
 * representation is the file's own thumbnail when one can be drawn, else its icon; the
 * update handler hears the icon first, then the thumbnail.
 */
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#define QL_EXPORT __attribute__((visibility("default")))

CGImageRef FinchQuickLookThumbnail(NSURL *url, size_t maxPixels, BOOL iconMode, BOOL *isIcon);

typedef NS_OPTIONS(NSUInteger, QLThumbnailGenerationRequestRepresentationTypes) {
    QLThumbnailGenerationRequestRepresentationTypeIcon = 1 << 0,
    QLThumbnailGenerationRequestRepresentationTypeLowQualityThumbnail = 1 << 1,
    QLThumbnailGenerationRequestRepresentationTypeThumbnail = 1 << 2,
    QLThumbnailGenerationRequestRepresentationTypeAll = NSUIntegerMax,
};

typedef NS_ENUM(NSInteger, QLThumbnailRepresentationType) {
    QLThumbnailRepresentationTypeIcon = 0,
    QLThumbnailRepresentationTypeLowQualityThumbnail = 1,
    QLThumbnailRepresentationTypeThumbnail = 2,
};

QL_EXPORT NSString *const QLThumbnailErrorDomain = @"QLThumbnailErrorDomain";

QL_EXPORT
@interface QLThumbnailGenerationRequest : NSObject <NSCopying, NSSecureCoding>
- (instancetype)initWithFileAtURL:(NSURL *)url size:(CGSize)size scale:(CGFloat)scale
              representationTypes:(QLThumbnailGenerationRequestRepresentationTypes)types;
@property (copy) NSURL *fileURL;
@property CGSize size;
@property CGFloat scale;
@property QLThumbnailGenerationRequestRepresentationTypes representationTypes;
@property CGFloat minimumDimension;
@property BOOL iconMode;
@property (copy) UTType *contentType;
@property (copy) NSData *data;
@property (strong) id item;
@property (strong) NSColor *tintColor;
@property (getter=isCancelled) BOOL cancelled;
@property (getter=isFinished) BOOL finished;
@property (copy) void (^completionBlock)(id, NSError *);
@property (copy) void (^updateBlock)(id, NSError *);
@property (readonly) NSUUID *uuid;
@end

@implementation QLThumbnailGenerationRequest

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithFileAtURL:(NSURL *)url size:(CGSize)size scale:(CGFloat)scale
              representationTypes:(QLThumbnailGenerationRequestRepresentationTypes)types
{
    if ((self = [super init])) {
        _fileURL = [url copy];
        _size = size;
        _scale = scale > 0 ? scale : 1;
        _representationTypes = types;
        _uuid = [NSUUID UUID];
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone
{
    QLThumbnailGenerationRequest *r = [[QLThumbnailGenerationRequest alloc] initWithFileAtURL:_fileURL size:_size scale:_scale
                                                                         representationTypes:_representationTypes];
    r.iconMode = _iconMode;
    r.contentType = _contentType;
    r.minimumDimension = _minimumDimension;
    return r;
}

- (instancetype)copyWithSize:(CGSize)size
{
    QLThumbnailGenerationRequest *r = [self copy];
    r.size = size;
    return r;
}

- (BOOL)isValid { return _fileURL != nil && _size.width > 0 && _size.height > 0; }
- (BOOL)isUbiquitous { return NO; }
- (void)cancel { self.cancelled = YES; }
- (void)finish { self.finished = YES; }

- (instancetype)initWithCoder:(NSCoder *)c
{
    return [self initWithFileAtURL:[c decodeObjectOfClass:[NSURL class] forKey:@"url"] size:[c decodeSizeForKey:@"size"]
                             scale:[c decodeDoubleForKey:@"scale"]
               representationTypes:(QLThumbnailGenerationRequestRepresentationTypes)[c decodeInt64ForKey:@"types"]];
}

- (void)encodeWithCoder:(NSCoder *)c
{
    [c encodeObject:_fileURL forKey:@"url"];
    [c encodeSize:_size forKey:@"size"];
    [c encodeDouble:_scale forKey:@"scale"];
    [c encodeInt64:(int64_t)_representationTypes forKey:@"types"];
}

@end

QL_EXPORT
@interface QLThumbnailRepresentation : NSObject
@property (readonly) QLThumbnailRepresentationType type;
@property (readonly) CGImageRef CGImage;
@property (readonly, strong) NSImage *NSImage;
@property (readonly) CGRect contentRect;
@end

@implementation QLThumbnailRepresentation {
    CGImageRef _image;
    CGFloat _scale;
}

- (instancetype)_initWithImage:(CGImageRef)image type:(QLThumbnailRepresentationType)type scale:(CGFloat)scale
{
    if ((self = [super init])) {
        _image = CGImageRetain(image);
        _type = type;
        _scale = scale;
    }
    return self;
}

- (void)dealloc { CGImageRelease(_image); }
- (CGImageRef)CGImage { return _image; }

- (NSImage *)NSImage
{
    return [[NSImage alloc] initWithCGImage:_image size:NSMakeSize(CGImageGetWidth(_image) / _scale, CGImageGetHeight(_image) / _scale)];
}

- (CGRect)contentRect
{
    return CGRectMake(0, 0, CGImageGetWidth(_image) / _scale, CGImageGetHeight(_image) / _scale);
}

@end

QL_EXPORT
@interface QLThumbnailGenerator : NSObject
@property (class, readonly, strong) QLThumbnailGenerator *sharedGenerator;
@end

@implementation QLThumbnailGenerator {
    dispatch_queue_t _queue;
}

+ (QLThumbnailGenerator *)sharedGenerator
{
    static QLThumbnailGenerator *g;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ g = [[self alloc] init]; });
    return g;
}

- (instancetype)init
{
    if ((self = [super init]))
        _queue = dispatch_queue_create("org.finch.quicklook.thumbnails", DISPATCH_QUEUE_CONCURRENT);
    return self;
}

static QLThumbnailRepresentation *
make(QLThumbnailGenerationRequest *r, BOOL icon, NSError **error)
{
    size_t px = (size_t)lround(MAX(r.size.width, r.size.height) * r.scale);
    BOOL isIcon = NO;
    CGImageRef im = FinchQuickLookThumbnail(r.fileURL, px, icon || r.iconMode, &isIcon);
    if (!im) {
        if (error)
            *error = [NSError errorWithDomain:QLThumbnailErrorDomain code:3 /* no representation */ userInfo:nil];
        return nil;
    }
    QLThumbnailRepresentation *rep = [[QLThumbnailRepresentation alloc] _initWithImage:im
                                                                                  type:isIcon ? QLThumbnailRepresentationTypeIcon
                                                                                              : QLThumbnailRepresentationTypeThumbnail
                                                                                 scale:r.scale];
    CGImageRelease(im);
    return rep;
}

- (void)generateBestRepresentationForRequest:(QLThumbnailGenerationRequest *)request
                           completionHandler:(void (^)(QLThumbnailRepresentation *, NSError *))handler
{
    dispatch_async(_queue, ^{
        NSError *e = nil;
        QLThumbnailRepresentation *rep = request.isCancelled ? nil : make(request, NO, &e);
        if (request.isCancelled)
            e = [NSError errorWithDomain:QLThumbnailErrorDomain code:4 /* cancelled */ userInfo:nil];
        request.finished = YES;
        if (handler)
            handler(rep, e);
    });
}

- (void)generateRepresentationsForRequest:(QLThumbnailGenerationRequest *)request
                            updateHandler:(void (^)(QLThumbnailRepresentation *, QLThumbnailRepresentationType, NSError *))handler
{
    dispatch_async(_queue, ^{
        if (request.representationTypes & QLThumbnailGenerationRequestRepresentationTypeIcon) {
            NSError *e = nil;
            QLThumbnailRepresentation *icon = make(request, YES, &e);
            if (handler && !request.isCancelled)
                handler(icon, QLThumbnailRepresentationTypeIcon, e);
        }
        if (request.representationTypes & (QLThumbnailGenerationRequestRepresentationTypeThumbnail |
                                           QLThumbnailGenerationRequestRepresentationTypeLowQualityThumbnail)) {
            NSError *e = nil;
            QLThumbnailRepresentation *t = make(request, NO, &e);
            if (handler && !request.isCancelled && t.type == QLThumbnailRepresentationTypeThumbnail)
                handler(t, QLThumbnailRepresentationTypeThumbnail, nil);
        }
        request.finished = YES;
    });
}

- (void)cancelRequest:(QLThumbnailGenerationRequest *)request
{
    [request cancel];
}

- (void)saveBestRepresentationForRequest:(QLThumbnailGenerationRequest *)request toFileAtURL:(NSURL *)url
                         withContentType:(NSString *)type completionHandler:(void (^)(NSError *))handler
{
    [self generateBestRepresentationForRequest:request completionHandler:^(QLThumbnailRepresentation *rep, NSError *e) {
        if (rep) {
            CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, (__bridge CFStringRef)(type ?: @"public.png"), 1, NULL);
            if (d) {
                CGImageDestinationAddImage(d, rep.CGImage, NULL);
                if (!CGImageDestinationFinalize(d))
                    e = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError userInfo:nil];
                CFRelease(d);
            }
        }
        if (handler)
            handler(e);
    }];
}

@end
