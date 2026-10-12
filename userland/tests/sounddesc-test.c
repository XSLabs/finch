/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CoreMedia's sound descriptions ('stsd' audio sample entries) to and from audio
 * format descriptions: QuickTime version 0 ('twos', 'sowt', 'raw ', 'ulaw'), version 1
 * ('ima4') and version 2 ('lpcm' float and integer), ISO 'mp4a' with an 'esds' cookie,
 * channel layouts ('chan'), the bytes written for PCM and AAC in each flavour, and
 * swapping to host order. Compared with Apple's.
 */
#include <CoreMedia/CoreMedia.h>
#include <stdio.h>
#include <string.h>

static void
be16(uint8_t **p, uint16_t v)
{
    (*p)[0] = (uint8_t)(v >> 8), (*p)[1] = (uint8_t)v;
    *p += 2;
}

static void
be32(uint8_t **p, uint32_t v)
{
    (*p)[0] = (uint8_t)(v >> 24), (*p)[1] = (uint8_t)(v >> 16), (*p)[2] = (uint8_t)(v >> 8), (*p)[3] = (uint8_t)v;
    *p += 4;
}

static void
be64(uint8_t **p, uint64_t v)
{
    be32(p, (uint32_t)(v >> 32));
    be32(p, (uint32_t)v);
}

static void
fcc(char *out, uint32_t c)
{
    out[0] = (char)(c >> 24), out[1] = (char)(c >> 16), out[2] = (char)(c >> 8), out[3] = (char)c, out[4] = 0;
}

static void
show(const char *label, CMAudioFormatDescriptionRef fd, OSStatus err)
{
    printf("%s: err %d", label, (int)err);
    if (!fd) {
        printf("\n");
        return;
    }
    const AudioStreamBasicDescription *a = CMAudioFormatDescriptionGetStreamBasicDescription(fd);
    char id[5], sub[5];
    fcc(id, a->mFormatID);
    fcc(sub, CMFormatDescriptionGetMediaSubType(fd));
    printf(" subtype %s format %s %.0f Hz flags %u bytes/packet %u frames/packet %u bytes/frame %u ch %u bits %u", sub, id,
        a->mSampleRate, a->mFormatFlags, a->mBytesPerPacket, a->mFramesPerPacket, a->mBytesPerFrame, a->mChannelsPerFrame,
        a->mBitsPerChannel);
    size_t cookie = 0, layout = 0;
    CMAudioFormatDescriptionGetMagicCookie(fd, &cookie);
    const AudioChannelLayout *l = CMAudioFormatDescriptionGetChannelLayout(fd, &layout);
    printf(" cookie %zu layout %zu", cookie, layout);
    if (l)
        printf(" tag %u", l->mChannelLayoutTag);
    printf("\n");
}

static void
dump(const char *label, CMBlockBufferRef bb, OSStatus err)
{
    printf("%s: err %d", label, (int)err);
    if (!bb) {
        printf("\n");
        return;
    }
    size_t n = CMBlockBufferGetDataLength(bb);
    uint8_t buf[512];
    CMBlockBufferCopyDataBytes(bb, 0, n < sizeof buf ? n : sizeof buf, buf);
    printf(" %zu bytes:", n);
    for (size_t i = 0; i < n && i < sizeof buf; i++)
        printf("%s%02x", i % 4 ? "" : " ", buf[i]);
    printf("\n");
}

/* A version 0 or 1 description of codec. */
static size_t
v01(uint8_t *b, uint32_t codec, int version, int channels, int bits, int rate, const uint32_t *v1fields, const uint8_t *ext,
    size_t extLen)
{
    uint8_t *p = b;
    be32(&p, 0);
    be32(&p, codec);
    memset(p, 0, 6), p += 6;
    be16(&p, 1);
    be16(&p, (uint16_t)version), be16(&p, 0), be32(&p, 0);
    be16(&p, (uint16_t)channels), be16(&p, (uint16_t)bits);
    be16(&p, version == 1 ? 0xFFFE : 0), be16(&p, 0);
    be32(&p, (uint32_t)rate << 16);
    if (version == 1)
        for (int i = 0; i < 4; i++)
            be32(&p, v1fields[i]);
    memcpy(p, ext, extLen), p += extLen;
    size_t n = (size_t)(p - b);
    uint8_t *q = b;
    be32(&q, (uint32_t)n);
    return n;
}

