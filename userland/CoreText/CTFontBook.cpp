// SPDX-License-Identifier: MIT OR Apache-2.0
/*
 * CoreText's private calls a font manager (Font Book) uses, Finch's: sample text for a
 * language or a font, names by ID in preferred languages, a glyph's characters, visibility,
 * matching with options, comparing descriptors, validation (every font passes: Finch has no
 * font validator yet), downloadable fonts (none), lines from strings, and runs' fonts.
 * Signatures as Font Book calls them.
 */
#include "CTInternal.h"
#include <CoreText/CoreText.h>
#include <string.h>

extern "C" {

extern const CFStringRef kCTFontAssetFontInfoKey = CFSTR("FontInfo4");
extern const CFStringRef kCTFontAssetType = CFSTR("com.apple.MobileAsset.Font8");
extern const CFStringRef kCTFontCollectionIncludeStubFontsOption = CFSTR("NSCTFontCollectionIncludeStubFontsOption");
extern const CFStringRef kCTFontDesignLanguagesAttribute = CFSTR("NSCTFontDesignLanguagesAttribute");
extern const CFStringRef kCTFontManagerAvailableFontURLsAddedKey = CFSTR("CTFontManagerAvailableFontURLsAdded");
extern const CFStringRef kCTFontManagerAvailableFontURLsRemovedKey = CFSTR("CTFontManagerAvailableFontURLsRemoved");
extern const CFStringRef kCTFontValidationOptionRunDynamic = CFSTR("dynamic");
extern const CFStringRef kCTFontValidationResults = CFSTR("results");
extern const CGFloat kCTFontWidthExtraCompressed = -0.4;

/* A sentence for a language, as the font panels show. */
static const struct {
    const char *language;
    const char *sample;
} samples[] = {
    {"en", "The quick brown fox jumps over the lazy dog."},
    {"fr", "Portez ce vieux whisky au juge blond qui fume."},
    {"de", "Victor jagt zwölf Boxkämpfer quer über den großen Sylter Deich."},
    {"es", "El veloz murciélago hindú comía feliz cardillo y kiwi."},
    {"it", "Quel vituperabile xenofobo zelante assaggia il whisky ed esclama: alleluja!"},
    {"pt", "Luís argüia à Júlia que «brações, fé, chá, óxido, pôr, zângão» eram palavras do português."},
    {"nl", "Pa's wijze lynx bezag vroom het fikse aquaduct."},
    {"sv", "Flygande bäckasiner söka hwila på mjuka tuvor."},
    {"pl", "Pchnąć w tę łódź jeża lub ośm skrzyń fig."},
    {"ru", "Съешь же ещё этих мягких французских булок, да выпей чаю."},
    {"el", "Ταχίστη αλώπηξ βαφής ψημένη γη, δρασκελίζει υπέρ νωθρού κυνός."},
    {"he", "דג סקרן שט בים מאוכזב ולפתע מצא חברה."},
    {"ar", "نص حكيم له سر قاطع وذو شأن عظيم مكتوب على ثوب أخضر ومغلف بجلد أزرق."},
    {"ja", "いろはにほへと ちりぬるを わかよたれそ つねならむ"},
    {"zh", "我能吞下玻璃而不伤身体。"},
    {"ko", "다람쥐 헌 쳇바퀴에 타고파."},
    {"th", "เป็นมนุษย์สุดประเสริฐเลิศคุณค่า"},
    {"hi", "ऋषियों को सताने वाले दुष्ट राक्षसों के राजा रावण का सर्वनाश करने वाले विष्णुवतार भगवान श्रीराम।"},
};

static CFStringRef
sample_for(CFStringRef language)
{
    char lang[16] = "en";
    if (language)
        CFStringGetCString(language, lang, sizeof lang, kCFStringEncodingUTF8);
    for (char *p = lang; *p; p++)
        if (*p == '-' || *p == '_') {
            *p = 0;
            break;
        }
    for (const auto &s : samples)
        if (!strcmp(s.language, lang))
            return CFStringCreateWithCString(NULL, s.sample, kCFStringEncodingUTF8);
    return NULL;
}

/* (language, whether to fall back) */
CFStringRef
CTCopySampleStringForLanguage(CFStringRef language, bool fallBack)
{
    CFStringRef s = sample_for(language);
    if (!s && fallBack)
        s = sample_for(CFSTR("en"));
    return s ? s : CFSTR("");
}

/* The font's own sample text (name 19), else a sample in the first of the languages it
   supports (or the preferred ones). */
CFStringRef
CTFontCopySampleStringWithLanguages(CTFontRef font, bool fallBack, CFArrayRef languages, CFStringRef *usedLanguage)
{
    if (usedLanguage)
        *usedLanguage = NULL;
    CFStringRef own = font ? CTFontNameString(font, 19) : NULL;
    if (own)
        return own;
    CFArrayRef supported = font ? CTFontCopySupportedLanguages(font) : NULL;
    CFArrayRef order[] = {languages, supported};
    for (CFArrayRef list : order) {
        if (!list)
            continue;
        for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
            CFStringRef lang = (CFStringRef)CFArrayGetValueAtIndex(list, i);
            CFStringRef s = sample_for(lang);
            if (s) {
                if (usedLanguage)
                    *usedLanguage = (CFStringRef)CFRetain(lang);
                if (supported)
                    CFRelease(supported);
                return s;
            }
        }
    }
    if (supported)
        CFRelease(supported);
    return fallBack ? CTCopySampleStringForLanguage(CFSTR("en"), true) : NULL;
}

