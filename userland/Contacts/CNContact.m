/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CNContact and CNMutableContact: a contact is its identifier and a dictionary of property
 * values, with the set of keys that were fetched (all of them for a contact made here or
 * read from vCard; those asked for when the store fetched it). Reading a property that
 * wasn't fetched raises CNPropertyNotFetchedException, as Apple's does. Key descriptors are
 * the property keys themselves and aggregates of them (the formatter's, the comparator's,
 * vCard's).
 */
#import "Contacts_Finch.h"

NSArray<NSString *> *
FinchCNStringKeys(void)
{
    static NSArray *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      keys = @[ CNContactNamePrefixKey, CNContactGivenNameKey, CNContactMiddleNameKey, CNContactFamilyNameKey,
                CNContactPreviousFamilyNameKey, CNContactNameSuffixKey, CNContactNicknameKey, CNContactOrganizationNameKey,
                CNContactDepartmentNameKey, CNContactJobTitleKey, CNContactPhoneticGivenNameKey, CNContactPhoneticMiddleNameKey,
                CNContactPhoneticFamilyNameKey, CNContactPhoneticOrganizationNameKey, CNContactNoteKey ];
    });
    return keys;
}

NSArray<NSString *> *
FinchCNArrayKeys(void)
{
    static NSArray *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      keys = @[ CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactPostalAddressesKey, CNContactUrlAddressesKey,
                CNContactRelationsKey, CNContactSocialProfilesKey, CNContactInstantMessageAddressesKey, CNContactDatesKey ];
    });
    return keys;
}

NSArray<NSString *> *
FinchCNAllKeys(void)
{
    static NSArray *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      NSMutableArray *k = [NSMutableArray arrayWithObjects:CNContactIdentifierKey, CNContactTypeKey, nil];
      [k addObjectsFromArray:FinchCNStringKeys()];
      [k addObjectsFromArray:FinchCNArrayKeys()];
      [k addObjectsFromArray:@[ CNContactImageDataKey, CNContactThumbnailImageDataKey, CNContactImageDataAvailableKey,
                                CNContactBirthdayKey, CNContactNonGregorianBirthdayKey ]];
      keys = k;
    });
    return keys;
}

/* --- key descriptors --- */

@implementation NSString (Contacts)
@end

@implementation CNAggregateKeyDescriptor
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithKeyDescriptors:(NSArray *)descriptors description:(NSString *)description
{
    if ((self = [super init])) {
        _descriptors = [descriptors copy];
        _finchDescription = [description copy];
    }
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return self; }
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_descriptors forKey:@"keyDescriptors"];
    [coder encodeObject:_finchDescription forKey:@"description"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSSet *classes = [NSSet setWithObjects:[NSArray class], [NSString class], [CNAggregateKeyDescriptor class], nil];
    return [self initWithKeyDescriptors:[coder decodeObjectOfClasses:classes forKey:@"keyDescriptors"] ?: @[]
                            description:[coder decodeObjectOfClass:[NSString class] forKey:@"description"]];
}
- (NSString *)description
{
    return [NSString stringWithFormat:@"<CNAggregateKeyDescriptor: %p: kind=%@>", self, _finchDescription];
}
@end

/* The property keys a list of descriptors comes to. */
NSSet<NSString *> *
FinchCNKeysOfDescriptors(NSArray *descriptors)
{
    NSMutableSet *keys = [NSMutableSet set];
    for (id d in descriptors) {
        if ([d isKindOfClass:[NSString class]])
            [keys addObject:d];
        else if ([d isKindOfClass:[CNAggregateKeyDescriptor class]])
            [keys unionSet:FinchCNKeysOfDescriptors(((CNAggregateKeyDescriptor *)d)->_descriptors)];
        else
            [NSException raise:NSInvalidArgumentException format:@"Unsupported key descriptor %@", d];
    }
    return keys;
}

/* --- CNContact --- */

static NSString *
new_identifier(NSString *suffix)
{
    return [NSString stringWithFormat:@"%@:%@", [NSUUID UUID].UUIDString, suffix];
}

@implementation CNContact

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)init
{
    if ((self = [super init])) {
        _identifier = new_identifier(@"ABPerson");
        _values = [NSMutableDictionary dictionary];
    }
    return self;
}

