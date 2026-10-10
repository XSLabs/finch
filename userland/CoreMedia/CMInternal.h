/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* CoreMedia, Finch's: what its files share. */
#ifndef FINCH_CM_INTERNAL_H
#define FINCH_CM_INTERNAL_H
#include <CoreMedia/CoreMedia.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

/* CoreFoundation's runtime, as Finch's frameworks register their CF types. */
typedef struct {
    uintptr_t isa;
    _Atomic(uint64_t) info;
} CFRuntimeBase;
typedef struct {
    CFIndex version;
    const char *className;
    void (*init)(CFTypeRef);
    CFTypeRef (*copy)(CFAllocatorRef, CFTypeRef);
    void (*finalize)(CFTypeRef);
    Boolean (*equal)(CFTypeRef, CFTypeRef);
    CFHashCode (*hash)(CFTypeRef);
    CFStringRef (*copyFormattingDesc)(CFTypeRef, CFDictionaryRef);
    CFStringRef (*copyDebugDesc)(CFTypeRef);
    void (*reclaim)(CFTypeRef);
    uint32_t (*refcount)(intptr_t, CFTypeRef);
    uintptr_t requiredAlignment;
} CFRuntimeClass;
extern CFTypeID _CFRuntimeRegisterClass(const CFRuntimeClass *cls);
extern CFTypeRef _CFRuntimeCreateInstance(CFAllocatorRef allocator, CFTypeID typeID, CFIndex extraBytes, unsigned char *category);

/* A CF type's ID, registered once. */
#define CM_DEFINE_TYPE(func, name, finalize, equal, hash, desc)                                                    \
    static CFTypeID func##_id;                                                                                    \
    static const CFRuntimeClass func##_cls = {0, name, NULL, NULL, finalize, equal, hash, NULL, desc, NULL, NULL, 0}; \
    static void func##_reg(void) { func##_id = _CFRuntimeRegisterClass(&func##_cls); }                            \
    CFTypeID func(void)                                                                                           \
    {                                                                                                             \
        static pthread_once_t once = PTHREAD_ONCE_INIT;                                                           \
        pthread_once(&once, func##_reg);                                                                          \
        return func##_id;                                                                                         \
    }

/* A message logged as Apple's CoreMedia logs its warnings (NSLog's format, to stderr). */
extern void NSLog(const void *format, ...);
static inline void __attribute__((format(printf, 1, 2)))
cm_log(const char *format, ...)
{
    char *m = NULL;
    va_list ap;
    va_start(ap, format);
    vasprintf(&m, format, ap);
    va_end(ap);
    NSLog(CFSTR("%s"), m);
    free(m);
}

static inline CFTypeRef
cm_create(CFAllocatorRef allocator, CFTypeID type, size_t size)
{
    return _CFRuntimeCreateInstance(allocator, type, (CFIndex)(size - sizeof(CFRuntimeBase)), NULL);
}

/* A sample buffer's attachments (both modes) and their lock; false for anything else. */
bool _FinchCMSampleBufferAttachments(CFTypeRef target, CFMutableDictionaryRef **attachments, pthread_mutex_t **lock);

#endif
