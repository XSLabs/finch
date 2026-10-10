/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Text Input Sources. Finch's one input source is the U.S. keyboard layout (TSM.c's,
 * the one the system types with), so it's the current, ASCII-capable keyboard layout
 * and input source, enabled and selected; its kTISPropertyUnicodeKeyLayoutData is the
 * layout as 'uchr' data, which UCKeyTranslate reads (CarbonCore). Other input sources
 * (input methods, palettes) come when Finch has them.
 */
#include <Carbon/Carbon.h>
#include <pthread.h>

CFDataRef FinchCopyUSKeyLayoutData(void);

typedef struct {
    uintptr_t isa;
    _Atomic(uint64_t) info;
} CFRuntimeBase;

struct __TISInputSource {
    CFRuntimeBase base;
    CFDictionaryRef properties;
};

/* CoreFoundation's runtime, as the other Finch frameworks register their CF types. */
typedef struct {
    CFIndex version;
    const char *className;
    void (*init)(CFTypeRef);
    CFTypeRef (*copy)(CFAllocatorRef, CFTypeRef);
    void (*finalize)(CFTypeRef);
    Boolean (*equal)(CFTypeRef, CFTypeRef);
    CFHashCode (*hash)(CFTypeRef);
    CFStringRef (*copyFormattingDesc)(CFTypeRef, CFDictionaryRef);
    CFStringRef (*copyDebugDesc)(CFTypeRef);
    void (*reclaim)(CFTypeRef);
    uint32_t (*refcount)(intptr_t, CFTypeRef);
    uintptr_t requiredAlignment;
} CFRuntimeClass;
extern CFTypeID _CFRuntimeRegisterClass(const CFRuntimeClass *cls);
extern CFTypeRef _CFRuntimeCreateInstance(CFAllocatorRef allocator, CFTypeID typeID, CFIndex extraBytes, unsigned char *category);

static CFStringRef
source_description(CFTypeRef cf)
{
    const struct __TISInputSource *s = cf;
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("<TSMInputSource %p> KB Layout: %@ (id=0)"), cf,
                                    CFDictionaryGetValue(s->properties, kTISPropertyLocalizedName));
}

static const CFRuntimeClass source_class = {0, "TSMInputSource", NULL, NULL, NULL, NULL, NULL, NULL, source_description, NULL, NULL, 0};
static CFTypeID source_type;
static TISInputSourceRef us_layout;

static void
register_type(void)
{
    source_type = _CFRuntimeRegisterClass(&source_class);
}

CFTypeID
TISInputSourceGetTypeID(void)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, register_type);
    return source_type;
}

static void
make_us(void)
{
        struct __TISInputSource *s = (struct __TISInputSource *)_CFRuntimeCreateInstance(
            NULL, TISInputSourceGetTypeID(), sizeof(struct __TISInputSource) - sizeof(CFRuntimeBase), NULL);
        CFMutableDictionaryRef p = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(p, kTISPropertyInputSourceCategory, kTISCategoryKeyboardInputSource);
        CFDictionarySetValue(p, kTISPropertyInputSourceType, kTISTypeKeyboardLayout);
        CFDictionarySetValue(p, kTISPropertyInputSourceIsASCIICapable, kCFBooleanTrue);
        CFDictionarySetValue(p, kTISPropertyInputSourceIsEnableCapable, kCFBooleanTrue);
        CFDictionarySetValue(p, kTISPropertyInputSourceIsSelectCapable, kCFBooleanTrue);
        CFDictionarySetValue(p, kTISPropertyInputSourceIsEnabled, kCFBooleanTrue);
        CFDictionarySetValue(p, kTISPropertyInputSourceIsSelected, kCFBooleanTrue);
        CFDictionarySetValue(p, kTISPropertyInputSourceID, CFSTR("com.apple.keylayout.US"));
        CFDictionarySetValue(p, kTISPropertyBundleID, CFSTR("com.apple.keylayout.US"));
        CFDictionarySetValue(p, kTISPropertyLocalizedName, CFSTR("U.S."));
        CFStringRef en = CFSTR("en");
        CFArrayRef languages = CFArrayCreate(NULL, (const void **)&en, 1, &kCFTypeArrayCallBacks);
        CFDictionarySetValue(p, kTISPropertyInputSourceLanguages, languages);
        CFRelease(languages);
        CFDataRef layout = FinchCopyUSKeyLayoutData();
        CFDictionarySetValue(p, kTISPropertyUnicodeKeyLayoutData, layout);
        CFRelease(layout);
        s->properties = p;
        us_layout = s;
}

