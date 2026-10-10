/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CoreVideo's pixel format descriptions, Finch's: the table of formats (CVPixelFormats.c,
 * with Apple's values) read once, and the formats apps register beside them.
 */
#include "CVInternal.h"

extern const unsigned char _FinchCVPixelFormats[];
extern const size_t _FinchCVPixelFormatsSize;

static CFMutableDictionaryRef formats; /* format number -> description */
static CFMutableArrayRef order;        /* the format numbers, in the table's order */
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

/* The fill callback the descriptions carry, where Apple's do: Finch's own. */
static Boolean
fill(CVPixelBufferRef pixelBuffer, void *refCon)
{
    return CVPixelBufferFillExtendedPixels(pixelBuffer) == kCVReturnSuccess;
}

static void
load(void)
{
    CVFillExtendedPixelsCallBackData callback = {0, fill, NULL};
    CFDataRef callbackData = CFDataCreate(NULL, (const UInt8 *)&callback, sizeof callback);
    formats = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    order = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFDataRef data = CFDataCreateWithBytesNoCopy(NULL, _FinchCVPixelFormats, (CFIndex)_FinchCVPixelFormatsSize, kCFAllocatorNull);
    CFArrayRef all = CFPropertyListCreateWithData(NULL, data, kCFPropertyListImmutable, NULL, NULL);
    CFRelease(data);
    for (CFIndex i = 0; all && i < CFArrayGetCount(all); i++) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(all, i);
        CFNumberRef f = CFDictionaryGetValue(d, kCVPixelFormatConstant);
        if (f && !CFDictionaryContainsKey(formats, f)) {
            if (CFDictionaryContainsKey(d, kCVPixelFormatFillExtendedPixelsCallback)) {
                CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(NULL, 0, d);
                CFDictionarySetValue(m, kCVPixelFormatFillExtendedPixelsCallback, callbackData);
                CFDictionarySetValue(formats, f, m);
                CFRelease(m);
            } else
                CFDictionarySetValue(formats, f, d);
            CFArrayAppendValue(order, f);
        }
    }
    CFRelease(callbackData);
    if (all)
        CFRelease(all);
}

static void
ensure(void)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, load);
}

CFDictionaryRef
_FinchCVCopyPixelFormatDescription(OSType format)
{
    ensure();
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt32Type, &format);
    pthread_mutex_lock(&lock);
    CFDictionaryRef d = CFDictionaryGetValue(formats, n);
    if (d)
        CFRetain(d);
    pthread_mutex_unlock(&lock);
    CFRelease(n);
    return d;
}

CFDictionaryRef
CVPixelFormatDescriptionCreateWithPixelFormatType(CFAllocatorRef allocator, OSType pixelFormat)
{
    return _FinchCVCopyPixelFormatDescription(pixelFormat);
}

CFArrayRef
CVPixelFormatDescriptionArrayCreateWithAllPixelFormatTypes(CFAllocatorRef allocator)
{
    ensure();
    pthread_mutex_lock(&lock);
    CFArrayRef a = CFArrayCreateCopy(allocator, order);
    pthread_mutex_unlock(&lock);
    return a;
}

void
CVPixelFormatDescriptionRegisterDescriptionWithPixelFormatType(CFDictionaryRef description, OSType pixelFormat)
{
    if (!description)
        return;
    ensure();
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt32Type, &pixelFormat);
    CFDictionaryRef d = CFDictionaryCreateCopy(NULL, description);
    pthread_mutex_lock(&lock);
    if (!CFDictionaryContainsKey(formats, n))
        CFArrayAppendValue(order, n);
    CFDictionarySetValue(formats, n, d);
    pthread_mutex_unlock(&lock);
    CFRelease(d);
    CFRelease(n);
}

Boolean
CVIsCompressedPixelFormatAvailable(OSType pixelFormatType)
{
    CFDictionaryRef d = _FinchCVCopyPixelFormatDescription(pixelFormatType);
    if (d)
        CFRelease(d);
    return d != NULL;
}
