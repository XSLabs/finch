/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSSharedKeySet, the keys a family of dictionaries will use
 * (+[NSDictionary sharedKeySetForKeys:]). Apple's CoreFoundation defines and
 * exports it; Apple's lays the keys out by a minimal perfect hash, so its
 * indexes are its own business. Finch's keeps them in order, with a
 * dictionary for lookups, and answers the same messages: indexes, keys at
 * indexes, enumeration, chaining to a sub-key-set, equality and secure coding
 * (NS.keys, NS.numKey and NS.subskset, which Apple's archives also carry).
 */

#include "CFObjCClasses_Finch.h"

@protocol NSCoding
- (void)encodeWithCoder:(id)coder;
- (id)initWithCoder:(id)coder;
@end
@protocol NSSecureCoding <NSCoding>
+ (BOOL)supportsSecureCoding;
@end

/* NSCoder's and NSSet's messages (Foundation's, which CF's headers don't declare). */
@interface NSObject (FinchSharedKeySetMessages)
- (void)encodeObject:(id)object forKey:(id)key;
- (void)encodeInt32:(int32_t)value forKey:(id)key;
- (id)decodeObjectOfClasses:(id)classes forKey:(id)key;
- (id)decodeObjectOfClass:(Class)cls forKey:(id)key;
+ (id)setWithObjects:(id)first, ... __attribute__((sentinel));
@end

@interface NSSharedKeySet : NSObject <NSCopying, NSSecureCoding, NSFastEnumeration> {
    CFArrayRef _keys;
    CFDictionaryRef _indexes;       /* key -> index + 1 */
    NSSharedKeySet *_subSharedKeySet;
}
- (instancetype)initWithKeys:(id *)keys count:(NSUInteger)count;
- (NSUInteger)count;
- (NSUInteger)indexForKey:(id)key;
- (id)keyAtIndex:(NSUInteger)index;
- (NSUInteger)keySetCount;
- (id)allKeys;
- (void)setSubSharedKeySet:(NSSharedKeySet *)s;
@end

@implementation NSSharedKeySet

+ (BOOL)supportsSecureCoding { return YES; }

+ (id)keySetWithKeys:(id)keys
{
    CFArrayRef array = (CFArrayRef)keys;
    CFIndex n = array ? CFArrayGetCount(array) : 0;
    id stackbuf[64], *objects = n <= 64 ? stackbuf : malloc((size_t)n * sizeof(id));
    if (n) CFArrayGetValues(array, CFRangeMake(0, n), (const void **)objects);
    NSSharedKeySet *s = [[[self alloc] initWithKeys:objects count:(NSUInteger)n] autorelease];
    if (objects != stackbuf) free(objects);
    return s;
}

- (instancetype)init { return [self initWithKeys:NULL count:0]; }

- (instancetype)initWithKeys:(id *)keys count:(NSUInteger)count
{
    if ((self = [super init])) {
        CFMutableArrayRef list = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
        CFMutableDictionaryRef indexes = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, NULL);
        for (NSUInteger i = 0; i < count; i++) {
            if (!keys[i] || CFDictionaryContainsKey(indexes, keys[i]))
                continue;
            CFDictionarySetValue(indexes, keys[i], (const void *)(uintptr_t)(CFArrayGetCount(list) + 1));
            CFArrayAppendValue(list, keys[i]);
        }
        _keys = list;
        _indexes = indexes;
    }
    return self;
}

- (void)dealloc
{
    if (_keys) CFRelease(_keys);
    if (_indexes) CFRelease(_indexes);
    [_subSharedKeySet release];
    [super dealloc];
}

- (id)copyWithZone:(struct _NSZone *)zone { return [self retain]; }

- (NSUInteger)ownCount { return (NSUInteger)CFArrayGetCount(_keys); }
- (NSUInteger)count { return [self ownCount] + (_subSharedKeySet ? [_subSharedKeySet count] : 0); }
- (BOOL)isEmpty { return [self count] == 0; }
- (NSUInteger)keySetCount { return 1 + (_subSharedKeySet ? [_subSharedKeySet keySetCount] : 0); }
- (NSUInteger)maximumIndex { NSUInteger n = [self count]; return n ? n - 1 : 0; }

