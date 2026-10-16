// SPDX-License-Identifier: MIT OR Apache-2.0
#import "CDInternal.h"
#import <CommonCrypto/CommonDigest.h>

static NSData *CDHash(NSString *text) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    NSData *input = [text dataUsingEncoding:NSUTF8StringEncoding];
    CC_SHA256([input bytes], (CC_LONG)[input length], digest);
    return [NSData dataWithBytes:digest length:sizeof(digest)];
}

static NSURL *CDResolveModelURL(NSURL *url) {
    BOOL directory = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:[url path] isDirectory:&directory] && directory) {
        NSURL *versionInfo = [url URLByAppendingPathComponent:@"VersionInfo.plist"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:versionInfo];
        NSString *name = [info objectForKey:@"NSManagedObjectModel_CurrentVersionName"];
        if (name) {
            NSURL *version = [url URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"mom"]];
            if ([[NSFileManager defaultManager] fileExistsAtPath:[version path]]) return version;
        }
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[url path] error:NULL];
        for (NSString *file in files) {
            if ([[file pathExtension] isEqualToString:@"mom"])
                return [url URLByAppendingPathComponent:file];
        }
        return nil;
    }
    return url;
}

@implementation NSPropertyDescription

- (NSString *)name { return CDGet(self, @"name"); }
- (void)setName:(NSString *)name { CDSet(self, @"name", [name copy]); }
- (NSEntityDescription *)entity { return CDGet(self, @"entity"); }
- (BOOL)isOptional { return [CDGet(self, @"optional") boolValue]; }
- (void)setOptional:(BOOL)value { CDSet(self, @"optional", [NSNumber numberWithBool:value]); }
- (BOOL)isTransient { return [CDGet(self, @"transient") boolValue]; }
- (void)setTransient:(BOOL)value { CDSet(self, @"transient", [NSNumber numberWithBool:value]); }
- (NSDictionary *)userInfo { return CDGet(self, @"userInfo"); }
- (void)setUserInfo:(NSDictionary *)value { CDSet(self, @"userInfo", [value copy]); }
- (BOOL)isIndexed { return [CDGet(self, @"indexed") boolValue]; }
- (void)setIndexed:(BOOL)value { CDSet(self, @"indexed", [NSNumber numberWithBool:value]); }
- (BOOL)isIndexedBySpotlight { return [CDGet(self, @"indexedBySpotlight") boolValue]; }
- (void)setIndexedBySpotlight:(BOOL)value { CDSet(self, @"indexedBySpotlight", [NSNumber numberWithBool:value]); }
- (BOOL)isStoredInExternalRecord { return [CDGet(self, @"storedInExternalRecord") boolValue]; }
- (void)setStoredInExternalRecord:(BOOL)value { CDSet(self, @"storedInExternalRecord", [NSNumber numberWithBool:value]); }
- (NSString *)versionHashModifier { return CDGet(self, @"versionHashModifier"); }
- (void)setVersionHashModifier:(NSString *)value { CDSet(self, @"versionHashModifier", [value copy]); }
- (NSString *)renamingIdentifier { return CDGet(self, @"renamingIdentifier"); }
- (void)setRenamingIdentifier:(NSString *)value { CDSet(self, @"renamingIdentifier", [value copy]); }
- (NSArray *)validationPredicates { return CDGet(self, @"validationPredicates") ?: [NSArray array]; }
- (NSArray *)validationWarnings { return CDGet(self, @"validationWarnings") ?: [NSArray array]; }
- (void)setValidationPredicates:(NSArray *)predicates withValidationWarnings:(NSArray *)warnings {
    CDSet(self, @"validationPredicates", [predicates copy]);
    CDSet(self, @"validationWarnings", [warnings copy]);
}
- (NSData *)versionHash {
    NSString *value = [NSString stringWithFormat:@"%@|%d|%d|%@", self.name ?: @"", self.optional,
                       self.transient, self.versionHashModifier ?: @""];
    return CDHash(value);
}
- (id)copyWithZone:(NSZone *)zone {
    NSPropertyDescription *copy = [[[self class] allocWithZone:zone] init];
    [copy setName:self.name];
    [copy setOptional:self.optional];
    [copy setTransient:self.transient];
    [copy setUserInfo:self.userInfo];
    [copy setIndexed:self.indexed];
    [copy setIndexedBySpotlight:self.indexedBySpotlight];
    [copy setVersionHashModifier:self.versionHashModifier];
    [copy setRenamingIdentifier:self.renamingIdentifier];
    return copy;
}
- (id)initWithCoder:(NSCoder *)coder {
    self = [self init];
    if (self) {
        [self setName:[coder decodeObjectForKey:@"NSPropertyName"] ?: [coder decodeObjectForKey:@"NSName"]];
        [self setOptional:[coder decodeBoolForKey:@"NSIsOptional"]];
        [self setTransient:[coder decodeBoolForKey:@"NSIsTransient"]];
        [self setIndexed:[coder decodeBoolForKey:@"NSIsIndexed"]];
        [self setIndexedBySpotlight:[coder decodeBoolForKey:@"NSIsIndexedBySpotlight"]];
        [self setUserInfo:[coder decodeObjectForKey:@"NSUserInfo"]];
        [self setRenamingIdentifier:[coder decodeObjectForKey:@"NSRenamingIdentifier"]];
        [self setVersionHashModifier:[coder decodeObjectForKey:@"NSVersionHashModifier"]];
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.name forKey:@"NSPropertyName"];
    [coder encodeBool:self.optional forKey:@"NSIsOptional"];
    [coder encodeBool:self.transient forKey:@"NSIsTransient"];
    [coder encodeObject:self.userInfo forKey:@"NSUserInfo"];
    [coder encodeObject:self.renamingIdentifier forKey:@"NSRenamingIdentifier"];
    [coder encodeObject:self.versionHashModifier forKey:@"NSVersionHashModifier"];
}
@end

