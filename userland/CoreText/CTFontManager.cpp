/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CTFontManager and CTFontCollection: registering fonts for this process
 * (by URL, data or CGFont), and listing and matching the fonts available.
 */
#include "CTRegistry.h"
#include <objc/message.h>
#include <objc/runtime.h>
#include <algorithm>
#include <set>

#pragma mark - Registration

static CGFontRef
font_from_url(CFURLRef url)
{
    CGDataProviderRef p = url ? CGDataProviderCreateWithURL(url) : NULL;
    CGFontRef f = p ? CGFontCreateWithDataProvider(p) : NULL;
    if (p)
        CFRelease(p);
    return f;
}

static CFErrorRef
font_error(CFIndex code)
{
    return CFErrorCreate(NULL, kCTFontManagerErrorDomain, code, NULL);
}

bool
CTFontManagerRegisterGraphicsFont(CGFontRef font, CFErrorRef *error)
{
    if (!font) {
        if (error)
            *error = font_error(kCTFontManagerErrorInvalidFontData);
        return false;
    }
    CTFontRegistryAddGraphicsFont(font);
    return true;
}

bool
CTFontManagerUnregisterGraphicsFont(CGFontRef font, CFErrorRef *error)
{
    if (!font || !CTFontRegistryRemoveGraphicsFont(font)) {
        if (error)
            *error = font_error(kCTFontManagerErrorNotRegistered);
        return false;
    }
    return true;
}

bool
CTFontManagerRegisterFontsForURL(CFURLRef url, CTFontManagerScope scope, CFErrorRef *error)
{
    CGFontRef f = font_from_url(url);
    if (!f) {
        if (error)
            *error = font_error(kCTFontManagerErrorInvalidFontData);
        return false;
    }
    CTFontRegistryAddGraphicsFont(f);
    CFRelease(f);
    return true;
}

bool
CTFontManagerUnregisterFontsForURL(CFURLRef url, CTFontManagerScope scope, CFErrorRef *error)
{
    CGFontRef f = font_from_url(url);
    bool ok = f && CTFontRegistryRemoveGraphicsFont(f);
    if (f)
        CFRelease(f);
    if (!ok && error)
        *error = font_error(kCTFontManagerErrorNotRegistered);
    return ok;
}

bool
CTFontManagerRegisterFontsForURLs(CFArrayRef urls, CTFontManagerScope scope, CFArrayRef *errors)
{
    bool all = true;
    for (CFIndex i = 0; urls && i < CFArrayGetCount(urls); i++)
        all &= CTFontManagerRegisterFontsForURL((CFURLRef)CFArrayGetValueAtIndex(urls, i), scope, NULL);
    if (errors)
        *errors = CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
    return all;
}

bool
CTFontManagerUnregisterFontsForURLs(CFArrayRef urls, CTFontManagerScope scope, CFArrayRef *errors)
{
    bool all = true;
    for (CFIndex i = 0; urls && i < CFArrayGetCount(urls); i++)
        all &= CTFontManagerUnregisterFontsForURL((CFURLRef)CFArrayGetValueAtIndex(urls, i), scope, NULL);
    if (errors)
        *errors = CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
    return all;
}

void
CTFontManagerRegisterFontURLs(CFArrayRef urls, CTFontManagerScope scope, bool enabled, bool (^handler)(CFArrayRef, bool))
{
    bool ok = CTFontManagerRegisterFontsForURLs(urls, scope, NULL);
    if (handler) {
        CFArrayRef none = CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
        handler(none, ok);
        CFRelease(none);
    }
}

void
CTFontManagerUnregisterFontURLs(CFArrayRef urls, CTFontManagerScope scope, bool (^handler)(CFArrayRef, bool))
{
    bool ok = CTFontManagerUnregisterFontsForURLs(urls, scope, NULL);
    if (handler) {
        CFArrayRef none = CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
        handler(none, ok);
        CFRelease(none);
    }
}

static CTFontDescriptorRef
descriptor_for(CGFontRef f)
{
    CFStringRef ps = CGFontCopyPostScriptName(f);
    CTFontDescriptorRef d = CTFontDescriptorCreateWithNameAndSize(ps ? ps : CFSTR(""), 0);
    if (ps)
        CFRelease(ps);
    return d;
}

