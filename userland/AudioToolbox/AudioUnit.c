/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Small PCM audio units for Finch's device-free audio stack. */
#include <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define FINCH_MAX_INPUTS 16
#define FINCH_MAX_CHANNELS 32
#define FINCH_MAX_INSTANCES 256
#define FINCH_DEFAULT_MAX_FRAMES 4096
#define FINCH_MAX_FRAMES 65536
#define FINCH_MAX_INPUT_FRAMES (1U << 20)
#define FINCH_UNIT_SIGNATURE UINT32_C(0x46415531)

enum UnitKind {
    UnitOutput,
    UnitConverter,
    UnitMixer
};

struct ComponentRecord {
    AudioComponentDescription description;
    const char *name;
    UInt32 version;
    enum UnitKind kind;
};

static const struct ComponentRecord components[] = {
    {{kAudioUnitType_Output, kAudioUnitSubType_DefaultOutput,
        kAudioUnitManufacturer_Apple, kAudioComponentFlag_SandboxSafe, 0},
        "Finch Default Output (no device)", 0x00010000, UnitOutput},
    {{kAudioUnitType_Output, kAudioUnitSubType_SystemOutput,
        kAudioUnitManufacturer_Apple, kAudioComponentFlag_SandboxSafe, 0},
        "Finch System Output (no device)", 0x00010000, UnitOutput},
    {{kAudioUnitType_FormatConverter, kAudioUnitSubType_AUConverter,
        kAudioUnitManufacturer_Apple, kAudioComponentFlag_SandboxSafe, 0},
        "Finch PCM Converter", 0x00010000, UnitConverter},
    {{kAudioUnitType_Mixer, kAudioUnitSubType_MultiChannelMixer,
        kAudioUnitManufacturer_Apple, kAudioComponentFlag_SandboxSafe, 0},
        "Finch Multichannel Mixer", 0x00010000, UnitMixer}
};

struct UnitInstance {
    UInt32 signature;
    const struct ComponentRecord *component;
    bool initialized;
    bool running;
    UInt32 inputCount;
    UInt32 maximumFrames;
    AudioStreamBasicDescription inputFormats[FINCH_MAX_INPUTS];
    AudioStreamBasicDescription outputFormat;
    /* Source frames already pulled, including any frames the converter buffered ahead. */
    Float64 inputSampleTime;
    Boolean inputSampleTimeValid;
    AURenderCallbackStruct inputCallbacks[FINCH_MAX_INPUTS];
    Float32 inputVolumes[FINCH_MAX_INPUTS];
    Float32 inputPans[FINCH_MAX_INPUTS];
    Boolean inputEnabled[FINCH_MAX_INPUTS];
    Float32 outputVolume;
    Boolean outputEnabled;
    UInt32 renderQuality;
    OSStatus lastRenderError;
    AudioConverterRef converter;
    void *inputScratch[FINCH_MAX_INPUTS];
    UInt32 inputScratchFrames[FINCH_MAX_INPUTS];
    Float32 *mixScratch;
};

typedef struct {
    UInt32 mNumberBuffers;
    AudioBuffer mBuffers[FINCH_MAX_CHANNELS];
} FinchAudioBufferList;

/*
 * Atomic reads keep the render path free of locks. Creation and removal also
 * take the registry lock so two callers cannot claim or clear the same slot.
 * Calls on one instance must be serialized by its owner; render or property
 * calls must stop before uninitialize or dispose begins.
 */
static _Atomic(struct UnitInstance *) instances[FINCH_MAX_INSTANCES];
static pthread_mutex_t instance_registry_lock = PTHREAD_MUTEX_INITIALIZER;

static AudioComponent
component_handle(const struct ComponentRecord *record)
{
    return (AudioComponent)(uintptr_t)record;
}

static const struct ComponentRecord *
component_record(AudioComponent handle)
{
    for (size_t i = 0; i < sizeof(components) / sizeof(components[0]); i++) {
        if (component_handle(&components[i]) == handle)
            return &components[i];
    }
    return NULL;
}

static struct UnitInstance *
unit_instance(AudioUnit handle)
{
    for (size_t i = 0; i < FINCH_MAX_INSTANCES; i++) {
        struct UnitInstance *unit = atomic_load_explicit(&instances[i], memory_order_acquire);
        if (unit && (AudioUnit)(void *)unit == handle)
            return unit;
    }
    return NULL;
}

static AudioStreamBasicDescription
default_format(void)
{
    return (AudioStreamBasicDescription){
        44100.0, kAudioFormatLinearPCM,
        kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        8, 1, 8, 2, 32, 0
    };
}

