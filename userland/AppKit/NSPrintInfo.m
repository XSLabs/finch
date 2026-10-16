/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Printing: NSPrintInfo (a job's settings, with macOS's defaults: US
 * Letter, 72/72/90/90-point margins), NSPrinter, NSPrintOperation,
 * NSPrintPanel and NSPageLayout.
 *
 * Finch has no printing system yet. A print operation whose job
 * disposition is NSPrintSaveJob draws its view, page by page, into a PDF
 * with CoreGraphics' PDF context; spooling to a printer and previewing
 * report that there is no printer. NSView's PDF methods use the same path.
 */
#import "NSView_Finch.h"
#include <math.h>

#pragma mark - NSPrinter

@implementation NSPrinter {
    NSString *_name, *_type;
}

+ (NSArray<NSString *> *)printerNames { return @[]; }
+ (NSArray<NSString *> *)printerTypes { return @[]; }
+ (NSPrinter *)printerWithName:(NSString *)name { return nil; }
+ (NSPrinter *)printerWithType:(NSPrinterTypeName)type { return nil; }
+ (NSPrinter *)printerWithName:(NSString *)name domain:(NSString *)domain includeUnavailable:(BOOL)flag { return nil; }

- (NSString *)name { return _name ?: @""; }
- (NSPrinterTypeName)type { return _type ?: @""; }
- (NSInteger)languageLevel { return 0; }
- (NSSize)pageSizeForPaper:(NSPrinterPaperName)paperName { return NSZeroSize; }
- (NSDictionary<NSDeviceDescriptionKey, id> *)deviceDescription { return @{NSDeviceIsPrinter : @"YES"}; }
- (NSPrinterTableStatus)statusForTable:(NSString *)tableName { return NSPrinterTableNotFound; }
- (BOOL)isKey:(NSString *)key inTable:(NSString *)table { return NO; }
- (BOOL)booleanForKey:(NSString *)key inTable:(NSString *)table { return NO; }
- (float)floatForKey:(NSString *)key inTable:(NSString *)table { return 0; }
- (int)intForKey:(NSString *)key inTable:(NSString *)table { return 0; }
- (NSRect)rectForKey:(NSString *)key inTable:(NSString *)table { return NSZeroRect; }
- (NSSize)sizeForKey:(NSString *)key inTable:(NSString *)table { return NSZeroSize; }
- (NSString *)stringForKey:(NSString *)key inTable:(NSString *)table { return nil; }
- (NSArray *)stringListForKey:(NSString *)key inTable:(NSString *)table { return nil; }
- (NSRect)imageRectForPaper:(NSString *)paperName { return NSZeroRect; }
- (BOOL)acceptsBinary { return YES; }
- (BOOL)isColor { return NO; }
- (BOOL)isFontAvailable:(NSString *)faceName { return NO; }
- (BOOL)isOutputStackInReverseOrder { return NO; }
- (NSString *)domain { return @""; }
- (NSString *)host { return @""; }
- (NSString *)note { return @""; }

- (void)dealloc
{
    [_name release];
    [_type release];
    [super dealloc];
}

@end

#pragma mark - NSPrintInfo

@implementation NSPrintInfo {
    NSMutableDictionary *_dict;
}

static NSPrintInfo *shared_info;

static NSMutableDictionary *
defaults(void)
{
    return [NSMutableDictionary dictionaryWithDictionary:@{
        NSPrintBottomMargin : @90, NSPrintTopMargin : @90, NSPrintLeftMargin : @72, NSPrintRightMargin : @72,
        NSPrintCopies : @1, NSPrintDetailedErrorReporting : @NO, NSPrintFaxNumber : @"", NSPrintFirstPage : @1,
        NSPrintLastPage : @INT32_MAX, NSPrintHorizontalPagination : @(NSPrintingPaginationModeClip),
        NSPrintVerticalPagination : @(NSPrintingPaginationModeAutomatic), NSPrintHorizontallyCentered : @YES,
        NSPrintVerticallyCentered : @YES, NSPrintJobDisposition : NSPrintSpoolJob, NSPrintMustCollate : @YES,
        NSPrintOrientation : @(NSPaperOrientationPortrait), NSPrintPagesAcross : @1, NSPrintPagesDown : @1,
        NSPrintPaperName : @"na-letter", NSPrintPaperSize : [NSValue valueWithSize:NSMakeSize(612, 792)],
        NSPrintAllPages : @YES, NSPrintSelectionOnly : @NO, NSPrintScalingFactor : @1.0, NSPrintSavePath : @"",
    }];
}

