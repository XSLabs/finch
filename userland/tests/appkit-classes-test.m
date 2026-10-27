/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-appkit-classes-test: AppKit's typesetters, NSTouch, the legacy image reps,
 * Writing Tools' coordinator and values, and the smaller document, media and system
 * classes: their defaults and answers (diff Apple's and Finch's).
 */
#import <AppKit/AppKit.h>
#import <CoreData/CoreData.h>
#include <stdio.h>
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static NSString *clean(id o) { NSString *s = [o description]; return s ? [s stringByReplacingOccurrencesOfString:@"0x[0-9a-f]+" withString:@"ADDR" options:NSRegularExpressionSearch range:NSMakeRange(0, s.length)] : @"(null)"; }
static void try(const char *what, void (^b)(void)) { @try { b(); } @catch (NSException *x) { printf("%s: %s: %s\n", what, x.name.UTF8String, clean(x.reason).UTF8String); } }
int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];
    printf("== typesetter\n");
    try("ts", ^{
        NSTypesetter *t = [NSTypesetter sharedSystemTypesetter];
        printf("shared class %s same %d\n", NSStringFromClass([t class]).UTF8String, t == [NSTypesetter sharedSystemTypesetter]);
        printf("default behavior %ld\n", (long)[NSTypesetter defaultTypesetterBehavior]);
        printf("for behavior latest %s\n", NSStringFromClass([[NSTypesetter sharedSystemTypesetterForBehavior:NSTypesetterLatestBehavior] class]).UTF8String);
        NSATSTypesetter *a = [NSATSTypesetter sharedTypesetter];
        printf("ats class %s same-as-system %d\n", NSStringFromClass([a class]).UTF8String, (id)a == (id)t);
        printf("usesFontLeading %d behavior %ld hyph %g pad %g bidi %d\n", t.usesFontLeading, (long)t.typesetterBehavior, t.hyphenationFactor, t.lineFragmentPadding, t.bidiProcessingEnabled);
        printf("attrString %d layoutManager %d container %d\n", t.attributedString != nil, t.layoutManager != nil, t.currentTextContainer != nil);
        NSLayoutManager *lm = [NSLayoutManager new];
        printf("lm typesetter %s behavior %ld\n", NSStringFromClass([lm.typesetter class]).UTF8String, (long)lm.typesetterBehavior);
        printf("baseline offset %g\n", [t baselineOffsetInLayoutManager:lm glyphIndex:0]);
        NSFont *f = [NSFont systemFontOfSize:13];
        printf("char %lu actions %lu\n", (unsigned long)[t actionForControlCharacterAtIndex:0], (unsigned long)NSTypesetterLineBreakAction);
        printf("hyph char %u\n", (unsigned)[t hyphenCharacterForGlyphAtIndex:0]);
        printf("substitute %s\n", [[t substituteFontForFont:f] fontName].UTF8String);
        printf("print %d\n", [NSTypesetter printingAdjustmentInLayoutManager:lm forNominallySpacedGlyphRange:NSMakeRange(0,0) packedGlyphs:NULL count:0].width == 0);
    });
    printf("== touch\n");
    try("touch", ^{ NSTouch *t = [NSTouch new]; printf("touch %s phase %lu identity %s resting %d type %ld\n", clean(t).UTF8String, (unsigned long)t.phase, clean(t.identity).UTF8String, t.isResting, (long)t.type); });
    printf("== image reps\n");
    try("eps", ^{
        NSData *eps = [@"%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 10 20 110 70\nnewpath 10 20 moveto 110 70 lineto stroke\nshowpage\n%%EOF\n" dataUsingEncoding:NSASCIIStringEncoding];
        NSEPSImageRep *r = [NSEPSImageRep imageRepWithData:eps];
        printf("eps %d bbox %s size %s pixels %ld x %ld can %d types %s\n", r != nil, NSStringFromRect(r.boundingBox).UTF8String, NSStringFromSize(r.size).UTF8String, (long)r.pixelsWide, (long)r.pixelsHigh, [NSEPSImageRep canInitWithData:eps], [[[NSEPSImageRep imageUnfilteredTypes] componentsJoinedByString:@","] UTF8String]);
        printf("eps rep equal %d bad %d\n", [r.EPSRepresentation isEqualToData:eps], [NSEPSImageRep imageRepWithData:[NSData dataWithBytes:"xx" length:2]] != nil);
    });
    try("pict", ^{
        NSMutableData *pict = [NSMutableData dataWithLength:512];
        uint8_t hdr[] = { 0x00, 0x00, 0x00, 0x05, 0x00, 0x06, 0x00, 0x35, 0x00, 0x46, 0x00, 0x11, 0x02, 0xff };
        [pict appendBytes:hdr length:sizeof hdr];
        NSPICTImageRep *p = [NSPICTImageRep imageRepWithData:pict];
        printf("pict %d bbox %s size %s types %s can %d\n", p != nil, NSStringFromRect(p.boundingBox).UTF8String, NSStringFromSize(p.size).UTF8String, [[[NSPICTImageRep imageUnfilteredTypes] componentsJoinedByString:@","] UTF8String], [NSPICTImageRep canInitWithData:pict]);
    });
    try("cached", ^{
        NSCachedImageRep *c = [[NSCachedImageRep alloc] initWithSize:NSMakeSize(20, 10) depth:0 separate:NO alpha:YES];
        printf("cached %d window %d rect %s size %s alpha %d\n", c != nil, c.window != nil, NSStringFromRect(c.rect).UTF8String, NSStringFromSize(c.size).UTF8String, c.hasAlpha);
    });
    printf("== writing tools\n");
    try("wt", ^{
        NSWritingToolsCoordinator *w = [[NSWritingToolsCoordinator alloc] initWithDelegate:nil];
        printf("state %ld pref %ld presult %lu result %lu markers %d view %d\n", (long)w.state, (long)w.preferredBehavior, (unsigned long)w.preferredResultOptions, (unsigned long)w.resultOptions, w.includesTextListMarkers, w.view != nil);
        NSWritingToolsCoordinatorContext *c = [[NSWritingToolsCoordinatorContext alloc] initWithAttributedString:[[NSAttributedString alloc] initWithString:@"hello world"] range:NSMakeRange(2, 3)];
        printf("context id %d range %s resolved %s string %s\n", c.identifier != nil, NSStringFromRange(c.range).UTF8String, NSStringFromRange(c.resolvedRange).UTF8String, c.attributedString.string.UTF8String);
    });
    try("preview", ^{
        CGContextRef ctx = CGBitmapContextCreate(NULL, 4, 4, 8, 16, CGColorSpaceCreateDeviceRGB(), (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGImageRef img = CGBitmapContextCreateImage(ctx);
        NSTextPreview *p = [[NSTextPreview alloc] initWithSnapshotImage:img presentationFrame:NSMakeRect(1,2,3,4)];
        printf("preview image %d frame %s rects %lu\n", p.previewImage == img, NSStringFromRect(p.presentationFrame).UTF8String, (unsigned long)p.candidateRects.count);
    });
    printf("== misc\n");
    try("align", ^{
        NSAlignmentFeedbackFilter *f = [NSAlignmentFeedbackFilter new];
        printf("mask %llx token %d same %d\n", (unsigned long long)NSAlignmentFeedbackFilter.inputEventMask,
            [f alignmentFeedbackTokenForMovementInView:nil previousPoint:NSMakePoint(0,0) alignedPoint:NSMakePoint(5,5) defaultPoint:NSMakePoint(6,6)] != nil,
            [f alignmentFeedbackTokenForHorizontalMovementInView:nil previousX:0 alignedX:5 defaultX:5] != nil);
    });
    try("bgext", ^{ NSBackgroundExtensionView *b = [[NSBackgroundExtensionView alloc] initWithFrame:NSMakeRect(0,0,10,10)]; printf("bgext auto %d content %d\n", b.automaticallyPlacesContentView, b.contentView != nil); });
    try("fontasset", ^{
        NSFontAssetRequest *r = [[NSFontAssetRequest alloc] initWithFontDescriptors:@[[NSFontDescriptor fontDescriptorWithName:@"Helvetica" size:12]] options:0];
        printf("progress total %lld done %lld downloaded %lu\n", r.progress.totalUnitCount, r.progress.completedUnitCount, (unsigned long)r.downloadedFontDescriptors.count);
    });
    try("media", ^{ NSMediaLibraryBrowserController *m = NSMediaLibraryBrowserController.sharedMediaLibraryBrowserController; printf("media visible %d frame %s libs %lu same %d\n", m.isVisible, NSStringFromRect(m.frame).UTF8String, (unsigned long)m.mediaLibraries, m == NSMediaLibraryBrowserController.sharedMediaLibraryBrowserController); });
    try("movie", ^{ printf("movie init %d\n", [[NSMovie alloc] init] != nil); });
    try("speech", ^{ NSSpeechRecognizer *s = [NSSpeechRecognizer new]; printf("speech %d fg %d blocks %d title %s commands %s\n", s != nil, s.listensInForegroundOnly, s.blocksOtherRecognizers, s.displayedCommandsTitle.UTF8String, clean(s.commands).UTF8String); });
    try("checking", ^{
        NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0,0,100,100)];
        NSTextCheckingController *c = [[NSTextCheckingController alloc] initWithClient:(id)tv];
        printf("checking client %d tag %ld annotations %s\n", c.client == (id)tv, (long)c.spellCheckerDocumentTag, [[[c validAnnotations] componentsJoinedByString:@","] UTF8String]);
    });
    try("inputserver", ^{ NSInputServer *s = [[NSInputServer alloc] initWithDelegate:nil name:@"x"]; printf("inputserver %d canBeDisabled %d\n", s != nil, [s canBeDisabled]); });
    printf("== persistent document\n");
    try("pdoc", ^{
        NSPersistentDocument *d = [NSPersistentDocument new];
        printf("model %s context %s store type %s\n", clean(d.managedObjectModel).UTF8String, NSStringFromClass([d.managedObjectContext class]).UTF8String, [d persistentStoreTypeForFileType:@"public.data"].UTF8String);
        printf("context psc %d undo %d hasUndo %d\n", d.managedObjectContext.persistentStoreCoordinator != nil, d.managedObjectContext.undoManager != nil, d.hasUndoManager);
    });
    try("workspace auth", ^{ printf("fm auth class %s\n", NSStringFromClass([NSFileManager class]).UTF8String); });
}}
