/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Compare PCM conversion, callback status and buffer ownership with macOS. */
#import <AVFAudio/AVAudioConverter.h>
#import <AVFAudio/AVAudioBuffer.h>
#import <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned failures;

static void
check(const char *name, BOOL passed)
{
    printf("%s=%d\n", name, (int)passed);
    if (!passed)
        failures++;
}

static AVAudioFormat *
format(AVAudioCommonFormat common, double rate, UInt32 channels, BOOL interleaved)
{
    return [[AVAudioFormat alloc] initWithCommonFormat:common sampleRate:rate
        channels:channels interleaved:interleaved];
}

static void
direct_conversion(void)
{
    AVAudioFormat *sourceFormat = format(AVAudioPCMFormatFloat32, 44100, 1, NO);
    AVAudioFormat *resultFormat = format(AVAudioPCMFormatInt16, 44100, 1, YES);
    AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:sourceFormat toFormat:resultFormat];
    check("simple-converter-created", converter != nil);
    if (!converter) {
        [sourceFormat release]; [resultFormat release];
        return;
    }
    check("converter-retains-formats", [converter.inputFormat isEqual:sourceFormat] &&
        [converter.outputFormat isEqual:resultFormat] && converter.sampleRateConverterQuality >= 0 &&
        converter.sampleRateConverterQuality <= kAudioConverterQuality_Max &&
        converter.primeMethod >= AVAudioConverterPrimeMethod_Pre &&
        converter.primeMethod <= AVAudioConverterPrimeMethod_None);
    printf("converter-defaults=%ld,%ld\n", (long)converter.sampleRateConverterQuality, (long)converter.primeMethod);
    AVAudioPCMBuffer *input = [[AVAudioPCMBuffer alloc] initWithPCMFormat:sourceFormat frameCapacity:7];
    const float values[] = {-1.0f, -0.75f, -0.25f, 0.0f, 0.25f, 0.75f, 1.0f};
    for (UInt32 i = 0; i < 7; i++)
        input.floatChannelData[0][i] = values[i];
    input.frameLength = 7;
    AVAudioPCMBuffer *output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:resultFormat frameCapacity:7];
    NSError *error = nil;
    BOOL converted = [converter convertToBuffer:output fromBuffer:input error:&error];
    int16_t *const *samples = output.int16ChannelData;
    check("simple-conversion", converted && error == nil && output.frameLength == 7 && samples &&
        samples[0][0] == INT16_MIN && samples[0][2] < 0 && samples[0][3] == 0 &&
        samples[0][4] > 0 && samples[0][6] == INT16_MAX);
    printf("simple-samples=%d,%d,%d,%d,%d,%d,%d\n", samples[0][0], samples[0][1], samples[0][2],
        samples[0][3], samples[0][4], samples[0][5], samples[0][6]);

    AVAudioFormat *smallFormat = format(AVAudioPCMFormatInt16, 44100, 1, YES);
    AVAudioPCMBuffer *small = [[AVAudioPCMBuffer alloc] initWithPCMFormat:smallFormat frameCapacity:2];
    error = nil;
    BOOL shortOutputRejected = NO;
    @try {
        shortOutputRejected = ![converter convertToBuffer:small fromBuffer:input error:&error] && error != nil;
    } @catch (NSException *exception) {
        (void)exception;
        shortOutputRejected = YES;
    }
    check("simple-rejects-short-output", shortOutputRejected);

    AVAudioFormat *rateFormat = format(AVAudioPCMFormatInt16, 48000, 1, YES);
    AVAudioConverter *rateConverter = [[AVAudioConverter alloc] initFromFormat:resultFormat toFormat:rateFormat];
    AVAudioPCMBuffer *rateOutput = [[AVAudioPCMBuffer alloc] initWithPCMFormat:rateFormat frameCapacity:12];
    error = nil;
    BOOL simpleRateRejected = NO;
    @try {
        simpleRateRejected = ![rateConverter convertToBuffer:rateOutput fromBuffer:(AVAudioPCMBuffer *)output error:&error] && error != nil;
    } @catch (NSException *exception) {
        (void)exception;
        simpleRateRejected = YES;
    }
    check("simple-rejects-rate-conversion", simpleRateRejected);

    AVAudioFormat *stereo = format(AVAudioPCMFormatInt16, 44100, 2, NO);
    AVAudioConverter *routing = [[AVAudioConverter alloc] initFromFormat:stereo toFormat:stereo];
    AVAudioPCMBuffer *stereoInput = [[AVAudioPCMBuffer alloc] initWithPCMFormat:stereo frameCapacity:3];
    AVAudioPCMBuffer *stereoOutput = [[AVAudioPCMBuffer alloc] initWithPCMFormat:stereo frameCapacity:3];
    int16_t *const *leftRight = stereoInput.int16ChannelData;
    leftRight[0][0] = 11; leftRight[1][0] = 22;
    leftRight[0][1] = 33; leftRight[1][1] = 44;
    leftRight[0][2] = 55; leftRight[1][2] = 66;
    stereoInput.frameLength = 3;
    routing.channelMap = @[@1, @0];
    NSArray *swapped = [routing.channelMap copy];
    routing.channelMap = @[@7, @0];
    BOOL invalidMapKeptOld = [routing.channelMap isEqual:swapped];
    error = nil;
    BOOL routed = [routing convertToBuffer:stereoOutput fromBuffer:stereoInput error:&error];
    int16_t *const *routedSamples = stereoOutput.int16ChannelData;
    printf("channel-map-result=%d,%d,%d,%d,%d\n", invalidMapKeptOld,
        routedSamples[0][0], routedSamples[1][0], routedSamples[0][1], routedSamples[1][1]);
    check("channel-map-and-invalid-map", routed && error == nil && invalidMapKeptOld &&
        routedSamples[0][0] == 22 && routedSamples[1][0] == 11 &&
        routedSamples[0][1] == 44 && routedSamples[1][1] == 33);
    [swapped release];

    AudioStreamBasicDescription unsupportedASBD = {0};
    unsupportedASBD.mSampleRate = 44100;
    unsupportedASBD.mFormatID = 'zzzz';
    unsupportedASBD.mChannelsPerFrame = 1;
    AVAudioFormat *unsupportedFormat = [[AVAudioFormat alloc] initWithStreamDescription:&unsupportedASBD];
    AVAudioConverter *unsupported = unsupportedFormat ?
        [[AVAudioConverter alloc] initFromFormat:unsupportedFormat toFormat:sourceFormat] : nil;
    check("unsupported-compressed-converter-fails", unsupportedFormat != nil && unsupported == nil);

    [unsupported release]; [unsupportedFormat release]; [stereoOutput release]; [stereoInput release];
    [routing release]; [stereo release]; [rateOutput release]; [rateConverter release]; [rateFormat release];
    [small release]; [smallFormat release]; [output release]; [input release]; [converter release];
    [resultFormat release]; [sourceFormat release];
}

