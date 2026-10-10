/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AudioToolbox's audio files, Finch's: WAVE, AIFF, AIFC, CAF and NeXT/Sun files read and
 * written, through a path or the caller's callbacks. Files are written as Apple's
 * writes them, so the bytes match: the header, a filler chunk ("FLLR", or CAF's "free")
 * so the audio data starts at 4096, then the data, its sizes put in the header as it
 * grows and when the file is closed.
 */
#include <AudioToolbox/AudioToolbox.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define ALIGN 4096

struct OpaqueAudioFileID {
    AudioFileTypeID type;
    int fd;
    void *client;
    AudioFile_ReadProc read;
    AudioFile_WriteProc write;
    AudioFile_GetSizeProc getSize;
    AudioFile_SetSizeProc setSize;
    bool writable, creating, deferSizes, dirty;
    AudioStreamBasicDescription format;
    SInt64 dataOffset, dataSize;
    SInt64 headerDataSizeAt; /* (where the data chunk's size is, to rewrite it) */
    AudioChannelLayout *layout;
    UInt32 layoutSize;
    CFDataRef cookie;
    /* (packets of formats whose packets vary in size, as CAF's 'pakt' lists them) */
    AudioStreamPacketDescription *packets;
    SInt64 packetCount, packetCapacity;
    UInt32 maxPacketSize;
    AudioFilePacketTableInfo packetInfo;
    CFMutableDictionaryRef info;
};

/* --- the bytes underneath --- */

static OSStatus
raw_read(AudioFileID f, SInt64 at, UInt32 size, void *out, UInt32 *got)
{
    if (f->read)
        return f->read(f->client, at, size, out, got);
    ssize_t n = pread(f->fd, out, size, at);
    if (n < 0)
        return kAudioFileUnspecifiedError;
    *got = (UInt32)n;
    return noErr;
}

static OSStatus
raw_write(AudioFileID f, SInt64 at, UInt32 size, const void *in)
{
    if (f->write) {
        UInt32 wrote = 0;
        OSStatus e = f->write(f->client, at, size, in, &wrote);
        return e ? e : wrote == size ? noErr : kAudioFileUnspecifiedError;
    }
    return pwrite(f->fd, in, size, at) == (ssize_t)size ? noErr : kAudioFilePermissionsError;
}

static SInt64
raw_size(AudioFileID f)
{
    if (f->getSize)
        return f->getSize(f->client);
    struct stat st;
    return fstat(f->fd, &st) ? 0 : st.st_size;
}

static void
raw_truncate(AudioFileID f, SInt64 size)
{
    if (f->setSize)
        f->setSize(f->client, size);
    else if (f->fd >= 0)
        ftruncate(f->fd, size);
}

/* Reads exactly size bytes at at; false if the file ends first. */
static bool
read_exact(AudioFileID f, SInt64 at, UInt32 size, void *out)
{
    UInt32 got = 0;
    return !raw_read(f, at, size, out, &got) && got == size;
}

static uint16_t
be16(const UInt8 *p)
{
    return (uint16_t)(p[0] << 8 | p[1]);
}

static uint32_t
be32(const UInt8 *p)
{
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

static uint64_t
be64(const UInt8 *p)
{
    return (uint64_t)be32(p) << 32 | be32(p + 4);
}

static uint16_t
le16(const UInt8 *p)
{
    return (uint16_t)(p[0] | p[1] << 8);
}

static uint32_t
le32(const UInt8 *p)
{
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

/* --- building headers --- */

typedef struct {
    UInt8 *b;
    size_t n, cap;
} Buf;

static void
put(Buf *o, const void *p, size_t n)
{
    if (o->n + n > o->cap) {
        o->cap = (o->n + n) * 2 + 64;
        o->b = realloc(o->b, o->cap);
    }
    memcpy(o->b + o->n, p, n);
    o->n += n;
}

static void
put_be16(Buf *o, uint32_t v)
{
    UInt8 b[2] = {(UInt8)(v >> 8), (UInt8)v};
    put(o, b, 2);
}

static void
put_be32(Buf *o, uint32_t v)
{
    UInt8 b[4] = {(UInt8)(v >> 24), (UInt8)(v >> 16), (UInt8)(v >> 8), (UInt8)v};
    put(o, b, 4);
}

static void
put_be64(Buf *o, uint64_t v)
{
    put_be32(o, (uint32_t)(v >> 32));
    put_be32(o, (uint32_t)v);
}

static void
put_le16(Buf *o, uint32_t v)
{
    UInt8 b[2] = {(UInt8)v, (UInt8)(v >> 8)};
    put(o, b, 2);
}

static void
put_le32(Buf *o, uint32_t v)
{
    UInt8 b[4] = {(UInt8)v, (UInt8)(v >> 8), (UInt8)(v >> 16), (UInt8)(v >> 24)};
    put(o, b, 4);
}

static void
put_zeros(Buf *o, size_t n)
{
    while (n--) {
        UInt8 z = 0;
        put(o, &z, 1);
    }
}

/* An 80-bit IEEE extended number (AIFF's sample rate). */
static void
put_extended(Buf *o, double v)
{
    UInt8 b[10] = {0};
    if (v > 0) {
        int exp;
        double m = frexp(v, &exp);
        uint64_t mant = (uint64_t)ldexp(m, 64);
        uint16_t e = (uint16_t)(exp - 1 + 16383);
        b[0] = (UInt8)(e >> 8), b[1] = (UInt8)e;
        for (int i = 0; i < 8; i++)
            b[2 + i] = (UInt8)(mant >> (56 - 8 * i));
    }
    put(o, b, 10);
}

static double
get_extended(const UInt8 *b)
{
    int e = ((b[0] & 0x7f) << 8) | b[1];
    uint64_t mant = be64(b + 2);
    if (!e && !mant)
        return 0;
    return ldexp((double)mant, e - 16383 - 63);
}

static void
put_be_double(Buf *o, double v)
{
    uint64_t bits;
    memcpy(&bits, &v, 8);
    put_be64(o, bits);
}

static double
get_be_double(const UInt8 *p)
{
    uint64_t bits = be64(p);
    double v;
    memcpy(&v, &bits, 8);
    return v;
}

/* --- the formats each file type takes --- */

static bool
pcm(const AudioStreamBasicDescription *a)
{
    return a->mFormatID == kAudioFormatLinearPCM;
}

static bool
big_endian(const AudioStreamBasicDescription *a)
{
    return (a->mFormatFlags & kAudioFormatFlagIsBigEndian) != 0;
}

static bool
is_float(const AudioStreamBasicDescription *a)
{
    return (a->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
}

/* Whether the type can hold the format (as Apple's decides for the formats Finch writes). */
static bool
type_takes(AudioFileTypeID type, const AudioStreamBasicDescription *a)
{
    bool law = a->mFormatID == kAudioFormatULaw || a->mFormatID == kAudioFormatALaw;
    switch (type) {
    case kAudioFileWAVEType:
        return law || (pcm(a) && !big_endian(a) && !(a->mFormatFlags & kAudioFormatFlagIsNonInterleaved));
    case kAudioFileAIFFType:
        return pcm(a) && !is_float(a) && (big_endian(a) || a->mBitsPerChannel <= 8) && (a->mFormatFlags & kAudioFormatFlagIsSignedInteger);
    case kAudioFileAIFCType:
        return law || (pcm(a) && !(a->mFormatFlags & kAudioFormatFlagIsNonInterleaved));
    case kAudioFileCAFType:
        return !(a->mFormatFlags & kAudioFormatFlagIsNonInterleaved);
    case kAudioFileNextType:
        return law || (pcm(a) && (big_endian(a) || a->mBitsPerChannel <= 8) && (a->mFormatFlags & kAudioFormatFlagIsSignedInteger || is_float(a)));
    }
    return false;
}

/* --- WAVE --- */

static uint32_t
wave_tag(const AudioStreamBasicDescription *a)
{
    if (a->mFormatID == kAudioFormatULaw)
        return 7;
    if (a->mFormatID == kAudioFormatALaw)
        return 6;
    return is_float(a) ? 3 : 1;
}

/* The WAVE channel mask for a layout (Apple's uses the side speakers for Ls and Rs). */
static uint32_t
wave_mask(const AudioChannelLayout *l, UInt32 channels)
{
    UInt32 n = 0;
    AudioChannelLayout *full = NULL;
    AudioChannelLabel labels[32];
    if (l->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions) {
        n = l->mNumberChannelDescriptions < 32 ? l->mNumberChannelDescriptions : 32;
        for (UInt32 i = 0; i < n; i++)
            labels[i] = l->mChannelDescriptions[i].mChannelLabel;
    } else {
        UInt32 size = 0;
        AudioChannelLayoutTag tag = l->mChannelLayoutTag;
        if (!AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag, 4, &tag, &size) && size) {
            full = malloc(size);
            if (!AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag, 4, &tag, &size, full)) {
                n = full->mNumberChannelDescriptions < 32 ? full->mNumberChannelDescriptions : 32;
                for (UInt32 i = 0; i < n; i++)
                    labels[i] = full->mChannelDescriptions[i].mChannelLabel;
            }
            free(full);
        }
    }
    static const struct {
        AudioChannelLabel label;
        uint32_t bit;
    } bits[] = {{kAudioChannelLabel_Left, 0x1},          {kAudioChannelLabel_Right, 0x2},          {kAudioChannelLabel_Center, 0x4},
                {kAudioChannelLabel_LFEScreen, 0x8},     {kAudioChannelLabel_RearSurroundLeft, 0x10}, {kAudioChannelLabel_RearSurroundRight, 0x20},
                {kAudioChannelLabel_LeftCenter, 0x40},   {kAudioChannelLabel_RightCenter, 0x80},   {kAudioChannelLabel_CenterSurround, 0x100},
                {kAudioChannelLabel_LeftSurround, 0x200}, {kAudioChannelLabel_RightSurround, 0x400}, {kAudioChannelLabel_TopCenterSurround, 0x800},
                {kAudioChannelLabel_VerticalHeightLeft, 0x1000}, {kAudioChannelLabel_VerticalHeightCenter, 0x2000},
                {kAudioChannelLabel_VerticalHeightRight, 0x4000}, {kAudioChannelLabel_TopBackLeft, 0x8000},
                {kAudioChannelLabel_TopBackCenter, 0x10000}, {kAudioChannelLabel_TopBackRight, 0x20000}};
    uint32_t mask = 0;
    for (UInt32 i = 0; i < n; i++)
        for (size_t k = 0; k < sizeof bits / sizeof bits[0]; k++)
            if (bits[k].label == labels[i])
                mask |= bits[k].bit;
    (void)channels;
    return mask;
}

static void
wave_header(AudioFileID f, Buf *o)
{
    const AudioStreamBasicDescription *a = &f->format;
    bool extensible = f->layout != NULL;
    put(o, "RIFF", 4);
    put_le32(o, 0);
    put(o, "WAVE", 4);
    put(o, "fmt ", 4);
    put_le32(o, extensible ? 40 : 16);
    put_le16(o, extensible ? 0xfffe : wave_tag(a));
    put_le16(o, a->mChannelsPerFrame);
    put_le32(o, (uint32_t)a->mSampleRate);
    put_le32(o, (uint32_t)(a->mSampleRate * a->mBytesPerFrame));
    put_le16(o, a->mBytesPerFrame);
    put_le16(o, a->mBitsPerChannel);
    if (extensible) {
        put_le16(o, 22);
        put_le16(o, a->mBitsPerChannel);
        put_le32(o, wave_mask(f->layout, a->mChannelsPerFrame));
        /* (the subformat: the format tag in the GUID xxxxxxxx-0000-0010-8000-00aa00389b71) */
        put_le32(o, wave_tag(a));
        static const UInt8 guid[12] = {0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71};
        put(o, guid, 12);
    }
    /* (the filler, so the data starts at the next 4096) */
    size_t data = (o->n + 16 + ALIGN - 1) / ALIGN * ALIGN;
    put(o, "FLLR", 4);
    put_le32(o, (uint32_t)(data - o->n - 12));
    put_zeros(o, data - o->n - 8);
    put(o, "data", 4);
    f->headerDataSizeAt = (SInt64)o->n;
    put_le32(o, 0);
    f->dataOffset = (SInt64)o->n;
}

static void
wave_sizes(AudioFileID f)
{
    Buf o = {0};
    put_le32(&o, (uint32_t)(f->dataOffset + f->dataSize - 8));
    raw_write(f, 4, 4, o.b);
    o.n = 0;
    put_le32(&o, (uint32_t)f->dataSize);
    raw_write(f, f->headerDataSizeAt, 4, o.b);
    free(o.b);
}

/* A WAVE channel mask as a layout: the tag whose channels are the mask's, in order, as
   Apple's reads it (the side speakers are Ls and Rs); or the channels described. */
static void
layout_from_mask(AudioFileID f, uint32_t mask)
{
    static const AudioChannelLabel order[18] = {
        kAudioChannelLabel_Left,          kAudioChannelLabel_Right,              kAudioChannelLabel_Center,
        kAudioChannelLabel_LFEScreen,     kAudioChannelLabel_RearSurroundLeft,   kAudioChannelLabel_RearSurroundRight,
        kAudioChannelLabel_LeftCenter,    kAudioChannelLabel_RightCenter,        kAudioChannelLabel_CenterSurround,
        kAudioChannelLabel_LeftSurround,  kAudioChannelLabel_RightSurround,      kAudioChannelLabel_TopCenterSurround,
        kAudioChannelLabel_VerticalHeightLeft, kAudioChannelLabel_VerticalHeightCenter, kAudioChannelLabel_VerticalHeightRight,
        kAudioChannelLabel_TopBackLeft,   kAudioChannelLabel_TopBackCenter,      kAudioChannelLabel_TopBackRight};
    AudioChannelLabel labels[18];
    UInt32 n = 0;
    for (int bit = 0; bit < 18; bit++)
        if (mask & (1u << bit))
            labels[n++] = order[bit];
    /* (the layouts for that many channels, for one with these channels in this order) */
    UInt32 size = 0;
    if (!AudioFormatGetPropertyInfo(kAudioFormatProperty_TagsForNumberOfChannels, 4, &n, &size) && size) {
        AudioChannelLayoutTag *tags = malloc(size);
        AudioFormatGetProperty(kAudioFormatProperty_TagsForNumberOfChannels, 4, &n, &size, tags);
        for (UInt32 i = 0; i < size / 4; i++) {
            UInt32 full = 0;
            if (AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag, 4, &tags[i], &full) || !full)
                continue;
            AudioChannelLayout *l = malloc(full);
            bool same = !AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag, 4, &tags[i], &full, l) && l->mNumberChannelDescriptions == n;
            for (UInt32 k = 0; same && k < n; k++)
                same = l->mChannelDescriptions[k].mChannelLabel == labels[k];
            free(l);
            if (same) {
                f->layoutSize = sizeof(AudioChannelLayout);
                f->layout = calloc(1, f->layoutSize);
                f->layout->mChannelLayoutTag = tags[i];
                free(tags);
                return;
            }
        }
        free(tags);
    }
    f->layoutSize = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + sizeof(AudioChannelDescription) * (n ? n : 1));
    f->layout = calloc(1, f->layoutSize);
    f->layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
    f->layout->mNumberChannelDescriptions = n;
    for (UInt32 i = 0; i < n; i++)
        f->layout->mChannelDescriptions[i].mChannelLabel = labels[i];
}