void
CTFontManagerRegisterFontDescriptors(CFArrayRef descriptors, CTFontManagerScope scope, bool enabled,
                                     bool (^handler)(CFArrayRef, bool))
{
    if (handler) {
        CFArrayRef none = CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
        handler(none, true);
        CFRelease(none);
    }
}

void
CTFontManagerUnregisterFontDescriptors(CFArrayRef descriptors, CTFontManagerScope scope, bool (^handler)(CFArrayRef, bool))
{
    CTFontManagerRegisterFontDescriptors(descriptors, scope, false, handler);
}

void
CTFontManagerRegisterFontsWithAssetNames(CFArrayRef names, CFBundleRef bundle, CTFontManagerScope scope, bool enabled,
                                         bool (^handler)(CFArrayRef, bool))
{
    if (handler) {
        CFArrayRef none = CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
        handler(none, true);
        CFRelease(none);
    }
}

void
CTFontManagerEnableFontDescriptors(CFArrayRef descriptors, bool enable)
{
}

CTFontManagerScope
CTFontManagerGetScopeForURL(CFURLRef url)
{
    return kCTFontManagerScopeNone;
}

bool
CTFontManagerIsSupportedFont(CFURLRef url)
{
    CGFontRef f = font_from_url(url);
    if (f)
        CFRelease(f);
    return f != NULL;
}

CTFontDescriptorRef
CTFontManagerCreateFontDescriptorFromData(CFDataRef data)
{
    CGDataProviderRef p = data ? CGDataProviderCreateWithCFData(data) : NULL;
    CGFontRef f = p ? CGFontCreateWithDataProvider(p) : NULL;
    if (p)
        CFRelease(p);
    if (!f)
        return NULL;
    CTFontRegistryAddGraphicsFont(f);
    CTFontDescriptorRef d = descriptor_for(f);
    CFRelease(f);
    return d;
}

CFArrayRef
CTFontManagerCreateFontDescriptorsFromData(CFDataRef data)
{
    CTFontDescriptorRef d = CTFontManagerCreateFontDescriptorFromData(data);
    if (!d)
        return CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
    CFArrayRef a = CFArrayCreate(NULL, (const void **)&d, 1, &kCFTypeArrayCallBacks);
    CFRelease(d);
    return a;
}

CFArrayRef
CTFontManagerCreateFontDescriptorsFromURL(CFURLRef url)
{
    CGFontRef f = font_from_url(url);
    if (!f)
        return NULL;
    CTFontRegistryAddGraphicsFont(f);
    CTFontDescriptorRef d = descriptor_for(f);
    CFRelease(f);
    CFArrayRef a = CFArrayCreate(NULL, (const void **)&d, 1, &kCFTypeArrayCallBacks);
    CFRelease(d);
    return a;
}

CFArrayRef
CTFontManagerCopyRegisteredFontDescriptors(CTFontManagerScope scope, bool enabled)
{
    CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (const std::string &n : CTFontRegistryRegisteredNames()) {
        CFStringRef s = CFStringCreateWithCString(NULL, n.c_str(), kCFStringEncodingUTF8);
        CTFontDescriptorRef d = CTFontDescriptorCreateWithNameAndSize(s, 0);
        CFArrayAppendValue(out, d);
        CFRelease(d), CFRelease(s);
    }
    return out;
}

void
CTFontManagerRequestFonts(CFArrayRef fontDescriptors, void (^completionHandler)(CFArrayRef unresolved))
{
    if (completionHandler) {
        CFArrayRef none = CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
        completionHandler(none);
        CFRelease(none);
    }
}

#pragma mark - Listing

static CFArrayRef
sorted_strings(std::set<std::string> names)
{
    CFMutableArrayRef out = CFArrayCreateMutable(NULL, (CFIndex)names.size(), &kCFTypeArrayCallBacks);
    for (const std::string &n : names) {
        CFStringRef s = CFStringCreateWithCString(NULL, n.c_str(), kCFStringEncodingUTF8);
        CFArrayAppendValue(out, s);
        CFRelease(s);
    }
    return out;
}