static void
callback_status(void)
{
    AVAudioFormat *audioFormat = format(AVAudioPCMFormatInt16, 44100, 1, YES);
    AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:audioFormat toFormat:audioFormat];
    AVAudioPCMBuffer *output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:audioFormat frameCapacity:4];
    __block UInt32 turn = 0;
    AVAudioConverterInputBlock block = ^AVAudioBuffer *(AVAudioPacketCount requested, AVAudioConverterInputStatus *status) {
        if (turn == 0) {
            turn++;
            *status = AVAudioConverterInputStatus_NoDataNow;
            return nil;
        }
        if (turn > 1) {
            *status = AVAudioConverterInputStatus_EndOfStream;
            return nil;
        }
        turn++;
        UInt32 frames = requested < 2 ? requested : 2;
        AVAudioPCMBuffer *input = [[AVAudioPCMBuffer alloc] initWithPCMFormat:audioFormat frameCapacity:frames];
        input.int16ChannelData[0][0] = 101;
        if (frames > 1)
            input.int16ChannelData[0][1] = 202;
        input.frameLength = frames;
        *status = AVAudioConverterInputStatus_HaveData;
        return [input autorelease];
    };
    NSError *error = nil;
    AVAudioConverterOutputStatus status = [converter convertToBuffer:output error:&error withInputFromBlock:block];
    check("callback-no-data-now", status == AVAudioConverterOutputStatus_InputRanDry && output.frameLength == 0 && error == nil);
    status = [converter convertToBuffer:output error:&error withInputFromBlock:block];
    check("callback-partial-data", status == AVAudioConverterOutputStatus_HaveData && output.frameLength == 2 && error == nil &&
        output.int16ChannelData[0][0] == 101 && output.int16ChannelData[0][1] == 202);
    status = [converter convertToBuffer:output error:&error withInputFromBlock:block];
    check("callback-end-of-stream", status == AVAudioConverterOutputStatus_EndOfStream && output.frameLength == 0 && error == nil);
    [converter reset];
    __block BOOL resetProvided = NO;
    AVAudioConverterInputBlock resetBlock = ^AVAudioBuffer *(AVAudioPacketCount requested, AVAudioConverterInputStatus *resetStatus) {
        (void)requested;
        if (resetProvided) {
            *resetStatus = AVAudioConverterInputStatus_EndOfStream;
            return nil;
        }
        resetProvided = YES;
        AVAudioPCMBuffer *input = [[AVAudioPCMBuffer alloc] initWithPCMFormat:audioFormat frameCapacity:1];
        input.int16ChannelData[0][0] = 303;
        input.frameLength = 1;
        *resetStatus = AVAudioConverterInputStatus_HaveData;
        return [input autorelease];
    };
    status = [converter convertToBuffer:output error:&error withInputFromBlock:resetBlock];
    check("callback-reset", converter != nil && status == AVAudioConverterOutputStatus_HaveData &&
        output.frameLength == 1 && output.int16ChannelData[0][0] == 303 && error == nil);
    [output release]; [converter release]; [audioFormat release];
}

