// SPDX-License-Identifier: MIT OR Apache-2.0
#import "CloudKitInternal.h"
#import <math.h>

static char CKRecordValuesKey;
static char CKRecordBaselineKey;
static char CKRecordFieldOrderKey;

static id CKCopyRecordValue(id value)
{
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *items = [NSMutableArray arrayWithCapacity:[value count]];
        for (id item in value)
            [items addObject:CKCopyRecordValue(item)];
        return [[items copy] autorelease];
    }
    return [[value copy] autorelease];
}

static void CKAddRecordTokens(id value, NSMutableSet *tokens)
{
    if ([value isKindOfClass:[NSString class]]) {
        NSMutableString *token = [NSMutableString string];
        NSCharacterSet *letters = [NSCharacterSet alphanumericCharacterSet];
        NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
        for (NSUInteger index = 0; index < [value length]; index++) {
            unichar character = [value characterAtIndex:index];
            if ([letters characterIsMember:character] || character == '_') {
                [token appendFormat:@"%C", character];
            } else {
                if (token.length) {
                    [tokens addObject:[token lowercaseString]];
                    [token setString:@""];
                }
                if (![whitespace characterIsMember:character])
                    [tokens addObject:[[NSString stringWithCharacters:&character length:1] lowercaseString]];
            }
        }
        if (token.length)
            [tokens addObject:[token lowercaseString]];
    } else if ([value isKindOfClass:[NSArray class]]) {
        for (id item in value)
            CKAddRecordTokens(item, tokens);
    }
}

static NSArray *CKRecordAllowedClasses(void)
{
    static NSArray *classes = nil;
    if (!classes) {
        classes = [[NSArray alloc] initWithObjects:
            [NSArray class], [NSDictionary class], [NSString class], [NSNumber class],
            [NSDate class], [NSData class], [NSURL class], [CKRecordID class],
            [CKRecordZoneID class], [CKReference class], [CKAsset class],
            [NSNull class], nil];
    }
    return classes;
}

BOOL CKIsValidRecordValue(id value)
{
    if (!value || value == [NSNull null])
        return NO;
    if ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]] ||
        [value isKindOfClass:[NSDate class]] || [value isKindOfClass:[NSData class]] ||
        [value isKindOfClass:[CKReference class]] || [value isKindOfClass:[CKAsset class]])
        return YES;
    Class locationClass = NSClassFromString(@"CLLocation");
    if (locationClass && [value isKindOfClass:locationClass])
        return YES;
    if ([value isKindOfClass:[NSArray class]]) {
        for (id item in value)
            if (!CKIsValidRecordValue(item))
                return NO;
        return YES;
    }
    return NO;
}

void CKValidateQuery(NSPredicate *predicate)
{
    if (![predicate isKindOfClass:[NSPredicate class]])
        [NSException raise:@"CKException" format:@"A predicate is required for a CloudKit query"];
    NSString *predicateClass = NSStringFromClass([predicate class]);
    if ([predicateClass rangeOfString:@"Block" options:NSCaseInsensitiveSearch].location != NSNotFound)
        [NSException raise:NSInvalidArgumentException format:@"Block predicates cannot be used for CloudKit queries"];
}

@implementation CKRecordID (Finch)

- (instancetype)initWithRecordName:(NSString *)recordName
{
    return [self initWithRecordName:recordName zoneID:[CKRecordZone defaultRecordZone].zoneID];
}

