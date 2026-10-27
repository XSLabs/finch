/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Grammatical agreement's model classes (docs/design/FOUNDATION.md), against
 * the SDK's <Foundation/NSMorphology.h>, <Foundation/NSTermOfAddress.h> and
 * <Foundation/NSInflectionRule.h>: NSMorphology and its pronoun classes,
 * NSTermOfAddress and the inflection rules. Descriptions, equality, hashes and
 * archive keys are Apple's. The user's own term of address isn't kept
 * anywhere yet, so +userMorphology is unspecified and +currentUser neutral.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include "Foundation_Finch.h"

/* The language part of an identifier ("en" of "en-US", "en_GB"), lowercased. */
static NSString *
language_code(NSString *language)
{
    NSRange r = [language rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"-_"]];
    return [(r.location == NSNotFound ? language : [language substringToIndex:r.location]) lowercaseString];
}

/* MARK: - NSMorphologyCustomPronoun */

@implementation NSMorphologyCustomPronoun

+ (BOOL)supportsSecureCoding { return YES; }

+ (BOOL)isSupportedForLanguage:(NSString *)language
{
    return [language_code(language) isEqualToString:@"en"];
}

+ (NSArray<NSString *> *)requiredKeysForLanguage:(NSString *)language
{
    if (![self isSupportedForLanguage:language]) return @[];
    return @[ @"subjectForm", @"objectForm", @"possessiveForm", @"possessiveAdjectiveForm", @"reflexiveForm" ];
}

- (void)dealloc
{
    [_subjectForm release];
    [_objectForm release];
    [_possessiveForm release];
    [_possessiveAdjectiveForm release];
    [_reflexiveForm release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    NSMorphologyCustomPronoun *copy = [[[self class] allocWithZone:zone] init];
    copy.subjectForm = _subjectForm;
    copy.objectForm = _objectForm;
    copy.possessiveForm = _possessiveForm;
    copy.possessiveAdjectiveForm = _possessiveAdjectiveForm;
    copy.reflexiveForm = _reflexiveForm;
    return copy;
}

static BOOL
same(id a, id b)
{
    return a == b || [a isEqual:b];
}

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[NSMorphologyCustomPronoun class]]) return NO;
    NSMorphologyCustomPronoun *o = other;
    return same(_subjectForm, o.subjectForm) && same(_objectForm, o.objectForm) && same(_possessiveForm, o.possessiveForm)
        && same(_possessiveAdjectiveForm, o.possessiveAdjectiveForm) && same(_reflexiveForm, o.reflexiveForm);
}

- (NSUInteger)hash
{
    return [_subjectForm hash] ^ [_objectForm hash] ^ [_possessiveForm hash] ^ [_possessiveAdjectiveForm hash] ^ [_reflexiveForm hash];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%s: %p> { subject: '%@', object: '%@', possessive: '%@', possessive adjective: '%@', reflexive: '%@' }",
        object_getClassName(self), self, _subjectForm, _objectForm, _possessiveForm, _possessiveAdjectiveForm, _reflexiveForm];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_subjectForm forKey:@"subjectForm"];
    [coder encodeObject:_objectForm forKey:@"objectForm"];
    [coder encodeObject:_possessiveForm forKey:@"possessiveForm"];
    [coder encodeObject:_possessiveAdjectiveForm forKey:@"possessiveAdjectiveForm"];
    [coder encodeObject:_reflexiveForm forKey:@"reflexiveForm"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [self init])) {
        Class s = [NSString class];
        _subjectForm = [[coder decodeObjectOfClass:s forKey:@"subjectForm"] copy];
        _objectForm = [[coder decodeObjectOfClass:s forKey:@"objectForm"] copy];
        _possessiveForm = [[coder decodeObjectOfClass:s forKey:@"possessiveForm"] copy];
        _possessiveAdjectiveForm = [[coder decodeObjectOfClass:s forKey:@"possessiveAdjectiveForm"] copy];
        _reflexiveForm = [[coder decodeObjectOfClass:s forKey:@"reflexiveForm"] copy];
    }
    return self;
}

@end

/* MARK: - NSMorphology */

@interface NSMorphology () {
@public
    NSMutableDictionary<NSString *, NSMorphologyCustomPronoun *> *_customPronouns;
}
@end

@implementation NSMorphology

+ (BOOL)supportsSecureCoding { return YES; }

+ (NSMorphology *)userMorphology { return [[[self alloc] init] autorelease]; }

- (void)dealloc
{
    [_customPronouns release];
    [super dealloc];
}

