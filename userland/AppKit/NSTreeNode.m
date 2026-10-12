/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSTreeNode: a node of a tree, holding an object; its children are nodes too. A node
 * added under another leaves the parent it had, as Apple's does; a node with no
 * children is a leaf. NSTreeController's nodes are a subclass (NSController.m).
 */
#import <AppKit/AppKit.h>
#import "NSTreeNode_Finch.h"

@implementation NSTreeNode {
    id _representedObject;
    NSTreeNode *_parent; /* (not retained: the parent holds its children) */
    NSMutableArray *_children;
}

+ (instancetype)treeNodeWithRepresentedObject:(id)modelObject
{
    return [[[self alloc] initWithRepresentedObject:modelObject] autorelease];
}

- (instancetype)initWithRepresentedObject:(id)modelObject
{
    if ((self = [super init]))
        _representedObject = [modelObject retain];
    return self;
}

- (instancetype)init
{
    return [self initWithRepresentedObject:nil];
}

- (void)dealloc
{
    for (NSTreeNode *c in _children)
        c->_parent = nil;
    [_children release];
    [_representedObject release];
    [super dealloc];
}

- (id)representedObject { return _representedObject; }
- (NSTreeNode *)parentNode { return _parent; }
- (BOOL)isLeaf { return [[self childNodes] count] == 0; }

#pragma mark Children

- (NSMutableArray *)_finchChildStorage { return _children; }

- (NSArray *)childNodes
{
    return _children ? [[_children mutableCopy] autorelease] : [NSMutableArray array];
}

- (NSMutableArray *)mutableChildNodes
{
    return [self mutableArrayValueForKey:@"childNodes"];
}

- (NSUInteger)countOfChildNodes { return [[self childNodes] count]; }
- (id)objectInChildNodesAtIndex:(NSUInteger)index { return [[self childNodes] objectAtIndex:index]; }

/* (the node leaves its old parent first; an index past the end appends) */
- (void)_finchInsertChild:(NSTreeNode *)child atIndex:(NSUInteger)index
{
    [child retain];
    NSTreeNode *old = child->_parent;
    if (old) {
        NSUInteger at = [old->_children indexOfObjectIdenticalTo:child];
        if (at != NSNotFound) {
            if (old == self && at < index)
                index--;
            [old _finchRemoveChildAtIndex:at];
        }
    }
    if (!_children)
        _children = [[NSMutableArray alloc] init];
    [_children insertObject:child atIndex:MIN(index, [_children count])];
    child->_parent = self;
    [child release];
}

- (void)_finchRemoveChildAtIndex:(NSUInteger)index
{
    NSTreeNode *child = [_children objectAtIndex:index];
    child->_parent = nil;
    [_children removeObjectAtIndex:index];
}

- (void)_finchSetChildren:(NSArray *)children
{
    NSArray *keep = [[children copy] autorelease];
    for (NSTreeNode *c in _children)
        if (![keep containsObject:c])
            c->_parent = nil;
    for (NSTreeNode *c in keep)
        if (c->_parent && c->_parent != self) {
            NSUInteger at = [c->_parent->_children indexOfObjectIdenticalTo:c];
            if (at != NSNotFound)
                [c->_parent _finchRemoveChildAtIndex:at];
        }
    [_children release];
    _children = [keep count] ? [keep mutableCopy] : nil;
    for (NSTreeNode *c in _children)
        c->_parent = self;
}

- (void)insertObject:(NSTreeNode *)node inChildNodesAtIndex:(NSUInteger)index { [self _finchInsertChild:node atIndex:index]; }
- (void)removeObjectFromChildNodesAtIndex:(NSUInteger)index { [self _finchRemoveChildAtIndex:index]; }

- (void)replaceObjectInChildNodesAtIndex:(NSUInteger)index withObject:(NSTreeNode *)node
{
    [self _finchRemoveChildAtIndex:index];
    [self _finchInsertChild:node atIndex:index];
}

#pragma mark Paths and sorting

- (NSIndexPath *)indexPath
{
    NSMutableArray *indexes = [NSMutableArray array];
    for (NSTreeNode *n = self; n->_parent; n = n->_parent)
        [indexes insertObject:@([n->_parent->_children indexOfObjectIdenticalTo:n]) atIndex:0];
    NSUInteger count = [indexes count], *buf = malloc((count ?: 1) * sizeof *buf);
    for (NSUInteger i = 0; i < count; i++)
        buf[i] = [indexes[i] unsignedIntegerValue];
    NSIndexPath *p = [NSIndexPath indexPathWithIndexes:buf length:count];
    free(buf);
    return p;
}

- (NSTreeNode *)descendantNodeAtIndexPath:(NSIndexPath *)indexPath
{
    NSTreeNode *n = self;
    for (NSUInteger i = 0; n && i < [indexPath length]; i++) {
        NSArray *kids = [n childNodes];
        NSUInteger at = [indexPath indexAtPosition:i];
        n = at < [kids count] ? kids[at] : nil;
    }
    return n;
}

/* (the descriptors' keys are the represented objects') */
static NSArray *
node_descriptors(NSArray *sortDescriptors)
{
    NSMutableArray *out = [NSMutableArray array];
    for (NSSortDescriptor *d in sortDescriptors) {
        NSString *key = d.key ? [@"representedObject." stringByAppendingString:d.key] : @"representedObject";
        NSSortDescriptor *n = d.comparator && !d.selector
                                  ? [NSSortDescriptor sortDescriptorWithKey:key ascending:d.ascending comparator:d.comparator]
                                  : [NSSortDescriptor sortDescriptorWithKey:key ascending:d.ascending selector:d.selector];
        [out addObject:n];
    }
    return out;
}

NSArray *FinchTreeNodeSortDescriptors(NSArray *sortDescriptors) { return node_descriptors(sortDescriptors); }

- (void)sortWithSortDescriptors:(NSArray<NSSortDescriptor *> *)sortDescriptors recursively:(BOOL)recursively
{
    NSArray *kids = [self childNodes];
    if ([sortDescriptors count] && [kids count] > 1)
        [self _finchSetChildren:[kids sortedArrayUsingDescriptors:node_descriptors(sortDescriptors)]];
    if (recursively)
        for (NSTreeNode *c in [self childNodes])
            [c sortWithSortDescriptors:sortDescriptors recursively:YES];
}

/* As Apple's: the node, then its children by index. */
- (NSString *)description
{
    NSMutableString *s = [NSMutableString stringWithFormat:@"<%@: %p>, child nodes {", [self class], self];
    NSArray *kids = [self childNodes];
    for (NSUInteger i = 0; i < [kids count]; i++)
        [s appendFormat:@"\t%lu:%@", (unsigned long)i, kids[i]];
    [s appendString:@"}"];
    return s;
}

@end
