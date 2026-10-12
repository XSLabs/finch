/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * PrintCore, Finch's: print sessions, print settings, page formats, papers and printers
 * as CF objects, with Apple's keys and behaviour where apps can see it.
 *
 * Finch has no printing system yet, so the printer list is empty and a session's current
 * printer is the generic printer, whose papers are the standard sizes (PWG names, 18-point
 * margins). Print settings are a dictionary under Apple's com.apple.print keys; a
 * session's defaults fill in copies, collation and the page range as Apple's do. Page
 * formats keep their paper, orientation and scale, and recompute their page and paper
 * rectangles when they're made, given a paper or validated, as Apple's do. A session
 * whose destination is a file draws into a PDF context there (BeginCGDocument /
 * BeginPage / GetCGGraphicsContext); one for a printer has nowhere to go
 * (kPMInvalidPrinter).
 */
#include <ApplicationServices/ApplicationServices.h>
#include <dispatch/dispatch.h>
#include <stdatomic.h>

#define PM_EXPORT __attribute__((visibility("default")))

/* CoreFoundation's runtime (swift-corelibs' CFRuntime.h): CF types of our own. */
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

/* MARK: - Objects */

#define KEY(s) CFSTR("com.apple.print." s)
#define K_COPIES KEY("PrintSettings.PMCopies")
#define K_COLLATE KEY("PrintSettings.PMCopyCollate")
#define K_FIRST KEY("PrintSettings.PMFirstPage")
#define K_LAST KEY("PrintSettings.PMLastPage")
#define K_RANGE KEY("PrintSettings.PMPageRange")
#define K_DUPLEX KEY("PrintSettings.PMDuplexing")
#define K_JOB KEY("JobInfo.PMJobName")
#define K_TICKET KEY("ticket.type")
#define K_SPOOL KEY("DocumentTicket.PMSpoolFormat")
#define K_DESTINATION KEY("PrintSettings.PMDestinationType")
#define K_OUTPUT_URL KEY("PrintSettings.PMOutputFilename")
#define K_OUTPUT_FORMAT KEY("PrintSettings.PMOutputFormat")
#define K_MATCHING KEY("PrintSettings.PMColorMatchingMode")
#define K_INTENT KEY("PrintSettings.PMApplicationOutputIntent")
#define ALL_PAGES 2147483647u

struct OpaquePMPrintSettings {
    CFRuntimeBase base;
    CFMutableDictionaryRef dict;
};

struct OpaquePMPaper {
    CFRuntimeBase base;
    CFStringRef ident, name, printerID;
    double width, height;
    PMPaperMargins margins;
    bool custom;
};

struct OpaquePMPageFormat {
    CFRuntimeBase base;
    PMPaper paper;
    PMOrientation orientation;
    double scale; /* percent */
    PMRect pageRect, paperRect; /* as last computed (made, given a paper, validated) */
    CFMutableDictionaryRef extended;
};

struct OpaquePMPrinter {
    CFRuntimeBase base;
    CFStringRef name, ident;
    PMResolution resolution;
};

struct OpaquePMPrintSession {
    CFRuntimeBase base;
    OSStatus error;
    PMPrinter printer;
    CFMutableDictionaryRef data;
    bool matchingLocked;
    /* a document being drawn */
    CGContextRef context;
    PMPageFormat format;
    bool inPage;
};

struct OpaquePMPreset {
    CFRuntimeBase base;
    CFStringRef name;
    CFDictionaryRef attributes;
};

static void
settings_finalize(CFTypeRef cf)
{
    struct OpaquePMPrintSettings *s = (void *)cf;
    if (s->dict)
        CFRelease(s->dict);
}

static void
paper_finalize(CFTypeRef cf)
{
    struct OpaquePMPaper *p = (void *)cf;
    if (p->ident)
        CFRelease(p->ident);
    if (p->name)
        CFRelease(p->name);
    if (p->printerID)
        CFRelease(p->printerID);
}

static void
format_finalize(CFTypeRef cf)
{
    struct OpaquePMPageFormat *f = (void *)cf;
    if (f->paper)
        CFRelease(f->paper);
    if (f->extended)
        CFRelease(f->extended);
}

static void
printer_finalize(CFTypeRef cf)
{
    struct OpaquePMPrinter *p = (void *)cf;
    if (p->name)
        CFRelease(p->name);
    if (p->ident)
        CFRelease(p->ident);
}

static void
session_finalize(CFTypeRef cf)
{
    struct OpaquePMPrintSession *s = (void *)cf;
    if (s->printer)
        CFRelease(s->printer);
    if (s->data)
        CFRelease(s->data);
    if (s->context)
        CGContextRelease(s->context);
    if (s->format)
        CFRelease(s->format);
}

static void
preset_finalize(CFTypeRef cf)
{
    struct OpaquePMPreset *p = (void *)cf;
    if (p->name)
        CFRelease(p->name);
    if (p->attributes)
        CFRelease(p->attributes);
}

#define CLASS(var, name, fin) static const CFRuntimeClass var = {0, name, NULL, NULL, fin, NULL, NULL, NULL, NULL, NULL, NULL, 0}
CLASS(settings_class, "PMPrintSettings", settings_finalize);
CLASS(paper_class, "PMPaper", paper_finalize);
CLASS(format_class, "PMPageFormat", format_finalize);
CLASS(printer_class, "PMPrinter", printer_finalize);
CLASS(session_class, "PMPrintSession", session_finalize);
CLASS(preset_class, "PMPreset", preset_finalize);

static CFTypeID settings_type, paper_type, format_type, printer_type, session_type, preset_type;

static void
register_types(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        settings_type = _CFRuntimeRegisterClass(&settings_class);
        paper_type = _CFRuntimeRegisterClass(&paper_class);
        format_type = _CFRuntimeRegisterClass(&format_class);
        printer_type = _CFRuntimeRegisterClass(&printer_class);
        session_type = _CFRuntimeRegisterClass(&session_class);
        preset_type = _CFRuntimeRegisterClass(&preset_class);
    });
}

static void *
make(CFTypeID *type, size_t size)
{
    register_types();
    return (void *)_CFRuntimeCreateInstance(NULL, *type, (CFIndex)(size - sizeof(CFRuntimeBase)), NULL);
}

#define IS(obj, type) ((obj) && (register_types(), CFGetTypeID((CFTypeRef)(obj)) == (type)))

static PMPrinter generic_printer(void);

PM_EXPORT OSStatus
PMRetain(PMObject object)
{
    if (!object)
        return kPMInvalidParameter;
    CFRetain(object);
    return noErr;
}

PM_EXPORT OSStatus
PMRelease(PMObject object)
{
    if (object)
        CFRelease(object);
    return noErr;
}

/* MARK: - Papers */

static const struct {
    const char *ident, *name;
    double width, height;
} standard_papers[] = {
    {"na-letter", "US Letter", 612, 792},
    {"na-legal", "US Legal", 612, 1008},
    {"iso-a4", "A4", 595, 842},
    {"iso-a5", "A5", 420, 595},
    {"jis-b5", "JIS B5", 516, 729},
    {"iso-b5", "B5", 499, 709},
    {"na-number-10-envelope", "Envelope #10", 297, 684},
    {"iso-designated", "Envelope DL", 312, 624},
    {"tabloid", "Tabloid", 792, 1224},
    {"iso-a3", "A3", 842, 1191},
};

#define GENERIC_ID CFSTR("")
static const PMPaperMargins standard_margins = {18, 18, 18, 18};

