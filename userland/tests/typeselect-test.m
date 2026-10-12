/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Type select in tables and outlines: keys typed into a table select the first row
 * whose string (in any column) starts with them, a search growing while keys come
 * quickly and starting over after a pause; the delegate's strings, searches and
 * refusals; view-based rows and outline items. Compared with Apple's.
 */
#import <AppKit/AppKit.h>

@interface DS : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate>
@property NSArray *names;
@property int mode; /* 0 plain, 1 delegate strings, 2 delegate search, 3 refuses, 4 views */
@end

@implementation DS
- (NSInteger)numberOfRowsInTableView:(NSTableView *)t { return self.names.count; }
- (id)tableView:(NSTableView *)t objectValueForTableColumn:(NSTableColumn *)c row:(NSInteger)r
{
    return [c.identifier isEqual:@"a"] ? self.names[r] : [@"z" stringByAppendingString:self.names[r]];
}
- (BOOL)respondsToSelector:(SEL)sel
{
    if (sel == @selector(tableView:typeSelectStringForTableColumn:row:))
        return self.mode == 1;
    if (sel == @selector(tableView:nextTypeSelectMatchFromRow:toRow:forString:))
        return self.mode == 2;
    if (sel == @selector(tableView:shouldTypeSelectForEvent:withCurrentSearchString:))
        return self.mode == 3;
    if (sel == @selector(tableView:viewForTableColumn:row:))
        return self.mode == 4;
    return [super respondsToSelector:sel];
}
- (NSString *)tableView:(NSTableView *)t typeSelectStringForTableColumn:(NSTableColumn *)c row:(NSInteger)r
{
    return [c.identifier isEqual:@"a"] ? [self.names[r] substringFromIndex:1] : nil;
}
- (NSInteger)tableView:(NSTableView *)t nextTypeSelectMatchFromRow:(NSInteger)from toRow:(NSInteger)to forString:(NSString *)s
{
    printf("  delegate search from %ld to %ld for %s\n", (long)from, (long)to, s.UTF8String);
    return self.names.count - 1;
}
- (BOOL)tableView:(NSTableView *)t shouldTypeSelectForEvent:(NSEvent *)e withCurrentSearchString:(NSString *)s
{
    printf("  should type select %s, current %s\n", e.characters.UTF8String, s ? s.UTF8String : "nil");
    return ![e.characters isEqualToString:@"c"];
}
- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)c row:(NSInteger)r
{
    NSTableCellView *v = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 100, 17)];
    NSTextField *f = [NSTextField labelWithString:[c.identifier isEqual:@"a"] ? self.names[r] : @"-"];
    v.textField = f;
    [v addSubview:f];
    return v;
}
/* outline: two groups */
- (NSInteger)outlineView:(NSOutlineView *)o numberOfChildrenOfItem:(id)item
{
    return item ? [item[@"kids"] count] : self.names.count;
}
- (id)outlineView:(NSOutlineView *)o child:(NSInteger)i ofItem:(id)item { return item ? item[@"kids"][i] : self.names[i]; }
- (BOOL)outlineView:(NSOutlineView *)o isItemExpandable:(id)item { return [item[@"kids"] count] > 0; }
- (id)outlineView:(NSOutlineView *)o objectValueForTableColumn:(NSTableColumn *)c byItem:(id)item { return item[@"name"]; }
@end

static double skew;

static void
type(NSTableView *t, NSString *s, double wait)
{
    NSEvent *e = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
                                  timestamp:[NSProcessInfo processInfo].systemUptime + skew windowNumber:t.window.windowNumber
                                    context:nil characters:s charactersIgnoringModifiers:s isARepeat:NO keyCode:0];
    [t keyDown:e];
    printf("%s -> %ld\n", s.UTF8String, (long)t.selectedRow);
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:wait]];
}

