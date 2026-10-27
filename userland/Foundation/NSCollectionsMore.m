/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Collection methods Foundation's headers declare that Finch's NSArray, NSMutableArray,
 * NSDictionary, NSMutableDictionary, NSSet and NSIndexSet didn't have yet (found by
 * tools/api-audit.sh): searching in ranges, tests with options, sorted keys, removals
 * by range or array, shared key sets, and reading property lists by URL. Written on
 * the classes' primitives, so they work for every subclass.
 */
#import <Foundation/Foundation.h>
#import <objc/message.h>

/* (enumeration options as the block methods take them: reverse order honoured, the
   concurrent flag runs serially, which is one of the orders it allows) */

#pragma mark - NSArray

@implementation NSArray (FinchAuditMethods)

+ (NSArray *)arrayWithContentsOfURL:(NSURL *)url error:(NSError **)error
{
    return [[[self alloc] initWithContentsOfURL:url error:error] autorelease];
}

- (instancetype)initWithContentsOfURL:(NSURL *)url error:(NSError **)error
{
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:error];
    id plist = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:error] : nil;
    if (data && ![plist isKindOfClass:[NSArray class]]) {
        if (plist && error)
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:nil];
        plist = nil;
    }
    if (!plist) {
        [self release];
        return nil;
    }
    return [self initWithArray:plist];
}

- (id)firstObjectCommonWithArray:(NSArray *)otherArray
{
    for (id o in self)
        if ([otherArray containsObject:o])
            return o;
    return nil;
}

- (NSUInteger)indexOfObject:(id)anObject inRange:(NSRange)range
{
    NSUInteger end = NSMaxRange(range);
    if (end > [self count])
        [NSException raise:NSRangeException format:@"*** -[NSArray indexOfObject:inRange:]: range %@ extends beyond bounds [0 .. %lu]",
                                                   NSStringFromRange(range), (unsigned long)([self count] ? [self count] - 1 : 0)];
    for (NSUInteger i = range.location; i < end; i++)
        if ([[self objectAtIndex:i] isEqual:anObject])
            return i;
    return NSNotFound;
}

- (NSUInteger)indexOfObjectIdenticalTo:(id)anObject inRange:(NSRange)range
{
    NSUInteger end = NSMaxRange(range);
    if (end > [self count])
        [NSException raise:NSRangeException format:@"*** -[NSArray indexOfObjectIdenticalTo:inRange:]: range %@ extends beyond bounds",
                                                   NSStringFromRange(range)];
    for (NSUInteger i = range.location; i < end; i++)
        if ([self objectAtIndex:i] == anObject)
            return i;
    return NSNotFound;
}

- (NSUInteger)indexOfObjectAtIndexes:(NSIndexSet *)s options:(NSEnumerationOptions)opts
                         passingTest:(BOOL (NS_NOESCAPE ^)(id obj, NSUInteger idx, BOOL *stop))predicate
{
    __block NSUInteger found = NSNotFound;
    [s enumerateIndexesWithOptions:opts & NSEnumerationReverse usingBlock:^(NSUInteger idx, BOOL *stop) {
        if (predicate([self objectAtIndex:idx], idx, stop)) {
            found = idx;
            *stop = YES;
        }
    }];
    return found;
}

- (NSUInteger)indexOfObjectWithOptions:(NSEnumerationOptions)opts passingTest:(BOOL (NS_NOESCAPE ^)(id obj, NSUInteger idx, BOOL *stop))predicate
{
    return [self indexOfObjectAtIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, [self count])] options:opts passingTest:predicate];
}

- (NSIndexSet *)indexesOfObjectsAtIndexes:(NSIndexSet *)s options:(NSEnumerationOptions)opts
                              passingTest:(BOOL (NS_NOESCAPE ^)(id obj, NSUInteger idx, BOOL *stop))predicate
{
    NSMutableIndexSet *found = [NSMutableIndexSet indexSet];
    [s enumerateIndexesWithOptions:opts & NSEnumerationReverse usingBlock:^(NSUInteger idx, BOOL *stop) {
        if (predicate([self objectAtIndex:idx], idx, stop))
            [found addIndex:idx];
    }];
    return [[found copy] autorelease];
}

- (NSIndexSet *)indexesOfObjectsWithOptions:(NSEnumerationOptions)opts passingTest:(BOOL (NS_NOESCAPE ^)(id obj, NSUInteger idx, BOOL *stop))predicate
{
    return [self indexesOfObjectsAtIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, [self count])] options:opts
                               passingTest:predicate];
}

/* The paths whose extensions are among those given. */
- (NSArray<NSString *> *)pathsMatchingExtensions:(NSArray<NSString *> *)filterTypes
{
    NSMutableArray *out = [NSMutableArray array];
    for (id p in self)
        if ([p isKindOfClass:[NSString class]] && [filterTypes containsObject:[p pathExtension]])
            [out addObject:p];
    return out;
}

