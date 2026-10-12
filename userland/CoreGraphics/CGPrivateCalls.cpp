/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * More of the private CoreGraphics calls apps make (signatures read from Apple's binaries
 * and from how apps call them): window-server regions, connections, displays, window
 * shapes and the session; shadow styles; colour spaces by ID, their type and profile
 * description; aligned row bytes; continuous rounded rects; and a few context and PDF
 * getters. The window server keeps no per-window shapes or transforms yet, so those
 * calls succeed and are kept nowhere.
 */
#include "CGInternal.h"
#include "CGContextInternal.h"
#include "CGColorSpaceInternal.h"
#include <cmath>
#include <unistd.h>
#include <vector>

typedef int CGSConnectionID;
typedef uint32_t CGSWindowID;

/* A region: a union of rectangles. */
struct CGSRegion {
    std::vector<CGRect> rects;
};
typedef CGSRegion *CGSRegionRef;

/* A shadow style, as Apple's CGStyleCreateShadow takes it. */
typedef struct {
    unsigned int version;
    CGFloat azimuth;    /* degrees, the direction the light comes from */
    CGFloat ambient;
    CGFloat height;     /* how far the shadow falls */
    CGFloat radius;     /* blur */
    CGFloat saturation;
} CGShadowStyle;

struct CGStyle {
    int refs;
    CGShadowStyle shadow;
};
typedef struct CGStyle *CGStyleRef;

typedef void (*CGSConnectionNotifyProc)(int type, void *data, uint32_t length, void *userInfo);

extern "C" {
CGError CGSNewRegionWithRect(const CGRect *rect, CGSRegionRef *out);
CGError CGSUnionRegion(CGSRegionRef a, CGSRegionRef b, CGSRegionRef *out);
CGError CGSOffsetRegion(CGSRegionRef r, float dx, float dy, CGSRegionRef *out);
CGError CGSGetRegionBounds(CGSRegionRef r, CGRect *out);
CGError CGSReleaseRegion(CGSRegionRef r);
CGError CGSRegionRelease(CGSRegionRef r);
CGError CGSNewConnection(void *attributes, CGSConnectionID *out);
CGError CGSReleaseConnection(CGSConnectionID cid);
CGError CGSSetConnectionProperty(CGSConnectionID cid, CGSConnectionID target, CFStringRef key, CFTypeRef value);
CGError CGSRegisterConnectionNotifyProc(CGSConnectionID cid, CGSConnectionNotifyProc proc, int type, void *userInfo);
CGError CGSGetOnlineDisplayList(uint32_t max, CGDirectDisplayID *displays, uint32_t *count);
CGDirectDisplayID CGSMainDisplayID(void);
CGError CGSGetCurrentDisplayMode(CGDirectDisplayID display, int *mode);
CGError CGSDisplayStatusQuery(CGDirectDisplayID display, int *status);
CGError CGSSetWindowAlpha(CGSConnectionID cid, CGSWindowID wid, float alpha);
CGError CGSSetWindowTransform(CGSConnectionID cid, CGSWindowID wid, CGAffineTransform t);
CGError CGSSetWindowTransformAtPlacement(CGSConnectionID cid, CGSWindowID wid, CGAffineTransform t, CGPoint placement);
CGError CGSGetWindowTransformAtPlacement(CGSConnectionID cid, CGSWindowID wid, CGPoint placement, CGAffineTransform *t);
CGError CGSCopySpecifiedWindowShape(CGSConnectionID cid, CGSWindowID wid, int kind, CGSRegionRef *out);
CGError CGSSetWindowCaptureExcludeShape(CGSConnectionID cid, CGSWindowID wid, CGSRegionRef region);
CFDictionaryRef CGSSessionCopyCurrentSessionProperties(void);
double CGSSecondsSinceLastInputEvent(int type);
uint32_t CGSInputModifierKeyState(int which);
int CGSServerOperationState(void);
CGError CGSDisableUpdateToken(CGSConnectionID cid, int *token);
CGError CGSReenableUpdateToken(CGSConnectionID cid, int *token);
CGStyleRef CGStyleCreateShadow(const CGShadowStyle *style);
CGStyleRef CGStyleRetain(CGStyleRef style);
void CGStyleRelease(CGStyleRef style);
bool CGStyleEqualToStyle(CGStyleRef a, CGStyleRef b);
void CGContextSetStyle(CGContextRef c, CGStyleRef style);
bool CGFloatIsValid(CGFloat v);
CGColorSpaceRef CGColorSpaceCreateWithID(int ident);
int CGColorSpaceGetType(CGColorSpaceRef space);
CFStringRef CGColorSpaceCopyICCProfileDescription(CGColorSpaceRef space);
void *CGDirectDisplayCopyCurrentMetalDevice(CGDirectDisplayID display);
size_t CGBitmapGetAlignedBytesPerRow(size_t bytesPerRow);
CGPathRef CGPathCreateWithContinuousRoundedRect(CGRect rect, CGFloat radius, const CGAffineTransform *transform);
size_t CGContextGetLineDashCount(CGContextRef c);
void CGContextGetLineDashPattern(CGContextRef c, CGFloat *phase, CGFloat *lengths);
void CGContextSetCTM(CGContextRef c, CGAffineTransform t);
void CGContextSetFontSmoothingBackgroundColor(CGContextRef c, CGColorRef color);
CGContextRef CGWindowContextCreate(CGSConnectionID cid, CGSWindowID wid, CFDictionaryRef options);
CGImageRef CGWindowContextCreateImage(CGContextRef c);
void *CGFontGetParserFont(CGFontRef font);
CFArrayRef CGPDFDocumentCopyOutputIntents(CGPDFDocumentRef document);
CGPDFDictionaryRef CGPDFDocumentGetDestination(CGPDFDocumentRef document, const char *name);
}

