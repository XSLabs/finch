/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * vImage's utilities (vImage_Utilities.h, BasicImageTypes.h): buffer allocation, the
 * vImage_CGImageFormat helpers, vImageConverter and vImageConvert_AnyToAny, and the PNG
 * decompression filter.
 *
 * A converter reads each source pixel of any vImage_CGImageFormat (any byte order, packed
 * 16- and 32-bit pixels, indexed colour, half and single floats, decode arrays) as double
 * precision colour and alpha, converts the colour through ColorSync when the two colour
 * spaces differ, deals with alpha (premultiplying, unpremultiplying, flattening against
 * the background colour) and writes the destination format, rounding to nearest.
 */
#include "common.h"
#include "utilities.h"
#include <ColorSync/ColorSync.h>
#include <stdatomic.h>

/* MARK: - Constants */

static const CGFloat decode_16q12[6] = {0, 65535.0 / 4096, 0, 65535.0 / 4096, 0, 65535.0 / 4096};
static const CGFloat decode_xr10[6] = {-384.0 / 511, 639.0 / 511, -384.0 / 511, 639.0 / 511, -384.0 / 511, 639.0 / 511};
const CGFloat *kvImageDecodeArray_16Q12Format = decode_16q12;
const CGFloat *kvImageConstDecodeArray0 = decode_xr10;

/* MARK: - Buffers */

/* rows of fewer than 64 bytes are 16-byte aligned, longer ones 128; a power of two of
   4096 bytes or more gets 128 more, to keep rows off the same cache sets (Apple's rule) */
vImage_Error vImageBuffer_Init(vImage_Buffer *buf, vImagePixelCount height, vImagePixelCount width, uint32_t pixelBits,
                               vImage_Flags flags)
{
    if (!buf)
        return kvImageNullPointerArgument;
    if (flags & ~(vImage_Flags)(kvImageNoAllocate | kvImagePrintDiagnosticsToConsole))
        return kvImageUnknownFlagsBit;
    if (pixelBits && width > (SIZE_MAX - 7) / pixelBits)
        return kvImageInvalidParameter;
    size_t bytes = ((size_t)width * pixelBits + 7) / 8, align = bytes < 64 ? 16 : 128;
    size_t rowBytes = (bytes + align - 1) & ~(align - 1);
    if (rowBytes >= 4096 && !(rowBytes & (rowBytes - 1)))
        rowBytes += align;
    buf->height = height;
    buf->width = width;
    buf->rowBytes = rowBytes;
    buf->data = NULL;
    if (flags & kvImageNoAllocate)
        return (vImage_Error)align;
    if (height && rowBytes > SIZE_MAX / height)
        return kvImageMemoryAllocationError;
    if (posix_memalign(&buf->data, 4096, rowBytes * height ? rowBytes * height : 1))
        return buf->data = NULL, kvImageMemoryAllocationError;
    return kvImageNoError;
}

CGSize vImageBuffer_GetSize(const vImage_Buffer *buf)
{
    /* rounded down to a representable CGFloat */
    CGFloat w = (CGFloat)buf->width, h = (CGFloat)buf->height;
    if ((vImagePixelCount)w > buf->width)
        w = nextafter(w, 0);
    if ((vImagePixelCount)h > buf->height)
        h = nextafter(h, 0);
    return CGSizeMake(w, h);
}

/* MARK: - vImage_CGImageFormat */

static uint32_t alpha_info(CGBitmapInfo info) { return info & kCGBitmapAlphaInfoMask; }

uint32_t vImageCGImageFormat_GetComponentCount(const vImage_CGImageFormat *format)
{
    size_t colors = format->colorSpace ? CGColorSpaceGetNumberOfComponents(format->colorSpace) : 3;
    uint32_t a = alpha_info(format->bitmapInfo);
    return (uint32_t)colors + (a != kCGImageAlphaNone && a != kCGImageAlphaOnly ? 1 : 0);
}

/* NULL colour spaces are the device RGB space, and NULL decode arrays the identity */
Boolean vImageCGImageFormat_IsEqual(const vImage_CGImageFormat *f1, const vImage_CGImageFormat *f2)
{
    if (!f1 || !f2)
        return false;
    if (f1->bitsPerComponent != f2->bitsPerComponent || f1->bitmapInfo != f2->bitmapInfo)
        return false;
    CGColorSpaceRef device = CGColorSpaceCreateDeviceRGB();
    CGColorSpaceRef s1 = f1->colorSpace ? f1->colorSpace : device, s2 = f2->colorSpace ? f2->colorSpace : device;
    bool same = s1 == s2 || CFEqual(s1, s2);
    CGColorSpaceRelease(device);
    if (!same)
        return false;
    size_t n = CGColorSpaceGetNumberOfComponents(s1);
    for (size_t i = 0; i < 2 * n; ++i) {
        CGFloat d1 = f1->decode ? f1->decode[i] : (CGFloat)(i & 1), d2 = f2->decode ? f2->decode[i] : (CGFloat)(i & 1);
        if (d1 != d2)
            return false;
    }
    return true;
}

