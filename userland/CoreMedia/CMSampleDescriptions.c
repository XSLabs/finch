/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Video format descriptions to and from QuickTime and ISO image descriptions
 * ('stsd' video sample entries), Finch's, laid out as Apple's: the fixed header (the
 * data reference index left 0xffff, quality 512 for QuickTime and 0 for ISO, the
 * compressor name the format name or the codec in quotes, depth 24), the extension
 * atoms, then those written from extensions: 'colr' ('nclc', or 'nclx' with the range
 * for ISO), 'gama', 'fiel', 'chrm', 'pasp', 'clap'; QuickTime's ends with four zero
 * bytes. Read back, a description keeps the whole of what it was made from, which is
 * written out again as it was.
 */
#include "CMInternal.h"
#include <CoreVideo/CoreVideo.h>
#include <libkern/OSByteOrder.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    UInt8 *bytes;
    size_t size, capacity;
} Out;

static void
grow(Out *o, size_t n)
{
    if (o->size + n > o->capacity) {
        o->capacity = (o->size + n) * 2;
        o->bytes = realloc(o->bytes, o->capacity);
    }
}

static void
put(Out *o, const void *p, size_t n)
{
    grow(o, n);
    memcpy(o->bytes + o->size, p, n);
    o->size += n;
}

static void
put8(Out *o, uint32_t v)
{
    UInt8 b = (UInt8)v;
    put(o, &b, 1);
}

static void
put16(Out *o, uint32_t v)
{
    UInt8 b[2] = {(UInt8)(v >> 8), (UInt8)v};
    put(o, b, 2);
}

static void
put32(Out *o, uint32_t v)
{
    UInt8 b[4] = {(UInt8)(v >> 24), (UInt8)(v >> 16), (UInt8)(v >> 8), (UInt8)v};
    put(o, b, 4);
}

static uint32_t
get16(const UInt8 *p)
{
    return (uint32_t)p[0] << 8 | p[1];
}