static PMPaper
paper_new(CFStringRef ident, CFStringRef name, CFStringRef printerID, double w, double h, const PMPaperMargins *m, bool custom)
{
    struct OpaquePMPaper *p = make(&paper_type, sizeof *p);
    p->ident = CFStringCreateCopy(NULL, ident ? ident : CFSTR(""));
    p->name = CFStringCreateCopy(NULL, name ? name : p->ident);
    p->printerID = printerID ? CFStringCreateCopy(NULL, printerID) : NULL;
    p->width = w, p->height = h;
    p->margins = m ? *m : (PMPaperMargins){0, 0, 0, 0};
    p->custom = custom;
    return p;
}

/* The paper a new page format starts with: letter where measurement is US, else A4 */
static PMPaper
default_paper(void)
{
    CFLocaleRef l = CFLocaleCopyCurrent();
    CFStringRef system = CFLocaleGetValue(l, kCFLocaleMeasurementSystem);
    bool us = system && CFEqual(system, CFSTR("U.S."));
    CFRelease(l);
    int i = us ? 0 : 2;
    CFStringRef ident = CFStringCreateWithCString(NULL, standard_papers[i].ident, kCFStringEncodingUTF8);
    CFStringRef name = CFStringCreateWithCString(NULL, standard_papers[i].name, kCFStringEncodingUTF8);
    PMPaper p = paper_new(ident, name, GENERIC_ID, standard_papers[i].width, standard_papers[i].height, &standard_margins, false);
    CFRelease(ident), CFRelease(name);
    return p;
}

PM_EXPORT OSStatus
PMPaperCreateCustom(PMPrinter printer, CFStringRef id, CFStringRef name, double width, double height, const PMPaperMargins *margins,
                    PMPaper *paperP)
{
    if (!paperP || !id || width <= 0 || height <= 0)
        return kPMInvalidParameter;
    *paperP = paper_new(id, name, printer ? PMPrinterGetID(printer) : NULL, width, height, margins, true);
    return noErr;
}

PM_EXPORT OSStatus
PMPaperGetWidth(PMPaper paper, double *w)
{
    if (!IS(paper, paper_type) || !w)
        return kPMInvalidParameter;
    *w = paper->width;
    return noErr;
}

PM_EXPORT OSStatus
PMPaperGetHeight(PMPaper paper, double *h)
{
    if (!IS(paper, paper_type) || !h)
        return kPMInvalidParameter;
    *h = paper->height;
    return noErr;
}

PM_EXPORT OSStatus
PMPaperGetMargins(PMPaper paper, PMPaperMargins *m)
{
    if (!IS(paper, paper_type) || !m)
        return kPMInvalidParameter;
    *m = paper->margins;
    return noErr;
}

PM_EXPORT OSStatus
PMPaperGetID(PMPaper paper, CFStringRef *id)
{
    if (!IS(paper, paper_type) || !id)
        return kPMInvalidParameter;
    *id = paper->ident;
    return noErr;
}

PM_EXPORT OSStatus
PMPaperGetPPDPaperName(PMPaper paper, CFStringRef *name)
{
    if (!IS(paper, paper_type) || !name)
        return kPMInvalidParameter;
    *name = paper->ident;
    return noErr;
}

PM_EXPORT OSStatus
PMPaperCreateLocalizedName(PMPaper paper, PMPrinter printer, CFStringRef *name)
{
    if (!IS(paper, paper_type) || !name)
        return kPMInvalidParameter;
    *name = CFStringCreateCopy(NULL, paper->name);
    return noErr;
}

PM_EXPORT OSStatus
PMPaperGetPrinterID(PMPaper paper, CFStringRef *id)
{
    if (!IS(paper, paper_type) || !id)
        return kPMInvalidParameter;
    *id = paper->printerID;
    return noErr;
}

PM_EXPORT Boolean
PMPaperIsCustom(PMPaper paper)
{
    return IS(paper, paper_type) && paper->custom;
}

/* MARK: - Page formats */

/* The page (imageable) and paper rectangles: the paper's size less its margins, turned
   for landscape, scaled up by the inverse of the scale; the page at the origin, the paper
   around it. */
static void
compute_rects(PMPageFormat f)
{
    PMPaper p = f->paper;
    double w = p ? p->width : 0, h = p ? p->height : 0;
    PMPaperMargins m = p ? p->margins : (PMPaperMargins){0, 0, 0, 0};
    if (f->orientation == kPMLandscape || f->orientation == kPMReverseLandscape) {
        double t = w;
        w = h, h = t;
        m = (PMPaperMargins){m.right, m.top, m.left, m.bottom}; /* (turned as Apple's turns them) */
    }
    double k = f->scale > 0 ? 100 / f->scale : 1;
    f->pageRect = (PMRect){0, 0, (h - m.top - m.bottom) * k, (w - m.left - m.right) * k};
    f->paperRect = (PMRect){-m.top * k, -m.left * k, (h - m.top) * k, (w - m.left) * k};
}

static PMPageFormat
format_new(PMPaper paper)
{
    struct OpaquePMPageFormat *f = make(&format_type, sizeof *f);
    f->paper = paper ? (PMPaper)CFRetain(paper) : paper_new(CFSTR("Unknown"), CFSTR("Unknown"), NULL, 0, 0, NULL, false);
    f->orientation = kPMPortrait;
    f->scale = 100;
    f->extended = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    compute_rects(f);
    return f;
}

PM_EXPORT OSStatus
PMCreatePageFormat(PMPageFormat *pageFormat)
{
    if (!pageFormat)
        return kPMInvalidParameter;
    *pageFormat = format_new(NULL);
    return noErr;
}

PM_EXPORT OSStatus
PMCreatePageFormatWithPMPaper(PMPageFormat *pageFormat, PMPaper paper)
{
    if (!pageFormat || !IS(paper, paper_type))
        return kPMInvalidParameter;
    *pageFormat = format_new(paper);
    return noErr;
}

PM_EXPORT OSStatus
PMCopyPageFormat(PMPageFormat src, PMPageFormat dst)
{
    if (!IS(src, format_type) || !IS(dst, format_type))
        return kPMInvalidPageFormat;
    CFRetain(src->paper);
    CFRelease(dst->paper);
    dst->paper = src->paper;
    dst->orientation = src->orientation, dst->scale = src->scale;
    dst->pageRect = src->pageRect, dst->paperRect = src->paperRect;
    CFRelease(dst->extended);
    dst->extended = CFDictionaryCreateMutableCopy(NULL, 0, src->extended);
    return noErr;
}

PM_EXPORT OSStatus
PMGetPageFormatPaper(PMPageFormat f, PMPaper *paper)
{
    if (!IS(f, format_type) || !paper)
        return kPMInvalidPageFormat;
    *paper = f->paper;
    return noErr;
}

PM_EXPORT OSStatus
PMGetOrientation(PMPageFormat f, PMOrientation *o)
{
    if (!IS(f, format_type) || !o)
        return kPMInvalidPageFormat;
    *o = f->orientation;
    return noErr;
}

PM_EXPORT OSStatus
PMSetOrientation(PMPageFormat f, PMOrientation o, Boolean lock)
{
    if (!IS(f, format_type))
        return kPMInvalidPageFormat;
    if (o < kPMPortrait || o > kPMReverseLandscape)
        return kPMValueOutOfRange;
    f->orientation = o;
    return noErr;
}

PM_EXPORT OSStatus
PMGetScale(PMPageFormat f, double *scale)
{
    if (!IS(f, format_type) || !scale)
        return kPMInvalidPageFormat;
    *scale = f->scale;
    return noErr;
}