+ (NSPrintInfo *)sharedPrintInfo
{
    if (!shared_info)
        shared_info = [[NSPrintInfo alloc] init];
    return shared_info;
}

+ (void)setSharedPrintInfo:(NSPrintInfo *)info
{
    [info retain];
    [shared_info release];
    shared_info = info;
}

+ (NSPrinter *)defaultPrinter { return nil; }
+ (NSString *)defaultPrinterName { return nil; }

/* Apple's deprecated setter has no effect; Finch has no system printer list to change. */
+ (void)setDefaultPrinter:(NSPrinter *)printer {}

+ (NSSize)sizeForPaperName:(NSPrinterPaperName)name
{
    return NSZeroSize;
}

- (instancetype)init
{
    return [self initWithDictionary:@{}];
}

- (instancetype)initWithDictionary:(NSDictionary<NSPrintInfoAttributeKey, id> *)attributes
{
    self = [super init];
    if (self) {
        _dict = [defaults() retain];
        [_dict addEntriesFromDictionary:attributes];
    }
    return self;
}

+ (void)initialize
{
    if (self == [NSPrintInfo class])
        [self setVersion:1];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSDictionary *d = [coder allowsKeyedCoding] ? [coder decodeObjectForKey:@"NSAttributes"] : [coder decodeObject];
    return [self initWithDictionary:[d isKindOfClass:[NSDictionary class]] ? d : @{}];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    if ([coder allowsKeyedCoding]) {
        [coder encodeObject:_dict forKey:@"NSAttributes"];
        return;
    }
    /* a typedstream: the attributes, less the printer and the job settings still at their
       defaults, as Apple's */
    static NSSet *skipped;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        skipped = [[NSSet alloc] initWithObjects:NSPrintPrinter, NSPrintPrinterName, NSPrintPaperName, NSPrintFirstPage,
                                                 NSPrintLastPage, NSPrintMustCollate, NSPrintAllPages, NSPrintDetailedErrorReporting,
                                                 NSPrintFaxNumber, NSPrintTime, NSPrintSavePath, @"NSDestinationFormat",
                                                 NSPrintPagesAcross, NSPrintPagesDown, @"NSPrintProtected", NSPrintSelectionOnly,
                                                 NSPrintJobSavingFileNameExtensionHidden, nil];
    });
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    NSDictionary *standard = defaults();
    [_dict enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
        if ([k isEqual:NSPrintPrinter] || ([skipped containsObject:k] && [standard[k] isEqual:v]))
            return;
        if ([v conformsToProtocol:@protocol(NSCoding)])
            d[k] = v;
    }];
    [coder encodeObject:d];
}

- (id)copyWithZone:(NSZone *)zone
{
    return [[NSPrintInfo alloc] initWithDictionary:_dict];
}

- (void)dealloc
{
    [_dict release];
    [super dealloc];
}

- (NSMutableDictionary<NSPrintInfoAttributeKey, id> *)dictionary { return _dict; }

static CGFloat num(NSPrintInfo *p, NSString *k) { return [p->_dict[k] doubleValue]; }

- (NSPrinterPaperName)paperName { return _dict[NSPrintPaperName]; }
- (void)setPaperName:(NSPrinterPaperName)name
{
    /* Without a printer list, keep the only paper Finch can name: the default letter sheet. */
    if ([name isEqualToString:@"na-letter"])
        _dict[NSPrintPaperName] = name;
}
- (NSSize)paperSize { return [_dict[NSPrintPaperSize] sizeValue]; }
- (void)setPaperSize:(NSSize)size
{
    _dict[NSPrintPaperSize] = [NSValue valueWithSize:size];
    BOOL letter = (size.width == 612 && size.height == 792) || (size.width == 792 && size.height == 612);
    _dict[NSPrintPaperName] = letter ? @"na-letter" : @"custom";
}
- (NSPaperOrientation)orientation { return [_dict[NSPrintOrientation] integerValue]; }

/* As Apple's: the paper size swaps when the orientation does. */
- (void)setOrientation:(NSPaperOrientation)orientation
{
    if (orientation == [self orientation])
        return;
    _dict[NSPrintOrientation] = @(orientation);
    NSSize s = [self paperSize];
    BOOL wide = s.width > s.height;
    if ((orientation == NSPaperOrientationLandscape) != wide)
        [self setPaperSize:NSMakeSize(s.height, s.width)];
}

