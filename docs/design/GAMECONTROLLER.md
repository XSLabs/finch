# GameController

Finch's GameController framework builds against the public macOS SDK headers. The build
does not copy Apple's headers or binaries into Finch. Objective-C objects use manual
retain and release, like the nearby Finch frameworks.

`GCController controllerWithExtendedGamepad` and `controllerWithMicroGamepad` create
writable snapshot profiles. Their buttons, axes and direction pads keep their values,
pressed and touched states, aliases, and change handlers. Extended and micro gamepad
snapshot data uses the version and byte layout declared by the SDK. The host comparison
checks button and direction-pad values, aliases, snapshot fields and the public input-name
strings against Apple's framework.

Finch AppKit passes local key, mouse, drag and scroll events through `NSEvent` monitors.
GameController uses those events to update its coalesced keyboard and mouse input objects.
Keyboard keys use the USB HID key codes exposed by `GCKeyCode`; key presses and releases
call the key-change handler. Mouse movement reports deltas, and button and scroll events
update the mouse profile.

Physical gamepad discovery cannot work yet. Finch IOKit returns no HID device list and does
not export `IOHIDDeviceGetProperty`. This framework does not change IOKit or invent
controllers. `GCController.controllers` is empty, `current` is nil, and no controller
connection notifications are sent. `supportsHIDDevice:` returns `NO` when the property
reader is unavailable.

Controller battery, light and haptics objects need a real supported device, so snapshot
controllers return `nil` for those properties. Those device classes and their services
are left out. `GCVirtualController` is unavailable on macOS in the SDK and is not included.

The API audit finds 545 of 907 public items. The focused host test matches Apple's
GameController framework. It does not test physical controller discovery, hardware
keyboard or mouse delivery, battery reporting, or haptics.
