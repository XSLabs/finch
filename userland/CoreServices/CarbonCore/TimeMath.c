/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "CarbonCore_Finch.h"
#include <errno.h>
#include <limits.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdatomic.h>
#include <time.h>

static mach_timebase_info_data_t
timebase(void)
{
    mach_timebase_info_data_t info = {1, 1};
    mach_timebase_info(&info);
    return info;
}

static UInt64
wide_to_u64(UnsignedWide value)
{
    return ((UInt64)value.hi << 32) | value.lo;
}

static UnsignedWide
u64_to_wide(UInt64 value)
{
    UnsignedWide result;
    result.hi = (UInt32)(value >> 32);
    result.lo = (UInt32)value;
    return result;
}

static UInt64
absolute_to_ns(UInt64 ticks)
{
    mach_timebase_info_data_t info = timebase();
    __uint128_t value = (__uint128_t)ticks * info.numer / info.denom;
    return value > UINT64_MAX ? UINT64_MAX : (UInt64)value;
}

static UInt64
ns_to_absolute(UInt64 nanoseconds)
{
    mach_timebase_info_data_t info = timebase();
    __uint128_t value = (__uint128_t)nanoseconds * info.denom / info.numer;
    return value > UINT64_MAX ? UINT64_MAX : (UInt64)value;
}

static UInt64
duration_to_ns_value(Duration duration)
{
    UInt64 count = duration < 0 ? (UInt64)-(SInt64)duration : (UInt64)duration;
    return count * (duration < 0 ? 1000ULL : 1000000ULL);
}

Duration
NanosecondsToDuration(Nanoseconds nanoseconds)
{
    UInt64 value = wide_to_u64(nanoseconds);
    if (value >= 1000000000ULL) {
        UInt64 milliseconds = value / 1000000ULL;
        return milliseconds > INT32_MAX ? INT32_MAX : (Duration)milliseconds;
    }
    UInt64 microseconds = value / 1000ULL;
    return microseconds ? -(Duration)microseconds : 0;
}

Nanoseconds
DurationToNanoseconds(Duration duration)
{
    return u64_to_wide(duration_to_ns_value(duration));
}

Nanoseconds
AbsoluteToNanoseconds(AbsoluteTime absoluteTime)
{
    return u64_to_wide(absolute_to_ns(wide_to_u64(absoluteTime)));
}

AbsoluteTime
NanosecondsToAbsolute(Nanoseconds nanoseconds)
{
    return u64_to_wide(ns_to_absolute(wide_to_u64(nanoseconds)));
}

Duration
AbsoluteToDuration(AbsoluteTime absoluteTime)
{
    return NanosecondsToDuration(AbsoluteToNanoseconds(absoluteTime));
}

AbsoluteTime
DurationToAbsolute(Duration duration)
{
    return NanosecondsToAbsolute(DurationToNanoseconds(duration));
}

AbsoluteTime
AddAbsoluteToAbsolute(AbsoluteTime absoluteTime1, AbsoluteTime absoluteTime2)
{
    return u64_to_wide(wide_to_u64(absoluteTime1) + wide_to_u64(absoluteTime2));
}

AbsoluteTime
SubAbsoluteFromAbsolute(AbsoluteTime leftAbsoluteTime, AbsoluteTime rightAbsoluteTime)
{
    return u64_to_wide(wide_to_u64(leftAbsoluteTime) - wide_to_u64(rightAbsoluteTime));
}

AbsoluteTime
AddNanosecondsToAbsolute(Nanoseconds nanoseconds, AbsoluteTime absoluteTime)
{
    return u64_to_wide(wide_to_u64(absoluteTime) + ns_to_absolute(wide_to_u64(nanoseconds)));
}

AbsoluteTime
SubNanosecondsFromAbsolute(Nanoseconds nanoseconds, AbsoluteTime absoluteTime)
{
    return u64_to_wide(wide_to_u64(absoluteTime) - ns_to_absolute(wide_to_u64(nanoseconds)));
}

AbsoluteTime
AddDurationToAbsolute(Duration duration, AbsoluteTime absoluteTime)
{
    return u64_to_wide(wide_to_u64(absoluteTime) + ns_to_absolute(duration_to_ns_value(duration)));
}

