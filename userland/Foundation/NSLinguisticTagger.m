/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSOrthography and NSLinguisticTagger, Finch's own. Apple's tagger runs trained
 * language models; Finch's tags what rules can: token types, languages and scripts.
 *
 *   - Words, whitespace and punctuation come from ICU's word boundaries (through
 *     CFStringTokenizer), sentences and paragraphs from its sentence and paragraph
 *     units. As Apple's: runs of sentence-ending marks ("...", "?!") are one token,
 *     other punctuation one token a character; symbols ("$") are Other; whitespace
 *     runs end at a line break; English clitics are their own words ("do" "n't",
 *     "you" "'ll"); a short list of abbreviations keeps its period ("Dr.") and
 *     doesn't end the sentence.
 *   - Languages are CFStringTokenizer's guesses, by paragraph (or the orthography the
 *     app set); a token's script is its paragraph's language's script.
 *   - Lexical classes, name types and lemmas aren't available: those schemes give nil
 *     tags, and the available schemes don't list them.
 */
#import <Foundation/Foundation.h>
#import <CoreFoundation/CFStringTokenizer.h>

/* ---- NSOrthography ---- */

@implementation NSOrthography {
    NSString *_dominantScript;
    NSDictionary *_languageMap;
}

+ (BOOL)supportsSecureCoding { return YES; }

+ (instancetype)orthographyWithDominantScript:(NSString *)script languageMap:(NSDictionary *)map
{
    return [[[self alloc] initWithDominantScript:script languageMap:map] autorelease];
}

/* The script a language is written in (ISO 15924). */
static NSString *
script_for_language(NSString *lang)
{
    if (!lang)
        return nil;
    static NSDictionary *scripts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        scripts = [@{
            @"ja" : @"Jpan", @"ko" : @"Kore", @"zh-Hans" : @"Hani", @"zh-Hant" : @"Hani", @"zh" : @"Hani",
            @"ru" : @"Cyrl", @"uk" : @"Cyrl", @"sr" : @"Cyrl", @"bg" : @"Cyrl", @"be" : @"Cyrl", @"mk" : @"Cyrl", @"kk" : @"Cyrl",
            @"el" : @"Grek", @"he" : @"Hebr", @"ar" : @"Arab", @"fa" : @"Arab", @"ur" : @"Arab", @"th" : @"Thai",
            @"hi" : @"Deva", @"mr" : @"Deva", @"ne" : @"Deva", @"hy" : @"Armn", @"ka" : @"Geor", @"bn" : @"Beng",
            @"ta" : @"Taml", @"te" : @"Telu", @"kn" : @"Knda", @"ml" : @"Mlym", @"gu" : @"Gujr", @"pa" : @"Guru",
            @"km" : @"Khmr", @"lo" : @"Laoo", @"my" : @"Mymr", @"si" : @"Sinh", @"bo" : @"Tibt", @"am" : @"Ethi",
        } retain];
    });
    return scripts[lang] ?: scripts[[lang componentsSeparatedByString:@"-"][0]] ?: @"Latn";
}

+ (instancetype)defaultOrthographyForLanguage:(NSString *)language
{
    NSString *script = script_for_language(language);
    return [self orthographyWithDominantScript:script languageMap:@{script : @[ language ]}];
}

- (instancetype)initWithDominantScript:(NSString *)script languageMap:(NSDictionary *)map
{
    if ((self = [super init])) {
        _dominantScript = [script copy];
        _languageMap = [map copy];
    }
    return self;
}

- (void)dealloc
{
    [_dominantScript release];
    [_languageMap release];
    [super dealloc];
}

- (NSString *)dominantScript { return _dominantScript; }
- (NSDictionary *)languageMap { return _languageMap; }
- (NSArray *)languagesForScript:(NSString *)script { return _languageMap[script]; }
- (NSString *)dominantLanguageForScript:(NSString *)script { return [_languageMap[script] firstObject]; }
- (NSString *)dominantLanguage { return [self dominantLanguageForScript:_dominantScript]; }
- (NSArray *)allScripts { return _languageMap.allKeys; }

