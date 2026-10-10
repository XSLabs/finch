/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The Pasteboard Manager (Pasteboard.h): Carbon's pasteboards, on CoreFoundation's
 * (CFPasteboard_Finch.c), the same ones NSPasteboard uses: the clipboard is the general
 * pasteboard, the find pasteboard the find one. A client synchronizes to see changes,
 * clears to become the owner, puts flavors on items it names, and keeps promises
 * through its promise keeper. And PlotIconRefInContext, which draws nothing: IconRefs
 * have no images yet (LaunchServices' LSPrivate.m).
 */
#include <ApplicationServices/ApplicationServices.h>
#include <pthread.h>

/* CoreFoundation's runtime, as Finch's frameworks register their CF types. */
typedef struct {
    uintptr_t isa;
    _Atomic(uint64_t) info;
} CFRuntimeBase;
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

typedef struct __FinchPasteboard *FinchPasteboardRef;
typedef CFDataRef (*FinchPasteboardProvider)(CFStringRef name, CFIndex seed, uint64_t item, CFStringRef type, void *info);
extern FinchPasteboardRef _FinchPasteboardGet(CFStringRef name);
extern void _FinchPasteboardSetProvider(FinchPasteboardRef pb, FinchPasteboardProvider provider, void *info);
extern CFIndex _FinchPasteboardClear(FinchPasteboardRef pb);
extern CFIndex _FinchPasteboardGetChangeCount(FinchPasteboardRef pb);
extern Boolean _FinchPasteboardPut(FinchPasteboardRef pb, CFIndex seed, uint64_t item, CFStringRef type, CFDataRef data);
extern CFArrayRef _FinchPasteboardCopyItems(FinchPasteboardRef pb, CFIndex *seed);
extern CFDataRef _FinchPasteboardCopyData(FinchPasteboardRef pb, uint64_t item, CFStringRef type);

struct OpaquePasteboardRef {
    CFRuntimeBase base;
    CFStringRef name;           /* as the client named it */
    FinchPasteboardRef pb;
    CFIndex synced;             /* the change count last synchronized to */
    CFIndex owned;              /* the change count this client cleared to (0: none) */
    CFArrayRef items;           /* as of `synced`: [{id, types}] */
    PasteboardPromiseKeeperProcPtr keeper;
    void *keeperContext;
    CFURLRef pasteLocation;
    pthread_mutex_t lock;
};

static void
pasteboard_finalize(CFTypeRef cf)
{
    PasteboardRef p = (PasteboardRef)cf;
    CFRelease(p->name);
    if (p->items)
        CFRelease(p->items);
    if (p->pasteLocation)
        CFRelease(p->pasteLocation);
    pthread_mutex_destroy(&p->lock);
}

static const CFRuntimeClass pasteboard_class = {0, "Pasteboard", NULL, NULL, pasteboard_finalize, NULL, NULL, NULL, NULL, NULL, NULL, 0};
static CFTypeID pasteboard_type;

static void
register_type(void)
{
    pasteboard_type = _CFRuntimeRegisterClass(&pasteboard_class);
}

CFTypeID
PasteboardGetTypeID(void)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, register_type);
    return pasteboard_type;
}

/* The CoreFoundation pasteboard a Carbon name is (the clipboard is the general one). */
static CFStringRef
store_name(CFStringRef name)
{
    if (CFEqual(name, kPasteboardClipboard))
        return CFSTR("Apple CFPasteboard general");
    if (CFEqual(name, kPasteboardFind))
        return CFSTR("Apple CFPasteboard find");
    return name;
}

static CFDataRef keep_promise(CFStringRef name, CFIndex seed, uint64_t item, CFStringRef type, void *info);

OSStatus
PasteboardCreate(CFStringRef inName, PasteboardRef *outPasteboard)
{
    if (!outPasteboard)
        return paramErr;
    PasteboardRef p = (PasteboardRef)_CFRuntimeCreateInstance(NULL, PasteboardGetTypeID(),
                                                              sizeof(struct OpaquePasteboardRef) - sizeof(CFRuntimeBase), NULL);
    if (!p)
        return memFullErr;
    if (inName) {
        p->name = CFStringCreateCopy(NULL, inName);
    } else {
        CFUUIDRef u = CFUUIDCreate(NULL);
        CFStringRef s = CFUUIDCreateString(NULL, u);
        p->name = CFStringCreateWithFormat(NULL, NULL, CFSTR("CFPasteboardUnique-%@"), s);
        CFRelease(s);
        CFRelease(u);
    }
    p->pb = _FinchPasteboardGet(store_name(p->name));
    pthread_mutex_init(&p->lock, NULL);
    /* (a new client starts as of the current contents: nothing has changed for it yet) */
    p->synced = _FinchPasteboardGetChangeCount(p->pb);
    *outPasteboard = p;
    return noErr;
}

