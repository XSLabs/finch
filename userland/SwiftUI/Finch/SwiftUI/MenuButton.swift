// SPDX-License-Identifier: MIT OR Apache-2.0
//
// The macOS 10.15 menu button keeps the old name while using Finch's working Menu view.

import SwiftUICore

@available(macOS, introduced: 10.15, deprecated: 100000.0, message: "Use Menu instead.")
public struct MenuButton<Label, Content>: View where Label: View, Content: View {
    var label: Label
    var content: Content

    nonisolated public init(label: Label, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    public var body: some View {
        Menu(content: { content }, label: { label })
    }
}

@available(macOS, introduced: 10.15, deprecated: 100000.0, message: "Use Menu instead.")
extension MenuButton where Label == Text {
    nonisolated public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(label: Text(titleKey), content: content)
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, @ViewBuilder content: () -> Content) where S: StringProtocol {
        self.init(label: Text(title), content: content)
    }
}
