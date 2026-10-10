/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-contacts-test: the Contacts model, its formatters and vCard, run against Apple's
 * Contacts and Finch's to compare (tools/host-tests.sh): contacts and their values,
 * fetched-key checks, names and postal addresses as each country writes them, labels
 * and keys by name, vCard out and back in. With "store" it uses the contacts store
 * instead, in a fresh home (Finch-only: Apple's asks the user for access; compare with
 * contacts-store-test.expected).
 *
 *   finch-contacts-test [store]
 */
#import <Contacts/Contacts.h>
#include <stdlib.h>
#include <unistd.h>

static void
out(NSString *format, ...)
{
    va_list ap;
    va_start(ap, format);
    NSString *s = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    /* (addresses and identifiers differ from run to run) */
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"0x[0-9a-f]+|[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"
                                                                        options:0 error:NULL];
    s = [re stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@"#"];
    printf("%s\n", s.UTF8String);
}

static NSString *
labels(NSArray<CNLabeledValue *> *values)
{
    NSMutableArray *a = [NSMutableArray array];
    for (CNLabeledValue *l in values) {
        id v = l.value;
        if ([v isKindOfClass:[CNPhoneNumber class]])
            v = [v stringValue];
        else if ([v isKindOfClass:[CNPostalAddress class]])
            v = [[CNPostalAddressFormatter stringFromPostalAddress:v style:0] stringByReplacingOccurrencesOfString:@"\n" withString:@" / "];
        else if ([v isKindOfClass:[CNContactRelation class]])
            v = [v name];
        else if ([v isKindOfClass:[CNSocialProfile class]])
            v = [NSString stringWithFormat:@"%@@%@ url %@ id %@", [v username], [v service], [v urlString], [v userIdentifier]];
        else if ([v isKindOfClass:[CNInstantMessageAddress class]])
            v = [NSString stringWithFormat:@"%@@%@", [v username], [v service]];
        else if ([v isKindOfClass:[NSDateComponents class]])
            v = [NSString stringWithFormat:@"%ld-%ld-%ld", (long)[v year], (long)[v month], (long)[v day]];
        [a addObject:[NSString stringWithFormat:@"%@=%@", l.label ?: @"(nil)", v]];
    }
    return [a componentsJoinedByString:@", "];
}

static void
dump(NSString *title, CNContact *c)
{
    out(@"%@: %@ type %ld given '%@' middle '%@' family '%@' prefix '%@' suffix '%@' nick '%@' org '%@' dept '%@' title '%@'", title,
        [c class], (long)c.contactType, c.givenName, c.middleName, c.familyName, c.namePrefix, c.nameSuffix, c.nickname,
        c.organizationName, c.departmentName, c.jobTitle);
    out(@"  phonetic '%@' '%@' '%@' '%@' maiden '%@' note '%@' image %lu",
        c.phoneticGivenName, c.phoneticMiddleName, c.phoneticFamilyName, c.phoneticOrganizationName, c.previousFamilyName, c.note,
        (unsigned long)c.imageData.length);
    out(@"  phones %@", labels(c.phoneNumbers));
    out(@"  emails %@", labels(c.emailAddresses));
    out(@"  addresses %@", labels(c.postalAddresses));
    out(@"  urls %@", labels(c.urlAddresses));
    out(@"  relations %@", labels(c.contactRelations));
    out(@"  social %@", labels(c.socialProfiles));
    out(@"  im %@", labels(c.instantMessageAddresses));
    out(@"  dates %@", labels(c.dates));
    out(@"  birthday %ld-%ld-%ld", (long)c.birthday.year, (long)c.birthday.month, (long)c.birthday.day);
}

