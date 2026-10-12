/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * IKSaveOptions: the image format and its options a save panel offers. An accessory view
 * with the formats ImageIO writes (a popup) and, for the lossy ones, a quality slider;
 * the user's choice comes back as the type and the properties to write with
 * (kCGImageDestinationLossyCompressionQuality).
 */
#import <Quartz/Quartz.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

/* The formats offered, in order, as ImageIO's type identifiers. */
static NSArray<NSString *> *
offered_types(void)
{
    NSArray *writable = [(NSArray *)CGImageDestinationCopyTypeIdentifiers() autorelease];
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *t in @[@"public.jpeg", @"public.png", @"public.tiff", @"public.heic", @"com.compuserve.gif", @"com.microsoft.bmp",
                          @"org.webmproject.webp"])
        if ([writable containsObject:t])
            [a addObject:t];
    return a;
}

static BOOL
lossy(NSString *type)
{
    return [type isEqual:@"public.jpeg"] || [type isEqual:@"public.heic"] || [type isEqual:@"org.webmproject.webp"];
}

@interface IKSaveOptions ()
@property (retain) NSPopUpButton *formatPopup;
@property (retain) NSSlider *qualitySlider;
@property (retain) NSTextField *qualityLabel;
@property (assign) NSSavePanel *savePanel;
@end

@implementation IKSaveOptions {
    NSDictionary *_properties;
    NSString *_type;
    id _delegate;
}

- (instancetype)initWithImageProperties:(NSDictionary *)imageProperties imageUTType:(NSString *)imageUTType
{
    if ((self = [super init])) {
        _properties = [imageProperties copy];
        _type = [imageUTType copy];
    }
    return self;
}

- (void)dealloc
{
    [_properties release];
    [_type release];
    [_formatPopup release];
    [_qualitySlider release];
    [_qualityLabel release];
    [super dealloc];
}

- (id)delegate { return _delegate; }
- (void)setDelegate:(id)delegate { _delegate = delegate; }
- (NSDictionary *)imageProperties { return _properties; }
- (NSString *)imageUTType { return _type; }

- (NSDictionary *)userSelection
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if (_type)
        d[@"documentType"] = _type;
    if (self.qualitySlider && lossy(_type)) {
        NSMutableDictionary *p = [NSMutableDictionary dictionaryWithDictionary:_properties ?: @{}];
        p[(NSString *)kCGImageDestinationLossyCompressionQuality] = @(self.qualitySlider.doubleValue);
        d[@"imageProperties"] = p;
    }
    return d;
}

/* The options: format, then quality for lossy formats. */
- (NSView *)_optionsView
{
    NSView *v = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 362, 64)] autorelease];
    NSTextField *formatLabel = [NSTextField labelWithString:NSLocalizedStringFromTableInBundle(@"Format:", @"ImageKit",
                                                                [NSBundle bundleForClass:[IKSaveOptions class]], nil)];
    formatLabel.frame = NSMakeRect(8, 36, 100, 20);
    formatLabel.alignment = NSTextAlignmentRight;
    [v addSubview:formatLabel];
    NSPopUpButton *popup = [[[NSPopUpButton alloc] initWithFrame:NSMakeRect(114, 32, 200, 26) pullsDown:NO] autorelease];
    for (NSString *t in offered_types()) {
        UTType *u = [UTType typeWithIdentifier:t];
        [popup addItemWithTitle:u.preferredFilenameExtension.uppercaseString ?: t];
        popup.lastItem.representedObject = t;
    }
    if (_type && [offered_types() containsObject:_type])
        [popup selectItemAtIndex:(NSInteger)[offered_types() indexOfObject:_type]];
    popup.target = self;
    popup.action = @selector(_formatChanged:);
    [v addSubview:popup];
    self.formatPopup = popup;
    NSTextField *qualityLabel = [NSTextField labelWithString:NSLocalizedStringFromTableInBundle(@"Quality:", @"ImageKit",
                                                                 [NSBundle bundleForClass:[IKSaveOptions class]], nil)];
    qualityLabel.frame = NSMakeRect(8, 8, 100, 20);
    qualityLabel.alignment = NSTextAlignmentRight;
    [v addSubview:qualityLabel];
    self.qualityLabel = qualityLabel;
    NSNumber *q = _properties[(NSString *)kCGImageDestinationLossyCompressionQuality];
    NSSlider *slider = [NSSlider sliderWithValue:q ? q.doubleValue : 0.8 minValue:0 maxValue:1 target:nil action:NULL];
    slider.frame = NSMakeRect(114, 8, 200, 20);
    [v addSubview:slider];
    self.qualitySlider = slider;
    [self _updateQuality];
    return v;
}

- (void)_updateQuality
{
    BOOL show = lossy(_type);
    self.qualitySlider.hidden = !show;
    self.qualityLabel.hidden = !show;
}

- (void)_formatChanged:(NSPopUpButton *)sender
{
    NSString *t = sender.selectedItem.representedObject;
    if (!t)
        return;
    [_type release];
    _type = [t copy];
    [self _updateQuality];
    UTType *u = [UTType typeWithIdentifier:t];
    if (u && self.savePanel)
        self.savePanel.allowedContentTypes = @[u];
}

- (void)addSaveOptionsToView:(NSView *)view
{
    NSView *options = [self _optionsView];
    NSRect b = view.bounds;
    options.frame = NSMakeRect(4, NSMaxY(b) - options.frame.size.height - 4, options.frame.size.width, options.frame.size.height);
    options.autoresizingMask = NSViewMinYMargin;
    [view addSubview:options];
}

- (void)addSaveOptionsAccessoryViewToSavePanel:(NSSavePanel *)savePanel
{
    self.savePanel = savePanel;
    savePanel.accessoryView = [self _optionsView];
    UTType *u = _type ? [UTType typeWithIdentifier:_type] : nil;
    if (u)
        savePanel.allowedContentTypes = @[u];
}

@end
