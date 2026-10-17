// SPDX-License-Identifier: MIT OR Apache-2.0
#import <PDFKit/PDFKit.h>
#import <PDFKit/PDFAnnotationUtilities.h>
#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dispatch/dispatch.h>
#include <ctype.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

NSString * const PDFDocumentDidUnlockNotification = @"PDFDocumentDidUnlockNotification";
NSString * const PDFDocumentDidBeginFindNotification = @"PDFDocumentDidBeginFindNotification";
NSString * const PDFDocumentDidEndFindNotification = @"PDFDocumentDidEndFindNotification";
NSString * const PDFDocumentDidBeginPageFindNotification = @"PDFDocumentDidBeginPageFindNotification";
NSString * const PDFDocumentDidEndPageFindNotification = @"PDFDocumentDidEndPageFindNotification";
NSString * const PDFDocumentDidFindMatchNotification = @"PDFDocumentDidFindMatchNotification";
NSString * const PDFDocumentDidBeginWriteNotification = @"PDFDocumentDidBeginWriteNotification";
NSString * const PDFDocumentDidEndWriteNotification = @"PDFDocumentDidEndWriteNotification";
NSString * const PDFDocumentDidBeginPageWriteNotification = @"PDFDocumentDidBeginPageWriteNotification";
NSString * const PDFDocumentDidEndPageWriteNotification = @"PDFDocumentDidEndPageWriteNotification";
NSString * const PDFDocumentFoundSelectionKey = @"PDFDocumentFoundSelection";
NSString * const PDFDocumentPageIndexKey = @"PDFDocumentPageIndex";
PDFDocumentAttribute const PDFDocumentTitleAttribute = @"Title";
PDFDocumentAttribute const PDFDocumentAuthorAttribute = @"Author";
PDFDocumentAttribute const PDFDocumentSubjectAttribute = @"Subject";
PDFDocumentAttribute const PDFDocumentCreatorAttribute = @"Creator";
PDFDocumentAttribute const PDFDocumentProducerAttribute = @"Producer";
PDFDocumentAttribute const PDFDocumentCreationDateAttribute = @"CreationDate";
PDFDocumentAttribute const PDFDocumentModificationDateAttribute = @"ModDate";
PDFDocumentAttribute const PDFDocumentKeywordsAttribute = @"Keywords";
PDFDocumentWriteOption const PDFDocumentOwnerPasswordOption = @"PDFDocumentOwnerPasswordOption";
PDFDocumentWriteOption const PDFDocumentUserPasswordOption = @"PDFDocumentUserPasswordOption";
PDFDocumentWriteOption const PDFDocumentAccessPermissionsOption = @"PDFDocumentAccessPermissionsOption";
PDFDocumentWriteOption const PDFDocumentBurnInAnnotationsOption = @"PDFDocumentBurnInAnnotationsOption";
PDFDocumentWriteOption const PDFDocumentSaveTextFromOCROption = @"PDFDocumentSaveTextFromOCROption";
PDFDocumentWriteOption const PDFDocumentSaveImagesAsJPEGOption = @"PDFDocumentSaveImagesAsJPEGOption";
PDFDocumentWriteOption const PDFDocumentOptimizeImagesForScreenOption = @"PDFDocumentOptimizeImagesForScreenOption";

PDFAnnotationSubtype const PDFAnnotationSubtypeText = @"Text";
PDFAnnotationSubtype const PDFAnnotationSubtypeLink = @"Link";
PDFAnnotationSubtype const PDFAnnotationSubtypeFreeText = @"FreeText";
PDFAnnotationSubtype const PDFAnnotationSubtypeLine = @"Line";
PDFAnnotationSubtype const PDFAnnotationSubtypeSquare = @"Square";
PDFAnnotationSubtype const PDFAnnotationSubtypeCircle = @"Circle";
PDFAnnotationSubtype const PDFAnnotationSubtypeHighlight = @"Highlight";
PDFAnnotationSubtype const PDFAnnotationSubtypeUnderline = @"Underline";
PDFAnnotationSubtype const PDFAnnotationSubtypeStrikeOut = @"StrikeOut";
PDFAnnotationSubtype const PDFAnnotationSubtypeInk = @"Ink";
PDFAnnotationSubtype const PDFAnnotationSubtypeStamp = @"Stamp";
PDFAnnotationSubtype const PDFAnnotationSubtypePopup = @"Popup";
PDFAnnotationSubtype const PDFAnnotationSubtypeWidget = @"Widget";
PDFAnnotationKey const PDFAnnotationKeyAppearanceDictionary = @"AP";
PDFAnnotationKey const PDFAnnotationKeyAppearanceState = @"AS";
PDFAnnotationKey const PDFAnnotationKeyBorder = @"Border";
PDFAnnotationKey const PDFAnnotationKeyColor = @"C";
PDFAnnotationKey const PDFAnnotationKeyContents = @"Contents";
PDFAnnotationKey const PDFAnnotationKeyFlags = @"F";
PDFAnnotationKey const PDFAnnotationKeyDate = @"M";
PDFAnnotationKey const PDFAnnotationKeyName = @"NM";
PDFAnnotationKey const PDFAnnotationKeyPage = @"P";
PDFAnnotationKey const PDFAnnotationKeyRect = @"Rect";
PDFAnnotationKey const PDFAnnotationKeySubtype = @"Subtype";
PDFAnnotationKey const PDFAnnotationKeyAction = @"A";
PDFAnnotationKey const PDFAnnotationKeyBorderStyle = @"BS";
PDFAnnotationKey const PDFAnnotationKeyDestination = @"Dest";
PDFBorderKey const PDFBorderKeyLineWidth = @"W";
PDFBorderKey const PDFBorderKeyStyle = @"S";
PDFBorderKey const PDFBorderKeyDashPattern = @"D";
const CGFloat kPDFDestinationUnspecifiedValue = -1.0;

@interface PDFPage (FinchPrivate)
- (instancetype)_initWithDocument:(PDFDocument *)document pageRef:(CGPDFPageRef)pageRef index:(NSUInteger)index;
- (CGRect)_boundsForRange:(NSRange)range;
- (NSString *)_stringForRange:(NSRange)range;
- (BOOL)_hasUnsupportedAnnotations;
- (void)_markDirty;
@end

@interface PDFDocument (FinchPrivate)
- (void)_markDirty;
- (BOOL)_loadData:(NSData *)data;
@end

@interface PDFSelection (FinchPrivate)
- (instancetype)_initWithDocument:(PDFDocument *)document page:(PDFPage *)page range:(NSRange)range;
- (void)_addPage:(PDFPage *)page range:(NSRange)range;
@end

@interface PDFAnnotation (FinchPrivate)
- (instancetype)_initWithDictionary:(CGPDFDictionaryRef)dictionary page:(PDFPage *)page;
@end

@interface PDFOutline (FinchPrivate)
- (void)_setDocument:(PDFDocument *)document parent:(PDFOutline *)parent root:(BOOL)root;
@end

static NSData *PDFCreateDataForPages(NSArray *pages, NSDictionary *attributes, PDFOutline *outline, PDFDocument *document);

static NSString *PDFStringFromPDFString(CGPDFStringRef value)
{
    if (!value)
        return nil;
    CFStringRef string = CGPDFStringCopyTextString(value);
    return string ? [(NSString *)string autorelease] : nil;
}

static NSString *PDFCanonicalKey(NSString *key)
{
    if ([key hasPrefix:@"/"])
        return [key substringFromIndex:1];
    return key;
}

static BOOL PDFReadRect(CGPDFArrayRef array, CGRect *rect)
{
    if (!array || CGPDFArrayGetCount(array) < 4)
        return NO;
    CGPDFReal v[4];
    for (size_t i = 0; i < 4; i++)
        if (!CGPDFArrayGetNumber(array, i, &v[i]))
            return NO;
    *rect = CGRectMake(v[0], v[1], v[2] - v[0], v[3] - v[1]);
    return YES;
}

static CGPDFBox PDFBoxForDisplayBox(PDFDisplayBox box)
{
    static const CGPDFBox boxes[] = { kCGPDFMediaBox, kCGPDFCropBox, kCGPDFBleedBox, kCGPDFTrimBox, kCGPDFArtBox };
    if (box < kPDFDisplayBoxMediaBox || box > kPDFDisplayBoxArtBox)
        [NSException raise:NSRangeException format:@"Invalid PDF display box %ld", (long)box];
    return boxes[box];
}

static CGRect PDFRectForCGPDFBox(CGPDFPageRef page, PDFDisplayBox box)
{
    if (!page)
        return CGRectZero;
    return CGPDFPageGetBoxRect(page, PDFBoxForDisplayBox(box));
}

static BOOL PDFCharacterIsWord(NSString *string, NSUInteger index)
{
    if (index >= string.length)
        return NO;
    unichar c = [string characterAtIndex:index];
    return [[NSCharacterSet alphanumericCharacterSet] characterIsMember:c] || c == '_';
}

typedef struct {
    NSMutableString *text;
    NSMutableArray *rects;
    PDFPage *page;
    CGFloat x;
    CGFloat y;
    CGFloat fontSize;
    BOOL hasPosition;
    CTFontRef font;
    NSDictionary *unicodeMap;
    size_t unicodeCodeLength;
} PDFTextScan;

static void PDFTextEnsurePosition(PDFTextScan *scan, PDFPage *page)
{
    if (scan->hasPosition)
        return;
    CGRect bounds = [page boundsForBox:kPDFDisplayBoxCropBox];
    scan->x = CGRectGetMinX(bounds) + 36.0;
    scan->y = CGRectGetMaxY(bounds) - 36.0;
    scan->hasPosition = YES;
}

static void PDFTextSetFont(PDFTextScan *scan, CGFloat size)
{
    scan->fontSize = size > 0 ? size : 12.0;
    if (scan->font)
        CFRelease(scan->font);
    scan->font = CTFontCreateWithName(CFSTR("Helvetica"), scan->fontSize, NULL);
}

static BOOL PDFNextCMapHex(const char **cursor, const char *limit, char *hex, size_t capacity)
{
    const char *p = *cursor;
    while (p < limit && *p != '<') p++;
    if (p >= limit || p + 1 >= limit || p[1] == '<') return NO;
    p++;
    size_t length = 0;
    while (p < limit && isxdigit((unsigned char)*p)) {
        if (length + 1 >= capacity) return NO;
        hex[length++] = (char)toupper((unsigned char)*p++);
    }
    if (p >= limit || *p != '>' || !length || length % 2) return NO;
    hex[length] = 0;
    *cursor = p + 1;
    return YES;
}

static NSString *PDFStringForUnicodeHex(const char *hex)
{
    size_t length = strlen(hex);
    if (!length || length % 2) return nil;
    NSMutableData *bytes = [NSMutableData dataWithLength:length / 2];
    uint8_t *output = [bytes mutableBytes];
    for (size_t i = 0; i < length / 2; i++) {
        unsigned value = 0;
        if (sscanf(hex + i * 2, "%2x", &value) != 1) return nil;
        output[i] = (uint8_t)value;
    }
    CFStringRef decoded = CFStringCreateWithBytes(kCFAllocatorDefault, [bytes bytes], (CFIndex)[bytes length], kCFStringEncodingUTF16BE, false);
    return decoded ? [(NSString *)decoded autorelease] : nil;
}

static void PDFAddCMapEntry(NSMutableDictionary *map, const char *source, const char *destination, size_t *codeLength)
{
    NSString *value = PDFStringForUnicodeHex(destination);
    if (!value.length) return;
    NSString *key = [NSString stringWithUTF8String:source];
    if (key) [map setObject:value forKey:key];
    if (!*codeLength) *codeLength = strlen(source) / 2;
}

