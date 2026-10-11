/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Check Finch's component list and its PCM AudioUnit render paths. */
#include <AudioToolbox/AudioToolbox.h>
#include <dlfcn.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void
expect(OSStatus actual, OSStatus wanted, const char *what)
{
    if (actual != wanted) {
        fprintf(stderr, "%s: got %d, wanted %d\n", what, (int)actual, (int)wanted);
        exit(1);
    }
}

static void
check(OSStatus status, const char *what)
{
    expect(status, noErr, what);
}

static AudioStreamBasicDescription
pcm_rate(double rate, UInt32 bits, Boolean floating)
{
    UInt32 flags = kAudioFormatFlagIsPacked |
        (floating ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger);
    UInt32 bytes = 2 * bits / 8;
    return (AudioStreamBasicDescription){rate, kAudioFormatLinearPCM, flags,
        bytes, 1, bytes, 2, bits, 0};
}

static AudioStreamBasicDescription
pcm(UInt32 bits, Boolean floating)
{
    return pcm_rate(44100.0, bits, floating);
}

struct ConstantInput {
    Float32 left;
    Float32 right;
    SInt16 left16;
    SInt16 right16;
    Boolean useInt16;
    UInt32 calls;
};

struct TimestampInput {
    Float64 nextSampleTime;
    Float64 firstSampleTime;
    Boolean hasNextSampleTime;
    Boolean invalidSequence;
    UInt32 calls;
};

/* A producer may supply its own samples instead of filling our scratch buffer. */
static OSStatus
render_borrowed(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
    UInt32 bus, UInt32 frames, AudioBufferList *data)
{
    (void)flags;
    (void)time;
    (void)bus;
    if (frames > 4 || !data || data->mNumberBuffers != 1)
        return kAudio_ParamError;
    data->mBuffers[0] = (AudioBuffer){2, frames * 2 * sizeof(Float32), context};
    return noErr;
}

static OSStatus
render_constant(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
    UInt32 bus, UInt32 frames, AudioBufferList *data)
{
    (void)flags;
    (void)time;
    (void)bus;
    struct ConstantInput *input = context;
    input->calls++;
    if (!data || data->mNumberBuffers != 1 || !data->mBuffers[0].mData)
        return kAudio_ParamError;
    if (input->useInt16) {
        SInt16 *samples = data->mBuffers[0].mData;
        for (UInt32 frame = 0; frame < frames; frame++) {
            samples[frame * 2] = input->left16;
            samples[frame * 2 + 1] = input->right16;
        }
        data->mBuffers[0].mDataByteSize = frames * 2 * sizeof(SInt16);
    } else {
        Float32 *samples = data->mBuffers[0].mData;
        for (UInt32 frame = 0; frame < frames; frame++) {
            samples[frame * 2] = input->left;
            samples[frame * 2 + 1] = input->right;
        }
        data->mBuffers[0].mDataByteSize = frames * 2 * sizeof(Float32);
    }
    return noErr;
}

static OSStatus
render_timestamped(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
    UInt32 bus, UInt32 frames, AudioBufferList *data)
{
    (void)flags;
    (void)bus;
    struct TimestampInput *input = context;
    if (!time || !(time->mFlags & kAudioTimeStampSampleTimeValid) ||
        !data || data->mNumberBuffers != 1 || !data->mBuffers[0].mData)
        return kAudio_ParamError;
    if (!input->hasNextSampleTime) {
        input->firstSampleTime = time->mSampleTime;
        input->hasNextSampleTime = true;
    } else if (fabs(time->mSampleTime - input->nextSampleTime) > 0.001) {
        input->invalidSequence = true;
    }
    input->nextSampleTime = time->mSampleTime + frames;
    input->calls++;

    Float32 *samples = data->mBuffers[0].mData;
    for (UInt32 frame = 0; frame < frames; frame++) {
        Float32 sample = (Float32)sin((time->mSampleTime + frame) * 0.031);
        samples[frame * 2] = sample;
        samples[frame * 2 + 1] = -sample;
    }
    data->mBuffers[0].mDataByteSize = frames * 2 * sizeof(Float32);
    return noErr;
}

