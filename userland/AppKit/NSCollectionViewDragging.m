/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Collection views in drag and drop, as Apple's: a press on an item that then moves
 * drags the selected items (or the pressed one) when the delegate allows it and gives
 * pasteboard writers (collectionView:pasteboardWriterForItemAtIndexPath:, or the older
 * index-set and writeItems...:toPasteboard: forms); as a destination, the pointer
 * proposes an index path and an operation (on an item in its middle, before an item
 * near its edges, after the last past the end), the delegate validates it and accepts
 * the drop, and a bar or an outline shows where it would land.
 */
#import "AppKit_Finch.h"

static char press_key, local_mask_key, external_mask_key, drag_paths_key, drop_path_key, drop_op_key, feedback_key;

/* Where a drop would land. */
@interface _FinchCollectionDropView : NSView {
@public
    NSRect _mark;
    BOOL _bar;
}
@end
@implementation _FinchCollectionDropView
- (NSView *)hitTest:(NSPoint)point { return nil; }
- (void)drawRect:(NSRect)r
{
    if (NSIsEmptyRect(_mark) && !_bar)
        return;
    [[NSColor controlAccentColor] set];
    if (_bar)
        NSRectFill(_mark);
    else {
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(_mark, 1.5, 1.5) xRadius:6 yRadius:6];
        [p setLineWidth:2];
        [p stroke];
    }
}
@end

/* (mouseDown: notes where a drag would start from) */
void
FinchCollectionViewNoteMouseDown(NSCollectionView *cv, NSEvent *event)
{
    NSPoint p = [cv convertPoint:[event locationInWindow] fromView:nil];
    NSIndexPath *hit = [cv indexPathForItemAtPoint:p];
    objc_setAssociatedObject(cv, &press_key, hit ? @[ hit, [NSValue valueWithPoint:p] ] : nil, OBJC_ASSOCIATION_RETAIN);
}

@implementation NSCollectionView (FinchDragging)

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

static NSIndexSet *
indexes_of(NSSet<NSIndexPath *> *paths)
{
    NSMutableIndexSet *s = [NSMutableIndexSet indexSet];
    for (NSIndexPath *p in paths)
        [s addIndex:(NSUInteger)[p item]];
    return s;
}

/* The items' frames drawn into one image (offset: its corner from the event's point). */
- (NSImage *)draggingImageForItemsAtIndexPaths:(NSSet<NSIndexPath *> *)paths withEvent:(NSEvent *)event offset:(NSPointPointer)dragImageOffset
{
    NSRect r = NSZeroRect;
    for (NSIndexPath *p in paths)
        r = NSUnionRect(r, [[self layoutAttributesForItemAtIndexPath:p] frame]);
    if (dragImageOffset)
        *dragImageOffset = NSZeroPoint;
    if (NSIsEmptyRect(r))
        return nil;
    NSBitmapImageRep *rep = [self bitmapImageRepForCachingDisplayInRect:r];
    [self cacheDisplayInRect:r toBitmapImageRep:rep];
    NSImage *image = [[[NSImage alloc] initWithSize:r.size] autorelease];
    [image addRepresentation:rep];
    return image;
}

- (NSImage *)draggingImageForItemsAtIndexes:(NSIndexSet *)indexes withEvent:(NSEvent *)event offset:(NSPointPointer)dragImageOffset
{
    NSMutableSet *paths = [NSMutableSet set];
    [indexes enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) { [paths addObject:[NSIndexPath indexPathForItem:(NSInteger)i inSection:0]]; }];
    return [self draggingImageForItemsAtIndexPaths:paths withEvent:event offset:dragImageOffset];
}

- (NSImage *)_finchImageOfItem:(NSIndexPath *)path
{
    NSPoint offset;
    NSEvent *none = nil;
    return [self draggingImageForItemsAtIndexPaths:[NSSet setWithObject:path] withEvent:none offset:&offset];
}