static void
callback_ownership(void)
{
    AVAudioFormat *audioFormat = format(AVAudioPCMFormatInt16, 44100, 1, YES);
    AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:audioFormat toFormat:audioFormat];
    AVAudioPCMBuffer *output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:audioFormat frameCapacity:2];
    __block UInt32 deallocations = 0;
    __block BOOL provided = NO;
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    AVAudioConverterInputBlock block = ^AVAudioBuffer *(AVAudioPacketCount requested, AVAudioConverterInputStatus *status) {
        (void)requested;
        if (provided) {
            *status = AVAudioConverterInputStatus_EndOfStream;
            return nil;
        }
        provided = YES;
        UInt32 frames = 4;
        int16_t *samples = calloc(frames, sizeof(*samples));
        if (!samples) {
            *status = AVAudioConverterInputStatus_NoDataNow;
            return nil;
        }
        for (UInt32 i = 0; i < frames; i++)
            samples[i] = (int16_t)(i * 100 + 1);
        struct { UInt32 count; AudioBuffer buffers[1]; } list = {1, {{1, frames * sizeof(*samples), samples}}};
        AVAudioPCMBuffer *input = [[AVAudioPCMBuffer alloc] initWithPCMFormat:audioFormat
            bufferListNoCopy:(AudioBufferList *)&list deallocator:^(const AudioBufferList *passed) {
                deallocations++;
                free(passed->mBuffers[0].mData);
            }];
        if (!input) {
            free(samples);
            *status = AVAudioConverterInputStatus_NoDataNow;
            return nil;
        }
        input.frameLength = frames;
        *status = AVAudioConverterInputStatus_HaveData;
        return [input autorelease];
    };
    NSError *error = nil;
    AVAudioConverterOutputStatus status = [converter convertToBuffer:output error:&error withInputFromBlock:block];
    int16_t *const *samples = output.int16ChannelData;
    BOOL firstHalf = status == AVAudioConverterOutputStatus_HaveData && output.frameLength == 2 && error == nil &&
        samples && samples[0][0] == 1 && samples[0][1] == 101 && deallocations == 0;
    status = [converter convertToBuffer:output error:&error withInputFromBlock:block];
    BOOL secondHalf = status == AVAudioConverterOutputStatus_HaveData && output.frameLength == 2 && error == nil &&
        samples && samples[0][0] == 201 && samples[0][1] == 301 && deallocations == 0;
    status = [converter convertToBuffer:output error:&error withInputFromBlock:block];
    BOOL ended = status == AVAudioConverterOutputStatus_EndOfStream && output.frameLength == 0 && error == nil &&
        deallocations == 0;
    [converter release];
    [pool drain];
    printf("callback-overprovision-result=%d,%d,%d,%u\n", (int)firstHalf, (int)secondHalf,
        (int)ended, (unsigned)deallocations);
    check("callback-overprovisioned-remainder", firstHalf && secondHalf && ended && deallocations == 1);
    [output release]; [audioFormat release];
}