PM_EXPORT OSStatus
PMSetScale(PMPageFormat f, double scale)
{
    if (!IS(f, format_type))
        return kPMInvalidPageFormat;
    if (scale <= 0)
        return kPMValueOutOfRange;
    f->scale = scale;
    return noErr;
}

PM_EXPORT OSStatus
PMGetAdjustedPageRect(PMPageFormat f, PMRect *r)
{
    if (!IS(f, format_type) || !r)
        return kPMInvalidPageFormat;
    *r = f->pageRect;
    return noErr;
}

PM_EXPORT OSStatus
PMGetAdjustedPaperRect(PMPageFormat f, PMRect *r)
{
    if (!IS(f, format_type) || !r)
        return kPMInvalidPageFormat;
    *r = f->paperRect;
    return noErr;
}

PM_EXPORT OSStatus
PMGetUnadjustedPageRect(PMPageFormat f, PMRect *r)
{
    return PMGetAdjustedPageRect(f, r);
}

PM_EXPORT OSStatus
PMGetUnadjustedPaperRect(PMPageFormat f, PMRect *r)
{
    return PMGetAdjustedPaperRect(f, r);
}

PM_EXPORT OSStatus
PMPageFormatGetPrinterID(PMPageFormat f, CFStringRef *id)
{
    if (!IS(f, format_type) || !id)
        return kPMInvalidPageFormat;
    *id = f->paper->printerID;
    return noErr;
}

PM_EXPORT OSStatus
PMGetPageFormatExtendedData(PMPageFormat f, OSType dataID, UInt32 *size, void *buffer)
{
    if (!IS(f, format_type) || !size)
        return kPMInvalidPageFormat;
    CFNumberRef key = CFNumberCreate(NULL, kCFNumberSInt32Type, &dataID);
    CFDataRef d = CFDictionaryGetValue(f->extended, key);
    CFRelease(key);
    if (!d)
        return kPMNoSuchEntry;
    if (buffer)
        CFDataGetBytes(d, CFRangeMake(0, CFDataGetLength(d) < (CFIndex)*size ? CFDataGetLength(d) : (CFIndex)*size), buffer);
    *size = (UInt32)CFDataGetLength(d);
    return noErr;
}

PM_EXPORT OSStatus
PMSetPageFormatExtendedData(PMPageFormat f, OSType dataID, UInt32 size, void *data)
{
    if (!IS(f, format_type) || (!data && size))
        return kPMInvalidPageFormat;
    CFNumberRef key = CFNumberCreate(NULL, kCFNumberSInt32Type, &dataID);
    CFDataRef d = CFDataCreate(NULL, data, size);
    CFDictionarySetValue(f->extended, key, d);
    CFRelease(key), CFRelease(d);
    return noErr;
}

/* A page format as a property list: its paper, orientation and scale. */
PM_EXPORT OSStatus
PMPageFormatCreateDataRepresentation(PMPageFormat f, CFDataRef *data, PMDataFormat format)
{
    if (!IS(f, format_type) || !data)
        return kPMInvalidPageFormat;
    PMPaper p = f->paper;
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int o = f->orientation;
    CFNumberRef n;
    n = CFNumberCreate(NULL, kCFNumberIntType, &o), CFDictionarySetValue(d, KEY("PageFormat.PMOrientation"), n), CFRelease(n);
    n = CFNumberCreate(NULL, kCFNumberDoubleType, &f->scale), CFDictionarySetValue(d, KEY("PageFormat.PMScaling"), n), CFRelease(n);
    CFDictionarySetValue(d, KEY("PaperInfo.PMPaperName"), p->ident);
    CFDictionarySetValue(d, KEY("PaperInfo.PMLocalizedPaperName"), p->name);
    double v[6] = {p->width, p->height, p->margins.top, p->margins.left, p->margins.bottom, p->margins.right};
    const char *names[6] = {"Width", "Height", "MarginTop", "MarginLeft", "MarginBottom", "MarginRight"};
    for (int i = 0; i < 6; i++) {
        CFStringRef k = CFStringCreateWithFormat(NULL, NULL, CFSTR("com.apple.print.PaperInfo.PMPaper%s"), names[i]);
        n = CFNumberCreate(NULL, kCFNumberDoubleType, &v[i]);
        CFDictionarySetValue(d, k, n);
        CFRelease(k), CFRelease(n);
    }
    CFDictionarySetValue(d, K_TICKET, KEY("PageFormatTicket"));
    *data = CFPropertyListCreateData(NULL, d, format == kPMDataFormatXMLDefault ? kCFPropertyListXMLFormat_v1_0 : kCFPropertyListBinaryFormat_v1_0,
                                     0, NULL);
    CFRelease(d);
    return *data ? noErr : kPMGeneralError;
}

static double
dict_double(CFDictionaryRef d, CFStringRef key, double fallback)
{
    CFNumberRef n = CFDictionaryGetValue(d, key);
    double v = fallback;
    if (n && CFGetTypeID(n) == CFNumberGetTypeID())
        CFNumberGetValue(n, kCFNumberDoubleType, &v);
    return v;
}

PM_EXPORT OSStatus
PMPageFormatCreateWithDataRepresentation(CFDataRef data, PMPageFormat *pageFormat)
{
    if (!data || !pageFormat)
        return kPMInvalidParameter;
    CFDictionaryRef d = CFPropertyListCreateWithData(NULL, data, kCFPropertyListImmutable, NULL, NULL);
    if (!d || CFGetTypeID(d) != CFDictionaryGetTypeID()) {
        if (d)
            CFRelease(d);
        return kPMInvalidParameter;
    }
    CFStringRef ident = CFDictionaryGetValue(d, KEY("PaperInfo.PMPaperName"));
    CFStringRef name = CFDictionaryGetValue(d, KEY("PaperInfo.PMLocalizedPaperName"));
    PMPaperMargins m = {dict_double(d, KEY("PaperInfo.PMPaperMarginTop"), 0), dict_double(d, KEY("PaperInfo.PMPaperMarginLeft"), 0),
                        dict_double(d, KEY("PaperInfo.PMPaperMarginBottom"), 0), dict_double(d, KEY("PaperInfo.PMPaperMarginRight"), 0)};
    PMPaper p = paper_new(ident, name, NULL, dict_double(d, KEY("PaperInfo.PMPaperWidth"), 0),
                          dict_double(d, KEY("PaperInfo.PMPaperHeight"), 0), &m, false);
    PMPageFormat f = format_new(p);
    CFRelease(p);
    f->orientation = (PMOrientation)dict_double(d, KEY("PageFormat.PMOrientation"), kPMPortrait);
    f->scale = dict_double(d, KEY("PageFormat.PMScaling"), 100);
    compute_rects(f);
    CFRelease(d);
    *pageFormat = f;
    return noErr;
}

/* MARK: - Print settings */

static PMPrintSettings
settings_new(void)
{
    struct OpaquePMPrintSettings *s = make(&settings_type, sizeof *s);
    s->dict = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(s->dict, K_TICKET, KEY("PrintSettingsTicket"));
    return s;
}

PM_EXPORT OSStatus
PMCreatePrintSettings(PMPrintSettings *ps)
{
    if (!ps)
        return kPMInvalidParameter;
    *ps = settings_new();
    return noErr;
}

PM_EXPORT OSStatus
PMCopyPrintSettings(PMPrintSettings src, PMPrintSettings dst)
{
    if (!IS(src, settings_type) || !IS(dst, settings_type))
        return kPMInvalidPrintSettings;
    CFRelease(dst->dict);
    dst->dict = CFDictionaryCreateMutableCopy(NULL, 0, src->dict);
    return noErr;
}