static OSStatus
wave_parse(AudioFileID f)
{
    UInt8 h[12];
    if (!read_exact(f, 0, 12, h) || (memcmp(h, "RIFF", 4) && memcmp(h, "RF64", 4)) || memcmp(h + 8, "WAVE", 4))
        return kAudioFileInvalidFileError;
    bool rf64 = !memcmp(h, "RF64", 4);
    SInt64 size = raw_size(f), at = 12, dataSize64 = -1;
    bool haveFormat = false, haveData = false;
    while (at + 8 <= size) {
        UInt8 c[8];
        if (!read_exact(f, at, 8, c))
            break;
        uint32_t len = le32(c + 4);
        if (!memcmp(c, "ds64", 4) && len >= 16) {
            UInt8 d[16];
            if (read_exact(f, at + 8, 16, d))
                dataSize64 = (SInt64)((uint64_t)le32(d + 8) | (uint64_t)le32(d + 12) << 32);
        } else if (!memcmp(c, "fmt ", 4) && len >= 16) {
            UInt8 fm[40] = {0};
            if (!read_exact(f, at + 8, len < 40 ? len : 40, fm))
                return kAudioFileInvalidFileError;
            uint32_t tag = le16(fm);
            AudioStreamBasicDescription *a = &f->format;
            memset(a, 0, sizeof *a);
            a->mChannelsPerFrame = le16(fm + 2);
            a->mSampleRate = le32(fm + 4);
            a->mBytesPerFrame = le16(fm + 12);
            a->mBitsPerChannel = le16(fm + 14);
            if (tag == 0xfffe && len >= 40) {
                tag = le32(fm + 24);
                uint32_t valid = le16(fm + 18), mask = le32(fm + 20);
                if (valid && valid < a->mBitsPerChannel) {
                    a->mFormatFlags |= kAudioFormatFlagIsAlignedHigh;
                    a->mBitsPerChannel = valid;
                }
                if (mask)
                    layout_from_mask(f, mask);
            }
            a->mFramesPerPacket = 1;
            a->mBytesPerPacket = a->mBytesPerFrame;
            switch (tag) {
            case 1:
                a->mFormatID = kAudioFormatLinearPCM;
                a->mFormatFlags |= (a->mBitsPerChannel > 8 ? kAudioFormatFlagIsSignedInteger : 0);
                break;
            case 3:
                a->mFormatID = kAudioFormatLinearPCM;
                a->mFormatFlags |= kAudioFormatFlagIsFloat;
                break;
            case 6: a->mFormatID = kAudioFormatALaw; break;
            case 7: a->mFormatID = kAudioFormatULaw; break;
            default: return kAudioFileUnsupportedDataFormatError;
            }
            if (a->mFormatID == kAudioFormatLinearPCM && a->mBytesPerFrame == a->mChannelsPerFrame * ((a->mBitsPerChannel + 7) / 8) &&
                !(a->mFormatFlags & kAudioFormatFlagIsAlignedHigh))
                a->mFormatFlags |= kAudioFormatFlagIsPacked;
            haveFormat = true;
        } else if (!memcmp(c, "data", 4)) {
            f->dataOffset = at + 8;
            f->dataSize = rf64 && len == 0xffffffff && dataSize64 >= 0 ? dataSize64 : len;
            if (f->dataOffset + f->dataSize > size)
                f->dataSize = size - f->dataOffset;
            f->headerDataSizeAt = at + 4;
            haveData = true;
        }
        at += 8 + len + (len & 1);
        if (haveData && haveFormat && at > size)
            break;
    }
    return haveFormat && haveData ? noErr : kAudioFileInvalidFileError;
}

