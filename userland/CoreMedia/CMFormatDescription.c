/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CoreMedia's format descriptions, Finch's: one CF type for every media type, as
 * Apple's is, with what's particular to video (codec and dimensions), audio (stream
 * description, magic cookie, channel layout and format list), muxed streams and time
 * codes; extensions are a copied dictionary. Descriptions print as Apple's do, naming
 * the class after the media type.
 */
#include "CMInternal.h"
#include <CoreAudioTypes/CoreAudioTypes.h>
#include <CoreVideo/CoreVideo.h>
#include <stdatomic.h>
#include <string.h>

const CMVideoDimensions kCMVideoDimensionsZero = {0, 0};

enum { KIND_OTHER, KIND_VIDEO, KIND_AUDIO, KIND_MUXED, KIND_TIMECODE, KIND_TEXT, KIND_METADATA };

struct opaqueCMFormatDescription {
    CFRuntimeBase base;
    CMMediaType mediaType;
    FourCharCode subType;
    CFDictionaryRef extensions;
    int kind;
    bool specific; /* (made by the media type's own create, not CMFormatDescriptionCreate) */
    struct {
        CMVideoCodecType codec;
        int32_t width, height;
    } video;
    struct {
        AudioStreamBasicDescription asbd;
        CFDataRef cookie;
        AudioChannelLayout *layout;
        size_t layoutSize;
        AudioFormatListItem *list;
        size_t listSize;
    } audio;
    CMMuxedStreamType mux;
    _Atomic(CFArrayRef) cached; /* (an array made from the description once, such as metadata identifiers) */
    struct {
        CMTime frameDuration;
        uint32_t quanta, flags;
    } timecode;
};

static int
kind_of(CMMediaType type)
{
    switch (type) {
    case kCMMediaType_Video: return KIND_VIDEO;
    case kCMMediaType_Audio: return KIND_AUDIO;
    case kCMMediaType_Muxed: return KIND_MUXED;
    case kCMMediaType_TimeCode: return KIND_TIMECODE;
    case kCMMediaType_Text:
    case kCMMediaType_Subtitle:
    case kCMMediaType_ClosedCaption: return KIND_TEXT;
    case kCMMediaType_Metadata: return KIND_METADATA;
    default: return KIND_OTHER;
    }
}

static const char *
class_name(CMMediaType type)
{
    switch (type) {
    case kCMMediaType_Video: return "CMVideoFormatDescription";
    case kCMMediaType_Audio: return "CMAudioFormatDescription";
    case kCMMediaType_Muxed: return "CMMuxedFormatDescription";
    case kCMMediaType_Text: return "CMTextFormatDescription";
    case kCMMediaType_Subtitle: return "CMSubtitleFormatDescription";
    case kCMMediaType_ClosedCaption: return "CMClosedCaptionFormatDescription";
    case kCMMediaType_Metadata: return "CMMetadataFormatDescription";
    default: return "CMFormatDescription";
    }
}

static void
finalize(CFTypeRef cf)
{
    CMFormatDescriptionRef d = (CMFormatDescriptionRef)cf;
    if (d->extensions)
        CFRelease(d->extensions);
    if (d->audio.cookie)
        CFRelease(d->audio.cookie);
    free(d->audio.layout);
    free(d->audio.list);
    if (d->cached)
        CFRelease(d->cached);
}

CFArrayRef
_FinchCMFormatDescriptionCachedArray(CMFormatDescriptionRef desc, CFArrayRef (*make)(CMFormatDescriptionRef))
{
    struct opaqueCMFormatDescription *d = (struct opaqueCMFormatDescription *)desc;
    CFArrayRef a = d->cached;
    if (a)
        return a;
    CFArrayRef made = make(desc);
    if (!made)
        return NULL;
    CFArrayRef expected = NULL;
    if (!atomic_compare_exchange_strong(&d->cached, &expected, made)) {
        CFRelease(made);
        return expected;
    }
    return made;
}

static bool
equal_specific(CMFormatDescriptionRef a, CMFormatDescriptionRef b)
{
    if (a->mediaType != b->mediaType || a->subType != b->subType || a->kind != b->kind)
        return false;
    switch (a->kind) {
    case KIND_VIDEO:
        return a->video.codec == b->video.codec && a->video.width == b->video.width && a->video.height == b->video.height;
    case KIND_AUDIO:
        return !memcmp(&a->audio.asbd, &b->audio.asbd, sizeof a->audio.asbd) &&
               (a->audio.cookie == b->audio.cookie || (a->audio.cookie && b->audio.cookie && CFEqual(a->audio.cookie, b->audio.cookie))) &&
               a->audio.layoutSize == b->audio.layoutSize && (!a->audio.layoutSize || !memcmp(a->audio.layout, b->audio.layout, a->audio.layoutSize));
    case KIND_MUXED:
        return a->mux == b->mux;
    case KIND_TIMECODE:
        return !CMTimeCompare(a->timecode.frameDuration, b->timecode.frameDuration) && a->timecode.quanta == b->timecode.quanta &&
               a->timecode.flags == b->timecode.flags;
    }
    return true;
}

