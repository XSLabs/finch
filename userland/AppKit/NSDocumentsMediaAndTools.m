/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AppKit classes around documents, media and system tools:
 *
 * - NSPersistentDocument, a document kept in a Core Data store (Core Data is reached at
 *   run time, so AppKit does not link it);
 * - NSTouch; the legacy image reps NSCachedImageRep, NSEPSImageRep and NSPICTImageRep
 *   (as on current macOS, EPS data no longer makes a rep, and a PICT is only measured);
 * - Writing Tools' coordinator, context, preview and animation parameters (Finch has no
 *   Writing Tools service, so it reports them unavailable);
 * - NSWorkspaceAuthorization, NSAlignmentFeedbackFilter, NSBackgroundExtensionView,
 *   NSFontAssetRequest, NSMediaLibraryBrowserController, NSMovie, NSSpeechRecognizer,
 *   NSTextCheckingController, NSInputServer and the OpenGL layer and pixel buffer.
 */
#import <AppKit/AppKit.h>
#import <CoreData/CoreData.h>
#import <Security/Authorization.h>
#import <objc/runtime.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

/* MARK: - NSPersistentDocument */

@implementation NSPersistentDocument {
    NSManagedObjectContext *_context;
    NSManagedObjectModel *_model;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_context release];
    [_model release];
    [super dealloc];
}

- (NSManagedObjectModel *)managedObjectModel
{
    if (!_model) {
        Class modelClass = NSClassFromString(@"NSManagedObjectModel");
        _model = [[modelClass mergedModelFromBundles:nil] retain] ?: [[modelClass alloc] init];
    }
    return _model;
}

- (NSManagedObjectContext *)managedObjectContext
{
    if (!_context) {
        NSPersistentStoreCoordinator *coordinator = [[[NSClassFromString(@"NSPersistentStoreCoordinator") alloc]
                                                       initWithManagedObjectModel:[self managedObjectModel]] autorelease];
        NSManagedObjectContext *context = [[[NSClassFromString(@"NSManagedObjectContext") alloc]
                                             initWithConcurrencyType:NSMainQueueConcurrencyType] autorelease];
        [context setPersistentStoreCoordinator:coordinator];
        [self setManagedObjectContext:context];
    }
    return _context;
}

- (void)setManagedObjectContext:(NSManagedObjectContext *)context
{
    if (context == _context) return;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    if (_context) [center removeObserver:self name:NSManagedObjectContextObjectsDidChangeNotification object:_context];
    [_context release];
    _context = [context retain];
    if (_context) {
        [_context setUndoManager:[self undoManager]];
        [center addObserver:self selector:@selector(_finchContextChanged:) name:NSManagedObjectContextObjectsDidChangeNotification object:_context];
    }
}

- (void)_finchContextChanged:(NSNotification *)notification
{
    (void)notification;
    if ([_context hasChanges] && ![self isDocumentEdited] && ![self undoManager]) [self updateChangeCount:NSChangeDone];
}

- (NSString *)persistentStoreTypeForFileType:(NSString *)fileType
{
    (void)fileType;
    return @"XML";
}

- (BOOL)configurePersistentStoreCoordinatorForURL:(NSURL *)url ofType:(NSString *)fileType modelConfiguration:(NSString *)configuration
                                    storeOptions:(NSDictionary *)storeOptions error:(NSError **)error
{
    NSPersistentStoreCoordinator *coordinator = [[self managedObjectContext] persistentStoreCoordinator];
    for (NSPersistentStore *store in [[[coordinator persistentStores] copy] autorelease]) [coordinator removePersistentStore:store error:NULL];
    return [coordinator addPersistentStoreWithType:[self persistentStoreTypeForFileType:fileType] configuration:configuration
                                               URL:url options:storeOptions error:error] != nil;
}

- (BOOL)configurePersistentStoreCoordinatorForURL:(NSURL *)url ofType:(NSString *)fileType error:(NSError **)error
{
    return [self configurePersistentStoreCoordinatorForURL:url ofType:fileType modelConfiguration:nil storeOptions:nil error:error];
}

- (BOOL)readFromURL:(NSURL *)absoluteURL ofType:(NSString *)typeName error:(NSError **)error
{
    return [self configurePersistentStoreCoordinatorForURL:absoluteURL ofType:typeName modelConfiguration:nil storeOptions:nil error:error];
}

