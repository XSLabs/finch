/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Small behaviours apps depend on, found running them: the standard colours are one
 * object each (apps keep them unretained), CFGetTypeID of any object, which views update
 * their layers instead of drawing, text fields' intrinsic widths (editable or not,
 * scrolling or wrapping), borders and bezels clearing each other, and a label's size
 * following its value under Auto Layout, and SPI apps call (a cell's vertical centring
 * flag as archived, its highlight drawing, a font's glyph for a character), and an image
 * view keeping its own target (its cell can't), and old images' flipped flag (it flips
 * only drawing into the image) and compositing in flipped contexts. Compared with
 * Apple's.
 */
#import <AppKit/AppKit.h>
#import <objc/message.h>

@interface Updates : NSView
@end
@implementation Updates
- (void)updateLayer
{
}
@end

@interface Draws : NSView
@end
@implementation Draws
- (void)drawRect:(NSRect)r
{
}
@end

@interface DrawsToo : Draws
@end
@implementation DrawsToo
@end

/* Where red lands in a 20x20 bitmap: an image whose top half was filled red through
   its own lockFocus, drawn three ways. */
static const char *
red_at(NSBitmapImageRep *rep)
{
    NSColor *top = [rep colorAtX:10 y:2], *bot = [rep colorAtX:10 y:17];
    BOOL t = top.redComponent > 0.5 && top.greenComponent < 0.3, b = bot.redComponent > 0.5 && bot.greenComponent < 0.3;
    return t && !b ? "top" : b && !t ? "bottom" : t && b ? "both" : "none";
}

static void
flipped_images(void)
{
    for (int imgFlipped = 0; imgFlipped < 2; imgFlipped++) {
        NSImage *im = [[NSImage alloc] initWithSize:NSMakeSize(20, 20)];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        im.flipped = imgFlipped;
#pragma clang diagnostic pop
        [im lockFocus];
        [[NSColor whiteColor] set];
        NSRectFill(NSMakeRect(0, 0, 20, 20));
        [[NSColor redColor] set];
        NSRectFill(NSMakeRect(0, 10, 20, 10));
        [im unlockFocus];
        for (int ctxFlipped = 0; ctxFlipped < 2; ctxFlipped++)
            for (int how = 0; how < 3; how++) {
                NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:20 pixelsHigh:20 bitsPerSample:8
                    samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:32];
                CGContextRef cg = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep].CGContext;
                if (ctxFlipped) {
                    CGContextTranslateCTM(cg, 0, 20);
                    CGContextScaleCTM(cg, 1, -1);
                }
                [NSGraphicsContext saveGraphicsState];
                NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:cg flipped:ctxFlipped];
                NSRect r = NSMakeRect(0, 0, 20, 20);
                if (how == 0)
                    [im drawInRect:r fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
                else if (how == 1)
                    [im drawInRect:r fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
                else
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                    [im compositeToPoint:NSMakePoint(0, ctxFlipped ? 20 : 0) operation:NSCompositingOperationSourceOver];
#pragma clang diagnostic pop
                [NSGraphicsContext restoreGraphicsState];
                printf("image flipped %d in a %s context, %s: red at %s\n", imgFlipped, ctxFlipped ? "flipped" : "plain",
                       how == 0 ? "drawn" : how == 1 ? "drawn respecting flipped" : "composited", red_at(rep));
            }
    }
}

int
main(void)
{
    @autoreleasepool {
        printf("standard colours, one object each:");
        for (NSString *n in @[ @"blackColor", @"whiteColor", @"clearColor", @"grayColor", @"redColor", @"blueColor", @"brownColor" ]) {
            SEL s = NSSelectorFromString(n);
            id (*send)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
            printf(" %d", send([NSColor class], s) == send([NSColor class], s));
        }
        printf("\n");

        id image = [NSImage new], object = [NSObject new];
        printf("CFGetTypeID: image %lu, object %lu, string is string %d\n", CFGetTypeID((__bridge CFTypeRef)image),
            CFGetTypeID((__bridge CFTypeRef)object), CFGetTypeID((__bridge CFTypeRef)@"x") == CFStringGetTypeID());

        printf("wantsUpdateLayer: NSView %d, updates %d, draws %d, inherits drawing %d\n", [NSView new].wantsUpdateLayer,
            [Updates new].wantsUpdateLayer, [Draws new].wantsUpdateLayer, [DrawsToo new].wantsUpdateLayer);

        printf("text field widths (editable, scrollable, selectable, wraps):\n ");
        for (int ed = 0; ed < 2; ed++)
            for (int sc = 0; sc < 2; sc++)
                for (int sel = 0; sel < 2; sel++)
                    for (int wr = 0; wr < 2; wr++) {
                        NSTextField *f = [NSTextField labelWithString:@"Hello 233"];
                        f.editable = ed;
                        f.cell.scrollable = sc;
                        f.selectable = sel;
                        f.cell.wraps = wr;
                        printf(" %d%d%d%d:%s", ed, sc, sel, wr, f.intrinsicContentSize.width < 0 ? "none" : "own");
                    }
        printf("\n");
        NSTextField *t = [NSTextField textFieldWithString:@"Hello"];
        printf("text field: width %s, scrollable %d", t.intrinsicContentSize.width < 0 ? "none" : "own", t.cell.scrollable);
        t.editable = NO;
        printf(", not editable: width %s\n", t.intrinsicContentSize.width < 0 ? "none" : "own");

        for (Class k in @[ [NSCell class], [NSTextFieldCell class], [NSButtonCell class] ]) {
            NSCell *c = [[k alloc] initTextCell:@"x"];
            c.bezeled = YES;
            c.bordered = NO;
            printf("%s: bezeled after bordered NO %d", NSStringFromClass(k).UTF8String, c.bezeled);
            c.bordered = YES;
            c.bezeled = NO;
            printf(", bordered after bezeled NO %d\n", c.bordered);
        }
        NSTextField *b = [NSTextField textFieldWithString:@"x"];
        b.bordered = NO;
        printf("text field bordered NO: bezeled %d\n", b.bezeled);

        NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 100)];
        NSTextField *l = [NSTextField labelWithString:@""];
        l.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:l];
        [l.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:10].active = YES;
        [l.topAnchor constraintEqualToAnchor:root.topAnchor constant:10].active = YES;
        [root layoutSubtreeIfNeeded];
        CGFloat empty = l.frame.size.width;
        l.stringValue = @"Red value:";
        [root layoutSubtreeIfNeeded];
        CGFloat set = l.frame.size.width;
        l.objectValue = @12345678;
        [root layoutSubtreeIfNeeded];
        printf("label under Auto Layout: grows with its string %d, with a number %d\n", set > empty + 20,
            l.frame.size.width > set);
        flipped_images();

        NSTextFieldCell *vc = [[NSTextFieldCell alloc] initTextCell:@"x"];
        ((void (*)(id, SEL, BOOL))objc_msgSend)(vc, sel_registerName("_setVerticallyCentered:"), YES);
        NSKeyedArchiver *ka = [[NSKeyedArchiver alloc] initRequiringSecureCoding:NO];
        [vc encodeWithCoder:ka];
        [ka finishEncoding];
        NSKeyedUnarchiver *ku = [[NSKeyedUnarchiver alloc] initForReadingFromData:ka.encodedData error:nil];
        ku.requiresSecureCoding = NO;
        printf("vertically centred flag archived: %#x\n", [ku decodeIntForKey:@"NSCellFlags"] & 0x02000000);
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:4 pixelsHigh:4 bitsPerSample:8
            samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:16 bitsPerPixel:32];
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
        NSCell *hc = [[NSCell alloc] initTextCell:@""];
        ((void (*)(id, SEL, NSRect, id))objc_msgSend)(hc, sel_registerName("_drawHighlightWithFrame:inView:"), NSMakeRect(0, 0, 4, 4), nil);
        [NSGraphicsContext restoreGraphicsState];
        NSColor *drawn = [rep colorAtX:2 y:2];
        printf("highlight drawn: alpha %.0f, not black %d\n", drawn.alphaComponent, drawn.redComponent + drawn.greenComponent + drawn.blueComponent > 0.5);
        NSView *hv = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
        printf("highlight colours: no view %s, a view %s\n", [[hc highlightColorWithFrame:NSZeroRect inView:(NSView *_Nonnull)(id)nil] description].UTF8String,
            [[hc highlightColorWithFrame:NSZeroRect inView:hv] description].UTF8String);
        NSImageView *iv = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
        iv.target = hv;
        iv.action = @selector(display);
        printf("image view: target kept %d, action %s, its cell's target %d\n", iv.target == hv, sel_getName(iv.action), [iv.cell target] == hv);
        @try {
            [hc setTarget:hv];
        } @catch (NSException *e) {
            printf("plain cell's target: %s %s\n", e.name.UTF8String, e.reason.UTF8String);
        }
        NSBitmapImageRep *one = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:40 pixelsHigh:20 bitsPerSample:8
            samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:32];
        one.size = NSMakeSize(20, 10);
        NSImage *ofRep = ((id (*)(id, SEL, id))objc_msgSend)([NSImage alloc], sel_registerName("initWithImageRep:"), one);
        printf("image of one rep: %s, reps %lu, same rep %d\n", NSStringFromSize(ofRep.size).UTF8String, (unsigned long)ofRep.representations.count,
               ofRep.representations.firstObject == one);
        NSArray *mixed = @[@"a", @1, @"b", @2.5];
        NSArray *nums = ((id (*)(id, SEL, Class))objc_msgSend)(mixed, sel_registerName("subarrayWithObjectsOfKind:"), [NSNumber class]);
        NSMutableArray *ins = [@[@1, @2] mutableCopy];
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(ins, sel_registerName("insertObjectsFromArray:atIndex:"), @[@8, @9], 1);
        printf("array additions: %s / %s\n", [nums componentsJoinedByString:@","].UTF8String, [ins componentsJoinedByString:@","].UTF8String);
        NSAttributedString *rich = [[NSAttributedString alloc] initWithString:@"hello" attributes:@{NSFontAttributeName : [NSFont systemFontOfSize:12],
            NSForegroundColorAttributeName : [NSColor redColor], NSLinkAttributeName : @"x", NSKernAttributeName : @2,
            NSParagraphStyleAttributeName : [NSParagraphStyle defaultParagraphStyle], NSUnderlineStyleAttributeName : @1,
            NSToolTipAttributeName : @"t", NSBackgroundColorAttributeName : [NSColor blueColor], @"Custom" : @1,
            NSSuperscriptAttributeName : @1, NSShadowAttributeName : [NSShadow new], NSObliquenessAttributeName : @0.1,
            NSLigatureAttributeName : @0, NSBaselineOffsetAttributeName : @1, NSStrokeWidthAttributeName : @1}];
        printf("font attributes: %s\n", [[[[rich fontAttributesInRange:NSMakeRange(0, 3)] allKeys] sortedArrayUsingSelector:@selector(compare:)]
                                             componentsJoinedByString:@","].UTF8String);
        printf("ruler attributes: %s\n", [[[[rich rulerAttributesInRange:NSMakeRange(0, 3)] allKeys] sortedArrayUsingSelector:@selector(compare:)]
                                              componentsJoinedByString:@","].UTF8String);
        printf("preferred fonts: %s\n", [[((id (*)(id, SEL))objc_msgSend)([NSFont class], sel_registerName("preferredFontNames"))
                                              componentsJoinedByString:@","] UTF8String]);
        NSWindow *uw = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 10, 10) styleMask:NSWindowStyleMaskTitled
                                                     backing:NSBackingStoreBuffered defer:YES];
        uw.releasedWhenClosed = NO;
        __block int undone = 0;
        [uw.undoManager registerUndoWithTarget:uw handler:^(id t) { undone = 1; }];
        ((void (*)(id, SEL, id))objc_msgSend)(uw, sel_registerName("undo:"), nil);
        printf("window undo: %d\n", undone);
        NSCursor *zin = ((id (*)(id, SEL))objc_msgSend)([NSCursor class], sel_registerName("_zoomInCursor"));
        NSCursor *zout = ((id (*)(id, SEL))objc_msgSend)([NSCursor class], sel_registerName("_zoomOutCursor"));
        printf("zoom cursors: %s hot %s, out differs %d, same twice %d\n", NSStringFromSize(zin.image.size).UTF8String,
               NSStringFromPoint(zin.hotSpot).UTF8String, zin != zout,
               zin == ((id (*)(id, SEL))objc_msgSend)([NSCursor class], sel_registerName("_zoomInCursor")));
        NSFont *sys = [NSFont systemFontOfSize:12];
        unichar chars[] = {'A', ' ', 0x4e00, 0xd83d};
        for (int i = 0; i < 4; i++) {
            CGGlyph g = 0;
            CTFontGetGlyphsForCharacters((CTFontRef)sys, &chars[i], &g, 1);
            NSGlyph dg = ((NSGlyph (*)(id, SEL, unichar))objc_msgSend)(sys, sel_registerName("_defaultGlyphForChar:"), chars[i]);
            printf("default glyph for %04x: as CoreText's %d, none %d\n", chars[i], dg == g, dg == 0);
        }
    }
    return 0;
}
