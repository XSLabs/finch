/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The values a contact holds: labeled values, phone numbers, postal addresses, social
 * profiles, instant message addresses and related names; and groups, containers and
 * contact properties. Each is immutable (copies are new objects with the same contents,
 * as Apple's are) and archives with the keys Apple's archives use.
 */
#import "Contacts_Finch.h"

static NSString *
nil_string(id s)
{
    return s ?: @"(nil)";
}

static BOOL
same(id a, id b)
{
    return a == b || [a isEqual:b];
}

/* --- CNLabeledValue --- */

@interface CNLabeledValue () {
    NSString *_identifier;
    NSString *_label;
    id _value;
}
- (instancetype)_finchInitWithIdentifier:(NSString *)identifier label:(NSString *)label value:(id)value FINCH_INIT;
@end

@implementation CNLabeledValue

+ (BOOL)supportsSecureCoding { return YES; }

+ (instancetype)labeledValueWithLabel:(NSString *)label value:(id)value
{
    return [[self alloc] initWithLabel:label value:value];
}

- (instancetype)_finchInitWithIdentifier:(NSString *)identifier label:(NSString *)label value:(id)value
{
    if ((self = [super init])) {
        _identifier = [identifier copy];
        _label = [label copy];
        _value = [value copy];
    }
    return self;
}

- (instancetype)initWithLabel:(NSString *)label value:(id)value
{
    return [self _finchInitWithIdentifier:[NSUUID UUID].UUIDString label:label value:value];
}

- (instancetype)init { return [self _finchInitWithIdentifier:[NSUUID UUID].UUIDString label:nil value:nil]; }

- (NSString *)identifier { return _identifier; }
- (NSString *)label { return _label; }
- (id)value { return _value; }

- (instancetype)labeledValueBySettingLabel:(NSString *)label
{
    return [[[self class] alloc] _finchInitWithIdentifier:_identifier label:label value:_value];
}
- (instancetype)labeledValueBySettingValue:(id)value
{
    return [[[self class] alloc] _finchInitWithIdentifier:_identifier label:_label value:value];
}
- (instancetype)labeledValueBySettingLabel:(NSString *)label value:(id)value
{
    return [[[self class] alloc] _finchInitWithIdentifier:_identifier label:label value:value];
}

+ (NSString *)localizedStringForLabel:(NSString *)label
{
    return FinchCNLocalizedString(@"label", label, label);
}

- (id)copyWithZone:(NSZone *)zone
{
    return [[[self class] alloc] _finchInitWithIdentifier:_identifier label:_label value:_value];
}

- (BOOL)isEqual:(id)o
{
    if (o == self)
        return YES;
    if (![o isKindOfClass:[CNLabeledValue class]])
        return NO;
    CNLabeledValue *l = o;
    return same(_identifier, l->_identifier) && same(_label, l->_label) && same(_value, l->_value);
}
- (NSUInteger)hash { return _identifier.hash ^ [_value hash]; }

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p: identifier=%@, label=%@, value=%@, iOSLegacyIdentifier=-1>", [self class], self,
                                      _identifier, nil_string(_label), nil_string(_value)];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_identifier forKey:@"_identifier"];
    [coder encodeObject:_label forKey:@"_label"];
    [coder encodeObject:_value forKey:@"_value"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSSet *values = [NSSet setWithObjects:[NSString class], [NSDateComponents class], [CNPhoneNumber class], [CNPostalAddress class],
                                          [CNContactRelation class], [CNSocialProfile class], [CNInstantMessageAddress class], nil];
    return [self _finchInitWithIdentifier:[coder decodeObjectOfClass:[NSString class] forKey:@"_identifier"] ?: [NSUUID UUID].UUIDString
                                    label:[coder decodeObjectOfClass:[NSString class] forKey:@"_label"]
                                    value:[coder decodeObjectOfClasses:values forKey:@"_value"]];
}

@end

/* --- CNPhoneNumber --- */

@interface CNPhoneNumber () {
    NSString *_stringValue;
}
@end

@implementation CNPhoneNumber

+ (BOOL)supportsSecureCoding { return YES; }

+ (instancetype)phoneNumberWithStringValue:(NSString *)stringValue
{
    return [[self alloc] initWithStringValue:stringValue];
}

- (instancetype)initWithStringValue:(NSString *)string
{
    if (!string)
        return nil;
    if ((self = [super init]))
        _stringValue = [string copy];
    return self;
}

