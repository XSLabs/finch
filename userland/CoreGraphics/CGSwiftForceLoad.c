/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* The Swift overlay's force-load symbol, which Apple's CoreGraphics carries (its Swift
   half is in the framework; /usr/lib/swift/libswiftCoreGraphics.dylib re-exports it). */
__attribute__((visibility("default"))) char swift_force_load_CoreGraphics __asm("__swift_FORCE_LOAD_$_swiftCoreGraphics") = 0;
