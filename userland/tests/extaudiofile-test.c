/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Compare ExtAudioFile PCM and G.711 reads, writes, seeking and properties with macOS. */
#include <AudioToolbox/AudioToolbox.h>
#include <AudioToolbox/ExtendedAudioFile.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static char directory[128];
static OSStatus (*write_extaudio)(ExtAudioFileRef, UInt32, const AudioBufferList *) = ExtAudioFileWrite;
static bool srcCheckMode;
static UInt32 srcFailures;

#define DETAIL(...) do { if (!srcCheckMode) printf(__VA_ARGS__); } while (0)

static void
src_check(bool passed, const char *name)
{
    if (srcCheckMode && !passed) {
        printf("SRC FAIL %s\n", name);
        srcFailures++;
    }
}

static uint64_t
hash_add(uint64_t value, const void *data, size_t size)
{
    const UInt8 *p = data;
    while (size--)
        value = (value ^ *p++) * UINT64_C(1099511628211);
    return value;
}

static uint64_t
hash_start(void)
{
    return UINT64_C(14695981039346656037);
}

static CFURLRef
file_url(const char *name)
{
    char path[256];
    snprintf(path, sizeof(path), "%s/%s", directory, name);
    return CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
}

static AudioStreamBasicDescription
pcm(UInt32 bits, bool floating, UInt32 channels, bool nonInterleaved, double rate)
{
    UInt32 bytes = bits / 8;
    UInt32 perFrame = nonInterleaved ? bytes : bytes * channels;
    UInt32 flags = kAudioFormatFlagIsPacked | (floating ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger);
    if (nonInterleaved)
        flags |= kAudioFormatFlagIsNonInterleaved;
    return (AudioStreamBasicDescription){rate, kAudioFormatLinearPCM, flags, perFrame, 1, perFrame, channels, bits, 0};
}

static void
print_format(const char *name, ExtAudioFileRef file, ExtAudioFilePropertyID property)
{
    AudioStreamBasicDescription a = {0};
    UInt32 size = sizeof(a);
    OSStatus e = ExtAudioFileGetProperty(file, property, &size, &a);
    printf("%s %d %u %08x %g %u %u %u %u %u %x\n", name, (int)e, (unsigned)size, (unsigned)a.mFormatID,
        a.mSampleRate, (unsigned)a.mBytesPerPacket, (unsigned)a.mFramesPerPacket, (unsigned)a.mBytesPerFrame,
        (unsigned)a.mChannelsPerFrame, (unsigned)a.mBitsPerChannel, (unsigned)a.mFormatFlags);
}

static void
print_length(const char *name, ExtAudioFileRef file)
{
    SInt64 frames = -1;
    UInt32 size = sizeof(frames);
    OSStatus e = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &frames);
    DETAIL("%s %d %u %lld\n", name, (int)e, (unsigned)size, (long long)frames);
}

