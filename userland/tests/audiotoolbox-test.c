/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-audiotoolbox-test: AudioToolbox, run against Apple's and Finch's to compare
 * (tools/host-tests.sh): AudioFormat's properties (format info and names, channel
 * layouts and their names, labels, bitmaps and maps); audio files written (the bytes
 * of each type and format) and read back.
 */
#include <AudioToolbox/AudioToolbox.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *
str(CFStringRef s)
{
    static char b[8][256];
    static int at;
    char *o = b[at++ % 8];
    snprintf(o, 256, "(null)");
    if (s)
        CFStringGetCString(s, o, 256, kCFStringEncodingUTF8);
    return o;
}

static const char *
code(UInt32 c)
{
    static char b[8][8];
    static int at;
    char *o = b[at++ % 8];
    snprintf(o, 8, "%c%c%c%c", (char)(c >> 24), (char)(c >> 16), (char)(c >> 8), (char)c);
    return o;
}

static void
formats(void)
{
    AudioStreamBasicDescription f[] = {
        {44100, kAudioFormatLinearPCM, kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, 4, 1, 4, 2, 16, 0},
        {48000, kAudioFormatLinearPCM, kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved, 4, 1, 4, 2, 32, 0},
        {44100, kAudioFormatLinearPCM, kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsPacked, 6, 1, 6, 2, 24, 0},
        {44100, kAudioFormatLinearPCM, kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, 1, 1, 1, 1, 8, 0},
        {44100, kAudioFormatLinearPCM, kAudioFormatFlagIsPacked, 1, 1, 1, 1, 8, 0},
        {44100, kAudioFormatLinearPCM, kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, 16, 1, 16, 2, 64, 0},
        {44100, kAudioFormatLinearPCM, kAudioFormatFlagIsSignedInteger, 8, 1, 8, 2, 24, 0},
        {22050.5, kAudioFormatLinearPCM, kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, 2, 1, 2, 1, 16, 0},
        {0, kAudioFormatLinearPCM, kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, 4, 1, 4, 2, 16, 0},
        {44100, kAudioFormatLinearPCM, kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, 4, 1, 4, 1, 16, 0},
        {44100, kAudioFormatLinearPCM, 0, 0, 0, 0, 2, 16, 0},
        {44100, kAudioFormatMPEG4AAC, 0, 0, 0, 0, 2, 0, 0},
        {22050, kAudioFormatMPEGLayer3, 0, 0, 0, 0, 1, 0, 0},
        {44100, kAudioFormatMPEGLayer3, 0, 0, 0, 0, 2, 0, 0},
        {8000, kAudioFormatULaw, 0, 0, 0, 0, 1, 0, 0},
        {8000, kAudioFormatALaw, 0, 0, 0, 0, 1, 0, 0},
        {44100, kAudioFormatAppleLossless, 0, 0, 0, 0, 2, 0, 0},
        {48000, kAudioFormatOpus, 0, 0, 0, 0, 2, 0, 0},
        {44100, kAudioFormatFLAC, 0, 0, 0, 0, 2, 0, 0},
        {44100, kAudioFormatAppleIMA4, 0, 0, 0, 0, 2, 0, 0},
        {44100, 'zzzz', 0, 0, 0, 0, 2, 0, 0},
    };
    for (size_t i = 0; i < sizeof f / sizeof f[0]; i++) {
        AudioStreamBasicDescription a = f[i];
        UInt32 sz = sizeof a;
        OSStatus e = AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, NULL, &sz, &a);
        printf("%s %g %u ch: info %d flags %x bpp %u fpp %u bpf %u bits %u", code(f[i].mFormatID), f[i].mSampleRate, (unsigned)f[i].mChannelsPerFrame, (int)e,
               (unsigned)a.mFormatFlags, (unsigned)a.mBytesPerPacket, (unsigned)a.mFramesPerPacket, (unsigned)a.mBytesPerFrame, (unsigned)a.mBitsPerChannel);
        CFStringRef name = NULL;
        sz = sizeof name;
        e = AudioFormatGetProperty(kAudioFormatProperty_FormatName, sizeof f[i], &f[i], &sz, &name);
        UInt32 vbr = 9;
        sz = 4;
        OSStatus ev = AudioFormatGetProperty(kAudioFormatProperty_FormatIsVBR, sizeof f[i], &f[i], &sz, &vbr);
        printf("\n  name %d %s, vbr %d %u\n", (int)e, str(name), (int)ev, (unsigned)vbr);
    }
}