static void
callback_resampling(void)
{
    AVAudioFormat *inputFormat = format(AVAudioPCMFormatInt16, 44100, 1, YES);
    AVAudioFormat *outputFormat = format(AVAudioPCMFormatInt16, 48000, 1, YES);
    AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:inputFormat toFormat:outputFormat];
    AVAudioPCMBuffer *output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:outputFormat frameCapacity:160];
    int16_t *samples = calloc(97, sizeof(*samples));
    if (!samples) {
        check("callback-resampling-allocation", NO);
        [output release]; [converter release]; [outputFormat release]; [inputFormat release];
        return;
    }
    for (UInt32 i = 0; i < 97; i++)
        samples[i] = (int16_t)((int)i * 503 - 24000);
    __block UInt32 at = 0;
    __block UInt32 calls = 0;
    AVAudioConverterInputBlock block = ^AVAudioBuffer *(AVAudioPacketCount requested, AVAudioConverterInputStatus *status) {
        calls++;
        if (at == 97) {
            *status = AVAudioConverterInputStatus_EndOfStream;
            return nil;
        }
        UInt32 frames = requested;
        if (frames > 13) frames = 13;
        if (frames > 97 - at) frames = 97 - at;
        AVAudioPCMBuffer *input = [[AVAudioPCMBuffer alloc] initWithPCMFormat:inputFormat frameCapacity:frames];
        memcpy(input.int16ChannelData[0], samples + at, frames * sizeof(*samples));
        input.frameLength = frames;
        at += frames;
        *status = AVAudioConverterInputStatus_HaveData;
        return [input autorelease];
    };
    NSError *error = nil;
    AVAudioConverterOutputStatus status = [converter convertToBuffer:output error:&error withInputFromBlock:block];
    check("callback-resampling", status == AVAudioConverterOutputStatus_HaveData && error == nil &&
        output.frameLength > 90 && output.frameLength <= 110 && at == 97 && calls > 1 && calls <= 97);
    printf("callback-resampling-frames=%u\n", (unsigned)output.frameLength);
    status = [converter convertToBuffer:output error:&error withInputFromBlock:block];
    check("callback-resampling-end", status == AVAudioConverterOutputStatus_EndOfStream && output.frameLength == 0 && error == nil);
    free(samples);
    [output release]; [converter release]; [outputFormat release]; [inputFormat release];
}

static void
callback_rejects_bad_input(void)
{
    AVAudioFormat *inputFormat = format(AVAudioPCMFormatInt16, 44100, 1, YES);
    AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:inputFormat toFormat:inputFormat];
    AVAudioPCMBuffer *output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:inputFormat frameCapacity:4];
    AVAudioConverterInputBlock block = ^AVAudioBuffer *(AVAudioPacketCount requested, AVAudioConverterInputStatus *status) {
        (void)requested;
        *status = (AVAudioConverterInputStatus)99;
        return nil;
    };
    NSError *error = nil;
    AVAudioConverterOutputStatus status = AVAudioConverterOutputStatus_Error;
    @try {
        status = [converter convertToBuffer:output error:&error withInputFromBlock:block];
    } @catch (NSException *exception) {
        (void)exception;
    }
    printf("callback-invalid-status-result=%ld,%d\n", (long)status, error != nil);
    check("callback-rejects-invalid-status", status == AVAudioConverterOutputStatus_Error && error != nil);
    [output release]; [converter release]; [inputFormat release];
}

int
main(void)
{
    @autoreleasepool {
        puts("AVAudioConverter comparison");
        direct_conversion();
        callback_status();
        callback_ownership();
        callback_resampling();
        callback_rejects_bad_input();
        printf("failures=%u\n", failures);
        return failures ? 1 : 0;
    }
}