/* MARK: - Pixel formats */

/* a vImage_CGImageFormat, digested */
typedef struct {
    CGColorSpaceRef space; /* retained; NULL means sRGB */
    CGColorSpaceRef base;  /* the colour space of the colour values (an indexed space's base) */
    int colors;            /* colour channels, after any index lookup */
    bool indexed;
    uint8_t *table;        /* an indexed space's colours (owned) */
    size_t tableCount;
    uint32_t alpha;        /* CGImageAlphaInfo */
    bool hasAlpha, alphaFirst, premultiplied, skip, alphaOnly;
    uint32_t bpc, bpp;
    bool isFloat;
    uint32_t order;        /* kCGBitmapByteOrder* */
    uint32_t packed;       /* kCGImagePixelFormat*, or one of them implied by 5 bits a component */
    CGFloat decode[32];
    bool hasDecode;
} Format;

static vImage_Error digest(const vImage_CGImageFormat *f, Format *d, bool destination)
{
    memset(d, 0, sizeof(*d));
    d->space = f->colorSpace ? CGColorSpaceRetain(f->colorSpace) : NULL;
    d->base = d->space;
    d->alpha = alpha_info(f->bitmapInfo);
    if (d->alpha > kCGImageAlphaOnly)
        return kvImageInvalidImageFormat;
    d->alphaOnly = d->alpha == kCGImageAlphaOnly;
    d->hasAlpha = d->alpha != kCGImageAlphaNone;
    d->alphaFirst = d->alpha == kCGImageAlphaFirst || d->alpha == kCGImageAlphaPremultipliedFirst ||
                    d->alpha == kCGImageAlphaNoneSkipFirst;
    d->premultiplied = d->alpha == kCGImageAlphaPremultipliedFirst || d->alpha == kCGImageAlphaPremultipliedLast;
    d->skip = d->alpha == kCGImageAlphaNoneSkipFirst || d->alpha == kCGImageAlphaNoneSkipLast;
    d->bpc = f->bitsPerComponent;
    d->bpp = f->bitsPerPixel;
    d->isFloat = (f->bitmapInfo & kCGBitmapFloatComponents) != 0;
    d->order = f->bitmapInfo & kCGBitmapByteOrderMask;
    d->packed = f->bitmapInfo & kCGImagePixelFormatMask;
    if (d->isFloat && d->bpc != 16 && d->bpc != 32)
        return kvImageInvalidImageFormat;
    switch (d->bpc) {
    case 1: case 2: case 4: case 5: case 8: case 10: case 12: case 16: case 32:
        break;
    default:
        return kvImageInvalidImageFormat;
    }
    if (d->bpc == 5 && !d->packed)
        d->packed = d->hasAlpha ? kCGImagePixelFormatRGB555 : kCGImagePixelFormatRGB565;
    if (d->space && CGColorSpaceGetModel(d->space) == kCGColorSpaceModelIndexed) {
        if (destination || d->hasAlpha || (d->bpc != 1 && d->bpc != 2 && d->bpc != 4 && d->bpc != 8))
            return kvImageInvalidImageFormat;
        d->indexed = true;
        d->base = CGColorSpaceGetBaseColorSpace(d->space);
        d->tableCount = CGColorSpaceGetColorTableCount(d->space);
        size_t baseN = CGColorSpaceGetNumberOfComponents(d->base);
        d->table = calloc(d->tableCount ? d->tableCount : 1, baseN ? baseN : 1);
        if (!d->table)
            return kvImageMemoryAllocationError;
        if (d->tableCount)
            CGColorSpaceGetColorTable(d->space, d->table);
    }
    d->colors = d->alphaOnly ? 0 : d->base ? (int)CGColorSpaceGetNumberOfComponents(d->base) : 3;
    int channels = d->indexed ? 1 : d->colors;
    if (f->decode) {
        d->hasDecode = true;
        for (int i = 0; i < 2 * channels && i < 32; ++i)
            d->decode[i] = f->decode[i];
    }
    int slots = (d->indexed ? 1 : d->colors) + (d->hasAlpha ? 1 : 0);
    if (!d->packed && d->bpp < (uint32_t)slots * d->bpc)
        return kvImageInvalidImageFormat;
    return kvImageNoError;
}

