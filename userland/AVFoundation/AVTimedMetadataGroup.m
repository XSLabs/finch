/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Metadata groups keep their items with the time or dates that describe them. */
#import "AVFInternal.h"
#import <AVFoundation/AVTimedMetadataGroup.h>

@interface AVMetadataGroup ()
- (instancetype)initWithFinchItems:(NSArray<AVMetadataItem *> *)items;
- (void)_finchSetItems:(NSArray<AVMetadataItem *> *)items;
@end

@interface AVTimedMetadataGroup ()
- (instancetype)initWithFinchItems:(NSArray<AVMetadataItem *> *)items timeRange:(CMTimeRange)timeRange;
- (void)_finchSetTimeRange:(CMTimeRange)timeRange;
@end

@interface AVDateRangeMetadataGroup ()
- (instancetype)initWithFinchItems:(NSArray<AVMetadataItem *> *)items startDate:(NSDate *)startDate endDate:(NSDate *)endDate;
- (void)_finchSetStartDate:(NSDate *)startDate;
- (void)_finchSetEndDate:(NSDate *)endDate;
@end

@implementation AVMetadataGroup {
    NSArray<AVMetadataItem *> *_finchItems;
}

- (instancetype)initWithFinchItems:(NSArray<AVMetadataItem *> *)items
{
    if ((self = [super init]))
        [self _finchSetItems:items];
    return self;
}

- (void)_finchSetItems:(NSArray<AVMetadataItem *> *)items
{
    _finchItems = [items copy] ?: @[];
}

- (NSArray<AVMetadataItem *> *)items { return _finchItems ?: @[]; }
- (NSString *)classifyingLabel { return nil; }
- (NSString *)uniqueID { return nil; }
@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation AVTimedMetadataGroup {
    CMTimeRange _finchTimeRange;
}

- (instancetype)initWithItems:(NSArray<AVMetadataItem *> *)items timeRange:(CMTimeRange)timeRange
{
    return [self initWithFinchItems:items timeRange:timeRange];
}

- (instancetype)initWithFinchItems:(NSArray<AVMetadataItem *> *)items timeRange:(CMTimeRange)timeRange
{
    if ((self = [super initWithFinchItems:items]))
        _finchTimeRange = timeRange;
    return self;
}

- (CMTimeRange)timeRange { return _finchTimeRange; }
- (void)_finchSetTimeRange:(CMTimeRange)timeRange { _finchTimeRange = timeRange; }

- (CMMetadataFormatDescriptionRef)copyFormatDescription
{
    NSMutableArray *specifications = [NSMutableArray arrayWithCapacity:self.items.count];
    for (AVMetadataItem *item in self.items) {
        if (!item.dataType)
            [NSException raise:NSInvalidArgumentException format:@"Every metadata item must have a data type"];
        if (!item.identifier)
            [NSException raise:NSInvalidArgumentException format:@"Every metadata item must have an identifier"];
        NSMutableDictionary *specification = [NSMutableDictionary dictionaryWithObjectsAndKeys:
            item.identifier, (__bridge NSString *)kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier,
            item.dataType, (__bridge NSString *)kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType, nil];
        if (item.extendedLanguageTag)
            specification[(__bridge NSString *)kCMMetadataFormatDescriptionMetadataSpecificationKey_ExtendedLanguageTag] = item.extendedLanguageTag;
        [specifications addObject:specification];
    }
    CMMetadataFormatDescriptionRef description = NULL;
    OSStatus status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(kCFAllocatorDefault,
        kCMMetadataFormatType_Boxed, (__bridge CFArrayRef)specifications, &description);
    return status == noErr ? description : NULL;
}

- (id)copyWithZone:(NSZone *)zone
{
    return [[AVTimedMetadataGroup allocWithZone:zone] initWithFinchItems:self.items timeRange:self.timeRange];
}

- (id)mutableCopyWithZone:(NSZone *)zone
{
    AVMutableTimedMetadataGroup *copy = [[AVMutableTimedMetadataGroup allocWithZone:zone] initWithFinchItems:self.items timeRange:self.timeRange];
    return copy;
}
@end
#pragma clang diagnostic pop

@implementation AVMutableTimedMetadataGroup
- (void)setItems:(NSArray<AVMetadataItem *> *)items { [self _finchSetItems:items]; }
- (void)setTimeRange:(CMTimeRange)timeRange { [self _finchSetTimeRange:timeRange]; }
@end

@implementation AVDateRangeMetadataGroup {
    NSDate *_finchStartDate;
    NSDate *_finchEndDate;
}

- (instancetype)initWithItems:(NSArray<AVMetadataItem *> *)items startDate:(NSDate *)startDate endDate:(NSDate *)endDate
{
    return [self initWithFinchItems:items startDate:startDate endDate:endDate];
}

- (instancetype)initWithFinchItems:(NSArray<AVMetadataItem *> *)items startDate:(NSDate *)startDate endDate:(NSDate *)endDate
{
    if ((self = [super initWithFinchItems:items])) {
        [self _finchSetStartDate:startDate];
        [self _finchSetEndDate:endDate];
    }
    return self;
}

- (void)_finchSetStartDate:(NSDate *)startDate { _finchStartDate = [startDate copy]; }
- (void)_finchSetEndDate:(NSDate *)endDate { _finchEndDate = [endDate copy]; }
- (NSDate *)startDate { return _finchStartDate; }
- (NSDate *)endDate { return _finchEndDate; }

- (id)copyWithZone:(NSZone *)zone
{
    return [[AVDateRangeMetadataGroup allocWithZone:zone] initWithFinchItems:self.items startDate:self.startDate endDate:self.endDate];
}

- (id)mutableCopyWithZone:(NSZone *)zone
{
    return [[AVMutableDateRangeMetadataGroup allocWithZone:zone] initWithFinchItems:self.items startDate:self.startDate endDate:self.endDate];
}
@end

@implementation AVMutableDateRangeMetadataGroup
- (void)setItems:(NSArray<AVMetadataItem *> *)items { [self _finchSetItems:items]; }
- (void)setStartDate:(NSDate *)startDate { [self _finchSetStartDate:startDate]; }
- (void)setEndDate:(NSDate *)endDate { [self _finchSetEndDate:endDate]; }
@end
