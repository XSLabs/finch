/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* AVAudioConverter's supported PCM paths use AudioConverter for the work. */
#import <AVFAudio/AVAudioConverter.h>
#import <AudioToolbox/AudioConverter.h>
#import <Block.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

NSString *const AVSampleRateConverterAlgorithm_Normal = @"AVSampleRateConverterAlgorithm_Normal";
NSString *const AVSampleRateConverterAlgorithm_Mastering = @"AVSampleRateConverterAlgorithm_Mastering";
NSString *const AVSampleRateConverterAlgorithm_MinimumPhase = @"AVSampleRateConverterAlgorithm_MinimumPhase";

struct AVAudioConverterImpl {
    AudioConverterRef converter;
    AVAudioFormat *inputFormat;
    AVAudioFormat *outputFormat;
    NSArray *channelMap;
    NSData *magicCookie;
    NSString *algorithm;
    NSString *bitRateStrategy;
    NSInteger bitRate;
    NSInteger quality;
    AVAudioConverterPrimeMethod primeMethod;
    AVAudioConverterPrimeInfo primeInfo;
    AVAudioPCMBuffer *pendingInputBuffer;
    UInt32 pendingInputOffset;
    BOOL dither;
    BOOL endOfStream;
};

struct AVAudioConverterInputContext {
    AVAudioConverterInputBlock block;
    AVAudioFormat *format;
    struct AVAudioConverterImpl *impl;
    AVAudioConverterInputStatus lastStatus;
    OSStatus callbackError;
    UInt32 calls;
};

static NSError *
converter_error(OSStatus status, NSString *message)
{
    return [NSError errorWithDomain:NSOSStatusErrorDomain code:status
        userInfo:@{NSLocalizedDescriptionKey: message}];
}

static void
set_converter_error(NSError **outError, OSStatus status, NSString *message)
{
    if (outError)
        *outError = converter_error(status, message);
}

static BOOL
is_pcm(AVAudioFormat *format)
{
    return format && format.streamDescription &&
        format.streamDescription->mFormatID == kAudioFormatLinearPCM;
}

static void
release_pending_input(struct AVAudioConverterImpl *impl)
{
    [impl->pendingInputBuffer release];
    impl->pendingInputBuffer = nil;
    impl->pendingInputOffset = 0;
}

