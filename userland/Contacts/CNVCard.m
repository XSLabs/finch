/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CNContactVCardSerialization: contacts to and from vCard (RFC 2426, version 3.0), written
 * as Apple's are: the properties in Apple's order, the first value of each kind marked
 * "pref", labels vCard has no type for given in an item group with X-ABLabel, Apple's
 * extensions (X-ABADR, X-ABDATE, X-ABRELATEDNAMES, X-SOCIALPROFILE, X-ABShowAs, ...), and,
 * as with Apple's, no note or picture. Reading takes 2.1, 3.0 and 4.0 cards: folded lines,
 * groups, quoted-printable and base64 values.
 */
#import "Contacts_Finch.h"

static NSString *
label_core(NSString *label)
{
    if ([label hasPrefix:@"_$!<"] && [label hasSuffix:@">!$_"] && label.length > 8)
        return [label substringWithRange:NSMakeRange(4, label.length - 8)];
    return nil;
}

static NSString *
escape(NSString *s)
{
    NSMutableString *o = [NSMutableString string];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        switch (c) {
        case '\\': [o appendString:@"\\\\"]; break;
        case ',': [o appendString:@"\\,"]; break;
        case ';': [o appendString:@"\\;"]; break;
        case '\n': [o appendString:@"\\n"]; break;
        case '\r': break;
        default: [o appendFormat:@"%C", c];
        }
    }
    return o;
}

static NSString *
date_string(NSDateComponents *d, NSString **params)
{
    *params = @"";
    NSInteger y = d.year;
    if (y == NSDateComponentUndefined) {
        *params = @";X-APPLE-OMIT-YEAR=1604";
        y = 1604;
    }
    return [NSString stringWithFormat:@"%04ld-%02ld-%02ld", (long)y, (long)d.month, (long)d.day];
}

/* --- writing --- */

@interface FinchVCardWriter : NSObject {
  @public
    NSMutableString *_out;
    NSInteger _item;
}
@end

@implementation FinchVCardWriter

- (void)line:(NSString *)name params:(NSString *)params value:(NSString *)value
{
    [_out appendFormat:@"%@%@:%@\r\n", name, params ?: @"", value];
}

/* One labeled value: with types vCard knows, or (types nil) in an item group with
   X-ABLabel; e-mail addresses are INTERNET either way. */
- (void)labeled:(NSString *)name types:(NSArray *)types label:(NSString *)label first:(BOOL)first value:(NSString *)value
          extra:(NSArray *)extra internet:(BOOL)internet
{
    NSMutableString *params = [NSMutableString string];
    if (internet)
        [params appendString:@";type=INTERNET"];
    for (NSString *t in types)
        [params appendFormat:@";type=%@", t];
    if (first)
        [params appendString:@";type=pref"];
    BOOL custom = !types && label.length;
    NSString *group = @"";
    if (custom || extra.count)
        group = [NSString stringWithFormat:@"item%ld.", (long)++_item];
    [self line:[group stringByAppendingString:name] params:params value:value];
    for (NSArray *e in extra)
        [self line:[group stringByAppendingString:e[0]] params:nil value:e[1]];
    if (custom)
        [self line:[group stringByAppendingString:@"X-ABLabel"] params:nil value:escape(label)];
}

- (void)labeled:(NSString *)name types:(NSArray *)types label:(NSString *)label first:(BOOL)first value:(NSString *)value
          extra:(NSArray *)extra
{
    [self labeled:name types:types label:label first:first value:value extra:extra internet:NO];
}

@end

static NSArray *
phone_types(NSString *label)
{
    if (!label.length)
        return @[];
    /* (iPhone's and Apple Watch's labels are plain words, the others Contacts' marked ones) */
    if ([label isEqualToString:CNLabelPhoneNumberiPhone])
        return @[ @"IPHONE", @"CELL", @"VOICE" ];
    if ([label isEqualToString:CNLabelPhoneNumberAppleWatch])
        return @[ @"APPLEWATCH", @"CELL", @"VOICE" ];
    static NSDictionary *types;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      types = @{
          @"Mobile" : @[ @"CELL", @"VOICE" ],
          @"Home" : @[ @"HOME", @"VOICE" ],
          @"Work" : @[ @"WORK", @"VOICE" ],
          @"Main" : @[ @"MAIN" ],
          @"HomeFAX" : @[ @"HOME", @"FAX" ],
          @"WorkFAX" : @[ @"WORK", @"FAX" ],
          @"OtherFAX" : @[ @"OTHER", @"FAX" ],
          @"Pager" : @[ @"PAGER" ],
          @"Other" : @[ @"OTHER", @"VOICE" ],
      };
    });
    NSString *core = label_core(label);
    return core ? types[core] : nil;
}

