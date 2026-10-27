/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-new-classes-test: Foundation's grammar classes (NSMorphology and its
 * pronouns, NSTermOfAddress, the inflection rules), NSExtensionItem,
 * NSProtocolChecker, NSPurgeableData and NSGarbageCollector: descriptions,
 * equality, validation, archives and errors, compared with Apple's on the host.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdio.h>

/* (the custom pronoun API is deprecated, and still Apple's) */
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

/* A description with its addresses taken out. */
static const char *
clean(NSString *s)
{
    s = [s ?: @"(nil)" stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    NSRegularExpression *address = [NSRegularExpression regularExpressionWithPattern:@"0x[0-9a-f]+" options:0 error:NULL];
    return [[address stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@"ADDR"] UTF8String];
}

#define TRY(label, ...)                                                                  \
    @try {                                                                               \
        printf("%s: %s\n", label, clean([(__VA_ARGS__) description]));                   \
    } @catch (NSException * e) {                                                         \
        printf("%s: raised %s: %s\n", label, e.name.UTF8String, clean(e.reason));         \
    }

/* The keys each archived object has, with integer values. */
static void
archive(const char *label, id object)
{
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:object requiringSecureCoding:YES error:NULL];
    NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
    NSMutableArray *parts = [NSMutableArray array];
    for (id o in plist[@"$objects"]) {
        if (![o isKindOfClass:[NSDictionary class]]) continue;
        NSMutableArray *keys = [NSMutableArray array];
        for (NSString *k in [[o allKeys] sortedArrayUsingSelector:@selector(compare:)])
            [keys addObject:[o[k] isKindOfClass:[NSNumber class]] ? [NSString stringWithFormat:@"%@=%@", k, o[k]] : k];
        [parts addObject:[keys componentsJoinedByString:@","]];
    }
    printf("archive %s: %s\n", label, [[parts componentsJoinedByString:@" | "] UTF8String]);
    id back = [NSKeyedUnarchiver unarchivedObjectOfClass:[object class] fromData:data error:NULL];
    printf("  round trip equal: %d\n", [back isEqual:object]);
}

@protocol Ping
- (id)ping;
- (id)me;
@optional
- (int)opt;
@end
@interface Target : NSObject <Ping>
@end
@implementation Target
- (id)ping { return @"pong"; }
- (id)me { return self; }
- (int)opt { return 7; }
@end

