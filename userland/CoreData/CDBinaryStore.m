// SPDX-License-Identifier: MIT OR Apache-2.0
// The binary store (NSBinaryStoreType), an atomic store in Core Data's binary
// format: "CoreData", then big-endian 64-bit words (the format's version, the
// metadata archive's offset and length, the object map archive's offset and
// length, and the last primary key), then two keyed archives. The map is a
// dictionary from primary key to NSDictionaryMapNode: the entity's name, the
// key, the attribute values in the order of the attributes' names followed by a
// null for each relationship, and the related nodes' keys by relationship name.
#import "CDInternal.h"

@interface NSBinaryObjectStore : NSAtomicStore
@end

@interface NSStoreMapNode : NSObject
@end
@implementation NSStoreMapNode
@end

@interface NSDictionaryMapNode : NSStoreMapNode <NSCoding> {
@public
    NSString *_entityName;
    long long _primaryKey;
    NSArray *_values;
    NSDictionary *_related;
}
@end

@implementation NSDictionaryMapNode
- (id)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init])) {
        _entityName = [[coder decodeObjectForKey:@"NSEntityName"] copy];
        _primaryKey = [coder decodeInt64ForKey:@"NSPrimaryKey64"];
        _values = [[coder decodeObjectForKey:@"NSAttributeValues"] copy];
        _related = [[coder decodeObjectForKey:@"NSRelatedNodes"] copy];
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    if ([_related count]) [coder encodeObject:_related forKey:@"NSRelatedNodes"];
    [coder encodeObject:_values forKey:@"NSAttributeValues"];
    [coder encodeInt64:_primaryKey forKey:@"NSPrimaryKey64"];
    [coder encodeObject:_entityName forKey:@"NSEntityName"];
}
- (void)dealloc
{
    [_entityName release];
    [_values release];
    [_related release];
    [super dealloc];
}
@end

static const uint64_t CDBinaryVersion = 0x0000000108040800ULL;

/* The order a node keeps its values in: attributes by name, then relationships by name. */
static NSArray *CDBinaryProperties(NSEntityDescription *entity) {
    NSMutableArray *attributes = [NSMutableArray array], *relationships = [NSMutableArray array];
    for (NSPropertyDescription *property in entity.properties) {
        if (property.isTransient) continue;
        if ([property isKindOfClass:[NSAttributeDescription class]]) [attributes addObject:property];
        else if ([property isKindOfClass:[NSRelationshipDescription class]]) [relationships addObject:property];
    }
    NSSortDescriptor *byName = [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES selector:@selector(compare:)];
    [attributes sortUsingDescriptors:[NSArray arrayWithObject:byName]];
    [relationships sortUsingDescriptors:[NSArray arrayWithObject:byName]];
    return [attributes arrayByAddingObjectsFromArray:relationships];
}

static uint64_t CDBigEndianWord(NSData *data, NSUInteger offset) {
    uint64_t word = 0;
    if (offset + 8 <= [data length]) memcpy(&word, (const uint8_t *)[data bytes] + offset, 8);
    return CFSwapInt64BigToHost(word);
}

static id CDBinaryUnarchive(NSData *data, NSString *key) {
    NSKeyedUnarchiver *unarchiver = [[[NSKeyedUnarchiver alloc] initForReadingFromData:data error:NULL] autorelease];
    unarchiver.requiresSecureCoding = NO;
    id value = [unarchiver decodeObjectForKey:key];
    [unarchiver finishDecoding];
    return value;
}

static NSData *CDBinaryArchive(id value, NSString *key) {
    NSKeyedArchiver *archiver = [[[NSKeyedArchiver alloc] initRequiringSecureCoding:NO] autorelease];
    [archiver encodeObject:value forKey:key];
    [archiver finishEncoding];
    return [archiver encodedData];
}

@implementation NSBinaryObjectStore

- (NSString *)type { return NSBinaryStoreType; }

- (NSData *)_fileData
{
    NSURL *url = self.URL;
    if (!url || ![[NSFileManager defaultManager] fileExistsAtPath:url.path]) return nil;
    NSData *data = [NSData dataWithContentsOfURL:url];
    return [data length] ? data : nil;
}