AbsoluteTime
SubDurationFromAbsolute(Duration duration, AbsoluteTime absoluteTime)
{
    return u64_to_wide(wide_to_u64(absoluteTime) - ns_to_absolute(duration_to_ns_value(duration)));
}

Nanoseconds
AbsoluteDeltaToNanoseconds(AbsoluteTime leftAbsoluteTime, AbsoluteTime rightAbsoluteTime)
{
    UInt64 left = wide_to_u64(leftAbsoluteTime), right = wide_to_u64(rightAbsoluteTime);
    return u64_to_wide(absolute_to_ns(left >= right ? left - right : right - left));
}

Duration
AbsoluteDeltaToDuration(AbsoluteTime leftAbsoluteTime, AbsoluteTime rightAbsoluteTime)
{
    return NanosecondsToDuration(AbsoluteDeltaToNanoseconds(leftAbsoluteTime, rightAbsoluteTime));
}

AbsoluteTime
UpTime(void)
{
    return u64_to_wide(mach_absolute_time());
}

void
Microseconds(UnsignedWide *microTickCount)
{
    if (microTickCount)
        *microTickCount = u64_to_wide(absolute_to_ns(mach_absolute_time()) / 1000ULL);
}

UInt32
TickCount(void)
{
    return (UInt32)(absolute_to_ns(mach_absolute_time()) * 60ULL / 1000000000ULL);
}

void
Delay(unsigned long numTicks, unsigned long *finalTicks)
{
    UInt64 nanoseconds = (UInt64)numTicks * 1000000000ULL / 60ULL;
    struct timespec requested = {(time_t)(nanoseconds / 1000000000ULL), (long)(nanoseconds % 1000000000ULL)};
    while (nanosleep(&requested, &requested) != 0 && errno == EINTR)
        ;
    if (finalTicks)
        *finalTicks = TickCount();
}

static SInt64
wide_to_s64(wide value)
{
    return (SInt64)(((UInt64)(UInt32)value.hi << 32) | value.lo);
}

static wide
s64_to_wide(SInt64 value)
{
    UInt64 bits = (UInt64)value;
    wide result;
    result.hi = (SInt32)(bits >> 32);
    result.lo = (UInt32)bits;
    return result;
}

short
WideCompare(const wide *target, const wide *source)
{
    if (!target || !source)
        return 0;
    SInt64 a = wide_to_s64(*target), b = wide_to_s64(*source);
    return a < b ? -1 : a > b ? 1 : 0;
}

wide *
WideAdd(wide *target, const wide *source)
{
    if (target && source)
        *target = s64_to_wide((SInt64)((UInt64)wide_to_s64(*target) + (UInt64)wide_to_s64(*source)));
    return target;
}

wide *
WideSubtract(wide *target, const wide *source)
{
    if (target && source)
        *target = s64_to_wide((SInt64)((UInt64)wide_to_s64(*target) - (UInt64)wide_to_s64(*source)));
    return target;
}

wide *
WideNegate(wide *target)
{
    if (target)
        *target = s64_to_wide((SInt64)(0ULL - (UInt64)wide_to_s64(*target)));
    return target;
}

wide *
WideShift(wide *target, SInt32 shift)
{
    if (!target)
        return NULL;
    SInt64 value = wide_to_s64(*target);
    if (shift < 0) {
        UInt32 left = (UInt32)(-(SInt64)shift);
        value = left >= 64 ? 0 : (SInt64)((UInt64)value << left);
    } else if (shift > 0) {
        UInt32 right = (UInt32)shift;
        if (right >= 64) {
            value = value < 0 ? -1 : 0;
        } else if (right) {
            SInt64 divisor = (SInt64)(1ULL << right);
            SInt64 quotient = value / divisor;
            SInt64 remainder = value % divisor;
            value = quotient + (remainder > 0 ? 1 : 0);
        }
    }
    *target = s64_to_wide(value);
    return target;
}

