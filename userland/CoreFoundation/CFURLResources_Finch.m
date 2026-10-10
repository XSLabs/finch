/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * CFURL's resource properties and bookmarks (CFURL.h on macOS; swift-corelibs leaves
 * them out). Foundation's NSURL has them (NSURLResources.m, NSURLBookmarks.m), and a
 * CFURL is an NSURL, so these ask it, loading Foundation if the process hasn't. The keys
 * are the NSURL keys (NSConstants.aliases); these few are CF's own. And
 * CFURLEnumerator: a directory's contents (fts) or the mounted volumes (getfsstat).
 */
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <fts.h>
#include <stdlib.h>
#include <strings.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>

/* CFURLEnumerator.h's (macOS's; swift-corelibs has none) */
typedef const struct __CFURLEnumerator *CFURLEnumeratorRef;
typedef CF_OPTIONS(CFOptionFlags, CFURLEnumeratorOptions) {
    kCFURLEnumeratorDefaultBehavior = 0,
    kCFURLEnumeratorDescendRecursively = 1UL << 0,
    kCFURLEnumeratorSkipInvisibles = 1UL << 1,
    kCFURLEnumeratorGenerateFileReferenceURLs = 1UL << 2,
    kCFURLEnumeratorSkipPackageContents = 1UL << 3,
    kCFURLEnumeratorIncludeDirectoriesPreOrder = 1UL << 4,
    kCFURLEnumeratorIncludeDirectoriesPostOrder = 1UL << 5,
    kCFURLEnumeratorGenerateRelativePathURLs = 1UL << 6,
};
typedef CF_ENUM(CFIndex, CFURLEnumeratorResult) {
    kCFURLEnumeratorSuccess = 1,
    kCFURLEnumeratorEnd = 2,
    kCFURLEnumeratorError = 3,
    kCFURLEnumeratorDirectoryPostOrderSuccess = 4,
};

CF_EXPORT const CFStringRef kCFURLBookmarkFileProviderStringKey;
const CFStringRef kCFURLBookmarkFileProviderStringKey = CFSTR("NSURLBookmarkFileProviderStringKey");
CF_EXPORT const CFStringRef kCFURLBookmarkOriginalPathKey;
const CFStringRef kCFURLBookmarkOriginalPathKey = CFSTR("_NSURLPathKey");
CF_EXPORT const CFStringRef kCFURLBookmarkOriginalRelativePathComponentsArrayKey;
const CFStringRef kCFURLBookmarkOriginalRelativePathComponentsArrayKey = CFSTR("NSURLBookmarkOriginalRelativePathComponentsArrayKey");
CF_EXPORT const CFStringRef kCFURLBookmarkOriginalRelativePathKey;
const CFStringRef kCFURLBookmarkOriginalRelativePathKey = CFSTR("NSURLBookmarkOriginalRelativePathKey");
CF_EXPORT const CFStringRef kCFURLBookmarkOriginalVolumeCreationDateKey;
const CFStringRef kCFURLBookmarkOriginalVolumeCreationDateKey = CFSTR("NSURLBookmarkOriginalVolumeCreationDateKey");
CF_EXPORT const CFStringRef kCFURLBookmarkOriginalVolumeNameKey;
const CFStringRef kCFURLBookmarkOriginalVolumeNameKey = CFSTR("NSURLBookmarkOriginalVolumeNameKey");
CF_EXPORT const CFStringRef kCFURLCustomIconKey;
const CFStringRef kCFURLCustomIconKey = CFSTR("kCFURLCustomIconKey");
CF_EXPORT const CFStringRef kCFURLEffectiveIconKey;
const CFStringRef kCFURLEffectiveIconKey = CFSTR("kCFURLEffectiveIconKey");
CF_EXPORT const CFStringRef kCFURLIsApplicationKey;
const CFStringRef kCFURLIsApplicationKey = CFSTR("_NSURLIsApplicationKey");
CF_EXPORT const CFStringRef kCFURLLabelColorKey;
const CFStringRef kCFURLLabelColorKey = CFSTR("kCFURLLabelColorKey");
CF_EXPORT const CFStringRef kCFURLPathKey;
const CFStringRef kCFURLPathKey = CFSTR("_NSURLPathKey");