/* --- regions --- */

CGError
CGSNewRegionWithRect(const CGRect *rect, CGSRegionRef *out)
{
    if (!out)
        return kCGErrorIllegalArgument;
    *out = new CGSRegion;
    if (rect && !CGRectIsEmpty(*rect))
        (*out)->rects.push_back(CGRectStandardize(*rect));
    return kCGErrorSuccess;
}

CGError
CGSUnionRegion(CGSRegionRef a, CGSRegionRef b, CGSRegionRef *out)
{
    if (!out)
        return kCGErrorIllegalArgument;
    *out = new CGSRegion;
    if (a)
        (*out)->rects = a->rects;
    if (b)
        (*out)->rects.insert((*out)->rects.end(), b->rects.begin(), b->rects.end());
    return kCGErrorSuccess;
}

CGError
CGSOffsetRegion(CGSRegionRef r, float dx, float dy, CGSRegionRef *out)
{
    if (!out)
        return kCGErrorIllegalArgument;
    *out = new CGSRegion;
    if (r)
        for (CGRect rect : r->rects)
            (*out)->rects.push_back(CGRectOffset(rect, dx, dy));
    return kCGErrorSuccess;
}

CGError
CGSGetRegionBounds(CGSRegionRef r, CGRect *out)
{
    if (!out)
        return kCGErrorIllegalArgument;
    CGRect bounds = CGRectNull;
    if (r)
        for (CGRect rect : r->rects)
            bounds = CGRectUnion(bounds, rect);
    *out = CGRectIsNull(bounds) ? CGRectZero : bounds;
    return kCGErrorSuccess;
}

CGError
CGSReleaseRegion(CGSRegionRef r)
{
    delete r;
    return kCGErrorSuccess;
}

CGError
CGSRegionRelease(CGSRegionRef r)
{
    return CGSReleaseRegion(r);
}

/* --- connections (one per process, as CGSMainConnectionID says) --- */

CGError
CGSNewConnection(void *attributes, CGSConnectionID *out)
{
    if (!out)
        return kCGErrorIllegalArgument;
    *out = (CGSConnectionID)getpid();
    return kCGErrorSuccess;
}

CGError CGSReleaseConnection(CGSConnectionID cid) { return kCGErrorSuccess; }
CGError CGSSetConnectionProperty(CGSConnectionID cid, CGSConnectionID target, CFStringRef key, CFTypeRef value) { return kCGErrorSuccess; }

/* (the window server doesn't send connection notifications yet; the procedure is kept nowhere) */
CGError
CGSRegisterConnectionNotifyProc(CGSConnectionID cid, CGSConnectionNotifyProc proc, int type, void *userInfo)
{
    return kCGErrorSuccess;
}

/* --- displays --- */

CGError
CGSGetOnlineDisplayList(uint32_t max, CGDirectDisplayID *displays, uint32_t *count)
{
    return CGGetOnlineDisplayList(max, displays, count);
}

CGDirectDisplayID CGSMainDisplayID(void) { return CGMainDisplayID(); }

CGError
CGSGetCurrentDisplayMode(CGDirectDisplayID display, int *mode)
{
    if (mode)
        *mode = 0;
    return kCGErrorSuccess;
}