/* A sub-key-set's keys follow this one's. */
- (NSUInteger)indexForKey:(id)key
{
    const void *i = NULL;
    if (key && CFDictionaryGetValueIfPresent(_indexes, key, &i)) return (NSUInteger)(uintptr_t)i - 1;
    NSUInteger sub = _subSharedKeySet ? [_subSharedKeySet indexForKey:key] : NSNotFound;
    return sub == NSNotFound ? NSNotFound : [self ownCount] + sub;
}

- (id)keyAtIndex:(NSUInteger)index
{
    if (index < [self ownCount]) return (id)CFArrayGetValueAtIndex(_keys, (CFIndex)index);
    return _subSharedKeySet ? [_subSharedKeySet keyAtIndex:index - [self ownCount]] : nil;
}

- (id)allKeys
{
    CFMutableArrayRef all = CFArrayCreateMutableCopy(NULL, 0, _keys);
    if (_subSharedKeySet) {
        CFArrayRef sub = (CFArrayRef)[_subSharedKeySet allKeys];
        CFArrayAppendArray(all, sub, CFRangeMake(0, CFArrayGetCount(sub)));
    }
    return [(id)all autorelease];
}

- (NSSharedKeySet *)subSharedKeySet { return _subSharedKeySet; }
- (void)setSubSharedKeySet:(NSSharedKeySet *)s
{
    [s retain];
    [_subSharedKeySet release];
    _subSharedKeySet = s;
}

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state objects:(id __unsafe_unretained [])buffer
                                    count:(NSUInteger)len
{
    return [[self allKeys] countByEnumeratingWithState:state objects:buffer count:len];
}

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[NSSharedKeySet class]] || [other count] != [self count]) return NO;
    for (NSUInteger i = 0; i < [self count]; i++)
        if ([other indexForKey:[self keyAtIndex:i]] == NSNotFound) return NO;
    return YES;
}

- (NSUInteger)hash { return [self count]; }

- (void)encodeWithCoder:(id)coder
{
    [coder encodeObject:(id)_keys forKey:@"NS.keys"];
    [coder encodeInt32:(int32_t)[self ownCount] forKey:@"NS.numKey"];
    [coder encodeObject:_subSharedKeySet forKey:@"NS.subskset"];
}

- (instancetype)initWithCoder:(id)coder
{
    id classes = [objc_getClass("NSSet") setWithObjects:objc_getClass("NSArray"), objc_getClass("NSString"),
        objc_getClass("NSNumber"), nil];
    id keys = [coder decodeObjectOfClasses:classes forKey:@"NS.keys"];
    if (keys && CFGetTypeID((CFTypeRef)keys) != CFArrayGetTypeID()) {
        [self release];
        return nil;
    }
    CFIndex n = keys ? CFArrayGetCount((CFArrayRef)keys) : 0;
    id stackbuf[64], *objects = n <= 64 ? stackbuf : malloc((size_t)n * sizeof(id));
    if (n) CFArrayGetValues((CFArrayRef)keys, CFRangeMake(0, n), (const void **)objects);
    self = [self initWithKeys:objects count:(NSUInteger)n];
    if (objects != stackbuf) free(objects);
    if (self) {
        id sub = [coder decodeObjectOfClass:[NSSharedKeySet class] forKey:@"NS.subskset"];
        if ([sub isKindOfClass:[NSSharedKeySet class]])
            [self setSubSharedKeySet:sub];
    }
    return self;
}

- (id)debugDescription
{
    return [(id)CFStringCreateWithFormat(NULL, NULL, CFSTR("<%s %p> %lu keys: %@"), object_getClassName(self), self,
        (unsigned long)[self count], [self allKeys]) autorelease];
}

@end