- (instancetype)_finchInitWithIdentifier:(NSString *)identifier values:(NSDictionary *)values available:(NSSet *)available
{
    if ((self = [super init])) {
        _identifier = [identifier copy];
        _values = [values mutableCopy];
        _available = [available copy];
    }
    return self;
}

- (BOOL)isKeyAvailable:(NSString *)key
{
    if ([key isEqualToString:CNContactIdentifierKey])
        return YES;
    if ([key isEqualToString:CNContactImageDataAvailableKey] && [_available containsObject:CNContactImageDataKey])
        return YES;
    return !_available || [_available containsObject:key];
}

- (BOOL)areKeysAvailable:(NSArray *)keyDescriptors
{
    for (NSString *k in FinchCNKeysOfDescriptors(keyDescriptors))
        if (![self isKeyAvailable:k])
            return NO;
    return YES;
}

- (void)_finchCheck:(NSString *)key
{
    if (![self isKeyAvailable:key])
        [NSException raise:CNContactPropertyNotFetchedExceptionName format:@"A property was not requested when contact was fetched."];
}

- (id)_finchValue:(NSString *)key
{
    [self _finchCheck:key];
    return _values[key];
}

- (NSString *)_finchString:(NSString *)key { return [self _finchValue:key] ?: @""; }
- (NSArray *)_finchArray:(NSString *)key { return [self _finchValue:key] ?: @[]; }

- (NSString *)identifier { return _identifier; }
- (CNContactType)contactType { return [[self _finchValue:CNContactTypeKey] integerValue]; }

#define STRING_GETTER(sel, key) \
    -(NSString *)sel { return [self _finchString:key]; }
STRING_GETTER(namePrefix, CNContactNamePrefixKey)
STRING_GETTER(givenName, CNContactGivenNameKey)
STRING_GETTER(middleName, CNContactMiddleNameKey)
STRING_GETTER(familyName, CNContactFamilyNameKey)
STRING_GETTER(previousFamilyName, CNContactPreviousFamilyNameKey)
STRING_GETTER(nameSuffix, CNContactNameSuffixKey)
STRING_GETTER(nickname, CNContactNicknameKey)
STRING_GETTER(organizationName, CNContactOrganizationNameKey)
STRING_GETTER(departmentName, CNContactDepartmentNameKey)
STRING_GETTER(jobTitle, CNContactJobTitleKey)
STRING_GETTER(phoneticGivenName, CNContactPhoneticGivenNameKey)
STRING_GETTER(phoneticMiddleName, CNContactPhoneticMiddleNameKey)
STRING_GETTER(phoneticFamilyName, CNContactPhoneticFamilyNameKey)
STRING_GETTER(phoneticOrganizationName, CNContactPhoneticOrganizationNameKey)
STRING_GETTER(note, CNContactNoteKey)

#define ARRAY_GETTER(sel, key) \
    -(NSArray *)sel { return [self _finchArray:key]; }
ARRAY_GETTER(phoneNumbers, CNContactPhoneNumbersKey)
ARRAY_GETTER(emailAddresses, CNContactEmailAddressesKey)
ARRAY_GETTER(postalAddresses, CNContactPostalAddressesKey)
ARRAY_GETTER(urlAddresses, CNContactUrlAddressesKey)
ARRAY_GETTER(contactRelations, CNContactRelationsKey)
ARRAY_GETTER(socialProfiles, CNContactSocialProfilesKey)
ARRAY_GETTER(instantMessageAddresses, CNContactInstantMessageAddressesKey)
ARRAY_GETTER(dates, CNContactDatesKey)

- (NSData *)imageData { return [self _finchValue:CNContactImageDataKey]; }
- (NSData *)thumbnailImageData { return [self _finchValue:CNContactThumbnailImageDataKey]; }
- (BOOL)imageDataAvailable
{
    [self _finchCheck:CNContactImageDataAvailableKey];
    return _values[CNContactImageDataKey] != nil;
}
- (NSDateComponents *)birthday { return [self _finchValue:CNContactBirthdayKey]; }
- (NSDateComponents *)nonGregorianBirthday { return [self _finchValue:CNContactNonGregorianBirthdayKey]; }

