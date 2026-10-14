/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Attributed strings read from HTML, web archives, Word 2003 XML (WordML), Word 2007
 * (.docx) and OpenDocument text (.odt), for NSAttributedString's initWithData: and
 * initWithURL: (NSAttributedStringDocuments.m). Each document's paragraphs (their
 * alignment) and runs (font family, size, bold, italic, underline, strikethrough,
 * colour) are kept, as NSAttributedStringExport.m writes them; HTML's headings, lists
 * and line breaks too. The XML is read by Foundation's NSXMLDocument (HTML through its
 * tidying parser); the .docx and .odt packages are zip files, their parts inflated by
 * zlib.
 */
#import "UIFoundationInternal.h"
#include <zlib.h>

typedef struct {
    NSString *family;
    CGFloat size;
    BOOL bold, italic, underline, strike;
    CGFloat r, g, b;
    BOOL hasColor;
} ImportStyle;

static NSFont *
font_for(ImportStyle s)
{
    CGFloat size = s.size > 0 ? s.size : 12;
    NSFont *font = nil;
    if (s.family) {
        NSDictionary *attrs = @{(id)kCTFontFamilyNameAttribute : s.family};
        CTFontDescriptorRef d = CTFontDescriptorCreateWithAttributes((CFDictionaryRef)attrs);
        CTFontRef f = CTFontCreateWithFontDescriptor(d, size, NULL);
        CFRelease(d);
        if (f) {
            CFStringRef family = CTFontCopyFamilyName(f);
            /* (CoreText answers any family with a fallback: kept only when it's the family asked for, or
               Finch's stand-in for it) */
            BOOL same = family && (CFStringCompare(family, (CFStringRef)s.family, kCFCompareCaseInsensitive) == 0 ||
                                   UIFFontAlias(s.family));
            if (family)
                CFRelease(family);
            font = same ? [(NSFont *)f autorelease] : nil;
            if (!same)
                CFRelease(f);
        }
        if (!font)
            font = [NSFont fontWithName:s.family size:size];
    }
    if (!font)
        font = [NSFont fontWithName:@"Helvetica" size:size] ?: UIFDefaultFont();
    CTFontSymbolicTraits want = (s.bold ? kCTFontTraitBold : 0) | (s.italic ? kCTFontTraitItalic : 0);
    CTFontSymbolicTraits mask = kCTFontTraitBold | kCTFontTraitItalic;
    if ((CTFontGetSymbolicTraits((CTFontRef)font) & mask) != want) {
        CTFontRef t = CTFontCreateCopyWithSymbolicTraits((CTFontRef)font, size, NULL, want, mask);
        if (t)
            font = [(NSFont *)t autorelease];
    }
    return font;
}