static void
pcm_round_trip(void)
{
    CFURLRef url = file_url("pcm.wav");
    AudioStreamBasicDescription fileFormat = pcm(16, false, 2, false, 44100);
    AudioChannelLayout stereo = {kAudioChannelLayoutTag_Stereo, 0, 0, {0}};
    ExtAudioFileRef file = NULL;
    OSStatus e = ExtAudioFileCreateWithURL(url, kAudioFileWAVEType, &fileFormat, &stereo,
        kAudioFileFlags_EraseFile, &file);
    CFRelease(url);
    printf("pcm create %d\n", (int)e);
    if (e)
        return;

    AudioStreamBasicDescription client = pcm(32, true, 2, true, 44100);
    e = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client);
    printf("pcm set-client %d\n", (int)e);
    e = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientChannelLayout, sizeof(stereo), &stereo);
    printf("pcm set-client-layout %d\n", (int)e);

    float left[] = {-1, -0.5f, -0.0000152588f, 0.5f};
    float right[] = {1, 0.5f, 0, -0.5f};
    struct { UInt32 count; AudioBuffer buffers[2]; } input = {2, {{1, sizeof(left), left}, {1, sizeof(right), right}}};
    e = ExtAudioFileWrite(file, 4, (const AudioBufferList *)&input);
    printf("pcm write %d\n", (int)e);
    SInt64 position = -1;
    e = ExtAudioFileTell(file, &position);
    printf("pcm write-tell %d %lld\n", (int)e, (long long)position);
    print_length("pcm write-length", file);
    print_format("pcm file-format", file, kExtAudioFileProperty_FileDataFormat);
    print_format("pcm client-format", file, kExtAudioFileProperty_ClientDataFormat);
    UInt32 size = 0;
    Boolean writable = false;
    e = ExtAudioFileGetPropertyInfo(file, kExtAudioFileProperty_FileLengthFrames, &size, &writable);
    printf("pcm length-info %d %u %u\n", (int)e, (unsigned)size, (unsigned)writable);
    UInt32 badSize = 1;
    UInt8 byte = 0;
    e = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &badSize, &byte);
    printf("pcm short-property %d %u\n", (int)e, (unsigned)badSize);
    UInt32 unknownSize = 0;
    e = ExtAudioFileGetPropertyInfo(file, 0x12345678, &unknownSize, NULL);
    printf("pcm unknown-property %d\n", (int)e);
    AudioFilePacketTableInfo packetTable = {0};
    UInt32 shortTableSize = sizeof(packetTable) - 1;
    e = ExtAudioFileGetProperty(file, kExtAudioFileProperty_PacketTable, &shortTableSize, &packetTable);
    printf("pcm short-packet-table %d %u\n", (int)e, (unsigned)shortTableSize);
    printf("pcm dispose %d\n", (int)ExtAudioFileDispose(file));

    url = file_url("pcm.wav");
    file = NULL;
    e = ExtAudioFileOpenURL(url, &file);
    CFRelease(url);
    printf("pcm open %d\n", (int)e);
    if (e)
        return;
    e = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client);
    printf("pcm read-set-client %d\n", (int)e);
    size = 0;
    writable = false;
    e = ExtAudioFileGetPropertyInfo(file, kExtAudioFileProperty_ClientMaxPacketSize, &size, &writable);
    UInt32 clientPacket = 0;
    UInt32 packetSize = sizeof(clientPacket);
    OSStatus packetError = ExtAudioFileGetProperty(file, kExtAudioFileProperty_ClientMaxPacketSize, &packetSize, &clientPacket);
    printf("pcm client-packet %d %u %u %d %u\n", (int)e, (unsigned)size, (unsigned)writable, (int)packetError, (unsigned)clientPacket);

    float readLeft[6] = {0}, readRight[6] = {0};
    struct { UInt32 count; AudioBuffer buffers[2]; } output = {2, {{1, sizeof(readLeft), readLeft}, {1, sizeof(readRight), readRight}}};
    UInt32 frames = 6;
    e = ExtAudioFileRead(file, &frames, (AudioBufferList *)&output);
    uint64_t h = hash_add(hash_start(), readLeft, frames * sizeof(float));
    h = hash_add(h, readRight, frames * sizeof(float));
    printf("pcm read %d %u %u %u %016llx\n", (int)e, (unsigned)frames,
        (unsigned)output.buffers[0].mDataByteSize, (unsigned)output.buffers[1].mDataByteSize, (unsigned long long)h);
    e = ExtAudioFileTell(file, &position);
    printf("pcm tell %d %lld\n", (int)e, (long long)position);
    printf("pcm seek-2 %d\n", (int)ExtAudioFileSeek(file, 2));
    e = ExtAudioFileTell(file, &position);
    printf("pcm tell-after-seek %d %lld\n", (int)e, (long long)position);
    memset(readLeft, 0, sizeof(readLeft));
    memset(readRight, 0, sizeof(readRight));
    frames = 2;
    e = ExtAudioFileRead(file, &frames, (AudioBufferList *)&output);
    h = hash_add(hash_start(), readLeft, frames * sizeof(float));
    h = hash_add(h, readRight, frames * sizeof(float));
    printf("pcm seek-read %d %u %016llx\n", (int)e, (unsigned)frames, (unsigned long long)h);
    printf("pcm seek-negative %d\n", (int)ExtAudioFileSeek(file, -1));
    frames = 1;
    e = ExtAudioFileRead(file, &frames, (AudioBufferList *)&output);
    printf("pcm eof %d %u\n", (int)e, (unsigned)frames);
    printf("pcm dispose-reader %d\n", (int)ExtAudioFileDispose(file));

    url = file_url("pcm.wav");
    AudioFileID audioFile = NULL;
    e = AudioFileOpenURL(url, kAudioFileReadPermission, 0, &audioFile);
    CFRelease(url);
    ExtAudioFileRef wrapped = NULL;
    OSStatus wrap = e ? e : ExtAudioFileWrapAudioFileID(audioFile, false, &wrapped);
    printf("pcm wrap %d\n", (int)wrap);
    if (!wrap) {
        printf("pcm wrapped-dispose %d\n", (int)ExtAudioFileDispose(wrapped));
        AudioStreamBasicDescription underlying = {0};
        size = sizeof(underlying);
        e = AudioFileGetProperty(audioFile, kAudioFilePropertyDataFormat, &size, &underlying);
        printf("pcm wrap-kept-file %d %u %08x\n", (int)e, (unsigned)size, (unsigned)underlying.mFormatID);
    }
    if (audioFile)
        printf("pcm close-wrapped-file %d\n", (int)AudioFileClose(audioFile));
}

