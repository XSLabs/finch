// SPDX-License-Identifier: MIT OR Apache-2.0
// The XML store (NSXMLStoreType), an atomic store kept in Core Data's XML
// format: a databaseInfo element with the store's version, UUID, last object
// number and metadata plist, then an object element per managed object,
// typed by its entity's upper-cased name and numbered "z<n>", holding its
// attributes and its relationships' id references. Text escapes &, < and >
// and UTF-16 surrogates as \u with the unit's bytes swapped, and doubles
// backslashes, as Apple's store does, so either system reads the other's files.
#import "CDInternal.h"

@interface NSXMLObjectStore : NSAtomicStore
@end

static NSString *CDXMLEscape(NSString *text) {
    NSMutableString *out = [NSMutableString stringWithCapacity:[text length]];
    for (NSUInteger i = 0; i < [text length]; i++) {
        unichar c = [text characterAtIndex:i];
        if (c == '\\') [out appendString:@"\\\\"];
        else if (c == '&' || c == '<' || c == '>' || (c >= 0xD800 && c <= 0xDFFF))
            [out appendFormat:@"\\u%02x%02x", c & 0xff, c >> 8];
        else [out appendFormat:@"%C", c];
    }
    return out;
}

static NSString *CDXMLUnescape(NSString *text) {
    if ([text rangeOfString:@"\\"].location == NSNotFound) return text;
    NSMutableString *out = [NSMutableString stringWithCapacity:[text length]];
    NSUInteger n = [text length];
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [text characterAtIndex:i];
        if (c == '\\' && i + 1 < n && [text characterAtIndex:i + 1] == '\\') { [out appendString:@"\\"]; i++; continue; }
        if (c == '\\' && i + 5 < n && [text characterAtIndex:i + 1] == 'u') {
            unsigned value = 0;
            NSScanner *scanner = [NSScanner scannerWithString:[text substringWithRange:NSMakeRange(i + 2, 4)]];
            if ([scanner scanHexInt:&value]) {
                [out appendFormat:@"%C", (unichar)(((value & 0xff) << 8) | (value >> 8))];
                i += 5;
                continue;
            }
        }
        [out appendFormat:@"%C", c];
    }
    return out;
}

static NSString *CDXMLTypeName(NSAttributeType type) {
    switch (type) {
        case NSInteger16AttributeType: return @"int16";
        case NSInteger32AttributeType: return @"int32";
        case NSInteger64AttributeType: return @"int64";
        case NSDecimalAttributeType: return @"decimal";
        case NSDoubleAttributeType: return @"double";
        case NSFloatAttributeType: return @"float";
        case NSStringAttributeType: return @"string";
        case NSBooleanAttributeType: return @"bool";
        case NSDateAttributeType: return @"date";
        case NSBinaryDataAttributeType: return @"binary";
        case NSUUIDAttributeType: return @"UUID";
        case NSURIAttributeType: return @"URL";
        case NSTransformableAttributeType: return @"encodable";
        default: return @"string";
    }
}

static NSString *CDXMLNumber(double value) {
    char buffer[64];
    snprintf(buffer, sizeof(buffer), "%.17g", value);
    for (int digits = 1; digits <= 17; digits++) {
        char shorter[64];
        snprintf(shorter, sizeof(shorter), "%.*g", digits, value);
        if (strtod(shorter, NULL) == value) return [NSString stringWithUTF8String:shorter];
    }
    return [NSString stringWithUTF8String:buffer];
}

