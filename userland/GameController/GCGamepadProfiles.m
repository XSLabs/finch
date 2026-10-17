// SPDX-License-Identifier: MIT OR Apache-2.0
#import "GCGameControllerPrivate.h"

static GCControllerButtonInput *GCMakeButton(GCController *controller, NSString *alias, BOOL analog)
{
    return [[[GCControllerButtonInput alloc] _initWithAlias:alias collection:nil analog:analog owner:controller] autorelease];
}

static GCControllerDirectionPad *GCMakeDpad(GCController *controller, NSString *alias, BOOL analog)
{
    return [[[GCControllerDirectionPad alloc] _initWithAlias:alias owner:controller analog:analog] autorelease];
}

static void GCAddButton(GCPhysicalInputProfile *profile, GCControllerButtonInput *button, NSString *alias)
{
    NSMutableSet *aliases = [NSMutableSet setWithSet:button.aliases ?: [NSSet set]];
    [aliases addObject:alias];
    [button _setAliases:aliases];
    [profile _addElement:button alias:alias kind:1];
}

static void GCAddDpad(GCPhysicalInputProfile *profile, GCControllerDirectionPad *dpad, NSString *alias)
{
    [profile _addElement:dpad alias:alias kind:3];
    NSArray *elements = @[dpad.xAxis, dpad.yAxis, dpad.up, dpad.down, dpad.left, dpad.right];
    NSArray *names = @[[alias stringByAppendingString:@" X Axis"], [alias stringByAppendingString:@" Y Axis"],
                       [alias stringByAppendingString:@" Up"], [alias stringByAppendingString:@" Down"],
                       [alias stringByAppendingString:@" Left"], [alias stringByAppendingString:@" Right"]];
    for (NSUInteger i = 0; i < [elements count]; i++) {
        GCControllerElement *element = [elements objectAtIndex:i];
        NSString *name = [names objectAtIndex:i];
        [element _setAliases:[NSSet setWithObject:name]];
        [profile _addElement:element alias:name kind:(i < 2 ? 2 : 1)];
    }
}

@implementation GCExtendedGamepad {
    GCController *_controller;
    GCExtendedGamepadValueChangedHandler _valueChangedHandler;
    GCControllerDirectionPad *_dpad;
    GCControllerButtonInput *_buttonA, *_buttonB, *_buttonX, *_buttonY;
    GCControllerButtonInput *_buttonMenu, *_buttonOptions, *_buttonHome;
    GCControllerDirectionPad *_leftThumbstick, *_rightThumbstick;
    GCControllerButtonInput *_leftShoulder, *_rightShoulder, *_leftTrigger, *_rightTrigger;
    GCControllerButtonInput *_leftThumbstickButton, *_rightThumbstickButton;
}

- (instancetype)init
{
    return [self _initWithController:nil];
}