static void
g711_round_trip(AudioFormatID format, const char *name)
{
    char filename[32];
    snprintf(filename, sizeof(filename), "%s.wav", name);
    CFURLRef url = file_url(filename);
    AudioStreamBasicDescription fileFormat = {8000, format, 0, 1, 1, 1, 1, 8, 0};
    AudioChannelLayout mono = {kAudioChannelLayoutTag_Mono, 0, 0, {0}};
    ExtAudioFileRef file = NULL;
    OSStatus e = ExtAudioFileCreateWithURL(url, kAudioFileWAVEType, &fileFormat, &mono,
        kAudioFileFlags_EraseFile, &file);
    CFRelease(url);
    printf("%s create %d\n", name, (int)e);
    if (e)
        return;
    AudioStreamBasicDescription client = pcm(16, false, 1, false, 8000);
    e = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client);
    printf("%s set-client %d\n", name, (int)e);
    int16_t source[] = {-32768, -20000, -10000, -1, 0, 1, 10000, 32767};
    AudioBufferList input = {1, {{1, sizeof(source), source}}};
    e = ExtAudioFileWrite(file, 8, &input);
    printf("%s write %d\n", name, (int)e);
    print_length("g711 write-length", file);
    printf("%s dispose-writer %d\n", name, (int)ExtAudioFileDispose(file));

    url = file_url(filename);
    file = NULL;
    e = ExtAudioFileOpenURL(url, &file);
    CFRelease(url);
    printf("%s open %d\n", name, (int)e);
    if (e)
        return;
    e = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client);
    printf("%s read-set-client %d\n", name, (int)e);
    int16_t result[10] = {0};
    AudioBufferList output = {1, {{1, sizeof(result), result}}};
    UInt32 frames = 10;
    e = ExtAudioFileRead(file, &frames, &output);
    printf("%s read %d %u %u %016llx\n", name, (int)e, (unsigned)frames, (unsigned)output.mBuffers[0].mDataByteSize,
        (unsigned long long)hash_add(hash_start(), result, frames * sizeof(*result)));
    printf("%s dispose-reader %d\n", name, (int)ExtAudioFileDispose(file));
}