- (NSArray *)allLanguages
{
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *s in _languageMap)
        for (NSString *l in _languageMap[s])
            if (![a containsObject:l])
                [a addObject:l];
    return a;
}

- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

- (BOOL)isEqual:(id)o
{
    return [o isKindOfClass:[NSOrthography class]] && [_dominantScript isEqual:[o dominantScript]] && [_languageMap isEqual:[o languageMap]];
}

- (NSUInteger)hash { return _dominantScript.hash ^ _languageMap.hash; }

- (NSString *)description
{
    return [NSString stringWithFormat:@"%@ %@ %@", super.description, _dominantScript, _languageMap];
}

- (instancetype)initWithCoder:(NSCoder *)c
{
    NSSet *classes = [NSSet setWithObjects:[NSDictionary class], [NSArray class], [NSString class], nil];
    return [self initWithDominantScript:[c decodeObjectOfClass:[NSString class] forKey:@"NSDominantScript"]
                            languageMap:[c decodeObjectOfClasses:classes forKey:@"NSLanguageMap"]];
}

- (void)encodeWithCoder:(NSCoder *)c
{
    [c encodeObject:_dominantScript forKey:@"NSDominantScript"];
    [c encodeObject:_languageMap forKey:@"NSLanguageMap"];
}

@end

/* ---- NSLinguisticTagger ---- */

enum { T_WORD, T_PUNCTUATION, T_WHITESPACE, T_OTHER };

typedef struct {
    NSRange range, sentence, paragraph;
    int type;
} Token;

@implementation NSLinguisticTagger {
    /* (_schemes, _options and _string are the header's) */
    Token *_tokens;
    NSUInteger _count;
    NSRange *_sentences, *_paragraphs;
    NSUInteger _sentenceCount, _paragraphCount;
    NSMutableArray *_paragraphLanguages; /* NSNull when there's no telling */
    NSMutableArray *_orthographies;      /* @[range value, orthography] */
}

static NSString *
token_type_tag(int t)
{
    switch (t) {
    case T_WORD: return NSLinguisticTagWord;
    case T_PUNCTUATION: return NSLinguisticTagPunctuation;
    case T_WHITESPACE: return NSLinguisticTagWhitespace;
    default: return NSLinguisticTagOther;
    }
}

+ (NSArray *)availableTagSchemesForUnit:(NSLinguisticTaggerUnit)unit language:(NSString *)language
{
    if (unit == NSLinguisticTaggerUnitWord)
        return @[ NSLinguisticTagSchemeLanguage, NSLinguisticTagSchemeScript, NSLinguisticTagSchemeTokenType ];
    return @[ NSLinguisticTagSchemeLanguage, NSLinguisticTagSchemeScript ];
}

+ (NSArray *)availableTagSchemesForLanguage:(NSString *)language
{
    return [self availableTagSchemesForUnit:NSLinguisticTaggerUnitWord language:language];
}

- (instancetype)initWithTagSchemes:(NSArray *)schemes options:(NSUInteger)options
{
    if ((self = [super init])) {
        _schemes = [schemes copy];
        _options = options;
        _orthographies = [NSMutableArray new];
    }
    return self;
}

- (void)forget
{
    free(_tokens);
    free(_sentences);
    free(_paragraphs);
    _tokens = NULL;
    _sentences = _paragraphs = NULL;
    _count = _sentenceCount = _paragraphCount = 0;
    [_paragraphLanguages release];
    _paragraphLanguages = nil;
}

- (void)dealloc
{
    [self forget];
    [_schemes release];
    [_string release];
    [_orthographies release];
    [super dealloc];
}

- (NSArray *)tagSchemes { return _schemes; }
- (NSString *)string { return _string; }

