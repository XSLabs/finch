/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Smaller methods AppKit adds to other classes, and ones its classes implement that apps'
 * subclasses call through to super (found by matching the selectors apps reference
 * against Apple's AppKit): NSArray's kind filter, attribute subsets of attributed
 * strings, the window's undo actions, the preferred font names, a colour from a
 * pasteboard, the old NSTextInput methods, the zoom cursors, the window's cancel key, and
 * NSAppleScript's styled source.
 */
#import <AppKit/AppKit.h>

@implementation NSArray (NSAppKitAdditions)

/* SPI: the elements that are kinds of `cls`, in order. */
- (NSArray *)subarrayWithObjectsOfKind:(Class)cls
{
    NSMutableArray *a = [NSMutableArray array];
    for (id o in self)
        if ([o isKindOfClass:cls])
            [a addObject:o];
    return a;
}

@end

@implementation NSMutableArray (NSAppKitAdditions)

/* SPI: insert an array's elements at an index (out of range raises, as inserting does). */
- (void)insertObjectsFromArray:(NSArray *)array atIndex:(NSUInteger)index
{
    [self insertObjects:array atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(index, array.count)]];
}

@end

@implementation NSAttributedString (NSAppKitAttributeSubsets)

/* The attributes at the range's start that belong to characters (font, colours, kerning,
   lines, shadow, ...) or to paragraphs. */
static NSDictionary *
subset(NSAttributedString *s, NSRange range, NSSet *keys)
{
    if (!s.length)
        return @{};
    NSUInteger at = range.location < s.length ? range.location : s.length - 1;
    NSDictionary *all = [s attributesAtIndex:at effectiveRange:NULL];
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSString *k in all)
        if ([keys containsObject:k])
            d[k] = all[k];
    return d;
}

- (NSDictionary<NSAttributedStringKey, id> *)fontAttributesInRange:(NSRange)range
{
    static NSSet *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = [[NSSet alloc] initWithObjects:NSFontAttributeName, NSForegroundColorAttributeName, NSBackgroundColorAttributeName,
                                              NSKernAttributeName, NSLigatureAttributeName, NSObliquenessAttributeName,
                                              NSShadowAttributeName, NSStrokeWidthAttributeName, NSStrokeColorAttributeName,
                                              NSSuperscriptAttributeName, NSBaselineOffsetAttributeName, NSUnderlineStyleAttributeName,
                                              NSUnderlineColorAttributeName, NSStrikethroughStyleAttributeName,
                                              NSStrikethroughColorAttributeName, NSExpansionAttributeName, nil];
    });
    return subset(self, range, keys);
}

- (NSDictionary<NSAttributedStringKey, id> *)rulerAttributesInRange:(NSRange)range
{
    return subset(self, range, [NSSet setWithObject:NSParagraphStyleAttributeName]);
}

@end

@implementation NSWindow (NSUndoActions)

/* Edit > Undo and Redo, when nothing nearer the first responder takes them */
- (void)undo:(id)sender { [[self undoManager] undo]; }
- (void)redo:(id)sender { [[self undoManager] redo]; }

@end

static NSArray *preferred_font_names;

@implementation NSFont (NSPreferredFonts)

+ (NSArray<NSString *> *)preferredFontNames
{
    return preferred_font_names ?: @[@"Helvetica", @".AppleSystemUIFont", @"Symbol"];
}

+ (void)setPreferredFontNames:(NSArray<NSString *> *)names
{
    NSArray *old = preferred_font_names;
    preferred_font_names = [names copy];
    [old release];
}

@end

@implementation NSColor (NSPasteboardColor)

+ (NSColor *)colorFromPasteboard:(NSPasteboard *)pasteboard
{
    NSData *d = [pasteboard dataForType:NSPasteboardTypeColor];
    if (!d)
        return nil;
    NSKeyedUnarchiver *u = [[[NSKeyedUnarchiver alloc] initForReadingFromData:d error:NULL] autorelease];
    u.requiresSecureCoding = NO;
    id c = [u decodeObjectForKey:NSKeyedArchiveRootObjectKey];
    if (!c)
        c = [NSUnarchiver unarchiveObjectWithData:d];
    return [c isKindOfClass:[NSColor class]] ? c : nil;
}

