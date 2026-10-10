/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Format descriptions from H.264 and HEVC parameter sets, Finch's: the sequence
 * parameter set read (ITU-T H.264 7.3.2.1 and H.265 7.3.2.2: dimensions after cropping,
 * chroma format, bit depths, field coding, the VUI's aspect ratio, range, colour and
 * chroma location) and the decoder configuration record written as ISO/IEC 14496-15
 * lays it out ('avcC', 'hvcC'), as the format description's extension atom. The sets
 * are read back out of that record.
 */
#include "CMInternal.h"
#include <CoreVideo/CoreVideo.h>
#include <stdlib.h>
#include <string.h>

#define kParameterSetError -12712 /* (kCMFormatDescriptionBridgeError_InvalidParameter) */

/* --- reading bits --- */

typedef struct {
    uint8_t *data; /* (the RBSP: emulation prevention bytes removed) */
    size_t size, bit;
    bool overrun;
} Bits;

static void
bits_init(Bits *b, const uint8_t *nal, size_t size)
{
    b->data = malloc(size ? size : 1);
    b->size = 0;
    for (size_t i = 0, zeros = 0; i < size; i++) {
        if (zeros >= 2 && nal[i] == 3) {
            zeros = 0;
            continue;
        }
        zeros = nal[i] == 0 ? zeros + 1 : 0;
        b->data[b->size++] = nal[i];
    }
    b->bit = 0;
    b->overrun = false;
}

static uint32_t
u(Bits *b, int n)
{
    uint32_t v = 0;
    for (int i = 0; i < n; i++) {
        if (b->bit >= b->size * 8) {
            b->overrun = true;
            return v << (n - i);
        }
        v = (v << 1) | ((b->data[b->bit / 8] >> (7 - b->bit % 8)) & 1);
        b->bit++;
    }
    return v;
}

static uint32_t
ue(Bits *b)
{
    int zeros = 0;
    while (!u(b, 1) && !b->overrun && zeros < 32)
        zeros++;
    return zeros ? ((1u << zeros) - 1) + u(b, zeros) : 0;
}

static int32_t
se(Bits *b)
{
    uint32_t k = ue(b);
    return (k & 1) ? (int32_t)((k + 1) / 2) : -(int32_t)(k / 2);
}

/* --- what the sequence parameter set says --- */

typedef struct {
    int32_t width, height;
    uint32_t chromaFormat, bitDepthLuma, bitDepthChroma;
    bool frameMbsOnly;
    uint32_t sarWidth, sarHeight;
    bool hasRange, fullRange;
    bool hasColour;
    uint32_t primaries, transfer, matrix;
    bool hasChromaLoc;
    uint32_t chromaLocTop, chromaLocBottom;
    /* HEVC */
    uint32_t maxSubLayers;
    bool temporalIdNesting;
    uint8_t ptl[12]; /* profile space, tier, profile; compatibility flags; constraint flags; level */
} SPS;

static const uint16_t sar_table[17][2] = {{0, 0},    {1, 1},   {12, 11}, {10, 11}, {16, 11}, {40, 33}, {24, 11}, {20, 11}, {32, 11},
                                          {80, 33},  {18, 11}, {15, 11}, {64, 33}, {160, 99}, {4, 3},  {3, 2},   {2, 1}};

/* The VUI's aspect ratio, video signal type and chroma location (the parts the two share). */
static void
vui_common(Bits *b, SPS *s)
{
    if (u(b, 1)) { /* aspect_ratio_info_present_flag */
        uint32_t idc = u(b, 8);
        if (idc == 255) {
            s->sarWidth = u(b, 16);
            s->sarHeight = u(b, 16);
        } else if (idc < 17) {
            s->sarWidth = sar_table[idc][0];
            s->sarHeight = sar_table[idc][1];
        }
    }
    if (u(b, 1)) /* overscan_info_present_flag */
        u(b, 1);
    if (u(b, 1)) { /* video_signal_type_present_flag */
        u(b, 3);
        s->hasRange = true;
        s->fullRange = u(b, 1);
        if (u(b, 1)) {
            s->hasColour = true;
            s->primaries = u(b, 8);
            s->transfer = u(b, 8);
            s->matrix = u(b, 8);
        }
    }
    if (u(b, 1)) { /* chroma_loc_info_present_flag */
        s->hasChromaLoc = true;
        s->chromaLocTop = ue(b);
        s->chromaLocBottom = ue(b);
    }
}