static void
set_uint(PMPrintSettings s, CFStringRef key, UInt32 v)
{
    SInt64 x = v;
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt64Type, &x);
    CFDictionarySetValue(s->dict, key, n);
    CFRelease(n);
}

static UInt32
get_uint(PMPrintSettings s, CFStringRef key, UInt32 fallback)
{
    CFNumberRef n = CFDictionaryGetValue(s->dict, key);
    SInt64 x = fallback;
    if (n && CFGetTypeID(n) == CFNumberGetTypeID())
        CFNumberGetValue(n, kCFNumberSInt64Type, &x);
    else if (n && CFGetTypeID(n) == CFBooleanGetTypeID())
        x = CFBooleanGetValue((CFBooleanRef)n);
    return (UInt32)x;
}

#define SETTINGS_CHECK(s)            \
    if (!IS(s, settings_type))       \
        return kPMInvalidPrintSettings;

PM_EXPORT OSStatus
PMGetCopies(PMPrintSettings s, UInt32 *copies)
{
    SETTINGS_CHECK(s);
    if (!copies)
        return kPMInvalidParameter;
    *copies = get_uint(s, K_COPIES, 0);
    return noErr;
}

PM_EXPORT OSStatus
PMSetCopies(PMPrintSettings s, UInt32 copies, Boolean lock)
{
    SETTINGS_CHECK(s);
    set_uint(s, K_COPIES, copies);
    return noErr;
}

PM_EXPORT OSStatus
PMGetCollate(PMPrintSettings s, Boolean *collate)
{
    SETTINGS_CHECK(s);
    if (!collate)
        return kPMInvalidParameter;
    *collate = get_uint(s, K_COLLATE, 0) != 0;
    return noErr;
}

PM_EXPORT OSStatus
PMSetCollate(PMPrintSettings s, Boolean collate)
{
    SETTINGS_CHECK(s);
    CFDictionarySetValue(s->dict, K_COLLATE, collate ? kCFBooleanTrue : kCFBooleanFalse);
    return noErr;
}

PM_EXPORT OSStatus
PMGetFirstPage(PMPrintSettings s, UInt32 *first)
{
    SETTINGS_CHECK(s);
    if (!first)
        return kPMInvalidParameter;
    *first = get_uint(s, K_FIRST, 0);
    return noErr;
}

PM_EXPORT OSStatus
PMSetFirstPage(PMPrintSettings s, UInt32 first, Boolean lock)
{
    SETTINGS_CHECK(s);
    set_uint(s, K_FIRST, first);
    return noErr;
}

PM_EXPORT OSStatus
PMGetLastPage(PMPrintSettings s, UInt32 *last)
{
    SETTINGS_CHECK(s);
    if (!last)
        return kPMInvalidParameter;
    *last = get_uint(s, K_LAST, 0);
    return noErr;
}

PM_EXPORT OSStatus
PMSetLastPage(PMPrintSettings s, UInt32 last, Boolean lock)
{
    SETTINGS_CHECK(s);
    set_uint(s, K_LAST, last == (UInt32)kPMPrintAllPages ? ALL_PAGES : last);
    return noErr;
}

PM_EXPORT OSStatus
PMGetPageRange(PMPrintSettings s, UInt32 *minPage, UInt32 *maxPage)
{
    SETTINGS_CHECK(s);
    CFArrayRef r = CFDictionaryGetValue(s->dict, K_RANGE);
    UInt32 lo = 0, hi = 0;
    if (r && CFGetTypeID(r) == CFArrayGetTypeID() && CFArrayGetCount(r) == 2) {
        SInt64 a = 0, b = 0;
        CFNumberGetValue(CFArrayGetValueAtIndex(r, 0), kCFNumberSInt64Type, &a);
        CFNumberGetValue(CFArrayGetValueAtIndex(r, 1), kCFNumberSInt64Type, &b);
        lo = (UInt32)a, hi = (UInt32)b;
    }
    if (minPage)
        *minPage = lo;
    if (maxPage)
        *maxPage = hi;
    return noErr;
}

PM_EXPORT OSStatus
PMSetPageRange(PMPrintSettings s, UInt32 minPage, UInt32 maxPage)
{
    SETTINGS_CHECK(s);
    if (maxPage == (UInt32)kPMPrintAllPages)
        maxPage = ALL_PAGES;
    if (minPage > maxPage)
        return kPMValueOutOfRange;
    SInt64 a = minPage, b = maxPage;
    CFNumberRef n[2] = {CFNumberCreate(NULL, kCFNumberSInt64Type, &a), CFNumberCreate(NULL, kCFNumberSInt64Type, &b)};
    CFArrayRef r = CFArrayCreate(NULL, (const void **)n, 2, &kCFTypeArrayCallBacks);
    CFDictionarySetValue(s->dict, K_RANGE, r);
    CFRelease(r), CFRelease(n[0]), CFRelease(n[1]);
    return noErr;
}

PM_EXPORT OSStatus
PMGetDuplex(PMPrintSettings s, PMDuplexMode *mode)
{
    SETTINGS_CHECK(s);
    if (!mode)
        return kPMInvalidParameter;
    *mode = get_uint(s, K_DUPLEX, kPMDuplexNone);
    return noErr;
}

PM_EXPORT OSStatus
PMSetDuplex(PMPrintSettings s, PMDuplexMode mode)
{
    SETTINGS_CHECK(s);
    set_uint(s, K_DUPLEX, mode);
    return noErr;
}

PM_EXPORT OSStatus
PMPrintSettingsGetJobName(PMPrintSettings s, CFStringRef *name)
{
    SETTINGS_CHECK(s);
    if (!name)
        return kPMInvalidParameter;
    *name = CFDictionaryGetValue(s->dict, K_JOB);
    return noErr;
}

PM_EXPORT OSStatus
PMPrintSettingsSetJobName(PMPrintSettings s, CFStringRef name)
{
    SETTINGS_CHECK(s);
    if (name)
        CFDictionarySetValue(s->dict, K_JOB, name);
    else
        CFDictionaryRemoveValue(s->dict, K_JOB);
    return noErr;
}

PM_EXPORT OSStatus
PMPrintSettingsGetValue(PMPrintSettings s, CFStringRef key, CFTypeRef *value)
{
    SETTINGS_CHECK(s);
    if (!key || !value)
        return kPMInvalidParameter;
    *value = CFDictionaryGetValue(s->dict, key);
    return noErr;
}

PM_EXPORT OSStatus
PMPrintSettingsSetValue(PMPrintSettings s, CFStringRef key, CFTypeRef value, Boolean locked)
{
    SETTINGS_CHECK(s);
    if (!key)
        return kPMInvalidParameter;
    if (value)
        CFDictionarySetValue(s->dict, key, value);
    else
        CFDictionaryRemoveValue(s->dict, key);
    return noErr;
}

PM_EXPORT OSStatus
PMPrintSettingsCopyAsDictionary(PMPrintSettings s, CFDictionaryRef *dict)
{
    SETTINGS_CHECK(s);
    if (!dict)
        return kPMInvalidParameter;
    *dict = CFDictionaryCreateCopy(NULL, s->dict);
    return noErr;
}

PM_EXPORT OSStatus
PMPrintSettingsCopyKeys(PMPrintSettings s, CFArrayRef *keys)
{
    SETTINGS_CHECK(s);
    if (!keys)
        return kPMInvalidParameter;
    CFIndex n = CFDictionaryGetCount(s->dict);
    const void **k = malloc(sizeof(void *) * (size_t)(n ? n : 1));
    CFDictionaryGetKeysAndValues(s->dict, k, NULL);
    *keys = CFArrayCreate(NULL, k, n, &kCFTypeArrayCallBacks);
    free(k);
    return noErr;
}