static NSString *CDXMLAttributeText(NSAttributeDescription *attribute, id value) {
    switch (attribute.attributeType) {
        case NSInteger16AttributeType: case NSInteger32AttributeType: case NSInteger64AttributeType:
            return [NSString stringWithFormat:@"%lld", [value longLongValue]];
        case NSBooleanAttributeType: return [value boolValue] ? @"1" : @"0";
        case NSDoubleAttributeType: return CDXMLNumber([value doubleValue]);
        case NSFloatAttributeType: {
            float f = [value floatValue];
            for (int digits = 1; digits <= 9; digits++) {
                char shorter[32];
                snprintf(shorter, sizeof(shorter), "%.*g", digits, (double)f);
                if (strtof(shorter, NULL) == f) return [NSString stringWithUTF8String:shorter];
            }
            return CDXMLNumber(f);
        }
        case NSDecimalAttributeType: return [value description];
        case NSDateAttributeType: return [NSString stringWithFormat:@"%.20f", [value timeIntervalSinceReferenceDate]];
        case NSBinaryDataAttributeType:
            return [[value base64EncodedStringWithOptions:NSDataBase64Encoding76CharacterLineLength | NSDataBase64EncodingEndLineWithLineFeed]
                    stringByAppendingString:@"\n"];
        case NSUUIDAttributeType: return [value isKindOfClass:[NSUUID class]] ? [value UUIDString] : [value description];
        case NSURIAttributeType: return CDXMLEscape([value isKindOfClass:[NSURL class]] ? [value absoluteString] : [value description]);
        case NSTransformableAttributeType: {
            NSData *data = nil;
            NSString *name = attribute.valueTransformerName;
            NSValueTransformer *transformer = name.length ? [NSValueTransformer valueTransformerForName:name] : nil;
            if (transformer) data = [transformer reverseTransformedValue:value];
            else data = [NSKeyedArchiver archivedDataWithRootObject:value requiringSecureCoding:NO error:NULL];
            return [[data base64EncodedStringWithOptions:NSDataBase64Encoding76CharacterLineLength | NSDataBase64EncodingEndLineWithLineFeed]
                    stringByAppendingString:@"\n"] ?: @"";
        }
        default: return CDXMLEscape([value description]);
    }
}

static id CDXMLAttributeValue(NSAttributeDescription *attribute, NSString *text) {
    switch (attribute.attributeType) {
        case NSInteger16AttributeType: return [NSNumber numberWithShort:(short)[text intValue]];
        case NSInteger32AttributeType: return [NSNumber numberWithInt:[text intValue]];
        case NSInteger64AttributeType: return [NSNumber numberWithLongLong:[text longLongValue]];
        case NSBooleanAttributeType: return [NSNumber numberWithBool:[text intValue] != 0];
        case NSDoubleAttributeType: return [NSNumber numberWithDouble:[text doubleValue]];
        case NSFloatAttributeType: return [NSNumber numberWithFloat:[text floatValue]];
        case NSDecimalAttributeType: return [NSDecimalNumber decimalNumberWithString:text];
        case NSDateAttributeType: return [NSDate dateWithTimeIntervalSinceReferenceDate:[text doubleValue]];
        case NSBinaryDataAttributeType: return [[[NSData alloc] initWithBase64EncodedString:text options:NSDataBase64DecodingIgnoreUnknownCharacters] autorelease];
        case NSUUIDAttributeType: return [[[NSUUID alloc] initWithUUIDString:text] autorelease];
        case NSURIAttributeType: return [NSURL URLWithString:CDXMLUnescape(text)];
        case NSTransformableAttributeType: {
            NSData *data = [[[NSData alloc] initWithBase64EncodedString:text options:NSDataBase64DecodingIgnoreUnknownCharacters] autorelease];
            NSString *name = attribute.valueTransformerName;
            NSValueTransformer *transformer = name.length ? [NSValueTransformer valueTransformerForName:name] : nil;
            if (transformer) return [transformer transformedValue:data];
            NSKeyedUnarchiver *unarchiver = [[[NSKeyedUnarchiver alloc] initForReadingFromData:data error:NULL] autorelease];
            unarchiver.requiresSecureCoding = NO;
            return [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];
        }
        default: return CDXMLUnescape(text);
    }
}

static NSEntityDescription *CDXMLEntityNamed(NSManagedObjectModel *model, NSString *upper) {
    for (NSEntityDescription *entity in model.entities)
        if ([[entity.name uppercaseString] isEqualToString:upper]) return entity;
    return nil;
}

@implementation NSXMLObjectStore

- (NSString *)type { return NSXMLStoreType; }

- (NSUInteger)_nextObjectNumber { return [CDGet(self, @"nextObjectID") unsignedIntegerValue]; }

- (NSXMLDocument *)_document
{
    NSURL *url = self.URL;
    if (!url || ![[NSFileManager defaultManager] fileExistsAtPath:url.path]) return nil;
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data.length) return nil;
    return [[[NSXMLDocument alloc] initWithData:data options:NSXMLNodePreserveWhitespace error:NULL] autorelease];
}

