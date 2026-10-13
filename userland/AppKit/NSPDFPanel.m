/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSPDFInfo and NSPDFPanel: where and how to save a PDF. The panel is a save panel for
 * PDF files, named the default file name ("Untitled") and, with
 * NSPDFPanelRequestsParentDirectory, choosing a folder instead; what the user picks goes
 * into the info (URL, whether the extension is hidden, tags). The paper size starts as
 * the default printer's, orientation portrait, as Apple's.
 */
#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@implementation NSPDFInfo {
    NSURL *_URL;
    BOOL _fileExtensionHidden;
    NSArray *_tagNames;
    NSPaperOrientation _orientation;
    NSSize _paperSize;
    NSMutableDictionary *_attributes;
}

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)init
{
    if ((self = [super init])) {
        _tagNames = [@[] retain];
        _orientation = NSPaperOrientationPortrait;
        _paperSize = [NSPrintInfo sharedPrintInfo].paperSize;
        if (_paperSize.width <= 0 || _paperSize.height <= 0)
            _paperSize = NSMakeSize(612, 792);
        _attributes = [NSMutableDictionary new];
    }
    return self;
}

- (void)dealloc
{
    [_URL release];
    [_tagNames release];
    [_attributes release];
    [super dealloc];
}

- (NSURL *)URL { return _URL; }
- (void)setURL:(NSURL *)u { [_URL autorelease]; _URL = [u copy]; }
- (BOOL)isFileExtensionHidden { return _fileExtensionHidden; }
- (void)setFileExtensionHidden:(BOOL)h { _fileExtensionHidden = h; }
- (NSArray *)tagNames { return _tagNames; }
- (void)setTagNames:(NSArray *)t { [_tagNames autorelease]; _tagNames = [t copy] ?: [@[] retain]; }
- (NSPaperOrientation)orientation { return _orientation; }
- (void)setOrientation:(NSPaperOrientation)o { _orientation = o; }
- (NSSize)paperSize { return _paperSize; }
- (void)setPaperSize:(NSSize)s { _paperSize = s; }
- (NSMutableDictionary *)attributes { return _attributes; }

- (id)copyWithZone:(NSZone *)zone
{
    NSPDFInfo *c = [[NSPDFInfo alloc] init];
    c.URL = _URL;
    c.fileExtensionHidden = _fileExtensionHidden;
    c.tagNames = _tagNames;
    c.orientation = _orientation;
    c.paperSize = _paperSize;
    [c->_attributes addEntriesFromDictionary:_attributes];
    return c;
}

- (instancetype)initWithCoder:(NSCoder *)c
{
    if ((self = [self init])) {
        self.URL = [c decodeObjectOfClass:[NSURL class] forKey:@"NSURL"];
        _fileExtensionHidden = [c decodeBoolForKey:@"NSFileExtensionHidden"];
        NSArray *tags = [c decodeObjectOfClasses:[NSSet setWithObjects:[NSArray class], [NSString class], nil] forKey:@"NSTagNames"];
        if (tags)
            self.tagNames = tags;
        _orientation = [c decodeIntegerForKey:@"NSOrientation"];
        if ([c containsValueForKey:@"NSPaperSize"])
            _paperSize = [c decodeSizeForKey:@"NSPaperSize"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)c
{
    [c encodeObject:_URL forKey:@"NSURL"];
    [c encodeBool:_fileExtensionHidden forKey:@"NSFileExtensionHidden"];
    [c encodeObject:_tagNames forKey:@"NSTagNames"];
    [c encodeInteger:_orientation forKey:@"NSOrientation"];
    [c encodeSize:_paperSize forKey:@"NSPaperSize"];
}

@end

@implementation NSPDFPanel {
    NSViewController *_accessoryController;
    NSPDFPanelOptions _options;
    NSString *_defaultFileName;
}

+ (NSPDFPanel *)panel { return [[[self alloc] init] autorelease]; }

- (instancetype)init
{
    if ((self = [super init]))
        _defaultFileName = [@"Untitled" copy];
    return self;
}

- (void)dealloc
{
    [_accessoryController release];
    [_defaultFileName release];
    [super dealloc];
}

- (NSViewController *)accessoryController { return _accessoryController; }
- (void)setAccessoryController:(NSViewController *)c { [_accessoryController autorelease]; _accessoryController = [c retain]; }
- (NSPDFPanelOptions)options { return _options; }
- (void)setOptions:(NSPDFPanelOptions)o { _options = o; }
- (NSString *)defaultFileName { return _defaultFileName; }
- (void)setDefaultFileName:(NSString *)n { [_defaultFileName autorelease]; _defaultFileName = [n copy] ?: [@"" copy]; }

- (void)beginSheetWithPDFInfo:(NSPDFInfo *)info modalForWindow:(NSWindow *)window completionHandler:(void (^)(NSInteger))handler
{
    void (^done)(NSInteger) = [[handler copy] autorelease];
    if (_options & NSPDFPanelRequestsParentDirectory) {
        NSOpenPanel *open = [NSOpenPanel openPanel];
        open.canChooseFiles = NO;
        open.canChooseDirectories = YES;
        open.canCreateDirectories = YES;
        open.prompt = @"Choose";
        open.accessoryView = _accessoryController.view;
        void (^chosen)(NSModalResponse) = ^(NSModalResponse r) {
            if (r == NSModalResponseOK)
                info.URL = open.URL;
            if (done)
                done(r == NSModalResponseOK);
        };
        if (window)
            [open beginSheetModalForWindow:window completionHandler:chosen];
        else
            chosen([open runModal]);
        return;
    }
    NSSavePanel *save = [NSSavePanel savePanel];
    save.allowedContentTypes = @[ UTTypePDF ];
    save.nameFieldStringValue = _defaultFileName;
    save.canSelectHiddenExtension = YES;
    save.showsTagField = YES;
    save.accessoryView = _accessoryController.view;
    void (^saved)(NSModalResponse) = ^(NSModalResponse r) {
        if (r == NSModalResponseOK) {
            info.URL = save.URL;
            info.fileExtensionHidden = save.extensionHidden;
            info.tagNames = save.tagNames ?: @[];
        }
        if (done)
            done(r == NSModalResponseOK);
    };
    if (window)
        [save beginSheetModalForWindow:window completionHandler:saved];
    else
        saved([save runModal]);
}

@end
