// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Public Text accessibility and speech modifiers store their values with the text.

public import Foundation
@_spi(ForOpenSwiftUIOnly) import SwiftUICore

@available(macOS 12.0, *)
extension Text {
    nonisolated public func accessibilityTextContentType(_ value: AccessibilityTextContentType) -> Text {
        _finchAccessibilityTextContentType(value)
    }

    nonisolated public func accessibilityHeading(_ level: AccessibilityHeadingLevel) -> Text {
        _finchAccessibilityHeading(level)
    }

    nonisolated public func accessibilityLabel(_ label: Text) -> Text {
        _finchAccessibilityLabel(label)
    }

    nonisolated public func accessibilityLabel(_ labelKey: LocalizedStringKey) -> Text {
        _finchAccessibilityLabel(Text(labelKey))
    }

    @_disfavoredOverload
    nonisolated public func accessibilityLabel(_ label: LocalizedStringResource) -> Text {
        _finchAccessibilityLabel(Text(label))
    }

    @_disfavoredOverload
    nonisolated public func accessibilityLabel<S>(_ label: S) -> Text where S: StringProtocol {
        _finchAccessibilityLabel(Text(verbatim: String(label)))
    }

    nonisolated public func speechAlwaysIncludesPunctuation(_ value: Bool = true) -> Text {
        _finchSpeechAlwaysIncludesPunctuation(value)
    }

    nonisolated public func speechSpellsOutCharacters(_ value: Bool = true) -> Text {
        _finchSpeechSpellsOutCharacters(value)
    }

    nonisolated public func speechAdjustedPitch(_ value: Double) -> Text {
        _finchSpeechAdjustedPitch(value)
    }
}

@available(macOS 12.0, *)
extension View {
    nonisolated public func speechAlwaysIncludesPunctuation(_ value: Bool = true) -> some View {
        environment(\.speechAlwaysIncludesPunctuation, Optional(value))
    }

    nonisolated public func speechSpellsOutCharacters(_ value: Bool = true) -> some View {
        environment(\.speechSpellsOutCharacters, Optional(value))
    }

    nonisolated public func speechAdjustedPitch(_ value: Double) -> some View {
        environment(\.speechAdjustedPitch, Optional(value))
    }
}