- (void)mouseDragged:(NSEvent *)event
{
    NSArray *press = objc_getAssociatedObject(self, &press_key);
    if (!press)
        return;
    NSIndexPath *hit = press[0];
    NSPoint start = [press[1] pointValue], p = [self convertPoint:[event locationInWindow] fromView:nil];
    if (hypot(p.x - start.x, p.y - start.y) < 4)
        return;
    objc_setAssociatedObject(self, &press_key, nil, OBJC_ASSOCIATION_RETAIN);
    id d = [self delegate];
    NSSet *selected = [self selectionIndexPaths];
    NSSet *paths = [selected containsObject:hit] ? selected : [NSSet setWithObject:hit];
    if ([d respondsToSelector:@selector(collectionView:canDragItemsAtIndexPaths:withEvent:)]) {
        if (![d collectionView:self canDragItemsAtIndexPaths:paths withEvent:event])
            return;
    } else if ([d respondsToSelector:@selector(collectionView:canDragItemsAtIndexes:withEvent:)]) {
        if (![d collectionView:self canDragItemsAtIndexes:indexes_of(paths) withEvent:event])
            return;
    } else
        return;
    NSMutableArray *items = [NSMutableArray array];
    NSArray *ordered = [[paths allObjects] sortedArrayUsingSelector:@selector(compare:)];
    for (NSIndexPath *ip in ordered) {
        id<NSPasteboardWriting> writer = nil;
        if ([d respondsToSelector:@selector(collectionView:pasteboardWriterForItemAtIndexPath:)])
            writer = [d collectionView:self pasteboardWriterForItemAtIndexPath:ip];
        else if ([d respondsToSelector:@selector(collectionView:pasteboardWriterForItemAtIndex:)])
            writer = [d collectionView:self pasteboardWriterForItemAtIndex:(NSUInteger)[ip item]];
        if (!writer)
            continue;
        NSDraggingItem *item = [[[NSDraggingItem alloc] initWithPasteboardWriter:writer] autorelease];
        [item setDraggingFrame:[[self layoutAttributesForItemAtIndexPath:ip] frame] contents:[self _finchImageOfItem:ip]];
        [items addObject:item];
    }
    objc_setAssociatedObject(self, &drag_paths_key, paths, OBJC_ASSOCIATION_RETAIN);
    if ([items count]) {
        [self beginDraggingSessionWithItems:items event:event source:(id<NSDraggingSource>)self];
        return;
    }
    NSPasteboard *pb = [NSPasteboard pasteboardWithName:NSPasteboardNameDrag];
    [pb clearContents];
    BOOL wrote = [d respondsToSelector:@selector(collectionView:writeItemsAtIndexPaths:toPasteboard:)]
                     ? [d collectionView:self writeItemsAtIndexPaths:paths toPasteboard:pb]
                 : [d respondsToSelector:@selector(collectionView:writeItemsAtIndexes:toPasteboard:)]
                     ? [d collectionView:self writeItemsAtIndexes:indexes_of(paths) toPasteboard:pb]
                     : NO;
    if (!wrote)
        return;
    NSRect first = [[self layoutAttributesForItemAtIndexPath:ordered[0]] frame];
    NSPoint offset;
    [self dragImage:[self draggingImageForItemsAtIndexPaths:paths withEvent:event offset:&offset]
                 at:NSMakePoint(NSMinX(first), [self isFlipped] ? NSMaxY(first) : NSMinY(first)) offset:NSZeroSize event:event pasteboard:pb
             source:self slideBack:YES];
}

- (void)draggingSession:(NSDraggingSession *)session willBeginAtPoint:(NSPoint)screenPoint
{
    id d = [self delegate];
    NSSet *paths = objc_getAssociatedObject(self, &drag_paths_key) ?: [NSSet set];
    if ([d respondsToSelector:@selector(collectionView:draggingSession:willBeginAtPoint:forItemsAtIndexPaths:)])
        [d collectionView:self draggingSession:session willBeginAtPoint:screenPoint forItemsAtIndexPaths:paths];
    else if ([d respondsToSelector:@selector(collectionView:draggingSession:willBeginAtPoint:forItemsAtIndexes:)])
        [d collectionView:self draggingSession:session willBeginAtPoint:screenPoint forItemsAtIndexes:indexes_of(paths)];
}

- (void)draggingSession:(NSDraggingSession *)session endedAtPoint:(NSPoint)screenPoint operation:(NSDragOperation)operation
{
    id d = [self delegate];
    if ([d respondsToSelector:@selector(collectionView:draggingSession:endedAtPoint:dragOperation:)])
        [d collectionView:self draggingSession:session endedAtPoint:screenPoint dragOperation:operation];
    objc_setAssociatedObject(self, &drag_paths_key, nil, OBJC_ASSOCIATION_RETAIN);
}

#pragma mark Destination