- (CGFloat)leftMargin { return num(self, NSPrintLeftMargin); }
- (void)setLeftMargin:(CGFloat)v { _dict[NSPrintLeftMargin] = @(v); }
- (CGFloat)rightMargin { return num(self, NSPrintRightMargin); }
- (void)setRightMargin:(CGFloat)v { _dict[NSPrintRightMargin] = @(v); }
- (CGFloat)topMargin { return num(self, NSPrintTopMargin); }
- (void)setTopMargin:(CGFloat)v { _dict[NSPrintTopMargin] = @(v); }
- (CGFloat)bottomMargin { return num(self, NSPrintBottomMargin); }
- (void)setBottomMargin:(CGFloat)v { _dict[NSPrintBottomMargin] = @(v); }
- (CGFloat)scalingFactor { return num(self, NSPrintScalingFactor); }
- (void)setScalingFactor:(CGFloat)v
{
    if (v > 0 && isfinite(v))
        _dict[NSPrintScalingFactor] = @(v);
}
- (NSPrintingPaginationMode)horizontalPagination { return [_dict[NSPrintHorizontalPagination] integerValue]; }
- (void)setHorizontalPagination:(NSPrintingPaginationMode)m { _dict[NSPrintHorizontalPagination] = @(m); }
- (NSPrintingPaginationMode)verticalPagination { return [_dict[NSPrintVerticalPagination] integerValue]; }
- (void)setVerticalPagination:(NSPrintingPaginationMode)m { _dict[NSPrintVerticalPagination] = @(m); }
- (BOOL)isHorizontallyCentered { return [_dict[NSPrintHorizontallyCentered] boolValue]; }
- (void)setHorizontallyCentered:(BOOL)f { _dict[NSPrintHorizontallyCentered] = @(f); }
- (BOOL)isVerticallyCentered { return [_dict[NSPrintVerticallyCentered] boolValue]; }
- (void)setVerticallyCentered:(BOOL)f { _dict[NSPrintVerticallyCentered] = @(f); }
- (NSPrintJobDispositionValue)jobDisposition { return _dict[NSPrintJobDisposition]; }
- (void)setJobDisposition:(NSPrintJobDispositionValue)d { _dict[NSPrintJobDisposition] = d ?: NSPrintSpoolJob; }
- (BOOL)isSelectionOnly { return [_dict[NSPrintSelectionOnly] boolValue]; }
- (void)setSelectionOnly:(BOOL)f { _dict[NSPrintSelectionOnly] = @(f); }
- (NSPrinter *)printer { return nil; }
- (void)setPrinter:(NSPrinter *)printer {}
- (void *)PMPrintSession { return NULL; }
- (void *)PMPageFormat { return NULL; }
- (void *)PMPrintSettings { return NULL; }
- (void)updateFromPMPageFormat {}
- (void)updateFromPMPrintSettings {}
- (void)setUpPrintOperationDefaultValues {}
- (NSMutableDictionary<NSPrintInfoSettingKey, id> *)printSettings { return [NSMutableDictionary dictionary]; }
- (NSString *)localizedPaperName { return @"US Letter"; }
+ (NSString *)localizedPaperNameForPaperName:(NSPrinterPaperName)name { return name; }
- (BOOL)takesPDFFormat { return YES; }
- (NSPDFPanel *)PDFPanel { return nil; }

- (void)takeSettingsFromPDFInfo:(NSPDFInfo *)info
{
    if (!info)
        return;
    NSURL *url = info.URL;
    BOOL isDirectory = NO;
    if (url.isFileURL && [[NSFileManager defaultManager] fileExistsAtPath:url.path isDirectory:&isDirectory] && isDirectory)
        [NSException raise:NSInvalidArgumentException format:@"The PDF destination must be a file, not a directory."];
    [_dict addEntriesFromDictionary:info.attributes];
}

/* As Apple's with no printer: the paper less a small device margin. */
- (NSRect)imageablePageBounds
{
    NSSize s = [self paperSize];
    return NSMakeRect(18, 40, s.width - 36, s.height - 58);
}

@end

#pragma mark - NSPrintOperation

static NSPrintOperation *current_operation;