static Boolean
equal(CFTypeRef x, CFTypeRef y)
{
    CMFormatDescriptionRef a = (CMFormatDescriptionRef)x, b = (CMFormatDescriptionRef)y;
    if (!equal_specific(a, b))
        return false;
    if (!a->extensions || !b->extensions)
        return a->extensions == b->extensions;
    return CFEqual(a->extensions, b->extensions);
}

/* A four-character code as Apple's descriptions print it. */
static void
append_code(CFMutableStringRef s, FourCharCode c)
{
    char b[5] = {(char)(c >> 24), (char)(c >> 16), (char)(c >> 8), (char)c, 0};
    int start = 0;
    while (start < 4 && !b[start])
        start++;
    CFStringAppendFormat(s, NULL, CFSTR("'%s'"), b + start);
}

static void
append_asbd(CFMutableStringRef s, const AudioStreamBasicDescription *a)
{
    CFStringAppendFormat(s, NULL, CFSTR("ASBD: {\n\t\t\tmSampleRate: %f \n\t\t\tmFormatID: "), a->mSampleRate);
    append_code(s, a->mFormatID);
    CFStringAppendFormat(s, NULL,
                         CFSTR(" \n\t\t\tmFormatFlags: 0x%x \n\t\t\tmBytesPerPacket: %u \n\t\t\tmFramesPerPacket: %u \n\t\t\tmBytesPerFrame: %u "
                               "\n\t\t\tmChannelsPerFrame: %u \n\t\t\tmBitsPerChannel: %u \t}"),
                         (unsigned)a->mFormatFlags, (unsigned)a->mBytesPerPacket, (unsigned)a->mFramesPerPacket, (unsigned)a->mBytesPerFrame,
                         (unsigned)a->mChannelsPerFrame, (unsigned)a->mBitsPerChannel);
}

/* --- channel layouts --- */

static const struct {
    AudioChannelLayoutTag tag;
    const char *name;
    uint32_t bitmap;
} layouts[] = {
    {kAudioChannelLayoutTag_Mono, "Mono (C)", kAudioChannelBit_Center},
    {kAudioChannelLayoutTag_Stereo, "Stereo (L R)", kAudioChannelBit_Left | kAudioChannelBit_Right},
    {kAudioChannelLayoutTag_StereoHeadphones, "Stereo Headphones (L R)", 0},
    {kAudioChannelLayoutTag_Quadraphonic, "Quadraphonic (L R Ls Rs)", 0},
    {kAudioChannelLayoutTag_MPEG_3_0_A, "3.0 (L R C)", kAudioChannelBit_Left | kAudioChannelBit_Right | kAudioChannelBit_Center},
    {kAudioChannelLayoutTag_MPEG_4_0_A, "4.0 (L R C Cs)", 0},
    {kAudioChannelLayoutTag_MPEG_5_0_A, "5.0 (L R C Ls Rs)", 0},
    {kAudioChannelLayoutTag_MPEG_5_1_A, "5.1 (L R C LFE Ls Rs)",
     kAudioChannelBit_Left | kAudioChannelBit_Right | kAudioChannelBit_Center | kAudioChannelBit_LFEScreen | kAudioChannelBit_LeftSurround |
         kAudioChannelBit_RightSurround},
    {kAudioChannelLayoutTag_MPEG_6_1_A, "6.1 (L R C LFE Ls Rs Cs)", 0},
    {kAudioChannelLayoutTag_MPEG_7_1_A, "7.1 (L R C LFE Ls Rs Lc Rc)", 0},
    {kAudioChannelLayoutTag_MPEG_7_1_C, "7.1 (L R C LFE Ls Rs Rls Rrs)", 0},
};

/* The tag a layout comes to: its own, or the one its bitmap or descriptions name. */
static AudioChannelLayoutTag
layout_tag(const AudioChannelLayout *l)
{
    if (l->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelBitmap) {
        for (size_t i = 0; i < sizeof layouts / sizeof layouts[0]; i++)
            if (layouts[i].bitmap && layouts[i].bitmap == l->mChannelBitmap)
                return layouts[i].tag;
        return l->mChannelLayoutTag;
    }
    if (l->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions) {
        static const AudioChannelLabel order[][6] = {
            {kAudioChannelLabel_Center},
            {kAudioChannelLabel_Left, kAudioChannelLabel_Right},
        };
        for (size_t k = 0; k < 2; k++)
            if (l->mNumberChannelDescriptions == k + 1) {
                bool same = true;
                for (UInt32 i = 0; i <= k; i++)
                    same &= l->mChannelDescriptions[i].mChannelLabel == order[k][i];
                if (same)
                    return k ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_Mono;
            }
        return l->mChannelLayoutTag;
    }
    return l->mChannelLayoutTag;
}