- (instancetype)init { return [self initWithStringValue:@""]; }

- (NSString *)stringValue { return _stringValue; }

/* (private, used through KVC) the country the number is in: the current region's */
- (NSString *)countryCode
{
    return [[[NSLocale currentLocale] objectForKey:NSLocaleCountryCode] lowercaseString] ?: @"us";
}

/* (private, used through KVC) the number's digits, in international form when the
   region's dialling is known (North American numbers: +1 and ten digits) */
- (NSString *)digits
{
    NSMutableString *d = [NSMutableString string];
    BOOL plus = NO;
    for (NSUInteger i = 0; i < _stringValue.length; i++) {
        unichar c = [_stringValue characterAtIndex:i];
        if (c >= '0' && c <= '9')
            [d appendFormat:@"%C", c];
        else if (c == '+' && !d.length)
            plus = YES;
    }
    if (plus)
        return [@"+" stringByAppendingString:d];
    NSString *cc = self.countryCode;
    if ([cc isEqualToString:@"us"] || [cc isEqualToString:@"ca"]) {
        if (d.length == 10)
            return [@"+1" stringByAppendingString:d];
        if (d.length == 11 && [d hasPrefix:@"1"])
            return [@"+" stringByAppendingString:d];
    }
    return d;
}

- (id)copyWithZone:(NSZone *)zone { return self; }
- (BOOL)isEqual:(id)o { return o == self || ([o isKindOfClass:[CNPhoneNumber class]] && same(_stringValue, ((CNPhoneNumber *)o)->_stringValue)); }
- (NSUInteger)hash { return _stringValue.hash; }

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p: stringValue=%@, initialCountryCode=(nil)>", [self class], self, _stringValue];
}

- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeObject:_stringValue forKey:@"stringValue"]; }
- (instancetype)initWithCoder:(NSCoder *)coder
{
    return [self initWithStringValue:[coder decodeObjectOfClass:[NSString class] forKey:@"stringValue"] ?: @""];
}

@end

/* --- CNPostalAddress --- */

static NSArray<NSString *> *
postal_keys(void)
{
    return @[ CNPostalAddressStreetKey, CNPostalAddressSubLocalityKey, CNPostalAddressCityKey, CNPostalAddressSubAdministrativeAreaKey,
              CNPostalAddressStateKey, CNPostalAddressPostalCodeKey, CNPostalAddressCountryKey, CNPostalAddressISOCountryCodeKey ];
}

@interface CNPostalAddress () {
  @public
    NSMutableDictionary *_parts;
}
@end

@implementation CNPostalAddress

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)init
{
    if ((self = [super init]))
        _parts = [NSMutableDictionary dictionary];
    return self;
}

- (NSString *)_finchPart:(NSString *)key { return _parts[key] ?: @""; }
- (NSString *)street { return [self _finchPart:CNPostalAddressStreetKey]; }
- (NSString *)subLocality { return [self _finchPart:CNPostalAddressSubLocalityKey]; }
- (NSString *)city { return [self _finchPart:CNPostalAddressCityKey]; }
- (NSString *)subAdministrativeArea { return [self _finchPart:CNPostalAddressSubAdministrativeAreaKey]; }
- (NSString *)state { return [self _finchPart:CNPostalAddressStateKey]; }
- (NSString *)postalCode { return [self _finchPart:CNPostalAddressPostalCodeKey]; }
- (NSString *)country { return [self _finchPart:CNPostalAddressCountryKey]; }
- (NSString *)ISOCountryCode { return [self _finchPart:CNPostalAddressISOCountryCodeKey]; }

+ (NSString *)localizedStringForKey:(NSString *)key
{
    return FinchCNLocalizedString(@"postal", key, nil);
}

- (id)copyWithZone:(NSZone *)zone
{
    CNPostalAddress *a = [[CNPostalAddress alloc] init];
    [a->_parts setDictionary:_parts];
    return a;
}

- (id)mutableCopyWithZone:(NSZone *)zone
{
    CNMutablePostalAddress *a = [[CNMutablePostalAddress alloc] init];
    [a->_parts setDictionary:_parts];
    return a;
}