static void
sample_rate_read(void)
{
    CFURLRef url = file_url("rate.wav");
    AudioStreamBasicDescription fileFormat = pcm(16, false, 1, false, 44100);
    ExtAudioFileRef file = NULL;
    OSStatus e = ExtAudioFileCreateWithURL(url, kAudioFileWAVEType, &fileFormat, NULL,
        kAudioFileFlags_EraseFile, &file);
    CFRelease(url);
    DETAIL("rate create %d\n", (int)e);
    src_check(e == noErr, "read-create");
    if (e)
        return;
    int16_t source[1000];
    for (UInt32 i = 0; i < 1000; i++)
        source[i] = (int16_t)((i * 73) % 30001 - 15000);
    AudioBufferList input = {1, {{1, sizeof(source), source}}};
    e = ExtAudioFileWrite(file, 1000, &input);
    DETAIL("rate write %d\n", (int)e);
    src_check(e == noErr, "read-seed-write");
    OSStatus closeError = ExtAudioFileDispose(file);
    DETAIL("rate writer-dispose %d\n", (int)closeError);
    src_check(closeError == noErr, "read-seed-close");
    if (e || closeError)
        return;

    url = file_url("rate.wav");
    file = NULL;
    e = ExtAudioFileOpenURL(url, &file);
    CFRelease(url);
    DETAIL("rate open %d\n", (int)e);
    src_check(e == noErr, "read-open");
    if (e)
        return;
    AudioStreamBasicDescription client = pcm(16, false, 1, false, 48000);
    e = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client);
    DETAIL("rate set-client %d\n", (int)e);
    src_check(e == noErr, "read-set-client");
    if (e) {
        ExtAudioFileDispose(file);
        return;
    }
    int16_t first[100] = {0}, second[100] = {0}, again[100] = {0};
    AudioBufferList output = {1, {{1, sizeof(first), first}}};
    UInt32 frames = 100;
    e = ExtAudioFileRead(file, &frames, &output);
    src_check(e == noErr && frames == 100, "read-first-chunk");
    uint64_t firstHash = hash_add(hash_start(), first, frames * sizeof(*first));
    DETAIL("rate short-read-1 %d %u %016llx\n", (int)e, (unsigned)frames, (unsigned long long)firstHash);
    output.mBuffers[0].mData = second;
    output.mBuffers[0].mDataByteSize = sizeof(second);
    frames = 100;
    e = ExtAudioFileRead(file, &frames, &output);
    src_check(e == noErr && frames == 100, "read-second-chunk");
    DETAIL("rate short-read-2 %d %u %016llx\n", (int)e, (unsigned)frames,
        (unsigned long long)hash_add(hash_start(), second, frames * sizeof(*second)));
    SInt64 position = -1;
    e = ExtAudioFileTell(file, &position);
    src_check(e == noErr && position == 183, "read-tell-after-chunks");
    DETAIL("rate tell-after-short-reads %d %lld\n", (int)e, (long long)position);
    OSStatus seekError = ExtAudioFileSeek(file, 0);
    DETAIL("rate seek-start %d\n", (int)seekError);
    src_check(seekError == noErr, "read-seek-start");
    output.mBuffers[0].mData = again;
    output.mBuffers[0].mDataByteSize = sizeof(again);
    frames = 100;
    e = ExtAudioFileRead(file, &frames, &output);
    src_check(e == noErr && frames == 100 && firstHash == hash_add(hash_start(), again, frames * sizeof(*again)),
        "read-reset-stability");
    uint64_t againHash = hash_add(hash_start(), again, frames * sizeof(*again));
    DETAIL("rate after-seek %d %u %016llx %u\n", (int)e, (unsigned)frames,
        (unsigned long long)againHash, (unsigned)(againHash == firstHash));
    seekError = ExtAudioFileSeek(file, 0);
    DETAIL("rate reset-after-short-reads %d\n", (int)seekError);
    src_check(seekError == noErr, "read-reset-to-start");
    int16_t tail[1200] = {0};
    output.mBuffers[0].mData = tail;
    output.mBuffers[0].mDataByteSize = sizeof(tail);
    frames = 1200;
    e = ExtAudioFileRead(file, &frames, &output);
    src_check(e == noErr && frames == 1088, "read-final-tail");
    DETAIL("rate eof-read %d %u %u\n", (int)e, (unsigned)frames,
        (unsigned)output.mBuffers[0].mDataByteSize);
    e = ExtAudioFileTell(file, &position);
    src_check(e == noErr && position == 999, "read-tell-at-eof");
    DETAIL("rate tell-at-eof %d %lld\n", (int)e, (long long)position);
    frames = 1;
    e = ExtAudioFileRead(file, &frames, &output);
    src_check(e == noErr && frames == 0, "read-eof-again");
    DETAIL("rate eof-again %d %u\n", (int)e, (unsigned)frames);
    seekError = ExtAudioFileSeek(file, 400);
    DETAIL("rate seek-400 %d\n", (int)seekError);
    src_check(seekError == noErr, "read-seek-offset");
    frames = 100;
    output.mBuffers[0].mDataByteSize = sizeof(again);
    OSStatus readError = ExtAudioFileRead(file, &frames, &output);
    uint64_t offsetHash = hash_add(hash_start(), tail, frames * sizeof(*tail));
    OSStatus tellError = ExtAudioFileTell(file, &position);
    src_check(readError == noErr && frames == 100 && tellError == noErr && position == 491,
        "read-seek-offset-result");
    DETAIL("rate nonzero-seek-read %d %u %016llx tell %d %lld\n", (int)readError, (unsigned)frames,
        (unsigned long long)offsetHash, (int)tellError, (long long)position);
    seekError = ExtAudioFileSeek(file, 400);
    DETAIL("rate seek-400-again %d\n", (int)seekError);
    src_check(seekError == noErr, "read-seek-offset-reset");
    memset(tail, 0, sizeof(tail));
    output.mBuffers[0].mDataByteSize = sizeof(tail);
    frames = 100;
    readError = ExtAudioFileRead(file, &frames, &output);
    uint64_t offsetAgainHash = hash_add(hash_start(), tail, frames * sizeof(*tail));
    src_check(readError == noErr && frames == 100 && offsetHash == offsetAgainHash,
        "read-offset-reset-stability");
    DETAIL("rate nonzero-seek-reset %d %u %u\n", (int)readError, (unsigned)frames, (unsigned)(offsetHash == offsetAgainHash));
    closeError = ExtAudioFileDispose(file);
    DETAIL("rate dispose-reader %d\n", (int)closeError);
    src_check(closeError == noErr, "read-close");
}

