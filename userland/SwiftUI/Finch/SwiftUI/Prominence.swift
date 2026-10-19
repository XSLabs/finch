// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Control prominence, to Apple's interface. The button styles use the increased value for
// the prominent AppKit bezel.

@available(OpenSwiftUI_v3_0, *)
@frozen
public enum Prominence: Hashable, Sendable {
    case standard
    case increased
}

@_silgen_name("$s7SwiftUI10ProminenceO8standardyA2CmF")
public func _finchProminenceStandard(_ type: Prominence.Type) -> Prominence { .standard }

@_silgen_name("$s7SwiftUI10ProminenceO9increasedyA2CmF")
public func _finchProminenceIncreased(_ type: Prominence.Type) -> Prominence { .increased }

@_silgen_name("$s7SwiftUI10ProminenceO9increasedyA2CmFWC")
public func _finchProminenceIncreasedForApps(_ type: Prominence.Type) -> Prominence { .increased }