CFArrayRef
CTFontManagerCopyAvailablePostScriptNames(void)
{
    std::set<std::string> names;
    for (auto &f : CTInstalledFonts())
        names.insert(f.postscript);
    for (const std::string &n : CTFontRegistryRegisteredNames())
        names.insert(n);
    return sorted_strings(names);
}

CFArrayRef
CTFontManagerCopyAvailableFontFamilyNames(void)
{
    std::set<std::string> names;
    for (auto &f : CTInstalledFonts())
        if (!f.family.empty() && f.family[0] != '.')
            names.insert(f.family);
    return sorted_strings(names);
}

CFArrayRef
CTFontManagerCopyAvailableFontURLs(void)
{
    CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    std::set<std::string> seen;
    for (auto &f : CTInstalledFonts()) {
        if (!seen.insert(f.path).second)
            continue;
        CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)f.path.c_str(), (CFIndex)f.path.size(), false);
        CFArrayAppendValue(out, u);
        CFRelease(u);
    }
    return out;
}

CFComparisonResult
CTFontManagerCompareFontFamilyNames(const void *a, const void *b, void *context)
{
    return CFStringCompare((CFStringRef)a, (CFStringRef)b, kCFCompareLocalized | kCFCompareCaseInsensitive);
}

CFRunLoopSourceRef
CTFontManagerCreateFontRequestRunLoopSource(CFIndex order, CFArrayRef (^createMatchesCallback)(CFDictionaryRef, pid_t))
{
    return NULL;
}

void CTFontManagerSetAutoActivationSetting(CFStringRef bundleIdentifier, CTFontManagerAutoActivationSetting setting) {}
CTFontManagerAutoActivationSetting CTFontManagerGetAutoActivationSetting(CFStringRef bundleIdentifier)
{
    return kCTFontManagerAutoActivationDefault;
}

#pragma mark - CTFontCollection

struct __CTFontCollection {
    CTRuntimeBase base;
    CFArrayRef query;      /* descriptors to match, or NULL for all fonts */
    CFArrayRef exclusions;
    CFDictionaryRef attributes; /* (private) the collection's own attributes: its name and the like */
};

static void
collection_finalize(CFTypeRef cf)
{
    struct __CTFontCollection *c = (struct __CTFontCollection *)cf;
    if (c->query)
        CFRelease(c->query);
    if (c->exclusions)
        CFRelease(c->exclusions);
    if (c->attributes)
        CFRelease(c->attributes);
}

static const CTRuntimeClass collection_class = {
    0, "CTFontCollection", NULL, NULL, collection_finalize, NULL, NULL, NULL, NULL, NULL, NULL, 0,
};
static CFTypeID collection_type;

CFTypeID
CTFontCollectionGetTypeID(void)
{
    return CTTypeRegister(&collection_class, &collection_type);
}

static struct __CTFontCollection *
collection_new(CFArrayRef query)
{
    struct __CTFontCollection *c =
        (struct __CTFontCollection *)CTTypeCreateInstance(CTFontCollectionGetTypeID(), sizeof(struct __CTFontCollection));
    c->query = query ? CFArrayCreateCopy(NULL, query) : NULL;
    return c;
}

CTFontCollectionRef CTFontCollectionCreateFromAvailableFonts(CFDictionaryRef options) { return collection_new(NULL); }
CTFontCollectionRef CTFontCollectionCreateWithFontDescriptors(CFArrayRef q, CFDictionaryRef options) { return collection_new(q); }

CTFontCollectionRef
CTFontCollectionCreateCopyWithFontDescriptors(CTFontCollectionRef original, CFArrayRef q, CFDictionaryRef options)
{
    return collection_new(q);
}

CTMutableFontCollectionRef
CTFontCollectionCreateMutableCopy(CTFontCollectionRef original)
{
    struct __CTFontCollection *c = collection_new(original ? original->query : NULL);
    if (original && original->exclusions)
        c->exclusions = CFArrayCreateCopy(NULL, original->exclusions);
    return (CTMutableFontCollectionRef)c;
}

/* (private) a collection's attributes, as Font Book keeps them */
extern "C" CFDictionaryRef CTFontCollectionCopyAttributes(CTFontCollectionRef c);
extern "C" void CTFontCollectionSetAttributes(CTFontCollectionRef c, CFDictionaryRef attributes);