static void
layouts(void)
{
    AudioChannelLayoutTag tags[] = {kAudioChannelLayoutTag_Mono,          kAudioChannelLayoutTag_Stereo,
                                    kAudioChannelLayoutTag_MPEG_5_1_A,    kAudioChannelLayoutTag_MPEG_7_1_C,
                                    kAudioChannelLayoutTag_Quadraphonic,  kAudioChannelLayoutTag_AAC_5_1,
                                    kAudioChannelLayoutTag_DiscreteInOrder | 3, kAudioChannelLayoutTag_Unknown | 4,
                                    kAudioChannelLayoutTag_Ambisonic_B_Format, kAudioChannelLayoutTag_Binaural,
                                    kAudioChannelLayoutTag_DVD_4,         kAudioChannelLayoutTag_Atmos_7_1_4};
    for (size_t i = 0; i < sizeof tags / sizeof tags[0]; i++) {
        AudioChannelLayout l = {tags[i], 0, 0, {}};
        CFStringRef n = NULL, sn = NULL;
        UInt32 sz = sizeof n;
        OSStatus e1 = AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutName, sizeof l, &l, &sz, &n);
        OSStatus e2 = AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutSimpleName, sizeof l, &l, &sz, &sn);
        UInt32 ch = 0, bm = 0, full = 0;
        sz = 4;
        OSStatus e3 = AudioFormatGetProperty(kAudioFormatProperty_NumberOfChannelsForLayout, sizeof l, &l, &sz, &ch);
        sz = 4;
        OSStatus e4 = AudioFormatGetProperty(kAudioFormatProperty_BitmapForLayoutTag, 4, &tags[i], &sz, &bm);
        OSStatus e5 = AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag, 4, &tags[i], &full);
        printf("layout %x: name %d %s, simple %d %s, channels %d %u, bitmap %d %x, full %d %u", (unsigned)tags[i], (int)e1, str(n), (int)e2, str(sn), (int)e3,
               (unsigned)ch, (int)e4, (unsigned)bm, (int)e5, (unsigned)full);
        if (!e5 && full) {
            AudioChannelLayout *f = malloc(full);
            AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag, 4, &tags[i], &full, f);
            printf(" labels");
            for (UInt32 k = 0; k < f->mNumberChannelDescriptions; k++)
                printf(" %u", (unsigned)f->mChannelDescriptions[k].mChannelLabel);
            free(f);
        }
        printf("\n");
    }
    AudioChannelLayout bitmapped = {kAudioChannelLayoutTag_UseChannelBitmap, kAudioChannelBit_Left | kAudioChannelBit_Right, 0, {}};
    CFStringRef bn = NULL;
    UInt32 sz = sizeof bn;
    printf("bitmap layout name %d", (int)AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutName, sizeof bitmapped, &bitmapped, &sz, &bn));
    printf(" %s\n", str(bn));
    UInt32 bitmap = 0x3f, full = 0;
    printf("layout for bitmap %d", (int)AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForBitmap, 4, &bitmap, &full));
    printf(" %u\n", (unsigned)full);
    for (UInt32 lab = 0; lab <= 14; lab++) {
        AudioChannelDescription d = {lab, 0, {0, 0, 0}};
        CFStringRef n = NULL, sn = NULL;
        UInt32 s2 = sizeof n;
        OSStatus a = AudioFormatGetProperty(kAudioFormatProperty_ChannelName, sizeof d, &d, &s2, &n);
        OSStatus b = AudioFormatGetProperty(kAudioFormatProperty_ChannelShortName, sizeof d, &d, &s2, &sn);
        printf("label %u: %d %s / %d %s\n", (unsigned)lab, (int)a, str(n), (int)b, str(sn));
    }
    UInt32 counts[] = {1, 2, 6, 8, 13};
    for (int k = 0; k < 5; k++) {
        UInt32 tsz = 0;
        OSStatus e = AudioFormatGetPropertyInfo(kAudioFormatProperty_TagsForNumberOfChannels, 4, &counts[k], &tsz);
        printf("tags for %u: %d %u:", (unsigned)counts[k], (int)e, (unsigned)(tsz / 4));
        if (!e && tsz) {
            AudioChannelLayoutTag *tl = malloc(tsz);
            AudioFormatGetProperty(kAudioFormatProperty_TagsForNumberOfChannels, 4, &counts[k], &tsz, tl);
            for (UInt32 i = 0; i < tsz / 4; i++)
                printf(" %x", (unsigned)tl[i]);
            free(tl);
        }
        printf("\n");
    }
    AudioChannelLayout st = {kAudioChannelLayoutTag_Stereo, 0, 0, {}}, fiveOne = {kAudioChannelLayoutTag_MPEG_5_1_A, 0, 0, {}},
                       aac = {kAudioChannelLayoutTag_AAC_5_1, 0, 0, {}};
    const AudioChannelLayout *pair[] = {&fiveOne, &aac};
    SInt32 map[8];
    UInt32 msz = 0;
    printf("map 5.1 to AAC 5.1 %d", (int)AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelMap, sizeof pair, pair, &msz));
    printf(" %u %d:", (unsigned)msz, (int)AudioFormatGetProperty(kAudioFormatProperty_ChannelMap, sizeof pair, pair, &msz, map));
    for (UInt32 i = 0; i < msz / 4; i++)
        printf(" %d", (int)map[i]);
    msz = sizeof map;
    printf(" too big %d", (int)AudioFormatGetProperty(kAudioFormatProperty_ChannelMap, sizeof pair, pair, &msz, map));
    const AudioChannelLayout *same[] = {&st, &bitmapped}, *differ[] = {&st, &fiveOne};
    UInt32 eq = 9;
    msz = 4;
    printf("\nequivalent %d", (int)AudioFormatGetProperty(kAudioFormatProperty_AreChannelLayoutsEquivalent, sizeof same, same, &msz, &eq));
    printf(" %u", (unsigned)eq);
    msz = 4;
    printf(" %d", (int)AudioFormatGetProperty(kAudioFormatProperty_AreChannelLayoutsEquivalent, sizeof differ, differ, &msz, &eq));
    printf(" %u\n", (unsigned)eq);
}