static NSDictionary *PDFUnicodeMapForFont(CGPDFScannerRef scanner, const char *fontName, size_t *codeLength)
{
    CGPDFObjectRef fontObject = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "Font", fontName);
    CGPDFDictionaryRef font = NULL;
    CGPDFStreamRef stream = NULL;
    if (!fontObject || !CGPDFObjectGetValue(fontObject, kCGPDFObjectTypeDictionary, &font) ||
        !CGPDFDictionaryGetStream(font, "ToUnicode", &stream)) return nil;
    CFDataRef data = CGPDFStreamCopyData(stream, NULL);
    if (!data) return nil;
    size_t dataLength = (size_t)CFDataGetLength(data);
    char *bytes = malloc(dataLength + 1);
    if (!bytes) { CFRelease(data); return nil; }
    memcpy(bytes, CFDataGetBytePtr(data), dataLength);
    bytes[dataLength] = 0;
    const char *end = bytes + dataLength;
    NSMutableDictionary *map = [NSMutableDictionary dictionary];

    for (const char *block = strstr(bytes, "beginbfchar"); block && block < end;) {
        const char *limit = strstr(block, "endbfchar");
        if (!limit || limit > end) break;
        const char *cursor = block + strlen("beginbfchar");
        while (cursor < limit) {
            char source[64], destination[128];
            if (!PDFNextCMapHex(&cursor, limit, source, sizeof(source)) ||
                !PDFNextCMapHex(&cursor, limit, destination, sizeof(destination))) break;
            PDFAddCMapEntry(map, source, destination, codeLength);
        }
        block = strstr(limit + strlen("endbfchar"), "beginbfchar");
    }

    for (const char *block = strstr(bytes, "beginbfrange"); block && block < end;) {
        const char *limit = strstr(block, "endbfrange");
        if (!limit || limit > end) break;
        const char *cursor = block + strlen("beginbfrange");
        while (cursor < limit) {
            char first[64], last[64], destination[128];
            if (!PDFNextCMapHex(&cursor, limit, first, sizeof(first)) ||
                !PDFNextCMapHex(&cursor, limit, last, sizeof(last))) break;
            unsigned long start = strtoul(first, NULL, 16), finish = strtoul(last, NULL, 16);
            if (finish < start || finish - start > 4096) break;
            while (cursor < limit && isspace((unsigned char)*cursor)) cursor++;
            if (cursor < limit && *cursor == '[') {
                cursor++;
                for (unsigned long code = start; code <= finish && cursor < limit; code++) {
                    if (!PDFNextCMapHex(&cursor, limit, destination, sizeof(destination))) break;
                    char key[64]; snprintf(key, sizeof(key), "%0*lX", (int)strlen(first), code);
                    PDFAddCMapEntry(map, key, destination, codeLength);
                }
                while (cursor < limit && *cursor != ']') cursor++;
                if (cursor < limit) cursor++;
            } else if (PDFNextCMapHex(&cursor, limit, destination, sizeof(destination))) {
                unsigned long base = strtoul(destination, NULL, 16);
                for (unsigned long code = start; code <= finish; code++) {
                    char key[64], value[128];
                    snprintf(key, sizeof(key), "%0*lX", (int)strlen(first), code);
                    snprintf(value, sizeof(value), "%0*lX", (int)strlen(destination), base + code - start);
                    PDFAddCMapEntry(map, key, value, codeLength);
                }
            }
        }
        block = strstr(limit + strlen("endbfrange"), "beginbfrange");
    }
    CFRelease(data);
    free(bytes);
    return map.count ? map : nil;
}

static NSString *PDFTextString(PDFTextScan *scan, CGPDFStringRef pdfString)
{
    if (scan->unicodeMap.count && scan->unicodeCodeLength) {
        const unsigned char *bytes = CGPDFStringGetBytePtr(pdfString);
        size_t length = CGPDFStringGetLength(pdfString), width = scan->unicodeCodeLength;
        if (bytes && length >= width) {
            NSMutableString *decoded = [NSMutableString string];
            for (size_t offset = 0; offset + width <= length; offset += width) {
                NSMutableString *key = [NSMutableString stringWithCapacity:width * 2];
                for (size_t i = 0; i < width; i++) [key appendFormat:@"%02X", bytes[offset + i]];
                NSString *character = [scan->unicodeMap objectForKey:key];
                if (character) [decoded appendString:character];
            }
            if (decoded.length) return decoded;
        }
    }
    return PDFStringFromPDFString(pdfString);
}

typedef struct { BOOL unsupported; } PDFAnnotationDictionaryCheck;

static void PDFCheckURLActionKey(const char *key, CGPDFObjectRef value, void *info)
{
    PDFAnnotationDictionaryCheck *check = (PDFAnnotationDictionaryCheck *)info;
    if (strcmp(key, "S") && strcmp(key, "URI") && strcmp(key, "Type")) check->unsupported = YES;
    if (!strcmp(key, "Type")) {
        const char *type = NULL;
        if (!CGPDFObjectGetValue(value, kCGPDFObjectTypeName, &type) || strcmp(type, "Action")) check->unsupported = YES;
    }
}

static BOOL PDFIsSimpleURLAction(CGPDFDictionaryRef action)
{
    const char *kind = NULL;
    CGPDFStringRef url = NULL;
    if (!action || !CGPDFDictionaryGetName(action, "S", &kind) || strcmp(kind, "URI") ||
        !CGPDFDictionaryGetString(action, "URI", &url)) return NO;
    PDFAnnotationDictionaryCheck check = { NO };
    CGPDFDictionaryApplyFunction(action, PDFCheckURLActionKey, &check);
    return !check.unsupported;
}

static BOOL PDFIsDefaultURLBorder(CGPDFArrayRef border)
{
    if (!border) return YES;
    if (CGPDFArrayGetCount(border) != 3) return NO;
    for (size_t i = 0; i < 3; i++) {
        CGPDFReal value = -1;
        if (!CGPDFArrayGetNumber(border, i, &value) || value != 0) return NO;
    }
    return YES;
}

static void PDFCheckURLAnnotationKey(const char *key, CGPDFObjectRef value, void *info)
{
    PDFAnnotationDictionaryCheck *check = (PDFAnnotationDictionaryCheck *)info;
    if (!strcmp(key, "Type")) {
        const char *type = NULL;
        if (!CGPDFObjectGetValue(value, kCGPDFObjectTypeName, &type) || strcmp(type, "Annot")) check->unsupported = YES;
    } else if (strcmp(key, "Subtype") && strcmp(key, "Rect") && strcmp(key, "Border") &&
               strcmp(key, "A") && strcmp(key, "P") && strcmp(key, "F")) {
        check->unsupported = YES;
    }
}

static void PDFTextAppendString(PDFTextScan *scan, PDFPage *page, CGPDFStringRef pdfString, BOOL newLine)
{
    NSString *string = PDFTextString(scan, pdfString);
    if (!string.length)
        return;
    PDFTextEnsurePosition(scan, page);
    if (newLine && scan->text.length && [scan->text characterAtIndex:scan->text.length - 1] != '\n') {
        [scan->text appendString:@"\n"];
        [scan->rects addObject:[NSValue valueWithRect:NSZeroRect]];
        scan->x = CGRectGetMinX([page boundsForBox:kPDFDisplayBoxCropBox]) + 36.0;
        scan->y -= scan->fontSize * 1.2;
    }
    for (NSUInteger i = 0; i < string.length;) {
        NSRange range = [string rangeOfComposedCharacterSequenceAtIndex:i];
        NSString *part = [string substringWithRange:range];
        [scan->text appendString:part];
        UniChar character = [part characterAtIndex:0];
        CGGlyph glyph = 0;
        CGSize advance = CGSizeMake(scan->fontSize * 0.5, 0);
        if (scan->font && CTFontGetGlyphsForCharacters(scan->font, &character, &glyph, 1))
            CTFontGetAdvancesForGlyphs(scan->font, kCTFontOrientationHorizontal, &glyph, &advance, 1);
        CGFloat ascent = scan->font ? CTFontGetAscent(scan->font) : scan->fontSize * 0.8;
        CGFloat descent = scan->font ? CTFontGetDescent(scan->font) : scan->fontSize * 0.2;
        CGRect bounds = CGRectMake(scan->x, scan->y - descent, MAX(advance.width, 0.1), ascent + descent);
        for (NSUInteger j = 0; j < range.length; j++)
            [scan->rects addObject:[NSValue valueWithRect:(j == 0 ? bounds : CGRectZero)]];
        scan->x += advance.width;
        i = NSMaxRange(range);
    }
}

static void PDFTextDrawString(CGPDFScannerRef scanner, void *info)
{
    PDFTextScan *scan = (PDFTextScan *)info;
    CGPDFStringRef string = NULL;
    if (CGPDFScannerPopString(scanner, &string))
        PDFTextAppendString(scan, scan->page, string, NO);
}

static void PDFTextDrawArray(CGPDFScannerRef scanner, void *info)
{
    PDFTextScan *scan = (PDFTextScan *)info;
    CGPDFArrayRef array = NULL;
    if (!CGPDFScannerPopArray(scanner, &array) || !array)
        return;
    for (size_t i = 0; i < CGPDFArrayGetCount(array); i++) {
        CGPDFStringRef string = NULL;
        CGPDFReal adjustment = 0;
        if (CGPDFArrayGetString(array, i, &string))
            PDFTextAppendString(scan, scan->page, string, NO);
        else if (CGPDFArrayGetNumber(array, i, &adjustment))
            scan->x -= adjustment * scan->fontSize / 1000.0;
    }
}

static void PDFTextMoveLine(CGPDFScannerRef scanner, void *info)
{
    PDFTextScan *scan = (PDFTextScan *)info;
    CGPDFReal ty = 0, tx = 0;
    if (CGPDFScannerPopNumber(scanner, &ty) && CGPDFScannerPopNumber(scanner, &tx)) {
        if (scan->text.length && [scan->text characterAtIndex:scan->text.length - 1] != '\n') {
            [scan->text appendString:@"\n"];
            [scan->rects addObject:[NSValue valueWithRect:NSZeroRect]];
        }
        scan->x += tx;
        scan->y += ty;
        scan->hasPosition = YES;
    }
}

static void PDFTextNextLine(CGPDFScannerRef scanner, void *info)
{
    (void)scanner;
    PDFTextScan *scan = (PDFTextScan *)info;
    if (scan->text.length && [scan->text characterAtIndex:scan->text.length - 1] != '\n') {
        [scan->text appendString:@"\n"];
        [scan->rects addObject:[NSValue valueWithRect:NSZeroRect]];
    }
    scan->x = 0;
    scan->y -= scan->fontSize * 1.2;
}

static void PDFTextSetMatrix(CGPDFScannerRef scanner, void *info)
{
    PDFTextScan *scan = (PDFTextScan *)info;
    CGPDFReal v[6];
    for (int i = 5; i >= 0; i--)
        if (!CGPDFScannerPopNumber(scanner, &v[i]))
            return;
    scan->x = v[4];
    scan->y = v[5];
    scan->hasPosition = YES;
}

static void PDFTextSetFontSize(CGPDFScannerRef scanner, void *info)
{
    PDFTextScan *scan = (PDFTextScan *)info;
    CGPDFReal size = 0;
    const char *name = NULL;
    if (CGPDFScannerPopNumber(scanner, &size) && CGPDFScannerPopName(scanner, &name)) {
        PDFTextSetFont(scan, size);
        [scan->unicodeMap release];
        scan->unicodeCodeLength = 0;
        scan->unicodeMap = [PDFUnicodeMapForFont(scanner, name, &scan->unicodeCodeLength) retain];
    }
}

static void PDFTextQuote(CGPDFScannerRef scanner, void *info)
{
    PDFTextNextLine(scanner, info);
    PDFTextDrawString(scanner, info);
}