static void release_format(Format *d)
{
    if (d->space)
        CGColorSpaceRelease(d->space);
    free(d->table);
    d->space = NULL;
    d->table = NULL;
}

/* an unsigned bit field of row, `bits` wide at bit offset `at`, most significant first,
   after the byte order's swapping of 16- or 32-bit units */
static uint32_t bits_at(const uint8_t *row, size_t at, uint32_t bits, uint32_t unit, bool little)
{
    uint32_t v = 0;
    for (uint32_t i = 0; i < bits; ++i) {
        size_t bit = at + i, byte = bit / 8;
        if (little && unit > 1) /* the byte's place within its unit, reversed */
            byte = byte / unit * unit + (unit - 1 - byte % unit);
        v = v << 1 | ((row[byte] >> (7 - bit % 8)) & 1);
    }
    return v;
}

static void set_bits(uint8_t *row, size_t at, uint32_t bits, uint32_t unit, bool little, uint32_t v)
{
    for (uint32_t i = 0; i < bits; ++i) {
        size_t bit = at + i, byte = bit / 8;
        if (little && unit > 1)
            byte = byte / unit * unit + (unit - 1 - byte % unit);
        uint8_t mask = (uint8_t)(1u << (7 - bit % 8));
        if ((v >> (bits - 1 - i)) & 1)
            row[byte] |= mask;
        else
            row[byte] &= (uint8_t)~mask;
    }
}

/* the byte order's unit (1 for none) and whether it is little-endian */
static void order_of(const Format *d, uint32_t *unit, bool *little)
{
    switch (d->order) {
    case kCGBitmapByteOrder16Little:
        *unit = 2, *little = true;
        break;
    case kCGBitmapByteOrder16Big:
        *unit = 2, *little = false;
        break;
    case kCGBitmapByteOrder32Little:
        *unit = 4, *little = true;
        break;
    case kCGBitmapByteOrder32Big:
        *unit = 4, *little = false;
        break;
    default:
        *unit = 1, *little = false;
        break;
    }
}

/* the bit widths and slots of a packed pixel: {alpha, r, g, b} widths, in pixel order */
static void packed_layout(const Format *d, int *widths, int *order, int *n)
{
    switch (d->packed) {
    case kCGImagePixelFormatRGB565:
        widths[0] = 5, widths[1] = 6, widths[2] = 5, order[0] = 1, order[1] = 2, order[2] = 3, *n = 3;
        break;
    case kCGImagePixelFormatRGB101010:
    case kCGImagePixelFormatRGBCIF10:
        if (d->alphaFirst)
            widths[0] = 2, widths[1] = widths[2] = widths[3] = 10, order[0] = 0, order[1] = 1, order[2] = 2, order[3] = 3;
        else
            widths[0] = widths[1] = widths[2] = 10, widths[3] = 2, order[0] = 1, order[1] = 2, order[2] = 3, order[3] = 0;
        *n = 4;
        break;
    default: /* RGB555: 1 bit of alpha (or padding), first or last */
        if (d->alphaFirst)
            widths[0] = 1, widths[1] = widths[2] = widths[3] = 5, order[0] = 0, order[1] = 1, order[2] = 2, order[3] = 3;
        else
            widths[0] = widths[1] = widths[2] = 5, widths[3] = 1, order[0] = 1, order[1] = 2, order[2] = 3, order[3] = 0;
        *n = 4;
        break;
    }
}

static inline double from_half(uint32_t h)
{
    uint16_t v = (uint16_t)h;
    _Float16 f;
    memcpy(&f, &v, 2);
    return (double)f;
}

static inline double from_float(uint32_t b)
{
    float f;
    memcpy(&f, &b, 4);
    return (double)f;
}

