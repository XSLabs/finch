// SPDX-License-Identifier: MIT OR Apache-2.0
//
// The entry point Apple's inlinable WindowGroup initializers call (macOS 14.5 and later):
// a group whose windows build their content when they open.

@available(OpenSwiftUI_v1_0, *)
extension WindowGroup {
    nonisolated public init(id: String, @ViewBuilder content: () -> Content) {
        self.id = id
        self.title = nil
        self.content = .eager(content())
    }

    nonisolated public init(_ title: Text, id: String, @ViewBuilder content: () -> Content) {
        self.id = id
        self.title = title
        self.content = .eager(content())
    }

    nonisolated public init(_ titleKey: LocalizedStringKey, id: String,
                            @ViewBuilder content: () -> Content) {
        self.init(Text(titleKey), id: id, content: content)
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, id: String, @ViewBuilder content: () -> Content)
        where S: StringProtocol {
        self.init(Text(title), id: id, content: content)
    }

    @_disfavoredOverload
    nonisolated public init(_ title: Text, @ViewBuilder content: () -> Content) {
        self.id = nil
        self.title = title
        self.content = .eager(content())
    }

    nonisolated public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(Text(titleKey), content: content)
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, @ViewBuilder content: () -> Content) where S: StringProtocol {
        self.init(Text(title), content: content)
    }
}

@available(OpenSwiftUI_v5_0, *)
extension WindowGroup {
    @usableFromInline
    nonisolated internal init(id: String? = nil, title: Text? = nil, @ViewBuilder lazyContent: @escaping () -> Content) {
        self.title = title
        self.id = id
        self.content = .lazy(lazyContent)
    }
}