@end

#pragma mark - NSMutableArray

@implementation NSMutableArray (FinchAuditMethods)

- (void)removeObject:(id)anObject inRange:(NSRange)range
{
    for (NSUInteger i = MIN(NSMaxRange(range), [self count]); i > range.location; i--)
        if ([[self objectAtIndex:i - 1] isEqual:anObject])
            [self removeObjectAtIndex:i - 1];
}

- (void)removeObjectIdenticalTo:(id)anObject inRange:(NSRange)range
{
    for (NSUInteger i = MIN(NSMaxRange(range), [self count]); i > range.location; i--)
        if ([self objectAtIndex:i - 1] == anObject)
            [self removeObjectAtIndex:i - 1];
}

- (void)removeObjectsInArray:(NSArray *)otherArray
{
    if (otherArray == self) {
        [self removeAllObjects];
        return;
    }
    NSSet *gone = [NSSet setWithArray:otherArray];
    for (NSUInteger i = [self count]; i > 0; i--)
        if ([gone containsObject:[self objectAtIndex:i - 1]])
            [self removeObjectAtIndex:i - 1];
}

- (void)removeObjectsFromIndices:(NSUInteger *)indices numIndices:(NSUInteger)cnt
{
    NSMutableIndexSet *set = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < cnt; i++)
        [set addIndex:indices[i]];
    [self removeObjectsAtIndexes:set];
}

- (void)replaceObjectsInRange:(NSRange)range withObjectsFromArray:(NSArray *)otherArray range:(NSRange)otherRange
{
    [self replaceObjectsInRange:range withObjectsFromArray:[otherArray subarrayWithRange:otherRange]];
}

- (void)replaceObjectsInRange:(NSRange)range withObjectsFromArray:(NSArray *)otherArray
{
    NSArray *incoming = otherArray == self ? [[otherArray copy] autorelease] : otherArray;
    [self removeObjectsInRange:range];
    [self insertObjects:incoming atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(range.location, [incoming count])]];
}

@end

#pragma mark - NSDictionary

/* A shared key set: the keys a family of dictionaries will use (CoreFoundation's
   class, as Apple's; Finch's dictionaries take it as a hint). */
@interface NSSharedKeySet : NSObject
+ (id)keySetWithKeys:(NSArray *)keys;
@end

@implementation NSDictionary (FinchAuditMethods)

+ (NSDictionary *)dictionaryWithContentsOfURL:(NSURL *)url error:(NSError **)error
{
    return [[[self alloc] initWithContentsOfURL:url error:error] autorelease];
}

- (instancetype)initWithContentsOfURL:(NSURL *)url error:(NSError **)error
{
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:error];
    id plist = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:error] : nil;
    if (data && ![plist isKindOfClass:[NSDictionary class]]) {
        if (plist && error)
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:nil];
        plist = nil;
    }
    if (!plist) {
        [self release];
        return nil;
    }
    return [self initWithDictionary:plist];
}

+ (id)sharedKeySetForKeys:(NSArray *)keys
{
    return [NSSharedKeySet keySetWithKeys:keys];
}