OSStatus
PasteboardCopyName(PasteboardRef inPasteboard, CFStringRef *outName)
{
    if (!inPasteboard || !outName)
        return paramErr;
    *outName = CFRetain(inPasteboard->name);
    return noErr;
}

/* Brings the client up to the pasteboard's contents: whether they've changed since, and
   whether the client owns them. */
PasteboardSyncFlags
PasteboardSynchronize(PasteboardRef p)
{
    CFIndex seed = 0;
    CFArrayRef items = _FinchPasteboardCopyItems(p->pb, &seed);
    pthread_mutex_lock(&p->lock);
    PasteboardSyncFlags flags = 0;
    if (seed != p->synced)
        flags |= kPasteboardModified;
    if (p->owned && p->owned == seed)
        flags |= kPasteboardClientIsOwner;
    p->synced = seed;
    if (p->items)
        CFRelease(p->items);
    p->items = items;
    pthread_mutex_unlock(&p->lock);
    return flags;
}

static CFArrayRef
items_of(PasteboardRef p)
{
    pthread_mutex_lock(&p->lock);
    Boolean need = p->items == NULL;
    pthread_mutex_unlock(&p->lock);
    if (need)
        PasteboardSynchronize(p);
    pthread_mutex_lock(&p->lock);
    CFArrayRef items = p->items ? CFRetain(p->items) : NULL;
    pthread_mutex_unlock(&p->lock);
    return items;
}

OSStatus
PasteboardClear(PasteboardRef p)
{
    if (!p)
        return paramErr;
    CFIndex seed = _FinchPasteboardClear(p->pb);
    _FinchPasteboardSetProvider(p->pb, keep_promise, p);
    pthread_mutex_lock(&p->lock);
    p->owned = seed;
    p->synced = seed;
    if (p->items)
        CFRelease(p->items);
    p->items = CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
    pthread_mutex_unlock(&p->lock);
    return noErr;
}

OSStatus
PasteboardGetItemCount(PasteboardRef p, ItemCount *outItemCount)
{
    if (!p || !outItemCount)
        return paramErr;
    CFArrayRef items = items_of(p);
    *outItemCount = items ? (ItemCount)CFArrayGetCount(items) : 0;
    if (items)
        CFRelease(items);
    return noErr;
}

/* Text in the flavors Carbon clients read it in, as Apple's translates it: each text
   flavor an item has brings the others it lacks. */
static const CFStringRef text_flavors[] = {CFSTR("public.utf8-plain-text"), CFSTR("public.utf16-external-plain-text"),
                                           CFSTR("com.apple.traditional-mac-plain-text"), CFSTR("public.utf16-plain-text")};
#define TEXT_FLAVORS 4

static Boolean
has(CFArrayRef types, CFStringRef t)
{
    return CFArrayContainsValue(types, CFRangeMake(0, CFArrayGetCount(types)), t);
}

static CFArrayRef
flavors_of(CFArrayRef types)
{
    CFMutableArrayRef out = CFArrayCreateMutableCopy(NULL, 0, types);
    Boolean text = false;
    for (int i = 0; i < TEXT_FLAVORS; i++)
        text |= has(types, text_flavors[i]);
    /* (UTF-8 text isn't made from the others: Apple's leaves it out) */
    for (int i = 1; text && i < TEXT_FLAVORS; i++)
        if (!has(out, text_flavors[i]))
            CFArrayAppendValue(out, text_flavors[i]);
    return out;
}

/* Text data in one flavor, from another. */
static CFDataRef
convert_text(CFDataRef data, CFStringRef from, CFStringRef to)
{
    CFStringEncoding in = CFEqual(from, text_flavors[0]) ? kCFStringEncodingUTF8
                          : CFEqual(from, text_flavors[2]) ? kCFStringEncodingMacRoman
                                                           : kCFStringEncodingUTF16;
    CFStringRef s = CFStringCreateFromExternalRepresentation(NULL, data, in);
    if (!s)
        return NULL;
    CFDataRef out = NULL;
    if (CFEqual(to, text_flavors[1]))
        out = CFStringCreateExternalRepresentation(NULL, s, kCFStringEncodingUTF16, '?');
    else if (CFEqual(to, text_flavors[2]))
        out = CFStringCreateExternalRepresentation(NULL, s, kCFStringEncodingMacRoman, '?');
    else if (CFEqual(to, text_flavors[3])) {
        CFIndex n = CFStringGetLength(s);
        UniChar *buf = malloc((size_t)n * sizeof(UniChar));
        CFStringGetCharacters(s, CFRangeMake(0, n), buf);
        out = CFDataCreate(NULL, (const UInt8 *)buf, n * (CFIndex)sizeof(UniChar));
        free(buf);
    } else if (CFEqual(to, text_flavors[0]))
        out = CFStringCreateExternalRepresentation(NULL, s, kCFStringEncodingUTF8, '?');
    CFRelease(s);
    return out;
}

