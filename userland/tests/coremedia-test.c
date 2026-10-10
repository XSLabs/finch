/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-coremedia-test: CoreMedia, run against Apple's and Finch's to compare
 * (tools/host-tests.sh): times (making, rounding, converting, arithmetic, comparing,
 * the invalid, infinite and indefinite ones), time ranges and mappings, their
 * descriptions and dictionaries; block buffers (memory allocated lazily or now, the
 * caller's, custom sources; several blocks, references, contiguous copies); format
 * descriptions (video, audio, muxed, time code and the rest; equality, apertures);
 * sample buffers (timing and sizes, ranges, copies, readiness, invalidation, sample and
 * buffer attachments, image buffers, output timing, audio buffer lists and packets);
 * clocks, timebases (anchors, rates, chains, timers) and conversions; simple and buffer
 * queues (ordering, triggers, end of data); memory pools; format descriptions from H.264
 * and HEVC parameter sets; metadata identifiers, the data type registry and metadata
 * format descriptions; tags, tag collections and tagged buffer groups.
 */
#include <CoreMedia/CoreMedia.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdarg.h>
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

/* --- format descriptions --- */

/* A description with its pointers masked. */
static void
show(const char *label, CFTypeRef x)
{
    if (!x) {
        printf("%s: NULL\n", label);
        return;
    }
    CFStringRef s = CFCopyDescription(x);
    char buf[8192];
    CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8);
    CFRelease(s);
    char out[8192], *o = out;
    for (char *p = buf; *p;) {
        if (p[0] == '0' && p[1] == 'x' && p[2] && strchr("0123456789abcdef", p[2]) && p[3] && strchr("0123456789abcdef", p[3]) &&
            p[4] && strchr("0123456789abcdef", p[4]) && p[5] && strchr("0123456789abcdef", p[5]) && p[6] && strchr("0123456789abcdef", p[6])) {
            p += 2;
            while (*p && strchr("0123456789abcdef", *p))
                p++;
            o += sprintf(o, "0x?");
        } else
            *o++ = *p++;
    }
    *o = 0;
    printf("%s: %s\n", label, out);
}

static CFNumberRef
num(double d)
{
    return CFNumberCreate(NULL, kCFNumberDoubleType, &d);
}