/* As a .strings file has it: "key" = "value"; per line. */
- (NSString *)descriptionInStringsFileFormat
{
    NSMutableString *s = [NSMutableString string];
    /* (strings quoted; other values as they describe themselves) */
    NSString * (^quote)(id) = ^NSString *(id o) {
        NSString *t = [o description];
        t = [t stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
        t = [t stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
        t = [t stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
        return [NSString stringWithFormat:@"\"%@\"", t];
    };
    for (id key in [[self allKeys] sortedArrayUsingSelector:@selector(compare:)])
        [s appendFormat:@"%@ = %@;\n", quote(key), [[self objectForKey:key] isKindOfClass:[NSString class]] ? quote([self objectForKey:key])
                                                                                                         : [[self objectForKey:key] description]];
    return s;
}

- (NSSet *)keysOfEntriesWithOptions:(NSEnumerationOptions)opts passingTest:(BOOL (NS_NOESCAPE ^)(id key, id obj, BOOL *stop))predicate
{
    NSMutableSet *found = [NSMutableSet set];
    BOOL stop = NO;
    for (id key in [self allKeys]) {
        if (predicate(key, [self objectForKey:key], &stop))
            [found addObject:key];
        if (stop)
            break;
    }
    return found;
}

- (NSSet *)keysOfEntriesPassingTest:(BOOL (NS_NOESCAPE ^)(id key, id obj, BOOL *stop))predicate
{
    return [self keysOfEntriesWithOptions:0 passingTest:predicate];
}

- (NSArray *)keysSortedByValueWithOptions:(NSSortOptions)opts usingComparator:(NSComparator NS_NOESCAPE)cmptr
{
    return [[self allKeys] sortedArrayWithOptions:opts
                                  usingComparator:^NSComparisonResult(id a, id b) {
                                      return cmptr([self objectForKey:a], [self objectForKey:b]);
                                  }];
}

- (NSArray *)keysSortedByValueUsingComparator:(NSComparator NS_NOESCAPE)cmptr
{
    return [self keysSortedByValueWithOptions:0 usingComparator:cmptr];
}

- (NSArray *)keysSortedByValueUsingSelector:(SEL)comparator
{
    return [self keysSortedByValueWithOptions:0
                              usingComparator:^NSComparisonResult(id a, id b) {
                                  return ((NSComparisonResult(*)(id, SEL, id))[a methodForSelector:comparator])(a, comparator, b);
                              }];
}

- (NSArray *)objectsForKeys:(NSArray *)keys notFoundMarker:(id)marker
{
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:[keys count]];
    for (id key in keys)
        [out addObject:[self objectForKey:key] ?: marker];
    return out;
}

@end

@implementation NSMutableDictionary (FinchAuditMethods)

+ (NSMutableDictionary *)dictionaryWithSharedKeySet:(id)keyset
{
    if (keyset && ![keyset isKindOfClass:[NSSharedKeySet class]])
        [NSException raise:NSInvalidArgumentException format:@"*** +[NSMutableDictionary dictionaryWithSharedKeySet:]: keyset is not a shared key set"];
    return [self dictionaryWithCapacity:[keyset count]];
}

@end

#pragma mark - NSSet

@implementation NSSet (FinchAuditMethods)

- (void)enumerateObjectsWithOptions:(NSEnumerationOptions)opts usingBlock:(void (NS_NOESCAPE ^)(id obj, BOOL *stop))block
{
    BOOL stop = NO;
    for (id o in [self allObjects]) {
        block(o, &stop);
        if (stop)
            break;
    }
}

- (void)makeObjectsPerformSelector:(SEL)aSelector withObject:(id)argument
{
    for (id o in [self allObjects])
        ((void (*)(id, SEL, id))objc_msgSend)(o, aSelector, argument);
}

- (NSSet *)objectsWithOptions:(NSEnumerationOptions)opts passingTest:(BOOL (NS_NOESCAPE ^)(id obj, BOOL *stop))predicate
{
    NSMutableSet *found = [NSMutableSet set];
    BOOL stop = NO;
    for (id o in [self allObjects]) {
        if (predicate(o, &stop))
            [found addObject:o];
        if (stop)
            break;
    }
    return found;
}

- (NSSet *)objectsPassingTest:(BOOL (NS_NOESCAPE ^)(id obj, BOOL *stop))predicate
{
    return [self objectsWithOptions:0 passingTest:predicate];
}

@end

#pragma mark - NSIndexSet

@implementation NSIndexSet (FinchAuditMethods)

- (NSUInteger)indexInRange:(NSRange)range options:(NSEnumerationOptions)opts passingTest:(BOOL (NS_NOESCAPE ^)(NSUInteger idx, BOOL *stop))predicate
{
    __block NSUInteger found = NSNotFound;
    [self enumerateIndexesInRange:range options:opts & NSEnumerationReverse usingBlock:^(NSUInteger idx, BOOL *stop) {
        if (predicate(idx, stop)) {
            found = idx;
            *stop = YES;
        }
    }];
    return found;
}

- (NSUInteger)indexWithOptions:(NSEnumerationOptions)opts passingTest:(BOOL (NS_NOESCAPE ^)(NSUInteger idx, BOOL *stop))predicate
{
    return [self indexInRange:NSMakeRange(0, NSNotFound - 1) options:opts passingTest:predicate];
}

- (NSIndexSet *)indexesInRange:(NSRange)range options:(NSEnumerationOptions)opts passingTest:(BOOL (NS_NOESCAPE ^)(NSUInteger idx, BOOL *stop))predicate
{
    NSMutableIndexSet *found = [NSMutableIndexSet indexSet];
    [self enumerateIndexesInRange:range options:opts & NSEnumerationReverse usingBlock:^(NSUInteger idx, BOOL *stop) {
        if (predicate(idx, stop))
            [found addIndex:idx];
    }];
    return [[found copy] autorelease];
}

- (NSIndexSet *)indexesWithOptions:(NSEnumerationOptions)opts passingTest:(BOOL (NS_NOESCAPE ^)(NSUInteger idx, BOOL *stop))predicate
{
    return [self indexesInRange:NSMakeRange(0, NSNotFound - 1) options:opts passingTest:predicate];
}

@end
