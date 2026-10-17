// SPDX-License-Identifier: MIT OR Apache-2.0
#import <PDFKit/PDFKit.h>
#import <PDFKit/PDFThumbnailView.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

NSString * const PDFViewDocumentChangedNotification = @"PDFViewDocumentChangedNotification";
NSString * const PDFViewChangedHistoryNotification = @"PDFViewChangedHistoryNotification";
NSString * const PDFViewPageChangedNotification = @"PDFViewPageChangedNotification";
NSString * const PDFViewScaleChangedNotification = @"PDFViewScaleChangedNotification";
NSString * const PDFViewAnnotationHitNotification = @"PDFViewAnnotationHitNotification";
NSString * const PDFViewCopyPermissionNotification = @"PDFViewCopyPermissionNotification";
NSString * const PDFViewPrintPermissionNotification = @"PDFViewPrintPermissionNotification";
NSString * const PDFViewAnnotationWillHitNotification = @"PDFViewAnnotationWillHitNotification";
NSString * const PDFViewSelectionChangedNotification = @"PDFViewSelectionChangedNotification";
NSString * const PDFViewDisplayModeChangedNotification = @"PDFViewDisplayModeChangedNotification";
NSString * const PDFViewDisplayBoxChangedNotification = @"PDFViewDisplayBoxChangedNotification";
NSString * const PDFViewVisiblePagesChangedNotification = @"PDFViewVisiblePagesChangedNotification";
NSString * const PDFThumbnailViewDocumentEditedNotification = @"PDFThumbnailViewDocumentEditedNotification";

