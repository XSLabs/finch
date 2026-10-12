/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Audio format descriptions to and from sound descriptions ('stsd' audio sample
 * entries), Finch's, laid out as Apple's (macOS 26.4, sounddesc-test.c):
 *   - QuickTime version 0 and 1 ('twos', 'sowt', 'raw ', 'NONE', 'in24', 'in32',
 *     'fl32', 'fl64', 'ulaw', 'alaw', compressed codecs), with a 'wave' atom holding
 *     'frma', 'enda' (byte order) and 'esds'; version 2 ('lpcm' and compressed codecs);
 *     'chan' channel layouts.
 *   - ISO: 'ipcm' and 'fpcm' with 'pcmC' and 'chnl', 'mp4a' with 'esds' (the cookie is
 *     the descriptor after its version and flags; AAC's object type, rate and channels
 *     come from its AudioSpecificConfig).
 *   - Written: QuickTime as version 1 (version 2 for the V2 flavour), with the data
 *     reference index 0xffff; ISO as version 0. A description too short to read is
 *     kCMBlockBufferBadOffsetParameterErr, as Apple's.
 */
#include "CMInternal.h"
#include <CoreAudioTypes/CoreAudioTypes.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    UInt8 *bytes;
    size_t size, capacity;
} Out;

static void
put(Out *o, const void *p, size_t n)
{
    if (o->size + n > o->capacity) {
        o->capacity = (o->size + n) * 2 + 64;
        o->bytes = realloc(o->bytes, o->capacity);
    }
    memcpy(o->bytes + o->size, p, n);
    o->size += n;
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

static void
patch32(Out *o, size_t at, uint32_t v)
{
    UInt8 b[4] = {(UInt8)(v >> 24), (UInt8)(v >> 16), (UInt8)(v >> 8), (UInt8)v};
    memcpy(o->bytes + at, b, 4);
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

static uint64_t
get64(const UInt8 *p)
{
    return (uint64_t)get32(p) << 32 | get32(p + 4);
}

static bool
iso_flavor(CFStringRef flavor)
{
    return flavor && (CFEqual(flavor, kCMSoundDescriptionFlavor_ISOFamily) || CFEqual(flavor, kCMSoundDescriptionFlavor_3GPFamily));
}

static bool
v2_flavor(CFStringRef flavor)
{
    return flavor && CFEqual(flavor, kCMSoundDescriptionFlavor_QuickTimeMovieV2);
}

#pragma mark - Reading

/* AAC and its relatives: the format, rate and channels an AudioSpecificConfig gives. */
static void
read_audio_specific_config(const UInt8 *p, size_t n, AudioStreamBasicDescription *a, uint32_t *channelConfig)
{
    if (n < 2)
        return;
    uint32_t bits = get16(p);
    uint32_t object = bits >> 11, freqIndex = (bits >> 7) & 0xF, channels = (bits >> 3) & 0xF;
    static const double rates[] = {96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350};
    if (freqIndex < 13)
        a->mSampleRate = rates[freqIndex];
    switch (object) {
    case 1:
    case 2: a->mFormatID = kAudioFormatMPEG4AAC; break;
    case 5: a->mFormatID = kAudioFormatMPEG4AAC_HE; break;
    case 23: a->mFormatID = kAudioFormatMPEG4AAC_LD; break;
    case 29: a->mFormatID = kAudioFormatMPEG4AAC_HE_V2; break;
    case 39: a->mFormatID = kAudioFormatMPEG4AAC_ELD; break;
    default: break;
    }
    if (channels)
        a->mChannelsPerFrame = channels;
    *channelConfig = channels;
    a->mFramesPerPacket = (bits & 0x4) ? 960 : 1024;
}

/* An MPEG-4 descriptor's length (one to four bytes, seven bits each). */
static size_t
descriptor_length(const UInt8 **p, const UInt8 *end)
{
    size_t len = 0;
    for (int i = 0; i < 4 && *p < end; i++) {
        UInt8 b = *(*p)++;
        len = len << 7 | (b & 0x7F);
        if (!(b & 0x80))
            break;
    }
    return len;
}

/* The decoder-specific info inside an 'esds' payload (after its version and flags). */
static bool
esds_config(const UInt8 *p, size_t n, const UInt8 **config, size_t *configLen)
{
    const UInt8 *end = p + n;
    if (p >= end || *p++ != 0x03)
        return false;
    descriptor_length(&p, end);
    if (p + 3 > end)
        return false;
    UInt8 flags = p[2];
    p += 3;
    if (flags & 0x80)
        p += 2;
    if (flags & 0x40 && p < end)
        p += 1 + *p;
    if (flags & 0x20)
        p += 2;
    if (p >= end || *p++ != 0x04)
        return false;
    descriptor_length(&p, end);
    p += 13;
    if (p >= end || *p++ != 0x05)
        return false;
    size_t len = descriptor_length(&p, end);
    if (p + len > end)
        return false;
    *config = p;
    *configLen = len;
    return true;
}

static AudioChannelLayoutTag
layout_for_channels(uint32_t config)
{
    switch (config) {
    case 1: return kAudioChannelLayoutTag_Mono;
    case 2: return kAudioChannelLayoutTag_Stereo;
    case 3: return kAudioChannelLayoutTag_MPEG_3_0_B;
    case 4: return kAudioChannelLayoutTag_MPEG_4_0_B;
    case 5: return kAudioChannelLayoutTag_MPEG_5_0_D;
    case 6: return kAudioChannelLayoutTag_MPEG_5_1_D;
    case 7: return kAudioChannelLayoutTag_MPEG_7_1_B;
    default: return 0;
    }
}

typedef struct {
    AudioStreamBasicDescription asbd;
    UInt8 *cookie;
    size_t cookieSize;
    AudioChannelLayout *layout;
    size_t layoutSize;
    FourCharCode original; /* 'frma' */
    int littleEndian;      /* 'enda': -1 if absent */
} Parsed;

static void
set_cookie(Parsed *r, const UInt8 *p, size_t n)
{
    free(r->cookie);
    r->cookie = malloc(n ? n : 1);
    memcpy(r->cookie, p, n);
    r->cookieSize = n;
}

static void
set_layout_tag(Parsed *r, AudioChannelLayoutTag tag)
{
    free(r->layout);
    r->layout = calloc(1, sizeof(AudioChannelLayout));
    r->layout->mChannelLayoutTag = tag;
    r->layoutSize = offsetof(AudioChannelLayout, mChannelDescriptions);
}

/* A QuickTime 'chan' body: version and flags, then a big-endian AudioChannelLayout. */
static void
read_chan(Parsed *r, const UInt8 *p, size_t n)
{
    if (n < 16)
        return;
    p += 4, n -= 4;
    uint32_t count = get32(p + 8);
    size_t size = offsetof(AudioChannelLayout, mChannelDescriptions) + count * sizeof(AudioChannelDescription);
    if (12 + count * 20 > n)
        return;
    free(r->layout);
    r->layout = calloc(1, size);
    r->layout->mChannelLayoutTag = get32(p);
    r->layout->mChannelBitmap = get32(p + 4);
    r->layout->mNumberChannelDescriptions = count;
    for (uint32_t i = 0; i < count; i++) {
        const UInt8 *d = p + 12 + i * 20;
        AudioChannelDescription *cd = &r->layout->mChannelDescriptions[i];
        cd->mChannelLabel = get32(d);
        cd->mChannelFlags = get32(d + 4);
        for (int k = 0; k < 3; k++) {
            uint32_t f = get32(d + 8 + k * 4);
            memcpy(&cd->mCoordinates[k], &f, 4);
        }
    }
    r->layoutSize = size;
}

static void read_atoms(Parsed *r, const UInt8 *p, size_t n, bool iso, bool inWave);

static void
read_esds(Parsed *r, const UInt8 *body, size_t len)
{
    if (len < 4)
        return;
    set_cookie(r, body + 4, len - 4);
    const UInt8 *config;
    size_t configLen;
    uint32_t channelConfig = 0;
    if (esds_config(body + 4, len - 4, &config, &configLen)) {
        read_audio_specific_config(config, configLen, &r->asbd, &channelConfig);
        AudioChannelLayoutTag tag = layout_for_channels(channelConfig);
        if (tag)
            set_layout_tag(r, tag);
    }
}

static void
read_atoms(Parsed *r, const UInt8 *p, size_t n, bool iso, bool inWave)
{
    for (size_t at = 0; at + 8 <= n;) {
        size_t size = get32(p + at);
        if (size < 8 || at + size > n)
            break;
        uint32_t type = get32(p + at + 4);
        const UInt8 *body = p + at + 8;
        size_t len = size - 8;
        if (type == 'wave' && !iso && !inWave)
            read_atoms(r, body, len, iso, true);
        else if (type == 'frma' && len >= 4)
            r->original = get32(body);
        else if (type == 'enda' && len >= 2)
            r->littleEndian = get16(body) != 0;
        else if (type == 'esds' && (iso || inWave))
            read_esds(r, body, len);
        else if (type == 'chan' && !iso)
            read_chan(r, body, len);
        else if (type == 'chnl' && iso && len >= 8) {
            /* (a defined layout: stereo's code is 2, mono's 1) */
            uint32_t defined = body[6];
            AudioChannelLayoutTag tag = defined == 2 ? kAudioChannelLayoutTag_Stereo : defined == 1 ? kAudioChannelLayoutTag_Mono : 0;
            if (tag)
                set_layout_tag(r, tag);
        } else if (type == 'pcmC' && iso && len >= 6) {
            bool le = body[4] & 1;
            uint32_t bits = body[5];
            r->asbd.mBitsPerChannel = bits;
            r->asbd.mFormatFlags = (r->asbd.mFormatFlags & kAudioFormatFlagIsFloat) | kAudioFormatFlagIsPacked |
                                   (r->asbd.mFormatFlags & kAudioFormatFlagIsFloat ? 0 : kAudioFormatFlagIsSignedInteger) |
                                   (le ? 0 : kAudioFormatFlagIsBigEndian);
            r->asbd.mBytesPerFrame = r->asbd.mChannelsPerFrame * ((bits + 7) / 8);
            r->asbd.mBytesPerPacket = r->asbd.mBytesPerFrame;
        }
        at += size;
    }
}

static bool
is_pcm_codec(uint32_t c)
{
    return c == 'twos' || c == 'sowt' || c == 'raw ' || c == 'NONE' || c == 'in24' || c == 'in32' || c == 'fl32' || c == 'fl64' ||
           c == 'lpcm';
}

OSStatus
CMAudioFormatDescriptionCreateFromBigEndianSoundDescriptionData(CFAllocatorRef allocator, const uint8_t *soundDescriptionData,
                                                                size_t size, CFStringRef flavor,
                                                                CMAudioFormatDescriptionRef *formatDescriptionOut)
{
    if (!soundDescriptionData || !formatDescriptionOut)
        return kCMFormatDescriptionBridgeError_InvalidParameter;
    *formatDescriptionOut = NULL;
    if (size < 36)
        return kCMBlockBufferBadOffsetParameterErr;
    const UInt8 *b = soundDescriptionData;
    size_t total = get32(b);
    if (total < 36 || total > size)
        return kCMFormatDescriptionBridgeError_InvalidSerializedSampleDescription;
    bool iso = iso_flavor(flavor);
    uint32_t codec = get32(b + 4), version = get16(b + 16);
    uint32_t channels = get16(b + 24), sampleSize = get16(b + 26);
    double rate = (double)(get32(b + 32) >> 16);
    Parsed r = {0};
    r.littleEndian = -1;
    AudioStreamBasicDescription *a = &r.asbd;
    a->mSampleRate = rate;
    a->mChannelsPerFrame = channels;
    size_t ext = 36;
    if (iso) {
        version = 0;
        if (codec == 'ipcm' || codec == 'fpcm') {
            a->mFormatID = kAudioFormatLinearPCM;
            a->mFramesPerPacket = 1;
            if (codec == 'fpcm')
                a->mFormatFlags = kAudioFormatFlagIsFloat;
        } else {
            a->mFormatID = codec;
            if (codec == 'mp4a')
                a->mFramesPerPacket = 1024;
        }
    } else if (version == 2) {
        if (total < 72)
            return kCMFormatDescriptionBridgeError_InvalidSerializedSampleDescription;
        uint64_t rbits = get64(b + 40);
        memcpy(&rate, &rbits, 8);
        a->mSampleRate = rate;
        a->mChannelsPerFrame = get32(b + 48);
        uint32_t bits = get32(b + 56), flags = get32(b + 60), bpp = get32(b + 64), fpp = get32(b + 68);
        a->mFormatID = codec == 'lpcm' ? kAudioFormatLinearPCM : codec;
        a->mBitsPerChannel = bits;
        a->mFormatFlags = flags;
        a->mBytesPerPacket = bpp;
        a->mFramesPerPacket = fpp;
        a->mBytesPerFrame = fpp == 1 ? bpp : 0;
        ext = 72;
    } else {
        uint32_t spp = 0, bpp = 0, bpf = 0, bps = 0;
        if (version == 1) {
            if (total < 52)
                return kCMFormatDescriptionBridgeError_InvalidSerializedSampleDescription;
            spp = get32(b + 36), bpp = get32(b + 40), bpf = get32(b + 44), bps = get32(b + 48);
            ext = 52;
        }
        (void)bpp;
        if (is_pcm_codec(codec)) {
            a->mFormatID = kAudioFormatLinearPCM;
            uint32_t bits = version == 1 && bps && codec != 'twos' && codec != 'sowt' && codec != 'raw ' && codec != 'NONE'
                                ? (bpf && channels ? bpf / channels * 8 : bps * 8)
                                : sampleSize;
            if (codec == 'in24')
                bits = 24;
            else if (codec == 'in32' || codec == 'fl32')
                bits = 32;
            else if (codec == 'fl64')
                bits = 64;
            a->mBitsPerChannel = bits;
            a->mFormatFlags = kAudioFormatFlagIsPacked;
            if (codec == 'fl32' || codec == 'fl64')
                a->mFormatFlags |= kAudioFormatFlagIsFloat | kAudioFormatFlagIsBigEndian;
            else if (codec == 'sowt')
                a->mFormatFlags |= kAudioFormatFlagIsSignedInteger;
            else if (codec == 'raw ')
                a->mFormatFlags |= kAudioFormatFlagIsBigEndian;
            else
                a->mFormatFlags |= kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsBigEndian;
            a->mFramesPerPacket = 1;
            a->mBytesPerFrame = channels * ((bits + 7) / 8);
            a->mBytesPerPacket = a->mBytesPerFrame;
        } else if (codec == 'ulaw' || codec == 'alaw') {
            a->mFormatID = codec;
            a->mFramesPerPacket = 1;
            a->mBitsPerChannel = 8;
            a->mBytesPerFrame = channels;
            a->mBytesPerPacket = channels;
        } else {
            a->mFormatID = codec;
            if (version == 1) {
                a->mFramesPerPacket = spp;
                a->mBytesPerPacket = bpf;
            }
            if (codec == 'mp4a') {
                a->mFormatID = kAudioFormatMPEG4AAC;
                a->mFramesPerPacket = 1024;
                a->mBytesPerPacket = 0;
            }
        }
    }
    if (ext < total)
        read_atoms(&r, b + ext, total - ext, iso, false);
    /* the byte order 'enda' gives (QuickTime PCM in a 'wave') */
    if (r.littleEndian >= 0 && a->mFormatID == kAudioFormatLinearPCM && a->mBitsPerChannel > 8) {
        if (r.littleEndian)
            a->mFormatFlags &= ~(AudioFormatFlags)kAudioFormatFlagIsBigEndian;
        else
            a->mFormatFlags |= kAudioFormatFlagIsBigEndian;
    }
    if (a->mFormatID == 'mp4a')
        a->mFormatID = kAudioFormatMPEG4AAC;
    /* (the description as it was, written out again as it was in the same flavour) */
    CFMutableDictionaryRef extensions = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDataRef verbatim = CFDataCreate(NULL, b, (CFIndex)total);
    CFDictionarySetValue(extensions, iso ? kCMFormatDescriptionExtension_VerbatimISOSampleEntry : kCMFormatDescriptionExtension_VerbatimSampleDescription,
                         verbatim);
    CFRelease(verbatim);
    OSStatus err = CMAudioFormatDescriptionCreate(allocator, a, r.layoutSize, r.layout, r.cookieSize, r.cookie, extensions,
                                                  formatDescriptionOut);
    CFRelease(extensions);
    free(r.cookie);
    free(r.layout);
    return err;
}

OSStatus
CMAudioFormatDescriptionCreateFromBigEndianSoundDescriptionBlockBuffer(CFAllocatorRef allocator,
                                                                       CMBlockBufferRef soundDescriptionBlockBuffer,
                                                                       CFStringRef flavor,
                                                                       CMAudioFormatDescriptionRef *formatDescriptionOut)
{
    if (!soundDescriptionBlockBuffer || !formatDescriptionOut)
        return kCMFormatDescriptionBridgeError_InvalidParameter;
    size_t n = CMBlockBufferGetDataLength(soundDescriptionBlockBuffer);
    uint8_t *bytes = malloc(n ? n : 1);
    OSStatus err = CMBlockBufferCopyDataBytes(soundDescriptionBlockBuffer, 0, n, bytes);
    if (!err)
        err = CMAudioFormatDescriptionCreateFromBigEndianSoundDescriptionData(allocator, bytes, n, flavor, formatDescriptionOut);
    free(bytes);
    return err;
}

Boolean
CMDoesBigEndianSoundDescriptionRequireLegacyCBRSampleTableLayout(CMBlockBufferRef soundDescriptionBlockBuffer, CFStringRef flavor)
{
    if (!soundDescriptionBlockBuffer || iso_flavor(flavor))
        return false;
    UInt8 head[18];
    if (CMBlockBufferCopyDataBytes(soundDescriptionBlockBuffer, 0, sizeof head, head))
        return false;
    uint32_t codec = get32(head + 4), version = get16(head + 16);
    return version < 2 && (is_pcm_codec(codec) || codec == 'ulaw' || codec == 'alaw');
}

#pragma mark - Writing

static void
put_box(Out *o, uint32_t type, const void *body, size_t n)
{
    put32(o, (uint32_t)(8 + n));
    put32(o, type);
    put(o, body, n);
}

/* The QuickTime codec for linear PCM, and whether it needs a 'wave' with 'enda'. */
static uint32_t
quicktime_pcm_codec(const AudioStreamBasicDescription *a, bool *wave)
{
    bool fl = a->mFormatFlags & kAudioFormatFlagIsFloat, be = a->mFormatFlags & kAudioFormatFlagIsBigEndian;
    bool sig = a->mFormatFlags & kAudioFormatFlagIsSignedInteger;
    uint32_t bits = a->mBitsPerChannel;
    *wave = false;
    if (fl) {
        *wave = !be;
        return bits == 64 ? 'fl64' : 'fl32';
    }
    if (bits <= 8)
        return sig ? 'twos' : 'raw ';
    if (bits == 16)
        return be ? 'twos' : 'sowt';
    *wave = !be;
    return bits == 24 ? 'in24' : 'in32';
}

static void
put_header(Out *o, uint32_t codec, uint32_t version)
{
    put32(o, 0);
    put32(o, codec);
    put32(o, 0), put16(o, 0), put16(o, 0xFFFF);
    put16(o, version), put16(o, 0), put32(o, 0);
}

static void
put_esds(Out *o, const void *cookie, size_t n)
{
    put32(o, (uint32_t)(12 + n));
    put32(o, 'esds');
    put32(o, 0);
    put(o, cookie, n);
}

OSStatus
CMAudioFormatDescriptionCopyAsBigEndianSoundDescriptionBlockBuffer(CFAllocatorRef allocator,
                                                                   CMAudioFormatDescriptionRef audioFormatDescription,
                                                                   CFStringRef flavor, CMBlockBufferRef *blockBufferOut)
{
    if (!audioFormatDescription || !blockBufferOut)
        return kCMFormatDescriptionBridgeError_InvalidParameter;
    *blockBufferOut = NULL;
    const AudioStreamBasicDescription *a = CMAudioFormatDescriptionGetStreamBasicDescription(audioFormatDescription);
    if (!a)
        return kCMFormatDescriptionBridgeError_InvalidFormatDescription;
    size_t cookieSize = 0;
    const void *cookie = CMAudioFormatDescriptionGetMagicCookie(audioFormatDescription, &cookieSize);
    CFDataRef verbatim = CMFormatDescriptionGetExtension(audioFormatDescription,
                                                         iso_flavor(flavor) ? kCMFormatDescriptionExtension_VerbatimISOSampleEntry
                                                                            : kCMFormatDescriptionExtension_VerbatimSampleDescription);
    if (verbatim && CFGetTypeID(verbatim) == CFDataGetTypeID() && !v2_flavor(flavor) && CFDataGetLength(verbatim) >= 36) {
        const UInt8 *v = CFDataGetBytePtr(verbatim);
        /* (QuickTime's verbatim copy serves only a QuickTime request of the same version) */
        if (iso_flavor(flavor) || get16(v + 16) < 2) {
            size_t n = (size_t)CFDataGetLength(verbatim);
            CMBlockBufferRef bb = NULL;
            OSStatus err = CMBlockBufferCreateWithMemoryBlock(allocator, NULL, n, allocator, NULL, 0, n, kCMBlockBufferAssureMemoryNowFlag, &bb);
            if (!err)
                err = CMBlockBufferReplaceDataBytes(v, bb, 0, n);
            if (err) {
                if (bb)
                    CFRelease(bb);
                return err;
            }
            *blockBufferOut = bb;
            return noErr;
        }
    }
    bool pcm = a->mFormatID == kAudioFormatLinearPCM;
    bool aac = a->mFormatID == kAudioFormatMPEG4AAC || a->mFormatID == kAudioFormatMPEG4AAC_HE ||
               a->mFormatID == kAudioFormatMPEG4AAC_HE_V2 || a->mFormatID == kAudioFormatMPEG4AAC_LD ||
               a->mFormatID == kAudioFormatMPEG4AAC_ELD;
    uint32_t rate1616 = (uint32_t)a->mSampleRate << 16;
    Out o = {0};
    if (iso_flavor(flavor)) {
        uint32_t codec;
        if (pcm) {
            if (!(a->mFormatFlags & kAudioFormatFlagIsFloat) && !(a->mFormatFlags & kAudioFormatFlagIsSignedInteger))
                return (OSStatus)'fmt?'; /* kAudioFormatUnsupportedDataFormatError */
            codec = a->mFormatFlags & kAudioFormatFlagIsFloat ? 'fpcm' : 'ipcm';
        } else if (aac) {
            codec = 'mp4a';
        } else {
            return kCMFormatDescriptionBridgeError_IncompatibleFormatDescription;
        }
        put_header(&o, codec, 0);
        put16(&o, a->mChannelsPerFrame), put16(&o, 16);
        put16(&o, 0), put16(&o, 0);
        put32(&o, rate1616);
        if (pcm) {
            UInt8 pcmC[6] = {0, 0, 0, 0, (UInt8)(a->mFormatFlags & kAudioFormatFlagIsBigEndian ? 0 : 1), (UInt8)a->mBitsPerChannel};
            put_box(&o, 'pcmC', pcmC, sizeof pcmC);
            if (a->mChannelsPerFrame == 2) {
                UInt8 chnl[8] = {1, 0, 0, 0, 0x11, 2, 2, 0};
                put_box(&o, 'chnl', chnl, sizeof chnl);
            }
        } else if (cookie && cookieSize) {
            put_esds(&o, cookie, cookieSize);
        }
    } else if (v2_flavor(flavor)) {
        put_header(&o, pcm ? 'lpcm' : (aac ? 'mp4a' : a->mFormatID), 2);
        put16(&o, 3), put16(&o, 16), put16(&o, 0xFFFE), put16(&o, 0);
        put32(&o, 0x10000);
        put32(&o, 72);
        uint64_t r;
        Float64 rate = a->mSampleRate;
        memcpy(&r, &rate, 8);
        put32(&o, (uint32_t)(r >> 32)), put32(&o, (uint32_t)r);
        put32(&o, a->mChannelsPerFrame);
        put32(&o, 0x7F000000);
        put32(&o, a->mBitsPerChannel);
        put32(&o, pcm ? a->mFormatFlags : 0);
        put32(&o, a->mBytesPerPacket);
        put32(&o, a->mFramesPerPacket);
    } else {
        bool wave = false;
        uint32_t codec = pcm ? quicktime_pcm_codec(a, &wave) : (aac ? 'mp4a' : a->mFormatID);
        put_header(&o, codec, 1);
        uint32_t bytesPerSample = pcm ? (a->mBitsPerChannel + 7) / 8 : (codec == 'ulaw' || codec == 'alaw') ? 1 : 2;
        put16(&o, a->mChannelsPerFrame);
        put16(&o, pcm && a->mBitsPerChannel <= 8 ? 8 : (codec == 'ulaw' || codec == 'alaw') ? 8 : 16);
        put16(&o, aac ? 0xFFFE : 0xFFFF), put16(&o, 0);
        put32(&o, rate1616);
        if (aac) {
            put32(&o, a->mFramesPerPacket);
            put32(&o, 1);
            put32(&o, a->mChannelsPerFrame);
            put32(&o, 2);
        } else {
            put32(&o, 1);
            put32(&o, bytesPerSample);
            put32(&o, pcm ? a->mBytesPerFrame : a->mChannelsPerFrame * bytesPerSample);
            put32(&o, bytesPerSample > 2 ? 2 : bytesPerSample);
        }
        if (wave || (aac && cookie && cookieSize)) {
            size_t at = o.size;
            put32(&o, 0);
            put32(&o, 'wave');
            UInt8 frma[4] = {(UInt8)(codec >> 24), (UInt8)(codec >> 16), (UInt8)(codec >> 8), (UInt8)codec};
            put_box(&o, 'frma', frma, 4);
            if (aac) {
                UInt8 zero[4] = {0};
                put_box(&o, 'mp4a', zero, 4);
                put_esds(&o, cookie, cookieSize);
            } else {
                UInt8 enda[2] = {0, 1};
                put_box(&o, 'enda', enda, 2);
            }
            put32(&o, 8), put32(&o, 0);
            patch32(&o, at, (uint32_t)(o.size - at));
        }
    }
    patch32(&o, 0, (uint32_t)o.size);
    CMBlockBufferRef bb = NULL;
    OSStatus err = CMBlockBufferCreateWithMemoryBlock(allocator, NULL, o.size, allocator, NULL, 0, o.size, kCMBlockBufferAssureMemoryNowFlag, &bb);
    if (!err)
        err = CMBlockBufferReplaceDataBytes(o.bytes, bb, 0, o.size);
    free(o.bytes);
    if (err) {
        if (bb)
            CFRelease(bb);
        return err;
    }
    *blockBufferOut = bb;
    return noErr;
}

#pragma mark - Byte order

static void
swap16(uint8_t *p)
{
    uint8_t t = p[0];
    p[0] = p[1], p[1] = t;
}

static void
swap32(uint8_t *p)
{
    uint8_t t = p[0];
    p[0] = p[3], p[3] = t;
    t = p[1];
    p[1] = p[2], p[2] = t;
}

static void
swap64(uint8_t *p)
{
    for (int i = 0; i < 4; i++) {
        uint8_t t = p[i];
        p[i] = p[7 - i], p[7 - i] = t;
    }
}

/* The fixed fields of a description, for its version (read from the big-endian copy). */
static OSStatus
swap_sound_description(uint8_t *d, size_t size, bool toHost)
{
    if (!d || size < 36)
        return kCMFormatDescriptionBridgeError_InvalidParameter;
    uint32_t version;
    if (toHost)
        version = get16(d + 16);
    else
        memcpy(&version, d + 16, 2), version &= 0xFFFF;
    swap32(d), swap32(d + 4);
    swap16(d + 14);
    swap16(d + 16), swap16(d + 18), swap32(d + 20);
    swap16(d + 24), swap16(d + 26), swap16(d + 28), swap16(d + 30);
    swap32(d + 32);
    if (version == 1 && size >= 52)
        for (int i = 0; i < 4; i++)
            swap32(d + 36 + i * 4);
    else if (version == 2 && size >= 72) {
        swap32(d + 36);
        swap64(d + 40);
        for (int i = 0; i < 6; i++)
            swap32(d + 48 + i * 4);
    }
    return noErr;
}

OSStatus
CMSwapBigEndianSoundDescriptionToHost(uint8_t *soundDescriptionData, size_t soundDescriptionSize)
{
    return swap_sound_description(soundDescriptionData, soundDescriptionSize, true);
}

OSStatus
CMSwapHostEndianSoundDescriptionToBig(uint8_t *soundDescriptionData, size_t soundDescriptionSize)
{
    return swap_sound_description(soundDescriptionData, soundDescriptionSize, false);
}