static OSStatus
render_bad_buffer_list(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
    UInt32 bus, UInt32 frames, AudioBufferList *data)
{
    (void)context;
    (void)flags;
    (void)time;
    (void)bus;
    (void)frames;
    data->mNumberBuffers = UINT32_MAX;
    return noErr;
}

static AudioComponent
find_component(UInt32 type, UInt32 subtype)
{
    AudioComponentDescription query = {type, subtype, kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent component = AudioComponentFindNext(NULL, &query);
    if (!component) {
        fprintf(stderr, "component %08x/%08x was not found\n", type, subtype);
        exit(1);
    }
    return component;
}

static AudioUnit
new_unit(UInt32 type, UInt32 subtype)
{
    AudioComponent component = find_component(type, subtype);
    AudioComponentInstance instance = NULL;
    check(AudioComponentInstanceNew(component, &instance), "create unit");
    if (!instance || AudioComponentInstanceGetComponent(instance) != component) {
        fprintf(stderr, "unit did not keep its component\n");
        exit(1);
    }
    Boolean supportsParameters = subtype == kAudioUnitSubType_MultiChannelMixer;
    Boolean supportsOutputStart = type == kAudioUnitType_Output;
    if (!AudioComponentInstanceCanDo(instance, kAudioUnitInitializeSelect) ||
        !AudioComponentInstanceCanDo(instance, kAudioUnitRenderSelect) ||
        AudioComponentInstanceCanDo(instance, kAudioUnitProcessMultipleSelect) ||
        AudioComponentInstanceCanDo(instance, kAudioUnitGetParameterSelect) != supportsParameters ||
        AudioComponentInstanceCanDo(instance, kAudioUnitSetParameterSelect) != supportsParameters ||
        AudioComponentInstanceCanDo(instance, kAudioOutputUnitStartSelect) != supportsOutputStart ||
        AudioComponentInstanceCanDo(instance, kAudioOutputUnitStopSelect) != supportsOutputStart) {
        fprintf(stderr, "unit reported incorrect selector support\n");
        exit(1);
    }
    return (AudioUnit)instance;
}

static void
set_format(AudioUnit unit, AudioUnitScope scope, AudioUnitElement element,
    const AudioStreamBasicDescription *format)
{
    check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, scope, element,
        format, sizeof(*format)), "set stream format");
}

static void
set_callback(AudioUnit unit, AudioUnitElement bus, struct ConstantInput *input)
{
    AURenderCallbackStruct callback = {render_constant, input};
    check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
        kAudioUnitScope_Input, bus, &callback, sizeof(callback)), "set render callback");
}

static void
render_at(AudioUnit unit, UInt32 frames, Float32 *samples, UInt32 capacityFrames,
    AudioUnitRenderActionFlags *flags, Float64 sampleTime)
{
    AudioStreamBasicDescription format = pcm(32, true);
    AudioBufferList list = {1, {{2, capacityFrames * 2 * sizeof(Float32), samples}}};
    AudioTimeStamp timestamp = {0};
    timestamp.mFlags = kAudioTimeStampSampleTimeValid;
    timestamp.mSampleTime = sampleTime;
    check(AudioUnitRender(unit, flags, &timestamp, 0, frames, &list), "render audio");
    if (list.mBuffers[0].mDataByteSize != frames * format.mBytesPerFrame) {
        fprintf(stderr, "render returned %u bytes for %u frames\n",
            list.mBuffers[0].mDataByteSize, frames);
        exit(1);
    }
}

static void
render(AudioUnit unit, UInt32 frames, Float32 *samples, UInt32 capacityFrames,
    AudioUnitRenderActionFlags *flags)
{
    render_at(unit, frames, samples, capacityFrames, flags, 0.0);
}