/* Foundation's NSURL category methods, there once Foundation is. */
static void
need_foundation(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      const char *fw = "/System/Library/Frameworks/Foundation.framework/Foundation";
      if (!dlopen(fw, RTLD_LAZY | RTLD_NOLOAD))
          dlopen(fw, RTLD_LAZY | RTLD_GLOBAL);
    });
}

#define SEND(type, ...) ((type(*)(id, SEL, ...))objc_msgSend)(__VA_ARGS__)

static id
url_class(void)
{
    need_foundation();
    return (id)objc_getClass("NSURL");
}

static void
give_error(CFErrorRef *error, id nserror)
{
    if (error)
        *error = nserror ? (CFErrorRef)CFRetain((CFTypeRef)nserror) : NULL;
}

Boolean
CFURLCopyResourcePropertyForKey(CFURLRef url, CFStringRef key, void *propertyValueTypeRefPtr, CFErrorRef *error)
{
    need_foundation();
    id value = nil, err = nil;
    BOOL ok = ((BOOL(*)(id, SEL, id *, id, id *))objc_msgSend)((id)url, sel_getUid("getResourceValue:forKey:error:"), &value,
                                                               (id)key, &err);
    if (propertyValueTypeRefPtr)
        *(CFTypeRef *)propertyValueTypeRefPtr = ok && value ? CFRetain((CFTypeRef)value) : NULL;
    give_error(error, ok ? nil : err);
    return ok;
}

CFDictionaryRef
CFURLCopyResourcePropertiesForKeys(CFURLRef url, CFArrayRef keys, CFErrorRef *error)
{
    need_foundation();
    id err = nil;
    id d = ((id(*)(id, SEL, id, id *))objc_msgSend)((id)url, sel_getUid("resourceValuesForKeys:error:"), (id)keys, &err);
    give_error(error, d ? nil : err);
    return d ? (CFDictionaryRef)CFRetain((CFTypeRef)d) : NULL;
}

Boolean
CFURLSetResourcePropertyForKey(CFURLRef url, CFStringRef key, CFTypeRef propertyValue, CFErrorRef *error)
{
    need_foundation();
    id err = nil;
    BOOL ok = ((BOOL(*)(id, SEL, id, id, id *))objc_msgSend)((id)url, sel_getUid("setResourceValue:forKey:error:"), (id)propertyValue,
                                                             (id)key, &err);
    give_error(error, ok ? nil : err);
    return ok;
}

Boolean
CFURLSetResourcePropertiesForKeys(CFURLRef url, CFDictionaryRef keyedPropertyValues, CFErrorRef *error)
{
    need_foundation();
    id err = nil;
    BOOL ok = ((BOOL(*)(id, SEL, id, id *))objc_msgSend)((id)url, sel_getUid("setResourceValues:error:"), (id)keyedPropertyValues, &err);
    give_error(error, ok ? nil : err);
    return ok;
}

/* (values aren't cached: each is read when asked for) */
void CFURLClearResourcePropertyCacheForKey(CFURLRef url, CFStringRef key) {}
void CFURLClearResourcePropertyCache(CFURLRef url) {}
void CFURLSetTemporaryResourcePropertyForKey(CFURLRef url, CFStringRef key, CFTypeRef propertyValue) {}

Boolean
CFURLResourceIsReachable(CFURLRef url, CFErrorRef *error)
{
    need_foundation();
    id err = nil;
    BOOL ok = ((BOOL(*)(id, SEL, id *))objc_msgSend)((id)url, sel_getUid("checkResourceIsReachableAndReturnError:"), &err);
    give_error(error, ok ? nil : err);
    return ok;
}

/* --- bookmarks --- */

CFDataRef
CFURLCreateBookmarkData(CFAllocatorRef allocator, CFURLRef url, CFURLBookmarkCreationOptions options,
                        CFArrayRef resourcePropertiesToInclude, CFURLRef relativeToURL, CFErrorRef *error)
{
    need_foundation();
    id err = nil;
    id d = ((id(*)(id, SEL, NSUInteger, id, id, id *))objc_msgSend)(
        (id)url, sel_getUid("bookmarkDataWithOptions:includingResourceValuesForKeys:relativeToURL:error:"), (NSUInteger)options,
        (id)resourcePropertiesToInclude, (id)relativeToURL, &err);
    give_error(error, d ? nil : err);
    return d ? (CFDataRef)CFRetain((CFTypeRef)d) : NULL;
}

