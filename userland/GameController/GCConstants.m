// SPDX-License-Identifier: MIT OR Apache-2.0
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#include <stdio.h>

NSString * const GCControllerDidBecomeCurrentNotification = @"GCControllerDidBecomeCurrentNotification";
NSString * const GCControllerDidConnectNotification = @"GCControllerDidConnectNotification";
NSString * const GCControllerDidDisconnectNotification = @"GCControllerDidDisconnectNotification";
NSString * const GCControllerDidStopBeingCurrentNotification = @"GCControllerDidStopBeingCurrentNotification";
NSString * const GCControllerUserCustomizationsDidChangeNotification = @"GCControllerUserCustomizationsDidChangeNotification";
NSString * const GCKeyboardDidConnectNotification = @"GCKeyboardDidConnectNotification";
NSString * const GCKeyboardDidDisconnectNotification = @"GCKeyboardDidDisconnectNotification";
NSString * const GCMouseDidBecomeCurrentNotification = @"GCMouseDidBecomeCurrentNotification";
NSString * const GCMouseDidConnectNotification = @"GCMouseDidConnectNotification";
NSString * const GCMouseDidDisconnectNotification = @"GCMouseDidDisconnectNotification";
NSString * const GCMouseDidStopBeingCurrentNotification = @"GCMouseDidStopBeingCurrentNotification";

#define INPUT_BUTTON(name, value) GCInputButtonName name = (GCInputButtonName)@value
#define INPUT_DPAD(name, value) GCInputDirectionPadName name = (GCInputDirectionPadName)@value
#define INPUT_AXIS(name, value) GCInputAxisName name = (GCInputAxisName)@value
#define INPUT_ELEMENT(name, value) GCInputElementName name = (GCInputElementName)@value

INPUT_BUTTON(GCInputButtonA, "Button A");
INPUT_BUTTON(GCInputButtonB, "Button B");
INPUT_BUTTON(GCInputButtonX, "Button X");
INPUT_BUTTON(GCInputButtonY, "Button Y");
INPUT_DPAD(GCInputDirectionPad, "Direction Pad");
INPUT_DPAD(GCInputThumbstick, "Thumbstick");
INPUT_DPAD(GCInputLeftThumbstick, "Left Thumbstick");
INPUT_DPAD(GCInputRightThumbstick, "Right Thumbstick");
INPUT_BUTTON(GCInputThumbstickButton, "Thumbstick Button");
INPUT_BUTTON(GCInputLeftThumbstickButton, "Left Thumbstick Button");
INPUT_BUTTON(GCInputRightThumbstickButton, "Right Thumbstick Button");
INPUT_BUTTON(GCInputLeftShoulder, "Left Shoulder");
INPUT_BUTTON(GCInputRightShoulder, "Right Shoulder");
INPUT_BUTTON(GCInputLeftBumper, "Left Bumper");
INPUT_BUTTON(GCInputRightBumper, "Right Bumper");
INPUT_BUTTON(GCInputTrigger, "Trigger");
INPUT_BUTTON(GCInputLeftTrigger, "Left Trigger");
INPUT_BUTTON(GCInputRightTrigger, "Right Trigger");
INPUT_BUTTON(GCInputLeftSideButton, "Left Side Button");
INPUT_BUTTON(GCInputRightSideButton, "Right Side Button");
INPUT_BUTTON(GCInputButtonHome, "Button Home");
INPUT_BUTTON(GCInputButtonMenu, "Button Menu");
INPUT_BUTTON(GCInputButtonOptions, "Button Options");
INPUT_BUTTON(GCInputButtonShare, "Button Share");
INPUT_BUTTON(GCInputXboxPaddleOne, "Paddle 1");
INPUT_BUTTON(GCInputXboxPaddleTwo, "Paddle 2");
INPUT_BUTTON(GCInputXboxPaddleThree, "Paddle 3");
INPUT_BUTTON(GCInputXboxPaddleFour, "Paddle 4");
INPUT_BUTTON(GCInputDualShockTouchpadButton, "Touchpad Button");
INPUT_DPAD(GCInputDualShockTouchpadOne, "Touchpad 1");
INPUT_DPAD(GCInputDualShockTouchpadTwo, "Touchpad 2");
INPUT_BUTTON(GCInputGripButton, "Grip");
INPUT_BUTTON(GCInputLeftPaddle, "Left Paddle");
INPUT_BUTTON(GCInputRightPaddle, "Right Paddle");
NSString * const GCInputDirectionalCardinalDpad = @"Cardinal Direction Pad";
NSString * const GCInputDirectionalCenterButton = @"Button Center";
NSString * const GCInputDirectionalDpad = @"Direction Pad";
NSString * const GCInputDirectionalTouchSurfaceButton = @"Button A";
NSString * const GCInputMicroGamepadDpad = @"Direction Pad";
NSString * const GCInputMicroGamepadButtonA = @"Button A";
NSString * const GCInputMicroGamepadButtonX = @"Button X";
NSString * const GCInputMicroGamepadButtonMenu = @"Button Menu";
INPUT_AXIS(GCInputSteeringWheel, "Steering Wheel");
INPUT_ELEMENT(GCInputShifter, "Shifter");
INPUT_BUTTON(GCInputPedalAccelerator, "Accelerator Pedal");
INPUT_BUTTON(GCInputPedalBrake, "Brake Pedal");
INPUT_BUTTON(GCInputPedalClutch, "Clutch Pedal");

