/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AVAudioTime, Finch's: a host time, a sample time at a rate, or both. Extrapolating
 * from an anchor takes the difference in sample counts at this time's own rate, as
 * Apple's does (the anchor's rate isn't taken into account).
 */
#import <AVFAudio/AVAudioTime.h>
#include <mach/mach_time.h>

static double
ticks_per_second(void)
{
    static double tps;
    if (!tps) {
        mach_timebase_info_data_t i;
        mach_timebase_info(&i);
        tps = 1e9 * i.denom / i.numer;
    }
    return tps;
}

/* (the header's _ats and _sampleRate hold the stamp and the rate) */
@implementation AVAudioTime

- (instancetype)initWithAudioTimeStamp:(const AudioTimeStamp *)ts sampleRate:(double)sampleRate
{
    if ((self = [super init])) {
        if (ts)
            _ats = *ts;
        _ats.mFlags &= kAudioTimeStampSampleHostTimeValid;
        _sampleRate = sampleRate;
    }
    return self;
}

- (instancetype)initWithHostTime:(uint64_t)hostTime
{
    AudioTimeStamp ts = {0};
    ts.mHostTime = hostTime;
    ts.mFlags = kAudioTimeStampHostTimeValid;
    return [self initWithAudioTimeStamp:&ts sampleRate:0];
}

- (instancetype)initWithSampleTime:(AVAudioFramePosition)sampleTime atRate:(double)sampleRate
{
    AudioTimeStamp ts = {0};
    ts.mSampleTime = (Float64)sampleTime;
    ts.mFlags = kAudioTimeStampSampleTimeValid;
    return [self initWithAudioTimeStamp:&ts sampleRate:sampleRate];
}

- (instancetype)initWithHostTime:(uint64_t)hostTime sampleTime:(AVAudioFramePosition)sampleTime atRate:(double)sampleRate
{
    AudioTimeStamp ts = {0};
    ts.mHostTime = hostTime;
    ts.mSampleTime = (Float64)sampleTime;
    ts.mFlags = kAudioTimeStampSampleHostTimeValid;
    return [self initWithAudioTimeStamp:&ts sampleRate:sampleRate];
}

+ (instancetype)timeWithAudioTimeStamp:(const AudioTimeStamp *)ts sampleRate:(double)sampleRate
{
    return [[[self alloc] initWithAudioTimeStamp:ts sampleRate:sampleRate] autorelease];
}

+ (instancetype)timeWithHostTime:(uint64_t)hostTime
{
    return [[[self alloc] initWithHostTime:hostTime] autorelease];
}

+ (instancetype)timeWithSampleTime:(AVAudioFramePosition)sampleTime atRate:(double)sampleRate
{
    return [[[self alloc] initWithSampleTime:sampleTime atRate:sampleRate] autorelease];
}

+ (instancetype)timeWithHostTime:(uint64_t)hostTime sampleTime:(AVAudioFramePosition)sampleTime atRate:(double)sampleRate
{
    return [[[self alloc] initWithHostTime:hostTime sampleTime:sampleTime atRate:sampleRate] autorelease];
}

+ (uint64_t)hostTimeForSeconds:(NSTimeInterval)seconds
{
    return (uint64_t)(seconds * ticks_per_second());
}

+ (NSTimeInterval)secondsForHostTime:(uint64_t)hostTime
{
    return (double)hostTime / ticks_per_second();
}

- (BOOL)isHostTimeValid
{
    return (_ats.mFlags & kAudioTimeStampHostTimeValid) != 0;
}

- (BOOL)isSampleTimeValid
{
    return (_ats.mFlags & kAudioTimeStampSampleTimeValid) != 0;
}

- (uint64_t)hostTime
{
    return self.hostTimeValid ? _ats.mHostTime : 0;
}

- (AVAudioFramePosition)sampleTime
{
    return self.sampleTimeValid ? (AVAudioFramePosition)_ats.mSampleTime : 0;
}

- (double)sampleRate
{
    return _sampleRate;
}

- (AudioTimeStamp)audioTimeStamp
{
    return _ats;
}

/* The missing half filled in from the anchor (which must have both); nil if it can't be. */
- (AVAudioTime *)extrapolateTimeFromAnchor:(AVAudioTime *)anchor
{
    if (!anchor || !anchor.hostTimeValid || !anchor.sampleTimeValid)
        return nil;
    if (self.sampleTimeValid && self.hostTimeValid)
        return [[self retain] autorelease];
    if (!self.sampleTimeValid || _sampleRate <= 0)
        return nil;
    double seconds = (double)(self.sampleTime - anchor.sampleTime) / _sampleRate;
    uint64_t host = (uint64_t)((double)anchor.hostTime + seconds * ticks_per_second());
    return [AVAudioTime timeWithHostTime:host sampleTime:self.sampleTime atRate:_sampleRate];
}

- (NSString *)description
{
    NSString *host = self.hostTimeValid ? [NSString stringWithFormat:@"%f s", [AVAudioTime secondsForHostTime:_ats.mHostTime]] : @"";
    NSString *sample = self.sampleTimeValid ? [NSString stringWithFormat:@"%lld fr (/%g Hz)", self.sampleTime, _sampleRate] : @"";
    return [NSString stringWithFormat:@"<AVAudioTime %p: %@ %@ >", self, host, sample];
}

@end