CFURLRef
CFURLCreateByResolvingBookmarkData(CFAllocatorRef allocator, CFDataRef bookmark, CFURLBookmarkResolutionOptions options,
                                   CFURLRef relativeToURL, CFArrayRef resourcePropertiesToInclude, Boolean *isStale, CFErrorRef *error)
{
    id err = nil;
    BOOL stale = NO;
    id u = ((id(*)(id, SEL, id, NSUInteger, id, BOOL *, id *))objc_msgSend)(
        url_class(), sel_getUid("URLByResolvingBookmarkData:options:relativeToURL:bookmarkDataIsStale:error:"), (id)bookmark,
        (NSUInteger)options, (id)relativeToURL, &stale, &err);
    if (isStale)
        *isStale = stale;
    give_error(error, u ? nil : err);
    return u ? (CFURLRef)CFRetain((CFTypeRef)u) : NULL;
}

CFDictionaryRef
CFURLCreateResourcePropertiesForKeysFromBookmarkData(CFAllocatorRef allocator, CFArrayRef resourcePropertiesToReturn, CFDataRef bookmark)
{
    id d = ((id(*)(id, SEL, id, id))objc_msgSend)(url_class(), sel_getUid("resourceValuesForKeys:fromBookmarkData:"),
                                                 (id)resourcePropertiesToReturn, (id)bookmark);
    return d ? (CFDictionaryRef)CFRetain((CFTypeRef)d) : NULL;
}

CFTypeRef
CFURLCreateResourcePropertyForKeyFromBookmarkData(CFAllocatorRef allocator, CFStringRef resourcePropertyKey, CFDataRef bookmark)
{
    CFArrayRef keys = CFArrayCreate(NULL, (const void **)&resourcePropertyKey, 1, &kCFTypeArrayCallBacks);
    CFDictionaryRef d = CFURLCreateResourcePropertiesForKeysFromBookmarkData(allocator, keys, bookmark);
    CFRelease(keys);
    CFTypeRef v = d ? CFDictionaryGetValue(d, resourcePropertyKey) : NULL;
    if (v)
        CFRetain(v);
    if (d)
        CFRelease(d);
    return v;
}

CFDataRef
CFURLCreateBookmarkDataFromFile(CFAllocatorRef allocator, CFURLRef fileURL, CFErrorRef *errorRef)
{
    id err = nil;
    id d = ((id(*)(id, SEL, id, id *))objc_msgSend)(url_class(), sel_getUid("bookmarkDataWithContentsOfURL:error:"), (id)fileURL, &err);
    give_error(errorRef, d ? nil : err);
    return d ? (CFDataRef)CFRetain((CFTypeRef)d) : NULL;
}

Boolean
CFURLWriteBookmarkDataToFile(CFDataRef bookmarkRef, CFURLRef fileURL, CFURLBookmarkFileCreationOptions options, CFErrorRef *errorRef)
{
    id err = nil;
    BOOL ok = ((BOOL(*)(id, SEL, id, id, NSUInteger, id *))objc_msgSend)(
        url_class(), sel_getUid("writeBookmarkData:toURL:options:error:"), (id)bookmarkRef, (id)fileURL, (NSUInteger)options, &err);
    give_error(errorRef, ok ? nil : err);
    return ok;
}

/* Alias records are Carbon's: none are made. */
CFDataRef CFURLCreateBookmarkDataFromAliasRecord(CFAllocatorRef allocatorRef, CFDataRef aliasRecordDataRef) { return NULL; }

/* Security scope (sandboxed apps): Finch doesn't sandbox, so access is always there. */
Boolean CFURLStartAccessingSecurityScopedResource(CFURLRef url) { return url != NULL; }
void CFURLStopAccessingSecurityScopedResource(CFURLRef url) {}

