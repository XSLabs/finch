/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Drag and drop within an app. -beginDraggingSessionWithItems:event:source: writes the
 * items to the drag pasteboard and returns the session; on the next turn of the run
 * loop the session follows the mouse (in NSEventTrackingRunLoopMode) with the items'
 * images in a borderless window, finds the frontmost window under the pointer and in
 * it the deepest view registered for one of the pasteboard's types (or the window
 * itself), and gives it the NSDraggingDestination calls: draggingEntered:,
 * draggingUpdated:, draggingExited:, then prepareForDragOperation:,
 * performDragOperation: and concludeDragOperation: on release, with draggingEnded:
 * last. The source hears willBeginAtPoint:, movedToPoint: and endedAtPoint:operation:
 * and gives the operations allowed. The older dragImage:at:offset:... runs the same
 * drag synchronously and calls its source's older methods. Escape cancels.
 *
 * Drags between apps (through the window server) aren't here yet.
 */
#import "AppKit_Finch.h"

@class NSDraggingSession;

@interface NSWindow (FinchDraggedTypes)
- (NSArray<NSPasteboardType> *)_finchRegisteredDraggedTypes;
@end

/* What a destination is told about the drag (NSDraggingInfo). */
@interface _FinchDraggingInfo : NSObject <NSDraggingInfo> {
@public
    NSDraggingSession *_session;
    NSWindow *_destinationWindow;
    NSPoint _screenLocation;
    NSDragOperation _sourceMask;
    id _source;
    NSImage *_image;
    NSPoint _imageScreenOrigin;
    NSInteger _validItems;
    NSDraggingFormation _formation;
    BOOL _animates;
}
@end

@implementation NSDraggingSession {
@public
    NSDraggingFormation _formation;
    BOOL _animates;
    NSInteger _leader;
    NSPasteboard *_pasteboard;
    NSInteger _sequence;
    NSPoint _location;
    NSArray<NSDraggingItem *> *_items;
    id _source;
    NSView *_sourceView;
    NSPoint _startScreen;
    BOOL _legacy;
    NSImage *_legacyImage;
    NSPoint _legacyImageOrigin; /* screen */
}

- (instancetype)_finchInitWithItems:(NSArray<NSDraggingItem *> *)items location:(NSPoint)location
{
    static NSInteger sequence;
    if ((self = [super init])) {
        _items = [items copy];
        _location = location;
        _pasteboard = [[NSPasteboard pasteboardWithName:NSPasteboardNameDrag] retain];
        _sequence = ++sequence;
        _animates = YES;
    }
    return self;
}

- (void)dealloc
{
    [_items release];
    [_pasteboard release];
    [_source release];
    [_sourceView release];
    [_legacyImage release];
    [super dealloc];
}

- (NSDraggingFormation)draggingFormation { return _formation; }
- (void)setDraggingFormation:(NSDraggingFormation)formation { _formation = formation; }
- (BOOL)animatesToStartingPositionsOnCancelOrFail { return _animates; }
- (void)setAnimatesToStartingPositionsOnCancelOrFail:(BOOL)flag { _animates = flag; }
- (NSInteger)draggingLeaderIndex { return _leader; }
- (void)setDraggingLeaderIndex:(NSInteger)index { _leader = index; }
- (NSPasteboard *)draggingPasteboard { return _pasteboard; }
- (NSInteger)draggingSequenceNumber { return _sequence; }
- (NSPoint)draggingLocation { return _location; }
- (NSArray<NSDraggingItem *> *)_finchItems { return _items; }

- (void)enumerateDraggingItemsWithOptions:(NSDraggingItemEnumerationOptions)enumOpts forView:(NSView *)view
                                  classes:(NSArray<Class> *)classArray
                            searchOptions:(NSDictionary<NSPasteboardReadingOptionKey, id> *)searchOptions
                               usingBlock:(void (NS_NOESCAPE ^)(NSDraggingItem *draggingItem, NSInteger idx, BOOL *stop))block
{
    BOOL stop = NO;
    NSInteger i = 0;
    for (NSDraggingItem *item in _items) {
        block(item, i++, &stop);
        if (stop)
            break;
    }
}

#pragma mark The drag image