static void
skip_scaling_list(Bits *b, int size)
{
    int32_t last = 8, next = 8;
    for (int j = 0; j < size; j++) {
        if (next)
            next = (last + se(b) + 256) % 256;
        last = next ? next : last;
    }
}

static bool
parse_h264_sps(const uint8_t *nal, size_t size, SPS *s)
{
    memset(s, 0, sizeof *s);
    if (size < 4 || (nal[0] & 0x1f) != 7)
        return false;
    Bits b;
    bits_init(&b, nal + 1, size - 1);
    uint32_t profile = u(&b, 8);
    u(&b, 8);
    u(&b, 8);
    ue(&b);
    s->chromaFormat = 1;
    s->bitDepthLuma = s->bitDepthChroma = 8;
    if (profile == 100 || profile == 110 || profile == 122 || profile == 244 || profile == 44 || profile == 83 || profile == 86 || profile == 118 ||
        profile == 128 || profile == 138 || profile == 139 || profile == 134 || profile == 135) {
        s->chromaFormat = ue(&b);
        if (s->chromaFormat == 3)
            u(&b, 1);
        s->bitDepthLuma = 8 + ue(&b);
        s->bitDepthChroma = 8 + ue(&b);
        u(&b, 1);
        if (u(&b, 1))
            for (int i = 0; i < (s->chromaFormat != 3 ? 8 : 12); i++)
                if (u(&b, 1))
                    skip_scaling_list(&b, i < 6 ? 16 : 64);
    }
    ue(&b); /* log2_max_frame_num_minus4 */
    uint32_t pocType = ue(&b);
    if (pocType == 0)
        ue(&b);
    else if (pocType == 1) {
        u(&b, 1);
        se(&b);
        se(&b);
        uint32_t n = ue(&b);
        for (uint32_t i = 0; i < n && !b.overrun; i++)
            se(&b);
    }
    ue(&b);
    u(&b, 1);
    uint32_t widthMbs = ue(&b) + 1, heightUnits = ue(&b) + 1;
    s->frameMbsOnly = u(&b, 1);
    if (!s->frameMbsOnly)
        u(&b, 1);
    u(&b, 1);
    uint32_t crop[4] = {0, 0, 0, 0};
    if (u(&b, 1))
        for (int i = 0; i < 4; i++)
            crop[i] = ue(&b);
    uint32_t subW = s->chromaFormat == 1 || s->chromaFormat == 2 ? 2 : 1, subH = s->chromaFormat == 1 ? 2 : 1;
    uint32_t cropX = s->chromaFormat ? subW : 1, cropY = (s->chromaFormat ? subH : 1) * (2 - s->frameMbsOnly);
    s->width = (int32_t)(widthMbs * 16 - cropX * (crop[0] + crop[1]));
    s->height = (int32_t)((2 - s->frameMbsOnly) * heightUnits * 16 - cropY * (crop[2] + crop[3]));
    if (u(&b, 1))
        vui_common(&b, s);
    bool ok = !b.overrun || s->width > 0;
    free(b.data);
    return ok && s->width > 0 && s->height > 0;
}

