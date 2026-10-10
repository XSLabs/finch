/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-iosurface-test: IOSurface, run against Apple's and Finch's to compare
 * (tools/host-tests.sh): layouts for packed and planar formats (row alignment, sizes,
 * plane offsets), seeds and locks, attachments, use counts, lookups by ID, port and XPC
 * (the memory is the same), property limits, and the Objective-C class.
 */
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <IOSurface/IOSurfaceObjC.h>

static void
show(const char *t, NSDictionary *d)
{
    IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)d);
    if (!s) {
        printf("%s: NULL\n", t);
        return;
    }
    printf("%s: w %zu h %zu bpe %zu bpr %zu alloc %zu ew %zu eh %zu format %x planes %zu page-aligned %d id %d casting %d\n", t,
           IOSurfaceGetWidth(s), IOSurfaceGetHeight(s), IOSurfaceGetBytesPerElement(s), IOSurfaceGetBytesPerRow(s),
           IOSurfaceGetAllocSize(s), IOSurfaceGetElementWidth(s), IOSurfaceGetElementHeight(s), IOSurfaceGetPixelFormat(s),
           IOSurfaceGetPlaneCount(s), ((uintptr_t)IOSurfaceGetBaseAddress(s) % 16384) == 0, IOSurfaceGetID(s) > 0,
           IOSurfaceAllowsPixelSizeCasting(s));
    for (size_t i = 0; i < MAX(IOSurfaceGetPlaneCount(s), 1); i++)
        printf("  plane %zu: w %zu h %zu bpe %zu bpr %zu offset %td ew %zu eh %zu\n", i, IOSurfaceGetWidthOfPlane(s, i),
               IOSurfaceGetHeightOfPlane(s, i), IOSurfaceGetBytesPerElementOfPlane(s, i), IOSurfaceGetBytesPerRowOfPlane(s, i),
               (char *)IOSurfaceGetBaseAddressOfPlane(s, i) - (char *)IOSurfaceGetBaseAddress(s), IOSurfaceGetElementWidthOfPlane(s, i),
               IOSurfaceGetElementHeightOfPlane(s, i));
    printf("  seed %u use %d in use %d\n", IOSurfaceGetSeed(s), IOSurfaceGetUseCount(s), IOSurfaceIsInUse(s));
    CFRelease(s);
}

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        printf("%s\n", [[NSBundle bundleForClass:[IOSurface class]] executablePath].UTF8String);
        show("BGRA 100x50", @{(id)kIOSurfaceWidth : @100, (id)kIOSurfaceHeight : @50, (id)kIOSurfaceBytesPerElement : @4,
                              (id)kIOSurfacePixelFormat : @((OSType)'BGRA')});
        show("no bytes per element", @{(id)kIOSurfaceWidth : @100, (id)kIOSurfaceHeight : @50});
        show("1 byte 33x7", @{(id)kIOSurfaceWidth : @33, (id)kIOSurfaceHeight : @7, (id)kIOSurfaceBytesPerElement : @1});
        show("bytes per row 1000", @{(id)kIOSurfaceWidth : @100, (id)kIOSurfaceHeight : @50, (id)kIOSurfaceBytesPerElement : @4,
                                     (id)kIOSurfaceBytesPerRow : @1000});
        show("alloc size", @{(id)kIOSurfaceWidth : @100, (id)kIOSurfaceHeight : @50, (id)kIOSurfaceBytesPerElement : @4,
                             (id)kIOSurfaceAllocSize : @100000});
        show("zero", @{(id)kIOSurfaceWidth : @0, (id)kIOSurfaceHeight : @0, (id)kIOSurfaceBytesPerElement : @4});
        show("too wide", @{(id)kIOSurfaceWidth : @20000, (id)kIOSurfaceHeight : @1, (id)kIOSurfaceBytesPerElement : @4});
        show("420v", @{
            (id)kIOSurfaceWidth : @64,
            (id)kIOSurfaceHeight : @32,
            (id)kIOSurfacePixelFormat : @((OSType)'420v'),
            (id)kIOSurfacePlaneInfo : @[
                @{(id)kIOSurfacePlaneWidth : @64, (id)kIOSurfacePlaneHeight : @32, (id)kIOSurfacePlaneBytesPerElement : @1},
                @{(id)kIOSurfacePlaneWidth : @32, (id)kIOSurfacePlaneHeight : @16, (id)kIOSurfacePlaneBytesPerElement : @2}
            ]
        });
        show("2vuy element width 2", @{(id)kIOSurfaceWidth : @64, (id)kIOSurfaceHeight : @8, (id)kIOSurfaceBytesPerElement : @4,
                                       (id)kIOSurfaceElementWidth : @2, (id)kIOSurfacePixelFormat : @((OSType)'2vuy')});

        IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef) @{(id)kIOSurfaceWidth : @16, (id)kIOSurfaceHeight : @16,
                                                                      (id)kIOSurfaceBytesPerElement : @4});
        uint32_t seed = 7;
        kern_return_t kr = IOSurfaceLock(s, 0, &seed);
        printf("lock %d seed %u\n", kr, seed);
        ((uint32_t *)IOSurfaceGetBaseAddress(s))[5] = 0xfeedface;
        kr = IOSurfaceUnlock(s, 0, &seed);
        printf("unlock %d seed %u now %u\n", kr, seed, IOSurfaceGetSeed(s));
        IOSurfaceLock(s, kIOSurfaceLockReadOnly, &seed);
        IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, &seed);
        printf("read-only: seed %u now %u\n", seed, IOSurfaceGetSeed(s));
        printf("unlock when unlocked: %x\n", IOSurfaceUnlock(s, 0, &seed));

        IOSurfaceSetValue(s, CFSTR("k"), CFSTR("v"));
        NSString *v = (__bridge_transfer NSString *)IOSurfaceCopyValue(s, CFSTR("k"));
        printf("value %s, has k %d\n", v.UTF8String, [(__bridge_transfer NSDictionary *)IOSurfaceCopyAllValues(s) objectForKey:@"k"] != nil);
        IOSurfaceRemoveValue(s, CFSTR("k"));
        printf("removed: %p\n", IOSurfaceCopyValue(s, CFSTR("k")));

        IOSurfaceRef byID = IOSurfaceLookup(IOSurfaceGetID(s));
        printf("by ID: found %d same object %d same memory %d\n", byID != NULL, byID == s,
               byID && ((uint32_t *)IOSurfaceGetBaseAddress(byID))[5] == 0xfeedface);
        if (byID)
            CFRelease(byID);
        mach_port_t port = IOSurfaceCreateMachPort(s);
        IOSurfaceRef fromPort = IOSurfaceLookupFromMachPort(port);
        printf("by port: same object %d w %zu same ID %d sees pixel %d\n", fromPort == s, IOSurfaceGetWidth(fromPort),
               IOSurfaceGetID(fromPort) == IOSurfaceGetID(s), ((uint32_t *)IOSurfaceGetBaseAddress(fromPort))[5] == 0xfeedface);
        ((uint32_t *)IOSurfaceGetBaseAddress(fromPort))[6] = 42;
        printf("written through the other: %u, seed shared %d\n", ((uint32_t *)IOSurfaceGetBaseAddress(s))[6],
               IOSurfaceGetSeed(fromPort) == IOSurfaceGetSeed(s));
        IOSurfaceIncrementUseCount(fromPort);
        printf("use: this %d other %d, in use %d %d\n", IOSurfaceGetUseCount(s), IOSurfaceGetUseCount(fromPort), IOSurfaceIsInUse(s),
               IOSurfaceIsInUse(fromPort));
        IOSurfaceDecrementUseCount(fromPort);
        printf("released use: in use %d\n", IOSurfaceIsInUse(s));
        CFRelease(fromPort);
        mach_port_deallocate(mach_task_self(), port);
        xpc_object_t x = IOSurfaceCreateXPCObject(s);
        IOSurfaceRef fromXPC = IOSurfaceLookupFromXPCObject(x);
        printf("by XPC: w %zu pixel %d\n", IOSurfaceGetWidth(fromXPC), ((uint32_t *)IOSurfaceGetBaseAddress(fromXPC))[5] == 0xfeedface);
        CFRelease(fromXPC);

        uint32_t old = 9;
        printf("purgeable: %d old %u\n", IOSurfaceSetPurgeable(s, kIOSurfacePurgeableVolatile, &old), old);
        IOSurfaceSetPurgeable(s, kIOSurfacePurgeableNonVolatile, &old);
        printf("purgeable again: old %u\n", old);
        printf("max width %zu, height %zu, row alignment %zu, align(row, 100) %zu, alloc alignment %zu\n",
               IOSurfaceGetPropertyMaximum(kIOSurfaceWidth), IOSurfaceGetPropertyMaximum(kIOSurfaceHeight),
               IOSurfaceGetPropertyAlignment(kIOSurfaceBytesPerRow), IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, 100),
               IOSurfaceGetPropertyAlignment(kIOSurfaceAllocSize));

        IOSurface *o = (__bridge IOSurface *)s;
        printf("object: %s w %ld alloc %ld planes %lu type ok %d\n", NSStringFromClass([o class]).UTF8String, (long)o.width,
               (long)o.allocationSize, (unsigned long)o.planeCount, CFGetTypeID(s) == IOSurfaceGetTypeID());
        [o setAttachment:@"x" forKey:@"att"];
        printf("attachment %s\n", [[o attachmentForKey:@"att"] UTF8String]);
        IOSurface *n = [[IOSurface alloc] initWithProperties:@{
            IOSurfacePropertyKeyWidth : @10,
            IOSurfacePropertyKeyHeight : @10,
            IOSurfacePropertyKeyBytesPerElement : @4
        }];
        printf("init: %s bpr %ld alloc %ld CF type %d\n", NSStringFromClass([n class]).UTF8String, (long)n.bytesPerRow,
               (long)n.allocationSize, CFGetTypeID((__bridge CFTypeRef)n) == IOSurfaceGetTypeID());
        IOSurface *bad = [[IOSurface alloc] initWithProperties:@{IOSurfacePropertyKeyWidth : @0}];
        printf("bad init: %p\n", bad);
        CFRelease(s);
    }
    return 0;
}
