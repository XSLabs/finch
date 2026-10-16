// SPDX-License-Identifier: MIT OR Apache-2.0
#import "CDInternal.h"

@interface CDFetchedSection : NSObject <NSFetchedResultsSectionInfo>
- (instancetype)initWithName:(NSString *)name objects:(NSArray *)objects;
@end

@interface NSFetchedResultsController (FinchInternal)
- (void)notifyDelegateFrom:(NSArray *)oldObjects to:(NSArray *)newObjects;
- (void)contextObjectsDidChange:(NSNotification *)notification;
@end

@implementation CDFetchedSection
- (instancetype)initWithName:(NSString *)name objects:(NSArray *)objects {
    self = [super init];
    if (self) { CDSet(self, @"name", [name copy]); CDSet(self, @"objects", [objects copy]); }
    return self;
}
- (NSString *)name { return CDGet(self, @"name"); }
- (NSString *)indexTitle { return self.name.length ? [self.name substringToIndex:1] : @""; }
- (NSUInteger)numberOfObjects { return [self.objects count]; }
- (NSArray *)objects { return CDGet(self, @"objects"); }
@end

static NSIndexPath *CDIndexPath(NSUInteger section, NSUInteger row) {
    NSUInteger indexes[] = {section, row};
    return [NSIndexPath indexPathWithIndexes:indexes length:2];
}