@implementation NSAttributeDescription
- (NSAttributeType)attributeType { return [CDGet(self, @"attributeType") unsignedIntegerValue]; }
- (void)setAttributeType:(NSAttributeType)value { CDSet(self, @"attributeType", [NSNumber numberWithUnsignedInteger:value]); }
- (NSString *)attributeValueClassName { return CDGet(self, @"attributeValueClassName"); }
- (void)setAttributeValueClassName:(NSString *)value { CDSet(self, @"attributeValueClassName", [value copy]); }
- (id)defaultValue { return CDGet(self, @"defaultValue"); }
- (void)setDefaultValue:(id)value { CDSet(self, @"defaultValue", value); }
- (NSString *)valueTransformerName { return CDGet(self, @"valueTransformerName"); }
- (void)setValueTransformerName:(NSString *)value { CDSet(self, @"valueTransformerName", [value copy]); }
- (BOOL)allowsExternalBinaryDataStorage { return [CDGet(self, @"allowsExternalBinaryDataStorage") boolValue]; }
- (void)setAllowsExternalBinaryDataStorage:(BOOL)value { CDSet(self, @"allowsExternalBinaryDataStorage", [NSNumber numberWithBool:value]); }
- (BOOL)preservesValueInHistoryOnDeletion { return [CDGet(self, @"preservesValueInHistoryOnDeletion") boolValue]; }
- (void)setPreservesValueInHistoryOnDeletion:(BOOL)value { CDSet(self, @"preservesValueInHistoryOnDeletion", [NSNumber numberWithBool:value]); }
- (BOOL)allowsCloudEncryption { return [CDGet(self, @"allowsCloudEncryption") boolValue]; }
- (void)setAllowsCloudEncryption:(BOOL)value { CDSet(self, @"allowsCloudEncryption", [NSNumber numberWithBool:value]); }
- (NSData *)versionHash {
    return CDHash([NSString stringWithFormat:@"%@|%lu|%@", [super versionHash],
                   (unsigned long)self.attributeType, self.attributeValueClassName ?: @""]);
}
- (id)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self setAttributeType:(NSAttributeType)[coder decodeIntegerForKey:@"NSAttributeType"]];
        [self setAttributeValueClassName:[coder decodeObjectForKey:@"NSAttributeValueClassName"]];
        [self setDefaultValue:[coder decodeObjectForKey:@"NSDefaultValue"]];
        [self setValueTransformerName:[coder decodeObjectForKey:@"NSValueTransformerName"]];
        [self setAllowsExternalBinaryDataStorage:[coder decodeBoolForKey:@"NSAllowsExternalBinaryDataStorage"]];
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder {
    [super encodeWithCoder:coder];
    [coder encodeInteger:self.attributeType forKey:@"NSAttributeType"];
    [coder encodeObject:self.attributeValueClassName forKey:@"NSAttributeValueClassName"];
    [coder encodeObject:self.defaultValue forKey:@"NSDefaultValue"];
    [coder encodeObject:self.valueTransformerName forKey:@"NSValueTransformerName"];
}
@end