static void
morphology(void)
{
    NSMorphology *m = [NSMorphology new];
    TRY("empty", m);
    printf("unspecified %d\n", m.isUnspecified);
    m.grammaticalGender = NSGrammaticalGenderFeminine;
    m.number = NSGrammaticalNumberPluralFew;
    m.partOfSpeech = NSGrammaticalPartOfSpeechAbbreviation;
    m.grammaticalCase = NSGrammaticalCaseTranslative;
    m.definiteness = NSGrammaticalDefinitenessDefinite;
    m.determination = NSGrammaticalDeterminationDependent;
    m.grammaticalPerson = NSGrammaticalPersonThird;
    m.pronounType = NSGrammaticalPronounTypePossessive;
    TRY("set", m);
    printf("hash %lu unspecified %d\n", (unsigned long)m.hash, m.isUnspecified);
    NSMorphology *odd = [NSMorphology new];
    odd.grammaticalGender = 99;
    TRY("out of range", odd);
    NSMorphology *copy = [m copy];
    printf("copy equal %d, hash equal %d\n", [copy isEqual:m], copy.hash == m.hash);
    archive("morphology", m);
    TRY("user", [NSMorphology userMorphology]);

    for (NSString *l in @[ @"en", @"en_GB", @"EN-us", @"de", @"fr", @"ja", @"" ])
        printf("%s: pronouns %d keys %s inflect %d\n", l.UTF8String, [NSMorphologyCustomPronoun isSupportedForLanguage:l],
            [[[NSMorphologyCustomPronoun requiredKeysForLanguage:l] componentsJoinedByString:@","] UTF8String],
            [NSInflectionRule canInflectLanguage:l]);

    NSMorphologyCustomPronoun *p = [NSMorphologyCustomPronoun new];
    p.subjectForm = @"they";
    TRY("partial pronoun", p);
    NSError *error = nil;
    printf("set partial %d\n", [m setCustomPronoun:p forLanguage:@"en" error:&error]);
    TRY("error", error);
    p.objectForm = @"them";
    p.possessiveForm = @"theirs";
    p.possessiveAdjectiveForm = @"their";
    p.reflexiveForm = @"themself";
    error = nil;
    printf("set unsupported %d\n", [m setCustomPronoun:p forLanguage:@"fr" error:&error]);
    TRY("error", error);
    printf("set en-US %d\n", [m setCustomPronoun:p forLanguage:@"en-US" error:NULL]);
    TRY("with pronoun", m);
    TRY("en", [m customPronounForLanguage:@"en"]);
    TRY("en-US", [m customPronounForLanguage:@"en-US"]);
    printf("same object %d, equal %d, equal to unset %d\n", [m customPronounForLanguage:@"en-US"] == p,
        [[m customPronounForLanguage:@"en-US"] isEqual:p], [m isEqual:copy]);
    archive("pronoun", p);
    archive("morphology with pronoun", m);
    printf("remove %d\n", [m setCustomPronoun:nil forLanguage:@"en-US" error:NULL]);
    TRY("removed", m);
    printf("equal again %d\n", [m isEqual:copy]);

    NSMorphologyPronoun *she = [[NSMorphologyPronoun alloc] initWithPronoun:@"she" morphology:copy dependentMorphology:nil];
    TRY("pronoun", she.pronoun);
    printf("morphology copied %d, equal %d\n", she.morphology != copy, [she.morphology isEqual:copy]);
    archive("morphology pronoun", she);

    for (NSTermOfAddress *t in @[ [NSTermOfAddress neutral], [NSTermOfAddress feminine], [NSTermOfAddress masculine] ]) {
        printf("term hash %lu, language %s, copy same %d\n", (unsigned long)t.hash, t.languageIdentifier.UTF8String ?: "-",
            [t copy] == t);
        archive("term", t);
    }
    NSTermOfAddress *local = [NSTermOfAddress localizedForLanguageIdentifier:@"en" withPronouns:@[ she ]];
    TRY("localized language", local.languageIdentifier);
    printf("localized equal %d, pronouns %lu\n",
        [local isEqual:[NSTermOfAddress localizedForLanguageIdentifier:@"en" withPronouns:@[ she ]]], (unsigned long)local.pronouns.count);
    archive("localized term", local);

    TRY("automatic", [NSInflectionRule automaticRule]);
    printf("automatic singleton %d, copy same %d\n", [NSInflectionRule automaticRule] == [NSInflectionRule automaticRule],
        [[NSInflectionRule automaticRule] copy] == [NSInflectionRule automaticRule]);
    archive("automatic", [NSInflectionRule automaticRule]);
    NSInflectionRuleExplicit *explicit = [[NSInflectionRuleExplicit alloc] initWithMorphology:copy];
    TRY("explicit", explicit);
    printf("explicit equal %d\n", [explicit isEqual:[[NSInflectionRuleExplicit alloc] initWithMorphology:copy]]);
    archive("explicit", explicit);
}