/* The items' images, composed over their frames (screen coordinates); origin out. */
- (NSImage *)_finchImageWithOrigin:(NSPoint *)origin
{
    if (_legacy) {
        *origin = _legacyImageOrigin;
        return _legacyImage;
    }
    NSRect all = NSZeroRect;
    for (NSDraggingItem *item in _items)
        all = NSIsEmptyRect(all) ? [item draggingFrame] : NSUnionRect(all, [item draggingFrame]);
    if (NSIsEmptyRect(all) || !_sourceView)
        return nil;
    NSImage *image = [[[NSImage alloc] initWithSize:all.size] autorelease];
    [image lockFocusFlipped:[_sourceView isFlipped]];
    for (NSDraggingItem *item in _items)
        for (NSDraggingImageComponent *c in [item imageComponents]) {
            id contents = [c contents];
            NSRect f = NSOffsetRect([c frame], NSMinX([item draggingFrame]) - NSMinX(all), NSMinY([item draggingFrame]) - NSMinY(all));
            if ([contents isKindOfClass:[NSImage class]])
                [contents drawInRect:f fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:0.75];
        }
    [image unlockFocus];
    NSRect inWindow = [_sourceView convertRect:all toView:nil];
    *origin = [[_sourceView window] convertRectToScreen:inWindow].origin;
    return image;
}

#pragma mark Destinations

/* The frontmost window of the app under the point (not the drag image's), and in it the
   deepest view registered for one of the pasteboard's types, else the window if it is. */
static id
destination_at(NSPoint screen, NSWindow *except, NSArray *types, NSWindow **windowOut)
{
    *windowOut = nil;
    for (NSWindow *w in [NSApp orderedWindows]) {
        if (w == except || ![w isVisible] || [w ignoresMouseEvents] || !NSPointInRect(screen, [w frame]))
            continue;
        *windowOut = w;
        NSPoint inWindow = [w convertPointFromScreen:screen];
        NSView *top = [[w contentView] superview] ?: [w contentView];
        NSView *v = [top hitTest:[top superview] ? [[top superview] convertPoint:inWindow fromView:nil] : inWindow];
        for (; v; v = [v superview])
            if ([[v registeredDraggedTypes] firstObjectCommonWithArray:types])
                return v;
        if ([[w _finchRegisteredDraggedTypes] firstObjectCommonWithArray:types])
            return w;
        return nil;
    }
    return nil;
}

/* The one operation a destination's answer comes to, within what the source allows. */
static NSDragOperation
choose(NSDragOperation answer, NSDragOperation allowed)
{
    NSDragOperation both = answer & allowed;
    if (!both)
        return NSDragOperationNone;
    const NSDragOperation order[] = {NSDragOperationMove, NSDragOperationCopy, NSDragOperationLink, NSDragOperationGeneric,
                                     NSDragOperationPrivate, NSDragOperationDelete};
    if (answer == NSDragOperationEvery || (answer & (answer - 1)))
        for (size_t i = 0; i < sizeof order / sizeof *order; i++)
            if (both & order[i])
                return order[i];
    return both;
}

static void
set_drag_cursor(NSDragOperation op)
{
    if (op & NSDragOperationCopy)
        [[NSCursor dragCopyCursor] set];
    else if (op & NSDragOperationLink)
        [[NSCursor dragLinkCursor] set];
    else if (op == NSDragOperationNone)
        [[NSCursor operationNotAllowedCursor] set];
    else
        [[NSCursor arrowCursor] set];
}

#pragma mark Running

- (NSDragOperation)_finchSourceMask
{
    if (_legacy) {
        if ([_source respondsToSelector:@selector(draggingSourceOperationMaskForLocal:)])
            return [_source draggingSourceOperationMaskForLocal:YES];
        return NSDragOperationEvery;
    }
    if ([_source respondsToSelector:@selector(draggingSession:sourceOperationMaskForDraggingContext:)])
        return [_source draggingSession:self sourceOperationMaskForDraggingContext:NSDraggingContextWithinApplication];
    return NSDragOperationNone;
}