static CNMutableContact *
sample(void)
{
    CNMutableContact *c = [CNMutableContact new];
    c.givenName = @"John";
    c.familyName = @"Appleseed";
    c.middleName = @"Q";
    c.namePrefix = @"Dr.";
    c.nameSuffix = @"Jr.";
    c.nickname = @"Johnny";
    c.organizationName = @"Apple; Inc, \\ co";
    c.jobTitle = @"Engineer";
    c.departmentName = @"HW";
    c.previousFamilyName = @"Old";
    c.phoneticGivenName = @"Jon";
    c.phoneticFamilyName = @"Apulsid";
    c.phoneNumbers = @[
        [CNLabeledValue labeledValueWithLabel:CNLabelPhoneNumberMobile value:[CNPhoneNumber phoneNumberWithStringValue:@"(408) 555-0123"]],
        [CNLabeledValue labeledValueWithLabel:CNLabelPhoneNumberiPhone value:[CNPhoneNumber phoneNumberWithStringValue:@"1"]],
        [CNLabeledValue labeledValueWithLabel:CNLabelHome value:[CNPhoneNumber phoneNumberWithStringValue:@"2"]],
        [CNLabeledValue labeledValueWithLabel:CNLabelPhoneNumberWorkFax value:[CNPhoneNumber phoneNumberWithStringValue:@"3"]],
        [CNLabeledValue labeledValueWithLabel:CNLabelPhoneNumberPager value:[CNPhoneNumber phoneNumberWithStringValue:@"4"]],
        [CNLabeledValue labeledValueWithLabel:CNLabelOther value:[CNPhoneNumber phoneNumberWithStringValue:@"5"]],
        [CNLabeledValue labeledValueWithLabel:@"boat" value:[CNPhoneNumber phoneNumberWithStringValue:@"6"]],
        [CNLabeledValue labeledValueWithLabel:nil value:[CNPhoneNumber phoneNumberWithStringValue:@"7"]],
    ];
    c.emailAddresses = @[
        [CNLabeledValue labeledValueWithLabel:CNLabelWork value:@"john@example.com"],
        [CNLabeledValue labeledValueWithLabel:CNLabelEmailiCloud value:@"i@x"],
        [CNLabeledValue labeledValueWithLabel:CNLabelOther value:@"o@x"],
        [CNLabeledValue labeledValueWithLabel:nil value:@"n@x"],
    ];
    CNMutablePostalAddress *a = [CNMutablePostalAddress new];
    a.street = @"1 Infinite Loop\nSuite 2";
    a.city = @"Cupertino";
    a.state = @"CA";
    a.postalCode = @"95014";
    a.country = @"United States";
    a.ISOCountryCode = @"us";
    CNMutablePostalAddress *b = [CNMutablePostalAddress new];
    b.city = @"Town";
    b.subLocality = @"Old Town";
    c.postalAddresses = @[ [CNLabeledValue labeledValueWithLabel:CNLabelHome value:a], [CNLabeledValue labeledValueWithLabel:CNLabelOther value:b] ];
    c.urlAddresses = @[
        [CNLabeledValue labeledValueWithLabel:CNLabelURLAddressHomePage value:@"https://example.com"],
        [CNLabeledValue labeledValueWithLabel:CNLabelWork value:@"w.com"],
    ];
    NSDateComponents *bd = [NSDateComponents new];
    bd.year = 1980, bd.month = 5, bd.day = 17;
    c.birthday = bd;
    NSDateComponents *noYear = [NSDateComponents new];
    noYear.month = 12, noYear.day = 25;
    c.dates = @[ [CNLabeledValue labeledValueWithLabel:CNLabelDateAnniversary value:bd], [CNLabeledValue labeledValueWithLabel:CNLabelOther value:noYear] ];
    c.socialProfiles = @[
        [CNLabeledValue labeledValueWithLabel:nil value:[[CNSocialProfile alloc] initWithUrlString:nil username:@"jq" userIdentifier:nil service:CNSocialProfileServiceTwitter]],
        [CNLabeledValue labeledValueWithLabel:nil value:[[CNSocialProfile alloc] initWithUrlString:@"http://x.com/a" username:@"a" userIdentifier:@"9" service:@"Mastodon"]],
    ];
    c.instantMessageAddresses = @[
        [CNLabeledValue labeledValueWithLabel:CNLabelHome value:[[CNInstantMessageAddress alloc] initWithUsername:@"jqa" service:CNInstantMessageServiceAIM]],
        [CNLabeledValue labeledValueWithLabel:nil value:[[CNInstantMessageAddress alloc] initWithUsername:@"s" service:CNInstantMessageServiceSkype]],
    ];
    c.contactRelations = @[ [CNLabeledValue labeledValueWithLabel:CNLabelContactRelationSpouse value:[CNContactRelation contactRelationWithName:@"Jane"]] ];
    c.note = @"a note";
    return c;
}