/* --- files --- */

static char dir[256];

static void
dump(const char *path)
{
    FILE *fp = fopen(path, "rb");
    if (!fp) {
        printf("  (no file)\n");
        return;
    }
    unsigned char b[8192];
    size_t n = fread(b, 1, sizeof b, fp);
    fclose(fp);
    /* (the header and the end, the filler's zeros left out) */
    printf("  %zu bytes:", n);
    for (size_t i = 0; i < n; i++) {
        bool zeros = i + 16 <= n && !memcmp(b + i, (unsigned char[16]){0}, 16);
        if (zeros && i > 0) {
            size_t run = i;
            while (run < n && !b[run])
                run++;
            if (run - i > 32) {
                printf(" [%zu zeros]", run - i);
                i = run - 1;
                continue;
            }
        }
        printf("%s%02x", i % 16 ? "" : " ", b[i]);
    }
    printf("\n");
}

static AudioFileID
create(const char *name, AudioFileTypeID type, AudioStreamBasicDescription a, AudioChannelLayoutTag tag, UInt32 frames, char *path)
{
    snprintf(path, 512, "%s/%s", dir, name);
    CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    AudioFileID f = NULL;
    OSStatus e = AudioFileCreateWithURL(u, type, &a, kAudioFileFlags_EraseFile, &f);
    CFRelease(u);
    printf("%s: create %d", name, (int)e);
    if (e) {
        printf("\n");
        return NULL;
    }
    if (tag) {
        AudioChannelLayout l = {tag, 0, 0, {}};
        printf(" layout %d", (int)AudioFileSetProperty(f, kAudioFilePropertyChannelLayout, sizeof l, &l));
    }
    UInt8 buf[1024];
    for (int i = 0; i < 1024; i++)
        buf[i] = (UInt8)(i * 7 + 1);
    UInt32 bytes = a.mBytesPerFrame * frames;
    if (bytes)
        printf(" write %d %u", (int)AudioFileWriteBytes(f, false, 0, &bytes, buf), (unsigned)bytes);
    return f;
}

