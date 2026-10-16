// SPDX-License-Identifier: MIT OR Apache-2.0
#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdio.h>

typedef struct __CGRegion *CGRegionRef;
extern CFTypeID CGRegionGetTypeID(void);
extern CGRegionRef CGRegionCreateWithRect(CGRect rect);
extern CGRect CGRegionGetBoundingBox(CGRegionRef region);
extern bool CGRegionIsEmpty(CGRegionRef region);
extern bool CGRegionIsRect(CGRegionRef region, CGRect *rect);
extern bool CGRegionContainsRect(CGRegionRef region, CGRect rect);
extern bool CGRegionIntersectsRect(CGRegionRef region, CGRect rect);
extern void CGRegionRelease(CGRegionRef region);

static void
show(const char *name, CGRect input)
{
    CGRegionRef region = CGRegionCreateWithRect(input);
    CGRect rect = CGRectZero;
    bool is_rect = CGRegionIsRect(region, &rect);
    CGRect bounds = CGRegionGetBoundingBox(region);
    printf("%s type %d empty %d rect %d %.0f %.0f %.0f %.0f bounds %.0f %.0f %.0f %.0f contains %d intersects %d\n",
           name, CFGetTypeID(region) == CGRegionGetTypeID(), CGRegionIsEmpty(region), is_rect, rect.origin.x,
           rect.origin.y, rect.size.width, rect.size.height, bounds.origin.x, bounds.origin.y, bounds.size.width,
           bounds.size.height, CGRegionContainsRect(region, CGRectMake(4, 5, 2, 3)),
           CGRegionIntersectsRect(region, CGRectMake(0, 0, 1, 1)));
    CGRegionRelease(region);
}

int
main(void)
{
    puts("CoreGraphics regions");
    show("normal", CGRectMake(2, 3, 10, 20));
    show("negative", CGRectMake(12, 3, -10, 20));
    show("zero", CGRectZero);
    return 0;
}
