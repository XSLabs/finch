/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CoreVideo's buffers, Finch's: attachments in two modes (a key set in one leaves
 * the other), propagated from one buffer to another; and the geometry of image
 * buffers (encoded and display sizes, the clean aperture) from their attachments,
 * as Apple's computes it.
 */
#include "CVInternal.h"

void
_FinchCVBufferInit(FinchCVBuffer *b)
{
    pthread_mutex_init(&b->attachmentLock, NULL);
    for (int i = 0; i < 2; i++)
        b->attachments[i] = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

void
_FinchCVBufferFinalize(FinchCVBuffer *b)
{
    for (int i = 0; i < 2; i++)
        if (b->attachments[i])
            CFRelease(b->attachments[i]);
    pthread_mutex_destroy(&b->attachmentLock);
}

CVBufferRef
CVBufferRetain(CVBufferRef buffer)
{
    return buffer ? (CVBufferRef)CFRetain(buffer) : NULL;
}

void
CVBufferRelease(CVBufferRef buffer)
{
    if (buffer)
        CFRelease(buffer);
}

static FinchCVBuffer *
as_buffer(CVBufferRef buffer)
{
    return buffer && _FinchCVIsBuffer(buffer) ? (FinchCVBuffer *)buffer : NULL;
}

static int
mode_index(CVAttachmentMode mode)
{
    return mode == kCVAttachmentMode_ShouldPropagate ? 1 : 0;
}

void
CVBufferSetAttachment(CVBufferRef buffer, CFStringRef key, CFTypeRef value, CVAttachmentMode attachmentMode)
{
    FinchCVBuffer *b = as_buffer(buffer);
    if (!b || !key || !value)
        return;
    int i = mode_index(attachmentMode);
    pthread_mutex_lock(&b->attachmentLock);
    CFDictionaryRemoveValue(b->attachments[!i], key);
    CFDictionarySetValue(b->attachments[i], key, value);
    pthread_mutex_unlock(&b->attachmentLock);
}

static CFTypeRef
copy_attachment(CVBufferRef buffer, CFStringRef key, CVAttachmentMode *attachmentMode)
{
    FinchCVBuffer *b = as_buffer(buffer);
    if (!b || !key)
        return NULL;
    CFTypeRef v = NULL;
    pthread_mutex_lock(&b->attachmentLock);
    for (int i = 0; i < 2 && !v; i++)
        if ((v = CFDictionaryGetValue(b->attachments[i], key))) {
            CFRetain(v);
            if (attachmentMode)
                *attachmentMode = i ? kCVAttachmentMode_ShouldPropagate : kCVAttachmentMode_ShouldNotPropagate;
        }
    pthread_mutex_unlock(&b->attachmentLock);
    return v;
}

CFTypeRef
CVBufferCopyAttachment(CVBufferRef buffer, CFStringRef key, CVAttachmentMode *attachmentMode)
{
    return copy_attachment(buffer, key, attachmentMode);
}

CFTypeRef
CVBufferGetAttachment(CVBufferRef buffer, CFStringRef key, CVAttachmentMode *attachmentMode)
{
    /* (not retained: the buffer still holds it, as Apple's deprecated call assumes) */
    CFTypeRef v = copy_attachment(buffer, key, attachmentMode);
    if (v)
        CFRelease(v);
    return v;
}

Boolean
CVBufferHasAttachment(CVBufferRef buffer, CFStringRef key)
{
    CFTypeRef v = copy_attachment(buffer, key, NULL);
    if (v)
        CFRelease(v);
    return v != NULL;
}

void
CVBufferRemoveAttachment(CVBufferRef buffer, CFStringRef key)
{
    FinchCVBuffer *b = as_buffer(buffer);
    if (!b || !key)
        return;
    pthread_mutex_lock(&b->attachmentLock);
    for (int i = 0; i < 2; i++)
        CFDictionaryRemoveValue(b->attachments[i], key);
    pthread_mutex_unlock(&b->attachmentLock);
}

void
CVBufferRemoveAllAttachments(CVBufferRef buffer)
{
    FinchCVBuffer *b = as_buffer(buffer);
    if (!b)
        return;
    pthread_mutex_lock(&b->attachmentLock);
    for (int i = 0; i < 2; i++)
        CFDictionaryRemoveAllValues(b->attachments[i]);
    pthread_mutex_unlock(&b->attachmentLock);
}

CFDictionaryRef
CVBufferCopyAttachments(CVBufferRef buffer, CVAttachmentMode attachmentMode)
{
    FinchCVBuffer *b = as_buffer(buffer);
    if (!b)
        return NULL;
    pthread_mutex_lock(&b->attachmentLock);
    CFDictionaryRef d = CFDictionaryCreateCopy(NULL, b->attachments[mode_index(attachmentMode)]);
    pthread_mutex_unlock(&b->attachmentLock);
    return d;
}

CFDictionaryRef
CVBufferGetAttachments(CVBufferRef buffer, CVAttachmentMode attachmentMode)
{
    FinchCVBuffer *b = as_buffer(buffer);
    return b ? b->attachments[mode_index(attachmentMode)] : NULL;
}

static void
set_each(const void *key, const void *value, void *context)
{
    void **args = context;
    CVBufferSetAttachment(args[0], key, value, (CVAttachmentMode)(uintptr_t)args[1]);
}

void
CVBufferSetAttachments(CVBufferRef buffer, CFDictionaryRef theAttachments, CVAttachmentMode attachmentMode)
{
    if (!as_buffer(buffer) || !theAttachments)
        return;
    void *args[] = {(void *)buffer, (void *)(uintptr_t)attachmentMode};
    CFDictionaryApplyFunction(theAttachments, set_each, args);
}

void
CVBufferPropagateAttachments(CVBufferRef sourceBuffer, CVBufferRef destinationBuffer)
{
    CFDictionaryRef d = CVBufferCopyAttachments(sourceBuffer, kCVAttachmentMode_ShouldPropagate);
    if (!d)
        return;
    CVBufferSetAttachments(destinationBuffer, d, kCVAttachmentMode_ShouldPropagate);
    CFRelease(d);
}

/* --- image buffers --- */

static bool
number(CFDictionaryRef d, CFStringRef key, double *out)
{
    CFTypeRef v = d && CFGetTypeID(d) == CFDictionaryGetTypeID() ? CFDictionaryGetValue(d, key) : NULL;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID())
        return CFNumberGetValue(v, kCFNumberDoubleType, out);
    if (v && CFGetTypeID(v) == CFArrayGetTypeID() && CFArrayGetCount(v) == 2) {
        double n, dn;
        CFTypeRef a = CFArrayGetValueAtIndex(v, 0), b = CFArrayGetValueAtIndex(v, 1);
        if (CFGetTypeID(a) == CFNumberGetTypeID() && CFGetTypeID(b) == CFNumberGetTypeID() && CFNumberGetValue(a, kCFNumberDoubleType, &n) &&
            CFNumberGetValue(b, kCFNumberDoubleType, &dn) && dn) {
            *out = n / dn;
            return true;
        }
    }
    return false;
}

