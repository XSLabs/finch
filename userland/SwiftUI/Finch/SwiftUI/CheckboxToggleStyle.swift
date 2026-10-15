// SPDX-License-Identifier: MIT OR Apache-2.0
//
// The macOS checkbox toggle style, drawn with AppKit's native checkbox.

import AppKit
import SwiftUICore

@available(macOS 10.15, *)
@available(iOS, unavailable)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
@available(visionOS, unavailable)
extension ToggleStyle where Self == CheckboxToggleStyle {
    @_alwaysEmitIntoClient
    @MainActor
    @preconcurrency
    public static var checkbox: CheckboxToggleStyle { .init() }
}

@available(macOS 10.15, *)
@available(iOS, unavailable)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
@available(visionOS, unavailable)
public struct CheckboxToggleStyle: ToggleStyle {
    public init() {}

    @MainActor
    @preconcurrency
    public func makeBody(configuration: Configuration) -> some View {
        let state = Binding<ToggleState>(get: {
            if #available(OpenSwiftUI_v4_0, *), configuration.isMixed { return .mixed }
            return configuration.isOn ? .on : .off
        }, set: { configuration.isOn = $0 != .off })
        return HStack(spacing: 6) {
            _FinchCheckbox(state: state).fixedSize()
            _FinchControlLabel(label: configuration.label)
        }
    }
}

@available(*, unavailable)
extension CheckboxToggleStyle: Sendable {}