static void PDFTextDoubleQuote(CGPDFScannerRef scanner, void *info)
{
    PDFTextScan *scan = (PDFTextScan *)info;
    CGPDFReal wordSpacing = 0, charSpacing = 0;
    CGPDFStringRef string = NULL;
    if (CGPDFScannerPopString(scanner, &string)) {
        CGPDFScannerPopNumber(scanner, &charSpacing);
        CGPDFScannerPopNumber(scanner, &wordSpacing);
        (void)charSpacing;
        (void)wordSpacing;
        PDFTextNextLine(scanner, info);
        PDFTextAppendString(scan, scan->page, string, NO);
    }
}

static NSString *PDFExtractText(PDFPage *page, CGPDFPageRef pageRef, NSMutableArray *rects)
{
    NSMutableString *text = [NSMutableString string];
    PDFTextScan scan = { text, rects, page, 0, 0, 12.0, NO, NULL, nil, 0 };
    PDFTextSetFont(&scan, 12.0);
    CGPDFOperatorTableRef table = CGPDFOperatorTableCreate();
    CGPDFOperatorTableSetCallback(table, "Tj", PDFTextDrawString);
    CGPDFOperatorTableSetCallback(table, "TJ", PDFTextDrawArray);
    CGPDFOperatorTableSetCallback(table, "Td", PDFTextMoveLine);
    CGPDFOperatorTableSetCallback(table, "TD", PDFTextMoveLine);
    CGPDFOperatorTableSetCallback(table, "Tm", PDFTextSetMatrix);
    CGPDFOperatorTableSetCallback(table, "Tf", PDFTextSetFontSize);
    CGPDFOperatorTableSetCallback(table, "T*", PDFTextNextLine);
    CGPDFOperatorTableSetCallback(table, "'", PDFTextQuote);
    CGPDFOperatorTableSetCallback(table, "\"", PDFTextDoubleQuote);
    CGPDFContentStreamRef stream = CGPDFContentStreamCreateWithPage(pageRef);
    CGPDFScannerRef scanner = stream ? CGPDFScannerCreate(stream, table, &scan) : NULL;
    if (scanner)
        CGPDFScannerScan(scanner);
    if (scanner)
        CGPDFScannerRelease(scanner);
    if (stream)
        CGPDFContentStreamRelease(stream);
    CGPDFOperatorTableRelease(table);
    if (scan.font)
        CFRelease(scan.font);
    [scan.unicodeMap release];
    while (rects.count < text.length)
        [rects addObject:[NSValue valueWithRect:NSZeroRect]];
    (void)page;
    return text;
}

@implementation PDFAction {
@public
    NSString *_factionType;
}
- (NSString *)type { return _factionType ? _factionType : @""; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
- (void)dealloc { [_factionType release]; [super dealloc]; }
@end

@implementation PDFActionURL {
@public
    NSURL *_furl;
}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
- (instancetype)init { return [self initWithURL:nil]; }
#pragma clang diagnostic pop
- (instancetype)initWithURL:(NSURL *)url
{
    if ((self = [super init])) {
        _factionType = [@"URL" copy];
        _furl = [url copy];
    }
    return self;
}
- (NSURL *)URL { return _furl; }
- (void)setURL:(NSURL *)url { if (_furl != url) { [_furl release]; _furl = [url copy]; } }
- (id)copyWithZone:(NSZone *)zone { return [[[self class] allocWithZone:zone] initWithURL:_furl]; }
- (void)dealloc { [_furl release]; [super dealloc]; }
@end

@implementation PDFActionGoTo {
@public
    PDFDestination *_fdestination;
}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
- (instancetype)init { return [self initWithDestination:nil]; }
#pragma clang diagnostic pop
- (instancetype)initWithDestination:(PDFDestination *)destination
{
    if ((self = [super init])) {
        _factionType = [@"GoTo" copy];
        _fdestination = [destination retain];
    }
    return self;
}
- (PDFDestination *)destination { return _fdestination; }
- (void)setDestination:(PDFDestination *)destination { if (_fdestination != destination) { [_fdestination release]; _fdestination = [destination retain]; } }
- (id)copyWithZone:(NSZone *)zone { return [[[self class] allocWithZone:zone] initWithDestination:_fdestination]; }
- (void)dealloc { [_fdestination release]; [super dealloc]; }
@end

@implementation PDFDestination {
@public
    PDFPage *_fpage;
    PDFPoint _fpoint;
    CGFloat _fzoom;
}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
- (instancetype)init { return [self initWithPage:nil atPoint:CGPointZero]; }
#pragma clang diagnostic pop
- (instancetype)initWithPage:(PDFPage *)page atPoint:(PDFPoint)point
{
    if ((self = [super init])) {
        _fpage = page;
        _fpoint = point;
        _fzoom = kPDFDestinationUnspecifiedValue;
    }
    return self;
}
- (PDFPage *)page { return _fpage; }
- (PDFPoint)point { return _fpoint; }
- (CGFloat)zoom { return _fzoom; }
- (void)setZoom:(CGFloat)zoom { _fzoom = zoom; }
- (NSComparisonResult)compare:(PDFDestination *)other
{
    if (!other || !_fpage || !other->_fpage)
        [NSException raise:NSInvalidArgumentException format:@"PDF destinations need pages"];
    PDFDocument *document = _fpage.document;
    if (document != other->_fpage.document)
        [NSException raise:NSInvalidArgumentException format:@"PDF destinations must belong to the same document"];
    NSUInteger a = [document indexForPage:_fpage], b = [document indexForPage:other->_fpage];
    if (a < b) return NSOrderedAscending;
    if (a > b) return NSOrderedDescending;
    if (_fpoint.y > other->_fpoint.y) return NSOrderedAscending;
    if (_fpoint.y < other->_fpoint.y) return NSOrderedDescending;
    return NSOrderedSame;
}
- (id)copyWithZone:(NSZone *)zone
{
    PDFDestination *copy = [[[self class] allocWithZone:zone] initWithPage:_fpage atPoint:_fpoint];
    copy->_fzoom = _fzoom;
    return copy;
}
@end

@implementation PDFBorder {
@public
    PDFBorderStyle _fstyle;
    CGFloat _fwidth;
    NSArray *_fdash;
}
- (instancetype)init { if ((self = [super init])) { _fstyle = kPDFBorderStyleSolid; _fwidth = 1.0; } return self; }
- (PDFBorderStyle)style { return _fstyle; }
- (void)setStyle:(PDFBorderStyle)style { _fstyle = style; }
- (CGFloat)lineWidth { return _fwidth; }
- (void)setLineWidth:(CGFloat)width { _fwidth = MAX(0, width); }
- (NSArray *)dashPattern { return _fdash; }
- (void)setDashPattern:(NSArray *)pattern { if (_fdash != pattern) { [_fdash release]; _fdash = [pattern copy]; } }
- (NSDictionary *)borderKeyValues
{
    NSMutableDictionary *values = [NSMutableDictionary dictionaryWithObjectsAndKeys:@(_fwidth), PDFBorderKeyLineWidth, @(_fstyle), PDFBorderKeyStyle, nil];
    if (_fdash) [values setObject:_fdash forKey:PDFBorderKeyDashPattern];
    return values;
}
- (void)drawInRect:(PDFRect)rect
{
    CGContextRef context = [[NSGraphicsContext currentContext] CGContext];
    if (!context) return;
    CGContextSetLineWidth(context, _fwidth);
    if (_fdash.count) {
        CGFloat pattern[16];
        size_t count = MIN(_fdash.count, 16);
        for (size_t i = 0; i < count; i++) pattern[i] = [_fdash[i] doubleValue];
        CGContextSetLineDash(context, 0, pattern, count);
    }
    CGContextStrokeRect(context, rect);
}
- (id)copyWithZone:(NSZone *)zone
{
    PDFBorder *copy = [[[self class] allocWithZone:zone] init];
    copy->_fstyle = _fstyle; copy->_fwidth = _fwidth; copy->_fdash = [_fdash copy];
    return copy;
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInteger:_fstyle forKey:@"style"];
    [coder encodeDouble:_fwidth forKey:@"lineWidth"];
    [coder encodeObject:_fdash forKey:@"dashPattern"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init])) {
        _fstyle = [coder decodeIntegerForKey:@"style"];
        _fwidth = [coder decodeDoubleForKey:@"lineWidth"];
        _fdash = [[coder decodeObjectForKey:@"dashPattern"] copy];
    }
    return self;
}
- (void)dealloc { [_fdash release]; [super dealloc]; }
@end

