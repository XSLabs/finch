/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CoreMedia's attachments, Finch's: on sample buffers (their own two dictionaries, made
 * when first needed and dropped when all are removed, so a copy is NULL until then) and
 * on CoreVideo's buffers (CoreVideo's attachments, so either framework sees them);
 * anything else bears none.
 */
#include "CMInternal.h"
#include <CoreVideo/CoreVideo.h>

static bool
is_cv(CMAttachmentBearerRef target)
{
    return target && CFGetTypeID(target) == CVPixelBufferGetTypeID();
}

void
CMSetAttachment(CMAttachmentBearerRef target, CFStringRef key, CFTypeRef value, CMAttachmentMode attachmentMode)
{
    if (!target || !key || !value)
        return;
    if (is_cv(target)) {
        CVBufferSetAttachment((CVBufferRef)target, key, value, attachmentMode);
        return;
    }
    CFMutableDictionaryRef *a;
    pthread_mutex_t *lock;
    if (!_FinchCMSampleBufferAttachments(target, &a, &lock))
        return;
    int i = attachmentMode == kCMAttachmentMode_ShouldPropagate;
    pthread_mutex_lock(lock);
    if (a[!i])
        CFDictionaryRemoveValue(a[!i], key);
    if (!a[i])
        a[i] = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(a[i], key, value);
    pthread_mutex_unlock(lock);
}

CFTypeRef
CMGetAttachment(CMAttachmentBearerRef target, CFStringRef key, CMAttachmentMode *attachmentModeOut)
{
    if (!target || !key)
        return NULL;
    if (is_cv(target))
        return CVBufferGetAttachment((CVBufferRef)target, key, attachmentModeOut);
    CFMutableDictionaryRef *a;
    pthread_mutex_t *lock;
    if (!_FinchCMSampleBufferAttachments(target, &a, &lock))
        return NULL;
    CFTypeRef v = NULL;
    pthread_mutex_lock(lock);
    for (int i = 0; i < 2 && !v; i++)
        if (a[i] && (v = CFDictionaryGetValue(a[i], key)) && attachmentModeOut)
            *attachmentModeOut = i ? kCMAttachmentMode_ShouldPropagate : kCMAttachmentMode_ShouldNotPropagate;
    pthread_mutex_unlock(lock);
    return v;
}

void
CMRemoveAttachment(CMAttachmentBearerRef target, CFStringRef key)
{
    if (!target || !key)
        return;
    if (is_cv(target)) {
        CVBufferRemoveAttachment((CVBufferRef)target, key);
        return;
    }
    CFMutableDictionaryRef *a;
    pthread_mutex_t *lock;
    if (!_FinchCMSampleBufferAttachments(target, &a, &lock))
        return;
    pthread_mutex_lock(lock);
    for (int i = 0; i < 2; i++)
        if (a[i])
            CFDictionaryRemoveValue(a[i], key);
    pthread_mutex_unlock(lock);
}

void
CMRemoveAllAttachments(CMAttachmentBearerRef target)
{
    if (!target)
        return;
    if (is_cv(target)) {
        CVBufferRemoveAllAttachments((CVBufferRef)target);
        return;
    }
    CFMutableDictionaryRef *a;
    pthread_mutex_t *lock;
    if (!_FinchCMSampleBufferAttachments(target, &a, &lock))
        return;
    pthread_mutex_lock(lock);
    for (int i = 0; i < 2; i++)
        if (a[i]) {
            CFRelease(a[i]);
            a[i] = NULL;
        }
    pthread_mutex_unlock(lock);
}

/* (a copy of a mode's attachments; NULL until there have been some) */
CFDictionaryRef
CMCopyDictionaryOfAttachments(CFAllocatorRef allocator, CMAttachmentBearerRef target, CMAttachmentMode attachmentMode)
{
    if (!target)
        return NULL;
    if (is_cv(target))
        return CVBufferCopyAttachments((CVBufferRef)target, attachmentMode);
    CFMutableDictionaryRef *a;
    pthread_mutex_t *lock;
    if (!_FinchCMSampleBufferAttachments(target, &a, &lock))
        return NULL;
    pthread_mutex_lock(lock);
    CFMutableDictionaryRef m = a[attachmentMode == kCMAttachmentMode_ShouldPropagate];
    CFDictionaryRef d = m ? CFDictionaryCreateCopy(allocator, m) : NULL;
    pthread_mutex_unlock(lock);
    return d;
}

static void
set_each(const void *key, const void *value, void *context)
{
    void **args = context;
    CMSetAttachment(args[0], key, value, (CMAttachmentMode)(uintptr_t)args[1]);
}

void
CMSetAttachments(CMAttachmentBearerRef target, CFDictionaryRef theAttachments, CMAttachmentMode attachmentMode)
{
    if (!target || !theAttachments)
        return;
    void *args[] = {(void *)target, (void *)(uintptr_t)attachmentMode};
    CFDictionaryApplyFunction(theAttachments, set_each, args);
}

void
CMPropagateAttachments(CMAttachmentBearerRef source, CMAttachmentBearerRef destination)
{
    CFDictionaryRef d = CMCopyDictionaryOfAttachments(NULL, source, kCMAttachmentMode_ShouldPropagate);
    if (!d)
        return;
    CMSetAttachments(destination, d, kCMAttachmentMode_ShouldPropagate);
    CFRelease(d);
}