static void
model(void)
{
    CNMutableContact *empty = [CNMutableContact new];
    out(@"new: id len %lu suffix %@ given '%@' type %ld phones %lu image %@ birthday %@", (unsigned long)empty.identifier.length,
        [empty.identifier componentsSeparatedByString:@":"].lastObject, empty.givenName, (long)empty.contactType,
        (unsigned long)empty.phoneNumbers.count, empty.imageData, empty.birthday);
    out(@"description %@", empty);
    CNMutableContact *c = sample();
    dump(@"sample", c);
    CNContact *frozen = [c copy];
    out(@"copy %@ equal %d hash %d", [frozen class], [frozen isEqual:c], frozen.hash == c.hash);
    c.givenName = @"Jack";
    out(@"changed: equal %d; other id equal %d", [frozen isEqual:c], [[CNMutableContact new] isEqual:[CNMutableContact new]]);
    CNMutableContact *again = [frozen mutableCopy];
    out(@"mutable copy %@ same id %d", [again class], [again.identifier isEqual:frozen.identifier]);
    out(@"keys: given %d note %d image %d available %d", [c isKeyAvailable:CNContactGivenNameKey], [c isKeyAvailable:CNContactNoteKey],
        [c isKeyAvailable:CNContactImageDataKey], [c areKeysAvailable:@[ [CNContactFormatter descriptorForRequiredKeysForStyle:0] ]]);
    c.imageData = [NSData dataWithBytes:"abc" length:3];
    out(@"image: thumbnail %@ available %d", c.thumbnailImageData, c.imageDataAvailable);

    CNLabeledValue *l = [CNLabeledValue labeledValueWithLabel:CNLabelHome value:@"v"];
    CNLabeledValue *relabeled = [l labeledValueBySettingLabel:CNLabelWork];
    out(@"labeled: same id %d equal %d; value %@ label %@; copy equal %d", [l.identifier isEqual:relabeled.identifier], [l isEqual:relabeled],
        [l labeledValueBySettingValue:@"w"].value, [l labeledValueBySettingLabel:(id _Nonnull)nil value:@"z"].label, [[l copy] isEqual:l]);
    out(@"labeled description %@", l);
    CNPhoneNumber *p = [CNPhoneNumber phoneNumberWithStringValue:@"+1 (408) 555-0123"];
    out(@"phone %@ equal %d other %d nil %@", p, [p isEqual:[CNPhoneNumber phoneNumberWithStringValue:@"+1 (408) 555-0123"]],
        [p isEqual:[CNPhoneNumber phoneNumberWithStringValue:@"14085550123"]], [CNPhoneNumber phoneNumberWithStringValue:(NSString *_Nonnull)(void *)0]);
    CNMutablePostalAddress *a = [CNMutablePostalAddress new];
    a.city = @"X";
    CNPostalAddress *ac = [a copy];
    out(@"postal %@ copy %@ equal %d", a, [ac class], [ac isEqual:a]);
    out(@"relation %@", [CNContactRelation contactRelationWithName:@"J"]);
    out(@"social %@", [[CNSocialProfile alloc] initWithUrlString:nil username:@"jq" userIdentifier:nil service:@"Twitter"]);
    out(@"im %@", [[CNInstantMessageAddress alloc] initWithUsername:@"u" service:@"AIM"]);
    CNMutableGroup *g = [CNMutableGroup new];
    g.name = @"Friends";
    out(@"group %@ copy %@", g, [[g copy] class]);
    CNContactFetchRequest *fr = [[CNContactFetchRequest alloc] initWithKeysToFetch:@[ CNContactGivenNameKey ]];
    out(@"fetch request: unify %d mutable %d sort %ld predicate %@", fr.unifyResults, fr.mutableObjects, (long)fr.sortOrder, fr.predicate);
    out(@"predicates: %@ | %@", [[CNContact predicateForContactsWithIdentifiers:@[ @"a", @"b" ]] predicateFormat],
        [[CNContact predicateForContactsMatchingName:@"x"] class] != nil ? @"name" : @"");
    out(@"descriptors: %@ | %@ | %@ | %@ | %@", [CNContactFormatter descriptorForRequiredKeysForStyle:1],
        [CNContactFormatter descriptorForRequiredKeysForNameOrder], [CNContactFormatter descriptorForRequiredKeysForDelimiter],
        [CNContactVCardSerialization descriptorForRequiredKeys], [CNContact descriptorForAllComparatorKeys]);
    CNMutableContact *x = [CNMutableContact new], *y = [CNMutableContact new], *z = [CNMutableContact new];
    x.givenName = @"Ann", x.familyName = @"Zed";
    y.givenName = @"Bob", y.familyName = @"Young";
    z.organizationName = @"Acme";
    z.contactType = CNContactTypeOrganization;
    for (NSNumber *order in @[ @(CNContactSortOrderGivenName), @(CNContactSortOrderFamilyName) ]) {
        NSArray *sorted = [@[ x, y, z ] sortedArrayUsingComparator:[CNContact comparatorForNameSortOrder:order.integerValue]];
        out(@"sorted by %@: %@", order, [[sorted valueForKey:@"givenName"] componentsJoinedByString:@","]);
    }
}