PM_EXPORT OSStatus
PMPrintSettingsCreateDataRepresentation(PMPrintSettings s, CFDataRef *data, PMDataFormat format)
{
    SETTINGS_CHECK(s);
    if (!data)
        return kPMInvalidParameter;
    *data = CFPropertyListCreateData(NULL, s->dict,
                                     format == kPMDataFormatXMLDefault ? kCFPropertyListXMLFormat_v1_0 : kCFPropertyListBinaryFormat_v1_0, 0, NULL);
    return *data ? noErr : kPMGeneralError;
}

PM_EXPORT OSStatus
PMPrintSettingsCreateWithDataRepresentation(CFDataRef data, PMPrintSettings *ps)
{
    if (!data || !ps)
        return kPMInvalidParameter;
    CFPropertyListRef d = CFPropertyListCreateWithData(NULL, data, kCFPropertyListMutableContainers, NULL, NULL);
    if (!d || CFGetTypeID(d) != CFDictionaryGetTypeID()) {
        if (d)
            CFRelease(d);
        return kPMInvalidParameter;
    }
    PMPrintSettings s = settings_new();
    CFRelease(s->dict);
    s->dict = (CFMutableDictionaryRef)d;
    *ps = s;
    return noErr;
}

/* The settings as CUPS job options ("copies=2 Collate=True page-ranges=1-3 ..."). */
static CFStringRef
settings_options(PMPrintSettings s, PMPageFormat f)
{
    CFMutableStringRef o = CFStringCreateMutable(NULL, 0);
    UInt32 copies = get_uint(s, K_COPIES, 1), first = get_uint(s, K_FIRST, 1), last = get_uint(s, K_LAST, ALL_PAGES);
    CFStringAppendFormat(o, NULL, CFSTR("copies=%u Collate=%s"), copies ? copies : 1, get_uint(s, K_COLLATE, 1) ? "True" : "False");
    if (first > 1 || last != ALL_PAGES)
        CFStringAppendFormat(o, NULL, CFSTR(" page-ranges=%u-%u"), first ? first : 1, last);
    PMDuplexMode d = get_uint(s, K_DUPLEX, kPMDuplexNone);
    CFStringAppendFormat(o, NULL, CFSTR(" sides=%s"), d == kPMDuplexNoTumble ? "two-sided-long-edge"
                                                      : d == kPMDuplexTumble ? "two-sided-short-edge"
                                                                             : "one-sided");
    if (f) {
        CFStringAppendFormat(o, NULL, CFSTR(" media=%@"), f->paper->ident);
        if (f->orientation == kPMLandscape || f->orientation == kPMReverseLandscape)
            CFStringAppend(o, CFSTR(" landscape"));
    }
    return o;
}

PM_EXPORT OSStatus
PMPrintSettingsToOptionsWithPrinterAndPageFormat(PMPrintSettings s, PMPrinter printer, PMPageFormat f, char **options)
{
    SETTINGS_CHECK(s);
    if (!options)
        return kPMInvalidParameter;
    CFStringRef o = settings_options(s, IS(f, format_type) ? f : NULL);
    CFIndex max = CFStringGetMaximumSizeForEncoding(CFStringGetLength(o), kCFStringEncodingUTF8) + 1;
    *options = malloc((size_t)max);
    CFStringGetCString(o, *options, max, kCFStringEncodingUTF8);
    CFRelease(o);
    return noErr;
}

PM_EXPORT OSStatus
PMPrintSettingsToOptions(PMPrintSettings s, char **options)
{
    return PMPrintSettingsToOptionsWithPrinterAndPageFormat(s, (PMPrinter)generic_printer(), NULL, options);
}

/* MARK: - Printers (only the generic one: Finch has no printing system yet) */

static PMPrinter
generic_printer(void)
{
    static PMPrinter generic;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        struct OpaquePMPrinter *p = make(&printer_type, sizeof *p);
        p->name = CFSTR("");
        p->ident = CFSTR("");
        p->resolution = (PMResolution){300, 300};
        generic = p;
    });
    return generic;
}

PM_EXPORT OSStatus
PMCreateGenericPrinter(PMPrinter *printer)
{
    if (!printer)
        return kPMInvalidParameter;
    *printer = (PMPrinter)CFRetain(generic_printer());
    return noErr;
}

PM_EXPORT OSStatus
PMServerCreatePrinterList(PMServer server, CFArrayRef *printerList)
{
    if (!printerList)
        return kPMInvalidParameter;
    *printerList = CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
    return noErr;
}

PM_EXPORT OSStatus
PMServerLaunchPrinterBrowser(PMServer server, CFDictionaryRef options)
{
    return kPMNotImplemented;
}

PM_EXPORT PMPrinter
PMPrinterCreateFromPrinterID(CFStringRef printerID)
{
    if (printerID && CFEqual(printerID, CFSTR("")))
        return (PMPrinter)CFRetain(generic_printer());
    return NULL; /* (no printers by that name) */
}

#define PRINTER_CHECK(p)           \
    if (!IS(p, printer_type))      \
        return kPMInvalidPrinter;

PM_EXPORT CFStringRef
PMPrinterGetName(PMPrinter p)
{
    return IS(p, printer_type) ? p->name : NULL;
}

PM_EXPORT CFStringRef
PMPrinterGetID(PMPrinter p)
{
    return IS(p, printer_type) ? p->ident : NULL;
}

PM_EXPORT Boolean PMPrinterIsDefault(PMPrinter p) { return false; }
PM_EXPORT Boolean PMPrinterIsFavorite(PMPrinter p) { return false; }
PM_EXPORT Boolean PMPrinterIsPostScriptCapable(PMPrinter p) { return IS(p, printer_type); }
PM_EXPORT CFStringRef PMPrinterGetLocation(PMPrinter p) { return NULL; }

PM_EXPORT OSStatus
PMPrinterIsPostScriptPrinter(PMPrinter p, Boolean *isPS)
{
    PRINTER_CHECK(p);
    if (!isPS)
        return kPMInvalidParameter;
    *isPS = false;
    return noErr;
}

PM_EXPORT OSStatus
PMPrinterIsRemote(PMPrinter p, Boolean *isRemote)
{
    PRINTER_CHECK(p);
    if (!isRemote)
        return kPMInvalidParameter;
    *isRemote = false;
    return noErr;
}

PM_EXPORT OSStatus
PMPrinterSetDefault(PMPrinter p)
{
    PRINTER_CHECK(p);
    return kPMInvalidPrinter;
}

PM_EXPORT OSStatus
PMPrinterGetState(PMPrinter p, PMPrinterState *state)
{
    PRINTER_CHECK(p);
    if (!state)
        return kPMInvalidParameter;
    *state = kPMPrinterIdle;
    return noErr;
}

PM_EXPORT OSStatus
PMPrinterCopyState(PMPrinter p, CFDictionaryRef *state)
{
    PRINTER_CHECK(p);
    if (!state)
        return kPMInvalidParameter;
    *state = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    return noErr;
}

PM_EXPORT OSStatus
PMPrinterGetMakeAndModelName(PMPrinter p, CFStringRef *model)
{
    PRINTER_CHECK(p);
    if (!model)
        return kPMInvalidParameter;
    *model = NULL;
    return noErr;
}

PM_EXPORT OSStatus
PMPrinterGetPrinterResolutionCount(PMPrinter p, UInt32 *count)
{
    PRINTER_CHECK(p);
    if (!count)
        return kPMInvalidParameter;
    *count = 1;
    return noErr;
}

