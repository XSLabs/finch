/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * ConsoleKit, Finch's own: its additions to AppKit and Foundation classes (the csk_
 * methods Console calls), and the search field's token field and cell. Icons are
 * symbol images (Finch's own symbols), with AppKit's named images behind them.
 */
#import "ConsoleKit.h"

static NSImage *
symbol(NSString *name, NSString *fallback)
{
    NSImage *i = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    return i ?: (fallback ? [NSImage imageNamed:fallback] : nil);
}

@implementation NSImage (ConsoleKit)
+ (NSImage *)csk_sidebarGenericFolderIcon { return symbol(@"folder", NSImageNameFolder); }
+ (NSImage *)csk_sidebarGenericFileIcon { return symbol(@"doc", NSImageNameMultipleDocuments); }
+ (NSImage *)csk_sidebarCrashReportIcon { return symbol(@"exclamationmark.triangle", NSImageNameCaution); }
+ (NSImage *)csk_sidebarLogReportIcon { return symbol(@"doc.text", NSImageNameMultipleDocuments); }
+ (NSImage *)csk_sidebarMacAnalyticsReportIcon { return symbol(@"chart.bar.doc.horizontal", NSImageNameMultipleDocuments); }
+ (NSImage *)csk_sidebarMiscReportIcon { return symbol(@"doc.badge.ellipsis", NSImageNameMultipleDocuments); }
+ (NSImage *)csk_sidebarSpinReportIcon { return symbol(@"hourglass", NSImageNameMultipleDocuments); }
+ (NSImage *)csk_sidebarMacIcon { return symbol(@"desktopcomputer", NSImageNameComputer); }
+ (NSImage *)csk_sidebarMacBookIcon { return symbol(@"laptopcomputer", NSImageNameComputer); }
+ (NSImage *)csk_sidebarUnknownDeviceIcon { return symbol(@"questionmark.square.dashed", NSImageNameComputer); }
+ (NSImage *)csk_iconForFileURL:(NSURL *)url { return [[NSWorkspace sharedWorkspace] iconForFile:url.path]; }
+ (NSImage *)csk_iconForFilePath:(NSString *)path { return [[NSWorkspace sharedWorkspace] iconForFile:path]; }
+ (NSImage *)csk_imageNamed:(NSString *)name inBundle:(NSBundle *)bundle { return [bundle imageForResource:name] ?: [NSImage imageNamed:name]; }
+ (NSImage *)csk_findIconWithColor:(NSColor *)color { return [symbol(@"magnifyingglass", nil) csk_imageTintedWithColor:color]; }
+ (NSImage *)csk_pullDownIconWithColor:(NSColor *)color { return [symbol(@"chevron.down", nil) csk_imageTintedWithColor:color]; }

static NSImage *
dot(NSColor *c)
{
    return [NSImage imageWithSize:NSMakeSize(8, 8) flipped:NO drawingHandler:^BOOL(NSRect r) {
        [c setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(r, 1, 1)] fill];
        return YES;
    }];
}

+ (NSImage *)csk_debugMessageTypeDotIcon { return dot([NSColor csk_debugMessageTypeColor]); }
+ (NSImage *)csk_infoMessageTypeDotIcon { return dot([NSColor csk_infoMessageTypeColor]); }
+ (NSImage *)csk_errorMessageTypeDotIcon { return dot([NSColor csk_errorMessageTypeColor]); }
+ (NSImage *)csk_faultMessageTypeDotIcon { return dot([NSColor csk_faultMessageTypeColor]); }

- (NSImage *)csk_imageTintedWithColor:(NSColor *)color
{
    if (!color)
        return self;
    NSImage *src = self;
    NSImage *i = [NSImage imageWithSize:self.size flipped:NO drawingHandler:^BOOL(NSRect r) {
        [src drawInRect:r];
        [color set];
        NSRectFillUsingOperation(r, NSCompositingOperationSourceAtop);
        return YES;
    }];
    return i;
}
@end