CGError
CGSDisplayStatusQuery(CGDirectDisplayID display, int *status)
{
    if (status)
        *status = display == CGMainDisplayID() ? 1 : 0;
    return kCGErrorSuccess;
}

void *CGDirectDisplayCopyCurrentMetalDevice(CGDirectDisplayID display) { return NULL; }

/* --- windows --- */

CGError CGSSetWindowAlpha(CGSConnectionID cid, CGSWindowID wid, float alpha) { return kCGErrorSuccess; }
CGError CGSSetWindowTransform(CGSConnectionID cid, CGSWindowID wid, CGAffineTransform t) { return kCGErrorSuccess; }

CGError
CGSSetWindowTransformAtPlacement(CGSConnectionID cid, CGSWindowID wid, CGAffineTransform t, CGPoint placement)
{
    return kCGErrorSuccess;
}

CGError
CGSGetWindowTransformAtPlacement(CGSConnectionID cid, CGSWindowID wid, CGPoint placement, CGAffineTransform *t)
{
    if (t)
        *t = CGAffineTransformIdentity;
    return kCGErrorSuccess;
}

/* (a window's shape: its frame, as the window list has it) */
CGError
CGSCopySpecifiedWindowShape(CGSConnectionID cid, CGSWindowID wid, int kind, CGSRegionRef *out)
{
    CGRect frame = CGRectZero;
    CFArrayRef list = CGWindowListCreateDescriptionFromArray(NULL);
    (void)list;
    CFArrayRef info = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, wid);
    if (info && CFArrayGetCount(info)) {
        CFDictionaryRef w = (CFDictionaryRef)CFArrayGetValueAtIndex(info, 0);
        CFDictionaryRef bounds = (CFDictionaryRef)CFDictionaryGetValue(w, kCGWindowBounds);
        if (bounds)
            CGRectMakeWithDictionaryRepresentation(bounds, &frame);
    }
    if (info)
        CFRelease(info);
    return CGSNewRegionWithRect(&frame, out);
}

CGError CGSSetWindowCaptureExcludeShape(CGSConnectionID cid, CGSWindowID wid, CGSRegionRef region) { return kCGErrorSuccess; }

/* --- the session --- */

CFDictionaryRef
CGSSessionCopyCurrentSessionProperties(void)
{
    return CGSessionCopyCurrentDictionary();
}

double
CGSSecondsSinceLastInputEvent(int type)
{
    return CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateHIDSystemState, type < 0 ? kCGAnyInputEventType : (CGEventType)type);
}

uint32_t
CGSInputModifierKeyState(int which)
{
    return (uint32_t)CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState) & 0xffff0000;
}

int CGSServerOperationState(void) { return 0; }

CGError
CGSDisableUpdateToken(CGSConnectionID cid, int *token)
{
    if (token)
        *token = 1;
    return kCGErrorSuccess;
}

CGError CGSReenableUpdateToken(CGSConnectionID cid, int *token) { return kCGErrorSuccess; }

/* --- shadow styles --- */

CGStyleRef
CGStyleCreateShadow(const CGShadowStyle *style)
{
    if (!style)
        return NULL;
    CGStyleRef s = new CGStyle;
    s->refs = 1;
    s->shadow = *style;
    return s;
}

CGStyleRef
CGStyleRetain(CGStyleRef style)
{
    if (style)
        __atomic_add_fetch(&style->refs, 1, __ATOMIC_RELAXED);
    return style;
}

void
CGStyleRelease(CGStyleRef style)
{
    if (style && __atomic_sub_fetch(&style->refs, 1, __ATOMIC_ACQ_REL) == 0)
        delete style;
}

bool
CGStyleEqualToStyle(CGStyleRef a, CGStyleRef b)
{
    if (a == b)
        return true;
    if (!a || !b)
        return false;
    const CGShadowStyle &x = a->shadow, &y = b->shadow;
    return x.azimuth == y.azimuth && x.ambient == y.ambient && x.height == y.height && x.radius == y.radius &&
           x.saturation == y.saturation;
}

/* (the style's shadow, cast away from the light by its height, in a third-black) */
void
CGContextSetStyle(CGContextRef c, CGStyleRef style)
{
    if (!c)
        return;
    if (!style) {
        CGContextSetShadowWithColor(c, CGSizeZero, 0, NULL);
        return;
    }
    const CGShadowStyle &s = style->shadow;
    double a = (s.azimuth + 180.0) * M_PI / 180.0;
    CGSize offset = CGSizeMake(s.height * cos(a), s.height * sin(a));
    CGFloat comps[4] = {0, 0, 0, s.ambient > 0 && s.ambient <= 1 ? s.ambient : 0.33};
    CGColorSpaceRef rgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGColorRef color = CGColorCreate(rgb, comps);
    CGContextSetShadowWithColor(c, offset, s.radius, color);
    CGColorRelease(color);
    CGColorSpaceRelease(rgb);
}