/* pixel x of row as colour values (normalized, decoded) and alpha, premultiplied as stored */
static void read_pixel(const Format *d, const uint8_t *row, vImagePixelCount x, double *color, double *alpha)
{
    uint32_t unit;
    bool little;
    order_of(d, &unit, &little);
    size_t at = (size_t)x * d->bpp;
    *alpha = 1;
    if (d->packed) {
        int widths[4], slots[4], n;
        packed_layout(d, widths, slots, &n);
        for (int k = 0; k < n; ++k) {
            uint32_t v = bits_at(row, at, (uint32_t)widths[k], unit, little);
            double f = (double)v / (double)((1u << widths[k]) - 1);
            at += (size_t)widths[k];
            if (slots[k] == 0) {
                if (d->hasAlpha && !d->skip)
                    *alpha = f;
            } else
                color[slots[k] - 1] = f;
        }
        return;
    }
    int channels = d->indexed ? 1 : d->colors;
    int total = channels + (d->hasAlpha ? 1 : 0);
    uint32_t max = d->bpc >= 32 ? 0xffffffffu : (1u << d->bpc) - 1;
    for (int k = 0; k < total; ++k) {
        bool isAlpha = d->hasAlpha && (d->alphaFirst ? k == 0 : k == total - 1);
        uint32_t raw = bits_at(row, at + (size_t)k * d->bpc, d->bpc, unit, little);
        /* (integers normalize as Apple's do, times 1 / max in single precision; integer to
           integer conversions are unaffected, as no exact quotient lies near a rounding tie) */
        double v = d->isFloat ? (d->bpc == 16 ? from_half(raw) : from_float(raw)) : (double)((float)raw * (1.0f / (float)max));
        if (isAlpha) {
            if (!d->skip)
                *alpha = v;
            continue;
        }
        int c = d->hasAlpha && d->alphaFirst ? k - 1 : k;
        if (d->indexed) {
            size_t i = raw < d->tableCount ? raw : d->tableCount ? d->tableCount - 1 : 0;
            size_t baseN = CGColorSpaceGetNumberOfComponents(d->base);
            for (size_t b = 0; b < baseN; ++b)
                color[b] = d->tableCount ? d->table[i * baseN + b] / 255.0 : 0;
            continue;
        }
        if (d->hasDecode)
            v = d->decode[2 * c] + v * (d->decode[2 * c + 1] - d->decode[2 * c]);
        color[c] = v;
    }
}

static inline uint32_t to_half_bits(double v)
{
    _Float16 f = (_Float16)v;
    uint16_t h;
    memcpy(&h, &f, 2);
    return h;
}

static inline uint32_t to_float_bits(double v)
{
    float f = (float)v;
    uint32_t b;
    memcpy(&b, &f, 4);
    return b;
}

/* to nearest, ties up (or to even, from half floats, as vImage's half conversions round) */
static _Thread_local bool round_even;

static inline uint32_t quantize(double v, uint32_t max)
{
    if (!(v > 0))
        return 0;
    if (v >= 1)
        return max;
    return (uint32_t)(round_even ? rintf((float)v * (float)max) : floor(v * max + 0.5));
}

static void write_pixel(const Format *d, uint8_t *row, vImagePixelCount x, const double *color, double alpha)
{
    uint32_t unit;
    bool little;
    order_of(d, &unit, &little);
    size_t at = (size_t)x * d->bpp;
    if (d->packed) {
        int widths[4], slots[4], n;
        packed_layout(d, widths, slots, &n);
        for (int k = 0; k < n; ++k) {
            double v = slots[k] == 0 ? (d->hasAlpha && !d->skip ? alpha : 1) : color[slots[k] - 1];
            set_bits(row, at, (uint32_t)widths[k], unit, little, quantize(v, (1u << widths[k]) - 1));
            at += (size_t)widths[k];
        }
        return;
    }
    int total = d->colors + (d->hasAlpha ? 1 : 0);
    uint32_t max = d->bpc >= 32 ? 0xffffffffu : (1u << d->bpc) - 1;
    for (int k = 0; k < total; ++k) {
        bool isAlpha = d->hasAlpha && (d->alphaFirst ? k == 0 : k == total - 1);
        double v;
        if (isAlpha)
            v = d->skip ? 1 : alpha;
        else {
            int c = d->hasAlpha && d->alphaFirst ? k - 1 : k;
            v = color[c];
            if (d->hasDecode && d->decode[2 * c + 1] != d->decode[2 * c])
                v = (v - d->decode[2 * c]) / (d->decode[2 * c + 1] - d->decode[2 * c]);
        }
        uint32_t raw = d->isFloat ? (d->bpc == 16 ? to_half_bits(v) : to_float_bits(v)) : quantize(v, max);
        set_bits(row, at + (size_t)k * d->bpc, d->bpc, unit, little, raw);
    }
    /* padding bits after the last component are left as they were */
}

/* MARK: - Converters */

#define CONVERTER_MAGIC 0x56434e56u /* "VNCV" */

struct vImageConverter {
    uint32_t magic;
    _Atomic long refs;
    Format src, dst;
    double background[16];
    bool hasBackground;
    ColorSyncTransformRef transform; /* NULL when the colour spaces match */
    vImage_Flags flags;
    vImageBufferTypeCode srcOrder[2], dstOrder[2];
    /* converters to and from CoreVideo formats */
    const struct vImageCVConversion *cv;
};