static const char *
layout_name(AudioChannelLayoutTag tag)
{
    for (size_t i = 0; i < sizeof layouts / sizeof layouts[0]; i++)
        if (layouts[i].tag == tag)
            return layouts[i].name;
    return NULL;
}

static CFStringRef
copy_description(CFTypeRef cf)
{
    CMFormatDescriptionRef d = (CMFormatDescriptionRef)cf;
    CFMutableStringRef s = CFStringCreateMutable(NULL, 0);
    CFStringAppendFormat(s, NULL, CFSTR("<%s %p [%p]> {\n\tmediaType:"), class_name(d->mediaType), cf, CFGetAllocator(cf));
    append_code(s, d->mediaType);
    CFStringAppend(s, CFSTR(" \n\tmediaSubType:"));
    append_code(s, d->subType);
    CFStringAppend(s, CFSTR(" \n\tmediaSpecific: {\n"));
    switch (d->kind) {
    case KIND_VIDEO:
        CFStringAppend(s, CFSTR("\t\tcodecType: "));
        if (d->video.codec)
            append_code(s, d->video.codec);
        else
            CFStringAppend(s, CFSTR("0"));
        CFStringAppendFormat(s, NULL, CFSTR("\t\tdimensions: %d x %d \n"), (int)d->video.width, (int)d->video.height);
        break;
    case KIND_AUDIO:
        CFStringAppend(s, CFSTR("\t\t"));
        append_asbd(s, &d->audio.asbd);
        CFStringAppend(s, CFSTR(" \n\t\tcookie: {"));
        if (d->audio.cookie) {
            CFStringRef c = CFCopyDescription(d->audio.cookie);
            CFStringAppend(s, c);
            CFRelease(c);
        } else
            CFStringAppend(s, CFSTR("(null)"));
        CFStringAppend(s, CFSTR("} \n\t\tACL: {"));
        const char *name = d->audio.layout ? layout_name(layout_tag(d->audio.layout)) : NULL;
        if (name)
            CFStringAppendCString(s, name, kCFStringEncodingUTF8);
        else if (d->audio.layout)
            CFStringAppendFormat(s, NULL, CFSTR("tag 0x%x"), (unsigned)d->audio.layout->mChannelLayoutTag);
        else
            CFStringAppend(s, CFSTR("(null)"));
        CFStringAppend(s, CFSTR("}\n\t\tFormatList Array: {"));
        if (d->audio.list) {
            for (size_t i = 0; i < d->audio.listSize / sizeof(AudioFormatListItem); i++) {
                CFStringAppendFormat(s, NULL, CFSTR("\n\t\t\tIndex: %zu \n\t\t\tChannelLayoutTag: 0x%x \n\t\t\t"), i,
                                     (unsigned)d->audio.list[i].mChannelLayoutTag);
                append_asbd(s, &d->audio.list[i].mASBD);
            }
            CFStringAppend(s, CFSTR("} \n"));
        } else
            CFStringAppend(s, CFSTR("(null)} \n"));
        break;
    case KIND_MUXED:
        CFStringAppend(s, CFSTR("\t\tmuxType: "));
        append_code(s, d->mux);
        CFStringAppend(s, CFSTR(" \n"));
        break;
    case KIND_TIMECODE: {
        CFStringRef t = CMTimeCopyDescription(NULL, d->timecode.frameDuration);
        CFStringAppendFormat(s, NULL, CFSTR("\t\tframeDuration: %@\t\tframes/sec: %u\t\ttcFlags: %u \n"), t, (unsigned)d->timecode.quanta,
                             (unsigned)d->timecode.flags);
        CFRelease(t);
        break;
    }
    case KIND_METADATA: {
        CFTypeRef table = d->extensions ? CFDictionaryGetValue(d->extensions, CFSTR("MetadataKeyTable")) : NULL;
        if (table)
            CFStringAppendFormat(s, NULL,
                                 CFSTR("\t\tidentifierToDataTypes %p\t\tlocalKeyIDToKeyEntryMapping %p\t\tlocalKeyIDToMetadataSpecificationMapping %p"
                                       "\t\tlocalKeyIDToConformingDataTypes %p\t\tlocalKeyIDToQuickTimeWellKnownTypeMapping %p \n"),
                                 table, table, table, table, table);
        else
            CFStringAppend(s, CFSTR(" \n"));
        break;
    }
    default:
        CFStringAppend(s, CFSTR("(null) \n"));
    }
    CFStringAppend(s, CFSTR("\t} \n\textensions: {"));
    if (d->extensions) {
        CFStringRef e = CFCopyDescription(d->extensions);
        CFStringAppend(s, e);
        CFRelease(e);
    } else
        CFStringAppend(s, CFSTR("(null)"));
    CFStringAppend(s, CFSTR("}\n}"));
    return s;
}