- (void)setString:(NSString *)string
{
    [self forget];
    [_orthographies removeAllObjects];
    [_string autorelease];
    _string = [string copy];
}

- (void)stringEditedInRange:(NSRange)newRange changeInLength:(NSInteger)delta
{
    [self forget];
}

/* The ranges of a CFStringTokenizer unit over the whole string, with what lies between
   tokens joined to the one before (sentences and paragraphs cover the whole string). */
static NSRange *
cover(NSString *s, CFOptionFlags unit, NSUInteger *count)
{
    NSUInteger n = 0, cap = 8, len = s.length;
    NSRange *r = malloc(cap * sizeof *r);
    CFStringTokenizerRef t = CFStringTokenizerCreate(NULL, (CFStringRef)s, CFRangeMake(0, len), unit, NULL);
    NSUInteger at = 0;
    while (CFStringTokenizerAdvanceToNextToken(t) != kCFStringTokenizerTokenNone) {
        CFRange tr = CFStringTokenizerGetCurrentTokenRange(t);
        NSUInteger end = tr.location + tr.length;
        if (end <= at)
            continue;
        if (n == cap)
            r = realloc(r, (cap *= 2) * sizeof *r);
        r[n++] = NSMakeRange(at, end - at);
        at = end;
    }
    CFRelease(t);
    if (at < len) {
        if (n == 0)
            r[n++] = NSMakeRange(0, len);
        else
            r[n - 1].length = len - r[n - 1].location;
    }
    *count = n;
    return r;
}

static BOOL
is_abbreviation(NSString *w)
{
    static NSSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [[NSSet alloc] initWithObjects:@"dr", @"mr", @"mrs", @"ms", @"prof", @"st", @"jr", @"sr", @"vs", @"etc", @"mt",
                                             @"gen", @"col", @"capt", @"lt", @"sgt", @"rev", @"inc", @"ltd", @"co", @"corp",
                                             @"no", @"fig", @"approx", @"dept", @"est", nil];
    });
    return [set containsObject:w.lowercaseString];
}

static BOOL
is_terminal(unichar c)
{
    return c == '.' || c == '?' || c == '!' || c == 0x2026 || c == 0x3002 || c == 0xFF01 || c == 0xFF1F;
}

static BOOL
is_apostrophe(unichar c)
{
    return c == '\'' || c == 0x2019;
}

- (void)addToken:(NSRange)r type:(int)type cap:(NSUInteger *)cap
{
    if (_count == *cap)
        _tokens = realloc(_tokens, (*cap *= 2) * sizeof *_tokens);
    _tokens[_count++] = (Token){r, {0, 0}, {0, 0}, type};
}

/* A word, with an English clitic split off. */
- (void)addWord:(NSRange)r english:(BOOL)english cap:(NSUInteger *)cap
{
    if (english && r.length > 3) {
        NSString *w = [_string substringWithRange:r];
        NSString *lw = w.lowercaseString;
        NSUInteger split = NSNotFound;
        if ([lw hasSuffix:@"n't"] || [lw hasSuffix:@"n’t"])
            split = r.length - 3;
        else
            for (NSUInteger i = 1; i + 1 < r.length && split == NSNotFound; i++)
                if (is_apostrophe([lw characterAtIndex:i])) {
                    NSString *rest = [lw substringFromIndex:i + 1];
                    if ([@[ @"s", @"ll", @"ve", @"re", @"d", @"m" ] containsObject:rest])
                        split = i;
                    break;
                }
        if (split != NSNotFound && split > 0) {
            [self addToken:NSMakeRange(r.location, split) type:T_WORD cap:cap];
            [self addToken:NSMakeRange(r.location + split, r.length - split) type:T_WORD cap:cap];
            return;
        }
    }
    [self addToken:r type:T_WORD cap:cap];
}

