// SPDX-License-Identifier: MIT OR Apache-2.0
#import <GameController/GameController.h>
#import <AppKit/AppKit.h>
#import <IOKit/hid/IOHIDDevice.h>
#import <IOKit/hid/IOHIDManager.h>
#import <objc/runtime.h>
#include <math.h>

@interface GCControllerElement (FinchPrivate)
- (instancetype)_initWithAlias:(NSString *)alias collection:(GCControllerElement *)collection
                        analog:(BOOL)analog owner:(id<GCDevice>)owner;
- (void)_setOwner:(id<GCDevice>)owner;
- (id<GCDevice>)_owner;
- (void)_setAliases:(NSSet *)aliases;
@end

@interface GCControllerButtonInput (FinchPrivate)
- (void)_setInputValue:(float)value touched:(BOOL)touched notify:(BOOL)notify;
@end

@interface GCControllerAxisInput (FinchPrivate)
- (void)_setInputValue:(float)value notify:(BOOL)notify;
@end

@interface GCControllerDirectionPad (FinchPrivate)
- (instancetype)_initWithAlias:(NSString *)alias owner:(id<GCDevice>)owner analog:(BOOL)analog;
- (void)_setPositionX:(float)x y:(float)y notify:(BOOL)notify;
@end

@interface GCPhysicalInputProfile (FinchPrivate)
- (void)_setDevice:(id<GCDevice>)device;
- (void)_setLastEventTimestamp:(NSTimeInterval)timestamp;
- (void)_addElement:(GCControllerElement *)element alias:(NSString *)alias kind:(NSUInteger)kind;
- (void)_notifyElementChanged:(GCControllerElement *)element;
- (void)_setStateFromProfile:(GCPhysicalInputProfile *)profile;
@end

@interface GCExtendedGamepad (FinchPrivate)
- (instancetype)_initWithController:(GCController *)controller;
@end

@interface GCMicroGamepad (FinchPrivate)
- (instancetype)_initWithController:(GCController *)controller;
@end

@interface GCGamepad (FinchPrivate)
- (instancetype)_initWithController:(GCController *)controller;
@end

@interface GCKeyboardInput (FinchPrivate)
- (instancetype)_initWithKeyboard:(GCKeyboard *)keyboard;
- (void)_setKeyCode:(GCKeyCode)code pressed:(BOOL)pressed timestamp:(NSTimeInterval)timestamp;
@end

@interface GCMouseInput (FinchPrivate)
- (instancetype)_initWithMouse:(GCMouse *)mouse;
- (void)_moveByX:(float)x y:(float)y;
- (void)_setButton:(NSInteger)button pressed:(BOOL)pressed;
- (void)_scrollByX:(float)x y:(float)y;
@end

@interface GCController (FinchPrivate)
- (instancetype)_initSnapshotWithProfileKind:(NSUInteger)kind;
- (void)_setProfile:(GCPhysicalInputProfile *)profile;
@end

@interface GCKeyboard (FinchPrivate)
+ (GCKeyboard *)_keyboardForInputEvent;
@end

@interface GCMouse (FinchPrivate)
+ (GCMouse *)_mouseForInputEvent;
@end

void GCInstallEventMonitors(void);
void GCKeyboardHandleEvent(NSEvent *event);
void GCMouseHandleEvent(NSEvent *event);
