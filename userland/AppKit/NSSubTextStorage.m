/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSSubTextStorage (SPI): a text storage that is a range of another, as Script Editor
 * uses it. Reads come from the parent within the range; edits go to the parent, and the
 * range grows or shrinks by what an edit changed. Also here, AppKit's small private
 * exports apps import: the accent colour calls, the localized width factor, the Help
 * book name and the tab view's floating-cell symbol.
 */
#import <AppKit/AppKit.h>

@interface NSSubTextStorage : NSTextStorage
- (instancetype)initWithTextStorage:(NSTextStorage *)storage range:(NSRange)range;
@property (retain) NSTextStorage *textStorage;
@property (readonly) NSRange range;
@end

@implementation NSSubTextStorage {
    NSTextStorage *_parent;
    NSRange _range;
}

- (instancetype)initWithTextStorage:(NSTextStorage *)storage range:(NSRange)range
{
    if ((self = [super init])) {
        _parent = [storage retain];
        NSUInteger len = [[storage string] length];
        _range.location = MIN(range.location, len);
        _range.length = MIN(range.length, len - _range.location);
    }
    return self;
}

- (instancetype)initWithString:(NSString *)string
{
    return [self initWithString:string attributes:nil];
}

- (instancetype)initWithString:(NSString *)string attributes:(NSDictionary *)attrs
{
    NSTextStorage *parent = [[[NSTextStorage alloc] initWithString:string ?: @"" attributes:attrs] autorelease];
    return [self initWithTextStorage:parent range:NSMakeRange(0, [string length])];
}

- (instancetype)initWithAttributedString:(NSAttributedString *)string
{
    NSTextStorage *parent = [[[NSTextStorage alloc] initWithAttributedString:string ?: [[NSAttributedString new] autorelease]] autorelease];
    return [self initWithTextStorage:parent range:NSMakeRange(0, [string length])];
}

- (void)dealloc
{
    [_parent release];
    [super dealloc];
}

- (NSTextStorage *)textStorage { return _parent; }

- (void)setTextStorage:(NSTextStorage *)storage
{
    if (storage == _parent)
        return;
    [_parent release];
    _parent = [storage retain];
    _range = NSMakeRange(0, [[storage string] length]);
}

- (NSRange)range { return _range; }

- (NSString *)string
{
    return [[_parent string] substringWithRange:_range];
}

- (NSDictionary *)attributesAtIndex:(NSUInteger)index effectiveRange:(NSRangePointer)effective
{
    NSRange r;
    NSDictionary *a = [_parent attributesAtIndex:_range.location + index effectiveRange:&r];
    if (effective) {
        NSRange in = NSIntersectionRange(r, _range);
        *effective = NSMakeRange(in.location - _range.location, in.length);
    }
    return a;
}

- (void)replaceCharactersInRange:(NSRange)range withString:(NSString *)string
{
    NSUInteger before = [[_parent string] length];
    [_parent replaceCharactersInRange:NSMakeRange(_range.location + range.location, range.length) withString:string];
    NSInteger delta = (NSInteger)[[_parent string] length] - (NSInteger)before;
    _range.length = (NSUInteger)((NSInteger)_range.length + delta);
    [self edited:NSTextStorageEditedCharacters range:range changeInLength:delta];
}

- (void)setAttributes:(NSDictionary *)attrs range:(NSRange)range
{
    [_parent setAttributes:attrs range:NSMakeRange(_range.location + range.location, range.length)];
    [self edited:NSTextStorageEditedAttributes range:range changeInLength:0];
}

- (NSTextStorage *)_subtextStorageFromRange:(NSRange)range
{
    return [[[NSSubTextStorage alloc] initWithTextStorage:_parent
                                                   range:NSMakeRange(_range.location + range.location, range.length)] autorelease];
}

- (id)copyWithZone:(NSZone *)zone
{
    return [[NSAttributedString allocWithZone:zone] initWithAttributedString:self];
}

- (Class)classForCoder { return [NSTextStorage class]; }

@end

/* The accent colour the user chose (Apple's numbers; -1 is the system's own) and the one
   in effect. */
__attribute__((visibility("default"))) NSInteger
NSColorGetUserAccentColor(void)
{
    return -1;
}

__attribute__((visibility("default"))) NSColor *
NSColorEffectiveUserAccentColor(void)
{
    return [NSColor controlAccentColor];
}

/* (how much wider the localization's text runs than English: none) */
__attribute__((visibility("default"))) CGFloat
_NSLocalizedUserInterfaceWidthFactor(void)
{
    return 1;
}

__attribute__((visibility("default"))) NSString *const NSHelpManagerSystemBook = @"com.apple.machelp";

/* (an empty word in Apple's AppKit, which Audio MIDI Setup imports) */
__attribute__((visibility("default"))) void *_NSTabViewFloatingCell = NULL;
