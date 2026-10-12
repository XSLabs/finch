/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AppKit in typedstreams (NSArchiver), as old documents, resources and copies by
 * archiving have it. NSColor: the bytes each kind of colour archives as (its
 * space's number, then its components as floats) and what they unarchive as; catalog
 * colours come back by name (Apple's also carry an old fallback colour, not compared), and
 * an array of colours as an app's old resource file has them. Then NSFont the same way
 * (its name as UTF-16 in a data object, its size, flags and any matrix), and a font
 * archived by an older AppKit (class version 21, big-endian UTF-16). Then the bytes and
 * round trips of transforms, colour lists, named images, paragraph styles and their tabs,
 * shadows, Bézier paths and print info (Apple's leaves its printer and job settings out).
 * Compared with Apple's.
 */
#import <AppKit/AppKit.h>

static void
dump(const char *label, id color, BOOL bytes)
{
    NSData *d = [NSArchiver archivedDataWithRootObject:color];
    const uint8_t *b = d.bytes;
    /* (after the stream's header and the NSColor class's name) */
    NSUInteger start = 0;
    for (NSUInteger i = 0; i + 7 < d.length; i++)
        if (!memcmp(b + i, "NSObject", 8)) {
            start = i + 9;
            break;
        }
    printf("%-9s", label);
    for (NSUInteger i = start; bytes && i < d.length; i++)
        printf(" %02x", b[i]);
    NSUnarchiver *u = [[NSUnarchiver alloc] initForReadingWithData:d];
    id back = [u decodeObject];
    printf(" (version %ld)", (long)[u versionForClassName:NSStringFromClass([color classForCoder])]);
    NSString *desc = [back isKindOfClass:[NSColor class]] ? [back description] : NSStringFromClass([back classForCoder]);
    if ([back isKindOfClass:[NSFont class]]) {
        /* (Finch's fonts stand in for some of Apple's: the font asked for, by its name) */
        NSFont *f = back;
        desc = [NSString stringWithFormat:@"%s %g matrix %g %g %g %g", [f.fontName isEqual:[color fontName]] ? "same font" : "other font",
                                          f.pointSize, f.matrix[0], f.matrix[1], f.matrix[2], f.matrix[3]];
    }
    printf("\n          back: %s\n", desc.UTF8String);
}

int
main(void)
{
    @autoreleasepool {
        dump("calrgb", [NSColor colorWithCalibratedRed:0.25 green:0.5 blue:0.75 alpha:0.5], YES);
        dump("devrgb", [NSColor colorWithDeviceRed:0.25 green:0.5 blue:0.75 alpha:1], YES);
        dump("calwhite", [NSColor colorWithCalibratedWhite:0.5 alpha:1], YES);
        dump("devwhite", [NSColor colorWithDeviceWhite:0.5 alpha:0.25], YES);
        dump("cmyk", [NSColor colorWithDeviceCyan:0.25 magenta:0.5 yellow:0.75 black:0.125 alpha:1], YES);
        dump("black", [NSColor blackColor], YES);
        dump("clear", [NSColor clearColor], YES);
        dump("catalog", [NSColor colorWithCatalogName:@"System" colorName:@"textColor"], NO);
        dump("control", [NSColor controlTextColor], NO);
        dump("hsb", [NSColor colorWithCalibratedHue:0.5 saturation:0.5 brightness:0.5 alpha:1], YES);

        /* an array of two colours, as an old resource file has them */
        NSArray *two = @[[NSColor colorWithCalibratedRed:1 green:1 blue:1 alpha:1], [NSColor colorWithCalibratedWhite:0.5 alpha:1]];
        NSArray *back = [NSUnarchiver unarchiveObjectWithData:[NSArchiver archivedDataWithRootObject:two]];
        printf("array: %lu, %s / %s\n", (unsigned long)back.count, [back[0] description].UTF8String, [back[1] description].UTF8String);

        dump("helvetica", [NSFont fontWithName:@"Helvetica" size:12], NO);
        dump("menlo", [NSFont fontWithName:@"Menlo-Bold" size:9.5], NO);
        CGFloat m[6] = {12, 0, 3, 12, 0, 0};
        dump("oblique", [NSFont fontWithName:@"Helvetica" matrix:m], NO);
        dump("system", [NSFont systemFontOfSize:13], YES);
        dump("bold", [NSFont boldSystemFontOfSize:11], YES);
        dump("medium", [NSFont systemFontOfSize:12 weight:NSFontWeightMedium], NO);

        /* Times Roman at 18, as a 2000s AppKit archived it */
        static const uint8_t old[] = {
            0x04, 0x0b, 't', 'y', 'p', 'e', 'd', 's', 't', 'r', 'e', 'a', 'm', 0x81, 0x03, 0xe8, 0x84, 0x01, '@', 0x84, 0x84, 0x84, 0x06,
            'N', 'S', 'F', 'o', 'n', 't', 0x15, 0x84, 0x84, 0x08, 'N', 'S', 'O', 'b', 'j', 'e', 'c', 't', 0x00, 0x85, 0x84, 0x01, 'i',
            0x20, 0x84, 0x05, '[', '3', '2', 'c', ']', 0x06, 0x00, 0x00, 0x00, 0x18, 0x00, 0x00, 0x00, 0xfe, 0xff, 0x00, 'T', 0x00, 'i',
            0x00, 'm', 0x00, 'e', 0x00, 's', 0x00, '-', 0x00, 'R', 0x00, 'o', 0x00, 'm', 0x00, 'a', 0x00, 'n', 0x84, 0x01, 'f', 0x12,
            0x84, 0x01, 'c', 0x00, 0x98, 0x01, 0x98, 0x00, 0x98, 0x00, 0x86};
        NSFont *f = [NSUnarchiver unarchiveObjectWithData:[NSData dataWithBytes:old length:sizeof old]];
        printf("old font: %s %g\n", [f.fontName isEqual:[NSFont fontWithName:@"Times-Roman" size:18].fontName] ? "Times Roman" : "other",
               f.pointSize);

        NSAffineTransform *t = [NSAffineTransform transform];
        [t translateXBy:2 yBy:3];
        [t scaleBy:1.5];
        dump("affine", (id)t, YES);
        NSAffineTransform *tb = [NSUnarchiver unarchiveObjectWithData:[NSArchiver archivedDataWithRootObject:t]];
        NSAffineTransformStruct ts = tb.transformStruct;
        printf("          transform %g %g %g %g %g %g\n", ts.m11, ts.m12, ts.m21, ts.m22, ts.tX, ts.tY);
        dump("colorlist", (id)[[NSColorList alloc] initWithName:@"x"], YES);
        NSImage *named = [NSImage imageNamed:NSImageNameCaution];
        NSImage *namedBack = [NSUnarchiver unarchiveObjectWithData:[NSArchiver archivedDataWithRootObject:named]];
        printf("named image: same object back %d\n", namedBack == named);
        @try {
            NSImage *drawn = [[NSImage alloc] initWithSize:NSMakeSize(2, 2)];
            [NSArchiver archivedDataWithRootObject:drawn];
            printf("unnamed image: archived\n");
        } @catch (NSException *e) {
            printf("unnamed image: %s\n", e.name.UTF8String);
        }

        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
        dump("para", ps, YES);
        ps.alignment = NSTextAlignmentCenter;
        ps.lineSpacing = 3;
        ps.firstLineHeadIndent = 4;
        ps.headIndent = 5;
        ps.tailIndent = -6;
        ps.lineBreakMode = NSLineBreakByTruncatingTail;
        ps.minimumLineHeight = 7;
        ps.maximumLineHeight = 8;
        ps.paragraphSpacing = 9;
        ps.paragraphSpacingBefore = 10;
        ps.lineHeightMultiple = 1.5;
        ps.defaultTabInterval = 11;
        ps.tabStops = @[[[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentRight location:20 options:@{}]];
        dump("para set", ps, YES);
        NSParagraphStyle *pb = [NSUnarchiver unarchiveObjectWithData:[NSArchiver archivedDataWithRootObject:ps]];
        printf("          back: %ld %ld %g %g %g %g %g %g %g %g %g %g tabs %lu\n", (long)pb.alignment, (long)pb.lineBreakMode, pb.lineSpacing,
               pb.paragraphSpacing, pb.headIndent, pb.tailIndent, pb.firstLineHeadIndent, pb.minimumLineHeight, pb.maximumLineHeight,
               pb.lineHeightMultiple, pb.paragraphSpacingBefore, pb.defaultTabInterval, (unsigned long)pb.tabStops.count);
        NSMutableParagraphStyle *p2 = [NSMutableParagraphStyle new];
        p2.hyphenationFactor = 0.5;
        p2.headerLevel = 2;
        p2.tabStops = @[];
        dump("para more", p2, YES);
        pb = [NSUnarchiver unarchiveObjectWithData:[NSArchiver archivedDataWithRootObject:p2]];
        printf("          back: hyphenation %g header %ld tightening %d tabs %lu, default tabs %lu\n", pb.hyphenationFactor, (long)pb.headerLevel,
               pb.allowsDefaultTighteningForTruncation,
               (unsigned long)pb.tabStops.count,
               (unsigned long)[[NSUnarchiver unarchiveObjectWithData:[NSArchiver archivedDataWithRootObject:[NSParagraphStyle defaultParagraphStyle]]] tabStops].count);
        NSTextTab *tabs[] = {[[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentLeft location:10 options:@{}],
                             [[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentCenter location:30 options:@{}],
                             [[NSTextTab alloc] initWithType:NSDecimalTabStopType location:40]};
        for (int i = 0; i < 3; i++) {
            dump("tab", tabs[i], YES);
            NSTextTab *b = [NSUnarchiver unarchiveObjectWithData:[NSArchiver archivedDataWithRootObject:tabs[i]]];
            printf("          type %ld at %g aligned %ld\n", (long)b.tabStopType, b.location, (long)b.alignment);
        }

        NSShadow *sh = [NSShadow new];
        dump("shadow", sh, YES);
        sh.shadowOffset = NSMakeSize(1, 0);
        dump("shadow dx", sh, YES);
        sh.shadowOffset = NSMakeSize(1, -1);
        sh.shadowBlurRadius = 2;
        sh.shadowColor = [NSColor colorWithCalibratedRed:0 green:0 blue:1 alpha:0.5];
        dump("shadow all", sh, YES);
        NSShadow *shb = [NSUnarchiver unarchiveObjectWithData:[NSArchiver archivedDataWithRootObject:sh]];
        printf("          %g %g blur %g alpha %g\n", shb.shadowOffset.width, shb.shadowOffset.height, shb.shadowBlurRadius, shb.shadowColor.alphaComponent);

        NSBezierPath *bp = [NSBezierPath bezierPath];
        [bp moveToPoint:NSMakePoint(1, 2)];
        [bp lineToPoint:NSMakePoint(3, 4)];
        [bp curveToPoint:NSMakePoint(5, 6) controlPoint1:NSMakePoint(7, 8) controlPoint2:NSMakePoint(9, 10)];
        [bp closePath];
        bp.lineWidth = 2;
        dump("path", bp, YES);
        NSBezierPath *bb = [NSUnarchiver unarchiveObjectWithData:[NSArchiver archivedDataWithRootObject:bp]];
        printf("          %ld elements, width %g, bounds %s\n", (long)bb.elementCount, bb.lineWidth, NSStringFromRect(bb.controlPointBounds).UTF8String);
        NSBezierPath *bp2 = [NSBezierPath bezierPath];
        [bp2 moveToPoint:NSMakePoint(0.5, 0)];
        bp2.lineCapStyle = NSLineCapStyleRound;
        bp2.lineJoinStyle = NSLineJoinStyleBevel;
        bp2.miterLimit = 4;
        bp2.flatness = 0.25;
        bp2.windingRule = NSWindingRuleEvenOdd;
        /* (no dash: Apple's crashes round-tripping one) */
        dump("path2", bp2, YES);
        bb = [NSUnarchiver unarchiveObjectWithData:[NSArchiver archivedDataWithRootObject:bp2]];
        CGFloat got[4] = {0};
        NSInteger ndash = 0;
        CGFloat phase = 0;
        [bb getLineDash:got count:&ndash phase:&phase];
        printf("          cap %ld join %ld miter %g flat %g winding %ld dashes %ld (%g %g) phase %g\n", (long)bb.lineCapStyle, (long)bb.lineJoinStyle,
               bb.miterLimit, bb.flatness, (long)bb.windingRule, (long)ndash, got[0], got[1], phase);

        NSPrintInfo *pi = [[NSPrintInfo alloc] initWithDictionary:@{}];
        pi.paperSize = NSMakeSize(612, 792);
        pi.orientation = NSPaperOrientationLandscape;
        pi.scalingFactor = 0.5;
        pi.jobDisposition = NSPrintSaveJob;
        pi.leftMargin = 12;
        pi.dictionary[NSPrintCopies] = @3;
        pi.dictionary[@"Custom"] = @"x";
        pi.dictionary[NSPrintFirstPage] = @2;
        NSPrintInfo *pib = [NSUnarchiver unarchiveObjectWithData:[NSArchiver archivedDataWithRootObject:pi]];
        printf("print info: paper %.0fx%.0f orientation %ld scale %g left %g disposition %s copies %s custom %s first page %s\n",
               pib.paperSize.width, pib.paperSize.height, (long)pib.orientation, pib.scalingFactor, pib.leftMargin, pib.jobDisposition.UTF8String,
               [pib.dictionary[NSPrintCopies] description].UTF8String, [pib.dictionary[@"Custom"] description].UTF8String,
               [pib.dictionary[NSPrintFirstPage] description].UTF8String);
    }
    return 0;
}
