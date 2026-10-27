/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Scripting's "whose" clauses and insertion points (docs/design/FOUNDATION.md),
 * against the SDK's <Foundation/NSScriptWhoseTests.h>,
 * <Foundation/NSScriptObjectSpecifiers.h> and
 * <Foundation/NSScriptExecutionContext.h>: the tests (NSSpecifierTest,
 * NSLogicalTest), NSWhoseSpecifier, NSPositionalSpecifier and the execution
 * context a test evaluates its object against. Specifiers describe themselves
 * as Apple's do ("<NSNameSpecifier: words named "x" of name of orderedDocuments 1>"),
 * which these classes' descriptions are made of.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include "Foundation_Finch.h"

/* MARK: - NSScriptExecutionContext */

@implementation NSScriptExecutionContext

+ (NSScriptExecutionContext *)sharedScriptExecutionContext
{
    static NSScriptExecutionContext *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[NSScriptExecutionContext alloc] init]; });
    return shared;
}

- (void)dealloc
{
    [_topLevelObject release];
    [_objectBeingTested release];
    [_rangeContainerObject release];
    [super dealloc];
}

- (id)topLevelObject { return _topLevelObject; }
- (void)setTopLevelObject:(id)obj
{
    [_topLevelObject autorelease];
    _topLevelObject = [obj retain];
}
- (id)objectBeingTested { return _objectBeingTested; }
- (void)setObjectBeingTested:(id)obj
{
    [_objectBeingTested autorelease];
    _objectBeingTested = [obj retain];
}
- (id)rangeContainerObject { return _rangeContainerObject; }
- (void)setRangeContainerObject:(id)obj
{
    [_rangeContainerObject autorelease];
    _rangeContainerObject = [obj retain];
}

@end

/* MARK: - Descriptions of specifiers */

/* A specifier's words, then its container's after "of": what Apple's descriptions are made of. */
@interface NSScriptObjectSpecifier (FinchPhrase)
- (NSString *)_finchOwnPhrase;
- (NSString *)_finchPhrase;
@end

/* An element's ordinal as Apple's descriptions give it: from one, or as given if negative. */
static NSString *
ordinal(NSInteger index)
{
    return [NSString stringWithFormat:@"%ld", (long)(index >= 0 ? index + 1 : index)];
}

@implementation NSScriptObjectSpecifier (FinchPhrase)
- (NSString *)_finchOwnPhrase { return [self key]; }
- (NSString *)_finchPhrase
{
    NSScriptObjectSpecifier *container = [self containerSpecifier];
    return container ? [NSString stringWithFormat:@"%@ of %@", [self _finchOwnPhrase], [container _finchPhrase]] : [self _finchOwnPhrase];
}
- (NSString *)description { return [NSString stringWithFormat:@"<%s: %@>", object_getClassName(self), [self _finchPhrase]]; }
@end

@implementation NSIndexSpecifier (FinchPhrase)
- (NSString *)_finchOwnPhrase { return [NSString stringWithFormat:@"%@ %@", [self key], ordinal([self index])]; }
@end
@implementation NSMiddleSpecifier (FinchPhrase)
- (NSString *)_finchOwnPhrase { return [@"middle " stringByAppendingString:[self key]]; }
@end
@implementation NSRandomSpecifier (FinchPhrase)
- (NSString *)_finchOwnPhrase { return [@"some " stringByAppendingString:[self key]]; }
@end
@implementation NSNameSpecifier (FinchPhrase)
- (NSString *)_finchOwnPhrase { return [NSString stringWithFormat:@"%@ named \"%@\"", [self key], [self name]]; }
@end
@implementation NSUniqueIDSpecifier (FinchPhrase)
- (NSString *)_finchOwnPhrase { return [NSString stringWithFormat:@"%@ with an ID of \"%@\"", [self key], [self uniqueID]]; }
@end
@implementation NSRangeSpecifier (FinchPhrase)
- (NSString *)_finchOwnPhrase
{
    return [NSString stringWithFormat:@"%@ from %@ to %@", [self key], [self startSpecifier], [self endSpecifier]];
}
@end
@implementation NSRelativeSpecifier (FinchPhrase)
- (NSString *)_finchOwnPhrase
{
    return [NSString stringWithFormat:@"%@ %@ %@", [self key], [self relativePosition] == NSRelativeAfter ? @"after" : @"before",
                     [self baseSpecifier]];
}
@end