void vImageConverter_Retain(vImageConverterRef converter)
{
    if (converter && converter->magic == CONVERTER_MAGIC)
        atomic_fetch_add(&converter->refs, 1);
}

void vImageConverter_Release(vImageConverterRef converter)
{
    if (!converter || converter->magic != CONVERTER_MAGIC)
        return;
    if (atomic_fetch_sub(&converter->refs, 1) != 1)
        return;
    release_format(&converter->src);
    release_format(&converter->dst);
    if (converter->transform)
        CFRelease(converter->transform);
    vimage_cv_release(converter->cv);
    converter->magic = 0;
    free(converter);
}

/* the profile of a colour space, as vImage maps them: device RGB is sRGB, device gray
   is generic gray (gamma 2.2) and device CMYK generic CMYK */
static ColorSyncProfileRef profile_for(CGColorSpaceRef space)
{
    if (!space)
        return ColorSyncProfileCreateWithName(kColorSyncSRGBProfile);
    CFDataRef icc = CGColorSpaceCopyICCData(space);
    if (icc) {
        ColorSyncProfileRef p = ColorSyncProfileCreate(icc, NULL);
        CFRelease(icc);
        if (p)
            return p;
    }
    switch (CGColorSpaceGetModel(space)) {
    case kCGColorSpaceModelMonochrome:
        return ColorSyncProfileCreateWithName(kColorSyncGenericGrayGamma22Profile);
    case kCGColorSpaceModelCMYK:
        return ColorSyncProfileCreateWithName(kColorSyncGenericCMYKProfile);
    case kCGColorSpaceModelLab:
        return ColorSyncProfileCreateWithName(kColorSyncGenericLabProfile);
    case kCGColorSpaceModelXYZ:
        return ColorSyncProfileCreateWithName(kColorSyncGenericXYZProfile);
    default:
        return ColorSyncProfileCreateWithName(kColorSyncSRGBProfile);
    }
}

static bool same_space(CGColorSpaceRef a, CGColorSpaceRef b)
{
    if (a == b)
        return true;
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB), device = CGColorSpaceCreateDeviceRGB();
    CGColorSpaceRef x = a ? a : srgb, y = b ? b : srgb;
    /* device RGB converts as sRGB */
    if (CFEqual(x, device))
        x = srgb;
    if (CFEqual(y, device))
        y = srgb;
    bool same = x == y || CFEqual(x, y);
    CGColorSpaceRelease(srgb);
    CGColorSpaceRelease(device);
    return same;
}

static CFStringRef intent_name(CGColorRenderingIntent intent)
{
    switch (intent) {
    case kCGRenderingIntentAbsoluteColorimetric:
        return kColorSyncRenderingIntentAbsolute;
    case kCGRenderingIntentRelativeColorimetric:
        return kColorSyncRenderingIntentRelative;
    case kCGRenderingIntentSaturation:
        return kColorSyncRenderingIntentSaturation;
    default:
        return kColorSyncRenderingIntentPerceptual;
    }
}