@implementation NSPrintOperation {
    NSView *_view;
    NSPrintInfo *_info;
    NSMutableData *_pdfData;
    NSString *_path;
    NSPrintPanel *_panel;
    NSString *_jobTitle;
    BOOL _showsPrintPanel, _showsProgressPanel, _pdfOnly;
    NSRect _insideRect;
    NSInteger _currentPage;
    NSPrintRenderingQuality _quality;
    NSPrintingPageOrder _pageOrder;
}

+ (NSPrintOperation *)printOperationWithView:(NSView *)view printInfo:(NSPrintInfo *)info
{
    NSPrintOperation *o = [[[self alloc] init] autorelease];
    o->_view = [view retain];
    o->_info = [info copy];
    o->_insideRect = [view bounds];
    o->_showsPrintPanel = YES;
    o->_showsProgressPanel = YES;
    return o;
}

+ (NSPrintOperation *)printOperationWithView:(NSView *)view
{
    return [self printOperationWithView:view printInfo:[NSPrintInfo sharedPrintInfo]];
}

+ (NSPrintOperation *)PDFOperationWithView:(NSView *)view insideRect:(NSRect)rect toData:(NSMutableData *)data
                                 printInfo:(NSPrintInfo *)info
{
    NSPrintOperation *o = [self printOperationWithView:view printInfo:info];
    o->_insideRect = rect;
    o->_pdfData = [data retain];
    o->_pdfOnly = YES;
    o->_showsPrintPanel = NO;
    o->_showsProgressPanel = NO;
    return o;
}

+ (NSPrintOperation *)PDFOperationWithView:(NSView *)view insideRect:(NSRect)rect toData:(NSMutableData *)data
{
    return [self PDFOperationWithView:view insideRect:rect toData:data printInfo:[NSPrintInfo sharedPrintInfo]];
}

+ (NSPrintOperation *)PDFOperationWithView:(NSView *)view insideRect:(NSRect)rect toPath:(NSString *)path
                                 printInfo:(NSPrintInfo *)info
{
    NSPrintOperation *o = [self PDFOperationWithView:view insideRect:rect toData:[NSMutableData data] printInfo:info];
    o->_path = [path copy];
    return o;
}

+ (NSPrintOperation *)EPSOperationWithView:(NSView *)view insideRect:(NSRect)rect toData:(NSMutableData *)data
                                 printInfo:(NSPrintInfo *)info
{
    return [self PDFOperationWithView:view insideRect:rect toData:data printInfo:info];
}

+ (NSPrintOperation *)EPSOperationWithView:(NSView *)view insideRect:(NSRect)rect toData:(NSMutableData *)data
{
    return [self PDFOperationWithView:view insideRect:rect toData:data];
}

+ (NSPrintOperation *)EPSOperationWithView:(NSView *)view insideRect:(NSRect)rect toPath:(NSString *)path
                                 printInfo:(NSPrintInfo *)info
{
    return [self PDFOperationWithView:view insideRect:rect toPath:path printInfo:info];
}

+ (NSPrintOperation *)currentOperation { return current_operation; }
+ (void)setCurrentOperation:(NSPrintOperation *)operation { current_operation = operation; }

- (void)dealloc
{
    [_view release];
    [_info release];
    [_pdfData release];
    [_path release];
    [_panel release];
    [_jobTitle release];
    [super dealloc];
}

