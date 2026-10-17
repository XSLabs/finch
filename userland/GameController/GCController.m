// SPDX-License-Identifier: MIT OR Apache-2.0
#import "GCGameControllerPrivate.h"
#import <IOKit/hid/IOHIDKeys.h>
#import <dlfcn.h>

enum {
    GCSnapshotProfileStandard = 1,
    GCSnapshotProfileMicro = 2,
    GCSnapshotProfileExtended = 3
};

static GCKeyboard *coalesced_keyboard;
static NSArray *connected_mice;
static GCMouse *current_mouse;
static BOOL should_monitor_background_events;

@implementation GCController {
    GCPhysicalInputProfile *_physicalInputProfile;
    GCExtendedGamepad *_extendedGamepad;
    GCMicroGamepad *_microGamepad;
    GCGamepad *_gamepad;
    void (^_controllerPausedHandler)(GCController *);
    dispatch_queue_t _handlerQueue;
    GCControllerPlayerIndex _playerIndex;
    BOOL _snapshot;
}

+ (NSArray<GCController *> *)controllers
{
    return [NSArray array];
}

+ (GCController *)current
{
    return nil;
}

+ (BOOL)shouldMonitorBackgroundEvents
{
    @synchronized(self) { return should_monitor_background_events; }
}

+ (void)setShouldMonitorBackgroundEvents:(BOOL)shouldMonitorBackgroundEvents
{
    @synchronized(self) { should_monitor_background_events = shouldMonitorBackgroundEvents; }
}

+ (BOOL)supportsHIDDevice:(IOHIDDeviceRef)device
{
    if (!device)
        return NO;
    typedef CFTypeRef (*GetPropertyFunction)(IOHIDDeviceRef, CFStringRef);
    GetPropertyFunction getProperty = (GetPropertyFunction)dlsym(RTLD_DEFAULT, "IOHIDDeviceGetProperty");
    if (!getProperty)
        return NO;
    CFTypeRef pageValue = getProperty(device, CFSTR(kIOHIDPrimaryUsagePageKey));
    CFTypeRef usageValue = getProperty(device, CFSTR(kIOHIDPrimaryUsageKey));
    if (!pageValue || !usageValue || CFGetTypeID(pageValue) != CFNumberGetTypeID() ||
        CFGetTypeID(usageValue) != CFNumberGetTypeID())
        return NO;
    int page = 0, usage = 0;
    CFNumberGetValue((CFNumberRef)pageValue, kCFNumberIntType, &page);
    CFNumberGetValue((CFNumberRef)usageValue, kCFNumberIntType, &usage);
    return page == 0x01 && (usage == 0x04 || usage == 0x05 || usage == 0x08);
}

+ (GCController *)controllerWithExtendedGamepad
{
    return [[[self alloc] _initSnapshotWithProfileKind:GCSnapshotProfileExtended] autorelease];
}

+ (GCController *)controllerWithMicroGamepad
{
    return [[[self alloc] _initSnapshotWithProfileKind:GCSnapshotProfileMicro] autorelease];
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _playerIndex = GCControllerPlayerIndexUnset;
        _handlerQueue = dispatch_get_main_queue();
        dispatch_retain(_handlerQueue);
    }
    return self;
}

- (instancetype)_initSnapshotWithProfileKind:(NSUInteger)kind
{
    self = [self init];
    if (!self)
        return nil;
    _snapshot = YES;
    if (kind == GCSnapshotProfileExtended) {
        _extendedGamepad = [[GCExtendedGamepad alloc] _initWithController:self];
        _physicalInputProfile = [_extendedGamepad retain];
    } else if (kind == GCSnapshotProfileMicro) {
        _microGamepad = [[GCMicroGamepad alloc] _initWithController:self];
        _physicalInputProfile = [_microGamepad retain];
    } else if (kind == GCSnapshotProfileStandard) {
        _gamepad = [[GCGamepad alloc] _initWithController:self];
        _physicalInputProfile = [_gamepad retain];
    }
    [_physicalInputProfile _setDevice:self];
    return self;
}

- (void)_setProfile:(GCPhysicalInputProfile *)profile
{
    if (_physicalInputProfile != profile) {
        [_physicalInputProfile release];
        _physicalInputProfile = [profile retain];
        [_physicalInputProfile _setDevice:self];
    }
}

- (void)dealloc
{
    [_physicalInputProfile release];
    [_extendedGamepad release];
    [_microGamepad release];
    [_gamepad release];
    [_controllerPausedHandler release];
    if (_handlerQueue)
        dispatch_release(_handlerQueue);
    [super dealloc];
}

- (BOOL)isSnapshot { return _snapshot; }
- (GCControllerPlayerIndex)playerIndex { return _playerIndex; }
- (void)setPlayerIndex:(GCControllerPlayerIndex)index
{
    _playerIndex = index < GCControllerPlayerIndexUnset ? GCControllerPlayerIndexUnset : index;
}

- (void (^)(GCController *))controllerPausedHandler { return _controllerPausedHandler; }
- (void)setControllerPausedHandler:(void (^)(GCController *))handler
{
    if (_controllerPausedHandler != handler) {
        [_controllerPausedHandler release];
        _controllerPausedHandler = [handler copy];
    }
}

