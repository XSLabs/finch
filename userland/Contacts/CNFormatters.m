/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CNContactFormatter and CNPostalAddressFormatter, and the names Contacts shows for its
 * labels and keys. A full name is the name's parts in the order the name is written:
 * given name first, or, for a name in Chinese, Japanese or Korean script, family name
 * first with nothing between; without a name it's the nickname, then the company. An
 * organization's name is its company. A postal address is laid out as its country writes
 * one (US style by default).
 */
#import "Contacts_Finch.h"
#include "CNStrings.inc"

#define COUNT(a) (sizeof(a) / sizeof((a)[0]))

NSString *
FinchCNLocalizedString(NSString *table, NSString *key, NSString *fallback)
{
    static NSDictionary *tables;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      NSMutableDictionary *t = [NSMutableDictionary dictionary];
#define TABLE(name)                                                                              \
    do {                                                                                         \
        NSMutableDictionary *d = [NSMutableDictionary dictionary];                               \
        for (size_t i = 0; i < COUNT(strings_##name); i++)                                       \
            d[@(strings_##name[i][0])] = @(strings_##name[i][1]);                                \
        t[@ #name] = d;                                                                          \
    } while (0)
      TABLE(label);
      TABLE(contact);
      TABLE(postal);
      TABLE(socialkey);
      TABLE(socialservice);
      TABLE(imkey);
      TABLE(imservice);
      tables = t;
    });
    if (!key)
        return fallback;
    return tables[table][key] ?: fallback;
}

NSError *
FinchCNError(CNErrorCode code, NSString *description)
{
    return [NSError errorWithDomain:CNErrorDomain code:code
                           userInfo:description ? @{NSLocalizedDescriptionKey : description} : nil];
}

/* --- names --- */

static BOOL
is_cjk(NSString *s)
{
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if ((c >= 0x1100 && c <= 0x11FF) || (c >= 0x2E80 && c <= 0x9FFF) || (c >= 0xAC00 && c <= 0xD7AF) ||
            (c >= 0xF900 && c <= 0xFAFF) || (c >= 0xFF00 && c <= 0xFFEF))
            return YES;
    }
    return NO;
}

static NSString *
part(CNContact *c, NSString *key)
{
    return [c isKeyAvailable:key] ? [c valueForKey:key] : @"";
}

static BOOL
family_first(CNContact *c)
{
    return is_cjk(part(c, CNContactGivenNameKey)) || is_cjk(part(c, CNContactFamilyNameKey)) ||
           is_cjk(part(c, CNContactMiddleNameKey));
}

/* The name's parts as (key, text) pairs, in order, and what goes between them. */
static NSArray *
name_parts(CNContact *c, CNContactFormatterStyle style, NSString **delimiter)
{
    BOOL ff = family_first(c);
    *delimiter = ff ? @"" : @" ";
    NSArray *keys;
    if (style == CNContactFormatterStylePhoneticFullName)
        keys = ff ? @[ CNContactPhoneticFamilyNameKey, CNContactPhoneticMiddleNameKey, CNContactPhoneticGivenNameKey ]
                  : @[ CNContactPhoneticGivenNameKey, CNContactPhoneticMiddleNameKey, CNContactPhoneticFamilyNameKey ];
    else
        keys = ff ? @[ CNContactNamePrefixKey, CNContactFamilyNameKey, CNContactMiddleNameKey, CNContactGivenNameKey, CNContactNameSuffixKey ]
                  : @[ CNContactNamePrefixKey, CNContactGivenNameKey, CNContactMiddleNameKey, CNContactFamilyNameKey, CNContactNameSuffixKey ];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *k in keys) {
        NSString *v = [part(c, k) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (v.length)
            [parts addObject:@[ k, v ]];
    }
    if (style == CNContactFormatterStylePhoneticFullName)
        return parts;
    BOOL organization = [c isKeyAvailable:CNContactTypeKey] && c.contactType == CNContactTypeOrganization;
    NSString *org = part(c, CNContactOrganizationNameKey);
    if (organization && org.length)
        return @[ @[ CNContactOrganizationNameKey, org ] ];
    if (!parts.count) {
        NSString *nick = part(c, CNContactNicknameKey);
        if (nick.length)
            return @[ @[ CNContactNicknameKey, nick ] ];
        if (org.length)
            return @[ @[ CNContactOrganizationNameKey, org ] ];
    }
    return parts;
}

@implementation CNContactFormatter {
    CNContactFormatterStyle _style;
}

+ (BOOL)supportsSecureCoding { return YES; }

+ (id<CNKeyDescriptor>)descriptorForRequiredKeysForStyle:(CNContactFormatterStyle)style
{
    NSArray *keys = style == CNContactFormatterStylePhoneticFullName
                        ? @[ CNContactPhoneticGivenNameKey, CNContactPhoneticMiddleNameKey, CNContactPhoneticFamilyNameKey,
                             CNContactGivenNameKey, CNContactFamilyNameKey, CNContactMiddleNameKey ]
                        : @[ CNContactNamePrefixKey, CNContactGivenNameKey, CNContactMiddleNameKey, CNContactFamilyNameKey,
                             CNContactNameSuffixKey, CNContactNicknameKey, CNContactOrganizationNameKey, CNContactTypeKey ];
    return [[CNAggregateKeyDescriptor alloc] initWithKeyDescriptors:keys
                                                        description:[NSString stringWithFormat:@"Formatter style: %ld", (long)style]];
}

+ (id<CNKeyDescriptor>)descriptorForRequiredKeysForNameOrder
{
    return [[CNAggregateKeyDescriptor alloc]
        initWithKeyDescriptors:@[ CNContactGivenNameKey, CNContactMiddleNameKey, CNContactFamilyNameKey ]
                   description:@"Name order"];
}

+ (id<CNKeyDescriptor>)descriptorForRequiredKeysForDelimiter
{
    return [[CNAggregateKeyDescriptor alloc]
        initWithKeyDescriptors:@[ CNContactNamePrefixKey, CNContactGivenNameKey, CNContactMiddleNameKey, CNContactFamilyNameKey,
                                  CNContactNameSuffixKey ]
                   description:@"Person name components"];
}

+ (NSString *)stringFromContact:(CNContact *)contact style:(CNContactFormatterStyle)style
{
    NSString *delimiter;
    NSArray *parts = name_parts(contact, style, &delimiter);
    if (!parts.count)
        return nil;
    NSMutableArray *texts = [NSMutableArray array];
    for (NSArray *p in parts)
        [texts addObject:p[1]];
    return [texts componentsJoinedByString:delimiter];
}

+ (NSAttributedString *)attributedStringFromContact:(CNContact *)contact style:(CNContactFormatterStyle)style
                                  defaultAttributes:(NSDictionary *)attributes
{
    NSString *delimiter;
    NSArray *parts = name_parts(contact, style, &delimiter);
    if (!parts.count)
        return nil;
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc] init];
    for (NSArray *p in parts) {
        if (s.length && delimiter.length)
            [s appendAttributedString:[[NSAttributedString alloc] initWithString:delimiter attributes:attributes]];
        NSMutableDictionary *a = [NSMutableDictionary dictionaryWithDictionary:attributes ?: @{}];
        a[CNContactPropertyAttribute] = p[0];
        [s appendAttributedString:[[NSAttributedString alloc] initWithString:p[1] attributes:a]];
    }
    return s;
}

