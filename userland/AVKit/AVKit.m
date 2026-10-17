// SPDX-License-Identifier: MIT OR Apache-2.0
#import <AVKit/AVKit.h>
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

@interface AVPlayerView (FinchPrivate)
- (void)_updatePlayerLayer;
- (void)_updateControls;
- (void)_togglePlayback:(id)sender;
- (void)_toggleFullScreen:(id)sender;
@end

@implementation AVPlayerView {
@public
    AVPlayer *_fplayer;
    AVPlayerLayer *_fplayerLayer;
    NSView *_foverlay;
    NSView *_fcontrols;
    NSButton *_fplayButton;
    NSButton *_ffullScreenButton;
    AVPlayerViewControlsStyle _fcontrolsStyle;
    AVLayerVideoGravity _fvideoGravity;
    id<AVPlayerViewDelegate> _fdelegate;
    NSArray *_fspeeds;
    AVPlaybackSpeed *_fselectedSpeed;
    NSMenu *_factionMenu;
    AVDisplayDynamicRange _fdynamicRange;
    AVVideoFrameAnalysisType _fanalysisTypes;
    CGFloat _fmagnification;
    BOOL _fupdatesNowPlaying;
    BOOL _fshowsFrameStep, _fshowsShare, _fshowsFullscreen, _fshowsTimecodes;
    BOOL _fanalysis, _fcanMagnify, _fallowsPiP;
}
- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        _fcontrolsStyle = AVPlayerViewControlsStyleInline;
        _fvideoGravity = AVLayerVideoGravityResizeAspect;
        _fmagnification = 1.0;
        _fupdatesNowPlaying = YES;
        _fanalysis = YES;
        self.wantsLayer = YES;
        _foverlay = [[NSView alloc] initWithFrame:self.bounds];
        _foverlay.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self addSubview:_foverlay];
        _fcontrols = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(frame), 38)];
        _fcontrols.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
        _fplayButton = [[NSButton alloc] initWithFrame:NSMakeRect(8, 7, 62, 24)];
        _fplayButton.bezelStyle = NSBezelStyleRounded;
        _fplayButton.target = self; _fplayButton.action = @selector(_togglePlayback:);
        [_fcontrols addSubview:_fplayButton];
        _ffullScreenButton = [[NSButton alloc] initWithFrame:NSMakeRect(NSWidth(frame) - 82, 7, 74, 24)];
        _ffullScreenButton.autoresizingMask = NSViewMinXMargin;
        _ffullScreenButton.bezelStyle = NSBezelStyleRounded;
        _ffullScreenButton.title = @"Full Screen";
        _ffullScreenButton.target = self; _ffullScreenButton.action = @selector(_toggleFullScreen:);
        [_fcontrols addSubview:_ffullScreenButton];
        [self addSubview:_fcontrols];
        [self _updateControls];
    }
    return self;
}
- (void)dealloc
{
    [_fplayer release]; [_fplayerLayer release]; [_foverlay release]; [_fcontrols release];
    [_fplayButton release]; [_ffullScreenButton release]; [_fspeeds release]; [_fselectedSpeed release]; [_factionMenu release];
    [_fvideoGravity release];
    [super dealloc];
}
- (AVPlayer *)player { return _fplayer; }
- (void)setPlayer:(AVPlayer *)player
{
    if (_fplayer == player) return;
    [_fplayer release]; _fplayer = [player retain];
    [self _updatePlayerLayer]; [self _updateControls];
}
- (void)_updatePlayerLayer
{
    if (!_fplayerLayer) {
        _fplayerLayer = [[AVPlayerLayer playerLayerWithPlayer:_fplayer] retain];
        _fplayerLayer.frame = self.bounds;
        self.layer = _fplayerLayer;
    } else {
        _fplayerLayer.player = _fplayer;
    }
    _fplayerLayer.videoGravity = _fvideoGravity;
    _fplayerLayer.frame = self.bounds;
    [self setNeedsDisplay:YES];
}
- (void)_updateControls
{
    BOOL visible = _fcontrolsStyle != AVPlayerViewControlsStyleNone;
    _fcontrols.hidden = !visible;
    _ffullScreenButton.hidden = !_fshowsFullscreen;
    _fplayButton.enabled = _fplayer != nil;
    _fplayButton.title = _fplayer.rate == 0 ? @"Play" : @"Pause";
    [self setNeedsDisplay:YES];
}
- (void)_togglePlayback:(id)sender
{
    if (_fplayer.rate == 0) [_fplayer play]; else [_fplayer pause];
    [self _updateControls]; (void)sender;
}
- (void)_toggleFullScreen:(id)sender
{
    if (self.inFullScreenMode) [self exitFullScreenModeWithOptions:nil];
    else [self enterFullScreenMode:[NSScreen mainScreen] withOptions:nil];
    (void)sender;
}
- (void)layout
{
    [super layout];
    _fplayerLayer.frame = self.bounds;
    _foverlay.frame = self.bounds;
    _fcontrols.frame = NSMakeRect(0, 0, NSWidth(self.bounds), 38);
    _ffullScreenButton.frame = NSMakeRect(NSWidth(self.bounds) - 82, 7, 74, 24);
}
- (void)drawRect:(NSRect)dirtyRect
{
    [[NSColor blackColor] set]; NSRectFill(dirtyRect);
}
- (AVPlayerViewControlsStyle)controlsStyle { return _fcontrolsStyle; }
- (void)setControlsStyle:(AVPlayerViewControlsStyle)style
{
    if (style < AVPlayerViewControlsStyleNone || style > AVPlayerViewControlsStyleMinimal) return;
    _fcontrolsStyle = style; [self _updateControls];
}
- (AVLayerVideoGravity)videoGravity { return _fvideoGravity; }
- (void)setVideoGravity:(AVLayerVideoGravity)gravity
{
    if (_fvideoGravity != gravity) { [_fvideoGravity release]; _fvideoGravity = [gravity copy]; }
    _fplayerLayer.videoGravity = gravity;
}
- (BOOL)isReadyForDisplay { return _fplayerLayer.isReadyForDisplay; }
- (NSRect)videoBounds { return self.bounds; }
- (NSView *)contentOverlayView { return _foverlay; }
- (BOOL)updatesNowPlayingInfoCenter { return _fupdatesNowPlaying; }
- (void)setUpdatesNowPlayingInfoCenter:(BOOL)value { _fupdatesNowPlaying = value; }
- (id<AVPlayerViewDelegate>)delegate { return _fdelegate; }
- (void)setDelegate:(id<AVPlayerViewDelegate>)delegate { _fdelegate = delegate; }
- (NSArray<AVPlaybackSpeed *> *)speeds { return _fspeeds; }
- (void)setSpeeds:(NSArray<AVPlaybackSpeed *> *)speeds { if (_fspeeds != speeds) { [_fspeeds release]; _fspeeds = [speeds copy]; } }
- (AVPlaybackSpeed *)selectedSpeed { return _fselectedSpeed; }
- (void)selectSpeed:(AVPlaybackSpeed *)speed
{
    if (![_fspeeds containsObject:speed]) return;
    if (_fselectedSpeed != speed) { [_fselectedSpeed release]; _fselectedSpeed = [speed retain]; }
    if (_fplayer) _fplayer.defaultRate = speed.rate;
}
- (BOOL)allowsVideoFrameAnalysis { return _fanalysis; }
- (void)setAllowsVideoFrameAnalysis:(BOOL)value { _fanalysis = value; }
- (AVVideoFrameAnalysisType)videoFrameAnalysisTypes { return _fanalysisTypes; }
- (void)setVideoFrameAnalysisTypes:(AVVideoFrameAnalysisType)value { _fanalysisTypes = value; }
- (BOOL)allowsMagnification { return _fcanMagnify; }
- (void)setAllowsMagnification:(BOOL)value { _fcanMagnify = value; }
- (CGFloat)magnification { return _fmagnification; }
- (void)setMagnification:(CGFloat)value { _fmagnification = MAX(1.0, MIN(64.0, value)); [self setNeedsDisplay:YES]; }
- (void)setMagnification:(CGFloat)value centeredAtPoint:(CGPoint)point { self.magnification = value; (void)point; }
- (AVDisplayDynamicRange)preferredDisplayDynamicRange { return _fdynamicRange; }
- (void)setPreferredDisplayDynamicRange:(AVDisplayDynamicRange)value { _fdynamicRange = value; }
- (BOOL)showsFrameSteppingButtons { return _fshowsFrameStep; }
- (void)setShowsFrameSteppingButtons:(BOOL)value { _fshowsFrameStep = value; }
- (BOOL)showsSharingServiceButton { return _fshowsShare; }
- (void)setShowsSharingServiceButton:(BOOL)value { _fshowsShare = value; }
- (NSMenu *)actionPopUpButtonMenu { return _factionMenu; }
- (void)setActionPopUpButtonMenu:(NSMenu *)menu { if (_factionMenu != menu) { [_factionMenu release]; _factionMenu = [menu retain]; } }
- (BOOL)showsFullScreenToggleButton { return _fshowsFullscreen; }
- (void)setShowsFullScreenToggleButton:(BOOL)value { _fshowsFullscreen = value; [self _updateControls]; }
- (BOOL)showsTimecodes { return _fshowsTimecodes; }
- (void)setShowsTimecodes:(BOOL)value { _fshowsTimecodes = value; }
- (BOOL)allowsPictureInPicturePlayback { return _fallowsPiP && [AVPictureInPictureController isPictureInPictureSupported]; }
- (void)setAllowsPictureInPicturePlayback:(BOOL)value { _fallowsPiP = value; }
- (id<AVPlayerViewPictureInPictureDelegate>)pictureInPictureDelegate { return nil; }
- (void)setPictureInPictureDelegate:(id<AVPlayerViewPictureInPictureDelegate>)delegate { (void)delegate; }
@end

