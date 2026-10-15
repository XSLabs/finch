/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Small AppKit value types and adapters whose behavior is available locally. */
#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>

@interface NSGlyphInfo ()
- (instancetype)_initWithGlyph:(CGGlyph)glyph
                  baseString:(NSString *)string
                        font:(NSFont *)font
                  glyphName:(NSString *)glyphName
        characterIdentifier:(NSUInteger)identifier
           characterCollection:(NSCharacterCollection)collection;
@end

@implementation NSGlyphInfo {
    CGGlyph _glyphID;
    NSString *_baseString, *_glyphName;
    NSFont *_font;
    NSUInteger _characterIdentifier;
    NSCharacterCollection _characterCollection;
}

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)_initWithGlyph:(CGGlyph)glyph
                  baseString:(NSString *)string
                        font:(NSFont *)font
                  glyphName:(NSString *)glyphName
        characterIdentifier:(NSUInteger)identifier
           characterCollection:(NSCharacterCollection)collection
{
    if ((self = [super init])) {
        _glyphID = glyph;
        _baseString = [string copy];
        _font = [font retain];
        _glyphName = [glyphName copy];
        _characterIdentifier = identifier;
        _characterCollection = collection;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSString *base = [coder decodeObjectOfClass:[NSString class] forKey:@"baseString"];
    NSString *name = [coder decodeObjectOfClass:[NSString class] forKey:@"glyphName"];
    NSFont *font = [coder decodeObjectOfClass:[NSFont class] forKey:@"font"];
    return [self _initWithGlyph:(CGGlyph)[coder decodeIntForKey:@"glyphID"]
                     baseString:base
                           font:font
                     glyphName:name
           characterIdentifier:(NSUInteger)[coder decodeIntegerForKey:@"characterIdentifier"]
              characterCollection:(NSCharacterCollection)[coder decodeIntegerForKey:@"characterCollection"]];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInt:_glyphID forKey:@"glyphID"];
    [coder encodeObject:_baseString forKey:@"baseString"];
    [coder encodeObject:_font forKey:@"font"];
    [coder encodeObject:_glyphName forKey:@"glyphName"];
    [coder encodeInteger:(NSInteger)_characterIdentifier forKey:@"characterIdentifier"];
    [coder encodeInteger:_characterCollection forKey:@"characterCollection"];
}

- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

- (void)dealloc
{
    [_baseString release];
    [_glyphName release];
    [_font release];
    [super dealloc];
}

+ (NSGlyphInfo *)glyphInfoWithCGGlyph:(CGGlyph)glyph forFont:(NSFont *)font baseString:(NSString *)string
{
    if (!font || !string.length || glyph >= font.numberOfGlyphs)
        return nil;
    return [[[self alloc] _initWithGlyph:glyph
                              baseString:string
                                    font:font
                              glyphName:nil
                    characterIdentifier:glyph
                       characterCollection:NSIdentityMappingCharacterCollection] autorelease];
}

+ (NSGlyphInfo *)glyphInfoWithGlyph:(NSGlyph)glyph forFont:(NSFont *)font baseString:(NSString *)string
{
    return [self glyphInfoWithCGGlyph:(CGGlyph)glyph forFont:font baseString:string];
}

+ (NSGlyphInfo *)glyphInfoWithGlyphName:(NSString *)name forFont:(NSFont *)font baseString:(NSString *)string
{
    if (!name.length || !font || !string.length)
        return nil;
    return [[[self alloc] _initWithGlyph:0
                              baseString:string
                                    font:font
                              glyphName:name
                    characterIdentifier:0
                       characterCollection:NSIdentityMappingCharacterCollection] autorelease];
}

+ (NSGlyphInfo *)glyphInfoWithCharacterIdentifier:(NSUInteger)identifier
                                       collection:(NSCharacterCollection)collection
                                        baseString:(NSString *)string
{
    if (!string.length || collection > NSAdobeKorea1CharacterCollection)
        return nil;
    return [[[self alloc] _initWithGlyph:(CGGlyph)(collection == NSIdentityMappingCharacterCollection ? identifier : 0)
                              baseString:string
                                    font:nil
                              glyphName:nil
                    characterIdentifier:identifier
                       characterCollection:collection] autorelease];
}

- (CGGlyph)glyphID { return _glyphID; }
- (NSString *)baseString { return _baseString; }
- (NSUInteger)characterIdentifier { return _characterIdentifier; }
- (NSCharacterCollection)characterCollection { return _characterCollection; }