static NSDictionary *
attributes_for(ImportStyle s, NSTextAlignment alignment)
{
    NSMutableDictionary *a = [NSMutableDictionary dictionary];
    a[NSFontAttributeName] = font_for(s);
    if (s.underline)
        a[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
    if (s.strike)
        a[NSStrikethroughStyleAttributeName] = @(NSUnderlineStyleSingle);
    if (s.hasColor) {
        Class color = UIFClass("NSColor");
        id c = [color colorWithSRGBRed:s.r green:s.g blue:s.b alpha:1];
        if (c)
            a[NSForegroundColorAttributeName] = c;
    }
    NSMutableParagraphStyle *ps = [[[NSMutableParagraphStyle alloc] init] autorelease];
    [ps setAlignment:alignment];
    a[NSParagraphStyleAttributeName] = ps;
    return a;
}

static BOOL
hex_color(NSString *hex, ImportStyle *s)
{
    if ([hex hasPrefix:@"#"])
        hex = [hex substringFromIndex:1];
    if ([hex length] != 6 || [hex isEqualToString:@"auto"])
        return NO;
    unsigned v = 0;
    if (![[NSScanner scannerWithString:hex] scanHexInt:&v])
        return NO;
    s->r = ((v >> 16) & 0xff) / 255.0, s->g = ((v >> 8) & 0xff) / 255.0, s->b = (v & 0xff) / 255.0;
    s->hasColor = YES;
    return YES;
}

/* A builder: text appended in styles, paragraphs ended with their alignment. */
@interface UIFImportText : NSObject {
@public
    BOOL wholeRunMarks;  /* the line end in all the last run's attributes (Word's), else its font */
    NSMutableAttributedString *out;
    NSUInteger paragraphStart;
    NSTextAlignment alignment;
}
@end

@implementation UIFImportText

- (instancetype)init
{
    if ((self = [super init])) {
        out = [[NSMutableAttributedString alloc] init];
        alignment = NSTextAlignmentNatural;
    }
    return self;
}

- (void)dealloc
{
    [out release];
    [super dealloc];
}

- (void)append:(NSString *)text style:(ImportStyle)s
{
    if (![text length])
        return;
    [out appendAttributedString:[[[NSAttributedString alloc] initWithString:text
                                                                  attributes:attributes_for(s, alignment)] autorelease]];
}

/* the paragraph's alignment over all of it, and its end */
- (void)endParagraph:(ImportStyle)s
{
    /* the line end in the paragraph's last run's font, as Apple's readers give it */
    if ([out length] > paragraphStart) {
        NSDictionary *last = [out attributesAtIndex:[out length] - 1 effectiveRange:NULL];
        NSMutableDictionary *mark = [NSMutableDictionary dictionary];
        for (NSString *k in @[ NSFontAttributeName, NSParagraphStyleAttributeName ])
            if (last[k])
                mark[k] = last[k];
        if (wholeRunMarks)
            [mark addEntriesFromDictionary:last];
        [out appendAttributedString:[[[NSAttributedString alloc] initWithString:@"\n" attributes:mark] autorelease]];
    } else {
        [self append:@"\n" style:s];
    }
    NSRange r = NSMakeRange(paragraphStart, [out length] - paragraphStart);
    NSMutableParagraphStyle *ps = [[[NSMutableParagraphStyle alloc] init] autorelease];
    [ps setAlignment:alignment];
    if (r.length)
        [out addAttribute:NSParagraphStyleAttributeName value:ps range:r];
    paragraphStart = [out length];
    alignment = NSTextAlignmentNatural;
}

/* the text, its last paragraph ended as Apple's readers end it */
- (NSAttributedString *)result
{
    return out;
}

@end

static NSArray<NSXMLElement *> *
child_elements(NSXMLNode *n)
{
    NSMutableArray *a = [NSMutableArray array];
    for (NSXMLNode *c in [n children])
        if ([c kind] == NSXMLElementKind)
            [a addObject:c];
    return a;
}

static NSXMLElement *
child_named(NSXMLNode *n, NSString *local)
{
    for (NSXMLElement *c in child_elements(n))
        if ([[c localName] isEqualToString:local])
            return c;
    return nil;
}

/* an attribute by its local name, whatever its prefix */
static NSString *
attr(NSXMLElement *e, NSString *local)
{
    for (NSXMLNode *a in [e attributes])
        if ([[a localName] isEqualToString:local] || [[a name] isEqualToString:local])
            return [a stringValue];
    return nil;
}

#pragma mark - Zip

static NSDictionary<NSString *, NSData *> *
zip_entries(NSData *data)
{
    const uint8_t *p = [data bytes];
    NSUInteger n = [data length];
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
#define U16(o) ((uint32_t)p[(o)] | (uint32_t)p[(o) + 1] << 8)
#define U32(o) (U16(o) | U16((o) + 2) << 16)
    /* the end of the central directory, searched from the end */
    NSInteger eocd = -1;
    for (NSInteger i = (NSInteger)n - 22; i >= 0 && i >= (NSInteger)n - 22 - 65535; i--)
        if (U32(i) == 0x06054b50) {
            eocd = i;
            break;
        }
    if (eocd < 0)
        return out;
    uint32_t count = U16(eocd + 10), at = U32(eocd + 16);
    for (uint32_t k = 0; k < count && at + 46 <= n && U32(at) == 0x02014b50; k++) {
        uint32_t method = U16(at + 10), csize = U32(at + 20), usize = U32(at + 24);
        uint32_t nameLen = U16(at + 28), extraLen = U16(at + 30), commentLen = U16(at + 32), local = U32(at + 42);
        if (at + 46 + nameLen > n)
            break;
        NSString *name = [[[NSString alloc] initWithBytes:p + at + 46 length:nameLen encoding:NSUTF8StringEncoding] autorelease];
        at += 46 + nameLen + extraLen + commentLen;
        if (local + 30 > n || U32(local) != 0x04034b50)
            continue;
        uint32_t start = local + 30 + U16(local + 26) + U16(local + 28);
        if (start + csize > n || !name)
            continue;
        if (method == 0) {
            out[name] = [NSData dataWithBytes:p + start length:csize];
        } else if (method == 8) {
            NSMutableData *d = [NSMutableData dataWithLength:usize];
            z_stream z = {0};
            z.next_in = (Bytef *)(p + start), z.avail_in = csize;
            z.next_out = [d mutableBytes], z.avail_out = usize;
            if (inflateInit2(&z, -MAX_WBITS) == Z_OK) {
                int r = inflate(&z, Z_FINISH);
                inflateEnd(&z);
                if (r == Z_STREAM_END)
                    out[name] = d;
            }
        }
    }
#undef U16
#undef U32
    return out;
}

#pragma mark - Word (2003 XML and 2007)

static NSTextAlignment
word_alignment(NSString *jc)
{
    if ([jc isEqualToString:@"center"])
        return NSTextAlignmentCenter;
    if ([jc isEqualToString:@"right"] || [jc isEqualToString:@"end"])
        return NSTextAlignmentRight;
    if ([jc isEqualToString:@"both"] || [jc isEqualToString:@"distribute"])
        return NSTextAlignmentJustified;
    if ([jc isEqualToString:@"left"] || [jc isEqualToString:@"start"])
        return NSTextAlignmentLeft;
    return NSTextAlignmentNatural;
}

/* a toggle property (w:b, w:i...): on unless its value says off */
static BOOL
word_on(NSXMLElement *e)
{
    NSString *v = attr(e, @"val");
    return !v || !([v isEqualToString:@"0"] || [v isEqualToString:@"false"] || [v isEqualToString:@"off"] ||
                   [v isEqualToString:@"none"]);
}

static void
word_run_properties(NSXMLElement *rPr, ImportStyle *s)
{
    for (NSXMLElement *e in child_elements(rPr)) {
        NSString *n = [e localName];
        if ([n isEqualToString:@"rFonts"]) {
            NSString *f = attr(e, @"ascii") ?: attr(e, @"hAnsi");
            if (f)
                s->family = f;
        } else if ([n isEqualToString:@"b"]) {
            s->bold = word_on(e);
        } else if ([n isEqualToString:@"i"]) {
            s->italic = word_on(e);
        } else if ([n isEqualToString:@"u"]) {
            s->underline = word_on(e);
        } else if ([n isEqualToString:@"strike"]) {
            s->strike = word_on(e);
        } else if ([n isEqualToString:@"color"]) {
            hex_color(attr(e, @"val"), s);
        } else if ([n isEqualToString:@"sz"]) {
            NSString *v = attr(e, @"val");
            if (v)
                s->size = [v doubleValue] / 2;
        }
    }
}

static void word_block(NSXMLElement *container, UIFImportText *t, ImportStyle base);

static void
word_runs(NSXMLElement *e, UIFImportText *t, ImportStyle base)
{
    for (NSXMLElement *c in child_elements(e)) {
        NSString *n = [c localName];
        if ([n isEqualToString:@"r"]) {
            ImportStyle s = base;
            NSXMLElement *rPr = child_named(c, @"rPr");
            if (rPr)
                word_run_properties(rPr, &s);
            for (NSXMLElement *x in child_elements(c)) {
                NSString *xn = [x localName];
                if ([xn isEqualToString:@"t"])
                    [t append:[x stringValue] style:s];
                else if ([xn isEqualToString:@"tab"])
                    [t append:@"\t" style:s];
                else if ([xn isEqualToString:@"br"] || [xn isEqualToString:@"cr"])
                    [t append:@" " style:s];
            }
        } else if ([n isEqualToString:@"hyperlink"] || [n isEqualToString:@"smartTag"] || [n isEqualToString:@"ins"] ||
                   [n isEqualToString:@"sdtContent"] || [n isEqualToString:@"sdt"] || [n isEqualToString:@"fldSimple"]) {
            word_runs(c, t, base);
        }
    }
}

static void
word_paragraph(NSXMLElement *p, UIFImportText *t, ImportStyle base)
{
    NSXMLElement *pPr = child_named(p, @"pPr");
    t->alignment = word_alignment(attr(child_named(pPr, @"jc") ?: (NSXMLElement *)nil, @"val"));
    ImportStyle s = base;
    NSXMLElement *mark = child_named(pPr, @"rPr");
    if (mark)
        word_run_properties(mark, &s);
    word_runs(p, t, base);
    [t endParagraph:s];
}

static void
word_block(NSXMLElement *container, UIFImportText *t, ImportStyle base)
{
    for (NSXMLElement *c in child_elements(container)) {
        NSString *n = [c localName];
        if ([n isEqualToString:@"p"])
            word_paragraph(c, t, base);
        else if ([n isEqualToString:@"tbl"] || [n isEqualToString:@"tr"] || [n isEqualToString:@"tc"] ||
                 [n isEqualToString:@"sdt"] || [n isEqualToString:@"sdtContent"] || [n isEqualToString:@"sect"] ||
                 [n isEqualToString:@"sub-section"])
            word_block(c, t, base);
    }
}

static NSXMLElement *
descendant_named(NSXMLNode *n, NSString *local)
{
    for (NSXMLElement *c in child_elements(n)) {
        if ([[c localName] isEqualToString:local])
            return c;
        NSXMLElement *d = descendant_named(c, local);
        if (d)
            return d;
    }
    return nil;
}

/* the defaults a Word 2007 document's styles part gives its text (docDefaults) */
static ImportStyle
word_defaults(NSData *styles)
{
    ImportStyle s = {0};
    s.size = 12;
    NSXMLDocument *doc = styles ? [[[NSXMLDocument alloc] initWithData:styles options:0 error:NULL] autorelease] : nil;
    NSXMLElement *rPr = descendant_named(descendant_named([doc rootElement], @"rPrDefault"), @"rPr");
    if (rPr)
        word_run_properties(rPr, &s);
    return s;
}

static NSAttributedString *
read_word_xml(NSData *xml, ImportStyle base)
{
    NSXMLDocument *doc = [[[NSXMLDocument alloc] initWithData:xml options:0 error:NULL] autorelease];
    NSXMLElement *body = descendant_named([doc rootElement], @"body");
    if (!body)
        return nil;
    UIFImportText *t = [[[UIFImportText alloc] init] autorelease];
    t->wholeRunMarks = YES;
    word_block(body, t, base);
    return [t result];
}

#pragma mark - OpenDocument

static void
odt_text_properties(NSXMLElement *props, ImportStyle *s)
{
    NSString *v;
    if ((v = attr(props, @"font-name") ?: attr(props, @"font-family")))
        s->family = [v stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"'\""]];
    if ((v = attr(props, @"font-size")) && [v hasSuffix:@"pt"])
        s->size = [v doubleValue];
    if ((v = attr(props, @"font-weight")))
        s->bold = [v isEqualToString:@"bold"] || [v intValue] >= 600;
    if ((v = attr(props, @"font-style")))
        s->italic = [v isEqualToString:@"italic"] || [v isEqualToString:@"oblique"];
    if ((v = attr(props, @"text-underline-style")))
        s->underline = ![v isEqualToString:@"none"];
    if ((v = attr(props, @"text-line-through-style")))
        s->strike = ![v isEqualToString:@"none"];
    if ((v = attr(props, @"color")))
        hex_color(v, s);
}