@implementation AVRoutePickerView {
@public
    AVPlayer *_fplayer;
    id<AVRoutePickerViewDelegate> _fdelegate;
    NSMutableDictionary *_fcolors;
    NSColor *_factiveTintColor;
    BOOL _fbordered;
}
- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        _fcolors = [NSMutableDictionary new];
        _fbordered = YES;
        _factiveTintColor = [[NSColor systemBlueColor] retain];
    }
    return self;
}
- (void)dealloc { [_fplayer release]; [_fcolors release]; [_factiveTintColor release]; [super dealloc]; }
- (id<AVRoutePickerViewDelegate>)delegate { return _fdelegate; }
- (void)setDelegate:(id<AVRoutePickerViewDelegate>)delegate { _fdelegate = delegate; }
- (AVPlayer *)player { return _fplayer; }
- (void)setPlayer:(AVPlayer *)player { if (_fplayer != player) { [_fplayer release]; _fplayer = [player retain]; } }
- (NSColor *)routePickerButtonColorForState:(AVRoutePickerViewButtonState)state
{
    NSColor *color = [_fcolors objectForKey:@(state)];
    return color ?: [NSColor disabledControlTextColor];
}
- (void)setRoutePickerButtonColor:(NSColor *)color forState:(AVRoutePickerViewButtonState)state
{
    if (color) [_fcolors setObject:color forKey:@(state)]; else [_fcolors removeObjectForKey:@(state)];
    [self setNeedsDisplay:YES];
}
- (BOOL)isRoutePickerButtonBordered { return _fbordered; }
- (void)setRoutePickerButtonBordered:(BOOL)value { _fbordered = value; [self setNeedsDisplay:YES]; }
- (NSColor *)activeTintColor { return _factiveTintColor ?: [NSColor systemBlueColor]; }
- (void)setActiveTintColor:(NSColor *)color
{
    NSColor *value = color ?: [NSColor systemBlueColor];
    if (_factiveTintColor != value) { [_factiveTintColor release]; _factiveTintColor = [value retain]; }
}
- (NSSize)intrinsicContentSize { return NSMakeSize(32, 32); }
- (NSString *)accessibilityLabel { return @"No playback routes available"; }
- (void)drawRect:(NSRect)dirtyRect
{
    if (_fbordered) {
        [[NSColor controlBackgroundColor] set]; NSBezierPath *background = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 1, 1) xRadius:5 yRadius:5]; [background fill];
    }
    [[self routePickerButtonColorForState:AVRoutePickerViewButtonStateNormal] set];
    NSRect bounds = NSInsetRect(self.bounds, 8, 8);
    NSBezierPath *screen = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(NSMinX(bounds), NSMinY(bounds) + 5, NSWidth(bounds), NSHeight(bounds) - 8) xRadius:2 yRadius:2];
    [screen setLineWidth:1.5]; [screen stroke];
    NSBezierPath *triangle = [NSBezierPath bezierPath];
    [triangle moveToPoint:NSMakePoint(NSMinX(bounds) + NSWidth(bounds) * 0.35, NSMinY(bounds) + 2)];
    [triangle lineToPoint:NSMakePoint(NSMinX(bounds) + NSWidth(bounds) * 0.5, NSMinY(bounds) + 8)];
    [triangle lineToPoint:NSMakePoint(NSMinX(bounds) + NSWidth(bounds) * 0.65, NSMinY(bounds) + 2)];
    [triangle closePath]; [triangle fill];
    (void)dirtyRect;
}
@end

