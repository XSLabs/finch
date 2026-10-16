/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CoreVideo, Finch's: the color code points of ITU-T H.273 and their names (as
 * Apple's maps them, "Prefix#N" for the ones without a name), color spaces from an
 * image buffer's attachments, and the Metal texture cache (Finch's Metal has no
 * devices yet, so a cache can't be made).
 */
#include "CVInternal.h"
#include <CoreGraphics/CoreGraphics.h>
#import <Metal/Metal.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    int code;
    CFStringRef name;
} CodePoint;

static const CodePoint matrices[] = {
    {1, CFSTR("ITU_R_709_2")}, {6, CFSTR("ITU_R_601_4")}, {7, CFSTR("SMPTE_240M_1995")},
    {9, CFSTR("ITU_R_2020")},  {14, CFSTR("ITU_R_2100_ICtCp")}, {15, CFSTR("IPT_C2")},
};
static const CodePoint primaries[] = {
    {1, CFSTR("ITU_R_709_2")}, {5, CFSTR("EBU_3213")}, {6, CFSTR("SMPTE_C")},
    {9, CFSTR("ITU_R_2020")},  {11, CFSTR("DCI_P3")},  {12, CFSTR("P3_D65")},
    {22, CFSTR("P22")},
};
static const CodePoint transfers[] = {
    {1, CFSTR("ITU_R_709_2")},       {6, CFSTR("ITU_R_709_2")},
    {7, CFSTR("SMPTE_240M_1995")},   {8, CFSTR("Linear")},
    {13, CFSTR("IEC_sRGB")},             {14, CFSTR("ITU_R_709_2")},
    {15, CFSTR("ITU_R_709_2")},      {16, CFSTR("SMPTE_ST_2084_PQ")},
    {17, CFSTR("SMPTE_ST_428_1")},   {18, CFSTR("ITU_R_2100_HLG")},
};

static CFStringRef
name_for(const CodePoint *table, size_t n, const char *prefix, int code)
{
    if (code == 0 || code == 2)
        return NULL;
    for (size_t i = 0; i < n; i++)
        if (table[i].code == code)
            return table[i].name;
    /* (the unnamed ones, made once each and kept, as the names are never released) */
    static CFMutableDictionaryRef made;
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    char buf[64];
    snprintf(buf, sizeof buf, "%s#%d", prefix, code);
    CFStringRef key = CFStringCreateWithCString(NULL, buf, kCFStringEncodingUTF8);
    pthread_mutex_lock(&lock);
    if (!made)
        made = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFStringRef s = CFDictionaryGetValue(made, key);
    if (!s) {
        CFDictionarySetValue(made, key, key);
        s = key;
    }
    pthread_mutex_unlock(&lock);
    CFRelease(key);
    return s;
}

static int
code_for(const CodePoint *table, size_t n, const char *prefix, CFStringRef name)
{
    if (!name)
        return 2;
    for (size_t i = 0; i < n; i++)
        if (CFEqual(table[i].name, name))
            return table[i].code;
    char buf[64];
    size_t len = strlen(prefix);
    if (CFStringGetCString(name, buf, sizeof buf, kCFStringEncodingUTF8) && !strncmp(buf, prefix, len) && buf[len] == '#') {
        char *end;
        long v = strtol(buf + len + 1, &end, 10);
        if (!*end && end != buf + len + 1)
            return (int)v;
    }
    return 2;
}

#define N(t) (sizeof t / sizeof t[0])

CFStringRef
CVYCbCrMatrixGetStringForIntegerCodePoint(int yCbCrMatrixCodePoint)
{
    return name_for(matrices, N(matrices), "YCbCrMatrix", yCbCrMatrixCodePoint);
}

CFStringRef
CVColorPrimariesGetStringForIntegerCodePoint(int colorPrimariesCodePoint)
{
    return name_for(primaries, N(primaries), "ColorPrimaries", colorPrimariesCodePoint);
}

CFStringRef
CVTransferFunctionGetStringForIntegerCodePoint(int transferFunctionCodePoint)
{
    return name_for(transfers, N(transfers), "TransferFunction", transferFunctionCodePoint);
}

int
CVYCbCrMatrixGetIntegerCodePointForString(CFStringRef yCbCrMatrixString)
{
    return code_for(matrices, N(matrices), "YCbCrMatrix", yCbCrMatrixString);
}

int
CVColorPrimariesGetIntegerCodePointForString(CFStringRef colorPrimariesString)
{
    return code_for(primaries, N(primaries), "ColorPrimaries", colorPrimariesString);
}

int
CVTransferFunctionGetIntegerCodePointForString(CFStringRef transferFunctionString)
{
    return code_for(transfers, N(transfers), "TransferFunction", transferFunctionString);
}

/* --- color spaces --- */