- (NSString *)glyphName
{
    if (_glyphName)
        return _glyphName;
    if (!_font)
        return nil;
    CTFontRef font = CTFontCreateWithName((CFStringRef)_font.fontName, _font.pointSize, NULL);
    if (!font)
        return nil;
    NSString *name = (NSString *)CTFontCopyNameForGlyph(font, _glyphID);
    CFRelease(font);
    return [name autorelease];
}

@end

@implementation NSTextAlternatives {
    NSString *_primaryString;
    NSArray *_alternativeStrings;
}

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithPrimaryString:(NSString *)primaryString alternativeStrings:(NSArray<NSString *> *)alternativeStrings
{
    if ((self = [super init])) {
        _primaryString = [primaryString copy];
        _alternativeStrings = [alternativeStrings copy];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSString *primary = [coder decodeObjectOfClass:[NSString class] forKey:@"primaryString"];
    NSArray *alternatives = [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSArray class], [NSString class], nil]
                                                   forKey:@"alternativeStrings"];
    return [self initWithPrimaryString:primary alternativeStrings:alternatives];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_primaryString forKey:@"primaryString"];
    [coder encodeObject:_alternativeStrings forKey:@"alternativeStrings"];
}

- (void)dealloc
{
    [_primaryString release];
    [_alternativeStrings release];
    [super dealloc];
}

- (NSString *)primaryString { return _primaryString; }
- (NSArray<NSString *> *)alternativeStrings { return _alternativeStrings; }

- (void)noteSelectedAlternativeString:(NSString *)alternativeString
{
    [[NSNotificationCenter defaultCenter] postNotificationName:NSTextAlternativesSelectedAlternativeStringNotification
                                                        object:self
                                                      userInfo:alternativeString
                                                               ? @{@"NSAlternativeString" : alternativeString}
                                                               : nil];
}

@end

@interface NSTextListElement ()
- (void)_finchSetParentElement:(NSTextListElement *)parent;
- (NSInteger)_finchItemNumber;
@end

@implementation NSTextListElement {
    NSTextList *_textList;
    NSAttributedString *_contents;
    NSDictionary *_markerAttributes;
    NSArray *_childElements;
    __weak NSTextListElement *_parentElement;
}

- (instancetype)initWithParentElement:(NSTextListElement *)parent
                              textList:(NSTextList *)textList
                              contents:(NSAttributedString *)contents
                      markerAttributes:(NSDictionary<NSAttributedStringKey, id> *)markerAttributes
                          childElements:(NSArray<NSTextListElement *> *)childElements
{
    if (!textList || (!contents && !markerAttributes && !childElements)) {
        [self release];
        [NSException raise:NSInvalidArgumentException format:@"A text list element needs a text list and contents, marker attributes, or children."];
        return nil;
    }
    if ((self = [super initWithAttributedString:contents])) {
        _textList = [textList retain];
        _contents = [contents copy];
        _markerAttributes = [markerAttributes copy];
        _childElements = [(childElements ?: @[]) copy];
        _parentElement = parent;
        for (NSTextListElement *child in _childElements)
            [child _finchSetParentElement:self];
    }
    return self;
}

- (instancetype)initWithAttributedString:(NSAttributedString *)attributedString
{
    NSParagraphStyle *style = attributedString.length
                                  ? [attributedString attribute:NSParagraphStyleAttributeName atIndex:0 effectiveRange:NULL]
                                  : nil;
    NSTextList *textList = style.textLists.lastObject;
    if (!textList) {
        [self release];
        return nil;
    }
    return [self initWithParentElement:nil textList:textList contents:attributedString markerAttributes:nil childElements:nil];
}

+ (instancetype)textListElementWithContents:(NSAttributedString *)contents
                           markerAttributes:(NSDictionary<NSAttributedStringKey, id> *)markerAttributes
                                   textList:(NSTextList *)textList
                               childElements:(NSArray<NSTextListElement *> *)children
{
    return [[[self alloc] initWithParentElement:nil
                                       textList:textList
                                       contents:contents
                               markerAttributes:markerAttributes
                                   childElements:children] autorelease];
}