@implementation PDFView {
@public
    PDFDocument *_fdocument;
    PDFSelection *_fselection;
    NSArray *_fhighlights;
    NSColor *_fbackground;
    id<PDFViewDelegate> _fdelegate;
    id<PDFPageOverlayViewProvider> _foverlayProvider;
    NSUInteger _fpageIndex;
    PDFDisplayMode _fmode;
    PDFDisplayDirection _fdirection;
    PDFDisplayBox _fbox;
    PDFInterpolationQuality _fquality;
    CGFloat _fscale, _fminScale, _fmaxScale;
    BOOL _fautoScales, _fpageBreaks, _fbook, _frtl, _fshadows, _facceptsFiles, _fdataDetectors, _fmarkup;
    PDFEdgeInsets _fmargins;
    NSMutableArray *_fhistory;
    NSUInteger _fhistoryIndex;
}
- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        _fmode = kPDFDisplaySinglePageContinuous;
        _fdirection = kPDFDisplayDirectionVertical;
        _fbox = kPDFDisplayBoxCropBox;
        _fquality = kPDFInterpolationQualityHigh;
        _fscale = 1.0; _fminScale = 0.1; _fmaxScale = 10.0;
        _fpageBreaks = YES; _fshadows = YES;
        _fmargins = (PDFEdgeInsets){ 4.75, 4.0, 4.75, 4.0 };
        _fbackground = [[NSColor colorWithCalibratedWhite:0.5 alpha:1.0] retain];
        _fhistory = [NSMutableArray new];
        self.wantsLayer = YES;
    }
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super initWithCoder:coder])) {
        _fmode = kPDFDisplaySinglePageContinuous; _fdirection = kPDFDisplayDirectionVertical;
        _fbox = kPDFDisplayBoxCropBox; _fscale = 1; _fminScale = 0.1; _fmaxScale = 10;
        _fpageBreaks = YES; _fshadows = YES; _fbackground = [[NSColor colorWithCalibratedWhite:0.5 alpha:1] retain];
        _fhistory = [NSMutableArray new]; self.wantsLayer = YES;
    }
    (void)coder;
    return self;
}
- (PDFDocument *)document { return _fdocument; }
- (void)setDocument:(PDFDocument *)document
{
    if (_fdocument == document) return;
    [_fdocument release]; _fdocument = [document retain];
    _fpageIndex = 0; [_fselection release]; _fselection = nil; [_fhistory removeAllObjects]; _fhistoryIndex = 0;
    if (_fdocument.pageCount) [_fhistory addObject:@0];
    if (_fautoScales) self.scaleFactor = self.scaleFactorForSizeToFit;
    [self setNeedsDisplay:YES];
    [[NSNotificationCenter defaultCenter] postNotificationName:PDFViewDocumentChangedNotification object:self];
}
- (PDFPage *)currentPage { return [_fdocument pageAtIndex:_fpageIndex]; }
- (BOOL)canGoToFirstPage { return _fdocument.pageCount > 0 && _fpageIndex > 0; }
- (BOOL)canGoToLastPage { return _fdocument.pageCount > 0 && _fpageIndex + 1 < _fdocument.pageCount; }
- (BOOL)canGoToNextPage { return [self canGoToLastPage]; }
- (BOOL)canGoToPreviousPage { return [self canGoToFirstPage]; }
- (BOOL)canGoBack { return _fhistoryIndex > 0; }
- (BOOL)canGoForward { return _fhistoryIndex + 1 < _fhistory.count; }
- (void)_setPageIndex:(NSUInteger)index record:(BOOL)record
{
    if (!_fdocument.pageCount) return;
    index = MIN(index, _fdocument.pageCount - 1);
    if (_fpageIndex == index) return;
    _fpageIndex = index;
    if (record) {
        while (_fhistory.count > _fhistoryIndex + 1) [_fhistory removeLastObject];
        [_fhistory addObject:@(index)]; _fhistoryIndex = _fhistory.count - 1;
        [[NSNotificationCenter defaultCenter] postNotificationName:PDFViewChangedHistoryNotification object:self];
    }
    [self setNeedsDisplay:YES];
    [[NSNotificationCenter defaultCenter] postNotificationName:PDFViewPageChangedNotification object:self];
}
- (void)goToFirstPage:(id)sender { if (_fdocument.pageCount) [self _setPageIndex:0 record:YES]; (void)sender; }
- (void)goToLastPage:(id)sender { if (_fdocument.pageCount) [self _setPageIndex:_fdocument.pageCount - 1 record:YES]; (void)sender; }
- (void)goToNextPage:(id)sender { if ([self canGoToNextPage]) [self _setPageIndex:_fpageIndex + 1 record:YES]; (void)sender; }
- (void)goToPreviousPage:(id)sender { if ([self canGoToPreviousPage]) [self _setPageIndex:_fpageIndex - 1 record:YES]; (void)sender; }
- (void)goBack:(id)sender
{
    if ([self canGoBack]) { _fhistoryIndex--; _fpageIndex = [_fhistory[_fhistoryIndex] unsignedIntegerValue]; [self setNeedsDisplay:YES]; [[NSNotificationCenter defaultCenter] postNotificationName:PDFViewPageChangedNotification object:self]; }
    (void)sender;
}
- (void)goForward:(id)sender
{
    if ([self canGoForward]) { _fhistoryIndex++; _fpageIndex = [_fhistory[_fhistoryIndex] unsignedIntegerValue]; [self setNeedsDisplay:YES]; [[NSNotificationCenter defaultCenter] postNotificationName:PDFViewPageChangedNotification object:self]; }
    (void)sender;
}
- (void)goToPage:(PDFPage *)page
{
    NSUInteger index = [_fdocument indexForPage:page];
    if (index != NSNotFound) [self _setPageIndex:index record:YES];
}
- (PDFDestination *)currentDestination
{
    PDFPage *page = self.currentPage;
    if (!page) return nil;
    CGRect bounds = [page boundsForBox:_fbox];
    return [[[PDFDestination alloc] initWithPage:page atPoint:CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds))] autorelease];
}
- (void)goToDestination:(PDFDestination *)destination
{
    if (destination.page) [self goToPage:destination.page];
    if (destination.zoom > 0) self.scaleFactor = destination.zoom;
}
- (void)goToSelection:(PDFSelection *)selection
{
    if (selection.pages.count) [self goToPage:[selection.pages firstObject]];
    self.currentSelection = selection;
}
- (void)goToRect:(PDFRect)rect onPage:(PDFPage *)page { [self goToPage:page]; (void)rect; }
- (PDFDisplayMode)displayMode { return _fmode; }
- (void)setDisplayMode:(PDFDisplayMode)mode { if (mode < kPDFDisplaySinglePage || mode > kPDFDisplayTwoUpContinuous) return; if (_fmode != mode) { _fmode = mode; [self setNeedsDisplay:YES]; [[NSNotificationCenter defaultCenter] postNotificationName:PDFViewDisplayModeChangedNotification object:self]; } }
- (PDFDisplayDirection)displayDirection { return _fdirection; }
- (void)setDisplayDirection:(PDFDisplayDirection)direction { _fdirection = direction; [self setNeedsDisplay:YES]; }
- (BOOL)displaysPageBreaks { return _fpageBreaks; }
- (void)setDisplaysPageBreaks:(BOOL)value { _fpageBreaks = value; if (!value) _fmargins = (PDFEdgeInsets){0,0,0,0}; [self setNeedsDisplay:YES]; }
- (PDFEdgeInsets)pageBreakMargins { return _fpageBreaks ? _fmargins : (PDFEdgeInsets){0,0,0,0}; }
- (void)setPageBreakMargins:(PDFEdgeInsets)margins
{
    _fmargins = (PDFEdgeInsets){ MAX(0,margins.top), MAX(0,margins.left), MAX(0,margins.bottom), MAX(0,margins.right) };
    [self setNeedsDisplay:YES];
}
- (PDFDisplayBox)displayBox { return _fbox; }
- (void)setDisplayBox:(PDFDisplayBox)box { if (box < kPDFDisplayBoxMediaBox || box > kPDFDisplayBoxArtBox) return; if (_fbox != box) { _fbox = box; [self setNeedsDisplay:YES]; [[NSNotificationCenter defaultCenter] postNotificationName:PDFViewDisplayBoxChangedNotification object:self]; } }
- (BOOL)displaysAsBook { return _fbook; }
- (void)setDisplaysAsBook:(BOOL)value { _fbook = value; [self setNeedsDisplay:YES]; }
- (BOOL)displaysRTL { return _frtl; }
- (void)setDisplaysRTL:(BOOL)value { _frtl = value; [self setNeedsDisplay:YES]; }
- (NSColor *)backgroundColor { return _fbackground; }
- (void)setBackgroundColor:(NSColor *)color { if (_fbackground != color) { [_fbackground release]; _fbackground = [color copy]; [self setNeedsDisplay:YES]; } }
- (PDFInterpolationQuality)interpolationQuality { return _fquality; }
- (void)setInterpolationQuality:(PDFInterpolationQuality)quality { _fquality = quality; }
- (BOOL)pageShadowsEnabled { return _fshadows; }
- (void)enablePageShadows:(BOOL)enabled { _fshadows = enabled; [self setNeedsDisplay:YES]; }
- (id<PDFViewDelegate>)delegate { return _fdelegate; }
- (void)setDelegate:(id<PDFViewDelegate>)delegate { _fdelegate = delegate; }
- (id<PDFPageOverlayViewProvider>)pageOverlayViewProvider { return _foverlayProvider; }
- (void)setPageOverlayViewProvider:(id<PDFPageOverlayViewProvider>)provider { _foverlayProvider = provider; }
- (CGFloat)scaleFactor { return _fscale; }
- (void)setScaleFactor:(CGFloat)scale { CGFloat value = MAX(_fminScale, MIN(_fmaxScale, scale)); if (_fscale != value) { _fscale = value; [self setNeedsDisplay:YES]; [[NSNotificationCenter defaultCenter] postNotificationName:PDFViewScaleChangedNotification object:self]; } }
- (CGFloat)minScaleFactor { return _fminScale; }
- (void)setMinScaleFactor:(CGFloat)value { _fminScale = MAX(0.01, value); if (_fmaxScale < _fminScale) _fmaxScale = _fminScale; _fautoScales = NO; self.scaleFactor = _fscale; }
- (CGFloat)maxScaleFactor { return _fmaxScale; }
- (void)setMaxScaleFactor:(CGFloat)value { _fmaxScale = MAX(_fminScale, value); _fautoScales = NO; self.scaleFactor = _fscale; }
- (BOOL)autoScales { return _fautoScales; }
- (void)setAutoScales:(BOOL)value { _fautoScales = value; if (value) self.scaleFactor = self.scaleFactorForSizeToFit; }
- (CGFloat)scaleFactorForSizeToFit
{
    PDFPage *page = self.currentPage;
    if (!page || NSWidth(self.bounds) <= 0 || NSHeight(self.bounds) <= 0) return 1.0;
    CGRect rect = [page boundsForBox:_fbox];
    CGFloat width = MAX(1, rect.size.width), height = MAX(1, rect.size.height);
    CGFloat horizontal = MAX(1, NSWidth(self.bounds) - _fmargins.left - _fmargins.right) / width;
    CGFloat vertical = MAX(1, NSHeight(self.bounds) - _fmargins.top - _fmargins.bottom) / height;
    return _fmode == kPDFDisplaySinglePageContinuous || _fmode == kPDFDisplayTwoUpContinuous ? horizontal : MIN(horizontal, vertical);
}
- (void)zoomIn:(id)sender { if ([self canZoomIn]) self.scaleFactor = _fscale * M_SQRT2; (void)sender; }
- (BOOL)canZoomIn { return _fscale < _fmaxScale - 1e-6; }
- (void)zoomOut:(id)sender { if ([self canZoomOut]) self.scaleFactor = _fscale / M_SQRT2; (void)sender; }
- (BOOL)canZoomOut { return _fscale > _fminScale + 1e-6; }
- (PDFAreaOfInterest)areaOfInterestForMouse:(NSEvent *)event { (void)event; return self.currentPage ? kPDFPageArea : kPDFNoArea; }
- (PDFAreaOfInterest)areaOfInterestForPoint:(PDFPoint)point { (void)point; return self.currentPage ? kPDFPageArea : kPDFNoArea; }
- (void)setCursorForAreaOfInterest:(PDFAreaOfInterest)area { (void)area; }
- (void)performAction:(PDFAction *)action
{
    if ([action isKindOfClass:[PDFActionGoTo class]]) [self goToDestination:[(PDFActionGoTo *)action destination]];
    else if ([action isKindOfClass:[PDFActionURL class]]) [[NSWorkspace sharedWorkspace] openURL:[(PDFActionURL *)action URL]];
}
- (PDFSelection *)currentSelection { return _fselection; }
- (void)setCurrentSelection:(PDFSelection *)selection
{
    if (_fselection == selection) return;
    [_fselection release]; _fselection = [selection retain]; [self setNeedsDisplay:YES];
    [[NSNotificationCenter defaultCenter] postNotificationName:PDFViewSelectionChangedNotification object:self];
}
- (void)setCurrentSelection:(PDFSelection *)selection animate:(BOOL)animate { self.currentSelection = selection; (void)animate; }
- (void)clearSelection { self.currentSelection = nil; }
- (void)selectAll:(id)sender { self.currentSelection = _fdocument.selectionForEntireDocument; (void)sender; }
- (void)scrollSelectionToVisible:(id)sender { if (_fselection.pages.count) [self goToPage:[_fselection.pages firstObject]]; (void)sender; }
- (NSArray *)highlightedSelections { return _fhighlights; }
- (void)setHighlightedSelections:(NSArray *)selections { if (_fhighlights != selections) { [_fhighlights release]; _fhighlights = [selections copy]; [self setNeedsDisplay:YES]; } }
- (void)drawPage:(PDFPage *)page toContext:(CGContextRef)context
{
    if (!page || !context) return;
    CGContextSaveGState(context);
    CGContextSetRGBFillColor(context, 1, 1, 1, 1);
    CGContextFillRect(context, [page boundsForBox:_fbox]);
    CGContextRestoreGState(context);
    [page drawWithBox:_fbox toContext:context];
    if (_fselection) [_fselection drawForPage:page withBox:_fbox active:YES];
    for (PDFSelection *selection in _fhighlights) [selection drawForPage:page withBox:_fbox active:NO];
}
- (void)drawPagePost:(PDFPage *)page toContext:(CGContextRef)context { (void)page; (void)context; }
- (void)drawRect:(NSRect)dirtyRect
{
    [_fbackground set]; NSRectFill(dirtyRect);
    if (!_fdocument.pageCount) return;
    CGContextRef context = [[NSGraphicsContext currentContext] CGContext];
    if (!context) return;
    NSUInteger first = _fmode == kPDFDisplaySinglePage ? _fpageIndex : 0;
    NSUInteger last = _fmode == kPDFDisplaySinglePage ? _fpageIndex + 1 : _fdocument.pageCount;
    CGFloat top = NSMaxY(self.bounds) - _fmargins.top;
    for (NSUInteger index = first; index < last; index++) {
        PDFPage *page = [_fdocument pageAtIndex:index];
        CGRect bounds = [page boundsForBox:_fbox];
        CGFloat scale = _fscale;
        CGFloat width = bounds.size.width * scale, height = bounds.size.height * scale;
        CGFloat x = NSMinX(self.bounds) + (NSWidth(self.bounds) - width) / 2.0;
        CGFloat y = top - height;
        if (y + height >= NSMinY(dirtyRect) && y <= NSMaxY(dirtyRect)) {
            CGContextSaveGState(context);
            CGContextTranslateCTM(context, x, y);
            CGContextScaleCTM(context, scale, scale);
            CGContextTranslateCTM(context, -bounds.origin.x, -bounds.origin.y);
            [self drawPage:page toContext:context];
            [self drawPagePost:page toContext:context];
            CGContextRestoreGState(context);
        }
        top = y - (_fpageBreaks ? _fmargins.bottom + _fmargins.top : 0);
    }
}
- (void)copy:(id)sender
{
    if (!_fdocument.allowsCopying) { [[NSNotificationCenter defaultCenter] postNotificationName:PDFViewCopyPermissionNotification object:self]; return; }
    NSString *string = _fselection.string;
    if (string) { NSPasteboard *pasteboard = [NSPasteboard generalPasteboard]; [pasteboard clearContents]; [pasteboard setString:string forType:NSPasteboardTypeString]; }
    (void)sender;
}
- (void)printWithInfo:(NSPrintInfo *)printInfo autoRotate:(BOOL)rotate { NSPrintOperation *operation = [_fdocument printOperationForPrintInfo:printInfo scalingMode:kPDFPrintPageScaleToFit autoRotate:rotate]; [operation runOperation]; }
- (void)printWithInfo:(NSPrintInfo *)printInfo autoRotate:(BOOL)rotate pageScaling:(PDFPrintScalingMode)scale { NSPrintOperation *operation = [_fdocument printOperationForPrintInfo:printInfo scalingMode:scale autoRotate:rotate]; [operation runOperation]; }
- (PDFPage *)pageForPoint:(PDFPoint)point nearest:(BOOL)nearest { (void)point; (void)nearest; return self.currentPage; }
- (PDFPoint)convertPoint:(PDFPoint)point toPage:(PDFPage *)page { (void)page; return point; }
- (PDFRect)convertRect:(PDFRect)rect toPage:(PDFPage *)page { (void)page; return rect; }
- (PDFPoint)convertPoint:(PDFPoint)point fromPage:(PDFPage *)page { (void)page; return point; }
- (PDFRect)convertRect:(PDFRect)rect fromPage:(PDFPage *)page { (void)page; return rect; }
- (NSView *)documentView { return self; }
- (void)layoutDocumentView { [self setNeedsDisplay:YES]; }
- (void)annotationsChangedOnPage:(PDFPage *)page { if (page.document == _fdocument) [self setNeedsDisplay:YES]; }
- (PDFSize)rowSizeForPage:(PDFPage *)page { CGRect bounds = [page boundsForBox:_fbox]; return bounds.size; }
- (BOOL)acceptsDraggedFiles { return _facceptsFiles; }
- (void)setAcceptsDraggedFiles:(BOOL)value { _facceptsFiles = value; }
- (NSArray *)visiblePages { return self.currentPage ? @[self.currentPage] : @[]; }
- (BOOL)enableDataDetectors { return _fdataDetectors; }
- (void)setEnableDataDetectors:(BOOL)value { _fdataDetectors = value; }
- (BOOL)isInMarkupMode { return _fmarkup; }
- (void)setInMarkupMode:(BOOL)value { _fmarkup = value; }
- (void)dealloc
{
    [_fdocument release]; [_fselection release]; [_fhighlights release]; [_fbackground release]; [_fhistory release];
    [super dealloc];
}
@end

