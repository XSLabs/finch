/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-cfurl-test: CFURL's resource properties, bookmarks and enumerators, run against
 * Apple's CoreFoundation and Finch's to compare (tools/host-tests.sh), on a folder of
 * files it makes: names, kinds, sizes, hidden files and packages; setting a property; a
 * bookmark out and back; directory enumeration in each mode; the mounted volumes.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static char root[PATH_MAX];

static void
print_value(CFTypeRef v)
{
    if (!v) {
        printf("(none)");
        return;
    }
    CFTypeID t = CFGetTypeID(v);
    char buf[512];
    if (t == CFStringGetTypeID()) {
        CFStringGetCString(v, buf, sizeof buf, kCFStringEncodingUTF8);
        printf("'%s'", buf);
    } else if (t == CFBooleanGetTypeID()) {
        printf("%s", CFBooleanGetValue(v) ? "true" : "false");
    } else if (t == CFNumberGetTypeID()) {
        long long n = 0;
        CFNumberGetValue(v, kCFNumberLongLongType, &n);
        printf("%lld", n);
    } else if (t == CFURLGetTypeID()) {
        CFStringRef s = CFURLCopyFileSystemPath(v, kCFURLPOSIXPathStyle);
        CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8);
        CFRelease(s);
        printf("<%s>", strncmp(buf, root, strlen(root)) ? buf : buf + strlen(root));
    } else if (t == CFDateGetTypeID()) {
        printf("(date)");
    } else {
        printf("(type %lu)", (unsigned long)t);
    }
}

static CFComparisonResult
compare_strings(const void *a, const void *b, void *context)
{
    return CFStringCompare(a, b, 0);
}

static CFURLRef
url(const char *rel, Boolean dir)
{
    char p[PATH_MAX];
    snprintf(p, sizeof p, "%s/%s", root, rel);
    return CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)p, (CFIndex)strlen(p), dir);
}

static void
props(const char *rel, Boolean dir)
{
    CFURLRef u = url(rel, dir);
    const CFStringRef keys[] = {kCFURLNameKey, kCFURLIsDirectoryKey, kCFURLIsRegularFileKey, kCFURLIsHiddenKey, kCFURLIsPackageKey,
                                kCFURLFileSizeKey, kCFURLIsSymbolicLinkKey, kCFURLIsAliasFileKey, kCFURLTypeIdentifierKey,
                                kCFURLParentDirectoryURLKey, kCFURLIsReadableKey, kCFURLVolumeURLKey};
    printf("%s:", rel);
    for (size_t i = 0; i < sizeof keys / sizeof keys[0]; i++) {
        CFTypeRef v = NULL;
        CFErrorRef err = NULL;
        Boolean ok = CFURLCopyResourcePropertyForKey(u, keys[i], &v, &err);
        printf(" ");
        if (!ok)
            printf("error %ld", (long)(err ? CFErrorGetCode(err) : 0));
        else
            print_value(v);
        if (v)
            CFRelease(v);
        if (err)
            CFRelease(err);
    }
    printf("\n");
    CFRelease(u);
}

static void
enumerate(const char *title, CFOptionFlags options)
{
    CFURLRef dir = url("", true);
    CFURLEnumeratorRef e = CFURLEnumeratorCreateForDirectoryURL(NULL, dir, options, NULL);
    CFMutableArrayRef found = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFURLRef u;
    CFURLEnumeratorResult r;
    while ((r = CFURLEnumeratorGetNextURL(e, &u, NULL)) != kCFURLEnumeratorEnd) {
        if (r == kCFURLEnumeratorError)
            continue;
        CFStringRef path = CFURLCopyFileSystemPath(u, kCFURLPOSIXPathStyle);
        CFStringRef item = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@%s@%ld"), path,
                                                    r == kCFURLEnumeratorDirectoryPostOrderSuccess ? " (after)" : "",
                                                    (long)CFURLEnumeratorGetDescendentLevel(e));
        CFArrayAppendValue(found, item);
        CFRelease(item);
        CFRelease(path);
    }
    /* (in the order seen for post-order; sorted otherwise: directory order is the file system's) */
    if (!(options & kCFURLEnumeratorIncludeDirectoriesPostOrder))
        CFArraySortValues(found, CFRangeMake(0, CFArrayGetCount(found)), compare_strings, NULL);
    printf("%s:", title);
    for (CFIndex i = 0; i < CFArrayGetCount(found); i++) {
        char buf[PATH_MAX];
        CFStringGetCString(CFArrayGetValueAtIndex(found, i), buf, sizeof buf, kCFStringEncodingUTF8);
        printf(" %s", buf + strlen(root));
    }
    printf("\n");
    CFRelease(found);
    CFRelease(e);
    CFRelease(dir);
}

