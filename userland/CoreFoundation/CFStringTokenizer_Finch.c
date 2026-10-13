/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * CFStringTokenizer: words, sentences, paragraphs and line breaks of a string
 * (public API, <CoreFoundation/CFStringTokenizer.h>). swift-corelibs has no
 * implementation, so this is Finch's, over ICU's break iterators:
 *
 *   - Words skip what ICU says isn't a word (spaces, punctuation); word
 *     boundaries give every segment.
 *   - Paragraphs end at paragraph separators (newlines, U+2029); their ranges
 *     include the separator, as sentences' do.
 *   - A token's type says whether it has numbers, non-letters, or is CJK.
 *
 * Latin transcriptions and sub-tokens aren't provided: CopyCurrentTokenAttribute
 * returns NULL and GetCurrentSubTokens 0. CopyBestStringLanguage guesses from the
 * script, and for Latin text from each language's common words and letters.
 */

#include "CFInternal.h"
#include "CFRuntime_Internal.h"

#include <_foundation_unicode/ubrk.h>
#include <dispatch/dispatch.h>

/* <CoreFoundation/CFStringTokenizer.h>'s public declarations; swift-corelibs has no copy of it. */
typedef struct __CFStringTokenizer *CFStringTokenizerRef;
enum {
    kCFStringTokenizerUnitWord = 0,
    kCFStringTokenizerUnitSentence = 1,
    kCFStringTokenizerUnitParagraph = 2,
    kCFStringTokenizerUnitLineBreak = 3,
    kCFStringTokenizerUnitWordBoundary = 4,
    kCFStringTokenizerAttributeLatinTranscription = 1UL << 16,
    kCFStringTokenizerAttributeLanguage = 1UL << 17,
};
typedef CFOptionFlags CFStringTokenizerTokenType;
enum {
    kCFStringTokenizerTokenNone = 0,
    kCFStringTokenizerTokenNormal = 1UL << 0,
    kCFStringTokenizerTokenHasSubTokensMask = 1UL << 1,
    kCFStringTokenizerTokenHasDerivedSubTokensMask = 1UL << 2,
    kCFStringTokenizerTokenHasHasNumbersMask = 1UL << 3,
    kCFStringTokenizerTokenHasNonLettersMask = 1UL << 4,
    kCFStringTokenizerTokenIsCJWordMask = 1UL << 5,
};
#include <stdlib.h>
#include <string.h>

struct __CFStringTokenizer {
    CFRuntimeBase base;
    CFStringRef string;
    CFRange range;
    CFOptionFlags options;
    CFLocaleRef locale;
    UniChar *chars;           /* the range's characters */
    UBreakIterator *iterator; /* NULL for paragraphs */
    CFRange token;            /* the current token, kCFNotFound for none */
};

static void
tokenizer_finalize(CFTypeRef cf)
{
    struct __CFStringTokenizer *t = (struct __CFStringTokenizer *)cf;
    if (t->iterator)
        ubrk_close(t->iterator);
    free(t->chars);
    if (t->string)
        CFRelease(t->string);
    if (t->locale)
        CFRelease(t->locale);
}

static const CFRuntimeClass tokenizer_class = {
    0, "CFStringTokenizer", NULL, NULL, tokenizer_finalize, NULL, NULL, NULL, NULL, NULL, NULL, 0,
};

CFTypeID
CFStringTokenizerGetTypeID(void)
{
    static CFTypeID type = _kCFRuntimeNotATypeID;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ type = _CFRuntimeRegisterClass(&tokenizer_class); });
    return type;
}

static CFIndex
unit(CFOptionFlags options)
{
    return (CFIndex)(options & 0xff);
}