static void
parse_ptl(Bits *b, SPS *s, uint32_t maxSubLayersMinus1)
{
    for (int i = 0; i < 12; i++)
        s->ptl[i] = (uint8_t)u(b, 8);
    bool subProfile[8], subLevel[8];
    for (uint32_t i = 0; i < maxSubLayersMinus1; i++) {
        subProfile[i] = u(b, 1);
        subLevel[i] = u(b, 1);
    }
    if (maxSubLayersMinus1 > 0)
        for (uint32_t i = maxSubLayersMinus1; i < 8; i++)
            u(b, 2);
    for (uint32_t i = 0; i < maxSubLayersMinus1; i++) {
        if (subProfile[i])
            u(b, 32), u(b, 32), u(b, 24);
        if (subLevel[i])
            u(b, 8);
    }
}

static bool
parse_hevc_sps(const uint8_t *nal, size_t size, SPS *s)
{
    memset(s, 0, sizeof *s);
    if (size < 4 || ((nal[0] >> 1) & 0x3f) != 33)
        return false;
    Bits b;
    bits_init(&b, nal + 2, size - 2);
    u(&b, 4);
    uint32_t maxSubLayersMinus1 = u(&b, 3);
    s->maxSubLayers = maxSubLayersMinus1 + 1;
    s->temporalIdNesting = u(&b, 1);
    parse_ptl(&b, s, maxSubLayersMinus1);
    ue(&b);
    s->chromaFormat = ue(&b);
    if (s->chromaFormat == 3)
        u(&b, 1);
    uint32_t w = ue(&b), h = ue(&b);
    uint32_t crop[4] = {0, 0, 0, 0};
    if (u(&b, 1))
        for (int i = 0; i < 4; i++)
            crop[i] = ue(&b);
    uint32_t subW = s->chromaFormat == 1 || s->chromaFormat == 2 ? 2 : 1, subH = s->chromaFormat == 1 ? 2 : 1;
    s->width = (int32_t)(w - subW * (crop[0] + crop[1]));
    s->height = (int32_t)(h - subH * (crop[2] + crop[3]));
    s->bitDepthLuma = 8 + ue(&b);
    s->bitDepthChroma = 8 + ue(&b);
    s->frameMbsOnly = true;
    /* (the rest, as far as the VUI) */
    uint32_t log2MaxPocLsb = ue(&b) + 4;
    bool subLayerOrdering = u(&b, 1);
    for (uint32_t i = subLayerOrdering ? 0 : maxSubLayersMinus1; i <= maxSubLayersMinus1; i++)
        ue(&b), ue(&b), ue(&b);
    ue(&b), ue(&b), ue(&b), ue(&b), ue(&b), ue(&b);
    if (u(&b, 1) && u(&b, 1)) { /* scaling_list_enabled, sps_scaling_list_data_present */
        for (int sizeId = 0; sizeId < 4; sizeId++)
            for (int matrixId = 0; matrixId < 6; matrixId += sizeId == 3 ? 3 : 1) {
                if (!u(&b, 1))
                    ue(&b);
                else {
                    int coefs = 1 << (4 + (sizeId << 1));
                    if (coefs > 64)
                        coefs = 64;
                    if (sizeId > 1)
                        se(&b);
                    for (int i = 0; i < coefs; i++)
                        se(&b);
                }
            }
    }
    u(&b, 1), u(&b, 1);
    if (u(&b, 1)) { /* pcm_enabled_flag */
        u(&b, 4), u(&b, 4);
        ue(&b), ue(&b);
        u(&b, 1);
    }
    uint32_t sets = ue(&b);
    uint32_t prevDeltas = 0;
    for (uint32_t i = 0; i < sets && !b.overrun; i++) {
        bool predict = i && u(&b, 1);
        uint32_t deltas = 0;
        if (predict) {
            u(&b, 1);
            ue(&b);
            for (uint32_t j = 0; j <= prevDeltas; j++)
                if (!u(&b, 1))
                    u(&b, 1);
                else
                    deltas++;
        } else {
            uint32_t neg = ue(&b), pos = ue(&b);
            for (uint32_t j = 0; j < neg + pos; j++)
                ue(&b), u(&b, 1);
            deltas = neg + pos;
        }
        prevDeltas = deltas;
    }
    if (u(&b, 1)) { /* long_term_ref_pics_present_flag */
        uint32_t n = ue(&b);
        for (uint32_t i = 0; i < n; i++)
            u(&b, (int)log2MaxPocLsb), u(&b, 1);
    }
    u(&b, 1), u(&b, 1);
    if (u(&b, 1)) /* vui_parameters_present_flag */
        vui_common(&b, s);
    free(b.data);
    return s->width > 0 && s->height > 0;
}