/* Color spaces for video come from an ICC profile Finch writes for the code points, as
   Apple's CoreVideo makes its own: "QuickTime 'nclc' Video (primaries,transfer,matrix)",
   the white point and the primaries (adapted to D50 by Bradford's method) and a
   parametric curve per channel. The BT.2100 ones (PQ, HLG) are Core Graphics' named
   spaces. */

typedef struct {
    int code;
    double xy[4][2]; /* red, green, blue, white */
} Primaries;

static const Primaries chromaticities[] = {
    {1, {{0.640, 0.330}, {0.300, 0.600}, {0.150, 0.060}, {0.3127, 0.3290}}},  /* BT.709 */
    {5, {{0.640, 0.330}, {0.290, 0.600}, {0.150, 0.060}, {0.3127, 0.3290}}},  /* EBU 3213 */
    {6, {{0.630, 0.340}, {0.310, 0.595}, {0.155, 0.070}, {0.3127, 0.3290}}},  /* SMPTE C */
    {9, {{0.708, 0.292}, {0.170, 0.797}, {0.131, 0.046}, {0.3127, 0.3290}}},  /* BT.2020 */
    {11, {{0.680, 0.320}, {0.265, 0.690}, {0.150, 0.060}, {0.314, 0.351}}},   /* DCI P3 */
    {12, {{0.680, 0.320}, {0.265, 0.690}, {0.150, 0.060}, {0.3127, 0.3290}}}, /* P3 D65 */
    {22, {{0.640, 0.340}, {0.290, 0.600}, {0.150, 0.060}, {0.3127, 0.3290}}}, /* P22 */
};

/* The ICC parametric curve (function type 3: g a b c d) for a transfer function. */
typedef struct {
    int code;
    double g, a, b, c, d;
} Curve;

static const Curve curves[] = {
    {13, 2.4, 1 / 1.055, 0.055 / 1.055, 1 / 12.92, 0.04045},                /* sRGB */
    {1, 1 / 0.45, 1 / 1.099, 0.099 / 1.099, 1 / 4.5, 0.081},                /* BT.709 */
    {7, 1 / 0.45, 1 / 1.1115, 0.1115 / 1.1115, 1 / 4.0, 0.0913},           /* SMPTE 240M */
    {8, 1, 1, 0, 0, 0},                                                     /* linear */
};

static void
put32(unsigned char *p, uint32_t v)
{
    p[0] = (unsigned char)(v >> 24), p[1] = (unsigned char)(v >> 16), p[2] = (unsigned char)(v >> 8), p[3] = (unsigned char)v;
}

static uint32_t
s15(double v)
{
    return (uint32_t)(int32_t)lround(v * 65536);
}

static void
xyz_of(const double xy[2], double out[3])
{
    out[0] = xy[0] / xy[1];
    out[1] = 1;
    out[2] = (1 - xy[0] - xy[1]) / xy[1];
}

static void
mul(const double m[3][3], const double v[3], double out[3])
{
    for (int i = 0; i < 3; i++)
        out[i] = m[i][0] * v[0] + m[i][1] * v[1] + m[i][2] * v[2];
}

static bool
invert(const double m[3][3], double out[3][3])
{
    double det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) +
                 m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
    if (fabs(det) < 1e-12)
        return false;
    for (int i = 0; i < 3; i++)
        for (int j = 0; j < 3; j++) {
            int r0 = (j + 1) % 3, r1 = (j + 2) % 3, c0 = (i + 1) % 3, c1 = (i + 2) % 3;
            out[i][j] = (m[r0][c0] * m[r1][c1] - m[r0][c1] * m[r1][c0]) / det;
        }
    return true;
}

/* The primaries' XYZ (columns: red, green, blue) adapted to D50, and the white's XYZ. */
static bool
colorants(const Primaries *p, double rgb[3][3], double white[3])
{
    double m[3][3], inv[3][3], s[3];
    for (int c = 0; c < 3; c++) {
        double v[3];
        xyz_of(p->xy[c], v);
        for (int r = 0; r < 3; r++)
            m[r][c] = v[r];
    }
    xyz_of(p->xy[3], white);
    if (!invert(m, inv))
        return false;
    mul(inv, white, s);
    static const double bradford[3][3] = {{0.8951, 0.2664, -0.1614}, {-0.7502, 1.7135, 0.0367}, {0.0389, -0.0685, 1.0296}};
    double binv[3][3], d50[3] = {0.9642, 1.0, 0.8249}, cs[3], cd[3], adapt[3][3], tmp[3][3];
    invert(bradford, binv);
    mul(bradford, white, cs);
    mul(bradford, d50, cd);
    for (int i = 0; i < 3; i++)
        for (int j = 0; j < 3; j++)
            tmp[i][j] = binv[i][j] * (cd[j] / cs[j]);
    for (int i = 0; i < 3; i++)
        for (int j = 0; j < 3; j++)
            adapt[i][j] = tmp[i][0] * bradford[0][j] + tmp[i][1] * bradford[1][j] + tmp[i][2] * bradford[2][j];
    for (int c = 0; c < 3; c++) {
        double col[3] = {m[0][c] * s[c], m[1][c] * s[c], m[2][c] * s[c]}, out[3];
        mul(adapt, col, out);
        for (int r = 0; r < 3; r++)
            rgb[r][c] = out[r];
    }
    return true;
}

