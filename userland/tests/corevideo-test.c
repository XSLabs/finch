/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-corevideo-test: CoreVideo, run against Apple's and Finch's to compare
 * (tools/host-tests.sh): pixel buffer layouts (row bytes, plane offsets and sizes, the
 * planar header) across formats, sizes and attributes; buffers over the caller's bytes
 * and IOSurfaces; locking; attachments and image buffer geometry; pools; pixel format
 * descriptions; color code points and color spaces.
 */
#include <CoreVideo/CoreVideo.h>
#include <IOSurface/IOSurface.h>
#include <dlfcn.h>
#include <libkern/OSByteOrder.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* A description with its pointers masked and the fill callbacks (pointers) left out. */
static void
show(const char *label, CFTypeRef x)
{
    if (!x) {
        printf("%s: NULL\n", label);
        return;
    }
    if (CFGetTypeID(x) == CFDictionaryGetTypeID() && CFDictionaryContainsKey(x, kCVPixelFormatFillExtendedPixelsCallback)) {
        CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(NULL, 0, x);
        CFDictionaryRemoveValue(m, kCVPixelFormatFillExtendedPixelsCallback);
        show(label, m);
        CFRelease(m);
        return;
    }
    CFStringRef s = CFCopyDescription(x);
    static char buf[65536], out[65536];
    CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8);
    CFRelease(s);
    char *o = out;
    for (char *p = buf; *p;) {
        if (p[0] == '0' && p[1] == 'x' && strspn(p + 2, "0123456789abcdef") >= 5) {
            p += 2 + strspn(p + 2, "0123456789abcdef");
            o += sprintf(o, "0x?");
        } else
            *o++ = *p++;
    }
    *o = 0;
    printf("%s: %s\n", label, out);
}