@implementation NSColor (ConsoleKit)
+ (NSColor *)csk_debugMessageTypeColor { return NSColor.systemGrayColor; }
+ (NSColor *)csk_infoMessageTypeColor { return NSColor.systemBlueColor; }
+ (NSColor *)csk_errorMessageTypeColor { return NSColor.systemYellowColor; }
+ (NSColor *)csk_faultMessageTypeColor { return NSColor.systemRedColor; }
+ (NSColor *)csk_debugMessageTypeTextColor { return NSColor.secondaryLabelColor; }
+ (NSColor *)csk_infoMessageTypeTextColor { return NSColor.labelColor; }
+ (NSColor *)csk_errorMessageTypeTextColor { return NSColor.labelColor; }
+ (NSColor *)csk_faultMessageTypeTextColor { return NSColor.labelColor; }
+ (NSColor *)csk_headerViewExtendButtonTitleColor { return NSColor.secondaryLabelColor; }
+ (NSColor *)csk_toolbarIconTintColor { return NSColor.secondaryLabelColor; }
@end

@implementation NSView (ConsoleKit)
- (void)csk_activateTiedConstraintsToSuperview
{
    NSView *s = self.superview;
    if (!s)
        return;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [self.topAnchor constraintEqualToAnchor:s.topAnchor], [self.bottomAnchor constraintEqualToAnchor:s.bottomAnchor],
        [self.leadingAnchor constraintEqualToAnchor:s.leadingAnchor], [self.trailingAnchor constraintEqualToAnchor:s.trailingAnchor]
    ]];
}
@end

@implementation NSScrollView (ConsoleKit)
- (void)csk_scrollToBottomWithEnclosedViewHeight:(CGFloat)height
{
    NSClipView *clip = self.contentView;
    CGFloat y = MAX(0, height - clip.bounds.size.height);
    [clip scrollToPoint:NSMakePoint(clip.bounds.origin.x, self.documentView.isFlipped ? y : 0)];
    [self reflectScrolledClipView:clip];
}
@end

@implementation NSString (ConsoleKit)
- (NSString *)csk_leadingTrailingWhitespacesAndNewLinesSanitizedString
{
    return [self stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}
- (NSString *)csk_newLinesSanitizedString
{
    return [[self componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "];
}
- (NSArray *)csk_newLinesSplittedString { return [self componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]; }
- (CGFloat)csk_heightForWidth:(CGFloat)width font:(NSFont *)font
{
    NSRect r = [self boundingRectWithSize:NSMakeSize(width, CGFLOAT_MAX) options:NSStringDrawingUsesLineFragmentOrigin
                               attributes:@{NSFontAttributeName : font ?: [NSFont systemFontOfSize:0]}];
    return ceil(r.size.height);
}
@end

/* The search field: a token field with a magnifying glass at its start. */
@interface CSKTokenFieldCell : NSTokenFieldCell
@end

@implementation CSKTokenFieldCell

- (NSImage *)findDefaultIcon { return [NSImage csk_findIconWithColor:NSColor.secondaryLabelColor]; }
- (NSImage *)findUnfocusedIcon { return [NSImage csk_findIconWithColor:NSColor.tertiaryLabelColor]; }

- (NSRect)_findIconRectFromContainerRect:(NSRect)r
{
    return NSMakeRect(NSMinX(r) + 5, NSMidY(r) - 7, 14, 14);
}

- (NSRect)drawingRectForBounds:(NSRect)bounds
{
    NSRect r = [super drawingRectForBounds:bounds];
    r.origin.x += 18;
    r.size.width = MAX(0, r.size.width - 18);
    return r;
}

- (void)drawInteriorWithFrame:(NSRect)frame inView:(NSView *)view
{
    [[self findDefaultIcon] drawInRect:[self _findIconRectFromContainerRect:frame]];
    [super drawInteriorWithFrame:frame inView:view];
}

@end

@interface CSKTokenField : NSTokenField
@end

@implementation CSKTokenField
+ (Class)cellClass { return [CSKTokenFieldCell class]; }
- (void)invalidateSelectionAndDisplayTokens { self.needsDisplay = YES; }
@end