static CFDictionaryRef
item_with_id(CFArrayRef items, uint64_t id)
{
    for (CFIndex i = 0; items && i < CFArrayGetCount(items); i++) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(items, i);
        uint64_t n = 0;
        CFNumberGetValue(CFDictionaryGetValue(d, CFSTR("id")), kCFNumberSInt64Type, &n);
        if (n == id)
            return d;
    }
    return NULL;
}

/* Items are numbered from 1. */
OSStatus
PasteboardGetItemIdentifier(PasteboardRef p, CFIndex inIndex, PasteboardItemID *outItem)
{
    if (!p || !outItem)
        return paramErr;
    CFArrayRef items = items_of(p);
    OSStatus err = badPasteboardIndexErr;
    if (items && inIndex >= 1 && inIndex <= CFArrayGetCount(items)) {
        uint64_t n = 0;
        CFNumberGetValue(CFDictionaryGetValue(CFArrayGetValueAtIndex(items, inIndex - 1), CFSTR("id")), kCFNumberSInt64Type, &n);
        *outItem = (PasteboardItemID)(uintptr_t)n;
        err = noErr;
    }
    if (items)
        CFRelease(items);
    return err;
}

OSStatus
PasteboardCopyItemFlavors(PasteboardRef p, PasteboardItemID inItem, CFArrayRef *outFlavorTypes)
{
    if (!p || !outFlavorTypes)
        return paramErr;
    CFArrayRef items = items_of(p);
    CFDictionaryRef d = item_with_id(items, (uint64_t)(uintptr_t)inItem);
    OSStatus err = badPasteboardItemErr;
    if (d) {
        *outFlavorTypes = flavors_of(CFDictionaryGetValue(d, CFSTR("types")));
        err = noErr;
    }
    if (items)
        CFRelease(items);
    return err;
}

OSStatus
PasteboardGetItemFlavorFlags(PasteboardRef p, PasteboardItemID inItem, CFStringRef inFlavorType, PasteboardFlavorFlags *outFlags)
{
    if (!p || !outFlags)
        return paramErr;
    CFArrayRef items = items_of(p);
    CFDictionaryRef d = item_with_id(items, (uint64_t)(uintptr_t)inItem);
    OSStatus err = badPasteboardItemErr;
    if (d) {
        CFArrayRef types = CFDictionaryGetValue(d, CFSTR("types")), all = flavors_of(types);
        err = has(all, inFlavorType) ? noErr : badPasteboardFlavorErr;
        *outFlags = has(types, inFlavorType) ? kPasteboardFlavorNoFlags : kPasteboardFlavorSystemTranslated;
        CFRelease(all);
    }
    if (items)
        CFRelease(items);
    return err;
}

OSStatus
PasteboardCopyItemFlavorData(PasteboardRef p, PasteboardItemID inItem, CFStringRef inFlavorType, CFDataRef *outData)
{
    if (!p || !inFlavorType || !outData)
        return paramErr;
    CFArrayRef items = items_of(p);
    CFDictionaryRef d = item_with_id(items, (uint64_t)(uintptr_t)inItem);
    OSStatus err = badPasteboardItemErr;
    if (d) {
        CFArrayRef types = CFDictionaryGetValue(d, CFSTR("types"));
        err = badPasteboardFlavorErr;
        if (has(types, inFlavorType)) {
            *outData = _FinchPasteboardCopyData(p->pb, (uint64_t)(uintptr_t)inItem, inFlavorType);
            err = *outData ? noErr : badPasteboardFlavorErr;
        } else {
            /* a text flavor made from the item's own text */
            for (int i = 0; i < TEXT_FLAVORS && err; i++)
                if (has(types, text_flavors[i]) && !CFEqual(text_flavors[i], inFlavorType)) {
                    CFDataRef src = _FinchPasteboardCopyData(p->pb, (uint64_t)(uintptr_t)inItem, text_flavors[i]);
                    for (int k = 1; src && k < TEXT_FLAVORS; k++)
                        if (CFEqual(text_flavors[k], inFlavorType)) {
                            *outData = convert_text(src, text_flavors[i], inFlavorType);
                            err = *outData ? noErr : badPasteboardFlavorErr;
                        }
                    if (src)
                        CFRelease(src);
                }
        }
    }
    if (items)
        CFRelease(items);
    return err;
}

