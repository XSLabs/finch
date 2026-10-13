/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * What SwiftUICore links that Finch doesn't have elsewhere:
 *   - libAccessibility's client identification (SwiftUI asks which assistive client is
 *     making a request): Finch has no assistive clients yet, so none (0);
 *   - the Swift 5.6 and concurrency compatibility libraries' force-load anchors, which
 *     the compiler adds for older deployment targets; SwiftUI targets macOS 26, which
 *     has no need of them;
 *   - the Metal overlay's force-load anchor: a module imports Metal's Swift overlay without
 *     using it, and Finch has no Metal yet, so the anchor is satisfied here and the
 *     overlay isn't linked.
 */
#include <stdint.h>

__attribute__((visibility("hidden"))) uint32_t _AXGetClientForCurrentRequestUntrusted(void) { return 0; }
__attribute__((visibility("hidden"))) void _AXSetClientIdentificationOverride(uint32_t client) { (void)client; }
__attribute__((visibility("hidden"))) char _swift_FORCE_LOAD_$_swiftCompatibility56;
__attribute__((visibility("hidden"))) char _swift_FORCE_LOAD_$_swiftCompatibilityConcurrency;
__attribute__((visibility("hidden"))) char _swift_FORCE_LOAD_$_swiftMetal;

/*
 * Named images and symbols, for SwiftUI's Image without CoreUI: AppKit's NSImage (Finch's
 * symbol artwork, or the bundle's image by name), drawn at twice its size. Returns a +1
 * CGImage, or NULL; *scale is its pixels per point and *isTemplate whether it's a template.
 * Found through the Objective-C runtime (SwiftUICore can't import AppKit).
 */
#include <CoreGraphics/CoreGraphics.h>
#include <objc/message.h>
#include <objc/runtime.h>

typedef struct { double x, y, w, h; } FinchRect;
typedef struct { double w, h; } FinchSize;

__attribute__((visibility("hidden"))) CGImageRef
_FinchPlatformImageCreate(const char *name, void *bundle, double *scale, _Bool *isTemplate)
{
    Class NSImageClass = objc_getClass("NSImage"), NSStringClass = objc_getClass("NSString");
    if (!NSImageClass || !NSStringClass || !name)
        return NULL;
    id str = ((id (*)(Class, SEL, const char *))objc_msgSend)(NSStringClass, sel_registerName("stringWithUTF8String:"), name);
    id image = bundle ? ((id (*)(id, SEL, id))objc_msgSend)((id)bundle, sel_registerName("imageForResource:"), str)
                      : ((id (*)(Class, SEL, id, id))objc_msgSend)(NSImageClass, sel_registerName("imageWithSystemSymbolName:accessibilityDescription:"),
                                                                  str, nil);
    if (!image)
        return NULL;
    FinchSize size = ((FinchSize (*)(id, SEL))objc_msgSend)(image, sel_registerName("size"));
    FinchRect rect = {0, 0, size.w * 2, size.h * 2};
    CGImageRef cg = ((CGImageRef (*)(id, SEL, FinchRect *, id, id))objc_msgSend)(image, sel_registerName("CGImageForProposedRect:context:hints:"),
                                                                               &rect, nil, nil);
    if (!cg)
        return NULL;
    *scale = size.w > 0 ? (double)CGImageGetWidth(cg) / size.w : 1;
    *isTemplate = !bundle || ((BOOL (*)(id, SEL))objc_msgSend)(image, sel_registerName("isTemplate"));
    return CGImageRetain(cg);
}