GCInputButtonName GCInputArcadeButtonName(NSInteger row, NSInteger column)
{
    return (GCInputButtonName)[NSString stringWithFormat:@"Arcade Button %ld, %ld", (long)row, (long)column];
}

GCInputButtonName GCInputBackLeftButton(NSInteger position)
{
    return (GCInputButtonName)[NSString stringWithFormat:@"Back Left Button %ld", (long)position];
}

GCInputButtonName GCInputBackRightButton(NSInteger position)
{
    return (GCInputButtonName)[NSString stringWithFormat:@"Back Right Button %ld", (long)position];
}

#define GC_KEY_NAME(name) NSString * const GCKey##name = @#name
GC_KEY_NAME(A); GC_KEY_NAME(B); GC_KEY_NAME(C); GC_KEY_NAME(D); GC_KEY_NAME(E); GC_KEY_NAME(F);
GC_KEY_NAME(G); GC_KEY_NAME(H); GC_KEY_NAME(I); GC_KEY_NAME(J); GC_KEY_NAME(K); GC_KEY_NAME(L);
GC_KEY_NAME(M); GC_KEY_NAME(N); GC_KEY_NAME(O); GC_KEY_NAME(P); GC_KEY_NAME(Q); GC_KEY_NAME(R);
GC_KEY_NAME(S); GC_KEY_NAME(T); GC_KEY_NAME(U); GC_KEY_NAME(V); GC_KEY_NAME(W); GC_KEY_NAME(X);
GC_KEY_NAME(Y); GC_KEY_NAME(Z);
GC_KEY_NAME(One); GC_KEY_NAME(Two); GC_KEY_NAME(Three); GC_KEY_NAME(Four); GC_KEY_NAME(Five);
GC_KEY_NAME(Six); GC_KEY_NAME(Seven); GC_KEY_NAME(Eight); GC_KEY_NAME(Nine); GC_KEY_NAME(Zero);
GC_KEY_NAME(ReturnOrEnter); GC_KEY_NAME(Escape); GC_KEY_NAME(DeleteOrBackspace); GC_KEY_NAME(Tab);
GC_KEY_NAME(Spacebar); GC_KEY_NAME(Hyphen); GC_KEY_NAME(EqualSign); GC_KEY_NAME(OpenBracket);
GC_KEY_NAME(CloseBracket); GC_KEY_NAME(Backslash); GC_KEY_NAME(NonUSPound); GC_KEY_NAME(Semicolon);
GC_KEY_NAME(Quote); GC_KEY_NAME(GraveAccentAndTilde); GC_KEY_NAME(Comma); GC_KEY_NAME(Period);
GC_KEY_NAME(Slash); GC_KEY_NAME(CapsLock);
GC_KEY_NAME(F1); GC_KEY_NAME(F2); GC_KEY_NAME(F3); GC_KEY_NAME(F4); GC_KEY_NAME(F5); GC_KEY_NAME(F6);
GC_KEY_NAME(F7); GC_KEY_NAME(F8); GC_KEY_NAME(F9); GC_KEY_NAME(F10); GC_KEY_NAME(F11); GC_KEY_NAME(F12);
GC_KEY_NAME(F13); GC_KEY_NAME(F14); GC_KEY_NAME(F15); GC_KEY_NAME(F16); GC_KEY_NAME(F17); GC_KEY_NAME(F18);
GC_KEY_NAME(F19); GC_KEY_NAME(F20);
GC_KEY_NAME(PrintScreen); GC_KEY_NAME(ScrollLock); GC_KEY_NAME(Pause); GC_KEY_NAME(Insert);
GC_KEY_NAME(Home); GC_KEY_NAME(PageUp); GC_KEY_NAME(DeleteForward); GC_KEY_NAME(End); GC_KEY_NAME(PageDown);
GC_KEY_NAME(RightArrow); GC_KEY_NAME(LeftArrow); GC_KEY_NAME(DownArrow); GC_KEY_NAME(UpArrow);
GC_KEY_NAME(KeypadNumLock); GC_KEY_NAME(KeypadSlash); GC_KEY_NAME(KeypadAsterisk); GC_KEY_NAME(KeypadHyphen);
GC_KEY_NAME(KeypadPlus); GC_KEY_NAME(KeypadEnter); GC_KEY_NAME(Keypad1); GC_KEY_NAME(Keypad2);
GC_KEY_NAME(Keypad3); GC_KEY_NAME(Keypad4); GC_KEY_NAME(Keypad5); GC_KEY_NAME(Keypad6); GC_KEY_NAME(Keypad7);
GC_KEY_NAME(Keypad8); GC_KEY_NAME(Keypad9); GC_KEY_NAME(Keypad0); GC_KEY_NAME(KeypadPeriod);
GC_KEY_NAME(KeypadEqualSign); GC_KEY_NAME(Application); GC_KEY_NAME(NonUSBackslash);
GC_KEY_NAME(International1); GC_KEY_NAME(International2); GC_KEY_NAME(International3);
GC_KEY_NAME(International4); GC_KEY_NAME(International5); GC_KEY_NAME(International6);
GC_KEY_NAME(International7); GC_KEY_NAME(International8); GC_KEY_NAME(International9);
GC_KEY_NAME(LANG1); GC_KEY_NAME(LANG2); GC_KEY_NAME(LANG3); GC_KEY_NAME(LANG4); GC_KEY_NAME(LANG5);
GC_KEY_NAME(LANG6); GC_KEY_NAME(LANG7); GC_KEY_NAME(LANG8); GC_KEY_NAME(LANG9);
GC_KEY_NAME(LeftControl); GC_KEY_NAME(LeftShift); GC_KEY_NAME(LeftAlt); GC_KEY_NAME(LeftGUI);
GC_KEY_NAME(RightControl); GC_KEY_NAME(RightShift); GC_KEY_NAME(RightAlt); GC_KEY_NAME(RightGUI);
GC_KEY_NAME(Power);
#undef GC_KEY_NAME

