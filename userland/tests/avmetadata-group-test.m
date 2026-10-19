/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Compare timed and date-range metadata value objects without a media device. */
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString *
time_text(CMTime time)
{
    if (CMTIME_IS_NUMERIC(time))
        time = CMTimeConvertScale(time, 600, kCMTimeRoundingMethod_RoundHalfAwayFromZero);
    return [NSString stringWithFormat:@"%lld/%d", time.value, time.timescale];
}

static NSString *
date_text(NSDate *date)
{
    return date ? [NSString stringWithFormat:@"%.0f", date.timeIntervalSince1970] : @"nil";
}

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        printf("%s\n", class_getImageName([AVTimedMetadataGroup class]));
        @autoreleasepool {
        AVMutableMetadataItem *item = [AVMutableMetadataItem metadataItem];
        item.identifier = AVMetadataIdentifierQuickTimeMetadataTitle;
        item.dataType = (__bridge NSString *)kCMMetadataBaseDataType_UTF8;
        item.value = @"Chapter one";
        AVTimedMetadataGroup *group = [[AVTimedMetadataGroup alloc] initWithItems:@[item]
                                                                         timeRange:CMTimeRangeMake(CMTimeMake(3, 2), CMTimeMake(5, 2))];
        printf("timed %lu %s %s %s %s %d\n", (unsigned long)group.items.count,
               time_text(group.timeRange.start).UTF8String, time_text(group.timeRange.duration).UTF8String,
               group.items.firstObject.identifier.UTF8String, group.items.firstObject.stringValue.UTF8String,
               [group.items.firstObject isKindOfClass:[AVMutableMetadataItem class]]);
        printf("labels %s %s\n", group.classifyingLabel.UTF8String ?: "nil", group.uniqueID.UTF8String ?: "nil");
        CMMetadataFormatDescriptionRef format = [group copyFormatDescription];
        NSArray *identifiers = format ? (__bridge NSArray *)CMMetadataFormatDescriptionGetIdentifiers(format) : nil;
        printf("format %d %lu %s\n", format != NULL, (unsigned long)identifiers.count,
               identifiers.firstObject ? [identifiers.firstObject UTF8String] : "nil");
        if (format)
            CFRelease(format);

        AVMutableTimedMetadataGroup *edited = [group mutableCopy];
        edited.timeRange = CMTimeRangeMake(CMTimeMake(7, 1), CMTimeMake(2, 1));
        edited.items = @[];
        printf("timed copy %lu %s original %lu %s\n", (unsigned long)edited.items.count,
               time_text(edited.timeRange.start).UTF8String, (unsigned long)group.items.count,
               time_text(group.timeRange.start).UTF8String);

        NSDate *start = [NSDate dateWithTimeIntervalSince1970:1000];
        AVDateRangeMetadataGroup *dateGroup = [[AVDateRangeMetadataGroup alloc] initWithItems:@[item] startDate:start endDate:nil];
        AVMutableDateRangeMetadataGroup *dateCopy = [dateGroup mutableCopy];
        dateCopy.startDate = [NSDate dateWithTimeIntervalSince1970:1200];
        dateCopy.endDate = [NSDate dateWithTimeIntervalSince1970:1300];
        printf("dates %s %s %lu copy %s %s\n", date_text(dateGroup.startDate).UTF8String,
               date_text(dateGroup.endDate).UTF8String, (unsigned long)dateGroup.items.count,
               date_text(dateCopy.startDate).UTF8String, date_text(dateCopy.endDate).UTF8String);
        }
        printf("metadata released\n");

        AVRouteDetector *detector = [[AVRouteDetector alloc] init];
        printf("route default %d\n", detector.routeDetectionEnabled);
        detector.routeDetectionEnabled = YES;
        printf("route enabled %d\n", detector.routeDetectionEnabled);
    }
    return 0;
}
