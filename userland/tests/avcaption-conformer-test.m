/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Compare caption copying and CEA-608 frame timing. */
#import <AVFoundation/AVCaption.h>
#import <AVFoundation/AVCaptionFormatConformer.h>
#import <AVFoundation/AVCaptionSettings.h>
#import <AVFoundation/AVMediaFormat.h>
#import <CoreMedia/CMFormatDescription.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        printf("%s\n", class_getImageName([AVCaptionFormatConformer class]));
        NSDictionary *settings = @{ AVCaptionMediaTypeKey: AVMediaTypeClosedCaption,
                                    AVCaptionMediaSubTypeKey: @(kCMClosedCaptionFormatType_CEA608) };
        AVCaptionFormatConformer *conformer = [[AVCaptionFormatConformer alloc] initWithConversionSettings:settings];
        AVCaption *caption = [[AVCaption alloc] initWithText:@"hello" timeRange:CMTimeRangeMake(CMTimeMake(1, 1), CMTimeMake(3, 1))];
        NSError *error = nil;
        AVCaption *copy = [conformer conformedCaptionForCaption:caption error:&error];
        printf("copy %d %s %.3f %.3f %ld\n", copy != caption, copy.text.UTF8String,
            CMTimeGetSeconds(copy.timeRange.start), CMTimeGetSeconds(copy.timeRange.duration), (long)error.code);
        AVCaption *invalid = [[AVCaption alloc] initWithText:@"empty" timeRange:CMTimeRangeMake(CMTimeMake(0, 1), kCMTimeZero)];
        copy = [conformer conformedCaptionForCaption:invalid error:&error];
        printf("empty %d %ld\n", copy == nil, (long)error.code);
        conformer.conformsCaptionsToTimeRange = YES;
        copy = [conformer conformedCaptionForCaption:caption error:&error];
        printf("frame timing %lld/%d %lld/%d %d\n", copy.timeRange.start.value, copy.timeRange.start.timescale,
            copy.timeRange.duration.value, copy.timeRange.duration.timescale, conformer.conformsCaptionsToTimeRange);
    }
    return 0;
}