@implementation PDFAnnotation {
@public
    PDFPage *_fpage;
    NSString *_ftype;
    PDFRect _fbounds;
    NSMutableDictionary *_fvalues;
    PDFAction *_faction;
    PDFBorder *_fborder;
    NSColor *_fcolor;
    BOOL _fdisplay, _fprint, _fhighlighted;
    BOOL _fchanged;
    BOOL _funsupportedForURLRewrite;
}
- (instancetype)init
{
    self = [self initWithBounds:NSZeroRect forType:@"Unknown" withProperties:nil];
    [self release];
    [NSException raise:NSInvalidArgumentException format:@"Use initWithBounds:forType:withProperties:"];
    return nil;
}
- (instancetype)initWithBounds:(PDFRect)bounds forType:(PDFAnnotationSubtype)type withProperties:(NSDictionary *)properties
{
    if ((self = [super init])) {
        _fbounds = bounds; _ftype = [type copy]; _fvalues = [NSMutableDictionary new];
        if (properties) [_fvalues addEntriesFromDictionary:properties];
        [_fvalues setObject:type forKey:PDFAnnotationKeySubtype];
        [_fvalues setObject:[NSValue valueWithRect:bounds] forKey:PDFAnnotationKeyRect];
        _fdisplay = YES; _fprint = YES;
    }
    return self;
}
- (instancetype)_initWithDictionary:(CGPDFDictionaryRef)dictionary page:(PDFPage *)page
{
    const char *subtype = NULL;
    CGPDFDictionaryGetName(dictionary, "Subtype", &subtype);
    CGPDFArrayRef array = NULL;
    CGRect bounds = CGRectZero;
    if (CGPDFDictionaryGetArray(dictionary, "Rect", &array)) PDFReadRect(array, &bounds);
    NSString *type = subtype ? [NSString stringWithUTF8String:subtype] : @"Unknown";
    if ((self = [self initWithBounds:bounds forType:type withProperties:nil])) {
        _fpage = page;
        PDFAnnotationDictionaryCheck check = { NO };
        CGPDFDictionaryApplyFunction(dictionary, PDFCheckURLAnnotationKey, &check);
        _funsupportedForURLRewrite = check.unsupported;
        CGPDFStringRef contents = NULL, user = NULL;
        if (CGPDFDictionaryGetString(dictionary, "Contents", &contents)) [_fvalues setObject:PDFStringFromPDFString(contents) forKey:PDFAnnotationKeyContents];
        if (CGPDFDictionaryGetString(dictionary, "T", &user)) [_fvalues setObject:PDFStringFromPDFString(user) forKey:@"T"];
        CGPDFInteger flags = 0;
        CGPDFDictionaryGetInteger(dictionary, "F", &flags);
        if (flags != 0) _funsupportedForURLRewrite = YES;
        _fdisplay = !(flags & (1 | 2));
        _fprint = (flags & 4) != 0;
        CGPDFArrayRef linkBorder = NULL;
        if (CGPDFDictionaryGetArray(dictionary, "Border", &linkBorder) && !PDFIsDefaultURLBorder(linkBorder))
            _funsupportedForURLRewrite = YES;
        CGPDFArrayRef color = NULL;
        if (CGPDFDictionaryGetArray(dictionary, "C", &color)) {
            NSMutableArray *components = [NSMutableArray array];
            for (size_t i = 0; i < CGPDFArrayGetCount(color); i++) {
                CGPDFReal component = 0;
                if (CGPDFArrayGetNumber(color, i, &component)) [components addObject:@(component)];
            }
            [_fvalues setObject:components forKey:PDFAnnotationKeyColor];
            if (components.count == 1) _fcolor = [[NSColor colorWithCalibratedWhite:[components[0] doubleValue] alpha:1] retain];
            else if (components.count >= 3) _fcolor = [[NSColor colorWithCalibratedRed:[components[0] doubleValue] green:[components[1] doubleValue] blue:[components[2] doubleValue] alpha:1] retain];
        }
        CGPDFDictionaryRef style = NULL;
        if (CGPDFDictionaryGetDictionary(dictionary, "BS", &style)) {
            PDFBorder *border = [[PDFBorder alloc] init];
            CGPDFReal width = 1;
            CGPDFDictionaryGetNumber(style, "W", &width);
            border.lineWidth = width;
            const char *borderStyle = NULL;
            CGPDFDictionaryGetName(style, "S", &borderStyle);
            if (borderStyle && !strcmp(borderStyle, "D")) border.style = kPDFBorderStyleDashed;
            _fborder = border;
        }
        CGPDFDictionaryRef action = NULL;
        const char *actionType = NULL;
        if (CGPDFDictionaryGetDictionary(dictionary, "A", &action)) {
            if (!PDFIsSimpleURLAction(action)) _funsupportedForURLRewrite = YES;
        }
        if (action && CGPDFDictionaryGetName(action, "S", &actionType)) {
            if (!strcmp(actionType, "URI")) {
                CGPDFStringRef uri = NULL;
                if (CGPDFDictionaryGetString(action, "URI", &uri)) {
                    NSString *urlString = PDFStringFromPDFString(uri);
                    NSURL *url = urlString ? [NSURL URLWithString:urlString] : nil;
                    if (url) _faction = [[PDFActionURL alloc] initWithURL:url];
                }
            }
        }
        CGPDFDictionaryRef appearance = NULL;
        if (CGPDFDictionaryGetDictionary(dictionary, "AP", &appearance)) [_fvalues setObject:@YES forKey:PDFAnnotationKeyAppearanceDictionary];
    }
    return self;
}
- (PDFPage *)page { return _fpage; }
- (void)setPage:(PDFPage *)page { _fpage = page; }
- (NSString *)type { return _ftype; }
- (void)setType:(NSString *)type { if (!_ftype && type) _ftype = [type copy]; }
- (PDFRect)bounds { return _fbounds; }
- (void)setBounds:(PDFRect)bounds { _fbounds = bounds; [_fvalues setObject:[NSValue valueWithRect:bounds] forKey:PDFAnnotationKeyRect]; _fchanged = YES; [_fpage _markDirty]; }
- (BOOL)shouldDisplay { return _fdisplay; }
- (void)setShouldDisplay:(BOOL)value { if (_fdisplay != value) _funsupportedForURLRewrite = YES; _fdisplay = value; _fchanged = YES; [_fpage _markDirty]; }
- (BOOL)shouldPrint { return _fprint; }
- (void)setShouldPrint:(BOOL)value { if (_fprint != value) _funsupportedForURLRewrite = YES; _fprint = value; _fchanged = YES; [_fpage _markDirty]; }
- (NSDate *)modificationDate { return [_fvalues objectForKey:PDFAnnotationKeyDate]; }
- (void)setModificationDate:(NSDate *)date { if (date) [_fvalues setObject:date forKey:PDFAnnotationKeyDate]; else [_fvalues removeObjectForKey:PDFAnnotationKeyDate]; _funsupportedForURLRewrite = YES; _fchanged = YES; [_fpage _markDirty]; }
- (NSString *)userName { return [_fvalues objectForKey:@"T"]; }
- (void)setUserName:(NSString *)name { if (name) [_fvalues setObject:name forKey:@"T"]; else [_fvalues removeObjectForKey:@"T"]; _funsupportedForURLRewrite = YES; _fchanged = YES; [_fpage _markDirty]; }
- (PDFAnnotation *)popup { return [_fvalues objectForKey:@"Popup"]; }
- (void)setPopup:(PDFAnnotation *)popup { if (popup) [_fvalues setObject:popup forKey:@"Popup"]; else [_fvalues removeObjectForKey:@"Popup"]; _funsupportedForURLRewrite = YES; _fchanged = YES; [_fpage _markDirty]; }
- (PDFBorder *)border { return _fborder; }
- (void)setBorder:(PDFBorder *)border { if (_fborder != border) { [_fborder release]; _fborder = [border retain]; _funsupportedForURLRewrite = YES; } _fchanged = YES; [_fpage _markDirty]; }
- (NSColor *)color
{
    if (!_fcolor) return [NSColor blackColor];
    return _fcolor;
}
- (void)setColor:(NSColor *)color
{
    if (_fcolor != color) { [_fcolor release]; _fcolor = [color copy]; _funsupportedForURLRewrite = YES; }
    [_fvalues removeObjectForKey:PDFAnnotationKeyColor]; _fchanged = YES; [_fpage _markDirty];
}
- (NSString *)contents { return [_fvalues objectForKey:PDFAnnotationKeyContents]; }
- (void)setContents:(NSString *)contents { if (contents) [_fvalues setObject:contents forKey:PDFAnnotationKeyContents]; else [_fvalues removeObjectForKey:PDFAnnotationKeyContents]; _funsupportedForURLRewrite = YES; _fchanged = YES; [_fpage _markDirty]; }
- (PDFAction *)action { return _faction; }
- (void)setAction:(PDFAction *)action { if (_faction != action) { [_faction release]; _faction = [action retain]; } if (![action isKindOfClass:[PDFActionURL class]] || ![(PDFActionURL *)action URL]) _funsupportedForURLRewrite = YES; _fchanged = YES; [_fpage _markDirty]; }
- (BOOL)hasAppearanceStream { return [_fvalues objectForKey:PDFAnnotationKeyAppearanceDictionary] != nil; }
- (BOOL)isHighlighted { return _fhighlighted; }
- (void)setHighlighted:(BOOL)value { _fhighlighted = value; }
- (BOOL)setValue:(id)value forAnnotationKey:(PDFAnnotationKey)key
{
    if (![key isKindOfClass:[NSString class]] || !value) return NO;
    NSString *canonical = PDFCanonicalKey(key);
    if ([canonical isEqualToString:PDFAnnotationKeySubtype] && _ftype) return NO;
    if ([canonical isEqualToString:PDFAnnotationKeyRect]) {
        if (![value respondsToSelector:@selector(rectValue)]) return NO;
        self.bounds = [value rectValue];
        return YES;
    }
    _funsupportedForURLRewrite = YES;
    [_fvalues setObject:value forKey:canonical];
    if ([canonical isEqualToString:PDFAnnotationKeyContents]) { /* property reads through the same dictionary */ }
    _fchanged = YES; [_fpage _markDirty];
    return YES;
}
- (BOOL)setBoolean:(BOOL)value forAnnotationKey:(PDFAnnotationKey)key { return [self setValue:@(value) forAnnotationKey:key]; }
- (BOOL)setRect:(PDFRect)value forAnnotationKey:(PDFAnnotationKey)key { return [self setValue:[NSValue valueWithRect:value] forAnnotationKey:key]; }
- (NSDictionary *)annotationKeyValues { return [[_fvalues copy] autorelease]; }
- (id)valueForAnnotationKey:(PDFAnnotationKey)key { return [[[_fvalues objectForKey:PDFCanonicalKey(key)] copy] autorelease]; }
- (void)removeValueForAnnotationKey:(PDFAnnotationKey)key { [_fvalues removeObjectForKey:PDFCanonicalKey(key)]; _funsupportedForURLRewrite = YES; _fchanged = YES; [_fpage _markDirty]; }
- (void)drawWithBox:(PDFDisplayBox)box inContext:(CGContextRef)context
{
    if (!_fdisplay || !context || CGRectIsEmpty(_fbounds)) return;
    CGContextSaveGState(context);
    NSColor *color = [self color];
    if ([color respondsToSelector:@selector(CGColor)]) CGContextSetStrokeColorWithColor(context, color.CGColor);
    if ([_ftype isEqualToString:@"Highlight"]) {
        CGContextSetRGBFillColor(context, 1.0, 0.85, 0.15, 0.35);
        CGContextFillRect(context, _fbounds);
    } else if ([_ftype isEqualToString:@"Square"] || [_ftype isEqualToString:@"Circle"]) {
        if (_fborder) CGContextSetLineWidth(context, _fborder.lineWidth);
        if ([_ftype isEqualToString:@"Circle"]) CGContextStrokeEllipseInRect(context, _fbounds);
        else CGContextStrokeRect(context, _fbounds);
    }
    CGContextRestoreGState(context);
    (void)box;
}
- (id)copyWithZone:(NSZone *)zone
{
    PDFAnnotation *copy = [[[self class] allocWithZone:zone] initWithBounds:_fbounds forType:_ftype withProperties:_fvalues];
    copy->_fdisplay = _fdisplay; copy->_fprint = _fprint; copy->_fcolor = [_fcolor copy]; copy->_fborder = [_fborder copy]; copy->_faction = [_faction copy];
    return copy;
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeRect:_fbounds forKey:@"bounds"];
    [coder encodeObject:_ftype forKey:@"type"];
    [coder encodeObject:_fvalues forKey:@"values"];
    [coder encodeObject:_fcolor forKey:@"color"];
    [coder encodeObject:_fborder forKey:@"border"];
    [coder encodeObject:_faction forKey:@"action"];
    [coder encodeBool:_fdisplay forKey:@"display"];
    [coder encodeBool:_fprint forKey:@"print"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    PDFRect bounds = [coder decodeRectForKey:@"bounds"];
    NSString *type = [coder decodeObjectForKey:@"type"];
    NSDictionary *values = [coder decodeObjectForKey:@"values"];
    if ((self = [self initWithBounds:bounds forType:type ?: @"Unknown" withProperties:values])) {
        _fcolor = [[coder decodeObjectForKey:@"color"] copy];
        _fborder = [[coder decodeObjectForKey:@"border"] retain];
        _faction = [[coder decodeObjectForKey:@"action"] retain];
        _fdisplay = [coder decodeBoolForKey:@"display"];
        _fprint = [coder decodeBoolForKey:@"print"];
    }
    return self;
}
- (void)dealloc { [_ftype release]; [_fvalues release]; [_faction release]; [_fborder release]; [_fcolor release]; [super dealloc]; }
@end

@implementation PDFOutline {
@public
    PDFDocument *_fdocument;
    PDFOutline *_fparent;
    NSMutableArray *_fchildren;
    NSString *_flabel;
    PDFDestination *_fdestination;
    PDFAction *_faction;
    BOOL _fopen;
    BOOL _froot;
}
- (instancetype)init
{
    if ((self = [super init])) { _fchildren = [NSMutableArray new]; _fopen = YES; }
    return self;
}
- (PDFDocument *)document { return _fdocument; }
- (PDFOutline *)parent { return _fparent; }
- (NSUInteger)numberOfChildren { return _fchildren.count; }
- (NSUInteger)index { return _fparent ? [_fparent->_fchildren indexOfObjectIdenticalTo:self] : 0; }
- (PDFOutline *)childAtIndex:(NSUInteger)index
{
    if (index >= _fchildren.count) [NSException raise:NSRangeException format:@"PDF outline child index out of range"];
    return [_fchildren objectAtIndex:index];
}
- (void)insertChild:(PDFOutline *)child atIndex:(NSUInteger)index
{
    if (!child || index > _fchildren.count) [NSException raise:NSRangeException format:@"PDF outline child index out of range"];
    [child retain]; [child removeFromParent];
    child->_fparent = self; child->_fdocument = _fdocument;
    [_fchildren insertObject:child atIndex:index]; [child release];
    [_fdocument _markDirty];
}
- (void)removeFromParent
{
    if (!_fparent) return;
    PDFOutline *parent = _fparent;
    [self retain]; [parent->_fchildren removeObjectIdenticalTo:self]; _fparent = nil;
    [_fdocument _markDirty]; [self release];
}
- (NSString *)label { return _flabel; }
- (void)setLabel:(NSString *)label { if (_flabel != label) { [_flabel release]; _flabel = [label copy]; } [_fdocument _markDirty]; }
- (BOOL)isOpen { return _froot ? YES : (_fchildren.count ? _fopen : NO); }
- (void)setIsOpen:(BOOL)value { if (!_froot && _fchildren.count) _fopen = value; }
- (PDFDestination *)destination { return _fdestination; }
- (void)setDestination:(PDFDestination *)destination { if (_fdestination != destination) { [_fdestination release]; _fdestination = [destination retain]; } if (destination) { [_faction release]; _faction = nil; } [_fdocument _markDirty]; }
- (PDFAction *)action { return _faction ? _faction : (_fdestination ? [[[PDFActionGoTo alloc] initWithDestination:_fdestination] autorelease] : nil); }
- (void)setAction:(PDFAction *)action { if (_faction != action) { [_faction release]; _faction = [action retain]; } if (action) { [_fdestination release]; _fdestination = nil; } [_fdocument _markDirty]; }
- (void)_setDocument:(PDFDocument *)document parent:(PDFOutline *)parent root:(BOOL)root
{
    _fdocument = document; _fparent = parent; _froot = root;
    for (PDFOutline *child in _fchildren) [child _setDocument:document parent:self root:NO];
}
- (void)dealloc { [_fchildren release]; [_flabel release]; [_fdestination release]; [_faction release]; [super dealloc]; }
@end