static const char attributes_key = 0;

CFDictionaryRef
CTFontCollectionCopyAttributes(CTFontCollectionRef c)
{
    if (c && CFGetTypeID(c) != CTFontCollectionGetTypeID()) {
        id a = objc_getAssociatedObject((id)c, &attributes_key);
        return a ? (CFDictionaryRef)CFRetain((CFTypeRef)a) : CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    }
    return c && c->attributes ? (CFDictionaryRef)CFRetain(c->attributes) : CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

void
CTFontCollectionSetAttributes(CTFontCollectionRef c, CFDictionaryRef attributes)
{
    if (!c)
        return;
    if (CFGetTypeID(c) != CTFontCollectionGetTypeID()) {
        CFDictionaryRef copy = attributes ? CFDictionaryCreateCopy(NULL, attributes) : NULL;
        objc_setAssociatedObject((id)c, &attributes_key, (id)copy, OBJC_ASSOCIATION_RETAIN);
        if (copy)
            CFRelease(copy);
        return;
    }
    struct __CTFontCollection *m = (struct __CTFontCollection *)c;
    if (m->attributes)
        CFRelease(m->attributes);
    m->attributes = attributes ? CFDictionaryCreateCopy(NULL, attributes) : NULL;
}

static CFArrayRef CTFontCollectionCopyQueryDescriptors_impl(CTFontCollectionRef c) { return c && c->query ? (CFArrayRef)CFRetain(c->query) : NULL; }
static CFArrayRef CTFontCollectionCopyExclusionDescriptors_impl(CTFontCollectionRef c) { return c && c->exclusions ? (CFArrayRef)CFRetain(c->exclusions) : NULL; }

void
CTFontCollectionSetQueryDescriptors(CTMutableFontCollectionRef c, CFArrayRef q)
{
    struct __CTFontCollection *m = (struct __CTFontCollection *)c;
    if (m->query)
        CFRelease(m->query);
    m->query = q ? CFArrayCreateCopy(NULL, q) : NULL;
}

void
CTFontCollectionSetExclusionDescriptors(CTMutableFontCollectionRef c, CFArrayRef e)
{
    struct __CTFontCollection *m = (struct __CTFontCollection *)c;
    if (m->exclusions)
        CFRelease(m->exclusions);
    m->exclusions = e ? CFArrayCreateCopy(NULL, e) : NULL;
}

/* Does an installed font satisfy a query descriptor (by name, family, symbolic traits
   and languages)? The font itself is opened only for traits and languages. */
static bool
matches(const CTInstalledFont &f, CTFontDescriptorRef d)
{
    CFStringRef name = (CFStringRef)CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute);
    CFStringRef family = (CFStringRef)CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute);
    CFDictionaryRef traits = (CFDictionaryRef)CTFontDescriptorCopyAttribute(d, kCTFontTraitsAttribute);
    CFArrayRef languages = (CFArrayRef)CTFontDescriptorCopyAttribute(d, kCTFontLanguagesAttribute);
    char buf[512];
    bool ok = true;
    if (name) {
        ok &= CFStringGetCString(name, buf, sizeof buf, kCFStringEncodingUTF8) && (f.postscript == buf || f.full == buf);
        CFRelease(name);
    }
    if (family) {
        ok &= CFStringGetCString(family, buf, sizeof buf, kCFStringEncodingUTF8) && f.family == buf;
        CFRelease(family);
    }
    uint32_t want = 0;
    if (traits && CFGetTypeID(traits) == CFDictionaryGetTypeID()) {
        CFNumberRef n = (CFNumberRef)CFDictionaryGetValue(traits, kCTFontSymbolicTrait);
        if (n && CFGetTypeID(n) == CFNumberGetTypeID())
            CFNumberGetValue(n, kCFNumberSInt32Type, &want);
        want &= 0xFFFF; /* the class bits aren't a mask */
    }
    bool wantLanguages = languages && CFGetTypeID(languages) == CFArrayGetTypeID() && CFArrayGetCount(languages);
    if (ok && (want || wantLanguages)) {
        CFStringRef ps = CFStringCreateWithCString(NULL, f.postscript.c_str(), kCFStringEncodingUTF8);
        CTFontRef font = CTFontCreateWithName(ps, 12, NULL);
        CFRelease(ps);
        if (want)
            ok &= font && (CTFontGetSymbolicTraits(font) & want) == want;
        if (ok && wantLanguages) {
            CFArrayRef have = font ? CTFontCopySupportedLanguages(font) : NULL;
            for (CFIndex i = 0; ok && i < CFArrayGetCount(languages); i++)
                ok &= have && CFArrayContainsValue(have, CFRangeMake(0, CFArrayGetCount(have)), CFArrayGetValueAtIndex(languages, i));
            if (have)
                CFRelease(have);
        }
        if (font)
            CFRelease(font);
    }
    if (traits)
        CFRelease(traits);
    if (languages)
        CFRelease(languages);
    return ok;
}