- (BOOL)isEqual:(id)o
{
    if (o == self)
        return YES;
    if (![o isKindOfClass:[CNPostalAddress class]])
        return NO;
    for (NSString *k in postal_keys())
        if (![[self _finchPart:k] isEqualToString:[(CNPostalAddress *)o _finchPart:k]])
            return NO;
    return YES;
}
- (NSUInteger)hash { return self.street.hash ^ self.city.hash; }

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p: street=%@, subLocality=%@, city=%@, subAdministrativeArea=%@, state=%@, "
                                      @"postalCode=%@, country=%@, countryCode=%@>",
                                      [self class], self, self.street, self.subLocality, self.city, self.subAdministrativeArea,
                                      self.state, self.postalCode, self.country, self.ISOCountryCode];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    for (NSString *k in postal_keys())
        [coder encodeObject:_parts[k] forKey:[@"_" stringByAppendingString:k]];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [self init]))
        for (NSString *k in postal_keys()) {
            NSString *v = [coder decodeObjectOfClass:[NSString class] forKey:[@"_" stringByAppendingString:k]];
            if (v)
                _parts[k] = v;
        }
    return self;
}

@end

@implementation CNMutablePostalAddress
- (void)_finchSet:(NSString *)v key:(NSString *)k
{
    if (v)
        _parts[k] = [v copy];
    else
        [_parts removeObjectForKey:k];
}
- (void)setStreet:(NSString *)v { [self _finchSet:v key:CNPostalAddressStreetKey]; }
- (void)setSubLocality:(NSString *)v { [self _finchSet:v key:CNPostalAddressSubLocalityKey]; }
- (void)setCity:(NSString *)v { [self _finchSet:v key:CNPostalAddressCityKey]; }
- (void)setSubAdministrativeArea:(NSString *)v { [self _finchSet:v key:CNPostalAddressSubAdministrativeAreaKey]; }
- (void)setState:(NSString *)v { [self _finchSet:v key:CNPostalAddressStateKey]; }
- (void)setPostalCode:(NSString *)v { [self _finchSet:v key:CNPostalAddressPostalCodeKey]; }
- (void)setCountry:(NSString *)v { [self _finchSet:v key:CNPostalAddressCountryKey]; }
- (void)setISOCountryCode:(NSString *)v { [self _finchSet:v key:CNPostalAddressISOCountryCodeKey]; }
/* (the declared properties make these the getters too) */
- (NSString *)street { return [super street]; }
- (NSString *)subLocality { return [super subLocality]; }
- (NSString *)city { return [super city]; }
- (NSString *)subAdministrativeArea { return [super subAdministrativeArea]; }
- (NSString *)state { return [super state]; }
- (NSString *)postalCode { return [super postalCode]; }
- (NSString *)country { return [super country]; }
- (NSString *)ISOCountryCode { return [super ISOCountryCode]; }
@end

/* --- CNContactRelation, CNSocialProfile, CNInstantMessageAddress --- */

@interface CNContactRelation () {
    NSString *_name;
}
@end

@implementation CNContactRelation
+ (BOOL)supportsSecureCoding { return YES; }
+ (instancetype)contactRelationWithName:(NSString *)name { return [[self alloc] initWithName:name]; }
- (instancetype)initWithName:(NSString *)name
{
    if ((self = [super init]))
        _name = [name copy] ?: @"";
    return self;
}
- (instancetype)init { return [self initWithName:@""]; }
- (NSString *)name { return _name; }
- (id)copyWithZone:(NSZone *)zone { return self; }
- (BOOL)isEqual:(id)o { return o == self || ([o isKindOfClass:[CNContactRelation class]] && [_name isEqual:[o name]]); }
- (NSUInteger)hash { return _name.hash; }
- (NSString *)description { return [NSString stringWithFormat:@"<%@: %p: name=%@>", [self class], self, _name]; }
- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeObject:_name forKey:@"_name"]; }
- (instancetype)initWithCoder:(NSCoder *)coder { return [self initWithName:[coder decodeObjectOfClass:[NSString class] forKey:@"_name"]]; }
@end

@interface CNSocialProfile () {
    NSString *_urlString, *_username, *_userIdentifier, *_service;
}
@end