@implementation PDFPage {
@public
    PDFDocument *_fdocument;
    CGPDFPageRef _fpageRef;
    NSUInteger _findex;
    NSInteger _frotation;
    CGRect _fboxes[5];
    BOOL _fboxSet[5];
    BOOL _fdisplaysAnnotations;
    NSMutableArray *_fannotations;
    NSMutableString *_ftext;
    NSMutableArray *_fcharacterRects;
    BOOL _ftextLoaded;
    NSImage *_fimage;
}
- (instancetype)initWithImage:(NSImage *)image options:(NSDictionary *)options
{
    if ((self = [super init])) {
        if (!image) { [self release]; return nil; }
        _fannotations = [NSMutableArray new]; _fcharacterRects = [NSMutableArray new];
        _fdisplaysAnnotations = YES;
        _fimage = [image copy];
        NSSize size = image.size;
        _fboxes[0] = CGRectMake(0, 0, MAX(1, size.width), MAX(1, size.height));
        (void)options;
    }
    return self;
}
- (instancetype)initWithImage:(NSImage *)image { return [self initWithImage:image options:@{}]; }
- (instancetype)init
{
    if ((self = [super init])) {
        _fannotations = [NSMutableArray new]; _fcharacterRects = [NSMutableArray new];
        _fboxes[0] = CGRectMake(0, 0, 612, 792); _fdisplaysAnnotations = YES;
    }
    return self;
}
- (instancetype)_initWithDocument:(PDFDocument *)document pageRef:(CGPDFPageRef)pageRef index:(NSUInteger)index
{
    if ((self = [self init])) {
        _fdocument = document; _fpageRef = pageRef ? CGPDFPageRetain(pageRef) : NULL; _findex = index;
        if (_fpageRef) {
            _frotation = CGPDFPageGetRotationAngle(_fpageRef);
            CGPDFDictionaryRef dictionary = CGPDFPageGetDictionary(_fpageRef);
            CGPDFArrayRef array = NULL;
            if (CGPDFDictionaryGetArray(dictionary, "Annots", &array)) {
                for (size_t i = 0; i < CGPDFArrayGetCount(array); i++) {
                    CGPDFDictionaryRef annotationDictionary = NULL;
                    if (CGPDFArrayGetDictionary(array, i, &annotationDictionary)) {
                        PDFAnnotation *annotation = [[PDFAnnotation alloc] _initWithDictionary:annotationDictionary page:self];
                        if (annotation) [_fannotations addObject:annotation];
                        [annotation release];
                    }
                }
            }
        }
    }
    return self;
}
- (PDFDocument *)document { return _fdocument; }
- (CGPDFPageRef)pageRef { return _fpageRef; }
- (NSString *)label { return [NSString stringWithFormat:@"%lu", (unsigned long)(_findex + 1)]; }
- (PDFRect)boundsForBox:(PDFDisplayBox)box
{
    if (box < kPDFDisplayBoxMediaBox || box > kPDFDisplayBoxArtBox) [NSException raise:NSRangeException format:@"Invalid PDF display box %ld", (long)box];
    if (_fboxSet[box]) return _fboxes[box];
    if (_fpageRef) return PDFRectForCGPDFBox(_fpageRef, box);
    if (box == kPDFDisplayBoxMediaBox) return _fboxes[box];
    return _fboxes[0];
}
- (void)setBounds:(PDFRect)bounds forBox:(PDFDisplayBox)box
{
    if (box < kPDFDisplayBoxMediaBox || box > kPDFDisplayBoxArtBox) [NSException raise:NSRangeException format:@"Invalid PDF display box %ld", (long)box];
    if (box == kPDFDisplayBoxMediaBox && CGRectIsEmpty(bounds)) [NSException raise:NSInvalidArgumentException format:@"The media box cannot be empty"];
    _fboxes[box] = bounds; _fboxSet[box] = YES; [self _markDirty];
}
- (NSInteger)rotation { return _frotation; }
- (void)setRotation:(NSInteger)rotation
{
    NSInteger normalized = rotation % 360; if (normalized < 0) normalized += 360;
    normalized = ((normalized + 45) / 90 * 90) % 360;
    if (_frotation != normalized) { _frotation = normalized; [self _markDirty]; }
}
- (NSArray *)annotations { return [[_fannotations copy] autorelease]; }
- (BOOL)displaysAnnotations { return _fdisplaysAnnotations; }
- (void)setDisplaysAnnotations:(BOOL)value { _fdisplaysAnnotations = value; }
- (void)addAnnotation:(PDFAnnotation *)annotation
{
    if (!annotation) return;
    if (annotation.page && annotation.page != self) [annotation.page removeAnnotation:annotation];
    if (![_fannotations containsObject:annotation]) { [_fannotations addObject:annotation]; annotation.page = self; [self _markDirty]; }
}
- (void)removeAnnotation:(PDFAnnotation *)annotation
{
    if ([_fannotations containsObject:annotation]) { [_fannotations removeObject:annotation]; annotation.page = nil; [self _markDirty]; }
}
- (PDFAnnotation *)annotationAtPoint:(PDFPoint)point
{
    for (PDFAnnotation *annotation in [_fannotations reverseObjectEnumerator])
        if (annotation.shouldDisplay && CGRectContainsPoint(annotation.bounds, point)) return annotation;
    return nil;
}
- (CGAffineTransform)transformForBox:(PDFDisplayBox)box
{
    CGRect rect = [self boundsForBox:box];
    return _fpageRef ? CGPDFPageGetDrawingTransform(_fpageRef, PDFBoxForDisplayBox(box), rect, (int)_frotation, true) : CGAffineTransformIdentity;
}
- (void)transformContext:(CGContextRef)context forBox:(PDFDisplayBox)box
{
    if (_fpageRef && context) CGContextConcatCTM(context, [self transformForBox:box]);
}
- (void)drawWithBox:(PDFDisplayBox)box
{
    CGContextRef context = [[NSGraphicsContext currentContext] CGContext];
    if (context) [self drawWithBox:box toContext:context];
}
- (void)transformContextForBox:(PDFDisplayBox)box
{
    CGContextRef context = [[NSGraphicsContext currentContext] CGContext];
    if (context) [self transformContext:context forBox:box];
}
- (void)drawWithBox:(PDFDisplayBox)box toContext:(CGContextRef)context
{
    if (!context) return;
    CGRect rect = [self boundsForBox:box];
    CGContextSaveGState(context);
    CGContextClipToRect(context, rect);
    if (_fimage && !_fpageRef) {
        CGImageRef image = [_fimage CGImageForProposedRect:NULL context:nil hints:nil];
        if (image) CGContextDrawImage(context, rect, image);
    } else if (_fpageRef) {
        CGContextConcatCTM(context, [self transformForBox:box]);
        CGContextDrawPDFPage(context, _fpageRef);
    }
    CGContextRestoreGState(context);
    if (_fdisplaysAnnotations)
        for (PDFAnnotation *annotation in _fannotations) [annotation drawWithBox:box inContext:context];
}
- (NSImage *)thumbnailOfSize:(PDFSize)size forBox:(PDFDisplayBox)box
{
    if (size.width <= 0 || size.height <= 0) return nil;
    CGRect bounds = [self boundsForBox:box];
    CGFloat scale = MIN(size.width / MAX(bounds.size.width, 1), size.height / MAX(bounds.size.height, 1));
    size_t width = MAX(1, (size_t)ceil(bounds.size.width * scale));
    size_t height = MAX(1, (size_t)ceil(bounds.size.height * scale));
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width * 4, colorSpace, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(colorSpace);
    if (!context) return nil;
    CGContextSetRGBFillColor(context, 1, 1, 1, 1); CGContextFillRect(context, CGRectMake(0, 0, width, height));
    CGContextScaleCTM(context, scale, scale);
    CGContextTranslateCTM(context, -bounds.origin.x, -bounds.origin.y);
    [self drawWithBox:box toContext:context];
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    NSImage *result = image ? [[[NSImage alloc] initWithCGImage:image size:NSMakeSize(width, height)] autorelease] : nil;
    if (image) CGImageRelease(image);
    return result;
}
- (NSString *)string
{
    if (!_ftextLoaded) {
        [_ftext release]; _ftext = [PDFExtractText(self, _fpageRef, _fcharacterRects) mutableCopy];
        _ftextLoaded = YES;
    }
    return _ftext;
}
- (NSAttributedString *)attributedString
{
    NSString *string = self.string;
    if (!string) return nil;
    CTFontRef font = CTFontCreateWithName(CFSTR("Helvetica"), 12, NULL);
    NSDictionary *attributes = font ? [NSDictionary dictionaryWithObject:(id)font forKey:(id)kCTFontAttributeName] : [NSDictionary dictionary];
    NSAttributedString *result = [[[NSAttributedString alloc] initWithString:string attributes:attributes] autorelease];
    if (font) CFRelease(font);
    return result;
}
- (NSUInteger)numberOfCharacters { return self.string.length; }
- (PDFRect)characterBoundsAtIndex:(NSInteger)index
{
    NSString *string = self.string;
    if (index < 0 || (NSUInteger)index >= string.length) [NSException raise:NSRangeException format:@"PDF character index out of range"];
    return [_fcharacterRects[(NSUInteger)index] rectValue];
}
- (NSInteger)characterIndexAtPoint:(PDFPoint)point
{
    [self string];
    for (NSUInteger i = 0; i < _fcharacterRects.count; i++)
        if (CGRectContainsPoint([_fcharacterRects[i] rectValue], point)) return (NSInteger)i;
    return NSNotFound;
}
- (PDFSelection *)selectionForRange:(NSRange)range
{
    NSUInteger length = self.string.length;
    if (range.location >= length || !range.length) return nil;
    range.length = MIN(range.length, length - range.location);
    return [[[PDFSelection alloc] _initWithDocument:_fdocument page:self range:range] autorelease];
}
- (PDFSelection *)selectionForWordAtPoint:(PDFPoint)point
{
    NSInteger index = [self characterIndexAtPoint:point];
    if (index == NSNotFound) return nil;
    NSString *string = self.string; NSUInteger start = (NSUInteger)index, end = start + 1;
    while (start && PDFCharacterIsWord(string, start - 1)) start--;
    while (end < string.length && PDFCharacterIsWord(string, end)) end++;
    return [self selectionForRange:NSMakeRange(start, end - start)];
}
- (PDFSelection *)selectionForLineAtPoint:(PDFPoint)point
{
    NSInteger index = [self characterIndexAtPoint:point];
    if (index == NSNotFound) return nil;
    NSString *string = self.string; NSUInteger start = (NSUInteger)index, end = start;
    while (start && [string characterAtIndex:start - 1] != '\n') start--;
    while (end < string.length && [string characterAtIndex:end] != '\n') end++;
    return [self selectionForRange:NSMakeRange(start, end - start)];
}
- (PDFSelection *)selectionFromPoint:(PDFPoint)startPoint toPoint:(PDFPoint)endPoint
{
    NSInteger a = [self characterIndexAtPoint:startPoint], b = [self characterIndexAtPoint:endPoint];
    if (a == NSNotFound || b == NSNotFound) return nil;
    NSUInteger start = MIN((NSUInteger)a, (NSUInteger)b), end = MAX((NSUInteger)a, (NSUInteger)b) + 1;
    return [self selectionForRange:NSMakeRange(start, end - start)];
}
- (PDFSelection *)selectionForRect:(PDFRect)rect
{
    [self string]; NSUInteger start = NSNotFound, end = 0;
    for (NSUInteger i = 0; i < _fcharacterRects.count; i++) {
        if (CGRectIntersectsRect([_fcharacterRects[i] rectValue], rect)) { if (start == NSNotFound) start = i; end = i + 1; }
    }
    return start == NSNotFound ? nil : [self selectionForRange:NSMakeRange(start, end - start)];
}
- (CGRect)_boundsForRange:(NSRange)range
{
    [self string]; CGRect result = CGRectNull;
    NSUInteger end = MIN(NSMaxRange(range), _fcharacterRects.count);
    for (NSUInteger i = range.location; i < end; i++) {
        CGRect rect = [_fcharacterRects[i] rectValue];
        if (CGRectIsEmpty(rect)) continue;
        result = CGRectIsNull(result) ? rect : CGRectUnion(result, rect);
    }
    return CGRectIsNull(result) ? CGRectZero : result;
}
- (NSString *)_stringForRange:(NSRange)range
{
    NSString *string = self.string;
    if (range.location >= string.length) return @"";
    return [string substringWithRange:NSMakeRange(range.location, MIN(range.length, string.length - range.location))];
}
- (NSData *)dataRepresentation
{
    NSData *data = PDFCreateDataForPages([NSArray arrayWithObject:self], nil, nil, _fdocument);
    return data;
}
- (BOOL)_hasUnsupportedAnnotations
{
    for (PDFAnnotation *annotation in _fannotations) {
        if (annotation->_funsupportedForURLRewrite || ![annotation.type isEqualToString:PDFAnnotationSubtypeLink] ||
            ![annotation.action isKindOfClass:[PDFActionURL class]] || ![(PDFActionURL *)annotation.action URL] ||
            annotation->_fborder || annotation->_fcolor) return YES;
        for (NSString *key in annotation->_fvalues) {
            if ([key isEqualToString:PDFAnnotationKeySubtype] || [key isEqualToString:PDFAnnotationKeyRect]) continue;
            if (![key isEqualToString:PDFAnnotationKeyBorder] || ![annotation->_fvalues[key] isKindOfClass:[NSArray class]]) return YES;
            NSArray *border = annotation->_fvalues[key];
            if (border.count != 3 || [border[0] doubleValue] != 0 || [border[1] doubleValue] != 0 || [border[2] doubleValue] != 0) return YES;
        }
    }
    return NO;
}
- (void)_markDirty { [_fdocument _markDirty]; }
- (id)copyWithZone:(NSZone *)zone
{
    PDFPage *copy = [[[self class] allocWithZone:zone] init];
    copy->_frotation = _frotation; memcpy(copy->_fboxes, _fboxes, sizeof(_fboxes)); memcpy(copy->_fboxSet, _fboxSet, sizeof(_fboxSet));
    copy->_fimage = [_fimage copy];
    if (_fpageRef) { copy->_fpageRef = CGPDFPageRetain(_fpageRef); copy->_findex = _findex; }
    for (PDFAnnotation *annotation in _fannotations) [copy addAnnotation:[[annotation copy] autorelease]];
    return copy;
}
- (void)dealloc
{
    if (_fpageRef) CGPDFPageRelease(_fpageRef);
    [_fannotations release]; [_ftext release]; [_fcharacterRects release]; [_fimage release];
    [super dealloc];
}
@end

