// SPDX-License-Identifier: MIT OR Apache-2.0
/* A CGRegion created from a rectangle keeps that rectangle in device-independent space. */
#include "CGInternal.h"
#include <math.h>

struct CGRegion {
    CGRuntimeBase base;
    CGRect bounds;
};
typedef CGRegion *CGRegionRef;

static Boolean
region_equal(CFTypeRef a, CFTypeRef b)
{
    return CGRectEqualToRect(((const CGRegion *)a)->bounds, ((const CGRegion *)b)->bounds);
}

static CFHashCode
region_hash(CFTypeRef cf)
{
    const CGRect r = ((const CGRegion *)cf)->bounds;
    return (CFHashCode)(r.origin.x * 31 + r.origin.y * 17 + r.size.width * 13 + r.size.height * 7);
}

static CFStringRef
region_description(CFTypeRef cf)
{
    const CGRect r = ((const CGRegion *)cf)->bounds;
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("<CGRegion %p [%g,%g %g×%g]>"), cf, r.origin.x, r.origin.y,
                                    r.size.width, r.size.height);
}

static const CGRuntimeClass region_class = {
    0, "CGRegion", NULL, NULL, NULL, region_equal, region_hash, NULL, region_description, NULL, NULL, 0,
};
static CFTypeID region_type;

extern "C" {

CFTypeID
CGRegionGetTypeID(void)
{
    return CGTypeRegister(&region_class, &region_type);
}

CGRegionRef
CGRegionCreateWithRect(CGRect rect)
{
    if (CGRectIsInfinite(rect))
        return NULL;
    CGRegion *region = (CGRegion *)CGTypeCreateInstance(CGRegionGetTypeID(), sizeof(CGRegion));
    if (CGRectIsNull(rect))
        region->bounds = CGRectZero;
    else {
        rect = CGRectStandardize(rect);
        region->bounds = CGRectIsEmpty(rect) ? CGRectZero : rect;
    }
    return region;
}

CGRegionRef
CGRegionRetain(CGRegionRef region)
{
    return region ? (CGRegionRef)CFRetain(region) : NULL;
}

void
CGRegionRelease(CGRegionRef region)
{
    if (region)
        CFRelease(region);
}

CGRect
CGRegionGetBoundingBox(CGRegionRef region)
{
    return region ? region->bounds : CGRectZero;
}

bool
CGRegionIsEmpty(CGRegionRef region)
{
    return !region || CGRectIsEmpty(region->bounds);
}

bool
CGRegionIsRect(CGRegionRef region, CGRect *rect)
{
    if (!region)
        return false;
    if (rect)
        *rect = region->bounds;
    return true;
}

bool
CGRegionContainsRect(CGRegionRef region, CGRect rect)
{
    return region && CGRectContainsRect(region->bounds, CGRectStandardize(rect));
}

bool
CGRegionIntersectsRect(CGRegionRef region, CGRect rect)
{
    rect = CGRectStandardize(rect);
    return region && !CGRectIsEmpty(region->bounds) && !CGRectIsEmpty(rect) && CGRectIntersectsRect(region->bounds, rect);
}

bool
CGRegionContainsPoint(CGRegionRef region, CGPoint point)
{
    return region && CGRectContainsPoint(region->bounds, point);
}

}
