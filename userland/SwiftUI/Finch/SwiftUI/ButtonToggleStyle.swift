// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ButtonToggleStyle presents a toggle as a bordered button and shows its selected state.

import SwiftUICore

@available(OpenSwiftUI_v1_0, *)
public struct ButtonToggleStyle: ToggleStyle {
    public init() {}

    @MainActor
    @preconcurrency
    public func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.isOn
        return Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
        }
        .buttonStyle(.bordered)
        .background(RoundedRectangle(cornerRadius: 6).fill(isOn ? Color.accentColor.opacity(0.16) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(isOn ? Color.accentColor.opacity(0.75) : Color.clear, lineWidth: 1)
            .allowsHitTesting(false))
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(Text(isOn ? "On" : "Off"))
    }
}

@available(*, unavailable) extension ButtonToggleStyle: Sendable {}

extension ToggleStyle where Self == ButtonToggleStyle {
    @MainActor
    @preconcurrency
    public static var button: ButtonToggleStyle { .init() }
}