struct WriteCheck {
    SInt64 frames;
    UInt32 readFrames;
    uint64_t hash;
    OSStatus readError;
    OSStatus status;
};

static struct WriteCheck
sample_rate_write_case(const char *tag, const char *filename, double fileRate, double clientRate,
    UInt32 inputFrames, const UInt32 *chunks, UInt32 chunkCount, bool checkZero)
{
    struct WriteCheck result = {-1, 0, hash_start(), -1, -1};
    CFURLRef url = file_url(filename);
    AudioStreamBasicDescription fileFormat = pcm(16, false, 1, false, fileRate);
    ExtAudioFileRef file = NULL;
    OSStatus e = ExtAudioFileCreateWithURL(url, kAudioFileWAVEType, &fileFormat, NULL,
        kAudioFileFlags_EraseFile, &file);
    CFRelease(url);
    DETAIL("%s create %d\n", tag, (int)e);
    src_check(e == noErr, "write-case-create");
    if (e)
        return result;
    AudioStreamBasicDescription client = pcm(16, false, 1, false, clientRate);
    e = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client);
    DETAIL("%s set-client %d\n", tag, (int)e);
    src_check(e == noErr, "write-case-set-client");
    if (e) {
        ExtAudioFileDispose(file);
        return result;
    }
    int16_t *source = calloc(inputFrames ? inputFrames : 1, sizeof(*source));
    if (!source) {
        src_check(false, "write-case-allocate-input");
        ExtAudioFileDispose(file);
        return result;
    }
    for (UInt32 i = 0; i < inputFrames; i++)
        source[i] = (int16_t)((i * 97) % 30001 - 15000);
    if (!e && checkZero) {
        OSStatus zeroNullError = write_extaudio(file, 0, NULL);
        DETAIL("%s zero-null %d\n", tag, (int)zeroNullError);
        src_check(zeroNullError == kAudio_ParamError, "write-zero-null-error");
        AudioBufferList empty = {1, {{1, 0, source}}};
        OSStatus zeroValidError = ExtAudioFileWrite(file, 0, &empty);
        DETAIL("%s zero-valid %d\n", tag, (int)zeroValidError);
        src_check(zeroValidError == noErr, "write-zero-valid-no-op");
    }
    UInt32 offset = 0;
    for (UInt32 i = 0; !e && i < chunkCount; i++) {
        UInt32 count = chunks[i];
        if (count > inputFrames - offset) {
            e = kAudio_ParamError;
            break;
        }
        AudioBufferList input = {1, {{1, count * sizeof(*source), source + offset}}};
        e = ExtAudioFileWrite(file, count, &input);
        src_check(e == noErr, "write-case-chunk");
        DETAIL("%s write-%u %d %u\n", tag, (unsigned)i, (int)e, (unsigned)count);
        offset += count;
    }
    src_check(offset == inputFrames, "write-case-input-count");
    SInt64 position = -1;
    OSStatus tellError = ExtAudioFileTell(file, &position);
    src_check(tellError == noErr, "write-case-tell");
    DETAIL("%s tell-before-close %d %lld\n", tag, (int)tellError, (long long)position);
    SInt64 beforeLength = -1;
    UInt32 beforeSize = sizeof(beforeLength);
    OSStatus beforeError = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames,
        &beforeSize, &beforeLength);
    src_check(beforeError == noErr, "write-case-length-before-close");
    DETAIL("%s length-before-close %d %lld\n", tag, (int)beforeError, (long long)beforeLength);
    OSStatus disposeError = ExtAudioFileDispose(file);
    src_check(disposeError == noErr, "write-case-dispose");
    DETAIL("%s writer-dispose %d\n", tag, (int)disposeError);
    free(source);

    url = file_url(filename);
    file = NULL;
    e = ExtAudioFileOpenURL(url, &file);
    CFRelease(url);
    DETAIL("%s reopen %d\n", tag, (int)e);
    src_check(e == noErr, "write-case-reopen");
    if (e)
        return result;
    SInt64 frames = -1;
    UInt32 size = sizeof(frames);
    e = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &frames);
    src_check(e == noErr, "write-case-length-after-close");
    DETAIL("%s length-after-close %d %lld\n", tag, (int)e, (long long)frames);
    if (!e && frames >= 0 && frames <= (SInt64)(UINT32_MAX / sizeof(int16_t))) {
        int16_t *output = calloc(frames ? (size_t)frames : 1, sizeof(*output));
        if (output) {
            AudioBufferList data = {1, {{1, (UInt32)frames * sizeof(*output), output}}};
            UInt32 readFrames = (UInt32)frames;
            result.readError = ExtAudioFileRead(file, &readFrames, &data);
            result.frames = frames;
            result.readFrames = readFrames;
            result.hash = hash_add(hash_start(), output, readFrames * sizeof(*output));
            src_check(result.readError == noErr && readFrames == (UInt32)frames, "write-case-readback");
            DETAIL("%s readback %d %u %016llx\n", tag, (int)result.readError, (unsigned)readFrames,
                (unsigned long long)result.hash);
            free(output);
        } else {
            src_check(false, "write-case-allocate-output");
        }
    }
    result.status = e;
    disposeError = ExtAudioFileDispose(file);
    src_check(disposeError == noErr, "write-case-reader-dispose");
    DETAIL("%s reader-dispose %d\n", tag, (int)disposeError);
    return result;
}

