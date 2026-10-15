/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Compare PCM, G.711, channel maps and callback conversion with the host. */
#include <AudioToolbox/AudioToolbox.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static AudioStreamBasicDescription
pcm_rate(double rate, UInt32 bits, bool floating, UInt32 channels)
{
    UInt32 flags = kAudioFormatFlagIsPacked | (floating ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger);
    AudioStreamBasicDescription a = {rate, kAudioFormatLinearPCM, flags, channels * bits / 8, 1, channels * bits / 8, channels, bits, 0};
    return a;
}

static AudioStreamBasicDescription
pcm(UInt32 bits, bool floating, UInt32 channels)
{
    return pcm_rate(44100, bits, floating, channels);
}

static void
check(OSStatus status)
{
    if (status) {
        fprintf(stderr, "unexpected audio error: %d\n", (int)status);
        exit(1);
    }
}

static uint64_t
hash(const void *data, size_t size)
{
    uint64_t value = UINT64_C(14695981039346656037);
    const UInt8 *p = data;
    while (size--)
        value = (value ^ *p++) * UINT64_C(1099511628211);
    return value;
}

static void
convert(const char *label, AudioStreamBasicDescription input, AudioStreamBasicDescription output, const void *samples, UInt32 bytes)
{
    AudioConverterRef c;
    check(AudioConverterNew(&input, &output, &c));
    UInt32 size = bytes / input.mBytesPerFrame * output.mBytesPerFrame;
    void *result = calloc(1, size);
    if (!result)
        exit(1);
    check(AudioConverterConvertBuffer(c, bytes, samples, &size, result));
    printf("%s %u %016llx\n", label, size, (unsigned long long)hash(result, size));
    free(result);
    check(AudioConverterDispose(c));
}

struct Feed {
    const int16_t *samples;
    UInt32 count, at, calls;
    OSStatus end;
};

static OSStatus
feed(AudioConverterRef c, UInt32 *packets, AudioBufferList *data, AudioStreamPacketDescription **descriptions, void *user)
{
    (void)c;
    (void)descriptions;
    struct Feed *f = user;
    f->calls++;
    if (*packets > 3)
        *packets = 3;
    if (*packets > f->count - f->at)
        *packets = f->count - f->at;
    data->mNumberBuffers = 1;
    data->mBuffers[0] = (AudioBuffer){1, *packets * 2, (void *)(f->samples + f->at)};
    f->at += *packets;
    return *packets ? noErr : f->end;
}

struct RateFeed {
    const int16_t *samples;
    UInt32 count, at, calls, chunk;
};

static OSStatus
rate_feed(AudioConverterRef c, UInt32 *packets, AudioBufferList *data,
    AudioStreamPacketDescription **descriptions, void *user)
{
    (void)c;
    (void)descriptions;
    struct RateFeed *f = user;
    f->calls++;
    if (*packets > f->chunk)
        *packets = f->chunk;
    if (*packets > f->count - f->at)
        *packets = f->count - f->at;
    data->mNumberBuffers = 1;
    data->mBuffers[0] = (AudioBuffer){1, *packets * sizeof(*f->samples), (void *)(f->samples + f->at)};
    f->at += *packets;
    return noErr;
}

static UInt32
run_rate(AudioStreamBasicDescription input, AudioStreamBasicDescription output,
    const int16_t *samples, UInt32 sampleCount, UInt32 chunk, int16_t *result, UInt32 capacity)
{
    AudioConverterRef c;
    check(AudioConverterNew(&input, &output, &c));
    struct RateFeed f = {samples, sampleCount, 0, 0, chunk};
    AudioBufferList list = {1, {{1, capacity * sizeof(*result), result}}};
    UInt32 count = capacity;
    check(AudioConverterFillComplexBuffer(c, rate_feed, &f, &count, &list, NULL));
    check(AudioConverterDispose(c));
    return count;
}

static double
rms(const int16_t *samples, UInt32 begin, UInt32 end)
{
    double energy = 0;
    for (UInt32 i = begin; i < end; i++)
        energy += (double)samples[i] * samples[i];
    return sqrt(energy / (end - begin));
}

static OSStatus
fill_rate_once(AudioConverterRef c, struct RateFeed *f, UInt32 capacity, int16_t *result, UInt32 *written)
{
    AudioBufferList list = {1, {{1, capacity * sizeof(*result), result}}};
    *written = capacity;
    OSStatus status = AudioConverterFillComplexBuffer(c, rate_feed, f, written, &list, NULL);
    return status;
}