+ (instancetype)textListElementWithChildElements:(NSArray<NSTextListElement *> *)children
                                         textList:(NSTextList *)textList
                                     nestingLevel:(NSInteger)nestingLevel
{
    if (nestingLevel < 0)
        [NSException raise:NSInvalidArgumentException format:@"nestingLevel must not be negative"];
    if (!children.count)
        return nil;
    NSTextListElement *result = [[[self alloc] initWithParentElement:nil
                                                           textList:textList
                                                           contents:nil
                                                   markerAttributes:nil
                                                       childElements:children] autorelease];
    for (NSInteger i = 0; i < nestingLevel; i++)
        result = [[[self alloc] initWithParentElement:nil
                                            textList:textList
                                            contents:nil
                                    markerAttributes:nil
                                        childElements:@[result]] autorelease];
    return result;
}

- (void)dealloc
{
    for (NSTextListElement *child in _childElements)
        if (child.parentElement == self)
            [child _finchSetParentElement:nil];
    [_textList release];
    [_contents release];
    [_markerAttributes release];
    [_childElements release];
    [super dealloc];
}

- (void)_finchSetParentElement:(NSTextListElement *)parent { _parentElement = parent; }
- (NSInteger)_finchItemNumber
{
    NSUInteger index = [_parentElement.childElements indexOfObjectIdenticalTo:self];
    return (NSInteger)_textList.startingItemNumber + (index == NSNotFound ? 0 : (NSInteger)index);
}

- (NSTextList *)textList { return _textList; }
- (NSAttributedString *)contents { return _contents; }
- (NSDictionary<NSAttributedStringKey, id> *)markerAttributes { return _markerAttributes; }
- (NSArray<NSTextListElement *> *)childElements { return _childElements; }
- (NSTextListElement *)parentElement { return _parentElement; }

- (NSAttributedString *)attributedString
{
    NSAttributedString *source = _contents ?: [[[NSAttributedString alloc] initWithString:@""] autorelease];
    NSMutableAttributedString *result = [[source mutableCopy] autorelease];
    NSMutableString *marker = [NSMutableString string];
    if (_textList.listOptions & NSTextListPrependEnclosingMarker) {
        NSMutableArray *parents = [NSMutableArray array];
        for (NSTextListElement *element = _parentElement; element; element = element.parentElement)
            [parents insertObject:element atIndex:0];
        for (NSTextListElement *element in parents)
            [marker appendString:[element.textList markerForItemNumber:[element _finchItemNumber]] ?: @""];
    }
    [marker appendString:[_textList markerForItemNumber:[self _finchItemNumber]] ?: @""];
    if (!marker.length)
        return result;
    [marker insertString:@"\t" atIndex:0];
    [marker appendString:@"\t"];
    NSDictionary *attributes = _markerAttributes ?: (_contents.length ? [_contents attributesAtIndex:0 effectiveRange:NULL] : @{});
    NSMutableAttributedString *prefixed = [[[NSMutableAttributedString alloc] initWithString:marker attributes:attributes] autorelease];
    [prefixed appendAttributedString:result];
    if (![prefixed.string hasSuffix:@"\n"] && ![prefixed.string hasSuffix:@"\r"])
        [prefixed appendAttributedString:[[[NSAttributedString alloc] initWithString:@"\n"] autorelease]];
    return prefixed;
}

@end

@interface NSCollectionViewUpdateItem ()
- (instancetype)initWithAction:(NSCollectionUpdateAction)action
         indexPathBeforeUpdate:(NSIndexPath *)before
          indexPathAfterUpdate:(NSIndexPath *)after;
@end

@implementation NSCollectionViewUpdateItem {
    NSIndexPath *_indexPathBeforeUpdate, *_indexPathAfterUpdate;
    NSCollectionUpdateAction _updateAction;
}

- (instancetype)initWithAction:(NSCollectionUpdateAction)action
         indexPathBeforeUpdate:(NSIndexPath *)before
          indexPathAfterUpdate:(NSIndexPath *)after
{
    if ((self = [super init])) {
        _updateAction = action;
        _indexPathBeforeUpdate = [before copy];
        _indexPathAfterUpdate = [after copy];
    }
    return self;
}

- (void)dealloc
{
    [_indexPathBeforeUpdate release];
    [_indexPathAfterUpdate release];
    [super dealloc];
}

- (NSIndexPath *)indexPathBeforeUpdate { return _indexPathBeforeUpdate; }
- (NSIndexPath *)indexPathAfterUpdate { return _indexPathAfterUpdate; }
- (NSCollectionUpdateAction)updateAction { return _updateAction; }

@end

