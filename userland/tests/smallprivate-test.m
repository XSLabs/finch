/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Small private frameworks: SoftLinking's _sl_dlopen (the first of a list of paths that
 * opens; an error message when none does), AppSupport's bitmap files (images written and
 * read back), ChronoServices' timeline controller and UserManagement's manager. Compared
 * with Apple's.
 */
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdlib.h>

extern void *_sl_dlopen(const char **paths, char **error);
extern CFArrayRef CPBitmapCreateImagesFromPath(CFStringRef path, CFPropertyListRef *properties, uint32_t flags, CFErrorRef *error);
extern long CPBitmapWriteImagesToPath(CFArrayRef images, uint32_t mode, CFDictionaryRef properties, CFStringRef path,
                                      uint32_t flags, CFErrorRef *error);

int
main(void)
{
    @autoreleasepool {
        const char *some[] = {"/nonexistent/libnothing.dylib", "/usr/lib/libz.1.dylib", NULL};
        char *err = NULL;
        void *h = _sl_dlopen(some, &err);
        printf("soft link: opened %d, zlibVersion found %d, error %d\n", h != NULL, h && dlsym(h, "zlibVersion"), err != NULL);
        const char *none[] = {"/nonexistent/a.dylib", "/nonexistent/b.dylib", NULL};
        err = NULL;
        h = _sl_dlopen(none, &err);
        printf("soft link to nothing: opened %d, error message %d\n", h != NULL, err && *err);
        free(err);

        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef c = CGBitmapContextCreate(NULL, 7, 5, 8, 0, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGContextSetRGBFillColor(c, 1, 0, 0, 1);
        CGContextFillRect(c, CGRectMake(0, 0, 7, 5));
        CGImageRef im = CGBitmapContextCreateImage(c);
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"finch-cpbitmap-test.png"];
        long wrote = CPBitmapWriteImagesToPath((__bridge CFArrayRef) @[(__bridge id)im], 1, (__bridge CFDictionaryRef) @{@"Scale" : @2},
                                               (__bridge CFStringRef)path, 0, NULL);
        CFPropertyListRef props = NULL;
        CFArrayRef back = CPBitmapCreateImagesFromPath((__bridge CFStringRef)path, &props, 2, NULL);
        CGImageRef first = back && CFArrayGetCount(back) ? (CGImageRef)CFArrayGetValueAtIndex(back, 0) : NULL;
        printf("bitmap file: written %d, read %ld image(s), %zux%zu, scale kept %d\n", wrote > 0, back ? (long)CFArrayGetCount(back) : -1L,
               first ? CGImageGetWidth(first) : 0, first ? CGImageGetHeight(first) : 0,
               [((__bridge NSDictionary *)props)[@"Scale"] isEqual:@2]);
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        [[NSFileManager defaultManager] removeItemAtPath:[path stringByAppendingString:@".properties"] error:NULL];

        dlopen("/System/Library/PrivateFrameworks/ChronoServices.framework/ChronoServices", RTLD_NOW);
        dlopen("/System/Library/PrivateFrameworks/UserManagement.framework/UserManagement", RTLD_NOW);
        Class T = objc_getClass("CHSTimelineController");
        id t = ((id(*)(id, SEL, id, id))objc_msgSend)([T alloc], sel_registerName("initWithExtensionBundleIdentifier:kind:"),
                                                      @"org.finch.example.widget", @"Example");
        printf("timeline controller: %d, kind %s\n", t != nil, [((id(*)(id, SEL))objc_msgSend)(t, sel_registerName("kind")) UTF8String]);
        Class U = objc_getClass("UMUserManager");
        id u = ((id(*)(id, SEL))objc_msgSend)(U, sel_registerName("sharedManager"));
        printf("user manager: %d, multi-user %d\n", u != nil, ((BOOL(*)(id, SEL))objc_msgSend)(u, sel_registerName("isMultiUser")));
    }
    return 0;
}