static CFDataRef
nclc_profile(const Primaries *p, const Curve *t, int matrix)
{
    double rgb[3][3], white[3];
    if (!colorants(p, rgb, white))
        return NULL;
    char name[64];
    snprintf(name, sizeof name, "QuickTime 'nclc' Video (%d,%d,%d)", p->code, t->code, matrix);
    static const char copyright[] = "No copyright, use freely";
    size_t descSize = 12 + strlen(name) + 1 + 12 + 67, cprtSize = 8 + sizeof copyright;
    enum { TAGS = 8 };
    size_t at = 128 + 4 + 12 * (TAGS + 1), size;
    unsigned char *d = calloc(1, 1024);
    size_t descAt = at;
    at += (descSize + 3) & ~3u;
    size_t cprtAt = at;
    at += (cprtSize + 3) & ~3u;
    size_t xyzAt[4];
    for (int i = 0; i < 4; i++, at += 20)
        xyzAt[i] = at;
    size_t trcAt = at;
    at += 32;
    size = at;
    /* header */
    put32(d, (uint32_t)size);
    memcpy(d + 4, "appl", 4);
    put32(d + 8, 0x04000000);
    memcpy(d + 12, "mntr", 4);
    memcpy(d + 16, "RGB ", 4);
    memcpy(d + 20, "XYZ ", 4);
    memcpy(d + 36, "acsp", 4);
    memcpy(d + 40, "APPL", 4);
    put32(d + 68, s15(0.9642)), put32(d + 72, s15(1.0)), put32(d + 76, s15(0.8249));
    /* tags */
    struct {
        const char *sig;
        size_t at, size;
    } tags[TAGS] = {{"desc", descAt, descSize}, {"cprt", cprtAt, cprtSize}, {"wtpt", xyzAt[0], 20}, {"rXYZ", xyzAt[1], 20},
                    {"gXYZ", xyzAt[2], 20},     {"bXYZ", xyzAt[3], 20},     {"rTRC", trcAt, 32},     {"gTRC", trcAt, 32}};
    put32(d + 128, TAGS + 1);
    for (int i = 0; i < TAGS; i++) {
        memcpy(d + 132 + 12 * i, tags[i].sig, 4);
        put32(d + 136 + 12 * i, (uint32_t)tags[i].at);
        put32(d + 140 + 12 * i, (uint32_t)tags[i].size);
    }
    /* (a ninth: blue's curve, shared with red's and green's) */
    memcpy(d + 132 + 12 * TAGS, "bTRC", 4);
    put32(d + 136 + 12 * TAGS, (uint32_t)trcAt);
    put32(d + 140 + 12 * TAGS, 32);
    memcpy(d + descAt, "desc", 4);
    put32(d + descAt + 8, (uint32_t)strlen(name) + 1);
    memcpy(d + descAt + 12, name, strlen(name));
    memcpy(d + cprtAt, "text", 4);
    memcpy(d + cprtAt + 8, copyright, sizeof copyright);
    const double *xyz[4] = {white, NULL, NULL, NULL};
    for (int i = 0; i < 4; i++) {
        double v[3];
        if (i == 0)
            memcpy(v, xyz[0], sizeof v);
        else
            v[0] = rgb[0][i - 1], v[1] = rgb[1][i - 1], v[2] = rgb[2][i - 1];
        memcpy(d + xyzAt[i], "XYZ ", 4);
        for (int k = 0; k < 3; k++)
            put32(d + xyzAt[i] + 8 + 4 * k, s15(v[k]));
    }
    memcpy(d + trcAt, "para", 4);
    d[trcAt + 9] = 3;
    double params[5] = {t->g, t->a, t->b, t->c, t->d};
    for (int k = 0; k < 5; k++)
        put32(d + trcAt + 12 + 4 * k, s15(params[k]));
    CFDataRef data = CFDataCreate(NULL, d, (CFIndex)size);
    free(d);
    return data;
}