static void
resampling(void)
{
    AudioStreamBasicDescription input = pcm_rate(44100, 16, false, 1);
    AudioStreamBasicDescription output = pcm_rate(48000, 16, false, 1);
    int16_t samples[97];
    for (UInt32 i = 0; i < 97; i++)
        samples[i] = (int16_t)((int)i * 503 - 24000);
    int16_t whole[160] = {0}, chunks[160] = {0}, reset[160] = {0};
    AudioConverterRef c;
    check(AudioConverterNew(&input, &output, &c));

    struct RateFeed f = {samples, 97, 0, 0, 13};
    UInt32 wholeCount = 0;
    check(fill_rate_once(c, &f, 160, whole, &wholeCount));

    check(AudioConverterReset(c));
    f = (struct RateFeed){samples, 97, 0, 0, 13};
    UInt32 caps[] = {7, 19, 11, 31, 64};
    UInt32 chunkCount = 0, calls = 0;
    while (chunkCount < 160) {
        UInt32 cap = caps[calls % (sizeof(caps) / sizeof(*caps))];
        if (cap > 160 - chunkCount)
            cap = 160 - chunkCount;
        UInt32 written = 0;
        check(fill_rate_once(c, &f, cap, chunks + chunkCount, &written));
        calls++;
        if (!written)
            break;
        chunkCount += written;
    }
    UInt32 chunkCalls = f.calls;

    check(AudioConverterReset(c));
    f = (struct RateFeed){samples, 97, 0, 0, 13};
    UInt32 resetCount = 0;
    check(fill_rate_once(c, &f, 160, reset, &resetCount));
    check(AudioConverterDispose(c));
    int chunkStable = chunkCalls > 1 && wholeCount == chunkCount &&
        !memcmp(whole, chunks, wholeCount * sizeof(*whole));
    int resetStable = wholeCount == resetCount && !memcmp(whole, reset, wholeCount * sizeof(*whole));
    if (wholeCount != 105 || chunkCount != 105 || resetCount != 105 || !chunkStable || !resetStable) {
        fprintf(stderr, "SRC frame/chunk/reset check failed: %u %u %u, short callbacks %u\n",
            wholeCount, chunkCount, resetCount, chunkCalls);
        exit(1);
    }
    printf("rate frames %u %u %u chunk-stable %d reset-stable %d\n", wholeCount, chunkCount, resetCount,
        chunkStable, resetStable);

    int16_t dc[4800];
    for (UInt32 i = 0; i < 4800; i++)
        dc[i] = 12000;
    int16_t dcOut[900] = {0};
    UInt32 dcCount = run_rate(pcm_rate(48000, 16, false, 1), pcm_rate(8000, 16, false, 1),
        dc, 4800, 257, dcOut, 900);
    UInt32 maxDCError = 0;
    for (UInt32 i = 20; i + 20 < dcCount; i++) {
        UInt32 error = (UInt32)abs(dcOut[i] - 12000);
        if (error > maxDCError)
            maxDCError = error;
    }

    int16_t tone[4800];
    for (UInt32 i = 0; i < 4800; i++)
        tone[i] = (int16_t)lrint(12000.0 * sin(2.0 * M_PI * 1000.0 * i / 48000.0));
    int16_t pass[900] = {0};
    UInt32 passCount = run_rate(pcm_rate(48000, 16, false, 1), pcm_rate(8000, 16, false, 1),
        tone, 4800, 257, pass, 900);
    for (UInt32 i = 0; i < 4800; i++)
        tone[i] = (int16_t)lrint(12000.0 * sin(2.0 * M_PI * 12000.0 * i / 48000.0));
    int16_t stop[900] = {0};
    UInt32 stopCount = run_rate(pcm_rate(48000, 16, false, 1), pcm_rate(8000, 16, false, 1),
        tone, 4800, 257, stop, 900);
    double passRms = rms(pass, 20, passCount - 20);
    double stopRms = rms(stop, 20, stopCount - 20);
    if (dcCount != 800 || maxDCError > 400 || passCount != 800 || stopCount != 800 ||
        passRms <= 5000 || stopRms * 5 >= passRms) {
        fprintf(stderr, "SRC signal check failed: DC frames=%u max-error=%u, pass frames=%u RMS=%.1f, "
            "stop frames=%u RMS=%.1f\n", dcCount, maxDCError, passCount, passRms, stopCount, stopRms);
        exit(1);
    }
    printf("rate signal %u %u DC %d pass %d alias-rejected %d\n", dcCount, passCount, maxDCError <= 400,
        passRms > 5000, stopRms * 5 < passRms);
}