static void
make(const char *name, AudioFileTypeID type, AudioStreamBasicDescription a, AudioChannelLayoutTag tag, UInt32 frames)
{
    char path[512];
    AudioFileID f = create(name, type, a, tag, frames, path);
    if (!f)
        return;
    printf(" close %d\n", (int)AudioFileClose(f));
    dump(path);
}

static void
read_back(const char *name)
{
    char path[512];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    AudioFileID f = NULL;
    OSStatus e = AudioFileOpenURL(u, kAudioFileReadPermission, 0, &f);
    CFRelease(u);
    printf("open %s: %d", name, (int)e);
    if (e) {
        printf("\n");
        return;
    }
    AudioFileTypeID type = 0;
    AudioStreamBasicDescription a = {0};
    UInt64 bytes = 0, packets = 0;
    UInt32 max = 0, sz;
    SInt64 offset = 0;
    Float64 duration = 0;
    sz = 4, AudioFileGetProperty(f, kAudioFilePropertyFileFormat, &sz, &type);
    sz = sizeof a, AudioFileGetProperty(f, kAudioFilePropertyDataFormat, &sz, &a);
    sz = 8, AudioFileGetProperty(f, kAudioFilePropertyAudioDataByteCount, &sz, &bytes);
    sz = 8, AudioFileGetProperty(f, kAudioFilePropertyAudioDataPacketCount, &sz, &packets);
    sz = 4, AudioFileGetProperty(f, kAudioFilePropertyMaximumPacketSize, &sz, &max);
    sz = 8, AudioFileGetProperty(f, kAudioFilePropertyDataOffset, &sz, &offset);
    sz = 8, AudioFileGetProperty(f, kAudioFilePropertyEstimatedDuration, &sz, &duration);
    printf(" type %s format %s %g flags %x bpp %u fpp %u bpf %u ch %u bits %u; bytes %llu packets %llu max %u offset %lld duration %.6f\n",
           code(type), code(a.mFormatID), a.mSampleRate, (unsigned)a.mFormatFlags, (unsigned)a.mBytesPerPacket, (unsigned)a.mFramesPerPacket,
           (unsigned)a.mBytesPerFrame, (unsigned)a.mChannelsPerFrame, (unsigned)a.mBitsPerChannel, (unsigned long long)bytes,
           (unsigned long long)packets, (unsigned)max, (long long)offset, duration);
    UInt32 lsz = 0, writable = 9;
    e = AudioFileGetPropertyInfo(f, kAudioFilePropertyChannelLayout, &lsz, &writable);
    printf("  layout %d %u", (int)e, (unsigned)lsz);
    if (!e && lsz) {
        AudioChannelLayout *l = malloc(lsz);
        AudioFileGetProperty(f, kAudioFilePropertyChannelLayout, &lsz, l);
        printf(" tag %x bitmap %x n %u", (unsigned)l->mChannelLayoutTag, (unsigned)l->mChannelBitmap, (unsigned)l->mNumberChannelDescriptions);
        free(l);
    }
    UInt8 got[64] = {0};
    UInt32 n = 6;
    e = AudioFileReadBytes(f, false, 1, &n, got);
    printf(", bytes from 1: %d %u", (int)e, (unsigned)n);
    for (UInt32 i = 0; i < n; i++)
        printf(" %02x", got[i]);
    UInt32 np = 1, nb = sizeof got;
    e = AudioFileReadPacketData(f, false, &nb, NULL, 1, &np, got);
    printf(", packet 1: %d %u packets %u bytes", (int)e, (unsigned)np, (unsigned)nb);
    n = 64;
    e = AudioFileReadBytes(f, false, (SInt64)bytes, &n, got);
    printf(", past the end %d %u\n", (int)e, (unsigned)n);
    AudioFileClose(f);
}