static void
names(void)
{
    CNMutableContact *c = sample();
    out(@"full '%@' phonetic '%@' order %ld delimiter '%@'", [CNContactFormatter stringFromContact:c style:0],
        [CNContactFormatter stringFromContact:c style:1], (long)[CNContactFormatter nameOrderForContact:c],
        [CNContactFormatter delimiterForContact:c]);
    NSAttributedString *as = [CNContactFormatter attributedStringFromContact:c style:0 defaultAttributes:@{@"k" : @"v"}];
    [as enumerateAttributesInRange:NSMakeRange(0, as.length) options:0 usingBlock:^(NSDictionary *at, NSRange r, BOOL *stop) {
      out(@"  attr %@ %@ %@", NSStringFromRange(r), at[CNContactPropertyAttribute], at[@"k"]);
    }];
    CNMutableContact *j = [CNMutableContact new];
    j.givenName = @"太郎", j.familyName = @"山田";
    out(@"cjk '%@' order %ld delimiter '%@'", [CNContactFormatter stringFromContact:j style:0], (long)[CNContactFormatter nameOrderForContact:j],
        [CNContactFormatter delimiterForContact:j]);
    CNMutableContact *n = [CNMutableContact new];
    out(@"empty '%@'", [CNContactFormatter stringFromContact:n style:0]);
    n.nickname = @"JJ";
    out(@"nickname '%@'", [CNContactFormatter stringFromContact:n style:0]);
    n.organizationName = @"Acme";
    n.nickname = @"";
    out(@"company '%@'", [CNContactFormatter stringFromContact:n style:0]);
    n.givenName = @"Bob";
    out(@"person with company '%@'", [CNContactFormatter stringFromContact:n style:0]);
    n.contactType = CNContactTypeOrganization;
    out(@"organization '%@'", [CNContactFormatter stringFromContact:n style:0]);
    CNMutableContact *e = [CNMutableContact new];
    e.emailAddresses = @[ [CNLabeledValue labeledValueWithLabel:nil value:@"a@b.c"] ];
    out(@"email only '%@'", [CNContactFormatter stringFromContact:e style:0]);
    CNContactFormatter *f = [CNContactFormatter new];
    out(@"formatter '%@' object '%@' not a contact '%@'", [f stringFromContact:c], [f stringForObjectValue:c], [f stringForObjectValue:@"x"]);

    NSArray *addresses = @[
        @[ @"us", @"1 Infinite Loop", @"Cupertino", @"CA", @"95014", @"United States" ],
        @[ @"gb", @"10 Downing St", @"London", @"", @"SW1A 2AA", @"United Kingdom" ],
        @[ @"de", @"Unter den Linden 1", @"Berlin", @"", @"10117", @"Germany" ],
        @[ @"fr", @"1 rue X", @"Paris", @"", @"75001", @"France" ],
        @[ @"ca", @"100 Queen St", @"Ottawa", @"ON", @"K1A 0A9", @"Canada" ],
        @[ @"jp", @"1-1 Chiyoda", @"Chiyoda-ku", @"Tokyo", @"100-0001", @"Japan" ],
        @[ @"au", @"1 George St", @"Sydney", @"NSW", @"2000", @"Australia" ],
        @[ @"", @"5 Main", @"Town", @"", @"", @"" ],
        @[ @"", @"", @"", @"", @"", @"" ],
    ];
    for (NSArray *p in addresses) {
        CNMutablePostalAddress *a = [CNMutablePostalAddress new];
        a.ISOCountryCode = p[0], a.street = p[1], a.city = p[2], a.state = p[3], a.postalCode = p[4], a.country = p[5];
        out(@"address %@: '%@'", p[0], [[CNPostalAddressFormatter stringFromPostalAddress:a style:0] stringByReplacingOccurrencesOfString:@"\n"
                                                                                                                      withString:@" / "]);
    }
    CNMutablePostalAddress *a = [CNMutablePostalAddress new];
    a.street = @"1 Main", a.city = @"Town", a.state = @"CA";
    NSAttributedString *pa = [CNPostalAddressFormatter attributedStringFromPostalAddress:a style:0 withDefaultAttributes:@{}];
    [pa enumerateAttributesInRange:NSMakeRange(0, pa.length) options:0 usingBlock:^(NSDictionary *at, NSRange r, BOOL *stop) {
      out(@"  postal attr %@ %@ %@", NSStringFromRange(r), at[CNPostalAddressPropertyAttribute], at[CNPostalAddressLocalizedPropertyNameAttribute]);
    }];
}

