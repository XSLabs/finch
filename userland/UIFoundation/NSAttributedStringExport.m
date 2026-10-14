/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Attributed strings written as HTML, web archives, Word 2003 XML (WordML), Word 2007
 * (Office Open XML, .docx) and OpenDocument text (.odt), for NSAttributedString's
 * dataFromRange:documentAttributes:error: (NSAttributedStringDocuments.m). Each is made
 * from the text's paragraphs (their alignment) and runs (font family, size, bold, italic,
 * underline, strikethrough, colour), the parts of a document TextEdit's formats carry; the
 * .docx and .odt packages are zip files of their XML parts, stored uncompressed.
 *
 * Fonts and colours are AppKit's: they're asked for what they are by message, as this
 * framework doesn't link AppKit.
 */
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <zlib.h>

@interface NSObject (FinchExportFont)
- (NSString *)familyName;
- (CGFloat)pointSize;
- (id)fontDescriptor;
- (uint32_t)symbolicTraits;
- (CGColorRef)CGColor;
@end

/* the attribute names, as AppKit spells them (NSAttributedString.h) */
static NSString *const FontKey = @"NSFont";
static NSString *const ColorKey = @"NSColor";
static NSString *const UnderlineKey = @"NSUnderline";
static NSString *const StrikeKey = @"NSStrikethrough";
static NSString *const ParagraphKey = @"NSParagraphStyle";

enum { TraitItalic = 1u << 0, TraitBold = 1u << 1 };

typedef struct {
    NSString *family;
    CGFloat size;
    BOOL bold, italic, underline, strike;
    BOOL hasColor;
    int r, g, b;
} RunStyle;

static RunStyle
run_style(NSDictionary *attrs)
{
    RunStyle s = {0};
    id font = attrs[FontKey];
    if (font && [font respondsToSelector:@selector(familyName)]) {
        s.family = [font familyName];
        s.size = [font pointSize];
        uint32_t traits = [[font fontDescriptor] symbolicTraits];
        s.bold = (traits & TraitBold) != 0;
        s.italic = (traits & TraitItalic) != 0;
    }
    s.underline = [attrs[UnderlineKey] integerValue] != 0;
    s.strike = [attrs[StrikeKey] integerValue] != 0;
    id color = attrs[ColorKey];
    if (color && [color respondsToSelector:@selector(CGColor)]) {
        CGColorRef cg = [color CGColor];
        CGColorSpaceRef rgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGColorRef conv = cg ? CGColorCreateCopyByMatchingToColorSpace(rgb, kCGRenderingIntentDefault, cg, NULL) : NULL;
        CGColorSpaceRelease(rgb);
        if (conv && CGColorGetNumberOfComponents(conv) >= 3) {
            const CGFloat *c = CGColorGetComponents(conv);
            s.r = (int)lround(c[0] * 255), s.g = (int)lround(c[1] * 255), s.b = (int)lround(c[2] * 255);
            /* black is every format's default: written only when it's another colour */
            s.hasColor = s.r || s.g || s.b;
        }
        if (conv)
            CGColorRelease(conv);
    }
    return s;
}

/* a paragraph's alignment as NSTextAlignment has it on macOS (0 left, 1 centre, 2 right,
   3 justified), or -1 for natural */
static NSInteger
alignment_of(NSDictionary *attrs)
{
    id ps = attrs[ParagraphKey];
    NSInteger a = ps ? (NSInteger)[ps alignment] : 4;
    return (a >= 0 && a <= 3) ? a : -1;  /* natural: none written, as Apple's writers do */
}

static NSString *
escape_xml(NSString *s)
{
    NSMutableString *m = [[s mutableCopy] autorelease];
    [m replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, [m length])];
    [m replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, [m length])];
    [m replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, [m length])];
    [m replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, [m length])];
    return m;
}

/* Each paragraph of the range (without its terminator), with its first character's attributes, and its runs. */
static void
each_paragraph(NSAttributedString *as, NSRange range,
               void (^paragraph)(NSRange p, NSDictionary *first, void (^runs)(void (^)(NSString *text, NSDictionary *attrs))))
{
    NSString *str = [as string];
    NSUInteger at = range.location, end = NSMaxRange(range);
    while (at < end || (at == end && at == range.location)) {
        NSUInteger pend = at, next = at;
        if (at < end) {
            NSUInteger start;
            [str getParagraphStart:&start end:&next contentsEnd:&pend forRange:NSMakeRange(at, 0)];
            pend = MIN(pend, end);
            next = MIN(next, end);
        }
        NSRange p = NSMakeRange(at, pend - at);
        NSDictionary *first = [as length] ? [as attributesAtIndex:MIN(at, [as length] - 1) effectiveRange:NULL] : @{};
        paragraph(p, first, ^(void (^run)(NSString *, NSDictionary *)) {
            [as enumerateAttributesInRange:p options:0 usingBlock:^(NSDictionary *a, NSRange r, BOOL *stop) {
                run([str substringWithRange:r], a);
            }];
        });
        if (next == at)
            break;
        at = next;
    }
}