static OSStatus
input_proc(AudioConverterRef converter, UInt32 *packets, AudioBufferList *data,
    AudioStreamPacketDescription **descriptions, void *userData)
{
    (void)converter;
    (void)descriptions;
    struct AVAudioConverterInputContext *context = userData;
    context->lastStatus = AVAudioConverterInputStatus_NoDataNow;
    if (!packets || !data || !context->block) {
        context->callbackError = kAudio_ParamError;
        return context->callbackError;
    }

    struct AVAudioConverterImpl *impl = context->impl;
    if (impl->endOfStream) {
        context->lastStatus = AVAudioConverterInputStatus_EndOfStream;
        *packets = 0;
        return noErr;
    }

    if (impl->pendingInputBuffer &&
        impl->pendingInputOffset >= impl->pendingInputBuffer.frameLength)
        release_pending_input(impl);

    if (!impl->pendingInputBuffer) {
        AVAudioConverterInputStatus inputStatus = AVAudioConverterInputStatus_NoDataNow;
        AVAudioBuffer *buffer = nil;
        context->calls++;
        @try {
            buffer = context->block(*packets, &inputStatus);
        } @catch (NSException *exception) {
            (void)exception;
            context->callbackError = kAudioConverterErr_UnspecifiedError;
            return context->callbackError;
        }
        context->lastStatus = inputStatus;
        if (inputStatus == AVAudioConverterInputStatus_NoDataNow ||
            inputStatus == AVAudioConverterInputStatus_EndOfStream) {
            if (buffer) {
                context->callbackError = kAudioConverterErr_InvalidInputSize;
                return context->callbackError;
            }
            if (inputStatus == AVAudioConverterInputStatus_EndOfStream)
                impl->endOfStream = YES;
            *packets = 0;
            return noErr;
        }
        if (inputStatus != AVAudioConverterInputStatus_HaveData ||
            ![buffer isKindOfClass:[AVAudioPCMBuffer class]] ||
            ![buffer.format isEqual:context->format]) {
            context->callbackError = kAudioConverterErr_FormatNotSupported;
            return context->callbackError;
        }

        AVAudioPCMBuffer *pcmBuffer = (AVAudioPCMBuffer *)buffer;
        const AudioBufferList *source = pcmBuffer.audioBufferList;
        if (!pcmBuffer.frameLength || !source || !source->mNumberBuffers ||
            source->mNumberBuffers > data->mNumberBuffers) {
            context->callbackError = kAudioConverterErr_InvalidInputSize;
            return context->callbackError;
        }
        impl->pendingInputBuffer = [pcmBuffer retain];
        impl->pendingInputOffset = 0;
    }

    AVAudioPCMBuffer *pcmBuffer = impl->pendingInputBuffer;
    const AudioBufferList *source = pcmBuffer.audioBufferList;
    if (!source || !source->mNumberBuffers || source->mNumberBuffers > data->mNumberBuffers ||
        impl->pendingInputOffset >= pcmBuffer.frameLength) {
        context->callbackError = kAudioConverterErr_InvalidInputSize;
        return context->callbackError;
    }
    UInt32 requested = *packets;
    UInt32 available = pcmBuffer.frameLength - impl->pendingInputOffset;
    UInt32 frames = available < requested ? available : requested;
    UInt32 bytesPerFrame = context->format.streamDescription->mBytesPerFrame;
    if (!frames || !bytesPerFrame) {
        context->callbackError = kAudioConverterErr_InvalidInputSize;
        return context->callbackError;
    }
    UInt64 byteOffset = (UInt64)impl->pendingInputOffset * bytesPerFrame;
    UInt64 byteCount = (UInt64)frames * bytesPerFrame;
    data->mNumberBuffers = source->mNumberBuffers;
    for (UInt32 i = 0; i < source->mNumberBuffers; i++) {
        const AudioBuffer *sourceBuffer = &source->mBuffers[i];
        if (!sourceBuffer->mData || byteOffset > sourceBuffer->mDataByteSize ||
            byteCount > sourceBuffer->mDataByteSize - byteOffset || byteCount > UINT32_MAX) {
            context->callbackError = kAudioConverterErr_InvalidInputSize;
            return context->callbackError;
        }
        data->mBuffers[i] = *sourceBuffer;
        data->mBuffers[i].mData = (UInt8 *)sourceBuffer->mData + (size_t)byteOffset;
        data->mBuffers[i].mDataByteSize = (UInt32)byteCount;
    }
    context->lastStatus = AVAudioConverterInputStatus_HaveData;
    impl->pendingInputOffset += frames;
    *packets = frames;
    return noErr;
}

static void
dispose_impl(struct AVAudioConverterImpl *impl)
{
    if (!impl)
        return;
    release_pending_input(impl);
    if (impl->converter)
        AudioConverterDispose(impl->converter);
    [impl->inputFormat release];
    [impl->outputFormat release];
    [impl->channelMap release];
    [impl->magicCookie release];
    [impl->algorithm release];
    [impl->bitRateStrategy release];
    free(impl);
}

@implementation AVAudioConverter