static CFArrayRef
CTFontCollectionCreateMatchingFontDescriptors_impl(CTFontCollectionRef c)
{
    if (!c)
        return NULL;
    CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    std::set<std::string> seen;
    for (auto &f : CTInstalledFonts()) {
        if (f.postscript.empty() || f.postscript[0] == '.' || !seen.insert(f.postscript).second)
            continue;
        bool want = !c->query;
        for (CFIndex i = 0; c->query && i < CFArrayGetCount(c->query) && !want; i++)
            want = matches(f, (CTFontDescriptorRef)CFArrayGetValueAtIndex(c->query, i));
        for (CFIndex i = 0; c->exclusions && i < CFArrayGetCount(c->exclusions) && want; i++)
            want = !matches(f, (CTFontDescriptorRef)CFArrayGetValueAtIndex(c->exclusions, i));
        if (!want)
            continue;
        CFStringRef s = CFStringCreateWithCString(NULL, f.postscript.c_str(), kCFStringEncodingUTF8);
        CTFontDescriptorRef d = CTFontDescriptorCreateWithNameAndSize(s, 0);
        CFArrayAppendValue(out, d);
        CFRelease(d), CFRelease(s);
    }
    if (CFArrayGetCount(out) == 0) {
        CFRelease(out);
        return NULL;
    }
    return out;
}

static CFArrayRef
CTFontCollectionCreateMatchingFontDescriptorsWithOptions_impl(CTFontCollectionRef c, CFDictionaryRef options)
{
    return CTFontCollectionCreateMatchingFontDescriptors(c);
}

CFArrayRef
CTFontCollectionCreateMatchingFontDescriptorsSortedWithCallback(CTFontCollectionRef c,
                                                                CTFontCollectionSortDescriptorsCallback sortCallback,
                                                                void *refCon)
{
    CFArrayRef a = CTFontCollectionCreateMatchingFontDescriptors(c);
    if (!a || !sortCallback)
        return a;
    CFMutableArrayRef m = CFArrayCreateMutableCopy(NULL, 0, a);
    CFRelease(a);
    CFArraySortValues(m, CFRangeMake(0, CFArrayGetCount(m)), (CFComparatorFunction)sortCallback, refCon);
    return m;
}

static CFArrayRef
CTFontCollectionCreateMatchingFontDescriptorsForFamily_impl(CTFontCollectionRef c, CFStringRef familyName, CFDictionaryRef options)
{
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, (const void **)&kCTFontFamilyNameAttribute, (const void **)&familyName,
                                               1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CTFontDescriptorRef d = CTFontDescriptorCreateWithAttributes(attrs);
    CFArrayRef q = CFArrayCreate(NULL, (const void **)&d, 1, &kCFTypeArrayCallBacks);
    CTFontCollectionRef fam = CTFontCollectionCreateWithFontDescriptors(q, NULL);
    CFArrayRef out = CTFontCollectionCreateMatchingFontDescriptors(fam);
    CFRelease(fam), CFRelease(q), CFRelease(d), CFRelease(attrs);
    return out;
}

