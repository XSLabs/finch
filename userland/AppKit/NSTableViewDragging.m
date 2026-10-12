/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Tables and outlines in drag and drop, as Apple's:
 *
 *  - As a source: a press on a row that then moves (vertically too, unless
 *    verticalMotionCanBeginDrag is off) drags the selected rows (or the pressed one)
 *    when the data source gives pasteboard writers for them
 *    (tableView:pasteboardWriterForRow:, outlineView:pasteboardWriterForItem:) or
 *    writes them itself (tableView:writeRowsWithIndexes:toPasteboard:,
 *    outlineView:writeItems:toPasteboard:). The data source hears the drag begin
 *    and end; the operation masks are setDraggingSourceOperationMask:forLocal:'s
 *    (everything within the app, nothing outside, until set).
 *  - As a destination (registered for the types): the pointer proposes a row and
 *    an operation (above a row near its top or bottom edge, on it in its middle;
 *    above the end past the last row), the data source validates and may retarget it
 *    (setDropRow:dropOperation:), and accepts the drop. Outlines propose an item and a
 *    child index instead (validateDrop:proposedItem:proposedChildIndex:,
 *    setDropItem:dropChildIndex:, acceptDrop:item:childIndex:). A line above the row,
 *    or an outline around it, shows where the drop would land.
 */
#import "AppKit_Finch.h"

@interface NSTableView (FinchDraggingHooks)
- (BOOL)_finchMaybeBeginDragWithEvent:(NSEvent *)event pressedRow:(NSInteger)row start:(NSPoint)start;
@end

static char drop_row_key, drop_op_key, local_mask_key, external_mask_key, feedback_key, drag_rows_key;

/* Where a drop would land, over the rows. */
@interface _FinchDropFeedbackView : NSView {
@public
    NSRect _mark;
    BOOL _line;
}
@end

@implementation _FinchDropFeedbackView
- (NSView *)hitTest:(NSPoint)point { return nil; }
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)r
{
    if (NSIsEmptyRect(_mark) && !_line)
        return;
    NSColor *c = [NSColor controlAccentColor];
    [c set];
    if (_line) {
        NSRect bar = NSMakeRect(NSMinX(_mark) + 4, NSMinY(_mark) - 1, NSWidth(_mark) - 8, 2);
        NSRectFill(bar);
        NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(NSMinX(bar) - 3, NSMidY(bar) - 3, 6, 6)];
        [dot setLineWidth:1.5];
        [dot stroke];
    } else {
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(_mark, 1.5, 1.5) xRadius:4 yRadius:4];
        [p setLineWidth:2];
        [p stroke];
    }
}
@end

@implementation NSTableView (FinchDragging)

#pragma mark Source

- (void)setDraggingSourceOperationMask:(NSDragOperation)mask forLocal:(BOOL)isLocal
{
    objc_setAssociatedObject(self, isLocal ? &local_mask_key : &external_mask_key, @(mask), OBJC_ASSOCIATION_RETAIN);
}

- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context
{
    BOOL local = context == NSDraggingContextWithinApplication;
    NSNumber *n = objc_getAssociatedObject(self, local ? &local_mask_key : &external_mask_key);
    return n ? [n unsignedIntegerValue] : (local ? NSDragOperationEvery : NSDragOperationNone);
}

- (NSDragOperation)draggingSourceOperationMaskForLocal:(BOOL)isLocal
{
    NSNumber *n = objc_getAssociatedObject(self, isLocal ? &local_mask_key : &external_mask_key);
    return n ? [n unsignedIntegerValue] : (isLocal ? NSDragOperationEvery : NSDragOperationNone);
}

- (BOOL)canDragRowsWithIndexes:(NSIndexSet *)rowIndexes atPoint:(NSPoint)mouseDownPoint { return YES; }

/* The writer for a row (an outline's for its item). */
- (id<NSPasteboardWriting>)_finchWriterForRow:(NSInteger)row
{
    id ds = [self dataSource];
    if ([ds respondsToSelector:@selector(tableView:pasteboardWriterForRow:)])
        return [ds tableView:self pasteboardWriterForRow:row];
    return nil;
}