static NSArray *
simple_types(NSString *label, NSArray *known)
{
    if (!label.length)
        return @[];
    NSString *core = label_core(label);
    return core && [known containsObject:core] ? @[ core.uppercaseString ] : nil;
}

static NSString *
im_scheme(NSString *service)
{
    NSDictionary *schemes = @{
        @"AIM" : @"aim", @"ICQ" : @"aim", @"Jabber" : @"xmpp", @"GoogleTalk" : @"xmpp", @"Facebook" : @"xmpp",
        @"MSN" : @"msnim", @"Yahoo" : @"ymsgr", @"Skype" : @"skype",
    };
    return schemes[service] ?: @"x-apple";
}

static void
write_contact(FinchVCardWriter *w, CNContact *c)
{
#define HAS(k) [c isKeyAvailable:k]
#define TEXT(k) (HAS(k) ? (NSString *)[c valueForKey:k] : @"")
    [w line:@"BEGIN" params:nil value:@"VCARD"];
    [w line:@"VERSION" params:nil value:@"3.0"];
    NSString *version = [NSDictionary dictionaryWithContentsOfFile:@"/System/Library/CoreServices/SystemVersion.plist"][@"ProductVersion"];
    [w line:@"PRODID" params:nil value:[NSString stringWithFormat:@"-//Finch//Finch %@//EN", version ?: @"1.0"]];
    [w line:@"N" params:nil value:[NSString stringWithFormat:@"%@;%@;%@;%@;%@", escape(TEXT(CNContactFamilyNameKey)),
                                                             escape(TEXT(CNContactGivenNameKey)), escape(TEXT(CNContactMiddleNameKey)),
                                                             escape(TEXT(CNContactNamePrefixKey)), escape(TEXT(CNContactNameSuffixKey))]];
    NSString *full = [CNContactFormatter stringFromContact:c style:CNContactFormatterStyleFullName];
    if (full.length)
        [w line:@"FN" params:nil value:escape(full)];
    NSArray *simple = @[ @[ @"NICKNAME", CNContactNicknameKey ], @[ @"X-MAIDENNAME", CNContactPreviousFamilyNameKey ],
                         @[ @"X-PHONETIC-FIRST-NAME", CNContactPhoneticGivenNameKey ],
                         @[ @"X-PHONETIC-MIDDLE-NAME", CNContactPhoneticMiddleNameKey ],
                         @[ @"X-PHONETIC-LAST-NAME", CNContactPhoneticFamilyNameKey ] ];
    for (NSArray *s in simple)
        if (TEXT(s[1]).length)
            [w line:s[0] params:nil value:escape(TEXT(s[1]))];
    NSString *org = TEXT(CNContactOrganizationNameKey), *dept = TEXT(CNContactDepartmentNameKey);
    if (org.length || dept.length)
        [w line:@"ORG" params:nil value:dept.length ? [NSString stringWithFormat:@"%@;%@", escape(org), escape(dept)] : escape(org)];
    if (TEXT(CNContactPhoneticOrganizationNameKey).length)
        [w line:@"X-PHONETIC-ORG" params:nil value:escape(TEXT(CNContactPhoneticOrganizationNameKey))];
    if (TEXT(CNContactJobTitleKey).length)
        [w line:@"TITLE" params:nil value:escape(TEXT(CNContactJobTitleKey))];

    BOOL first = YES;
    if (HAS(CNContactEmailAddressesKey))
        for (CNLabeledValue *l in c.emailAddresses) {
            /* (INTERNET always; a label without a type goes in an item group) */
            NSArray *t = simple_types(l.label, @[ @"Home", @"Work" ]);
            [w labeled:@"EMAIL" types:t label:l.label first:first
                 value:escape(l.value) extra:nil internet:YES];
            first = NO;
        }
    first = YES;
    if (HAS(CNContactPhoneNumbersKey))
        for (CNLabeledValue *l in c.phoneNumbers) {
            [w labeled:@"TEL" types:phone_types(l.label) label:l.label first:first value:escape([l.value stringValue]) extra:nil];
            first = NO;
        }
    first = YES;
    if (HAS(CNContactPostalAddressesKey))
        for (CNLabeledValue *l in c.postalAddresses) {
            CNPostalAddress *a = l.value;
            NSString *v = [NSString stringWithFormat:@";;%@;%@;%@;%@;%@", escape(a.street), escape(a.city), escape(a.state),
                                                     escape(a.postalCode), escape(a.country)];
            NSMutableArray *extra = [NSMutableArray array];
            if (a.ISOCountryCode.length)
                [extra addObject:@[ @"X-ABADR", escape(a.ISOCountryCode) ]];
            if (a.subLocality.length)
                [extra addObject:@[ @"X-APPLE-SUBLOCALITY", escape(a.subLocality) ]];
            if (a.subAdministrativeArea.length)
                [extra addObject:@[ @"X-APPLE-SUBADMINISTRATIVEAREA", escape(a.subAdministrativeArea) ]];
            [w labeled:@"ADR" types:simple_types(l.label, @[ @"Home", @"Work", @"Other" ]) label:l.label first:first value:v
                 extra:extra];
            first = NO;
        }
    if (HAS(CNContactSocialProfilesKey))
        for (CNLabeledValue *l in c.socialProfiles) {
            CNSocialProfile *p = l.value;
            NSString *svc = p.service;
            NSString *known = [FinchCNLocalizedString(@"socialservice", svc, nil) length] && svc.length ? svc.lowercaseString : svc;
            NSMutableString *params = [NSMutableString string];
            if (known.length)
                [params appendFormat:@";type=%@", known];
            if (p.urlString.length && p.username.length)
                [params appendFormat:@";x-user=%@", p.username];
            if (p.userIdentifier.length)
                [params appendFormat:@";x-userid=%@", p.userIdentifier];
            NSString *value = p.urlString.length ? p.urlString : [@"x-apple:" stringByAppendingString:p.username ?: @""];
            [w line:@"X-SOCIALPROFILE" params:params value:value];
        }
    first = YES;
    if (HAS(CNContactUrlAddressesKey))
        for (CNLabeledValue *l in c.urlAddresses) {
            [w labeled:@"URL" types:simple_types(l.label, @[ @"Home", @"Work" ]) label:l.label first:first value:escape(l.value)
                 extra:nil];
            first = NO;
        }
    if (HAS(CNContactBirthdayKey) && c.birthday) {
        NSString *params;
        NSString *v = date_string(c.birthday, &params);
        [w line:@"BDAY" params:params value:v];
    }
    if (HAS(CNContactNonGregorianBirthdayKey) && c.nonGregorianBirthday) {
        NSDateComponents *d = c.nonGregorianBirthday;
        NSString *cal = d.calendar.calendarIdentifier ?: @"chinese";
        [w line:@"X-ALTBDAY" params:[@";CALSCALE=" stringByAppendingString:cal]
            value:[NSString stringWithFormat:@"%04ld%04ld%02ld%02ld", (long)(d.era == NSDateComponentUndefined ? 0 : d.era),
                                             (long)d.year, (long)d.month, (long)d.day]];
    }
    if (HAS(CNContactInstantMessageAddressesKey)) {
        NSArray *legacy = @[ @"AIM", @"Jabber", @"MSN", @"Yahoo", @"ICQ" ];
        NSMutableSet *seen = [NSMutableSet set];
        for (CNLabeledValue *l in c.instantMessageAddresses) {
            CNInstantMessageAddress *m = l.value;
            if (![legacy containsObject:m.service])
                continue;
            NSMutableString *params = [NSMutableString string];
            NSArray *t = simple_types(l.label, @[ @"Home", @"Work" ]);
            for (NSString *x in t)
                [params appendFormat:@";type=%@", x];
            if (![seen containsObject:m.service])
                [params appendString:@";type=pref"];
            [seen addObject:m.service];
            [w line:[@"X-" stringByAppendingString:m.service.uppercaseString] params:params value:escape(m.username)];
        }
        first = YES;
        for (CNLabeledValue *l in c.instantMessageAddresses) {
            CNInstantMessageAddress *m = l.value;
            NSMutableArray *types = [NSMutableArray array];
            for (NSString *x in simple_types(l.label, @[ @"Home", @"Work" ]))
                [types addObject:x];
            NSString *svc = [NSString stringWithFormat:@"IMPP;X-SERVICE-TYPE=%@", m.service];
            [w labeled:svc types:types label:l.label first:first
                 value:[NSString stringWithFormat:@"%@:%@", im_scheme(m.service), escape(m.username)] extra:nil];
            first = NO;
        }
    }
    first = YES;
    if (HAS(CNContactDatesKey))
        for (CNLabeledValue *l in c.dates) {
            NSString *params;
            NSString *v = date_string(l.value, &params);
            NSString *group = [NSString stringWithFormat:@"item%ld.", (long)++w->_item];
            [w line:[group stringByAppendingString:@"X-ABDATE"] params:[params stringByAppendingString:first ? @";type=pref" : @""]
                value:v];
            if (l.label.length)
                [w line:[group stringByAppendingString:@"X-ABLabel"] params:nil value:escape(l.label)];
            first = NO;
        }
    first = YES;
    if (HAS(CNContactRelationsKey))
        for (CNLabeledValue *l in c.contactRelations) {
            NSString *group = [NSString stringWithFormat:@"item%ld.", (long)++w->_item];
            [w line:[group stringByAppendingString:@"X-ABRELATEDNAMES"] params:first ? @";type=pref" : @""
                value:escape([l.value name])];
            if (l.label.length)
                [w line:[group stringByAppendingString:@"X-ABLabel"] params:nil value:escape(l.label)];
            first = NO;
        }
    if (HAS(CNContactTypeKey) && c.contactType == CNContactTypeOrganization)
        [w line:@"X-ABShowAs" params:nil value:@"COMPANY"];
    [w line:@"END" params:nil value:@"VCARD"];
#undef HAS
#undef TEXT
}