- (BOOL)loadMetadata:(NSError **)error
{
    NSData *data = [self _fileData];
    NSDictionary *metadata = nil;
    if (data) {
        if ([data length] < 64 || memcmp([data bytes], "CoreData", 8) != 0)
            return CDReturnError(error, CDError(134110, @"The file is not a Core Data binary store."));
        uint64_t metadataOffset = CDBigEndianWord(data, 16), metadataLength = CDBigEndianWord(data, 24);
        if (metadataOffset + metadataLength <= [data length])
            metadata = CDBinaryUnarchive([data subdataWithRange:NSMakeRange((NSUInteger)metadataOffset, (NSUInteger)metadataLength)], @"metadata");
        CDSet(self, @"lastKey", [NSNumber numberWithUnsignedLongLong:CDBigEndianWord(data, 48)]);
        CDSet(self, @"fileData", data);
    } else {
        CDSet(self, @"lastKey", [NSNumber numberWithUnsignedLongLong:0]);
    }
    NSMutableDictionary *full = [NSMutableDictionary dictionaryWithDictionary:metadata ?: [NSDictionary dictionary]];
    if (![full objectForKey:NSStoreUUIDKey]) [full setObject:[[NSUUID UUID] UUIDString] forKey:NSStoreUUIDKey];
    self.metadata = full;
    return YES;
}

- (BOOL)load:(NSError **)error
{
    (void)error;
    NSData *data = CDGet(self, @"fileData");
    if (!data) return YES;
    uint64_t mapOffset = CDBigEndianWord(data, 32), mapLength = CDBigEndianWord(data, 40);
    NSDictionary *map = mapOffset + mapLength <= [data length]
        ? CDBinaryUnarchive([data subdataWithRange:NSMakeRange((NSUInteger)mapOffset, (NSUInteger)mapLength)], @"mapData") : nil;
    NSManagedObjectModel *model = self.persistentStoreCoordinator.managedObjectModel;
    NSMutableDictionary *nodes = [NSMutableDictionary dictionary];
    for (NSNumber *key in map) {
        NSDictionaryMapNode *mapNode = [map objectForKey:key];
        if (![mapNode isKindOfClass:[NSDictionaryMapNode class]]) continue;
        NSEntityDescription *entity = [model.entitiesByName objectForKey:mapNode->_entityName];
        if (!entity) continue;
        NSAtomicStoreCacheNode *node = [[[NSAtomicStoreCacheNode alloc]
            initWithObjectID:[self objectIDForEntity:entity referenceObject:[NSNumber numberWithLongLong:mapNode->_primaryKey]]] autorelease];
        NSMutableDictionary *cache = [NSMutableDictionary dictionary];
        NSArray *properties = CDBinaryProperties(entity);
        for (NSUInteger i = 0; i < [properties count] && i < [mapNode->_values count]; i++) {
            NSPropertyDescription *property = [properties objectAtIndex:i];
            id value = [mapNode->_values objectAtIndex:i];
            if (![property isKindOfClass:[NSAttributeDescription class]] || value == [NSNull null]) continue;
            /* Transformable values are archived as themselves, as Apple's store keeps them. */
            if (value) [cache setObject:value forKey:property.name];
        }
        [node setPropertyCache:cache];
        [nodes setObject:node forKey:[NSNumber numberWithLongLong:mapNode->_primaryKey]];
    }
    for (NSNumber *key in map) {
        NSDictionaryMapNode *mapNode = [map objectForKey:key];
        NSAtomicStoreCacheNode *node = [nodes objectForKey:[NSNumber numberWithLongLong:mapNode->_primaryKey]];
        if (!node) continue;
        NSEntityDescription *entity = node.objectID.entity;
        for (NSString *name in mapNode->_related) {
            NSRelationshipDescription *relationship = [entity.relationshipsByName objectForKey:name];
            if (!relationship) continue;
            NSMutableArray *targets = [NSMutableArray array];
            for (NSNumber *target in [mapNode->_related objectForKey:name]) {
                NSAtomicStoreCacheNode *other = [nodes objectForKey:target];
                if (other) [targets addObject:other];
            }
            if (relationship.isToMany)
                [[node propertyCache] setObject:relationship.isOrdered ? (id)[NSMutableOrderedSet orderedSetWithArray:targets]
                                                                       : (id)[NSMutableSet setWithArray:targets] forKey:name];
            else if ([targets count])
                [[node propertyCache] setObject:[targets firstObject] forKey:name];
        }
    }
    [self addCacheNodes:[NSSet setWithArray:[nodes allValues]]];
    CDSet(self, @"fileData", nil);
    return YES;
}

- (id)newReferenceObjectForManagedObject:(NSManagedObject *)managedObject
{
    (void)managedObject;
    unsigned long long next = [CDGet(self, @"lastKey") unsignedLongLongValue] + 1;
    CDSet(self, @"lastKey", [NSNumber numberWithUnsignedLongLong:next]);
    return [[NSNumber alloc] initWithUnsignedLongLong:next];
}

