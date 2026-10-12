/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AVTime.h's additions: CMTime, CMTimeRange and CMTimeMapping as NSValues, and coded by
 * key as CoreMedia's dictionary forms (CMTimeCopyAsDictionary and its kin), as Apple's.
 */
#import "AVFInternal.h"

@implementation NSValue (NSValueCMTimeExtensions)

+ (NSValue *)valueWithCMTime:(CMTime)time { return [NSValue valueWithBytes:&time objCType:@encode(CMTime)]; }

- (CMTime)CMTimeValue
{
    CMTime t = kCMTimeInvalid;
    if (!strcmp(self.objCType, @encode(CMTime)))
        [self getValue:&t size:sizeof t];
    return t;
}

+ (NSValue *)valueWithCMTimeRange:(CMTimeRange)timeRange { return [NSValue valueWithBytes:&timeRange objCType:@encode(CMTimeRange)]; }

- (CMTimeRange)CMTimeRangeValue
{
    CMTimeRange r = kCMTimeRangeInvalid;
    if (!strcmp(self.objCType, @encode(CMTimeRange)))
        [self getValue:&r size:sizeof r];
    return r;
}

+ (NSValue *)valueWithCMTimeMapping:(CMTimeMapping)timeMapping
{
    return [NSValue valueWithBytes:&timeMapping objCType:@encode(CMTimeMapping)];
}

- (CMTimeMapping)CMTimeMappingValue
{
    CMTimeMapping m = {kCMTimeRangeInvalid, kCMTimeRangeInvalid};
    if (!strcmp(self.objCType, @encode(CMTimeMapping)))
        [self getValue:&m size:sizeof m];
    return m;
}

@end

@implementation NSCoder (AVTimeCoding)

- (void)encodeCMTime:(CMTime)time forKey:(NSString *)key
{
    [self encodeObject:(__bridge_transfer NSDictionary *)CMTimeCopyAsDictionary(time, NULL) forKey:key];
}

- (CMTime)decodeCMTimeForKey:(NSString *)key
{
    NSDictionary *d = [self decodeObjectOfClass:[NSDictionary class] forKey:key];
    return d ? CMTimeMakeFromDictionary((__bridge CFDictionaryRef)d) : kCMTimeInvalid;
}

- (void)encodeCMTimeRange:(CMTimeRange)timeRange forKey:(NSString *)key
{
    [self encodeObject:(__bridge_transfer NSDictionary *)CMTimeRangeCopyAsDictionary(timeRange, NULL) forKey:key];
}

- (CMTimeRange)decodeCMTimeRangeForKey:(NSString *)key
{
    NSDictionary *d = [self decodeObjectOfClass:[NSDictionary class] forKey:key];
    return d ? CMTimeRangeMakeFromDictionary((__bridge CFDictionaryRef)d) : kCMTimeRangeInvalid;
}

- (void)encodeCMTimeMapping:(CMTimeMapping)timeMapping forKey:(NSString *)key
{
    [self encodeObject:(__bridge_transfer NSDictionary *)CMTimeMappingCopyAsDictionary(timeMapping, NULL) forKey:key];
}

- (CMTimeMapping)decodeCMTimeMappingForKey:(NSString *)key
{
    NSDictionary *d = [self decodeObjectOfClass:[NSDictionary class] forKey:key];
    return d ? CMTimeMappingMakeFromDictionary((__bridge CFDictionaryRef)d) : (CMTimeMapping){kCMTimeRangeInvalid, kCMTimeRangeInvalid};
}

@end