static Boolean
non_interleaved(const AudioStreamBasicDescription *format)
{
    return (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
}

static UInt32
container_bytes(const AudioStreamBasicDescription *format)
{
    if (non_interleaved(format))
        return format->mBytesPerFrame;
    if (!format->mChannelsPerFrame || format->mBytesPerFrame % format->mChannelsPerFrame)
        return 0;
    return format->mBytesPerFrame / format->mChannelsPerFrame;
}

static size_t
frame_storage_bytes(const AudioStreamBasicDescription *format)
{
    return (size_t)container_bytes(format) * format->mChannelsPerFrame;
}

static UInt32
buffer_count(const AudioStreamBasicDescription *format)
{
    return non_interleaved(format) ? format->mChannelsPerFrame : 1;
}

static UInt32
buffer_channels(const AudioStreamBasicDescription *format)
{
    return non_interleaved(format) ? 1 : format->mChannelsPerFrame;
}

static size_t
buffer_frame_bytes(const AudioStreamBasicDescription *format)
{
    return non_interleaved(format) ? container_bytes(format) : format->mBytesPerFrame;
}

static Boolean
valid_pcm_format(const AudioStreamBasicDescription *format)
{
    if (!format || format->mFormatID != kAudioFormatLinearPCM ||
        !isfinite(format->mSampleRate) || format->mSampleRate <= 0.0 ||
        !format->mChannelsPerFrame || format->mChannelsPerFrame > FINCH_MAX_CHANNELS ||
        format->mFramesPerPacket != 1 || !format->mBytesPerFrame || !format->mBytesPerPacket)
        return false;

    Boolean floating = (format->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    UInt32 bits = format->mBitsPerChannel;
    if (floating ? (bits != 32 && bits != 64) :
        (bits != 8 && bits != 16 && bits != 20 && bits != 24 && bits != 32))
        return false;
    if (floating && (format->mFormatFlags & kAudioFormatFlagIsAlignedHigh))
        return false;

    UInt32 storage = container_bytes(format);
    UInt32 flags = format->mFormatFlags;
    if (!storage || storage > 8 || storage * 8 < bits)
        return false;
    if ((flags & kAudioFormatFlagIsPacked) && (bits % 8 || storage * 8 != bits))
        return false;
    if ((flags & kAudioFormatFlagIsAlignedHigh) && (flags & kAudioFormatFlagIsPacked))
        return false;
    if (format->mBytesPerFrame != storage * (non_interleaved(format) ? 1 : format->mChannelsPerFrame))
        return false;
    return true;
}

static Boolean
matches_description(const struct ComponentRecord *record, const AudioComponentDescription *query)
{
    if (!query)
        return true;
    if (query->componentType && query->componentType != record->description.componentType)
        return false;
    if (query->componentSubType && query->componentSubType != record->description.componentSubType)
        return false;
    if (query->componentManufacturer && query->componentManufacturer != record->description.componentManufacturer)
        return false;
    if (((query->componentFlags ^ record->description.componentFlags) & query->componentFlagsMask) != 0)
        return false;
    return true;
}

AudioComponent
AudioComponentFindNext(AudioComponent inComponent, const AudioComponentDescription *inDesc)
{
    size_t start = 0;
    if (inComponent) {
        const struct ComponentRecord *current = component_record(inComponent);
        if (!current)
            return NULL;
        start = (size_t)(current - components) + 1;
    }
    for (size_t i = start; i < sizeof(components) / sizeof(components[0]); i++) {
        if (matches_description(&components[i], inDesc))
            return component_handle(&components[i]);
    }
    return NULL;
}

UInt32
AudioComponentCount(const AudioComponentDescription *inDesc)
{
    UInt32 count = 0;
    for (size_t i = 0; i < sizeof(components) / sizeof(components[0]); i++)
        if (matches_description(&components[i], inDesc))
            count++;
    return count;
}

OSStatus
AudioComponentCopyName(AudioComponent inComponent, CFStringRef *outName)
{
    const struct ComponentRecord *record = component_record(inComponent);
    if (!record || !outName)
        return kAudio_ParamError;
    *outName = CFStringCreateWithCString(kCFAllocatorDefault, record->name, kCFStringEncodingUTF8);
    return *outName ? noErr : kAudioUnitErr_FailedInitialization;
}

OSStatus
AudioComponentGetDescription(AudioComponent inComponent, AudioComponentDescription *outDesc)
{
    const struct ComponentRecord *record = component_record(inComponent);
    if (!record || !outDesc)
        return kAudio_ParamError;
    *outDesc = record->description;
    return noErr;
}

OSStatus
AudioComponentGetVersion(AudioComponent inComponent, UInt32 *outVersion)
{
    const struct ComponentRecord *record = component_record(inComponent);
    if (!record || !outVersion)
        return kAudio_ParamError;
    *outVersion = record->version;
    return noErr;
}

static void
free_render_memory(struct UnitInstance *unit)
{
    for (UInt32 i = 0; i < FINCH_MAX_INPUTS; i++) {
        free(unit->inputScratch[i]);
        unit->inputScratch[i] = NULL;
        unit->inputScratchFrames[i] = 0;
    }
    free(unit->mixScratch);
    unit->mixScratch = NULL;
    if (unit->converter) {
        AudioConverterDispose(unit->converter);
        unit->converter = NULL;
    }
}

static OSStatus
unit_uninitialize(struct UnitInstance *unit)
{
    if (!unit->initialized)
        return noErr;
    if (unit->running)
        return kAudioUnitErr_CannotDoInCurrentContext;
    free_render_memory(unit);
    unit->inputSampleTime = 0.0;
    unit->inputSampleTimeValid = false;
    unit->initialized = false;
    return noErr;
}

OSStatus
AudioComponentInstanceNew(AudioComponent inComponent, AudioComponentInstance *outInstance)
{
    const struct ComponentRecord *record = component_record(inComponent);
    if (!record || !outInstance)
        return kAudio_ParamError;
    *outInstance = NULL;
    struct UnitInstance *unit = calloc(1, sizeof(*unit));
    if (!unit)
        return kAudioUnitErr_FailedInitialization;
    unit->signature = FINCH_UNIT_SIGNATURE;
    unit->component = record;
    unit->inputCount = 1;
    unit->maximumFrames = FINCH_DEFAULT_MAX_FRAMES;
    unit->outputVolume = 1.0f;
    unit->outputEnabled = true;
    unit->renderQuality = 127;
    AudioStreamBasicDescription format = default_format();
    unit->outputFormat = format;
    for (UInt32 i = 0; i < FINCH_MAX_INPUTS; i++) {
        unit->inputFormats[i] = format;
        unit->inputVolumes[i] = 1.0f;
        unit->inputEnabled[i] = true;
    }
    pthread_mutex_lock(&instance_registry_lock);
    size_t slot;
    for (slot = 0; slot < FINCH_MAX_INSTANCES &&
        atomic_load_explicit(&instances[slot], memory_order_relaxed); slot++)
        ;
    if (slot == FINCH_MAX_INSTANCES) {
        pthread_mutex_unlock(&instance_registry_lock);
        free(unit);
        return kAudioUnitErr_FailedInitialization;
    }
    atomic_store_explicit(&instances[slot], unit, memory_order_release);
    pthread_mutex_unlock(&instance_registry_lock);
    *outInstance = (AudioComponentInstance)(void *)unit;
    return noErr;
}

OSStatus
AudioComponentInstanceDispose(AudioComponentInstance inInstance)
{
    struct UnitInstance *unit = unit_instance((AudioUnit)inInstance);
    if (!unit)
        return kAudio_ParamError;

    pthread_mutex_lock(&instance_registry_lock);
    size_t slot;
    for (slot = 0; slot < FINCH_MAX_INSTANCES; slot++) {
        if (atomic_load_explicit(&instances[slot], memory_order_relaxed) == unit)
            break;
    }
    if (slot == FINCH_MAX_INSTANCES) {
        pthread_mutex_unlock(&instance_registry_lock);
        return kAudio_ParamError;
    }
    OSStatus status = unit_uninitialize(unit);
    if (status) {
        pthread_mutex_unlock(&instance_registry_lock);
        return status;
    }
    atomic_store_explicit(&instances[slot], NULL, memory_order_release);
    pthread_mutex_unlock(&instance_registry_lock);
    unit->signature = 0;
    free(unit);
    return noErr;
}

AudioComponent
AudioComponentInstanceGetComponent(AudioComponentInstance inInstance)
{
    struct UnitInstance *unit = unit_instance((AudioUnit)inInstance);
    return unit ? component_handle(unit->component) : NULL;
}

Boolean
AudioComponentInstanceCanDo(AudioComponentInstance inInstance, SInt16 inSelectorID)
{
    struct UnitInstance *unit = unit_instance((AudioUnit)inInstance);
    if (!unit)
        return false;

    switch (inSelectorID) {
    case kAudioUnitInitializeSelect:
    case kAudioUnitUninitializeSelect:
    case kAudioUnitGetPropertyInfoSelect:
    case kAudioUnitGetPropertySelect:
    case kAudioUnitSetPropertySelect:
    case kAudioUnitRenderSelect:
    case kAudioUnitResetSelect:
        return true;
    case kAudioUnitGetParameterSelect:
    case kAudioUnitSetParameterSelect:
        return unit->component->kind == UnitMixer;
    case kAudioOutputUnitStartSelect:
    case kAudioOutputUnitStopSelect:
        return unit->component->kind == UnitOutput;
    default:
        return false;
    }
}

static Boolean
input_element_valid(const struct UnitInstance *unit, UInt32 element)
{
    return element < unit->inputCount && element < FINCH_MAX_INPUTS;
}

static OSStatus
property_error_for_scope(AudioUnitScope scope)
{
    if (scope != kAudioUnitScope_Global && scope != kAudioUnitScope_Input && scope != kAudioUnitScope_Output)
        return kAudioUnitErr_InvalidScope;
    return noErr;
}

static OSStatus
property_info(struct UnitInstance *unit, AudioUnitPropertyID property, AudioUnitScope scope,
    AudioUnitElement element, UInt32 *size, Boolean *writable)
{
    if (!size)
        return kAudio_ParamError;
    OSStatus status = property_error_for_scope(scope);
    if (status)
        return status;
    Boolean writeable = false;
    switch (property) {
    case kAudioUnitProperty_StreamFormat:
        if (scope == kAudioUnitScope_Global)
            return kAudioUnitErr_InvalidScope;
        if (scope == kAudioUnitScope_Input && !input_element_valid(unit, element))
            return kAudioUnitErr_InvalidElement;
        if (scope == kAudioUnitScope_Output && element != 0)
            return kAudioUnitErr_InvalidElement;
        *size = sizeof(AudioStreamBasicDescription);
        writeable = true;
        break;
    case kAudioUnitProperty_SetRenderCallback:
        if (scope != kAudioUnitScope_Input)
            return kAudioUnitErr_InvalidScope;
        if (!input_element_valid(unit, element))
            return kAudioUnitErr_InvalidElement;
        *size = sizeof(AURenderCallbackStruct);
        writeable = true;
        break;
    case kAudioUnitProperty_ElementCount:
        if (scope == kAudioUnitScope_Global)
            return kAudioUnitErr_InvalidScope;
        if (scope == kAudioUnitScope_Input && element != 0)
            return kAudioUnitErr_InvalidElement;
        if (scope == kAudioUnitScope_Output && element != 0)
            return kAudioUnitErr_InvalidElement;
        *size = sizeof(UInt32);
        writeable = unit->component->kind == UnitMixer && scope == kAudioUnitScope_Input;
        break;
    case kAudioUnitProperty_MaximumFramesPerSlice:
        if (scope != kAudioUnitScope_Global)
            return kAudioUnitErr_InvalidScope;
        *size = sizeof(UInt32);
        writeable = true;
        break;
    case kAudioUnitProperty_RenderQuality:
        if (scope != kAudioUnitScope_Global)
            return kAudioUnitErr_InvalidScope;
        *size = sizeof(UInt32);
        writeable = true;
        break;
    case kAudioUnitProperty_Latency:
    case kAudioUnitProperty_TailTime:
        if (scope != kAudioUnitScope_Global)
            return kAudioUnitErr_InvalidScope;
        *size = sizeof(Float64);
        break;
    case kAudioUnitProperty_SampleRate:
        if (scope != kAudioUnitScope_Global)
            return kAudioUnitErr_InvalidScope;
        *size = sizeof(Float64);
        break;
    case kAudioUnitProperty_LastRenderError:
        if (scope != kAudioUnitScope_Global)
            return kAudioUnitErr_InvalidScope;
        *size = sizeof(OSStatus);
        break;
    case kAudioUnitProperty_ParameterList:
        if (unit->component->kind != UnitMixer)
            return kAudioUnitErr_InvalidProperty;
        if (scope != kAudioUnitScope_Global)
            return kAudioUnitErr_InvalidScope;
        *size = 3 * sizeof(AudioUnitParameterID);
        break;
    default:
        return kAudioUnitErr_InvalidProperty;
    }
    if (writable)
        *writable = writeable;
    return noErr;
}

OSStatus
AudioUnitGetPropertyInfo(AudioUnit inUnit, AudioUnitPropertyID inID, AudioUnitScope inScope,
    AudioUnitElement inElement, UInt32 *outDataSize, Boolean *outWritable)
{
    struct UnitInstance *unit = unit_instance(inUnit);
    if (!unit)
        return kAudio_ParamError;
    return property_info(unit, inID, inScope, inElement, outDataSize, outWritable);
}

static OSStatus
copy_property(const void *source, UInt32 sourceSize, UInt32 *ioDataSize, void *outData)
{
    if (!ioDataSize || !outData)
        return kAudio_ParamError;
    if (*ioDataSize < sourceSize)
        return kAudioUnitErr_InvalidPropertyValue;
    memcpy(outData, source, sourceSize);
    *ioDataSize = sourceSize;
    return noErr;
}

OSStatus
AudioUnitGetProperty(AudioUnit inUnit, AudioUnitPropertyID inID, AudioUnitScope inScope,
    AudioUnitElement inElement, void *outData, UInt32 *ioDataSize)
{
    struct UnitInstance *unit = unit_instance(inUnit);
    if (!unit)
        return kAudio_ParamError;
    UInt32 size = 0;
    OSStatus status = property_info(unit, inID, inScope, inElement, &size, NULL);
    if (status)
        return status;
    switch (inID) {
    case kAudioUnitProperty_StreamFormat:
        return copy_property(inScope == kAudioUnitScope_Input ? &unit->inputFormats[inElement] :
            &unit->outputFormat, size, ioDataSize, outData);
    case kAudioUnitProperty_SetRenderCallback:
        return copy_property(&unit->inputCallbacks[inElement], size, ioDataSize, outData);
    case kAudioUnitProperty_ElementCount: {
        UInt32 count = inScope == kAudioUnitScope_Input ? unit->inputCount : 1;
        return copy_property(&count, size, ioDataSize, outData);
    }
    case kAudioUnitProperty_MaximumFramesPerSlice:
        return copy_property(&unit->maximumFrames, size, ioDataSize, outData);
    case kAudioUnitProperty_RenderQuality:
        return copy_property(&unit->renderQuality, size, ioDataSize, outData);
    case kAudioUnitProperty_Latency: {
        Float64 value = 0.0;
        return copy_property(&value, size, ioDataSize, outData);
    }
    case kAudioUnitProperty_TailTime: {
        Float64 value = 0.0;
        return copy_property(&value, size, ioDataSize, outData);
    }
    case kAudioUnitProperty_SampleRate: {
        Float64 value = unit->outputFormat.mSampleRate;
        return copy_property(&value, size, ioDataSize, outData);
    }
    case kAudioUnitProperty_LastRenderError:
        return copy_property(&unit->lastRenderError, size, ioDataSize, outData);
    case kAudioUnitProperty_ParameterList: {
        const AudioUnitParameterID values[] = {
            kMultiChannelMixerParam_Volume,
            kMultiChannelMixerParam_Enable,
            kMultiChannelMixerParam_Pan
        };
        return copy_property(values, size, ioDataSize, outData);
    }
    default:
        return kAudioUnitErr_InvalidProperty;
    }
}

OSStatus
AudioUnitSetProperty(AudioUnit inUnit, AudioUnitPropertyID inID, AudioUnitScope inScope,
    AudioUnitElement inElement, const void *inData, UInt32 inDataSize)
{
    struct UnitInstance *unit = unit_instance(inUnit);
    if (!unit)
        return kAudio_ParamError;
    UInt32 size = 0;
    Boolean writable = false;
    OSStatus status = property_info(unit, inID, inScope, inElement, &size, &writable);
    if (status)
        return status;
    if (!writable)
        return kAudioUnitErr_PropertyNotWritable;
    if (!inData || inDataSize != size)
        return kAudioUnitErr_InvalidPropertyValue;
    if (unit->initialized)
        return kAudioUnitErr_Initialized;

    switch (inID) {
    case kAudioUnitProperty_StreamFormat: {
        const AudioStreamBasicDescription *format = inData;
        if (!valid_pcm_format(format))
            return kAudioUnitErr_FormatNotSupported;
        if (inScope == kAudioUnitScope_Input)
            unit->inputFormats[inElement] = *format;
        else
            unit->outputFormat = *format;
        return noErr;
    }
    case kAudioUnitProperty_SetRenderCallback:
        unit->inputCallbacks[inElement] = *(const AURenderCallbackStruct *)inData;
        return noErr;
    case kAudioUnitProperty_ElementCount: {
        UInt32 count = *(const UInt32 *)inData;
        if (!count || count > FINCH_MAX_INPUTS)
            return kAudioUnitErr_InvalidPropertyValue;
        unit->inputCount = count;
        return noErr;
    }
    case kAudioUnitProperty_MaximumFramesPerSlice: {
        UInt32 frames = *(const UInt32 *)inData;
        if (!frames || frames > FINCH_MAX_FRAMES)
            return kAudioUnitErr_InvalidPropertyValue;
        unit->maximumFrames = frames;
        return noErr;
    }
    case kAudioUnitProperty_RenderQuality: {
        UInt32 quality = *(const UInt32 *)inData;
        if (quality > 127)
            return kAudioUnitErr_InvalidPropertyValue;
        unit->renderQuality = quality;
        return noErr;
    }
    default:
        return kAudioUnitErr_InvalidProperty;
    }
}

static Boolean
valid_output_list(const AudioStreamBasicDescription *format, UInt32 frames, const AudioBufferList *list)
{
    if (!list || list->mNumberBuffers != buffer_count(format))
        return false;
    size_t needed = buffer_frame_bytes(format) * frames;
    for (UInt32 i = 0; i < list->mNumberBuffers; i++) {
        if (!list->mBuffers[i].mData || list->mBuffers[i].mDataByteSize < needed)
            return false;
    }
    return true;
}

static void
clear_output_list(const AudioStreamBasicDescription *format, UInt32 frames, AudioBufferList *list)
{
    if (!list || list->mNumberBuffers != buffer_count(format))
        return;
    size_t bytes = buffer_frame_bytes(format) * frames;
    for (UInt32 i = 0; i < list->mNumberBuffers; i++) {
        if (list->mBuffers[i].mData && list->mBuffers[i].mDataByteSize >= bytes) {
            memset(list->mBuffers[i].mData, 0, bytes);
            list->mBuffers[i].mDataByteSize = (UInt32)bytes;
        }
    }
}

static void
set_buffer_list(FinchAudioBufferList *list, const AudioStreamBasicDescription *format,
    void *memory, UInt32 frames)
{
    list->mNumberBuffers = buffer_count(format);
    UInt32 bytes = (UInt32)(buffer_frame_bytes(format) * frames);
    UInt32 channels = buffer_channels(format);
    UInt32 sampleBytes = container_bytes(format);
    for (UInt32 i = 0; i < list->mNumberBuffers; i++) {
        list->mBuffers[i].mNumberChannels = channels;
        list->mBuffers[i].mDataByteSize = bytes;
        list->mBuffers[i].mData = (UInt8 *)memory + (non_interleaved(format) ? (size_t)i * bytes : 0);
        if (non_interleaved(format))
            list->mBuffers[i].mDataByteSize = frames * sampleBytes;
    }
}

static const UInt8 *
sample_pointer(const AudioStreamBasicDescription *format, const AudioBufferList *list,
    UInt32 frame, UInt32 channel)
{
    UInt32 bytes = container_bytes(format);
    if (non_interleaved(format))
        return (const UInt8 *)list->mBuffers[channel].mData + (size_t)frame * bytes;
    return (const UInt8 *)list->mBuffers[0].mData + (size_t)frame * format->mBytesPerFrame +
        (size_t)channel * bytes;
}

static UInt8 *
mutable_sample_pointer(const AudioStreamBasicDescription *format, AudioBufferList *list,
    UInt32 frame, UInt32 channel)
{
    return (UInt8 *)sample_pointer(format, list, frame, channel);
}

static UInt64
read_integer(const UInt8 *bytes, UInt32 count, Boolean bigEndian)
{
    UInt64 value = 0;
    if (bigEndian) {
        for (UInt32 i = 0; i < count; i++)
            value = (value << 8) | bytes[i];
    } else {
        for (UInt32 i = 0; i < count; i++)
            value |= (UInt64)bytes[i] << (i * 8);
    }
    return value;
}

static void
write_integer(UInt8 *bytes, UInt32 count, Boolean bigEndian, UInt64 value)
{
    for (UInt32 i = 0; i < count; i++) {
        UInt32 shift = bigEndian ? (count - i - 1) * 8 : i * 8;
        bytes[i] = (UInt8)(value >> shift);
    }
}

static Float64
read_sample(const AudioStreamBasicDescription *format, const AudioBufferList *list,
    UInt32 frame, UInt32 channel)
{
    const UInt8 *sample = sample_pointer(format, list, frame, channel);
    UInt32 bytes = container_bytes(format);
    UInt32 bits = format->mBitsPerChannel;
    Boolean bigEndian = (format->mFormatFlags & kAudioFormatFlagIsBigEndian) != 0;
    UInt64 raw = read_integer(sample, bytes, bigEndian);
    if (format->mFormatFlags & kAudioFormatFlagIsFloat) {
        if (bits == 32) {
            UInt32 word = (UInt32)raw;
            Float32 value;
            memcpy(&value, &word, sizeof(value));
            return value;
        }
        Float64 value;
        memcpy(&value, &raw, sizeof(value));
        return value;
    }

    UInt64 mask = (UINT64_C(1) << bits) - 1;
    if (format->mFormatFlags & kAudioFormatFlagIsAlignedHigh)
        raw >>= bytes * 8 - bits;
    raw &= mask;
    if (format->mFormatFlags & kAudioFormatFlagIsSignedInteger) {
        UInt64 sign = UINT64_C(1) << (bits - 1);
        SInt64 value = (raw & sign) ? (SInt64)(raw | ~mask) : (SInt64)raw;
        return (Float64)value / (Float64)sign;
    }
    return ((Float64)raw - (Float64)(UINT64_C(1) << (bits - 1))) /
        (Float64)(UINT64_C(1) << (bits - 1));
}

static void
write_sample(const AudioStreamBasicDescription *format, AudioBufferList *list,
    UInt32 frame, UInt32 channel, Float64 value)
{
    UInt8 *sample = mutable_sample_pointer(format, list, frame, channel);
    UInt32 bytes = container_bytes(format);
    UInt32 bits = format->mBitsPerChannel;
    Boolean bigEndian = (format->mFormatFlags & kAudioFormatFlagIsBigEndian) != 0;
    if (format->mFormatFlags & kAudioFormatFlagIsFloat) {
        if (bits == 32) {
            Float32 converted = (Float32)value;
            UInt32 word;
            memcpy(&word, &converted, sizeof(word));
            write_integer(sample, bytes, bigEndian, word);
        } else {
            memcpy(sample, &value, sizeof(value));
            if (bigEndian != (__BYTE_ORDER__ == __ORDER_BIG_ENDIAN__)) {
                for (UInt32 i = 0; i < bytes / 2; i++) {
                    UInt8 temp = sample[i];
                    sample[i] = sample[bytes - i - 1];
                    sample[bytes - i - 1] = temp;
                }
            }
        }
        return;
    }

    Float64 upper = (Float64)((UINT64_C(1) << (bits - 1)) - 1);
    Float64 lower = -(Float64)(UINT64_C(1) << (bits - 1));
    if (format->mFormatFlags & kAudioFormatFlagIsSignedInteger) {
        if (value < -1.0) value = -1.0;
        if (value > 1.0) value = 1.0;
        Float64 scaled = value < 0.0 ? value * -lower : value * upper;
        SInt64 converted = (SInt64)(scaled < 0.0 ? scaled - 0.5 : scaled + 0.5);
        if (converted < (SInt64)lower) converted = (SInt64)lower;
        if (converted > (SInt64)upper) converted = (SInt64)upper;
        UInt64 raw = (UInt64)converted & ((UINT64_C(1) << bits) - 1);
        if (format->mFormatFlags & kAudioFormatFlagIsAlignedHigh)
            raw <<= bytes * 8 - bits;
        write_integer(sample, bytes, bigEndian, raw);
    } else {
        if (value < -1.0) value = -1.0;
        if (value > 1.0) value = 1.0;
        Float64 scaled = (value + 1.0) * 0.5 * (Float64)((UINT64_C(1) << bits) - 1);
        UInt64 raw = (UInt64)(scaled + 0.5);
        if (format->mFormatFlags & kAudioFormatFlagIsAlignedHigh)
            raw <<= bytes * 8 - bits;
        write_integer(sample, bytes, bigEndian, raw);
    }
}

static OSStatus
allocate_render_memory(struct UnitInstance *unit)
{
    if (unit->component->kind == UnitConverter) {
        double ratio = unit->inputFormats[0].mSampleRate / unit->outputFormat.mSampleRate;
        double needed = ceil((double)unit->maximumFrames * ratio) + 512.0;
        if (!isfinite(needed) || needed <= 0.0 || needed > FINCH_MAX_INPUT_FRAMES)
            return kAudioUnitErr_TooManyFramesToProcess;
        UInt32 frames = (UInt32)needed;
        size_t frameBytes = frame_storage_bytes(&unit->inputFormats[0]);
        if (!frameBytes || frames > SIZE_MAX / frameBytes)
            return kAudioUnitErr_InvalidPropertyValue;
        unit->inputScratch[0] = calloc(frames, frameBytes);
        if (!unit->inputScratch[0])
            return kAudioUnitErr_FailedInitialization;
        unit->inputScratchFrames[0] = frames;
        OSStatus status = AudioConverterNew(&unit->inputFormats[0], &unit->outputFormat, &unit->converter);
        if (status) {
            free_render_memory(unit);
            return kAudioUnitErr_FormatNotSupported;
        }
        return noErr;
    }

    if (unit->component->kind == UnitMixer) {
        size_t samples = (size_t)unit->maximumFrames * unit->outputFormat.mChannelsPerFrame;
        if (samples > SIZE_MAX / sizeof(Float32))
            return kAudioUnitErr_InvalidPropertyValue;
        unit->mixScratch = calloc(samples, sizeof(Float32));
        if (!unit->mixScratch)
            return kAudioUnitErr_FailedInitialization;
        for (UInt32 i = 0; i < unit->inputCount; i++) {
            if (fabs(unit->inputFormats[i].mSampleRate - unit->outputFormat.mSampleRate) > 0.001)
                return kAudioUnitErr_FormatNotSupported;
            size_t frameBytes = frame_storage_bytes(&unit->inputFormats[i]);
            if (!frameBytes || unit->maximumFrames > SIZE_MAX / frameBytes)
                return kAudioUnitErr_InvalidPropertyValue;
            unit->inputScratch[i] = calloc(unit->maximumFrames, frameBytes);
            if (!unit->inputScratch[i])
                return kAudioUnitErr_FailedInitialization;
            unit->inputScratchFrames[i] = unit->maximumFrames;
        }
    }
    return noErr;
}

OSStatus
AudioUnitInitialize(AudioUnit inUnit)
{
    struct UnitInstance *unit = unit_instance(inUnit);
    if (!unit)
        return kAudio_ParamError;
    if (unit->initialized)
        return kAudioUnitErr_Initialized;
    if (!valid_pcm_format(&unit->outputFormat))
        return kAudioUnitErr_FormatNotSupported;
    for (UInt32 i = 0; i < unit->inputCount; i++) {
        if (!valid_pcm_format(&unit->inputFormats[i]))
            return kAudioUnitErr_FormatNotSupported;
    }
    OSStatus status = allocate_render_memory(unit);
    if (status) {
        free_render_memory(unit);
        return status;
    }
    unit->lastRenderError = noErr;
    unit->initialized = true;
    return noErr;
}

OSStatus
AudioUnitUninitialize(AudioUnit inUnit)
{
    struct UnitInstance *unit = unit_instance(inUnit);
    return unit ? unit_uninitialize(unit) : kAudio_ParamError;
}

typedef struct {
    struct UnitInstance *unit;
    AudioUnitRenderActionFlags flags;
    AudioTimeStamp timestamp;
    UInt32 inputBus;
    UInt32 deliveredFrames;
} ConverterInputContext;

static OSStatus
rendered_frames(const AudioStreamBasicDescription *format, const AudioBufferList *list,
    UInt32 requested, UInt32 *outFrames)
{
    if (!list || !outFrames)
        return kAudio_ParamError;
    *outFrames = 0;

    UInt32 count = buffer_count(format);
    size_t bytesPerFrame = buffer_frame_bytes(format);
    if (list->mNumberBuffers != count || !bytesPerFrame ||
        requested > SIZE_MAX / bytesPerFrame)
        return kAudioUnitErr_InvalidPropertyValue;

    size_t capacity = bytesPerFrame * requested;
    UInt32 channels = buffer_channels(format);
    UInt32 frames = requested;
    for (UInt32 i = 0; i < count; i++) {
        if ((!list->mBuffers[i].mData && list->mBuffers[i].mDataByteSize) ||
            list->mBuffers[i].mNumberChannels != channels ||
            list->mBuffers[i].mDataByteSize > capacity ||
            list->mBuffers[i].mDataByteSize % bytesPerFrame != 0)
            return kAudioUnitErr_InvalidPropertyValue;

        UInt32 available = (UInt32)(list->mBuffers[i].mDataByteSize / bytesPerFrame);
        if (available < frames)
            frames = available;
    }
    *outFrames = frames;
    return noErr;
}

static void
advance_timestamp(AudioTimeStamp *timestamp, UInt32 frames)
{
    if (timestamp->mFlags & kAudioTimeStampSampleTimeValid)
        timestamp->mSampleTime += frames;
}

static OSStatus
converter_input_proc(AudioConverterRef converter, UInt32 *ioNumberDataPackets,
    AudioBufferList *ioData, AudioStreamPacketDescription **outPacketDescriptions, void *userData)
{
    (void)converter;
    (void)outPacketDescriptions;
    ConverterInputContext *context = userData;
    struct UnitInstance *unit = context->unit;
    UInt32 requested = *ioNumberDataPackets;
    const AudioStreamBasicDescription *format = &unit->inputFormats[context->inputBus];
    AURenderCallbackStruct callback = unit->inputCallbacks[context->inputBus];
    if (!callback.inputProc)
        return kAudioUnitErr_NoConnection;
    if (requested > unit->inputScratchFrames[context->inputBus])
        return kAudioUnitErr_TooManyFramesToProcess;

    set_buffer_list((FinchAudioBufferList *)ioData, format, unit->inputScratch[context->inputBus], requested);
    AudioUnitRenderActionFlags flags = context->flags;
    AudioTimeStamp timestamp = context->timestamp;
    advance_timestamp(&timestamp, context->deliveredFrames);
    OSStatus status = callback.inputProc(callback.inputProcRefCon, &flags, &timestamp,
        context->inputBus, requested, ioData);
    if (status)
        return status;
    UInt32 frames = 0;
    status = rendered_frames(format, ioData, requested, &frames);
    if (status)
        return status;
    context->deliveredFrames += frames;
    *ioNumberDataPackets = frames;
    return noErr;
}

static Boolean
render_input_bus(struct UnitInstance *unit, UInt32 bus, const AudioTimeStamp *timestamp,
    AudioUnitRenderActionFlags flags, UInt32 frames, FinchAudioBufferList *list, UInt32 *actualFrames)
{
    const AudioStreamBasicDescription *format = &unit->inputFormats[bus];
    AURenderCallbackStruct callback = unit->inputCallbacks[bus];
    if (!callback.inputProc) {
        *actualFrames = 0;
        return true;
    }
    if (frames > unit->inputScratchFrames[bus])
        return false;
    set_buffer_list(list, format, unit->inputScratch[bus], frames);
    AudioUnitRenderActionFlags callbackFlags = flags;
    OSStatus status = callback.inputProc(callback.inputProcRefCon, &callbackFlags, timestamp,
        bus, frames, (AudioBufferList *)list);
    if (status) {
        unit->lastRenderError = status;
        *actualFrames = 0;
        return false;
    }
    status = rendered_frames(format, (AudioBufferList *)list, frames, actualFrames);
    if (status) {
        unit->lastRenderError = status;
        return false;
    }
    return true;
}

static OSStatus
render_mixer(struct UnitInstance *unit, AudioUnitRenderActionFlags *flags,
    const AudioTimeStamp *timestamp, UInt32 frames, AudioBufferList *ioData)
{
    const AudioStreamBasicDescription *output = &unit->outputFormat;
    if (!valid_output_list(output, frames, ioData))
        return kAudioUnitErr_InvalidPropertyValue;
    size_t samples = (size_t)frames * output->mChannelsPerFrame;
    memset(unit->mixScratch, 0, samples * sizeof(Float32));
    clear_output_list(output, frames, ioData);
    for (UInt32 bus = 0; bus < unit->inputCount; bus++) {
        if (!unit->inputEnabled[bus] || unit->inputVolumes[bus] == 0.0f)
            continue;
        FinchAudioBufferList input = {0};
        UInt32 got = 0;
        if (!render_input_bus(unit, bus, timestamp, flags ? *flags : 0, frames, &input, &got))
            return unit->lastRenderError ? unit->lastRenderError : kAudioUnitErr_TooManyFramesToProcess;
        const AudioStreamBasicDescription *format = &unit->inputFormats[bus];
        for (UInt32 frame = 0; frame < got; frame++) {
            for (UInt32 channel = 0; channel < output->mChannelsPerFrame; channel++) {
                Float64 sample = 0.0;
                if (format->mChannelsPerFrame == 1) {
                    sample = read_sample(format, (AudioBufferList *)&input, frame, 0);
                } else if (output->mChannelsPerFrame == 1) {
                    for (UInt32 inChannel = 0; inChannel < format->mChannelsPerFrame; inChannel++)
                        sample += read_sample(format, (AudioBufferList *)&input, frame, inChannel);
                    sample /= format->mChannelsPerFrame;
                } else {
                    UInt32 inChannel = channel < format->mChannelsPerFrame ? channel : format->mChannelsPerFrame - 1;
                    sample = read_sample(format, (AudioBufferList *)&input, frame, inChannel);
                }
                Float64 pan = unit->inputPans[bus];
                if (output->mChannelsPerFrame > 1) {
                    if (channel == 0 && pan > 0.0)
                        sample *= 1.0 - pan;
                    else if (channel == 1 && pan < 0.0)
                        sample *= 1.0 + pan;
                }
                unit->mixScratch[(size_t)frame * output->mChannelsPerFrame + channel] +=
                    (Float32)(sample * unit->inputVolumes[bus]);
            }
        }
    }

    Boolean silence = true;
    for (UInt32 frame = 0; frame < frames; frame++) {
        for (UInt32 channel = 0; channel < output->mChannelsPerFrame; channel++) {
            Float64 sample = unit->outputEnabled ?
                unit->mixScratch[(size_t)frame * output->mChannelsPerFrame + channel] * unit->outputVolume : 0.0;
            if (sample != 0.0)
                silence = false;
            write_sample(output, ioData, frame, channel, sample);
        }
    }
    for (UInt32 i = 0; i < ioData->mNumberBuffers; i++)
        ioData->mBuffers[i].mDataByteSize = (UInt32)(buffer_frame_bytes(output) * frames);
    if (flags) {
        if (silence)
            *flags |= kAudioUnitRenderAction_OutputIsSilence;
        else
            *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
    }
    return noErr;
}

OSStatus
AudioUnitRender(AudioUnit inUnit, AudioUnitRenderActionFlags *ioActionFlags,
    const AudioTimeStamp *inTimeStamp, UInt32 inOutputBusNumber, UInt32 inNumberFrames,
    AudioBufferList *ioData)
{
    struct UnitInstance *unit = unit_instance(inUnit);
    if (!unit || !ioData || !inTimeStamp)
        return kAudio_ParamError;
    if (!unit->initialized)
        return kAudioUnitErr_Uninitialized;
    if (unit->component->kind == UnitOutput) {
        unit->lastRenderError = kAudioUnitErr_NoConnection;
        return kAudioUnitErr_NoConnection;
    }
    if (inOutputBusNumber != 0) {
        unit->lastRenderError = kAudioUnitErr_InvalidElement;
        return kAudioUnitErr_InvalidElement;
    }
    if (inNumberFrames > unit->maximumFrames) {
        unit->lastRenderError = kAudioUnitErr_TooManyFramesToProcess;
        return kAudioUnitErr_TooManyFramesToProcess;
    }
    if (!inNumberFrames) {
        unit->lastRenderError = noErr;
        return noErr;
    }

    unit->lastRenderError = noErr;
    OSStatus status;
    if (unit->component->kind == UnitMixer) {
        status = render_mixer(unit, ioActionFlags, inTimeStamp, inNumberFrames, ioData);
    } else {
        if (!unit->inputCallbacks[0].inputProc)
            status = kAudioUnitErr_NoConnection;
        else if (!valid_output_list(&unit->outputFormat, inNumberFrames, ioData))
            status = kAudioUnitErr_InvalidPropertyValue;
        else {
            ConverterInputContext context = {unit, ioActionFlags ? *ioActionFlags : 0,
                *inTimeStamp, 0, 0};
            if (!unit->inputSampleTimeValid &&
                (inTimeStamp->mFlags & kAudioTimeStampSampleTimeValid)) {
                Float64 rateRatio = unit->inputFormats[0].mSampleRate /
                    unit->outputFormat.mSampleRate;
                Float64 inputTime = inTimeStamp->mSampleTime * rateRatio;
                if (!isfinite(inputTime)) {
                    status = kAudioUnitErr_InvalidPropertyValue;
                    goto render_finished;
                }
                unit->inputSampleTime = inputTime;
                unit->inputSampleTimeValid = true;
            }
            if (unit->inputSampleTimeValid) {
                context.timestamp.mSampleTime = unit->inputSampleTime;
                context.timestamp.mFlags |= kAudioTimeStampSampleTimeValid;
            }
            UInt32 packets = inNumberFrames;
            status = AudioConverterFillComplexBuffer(unit->converter, converter_input_proc,
                &context, &packets, ioData, NULL);
            if (unit->inputSampleTimeValid)
                unit->inputSampleTime += context.deliveredFrames;
            if (!status) {
                for (UInt32 i = 0; i < ioData->mNumberBuffers; i++)
                    ioData->mBuffers[i].mDataByteSize = (UInt32)(buffer_frame_bytes(&unit->outputFormat) * packets);
                if (ioActionFlags) {
                    if (!packets)
                        *ioActionFlags |= kAudioUnitRenderAction_OutputIsSilence;
                    else
                        *ioActionFlags &= ~kAudioUnitRenderAction_OutputIsSilence;
                }
            }
        }
render_finished:
        if (status && valid_output_list(&unit->outputFormat, inNumberFrames, ioData))
            clear_output_list(&unit->outputFormat, inNumberFrames, ioData);
    }
    unit->lastRenderError = status;
    return status;
}

OSStatus
AudioUnitReset(AudioUnit inUnit, AudioUnitScope inScope, AudioUnitElement inElement)
{
    struct UnitInstance *unit = unit_instance(inUnit);
    if (!unit)
        return kAudio_ParamError;
    OSStatus status = property_error_for_scope(inScope);
    if (status)
        return status;
    if (inScope == kAudioUnitScope_Input && !input_element_valid(unit, inElement))
        return kAudioUnitErr_InvalidElement;
    if (inScope == kAudioUnitScope_Output && inElement != 0)
        return kAudioUnitErr_InvalidElement;
    if (unit->converter) {
        status = AudioConverterReset(unit->converter);
        if (status)
            return status;
    }
    if (unit->component->kind == UnitConverter) {
        unit->inputSampleTime = 0.0;
        unit->inputSampleTimeValid = false;
    }
    if (unit->mixScratch)
        memset(unit->mixScratch, 0, (size_t)unit->maximumFrames *
            unit->outputFormat.mChannelsPerFrame * sizeof(Float32));
    unit->lastRenderError = noErr;
    return noErr;
}

OSStatus
AudioOutputUnitStart(AudioUnit inUnit)
{
    struct UnitInstance *unit = unit_instance(inUnit);
    if (!unit || unit->component->kind != UnitOutput)
        return kAudio_ParamError;
    if (!unit->initialized)
        return kAudioUnitErr_Uninitialized;
    unit->running = false;
    return kAudioUnitErr_NoConnection;
}

OSStatus
AudioOutputUnitStop(AudioUnit inUnit)
{
    struct UnitInstance *unit = unit_instance(inUnit);
    if (!unit || unit->component->kind != UnitOutput)
        return kAudio_ParamError;
    unit->running = false;
    return noErr;
}

static OSStatus
get_mixer_parameter(struct UnitInstance *unit, AudioUnitParameterID id, AudioUnitScope scope,
    AudioUnitElement element, AudioUnitParameterValue *value)
{
    if (unit->component->kind != UnitMixer)
        return kAudioUnitErr_InvalidParameter;
    if (id == kMultiChannelMixerParam_Volume || id == kMultiChannelMixerParam_Enable) {
        if (scope == kAudioUnitScope_Global && element == 0) {
            *value = id == kMultiChannelMixerParam_Volume ? unit->outputVolume : unit->outputEnabled;
            return noErr;
        }
        if (scope == kAudioUnitScope_Input && input_element_valid(unit, element)) {
            *value = id == kMultiChannelMixerParam_Volume ? unit->inputVolumes[element] : unit->inputEnabled[element];
            return noErr;
        }
    }
    if (id == kMultiChannelMixerParam_Pan && scope == kAudioUnitScope_Input && input_element_valid(unit, element)) {
        *value = unit->inputPans[element];
        return noErr;
    }
    if (scope == kAudioUnitScope_Input && !input_element_valid(unit, element))
        return kAudioUnitErr_InvalidElement;
    return kAudioUnitErr_InvalidParameter;
}

OSStatus
AudioUnitGetParameter(AudioUnit inUnit, AudioUnitParameterID inID, AudioUnitScope inScope,
    AudioUnitElement inElement, AudioUnitParameterValue *outValue)
{
    struct UnitInstance *unit = unit_instance(inUnit);
    if (!unit || !outValue)
        return kAudio_ParamError;
    return get_mixer_parameter(unit, inID, inScope, inElement, outValue);
}

OSStatus
AudioUnitSetParameter(AudioUnit inUnit, AudioUnitParameterID inID, AudioUnitScope inScope,
    AudioUnitElement inElement, AudioUnitParameterValue inValue, UInt32 inBufferOffsetInFrames)
{
    struct UnitInstance *unit = unit_instance(inUnit);
    if (!unit)
        return kAudio_ParamError;
    if (!isfinite(inValue) || inBufferOffsetInFrames)
        return kAudioUnitErr_InvalidParameterValue;
    AudioUnitParameterValue previous;
    OSStatus status = get_mixer_parameter(unit, inID, inScope, inElement, &previous);
    if (status)
        return status;
    if (inID == kMultiChannelMixerParam_Volume) {
        if (inScope == kAudioUnitScope_Global)
            unit->outputVolume = inValue;
        else
            unit->inputVolumes[inElement] = inValue;
    } else if (inID == kMultiChannelMixerParam_Enable) {
        if (inScope == kAudioUnitScope_Global)
            unit->outputEnabled = inValue >= 0.5f;
        else
            unit->inputEnabled[inElement] = inValue >= 0.5f;
    } else {
        if (inValue < -1.0f || inValue > 1.0f)
            return kAudioUnitErr_InvalidParameterValue;
        unit->inputPans[inElement] = inValue;
    }
    return noErr;
}