static CFNumberRef
num(long long v)
{
    return CFNumberCreate(NULL, kCFNumberLongLongType, &v);
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

static const char *
code(OSType f)
{
    static char b[8][16];
    static int at;
    char *s = b[at++ % 8];
    if (f < 0x20202020)
        snprintf(s, 16, "%u", (unsigned)f);
    else
        snprintf(s, 16, "%c%c%c%c", (char)(f >> 24), (char)(f >> 16), (char)(f >> 8), (char)f);
    return s;
}

static void
layout(const char *label, OSType f, size_t w, size_t h, CFDictionaryRef attrs)
{
    CVPixelBufferRef b = NULL;
    CVReturn e = CVPixelBufferCreate(NULL, w, h, f, attrs, &b);
    printf("%s %s %zux%zu: %d", label, code(f), w, h, e);
    if (!b) {
        printf("\n");
        return;
    }
    CVPixelBufferLockBaseAddress(b, 0);
    size_t l, r, t, bo;
    CVPixelBufferGetExtendedPixels(b, &l, &r, &t, &bo);
    printf(" bpr %zu size %zu planar %d planes %zu ext %zu %zu %zu %zu surface %d", CVPixelBufferGetBytesPerRow(b), CVPixelBufferGetDataSize(b),
           CVPixelBufferIsPlanar(b), CVPixelBufferGetPlaneCount(b), l, r, t, bo, CVPixelBufferGetIOSurface(b) != NULL);
    char *base = CVPixelBufferGetBaseAddress(b);
    for (size_t i = 0; i < CVPixelBufferGetPlaneCount(b); i++) {
        char *p = CVPixelBufferGetBaseAddressOfPlane(b, i);
        printf(" [%zux%zu bpr %zu at %td", CVPixelBufferGetWidthOfPlane(b, i), CVPixelBufferGetHeightOfPlane(b, i),
               CVPixelBufferGetBytesPerRowOfPlane(b, i), p - base);
        /* (the planar header: each plane's offset and row bytes, big-endian) */
        uint32_t *info = (uint32_t *)(base + 8 * i);
        printf(" header %u %u]", OSSwapBigToHostInt32(info[0]), OSSwapBigToHostInt32(info[1]));
    }
    printf(" aligned %d\n", ((uintptr_t)base & 15) == 0);
    CVPixelBufferUnlockBaseAddress(b, 0);
    CFRelease(b);
}

static void
layouts(void)
{
    const OSType formats[] = {kCVPixelFormatType_32BGRA,
                              kCVPixelFormatType_32ARGB,
                              kCVPixelFormatType_24RGB,
                              kCVPixelFormatType_16LE565,
                              kCVPixelFormatType_OneComponent8,
                              kCVPixelFormatType_OneComponent16Half,
                              kCVPixelFormatType_TwoComponent8,
                              kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                              kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                              kCVPixelFormatType_420YpCbCr8Planar,
                              kCVPixelFormatType_422YpCbCr8,
                              kCVPixelFormatType_422YpCbCr8_yuvs,
                              kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
                              kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange,
                              kCVPixelFormatType_64RGBAHalf,
                              kCVPixelFormatType_128RGBAFloat,
                              kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                              kCVPixelFormatType_DepthFloat32,
                              kCVPixelFormatType_1Monochrome,
                              kCVPixelFormatType_30RGB,
                              kCVPixelFormatType_32RGBA,
                              kCVPixelFormatType_48RGB,
                              kCVPixelFormatType_4444AYpCbCr8,
                              kCVPixelFormatType_420YpCbCr8VideoRange_8A_TriPlanar,
                              'abcd'};
    const size_t sizes[][2] = {{100, 50}, {1, 1}, {641, 481}, {17, 3}};
    for (size_t i = 0; i < sizeof formats / sizeof formats[0]; i++)
        for (size_t s = 0; s < 4; s++)
            layout("plain", formats[i], sizes[s][0], sizes[s][1], NULL);
    CFDictionaryRef io = dict(1, kCVPixelBufferIOSurfacePropertiesKey, dict(0));
    layout("iosurface", kCVPixelFormatType_32BGRA, 100, 50, io);
    layout("iosurface", kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 100, 50, io);
    layout("iosurface", kCVPixelFormatType_420YpCbCr8Planar, 33, 17, io);
    layout("align 128", kCVPixelFormatType_32BGRA, 100, 50, dict(1, kCVPixelBufferBytesPerRowAlignmentKey, num(128)));
    layout("align 3", kCVPixelFormatType_32BGRA, 100, 50, dict(1, kCVPixelBufferBytesPerRowAlignmentKey, num(3)));
    layout("align 3", kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 100, 50, dict(1, kCVPixelBufferBytesPerRowAlignmentKey, num(3)));
    CFNumberRef four = num(4);
    CFDictionaryRef ext = dict(4, kCVPixelBufferExtendedPixelsLeftKey, four, kCVPixelBufferExtendedPixelsTopKey, num(2),
                               kCVPixelBufferExtendedPixelsRightKey, num(20), kCVPixelBufferExtendedPixelsBottomKey, four);
    layout("extended", kCVPixelFormatType_32BGRA, 100, 50, ext);
    layout("extended", kCVPixelFormatType_24RGB, 10, 5, ext);
    layout("zero width", kCVPixelFormatType_32BGRA, 0, 50, NULL);
    layout("zero height", kCVPixelFormatType_32BGRA, 50, 0, NULL);

    /* extended pixels filled from the edges */
    CVPixelBufferRef b = NULL;
    CVPixelBufferCreate(NULL, 3, 2, kCVPixelFormatType_OneComponent8, dict(4, kCVPixelBufferExtendedPixelsLeftKey, num(1),
                                                                         kCVPixelBufferExtendedPixelsTopKey, num(1),
                                                                         kCVPixelBufferExtendedPixelsRightKey, num(2),
                                                                         kCVPixelBufferExtendedPixelsBottomKey, num(1)),
                        &b);
    CVPixelBufferLockBaseAddress(b, 0);
    unsigned char *p = CVPixelBufferGetBaseAddress(b);
    size_t bpr = CVPixelBufferGetBytesPerRow(b);
    for (int y = 0; y < 2; y++)
        for (int x = 0; x < 3; x++)
            p[y * bpr + x] = (unsigned char)('a' + y * 3 + x);
    printf("fill %d:", CVPixelBufferFillExtendedPixels(b));
    for (int y = -1; y < 3; y++) {
        printf(" ");
        for (int x = -1; x < 5; x++)
            printf("%c", p[y * (long)bpr + x] ? p[y * (long)bpr + x] : '.');
    }
    printf("\n");
    CVPixelBufferUnlockBaseAddress(b, 0);
    CFRelease(b);
}

static int released;

static void
release_bytes(void *refCon, const void *base)
{
    released++;
    printf("  released %s\n", (char *)refCon);
}

static void
release_planar(void *refCon, const void *data, size_t size, size_t planes, const void *bases[])
{
    released++;
    printf("  released planar %s size %zu planes %zu\n", (char *)refCon, size, planes);
}

static void
wrapping(void)
{
    static char bytes[64 * 4];
    CVPixelBufferRef b = NULL;
    printf("with bytes %d\n", CVPixelBufferCreateWithBytes(NULL, 10, 4, kCVPixelFormatType_32BGRA, bytes, 64, release_bytes, "bytes", NULL, &b));
    printf("  base is the bytes %d bpr %zu size %zu planar %d\n", CVPixelBufferGetBaseAddress(b) == bytes, CVPixelBufferGetBytesPerRow(b),
           CVPixelBufferGetDataSize(b), CVPixelBufferIsPlanar(b));
    CFRelease(b);
    printf("with bytes, bad format %d\n", CVPixelBufferCreateWithBytes(NULL, 10, 4, 'abcd', bytes, 64, NULL, NULL, NULL, &b));
    static char y[64 * 4], uv[64 * 2];
    void *bases[] = {y, uv};
    size_t widths[] = {10, 5}, heights[] = {4, 2}, bprs[] = {64, 64};
    printf("with planar bytes %d\n", CVPixelBufferCreateWithPlanarBytes(NULL, 10, 4, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, NULL, 999, 2,
                                                                         bases, widths, heights, bprs, release_planar, "planar", NULL, &b));
    printf("  planar %d planes %zu plane 1 is uv %d bpr %zu %zu size %zu base %d\n", CVPixelBufferIsPlanar(b), CVPixelBufferGetPlaneCount(b),
           CVPixelBufferGetBaseAddressOfPlane(b, 1) == uv, CVPixelBufferGetBytesPerRowOfPlane(b, 1), CVPixelBufferGetBytesPerRow(b),
           CVPixelBufferGetDataSize(b), CVPixelBufferGetBaseAddress(b) == NULL);
    CFRelease(b);

    IOSurfaceRef s = IOSurfaceCreate(dict(5, kIOSurfaceWidth, num(30), kIOSurfaceHeight, num(20), kIOSurfaceBytesPerElement, num(4),
                                          kIOSurfacePixelFormat, num(kCVPixelFormatType_32BGRA), kIOSurfaceBytesPerRow, num(128)));
    printf("with surface %d\n", CVPixelBufferCreateWithIOSurface(NULL, s, NULL, &b));
    printf("  %zux%zu %s bpr %zu size %zu surface %d base %d\n", CVPixelBufferGetWidth(b), CVPixelBufferGetHeight(b),
           code(CVPixelBufferGetPixelFormatType(b)), CVPixelBufferGetBytesPerRow(b), CVPixelBufferGetDataSize(b), CVPixelBufferGetIOSurface(b) == s,
           CVPixelBufferGetBaseAddress(b) == IOSurfaceGetBaseAddress(s));
    CFRelease(b);
    printf("released %d\n", released);

    CVPixelBufferCreate(NULL, 4, 4, kCVPixelFormatType_32BGRA, NULL, &b);
    printf("lock %d unlock %d unlock again %d read-only lock %d unlock %d unlock %d\n", CVPixelBufferLockBaseAddress(b, 0),
           CVPixelBufferUnlockBaseAddress(b, 0), CVPixelBufferUnlockBaseAddress(b, 0), CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly),
           CVPixelBufferUnlockBaseAddress(b, 0), CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly));
    printf("type %d compatible %d %d %d\n", CFGetTypeID(b) == CVPixelBufferGetTypeID(),
           CVPixelBufferIsCompatibleWithAttributes(b, dict(2, kCVPixelBufferWidthKey, num(4), kCVPixelBufferPixelFormatTypeKey,
                                                           num(kCVPixelFormatType_32BGRA))),
           CVPixelBufferIsCompatibleWithAttributes(b, dict(1, kCVPixelBufferWidthKey, num(5))),
           CVPixelBufferIsCompatibleWithAttributes(b, dict(1, kCVPixelBufferPixelFormatTypeKey, num(kCVPixelFormatType_24RGB))));
    show("creation attributes", CVPixelBufferCopyCreationAttributes(b));
    show("description", b);
    CFRelease(b);
}

