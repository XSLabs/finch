// SPDX-License-Identifier: MIT OR Apache-2.0
#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdio.h>

extern bool CGColorSpaceIsICCCompatible(CGColorSpaceRef space);
extern CGAffineTransform CGContextGetBaseCTM(CGContextRef context);
extern void CGContextSetBaseCTM(CGContextRef context, CGAffineTransform transform);
extern CGColorSpaceRef CGContextCopyDeviceColorSpace(CGContextRef context);

static void
show_compatibility(const char *name, CGColorSpaceRef space)
{
    printf("icc %s %d\n", name, CGColorSpaceIsICCCompatible(space));
}

int
main(void)
{
    puts("CoreGraphics private helpers");
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGColorSpaceRef indexed = CGColorSpaceCreateIndexed(rgb, 1, (const uint8_t[]){0, 0, 0, 255, 255, 255});
    CGColorSpaceRef pattern = CGColorSpaceCreatePattern(NULL);
    show_compatibility("rgb", rgb);
    show_compatibility("gray", gray);
    show_compatibility("srgb", srgb);
    show_compatibility("indexed", indexed);
    show_compatibility("pattern", pattern);

    uint8_t pixel[4] = {0};
    CGContextRef context = CGBitmapContextCreate(pixel, 1, 1, 8, sizeof pixel, rgb, kCGImageAlphaPremultipliedLast);
    CGAffineTransform base = CGContextGetBaseCTM(context);
    printf("base %.0f %.0f %.0f %.0f %.0f %.0f\n", base.a, base.b, base.c, base.d, base.tx, base.ty);
    CGAffineTransform replacement = CGAffineTransformMake(2, 3, 4, 5, 6, 7);
    CGContextSetBaseCTM(context, replacement);
    base = CGContextGetBaseCTM(context);
    printf("set base %.0f %.0f %.0f %.0f %.0f %.0f\n", base.a, base.b, base.c, base.d, base.tx, base.ty);
    CGContextSetBaseCTM(context, replacement);
    CGAffineTransform device = CGContextGetUserSpaceToDeviceSpaceTransform(context);
    printf("device %.0f %.0f %.0f %.0f %.0f %.0f\n", device.a, device.b, device.c, device.d, device.tx, device.ty);
    CGColorSpaceRef device_space = CGContextCopyDeviceColorSpace(context);
    printf("device space %d\n", device_space ? (int)CGColorSpaceGetModel(device_space) : -1);

    if (device_space)
        CGColorSpaceRelease(device_space);
    CGContextRelease(context);
    CGColorSpaceRelease(pattern);
    CGColorSpaceRelease(indexed);
    CGColorSpaceRelease(srgb);
    CGColorSpaceRelease(gray);
    CGColorSpaceRelease(rgb);
    return 0;
}