CM_DEFINE_TYPE(CMFormatDescriptionGetTypeID, "CMFormatDescription", finalize, equal, NULL, copy_description)

typedef struct opaqueCMFormatDescription *MutableDescription;

static MutableDescription
create(CFAllocatorRef allocator, CMMediaType mediaType, FourCharCode subType, CFDictionaryRef extensions)
{
    MutableDescription d = (MutableDescription)cm_create(allocator, CMFormatDescriptionGetTypeID(), sizeof(struct opaqueCMFormatDescription));
    if (!d)
        return NULL;
    d->mediaType = mediaType;
    d->subType = subType;
    d->kind = kind_of(mediaType);
    d->timecode.frameDuration = kCMTimeInvalid;
    if (extensions && CFDictionaryGetCount(extensions))
        d->extensions = CFDictionaryCreateCopy(allocator, extensions);
    return d;
}

OSStatus
CMFormatDescriptionCreate(CFAllocatorRef allocator, CMMediaType mediaType, FourCharCode mediaSubType, CFDictionaryRef extensions,
                          CMFormatDescriptionRef *formatDescriptionOut)
{
    if (!formatDescriptionOut || !mediaType)
        return kCMFormatDescriptionError_InvalidParameter;
    *formatDescriptionOut = create(allocator, mediaType, mediaSubType, extensions);
    return *formatDescriptionOut ? noErr : kCMFormatDescriptionError_AllocationFailed;
}

CMMediaType
CMFormatDescriptionGetMediaType(CMFormatDescriptionRef desc)
{
    return desc ? desc->mediaType : 0;
}

FourCharCode
CMFormatDescriptionGetMediaSubType(CMFormatDescriptionRef desc)
{
    return desc ? desc->subType : 0;
}

CFDictionaryRef
CMFormatDescriptionGetExtensions(CMFormatDescriptionRef desc)
{
    return desc ? desc->extensions : NULL;
}

CFPropertyListRef
CMFormatDescriptionGetExtension(CMFormatDescriptionRef desc, CFStringRef extensionKey)
{
    return desc && desc->extensions && extensionKey ? CFDictionaryGetValue(desc->extensions, extensionKey) : NULL;
}

Boolean
CMFormatDescriptionEqual(CMFormatDescriptionRef formatDescription, CMFormatDescriptionRef otherFormatDescription)
{
    if (formatDescription == otherFormatDescription)
        return true;
    if (!formatDescription || !otherFormatDescription)
        return false;
    return CFEqual(formatDescription, otherFormatDescription);
}

/* The extensions without the keys to ignore (a string or an array of them). */
static CFDictionaryRef
copy_without(CFDictionaryRef ext, CFTypeRef ignore)
{
    if (!ext)
        return NULL;
    CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(NULL, 0, ext);
    if (ignore && CFGetTypeID(ignore) == CFStringGetTypeID())
        CFDictionaryRemoveValue(m, ignore);
    else if (ignore && CFGetTypeID(ignore) == CFArrayGetTypeID())
        for (CFIndex i = 0; i < CFArrayGetCount(ignore); i++)
            CFDictionaryRemoveValue(m, CFArrayGetValueAtIndex(ignore, i));
    return m;
}