#define GC_KEY_CODE(name, value) const GCKeyCode GCKeyCode##name = value
GC_KEY_CODE(KeyA, 4); GC_KEY_CODE(KeyB, 5); GC_KEY_CODE(KeyC, 6); GC_KEY_CODE(KeyD, 7);
GC_KEY_CODE(KeyE, 8); GC_KEY_CODE(KeyF, 9); GC_KEY_CODE(KeyG, 10); GC_KEY_CODE(KeyH, 11);
GC_KEY_CODE(KeyI, 12); GC_KEY_CODE(KeyJ, 13); GC_KEY_CODE(KeyK, 14); GC_KEY_CODE(KeyL, 15);
GC_KEY_CODE(KeyM, 16); GC_KEY_CODE(KeyN, 17); GC_KEY_CODE(KeyO, 18); GC_KEY_CODE(KeyP, 19);
GC_KEY_CODE(KeyQ, 20); GC_KEY_CODE(KeyR, 21); GC_KEY_CODE(KeyS, 22); GC_KEY_CODE(KeyT, 23);
GC_KEY_CODE(KeyU, 24); GC_KEY_CODE(KeyV, 25); GC_KEY_CODE(KeyW, 26); GC_KEY_CODE(KeyX, 27);
GC_KEY_CODE(KeyY, 28); GC_KEY_CODE(KeyZ, 29);
GC_KEY_CODE(One, 30); GC_KEY_CODE(Two, 31); GC_KEY_CODE(Three, 32); GC_KEY_CODE(Four, 33);
GC_KEY_CODE(Five, 34); GC_KEY_CODE(Six, 35); GC_KEY_CODE(Seven, 36); GC_KEY_CODE(Eight, 37);
GC_KEY_CODE(Nine, 38); GC_KEY_CODE(Zero, 39); GC_KEY_CODE(ReturnOrEnter, 40); GC_KEY_CODE(Escape, 41);
GC_KEY_CODE(DeleteOrBackspace, 42); GC_KEY_CODE(Tab, 43); GC_KEY_CODE(Spacebar, 44); GC_KEY_CODE(Hyphen, 45);
GC_KEY_CODE(EqualSign, 46); GC_KEY_CODE(OpenBracket, 47); GC_KEY_CODE(CloseBracket, 48);
GC_KEY_CODE(Backslash, 49); GC_KEY_CODE(NonUSPound, 50); GC_KEY_CODE(Semicolon, 51); GC_KEY_CODE(Quote, 52);
GC_KEY_CODE(GraveAccentAndTilde, 53); GC_KEY_CODE(Comma, 54); GC_KEY_CODE(Period, 55); GC_KEY_CODE(Slash, 56);
GC_KEY_CODE(CapsLock, 57);
GC_KEY_CODE(F1, 58); GC_KEY_CODE(F2, 59); GC_KEY_CODE(F3, 60); GC_KEY_CODE(F4, 61); GC_KEY_CODE(F5, 62);
GC_KEY_CODE(F6, 63); GC_KEY_CODE(F7, 64); GC_KEY_CODE(F8, 65); GC_KEY_CODE(F9, 66); GC_KEY_CODE(F10, 67);
GC_KEY_CODE(F11, 68); GC_KEY_CODE(F12, 69); GC_KEY_CODE(PrintScreen, 70); GC_KEY_CODE(ScrollLock, 71);
GC_KEY_CODE(Pause, 72); GC_KEY_CODE(Insert, 73); GC_KEY_CODE(Home, 74); GC_KEY_CODE(PageUp, 75);
GC_KEY_CODE(DeleteForward, 76); GC_KEY_CODE(End, 77); GC_KEY_CODE(PageDown, 78); GC_KEY_CODE(RightArrow, 79);
GC_KEY_CODE(LeftArrow, 80); GC_KEY_CODE(DownArrow, 81); GC_KEY_CODE(UpArrow, 82);
GC_KEY_CODE(KeypadNumLock, 83); GC_KEY_CODE(KeypadSlash, 84); GC_KEY_CODE(KeypadAsterisk, 85);
GC_KEY_CODE(KeypadHyphen, 86); GC_KEY_CODE(KeypadPlus, 87); GC_KEY_CODE(KeypadEnter, 88);
GC_KEY_CODE(Keypad1, 89); GC_KEY_CODE(Keypad2, 90); GC_KEY_CODE(Keypad3, 91); GC_KEY_CODE(Keypad4, 92);
GC_KEY_CODE(Keypad5, 93); GC_KEY_CODE(Keypad6, 94); GC_KEY_CODE(Keypad7, 95); GC_KEY_CODE(Keypad8, 96);
GC_KEY_CODE(Keypad9, 97); GC_KEY_CODE(Keypad0, 98); GC_KEY_CODE(KeypadPeriod, 99);
GC_KEY_CODE(NonUSBackslash, 100); GC_KEY_CODE(Application, 101); GC_KEY_CODE(Power, 102);
GC_KEY_CODE(KeypadEqualSign, 103); GC_KEY_CODE(F13, 104); GC_KEY_CODE(F14, 105); GC_KEY_CODE(F15, 106);
GC_KEY_CODE(F16, 107); GC_KEY_CODE(F17, 108); GC_KEY_CODE(F18, 109); GC_KEY_CODE(F19, 110); GC_KEY_CODE(F20, 111);
GC_KEY_CODE(International1, 135); GC_KEY_CODE(International2, 136); GC_KEY_CODE(International3, 137);
GC_KEY_CODE(International4, 138); GC_KEY_CODE(International5, 139); GC_KEY_CODE(International6, 140);
GC_KEY_CODE(International7, 141); GC_KEY_CODE(International8, 142); GC_KEY_CODE(International9, 143);
GC_KEY_CODE(LANG1, 144); GC_KEY_CODE(LANG2, 145); GC_KEY_CODE(LANG3, 146); GC_KEY_CODE(LANG4, 147);
GC_KEY_CODE(LANG5, 148); GC_KEY_CODE(LANG6, 149); GC_KEY_CODE(LANG7, 150); GC_KEY_CODE(LANG8, 151);
GC_KEY_CODE(LANG9, 152); GC_KEY_CODE(LeftControl, 224); GC_KEY_CODE(LeftShift, 225); GC_KEY_CODE(LeftAlt, 226);
GC_KEY_CODE(LeftGUI, 227); GC_KEY_CODE(RightControl, 228); GC_KEY_CODE(RightShift, 229);
GC_KEY_CODE(RightAlt, 230); GC_KEY_CODE(RightGUI, 231);
#undef GC_KEY_CODE