@implementation CNSocialProfile
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithUrlString:(NSString *)urlString username:(NSString *)username userIdentifier:(NSString *)userIdentifier
                          service:(NSString *)service
{
    if ((self = [super init])) {
        _urlString = [urlString copy];
        _username = [username copy];
        _userIdentifier = [userIdentifier copy];
        _service = [service copy];
    }
    return self;
}
- (NSString *)urlString { return _urlString; }
- (NSString *)username { return _username; }
- (NSString *)userIdentifier { return _userIdentifier; }
- (NSString *)service { return _service; }
+ (NSString *)localizedStringForKey:(NSString *)key { return FinchCNLocalizedString(@"socialkey", key, nil); }
+ (NSString *)localizedStringForService:(NSString *)service { return FinchCNLocalizedString(@"socialservice", service, service); }
- (id)copyWithZone:(NSZone *)zone { return self; }
- (BOOL)isEqual:(id)o
{
    if (o == self)
        return YES;
    if (![o isKindOfClass:[CNSocialProfile class]])
        return NO;
    CNSocialProfile *p = o;
    return same(_urlString, p->_urlString) && same(_username, p->_username) && same(_userIdentifier, p->_userIdentifier) &&
           same(_service, p->_service);
}
- (NSUInteger)hash { return _username.hash ^ _service.hash; }
- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p: urlString=%@, username=%@, userIdentifier=%@, service=%@, displayname=(nil), "
                                      @"teamIdentifier=(nil), bundleIdentifiers=(nil)>",
                                      [self class], self, nil_string(_urlString), nil_string(_username),
                                      nil_string(_userIdentifier), nil_string(_service)];
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_urlString forKey:@"_urlString"];
    [coder encodeObject:_username forKey:@"_username"];
    [coder encodeObject:_userIdentifier forKey:@"_userIdentifier"];
    [coder encodeObject:_service forKey:@"_service"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    Class s = [NSString class];
    return [self initWithUrlString:[coder decodeObjectOfClass:s forKey:@"_urlString"]
                          username:[coder decodeObjectOfClass:s forKey:@"_username"]
                    userIdentifier:[coder decodeObjectOfClass:s forKey:@"_userIdentifier"]
                           service:[coder decodeObjectOfClass:s forKey:@"_service"]];
}
@end

@interface CNInstantMessageAddress () {
    NSString *_username, *_service;
}
@end

@implementation CNInstantMessageAddress
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithUsername:(NSString *)username service:(NSString *)service
{
    if ((self = [super init])) {
        _username = [username copy];
        _service = [service copy];
    }
    return self;
}
- (NSString *)username { return _username; }
- (NSString *)service { return _service; }
+ (NSString *)localizedStringForKey:(NSString *)key { return FinchCNLocalizedString(@"imkey", key, nil); }
+ (NSString *)localizedStringForService:(NSString *)service { return FinchCNLocalizedString(@"imservice", service, service); }
- (id)copyWithZone:(NSZone *)zone { return self; }
- (BOOL)isEqual:(id)o
{
    return o == self || ([o isKindOfClass:[CNInstantMessageAddress class]] && same(_username, [o username]) && same(_service, [o service]));
}
- (NSUInteger)hash { return _username.hash ^ _service.hash; }
- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p: username=%@, userIdentifier=(nil), service=%@, teamIdentifier=(nil), "
                                      @"bundleIdentifiers=(nil)>",
                                      [self class], self, nil_string(_username), nil_string(_service)];
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_username forKey:@"_username"];
    [coder encodeObject:_service forKey:@"_service"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    return [self initWithUsername:[coder decodeObjectOfClass:[NSString class] forKey:@"_username"]
                          service:[coder decodeObjectOfClass:[NSString class] forKey:@"_service"]];
}
@end

/* --- groups and containers --- */

@implementation CNGroup
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)_finchInitWithIdentifier:(NSString *)identifier name:(NSString *)name
{
    if ((self = [super init])) {
        _identifier = [identifier copy];
        _name = [name copy] ?: @"";
    }
    return self;
}
- (instancetype)init
{
    return [self _finchInitWithIdentifier:[NSString stringWithFormat:@"%@:ABGroup", [NSUUID UUID].UUIDString] name:@""];
}
- (NSString *)identifier { return _identifier; }
- (NSString *)name { return _name; }
- (id)copyWithZone:(NSZone *)zone { return [[CNGroup alloc] _finchInitWithIdentifier:_identifier name:_name]; }
- (id)mutableCopyWithZone:(NSZone *)zone { return [[CNMutableGroup alloc] _finchInitWithIdentifier:_identifier name:_name]; }
- (BOOL)isEqual:(id)o
{
    return o == self || ([o isKindOfClass:[CNGroup class]] && [_identifier isEqual:((CNGroup *)o)->_identifier] &&
                         [_name isEqual:((CNGroup *)o)->_name]);
}
- (NSUInteger)hash { return _identifier.hash; }
- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p: identifier=%@, name=%@, iOSLegacyIdentifier=-1, creationDate=(nil), "
                                      @"modificationDate=(nil), externalURI=(nil), externalRepresentation=(nil), "
                                      @"externalModificationTag=(nil), externalUUID=(nil)>",
                                      [self class], self, _identifier, _name];
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_identifier forKey:@"_identifier"];
    [coder encodeObject:_name forKey:@"_name"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    return [self _finchInitWithIdentifier:[coder decodeObjectOfClass:[NSString class] forKey:@"_identifier"] ?: @""
                                     name:[coder decodeObjectOfClass:[NSString class] forKey:@"_name"]];
}
@end