Boolean
CMFormatDescriptionEqualIgnoringExtensionKeys(CMFormatDescriptionRef formatDescription, CMFormatDescriptionRef otherFormatDescription,
                                              CFTypeRef formatDescriptionExtensionKeysToIgnore, CFTypeRef sampleDescriptionExtensionAtomKeysToIgnore)
{
    if (!formatDescription || !otherFormatDescription)
        return formatDescription == otherFormatDescription;
    if (!equal_specific(formatDescription, otherFormatDescription))
        return false;
    CFDictionaryRef a = copy_without(formatDescription->extensions, formatDescriptionExtensionKeysToIgnore);
    CFDictionaryRef b = copy_without(otherFormatDescription->extensions, formatDescriptionExtensionKeysToIgnore);
    /* (and the sample description atoms named) */
    if (sampleDescriptionExtensionAtomKeysToIgnore) {
        CFDictionaryRef *both[] = {&a, &b};
        for (int i = 0; i < 2; i++) {
            CFDictionaryRef atoms = *both[i] ? CFDictionaryGetValue(*both[i], kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) : NULL;
            if (atoms && CFGetTypeID(atoms) == CFDictionaryGetTypeID()) {
                CFDictionaryRef trimmed = copy_without(atoms, sampleDescriptionExtensionAtomKeysToIgnore);
                CFDictionarySetValue((CFMutableDictionaryRef)*both[i], kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms, trimmed);
                CFRelease(trimmed);
            }
        }
    }
    bool same;
    if (!a || !b)
        same = (!a || !CFDictionaryGetCount(a)) && (!b || !CFDictionaryGetCount(b));
    else
        same = CFEqual(a, b);
    if (a)
        CFRelease(a);
    if (b)
        CFRelease(b);
    return same;
}

/* --- video --- */

OSStatus
CMVideoFormatDescriptionCreate(CFAllocatorRef allocator, CMVideoCodecType codecType, int32_t width, int32_t height, CFDictionaryRef extensions,
                               CMVideoFormatDescriptionRef *formatDescriptionOut)
{
    if (!formatDescriptionOut)
        return kCMFormatDescriptionError_InvalidParameter;
    MutableDescription d = create(allocator, kCMMediaType_Video, codecType, extensions);
    if (!d)
        return kCMFormatDescriptionError_AllocationFailed;
    d->specific = true;
    d->video.codec = codecType;
    d->video.width = width;
    d->video.height = height;
    *formatDescriptionOut = d;
    return noErr;
}

CMVideoDimensions
CMVideoFormatDescriptionGetDimensions(CMVideoFormatDescriptionRef videoDesc)
{
    CMVideoDimensions dims = {0, 0};
    if (videoDesc && videoDesc->kind == KIND_VIDEO)
        dims = (CMVideoDimensions){videoDesc->video.width, videoDesc->video.height};
    return dims;
}

static bool
number(CFDictionaryRef d, CFStringRef key, double *out)
{
    CFTypeRef v = d ? CFDictionaryGetValue(d, key) : NULL;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID())
        return CFNumberGetValue(v, kCFNumberDoubleType, out);
    /* (or a rational: an array of numerator and denominator) */
    if (v && CFGetTypeID(v) == CFArrayGetTypeID() && CFArrayGetCount(v) == 2) {
        double n, dn;
        if (CFNumberGetValue(CFArrayGetValueAtIndex(v, 0), kCFNumberDoubleType, &n) &&
            CFNumberGetValue(CFArrayGetValueAtIndex(v, 1), kCFNumberDoubleType, &dn) && dn) {
            *out = n / dn;
            return true;
        }
    }
    return false;
}

CGRect
CMVideoFormatDescriptionGetCleanAperture(CMVideoFormatDescriptionRef videoDesc, Boolean originIsAtTopLeft)
{
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(videoDesc);
    CGRect r = CGRectMake(0, 0, dims.width, dims.height);
    CFDictionaryRef ca = (CFDictionaryRef)CMFormatDescriptionGetExtension(videoDesc, kCMFormatDescriptionExtension_CleanAperture);
    double w, h, x = 0, y = 0;
    if (!ca || CFGetTypeID(ca) != CFDictionaryGetTypeID() || !number(ca, kCMFormatDescriptionKey_CleanApertureWidth, &w) ||
        !number(ca, kCMFormatDescriptionKey_CleanApertureHeight, &h))
        return r;
    number(ca, kCMFormatDescriptionKey_CleanApertureHorizontalOffset, &x);
    number(ca, kCMFormatDescriptionKey_CleanApertureVerticalOffset, &y);
    double top = (dims.height - h) / 2;
    return CGRectMake((dims.width - w) / 2 + x, originIsAtTopLeft ? top + y : top - y, w, h);
}

CGSize
CMVideoFormatDescriptionGetPresentationDimensions(CMVideoFormatDescriptionRef videoDesc, Boolean usePixelAspectRatio, Boolean useCleanAperture)
{
    CGRect r = useCleanAperture ? CMVideoFormatDescriptionGetCleanAperture(videoDesc, true) : CGRectMake(0, 0, CMVideoFormatDescriptionGetDimensions(videoDesc).width, CMVideoFormatDescriptionGetDimensions(videoDesc).height);
    CGSize s = r.size;
    CFDictionaryRef par = (CFDictionaryRef)CMFormatDescriptionGetExtension(videoDesc, kCMFormatDescriptionExtension_PixelAspectRatio);
    double hs, vs;
    if (usePixelAspectRatio && par && CFGetTypeID(par) == CFDictionaryGetTypeID() &&
        number(par, kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing, &hs) &&
        number(par, kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing, &vs) && hs > 0 && vs > 0)
        s.width = s.width * hs / vs;
    return s;
}

