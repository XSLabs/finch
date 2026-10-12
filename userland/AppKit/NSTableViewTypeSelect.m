/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Type select in tables and outlines: typing selects the first row whose string
 * starts with what was typed. As measured on macOS 26.4 (tablesel probes):
 *   - Keys typed within about 1.2 seconds of each other (wall-clock, whatever the
 *     events' timestamps) add to the search; after that a key starts a new one.
 *   - Every visible column's string counts, row by row: the delegate's type select
 *     string for the column, else the cell's string (a view-based row's cell view's
 *     text field's). Matching ignores case and diacritics and is anchored at the start.
 *   - A new search starts after the selected row, wrapping (typing the same letter
 *     again steps through the matches); a growing one starts at the selected row.
 *     No match leaves the selection as it was.
 *   - The delegate may decline the event, give the strings, or do the search itself
 *     (from the row it starts at "to" the row selected when the search began, or 0).
 */
#import "NSTableView_Finch.h"
#import <objc/runtime.h>

@interface _FinchTypeSelect : NSObject {
@public
    NSMutableString *_search;
    NSTimer *_timer;
    NSInteger _origin; /* the row selected when the search began (0 if none) */
}
@end

@implementation _FinchTypeSelect
- (void)dealloc
{
    [_timer invalidate];
    [_timer release];
    [_search release];
    [super dealloc];
}
- (void)_finchEnd:(NSTimer *)timer
{
    [_search setString:@""];
    [_timer release];
    _timer = nil;
}
@end

static char type_select_key;
static const NSTimeInterval type_select_timeout = 1.2;

@implementation NSTableView (FinchTypeSelect)

- (_FinchTypeSelect *)_finchTypeSelectState
{
    _FinchTypeSelect *s = objc_getAssociatedObject(self, &type_select_key);
    if (!s) {
        s = [[[_FinchTypeSelect alloc] init] autorelease];
        s->_search = [[NSMutableString alloc] init];
        objc_setAssociatedObject(self, &type_select_key, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return s;
}

/* The string a column gives a row to match. */
- (NSString *)_finchTypeSelectStringForColumn:(NSTableColumn *)column row:(NSInteger)row
{
    id d = [self delegate];
    if ([self isKindOfClass:[NSOutlineView class]]) {
        if ([d respondsToSelector:@selector(outlineView:typeSelectStringForTableColumn:item:)])
            return [d outlineView:(NSOutlineView *)self typeSelectStringForTableColumn:column
                             item:[(NSOutlineView *)self itemAtRow:row]];
    } else if ([d respondsToSelector:@selector(tableView:typeSelectStringForTableColumn:row:)]) {
        return [d tableView:self typeSelectStringForTableColumn:column row:row];
    }
    NSInteger c = [[self tableColumns] indexOfObjectIdenticalTo:column];
    if (c == NSNotFound)
        return nil;
    NSView *v = [self viewAtColumn:c row:row makeIfNecessary:YES];
    if (v) {
        if ([v isKindOfClass:[NSTableCellView class]])
            return [[(NSTableCellView *)v textField] stringValue];
        if ([v isKindOfClass:[NSControl class]])
            return [(NSControl *)v stringValue];
        return nil;
    }
    return [[self preparedCellAtColumn:c row:row] stringValue];
}

- (BOOL)_finchTypeSelectRow:(NSInteger)row matches:(NSString *)search
{
    for (NSTableColumn *col in [self tableColumns]) {
        if ([col isHidden])
            continue;
        NSString *s = [self _finchTypeSelectStringForColumn:col row:row];
        if ([s isKindOfClass:[NSString class]] &&
            [s rangeOfString:search options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSAnchoredSearch]
                    .location != NSNotFound)
            return YES;
    }
    return NO;
}

/* The first matching row from start, wrapping, before coming back round; -1 if none
   (the delegate is given the end it was given on Apple's). */
- (NSInteger)_finchTypeSelectMatchFrom:(NSInteger)start to:(NSInteger)end search:(NSString *)search
{
    id d = [self delegate];
    if ([self isKindOfClass:[NSOutlineView class]]) {
        NSOutlineView *o = (NSOutlineView *)self;
        if ([d respondsToSelector:@selector(outlineView:nextTypeSelectMatchFromItem:toItem:forString:)]) {
            id item = [d outlineView:o nextTypeSelectMatchFromItem:[o itemAtRow:start] toItem:[o itemAtRow:end] forString:search];
            return item ? [o rowForItem:item] : -1;
        }
    } else if ([d respondsToSelector:@selector(tableView:nextTypeSelectMatchFromRow:toRow:forString:)]) {
        return [d tableView:self nextTypeSelectMatchFromRow:start toRow:end forString:search];
    }
    NSInteger n = [self numberOfRows];
    for (NSInteger i = 0; i < n; i++) {
        NSInteger r = (start + i) % n;
        if ([self _finchTypeSelectRow:r matches:search])
            return r;
    }
    return -1;
}

/* A key typed into the table: YES if type select took it. */
- (BOOL)_finchTypeSelect:(NSEvent *)event
{
    if (![self allowsTypeSelect] || ![self numberOfRows])
        return NO;
    if ([event modifierFlags] & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagFunction))
        return NO;
    NSString *chars = [event characters];
    if (![chars length])
        return NO;
    for (NSUInteger i = 0; i < [chars length]; i++) {
        unichar c = [chars characterAtIndex:i];
        if (c < 0x20 || c == 0x7f || (c >= 0xf700 && c <= 0xf8ff))
            return NO;
    }
    _FinchTypeSelect *state = [self _finchTypeSelectState];
    BOOL growing = [state->_search length] > 0;
    if (!growing && [chars isEqualToString:@" "])
        return NO;
    id d = [self delegate];
    if ([self isKindOfClass:[NSOutlineView class]]) {
        if ([d respondsToSelector:@selector(outlineView:shouldTypeSelectForEvent:withCurrentSearchString:)] &&
            ![d outlineView:(NSOutlineView *)self shouldTypeSelectForEvent:event
                withCurrentSearchString:growing ? state->_search : nil])
            return NO;
    } else if ([d respondsToSelector:@selector(tableView:shouldTypeSelectForEvent:withCurrentSearchString:)] &&
               ![d tableView:self shouldTypeSelectForEvent:event withCurrentSearchString:growing ? state->_search : nil]) {
        return NO;
    }
    if (!growing)
        state->_origin = MAX([self selectedRow], 0);
    [state->_search appendString:chars];
    [state->_timer invalidate];
    [state->_timer release];
    state->_timer = [[NSTimer timerWithTimeInterval:type_select_timeout target:state selector:@selector(_finchEnd:)
                                           userInfo:nil repeats:NO] retain];
    [[NSRunLoop currentRunLoop] addTimer:state->_timer forMode:NSRunLoopCommonModes];

    NSInteger n = [self numberOfRows], sel = [self selectedRow];
    NSInteger start = sel < 0 ? 0 : (growing ? sel : (sel + 1) % n);
    NSInteger row = [self _finchTypeSelectMatchFrom:start to:state->_origin search:state->_search];
    if (row < 0 || row >= n || row == sel)
        return YES;
    [self selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    [self scrollRowToVisible:row];
    return YES;
}

@end