/* (private) whether a URL is a file URL */
Boolean
CFURLIsFileURL(CFURLRef url)
{
    CFStringRef scheme = url ? CFURLCopyScheme(url) : NULL;
    Boolean file = scheme && CFStringCompare(scheme, CFSTR("file"), kCFCompareCaseInsensitive) == kCFCompareEqualTo;
    if (scheme)
        CFRelease(scheme);
    return file;
}

/* --- CFURLEnumerator --- */

typedef struct __CFURLEnumerator {
    CFRuntimeBase base;
    FTS *fts;                 /* a directory's */
    CFMutableArrayRef volumes; /* or the mounted volumes */
    CFIndex next;
    CFOptionFlags options;
    CFIndex level;
    FTSENT *current;
    CFMutableArrayRef handed; /* the URLs last handed out: theirs until the next call */
} Enumerator;

#include <CoreFoundation/CFRuntime.h>

static void
enumerator_finalize(CFTypeRef cf)
{
    Enumerator *e = (Enumerator *)cf;
    if (e->fts)
        fts_close(e->fts);
    if (e->volumes)
        CFRelease(e->volumes);
    if (e->handed)
        CFRelease(e->handed);
}

static const CFRuntimeClass enumerator_class = {0, "CFURLEnumerator", NULL, NULL, enumerator_finalize, NULL, NULL, NULL, NULL, NULL, NULL, 0};
static CFTypeID enumerator_type;

CFTypeID
CFURLEnumeratorGetTypeID(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      enumerator_type = _CFRuntimeRegisterClass(&enumerator_class);
    });
    return enumerator_type;
}

static Enumerator *
new_enumerator(CFAllocatorRef alloc, CFOptionFlags option)
{
    Enumerator *e = (Enumerator *)_CFRuntimeCreateInstance(alloc, CFURLEnumeratorGetTypeID(), sizeof(Enumerator) - sizeof(CFRuntimeBase), NULL);
    if (e) {
        e->options = option;
        e->handed = CFArrayCreateMutable(alloc, 0, &kCFTypeArrayCallBacks);
    }
    return e;
}

CFURLEnumeratorRef
CFURLEnumeratorCreateForDirectoryURL(CFAllocatorRef alloc, CFURLRef directoryURL, CFURLEnumeratorOptions option, CFArrayRef propertyKeys)
{
    char path[PATH_MAX];
    if (!directoryURL || !CFURLGetFileSystemRepresentation(directoryURL, true, (UInt8 *)path, sizeof path))
        return NULL;
    Enumerator *e = new_enumerator(alloc, option);
    if (!e)
        return NULL;
    char *paths[] = {path, NULL};
    e->fts = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
    if (e->fts) {
        FTSENT *root = fts_read(e->fts); /* the directory itself isn't one of its contents */
        if (!root || root->fts_info != FTS_D) {
            fts_close(e->fts);
            e->fts = NULL;
        }
    }
    return (CFURLEnumeratorRef)e;
}

CFURLEnumeratorRef
CFURLEnumeratorCreateForMountedVolumes(CFAllocatorRef alloc, CFURLEnumeratorOptions option, CFArrayRef propertyKeys)
{
    Enumerator *e = new_enumerator(alloc, option);
    if (!e)
        return NULL;
    e->volumes = CFArrayCreateMutable(alloc, 0, &kCFTypeArrayCallBacks);
    int n = getfsstat(NULL, 0, MNT_NOWAIT);
    struct statfs *fs = n > 0 ? calloc((size_t)n, sizeof *fs) : NULL;
    if (fs)
        n = getfsstat(fs, (int)(n * sizeof *fs), MNT_NOWAIT);
    for (int i = 0; fs && i < n; i++) {
        /* (the user's volumes: those not marked to be left out of browsing) */
        if ((fs[i].f_flags & MNT_DONTBROWSE) && (option & kCFURLEnumeratorSkipInvisibles) && strcmp(fs[i].f_mntonname, "/"))
            continue;
        CFURLRef u = CFURLCreateFromFileSystemRepresentation(alloc, (const UInt8 *)fs[i].f_mntonname, (CFIndex)strlen(fs[i].f_mntonname), true);
        if (u) {
            CFArrayAppendValue(e->volumes, u);
            CFRelease(u);
        }
    }
    free(fs);
    return (CFURLEnumeratorRef)e;
}