@end

@implementation NSTextView (NSTextInputCompatibility)

- (NSRect)firstRectForCharacterRange:(NSRange)range { return [self firstRectForCharacterRange:range actualRange:NULL]; }
- (NSInteger)conversationIdentifier { return (NSInteger)self; }

@end

/* Delegate methods Apple's classes implement for themselves, so subclasses' calls to
   super land somewhere. */
@implementation NSDocument (NSMenuDelegateCompatibility)
- (void)menuNeedsUpdate:(NSMenu *)menu
{
}
@end

@implementation NSTableView (NSEditingCompatibility)
- (void)controlTextDidEndEditing:(NSNotification *)notification
{
}
- (void)draggedImage:(NSImage *)image endedAt:(NSPoint)point operation:(NSDragOperation)operation
{
}
@end

@implementation NSSplitViewController (NSSplitViewDelegateCompatibility)
- (void)splitViewDidResizeSubviews:(NSNotification *)notification
{
}
@end

/* SPI: the zoom cursors (a magnifier with a plus or a minus, its lens at the hot spot):
   Finch's own drawing, at Apple's size. */
static NSCursor *
zoom_cursor(BOOL zoomIn)
{
    NSImage *im = [NSImage imageWithSize:NSMakeSize(28, 26) flipped:YES drawingHandler:^BOOL(NSRect r) {
        NSBezierPath *lens = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(5, 4, 14, 14)];
        NSBezierPath *handle = [NSBezierPath bezierPath];
        [handle moveToPoint:NSMakePoint(17, 16)];
        [handle lineToPoint:NSMakePoint(24, 23)];
        handle.lineCapStyle = NSLineCapStyleRound;
        /* a white halo, then ink */
        [[NSColor whiteColor] setStroke];
        lens.lineWidth = handle.lineWidth = 4.5;
        [lens stroke];
        [handle stroke];
        [[NSColor whiteColor] setFill];
        [lens fill];
        [[NSColor colorWithWhite:0.17 alpha:1] setStroke];
        lens.lineWidth = 2;
        handle.lineWidth = 2.5;
        [lens stroke];
        [handle stroke];
        NSBezierPath *mark = [NSBezierPath bezierPath];
        mark.lineWidth = 1.75;
        [mark moveToPoint:NSMakePoint(8.5, 11)];
        [mark lineToPoint:NSMakePoint(15.5, 11)];
        if (zoomIn) {
            [mark moveToPoint:NSMakePoint(12, 7.5)];
            [mark lineToPoint:NSMakePoint(12, 14.5)];
        }
        [mark stroke];
        return YES;
    }];
    return [[[NSCursor alloc] initWithImage:im hotSpot:NSMakePoint(12, 11)] autorelease];
}

@implementation NSCursor (NSZoomCursors)

+ (NSCursor *)_zoomInCursor
{
    static NSCursor *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [zoom_cursor(YES) retain]; });
    return c;
}

+ (NSCursor *)_zoomOutCursor
{
    static NSCursor *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [zoom_cursor(NO) retain]; });
    return c;
}

@end

@implementation NSWindow (NSCancelKey)

/* SPI: Escape's work: offered as a key equivalent first (a Cancel button takes it), then
   as cancelOperation: along the responder chain. */
- (void)_cancelKey:(id)sender
{
    NSEvent *esc = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0
                                windowNumber:[self windowNumber] context:nil characters:@"\e" charactersIgnoringModifiers:@"\e"
                                   isARepeat:NO keyCode:53];
    if ([self performKeyEquivalent:esc])
        return;
    NSResponder *r = [self firstResponder] ?: (NSResponder *)self;
    if (![r tryToPerform:@selector(cancelOperation:) with:sender])
        [self tryToPerform:@selector(cancelOperation:) with:sender];
}

@end

/* NSAppleScript's styled source, from Foundation's (which has the OSA calls) */
@interface NSAppleScript (FinchRichText)
- (NSAttributedString *)_finchRichTextSource;
@end

@implementation NSAppleScript (NSExtensions)
- (NSAttributedString *)richTextSource
{
    return [self respondsToSelector:@selector(_finchRichTextSource)] ? [self _finchRichTextSource] : nil;
}
@end
