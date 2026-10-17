// SPDX-License-Identifier: MIT OR Apache-2.0
#import "GCGameControllerPrivate.h"

static void GCInputDispatchHandler(id<GCDevice> device, dispatch_block_t handler)
{
    dispatch_queue_t queue = device.handlerQueue;
    if (!queue)
        queue = dispatch_get_main_queue();
    dispatch_async(queue, handler);
}

static GCControllerButtonInput *GCInputMakeButton(NSString *alias)
{
    return [[[GCControllerButtonInput alloc] _initWithAlias:alias collection:nil analog:NO owner:nil] autorelease];
}

static GCDeviceCursor *GCInputMakeCursor(NSString *alias)
{
    return [[[GCDeviceCursor alloc] _initWithAlias:alias owner:nil analog:YES] autorelease];
}

typedef struct {
    GCKeyCode code;
    NSString *name;
} GCKeyboardKey;

#define KEY(codeValue, keyName) { codeValue, @#keyName }
static const GCKeyboardKey keyboardKeys[] = {
    KEY(4, A), KEY(5, B), KEY(6, C), KEY(7, D), KEY(8, E), KEY(9, F),
    KEY(10, G), KEY(11, H), KEY(12, I), KEY(13, J), KEY(14, K), KEY(15, L),
    KEY(16, M), KEY(17, N), KEY(18, O), KEY(19, P), KEY(20, Q), KEY(21, R),
    KEY(22, S), KEY(23, T), KEY(24, U), KEY(25, V), KEY(26, W), KEY(27, X),
    KEY(28, Y), KEY(29, Z), KEY(30, One), KEY(31, Two), KEY(32, Three), KEY(33, Four),
    KEY(34, Five), KEY(35, Six), KEY(36, Seven), KEY(37, Eight), KEY(38, Nine), KEY(39, Zero),
    KEY(40, ReturnOrEnter), KEY(41, Escape), KEY(42, DeleteOrBackspace),
    KEY(43, Tab), KEY(44, Spacebar), KEY(45, Hyphen), KEY(46, EqualSign),
    KEY(47, OpenBracket), KEY(48, CloseBracket), KEY(49, Backslash),
    KEY(50, NonUSPound), KEY(51, Semicolon), KEY(52, Quote),
    KEY(53, GraveAccentAndTilde), KEY(54, Comma), KEY(55, Period),
    KEY(56, Slash), KEY(57, CapsLock), KEY(58, F1), KEY(59, F2), KEY(60, F3),
    KEY(61, F4), KEY(62, F5), KEY(63, F6), KEY(64, F7), KEY(65, F8), KEY(66, F9),
    KEY(67, F10), KEY(68, F11), KEY(69, F12), KEY(104, F13), KEY(105, F14), KEY(106, F15),
    KEY(107, F16), KEY(108, F17), KEY(109, F18), KEY(110, F19), KEY(111, F20),
    KEY(70, PrintScreen), KEY(71, ScrollLock), KEY(72, Pause), KEY(73, Insert),
    KEY(74, Home), KEY(75, PageUp), KEY(76, DeleteForward), KEY(77, End), KEY(78, PageDown),
    KEY(79, RightArrow), KEY(80, LeftArrow), KEY(81, DownArrow), KEY(82, UpArrow),
    KEY(83, KeypadNumLock), KEY(84, KeypadSlash), KEY(85, KeypadAsterisk),
    KEY(86, KeypadHyphen), KEY(87, KeypadPlus), KEY(88, KeypadEnter),
    KEY(89, Keypad1), KEY(90, Keypad2), KEY(91, Keypad3), KEY(92, Keypad4),
    KEY(93, Keypad5), KEY(94, Keypad6), KEY(95, Keypad7), KEY(96, Keypad8),
    KEY(97, Keypad9), KEY(98, Keypad0), KEY(99, KeypadPeriod),
    KEY(100, NonUSBackslash), KEY(101, Application), KEY(102, Power),
    KEY(103, KeypadEqualSign), KEY(135, International1), KEY(136, International2),
    KEY(137, International3), KEY(138, International4), KEY(139, International5),
    KEY(140, International6), KEY(141, International7), KEY(142, International8),
    KEY(143, International9), KEY(144, LANG1), KEY(145, LANG2), KEY(146, LANG3),
    KEY(147, LANG4), KEY(148, LANG5), KEY(149, LANG6), KEY(150, LANG7), KEY(151, LANG8),
    KEY(152, LANG9), KEY(224, LeftControl), KEY(225, LeftShift), KEY(226, LeftAlt),
    KEY(227, LeftGUI), KEY(228, RightControl), KEY(229, RightShift),
    KEY(230, RightAlt), KEY(231, RightGUI)
};
#undef KEY