static uint32_t
get32(const UInt8 *p)
{
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

static uint32_t
fourcc(CFStringRef s)
{
    char b[8] = {0};
    CFStringGetCString(s, b, sizeof b, kCFStringEncodingMacRoman);
    return (uint32_t)(UInt8)b[0] << 24 | (uint32_t)(UInt8)b[1] << 16 | (uint32_t)(UInt8)b[2] << 8 | (UInt8)b[3];
}

static bool
number(CFTypeRef v, double *out)
{
    if (v && CFGetTypeID(v) == CFBooleanGetTypeID()) {
        *out = CFBooleanGetValue(v);
        return true;
    }
    if (v && CFGetTypeID(v) == CFNumberGetTypeID())
        return CFNumberGetValue(v, kCFNumberDoubleType, out);
    if (v && CFGetTypeID(v) == CFStringGetTypeID()) {
        *out = CFStringGetDoubleValue(v);
        return true;
    }
    return false;
}

static int
ext_int(CFDictionaryRef ext, CFStringRef key, int otherwise)
{
    double d;
    return ext && number(CFDictionaryGetValue(ext, key), &d) ? (int)d : otherwise;
}

/* A rational from a number or a [numerator, denominator] array. */
static bool
rational(CFTypeRef v, int32_t *n, int32_t *d)
{
    if (v && CFGetTypeID(v) == CFArrayGetTypeID() && CFArrayGetCount(v) == 2) {
        double a, b;
        if (number(CFArrayGetValueAtIndex(v, 0), &a) && number(CFArrayGetValueAtIndex(v, 1), &b)) {
            *n = (int32_t)a, *d = (int32_t)b;
            return true;
        }
    }
    double x;
    if (!number(v, &x))
        return false;
    *n = (int32_t)x, *d = 1;
    return true;
}

static const struct {
    CFStringRef *name;
    uint32_t code;
} field_details[] = {
    {(CFStringRef *)&kCMFormatDescriptionFieldDetail_TemporalTopFirst, 1},
    {(CFStringRef *)&kCMFormatDescriptionFieldDetail_TemporalBottomFirst, 6},
    {(CFStringRef *)&kCMFormatDescriptionFieldDetail_SpatialFirstLineEarly, 9},
    {(CFStringRef *)&kCMFormatDescriptionFieldDetail_SpatialFirstLineLate, 14},
};

static CFStringRef
chroma_name(uint32_t code)
{
    CFStringRef names[] = {kCVImageBufferChromaLocation_Left,    kCVImageBufferChromaLocation_Center,     kCVImageBufferChromaLocation_TopLeft,
                           kCVImageBufferChromaLocation_Top,     kCVImageBufferChromaLocation_BottomLeft, kCVImageBufferChromaLocation_Bottom,
                           kCVImageBufferChromaLocation_DV420};
    return code < 7 ? names[code] : NULL;
}

static int
chroma_code(CFTypeRef name)
{
    for (uint32_t i = 0; i < 7; i++)
        if (name && CFEqual(name, chroma_name(i)))
            return (int)i;
    return -1;
}

static bool
iso_flavor(CFStringRef flavor)
{
    return flavor && (CFEqual(flavor, kCMImageDescriptionFlavor_ISOFamily) || CFEqual(flavor, kCMImageDescriptionFlavor_3GPFamily) ||
                      CFEqual(flavor, kCMImageDescriptionFlavor_ISOFamilyWithAppleExtensions));
}

static void
put_atom_data(Out *o, CFStringRef type, CFDataRef data)
{
    put32(o, (uint32_t)(8 + CFDataGetLength(data)));
    put32(o, fourcc(type));
    put(o, CFDataGetBytePtr(data), (size_t)CFDataGetLength(data));
}

static void
put_extension_atoms(Out *o, CFDictionaryRef atoms)
{
    if (!atoms || CFGetTypeID(atoms) != CFDictionaryGetTypeID())
        return;
    CFIndex n = CFDictionaryGetCount(atoms);
    const void **keys = malloc(sizeof(void *) * (size_t)(n ? n : 1) * 2), **values = keys + n;
    CFDictionaryGetKeysAndValues(atoms, keys, values);
    for (CFIndex i = 0; i < n; i++) {
        if (CFGetTypeID(values[i]) == CFDataGetTypeID())
            put_atom_data(o, keys[i], values[i]);
        else if (CFGetTypeID(values[i]) == CFArrayGetTypeID())
            for (CFIndex k = 0; k < CFArrayGetCount(values[i]); k++)
                put_atom_data(o, keys[i], CFArrayGetValueAtIndex(values[i], k));
    }
    free(keys);
}

OSStatus
CMVideoFormatDescriptionCopyAsBigEndianImageDescriptionBlockBuffer(CFAllocatorRef allocator, CMVideoFormatDescriptionRef videoFormatDescription,
                                                                   CFStringEncoding stringEncoding, CMImageDescriptionFlavor flavor,
                                                                   CMBlockBufferRef *blockBufferOut)
{
    if (!videoFormatDescription || !blockBufferOut || CMFormatDescriptionGetMediaType(videoFormatDescription) != kCMMediaType_Video)
        return kCMFormatDescriptionBridgeError_InvalidParameter;
    *blockBufferOut = NULL;
    bool iso = iso_flavor(flavor);
    CFDictionaryRef ext = CMFormatDescriptionGetExtensions(videoFormatDescription);
    /* (what it was made from, as it was) */
    CFDataRef verbatim = CMFormatDescriptionGetExtension(videoFormatDescription, iso ? CFSTR("VerbatimISOSampleEntry") : kCMFormatDescriptionExtension_VerbatimSampleDescription);
    if (verbatim && CFGetTypeID(verbatim) == CFDataGetTypeID()) {
        size_t n = (size_t)CFDataGetLength(verbatim);
        OSStatus e = CMBlockBufferCreateWithMemoryBlock(allocator, NULL, n, allocator, NULL, 0, n, kCMBlockBufferAssureMemoryNowFlag, blockBufferOut);
        if (!e)
            CMBlockBufferReplaceDataBytes(CFDataGetBytePtr(verbatim), *blockBufferOut, 0, n);
        return e;
    }
    FourCharCode codec = CMFormatDescriptionGetMediaSubType(videoFormatDescription);
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(videoFormatDescription);
    Out o = {0};
    put32(&o, 0);
    put32(&o, codec);
    put32(&o, 0), put16(&o, 0);
    put16(&o, 0xffff);
    put16(&o, (uint32_t)ext_int(ext, kCMFormatDescriptionExtension_Version, 0));
    put16(&o, (uint32_t)ext_int(ext, kCMFormatDescriptionExtension_RevisionLevel, 0));
    CFTypeRef vendor = ext ? CFDictionaryGetValue(ext, kCMFormatDescriptionExtension_Vendor) : NULL;
    put32(&o, vendor && CFGetTypeID(vendor) == CFStringGetTypeID() ? fourcc(vendor) : 0);
    put32(&o, (uint32_t)ext_int(ext, kCMFormatDescriptionExtension_TemporalQuality, iso ? 0 : 512));
    put32(&o, (uint32_t)ext_int(ext, kCMFormatDescriptionExtension_SpatialQuality, iso ? 0 : 512));
    put16(&o, (uint32_t)dims.width), put16(&o, (uint32_t)dims.height);
    put32(&o, 0x00480000), put32(&o, 0x00480000);
    put32(&o, 0);
    put16(&o, 1);
    /* (the compressor name: a Pascal string in 32 bytes) */
    UInt8 name[32] = {0};
    if (!iso) {
        CFStringRef formatName = ext ? CFDictionaryGetValue(ext, kCMFormatDescriptionExtension_FormatName) : NULL;
        char buf[64];
        if (formatName && CFGetTypeID(formatName) == CFStringGetTypeID() && CFStringGetCString(formatName, buf, sizeof buf, stringEncoding))
            ;
        else
            snprintf(buf, sizeof buf, "'%c%c%c%c'", (char)(codec >> 24), (char)(codec >> 16), (char)(codec >> 8), (char)codec);
        size_t len = strlen(buf) > 31 ? 31 : strlen(buf);
        name[0] = (UInt8)len;
        memcpy(name + 1, buf, len);
    }
    put(&o, name, 32);
    put16(&o, (uint32_t)ext_int(ext, kCMFormatDescriptionExtension_Depth, 24));
    put16(&o, 0xffff);
    /* (the atoms) */
    put_extension_atoms(&o, ext ? CFDictionaryGetValue(ext, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) : NULL);
    CFTypeRef p = ext ? CFDictionaryGetValue(ext, kCMFormatDescriptionExtension_ColorPrimaries) : NULL;
    CFTypeRef t = ext ? CFDictionaryGetValue(ext, kCMFormatDescriptionExtension_TransferFunction) : NULL;
    CFTypeRef m = ext ? CFDictionaryGetValue(ext, kCMFormatDescriptionExtension_YCbCrMatrix) : NULL;
    if (p || t || m) {
        put32(&o, iso ? 19 : 18);
        put32(&o, 'colr');
        put32(&o, iso ? 'nclx' : 'nclc');
        put16(&o, p ? (uint32_t)CVColorPrimariesGetIntegerCodePointForString(p) : 2);
        put16(&o, t ? (uint32_t)CVTransferFunctionGetIntegerCodePointForString(t) : 2);
        put16(&o, m ? (uint32_t)CVYCbCrMatrixGetIntegerCodePointForString(m) : 2);
        if (iso)
            put8(&o, ext_int(ext, kCMFormatDescriptionExtension_FullRangeVideo, 0) ? 0x80 : 0);
    }
    double gamma;
    if (ext && number(CFDictionaryGetValue(ext, kCMFormatDescriptionExtension_GammaLevel), &gamma)) {
        put32(&o, 12), put32(&o, 'gama');
        put32(&o, (uint32_t)lround(gamma * 65536));
    }
    int fields = ext_int(ext, kCMFormatDescriptionExtension_FieldCount, 0);
    if (fields) {
        CFTypeRef detail = CFDictionaryGetValue(ext, kCMFormatDescriptionExtension_FieldDetail);
        uint32_t code = 0;
        for (size_t i = 0; detail && i < sizeof field_details / sizeof field_details[0]; i++)
            if (CFEqual(detail, *field_details[i].name))
                code = field_details[i].code;
        put32(&o, 10), put32(&o, 'fiel');
        put8(&o, (uint32_t)fields), put8(&o, code);
    }
    int top = chroma_code(ext ? CFDictionaryGetValue(ext, kCMFormatDescriptionExtension_ChromaLocationTopField) : NULL);
    int bottom = chroma_code(ext ? CFDictionaryGetValue(ext, kCMFormatDescriptionExtension_ChromaLocationBottomField) : NULL);
    if (top >= 0 || bottom >= 0) {
        put32(&o, 10), put32(&o, 'chrm');
        put8(&o, (uint32_t)(top < 0 ? 0 : top)), put8(&o, (uint32_t)(bottom < 0 ? 0 : bottom));
    }
    CFDictionaryRef par = ext ? CFDictionaryGetValue(ext, kCMFormatDescriptionExtension_PixelAspectRatio) : NULL;
    double hs, vs;
    if (par && CFGetTypeID(par) == CFDictionaryGetTypeID() && number(CFDictionaryGetValue(par, kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing), &hs) &&
        number(CFDictionaryGetValue(par, kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing), &vs)) {
        put32(&o, 16), put32(&o, 'pasp');
        put32(&o, (uint32_t)hs), put32(&o, (uint32_t)vs);
    }
    CFDictionaryRef clap = ext ? CFDictionaryGetValue(ext, kCMFormatDescriptionExtension_CleanAperture) : NULL;
    int32_t r[8];
    if (clap && CFGetTypeID(clap) == CFDictionaryGetTypeID() &&
        rational(CFDictionaryGetValue(clap, kCMFormatDescriptionKey_CleanApertureWidth), &r[0], &r[1]) &&
        rational(CFDictionaryGetValue(clap, kCMFormatDescriptionKey_CleanApertureHeight), &r[2], &r[3])) {
        if (!rational(CFDictionaryGetValue(clap, kCMFormatDescriptionKey_CleanApertureHorizontalOffset), &r[4], &r[5]))
            r[4] = 0, r[5] = 1;
        if (!rational(CFDictionaryGetValue(clap, kCMFormatDescriptionKey_CleanApertureVerticalOffset), &r[6], &r[7]))
            r[6] = 0, r[7] = 1;
        put32(&o, 40), put32(&o, 'clap');
        for (int i = 0; i < 8; i++)
            put32(&o, (uint32_t)r[i]);
    }
    if (!iso)
        put32(&o, 0);
    o.bytes[0] = (UInt8)(o.size >> 24), o.bytes[1] = (UInt8)(o.size >> 16), o.bytes[2] = (UInt8)(o.size >> 8), o.bytes[3] = (UInt8)o.size;
    OSStatus e = CMBlockBufferCreateWithMemoryBlock(allocator, NULL, o.size, allocator, NULL, 0, o.size, kCMBlockBufferAssureMemoryNowFlag, blockBufferOut);
    if (!e)
        CMBlockBufferReplaceDataBytes(o.bytes, *blockBufferOut, 0, o.size);
    free(o.bytes);
    return e;
}

static void
set_int(CFMutableDictionaryRef d, CFStringRef key, long long v)
{
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberLongLongType, &v);
    CFDictionarySetValue(d, key, n);
    CFRelease(n);
}