- (BOOL)isUnspecified
{
    return !_grammaticalGender && !_partOfSpeech && !_number && !_grammaticalCase && !_determination && !_grammaticalPerson
        && !_pronounType && !_definiteness && ![_customPronouns count];
}

- (NSMorphologyCustomPronoun *)customPronounForLanguage:(NSString *)language
{
    return [[[_customPronouns objectForKey:[language lowercaseString]] copy] autorelease];
}

- (BOOL)setCustomPronoun:(NSMorphologyCustomPronoun *)features forLanguage:(NSString *)language error:(NSError **)error
{
    NSString *invalid = nil;
    if (![NSMorphologyCustomPronoun isSupportedForLanguage:language]) {
        invalid = @"self";
    } else if (features) {
        for (NSString *key in [NSMorphologyCustomPronoun requiredKeysForLanguage:language]) {
            if (![features valueForKey:key]) {
                invalid = key;
                break;
            }
        }
    }
    if (invalid) {
        if (error)
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSKeyValueValidationError
                                     userInfo:@{ @"NSInvalidValue" : invalid }];
        return NO;
    }
    if (!_customPronouns) _customPronouns = [[NSMutableDictionary alloc] init];
    if (features)
        [_customPronouns setObject:[[features copy] autorelease] forKey:[language lowercaseString]];
    else
        [_customPronouns removeObjectForKey:[language lowercaseString]];
    return YES;
}

- (id)copyWithZone:(NSZone *)zone
{
    NSMorphology *copy = [[[self class] allocWithZone:zone] init];
    copy.grammaticalGender = _grammaticalGender;
    copy.partOfSpeech = _partOfSpeech;
    copy.number = _number;
    copy.grammaticalCase = _grammaticalCase;
    copy.determination = _determination;
    copy.grammaticalPerson = _grammaticalPerson;
    copy.pronounType = _pronounType;
    copy.definiteness = _definiteness;
    copy->_customPronouns = [_customPronouns mutableCopy];
    return copy;
}

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[NSMorphology class]]) return NO;
    NSMorphology *o = other;
    return _grammaticalGender == o.grammaticalGender && _partOfSpeech == o.partOfSpeech && _number == o.number
        && _grammaticalCase == o.grammaticalCase && _determination == o.determination && _grammaticalPerson == o.grammaticalPerson
        && _pronounType == o.pronounType && _definiteness == o.definiteness
        && ([_customPronouns count] + [o->_customPronouns count] == 0 || same(_customPronouns, o->_customPronouns));
}

- (NSUInteger)hash
{
    return (NSUInteger)(_grammaticalGender ^ _partOfSpeech ^ _number ^ _grammaticalCase ^ _determination ^ _grammaticalPerson
        ^ _pronounType ^ _definiteness) ^ [_customPronouns hash];
}

static NSString *
value_name(const char *type, NSInteger value, NSArray<NSString *> *names)
{
    if (value >= 0 && (NSUInteger)value < [names count]) return names[(NSUInteger)value];
    return [NSString stringWithFormat:@"(%s)(%ld)", type, (long)value];
}