- (NSView *)view { return _view; }
- (NSPrintInfo *)printInfo { return _info; }
- (void)setPrintInfo:(NSPrintInfo *)info { [_info autorelease]; _info = [info copy]; }
- (BOOL)isCopyingOperation { return _pdfOnly; }
- (BOOL)showsPrintPanel { return _showsPrintPanel; }
- (void)setShowsPrintPanel:(BOOL)f { _showsPrintPanel = f; }
- (BOOL)showsProgressPanel { return _showsProgressPanel; }
- (void)setShowsProgressPanel:(BOOL)f { _showsProgressPanel = f; }
- (NSString *)jobTitle { return _jobTitle; }
- (void)setJobTitle:(NSString *)t { [_jobTitle autorelease]; _jobTitle = [t copy]; }
- (NSPrintPanel *)printPanel { return _panel ?: (_panel = [[NSPrintPanel alloc] init]); }
- (void)setPrintPanel:(NSPrintPanel *)p { [_panel autorelease]; _panel = [p retain]; }
- (NSView *)accessoryView { return self.printPanel.accessoryView; }
- (void)setAccessoryView:(NSView *)view { self.printPanel.accessoryView = view; }
- (NSString *)jobStyleHint { return self.printPanel.jobStyleHint; }
- (void)setJobStyleHint:(NSString *)hint { self.printPanel.jobStyleHint = hint; }
- (BOOL)showPanels { return _showsPrintPanel && _showsProgressPanel; }
- (void)setShowPanels:(BOOL)flag { _showsPrintPanel = flag; _showsProgressPanel = flag; }
- (NSPDFPanel *)PDFPanel { return nil; }
- (void)setPDFPanel:(NSPDFPanel *)p {}
- (BOOL)canSpawnSeparateThread { return NO; }
- (void)setCanSpawnSeparateThread:(BOOL)f {}
- (NSPrintingPageOrder)pageOrder { return _pageOrder; }
- (void)setPageOrder:(NSPrintingPageOrder)o { _pageOrder = o; }
- (NSPrintRenderingQuality)preferredRenderingQuality { return _quality; }
- (NSInteger)currentPage { return _currentPage; }
- (NSRange)pageRange { return NSMakeRange(1, NSIntegerMax); }
- (NSGraphicsContext *)context { return [NSGraphicsContext currentContext]; }
- (NSGraphicsContext *)createContext { return [NSGraphicsContext currentContext]; }
- (void)destroyContext {}
- (BOOL)deliverResult { return YES; }
- (void)cleanUpOperation {}

/* The view's pages: its own (knowsPageRange:/rectForPage:), or its rect cut into page-high strips. */
static NSArray<NSValue *> *
pages(NSPrintOperation *op)
{
    NSMutableArray *rects = [NSMutableArray array];
    NSView *v = op->_view;
    NSRange range;
    if ([v knowsPageRange:&range]) {
        for (NSUInteger i = range.location; i < NSMaxRange(range) && i - range.location < 10000; i++)
            [rects addObject:[NSValue valueWithRect:[v rectForPage:(NSInteger)i]]];
        return rects;
    }
    NSPrintInfo *p = op->_info;
    /* as Apple's: the view as it is now, after knowsPageRange: (a print view, TextEdit's, sizes
       itself to the page there), unless a PDF of a given rect is asked for */
    NSRect r = op->_pdfOnly ? op->_insideRect : [v bounds];
    CGFloat pageHeight = [p paperSize].height - [p topMargin] - [p bottomMargin];
    if (op->_pdfOnly || pageHeight <= 0 || r.size.height <= pageHeight) {
        [rects addObject:[NSValue valueWithRect:r]];
        return rects;
    }
    for (CGFloat y = 0; y < r.size.height; y += pageHeight) {
        CGFloat top = [v isFlipped] ? NSMinY(r) + y : NSMaxY(r) - y - pageHeight;
        [rects addObject:[NSValue valueWithRect:NSMakeRect(NSMinX(r), MAX(top, NSMinY(r)), r.size.width,
                                                          MIN(pageHeight, r.size.height - y))]];
    }
    return rects;
}