static NSString *GCKeyboardNameForCode(GCKeyCode code)
{
    for (size_t i = 0; i < sizeof(keyboardKeys) / sizeof(keyboardKeys[0]); i++)
        if (keyboardKeys[i].code == code)
            return keyboardKeys[i].name;
    return nil;
}

static GCKeyCode GCKeyboardCodeForVirtualKey(unsigned short keyCode)
{
    switch (keyCode) {
    case 0: return GCKeyCodeKeyA; case 1: return GCKeyCodeKeyS; case 2: return GCKeyCodeKeyD;
    case 3: return GCKeyCodeKeyF; case 4: return GCKeyCodeKeyH; case 5: return GCKeyCodeKeyG;
    case 6: return GCKeyCodeKeyZ; case 7: return GCKeyCodeKeyX; case 8: return GCKeyCodeKeyC;
    case 9: return GCKeyCodeKeyV; case 11: return GCKeyCodeKeyB; case 12: return GCKeyCodeKeyQ;
    case 13: return GCKeyCodeKeyW; case 14: return GCKeyCodeKeyE; case 15: return GCKeyCodeKeyR;
    case 16: return GCKeyCodeKeyY; case 17: return GCKeyCodeKeyT; case 18: return GCKeyCodeOne;
    case 19: return GCKeyCodeTwo; case 20: return GCKeyCodeThree; case 21: return GCKeyCodeFour;
    case 22: return GCKeyCodeSix; case 23: return GCKeyCodeFive; case 24: return GCKeyCodeEqualSign;
    case 25: return GCKeyCodeNine; case 26: return GCKeyCodeSeven; case 27: return GCKeyCodeHyphen;
    case 28: return GCKeyCodeEight; case 29: return GCKeyCodeZero; case 30: return GCKeyCodeCloseBracket;
    case 31: return GCKeyCodeKeyO; case 32: return GCKeyCodeKeyU; case 33: return GCKeyCodeOpenBracket;
    case 34: return GCKeyCodeKeyI; case 35: return GCKeyCodeKeyP; case 36: return GCKeyCodeReturnOrEnter;
    case 37: return GCKeyCodeKeyL; case 38: return GCKeyCodeKeyJ; case 39: return GCKeyCodeQuote;
    case 40: return GCKeyCodeKeyK; case 41: return GCKeyCodeSemicolon; case 42: return GCKeyCodeBackslash;
    case 43: return GCKeyCodeComma; case 44: return GCKeyCodeSlash; case 45: return GCKeyCodeKeyN;
    case 46: return GCKeyCodeKeyM; case 47: return GCKeyCodePeriod; case 48: return GCKeyCodeTab;
    case 49: return GCKeyCodeSpacebar; case 50: return GCKeyCodeGraveAccentAndTilde;
    case 51: return GCKeyCodeDeleteOrBackspace; case 53: return GCKeyCodeEscape;
    case 55: return GCKeyCodeLeftGUI; case 56: return GCKeyCodeLeftShift; case 57: return GCKeyCodeCapsLock;
    case 58: return GCKeyCodeLeftAlt; case 59: return GCKeyCodeLeftControl; case 60: return GCKeyCodeRightShift;
    case 61: return GCKeyCodeRightAlt; case 62: return GCKeyCodeRightControl; case 65: return GCKeyCodeKeypadPeriod;
    case 67: return GCKeyCodeKeypadAsterisk; case 69: return GCKeyCodeKeypadPlus; case 71: return GCKeyCodeKeypadNumLock;
    case 75: return GCKeyCodeKeypadSlash; case 76: return GCKeyCodeKeypadEnter; case 78: return GCKeyCodeKeypadHyphen;
    case 81: return GCKeyCodeKeypadEqualSign; case 82: return GCKeyCodeKeypad0; case 83: return GCKeyCodeKeypad1;
    case 84: return GCKeyCodeKeypad2; case 85: return GCKeyCodeKeypad3; case 86: return GCKeyCodeKeypad4;
    case 87: return GCKeyCodeKeypad5; case 88: return GCKeyCodeKeypad6; case 89: return GCKeyCodeKeypad7;
    case 91: return GCKeyCodeKeypad8; case 92: return GCKeyCodeKeypad9; case 96: return GCKeyCodeF5;
    case 97: return GCKeyCodeF6; case 98: return GCKeyCodeF7; case 99: return GCKeyCodeF3; case 100: return GCKeyCodeF8;
    case 101: return GCKeyCodeF9; case 103: return GCKeyCodeF11; case 105: return GCKeyCodeF13;
    case 106: return GCKeyCodeF16; case 107: return GCKeyCodeF14; case 109: return GCKeyCodeF10;
    case 111: return GCKeyCodeF12; case 113: return GCKeyCodeF15; case 114: return GCKeyCodeInsert;
    case 115: return GCKeyCodeHome; case 116: return GCKeyCodePageUp; case 117: return GCKeyCodeDeleteForward;
    case 118: return GCKeyCodeF4; case 119: return GCKeyCodeEnd; case 120: return GCKeyCodeF2;
    case 121: return GCKeyCodePageDown; case 122: return GCKeyCodeF1; case 123: return GCKeyCodeLeftArrow;
    case 124: return GCKeyCodeRightArrow; case 125: return GCKeyCodeDownArrow; case 126: return GCKeyCodeUpArrow;
    case 64: return GCKeyCodeF17; case 79: return GCKeyCodeF18; case 80: return GCKeyCodeF19; case 90: return GCKeyCodeF20;
    default: return (GCKeyCode)-1;
    }
}