- (instancetype)initWithRecordName:(NSString *)recordName zoneID:(CKRecordZoneID *)zoneID
{
    if (![recordName isKindOfClass:[NSString class]] || recordName.length == 0 ||
        recordName.length > 255 || ![recordName canBeConvertedToEncoding:NSASCIIStringEncoding]) {
        [self release];
        [NSException raise:NSInvalidArgumentException format:@"Record name must be a nonempty ASCII string of at most 255 characters"];
        return nil;
    }
    if (!zoneID)
        zoneID = [CKRecordZone defaultRecordZone].zoneID;
    self = [super init];
    if (self) {
        [self setValue:[[recordName copy] autorelease] forKey:@"recordName"];
        [self setValue:zoneID forKey:@"zoneID"];
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone
{
    return [[CKRecordID allocWithZone:zone] initWithRecordName:self.recordName zoneID:self.zoneID];
}

- (BOOL)isEqual:(id)object
{
    return object == self || ([object isKindOfClass:[CKRecordID class]] &&
        [self.recordName isEqual:[object recordName]] && [self.zoneID isEqual:[object zoneID]]);
}

- (NSUInteger)hash
{
    return self.recordName.hash ^ self.zoneID.hash;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:self.recordName forKey:@"recordName"];
    [coder encodeObject:self.zoneID forKey:@"zoneID"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSString *name = [coder decodeObjectOfClass:[NSString class] forKey:@"recordName"];
    CKRecordZoneID *zone = [coder decodeObjectOfClass:[CKRecordZoneID class] forKey:@"zoneID"];
    return [self initWithRecordName:name zoneID:zone];
}

+ (BOOL)supportsSecureCoding
{
    return YES;
}

@end

@implementation CKRecordZoneID (Finch)

- (instancetype)initWithZoneName:(NSString *)zoneName ownerName:(NSString *)ownerName
{
    if (![zoneName isKindOfClass:[NSString class]] || zoneName.length == 0 || zoneName.length > 255 ||
        ![zoneName canBeConvertedToEncoding:NSASCIIStringEncoding] ||
        ![ownerName isKindOfClass:[NSString class]] || ownerName.length == 0) {
        [self release];
        [NSException raise:NSInvalidArgumentException format:@"Zone name and owner name must not be empty"];
        return nil;
    }
    self = [super init];
    if (self) {
        [self setValue:[[zoneName copy] autorelease] forKey:@"zoneName"];
        [self setValue:[[ownerName copy] autorelease] forKey:@"ownerName"];
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone
{
    return [[CKRecordZoneID allocWithZone:zone] initWithZoneName:self.zoneName ownerName:self.ownerName];
}

- (BOOL)isEqual:(id)object
{
    return object == self || ([object isKindOfClass:[CKRecordZoneID class]] &&
        [self.zoneName isEqual:[object zoneName]] && [self.ownerName isEqual:[object ownerName]]);
}

- (NSUInteger)hash
{
    return self.zoneName.hash ^ self.ownerName.hash;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:self.zoneName forKey:@"zoneName"];
    [coder encodeObject:self.ownerName forKey:@"ownerName"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    return [self initWithZoneName:[coder decodeObjectOfClass:[NSString class] forKey:@"zoneName"]
                         ownerName:[coder decodeObjectOfClass:[NSString class] forKey:@"ownerName"]];
}

+ (BOOL)supportsSecureCoding
{
    return YES;
}

@end

@implementation CKRecordZone (Finch)

+ (CKRecordZone *)defaultRecordZone
{
    static CKRecordZone *zone = nil;
    if (!zone)
        zone = [[CKRecordZone alloc] initWithZoneName:CKRecordZoneDefaultName];
    return zone;
}

- (instancetype)initWithZoneName:(NSString *)zoneName
{
    CKRecordZoneID *zoneID = [[[CKRecordZoneID alloc] initWithZoneName:zoneName ownerName:CKCurrentUserDefaultName] autorelease];
    return [self initWithZoneID:zoneID];
}

- (instancetype)initWithZoneID:(CKRecordZoneID *)zoneID
{
    if (![zoneID isKindOfClass:[CKRecordZoneID class]]) {
        [self release];
        [NSException raise:NSInvalidArgumentException format:@"A record zone identifier is required"];
        return nil;
    }
    self = [super init];
    if (self)
        [self setValue:zoneID forKey:@"zoneID"];
    return self;
}

- (id)copyWithZone:(NSZone *)zone
{
    CKRecordZone *copy = [[CKRecordZone allocWithZone:zone] initWithZoneID:self.zoneID];
    [copy setValue:@(self.capabilities) forKey:@"capabilities"];
    [copy setValue:@(self.encryptionScope) forKey:@"encryptionScope"];
    if (self.share)
        [copy setValue:self.share forKey:@"share"];
    return copy;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:self.zoneID forKey:@"zoneID"];
    [coder encodeInteger:self.capabilities forKey:@"capabilities"];
    [coder encodeInteger:self.encryptionScope forKey:@"encryptionScope"];
    [coder encodeObject:self.share forKey:@"share"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    CKRecordZoneID *zoneID = [coder decodeObjectOfClass:[CKRecordZoneID class] forKey:@"zoneID"];
    self = [self initWithZoneID:zoneID];
    if (self) {
        [self setValue:@([coder decodeIntegerForKey:@"capabilities"]) forKey:@"capabilities"];
        [self setValue:@([coder decodeIntegerForKey:@"encryptionScope"]) forKey:@"encryptionScope"];
        [self setValue:[coder decodeObjectOfClass:[CKReference class] forKey:@"share"] forKey:@"share"];
    }
    return self;
}

+ (BOOL)supportsSecureCoding
{
    return YES;
}

@end

@implementation CKReference (Finch)

- (instancetype)initWithRecordID:(CKRecordID *)recordID action:(CKReferenceAction)action
{
    if (![recordID isKindOfClass:[CKRecordID class]] ||
        (action != CKReferenceActionNone && action != CKReferenceActionDeleteSelf)) {
        [self release];
        [NSException raise:NSInvalidArgumentException format:@"A record identifier and valid reference action are required"];
        return nil;
    }
    self = [super init];
    if (self) {
        [self setValue:recordID forKey:@"recordID"];
        [self setValue:@(action) forKey:@"referenceAction"];
    }
    return self;
}

- (instancetype)initWithRecord:(CKRecord *)record action:(CKReferenceAction)action
{
    return [self initWithRecordID:record.recordID action:action];
}

- (id)copyWithZone:(NSZone *)zone
{
    return [[CKReference allocWithZone:zone] initWithRecordID:self.recordID action:self.referenceAction];
}

- (BOOL)isEqual:(id)object
{
    return object == self || ([object isKindOfClass:[CKReference class]] &&
        self.referenceAction == [object referenceAction] && [self.recordID isEqual:[object recordID]]);
}

- (NSUInteger)hash
{
    return self.recordID.hash ^ (NSUInteger)self.referenceAction;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:self.recordID forKey:@"recordID"];
    [coder encodeInteger:self.referenceAction forKey:@"referenceAction"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    CKRecordID *recordID = [coder decodeObjectOfClass:[CKRecordID class] forKey:@"recordID"];
    return [self initWithRecordID:recordID action:[coder decodeIntegerForKey:@"referenceAction"]];
}

+ (BOOL)supportsSecureCoding
{
    return YES;
}

@end

@implementation CKAsset (Finch)

- (instancetype)initWithFileURL:(NSURL *)fileURL
{
    if (![fileURL isKindOfClass:[NSURL class]] || !fileURL.isFileURL) {
        [self release];
        [NSException raise:NSInvalidArgumentException format:@"CKAsset requires a file URL"];
        return nil;
    }
    self = [super init];
    if (self)
        [self setValue:fileURL forKey:@"fileURL"];
    return self;
}

- (id)copyWithZone:(NSZone *)zone
{
    return [[CKAsset allocWithZone:zone] initWithFileURL:self.fileURL];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:self.fileURL forKey:@"fileURL"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSURL *url = [coder decodeObjectOfClass:[NSURL class] forKey:@"fileURL"];
    return [self initWithFileURL:url];
}

+ (BOOL)supportsSecureCoding
{
    return YES;
}

@end

@implementation CKRecord (Finch)

- (instancetype)initWithRecordType:(CKRecordType)recordType
{
    CKRecordID *recordID = [[[CKRecordID alloc] initWithRecordName:[[NSUUID UUID] UUIDString]] autorelease];
    return [self initWithRecordType:recordType recordID:recordID];
}

- (instancetype)initWithRecordType:(CKRecordType)recordType recordID:(CKRecordID *)recordID
{
    if (![recordType isKindOfClass:[NSString class]] || recordType.length == 0 ||
        ![recordID isKindOfClass:[CKRecordID class]]) {
        [self release];
        [NSException raise:NSInvalidArgumentException format:@"A record type and record identifier are required"];
        return nil;
    }
    self = [super init];
    if (self) {
        [self setValue:[[recordType copy] autorelease] forKey:@"recordType"];
        [self setValue:recordID forKey:@"recordID"];
        objc_setAssociatedObject(self, &CKRecordValuesKey, [NSMutableDictionary dictionary], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &CKRecordBaselineKey, [NSDictionary dictionary], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &CKRecordFieldOrderKey, [NSMutableArray array], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return self;
}

- (instancetype)initWithRecordType:(CKRecordType)recordType zoneID:(CKRecordZoneID *)zoneID
{
    CKRecordID *recordID = [[[CKRecordID alloc] initWithRecordName:[[NSUUID UUID] UUIDString]
        zoneID:zoneID] autorelease];
    return [self initWithRecordType:recordType recordID:recordID];
}

- (NSDictionary *)_fieldValues
{
    NSMutableDictionary *values = objc_getAssociatedObject(self, &CKRecordValuesKey);
    if (!values) {
        values = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(self, &CKRecordValuesKey, values, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return values;
}

- (id)objectForKey:(CKRecordFieldKey)key
{
    return key ? [[self _fieldValues] objectForKey:key] : nil;
}

- (void)setObject:(id)object forKey:(CKRecordFieldKey)key
{
    if (![key isKindOfClass:[NSString class]] || key.length == 0 || [key hasPrefix:@"___"])
        [NSException raise:NSInvalidArgumentException format:@"A nonempty, non-system field key is required"];
    if (object && !CKIsValidRecordValue(object))
        [NSException raise:NSInvalidArgumentException format:@"The value for %@ is not a CloudKit record value", key];
    NSMutableDictionary *values = (NSMutableDictionary *)[self _fieldValues];
    NSMutableArray *order = objc_getAssociatedObject(self, &CKRecordFieldOrderKey);
    if (!order) {
        order = [NSMutableArray arrayWithArray:[values allKeys]];
        objc_setAssociatedObject(self, &CKRecordFieldOrderKey, order, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (object) {
        if (![values objectForKey:key] && ![order containsObject:key])
            [order addObject:key];
        [values setObject:CKCopyRecordValue(object) forKey:key];
    } else {
        [values removeObjectForKey:key];
        [order removeObject:key];
    }
}

- (NSArray *)allKeys
{
    NSDictionary *values = [self _fieldValues];
    NSArray *order = objc_getAssociatedObject(self, &CKRecordFieldOrderKey);
    if (!order)
        return [[values allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *keys = [NSMutableArray arrayWithCapacity:order.count];
    for (NSString *key in order)
        if ([values objectForKey:key])
            [keys addObject:key];
    return keys;
}

- (NSArray *)allTokens
{
    NSMutableSet *tokens = [NSMutableSet set];
    for (id value in [[self _fieldValues] allValues])
        CKAddRecordTokens(value, tokens);
    return tokens.count ? [tokens allObjects] : nil;
}

- (id)objectForKeyedSubscript:(CKRecordFieldKey)key
{
    return [self objectForKey:key];
}

- (void)setObject:(id)object forKeyedSubscript:(CKRecordFieldKey)key
{
    [self setObject:object forKey:key];
}

- (NSArray *)changedKeys
{
    NSDictionary *current = [self _fieldValues];
    NSDictionary *baseline = objc_getAssociatedObject(self, &CKRecordBaselineKey) ?: @{};
    NSMutableArray *keys = [NSMutableArray arrayWithArray:objc_getAssociatedObject(self, &CKRecordFieldOrderKey) ?: @[]];
    for (NSString *key in [baseline allKeys])
        if (![keys containsObject:key])
            [keys addObject:key];
    NSMutableArray *changed = [NSMutableArray array];
    for (NSString *key in keys) {
        id currentValue = [current objectForKey:key];
        id baselineValue = [baseline objectForKey:key];
        if (currentValue != baselineValue && ![currentValue isEqual:baselineValue])
            [changed addObject:key];
    }
    return changed;
}

- (void)encodeSystemFieldsWithCoder:(NSCoder *)coder
{
    [coder encodeObject:self.recordType forKey:@"RecordType"];
    [coder encodeObject:self.recordID forKey:@"RecordID"];
    [coder encodeObject:self.recordChangeTag forKey:@"ETag"];
    [coder encodeObject:self.creatorUserRecordID forKey:@"CreatorUserRecordID"];
    [coder encodeObject:self.creationDate forKey:@"RecordCtime"];
    [coder encodeObject:self.lastModifiedUserRecordID forKey:@"LastModifiedUserRecordID"];
    [coder encodeObject:self.modificationDate forKey:@"RecordMtime"];
    [coder encodeObject:self.parent forKey:@"ParentReference"];
    [coder encodeObject:self.share forKey:@"ShareReference"];
}

- (void)_setSystemValue:(id)value forKey:(NSString *)key
{
    if (value)
        [self setValue:value forKey:key];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [self encodeSystemFieldsWithCoder:coder];
    [coder encodeObject:[self _fieldValues] forKey:@"finch.fields"];
    [coder encodeObject:objc_getAssociatedObject(self, &CKRecordBaselineKey) forKey:@"finch.baseline"];
    [coder encodeObject:objc_getAssociatedObject(self, &CKRecordFieldOrderKey) forKey:@"finch.fieldOrder"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSString *recordType = [coder decodeObjectOfClass:[NSString class] forKey:@"RecordType"];
    CKRecordID *recordID = [coder decodeObjectOfClass:[CKRecordID class] forKey:@"RecordID"];
    self = [self initWithRecordType:recordType recordID:recordID];
    if (!self)
        return nil;
    NSSet *allowed = [NSSet setWithArray:CKRecordAllowedClasses()];
    NSDictionary *fields = [coder decodeObjectOfClasses:allowed forKey:@"finch.fields"];
    NSDictionary *baseline = [coder decodeObjectOfClasses:allowed forKey:@"finch.baseline"];
    if ([fields isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *copy = [fields mutableCopy];
        objc_setAssociatedObject(self, &CKRecordValuesKey, copy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [copy release];
    }
    NSArray *order = [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSArray class], [NSString class], nil]
        forKey:@"finch.fieldOrder"];
    if ([order isKindOfClass:[NSArray class]])
        objc_setAssociatedObject(self, &CKRecordFieldOrderKey, [NSMutableArray arrayWithArray:order], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    else if ([fields isKindOfClass:[NSDictionary class]])
        objc_setAssociatedObject(self, &CKRecordFieldOrderKey, [NSMutableArray arrayWithArray:[fields allKeys]], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if ([baseline isKindOfClass:[NSDictionary class]])
        objc_setAssociatedObject(self, &CKRecordBaselineKey, baseline, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self setValue:[coder decodeObjectOfClass:[NSString class] forKey:@"ETag"] forKey:@"recordChangeTag"];
    [self setValue:[coder decodeObjectOfClass:[CKRecordID class] forKey:@"CreatorUserRecordID"] forKey:@"creatorUserRecordID"];
    [self setValue:[coder decodeObjectOfClass:[NSDate class] forKey:@"RecordCtime"] forKey:@"creationDate"];
    [self setValue:[coder decodeObjectOfClass:[CKRecordID class] forKey:@"LastModifiedUserRecordID"] forKey:@"lastModifiedUserRecordID"];
    [self setValue:[coder decodeObjectOfClass:[NSDate class] forKey:@"RecordMtime"] forKey:@"modificationDate"];
    [self setValue:[coder decodeObjectOfClass:[CKReference class] forKey:@"ParentReference"] forKey:@"parent"];
    [self setValue:[coder decodeObjectOfClass:[CKReference class] forKey:@"ShareReference"] forKey:@"share"];
    return self;
}

- (id)copyWithZone:(NSZone *)zone
{
    CKRecord *copy = [[CKRecord allocWithZone:zone] initWithRecordType:self.recordType recordID:self.recordID];
    NSMutableDictionary *values = [[self _fieldValues] mutableCopy];
    objc_setAssociatedObject(copy, &CKRecordValuesKey, values, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [values release];
    NSArray *fieldOrder = objc_getAssociatedObject(self, &CKRecordFieldOrderKey) ?: [self allKeys];
    objc_setAssociatedObject(copy, &CKRecordFieldOrderKey, [NSMutableArray arrayWithArray:fieldOrder], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSDictionary *baseline = objc_getAssociatedObject(self, &CKRecordBaselineKey) ?: @{};
    NSDictionary *baselineCopy = [baseline copy];
    objc_setAssociatedObject(copy, &CKRecordBaselineKey, baselineCopy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [baselineCopy release];
    [copy setValue:self.recordChangeTag forKey:@"recordChangeTag"];
    [copy setValue:self.creatorUserRecordID forKey:@"creatorUserRecordID"];
    [copy setValue:self.creationDate forKey:@"creationDate"];
    [copy setValue:self.lastModifiedUserRecordID forKey:@"lastModifiedUserRecordID"];
    [copy setValue:self.modificationDate forKey:@"modificationDate"];
    [copy setValue:self.parent forKey:@"parent"];
    [copy setValue:self.share forKey:@"share"];
    return copy;
}

+ (BOOL)supportsSecureCoding
{
    return YES;
}

- (void)setParentReferenceFromRecord:(CKRecord *)parentRecord
{
    self.parent = parentRecord ? [[[CKReference alloc] initWithRecord:parentRecord action:CKReferenceActionDeleteSelf] autorelease] : nil;
}

- (void)setParentReferenceFromRecordID:(CKRecordID *)parentRecordID
{
    self.parent = parentRecordID ? [[[CKReference alloc] initWithRecordID:parentRecordID action:CKReferenceActionDeleteSelf] autorelease] : nil;
}

@end

@implementation CKQuery (Finch)

- (instancetype)initWithRecordType:(CKRecordType)recordType predicate:(NSPredicate *)predicate
{
    if (![recordType isKindOfClass:[NSString class]] || recordType.length == 0 || !predicate) {
        [self release];
        [NSException raise:NSInvalidArgumentException format:@"A record type and predicate are required"];
        return nil;
    }
    CKValidateQuery(predicate);
    self = [super init];
    if (self) {
        [self setValue:[[recordType copy] autorelease] forKey:@"recordType"];
        [self setValue:predicate forKey:@"predicate"];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSString *type = [coder decodeObjectOfClass:[NSString class] forKey:@"recordType"];
    NSPredicate *predicate = [coder decodeObjectOfClass:[NSPredicate class] forKey:@"predicate"];
    self = [self initWithRecordType:type predicate:predicate];
    if (self)
        self.sortDescriptors = [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSArray class], [NSSortDescriptor class], [CKLocationSortDescriptor class], nil] forKey:@"sortDescriptors"];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:self.recordType forKey:@"recordType"];
    [coder encodeObject:self.predicate forKey:@"predicate"];
    [coder encodeObject:self.sortDescriptors forKey:@"sortDescriptors"];
}

- (id)copyWithZone:(NSZone *)zone
{
    CKQuery *copy = [[CKQuery allocWithZone:zone] initWithRecordType:self.recordType predicate:self.predicate];
    copy.sortDescriptors = self.sortDescriptors;
    return copy;
}

+ (BOOL)supportsSecureCoding
{
    return YES;
}

@end

@implementation CKLocationSortDescriptor (Finch)

- (instancetype)initWithKey:(NSString *)key relativeLocation:(CLLocation *)relativeLocation
{
    if (![key isKindOfClass:[NSString class]] || key.length == 0 || !relativeLocation) {
        [self release];
        [NSException raise:NSInvalidArgumentException format:@"A key and relative location are required"];
        return nil;
    }
    self = [super initWithKey:key ascending:YES];
    if (self)
        [self setValue:relativeLocation forKey:@"relativeLocation"];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSString *key = [coder decodeObjectOfClass:[NSString class] forKey:@"key"];
    CLLocation *location = [coder decodeObjectForKey:@"relativeLocation"];
    self = [self initWithKey:key relativeLocation:location];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:self.key forKey:@"key"];
    [coder encodeObject:self.relativeLocation forKey:@"relativeLocation"];
}

+ (BOOL)supportsSecureCoding
{
    return YES;
}

@end
