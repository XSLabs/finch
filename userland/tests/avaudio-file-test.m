/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Compare AVAudioFile's PCM/G.711 paths, errors and close behavior with macOS. */
#import <AVFAudio/AVAudioFile.h>
#import <AVFAudio/AVAudioBuffer.h>
#import <AVFAudio/AVAudioSettings.h>
#import <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static unsigned failures;

static void
check(const char *name, BOOL passed)
{
    printf("%s=%d\n", name, (int)passed);
    if (!passed)
        failures++;
}

static NSURL *
file_url(const char *directory, const char *name)
{
    char path[512];
    snprintf(path, sizeof(path), "%s/%s", directory, name);
    return [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
}

static NSDictionary *
pcm_settings(UInt32 channels, UInt32 bits)
{
    return @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVSampleRateKey: @44100,
        AVNumberOfChannelsKey: @(channels),
        AVLinearPCMBitDepthKey: @(bits),
        AVLinearPCMIsFloatKey: @NO,
        AVLinearPCMIsBigEndianKey: @NO,
        AVLinearPCMIsNonInterleaved: @NO
    };
}

static void
remove_file(NSURL *url)
{
    if (url.path)
        unlink(url.fileSystemRepresentation);
}

static int
run_pcm_file(const char *directory)
{
    NSError *error = nil;
    NSURL *url = [file_url(directory, "pcm.wav") retain];
    NSDictionary *settings = pcm_settings(2, 16);
    AVAudioFile *writer = [[AVAudioFile alloc] initForWriting:url settings:settings error:&error];
    check("writer-created", writer != nil && error == nil);
    if (!writer) {
        [url release];
        return 1;
    }
    check("writer-format", writer.fileFormat.streamDescription->mFormatID == kAudioFormatLinearPCM &&
        writer.fileFormat.streamDescription->mBitsPerChannel == 16 && writer.processingFormat.isStandard &&
        !writer.processingFormat.isInterleaved && writer.url == url);

    AVAudioPCMBuffer *input = [[AVAudioPCMBuffer alloc] initWithPCMFormat:writer.processingFormat frameCapacity:5];
    const float left[] = {-1.0f, -0.5f, -0.25f, 0.5f, 1.0f};
    const float right[] = {1.0f, 0.5f, 0.25f, -0.5f, -1.0f};
    for (UInt32 i = 0; i < 5; i++) {
        input.floatChannelData[0][i] = left[i];
        input.floatChannelData[1][i] = right[i];
    }
    input.frameLength = 5;
    BOOL wrote = [writer writeFromBuffer:input error:&error];
    check("writer-wrote-five", wrote && error == nil && writer.framePosition == 5 && writer.length == 5);
    [writer close];
    check("writer-close", !writer.isOpen && writer.length == 5 && writer.url == url);

    error = nil;
    AVAudioFile *reader = [[AVAudioFile alloc] initForReading:url error:&error];
    check("reader-created", reader != nil && error == nil && reader.length == 5 &&
        reader.fileFormat.streamDescription->mBitsPerChannel == 16 && reader.processingFormat.isStandard);
    if (!reader) {
        [input release]; [writer release]; [url release];
        return 1;
    }
    AVAudioPCMBuffer *output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:reader.processingFormat frameCapacity:4];
    error = nil;
    BOOL firstRead = [reader readIntoBuffer:output frameCount:3 error:&error];
    BOOL firstSamples = output.frameLength == 3 && fabsf(output.floatChannelData[0][0] + 1.0f) < 0.001f &&
        fabsf(output.floatChannelData[1][1] - 0.5f) < 0.001f;
    check("reader-first-three", firstRead && error == nil && reader.framePosition == 3 && firstSamples);
    error = nil;
    BOOL secondRead = [reader readIntoBuffer:output frameCount:4 error:&error];
    check("reader-short-final-read", secondRead && error == nil && output.frameLength == 2 && reader.framePosition == 5);
    error = nil;
    BOOL eofRead = [reader readIntoBuffer:output error:&error];
    printf("reader-eof-result=%d,%d,%u,%lld\n", (int)eofRead, error != nil,
        (unsigned)output.frameLength, (long long)reader.framePosition);
    check("reader-eof", !eofRead && error == nil && output.frameLength == 0 && reader.framePosition == 5);

    reader.framePosition = 2;
    error = nil;
    BOOL seekRead = [reader readIntoBuffer:output frameCount:1 error:&error];
    check("reader-seek", seekRead && error == nil && output.frameLength == 1 && reader.framePosition == 3 &&
        fabsf(output.floatChannelData[0][0] + 0.25f) < 0.001f);

    AVAudioFormat *wrongFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
        sampleRate:44100 channels:2 interleaved:YES];
    AVAudioPCMBuffer *wrongBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:wrongFormat frameCapacity:2];
    error = nil;
    BOOL rejectedWrongFormat = NO;
    @try {
        rejectedWrongFormat = ![reader readIntoBuffer:wrongBuffer error:&error] && error != nil;
    } @catch (NSException *exception) {
        (void)exception;
        rejectedWrongFormat = YES;
    }
    printf("reader-wrong-format-result=%d,%d,%u,%lld\n", (int)rejectedWrongFormat, error != nil,
        (unsigned)wrongBuffer.frameLength, (long long)reader.framePosition);
    check("reader-rejects-wrong-format", rejectedWrongFormat);

    error = nil;
    BOOL rejectedTooManyFrames = NO;
    @try {
        rejectedTooManyFrames = ![reader readIntoBuffer:output frameCount:5 error:&error] && error != nil;
    } @catch (NSException *exception) {
        (void)exception;
        rejectedTooManyFrames = YES;
    }
    check("reader-rejects-oversized-read", rejectedTooManyFrames);
    BOOL negativeSeekRejected = NO;
    @try {
        reader.framePosition = -1;
    } @catch (NSException *exception) {
        (void)exception;
        negativeSeekRejected = YES;
    }
    printf("reader-negative-seek-result=%d,%lld\n", (int)negativeSeekRejected, (long long)reader.framePosition);
    check("reader-rejects-negative-seek", negativeSeekRejected && reader.framePosition == 3);
    [reader close];
    error = nil;
    check("reader-close-rejects-read", ![reader readIntoBuffer:output error:&error] && error != nil);

    AVAudioFile *integerReader = [[AVAudioFile alloc] initForReading:url commonFormat:AVAudioPCMFormatInt16
        interleaved:YES error:&error];
    if (integerReader) {
        AVAudioPCMBuffer *integerBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:integerReader.processingFormat frameCapacity:5];
        error = nil;
        BOOL integerRead = [integerReader readIntoBuffer:integerBuffer error:&error];
        int16_t *const *samples = integerBuffer.int16ChannelData;
        check("reader-custom-int16", integerRead && error == nil && integerBuffer.frameLength == 5 &&
            samples && samples[0][0] == INT16_MIN && samples[0][2] < 0 && samples[1][2] > 0 && samples[0][8] == INT16_MAX);
        [integerBuffer release];
    } else {
        check("reader-custom-int16", NO);
    }

    NSError *missingError = nil;
    NSURL *missingURL = file_url(directory, "missing.wav");
    AVAudioFile *missing = [[AVAudioFile alloc] initForReading:missingURL error:&missingError];
    check("missing-file-fails", missing == nil && missingError != nil);
    [missing release];

    NSMutableDictionary *compressedSettings = [NSMutableDictionary dictionaryWithDictionary:settings];
    compressedSettings[AVFormatIDKey] = @(kAudioFormatMPEG4AAC);
    compressedSettings[AVAudioFileTypeKey] = @(kAudioFileWAVEType);
    NSError *compressedError = nil;
    AVAudioFile *compressed = [[AVAudioFile alloc] initForWriting:file_url(directory, "unsupported.wav")
        settings:compressedSettings error:&compressedError];
    check("unsupported-compressed-write-fails", compressed == nil && compressedError != nil);
    [compressed close];
    [compressed release];

    [integerReader release]; [wrongBuffer release]; [wrongFormat release];
    [output release]; [reader release]; [input release]; [writer release];
    remove_file(file_url(directory, "unsupported.wav"));
    remove_file(url);
    [url release];
    return 0;
}