static void
unpacked_samples(void)
{
    AudioStreamBasicDescription input = pcm_rate(44100, 20, false, 1);
    input.mBytesPerFrame = input.mBytesPerPacket = 4;
    AudioStreamBasicDescription output = pcm(16, false, 1);
    AudioConverterRef c = NULL;
    OSStatus packedStatus = AudioConverterNew(&input, &output, &c);
    printf("packed 20-in-32 %d\n", (int)packedStatus);
    if (!packedStatus)
        check(AudioConverterDispose(c));
    input.mFormatFlags &= ~kAudioFormatFlagIsPacked;
    int32_t low[] = {0x0007ffff, 0x00040000, 0, -0x00040000, -0x00080000};
    int32_t high[sizeof(low) / sizeof(*low)];
    for (unsigned i = 0; i < sizeof(low) / sizeof(*low); i++)
        high[i] = (int32_t)((uint32_t)low[i] << 12);
    output.mFormatFlags &= ~kAudioFormatFlagIsPacked;
    int16_t lowResult[5] = {0}, highResult[5] = {0};
    convert("20bit low-aligned", input, output, low, sizeof(low));
    input.mFormatFlags |= kAudioFormatFlagIsAlignedHigh;
    convert("20bit high-aligned", input, output, high, sizeof(high));
    check(AudioConverterNew(&input, &output, &c));
    UInt32 bytes = sizeof(highResult);
    check(AudioConverterConvertBuffer(c, sizeof(high), high, &bytes, highResult));
    check(AudioConverterDispose(c));
    input.mFormatFlags &= ~kAudioFormatFlagIsAlignedHigh;
    check(AudioConverterNew(&input, &output, &c));
    bytes = sizeof(lowResult);
    check(AudioConverterConvertBuffer(c, sizeof(low), low, &bytes, lowResult));
    check(AudioConverterDispose(c));
    printf("20bit align equal %d %d\n", !memcmp(lowResult, highResult, sizeof(lowResult)),
        lowResult[0] > lowResult[1] && lowResult[1] > lowResult[2] && lowResult[2] > lowResult[3] && lowResult[3] > lowResult[4]);
}

static void
buffers(void)
{
    AudioStreamBasicDescription input = pcm(16, false, 2), output = input;
    output.mFormatFlags |= kAudioFormatFlagIsNonInterleaved;
    output.mBytesPerFrame = output.mBytesPerPacket = 2;
    int16_t samples[] = {100, 200, -300, -400, 32767, -32768};
    int16_t left[3] = {0}, right[3] = {0};
    AudioBufferList in = {1, {{2, sizeof(samples), samples}}};
    struct { UInt32 count; AudioBuffer buffers[2]; } out = {2, {{1, sizeof(left), left}, {1, sizeof(right), right}}};
    AudioConverterRef c;
    check(AudioConverterNew(&input, &output, &c));
    check(AudioConverterConvertComplexBuffer(c, 3, &in, (AudioBufferList *)&out));
    printf("planar %d %d %d / %d %d %d\n", left[0], left[1], left[2], right[0], right[1], right[2]);
    SInt32 map[] = {1, -1};
    check(AudioConverterSetProperty(c, kAudioConverterChannelMap, sizeof(map), map));
    check(AudioConverterConvertComplexBuffer(c, 3, &in, (AudioBufferList *)&out));
    printf("mapped %d %d %d / %d %d %d\n", left[0], left[1], left[2], right[0], right[1], right[2]);
    check(AudioConverterDispose(c));
    input = pcm(16, false, 1);
    output = pcm(32, true, 1);
    check(AudioConverterNew(&input, &output, &c));
    for (int error = 0; error < 2; error++) {
        struct Feed f = {samples, 6, 0, 0, error ? -1234 : 0};
        float result[10] = {0};
        AudioBufferList list = {1, {{1, sizeof(result), result}}};
        UInt32 count = 10;
        OSStatus status = AudioConverterFillComplexBuffer(c, feed, &f, &count, &list, NULL);
        printf("feed %d %u %u %u %016llx\n", (int)status, count, f.at, list.mBuffers[0].mDataByteSize,
            (unsigned long long)hash(result, list.mBuffers[0].mDataByteSize));
        check(AudioConverterReset(c));
    }
    check(AudioConverterDispose(c));
}