static CFDictionaryRef
dict(int n, ...)
{
    va_list ap;
    va_start(ap, n);
    const void *k[16], *v[16];
    for (int i = 0; i < n; i++) {
        k[i] = va_arg(ap, const void *);
        v[i] = va_arg(ap, const void *);
    }
    va_end(ap);
    return CFDictionaryCreate(NULL, k, v, n, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

static void
audio(int channels, AudioFormatID format, const AudioChannelLayout *layout, size_t layoutSize, bool print)
{
    bool pcm = format == kAudioFormatLinearPCM;
    AudioStreamBasicDescription a = {48000, format, pcm ? kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked : 0, pcm ? 4 * channels : 0,
                                     pcm ? 1 : 1024, pcm ? 4 * channels : 0, channels, pcm ? 32 : 0, 0};
    char cookie[5] = {1, 2, 3, 4, 5};
    CMAudioFormatDescriptionRef d = NULL;
    OSStatus e = CMAudioFormatDescriptionCreate(NULL, &a, layoutSize, layout, pcm ? 0 : 5, pcm ? NULL : cookie, NULL, &d);
    size_t n = 0, ls = 0, cs = 0;
    const AudioFormatListItem *list = d ? CMAudioFormatDescriptionGetFormatList(d, &n) : NULL;
    const AudioChannelLayout *l = d ? CMAudioFormatDescriptionGetChannelLayout(d, &ls) : NULL;
    const void *c = d ? CMAudioFormatDescriptionGetMagicCookie(d, &cs) : NULL;
    printf("audio %d channels %c%c%c%c: %d list %zu tag %x layout %zu tag %x cookie %zu copied %d richest %d compatible %d\n", channels,
           (char)(format >> 24), (char)(format >> 16), (char)(format >> 8), (char)format, (int)e, n, n ? (unsigned)list[0].mChannelLayoutTag : 0, ls,
           l ? (unsigned)l->mChannelLayoutTag : 0, cs, c && c != cookie, d && CMAudioFormatDescriptionGetRichestDecodableFormat(d) == list,
           d && CMAudioFormatDescriptionGetMostCompatibleFormat(d) == list);
    if (d && print)
        show("  description", d);
    if (d)
        CFRelease(d);
}

static void
formats(void)
{
    CFStringRef k[] = {CFSTR("FormatName"), kCMFormatDescriptionExtension_FieldCount, CFSTR("Custom")};
    int two = 2;
    CFNumberRef n2 = CFNumberCreate(NULL, kCFNumberIntType, &two);
    CFTypeRef v[] = {CFSTR("Fancy"), n2, CFSTR("x")};
    CFDictionaryRef ext = CFDictionaryCreate(NULL, (const void **)k, v, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CMVideoFormatDescriptionRef f = NULL;
    printf("video %d\n", (int)CMVideoFormatDescriptionCreate(NULL, kCMVideoCodecType_H264, 640, 480, ext, &f));
    show("  description", f);
    int fields = 0;
    CFNumberGetValue(CMFormatDescriptionGetExtension(f, kCMFormatDescriptionExtension_FieldCount), kCFNumberIntType, &fields);
    printf("  type %d media %x sub %x extension %s field count %d\n", CFGetTypeID(f) == CMFormatDescriptionGetTypeID(),
           (unsigned)CMFormatDescriptionGetMediaType(f), (unsigned)CMFormatDescriptionGetMediaSubType(f),
           desc(CMFormatDescriptionGetExtension(f, CFSTR("FormatName"))), fields);
    printf("  extensions copied %d\n", CMFormatDescriptionGetExtensions(f) != ext);
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(f);
    printf("  dimensions %d x %d\n", dims.width, dims.height);
    show("  common keys", CMVideoFormatDescriptionGetExtensionKeysCommonWithImageBuffers());

    CFDictionaryRef par = dict(2, kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing, num(4),
                               kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing, num(3));
    CFDictionaryRef ca = dict(4, kCMFormatDescriptionKey_CleanApertureWidth, num(600), kCMFormatDescriptionKey_CleanApertureHeight, num(400),
                              kCMFormatDescriptionKey_CleanApertureHorizontalOffset, num(10), kCMFormatDescriptionKey_CleanApertureVerticalOffset, num(-6));
    CMVideoFormatDescriptionRef v1 = NULL, v2 = NULL, v3 = NULL;
    CMVideoFormatDescriptionCreate(NULL, kCMVideoCodecType_H264, 640, 480,
                                   dict(2, kCMFormatDescriptionExtension_PixelAspectRatio, par, kCMFormatDescriptionExtension_CleanAperture, ca), &v1);
    for (int a = 0; a < 2; a++)
        for (int b = 0; b < 2; b++) {
            CGSize s = CMVideoFormatDescriptionGetPresentationDimensions(v1, a, b);
            printf("  presentation aspect %d aperture %d: %g x %g\n", a, b, s.width, s.height);
        }
    CGRect r = CMVideoFormatDescriptionGetCleanAperture(v1, true), r2 = CMVideoFormatDescriptionGetCleanAperture(v1, false);
    printf("  clean aperture top-left %g %g %g %g, bottom-left %g %g\n", r.origin.x, r.origin.y, r.size.width, r.size.height, r2.origin.x, r2.origin.y);
    CMVideoFormatDescriptionCreate(NULL, kCMVideoCodecType_H264, 640, 480, NULL, &v2);
    CMVideoFormatDescriptionCreate(NULL, kCMVideoCodecType_H264, 640, 480, NULL, &v3);
    r = CMVideoFormatDescriptionGetCleanAperture(v2, true);
    printf("  no aperture %g %g %g %g\n", r.origin.x, r.origin.y, r.size.width, r.size.height);
    const void *both[] = {kCMFormatDescriptionExtension_PixelAspectRatio, kCMFormatDescriptionExtension_CleanAperture};
    CFArrayRef ignore = CFArrayCreate(NULL, both, 2, &kCFTypeArrayCallBacks);
    printf("  equal %d %d %d ignoring one %d ignoring both %d hash %d\n", CMFormatDescriptionEqual(v1, v2), CMFormatDescriptionEqual(v2, v3),
           CFEqual(v2, v3), CMFormatDescriptionEqualIgnoringExtensionKeys(v1, v2, kCMFormatDescriptionExtension_PixelAspectRatio, NULL),
           CMFormatDescriptionEqualIgnoringExtensionKeys(v1, v2, ignore, NULL), CFHash(v2) == CFHash(v3));
    CMVideoFormatDescriptionRef bad = NULL;
    printf("  negative width %d, plain video %d, no media type %d\n", (int)CMVideoFormatDescriptionCreate(NULL, kCMVideoCodecType_H264, -1, 480, NULL, &bad),
           (int)CMFormatDescriptionCreate(NULL, kCMMediaType_Video, kCMVideoCodecType_H264, NULL, &v3),
           (int)CMFormatDescriptionCreate(NULL, 0, kCMVideoCodecType_H264, NULL, &bad));
    show("  plain video", v3);
    dims = CMVideoFormatDescriptionGetDimensions(v3);
    printf("  plain dimensions %d x %d, equal to made %d\n", dims.width, dims.height, CMFormatDescriptionEqual(v2, v3));

    CMMediaType types[][2] = {{kCMMediaType_Muxed, kCMMuxedStreamType_MPEG2Program}, {kCMMediaType_Text, kCMTextFormatType_QTText},
                              {kCMMediaType_TimeCode, kCMTimeCodeFormatType_TimeCode32}, {kCMMediaType_Metadata, kCMMetadataFormatType_Boxed},
                              {'abcd', 'efgh'}, {kCMMediaType_ClosedCaption, kCMClosedCaptionFormatType_CEA608},
                              {kCMMediaType_Subtitle, kCMSubtitleFormatType_3GText}, {kCMMediaType_Audio, kAudioFormatLinearPCM}};
    for (size_t i = 0; i < sizeof types / sizeof types[0]; i++) {
        CMFormatDescriptionRef d = NULL;
        CMFormatDescriptionCreate(NULL, types[i][0], types[i][1], NULL, &d);
        show("plain", d);
        CFRelease(d);
    }
    CMTimeCodeFormatDescriptionRef tc = NULL;
    printf("time code %d\n", (int)CMTimeCodeFormatDescriptionCreate(NULL, kCMTimeCodeFormatType_TimeCode32, CMTimeMake(1001, 30000), 30,
                                                                     kCMTimeCodeFlag_DropFrame, NULL, &tc));
    show("  description", tc);
    printf("  duration %s quanta %u flags %u\n", t(CMTimeCodeFormatDescriptionGetFrameDuration(tc)), CMTimeCodeFormatDescriptionGetFrameQuanta(tc),
           CMTimeCodeFormatDescriptionGetTimeCodeFlags(tc));
    CMMuxedFormatDescriptionRef mx = NULL;
    printf("muxed %d\n", (int)CMMuxedFormatDescriptionCreate(NULL, kCMMuxedStreamType_MPEG2Transport, NULL, &mx));
    show("  description", mx);

    for (int c = 0; c <= 3; c++)
        audio(c, kAudioFormatLinearPCM, NULL, 0, c == 2);
    audio(8, kAudioFormatLinearPCM, NULL, 0, false);
    audio(2, kAudioFormatMPEG4AAC, NULL, 0, true);
    AudioChannelLayout l = {kAudioChannelLayoutTag_MPEG_5_1_A, 0, 0, {}};
    audio(6, kAudioFormatLinearPCM, &l, sizeof l, true);
    audio(2, kAudioFormatLinearPCM, &l, sizeof l, false);
    AudioChannelLayout *two_labels = calloc(1, sizeof(AudioChannelLayout) + sizeof(AudioChannelDescription));
    two_labels->mNumberChannelDescriptions = 2;
    two_labels->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
    two_labels->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
    audio(2, kAudioFormatMPEG4AAC, two_labels, sizeof(AudioChannelLayout) + sizeof(AudioChannelDescription), true);
    l.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelBitmap;
    l.mChannelBitmap = kAudioChannelBit_Left | kAudioChannelBit_Right;
    audio(2, kAudioFormatMPEG4AAC, &l, sizeof l, true);
    CMAudioFormatDescriptionRef au = NULL;
    const AudioStreamBasicDescription *none = NULL;
    printf("audio without a description %d\n", (int)CMAudioFormatDescriptionCreate(NULL, none, 0, NULL, 0, NULL, NULL, &au));
}

/* --- sample buffers --- */

static const char *
timing(CMSampleTimingInfo i)
{
    static char b[8][600];
    static int at;
    char *o = b[at++ % 8];
    snprintf(o, 600, "(dur %s pts %s dts %s)", t(i.duration), t(i.presentationTimeStamp), t(i.decodeTimeStamp));
    return o;
}

static void
report(const char *label, CMSampleBufferRef sb)
{
    printf("%s: valid %d ready %d samples %ld total size %zu duration %s\n", label, CMSampleBufferIsValid(sb), CMSampleBufferDataIsReady(sb),
           (long)CMSampleBufferGetNumSamples(sb), CMSampleBufferGetTotalSampleSize(sb), t(CMSampleBufferGetDuration(sb)));
    printf("  pts %s dts %s\n", t(CMSampleBufferGetPresentationTimeStamp(sb)), t(CMSampleBufferGetDecodeTimeStamp(sb)));
    printf("  output pts %s duration %s dts %s\n", t(CMSampleBufferGetOutputPresentationTimeStamp(sb)), t(CMSampleBufferGetOutputDuration(sb)),
           t(CMSampleBufferGetOutputDecodeTimeStamp(sb)));
    CMItemCount needed = -1;
    OSStatus e = CMSampleBufferGetSampleTimingInfoArray(sb, 0, NULL, &needed);
    printf("  timing entries %d %ld:", (int)e, (long)needed);
    CMSampleTimingInfo infos[8];
    if (needed > 0 && needed <= 8 && !CMSampleBufferGetSampleTimingInfoArray(sb, needed, infos, NULL))
        for (CMItemCount i = 0; i < needed; i++)
            printf(" %s", timing(infos[i]));
    printf("\n");
    e = CMSampleBufferGetSampleSizeArray(sb, 0, NULL, &needed);
    printf("  size entries %d %ld:", (int)e, (long)needed);
    size_t sizes[8];
    if (needed > 0 && needed <= 8 && !CMSampleBufferGetSampleSizeArray(sb, needed, sizes, NULL))
        for (CMItemCount i = 0; i < needed; i++)
            printf(" %zu", sizes[i]);
    printf("\n");
    for (CMItemIndex i = 0; i <= CMSampleBufferGetNumSamples(sb) && i < 6; i++) {
        CMSampleTimingInfo info;
        e = CMSampleBufferGetSampleTimingInfo(sb, i, &info);
        printf("  sample %ld: size %zu timing %d %s\n", (long)i, CMSampleBufferGetSampleSize(sb, i), (int)e, e ? "" : timing(info));
    }
    CMBlockBufferRef data = CMSampleBufferGetDataBuffer(sb);
    printf("  data %zu image %d format %s\n", data ? CMBlockBufferGetDataLength(data) : 0, CMSampleBufferGetImageBuffer(sb) != NULL,
           CMSampleBufferGetFormatDescription(sb) ? "yes" : "none");
}

static int readied, invalidated, each;

static OSStatus
make_ready(CMSampleBufferRef sb, void *refcon)
{
    readied++;
    printf("  making ready (%s)\n", (char *)refcon);
    return 0;
}

static void
on_invalidate(CMSampleBufferRef sb, uint64_t refcon)
{
    invalidated++;
    printf("  invalidated %llu\n", (unsigned long long)refcon);
}

static OSStatus
for_each(CMSampleBufferRef sb, CMItemCount index, void *refcon)
{
    each++;
    printf("  sample %ld of %ld: %s size %zu\n", (long)index, (long)CMSampleBufferGetNumSamples(sb),
           t(CMSampleBufferGetPresentationTimeStamp(sb)), CMSampleBufferGetTotalSampleSize(sb));
    return index == 1 && refcon ? -1 : 0;
}

static void
samples(void)
{
    CMBlockBufferRef bb = NULL;
    CMBlockBufferCreateWithMemoryBlock(NULL, NULL, 20, NULL, NULL, 0, 20, kCMBlockBufferAssureMemoryNowFlag, &bb);
    CMBlockBufferReplaceDataBytes("aaaabbbbbbcccccccccc", bb, 0, 20);
    CMFormatDescriptionRef fd = NULL;
    CMFormatDescriptionCreate(NULL, kCMMediaType_Muxed, 'abcd', NULL, &fd);
    CMSampleTimingInfo one = {CMTimeMake(1, 30), CMTimeMake(10, 30), kCMTimeInvalid};
    size_t sizes[] = {4, 6, 10};
    CMSampleBufferRef sb = NULL;
    printf("ready %d\n", (int)CMSampleBufferCreateReady(NULL, bb, fd, 3, 1, &one, 3, sizes, &sb));
    report("three samples", sb);
    printf("  type %d\n", CFGetTypeID(sb) == CMSampleBufferGetTypeID());
    CMSampleTimingInfo small[1];
    CMItemCount needed = 0;
    printf("  timing into a small array %d\n", (int)CMSampleBufferGetSampleTimingInfoArray(sb, 0, small, &needed));
    size_t sz[1];
    printf("  sizes into a small array %d\n", (int)CMSampleBufferGetSampleSizeArray(sb, 0, sz, &needed));
    each = 0;
    printf("  for each %d\n", (int)CMSampleBufferCallForEachSample(sb, for_each, NULL));
    printf("  for each, stopping %d (%d calls)\n", (int)CMSampleBufferCallForEachSample(sb, for_each, "stop"), each);

    CMSampleBufferRef r = NULL;
    printf("range 1-2 %d\n", (int)CMSampleBufferCopySampleBufferForRange(NULL, sb, CFRangeMake(1, 2), &r));
    if (r) {
        report("  range", r);
        char got[32] = {0};
        CMBlockBufferCopyDataBytes(CMSampleBufferGetDataBuffer(r), 0, CMBlockBufferGetDataLength(CMSampleBufferGetDataBuffer(r)), got);
        printf("  range data [%s]\n", got);
        CFRelease(r);
    }
    printf("range past the end %d\n", (int)CMSampleBufferCopySampleBufferForRange(NULL, sb, CFRangeMake(2, 2), &r));
    CMSampleTimingInfo three[] = {{CMTimeMake(1, 10), CMTimeMake(5, 10), CMTimeMake(4, 10)},
                                  {CMTimeMake(2, 10), CMTimeMake(7, 10), CMTimeMake(5, 10)},
                                  {CMTimeMake(1, 10), CMTimeMake(6, 10), CMTimeMake(6, 10)}};
    printf("new timing %d\n", (int)CMSampleBufferCreateCopyWithNewTiming(NULL, sb, 3, three, &r));
    report("  retimed", r);
    printf("new timing, wrong count %d\n", (int)CMSampleBufferCreateCopyWithNewTiming(NULL, sb, 2, three, &r));
    CMSampleBufferRef c = NULL;
    printf("copy %d\n", (int)CMSampleBufferCreateCopy(NULL, sb, &c));
    printf("  shares data %d format %d\n", CMSampleBufferGetDataBuffer(c) == bb, CMSampleBufferGetFormatDescription(c) == fd);

    /* sample attachments */
    printf("sample attachments, not made %s\n", CMSampleBufferGetSampleAttachmentsArray(sb, false) ? "some" : "none");
    CFArrayRef sa = CMSampleBufferGetSampleAttachmentsArray(sb, true);
    printf("  made %ld\n", sa ? (long)CFArrayGetCount(sa) : -1);
    CFDictionarySetValue((CFMutableDictionaryRef)CFArrayGetValueAtIndex(sa, 1), kCMSampleAttachmentKey_NotSync, kCFBooleanTrue);
    show("  again", CMSampleBufferGetSampleAttachmentsArray(sb, false));
    printf("  the copy's %s\n", CMSampleBufferGetSampleAttachmentsArray(c, false) ? "some" : "none");
    printf("range keeps them: ");
    CMSampleBufferCopySampleBufferForRange(NULL, sb, CFRangeMake(1, 1), &r);
    show("", CMSampleBufferGetSampleAttachmentsArray(r, false));

    /* buffer attachments, on sample buffers and pixel buffers */
    CMSetAttachment(sb, CFSTR("p"), CFSTR("propagated"), kCMAttachmentMode_ShouldPropagate);
    CMSetAttachment(sb, CFSTR("n"), CFSTR("not"), kCMAttachmentMode_ShouldNotPropagate);
    CMAttachmentMode mode = 9;
    show("attachment p", CMGetAttachment(sb, CFSTR("p"), &mode));
    printf("  mode %d\n", mode);
    show("  propagated", CMCopyDictionaryOfAttachments(NULL, sb, kCMAttachmentMode_ShouldPropagate));
    show("  not", CMCopyDictionaryOfAttachments(NULL, sb, kCMAttachmentMode_ShouldNotPropagate));
    CMPropagateAttachments(sb, c);
    show("  propagated to the copy", CMCopyDictionaryOfAttachments(NULL, c, kCMAttachmentMode_ShouldPropagate));
    CMRemoveAttachment(sb, CFSTR("p"));
    show("  removed", CMCopyDictionaryOfAttachments(NULL, sb, kCMAttachmentMode_ShouldPropagate));
    CMRemoveAllAttachments(sb);
    show("  removed all", CMCopyDictionaryOfAttachments(NULL, sb, kCMAttachmentMode_ShouldNotPropagate));
    CVPixelBufferRef pb = NULL;
    CVPixelBufferCreate(NULL, 64, 48, kCVPixelFormatType_32BGRA, NULL, &pb);
    CMSetAttachment(pb, CFSTR("on"), CFSTR("pixels"), kCMAttachmentMode_ShouldPropagate);
    CFTypeRef cv = CVBufferCopyAttachment(pb, CFSTR("on"), NULL);
    show("  on a pixel buffer, seen by CoreVideo", cv);
    show("  on a string", CMGetAttachment(CFSTR("x"), CFSTR("y"), NULL));

    /* image buffers */
    CMVideoFormatDescriptionRef vfd = NULL;
    printf("format for image %d\n", (int)CMVideoFormatDescriptionCreateForImageBuffer(NULL, pb, &vfd));
    show("  description", vfd);
    printf("  matches %d\n", CMVideoFormatDescriptionMatchesImageBuffer(vfd, pb));
    CVPixelBufferRef other = NULL;
    CVPixelBufferCreate(NULL, 32, 48, kCVPixelFormatType_32BGRA, NULL, &other);
    printf("  matches another size %d\n", CMVideoFormatDescriptionMatchesImageBuffer(vfd, other));
    CMSampleBufferRef ib = NULL;
    printf("image sample %d\n", (int)CMSampleBufferCreateReadyWithImageBuffer(NULL, pb, vfd, &one, &ib));
    report("  image", ib);
    printf("  same image %d\n", CMSampleBufferGetImageBuffer(ib) == pb);
    printf("image sample, mismatched format %d\n", (int)CMSampleBufferCreateReadyWithImageBuffer(NULL, other, vfd, &one, &r));
    printf("image sample, no timing %d\n", (int)CMSampleBufferCreateForImageBuffer(NULL, pb, true, NULL, NULL, vfd, &one, &r));

    /* readiness, failure and invalidation */
    CMSampleBufferRef lazy = NULL;
    printf("not ready %d\n", (int)CMSampleBufferCreate(NULL, bb, false, make_ready, "refcon", fd, 3, 1, &one, 3, sizes, &lazy));
    printf("  ready %d\n", CMSampleBufferDataIsReady(lazy));
    printf("  make ready %d now %d (called %d)\n", (int)CMSampleBufferMakeDataReady(lazy), CMSampleBufferDataIsReady(lazy), readied);
    printf("  make ready again %d (called %d)\n", (int)CMSampleBufferMakeDataReady(lazy), readied);
    CMSampleBufferRef failing = NULL;
    CMSampleBufferCreate(NULL, bb, false, NULL, NULL, fd, 3, 1, &one, 3, sizes, &failing);
    OSStatus status = 0;
    printf("  make ready without a callback %d\n", (int)CMSampleBufferMakeDataReady(failing));
    printf("  failed %d", CMSampleBufferHasDataFailed(failing, &status));
    printf(" set failed %d", (int)CMSampleBufferSetDataFailed(failing, -42));
    printf(" failed %d status %d ready %d\n", CMSampleBufferHasDataFailed(failing, &status), (int)status, CMSampleBufferDataIsReady(failing));
    printf("  set ready %d now %d\n", (int)CMSampleBufferSetDataReady(failing), CMSampleBufferDataIsReady(failing));
    printf("invalidate callback %d\n", (int)CMSampleBufferSetInvalidateCallback(c, on_invalidate, 77));
    printf("  again %d\n", (int)CMSampleBufferSetInvalidateCallback(c, on_invalidate, 78));
    printf("  invalidate %d valid %d (called %d)\n", (int)CMSampleBufferInvalidate(c), CMSampleBufferIsValid(c), invalidated);
    printf("  invalidate again %d (called %d)\n", (int)CMSampleBufferInvalidate(c), invalidated);
    printf("  after: samples %ld size %zu timing %d\n", (long)CMSampleBufferGetNumSamples(c), CMSampleBufferGetTotalSampleSize(c),
           (int)CMSampleBufferGetSampleTimingInfo(c, 0, small));

    /* data buffers set later, and errors */
    CMSampleBufferRef empty = NULL;
    printf("no data %d\n", (int)CMSampleBufferCreate(NULL, NULL, false, NULL, NULL, fd, 3, 1, &one, 3, sizes, &empty));
    report("  no data", empty);
    printf("  set data %d again %d\n", (int)CMSampleBufferSetDataBuffer(empty, bb), (int)CMSampleBufferSetDataBuffer(empty, bb));
    printf("  ready now %d\n", CMSampleBufferDataIsReady(empty));
    printf("errors: sizes too many %d timing count %d samples without sizes %d data too small %d\n",
           (int)CMSampleBufferCreateReady(NULL, bb, fd, 2, 1, &one, 3, sizes, &r), (int)CMSampleBufferCreateReady(NULL, bb, fd, 3, 2, three, 3, sizes, &r),
           (int)CMSampleBufferCreateReady(NULL, bb, fd, 3, 1, &one, 0, NULL, &r),
           (int)CMSampleBufferCreateReady(NULL, bb, fd, 3, 1, &one, 1, (size_t[]){10}, &r));
    printf("no samples, no data %d\n", (int)CMSampleBufferCreateReady(NULL, NULL, NULL, 0, 0, NULL, 0, NULL, &r));
    if (r)
        report("  nothing", r);
    size_t four = 4;
    printf("one size for all %d\n", (int)CMSampleBufferCreateReady(NULL, bb, fd, 5, 1, &one, 1, &four, &r));
    report("  sized", r);
    CMSampleTimingInfo noDuration = {kCMTimeInvalid, CMTimeMake(3, 1), kCMTimeInvalid};
    printf("no duration %d\n", (int)CMSampleBufferCreateReady(NULL, bb, fd, 2, 1, &noDuration, 1, &four, &r));
    report("  undurated", r);

    /* output timing: trims and speed */
    CMSampleBufferCreateReady(NULL, bb, fd, 3, 1, &one, 3, sizes, &r);
    CMSetAttachment(r, kCMSampleBufferAttachmentKey_TrimDurationAtStart, (CFDictionaryRef)CMTimeCopyAsDictionary(CMTimeMake(1, 60), NULL),
                    kCMAttachmentMode_ShouldPropagate);
    CMSetAttachment(r, kCMSampleBufferAttachmentKey_SpeedMultiplier, (CFNumberRef)CFAutorelease(CFNumberCreate(NULL, kCFNumberDoubleType, &(double){2.0})),
                    kCMAttachmentMode_ShouldPropagate);
    report("trimmed and fast", r);
    printf("  set output pts %d\n", (int)CMSampleBufferSetOutputPresentationTimeStamp(r, CMTimeMake(100, 1)));
    report("  moved", r);
    CMSampleTimingInfo outs[4];
    CMItemCount n = 0;
    printf("  output timing %d", (int)CMSampleBufferGetOutputSampleTimingInfoArray(r, 4, outs, &n));
    for (CMItemCount i = 0; i < n; i++)
        printf(" %s", timing(outs[i]));
    printf("\n");

    /* audio */
    AudioStreamBasicDescription pcm = {48000, kAudioFormatLinearPCM, kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, 4, 1, 4, 2, 16, 0};
    CMAudioFormatDescriptionRef afd = NULL;
    CMAudioFormatDescriptionCreate(NULL, &pcm, 0, NULL, 0, NULL, NULL, &afd);
    CMBlockBufferRef ab = NULL;
    CMBlockBufferCreateWithMemoryBlock(NULL, NULL, 40, NULL, NULL, 0, 40, kCMBlockBufferAssureMemoryNowFlag, &ab);
    for (int i = 0; i < 20; i++)
        CMBlockBufferReplaceDataBytes(&(int16_t){(int16_t)(i * 100)}, ab, (size_t)i * 2, 2);
    CMSampleBufferRef as = NULL;
    printf("audio %d\n", (int)CMAudioSampleBufferCreateReadyWithPacketDescriptions(NULL, ab, afd, 10, CMTimeMake(480, 48000), NULL, &as));
    report("  pcm", as);
    size_t listSize = 0;
    printf("  list size %d", (int)CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(as, &listSize, NULL, 0, NULL, NULL, 0, NULL));
    printf(" %zu\n", listSize);
    AudioBufferList list;
    CMBlockBufferRef held = NULL;
    printf("  list %d", (int)CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(as, NULL, &list, sizeof list, NULL, NULL, 0, &held));
    printf(" buffers %u channels %u bytes %u first %d held %d\n", (unsigned)list.mNumberBuffers, (unsigned)list.mBuffers[0].mNumberChannels,
           (unsigned)list.mBuffers[0].mDataByteSize, ((int16_t *)list.mBuffers[0].mData)[2], held != NULL);
    int16_t pcmOut[8] = {0};
    AudioBufferList outList = {1, {{2, sizeof pcmOut, pcmOut}}};
    printf("  copy frames 3-6 %d:", (int)CMSampleBufferCopyPCMDataIntoAudioBufferList(as, 3, 4, &outList));
    for (int i = 0; i < 8; i++)
        printf(" %d", pcmOut[i]);
    printf("\n  copy past the end %d\n", (int)CMSampleBufferCopyPCMDataIntoAudioBufferList(as, 8, 4, &outList));
    AudioStreamBasicDescription aac = {44100, kAudioFormatMPEG4AAC, 0, 0, 1024, 0, 2, 0, 0};
    CMAudioFormatDescriptionRef aacfd = NULL;
    CMAudioFormatDescriptionCreate(NULL, &aac, 0, NULL, 0, NULL, NULL, &aacfd);
    AudioStreamPacketDescription packets[] = {{0, 0, 8}, {8, 0, 12}};
    printf("aac %d\n", (int)CMAudioSampleBufferCreateReadyWithPacketDescriptions(NULL, bb, aacfd, 2, CMTimeMake(0, 44100), packets, &as));
    report("  aac", as);
    const AudioStreamPacketDescription *pp = NULL;
    size_t ps = 0;
    printf("  packets %d size %zu second %lld+%u\n", (int)CMSampleBufferGetAudioStreamPacketDescriptionsPtr(as, &pp, &ps), ps, pp ? pp[1].mStartOffset : -1,
           pp ? (unsigned)pp[1].mDataByteSize : 0);
    printf("aac without packets %d\n", (int)CMAudioSampleBufferCreateReadyWithPacketDescriptions(NULL, bb, aacfd, 2, CMTimeMake(0, 44100), NULL, &as));
}

/* --- clocks and timebases --- */

static int fired;

static void
timer_fired(CFRunLoopTimerRef timer, void *info)
{
    fired++;
    CFRunLoopStop(CFRunLoopGetCurrent());
}

static void
clocks(void)
{
    CMClockRef host = CMClockGetHostTimeClock();
    uint64_t m = mach_absolute_time();
    CMTime h = CMClockGetTime(host);
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    long long ns = (long long)(m * info.numer / info.denom);
    printf("host clock: timescale %d, within a millisecond of mach time %d\n", h.timescale, llabs(h.value - ns) < 1000000);
    printf("from units %s\n", t(CMClockMakeHostTimeFromSystemUnits(24000000ull * info.denom / info.numer * info.numer / info.denom)));
    printf("to units: a second %d, a third %llu\n", CMClockConvertHostTimeToSystemUnits(CMTimeMake(1, 1)) == (uint64_t)1000000000 * info.denom / info.numer,
           (unsigned long long)CMClockConvertHostTimeToSystemUnits(CMTimeMake(1, 3)) * info.numer / info.denom);
    CMTimebaseRef tb = NULL, tb2 = NULL;
    printf("timebase %d rate %g effective %g time %s\n", (int)CMTimebaseCreateWithSourceClock(NULL, host, &tb), CMTimebaseGetRate(tb),
           CMTimebaseGetEffectiveRate(tb), t(CMTimebaseGetTime(tb)));
    printf("  set %d: %s, at 600 %s\n", (int)CMTimebaseSetTime(tb, CMTimeMake(5, 1)), t(CMTimebaseGetTime(tb)),
           t(CMTimebaseGetTimeWithTimeScale(tb, 600, kCMTimeRoundingMethod_Default)));
    printf("on it %d: %s\n", (int)CMTimebaseCreateWithSourceTimebase(NULL, tb, &tb2), t(CMTimebaseGetTime(tb2)));
    printf("  rate and anchor %d: %s rate %g effective %g\n", (int)CMTimebaseSetRateAndAnchorTime(tb2, 2.0, CMTimeMake(100, 1), CMTimeMake(5, 1)),
           t(CMTimebaseGetTime(tb2)), CMTimebaseGetRate(tb2), CMTimebaseGetEffectiveRate(tb2));
    printf("  relative rate %g, back %g\n", CMSyncGetRelativeRate(tb2, tb), CMSyncGetRelativeRate(tb, tb2));
    printf("  convert 7 up %s, 104 down %s, 7 to the clock %s\n", t(CMSyncConvertTime(CMTimeMake(7, 1), tb, tb2)),
           t(CMSyncConvertTime(CMTimeMake(104, 1), tb2, tb)), t(CMSyncConvertTime(CMTimeMake(7, 1), tb, host)));
    Float64 rr = 0;
    CMTime a, b;
    printf("  relative anchor %d", (int)CMSyncGetRelativeRateAndAnchorTime(tb2, tb, &rr, &a, &b));
    printf(" %g %s %s\n", rr, t(a), t(b));
    printf("  drift %d %d, sync time %s\n", CMSyncMightDrift(tb, tb2), CMSyncMightDrift(host, tb), t(CMSyncGetTime(tb2)));
    printf("  anchor %d: %s\n", (int)CMTimebaseSetAnchorTime(tb, CMTimeMake(10, 1), CMTimeMake(0, 1)), t(CMTimebaseGetTime(tb)));
    CMTimebaseSetRate(tb, 1.0);
    printf("  first running: on it effective %g\n", CMTimebaseGetEffectiveRate(tb2));
    CFTypeRef src = CMTimebaseCopySource(tb);
    CMClockRef ultimate = CMTimebaseCopyUltimateSourceClock(tb2);
    CMTimebaseRef srcTb = CMTimebaseCopySourceTimebase(tb2);
    printf("  sources: host %d, ultimately host %d, timebase %d, clock of a timebase-sourced one %s\n", src == host, ultimate == host, srcTb == tb,
           CMTimebaseCopySourceClock(tb2) ? "some" : "none");
    printf("  type ids %d %d %d\n", CFGetTypeID(host) == CMClockGetTypeID(), CFGetTypeID(tb) == CMTimebaseGetTypeID(),
           CMClockGetTypeID() != CMTimebaseGetTypeID());
    CMTimebaseRef none = NULL;
    CMClockRef noClock = NULL;
    printf("errors: invalid time %d, no source %d\n", (int)CMTimebaseSetTime(tb2, kCMTimeInvalid),
           (int)CMTimebaseCreateWithSourceClock(NULL, noClock, &none));

    /* a timer on a running timebase */
    CMTimebaseRef running = NULL;
    CMTimebaseCreateWithSourceClock(NULL, host, &running);
    CMTimebaseSetRate(running, 4.0);
    /* (a long interval and a far fire date, as CMTimebaseAddTimer asks) */
    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 256.0 * 365 * 24 * 3600, 256.0 * 365 * 24 * 3600, 0, 0, timer_fired, NULL);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopDefaultMode);
    printf("timer %d", (int)CMTimebaseAddTimer(running, timer, CFRunLoopGetCurrent()));
    printf(" fire at 0.4 %d", (int)CMTimebaseSetTimerNextFireTime(running, timer, CMTimeAdd(CMTimebaseGetTime(running), CMTimeMake(4, 10)), 0));
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 2, false);
    double took = CFAbsoluteTimeGetCurrent() - start;
    printf(" fired %d after about a tenth %d\n", fired, took > 0.05 && took < 0.5);
    printf("  remove %d again %d\n", (int)CMTimebaseRemoveTimer(running, timer), (int)CMTimebaseRemoveTimer(running, timer));
}