@implementation NSRelationshipDescription
- (NSEntityDescription *)destinationEntity { return CDGet(self, @"destinationEntity"); }
- (void)setDestinationEntity:(NSEntityDescription *)value { CDSet(self, @"destinationEntity", value); }
- (NSRelationshipDescription *)inverseRelationship { return CDGet(self, @"inverseRelationship"); }
- (void)setInverseRelationship:(NSRelationshipDescription *)value { CDSet(self, @"inverseRelationship", value); }
- (NSUInteger)maxCount { return [CDGet(self, @"maxCount") unsignedIntegerValue]; }
- (void)setMaxCount:(NSUInteger)value { CDSet(self, @"maxCount", [NSNumber numberWithUnsignedInteger:value]); }
- (NSUInteger)minCount { return [CDGet(self, @"minCount") unsignedIntegerValue]; }
- (void)setMinCount:(NSUInteger)value { CDSet(self, @"minCount", [NSNumber numberWithUnsignedInteger:value]); }
- (NSDeleteRule)deleteRule { return [CDGet(self, @"deleteRule") unsignedIntegerValue]; }
- (void)setDeleteRule:(NSDeleteRule)value { CDSet(self, @"deleteRule", [NSNumber numberWithUnsignedInteger:value]); }
- (BOOL)isToMany { return self.maxCount == 0 || self.maxCount > 1; }
- (BOOL)isOrdered { return [CDGet(self, @"ordered") boolValue]; }
- (void)setOrdered:(BOOL)value { CDSet(self, @"ordered", [NSNumber numberWithBool:value]); }
- (NSData *)versionHash {
    return CDHash([NSString stringWithFormat:@"%@|%@|%@|%lu|%lu|%lu", [super versionHash],
                   self.destinationEntity.name ?: @"", self.inverseRelationship.name ?: @"",
                   (unsigned long)self.minCount, (unsigned long)self.maxCount,
                   (unsigned long)self.deleteRule]);
}
- (id)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self setDestinationEntity:[coder decodeObjectForKey:@"NSDestinationEntity"]];
        [self setInverseRelationship:[coder decodeObjectForKey:@"NSInverseRelationship"]];
        [self setMinCount:(NSUInteger)[coder decodeIntegerForKey:@"NSMinCount"]];
        [self setMaxCount:(NSUInteger)[coder decodeIntegerForKey:@"NSMaxCount"]];
        [self setDeleteRule:(NSDeleteRule)[coder decodeIntegerForKey:@"NSDeleteRule"]];
        [self setOrdered:[coder decodeBoolForKey:@"NSOrdered"]];
        CDSet(self, @"destinationName", [coder decodeObjectForKey:@"_NSDestinationEntityName"]);
        CDSet(self, @"inverseName", [coder decodeObjectForKey:@"_NSInverseRelationshipName"]);
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder {
    [super encodeWithCoder:coder];
    [coder encodeObject:self.destinationEntity forKey:@"NSDestinationEntity"];
    [coder encodeObject:self.inverseRelationship forKey:@"NSInverseRelationship"];
    [coder encodeInteger:self.minCount forKey:@"NSMinCount"];
    [coder encodeInteger:self.maxCount forKey:@"NSMaxCount"];
    [coder encodeInteger:self.deleteRule forKey:@"NSDeleteRule"];
    [coder encodeBool:self.ordered forKey:@"NSOrdered"];
}
@end

@implementation NSFetchedPropertyDescription
- (NSFetchRequest *)fetchRequest { return CDGet(self, @"fetchRequest"); }
- (void)setFetchRequest:(NSFetchRequest *)value { CDSet(self, @"fetchRequest", [value copy]); }
@end