static void
components(void)
{
    AudioComponentDescription all = {0};
    if (AudioComponentCount(&all) != 4) {
        fprintf(stderr, "component count did not include the four Finch units\n");
        exit(1);
    }
    const UInt32 types[] = {
        kAudioUnitType_Output, kAudioUnitType_Output,
        kAudioUnitType_FormatConverter, kAudioUnitType_Mixer
    };
    const UInt32 subtypes[] = {
        kAudioUnitSubType_DefaultOutput, kAudioUnitSubType_SystemOutput,
        kAudioUnitSubType_AUConverter,
        kAudioUnitSubType_MultiChannelMixer
    };
    for (size_t i = 0; i < sizeof(types) / sizeof(types[0]); i++) {
        AudioComponentDescription query = {types[i], subtypes[i], kAudioUnitManufacturer_Apple, 0, 0};
        AudioComponent component = AudioComponentFindNext(NULL, &query);
        AudioComponentDescription found = {0};
        UInt32 version = 0;
        CFStringRef name = NULL;
        if (!component || AudioComponentCount(&query) != 1)
            exit(1);
        check(AudioComponentGetDescription(component, &found), "get component description");
        check(AudioComponentGetVersion(component, &version), "get component version");
        check(AudioComponentCopyName(component, &name), "copy component name");
        if (found.componentType != types[i] || found.componentSubType != subtypes[i] ||
            found.componentManufacturer != kAudioUnitManufacturer_Apple || version != 0x00010000 || !name)
            exit(1);
        CFRelease(name);
    }
    AudioComponentDescription missing = {kAudioUnitType_Mixer, 'none', kAudioUnitManufacturer_Apple, 0, 0};
    if (AudioComponentCount(&missing) != 0)
        exit(1);
    AudioComponentDescription genericOutput = {
        kAudioUnitType_Output, kAudioUnitSubType_GenericOutput,
        kAudioUnitManufacturer_Apple, 0, 0
    };
    if (AudioComponentCount(&genericOutput) != 0)
        exit(1);
    printf("components 4 names versions filters ok\n");
}