/* --- queues and memory pools --- */

static CMSampleBufferRef
sample_at(int pts, int duration, size_t size)
{
    CMSampleTimingInfo t = {CMTimeMake(duration, 10), CMTimeMake(pts, 10), CMTimeMake(pts, 10)};
    CMSampleBufferRef sb = NULL;
    CMSampleBufferCreateReady(NULL, NULL, NULL, 1, 1, &t, 1, &size, &sb);
    return sb;
}

/* (triggers that fire together are printed sorted: Apple's order among them varies) */
static const char *fired_triggers[16];
static int fired_count;

static void
trigger(void *refcon, CMBufferQueueTriggerToken token)
{
    if (fired_count < 16)
        fired_triggers[fired_count++] = refcon;
}

static int
by_name(const void *a, const void *b)
{
    return strcmp(*(const char *const *)a, *(const char *const *)b);
}

static void
flush_triggers(void)
{
    qsort(fired_triggers, (size_t)fired_count, sizeof fired_triggers[0], by_name);
    for (int i = 0; i < fired_count; i++)
        printf("    trigger %s\n", fired_triggers[i]);
    fired_count = 0;
}

static OSStatus
each_buffer(CMBufferRef b, void *refcon)
{
    printf("    buffer at %s\n", t(CMSampleBufferGetPresentationTimeStamp((CMSampleBufferRef)b)));
    return 0;
}