@implementation NSExpressionDescription
- (NSExpression *)expression { return CDGet(self, @"expression"); }
- (void)setExpression:(NSExpression *)value { CDSet(self, @"expression", value); }
- (NSAttributeType)expressionResultType { return [CDGet(self, @"expressionResultType") unsignedIntegerValue]; }
- (void)setExpressionResultType:(NSAttributeType)value { CDSet(self, @"expressionResultType", [NSNumber numberWithUnsignedInteger:value]); }
@end

@implementation NSFetchIndexDescription
- (instancetype)initWithName:(NSString *)name elements:(NSArray *)elements {
    self = [self init];
    if (self) { self.name = name; self.elements = elements ?: [NSArray array]; }
    return self;
}
- (NSString *)name { return CDGet(self, @"name"); }
- (void)setName:(NSString *)value { CDSet(self, @"name", [value copy]); }
- (NSArray *)elements { return CDGet(self, @"elements") ?: [NSArray array]; }
- (void)setElements:(NSArray *)value { CDSet(self, @"elements", [value copy]); }
- (NSEntityDescription *)entity { return CDGet(self, @"entity"); }
- (NSPredicate *)partialIndexPredicate { return CDGet(self, @"partialIndexPredicate"); }
- (void)setPartialIndexPredicate:(NSPredicate *)value { CDSet(self, @"partialIndexPredicate", [value copy]); }
- (id)copyWithZone:(NSZone *)zone {
    return [[[self class] allocWithZone:zone] initWithName:self.name elements:self.elements];
}
- (id)initWithCoder:(NSCoder *)coder {
    self = [self init];
    if (self) { self.name = [coder decodeObjectForKey:@"NSIndexName"]; self.elements = [coder decodeObjectForKey:@"NSIndexElements"]; }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.name forKey:@"NSIndexName"];
    [coder encodeObject:self.elements forKey:@"NSIndexElements"];
}
@end

@implementation NSFetchIndexElementDescription
- (instancetype)initWithProperty:(NSPropertyDescription *)property collationType:(NSFetchIndexElementType)type {
    self = [super init];
    if (self) { CDSet(self, @"property", property); self.collationType = type; }
    return self;
}
- (NSPropertyDescription *)property { return CDGet(self, @"property"); }
- (NSString *)propertyName { return self.property.name ?: CDGet(self, @"propertyName"); }
- (NSFetchIndexElementType)collationType { return [CDGet(self, @"collationType") unsignedIntegerValue]; }
- (void)setCollationType:(NSFetchIndexElementType)value { CDSet(self, @"collationType", [NSNumber numberWithUnsignedInteger:value]); }
- (BOOL)isAscending { return CDGet(self, @"ascending") ? [CDGet(self, @"ascending") boolValue] : YES; }
- (void)setAscending:(BOOL)value { CDSet(self, @"ascending", [NSNumber numberWithBool:value]); }
- (NSFetchIndexDescription *)indexDescription { return CDGet(self, @"indexDescription"); }
- (id)copyWithZone:(NSZone *)zone {
    NSFetchIndexElementDescription *copy = [[[self class] allocWithZone:zone] initWithProperty:self.property collationType:self.collationType];
    copy.ascending = self.ascending;
    return copy;
}
- (id)initWithCoder:(NSCoder *)coder {
    self = [self init];
    if (self) {
        CDSet(self, @"property", [coder decodeObjectForKey:@"NSProperty"]);
        CDSet(self, @"propertyName", [coder decodeObjectForKey:@"NSPropertyName"]);
        [self setCollationType:(NSFetchIndexElementType)[coder decodeIntegerForKey:@"NSFetchIndexElementType"]];
        [self setAscending:[coder decodeBoolForKey:@"NSAscending"]];
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.property forKey:@"NSProperty"];
    [coder encodeObject:self.propertyName forKey:@"NSPropertyName"];
    [coder encodeInteger:self.collationType forKey:@"NSFetchIndexElementType"];
    [coder encodeBool:self.ascending forKey:@"NSAscending"];
}
@end