/* --- reading --- */

static NSString *
unescape(NSString *s)
{
    if ([s rangeOfString:@"\\"].location == NSNotFound)
        return s;
    NSMutableString *o = [NSMutableString string];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == '\\' && i + 1 < s.length) {
            unichar n = [s characterAtIndex:++i];
            [o appendString:n == 'n' || n == 'N' ? @"\n" : [NSString stringWithFormat:@"%C", n]];
        } else {
            [o appendFormat:@"%C", c];
        }
    }
    return o;
}

/* A structured value's components (split at unescaped ';'), each unescaped. */
static NSArray *
components(NSString *s)
{
    NSMutableArray *parts = [NSMutableArray array];
    NSUInteger start = 0;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == '\\')
            i++;
        else if (c == ';') {
            [parts addObject:unescape([s substringWithRange:NSMakeRange(start, i - start)])];
            start = i + 1;
        }
    }
    [parts addObject:unescape([s substringFromIndex:MIN(start, s.length)])];
    return parts;
}

static NSString *
component(NSArray *parts, NSUInteger i)
{
    return i < parts.count ? parts[i] : @"";
}

static NSData *
quoted_printable(NSString *s)
{
    NSMutableData *d = [NSMutableData data];
    const char *p = s.UTF8String;
    for (; *p; p++) {
        if (*p == '=' && p[1] && p[2]) {
            char hex[3] = {p[1], p[2], 0};
            uint8_t b = (uint8_t)strtol(hex, NULL, 16);
            [d appendBytes:&b length:1];
            p += 2;
        } else {
            [d appendBytes:p length:1];
        }
    }
    return d;
}