static void
set_string(struct __CFStringTokenizer *t, CFStringRef string, CFRange range)
{
    if (t->iterator)
        ubrk_close(t->iterator);
    t->iterator = NULL;
    free(t->chars);
    t->chars = NULL;
    if (t->string)
        CFRelease(t->string);
    t->string = string ? CFStringCreateCopy(kCFAllocatorSystemDefault, string) : CFSTR("");
    CFIndex len = CFStringGetLength(t->string);
    if (range.location < 0 || range.location > len)
        range = CFRangeMake(0, 0);
    if (range.location + range.length > len)
        range.length = len - range.location;
    t->range = range;
    t->token = CFRangeMake(kCFNotFound, 0);
    t->chars = malloc((size_t)(range.length ? range.length : 1) * sizeof(UniChar));
    CFStringGetCharacters(t->string, range, t->chars);
    if (unit(t->options) == kCFStringTokenizerUnitParagraph)
        return;
    UBreakIteratorType kind = unit(t->options) == kCFStringTokenizerUnitSentence    ? UBRK_SENTENCE
                              : unit(t->options) == kCFStringTokenizerUnitLineBreak ? UBRK_LINE
                                                                                    : UBRK_WORD;
    char locale[64] = "";
    if (t->locale)
        CFStringGetCString(CFLocaleGetIdentifier(t->locale), locale, sizeof locale, kCFStringEncodingASCII);
    UErrorCode status = U_ZERO_ERROR;
    t->iterator = ubrk_open(kind, locale, (const UChar *)t->chars, (int32_t)range.length, &status);
    if (U_FAILURE(status))
        t->iterator = NULL;
}

CFStringTokenizerRef
CFStringTokenizerCreate(CFAllocatorRef alloc, CFStringRef string, CFRange range, CFOptionFlags options,
                        CFLocaleRef locale)
{
    struct __CFStringTokenizer *t = (struct __CFStringTokenizer *)_CFRuntimeCreateInstance(
        alloc, CFStringTokenizerGetTypeID(), sizeof(struct __CFStringTokenizer) - sizeof(CFRuntimeBase), NULL);
    if (!t)
        return NULL;
    t->options = options;
    t->locale = locale ? (CFLocaleRef)CFRetain(locale) : NULL;
    set_string(t, string, range);
    return t;
}

void
CFStringTokenizerSetString(CFStringTokenizerRef tokenizer, CFStringRef string, CFRange range)
{
    set_string((struct __CFStringTokenizer *)tokenizer, string, range);
}

static Boolean
is_paragraph_break(UniChar c)
{
    return c == '\n' || c == '\r' || c == 0x2029 || c == 0x85;
}

/*
 * The token type, as Apple's: only words and word boundaries carry flags. A token with digits
 * has numbers (and, as Apple's says, sub-tokens); one with neither letters nor digits is
 * non-letters; Chinese and Japanese ones are CJ words.
 */
static CFStringTokenizerTokenType
token_type(struct __CFStringTokenizer *t)
{
    CFStringTokenizerTokenType type = kCFStringTokenizerTokenNormal;
    CFIndex u = unit(t->options);
    if (u != kCFStringTokenizerUnitWord && u != kCFStringTokenizerUnitWordBoundary)
        return type;
    CFCharacterSetRef letters = CFCharacterSetGetPredefined(kCFCharacterSetLetter);
    Boolean digits = false, letter = false, cj = false;
    CFIndex start = t->token.location - t->range.location;
    for (CFIndex i = start; i < start + t->token.length; i++) {
        UniChar c = t->chars[i];
        if (c >= '0' && c <= '9')
            digits = true;
        else if (CFCharacterSetIsCharacterMember(letters, c))
            letter = true;
        if ((c >= 0x3040 && c <= 0x30ff) || (c >= 0x4e00 && c <= 0x9fff) || (c >= 0x3400 && c <= 0x4dbf))
            cj = true;
    }
    if (digits)
        type |= kCFStringTokenizerTokenHasHasNumbersMask | kCFStringTokenizerTokenHasSubTokensMask;
    if (!digits && !letter)
        type |= kCFStringTokenizerTokenHasNonLettersMask;
    if (cj)
        type |= kCFStringTokenizerTokenIsCJWordMask;
    return type;
}

/* Move to the token that starts at or after `from` (relative to the range); NO when there's none. */
static Boolean
find_from(struct __CFStringTokenizer *t, CFIndex from)
{
    CFIndex len = t->range.length;
    if (unit(t->options) == kCFStringTokenizerUnitParagraph) {
        if (from >= len)
            return false;
        CFIndex end = from;
        while (end < len && !is_paragraph_break(t->chars[end]))
            end++;
        if (end < len)
            end += (t->chars[end] == '\r' && end + 1 < len && t->chars[end + 1] == '\n') ? 2 : 1;
        t->token = CFRangeMake(t->range.location + from, end - from);
        return true;
    }
    if (!t->iterator)
        return false;
    int32_t start = from <= 0 ? ubrk_first(t->iterator) : ubrk_preceding(t->iterator, (int32_t)from + 1);
    if (start == UBRK_DONE)
        start = 0;
    if (start < from)
        start = ubrk_following(t->iterator, (int32_t)from - 1) == (int32_t)from ? (int32_t)from : start;
    ubrk_isBoundary(t->iterator, start);
    while (start != UBRK_DONE && start < len) {
        int32_t end = ubrk_next(t->iterator);
        if (end == UBRK_DONE)
            break;
        Boolean wordsOnly = unit(t->options) == kCFStringTokenizerUnitWord;
        if (!wordsOnly || ubrk_getRuleStatus(t->iterator) != UBRK_WORD_NONE) {
            if (start >= from || unit(t->options) != kCFStringTokenizerUnitWord) {
                t->token = CFRangeMake(t->range.location + start, end - start);
                return true;
            }
        }
        start = end;
    }
    return false;
}