static void
files(void)
{
    snprintf(dir, sizeof dir, "/tmp/finch-audiotoolbox-test.%d", (int)getpid());
    mkdir(dir, 0755);
    AudioStreamBasicDescription le16 = {44100, kAudioFormatLinearPCM, kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, 4, 1, 4, 2, 16, 0};
    AudioStreamBasicDescription be16 = le16;
    be16.mFormatFlags |= kAudioFormatFlagIsBigEndian;
    make("a.wav", kAudioFileWAVEType, le16, 0, 4);
    make("a.aif", kAudioFileAIFFType, be16, 0, 4);
    make("a.aifc", kAudioFileAIFCType, be16, 0, 4);
    make("a.caf", kAudioFileCAFType, le16, 0, 4);
    make("a.au", kAudioFileNextType, be16, 0, 4);
    make("float.wav", kAudioFileWAVEType, (AudioStreamBasicDescription){48000, 'lpcm', kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, 8, 1, 8, 2, 32, 0}, 0, 2);
    make("24.wav", kAudioFileWAVEType, (AudioStreamBasicDescription){48000, 'lpcm', kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, 6, 1, 6, 2, 24, 0}, 0, 2);
    make("8.wav", kAudioFileWAVEType, (AudioStreamBasicDescription){8000, 'lpcm', kAudioFormatFlagIsPacked, 1, 1, 1, 1, 8, 0}, 0, 3);
    make("six.wav", kAudioFileWAVEType, (AudioStreamBasicDescription){48000, 'lpcm', kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, 12, 1, 12, 6, 16, 0}, 0, 2);
    make("six-layout.wav", kAudioFileWAVEType, (AudioStreamBasicDescription){48000, 'lpcm', kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, 12, 1, 12, 6, 16, 0},
         kAudioChannelLayoutTag_MPEG_5_1_A, 2);
    make("stereo-layout.caf", kAudioFileCAFType, (AudioStreamBasicDescription){48000, 'lpcm', kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, 4, 1, 4, 2, 16, 0},
         kAudioChannelLayoutTag_Stereo, 2);
    make("empty.wav", kAudioFileWAVEType, le16, 0, 0);
    make("float.caf", kAudioFileCAFType, (AudioStreamBasicDescription){48000, 'lpcm', kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, 8, 1, 8, 2, 32, 0}, 0, 2);
    make("ulaw.wav", kAudioFileWAVEType, (AudioStreamBasicDescription){8000, 'ulaw', 0, 1, 1, 1, 1, 8, 0}, 0, 2);
    make("ulaw.au", kAudioFileNextType, (AudioStreamBasicDescription){8000, 'ulaw', 0, 1, 1, 1, 1, 8, 0}, 0, 2);
    make("24.aif", kAudioFileAIFFType,
         (AudioStreamBasicDescription){48000, 'lpcm', kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagIsBigEndian, 6, 1, 6, 2, 24, 0}, 0, 2);
    make("float.aifc", kAudioFileAIFCType,
         (AudioStreamBasicDescription){48000, 'lpcm', kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsBigEndian, 8, 1, 8, 2, 32, 0}, 0, 2);
    make("le.aif", kAudioFileAIFFType, le16, 0, 2);
    make("be.wav", kAudioFileWAVEType, be16, 0, 2);
    make("bad.type", 'zzzz', le16, 0, 2);
    /* (sizes put in as it grows: read before closing) */
    char path[512];
    AudioFileID open = create("growing.wav", kAudioFileWAVEType, le16, 0, 4, path);
    if (open) {
        printf("\n");
        dump(path);
        AudioFileClose(open);
    }
    const char *names[] = {"a.wav", "a.aif", "a.aifc", "a.caf", "a.au", "float.wav", "24.wav", "8.wav", "six-layout.wav", "stereo-layout.caf",
                           "empty.wav", "float.caf", "ulaw.wav", "ulaw.au", "24.aif", "float.aifc", "missing.wav"};
    for (size_t i = 0; i < sizeof names / sizeof names[0]; i++)
        read_back(names[i]);
}

int
main(void)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    Dl_info info;
    dladdr((void *)AudioFormatGetProperty, &info);
    printf("%s\n", info.dli_fname);
    formats();
    layouts();
    files();
    return 0;
}