static CFArrayRef common_keys;

static void
make_common_keys(void)
{
    const void *k[] = {
        kCMFormatDescriptionExtension_CleanAperture,
        kCMFormatDescriptionExtension_FieldCount,
        kCMFormatDescriptionExtension_FieldDetail,
        kCMFormatDescriptionExtension_PixelAspectRatio,
        kCMFormatDescriptionExtension_ColorPrimaries,
        kCMFormatDescriptionExtension_TransferFunction,
        kCMFormatDescriptionExtension_GammaLevel,
        kCMFormatDescriptionExtension_YCbCrMatrix,
        kCMFormatDescriptionExtension_ICCProfile,
        kCMFormatDescriptionExtension_ChromaLocationTopField,
        kCMFormatDescriptionExtension_ChromaLocationBottomField,
        kCMFormatDescriptionExtension_MasteringDisplayColorVolume,
        kCMFormatDescriptionExtension_ContentLightLevelInfo,
        kCMFormatDescriptionExtension_ContentColorVolume,
        kCMFormatDescriptionExtension_AmbientViewingEnvironment,
        kCMFormatDescriptionExtension_LogTransferFunction,
    };
    common_keys = CFArrayCreate(NULL, k, sizeof k / sizeof k[0], &kCFTypeArrayCallBacks);
}

CFArrayRef
CMVideoFormatDescriptionGetExtensionKeysCommonWithImageBuffers(void)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, make_common_keys);
    return common_keys;
}

/* The extensions an image buffer gives a format description: its row bytes, the
   version, and those of its attachments that format descriptions share. */
static CFDictionaryRef
copy_image_extensions(CVImageBufferRef imageBuffer)
{
    CFMutableDictionaryRef ext = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFArrayRef keys = CMVideoFormatDescriptionGetExtensionKeysCommonWithImageBuffers();
    for (CFIndex i = 0; i < CFArrayGetCount(keys); i++) {
        CFTypeRef v = CVBufferCopyAttachment(imageBuffer, CFArrayGetValueAtIndex(keys, i), NULL);
        if (v) {
            CFDictionarySetValue(ext, CFArrayGetValueAtIndex(keys, i), v);
            CFRelease(v);
        }
    }
    long long rowBytes = CVPixelBufferIsPlanar(imageBuffer) ? (long long)CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0)
                                                            : (long long)CVPixelBufferGetBytesPerRow(imageBuffer);
    int version = 2;
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberLongLongType, &rowBytes), v = CFNumberCreate(NULL, kCFNumberIntType, &version);
    CFDictionarySetValue(ext, kCMFormatDescriptionExtension_BytesPerRow, n);
    CFDictionarySetValue(ext, kCMFormatDescriptionExtension_Version, v);
    CFRelease(n);
    CFRelease(v);
    return ext;
}

OSStatus
CMVideoFormatDescriptionCreateForImageBuffer(CFAllocatorRef allocator, CVImageBufferRef imageBuffer, CMVideoFormatDescriptionRef *formatDescriptionOut)
{
    if (!formatDescriptionOut || !imageBuffer || CFGetTypeID(imageBuffer) != CVPixelBufferGetTypeID())
        return kCMFormatDescriptionError_InvalidParameter;
    CFDictionaryRef ext = copy_image_extensions(imageBuffer);
    OSStatus e = CMVideoFormatDescriptionCreate(allocator, CVPixelBufferGetPixelFormatType(imageBuffer), (int32_t)CVPixelBufferGetWidth(imageBuffer),
                                                (int32_t)CVPixelBufferGetHeight(imageBuffer), ext, formatDescriptionOut);
    CFRelease(ext);
    return e;
}

Boolean
CMVideoFormatDescriptionMatchesImageBuffer(CMVideoFormatDescriptionRef desc, CVImageBufferRef imageBuffer)
{
    if (!desc || desc->kind != KIND_VIDEO || !imageBuffer || CFGetTypeID(imageBuffer) != CVPixelBufferGetTypeID())
        return false;
    if (desc->video.codec != CVPixelBufferGetPixelFormatType(imageBuffer) || desc->video.width != (int32_t)CVPixelBufferGetWidth(imageBuffer) ||
        desc->video.height != (int32_t)CVPixelBufferGetHeight(imageBuffer))
        return false;
    /* (and the extensions they share agree) */
    CFArrayRef keys = CMVideoFormatDescriptionGetExtensionKeysCommonWithImageBuffers();
    for (CFIndex i = 0; i < CFArrayGetCount(keys); i++) {
        CFStringRef k = CFArrayGetValueAtIndex(keys, i);
        CFTypeRef a = CMFormatDescriptionGetExtension(desc, k), b = CVBufferCopyAttachment(imageBuffer, k, NULL);
        bool same = a == b || (a && b && CFEqual(a, b));
        if (b)
            CFRelease(b);
        if (!same)
            return false;
    }
    return true;
}

