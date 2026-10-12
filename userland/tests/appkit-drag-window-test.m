/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-appkit-drag-window-test: drag and drop within an app, on Finch's window server.
 * Starts a headless server, puts a drag source in one window and a logging
 * destination and an editable text view in another, then drags through the server:
 * a string to the destination (the destination calls and the source's, in order),
 * text into the text view at a point, a drag to nowhere, a drag cancelled with
 * Escape, text moved within a text view, and a drag by the older dragImage: API.
 * Finch-only (Apple's drags run in its own window server): compare with
 * appkit-drag-window-test.expected.
 *
 *   finch-appkit-drag-window-test [path to finch-windowserver]
 */
#import <AppKit/AppKit.h>
#include <spawn.h>
#include "../WindowServer/FinchWSProtocol.h"

extern char **environ;
bool FWSConnect(void);
void FWSPostEvent(const FWSEvent *e);
void FWSSetCursorVisible(bool v);

static const double kScreenHeight = 600;
static NSMutableArray *calls;

static void
post_at(uint32_t type, NSPoint p, unichar c)
{
    FWSEvent e;
    memset(&e, 0, sizeof e);
    e.type = type;
    e.screen_x = p.x, e.screen_y = kScreenHeight - p.y;
    if (c) {
        e.characters[0] = e.unmodified[0] = c;
        e.length = 1;
    }
    FWSPostEvent(&e);
}

static void
pump(double seconds)
{
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    for (;;) {
        NSEvent *e = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:until inMode:NSDefaultRunLoopMode dequeue:YES];
        if (!e)
            break;
        [NSApp sendEvent:e];
    }
}

static NSPoint
screen_point(NSView *v, NSPoint inView)
{
    return [v.window convertPointToScreen:[v convertPoint:inView toView:nil]];
}

static NSPoint
center_of(NSView *v)
{
    return screen_point(v, NSMakePoint(NSMidX(v.bounds), NSMidY(v.bounds)));
}

/* A press, moves along the way, and a release (Escape before it, to cancel). */
static void
drag(NSPoint from, NSPoint to, BOOL cancel)
{
    post_at(FWS_EVENT_LEFT_DOWN, from, 0);
    for (int i = 1; i <= 6; i++) {
        NSPoint p = NSMakePoint(from.x + (to.x - from.x) * i / 6, from.y + (to.y - from.y) * i / 6);
        post_at(FWS_EVENT_LEFT_DRAGGED, p, 0);
    }
    if (cancel) {
        /* (Escape while the drag runs: a timer in the tracking mode, the release after it) */
        NSTimer *move = [NSTimer timerWithTimeInterval:0.3 repeats:NO block:^(NSTimer *timer) {
            post_at(FWS_EVENT_LEFT_DRAGGED, to, 0);
        }];
        NSTimer *escape = [NSTimer timerWithTimeInterval:0.8 repeats:NO block:^(NSTimer *timer) {
            post_at(FWS_EVENT_KEY_DOWN, to, '\e');
            post_at(FWS_EVENT_LEFT_UP, to, 0);
        }];
        [[NSRunLoop currentRunLoop] addTimer:move forMode:NSRunLoopCommonModes];
        [[NSRunLoop currentRunLoop] addTimer:escape forMode:NSRunLoopCommonModes];
    } else
        post_at(FWS_EVENT_LEFT_UP, to, 0);
    pump(1.5);
}

static NSString *
op_name(NSDragOperation op)
{
    switch (op) {
    case NSDragOperationNone: return @"none";
    case NSDragOperationCopy: return @"copy";
    case NSDragOperationMove: return @"move";
    case NSDragOperationLink: return @"link";
    case NSDragOperationGeneric: return @"generic";
    default: return [NSString stringWithFormat:@"%lu", (unsigned long)op];
    }
}

/* A square that drags a string when the mouse moves on it. */
@interface SourceView : NSView <NSDraggingSource>
@property BOOL legacy;
@end
@implementation SourceView
- (void)drawRect:(NSRect)r
{
    [[NSColor systemOrangeColor] setFill];
    NSRectFill(self.bounds);
}
- (void)mouseDown:(NSEvent *)e {}
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (void)mouseDragged:(NSEvent *)e
{
    NSImage *img = [NSImage imageWithSize:NSMakeSize(20, 20) flipped:NO drawingHandler:^BOOL(NSRect r) {
        [[NSColor systemOrangeColor] setFill];
        NSRectFill(r);
        return YES;
    }];
    if (self.legacy) {
        NSPasteboard *pb = [NSPasteboard pasteboardWithName:NSPasteboardNameDrag];
        [pb clearContents];
        [pb setString:@"legacy text" forType:NSPasteboardTypeString];
        [calls addObject:@"legacy drag starts"];
        [self dragImage:img at:NSZeroPoint offset:NSZeroSize event:e pasteboard:pb source:self slideBack:YES];
        [calls addObject:@"legacy drag returned"];
        return;
    }
    NSDraggingItem *item = [[NSDraggingItem alloc] initWithPasteboardWriter:@"dragged text"];
    [item setDraggingFrame:NSMakeRect(0, 0, 20, 20) contents:img];
    NSDraggingSession *s = [self beginDraggingSessionWithItems:@[ item ] event:e source:self];
    [calls addObject:[NSString stringWithFormat:@"began (session %s)", s ? "made" : "nil"]];
}
- (NSDragOperation)draggingSession:(NSDraggingSession *)s sourceOperationMaskForDraggingContext:(NSDraggingContext)c
{
    return NSDragOperationCopy | NSDragOperationGeneric;
}
- (void)draggingSession:(NSDraggingSession *)s willBeginAtPoint:(NSPoint)p { [calls addObject:@"source: will begin"]; }
- (void)draggingSession:(NSDraggingSession *)s endedAtPoint:(NSPoint)p operation:(NSDragOperation)op
{
    [calls addObject:[@"source: ended " stringByAppendingString:op_name(op)]];
}
- (NSDragOperation)draggingSourceOperationMaskForLocal:(BOOL)local { return NSDragOperationCopy; }
- (void)draggedImage:(NSImage *)i beganAt:(NSPoint)p { [calls addObject:@"legacy source: began"]; }
- (void)draggedImage:(NSImage *)i endedAt:(NSPoint)p operation:(NSDragOperation)op
{
    [calls addObject:[@"legacy source: ended " stringByAppendingString:op_name(op)]];
}
@end

/* A destination that logs what it's told and takes strings. */
@interface DestView : NSView
@property (copy) NSString *got;
@end
@implementation DestView
- (void)drawRect:(NSRect)r
{
    [[NSColor systemTealColor] setFill];
    NSRectFill(self.bounds);
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info
{
    [calls addObject:[NSString stringWithFormat:@"dest: entered (mask %@, window %s)", op_name(info.draggingSourceOperationMask),
                                                info.draggingDestinationWindow == self.window ? "mine" : "other"]];
    return NSDragOperationCopy;
}
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info { return NSDragOperationCopy; }
- (void)draggingExited:(id<NSDraggingInfo>)info { [calls addObject:@"dest: exited"]; }
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)info
{
    [calls addObject:@"dest: prepare"];
    return YES;
}
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info
{
    self.got = [info.draggingPasteboard stringForType:NSPasteboardTypeString];
    NSPoint p = [self convertPoint:info.draggingLocation fromView:nil];
    [calls addObject:[NSString stringWithFormat:@"dest: perform [%@] inside %d", self.got, NSPointInRect(p, self.bounds)]];
    return YES;
}
- (void)concludeDragOperation:(id<NSDraggingInfo>)info { [calls addObject:@"dest: conclude"]; }
- (void)draggingEnded:(id<NSDraggingInfo>)info { [calls addObject:@"dest: ended"]; }
@end

/* A table whose rows reorder by dragging. */
@interface Rows : NSObject <NSTableViewDataSource>
@property NSMutableArray *rows;
@end
@implementation Rows
- (NSInteger)numberOfRowsInTableView:(NSTableView *)t { return (NSInteger)self.rows.count; }
- (id)tableView:(NSTableView *)t objectValueForTableColumn:(NSTableColumn *)c row:(NSInteger)r { return self.rows[(NSUInteger)r]; }
- (id<NSPasteboardWriting>)tableView:(NSTableView *)t pasteboardWriterForRow:(NSInteger)r
{
    NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
    [item setString:[NSString stringWithFormat:@"%ld", (long)r] forType:@"org.finch.test.row"];
    return item;
}
- (void)tableView:(NSTableView *)t draggingSession:(NSDraggingSession *)s willBeginAtPoint:(NSPoint)p forRowIndexes:(NSIndexSet *)rows
{
    [calls addObject:[NSString stringWithFormat:@"rows: drag begins with %lu", (unsigned long)rows.count]];
}
- (NSDragOperation)tableView:(NSTableView *)t validateDrop:(id<NSDraggingInfo>)info proposedRow:(NSInteger)row
       proposedDropOperation:(NSTableViewDropOperation)op
{
    if (op == NSTableViewDropOn)
        [t setDropRow:row dropOperation:NSTableViewDropAbove];
    return NSDragOperationMove;
}
- (BOOL)tableView:(NSTableView *)t acceptDrop:(id<NSDraggingInfo>)info row:(NSInteger)row dropOperation:(NSTableViewDropOperation)op
{
    NSInteger from = [[info.draggingPasteboard stringForType:@"org.finch.test.row"] integerValue];
    [calls addObject:[NSString stringWithFormat:@"rows: drop row %ld at %ld (%s)", (long)from, (long)row, op == NSTableViewDropAbove ? "above" : "on"]];
    id moved = self.rows[(NSUInteger)from];
    [self.rows removeObjectAtIndex:(NSUInteger)from];
    [self.rows insertObject:moved atIndex:(NSUInteger)(row > from ? row - 1 : row)];
    [t reloadData];
    return YES;
}
- (void)tableView:(NSTableView *)t draggingSession:(NSDraggingSession *)s endedAtPoint:(NSPoint)p operation:(NSDragOperation)op
{
    [calls addObject:[@"rows: drag ended " stringByAppendingString:op_name(op)]];
}
@end

/* An outline of two groups; items drop onto a group. */
@interface Groups : NSObject <NSOutlineViewDataSource>
@property NSMutableDictionary *groups; /* name -> items */
@end
@implementation Groups
- (NSArray *)names { return @[ @"fruit", @"veg" ]; }
- (NSInteger)outlineView:(NSOutlineView *)o numberOfChildrenOfItem:(id)item
{
    return item ? (NSInteger)[self.groups[item] count] : 2;
}
- (id)outlineView:(NSOutlineView *)o child:(NSInteger)i ofItem:(id)item
{
    return item ? self.groups[item][(NSUInteger)i] : self.names[(NSUInteger)i];
}
- (BOOL)outlineView:(NSOutlineView *)o isItemExpandable:(id)item { return self.groups[item] != nil; }
- (id)outlineView:(NSOutlineView *)o objectValueForTableColumn:(NSTableColumn *)c byItem:(id)item { return item; }
- (id<NSPasteboardWriting>)outlineView:(NSOutlineView *)o pasteboardWriterForItem:(id)item
{
    if (self.groups[item])
        return nil;
    NSPasteboardItem *pi = [[NSPasteboardItem alloc] init];
    [pi setString:item forType:@"org.finch.test.item"];
    return pi;
}
- (NSDragOperation)outlineView:(NSOutlineView *)o validateDrop:(id<NSDraggingInfo>)info proposedItem:(id)item proposedChildIndex:(NSInteger)index
{
    [calls addObject:[NSString stringWithFormat:@"groups: proposed %@ %ld", item ?: @"root", (long)index]];
    if (!self.groups[item])
        return NSDragOperationNone;
    return NSDragOperationMove;
}
- (BOOL)outlineView:(NSOutlineView *)o acceptDrop:(id<NSDraggingInfo>)info item:(id)item childIndex:(NSInteger)index
{
    NSString *thing = [info.draggingPasteboard stringForType:@"org.finch.test.item"];
    for (NSString *g in self.names)
        [self.groups[g] removeObject:thing];
    [self.groups[item] addObject:thing];
    [calls addObject:[NSString stringWithFormat:@"groups: %@ into %@ at %ld", thing, item, (long)index]];
    [o reloadData];
    [o expandItem:nil expandChildren:YES];
    return YES;
}
@end

/* A collection whose items reorder by dragging. */
@interface Tiles : NSObject <NSCollectionViewDataSource, NSCollectionViewDelegate>
@property NSMutableArray *tiles;
@end
@implementation Tiles
- (NSInteger)collectionView:(NSCollectionView *)cv numberOfItemsInSection:(NSInteger)s { return (NSInteger)self.tiles.count; }
- (NSCollectionViewItem *)collectionView:(NSCollectionView *)cv itemForRepresentedObjectAtIndexPath:(NSIndexPath *)ip
{
    NSCollectionViewItem *item = [cv makeItemWithIdentifier:@"tile" forIndexPath:ip];
    item.representedObject = self.tiles[(NSUInteger)ip.item];
    return item;
}
- (BOOL)collectionView:(NSCollectionView *)cv canDragItemsAtIndexPaths:(NSSet<NSIndexPath *> *)paths withEvent:(NSEvent *)e { return YES; }
- (id<NSPasteboardWriting>)collectionView:(NSCollectionView *)cv pasteboardWriterForItemAtIndexPath:(NSIndexPath *)ip
{
    NSPasteboardItem *pi = [[NSPasteboardItem alloc] init];
    [pi setString:[NSString stringWithFormat:@"%ld", (long)ip.item] forType:@"org.finch.test.tile"];
    return pi;
}
- (NSDragOperation)collectionView:(NSCollectionView *)cv validateDrop:(id<NSDraggingInfo>)info
                proposedIndexPath:(NSIndexPath **)path dropOperation:(NSCollectionViewDropOperation *)op
{
    if (*op == NSCollectionViewDropOn)
        *op = NSCollectionViewDropBefore;
    return NSDragOperationMove;
}
- (BOOL)collectionView:(NSCollectionView *)cv acceptDrop:(id<NSDraggingInfo>)info indexPath:(NSIndexPath *)path
         dropOperation:(NSCollectionViewDropOperation)op
{
    NSInteger from = [[info.draggingPasteboard stringForType:@"org.finch.test.tile"] integerValue], to = path.item;
    [calls addObject:[NSString stringWithFormat:@"tiles: drop %ld before %ld", (long)from, (long)to]];
    id moved = self.tiles[(NSUInteger)from];
    [self.tiles removeObjectAtIndex:(NSUInteger)from];
    [self.tiles insertObject:moved atIndex:(NSUInteger)(to > from ? to - 1 : to)];
    [cv reloadData];
    return YES;
}
- (void)collectionView:(NSCollectionView *)cv draggingSession:(NSDraggingSession *)s endedAtPoint:(NSPoint)p dragOperation:(NSDragOperation)op
{
    [calls addObject:[@"tiles: drag ended " stringByAppendingString:op_name(op)]];
}
@end

@interface Tile : NSCollectionViewItem
@end
@implementation Tile
- (void)loadView { self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 40, 40)]; }
@end

