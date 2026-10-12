/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Symbol images (+imageWithSystemSymbolName:): which names give an image (variants made
 * with .fill, .circle, .slash and badges, and names that don't exist), that they're
 * templates with no name and an accessibility description, how their size follows the
 * point size and the scale (as ratios: Finch's glyphs are its own), configurations
 * applied and kept, and the private call apps use. SYMBOLS_SHEET=PATH saves Finch's
 * glyphs as a contact sheet. Compared with Apple's.
 */
#import <AppKit/AppKit.h>
#import <objc/message.h>

int
main(void)
{
    @autoreleasepool {
        NSArray *names = @[@"star", @"star.fill", @"heart.fill", @"xmark", @"xmark.circle.fill", @"checkmark.circle", @"info.circle",
                           @"plus.circle.fill", @"trash", @"trash.fill", @"folder.badge.plus", @"eye.slash", @"speaker.slash.fill",
                           @"gearshape.2", @"person.crop.circle.fill", @"square.and.arrow.up", @"magnifyingglass", @"chevron.right",
                           @"doc", @"doc.badge.gearshape", @"calculator", @"arrow.clockwise", @"play.fill", @"pause.circle.fill", @"lock.fill", @"printer", @"film",
                           @"nonexistent.symbol", @"", @"star.fill.fill"];
        for (NSString *n in names) {
            NSImage *im = [NSImage imageWithSystemSymbolName:n accessibilityDescription:nil];
            printf("%-24s %s", n.UTF8String, im ? "image" : "none");
            if (im)
                printf(" template %d name %d description %d", im.template, im.name != nil, im.accessibilityDescription.length > 0);
            printf("\n");
        }
        NSImage *star = [NSImage imageWithSystemSymbolName:@"star" accessibilityDescription:@"Favourite"];
        printf("description given: %s\n", star.accessibilityDescription.UTF8String);
        NSSize base = star.size;
        for (NSNumber *pt in @[@10, @20, @40]) {
            NSImage *c = [star imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:pt.doubleValue
                                                                                                           weight:NSFontWeightRegular]];
            printf("at %g points: height ratio %.1f\n", pt.doubleValue, c.size.height / base.height);
        }
        NSImage *small = [star imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithScale:NSImageSymbolScaleSmall]];
        NSImage *large = [star imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithScale:NSImageSymbolScaleLarge]];
        printf("scales: small %.1f large %.1f\n", small.size.height / base.height, large.size.height / base.height);
        NSImage *bold = [star imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightBold]];
        printf("bold: image %d, configuration %d, description kept %d\n", bold != nil, bold.symbolConfiguration != nil,
               [bold.accessibilityDescription isEqual:@"Favourite"]);
        printf("plain image's configuration %d\n", [[NSImage alloc] initWithSize:NSMakeSize(4, 4)].symbolConfiguration != nil);
        NSImage *priv = ((id (*)(id, SEL, id))objc_msgSend)([NSImage class], sel_registerName("_imageWithSystemSymbolName:"), @"gear");
        printf("private call: %d template %d\n", priv != nil, priv.template);
        /* a private symbol: only the private call gives it */
        NSImage *calc = ((id (*)(id, SEL, id))objc_msgSend)([NSImage class], sel_registerName("_imageWithSystemSymbolName:"), @"calculator");
        printf("private symbol: private call %d (%gx%g, description %d), public call %d\n", calc != nil, calc.size.width, calc.size.height,
               calc.accessibilityDescription != nil, [NSImage imageWithSystemSymbolName:@"calculator" accessibilityDescription:nil] != nil);

        const char *sheet = getenv("SYMBOLS_SHEET");
        if (sheet) {
            NSMutableArray *show = [NSMutableArray arrayWithArray:names];
            for (NSString *extra in @[@"heart", @"bell", @"calendar", @"clock", @"house", @"globe", @"envelope", @"paperplane", @"camera",
                                      @"photo", @"mic", @"video", @"keyboard", @"display", @"sun.max", @"moon", @"bolt", @"cloud",
                                      @"wifi", @"link", @"tag", @"bookmark", @"pencil", @"scissors", @"key", @"lock.open", @"eye",
                                      @"slider.horizontal.3", @"list.bullet", @"square.grid.2x2", @"sidebar.leading", @"arrow.uturn.backward",
                                      @"arrow.left.arrow.right", @"speaker.wave.3.fill", @"doc.on.doc", @"square.and.pencil",
                                      @"textformat.size.larger", @"hand.thumbsup.fill", @"camera.filters", @"fan", @"mug", @"wind",
                                      @"translate", @"signature", @"pip", @"aspectratio", @"person.2", @"mappin.and.ellipse"])
                [show addObject:extra];
            int cols = 10, cell = 64;
            NSUInteger n = show.count;
            int rows = (int)((n + cols - 1) / cols);
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:cols * cell pixelsHigh:rows * cell
                bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:32];
            [NSGraphicsContext saveGraphicsState];
            NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
            [[NSColor colorWithWhite:0.96 alpha:1] setFill];
            NSRectFill(NSMakeRect(0, 0, cols * cell, rows * cell));
            for (NSUInteger i = 0; i < n; i++) {
                NSImage *im = [NSImage imageWithSystemSymbolName:show[i] accessibilityDescription:nil];
                im = [im imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:26 weight:NSFontWeightRegular]];
                NSRect c = NSMakeRect((i % cols) * cell, (rows - 1 - (int)(i / cols)) * cell, cell, cell);
                [im drawInRect:NSMakeRect(NSMidX(c) - im.size.width / 2, NSMidY(c) - im.size.height / 2, im.size.width, im.size.height)];
            }
            [NSGraphicsContext restoreGraphicsState];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(sheet) atomically:YES];
        }
    }
    return 0;
}