- (void)tokenize
{
    if (_tokens || !_string)
        return;
    NSString *s = _string;
    NSUInteger len = s.length, cap = 32;
    _tokens = malloc(cap * sizeof *_tokens);
    NSCharacterSet *letters = [NSCharacterSet alphanumericCharacterSet];
    NSCharacterSet *spaces = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSCharacterSet *symbols = [NSCharacterSet symbolCharacterSet];
    NSCharacterSet *newlines = [NSCharacterSet newlineCharacterSet];

    _paragraphs = cover(s, kCFStringTokenizerUnitParagraph, &_paragraphCount);
    NSUInteger rawCount;
    NSRange *raw = cover(s, kCFStringTokenizerUnitSentence, &rawCount);

    /* Words and the like, within each paragraph so that languages can be told apart. */
    for (NSUInteger p = 0; p < _paragraphCount; p++) {
        NSString *lang = [self languageOfParagraph:p];
        BOOL english = [lang isEqualToString:@"en"];
        NSRange pr = _paragraphs[p];
        CFStringTokenizerRef t = CFStringTokenizerCreate(NULL, (CFStringRef)s, CFRangeMake(pr.location, pr.length),
                                                         kCFStringTokenizerUnitWordBoundary, NULL);
        while (CFStringTokenizerAdvanceToNextToken(t) != kCFStringTokenizerTokenNone) {
            CFRange cr = CFStringTokenizerGetCurrentTokenRange(t);
            NSRange r = NSMakeRange(cr.location, cr.length);
            unichar c = [s characterAtIndex:r.location];
            if ([letters characterIsMember:c]) {
                /* an abbreviation keeps its period */
                if (NSMaxRange(r) < len && [s characterAtIndex:NSMaxRange(r)] == '.' && is_abbreviation([s substringWithRange:r]))
                    r.length++;
                [self addWord:r english:english cap:&cap];
                if (r.length > (NSUInteger)cr.length)
                    CFStringTokenizerAdvanceToNextToken(t); /* the period */
            } else if ([spaces characterIsMember:c]) {
                /* a run of spaces ends after a line break */
                NSUInteger i = r.location, end = NSMaxRange(r);
                while (i < end) {
                    NSUInteger start = i;
                    while (i < end && ![newlines characterIsMember:[s characterAtIndex:i]])
                        i++;
                    if (i < end)
                        i++;
                    [self addToken:NSMakeRange(start, i - start) type:T_WHITESPACE cap:&cap];
                }
            } else if (is_terminal(c)) {
                /* a run of sentence-ending marks is one token */
                if (_count && _tokens[_count - 1].type == T_PUNCTUATION && NSMaxRange(_tokens[_count - 1].range) == r.location &&
                    is_terminal([s characterAtIndex:_tokens[_count - 1].range.location]))
                    _tokens[_count - 1].range.length += r.length;
                else
                    [self addToken:r type:T_PUNCTUATION cap:&cap];
            } else
                [self addToken:r type:[symbols characterIsMember:c] ? T_OTHER : T_PUNCTUATION cap:&cap];
        }
        CFRelease(t);
    }

    /* Sentences: ICU's, joined where one ends with an abbreviation's period. */
    _sentences = malloc((rawCount ?: 1) * sizeof *_sentences);
    for (NSUInteger i = 0; i < rawCount; i++) {
        BOOL join = NO;
        if (_sentenceCount) {
            NSRange prev = _sentences[_sentenceCount - 1];
            NSString *t = [[s substringWithRange:prev] stringByTrimmingCharactersInSet:spaces];
            if ([t hasSuffix:@"."]) {
                NSRange w = [t rangeOfCharacterFromSet:[letters invertedSet] options:NSBackwardsSearch
                                                 range:NSMakeRange(0, t.length - 1)];
                NSString *last = [t substringWithRange:NSMakeRange(w.location == NSNotFound ? 0 : NSMaxRange(w),
                                                                   t.length - 1 - (w.location == NSNotFound ? 0 : NSMaxRange(w)))];
                join = is_abbreviation(last);
            }
            /* sentences don't cross paragraphs */
            for (NSUInteger p = 0; join && p < _paragraphCount; p++)
                if (NSMaxRange(_paragraphs[p]) == raw[i].location)
                    join = NO;
        }
        if (join)
            _sentences[_sentenceCount - 1].length = NSMaxRange(raw[i]) - _sentences[_sentenceCount - 1].location;
        else
            _sentences[_sentenceCount++] = raw[i];
    }
    free(raw);

    for (NSUInteger i = 0, si = 0, pi = 0; i < _count; i++) {
        while (si + 1 < _sentenceCount && _tokens[i].range.location >= NSMaxRange(_sentences[si]))
            si++;
        while (pi + 1 < _paragraphCount && _tokens[i].range.location >= NSMaxRange(_paragraphs[pi]))
            pi++;
        _tokens[i].sentence = _sentenceCount ? _sentences[si] : NSMakeRange(0, len);
        _tokens[i].paragraph = _paragraphCount ? _paragraphs[pi] : NSMakeRange(0, len);
    }
}

