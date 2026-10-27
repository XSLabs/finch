/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSPurgeableData (docs/design/FOUNDATION.md), against the SDK's
 * <Foundation/NSData.h>: mutable data whose bytes may be thrown away while
 * nobody is accessing them (NSDiscardableContent). As Apple's, a new object
 * starts with one access open, using the bytes outside an access raises, and
 * once discarded the content can't be accessed again. Bytes are only thrown
 * away when asked (-discardContentIfPossible, which NSCache calls); Finch has
 * no purgeable-memory pressure handling yet.
 *
 * NSGarbageCollector (<Foundation/NSGarbageCollector.h>), from the garbage
 * collection Objective-C no longer has: there is no collector, so
 * +defaultCollector is nil, as Apple's is.
 */
#import <Foundation/Foundation.h>

#include "Foundation_Finch.h"

/* MARK: - NSPurgeableData */

@interface NSPurgeableData () {
    NSMutableData *_bytes;
    NSUInteger _accesses;
    BOOL _discarded;
}
@end

@implementation NSPurgeableData

- (instancetype)init
{
    if ((self = [super init])) {
        _bytes = [[NSMutableData alloc] init];
        _accesses = 1;
    }
    return self;
}

- (instancetype)initWithBytes:(const void *)bytes length:(NSUInteger)length
{
    if ((self = [self init])) [_bytes appendBytes:bytes length:length];
    return self;
}

- (instancetype)initWithCapacity:(NSUInteger)capacity { return [self init]; }

- (void)dealloc
{
    [_bytes release];
    [super dealloc];
}

- (void)check:(SEL)cmd
{
    if (!_accesses || _discarded)
        FinchRaise(NSGenericException, "*** -[%s %s]: <%s: %p> accessed outside successful -beginContentAccess and -endContentAccess calls.",
            object_getClassName(self), sel_getName(cmd), object_getClassName(self), self);
}

- (NSUInteger)length
{
    [self check:_cmd];
    return [_bytes length];
}

- (const void *)bytes
{
    [self check:_cmd];
    return [_bytes bytes];
}

- (void *)mutableBytes
{
    [self check:_cmd];
    return [_bytes mutableBytes];
}

- (void)setLength:(NSUInteger)length
{
    [self check:_cmd];
    [_bytes setLength:length];
}

- (BOOL)beginContentAccess
{
    @synchronized(self) {
        if (_discarded) return NO;
        _accesses++;
        return YES;
    }
}

- (void)endContentAccess
{
    @synchronized(self) {
        if (!_accesses)
            FinchRaise(NSGenericException, "*** -[%s %s]: called without successful matching -beginContentAccess",
                object_getClassName(self), sel_getName(_cmd));
        _accesses--;
    }
}

- (void)discardContentIfPossible
{
    @synchronized(self) {
        if (_accesses || _discarded) return;
        _discarded = YES;
        [_bytes release];
        _bytes = nil;
    }
}

- (BOOL)isContentDiscarded { return _discarded; }

/* The bytes only while they can be accessed. */
- (NSString *)description
{
    if (!_accesses || _discarded) return [NSString stringWithFormat:@"<%s: %p>", object_getClassName(self), self];
    return [super description];
}

@end

/* MARK: - NSGarbageCollector */

@implementation NSGarbageCollector

+ (id)defaultCollector { return nil; }
- (BOOL)isCollecting { return NO; }
- (void)disable { }
- (void)enable { }
- (BOOL)isEnabled { return NO; }
- (void)collectIfNeeded { }
- (void)collectExhaustively { }
- (void)disableCollectorForPointer:(const void *)ptr { }
- (void)enableCollectorForPointer:(const void *)ptr { }
- (NSZone *)zone { return NSDefaultMallocZone(); }

@end