static void
report(const char *label)
{
    printf("%s:\n", label);
    for (NSString *c in calls)
        printf("  %s\n", c.UTF8String);
    [calls removeAllObjects];
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        const char *server = argc > 1 ? argv[1] : "/usr/libexec/finch-windowserver";
        char sock[64];
        snprintf(sock, sizeof sock, "/tmp/finch-adwt.%d", getpid());
        setenv(FWS_SOCKET_ENV, sock, 1);
        pid_t pid;
        char *args[] = {(char *)server, "--headless", "--size", "800x600", "--scale", "2", NULL};
        if (posix_spawn(&pid, server, NULL, NULL, args, environ)) {
            printf("can't start %s\n", server);
            return 1;
        }
        for (int i = 0; i < 100 && !FWSConnect(); i++)
            usleep(20000);
        FWSSetCursorVisible(false);
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp finishLaunching];
        calls = [NSMutableArray array];

        NSWindow *a = [[NSWindow alloc] initWithContentRect:NSMakeRect(40, 300, 200, 160) styleMask:NSWindowStyleMaskTitled
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
        a.releasedWhenClosed = NO;
        SourceView *src = [[SourceView alloc] initWithFrame:NSMakeRect(20, 20, 60, 60)];
        [a.contentView addSubview:src];
        NSWindow *b = [[NSWindow alloc] initWithContentRect:NSMakeRect(320, 120, 420, 340) styleMask:NSWindowStyleMaskTitled
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
        b.releasedWhenClosed = NO;
        DestView *dest = [[DestView alloc] initWithFrame:NSMakeRect(20, 220, 120, 90)];
        [dest registerForDraggedTypes:@[ NSPasteboardTypeString ]];
        [b.contentView addSubview:dest];
        NSView *plain = [[NSView alloc] initWithFrame:NSMakeRect(180, 220, 120, 90)];
        [b.contentView addSubview:plain];
        NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(20, 20, 380, 180)];
        tv.string = @"Hello world";
        tv.font = [NSFont systemFontOfSize:14];
        [b.contentView addSubview:tv];
        [b makeKeyAndOrderFront:nil];
        [a orderFront:nil];
        pump(0.5);
        printf("text view registered for strings: %d\n", [tv.registeredDraggedTypes containsObject:NSPasteboardTypeString] ||
                                                          [tv.registeredDraggedTypes containsObject:@"NSStringPboardType"]);

        drag(center_of(src), center_of(dest), NO);
        report("to the destination");
        printf("destination got: %s\n", dest.got.UTF8String);

        NSUInteger end = tv.string.length;
        NSRect lastChar = [tv firstRectForCharacterRange:NSMakeRange(end - 1, 1) actualRange:NULL];
        NSPoint afterText = NSMakePoint(NSMaxX(lastChar) + 2, NSMidY(lastChar));
        drag(center_of(src), afterText, NO);
        report("into the text view");
        printf("text: [%s] selected %s\n", tv.string.UTF8String, NSStringFromRange(tv.selectedRange).UTF8String);

        drag(center_of(src), center_of(plain), NO);
        report("to a view taking nothing");

        drag(center_of(src), center_of(dest), YES);
        report("cancelled");

        tv.string = @"Hello world";
        [b makeFirstResponder:tv];
        tv.selectedRange = NSMakeRange(0, 5);
        pump(0.2);
        NSRect hello = [tv firstRectForCharacterRange:NSMakeRange(1, 1) actualRange:NULL];
        lastChar = [tv firstRectForCharacterRange:NSMakeRange(tv.string.length - 1, 1) actualRange:NULL];
        drag(NSMakePoint(NSMidX(hello), NSMidY(hello)), NSMakePoint(NSMaxX(lastChar) + 2, NSMidY(lastChar)), NO);
        printf("moved within the text view: [%s] selected %s\n", tv.string.UTF8String, NSStringFromRange(tv.selectedRange).UTF8String);

        src.legacy = YES;
        drag(center_of(src), center_of(dest), NO);
        report("the older dragImage:");
        printf("destination got: %s\n", dest.got.UTF8String);

        /* tables: drag row 0 below row 2 */
        NSWindow *c = [[NSWindow alloc] initWithContentRect:NSMakeRect(40, 40, 220, 220) styleMask:NSWindowStyleMaskTitled
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
        c.releasedWhenClosed = NO;
        Rows *rows = [Rows new];
        rows.rows = [@[ @"a", @"b", @"c", @"d" ] mutableCopy];
        NSTableView *table = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 200, 200)];
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"c"];
        col.width = 180;
        [table addTableColumn:col];
        table.headerView = nil;
        table.dataSource = rows;
        [table registerForDraggedTypes:@[ @"org.finch.test.row" ]];
        table.frame = NSMakeRect(10, 10, 200, 200);
        [c.contentView addSubview:table];
        [c makeKeyAndOrderFront:nil];
        [table reloadData];
        pump(0.4);
        NSRect r0 = [table rectOfRow:0], r2 = [table rectOfRow:2];
        drag(screen_point(table, NSMakePoint(NSMidX(r0), NSMidY(r0))),
             screen_point(table, NSMakePoint(NSMidX(r2), table.isFlipped ? NSMaxY(r2) - 2 : NSMinY(r2) + 2)), NO);
        report("reordering a table");
        printf("rows: %s\n", [rows.rows componentsJoinedByString:@" "].UTF8String);

        /* outlines: drag "apple" onto the veg group */
        Groups *groups = [Groups new];
        groups.groups = [@{@"fruit" : [@[ @"apple", @"pear" ] mutableCopy], @"veg" : [@[ @"leek" ] mutableCopy]} mutableCopy];
        NSOutlineView *outline = [[NSOutlineView alloc] initWithFrame:NSMakeRect(10, 10, 200, 200)];
        NSTableColumn *oc = [[NSTableColumn alloc] initWithIdentifier:@"o"];
        oc.width = 180;
        [outline addTableColumn:oc];
        outline.outlineTableColumn = oc;
        outline.headerView = nil;
        outline.dataSource = groups;
        [outline registerForDraggedTypes:@[ @"org.finch.test.item" ]];
        [table removeFromSuperview];
        [c.contentView addSubview:outline];
        [outline reloadData];
        [outline expandItem:nil expandChildren:YES];
        pump(0.4);
        NSInteger appleRow = [outline rowForItem:@"apple"], vegRow = [outline rowForItem:@"veg"];
        NSRect ra = [outline rectOfRow:appleRow], rv = [outline rectOfRow:vegRow];
        drag(screen_point(outline, NSMakePoint(NSMidX(ra), NSMidY(ra))), screen_point(outline, NSMakePoint(NSMidX(rv), NSMidY(rv))), NO);
        report("onto an outline group");
        printf("fruit: %s; veg: %s\n", [groups.groups[@"fruit"] componentsJoinedByString:@" "].UTF8String,
            [groups.groups[@"veg"] componentsJoinedByString:@" "].UTF8String);

        /* collections: drag tile 0 to before tile 3 */
        Tiles *tiles = [Tiles new];
        tiles.tiles = [@[ @"w", @"x", @"y", @"z" ] mutableCopy];
        NSCollectionViewFlowLayout *flow = [[NSCollectionViewFlowLayout alloc] init];
        flow.itemSize = NSMakeSize(40, 40);
        flow.minimumInteritemSpacing = 4;
        NSCollectionView *cv = [[NSCollectionView alloc] initWithFrame:NSMakeRect(10, 10, 200, 60)];
        cv.collectionViewLayout = flow;
        [cv registerClass:[Tile class] forItemWithIdentifier:@"tile"];
        cv.dataSource = tiles;
        cv.delegate = tiles;
        cv.selectable = YES;
        [cv registerForDraggedTypes:@[ @"org.finch.test.tile" ]];
        [outline removeFromSuperview];
        [c.contentView addSubview:cv];
        [cv reloadData];
        [cv layoutSubtreeIfNeeded];
        pump(0.4);
        NSRect t0 = [cv frameForItemAtIndex:0], t3 = [cv frameForItemAtIndex:3];
        drag(screen_point(cv, NSMakePoint(NSMidX(t0), NSMidY(t0))), screen_point(cv, NSMakePoint(NSMinX(t3) + 3, NSMidY(t3))), NO);
        report("reordering a collection");
        printf("tiles: %s\n", [tiles.tiles componentsJoinedByString:@" "].UTF8String);

        kill(pid, SIGTERM);
    }
    return 0;
}