static void
converter(void)
{
    AudioUnit unit = new_unit(kAudioUnitType_FormatConverter, kAudioUnitSubType_AUConverter);
    AudioStreamBasicDescription inputFormat = pcm(16, false);
    AudioStreamBasicDescription outputFormat = pcm(32, true);
    set_format(unit, kAudioUnitScope_Input, 0, &inputFormat);
    set_format(unit, kAudioUnitScope_Output, 0, &outputFormat);
    UInt32 maximum = 64;
    check(AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
        kAudioUnitScope_Global, 0, &maximum, sizeof(maximum)), "set maximum frames");
    struct ConstantInput source = {0, 0, 8192, -16384, true, 0};
    set_callback(unit, 0, &source);

    Float32 samples[8] = {0};
    AudioBufferList list = {1, {{2, sizeof(samples), samples}}};
    AudioTimeStamp timestamp = {0};
    timestamp.mFlags = kAudioTimeStampSampleTimeValid;
    timestamp.mSampleTime = 0;
    expect(AudioUnitRender(unit, NULL, &timestamp, 0, 4, &list),
        kAudioUnitErr_Uninitialized, "render before initialize");
    check(AudioUnitInitialize(unit), "initialize converter");
    expect(AudioUnitInitialize(unit), kAudioUnitErr_Initialized, "initialize twice");
    expect(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,
        0, &inputFormat, sizeof(inputFormat)), kAudioUnitErr_Initialized, "change live format");

    AudioUnitRenderActionFlags flags = 0;
    render(unit, 4, samples, 4, &flags);
    if (source.calls != 1 || fabs(samples[0] - 0.25f) > 0.0001 ||
        fabs(samples[1] + 0.5f) > 0.0001 || fabs(samples[6] - 0.25f) > 0.0001 ||
        fabs(samples[7] + 0.5f) > 0.0001) {
        fprintf(stderr, "converter did not turn the callback's 16-bit PCM into float PCM\n");
        exit(1);
    }
    check(AudioUnitReset(unit, kAudioUnitScope_Global, 0), "reset converter");
    memset(samples, 0, sizeof(samples));
    render(unit, 4, samples, 4, &flags);
    if (fabs(samples[0] - 0.25f) > 0.0001 || fabs(samples[1] + 0.5f) > 0.0001)
        exit(1);
    check(AudioUnitUninitialize(unit), "uninitialize converter");
    expect(AudioUnitRender(unit, &flags, &timestamp, 0, 4, &list),
        kAudioUnitErr_Uninitialized, "render after uninitialize");
    check(AudioComponentInstanceDispose(unit), "dispose converter");

    unit = new_unit(kAudioUnitType_FormatConverter, kAudioUnitSubType_AUConverter);
    inputFormat = pcm_rate(48000.0, 32, true);
    outputFormat = pcm_rate(44100.0, 32, true);
    set_format(unit, kAudioUnitScope_Input, 0, &inputFormat);
    set_format(unit, kAudioUnitScope_Output, 0, &outputFormat);
    maximum = 64;
    check(AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
        kAudioUnitScope_Global, 0, &maximum, sizeof(maximum)), "set resampler frames");
    source = (struct ConstantInput){0.25f, -0.5f, 0, 0, false, 0};
    set_callback(unit, 0, &source);
    check(AudioUnitInitialize(unit), "initialize resampler");
    memset(samples, 0, sizeof(samples));
    render(unit, 4, samples, 4, &flags);
    if (source.calls == 0 || fabs(samples[0] - 0.25f) > 0.01 ||
        fabs(samples[1] + 0.5f) > 0.01)
        exit(1);
    check(AudioUnitUninitialize(unit), "uninitialize resampler");
    check(AudioComponentInstanceDispose(unit), "dispose resampler");

    unit = new_unit(kAudioUnitType_FormatConverter, kAudioUnitSubType_AUConverter);
    inputFormat = pcm_rate(22050.0, 32, true);
    outputFormat = pcm_rate(44100.0, 32, true);
    set_format(unit, kAudioUnitScope_Input, 0, &inputFormat);
    set_format(unit, kAudioUnitScope_Output, 0, &outputFormat);
    struct TimestampInput timeline = {0};
    AURenderCallbackStruct timeCallback = {render_timestamped, &timeline};
    check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
        kAudioUnitScope_Input, 0, &timeCallback, sizeof(timeCallback)), "set timestamp callback");
    check(AudioUnitInitialize(unit), "initialize default-size 2:1 resampler");

    const UInt32 chunks[] = {7, 17, 3, 31, 11, 29};
    Float32 chunkSamples[31 * 2] = {0};
    flags = 0;
    Float64 outputSampleTime = 1000.0;
    Boolean outputVaries = false;
    for (size_t i = 0; i < sizeof(chunks) / sizeof(chunks[0]); i++) {
        UInt32 frames = chunks[i];
        memset(chunkSamples, 0, sizeof(chunkSamples));
        render_at(unit, frames, chunkSamples, frames, &flags, outputSampleTime);
        outputSampleTime += frames;
        if (fabs(chunkSamples[0] - chunkSamples[2]) > 0.001)
            outputVaries = true;
    }
    if (timeline.calls < 2 || timeline.invalidSequence || !outputVaries ||
        fabs(timeline.firstSampleTime - 500.0) > 0.001) {
        fprintf(stderr, "converter callback timestamps did not follow the input sample stream\n");
        exit(1);
    }

    check(AudioUnitReset(unit, kAudioUnitScope_Global, 0), "reset timestamp resampler");
    timeline.hasNextSampleTime = false;
    timeline.invalidSequence = false;
    timeline.calls = 0;
    memset(chunkSamples, 0, sizeof(chunkSamples));
    render_at(unit, 13, chunkSamples, 13, &flags, 5000.0);
    if (!timeline.calls || timeline.invalidSequence ||
        fabs(timeline.firstSampleTime - 2500.0) > 0.001) {
        fprintf(stderr, "converter reset did not restart its source timestamp\n");
        exit(1);
    }
    check(AudioUnitUninitialize(unit), "uninitialize timestamp resampler");
    check(AudioComponentInstanceDispose(unit), "dispose timestamp resampler");
    printf("converter lifecycle callback PCM resampling reset timestamps ok\n");
}

