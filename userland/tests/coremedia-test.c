/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-coremedia-test: CoreMedia, run against Apple's and Finch's to compare
 * (tools/host-tests.sh): times (making, rounding, converting, arithmetic, comparing,
 * the invalid, infinite and indefinite ones), time ranges and mappings, their
 * descriptions and dictionaries; block buffers (memory allocated lazily or now, the
 * caller's, custom sources; several blocks, references, contiguous copies).
 */
#include <CoreMedia/CoreMedia.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *
desc(CFTypeRef d)
{
    static char buf[8][512];
    static int at;
    char *b = buf[at++ % 8];
    if (!d) {
        strcpy(b, "(null)");
        return b;
    }
    CFStringRef s = CFGetTypeID(d) == CFStringGetTypeID() ? CFRetain(d) : CFCopyDescription(d);
    CFStringGetCString(s, b, 512, kCFStringEncodingUTF8);
    CFRelease(s);
    return b;
}

static const char *
t(CMTime x)
{
    CFStringRef s = CMTimeCopyDescription(NULL, x);
    const char *r = desc(s);
    CFRelease(s);
    static char buf[8][600];
    static int at;
    char *b = buf[at++ % 8];
    snprintf(b, 600, "%s [%lld/%d f%u e%lld]", r, x.value, x.timescale, x.flags, x.epoch);
    return b;
}

static const char *
r(CMTimeRange x)
{
    CFStringRef s = CMTimeRangeCopyDescription(NULL, x);
    const char *res = desc(s);
    CFRelease(s);
    return res;
}

static void
times(void)
{
    printf("make: %s | %s | %s | %s\n", t(CMTimeMake(1, 30)), t(CMTimeMake(1, 0)), t(CMTimeMake(-5, 3)), t(CMTimeMake(7, -2)));
    printf("epoch: %s\n", t(CMTimeMakeWithEpoch(10, 600, 3)));
    printf("constants: %s | %s | %s | %s | %s\n", t(kCMTimeZero), t(kCMTimeInvalid), t(kCMTimePositiveInfinity),
           t(kCMTimeNegativeInfinity), t(kCMTimeIndefinite));
    double secs[] = {0.5, 1.0 / 3, -2.25, 1e10, 1e15, 1e-9, NAN, INFINITY, -INFINITY};
    for (int i = 0; i < 9; i++)
        printf("seconds %g: %s | %s | %s\n", secs[i], t(CMTimeMakeWithSeconds(secs[i], 600)), t(CMTimeMakeWithSeconds(secs[i], 1)),
               t(CMTimeMakeWithSeconds(secs[i], 1000000000)));
    CMTime samples[] = {CMTimeMake(1, 3), CMTimeMake(2, 3), CMTimeMake(-1, 3), CMTimeMake(5, 2), CMTimeMake(-5, 2), CMTimeMake(1001, 30000),
                        kCMTimeInvalid, kCMTimePositiveInfinity, kCMTimeIndefinite};
    const CMTimeRoundingMethod methods[] = {kCMTimeRoundingMethod_RoundHalfAwayFromZero, kCMTimeRoundingMethod_RoundTowardZero,
                                            kCMTimeRoundingMethod_RoundAwayFromZero, kCMTimeRoundingMethod_QuickTime,
                                            kCMTimeRoundingMethod_RoundTowardPositiveInfinity,
                                            kCMTimeRoundingMethod_RoundTowardNegativeInfinity};
    for (int i = 0; i < 9; i++) {
        printf("seconds of %s: %g\n", t(samples[i]), CMTimeGetSeconds(samples[i]));
        for (int m = 0; m < 6; m++)
            printf("  convert method %d: to 1 %s, to 10 %s, to 600 %s\n", methods[m], t(CMTimeConvertScale(samples[i], 1, methods[m])),
                   t(CMTimeConvertScale(samples[i], 10, methods[m])), t(CMTimeConvertScale(samples[i], 600, methods[m])));
    }
    printf("convert big: %s | %s\n", t(CMTimeConvertScale(CMTimeMake(INT64_MAX / 2, 1), 1000000, kCMTimeRoundingMethod_Default)),
           t(CMTimeConvertScale(CMTimeMake(1, 3), 0, kCMTimeRoundingMethod_Default)));

    CMTime ops[] = {CMTimeMake(1, 3), CMTimeMake(1, 2), CMTimeMake(1, 30000), CMTimeMake(1, 600), CMTimeMakeWithEpoch(1, 2, 1),
                    CMTimeMake(INT64_MAX - 1, 1), kCMTimePositiveInfinity, kCMTimeNegativeInfinity, kCMTimeIndefinite, kCMTimeInvalid,
                    CMTimeMake(1, 7), CMTimeMake(1, 1000000007)};
    int n = sizeof ops / sizeof ops[0];
    for (int i = 0; i < n; i++)
        for (int k = 0; k < n; k++)
            printf("%s ? %s: add %s sub %s cmp %d min %s\n", t(ops[i]), t(ops[k]), t(CMTimeAdd(ops[i], ops[k])),
                   t(CMTimeSubtract(ops[i], ops[k])), CMTimeCompare(ops[i], ops[k]), t(CMTimeMinimum(ops[i], ops[k])));
    for (int i = 0; i < n; i++)
        printf("%s: *3 %s *-2 %s *0.5 %s *1/3 %s abs %s\n", t(ops[i]), t(CMTimeMultiply(ops[i], 3)), t(CMTimeMultiply(ops[i], -2)),
               t(CMTimeMultiplyByFloat64(ops[i], 0.5)), t(CMTimeMultiplyByRatio(ops[i], 1, 3)), t(CMTimeAbsoluteValue(ops[i])));
    printf("multiply overflow: %s\n", t(CMTimeMultiply(CMTimeMake(INT64_MAX / 2, 1), 3)));
    CMTime e2 = CMTimeMakeWithEpoch(1, 2, 2), e3 = CMTimeMakeWithEpoch(1, 3, 3);
    printf("epochs: %s %s %s %s\n", t(CMTimeAdd(e2, e3)), t(CMTimeSubtract(e2, e3)), t(CMTimeAdd(e3, e3)), t(CMTimeSubtract(e3, e2)));
    printf("big lcm: %s | %s | %s\n", t(CMTimeAdd(CMTimeMake(1, 999999), CMTimeMake(1, 1000000))),
           t(CMTimeAdd(CMTimeMake(1, 65537), CMTimeMake(1, 65539))), t(CMTimeAdd(CMTimeMake(1, 2000000000), CMTimeMake(1, 3))));
    printf("sub overflow: %s | %s\n", t(CMTimeSubtract(CMTimeMake(INT64_MIN + 2, 1), CMTimeMake(5, 1))),
           t(CMTimeAdd(CMTimeMake(INT64_MAX - 1, 600), CMTimeMake(INT64_MAX - 1, 600))));
    CMTime rounded = CMTimeConvertScale(CMTimeMake(1, 3), 10, kCMTimeRoundingMethod_Default);
    printf("rounded description: %s\n", t(rounded));

    CFDictionaryRef d = CMTimeCopyAsDictionary(CMTimeMakeWithEpoch(5, 7, 2), NULL);
    printf("dictionary: %s\n", desc(d));
    printf("from dictionary: %s\n", t(CMTimeMakeFromDictionary(d)));
    CFRelease(d);
    printf("from NULL dictionary: %s\n", t(CMTimeMakeFromDictionary(NULL)));

    CMTimeRange a = CMTimeRangeMake(CMTimeMake(1, 1), CMTimeMake(3, 1)), b = CMTimeRangeMake(CMTimeMake(2, 1), CMTimeMake(5, 2));
    printf("range %s end %s\n", r(a), t(CMTimeRangeGetEnd(a)));
    printf("union %s intersection %s\n", r(CMTimeRangeGetUnion(a, b)), r(CMTimeRangeGetIntersection(a, b)));
    printf("disjoint intersection %s\n", r(CMTimeRangeGetIntersection(a, CMTimeRangeMake(CMTimeMake(10, 1), CMTimeMake(1, 1)))));
    printf("contains 1 %d 4 %d 3.9 %d range %d\n", CMTimeRangeContainsTime(a, CMTimeMake(1, 1)), CMTimeRangeContainsTime(a, CMTimeMake(4, 1)),
           CMTimeRangeContainsTime(a, CMTimeMake(39, 10)), CMTimeRangeContainsTimeRange(a, CMTimeRangeMake(CMTimeMake(2, 1), CMTimeMake(1, 1))));
    printf("from-to %s equal %d\n", r(CMTimeRangeFromTimeToTime(CMTimeMake(1, 2), CMTimeMake(3, 1))),
           CMTimeRangeEqual(a, CMTimeRangeMake(CMTimeMake(2, 2), CMTimeMake(6, 2))));
    printf("constants %s %s %s\n", r(kCMTimeRangeZero), r(kCMTimeRangeInvalid), r(CMTimeRangeMake(kCMTimeZero, kCMTimePositiveInfinity)));
    printf("clamp %s %s %s\n", t(CMTimeClampToRange(CMTimeMake(0, 1), a)), t(CMTimeClampToRange(CMTimeMake(9, 1), a)),
           t(CMTimeClampToRange(CMTimeMake(2, 1), a)));
    CMTimeRange from = CMTimeRangeMake(CMTimeMake(0, 1), CMTimeMake(10, 1)), to = CMTimeRangeMake(CMTimeMake(100, 1), CMTimeMake(5, 1));
    printf("map %s duration %s\n", t(CMTimeMapTimeFromRangeToRange(CMTimeMake(4, 1), from, to)),
           t(CMTimeMapDurationFromRangeToRange(CMTimeMake(4, 1), from, to)));
    printf("fold %s %s\n", t(CMTimeFoldIntoRange(CMTimeMake(23, 1), from)), t(CMTimeFoldIntoRange(CMTimeMake(-3, 1), from)));
    d = CMTimeRangeCopyAsDictionary(a, NULL);
    printf("range dictionary %s back %s\n", desc(d), r(CMTimeRangeMakeFromDictionary(d)));
    CFRelease(d);
    CMTimeMapping m = CMTimeMappingMake(from, to), e = CMTimeMappingMakeEmpty(to);
    CFStringRef ms = CMTimeMappingCopyDescription(NULL, m), es = CMTimeMappingCopyDescription(NULL, e);
    printf("mapping %s empty %s\n", desc(ms), desc(es));
    CFRelease(ms);
    CFRelease(es);
    d = CMTimeMappingCopyAsDictionary(m, NULL);
    printf("mapping dictionary %s\n", desc(d));
    CFRelease(d);
}

/* --- block buffers --- */

static int allocated, freed;

static void *
source_allocate(void *refcon, size_t size)
{
    allocated++;
    printf("  allocate %zu refcon %s\n", size, (char *)refcon);
    return calloc(1, size);
}

static void
source_free(void *refcon, void *block, size_t size)
{
    freed++;
    printf("  free %zu refcon %s\n", size, (char *)refcon);
    free(block);
}

static void
contents(const char *label, CMBlockBufferRef b)
{
    size_t n = CMBlockBufferGetDataLength(b);
    char buf[256] = {0};
    OSStatus e = CMBlockBufferCopyDataBytes(b, 0, n < sizeof buf ? n : sizeof buf - 1, buf);
    for (size_t i = 0; i < n && i < sizeof buf; i++)
        if (buf[i] < 32)
            buf[i] = '.';
    printf("%s: length %zu empty %d copy %d [%s]\n", label, n, CMBlockBufferIsEmpty(b), (int)e, buf);
}

static void
pointer(CMBlockBufferRef b, size_t offset)
{
    size_t at = 99, total = 99;
    char *p = NULL;
    OSStatus e = CMBlockBufferGetDataPointer(b, offset, &at, &total, &p);
    printf("  pointer at %zu: %d, length at offset %zu total %zu %s\n", offset, (int)e, at, total, p ? "set" : "NULL");
}

static void
blocks(void)
{
    CMBlockBufferRef b = NULL;
    printf("empty %d\n", (int)CMBlockBufferCreateEmpty(NULL, 0, 0, &b));
    contents("empty", b);
    printf("type id %d, empty pointer:\n", CFGetTypeID(b) == CMBlockBufferGetTypeID());
    pointer(b, 0);
    printf("empty contiguous %d\n", CMBlockBufferIsRangeContiguous(b, 0, 0));
    CFRelease(b);

    /* memory the buffer allocates, lazily or now */
    printf("lazy %d\n", (int)CMBlockBufferCreateWithMemoryBlock(NULL, NULL, 100, NULL, NULL, 10, 50, 0, &b));
    printf("  length %zu\n", CMBlockBufferGetDataLength(b));
    pointer(b, 0);
    char tmp[8];
    char *ret = NULL;
    printf("  access unallocated %d\n", (int)CMBlockBufferAccessDataBytes(b, 0, 4, tmp, &ret));
    printf("  fill unallocated %d\n", (int)CMBlockBufferFillDataBytes('z', b, 0, 4));
    printf("  assure %d\n", (int)CMBlockBufferAssureBlockMemory(b));
    pointer(b, 0);
    pointer(b, 49);
    pointer(b, 50);
    printf("  fill %d\n", (int)CMBlockBufferFillDataBytes('a', b, 0, 50));
    printf("  replace %d\n", (int)CMBlockBufferReplaceDataBytes("HELLO", b, 45, 5));
    printf("  replace past %d\n", (int)CMBlockBufferReplaceDataBytes("HELLO", b, 46, 5));
    contents("  lazy", b);
    CFRelease(b);

    /* parameters */
    printf("errors: offset %d length %d zero %d zero-block %d\n", (int)CMBlockBufferCreateWithMemoryBlock(NULL, NULL, 10, NULL, NULL, 11, 0, 0, &b),
           (int)CMBlockBufferCreateWithMemoryBlock(NULL, NULL, 10, NULL, NULL, 5, 6, 0, &b),
           (int)CMBlockBufferCreateWithMemoryBlock(NULL, NULL, 10, NULL, NULL, 0, 0, 0, &b),
           (int)CMBlockBufferCreateWithMemoryBlock(NULL, NULL, 0, NULL, NULL, 0, 0, 0, &b));
    printf("errors: offset=block %d\n", (int)CMBlockBufferCreateWithMemoryBlock(NULL, NULL, 10, NULL, NULL, 10, 0, 0, &b));

    /* memory of the caller's, not freed (kCFAllocatorNull), and a custom source */
    static char mine[] = "0123456789abcdefghij";
    printf("caller's %d\n", (int)CMBlockBufferCreateWithMemoryBlock(NULL, mine, 20, kCFAllocatorNull, NULL, 5, 10, 0, &b));
    contents("  caller's", b);
    char *p = NULL;
    CMBlockBufferGetDataPointer(b, 2, NULL, NULL, &p);
    printf("  pointer is into it %d\n", p == mine + 7);
    CFRelease(b);
    /* (the struct is packed: filled in at run time, not from a constant) */
    CMBlockBufferCustomBlockSource src;
    src.version = kCMBlockBufferCustomBlockSourceVersion;
    src.AllocateBlock = source_allocate;
    src.FreeBlock = source_free;
    src.refCon = "src";
    printf("custom now %d\n", (int)CMBlockBufferCreateWithMemoryBlock(NULL, NULL, 32, NULL, &src, 0, 32, kCMBlockBufferAssureMemoryNowFlag, &b));
    printf("  allocated %d freed %d\n", allocated, freed);
    CFRelease(b);
    printf("  allocated %d freed %d\n", allocated, freed);
    printf("custom given memory %d\n", (int)CMBlockBufferCreateWithMemoryBlock(NULL, malloc(16), 16, NULL, &src, 0, 16, 0, &b));
    CFRelease(b);
    printf("  allocated %d freed %d\n", allocated, freed);
    CMBlockBufferCustomBlockSource bad = src;
    bad.version = 7;
    printf("bad version %d\n", (int)CMBlockBufferCreateWithMemoryBlock(NULL, NULL, 32, NULL, &bad, 0, 32, 0, &b));

    /* several blocks */
    static char first[] = "ABCDEFGH", second[] = "ijklmnop";
    CMBlockBufferCreateEmpty(NULL, 0, 0, &b);
    printf("append %d %d %d\n", (int)CMBlockBufferAppendMemoryBlock(b, first, 8, kCFAllocatorNull, NULL, 0, 8, 0),
           (int)CMBlockBufferAppendMemoryBlock(b, second, 8, kCFAllocatorNull, NULL, 2, 4, 0),
           (int)CMBlockBufferAppendMemoryBlock(b, NULL, 6, NULL, NULL, 0, 6, kCMBlockBufferAssureMemoryNowFlag));
    CMBlockBufferFillDataBytes('-', b, 12, 6);
    contents("blocks", b);
    for (size_t off = 0; off < 20; off += 3)
        pointer(b, off);
    printf("  contiguous 0-8 %d 0-9 %d 8-4 %d 7-2 %d 12-0 %d 12-7 %d 0-0 %d\n", CMBlockBufferIsRangeContiguous(b, 0, 8),
           CMBlockBufferIsRangeContiguous(b, 0, 9), CMBlockBufferIsRangeContiguous(b, 8, 4), CMBlockBufferIsRangeContiguous(b, 7, 2),
           CMBlockBufferIsRangeContiguous(b, 12, 0), CMBlockBufferIsRangeContiguous(b, 12, 7), CMBlockBufferIsRangeContiguous(b, 0, 0));
    char t8[8] = {0};
    ret = NULL;
    OSStatus e = CMBlockBufferAccessDataBytes(b, 6, 4, t8, &ret);
    printf("  access across %d temp %d [%.4s]\n", (int)e, ret == t8, ret);
    e = CMBlockBufferAccessDataBytes(b, 1, 4, t8, &ret);
    printf("  access within %d temp %d [%.4s]\n", (int)e, ret == t8, ret);
    printf("  access past %d copy past %d\n", (int)CMBlockBufferAccessDataBytes(b, 16, 4, t8, &ret), (int)CMBlockBufferCopyDataBytes(b, 15, 4, t8));
    printf("  replace across %d\n", (int)CMBlockBufferReplaceDataBytes("xyz", b, 7, 3));
    contents("  after", b);
    printf("  in caller's memory: %s %s\n", first, second);

    /* references */
    CMBlockBufferRef r = NULL, c = NULL;
    printf("reference %d\n", (int)CMBlockBufferCreateWithBufferReference(NULL, b, 4, 10, 0, &r));
    contents("  ref", r);
    printf("  contiguous %d %d\n", CMBlockBufferIsRangeContiguous(r, 0, 4), CMBlockBufferIsRangeContiguous(r, 0, 5));
    printf("  ref errors: zero %d past %d offset %d empty-ok %d\n", (int)CMBlockBufferCreateWithBufferReference(NULL, b, 4, 0, 0, &c),
           (int)CMBlockBufferCreateWithBufferReference(NULL, b, 10, 10, 0, &c), (int)CMBlockBufferCreateWithBufferReference(NULL, b, 30, 1, 0, &c),
           (int)CMBlockBufferCreateWithBufferReference(NULL, b, 4, 0, kCMBlockBufferPermitEmptyReferenceFlag, &c));
    if (c) {
        contents("  empty reference", c);
        CFRelease(c);
        c = NULL;
    }
    printf("  append reference %d\n", (int)CMBlockBufferAppendBufferReference(r, b, 0, 3, 0));
    contents("  ref+", r);
    CMBlockBufferReplaceDataBytes("##", r, 0, 2);
    contents("  source sees writes", b);
    printf("contiguous copy %d\n", (int)CMBlockBufferCreateContiguous(NULL, r, NULL, NULL, 0, 0, 0, &c));
    contents("  contiguous", c);
    printf("  one piece %d\n", CMBlockBufferIsRangeContiguous(c, 0, 0));
    CFRelease(c);
    printf("contiguous of contiguous %d\n", (int)CMBlockBufferCreateContiguous(NULL, b, NULL, NULL, 1, 4, 0, &c));
    char *p1 = NULL, *p2 = NULL;
    CMBlockBufferGetDataPointer(b, 1, NULL, NULL, &p1);
    CMBlockBufferGetDataPointer(c, 0, NULL, NULL, &p2);
    printf("  shares memory %d\n", p1 == p2);
    CFRelease(c);
    printf("contiguous always copying %d\n", (int)CMBlockBufferCreateContiguous(NULL, b, NULL, NULL, 1, 4, kCMBlockBufferAlwaysCopyDataFlag, &c));
    CMBlockBufferGetDataPointer(c, 0, NULL, NULL, &p2);
    printf("  shares memory %d\n", p1 == p2);
    contents("  copy", c);
    CFRelease(c);
    CMBlockBufferRef em = NULL;
    CMBlockBufferCreateEmpty(NULL, 0, 0, &em);
    printf("contiguous of empty %d, past end %d\n", (int)CMBlockBufferCreateContiguous(NULL, em, NULL, NULL, 0, 0, 0, &c),
           (int)CMBlockBufferCreateContiguous(NULL, b, NULL, NULL, 10, 20, 0, &c));
    printf("reference to empty %d\n", (int)CMBlockBufferAppendBufferReference(em, b, 0, 0, 0));
    contents("  appended whole", em);
    CFRelease(em);
    CFRelease(r);
    CFRelease(b);
    printf("released: allocated %d freed %d\n", allocated, freed);
}

int
main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    Dl_info info;
    dladdr((void *)CMTimeMake, &info);
    printf("%s\n", info.dli_fname);
    times();
    blocks();
    return 0;
}