/* --- audio --- */

OSStatus
CMAudioFormatDescriptionCreate(CFAllocatorRef allocator, const AudioStreamBasicDescription *asbd, size_t layoutSize, const AudioChannelLayout *layout,
                               size_t magicCookieSize, const void *magicCookie, CFDictionaryRef extensions,
                               CMAudioFormatDescriptionRef *formatDescriptionOut)
{
    if (!formatDescriptionOut || !asbd || (layoutSize && !layout) || (layout && layoutSize < offsetof(AudioChannelLayout, mChannelDescriptions)))
        return kCMFormatDescriptionError_InvalidParameter;
    MutableDescription d = create(allocator, kCMMediaType_Audio, asbd->mFormatID, extensions);
    if (!d)
        return kCMFormatDescriptionError_AllocationFailed;
    d->specific = true;
    d->audio.asbd = *asbd;
    if (magicCookie && magicCookieSize)
        d->audio.cookie = CFDataCreate(allocator, magicCookie, (CFIndex)magicCookieSize);
    AudioChannelLayoutTag tag;
    if (layout) {
        d->audio.layout = malloc(layoutSize);
        memcpy(d->audio.layout, layout, layoutSize);
        d->audio.layoutSize = layoutSize;
        tag = layout_tag(layout);
    } else
        tag = asbd->mChannelsPerFrame == 1 ? kAudioChannelLayoutTag_Mono
              : asbd->mChannelsPerFrame == 2 ? kAudioChannelLayoutTag_Stereo
                                             : kAudioChannelLayoutTag_Unknown;
    d->audio.list = calloc(1, sizeof(AudioFormatListItem));
    d->audio.list->mASBD = *asbd;
    d->audio.list->mChannelLayoutTag = tag;
    d->audio.listSize = sizeof(AudioFormatListItem);
    *formatDescriptionOut = d;
    return noErr;
}

const AudioStreamBasicDescription *
CMAudioFormatDescriptionGetStreamBasicDescription(CMAudioFormatDescriptionRef desc)
{
    return desc && desc->kind == KIND_AUDIO ? &desc->audio.asbd : NULL;
}

const void *
CMAudioFormatDescriptionGetMagicCookie(CMAudioFormatDescriptionRef desc, size_t *sizeOut)
{
    CFDataRef c = desc && desc->kind == KIND_AUDIO ? desc->audio.cookie : NULL;
    if (sizeOut)
        *sizeOut = c ? (size_t)CFDataGetLength(c) : 0;
    return c ? CFDataGetBytePtr(c) : NULL;
}

const AudioChannelLayout *
CMAudioFormatDescriptionGetChannelLayout(CMAudioFormatDescriptionRef desc, size_t *sizeOut)
{
    bool audio = desc && desc->kind == KIND_AUDIO;
    if (sizeOut)
        *sizeOut = audio ? desc->audio.layoutSize : 0;
    return audio ? desc->audio.layout : NULL;
}

const AudioFormatListItem *
CMAudioFormatDescriptionGetFormatList(CMAudioFormatDescriptionRef desc, size_t *sizeOut)
{
    bool audio = desc && desc->kind == KIND_AUDIO;
    if (sizeOut)
        *sizeOut = audio ? desc->audio.listSize : 0;
    return audio ? desc->audio.list : NULL;
}

const AudioFormatListItem *
CMAudioFormatDescriptionGetRichestDecodableFormat(CMAudioFormatDescriptionRef desc)
{
    return CMAudioFormatDescriptionGetFormatList(desc, NULL);
}

const AudioFormatListItem *
CMAudioFormatDescriptionGetMostCompatibleFormat(CMAudioFormatDescriptionRef desc)
{
    size_t size = 0;
    const AudioFormatListItem *list = CMAudioFormatDescriptionGetFormatList(desc, &size);
    return list && size >= sizeof *list ? &list[size / sizeof *list - 1] : NULL;
}