/* The drag, from where it began until the mouse goes up (or Escape). */
- (NSDragOperation)_finchRun
{
    NSPoint origin = NSZeroPoint;
    NSImage *image = [self _finchImageWithOrigin:&origin];
    NSPoint grab = NSMakePoint(_startScreen.x - origin.x, _startScreen.y - origin.y);
    NSWindow *shown = nil;
    if (image) {
        shown = [[NSWindow alloc] initWithContentRect:NSMakeRect(origin.x, origin.y, [image size].width, [image size].height)
                                            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        [shown setReleasedWhenClosed:NO];
        [shown setOpaque:NO];
        [shown setBackgroundColor:[NSColor clearColor]];
        [shown setIgnoresMouseEvents:YES];
        [shown setLevel:NSPopUpMenuWindowLevel];
        NSImageView *iv = [NSImageView imageViewWithImage:image];
        [shown setContentView:iv];
        [shown orderFront:nil];
    }
    NSDragOperation mask = [self _finchSourceMask];
    if (_legacy) {
        if ([_source respondsToSelector:@selector(draggedImage:beganAt:)])
            [_source draggedImage:image beganAt:origin];
    } else if ([_source respondsToSelector:@selector(draggingSession:willBeginAtPoint:)])
        [_source draggingSession:self willBeginAtPoint:_startScreen];

    _FinchDraggingInfo *info = [[[_FinchDraggingInfo alloc] init] autorelease];
    info->_session = self;
    info->_sourceMask = mask;
    info->_source = _source;
    info->_image = image;
    info->_formation = _formation;
    info->_animates = YES;
    info->_validItems = (NSInteger)[_items count] ?: 1;
    extern NSArray<NSString *> *FinchPasteboardTypeNames(NSString *type); /* (NSPasteboard.m) */
    NSMutableArray *types = [NSMutableArray array];
    for (NSString *t in [_pasteboard types])
        [types addObjectsFromArray:FinchPasteboardTypeNames(t)];
    id current = nil;
    NSDragOperation op = NSDragOperationNone;
    NSPoint screen = _startScreen;
    BOOL cancelled = NO;
    for (;;) {
        NSEvent *e = [NSApp nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp | NSEventMaskMouseMoved |
                                                  NSEventMaskKeyDown | NSEventMaskFlagsChanged
                                        untilDate:[NSDate distantFuture]
                                           inMode:NSEventTrackingRunLoopMode
                                          dequeue:YES];
        if (!e)
            continue;
        if (getenv("FINCH_DRAG_DEBUG"))
            fprintf(stderr, "drag event %lu at %s window %ld\n", (unsigned long)[e type], NSStringFromPoint([e locationInWindow]).UTF8String,
                    (long)[[e window] windowNumber]);
        if ([e type] == NSEventTypeKeyDown) {
            if ([[e charactersIgnoringModifiers] isEqualToString:@"\e"]) {
                cancelled = YES;
                break;
            }
            continue;
        }
        screen = [e window] ? [[e window] convertPointToScreen:[e locationInWindow]] : [NSEvent mouseLocation];
        _location = screen;
        info->_screenLocation = screen;
        info->_imageScreenOrigin = NSMakePoint(screen.x - grab.x, screen.y - grab.y);
        [shown setFrameOrigin:info->_imageScreenOrigin];
        if (_legacy) {
            if ([_source respondsToSelector:@selector(draggedImage:movedTo:)])
                [_source draggedImage:image movedTo:info->_imageScreenOrigin];
        } else if ([_source respondsToSelector:@selector(draggingSession:movedToPoint:)])
            [_source draggingSession:self movedToPoint:screen];
        NSWindow *window = nil;
        id dest = destination_at(screen, shown, types, &window);
        info->_destinationWindow = window;
        if (dest != current) {
            if ([current respondsToSelector:@selector(draggingExited:)])
                [current draggingExited:info];
            current = dest;
            op = NSDragOperationNone;
            if ([current respondsToSelector:@selector(draggingEntered:)])
                op = choose([current draggingEntered:info], mask);
            else if ([current respondsToSelector:@selector(performDragOperation:)])
                op = choose(NSDragOperationEvery, mask);
        } else if (current && [current respondsToSelector:@selector(draggingUpdated:)])
            op = choose([current draggingUpdated:info], mask);
        set_drag_cursor(current ? op : NSDragOperationNone);
        if ([e type] == NSEventTypeLeftMouseUp)
            break;
    }
    BOOL done = NO;
    if (!cancelled && current && op != NSDragOperationNone) {
        BOOL prepared = ![current respondsToSelector:@selector(prepareForDragOperation:)] || [current prepareForDragOperation:info];
        done = prepared && [current respondsToSelector:@selector(performDragOperation:)] && [current performDragOperation:info];
        if (done && [current respondsToSelector:@selector(concludeDragOperation:)])
            [current concludeDragOperation:info];
    } else if (current && [current respondsToSelector:@selector(draggingExited:)])
        [current draggingExited:info];
    if (!done)
        op = NSDragOperationNone;
    if ([current respondsToSelector:@selector(draggingEnded:)])
        [current draggingEnded:info];
    [[NSCursor arrowCursor] set];
    [shown orderOut:nil];
    [shown release];
    if (_legacy) {
        if ([_source respondsToSelector:@selector(draggedImage:endedAt:operation:)])
            [_source draggedImage:image endedAt:info->_imageScreenOrigin operation:op];
    } else if ([_source respondsToSelector:@selector(draggingSession:endedAtPoint:operation:)])
        [_source draggingSession:self endedAtPoint:screen operation:op];
    return op;
}

@end

#pragma mark - The dragging info

@implementation _FinchDraggingInfo

- (NSWindow *)draggingDestinationWindow { return _destinationWindow; }
- (NSDragOperation)draggingSourceOperationMask { return _sourceMask; }
- (NSPoint)draggingLocation { return _destinationWindow ? [_destinationWindow convertPointFromScreen:_screenLocation] : _screenLocation; }
- (NSPoint)draggedImageLocation
{
    return _destinationWindow ? [_destinationWindow convertPointFromScreen:_imageScreenOrigin] : _imageScreenOrigin;
}
- (NSImage *)draggedImage { return _image; }
- (NSPasteboard *)draggingPasteboard { return [_session draggingPasteboard]; }
- (id)draggingSource { return _source; }
- (NSInteger)draggingSequenceNumber { return [_session draggingSequenceNumber]; }
- (void)slideDraggedImageTo:(NSPoint)screenPoint {}
- (NSArray<NSString *> *)namesOfPromisedFilesDroppedAtDestination:(NSURL *)dropDestination { return nil; }
- (NSDraggingFormation)draggingFormation { return _formation; }
- (void)setDraggingFormation:(NSDraggingFormation)f { _formation = f; }
- (BOOL)animatesToDestination { return _animates; }
- (void)setAnimatesToDestination:(BOOL)flag { _animates = flag; }
- (NSInteger)numberOfValidItemsForDrop { return _validItems; }
- (void)setNumberOfValidItemsForDrop:(NSInteger)n { _validItems = n; }
- (NSSpringLoadingHighlight)springLoadingHighlight { return NSSpringLoadingHighlightNone; }
- (void)resetSpringLoading {}

- (void)enumerateDraggingItemsWithOptions:(NSDraggingItemEnumerationOptions)enumOpts forView:(NSView *)view
                                  classes:(NSArray<Class> *)classArray
                            searchOptions:(NSDictionary<NSPasteboardReadingOptionKey, id> *)searchOptions
                               usingBlock:(void (NS_NOESCAPE ^)(NSDraggingItem *draggingItem, NSInteger idx, BOOL *stop))block
{
    /* (the items as the destination reads them: objects of the classes asked for) */
    NSArray *objects = [[self draggingPasteboard] readObjectsForClasses:classArray options:searchOptions] ?: @[];
    BOOL stop = NO;
    NSInteger i = 0;
    for (id o in objects) {
        NSDraggingItem *item = [[[NSDraggingItem alloc] initWithPasteboardWriter:o] autorelease];
        block(item, i++, &stop);
        if (stop)
            break;
    }
}

@end

#pragma mark - Starting a drag

static NSMutableArray *pending_drags;

/* (NSApplication's sendEvent: calls this once each event is dispatched) */
void
FinchRunPendingDrag(void)
{
    while (pending_drags && [pending_drags count]) {
        NSDraggingSession *s = [[pending_drags[0] retain] autorelease];
        [pending_drags removeObjectAtIndex:0];
        [s _finchRun];
    }
}

@implementation NSView (FinchDragging)

/* The items on the drag pasteboard, then the drag on the next turn (as Apple's, the
   caller returns first). */
- (NSDraggingSession *)beginDraggingSessionWithItems:(NSArray<NSDraggingItem *> *)items event:(NSEvent *)event source:(id<NSDraggingSource>)source
{
    NSPoint screen = [event window] ? [[event window] convertPointToScreen:[event locationInWindow]] : [NSEvent mouseLocation];
    NSDraggingSession *s = [[NSDraggingSession alloc] _finchInitWithItems:items location:screen];
    NSPasteboard *pb = [s draggingPasteboard];
    [pb clearContents];
    NSMutableArray *writers = [NSMutableArray array];
    for (NSDraggingItem *item in items)
        if ([item item])
            [writers addObject:[item item]];
    [pb writeObjects:writers];
    s->_source = [source retain];
    s->_sourceView = [self retain];
    s->_startScreen = screen;
    /* (run once the event that began it is handled, or on the next turn if it began elsewhere) */
    if (!pending_drags)
        pending_drags = [[NSMutableArray alloc] init];
    [pending_drags addObject:s];
    [s release];
    dispatch_async(dispatch_get_main_queue(), ^{
        FinchRunPendingDrag();
    });
    return s;
}

/* A file, with its icon, as the older API drags one. */
- (BOOL)dragFile:(NSString *)filename fromRect:(NSRect)rect slideBack:(BOOL)flag event:(NSEvent *)event
{
    NSPasteboard *pb = [NSPasteboard pasteboardWithName:NSPasteboardNameDrag];
    [pb declareTypes:@[ @"NSFilenamesPboardType", NSPasteboardTypeFileURL ] owner:nil];
    [pb setPropertyList:@[ filename ] forType:@"NSFilenamesPboardType"];
    [pb setString:[[NSURL fileURLWithPath:filename] absoluteString] forType:NSPasteboardTypeFileURL];
    NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:filename];
    [self dragImage:icon at:rect.origin offset:NSZeroSize event:event pasteboard:pb source:self slideBack:flag];
    return YES;
}