/* --- AIFF and AIFC --- */

static uint32_t
aifc_compression(const AudioStreamBasicDescription *a)
{
    if (a->mFormatID == kAudioFormatULaw)
        return 'ulaw';
    if (a->mFormatID == kAudioFormatALaw)
        return 'alaw';
    if (is_float(a))
        return a->mBitsPerChannel == 64 ? 'fl64' : 'fl32';
    if (a->mBitsPerChannel <= 8)
        return 'raw ';
    return big_endian(a) ? 'twos' : 'sowt';
}

/* The compression's name: the format's own, up to its channels and rate. */
static CFStringRef
aifc_name(const AudioStreamBasicDescription *a)
{
    CFStringRef name = NULL;
    UInt32 size = sizeof name;
    if (AudioFormatGetProperty(kAudioFormatProperty_FormatName, sizeof *a, a, &size, &name) || !name)
        return CFSTR("");
    CFStringRef tail = CFStringCreateWithFormat(NULL, NULL, CFSTR(", %u channels"), (unsigned)a->mChannelsPerFrame);
    CFRange at = CFStringFind(name, tail, 0);
    CFRelease(tail);
    if (at.location == kCFNotFound)
        return name;
    CFStringRef cut = CFStringCreateWithSubstring(NULL, name, CFRangeMake(0, at.location));
    CFRelease(name);
    return cut;
}

static void
aiff_header(AudioFileID f, Buf *o)
{
    const AudioStreamBasicDescription *a = &f->format;
    bool aifc = f->type == kAudioFileAIFCType;
    put(o, "FORM", 4);
    put_be32(o, 0);
    put(o, aifc ? "AIFC" : "AIFF", 4);
    if (aifc) {
        put(o, "FVER", 4);
        put_be32(o, 4);
        put_be32(o, 0xA2805140);
    }
    char name[256] = {0};
    if (aifc) {
        CFStringRef n = aifc_name(a);
        CFStringGetCString(n, name, sizeof name, kCFStringEncodingMacRoman);
        CFRelease(n);
    }
    size_t nameLength = strlen(name), pstring = 1 + nameLength + ((1 + nameLength) & 1);
    put(o, "COMM", 4);
    put_be32(o, (uint32_t)(18 + (aifc ? 4 + pstring : 0)));
    put_be16(o, a->mChannelsPerFrame);
    put_be32(o, 0);
    put_be16(o, a->mBitsPerChannel);
    put_extended(o, a->mSampleRate);
    if (aifc) {
        put_be32(o, aifc_compression(a));
        UInt8 len = (UInt8)nameLength;
        put(o, &len, 1);
        put(o, name, nameLength);
        if ((1 + nameLength) & 1)
            put_zeros(o, 1);
    }
    size_t data = (o->n + 8 + 16 + ALIGN - 1) / ALIGN * ALIGN;
    put(o, "FLLR", 4);
    put_be32(o, (uint32_t)(data - o->n - 4 - 16));
    put_zeros(o, data - o->n - 16);
    put(o, "SSND", 4);
    f->headerDataSizeAt = (SInt64)o->n;
    put_be32(o, 8);
    put_be32(o, 0);
    put_be32(o, 0);
    f->dataOffset = (SInt64)o->n;
}

static void
aiff_sizes(AudioFileID f)
{
    Buf o = {0};
    put_be32(&o, (uint32_t)(f->dataOffset + f->dataSize - 8));
    raw_write(f, 4, 4, o.b);
    o.n = 0;
    put_be32(&o, (uint32_t)(f->dataSize + 8));
    raw_write(f, f->headerDataSizeAt, 4, o.b);
    o.n = 0;
    put_be32(&o, f->format.mBytesPerFrame ? (uint32_t)(f->dataSize / f->format.mBytesPerFrame) : 0);
    /* (COMM's frame count: after the channel count, its chunk just after FORM's, or FVER's) */
    raw_write(f, f->type == kAudioFileAIFCType ? 12 + 12 + 8 + 2 : 12 + 8 + 2, 4, o.b);
    free(o.b);
}