static void
mixer(void)
{
    AudioUnit unit = new_unit(kAudioUnitType_Mixer, kAudioUnitSubType_MultiChannelMixer);
    AudioStreamBasicDescription format = pcm(32, true);
    UInt32 count = 2;
    check(AudioUnitSetProperty(unit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input,
        0, &count, sizeof(count)), "set mixer inputs");
    set_format(unit, kAudioUnitScope_Input, 0, &format);
    set_format(unit, kAudioUnitScope_Input, 1, &format);
    set_format(unit, kAudioUnitScope_Output, 0, &format);
    struct ConstantInput first = {0.25f, 0.25f, 0, 0, false, 0};
    struct ConstantInput second = {0.5f, 0.5f, 0, 0, false, 0};
    set_callback(unit, 0, &first);
    set_callback(unit, 1, &second);
    check(AudioUnitSetParameter(unit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input,
        0, 0.5f, 0), "set input volume");
    check(AudioUnitInitialize(unit), "initialize mixer");

    Float32 samples[16] = {0};
    AudioUnitRenderActionFlags flags = 0;
    render(unit, 8, samples, 8, &flags);
    for (size_t i = 0; i < sizeof(samples) / sizeof(samples[0]); i++) {
        if (fabs(samples[i] - 0.625f) > 0.0001) {
            fprintf(stderr, "mixer sample %zu was %.6f, wanted 0.625\n", i, samples[i]);
            exit(1);
        }
    }
    if (first.calls != 1 || second.calls != 1 || (flags & kAudioUnitRenderAction_OutputIsSilence))
        exit(1);

    check(AudioUnitSetParameter(unit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Global,
        0, 0.5f, 0), "set output volume");
    AudioUnitParameterValue volume = 0;
    check(AudioUnitGetParameter(unit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Global,
        0, &volume), "get output volume");
    if (fabs(volume - 0.5f) > 0.0001)
        exit(1);
    render(unit, 8, samples, 8, &flags);
    if (fabs(samples[0] - 0.3125f) > 0.0001 || fabs(samples[1] - 0.3125f) > 0.0001)
        exit(1);

    expect(AudioUnitGetPropertyInfo(unit, UINT32_C(0x7fffffff), kAudioUnitScope_Global,
        0, &count, NULL), kAudioUnitErr_InvalidProperty, "unsupported property");
    expect(AudioUnitGetPropertyInfo(unit, kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Input, 2, &count, NULL), kAudioUnitErr_InvalidElement, "bad input bus");
    expect(AudioUnitGetPropertyInfo(unit, kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Global, 0, &count, NULL), kAudioUnitErr_InvalidScope, "bad format scope");
    check(AudioUnitReset(unit, kAudioUnitScope_Global, 0), "reset mixer");
    check(AudioUnitUninitialize(unit), "uninitialize mixer");
    check(AudioComponentInstanceDispose(unit), "dispose mixer");

    unit = new_unit(kAudioUnitType_Mixer, kAudioUnitSubType_MultiChannelMixer);
    AudioStreamBasicDescription integerFormat = pcm(16, false);
    set_format(unit, kAudioUnitScope_Input, 0, &integerFormat);
    set_format(unit, kAudioUnitScope_Output, 0, &integerFormat);
    struct ConstantInput integerSource = {0, 0, 8192, 16384, true, 0};
    set_callback(unit, 0, &integerSource);
    check(AudioUnitInitialize(unit), "initialize integer mixer");
    SInt16 integerSamples[8] = {0};
    AudioBufferList integerList = {1, {{2, sizeof(integerSamples), integerSamples}}};
    AudioTimeStamp timestamp = {0};
    timestamp.mFlags = kAudioTimeStampSampleTimeValid;
    timestamp.mSampleTime = 0;
    check(AudioUnitRender(unit, &flags, &timestamp, 0, 4, &integerList), "render integer mixer");
    for (size_t i = 0; i < sizeof(integerSamples) / sizeof(integerSamples[0]); i++) {
        if (abs(integerSamples[i] - (i % 2 ? 16384 : 8192)) > 1)
            exit(1);
    }
    check(AudioUnitUninitialize(unit), "uninitialize integer mixer");
    check(AudioComponentInstanceDispose(unit), "dispose integer mixer");

    unit = new_unit(kAudioUnitType_Mixer, kAudioUnitSubType_MultiChannelMixer);
    set_format(unit, kAudioUnitScope_Input, 0, &format);
    set_format(unit, kAudioUnitScope_Output, 0, &format);
    AURenderCallbackStruct badCallback = {render_bad_buffer_list, NULL};
    check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
        kAudioUnitScope_Input, 0, &badCallback, sizeof(badCallback)), "set malformed callback");
    check(AudioUnitInitialize(unit), "initialize malformed callback mixer");
    Float32 malformedSamples[8] = {0};
    AudioBufferList malformedList = {1, {{2, sizeof(malformedSamples), malformedSamples}}};
    expect(AudioUnitRender(unit, &flags, &timestamp, 0, 4, &malformedList),
        kAudioUnitErr_InvalidPropertyValue, "reject malformed callback buffer list");
    check(AudioUnitUninitialize(unit), "uninitialize before changing callback");
    Float32 borrowedSamples[8] = {0.25f, 0.5f, 0.25f, 0.5f, 0.25f, 0.5f, 0.25f, 0.5f};
    AURenderCallbackStruct borrowedCallback = {render_borrowed, borrowedSamples};
    check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
        kAudioUnitScope_Input, 0, &borrowedCallback, sizeof(borrowedCallback)), "set borrowed samples callback");
    check(AudioUnitInitialize(unit), "initialize borrowed samples callback");
    malformedList.mBuffers[0].mDataByteSize = sizeof(malformedSamples);
    check(AudioUnitRender(unit, &flags, &timestamp, 0, 4, &malformedList), "render borrowed samples");
    for (size_t i = 0; i < 8; i++)
        if (fabs(malformedSamples[i] - borrowedSamples[i]) > 0.0001)
            exit(1);
    check(AudioUnitUninitialize(unit), "uninitialize malformed callback mixer");
    check(AudioComponentInstanceDispose(unit), "dispose malformed callback mixer");
    printf("mixer float and integer inputs volume reset malformed callback paths ok\n");
}

static void
silent_output(void)
{
    AudioUnit unit = new_unit(kAudioUnitType_Output, kAudioUnitSubType_DefaultOutput);
    check(AudioUnitInitialize(unit), "initialize output sink");
    expect(AudioOutputUnitStart(unit), kAudioUnitErr_NoConnection, "start without a device");
    check(AudioOutputUnitStop(unit), "stop output sink");
    Float32 samples[8] = {0};
    AudioBufferList list = {1, {{2, sizeof(samples), samples}}};
    AudioTimeStamp timestamp = {0};
    timestamp.mFlags = kAudioTimeStampSampleTimeValid;
    expect(AudioUnitRender(unit, NULL, &timestamp, 0, 4, &list),
        kAudioUnitErr_NoConnection, "render without a device");
    check(AudioUnitUninitialize(unit), "uninitialize output sink");
    check(AudioComponentInstanceDispose(unit), "dispose output sink");
    printf("output has no device and reports no connection\n");
}

int
main(void)
{
    puts("Finch software audio units");
    components();
    converter();
    mixer();
    silent_output();
    return 0;
}