- (NSString *)description
{
    NSString *genders = value_name("NSGrammaticalGender", _grammaticalGender, @[ @"NotSet", @"Feminine", @"Masculine", @"Neuter" ]);
    NSString *numbers = value_name("NSGrammaticalNumber", _number,
        @[ @"NotSet", @"Singular", @"Zero", @"Plural", @"PluralTwo", @"PluralFew", @"PluralMany" ]);
    NSString *parts = value_name("NSGrammaticalPartOfSpeech", _partOfSpeech,
        @[ @"NotSet", @"Determiner", @"Pronoun", @"Letter", @"Adverb", @"Particle", @"Adjective", @"Adposition", @"Verb", @"Noun",
            @"Conjunction", @"Numeral", @"Interjection", @"Preposition", @"Abbreviation" ]);
    NSString *cases = value_name("NSGrammaticalCase", _grammaticalCase,
        @[ @"NotSet", @"Nominative", @"Accusative", @"Dative", @"Genitive", @"Prepositional", @"Ablative", @"Adessive", @"Allative",
            @"Elative", @"Illative", @"Essive", @"Inessive", @"Locative", @"Translative" ]);
    NSString *definiteness = value_name("NSGrammaticalDefiniteness", _definiteness, @[ @"NotSet", @"Indefinite", @"Definite" ]);
    NSString *determination = value_name("NSGrammaticalDetermination", _determination, @[ @"NotSet", @"Independent", @"Dependent" ]);
    NSString *person = value_name("NSGrammaticalPerson", _grammaticalPerson, @[ @"NotSet", @"First", @"Second", @"Third" ]);
    NSString *pronoun = value_name("NSGrammaticalPronounType", _pronounType, @[ @"NotSet", @"Personal", @"Reflexive", @"Possessive" ]);
    return [NSString stringWithFormat:@"<%s: %p> { grammaticalGender = %@, number = %@, partOfSpeech = %@, case = %@, definiteness = %@, "
                                      @"determination = %@, grammaticalPerson = %@, pronounType = %@, customPronouns = %@ }",
        object_getClassName(self), self, genders, numbers, parts, cases, definiteness, determination, person, pronoun, _customPronouns];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInteger:_grammaticalGender forKey:@"grammaticalGender"];
    [coder encodeInteger:_partOfSpeech forKey:@"partOfSpeech"];
    [coder encodeInteger:_number forKey:@"number"];
    [coder encodeInteger:_grammaticalCase forKey:@"grammaticalCase"];
    [coder encodeInteger:_determination forKey:@"determination"];
    [coder encodeInteger:_grammaticalPerson forKey:@"grammaticalPerson"];
    [coder encodeInteger:_pronounType forKey:@"pronounType"];
    [coder encodeInteger:_definiteness forKey:@"definiteness"];
    if (_customPronouns) [coder encodeObject:_customPronouns forKey:@"customPronouns"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [self init])) {
        _grammaticalGender = [coder decodeIntegerForKey:@"grammaticalGender"];
        _partOfSpeech = [coder decodeIntegerForKey:@"partOfSpeech"];
        _number = [coder decodeIntegerForKey:@"number"];
        _grammaticalCase = [coder decodeIntegerForKey:@"grammaticalCase"];
        _determination = [coder decodeIntegerForKey:@"determination"];
        _grammaticalPerson = [coder decodeIntegerForKey:@"grammaticalPerson"];
        _pronounType = [coder decodeIntegerForKey:@"pronounType"];
        _definiteness = [coder decodeIntegerForKey:@"definiteness"];
        NSDictionary *pronouns = [coder decodeDictionaryWithKeysOfClass:[NSString class]
                                                         objectsOfClass:[NSMorphologyCustomPronoun class]
                                                                 forKey:@"customPronouns"];
        if (pronouns) _customPronouns = [pronouns mutableCopy];
    }
    return self;
}

@end

/* MARK: - NSMorphologyPronoun */

@implementation NSMorphologyPronoun

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithPronoun:(NSString *)pronoun morphology:(NSMorphology *)morphology dependentMorphology:(NSMorphology *)dependent
{
    if ((self = [super init])) {
        _pronoun = [pronoun copy];
        _morphology = [morphology copy];
        _dependentMorphology = [dependent copy];
    }
    return self;
}

- (void)dealloc
{
    [_pronoun release];
    [_morphology release];
    [_dependentMorphology release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[NSMorphologyPronoun class]]) return NO;
    NSMorphologyPronoun *o = other;
    return same(_pronoun, o.pronoun) && same(_morphology, o.morphology) && same(_dependentMorphology, o.dependentMorphology);
}

- (NSUInteger)hash { return [_pronoun hash] ^ [_morphology hash] ^ [_dependentMorphology hash]; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_pronoun forKey:@"pronoun"];
    [coder encodeObject:_morphology forKey:@"morphology"];
    if (_dependentMorphology) [coder encodeObject:_dependentMorphology forKey:@"dependentMorphology"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    return [self initWithPronoun:[coder decodeObjectOfClass:[NSString class] forKey:@"pronoun"]
                      morphology:[coder decodeObjectOfClass:[NSMorphology class] forKey:@"morphology"]
             dependentMorphology:[coder decodeObjectOfClass:[NSMorphology class] forKey:@"dependentMorphology"]];
}

@end

/* MARK: - NSTermOfAddress */

/* Apple's archived kinds: the localized ones store a language and pronouns instead. */
enum { TermLocalized = 0, TermFeminine = 1, TermMasculine = 2, TermNeutral = 3 };

@interface NSTermOfAddress () {
    NSInteger _kind;
    NSString *_language;
    NSArray *_pronouns;
}
@end

@implementation NSTermOfAddress

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)_initWithKind:(NSInteger)kind language:(NSString *)language pronouns:(NSArray *)pronouns
{
    if ((self = [super init])) {
        _kind = kind;
        _language = [language copy];
        _pronouns = [pronouns copy];
    }
    return self;
}

