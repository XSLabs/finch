// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Repeating buttons use AppKit's familiar half-second pause followed by short repeats.

import SwiftUICore

@available(macOS 14.0, *)
public struct ButtonRepeatBehavior: Hashable, Sendable {
    private let repeats: Bool?

    private init(repeats: Bool?) {
        self.repeats = repeats
    }

    public static let automatic = ButtonRepeatBehavior(repeats: nil)
    public static let enabled = ButtonRepeatBehavior(repeats: true)
    public static let disabled = ButtonRepeatBehavior(repeats: false)
}

@available(macOS 14.0, *)
private struct _FinchButtonRepeatBehaviorKey: EnvironmentKey {
    static let defaultValue = ButtonRepeatBehavior.automatic
}

@available(macOS 14.0, *)
extension EnvironmentValues {
    public var buttonRepeatBehavior: ButtonRepeatBehavior {
        self[_FinchButtonRepeatBehaviorKey.self]
    }

    var _finchButtonRepeatBehavior: ButtonRepeatBehavior {
        get { self[_FinchButtonRepeatBehaviorKey.self] }
        set { self[_FinchButtonRepeatBehaviorKey.self] = newValue }
    }
}

@available(macOS 14.0, *)
extension View {
    nonisolated public func buttonRepeatBehavior(_ behavior: ButtonRepeatBehavior) -> some View {
        environment(\._finchButtonRepeatBehavior, behavior)
    }
}