static CFURLEnumeratorResult
next_url(Enumerator *e, CFURLRef *url, CFErrorRef *error)
{
    if (url)
        *url = NULL;
    if (error)
        *error = NULL;
    if (e->volumes) {
        if (e->next >= CFArrayGetCount(e->volumes))
            return kCFURLEnumeratorEnd;
        if (url)
            *url = CFArrayGetValueAtIndex(e->volumes, e->next);
        e->next++;
        return kCFURLEnumeratorSuccess;
    }
    if (!e->fts)
        return kCFURLEnumeratorEnd;
    for (;;) {
        FTSENT *f = fts_read(e->fts);
        if (!f)
            return kCFURLEnumeratorEnd;
        if (f->fts_level == 0)
            continue;
        BOOL post = f->fts_info == FTS_DP;
        if (post && !(e->options & kCFURLEnumeratorIncludeDirectoriesPostOrder))
            continue;
        /* (invisible: a dot name, or the hidden flag) */
        if (!post && (e->options & kCFURLEnumeratorSkipInvisibles) &&
            (f->fts_name[0] == '.' || (f->fts_statp && (f->fts_statp->st_flags & UF_HIDDEN)))) {
            if (f->fts_info == FTS_D)
                fts_set(e->fts, f, FTS_SKIP);
            continue;
        }
        if (f->fts_info == FTS_D && !(e->options & kCFURLEnumeratorDescendRecursively))
            fts_set(e->fts, f, FTS_SKIP);
        if (f->fts_info == FTS_D && (e->options & kCFURLEnumeratorSkipPackageContents)) {
            /* (a package: a directory with a bundle's extension) */
            const char *dot = strrchr(f->fts_name, '.');
            static const char *const packages[] = {".app", ".bundle", ".framework", ".plugin", ".kext", ".pkg", ".rtfd", ".xcodeproj", NULL};
            for (int k = 0; dot && packages[k]; k++)
                if (!strcasecmp(dot, packages[k]))
                    fts_set(e->fts, f, FTS_SKIP);
        }
        e->current = f;
        e->level = f->fts_level;
        /* a directory comes before its contents unless asked for after them (and not before) */
        if (f->fts_info == FTS_D && (e->options & kCFURLEnumeratorIncludeDirectoriesPostOrder) &&
            !(e->options & kCFURLEnumeratorIncludeDirectoriesPreOrder))
            continue;
        CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)f->fts_path, (CFIndex)f->fts_pathlen,
                                                            f->fts_info == FTS_D);
        if (!u)
            continue;
        CFArrayAppendValue(e->handed, u);
        CFRelease(u);
        if (url)
            *url = u;
        return post ? kCFURLEnumeratorDirectoryPostOrderSuccess : kCFURLEnumeratorSuccess;
    }
}

CFURLEnumeratorResult
CFURLEnumeratorGetNextURL(CFURLEnumeratorRef enumerator, CFURLRef *url, CFErrorRef *error)
{
    Enumerator *e = (Enumerator *)enumerator;
    CFArrayRemoveAllValues(e->handed);
    return next_url(e, url, error);
}

/* (private) several at once */
CFIndex
CFURLEnumeratorGetURLsBulk(CFURLEnumeratorRef enumerator, CFIndex maxURLs, CFURLRef *urls, CFErrorRef *error)
{
    Enumerator *e = (Enumerator *)enumerator;
    CFArrayRemoveAllValues(e->handed);
    CFIndex n = 0;
    while (n < maxURLs && next_url(e, &urls[n], error) == kCFURLEnumeratorSuccess)
        n++;
    return n;
}

void
CFURLEnumeratorSkipDescendents(CFURLEnumeratorRef enumerator)
{
    Enumerator *e = (Enumerator *)enumerator;
    if (e->fts && e->current && e->current->fts_info == FTS_D)
        fts_set(e->fts, e->current, FTS_SKIP);
}

CFIndex CFURLEnumeratorGetDescendentLevel(CFURLEnumeratorRef enumerator) { return ((Enumerator *)enumerator)->level; }
Boolean CFURLEnumeratorGetSourceDidChange(CFURLEnumeratorRef enumerator) { return false; }