#define TERM(name, kind)                                                                    \
    +(instancetype)name                                                                     \
    {                                                                                       \
        static NSTermOfAddress *term;                                                       \
        static dispatch_once_t once;                                                        \
        dispatch_once(&once, ^{ term = [[self alloc] _initWithKind:kind language:nil pronouns:nil]; }); \
        return term;                                                                        \
    }
TERM(neutral, TermNeutral)
TERM(feminine, TermFeminine)
TERM(masculine, TermMasculine)
#undef TERM

+ (instancetype)currentUser { return [self neutral]; }

+ (instancetype)localizedForLanguageIdentifier:(NSString *)language withPronouns:(NSArray<NSMorphologyPronoun *> *)pronouns
{
    return [[[self alloc] _initWithKind:TermLocalized language:language pronouns:pronouns] autorelease];
}

- (void)dealloc
{
    [_language release];
    [_pronouns release];
    [super dealloc];
}

- (NSString *)languageIdentifier { return _language; }
- (NSArray *)pronouns { return _pronouns; }

- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[NSTermOfAddress class]]) return NO;
    NSTermOfAddress *o = other;
    return _kind == o->_kind && same(_language, o->_language) && same(_pronouns, o->_pronouns);
}

- (NSUInteger)hash { return _kind ? (NSUInteger)_kind : [_language hash] ^ [_pronouns hash]; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    if (_kind) {
        [coder encodeInteger:_kind forKey:@"termOfAddress"];
    } else {
        [coder encodeObject:_language forKey:@"language"];
        [coder encodeObject:_pronouns forKey:@"pronouns"];
    }
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSInteger kind = [coder decodeIntegerForKey:@"termOfAddress"];
    if (kind) return [self _initWithKind:kind language:nil pronouns:nil];
    NSArray *pronouns = [coder decodeArrayOfObjectsOfClass:[NSMorphologyPronoun class] forKey:@"pronouns"];
    return [self _initWithKind:TermLocalized language:[coder decodeObjectOfClass:[NSString class] forKey:@"language"] pronouns:pronouns];
}

@end

/* MARK: - NSInflectionRule */

/* (NSInflectionRule's -init is unavailable: the class is abstract.) */
@interface NSInflectionRule ()
- (instancetype)_init;
@end

@interface _NSInflectionRuleAutomatic : NSInflectionRule
@end

@implementation NSInflectionRule

+ (BOOL)supportsSecureCoding { return YES; }

+ (NSInflectionRule *)automaticRule
{
    static NSInflectionRule *rule;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ rule = [[_NSInflectionRuleAutomatic alloc] _init]; });
    return rule;
}

/* The languages Apple's agreement engine inflects. */
+ (BOOL)canInflectLanguage:(NSString *)language
{
    static NSSet *languages;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ languages = [[NSSet alloc] initWithObjects:@"en", @"de", @"es", @"fr", @"it", @"pt", nil]; });
    return [languages containsObject:language_code(language)];
}

+ (BOOL)canInflectPreferredLocalization
{
    NSString *language = [[[NSBundle mainBundle] preferredLocalizations] firstObject];
    return language && [self canInflectLanguage:language];
}

- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
- (void)encodeWithCoder:(NSCoder *)coder { }
- (instancetype)_init { return [super init]; }
- (instancetype)initWithCoder:(NSCoder *)coder { return [super init]; }

@end

@implementation _NSInflectionRuleAutomatic

- (instancetype)initWithCoder:(NSCoder *)coder
{
    [self release];
    return (id)[[NSInflectionRule automaticRule] retain];
}

- (NSString *)description { return [NSString stringWithFormat:@"<%s: %p> (automatic inflection rule)", object_getClassName(self), self]; }

@end

@implementation NSInflectionRuleExplicit

- (instancetype)initWithMorphology:(NSMorphology *)morphology
{
    if ((self = [super _init])) _morphology = [morphology copy];
    return self;
}

- (void)dealloc
{
    [_morphology release];
    [super dealloc];
}

- (BOOL)isEqual:(id)other
{
    return other == self || ([other isKindOfClass:[NSInflectionRuleExplicit class]] && same(_morphology, [other morphology]));
}

- (NSUInteger)hash { return [_morphology hash]; }

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%s: %p> { morphology = %@ }", object_getClassName(self), self, _morphology];
}

- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeObject:_morphology forKey:@"NS.Morphology"]; }

- (instancetype)initWithCoder:(NSCoder *)coder
{
    return [self initWithMorphology:[coder decodeObjectOfClass:[NSMorphology class] forKey:@"NS.Morphology"]];
}

@end