static void
properties(void)
{
    AudioStreamBasicDescription input = pcm(16, false, 1), output = pcm(32, true, 2);
    AudioConverterRef c;
    check(AudioConverterNew(&input, &output, &c));
    UInt32 ids[] = {kAudioConverterPropertyMinimumInputBufferSize, kAudioConverterPropertyMinimumOutputBufferSize,
        kAudioConverterPropertyMaximumInputPacketSize, kAudioConverterPropertyMaximumOutputPacketSize,
        kAudioConverterPropertyCalculateInputBufferSize, kAudioConverterPropertyCalculateOutputBufferSize,
        kAudioConverterChannelMap,
        kAudioConverterCurrentInputStreamDescription, kAudioConverterCurrentOutputStreamDescription};
    for (unsigned i = 0; i < sizeof(ids) / sizeof(*ids); i++) {
        UInt32 size = 0;
        Boolean writable = false;
        check(AudioConverterGetPropertyInfo(c, ids[i], &size, &writable));
        UInt32 data[16] = {16};
        if (size > sizeof(data))
            exit(1);
        check(AudioConverterGetProperty(c, ids[i], &size, data));
        printf("property %u %u %d %016llx\n", ids[i], size, writable, (unsigned long long)hash(data, size));
    }
    int16_t samples[] = {100, -100};
    float result[4] = {0};
    UInt32 size = 4;
    printf("short output %d\n", (int)AudioConverterConvertBuffer(c, sizeof(samples), samples, &size, result));
    size = sizeof(result);
    printf("partial input %d\n", (int)AudioConverterConvertBuffer(c, 3, samples, &size, result));
    size = 0;
    printf("empty output %d\n", (int)AudioConverterConvertBuffer(c, sizeof(samples), samples, &size, result));
    check(AudioConverterDispose(c));
}

static void
sample_rate_properties(void)
{
    AudioStreamBasicDescription input = pcm_rate(44100, 16, false, 1);
    AudioStreamBasicDescription output = pcm_rate(48000, 16, false, 1);
    AudioConverterRef c;
    check(AudioConverterNew(&input, &output, &c));
    UInt32 ids[] = {kAudioConverterSampleRateConverterComplexity, kAudioConverterSampleRateConverterQuality,
        kAudioConverterSampleRateConverterInitialPhase, kAudioConverterPrimeMethod, kAudioConverterPrimeInfo};
    for (unsigned i = 0; i < sizeof(ids) / sizeof(*ids); i++) {
        UInt32 size = 0;
        Boolean writable = false;
        check(AudioConverterGetPropertyInfo(c, ids[i], &size, &writable));
        UInt32 data[2] = {0};
        check(AudioConverterGetProperty(c, ids[i], &size, data));
        printf("src property %u %u %d %016llx\n", ids[i], size, writable,
            (unsigned long long)hash(data, size));
    }
    check(AudioConverterDispose(c));
}

static void
property_changes(void)
{
    AudioStreamBasicDescription input = pcm_rate(44100, 16, false, 1);
    AudioStreamBasicDescription output = pcm_rate(48000, 16, false, 1);
    AudioConverterRef c;
    check(AudioConverterNew(&input, &output, &c));
    AudioConverterPropertyID ids[] = {kAudioConverterSampleRateConverterComplexity,
        kAudioConverterSampleRateConverterQuality, kAudioConverterPrimeMethod,
        kAudioConverterPropertyDithering, kAudioConverterPropertyDitherBitDepth};
    UInt32 values[] = {kAudioConverterSampleRateConverterComplexity_Linear,
        kAudioConverterQuality_Low, kConverterPrimeMethod_None, kDitherAlgorithm_TPDF, 16};
    for (unsigned i = 0; i < sizeof(ids) / sizeof(*ids); i++) {
        OSStatus setStatus = AudioConverterSetProperty(c, ids[i], sizeof(values[i]), &values[i]);
        UInt32 got = 0, size = sizeof(got);
        OSStatus getStatus = setStatus ? setStatus : AudioConverterGetProperty(c, ids[i], &size, &got);
        printf("set property %u %d %d %u\n", ids[i], (int)setStatus, (int)getStatus, got);
    }
    Float64 phase = 0.25, gotPhase = 0;
    OSStatus phaseSet = AudioConverterSetProperty(c, kAudioConverterSampleRateConverterInitialPhase, sizeof(phase), &phase);
    UInt32 phaseSize = sizeof(gotPhase);
    OSStatus phaseGet = phaseSet ? phaseSet : AudioConverterGetProperty(c,
        kAudioConverterSampleRateConverterInitialPhase, &phaseSize, &gotPhase);
    printf("set phase %d %d %.2f\n", (int)phaseSet, (int)phaseGet, gotPhase);
    check(AudioConverterDispose(c));
}