static OSStatus
aiff_parse(AudioFileID f)
{
    UInt8 h[12];
    if (!read_exact(f, 0, 12, h) || memcmp(h, "FORM", 4) || (memcmp(h + 8, "AIFF", 4) && memcmp(h + 8, "AIFC", 4)))
        return kAudioFileInvalidFileError;
    bool aifc = !memcmp(h + 8, "AIFC", 4);
    SInt64 size = raw_size(f), at = 12;
    bool haveFormat = false, haveData = false;
    while (at + 8 <= size) {
        UInt8 c[8];
        if (!read_exact(f, at, 8, c))
            break;
        uint32_t len = be32(c + 4);
        if (!memcmp(c, "COMM", 4) && len >= 18) {
            UInt8 cm[24] = {0};
            if (!read_exact(f, at + 8, len < 22 ? len : 22, cm))
                return kAudioFileInvalidFileError;
            AudioStreamBasicDescription *a = &f->format;
            memset(a, 0, sizeof *a);
            a->mChannelsPerFrame = be16(cm);
            a->mBitsPerChannel = be16(cm + 6);
            a->mSampleRate = get_extended(cm + 8);
            uint32_t comp = aifc && len >= 22 ? be32(cm + 18) : 'NONE';
            a->mFormatID = kAudioFormatLinearPCM;
            a->mFramesPerPacket = 1;
            UInt32 bytes = (a->mBitsPerChannel + 7) / 8;
            switch (comp) {
            case 'NONE':
            case 'twos':
                a->mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | (bytes > 1 ? kAudioFormatFlagIsBigEndian : 0);
                break;
            case 'sowt': a->mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked; break;
            case 'raw ': a->mFormatFlags = kAudioFormatFlagIsPacked; break;
            case 'fl32':
            case 'FL32':
                a->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsBigEndian;
                a->mBitsPerChannel = 32, bytes = 4;
                break;
            case 'fl64':
            case 'FL64':
                a->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsBigEndian;
                a->mBitsPerChannel = 64, bytes = 8;
                break;
            case 'ulaw':
            case 'ULAW': a->mFormatID = kAudioFormatULaw, a->mFormatFlags = 0, a->mBitsPerChannel = 8, bytes = 1; break;
            case 'alaw':
            case 'ALAW': a->mFormatID = kAudioFormatALaw, a->mFormatFlags = 0, a->mBitsPerChannel = 8, bytes = 1; break;
            default: return kAudioFileUnsupportedDataFormatError;
            }
            a->mBytesPerFrame = a->mBytesPerPacket = bytes * a->mChannelsPerFrame;
            haveFormat = true;
        } else if (!memcmp(c, "SSND", 4) && len >= 8) {
            UInt8 s[8];
            if (!read_exact(f, at + 8, 8, s))
                return kAudioFileInvalidFileError;
            f->dataOffset = at + 16 + be32(s);
            f->dataSize = len - 8 - be32(s);
            if (f->dataOffset + f->dataSize > size)
                f->dataSize = size - f->dataOffset;
            f->headerDataSizeAt = at + 4;
            haveData = true;
        }
        at += 8 + len + (len & 1);
    }
    return haveFormat && haveData ? noErr : kAudioFileInvalidFileError;
}

/* --- CAF --- */

static uint32_t
caf_flags(const AudioStreamBasicDescription *a)
{
    if (!pcm(a))
        return a->mFormatFlags;
    /* (CAF's own: float, little-endian) */
    return (is_float(a) ? 1 : 0) | (big_endian(a) ? 0 : 2);
}

static void
caf_header(AudioFileID f, Buf *o)
{
    const AudioStreamBasicDescription *a = &f->format;
    put(o, "caff", 4);
    put_be16(o, 1);
    put_be16(o, 0);
    put(o, "desc", 4);
    put_be64(o, 32);
    put_be_double(o, a->mSampleRate);
    put_be32(o, a->mFormatID);
    put_be32(o, caf_flags(a));
    put_be32(o, a->mBytesPerPacket);
    put_be32(o, a->mFramesPerPacket);
    put_be32(o, a->mChannelsPerFrame);
    put_be32(o, a->mBitsPerChannel);
    if (f->layout) {
        /* (a layout as Apple's writes it: at least one description's room) */
        UInt32 n = f->layout->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions ? f->layout->mNumberChannelDescriptions : 0;
        put(o, "chan", 4);
        put_be64(o, 12 + 20 * (n ? n : 1));
        put_be32(o, f->layout->mChannelLayoutTag);
        put_be32(o, f->layout->mChannelBitmap);
        put_be32(o, n);
        if (!n)
            put_zeros(o, 20);
        for (UInt32 i = 0; i < n; i++) {
            const AudioChannelDescription *d = &f->layout->mChannelDescriptions[i];
            put_be32(o, d->mChannelLabel);
            put_be32(o, d->mChannelFlags);
            for (int k = 0; k < 3; k++) {
                uint32_t bits;
                memcpy(&bits, &d->mCoordinates[k], 4);
                put_be32(o, bits);
            }
        }
    }
    if (f->cookie) {
        put(o, "kuki", 4);
        put_be64(o, (uint64_t)CFDataGetLength(f->cookie));
        put(o, CFDataGetBytePtr(f->cookie), (size_t)CFDataGetLength(f->cookie));
    }
    size_t data = (o->n + 12 + 16 + ALIGN - 1) / ALIGN * ALIGN;
    put(o, "free", 4);
    put_be64(o, (uint64_t)(data - o->n - 8 - 16));
    put_zeros(o, data - o->n - 16);
    put(o, "data", 4);
    f->headerDataSizeAt = (SInt64)o->n;
    put_be64(o, 4);
    put_be32(o, 0);
    f->dataOffset = (SInt64)o->n;
}

static void
caf_sizes(AudioFileID f)
{
    Buf o = {0};
    put_be64(&o, (uint64_t)(f->dataSize + 4));
    raw_write(f, f->headerDataSizeAt, 8, o.b);
    free(o.b);
}

static OSStatus
caf_parse(AudioFileID f)
{
    UInt8 h[8];
    if (!read_exact(f, 0, 8, h) || memcmp(h, "caff", 4))
        return kAudioFileInvalidFileError;
    SInt64 size = raw_size(f), at = 8;
    bool haveFormat = false, haveData = false;
    while (at + 12 <= size) {
        UInt8 c[12];
        if (!read_exact(f, at, 12, c))
            break;
        int64_t len = (int64_t)be64(c + 4);
        SInt64 body = at + 12;
        if (!memcmp(c, "desc", 4) && len >= 32) {
            UInt8 d[32];
            if (!read_exact(f, body, 32, d))
                return kAudioFileInvalidFileError;
            AudioStreamBasicDescription *a = &f->format;
            a->mSampleRate = get_be_double(d);
            a->mFormatID = be32(d + 8);
            uint32_t flags = be32(d + 12);
            a->mBytesPerPacket = be32(d + 16);
            a->mFramesPerPacket = be32(d + 20);
            a->mChannelsPerFrame = be32(d + 24);
            a->mBitsPerChannel = be32(d + 28);
            if (pcm(a)) {
                a->mFormatFlags = ((flags & 1) ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) | ((flags & 2) ? 0 : kAudioFormatFlagIsBigEndian);
                if (a->mBitsPerChannel <= 8 && !(flags & 1))
                    a->mFormatFlags &= ~kAudioFormatFlagIsBigEndian;
                if (a->mBytesPerPacket == a->mChannelsPerFrame * ((a->mBitsPerChannel + 7) / 8))
                    a->mFormatFlags |= kAudioFormatFlagIsPacked;
                a->mBytesPerFrame = a->mBytesPerPacket;
            } else {
                a->mFormatFlags = flags;
                a->mBytesPerFrame = a->mFramesPerPacket == 1 ? a->mBytesPerPacket : 0;
            }
            haveFormat = true;
        } else if (!memcmp(c, "chan", 4) && len >= 12) {
            UInt8 *d = malloc((size_t)len);
            if (read_exact(f, body, (UInt32)len, d)) {
                UInt32 n = be32(d + 8);
                f->layoutSize = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + sizeof(AudioChannelDescription) * (n ? n : 1));
                f->layout = calloc(1, f->layoutSize);
                f->layout->mChannelLayoutTag = be32(d);
                f->layout->mChannelBitmap = be32(d + 4);
                f->layout->mNumberChannelDescriptions = n;
                for (UInt32 i = 0; i < n && 12 + 20 * (i + 1) <= len; i++) {
                    const UInt8 *p = d + 12 + 20 * i;
                    f->layout->mChannelDescriptions[i].mChannelLabel = be32(p);
                    f->layout->mChannelDescriptions[i].mChannelFlags = be32(p + 4);
                    for (int k = 0; k < 3; k++) {
                        uint32_t bits = be32(p + 8 + 4 * k);
                        memcpy(&f->layout->mChannelDescriptions[i].mCoordinates[k], &bits, 4);
                    }
                }
            }
            free(d);
        } else if (!memcmp(c, "kuki", 4) && len > 0) {
            UInt8 *d = malloc((size_t)len);
            if (read_exact(f, body, (UInt32)len, d))
                f->cookie = CFDataCreate(NULL, d, (CFIndex)len);
            free(d);
        } else if (!memcmp(c, "pakt", 4) && len >= 24) {
            UInt8 *d = malloc((size_t)len);
            if (read_exact(f, body, (UInt32)len, d)) {
                int64_t n = (int64_t)be64(d);
                f->packetInfo.mNumberValidFrames = (SInt64)be64(d + 8);
                f->packetInfo.mPrimingFrames = (SInt32)be32(d + 16);
                f->packetInfo.mRemainderFrames = (SInt32)be32(d + 20);
                /* (each packet's size, and frames when they vary, as variable-length integers) */
                f->packets = calloc((size_t)(n ? n : 1), sizeof *f->packets);
                f->packetCount = f->packetCapacity = n;
                const UInt8 *p = d + 24, *end = d + len;
                SInt64 offset = 0;
                for (int64_t i = 0; i < n && p < end; i++) {
                    uint64_t v[2] = {0, 0};
                    for (int k = 0; k < ((f->format.mBytesPerPacket == 0 && f->format.mFramesPerPacket == 0) ? 2 : 1); k++)
                        if (k == 0 ? f->format.mBytesPerPacket == 0 : true)
                            while (p < end) {
                                v[k] = v[k] << 7 | (*p & 0x7f);
                                if (!(*p++ & 0x80))
                                    break;
                            }
                    f->packets[i].mStartOffset = offset;
                    f->packets[i].mDataByteSize = (UInt32)(f->format.mBytesPerPacket ? f->format.mBytesPerPacket : v[0]);
                    f->packets[i].mVariableFramesInPacket = (UInt32)(f->format.mFramesPerPacket ? 0 : v[f->format.mBytesPerPacket ? 0 : 1]);
                    if (f->packets[i].mDataByteSize > f->maxPacketSize)
                        f->maxPacketSize = f->packets[i].mDataByteSize;
                    offset += f->packets[i].mDataByteSize;
                }
            }
            free(d);
        } else if (!memcmp(c, "data", 4)) {
            f->dataOffset = body + 4;
            f->dataSize = len == -1 ? size - f->dataOffset : len - 4;
            f->headerDataSizeAt = at + 4;
            haveData = true;
            if (len == -1)
                break;
        }
        if (len < 0)
            break;
        at = body + len;
    }
    return haveFormat && haveData ? noErr : kAudioFileInvalidFileError;
}