wide *
WideBitShift(wide *target, SInt32 shift)
{
    if (!target)
        return NULL;
    UInt64 bits = (UInt64)wide_to_s64(*target);
    if (shift < 0) {
        UInt32 left = (UInt32)(-(SInt64)shift);
        bits = left >= 64 ? 0 : bits << left;
    } else if (shift > 0) {
        UInt32 right = (UInt32)shift;
        SInt64 value = wide_to_s64(*target);
        bits = right >= 64 ? (value < 0 ? UINT64_MAX : 0) : (UInt64)(value >> right);
    }
    *target = s64_to_wide((SInt64)bits);
    return target;
}

UInt32
WideSquareRoot(const wide *source)
{
    if (!source)
        return 0;
    SInt64 signedValue = wide_to_s64(*source);
    if (signedValue <= 0)
        return 0;
    UInt64 value = (UInt64)signedValue;
    UInt64 root = (UInt64)sqrtl((long double)value);
    while ((root + 1) * (root + 1) <= value)
        root++;
    while (root * root > value)
        root--;
    if (value - root * root > root)
        root++;
    return root > UINT32_MAX ? UINT32_MAX : (UInt32)root;
}

wide *
WideMultiply(SInt32 multiplicand, SInt32 multiplier, wide *target)
{
    if (target)
        *target = s64_to_wide((SInt64)multiplicand * multiplier);
    return target;
}

SInt32
WideDivide(const wide *dividend, SInt32 divisor, SInt32 *remainder)
{
    if (!dividend || divisor == 0)
        return 0;
    SInt64 value = wide_to_s64(*dividend);
    if (value == INT64_MIN && divisor == -1) {
        if (remainder && remainder != (SInt32 *)-1)
            *remainder = 0;
        return remainder == (SInt32 *)-1 ? INT32_MIN : INT32_MAX;
    }
    SInt64 quotient = value / divisor;
    SInt32 rest = (SInt32)(value % divisor);
    if (remainder && remainder != (SInt32 *)-1)
        *remainder = rest;
    if (quotient > INT32_MAX)
        return remainder == (SInt32 *)-1 ? INT32_MIN : INT32_MAX;
    if (quotient < INT32_MIN)
        return INT32_MIN;
    return (SInt32)quotient;
}

wide *
WideWideDivide(wide *dividend, SInt32 divisor, SInt32 *remainder)
{
    if (!dividend || divisor == 0)
        return dividend;
    SInt64 value = wide_to_s64(*dividend);
    if (value == INT64_MIN && divisor == -1) {
        *dividend = s64_to_wide(INT64_MIN);
        if (remainder)
            *remainder = 0;
        return dividend;
    }
    *dividend = s64_to_wide(value / divisor);
    if (remainder)
        *remainder = (SInt32)(value % divisor);
    return dividend;
}

UnsignedFixed
UnsignedFixedMulDiv(UnsignedFixed value, UnsignedFixed multiplier, UnsignedFixed divisor)
{
    if (!divisor)
        return UINT32_MAX;
    return (UnsignedFixed)((UInt64)value * multiplier / divisor);
}

SInt32
U64Compare(UInt64 left, UInt64 right)
{
    return left < right ? -1 : left > right ? 1 : 0;
}

#ifdef S64Absolute
#undef S64Absolute
#endif
SInt64
S64Absolute(SInt64 value)
{
    return value < 0 ? (SInt64)(0ULL - (UInt64)value) : value;
}

long BitAnd(long value1, long value2) { return value1 & value2; }
long BitOr(long value1, long value2) { return value1 | value2; }
long BitXor(long value1, long value2) { return value1 ^ value2; }
long BitNot(long value) { return ~value; }

long
BitShift(long value, short count)
{
    if (count > 0) {
        UInt32 left = (UInt32)count;
        return left >= sizeof(long) * CHAR_BIT ? 0 : (long)((unsigned long)value << left);
    }
    if (count == 0)
        return value;
    UInt32 right = (UInt32)(-(SInt32)count);
    return right >= sizeof(long) * CHAR_BIT ? (value < 0 ? -1 : 0) : value >> right;
}

static UInt8
bit_mask(UInt32 bit)
{
    return (UInt8)(1U << (bit & 7));
}

