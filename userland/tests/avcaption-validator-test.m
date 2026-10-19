/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Compare validator state and completion for a plain caption. */
#import <AVFoundation/AVCaption.h>
#import <AVFoundation/AVCaptionConversionValidator.h>
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
        printf("%s\n", class_getImageName([AVCaptionConversionValidator class]));
        NSDictionary *settings = @{ AVCaptionMediaTypeKey: AVMediaTypeClosedCaption,
                                    AVCaptionMediaSubTypeKey: @(kCMClosedCaptionFormatType_CEA608) };
        AVCaption *caption = [[AVCaption alloc] initWithText:@"hello" timeRange:CMTimeRangeMake(CMTimeMake(0, 1), CMTimeMake(1, 1))];
        AVCaptionConversionValidator *validator = [[AVCaptionConversionValidator alloc]
            initWithCaptions:@[caption] timeRange:CMTimeRangeMake(CMTimeMake(0, 1), CMTimeMake(2, 1)) conversionSettings:settings];
        printf("before %ld %lu %lu %.0f+%.0f\n", (long)validator.status,
            (unsigned long)validator.captions.count, (unsigned long)validator.warnings.count,
            CMTimeGetSeconds(validator.timeRange.start), CMTimeGetSeconds(validator.timeRange.duration));
        __block NSUInteger completions = 0;
        __block NSUInteger warnings = 0;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [validator validateCaptionConversionWithWarningHandler:^(AVCaptionConversionWarning *warning) {
            if (warning) {
                warnings++;
                AVCaptionConversionTimeRangeAdjustment *adjustment = (id)warning.adjustment;
                printf("warning %s %lu+%lu %s %lld/%d %lld/%d\n",
                    warning.warningType.UTF8String, (unsigned long)warning.rangeOfCaptions.location,
                    (unsigned long)warning.rangeOfCaptions.length, warning.adjustment.adjustmentType.UTF8String,
                    adjustment.startTimeOffset.value, adjustment.startTimeOffset.timescale,
                    adjustment.durationOffset.value, adjustment.durationOffset.timescale);
            }
            else { completions++; dispatch_semaphore_signal(done); }
        }];
        dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
        [validator stopValidating];
        printf("after %ld %lu %lu %lu\n", (long)validator.status,
            (unsigned long)validator.warnings.count, (unsigned long)warnings, (unsigned long)completions);
    }
    return 0;
}