static CFArrayRef
rational_array(int32_t n, int32_t d)
{
    CFNumberRef a = CFNumberCreate(NULL, kCFNumberSInt32Type, &n), b = CFNumberCreate(NULL, kCFNumberSInt32Type, &d);
    CFArrayRef arr = CFArrayCreate(NULL, (const void *[]){a, b}, 2, &kCFTypeArrayCallBacks);
    CFRelease(a);
    CFRelease(b);
    return arr;
}

/* A rational as Apple's records it read back: a number when the denominator is 1. */
static void
set_rational(CFMutableDictionaryRef d, CFStringRef key, int32_t n, int32_t den)
{
    if (den == 1)
        set_int(d, key, n);
    else {
        CFArrayRef a = rational_array(n, den);
        CFDictionarySetValue(d, key, a);
        CFRelease(a);
    }
}

OSStatus
CMVideoFormatDescriptionCreateFromBigEndianImageDescriptionData(CFAllocatorRef allocator, const uint8_t *imageDescriptionData, size_t size,
                                                                CFStringEncoding stringEncoding, CMImageDescriptionFlavor flavor,
                                                                CMVideoFormatDescriptionRef *formatDescriptionOut)
{
    if (!imageDescriptionData || !formatDescriptionOut || size < 86)
        return kCMFormatDescriptionBridgeError_InvalidParameter;
    *formatDescriptionOut = NULL;
    const UInt8 *b = imageDescriptionData;
    size_t total = get32(b);
    if (total < 86 || total > size)
        return kCMFormatDescriptionBridgeError_InvalidSerializedSampleDescription;
    bool iso = iso_flavor(flavor);
    FourCharCode codec = get32(b + 4);
    CFMutableDictionaryRef ext = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    set_int(ext, kCMFormatDescriptionExtension_Version, get16(b + 16));
    set_int(ext, kCMFormatDescriptionExtension_RevisionLevel, get16(b + 18));
    uint32_t vendor = get32(b + 20);
    if (vendor) {
        char v[5] = {(char)(vendor >> 24), (char)(vendor >> 16), (char)(vendor >> 8), (char)vendor, 0};
        CFStringRef s = CFStringCreateWithCString(NULL, v, kCFStringEncodingMacRoman);
        CFDictionarySetValue(ext, kCMFormatDescriptionExtension_Vendor, s);
        CFRelease(s);
    }
    set_int(ext, kCMFormatDescriptionExtension_TemporalQuality, get32(b + 24));
    set_int(ext, kCMFormatDescriptionExtension_SpatialQuality, get32(b + 28));
    int32_t width = (int32_t)get16(b + 32), height = (int32_t)get16(b + 34);
    size_t nameLength = b[50] > 31 ? 31 : b[50];
    CFStringRef formatName = nameLength ? CFStringCreateWithBytes(NULL, b + 51, (CFIndex)nameLength, stringEncoding, false) : NULL;
    if (!formatName) {
        char q[8];
        snprintf(q, sizeof q, "'%c%c%c%c'", (char)(codec >> 24), (char)(codec >> 16), (char)(codec >> 8), (char)codec);
        formatName = CFStringCreateWithCString(NULL, q, kCFStringEncodingMacRoman);
    }
    CFDictionarySetValue(ext, kCMFormatDescriptionExtension_FormatName, formatName);
    CFRelease(formatName);
    set_int(ext, kCMFormatDescriptionExtension_Depth, get16(b + 82));
    /* (the atoms: those that are extensions read into them, the rest kept as they are) */
    CFMutableDictionaryRef atoms = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    for (size_t at = 86; at + 8 <= total;) {
        size_t n = get32(b + at);
        if (n < 8 || at + n > total)
            break;
        uint32_t type = get32(b + at + 4);
        const UInt8 *body = b + at + 8;
        size_t len = n - 8;
        if (type == 'colr' && len >= 10 && (get32(body) == 'nclc' || get32(body) == 'nclx')) {
            CFStringRef pr = CVColorPrimariesGetStringForIntegerCodePoint((int)get16(body + 4));
            CFStringRef tf = CVTransferFunctionGetStringForIntegerCodePoint((int)get16(body + 6));
            CFStringRef mx = CVYCbCrMatrixGetStringForIntegerCodePoint((int)get16(body + 8));
            if (pr)
                CFDictionarySetValue(ext, kCMFormatDescriptionExtension_ColorPrimaries, pr);
            if (tf)
                CFDictionarySetValue(ext, kCMFormatDescriptionExtension_TransferFunction, tf);
            if (mx)
                CFDictionarySetValue(ext, kCMFormatDescriptionExtension_YCbCrMatrix, mx);
            if (get32(body) == 'nclx' && len >= 11)
                CFDictionarySetValue(ext, kCMFormatDescriptionExtension_FullRangeVideo, (body[10] & 0x80) ? kCFBooleanTrue : kCFBooleanFalse);
        } else if (type == 'gama' && len >= 4) {
            double g = (double)get32(body) / 65536;
            CFNumberRef gn = CFNumberCreate(NULL, kCFNumberDoubleType, &g);
            CFDictionarySetValue(ext, kCMFormatDescriptionExtension_GammaLevel, gn);
            CFRelease(gn);
        } else if (type == 'fiel' && len >= 2) {
            set_int(ext, kCMFormatDescriptionExtension_FieldCount, body[0]);
            for (size_t i = 0; i < sizeof field_details / sizeof field_details[0]; i++)
                if (field_details[i].code == body[1])
                    CFDictionarySetValue(ext, kCMFormatDescriptionExtension_FieldDetail, *field_details[i].name);
        } else if (type == 'chrm' && len >= 2) {
            CFStringRef top = chroma_name(body[0]), bottom = chroma_name(body[1]);
            if (top)
                CFDictionarySetValue(ext, kCMFormatDescriptionExtension_ChromaLocationTopField, top);
            if (bottom)
                CFDictionarySetValue(ext, kCMFormatDescriptionExtension_ChromaLocationBottomField, bottom);
        } else if (type == 'pasp' && len >= 8) {
            CFMutableDictionaryRef par = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            set_int(par, kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing, get32(body));
            set_int(par, kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing, get32(body + 4));
            CFDictionarySetValue(ext, kCMFormatDescriptionExtension_PixelAspectRatio, par);
            CFRelease(par);
        } else if (type == 'clap' && len >= 32) {
            CFMutableDictionaryRef clap = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            CFStringRef keys[] = {kCMFormatDescriptionKey_CleanApertureWidth, kCMFormatDescriptionKey_CleanApertureHeight,
                                  kCMFormatDescriptionKey_CleanApertureHorizontalOffset, kCMFormatDescriptionKey_CleanApertureVerticalOffset};
            for (int i = 0; i < 4; i++)
                set_rational(clap, keys[i], (int32_t)get32(body + 8 * i), (int32_t)get32(body + 8 * i + 4));
            CFDictionarySetValue(ext, kCMFormatDescriptionExtension_CleanAperture, clap);
            CFRelease(clap);
        } else {
            char t[5] = {(char)(type >> 24), (char)(type >> 16), (char)(type >> 8), (char)type, 0};
            CFStringRef key = CFStringCreateWithCString(NULL, t, kCFStringEncodingMacRoman);
            CFDataRef data = CFDataCreate(NULL, body, (CFIndex)len);
            CFTypeRef existing = CFDictionaryGetValue(atoms, key);
            if (!existing)
                CFDictionarySetValue(atoms, key, data);
            else {
                /* (an atom that's there more than once: an array of them) */
                CFMutableArrayRef all = CFGetTypeID(existing) == CFArrayGetTypeID() ? CFArrayCreateMutableCopy(NULL, 0, existing)
                                                                                   : CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
                if (CFGetTypeID(existing) != CFArrayGetTypeID())
                    CFArrayAppendValue(all, existing);
                CFArrayAppendValue(all, data);
                CFDictionarySetValue(atoms, key, all);
                CFRelease(all);
            }
            CFRelease(data);
            CFRelease(key);
        }
        at += n;
    }
    if (CFDictionaryGetCount(atoms))
        CFDictionarySetValue(ext, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms, atoms);
    CFRelease(atoms);
    CFDataRef verbatim = CFDataCreate(NULL, b, (CFIndex)total);
    CFDictionarySetValue(ext, iso ? CFSTR("VerbatimISOSampleEntry") : kCMFormatDescriptionExtension_VerbatimSampleDescription, verbatim);
    CFRelease(verbatim);
    OSStatus e = CMVideoFormatDescriptionCreate(allocator, codec, width, height, ext, formatDescriptionOut);
    CFRelease(ext);
    return e;
}

