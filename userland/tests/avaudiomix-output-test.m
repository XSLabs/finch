/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Compare audio mix output from the PCM track in the shared synthetic movie. */
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include "avmovie.h"
#include "avframes.h"

static double
mean_absolute_sample(CMSampleBufferRef sample)
{
    CMAudioFormatDescriptionRef description = (CMAudioFormatDescriptionRef)CMSampleBufferGetFormatDescription(sample);
    const AudioStreamBasicDescription *format = CMAudioFormatDescriptionGetStreamBasicDescription(description);
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
    size_t length = block ? CMBlockBufferGetDataLength(block) : 0;
    if (!format || !block || format->mChannelsPerFrame == 0 || format->mBytesPerFrame == 0)
        return -1;
    uint32_t bits = format->mBitsPerChannel;
    size_t samples = MIN(length / (bits / 8), 4096u);
    double sum = 0;
    for (size_t i = 0; i < samples; i++) {
        double value = 0;
        if ((format->mFormatFlags & kAudioFormatFlagIsFloat) && bits == 32) {
            float f;
            CMBlockBufferCopyDataBytes(block, i * 4, 4, &f);
            value = f;
        } else if ((format->mFormatFlags & kAudioFormatFlagIsSignedInteger) && bits == 16) {
            int16_t v;
            CMBlockBufferCopyDataBytes(block, i * 2, 2, &v);
            value = (double)v / 32768.0;
        } else {
            return -1;
        }
        sum += fabs(value);
    }
    return samples ? sum / samples : 0;
}

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        printf("%s\n", class_getImageName([AVAssetReaderAudioMixOutput class]));
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"avaudiomix-output-%d.mov", getpid()]];
        NSData *frame = [NSData dataWithBytes:frame0 length:sizeof(frame0)];
        [build_movie_with_frames(@[frame]) writeToFile:path atomically:YES];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
        AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
        NSError *error = nil;
        AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
        AVAssetReaderAudioMixOutput *output = [[AVAssetReaderAudioMixOutput alloc] initWithAudioTracks:@[track] audioSettings:nil];
        AVMutableAudioMixInputParameters *parameters = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:track];
        [parameters setVolume:0.0f atTime:kCMTimeZero];
        AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
        mix.inputParameters = @[parameters];
        output.audioMix = mix;
        printf("setup tracks %lu settings %d mix %d add %d error %ld\n",
               (unsigned long)output.audioTracks.count, output.audioSettings != nil, output.audioMix != nil,
               [reader canAddOutput:output], (long)error.code);
        [reader addOutput:output];
        printf("start %d\n", [reader startReading]);
        CMSampleBufferRef sample = NULL;
        while ((sample = [output copyNextSampleBuffer])) {
            if (CMSampleBufferGetNumSamples(sample)) {
                CMAudioFormatDescriptionRef description = (CMAudioFormatDescriptionRef)CMSampleBufferGetFormatDescription(sample);
                const AudioStreamBasicDescription *format = CMAudioFormatDescriptionGetStreamBasicDescription(description);
                printf("sample count %ld pts %.3f rate %.0f channels %u bits %u flags %u mean-abs %.6f\n",
                       (long)CMSampleBufferGetNumSamples(sample), CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)),
                       format->mSampleRate, format->mChannelsPerFrame, format->mBitsPerChannel, format->mFormatFlags,
                       mean_absolute_sample(sample));
                CFRelease(sample);
                break;
            }
            CFRelease(sample);
        }
        printf("status %ld error %ld\n", (long)reader.status, (long)reader.error.code);
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
    return 0;
}