static void
localized(void)
{
    for (NSString *l in @[ CNLabelHome, CNLabelWork, CNLabelOther, CNLabelPhoneNumberMobile, CNLabelPhoneNumberiPhone, CNLabelPhoneNumberMain,
                           CNLabelPhoneNumberHomeFax, CNLabelURLAddressHomePage, CNLabelDateAnniversary, CNLabelContactRelationSpouse,
                           CNLabelContactRelationMother, CNLabelSchool, CNLabelEmailiCloud, @"custom" ])
        out(@"label %@ -> %@", l, [CNLabeledValue localizedStringForLabel:l]);
    for (NSString *k in @[ CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactPhoneNumbersKey,
                           CNContactPostalAddressesKey, CNContactIdentifierKey, CNContactBirthdayKey, @"bogus" ])
        out(@"key %@ -> %@", k, [CNContact localizedStringForKey:k]);
    for (NSString *k in @[ CNPostalAddressStreetKey, CNPostalAddressPostalCodeKey, CNPostalAddressSubLocalityKey ])
        out(@"postal key %@ -> %@", k, [CNPostalAddress localizedStringForKey:k]);
    out(@"services %@ %@ %@ %@", [CNSocialProfile localizedStringForService:CNSocialProfileServiceMySpace],
        [CNSocialProfile localizedStringForService:@"Mastodon"], [CNInstantMessageAddress localizedStringForService:CNInstantMessageServiceGaduGadu],
        [CNInstantMessageAddress localizedStringForKey:CNInstantMessageAddressUsernameKey]);
}