/* The index path and operation a point proposes. */
- (void)_finchPropose:(NSPoint)p path:(NSIndexPath **)pathOut operation:(NSCollectionViewDropOperation *)opOut
{
    NSIndexPath *hit = [self indexPathForItemAtPoint:p];
    if (hit) {
        NSRect f = [[self layoutAttributesForItemAtIndexPath:hit] frame];
        CGFloat edge = NSWidth(f) / 4;
        if (p.x < NSMinX(f) + edge) {
            *pathOut = hit;
            *opOut = NSCollectionViewDropBefore;
        } else if (p.x > NSMaxX(f) - edge) {
            *pathOut = [NSIndexPath indexPathForItem:[hit item] + 1 inSection:[hit section]];
            *opOut = NSCollectionViewDropBefore;
        } else {
            *pathOut = hit;
            *opOut = NSCollectionViewDropOn;
        }
        return;
    }
    NSInteger sections = [self numberOfSections], last = sections > 0 ? sections - 1 : 0;
    *pathOut = [NSIndexPath indexPathForItem:sections > 0 ? [self numberOfItemsInSection:last] : 0 inSection:last];
    *opOut = NSCollectionViewDropBefore;
}

- (_FinchCollectionDropView *)_finchDropView
{
    _FinchCollectionDropView *v = objc_getAssociatedObject(self, &feedback_key);
    if (!v) {
        v = [[[_FinchCollectionDropView alloc] initWithFrame:[self bounds]] autorelease];
        objc_setAssociatedObject(self, &feedback_key, v, OBJC_ASSOCIATION_RETAIN);
    }
    if ([v superview] != self)
        [self addSubview:v positioned:NSWindowAbove relativeTo:nil];
    [v setFrame:[self bounds]];
    return v;
}

- (void)_finchHideCollectionDrop { [objc_getAssociatedObject(self, &feedback_key) removeFromSuperview]; }

- (NSDragOperation)_finchCollectionDropUpdate:(id<NSDraggingInfo>)info
{
    NSPoint p = [self convertPoint:[info draggingLocation] fromView:nil];
    NSIndexPath *path = nil;
    NSCollectionViewDropOperation op = NSCollectionViewDropBefore;
    [self _finchPropose:p path:&path operation:&op];
    id d = [self delegate];
    NSDragOperation result = NSDragOperationNone;
    if ([d respondsToSelector:@selector(collectionView:validateDrop:proposedIndexPath:dropOperation:)])
        result = [d collectionView:self validateDrop:info proposedIndexPath:&path dropOperation:&op];
    else if ([d respondsToSelector:@selector(collectionView:validateDrop:proposedIndex:dropOperation:)]) {
        NSInteger index = [path item];
        result = [d collectionView:self validateDrop:info proposedIndex:&index dropOperation:&op];
        path = [NSIndexPath indexPathForItem:index inSection:0];
    }
    objc_setAssociatedObject(self, &drop_path_key, path, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(self, &drop_op_key, @(op), OBJC_ASSOCIATION_RETAIN);
    _FinchCollectionDropView *v = [self _finchDropView];
    if (result == NSDragOperationNone) {
        v->_mark = NSZeroRect;
        v->_bar = NO;
    } else if (op == NSCollectionViewDropOn) {
        v->_mark = [[self layoutAttributesForItemAtIndexPath:path] frame];
        v->_bar = NO;
    } else {
        NSInteger n = [self numberOfItemsInSection:[path section]];
        BOOL after = [path item] >= n;
        NSIndexPath *ref = after ? [NSIndexPath indexPathForItem:n - 1 inSection:[path section]] : path;
        NSRect f = n ? [[self layoutAttributesForItemAtIndexPath:ref] frame] : NSZeroRect;
        v->_mark = NSMakeRect((after ? NSMaxX(f) : NSMinX(f)) - 1.5, NSMinY(f), 3, NSHeight(f));
        v->_bar = YES;
    }
    [v setNeedsDisplay:YES];
    return result;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info { return [self _finchCollectionDropUpdate:info]; }
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info { return [self _finchCollectionDropUpdate:info]; }
- (void)draggingExited:(id<NSDraggingInfo>)info { [self _finchHideCollectionDrop]; }
- (void)draggingEnded:(id<NSDraggingInfo>)info { [self _finchHideCollectionDrop]; }
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)info { return YES; }

- (BOOL)performDragOperation:(id<NSDraggingInfo>)info
{
    [self _finchHideCollectionDrop];
    id d = [self delegate];
    NSIndexPath *path = objc_getAssociatedObject(self, &drop_path_key);
    NSCollectionViewDropOperation op = [objc_getAssociatedObject(self, &drop_op_key) integerValue];
    if (!path)
        return NO;
    if ([d respondsToSelector:@selector(collectionView:acceptDrop:indexPath:dropOperation:)])
        return [d collectionView:self acceptDrop:info indexPath:path dropOperation:op];
    if ([d respondsToSelector:@selector(collectionView:acceptDrop:index:dropOperation:)])
        return [d collectionView:self acceptDrop:info index:[path item] dropOperation:op];
    return NO;
}

- (void)concludeDragOperation:(id<NSDraggingInfo>)info { [self _finchHideCollectionDrop]; }

@end
