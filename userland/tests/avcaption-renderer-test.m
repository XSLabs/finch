/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Static caption scene ranges and drawing into a bitmap context. */
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>

static AVCaption *
caption(NSString *text, int start, int duration)
{
    AVMutableCaption *caption = [[AVMutableCaption alloc] initWithText:text timeRange:CMTimeRangeMake(CMTimeMake(start, 1), CMTimeMake(duration, 1))];
    caption.region = [AVCaptionRegion appleITTBottomRegion];
    return caption;
}

int
main(void)
{
    @autoreleasepool {
        AVCaptionRenderer *renderer = [[AVCaptionRenderer alloc] init];
        renderer.bounds = CGRectMake(0, 0, 160, 64);
        renderer.captions = @[caption(@"one", 1, 1), caption(@"two", 3, 1)];
        NSArray<AVCaptionRendererScene *> *scenes = [renderer captionSceneChangesInRange:CMTimeRangeMake(CMTimeMake(0, 1), CMTimeMake(5, 1))];
        printf("scenes %lu\n", (unsigned long)scenes.count);
        for (AVCaptionRendererScene *scene in scenes)
            printf("  %.1f %.1f active %d refresh %d\n", CMTimeGetSeconds(scene.timeRange.start),
                   CMTimeGetSeconds(scene.timeRange.duration), scene.hasActiveCaptions, scene.needsPeriodicRefresh);

        uint8_t pixels[160 * 64 * 4] = {0};
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(pixels, 160, 64, 8, 160 * 4, colorSpace,
                                                     kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(colorSpace);
        [renderer renderInContext:context forTime:CMTimeMake(7, 2)];
        CGContextRelease(context);
        printf("render call completed %d copy %d\n", sizeof pixels > 0, [scenes.firstObject copy] == scenes.firstObject);
    }
    return 0;
}
