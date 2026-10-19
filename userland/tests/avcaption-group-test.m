/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Compare active caption sets across the timeline. */
#import <AVFoundation/AVCaption.h>
#import <AVFoundation/AVCaptionGroup.h>
#import <AVFoundation/AVCaptionGrouper.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static void
print_groups(NSString *label, NSArray<AVCaptionGroup *> *groups)
{
    printf("%s %lu\n", label.UTF8String, (unsigned long)groups.count);
    for (AVCaptionGroup *group in groups) {
        printf("  %.0f+%.0f:", CMTimeGetSeconds(group.timeRange.start), CMTimeGetSeconds(group.timeRange.duration));
        for (AVCaption *caption in group.captions)
            printf(" %s", caption.text.UTF8String);
        printf("\n");
    }
}

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        printf("%s\n", class_getImageName([AVCaptionGroup class]));
        AVCaption *first = [[AVCaption alloc] initWithText:@"first" timeRange:CMTimeRangeMake(CMTimeMake(0, 1), CMTimeMake(5, 1))];
        AVCaption *second = [[AVCaption alloc] initWithText:@"second" timeRange:CMTimeRangeMake(CMTimeMake(2, 1), CMTimeMake(5, 1))];
        AVCaption *third = [[AVCaption alloc] initWithText:@"third" timeRange:CMTimeRangeMake(CMTimeMake(8, 1), CMTimeMake(2, 1))];

        AVCaptionGroup *empty = [[AVCaptionGroup alloc] initWithTimeRange:CMTimeRangeMake(CMTimeMake(0, 1), CMTimeMake(1, 1))];
        AVCaptionGroup *single = [[AVCaptionGroup alloc] initWithCaptions:@[first] timeRange:CMTimeRangeMake(CMTimeMake(0, 1), CMTimeMake(5, 1))];
        printf("values %.0f+%.0f %lu %lu\n", CMTimeGetSeconds(empty.timeRange.start), CMTimeGetSeconds(empty.timeRange.duration),
            (unsigned long)empty.captions.count, (unsigned long)single.captions.count);

        AVCaptionGrouper *grouper = [[AVCaptionGrouper alloc] init];
        [grouper addCaption:first];
        [grouper addCaption:second];
        print_groups(@"first flush", [grouper flushAddedCaptionsIntoGroupsUpToTime:CMTimeMake(7, 1)]);
        [grouper addCaption:third];
        print_groups(@"second flush", [grouper flushAddedCaptionsIntoGroupsUpToTime:CMTimeMake(11, 1)]);
    }
    return 0;
}