@implementation PDFThumbnailView {
@public
    PDFView *_fview;
    NSColor *_fbackground;
    NSSize _fthumbnailSize;
    NSUInteger _fcolumns;
    NSFont *_ffont;
    BOOL _fdrag, _fmulti;
}
- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        _fthumbnailSize = NSMakeSize(128, 128); _fbackground = [[NSColor controlBackgroundColor] retain];
        _ffont = [[NSFont systemFontOfSize:11] retain]; _fcolumns = 0;
    }
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super initWithCoder:coder])) { _fthumbnailSize = NSMakeSize(128,128); _fbackground = [[NSColor controlBackgroundColor] retain]; _ffont = [[NSFont systemFontOfSize:11] retain]; }
    (void)coder;
    return self;
}
- (PDFView *)PDFView { return _fview; }
- (void)setPDFView:(PDFView *)view { _fview = view; [self setNeedsDisplay:YES]; }
- (NSColor *)backgroundColor { return _fbackground; }
- (void)setBackgroundColor:(NSColor *)color { if (_fbackground != color) { [_fbackground release]; _fbackground = [color copy]; [self setNeedsDisplay:YES]; } }
- (NSArray *)selectedPages { return _fview.currentPage ? @[_fview.currentPage] : @[]; }
- (NSSize)thumbnailSize { return _fthumbnailSize; }
- (void)setThumbnailSize:(NSSize)size { _fthumbnailSize = NSMakeSize(MAX(1,size.width),MAX(1,size.height)); [self setNeedsDisplay:YES]; }
- (NSUInteger)maximumNumberOfColumns { return _fcolumns; }
- (void)setMaximumNumberOfColumns:(NSUInteger)columns { _fcolumns = columns; [self setNeedsDisplay:YES]; }
- (NSFont *)labelFont { return _ffont; }
- (void)setLabelFont:(NSFont *)font { if (_ffont != font) { [_ffont release]; _ffont = [font copy]; [self setNeedsDisplay:YES]; } }
- (BOOL)allowsDragging { return _fdrag; }
- (void)setAllowsDragging:(BOOL)value { _fdrag = value; }
- (BOOL)allowsMultipleSelection { return _fmulti; }
- (void)setAllowsMultipleSelection:(BOOL)value { _fmulti = value; }
- (void)drawRect:(NSRect)dirtyRect
{
    [_fbackground set]; NSRectFill(dirtyRect);
    PDFDocument *document = _fview.document;
    if (!document.pageCount) return;
    NSUInteger columns = _fcolumns ? MIN(_fcolumns, document.pageCount) : MAX(1, (NSUInteger)(NSWidth(self.bounds) / (_fthumbnailSize.width + 24)));
    CGFloat cellWidth = NSWidth(self.bounds) / columns;
    CGFloat y = NSMaxY(self.bounds) - 12;
    for (NSUInteger i = 0; i < document.pageCount; i++) {
        NSUInteger row = i / columns, column = i % columns;
        CGFloat x = NSMinX(self.bounds) + column * cellWidth + (cellWidth - _fthumbnailSize.width) / 2;
        CGFloat cellY = y - row * (_fthumbnailSize.height + 30);
        NSImage *image = [[document pageAtIndex:i] thumbnailOfSize:_fthumbnailSize forBox:kPDFDisplayBoxCropBox];
        [image drawInRect:NSMakeRect(x, cellY - _fthumbnailSize.height, _fthumbnailSize.width, _fthumbnailSize.height)];
        NSDictionary *attributes = _ffont ? @{ NSFontAttributeName: _ffont, NSForegroundColorAttributeName: [NSColor labelColor] } : @{};
        NSString *label = [NSString stringWithFormat:@"%lu", (unsigned long)(i + 1)];
        NSSize textSize = [label sizeWithAttributes:attributes];
        [label drawAtPoint:NSMakePoint(x + (_fthumbnailSize.width - textSize.width) / 2, cellY - _fthumbnailSize.height - 16) withAttributes:attributes];
        if (i == [_fview.document indexForPage:_fview.currentPage]) {
            [[NSColor selectedControlColor] set]; NSFrameRect(NSMakeRect(x - 2, cellY - _fthumbnailSize.height - 2, _fthumbnailSize.width + 4, _fthumbnailSize.height + 4));
        }
    }
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeSize:_fthumbnailSize forKey:@"thumbnailSize"];
    [coder encodeInteger:(NSInteger)_fcolumns forKey:@"maximumNumberOfColumns"];
    [coder encodeObject:_ffont forKey:@"labelFont"];
    [coder encodeBool:_fdrag forKey:@"allowsDragging"];
    [coder encodeBool:_fmulti forKey:@"allowsMultipleSelection"];
}
- (void)dealloc { [_fbackground release]; [_ffont release]; [super dealloc]; }
@end