- (instancetype)_initWithController:(GCController *)controller
{
    self = [super init];
    if (!self)
        return nil;
    _controller = controller;
    _dpad = [GCMakeDpad(controller, GCInputDirectionPad, YES) retain];
    _leftThumbstick = [GCMakeDpad(controller, GCInputLeftThumbstick, YES) retain];
    _rightThumbstick = [GCMakeDpad(controller, GCInputRightThumbstick, YES) retain];
    GCAddDpad(self, _dpad, GCInputDirectionPad);
    GCAddDpad(self, _leftThumbstick, GCInputLeftThumbstick);
    GCAddDpad(self, _rightThumbstick, GCInputRightThumbstick);

    _buttonA = [GCMakeButton(controller, GCInputButtonA, YES) retain];
    _buttonB = [GCMakeButton(controller, GCInputButtonB, YES) retain];
    _buttonX = [GCMakeButton(controller, GCInputButtonX, YES) retain];
    _buttonY = [GCMakeButton(controller, GCInputButtonY, YES) retain];
    _leftShoulder = [GCMakeButton(controller, GCInputLeftShoulder, YES) retain];
    _rightShoulder = [GCMakeButton(controller, GCInputRightShoulder, YES) retain];
    _leftTrigger = [GCMakeButton(controller, GCInputLeftTrigger, YES) retain];
    _rightTrigger = [GCMakeButton(controller, GCInputRightTrigger, YES) retain];
    _buttonMenu = [GCMakeButton(controller, GCInputButtonMenu, NO) retain];
    _buttonOptions = [GCMakeButton(controller, GCInputButtonOptions, NO) retain];
    _buttonHome = [GCMakeButton(controller, GCInputButtonHome, NO) retain];
    _leftThumbstickButton = [GCMakeButton(controller, GCInputLeftThumbstickButton, NO) retain];
    _rightThumbstickButton = [GCMakeButton(controller, GCInputRightThumbstickButton, NO) retain];
    GCAddButton(self, _buttonA, GCInputButtonA);
    GCAddButton(self, _buttonB, GCInputButtonB);
    GCAddButton(self, _buttonX, GCInputButtonX);
    GCAddButton(self, _buttonY, GCInputButtonY);
    GCAddButton(self, _leftShoulder, GCInputLeftShoulder);
    GCAddButton(self, _leftShoulder, GCInputLeftBumper);
    GCAddButton(self, _rightShoulder, GCInputRightShoulder);
    GCAddButton(self, _rightShoulder, GCInputRightBumper);
    GCAddButton(self, _leftTrigger, GCInputLeftTrigger);
    GCAddButton(self, _rightTrigger, GCInputRightTrigger);
    GCAddButton(self, _buttonMenu, GCInputButtonMenu);
    GCAddButton(self, _buttonOptions, GCInputButtonOptions);
    GCAddButton(self, _buttonHome, GCInputButtonHome);
    GCAddButton(self, _leftThumbstickButton, GCInputLeftThumbstickButton);
    GCAddButton(self, _rightThumbstickButton, GCInputRightThumbstickButton);
    return self;
}

- (void)dealloc
{
    [_valueChangedHandler release];
    [_dpad release]; [_leftThumbstick release]; [_rightThumbstick release];
    [_buttonA release]; [_buttonB release]; [_buttonX release]; [_buttonY release];
    [_buttonMenu release]; [_buttonOptions release]; [_buttonHome release];
    [_leftShoulder release]; [_rightShoulder release]; [_leftTrigger release]; [_rightTrigger release];
    [_leftThumbstickButton release]; [_rightThumbstickButton release];
    [super dealloc];
}

- (GCController *)controller { return _controller; }
- (GCExtendedGamepadValueChangedHandler)valueChangedHandler { return _valueChangedHandler; }
- (void)setValueChangedHandler:(GCExtendedGamepadValueChangedHandler)handler
{
    if (_valueChangedHandler != handler) {
        [_valueChangedHandler release];
        _valueChangedHandler = [handler copy];
    }
}
- (GCControllerDirectionPad *)dpad { return _dpad; }
- (GCControllerButtonInput *)buttonA { return _buttonA; }
- (GCControllerButtonInput *)buttonB { return _buttonB; }
- (GCControllerButtonInput *)buttonX { return _buttonX; }
- (GCControllerButtonInput *)buttonY { return _buttonY; }
- (GCControllerButtonInput *)buttonMenu { return _buttonMenu; }
- (GCControllerButtonInput *)buttonOptions { return _buttonOptions; }
- (GCControllerButtonInput *)buttonHome { return _buttonHome; }
- (GCControllerDirectionPad *)leftThumbstick { return _leftThumbstick; }
- (GCControllerDirectionPad *)rightThumbstick { return _rightThumbstick; }
- (GCControllerButtonInput *)leftShoulder { return _leftShoulder; }
- (GCControllerButtonInput *)rightShoulder { return _rightShoulder; }
- (GCControllerButtonInput *)leftTrigger { return _leftTrigger; }
- (GCControllerButtonInput *)rightTrigger { return _rightTrigger; }
- (GCControllerButtonInput *)leftThumbstickButton { return _leftThumbstickButton; }
- (GCControllerButtonInput *)rightThumbstickButton { return _rightThumbstickButton; }

- (void)setStateFromExtendedGamepad:(GCExtendedGamepad *)gamepad
{
    if ([_controller isSnapshot] && gamepad)
        [self _setStateFromProfile:gamepad];
}

