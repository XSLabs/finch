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
 * Between apps: over another app's window (the frontmost under the pointer, from the
 * window server's list), the source sends that window enter, update, exit, drop and
 * end messages through the window server (FWS_DRAG) and waits briefly for each reply;
 * the other app runs the same destination search in its window and answers with the
 * operation its destination takes. The drag pasteboard is the pasteboard server's,
 * shared by every app.
 */
#import "AppKit_Finch.h"
#include "../WindowServer/FinchWSProtocol.h"

void FWSSendDrag(const FWSEvent *e);

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
    NSInteger _sequence; /* another app's drag's */
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

/* In a given window: the deepest view under the point registered for the types, else
   the window if it is. */
static id
destination_in(NSWindow *w, NSPoint screen, NSArray *types, NSWindow **windowOut)
{
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

#pragma mark Other apps' windows

/* The frontmost window of any app under a point (Cocoa screen coordinates), skipping
   the windows given; its owner's process ID out. */
static uint32_t
window_at(NSPoint screen, NSArray<NSNumber *> *skip, pid_t *ownerOut)
{
    /* (the desktop takes no drops) */
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    CGFloat height = NSMaxY([[[NSScreen screens] firstObject] frame]);
    uint32_t found = 0;
    for (NSDictionary *info in (NSArray *)list) {
        NSNumber *number = info[(id)kCGWindowNumber];
        if ([skip containsObject:number])
            continue;
        CGRect b;
        if (!CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)info[(id)kCGWindowBounds], &b))
            continue;
        NSRect r = NSMakeRect(b.origin.x, height - b.origin.y - b.size.height, b.size.width, b.size.height);
        if (!NSPointInRect(screen, r))
            continue;
        found = [number unsignedIntValue];
        *ownerOut = [info[(id)kCGWindowOwnerPID] intValue];
        break;
    }
    if (list)
        CFRelease(list);
    return found;
}

static NSMutableDictionary<NSNumber *, NSNumber *> *drag_replies;
static uint32_t drag_message_id;

/* A message to another app's window, and its answer (waited for, a while). */
static NSDragOperation
send_drag(uint32_t window, int phase, NSPoint screen, NSDragOperation mask, NSInteger sequence)
{
    FWSEvent e;
    memset(&e, 0, sizeof e);
    e.type = FWS_EVENT_DRAG;
    e.window = window;
    e.key_code = (uint32_t)phase;
    e.button = (uint32_t)sequence;
    e.click_count = ++drag_message_id;
    e.modifiers = mask;
    CGFloat height = NSMaxY([[[NSScreen screens] firstObject] frame]);
    e.screen_x = screen.x, e.screen_y = height - screen.y;
    if (!drag_replies)
        drag_replies = [[NSMutableDictionary alloc] init];
    NSNumber *key = @(e.click_count);
    FWSSendDrag(&e);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:phase == FWS_DRAG_DROP ? 10 : 1];
    while (!drag_replies[key] && [deadline timeIntervalSinceNow] > 0)
        CFRunLoopRunInMode((CFStringRef)NSEventTrackingRunLoopMode, 0.01, true);
    NSDragOperation op = [drag_replies[key] unsignedIntegerValue];
    [drag_replies removeObjectForKey:key];
    return op;
}

#pragma mark Running

- (NSDragOperation)_finchSourceMaskLocal:(BOOL)local
{
    if (_legacy) {
        if ([_source respondsToSelector:@selector(draggingSourceOperationMaskForLocal:)])
            return [_source draggingSourceOperationMaskForLocal:local];
        return local ? NSDragOperationEvery : NSDragOperationCopy;
    }
    if ([_source respondsToSelector:@selector(draggingSession:sourceOperationMaskForDraggingContext:)])
        return [_source draggingSession:self
            sourceOperationMaskForDraggingContext:local ? NSDraggingContextWithinApplication : NSDraggingContextOutsideApplication];
    return NSDragOperationNone;
}