static void
extensions(void)
{
    NSExtensionItem *item = [NSExtensionItem new];
    TRY("empty item", item);
    item.attributedTitle = [[NSAttributedString alloc] initWithString:@"Title"];
    item.attributedContentText = [[NSAttributedString alloc] initWithString:@"Content"];
    item.attachments = @[];
    NSMutableDictionary *info = [item.userInfo mutableCopy];
    info[@"k"] = @"v";
    item.userInfo = info;
    printf("keys: %s\n", [[[item.userInfo.allKeys sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","] UTF8String]);
    printf("title is data %d\n", [item.userInfo[NSExtensionItemAttributedTitleKey] isKindOfClass:[NSData class]]);
    TRY("title", item.attributedTitle.string);
    TRY("content", item.attributedContentText.string);
    TRY("attachments", item.attachments);
    NSExtensionItem *copy = [item copy];
    printf("copy equal %d, same user info %d\n", [copy isEqual:item], [copy.userInfo isEqual:item.userInfo]);
    item.attributedTitle = nil;
    item.attachments = nil;
    printf("after clearing: %s\n", [[[item.userInfo.allKeys sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","] UTF8String]);
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:copy requiringSecureCoding:YES error:NULL];
    NSError *error = nil;
    NSExtensionItem *back = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSExtensionItem class] fromData:data error:&error];
    printf("unarchived %d\n", back != nil);
    printf("unarchive error %ld\n", (long)error.code);
    TRY("unarchived title", back.attributedTitle.string);
    TRY("context items", [[NSExtensionContext alloc] init].inputItems);
}

static void
checker(void)
{
    Target *target = [Target new];
    NSProtocolChecker *checker = [NSProtocolChecker protocolCheckerWithTarget:target protocol:@protocol(Ping)];
    id pc = checker;
    TRY("class", NSStringFromClass([pc class]));
    TRY("superclass", NSStringFromClass(class_getSuperclass(object_getClass(pc))));
    TRY("protocol", NSStringFromProtocol(checker.protocol));
    printf("target %d\n", checker.target == target);
    TRY("ping", [pc ping]);
    printf("me is target %d\n", [pc me] == target);
    printf("optional %d\n", [pc opt]);
    printf("responds ping %d length %d, conforms %d NSCopying %d\n", [pc respondsToSelector:@selector(ping)],
        [pc respondsToSelector:@selector(length)], [pc conformsToProtocol:@protocol(Ping)], [pc conformsToProtocol:@protocol(NSCopying)]);
    printf("signature ping %d length %d\n", [pc methodSignatureForSelector:@selector(ping)] != nil,
        [pc methodSignatureForSelector:@selector(length)] != nil);
    TRY("undeclared", @([pc length]));
    printf("hash differs %d, equal %d\n", [pc hash] != [target hash], [pc isEqual:target]);
}

static void
purgeable(void)
{
    NSPurgeableData *d = [NSPurgeableData dataWithBytes:"abc" length:3];
    TRY("superclass", NSStringFromClass([NSPurgeableData superclass]));
    TRY("new", d);
    printf("begin %d\n", [d beginContentAccess]);
    [d endContentAccess];
    [d discardContentIfPossible];
    printf("discarded while open %d\n", d.isContentDiscarded);
    [d endContentAccess];
    TRY("closed", d);
    TRY("length", @(d.length));
    TRY("bytes", @(d.bytes != NULL));
    TRY("setLength", (d.length = 2, @"set"));
    @try {
        [d endContentAccess];
        printf("extra end accepted\n");
    } @catch (NSException *e) {
        printf("extra end: %s %s\n", e.name.UTF8String, e.reason.UTF8String);
    }
    [d discardContentIfPossible];
    printf("discarded %d, begin %d\n", d.isContentDiscarded, [d beginContentAccess]);
    NSPurgeableData *e = [[NSPurgeableData alloc] initWithLength:4];
    [e appendBytes:"xy" length:2];
    TRY("grown", e);
    TRY("copy", [e copy]);
    printf("copy equal %d\n", [[e copy] isEqual:e]);
    TRY("capacity", [[NSPurgeableData alloc] initWithCapacity:8]);

    Class gc = NSClassFromString(@"NSGarbageCollector");
    printf("collector class %d, default %s\n", gc != nil, [gc performSelector:@selector(defaultCollector)] ? "yes" : "nil");
}

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        morphology();
        extensions();
        checker();
        purgeable();
    }
    return 0;
}