+ (CNContactDisplayNameOrder)nameOrderForContact:(CNContact *)contact
{
    return family_first(contact) ? CNContactDisplayNameOrderFamilyNameFirst : CNContactDisplayNameOrderGivenNameFirst;
}

+ (NSString *)delimiterForContact:(CNContact *)contact
{
    return family_first(contact) ? @"" : @" ";
}

- (CNContactFormatterStyle)style { return _style; }
- (void)setStyle:(CNContactFormatterStyle)style { _style = style; }

- (NSString *)stringFromContact:(CNContact *)contact { return [CNContactFormatter stringFromContact:contact style:_style]; }

- (NSAttributedString *)attributedStringFromContact:(CNContact *)contact defaultAttributes:(NSDictionary *)attributes
{
    return [CNContactFormatter attributedStringFromContact:contact style:_style defaultAttributes:attributes];
}

- (NSString *)stringForObjectValue:(id)obj
{
    return [obj isKindOfClass:[CNContact class]] ? [self stringFromContact:obj] : nil;
}

- (NSAttributedString *)attributedStringForObjectValue:(id)obj withDefaultAttributes:(NSDictionary *)attrs
{
    return [obj isKindOfClass:[CNContact class]] ? [self attributedStringFromContact:obj defaultAttributes:attrs] : nil;
}