static NSString *
guess_language(NSString *s, NSRange r)
{
    CFStringRef l = CFStringTokenizerCopyBestStringLanguage((CFStringRef)s, CFRangeMake(r.location, r.length));
    return [(NSString *)l autorelease];
}

- (NSOrthography *)orthographyCovering:(NSUInteger)index
{
    for (NSArray *o in _orthographies.reverseObjectEnumerator)
        if (NSLocationInRange(index, [o[0] rangeValue]))
            return o[1];
    return nil;
}

- (NSString *)languageOfParagraph:(NSUInteger)p
{
    if (!_paragraphLanguages) {
        _paragraphLanguages = [[NSMutableArray alloc] init];
        for (NSUInteger i = 0; i < _paragraphCount; i++)
            [_paragraphLanguages addObject:[NSNull null]];
    }
    id l = _paragraphLanguages[p];
    if (l == [NSNull null]) {
        NSOrthography *o = [self orthographyCovering:_paragraphs[p].location];
        l = o.dominantLanguage ?: guess_language(_string, _paragraphs[p]);
        _paragraphLanguages[p] = l ?: @"";
    }
    return [l length] ? l : nil;
}

- (NSUInteger)paragraphAt:(NSUInteger)index
{
    for (NSUInteger p = 0; p < _paragraphCount; p++)
        if (index < NSMaxRange(_paragraphs[p]))
            return p;
    return _paragraphCount ? _paragraphCount - 1 : NSNotFound;
}

- (NSString *)languageAt:(NSUInteger)index
{
    [self tokenize];
    NSUInteger p = [self paragraphAt:index];
    return p == NSNotFound ? nil : [self languageOfParagraph:p];
}

/* ---- tags ---- */

static BOOL
omitted(int type, NSUInteger options)
{
    return (type == T_WORD && (options & NSLinguisticTaggerOmitWords)) ||
           (type == T_PUNCTUATION && (options & NSLinguisticTaggerOmitPunctuation)) ||
           (type == T_WHITESPACE && (options & NSLinguisticTaggerOmitWhitespace)) ||
           (type == T_OTHER && (options & NSLinguisticTaggerOmitOther));
}

/* The tag of a range in a scheme, its token type given. */
- (NSString *)tagForRange:(NSRange)r type:(int)type scheme:(NSString *)scheme
{
    if ([scheme isEqualToString:NSLinguisticTagSchemeTokenType])
        return token_type_tag(type);
    if ([scheme isEqualToString:NSLinguisticTagSchemeLanguage])
        return type == T_WHITESPACE && r.length && [_string characterAtIndex:r.location] == '\n' ? nil : [self languageAt:r.location];
    if ([scheme isEqualToString:NSLinguisticTagSchemeScript]) {
        NSString *l = [self languageAt:r.location];
        return l ? script_for_language(l) : nil;
    }
    return nil;
}