/* KVC answers the fetched-key check too (predicates read contacts with it). */
- (id)valueForUndefinedKey:(NSString *)key
{
    return [super valueForUndefinedKey:key];
}

- (BOOL)isUnifiedWithContactWithIdentifier:(NSString *)contactIdentifier
{
    return [_identifier isEqualToString:contactIdentifier];
}

- (id)copyWithZone:(NSZone *)zone
{
    if ([self class] == [CNContact class])
        return self;
    CNContact *c = [[CNContact alloc] _finchInitWithIdentifier:_identifier values:_values available:_available];
    c->_persisted = _persisted;
    return c;
}

- (id)mutableCopyWithZone:(NSZone *)zone
{
    CNMutableContact *c = [[CNMutableContact alloc] _finchInitWithIdentifier:_identifier values:_values available:_available];
    c->_persisted = _persisted;
    return c;
}

- (BOOL)isEqual:(id)object
{
    if (object == self)
        return YES;
    if (![object isKindOfClass:[CNContact class]])
        return NO;
    CNContact *o = object;
    return [_identifier isEqualToString:o->_identifier] && [_values isEqualToDictionary:o->_values];
}

- (NSUInteger)hash { return _identifier.hash; }

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p: identifier=%@%@>", [self class], self, _identifier,
                                      _persisted ? @"" : @" non-persisted"];
}

/* (archived with the ivar names Apple's archives use) */
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_identifier forKey:@"_identifier"];
    for (NSString *k in _values)
        [coder encodeObject:_values[k] forKey:[@"_" stringByAppendingString:k]];
    if (_available)
        [coder encodeObject:_available forKey:@"availableKeys_v2"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if (!(self = [super init]))
        return nil;
    NSSet *classes = [NSSet setWithObjects:[NSString class], [NSNumber class], [NSData class], [NSArray class], [NSSet class],
                                           [NSDateComponents class], [CNLabeledValue class], [CNPhoneNumber class],
                                           [CNPostalAddress class], [CNContactRelation class], [CNSocialProfile class],
                                           [CNInstantMessageAddress class], nil];
    _identifier = [coder decodeObjectOfClass:[NSString class] forKey:@"_identifier"] ?: new_identifier(@"ABPerson");
    _values = [NSMutableDictionary dictionary];
    for (NSString *k in FinchCNAllKeys()) {
        if ([k isEqualToString:CNContactIdentifierKey] || [k isEqualToString:CNContactImageDataAvailableKey])
            continue;
        id v = [coder decodeObjectOfClasses:classes forKey:[@"_" stringByAppendingString:k]];
        if (v && ![v isKindOfClass:[NSNull class]])
            _values[k] = v;
    }
    if ([coder containsValueForKey:@"_contactType"] && !_values[CNContactTypeKey])
        _values[CNContactTypeKey] = @([coder decodeIntegerForKey:@"_contactType"]);
    _available = [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSSet class], [NSString class], nil] forKey:@"availableKeys_v2"];
    return self;
}

+ (NSString *)localizedStringForKey:(NSString *)key
{
    return FinchCNLocalizedString(@"contact", key, nil);
}

/* The name a contact sorts by, given name or family name first. */
static NSString *
sort_name(CNContact *c, CNContactSortOrder order)
{
    NSString *given = [c isKeyAvailable:CNContactGivenNameKey] ? c.givenName : @"";
    NSString *family = [c isKeyAvailable:CNContactFamilyNameKey] ? c.familyName : @"";
    NSString *org = [c isKeyAvailable:CNContactOrganizationNameKey] ? c.organizationName : @"";
    BOOL isOrg = [c isKeyAvailable:CNContactTypeKey] && c.contactType == CNContactTypeOrganization;
    if (isOrg && org.length)
        return org;
    NSString *first = order == CNContactSortOrderGivenName ? given : family;
    NSString *second = order == CNContactSortOrderGivenName ? family : given;
    NSString *s = first.length && second.length ? [NSString stringWithFormat:@"%@ %@", first, second] : first.length ? first : second;
    return s.length ? s : org;
}