CGColorSpaceRef
CVImageBufferCreateColorSpaceFromAttachments(CFDictionaryRef attachments)
{
    if (!attachments)
        return NULL;
    CFTypeRef icc = CFDictionaryGetValue(attachments, kCVImageBufferICCProfileKey);
    if (icc && CFGetTypeID(icc) == CFDataGetTypeID())
        return CGColorSpaceCreateWithICCData(icc);
    CFTypeRef pv = CFDictionaryGetValue(attachments, kCVImageBufferColorPrimariesKey);
    CFTypeRef tv = CFDictionaryGetValue(attachments, kCVImageBufferTransferFunctionKey);
    CFTypeRef mv = CFDictionaryGetValue(attachments, kCVImageBufferYCbCrMatrixKey);
    if (!pv || !tv || CFGetTypeID(pv) != CFStringGetTypeID() || CFGetTypeID(tv) != CFStringGetTypeID())
        return NULL;
    int pc = CVColorPrimariesGetIntegerCodePointForString(pv), tc = CVTransferFunctionGetIntegerCodePointForString(tv);
    int mc = mv && CFGetTypeID(mv) == CFStringGetTypeID() ? CVYCbCrMatrixGetIntegerCodePointForString(mv) : 2;
    if (pc == 1 && tc == 1 && mc == 1)
        return CGColorSpaceCreateWithName(kCGColorSpaceCoreMedia709);
    if (pc == 9 && tc == 16)
        return CGColorSpaceCreateWithName(kCGColorSpaceITUR_2100_PQ);
    if (pc == 9 && tc == 18)
        return CGColorSpaceCreateWithName(kCGColorSpaceITUR_2100_HLG);
    const Primaries *p = NULL;
    const Curve *t = NULL;
    for (size_t i = 0; i < N(chromaticities); i++)
        if (chromaticities[i].code == pc)
            p = &chromaticities[i];
    for (size_t i = 0; i < N(curves); i++)
        if (curves[i].code == tc)
            t = &curves[i];
    if (!p || !t)
        return NULL;
    CFDataRef profile = nclc_profile(p, t, mc);
    CGColorSpaceRef cs = profile ? CGColorSpaceCreateWithICCData(profile) : NULL;
    if (profile)
        CFRelease(profile);
    return cs;
}

CGColorSpaceRef
CVImageBufferGetColorSpace(CVImageBufferRef imageBuffer)
{
    /* (made from the attachments and kept on the buffer, as a non-propagated attachment) */
    CFTypeRef cs = CVBufferCopyAttachment(imageBuffer, kCVImageBufferCGColorSpaceKey, NULL);
    if (cs) {
        CFRelease(cs);
        return (CGColorSpaceRef)cs;
    }
    CFDictionaryRef a = CVBufferCopyAttachments(imageBuffer, kCVAttachmentMode_ShouldPropagate);
    CGColorSpaceRef made = CVImageBufferCreateColorSpaceFromAttachments(a);
    if (a)
        CFRelease(a);
    if (!made)
        return NULL;
    CVBufferSetAttachment(imageBuffer, kCVImageBufferCGColorSpaceKey, made, kCVAttachmentMode_ShouldNotPropagate);
    CGColorSpaceRelease(made);
    return made;
}

/* --- Metal texture caches --- */

CV_DEFINE_TYPE(CVMetalTextureCacheGetTypeID, "CVMetalTextureCache", NULL, NULL)
CV_DEFINE_TYPE(CVMetalTextureGetTypeID, "CVMetalTexture", NULL, NULL)

CVReturn
CVMetalTextureCacheCreate(CFAllocatorRef allocator, CFDictionaryRef cacheAttributes, id<MTLDevice> metalDevice, CFDictionaryRef textureAttributes,
                          CVMetalTextureCacheRef *cacheOut)
{
    if (cacheOut)
        *cacheOut = NULL;
    return metalDevice ? kCVReturnUnsupported : kCVReturnInvalidArgument;
}

CVReturn
CVMetalTextureCacheCreateTextureFromImage(CFAllocatorRef allocator, CVMetalTextureCacheRef textureCache, CVImageBufferRef sourceImage,
                                          CFDictionaryRef textureAttributes, MTLPixelFormat pixelFormat, size_t width, size_t height,
                                          size_t planeIndex, CVMetalTextureRef *textureOut)
{
    if (textureOut)
        *textureOut = NULL;
    return kCVReturnInvalidArgument;
}

void
CVMetalTextureCacheFlush(CVMetalTextureCacheRef textureCache, CVOptionFlags options)
{
}

id<MTLTexture>
CVMetalTextureGetTexture(CVMetalTextureRef image)
{
    return nil;
}

Boolean
CVMetalTextureIsFlipped(CVMetalTextureRef image)
{
    return false;
}

void
CVMetalTextureGetCleanTexCoords(CVMetalTextureRef image, float lowerLeft[2], float lowerRight[2], float upperRight[2], float upperLeft[2])
{
}
