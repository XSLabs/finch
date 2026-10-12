/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AppSupport (private): what apps take from it here. Bitmap files of several images
 * (CPBitmap: Finch's own files, through ImageIO, with their properties beside them), log flushing (os_log needs none),
 * ALCityManager (Apple's world-city database, which Finch doesn't carry: no cities) and
 * RadiosPreferences (airplane mode: off, and a Mac without radios to switch).
 */
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

#define AS_EXPORT __attribute__((visibility("default")))

/* CPBitmap files are Apple's own cache format; Finch keeps the images in a TIFF (a PNG
   for one) through ImageIO, and the properties the writer gave beside it, in
   "<path>.properties" (a property list), so what's written reads back. */
static CFStringRef
properties_path(CFStringRef path)
{
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("%@.properties"), path);
}

/* The images in a file, in order, and the properties written with them. */
AS_EXPORT CFArrayRef
CPBitmapCreateImagesFromPath(CFStringRef path, CFPropertyListRef *properties, uint32_t flags, CFErrorRef *error)
{
    if (properties)
        *properties = NULL;
    if (error)
        *error = NULL;
    CFURLRef url = path ? CFURLCreateWithFileSystemPath(NULL, path, kCFURLPOSIXPathStyle, false) : NULL;
    CGImageSourceRef src = url ? CGImageSourceCreateWithURL(url, NULL) : NULL;
    if (url)
        CFRelease(url);
    if (!src) {
        if (error)
            *error = CFErrorCreate(NULL, kCFErrorDomainPOSIX, 2 /* ENOENT */, NULL);
        return NULL;
    }
    size_t n = CGImageSourceGetCount(src);
    CFMutableArrayRef a = CFArrayCreateMutable(NULL, (CFIndex)n, &kCFTypeArrayCallBacks);
    for (size_t i = 0; i < n; i++) {
        CGImageRef im = CGImageSourceCreateImageAtIndex(src, i, NULL);
        if (im) {
            CFArrayAppendValue(a, im);
            CGImageRelease(im);
        }
    }
    CFRelease(src);
    if (properties) {
        CFStringRef pp = properties_path(path);
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:(__bridge NSString *)pp];
        CFRelease(pp);
        *properties = d ? CFBridgingRetain(d) : NULL;
    }
    return a;
}

/* images: CGImages; properties: kept with them; mode and flags: Apple's encoding choices.
   The bytes written, as Apple's returns (0 on failure). */
AS_EXPORT long
CPBitmapWriteImagesToPath(CFArrayRef images, uint32_t mode, CFDictionaryRef properties, CFStringRef path, uint32_t flags,
                          CFErrorRef *error)
{
    if (error)
        *error = NULL;
    CFIndex n = images ? CFArrayGetCount(images) : 0;
    if (!n || !path)
        return 0;
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, path, kCFURLPOSIXPathStyle, false);
    CGImageDestinationRef d = CGImageDestinationCreateWithURL(url, n > 1 ? CFSTR("public.tiff") : CFSTR("public.png"), (size_t)n, NULL);
    CFRelease(url);
    if (!d) {
        if (error)
            *error = CFErrorCreate(NULL, kCFErrorDomainPOSIX, 13 /* EACCES */, NULL);
        return 0;
    }
    for (CFIndex i = 0; i < n; i++)
        CGImageDestinationAddImage(d, (CGImageRef)CFArrayGetValueAtIndex(images, i), NULL);
    bool ok = CGImageDestinationFinalize(d);
    CFRelease(d);
    CFStringRef pp = properties_path(path);
    if (ok && properties)
        [(__bridge NSDictionary *)properties writeToFile:(__bridge NSString *)pp atomically:YES];
    else
        [[NSFileManager defaultManager] removeItemAtPath:(__bridge NSString *)pp error:NULL];
    CFRelease(pp);
    if (!ok)
        return 0;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:(__bridge NSString *)path error:NULL];
    return attrs ? (long)[attrs fileSize] : 1;
}

AS_EXPORT void CPLoggingFlush(void) {}

AS_EXPORT
@interface ALCityManager : NSObject
+ (instancetype)sharedManager;
@end

@implementation ALCityManager

+ (instancetype)sharedManager
{
    static ALCityManager *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [[self alloc] init]; });
    return m;
}

+ (BOOL)willApplyTimeZoneChanges1 { return NO; }
- (NSArray *)allCities { return @[]; }
- (NSArray *)citiesMatchingName:(NSString *)name { return @[]; }
- (NSArray *)defaultCitiesShownInWorldClock { return @[]; }

@end

AS_EXPORT
@interface RadiosPreferences : NSObject
@property (assign) id delegate;
@property BOOL airplaneMode;
@end

@implementation RadiosPreferences

- (instancetype)initWithQueue:(dispatch_queue_t)queue
{
    return [self init];
}

- (void)refresh {}
- (void)synchronize {}
/* (Apple's takes a CF value and key, the same in the ABI: a radio setting, of which a Mac has none) */
- (void)setValue:(id)value forKey:(NSString *)key {}

@end