CFStringTokenizerTokenType
CFStringTokenizerAdvanceToNextToken(CFStringTokenizerRef tokenizer)
{
    struct __CFStringTokenizer *t = (struct __CFStringTokenizer *)tokenizer;
    CFIndex from = t->token.location == kCFNotFound ? 0 : t->token.location - t->range.location + t->token.length;
    if (!find_from(t, from)) {
        t->token = CFRangeMake(kCFNotFound, 0);
        return kCFStringTokenizerTokenNone;
    }
    return token_type(t);
}

CFStringTokenizerTokenType
CFStringTokenizerGoToTokenAtIndex(CFStringTokenizerRef tokenizer, CFIndex index)
{
    struct __CFStringTokenizer *t = (struct __CFStringTokenizer *)tokenizer;
    CFIndex rel = index - t->range.location;
    t->token = CFRangeMake(kCFNotFound, 0);
    if (rel < 0 || rel >= t->range.length)
        return kCFStringTokenizerTokenNone;
    /* the token containing the index: scan from the start (tokens are short) */
    CFIndex from = 0;
    while (find_from(t, from)) {
        CFIndex s = t->token.location - t->range.location, e = s + t->token.length;
        if (rel >= s && rel < e)
            return token_type(t);
        if (s > rel || e <= from)
            break;
        from = e;
    }
    t->token = CFRangeMake(kCFNotFound, 0);
    return kCFStringTokenizerTokenNone;
}

CFRange
CFStringTokenizerGetCurrentTokenRange(CFStringTokenizerRef tokenizer)
{
    return ((struct __CFStringTokenizer *)tokenizer)->token;
}

CFTypeRef
CFStringTokenizerCopyCurrentTokenAttribute(CFStringTokenizerRef tokenizer, CFOptionFlags attribute)
{
    struct __CFStringTokenizer *t = (struct __CFStringTokenizer *)tokenizer;
    if (t->token.location == kCFNotFound)
        return NULL;
    if (attribute == kCFStringTokenizerAttributeLanguage && t->locale)
        return CFRetain(CFLocaleGetIdentifier(t->locale));
    return NULL;
}

CFIndex
CFStringTokenizerGetCurrentSubTokens(CFStringTokenizerRef tokenizer, CFRange *ranges, CFIndex maxRangeLength,
                                     CFMutableArrayRef derivedSubTokens)
{
    return 0;
}

/* Language guessing: Finch's own, by script and, for Latin text, by the common short words
   of each language and the letters only some languages use. */

enum { S_LATIN, S_CYRILLIC, S_GREEK, S_HEBREW, S_ARABIC, S_HANGUL, S_KANA, S_HAN, S_THAI, S_DEVANAGARI,
       S_ARMENIAN, S_GEORGIAN, S_BENGALI, S_TAMIL, S_COUNT };