static void
entrypoints(void)
{
    AudioStreamBasicDescription input = pcm(16, false, 1), output = pcm(16, false, 1);
    AudioConverterRef c = NULL;
    const AudioClassDescription *none = NULL;
    OSStatus specific = AudioConverterNewSpecific(&input, &output, 0, none, &c);
    printf("new specific %d\n", (int)specific);
    if (!specific)
        check(AudioConverterDispose(c));
    OSStatus regular = AudioConverterNewWithOptions(&input, &output, 0, &c);
    printf("new options %d\n", (int)regular);
    if (!regular)
        check(AudioConverterDispose(c));
    OSStatus unbuffered = AudioConverterNewWithOptions(&input, &output, kAudioConverterOption_Unbuffered, &c);
    printf("new unbuffered %d\n", (int)unbuffered);
    if (!unbuffered) {
        int16_t source[] = {123, -456, 789};
        int16_t target[3] = {0};
        struct Feed f = {source, 3, 0, 0, noErr};
        AudioBufferList list = {1, {{1, sizeof(target), target}}};
        UInt32 count = 3;
        OSStatus status = AudioConverterFillComplexBuffer(c, feed, &f, &count, &list, NULL);
        printf("unbuffered fill %d\n", (int)status);
        check(AudioConverterDispose(c));
    }

    input = pcm_rate(44100, 16, false, 1);
    output = pcm_rate(48000, 16, false, 1);
    check(AudioConverterNew(&input, &output, &c));
    int16_t source[] = {100, -100, 200, -200, 300, -300};
    int16_t target[8] = {0};
    struct RateFeed f = {source, 6, 0, 0, 3};
    AudioBufferList list = {1, {{1, sizeof(target), target}}};
    UInt32 count = 8;
    OSStatus status = AudioConverterFillComplexBufferRealtimeSafe(c, rate_feed, &f, &count, &list, NULL);
    printf("realtime-safe fill %d %u\n", (int)status, count);
    check(AudioConverterDispose(c));

    input = pcm(16, false, 1);
    output = pcm(16, false, 1);
    check(AudioConverterNew(&input, &output, &c));
    int16_t legacySource[] = {100, -100, 200};
    int16_t legacyOutput[3] = {0};
    struct Feed legacy = {legacySource, 3, 0, 0, noErr};
    AudioBufferList legacyList = {1, {{1, sizeof(legacyOutput), legacyOutput}}};
    AudioStreamPacketDescription packetDescriptions[3];
    AudioStreamPacketDescription packetDescriptionSentinel[3];
    AudioStreamPacketDependencyDescription dependencies[3];
    AudioStreamPacketDependencyDescription dependencySentinel[3];
    memset(packetDescriptions, 0xa5, sizeof(packetDescriptions));
    memcpy(packetDescriptionSentinel, packetDescriptions, sizeof(packetDescriptions));
    memset(dependencies, 0xa5, sizeof(dependencies));
    memcpy(dependencySentinel, dependencies, sizeof(dependencies));
    count = 3;
    status = AudioConverterFillComplexBufferWithPacketDependencies(c, feed, &legacy, &count,
        &legacyList, packetDescriptions, dependencies);
    printf("packet dependencies %d %u unchanged %d %d\n", (int)status, count,
        !memcmp(dependencies, dependencySentinel, sizeof(dependencies)),
        !memcmp(packetDescriptions, packetDescriptionSentinel, sizeof(packetDescriptions)));
    check(AudioConverterDispose(c));

    input = pcm_rate(44100, 16, false, 1);
    output = pcm_rate(48000, 16, false, 1);
    check(AudioConverterNew(&input, &output, &c));
    count = sizeof(source);
    status = AudioConverterConvertBuffer(c, sizeof(source), source, &count, target);
    printf("fixed-size rate change %d\n", (int)status);
    check(AudioConverterDispose(c));
}