static void
sample_rate_write_chunks(void)
{
    const UInt32 irregular[] = {123, 0, 333, 544};
    const UInt32 whole[] = {1000};
    const UInt32 one1001[] = {1001};
    const UInt32 one1002[] = {1002};
    const UInt32 exactIrregular[] = {123, 333, 544};
    struct WriteCheck a = sample_rate_write_case("rate-chunks", "rate-write-chunks.wav",
        44100, 48000, 1000, irregular, sizeof(irregular) / sizeof(irregular[0]), true);
    struct WriteCheck b = sample_rate_write_case("rate-whole", "rate-write-whole.wav",
        44100, 48000, 1000, whole, sizeof(whole) / sizeof(whole[0]), false);
    src_check(a.status == noErr && b.status == noErr && a.readError == noErr && b.readError == noErr,
        "write-chunk-cases-complete");
    src_check(a.frames == b.frames && a.readFrames == b.readFrames && a.hash == b.hash,
        "write-chunk-stability");
    src_check(llabs(a.frames - 919) <= 1, "write-final-tail-count-tolerance");
    DETAIL("rate-chunks same-output %u %u %u\n", (unsigned)(a.frames == b.frames),
        (unsigned)(a.readFrames == b.readFrames), (unsigned)(a.hash == b.hash));
    struct WriteCheck one = sample_rate_write_case("rate-1001", "rate-write-1001.wav",
        44100, 48000, 1001, one1001, 1, false);
    struct WriteCheck two = sample_rate_write_case("rate-1002", "rate-write-1002.wav",
        44100, 48000, 1002, one1002, 1, false);
    src_check(one.status == noErr && two.status == noErr && one.readError == noErr && two.readError == noErr,
        "write-fractional-cases-complete");
    src_check(llabs(one.frames - 920) <= 1 && llabs(two.frames - 921) <= 1,
        "write-fractional-count-tolerance");
    DETAIL("rate-fractional within-one-frame %u %u %lld %lld\n",
        (unsigned)(llabs(one.frames - 920) <= 1), (unsigned)(llabs(two.frames - 921) <= 1),
        (long long)one.frames, (long long)two.frames);

    struct WriteCheck c = sample_rate_write_case("rate-exact-chunks", "rate-exact-chunks.wav",
        24000, 48000, 1000, exactIrregular, sizeof(exactIrregular) / sizeof(exactIrregular[0]), false);
    struct WriteCheck d = sample_rate_write_case("rate-exact-whole", "rate-exact-whole.wav",
        24000, 48000, 1000, whole, sizeof(whole) / sizeof(whole[0]), false);
    src_check(c.status == noErr && d.status == noErr && c.readError == noErr && d.readError == noErr,
        "write-exact-cases-complete");
    src_check(c.frames == 500 && d.frames == 500, "write-exact-frame-count");
    src_check(c.frames == d.frames && c.readFrames == d.readFrames && c.hash == d.hash,
        "write-exact-chunk-stability");
    DETAIL("rate-exact expected-count %u %lld\n", (unsigned)(c.frames == 500), (long long)c.frames);
    DETAIL("rate-exact same-output %u %u %u\n", (unsigned)(c.frames == d.frames),
        (unsigned)(c.readFrames == d.readFrames), (unsigned)(c.hash == d.hash));
}