int
main(void)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    Dl_info info;
    dladdr((void *)CFURLCopyResourcePropertyForKey, &info);
    printf("%s\n", info.dli_fname);
    char tmpl[] = "/tmp/finch-cfurl.XXXXXX";
    realpath(mkdtemp(tmpl), root);
    char p[PATH_MAX];
    snprintf(p, sizeof p, "%s/a.txt", root);
    FILE *f = fopen(p, "w");
    fputs("hello", f);
    fclose(f);
    snprintf(p, sizeof p, "%s/.hidden", root);
    close(open(p, O_CREAT | O_WRONLY, 0644));
    snprintf(p, sizeof p, "%s/sub", root);
    mkdir(p, 0755);
    snprintf(p, sizeof p, "%s/sub/b.dat", root);
    close(open(p, O_CREAT | O_WRONLY, 0644));
    snprintf(p, sizeof p, "%s/Thing.app", root);
    mkdir(p, 0755);
    snprintf(p, sizeof p, "%s/Thing.app/Contents", root);
    mkdir(p, 0755);
    snprintf(p, sizeof p, "%s/link", root);
    symlink("a.txt", p);

    props("a.txt", false);
    props(".hidden", false);
    props("sub", true);
    props("Thing.app", true);
    props("link", false);
    props("missing", false);

    CFURLRef a = url("a.txt", false);
    CFArrayRef keys = CFArrayCreate(NULL, (const void *[]){kCFURLNameKey, kCFURLFileSizeKey, kCFURLIsDirectoryKey}, 3,
                                    &kCFTypeArrayCallBacks);
    CFDictionaryRef d = CFURLCopyResourcePropertiesForKeys(a, keys, NULL);
    printf("several: %ld values, size ", (long)CFDictionaryGetCount(d));
    print_value(CFDictionaryGetValue(d, kCFURLFileSizeKey));
    printf("\n");
    CFRelease(d);
    CFErrorRef err = NULL;
    Boolean ok = CFURLSetResourcePropertyForKey(a, kCFURLIsHiddenKey, kCFBooleanTrue, &err);
    CFURLClearResourcePropertyCache(a);
    CFTypeRef hidden = NULL;
    CFURLCopyResourcePropertyForKey(a, kCFURLIsHiddenKey, &hidden, NULL);
    printf("set hidden %d: now ", ok);
    print_value(hidden);
    printf("\n");
    printf("reachable: %d", CFURLResourceIsReachable(a, NULL));
    CFURLRef missing = url("missing", false);
    printf(", missing %d\n", CFURLResourceIsReachable(missing, NULL));

    CFDataRef bookmark = CFURLCreateBookmarkData(NULL, a, 0, keys, NULL, &err);
    Boolean stale = true;
    CFURLRef back = bookmark ? CFURLCreateByResolvingBookmarkData(NULL, bookmark, 0, NULL, NULL, &stale, NULL) : NULL;
    printf("bookmark: made %d, resolved ", bookmark != NULL);
    print_value(back);
    printf(" stale %d, name from data ", stale);
    CFTypeRef name = bookmark ? CFURLCreateResourcePropertyForKeyFromBookmarkData(NULL, kCFURLNameKey, bookmark) : NULL;
    print_value(name);
    printf("\n");

    enumerate("default", kCFURLEnumeratorDefaultBehavior);
    enumerate("skip invisibles", kCFURLEnumeratorSkipInvisibles);
    enumerate("recursive", kCFURLEnumeratorDescendRecursively);
    enumerate("recursive, skip packages", kCFURLEnumeratorDescendRecursively | kCFURLEnumeratorSkipPackageContents);
    enumerate("recursive, post order", kCFURLEnumeratorDescendRecursively | kCFURLEnumeratorIncludeDirectoriesPostOrder |
                                           kCFURLEnumeratorSkipInvisibles);

    CFURLEnumeratorRef vols = CFURLEnumeratorCreateForMountedVolumes(NULL, kCFURLEnumeratorSkipInvisibles, NULL);
    CFURLRef v;
    int count = 0, rootSeen = 0;
    while (CFURLEnumeratorGetNextURL(vols, &v, NULL) == kCFURLEnumeratorSuccess) {
        count++;
        CFStringRef path = CFURLCopyFileSystemPath(v, kCFURLPOSIXPathStyle);
        rootSeen |= CFStringCompare(path, CFSTR("/"), 0) == kCFCompareEqualTo;
        CFRelease(path);
    }
    printf("volumes: some %d, root %d\n", count > 0, rootSeen);
    CFRelease(vols);
    CFTypeRef cap = NULL;
    CFURLRef slash = CFURLCreateWithFileSystemPath(NULL, CFSTR("/"), kCFURLPOSIXPathStyle, true);
    printf("root volume: capacity %d", CFURLCopyResourcePropertyForKey(slash, kCFURLVolumeTotalCapacityKey, &cap, NULL) && cap);
    CFTypeRef vname = NULL;
    CFURLCopyResourcePropertyForKey(slash, kCFURLVolumeURLKey, &vname, NULL);
    printf(" url ");
    print_value(vname);
    printf("\n");
    char cmd[PATH_MAX + 16];
    snprintf(cmd, sizeof cmd, "rm -rf '%s'", root);
    system(cmd);
    return 0;
}