@interface PDFSelectionRange : NSObject {
@public PDFPage *page; NSRange range;
}
@end
@implementation PDFSelectionRange
- (void)dealloc { [page release]; [super dealloc]; }
@end

@implementation PDFSelection {
@public
    PDFDocument *_fdocument;
    NSMutableArray *_franges;
    NSColor *_fcolor;
}
- (instancetype)init
{
    PDFDocument *document = [[PDFDocument alloc] init];
    PDFSelection *selection = [self initWithDocument:document];
    [document release];
    return selection;
}
- (instancetype)initWithDocument:(PDFDocument *)document
{
    if ((self = [super init])) { _fdocument = [document retain]; _franges = [NSMutableArray new]; }
    return self;
}
- (instancetype)_initWithDocument:(PDFDocument *)document page:(PDFPage *)page range:(NSRange)range
{
    if ((self = [self initWithDocument:document])) [self _addPage:page range:range];
    return self;
}
- (void)_addPage:(PDFPage *)page range:(NSRange)range
{
    if (!page || !range.length) return;
    PDFSelectionRange *entry = [PDFSelectionRange new]; entry->page = [page retain]; entry->range = range; [_franges addObject:entry]; [entry release];
}
- (NSArray *)pages
{
    NSMutableArray *pages = [NSMutableArray array];
    for (PDFSelectionRange *entry in _franges) if (![pages containsObject:entry->page]) [pages addObject:entry->page];
    [pages sortUsingComparator:^NSComparisonResult(PDFPage *a, PDFPage *b) { NSUInteger x = [_fdocument indexForPage:a], y = [_fdocument indexForPage:b]; return x < y ? NSOrderedAscending : (x > y ? NSOrderedDescending : NSOrderedSame); }];
    return pages;
}
- (NSColor *)color { return _fcolor; }
- (void)setColor:(NSColor *)color { if (_fcolor != color) { [_fcolor release]; _fcolor = [color copy]; } }
- (NSString *)string
{
    NSMutableArray *parts = [NSMutableArray array];
    PDFPage *lastPage = nil;
    for (PDFSelectionRange *entry in _franges) {
        if (lastPage && lastPage != entry->page) [parts addObject:@"\n"];
        [parts addObject:[entry->page _stringForRange:entry->range]]; lastPage = entry->page;
    }
    return [parts componentsJoinedByString:@""];
}
- (NSAttributedString *)attributedString { return [[[NSAttributedString alloc] initWithString:self.string ?: @""] autorelease]; }
- (PDFRect)boundsForPage:(PDFPage *)page
{
    CGRect bounds = CGRectNull;
    for (PDFSelectionRange *entry in _franges) if (entry->page == page) { CGRect part = [page _boundsForRange:entry->range]; if (!CGRectIsEmpty(part)) bounds = CGRectIsNull(bounds) ? part : CGRectUnion(bounds, part); }
    return CGRectIsNull(bounds) ? CGRectZero : bounds;
}
- (NSUInteger)numberOfTextRangesOnPage:(PDFPage *)page { NSUInteger n = 0; for (PDFSelectionRange *entry in _franges) if (entry->page == page) n++; return n; }
- (NSRange)rangeAtIndex:(NSUInteger)index onPage:(PDFPage *)page
{
    for (PDFSelectionRange *entry in _franges) if (entry->page == page) { if (!index--) return entry->range; }
    [NSException raise:NSRangeException format:@"PDF selection range index out of range"];
    return NSMakeRange(NSNotFound, 0);
}
- (NSArray *)selectionsByLine
{
    NSMutableArray *result = [NSMutableArray array];
    for (PDFSelectionRange *entry in _franges) {
        NSString *text = entry->page.string; NSUInteger end = NSMaxRange(entry->range), start = entry->range.location;
        while (start < end) {
            NSUInteger lineEnd = start;
            while (lineEnd < end && [text characterAtIndex:lineEnd] != '\n') lineEnd++;
            PDFSelection *line = [[[PDFSelection alloc] _initWithDocument:_fdocument page:entry->page range:NSMakeRange(start, lineEnd - start)] autorelease];
            if (line.string.length) [result addObject:line];
            start = lineEnd + 1;
        }
    }
    return result;
}
- (void)addSelection:(PDFSelection *)selection { for (PDFSelectionRange *entry in selection->_franges) [self _addPage:entry->page range:entry->range]; }
- (void)addSelections:(NSArray *)selections { for (PDFSelection *selection in selections) [self addSelection:selection]; }
- (void)extendSelectionAtEnd:(NSInteger)succeed
{
    if (!_franges.count || !succeed) return;
    PDFSelectionRange *last = [_franges lastObject]; NSUInteger length = last->page.string.length;
    NSInteger target = (NSInteger)NSMaxRange(last->range) + succeed;
    target = MAX((NSInteger)last->range.location, MIN(target, (NSInteger)length));
    last->range.length = (NSUInteger)target - last->range.location;
}
- (void)extendSelectionAtStart:(NSInteger)precede
{
    if (!_franges.count || !precede) return;
    PDFSelectionRange *first = [_franges objectAtIndex:0]; NSInteger start = (NSInteger)first->range.location - precede;
    start = MAX(0, MIN(start, (NSInteger)NSMaxRange(first->range)));
    first->range.length += first->range.location - (NSUInteger)start; first->range.location = (NSUInteger)start;
}
- (void)extendSelectionForLineBoundaries
{
    for (PDFSelectionRange *entry in _franges) {
        NSString *text = entry->page.string; NSUInteger start = entry->range.location, end = NSMaxRange(entry->range);
        while (start && [text characterAtIndex:start - 1] != '\n') start--;
        while (end < text.length && [text characterAtIndex:end] != '\n') end++;
        entry->range = NSMakeRange(start, end - start);
    }
}
- (void)drawForPage:(PDFPage *)page active:(BOOL)active { [self drawForPage:page withBox:kPDFDisplayBoxCropBox active:active]; }
- (void)drawForPage:(PDFPage *)page withBox:(PDFDisplayBox)box active:(BOOL)active
{
    NSColor *color = _fcolor ?: (active ? [NSColor selectedTextBackgroundColor] : [NSColor secondarySelectedControlColor]);
    [color set];
    for (PDFSelectionRange *entry in _franges) if (entry->page == page) {
        NSUInteger end = MIN(NSMaxRange(entry->range), page.numberOfCharacters);
        for (NSUInteger i = entry->range.location; i < end; i++) NSRectFill([page characterBoundsAtIndex:(NSInteger)i]);
    }
    (void)box;
}
- (id)copyWithZone:(NSZone *)zone
{
    PDFSelection *copy = [[[self class] allocWithZone:zone] initWithDocument:_fdocument];
    [copy addSelection:self]; copy->_fcolor = [_fcolor copy]; return copy;
}
- (void)dealloc { [_fdocument release]; [_franges release]; [_fcolor release]; [super dealloc]; }
@end

static CFDataRef PDFDataForRect(CGRect rect)
{
    return CFDataCreate(kCFAllocatorDefault, (const UInt8 *)&rect, sizeof(rect));
}

