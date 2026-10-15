/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSCalendar's newer operations. CoreFoundation owns Finch's toll-free
 * bridged calendar objects; the matching Swift calendar implementation is
 * built into Foundation. These methods hand work to that implementation
 * with the receiver's calendar settings.
 */
#import <Foundation/Foundation.h>

#include "Foundation_Finch.h"

@interface NSCalendar (FinchSwiftCalendar)
+ (instancetype)_newCalendarWithIdentifier:(NSString *)identifier;
@end

static NSCalendar *
swift_calendar(NSCalendar *calendar)
{
    Class swiftClass = NSClassFromString(@"_NSSwiftCalendar");
    if (!swiftClass)
        return nil;
    if ([calendar isKindOfClass:swiftClass])
        return calendar;

    NSCalendar *copy = [NSCalendar _newCalendarWithIdentifier:[calendar calendarIdentifier]];
    if (!copy || ![copy isKindOfClass:swiftClass]) {
        [copy release];
        return nil;
    }
    copy.locale = calendar.locale;
    copy.timeZone = calendar.timeZone;
    copy.firstWeekday = calendar.firstWeekday;
    copy.minimumDaysInFirstWeek = calendar.minimumDaysInFirstWeek;
    return [copy autorelease];
}

@implementation NSCalendar (FinchCalendarOperations)

- (NSComparisonResult)compareDate:(NSDate *)date1 toDate:(NSDate *)date2 toUnitGranularity:(NSCalendarUnit)unit
{
    return [swift_calendar(self) compareDate:date1 toDate:date2 toUnitGranularity:unit];
}

- (NSDateComponents *)components:(NSCalendarUnit)unitFlags fromDateComponents:(NSDateComponents *)startingComponents
                  toDateComponents:(NSDateComponents *)resultComponents options:(NSCalendarOptions)options
{
    return [swift_calendar(self) components:unitFlags fromDateComponents:startingComponents
                           toDateComponents:resultComponents options:options];
}

- (BOOL)date:(NSDate *)date matchesComponents:(NSDateComponents *)components
{
    return [swift_calendar(self) date:date matchesComponents:components];
}

- (NSDate *)dateBySettingUnit:(NSCalendarUnit)unit value:(NSInteger)value ofDate:(NSDate *)date options:(NSCalendarOptions)options
{
    return [swift_calendar(self) dateBySettingUnit:unit value:value ofDate:date options:options];
}

- (NSDate *)dateWithEra:(NSInteger)era yearForWeekOfYear:(NSInteger)yearForWeekOfYear weekOfYear:(NSInteger)weekOfYear
                weekday:(NSInteger)weekday hour:(NSInteger)hour minute:(NSInteger)minute second:(NSInteger)second nanosecond:(NSInteger)nanosecond
{
    return [swift_calendar(self) dateWithEra:era yearForWeekOfYear:yearForWeekOfYear weekOfYear:weekOfYear weekday:weekday
                                      hour:hour minute:minute second:second nanosecond:nanosecond];
}

- (void)enumerateDatesStartingAfterDate:(NSDate *)start matchingComponents:(NSDateComponents *)components
                                options:(NSCalendarOptions)options
                             usingBlock:(void (NS_NOESCAPE ^)(NSDate * _Nullable, BOOL, BOOL *))block
{
    [swift_calendar(self) enumerateDatesStartingAfterDate:start matchingComponents:components options:options usingBlock:block];
}

- (void)getEra:(NSInteger *)era year:(NSInteger *)year month:(NSInteger *)month day:(NSInteger *)day fromDate:(NSDate *)date
{
    [swift_calendar(self) getEra:era year:year month:month day:day fromDate:date];
}

- (void)getEra:(NSInteger *)era yearForWeekOfYear:(NSInteger *)yearForWeekOfYear weekOfYear:(NSInteger *)weekOfYear
      weekday:(NSInteger *)weekday fromDate:(NSDate *)date
{
    [swift_calendar(self) getEra:era yearForWeekOfYear:yearForWeekOfYear weekOfYear:weekOfYear weekday:weekday fromDate:date];
}

- (void)getHour:(NSInteger *)hour minute:(NSInteger *)minute second:(NSInteger *)second nanosecond:(NSInteger *)nanosecond fromDate:(NSDate *)date
{
    [swift_calendar(self) getHour:hour minute:minute second:second nanosecond:nanosecond fromDate:date];
}

- (BOOL)isDate:(NSDate *)date equalToDate:(NSDate *)otherDate toUnitGranularity:(NSCalendarUnit)unit
{
    return [swift_calendar(self) isDate:date equalToDate:otherDate toUnitGranularity:unit];
}

- (BOOL)isDateInTomorrow:(NSDate *)date { return [swift_calendar(self) isDateInTomorrow:date]; }
- (BOOL)isDateInYesterday:(NSDate *)date { return [swift_calendar(self) isDateInYesterday:date]; }

- (NSDate *)nextDateAfterDate:(NSDate *)date matchingComponents:(NSDateComponents *)components options:(NSCalendarOptions)options
{
    return [swift_calendar(self) nextDateAfterDate:date matchingComponents:components options:options];
}

- (NSDate *)nextDateAfterDate:(NSDate *)date matchingHour:(NSInteger)hour minute:(NSInteger)minute second:(NSInteger)second
                      options:(NSCalendarOptions)options
{
    return [swift_calendar(self) nextDateAfterDate:date matchingHour:hour minute:minute second:second options:options];
}

- (NSDate *)nextDateAfterDate:(NSDate *)date matchingUnit:(NSCalendarUnit)unit value:(NSInteger)value options:(NSCalendarOptions)options
{
    return [swift_calendar(self) nextDateAfterDate:date matchingUnit:unit value:value options:options];
}

- (BOOL)nextWeekendStartDate:(NSDate * _Nullable *)date interval:(NSTimeInterval *)interval options:(NSCalendarOptions)options
                     afterDate:(NSDate *)afterDate
{
    return [swift_calendar(self) nextWeekendStartDate:date interval:interval options:options afterDate:afterDate];
}

- (BOOL)rangeOfWeekendStartDate:(NSDate * _Nullable *)date interval:(NSTimeInterval *)interval containingDate:(NSDate *)containingDate
{
    return [swift_calendar(self) rangeOfWeekendStartDate:date interval:interval containingDate:containingDate];
}

@end
