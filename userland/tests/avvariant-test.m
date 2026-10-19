/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Check the public predicates used to select asset variants. */
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        puts("AVAssetVariant qualifier checks");
        NSPredicate *width = [AVAssetVariantQualifier predicateForPresentationWidth:1920 operatorType:NSGreaterThanOrEqualToPredicateOperatorType];
        NSPredicate *height = [AVAssetVariantQualifier predicateForPresentationHeight:1080 operatorType:NSEqualToPredicateOperatorType];
        NSPredicate *channels = [AVAssetVariantQualifier predicateForChannelCount:6 mediaSelectionOption:nil operatorType:NSGreaterThanOrEqualToPredicateOperatorType];
        NSPredicate *rate = [AVAssetVariantQualifier predicateForAudioSampleRate:48000 mediaSelectionOption:nil operatorType:NSEqualToPredicateOperatorType];
        NSPredicate *binaural = [AVAssetVariantQualifier predicateForBinauralAudio:YES mediaSelectionOption:nil];
        NSPredicate *immersive = [AVAssetVariantQualifier predicateForImmersiveAudio:NO mediaSelectionOption:nil];
        NSPredicate *downmix = [AVAssetVariantQualifier predicateForDownmixAudio:YES mediaSelectionOption:nil];
        printf("width %s\nheight %s\nchannels %s\nsample rate %s\nbinaural %s\nimmersive %s\ndownmix %s\n",
               width.predicateFormat.UTF8String, height.predicateFormat.UTF8String,
               channels.predicateFormat.UTF8String, rate.predicateFormat.UTF8String,
               binaural.predicateFormat.UTF8String, immersive.predicateFormat.UTF8String,
               downmix.predicateFormat.UTF8String);
        AVAssetVariantQualifier *qualifier = [AVAssetVariantQualifier assetVariantQualifierWithPredicate:width];
        printf("qualifier %d copy %d\n", [qualifier isKindOfClass:[AVAssetVariantQualifier class]], [qualifier copy] == qualifier);
    }
    return 0;
}