static void
attachments(void)
{
    CVPixelBufferRef b, c;
    CVPixelBufferCreate(NULL, 16, 16, kCVPixelFormatType_32BGRA, NULL, &b);
    show("initial propagated", CVBufferCopyAttachments(b, kCVAttachmentMode_ShouldPropagate));
    show("initial not propagated", CVBufferCopyAttachments(b, kCVAttachmentMode_ShouldNotPropagate));
    CVBufferSetAttachment(b, CFSTR("k"), CFSTR("v1"), kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(b, CFSTR("k"), CFSTR("v2"), kCVAttachmentMode_ShouldNotPropagate);
    CVAttachmentMode m = 9;
    CFTypeRef v = CVBufferCopyAttachment(b, CFSTR("k"), &m);
    show("k", v);
    printf("mode %d\n", m);
    show("propagated", CVBufferCopyAttachments(b, kCVAttachmentMode_ShouldPropagate));
    show("not propagated", CVBufferCopyAttachments(b, kCVAttachmentMode_ShouldNotPropagate));
    CVBufferSetAttachment(b, CFSTR("p"), CFSTR("pv"), kCVAttachmentMode_ShouldPropagate);
    CVPixelBufferCreate(NULL, 8, 8, kCVPixelFormatType_32BGRA, NULL, &c);
    CVBufferPropagateAttachments(b, c);
    show("copied on", CVBufferCopyAttachments(c, kCVAttachmentMode_ShouldPropagate));
    show("copied on, not propagated", CVBufferCopyAttachments(c, kCVAttachmentMode_ShouldNotPropagate));
    CVBufferRemoveAttachment(b, CFSTR("k"));
    printf("has p %d k %d\n", CVBufferHasAttachment(b, CFSTR("p")), CVBufferHasAttachment(b, CFSTR("k")));
    CVBufferSetAttachments(b, dict(2, CFSTR("x"), CFSTR("1"), CFSTR("y"), CFSTR("2")), kCVAttachmentMode_ShouldNotPropagate);
    show("set several", CVBufferCopyAttachments(b, kCVAttachmentMode_ShouldNotPropagate));
    CVBufferRemoveAllAttachments(b);
    show("removed all", CVBufferCopyAttachments(b, kCVAttachmentMode_ShouldPropagate));

    CGSize e = CVImageBufferGetEncodedSize(b), d = CVImageBufferGetDisplaySize(b);
    CGRect r = CVImageBufferGetCleanRect(b);
    printf("encoded %g %g display %g %g clean %g %g %g %g flipped %d\n", e.width, e.height, d.width, d.height, r.origin.x, r.origin.y, r.size.width,
           r.size.height, CVImageBufferIsFlipped(b));
    CVBufferSetAttachment(b, kCVImageBufferPixelAspectRatioKey,
                          dict(2, kCVImageBufferPixelAspectRatioHorizontalSpacingKey, num(4), kCVImageBufferPixelAspectRatioVerticalSpacingKey, num(3)),
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(b, kCVImageBufferCleanApertureKey,
                          dict(4, kCVImageBufferCleanApertureWidthKey, num(10), kCVImageBufferCleanApertureHeightKey, num(8),
                               kCVImageBufferCleanApertureHorizontalOffsetKey, num(1), kCVImageBufferCleanApertureVerticalOffsetKey, num(-1)),
                          kCVAttachmentMode_ShouldPropagate);
    e = CVImageBufferGetEncodedSize(b), d = CVImageBufferGetDisplaySize(b);
    r = CVImageBufferGetCleanRect(b);
    printf("with aperture: encoded %g %g display %g %g clean %g %g %g %g\n", e.width, e.height, d.width, d.height, r.origin.x, r.origin.y,
           r.size.width, r.size.height);
    CVPixelBufferRef a = NULL;
    CVPixelBufferCreate(NULL, 4, 4, kCVPixelFormatType_32BGRA,
                        dict(2, kCVBufferPropagatedAttachmentsKey, dict(1, CFSTR("from"), CFSTR("attributes")), kCVBufferNonPropagatedAttachmentsKey,
                             dict(1, CFSTR("np"), CFSTR("too"))),
                        &a);
    show("from attributes", CVBufferCopyAttachments(a, kCVAttachmentMode_ShouldPropagate));
    show("from attributes, not propagated", CVBufferCopyAttachments(a, kCVAttachmentMode_ShouldNotPropagate));
}

static void
pools(void)
{
    CVPixelBufferPoolRef p = NULL;
    printf("pool without attributes %d\n", CVPixelBufferPoolCreate(NULL, NULL, NULL, &p));
    printf("pool without a format %d\n",
           CVPixelBufferPoolCreate(NULL, NULL, dict(2, kCVPixelBufferWidthKey, num(64), kCVPixelBufferHeightKey, num(32)), &p));
    CFDictionaryRef pa = dict(3, kCVPixelBufferWidthKey, num(64), kCVPixelBufferHeightKey, num(32), kCVPixelBufferPixelFormatTypeKey,
                              num(kCVPixelFormatType_32BGRA));
    printf("pool %d\n", CVPixelBufferPoolCreate(NULL, dict(1, kCVPixelBufferPoolMinimumBufferCountKey, num(2)), pa, &p));
    show("  pool attributes", CVPixelBufferPoolGetAttributes(p));
    show("  buffer attributes", CVPixelBufferPoolGetPixelBufferAttributes(p));
    printf("  type %d\n", CFGetTypeID(p) == CVPixelBufferPoolGetTypeID());
    CVPixelBufferRef a = NULL, b = NULL, c = NULL;
    printf("  buffer %d\n", CVPixelBufferPoolCreatePixelBuffer(NULL, p, &a));
    printf("  %zux%zu bpr %zu surface %d\n", CVPixelBufferGetWidth(a), CVPixelBufferGetHeight(a), CVPixelBufferGetBytesPerRow(a),
           CVPixelBufferGetIOSurface(a) != NULL);
    show("  its creation attributes", CVPixelBufferCopyCreationAttributes(a));
    void *base = CVPixelBufferGetBaseAddress(a);
    CFRelease(a);
    CVPixelBufferPoolCreatePixelBuffer(NULL, p, &b);
    printf("  memory reused %d\n", CVPixelBufferGetBaseAddress(b) == base);
    printf("  threshold 1: %d\n", CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                                      NULL, p, dict(1, kCVPixelBufferPoolAllocationThresholdKey, num(1)), &c));
    printf("  threshold 5: %d\n", CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                                      NULL, p, dict(1, kCVPixelBufferPoolAllocationThresholdKey, num(5)), &c));
    show("  description", p);
    CFRelease(b);
    CFRelease(c);
    CVPixelBufferPoolFlush(p, kCVPixelBufferPoolFlushExcessBuffers);
}