@implementation GCKeyboardInput {
    GCKeyboard *_keyboard;
    GCKeyboardValueChangedHandler _keyChangedHandler;
    NSMutableDictionary *_buttonsByCode;
    NSMutableDictionary *_buttonsByName;
}

- (instancetype)init
{
    return [self _initWithKeyboard:nil];
}
- (instancetype)_initWithKeyboard:(GCKeyboard *)keyboard
{
    self = [super init];
    if (self) {
        _keyboard = keyboard;
        [self _setDevice:keyboard];
        _buttonsByCode = [[NSMutableDictionary alloc] init];
        _buttonsByName = [[NSMutableDictionary alloc] init];
    }
    return self;
}
- (void)dealloc
{
    [_keyChangedHandler release]; [_buttonsByCode release]; [_buttonsByName release];
    [super dealloc];
}
- (GCKeyboardValueChangedHandler)keyChangedHandler { return _keyChangedHandler; }
- (void)setKeyChangedHandler:(GCKeyboardValueChangedHandler)handler
{
    if (_keyChangedHandler != handler) { [_keyChangedHandler release]; _keyChangedHandler = [handler copy]; }
}
- (BOOL)isAnyKeyPressed
{
    for (GCControllerButtonInput *button in [_buttonsByCode allValues])
        if (button.pressed)
            return YES;
    return NO;
}
- (GCDeviceButtonInput *)buttonForKeyCode:(GCKeyCode)code
{
    NSString *name = GCKeyboardNameForCode(code);
    if (!name)
        return nil;
    NSNumber *number = [NSNumber numberWithLong:code];
    GCControllerButtonInput *button = [_buttonsByCode objectForKey:number];
    if (!button) {
        button = [[[GCControllerButtonInput alloc] _initWithAlias:name collection:nil analog:NO owner:nil] autorelease];
        [_buttonsByCode setObject:button forKey:number];
        [_buttonsByName setObject:button forKey:name];
        [self _addElement:button alias:name kind:1];
    }
    return button;
}
- (void)_setKeyCode:(GCKeyCode)code pressed:(BOOL)pressed timestamp:(NSTimeInterval)timestamp
{
    GCControllerButtonInput *button = (GCControllerButtonInput *)[self buttonForKeyCode:code];
    if (!button)
        return;
    [button _setInputValue:pressed ? 1.0f : 0.0f touched:pressed notify:YES];
    [self _setLastEventTimestamp:timestamp];
    [self _notifyElementChanged:button];
    if (_keyChangedHandler) {
        GCKeyboardValueChangedHandler handler = [_keyChangedHandler copy];
        GCInputDispatchHandler(_keyboard, ^{ handler(self, button, code, pressed); });
        [handler release];
    }
}