- (BOOL)_finchWritesRows
{
    id ds = [self dataSource];
    return [ds respondsToSelector:@selector(tableView:pasteboardWriterForRow:)] ||
           [ds respondsToSelector:@selector(tableView:writeRowsWithIndexes:toPasteboard:)];
}

- (BOOL)_finchWriteRowsLegacy:(NSIndexSet *)rows toPasteboard:(NSPasteboard *)pb
{
    id ds = [self dataSource];
    return [ds respondsToSelector:@selector(tableView:writeRowsWithIndexes:toPasteboard:)] &&
           [ds tableView:self writeRowsWithIndexes:rows toPasteboard:pb];
}

- (void)_finchTellDragBegan:(NSDraggingSession *)session at:(NSPoint)p rows:(NSIndexSet *)rows
{
    id ds = [self dataSource];
    if ([ds respondsToSelector:@selector(tableView:draggingSession:willBeginAtPoint:forRowIndexes:)])
        [ds tableView:self draggingSession:session willBeginAtPoint:p forRowIndexes:rows];
}

- (void)_finchTellDragEnded:(NSDraggingSession *)session at:(NSPoint)p operation:(NSDragOperation)op
{
    id ds = [self dataSource];
    if ([ds respondsToSelector:@selector(tableView:draggingSession:endedAtPoint:operation:)])
        [ds tableView:self draggingSession:session endedAtPoint:p operation:op];
}

/* A row's picture, for its dragging item. */
- (NSImage *)_finchImageOfRow:(NSInteger)row
{
    NSRect r = [self rectOfRow:row];
    if (NSIsEmptyRect(r))
        return nil;
    NSBitmapImageRep *rep = [self bitmapImageRepForCachingDisplayInRect:r];
    [self cacheDisplayInRect:r toBitmapImageRep:rep];
    NSImage *image = [[[NSImage alloc] initWithSize:r.size] autorelease];
    [image addRepresentation:rep];
    return image;
}

/* Called from mouseDown:'s tracking: a drag of the rows, if they can be dragged and the
   mouse has moved far enough (and, unless vertical motion may, sideways). */
- (BOOL)_finchMaybeBeginDragWithEvent:(NSEvent *)event pressedRow:(NSInteger)row start:(NSPoint)start
{
    if (row < 0 || ![self _finchWritesRows])
        return NO;
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    CGFloat dx = fabs(p.x - start.x), dy = fabs(p.y - start.y);
    if (hypot(dx, dy) < 4 || (![self verticalMotionCanBeginDrag] && dy > dx))
        return NO;
    NSIndexSet *rows = [[self selectedRowIndexes] containsIndex:(NSUInteger)row] ? [self selectedRowIndexes]
                                                                                  : [NSIndexSet indexSetWithIndex:(NSUInteger)row];
    if (![self canDragRowsWithIndexes:rows atPoint:start])
        return NO;
    id del = [self delegate];
    SEL can = @selector(tableView:canDragRowsWithIndexes:atPoint:);
    if ([[self dataSource] respondsToSelector:can] &&
        !((BOOL (*)(id, SEL, id, id, NSPoint))objc_msgSend)([self dataSource], can, self, rows, start))
        return NO;
    (void)del;
    NSMutableArray *items = [NSMutableArray array];
    for (NSUInteger r = [rows firstIndex]; r != NSNotFound; r = [rows indexGreaterThanIndex:r]) {
        id writer = [self _finchWriterForRow:(NSInteger)r];
        if (!writer)
            continue;
        NSDraggingItem *item = [[[NSDraggingItem alloc] initWithPasteboardWriter:writer] autorelease];
        NSRect frame = [self rectOfRow:(NSInteger)r];
        [item setDraggingFrame:frame contents:[self _finchImageOfRow:(NSInteger)r]];
        [items addObject:item];
    }
    if ([items count]) {
        objc_setAssociatedObject(self, &drag_rows_key, rows, OBJC_ASSOCIATION_RETAIN);
        [self beginDraggingSessionWithItems:items event:event source:(id<NSDraggingSource>)self];
        return YES;
    }
    /* the older way: the data source writes the drag pasteboard */
    NSPasteboard *pb = [NSPasteboard pasteboardWithName:NSPasteboardNameDrag];
    [pb clearContents];
    if (![self _finchWriteRowsLegacy:rows toPasteboard:pb])
        return NO;
    NSPoint offset = NSZeroPoint;
    NSImage *image = [self dragImageForRowsWithIndexes:rows tableColumns:[self tableColumns] event:event offset:&offset];
    NSRect first = [self rectOfRow:(NSInteger)[rows firstIndex]];
    objc_setAssociatedObject(self, &drag_rows_key, rows, OBJC_ASSOCIATION_RETAIN);
    [self dragImage:image at:NSMakePoint(NSMinX(first), [self isFlipped] ? NSMaxY(first) : NSMinY(first)) offset:NSZeroSize
              event:event pasteboard:pb source:self slideBack:YES];
    return YES;
}

