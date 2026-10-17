/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-audiotoolbox-test: AudioToolbox, run against Apple's and Finch's to compare
 * (tools/host-tests.sh): AudioFormat's properties (format info and names, channel
 * layouts and their names, labels, bitmaps and maps); audio files written (the bytes
 * of each type and format) and read back.
 */
#include <AudioToolbox/AudioToolbox.h>
#include <AudioToolbox/AudioHardwareService.h>
#include <CoreServices/CoreServices.h>
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

static UInt32 parameterNotifications, eventNotifications;
static AudioUnitParameterValue lastParameterValue;

static void
parameter_changed(void *userData, void *object, const AudioUnitParameter *parameter, AudioUnitParameterValue value)
{
    (void)userData; (void)object; (void)parameter;
    parameterNotifications++;
    lastParameterValue = value;
}

static void
event_changed(void *userData, void *object, const AudioUnitEvent *event, UInt64 hostTime, AudioUnitParameterValue value)
{
    (void)userData; (void)object; (void)event; (void)hostTime; (void)value;
    eventNotifications++;
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

static void
legacy_file_apis(void)
{
    FSRef parent, fileRef;
    if (FSPathMakeRef((const UInt8 *)dir, &parent, NULL) != noErr) {
        puts("legacy file APIs: parent unavailable");
        return;
    }
    AudioStreamBasicDescription format = {
        44100, kAudioFormatLinearPCM,
        kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        4, 1, 4, 2, 16, 0
    };
    AudioFileID file = NULL;
    OSStatus status = AudioFileCreate(&parent, CFSTR("legacy.wav"), kAudioFileWAVEType,
        &format, kAudioFileFlags_EraseFile, &fileRef, &file);
    printf("legacy AudioFileCreate %d file %d", (int)status, file != NULL);
    if (!status && file) {
        UInt8 bytes[] = {1, 2, 3, 4, 5, 6, 7, 8};
        UInt32 size = sizeof bytes;
        printf(" write %d", (int)AudioFileWriteBytes(file, false, 0, &size, bytes));
        printf(" close %d", (int)AudioFileClose(file));
    }
    file = NULL;
    status = AudioFileOpen(&fileRef, kAudioFileReadPermission, 0, &file);
    UInt64 byteCount = 0;
    UInt32 propertySize = sizeof byteCount;
    OSStatus propertyStatus = status ? status : AudioFileGetProperty(file,
        kAudioFilePropertyAudioDataByteCount, &propertySize, &byteCount);
    printf(" open %d bytes %d/%llu", (int)status, (int)propertyStatus,
        (unsigned long long)byteCount);
    if (file)
        AudioFileClose(file);

    file = NULL;
    status = AudioFileInitialize(&fileRef, kAudioFileCAFType, &format, 0, &file);
    printf(" initialize %d file %d", (int)status, file != NULL);
    if (file)
        AudioFileClose(file);
    file = NULL;
    status = AudioFileOpen(&fileRef, kAudioFileReadPermission, 0, &file);
    UInt32 type = 0;
    propertySize = sizeof type;
    propertyStatus = status ? status : AudioFileGetProperty(file, kAudioFilePropertyFileFormat,
        &propertySize, &type);
    printf(" reopened %d type %s/%d\n", (int)status, code(type), (int)propertyStatus);
    if (file)
        AudioFileClose(file);
}

typedef struct {
    UInt32 properties;
    UInt32 packets;
    UInt32 packetBytes;
} StreamTestState;

static void
stream_property(void *client, AudioFileStreamID stream, AudioFileStreamPropertyID property,
    AudioFileStreamPropertyFlags *flags)
{
    (void)stream;
    (void)property;
    (void)flags;
    ((StreamTestState *)client)->properties++;
}

static void
stream_packets(void *client, UInt32 byteCount, UInt32 packetCount, const void *data,
    AudioStreamPacketDescription *descriptions)
{
    (void)data;
    (void)descriptions;
    StreamTestState *state = client;
    state->packets += packetCount;
    state->packetBytes += byteCount;
}

static void
audio_file_stream(void)
{
    char path[512];
    snprintf(path, sizeof(path), "%s/a.wav", dir);
    FILE *file = fopen(path, "rb");
    if (!file) {
        puts("audio stream missing input");
        return;
    }
    fseek(file, 0, SEEK_END);
    long length = ftell(file);
    rewind(file);
    UInt8 *bytes = length > 0 ? malloc((size_t)length) : NULL;
    size_t readCount = bytes ? fread(bytes, 1, (size_t)length, file) : 0;
    fclose(file);
    StreamTestState state = {0};
    AudioFileStreamID stream = NULL;
    OSStatus openStatus = AudioFileStreamOpen(&state, stream_property, stream_packets, 0, &stream);
    OSStatus parseStatus = openStatus ? openStatus : AudioFileStreamParseBytes(stream,
        (UInt32)readCount, bytes, 0);
    UInt32 ready = 0, size = sizeof(ready);
    OSStatus readyStatus = parseStatus ? parseStatus : AudioFileStreamGetProperty(stream,
        kAudioFileStreamProperty_ReadyToProducePackets, &size, &ready);
    AudioStreamBasicDescription format = {0};
    size = sizeof(format);
    OSStatus formatStatus = readyStatus ? readyStatus : AudioFileStreamGetProperty(stream,
        kAudioFileStreamProperty_DataFormat, &size, &format);
    SInt64 seek = -1;
    AudioFileStreamSeekFlags seekFlags = 0;
    OSStatus seekStatus = formatStatus ? formatStatus : AudioFileStreamSeek(stream, 1, &seek, &seekFlags);
    OSStatus flushStatus = parseStatus ? parseStatus : AudioFileStreamParseBytes(stream, 0, NULL, 0);
    printf("audio stream %d/%d ready %d/%u format %d %s/%u packets %u/%u seek %d %lld/%u flush %d\n",
        (int)openStatus, (int)parseStatus, (int)readyStatus, (unsigned)ready,
        (int)formatStatus, code(format.mFormatID), (unsigned)format.mBytesPerPacket,
        (unsigned)state.packets, (unsigned)state.properties, (int)seekStatus, (long long)seek,
        (unsigned)seekFlags, (int)flushStatus);
    if (stream) AudioFileStreamClose(stream);
    free(bytes);
}

static void
global_file_types(void)
{
    const AudioFileTypeID types[] = {
        kAudioFileAIFFType, kAudioFileAIFCType, kAudioFileWAVEType,
        kAudioFileCAFType, kAudioFileNextType
    };
    for (size_t i = 0; i < sizeof types / sizeof types[0]; i++) {
        CFStringRef name = NULL;
        UInt32 size = 0;
        OSStatus sizeStatus = AudioFileGetGlobalInfoSize(kAudioFileGlobalInfo_FileTypeName,
            sizeof types[i], (void *)&types[i], &size);
        OSStatus status = sizeStatus ? sizeStatus : AudioFileGetGlobalInfo(kAudioFileGlobalInfo_FileTypeName,
            sizeof types[i], (void *)&types[i], &size, &name);
        char text[128] = "";
        if (name)
            CFStringGetCString(name, text, sizeof text, kCFStringEncodingUTF8);
        printf("global file type %s: size %d/%u name %d %s\n", code(types[i]), (int)sizeStatus,
            (unsigned)size, (int)status, text);
        if (name)
            CFRelease(name);

        CFArrayRef extensions = NULL;
        size = sizeof extensions;
        status = AudioFileGetGlobalInfo(kAudioFileGlobalInfo_ExtensionsForType,
            sizeof types[i], (void *)&types[i], &size, &extensions);
        printf("  extensions %d", (int)status);
        if (!status && extensions) {
            for (CFIndex j = 0; j < CFArrayGetCount(extensions); j++) {
                char extension[32] = "";
                CFStringGetCString(CFArrayGetValueAtIndex(extensions, j), extension,
                    sizeof extension, kCFStringEncodingUTF8);
                printf(" %s", extension);
            }
            CFRelease(extensions);
        }
        printf("\n");
    }
}

static void
music_sequence(void)
{
    MusicSequence sequence = NULL;
    MusicTrack tempo = NULL, track = NULL, fetched = NULL;
    OSStatus status = NewMusicSequence(&sequence);
    printf("music sequence create %d", (int)status);
    if (status)
        return;
    UInt32 count = 99, index = 99;
    MusicSequenceGetTrackCount(sequence, &count);
    MusicSequenceGetTempoTrack(sequence, &tempo);
    MusicSequenceNewTrack(sequence, &track);
    MusicSequenceGetIndTrack(sequence, 0, &fetched);
    MusicSequenceGetTrackIndex(sequence, track, &index);
    printf(" tracks %u index %u same %u", (unsigned)count, (unsigned)index, fetched == track);

    MIDINoteMessage note = {0, 60, 100, 0, 1.25f};
    ExtendedTempoEvent tempoEvent = {90.0};
    OSStatus noteStatus = MusicTrackNewMIDINoteEvent(track, 0.5, &note);
    OSStatus tempoStatus = MusicTrackNewExtendedTempoEvent(tempo, 0, tempoEvent.bpm);
    ExtendedControlEvent control = {0, 7, 0.5f};
    OSStatus controlStatus = MusicTrackNewExtendedControlEvent(track, 1.5, &control);
    Float64 seconds = -1;
    OSStatus secondsStatus = MusicSequenceGetSecondsForBeats(sequence, 3, &seconds);
    MusicTimeStamp beats = -1;
    OSStatus beatsStatus = MusicSequenceGetBeatsForSeconds(sequence, 2, &beats);
    printf(" note %d tempo %d control %d seconds %d %.6f beats %d %.6f", (int)noteStatus, (int)tempoStatus,
           (int)controlStatus,
           (int)secondsStatus, seconds, (int)beatsStatus, beats);

    UInt32 length = sizeof(MusicTimeStamp);
    MusicTimeStamp trackLength = -1;
    OSStatus lengthStatus = MusicTrackGetProperty(track, kSequenceTrackProperty_TrackLength, &trackLength, &length);
    MusicTrackLoopInfo loop = {2, 3};
    OSStatus loopSet = MusicTrackSetProperty(track, kSequenceTrackProperty_LoopInfo, &loop, sizeof(loop));
    length = sizeof(loop);
    MusicTrackLoopInfo loopOut = {0};
    OSStatus loopGet = MusicTrackGetProperty(track, kSequenceTrackProperty_LoopInfo, &loopOut, &length);
    printf(" length %d %.6f loop %d/%d %.6f %d", (int)lengthStatus, trackLength, (int)loopSet,
           (int)loopGet, loopOut.loopDuration, loopOut.numberOfLoops);

    MusicEventIterator iterator = NULL;
    OSStatus iteratorStatus = NewMusicEventIterator(track, &iterator);
    Boolean current = false, next = false, previous = false;
    MusicEventIteratorHasCurrentEvent(iterator, &current);
    MusicEventIteratorHasNextEvent(iterator, &next);
    MusicEventIteratorHasPreviousEvent(iterator, &previous);
    MusicTimeStamp time = -1;
    MusicEventType type = 0;
    const void *data = NULL;
    UInt32 dataSize = 0;
    OSStatus infoStatus = MusicEventIteratorGetEventInfo(iterator, &time, &type, &data, &dataSize);
    printf(" iterator %d current %u next %u previous %u info %d %.6f %u %u", (int)iteratorStatus,
           (unsigned)current, (unsigned)next, (unsigned)previous, (int)infoStatus, time, (unsigned)type, (unsigned)dataSize);
    MusicEventIteratorNextEvent(iterator);
    MusicEventIteratorHasCurrentEvent(iterator, &current);
    printf(" end %u", (unsigned)current);
    DisposeMusicEventIterator(iterator);

    CFDataRef midiData = NULL;
    OSStatus midiStatus = MusicSequenceSaveSMFData(sequence, &midiData, 480);
    MusicSequence loaded = NULL;
    OSStatus loadCreate = NewMusicSequence(&loaded);
    OSStatus loadStatus = loadCreate ? loadCreate : MusicSequenceFileLoadData(loaded, midiData,
        kMusicSequenceFile_MIDIType, kMusicSequenceLoadSMF_PreserveTracks);
    UInt32 loadedTracks = 0;
    if (!loadStatus) MusicSequenceGetTrackCount(loaded, &loadedTracks);
    CFURLRef midiURL = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)"build/music-sequence-test.mid",
        strlen("build/music-sequence-test.mid"), false);
    OSStatus createFileStatus = MusicSequenceFileCreate(sequence, midiURL, kMusicSequenceFile_MIDIType,
        kMusicSequenceFileFlags_EraseFile, 480);
    MusicSequence loadedFromFile = NULL;
    OSStatus fileLoadCreate = NewMusicSequence(&loadedFromFile);
    OSStatus fileLoadStatus = fileLoadCreate ? fileLoadCreate : MusicSequenceFileLoad(loadedFromFile, midiURL,
        kMusicSequenceFile_MIDIType, kMusicSequenceLoadSMF_PreserveTracks);
    UInt32 fileTracks = 0;
    if (!fileLoadStatus) MusicSequenceGetTrackCount(loadedFromFile, &fileTracks);
    MusicTrack copiedTrack = NULL;
    OSStatus copyTrackStatus = NewMusicTrackFrom(track, 0, 3, &copiedTrack);
    MusicEventIterator copiedIterator = NULL;
    Boolean copiedHasEvent = false;
    if (!copyTrackStatus) {
        NewMusicEventIterator(copiedTrack, &copiedIterator);
        if (copiedIterator) MusicEventIteratorHasCurrentEvent(copiedIterator, &copiedHasEvent);
    }
    printf("midi %d %ld load %d/%d tracks %u file %d/%d tracks %u copied %d event %u\n",
           (int)midiStatus, (long)(midiData ? CFDataGetLength(midiData) : -1),
           (int)loadCreate, (int)loadStatus, (unsigned)loadedTracks,
           (int)createFileStatus, (int)fileLoadStatus, (unsigned)fileTracks,
           (int)copyTrackStatus, (unsigned)copiedHasEvent);
    if (midiData) CFRelease(midiData);
    if (midiURL) CFRelease(midiURL);
    if (copiedIterator) DisposeMusicEventIterator(copiedIterator);
    if (loaded) DisposeMusicSequence(loaded);
    if (loadedFromFile) DisposeMusicSequence(loadedFromFile);
    unlink("build/music-sequence-test.mid");

    CABarBeatTime barBeat = {0};
    MusicSequenceBeatsToBarBeatTime(sequence, 5.5, 960, &barBeat);
    MusicTimeStamp converted = -1;
    MusicSequenceBarBeatTimeToBeats(sequence, &barBeat, &converted);
    printf(" barbeat %d.%u.%u/%u %.6f", barBeat.bar, barBeat.beat, barBeat.subbeat,
           barBeat.subbeatDivisor, converted);

    CFDictionaryRef info = MusicSequenceGetInfoDictionary(sequence);
    printf(" info %ld", info ? CFDictionaryGetCount(info) : -1L);
    if (info) {
        CFNumberRef tempoValue = (CFNumberRef)CFDictionaryGetValue(info, CFSTR("tempo"));
        Float64 tempoNumber = 0;
        if (tempoValue) CFNumberGetValue(tempoValue, kCFNumberFloat64Type, &tempoNumber);
        CFStringRef signature = CFDictionaryGetValue(info, CFSTR("time signature"));
        printf(" tempo %.1f signature %s", tempoNumber, str(signature));
        CFRelease(info);
    }
    MusicTrackClear(track, 0, kMusicTimeStamp_EndOfTrack);

    MusicPlayer player = NULL;
    OSStatus playerCreate = NewMusicPlayer(&player);
    OSStatus playerSet = playerCreate ? playerCreate : MusicPlayerSetSequence(player, sequence);
    MusicSequence attached = NULL;
    OSStatus playerGet = playerSet ? playerSet : MusicPlayerGetSequence(player, &attached);
    MusicTimeStamp playerTime = -1;
    OSStatus playerTimeStatus = playerGet ? playerGet : MusicPlayerGetTime(player, &playerTime);
    OSStatus rateSet = playerTimeStatus ? playerTimeStatus : MusicPlayerSetPlayRateScalar(player, 1.25);
    Float64 rate = 0;
    OSStatus rateGet = rateSet ? rateSet : MusicPlayerGetPlayRateScalar(player, &rate);
    OSStatus playerStart = rateGet ? rateGet : MusicPlayerStart(player);
    Boolean playing = false;
    OSStatus playingStatus = playerStart ? playerStart : MusicPlayerIsPlaying(player, &playing);
    Boolean wasPlaying = playing;
    OSStatus playerStop = playingStatus ? playingStatus : MusicPlayerStop(player);
    MusicPlayerIsPlaying(player, &playing);
    printf(" player %d/%d/%d attached %u time %d rate %.2f start %d playing %u stop %d final %u",
           (int)playerCreate, (int)playerSet, (int)playerGet, attached == sequence,
           (int)playerTimeStatus, rate, (int)playerStart, (unsigned)wasPlaying,
           (int)playerStop, (unsigned)playing);
    MusicPlayerSetSequence(player, NULL);
    OSStatus playerDispose = DisposeMusicPlayer(player);
    printf(" dispose-player %d", (int)playerDispose);
    MusicSequenceGetTrackCount(sequence, &count);
    printf(" clear tracks %u", (unsigned)count);
    OSStatus disposeStatus = DisposeMusicSequence(sequence);
    printf(" dispose %d\n", (int)disposeStatus);
}