/* --- colour spaces --- */

bool
CGFloatIsValid(CGFloat v)
{
    return std::isfinite(v);
}

/* (named in Apple's CoreGraphics, not in the SDK's headers) */
static const CFStringRef kFinchDisplayP3_709OETF = CFSTR("kCGColorSpaceDisplayP3_709OETF");

/* (Apple's numbering of its named spaces) */
CGColorSpaceRef
CGColorSpaceCreateWithID(int ident)
{
    static const CFStringRef *const names[] = {
        nullptr, &kCGColorSpaceGenericGrayGamma2_2, &kCGColorSpaceExtendedGray, &kCGColorSpaceLinearGray,
        &kCGColorSpaceExtendedLinearGray, &kCGColorSpaceGenericLab, &kCGColorSpaceGenericXYZ, &kCGColorSpaceDisplayP3,
        &kCGColorSpaceExtendedDisplayP3, &kCGColorSpaceLinearDisplayP3, &kCGColorSpaceExtendedLinearDisplayP3,
        &kCGColorSpaceDisplayP3_PQ, &kCGColorSpaceDisplayP3_HLG, &kFinchDisplayP3_709OETF, &kCGColorSpaceAdobeRGB1998,
        &kCGColorSpaceSRGB, &kCGColorSpaceExtendedSRGB, &kCGColorSpaceLinearSRGB, &kCGColorSpaceExtendedLinearSRGB,
        &kCGColorSpaceACESCGLinear, &kCGColorSpaceITUR_709, &kCGColorSpaceITUR_709_PQ, &kCGColorSpaceITUR_709_HLG,
        &kCGColorSpaceITUR_2020, &kCGColorSpaceLinearITUR_2020, &kCGColorSpaceExtendedITUR_2020,
        &kCGColorSpaceExtendedLinearITUR_2020, &kCGColorSpaceITUR_2020_sRGBGamma, &kCGColorSpaceITUR_2100_PQ,
        &kCGColorSpaceITUR_2100_HLG, &kCGColorSpaceROMMRGB, &kCGColorSpaceDCIP3, &kCGColorSpaceCoreMedia709,
    };
    if (ident <= 0 || (size_t)ident >= sizeof names / sizeof names[0])
        return NULL;
    return CGColorSpaceCreateWithName(*names[ident]);
}

/* (Apple's types: device gray, RGB and CMYK 0 to 2, Lab 5, ICC-based 6, indexed 7, pattern 8) */
int
CGColorSpaceGetType(CGColorSpaceRef space)
{
    if (!space)
        return -1;
    switch (space->kind) {
    case CG_SPACE_DEVICE_GRAY:
        return 0;
    case CG_SPACE_DEVICE_RGB:
        return 1;
    case CG_SPACE_DEVICE_CMYK:
        return 2;
    case CG_SPACE_LAB:
        return 5;
    case CG_SPACE_INDEXED:
        return 7;
    case CG_SPACE_PATTERN:
        return 8;
    default:
        return 6;
    }
}

CFStringRef
CGColorSpaceCopyICCProfileDescription(CGColorSpaceRef space)
{
    if (!space || !space->desc)
        return NULL;
    return CFStringCreateWithCString(kCFAllocatorDefault, space->desc, kCFStringEncodingUTF8);
}

/* --- bitmaps and paths --- */

size_t
CGBitmapGetAlignedBytesPerRow(size_t bytesPerRow)
{
    return (bytesPerRow + 31) & ~(size_t)31;
}

/* A rounded rect with continuous (squircle-like) corners: each corner drawn as two
   curves over 1.528 times the radius, as Apple's continuous corners reach. */