static int
script_of(UniChar c)
{
    if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= 0xC0 && c <= 0x24F && c != 0xD7 && c != 0xF7) ||
        (c >= 0x1E00 && c <= 0x1EFF))
        return S_LATIN;
    if (c >= 0x400 && c <= 0x52F)
        return S_CYRILLIC;
    if ((c >= 0x370 && c <= 0x3FF) || (c >= 0x1F00 && c <= 0x1FFF))
        return S_GREEK;
    if (c >= 0x530 && c <= 0x58F)
        return S_ARMENIAN;
    if (c >= 0x590 && c <= 0x5FF)
        return S_HEBREW;
    if ((c >= 0x600 && c <= 0x6FF) || (c >= 0x750 && c <= 0x77F) || (c >= 0xFB50 && c <= 0xFEFF))
        return S_ARABIC;
    if (c >= 0x900 && c <= 0x97F)
        return S_DEVANAGARI;
    if (c >= 0x980 && c <= 0x9FF)
        return S_BENGALI;
    if (c >= 0xB80 && c <= 0xBFF)
        return S_TAMIL;
    if (c >= 0xE00 && c <= 0xE7F)
        return S_THAI;
    if (c >= 0x10A0 && c <= 0x10FF)
        return S_GEORGIAN;
    if ((c >= 0x1100 && c <= 0x11FF) || (c >= 0x3130 && c <= 0x318F) || (c >= 0xAC00 && c <= 0xD7AF))
        return S_HANGUL;
    if (c >= 0x3040 && c <= 0x30FF)
        return S_KANA;
    if ((c >= 0x4E00 && c <= 0x9FFF) || (c >= 0x3400 && c <= 0x4DBF) || (c >= 0xF900 && c <= 0xFAFF))
        return S_HAN;
    return -1;
}

static int
has_any(const UniChar *s, CFIndex n, const char *utf8)
{
    CFStringRef set = CFStringCreateWithCString(kCFAllocatorSystemDefault, utf8, kCFStringEncodingUTF8);
    CFIndex m = CFStringGetLength(set);
    int found = 0;
    for (CFIndex i = 0; i < n && !found; i++)
        for (CFIndex j = 0; j < m; j++)
            if (s[i] == CFStringGetCharacterAtIndex(set, j)) {
                found = 1;
                break;
            }
    CFRelease(set);
    return found;
}

/* Latin-script languages: their commonest short words, and letters that point to them. */
static const struct latin_language {
    const char *code, *words, *letters;
} latin[] = {
    {"en", " the and of to is in it that you was for are with this have not be on at but they what all we can "
           "my your how hello today yes no or from by an as do if so up out there one "
           "about will would ", ""},
    {"fr", " le la les de des du et est un une que qui pas dans pour sur au aux ce il elle nous vous je tu "
           "bonjour avec mais tout comment ", "àâæçèêëîïôœùûÿ"},
    {"de", " der die das und ist nicht ein eine ich du sie er es wir mit von zu den dem auf für wie auch "
           "guten heute ihnen ", "äöüß"},
    {"es", " el la los las de del y que es en un una por para con no se lo como pero estoy hola muy está "
           "estás ", "ñ¿¡áéíóú"},
    {"it", " il lo la gli le di che è e un una per non con sono come ciao oggi della anche questo stai ",
           "àèéìòù"},
    {"pt", " o a os as de do da dos das e que não um uma para com por como você está olá hoje em ",
           "ãõçáâêéíóú"},
    {"nl", " de het een en van is dat niet ik je hoe met op te zijn wat voor hallo gaat vandaag ", ""},
    {"sv", " och att det som en är på för med jag inte har till av ett hej hur ", "åäö"},
    {"da", " og at det som en er på for med jeg ikke har til af et hej hvordan ", "æøå"},
    {"nb", " og at det som en er på for med jeg ikke har til av et hei hvordan ", "æøå"},
    {"fi", " ja on ei se että hän mitä kuin minä sinä tämä mutta hei miten ", "äö"},
    {"pl", " i w nie na to że się jest z do jak co ale czy tak ", "ąćęłńóśźż"},
    {"cs", " a je to že se na v ne jak co ale jsem ", "čďěňřšťůž"},
    {"tr", " ve bir bu da de ne için ile çok ama nasıl merhaba ", "çğıöşü"},
    {"ro", " și în de la nu că un o este pe cu ce ", "ăâîșțşţ"},
    {"hu", " a az és hogy nem egy is van meg de ", "áéíóöőúüű"},
    {"vi", " và là của có không một những người được trong ", "ăâđêôơưạảấầẩẫậắằẳẵặẹẻẽếềểễệỉịọỏốồổỗộớờởỡợụủứừửữựỳỵỷỹ"},
    {"id", " dan yang di ini itu dengan tidak untuk dari ada saya apa ", ""},
};