- (instancetype)initFromFormat:(AVAudioFormat *)fromFormat toFormat:(AVAudioFormat *)toFormat
{
    if (!is_pcm(fromFormat) || !is_pcm(toFormat) || !fromFormat.channelCount || !toFormat.channelCount ||
        fromFormat.channelCount > 256 || toFormat.channelCount > 256) {
        [self release];
        return nil;
    }
    AudioConverterRef converter = NULL;
    OSStatus status = AudioConverterNew(fromFormat.streamDescription, toFormat.streamDescription, &converter);
    if (status) {
        if (converter)
            AudioConverterDispose(converter);
        [self release];
        return nil;
    }
    self = [super init];
    if (!self) {
        AudioConverterDispose(converter);
        return nil;
    }
    struct AVAudioConverterImpl *impl = calloc(1, sizeof(*impl));
    if (!impl) {
        AudioConverterDispose(converter);
        [self release];
        return nil;
    }
    impl->converter = converter;
    impl->inputFormat = [fromFormat retain];
    impl->outputFormat = [toFormat retain];
    impl->quality = AVAudioQualityMin;
    impl->primeMethod = AVAudioConverterPrimeMethod_Pre;
    impl->algorithm = [AVSampleRateConverterAlgorithm_Normal copy];
    UInt32 initialQuality = (UInt32)impl->quality;
    (void)AudioConverterSetProperty(converter, kAudioConverterSampleRateConverterQuality,
        sizeof(initialQuality), &initialQuality);
    UInt32 initialPrimeMethod = (UInt32)impl->primeMethod;
    (void)AudioConverterSetProperty(converter, kAudioConverterPrimeMethod,
        sizeof(initialPrimeMethod), &initialPrimeMethod);

    UInt32 size = 0;
    if (AudioConverterGetPropertyInfo(converter, kAudioConverterChannelMap, &size, NULL) == noErr && size) {
        if (size > 256 * sizeof(SInt32)) {
            dispose_impl(impl);
            [self release];
            return nil;
        }
        UInt32 count = size / sizeof(SInt32);
        SInt32 *map = calloc(count, sizeof(*map));
        if (map) {
            UInt32 actualSize = size;
            if (AudioConverterGetProperty(converter, kAudioConverterChannelMap, &actualSize, map) == noErr) {
                NSMutableArray *values = [NSMutableArray arrayWithCapacity:count];
                for (UInt32 i = 0; i < count; i++)
                    [values addObject:[NSNumber numberWithInt:map[i]]];
                impl->channelMap = [values copy];
            }
            free(map);
        }
    }
    _impl = impl;
    return self;
}

- (void)reset
{
    struct AVAudioConverterImpl *impl = _impl;
    if (impl && impl->converter) {
        AudioConverterReset(impl->converter);
        release_pending_input(impl);
        impl->endOfStream = NO;
    }
}

- (AVAudioFormat *)inputFormat { return ((struct AVAudioConverterImpl *)_impl)->inputFormat; }
- (AVAudioFormat *)outputFormat { return ((struct AVAudioConverterImpl *)_impl)->outputFormat; }

- (NSArray<NSNumber *> *)channelMap { return ((struct AVAudioConverterImpl *)_impl)->channelMap; }

- (void)setChannelMap:(NSArray<NSNumber *> *)channelMap
{
    struct AVAudioConverterImpl *impl = _impl;
    if (![channelMap isKindOfClass:[NSArray class]])
        return;
    UInt32 outputs = impl->outputFormat.channelCount;
    UInt32 inputs = impl->inputFormat.channelCount;
    if (channelMap.count != outputs || outputs > UINT32_MAX / sizeof(SInt32))
        return;
    NSArray *copy = [channelMap copy];
    if (!copy)
        return;
    SInt32 *map = calloc(outputs, sizeof(*map));
    if (!map) {
        [copy release];
        return;
    }
    BOOL valid = YES;
    for (UInt32 i = 0; i < outputs; i++) {
        id value = channelMap[i];
        if (![value isKindOfClass:[NSNumber class]]) {
            valid = NO;
            break;
        }
        NSInteger index = [value integerValue];
        if (index < -1 || index >= (NSInteger)inputs || index < INT32_MIN || index > INT32_MAX) {
            valid = NO;
            break;
        }
        map[i] = (SInt32)index;
    }
    if (valid && AudioConverterSetProperty(impl->converter, kAudioConverterChannelMap,
            outputs * sizeof(*map), map) == noErr) {
        [impl->channelMap release];
        impl->channelMap = copy;
        copy = nil;
    }
    [copy release];
    free(map);
}

- (NSData *)magicCookie { return ((struct AVAudioConverterImpl *)_impl)->magicCookie; }

- (void)setMagicCookie:(NSData *)magicCookie
{
    struct AVAudioConverterImpl *impl = _impl;
    if (magicCookie == impl->magicCookie)
        return;
    [magicCookie retain];
    [impl->magicCookie release];
    impl->magicCookie = magicCookie;
}

- (BOOL)downmix { return NO; }

- (void)setDownmix:(BOOL)downmix
{
    if (downmix)
        [NSException raise:NSInvalidArgumentException
            format:@"This converter supports channel routing but not channel mixing."];
}

- (BOOL)dither { return ((struct AVAudioConverterImpl *)_impl)->dither; }