static void
vcard(void)
{
    CNMutableContact *org = [CNMutableContact new];
    org.contactType = CNContactTypeOrganization;
    org.organizationName = @"Acme";
    org.departmentName = @"R&D";
    NSData *data = [CNContactVCardSerialization dataWithContacts:@[ sample(), org, [CNMutableContact new] ] error:NULL];
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    out(@"vCard %lu lines, CRLF %d", (unsigned long)[text componentsSeparatedByString:@"\r\n"].count,
        [text rangeOfString:@"\r\n"].location != NSNotFound);
    for (NSString *line in [text componentsSeparatedByString:@"\r\n"])
        if (![line hasPrefix:@"PRODID:"])
            out(@"  %@", line);
    NSError *error = nil;
    NSArray *back = [CNContactVCardSerialization contactsWithData:data error:&error];
    out(@"read back %lu error %@", (unsigned long)back.count, error);
    for (CNContact *c in back)
        dump(@"back", c);
    NSString *other = @"BEGIN:VCARD\r\nVERSION:2.1\r\nN:Doe;Jane;;;\r\nFN:Jane Doe\r\nTEL;HOME;VOICE:555\r\nTEL;CELL:556\r\n"
                      @"EMAIL;INTERNET:j@x.org\r\nitem1.TEL:777\r\nitem1.X-ABLabel:Boat\r\n"
                      @"NOTE;ENCODING=QUOTED-PRINTABLE:caf=C3=A9 =\r\nau lait\r\nADR;WORK:;;1 Main\\nApt 2;Town;ST;12345;USA\r\n"
                      @"BDAY:19800517\r\nEND:VCARD\r\n"
                      @"BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Only Full\r\nORG:Org Inc;\r\nX-ABShowAs:COMPANY\r\n"
                      @"NOTE:line1\\nline2\\, x\r\n ending\r\nPHOTO;ENCODING=b;TYPE=JPEG:AAEC\r\n"
                      @"X-SOCIALPROFILE;type=twitter;x-userid=5:x-apple:bird\r\nIMPP;X-SERVICE-TYPE=Jabber;type=HOME:xmpp:me@j.org\r\n"
                      @"BDAY;X-APPLE-OMIT-YEAR=1604:1604-12-25\r\nEND:VCARD\r\n";
    back = [CNContactVCardSerialization contactsWithData:[other dataUsingEncoding:NSUTF8StringEncoding] error:&error];
    for (CNContact *c in back) {
        dump(@"other", c);
        out(@"  keys: note %d image %d thumbnail %d", [c isKeyAvailable:CNContactNoteKey], [c isKeyAvailable:CNContactImageDataKey],
            [c isKeyAvailable:CNContactThumbnailImageDataKey]);
    }
    back = [CNContactVCardSerialization contactsWithData:[@"garbage" dataUsingEncoding:NSUTF8StringEncoding] error:&error];
    out(@"garbage: %lu error %ld", (unsigned long)back.count, (long)error.code);
}

/* --- the store (Finch-only) --- */