@end

@implementation GCMouseInput {
    GCMouse *_mouse;
    GCMouseMoved _mouseMovedHandler;
    GCControllerDirectionPad *_scroll;
    GCControllerButtonInput *_leftButton, *_rightButton, *_middleButton;
    NSMutableArray *_auxiliaryButtons;
}
- (instancetype)init { return [self _initWithMouse:nil]; }
- (instancetype)_initWithMouse:(GCMouse *)mouse
{
    self = [super init];
    if (!self)
        return nil;
    _mouse = mouse;
    [self _setDevice:mouse];
    _scroll = [GCInputMakeCursor(@"Scroll") retain];
    _leftButton = [GCInputMakeButton(@"Left Button") retain];
    _rightButton = [GCInputMakeButton(@"Right Button") retain];
    _middleButton = [GCInputMakeButton(@"Middle Button") retain];
    _auxiliaryButtons = [[NSMutableArray alloc] init];
    [self _addElement:_scroll alias:@"Scroll" kind:3];
    [self _addElement:_leftButton alias:@"Left Button" kind:1];
    [self _addElement:_rightButton alias:@"Right Button" kind:1];
    [self _addElement:_middleButton alias:@"Middle Button" kind:1];
    return self;
}
- (void)dealloc
{
    [_mouseMovedHandler release]; [_scroll release]; [_leftButton release]; [_rightButton release];
    [_middleButton release]; [_auxiliaryButtons release];
    [super dealloc];
}
- (GCMouseMoved)mouseMovedHandler { return _mouseMovedHandler; }
- (void)setMouseMovedHandler:(GCMouseMoved)handler
{
    if (_mouseMovedHandler != handler) { [_mouseMovedHandler release]; _mouseMovedHandler = [handler copy]; }
}
- (GCDeviceCursor *)scroll { return (GCDeviceCursor *)_scroll; }
- (GCDeviceButtonInput *)leftButton { return _leftButton; }
- (GCDeviceButtonInput *)rightButton { return _rightButton; }
- (GCDeviceButtonInput *)middleButton { return _middleButton; }
- (NSArray<GCDeviceButtonInput *> *)auxiliaryButtons { return _auxiliaryButtons; }
- (void)_moveByX:(float)x y:(float)y
{
    [self _setLastEventTimestamp:[NSDate timeIntervalSinceReferenceDate]];
    if (_mouseMovedHandler) {
        GCMouseMoved handler = [_mouseMovedHandler copy];
        GCInputDispatchHandler(_mouse, ^{ handler(self, x, y); });
        [handler release];
    }
}
- (void)_setButton:(NSInteger)button pressed:(BOOL)pressed
{
    GCControllerButtonInput *input = button == 0 ? _leftButton : button == 1 ? _rightButton :
                                     button == 2 ? _middleButton : nil;
    if (!input && button > 2) {
        NSUInteger index = (NSUInteger)(button - 3);
        while ([_auxiliaryButtons count] <= index) {
            NSString *alias = [NSString stringWithFormat:@"Auxiliary Button %lu", (unsigned long)([_auxiliaryButtons count] + 1)];
            GCControllerButtonInput *aux = GCInputMakeButton(alias);
            [_auxiliaryButtons addObject:aux];
            [self _addElement:aux alias:alias kind:1];
        }
        input = [_auxiliaryButtons objectAtIndex:index];
    }
    [input _setInputValue:pressed ? 1.0f : 0.0f touched:pressed notify:YES];
    [self _setLastEventTimestamp:[NSDate timeIntervalSinceReferenceDate]];
    [self _notifyElementChanged:input];
}
- (void)_scrollByX:(float)x y:(float)y
{
    [_scroll _setPositionX:x y:y notify:YES];
    [self _setLastEventTimestamp:[NSDate timeIntervalSinceReferenceDate]];
    [self _notifyElementChanged:_scroll];
}
@end