- (BOOL)writeToURL:(NSURL *)absoluteURL ofType:(NSString *)typeName forSaveOperation:(NSSaveOperationType)saveOperation
originalContentsURL:(NSURL *)absoluteOriginalContentsURL error:(NSError **)error
{
    (void)absoluteOriginalContentsURL;
    NSManagedObjectContext *context = [self managedObjectContext];
    NSPersistentStoreCoordinator *coordinator = [context persistentStoreCoordinator];
    NSPersistentStore *store = [[coordinator persistentStores] firstObject];
    NSString *storeType = [self persistentStoreTypeForFileType:typeName];
    if (!store) {
        if (![coordinator addPersistentStoreWithType:storeType configuration:nil URL:absoluteURL options:nil error:error]) return NO;
    } else if (![[store URL] isEqual:absoluteURL]) {
        if (saveOperation == NSSaveToOperation || saveOperation == NSAutosaveElsewhereOperation) {
            /* a copy: save, then write the store's contents to the new place */
            if ([context hasChanges] && ![context save:error]) return NO;
            NSPersistentStoreCoordinator *copy = [[[[coordinator class] alloc] initWithManagedObjectModel:[coordinator managedObjectModel]] autorelease];
            NSPersistentStore *source = [copy addPersistentStoreWithType:[store type] configuration:nil URL:[store URL] options:nil error:error];
            return source && [copy migratePersistentStore:source toURL:absoluteURL options:nil withType:storeType error:error] != nil;
        }
        if (![coordinator migratePersistentStore:store toURL:absoluteURL options:nil withType:storeType error:error]) return NO;
    }
    return ![context hasChanges] || [context save:error];
}

- (BOOL)revertToContentsOfURL:(NSURL *)inAbsoluteURL ofType:(NSString *)inTypeName error:(NSError **)outError
{
    [[self managedObjectContext] reset];
    [[self undoManager] removeAllActions];
    if (![self readFromURL:inAbsoluteURL ofType:inTypeName error:outError]) return NO;
    [self updateChangeCount:NSChangeCleared];
    return YES;
}

- (BOOL)isDocumentEdited { return [super isDocumentEdited] || [_context hasChanges]; }

@end

/* MARK: - NSTouch */

@implementation NSTouch {
    id _identity;
    NSTouchPhase _phase;
    NSPoint _position, _location, _previous;
    BOOL _resting;
    id _device;
    NSSize _deviceSize;
    NSTouchType _type;
    NSView *_view;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _identity = [[NSUUID UUID] retain];
        _type = NSTouchTypeIndirect;
    }
    return self;
}