int
main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 300, 300) styleMask:NSWindowStyleMaskTitled
                                                    backing:NSBackingStoreBuffered defer:YES];
        NSTableView *t = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 300, 300)];
        for (NSString *i in @[ @"a", @"b" ])
            [t addTableColumn:[[NSTableColumn alloc] initWithIdentifier:i]];
        DS *d = [DS new];
        d.names = @[ @"Apple", @"apricot", @"Banana", @"blueberry", @"Cherry", @"zeta", @"Éclair" ];
        t.dataSource = d;
        t.delegate = d;
        [w.contentView addSubview:t];
        [w makeFirstResponder:t];
        printf("allows %d\n", t.allowsTypeSelect);

        printf("growing:\n");
        for (NSString *s in @[ @"b", @"l", @"u", @"x" ])
            type(t, s, 0.05);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.6]];
        printf("stepping:\n");
        for (NSString *s in @[ @"a", @"a", @"a", @"z", @"e" ])
            type(t, s, s == (id)@"z" ? 0.05 : 1.6);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.6]];
        printf("diacritics, event time ignored:\n");
        skew = 10;
        type(t, @"e", 0.05);
        type(t, @"c", 1.6);
        skew = 0;
        printf("space, command and arrows:\n");
        type(t, @" ", 0.05);
        NSEvent *cmd = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand
                                       timestamp:0 windowNumber:w.windowNumber context:nil characters:@"b"
                     charactersIgnoringModifiers:@"b" isARepeat:NO keyCode:11];
        [t keyDown:cmd];
        printf("cmd-b -> %ld\n", (long)t.selectedRow);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.6]];

        printf("not allowed:\n");
        t.allowsTypeSelect = NO;
        type(t, @"b", 0.05);
        t.allowsTypeSelect = YES;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.6]];

        printf("delegate strings:\n");
        d.mode = 1;
        t.delegate = nil;
        t.delegate = d;
        [t deselectAll:nil];
        type(t, @"p", 0.05);
        type(t, @"r", 1.6);
        type(t, @"z", 1.6);
        printf("delegate search:\n");
        d.mode = 2;
        t.delegate = nil;
        t.delegate = d;
        [t selectRowIndexes:[NSIndexSet indexSetWithIndex:2] byExtendingSelection:NO];
        type(t, @"q", 0.05);
        type(t, @"q", 1.6);
        [t deselectAll:nil];
        type(t, @"q", 1.6);
        printf("delegate refuses c:\n");
        d.mode = 3;
        t.delegate = nil;
        t.delegate = d;
        [t deselectAll:nil];
        type(t, @"b", 0.05);
        type(t, @"c", 0.05);
        type(t, @"l", 1.6);

        printf("view-based:\n");
        d.mode = 4;
        NSTableView *v = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 300, 300)];
        for (NSString *i in @[ @"a", @"b" ])
            [v addTableColumn:[[NSTableColumn alloc] initWithIdentifier:i]];
        v.dataSource = d;
        v.delegate = d;
        [w.contentView addSubview:v];
        [w makeFirstResponder:v];
        type(v, @"c", 0.05);
        type(v, @"-", 1.6);

        printf("outline:\n");
        DS *od = [DS new];
        od.names = @[
            @{ @"name" : @"Fruit", @"kids" : @[ @{ @"name" : @"Fig" }, @{ @"name" : @"Grape" } ] },
            @{ @"name" : @"Grains", @"kids" : @[ @{ @"name" : @"Rice" } ] },
        ];
        NSOutlineView *o = [[NSOutlineView alloc] initWithFrame:NSMakeRect(0, 0, 300, 300)];
        NSTableColumn *oc = [[NSTableColumn alloc] initWithIdentifier:@"a"];
        [o addTableColumn:oc];
        o.outlineTableColumn = oc;
        o.dataSource = od;
        o.delegate = od;
        [w.contentView addSubview:o];
        [w makeFirstResponder:o];
        type(o, @"g", 1.6);
        type(o, @"r", 1.6);
        [o expandItem:nil expandChildren:YES];
        type(o, @"g", 1.6);
        type(o, @"r", 1.6);
    }
    return 0;
}