static CFDictionaryRef PDFCreateOutlineDictionary(PDFOutline *outline, PDFDocument *document)
{
    if (!outline) return NULL;
    CFMutableDictionaryRef result = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (outline.label) CFDictionarySetValue(result, kCGPDFOutlineTitle, (CFStringRef)outline.label);
    if ([outline.action isKindOfClass:[PDFActionURL class]]) {
        NSURL *url = [(PDFActionURL *)outline.action URL]; if (url) CFDictionarySetValue(result, kCGPDFOutlineDestination, (CFURLRef)url);
    } else if (outline.destination.page) {
        long page = (long)[document indexForPage:outline.destination.page] + 1;
        CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberLongType, &page);
        if (number) { CFDictionarySetValue(result, kCGPDFOutlineDestination, number); CFRelease(number); }
    }
    if (outline.numberOfChildren) {
        CFMutableArrayRef children = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
        for (NSUInteger i = 0; i < outline.numberOfChildren; i++) {
            CFDictionaryRef child = PDFCreateOutlineDictionary([outline childAtIndex:i], document);
            if (child) { CFArrayAppendValue(children, child); CFRelease(child); }
        }
        CFDictionarySetValue(result, kCGPDFOutlineChildren, children); CFRelease(children);
    }
    return result;
}

static NSDictionary *PDFCGContextAttributes(NSDictionary *attributes)
{
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSDictionary *mapping = @{ PDFDocumentTitleAttribute: (id)kCGPDFContextTitle,
                                PDFDocumentAuthorAttribute: (id)kCGPDFContextAuthor,
                                PDFDocumentSubjectAttribute: (id)kCGPDFContextSubject,
                                PDFDocumentCreatorAttribute: (id)kCGPDFContextCreator,
                                PDFDocumentKeywordsAttribute: (id)kCGPDFContextKeywords };
    for (NSString *key in mapping) if ([attributes objectForKey:key]) [result setObject:[attributes objectForKey:key] forKey:[mapping objectForKey:key]];
    return result;
}

static NSData *PDFCreateDataForPages(NSArray *pages, NSDictionary *attributes, PDFOutline *outline, PDFDocument *document)
{
    for (PDFPage *page in pages) if ([page _hasUnsupportedAnnotations]) return nil;
    CFMutableDataRef output = CFDataCreateMutable(kCFAllocatorDefault, 0);
    CGDataConsumerRef consumer = CGDataConsumerCreateWithCFData(output);
    NSDictionary *contextAttributes = PDFCGContextAttributes(attributes ?: @{});
    CGContextRef context = CGPDFContextCreate(consumer, NULL, (CFDictionaryRef)contextAttributes);
    CGDataConsumerRelease(consumer);
    if (!context) { CFRelease(output); return nil; }
    CFDictionaryRef outlineDictionary = PDFCreateOutlineDictionary(outline, document);
    if (outlineDictionary) { CGPDFContextSetOutline(context, outlineDictionary); CFRelease(outlineDictionary); }
    for (PDFPage *page in pages) {
        CGRect media = [page boundsForBox:kPDFDisplayBoxMediaBox];
        CFMutableDictionaryRef pageInfo = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDataRef boxData = PDFDataForRect(media);
        if (boxData) { CFDictionarySetValue(pageInfo, kCGPDFContextMediaBox, boxData); CFRelease(boxData); }
        CGPDFContextBeginPage(context, pageInfo);
        CFRelease(pageInfo);
        for (PDFAnnotation *annotation in page.annotations) {
            NSURL *url = [(PDFActionURL *)annotation.action URL];
            if (url) CGPDFContextSetURLForRect(context, (CFURLRef)url, annotation.bounds);
        }
        [page drawWithBox:kPDFDisplayBoxMediaBox toContext:context];
        CGPDFContextEndPage(context);
    }
    CGPDFContextClose(context);
    CGContextRelease(context);
    NSData *data = [[NSData alloc] initWithBytes:CFDataGetBytePtr(output) length:(NSUInteger)CFDataGetLength(output)];
    CFRelease(output);
    return [data autorelease];
}

static PDFOutline *PDFOutlineFromDictionary(CFDictionaryRef dictionary, PDFDocument *document, PDFOutline *parent, BOOL root)
{
    if (!dictionary) return nil;
    PDFOutline *outline = [[PDFOutline alloc] init];
    outline->_fparent = parent;
    outline->_froot = root;
    if (!root) {
        CFStringRef title = CFDictionaryGetValue(dictionary, kCGPDFOutlineTitle);
        if (title) outline.label = (NSString *)title;
        CFTypeRef destination = CFDictionaryGetValue(dictionary, kCGPDFOutlineDestination);
        if (destination && CFGetTypeID(destination) == CFNumberGetTypeID()) {
            long index = 0; CFNumberGetValue(destination, kCFNumberLongType, &index);
            if (index > 0 && (NSUInteger)index <= document.pageCount) {
                PDFPage *page = [document pageAtIndex:(NSUInteger)index - 1];
                outline.destination = [[[PDFDestination alloc] initWithPage:page atPoint:CGPointZero] autorelease];
            }
        } else if (destination && CFGetTypeID(destination) == CFURLGetTypeID()) {
            outline.action = [[[PDFActionURL alloc] initWithURL:(NSURL *)destination] autorelease];
        }
    }
    CFArrayRef children = CFDictionaryGetValue(dictionary, kCGPDFOutlineChildren);
    if (children && CFGetTypeID(children) == CFArrayGetTypeID()) {
        for (CFIndex i = 0; i < CFArrayGetCount(children); i++) {
            PDFOutline *child = PDFOutlineFromDictionary(CFArrayGetValueAtIndex(children, i), document, outline, NO);
            if (child) [outline->_fchildren addObject:child];
        }
    }
    [outline _setDocument:document parent:parent root:root];
    return [outline autorelease];
}