@implementation NSTableViewDiffableDataSource {
    __weak NSTableView *_tableView;
    NSTableViewDiffableDataSourceCellProvider _cellProvider;
    NSTableViewDiffableDataSourceRowProvider _rowViewProvider;
    NSTableViewDiffableDataSourceSectionHeaderViewProvider _sectionHeaderViewProvider;
    NSDiffableDataSourceSnapshot *_snapshot;
    NSTableViewAnimationOptions _defaultRowAnimation;
}

- (instancetype)init
{
    [NSException raise:NSInvalidArgumentException format:@"Use initWithTableView:cellProvider:"];
    return nil;
}

+ (instancetype)new
{
    [NSException raise:NSInvalidArgumentException format:@"Use initWithTableView:cellProvider:"];
    return nil;
}

- (instancetype)initWithTableView:(NSTableView *)tableView cellProvider:(NSTableViewDiffableDataSourceCellProvider)cellProvider
{
    if (!tableView || !cellProvider) {
        [self release];
        [NSException raise:NSInvalidArgumentException format:@"A table view and cell provider are required."];
        return nil;
    }
    if ((self = [super init])) {
        _tableView = tableView;
        _cellProvider = [cellProvider copy];
        _snapshot = [NSDiffableDataSourceSnapshot new];
        _defaultRowAnimation = NSTableViewAnimationEffectFade;
        tableView.dataSource = self;
    }
    return self;
}

- (void)dealloc
{
    if (_tableView.dataSource == self)
        _tableView.dataSource = nil;
    [_cellProvider release];
    [_rowViewProvider release];
    [_sectionHeaderViewProvider release];
    [_snapshot release];
    [super dealloc];
}

- (NSDiffableDataSourceSnapshot *)snapshot { return [[_snapshot copy] autorelease]; }

- (void)applySnapshot:(NSDiffableDataSourceSnapshot *)snapshot animatingDifferences:(BOOL)animatingDifferences
{
    [self applySnapshot:snapshot animatingDifferences:animatingDifferences completion:nil];
}

- (void)applySnapshot:(NSDiffableDataSourceSnapshot *)snapshot
   animatingDifferences:(BOOL)animatingDifferences
            completion:(void (^)(void))completion
{
    if (!snapshot)
        [NSException raise:NSInvalidArgumentException format:@"A snapshot is required."];
    NSDiffableDataSourceSnapshot *copy = [snapshot copy];
    [_snapshot release];
    _snapshot = copy;
    [_tableView reloadData];
    if (completion)
        completion();
}

- (id)itemIdentifierForRow:(NSInteger)row
{
    NSArray *items = _snapshot.itemIdentifiers;
    return row >= 0 && (NSUInteger)row < items.count ? items[(NSUInteger)row] : nil;
}

- (NSInteger)rowForItemIdentifier:(id)identifier
{
    return [_snapshot indexOfItemIdentifier:identifier];
}

- (id)sectionIdentifierForRow:(NSInteger)row
{
    return nil;
}

- (NSInteger)rowForSectionIdentifier:(id)identifier
{
    return NSNotFound;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return _snapshot.numberOfItems; }

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
    id identifier = [self itemIdentifierForRow:row];
    NSView *view = identifier ? _cellProvider(tableView, column, row, identifier) : nil;
    if (!view)
        [NSException raise:NSInternalInconsistencyException format:@"NSTableViewDiffableDataSource cell provider returned nil for row %ld.", (long)row];
    return view;
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row
{
    return _rowViewProvider ? _rowViewProvider(tableView, row, [self itemIdentifierForRow:row]) : nil;
}

- (NSTableViewDiffableDataSourceRowProvider)rowViewProvider { return _rowViewProvider; }
- (void)setRowViewProvider:(NSTableViewDiffableDataSourceRowProvider)provider
{
    [_rowViewProvider release];
    _rowViewProvider = [provider copy];
}

- (NSTableViewDiffableDataSourceSectionHeaderViewProvider)sectionHeaderViewProvider { return _sectionHeaderViewProvider; }
- (void)setSectionHeaderViewProvider:(NSTableViewDiffableDataSourceSectionHeaderViewProvider)provider
{
    [_sectionHeaderViewProvider release];
    _sectionHeaderViewProvider = [provider copy];
}

- (NSTableViewAnimationOptions)defaultRowAnimation { return _defaultRowAnimation; }
- (void)setDefaultRowAnimation:(NSTableViewAnimationOptions)animation { _defaultRowAnimation = animation; }

