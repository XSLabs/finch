// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Localized accessibility labels flow through the same text-backed label storage.

public import Foundation
import SwiftUICore

@available(macOS 15.0, *)
extension View {
    @_disfavoredOverload
    nonisolated public func accessibilityLabel(_ label: LocalizedStringResource, isEnabled: Bool) -> ModifiedContent<Self, AccessibilityAttachmentModifier> {
        accessibilityLabel(Text(label), isEnabled: isEnabled)
    }
}

@available(macOS 13.0, *)
extension ModifiedContent where Modifier == AccessibilityAttachmentModifier {
    @available(macOS 15.0, *)
    @_disfavoredOverload
    nonisolated public func accessibilityLabel(_ label: LocalizedStringResource, isEnabled: Bool) -> ModifiedContent<Content, Modifier> {
        accessibilityLabel(Text(label), isEnabled: isEnabled)
    }

    @_disfavoredOverload
    nonisolated public func accessibilityLabel(_ label: LocalizedStringResource) -> ModifiedContent<Content, Modifier> {
        accessibilityLabel(Text(label))
    }
}