PM_EXPORT OSStatus
PMPrinterGetIndexedPrinterResolution(PMPrinter p, UInt32 index, PMResolution *res)
{
    PRINTER_CHECK(p);
    if (!res || index != 1)
        return kPMValueOutOfRange;
    *res = p->resolution;
    return noErr;
}

PM_EXPORT OSStatus
PMPrinterGetOutputResolution(PMPrinter p, PMPrintSettings s, PMResolution *res)
{
    PRINTER_CHECK(p);
    if (!res)
        return kPMInvalidParameter;
    *res = p->resolution;
    return noErr;
}

PM_EXPORT OSStatus
PMPrinterSetOutputResolution(PMPrinter p, PMPrintSettings s, const PMResolution *res)
{
    PRINTER_CHECK(p);
    return res ? noErr : kPMInvalidParameter;
}

PM_EXPORT OSStatus
PMPrinterGetPaperList(PMPrinter p, CFArrayRef *list)
{
    PRINTER_CHECK(p);
    if (!list)
        return kPMInvalidParameter;
    static CFArrayRef papers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CFMutableArrayRef a = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
        for (size_t i = 0; i < sizeof standard_papers / sizeof standard_papers[0]; i++) {
            CFStringRef ident = CFStringCreateWithCString(NULL, standard_papers[i].ident, kCFStringEncodingUTF8);
            CFStringRef name = CFStringCreateWithCString(NULL, standard_papers[i].name, kCFStringEncodingUTF8);
            PMPaper paper = paper_new(ident, name, GENERIC_ID, standard_papers[i].width, standard_papers[i].height, &standard_margins, false);
            CFArrayAppendValue(a, paper);
            CFRelease(paper), CFRelease(ident), CFRelease(name);
        }
        papers = a;
    });
    *list = papers;
    return noErr;
}

PM_EXPORT OSStatus
PMPrinterGetMimeTypes(PMPrinter p, PMPrintSettings s, CFArrayRef *types)
{
    PRINTER_CHECK(p);
    if (!types)
        return kPMInvalidParameter;
    static CFArrayRef mimes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const void *v[] = {CFSTR("application/pdf"), CFSTR("application/postscript")};
        mimes = CFArrayCreate(NULL, v, 2, &kCFTypeArrayCallBacks);
    });
    *types = mimes;
    return noErr;
}

PM_EXPORT OSStatus
PMPrinterCopyPresets(PMPrinter p, CFArrayRef *presets)
{
    PRINTER_CHECK(p);
    if (!presets)
        return kPMInvalidParameter;
    *presets = CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
    return noErr;
}

PM_EXPORT OSStatus
PMPrinterCopyDescriptionURL(PMPrinter p, CFStringRef descriptionType, CFURLRef *url)
{
    PRINTER_CHECK(p);
    if (url)
        *url = NULL;
    return kPMInvalidParameter;
}

PM_EXPORT OSStatus
PMPrinterCopyDeviceURI(PMPrinter p, CFURLRef *uri)
{
    PRINTER_CHECK(p);
    if (uri)
        *uri = NULL;
    return kPMInvalidParameter;
}

PM_EXPORT OSStatus
PMPrinterCopyHostName(PMPrinter p, CFStringRef *host)
{
    PRINTER_CHECK(p);
    if (host)
        *host = NULL;
    return kPMInvalidParameter;
}

PM_EXPORT OSStatus
PMPrinterGetCommInfo(PMPrinter p, Boolean *supportsTransparent, Boolean *supportsEightBit)
{
    PRINTER_CHECK(p);
    if (supportsTransparent)
        *supportsTransparent = false;
    if (supportsEightBit)
        *supportsEightBit = true;
    return noErr;
}

PM_EXPORT OSStatus
PMPrinterGetDriverCreator(PMPrinter p, OSType *creator)
{
    PRINTER_CHECK(p);
    if (creator)
        *creator = 'APPL';
    return noErr;
}

PM_EXPORT OSStatus
PMPrinterGetDriverReleaseInfo(PMPrinter p, VersRec *info)
{
    PRINTER_CHECK(p);
    if (info)
        memset(info, 0, sizeof *info);
    return noErr;
}

PM_EXPORT OSStatus
PMPrinterGetLanguageInfo(PMPrinter p, PMLanguageInfo *info)
{
    PRINTER_CHECK(p);
    if (info)
        memset(info, 0, sizeof *info);
    return noErr;
}

/* Printing needs a printing system, which Finch doesn't have yet. */
PM_EXPORT OSStatus
PMPrinterPrintWithFile(PMPrinter p, PMPrintSettings s, PMPageFormat f, CFStringRef mimeType, CFURLRef fileURL)
{
    PRINTER_CHECK(p);
    return kPMInvalidPrinter;
}

PM_EXPORT OSStatus
PMPrinterPrintWithProvider(PMPrinter p, PMPrintSettings s, PMPageFormat f, CFStringRef mimeType, CGDataProviderRef provider)
{
    PRINTER_CHECK(p);
    return kPMInvalidPrinter;
}

PM_EXPORT OSStatus
PMPrinterWritePostScriptToURL(PMPrinter p, PMPrintSettings s, PMPageFormat f, CFStringRef mimeType, CFURLRef source, CFURLRef dest)
{
    PRINTER_CHECK(p);
    return kPMNotImplemented;
}

PM_EXPORT OSStatus
PMPrinterSendCommand(PMPrinter p, CFStringRef command, CFStringRef jobTitle, CFDictionaryRef options)
{
    PRINTER_CHECK(p);
    return kPMInvalidPrinter;
}

/* (private) */
PM_EXPORT OSStatus
PMPrinterSupportsMatchingMode(PMPrinter p, int mode, Boolean *supported)
{
    PRINTER_CHECK(p);
    if (!supported)
        return kPMInvalidParameter;
    *supported = true;
    return noErr;
}

PM_EXPORT Boolean PMPrinterIsFax(PMPrinter p) { return false; }
PM_EXPORT Boolean PMPrinterIsAirPrint(PMPrinter p) { return false; }
PM_EXPORT Boolean PMPrinterIsDirectConnect(PMPrinter p) { return false; }

/* MARK: - Presets (printers have none yet) */

PM_EXPORT OSStatus
PMPresetCopyName(PMPreset preset, CFStringRef *name)
{
    if (!IS(preset, preset_type) || !name)
        return kPMInvalidPreset;
    *name = CFRetain(preset->name);
    return noErr;
}

PM_EXPORT OSStatus
PMPresetGetAttributes(PMPreset preset, CFDictionaryRef *attributes)
{
    if (!IS(preset, preset_type) || !attributes)
        return kPMInvalidPreset;
    *attributes = preset->attributes;
    return noErr;
}

PM_EXPORT OSStatus
PMPresetCreatePrintSettings(PMPreset preset, PMPrintSession session, PMPrintSettings *ps)
{
    if (!IS(preset, preset_type) || !ps)
        return kPMInvalidPreset;
    return PMCreatePrintSettings(ps);
}

/* MARK: - PPDs and workflows (none) */

PM_EXPORT OSStatus
PMCopyAvailablePPDs(PMPPDDomain domain, CFArrayRef *ppds)
{
    if (!ppds)
        return kPMInvalidParameter;
    *ppds = CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
    return noErr;
}

PM_EXPORT OSStatus
PMCopyLocalizedPPD(CFURLRef ppd, CFURLRef *localized)
{
    if (localized)
        *localized = NULL;
    return kPMInvalidParameter;
}

PM_EXPORT OSStatus
PMCopyPPDData(CFURLRef ppd, CFDataRef *data)
{
    if (data)
        *data = NULL;
    return kPMInvalidParameter;
}

