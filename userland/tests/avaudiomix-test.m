/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Compare audio-mix volume ramps and copied settings without using audio hardware. */
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

static NSString *
time_text(CMTime time)
{
    if (CMTIME_IS_NUMERIC(time))
        time = CMTimeConvertScale(time, 600, kCMTimeRoundingMethod_RoundHalfAwayFromZero);
    return [NSString stringWithFormat:@"%lld/%d", time.value, time.timescale];
}

static void
print_ramp(AVAudioMixInputParameters *parameters, CMTime time)
{
    float start = -1.0f, end = -1.0f;
    CMTimeRange range = kCMTimeRangeInvalid;
    BOOL found = [parameters getVolumeRampForTime:time startVolume:&start endVolume:&end timeRange:&range];
    printf("ramp %s %d %.3f %.3f %s %s\n", time_text(time).UTF8String, found, start, end,
           time_text(range.start).UTF8String, time_text(range.duration).UTF8String);
}

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        AVMutableAudioMixInputParameters *parameters = [AVMutableAudioMixInputParameters audioMixInputParameters];
        parameters.trackID = 42;
        parameters.audioTimePitchAlgorithm = AVAudioTimePitchAlgorithmSpectral;
        [parameters setVolume:1.0f atTime:kCMTimeZero];
        [parameters setVolumeRampFromStartVolume:0.5f toEndVolume:0.2f
                                       timeRange:CMTimeRangeMake(CMTimeMake(4, 1), CMTimeMake(5, 1))];
        printf("parameters track %d pitch %s\n", parameters.trackID,
               parameters.audioTimePitchAlgorithm.UTF8String);
        print_ramp(parameters, kCMTimeZero);
        print_ramp(parameters, CMTimeMake(4, 1));
        print_ramp(parameters, CMTimeMake(13, 2));
        print_ramp(parameters, CMTimeMake(9, 1));
        print_ramp(parameters, CMTimeMake(19, 2));

        AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
        mix.inputParameters = @[parameters];
        printf("mix inputs %lu class %d\n", (unsigned long)mix.inputParameters.count,
               [mix copy] != nil);
        AVAudioMixInputParameters *stored = mix.inputParameters.firstObject;
        printf("stored track %d class %d\n", stored.trackID,
               [stored isKindOfClass:[AVMutableAudioMixInputParameters class]]);
        [parameters setVolume:0.75f atTime:CMTimeMake(12, 1)];
        print_ramp(stored, CMTimeMake(12, 1));
        AVMutableAudioMix *mutableCopy = [mix mutableCopy];
        printf("mutable copy inputs %lu\n", (unsigned long)mutableCopy.inputParameters.count);
    }
    return 0;
}
