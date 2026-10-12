/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSTreeNode and NSTreeController: nodes, index paths, sorting; a controller over
 * dictionaries and over objects (children, count and leaf key paths), its arranged
 * nodes, selection by index path, insertion, removal and moves, sort descriptors, and
 * the KVO it posts. Compared with Apple's.
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

static NSString *
names(NSArray *objects)
{
    NSMutableArray *a = [NSMutableArray array];
    for (id o in objects)
        [a addObject:[o valueForKey:@"name"] ?: @"?"];
    return [NSString stringWithFormat:@"[%@]", [a componentsJoinedByString:@" "]];
}

/* A node's subtree, as name(children...). */
static NSString *
tree_string(NSTreeNode *node)
{
    NSMutableString *s = [NSMutableString string];
    id o = node.representedObject;
    [s appendString:o ? ([o valueForKey:@"name"] ?: @"?") : @"root"];
    if (node.childNodes.count) {
        [s appendString:@"("];
        BOOL first = YES;
        for (NSTreeNode *c in node.childNodes) {
            if (!first)
                [s appendString:@" "];
            first = NO;
            [s appendString:tree_string(c)];
        }
        [s appendString:@")"];
    }
    return s;
}

static NSMutableDictionary *
item(NSString *name, NSArray *children)
{
    NSMutableDictionary *d = [@{@"name" : name} mutableCopy];
    if (children)
        d[@"children"] = [children mutableCopy];
    else
        d[@"isLeaf"] = @YES;
    return d;
}

@interface Observer : NSObject
@property NSMutableArray *log;
@end
@implementation Observer
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    [self.log addObject:keyPath];
}
@end

@interface Folder : NSObject
@property (copy) NSString *name;
@property NSMutableArray *kids;
@property (readonly) NSUInteger kidCount;
@end
@implementation Folder
- (NSUInteger)kidCount { return self.kids.count; }
@end