/* Relationships are kept as object IDs, so related objects saved together need no order. */
- (void)updateCacheNode:(NSAtomicStoreCacheNode *)node fromManagedObject:(NSManagedObject *)managedObject
{
    NSMutableDictionary *cache = [NSMutableDictionary dictionary];
    for (NSPropertyDescription *property in managedObject.entity.properties) {
        if (property.isTransient) continue;
        id value = [managedObject valueForKey:property.name];
        if (!value) continue;
        if ([property isKindOfClass:[NSRelationshipDescription class]]) {
            if ([(NSRelationshipDescription *)property isToMany]) {
                NSMutableArray *ids = [NSMutableArray array];
                for (NSManagedObject *related in value) [ids addObject:related.objectID];
                value = ids;
            } else {
                value = [value objectID];
            }
        }
        [cache setObject:value forKey:property.name];
    }
    [node setPropertyCache:cache];
}

- (NSAtomicStoreCacheNode *)newCacheNodeForManagedObject:(NSManagedObject *)managedObject
{
    NSAtomicStoreCacheNode *node = [[NSAtomicStoreCacheNode alloc] initWithObjectID:managedObject.objectID];
    [self updateCacheNode:node fromManagedObject:managedObject];
    return node;
}

static NSNumber *CDBinaryKey(NSBinaryObjectStore *store, id value) {
    NSManagedObjectID *objectID = [value isKindOfClass:[NSAtomicStoreCacheNode class]] ? [value objectID]
                                : [value isKindOfClass:[NSManagedObject class]] ? [value objectID] : value;
    if (![objectID isKindOfClass:[NSManagedObjectID class]]) return nil;
    id reference = [store referenceObjectForObjectID:objectID];
    return [reference isKindOfClass:[NSNumber class]] ? reference : [NSNumber numberWithLongLong:[reference longLongValue]];
}

- (BOOL)save:(NSError **)error
{
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    for (NSAtomicStoreCacheNode *node in [self cacheNodes]) {
        NSEntityDescription *entity = node.objectID.entity;
        NSDictionaryMapNode *mapNode = [[[NSDictionaryMapNode alloc] init] autorelease];
        NSNumber *key = CDBinaryKey(self, node.objectID);
        mapNode->_entityName = [entity.name copy];
        mapNode->_primaryKey = [key longLongValue];
        NSMutableArray *values = [NSMutableArray array];
        NSMutableDictionary *related = [NSMutableDictionary dictionary];
        for (NSPropertyDescription *property in CDBinaryProperties(entity)) {
            id value = [[node propertyCache] objectForKey:property.name];
            if ([property isKindOfClass:[NSRelationshipDescription class]]) {
                [values addObject:[NSNull null]];
                NSMutableArray *keys = [NSMutableArray array];
                if ([(NSRelationshipDescription *)property isToMany]) { for (id item in value) { NSNumber *k = CDBinaryKey(self, item); if (k) [keys addObject:k]; } }
                else if (value) { NSNumber *k = CDBinaryKey(self, value); if (k) [keys addObject:k]; }
                if ([keys count]) [related setObject:keys forKey:property.name];
                continue;
            }
            [values addObject:value ?: [NSNull null]];
        }
        mapNode->_values = [values copy];
        mapNode->_related = [related copy];
        [map setObject:mapNode forKey:key];
    }
    NSData *mapData = CDBinaryArchive(map, @"mapData");
    NSData *metadata = CDBinaryArchive(self.metadata, @"metadata");
    uint64_t words[7] = { CDBinaryVersion, 64 + [mapData length], [metadata length], 64, [mapData length],
                          [CDGet(self, @"lastKey") unsignedLongLongValue], 0 };
    NSMutableData *file = [NSMutableData dataWithBytes:"CoreData" length:8];
    for (int i = 0; i < 7; i++) {
        uint64_t word = CFSwapInt64HostToBig(words[i]);
        [file appendBytes:&word length:8];
    }
    [file appendData:mapData];
    [file appendData:metadata];
    NSURL *url = self.URL;
    if (!url) return CDReturnError(error, CDError(134030, @"The binary store has no file."));
    return [file writeToURL:url options:NSDataWritingAtomic error:error];
}

@end

void CDRegisterBinaryStore(NSMutableDictionary *classes) {
    [classes setObject:[NSBinaryObjectStore class] forKey:NSBinaryStoreType];
}