- (void)setDither:(BOOL)dither
{
    struct AVAudioConverterImpl *impl = _impl;
    UInt32 value = dither ? kDitherAlgorithm_TPDF : 0;
    if (AudioConverterSetProperty(impl->converter, kAudioConverterPropertyDithering,
            sizeof(value), &value) == noErr)
        impl->dither = dither;
}

- (NSInteger)sampleRateConverterQuality
{
    return ((struct AVAudioConverterImpl *)_impl)->quality;
}

- (void)setSampleRateConverterQuality:(NSInteger)quality
{
    if (quality < 0 || quality > kAudioConverterQuality_Max)
        return;
    struct AVAudioConverterImpl *impl = _impl;
    UInt32 value = (UInt32)quality;
    if (AudioConverterSetProperty(impl->converter, kAudioConverterSampleRateConverterQuality,
            sizeof(value), &value) == noErr)
        impl->quality = quality;
}

- (NSString *)sampleRateConverterAlgorithm
{
    return ((struct AVAudioConverterImpl *)_impl)->algorithm;
}

- (void)setSampleRateConverterAlgorithm:(NSString *)algorithm
{
    struct AVAudioConverterImpl *impl = _impl;
    NSString *selected = algorithm ?: AVSampleRateConverterAlgorithm_Normal;
    UInt32 value;
    if ([selected isEqualToString:AVSampleRateConverterAlgorithm_Normal])
        value = kAudioConverterSampleRateConverterComplexity_Normal;
    else if ([selected isEqualToString:AVSampleRateConverterAlgorithm_Mastering])
        value = kAudioConverterSampleRateConverterComplexity_Mastering;
    else if ([selected isEqualToString:AVSampleRateConverterAlgorithm_MinimumPhase])
        value = kAudioConverterSampleRateConverterComplexity_MinimumPhase;
    else
        return;
    if (AudioConverterSetProperty(impl->converter, kAudioConverterSampleRateConverterComplexity,
            sizeof(value), &value) == noErr) {
        [selected retain];
        [impl->algorithm release];
        impl->algorithm = selected;
    }
}

- (AVAudioConverterPrimeMethod)primeMethod
{
    return ((struct AVAudioConverterImpl *)_impl)->primeMethod;
}

- (void)setPrimeMethod:(AVAudioConverterPrimeMethod)primeMethod
{
    if (primeMethod < AVAudioConverterPrimeMethod_Pre || primeMethod > AVAudioConverterPrimeMethod_None)
        return;
    struct AVAudioConverterImpl *impl = _impl;
    UInt32 value = (UInt32)primeMethod;
    if (AudioConverterSetProperty(impl->converter, kAudioConverterPrimeMethod, sizeof(value), &value) == noErr)
        impl->primeMethod = primeMethod;
}

- (AVAudioConverterPrimeInfo)primeInfo
{
    return ((struct AVAudioConverterImpl *)_impl)->primeInfo;
}

- (void)setPrimeInfo:(AVAudioConverterPrimeInfo)primeInfo
{
    if (primeInfo.leadingFrames || primeInfo.trailingFrames)
        [NSException raise:NSInvalidArgumentException
            format:@"This AudioConverter implementation does not accept manual priming frames."];
}

- (BOOL)convertToBuffer:(AVAudioPCMBuffer *)outputBuffer
    fromBuffer:(const AVAudioPCMBuffer *)inputBuffer error:(NSError **)outError
{
    if (outError) *outError = nil;
    struct AVAudioConverterImpl *impl = _impl;
    if (![inputBuffer isKindOfClass:[AVAudioPCMBuffer class]] ||
        ![outputBuffer isKindOfClass:[AVAudioPCMBuffer class]] ||
        ![inputBuffer.format isEqual:impl->inputFormat] ||
        ![outputBuffer.format isEqual:impl->outputFormat]) {
        set_converter_error(outError, kAudio_ParamError,
            @"The input and output buffers must match the converter's PCM formats.");
        return NO;
    }
    if (impl->inputFormat.sampleRate != impl->outputFormat.sampleRate) {
        set_converter_error(outError, kAudioConverterErr_OperationNotSupported,
            @"Sample-rate conversion needs the input-block conversion method.");
        return NO;
    }
    UInt32 frames = inputBuffer.frameLength;
    if (frames > outputBuffer.frameCapacity) {
        set_converter_error(outError, kAudioConverterErr_InvalidOutputSize,
            @"The output buffer is too small for this conversion.");
        return NO;
    }
    outputBuffer.frameLength = frames;
    if (!frames)
        return YES;
    OSStatus status = AudioConverterConvertComplexBuffer(impl->converter, frames,
        inputBuffer.audioBufferList, outputBuffer.mutableAudioBufferList);
    if (status) {
        outputBuffer.frameLength = 0;
        set_converter_error(outError, status, @"Could not convert the PCM buffers.");
        return NO;
    }
    outputBuffer.frameLength = frames;
    return YES;
}