static void
sample_rate_write_format_change(void)
{
    CFURLRef url = file_url("rate-write-format-change.wav");
    AudioStreamBasicDescription fileFormat = pcm(16, false, 1, false, 44100);
    ExtAudioFileRef file = NULL;
    OSStatus e = ExtAudioFileCreateWithURL(url, kAudioFileWAVEType, &fileFormat, NULL,
        kAudioFileFlags_EraseFile, &file);
    CFRelease(url);
    DETAIL("rate-change-write create %d\n", (int)e);
    src_check(e == noErr, "write-format-change-create");
    if (e)
        return;
    AudioStreamBasicDescription convertedClient = pcm(16, false, 1, false, 48000);
    e = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
        sizeof(convertedClient), &convertedClient);
    DETAIL("rate-change-write set-src-client %d\n", (int)e);
    src_check(e == noErr, "write-format-change-set-src");
    int16_t samples[1000];
    for (UInt32 i = 0; i < 1000; i++)
        samples[i] = (int16_t)((i * 97) % 30001 - 15000);
    AudioBufferList firstHalf = {1, {{1, 500 * sizeof(*samples), samples}}};
    if (!e)
        e = ExtAudioFileWrite(file, 500, &firstHalf);
    DETAIL("rate-change-write first-half %d\n", (int)e);
    src_check(e == noErr, "write-format-change-first-half");
    AudioStreamBasicDescription directClient = pcm(16, false, 1, false, 44100);
    if (!e)
        e = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
            sizeof(directClient), &directClient);
    DETAIL("rate-change-write set-direct-client %d\n", (int)e);
    src_check(e == noErr, "write-format-change-set-direct");
    SInt64 position = -1;
    OSStatus tellError = ExtAudioFileTell(file, &position);
    DETAIL("rate-change-write tell-after-change %d %lld\n", (int)tellError, (long long)position);
    src_check(tellError == noErr && position > 0, "write-format-change-tell");
    AudioBufferList secondHalf = {1, {{1, 500 * sizeof(*samples), samples + 500}}};
    if (!e)
        e = ExtAudioFileWrite(file, 500, &secondHalf);
    tellError = ExtAudioFileTell(file, &position);
    DETAIL("rate-change-write second-half %d tell %d %lld\n", (int)e, (int)tellError, (long long)position);
    src_check(e == noErr && tellError == noErr, "write-format-change-second-half");
    OSStatus disposeError = ExtAudioFileDispose(file);
    DETAIL("rate-change-write writer-dispose %d\n", (int)disposeError);
    src_check(disposeError == noErr, "write-format-change-dispose");

    url = file_url("rate-write-format-change.wav");
    file = NULL;
    e = ExtAudioFileOpenURL(url, &file);
    CFRelease(url);
    DETAIL("rate-change-write reopen %d\n", (int)e);
    src_check(e == noErr, "write-format-change-reopen");
    if (!e) {
        SInt64 frames = -1;
        UInt32 size = sizeof(frames);
        OSStatus lengthError = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &frames);
        DETAIL("rate-change-write length-after-close %d %lld\n", (int)lengthError, (long long)frames);
        src_check(lengthError == noErr && frames > 0,
            "write-format-change-final-file");
        disposeError = ExtAudioFileDispose(file);
        DETAIL("rate-change-write reader-dispose %d\n", (int)disposeError);
        src_check(disposeError == noErr, "write-format-change-reader-dispose");
    }
}

