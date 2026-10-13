/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSCIImageRep: a Core Image image as an image representation. Its size is the image's
 * extent (an infinite extent gives the largest size, as Apple's); drawing renders the
 * image through a CIContext on the current graphics context. Core Image is reached at
 * run time, so AppKit doesn't link it (Apple's soft-links it too).
 */
#import <AppKit/AppKit.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <float.h>

@implementation NSCIImageRep {
    CIImage *_image;
}

+ (instancetype)imageRepWithCIImage:(CIImage *)image { return [[[self alloc] initWithCIImage:image] autorelease]; }

- (instancetype)initWithCIImage:(CIImage *)image
{
    if ((self = [super init])) {
        _image = [(id)image retain];
        CGRect extent = ((CGRect(*)(id, SEL))objc_msgSend)((id)image, sel_registerName("extent"));
        BOOL infinite = CGRectIsInfinite(extent) || extent.size.width > 1e15;
        NSSize size = infinite ? NSMakeSize(DBL_MAX, DBL_MAX) : NSSizeFromCGSize(extent.size);
        self.size = size;
        self.pixelsWide = infinite ? NSImageRepMatchesDevice : (NSInteger)extent.size.width;
        self.pixelsHigh = infinite ? NSImageRepMatchesDevice : (NSInteger)extent.size.height;
        self.opaque = NO;
        self.colorSpaceName = NSCalibratedRGBColorSpace;
        self.bitsPerSample = 8;
        self.alpha = YES;
    }
    return self;
}

- (void)dealloc
{
    [(id)_image release];
    [super dealloc];
}

- (CIImage *)CIImage { return _image; }
- (id)copyWithZone:(NSZone *)zone { return [[NSCIImageRep alloc] initWithCIImage:_image]; }

- (BOOL)drawInRect:(NSRect)rect
{
    CGContextRef cg = [NSGraphicsContext currentContext].CGContext;
    if (!cg || !_image)
        return NO;
    dlopen("/System/Library/Frameworks/CoreImage.framework/CoreImage", RTLD_LAZY);
    Class CIContext = NSClassFromString(@"CIContext");
    id ctx = ((id(*)(id, SEL, CGContextRef, id))objc_msgSend)(CIContext, sel_registerName("contextWithCGContext:options:"), cg, nil);
    CGRect extent = ((CGRect(*)(id, SEL))objc_msgSend)((id)_image, sel_registerName("extent"));
    if (CGRectIsInfinite(extent) || extent.size.width > 1e15)
        extent = NSRectToCGRect(rect);
    ((void (*)(id, SEL, id, CGRect, CGRect))objc_msgSend)(ctx, sel_registerName("drawImage:inRect:fromRect:"), (id)_image,
                                                           NSRectToCGRect(rect), extent);
    return YES;
}

- (BOOL)draw
{
    NSSize s = self.size;
    return [self drawInRect:NSMakeRect(0, 0, s.width, s.height)];
}

@end
