// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Control group labels share the same localized title and symbol rules as Label.

public import Foundation
import DeveloperToolsSupport
import SwiftUICore

@available(macOS 13.0, *)
extension ControlGroup {
    nonisolated public init<C>(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> C)
        where Content == LabeledControlGroupContent<C, Text>, C: View {
        self.init(content: content) { Text(titleKey) }
    }

    @_disfavoredOverload
    nonisolated public init<C>(_ titleResource: LocalizedStringResource, @ViewBuilder content: () -> C)
        where Content == LabeledControlGroupContent<C, Text>, C: View {
        self.init(content: content) { Text(titleResource) }
    }

    @_disfavoredOverload
    nonisolated public init<C, S>(_ title: S, @ViewBuilder content: () -> C)
        where Content == LabeledControlGroupContent<C, Text>, C: View, S: StringProtocol {
        self.init(content: content) { Text(title) }
    }

    nonisolated public init<C>(_ titleKey: LocalizedStringKey, systemImage: String,
                               @ViewBuilder content: () -> C)
        where Content == LabeledControlGroupContent<C, Label<Text, Image>>, C: View {
        self.init(content: content) { Label(titleKey, systemImage: systemImage) }
    }

    @_disfavoredOverload
    nonisolated public init<C>(_ titleResource: LocalizedStringResource, systemImage: String,
                               @ViewBuilder content: () -> C)
        where Content == LabeledControlGroupContent<C, Label<Text, Image>>, C: View {
        self.init(content: content) {
            Label { Text(titleResource) } icon: { Image(systemName: systemImage) }
        }
    }

    @_disfavoredOverload
    nonisolated public init<C, S>(_ title: S, systemImage: String, @ViewBuilder content: () -> C)
        where Content == LabeledControlGroupContent<C, Label<Text, Image>>, C: View, S: StringProtocol {
        self.init(content: content) { Label(title, systemImage: systemImage) }
    }
}

@available(macOS 14.0, *)
extension ControlGroup {
    nonisolated public init<C>(_ titleKey: LocalizedStringKey, image: ImageResource,
                               @ViewBuilder content: () -> C)
        where Content == LabeledControlGroupContent<C, Label<Text, Image>>, C: View {
        self.init(content: content) { Label(titleKey, image: image) }
    }

    @_disfavoredOverload
    nonisolated public init<C>(_ titleResource: LocalizedStringResource, image: ImageResource,
                               @ViewBuilder content: () -> C)
        where Content == LabeledControlGroupContent<C, Label<Text, Image>>, C: View {
        self.init(content: content) {
            Label { Text(titleResource) } icon: { Image(image) }
        }
    }

    @_disfavoredOverload
    nonisolated public init<C, S>(_ title: S, image: ImageResource, @ViewBuilder content: () -> C)
        where Content == LabeledControlGroupContent<C, Label<Text, Image>>, C: View, S: StringProtocol {
        self.init(content: content) { Label(title, image: image) }
    }
}