static void
clock_listener(void *userData, CAClockMessage message, const void *param)
{
    (void)userData;
    (void)message;
    (void)param;
}

static void
audio_clock(void)
{
    CAClockRef clock = NULL;
    OSStatus createStatus = CAClockNew(0, &clock);
    if (createStatus) {
        printf("clock create %d\n", (int)createStatus);
        return;
    }
    UInt32 size = 0;
    Boolean writable = false;
    OSStatus infoStatus = CAClockGetPropertyInfo(clock, kCAClockProperty_TempoMap, &size, &writable);
    OSStatus listenerAdd = CAClockAddListener(clock, clock_listener, clock);
    OSStatus listenerRemove = CAClockRemoveListener(clock, clock_listener, clock);
    CATempoMapEntry map[] = {{0, 120}, {8, 60}};
    OSStatus mapStatus = CAClockSetProperty(clock, kCAClockProperty_TempoMap, sizeof map, map);
    CFStringRef name = CFSTR("finch clock");
    OSStatus nameSet = CAClockSetProperty(clock, kCAClockProperty_Name, sizeof name, &name);
    CFStringRef nameOut = NULL;
    UInt32 nameSize = sizeof nameOut;
    OSStatus nameGet = CAClockGetProperty(clock, kCAClockProperty_Name, &nameSize, &nameOut);
    CAClockTime position = {.format = kCAClockTimeFormat_Beats, .time.beats = 8};
    OSStatus setTime = CAClockSetCurrentTime(clock, &position);
    CAClockTime seconds = {.format = kCAClockTimeFormat_Seconds};
    OSStatus getTime = CAClockGetCurrentTime(clock, kCAClockTimeFormat_Seconds, &seconds);
    CAClockTime start = {.format = kCAClockTimeFormat_Beats};
    OSStatus getStart = CAClockGetStartTime(clock, kCAClockTimeFormat_Beats, &start);
    CAClockTime translated = {.format = kCAClockTimeFormat_Seconds};
    OSStatus translate = CAClockTranslateTime(clock, &position, kCAClockTimeFormat_Seconds, &translated);
    CABarBeatTime barBeat = {0};
    OSStatus barStatus = CAClockBeatsToBarBeatTime(clock, 5.5, 480, &barBeat);
    CAClockBeats barBeats = -1;
    OSStatus barBack = CAClockBarBeatTimeToBeats(clock, &barBeat, &barBeats);
    SMPTETime smpte = {0};
    OSStatus smpteStatus = CAClockSecondsToSMPTETime(clock, 3661.5, 80, &smpte);
    CAClockSeconds smpteSeconds = -1;
    OSStatus smpteBack = CAClockSMPTETimeToSeconds(clock, &smpte, &smpteSeconds);
    Float64 rate = 0;
    OSStatus rateSet = CAClockSetPlayRate(clock, 0.75);
    OSStatus rateGet = CAClockGetPlayRate(clock, &rate);
    CAClockTempo tempo = 0;
    OSStatus stoppedTempo = CAClockSetCurrentTempo(clock, 100, NULL);
    OSStatus startStatus = CAClockStart(clock);
    OSStatus runningTempo = CAClockSetCurrentTempo(clock, 100, NULL);
    OSStatus tempoGet = CAClockGetCurrentTempo(clock, &tempo, NULL);
    CAClockTime ignored = {.format = kCAClockTimeFormat_Beats, .time.beats = 1};
    OSStatus runningSetTime = CAClockSetCurrentTime(clock, &ignored);
    OSStatus armStatus = CAClockArm(clock);
    OSStatus disarmStatus = CAClockDisarm(clock);
    OSStatus stopStatus = CAClockStop(clock);
    printf("clock prop %d/%u/%u listener %d/%d map %d name %d/%d time %d/%d %.3f start %d %.3f translate %d %.3f",
           (int)infoStatus, (unsigned)size, (unsigned)writable, (int)listenerAdd,
           (int)listenerRemove, (int)mapStatus, (int)nameSet, (int)nameGet,
           (int)setTime, (int)getTime, seconds.time.seconds, (int)getStart,
           start.time.beats, (int)translate, translated.time.seconds);
    printf(" bar %d/%d %d.%u.%u/%u %.3f smpte %d %d:%d:%d:%d %.3f/%d %.3f",
           (int)barStatus, (int)barBack, barBeat.bar, barBeat.beat, barBeat.subbeat,
           barBeat.subbeatDivisor, barBeats, (int)smpteStatus, smpte.mHours,
           smpte.mMinutes, smpte.mSeconds, smpte.mFrames, smpteSeconds,
           (int)smpteBack, smpteSeconds);
    printf(" rate %d/%d %.2f tempo %d start %d running %d/%d %.1f set-running %d arm %d/%d stop %d\n",
           (int)rateSet, (int)rateGet, rate, (int)stoppedTempo, (int)startStatus,
           (int)runningTempo, (int)tempoGet, tempo, (int)runningSetTime, (int)armStatus,
           (int)disarmStatus, (int)stopStatus);
    CAClockDispose(clock);
}