#pragma mark - HTML

static NSString *
css_of(RunStyle s)
{
    NSMutableString *css = [NSMutableString string];
    if (s.family)
        [css appendFormat:@"font-family: '%@'; ", escape_xml(s.family)];
    if (s.size > 0)
        [css appendFormat:@"font-size: %gpx; ", s.size];  /* (a CSS pixel is a point, in WebKit) */
    if (s.bold)
        [css appendString:@"font-weight: bold; "];
    if (s.italic)
        [css appendString:@"font-style: italic; "];
    if (s.underline || s.strike)
        [css appendFormat:@"text-decoration:%@%@; ", s.underline ? @" underline" : @"", s.strike ? @" line-through" : @""];
    if (s.hasColor)
        [css appendFormat:@"color: #%02x%02x%02x; ", s.r, s.g, s.b];
    return css;
}

static NSString *
html_of(NSAttributedString *as, NSRange range, NSDictionary *dict)
{
    static NSString *const align[] = {@"left", @"center", @"right", @"justify"};
    NSMutableString *out = [NSMutableString stringWithString:
        @"<!DOCTYPE html PUBLIC \"-//W3C//DTD HTML 4.01//EN\" \"http://www.w3.org/TR/html4/strict.dtd\">\n<html>\n<head>\n"
        @"<meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\">\n"];
    NSString *title = dict[@"NSTitleDocumentAttribute"] ?: dict[@"Title"];
    if (title)
        [out appendFormat:@"<title>%@</title>\n", escape_xml(title)];
    [out appendString:@"</head>\n<body>\n"];
    each_paragraph(as, range, ^(NSRange p, NSDictionary *first, void (^runs)(void (^)(NSString *, NSDictionary *))) {
        NSInteger a = alignment_of(first);
        if (a >= 0)
            [out appendFormat:@"<p style=\"margin: 0; text-align: %@;\">", align[a]];
        else
            [out appendString:@"<p style=\"margin: 0;\">"];
        __block BOOL any = NO;
        runs(^(NSString *text, NSDictionary *attrs) {
            any = YES;
            [out appendFormat:@"<span style=\"%@\">%@</span>", css_of(run_style(attrs)), escape_xml(text)];
        });
        if (!any)
            [out appendString:@"<br>"];
        [out appendString:@"</p>\n"];
    });
    [out appendString:@"</body>\n</html>\n"];
    return out;
}

#pragma mark - WordML (Word 2003 XML) and Office Open XML (Word 2007)

static NSString *
word_runs(NSAttributedString *as, NSRange range, NSString *ns)
{
    static NSString *const jc[] = {@"left", @"center", @"right", @"both"};
    NSMutableString *body = [NSMutableString string];
    each_paragraph(as, range, ^(NSRange p, NSDictionary *first, void (^runs)(void (^)(NSString *, NSDictionary *))) {
        NSInteger a = alignment_of(first);
        if (a >= 0)
            [body appendFormat:@"<%@:p><%@:pPr><%@:jc %@:val=\"%@\"/></%@:pPr>", ns, ns, ns, ns, jc[a], ns];
        else
            [body appendFormat:@"<%@:p>", ns];
        runs(^(NSString *text, NSDictionary *attrs) {
            RunStyle s = run_style(attrs);
            [body appendFormat:@"<%@:r><%@:rPr>", ns, ns];
            if (s.family)
                [body appendFormat:@"<%@:rFonts %@:ascii=\"%@\" %@:hAnsi=\"%@\"/>", ns, ns, escape_xml(s.family), ns,
                                   escape_xml(s.family)];
            if (s.bold)
                [body appendFormat:@"<%@:b/>", ns];
            if (s.italic)
                [body appendFormat:@"<%@:i/>", ns];
            if (s.strike)
                [body appendFormat:@"<%@:strike/>", ns];
            if (s.hasColor)
                [body appendFormat:@"<%@:color %@:val=\"%02X%02X%02X\"/>", ns, ns, s.r, s.g, s.b];
            if (s.size > 0)
                [body appendFormat:@"<%@:sz %@:val=\"%ld\"/>", ns, ns, (long)lround(s.size * 2)];
            if (s.underline)
                [body appendFormat:@"<%@:u %@:val=\"single\"/>", ns, ns];
            [body appendFormat:@"</%@:rPr>", ns];
            /* tabs as Word's own elements; the rest as text kept as it is */
            NSArray *pieces = [text componentsSeparatedByString:@"\t"];
            for (NSUInteger i = 0; i < [pieces count]; i++) {
                if (i)
                    [body appendFormat:@"<%@:tab/>", ns];
                if ([pieces[i] length])
                    [body appendFormat:@"<%@:t xml:space=\"preserve\">%@</%@:t>", ns, escape_xml(pieces[i]), ns];
            }
            [body appendFormat:@"</%@:r>", ns];
        });
        [body appendFormat:@"</%@:p>", ns];
    });
    return body;
}

