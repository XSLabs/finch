/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * SkyLight (private): the window server's client library, whose SLS calls
 * CoreGraphics' CGS ones are on macOS. Finch's window server is its own
 * (userland/WindowServer) and CoreGraphics talks to it; these are the SLS calls apps
 * import directly, over CoreGraphics: window capture, display headroom and presets,
 * and the capture options and connection keys.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>

#define EXPORT __attribute__((visibility("default")))

typedef int SLSConnectionID;

/* Capture options (Apple's values) */
EXPORT const uint32_t kSLSCaptureNoTCCs = 0x100000;
EXPORT const uint32_t kSLSCaptureExtendedRange = 0x200000;
EXPORT const uint32_t kSLSCaptureIgnoreDeformingTransforms = 0x800000;
EXPORT const uint32_t kSLSCapturePrioritizeCaptureRectCenter = 0x400000;

/* Connection property keys */
EXPORT const CFStringRef kSLSConnectionHasPluginPower = CFSTR("ConnectionHasPluginPower");

extern SLSConnectionID CGSMainConnectionID(void);
/* (the SDK marks it unavailable to apps; CoreGraphics still has it, and so does Finch's) */
extern CGImageRef window_list_image(CGRect, CFArrayRef, CGWindowImageOption) __asm__("_CGWindowListCreateImageFromArray");

EXPORT SLSConnectionID SLSMainConnectionID(void) { return CGSMainConnectionID(); }

/* The windows listed, composited, over the rectangle (global points): an array of one
   image, as Apple's returns for a rectangle. */
EXPORT CFArrayRef
SLSHWCaptureWindowListInRect(SLSConnectionID cid, const uint32_t *windows, int count, uint32_t options, CGRect rect)
{
    CFMutableArrayRef ids = CFArrayCreateMutable(kCFAllocatorDefault, 0, NULL);
    for (int i = 0; windows && i < count; i++)
        CFArrayAppendValue(ids, (const void *)(uintptr_t)windows[i]);
    CGImageRef image = window_list_image(rect, ids, kCGWindowImageDefault);
    CFRelease(ids);
    if (!image)
        return CFArrayCreate(kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks);
    CFArrayRef out = CFArrayCreate(kCFAllocatorDefault, (const void **)&image, 1, &kCFTypeArrayCallBacks);
    CGImageRelease(image);
    return out;
}

/* (Finch's displays are standard range: no headroom above reference white) */
EXPORT float SLSDisplayGetCurrentHeadroom(CGDirectDisplayID display) { return 1.0f; }

/* (no reference presets) */
EXPORT int SLSDisplayGetPresetCount(CGDirectDisplayID display) { return 0; }