static NSArray *
param_types(NSDictionary *params)
{
    NSMutableArray *t = [NSMutableArray array];
    for (NSString *v in params[@"TYPE"])
        [t addObjectsFromArray:[v.uppercaseString componentsSeparatedByString:@","]];
    for (NSString *v in params[@""])
        [t addObject:v.uppercaseString]; /* 2.1: bare parameters are types */
    return t;
}

static NSString *
phone_label(NSArray *t)
{
    BOOL fax = [t containsObject:@"FAX"];
    if ([t containsObject:@"IPHONE"])
        return CNLabelPhoneNumberiPhone;
    if ([t containsObject:@"APPLEWATCH"])
        return CNLabelPhoneNumberAppleWatch;
    if (fax)
        return [t containsObject:@"HOME"] ? CNLabelPhoneNumberHomeFax
               : [t containsObject:@"WORK"] ? CNLabelPhoneNumberWorkFax
                                            : CNLabelPhoneNumberOtherFax;
    if ([t containsObject:@"CELL"])
        return CNLabelPhoneNumberMobile;
    if ([t containsObject:@"MAIN"])
        return CNLabelPhoneNumberMain;
    if ([t containsObject:@"PAGER"])
        return CNLabelPhoneNumberPager;
    if ([t containsObject:@"HOME"])
        return CNLabelHome;
    if ([t containsObject:@"WORK"])
        return CNLabelWork;
    if ([t containsObject:@"OTHER"])
        return CNLabelOther;
    return @"";
}