- (GCExtendedGamepadSnapshot *)saveSnapshot
{
    extern NSData *NSDataFromGCExtendedGamepadSnapshotData(GCExtendedGamepadSnapshotData *data);
    GCExtendedGamepadSnapshotData data = {0};
    data.dpadX = _dpad.xAxis.value; data.dpadY = _dpad.yAxis.value;
    data.buttonA = _buttonA.value; data.buttonB = _buttonB.value;
    data.buttonX = _buttonX.value; data.buttonY = _buttonY.value;
    data.leftShoulder = _leftShoulder.value; data.rightShoulder = _rightShoulder.value;
    data.leftThumbstickX = _leftThumbstick.xAxis.value; data.leftThumbstickY = _leftThumbstick.yAxis.value;
    data.rightThumbstickX = _rightThumbstick.xAxis.value; data.rightThumbstickY = _rightThumbstick.yAxis.value;
    data.leftTrigger = _leftTrigger.value; data.rightTrigger = _rightTrigger.value;
    NSData *bytes = NSDataFromGCExtendedGamepadSnapshotData(&data);
    return [[[GCExtendedGamepadSnapshot alloc] initWithController:_controller snapshotData:bytes] autorelease];
}

@end

@implementation GCMicroGamepad {
    GCController *_controller;
    GCMicroGamepadValueChangedHandler _valueChangedHandler;
    GCControllerDirectionPad *_dpad;
    GCControllerButtonInput *_buttonA, *_buttonX, *_buttonMenu;
    BOOL _reportsAbsoluteDpadValues;
    BOOL _allowsRotation;
}

- (instancetype)init { return [self _initWithController:nil]; }
- (instancetype)_initWithController:(GCController *)controller
{
    self = [super init];
    if (!self)
        return nil;
    _controller = controller;
    _dpad = [GCMakeDpad(controller, GCInputDirectionPad, YES) retain];
    GCAddDpad(self, _dpad, GCInputDirectionPad);
    _buttonA = [GCMakeButton(controller, GCInputButtonA, YES) retain];
    _buttonX = [GCMakeButton(controller, GCInputButtonX, YES) retain];
    _buttonMenu = [GCMakeButton(controller, GCInputButtonMenu, NO) retain];
    GCAddButton(self, _buttonA, GCInputButtonA);
    GCAddButton(self, _buttonX, GCInputButtonX);
    GCAddButton(self, _buttonMenu, GCInputButtonMenu);
    return self;
}
- (void)dealloc
{
    [_valueChangedHandler release]; [_dpad release]; [_buttonA release]; [_buttonX release]; [_buttonMenu release];
    [super dealloc];
}
- (GCController *)controller { return _controller; }
- (GCMicroGamepadValueChangedHandler)valueChangedHandler { return _valueChangedHandler; }
- (void)setValueChangedHandler:(GCMicroGamepadValueChangedHandler)handler
{
    if (_valueChangedHandler != handler) { [_valueChangedHandler release]; _valueChangedHandler = [handler copy]; }
}
- (GCControllerDirectionPad *)dpad { return _dpad; }
- (GCControllerButtonInput *)buttonA { return _buttonA; }
- (GCControllerButtonInput *)buttonX { return _buttonX; }
- (GCControllerButtonInput *)buttonMenu { return _buttonMenu; }
- (BOOL)reportsAbsoluteDpadValues { return _reportsAbsoluteDpadValues; }
- (void)setReportsAbsoluteDpadValues:(BOOL)value { _reportsAbsoluteDpadValues = value; }
- (BOOL)allowsRotation { return _allowsRotation; }
- (void)setAllowsRotation:(BOOL)value { _allowsRotation = value; }
- (void)setStateFromMicroGamepad:(GCMicroGamepad *)gamepad
{
    if ([_controller isSnapshot] && gamepad)
        [self _setStateFromProfile:gamepad];
}
- (GCMicroGamepadSnapshot *)saveSnapshot
{
    extern NSData *NSDataFromGCMicroGamepadSnapshotData(GCMicroGamepadSnapshotData *data);
    GCMicroGamepadSnapshotData data = {0};
    data.dpadX = _dpad.xAxis.value; data.dpadY = _dpad.yAxis.value;
    data.buttonA = _buttonA.value; data.buttonX = _buttonX.value;
    NSData *bytes = NSDataFromGCMicroGamepadSnapshotData(&data);
    return [[[GCMicroGamepadSnapshot alloc] initWithController:_controller snapshotData:bytes] autorelease];
}
@end

