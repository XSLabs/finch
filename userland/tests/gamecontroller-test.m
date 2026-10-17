// SPDX-License-Identifier: MIT OR Apache-2.0
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <dlfcn.h>
#include <stdio.h>

static void printFrameworkImage(void)
{
    Dl_info info = {0};
    if (dladdr((const void *)[GCController class], &info) && info.dli_fname)
        puts(info.dli_fname);
    else
        puts("(GameController image unavailable)");
}

int main(void)
{
    @autoreleasepool {
        printFrameworkImage();
#define PRINT_NAME(name) printf(#name "=%s\n", name.UTF8String)
        PRINT_NAME(GCInputButtonA); PRINT_NAME(GCInputButtonB); PRINT_NAME(GCInputButtonX); PRINT_NAME(GCInputButtonY);
        PRINT_NAME(GCInputDirectionPad); PRINT_NAME(GCInputThumbstick); PRINT_NAME(GCInputLeftThumbstick);
        PRINT_NAME(GCInputRightThumbstick); PRINT_NAME(GCInputThumbstickButton);
        PRINT_NAME(GCInputLeftThumbstickButton); PRINT_NAME(GCInputRightThumbstickButton);
        PRINT_NAME(GCInputLeftShoulder); PRINT_NAME(GCInputRightShoulder); PRINT_NAME(GCInputLeftBumper);
        PRINT_NAME(GCInputRightBumper); PRINT_NAME(GCInputTrigger); PRINT_NAME(GCInputLeftTrigger);
        PRINT_NAME(GCInputRightTrigger);
        if (@available(macOS 26.4, *)) {
            PRINT_NAME(GCInputLeftSideButton); PRINT_NAME(GCInputRightSideButton);
        }
        PRINT_NAME(GCInputButtonHome); PRINT_NAME(GCInputButtonMenu); PRINT_NAME(GCInputButtonOptions);
        PRINT_NAME(GCInputButtonShare); PRINT_NAME(GCInputXboxPaddleOne); PRINT_NAME(GCInputXboxPaddleTwo);
        PRINT_NAME(GCInputXboxPaddleThree); PRINT_NAME(GCInputXboxPaddleFour);
        PRINT_NAME(GCInputDualShockTouchpadOne); PRINT_NAME(GCInputDualShockTouchpadTwo);
        PRINT_NAME(GCInputDualShockTouchpadButton); PRINT_NAME(GCInputGripButton); PRINT_NAME(GCInputLeftPaddle);
        PRINT_NAME(GCInputRightPaddle); PRINT_NAME(GCInputDirectionalCardinalDpad);
        PRINT_NAME(GCInputDirectionalCenterButton); PRINT_NAME(GCInputDirectionalDpad);
        PRINT_NAME(GCInputDirectionalTouchSurfaceButton); PRINT_NAME(GCInputMicroGamepadDpad);
        PRINT_NAME(GCInputMicroGamepadButtonA); PRINT_NAME(GCInputMicroGamepadButtonX);
        PRINT_NAME(GCInputMicroGamepadButtonMenu); PRINT_NAME(GCInputSteeringWheel); PRINT_NAME(GCInputShifter);
        PRINT_NAME(GCInputPedalAccelerator); PRINT_NAME(GCInputPedalBrake); PRINT_NAME(GCInputPedalClutch);
        printf("GCInputArcadeButtonName=%s\n", GCInputArcadeButtonName(2, 3).UTF8String);
        printf("GCInputBackLeftButton=%s\n", GCInputBackLeftButton(0).UTF8String);
        printf("GCInputBackRightButton=%s\n", GCInputBackRightButton(1).UTF8String);
#undef PRINT_NAME
        struct { const char *codeName; GCKeyCode code; NSString *keyName; } keys[] = {
            {"KeyA", GCKeyCodeKeyA, GCKeyA},
            {"KeyB", GCKeyCodeKeyB, GCKeyB},
            {"KeyC", GCKeyCodeKeyC, GCKeyC},
            {"KeyD", GCKeyCodeKeyD, GCKeyD},
            {"KeyE", GCKeyCodeKeyE, GCKeyE},
            {"KeyF", GCKeyCodeKeyF, GCKeyF},
            {"KeyG", GCKeyCodeKeyG, GCKeyG},
            {"KeyH", GCKeyCodeKeyH, GCKeyH},
            {"KeyI", GCKeyCodeKeyI, GCKeyI},
            {"KeyJ", GCKeyCodeKeyJ, GCKeyJ},
            {"KeyK", GCKeyCodeKeyK, GCKeyK},
            {"KeyL", GCKeyCodeKeyL, GCKeyL},
            {"KeyM", GCKeyCodeKeyM, GCKeyM},
            {"KeyN", GCKeyCodeKeyN, GCKeyN},
            {"KeyO", GCKeyCodeKeyO, GCKeyO},
            {"KeyP", GCKeyCodeKeyP, GCKeyP},
            {"KeyQ", GCKeyCodeKeyQ, GCKeyQ},
            {"KeyR", GCKeyCodeKeyR, GCKeyR},
            {"KeyS", GCKeyCodeKeyS, GCKeyS},
            {"KeyT", GCKeyCodeKeyT, GCKeyT},
            {"KeyU", GCKeyCodeKeyU, GCKeyU},
            {"KeyV", GCKeyCodeKeyV, GCKeyV},
            {"KeyW", GCKeyCodeKeyW, GCKeyW},
            {"KeyX", GCKeyCodeKeyX, GCKeyX},
            {"KeyY", GCKeyCodeKeyY, GCKeyY},
            {"KeyZ", GCKeyCodeKeyZ, GCKeyZ},
            {"One", GCKeyCodeOne, GCKeyOne},
            {"Two", GCKeyCodeTwo, GCKeyTwo},
            {"Three", GCKeyCodeThree, GCKeyThree},
            {"Four", GCKeyCodeFour, GCKeyFour},
            {"Five", GCKeyCodeFive, GCKeyFive},
            {"Six", GCKeyCodeSix, GCKeySix},
            {"Seven", GCKeyCodeSeven, GCKeySeven},
            {"Eight", GCKeyCodeEight, GCKeyEight},
            {"Nine", GCKeyCodeNine, GCKeyNine},
            {"Zero", GCKeyCodeZero, GCKeyZero},
            {"ReturnOrEnter", GCKeyCodeReturnOrEnter, GCKeyReturnOrEnter},
            {"Escape", GCKeyCodeEscape, GCKeyEscape},
            {"DeleteOrBackspace", GCKeyCodeDeleteOrBackspace, GCKeyDeleteOrBackspace},
            {"Tab", GCKeyCodeTab, GCKeyTab},
            {"Spacebar", GCKeyCodeSpacebar, GCKeySpacebar},
            {"Hyphen", GCKeyCodeHyphen, GCKeyHyphen},
            {"EqualSign", GCKeyCodeEqualSign, GCKeyEqualSign},
            {"OpenBracket", GCKeyCodeOpenBracket, GCKeyOpenBracket},
            {"CloseBracket", GCKeyCodeCloseBracket, GCKeyCloseBracket},
            {"Backslash", GCKeyCodeBackslash, GCKeyBackslash},
            {"NonUSPound", GCKeyCodeNonUSPound, GCKeyNonUSPound},
            {"Semicolon", GCKeyCodeSemicolon, GCKeySemicolon},
            {"Quote", GCKeyCodeQuote, GCKeyQuote},
            {"GraveAccentAndTilde", GCKeyCodeGraveAccentAndTilde, GCKeyGraveAccentAndTilde},
            {"Comma", GCKeyCodeComma, GCKeyComma},
            {"Period", GCKeyCodePeriod, GCKeyPeriod},
            {"Slash", GCKeyCodeSlash, GCKeySlash},
            {"CapsLock", GCKeyCodeCapsLock, GCKeyCapsLock},
            {"F1", GCKeyCodeF1, GCKeyF1},
            {"F2", GCKeyCodeF2, GCKeyF2},
            {"F3", GCKeyCodeF3, GCKeyF3},
            {"F4", GCKeyCodeF4, GCKeyF4},
            {"F5", GCKeyCodeF5, GCKeyF5},
            {"F6", GCKeyCodeF6, GCKeyF6},
            {"F7", GCKeyCodeF7, GCKeyF7},
            {"F8", GCKeyCodeF8, GCKeyF8},
            {"F9", GCKeyCodeF9, GCKeyF9},
            {"F10", GCKeyCodeF10, GCKeyF10},
            {"F11", GCKeyCodeF11, GCKeyF11},
            {"F12", GCKeyCodeF12, GCKeyF12},
            {"PrintScreen", GCKeyCodePrintScreen, GCKeyPrintScreen},
            {"ScrollLock", GCKeyCodeScrollLock, GCKeyScrollLock},
            {"Pause", GCKeyCodePause, GCKeyPause},
            {"Insert", GCKeyCodeInsert, GCKeyInsert},
            {"Home", GCKeyCodeHome, GCKeyHome},
            {"PageUp", GCKeyCodePageUp, GCKeyPageUp},
            {"DeleteForward", GCKeyCodeDeleteForward, GCKeyDeleteForward},
            {"End", GCKeyCodeEnd, GCKeyEnd},
            {"PageDown", GCKeyCodePageDown, GCKeyPageDown},
            {"RightArrow", GCKeyCodeRightArrow, GCKeyRightArrow},
            {"LeftArrow", GCKeyCodeLeftArrow, GCKeyLeftArrow},
            {"DownArrow", GCKeyCodeDownArrow, GCKeyDownArrow},
            {"UpArrow", GCKeyCodeUpArrow, GCKeyUpArrow},
            {"KeypadNumLock", GCKeyCodeKeypadNumLock, GCKeyKeypadNumLock},
            {"KeypadSlash", GCKeyCodeKeypadSlash, GCKeyKeypadSlash},
            {"KeypadAsterisk", GCKeyCodeKeypadAsterisk, GCKeyKeypadAsterisk},
            {"KeypadHyphen", GCKeyCodeKeypadHyphen, GCKeyKeypadHyphen},
            {"KeypadPlus", GCKeyCodeKeypadPlus, GCKeyKeypadPlus},
            {"KeypadEnter", GCKeyCodeKeypadEnter, GCKeyKeypadEnter},
            {"Keypad1", GCKeyCodeKeypad1, GCKeyKeypad1},
            {"Keypad2", GCKeyCodeKeypad2, GCKeyKeypad2},
            {"Keypad3", GCKeyCodeKeypad3, GCKeyKeypad3},
            {"Keypad4", GCKeyCodeKeypad4, GCKeyKeypad4},
            {"Keypad5", GCKeyCodeKeypad5, GCKeyKeypad5},
            {"Keypad6", GCKeyCodeKeypad6, GCKeyKeypad6},
            {"Keypad7", GCKeyCodeKeypad7, GCKeyKeypad7},
            {"Keypad8", GCKeyCodeKeypad8, GCKeyKeypad8},
            {"Keypad9", GCKeyCodeKeypad9, GCKeyKeypad9},
            {"Keypad0", GCKeyCodeKeypad0, GCKeyKeypad0},
            {"KeypadPeriod", GCKeyCodeKeypadPeriod, GCKeyKeypadPeriod},
            {"NonUSBackslash", GCKeyCodeNonUSBackslash, GCKeyNonUSBackslash},
            {"Application", GCKeyCodeApplication, GCKeyApplication},
            {"Power", GCKeyCodePower, GCKeyPower},
            {"KeypadEqualSign", GCKeyCodeKeypadEqualSign, GCKeyKeypadEqualSign},
            {"F13", GCKeyCodeF13, GCKeyF13},
            {"F14", GCKeyCodeF14, GCKeyF14},
            {"F15", GCKeyCodeF15, GCKeyF15},
            {"F16", GCKeyCodeF16, GCKeyF16},
            {"F17", GCKeyCodeF17, GCKeyF17},
            {"F18", GCKeyCodeF18, GCKeyF18},
            {"F19", GCKeyCodeF19, GCKeyF19},
            {"F20", GCKeyCodeF20, GCKeyF20},
            {"International1", GCKeyCodeInternational1, GCKeyInternational1},
            {"International2", GCKeyCodeInternational2, GCKeyInternational2},
            {"International3", GCKeyCodeInternational3, GCKeyInternational3},
            {"International4", GCKeyCodeInternational4, GCKeyInternational4},
            {"International5", GCKeyCodeInternational5, GCKeyInternational5},
            {"International6", GCKeyCodeInternational6, GCKeyInternational6},
            {"International7", GCKeyCodeInternational7, GCKeyInternational7},
            {"International8", GCKeyCodeInternational8, GCKeyInternational8},
            {"International9", GCKeyCodeInternational9, GCKeyInternational9},
            {"LANG1", GCKeyCodeLANG1, GCKeyLANG1},
            {"LANG2", GCKeyCodeLANG2, GCKeyLANG2},
            {"LANG3", GCKeyCodeLANG3, GCKeyLANG3},
            {"LANG4", GCKeyCodeLANG4, GCKeyLANG4},
            {"LANG5", GCKeyCodeLANG5, GCKeyLANG5},
            {"LANG6", GCKeyCodeLANG6, GCKeyLANG6},
            {"LANG7", GCKeyCodeLANG7, GCKeyLANG7},
            {"LANG8", GCKeyCodeLANG8, GCKeyLANG8},
            {"LANG9", GCKeyCodeLANG9, GCKeyLANG9},
            {"LeftControl", GCKeyCodeLeftControl, GCKeyLeftControl},
            {"LeftShift", GCKeyCodeLeftShift, GCKeyLeftShift},
            {"LeftAlt", GCKeyCodeLeftAlt, GCKeyLeftAlt},
            {"LeftGUI", GCKeyCodeLeftGUI, GCKeyLeftGUI},
            {"RightControl", GCKeyCodeRightControl, GCKeyRightControl},
            {"RightShift", GCKeyCodeRightShift, GCKeyRightShift},
            {"RightAlt", GCKeyCodeRightAlt, GCKeyRightAlt},
            {"RightGUI", GCKeyCodeRightGUI, GCKeyRightGUI}
        };
        for (NSUInteger i = 0; i < sizeof(keys) / sizeof(keys[0]); i++)
            printf("key-%s=%ld/%s\n", keys[i].codeName, (long)keys[i].code, keys[i].keyName.UTF8String);
        printf("devices: controllers=%lu current=%d keyboard=%d mice=%lu mouse=%d\n",
               (unsigned long)[[GCController controllers] count], [GCController current] != nil,
               [GCKeyboard coalescedKeyboard] != nil, (unsigned long)[[GCMouse mice] count],
               [GCMouse current] != nil);

        GCController *controller = [GCController controllerWithExtendedGamepad];
        GCExtendedGamepad *gamepad = controller.extendedGamepad;
        gamepad.buttonA.value = 0.4f;
        [gamepad.dpad setValueForXAxis:0.5f yAxis:-0.5f];
        printf("profile: extended=%d snapshot=%d A=%.2f pressed=%d aliases=%lu dpad=%.2f,%.2f right=%d down=%d\n",
               gamepad != nil, controller.snapshot, gamepad.buttonA.value, gamepad.buttonA.pressed,
               (unsigned long)gamepad.buttonA.aliases.count,
               gamepad.dpad.xAxis.value, gamepad.dpad.yAxis.value,
               gamepad.dpad.right.pressed, gamepad.dpad.down.pressed);

        GCExtendedGamepadSnapshot *snapshot = [gamepad saveSnapshot];
        GCExtendedGamepadSnapshotData state = {0};
        BOOL parsed = GCExtendedGamepadSnapshotDataFromNSData(&state, snapshot.snapshotData);
        printf("snapshot: saved=%d parsed=%d version=%u size=%u A=%.2f dpad=%.2f,%.2f\n",
               snapshot != nil, parsed, state.version, state.size,
               state.buttonA, state.dpadX, state.dpadY);

        GCController *microController = [GCController controllerWithMicroGamepad];
        GCMicroGamepad *micro = microController.microGamepad;
        micro.buttonA.value = 0.6f;
        [micro.dpad setValueForXAxis:-0.25f yAxis:0.75f];
        printf("micro: profile=%d snapshot=%d A=%.2f pressed=%d dpad=%.2f,%.2f left=%d up=%d\n",
               micro != nil, microController.snapshot, micro.buttonA.value, micro.buttonA.pressed,
               micro.dpad.xAxis.value, micro.dpad.yAxis.value,
               micro.dpad.left.pressed, micro.dpad.up.pressed);
        GCMicroGamepadSnapshot *microSnapshot = [micro saveSnapshot];
        GCMicroGamepadSnapshotData microState = {0};
        BOOL microParsed = GCMicroGamepadSnapshotDataFromNSData(&microState, microSnapshot.snapshotData);
        printf("micro snapshot: saved=%d parsed=%d version=%u size=%u A=%.2f dpad=%.2f,%.2f\n",
               microSnapshot != nil, microParsed, microState.version, microState.size,
               microState.buttonA, microState.dpadX, microState.dpadY);
    }
    return 0;
}
