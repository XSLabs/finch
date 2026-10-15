/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Local AppKit values and APIs that do not need a screen, printer or Apple service. */
#import <AppKit/AppKit.h>
#import <CoreImage/CoreImage.h>

static void
out(NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *text = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    printf("%s\n", text.UTF8String);
}

static void
show_size(NSString *label, NSSize size)
{
    printf("  %s %.0f x %.0f\n", label.UTF8String, size.width, size.height);
}

static void
printing(void)
{
    out(@"printing:");
    show_size(@"letter", [NSPrintInfo sizeForPaperName:@"na-letter"]);
    show_size(@"a4", [NSPrintInfo sizeForPaperName:@"iso-a4"]);
    show_size(@"unknown", [NSPrintInfo sizeForPaperName:@"no-such-paper"]);

    NSPDFInfo *pdf = [NSPDFInfo new];
    pdf.URL = [NSURL fileURLWithPath:@"/Finch-test.pdf"];
    [pdf.attributes addEntriesFromDictionary:@{NSPrintCopies : @3, @"FinchTestAttribute" : @"kept"}];
    NSPrintInfo *info = [[NSPrintInfo alloc] init];
    [info takeSettingsFromPDFInfo:pdf];
    out(@"  PDF settings copies %ld custom %@", (long)[info.dictionary[NSPrintCopies] integerValue], info.dictionary[@"FinchTestAttribute"]);

    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 100, 40)];
    NSPrintOperation *operation = [NSPrintOperation printOperationWithView:view printInfo:info];
    NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 20, 10)];
    operation.accessoryView = accessory;
    operation.jobStyleHint = @"FinchTestStyle";
    [operation setShowPanels:NO];
    out(@"  operation accessory %d style %@ old-panels %d print %d progress %d", operation.accessoryView == accessory,
           operation.jobStyleHint, operation.showPanels, operation.showsPrintPanel, operation.showsProgressPanel);

    NSPrintPanel *panel = [NSPrintPanel printPanel];
    panel.defaultButtonTitle = @"Continue";
    panel.accessoryView = accessory;
    panel.jobStyleHint = @"FinchTestStyle";
    [panel updateFromPrintInfo];
    [panel finalWritePrintInfo];
    out(@"  print panel title %@ accessory %d controllers %lu style %@", panel.defaultButtonTitle,
           panel.accessoryView == accessory, (unsigned long)panel.accessoryControllers.count, panel.jobStyleHint);

    NSPageLayout *layout = [NSPageLayout pageLayout];
    layout.accessoryView = accessory;
    [layout readPrintInfo];
    [layout writePrintInfo];
    out(@"  page layout accessory %d controllers %lu", layout.accessoryView == accessory, (unsigned long)layout.accessoryControllers.count);
}