typedef struct {
    NSMutableDictionary *text, *paragraph;  /* style name: NSValue of ImportStyle / NSNumber alignment */
} ODTStyles;

static void
odt_read_styles(NSXMLElement *container, ODTStyles *st)
{
    for (NSXMLElement *e in child_elements(container)) {
        if (![[e localName] isEqualToString:@"style"])
            continue;
        NSString *name = attr(e, @"name");
        if (!name)
            continue;
        ImportStyle s = {0};
        NSXMLElement *tp = child_named(e, @"text-properties");
        if (tp) {
            odt_text_properties(tp, &s);
            st->text[name] = [NSValue valueWithBytes:&s objCType:@encode(ImportStyle)];
        }
        NSXMLElement *pp = child_named(e, @"paragraph-properties");
        NSString *a = pp ? attr(pp, @"text-align") : nil;
        if (a)
            st->paragraph[name] = @(word_alignment([a isEqualToString:@"justify"] ? @"both" : a));
    }
}

static ImportStyle
odt_merge(ImportStyle base, NSValue *v)
{
    if (!v)
        return base;
    ImportStyle s;
    [v getValue:&s];
    if (s.family)
        base.family = s.family;
    if (s.size > 0)
        base.size = s.size;
    base.bold |= s.bold, base.italic |= s.italic, base.underline |= s.underline, base.strike |= s.strike;
    if (s.hasColor)
        base.r = s.r, base.g = s.g, base.b = s.b, base.hasColor = YES;
    return base;
}