/* --- NeXT/Sun --- */

static uint32_t
next_encoding(const AudioStreamBasicDescription *a)
{
    if (a->mFormatID == kAudioFormatULaw)
        return 1;
    if (a->mFormatID == kAudioFormatALaw)
        return 27;
    if (is_float(a))
        return a->mBitsPerChannel == 64 ? 7 : 6;
    switch (a->mBitsPerChannel) {
    case 8: return 2;
    case 16: return 3;
    case 24: return 4;
    default: return 5;
    }
}

static void
next_header(AudioFileID f, Buf *o)
{
    const AudioStreamBasicDescription *a = &f->format;
    put(o, ".snd", 4);
    put_be32(o, 28);
    f->headerDataSizeAt = (SInt64)o->n;
    put_be32(o, 0);
    put_be32(o, next_encoding(a));
    put_be32(o, (uint32_t)a->mSampleRate);
    put_be32(o, a->mChannelsPerFrame);
    put_be32(o, 0);
    f->dataOffset = (SInt64)o->n;
}

static void
next_sizes(AudioFileID f)
{
    Buf o = {0};
    put_be32(&o, (uint32_t)f->dataSize);
    raw_write(f, f->headerDataSizeAt, 4, o.b);
    free(o.b);
}

static OSStatus
next_parse(AudioFileID f)
{
    UInt8 h[24];
    if (!read_exact(f, 0, 24, h) || memcmp(h, ".snd", 4))
        return kAudioFileInvalidFileError;
    AudioStreamBasicDescription *a = &f->format;
    memset(a, 0, sizeof *a);
    f->dataOffset = be32(h + 4);
    uint32_t size = be32(h + 8), enc = be32(h + 12);
    a->mSampleRate = be32(h + 16);
    a->mChannelsPerFrame = be32(h + 20);
    a->mFormatID = kAudioFormatLinearPCM;
    a->mFramesPerPacket = 1;
    UInt32 bytes;
    switch (enc) {
    case 1: a->mFormatID = kAudioFormatULaw, a->mBitsPerChannel = 8, bytes = 1, a->mFormatFlags = kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsPacked; break;
    case 27: a->mFormatID = kAudioFormatALaw, a->mBitsPerChannel = 8, bytes = 1, a->mFormatFlags = kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsPacked; break;
    case 2: a->mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, a->mBitsPerChannel = 8, bytes = 1; break;
    case 3:
    case 4:
    case 5:
        bytes = enc - 1;
        a->mBitsPerChannel = bytes * 8;
        a->mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagIsBigEndian;
        break;
    case 6:
    case 7:
        bytes = enc == 6 ? 4 : 8;
        a->mBitsPerChannel = bytes * 8;
        a->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsBigEndian;
        break;
    default: return kAudioFileUnsupportedDataFormatError;
    }
    a->mBytesPerFrame = a->mBytesPerPacket = bytes * a->mChannelsPerFrame;
    SInt64 total = raw_size(f);
    f->dataSize = size == 0xffffffff || f->dataOffset + size > total ? total - f->dataOffset : size;
    f->headerDataSizeAt = 8;
    return noErr;
}

/* --- the handlers --- */

typedef struct {
    AudioFileTypeID type;
    OSStatus (*parse)(AudioFileID);
    void (*header)(AudioFileID, Buf *);
    void (*sizes)(AudioFileID);
} Handler;

static const Handler handlers[] = {
    {kAudioFileWAVEType, wave_parse, wave_header, wave_sizes}, {kAudioFileAIFFType, aiff_parse, aiff_header, aiff_sizes},
    {kAudioFileAIFCType, aiff_parse, aiff_header, aiff_sizes}, {kAudioFileCAFType, caf_parse, caf_header, caf_sizes},
    {kAudioFileNextType, next_parse, next_header, next_sizes},
};

static const Handler *
handler_for(AudioFileTypeID type)
{
    for (size_t i = 0; i < sizeof handlers / sizeof handlers[0]; i++)
        if (handlers[i].type == type)
            return &handlers[i];
    return NULL;
}

static void
update_sizes(AudioFileID f)
{
    const Handler *h = handler_for(f->type);
    if (h && f->writable)
        h->sizes(f);
    f->dirty = false;
}

/* --- opening and creating --- */

static AudioFileID
new_file(void)
{
    AudioFileID f = calloc(1, sizeof *f);
    f->fd = -1;
    return f;
}

static void
dispose(AudioFileID f)
{
    if (f->fd >= 0)
        close(f->fd);
    free(f->layout);
    free(f->packets);
    if (f->cookie)
        CFRelease(f->cookie);
    if (f->info)
        CFRelease(f->info);
    free(f);
}

/* Which type a file's first bytes say it is. */
static AudioFileTypeID
sniff(AudioFileID f)
{
    UInt8 h[12] = {0};
    UInt32 got = 0;
    raw_read(f, 0, 12, h, &got);
    if (got >= 12 && (!memcmp(h, "RIFF", 4) || !memcmp(h, "RF64", 4)) && !memcmp(h + 8, "WAVE", 4))
        return !memcmp(h, "RF64", 4) ? kAudioFileRF64Type : kAudioFileWAVEType;
    if (got >= 12 && !memcmp(h, "FORM", 4))
        return !memcmp(h + 8, "AIFC", 4) ? kAudioFileAIFCType : kAudioFileAIFFType;
    if (got >= 4 && !memcmp(h, "caff", 4))
        return kAudioFileCAFType;
    if (got >= 4 && !memcmp(h, ".snd", 4))
        return kAudioFileNextType;
    return 0;
}

static OSStatus
open_parsed(AudioFileID f, AudioFileTypeID hint)
{
    AudioFileTypeID type = sniff(f);
    if (!type)
        return hint ? kAudioFileInvalidFileError : kAudioFileUnsupportedFileTypeError;
    f->type = type == kAudioFileRF64Type ? kAudioFileWAVEType : type;
    const Handler *h = handler_for(f->type);
    OSStatus e = h->parse(f);
    if (type == kAudioFileRF64Type)
        f->type = kAudioFileRF64Type;
    return e;
}