static NSString *
place_label(NSArray *t)
{
    if ([t containsObject:@"HOME"])
        return CNLabelHome;
    if ([t containsObject:@"WORK"])
        return CNLabelWork;
    if ([t containsObject:@"OTHER"])
        return CNLabelOther;
    return @"";
}

static NSDateComponents *
parse_date(NSString *v, NSDictionary *params)
{
    NSString *digits = [[v componentsSeparatedByCharactersInSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]]
        componentsJoinedByString:@""];
    NSDateComponents *d = [[NSDateComponents alloc] init];
    if ([v hasPrefix:@"--"] && digits.length >= 4) { /* 4.0: --MMDD */
        d.month = [[digits substringWithRange:NSMakeRange(0, 2)] integerValue];
        d.day = [[digits substringWithRange:NSMakeRange(2, 2)] integerValue];
        return d;
    }
    if (digits.length < 8)
        return nil;
    d.year = [[digits substringToIndex:4] integerValue];
    d.month = [[digits substringWithRange:NSMakeRange(4, 2)] integerValue];
    d.day = [[digits substringWithRange:NSMakeRange(6, 2)] integerValue];
    if (params[@"X-APPLE-OMIT-YEAR"])
        d.year = NSDateComponentUndefined;
    return d;
}

static CNContact *
read_card(NSArray *store)
{
    CNMutableContact *c = [[CNMutableContact alloc] init];
    NSMutableDictionary *labels = [NSMutableDictionary dictionary]; /* group -> X-ABLabel */
    NSMutableDictionary *groupExtras = [NSMutableDictionary dictionary]; /* group -> {name: value} */
    for (NSDictionary *l in store) {
        NSString *g = l[@"group"];
        if (!g.length)
            continue;
        NSString *n = l[@"name"];
        if ([n isEqualToString:@"X-ABLABEL"])
            labels[g] = unescape(l[@"value"]);
        else {
            NSMutableDictionary *e = groupExtras[g] ?: (groupExtras[g] = [NSMutableDictionary dictionary]);
            e[n] = unescape(l[@"value"]);
        }
    }
    NSMutableArray *phones = [NSMutableArray array], *emails = [NSMutableArray array], *addresses = [NSMutableArray array],
                   *urls = [NSMutableArray array], *relations = [NSMutableArray array], *socials = [NSMutableArray array],
                   *ims = [NSMutableArray array], *legacyIMs = [NSMutableArray array], *dates = [NSMutableArray array];
    for (NSDictionary *l in store) {
        NSString *name = l[@"name"], *value = l[@"value"], *group = l[@"group"];
        NSDictionary *params = l[@"params"];
        NSArray *types = param_types(params);
        NSString *custom = group.length ? labels[group] : nil;
        if ([name isEqualToString:@"N"]) {
            NSArray *p = components(value);
            c.familyName = component(p, 0);
            c.givenName = component(p, 1);
            c.middleName = component(p, 2);
            c.namePrefix = component(p, 3);
            c.nameSuffix = component(p, 4);
        } else if ([name isEqualToString:@"NICKNAME"]) {
            c.nickname = unescape(value);
        } else if ([name isEqualToString:@"X-MAIDENNAME"]) {
            c.previousFamilyName = unescape(value);
        } else if ([name isEqualToString:@"X-PHONETIC-FIRST-NAME"]) {
            c.phoneticGivenName = unescape(value);
        } else if ([name isEqualToString:@"X-PHONETIC-MIDDLE-NAME"]) {
            c.phoneticMiddleName = unescape(value);
        } else if ([name isEqualToString:@"X-PHONETIC-LAST-NAME"]) {
            c.phoneticFamilyName = unescape(value);
        } else if ([name isEqualToString:@"X-PHONETIC-ORG"]) {
            c.phoneticOrganizationName = unescape(value);
        } else if ([name isEqualToString:@"ORG"]) {
            NSArray *p = components(value);
            c.organizationName = component(p, 0);
            c.departmentName = component(p, 1);
        } else if ([name isEqualToString:@"TITLE"]) {
            c.jobTitle = unescape(value);
        } else if ([name isEqualToString:@"NOTE"]) {
            c.note = unescape(value);
        } else if ([name isEqualToString:@"TEL"]) {
            NSString *label = custom ?: phone_label(types);
            [phones addObject:[CNLabeledValue labeledValueWithLabel:label
                                                               value:[CNPhoneNumber phoneNumberWithStringValue:unescape(value)]]];
        } else if ([name isEqualToString:@"EMAIL"]) {
            [emails addObject:[CNLabeledValue labeledValueWithLabel:custom ?: place_label(types) value:unescape(value)]];
        } else if ([name isEqualToString:@"ADR"]) {
            NSArray *p = components(value);
            CNMutablePostalAddress *a = [[CNMutablePostalAddress alloc] init];
            NSMutableArray *street = [NSMutableArray array];
            for (NSUInteger i = 0; i < 3; i++)
                if (component(p, i).length)
                    [street addObject:component(p, i)];
            a.street = [street componentsJoinedByString:@"\n"];
            a.city = component(p, 3);
            a.state = component(p, 4);
            a.postalCode = component(p, 5);
            a.country = component(p, 6);
            NSDictionary *extra = group.length ? groupExtras[group] : nil;
            if (extra[@"X-ABADR"])
                a.ISOCountryCode = extra[@"X-ABADR"];
            if (extra[@"X-APPLE-SUBLOCALITY"])
                a.subLocality = extra[@"X-APPLE-SUBLOCALITY"];
            if (extra[@"X-APPLE-SUBADMINISTRATIVEAREA"])
                a.subAdministrativeArea = extra[@"X-APPLE-SUBADMINISTRATIVEAREA"];
            [addresses addObject:[CNLabeledValue labeledValueWithLabel:custom ?: place_label(types) value:a]];
        } else if ([name isEqualToString:@"URL"]) {
            [urls addObject:[CNLabeledValue labeledValueWithLabel:custom ?: place_label(types) value:unescape(value)]];
        } else if ([name isEqualToString:@"BDAY"]) {
            c.birthday = parse_date(value, params);
        } else if ([name isEqualToString:@"X-ALTBDAY"]) {
            NSString *cal = [params[@"CALSCALE"] firstObject] ?: @"chinese";
            if (value.length >= 12) {
                NSDateComponents *d = [[NSDateComponents alloc] init];
                d.calendar = [NSCalendar calendarWithIdentifier:cal];
                d.era = [[value substringToIndex:4] integerValue];
                d.year = [[value substringWithRange:NSMakeRange(4, 4)] integerValue];
                d.month = [[value substringWithRange:NSMakeRange(8, 2)] integerValue];
                d.day = [[value substringWithRange:NSMakeRange(10, 2)] integerValue];
                c.nonGregorianBirthday = d;
            }
        } else if ([name isEqualToString:@"X-ABDATE"] || [name isEqualToString:@"ANNIVERSARY"]) {
            NSDateComponents *d = parse_date(value, params);
            if (d)
                [dates addObject:[CNLabeledValue labeledValueWithLabel:custom ?: ([name isEqualToString:@"ANNIVERSARY"]
                                                                                       ? CNLabelDateAnniversary
                                                                                       : @"")
                                                                  value:d]];
        } else if ([name isEqualToString:@"X-ABRELATEDNAMES"]) {
            [relations addObject:[CNLabeledValue labeledValueWithLabel:custom ?: @""
                                                                  value:[CNContactRelation contactRelationWithName:unescape(value)]]];
        } else if ([name isEqualToString:@"X-SOCIALPROFILE"]) {
            /* the service as the card gives it, or, for a profile's address, the service whose
               site it is (as Apple's reads them) */
            NSString *service = [params[@"TYPE"] firstObject];
            NSString *user = [params[@"X-USER"] firstObject], *url = nil;
            if ([value hasPrefix:@"x-apple:"])
                user = [value substringFromIndex:8];
            else {
                url = value;
                NSString *host = [NSURL URLWithString:value].host.lowercaseString;
                if ([host hasPrefix:@"www."])
                    host = [host substringFromIndex:4];
                NSDictionary *sites = @{
                    @"twitter.com" : CNSocialProfileServiceTwitter, @"x.com" : CNSocialProfileServiceTwitter,
                    @"facebook.com" : CNSocialProfileServiceFacebook, @"flickr.com" : CNSocialProfileServiceFlickr,
                    @"linkedin.com" : CNSocialProfileServiceLinkedIn, @"myspace.com" : CNSocialProfileServiceMySpace,
                    @"weibo.com" : CNSocialProfileServiceSinaWeibo, @"t.qq.com" : CNSocialProfileServiceTencentWeibo,
                    @"yelp.com" : CNSocialProfileServiceYelp,
                };
                if (host && sites[host])
                    service = sites[host];
            }
            [socials addObject:[CNLabeledValue labeledValueWithLabel:custom ?: @""
                                                               value:[[CNSocialProfile alloc] initWithUrlString:url username:user
                                                                                                userIdentifier:[params[@"X-USERID"] firstObject]
                                                                                                       service:service]]];
        } else if ([name isEqualToString:@"IMPP"]) {
            NSString *service = [params[@"X-SERVICE-TYPE"] firstObject];
            NSRange colon = [value rangeOfString:@":"];
            NSString *user = colon.location != NSNotFound ? [value substringFromIndex:NSMaxRange(colon)] : value;
            [ims addObject:[CNLabeledValue labeledValueWithLabel:custom ?: place_label(types)
                                                           value:[[CNInstantMessageAddress alloc] initWithUsername:unescape(user)
                                                                                                           service:service ?: @""]]];
        } else if ([name hasPrefix:@"X-"] &&
                   [@[ @"X-AIM", @"X-JABBER", @"X-MSN", @"X-YAHOO", @"X-ICQ" ] containsObject:name]) {
            NSString *service = @{@"X-AIM" : @"AIM", @"X-JABBER" : @"Jabber", @"X-MSN" : @"MSN", @"X-YAHOO" : @"Yahoo", @"X-ICQ" : @"ICQ"}[name];
            [legacyIMs addObject:[CNLabeledValue labeledValueWithLabel:custom ?: place_label(types)
                                                                 value:[[CNInstantMessageAddress alloc] initWithUsername:unescape(value)
                                                                                                                 service:service]]];
        } else if ([name isEqualToString:@"PHOTO"]) {
            NSString *enc = [[params[@"ENCODING"] firstObject] uppercaseString];
            NSData *d = nil;
            if ([enc isEqualToString:@"B"] || [enc isEqualToString:@"BASE64"])
                d = [[NSData alloc] initWithBase64EncodedString:value options:NSDataBase64DecodingIgnoreUnknownCharacters];
            else if ([value hasPrefix:@"data:"]) {
                NSRange comma = [value rangeOfString:@","];
                if (comma.location != NSNotFound)
                    d = [[NSData alloc] initWithBase64EncodedString:[value substringFromIndex:comma.location + 1]
                                                            options:NSDataBase64DecodingIgnoreUnknownCharacters];
            }
            if (d.length)
                c.imageData = d;
        } else if ([name isEqualToString:@"X-ABSHOWAS"]) {
            if ([value.uppercaseString isEqualToString:@"COMPANY"])
                c.contactType = CNContactTypeOrganization;
        }
    }
    c.phoneNumbers = phones;
    c.emailAddresses = emails;
    c.postalAddresses = addresses;
    c.urlAddresses = urls;
    c.contactRelations = relations;
    c.socialProfiles = socials;
    c.instantMessageAddresses = ims.count ? ims : legacyIMs;
    c.dates = dates;
    return [c copy];
}