PM_EXPORT OSStatus
PMWorkflowCopyItems(CFArrayRef *workflowItems)
{
    if (!workflowItems)
        return kPMInvalidParameter;
    *workflowItems = CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
    return noErr;
}

PM_EXPORT OSStatus
PMWorkflowSubmitPDFWithOptions(CFURLRef workflowItem, CFStringRef title, const char *options, CFURLRef pdfFile)
{
    return kPMNotImplemented;
}

PM_EXPORT OSStatus
PMWorkflowSubmitPDFWithSettings(CFURLRef workflowItem, PMPrintSettings settings, CFURLRef pdfFile)
{
    return kPMNotImplemented;
}

PM_EXPORT CGImageRef
PMCGImageCreateWithEPSDataProvider(CGDataProviderRef epsDataProvider, CGImageRef epsPreview)
{
    return epsPreview ? CGImageRetain(epsPreview) : NULL;
}

/* MARK: - Sessions */

PM_EXPORT OSStatus
PMCreateSession(PMPrintSession *session)
{
    if (!session)
        return kPMInvalidParameter;
    struct OpaquePMPrintSession *s = make(&session_type, sizeof *s);
    s->printer = (PMPrinter)CFRetain(generic_printer());
    s->data = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    *session = s;
    return noErr;
}

#define SESSION_CHECK(s)            \
    if (!IS(s, session_type))       \
        return kPMInvalidPrintSession;

PM_EXPORT OSStatus
PMSessionError(PMPrintSession s)
{
    SESSION_CHECK(s);
    return s->error;
}

PM_EXPORT OSStatus
PMSessionSetError(PMPrintSession s, OSStatus error)
{
    SESSION_CHECK(s);
    s->error = error;
    return noErr;
}

PM_EXPORT OSStatus
PMSessionDefaultPrintSettings(PMPrintSession s, PMPrintSettings ps)
{
    SESSION_CHECK(s);
    SETTINGS_CHECK(ps);
    set_uint(ps, K_COPIES, 1);
    CFDictionarySetValue(ps->dict, K_COLLATE, kCFBooleanTrue);
    set_uint(ps, K_FIRST, 1);
    set_uint(ps, K_LAST, ALL_PAGES);
    PMSetPageRange(ps, 1, ALL_PAGES);
    CFDictionarySetValue(ps->dict, K_SPOOL, CFSTR("application/pdf"));
    return noErr;
}

PM_EXPORT OSStatus
PMSessionDefaultPageFormat(PMPrintSession s, PMPageFormat f)
{
    SESSION_CHECK(s);
    if (!IS(f, format_type))
        return kPMInvalidPageFormat;
    PMPaper p = default_paper();
    CFRelease(f->paper);
    f->paper = p;
    f->orientation = kPMPortrait;
    f->scale = 100;
    compute_rects(f);
    return noErr;
}

PM_EXPORT OSStatus
PMSessionValidatePrintSettings(PMPrintSession s, PMPrintSettings ps, Boolean *changed)
{
    SESSION_CHECK(s);
    SETTINGS_CHECK(ps);
    if (changed)
        *changed = false;
    return noErr;
}

PM_EXPORT OSStatus
PMSessionValidatePageFormat(PMPrintSession s, PMPageFormat f, Boolean *changed)
{
    SESSION_CHECK(s);
    if (!IS(f, format_type))
        return kPMInvalidPageFormat;
    compute_rects(f);
    /* ("changed" is about values validation had to correct, which a generic printer never does) */
    if (changed)
        *changed = false;
    return noErr;
}

PM_EXPORT OSStatus
PMSessionGetCurrentPrinter(PMPrintSession s, PMPrinter *printer)
{
    SESSION_CHECK(s);
    if (!printer)
        return kPMInvalidParameter;
    *printer = s->printer;
    return noErr;
}

PM_EXPORT OSStatus
PMSessionSetCurrentPMPrinter(PMPrintSession s, PMPrinter printer)
{
    SESSION_CHECK(s);
    PRINTER_CHECK(printer);
    CFRetain(printer);
    CFRelease(s->printer);
    s->printer = printer;
    return noErr;
}

PM_EXPORT OSStatus
PMSessionCreatePrinterList(PMPrintSession s, CFArrayRef *printerList, CFIndex *currentIndex, PMPrinter *currentPrinter)
{
    SESSION_CHECK(s);
    if (!printerList)
        return kPMInvalidParameter;
    *printerList = CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
    if (currentIndex)
        *currentIndex = -1;
    if (currentPrinter)
        *currentPrinter = s->printer;
    return noErr;
}

PM_EXPORT OSStatus
PMSessionCreatePageFormatList(PMPrintSession s, PMPrinter printer, CFArrayRef *pageFormatList)
{
    SESSION_CHECK(s);
    if (!pageFormatList)
        return kPMInvalidParameter;
    CFArrayRef papers;
    OSStatus e = PMPrinterGetPaperList(printer ? printer : s->printer, &papers);
    if (e)
        return e;
    CFMutableArrayRef list = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < CFArrayGetCount(papers); i++) {
        PMPageFormat f = format_new((PMPaper)CFArrayGetValueAtIndex(papers, i));
        CFArrayAppendValue(list, f);
        CFRelease(f);
    }
    *pageFormatList = list;
    return noErr;
}

PM_EXPORT OSStatus
PMSessionGetDataFromSession(PMPrintSession s, CFStringRef key, CFTypeRef *data)
{
    SESSION_CHECK(s);
    if (!key || !data)
        return kPMInvalidParameter;
    *data = CFDictionaryGetValue(s->data, key);
    return *data ? noErr : kPMKeyNotFound;
}

PM_EXPORT OSStatus
PMSessionSetDataInSession(PMPrintSession s, CFStringRef key, CFTypeRef data)
{
    SESSION_CHECK(s);
    if (!key)
        return kPMInvalidParameter;
    if (data)
        CFDictionarySetValue(s->data, key, data);
    else
        CFDictionaryRemoveValue(s->data, key);
    return noErr;
}

PM_EXPORT OSStatus
PMSessionSetDestination(PMPrintSession s, PMPrintSettings ps, PMDestinationType type, CFStringRef format, CFURLRef location)
{
    SESSION_CHECK(s);
    SETTINGS_CHECK(ps);
    if (type < kPMDestinationPrinter || type > kPMDestinationProcessPDF)
        return kPMValueOutOfRange;
    set_uint(ps, K_DESTINATION, type);
    if (format)
        CFDictionarySetValue(ps->dict, K_OUTPUT_FORMAT, format);
    else
        CFDictionaryRemoveValue(ps->dict, K_OUTPUT_FORMAT);
    if (location) {
        CFStringRef path = CFURLCopyFileSystemPath(location, kCFURLPOSIXPathStyle);
        CFDictionarySetValue(ps->dict, K_OUTPUT_URL, path);
        CFRelease(path);
    } else {
        CFDictionaryRemoveValue(ps->dict, K_OUTPUT_URL);
    }
    return noErr;
}

PM_EXPORT OSStatus
PMSessionGetDestinationType(PMPrintSession s, PMPrintSettings ps, PMDestinationType *type)
{
    SESSION_CHECK(s);
    SETTINGS_CHECK(ps);
    if (!type)
        return kPMInvalidParameter;
    *type = get_uint(ps, K_DESTINATION, kPMDestinationPrinter);
    return noErr;
}