void GCKeyboardHandleEvent(NSEvent *event)
{
    NSEventType type = [event type];
    if (type != NSEventTypeKeyDown && type != NSEventTypeKeyUp && type != NSEventTypeFlagsChanged)
        return;
    GCKeyCode code = GCKeyboardCodeForVirtualKey([event keyCode]);
    if (code < 0)
        return;
    GCKeyboard *keyboard = [GCKeyboard _keyboardForInputEvent];
    BOOL pressed = type != NSEventTypeKeyUp;
    if (type == NSEventTypeFlagsChanged) {
        NSEventModifierFlags flags = [event modifierFlags];
        GCControllerButtonInput *button = (GCControllerButtonInput *)
            [keyboard.keyboardInput buttonForKeyCode:code];
        NSEventModifierFlags mask = 0;
        switch ([event keyCode]) {
        case 54: case 55: mask = NSEventModifierFlagCommand; break;
        case 56: case 60: mask = NSEventModifierFlagShift; break;
        case 57: mask = NSEventModifierFlagCapsLock; break;
        case 58: case 61: mask = NSEventModifierFlagOption; break;
        case 59: case 62: mask = NSEventModifierFlagControl; break;
        default: break;
        }
        if (mask == NSEventModifierFlagCapsLock)
            pressed = (flags & mask) != 0;
        else if (mask)
            pressed = (flags & mask) ? !button.pressed : NO;
    }
    [keyboard.keyboardInput _setKeyCode:code pressed:pressed timestamp:event.timestamp];
}

void GCMouseHandleEvent(NSEvent *event)
{
    GCMouse *mouse = [GCMouse _mouseForInputEvent];
    GCMouseInput *input = mouse.mouseInput;
    switch ([event type]) {
    case NSEventTypeMouseMoved:
    case NSEventTypeLeftMouseDragged:
    case NSEventTypeRightMouseDragged:
    case NSEventTypeOtherMouseDragged:
        [input _moveByX:(float)[event deltaX] y:(float)[event deltaY]];
        break;
    case NSEventTypeLeftMouseDown: [input _setButton:0 pressed:YES]; break;
    case NSEventTypeLeftMouseUp: [input _setButton:0 pressed:NO]; break;
    case NSEventTypeRightMouseDown: [input _setButton:1 pressed:YES]; break;
    case NSEventTypeRightMouseUp: [input _setButton:1 pressed:NO]; break;
    case NSEventTypeOtherMouseDown: [input _setButton:[event buttonNumber] pressed:YES]; break;
    case NSEventTypeOtherMouseUp: [input _setButton:[event buttonNumber] pressed:NO]; break;
    case NSEventTypeScrollWheel:
        [input _scrollByX:(float)[event scrollingDeltaX] y:(float)[event scrollingDeltaY]];
        break;
    default: break;
    }
}

static BOOL input_monitors_installed;
static id keyboard_monitor_token;
static id mouse_monitor_token;

void GCInstallEventMonitors(void)
{
    @synchronized([NSEvent class]) {
        if (input_monitors_installed)
            return;
        input_monitors_installed = YES;
        keyboard_monitor_token = [[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskKeyUp | NSEventMaskFlagsChanged
                                                                            handler:^NSEvent *(NSEvent *event) {
            GCKeyboardHandleEvent(event);
            return event;
        }] retain];
        NSEventMask mouseMask = NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged | NSEventMaskRightMouseDragged |
                                NSEventMaskOtherMouseDragged | NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp |
                                NSEventMaskRightMouseDown | NSEventMaskRightMouseUp | NSEventMaskOtherMouseDown |
                                NSEventMaskOtherMouseUp | NSEventMaskScrollWheel;
        mouse_monitor_token = [[NSEvent addLocalMonitorForEventsMatchingMask:mouseMask handler:^NSEvent *(NSEvent *event) {
            GCMouseHandleEvent(event);
            return event;
        }] retain];
    }
}

@interface _GCInputMonitorInstaller : NSObject
@end

@implementation _GCInputMonitorInstaller
+ (void)load { GCInstallEventMonitors(); }
@end