static CFArrayRef
CTFontCollectionCopyFontAttribute_impl(CTFontCollectionRef c, CFStringRef attributeName, CTFontCollectionCopyOptions options)
{
    CFArrayRef descs = CTFontCollectionCreateMatchingFontDescriptors(c);
    CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; descs && i < CFArrayGetCount(descs); i++) {
        CFTypeRef v = CTFontDescriptorCopyAttribute((CTFontDescriptorRef)CFArrayGetValueAtIndex(descs, i), attributeName);
        if (v) {
            CFArrayAppendValue(out, v);
            CFRelease(v);
        }
    }
    if (descs)
        CFRelease(descs);
    return out;
}

static CFArrayRef
CTFontCollectionCopyFontAttributes_impl(CTFontCollectionRef c, CFSetRef attributeNames, CTFontCollectionCopyOptions options)
{
    return CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
}

#pragma mark - Finch's NSFontCollections

/* Apple's NSFontCollection is a CTFontCollection; Finch's is an Objective-C object, so the
   calls that read a collection take one by asking it for its CoreText collection. */
static CTFontCollectionRef
as_ct(CTFontCollectionRef c, CTFontCollectionRef *owned)
{
    *owned = NULL;
    if (!c || CFGetTypeID(c) == CTFontCollectionGetTypeID())
        return c;
    SEL s = sel_registerName("_ctCollection");
    if (!class_respondsToSelector(object_getClass((id)c), s))
        return NULL;
    *owned = ((CTFontCollectionRef(*)(const void *, SEL))objc_msgSend)(c, s);
    return *owned;
}

CFArrayRef
CTFontCollectionCreateMatchingFontDescriptors(CTFontCollectionRef c)
{
    CTFontCollectionRef owned;
    c = as_ct(c, &owned);
    CFArrayRef r = c ? CTFontCollectionCreateMatchingFontDescriptors_impl(c) : NULL;
    if (owned)
        CFRelease(owned);
    return r;
}

CFArrayRef
CTFontCollectionCreateMatchingFontDescriptorsWithOptions(CTFontCollectionRef c, CFDictionaryRef options)
{
    CTFontCollectionRef owned;
    c = as_ct(c, &owned);
    CFArrayRef r = c ? CTFontCollectionCreateMatchingFontDescriptorsWithOptions_impl(c, options) : NULL;
    if (owned)
        CFRelease(owned);
    return r;
}

CFArrayRef
CTFontCollectionCreateMatchingFontDescriptorsForFamily(CTFontCollectionRef c, CFStringRef familyName, CFDictionaryRef options)
{
    CTFontCollectionRef owned;
    c = as_ct(c, &owned);
    CFArrayRef r = c ? CTFontCollectionCreateMatchingFontDescriptorsForFamily_impl(c, familyName, options) : NULL;
    if (owned)
        CFRelease(owned);
    return r;
}

CFArrayRef
CTFontCollectionCopyFontAttribute(CTFontCollectionRef c, CFStringRef attributeName, CTFontCollectionCopyOptions options)
{
    CTFontCollectionRef owned;
    c = as_ct(c, &owned);
    CFArrayRef r = c ? CTFontCollectionCopyFontAttribute_impl(c, attributeName, options) : NULL;
    if (owned)
        CFRelease(owned);
    return r;
}

CFArrayRef
CTFontCollectionCopyFontAttributes(CTFontCollectionRef c, CFSetRef attributeNames, CTFontCollectionCopyOptions options)
{
    CTFontCollectionRef owned;
    c = as_ct(c, &owned);
    CFArrayRef r = c ? CTFontCollectionCopyFontAttributes_impl(c, attributeNames, options) : NULL;
    if (owned)
        CFRelease(owned);
    return r;
}

CFArrayRef
CTFontCollectionCopyQueryDescriptors(CTFontCollectionRef c)
{
    CTFontCollectionRef owned;
    c = as_ct(c, &owned);
    CFArrayRef r = c ? CTFontCollectionCopyQueryDescriptors_impl(c) : NULL;
    if (owned)
        CFRelease(owned);
    return r;
}

CFArrayRef
CTFontCollectionCopyExclusionDescriptors(CTFontCollectionRef c)
{
    CTFontCollectionRef owned;
    c = as_ct(c, &owned);
    CFArrayRef r = c ? CTFontCollectionCopyExclusionDescriptors_impl(c) : NULL;
    if (owned)
        CFRelease(owned);
    return r;
}