static size_t
v2(uint8_t *b, uint32_t codec, double rate, int channels, int bits, uint32_t flags, int bytesPerPacket, int framesPerPacket,
   const uint8_t *ext, size_t extLen)
{
    uint8_t *p = b;
    be32(&p, 0);
    be32(&p, codec);
    memset(p, 0, 6), p += 6;
    be16(&p, 1);
    be16(&p, 2), be16(&p, 0), be32(&p, 0);
    be16(&p, 3), be16(&p, 16), be16(&p, 0xFFFE), be16(&p, 0);
    be32(&p, 0x10000);
    be32(&p, 72);
    uint64_t r;
    memcpy(&r, &rate, 8);
    be64(&p, r);
    be32(&p, (uint32_t)channels), be32(&p, 0x7F000000), be32(&p, (uint32_t)bits), be32(&p, flags);
    be32(&p, (uint32_t)bytesPerPacket), be32(&p, (uint32_t)framesPerPacket);
    memcpy(p, ext, extLen), p += extLen;
    size_t n = (size_t)(p - b);
    uint8_t *q = b;
    be32(&q, (uint32_t)n);
    return n;
}

int
main(void)
{
    uint8_t b[512];
    CMAudioFormatDescriptionRef fd;
    OSStatus e;
    size_t n;

    struct {
        const char *label;
        uint32_t codec;
        int channels, bits, rate;
    } v0s[] = {
        {"v0 twos 16", 'twos', 2, 16, 44100}, {"v0 twos 8", 'twos', 1, 8, 22050}, {"v0 sowt", 'sowt', 2, 16, 48000},
        {"v0 raw", 'raw ', 1, 8, 11025},      {"v0 ulaw", 'ulaw', 1, 8, 8000},     {"v0 alaw", 'alaw', 2, 8, 8000},
        {"v0 NONE", 'NONE', 2, 16, 32000},    {"v0 in24", 'in24', 2, 24, 48000},   {"v0 fl32", 'fl32', 2, 32, 48000},
    };
    for (size_t i = 0; i < sizeof v0s / sizeof v0s[0]; i++) {
        n = v01(b, v0s[i].codec, 0, v0s[i].channels, v0s[i].bits, v0s[i].rate, NULL, NULL, 0);
        fd = NULL;
        e = CMAudioFormatDescriptionCreateFromBigEndianSoundDescriptionData(NULL, b, n, NULL, &fd);
        show(v0s[i].label, fd, e);
        if (fd)
            CFRelease(fd);
    }
    uint32_t ima[4] = {64, 34, 68, 2};
    n = v01(b, 'ima4', 1, 2, 16, 44100, ima, NULL, 0);
    fd = NULL;
    e = CMAudioFormatDescriptionCreateFromBigEndianSoundDescriptionData(NULL, b, n, NULL, &fd);
    show("v1 ima4", fd, e);
    if (fd)
        CFRelease(fd);
    /* in a 'wave' atom: frma, enda (little-endian), terminator */
    uint8_t wave[] = {0, 0, 0, 0x26, 'w', 'a', 'v', 'e', 0, 0, 0, 12, 'f', 'r', 'm', 'a', 'i', 'n', '2', '4', 0, 0, 0, 10, 'e', 'n', 'd',
                      'a', 0, 1, 0, 0, 0, 8, 0, 0, 0, 0};
    uint32_t i24[4] = {1, 3, 6, 3};
    n = v01(b, 'in24', 1, 2, 16, 48000, i24, wave, sizeof wave);
    fd = NULL;
    e = CMAudioFormatDescriptionCreateFromBigEndianSoundDescriptionData(NULL, b, n, NULL, &fd);
    show("v1 in24 little-endian", fd, e);
    if (fd)
        CFRelease(fd);

    n = v2(b, 'lpcm', 44100, 2, 16, 12, 4, 1, NULL, 0);
    fd = NULL;
    e = CMAudioFormatDescriptionCreateFromBigEndianSoundDescriptionData(NULL, b, n, NULL, &fd);
    show("v2 lpcm int16", fd, e);
    if (fd)
        CFRelease(fd);
    uint8_t chan[] = {0, 0, 0, 24, 'c', 'h', 'a', 'n', 0, 0, 0, 0, 0, 0x65, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0};
    n = v2(b, 'lpcm', 96000, 2, 32, 9, 8, 1, chan, sizeof chan);
    fd = NULL;
    e = CMAudioFormatDescriptionCreateFromBigEndianSoundDescriptionData(NULL, b, n, NULL, &fd);
    show("v2 lpcm float32 with chan", fd, e);
    if (fd)
        CFRelease(fd);

    /* ISO mp4a, AAC-LC 44.1 kHz stereo */
    uint8_t esds[] = {0,    0,    0,    0x27, 'e',  's',  'd',  's',  0,    0,    0,    0,    0x03, 0x19, 0x00, 0x00,
                      0x00, 0x04, 0x11, 0x40, 0x15, 0x00, 0x00, 0x00, 0x00, 0x01, 0xf4, 0x00, 0x00, 0x01, 0xf4, 0x00,
                      0x05, 0x02, 0x12, 0x10, 0x06, 0x01, 0x02};
    n = v01(b, 'mp4a', 0, 2, 16, 44100, NULL, esds, sizeof esds);
    fd = NULL;
    e = CMAudioFormatDescriptionCreateFromBigEndianSoundDescriptionData(NULL, b, n, kCMSoundDescriptionFlavor_ISOFamily, &fd);
    show("iso mp4a", fd, e);
    CMBlockBufferRef bb = NULL;
    if (fd) {
        e = CMAudioFormatDescriptionCopyAsBigEndianSoundDescriptionBlockBuffer(NULL, fd, kCMSoundDescriptionFlavor_ISOFamily, &bb);
        dump("  back as ISO", bb, e);
        if (bb)
            CFRelease(bb), bb = NULL;
        e = CMAudioFormatDescriptionCopyAsBigEndianSoundDescriptionBlockBuffer(NULL, fd, NULL, &bb);
        dump("  back as QuickTime", bb, e);
        if (bb)
            CFRelease(bb), bb = NULL;
        CFRelease(fd);
    }
    fd = NULL;
    e = CMAudioFormatDescriptionCreateFromBigEndianSoundDescriptionData(NULL, b, n, NULL, &fd);
    show("mp4a read as QuickTime", fd, e);
    if (fd)
        CFRelease(fd);

    /* written from format descriptions */
    struct {
        const char *label;
        AudioStreamBasicDescription a;
    } asbds[] = {
        {"int16 le stereo", {44100, kAudioFormatLinearPCM, 12, 4, 1, 4, 2, 16, 0}},
        {"int16 be mono", {22050, kAudioFormatLinearPCM, 14, 2, 1, 2, 1, 16, 0}},
        {"uint8 mono", {11025, kAudioFormatLinearPCM, 8, 1, 1, 1, 1, 8, 0}},
        {"float32 stereo", {48000, kAudioFormatLinearPCM, 9, 8, 1, 8, 2, 32, 0}},
        {"int24 stereo", {48000, kAudioFormatLinearPCM, 12, 6, 1, 6, 2, 24, 0}},
        {"ulaw mono", {8000, kAudioFormatULaw, 0, 1, 1, 1, 1, 8, 0}},
        {"aac stereo", {44100, kAudioFormatMPEG4AAC, 0, 0, 1024, 0, 2, 0, 0}},
    };
    const char *flavors[] = {"QuickTime", "QuickTime movie v2", "ISO"};
    CFStringRef flavorNames[] = {NULL, kCMSoundDescriptionFlavor_QuickTimeMovieV2, kCMSoundDescriptionFlavor_ISOFamily};
    for (size_t i = 0; i < sizeof asbds / sizeof asbds[0]; i++) {
        fd = NULL;
        CMAudioFormatDescriptionCreate(NULL, &asbds[i].a, 0, NULL, 0, NULL, NULL, &fd);
        for (int f = 0; f < 3; f++) {
            bb = NULL;
            e = CMAudioFormatDescriptionCopyAsBigEndianSoundDescriptionBlockBuffer(NULL, fd, flavorNames[f], &bb);
            char label[96];
            snprintf(label, sizeof label, "%s as %s", asbds[i].label, flavors[f]);
            dump(label, bb, e);
            if (bb) {
                CMAudioFormatDescriptionRef back = NULL;
                e = CMAudioFormatDescriptionCreateFromBigEndianSoundDescriptionBlockBuffer(NULL, bb, flavorNames[f], &back);
                show("  read back", back, e);
                if (back)
                    CFRelease(back);
                CFRelease(bb);
            }
        }
        CFRelease(fd);
    }

    /* swapping */
    n = v2(b, 'lpcm', 44100, 2, 16, 12, 4, 1, NULL, 0);
    e = CMSwapBigEndianSoundDescriptionToHost(b, n);
    printf("swap to host: err %d size %u codec %08x version %u\n", (int)e, *(uint32_t *)b, *(uint32_t *)(b + 4), *(uint16_t *)(b + 16));
    e = CMSwapHostEndianSoundDescriptionToBig(b, n);
    printf("swap back: err %d first bytes %02x%02x%02x%02x\n", (int)e, b[0], b[1], b[2], b[3]);
    fd = NULL;
    e = CMAudioFormatDescriptionCreateFromBigEndianSoundDescriptionData(NULL, b, 10, NULL, &fd);
    printf("too short: err %d\n", (int)e);
    return 0;
}