static void
store(void)
{
    char home[] = "/tmp/finch-contacts.XXXXXX";
    mkdtemp(home);
    setenv("HOME", home, 1);
    setenv("CFFIXED_USER_HOME", home, 1);
    CNContactStore *s = [CNContactStore new];
    __block int notes = 0;
    [[NSNotificationCenter defaultCenter] addObserverForName:CNContactStoreDidChangeNotification object:nil queue:nil
                                                  usingBlock:^(NSNotification *n) { notes++; }];
    out(@"status %ld", (long)[CNContactStore authorizationStatusForEntityType:CNEntityTypeContacts]);
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [s requestAccessForEntityType:CNEntityTypeContacts completionHandler:^(BOOL granted, NSError *error) {
      out(@"access %d %@", granted, error);
      dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    NSArray *containers = [s containersMatchingPredicate:nil error:NULL];
    CNContainer *container = containers.firstObject;
    out(@"containers %lu: %@ type %ld default %d", (unsigned long)containers.count, container.name, (long)container.type,
        [container.identifier isEqual:s.defaultContainerIdentifier]);
    NSData *token0 = s.currentHistoryToken;

    CNMutableContact *john = sample(), *ann = [CNMutableContact new];
    ann.givenName = @"Ann", ann.familyName = @"Zed";
    ann.emailAddresses = @[ [CNLabeledValue labeledValueWithLabel:CNLabelHome value:@"Ann@Example.org"] ];
    CNSaveRequest *save = [CNSaveRequest new];
    [save addContact:john toContainerWithIdentifier:nil];
    [save addContact:ann toContainerWithIdentifier:nil];
    NSError *error = nil;
    out(@"save %d %@; description persisted %d", [s executeSaveRequest:save error:&error], error,
        [[john description] rangeOfString:@"non-persisted"].location == NSNotFound);
    out(@"notifications %d", notes);
    save = [CNSaveRequest new];
    [save addContact:john toContainerWithIdentifier:nil];
    out(@"again: %d code %ld", [s executeSaveRequest:save error:&error], (long)error.code);

    CNContactFetchRequest *fr = [[CNContactFetchRequest alloc] initWithKeysToFetch:@[ CNContactGivenNameKey, CNContactFamilyNameKey ]];
    fr.sortOrder = CNContactSortOrderGivenName;
    NSMutableArray *seen = [NSMutableArray array];
    [s enumerateContactsWithFetchRequest:fr error:NULL usingBlock:^(CNContact *c, BOOL *stop) {
      [seen addObject:[NSString stringWithFormat:@"%@ %@ (%@)", c.givenName, c.familyName, [c class]]];
    }];
    out(@"all: %@", [seen componentsJoinedByString:@"; "]);
    CNContact *fetched = [s unifiedContactWithIdentifier:john.identifier keysToFetch:@[ CNContactGivenNameKey ] error:&error];
    out(@"by id: %@ note available %d", fetched.givenName, [fetched isKeyAvailable:CNContactNoteKey]);
    @try {
        (void)fetched.note;
        out(@"note read");
    } @catch (NSException *e) {
        out(@"note: %@ %@", e.name, e.reason);
    }
    out(@"missing: %@ code %ld", [s unifiedContactWithIdentifier:@"nope" keysToFetch:@[] error:&error], (long)error.code);
    NSArray *byName = [s unifiedContactsMatchingPredicate:[CNContact predicateForContactsMatchingName:@"apple"] keysToFetch:@[ CNContactGivenNameKey ]
                                                    error:NULL];
    out(@"name 'apple': %@", [[byName valueForKey:@"givenName"] componentsJoinedByString:@","]);
    byName = [s unifiedContactsMatchingPredicate:[CNContact predicateForContactsMatchingName:@"jo app"] keysToFetch:@[ CNContactGivenNameKey ]
                                           error:NULL];
    out(@"name 'jo app': %@", [[byName valueForKey:@"givenName"] componentsJoinedByString:@","]);
    NSArray *byEmail = [s unifiedContactsMatchingPredicate:[CNContact predicateForContactsMatchingEmailAddress:@"ann@example.org"]
                                               keysToFetch:@[ CNContactGivenNameKey ]
                                                     error:NULL];
    out(@"email: %@", [[byEmail valueForKey:@"givenName"] componentsJoinedByString:@","]);
    NSArray *byPhone = [s unifiedContactsMatchingPredicate:[CNContact predicateForContactsMatchingPhoneNumber:
                                                                          [CNPhoneNumber phoneNumberWithStringValue:@"408-555-0123"]]
                                               keysToFetch:@[ CNContactGivenNameKey ]
                                                     error:NULL];
    out(@"phone: %@", [[byPhone valueForKey:@"givenName"] componentsJoinedByString:@","]);

    /* an update with some keys changes just those */
    CNMutableContact *m = [[s unifiedContactWithIdentifier:ann.identifier keysToFetch:@[ CNContactGivenNameKey ] error:NULL] mutableCopy];
    m.givenName = @"Anne";
    save = [CNSaveRequest new];
    [save updateContact:m];
    out(@"update %d", [s executeSaveRequest:save error:NULL]);
    CNContact *anne = [s unifiedContactWithIdentifier:ann.identifier keysToFetch:@[ CNContactGivenNameKey, CNContactEmailAddressesKey ]
                                                error:NULL];
    out(@"updated: %@ emails %@", anne.givenName, labels(anne.emailAddresses));

    /* groups */
    CNMutableGroup *friends = [CNMutableGroup new];
    friends.name = @"Friends";
    save = [CNSaveRequest new];
    [save addGroup:friends toContainerWithIdentifier:nil];
    [save addMember:john toGroup:friends];
    out(@"group save %d", [s executeSaveRequest:save error:NULL]);
    NSArray *groups = [s groupsMatchingPredicate:nil error:NULL];
    out(@"groups: %@", [[groups valueForKey:@"name"] componentsJoinedByString:@","]);
    NSArray *members = [s unifiedContactsMatchingPredicate:[CNContact predicateForContactsInGroupWithIdentifier:friends.identifier]
                                               keysToFetch:@[ CNContactGivenNameKey ]
                                                     error:NULL];
    out(@"members: %@", [[members valueForKey:@"givenName"] componentsJoinedByString:@","]);

    /* history since the start, then since now */
    CNChangeHistoryFetchRequest *hr = [CNChangeHistoryFetchRequest new];
    hr.startingToken = token0;
    hr.includeGroupChanges = YES;
    CNFetchResult *r = [s enumeratorForChangeHistoryFetchRequest:hr error:NULL];
    NSMutableArray *events = [NSMutableArray array];
    for (CNChangeHistoryEvent *e in r.value)
        [events addObject:NSStringFromClass([e class])];
    out(@"history: %@", [events componentsJoinedByString:@", "]);
    hr.startingToken = r.currentHistoryToken;
    out(@"since now: %lu", (unsigned long)[[[s enumeratorForChangeHistoryFetchRequest:hr error:NULL].value allObjects] count]);
    hr.startingToken = nil;
    [events removeAllObjects];
    for (CNChangeHistoryEvent *e in [s enumeratorForChangeHistoryFetchRequest:hr error:NULL].value)
        [events addObject:NSStringFromClass([e class])];
    out(@"from nothing: %@", [events componentsJoinedByString:@", "]);

    /* another store sees it; delete */
    CNContactStore *other = [CNContactStore new];
    out(@"other store: %lu", (unsigned long)[[other unifiedContactsMatchingPredicate:[CNContact predicateForContactsMatchingName:@"Anne"]
                                                                          keysToFetch:@[]
                                                                                error:NULL] count]);
    save = [CNSaveRequest new];
    [save deleteContact:john];
    out(@"delete %d", [s executeSaveRequest:save error:NULL]);
    fr.sortOrder = CNContactSortOrderNone;
    CNFetchResult *all = [s enumeratorForContactFetchRequest:fr error:NULL];
    out(@"left: %lu; members %lu", (unsigned long)[[all.value allObjects] count],
        (unsigned long)[[s unifiedContactsMatchingPredicate:[CNContact predicateForContactsInGroupWithIdentifier:friends.identifier]
                                                keysToFetch:@[]
                                                      error:NULL] count]);
    out(@"me: %@", [s unifiedMeContactWithKeysToFetch:@[] error:&error]);
    out(@"notifications %d", notes);
    [[NSFileManager defaultManager] removeItemAtPath:@(home) error:NULL];
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        [[NSUserDefaults standardUserDefaults] setVolatileDomain:@{@"AppleLanguages" : @[ @"en" ], @"AppleLocale" : @"en_US"}
                                                         forName:NSArgumentDomain];
        printf("%s\n", [[NSBundle bundleForClass:[CNContact class]] executablePath].UTF8String);
        if (argc > 1 && !strcmp(argv[1], "store")) {
            store();
            return 0;
        }
        model();
        names();
        localized();
        vcard();
    }
    return 0;
}