@implementation NSFetchedResultsController
- (instancetype)initWithFetchRequest:(NSFetchRequest *)request managedObjectContext:(NSManagedObjectContext *)context sectionNameKeyPath:(NSString *)sectionNameKeyPath cacheName:(NSString *)cacheName {
    self = [super init];
    if (self) {
        CDSet(self, @"fetchRequest", [request copy]);
        CDSet(self, @"context", [context retain]);
        CDSet(self, @"sectionNameKeyPath", [sectionNameKeyPath copy]);
        CDSet(self, @"cacheName", [cacheName copy]);
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(contextObjectsDidChange:)
                                                     name:NSManagedObjectContextObjectsDidChangeNotification object:context];
    }
    return self;
}
- (NSFetchRequest *)fetchRequest { return CDGet(self, @"fetchRequest"); }
- (NSManagedObjectContext *)managedObjectContext { return CDGet(self, @"context"); }
- (NSString *)sectionNameKeyPath { return CDGet(self, @"sectionNameKeyPath"); }
- (NSString *)cacheName { return CDGet(self, @"cacheName"); }
- (id<NSFetchedResultsControllerDelegate>)delegate { return [CDGet(self, @"delegate") nonretainedObjectValue]; }
- (void)setDelegate:(id<NSFetchedResultsControllerDelegate>)value {
    CDSet(self, @"delegate", value ? [NSValue valueWithNonretainedObject:value] : nil);
}
- (NSArray *)fetchedObjects { return CDGet(self, @"fetchedObjects"); }
- (NSArray *)sections { return CDGet(self, @"sections") ?: [NSArray array]; }
- (NSArray *)sectionIndexTitles {
    NSMutableArray *titles = [NSMutableArray array];
    for (id<NSFetchedResultsSectionInfo> section in self.sections)
        if (section.indexTitle && ![titles containsObject:section.indexTitle]) [titles addObject:section.indexTitle];
    return titles;
}
- (nullable NSString *)sectionIndexTitleForSectionName:(NSString *)sectionName {
    if (!sectionName.length) return @"";
    return [sectionName substringToIndex:1];
}
- (NSInteger)sectionForSectionIndexTitle:(NSString *)title atIndex:(NSInteger)sectionIndex {
    if (sectionIndex >= 0 && (NSUInteger)sectionIndex < self.sections.count) return sectionIndex;
    NSArray *titles = self.sectionIndexTitles;
    NSUInteger index = [titles indexOfObject:title];
    return index == NSNotFound ? NSNotFound : (NSInteger)index;
}
+ (void)deleteCacheWithName:(NSString *)name { (void)name; }
- (BOOL)performFetch:(NSError **)error {
    NSArray *oldObjects = self.fetchedObjects ?: [NSArray array];
    NSArray *objects = [self.managedObjectContext executeFetchRequest:self.fetchRequest error:error];
    if (!objects) return NO;
    CDSet(self, @"fetchedObjects", [objects copy]);
    NSMutableArray *sections = [NSMutableArray array];
    NSMutableArray *current = [NSMutableArray array];
    NSString *currentName = nil;
    for (NSManagedObject *object in objects) {
        id value = self.sectionNameKeyPath ? [object valueForKeyPath:self.sectionNameKeyPath] : @"";
        NSString *name = value ? [value description] : @"";
        if (!currentName) currentName = name;
        if (![currentName isEqualToString:name]) {
            [sections addObject:[[[CDFetchedSection alloc] initWithName:currentName objects:current] autorelease]];
            [current removeAllObjects];
            currentName = name;
        }
        [current addObject:object];
    }
    if (currentName) [sections addObject:[[[CDFetchedSection alloc] initWithName:currentName objects:current] autorelease]];
    CDSet(self, @"sections", [sections copy]);
    [self notifyDelegateFrom:oldObjects to:objects];
    return YES;
}
- (void)notifyDelegateFrom:(NSArray *)oldObjects to:(NSArray *)newObjects {
    id<NSFetchedResultsControllerDelegate> delegate = self.delegate;
    if (!delegate || oldObjects == newObjects) return;
    NSMutableDictionary *oldPositions = [NSMutableDictionary dictionary];
    NSMutableDictionary *newPositions = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < oldObjects.count; i++) oldPositions[[[oldObjects objectAtIndex:i] objectID]] = CDIndexPath(0, i);
    for (NSUInteger i = 0; i < newObjects.count; i++) newPositions[[[newObjects objectAtIndex:i] objectID]] = CDIndexPath(0, i);
    if ([delegate respondsToSelector:@selector(controllerWillChangeContent:)]) [delegate controllerWillChangeContent:self];
    for (NSManagedObject *object in oldObjects) {
        NSIndexPath *oldPath = [oldPositions objectForKey:object.objectID];
        if (![newPositions objectForKey:object.objectID] && [delegate respondsToSelector:@selector(controller:didChangeObject:atIndexPath:forChangeType:newIndexPath:)])
            [delegate controller:self didChangeObject:object atIndexPath:oldPath forChangeType:NSFetchedResultsChangeDelete newIndexPath:nil];
    }
    for (NSManagedObject *object in newObjects) {
        NSIndexPath *newPath = [newPositions objectForKey:object.objectID];
        NSIndexPath *oldPath = [oldPositions objectForKey:object.objectID];
        if (!oldPath) {
            if ([delegate respondsToSelector:@selector(controller:didChangeObject:atIndexPath:forChangeType:newIndexPath:)])
                [delegate controller:self didChangeObject:object atIndexPath:nil forChangeType:NSFetchedResultsChangeInsert newIndexPath:newPath];
        } else if (![oldPath isEqual:newPath]) {
            if ([delegate respondsToSelector:@selector(controller:didChangeObject:atIndexPath:forChangeType:newIndexPath:)])
                [delegate controller:self didChangeObject:object atIndexPath:oldPath forChangeType:NSFetchedResultsChangeMove newIndexPath:newPath];
        } else if (object.isUpdated && [delegate respondsToSelector:@selector(controller:didChangeObject:atIndexPath:forChangeType:newIndexPath:)]) {
            [delegate controller:self didChangeObject:object atIndexPath:oldPath forChangeType:NSFetchedResultsChangeUpdate newIndexPath:nil];
        }
    }
    if ([delegate respondsToSelector:@selector(controllerDidChangeContent:)]) [delegate controllerDidChangeContent:self];
}
- (void)contextObjectsDidChange:(NSNotification *)notification {
    (void)notification;
    if (CDGet(self, @"fetchedObjects")) [self performFetch:NULL];
}
- (id)objectAtIndexPath:(NSIndexPath *)indexPath {
    NSUInteger section = [indexPath indexAtPosition:0];
    NSUInteger row = [indexPath indexAtPosition:1];
    if (section >= self.sections.count) return nil;
    NSArray *objects = [[self.sections objectAtIndex:section] objects];
    return row < objects.count ? [objects objectAtIndex:row] : nil;
}
- (NSIndexPath *)indexPathForObject:(id)object {
    NSUInteger index = [self.fetchedObjects indexOfObject:object];
    return index == NSNotFound ? nil : CDIndexPath(0, index);
}
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [super dealloc];
}
@end