/* The card's lines, unfolded, as {group, name, params, value} (2.1 quoted-printable decoded). */
static NSArray *
parse_lines(NSString *text)
{
    NSMutableArray *raw = [NSMutableArray array];
    [text enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
      if ((line.length && ([line characterAtIndex:0] == ' ' || [line characterAtIndex:0] == '\t')) && raw.count)
          raw[raw.count - 1] = [raw.lastObject stringByAppendingString:[line substringFromIndex:1]];
      else if (raw.count && [raw.lastObject hasSuffix:@"="] && [[raw.lastObject uppercaseString] containsString:@"QUOTED-PRINTABLE"])
          raw[raw.count - 1] = [[raw.lastObject substringToIndex:[raw.lastObject length] - 1] stringByAppendingString:line];
      else
          [raw addObject:line];
    }];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *line in raw) {
        /* the name and parameters end at the first ':' outside quotes */
        NSUInteger colon = NSNotFound;
        BOOL quoted = NO;
        for (NSUInteger i = 0; i < line.length; i++) {
            unichar ch = [line characterAtIndex:i];
            if (ch == '"')
                quoted = !quoted;
            else if (ch == ':' && !quoted) {
                colon = i;
                break;
            }
        }
        if (colon == NSNotFound)
            continue;
        NSString *head = [line substringToIndex:colon], *value = [line substringFromIndex:colon + 1];
        NSArray *pieces = [head componentsSeparatedByString:@";"];
        NSString *name = pieces[0], *group = @"";
        NSRange dot = [name rangeOfString:@"."];
        if (dot.location != NSNotFound) {
            group = [name substringToIndex:dot.location];
            name = [name substringFromIndex:NSMaxRange(dot)];
        }
        NSMutableDictionary *params = [NSMutableDictionary dictionary];
        for (NSUInteger i = 1; i < pieces.count; i++) {
            NSString *p = pieces[i];
            NSRange eq = [p rangeOfString:@"="];
            NSString *k = eq.location == NSNotFound ? @"" : [p substringToIndex:eq.location].uppercaseString;
            NSString *v = eq.location == NSNotFound ? p : [p substringFromIndex:NSMaxRange(eq)];
            v = [v stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
            NSMutableArray *list = params[k] ?: (params[k] = [NSMutableArray array]);
            [list addObject:v];
        }
        if ([[params[@"ENCODING"] firstObject] caseInsensitiveCompare:@"QUOTED-PRINTABLE"] == NSOrderedSame ||
            [params[@""] containsObject:@"QUOTED-PRINTABLE"]) {
            NSString *decoded = [[NSString alloc] initWithData:quoted_printable(value) encoding:NSUTF8StringEncoding];
            value = decoded ?: value;
        }
        [out addObject:@{@"group" : group.uppercaseString, @"name" : name.uppercaseString, @"params" : params, @"value" : value}];
    }
    return out;
}