static int
run_g711_file(const char *directory)
{
    NSURL *url = [file_url(directory, "law.wav") retain];
    NSMutableDictionary *settings = [NSMutableDictionary dictionaryWithDictionary:pcm_settings(1, 16)];
    settings[AVFormatIDKey] = @(kAudioFormatULaw);
    NSError *error = nil;
    AVAudioFile *writer = [[AVAudioFile alloc] initForWriting:url settings:settings error:&error];
    check("g711-writer-created", writer != nil && error == nil && writer.fileFormat.streamDescription->mFormatID == kAudioFormatULaw);
    if (writer) {
        AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:writer.processingFormat frameCapacity:4];
        buffer.floatChannelData[0][0] = -1.0f;
        buffer.floatChannelData[0][1] = -0.25f;
        buffer.floatChannelData[0][2] = 0.25f;
        buffer.floatChannelData[0][3] = 1.0f;
        buffer.frameLength = 4;
        error = nil;
        BOOL wrote = [writer writeFromBuffer:buffer error:&error];
        [writer close];
        check("g711-write-close", wrote && error == nil && !writer.isOpen);
        [buffer release];
    }
    error = nil;
    AVAudioFile *reader = [[AVAudioFile alloc] initForReading:url error:&error];
    check("g711-reader", reader != nil && error == nil &&
        reader.fileFormat.streamDescription->mFormatID == kAudioFormatULaw && reader.length == 4);
    if (reader) {
        AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:reader.processingFormat frameCapacity:4];
        error = nil;
        BOOL read = [reader readIntoBuffer:buffer error:&error];
        check("g711-read", read && error == nil && buffer.frameLength == 4 &&
            buffer.floatChannelData[0][0] < -0.9f && buffer.floatChannelData[0][3] > 0.9f);
        [buffer release];
    }
    [reader release]; [writer release];
    remove_file(url);
    [url release];
    return 0;
}

int
main(void)
{
    char directory[] = "/tmp/finch-avaudio-file-XXXXXX";
    if (!mkdtemp(directory)) {
        perror("mkdtemp");
        return 1;
    }
    @autoreleasepool {
        puts("AVAudioFile comparison");
        int failed = run_pcm_file(directory);
        failed |= run_g711_file(directory);
        rmdir(directory);
        printf("failures=%u\n", failures);
        return failed || failures ? 1 : 0;
    }
}