- (BOOL)dragPromisedFilesOfTypes:(NSArray<NSString *> *)typeArray fromRect:(NSRect)rect source:(id)sourceObject slideBack:(BOOL)flag
                           event:(NSEvent *)event
{
    NSPasteboard *pb = [NSPasteboard pasteboardWithName:NSPasteboardNameDrag];
    [pb declareTypes:@[ @"NSPromiseContentsPboardType", @"Apple files promise pasteboard type" ] owner:sourceObject];
    [pb setPropertyList:typeArray forType:@"NSPromiseContentsPboardType"];
    NSImage *image = [[NSWorkspace sharedWorkspace] iconForFileType:[typeArray firstObject] ?: @"public.data"];
    [self dragImage:image at:rect.origin offset:NSZeroSize event:event pasteboard:pb source:sourceObject slideBack:flag];
    return YES;
}

@end

@implementation NSWindow (FinchDragging)

/* The older drag: the pasteboard as the caller filled it, the image at a point in
   the window; the drag runs before this returns, as Apple's. */
- (void)dragImage:(NSImage *)image at:(NSPoint)baseLocation offset:(NSSize)initialOffset event:(NSEvent *)event
       pasteboard:(NSPasteboard *)pboard source:(id)sourceObj slideBack:(BOOL)slideFlag
{
    NSPoint screen = [event window] ? [[event window] convertPointToScreen:[event locationInWindow]] : [NSEvent mouseLocation];
    NSDraggingSession *s = [[[NSDraggingSession alloc] _finchInitWithItems:@[] location:screen] autorelease];
    if (pboard && pboard != [s draggingPasteboard]) {
        NSPasteboard *drag = [s draggingPasteboard];
        [drag declareTypes:[pboard types] ?: @[] owner:nil];
        for (NSString *t in [pboard types]) {
            NSData *d = [pboard dataForType:t];
            if (d)
                [drag setData:d forType:t];
        }
    }
    s->_source = [sourceObj retain];
    s->_startScreen = screen;
    s->_legacy = YES;
    s->_legacyImage = [image retain];
    s->_legacyImageOrigin = [self convertPointToScreen:baseLocation];
    [s _finchRun];
}

- (NSDraggingSession *)beginDraggingSessionWithItems:(NSArray<NSDraggingItem *> *)items event:(NSEvent *)event source:(id<NSDraggingSource>)source
{
    NSView *top = [[self contentView] superview] ?: [self contentView];
    return [top beginDraggingSessionWithItems:items event:event source:source];
}

@end

@implementation NSView (FinchLegacyDragImage)

- (void)dragImage:(NSImage *)image at:(NSPoint)viewLocation offset:(NSSize)initialOffset event:(NSEvent *)event
       pasteboard:(NSPasteboard *)pboard source:(id)sourceObj slideBack:(BOOL)slideFlag
{
    [[self window] dragImage:image at:[self convertPoint:viewLocation toView:nil] offset:initialOffset event:event pasteboard:pboard
                      source:sourceObj slideBack:slideFlag];
}

@end
