/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#import <AVFoundation/AVFoundation.h>
#import <stdio.h>

static void print_time(const char *name, CMTime time)
{
    printf("%s=%.3f\n", name, CMTIME_IS_NUMERIC(time) ? CMTimeGetSeconds(time) : -999.0);
}

int main(void)
{
    @autoreleasepool {
        printf("framework=%s\n", [[[AVMutableVideoComposition videoComposition] class] description].UTF8String);
        AVMutableVideoComposition *composition = [AVMutableVideoComposition videoComposition];
        print_time("default-frame", composition.frameDuration);
        printf("default-size=%.0f,%.0f scale=%.1f instructionsNil=%d sourceIDs=%lu\n",
            composition.renderSize.width, composition.renderSize.height, composition.renderScale,
            composition.instructions == nil, (unsigned long)composition.sourceSampleDataTrackIDs.count);

        AVMutableVideoCompositionLayerInstruction *layer = [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstruction];
        layer.trackID = 812;
        CGAffineTransform startTransform = CGAffineTransformIdentity;
        CGAffineTransform endTransform = CGAffineTransformMakeTranslation(40, 20);
        CMTimeRange rampRange = CMTimeRangeMake(CMTimeMake(0, 1), CMTimeMake(10, 1));
        [layer setTransformRampFromStartTransform:startTransform toEndTransform:endTransform timeRange:rampRange];
        [layer setOpacityRampFromStartOpacity:1.0 toEndOpacity:0.0 timeRange:rampRange];
        [layer setCropRectangleRampFromStartCropRectangle:CGRectMake(0, 0, 100, 80)
            toEndCropRectangle:CGRectMake(10, 5, 80, 60) timeRange:rampRange];

        CGAffineTransform gotStart = CGAffineTransformIdentity, gotEnd = CGAffineTransformIdentity;
        CMTimeRange gotRange = kCMTimeRangeInvalid;
        BOOL transformFound = [layer getTransformRampForTime:CMTimeMake(5, 1) startTransform:&gotStart endTransform:&gotEnd timeRange:&gotRange];
        print_time("transform-start", gotRange.start);
        print_time("transform-duration", gotRange.duration);
        printf("transform=%d %.1f,%.1f -> %.1f,%.1f\n", transformFound,
            gotStart.tx, gotStart.ty, gotEnd.tx, gotEnd.ty);
        float startOpacity = -1, endOpacity = -1;
        BOOL opacityFound = [layer getOpacityRampForTime:CMTimeMake(5, 1) startOpacity:&startOpacity endOpacity:&endOpacity timeRange:&gotRange];
        printf("opacity=%d %.2f->%.2f\n", opacityFound, startOpacity, endOpacity);
        CGRect startCrop = CGRectZero, endCrop = CGRectZero;
        BOOL cropFound = [layer getCropRectangleRampForTime:CMTimeMake(5, 1) startCropRectangle:&startCrop endCropRectangle:&endCrop timeRange:&gotRange];
        printf("crop=%d %.0f,%.0f,%.0f,%.0f -> %.0f,%.0f,%.0f,%.0f\n", cropFound,
            startCrop.origin.x, startCrop.origin.y, startCrop.size.width, startCrop.size.height,
            endCrop.origin.x, endCrop.origin.y, endCrop.size.width, endCrop.size.height);
        printf("afterLast=%d\n", [layer getOpacityRampForTime:CMTimeMake(11, 1) startOpacity:NULL endOpacity:NULL timeRange:NULL]);

        AVMutableVideoCompositionInstruction *instruction = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
        instruction.timeRange = rampRange;
        instruction.layerInstructions = @[layer];
        instruction.enablePostProcessing = NO;
        instruction.requiredSourceSampleDataTrackIDs = @[@77];
        printf("instruction=%.1f,%0.1f post=%d tween=%d layers=%lu required=%lu pass=%d source=%lu\n",
            CMTimeGetSeconds(instruction.timeRange.start), CMTimeGetSeconds(instruction.timeRange.duration),
            instruction.enablePostProcessing, instruction.containsTweening,
            (unsigned long)instruction.layerInstructions.count,
            (unsigned long)instruction.requiredSourceTrackIDs.count,
            instruction.passthroughTrackID, (unsigned long)instruction.requiredSourceSampleDataTrackIDs.count);
        composition.frameDuration = CMTimeMake(1, 24);
        composition.renderSize = CGSizeMake(640, 480);
        composition.instructions = @[instruction];
        composition.colorPrimaries = @"test-primaries";
        composition.colorYCbCrMatrix = @"test-matrix";
        printf("stored=%.0fx%.0f frame=%.3f sourceIDs=%lu colors=%d\n",
            composition.renderSize.width, composition.renderSize.height, CMTimeGetSeconds(composition.frameDuration),
            (unsigned long)composition.sourceSampleDataTrackIDs.count,
            [composition.colorPrimaries isEqualToString:@"test-primaries"] && [composition.colorYCbCrMatrix isEqualToString:@"test-matrix"]);
        AVVideoComposition *immutable = [composition copy];
        AVMutableVideoComposition *mutableCopy = [composition mutableCopy];
        printf("copies=mutableSetter:%d mutableCopy:%d retained:%d\n",
            [immutable respondsToSelector:@selector(setRenderSize:)],
            [mutableCopy respondsToSelector:@selector(setRenderSize:)],
            mutableCopy.instructions.count == 1);
        printf("valid=%d gapValid=%d\n",
            [composition isValidForAsset:nil timeRange:rampRange validationDelegate:nil],
            [composition isValidForAsset:nil timeRange:CMTimeRangeMake(CMTimeMake(11, 1), CMTimeMake(1, 1)) validationDelegate:nil]);
        return 0;
    }
}
