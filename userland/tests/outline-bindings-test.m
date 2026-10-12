/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Outline views bound to a tree controller: the bindings a column's value binding
 * makes on the outline view, the rows and their items, expanding, selection both ways
 * (by index path), insertion and removal through the controller, editing a value,
 * and a view-based outline's cell views. Compared with Apple's.
 */
#import <AppKit/AppKit.h>

static NSString *
path_string(NSIndexPath *p)
{
    if (!p)
        return @"nil";
    NSMutableArray *parts = [NSMutableArray array];
    for (NSUInteger i = 0; i < p.length; i++)
        [parts addObject:@([p indexAtPosition:i]).stringValue];
    return [parts componentsJoinedByString:@"."];
}

static NSString *
paths_string(NSArray *paths)
{
    NSMutableArray *a = [NSMutableArray array];
    for (NSIndexPath *p in paths)
        [a addObject:path_string(p)];
    return [NSString stringWithFormat:@"[%@]", [a componentsJoinedByString:@" "]];
}

static NSMutableDictionary *
node(NSString *name, NSArray *kids)
{
    return [@{ @"name" : name, @"children" : [kids mutableCopy] ?: [NSMutableArray array] } mutableCopy];
}

/* The rows as name/level, expanded items marked +, expandable ones >. */
static NSString *
rows_string(NSOutlineView *ov)
{
    NSMutableArray *a = [NSMutableArray array];
    for (NSInteger r = 0; r < ov.numberOfRows; r++) {
        id item = [ov itemAtRow:r];
        NSCell *c = [ov preparedCellAtColumn:0 row:r];
        [a addObject:[NSString stringWithFormat:@"%@/%ld%@", c.objectValue ?: @"nil", (long)[ov levelForRow:r],
                                               [ov isItemExpanded:item] ? @"+" : ([ov isExpandable:item] ? @">" : @"")]];
    }
    return [NSString stringWithFormat:@"[%@]", [a componentsJoinedByString:@" "]];
}

static NSString *
rows_of(NSOutlineView *ov)
{
    NSMutableArray *a = [NSMutableArray array];
    [ov.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) { [a addObject:@(i).stringValue]; }];
    return [NSString stringWithFormat:@"{%@}", [a componentsJoinedByString:@" "]];
}

static void
bindings(NSObject *o)
{
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *b in @[ NSContentBinding, NSSelectionIndexPathsBinding, NSSortDescriptorsBinding, NSSelectionIndexesBinding ]) {
        NSDictionary *info = [o infoForBinding:b];
        if (info)
            [a addObject:[NSString stringWithFormat:@"%@->%@", b, info[NSObservedKeyPathKey]]];
    }
    printf("  bindings: %s\n", [a componentsJoinedByString:@", "].UTF8String);
}

@interface Views : NSObject <NSOutlineViewDelegate>
@end

@implementation Views
- (NSView *)outlineView:(NSOutlineView *)ov viewForTableColumn:(NSTableColumn *)column item:(id)item
{
    NSTableCellView *v = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 100, 17)];
    NSTextField *f = [NSTextField labelWithString:@""];
    v.textField = f;
    [v addSubview:f];
    [f bind:NSValueBinding toObject:v withKeyPath:@"objectValue.name" options:nil];
    return v;
}
@end