static BOOL
write_pdf(NSPrintOperation *op, NSURL *url, NSMutableData *data)
{
    NSArray *rects = pages(op);
    NSPrintInfo *p = op->_info;
    CGRect media = op->_pdfOnly ? NSRectToCGRect(NSMakeRect(0, 0, op->_insideRect.size.width, op->_insideRect.size.height))
                                : CGRectMake(0, 0, [p paperSize].width, [p paperSize].height);
    CGDataConsumerRef consumer = url ? CGDataConsumerCreateWithURL((CFURLRef)url)
                                     : CGDataConsumerCreateWithCFData((CFMutableDataRef)data);
    if (!consumer)
        return NO;
    CGContextRef pdf = CGPDFContextCreate(consumer, &media, NULL);
    CGDataConsumerRelease(consumer);
    if (!pdf)
        return NO;
    NSPrintOperation *saved = current_operation;
    current_operation = op;
    /* FINCH_TRACE_PRINT=1: what's printed, and on which pages */
    if (getenv("FINCH_TRACE_PRINT")) {
        NSView *v = op->_view;
        fprintf(stderr, "print: %s %s, %lu page(s) %s\n", class_getName([v class]), NSStringFromRect([v frame]).UTF8String,
                (unsigned long)[rects count], [[[rects componentsJoinedByString:@" "] stringByReplacingOccurrencesOfString:@"\n" withString:@" "] UTF8String]);
        if ([v isKindOfClass:[NSTextView class]])
            fprintf(stderr, "print: text length %lu, layout %s, subviews %lu\n", (unsigned long)[[(NSTextView *)v string] length],
                    [(NSTextView *)v textLayoutManager] ? "TextKit 2" : "TextKit 1", (unsigned long)[[v subviews] count]);
        for (NSView *sub in [v subviews])
            fprintf(stderr, "print:   subview %s %s\n", class_getName([sub class]), NSStringFromRect([sub frame]).UTF8String);
    }
    extern void FinchGraphicsSetPrintingContext(CGContextRef cg);
    FinchGraphicsSetPrintingContext(pdf);
    [op->_view beginDocument];
    NSInteger page = 1;
    for (NSValue *value in rects) {
        NSRect r = [value rectValue];
        op->_currentPage = page++;
        CGPDFContextBeginPage(pdf, NULL);
        CGContextSaveGState(pdf);
        if (!op->_pdfOnly) {
            CGFloat x = [p leftMargin], y = [p bottomMargin];
            CGFloat areaW = media.size.width - [p leftMargin] - [p rightMargin];
            CGFloat areaH = media.size.height - [p topMargin] - [p bottomMargin];
            if ([p isHorizontallyCentered])
                x += MAX(0, (areaW - r.size.width) / 2);
            if ([p isVerticallyCentered])
                y += MAX(0, (areaH - r.size.height) / 2);
            else
                y += areaH - MIN(areaH, r.size.height);
            /* as Apple's: fit pagination scales a view wider (or taller) than the page down to it */
            CGFloat scale = [p scalingFactor];
            if ([p horizontalPagination] == NSPrintingPaginationModeFit && r.size.width * scale > areaW && r.size.width > 0)
                scale = areaW / r.size.width;
            if ([p verticalPagination] == NSPrintingPaginationModeFit && r.size.height * scale > areaH && r.size.height > 0)
                scale = MIN(scale, areaH / r.size.height);
            if (scale != [p scalingFactor] && ![p isVerticallyCentered])
                y = [p bottomMargin] + areaH - MIN(areaH, r.size.height * scale);
            CGContextTranslateCTM(pdf, x, y);
            CGContextScaleCTM(pdf, scale, scale);
        }
        if ([op->_view isFlipped])
            CGContextConcatCTM(pdf, CGAffineTransformMake(1, 0, 0, -1, -NSMinX(r), NSMaxY(r)));
        else
            CGContextTranslateCTM(pdf, -NSMinX(r), -NSMinY(r));
        [op->_view beginPageInRect:r atPlacement:NSZeroPoint];
        FinchViewDrawTree(op->_view, pdf, r, YES);
        [op->_view endPage];
        CGContextRestoreGState(pdf);
        CGPDFContextEndPage(pdf);
    }
    [op->_view endDocument];
    FinchGraphicsSetPrintingContext(NULL);
    current_operation = saved;
    CGPDFContextClose(pdf);
    CGContextRelease(pdf);
    return YES;
}

- (BOOL)runOperation
{
    if (_pdfOnly)
        return write_pdf(self, _path ? [NSURL fileURLWithPath:_path] : nil, _pdfData);
    if ([[_info jobDisposition] isEqualToString:NSPrintSaveJob]) {
        NSURL *url = [_info dictionary][NSPrintJobSavingURL];
        if (!url && [[_info dictionary][NSPrintSavePath] length])
            url = [NSURL fileURLWithPath:[_info dictionary][NSPrintSavePath]];
        return url && write_pdf(self, url, nil);
    }
    NSString *title = _jobTitle ?: [[_view window] title] ?: @"";
    if (_showsPrintPanel && NSApp)
        return [self _finchSaveAsPDFTitled:title];
    NSLog(@"Finch: no printer to print \"%@\" on", title);
    return NO;
}

/* The print panel, for now: there are no printers, so, as the PDF menu of Apple's offers, the
   job can be saved as a PDF, named after the document, where a save panel says. */
- (BOOL)_finchSaveAsPDFTitled:(NSString *)title
{
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    [alert setMessageText:[NSString stringWithFormat:@"Print “%@”", title]];
    [alert setInformativeText:@"No printer is set up. The document can be saved as a PDF."];
    [alert addButtonWithTitle:@"Save as PDF…"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn)
        return NO;
    NSSavePanel *save = [NSSavePanel savePanel];
    NSString *base = [[title stringByDeletingPathExtension] length] ? [title stringByDeletingPathExtension] : @"Untitled";
    [save setNameFieldStringValue:[base stringByAppendingPathExtension:@"pdf"]];
    if ([save runModal] != NSModalResponseOK || ![save URL])
        return NO;
    return write_pdf(self, [save URL], nil);
}