PM_EXPORT OSStatus
PMSessionCopyDestinationFormat(PMPrintSession s, PMPrintSettings ps, CFStringRef *format)
{
    SESSION_CHECK(s);
    SETTINGS_CHECK(ps);
    if (!format)
        return kPMInvalidParameter;
    CFStringRef f = CFDictionaryGetValue(ps->dict, K_OUTPUT_FORMAT);
    *format = f ? CFRetain(f) : NULL;
    return noErr;
}

PM_EXPORT OSStatus
PMSessionCopyDestinationLocation(PMPrintSession s, PMPrintSettings ps, CFURLRef *location)
{
    SESSION_CHECK(s);
    SETTINGS_CHECK(ps);
    if (!location)
        return kPMInvalidParameter;
    CFStringRef path = CFDictionaryGetValue(ps->dict, K_OUTPUT_URL);
    *location = path ? CFURLCreateWithFileSystemPath(NULL, path, kCFURLPOSIXPathStyle, false) : NULL;
    return noErr;
}

PM_EXPORT OSStatus
PMSessionCopyOutputFormatList(PMPrintSession s, PMDestinationType type, CFArrayRef *formats)
{
    SESSION_CHECK(s);
    if (!formats)
        return kPMInvalidParameter;
    const void *v[] = {CFSTR("application/pdf"), CFSTR("application/postscript")};
    *formats = CFArrayCreate(NULL, v, type == kPMDestinationFile ? 2 : 1, &kCFTypeArrayCallBacks);
    return noErr;
}

/* Drawing a document: into a PDF file when that's the destination. */
PM_EXPORT OSStatus
PMSessionBeginCGDocumentNoDialog(PMPrintSession s, PMPrintSettings ps, PMPageFormat f)
{
    SESSION_CHECK(s);
    SETTINGS_CHECK(ps);
    if (!IS(f, format_type))
        return kPMInvalidPageFormat;
    if (s->context)
        return kPMObjectInUse;
    PMDestinationType type = get_uint(ps, K_DESTINATION, kPMDestinationPrinter);
    CFStringRef path = CFDictionaryGetValue(ps->dict, K_OUTPUT_URL);
    if (type != kPMDestinationFile || !path)
        return s->error = kPMInvalidPrinter;
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, path, kCFURLPOSIXPathStyle, false);
    CGRect media = CGRectMake(0, 0, f->paperRect.right - f->paperRect.left, f->paperRect.bottom - f->paperRect.top);
    CFMutableDictionaryRef info = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFStringRef job = CFDictionaryGetValue(ps->dict, K_JOB);
    if (job)
        CFDictionarySetValue(info, kCGPDFContextTitle, job);
    s->context = CGPDFContextCreateWithURL(url, &media, info);
    CFRelease(info);
    CFRelease(url);
    if (!s->context)
        return s->error = kPMGeneralError;
    CFRetain(f);
    if (s->format)
        CFRelease(s->format);
    s->format = f;
    return noErr;
}

PM_EXPORT OSStatus
PMSessionBeginPageNoDialog(PMPrintSession s, PMPageFormat f, const PMRect *pageFrame)
{
    SESSION_CHECK(s);
    if (!s->context)
        return kPMOutOfScope;
    PMPageFormat pf = IS(f, format_type) ? f : s->format;
    CGRect media = CGRectMake(0, 0, pf->paperRect.right - pf->paperRect.left, pf->paperRect.bottom - pf->paperRect.top);
    CFDataRef box = CFDataCreate(NULL, (const UInt8 *)&media, sizeof media);
    const void *k[] = {kCGPDFContextMediaBox}, *v[] = {box};
    CFDictionaryRef page = CFDictionaryCreate(NULL, k, v, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CGPDFContextBeginPage(s->context, page);
    CFRelease(page), CFRelease(box);
    CGContextSaveGState(s->context);
    /* (the context's origin is the imageable area's corner, its units the page format's scale) */
    CGContextTranslateCTM(s->context, -pf->paperRect.left, media.size.height + pf->paperRect.top - (pf->pageRect.bottom - pf->pageRect.top));
    s->inPage = true;
    return noErr;
}

PM_EXPORT OSStatus
PMSessionGetCGGraphicsContext(PMPrintSession s, CGContextRef *context)
{
    SESSION_CHECK(s);
    if (!context)
        return kPMInvalidParameter;
    *context = s->inPage ? s->context : NULL;
    return s->inPage ? noErr : kPMOutOfScope;
}

PM_EXPORT OSStatus
PMSessionEndPageNoDialog(PMPrintSession s)
{
    SESSION_CHECK(s);
    if (!s->inPage)
        return kPMOutOfScope;
    CGContextRestoreGState(s->context);
    CGPDFContextEndPage(s->context);
    s->inPage = false;
    return noErr;
}

PM_EXPORT OSStatus
PMSessionEndDocumentNoDialog(PMPrintSession s)
{
    SESSION_CHECK(s);
    if (!s->context)
        return kPMOutOfScope;
    if (s->inPage)
        PMSessionEndPageNoDialog(s);
    CGPDFContextClose(s->context);
    CGContextRelease(s->context);
    s->context = NULL;
    return noErr;
}

/* MARK: - Colour matching (private calls ColorSync Utility makes) */

PM_EXPORT OSStatus
PMSessionGetColorMatchingMode(PMPrintSession s, PMPrintSettings ps, int *mode)
{
    SESSION_CHECK(s);
    SETTINGS_CHECK(ps);
    if (!mode)
        return kPMInvalidParameter;
    *mode = (int)get_uint(ps, K_MATCHING, 0);
    return noErr;
}

PM_EXPORT OSStatus
PMSessionSetColorMatchingMode(PMPrintSession s, PMPrintSettings ps, int mode)
{
    SESSION_CHECK(s);
    SETTINGS_CHECK(ps);
    if (s->matchingLocked)
        return kPMObjectInUse;
    set_uint(ps, K_MATCHING, (UInt32)mode);
    return noErr;
}

PM_EXPORT OSStatus
PMSessionSetColorMatchingModeLock(PMPrintSession s, Boolean lock)
{
    SESSION_CHECK(s);
    s->matchingLocked = lock;
    return noErr;
}

PM_EXPORT OSStatus
PMSessionCopyApplicationOutputIntentWithColorSyncProfiles(PMPrintSession s, PMPrintSettings ps, CFTypeRef *intent)
{
    SESSION_CHECK(s);
    SETTINGS_CHECK(ps);
    if (!intent)
        return kPMInvalidParameter;
    CFTypeRef v = CFDictionaryGetValue(ps->dict, K_INTENT);
    *intent = v ? CFRetain(v) : NULL;
    return noErr;
}

PM_EXPORT OSStatus
PMSessionSetApplicationOutputIntentWithColorSyncProfiles(PMPrintSession s, PMPrintSettings ps, CFTypeRef intent)
{
    SESSION_CHECK(s);
    SETTINGS_CHECK(ps);
    if (intent)
        CFDictionarySetValue(ps->dict, K_INTENT, intent);
    else
        CFDictionaryRemoveValue(ps->dict, K_INTENT);
    return noErr;
}

PM_EXPORT OSStatus
PMSessionCopyDefaultOutputIntentWithColorSyncProfiles(PMPrintSession s, PMPrintSettings ps, CFTypeRef *intent)
{
    SESSION_CHECK(s);
    if (!intent)
        return kPMInvalidParameter;
    *intent = NULL; /* (the generic printer has no output profile) */
    return noErr;
}

PM_EXPORT OSStatus
PMSessionCopyCurrentPrinterColorSyncProfile(PMPrintSession s, PMPrintSettings ps, CFTypeRef *profile)
{
    SESSION_CHECK(s);
    if (!profile)
        return kPMInvalidParameter;
    *profile = NULL;
    return noErr;
}
