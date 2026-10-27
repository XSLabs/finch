/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * CoreFoundation's immortal and tagged objects, the classes Apple's exports:
 *
 *   NSConstantData        {isa, length, bytes}: data laid out at build time
 *   NSConstantDate        {isa, double}: a date laid out at build time
 *   NSTaggedPointerString up to seven ASCII characters held in the pointer
 *   NSIndirectTaggedPointerString
 *                         a pointer to constant, NUL-terminated ASCII bytes,
 *                         held in the pointer (Swift bridges its immortal
 *                         ASCII strings to these when the class exists)
 *
 * The first two have Apple's instance layouts (as read from macOS 26.4's
 * runtime metadata), so an instance a compiler or linker emits works here.
 * Allocating one gives NSData's or NSDate's placeholder, as Apple's does.
 * The payload layout of the tagged strings is private to a process (the
 * runtime obfuscates tagged pointers per process), so Finch's is its own,
 * with NSString's tag (2) for the direct form and the first extended
 * Foundation tag (22) for the indirect one. CF's string functions don't
 * make tagged strings (_CFStringCreateTaggedPointerString does).
 *
 * Built without ARC: these classes implement retain and release.
 */

#include "CFObjCClasses_Finch.h"
#import <objc/runtime.h>
#include <string.h>

/*
 * arm64 tagged pointers, as the runtime lays them out (what it publishes for
 * debuggers in objc_debug_taggedpointer_obfuscator and
 * objc_debug_tag60_permutations): the top bit marks one; the low three bits
 * are the tag, permuted per process, with 7 meaning an extended tag in bits
 * 55-62. A basic tag's 60-bit payload is in bits 3-62, an extended tag's
 * 52-bit payload in bits 3-54; the rest is XORed with the obfuscator, except
 * in the runtime's unobfuscated (constant) form.
 */
void _objc_registerTaggedPointerClass(unsigned tag, Class cls);
extern uintptr_t objc_debug_taggedpointer_obfuscator;
extern uint8_t objc_debug_tag60_permutations[8];

#define TAG_NSString 2
#define TAG_Foundation_1 22
#define TAG_FIRST_EXTENDED 8
#define TAG_MARK (1UL << 63)
#define TAG_UNOBFUSCATED (TAG_MARK | (1UL << 62) | 7UL)

static void *
make_tagged(unsigned tag, uintptr_t payload)
{
    uintptr_t raw = tag < 7 ? TAG_MARK | tag | ((payload << 4) >> 1)
                            : TAG_MARK | 7UL | ((uintptr_t)(tag - TAG_FIRST_EXTENDED) << 55) | ((payload << 12) >> 9);
    uintptr_t value = raw ^ objc_debug_taggedpointer_obfuscator;
    if ((value & TAG_UNOBFUSCATED) == TAG_UNOBFUSCATED)
        return (void *)raw;
    return (void *)((value & ~7UL) | objc_debug_tag60_permutations[value & 7]);
}

static uintptr_t
tagged_payload(const void *ptr)
{
    uintptr_t value = (uintptr_t)ptr;
    if ((value & TAG_UNOBFUSCATED) != TAG_UNOBFUSCATED)
        value ^= objc_debug_taggedpointer_obfuscator;
    return (value & 7) == 7 ? (value << 9) >> 12 : (value << 1) >> 4;
}

/* MARK: - Constant data and dates */

@interface NSConstantData : NSData {
    NSUInteger _length;
    const char *_bytes;
}
@end

#define FINCH_IMMORTAL \
    - (instancetype)retain { return self; } \
    - (oneway void)release { } \
    - (instancetype)autorelease { return self; } \
    - (NSUInteger)retainCount { return UINTPTR_MAX; } \
    - (BOOL)_tryRetain { return YES; } \
    - (BOOL)_isDeallocating { return NO; } \
    - (id)copyWithZone:(struct _NSZone *)zone { return self; } \
    - (id)copy { return self; } \
    - (void)dealloc { }

@implementation NSConstantData
FINCH_IMMORTAL
+ (instancetype)allocWithZone:(struct _NSZone *)zone { return (id)[NSData allocWithZone:zone]; }
+ (instancetype)new { return (id)[NSData new]; }
+ (BOOL)automaticallyNotifiesObserversForKey:(id)key { return NO; }
- (NSUInteger)length { return _length; }
- (const void *)bytes { return _bytes; }
- (BOOL)_isCompact { return YES; }
@end

@interface NSConstantDate : NSDate {
    CFTimeInterval _ti;
}
@end

@implementation NSConstantDate
FINCH_IMMORTAL
+ (instancetype)allocWithZone:(struct _NSZone *)zone { return (id)[NSDate allocWithZone:zone]; }
+ (instancetype)new { return (id)[NSDate new]; }
+ (BOOL)automaticallyNotifiesObserversForKey:(id)key { return NO; }
- (CFTimeInterval)timeIntervalSinceReferenceDate { return _ti; }
@end

/* MARK: - Tagged strings */

/* The direct form: length in the low 4 bits, then a byte per character. */
#define DIRECT_MAX 7
#define INDIRECT_TAG TAG_Foundation_1

@interface NSString (FinchTaggedMessages)
- (const char *)cStringUsingEncoding:(NSUInteger)encoding;
@end

@interface NSTaggedPointerString : NSString
@end
@interface NSIndirectTaggedPointerString : NSString
@end

