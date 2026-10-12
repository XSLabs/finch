/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* NSTreeNode's storage, for NSTreeController's nodes (NSController.m). */
#import <AppKit/NSTreeNode.h>

@interface NSTreeNode (FinchStorage)
/* The children as stored, without building them (nil until there are any). */
- (NSMutableArray *)_finchChildStorage;
/* Replaces the children with these nodes (each moved here from any other parent). */
- (void)_finchSetChildren:(NSArray *)children;
- (void)_finchInsertChild:(NSTreeNode *)child atIndex:(NSUInteger)index;
- (void)_finchRemoveChildAtIndex:(NSUInteger)index;
@end