- (NSDragOperation)_finchSourceMask { return [self _finchSourceMaskLocal:YES]; }

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
    uint32_t external = 0; /* another app's window the drag is over */
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
        /* another app's window in front: messages to it through the window server */
        pid_t owner = getpid();
        uint32_t under = window_at(screen, shown ? @[ @([shown windowNumber]) ] : @[], &owner);
        if (owner != getpid() && under) {
            if ([current respondsToSelector:@selector(draggingExited:)])
                [current draggingExited:info];
            current = nil;
            NSDragOperation outside = [self _finchSourceMaskLocal:NO];
            if (under != external) {
                if (external)
                    send_drag(external, FWS_DRAG_EXIT, screen, outside, _sequence);
                external = under;
                op = choose(send_drag(external, FWS_DRAG_ENTER, screen, outside, _sequence), outside);
            } else
                op = choose(send_drag(external, FWS_DRAG_UPDATE, screen, outside, _sequence), outside);
            set_drag_cursor(op);
            if ([e type] == NSEventTypeLeftMouseUp)
                break;
            continue;
        }
        if (external) {
            send_drag(external, FWS_DRAG_EXIT, screen, [self _finchSourceMaskLocal:NO], _sequence);
            external = 0;
        }
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
    if (external) {
        NSDragOperation outside = [self _finchSourceMaskLocal:NO];
        if (!cancelled && op != NSDragOperationNone) {
            op = choose(send_drag(external, FWS_DRAG_DROP, screen, outside, _sequence), outside);
            done = op != NSDragOperationNone;
        } else
            send_drag(external, FWS_DRAG_EXIT, screen, outside, _sequence);
        send_drag(external, FWS_DRAG_END, screen, outside, _sequence);
    } else if (!cancelled && current && op != NSDragOperationNone) {
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
/* (another app's drag has no session here: the drag pasteboard, shared by every app) */
- (NSPasteboard *)draggingPasteboard
{
    return _session ? [_session draggingPasteboard] : [NSPasteboard pasteboardWithName:NSPasteboardNameDrag];
}
- (id)draggingSource { return _source; }
- (NSInteger)draggingSequenceNumber { return _session ? [_session draggingSequenceNumber] : _sequence; }
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

#pragma mark - Drags from other apps

/* The destination in one of this app's windows for another app's drag, kept across its
   messages (by the drag's sequence number). */
static NSMutableDictionary<NSNumber *, id> *incoming_targets;
static NSMutableDictionary<NSNumber *, _FinchDraggingInfo *> *incoming_infos;

static void
reply_drag(const FWSEvent *message, NSDragOperation op)
{
    FWSEvent r = *message;
    r.type = FWS_EVENT_DRAG_REPLY;
    r.modifiers = op;
    FWSSendDrag(&r);
}

/* (NSApplication passes the window server's drag messages here) */
void
FinchDragMessage(const FWSEvent *e)
{
    if (e->type == FWS_EVENT_DRAG_REPLY) {
        if (!drag_replies)
            drag_replies = [[NSMutableDictionary alloc] init];
        drag_replies[@(e->click_count)] = @(e->modifiers);
        return;
    }
    if (!incoming_targets) {
        incoming_targets = [[NSMutableDictionary alloc] init];
        incoming_infos = [[NSMutableDictionary alloc] init];
    }
    NSNumber *seq = @(e->button);
    NSWindow *w = nil;
    for (NSWindow *candidate in [NSApp windows])
        if ((uint32_t)[candidate windowNumber] == e->window)
            w = candidate;
    CGFloat height = NSMaxY([[[NSScreen screens] firstObject] frame]);
    NSPoint screen = NSMakePoint(e->screen_x, height - e->screen_y);
    _FinchDraggingInfo *info = incoming_infos[seq];
    if (!info) {
        info = [[[_FinchDraggingInfo alloc] init] autorelease];
        incoming_infos[seq] = info;
    }
    info->_destinationWindow = w;
    info->_sequence = e->button;
    info->_screenLocation = screen;
    info->_imageScreenOrigin = screen;
    info->_sourceMask = (NSDragOperation)e->modifiers;
    info->_validItems = 1;
    info->_animates = YES;
    id current = incoming_targets[seq];
    NSDragOperation op = NSDragOperationNone;
    switch (e->key_code) {
    case FWS_DRAG_ENTER:
    case FWS_DRAG_UPDATE: {
        extern NSArray<NSString *> *FinchPasteboardTypeNames(NSString *type);
        NSMutableArray *types = [NSMutableArray array];
        for (NSString *t in [[NSPasteboard pasteboardWithName:NSPasteboardNameDrag] types])
            [types addObjectsFromArray:FinchPasteboardTypeNames(t)];
        NSWindow *found = nil;
        id dest = w ? destination_in(w, screen, types, &found) : nil;
        if (dest != current) {
            if ([current respondsToSelector:@selector(draggingExited:)])
                [current draggingExited:info];
            current = dest;
            if (current)
                incoming_targets[seq] = current;
            else
                [incoming_targets removeObjectForKey:seq];
            if ([current respondsToSelector:@selector(draggingEntered:)])
                op = choose([current draggingEntered:info], info->_sourceMask);
            else if ([current respondsToSelector:@selector(performDragOperation:)])
                op = choose(NSDragOperationEvery, info->_sourceMask);
        } else if ([current respondsToSelector:@selector(draggingUpdated:)])
            op = choose([current draggingUpdated:info], info->_sourceMask);
        else if (current)
            op = choose(NSDragOperationEvery, info->_sourceMask);
        break;
    }
    case FWS_DRAG_EXIT:
        if ([current respondsToSelector:@selector(draggingExited:)])
            [current draggingExited:info];
        [incoming_targets removeObjectForKey:seq];
        break;
    case FWS_DRAG_DROP:
        if (current) {
            BOOL prepared = ![current respondsToSelector:@selector(prepareForDragOperation:)] || [current prepareForDragOperation:info];
            BOOL done = prepared && [current respondsToSelector:@selector(performDragOperation:)] && [current performDragOperation:info];
            if (done && [current respondsToSelector:@selector(concludeDragOperation:)])
                [current concludeDragOperation:info];
            op = done ? choose(NSDragOperationEvery, info->_sourceMask) : NSDragOperationNone;
        }
        break;
    case FWS_DRAG_END:
        if ([current respondsToSelector:@selector(draggingEnded:)])
            [current draggingEnded:info];
        [incoming_targets removeObjectForKey:seq];
        [incoming_infos removeObjectForKey:seq];
        break;
    }
    reply_drag(e, op);
}