/* --- extensions --- */

static void
set_number(CFMutableDictionaryRef d, CFStringRef key, int v)
{
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &v);
    CFDictionarySetValue(d, key, n);
    CFRelease(n);
}

static CFStringRef
chroma_location(uint32_t v)
{
    CFStringRef names[] = {kCVImageBufferChromaLocation_Left,    kCVImageBufferChromaLocation_Center,  kCVImageBufferChromaLocation_TopLeft,
                           kCVImageBufferChromaLocation_Top,     kCVImageBufferChromaLocation_BottomLeft, kCVImageBufferChromaLocation_Bottom};
    return v < 6 ? names[v] : NULL;
}

/* What the parameter set gives the extensions, as Apple's: fields, chroma location,
   aspect ratio and colour, and (for HEVC) bit depth and range. */
static CFMutableDictionaryRef
extensions_for(const SPS *s, bool hevc, CFDictionaryRef given)
{
    CFMutableDictionaryRef ext = given ? CFDictionaryCreateMutableCopy(NULL, 0, given)
                                       : CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    set_number(ext, kCMFormatDescriptionExtension_FieldCount, s->frameMbsOnly ? 1 : 2);
    if (s->chromaFormat == 1) {
        CFStringRef top = s->hasChromaLoc ? chroma_location(s->chromaLocTop) : kCVImageBufferChromaLocation_Left;
        CFStringRef bottom = s->hasChromaLoc ? chroma_location(s->chromaLocBottom) : kCVImageBufferChromaLocation_Left;
        if (top)
            CFDictionarySetValue(ext, kCMFormatDescriptionExtension_ChromaLocationTopField, top);
        if (bottom)
            CFDictionarySetValue(ext, kCMFormatDescriptionExtension_ChromaLocationBottomField, bottom);
    }
    if (s->sarWidth && s->sarHeight && !(s->sarWidth == 1 && s->sarHeight == 1)) {
        CFMutableDictionaryRef par = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        set_number(par, kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing, (int)s->sarWidth);
        set_number(par, kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing, (int)s->sarHeight);
        CFDictionarySetValue(ext, kCMFormatDescriptionExtension_PixelAspectRatio, par);
        CFRelease(par);
    }
    if (s->hasColour) {
        CFStringRef p = CVColorPrimariesGetStringForIntegerCodePoint((int)s->primaries);
        CFStringRef t = CVTransferFunctionGetStringForIntegerCodePoint((int)s->transfer);
        CFStringRef m = CVYCbCrMatrixGetStringForIntegerCodePoint((int)s->matrix);
        if (p)
            CFDictionarySetValue(ext, kCMFormatDescriptionExtension_ColorPrimaries, p);
        if (t)
            CFDictionarySetValue(ext, kCMFormatDescriptionExtension_TransferFunction, t);
        if (m)
            CFDictionarySetValue(ext, kCMFormatDescriptionExtension_YCbCrMatrix, m);
    }
    if (hevc) {
        set_number(ext, kCMFormatDescriptionExtension_BitsPerComponent, (int)s->bitDepthLuma);
        CFDictionarySetValue(ext, kCMFormatDescriptionExtension_FullRangeVideo, s->fullRange ? kCFBooleanTrue : kCFBooleanFalse);
    } else if (s->hasRange && s->fullRange)
        CFDictionarySetValue(ext, kCMFormatDescriptionExtension_FullRangeVideo, kCFBooleanTrue);
    return ext;
}