/* A flavor on an item of the client's own contents (kPasteboardPromisedData: promised,
   kept by its promise keeper). */
OSStatus
PasteboardPutItemFlavor(PasteboardRef p, PasteboardItemID inItem, CFStringRef inFlavorType, CFDataRef inData,
                        PasteboardFlavorFlags inFlags)
{
    if (!p || !inFlavorType)
        return paramErr;
    pthread_mutex_lock(&p->lock);
    CFIndex owned = p->owned;
    pthread_mutex_unlock(&p->lock);
    if (!owned || _FinchPasteboardGetChangeCount(p->pb) != owned)
        return notPasteboardOwnerErr;
    CFDataRef data = inData == kPasteboardPromisedData ? NULL : inData;
    if (!_FinchPasteboardPut(p->pb, owned, (uint64_t)(uintptr_t)inItem, inFlavorType, data))
        return notPasteboardOwnerErr;
    /* (the client sees its own writes at once) */
    PasteboardSynchronize(p);
    return noErr;
}

OSStatus
PasteboardSetPromiseKeeper(PasteboardRef p, PasteboardPromiseKeeperProcPtr inPromiseKeeper, void *inContext)
{
    if (!p)
        return paramErr;
    pthread_mutex_lock(&p->lock);
    p->keeper = inPromiseKeeper;
    p->keeperContext = inContext;
    pthread_mutex_unlock(&p->lock);
    return noErr;
}

/* A promise asked for: the keeper puts the data, which is then read back. */
static CFDataRef
keep_promise(CFStringRef name, CFIndex seed, uint64_t item, CFStringRef type, void *info)
{
    PasteboardRef p = info;
    pthread_mutex_lock(&p->lock);
    PasteboardPromiseKeeperProcPtr keeper = p->keeper;
    void *context = p->keeperContext;
    Boolean mine = seed == p->owned;
    pthread_mutex_unlock(&p->lock);
    if (!keeper || !mine)
        return NULL;
    if (keeper(p, (PasteboardItemID)(uintptr_t)item, type, context) != noErr)
        return NULL;
    return _FinchPasteboardCopyData(p->pb, item, type);
}

/* Keeps every promise of the client's now (as before quitting). */
OSStatus
PasteboardResolvePromises(PasteboardRef p)
{
    if (!p)
        return paramErr;
    CFArrayRef items = items_of(p);
    for (CFIndex i = 0; items && i < CFArrayGetCount(items); i++) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(items, i);
        uint64_t id = 0;
        CFNumberGetValue(CFDictionaryGetValue(d, CFSTR("id")), kCFNumberSInt64Type, &id);
        CFArrayRef types = CFDictionaryGetValue(d, CFSTR("types"));
        for (CFIndex k = 0; k < CFArrayGetCount(types); k++) {
            CFDataRef data = _FinchPasteboardCopyData(p->pb, id, CFArrayGetValueAtIndex(types, k));
            if (data)
                CFRelease(data);
        }
    }
    if (items)
        CFRelease(items);
    return noErr;
}

OSStatus
PasteboardSetPasteLocation(PasteboardRef p, CFURLRef inPasteLocation)
{
    if (!p)
        return paramErr;
    pthread_mutex_lock(&p->lock);
    if (p->pasteLocation)
        CFRelease(p->pasteLocation);
    p->pasteLocation = inPasteLocation ? CFRetain(inPasteLocation) : NULL;
    pthread_mutex_unlock(&p->lock);
    return noErr;
}

OSStatus
PasteboardCopyPasteLocation(PasteboardRef p, CFURLRef *outPasteLocation)
{
    if (!p || !outPasteLocation)
        return paramErr;
    pthread_mutex_lock(&p->lock);
    *outPasteLocation = p->pasteLocation ? CFRetain(p->pasteLocation) : NULL;
    pthread_mutex_unlock(&p->lock);
    return *outPasteLocation ? noErr : noPasteboardPromiseKeeperErr;
}

/* Icons: an IconRef has no image yet, so there's nothing to draw. */
OSStatus
PlotIconRefInContext(CGContextRef inContext, const CGRect *inRect, IconAlignmentType inAlign, IconTransformType inTransform,
                     const RGBColor *inLabelColor, PlotIconRefFlags inFlags, IconRef inIconRef)
{
    return inContext && inRect && inIconRef ? noErr : paramErr;
}