@implementation CNMutableGroup
- (void)setName:(NSString *)name { _name = [name copy] ?: @""; }
- (NSString *)name { return _name; }
@end

@implementation CNContainer
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)_finchInitWithIdentifier:(NSString *)identifier name:(NSString *)name type:(CNContainerType)type
{
    if ((self = [super init])) {
        _identifier = [identifier copy];
        _name = [name copy];
        _type = type;
    }
    return self;
}
- (NSString *)identifier { return _identifier; }
- (NSString *)name { return _name; }
- (CNContainerType)type { return _type; }
- (id)copyWithZone:(NSZone *)zone { return self; }
- (BOOL)isEqual:(id)o { return o == self || ([o isKindOfClass:[CNContainer class]] && [_identifier isEqual:((CNContainer *)o)->_identifier]); }
- (NSUInteger)hash { return _identifier.hash; }
- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p: identifier=%@, name=%@, type=%ld>", [self class], self, _identifier, _name, (long)_type];
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_identifier forKey:@"_identifier"];
    [coder encodeObject:_name forKey:@"_name"];
    [coder encodeInteger:_type forKey:@"_type"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    return [self _finchInitWithIdentifier:[coder decodeObjectOfClass:[NSString class] forKey:@"_identifier"] ?: @""
                                     name:[coder decodeObjectOfClass:[NSString class] forKey:@"_name"] ?: @""
                                     type:[coder decodeIntegerForKey:@"_type"]];
}
@end

/* --- CNContactProperty: one value of a contact (what a picker hands back) --- */

@interface CNContactProperty () {
    CNContact *_contact;
    NSString *_key;
    id _value;
    NSString *_identifier;
    NSString *_label;
}
@end

@implementation CNContactProperty
+ (BOOL)supportsSecureCoding { return YES; }
+ (instancetype)contactPropertyWithContact:(CNContact *)contact propertyKey:(NSString *)key identifier:(NSString *)identifier
{
    CNContactProperty *p = [[self alloc] init];
    p->_contact = [contact copy];
    p->_key = [key copy];
    id v = [contact isKeyAvailable:key] ? [contact valueForKey:key] : nil;
    if ([v isKindOfClass:[NSArray class]]) {
        for (CNLabeledValue *l in v)
            if (!identifier || [l.identifier isEqual:identifier]) {
                p->_value = l.value;
                p->_label = l.label;
                p->_identifier = l.identifier;
                break;
            }
    } else {
        p->_value = v;
    }
    return p;
}
- (CNContact *)contact { return _contact; }
- (NSString *)key { return _key; }
- (id)value { return _value; }
- (NSString *)identifier { return _identifier; }
- (NSString *)label { return _label; }
- (id)copyWithZone:(NSZone *)zone { return self; }
- (BOOL)isEqual:(id)o
{
    if (o == self)
        return YES;
    if (![o isKindOfClass:[CNContactProperty class]])
        return NO;
    CNContactProperty *p = o;
    return same(_contact.identifier, p->_contact.identifier) && same(_key, p->_key) && same(_identifier, p->_identifier);
}
- (NSUInteger)hash { return _key.hash ^ _contact.identifier.hash; }
- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p: contact=%@, key=%@, identifier=%@, label=%@, value=%@>", [self class], self,
                                      _contact, _key, nil_string(_identifier), nil_string(_label), nil_string(_value)];
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_contact forKey:@"contact"];
    [coder encodeObject:_key forKey:@"key"];
    [coder encodeObject:_identifier forKey:@"identifier"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    return [CNContactProperty contactPropertyWithContact:[coder decodeObjectOfClass:[CNContact class] forKey:@"contact"]
                                             propertyKey:[coder decodeObjectOfClass:[NSString class] forKey:@"key"]
                                              identifier:[coder decodeObjectOfClass:[NSString class] forKey:@"identifier"]];
}
@end
