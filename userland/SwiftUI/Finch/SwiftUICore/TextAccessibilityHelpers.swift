// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Text keeps accessibility and speech details with its styled text data.

import Foundation

private final class _FinchSpeechTextModifier: AnyTextModifier {
    let value: AccessibilitySpeechAttributes

    init(_ value: AccessibilitySpeechAttributes) {
        self.value = value
    }

    override func isStyled(options: Text.ResolveOptions) -> Bool {
        options.contains(.includeAccessibility)
    }

    override func modify(style: inout Text.Style, environment: EnvironmentValues) {
        if let existing = style.speech {
            style.speech = value.combined(with: existing)
        } else {
            style.speech = value
        }
    }

    override func isEqual(to other: AnyTextModifier) -> Bool {
        guard let other = other as? _FinchSpeechTextModifier else { return false }
        return value == other.value
    }
}

@_spi(ForOpenSwiftUIOnly)
public extension Text {
    func _finchAccessibilityTextContentType(_ value: AccessibilityTextContentType) -> Text {
        modified(with: .anyTextModifier(AccessibilityTextModifier(.init(contentType: value))))
    }

    func _finchAccessibilityHeading(_ level: AccessibilityHeadingLevel) -> Text {
        modified(with: .anyTextModifier(AccessibilityTextModifier(.init(headingLevel: level))))
    }

    func _finchAccessibilityLabel(_ label: Text) -> Text {
        modified(with: .anyTextModifier(AccessibilityTextModifier(.init(label: label))))
    }

    func _finchSpeechAlwaysIncludesPunctuation(_ value: Bool) -> Text {
        modified(with: .anyTextModifier(_FinchSpeechTextModifier(.init(alwaysIncludesPunctuation: value))))
    }

    func _finchSpeechSpellsOutCharacters(_ value: Bool) -> Text {
        modified(with: .anyTextModifier(_FinchSpeechTextModifier(.init(spellsOutCharacters: value))))
    }

    func _finchSpeechAdjustedPitch(_ value: Double) -> Text {
        modified(with: .anyTextModifier(_FinchSpeechTextModifier(.init(adjustedPitch: value))))
    }
}