static void
register_tagged_classes(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        _objc_registerTaggedPointerClass(TAG_NSString, [NSTaggedPointerString class]);
        _objc_registerTaggedPointerClass(INDIRECT_TAG, [NSIndirectTaggedPointerString class]);
    });
}

static NSUInteger
direct_length(id s)
{
    return tagged_payload((const void *)s) & 0xf;
}

static unsigned char
direct_char(id s, NSUInteger i)
{
    return (unsigned char)(tagged_payload((const void *)s) >> (4 + 8 * i));
}

static const char *
indirect_bytes(id s)
{
    return (const char *)tagged_payload((const void *)s);
}

/* A tagged string for up to seven ASCII bytes, or NULL. */
CF_PRIVATE id
__CFFinchCreateTaggedString(const uint8_t *bytes, CFIndex count)
{
    if (count < 0 || count > DIRECT_MAX) return nil;
    uintptr_t payload = (uintptr_t)count;
    for (CFIndex i = 0; i < count; i++) {
        if (bytes[i] == 0 || bytes[i] > 0x7f) return nil;
        payload |= (uintptr_t)bytes[i] << (4 + 8 * i);
    }
    register_tagged_classes();
    return (id)make_tagged(TAG_NSString, payload);
}

#define FINCH_TAGGED_STRING(LENGTH, CHAR) \
    - (instancetype)retain { return self; } \
    - (oneway void)release { } \
    - (instancetype)autorelease { return self; } \
    - (NSUInteger)retainCount { return UINTPTR_MAX; } \
    - (id)copyWithZone:(struct _NSZone *)zone { return self; } \
    - (BOOL)isNSString__ { return YES; } \
    - (NSUInteger)length { return LENGTH; } \
    - (unichar)characterAtIndex:(NSUInteger)i \
    { \
        if (i >= LENGTH) \
            /* (NSInvalidArgumentException, as Apple's tagged strings raise) */ \
            __CFFinchRaise(NSInvalidArgumentException, "-[%s characterAtIndex:]: Index %lu out of bounds; string length %lu", \
                object_getClassName(self), (unsigned long)i, (unsigned long)LENGTH); \
        return CHAR(i); \
    } \
    - (void)getCharacters:(unichar *)buffer range:(NSRange)range \
    { \
        NSUInteger n = LENGTH; \
        if (range.location > n || range.length > n - range.location) \
            __CFFinchRaise(NSRangeException, "-[%s getCharacters:range:]: Range {%lu, %lu} out of bounds; string length %lu", \
                object_getClassName(self), (unsigned long)range.location, (unsigned long)range.length, (unsigned long)n); \
        for (NSUInteger i = 0; i < range.length; i++) \
            buffer[i] = CHAR(range.location + i); \
    } \
    - (NSUInteger)fastestEncoding { return 1; /* NSASCIIStringEncoding */ } \
    - (NSUInteger)smallestEncoding { return 1; } \
    - (const unichar *)_fastCharacterContents { return NULL; } \
    + (BOOL)automaticallyNotifiesObserversForKey:(id)key { return NO; }

@implementation NSTaggedPointerString
#define D_LEN direct_length(self)
#define D_CHAR(i) direct_char(self, (i))
FINCH_TAGGED_STRING(D_LEN, D_CHAR)
+ (void)_setAsTaggedStringClass { _objc_registerTaggedPointerClass(TAG_NSString, self); }
/* No storage of its own: as other short strings, a copy that lives as long as the pool. */
- (const char *)UTF8String
{
    char buf[DIRECT_MAX + 1];
    NSUInteger n = D_LEN;
    for (NSUInteger i = 0; i < n; i++) buf[i] = (char)D_CHAR(i);
    buf[n] = 0;
    return (const char *)CFDataGetBytePtr((CFDataRef)[(id)CFDataCreate(NULL, (const UInt8 *)buf, (CFIndex)n + 1) autorelease]);
}
- (BOOL)_isCString { return YES; }
- (const char *)_fastCStringContents:(BOOL)nullTerminationRequired { return NULL; }
@end

@implementation NSIndirectTaggedPointerString
#define I_LEN strlen(indirect_bytes(self))
#define I_CHAR(i) ((unsigned char)indirect_bytes(self)[(i)])
FINCH_TAGGED_STRING(I_LEN, I_CHAR)
- (id)copy { return self; }
/* Constant, NUL-terminated ASCII the caller keeps for the life of the process. */
+ (id)newIndirectTaggedNSStringWithConstantNullTerminatedASCIIBytes_:(const uint8_t *)bytes length_:(CFIndex)length
{
    uintptr_t p = (uintptr_t)bytes;
    if (!bytes || length < 0 || (p >> 52) != 0 || strnlen((const char *)bytes, (size_t)length + 1) != (size_t)length)
        return nil;
    for (CFIndex i = 0; i < length; i++)
        if (bytes[i] > 0x7f) return nil;
    register_tagged_classes();
    return (id)make_tagged(INDIRECT_TAG, p);
}
- (const char *)UTF8String { return indirect_bytes(self); }
- (const char *)_fastCStringContents:(BOOL)nullTerminationRequired { return indirect_bytes(self); }
- (const char *)_fastUTF8StringContents:(BOOL)nullTerminationRequired utf8Length:(NSUInteger *)length
{
    if (length) *length = I_LEN;
    return indirect_bytes(self);
}
- (const char *)cStringUsingEncoding:(NSUInteger)encoding
{
    if (encoding == 1 || encoding == 4)   /* ASCII, UTF-8 */
        return indirect_bytes(self);
    return [super cStringUsingEncoding:encoding];
}
@end