static OSStatus
start_writing(AudioFileID f, AudioFileTypeID type, const AudioStreamBasicDescription *format)
{
    const Handler *h = handler_for(type);
    if (!h)
        return kAudioFileUnsupportedFileTypeError;
    if (!format || !type_takes(type, format))
        return kAudioFileUnsupportedDataFormatError;
    f->type = type;
    f->format = *format;
    f->writable = f->creating = true;
    raw_truncate(f, 0);
    Buf o = {0};
    h->header(f, &o);
    OSStatus e = raw_write(f, 0, (UInt32)o.n, o.b);
    free(o.b);
    f->dataSize = 0;
    if (!e)
        update_sizes(f);
    return e;
}

/* Rewrites the header (after a layout or cookie is set before any data). */
static OSStatus
rewrite_header(AudioFileID f)
{
    const Handler *h = handler_for(f->type);
    if (!h || f->dataSize)
        return kAudioFileOperationNotSupportedError;
    Buf o = {0};
    h->header(f, &o);
    raw_truncate(f, 0);
    OSStatus e = raw_write(f, 0, (UInt32)o.n, o.b);
    free(o.b);
    update_sizes(f);
    return e;
}

static int
open_path(CFURLRef url, int flags)
{
    char path[PATH_MAX];
    if (!url || !CFURLGetFileSystemRepresentation(url, true, (UInt8 *)path, sizeof path))
        return -1;
    return open(path, flags | O_CLOEXEC, 0644);
}

OSStatus
AudioFileCreateWithURL(CFURLRef inFileRef, AudioFileTypeID inFileType, const AudioStreamBasicDescription *inFormat, AudioFileFlags inFlags,
                       AudioFileID *outAudioFile)
{
    if (!inFileRef || !inFormat || !outAudioFile)
        return kAudio_ParamError;
    *outAudioFile = NULL;
    if (!handler_for(inFileType))
        return kAudioFileUnsupportedFileTypeError;
    if (!type_takes(inFileType, inFormat))
        return kAudioFileUnsupportedDataFormatError;
    int fd = open_path(inFileRef, O_RDWR | O_CREAT | ((inFlags & kAudioFileFlags_EraseFile) ? O_TRUNC : O_EXCL));
    if (fd < 0)
        return errno == EEXIST ? kAudioFilePermissionsError : kAudioFilePermissionsError;
    AudioFileID f = new_file();
    f->fd = fd;
    OSStatus e = start_writing(f, inFileType, inFormat);
    if (e) {
        dispose(f);
        return e;
    }
    *outAudioFile = f;
    return noErr;
}

OSStatus
AudioFileOpenURL(CFURLRef inFileRef, AudioFilePermissions inPermissions, AudioFileTypeID inFileTypeHint, AudioFileID *outAudioFile)
{
    if (!inFileRef || !outAudioFile)
        return kAudio_ParamError;
    *outAudioFile = NULL;
    int flags = inPermissions == kAudioFileReadPermission ? O_RDONLY : inPermissions == kAudioFileWritePermission ? O_RDWR : O_RDWR;
    int fd = open_path(inFileRef, flags);
    if (fd < 0)
        return errno == ENOENT ? kAudioFileUnspecifiedError : kAudioFilePermissionsError;
    AudioFileID f = new_file();
    f->fd = fd;
    f->writable = inPermissions != kAudioFileReadPermission;
    OSStatus e = open_parsed(f, inFileTypeHint);
    if (e) {
        dispose(f);
        return e;
    }
    *outAudioFile = f;
    return noErr;
}

OSStatus
AudioFileInitializeWithCallbacks(void *inClientData, AudioFile_ReadProc inReadFunc, AudioFile_WriteProc inWriteFunc,
                                 AudioFile_GetSizeProc inGetSizeFunc, AudioFile_SetSizeProc inSetSizeFunc, AudioFileTypeID inFileType,
                                 const AudioStreamBasicDescription *inFormat, AudioFileFlags inFlags, AudioFileID *outAudioFile)
{
    if (!inReadFunc || !inWriteFunc || !inGetSizeFunc || !inSetSizeFunc || !outAudioFile)
        return kAudio_ParamError;
    AudioFileID f = new_file();
    f->client = inClientData, f->read = inReadFunc, f->write = inWriteFunc, f->getSize = inGetSizeFunc, f->setSize = inSetSizeFunc;
    OSStatus e = start_writing(f, inFileType, inFormat);
    if (e) {
        dispose(f);
        *outAudioFile = NULL;
        return e;
    }
    *outAudioFile = f;
    return noErr;
}

OSStatus
AudioFileOpenWithCallbacks(void *inClientData, AudioFile_ReadProc inReadFunc, AudioFile_WriteProc inWriteFunc, AudioFile_GetSizeProc inGetSizeFunc,
                           AudioFile_SetSizeProc inSetSizeFunc, AudioFileTypeID inFileTypeHint, AudioFileID *outAudioFile)
{
    if (!inReadFunc || !inGetSizeFunc || !outAudioFile)
        return kAudio_ParamError;
    AudioFileID f = new_file();
    f->client = inClientData, f->read = inReadFunc, f->write = inWriteFunc, f->getSize = inGetSizeFunc, f->setSize = inSetSizeFunc;
    f->writable = inWriteFunc != NULL;
    OSStatus e = open_parsed(f, inFileTypeHint);
    if (e) {
        dispose(f);
        *outAudioFile = NULL;
        return e;
    }
    *outAudioFile = f;
    return noErr;
}

OSStatus
AudioFileClose(AudioFileID inAudioFile)
{
    if (!inAudioFile)
        return kAudio_ParamError;
    if (inAudioFile->writable && inAudioFile->dirty)
        update_sizes(inAudioFile);
    dispose(inAudioFile);
    return noErr;
}

OSStatus
AudioFileOptimize(AudioFileID inAudioFile)
{
    if (!inAudioFile)
        return kAudio_ParamError;
    if (inAudioFile->writable)
        update_sizes(inAudioFile);
    return noErr;
}

/* --- data --- */

OSStatus
AudioFileReadBytes(AudioFileID inAudioFile, Boolean inUseCache, SInt64 inStartingByte, UInt32 *ioNumBytes, void *outBuffer)
{
    if (!inAudioFile || !ioNumBytes || !outBuffer)
        return kAudio_ParamError;
    if (inStartingByte < 0)
        return kAudioFileInvalidPacketOffsetError;
    if (inStartingByte >= inAudioFile->dataSize) {
        *ioNumBytes = 0;
        return kAudioFileEndOfFileError;
    }
    UInt32 want = *ioNumBytes;
    if ((SInt64)want > inAudioFile->dataSize - inStartingByte)
        want = (UInt32)(inAudioFile->dataSize - inStartingByte);
    UInt32 asked = *ioNumBytes, got = 0;
    OSStatus e = raw_read(inAudioFile, inAudioFile->dataOffset + inStartingByte, want, outBuffer, &got);
    *ioNumBytes = got;
    if (e)
        return e;
    return got < asked ? kAudioFileEndOfFileError : noErr;
}

OSStatus
AudioFileWriteBytes(AudioFileID inAudioFile, Boolean inUseCache, SInt64 inStartingByte, UInt32 *ioNumBytes, const void *inBuffer)
{
    if (!inAudioFile || !ioNumBytes || !inBuffer)
        return kAudio_ParamError;
    if (!inAudioFile->writable)
        return kAudioFilePermissionsError;
    if (inStartingByte < 0 || inStartingByte > inAudioFile->dataSize)
        return kAudioFileInvalidPacketOffsetError;
    OSStatus e = raw_write(inAudioFile, inAudioFile->dataOffset + inStartingByte, *ioNumBytes, inBuffer);
    if (e) {
        *ioNumBytes = 0;
        return e;
    }
    if (inStartingByte + *ioNumBytes > inAudioFile->dataSize)
        inAudioFile->dataSize = inStartingByte + *ioNumBytes;
    /* (the header's sizes are put in when the file is closed or optimized, as Apple's are) */
    inAudioFile->dirty = true;
    return noErr;
}

static UInt32
constant_packet_size(AudioFileID f)
{
    return f->format.mBytesPerPacket;
}

static SInt64
packet_count(AudioFileID f)
{
    UInt32 b = constant_packet_size(f);
    return b ? f->dataSize / b : f->packetCount;
}