@implementation NSEntityDescription
+ (NSEntityDescription *)entityForName:(NSString *)name inManagedObjectContext:(NSManagedObjectContext *)context {
    return [context.persistentStoreCoordinator.managedObjectModel.entitiesByName objectForKey:name];
}
+ (NSManagedObject *)insertNewObjectForEntityForName:(NSString *)name inManagedObjectContext:(NSManagedObjectContext *)context {
    NSEntityDescription *entity = [self entityForName:name inManagedObjectContext:context];
    return entity ? CDNewObject(entity, context) : nil;
}
- (NSString *)name { return CDGet(self, @"name"); }
- (void)setName:(NSString *)value { CDSet(self, @"name", [value copy]); }
- (NSString *)managedObjectClassName { return CDGet(self, @"managedObjectClassName") ?: NSStringFromClass([NSManagedObject class]); }
- (void)setManagedObjectClassName:(NSString *)value { CDSet(self, @"managedObjectClassName", [value copy]); }
- (NSManagedObjectModel *)managedObjectModel { return CDGet(self, @"managedObjectModel"); }
- (NSEntityDescription *)superentity { return CDGet(self, @"superentity"); }
- (void)setSuperentity:(NSEntityDescription *)value { CDSet(self, @"superentity", value); }
- (NSArray *)subentities { return CDGet(self, @"subentities") ?: [NSArray array]; }
- (void)setSubentities:(NSArray *)value { CDSet(self, @"subentities", [value copy]); }
- (NSArray *)properties { return CDGet(self, @"properties") ?: [NSArray array]; }
- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state objects:(id __unsafe_unretained [])buffer count:(NSUInteger)length {
    return [self.properties countByEnumeratingWithState:state objects:buffer count:length];
}
- (void)setProperties:(NSArray *)value {
    NSArray *properties = [value copy] ?: [[NSArray alloc] init];
    CDSet(self, @"properties", properties);
    for (NSPropertyDescription *property in properties) {
        CDSet(property, @"entity", self);
        if ([property isKindOfClass:[NSFetchIndexDescription class]]) CDSet(property, @"entity", self);
    }
    [properties release];
}
- (NSDictionary *)propertiesByName {
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    for (NSPropertyDescription *property in self.properties) if (property.name) [map setObject:property forKey:property.name];
    return map;
}
- (NSDictionary *)attributesByName {
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    for (NSPropertyDescription *property in self.properties)
        if ([property isKindOfClass:[NSAttributeDescription class]] && property.name) [map setObject:property forKey:property.name];
    return map;
}
- (NSDictionary *)relationshipsByName {
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    for (NSPropertyDescription *property in self.properties)
        if ([property isKindOfClass:[NSRelationshipDescription class]] && property.name) [map setObject:property forKey:property.name];
    return map;
}
- (NSDictionary *)subentitiesByName {
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    for (NSEntityDescription *entity in self.subentities) if (entity.name) [map setObject:entity forKey:entity.name];
    return map;
}
- (NSArray *)relationshipsWithDestinationEntity:(NSEntityDescription *)entity {
    NSMutableArray *matches = [NSMutableArray array];
    for (NSRelationshipDescription *relationship in [self.relationshipsByName allValues])
        if (relationship.destinationEntity == entity) [matches addObject:relationship];
    return matches;
}
- (BOOL)isAbstract { return [CDGet(self, @"abstract") boolValue]; }
- (void)setAbstract:(BOOL)value { CDSet(self, @"abstract", [NSNumber numberWithBool:value]); }
- (NSDictionary *)userInfo { return CDGet(self, @"userInfo"); }
- (void)setUserInfo:(NSDictionary *)value { CDSet(self, @"userInfo", [value copy]); }
- (NSString *)versionHashModifier { return CDGet(self, @"versionHashModifier"); }
- (void)setVersionHashModifier:(NSString *)value { CDSet(self, @"versionHashModifier", [value copy]); }
- (NSString *)renamingIdentifier { return CDGet(self, @"renamingIdentifier"); }
- (void)setRenamingIdentifier:(NSString *)value { CDSet(self, @"renamingIdentifier", [value copy]); }
- (NSArray *)indexes { return CDGet(self, @"indexes") ?: [NSArray array]; }
- (void)setIndexes:(NSArray *)value { CDSet(self, @"indexes", [value copy]); }
- (NSArray *)compoundIndexes { return CDGet(self, @"compoundIndexes") ?: [NSArray array]; }
- (void)setCompoundIndexes:(NSArray *)value { CDSet(self, @"compoundIndexes", [value copy]); }
- (NSArray *)uniquenessConstraints { return CDGet(self, @"uniquenessConstraints") ?: [NSArray array]; }
- (void)setUniquenessConstraints:(NSArray *)value { CDSet(self, @"uniquenessConstraints", [value copy]); }
- (NSExpression *)coreSpotlightDisplayNameExpression { return CDGet(self, @"coreSpotlightDisplayNameExpression"); }
- (void)setCoreSpotlightDisplayNameExpression:(NSExpression *)value { CDSet(self, @"coreSpotlightDisplayNameExpression", value); }
- (BOOL)isKindOfEntity:(NSEntityDescription *)entity {
    for (NSEntityDescription *current = self; current; current = current.superentity) if (current == entity) return YES;
    return NO;
}
- (NSData *)versionHash {
    NSMutableArray *parts = [NSMutableArray arrayWithObjects:self.name ?: @"", self.managedObjectClassName ?: @"",
                              self.versionHashModifier ?: @"", self.isAbstract ? @"1" : @"0", nil];
    NSArray *names = [[self.propertiesByName allKeys] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in names) {
        NSPropertyDescription *property = [self.propertiesByName objectForKey:name];
        [parts addObject:[NSString stringWithFormat:@"%@:%@", name, property.versionHash]];
    }
    return CDHash([parts componentsJoinedByString:@"|"]);
}
- (id)copyWithZone:(NSZone *)zone {
    NSEntityDescription *copy = [[[self class] allocWithZone:zone] init];
    copy.name = self.name;
    copy.managedObjectClassName = self.managedObjectClassName;
    copy.abstract = self.abstract;
    copy.properties = self.properties;
    copy.userInfo = self.userInfo;
    copy.versionHashModifier = self.versionHashModifier;
    copy.renamingIdentifier = self.renamingIdentifier;
    return copy;
}
- (id)initWithCoder:(NSCoder *)coder {
    self = [self init];
    if (self) {
        self.name = [coder decodeObjectForKey:@"NSEntityName"];
        self.managedObjectClassName = [coder decodeObjectForKey:@"NSClassNameForEntity"];
        self.properties = [[coder decodeObjectForKey:@"NSProperties"] allValues];
        self.subentities = [[coder decodeObjectForKey:@"NSSubentities"] allValues];
        self.superentity = [coder decodeObjectForKey:@"NSSuperentity"];
        self.userInfo = [coder decodeObjectForKey:@"NSUserInfo"];
        self.versionHashModifier = [coder decodeObjectForKey:@"NSVersionHashModifier"];
        self.renamingIdentifier = [coder decodeObjectForKey:@"NSRenamingIdentifier"];
        self.compoundIndexes = [coder decodeObjectForKey:@"NSCompoundIndexes"];
        self.indexes = [coder decodeObjectForKey:@"NSFetchIndexDescriptions"];
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.name forKey:@"NSEntityName"];
    [coder encodeObject:self.managedObjectClassName forKey:@"NSClassNameForEntity"];
    [coder encodeObject:self.properties forKey:@"NSProperties"];
    [coder encodeObject:self.subentities forKey:@"NSSubentities"];
    [coder encodeObject:self.superentity forKey:@"NSSuperentity"];
    [coder encodeObject:self.userInfo forKey:@"NSUserInfo"];
    [coder encodeObject:self.versionHashModifier forKey:@"NSVersionHashModifier"];
}
@end

