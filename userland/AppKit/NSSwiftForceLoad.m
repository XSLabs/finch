/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* The Swift overlay's force-load symbol, which Apple's AppKit carries (its Swift half
   is in the framework; /usr/lib/swift/libswiftAppKit.dylib re-exports it). */
__attribute__((visibility("default"))) char swift_force_load_AppKit __asm("__swift_FORCE_LOAD_$_swiftAppKit") = 0;