@end

@implementation NSAttributedString (FinchAppKitDocumentFormats)

- (instancetype)initWithDocFormat:(NSData *)data documentAttributes:(NSDictionary **)attributes
{
    return [self initWithData:data
                      options:@{NSDocumentTypeDocumentOption : NSDocFormatTextDocumentType}
           documentAttributes:attributes
                        error:NULL];
}

- (instancetype)initWithHTML:(NSData *)data documentAttributes:(NSDictionary **)attributes
{
    return [self initWithHTML:data options:@{} documentAttributes:attributes];
}

- (instancetype)initWithHTML:(NSData *)data baseURL:(NSURL *)baseURL documentAttributes:(NSDictionary **)attributes
{
    NSDictionary *options = baseURL ? @{NSBaseURLDocumentOption : baseURL} : @{};
    return [self initWithHTML:data options:options documentAttributes:attributes];
}

- (instancetype)initWithHTML:(NSData *)data options:(NSDictionary *)options documentAttributes:(NSDictionary **)attributes
{
    NSMutableDictionary *readingOptions = [options mutableCopy] ?: [[NSMutableDictionary alloc] init];
    readingOptions[NSDocumentTypeDocumentOption] = NSHTMLTextDocumentType;
    NSAttributedString *result = [self initWithData:data options:readingOptions documentAttributes:attributes error:NULL];
    [readingOptions release];
    return result;
}

- (instancetype)initWithPath:(NSString *)path documentAttributes:(NSDictionary **)attributes
{
    return [self initWithURL:[NSURL fileURLWithPath:path] options:@{} documentAttributes:attributes error:NULL];
}

- (instancetype)initWithURL:(NSURL *)url documentAttributes:(NSDictionary **)attributes
{
    return [self initWithURL:url options:@{} documentAttributes:attributes error:NULL];
}

- (BOOL)prefersRTFDInRange:(NSRange)range
{
    return [self containsAttachmentsInRange:range];
}

+ (NSAttributedString *)attributedStringWithAdaptiveImageGlyph:(id)glyph attributes:(NSDictionary<NSAttributedStringKey, id> *)attributes
{
    if (!glyph)
        return [[[self alloc] initWithString:@""] autorelease];
    NSMutableDictionary *attrs = [attributes mutableCopy] ?: [[NSMutableDictionary alloc] init];
    attrs[NSAdaptiveImageGlyphAttributeName] = glyph;
    NSAttributedString *result = [[[self alloc] initWithString:@"\uFFFC" attributes:attrs] autorelease];
    [attrs release];
    return result;
}

+ (NSArray *)textUnfilteredFileTypes
{
    return @[@"txt", @"TXT", @"rtf", @"RTF", @"rtfd", @"RTFD", @"html", @"HTML", @"htm", @"HTM", @"xml", @"XML", @"webarchive",
             @"WEBARCHIVE", @"doc", @"DOC", @"dot", @"DOT", @"docx", @"DOCX", @"docm", @"DOCM", @"dotx", @"DOTX", @"dotm", @"DOTM",
             @"odt", @"ODT", @"ott", @"OTT", @"sxw", @"SXW", @"stw", @"STW", @"'TEXT'", @"'ttro'", @"'sEXT'", @"'W8BN'", @"'W8TN'"];
}

+ (NSArray *)textUnfilteredPasteboardTypes
{
    return @[NSStringPboardType, NSRTFPboardType, NSRTFDPboardType, NSHTMLPboardType];
}

+ (NSArray *)textFileTypes { return [self textUnfilteredFileTypes]; }

+ (NSArray *)textPasteboardTypes
{
    NSMutableArray *types = [NSMutableArray array];
    for (NSString *fileType in [self textFileTypes])
        [types addObject:NSCreateFilenamePboardType(fileType)];
    [types addObjectsFromArray:[self textUnfilteredPasteboardTypes]];
    return types;
}

@end

@interface NSMutableAttributedString (FinchAppKitTextEditsPrivate)
- (void)_finchAdjustScriptInRange:(NSRange)range by:(NSInteger)delta;
@end

@implementation NSMutableAttributedString (FinchAppKitTextEdits)