Boolean
BitTst(const void *bytePtr, long bitNum)
{
    if (!bytePtr || bitNum < 0)
        return false;
    const UInt8 *bytes = bytePtr;
    return (bytes[(UInt32)bitNum >> 3] & bit_mask((UInt32)bitNum)) != 0;
}

void
BitSet(void *bytePtr, long bitNum)
{
    if (bytePtr && bitNum >= 0)
        ((UInt8 *)bytePtr)[(UInt32)bitNum >> 3] |= bit_mask((UInt32)bitNum);
}

void
BitClr(void *bytePtr, long bitNum)
{
    if (bytePtr && bitNum >= 0)
        ((UInt8 *)bytePtr)[(UInt32)bitNum >> 3] &= (UInt8)~bit_mask((UInt32)bitNum);
}

#define ATOMIC_FETCH(name, type, ptrtype, op) \
    type name(type value, ptrtype *address) \
    { return address ? __atomic_fetch_##op(address, value, __ATOMIC_SEQ_CST) : 0; }
#define ATOMIC_FETCH_ARG(name, resulttype, argtype, ptrtype, op) \
    resulttype name(argtype value, ptrtype *address) \
    { return address ? __atomic_fetch_##op(address, value, __ATOMIC_SEQ_CST) : 0; }
#define ATOMIC_ONE(name, type, ptrtype, op) \
    type name(ptrtype *address) \
    { return address ? __atomic_fetch_##op(address, 1, __ATOMIC_SEQ_CST) : 0; }
#define ATOMIC_BIT(name, type, ptrtype, op) ATOMIC_FETCH(name, type, ptrtype, op)

Boolean
CompareAndSwap(UInt32 oldValue, UInt32 newValue, UInt32 *address)
{
    if (!address)
        return false;
    return __atomic_compare_exchange_n(address, &oldValue, newValue, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
}

Boolean
TestAndSet(UInt32 bit, UInt8 *address)
{
    if (!address)
        return false;
    UInt8 mask = bit_mask(bit);
    UInt8 old = __atomic_fetch_or(&address[bit >> 3], mask, __ATOMIC_SEQ_CST);
    return (old & mask) != 0;
}

Boolean
TestAndClear(UInt32 bit, UInt8 *address)
{
    if (!address)
        return false;
    UInt8 mask = bit_mask(bit);
    UInt8 old = __atomic_fetch_and(&address[bit >> 3], (UInt8)~mask, __ATOMIC_SEQ_CST);
    return (old & mask) != 0;
}

ATOMIC_ONE(IncrementAtomic, SInt32, SInt32, add)
ATOMIC_ONE(DecrementAtomic, SInt32, SInt32, sub)
ATOMIC_FETCH(AddAtomic, SInt32, SInt32, add)
ATOMIC_BIT(BitAndAtomic, UInt32, UInt32, and)
ATOMIC_BIT(BitOrAtomic, UInt32, UInt32, or)
ATOMIC_BIT(BitXorAtomic, UInt32, UInt32, xor)
ATOMIC_ONE(IncrementAtomic16, SInt16, SInt16, add)
ATOMIC_ONE(DecrementAtomic16, SInt16, SInt16, sub)
ATOMIC_FETCH_ARG(AddAtomic16, SInt16, SInt32, SInt16, add)
ATOMIC_FETCH_ARG(BitAndAtomic16, UInt16, UInt32, UInt16, and)
ATOMIC_FETCH_ARG(BitOrAtomic16, UInt16, UInt32, UInt16, or)
ATOMIC_FETCH_ARG(BitXorAtomic16, UInt16, UInt32, UInt16, xor)
ATOMIC_ONE(IncrementAtomic8, SInt8, SInt8, add)
ATOMIC_ONE(DecrementAtomic8, SInt8, SInt8, sub)
ATOMIC_FETCH_ARG(AddAtomic8, SInt8, SInt32, SInt8, add)
ATOMIC_FETCH_ARG(BitAndAtomic8, UInt8, UInt32, UInt8, and)
ATOMIC_FETCH_ARG(BitOrAtomic8, UInt8, UInt32, UInt8, or)
ATOMIC_FETCH_ARG(BitXorAtomic8, UInt8, UInt32, UInt8, xor)