static OSStatus
graph_render_callback(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
    UInt32 bus, UInt32 frames, AudioBufferList *buffers)
{
    return noErr;
}

static void
audio_unit_utilities(void)
{
    AudioComponentDescription description = {kAudioUnitType_Effect, kAudioUnitSubType_Delay,
        kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    AudioUnit unit = NULL;
    OSStatus createStatus = component ? AudioComponentInstanceNew(component, &unit) : -1;
    AudioUnitParameter parameter = {unit, kDelayParam_WetDryMix, kAudioUnitScope_Global, 0};
    AudioUnitParameterInfo info = {0};
    UInt32 infoSize = sizeof(info);
    OSStatus infoStatus = createStatus ? createStatus : AudioUnitGetProperty(unit, kAudioUnitProperty_ParameterInfo,
        kAudioUnitScope_Global, kDelayParam_WetDryMix, &info, &infoSize);
    char formatted[64] = {0};
    AUParameterFormatValue(65.432, &parameter, formatted, 3);
    printf("AU utility unit %d info %d %u %.2f %.2f %.2f flags %x unit %u value %.3f/%.3f format %s\n",
        (int)createStatus, (int)infoStatus, (unsigned)infoSize, info.minValue, info.maxValue,
        info.defaultValue, (unsigned)(info.flags & ~kAudioUnitParameterFlag_CFNameRelease), (unsigned)info.unit,
        AUParameterValueToLinear(50, &parameter), AUParameterValueFromLinear(0.5f, &parameter), formatted);

    parameterNotifications = 0;
    eventNotifications = 0;
    AUParameterListenerRef listener = NULL;
    AUEventListenerRef eventListener = NULL;
    CFRunLoopRef runLoop = CFRunLoopGetCurrent();
    OSStatus listenerStatus = AUListenerCreate(parameter_changed, &parameterNotifications,
        runLoop, kCFRunLoopDefaultMode, 0, &listener);
    OSStatus addParameterStatus = listenerStatus ? listenerStatus : AUListenerAddParameter(listener, unit, &parameter);
    OSStatus eventCreateStatus = AUEventListenerCreate(event_changed, &eventNotifications,
        runLoop, kCFRunLoopDefaultMode, 0, 0, &eventListener);
    AudioUnitEvent changed = {.mEventType = kAudioUnitEvent_ParameterValueChange};
    changed.mArgument.mParameter = parameter;
    AudioUnitEvent gesture = {.mEventType = kAudioUnitEvent_BeginParameterChangeGesture};
    gesture.mArgument.mParameter = parameter;
    OSStatus addEventStatus = eventCreateStatus ? eventCreateStatus : AUEventListenerAddEventType(eventListener, unit, &changed);
    OSStatus addGestureStatus = eventCreateStatus ? eventCreateStatus : AUEventListenerAddEventType(eventListener, unit, &gesture);
    OSStatus setStatus = (addParameterStatus || addEventStatus) ? -50 : AUParameterSet(NULL, NULL, &parameter, 65.0f, 0);
    OSStatus gestureStatus = eventCreateStatus ? eventCreateStatus : AUEventListenerNotify(NULL, NULL, &gesture);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);
    AudioUnitParameterValue currentValue = 0;
    if (unit)
        AudioUnitGetParameter(unit, kDelayParam_WetDryMix, kAudioUnitScope_Global, 0, &currentValue);
    printf("AU utilities listeners %d/%d event %d/%d/%d set %d gesture %d callbacks %u/%u value %.2f current %.2f\n",
        (int)listenerStatus, (int)addParameterStatus, (int)eventCreateStatus, (int)addEventStatus,
        (int)addGestureStatus, (int)setStatus, (int)gestureStatus, (unsigned)parameterNotifications,
        (unsigned)eventNotifications, lastParameterValue, currentValue);
    if (eventListener) AUListenerDispose(eventListener);
    if (listener) AUListenerDispose(listener);

    __block unsigned queuedParameterEvents = 0;
    __block unsigned queuedAudioUnitEvents = 0;
    dispatch_queue_t callbackQueue = dispatch_queue_create("finch.audio.listener-test", DISPATCH_QUEUE_SERIAL);
    AUParameterListenerRef queuedParameterListener = NULL;
    AUEventListenerRef queuedEventListener = NULL;
    OSStatus queuedParameterCreate = AUListenerCreateWithDispatchQueue(&queuedParameterListener,
        0, callbackQueue, ^(void *object, const AudioUnitParameter *changedParameter, AudioUnitParameterValue changedValue) {
            (void)object; (void)changedParameter; (void)changedValue;
            queuedParameterEvents++;
        });
    OSStatus queuedEventCreate = AUEventListenerCreateWithDispatchQueue(&queuedEventListener,
        0, 0, callbackQueue, ^(void *object, const AudioUnitEvent *event, UInt64 hostTime, AudioUnitParameterValue value) {
            (void)object; (void)event; (void)hostTime; (void)value;
            queuedAudioUnitEvents++;
        });
    AudioUnitEvent queuedChange = {.mEventType = kAudioUnitEvent_BeginParameterChangeGesture};
    queuedChange.mArgument.mParameter = parameter;
    OSStatus queuedAddParameter = queuedParameterCreate ? queuedParameterCreate :
        AUListenerAddParameter(queuedParameterListener, unit, &parameter);
    OSStatus queuedAddEvent = queuedEventCreate ? queuedEventCreate :
        AUEventListenerAddEventType(queuedEventListener, unit, &queuedChange);
    OSStatus queuedSet = queuedAddParameter || queuedAddEvent ? -50 :
        AUParameterSet(NULL, NULL, &parameter, 67.0f, 0);
    OSStatus queuedNotify = 0;
    dispatch_sync(callbackQueue, ^{});
    printf("AU dispatch listeners %d/%d/%d/%d set %d notify %d callbacks %u/%u\n",
        (int)queuedParameterCreate, (int)queuedEventCreate, (int)queuedAddParameter,
        (int)queuedAddEvent, (int)queuedSet, (int)queuedNotify, queuedParameterEvents, queuedAudioUnitEvents);
    if (queuedEventListener) AUListenerDispose(queuedEventListener);
    if (queuedParameterListener) AUListenerDispose(queuedParameterListener);
    dispatch_release(callbackQueue);
    if (unit) AudioComponentInstanceDispose(unit);

    AudioComponentDescription effectDescription = {kAudioUnitType_Effect,
        kAudioUnitSubType_Delay, kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent effectComponent = AudioComponentFindNext(NULL, &effectDescription);
    AudioUnit effect = NULL;
    OSStatus effectCreate = effectComponent ? AudioComponentInstanceNew(effectComponent, &effect) : -1;
    OSStatus effectInit = effectCreate ? effectCreate : AudioUnitInitialize(effect);
    float leftInput[4] = {0.125f, -0.25f, 0.5f, -0.75f};
    float rightInput[4] = {0.25f, -0.5f, 0.75f, -1.0f};
    float leftOutput[4] = {0}, rightOutput[4] = {0};
    struct { UInt32 count; AudioBuffer buffers[2]; } inputList = {2,
        {{1, sizeof(leftInput), leftInput}, {1, sizeof(rightInput), rightInput}}};
    struct { UInt32 count; AudioBuffer buffers[2]; } outputList = {2,
        {{1, sizeof(leftOutput), leftOutput}, {1, sizeof(rightOutput), rightOutput}}};
    const AudioBufferList *inputLists[] = {(const AudioBufferList *)&inputList};
    AudioBufferList *outputLists[] = {(AudioBufferList *)&outputList};
    AudioTimeStamp processTime = {.mSampleTime = 0, .mFlags = kAudioTimeStampSampleTimeValid};
    AudioUnitRenderActionFlags processFlags = 0;
    OSStatus processMultiple = effectInit ? effectInit : AudioUnitProcessMultiple(effect,
        &processFlags, &processTime, 4, 1, inputLists, 1, outputLists);
    printf("AudioUnitProcessMultiple %d/%d %.3f %.3f\n", (int)effectCreate,
        (int)processMultiple, leftOutput[0], rightOutput[3]);
    AudioUnitRenderActionFlags singleFlags = 0;
    OSStatus process = effectInit ? effectInit : AudioUnitProcess(effect, &singleFlags,
        &processTime, 4, (AudioBufferList *)&outputList);
    printf("AudioUnitProcess %d\n", (int)process);
    if (effect) {
        if (!effectInit) AudioUnitUninitialize(effect);
        AudioComponentInstanceDispose(effect);
    }
}

static void
audio_graph(void)
{
    AUGraph graph = NULL;
    OSStatus status = NewAUGraph(&graph);
    printf("audio graph create %d", (int)status);
    if (status)
        return;
    UInt32 count = 0;
    AUGraphGetNodeCount(graph, &count);
    printf(" nodes %u", (unsigned)count);
    AudioComponentDescription mixerDescription = {kAudioUnitType_Mixer, kAudioUnitSubType_MultiChannelMixer,
        kAudioUnitManufacturer_Apple, 0, 0};
    AUNode mixer = -1, otherMixer = -1, first = -1;
    OSStatus mixerStatus = AUGraphAddNode(graph, &mixerDescription, &mixer);
    OSStatus otherMixerStatus = AUGraphAddNode(graph, &mixerDescription, &otherMixer);
    AUGraphGetIndNode(graph, 0, &first);
    printf(" add %d/%d ids %d/%d first %d", (int)mixerStatus, (int)otherMixerStatus,
           (int)mixer, (int)otherMixer, (int)first);
    OSStatus connectStatus = AUGraphConnectNodeInput(graph, mixer, 0, otherMixer, 0);
    AURenderCallbackStruct inputCallback = {graph_render_callback, NULL};
    OSStatus inputCallbackStatus = AUGraphSetNodeInputCallback(graph, mixer, 0, &inputCallback);
    OSStatus renderNotifyStatus = AUGraphAddRenderNotify(graph, graph_render_callback, NULL);
    UInt32 interactions = 0, connections = 0, nodeInteractions = 0, nodeConnections = 0;
    AUGraphGetNumberOfInteractions(graph, &interactions);
    AUGraphGetNumberOfConnections(graph, &connections);
    AUGraphCountNodeInteractions(graph, mixer, &nodeInteractions);
    AUGraphCountNodeConnections(graph, mixer, &nodeConnections);
    AUNodeInteraction interaction = {0};
    OSStatus interactionStatus = AUGraphGetInteractionInfo(graph, 0, &interaction);
    printf(" connect %d callback %d notify %d interactions %u/%u connections %u/%u details %d %u %d:%u>%d:%u",
           (int)connectStatus, (int)inputCallbackStatus, (int)renderNotifyStatus,
           (unsigned)interactions, (unsigned)nodeInteractions,
           (unsigned)connections, (unsigned)nodeConnections, (int)interactionStatus,
           (unsigned)interaction.nodeInteractionType, (int)interaction.nodeInteraction.connection.sourceNode,
           (unsigned)interaction.nodeInteraction.connection.sourceOutputNumber,
           (int)interaction.nodeInteraction.connection.destNode,
           (unsigned)interaction.nodeInteraction.connection.destInputNumber);
    AUNodeInteraction nodeItems[2] = {{0}};
    UInt32 itemCount = 2;
    OSStatus nodeInteractionsStatus = AUGraphGetNodeInteractions(graph, mixer, &itemCount, nodeItems);
    AudioUnitNodeConnection nodeConnectionsOut[2] = {{0}};
    UInt32 connectionCount = 2;
    OSStatus nodeConnectionsStatus = AUGraphGetNodeConnections(graph, mixer, nodeConnectionsOut, &connectionCount);
    printf(" node-lists %d/%u %d/%u", (int)nodeInteractionsStatus, (unsigned)itemCount,
           (int)nodeConnectionsStatus, (unsigned)connectionCount);
    Boolean isOpen = false, isInitialized = false, isRunning = false, updated = false;
    AUGraphIsOpen(graph, &isOpen);
    AUGraphIsInitialized(graph, &isInitialized);
    AUGraphIsRunning(graph, &isRunning);
    OSStatus updateStatus = AUGraphUpdate(graph, &updated);
    printf(" state %u/%u/%u update %d/%u", (unsigned)isOpen, (unsigned)isInitialized,
           (unsigned)isRunning, (int)updateStatus, (unsigned)updated);
    OSStatus openStatus = AUGraphOpen(graph);
    AUGraphIsOpen(graph, &isOpen);
    AudioComponentDescription gotDescription = {0};
    AudioUnit unit = NULL;
    OSStatus nodeInfoStatus = AUGraphNodeInfo(graph, mixer, &gotDescription, &unit);
    printf(" open %d/%u node-info %d %u:%u:%u unit %u", (int)openStatus, (unsigned)isOpen,
           (int)nodeInfoStatus, (unsigned)gotDescription.componentType, (unsigned)gotDescription.componentSubType,
           (unsigned)gotDescription.componentManufacturer, unit != NULL);
    OSStatus disconnectStatus = AUGraphDisconnectNodeInput(graph, otherMixer, 0);
    OSStatus notifyRemoveStatus = AUGraphRemoveRenderNotify(graph, graph_render_callback, NULL);
    printf(" disconnect %d notify-remove %d", (int)disconnectStatus, (int)notifyRemoveStatus);
    OSStatus initStatus = AUGraphInitialize(graph);
    AUGraphIsInitialized(graph, &isInitialized);
    Float32 cpu = -1, maxCPU = -1;
    OSStatus cpuStatus = AUGraphGetCPULoad(graph, &cpu);
    OSStatus maxCPUStatus = AUGraphGetMaxCPULoad(graph, &maxCPU);
    printf(" initialize %d/%u cpu %d %.3f max %d %.3f", (int)initStatus,
           (unsigned)isInitialized, (int)cpuStatus, cpu, (int)maxCPUStatus, maxCPU);
    OSStatus uninitStatus = AUGraphUninitialize(graph);
    OSStatus clearStatus = AUGraphClearConnections(graph);
    OSStatus closeStatus = AUGraphClose(graph);
    OSStatus removeStatus = AUGraphRemoveNode(graph, mixer);
    OSStatus disposeStatus = DisposeAUGraph(graph);
    printf(" uninitialize %d clear %d close %d remove %d dispose %d\n", (int)uninitStatus,
           (int)clearStatus, (int)closeStatus, (int)removeStatus, (int)disposeStatus);
}

static OSStatus property_listener(AudioObjectID, UInt32,
    const AudioObjectPropertyAddress[], void *);

static void
audio_hardware_service(void)
{
    AudioObjectPropertyAddress address = {kAudioObjectPropertyClass,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioClassID classID = 0;
    UInt32 size = sizeof(classID);
    Boolean settable = true;
    OSStatus getStatus = AudioHardwareServiceGetPropertyData(kAudioObjectSystemObject,
        &address, 0, NULL, &size, &classID);
    OSStatus settableStatus = AudioHardwareServiceIsPropertySettable(kAudioObjectSystemObject,
        &address, &settable);
    OSStatus addStatus = AudioHardwareServiceAddPropertyListener(kAudioObjectSystemObject,
        &address, property_listener, NULL);
    OSStatus removeStatus = AudioHardwareServiceRemovePropertyListener(kAudioObjectSystemObject,
        &address, property_listener, NULL);
    printf("audio hardware service %u %d %u %d settable %d listener %d/%d\n",
        (unsigned)AudioHardwareServiceHasProperty(kAudioObjectSystemObject, &address),
        (int)getStatus, (unsigned)classID, (int)settableStatus, (int)settable,
        (int)addStatus, (int)removeStatus);
}

static OSStatus
property_listener(AudioObjectID objectID, UInt32 count,
    const AudioObjectPropertyAddress addresses[], void *clientData)
{
    return noErr;
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
    global_file_types();
    music_sequence();
    audio_clock();
    audio_unit_utilities();
    audio_graph();
    audio_hardware_service();
    files();
    legacy_file_apis();
    audio_file_stream();
    return 0;
}