/* The type of a sentence, paragraph or document: a word when it has any. */
- (int)typeOfRange:(NSRange)r
{
    [self tokenize];
    int type = -1;
    for (NSUInteger i = 0; i < _count; i++)
        if (NSLocationInRange(_tokens[i].range.location, r)) {
            if (_tokens[i].type == T_WORD)
                return T_WORD;
            if (type < 0 || _tokens[i].type == T_PUNCTUATION)
                type = _tokens[i].type;
        }
    return type < 0 ? T_WHITESPACE : type;
}

- (void)enumerateTagsInRange:(NSRange)range unit:(NSLinguisticTaggerUnit)unit scheme:(NSString *)scheme
                     options:(NSLinguisticTaggerOptions)options
                  usingBlock:(NS_NOESCAPE void (^)(NSString *, NSRange, BOOL *))block
{
    [self tokenize];
    BOOL stop = NO;
    if (unit == NSLinguisticTaggerUnitWord) {
        for (NSUInteger i = 0; i < _count && !stop; i++) {
            NSRange r = _tokens[i].range;
            if (NSMaxRange(r) <= range.location || r.location >= NSMaxRange(range) || omitted(_tokens[i].type, options))
                continue;
            block([self tagForRange:r type:_tokens[i].type scheme:scheme], r, &stop);
        }
        return;
    }
    NSRange whole = NSMakeRange(0, _string.length);
    NSRange *units = unit == NSLinguisticTaggerUnitSentence ? _sentences : unit == NSLinguisticTaggerUnitParagraph ? _paragraphs : &whole;
    NSUInteger n = unit == NSLinguisticTaggerUnitSentence ? _sentenceCount : unit == NSLinguisticTaggerUnitParagraph ? _paragraphCount : 1;
    for (NSUInteger i = 0; i < n && !stop; i++) {
        NSRange r = units[i];
        if (NSMaxRange(r) <= range.location || r.location >= NSMaxRange(range))
            continue;
        int type = [self typeOfRange:r];
        if (omitted(type, options))
            continue;
        NSString *tag;
        if ([scheme isEqualToString:NSLinguisticTagSchemeLanguage] || [scheme isEqualToString:NSLinguisticTagSchemeScript]) {
            NSOrthography *o = [self orthographyCovering:r.location];
            NSString *l = o.dominantLanguage ?: guess_language(_string, r);
            tag = [scheme isEqualToString:NSLinguisticTagSchemeLanguage] ? l : l ? script_for_language(l) : nil;
        } else
            tag = [self tagForRange:r type:type scheme:scheme];
        block(tag, r, &stop);
    }
}

- (NSString *)tagAtIndex:(NSUInteger)index unit:(NSLinguisticTaggerUnit)unit scheme:(NSString *)scheme tokenRange:(NSRangePointer)tokenRange
{
    __block NSString *tag = nil;
    __block NSRange found = NSMakeRange(NSNotFound, 0);
    [self enumerateTagsInRange:NSMakeRange(index, 1) unit:unit scheme:scheme options:0
                    usingBlock:^(NSString *t, NSRange r, BOOL *stop) {
                        if (NSLocationInRange(index, r)) {
                            tag = t;
                            found = r;
                            *stop = YES;
                        }
                    }];
    if (tokenRange)
        *tokenRange = found;
    return tag;
}

- (NSArray *)tagsInRange:(NSRange)range unit:(NSLinguisticTaggerUnit)unit scheme:(NSString *)scheme
                 options:(NSLinguisticTaggerOptions)options tokenRanges:(NSArray<NSValue *> **)tokenRanges
{
    NSMutableArray *tags = [NSMutableArray array], *ranges = [NSMutableArray array];
    [self enumerateTagsInRange:range unit:unit scheme:scheme options:options
                    usingBlock:^(NSString *t, NSRange r, BOOL *stop) {
                        [tags addObject:t ?: (id)@""];
                        [ranges addObject:[NSValue valueWithRange:r]];
                    }];
    if (tokenRanges)
        *tokenRanges = ranges;
    return tags;
}