- (void)superscriptRange:(NSRange)range { [self _finchAdjustScriptInRange:range by:1]; }
- (void)subscriptRange:(NSRange)range { [self _finchAdjustScriptInRange:range by:-1]; }
- (void)unscriptRange:(NSRange)range
{
    if (NSMaxRange(range) > self.length)
        [NSException raise:NSRangeException format:@"script range is outside the string"];
    [self removeAttribute:NSSuperscriptAttributeName range:range];
}

- (void)_finchAdjustScriptInRange:(NSRange)range by:(NSInteger)delta
{
    if (NSMaxRange(range) > self.length)
        [NSException raise:NSRangeException format:@"script range is outside the string"];
    NSMutableArray *runs = [NSMutableArray array];
    NSUInteger index = range.location;
    while (index < NSMaxRange(range)) {
        NSRange effective;
        id value = [self attribute:NSSuperscriptAttributeName atIndex:index effectiveRange:&effective];
        NSRange part = NSIntersectionRange(range, effective);
        [runs addObject:@[[NSValue valueWithRange:part], value ?: [NSNull null]]];
        index = NSMaxRange(part);
    }
    for (NSArray *run in runs) {
        NSRange part = [run[0] rangeValue];
        NSInteger value = run[1] == [NSNull null] ? 0 : [run[1] integerValue];
        value += delta;
        if (value)
            [self addAttribute:NSSuperscriptAttributeName value:@(value) range:part];
        else
            [self removeAttribute:NSSuperscriptAttributeName range:part];
    }
}

- (void)applyFontTraits:(NSFontTraitMask)traitMask range:(NSRange)range
{
    if (NSMaxRange(range) > self.length)
        [NSException raise:NSRangeException format:@"font trait range is outside the string"];
    NSMutableArray *runs = [NSMutableArray array];
    NSUInteger index = range.location;
    while (index < NSMaxRange(range)) {
        NSRange effective;
        NSFont *font = [self attribute:NSFontAttributeName atIndex:index effectiveRange:&effective];
        NSRange part = NSIntersectionRange(range, effective);
        [runs addObject:@[[NSValue valueWithRange:part], font ?: [NSNull null]]];
        index = NSMaxRange(part);
    }
    NSFontManager *manager = [NSFontManager sharedFontManager];
    for (NSArray *run in runs) {
        NSRange part = [run[0] rangeValue];
        NSFont *font = run[1] == [NSNull null] ? [NSFont systemFontOfSize:0] : run[1];
        NSFont *converted = [manager convertFont:font toHaveTrait:traitMask];
        if (converted)
            [self addAttribute:NSFontAttributeName value:converted range:part];
    }
}

- (void)setAlignment:(NSTextAlignment)alignment range:(NSRange)range
{
    if (NSMaxRange(range) > self.length)
        [NSException raise:NSRangeException format:@"alignment range is outside the string"];
    if (!range.length)
        return;
    NSString *string = self.string;
    NSUInteger index = range.location;
    while (index < NSMaxRange(range)) {
        NSRange paragraph = [string paragraphRangeForRange:NSMakeRange(index, 1)];
        NSParagraphStyle *style = [self attribute:NSParagraphStyleAttributeName atIndex:index effectiveRange:NULL];
        NSMutableParagraphStyle *updated = [(style ?: [NSParagraphStyle defaultParagraphStyle]) mutableCopy];
        updated.alignment = alignment;
        [self addAttribute:NSParagraphStyleAttributeName value:updated range:paragraph];
        [updated release];
        index = NSMaxRange(paragraph);
    }
}

- (BOOL)readFromData:(NSData *)data
             options:(NSDictionary<NSAttributedStringDocumentReadingOptionKey, id> *)options
  documentAttributes:(NSDictionary<NSAttributedStringDocumentAttributeKey, id> **)attributes
               error:(NSError **)error
{
    NSAttributedString *read = [[[NSAttributedString alloc] initWithData:data options:options documentAttributes:attributes error:error] autorelease];
    if (!read)
        return NO;
    [self setAttributedString:read];
    return YES;
}

- (BOOL)readFromURL:(NSURL *)url
            options:(NSDictionary<NSAttributedStringDocumentReadingOptionKey, id> *)options
 documentAttributes:(NSDictionary<NSAttributedStringDocumentAttributeKey, id> **)attributes
              error:(NSError **)error
{
    NSAttributedString *read = [[[NSAttributedString alloc] initWithURL:url options:options documentAttributes:attributes error:error] autorelease];
    if (!read)
        return NO;
    [self setAttributedString:read];
    return YES;
}

@end