@implementation GCGamepad {
    GCController *_controller;
    GCGamepadValueChangedHandler _valueChangedHandler;
    GCControllerDirectionPad *_dpad;
    GCControllerButtonInput *_buttonA, *_buttonB, *_buttonX, *_buttonY;
    GCControllerButtonInput *_leftShoulder, *_rightShoulder;
}
- (instancetype)init { return [self _initWithController:nil]; }
- (instancetype)_initWithController:(GCController *)controller
{
    self = [super init];
    if (!self)
        return nil;
    _controller = controller;
    _dpad = [GCMakeDpad(controller, GCInputDirectionPad, YES) retain];
    GCAddDpad(self, _dpad, GCInputDirectionPad);
    _buttonA = [GCMakeButton(controller, GCInputButtonA, YES) retain];
    _buttonB = [GCMakeButton(controller, GCInputButtonB, YES) retain];
    _buttonX = [GCMakeButton(controller, GCInputButtonX, YES) retain];
    _buttonY = [GCMakeButton(controller, GCInputButtonY, YES) retain];
    _leftShoulder = [GCMakeButton(controller, GCInputLeftShoulder, YES) retain];
    _rightShoulder = [GCMakeButton(controller, GCInputRightShoulder, YES) retain];
    GCAddButton(self, _buttonA, GCInputButtonA); GCAddButton(self, _buttonB, GCInputButtonB);
    GCAddButton(self, _buttonX, GCInputButtonX); GCAddButton(self, _buttonY, GCInputButtonY);
    GCAddButton(self, _leftShoulder, GCInputLeftShoulder); GCAddButton(self, _rightShoulder, GCInputRightShoulder);
    return self;
}
- (void)dealloc
{
    [_valueChangedHandler release]; [_dpad release]; [_buttonA release]; [_buttonB release];
    [_buttonX release]; [_buttonY release]; [_leftShoulder release]; [_rightShoulder release];
    [super dealloc];
}
- (GCController *)controller { return _controller; }
- (GCGamepadValueChangedHandler)valueChangedHandler { return _valueChangedHandler; }
- (void)setValueChangedHandler:(GCGamepadValueChangedHandler)handler
{
    if (_valueChangedHandler != handler) { [_valueChangedHandler release]; _valueChangedHandler = [handler copy]; }
}
- (GCControllerDirectionPad *)dpad { return _dpad; }
- (GCControllerButtonInput *)buttonA { return _buttonA; }
- (GCControllerButtonInput *)buttonB { return _buttonB; }
- (GCControllerButtonInput *)buttonX { return _buttonX; }
- (GCControllerButtonInput *)buttonY { return _buttonY; }
- (GCControllerButtonInput *)leftShoulder { return _leftShoulder; }
- (GCControllerButtonInput *)rightShoulder { return _rightShoulder; }
- (GCGamepadSnapshot *)saveSnapshot
{
    extern NSData *NSDataFromGCGamepadSnapShotDataV100(GCGamepadSnapShotDataV100 *data);
    GCGamepadSnapShotDataV100 data = {0};
    data.dpadX = _dpad.xAxis.value; data.dpadY = _dpad.yAxis.value;
    data.buttonA = _buttonA.value; data.buttonB = _buttonB.value;
    data.buttonX = _buttonX.value; data.buttonY = _buttonY.value;
    data.leftShoulder = _leftShoulder.value; data.rightShoulder = _rightShoulder.value;
    NSData *bytes = NSDataFromGCGamepadSnapShotDataV100(&data);
    return [[[GCGamepadSnapshot alloc] initWithController:_controller snapshotData:bytes] autorelease];
}
@end