static BOOL
is_empty(CNContact *c)
{
    for (id v in c->_values.allValues) {
        if ([v isKindOfClass:[NSArray class]]) {
            if ([v count])
                return NO;
        } else if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSData class]]) {
            if ([v length])
                return NO;
        } else if (![v isKindOfClass:[NSNumber class]] || [v integerValue]) {
            return NO;
        }
    }
    return YES;
}

@implementation CNContactVCardSerialization

+ (id<CNKeyDescriptor>)descriptorForRequiredKeys
{
    NSMutableArray *keys = [NSMutableArray arrayWithArray:FinchCNAllKeys()];
    [keys removeObject:CNContactNoteKey];
    return [[CNAggregateKeyDescriptor alloc] initWithKeyDescriptors:keys
                                                        description:@"+[CNContactVCardSerialization descriptorForRequiredKeys]"];
}

+ (NSData *)dataWithContacts:(NSArray<CNContact *> *)contacts error:(NSError **)error
{
    FinchVCardWriter *w = [[FinchVCardWriter alloc] init];
    w->_out = [NSMutableString string];
    for (CNContact *c in contacts) {
        w->_item = 0;
        write_contact(w, c);
    }
    return [w->_out dataUsingEncoding:NSUTF8StringEncoding];
}

+ (NSArray<CNContact *> *)contactsWithData:(NSData *)data error:(NSError **)error
{
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text)
        text = [[NSString alloc] initWithData:data encoding:NSUTF16StringEncoding];
    if (!text)
        text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    NSMutableArray *contacts = [NSMutableArray array];
    NSMutableArray *card = nil;
    for (NSDictionary *l in parse_lines(text ?: @"")) {
        if ([l[@"name"] isEqualToString:@"BEGIN"] && [[l[@"value"] uppercaseString] isEqualToString:@"VCARD"])
            card = [NSMutableArray array];
        else if ([l[@"name"] isEqualToString:@"END"] && card) {
            /* (a card with nothing on it gives no contact, as with Apple's) */
            CNContact *c = read_card(card);
            if (!is_empty(c))
                [contacts addObject:c];
            card = nil;
        } else
            [card addObject:l];
    }
    return contacts;
}

@end