- (void)runOperationModalForWindow:(NSWindow *)docWindow delegate:(id)delegate
                    didRunSelector:(SEL)didRunSelector contextInfo:(void *)contextInfo
{
    BOOL ok = [self runOperation];
    if (delegate && didRunSelector)
        ((void (*)(id, SEL, id, BOOL, void *))objc_msgSend)(delegate, didRunSelector, self, ok, contextInfo);
}

@end

#pragma mark - Panels

@implementation NSPrintPanel {
    NSPrintPanelOptions _options;
    NSString *_helpAnchor, *_jobStyleHint, *_defaultButtonTitle;
    NSPrintInfo *_printInfo;
    NSMutableArray *_accessories;
}

+ (NSPrintPanel *)printPanel { return [[[self alloc] init] autorelease]; }
- (NSPrintPanelOptions)options { return _options; }
- (void)setOptions:(NSPrintPanelOptions)o { _options = o; }
- (NSString *)helpAnchor { return _helpAnchor; }
- (void)setHelpAnchor:(NSString *)a { [_helpAnchor autorelease]; _helpAnchor = [a copy]; }
- (NSString *)defaultButtonTitle { return _defaultButtonTitle; }
- (void)setDefaultButtonTitle:(NSString *)title { [_defaultButtonTitle autorelease]; _defaultButtonTitle = [title copy]; }
- (NSPrintPanelJobStyleHint)jobStyleHint { return _jobStyleHint; }
- (void)setJobStyleHint:(NSPrintPanelJobStyleHint)h { [_jobStyleHint autorelease]; _jobStyleHint = [h copy]; }
- (NSArray *)accessoryControllers { return _accessories ? [[_accessories copy] autorelease] : @[]; }
- (NSView *)accessoryView { return [(NSViewController *)_accessories.firstObject view]; }
- (void)setAccessoryView:(NSView *)view
{
    [_accessories release];
    _accessories = nil;
    if (view) {
        NSViewController *controller = [[NSViewController alloc] init];
        controller.view = view;
        _accessories = [[NSMutableArray alloc] initWithObjects:controller, nil];
        [controller release];
    }
}
- (void)addAccessoryController:(NSViewController<NSPrintPanelAccessorizing> *)c
{
    if (!_accessories)
        _accessories = [[NSMutableArray alloc] init];
    [_accessories addObject:c];
}
- (void)removeAccessoryController:(NSViewController<NSPrintPanelAccessorizing> *)c
{
    [_accessories removeObjectIdenticalTo:c];
}
- (NSInteger)runModal { return [self runModalWithPrintInfo:NSPrintOperation.currentOperation.printInfo ?: [NSPrintInfo sharedPrintInfo]]; }
- (NSInteger)runModalWithPrintInfo:(NSPrintInfo *)info
{
    [_printInfo release];
    _printInfo = [info retain];
    return NSModalResponseCancel;
}
- (void)beginSheetUsingPrintInfo:(NSPrintInfo *)info onWindow:(NSWindow *)window
               completionHandler:(void (^)(NSPrintPanelResult))handler
{
    [_printInfo release];
    _printInfo = [info retain];
    if (handler)
        handler(NSPrintPanelResultCancelled);
}
- (void)beginSheetWithPrintInfo:(NSPrintInfo *)info
                  modalForWindow:(NSWindow *)window
                         delegate:(id)delegate
                  didEndSelector:(SEL)didEndSelector
                     contextInfo:(void *)contextInfo
{
    [self beginSheetUsingPrintInfo:info onWindow:window completionHandler:^(NSPrintPanelResult result) {
        if (delegate && didEndSelector)
            ((void (*)(id, SEL, id, NSInteger, void *))objc_msgSend)(delegate, didEndSelector, self, result, contextInfo);
    }];
}
- (NSPrintInfo *)printInfo { return _printInfo ?: [NSPrintInfo sharedPrintInfo]; }
- (void)updateFromPrintInfo
{
    if (!_printInfo)
        _printInfo = [[NSPrintInfo sharedPrintInfo] retain];
}
- (void)finalWritePrintInfo {}