- (BOOL)loadMetadata:(NSError **)error
{
    NSXMLDocument *document = [self _document];
    NSDictionary *metadata = nil;
    if (document) {
        NSXMLElement *info = [[[document rootElement] elementsForName:@"databaseInfo"] firstObject];
        NSXMLElement *plist = [[[[info elementsForName:@"metadata"] firstObject] elementsForName:@"plist"] firstObject];
        if (plist) {
            NSData *xml = [[plist XMLString] dataUsingEncoding:NSUTF8StringEncoding];
            metadata = [NSPropertyListSerialization propertyListWithData:xml options:0 format:NULL error:NULL];
        }
        NSString *uuid = [[[info elementsForName:@"UUID"] firstObject] stringValue];
        NSMutableDictionary *full = [NSMutableDictionary dictionaryWithDictionary:metadata ?: [NSDictionary dictionary]];
        if (uuid) [full setObject:uuid forKey:NSStoreUUIDKey];
        metadata = full;
        CDSet(self, @"nextObjectID", [NSNumber numberWithInteger:[[[[info elementsForName:@"nextObjectID"] firstObject] stringValue] integerValue]]);
        CDSet(self, @"document", document);
    } else if (self.URL && [[NSFileManager defaultManager] fileExistsAtPath:self.URL.path] &&
               [[[NSFileManager defaultManager] attributesOfItemAtPath:self.URL.path error:NULL] fileSize] > 0) {
        return CDReturnError(error, CDError(134110, @"The file is not a Core Data XML store."));
    } else {
        metadata = [NSDictionary dictionaryWithObject:[[NSUUID UUID] UUIDString] forKey:NSStoreUUIDKey];
        CDSet(self, @"nextObjectID", [NSNumber numberWithUnsignedInteger:101]);
    }
    self.metadata = metadata;
    return YES;
}

- (BOOL)load:(NSError **)error
{
    (void)error;
    NSXMLDocument *document = CDGet(self, @"document");
    if (!document) return YES;
    NSManagedObjectModel *model = self.persistentStoreCoordinator.managedObjectModel;
    NSMutableDictionary *nodes = [NSMutableDictionary dictionary];
    NSMutableArray *pending = [NSMutableArray array];
    for (NSXMLElement *object in [[document rootElement] elementsForName:@"object"]) {
        NSEntityDescription *entity = CDXMLEntityNamed(model, [[object attributeForName:@"type"] stringValue]);
        NSString *identifier = [[object attributeForName:@"id"] stringValue];
        if (!entity || ![identifier hasPrefix:@"z"]) continue;
        NSNumber *reference = [NSNumber numberWithInteger:[[identifier substringFromIndex:1] integerValue]];
        NSAtomicStoreCacheNode *node = [[[NSAtomicStoreCacheNode alloc] initWithObjectID:[self objectIDForEntity:entity referenceObject:reference]] autorelease];
        [node setPropertyCache:[NSMutableDictionary dictionary]];
        for (NSXMLElement *attribute in [object elementsForName:@"attribute"]) {
            NSAttributeDescription *description = [entity.attributesByName objectForKey:[[attribute attributeForName:@"name"] stringValue]];
            id value = description ? CDXMLAttributeValue(description, [attribute stringValue]) : nil;
            if (value) [[node propertyCache] setObject:value forKey:description.name];
        }
        [nodes setObject:node forKey:identifier];
        [pending addObject:[NSArray arrayWithObjects:node, object, entity, nil]];
    }
    for (NSArray *entry in pending) {
        NSAtomicStoreCacheNode *node = [entry objectAtIndex:0];
        NSEntityDescription *entity = [entry objectAtIndex:2];
        for (NSXMLElement *element in [[entry objectAtIndex:1] elementsForName:@"relationship"]) {
            NSRelationshipDescription *relationship = [entity.relationshipsByName objectForKey:[[element attributeForName:@"name"] stringValue]];
            if (!relationship) continue;
            NSMutableArray *targets = [NSMutableArray array];
            for (NSString *reference in [[[element attributeForName:@"idrefs"] stringValue] componentsSeparatedByString:@" "]) {
                NSAtomicStoreCacheNode *target = [nodes objectForKey:reference];
                if (target) [targets addObject:target];
            }
            if (relationship.isToMany) {
                id value = relationship.isOrdered ? (id)[NSMutableOrderedSet orderedSetWithArray:targets] : (id)[NSMutableSet setWithArray:targets];
                [[node propertyCache] setObject:value forKey:relationship.name];
            } else if ([targets count]) {
                [[node propertyCache] setObject:[targets firstObject] forKey:relationship.name];
            }
        }
    }
    [self addCacheNodes:[NSSet setWithArray:[nodes allValues]]];
    CDSet(self, @"document", nil);
    return YES;
}