- (void)enumerateTagsInRange:(NSRange)range scheme:(NSString *)scheme options:(NSLinguisticTaggerOptions)options
                  usingBlock:(NS_NOESCAPE void (^)(NSString *, NSRange, NSRange, BOOL *))block
{
    [self tokenize];
    BOOL stop = NO;
    for (NSUInteger i = 0; i < _count && !stop; i++) {
        NSRange r = _tokens[i].range;
        if (NSMaxRange(r) <= range.location || r.location >= NSMaxRange(range) || omitted(_tokens[i].type, options))
            continue;
        block([self tagForRange:r type:_tokens[i].type scheme:scheme], r, _tokens[i].sentence, &stop);
    }
}

- (NSString *)tagAtIndex:(NSUInteger)index scheme:(NSString *)scheme tokenRange:(NSRangePointer)tokenRange sentenceRange:(NSRangePointer)sentenceRange
{
    [self tokenize];
    for (NSUInteger i = 0; i < _count; i++)
        if (NSLocationInRange(index, _tokens[i].range)) {
            if (tokenRange)
                *tokenRange = _tokens[i].range;
            if (sentenceRange)
                *sentenceRange = _tokens[i].sentence;
            return [self tagForRange:_tokens[i].range type:_tokens[i].type scheme:scheme];
        }
    if (tokenRange)
        *tokenRange = NSMakeRange(NSNotFound, 0);
    if (sentenceRange)
        *sentenceRange = NSMakeRange(NSNotFound, 0);
    return nil;
}

- (NSArray *)tagsInRange:(NSRange)range scheme:(NSString *)scheme options:(NSLinguisticTaggerOptions)options tokenRanges:(NSArray<NSValue *> **)tokenRanges
{
    return [self tagsInRange:range unit:NSLinguisticTaggerUnitWord scheme:scheme options:options tokenRanges:tokenRanges];
}

- (NSArray *)possibleTagsAtIndex:(NSUInteger)index scheme:(NSString *)scheme tokenRange:(NSRangePointer)tokenRange
                   sentenceRange:(NSRangePointer)sentenceRange scores:(NSArray<NSValue *> **)scores
{
    NSString *tag = [self tagAtIndex:index scheme:scheme tokenRange:tokenRange sentenceRange:sentenceRange];
    if (scores)
        *scores = tag ? @[ @1.0 ] : @[];
    return tag ? @[ tag ] : @[];
}

- (NSRange)tokenRangeAtIndex:(NSUInteger)index unit:(NSLinguisticTaggerUnit)unit
{
    NSRange r = NSMakeRange(NSNotFound, 0);
    [self tagAtIndex:index unit:unit scheme:NSLinguisticTagSchemeTokenType tokenRange:&r];
    return r;
}

- (NSRange)sentenceRangeForRange:(NSRange)range
{
    [self tokenize];
    NSUInteger start = NSNotFound, end = 0;
    for (NSUInteger i = 0; i < _sentenceCount; i++)
        if (NSIntersectionRange(_sentences[i], range).length ||
            NSLocationInRange(range.location, _sentences[i])) {
            start = MIN(start, _sentences[i].location);
            end = MAX(end, NSMaxRange(_sentences[i]));
        }
    return start == NSNotFound ? NSMakeRange(NSNotFound, 0) : NSMakeRange(start, end - start);
}

- (void)setOrthography:(NSOrthography *)orthography range:(NSRange)range
{
    if (orthography)
        [_orthographies addObject:@[ [NSValue valueWithRange:range], orthography ]];
    [_paragraphLanguages release];
    _paragraphLanguages = nil;
}