NSString * const GCProductCategoryDualSense = @"DualSense";
NSString * const GCProductCategoryDualShock4 = @"DualShock 4";
NSString * const GCProductCategoryMFi = @"MFi";
NSString * const GCProductCategoryXboxOne = @"Xbox One";
NSString * const GCProductCategoryHID = @"HID";
NSString * const GCProductCategorySpatialController = @"Spatial Controller";
NSString * const GCProductCategoryArcadeStick = @"Arcade Stick";
NSString * const GCProductCategorySiriRemote1stGen = @"Siri Remote (1st Generation)";
NSString * const GCProductCategorySiriRemote2ndGen = @"Siri Remote (2nd Generation)";
NSString * const GCProductCategoryControlCenterRemote = @"Control Center Remote";
NSString * const GCProductCategoryUniversalElectronicsRemote = @"Universal Electronics Remote";
NSString * const GCProductCategoryCoalescedRemote = @"Coalesced Remote";
NSString * const GCProductCategoryMouse = @"Mouse";
NSString * const GCProductCategoryKeyboard = @"Keyboard";

GCHapticsLocality const GCHapticsLocalityDefault = @"Default";
GCHapticsLocality const GCHapticsLocalityAll = @"All";
GCHapticsLocality const GCHapticsLocalityHandles = @"Handles";
GCHapticsLocality const GCHapticsLocalityLeftHandle = @"Left Handle";
GCHapticsLocality const GCHapticsLocalityRightHandle = @"Right Handle";
GCHapticsLocality const GCHapticsLocalityTriggers = @"Triggers";
GCHapticsLocality const GCHapticsLocalityLeftTrigger = @"Left Trigger";
GCHapticsLocality const GCHapticsLocalityRightTrigger = @"Right Trigger";
const float GCHapticDurationInfinite = 1000000.0f;

const GCExtendedGamepadSnapshotDataVersion GCCurrentExtendedGamepadSnapshotDataVersion = 0x0101;
const GCMicroGamepadSnapshotDataVersion GCCurrentMicroGamepadSnapshotDataVersion = 0x0100;

const GCPoint2 GCPoint2Zero = { 0.0f, 0.0f };

NSString *NSStringFromGCPoint2(GCPoint2 point)
{
    return [NSString stringWithFormat:@"{%g, %g}", point.x, point.y];
}

@implementation NSValue (GCTypes)

+ (instancetype)valueWithGCPoint2:(GCPoint2)point
{
    return [self valueWithBytes:&point objCType:@encode(GCPoint2)];
}

- (GCPoint2)GCPoint2Value
{
    GCPoint2 point = GCPoint2Zero;
    if (strcmp([self objCType], @encode(GCPoint2)) == 0)
        [self getValue:&point size:sizeof(point)];
    return point;
}

@end