static void
descriptions(void)
{
    CFArrayRef all = CVPixelFormatDescriptionArrayCreateWithAllPixelFormatTypes(NULL);
    printf("%ld pixel formats\n", (long)CFArrayGetCount(all));
    const OSType some[] = {kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr8,
                           kCVPixelFormatType_24RGB, kCVPixelFormatType_16LE565, 'abcd'};
    for (size_t i = 0; i < sizeof some / sizeof some[0]; i++) {
        char label[32];
        snprintf(label, sizeof label, "format %s", code(some[i]));
        show(label, CVPixelFormatDescriptionCreateWithPixelFormatType(NULL, some[i]));
    }
    CVPixelFormatDescriptionRegisterDescriptionWithPixelFormatType(dict(2, kCVPixelFormatBitsPerBlock, num(16), kCVPixelFormatContainsRGB, kCFBooleanTrue),
                                                                   'Fnch');
    show("registered", CVPixelFormatDescriptionCreateWithPixelFormatType(NULL, 'Fnch'));
    layout("registered", 'Fnch', 10, 10, NULL);
    CFArrayRef again = CVPixelFormatDescriptionArrayCreateWithAllPixelFormatTypes(NULL);
    printf("now %ld\n", (long)CFArrayGetCount(again));
}

static void
colors(void)
{
    CFStringRef (*names[])(int) = {CVYCbCrMatrixGetStringForIntegerCodePoint, CVColorPrimariesGetStringForIntegerCodePoint,
                                   CVTransferFunctionGetStringForIntegerCodePoint};
    int (*codes[])(CFStringRef) = {CVYCbCrMatrixGetIntegerCodePointForString, CVColorPrimariesGetIntegerCodePointForString,
                                   CVTransferFunctionGetIntegerCodePointForString};
    for (int k = 0; k < 3; k++) {
        printf("code points %d:", k);
        for (int i = -1; i < 24; i++) {
            CFStringRef s = names[k](i);
            char b[64] = "-";
            if (s)
                CFStringGetCString(s, b, sizeof b, kCFStringEncodingUTF8);
            printf(" %d=%s(%d)", i, b, s ? codes[k](s) : -9);
        }
        printf(" unknown %d null %d\n", codes[k](CFSTR("nope")), codes[k](NULL));
    }
    CFStringRef pairs[][2] = {{kCVImageBufferColorPrimaries_ITU_R_709_2, kCVImageBufferTransferFunction_sRGB},
                              {kCVImageBufferColorPrimaries_ITU_R_709_2, kCVImageBufferTransferFunction_Linear},
                              {kCVImageBufferColorPrimaries_P3_D65, kCVImageBufferTransferFunction_sRGB},
                              {kCVImageBufferColorPrimaries_ITU_R_2020, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ},
                              {kCVImageBufferColorPrimaries_ITU_R_2020, kCVImageBufferTransferFunction_ITU_R_2100_HLG}};
    for (size_t i = 0; i < sizeof pairs / sizeof pairs[0]; i++) {
        CGColorSpaceRef cs = CVImageBufferCreateColorSpaceFromAttachments(
            dict(2, kCVImageBufferColorPrimariesKey, pairs[i][0], kCVImageBufferTransferFunctionKey, pairs[i][1]));
        CFStringRef name = cs ? CGColorSpaceCopyName(cs) : NULL;
        char b[128] = "(none)";
        if (name)
            CFStringGetCString(name, b, sizeof b, kCFStringEncodingUTF8);
        printf("color space %zu: %s %s\n", i, cs ? "made" : "NULL", b);
    }
    printf("no attachments: %s\n", CVImageBufferCreateColorSpaceFromAttachments(dict(0)) ? "made" : "NULL");
}

int
main(void)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    Dl_info info;
    dladdr((void *)CVPixelBufferCreate, &info);
    printf("%s\n", info.dli_fname);
    layouts();
    wrapping();
    attachments();
    pools();
    descriptions();
    colors();
    return 0;
}
