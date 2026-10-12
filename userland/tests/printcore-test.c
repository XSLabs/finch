/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * PrintCore without depending on the machine's printers: page formats and custom papers
 * (their rectangles before and after validation, landscape, scale), print settings and
 * a session's defaults (copies, collation, page range, Apple's keys), values, job names,
 * data representations, destinations and output formats, a two-page document printed
 * to a PDF file through a session (read back: its pages and their size).
 * Compared with Apple's.
 */
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <unistd.h>

static void
rect(const char *label, PMRect r)
{
    printf("%s: %g %g %g %g\n", label, r.top, r.left, r.bottom, r.right);
}

static void
cfprint(const char *label, CFTypeRef v)
{
    char buf[512] = "(null)";
    if (v) {
        CFStringRef s = CFGetTypeID(v) == CFStringGetTypeID() ? CFRetain(v) : CFCopyDescription(v);
        CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8);
        CFRelease(s);
    }
    printf("%s: %s\n", label, buf);
}

static CFComparisonResult
compare_strings(const void *a, const void *b, void *context)
{
    return CFStringCompare(a, b, 0);
}

int
main(void)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    PMPageFormat pf;
    printf("create page format %d\n", (int)PMCreatePageFormat(&pf));
    PMPaper paper;
    PMGetPageFormatPaper(pf, &paper);
    CFStringRef id;
    double w, h;
    PMPaperGetID(paper, &id);
    PMPaperGetWidth(paper, &w);
    PMPaperGetHeight(paper, &h);
    cfprint("fresh paper", id);
    printf("fresh size %gx%g\n", w, h);
    PMOrientation o;
    double scale;
    PMGetOrientation(pf, &o);
    PMGetScale(pf, &scale);
    printf("orientation %d scale %g\n", o, scale);

    PMPaper custom;
    PMPaperMargins margins = {10, 20, 30, 40};
    PMPaperCreateCustom(NULL, CFSTR("My"), CFSTR("Mine"), 300, 400, &margins, &custom);
    PMPaperGetID(custom, &id);
    cfprint("custom id", id);
    printf("custom %d\n", PMPaperIsCustom(custom));
    PMPageFormat cf;
    PMCreatePageFormatWithPMPaper(&cf, custom);
    PMRect r;
    PMGetAdjustedPageRect(cf, &r);
    rect("page", r);
    PMGetAdjustedPaperRect(cf, &r);
    rect("paper", r);
    PMSetOrientation(cf, kPMLandscape, false);
    PMSetScale(cf, 50);
    PMGetAdjustedPageRect(cf, &r);
    rect("landscape 50% before validating", r);
    PMPrintSession s;
    PMCreateSession(&s);
    Boolean changed = false;
    printf("validate %d\n", (int)PMSessionValidatePageFormat(s, cf, &changed));
    printf("changed %d\n", changed);
    PMGetAdjustedPageRect(cf, &r);
    rect("landscape 50% page", r);
    PMGetAdjustedPaperRect(cf, &r);
    rect("landscape 50% paper", r);

    PMPrintSettings ps;
    PMCreatePrintSettings(&ps);
    UInt32 copies, first, last, lo, hi;
    Boolean collate;
    PMGetCopies(ps, &copies);
    PMGetCollate(ps, &collate);
    PMGetFirstPage(ps, &first);
    PMGetLastPage(ps, &last);
    printf("fresh settings: copies %u collate %d pages %u-%u\n", copies, collate, first, last);
    PMSessionDefaultPrintSettings(s, ps);
    PMGetCopies(ps, &copies);
    PMGetCollate(ps, &collate);
    PMGetFirstPage(ps, &first);
    PMGetLastPage(ps, &last);
    PMGetPageRange(ps, &lo, &hi);
    printf("session defaults: copies %u collate %d pages %u-%u range %u-%u\n", copies, collate, first, last, lo, hi);
    PMSetCopies(ps, 3, false);
    PMSetPageRange(ps, 2, 5);
    PMSetFirstPage(ps, 2, false);
    PMSetLastPage(ps, 4, false);
    PMGetCopies(ps, &copies);
    PMGetPageRange(ps, &lo, &hi);
    PMGetFirstPage(ps, &first);
    PMGetLastPage(ps, &last);
    printf("set: copies %u range %u-%u pages %u-%u\n", copies, lo, hi, first, last);
    printf("bad range %d\n", (int)PMSetPageRange(ps, 5, 2));
    PMPrintSettingsSetJobName(ps, CFSTR("Job"));
    CFStringRef job;
    PMPrintSettingsGetJobName(ps, &job);
    cfprint("job", job);
    PMPrintSettingsSetValue(ps, CFSTR("com.example.key"), CFSTR("v"), false);
    CFTypeRef v;
    PMPrintSettingsGetValue(ps, CFSTR("com.example.key"), &v);
    cfprint("value", v);
    PMDuplexMode d;
    PMGetDuplex(ps, &d);
    printf("duplex %u\n", d);
    CFDictionaryRef dict;
    PMPrintSettingsCopyAsDictionary(ps, &dict);
    CFIndex n = CFDictionaryGetCount(dict);
    const void *keys[64];
    CFDictionaryGetKeysAndValues(dict, keys, NULL);
    CFArrayRef ka = CFArrayCreate(NULL, keys, n, &kCFTypeArrayCallBacks);
    CFMutableArrayRef sorted = CFArrayCreateMutableCopy(NULL, 0, ka);
    CFArraySortValues(sorted, CFRangeMake(0, n), compare_strings, NULL);
    for (CFIndex i = 0; i < n; i++)
        cfprint("  key", CFArrayGetValueAtIndex(sorted, i));
    CFDataRef data;
    PMPrintSettingsCreateDataRepresentation(ps, &data, kPMDataFormatXMLDefault);
    PMPrintSettings back;
    printf("settings round trip %d\n", (int)PMPrintSettingsCreateWithDataRepresentation(data, &back));
    PMGetCopies(back, &copies);
    PMPrintSettingsGetJobName(back, &job);
    printf("back copies %u\n", copies);
    cfprint("back job", job);
    PMPageFormatCreateDataRepresentation(cf, &data, kPMDataFormatXMLDefault);
    PMPageFormat fback;
    printf("format round trip %d\n", (int)PMPageFormatCreateWithDataRepresentation(data, &fback));
    PMGetOrientation(fback, &o);
    PMGetScale(fback, &scale);
    printf("back orientation %d scale %g\n", o, scale);

    PMDestinationType dt;
    PMSessionGetDestinationType(s, ps, &dt);
    printf("destination %u\n", dt);
    CFArrayRef formats;
    PMSessionCopyOutputFormatList(s, kPMDestinationFile, &formats);
    for (CFIndex i = 0; i < CFArrayGetCount(formats); i++)
        cfprint("  file format", CFArrayGetValueAtIndex(formats, i));
    char path[] = "/tmp/finch-printcore-XXXXXX.pdf";
    close(mkstemps(path, 4));
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    printf("set destination %d\n", (int)PMSessionSetDestination(s, ps, kPMDestinationFile, kPMDocumentFormatPDF, url));
    PMSessionGetDestinationType(s, ps, &dt);
    CFStringRef fmt;
    CFURLRef loc;
    PMSessionCopyDestinationFormat(s, ps, &fmt);
    PMSessionCopyDestinationLocation(s, ps, &loc);
    printf("destination %u, location set %d\n", dt, loc != NULL);
    cfprint("format", fmt);

    PMPageFormat letter;
    PMPaper lp;
    PMPaperCreateCustom(NULL, CFSTR("L"), CFSTR("L"), 612, 792, &(PMPaperMargins){18, 18, 18, 18}, &lp);
    PMCreatePageFormatWithPMPaper(&letter, lp);
    PMSetPageRange(ps, 1, 2);
    PMSetFirstPage(ps, 1, false);
    PMSetLastPage(ps, 2, false);
    printf("begin document %d\n", (int)PMSessionBeginCGDocumentNoDialog(s, ps, letter));
    for (int page = 0; page < 2; page++) {
        printf("begin page %d\n", (int)PMSessionBeginPageNoDialog(s, letter, NULL));
        CGContextRef c = NULL;
        printf("context %d\n", PMSessionGetCGGraphicsContext(s, &c) == noErr && c);
        CGContextSetRGBFillColor(c, 1, 0, 0, 1);
        CGContextFillRect(c, CGRectMake(0, 0, 100, 100));
        printf("end page %d\n", (int)PMSessionEndPageNoDialog(s));
    }
    printf("end document %d\n", (int)PMSessionEndDocumentNoDialog(s));
    CGPDFDocumentRef doc = CGPDFDocumentCreateWithURL(url);
    printf("pdf pages %zu\n", doc ? CGPDFDocumentGetNumberOfPages(doc) : 0);
    if (doc && CGPDFDocumentGetNumberOfPages(doc)) {
        CGRect box = CGPDFPageGetBoxRect(CGPDFDocumentGetPage(doc, 1), kCGPDFMediaBox);
        printf("page size %gx%g\n", box.size.width, box.size.height);
        CGPDFDocumentRelease(doc);
    }
    unlink(path);

    printf("retain/release %d %d\n", (int)PMRetain(ps), (int)PMRelease(ps));
    return 0;
}