OSStatus
AudioFileReadPacketData(AudioFileID inAudioFile, Boolean inUseCache, UInt32 *ioNumBytes, AudioStreamPacketDescription *outPacketDescriptions,
                        SInt64 inStartingPacket, UInt32 *ioNumPackets, void *outBuffer)
{
    if (!inAudioFile || !ioNumPackets || !ioNumBytes)
        return kAudio_ParamError;
    AudioFileID f = inAudioFile;
    SInt64 total = packet_count(f);
    if (inStartingPacket < 0)
        return kAudioFileInvalidPacketOffsetError;
    if (inStartingPacket >= total) {
        *ioNumPackets = 0, *ioNumBytes = 0;
        return noErr;
    }
    UInt32 want = *ioNumPackets;
    if (inStartingPacket + want > total)
        want = (UInt32)(total - inStartingPacket);
    UInt32 b = constant_packet_size(f);
    SInt64 start;
    UInt32 bytes = 0, n = 0;
    if (b) {
        n = *ioNumBytes / b < want ? *ioNumBytes / b : want;
        start = inStartingPacket * b;
        bytes = n * b;
    } else {
        start = f->packets[inStartingPacket].mStartOffset;
        while (n < want && bytes + f->packets[inStartingPacket + n].mDataByteSize <= *ioNumBytes) {
            if (outPacketDescriptions) {
                outPacketDescriptions[n] = f->packets[inStartingPacket + n];
                outPacketDescriptions[n].mStartOffset = bytes;
            }
            bytes += f->packets[inStartingPacket + n].mDataByteSize;
            n++;
        }
    }
    if (outBuffer && bytes) {
        UInt32 got = bytes;
        OSStatus e = AudioFileReadBytes(f, inUseCache, start, &got, outBuffer);
        if (e && e != kAudioFileEndOfFileError)
            return e;
    }
    *ioNumPackets = n, *ioNumBytes = bytes;
    return noErr;
}

OSStatus
AudioFileReadPackets(AudioFileID inAudioFile, Boolean inUseCache, UInt32 *outNumBytes, AudioStreamPacketDescription *outPacketDescriptions,
                     SInt64 inStartingPacket, UInt32 *ioNumPackets, void *outBuffer)
{
    if (!inAudioFile || !ioNumPackets)
        return kAudio_ParamError;
    /* (the caller's buffer is taken to hold the packets asked for, at their largest) */
    UInt32 b = constant_packet_size(inAudioFile);
    UInt32 room = (b ? b : (inAudioFile->maxPacketSize ? inAudioFile->maxPacketSize : 1)) * *ioNumPackets;
    OSStatus e = AudioFileReadPacketData(inAudioFile, inUseCache, &room, outPacketDescriptions, inStartingPacket, ioNumPackets, outBuffer);
    if (outNumBytes)
        *outNumBytes = room;
    return e;
}

OSStatus
AudioFileWritePackets(AudioFileID inAudioFile, Boolean inUseCache, UInt32 inNumBytes, const AudioStreamPacketDescription *inPacketDescriptions,
                      SInt64 inStartingPacket, UInt32 *ioNumPackets, const void *inBuffer)
{
    if (!inAudioFile || !ioNumPackets || !inBuffer)
        return kAudio_ParamError;
    AudioFileID f = inAudioFile;
    UInt32 b = constant_packet_size(f);
    if (!b)
        return kAudioFileOperationNotSupportedError;
    UInt32 bytes = *ioNumPackets * b;
    if (bytes > inNumBytes)
        bytes = inNumBytes / b * b;
    OSStatus e = AudioFileWriteBytes(f, inUseCache, inStartingPacket * b, &bytes, inBuffer);
    *ioNumPackets = e ? 0 : bytes / b;
    return e;
}

/* --- user data (not kept in the files Finch writes yet) --- */

OSStatus
AudioFileCountUserData(AudioFileID inAudioFile, UInt32 inUserDataID, UInt32 *outNumberItems)
{
    if (!inAudioFile || !outNumberItems)
        return kAudio_ParamError;
    *outNumberItems = 0;
    return noErr;
}

OSStatus
AudioFileGetUserDataSize(AudioFileID inAudioFile, UInt32 inUserDataID, UInt32 inIndex, UInt32 *outUserDataSize)
{
    return inAudioFile ? kAudioFileInvalidChunkError : kAudio_ParamError;
}

OSStatus
AudioFileGetUserDataSize64(AudioFileID inAudioFile, UInt32 inUserDataID, UInt32 inIndex, UInt64 *outUserDataSize)
{
    return inAudioFile ? kAudioFileInvalidChunkError : kAudio_ParamError;
}

OSStatus
AudioFileGetUserData(AudioFileID inAudioFile, UInt32 inUserDataID, UInt32 inIndex, UInt32 *ioUserDataSize, void *outUserData)
{
    return inAudioFile ? kAudioFileInvalidChunkError : kAudio_ParamError;
}

OSStatus
AudioFileGetUserDataAtOffset(AudioFileID inAudioFile, UInt32 inUserDataID, UInt32 inIndex, SInt64 inOffset, UInt32 *ioUserDataSize, void *outUserData)
{
    return inAudioFile ? kAudioFileInvalidChunkError : kAudio_ParamError;
}

OSStatus
AudioFileSetUserData(AudioFileID inAudioFile, UInt32 inUserDataID, UInt32 inIndex, UInt32 inUserDataSize, const void *inUserData)
{
    return inAudioFile ? kAudioFileOperationNotSupportedError : kAudio_ParamError;
}

OSStatus
AudioFileRemoveUserData(AudioFileID inAudioFile, UInt32 inUserDataID, UInt32 inIndex)
{
    return inAudioFile ? kAudioFileInvalidChunkError : kAudio_ParamError;
}

/* --- properties --- */

static OSStatus
give(void *out, UInt32 *size, const void *value, UInt32 valueSize)
{
    if (out) {
        if (*size < valueSize)
            return kAudioFileBadPropertySizeError;
        memcpy(out, value, valueSize);
    }
    *size = valueSize;
    return noErr;
}