static NSString *
wordml_of(NSAttributedString *as, NSRange range)
{
    return [NSString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<?mso-application progid=\"Word.Document\"?>\n"
        @"<w:wordDocument xmlns:w=\"http://schemas.microsoft.com/office/word/2003/wordml\">"
        @"<w:body>%@</w:body></w:wordDocument>\n", word_runs(as, range, @"w")];
}

#pragma mark - Zip packages

@interface FinchZip : NSObject {
    NSMutableData *_data, *_directory;
    uint16_t _count;
}
- (void)add:(NSString *)name data:(NSData *)contents;
- (NSData *)finish;
@end

@implementation FinchZip

- (instancetype)init
{
    if ((self = [super init])) {
        _data = [[NSMutableData alloc] init];
        _directory = [[NSMutableData alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [_data release];
    [_directory release];
    [super dealloc];
}

static void
le16(NSMutableData *d, uint16_t v)
{
    uint8_t b[2] = {(uint8_t)v, (uint8_t)(v >> 8)};
    [d appendBytes:b length:2];
}

static void
le32(NSMutableData *d, uint32_t v)
{
    uint8_t b[4] = {(uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16), (uint8_t)(v >> 24)};
    [d appendBytes:b length:4];
}

/* an entry stored as it is (method 0), with the 1980-01-01 date zip readers accept */
- (void)add:(NSString *)name data:(NSData *)contents
{
    NSData *n = [name dataUsingEncoding:NSUTF8StringEncoding];
    uint32_t crc = (uint32_t)crc32(0, [contents bytes], (uInt)[contents length]);
    uint32_t size = (uint32_t)[contents length], offset = (uint32_t)[_data length];
    le32(_data, 0x04034b50);
    le16(_data, 20), le16(_data, 0x0800), le16(_data, 0), le16(_data, 0), le16(_data, 0x21);
    le32(_data, crc), le32(_data, size), le32(_data, size);
    le16(_data, (uint16_t)[n length]), le16(_data, 0);
    [_data appendData:n];
    [_data appendData:contents];
    le32(_directory, 0x02014b50);
    le16(_directory, 20), le16(_directory, 20), le16(_directory, 0x0800), le16(_directory, 0);
    le16(_directory, 0), le16(_directory, 0x21);
    le32(_directory, crc), le32(_directory, size), le32(_directory, size);
    le16(_directory, (uint16_t)[n length]), le16(_directory, 0), le16(_directory, 0), le16(_directory, 0), le16(_directory, 0);
    le32(_directory, 0), le32(_directory, offset);
    [_directory appendData:n];
    _count++;
}

- (NSData *)finish
{
    uint32_t start = (uint32_t)[_data length];
    [_data appendData:_directory];
    le32(_data, 0x06054b50);
    le16(_data, 0), le16(_data, 0), le16(_data, _count), le16(_data, _count);
    le32(_data, (uint32_t)[_directory length]), le32(_data, start), le16(_data, 0);
    return [[_data copy] autorelease];
}

@end

static NSData *
utf8(NSString *s)
{
    return [s dataUsingEncoding:NSUTF8StringEncoding];
}

static NSData *
docx_of(NSAttributedString *as, NSRange range)
{
    FinchZip *zip = [[[FinchZip alloc] init] autorelease];
    [zip add:@"[Content_Types].xml" data:utf8(
        @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        @"<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        @"<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        @"<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        @"<Override PartName=\"/word/document.xml\" "
        @"ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
        @"</Types>")];
    [zip add:@"_rels/.rels" data:utf8(
        @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        @"<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        @"<Relationship Id=\"rId1\" "
        @"Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" "
        @"Target=\"word/document.xml\"/></Relationships>")];
    [zip add:@"word/document.xml" data:utf8([NSString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        @"<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
        @"<w:body>%@<w:sectPr/></w:body></w:document>", word_runs(as, range, @"w")])];
    return [zip finish];
}

#pragma mark - OpenDocument text

static NSData *
odt_of(NSAttributedString *as, NSRange range)
{
    static NSString *const align[] = {@"start", @"center", @"end", @"justify"};
    NSMutableString *styles = [NSMutableString string], *body = [NSMutableString string];
    NSMutableDictionary *names = [NSMutableDictionary dictionary];
    __block int next = 1;
    NSString * (^style_for)(NSString *, NSString *) = ^NSString *(NSString *family, NSString *props) {
        NSString *key = [family stringByAppendingString:props];
        NSString *name = names[key];
        if (!name) {
            name = [NSString stringWithFormat:@"%@%d", [family isEqual:@"paragraph"] ? @"P" : @"T", next++];
            names[key] = name;
            [styles appendFormat:@"<style:style style:name=\"%@\" style:family=\"%@\">%@</style:style>", name, family, props];
        }
        return name;
    };
    each_paragraph(as, range, ^(NSRange p, NSDictionary *first, void (^runs)(void (^)(NSString *, NSDictionary *))) {
        NSInteger a = alignment_of(first);
        if (a >= 0)
            [body appendFormat:@"<text:p text:style-name=\"%@\">", style_for(@"paragraph", [NSString stringWithFormat:
                @"<style:paragraph-properties fo:text-align=\"%@\"/>", align[a]])];
        else
            [body appendString:@"<text:p>"];
        runs(^(NSString *text, NSDictionary *attrs) {
            RunStyle s = run_style(attrs);
            NSMutableString *props = [NSMutableString stringWithString:@"<style:text-properties"];
            if (s.family)
                [props appendFormat:@" style:font-name=\"%@\" fo:font-family=\"'%@'\"", escape_xml(s.family), escape_xml(s.family)];
            if (s.size > 0)
                [props appendFormat:@" fo:font-size=\"%gpt\"", s.size];
            if (s.bold)
                [props appendString:@" fo:font-weight=\"bold\""];
            if (s.italic)
                [props appendString:@" fo:font-style=\"italic\""];
            if (s.underline)
                [props appendString:@" style:text-underline-style=\"solid\" style:text-underline-width=\"auto\""];
            if (s.strike)
                [props appendString:@" style:text-line-through-style=\"solid\""];
            if (s.hasColor)
                [props appendFormat:@" fo:color=\"#%02x%02x%02x\"", s.r, s.g, s.b];
            [props appendString:@"/>"];
            NSString *tstyle = style_for(@"text", props);
            NSMutableString *t = [NSMutableString string];
            NSArray *pieces = [text componentsSeparatedByString:@"\t"];
            for (NSUInteger i = 0; i < [pieces count]; i++) {
                if (i)
                    [t appendString:@"<text:tab/>"];
                [t appendString:escape_xml(pieces[i])];
            }
            [body appendFormat:@"<text:span text:style-name=\"%@\">%@</text:span>", tstyle, t];
        });
        [body appendString:@"</text:p>"];
    });
    NSString *ns = @"xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" "
                   @"xmlns:style=\"urn:oasis:names:tc:opendocument:xmlns:style:1.0\" "
                   @"xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" "
                   @"xmlns:fo=\"urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0\"";
    FinchZip *zip = [[[FinchZip alloc] init] autorelease];
    /* the mimetype first, stored, as OpenDocument requires */
    [zip add:@"mimetype" data:utf8(@"application/vnd.oasis.opendocument.text")];
    [zip add:@"META-INF/manifest.xml" data:utf8(
        @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        @"<manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.2\">"
        @"<manifest:file-entry manifest:full-path=\"/\" manifest:media-type=\"application/vnd.oasis.opendocument.text\"/>"
        @"<manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/>"
        @"</manifest:manifest>")];
    [zip add:@"content.xml" data:utf8([NSString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        @"<office:document-content %@ office:version=\"1.2\"><office:automatic-styles>%@</office:automatic-styles>"
        @"<office:body><office:text>%@</office:text></office:body></office:document-content>", ns, styles, body])];
    return [zip finish];
}

#pragma mark - Entry

/* The data of one of these formats for `type`, or nil when it's none of them. */
__attribute__((visibility("hidden"))) NSData *
FinchExportAttributedString(NSAttributedString *as, NSRange range, NSString *type, NSDictionary *dict)
{
    if ([type isEqualToString:@"NSHTML"])
        return utf8(html_of(as, range, dict));
    if ([type isEqualToString:@"NSWebArchive"]) {
        NSDictionary *archive = @{@"WebMainResource" : @{
            @"WebResourceData" : utf8(html_of(as, range, dict)),
            @"WebResourceMIMEType" : @"text/html",
            @"WebResourceTextEncodingName" : @"UTF-8",
            @"WebResourceURL" : @"about:blank",
            @"WebResourceFrameName" : @"",
        }};
        return [NSPropertyListSerialization dataWithPropertyList:archive format:NSPropertyListBinaryFormat_v1_0
                                                         options:0 error:NULL];
    }
    if ([type isEqualToString:@"NSWordML"])
        return utf8(wordml_of(as, range));
    if ([type isEqualToString:@"NSOfficeOpenXML"])
        return docx_of(as, range);
    if ([type isEqualToString:@"NSOpenDocument"])
        return odt_of(as, range);
    return nil;
}