- (void)draggingSession:(NSDraggingSession *)session willBeginAtPoint:(NSPoint)screenPoint
{
    [self _finchTellDragBegan:session at:screenPoint rows:objc_getAssociatedObject(self, &drag_rows_key) ?: [NSIndexSet indexSet]];
}

- (void)draggingSession:(NSDraggingSession *)session endedAtPoint:(NSPoint)screenPoint operation:(NSDragOperation)operation
{
    [self _finchTellDragEnded:session at:screenPoint operation:operation];
    objc_setAssociatedObject(self, &drag_rows_key, nil, OBJC_ASSOCIATION_RETAIN);
}

#pragma mark Destination

- (void)setDropRow:(NSInteger)row dropOperation:(NSTableViewDropOperation)dropOperation
{
    objc_setAssociatedObject(self, &drop_row_key, @(row), OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(self, &drop_op_key, @(dropOperation), OBJC_ASSOCIATION_RETAIN);
}

- (NSInteger)_finchDropRow { return [objc_getAssociatedObject(self, &drop_row_key) integerValue]; }
- (NSTableViewDropOperation)_finchDropOperation { return [objc_getAssociatedObject(self, &drop_op_key) unsignedIntegerValue]; }

/* The row and operation a point proposes. */
- (void)_finchPropose:(NSPoint)p row:(NSInteger *)rowOut operation:(NSTableViewDropOperation *)opOut
{
    NSInteger row = [self rowAtPoint:p], n = [self numberOfRows];
    if (row < 0) {
        *rowOut = n;
        *opOut = NSTableViewDropAbove;
        return;
    }
    NSRect r = [self rectOfRow:row];
    CGFloat fromTop = [self isFlipped] ? p.y - NSMinY(r) : NSMaxY(r) - p.y;
    CGFloat edge = NSHeight(r) / 4;
    if (fromTop < edge) {
        *rowOut = row;
        *opOut = NSTableViewDropAbove;
    } else if (fromTop > NSHeight(r) - edge) {
        *rowOut = row + 1;
        *opOut = NSTableViewDropAbove;
    } else {
        *rowOut = row;
        *opOut = NSTableViewDropOn;
    }
}

- (NSDragOperation)_finchValidate:(id<NSDraggingInfo>)info row:(NSInteger)row operation:(NSTableViewDropOperation)op
{
    id ds = [self dataSource];
    if (![ds respondsToSelector:@selector(tableView:validateDrop:proposedRow:proposedDropOperation:)])
        return NSDragOperationNone;
    return [ds tableView:self validateDrop:info proposedRow:row proposedDropOperation:op];
}

- (BOOL)_finchAccept:(id<NSDraggingInfo>)info
{
    id ds = [self dataSource];
    return [ds respondsToSelector:@selector(tableView:acceptDrop:row:dropOperation:)] &&
           [ds tableView:self acceptDrop:info row:[self _finchDropRow] dropOperation:[self _finchDropOperation]];
}

- (_FinchDropFeedbackView *)_finchFeedback
{
    _FinchDropFeedbackView *v = objc_getAssociatedObject(self, &feedback_key);
    if (!v) {
        v = [[[_FinchDropFeedbackView alloc] initWithFrame:[self bounds]] autorelease];
        [v setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        objc_setAssociatedObject(self, &feedback_key, v, OBJC_ASSOCIATION_RETAIN);
    }
    if ([v superview] != self)
        [self addSubview:v positioned:NSWindowAbove relativeTo:nil];
    [v setFrame:[self bounds]];
    return v;
}

- (void)_finchShowDropAt:(NSInteger)row operation:(NSTableViewDropOperation)op valid:(BOOL)valid
{
    _FinchDropFeedbackView *v = [self _finchFeedback];
    if (!valid || [self draggingDestinationFeedbackStyle] == NSTableViewDraggingDestinationFeedbackStyleNone) {
        v->_mark = NSZeroRect;
        v->_line = NO;
    } else if (op == NSTableViewDropOn && row >= 0 && row < [self numberOfRows]) {
        v->_mark = [self convertRect:[self rectOfRow:row] toView:v];
        v->_line = NO;
    } else {
        NSInteger n = [self numberOfRows];
        NSRect r = row < n ? [self rectOfRow:row] : (n ? [self rectOfRow:n - 1] : NSMakeRect(0, 0, NSWidth([self bounds]), 0));
        NSRect inV = [self convertRect:r toView:v];
        v->_mark = NSMakeRect(NSMinX(inV), row < n ? NSMinY(inV) : NSMaxY(inV), NSWidth(inV), 0);
        v->_line = YES;
    }
    [v setNeedsDisplay:YES];
}

- (void)_finchHideDrop
{
    _FinchDropFeedbackView *v = objc_getAssociatedObject(self, &feedback_key);
    [v removeFromSuperview];
}

- (NSDragOperation)_finchDropUpdate:(id<NSDraggingInfo>)info
{
    NSPoint p = [self convertPoint:[info draggingLocation] fromView:nil];
    NSInteger row;
    NSTableViewDropOperation op;
    [self _finchPropose:p row:&row operation:&op];
    [self setDropRow:row dropOperation:op];
    NSDragOperation result = [self _finchValidate:info row:row operation:op];
    [self _finchShowDropAt:[self _finchDropRow] operation:[self _finchDropOperation] valid:result != NSDragOperationNone];
    return result;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info { return [self _finchDropUpdate:info]; }
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info { return [self _finchDropUpdate:info]; }
- (void)draggingExited:(id<NSDraggingInfo>)info { [self _finchHideDrop]; }
- (void)draggingEnded:(id<NSDraggingInfo>)info { [self _finchHideDrop]; }
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)info { return YES; }

- (BOOL)performDragOperation:(id<NSDraggingInfo>)info
{
    [self _finchHideDrop];
    return [self _finchAccept:info];
}

- (void)concludeDragOperation:(id<NSDraggingInfo>)info { [self _finchHideDrop]; }

@end

#pragma mark - Outlines

static char drop_item_key, drop_child_key;

@implementation NSOutlineView (FinchDragging)

- (id<NSPasteboardWriting>)_finchWriterForRow:(NSInteger)row
{
    id ds = [self dataSource];
    if ([ds respondsToSelector:@selector(outlineView:pasteboardWriterForItem:)])
        return [ds outlineView:self pasteboardWriterForItem:[self itemAtRow:row]];
    return nil;
}

- (BOOL)_finchWritesRows
{
    id ds = [self dataSource];
    return [ds respondsToSelector:@selector(outlineView:pasteboardWriterForItem:)] ||
           [ds respondsToSelector:@selector(outlineView:writeItems:toPasteboard:)];
}

- (NSArray *)_finchItemsOfRows:(NSIndexSet *)rows
{
    NSMutableArray *items = [NSMutableArray array];
    for (NSUInteger r = [rows firstIndex]; r != NSNotFound; r = [rows indexGreaterThanIndex:r]) {
        id item = [self itemAtRow:(NSInteger)r];
        if (item)
            [items addObject:item];
    }
    return items;
}

- (BOOL)_finchWriteRowsLegacy:(NSIndexSet *)rows toPasteboard:(NSPasteboard *)pb
{
    id ds = [self dataSource];
    return [ds respondsToSelector:@selector(outlineView:writeItems:toPasteboard:)] &&
           [ds outlineView:self writeItems:[self _finchItemsOfRows:rows] toPasteboard:pb];
}

- (void)_finchTellDragBegan:(NSDraggingSession *)session at:(NSPoint)p rows:(NSIndexSet *)rows
{
    id ds = [self dataSource];
    if ([ds respondsToSelector:@selector(outlineView:draggingSession:willBeginAtPoint:forItems:)])
        [ds outlineView:self draggingSession:session willBeginAtPoint:p forItems:[self _finchItemsOfRows:rows]];
}

- (void)_finchTellDragEnded:(NSDraggingSession *)session at:(NSPoint)p operation:(NSDragOperation)op
{
    id ds = [self dataSource];
    if ([ds respondsToSelector:@selector(outlineView:draggingSession:endedAtPoint:operation:)])
        [ds outlineView:self draggingSession:session endedAtPoint:p operation:op];
}

- (void)setDropItem:(id)item dropChildIndex:(NSInteger)index
{
    objc_setAssociatedObject(self, &drop_item_key, item, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(self, &drop_child_key, @(index), OBJC_ASSOCIATION_RETAIN);
    /* (shown as the table would: on the item's row, or above the child's) */
    if (index == NSOutlineViewDropOnItemIndex) {
        [self setDropRow:item ? [self rowForItem:item] : -1 dropOperation:NSTableViewDropOn];
        return;
    }
    NSInteger parentRow = item ? [self rowForItem:item] : -1;
    NSInteger n = [self numberOfRows], row = n;
    NSInteger seen = 0;
    for (NSInteger r = parentRow + 1; r < n; r++) {
        id it = [self itemAtRow:r];
        if ([self parentForItem:it] == item || (!item && [self levelForRow:r] == 0)) {
            if (seen++ == index) {
                row = r;
                break;
            }
        } else if ([self levelForRow:r] <= (item ? [self levelForRow:parentRow] : -1))
            break;
        row = r + 1;
    }
    [self setDropRow:row dropOperation:NSTableViewDropAbove];
}

/* A row and operation as an item and child index: on a row is on its item; above a row
   is before its item in its parent (or after the last top-level item, past the end). */
- (NSDragOperation)_finchValidate:(id<NSDraggingInfo>)info row:(NSInteger)row operation:(NSTableViewDropOperation)op
{
    id ds = [self dataSource];
    if (![ds respondsToSelector:@selector(outlineView:validateDrop:proposedItem:proposedChildIndex:)])
        return NSDragOperationNone;
    id item = nil;
    NSInteger child = NSOutlineViewDropOnItemIndex;
    NSInteger n = [self numberOfRows];
    if (op == NSTableViewDropOn && row < n)
        item = [self itemAtRow:row];
    else if (row < n) {
        id at = [self itemAtRow:row];
        item = [self parentForItem:at];
        child = [self childIndexForItem:at];
    } else {
        item = nil;
        child = [self numberOfChildrenOfItem:nil];
    }
    [self setDropItem:item dropChildIndex:child];
    return [ds outlineView:self validateDrop:info proposedItem:item proposedChildIndex:child];
}

- (BOOL)_finchAccept:(id<NSDraggingInfo>)info
{
    id ds = [self dataSource];
    return [ds respondsToSelector:@selector(outlineView:acceptDrop:item:childIndex:)] &&
           [ds outlineView:self acceptDrop:info item:objc_getAssociatedObject(self, &drop_item_key)
                childIndex:[objc_getAssociatedObject(self, &drop_child_key) integerValue]];
}

@end