static void
queue_state(const char *label, CMBufferQueueRef q)
{
    printf("  %s: count %ld empty %d duration %s total size %zu\n", label, (long)CMBufferQueueGetBufferCount(q), CMBufferQueueIsEmpty(q),
           t(CMBufferQueueGetDuration(q)), CMBufferQueueGetTotalSize(q));
    printf("    first pts %s min pts %s max pts %s end pts %s\n", t(CMBufferQueueGetFirstPresentationTimeStamp(q)),
           t(CMBufferQueueGetMinPresentationTimeStamp(q)), t(CMBufferQueueGetMaxPresentationTimeStamp(q)),
           t(CMBufferQueueGetEndPresentationTimeStamp(q)));
    printf("    first dts %s min dts %s\n", t(CMBufferQueueGetFirstDecodeTimeStamp(q)), t(CMBufferQueueGetMinDecodeTimeStamp(q)));
}

static void
queues(void)
{
    CMSimpleQueueRef sq = NULL;
    printf("simple queue %d capacity %d count %d\n", (int)CMSimpleQueueCreate(NULL, 3, &sq), (int)CMSimpleQueueGetCapacity(sq),
           (int)CMSimpleQueueGetCount(sq));
    printf("  enqueue %d %d %d %d\n", (int)CMSimpleQueueEnqueue(sq, (void *)1), (int)CMSimpleQueueEnqueue(sq, (void *)2),
           (int)CMSimpleQueueEnqueue(sq, (void *)3), (int)CMSimpleQueueEnqueue(sq, (void *)4));
    printf("  head %ld count %d dequeue %ld %ld head %ld\n", (long)CMSimpleQueueGetHead(sq), (int)CMSimpleQueueGetCount(sq),
           (long)CMSimpleQueueDequeue(sq), (long)CMSimpleQueueDequeue(sq), (long)CMSimpleQueueGetHead(sq));
    printf("  wrap %d %d count %d\n", (int)CMSimpleQueueEnqueue(sq, (void *)5), (int)CMSimpleQueueEnqueue(sq, (void *)6), (int)CMSimpleQueueGetCount(sq));
    printf("  order %ld %ld %ld %ld\n", (long)CMSimpleQueueDequeue(sq), (long)CMSimpleQueueDequeue(sq), (long)CMSimpleQueueDequeue(sq),
           (long)CMSimpleQueueDequeue(sq));
    const void *nothing = NULL;
    printf("  null element %d reset %d count %d\n", (int)CMSimpleQueueEnqueue(sq, nothing), (int)CMSimpleQueueReset(sq), (int)CMSimpleQueueGetCount(sq));
    CMSimpleQueueRef bad = NULL;
    printf("  zero capacity %d negative %d type %d\n", (int)CMSimpleQueueCreate(NULL, 0, &bad), (int)CMSimpleQueueCreate(NULL, -1, &bad),
           CFGetTypeID(sq) == CMSimpleQueueGetTypeID());

    CMBufferQueueRef q = NULL;
    printf("buffer queue, unsorted %d\n", (int)CMBufferQueueCreate(NULL, 0, CMBufferQueueGetCallbacksForUnsortedSampleBuffers(), &q));
    flush_triggers();
    queue_state("empty", q);
    CMBufferQueueTriggerToken t1, t2, t3, t4;
    printf("  install %d", (int)CMBufferQueueInstallTrigger(q, trigger, "count over 2", kCMBufferQueueTrigger_WhenBufferCountBecomesGreaterThan,
                                                            CMTimeMake(2, 1), &t1));
    printf(" %d", (int)CMBufferQueueInstallTrigger(q, trigger, "duration under 0.3", kCMBufferQueueTrigger_WhenDurationBecomesLessThan, CMTimeMake(3, 10), &t2));
    flush_triggers();
    printf(" %d", (int)CMBufferQueueInstallTrigger(q, trigger, "end of data", kCMBufferQueueTrigger_WhenEndOfDataReached, kCMTimeZero, &t3));
    flush_triggers();
    printf(" %d\n", (int)CMBufferQueueInstallTriggerWithIntegerThreshold(q, trigger, "count under 2", kCMBufferQueueTrigger_WhenBufferCountBecomesLessThan,
                                                                      2, &t4));
    CMBufferQueueTriggerToken t5 = NULL, t6 = NULL;
    printf("  install count over 2 by integer %d", (int)CMBufferQueueInstallTriggerWithIntegerThreshold(
                                                   q, trigger, "count over 2 (integer)", kCMBufferQueueTrigger_WhenBufferCountBecomesGreaterThan, 2, &t5));
    printf(" duration by integer %d", (int)CMBufferQueueInstallTriggerWithIntegerThreshold(
                                          q, trigger, "duration (integer)", kCMBufferQueueTrigger_WhenDurationBecomesLessThan, 2, &t6));
    printf(" bad condition %d\n", (int)CMBufferQueueInstallTrigger(q, trigger, "bad", 99, kCMTimeZero, &t6));
    flush_triggers();
    printf("  test triggers %d %d %d %d\n", CMBufferQueueTestTrigger(q, t1), CMBufferQueueTestTrigger(q, t2), CMBufferQueueTestTrigger(q, t3),
           CMBufferQueueTestTrigger(q, t4));
    int pts[] = {5, 2, 8, 3};
    for (int i = 0; i < 4; i++) {
        CMSampleBufferRef sb = sample_at(pts[i], 1 + i, 10 * (size_t)(i + 1));
        printf("  enqueue at %d: %d\n", pts[i], (int)CMBufferQueueEnqueue(q, sb));
        flush_triggers();
        CFRelease(sb);
    }
    queue_state("four", q);
    printf("  for each %d\n", (int)CMBufferQueueCallForEachBuffer(q, each_buffer, NULL));
    flush_triggers();
    CMBufferRef head = CMBufferQueueCopyHead(q);
    printf("  head at %s\n", t(CMSampleBufferGetPresentationTimeStamp((CMSampleBufferRef)head)));
    flush_triggers();
    CFRelease(head);
    CMBufferRef d = CMBufferQueueDequeueAndRetain(q);
    printf("  dequeued at %s\n", t(CMSampleBufferGetPresentationTimeStamp((CMSampleBufferRef)d)));
    flush_triggers();
    CFRelease(d);
    flush_triggers();
    queue_state("three", q);
    printf("  mark end %d contains %d at end %d\n", (int)CMBufferQueueMarkEndOfData(q), CMBufferQueueContainsEndOfData(q), CMBufferQueueIsAtEndOfData(q));
    flush_triggers();
    CMSampleBufferRef late = sample_at(9, 1, 1);
    printf("  enqueue after end %d\n", (int)CMBufferQueueEnqueue(q, late));
    flush_triggers();
    while ((d = CMBufferQueueDequeueIfDataReadyAndRetain(q))) {
        printf("  dequeued at %s\n", t(CMSampleBufferGetPresentationTimeStamp((CMSampleBufferRef)d)));
        flush_triggers();
        CFRelease(d);
        flush_triggers();
    }
    printf("  at end %d, test end trigger %d\n", CMBufferQueueIsAtEndOfData(q), CMBufferQueueTestTrigger(q, t3));
    flush_triggers();
    printf("  remove trigger %d again %d\n", (int)CMBufferQueueRemoveTrigger(q, t1), (int)CMBufferQueueRemoveTrigger(q, t1));
    flush_triggers();
    printf("  reset %d contains end %d\n", (int)CMBufferQueueReset(q), CMBufferQueueContainsEndOfData(q));
    flush_triggers();
    CFRelease(q);

    printf("buffer queue, sorted by output time %d\n", (int)CMBufferQueueCreate(NULL, 2, CMBufferQueueGetCallbacksForSampleBuffersSortedByOutputPTS(), &q));
    flush_triggers();
    for (int i = 0; i < 3; i++) {
        CMSampleBufferRef sb = sample_at(pts[i], 1, 1);
        printf("  enqueue at %d: %d\n", pts[i], (int)CMBufferQueueEnqueue(q, sb));
        flush_triggers();
        CFRelease(sb);
    }
    queue_state("sorted", q);
    printf("  for each %d\n", (int)CMBufferQueueCallForEachBuffer(q, each_buffer, NULL));
    flush_triggers();
    CFRelease(q);

    CMMemoryPoolRef pool = CMMemoryPoolCreate(NULL);
    CFAllocatorRef pa = CMMemoryPoolGetAllocator(pool);
    void *p1 = CFAllocatorAllocate(pa, 1000, 0);
    memset(p1, 1, 1000);
    CFAllocatorDeallocate(pa, p1);
    void *p2 = CFAllocatorAllocate(pa, 1000, 0);
    printf("memory pool: type %d, block reused %d\n", CFGetTypeID(pool) == CMMemoryPoolGetTypeID(), p1 == p2);
    CFAllocatorDeallocate(pa, p2);
    CMMemoryPoolFlush(pool);
    CMMemoryPoolInvalidate(pool);
    void *p3 = CFAllocatorAllocate(pa, 64, 0);
    printf("  after invalidating, allocates %d\n", p3 != NULL);
    CFAllocatorDeallocate(pa, p3);
    CFRelease(pool);
}