- (void)dealloc
{
    [_identity release];
    [_device release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone { (void)zone; return [self retain]; }
- (id)identity { return _identity; }
- (NSTouchPhase)phase { return _phase; }
- (NSPoint)normalizedPosition { return _position; }
- (BOOL)isResting { return _resting; }
- (id)device { return _device; }
- (NSSize)deviceSize { return _deviceSize; }
- (NSTouchType)type { return _type; }

- (NSPoint)locationInView:(NSView *)view
{
    if (_type != NSTouchTypeDirect)
        [NSException raise:NSInternalInconsistencyException format:@"Cannot get locationInView: for this type of NSTouch"];
    return view ? [view convertPoint:_location fromView:nil] : _location;
}

- (NSPoint)previousLocationInView:(NSView *)view
{
    if (_type != NSTouchTypeDirect)
        [NSException raise:NSInternalInconsistencyException format:@"Cannot get previousLocationInView: for this type of NSTouch"];
    return view ? [view convertPoint:_previous fromView:nil] : _previous;
}

- (NSString *)description
{
    NSPoint location = [self locationInView:nil];
    return [NSString stringWithFormat:@"<%@: %p> Phase: %lu Location: %@", [self class], self, (unsigned long)_phase, NSStringFromPoint(location)];
}

@end

/* MARK: - Legacy image reps */

@implementation NSCachedImageRep {
    NSWindow *_window;
    NSRect _rect;
}

- (id)initWithWindow:(NSWindow *)win rect:(NSRect)rect
{
    if ((self = [super init])) {
        _window = [win retain];
        _rect = rect;
        [self setSize:rect.size];
        [self setPixelsWide:(NSInteger)rect.size.width];
        [self setPixelsHigh:(NSInteger)rect.size.height];
    }
    return self;
}

- (id)initWithSize:(NSSize)size depth:(NSWindowDepth)depth separate:(BOOL)flag alpha:(BOOL)alpha
{
    (void)depth; (void)flag;
    NSWindow *window = [[[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, size.width, size.height) styleMask:NSWindowStyleMaskBorderless
                                                      backing:NSBackingStoreBuffered defer:YES] autorelease];
    if ((self = [self initWithWindow:window rect:NSMakeRect(0, 0, size.width, size.height)])) [self setAlpha:alpha];
    return self;
}

- (void)dealloc
{
    [_window release];
    [super dealloc];
}

- (NSWindow *)window { return _window; }
- (NSRect)rect { return _rect; }
- (BOOL)draw { return YES; }

@end

@implementation NSEPSImageRep
+ (NSArray *)imageUnfilteredTypes { return @[ @"com.adobe.encapsulated-postscript" ]; }
+ (NSArray *)imageUnfilteredFileTypes { return @[ @"eps", @"epi", @"epsf", @"epsi", @"ps" ]; }
/* As on current macOS: PostScript is no longer interpreted, so no rep is made. */
+ (BOOL)canInitWithData:(NSData *)data { (void)data; return NO; }
+ (instancetype)imageRepWithData:(NSData *)epsData { return [[[self alloc] initWithData:epsData] autorelease]; }
- (instancetype)initWithData:(NSData *)epsData
{
    (void)epsData;
    [self release];
    return nil;
}
- (NSRect)boundingBox { return NSZeroRect; }
- (NSData *)EPSRepresentation { return [NSData data]; }
- (void)prepareGState {}
@end

@implementation NSPICTImageRep {
    NSData *_data;
    NSRect _box;
}
+ (NSArray *)imageUnfilteredTypes { return @[ @"com.apple.pict" ]; }
+ (NSArray *)imageUnfilteredFileTypes { return @[ @"pict", @"pct", @"pic" ]; }

/* A picture follows a 512-byte file header or starts the data: a size word, then
   its frame (top, left, bottom, right). */
static NSInteger
pict_offset(NSData *data)
{
    if ([data length] >= 512 + 10) return 512;
    if ([data length] >= 10) return 0;
    return -1;
}

/* (only data with a picture's version opcode: version 1's 0x1101 or version 2's
   0x001102FF after the frame, so other images aren't taken for pictures) */
+ (BOOL)canInitWithData:(NSData *)data
{
    for (NSInteger offset = [data length] >= 512 + 14 ? 512 : 0;; offset = 0) {
        if ((NSInteger)[data length] >= offset + 14) {
            const uint8_t *b = (const uint8_t *)[data bytes] + offset + 10;
            if ((b[0] == 0x11 && b[1] == 0x01) || (b[0] == 0x00 && b[1] == 0x11 && b[2] == 0x02 && b[3] == 0xFF))
                return YES;
        }
        if (offset == 0)
            return NO;
    }
}
+ (NSArray *)imageUnfilteredPasteboardTypes { return @[ @"Apple PICT pasteboard type" ]; }
+ (instancetype)imageRepWithData:(NSData *)pictData { return [[[self alloc] initWithData:pictData] autorelease]; }

- (instancetype)initWithData:(NSData *)pictData
{
    NSInteger offset = pict_offset(pictData);
    if (offset < 0 || !(self = [super init])) {
        [self release];
        return nil;
    }
    _data = [pictData copy];
    const uint8_t *b = (const uint8_t *)[pictData bytes] + offset;
    int16_t top = (int16_t)(b[2] << 8 | b[3]), left = (int16_t)(b[4] << 8 | b[5]);
    /* QuickDraw is gone: the frame's origin is all that is read */
    _box = NSMakeRect(left, top, 0, 0);
    return self;
}

- (void)dealloc
{
    [_data release];
    [super dealloc];
}

- (NSData *)PICTRepresentation { return _data; }
- (NSRect)boundingBox { return _box; }
- (BOOL)draw { return NO; }
@end

/* MARK: - Writing Tools */

@implementation NSWritingToolsCoordinator {
    id _delegate;
    NSView *_view, *_effect, *_decoration;
    NSWritingToolsBehavior _preferredBehavior;
    NSWritingToolsResultOptions _preferredResults;
    BOOL _markers;
}

/* Finch has no Writing Tools service. */
+ (BOOL)isWritingToolsAvailable { return NO; }

- (instancetype)initWithDelegate:(id<NSWritingToolsCoordinatorDelegate>)delegate
{
    if ((self = [super init])) _delegate = delegate;
    return self;
}

- (id<NSWritingToolsCoordinatorDelegate>)delegate { return _delegate; }
- (NSView *)view { return _view; }
- (void)_setView:(NSView *)view { _view = view; }
- (NSView *)effectContainerView { return _effect; }
- (void)setEffectContainerView:(NSView *)view { _effect = view; }
- (NSView *)decorationContainerView { return _decoration; }
- (void)setDecorationContainerView:(NSView *)view { _decoration = view; }
- (NSWritingToolsCoordinatorState)state { return NSWritingToolsCoordinatorStateInactive; }
- (void)stopWritingTools {}
- (NSWritingToolsBehavior)preferredBehavior { return _preferredBehavior; }
- (void)setPreferredBehavior:(NSWritingToolsBehavior)behavior { _preferredBehavior = behavior; }
- (NSWritingToolsBehavior)behavior { return NSWritingToolsBehaviorNone; }
- (NSWritingToolsResultOptions)preferredResultOptions { return _preferredResults; }
- (void)setPreferredResultOptions:(NSWritingToolsResultOptions)options { _preferredResults = options; }
- (NSWritingToolsResultOptions)resultOptions
{
    return _preferredResults ?: (NSWritingToolsResultPlainText | NSWritingToolsResultRichText | NSWritingToolsResultList | NSWritingToolsResultTable);
}
- (BOOL)includesTextListMarkers { return _markers; }
- (void)setIncludesTextListMarkers:(BOOL)value { _markers = value; }
- (void)updateRange:(NSRange)range withText:(NSAttributedString *)replacementText reason:(NSWritingToolsCoordinatorTextUpdateReason)reason
    forContextWithIdentifier:(NSUUID *)contextID
{
    (void)range; (void)replacementText; (void)reason; (void)contextID;
}
- (void)updateForReflowedTextInContextWithIdentifier:(NSUUID *)contextID { (void)contextID; }

@end

@implementation NSWritingToolsCoordinatorContext {
    NSAttributedString *_string;
    NSRange _range;
    NSUUID *_identifier;
}

- (instancetype)initWithAttributedString:(NSAttributedString *)attributedString range:(NSRange)range
{
    if ((self = [super init])) {
        _string = [attributedString copy];
        _range = range;
        _identifier = [[NSUUID alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [_string release];
    [_identifier release];
    [super dealloc];
}

- (NSAttributedString *)attributedString { return _string; }
- (NSRange)range { return _range; }
- (NSUUID *)identifier { return _identifier; }
- (NSRange)resolvedRange { return _range; }

@end

@implementation NSWritingToolsCoordinatorAnimationParameters {
    void (^_progress)(float);
    void (^_completion)(void);
}
- (CGFloat)duration { return 0; }
- (CGFloat)delay { return 0; }
- (void (^)(float))progressHandler { return _progress; }
- (void)setProgressHandler:(void (^)(float))handler { [_progress release]; _progress = [handler copy]; }
- (void (^)(void))completionHandler { return _completion; }
- (void)setCompletionHandler:(void (^)(void))handler { [_completion release]; _completion = [handler copy]; }
- (void)dealloc
{
    [_progress release];
    [_completion release];
    [super dealloc];
}
@end

@implementation NSTextPreview {
    CGImageRef _image;
    NSRect _frame;
    NSArray *_rects;
}

- (instancetype)initWithSnapshotImage:(CGImageRef)snapshotImage presentationFrame:(NSRect)presentationFrame candidateRects:(NSArray *)candidateRects
{
    if ((self = [super init])) {
        _image = CGImageRetain(snapshotImage);
        _frame = presentationFrame;
        _rects = [candidateRects copy] ?: [[NSArray alloc] init];
    }
    return self;
}

- (instancetype)initWithSnapshotImage:(CGImageRef)snapshotImage presentationFrame:(NSRect)presentationFrame
{
    return [self initWithSnapshotImage:snapshotImage presentationFrame:presentationFrame candidateRects:@[]];
}

- (void)dealloc
{
    CGImageRelease(_image);
    [_rects release];
    [super dealloc];
}

- (CGImageRef)previewImage { return _image; }
- (NSRect)presentationFrame { return _frame; }
- (NSArray *)candidateRects { return _rects; }

@end

/* MARK: - NSWorkspaceAuthorization */

@implementation NSWorkspaceAuthorization {
    AuthorizationRef _authorization;
    NSWorkspaceAuthorizationType _type;
}

- (instancetype)_initWithAuthorization:(AuthorizationRef)authorization type:(NSWorkspaceAuthorizationType)type
{
    if ((self = [super init])) {
        _authorization = authorization;
        _type = type;
    }
    return self;
}

- (void)dealloc
{
    if (_authorization) AuthorizationFree(_authorization, kAuthorizationFlagDefaults);
    [super dealloc];
}

- (AuthorizationRef)_authorization { return _authorization; }

@end

@implementation NSWorkspace (NSWorkspaceAuthorization)

/* The right for each kind of change, asked of the authorization service (Finch's authd). */
- (void)requestAuthorizationOfType:(NSWorkspaceAuthorizationType)type
                 completionHandler:(void (^)(NSWorkspaceAuthorization *authorization, NSError *error))completionHandler
{
    static const char *const rights[] = { "system.preferences", "system.install.software", "system.privilege.admin" };
    const char *right = type <= NSWorkspaceAuthorizationTypeReplaceFile ? rights[type] : rights[2];
    AuthorizationItem item = { right, 0, NULL, 0 };
    AuthorizationRights requested = { 1, &item };
    AuthorizationRef authorization = NULL;
    OSStatus status = AuthorizationCreate(&requested, kAuthorizationEmptyEnvironment,
                                          kAuthorizationFlagInteractionAllowed | kAuthorizationFlagExtendRights | kAuthorizationFlagPreAuthorize,
                                          &authorization);
    NSWorkspaceAuthorization *result = nil;
    NSError *error = nil;
    if (status == errAuthorizationSuccess)
        result = [[[NSWorkspaceAuthorization alloc] _initWithAuthorization:authorization type:type] autorelease];
    else {
        if (authorization) AuthorizationFree(authorization, kAuthorizationFlagDefaults);
        error = [NSError errorWithDomain:NSCocoaErrorDomain code:status == errAuthorizationCanceled ? NSUserCancelledError : NSFileWriteNoPermissionError
                                userInfo:nil];
    }
    if (completionHandler) completionHandler(result, error);
}

@end

@implementation NSFileManager (NSWorkspaceAuthorization)

static char authorization_key;

+ (instancetype)fileManagerWithAuthorization:(NSWorkspaceAuthorization *)authorization
{
    NSFileManager *manager = [[[self alloc] init] autorelease];
    objc_setAssociatedObject(manager, &authorization_key, authorization, OBJC_ASSOCIATION_RETAIN);
    return manager;
}

@end

/* MARK: - Smaller classes */

@interface FinchAlignmentFeedbackToken : NSObject <NSAlignmentFeedbackToken>
@end
@implementation FinchAlignmentFeedbackToken
@end

@implementation NSAlignmentFeedbackFilter
+ (NSEventMask)inputEventMask
{
    return NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged | NSEventMaskFlagsChanged | NSEventMaskPeriodic;
}
- (void)updateWithEvent:(NSEvent *)event { (void)event; }
- (void)updateWithPanRecognizer:(NSPanGestureRecognizer *)panRecognizer { (void)panRecognizer; }
- (id<NSAlignmentFeedbackToken>)alignmentFeedbackTokenForMovementInView:(NSView *)view previousPoint:(NSPoint)previousPoint
                                                           alignedPoint:(NSPoint)alignedPoint defaultPoint:(NSPoint)defaultPoint
{
    (void)view; (void)previousPoint; (void)alignedPoint; (void)defaultPoint;
    return [[[FinchAlignmentFeedbackToken alloc] init] autorelease];
}
- (id<NSAlignmentFeedbackToken>)alignmentFeedbackTokenForHorizontalMovementInView:(NSView *)view previousX:(CGFloat)previousX
                                                                         alignedX:(CGFloat)alignedX defaultX:(CGFloat)defaultX
{
    (void)view; (void)previousX; (void)alignedX; (void)defaultX;
    return [[[FinchAlignmentFeedbackToken alloc] init] autorelease];
}
- (id<NSAlignmentFeedbackToken>)alignmentFeedbackTokenForVerticalMovementInView:(NSView *)view previousY:(CGFloat)previousY
                                                                       alignedY:(CGFloat)alignedY defaultY:(CGFloat)defaultY
{
    (void)view; (void)previousY; (void)alignedY; (void)defaultY;
    return [[[FinchAlignmentFeedbackToken alloc] init] autorelease];
}
/* No haptic hardware to drive. */
- (void)performFeedback:(NSArray *)alignmentFeedbackTokens performanceTime:(NSHapticFeedbackPerformanceTime)performanceTime
{
    (void)alignmentFeedbackTokens; (void)performanceTime;
}
@end

@implementation NSBackgroundExtensionView {
    NSView *_contentView;
    BOOL _automatic;
}

- (instancetype)initWithFrame:(NSRect)frameRect
{
    if ((self = [super initWithFrame:frameRect])) _automatic = YES;
    return self;
}

- (void)dealloc
{
    [_contentView release];
    [super dealloc];
}

- (NSView *)contentView { return _contentView; }

- (void)setContentView:(NSView *)view
{
    if (view == _contentView) return;
    [_contentView removeFromSuperview];
    [_contentView release];
    _contentView = [view retain];
    if (view) {
        [self addSubview:view];
        [self setNeedsLayout:YES];
    }
}

- (BOOL)automaticallyPlacesContentView { return _automatic; }
- (void)setAutomaticallyPlacesContentView:(BOOL)value { _automatic = value; [self setNeedsLayout:YES]; }

/* The content fills the safe area; the area outside it shows the extended background. */
- (void)layout
{
    [super layout];
    if (_automatic && _contentView) [_contentView setFrame:[self safeAreaRect]];
}

@end

@implementation NSFontAssetRequest {
    NSArray *_descriptors;
    NSArray *_downloaded;
    NSProgress *_progress;
}

- (instancetype)initWithFontDescriptors:(NSArray *)fontDescriptors options:(NSFontAssetRequestOptions)options
{
    (void)options;
    if ((self = [super init])) {
        _descriptors = [fontDescriptors copy];
        _downloaded = [[NSArray alloc] init];
        _progress = [[NSProgress progressWithTotalUnitCount:1] retain];
    }
    return self;
}

- (void)dealloc
{
    [_descriptors release];
    [_downloaded release];
    [_progress release];
    [super dealloc];
}

- (NSArray *)downloadedFontDescriptors { return _downloaded; }
- (NSProgress *)progress { return _progress; }

/* Finch has no font asset service: installed fonts are already there, others never come. */
- (void)downloadFontAssetsWithCompletionHandler:(BOOL (^)(NSError *error))completionHandler
{
    NSMutableArray *missing = [NSMutableArray array];
    NSMutableArray *found = [NSMutableArray array];
    for (NSFontDescriptor *descriptor in _descriptors)
        [([NSFont fontWithDescriptor:descriptor size:0] ? found : missing) addObject:descriptor];
    [_downloaded release];
    _downloaded = [found copy];
    [_progress setCompletedUnitCount:1];
    NSError *error = [missing count] ? [NSError errorWithDomain:NSCocoaErrorDomain code:NSFontAssetDownloadError
                                                       userInfo:@{ NSLocalizedDescriptionKey : @"The fonts could not be downloaded." }] : nil;
    if (completionHandler) {
        void (^handler)(NSError *) = [[completionHandler copy] autorelease];
        dispatch_async(dispatch_get_main_queue(), ^{ handler(error); });
    }
}

@end

@implementation NSMediaLibraryBrowserController {
    BOOL _visible;
    NSRect _frame;
    NSMediaLibrary _libraries;
}
+ (NSMediaLibraryBrowserController *)sharedMediaLibraryBrowserController
{
    static NSMediaLibraryBrowserController *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[NSMediaLibraryBrowserController alloc] init]; });
    return shared;
}
/* There is no media library service to show. */
- (BOOL)isVisible { return _visible; }
- (void)setVisible:(BOOL)visible { _visible = visible; }
- (NSRect)frame { return _frame; }
- (void)setFrame:(NSRect)frame { _frame = frame; }
- (NSMediaLibrary)mediaLibraries { return _libraries; }
- (void)setMediaLibraries:(NSMediaLibrary)libraries { _libraries = libraries; }
- (IBAction)togglePanel:(id)sender { (void)sender; _visible = !_visible; }
@end

/* As on macOS since 10.15, NSMovie no longer wraps a movie. */
@implementation NSMovie
- (instancetype)init { [self release]; return nil; }
- (instancetype)initWithMovie:(QTMovie *)movie { (void)movie; [self release]; return nil; }
- (instancetype)initWithCoder:(NSCoder *)coder { (void)coder; [self release]; return nil; }
- (void)encodeWithCoder:(NSCoder *)coder { (void)coder; }
- (QTMovie *)QTMovie { return nil; }
@end

/* Finch has no speech recognition service: a recognizer listens but hears nothing. */
@implementation NSSpeechRecognizer {
    id _delegate;
    NSArray *_commands;
    NSString *_title;
    BOOL _foreground, _blocks;
}
- (instancetype)init
{
    if ((self = [super init])) _foreground = YES;
    return self;
}
- (void)dealloc
{
    [_commands release];
    [_title release];
    [super dealloc];
}
- (void)startListening {}
- (void)stopListening {}
- (id<NSSpeechRecognizerDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSSpeechRecognizerDelegate>)delegate { _delegate = delegate; }
- (NSArray *)commands { return _commands; }
- (void)setCommands:(NSArray *)commands { [_commands release]; _commands = [commands copy]; }
- (NSString *)displayedCommandsTitle { return _title; }
- (void)setDisplayedCommandsTitle:(NSString *)title { [_title release]; _title = [title copy]; }
- (BOOL)listensInForegroundOnly { return _foreground; }
- (void)setListensInForegroundOnly:(BOOL)value { _foreground = value; }
- (BOOL)blocksOtherRecognizers { return _blocks; }
- (void)setBlocksOtherRecognizers:(BOOL)value { _blocks = value; }
@end

/* Text checking for a client view: spelling through NSSpellChecker, its findings as the
   client's annotations. */
@implementation NSTextCheckingController {
    id _client;
    NSInteger _tag;
}

- (instancetype)initWithClient:(id<NSTextCheckingClient>)client
{
    if ((self = [super init])) {
        _client = client;
        _tag = [NSSpellChecker uniqueSpellDocumentTag];
    }
    return self;
}

- (id<NSTextCheckingClient>)client { return _client; }
- (void)invalidate { _client = nil; }
- (void)didChangeTextInRange:(NSRange)range { [self considerTextCheckingForRange:range]; }
- (void)insertedTextInRange:(NSRange)range { [self considerTextCheckingForRange:range]; }
- (void)didChangeSelectedRange {}
- (void)considerTextCheckingForRange:(NSRange)range
{
    if ([NSSpellChecker isAutomaticSpellingCorrectionEnabled] || [NSSpellChecker isAutomaticTextReplacementEnabled])
        [self checkTextInRange:range types:NSTextCheckingTypeSpelling options:@{}];
}

- (NSString *)_finchClientString:(NSRange)range
{
    if (![_client respondsToSelector:@selector(attributedSubstringForProposedRange:actualRange:)]) return nil;
    return [[_client attributedSubstringForProposedRange:range actualRange:NULL] string];
}

- (void)checkTextInRange:(NSRange)range types:(NSTextCheckingTypes)checkingTypes options:(NSDictionary *)options
{
    NSString *text = [self _finchClientString:range];
    if (!text) return;
    NSArray *results = [[NSSpellChecker sharedSpellChecker] checkString:text range:NSMakeRange(0, [text length]) types:checkingTypes
                                                                options:options inSpellDocumentWithTag:_tag orthography:NULL wordCount:NULL];
    if (![_client respondsToSelector:@selector(addAnnotations:range:)]) return;
    for (NSTextCheckingResult *result in results)
        if ([result resultType] == NSTextCheckingTypeSpelling)
            [_client addAnnotations:@{ @"NSSpellingState" : (id)@(NSSpellingStateSpellingFlag) }
                              range:NSMakeRange(range.location + [result range].location, [result range].length)];
}

- (void)checkTextInSelection:(id)sender
{
    (void)sender;
    if ([_client respondsToSelector:@selector(selectedRange)]) [self checkTextInRange:[_client selectedRange] types:NSTextCheckingAllSystemTypes options:@{}];
}

- (void)checkTextInDocument:(id)sender
{
    (void)sender;
    if ([_client respondsToSelector:@selector(attributedString)])
        [self checkTextInRange:NSMakeRange(0, [[_client attributedString] length]) types:NSTextCheckingAllSystemTypes options:@{}];
}

- (void)orderFrontSubstitutionsPanel:(id)sender { [[[NSSpellChecker sharedSpellChecker] substitutionsPanel] orderFront:sender]; }
- (void)checkSpelling:(id)sender { [self checkTextInSelection:sender]; }
- (void)showGuessPanel:(id)sender { (void)sender; [[[NSSpellChecker sharedSpellChecker] spellingPanel] orderFront:nil]; }
- (void)changeSpelling:(id)sender
{
    NSString *word = [sender respondsToSelector:@selector(selectedCell)] ? [[sender selectedCell] stringValue] : nil;
    if (word && [_client respondsToSelector:@selector(insertText:replacementRange:)] && [_client respondsToSelector:@selector(selectedRange)])
        [_client insertText:word replacementRange:[_client selectedRange]];
}
- (void)ignoreSpelling:(id)sender
{
    NSString *word = [sender respondsToSelector:@selector(stringValue)] ? [sender stringValue] : nil;
    if (word) [[NSSpellChecker sharedSpellChecker] ignoreWord:word inSpellDocumentWithTag:_tag];
}
- (void)updateCandidates {}

- (NSArray *)validAnnotations
{
    return @[ @"NSAccessibilitySpellingState", @"NSCompletionString", @"NSDataDetection", @"NSDominantLanguageAttributeName",
              @"NSDominantScriptAttributeName", @"NSEmojiCheckingAttributeName", @"NSGrammarCorrections", @"NSGrammarLeftOffset",
              @"NSGrammarRightOffset", @"NSGrammarUserDescription", @"NSGrammarConfidenceScore", @"NSGrammarIssueType",
              @"NSGrammarTargetPair", @"NSIgnoringSubstitution", @"NSLanguageMapAttributeName", @"NSLink", @"NSOrthography",
              @"NSPostEditingCorrection", @"NSReplacedString", @"NSSpellingState", @"NSTemporaryTextCorrection",
              @"NSTextAlternatives", @"NSTextChecked", @"NSTextCompleted", @"NSTextCompletion", @"NSTextCorrection",
              @"NSTextEdited", @"NSTextReplacementAttributeName", @"NSTextReverted" ];
}

- (NSMenu *)menuAtIndex:(NSUInteger)location clickedOnSelection:(BOOL)clickedOnSelection effectiveRange:(NSRangePointer)effectiveRange
{
    (void)clickedOnSelection;
    if (effectiveRange) *effectiveRange = NSMakeRange(location, 0);
    return nil;
}

- (NSInteger)spellCheckerDocumentTag { return _tag; }
- (void)setSpellCheckerDocumentTag:(NSInteger)tag { _tag = tag; }

@end

/* The pre-10.6 input server: kept for its API; input methods are not loaded through it. */
@implementation NSInputServer
- (instancetype)initWithDelegate:(id)delegate name:(NSString *)name { (void)delegate; (void)name; return [super init]; }
- (void)insertText:(id)string client:(id)sender { (void)string; (void)sender; }
- (void)doCommandBySelector:(SEL)selector client:(id)sender { (void)selector; (void)sender; }
- (void)markedTextAbandoned:(id)sender { (void)sender; }
- (void)markedTextSelectionChanged:(NSRange)newSel client:(id)sender { (void)newSel; (void)sender; }
- (void)terminate:(id)sender { (void)sender; }
- (BOOL)canBeDisabled { return YES; }
- (BOOL)wantsToInterpretAllKeystrokes { return NO; }
- (BOOL)wantsToHandleMouseEvents { return NO; }
- (BOOL)wantsToDelayTextChangeNotifications { return NO; }
- (void)inputClientBecomeActive:(id)sender { (void)sender; }
- (void)inputClientResignActive:(id)sender { (void)sender; }
- (void)inputClientEnabled:(id)sender { (void)sender; }
- (void)inputClientDisabled:(id)sender { (void)sender; }
- (void)activeConversationWillChange:(id)sender fromOldConversation:(NSInteger)oldConversation { (void)sender; (void)oldConversation; }
- (void)activeConversationChanged:(id)sender toNewConversation:(NSInteger)newConversation { (void)sender; (void)newConversation; }
- (BOOL)mouseDownOnCharacterIndex:(NSUInteger)index atCoordinate:(NSPoint)point withModifier:(NSUInteger)flags client:(id)sender
{
    (void)index; (void)point; (void)flags; (void)sender;
    return NO;
}
- (BOOL)mouseDraggedOnCharacterIndex:(NSUInteger)index atCoordinate:(NSPoint)point withModifier:(NSUInteger)flags client:(id)sender
{
    (void)index; (void)point; (void)flags; (void)sender;
    return NO;
}
- (void)mouseUpOnCharacterIndex:(NSUInteger)index atCoordinate:(NSPoint)point withModifier:(NSUInteger)flags client:(id)sender
{
    (void)index; (void)point; (void)flags; (void)sender;
}
@end