OSStatus
CMVideoFormatDescriptionCreateFromBigEndianImageDescriptionBlockBuffer(CFAllocatorRef allocator, CMBlockBufferRef imageDescriptionBlockBuffer,
                                                                       CFStringEncoding stringEncoding, CMImageDescriptionFlavor flavor,
                                                                       CMVideoFormatDescriptionRef *formatDescriptionOut)
{
    if (!imageDescriptionBlockBuffer || !formatDescriptionOut)
        return kCMFormatDescriptionBridgeError_InvalidParameter;
    size_t n = CMBlockBufferGetDataLength(imageDescriptionBlockBuffer);
    uint8_t *bytes = malloc(n ? n : 1);
    OSStatus e = n ? CMBlockBufferCopyDataBytes(imageDescriptionBlockBuffer, 0, n, bytes) : kCMFormatDescriptionBridgeError_InvalidParameter;
    if (!e)
        e = CMVideoFormatDescriptionCreateFromBigEndianImageDescriptionData(allocator, bytes, n, stringEncoding, flavor, formatDescriptionOut);
    free(bytes);
    return e;
}

/* The fixed header's integer fields swapped in place (an ImageDescription: 86 bytes). */
static void
swap_image_description(uint8_t *d, bool toHost)
{
    static const struct {
        size_t at, size;
    } fields[] = {{0, 4}, {4, 4}, {8, 4}, {12, 2}, {14, 2}, {16, 2}, {18, 2}, {20, 4}, {24, 4}, {28, 4}, {32, 2}, {34, 2},
                  {36, 4}, {40, 4}, {44, 4}, {48, 2}, {82, 2}, {84, 2}};
    for (size_t i = 0; i < sizeof fields / sizeof fields[0]; i++) {
        uint8_t *p = d + fields[i].at;
        if (fields[i].size == 4) {
            uint32_t v;
            memcpy(&v, p, 4);
            v = OSSwapInt32(v);
            memcpy(p, &v, 4);
        } else {
            uint16_t v;
            memcpy(&v, p, 2);
            v = OSSwapInt16(v);
            memcpy(p, &v, 2);
        }
    }
    (void)toHost;
}

OSStatus
CMSwapBigEndianImageDescriptionToHost(uint8_t *imageDescriptionData, size_t imageDescriptionSize)
{
    if (!imageDescriptionData)
        return kCMFormatDescriptionBridgeError_InvalidParameter;
    if (imageDescriptionSize < 86)
        return kCMFormatDescriptionBridgeError_InvalidSerializedSampleDescription;
    swap_image_description(imageDescriptionData, true);
    return noErr;
}

OSStatus
CMSwapHostEndianImageDescriptionToBig(uint8_t *imageDescriptionData, size_t imageDescriptionSize)
{
    if (!imageDescriptionData)
        return kCMFormatDescriptionBridgeError_InvalidParameter;
    if (imageDescriptionSize < 86)
        return kCMFormatDescriptionBridgeError_InvalidSerializedSampleDescription;
    swap_image_description(imageDescriptionData, false);
    return noErr;
}