static void
odt_inline(NSXMLNode *n, UIFImportText *t, ImportStyle s, ODTStyles *st)
{
    for (NSXMLNode *c in [n children]) {
        if ([c kind] == NSXMLTextKind) {
            [t append:[c stringValue] style:s];
            continue;
        }
        if ([c kind] != NSXMLElementKind)
            continue;
        NSXMLElement *e = (NSXMLElement *)c;
        NSString *name = [e localName];
        if ([name isEqualToString:@"span"] || [name isEqualToString:@"a"])
            odt_inline(e, t, odt_merge(s, st->text[attr(e, @"style-name") ?: @""]), st);
        else if ([name isEqualToString:@"tab"])
            [t append:@"\t" style:s];
        else if ([name isEqualToString:@"line-break"])
            [t append:@" " style:s];
        else if ([name isEqualToString:@"s"])
            [t append:[@"" stringByPaddingToLength:(NSUInteger)MAX(1, [attr(e, @"c") intValue]) withString:@" " startingAtIndex:0]
                style:s];
    }
}

static void
odt_block(NSXMLElement *container, UIFImportText *t, ImportStyle base, ODTStyles *st)
{
    for (NSXMLElement *e in child_elements(container)) {
        NSString *n = [e localName];
        if ([n isEqualToString:@"p"] || [n isEqualToString:@"h"]) {
            NSString *style = attr(e, @"style-name") ?: @"";
            NSNumber *a = st->paragraph[style];
            t->alignment = a ? (NSTextAlignment)[a integerValue] : NSTextAlignmentNatural;
            ImportStyle s = odt_merge(base, st->text[style]);
            if ([n isEqualToString:@"h"] && !st->text[style])
                s.bold = YES, s.size = MAX(s.size, 16);
            odt_inline(e, t, s, st);
            [t endParagraph:s];
        } else if ([n isEqualToString:@"list"] || [n isEqualToString:@"list-item"] || [n isEqualToString:@"section"] ||
                   [n isEqualToString:@"table"] || [n isEqualToString:@"table-row"] || [n isEqualToString:@"table-cell"]) {
            odt_block(e, t, base, st);
        }
    }
}

