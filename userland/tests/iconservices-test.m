/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * IconServices (private): named image descriptors and their sizes, and icons for an
 * app (by bundle identifier and by URL), a file, a folder, a type and the generic ones,
 * as images of the size asked for: pixel size, scale and whether one was found. Icons
 * themselves are each system's own art, so pixels aren't compared. Built without ARC: an
 * ISIcon init may hand back another object than the one allocated. Compared with Apple's.
 */
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#import <objc/runtime.h>

extern NSString *const kISImageDescriptorHomeScreen;
extern NSString *const kISImageDescriptorTableUIName;
extern NSString *const kISImageDescriptorSpotlight;
extern NSString *const kISImageDescriptorNotification;

static id
make(Class c, SEL s, id arg)
{
    return ((id(*)(id, SEL, id))objc_msgSend)([c alloc], s, arg);
}

static void
show(const char *label, id icon, id descriptor)
{
    id image = ((id(*)(id, SEL, id))objc_msgSend)(icon, sel_registerName("imageForDescriptor:"), descriptor);
    CGImageRef cg = ((CGImageRef(*)(id, SEL, id))objc_msgSend)(icon, sel_registerName("CGImageForDescriptor:"), descriptor);
    if (!image) {
        printf("%-22s no image\n", label);
        return;
    }
    CGImageRef im = ((CGImageRef(*)(id, SEL))objc_msgSend)(image, sel_registerName("CGImage"));
    double scale = ((double(*)(id, SEL))objc_msgSend)(image, sel_registerName("scale"));
    CGSize size = ((CGSize(*)(id, SEL))objc_msgSend)(image, sel_registerName("size"));
    printf("%-22s %zux%zu pixels, scale %g, size %gx%g, CGImage %d\n", label, CGImageGetWidth(im), CGImageGetHeight(im), scale,
           size.width, size.height, cg != NULL);
}

int
main(void)
{
    @autoreleasepool {
        Class Icon = objc_getClass("ISIcon"), Desc = objc_getClass("ISImageDescriptor"), Sym = objc_getClass("ISSymbol");
        printf("classes %d %d %d\n", Icon != Nil, Desc != Nil, Sym != Nil);
        for (NSString *n in @[kISImageDescriptorHomeScreen, kISImageDescriptorTableUIName, kISImageDescriptorSpotlight,
                              kISImageDescriptorNotification]) {
            id d = ((id(*)(id, SEL, id))objc_msgSend)(Desc, sel_registerName("imageDescriptorNamed:"), n);
            CGSize s = ((CGSize(*)(id, SEL))objc_msgSend)(d, sel_registerName("size"));
            double sc = ((double(*)(id, SEL))objc_msgSend)(d, sel_registerName("scale"));
            printf("%s: %gx%g @%g\n", n.UTF8String, s.width, s.height, sc);
        }
        id d32 = ((id(*)(id, SEL, CGSize, double))objc_msgSend)([Desc alloc], sel_registerName("initWithSize:scale:"),
                                                                 CGSizeMake(32, 32), 2);
        id home = ((id(*)(id, SEL, id))objc_msgSend)(Desc, sel_registerName("imageDescriptorNamed:"), kISImageDescriptorHomeScreen);
        show("app by identifier", make(Icon, sel_registerName("initWithBundleIdentifier:"), @"com.apple.TextEdit"), d32);
        show("app by URL", make(Icon, sel_registerName("initWithURL:"), [NSURL fileURLWithPath:@"/System/Applications/TextEdit.app"]), home);
        show("file", make(Icon, sel_registerName("initWithURL:"), [NSURL fileURLWithPath:@"/etc/hosts"]), d32);
        show("folder", make(Icon, sel_registerName("initWithURL:"), [NSURL fileURLWithPath:@"/tmp/"]), d32);
        show("type", make(Icon, sel_registerName("initWithType:"), @"public.plain-text"), d32);
        show("extension", make(Icon, sel_registerName("initWithFileExtension:"), @"png"), d32);
        show("generic application", ((id(*)(id, SEL))objc_msgSend)(Icon, sel_registerName("genericApplicationIcon")), d32);
        show("generic document", ((id(*)(id, SEL))objc_msgSend)(Icon, sel_registerName("genericDocumentIcon")), home);
        NSError *e = nil;
        id sym = ((id(*)(id, SEL, id, NSError **))objc_msgSend)(Sym, sel_registerName("symbolForTypeIdentifier:error:"), @"x.unknown.nothing", &e);
        printf("symbol for an unknown type: %d\n", sym != nil);
    }
    return 0;
}