ColorSyncTransformRef vimage_make_transform(CGColorSpaceRef from, CGColorSpaceRef to, CGColorRenderingIntent intent)
{
    ColorSyncProfileRef a = profile_for(from), b = profile_for(to);
    if (!a || !b) {
        if (a)
            CFRelease(a);
        if (b)
            CFRelease(b);
        return NULL;
    }
    const void *keys[] = {kColorSyncProfile, kColorSyncRenderingIntent, kColorSyncTransformTag};
    const void *first[] = {a, intent_name(intent), kColorSyncTransformDeviceToPCS};
    const void *last[] = {b, intent_name(intent), kColorSyncTransformPCSToDevice};
    CFDictionaryRef d1 = CFDictionaryCreate(NULL, keys, first, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionaryRef d2 = CFDictionaryCreate(NULL, keys, last, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void *seq[] = {d1, d2};
    CFArrayRef sequence = CFArrayCreate(NULL, seq, 2, &kCFTypeArrayCallBacks);
    ColorSyncTransformRef t = ColorSyncTransformCreate(sequence, NULL);
    CFRelease(sequence);
    CFRelease(d1);
    CFRelease(d2);
    CFRelease(a);
    CFRelease(b);
    return t;
}

vImageConverterRef vimage_converter_alloc(void)
{
    struct vImageConverter *c = calloc(1, sizeof(*c));
    if (!c)
        return NULL;
    c->magic = CONVERTER_MAGIC;
    atomic_store(&c->refs, 1);
    c->srcOrder[0] = c->dstOrder[0] = kvImageBufferTypeCode_CGFormat;
    return c;
}

static vImageConverterRef fail(vImageConverterRef c, vImage_Error e, vImage_Error *error)
{
    if (error)
        *error = e;
    if (c)
        vImageConverter_Release(c);
    return NULL;
}

static vImageConverterRef create(const vImage_CGImageFormat *srcFormat, const vImage_CGImageFormat *destFormat,
                                 const CGFloat *backgroundColor, vImage_Flags flags, vImage_Error *error,
                                 CGColorSpaceRef transformFrom, CGColorSpaceRef transformTo, bool forceTransform)
{
    if (!srcFormat || !destFormat)
        return fail(NULL, kvImageNullPointerArgument, error);
    if (flags & ~(vImage_Flags)(kvImagePrintDiagnosticsToConsole | kvImageDoNotTile))
        return fail(NULL, kvImageUnknownFlagsBit, error);
    struct vImageConverter *c = (struct vImageConverter *)vimage_converter_alloc();
    if (!c)
        return fail(NULL, kvImageMemoryAllocationError, error);
    c->flags = flags;
    vImage_Error e = digest(srcFormat, &c->src, false);
    if (!e)
        e = digest(destFormat, &c->dst, true);
    if (e)
        return fail(c, e, error);
    if (c->src.hasAlpha && !c->src.skip && !c->dst.hasAlpha) {
        /* flattening needs a background (NULL is black) */
        c->hasBackground = true;
        /* (to an integer format's precision, as vImage's flattening takes it) */
        double max = c->dst.isFloat || c->dst.packed ? 0 : (double)((1ull << c->dst.bpc) - 1);
        for (int i = 0; i < c->dst.colors && i < 16; ++i) {
            double v = backgroundColor ? backgroundColor[i] : 0;
            c->background[i] = max ? (double)llround(v * max) / max : v;
        }
    }
    if (forceTransform || !same_space(c->src.base, c->dst.base)) {
        c->transform = vimage_make_transform(transformFrom ? transformFrom : c->src.base,
                                             transformTo ? transformTo : c->dst.base, destFormat->renderingIntent);
        if (!c->transform)
            return fail(c, kvImageInternalError, error);
    }
    if (error)
        *error = kvImageNoError;
    return c;
}

vImageConverterRef vImageConverter_CreateWithCGImageFormat(const vImage_CGImageFormat *srcFormat,
                                                           const vImage_CGImageFormat *destFormat,
                                                           const CGFloat *backgroundColor, vImage_Flags flags,
                                                           vImage_Error *error)
{
    return create(srcFormat, destFormat, backgroundColor, flags, error, NULL, NULL, false);
}

/* (the code fragment's own profile sequence is not read: the conversion runs between the
   two formats' colour spaces) */
vImageConverterRef vImageConverter_CreateWithColorSyncCodeFragment(CFTypeRef codeFragment,
                                                                   const vImage_CGImageFormat *srcFormat,
                                                                   const vImage_CGImageFormat *destFormat,
                                                                   const CGFloat *backgroundColor, vImage_Flags flags,
                                                                   vImage_Error *error)
{
    if (!codeFragment)
        return fail(NULL, kvImageNullPointerArgument, error);
    return create(srcFormat, destFormat, backgroundColor, flags, error, NULL, NULL, true);
}

vImageConverterRef vImageConverter_CreateWithCGColorConversionInfo(CGColorConversionInfoRef colorConversionInfoRef,
                                                                   const vImage_CGImageFormat *sFormat,
                                                                   const vImage_CGImageFormat *dFormat,
                                                                   const CGFloat *bg, vImage_Flags flags,
                                                                   vImage_Error *error)
{
    if (!colorConversionInfoRef)
        return fail(NULL, kvImageNullPointerArgument, error);
    return create(sFormat, dFormat, bg, flags, error, NULL, NULL, true);
}

unsigned long vImageConverter_GetNumberOfSourceBuffers(const vImageConverterRef converter)
{
    if (!converter || converter->magic != CONVERTER_MAGIC)
        return 0;
    unsigned long n = 0;
    while (converter->cv ? vimage_cv_source_order(converter->cv)[n] : converter->srcOrder[n])
        ++n;
    return n;
}

unsigned long vImageConverter_GetNumberOfDestinationBuffers(const vImageConverterRef converter)
{
    if (!converter || converter->magic != CONVERTER_MAGIC)
        return 0;
    unsigned long n = 0;
    while (converter->cv ? vimage_cv_destination_order(converter->cv)[n] : converter->dstOrder[n])
        ++n;
    return n;
}

const vImageBufferTypeCode *vImageConverter_GetSourceBufferOrder(vImageConverterRef converter)
{
    if (!converter || converter->magic != CONVERTER_MAGIC)
        return NULL;
    return converter->cv ? vimage_cv_source_order(converter->cv) : converter->srcOrder;
}

const vImageBufferTypeCode *vImageConverter_GetDestinationBufferOrder(vImageConverterRef converter)
{
    if (!converter || converter->magic != CONVERTER_MAGIC)
        return NULL;
    return converter->cv ? vimage_cv_destination_order(converter->cv) : converter->dstOrder;
}

/* in place works when every destination pixel is no wider than its source pixel */
vImage_Error vImageConverter_MustOperateOutOfPlace(const vImageConverterRef converter, const vImage_Buffer *srcs,
                                                   const vImage_Buffer *dests, vImage_Flags flags)
{
    if (!converter)
        return kvImageNullPointerArgument;
    if (converter->magic != CONVERTER_MAGIC)
        return kvImageInvalidParameter;
    if (flags & ~(vImage_Flags)(kvImagePrintDiagnosticsToConsole | kvImageDoNotTile | kvImageGetTempBufferSize))
        return kvImageUnknownFlagsBit;
    if (!srcs != !dests)
        return kvImageNullPointerArgument;
    if (converter->cv)
        return kvImageOutOfPlaceOperationRequired;
    return converter->dst.bpp <= converter->src.bpp ? kvImageNoError : kvImageOutOfPlaceOperationRequired;
}

/* MARK: - Converting */

/* one row: read the source, convert colour, deal with alpha, write */
static vImage_Error convert_rows(const struct vImageConverter *c, const vImage_Buffer *src, const vImage_Buffer *dest)
{
    vImagePixelCount w = dest->width;
    int sc = c->src.colors, dc = c->dst.colors;
    double *color = malloc(w * 16 * sizeof(double)), *alpha = malloc(w * sizeof(double));
    float *fin = malloc(w * 16 * sizeof(float)), *fout = malloc(w * 16 * sizeof(float));
    uint8_t *line = malloc((size_t)(((uint64_t)w * c->dst.bpp + 7) / 8) + 16);
    if (!color || !alpha || !fin || !fout || !line) {
        free(color), free(alpha), free(fin), free(fout), free(line);
        return kvImageMemoryAllocationError;
    }
    size_t lineBytes = (size_t)(((uint64_t)w * c->dst.bpp + 7) / 8);
    round_even = c->src.isFloat && c->src.bpc == 16;
    for (vImagePixelCount y = 0; y < dest->height; ++y) {
        const uint8_t *in = CROW(src, y);
        for (vImagePixelCount x = 0; x < w; ++x) {
            double a;
            read_pixel(&c->src, in, x, color + 16 * x, &a);
            alpha[x] = a;
            /* colour conversion and flattening work on unpremultiplied colour */
            bool unpremultiply = c->src.premultiplied && (c->transform || !c->dst.premultiplied || c->hasBackground);
            if (unpremultiply && !c->src.isFloat && (c->src.bpc == 8 || c->src.bpc == 16)) {
                /* 8- and 16-bit samples unpremultiply as vImage's integer functions do, at
                   8 bits when the destination has 8 */
                bool to8 = !c->transform && !c->dst.isFloat && c->dst.bpc == 8;
                double max = c->src.bpc == 8 || to8 ? 255 : 65535;
                uint64_t A = (uint64_t)floor(a * max + 0.5);
                for (int k = 0; k < sc; ++k) {
                    uint64_t C = (uint64_t)floor(color[16 * x + k] * max + 0.5);
                    color[16 * x + k] = A ? (double)(((C < A ? C : A) * (uint64_t)max + A / 2) / A) / max : 0;
                }
            } else if (unpremultiply)
                for (int k = 0; k < sc; ++k)
                    color[16 * x + k] = a > 0 ? color[16 * x + k] / a : 0;
        }
        if (c->transform) {
            for (vImagePixelCount x = 0; x < w; ++x)
                for (int k = 0; k < sc; ++k)
                    fin[(size_t)sc * x + (size_t)k] = (float)color[16 * x + k];
            ColorSyncTransformConvert(c->transform, w, 1, fout, kColorSync32BitFloat, kColorSyncByteOrderDefault,
                                      w * (size_t)dc * sizeof(float), fin, kColorSync32BitFloat,
                                      kColorSyncByteOrderDefault, w * (size_t)sc * sizeof(float), NULL);
            for (vImagePixelCount x = 0; x < w; ++x)
                for (int k = 0; k < dc; ++k)
                    color[16 * x + k] = fout[(size_t)dc * x + (size_t)k];
        }
        for (vImagePixelCount x = 0; x < w; ++x) {
            double *p = color + 16 * x, a = alpha[x];
            bool srcPremultiplied = c->src.premultiplied && !(c->transform || !c->dst.premultiplied || c->hasBackground);
            if (c->hasBackground) {
                for (int k = 0; k < dc; ++k)
                    p[k] = p[k] * a + c->background[k] * (1 - a);
                a = 1;
            } else if (c->dst.premultiplied && !srcPremultiplied)
                for (int k = 0; k < dc; ++k)
                    p[k] *= a;
            /* untouched source bytes keep the destination's padding as the source had it */
            if (x == 0)
                memset(line, 0, lineBytes);
            write_pixel(&c->dst, line, x, p, a);
        }
        memcpy(ROW(dest, y), line, lineBytes);
    }
    free(color), free(alpha), free(fin), free(fout), free(line);
    return kvImageNoError;
}

vImage_Error vImageConvert_AnyToAny(const vImageConverterRef converter, const vImage_Buffer *srcs,
                                    const vImage_Buffer *dests, void *tempBuffer, vImage_Flags flags)
{
    if (!converter || !srcs || !dests)
        return kvImageNullPointerArgument;
    if (converter->magic != CONVERTER_MAGIC)
        return kvImageInvalidParameter;
    if (flags & ~(vImage_Flags)(kvImagePrintDiagnosticsToConsole | kvImageDoNotTile | kvImageGetTempBufferSize))
        return kvImageUnknownFlagsBit;
    if (converter->cv)
        return vimage_cv_convert(converter, converter->cv, srcs, dests, flags);
    /* (Finch's conversion allocates its own row buffers; a nominal size is reported, as
       Apple's always asks for one) */
    if (flags & kvImageGetTempBufferSize)
        return (vImage_Error)(dests[0].width * 64 + 1024);
    if (!srcs[0].data || !dests[0].data)
        return kvImageInvalidParameter;
    if (srcs[0].height < dests[0].height || srcs[0].width < dests[0].width)
        return kvImageRoiLargerThanInputBuffer;
    return convert_rows(converter, &srcs[0], &dests[0]);
}

/* the converter's formats, for the CoreVideo converters */
vImage_Error vimage_convert_cg(vImageConverterRef converter, const vImage_Buffer *src, const vImage_Buffer *dest)
{
    return convert_rows(converter, src, dest);
}

/* MARK: - PNG decompression filter */

static inline uint8_t paeth(int a, int b, int c)
{
    int p = a + b - c, pa = abs(p - a), pb = abs(p - b), pc = abs(p - c);
    return (uint8_t)(pa <= pb && pa <= pc ? a : pb <= pc ? b : c);
}

vImage_Error vImagePNGDecompressionFilter(const vImage_Buffer *buffer, vImagePixelCount startScanline,
                                          vImagePixelCount scanlineCount, uint32_t bitsPerPixel,
                                          uint32_t filterMethodNumber, uint32_t filterType, vImage_Flags flags)
{
    if (!buffer || !buffer->data)
        return kvImageNullPointerArgument;
    /* (Apple's does not check the method or type: others leave the data as it was) */
    if (filterMethodNumber != 0 || filterType > kvImage_PNG_FILTER_VALUE_PAETH)
        return kvImageNoError;
    if (startScanline + scanlineCount > buffer->height)
        return kvImageInvalidParameter;
    size_t bpp = (bitsPerPixel + 7) / 8 ? (bitsPerPixel + 7) / 8 : 1, bytes = ((size_t)buffer->width * bitsPerPixel + 7) / 8;
    for (vImagePixelCount y = startScanline; y < startScanline + scanlineCount; ++y) {
        uint8_t *row = ROW(buffer, y);
        const uint8_t *up = y ? ROW(buffer, y - 1) : NULL;
        for (size_t i = 0; i < bytes; ++i) {
            int a = i >= bpp ? row[i - bpp] : 0, b = up ? up[i] : 0, c = up && i >= bpp ? up[i - bpp] : 0;
            switch (filterType) {
            case kvImage_PNG_FILTER_VALUE_SUB:
                row[i] = (uint8_t)(row[i] + a);
                break;
            case kvImage_PNG_FILTER_VALUE_UP:
                row[i] = (uint8_t)(row[i] + b);
                break;
            case kvImage_PNG_FILTER_VALUE_AVG:
                row[i] = (uint8_t)(row[i] + (a + b) / 2);
                break;
            case kvImage_PNG_FILTER_VALUE_PAETH:
                row[i] = (uint8_t)(row[i] + paeth(a, b, c));
                break;
            default:
                break;
            }
        }
    }
    (void)flags;
    return kvImageNoError;
}