static void
prepare(void)
{
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    __block OSStatus result = -1;
    AudioConverterPrepare(0, NULL, ^(OSStatus status) {
        result = status;
        dispatch_semaphore_signal(completed);
    });
    long wait = dispatch_semaphore_wait(completed, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    printf("prepare %d\n", wait ? -1 : (int)result);
    dispatch_release(completed);
}

int
main(void)
{
    Dl_info info = {0};
    dladdr((void *)AudioConverterNew, &info);
    printf("AudioConverter: %s\n", info.dli_fname);
    prepare();
    int16_t *all = malloc(65536 * sizeof(*all));
    if (!all)
        return 1;
    for (int i = 0; i < 65536; i++)
        all[i] = (int16_t)(i - 32768);
    UInt32 widths[] = {8, 16, 24, 32, 64};
    for (unsigned i = 0; i < sizeof(widths) / sizeof(*widths); i++) {
        for (int floating = 0; floating <= 1; floating++) {
            if ((floating && widths[i] < 32) || (!floating && widths[i] == 64))
                continue;
            for (int big = 0; big <= 1; big++) {
                AudioStreamBasicDescription out = pcm(widths[i], floating, 1);
                if (big)
                    out.mFormatFlags |= kAudioFormatFlagIsBigEndian;
                char label[64];
                snprintf(label, sizeof(label), "all16 to %s%u %s", floating ? "f" : "i", widths[i], big ? "be" : "le");
                convert(label, pcm(16, false, 1), out, all, 65536 * sizeof(*all));
            }
        }
    }
    for (int law = 0; law < 2; law++) {
        AudioStreamBasicDescription a = {44100, law ? kAudioFormatALaw : kAudioFormatULaw, 0, 1, 1, 1, 1, 8, 0};
        convert(law ? "encode alaw" : "encode ulaw", pcm(16, false, 1), a, all, 65536 * sizeof(*all));
        UInt8 codes[256];
        for (int i = 0; i < 256; i++)
            codes[i] = i;
        convert(law ? "decode alaw" : "decode ulaw", a, pcm(16, false, 1), codes, sizeof(codes));
    }
    free(all);
    double values[] = {0, 0.5, -0.5, 1, -1, 2, -2, 0.99999, 0.5/32768, -0.5/32768, 1.5/32768, -1.5/32768,
        0.5/128, -0.5/128, 0.5/8388608, -0.5/8388608, INFINITY, -INFINITY};
    float floats[sizeof(values) / sizeof(*values)];
    for (unsigned i = 0; i < sizeof(floats) / sizeof(*floats); i++)
        floats[i] = values[i];
    for (int i = 0; i < 4; i++) {
        char label[64];
        snprintf(label, sizeof(label), "float64 to %u", widths[i]);
        convert(label, pcm(64, true, 1), pcm(widths[i], false, 1), values, sizeof(values));
        snprintf(label, sizeof(label), "float32 to %u", widths[i]);
        convert(label, pcm(32, true, 1), pcm(widths[i], false, 1), floats, sizeof(floats));
    }
    int16_t channels[] = {1, 2, 3, -4, -5, -6};
    convert("mono stereo", pcm(16, false, 1), pcm(16, false, 2), channels, sizeof(channels));
    convert("stereo mono", pcm(16, false, 2), pcm(16, false, 1), channels, sizeof(channels));
    convert("mono three", pcm(16, false, 1), pcm(16, false, 3), channels, sizeof(channels));
    convert("three stereo", pcm(16, false, 3), pcm(16, false, 2), channels, sizeof(channels));
    int32_t wide[4096];
    UInt8 packed[4096 * 3];
    uint32_t random = 12345;
    for (unsigned i = 0; i < 4096; i++) {
        random = random * 1664525 + 1013904223;
        wide[i] = (int32_t)random;
        packed[i * 3] = random;
        packed[i * 3 + 1] = random >> 8;
        packed[i * 3 + 2] = random >> 16;
    }
    for (int i = 0; i < 4; i++) {
        char label[64];
        snprintf(label, sizeof(label), "random32 to %u", widths[i]);
        convert(label, pcm(32, false, 1), pcm(widths[i], false, 1), wide, sizeof(wide));
        snprintf(label, sizeof(label), "random24 to %u", widths[i]);
        convert(label, pcm(24, false, 1), pcm(widths[i], false, 1), packed, sizeof(packed));
    }
    properties();
    sample_rate_properties();
    buffers();
    unpacked_samples();
    resampling();
    property_changes();
    entrypoints();
    return 0;
}