static void
src_write_error_check(void)
{
    CFURLRef url = file_url("rate-write-chunks.wav");
    AudioFileID underlying = NULL;
    OSStatus e = AudioFileOpenURL(url, kAudioFileReadPermission, 0, &underlying);
    CFRelease(url);
    src_check(e == noErr, "write-error-open-read-only");
    if (e)
        return;
    ExtAudioFileRef file = NULL;
    e = ExtAudioFileWrapAudioFileID(underlying, true, &file);
    src_check(e == noErr, "write-error-wrap");
    if (!e) {
        AudioStreamBasicDescription client = pcm(16, false, 1, false, 44100);
        e = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client);
        src_check(e == noErr, "write-error-set-client");
        int16_t sample = 0;
        AudioBufferList data = {1, {{1, sizeof(sample), &sample}}};
        OSStatus writeError = e ? e : ExtAudioFileWrite(file, 1, &data);
        src_check(writeError != noErr, "write-error-reported");
        OSStatus disposeError = ExtAudioFileDispose(file);
        src_check(disposeError == noErr, "write-error-dispose-status");
    }
    OSStatus closeError = AudioFileClose(underlying);
    src_check(closeError == noErr, "write-error-close-underlying");
}

static void
errors(void)
{
    CFURLRef url = file_url("missing.wav");
    ExtAudioFileRef file = NULL;
    OSStatus e = ExtAudioFileOpenURL(url, &file);
    CFRelease(url);
    printf("missing open %d\n", (int)e);

    url = file_url("pcm.wav");
    e = ExtAudioFileOpenURL(url, &file);
    CFRelease(url);
    if (e) {
        printf("errors open %d\n", (int)e);
        return;
    }
    AudioStreamBasicDescription nonPCM = {44100, kAudioFormatULaw, 0, 1, 1, 1, 1, 8, 0};
    printf("non-pcm-client %d\n", (int)ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof(nonPCM), &nonPCM));
    UInt32 shortSize = 4;
    printf("short-client %d\n", (int)ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, shortSize, &nonPCM));
    AudioStreamBasicDescription wrongRate = pcm(16, false, 2, false, 48000);
    printf("rate-change %d\n", (int)ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof(wrongRate), &wrongRate));
    AudioStreamBasicDescription client = pcm(16, false, 2, false, 44100);
    printf("set-client %d\n", (int)ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client));
    UInt32 frames = 1;
    int16_t sample[2] = {0};
    AudioBufferList output = {1, {{2, sizeof(sample), sample}}};
    printf("read %d\n", (int)ExtAudioFileRead(file, &frames, &output));
    printf("set-after-read %d\n", (int)ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client));
    printf("errors dispose %d\n", (int)ExtAudioFileDispose(file));

    url = file_url("pcm.wav");
    AudioFileID readOnlyFile = NULL;
    e = AudioFileOpenURL(url, kAudioFileReadPermission, 0, &readOnlyFile);
    CFRelease(url);
    ExtAudioFileRef wrappedWriter = NULL;
    OSStatus wrapError = e ? e : ExtAudioFileWrapAudioFileID(readOnlyFile, true, &wrappedWriter);
    printf("read-only wrap-writer %d\n", (int)wrapError);
    if (!wrapError) {
        e = ExtAudioFileSetProperty(wrappedWriter, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client);
        printf("read-only writer-set-client %d\n", (int)e);
        AudioBufferList input = {1, {{2, sizeof(sample), sample}}};
        OSStatus writeError = e ? e : ExtAudioFileWrite(wrappedWriter, 1, &input);
        printf("read-only writer-write %d\n", (int)writeError);
        printf("read-only writer-dispose %d\n", (int)ExtAudioFileDispose(wrappedWriter));
    }
    if (readOnlyFile)
        printf("read-only close-underlying %d\n", (int)AudioFileClose(readOnlyFile));
}

int
main(int argc, char **argv)
{
    bool srcMode = argc == 2 && !strcmp(argv[1], "--src-check");
    if (argc > 2 || (argc == 2 && !srcMode)) {
        fprintf(stderr, "usage: %s [--src-check]\n", argv[0]);
        return 2;
    }
    snprintf(directory, sizeof(directory), "/tmp/finch-extaudiofile-test.%d", (int)getpid());
    if (mkdir(directory, 0755) && access(directory, F_OK))
        return 1;
    printf("ExtAudioFile contract comparison\n");
    if (srcMode) {
        srcCheckMode = true;
        sample_rate_read();
        sample_rate_write_chunks();
        sample_rate_write_format_change();
        src_write_error_check();
        if (srcFailures) {
            printf("SRC CHECK FAIL %u\n", (unsigned)srcFailures);
            return 1;
        }
        printf("SRC CHECK PASS read-reset final-tail chunk-stability fractional-counts exact-ratio format-change error-propagation\n");
        return 0;
    }
    pcm_round_trip();
    g711_round_trip(kAudioFormatULaw, "ulaw");
    g711_round_trip(kAudioFormatALaw, "alaw");
    errors();
    return 0;
}