/* --- format descriptions from parameter sets --- */

static size_t
from_hex(const char *h, uint8_t *out)
{
    size_t n = 0;
    while (h[0] && h[1]) {
        unsigned v;
        sscanf(h, "%2x", &v);
        out[n++] = (uint8_t)v;
        h += 2;
    }
    return n;
}

static void
atoms(CMFormatDescriptionRef fd)
{
    CFDictionaryRef a = CMFormatDescriptionGetExtension(fd, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms);
    if (!a)
        return;
    CFIndex n = CFDictionaryGetCount(a);
    const void *k[4], *v[4];
    CFDictionaryGetKeysAndValues(a, k, v);
    for (CFIndex i = 0; i < n && i < 4; i++) {
        printf("  atom %s: ", desc(k[i]));
        for (CFIndex j = 0; j < CFDataGetLength(v[i]); j++)
            printf("%02x", CFDataGetBytePtr(v[i])[j]);
        printf("\n");
    }
}

static void
parameter_sets(void)
{
    /* (sets Apple's encoder made, 640x480 and 1920x1080 H.264 and 1280x720 HEVC) */
    const char *h264[][2] = {{"2764001eac5650280f64", "28ee3cb0"}, {"27640028ac56501e0089f950", "28ee3cb0"},
                             {"6742c01e95a0280f6400", "68ce3c80"}};
    for (int i = 0; i < 3; i++) {
        uint8_t a[64], b[64];
        size_t sa = from_hex(h264[i][0], a), sb = from_hex(h264[i][1], b);
        const uint8_t *p[] = {a, b};
        size_t sz[] = {sa, sb};
        CMFormatDescriptionRef fd = NULL;
        printf("h264 %d\n", (int)CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL, 2, p, sz, 4, &fd));
        if (!fd)
            continue;
        show("  description", fd);
        atoms(fd);
        size_t n = 0, qs = 0;
        int nal = 0;
        const uint8_t *q = NULL;
        printf("  get second %d", (int)CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, 1, &q, &qs, &n, &nal));
        printf(" count %zu nal %d size %zu same %d", n, nal, qs, q && qs == sb && !memcmp(q, b, sb));
        printf(" third %d\n", (int)CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, 2, &q, &qs, NULL, NULL));
        CFRelease(fd);
    }
    uint8_t v[64], sp[64], pp[64];
    size_t sv = from_hex("40010c01ffff016000000300b0000003000003005d15c090", v);
    size_t ss = from_hex("420101016000000300b0000003000003005da00280802d162057b9165440", sp);
    size_t spp = from_hex("4401c02cbc14c9", pp);
    const uint8_t *hp[] = {v, sp, pp};
    size_t hs[] = {sv, ss, spp};
    CMFormatDescriptionRef fd = NULL;
    printf("hevc %d\n", (int)CMVideoFormatDescriptionCreateFromHEVCParameterSets(NULL, 3, hp, hs, 4, NULL, &fd));
    if (fd) {
        show("  description", fd);
        atoms(fd);
        size_t n = 0, qs = 0;
        int nal = 0;
        const uint8_t *q = NULL;
        printf("  get pps %d", (int)CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, 2, &q, &qs, &n, &nal));
        printf(" count %zu nal %d size %zu same %d\n", n, nal, qs, q && qs == spp && !memcmp(q, pp, spp));
        printf("  as H.264 %d\n", (int)CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, 0, &q, &qs, &n, &nal));
    }
    const uint8_t *one[] = {v};
    printf("errors: one set %d, a header length of 3 %d, HEVC without a sequence set %d\n",
           (int)CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL, 1, one, &sv, 4, &fd),
           (int)CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL, 2, hp, hs, 3, &fd),
           (int)CMVideoFormatDescriptionCreateFromHEVCParameterSets(NULL, 3, (const uint8_t *[]){v, pp, pp}, (size_t[]){sv, spp, spp}, 4, NULL, &fd));
}