@implementation NSManagedObjectModel
- (instancetype)init {
    self = [super init];
    if (self) { CDSet(self, @"entities", [NSArray array]); CDSet(self, @"versionIdentifiers", [NSSet set]); }
    return self;
}
- (instancetype)initWithContentsOfURL:(NSURL *)url {
    self = [self init];
    if (!self) return nil;
    NSURL *modelURL = CDResolveModelURL(url);
    if (!modelURL) { [self release]; return nil; }
    NSData *data = [NSData dataWithContentsOfURL:modelURL];
    if (!data) { [self release]; return nil; }
    [self release];
    id model = [NSKeyedUnarchiver unarchiveObjectWithData:data];
    return [model isKindOfClass:[NSManagedObjectModel class]] ? [model retain] : nil;
}
- (NSArray *)entities { return CDGet(self, @"entities") ?: [NSArray array]; }
- (void)setEntities:(NSArray *)entities {
    CDSet(self, @"entities", [entities copy] ?: [NSArray array]);
    for (NSEntityDescription *entity in entities) {
        CDSet(entity, @"managedObjectModel", self);
        for (NSRelationshipDescription *relationship in [entity.relationshipsByName allValues]) {
            NSString *name = CDGet(relationship, @"destinationName");
            if (name) relationship.destinationEntity = [self.entitiesByName objectForKey:name];
            NSString *inverseName = CDGet(relationship, @"inverseName");
            if (!relationship.inverseRelationship && inverseName)
                relationship.inverseRelationship = [relationship.destinationEntity.propertiesByName objectForKey:inverseName];
        }
    }
}
- (NSDictionary *)entitiesByName {
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    for (NSEntityDescription *entity in self.entities) if (entity.name) [map setObject:entity forKey:entity.name];
    return map;
}
- (NSArray *)configurations { return [[CDGet(self, @"configurationEntities") allKeys] sortedArrayUsingSelector:@selector(compare:)]; }
- (NSArray *)entitiesForConfiguration:(NSString *)configuration {
    if (!configuration) return self.entities;
    return [[CDGet(self, @"configurationEntities") objectForKey:configuration] copy] ?: nil;
}
- (void)setEntities:(NSArray *)entities forConfiguration:(NSString *)configuration {
    NSMutableDictionary *map = CDGet(self, @"configurationEntities");
    if (!map) { map = [NSMutableDictionary dictionary]; CDSet(self, @"configurationEntities", map); }
    [map setObject:[[entities copy] autorelease] forKey:configuration];
}
- (NSDictionary *)fetchRequestTemplatesByName { return CDGet(self, @"templates") ?: [NSDictionary dictionary]; }
- (void)setFetchRequestTemplate:(NSFetchRequest *)request forName:(NSString *)name {
    NSMutableDictionary *map = CDGet(self, @"templates");
    if (!map) { map = [NSMutableDictionary dictionary]; CDSet(self, @"templates", map); }
    if (request) [map setObject:request forKey:name]; else [map removeObjectForKey:name];
}
- (NSFetchRequest *)fetchRequestTemplateForName:(NSString *)name { return [self.fetchRequestTemplatesByName objectForKey:name]; }
- (NSFetchRequest *)fetchRequestFromTemplateWithName:(NSString *)name substitutionVariables:(NSDictionary *)variables {
    NSFetchRequest *request = [[self fetchRequestTemplateForName:name] copy];
    if (!request) return nil;
    request.predicate = [request.predicate predicateWithSubstitutionVariables:variables ?: [NSDictionary dictionary]];
    return [request autorelease];
}
- (NSDictionary *)localizationDictionary { return CDGet(self, @"localizationDictionary"); }
- (void)setLocalizationDictionary:(NSDictionary *)value { CDSet(self, @"localizationDictionary", [value copy]); }
- (NSSet *)versionIdentifiers { return CDGet(self, @"versionIdentifiers") ?: [NSSet set]; }
- (void)setVersionIdentifiers:(NSSet *)value { CDSet(self, @"versionIdentifiers", [value copy]); }
- (NSDictionary *)entityVersionHashesByName {
    NSMutableDictionary *hashes = [NSMutableDictionary dictionary];
    for (NSEntityDescription *entity in self.entities) if (entity.name) [hashes setObject:entity.versionHash forKey:entity.name];
    return hashes;
}
- (NSString *)versionChecksum {
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *key in [[self.entityVersionHashesByName allKeys] sortedArrayUsingSelector:@selector(compare:)])
        [items addObject:[NSString stringWithFormat:@"%@:%@", key, [[self.entityVersionHashesByName objectForKey:key] base64EncodedStringWithOptions:0]]];
    return [items componentsJoinedByString:@";"];
}
- (BOOL)isConfiguration:(NSString *)configuration compatibleWithStoreMetadata:(NSDictionary *)metadata {
    NSDictionary *stored = [metadata objectForKey:@"NSStoreModelVersionHashes"];
    if (![stored isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *current = self.entityVersionHashesByName;
    for (NSString *name in stored) {
        NSData *hash = [current objectForKey:name];
        if (!hash || ![hash isEqual:[stored objectForKey:name]]) return NO;
    }
    return [stored count] == [current count];
}
- (id)copyWithZone:(NSZone *)zone {
    NSManagedObjectModel *copy = [[[self class] allocWithZone:zone] init];
    copy.entities = self.entities;
    copy.versionIdentifiers = self.versionIdentifiers;
    copy.localizationDictionary = self.localizationDictionary;
    return copy;
}
- (id)initWithCoder:(NSCoder *)coder {
    self = [self init];
    if (self) {
        id entities = [coder decodeObjectForKey:@"NSEntities"];
        self.entities = [entities isKindOfClass:[NSDictionary class]] ? [entities allValues] : entities;
        self.versionIdentifiers = [coder decodeObjectForKey:@"NSVersionIdentifiers"] ?: [NSSet set];
        id templates = [coder decodeObjectForKey:@"NSFetchRequestTemplates"];
        if ([templates isKindOfClass:[NSDictionary class]]) CDSet(self, @"templates", templates);
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.entities forKey:@"NSEntities"];
    [coder encodeObject:self.versionIdentifiers forKey:@"NSVersionIdentifiers"];
    [coder encodeObject:self.fetchRequestTemplatesByName forKey:@"NSFetchRequestTemplates"];
}
- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state objects:(id *)buffer count:(NSUInteger)len {
    return [self.entities countByEnumeratingWithState:state objects:buffer count:len];
}
+ (NSManagedObjectModel *)modelByMergingModels:(NSArray *)models {
    NSManagedObjectModel *merged = [[[self alloc] init] autorelease];
    NSMutableArray *entities = [NSMutableArray array];
    NSMutableSet *versions = [NSMutableSet set];
    for (NSManagedObjectModel *model in models) { [entities addObjectsFromArray:model.entities]; [versions unionSet:model.versionIdentifiers]; }
    merged.entities = entities;
    merged.versionIdentifiers = versions;
    return merged;
}
+ (NSManagedObjectModel *)mergedModelFromBundles:(NSArray *)bundles {
    if (!bundles) bundles = [NSArray arrayWithObject:[NSBundle mainBundle]];
    NSMutableArray *models = [NSMutableArray array];
    for (NSBundle *bundle in bundles) {
        NSString *resources = [bundle resourcePath];
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:resources error:NULL];
        for (NSString *file in files) {
            NSString *extension = [file pathExtension];
            if (![extension isEqualToString:@"momd"] && ![extension isEqualToString:@"mom"]) continue;
            NSURL *url = [NSURL fileURLWithPath:[resources stringByAppendingPathComponent:file]];
            NSManagedObjectModel *model = [[[NSManagedObjectModel alloc] initWithContentsOfURL:url] autorelease];
            if (model) [models addObject:model];
        }
    }
    return models.count ? [self modelByMergingModels:models] : nil;
}
+ (NSManagedObjectModel *)mergedModelFromBundles:(NSArray *)bundles forStoreMetadata:(NSDictionary *)metadata {
    NSManagedObjectModel *merged = [self mergedModelFromBundles:bundles];
    return [merged isConfiguration:nil compatibleWithStoreMetadata:metadata] ? merged : nil;
}
+ (NSManagedObjectModel *)modelByMergingModels:(NSArray *)models forStoreMetadata:(NSDictionary *)metadata {
    NSManagedObjectModel *merged = [self modelByMergingModels:models];
    return [merged isConfiguration:nil compatibleWithStoreMetadata:metadata] ? merged : nil;
}
+ (NSDictionary *)checksumsForVersionedModelAtURL:(NSURL *)url error:(NSError **)error {
    NSManagedObjectModel *model = [[[self alloc] initWithContentsOfURL:url] autorelease];
    if (!model) { CDReturnError(error, CDError(134100, @"The compiled model could not be read.")); return nil; }
    return [NSDictionary dictionaryWithObject:model.versionChecksum forKey:@"current"];
}
@end

double NSCoreDataVersionNumber = 1526.0;
const unsigned char NSCoreDataVersionString[] = "1526";