Boolean
CMAudioFormatDescriptionEqual(CMAudioFormatDescriptionRef formatDescription, CMAudioFormatDescriptionRef otherFormatDescription,
                              CMAudioFormatDescriptionMask equalityMask, CMAudioFormatDescriptionMask *equalityMaskOut)
{
    CMAudioFormatDescriptionMask same = 0;
    if (formatDescription && otherFormatDescription && formatDescription->kind == KIND_AUDIO && otherFormatDescription->kind == KIND_AUDIO) {
        const AudioStreamBasicDescription *a = &formatDescription->audio.asbd, *b = &otherFormatDescription->audio.asbd;
        /* (fields of 0 are wildcards, as in Core Audio) */
#define FIELD(f) (!a->f || !b->f || a->f == b->f)
        if (FIELD(mSampleRate) && FIELD(mFormatID) && FIELD(mFormatFlags) && FIELD(mBytesPerPacket) && FIELD(mFramesPerPacket) &&
            FIELD(mBytesPerFrame) && FIELD(mChannelsPerFrame) && FIELD(mBitsPerChannel))
            same |= kCMAudioFormatDescriptionMask_StreamBasicDescription;
#undef FIELD
        CFDataRef c1 = formatDescription->audio.cookie, c2 = otherFormatDescription->audio.cookie;
        if (c1 == c2 || (c1 && c2 && CFEqual(c1, c2)))
            same |= kCMAudioFormatDescriptionMask_MagicCookie;
        const AudioChannelLayout *l1 = formatDescription->audio.layout, *l2 = otherFormatDescription->audio.layout;
        if ((!l1 && !l2) || (l1 && l2 && layout_tag(l1) == layout_tag(l2) &&
                             (layout_tag(l1) != kAudioChannelLayoutTag_UseChannelDescriptions ||
                              (formatDescription->audio.layoutSize == otherFormatDescription->audio.layoutSize &&
                               !memcmp(l1, l2, formatDescription->audio.layoutSize)))))
            same |= kCMAudioFormatDescriptionMask_ChannelLayout;
        CFDictionaryRef e1 = formatDescription->extensions, e2 = otherFormatDescription->extensions;
        if (e1 == e2 || (e1 && e2 && CFEqual(e1, e2)))
            same |= kCMAudioFormatDescriptionMask_Extensions;
    }
    same &= equalityMask;
    if (equalityMaskOut)
        *equalityMaskOut = same;
    return same == equalityMask;
}

/* --- muxed streams, time codes --- */

OSStatus
CMMuxedFormatDescriptionCreate(CFAllocatorRef allocator, CMMuxedStreamType muxType, CFDictionaryRef extensions,
                               CMMuxedFormatDescriptionRef *formatDescriptionOut)
{
    if (!formatDescriptionOut)
        return kCMFormatDescriptionError_InvalidParameter;
    MutableDescription d = create(allocator, kCMMediaType_Muxed, muxType, extensions);
    if (!d)
        return kCMFormatDescriptionError_AllocationFailed;
    d->specific = true;
    d->mux = muxType;
    *formatDescriptionOut = d;
    return noErr;
}

OSStatus
CMTimeCodeFormatDescriptionCreate(CFAllocatorRef allocator, CMTimeCodeFormatType timeCodeFormatType, CMTime frameDuration, uint32_t frameQuanta,
                                  uint32_t flags, CFDictionaryRef extensions, CMTimeCodeFormatDescriptionRef *formatDescriptionOut)
{
    if (!formatDescriptionOut)
        return kCMFormatDescriptionError_InvalidParameter;
    MutableDescription d = create(allocator, kCMMediaType_TimeCode, timeCodeFormatType, extensions);
    if (!d)
        return kCMFormatDescriptionError_AllocationFailed;
    d->specific = true;
    d->timecode.frameDuration = frameDuration;
    d->timecode.quanta = frameQuanta;
    d->timecode.flags = flags;
    *formatDescriptionOut = d;
    return noErr;
}

CMTime
CMTimeCodeFormatDescriptionGetFrameDuration(CMTimeCodeFormatDescriptionRef timeCodeFormatDescription)
{
    return timeCodeFormatDescription && timeCodeFormatDescription->kind == KIND_TIMECODE ? timeCodeFormatDescription->timecode.frameDuration
                                                                                        : kCMTimeInvalid;
}

uint32_t
CMTimeCodeFormatDescriptionGetFrameQuanta(CMTimeCodeFormatDescriptionRef timeCodeFormatDescription)
{
    return timeCodeFormatDescription && timeCodeFormatDescription->kind == KIND_TIMECODE ? timeCodeFormatDescription->timecode.quanta : 0;
}

uint32_t
CMTimeCodeFormatDescriptionGetTimeCodeFlags(CMTimeCodeFormatDescriptionRef desc)
{
    return desc && desc->kind == KIND_TIMECODE ? desc->timecode.flags : 0;
}