static void
text_values(void)
{
    out(@"text values:");
    NSTextAlternatives *alternatives = [[NSTextAlternatives alloc] initWithPrimaryString:@"color" alternativeStrings:@[@"colour", @"hue"]];
    __block NSString *selected = nil;
    id observer = [[NSNotificationCenter defaultCenter] addObserverForName:NSTextAlternativesSelectedAlternativeStringNotification
                                                                     object:nil
                                                                      queue:nil
                                                                 usingBlock:^(NSNotification *note) {
        selected = [note.object isKindOfClass:[NSString class]]
                        ? note.object
                        : note.userInfo[@"NSAlternativeString"];
    }];
    [alternatives noteSelectedAlternativeString:@"colour"];
    out(@"  alternatives %@ %@ selected %@", alternatives.primaryString, [alternatives.alternativeStrings componentsJoinedByString:@","], selected);
    [[NSNotificationCenter defaultCenter] removeObserver:observer];

    NSFont *font = [NSFont fontWithName:@"Helvetica" size:12];
    NSGlyphInfo *glyph = [NSGlyphInfo glyphInfoWithGlyphName:@"A" forFont:font baseString:@"A"];
    NSGlyphInfo *character = [NSGlyphInfo glyphInfoWithCharacterIdentifier:65 collection:NSIdentityMappingCharacterCollection baseString:@"A"];
    out(@"  glyph %@ %u %@ name %@; character %lu collection %lu", glyph.baseString, glyph.glyphID, glyph.characterCollection == NSIdentityMappingCharacterCollection ? @"identity" : @"other",
           glyph.glyphName, (unsigned long)character.characterIdentifier, (unsigned long)character.characterCollection);

    NSTextList *list = [[NSTextList alloc] initWithMarkerFormat:NSTextListMarkerDecimal options:0];
    NSAttributedString *first = [[NSAttributedString alloc] initWithString:@"first"];
    NSAttributedString *second = [[NSAttributedString alloc] initWithString:@"second"];
    NSTextListElement *a = [NSTextListElement textListElementWithContents:first markerAttributes:nil textList:list childElements:nil];
    NSTextListElement *b = [NSTextListElement textListElementWithContents:second markerAttributes:nil textList:list childElements:nil];
    NSTextListElement *group = [NSTextListElement textListElementWithChildElements:@[a, b] textList:list nestingLevel:0];
    out(@"  list children %lu parent %d; content %@ display %@", (unsigned long)group.childElements.count,
           a.parentElement == group, a.contents.string, a.attributedString.string);

    NSCollectionViewUpdateItem *update = [[NSCollectionViewUpdateItem alloc] init];
    out(@"  collection update action %ld before %d after %d", (long)update.updateAction,
           update.indexPathBeforeUpdate != nil, update.indexPathAfterUpdate != nil);

    NSMutableAttributedString *edited = [[NSMutableAttributedString alloc] initWithString:@"ab\ncd"];
    [edited setAlignment:NSTextAlignmentCenter range:NSMakeRange(0, 2)];
    [edited superscriptRange:NSMakeRange(0, 1)];
    [edited subscriptRange:NSMakeRange(0, 1)];
    out(@"  edits align %ld script %ld", (long)[[edited attribute:NSParagraphStyleAttributeName atIndex:0 effectiveRange:NULL] alignment],
           (long)[[edited attribute:NSSuperscriptAttributeName atIndex:0 effectiveRange:NULL] integerValue]);
    [edited unscriptRange:NSMakeRange(0, 1)];
    out(@"  unscript %d", [edited attribute:NSSuperscriptAttributeName atIndex:0 effectiveRange:NULL] != nil);
    [edited applyFontTraits:NSBoldFontMask range:NSMakeRange(0, 1)];
    NSFont *bold = [edited attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
    out(@"  bold trait %d", ([NSFontManager.sharedFontManager traitsOfFont:bold] & NSBoldFontMask) != 0);

    NSArray *fileTypes = [NSAttributedString textFileTypes];
    NSArray *pasteboardTypes = [NSAttributedString textPasteboardTypes];
    out(@"  text type counts %lu %lu; rtf %d; unfiltered pasteboard %@", (unsigned long)fileTypes.count,
        (unsigned long)pasteboardTypes.count, [fileTypes containsObject:@"rtf"],
        [[NSAttributedString textUnfilteredPasteboardTypes] componentsJoinedByString:@","]);

    NSData *htmlData = [@"<html><body><p>sample</p></body></html>" dataUsingEncoding:NSUTF8StringEncoding];
    NSAttributedString *html = [[NSAttributedString alloc] initWithHTML:htmlData documentAttributes:NULL];
    NSMutableAttributedString *plain = [[NSMutableAttributedString alloc] initWithString:@""];
    BOOL read = [plain readFromData:[@"plain text" dataUsingEncoding:NSUTF8StringEncoding]
                            options:@{NSDocumentTypeDocumentOption : NSPlainTextDocumentType}
                 documentAttributes:NULL
                              error:NULL];
    out(@"  document reads HTML '%@', plain %d '%@'", html.string, read, plain.string);
}

static void
table_values(void)
{
    out(@"table diffable:");
    NSTableView *table = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
    NSTableViewDiffableDataSource *source = [[NSTableViewDiffableDataSource alloc]
        initWithTableView:table
             cellProvider:^NSView *(NSTableView *view, NSTableColumn *column, NSInteger row, id identifier) {
                 return [[NSView alloc] initWithFrame:NSZeroRect];
             }];
    NSDiffableDataSourceSnapshot *snapshot = [NSDiffableDataSourceSnapshot new];
    [snapshot appendSectionsWithIdentifiers:@[@"one", @"two"]];
    [snapshot appendItemsWithIdentifiers:@[@"a", @"b"] intoSectionWithIdentifier:@"one"];
    [snapshot appendItemsWithIdentifiers:@[@"c"] intoSectionWithIdentifier:@"two"];
    __block BOOL completed = NO;
    [source applySnapshot:snapshot animatingDifferences:NO completion:^{ completed = YES; }];
    out(@"  rows %ld items %@ row-c %ld section-c %@ row-two %ld snapshot %ld/%ld completed %d animation %ld",
           (long)[source numberOfRowsInTableView:table], source.snapshot.itemIdentifiers,
           (long)[source rowForItemIdentifier:@"c"], [source sectionIdentifierForRow:2], (long)[source rowForSectionIdentifier:@"two"],
           (long)source.snapshot.numberOfSections, (long)source.snapshot.numberOfItems, completed, (long)source.defaultRowAnimation);
}

static void
pasteboard_values(void)
{
    out(@"pasteboard:");
    NSPasteboard *pasteboard = [NSPasteboard pasteboardWithName:@"Finch AppKit Gaps Test"];
    [pasteboard clearContents];
    NSPasteboardItem *one = [NSPasteboardItem new];
    NSPasteboardItem *two = [NSPasteboardItem new];
    [one setString:@"one" forType:NSPasteboardTypeString];
    [two setString:@"two" forType:NSPasteboardTypeString];
    [pasteboard writeObjects:@[one, two]];
    NSArray *items = pasteboard.pasteboardItems;
    out(@"  items %lu indices %lu %lu missing %lu", (unsigned long)items.count,
           (unsigned long)[pasteboard indexOfPasteboardItem:items[0]], (unsigned long)[pasteboard indexOfPasteboardItem:items[1]],
           (unsigned long)[pasteboard indexOfPasteboardItem:one]);

    NSFileWrapper *wrapper = [[NSFileWrapper alloc] initRegularFileWithContents:[@"file body" dataUsingEncoding:NSUTF8StringEncoding]];
    wrapper.preferredFilename = @"sample.txt";
    BOOL wrote = [pasteboard writeFileWrapper:wrapper];
    NSFileWrapper *read = [pasteboard readFileWrapper];
    NSString *contents = [[NSString alloc] initWithData:read.regularFileContents encoding:NSUTF8StringEncoding];
    out(@"  file wrapper wrote %d contents %@", wrote, contents);

    [pasteboard clearContents];
    NSURL *url = [NSURL fileURLWithPath:@"/Finch-test.txt"];
    [url writeToPasteboard:pasteboard];
    [pasteboard clearContents];
    [pasteboard setString:url.absoluteString forType:NSPasteboardTypeFileURL];
    NSArray *urlTypes = pasteboard.types;
    out(@"  URL %@ file-type %d raw %@", [NSURL URLFromPasteboard:pasteboard].absoluteString,
        [urlTypes containsObject:NSPasteboardTypeFileURL], [pasteboard stringForType:NSPasteboardTypeFileURL]);

    CIColor *ci = [CIColor colorWithRed:0.25 green:0.5 blue:0.75 alpha:1];
    NSColor *color = [NSColor colorWithCIColor:ci];
    [pasteboard clearContents];
    [color writeToPasteboard:pasteboard];
    [pasteboard clearContents];
    [pasteboard writeObjects:@[color]];
    NSColor *readColor = [NSColor colorFromPasteboard:pasteboard];
    NSData *colorData = [pasteboard dataForType:NSPasteboardTypeColor];
    out(@"  CI color %.2f %.2f %.2f data %d read %d %.2f %.2f %.2f", color.redComponent, color.greenComponent, color.blueComponent,
        colorData.length > 0, readColor != nil, readColor.redComponent, readColor.greenComponent, readColor.blueComponent);
}

int
main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        printing();
        text_values();
        table_values();
        pasteboard_values();
    }
    return 0;
}