- (BOOL)getObjectValue:(out id *)obj forString:(NSString *)string errorDescription:(out NSString **)error
{
    return NO;
}

- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeInteger:_style forKey:@"style"]; }
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init]))
        _style = [coder decodeIntegerForKey:@"style"];
    return self;
}

@end

/* --- postal addresses --- */

/* Each line of an address, as the parts on it: by country. */
static NSArray *
layout_for(NSString *country)
{
    NSString *street = CNPostalAddressStreetKey, *city = CNPostalAddressCityKey, *state = CNPostalAddressStateKey,
             *postal = CNPostalAddressPostalCodeKey, *sub = CNPostalAddressSubLocalityKey, *nation = CNPostalAddressCountryKey;
    static NSSet *postalFirst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      postalFirst = [NSSet setWithArray:@[ @"de", @"fr", @"at", @"ch", @"nl", @"be", @"es", @"it", @"se", @"no", @"dk", @"fi", @"pt",
                                           @"pl", @"cz", @"sk", @"hu", @"lu", @"is", @"gr", @"tr", @"il", @"ar", @"mx", @"br" ]];
    });
    if ([country isEqualToString:@"gb"] || [country isEqualToString:@"ie"])
        return @[ @[ street ], @[ city ], @[ postal ], @[ nation ] ];
    if ([country isEqualToString:@"jp"])
        return @[ @[ postal ], @[ state, city ], @[ street ], @[ nation ] ];
    if ([country isEqualToString:@"cn"] || [country isEqualToString:@"tw"] || [country isEqualToString:@"kr"])
        return @[ @[ nation ], @[ state, city ], @[ sub, street ], @[ postal ] ];
    if ([postalFirst containsObject:country])
        return @[ @[ street ], @[ postal, city ], @[ nation ] ];
    return @[ @[ street ], @[ city, state, postal ], @[ nation ] ];
}

static NSAttributedString *
format_address(CNPostalAddress *a, NSDictionary *attributes)
{
    NSString *country = a.ISOCountryCode.lowercaseString;
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] init];
    for (NSArray *line in layout_for(country)) {
        NSMutableAttributedString *l = [[NSMutableAttributedString alloc] init];
        for (NSString *k in line) {
            NSString *v = [a valueForKey:k];
            if (!v.length)
                continue;
            if (l.length)
                [l appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:attributes]];
            NSMutableDictionary *at = [NSMutableDictionary dictionaryWithDictionary:attributes ?: @{}];
            at[CNPostalAddressPropertyAttribute] = k;
            at[CNPostalAddressLocalizedPropertyNameAttribute] = [CNPostalAddress localizedStringForKey:k] ?: k;
            [l appendAttributedString:[[NSAttributedString alloc] initWithString:v attributes:at]];
        }
        if (!l.length)
            continue;
        if (out.length)
            [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:attributes]];
        [out appendAttributedString:l];
    }
    return out;
}

@implementation CNPostalAddressFormatter {
    CNPostalAddressFormatterStyle _style;
}

+ (NSString *)stringFromPostalAddress:(CNPostalAddress *)postalAddress style:(CNPostalAddressFormatterStyle)style
{
    return format_address(postalAddress, nil).string;
}

+ (NSAttributedString *)attributedStringFromPostalAddress:(CNPostalAddress *)postalAddress style:(CNPostalAddressFormatterStyle)style
                                    withDefaultAttributes:(NSDictionary *)attributes
{
    return format_address(postalAddress, attributes);
}

- (CNPostalAddressFormatterStyle)style { return _style; }
- (void)setStyle:(CNPostalAddressFormatterStyle)style { _style = style; }
- (NSString *)stringFromPostalAddress:(CNPostalAddress *)postalAddress { return format_address(postalAddress, nil).string; }
- (NSAttributedString *)attributedStringFromPostalAddress:(CNPostalAddress *)postalAddress withDefaultAttributes:(NSDictionary *)attributes
{
    return format_address(postalAddress, attributes);
}
- (NSString *)stringForObjectValue:(id)obj
{
    return [obj isKindOfClass:[CNPostalAddress class]] ? [self stringFromPostalAddress:obj] : nil;
}
- (BOOL)getObjectValue:(out id *)obj forString:(NSString *)string errorDescription:(out NSString **)error { return NO; }

@end