static NSAttributedString *
read_odt(NSDictionary<NSString *, NSData *> *parts)
{
    NSXMLDocument *content = [[[NSXMLDocument alloc] initWithData:parts[@"content.xml"] options:0 error:NULL] autorelease];
    NSXMLElement *text = descendant_named(descendant_named([content rootElement], @"body"), @"text");
    if (!text)
        return nil;
    ODTStyles st = {[NSMutableDictionary dictionary], [NSMutableDictionary dictionary]};
    NSXMLDocument *styles = parts[@"styles.xml"] ? [[[NSXMLDocument alloc] initWithData:parts[@"styles.xml"] options:0
                                                                                   error:NULL] autorelease] : nil;
    for (NSXMLElement *root in @[ [styles rootElement] ?: [NSNull null], [content rootElement] ]) {
        if ((id)root == [NSNull null])
            continue;
        for (NSString *section in @[ @"styles", @"automatic-styles" ]) {
            NSXMLElement *e = child_named(root, section);
            if (e)
                odt_read_styles(e, &st);
        }
    }
    ImportStyle base = {0};
    base.size = 12;
    UIFImportText *t = [[[UIFImportText alloc] init] autorelease];
    odt_block(text, t, base, &st);
    return [t result];
}

#pragma mark - HTML

static void
css_apply(NSString *css, ImportStyle *s, NSTextAlignment *align)
{
    for (NSString *decl in [css componentsSeparatedByString:@";"]) {
        NSRange colon = [decl rangeOfString:@":"];
        if (colon.location == NSNotFound)
            continue;
        NSString *k = [[[decl substringToIndex:colon.location] stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
        NSString *v = [[decl substringFromIndex:NSMaxRange(colon)] stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([k isEqualToString:@"font"]) {
            /* [style] [weight] size[/line-height] family, as Apple's HTML writes "font: 14.0px Helvetica" */
            NSScanner *sc = [NSScanner scannerWithString:v];
            NSString *word = nil;
            while ([sc scanUpToCharactersFromSet:[NSCharacterSet whitespaceCharacterSet] intoString:&word]) {
                double n = [word doubleValue];
                if ([word isEqualToString:@"italic"] || [word isEqualToString:@"oblique"]) {
                    s->italic = YES;
                } else if ([word isEqualToString:@"bold"] || (n >= 600 && [word rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].location == NSNotFound)) {
                    s->bold = YES;
                } else if (n > 0 && [word rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].location != NSNotFound) {
                    NSString *size = [[word componentsSeparatedByString:@"/"] firstObject];
                    s->size = [size hasSuffix:@"pt"] ? [size doubleValue] * 4 / 3 : [size doubleValue];
                    NSString *rest = [[v substringFromIndex:[sc scanLocation]] stringByTrimmingCharactersInSet:
                                          [NSCharacterSet whitespaceCharacterSet]];
                    if ([rest length])
                        css_apply([@"font-family:" stringByAppendingString:rest], s, NULL);
                    break;
                }
            }
        } else if ([k isEqualToString:@"font-family"]) {
            NSString *first = [[v componentsSeparatedByString:@","] firstObject];
            s->family = [first stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"'\" "]];
        } else if ([k isEqualToString:@"font-size"]) {
            double n = [v doubleValue];
            /* points are a CSS pixel each in WebKit; pt a third more */
            s->size = [v hasSuffix:@"pt"] ? n * 4 / 3 : [v hasSuffix:@"em"] ? n * (s->size > 0 ? s->size : 12) : n;
        } else if ([k isEqualToString:@"font-weight"]) {
            s->bold = [v isEqualToString:@"bold"] || [v intValue] >= 600;
        } else if ([k isEqualToString:@"font-style"]) {
            s->italic = [v isEqualToString:@"italic"] || [v isEqualToString:@"oblique"];
        } else if ([k isEqualToString:@"text-decoration"] || [k isEqualToString:@"text-decoration-line"]) {
            s->underline = [v rangeOfString:@"underline"].location != NSNotFound;
            s->strike = [v rangeOfString:@"line-through"].location != NSNotFound;
        } else if ([k isEqualToString:@"color"]) {
            hex_color(v, s);
        } else if ([k isEqualToString:@"text-align"] && align) {
            *align = [v isEqualToString:@"center"] ? NSTextAlignmentCenter
                   : [v isEqualToString:@"right"] ? NSTextAlignmentRight
                   : [v isEqualToString:@"justify"] ? NSTextAlignmentJustified : NSTextAlignmentLeft;
        }
    }
}

static BOOL
html_block_element(NSString *n)
{
    static NSSet *blocks;
    if (!blocks)
        blocks = [[NSSet alloc] initWithObjects:@"p", @"div", @"h1", @"h2", @"h3", @"h4", @"h5", @"h6", @"li", @"blockquote",
                                                @"pre", @"tr", @"dt", @"dd", @"address", @"center", nil];
    return [blocks containsObject:n];
}

/* The rules of a document's style sheets: selector ("p", ".p1", "p.p1") to declarations. */
static NSDictionary<NSString *, NSString *> *
html_style_sheet(NSXMLElement *root)
{
    NSMutableDictionary *rules = [NSMutableDictionary dictionary];
    NSArray *styles = [root nodesForXPath:@"//style" error:NULL];
    for (NSXMLNode *style in styles) {
        NSString *css = [style stringValue];
        NSScanner *sc = [NSScanner scannerWithString:css];
        while (![sc isAtEnd]) {
            NSString *selectors = nil, *decls = nil;
            if (![sc scanUpToString:@"{" intoString:&selectors] || ![sc scanString:@"{" intoString:NULL])
                break;
            [sc scanUpToString:@"}" intoString:&decls];
            [sc scanString:@"}" intoString:NULL];
            for (NSString *sel in [selectors componentsSeparatedByString:@","]) {
                NSString *key = [[sel stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
                    lowercaseString];
                if ([key length])
                    rules[key] = rules[key] ? [rules[key] stringByAppendingFormat:@";%@", decls ?: @""] : (decls ?: @"");
            }
        }
    }
    return rules;
}

static void
html_walk(NSXMLNode *node, UIFImportText *t, ImportStyle s, BOOL pre, NSDictionary *sheet)
{
    for (NSXMLNode *c in [node children]) {
        if ([c kind] == NSXMLTextKind) {
            NSString *text = [c stringValue];
            if (!pre) {
                /* runs of white space as one space, as HTML lays them out */
                NSArray *words = [text componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                NSString *joined = [[words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]]
                    componentsJoinedByString:@" "];
                if ([text length] && [[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:[text characterAtIndex:0]] &&
                    [t->out length] > t->paragraphStart && ![[t->out string] hasSuffix:@" "])
                    joined = [@" " stringByAppendingString:joined];
                if ([text length] && [joined length] &&
                    [[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:[text characterAtIndex:[text length] - 1]])
                    joined = [joined stringByAppendingString:@" "];
                text = joined;
            }
            [t append:text style:s];
            continue;
        }
        if ([c kind] != NSXMLElementKind)
            continue;
        NSXMLElement *e = (NSXMLElement *)c;
        NSString *n = [[e localName] lowercaseString];
        if ([n isEqualToString:@"head"] || [n isEqualToString:@"script"] || [n isEqualToString:@"style"] ||
            [n isEqualToString:@"title"])
            continue;
        if ([n isEqualToString:@"br"]) {
            [t append:@" " style:s];
            continue;
        }
        ImportStyle inner = s;
        NSTextAlignment align = t->alignment;
        if ([n isEqualToString:@"b"] || [n isEqualToString:@"strong"] || [n isEqualToString:@"th"])
            inner.bold = YES;
        else if ([n isEqualToString:@"i"] || [n isEqualToString:@"em"] || [n isEqualToString:@"cite"])
            inner.italic = YES;
        else if ([n isEqualToString:@"u"] || [n isEqualToString:@"ins"])
            inner.underline = YES;
        else if ([n isEqualToString:@"s"] || [n isEqualToString:@"strike"] || [n isEqualToString:@"del"])
            inner.strike = YES;
        else if ([n length] == 2 && [n characterAtIndex:0] == 'h' && [n characterAtIndex:1] >= '1' && [n characterAtIndex:1] <= '6') {
            static const CGFloat sizes[] = {24, 18, 14, 12, 10, 8};
            inner.bold = YES;
            inner.size = sizes[[n characterAtIndex:1] - '1'];
        } else if ([n isEqualToString:@"font"]) {
            NSString *face = attr(e, @"face"), *color = attr(e, @"color");
            if (face)
                inner.family = [[face componentsSeparatedByString:@","] firstObject];
            if (color)
                hex_color(color, &inner);
        } else if ([n isEqualToString:@"center"]) {
            align = NSTextAlignmentCenter;
        }
        /* the style sheet's rules for its tag, then its classes */
        NSString *rule = sheet[n];
        if (rule)
            css_apply(rule, &inner, &align);
        for (NSString *cls in [[attr(e, @"class") lowercaseString] componentsSeparatedByString:@" "]) {
            if (![cls length])
                continue;
            if ((rule = sheet[[@"." stringByAppendingString:cls]]))
                css_apply(rule, &inner, &align);
            if ((rule = sheet[[NSString stringWithFormat:@"%@.%@", n, cls]]))
                css_apply(rule, &inner, &align);
        }
        NSString *alignAttr = attr(e, @"align");
        if (alignAttr)
            css_apply([@"text-align:" stringByAppendingString:alignAttr], &inner, &align);
        NSString *style = attr(e, @"style");
        if (style)
            css_apply(style, &inner, &align);
        BOOL block = html_block_element(n);
        if (block && [t->out length] > t->paragraphStart)
            [t endParagraph:s];
        if (block)
            t->alignment = align;
        if ([n isEqualToString:@"li"])
            [t append:@"•\t" style:inner];
        html_walk(e, t, inner, pre || [n isEqualToString:@"pre"], sheet);
        if (block && [t->out length] >= t->paragraphStart)
            [t endParagraph:inner];
    }
}

static NSAttributedString *
read_html(NSData *data)
{
    NSXMLDocument *doc = [[[NSXMLDocument alloc] initWithData:data options:NSXMLDocumentTidyHTML error:NULL] autorelease];
    if (!doc)
        return nil;
    NSXMLElement *body = descendant_named([doc rootElement], @"body") ?: [doc rootElement];
    ImportStyle base = {0};
    base.size = 12;
    base.family = @"Times";
    NSDictionary *sheet = html_style_sheet([doc rootElement]);
    if (sheet[@"body"])
        css_apply(sheet[@"body"], &base, NULL);
    UIFImportText *t = [[[UIFImportText alloc] init] autorelease];
    html_walk(body, t, base, NO, sheet);
    return [t result];
}

#pragma mark - Entry

static NSString *
sniff(NSData *data)
{
    const char *p = [data bytes];
    NSUInteger n = [data length];
    if (n >= 4 && !memcmp(p, "PK\3\4", 4)) {
        NSDictionary *parts = zip_entries(data);
        if (parts[@"word/document.xml"])
            return @"NSOfficeOpenXML";
        NSString *mime = [[[NSString alloc] initWithData:parts[@"mimetype"] ?: [NSData data] encoding:NSUTF8StringEncoding] autorelease];
        if ([mime hasPrefix:@"application/vnd.oasis.opendocument.text"])
            return @"NSOpenDocument";
        return nil;
    }
    if (n >= 8 && !memcmp(p, "bplist00", 8)) {
        id plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
        return [plist isKindOfClass:[NSDictionary class]] && plist[@"WebMainResource"] ? @"NSWebArchive" : nil;
    }
    NSString *head = [[[NSString alloc] initWithBytes:p length:MIN(n, (NSUInteger)1024) encoding:NSUTF8StringEncoding]
        autorelease] ?: [[[NSString alloc] initWithBytes:p length:MIN(n, (NSUInteger)1024) encoding:NSISOLatin1StringEncoding] autorelease];
    NSString *lower = [head lowercaseString];
    if ([lower rangeOfString:@"<w:worddocument"].location != NSNotFound)
        return @"NSWordML";
    if ([lower rangeOfString:@"<html"].location != NSNotFound || [lower rangeOfString:@"<!doctype html"].location != NSNotFound)
        return @"NSHTML";
    return nil;
}

/* The type of a document Finch reads here, or nil (RTF and plain text are another file's). */
UIF_HIDDEN NSString *
FinchImportSniff(NSData *data)
{
    return data ? sniff(data) : nil;
}

/* A document of one of these types read, or nil. */
UIF_HIDDEN NSAttributedString *
FinchImportAttributedString(NSData *data, NSString *type, NSDictionary *options, NSDictionary **docAttrs)
{
    NSAttributedString *s = nil;
    NSString *uti = nil;
    if ([type isEqualToString:@"NSHTML"]) {
        s = read_html(data), uti = @"public.html";
    } else if ([type isEqualToString:@"NSWebArchive"]) {
        id plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
        NSData *html = plist[@"WebMainResource"][@"WebResourceData"];
        s = [html isKindOfClass:[NSData class]] ? read_html(html) : nil, uti = @"com.apple.webarchive";
    } else if ([type isEqualToString:@"NSWordML"]) {
        ImportStyle base = {0};
        base.size = 12;
        s = read_word_xml(data, base), uti = @"com.microsoft.word.wordml";
    } else if ([type isEqualToString:@"NSOfficeOpenXML"]) {
        NSDictionary *parts = zip_entries(data);
        if (parts[@"word/document.xml"])
            s = read_word_xml(parts[@"word/document.xml"], word_defaults(parts[@"word/styles.xml"]));
        uti = @"org.openxmlformats.wordprocessingml.document";
    } else if ([type isEqualToString:@"NSOpenDocument"]) {
        s = read_odt(zip_entries(data)), uti = @"org.oasis-open.opendocument.text";
    }
    if (s && docAttrs)
        *docAttrs = @{NSDocumentTypeDocumentAttribute : type, @"UTI" : uti,
                      NSPaperSizeDocumentAttribute : [NSValue valueWithSize:NSMakeSize(612, 792)]};
    return s;
}