/* MARK: - NSScriptWhoseTest */

@implementation NSScriptWhoseTest

- (BOOL)isTrue { return NO; }
- (instancetype)init { return [super init]; }
- (instancetype)initWithCoder:(NSCoder *)inCoder { return [super init]; }
- (void)encodeWithCoder:(NSCoder *)coder { }

@end

/* MARK: - NSLogicalTest */

enum { LogicalAnd = 0, LogicalOr = 1, LogicalNot = 2 };

@implementation NSLogicalTest

- (instancetype)_initWithOperator:(int)op tests:(NSArray *)tests
{
    if ((self = [super init])) {
        _operator = op;
        _subTests = [tests copy];
    }
    return self;
}

- (instancetype)initAndTestWithTests:(NSArray<NSSpecifierTest *> *)subTests { return [self _initWithOperator:LogicalAnd tests:subTests]; }
- (instancetype)initOrTestWithTests:(NSArray<NSSpecifierTest *> *)subTests { return [self _initWithOperator:LogicalOr tests:subTests]; }
- (instancetype)initNotTestWithTest:(NSScriptWhoseTest *)subTest
{
    return [self _initWithOperator:LogicalNot tests:subTest ? @[ subTest ] : @[]];
}

- (instancetype)initWithCoder:(NSCoder *)inCoder
{
    if ((self = [super initWithCoder:inCoder])) {
        int op = 0;
        [inCoder decodeValueOfObjCType:@encode(int) at:&op size:sizeof op];
        _operator = op;
        _subTests = [[inCoder decodeObject] copy];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    int op = _operator;
    [coder encodeValueOfObjCType:@encode(int) at:&op];
    [coder encodeObject:_subTests];
}

- (void)dealloc
{
    [_subTests release];
    [super dealloc];
}

- (BOOL)isTrue
{
    switch (_operator) {
    case LogicalAnd:
        for (NSScriptWhoseTest *t in _subTests)
            if (![t isTrue]) return NO;
        return YES;
    case LogicalOr:
        for (NSScriptWhoseTest *t in _subTests)
            if ([t isTrue]) return YES;
        return NO;
    default:
        return ![[_subTests firstObject] isTrue];
    }
}

/* Apple's: the tests joined by "AND" or "OR", or "NOT" and the test. */
- (NSString *)description
{
    if (_operator == LogicalNot) return [NSString stringWithFormat:@"NOT %@", [_subTests firstObject]];
    NSMutableArray *parts = [NSMutableArray array];
    for (id t in _subTests) [parts addObject:[t description]];
    return [parts componentsJoinedByString:_operator == LogicalAnd ? @" AND " : @" OR "];
}

@end

/* MARK: - NSSpecifierTest */

@implementation NSSpecifierTest

- (instancetype)initWithObjectSpecifier:(NSScriptObjectSpecifier *)obj1 comparisonOperator:(NSTestComparisonOperation)compOp testObject:(id)obj2
{
    if ((self = [super init])) {
        _object1 = [obj1 retain];
        _comparisonOperator = compOp;
        _object2 = [obj2 retain];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)inCoder
{
    if ((self = [super initWithCoder:inCoder])) {
        NSUInteger op = 0;
        [inCoder decodeValueOfObjCType:@encode(NSUInteger) at:&op size:sizeof op];
        _comparisonOperator = op;
        _object1 = [[inCoder decodeObject] retain];
        _object2 = [[inCoder decodeObject] retain];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    NSUInteger op = _comparisonOperator;
    [coder encodeValueOfObjCType:@encode(NSUInteger) at:&op];
    [coder encodeObject:_object1];
    [coder encodeObject:_object2];
}

- (void)dealloc
{
    [_object1 release];
    [_object2 release];
    [super dealloc];
}

static id
evaluated(id object)
{
    return [object isKindOfClass:[NSScriptObjectSpecifier class]] ? [object objectsByEvaluatingSpecifier] : object;
}

/* The object (evaluated against the object being tested) compared with the test object,
   by the scripting comparison methods. */
- (BOOL)isTrue
{
    id a = evaluated(_object1), b = evaluated(_object2);
    if (!a || !b) return !a && !b && _comparisonOperator == NSEqualToComparison;
    switch (_comparisonOperator) {
    case NSEqualToComparison: return [a scriptingIsEqualTo:b];
    case NSLessThanOrEqualToComparison: return [a scriptingIsLessThanOrEqualTo:b];
    case NSLessThanComparison: return [a scriptingIsLessThan:b];
    case NSGreaterThanOrEqualToComparison: return [a scriptingIsGreaterThanOrEqualTo:b];
    case NSGreaterThanComparison: return [a scriptingIsGreaterThan:b];
    case NSBeginsWithComparison: return [a scriptingBeginsWith:b];
    case NSEndsWithComparison: return [a scriptingEndsWith:b];
    case NSContainsComparison: return [a scriptingContains:b];
    default: return NO;
    }
}

- (NSString *)description
{
    static NSString *const operators[] = { @"=", @"<=", @"<", @">=", @">", @"begins with", @"ends with", @"contains" };
    NSString *op = _comparisonOperator < 8 ? operators[_comparisonOperator] : @"<unknown operation type>";
    return [NSString stringWithFormat:@"<NSSpecifierTest: %@ %@ %@>", _object1, op, _object2];
}

@end

/* MARK: - NSWhoseSpecifier */

@implementation NSWhoseSpecifier

- (instancetype)initWithContainerClassDescription:(NSScriptClassDescription *)classDesc
                               containerSpecifier:(NSScriptObjectSpecifier *)container
                                              key:(NSString *)property
                                             test:(NSScriptWhoseTest *)test
{
    if ((self = [super initWithContainerClassDescription:classDesc containerSpecifier:container key:property])) {
        _test = [test retain];
        _startSubelementIdentifier = NSEverySubelement;
        _endSubelementIdentifier = NSNoSubelement;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)inCoder
{
    if ((self = [super initWithCoder:inCoder])) {
        _test = [[inCoder decodeObjectForKey:@"NSTest"] retain];
        _startSubelementIdentifier = (NSWhoseSubelementIdentifier)[inCoder decodeIntegerForKey:@"NSStartSubelementIdentifier"];
        _startSubelementIndex = [inCoder decodeIntegerForKey:@"NSStartSubelementIndex"];
        _endSubelementIdentifier = (NSWhoseSubelementIdentifier)[inCoder decodeIntegerForKey:@"NSEndSubelementIdentifier"];
        _endSubelementIndex = [inCoder decodeIntegerForKey:@"NSEndSubelementIndex"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeObject:_test forKey:@"NSTest"];
    [coder encodeInteger:(NSInteger)_startSubelementIdentifier forKey:@"NSStartSubelementIdentifier"];
    [coder encodeInteger:_startSubelementIndex forKey:@"NSStartSubelementIndex"];
    [coder encodeInteger:(NSInteger)_endSubelementIdentifier forKey:@"NSEndSubelementIdentifier"];
    [coder encodeInteger:_endSubelementIndex forKey:@"NSEndSubelementIndex"];
}

- (void)dealloc
{
    [_test release];
    [super dealloc];
}

- (NSScriptWhoseTest *)test { return _test; }
- (void)setTest:(NSScriptWhoseTest *)test
{
    [_test autorelease];
    _test = [test retain];
}
- (NSWhoseSubelementIdentifier)startSubelementIdentifier { return _startSubelementIdentifier; }
- (void)setStartSubelementIdentifier:(NSWhoseSubelementIdentifier)identifier { _startSubelementIdentifier = identifier; }
- (NSInteger)startSubelementIndex { return _startSubelementIndex; }
- (void)setStartSubelementIndex:(NSInteger)index { _startSubelementIndex = index; }
- (NSWhoseSubelementIdentifier)endSubelementIdentifier { return _endSubelementIdentifier; }
- (void)setEndSubelementIdentifier:(NSWhoseSubelementIdentifier)identifier { _endSubelementIdentifier = identifier; }
- (NSInteger)endSubelementIndex { return _endSubelementIndex; }
- (void)setEndSubelementIndex:(NSInteger)index { _endSubelementIndex = index; }

static NSString *
subelement(NSWhoseSubelementIdentifier identifier, NSInteger index)
{
    switch (identifier) {
    case NSIndexSubelement: return [@"element " stringByAppendingString:ordinal(index)];
    case NSEverySubelement: return @"all";
    case NSMiddleSubelement: return @"middle element";
    case NSRandomSubelement: return @"any element";
    default: return @"";
    }
}

/* Apple's: "all items satisfying test ...", "element 3 of items ...", "from all to middle element of items ...". */
- (NSString *)_finchOwnPhrase
{
    NSString *start = subelement(_startSubelementIdentifier, _startSubelementIndex), *which;
    if (_endSubelementIdentifier != NSNoSubelement)
        which = [NSString stringWithFormat:@"from %@ to %@ of %@", start, subelement(_endSubelementIdentifier, _endSubelementIndex), [self key]];
    else if (_startSubelementIdentifier == NSEverySubelement)
        which = [@"all " stringByAppendingString:[self key]];
    else
        which = [NSString stringWithFormat:@"%@ of %@", start, [self key]];
    return [NSString stringWithFormat:@"%@ satisfying test %@", which, _test];
}

/* One of the matching elements' positions, by a subelement identifier; NSNotFound if none. */
static NSInteger
pick(NSWhoseSubelementIdentifier identifier, NSInteger index, NSInteger count)
{
    if (!count) return NSNotFound;
    switch (identifier) {
    case NSIndexSubelement: {
        NSInteger i = index < 0 ? count + index : index;
        return i >= 0 && i < count ? i : NSNotFound;
    }
    case NSMiddleSubelement: return (count - 1) / 2;
    case NSRandomSubelement: return (NSInteger)arc4random_uniform((uint32_t)count);
    case NSEverySubelement: return 0;
    default: return NSNotFound;
    }
}

/* The elements the test is true of (each tested in turn as the context's object being
   tested), then the subelements asked for among them. */
- (NSInteger *)indicesOfObjectsByEvaluatingWithContainer:(id)container count:(NSInteger *)count
{
    id value = [container valueForKey:[self key]];
    NSArray *all = [value isKindOfClass:[NSArray class]] ? value : value ? @[ value ] : @[];
    NSScriptExecutionContext *context = [NSScriptExecutionContext sharedScriptExecutionContext];
    id previous = [[[context objectBeingTested] retain] autorelease];
    NSMutableArray *matches = [NSMutableArray array];
    for (NSUInteger i = 0; i < [all count]; i++) {
        [context setObjectBeingTested:[all objectAtIndex:i]];
        if ([_test isTrue]) [matches addObject:@(i)];
    }
    [context setObjectBeingTested:previous];
    NSInteger n = (NSInteger)[matches count], first, last;
    if (_endSubelementIdentifier == NSNoSubelement && _startSubelementIdentifier == NSEverySubelement) {
        first = 0, last = n - 1;
    } else {
        first = pick(_startSubelementIdentifier, _startSubelementIndex, n);
        last = _endSubelementIdentifier == NSNoSubelement ? first
             : _endSubelementIdentifier == NSEverySubelement ? n - 1
                                                             : pick(_endSubelementIdentifier, _endSubelementIndex, n);
        if (first == NSNotFound || last == NSNotFound) {
            *count = 0;
            [self setEvaluationErrorNumber:NSInvalidIndexSpecifierError];
            return NULL;
        }
        if (first > last) {
            NSInteger t = first;
            first = last, last = t;
        }
    }
    NSInteger m = last >= first ? last - first + 1 : 0;
    NSMutableData *d = [NSMutableData dataWithLength:sizeof(NSInteger) * (NSUInteger)MAX(m, 1)];
    NSInteger *out = (NSInteger *)[d mutableBytes];
    for (NSInteger i = 0; i < m; i++) out[i] = [[matches objectAtIndex:(NSUInteger)(first + i)] integerValue];
    *count = m;
    return out;
}

@end

/* MARK: - NSPositionalSpecifier */

/* What -evaluate found (Apple's _moreVars). */
#define _evaluated ((NSMutableDictionary *)_moreVars)

@implementation NSPositionalSpecifier

- (instancetype)initWithPosition:(NSInsertionPosition)position objectSpecifier:(NSScriptObjectSpecifier *)specifier
{
    if ((self = [super init])) {
        _unadjustedPosition = position;
        _specifier = [specifier retain];
        _moreVars = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [_specifier release];
    [_insertionClassDescription release];
    [_moreVars release];
    [super dealloc];
}

- (NSInsertionPosition)position { return _unadjustedPosition; }
- (NSScriptObjectSpecifier *)objectSpecifier { return _specifier; }

- (void)setInsertionClassDescription:(NSScriptClassDescription *)classDescription
{
    [_insertionClassDescription autorelease];
    _insertionClassDescription = [classDescription retain];
}

static BOOL
inserts_beside(NSInsertionPosition position)
{
    return position == NSPositionAfter || position == NSPositionBefore || position == NSPositionReplace;
}

/* Where an insertion goes: beside the specified object, in its container's collection, or
   at the beginning or end of the specified object's collection of the inserted class. */
- (void)evaluate
{
    [_evaluated removeAllObjects];
    _evaluated[@"evaluated"] = @YES;
    if (inserts_beside(_unadjustedPosition)) {
        NSScriptObjectSpecifier *containerSpec = [_specifier containerSpecifier];
        id container = containerSpec ? [containerSpec objectsByEvaluatingSpecifier]
                                     : [[NSScriptExecutionContext sharedScriptExecutionContext] topLevelObject];
        if (!container) return;
        NSInteger n = 0, *indices = [_specifier indicesOfObjectsByEvaluatingWithContainer:container count:&n];
        if (!indices || n < 1) return;
        NSInteger index = indices[0] + (_unadjustedPosition == NSPositionAfter ? 1 : 0);
        _evaluated[@"container"] = container;
        _evaluated[@"index"] = @(index);
        if (_unadjustedPosition == NSPositionReplace) _evaluated[@"replaces"] = @YES;
        return;
    }
    id container = [_specifier objectsByEvaluatingSpecifier];
    if (!container) return;
    NSScriptClassDescription *containerDescription = (NSScriptClassDescription *)[container classDescription];
    NSString *key = nil;
    for (NSString *k in [containerDescription toManyRelationshipKeys]) {
        NSScriptClassDescription *d = [containerDescription classDescriptionForKey:k];
        if (!_insertionClassDescription || d == _insertionClassDescription || [[d className] isEqual:[_insertionClassDescription className]]) {
            key = k;
            break;
        }
    }
    if (!key) return;
    _evaluated[@"container"] = container;
    _evaluated[@"key"] = key;
    _evaluated[@"index"] = @(_unadjustedPosition == NSPositionBeginning ? 0 : -1);
}

/* (as Apple's: asking evaluates, the first time) */
- (void)_finchEvaluateOnce
{
    if (!_evaluated[@"evaluated"]) [self evaluate];
}

- (id)insertionContainer
{
    [self _finchEvaluateOnce];
    return _evaluated[@"container"];
}

/* (when evaluation finds nothing, the specified object's key when inserting beside it) */
- (NSString *)insertionKey
{
    [self _finchEvaluateOnce];
    NSString *key = _evaluated[@"key"];
    if (key) return key;
    return inserts_beside(_unadjustedPosition) ? [_specifier key] : nil;
}

- (NSInteger)insertionIndex
{
    [self _finchEvaluateOnce];
    return [_evaluated[@"index"] integerValue];
}

- (BOOL)insertionReplaces
{
    [self _finchEvaluateOnce];
    return [_evaluated[@"replaces"] boolValue];
}

- (NSString *)description
{
    static NSString *const positions[] = { @"after", @"before", @"at the beginning of", @"at the end of", @"replacing" };
    NSString *position = _unadjustedPosition < 5 ? positions[_unadjustedPosition] : @"<unrecognized position>";
    return [NSString stringWithFormat:@"<NSPositionalSpecifier: %@ %@>", position, _specifier];
}

@end

#undef _evaluated