/* A few letters to show the font with: the first letters of its sample. */
CFStringRef
CTFontCopySampleLettersWithLanguages(CTFontRef font, bool fallBack, CFArrayRef languages, CFStringRef *usedLanguage)
{
    CFStringRef s = CTFontCopySampleStringWithLanguages(font, true, languages, usedLanguage);
    if (!s)
        return CFSTR("Aa");
    CFStringRef latin = CFSTR("The quick brown fox jumps over the lazy dog.");
    if (CFEqual(s, latin)) {
        CFRelease(s);
        return CFSTR("Aa");
    }
    CFIndex n = CFStringGetLength(s);
    CFStringRef letters = CFStringCreateWithSubstring(NULL, s, CFRangeMake(0, n < 2 ? n : 2));
    CFRelease(s);
    return letters;
}

/* A name record in the first of the languages the font has it in (Finch reads each name's
   preferred record). */
CFStringRef
CTFontCopyLocalizedNameByIDWithLanguages(CTFontRef font, CFIndex nameID, CFArrayRef languages, CFStringRef *usedLanguage)
{
    if (usedLanguage)
        *usedLanguage = NULL;
    if (!font || nameID < 0 || nameID > 0xffff)
        return NULL;
    return CTFontNameString(font, (uint16_t)nameID);
}

/* The characters a glyph draws: the first character the font maps to it. */
CFStringRef
CTFontCopyStringForGlyph(CTFontRef font, CGGlyph glyph)
{
    if (!font)
        return CFSTR("");
    CFCharacterSetRef set = CTFontCopyCharacterSet(font);
    if (!set)
        return CFSTR("");
    for (UTF32Char c = 0x20; c < 0x30000; c++) {
        if (!CFCharacterSetIsLongCharacterMember(set, c))
            continue;
        UniChar u[2];
        CFIndex n = 1;
        if (c > 0xffff) {
            u[0] = (UniChar)(0xd800 + ((c - 0x10000) >> 10));
            u[1] = (UniChar)(0xdc00 + ((c - 0x10000) & 0x3ff));
            n = 2;
        } else
            u[0] = (UniChar)c;
        CGGlyph g[2] = {0, 0};
        if (CTFontGetGlyphsForCharacters(font, u, g, n) && g[0] == glyph) {
            CFRelease(set);
            return CFStringCreateWithCharacters(NULL, u, n);
        }
    }
    CFRelease(set);
    return CFSTR("");
}