int
main(void)
{
    @autoreleasepool {
        printf("NSTreeController\n");

        /* nodes */
        NSTreeNode *root = [NSTreeNode treeNodeWithRepresentedObject:nil];
        NSTreeNode *b = [NSTreeNode treeNodeWithRepresentedObject:@{@"name" : @"b"}];
        NSTreeNode *a = [NSTreeNode treeNodeWithRepresentedObject:@{@"name" : @"a"}];
        NSTreeNode *a1 = [NSTreeNode treeNodeWithRepresentedObject:@{@"name" : @"a1"}];
        [[root mutableChildNodes] addObject:b];
        [[root mutableChildNodes] addObject:a];
        [[a mutableChildNodes] addObject:a1];
        printf("nodes: %s, a1 at %s, parent of a1 %s, leaf %d %d\n", tree_string(root).UTF8String, path_string(a1.indexPath).UTF8String,
            [a1.parentNode.representedObject[@"name"] UTF8String], a.isLeaf, a1.isLeaf);
        printf("  descendant 1.0: %s, root path length %lu\n",
            [[root descendantNodeAtIndexPath:[NSIndexPath indexPathWithIndexes:(NSUInteger[]){1, 0} length:2]].representedObject[@"name"] UTF8String],
            (unsigned long)root.indexPath.length);
        [root sortWithSortDescriptors:@[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ] recursively:YES];
        printf("  sorted: %s\n", tree_string(root).UTF8String);
        [[root mutableChildNodes] removeObject:a];
        printf("  removed a: parent %s, %s\n", a.parentNode ? "set" : "nil", tree_string(root).UTF8String);

        /* a controller over dictionaries */
        NSMutableArray *content = [@[
            item(@"Fruit", @[ item(@"Pear", nil), item(@"Apple", nil) ]),
            item(@"Veg", @[ item(@"Leek", nil) ]),
            item(@"Bread", nil),
        ] mutableCopy];
        NSTreeController *tc = [[NSTreeController alloc] init];
        tc.childrenKeyPath = @"children";
        tc.leafKeyPath = @"isLeaf";
        Observer *ob = [Observer new];
        ob.log = [NSMutableArray array];
        for (NSString *k in @[ @"arrangedObjects", @"selectionIndexPaths", @"selectedObjects", @"selectedNodes", @"selection", @"canInsert",
                 @"canInsertChild", @"canAddChild", @"canRemove", @"content" ])
            [tc addObserver:ob forKeyPath:k options:0 context:NULL];
        printf("defaults: avoids empty %d, preserves %d, selects inserted %d, editable %d, count key %s\n", tc.avoidsEmptySelection,
            tc.preservesSelection, tc.selectsInsertedObjects, tc.isEditable, tc.countKeyPath ? tc.countKeyPath.UTF8String : "nil");
        tc.content = content;
        NSTreeNode *arranged = [tc arrangedObjects];
        printf("content set: %s, notified %s\n", tree_string(arranged).UTF8String,
            [[[[NSSet setWithArray:ob.log] allObjects] sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","].UTF8String);
        printf("  arranged responds: childNodes %d, descendant %d, node at 0.1 %s\n", [arranged respondsToSelector:@selector(childNodes)],
            [arranged respondsToSelector:@selector(descendantNodeAtIndexPath:)],
            [[[arranged descendantNodeAtIndexPath:[NSIndexPath indexPathWithIndexes:(NSUInteger[]){0, 1} length:2]] representedObject][@"name"] UTF8String]);
        printf("  selection after content: %s %s\n", paths_string(tc.selectionIndexPaths).UTF8String, names(tc.selectedObjects).UTF8String);
        NSTreeNode *pear = [arranged descendantNodeAtIndexPath:[NSIndexPath indexPathWithIndexes:(NSUInteger[]){0, 0} length:2]];
        printf("  pear: leaf %d, path %s, same node again %d\n", pear.isLeaf, path_string(pear.indexPath).UTF8String,
            pear == [arranged descendantNodeAtIndexPath:[NSIndexPath indexPathWithIndexes:(NSUInteger[]){0, 0} length:2]]);

        /* selection */
        [ob.log removeAllObjects];
        BOOL changed = [tc setSelectionIndexPath:[NSIndexPath indexPathWithIndexes:(NSUInteger[]){1, 0} length:2]];
        printf("select 1.0: %d %s %s nodes %lu, notified %lu\n", changed, paths_string(tc.selectionIndexPaths).UTF8String,
            names(tc.selectedObjects).UTF8String, (unsigned long)tc.selectedNodes.count, (unsigned long)ob.log.count);
        printf("  selection proxy name: %s\n", [[[tc selection] valueForKey:@"name"] description].UTF8String);
        [tc addSelectionIndexPaths:@[ [NSIndexPath indexPathWithIndex:2], [NSIndexPath indexPathWithIndexes:(NSUInteger[]){0, 1} length:2] ]];
        printf("  added: %s %s, proxy %s\n", paths_string(tc.selectionIndexPaths).UTF8String, names(tc.selectedObjects).UTF8String,
            [[[tc selection] valueForKey:@"name"] description].UTF8String);
        [tc removeSelectionIndexPaths:@[ [NSIndexPath indexPathWithIndex:2] ]];
        printf("  removed: %s, same set again changes %d\n", paths_string(tc.selectionIndexPaths).UTF8String,
            [tc setSelectionIndexPaths:tc.selectionIndexPaths]);
        printf("  can: insert %d child %d add child %d remove %d add %d\n", tc.canInsert, tc.canInsertChild, tc.canAddChild, tc.canRemove,
            tc.canAdd);

        /* insertion and removal */
        [ob.log removeAllObjects];
        [tc insertObject:item(@"Rye", nil) atArrangedObjectIndexPath:[NSIndexPath indexPathWithIndexes:(NSUInteger[]){2} length:1]];
        printf("insert at 2: %s, content count %lu, selection %s %s\n", tree_string([tc arrangedObjects]).UTF8String,
            (unsigned long)content.count, paths_string(tc.selectionIndexPaths).UTF8String, names(tc.selectedObjects).UTF8String);
        printf("  notified %s\n", [[[[NSSet setWithArray:ob.log] allObjects] sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","].UTF8String);
        [tc insertObject:item(@"Plum", nil) atArrangedObjectIndexPath:[NSIndexPath indexPathWithIndexes:(NSUInteger[]){0, 1} length:2]];
        printf("insert at 0.1: %s, fruit children %lu, selection %s\n", tree_string([tc arrangedObjects]).UTF8String,
            (unsigned long)[content[0][@"children"] count], paths_string(tc.selectionIndexPaths).UTF8String);
        [tc removeObjectAtArrangedObjectIndexPath:[NSIndexPath indexPathWithIndexes:(NSUInteger[]){0, 0} length:2]];
        printf("remove 0.0: %s, selection %s %s\n", tree_string([tc arrangedObjects]).UTF8String, paths_string(tc.selectionIndexPaths).UTF8String,
            names(tc.selectedObjects).UTF8String);
        [tc setSelectionIndexPath:[NSIndexPath indexPathWithIndex:1]];
        [tc remove:nil];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        printf("remove: action: %s, selection %s\n", tree_string([tc arrangedObjects]).UTF8String, paths_string(tc.selectionIndexPaths).UTF8String);

        /* moves */
        NSTreeNode *rye = [[tc arrangedObjects] descendantNodeAtIndexPath:[NSIndexPath indexPathWithIndex:2]];
        [tc moveNode:rye toIndexPath:[NSIndexPath indexPathWithIndexes:(NSUInteger[]){0, 0} length:2]];
        printf("move rye to 0.0: %s, content %s\n", tree_string([tc arrangedObjects]).UTF8String, names(content).UTF8String);

        /* sorting */
        tc.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ];
        printf("sorted: %s, content order kept %s\n", tree_string([tc arrangedObjects]).UTF8String, names(content).UTF8String);
        [tc insertObject:item(@"Apricot", nil) atArrangedObjectIndexPath:[NSIndexPath indexPathWithIndexes:(NSUInteger[]){0, 0} length:2]];
        printf("insert while sorted: %s\n", tree_string([tc arrangedObjects]).UTF8String);
        [tc rearrangeObjects];
        printf("rearranged: %s\n", tree_string([tc arrangedObjects]).UTF8String);

        /* add and add child */
        tc.sortDescriptors = @[];
        tc.selectsInsertedObjects = YES;
        [tc setSelectionIndexPath:[NSIndexPath indexPathWithIndex:0]];
        [tc addChild:nil];
        [tc add:nil];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        printf("add child, add: %lu top, fruit kids %lu, selection %s, new class %s\n", (unsigned long)[[tc arrangedObjects] childNodes].count,
            (unsigned long)[content[0][@"children"] count], paths_string(tc.selectionIndexPaths).UTF8String,
            [tc.selectedObjects.firstObject isKindOfClass:[NSMutableDictionary class]] ? "mutable dictionary" : "other");
        for (NSString *k in @[ @"arrangedObjects", @"selectionIndexPaths", @"selectedObjects", @"selectedNodes", @"selection", @"canInsert",
                 @"canInsertChild", @"canAddChild", @"canRemove", @"content" ])
            [tc removeObserver:ob forKeyPath:k];

        /* objects with a count key path */
        Folder *docs = [Folder new], *pics = [Folder new], *empty = [Folder new];
        docs.name = @"docs", pics.name = @"pics", empty.name = @"empty";
        docs.kids = [@[ pics ] mutableCopy];
        pics.kids = [NSMutableArray array];
        empty.kids = [NSMutableArray array];
        NSTreeController *fc = [[NSTreeController alloc] initWithContent:@[ docs, empty ]];
        fc.childrenKeyPath = @"kids";
        fc.countKeyPath = @"kidCount";
        NSTreeNode *top = [fc arrangedObjects];
        NSTreeNode *emptyNode = [top descendantNodeAtIndexPath:[NSIndexPath indexPathWithIndex:1]];
        printf("folders: %s, empty leaf %d, docs leaf %d, child key for node %s, count key for node %s\n", tree_string(top).UTF8String,
            emptyNode.isLeaf, [top descendantNodeAtIndexPath:[NSIndexPath indexPathWithIndex:0]].isLeaf,
            [fc childrenKeyPathForNode:emptyNode].UTF8String, [fc countKeyPathForNode:emptyNode].UTF8String);
        [fc setSelectionIndexPath:[NSIndexPath indexPathWithIndexes:(NSUInteger[]){0, 0} length:2]];
        printf("  selected %s, proxy %s\n", names(fc.selectedObjects).UTF8String, [[[fc selection] valueForKey:@"name"] description].UTF8String);
        [[fc selection] setValue:@"photos" forKey:@"name"];
        printf("  renamed through proxy: %s\n", pics.name.UTF8String);
        [docs.kids addObject:empty];
        printf("  kvo-unaware change: %s", tree_string([fc arrangedObjects]).UTF8String);
        [fc rearrangeObjects];
        printf(", after rearrange %s\n", tree_string([fc arrangedObjects]).UTF8String);
    }
    return 0;
}