- (id)newReferenceObjectForManagedObject:(NSManagedObject *)managedObject
{
    (void)managedObject;
    NSUInteger next = [self _nextObjectNumber] + 1;
    CDSet(self, @"nextObjectID", [NSNumber numberWithUnsignedInteger:next]);
    return [[NSNumber alloc] initWithUnsignedInteger:next];
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

static NSString *CDXMLReference(NSXMLObjectStore *store, id value) {
    NSManagedObjectID *objectID = [value isKindOfClass:[NSAtomicStoreCacheNode class]] ? [value objectID]
                                : [value isKindOfClass:[NSManagedObject class]] ? [value objectID] : value;
    if (![objectID isKindOfClass:[NSManagedObjectID class]]) return nil;
    return [NSString stringWithFormat:@"z%@", [store referenceObjectForObjectID:objectID]];
}

static void CDXMLAppendPlist(NSMutableString *out, NSDictionary *metadata) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:metadata format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
    NSString *text = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (![line length] || [line hasPrefix:@"<?xml"] || [line hasPrefix:@"<!DOCTYPE"]) continue;
        [out appendFormat:@"            %@\n", line];
    }
}

- (BOOL)save:(NSError **)error
{
    NSMutableString *out = [NSMutableString stringWithString:
        @"<?xml version=\"1.0\"?>\n<!DOCTYPE database SYSTEM \"file:///System/Library/DTDs/CoreData.dtd\">\n\n<database>\n    <databaseInfo>\n"];
    [out appendString:@"        <version>134481920</version>\n"];
    [out appendFormat:@"        <UUID>%@</UUID>\n", [self.metadata objectForKey:NSStoreUUIDKey] ?: self.identifier];
    [out appendFormat:@"        <nextObjectID>%lu</nextObjectID>\n", (unsigned long)[self _nextObjectNumber]];
    [out appendString:@"        <metadata>\n"];
    CDXMLAppendPlist(out, self.metadata);
    [out appendString:@"        </metadata>\n    </databaseInfo>\n"];
    NSArray *nodes = [[[self cacheNodes] allObjects] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        return [[self referenceObjectForObjectID:[a objectID]] compare:[self referenceObjectForObjectID:[b objectID]]];
    }];
    for (NSAtomicStoreCacheNode *node in nodes) {
        NSEntityDescription *entity = node.objectID.entity;
        [out appendFormat:@"    <object type=\"%@\" id=\"%@\">", [entity.name uppercaseString], CDXMLReference(self, node.objectID)];
        BOOL any = NO;
        for (NSPropertyDescription *property in entity.properties) {
            id value = [[node propertyCache] objectForKey:property.name];
            if (!value || property.isTransient) continue;
            if ([property isKindOfClass:[NSAttributeDescription class]]) {
                NSAttributeDescription *attribute = (NSAttributeDescription *)property;
                [out appendFormat:@"\n        <attribute name=\"%@\" type=\"%@\">%@</attribute>", property.name,
                     CDXMLTypeName(attribute.attributeType), CDXMLAttributeText(attribute, value)];
                any = YES;
            } else if ([property isKindOfClass:[NSRelationshipDescription class]]) {
                NSRelationshipDescription *relationship = (NSRelationshipDescription *)property;
                NSMutableArray *references = [NSMutableArray array];
                if (relationship.isToMany) { for (id item in value) { NSString *r = CDXMLReference(self, item); if (r) [references addObject:r]; } }
                else { NSString *r = CDXMLReference(self, value); if (r) [references addObject:r]; }
                NSString *idrefs = [references count] ? [NSString stringWithFormat:@" idrefs=\"%@\"", [references componentsJoinedByString:@" "]] : @"";
                [out appendFormat:@"\n        <relationship name=\"%@\" type=\"%lu/%lu\" destination=\"%@\"%@></relationship>",
                     property.name, (unsigned long)relationship.minCount, (unsigned long)relationship.maxCount,
                     [relationship.destinationEntity.name uppercaseString], idrefs];
                any = YES;
            }
        }
        [out appendString:any ? @"\n    </object>\n" : @"</object>\n"];
    }
    [out appendString:@"</database>"];
    NSURL *url = self.URL;
    if (!url) return CDReturnError(error, CDError(134030, @"The XML store has no file."));
    return [[out dataUsingEncoding:NSUTF8StringEncoding] writeToURL:url options:NSDataWritingAtomic error:error];
}

@end

void CDRegisterBuiltInStores(NSMutableDictionary *classes) {
    [classes setObject:[NSXMLObjectStore class] forKey:NSXMLStoreType];
    CDRegisterBinaryStore(classes);
}