/* Fonts are visible unless their names say they're the system's own (".SF…"). */
bool
CTFontDescriptorIsVisible(CTFontDescriptorRef d)
{
    if (!d)
        return false;
    CFStringRef name = (CFStringRef)CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute);
    bool visible = !name || CFStringGetLength(name) == 0 || CFStringGetCharacterAtIndex(name, 0) != '.';
    if (name)
        CFRelease(name);
    return visible;
}

/* A name of the descriptor's font (kCTFontFamilyNameKey and the like). */
CFStringRef
CTFontDescriptorCopyName(CTFontDescriptorRef d, CFStringRef nameKey)
{
    if (!d || !nameKey)
        return NULL;
    CTFontRef f = CTFontCreateWithFontDescriptor(d, 0, NULL);
    if (!f)
        return NULL;
    CFStringRef s = CTFontCopyName(f, nameKey);
    CFRelease(f);
    return s;
}

CFArrayRef
CTFontDescriptorCreateMatchingFontDescriptorsWithOptions(CTFontDescriptorRef d, CFSetRef mandatoryAttributes, CFIndex options)
{
    return CTFontDescriptorCreateMatchingFontDescriptors(d, mandatoryAttributes);
}

/* No fonts can be downloaded on Finch yet. */
CFArrayRef
CTFontDescriptorCopyDownloadableFontAttributesForRequests(CFArrayRef requests)
{
    return CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
}

/* Order descriptors by family, then style (their display names). */
CFComparisonResult
CTFontManagerCompareFontDescriptors2(CTFontDescriptorRef a, CTFontDescriptorRef b, void *context)
{
    CFStringRef keys[] = {kCTFontFamilyNameAttribute, kCTFontStyleNameAttribute, kCTFontNameAttribute};
    for (CFStringRef k : keys) {
        CFStringRef x = a ? (CFStringRef)CTFontDescriptorCopyAttribute(a, k) : NULL;
        CFStringRef y = b ? (CFStringRef)CTFontDescriptorCopyAttribute(b, k) : NULL;
        CFComparisonResult r = x && y ? CFStringCompare(x, y, kCFCompareCaseInsensitive | kCFCompareLocalized)
                               : x    ? kCFCompareGreaterThan
                               : y    ? kCFCompareLessThan
                                      : kCFCompareEqualTo;
        if (x)
            CFRelease(x);
        if (y)
            CFRelease(y);
        if (r != kCFCompareEqualTo)
            return r;
    }
    return kCFCompareEqualTo;
}

/* Every font passes (Finch has no validator yet): no results. */
bool
CTFontManagerValidateFonts(CFArrayRef fontURLs, CFDictionaryRef options, CFTypeRef *results)
{
    if (results)
        *results = NULL;
    return true;
}

/* A line of the string set in the attributes. */
CTLineRef
CTLineCreateWithString(CFStringRef string, CFDictionaryRef attributes)
{
    CFAttributedStringRef a = CFAttributedStringCreate(NULL, string ? string : CFSTR(""), attributes);
    CTLineRef line = CTLineCreateWithAttributedString(a);
    CFRelease(a);
    return line;
}

/* The run's font (not retained). */
CTFontRef
CTRunGetFont(CTRunRef run)
{
    CFDictionaryRef attrs = run ? CTRunGetAttributes(run) : NULL;
    return attrs ? (CTFontRef)CFDictionaryGetValue(attrs, kCTFontAttributeName) : NULL;
}

/* The default ascent: the font's own (Finch doesn't adjust ascents for languages). */
CGFloat
CTFontGetDefaultAscent(CTFontRef font)
{
    return font ? CTFontGetAscent(font) : 0;
}

}