// These initializers intentionally refuse construction because Finch has no PiP
// window service. Clang's designated-initializer warning does not model that case.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-designated-initializers"
@implementation AVPictureInPictureController {
@public
    AVPlayerLayer *_fplayerLayer;
    id<AVPictureInPictureControllerDelegate> _fdelegate;
    AVPictureInPictureControllerContentSource *_fcontentSource;
    BOOL _flinearPlayback;
}
+ (BOOL)isPictureInPictureSupported { return NO; }
static NSImage *AVPiPButtonImage(BOOL start)
{
    static NSImage *startImage;
    static NSImage *stopImage;
    @synchronized([AVPictureInPictureController class]) {
        NSImage **slot = start ? &startImage : &stopImage;
        if (!*slot) {
            NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(24, 24)];
            [image lockFocus];
            [[NSColor blackColor] setStroke];
            NSBezierPath *frame = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(2.5, 3.5, 19, 16) xRadius:2 yRadius:2];
            [frame setLineWidth:1.7]; [frame stroke];
            if (start) {
                [[NSColor blackColor] setFill];
                NSBezierPath *play = [NSBezierPath bezierPath];
                [play moveToPoint:NSMakePoint(10, 8)]; [play lineToPoint:NSMakePoint(16, 11.5)];
                [play lineToPoint:NSMakePoint(10, 15)]; [play closePath]; [play fill];
            } else {
                [[NSColor blackColor] setFill];
                NSRectFill(NSMakeRect(8, 8, 2.5, 7)); NSRectFill(NSMakeRect(13.5, 8, 2.5, 7));
            }
            [image unlockFocus];
            image.template = YES;
            *slot = image;
        }
        return *slot;
    }
}
+ (NSImage *)pictureInPictureButtonStartImage { return AVPiPButtonImage(YES); }
+ (NSImage *)pictureInPictureButtonStopImage { return AVPiPButtonImage(NO); }
- (instancetype)init
{
    [self release];
    return nil;
}
- (instancetype)initWithPlayerLayer:(AVPlayerLayer *)playerLayer
{
    (void)playerLayer;
    [self release];
    return nil;
}
- (instancetype)initWithContentSource:(AVPictureInPictureControllerContentSource *)contentSource
{
    (void)contentSource;
    [self release];
    return nil;
}
- (void)dealloc { [_fplayerLayer release]; [_fcontentSource release]; [super dealloc]; }
- (AVPlayerLayer *)playerLayer { return _fplayerLayer; }
- (AVPictureInPictureControllerContentSource *)contentSource { return _fcontentSource; }
- (void)setContentSource:(AVPictureInPictureControllerContentSource *)source
{
    if (_fcontentSource != source) { [_fcontentSource release]; _fcontentSource = [source retain]; }
}
- (id<AVPictureInPictureControllerDelegate>)delegate { return _fdelegate; }
- (void)setDelegate:(id<AVPictureInPictureControllerDelegate>)delegate { _fdelegate = delegate; }
- (void)startPictureInPicture { }
- (void)stopPictureInPicture { }
- (BOOL)isPictureInPicturePossible { return NO; }
- (BOOL)isPictureInPictureActive { return NO; }
- (BOOL)isPictureInPictureSuspended { return NO; }
- (BOOL)requiresLinearPlayback { return _flinearPlayback; }
- (void)setRequiresLinearPlayback:(BOOL)value { _flinearPlayback = value; }
- (void)invalidatePlaybackState { }
@end
#pragma clang diagnostic pop