+ (NSComparator)comparatorForNameSortOrder:(CNContactSortOrder)sortOrder
{
    if (sortOrder == CNContactSortOrderUserDefault || sortOrder == CNContactSortOrderNone)
        sortOrder = [CNContactsUserDefaults sharedDefaults].sortOrder;
    return [^NSComparisonResult(CNContact *a, CNContact *b) {
      NSString *x = sort_name(a, sortOrder), *y = sort_name(b, sortOrder);
      /* nameless contacts last */
      if (!x.length || !y.length)
          return x.length == y.length ? NSOrderedSame : x.length ? NSOrderedAscending : NSOrderedDescending;
      return [x localizedStandardCompare:y];
    } copy];
}

+ (id<CNKeyDescriptor>)descriptorForAllComparatorKeys
{
    return [[CNAggregateKeyDescriptor alloc]
        initWithKeyDescriptors:@[ CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactTypeKey,
                                  CNContactPhoneticGivenNameKey, CNContactPhoneticFamilyNameKey ]
                   description:@"Formatter style: 1003"];
}

@end

/* --- CNMutableContact --- */

@implementation CNMutableContact

- (void)_finchSet:(id)value forKey:(NSString *)key
{
    if (value)
        _values[key] = value;
    else
        [_values removeObjectForKey:key];
    if (_available && ![_available containsObject:key])
        _available = [_available setByAddingObject:key];
}

- (void)setContactType:(CNContactType)t { [self _finchSet:@(t) forKey:CNContactTypeKey]; }

#define STRING_SETTER(sel, key) \
    -(void)sel:(NSString *)v { [self _finchSet:[v copy] forKey:key]; }
STRING_SETTER(setNamePrefix, CNContactNamePrefixKey)
STRING_SETTER(setGivenName, CNContactGivenNameKey)
STRING_SETTER(setMiddleName, CNContactMiddleNameKey)
STRING_SETTER(setFamilyName, CNContactFamilyNameKey)
STRING_SETTER(setPreviousFamilyName, CNContactPreviousFamilyNameKey)
STRING_SETTER(setNameSuffix, CNContactNameSuffixKey)
STRING_SETTER(setNickname, CNContactNicknameKey)
STRING_SETTER(setOrganizationName, CNContactOrganizationNameKey)
STRING_SETTER(setDepartmentName, CNContactDepartmentNameKey)
STRING_SETTER(setJobTitle, CNContactJobTitleKey)
STRING_SETTER(setPhoneticGivenName, CNContactPhoneticGivenNameKey)
STRING_SETTER(setPhoneticMiddleName, CNContactPhoneticMiddleNameKey)
STRING_SETTER(setPhoneticFamilyName, CNContactPhoneticFamilyNameKey)
STRING_SETTER(setPhoneticOrganizationName, CNContactPhoneticOrganizationNameKey)
STRING_SETTER(setNote, CNContactNoteKey)

#define ARRAY_SETTER(sel, key) \
    -(void)sel:(NSArray *)v { [self _finchSet:[v copy] forKey:key]; }
ARRAY_SETTER(setPhoneNumbers, CNContactPhoneNumbersKey)
ARRAY_SETTER(setEmailAddresses, CNContactEmailAddressesKey)
ARRAY_SETTER(setPostalAddresses, CNContactPostalAddressesKey)
ARRAY_SETTER(setUrlAddresses, CNContactUrlAddressesKey)
ARRAY_SETTER(setContactRelations, CNContactRelationsKey)
ARRAY_SETTER(setSocialProfiles, CNContactSocialProfilesKey)
ARRAY_SETTER(setInstantMessageAddresses, CNContactInstantMessageAddressesKey)
ARRAY_SETTER(setDates, CNContactDatesKey)

- (void)setImageData:(NSData *)v
{
    [self _finchSet:[v copy] forKey:CNContactImageDataKey];
    /* (the thumbnail comes when the store saves it, as with Apple's) */
    [self _finchSet:nil forKey:CNContactThumbnailImageDataKey];
}
- (void)setBirthday:(NSDateComponents *)v { [self _finchSet:[v copy] forKey:CNContactBirthdayKey]; }
- (void)setNonGregorianBirthday:(NSDateComponents *)v { [self _finchSet:[v copy] forKey:CNContactNonGregorianBirthdayKey]; }

/* (the declared property types make these the getters too) */
- (CNContactType)contactType { return [super contactType]; }

@end