CGSize
CVImageBufferGetEncodedSize(CVImageBufferRef imageBuffer)
{
    size_t w, h;
    if (!_FinchCVPixelBufferGetSize(imageBuffer, &w, &h))
        return CGSizeZero;
    return CGSizeMake(w, h);
}

CGRect
CVImageBufferGetCleanRect(CVImageBufferRef imageBuffer)
{
    CGSize size = CVImageBufferGetEncodedSize(imageBuffer);
    CGRect r = {CGPointZero, size};
    CFDictionaryRef ca = CVBufferCopyAttachment(imageBuffer, kCVImageBufferCleanApertureKey, NULL);
    double w, h, x = 0, y = 0;
    if (ca && number(ca, kCVImageBufferCleanApertureWidthKey, &w) && number(ca, kCVImageBufferCleanApertureHeightKey, &h)) {
        number(ca, kCVImageBufferCleanApertureHorizontalOffsetKey, &x);
        number(ca, kCVImageBufferCleanApertureVerticalOffsetKey, &y);
        r = CGRectMake((size.width - w) / 2 + x, (size.height - h) / 2 - y, w, h);
    }
    if (ca)
        CFRelease(ca);
    return r;
}

CGSize
CVImageBufferGetDisplaySize(CVImageBufferRef imageBuffer)
{
    CGSize s = CVImageBufferGetCleanRect(imageBuffer).size;
    CFDictionaryRef par = CVBufferCopyAttachment(imageBuffer, kCVImageBufferPixelAspectRatioKey, NULL);
    double hs, vs;
    if (par && number(par, kCVImageBufferPixelAspectRatioHorizontalSpacingKey, &hs) &&
        number(par, kCVImageBufferPixelAspectRatioVerticalSpacingKey, &vs) && hs > 0 && vs > 0)
        s.width = s.width * hs / vs;
    if (par)
        CFRelease(par);
    return s;
}

Boolean
CVImageBufferIsFlipped(CVImageBufferRef imageBuffer)
{
    return true;
}