- (NSOrthography *)orthographyAtIndex:(NSUInteger)index effectiveRange:(NSRangePointer)effectiveRange
{
    NSOrthography *o = [self orthographyCovering:index];
    if (o) {
        for (NSArray *e in _orthographies.reverseObjectEnumerator)
            if (e[1] == o && effectiveRange)
                *effectiveRange = [e[0] rangeValue];
        return o;
    }
    [self tokenize];
    NSUInteger p = [self paragraphAt:index];
    NSString *l = p == NSNotFound ? nil : [self languageOfParagraph:p];
    if (effectiveRange)
        *effectiveRange = p == NSNotFound ? NSMakeRange(NSNotFound, 0) : _paragraphs[p];
    return l ? [NSOrthography defaultOrthographyForLanguage:l] : nil;
}

/* (from the text, whatever orthography was set, as Apple's) */
- (NSString *)dominantLanguage
{
    return _string.length ? guess_language(_string, NSMakeRange(0, _string.length)) : nil;
}

/* ---- the one-shot class methods ---- */

+ (NSString *)dominantLanguageForString:(NSString *)string
{
    return string.length ? guess_language(string, NSMakeRange(0, string.length)) : nil;
}

static NSLinguisticTagger *
one_shot(NSString *string, NSString *scheme, NSOrthography *orthography)
{
    NSLinguisticTagger *t = [[[NSLinguisticTagger alloc] initWithTagSchemes:@[ scheme ] options:0] autorelease];
    t.string = string;
    if (orthography)
        [t setOrthography:orthography range:NSMakeRange(0, string.length)];
    return t;
}

+ (NSString *)tagForString:(NSString *)string atIndex:(NSUInteger)index unit:(NSLinguisticTaggerUnit)unit
                    scheme:(NSString *)scheme orthography:(NSOrthography *)orthography tokenRange:(NSRangePointer)tokenRange
{
    return [one_shot(string, scheme, orthography) tagAtIndex:index unit:unit scheme:scheme tokenRange:tokenRange];
}

+ (NSArray *)tagsForString:(NSString *)string range:(NSRange)range unit:(NSLinguisticTaggerUnit)unit scheme:(NSString *)scheme
                   options:(NSLinguisticTaggerOptions)options orthography:(NSOrthography *)orthography
               tokenRanges:(NSArray<NSValue *> **)tokenRanges
{
    return [one_shot(string, scheme, orthography) tagsInRange:range unit:unit scheme:scheme options:options tokenRanges:tokenRanges];
}

+ (void)enumerateTagsForString:(NSString *)string range:(NSRange)range unit:(NSLinguisticTaggerUnit)unit scheme:(NSString *)scheme
                       options:(NSLinguisticTaggerOptions)options orthography:(NSOrthography *)orthography
                    usingBlock:(NS_NOESCAPE void (^)(NSString *, NSRange, BOOL *))block
{
    [one_shot(string, scheme, orthography) enumerateTagsInRange:range unit:unit scheme:scheme options:options usingBlock:block];
}

@end

@implementation NSString (NSLinguisticAnalysis)

- (NSArray *)linguisticTagsInRange:(NSRange)range scheme:(NSString *)scheme options:(NSLinguisticTaggerOptions)options
                       orthography:(NSOrthography *)orthography tokenRanges:(NSArray<NSValue *> **)tokenRanges
{
    return [one_shot(self, scheme, orthography) tagsInRange:range scheme:scheme options:options tokenRanges:tokenRanges];
}

- (void)enumerateLinguisticTagsInRange:(NSRange)range scheme:(NSString *)scheme options:(NSLinguisticTaggerOptions)options
                           orthography:(NSOrthography *)orthography
                            usingBlock:(NS_NOESCAPE void (^)(NSString *, NSRange, NSRange, BOOL *))block
{
    [one_shot(self, scheme, orthography) enumerateTagsInRange:range scheme:scheme options:options usingBlock:block];
}

@end