CGPathRef
CGPathCreateWithContinuousRoundedRect(CGRect rect, CGFloat radius, const CGAffineTransform *transform)
{
    rect = CGRectStandardize(rect);
    CGFloat r = std::min(radius, std::min(rect.size.width, rect.size.height) / 2);
    if (r <= 0)
        return CGPathCreateWithRect(rect, transform);
    CGFloat e = std::min(r * 1.528665, std::min(rect.size.width, rect.size.height) / 2);
    CGFloat minX = CGRectGetMinX(rect), maxX = CGRectGetMaxX(rect), minY = CGRectGetMinY(rect), maxY = CGRectGetMaxY(rect);
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, transform, minX + e, minY);
    CGPathAddLineToPoint(p, transform, maxX - e, minY);
    CGPathAddCurveToPoint(p, transform, maxX - e * 0.37, minY, maxX, minY + e * 0.37, maxX, minY + e);
    CGPathAddLineToPoint(p, transform, maxX, maxY - e);
    CGPathAddCurveToPoint(p, transform, maxX, maxY - e * 0.37, maxX - e * 0.37, maxY, maxX - e, maxY);
    CGPathAddLineToPoint(p, transform, minX + e, maxY);
    CGPathAddCurveToPoint(p, transform, minX + e * 0.37, maxY, minX, maxY - e * 0.37, minX, maxY - e);
    CGPathAddLineToPoint(p, transform, minX, minY + e);
    CGPathAddCurveToPoint(p, transform, minX, minY + e * 0.37, minX + e * 0.37, minY, minX + e, minY);
    CGPathCloseSubpath(p);
    return p;
}

/* --- context state --- */

size_t
CGContextGetLineDashCount(CGContextRef c)
{
    return c ? CGContextState(c).dashes.size() : 0;
}

void
CGContextGetLineDashPattern(CGContextRef c, CGFloat *phase, CGFloat *lengths)
{
    if (!c)
        return;
    if (phase)
        *phase = CGContextState(c).dash_phase;
    if (lengths)
        for (size_t i = 0; i < CGContextState(c).dashes.size(); i++)
            lengths[i] = CGContextState(c).dashes[i];
}

void
CGContextSetCTM(CGContextRef c, CGAffineTransform t)
{
    if (c)
        CGContextState(c).ctm = t;
}

/* (Finch smooths text over whatever is drawn below it; the colour isn't needed) */
void CGContextSetFontSmoothingBackgroundColor(CGContextRef c, CGColorRef color) {}

/* --- what Finch doesn't have yet --- */

CGContextRef CGWindowContextCreate(CGSConnectionID cid, CGSWindowID wid, CFDictionaryRef options) { return NULL; }
CGImageRef CGWindowContextCreateImage(CGContextRef c) { return NULL; }
void *CGFontGetParserFont(CGFontRef font) { return NULL; }

/* (PostScript isn't interpreted: no converter can be made) */
CGPSConverterRef CGPSConverterCreate(void *info, const CGPSConverterCallbacks *callbacks, CFDictionaryRef options) { return NULL; }
bool CGPSConverterConvert(CGPSConverterRef converter, CGDataProviderRef provider, CGDataConsumerRef consumer, CFDictionaryRef options) { return false; }
bool CGPSConverterAbort(CGPSConverterRef converter) { return false; }

/* The output intents in the document's catalog, as Apple's gives them: each intent's
   dictionary as a CFDictionary of its subtype and identifiers. */
CFArrayRef
CGPDFDocumentCopyOutputIntents(CGPDFDocumentRef document)
{
    CGPDFDictionaryRef catalog = document ? CGPDFDocumentGetCatalog(document) : NULL;
    CGPDFArrayRef intents = NULL;
    if (!catalog || !CGPDFDictionaryGetArray(catalog, "OutputIntents", &intents) || !intents)
        return NULL;
    CFMutableArrayRef out = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    for (size_t i = 0; i < CGPDFArrayGetCount(intents); i++) {
        CGPDFDictionaryRef intent = NULL;
        if (!CGPDFArrayGetDictionary(intents, i, &intent))
            continue;
        CFMutableDictionaryRef d = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
                                                             &kCFTypeDictionaryValueCallBacks);
        const char *keys[] = {"S", "OutputConditionIdentifier", "OutputCondition", "RegistryName", "Info"};
        for (const char *k : keys) {
            const char *name = NULL;
            CGPDFStringRef str = NULL;
            CFStringRef value = NULL;
            if (CGPDFDictionaryGetName(intent, k, &name) && name)
                value = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingUTF8);
            else if (CGPDFDictionaryGetString(intent, k, &str) && str)
                value = CGPDFStringCopyTextString(str);
            if (!value)
                continue;
            CFStringRef key = CFStringCreateWithCString(kCFAllocatorDefault, k, kCFStringEncodingUTF8);
            CFDictionarySetValue(d, key, value);
            CFRelease(key);
            CFRelease(value);
        }
        CFArrayAppendValue(out, d);
        CFRelease(d);
    }
    return out;
}

/* (named destinations aren't looked up yet) */
CGPDFDictionaryRef CGPDFDocumentGetDestination(CGPDFDocumentRef document, const char *name) { return NULL; }