static void
set_atom(CFMutableDictionaryRef ext, CFStringRef name, const uint8_t *bytes, size_t size)
{
    CFDataRef data = CFDataCreate(NULL, bytes, (CFIndex)size);
    CFDictionaryRef atoms = CFDictionaryCreate(NULL, (const void **)&name, (const void **)&data, 1, &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(ext, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms, atoms);
    CFRelease(atoms);
    CFRelease(data);
}

/* --- H.264 --- */

OSStatus
CMVideoFormatDescriptionCreateFromH264ParameterSets(CFAllocatorRef allocator, size_t parameterSetCount, const uint8_t *const *parameterSetPointers,
                                                    const size_t *parameterSetSizes, int NALUnitHeaderLength,
                                                    CMFormatDescriptionRef *formatDescriptionOut)
{
    if (!formatDescriptionOut || parameterSetCount < 2 || !parameterSetPointers || !parameterSetSizes ||
        (NALUnitHeaderLength != 1 && NALUnitHeaderLength != 2 && NALUnitHeaderLength != 4))
        return kParameterSetError;
    *formatDescriptionOut = NULL;
    /* (sequence sets, then picture sets; the first sequence set describes the stream) */
    size_t sps = 0, pps = 0, total = 0;
    const uint8_t *first = NULL;
    size_t firstSize = 0;
    for (size_t i = 0; i < parameterSetCount; i++) {
        if (!parameterSetPointers[i] || !parameterSetSizes[i])
            return kParameterSetError;
        int type = parameterSetPointers[i][0] & 0x1f;
        if (type == 7) {
            if (!first)
                first = parameterSetPointers[i], firstSize = parameterSetSizes[i];
            sps++;
        } else if (type == 8)
            pps++;
        else
            return kParameterSetError;
        total += 2 + parameterSetSizes[i];
    }
    SPS s;
    if (!sps || !pps || !parse_h264_sps(first, firstSize, &s))
        return kParameterSetError;
    bool high = first[1] == 100 || first[1] == 110 || first[1] == 122 || first[1] == 144;
    uint8_t *rec = malloc(7 + total + (high ? 4 : 0)), *p = rec;
    *p++ = 1;
    *p++ = first[1];
    *p++ = first[2];
    *p++ = first[3];
    *p++ = (uint8_t)(0xfc | (NALUnitHeaderLength - 1));
    *p++ = (uint8_t)(0xe0 | sps);
    for (int pass = 0; pass < 2; pass++) {
        if (pass)
            *p++ = (uint8_t)pps;
        for (size_t i = 0; i < parameterSetCount; i++)
            if ((parameterSetPointers[i][0] & 0x1f) == (pass ? 8 : 7)) {
                *p++ = (uint8_t)(parameterSetSizes[i] >> 8);
                *p++ = (uint8_t)parameterSetSizes[i];
                memcpy(p, parameterSetPointers[i], parameterSetSizes[i]);
                p += parameterSetSizes[i];
            }
    }
    if (high) {
        *p++ = (uint8_t)(0xfc | s.chromaFormat);
        *p++ = (uint8_t)(0xf8 | (s.bitDepthLuma - 8));
        *p++ = (uint8_t)(0xf8 | (s.bitDepthChroma - 8));
        *p++ = 0;
    }
    CFMutableDictionaryRef ext = extensions_for(&s, false, NULL);
    set_atom(ext, CFSTR("avcC"), rec, (size_t)(p - rec));
    free(rec);
    OSStatus e = CMVideoFormatDescriptionCreate(allocator, kCMVideoCodecType_H264, s.width, s.height, ext, formatDescriptionOut);
    CFRelease(ext);
    return e;
}

static CFDataRef
atom_of(CMFormatDescriptionRef desc, CFStringRef name)
{
    CFDictionaryRef atoms = CMFormatDescriptionGetExtension(desc, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms);
    CFTypeRef d = atoms && CFGetTypeID(atoms) == CFDictionaryGetTypeID() ? CFDictionaryGetValue(atoms, name) : NULL;
    return d && CFGetTypeID(d) == CFDataGetTypeID() ? d : NULL;
}

OSStatus
CMVideoFormatDescriptionGetH264ParameterSetAtIndex(CMFormatDescriptionRef videoDesc, size_t parameterSetIndex, const uint8_t **parameterSetPointerOut,
                                                   size_t *parameterSetSizeOut, size_t *parameterSetCountOut, int *NALUnitHeaderLengthOut)
{
    CFDataRef avcC = atom_of(videoDesc, CFSTR("avcC"));
    if (!avcC || CFDataGetLength(avcC) < 7)
        return kCMFormatDescriptionError_InvalidParameter;
    const uint8_t *r = CFDataGetBytePtr(avcC), *end = r + CFDataGetLength(avcC);
    if (NALUnitHeaderLengthOut)
        *NALUnitHeaderLengthOut = (r[4] & 3) + 1;
    /* (the sets in order: sequence sets, then picture sets) */
    const uint8_t *p = r + 5;
    size_t count = 0, found = 0;
    const uint8_t *at = NULL;
    for (int pass = 0; pass < 2 && p < end; pass++) {
        size_t n = pass ? *p++ : (*p++ & 0x1f);
        for (size_t i = 0; i < n && p + 2 <= end; i++) {
            size_t size = (size_t)(p[0] << 8 | p[1]);
            if (count == parameterSetIndex)
                at = p + 2, found = size;
            p += 2 + size;
            count++;
        }
    }
    if (parameterSetCountOut)
        *parameterSetCountOut = count;
    if (!parameterSetPointerOut && !parameterSetSizeOut)
        return noErr;
    if (!at)
        return kParameterSetError;
    if (parameterSetPointerOut)
        *parameterSetPointerOut = at;
    if (parameterSetSizeOut)
        *parameterSetSizeOut = found;
    return noErr;
}

/* --- HEVC --- */

OSStatus
CMVideoFormatDescriptionCreateFromHEVCParameterSets(CFAllocatorRef allocator, size_t parameterSetCount, const uint8_t *const *parameterSetPointers,
                                                    const size_t *parameterSetSizes, int NALUnitHeaderLength, CFDictionaryRef extensions,
                                                    CMFormatDescriptionRef *formatDescriptionOut)
{
    if (!formatDescriptionOut || parameterSetCount < 3 || !parameterSetPointers || !parameterSetSizes ||
        (NALUnitHeaderLength != 1 && NALUnitHeaderLength != 2 && NALUnitHeaderLength != 4))
        return kParameterSetError;
    *formatDescriptionOut = NULL;
    /* (arrays of each NAL type, in the order the types first appear) */
    int types[8];
    size_t typeCount = 0, total = 0;
    const uint8_t *sps = NULL;
    size_t spsSize = 0;
    for (size_t i = 0; i < parameterSetCount; i++) {
        if (!parameterSetPointers[i] || parameterSetSizes[i] < 2)
            return kParameterSetError;
        int type = (parameterSetPointers[i][0] >> 1) & 0x3f;
        if (type == 33 && !sps)
            sps = parameterSetPointers[i], spsSize = parameterSetSizes[i];
        size_t k = 0;
        while (k < typeCount && types[k] != type)
            k++;
        if (k == typeCount) {
            if (typeCount == 8)
                return kParameterSetError;
            types[typeCount++] = type;
        }
        total += 2 + parameterSetSizes[i];
    }
    SPS s;
    if (!sps)
        return kCMFormatDescriptionError_InvalidParameter;
    if (!parse_hevc_sps(sps, spsSize, &s))
        return kParameterSetError;
    uint8_t *rec = malloc(23 + 3 * typeCount + total), *p = rec;
    *p++ = 1;
    memcpy(p, s.ptl, 12);
    p += 12;
    *p++ = 0xf0; /* min_spatial_segmentation_idc 0 */
    *p++ = 0x00;
    *p++ = 0xfc; /* parallelismType 0 */
    *p++ = (uint8_t)(0xfc | s.chromaFormat);
    *p++ = (uint8_t)(0xf8 | (s.bitDepthLuma - 8));
    *p++ = (uint8_t)(0xf8 | (s.bitDepthChroma - 8));
    *p++ = 0; /* avgFrameRate */
    *p++ = 0;
    *p++ = (uint8_t)(((s.maxSubLayers & 7) << 3) | (s.temporalIdNesting << 2) | (NALUnitHeaderLength - 1));
    *p++ = (uint8_t)typeCount;
    for (size_t k = 0; k < typeCount; k++) {
        size_t n = 0;
        for (size_t i = 0; i < parameterSetCount; i++)
            n += ((parameterSetPointers[i][0] >> 1) & 0x3f) == types[k];
        *p++ = (uint8_t)(0x80 | types[k]); /* (array_completeness set) */
        *p++ = (uint8_t)(n >> 8);
        *p++ = (uint8_t)n;
        for (size_t i = 0; i < parameterSetCount; i++)
            if (((parameterSetPointers[i][0] >> 1) & 0x3f) == types[k]) {
                *p++ = (uint8_t)(parameterSetSizes[i] >> 8);
                *p++ = (uint8_t)parameterSetSizes[i];
                memcpy(p, parameterSetPointers[i], parameterSetSizes[i]);
                p += parameterSetSizes[i];
            }
    }
    CFMutableDictionaryRef ext = extensions_for(&s, true, extensions);
    set_atom(ext, CFSTR("hvcC"), rec, (size_t)(p - rec));
    free(rec);
    OSStatus e = CMVideoFormatDescriptionCreate(allocator, kCMVideoCodecType_HEVC, s.width, s.height, ext, formatDescriptionOut);
    CFRelease(ext);
    return e;
}

OSStatus
CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(CMFormatDescriptionRef videoDesc, size_t parameterSetIndex, const uint8_t **parameterSetPointerOut,
                                                   size_t *parameterSetSizeOut, size_t *parameterSetCountOut, int *NALUnitHeaderLengthOut)
{
    CFDataRef hvcC = atom_of(videoDesc, CFSTR("hvcC"));
    if (!hvcC || CFDataGetLength(hvcC) < 23)
        return kCMFormatDescriptionError_InvalidParameter;
    const uint8_t *r = CFDataGetBytePtr(hvcC), *end = r + CFDataGetLength(hvcC);
    if (NALUnitHeaderLengthOut)
        *NALUnitHeaderLengthOut = (r[21] & 3) + 1;
    const uint8_t *p = r + 23, *at = NULL;
    size_t count = 0, found = 0;
    for (size_t a = 0, arrays = r[22]; a < arrays && p + 3 <= end; a++) {
        size_t n = (size_t)(p[1] << 8 | p[2]);
        p += 3;
        for (size_t i = 0; i < n && p + 2 <= end; i++) {
            size_t size = (size_t)(p[0] << 8 | p[1]);
            if (count == parameterSetIndex)
                at = p + 2, found = size;
            p += 2 + size;
            count++;
        }
    }
    if (parameterSetCountOut)
        *parameterSetCountOut = count;
    if (!parameterSetPointerOut && !parameterSetSizeOut)
        return noErr;
    if (!at)
        return kParameterSetError;
    if (parameterSetPointerOut)
        *parameterSetPointerOut = at;
    if (parameterSetSizeOut)
        *parameterSetSizeOut = found;
    return noErr;
}