- (AVAudioConverterOutputStatus)convertToBuffer:(AVAudioBuffer *)outputBuffer error:(NSError **)outError
    withInputFromBlock:(AVAudioConverterInputBlock)inputBlock
{
    if (outError) *outError = nil;
    struct AVAudioConverterImpl *impl = _impl;
    if (![outputBuffer isKindOfClass:[AVAudioPCMBuffer class]] ||
        ![outputBuffer.format isEqual:impl->outputFormat] || !inputBlock) {
        set_converter_error(outError, kAudio_ParamError,
            @"The output buffer and input block must match the converter's PCM formats.");
        return AVAudioConverterOutputStatus_Error;
    }
    AVAudioPCMBuffer *pcmOutput = (AVAudioPCMBuffer *)outputBuffer;
    UInt32 capacity = pcmOutput.frameCapacity;
    pcmOutput.frameLength = capacity;
    struct AVAudioConverterInputContext context = {0};
    context.block = Block_copy(inputBlock);
    context.format = impl->inputFormat;
    context.impl = impl;
    context.lastStatus = AVAudioConverterInputStatus_NoDataNow;
    if (!context.block) {
        pcmOutput.frameLength = 0;
        set_converter_error(outError, -108, @"Could not retain the input callback.");
        return AVAudioConverterOutputStatus_Error;
    }

    UInt32 frames = capacity;
    OSStatus status = AudioConverterFillComplexBuffer(impl->converter, input_proc, &context,
        &frames, pcmOutput.mutableAudioBufferList, NULL);
    pcmOutput.frameLength = frames;
    Block_release(context.block);
    if (status || context.callbackError) {
        pcmOutput.frameLength = 0;
        OSStatus error = context.callbackError ? context.callbackError : status;
        set_converter_error(outError, error, @"The audio converter input callback failed.");
        return AVAudioConverterOutputStatus_Error;
    }
    if (frames == capacity)
        return AVAudioConverterOutputStatus_HaveData;
    if (context.lastStatus == AVAudioConverterInputStatus_EndOfStream) {
        return frames ? AVAudioConverterOutputStatus_HaveData : AVAudioConverterOutputStatus_EndOfStream;
    }
    if (!frames && impl->endOfStream)
        return AVAudioConverterOutputStatus_EndOfStream;
    if (context.lastStatus == AVAudioConverterInputStatus_NoDataNow || !frames)
        return AVAudioConverterOutputStatus_InputRanDry;
    return AVAudioConverterOutputStatus_HaveData;
}

- (NSInteger)bitRate { return 0; }
- (void)setBitRate:(NSInteger)bitRate { (void)bitRate; }
- (NSString *)bitRateStrategy { return nil; }
- (void)setBitRateStrategy:(NSString *)strategy { (void)strategy; }

- (NSInteger)maximumOutputPacketSize
{
    UInt32 size = sizeof(UInt32), value = 0;
    if (AudioConverterGetProperty(((struct AVAudioConverterImpl *)_impl)->converter,
            kAudioConverterPropertyMaximumOutputPacketSize, &size, &value) != noErr)
        return 0;
    return value;
}

- (NSArray<NSNumber *> *)availableEncodeBitRates { return nil; }
- (NSArray<NSNumber *> *)applicableEncodeBitRates { return nil; }
- (NSArray<NSNumber *> *)availableEncodeSampleRates { return nil; }
- (NSArray<NSNumber *> *)applicableEncodeSampleRates { return nil; }
- (NSArray<NSNumber *> *)availableEncodeChannelLayoutTags { return nil; }

- (void)dealloc
{
    dispose_impl(_impl);
    [super dealloc];
}

@end