- (void)dealloc
{
    [_helpAnchor release];
    [_jobStyleHint release];
    [_defaultButtonTitle release];
    [_printInfo release];
    [_accessories release];
    [super dealloc];
}

@end

@implementation NSPageLayout {
    NSPrintInfo *_printInfo;
    NSMutableArray *_accessories;
}

+ (NSPageLayout *)pageLayout { return [[[self alloc] init] autorelease]; }
- (NSInteger)runModal { return [self runModalWithPrintInfo:[NSPrintInfo sharedPrintInfo]]; }
- (NSInteger)runModalWithPrintInfo:(NSPrintInfo *)info
{
    [_printInfo release];
    _printInfo = [info retain];
    return NSModalResponseCancel;
}
- (void)beginSheetUsingPrintInfo:(NSPrintInfo *)info onWindow:(NSWindow *)window
               completionHandler:(void (^)(NSPageLayoutResult))handler
{
    [_printInfo release];
    _printInfo = [info retain];
    if (handler)
        handler(NSPageLayoutResultCancelled);
}
- (void)beginSheetWithPrintInfo:(NSPrintInfo *)info
                  modalForWindow:(NSWindow *)window
                         delegate:(id)delegate
                  didEndSelector:(SEL)didEndSelector
                     contextInfo:(void *)contextInfo
{
    [self beginSheetUsingPrintInfo:info onWindow:window completionHandler:^(NSPageLayoutResult result) {
        if (delegate && didEndSelector)
            ((void (*)(id, SEL, id, NSInteger, void *))objc_msgSend)(delegate, didEndSelector, self, result, contextInfo);
    }];
}
- (NSArray *)accessoryControllers { return _accessories ? [[_accessories copy] autorelease] : @[]; }
- (NSView *)accessoryView { return [(NSViewController *)_accessories.firstObject view]; }
- (void)setAccessoryView:(NSView *)view
{
    [_accessories release];
    _accessories = nil;
    if (view) {
        NSViewController *controller = [[NSViewController alloc] init];
        controller.view = view;
        _accessories = [[NSMutableArray alloc] initWithObjects:controller, nil];
        [controller release];
    }
}
- (void)addAccessoryController:(NSViewController *)controller
{
    if (!_accessories)
        _accessories = [[NSMutableArray alloc] init];
    [_accessories addObject:controller];
}
- (void)removeAccessoryController:(NSViewController *)controller { [_accessories removeObjectIdenticalTo:controller]; }
- (NSPrintInfo *)printInfo { return _printInfo; }
- (void)readPrintInfo {}
- (void)writePrintInfo {}

- (void)dealloc
{
    [_printInfo release];
    [_accessories release];
    [super dealloc];
}

@end

#pragma mark - NSView's printing and PDF methods

@implementation NSView (FinchPrinting)

- (NSData *)dataWithPDFInsideRect:(NSRect)rect
{
    NSMutableData *d = [NSMutableData data];
    [[NSPrintOperation PDFOperationWithView:self insideRect:rect toData:d] runOperation];
    return d;
}

- (NSData *)dataWithEPSInsideRect:(NSRect)rect
{
    return [self dataWithPDFInsideRect:rect];
}

- (void)print:(id)sender
{
    [[NSPrintOperation printOperationWithView:self] runOperation];
}

- (BOOL)knowsPageRange:(NSRangePointer)range { return NO; }
- (NSRect)rectForPage:(NSInteger)page { return NSZeroRect; }
- (NSPoint)locationOfPrintRect:(NSRect)rect { return NSZeroPoint; }
- (void)beginDocument {}
- (void)endDocument {}
- (void)beginPageInRect:(NSRect)rect atPlacement:(NSPoint)location {}
- (void)endPage {}
- (NSString *)printJobTitle { return [[self window] title] ?: @""; }
- (CGFloat)heightAdjustLimit { return 0.2; }
- (CGFloat)widthAdjustLimit { return 0.2; }
- (void)adjustPageWidthNew:(CGFloat *)newRight left:(CGFloat)oldLeft right:(CGFloat)oldRight limit:(CGFloat)limit {}
- (void)adjustPageHeightNew:(CGFloat *)newBottom top:(CGFloat)oldTop bottom:(CGFloat)oldBottom limit:(CGFloat)limit {}
- (NSAttributedString *)pageHeader { return nil; }
- (NSAttributedString *)pageFooter { return nil; }

@end