@implementation PDFDocument {
@public
    CGPDFDocumentRef _fdocumentRef;
    NSData *_fdata;
    NSURL *_furl;
    NSMutableArray *_fpages;
    NSMutableDictionary *_fattributes;
    PDFOutline *_foutline;
    id<PDFDocumentDelegate> _fdelegate;
    BOOL _fdirty, _ffinding, _fcancelFind;
    NSInteger _fmajor, _fminor;
}
- (instancetype)init
{
    if ((self = [super init]) && ![self _loadData:[NSData data]]) { [self release]; return nil; }
    return self;
}
- (instancetype)initWithURL:(NSURL *)url
{
    if (!(self = [super init])) return nil;
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data || ![self _loadData:data]) { [self release]; return nil; }
    _furl = [url copy];
    return self;
}
- (instancetype)initWithData:(NSData *)data
{
    if (!(self = [super init])) return nil;
    if (![self _loadData:data]) { [self release]; return nil; }
    return self;
}
- (BOOL)_loadData:(NSData *)data
{
    _fdata = [data copy]; _fpages = [NSMutableArray new]; _fattributes = [NSMutableDictionary new];
    if (!_fdata.length) return YES;
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((CFDataRef)_fdata);
    _fdocumentRef = CGPDFDocumentCreateWithProvider(provider);
    if (provider) CGDataProviderRelease(provider);
    if (!_fdocumentRef || !CGPDFDocumentGetNumberOfPages(_fdocumentRef)) return NO;
    int major = 0, minor = 0;
    CGPDFDocumentGetVersion(_fdocumentRef, &major, &minor);
    _fmajor = major; _fminor = minor;
    CGPDFDictionaryRef info = CGPDFDocumentGetInfo(_fdocumentRef);
    struct { const char *pdfKey; NSString *attribute; } keys[] = {
        {"Title", PDFDocumentTitleAttribute}, {"Author", PDFDocumentAuthorAttribute}, {"Subject", PDFDocumentSubjectAttribute},
        {"Creator", PDFDocumentCreatorAttribute}, {"Producer", PDFDocumentProducerAttribute}, {"Keywords", PDFDocumentKeywordsAttribute}
    };
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        CGPDFStringRef value = NULL;
        if (info && CGPDFDictionaryGetString(info, keys[i].pdfKey, &value)) {
            NSString *string = PDFStringFromPDFString(value); if (string) [_fattributes setObject:string forKey:keys[i].attribute];
        }
    }
    for (size_t i = 1; i <= CGPDFDocumentGetNumberOfPages(_fdocumentRef); i++) {
        CGPDFPageRef pageRef = CGPDFDocumentGetPage(_fdocumentRef, i);
        Class cls = [self pageClass];
        PDFPage *page = [[cls alloc] _initWithDocument:self pageRef:pageRef index:i - 1];
        if (page) { [_fpages addObject:page]; [page release]; }
    }
    return YES;
}
- (NSURL *)documentURL { return _furl; }
- (CGPDFDocumentRef)documentRef { return _fdocumentRef; }
- (NSDictionary *)documentAttributes { return [[_fattributes copy] autorelease]; }
- (void)setDocumentAttributes:(NSDictionary *)attributes { [_fattributes setDictionary:attributes ?: @{}]; [self _markDirty]; }
- (NSInteger)majorVersion { return _fmajor; }
- (NSInteger)minorVersion { return _fminor; }
- (BOOL)isEncrypted { return _fdocumentRef && CGPDFDocumentIsEncrypted(_fdocumentRef); }
- (BOOL)isLocked { return _fdocumentRef && !CGPDFDocumentIsUnlocked(_fdocumentRef); }
- (BOOL)unlockWithPassword:(NSString *)password
{
    BOOL unlocked = _fdocumentRef && CGPDFDocumentUnlockWithPassword(_fdocumentRef, [password UTF8String]);
    if (unlocked) [[NSNotificationCenter defaultCenter] postNotificationName:PDFDocumentDidUnlockNotification object:self];
    return unlocked;
}
- (BOOL)allowsPrinting { return !_fdocumentRef || CGPDFDocumentAllowsPrinting(_fdocumentRef); }
- (BOOL)allowsCopying { return !_fdocumentRef || CGPDFDocumentAllowsCopying(_fdocumentRef); }
- (BOOL)allowsDocumentChanges { return !_fdocumentRef || (CGPDFDocumentGetAccessPermissions(_fdocumentRef) & kCGPDFAllowsDocumentChanges); }
- (BOOL)allowsDocumentAssembly { return !_fdocumentRef || (CGPDFDocumentGetAccessPermissions(_fdocumentRef) & kCGPDFAllowsDocumentAssembly); }
- (BOOL)allowsContentAccessibility { return !_fdocumentRef || (CGPDFDocumentGetAccessPermissions(_fdocumentRef) & kCGPDFAllowsContentAccessibility); }
- (BOOL)allowsCommenting { return !_fdocumentRef || (CGPDFDocumentGetAccessPermissions(_fdocumentRef) & kCGPDFAllowsCommenting); }
- (BOOL)allowsFormFieldEntry { return !_fdocumentRef || (CGPDFDocumentGetAccessPermissions(_fdocumentRef) & kCGPDFAllowsFormFieldEntry); }
- (PDFAccessPermissions)accessPermissions { return _fdocumentRef ? (PDFAccessPermissions)CGPDFDocumentGetAccessPermissions(_fdocumentRef) : (PDFAllowsLowQualityPrinting | PDFAllowsHighQualityPrinting | PDFAllowsDocumentChanges | PDFAllowsDocumentAssembly | PDFAllowsContentCopying | PDFAllowsContentAccessibility | PDFAllowsCommenting | PDFAllowsFormFieldEntry); }
- (PDFDocumentPermissions)permissionsStatus { return self.isLocked ? kPDFDocumentPermissionsNone : (self.isEncrypted ? kPDFDocumentPermissionsUser : kPDFDocumentPermissionsOwner); }
- (NSString *)string
{
    NSMutableArray *strings = [NSMutableArray array];
    for (PDFPage *page in _fpages) if (page.string) [strings addObject:page.string];
    return [strings componentsJoinedByString:@"\n"];
}
- (id<PDFDocumentDelegate>)delegate { return _fdelegate; }
- (void)setDelegate:(id<PDFDocumentDelegate>)delegate { _fdelegate = delegate; }
- (PDFOutline *)outlineRoot
{
    if (!_foutline && _fdocumentRef) {
        CFDictionaryRef source = CGPDFDocumentGetOutline(_fdocumentRef);
        if (source) _foutline = [PDFOutlineFromDictionary(source, self, nil, YES) retain];
    }
    return _foutline;
}
- (void)setOutlineRoot:(PDFOutline *)outline
{
    if (_foutline != outline) { [_foutline release]; _foutline = [outline retain]; }
    [_foutline _setDocument:self parent:nil root:YES]; [self _markDirty];
}
- (NSUInteger)pageCount { return _fpages.count; }
- (PDFPage *)pageAtIndex:(NSUInteger)index { return index < _fpages.count ? [_fpages objectAtIndex:index] : nil; }
- (NSUInteger)indexForPage:(PDFPage *)page { NSUInteger index = [_fpages indexOfObjectIdenticalTo:page]; return index == NSNotFound ? NSNotFound : index; }
- (void)insertPage:(PDFPage *)page atIndex:(NSUInteger)index
{
    if (!page || index > _fpages.count) [NSException raise:NSRangeException format:@"PDF page index out of range"];
    PDFPage *copy = page.document && page.document != self ? [page copy] : [page retain];
    copy->_fdocument = self; [_fpages insertObject:copy atIndex:index]; [copy release]; [self _markDirty];
    for (NSUInteger i = 0; i < _fpages.count; i++) ((PDFPage *)_fpages[i])->_findex = i;
}
- (void)removePageAtIndex:(NSUInteger)index
{
    if (index >= _fpages.count) [NSException raise:NSRangeException format:@"PDF page index out of range"];
    ((PDFPage *)_fpages[index])->_fdocument = nil; [_fpages removeObjectAtIndex:index]; [self _markDirty];
    for (NSUInteger i = 0; i < _fpages.count; i++) ((PDFPage *)_fpages[i])->_findex = i;
}
- (void)exchangePageAtIndex:(NSUInteger)a withPageAtIndex:(NSUInteger)b
{
    if (a >= _fpages.count || b >= _fpages.count) [NSException raise:NSRangeException format:@"PDF page index out of range"];
    if (a != b) { [_fpages exchangeObjectAtIndex:a withObjectAtIndex:b]; [self _markDirty]; }
    for (NSUInteger i = 0; i < _fpages.count; i++) ((PDFPage *)_fpages[i])->_findex = i;
}
- (Class)pageClass { return [_fdelegate respondsToSelector:@selector(classForPage)] ? [_fdelegate classForPage] : [PDFPage class]; }
- (NSArray *)findString:(NSString *)query withOptions:(NSStringCompareOptions)options
{
    if (!query.length) return @[];
    NSMutableArray *results = [NSMutableArray array];
    BOOL backwards = (options & NSBackwardsSearch) != 0;
    NSStringCompareOptions compareOptions = options & ~NSBackwardsSearch;
    for (PDFPage *page in (backwards ? [[_fpages reverseObjectEnumerator] allObjects] : _fpages)) {
        NSString *text = page.string; NSRange search = NSMakeRange(0, text.length);
        while (search.length) {
            NSRange match = [text rangeOfString:query options:compareOptions range:search];
            if (match.location == NSNotFound) break;
            PDFSelection *selection = [page selectionForRange:match]; if (selection) [results addObject:selection];
            if (backwards) { if (!match.location) break; search.length = match.location; }
            else { NSUInteger end = NSMaxRange(match); if (end >= text.length) break; search = NSMakeRange(end, text.length - end); }
        }
    }
    return results;
}
- (void)beginFindString:(NSString *)query withOptions:(NSStringCompareOptions)options { [self beginFindStrings:query ? @[query] : @[] withOptions:options]; }
- (void)beginFindStrings:(NSArray *)queries withOptions:(NSStringCompareOptions)options
{
    _ffinding = YES; _fcancelFind = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:PDFDocumentDidBeginFindNotification object:self];
        for (PDFPage *page in _fpages) {
            if (_fcancelFind) break;
            NSUInteger index = [self indexForPage:page];
            NSDictionary *info = @{ PDFDocumentPageIndexKey: @(index) };
            [[NSNotificationCenter defaultCenter] postNotificationName:PDFDocumentDidBeginPageFindNotification object:self userInfo:info];
            for (NSString *query in queries) for (PDFSelection *selection in [self findString:query withOptions:options]) {
                if (_fcancelFind) break;
                if ([selection.pages containsObject:page]) {
                    NSDictionary *match = @{ PDFDocumentFoundSelectionKey: selection };
                    [[NSNotificationCenter defaultCenter] postNotificationName:PDFDocumentDidFindMatchNotification object:self userInfo:match];
                    if ([_fdelegate respondsToSelector:@selector(didMatchString:)]) [_fdelegate didMatchString:selection];
                }
            }
            [[NSNotificationCenter defaultCenter] postNotificationName:PDFDocumentDidEndPageFindNotification object:self userInfo:info];
        }
        _ffinding = NO;
        [[NSNotificationCenter defaultCenter] postNotificationName:PDFDocumentDidEndFindNotification object:self];
    });
}
- (PDFSelection *)findString:(NSString *)query fromSelection:(PDFSelection *)selection withOptions:(NSStringCompareOptions)options
{
    NSArray *matches = [self findString:query withOptions:options];
    if (!matches.count) return nil;
    if (!selection || !selection.pages.count) return (options & NSBackwardsSearch) ? [matches lastObject] : [matches firstObject];
    PDFPage *fromPage = [selection.pages lastObject]; NSUInteger fromIndex = [self indexForPage:fromPage]; NSRange fromRange = [selection rangeAtIndex:[selection numberOfTextRangesOnPage:fromPage] - 1 onPage:fromPage];
    for (PDFSelection *candidate in matches) {
        PDFPage *candidatePage = [candidate.pages firstObject]; NSUInteger index = [self indexForPage:candidatePage];
        NSRange range = [candidate rangeAtIndex:0 onPage:candidatePage];
        if (options & NSBackwardsSearch) { if (index < fromIndex || (index == fromIndex && NSMaxRange(range) <= fromRange.location)) return candidate; }
        else if (index > fromIndex || (index == fromIndex && range.location >= NSMaxRange(fromRange))) return candidate;
    }
    return nil;
}
- (BOOL)isFinding { return _ffinding; }
- (void)cancelFindString { _fcancelFind = YES; }
- (PDFSelection *)selectionForEntireDocument
{
    PDFSelection *selection = [[[PDFSelection alloc] initWithDocument:self] autorelease];
    for (PDFPage *page in _fpages) if (page.numberOfCharacters) [selection _addPage:page range:NSMakeRange(0, page.numberOfCharacters)];
    return selection;
}
- (PDFSelection *)selectionFromPage:(PDFPage *)startPage atCharacterIndex:(NSUInteger)start toPage:(PDFPage *)endPage atCharacterIndex:(NSUInteger)end
{
    NSUInteger a = [self indexForPage:startPage], b = [self indexForPage:endPage];
    if (a == NSNotFound || b == NSNotFound) return nil;
    if (a > b || (a == b && start > end)) { NSUInteger t = a; a = b; b = t; t = start; start = end; end = t; }
    PDFSelection *selection = [[[PDFSelection alloc] initWithDocument:self] autorelease];
    for (NSUInteger i = a; i <= b; i++) {
        PDFPage *page = _fpages[i]; NSUInteger length = page.numberOfCharacters;
        NSUInteger first = i == a ? MIN(start, length) : 0, last = i == b ? MIN(end + 1, length) : length;
        if (last > first) [selection _addPage:page range:NSMakeRange(first, last - first)];
    }
    return selection;
}
- (PDFSelection *)selectionFromPage:(PDFPage *)startPage atPoint:(PDFPoint)startPoint toPage:(PDFPage *)endPage atPoint:(PDFPoint)endPoint
{
    NSInteger a = [startPage characterIndexAtPoint:startPoint], b = [endPage characterIndexAtPoint:endPoint];
    if (a == NSNotFound || b == NSNotFound) return nil;
    return [self selectionFromPage:startPage atCharacterIndex:(NSUInteger)a toPage:endPage atCharacterIndex:(NSUInteger)b];
}
- (PDFSelection *)selectionFromPage:(PDFPage *)startPage atPoint:(PDFPoint)startPoint toPage:(PDFPage *)endPage atPoint:(PDFPoint)endPoint withGranularity:(PDFSelectionGranularity)granularity
{
    PDFSelection *selection = [self selectionFromPage:startPage atPoint:startPoint toPage:endPage atPoint:endPoint];
    if (granularity == PDFSelectionGranularityWord && selection) {
        PDFSelection *first = [startPage selectionForWordAtPoint:startPoint], *last = [endPage selectionForWordAtPoint:endPoint];
        if (first && last && startPage == endPage) { selection = [[[PDFSelection alloc] initWithDocument:self] autorelease]; [selection addSelection:first]; [selection addSelection:last]; }
    }
    return selection;
}
- (NSData *)dataRepresentation { return [self dataRepresentationWithOptions:@{}]; }
- (NSData *)dataRepresentationWithOptions:(NSDictionary *)options
{
    if (options.count) return nil;
    if (!_fdirty && _fdata) return [[_fdata copy] autorelease];
    return PDFCreateDataForPages(_fpages, _fattributes, self.outlineRoot, self);
}
- (BOOL)writeToFile:(NSString *)path { return [self writeToFile:path withOptions:nil]; }
- (BOOL)writeToFile:(NSString *)path withOptions:(NSDictionary *)options { return [self writeToURL:[NSURL fileURLWithPath:path] withOptions:options]; }
- (BOOL)writeToURL:(NSURL *)url { return [self writeToURL:url withOptions:nil]; }
- (BOOL)writeToURL:(NSURL *)url withOptions:(NSDictionary *)options
{
    [[NSNotificationCenter defaultCenter] postNotificationName:PDFDocumentDidBeginWriteNotification object:self];
    NSData *data = [self dataRepresentationWithOptions:options];
    BOOL result = data && [data writeToURL:url atomically:YES];
    [[NSNotificationCenter defaultCenter] postNotificationName:PDFDocumentDidEndWriteNotification object:self];
    if (result) { [_furl release]; _furl = [url copy]; }
    return result;
}
- (NSPrintOperation *)printOperationForPrintInfo:(NSPrintInfo *)printInfo scalingMode:(PDFPrintScalingMode)scaleMode autoRotate:(BOOL)doRotate
{
    if (!_fpages.count) return nil;
    PDFView *view = [[PDFView alloc] initWithFrame:NSMakeRect(0, 0, 612, 792)];
    view.document = self;
    NSPrintOperation *operation = [NSPrintOperation printOperationWithView:view printInfo:printInfo ?: [NSPrintInfo sharedPrintInfo]];
    [view release];
    (void)scaleMode; (void)doRotate;
    return operation;
}
- (PDFSelection *)outlineItemForSelection:(PDFSelection *)selection
{
    if (!selection.pages.count) return nil;
    PDFPage *page = [selection.pages firstObject]; NSUInteger index = [self indexForPage:page];
    PDFOutline *root = self.outlineRoot;
    NSMutableArray *stack = [NSMutableArray arrayWithArray:root ? root->_fchildren : @[]];
    while (stack.count) {
        PDFOutline *item = [stack firstObject]; [stack removeObjectAtIndex:0];
        if (item.destination.page == page) return selection;
        [stack addObjectsFromArray:item->_fchildren];
    }
    (void)index;
    return nil;
}
- (Class)classForAnnotationType:(NSString *)annotationType { (void)annotationType; return [PDFAnnotation class]; }
- (void)_markDirty { _fdirty = YES; }
- (id)copyWithZone:(NSZone *)zone
{
    NSData *data = self.dataRepresentation;
    if (!data) return nil;
    return [[[self class] allocWithZone:zone] initWithData:data];
}
- (void)dealloc
{
    if (_fdocumentRef) CGPDFDocumentRelease(_fdocumentRef);
    [_fdata release]; [_furl release]; [_fpages release]; [_fattributes release]; [_foutline release];
    [super dealloc];
}
@end