int
main(void)
{
    @autoreleasepool {
        NSMutableArray *content = [@[
            node(@"fruit", @[ node(@"apple", nil), node(@"pear", @[ node(@"conference", nil) ]) ]),
            node(@"veg", @[ node(@"leek", nil) ]),
            node(@"salt", nil),
        ] mutableCopy];
        NSTreeController *tc = [[NSTreeController alloc] init];
        tc.childrenKeyPath = @"children";
        tc.objectClass = [NSMutableDictionary class];
        tc.content = content;

        NSOutlineView *ov = [[NSOutlineView alloc] initWithFrame:NSMakeRect(0, 0, 200, 300)];
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"name"];
        [ov addTableColumn:col];
        ov.outlineTableColumn = col;
        [col bind:NSValueBinding toObject:tc withKeyPath:@"arrangedObjects.name" options:nil];
        printf("column bound:\n");
        bindings(ov);
        printf("  rows %s, data source %s\n", rows_string(ov).UTF8String, ov.dataSource ? "set" : "nil");
        id item0 = [ov itemAtRow:0];
        printf("  item is tree node %d, represented %s, index path %s, parent %s\n", [item0 isKindOfClass:[NSTreeNode class]],
            [[item0 representedObject][@"name"] UTF8String], path_string([item0 indexPath]).UTF8String,
            [ov parentForItem:item0] ? "set" : "nil");
        printf("  item is arranged node %d, children %ld\n",
            item0 == [[tc arrangedObjects] descendantNodeAtIndexPath:[NSIndexPath indexPathWithIndex:0]],
            (long)[ov numberOfChildrenOfItem:item0]);

        [ov expandItem:item0];
        printf("expand fruit: %s\n", rows_string(ov).UTF8String);
        [ov expandItem:nil expandChildren:YES];
        printf("expand all: %s\n", rows_string(ov).UTF8String);
        [ov collapseItem:[ov itemAtRow:5]];
        printf("collapse veg: %s\n", rows_string(ov).UTF8String);

        /* selection from the outline view */
        [ov selectRowIndexes:[NSIndexSet indexSetWithIndex:2] byExtendingSelection:NO];
        printf("select row 2: controller %s, selected %s\n", paths_string(tc.selectionIndexPaths).UTF8String,
            [[tc.selectedObjects.firstObject valueForKey:@"name"] UTF8String]);
        [ov selectRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(3, 3)] byExtendingSelection:YES];
        printf("extend to 3-5: controller %s\n", paths_string(tc.selectionIndexPaths).UTF8String);

        /* selection from the controller */
        [tc setSelectionIndexPath:[NSIndexPath indexPathWithIndexes:(NSUInteger[]){1, 0} length:2]];
        printf("controller selects 1.0: rows %s, selected rows %s\n", rows_string(ov).UTF8String,
            rows_of(ov).UTF8String);
        [ov collapseItem:nil collapseChildren:YES];
        [tc setSelectionIndexPath:[NSIndexPath indexPathWithIndexes:(NSUInteger[]){0, 1, 0} length:3]];
        printf("collapsed, controller selects 0.1.0: rows %s, selected rows %s\n", rows_string(ov).UTF8String, rows_of(ov).UTF8String);
        [ov collapseItem:[ov itemAtRow:0]];
        printf("collapse fruit: controller %s, selected rows %s\n", paths_string(tc.selectionIndexPaths).UTF8String, rows_of(ov).UTF8String);
        [ov expandItem:nil expandChildren:YES];
        [tc setSelectionIndexPaths:@[]];
        printf("controller clears: selected rows %ld\n", (long)ov.selectedRowIndexes.count);

        /* changes through the controller */
        [tc insertObject:node(@"fig", nil) atArrangedObjectIndexPath:[NSIndexPath indexPathWithIndexes:(NSUInteger[]){0, 1} length:2]];
        printf("insert fig at 0.1: %s, selected rows %s\n", rows_string(ov).UTF8String, rows_of(ov).UTF8String);
        [tc removeObjectAtArrangedObjectIndexPath:[NSIndexPath indexPathWithIndex:2]];
        printf("remove salt: %s\n", rows_string(ov).UTF8String);
        [tc insertObject:node(@"herbs", @[ node(@"mint", nil) ]) atArrangedObjectIndexPath:[NSIndexPath indexPathWithIndex:0]];
        printf("insert herbs at 0: %s\n", rows_string(ov).UTF8String);
        [tc setSelectionIndexPaths:@[]];

        /* sorting the controller */
        tc.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:NO] ];
        printf("sorted descending: %s\n", rows_string(ov).UTF8String);
        tc.sortDescriptors = @[];

        /* the column's value pushed back */
        NSInteger r = [ov rowForItem:[[tc arrangedObjects] descendantNodeAtIndexPath:[NSIndexPath indexPathWithIndexes:(NSUInteger[]){1, 0} length:2]]];
        id info = [col infoForBinding:NSValueBinding];
        printf("row of 1.0: %ld, value binding %s\n", (long)r, [info[NSObservedKeyPathKey] UTF8String]);

        /* content bound directly, no column binding */
        NSOutlineView *plain = [[NSOutlineView alloc] initWithFrame:NSMakeRect(0, 0, 200, 300)];
        NSTableColumn *pc = [[NSTableColumn alloc] initWithIdentifier:@"x"];
        [plain addTableColumn:pc];
        plain.outlineTableColumn = pc;
        [plain bind:NSContentBinding toObject:tc withKeyPath:@"arrangedObjects" options:nil];
        printf("content bound: rows %ld, item 0 %s\n", (long)plain.numberOfRows,
            [[[plain itemAtRow:0] representedObject][@"name"] UTF8String]);
        bindings(plain);

        /* view-based */
        NSOutlineView *vb = [[NSOutlineView alloc] initWithFrame:NSMakeRect(0, 0, 200, 300)];
        NSTableColumn *vc = [[NSTableColumn alloc] initWithIdentifier:@"v"];
        [vb addTableColumn:vc];
        vb.outlineTableColumn = vc;
        Views *views = [Views new];
        vb.delegate = views;
        [vb bind:NSContentBinding toObject:tc withKeyPath:@"arrangedObjects" options:nil];
        [vb bind:NSSelectionIndexPathsBinding toObject:tc withKeyPath:NSSelectionIndexPathsBinding options:nil];
        NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 200, 300)];
        sv.documentView = vb;
        [vb expandItem:[vb itemAtRow:1]];
        [vb layoutSubtreeIfNeeded];
        NSTableCellView *cv = [vb viewAtColumn:0 row:2 makeIfNecessary:YES];
        printf("view-based: rows %ld, cell object is item %d, is represented object %d, label %s\n", (long)vb.numberOfRows,
            cv.objectValue == [vb itemAtRow:2], cv.objectValue == [[vb itemAtRow:2] representedObject], cv.textField.stringValue.UTF8String);
        [vb selectRowIndexes:[NSIndexSet indexSetWithIndex:2] byExtendingSelection:NO];
        printf("  select row 2: controller %s\n", paths_string(tc.selectionIndexPaths).UTF8String);
        [tc setSelectionIndexPath:[NSIndexPath indexPathWithIndex:3]];
        printf("  controller selects 3: row %ld\n", (long)vb.selectedRow);
        [vb unbind:NSContentBinding];
        printf("  unbound: rows %ld\n", (long)vb.numberOfRows);
    }
    return 0;
}