/* --- metadata --- */

static void
metadata(void)
{
    struct {
        CFTypeRef key;
        CFStringRef space;
    } pairs[] = {{CFSTR("com.apple.quicktime.title"), kCMMetadataKeySpace_QuickTimeMetadata},
                 {CFSTR("weird/key%"), kCMMetadataKeySpace_QuickTimeMetadata},
                 {CFSTR("TIT2"), kCMMetadataKeySpace_ID3},
                 {CFSTR("©nam"), kCMMetadataKeySpace_iTunes},
                 {CFSTR("x"), CFSTR("toolongkeyspace")},
                 {CFSTR("abc"), kCMMetadataKeySpace_iTunes},
                 {CFSTR("café"), kCMMetadataKeySpace_QuickTimeMetadata},
                 {CFSTR("icy"), kCMMetadataKeySpace_Icy}};
    for (size_t i = 0; i < sizeof pairs / sizeof pairs[0]; i++) {
        CFStringRef id = NULL;
        OSStatus e = CMMetadataCreateIdentifierForKeyAndKeySpace(NULL, pairs[i].key, pairs[i].space, &id);
        printf("identifier %d %s\n", (int)e, desc(id));
    }
    int code = (int)0xa96e616d;
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &code);
    CFDataRef data = CFDataCreate(NULL, (const UInt8 *)"\xa9nam", 4);
    CFStringRef id = NULL;
    printf("from a number %d", (int)CMMetadataCreateIdentifierForKeyAndKeySpace(NULL, number, kCMMetadataKeySpace_iTunes, &id));
    printf(" %s", desc(id));
    printf(" from data %d", (int)CMMetadataCreateIdentifierForKeyAndKeySpace(NULL, data, kCMMetadataKeySpace_iTunes, &id));
    printf(" %s", desc(id));
    printf(" a number for a string space %d\n", (int)CMMetadataCreateIdentifierForKeyAndKeySpace(NULL, number, kCMMetadataKeySpace_QuickTimeMetadata, &id));
    CFStringRef ids[] = {CFSTR("mdta/com.apple.quicktime.title"), CFSTR("itsk/%A9nam"), CFSTR("id3/TIT2"), CFSTR("udta/%A9day"), CFSTR("bad"),
                         CFSTR("mdta/a%2Fb"), CFSTR("mdta/"), CFSTR("/x")};
    for (size_t i = 0; i < sizeof ids / sizeof ids[0]; i++) {
        CFTypeRef key = NULL;
        CFStringRef space = NULL;
        CFDataRef bytes = NULL;
        OSStatus e1 = CMMetadataCreateKeyFromIdentifier(NULL, ids[i], &key), e2 = CMMetadataCreateKeySpaceFromIdentifier(NULL, ids[i], &space),
                 e3 = CMMetadataCreateKeyFromIdentifierAsCFData(NULL, ids[i], &bytes);
        char k[256] = "(null)";
        if (key && CFGetTypeID(key) == CFNumberGetTypeID()) {
            int v;
            CFNumberGetValue(key, kCFNumberIntType, &v);
            snprintf(k, sizeof k, "number %d", v);
        } else if (key)
            snprintf(k, sizeof k, "%s", desc(key));
        printf("%s: key %d %s, space %d %s, bytes %d %ld\n", desc(ids[i]), (int)e1, k, (int)e2, desc(space), (int)e3,
               bytes ? (long)CFDataGetLength(bytes) : -1L);
    }
    show("base types", CMMetadataDataTypeRegistryGetBaseDataTypes());
    printf("registered %d %d\n", CMMetadataDataTypeRegistryDataTypeIsRegistered(kCMMetadataBaseDataType_UTF8),
           CMMetadataDataTypeRegistryDataTypeIsRegistered(CFSTR("com.example.x")));
    const void *utf8[] = {kCMMetadataBaseDataType_UTF8};
    CFArrayRef conforms = CFArrayCreate(NULL, utf8, 1, &kCFTypeArrayCallBacks);
    printf("register %d again %d\n", (int)CMMetadataDataTypeRegistryRegisterDataType(CFSTR("com.example.x"), CFSTR("an example"), conforms),
           (int)CMMetadataDataTypeRegistryRegisterDataType(CFSTR("com.example.x"), CFSTR("an example"), conforms));
    printf("conforms %d %d base %d %d\n", CMMetadataDataTypeRegistryDataTypeConformsToDataType(CFSTR("com.example.x"), kCMMetadataBaseDataType_UTF8),
           CMMetadataDataTypeRegistryDataTypeConformsToDataType(kCMMetadataBaseDataType_UTF8, CFSTR("com.example.x")),
           CMMetadataDataTypeRegistryDataTypeIsBaseDataType(kCMMetadataBaseDataType_UTF8),
           CMMetadataDataTypeRegistryDataTypeIsBaseDataType(CFSTR("com.example.x")));
    printf("description %s, base %s, UTF-8's %s\n", desc(CMMetadataDataTypeRegistryGetDataTypeDescription(CFSTR("com.example.x"))),
           desc(CMMetadataDataTypeRegistryGetBaseDataTypeForConformingDataType(CFSTR("com.example.x"))),
           desc(CMMetadataDataTypeRegistryGetDataTypeDescription(kCMMetadataBaseDataType_UTF8)));
    CFStringRef named[] = {kCMMetadataDataType_QuickTimeMetadataLocation_ISO6709, kCMMetadataDataType_QuickTimeMetadataDirection,
                           kCMMetadataBaseDataType_RawData, kCMMetadataBaseDataType_PolygonF32};
    for (size_t i = 0; i < 4; i++)
        printf("%s: %s, conforms to %s\n", desc(named[i]), desc(CMMetadataDataTypeRegistryGetDataTypeDescription(named[i])),
               desc(CMMetadataDataTypeRegistryGetConformingDataTypes(named[i])));

    CFStringRef specKeys[] = {kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier, kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType};
    CFTypeRef s1v[] = {CFSTR("mdta/com.apple.quicktime.title"), kCMMetadataBaseDataType_UTF8};
    CFTypeRef s2v[] = {CFSTR("mdta/com.apple.quicktime.location.ISO6709"), kCMMetadataDataType_QuickTimeMetadataLocation_ISO6709};
    CFTypeRef s3v[] = {CFSTR("udta/%A9day"), kCMMetadataBaseDataType_SInt32};
    CFDictionaryRef s1 = CFDictionaryCreate(NULL, (const void **)specKeys, s1v, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionaryRef s2 = CFDictionaryCreate(NULL, (const void **)specKeys, s2v, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionaryRef s3 = CFDictionaryCreate(NULL, (const void **)specKeys, s3v, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFArrayRef specs = CFArrayCreate(NULL, (const void *[]){s1, s2}, 2, &kCFTypeArrayCallBacks);
    CMMetadataFormatDescriptionRef fd = NULL, more = NULL, merged = NULL;
    printf("metadata format %d\n", (int)CMMetadataFormatDescriptionCreateWithMetadataSpecifications(NULL, kCMMetadataFormatType_Boxed, specs, &fd));
    show("  description", fd);
    show("  identifiers", CMMetadataFormatDescriptionGetIdentifiers(fd));
    show("  key 2", CMMetadataFormatDescriptionGetKeyWithLocalID(fd, 2));
    show("  key 3", CMMetadataFormatDescriptionGetKeyWithLocalID(fd, 3));
    CFArrayRef three = CFArrayCreate(NULL, (const void *[]){s3, s1}, 2, &kCFTypeArrayCallBacks);
    printf("extended %d\n", (int)CMMetadataFormatDescriptionCreateWithMetadataFormatDescriptionAndMetadataSpecifications(NULL, fd, three, &more));
    show("  identifiers", CMMetadataFormatDescriptionGetIdentifiers(more));
    CMMetadataFormatDescriptionRef other = NULL;
    CMMetadataFormatDescriptionCreateWithMetadataSpecifications(NULL, kCMMetadataFormatType_Boxed,
                                                                CFArrayCreate(NULL, (const void *[]){s3, s1}, 2, &kCFTypeArrayCallBacks), &other);
    printf("merged %d\n", (int)CMMetadataFormatDescriptionCreateByMergingMetadataFormatDescriptions(NULL, fd, other, &merged));
    show("  identifiers", CMMetadataFormatDescriptionGetIdentifiers(merged));
    CMMetadataFormatDescriptionRef id3 = NULL;
    printf("id3 %d\n", (int)CMMetadataFormatDescriptionCreateWithKeys(NULL, kCMMetadataFormatType_ID3, NULL, &id3));
    show("  description", id3);
    printf("unknown data type %d\n",
           (int)CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
               NULL, kCMMetadataFormatType_Boxed,
               CFArrayCreate(NULL,
                             (const void *[]){CFDictionaryCreate(NULL, (const void **)specKeys, (const void *[]){CFSTR("mdta/x"), CFSTR("com.nope")}, 2,
                                                                 &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks)},
                             1, &kCFTypeArrayCallBacks),
               &other));
}

/* --- tags --- */

static void
tag(const char *label, CMTag x)
{
    CFStringRef d = CMTagCopyDescription(NULL, x);
    printf("%s: %s (category %x type %d) int %lld float %g ostype %x flags %llx\n", label, desc(d), (unsigned)x.category, (int)x.dataType,
           (long long)CMTagGetSInt64Value(x), CMTagGetFloat64Value(x), (unsigned)CMTagGetOSTypeValue(x), (unsigned long long)CMTagGetFlagsValue(x));
    CFRelease(d);
}

static void
tags(void)
{
    tag("invalid", kCMTagInvalid);
    tag("video", kCMTagMediaTypeVideo);
    tag("left", kCMTagStereoLeftEye);
    tag("both", kCMTagStereoLeftAndRightEye);
    tag("int", CMTagMakeWithSInt64Value(kCMTagCategory_VideoLayerID, -5));
    tag("float", CMTagMakeWithFloat64Value('abcd', 1.5));
    tag("ostype", CMTagMakeWithOSTypeValue(kCMTagCategory_MediaType, 'soun'));
    tag("projection", kCMTagProjectionTypeEquirectangular);
    tag("packing", kCMTagPackingTypeSideBySide);
    CMTag a = CMTagMakeWithSInt64Value('aaaa', 1), b = CMTagMakeWithSInt64Value('aaaa', 2), c = CMTagMakeWithFloat64Value('aaaa', 1),
          d = CMTagMakeWithSInt64Value('bbbb', 0), neg = CMTagMakeWithSInt64Value('aaaa', -1);
    printf("compare %d %d %d %d %d %d equal %d %d\n", (int)CMTagCompare(a, b), (int)CMTagCompare(b, a), (int)CMTagCompare(a, c), (int)CMTagCompare(a, d),
           (int)CMTagCompare(a, a), (int)CMTagCompare(neg, a), CMTagEqualToTag(a, a), CMTagEqualToTag(a, c));
    show("tag dictionary", CMTagCopyAsDictionary(CMTagMakeWithFloat64Value('aaaa', 1.25), NULL));
    tag("back", CMTagMakeFromDictionary(CMTagCopyAsDictionary(CMTagMakeWithFloat64Value('aaaa', 1.25), NULL)));
    tag("from nothing", CMTagMakeFromDictionary(dict(0)));
    CMTag list[] = {kCMTagStereoRightEye, kCMTagMediaTypeVideo, kCMTagStereoLeftEye, kCMTagMediaTypeVideo,
                    CMTagMakeWithSInt64Value(kCMTagCategory_VideoLayerID, 7)};
    CMTagCollectionRef col = NULL;
    printf("collection %d count %ld\n", (int)CMTagCollectionCreate(NULL, list, 5, &col), (long)CMTagCollectionGetCount(col));
    show("  description", col);
    show("  dictionary", CMTagCollectionCopyAsDictionary(col, NULL));
    CFDataRef data = CMTagCollectionCopyAsData(col, NULL);
    printf("  data %ld: ", (long)CFDataGetLength(data));
    for (CFIndex i = 0; i < CFDataGetLength(data); i++)
        printf("%02x", CFDataGetBytePtr(data)[i]);
    CMTagCollectionRef fromData = NULL, fromDict = NULL;
    printf("\n  from data %d equal %d", (int)CMTagCollectionCreateFromData(data, NULL, &fromData), fromData && CFEqual(fromData, col));
    printf(" from dictionary %d equal %d\n", (int)CMTagCollectionCreateFromDictionary(CMTagCollectionCopyAsDictionary(col, NULL), NULL, &fromDict),
           fromDict && CFEqual(fromDict, col));
    CMTag got[8];
    CMItemCount n = 0;
    printf("  get %d %ld small %d", (int)CMTagCollectionGetTags(col, got, 8, &n), (long)n, (int)CMTagCollectionGetTags(col, got, 2, &n));
    printf(" %ld of category %ld", (long)n, (long)CMTagCollectionGetCountOfCategory(col, kCMTagCategory_StereoView));
    printf(" with category %d", (int)CMTagCollectionGetTagsWithCategory(col, kCMTagCategory_StereoView, got, 8, &n));
    printf(" %ld contains %d %d category %d %d\n", (long)n, CMTagCollectionContainsTag(col, kCMTagStereoLeftEye),
           CMTagCollectionContainsTag(col, kCMTagStereoNone), CMTagCollectionContainsCategory(col, kCMTagCategory_PackingType),
           CMTagCollectionContainsCategory(col, kCMTagCategory_VideoLayerID));
    CMTagCollectionRef other = NULL, r = NULL;
    CMTag ot[] = {kCMTagStereoLeftEye, kCMTagPackingTypeNone};
    CMTagCollectionCreate(NULL, ot, 2, &other);
    CMTagCollectionCreateUnion(col, other, &r);
    show("  union", r);
    CMTagCollectionCreateIntersection(col, other, &r);
    show("  intersection", r);
    CMTagCollectionCreateDifference(col, other, &r);
    show("  difference", r);
    CMTagCollectionCreateExclusiveOr(col, other, &r);
    show("  exclusive or", r);
    CMTagCategory cats[] = {kCMTagCategory_StereoView, kCMTagCategory_PackingType};
    CMTagCollectionCopyTagsOfCategories(NULL, col, cats, 2, &r);
    show("  of categories", r);
    printf("  contains other %d its own copy %d\n", CMTagCollectionContainsTagsOfCollection(col, other), CMTagCollectionContainsTagsOfCollection(col, fromData));
    CMMutableTagCollectionRef m = NULL;
    CMTagCollectionCreateMutable(NULL, 0, &m);
    printf("mutable: add %d %d remove %d %d", (int)CMTagCollectionAddTag(m, kCMTagStereoLeftEye), (int)CMTagCollectionAddTag(m, kCMTagStereoLeftEye),
           (int)CMTagCollectionRemoveTag(m, kCMTagStereoRightEye), (int)CMTagCollectionRemoveTag(m, kCMTagStereoLeftEye));
    printf(" to immutable %d invalid tag %d empty %d\n", (int)CMTagCollectionAddTag((CMMutableTagCollectionRef)col, kCMTagStereoNone),
           (int)CMTagCollectionAddTag(m, kCMTagInvalid), CMTagCollectionIsEmpty(m));
    CMTagCollectionAddTagsFromCollection(m, col);
    CMTagCollectionRemoveAllTagsOfCategory(m, kCMTagCategory_StereoView);
    show("  after adding and removing eyes", m);
    printf("bad data %d\n", (int)CMTagCollectionCreateFromData(CFDataCreate(NULL, (const UInt8 *)"12345678", 8), NULL, &r));

    CVPixelBufferRef left = NULL, right = NULL;
    CVPixelBufferCreate(NULL, 8, 8, kCVPixelFormatType_32BGRA, NULL, &left);
    CVPixelBufferCreate(NULL, 8, 8, kCVPixelFormatType_32BGRA, NULL, &right);
    CMTagCollectionRef lc = NULL, rc = NULL;
    CMTagCollectionCreate(NULL, (CMTag[]){kCMTagStereoLeftEye, kCMTagMediaTypeVideo}, 2, &lc);
    CMTagCollectionCreate(NULL, (CMTag[]){kCMTagStereoRightEye, kCMTagMediaTypeVideo}, 2, &rc);
    CFArrayRef cols = CFArrayCreate(NULL, (const void *[]){lc, rc}, 2, &kCFTypeArrayCallBacks);
    CFArrayRef bufs = CFArrayCreate(NULL, (const void *[]){left, right}, 2, &kCFTypeArrayCallBacks);
    CMTaggedBufferGroupRef group = NULL;
    printf("group %d count %ld", (int)CMTaggedBufferGroupCreate(NULL, cols, bufs, &group), (long)CMTaggedBufferGroupGetCount(group));
    CFIndex at = -1;
    printf(" right is %d at %ld", CMTaggedBufferGroupGetCVPixelBufferForTag(group, kCMTagStereoRightEye, &at) == right, (long)at);
    printf(" video matches %ld, ambiguous %d, first %d sample %d\n", (long)CMTaggedBufferGroupGetNumberOfMatchesForTagCollection(group, lc),
           CMTaggedBufferGroupGetCVPixelBufferForTag(group, kCMTagMediaTypeVideo, NULL) != NULL, CMTaggedBufferGroupGetCVPixelBufferAtIndex(group, 0) == left,
           CMTaggedBufferGroupGetCMSampleBufferAtIndex(group, 0) != NULL);
    printf("  mismatched arrays %d\n", (int)CMTaggedBufferGroupCreate(NULL, cols, CFArrayCreate(NULL, (const void *[]){left}, 1, &kCFTypeArrayCallBacks), &group));
    CMTaggedBufferGroupFormatDescriptionRef gfd = NULL;
    printf("  format %d", (int)CMTaggedBufferGroupFormatDescriptionCreateForTaggedBufferGroup(NULL, group, &gfd));
    printf(" type %x sub %x matches %d\n", (unsigned)CMFormatDescriptionGetMediaType(gfd), (unsigned)CMFormatDescriptionGetMediaSubType(gfd),
           CMTaggedBufferGroupFormatDescriptionMatchesTaggedBufferGroup(gfd, group));
    CMSampleBufferRef gsb = NULL;
    printf("  sample buffer %d", (int)CMSampleBufferCreateForTaggedBufferGroup(NULL, group, CMTimeMake(1, 30), CMTimeMake(1, 30), gfd, &gsb));
    printf(" group %d samples %ld\n", CMSampleBufferGetTaggedBufferGroup(gsb) == group, (long)CMSampleBufferGetNumSamples(gsb));
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
    formats();
    samples();
    clocks();
    queues();
    parameter_sets();
    metadata();
    tags();
    return 0;
}