static TISInputSourceRef
us(void)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, make_us);
    return us_layout;
}

void *
TISGetInputSourceProperty(TISInputSourceRef inputSource, CFStringRef propertyKey)
{
    if (!inputSource || !propertyKey)
        return NULL;
    return (void *)CFDictionaryGetValue(((const struct __TISInputSource *)inputSource)->properties, propertyKey);
}

static TISInputSourceRef
copy_us(void)
{
    return (TISInputSourceRef)CFRetain(us());
}

TISInputSourceRef TISCopyCurrentKeyboardInputSource(void) { return copy_us(); }
TISInputSourceRef TISCopyCurrentKeyboardLayoutInputSource(void) { return copy_us(); }
TISInputSourceRef TISCopyCurrentASCIICapableKeyboardInputSource(void) { return copy_us(); }
TISInputSourceRef TISCopyCurrentASCIICapableKeyboardLayoutInputSource(void) { return copy_us(); }
TISInputSourceRef TISCopyInputMethodKeyboardLayoutOverride(void) { return NULL; }

TISInputSourceRef
TISCopyInputSourceForLanguage(CFStringRef language)
{
    return language && CFStringHasPrefix(language, CFSTR("en")) ? copy_us() : NULL;
}

/* The sources whose properties match those given (all of them: just the one). */
CFArrayRef
TISCreateInputSourceList(CFDictionaryRef properties, Boolean includeAllInstalled)
{
    TISInputSourceRef s = us();
    Boolean match = true;
    if (properties) {
        CFIndex n = CFDictionaryGetCount(properties);
        const void **keys = malloc((size_t)n * sizeof(void *)), **values = malloc((size_t)n * sizeof(void *));
        CFDictionaryGetKeysAndValues(properties, keys, values);
        for (CFIndex i = 0; i < n; i++) {
            CFTypeRef have = TISGetInputSourceProperty(s, keys[i]);
            if (!have || !CFEqual(have, values[i]))
                match = false;
        }
        free(keys);
        free(values);
    }
    return CFArrayCreate(NULL, match ? (const void **)&s : NULL, match ? 1 : 0, &kCFTypeArrayCallBacks);
}

CFArrayRef
TISCreateASCIICapableInputSourceList(void)
{
    TISInputSourceRef s = us();
    return CFArrayCreate(NULL, (const void **)&s, 1, &kCFTypeArrayCallBacks);
}

OSStatus TISSelectInputSource(TISInputSourceRef inputSource) { return inputSource == us() ? noErr : paramErr; }
OSStatus TISDeselectInputSource(TISInputSourceRef inputSource) { return paramErr; }
OSStatus TISEnableInputSource(TISInputSourceRef inputSource) { return inputSource == us() ? noErr : paramErr; }
OSStatus TISDisableInputSource(TISInputSourceRef inputSource) { return paramErr; }
OSStatus TISSetInputMethodKeyboardLayoutOverride(TISInputSourceRef keyboardLayout) { return noErr; }
OSStatus TISRegisterInputSource(CFURLRef location) { return paramErr; }

/* The keyboard type (LowMem): an ANSI keyboard. */
UInt8 LMGetKbdType(void) { return 40; }
UInt32 KBGetLayoutType(SInt16 iKeyboardType) { return kKeyboardANSI; }