static CFStringRef
latin_language(const UniChar *s, CFIndex n)
{
    enum { N = sizeof latin / sizeof latin[0] };
    double score[N] = {0};
    CFIndex i = 0;
    while (i < n) {
        while (i < n && script_of(s[i]) != S_LATIN)
            i++;
        CFIndex start = i;
        while (i < n && script_of(s[i]) == S_LATIN)
            i++;
        if (i == start)
            break;
        /* parts of addresses (a@b.com) aren't words of any language */
        if ((start > 0 && (s[start - 1] == '.' || s[start - 1] == '@')) || (i < n && s[i] == '@'))
            continue;
        /* " word " in UTF-8, lowercased */
        CFStringRef w = CFStringCreateWithCharacters(kCFAllocatorSystemDefault, s + start, i - start);
        CFMutableStringRef lw = CFStringCreateMutableCopy(kCFAllocatorSystemDefault, 0, w);
        CFStringLowercase(lw, NULL);
        char buf[64] = " ";
        if (CFStringGetCString(lw, buf + 1, sizeof buf - 2, kCFStringEncodingUTF8)) {
            strcat(buf, " ");
            for (int k = 0; k < N; k++)
                if (strstr(latin[k].words, buf))
                    score[k] += i - start == 1 ? 0.25 : 1; /* "a", "e", "i" say little */
        }
        CFRelease(lw);
        CFRelease(w);
    }
    for (int k = 0; k < N; k++) {
        if (!latin[k].letters[0])
            continue;
        CFStringRef set = CFStringCreateWithCString(kCFAllocatorSystemDefault, latin[k].letters, kCFStringEncodingUTF8);
        CFIndex m = CFStringGetLength(set);
        for (CFIndex j = 0; j < n; j++) {
            UniChar c = s[j] >= 'A' && s[j] <= 'Z' ? s[j] + 32 : (s[j] >= 0xC0 && s[j] <= 0xDE && s[j] != 0xD7) ? s[j] + 32 : s[j];
            for (CFIndex x = 0; x < m; x++)
                if (c == CFStringGetCharacterAtIndex(set, x))
                    score[k] += 0.5;
        }
        CFRelease(set);
    }
    int best = 0;
    for (int k = 1; k < N; k++)
        if (score[k] > score[best])
            best = k;
    return CFStringCreateWithCString(kCFAllocatorSystemDefault, latin[best].code, kCFStringEncodingUTF8);
}

CFStringRef
CFStringTokenizerCopyBestStringLanguage(CFStringRef string, CFRange range)
{
    if (!string || range.length <= 0)
        return NULL;
    UniChar *s = malloc(range.length * sizeof(UniChar));
    CFStringGetCharacters(string, range, s);
    CFIndex count[S_COUNT] = {0}, letters = 0;
    for (CFIndex i = 0; i < range.length; i++) {
        int sc = script_of(s[i]);
        if (sc >= 0) {
            count[sc]++;
            letters++;
        }
    }
    const char *lang = NULL;
    CFStringRef result = NULL;
    if (letters >= 2) {
        int top = 0;
        for (int k = 1; k < S_COUNT; k++)
            if (count[k] > count[top])
                top = k;
        if (count[S_KANA] && (top == S_HAN || top == S_KANA))
            top = S_KANA;
        switch (top) {
        case S_LATIN:
            result = latin_language(s, range.length);
            break;
        case S_CYRILLIC:
            lang = has_any(s, range.length, "іїєґІЇЄҐ") ? "uk" : has_any(s, range.length, "ђћџљњјЂЋЏЉЊЈ") ? "sr" : "ru";
            break;
        case S_GREEK: lang = "el"; break;
        case S_HEBREW: lang = "he"; break;
        case S_ARABIC:
            lang = has_any(s, range.length, "ٹڈڑںے") ? "ur" : has_any(s, range.length, "پچژگ") ? "fa" : "ar";
            break;
        case S_HANGUL: lang = "ko"; break;
        case S_KANA: lang = "ja"; break;
        case S_HAN:
            /* Characters written one way in traditional Chinese and another in simplified. */
            lang = has_any(s, range.length, "們這來個為說對時會國學語經過還開關體電話問題東車長門見") ? "zh-Hant" : "zh-Hans";
            break;
        case S_THAI: lang = "th"; break;
        case S_DEVANAGARI: lang = "hi"; break;
        case S_ARMENIAN: lang = "hy"; break;
        case S_GEORGIAN: lang = "ka"; break;
        case S_BENGALI: lang = "bn"; break;
        case S_TAMIL: lang = "ta"; break;
        }
    }
    free(s);
    if (lang)
        result = CFStringCreateWithCString(kCFAllocatorSystemDefault, lang, kCFStringEncodingUTF8);
    return result;
}