static OSStatus
property(AudioFileID f, AudioFilePropertyID p, UInt32 *size, void *out, UInt32 *writable)
{
    if (writable)
        *writable = 0;
    switch (p) {
    case kAudioFilePropertyFileFormat:
        return give(out, size, &f->type, sizeof f->type);
    case kAudioFilePropertyDataFormat:
        if (writable)
            *writable = f->writable && !f->dataSize;
        return give(out, size, &f->format, sizeof f->format);
    case kAudioFilePropertyAudioDataByteCount: {
        UInt64 v = (UInt64)f->dataSize;
        return give(out, size, &v, sizeof v);
    }
    case kAudioFilePropertyAudioDataPacketCount: {
        UInt64 v = (UInt64)packet_count(f);
        return give(out, size, &v, sizeof v);
    }
    case kAudioFilePropertyMaximumPacketSize:
    case kAudioFilePropertyPacketSizeUpperBound: {
        UInt32 v = f->format.mBytesPerPacket ? f->format.mBytesPerPacket : f->maxPacketSize;
        return give(out, size, &v, sizeof v);
    }
    case kAudioFilePropertyDataOffset: {
        SInt64 v = f->dataOffset;
        return give(out, size, &v, sizeof v);
    }
    case kAudioFilePropertyIsOptimized: {
        UInt32 v = 1;
        return give(out, size, &v, sizeof v);
    }
    case kAudioFilePropertyDeferSizeUpdates: {
        UInt32 v = f->deferSizes;
        if (writable)
            *writable = 1;
        return give(out, size, &v, sizeof v);
    }
    case kAudioFilePropertyMagicCookieData:
        if (writable)
            *writable = f->writable && f->type == kAudioFileCAFType;
        if (!f->cookie)
            return kAudioFileUnsupportedPropertyError;
        return give(out, size, CFDataGetBytePtr(f->cookie), (UInt32)CFDataGetLength(f->cookie));
    case kAudioFilePropertyChannelLayout:
        if (writable)
            *writable = f->writable;
        if (!f->layout)
            return kAudioFileBadPropertySizeError; /* (what Apple's answers for a file without one) */
        return give(out, size, f->layout, f->layoutSize);
    case kAudioFilePropertyPacketTableInfo:
        if (f->format.mBytesPerPacket)
            return kAudioFileUnsupportedPropertyError;
        return give(out, size, &f->packetInfo, sizeof f->packetInfo);
    case kAudioFilePropertyEstimatedDuration: {
        Float64 frames = f->format.mBytesPerPacket ? (Float64)(f->dataSize / f->format.mBytesPerPacket) * f->format.mFramesPerPacket
                                                   : (Float64)f->packetCount * f->format.mFramesPerPacket;
        Float64 v = f->format.mSampleRate > 0 ? frames / f->format.mSampleRate : 0;
        return give(out, size, &v, sizeof v);
    }
    case kAudioFilePropertyBitRate: {
        UInt32 v = (UInt32)(f->format.mSampleRate * f->format.mBytesPerFrame * 8);
        return give(out, size, &v, sizeof v);
    }
    case kAudioFilePropertySourceBitDepth: {
        SInt32 v = (SInt32)f->format.mBitsPerChannel;
        if (is_float(&f->format))
            v = -v;
        return give(out, size, &v, sizeof v);
    }
    case kAudioFilePropertyFormatList: {
        AudioFormatListItem item = {f->format, f->layout ? f->layout->mChannelLayoutTag
                                               : f->format.mChannelsPerFrame == 1 ? kAudioChannelLayoutTag_Mono
                                               : f->format.mChannelsPerFrame == 2 ? kAudioChannelLayoutTag_Stereo
                                                                                  : (kAudioChannelLayoutTag_Unknown | f->format.mChannelsPerFrame)};
        return give(out, size, &item, sizeof item);
    }
    case kAudioFilePropertyInfoDictionary: {
        if (!out) {
            *size = sizeof(CFDictionaryRef);
            return noErr;
        }
        if (*size < sizeof(CFDictionaryRef))
            return kAudioFileBadPropertySizeError;
        CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        Float64 seconds = 0;
        UInt32 s = sizeof seconds;
        property(f, kAudioFilePropertyEstimatedDuration, &s, &seconds, NULL);
        CFStringRef dur = CFStringCreateWithFormat(NULL, NULL, CFSTR("%.3f"), seconds);
        CFDictionarySetValue(d, CFSTR(kAFInfoDictionary_ApproximateDurationInSeconds), dur);
        CFRelease(dur);
        *(CFDictionaryRef *)out = d;
        *size = sizeof(CFDictionaryRef);
        return noErr;
    }
    case kAudioFilePropertyDataFormatName: {
        if (!out) {
            *size = sizeof(CFStringRef);
            return noErr;
        }
        CFStringRef n = NULL;
        UInt32 s = sizeof n;
        OSStatus e = AudioFormatGetProperty(kAudioFormatProperty_FormatName, sizeof f->format, &f->format, &s, &n);
        if (e)
            return e;
        *(CFStringRef *)out = n;
        *size = sizeof n;
        return noErr;
    }
    case kAudioFilePropertyChunkIDs: {
        UInt32 ids[4], n = 0;
        switch (f->type) {
        case kAudioFileWAVEType: ids[n++] = 'fmt ', ids[n++] = 'data'; break;
        case kAudioFileAIFFType:
        case kAudioFileAIFCType: ids[n++] = 'COMM', ids[n++] = 'SSND'; break;
        case kAudioFileCAFType: ids[n++] = 'desc', ids[n++] = 'data'; break;
        }
        return give(out, size, ids, n * 4);
    }
    }
    return kAudioFileUnsupportedPropertyError;
}

OSStatus
AudioFileGetPropertyInfo(AudioFileID inAudioFile, AudioFilePropertyID inPropertyID, UInt32 *outDataSize, UInt32 *isWritable)
{
    if (!inAudioFile)
        return kAudio_ParamError;
    UInt32 size = 0;
    OSStatus e = property(inAudioFile, inPropertyID, &size, NULL, isWritable);
    if (outDataSize)
        *outDataSize = size;
    return e;
}

OSStatus
AudioFileGetProperty(AudioFileID inAudioFile, AudioFilePropertyID inPropertyID, UInt32 *ioDataSize, void *outPropertyData)
{
    if (!inAudioFile || !ioDataSize || !outPropertyData)
        return kAudio_ParamError;
    switch (inPropertyID) {
    case kAudioFilePropertyPacketToFrame:
    case kAudioFilePropertyFrameToPacket:
    case kAudioFilePropertyPacketToByte:
    case kAudioFilePropertyByteToPacket: {
        UInt32 fpp = inAudioFile->format.mFramesPerPacket ? inAudioFile->format.mFramesPerPacket : 1, bpp = inAudioFile->format.mBytesPerPacket;
        if (inPropertyID == kAudioFilePropertyPacketToFrame || inPropertyID == kAudioFilePropertyFrameToPacket) {
            if (*ioDataSize < sizeof(AudioFramePacketTranslation))
                return kAudioFileBadPropertySizeError;
            AudioFramePacketTranslation *t = outPropertyData;
            if (inPropertyID == kAudioFilePropertyPacketToFrame)
                t->mFrame = t->mPacket * fpp;
            else {
                t->mPacket = t->mFrame / fpp;
                t->mFrameOffsetInPacket = (UInt32)(t->mFrame % fpp);
            }
            return noErr;
        }
        if (*ioDataSize < sizeof(AudioBytePacketTranslation))
            return kAudioFileBadPropertySizeError;
        AudioBytePacketTranslation *t = outPropertyData;
        if (!bpp)
            return kAudioFileOperationNotSupportedError;
        if (inPropertyID == kAudioFilePropertyPacketToByte) {
            t->mByte = t->mPacket * bpp;
            t->mFlags = 0;
        } else {
            t->mPacket = t->mByte / bpp;
            t->mByteOffsetInPacket = (UInt32)(t->mByte % bpp);
            t->mFlags = 0;
        }
        return noErr;
    }
    }
    return property(inAudioFile, inPropertyID, ioDataSize, outPropertyData, NULL);
}

OSStatus
AudioFileSetProperty(AudioFileID inAudioFile, AudioFilePropertyID inPropertyID, UInt32 inDataSize, const void *inPropertyData)
{
    if (!inAudioFile || !inPropertyData)
        return kAudio_ParamError;
    AudioFileID f = inAudioFile;
    switch (inPropertyID) {
    case kAudioFilePropertyDeferSizeUpdates:
        if (inDataSize < 4)
            return kAudioFileBadPropertySizeError;
        f->deferSizes = *(const UInt32 *)inPropertyData != 0;
        if (!f->deferSizes && f->dirty)
            update_sizes(f);
        return noErr;
    case kAudioFilePropertyChannelLayout: {
        if (!f->writable)
            return kAudioFilePermissionsError;
        if (inDataSize < offsetof(AudioChannelLayout, mChannelDescriptions))
            return kAudioFileBadPropertySizeError;
        free(f->layout);
        f->layout = malloc(inDataSize < sizeof(AudioChannelLayout) ? sizeof(AudioChannelLayout) : inDataSize);
        memset(f->layout, 0, sizeof(AudioChannelLayout));
        memcpy(f->layout, inPropertyData, inDataSize);
        f->layoutSize = inDataSize;
        return f->dataSize ? noErr : rewrite_header(f);
    }
    case kAudioFilePropertyMagicCookieData:
        if (!f->writable)
            return kAudioFilePermissionsError;
        if (f->cookie)
            CFRelease(f->cookie);
        f->cookie = CFDataCreate(NULL, inPropertyData, inDataSize);
        return f->dataSize ? noErr : rewrite_header(f);
    case kAudioFilePropertyDataFormat:
        if (!f->writable || f->dataSize)
            return kAudioFileOperationNotSupportedError;
        if (inDataSize < sizeof(AudioStreamBasicDescription))
            return kAudioFileBadPropertySizeError;
        if (!type_takes(f->type, inPropertyData))
            return kAudioFileUnsupportedDataFormatError;
        f->format = *(const AudioStreamBasicDescription *)inPropertyData;
        return rewrite_header(f);
    }
    return kAudioFileUnsupportedPropertyError;
}