- (BOOL)isAttachedToDevice { return NO; }
- (GCPhysicalInputProfile *)physicalInputProfile { return _physicalInputProfile; }
- (GCExtendedGamepad *)extendedGamepad { return _extendedGamepad; }
- (GCMicroGamepad *)microGamepad { return _microGamepad; }
- (GCGamepad *)gamepad { return _gamepad; }
- (GCMotion *)motion { return nil; }
- (GCDeviceBattery *)battery { return nil; }
- (GCDeviceLight *)light { return nil; }
- (GCDeviceHaptics *)haptics { return nil; }
- (GCControllerLiveInput *)input { return nil; }
- (NSString *)vendorName { return nil; }
- (NSString *)productCategory { return GCProductCategoryHID; }

- (dispatch_queue_t)handlerQueue { return _handlerQueue; }
- (void)setHandlerQueue:(dispatch_queue_t)queue
{
    if (!queue)
        queue = dispatch_get_main_queue();
    if (_handlerQueue != queue) {
        dispatch_retain(queue);
        if (_handlerQueue)
            dispatch_release(_handlerQueue);
        _handlerQueue = queue;
    }
}

- (GCController *)capture
{
    NSUInteger kind = _extendedGamepad ? GCSnapshotProfileExtended :
                      _microGamepad ? GCSnapshotProfileMicro :
                      _gamepad ? GCSnapshotProfileStandard : 0;
    if (!kind)
        return nil;
    GCController *copy = [[[GCController alloc] _initSnapshotWithProfileKind:kind] autorelease];
    [copy->_physicalInputProfile _setStateFromProfile:_physicalInputProfile];
    return copy;
}

@end

@implementation GCKeyboard {
    GCKeyboardInput *_keyboardInput;
    dispatch_queue_t _handlerQueue;
}

+ (GCKeyboard *)coalescedKeyboard
{
    @synchronized(self) { return coalesced_keyboard; }
}

+ (GCKeyboard *)_keyboardForInputEvent
{
    @synchronized(self) {
        if (!coalesced_keyboard) {
            coalesced_keyboard = [[self alloc] init];
            [[NSNotificationCenter defaultCenter] postNotificationName:GCKeyboardDidConnectNotification
                                                                object:coalesced_keyboard];
        }
        return coalesced_keyboard;
    }
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _handlerQueue = dispatch_get_main_queue();
        dispatch_retain(_handlerQueue);
        _keyboardInput = [[GCKeyboardInput alloc] _initWithKeyboard:self];
    }
    return self;
}

- (void)dealloc
{
    [_keyboardInput release];
    if (_handlerQueue)
        dispatch_release(_handlerQueue);
    [super dealloc];
}

- (GCKeyboardInput *)keyboardInput { return _keyboardInput; }
- (NSString *)vendorName { return nil; }
- (NSString *)productCategory { return GCProductCategoryKeyboard; }
- (GCPhysicalInputProfile *)physicalInputProfile { return _keyboardInput; }
- (dispatch_queue_t)handlerQueue { return _handlerQueue; }
- (void)setHandlerQueue:(dispatch_queue_t)queue
{
    if (!queue)
        queue = dispatch_get_main_queue();
    if (_handlerQueue != queue) {
        dispatch_retain(queue);
        if (_handlerQueue)
            dispatch_release(_handlerQueue);
        _handlerQueue = queue;
    }
}

@end

@implementation GCMouse {
    GCMouseInput *_mouseInput;
    dispatch_queue_t _handlerQueue;
}

+ (NSArray<GCMouse *> *)mice
{
    @synchronized(self) { return connected_mice ?: [NSArray array]; }
}

+ (GCMouse *)current
{
    @synchronized(self) { return current_mouse; }
}

+ (GCMouse *)_mouseForInputEvent
{
    @synchronized(self) {
        if (!connected_mice) {
            current_mouse = [[self alloc] init];
            connected_mice = [[NSArray alloc] initWithObjects:current_mouse, nil];
            [[NSNotificationCenter defaultCenter] postNotificationName:GCMouseDidConnectNotification object:current_mouse];
            [[NSNotificationCenter defaultCenter] postNotificationName:GCMouseDidBecomeCurrentNotification object:current_mouse];
        }
        return current_mouse;
    }
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _handlerQueue = dispatch_get_main_queue();
        dispatch_retain(_handlerQueue);
        _mouseInput = [[GCMouseInput alloc] _initWithMouse:self];
    }
    return self;
}

- (void)dealloc
{
    [_mouseInput release];
    if (_handlerQueue)
        dispatch_release(_handlerQueue);
    [super dealloc];
}

- (GCMouseInput *)mouseInput { return _mouseInput; }
- (NSString *)vendorName { return nil; }
- (NSString *)productCategory { return GCProductCategoryMouse; }
- (GCPhysicalInputProfile *)physicalInputProfile { return _mouseInput; }
- (dispatch_queue_t)handlerQueue { return _handlerQueue; }
- (void)setHandlerQueue:(dispatch_queue_t)queue
{
    if (!queue)
        queue = dispatch_get_main_queue();
    if (_handlerQueue != queue) {
        dispatch_retain(queue);
        if (_handlerQueue)
            dispatch_release(_handlerQueue);
        _handlerQueue = queue;
    }
}

@end
