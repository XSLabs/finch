// SPDX-License-Identifier: MIT OR Apache-2.0
//
// WindowGroup's newer lazy builders and localized data titles keep the group settings while
// using the same window content path as the existing initializer.

public import Foundation
import SwiftUICore

@available(macOS 14.0, *)
extension WindowGroup {
    nonisolated public init(id: String, @ViewBuilder makeContent: @escaping () -> Content) {
        self.init(id: id, title: nil, lazyContent: makeContent)
    }

    @_disfavoredOverload
    nonisolated public init(_ title: Text, id: String, @ViewBuilder makeContent: @escaping () -> Content) {
        self.init(id: id, title: title, lazyContent: makeContent)
    }

    nonisolated public init(_ titleKey: LocalizedStringKey, id: String,
                            @ViewBuilder makeContent: @escaping () -> Content) {
        self.init(Text(titleKey), id: id, makeContent: makeContent)
    }

    @_disfavoredOverload
    nonisolated public init(_ title: LocalizedStringResource, id: String,
                            @ViewBuilder makeContent: @escaping () -> Content) {
        self.init(Text(title), id: id, makeContent: makeContent)
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, id: String, @ViewBuilder makeContent: @escaping () -> Content)
        where S: StringProtocol {
        self.init(Text(title), id: id, makeContent: makeContent)
    }

    nonisolated public init(@ViewBuilder makeContent: @escaping () -> Content) {
        self.init(id: nil, title: nil, lazyContent: makeContent)
    }

    @_disfavoredOverload
    nonisolated public init(_ title: Text, @ViewBuilder makeContent: @escaping () -> Content) {
        self.init(id: nil, title: title, lazyContent: makeContent)
    }

    nonisolated public init(_ titleKey: LocalizedStringKey, @ViewBuilder makeContent: @escaping () -> Content) {
        self.init(Text(titleKey), makeContent: makeContent)
    }

    @_disfavoredOverload
    nonisolated public init(_ title: LocalizedStringResource, @ViewBuilder makeContent: @escaping () -> Content) {
        self.init(Text(title), makeContent: makeContent)
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, @ViewBuilder makeContent: @escaping () -> Content)
        where S: StringProtocol {
        self.init(Text(title), makeContent: makeContent)
    }
}

@available(macOS 13.0, *)
extension WindowGroup {
    @_disfavoredOverload
    nonisolated public init<D, C>(_ title: LocalizedStringResource, id: String, for type: D.Type,
                                  @ViewBuilder content: @escaping (Binding<D?>) -> C)
        where Content == PresentedWindowContent<D, C>, D: Decodable, D: Encodable, D: Hashable, C: View {
        self.init(Text(title), id: id, for: type, content: content)
    }

    @_disfavoredOverload
    nonisolated public init<S, D, C>(_ title: S, id: String, for type: D.Type,
                                     @ViewBuilder content: @escaping (Binding<D?>) -> C)
        where Content == PresentedWindowContent<D, C>, S: StringProtocol,
              D: Decodable, D: Encodable, D: Hashable, C: View {
        self.init(Text(title), id: id, for: type, content: content)
    }

    @_disfavoredOverload
    nonisolated public init<D, C>(_ title: Text, for type: D.Type,
                                  @ViewBuilder content: @escaping (Binding<D?>) -> C)
        where Content == PresentedWindowContent<D, C>, D: Decodable, D: Encodable, D: Hashable, C: View {
        self.init(id: nil, title: title) { PresentedWindowContent(content: content) }
    }

    nonisolated public init<D, C>(_ titleKey: LocalizedStringKey, for type: D.Type,
                                  @ViewBuilder content: @escaping (Binding<D?>) -> C)
        where Content == PresentedWindowContent<D, C>, D: Decodable, D: Encodable, D: Hashable, C: View {
        self.init(Text(titleKey), for: type, content: content)
    }

    @_disfavoredOverload
    nonisolated public init<D, C>(_ title: LocalizedStringResource, for type: D.Type,
                                  @ViewBuilder content: @escaping (Binding<D?>) -> C)
        where Content == PresentedWindowContent<D, C>, D: Decodable, D: Encodable, D: Hashable, C: View {
        self.init(Text(title), for: type, content: content)
    }

    @_disfavoredOverload
    nonisolated public init<S, D, C>(_ title: S, for type: D.Type,
                                     @ViewBuilder content: @escaping (Binding<D?>) -> C)
        where Content == PresentedWindowContent<D, C>, S: StringProtocol,
              D: Decodable, D: Encodable, D: Hashable, C: View {
        self.init(Text(title), for: type, content: content)
    }
}

@available(macOS 13.0, *)
extension WindowGroup {
    nonisolated public init<D, C>(id: String, for type: D.Type = D.self,
                                  @ViewBuilder content: @escaping (Binding<D>) -> C,
                                  defaultValue: @escaping () -> D)
        where Content == PresentedWindowContent<D, C>, D: Decodable, D: Encodable, D: Hashable, C: View {
        self.init(id: id, title: nil) {
            PresentedWindowContent(defaultValue: defaultValue, content: content)
        }
    }

    nonisolated public init<D, C>(for type: D.Type = D.self,
                                  @ViewBuilder content: @escaping (Binding<D>) -> C,
                                  defaultValue: @escaping () -> D)
        where Content == PresentedWindowContent<D, C>, D: Decodable, D: Encodable, D: Hashable, C: View {
        self.init(id: nil, title: nil) {
            PresentedWindowContent(defaultValue: defaultValue, content: content)
        }
    }

    @_disfavoredOverload
    nonisolated public init<D, C>(_ title: Text, id: String, for type: D.Type = D.self,
                                  @ViewBuilder content: @escaping (Binding<D>) -> C,
                                  defaultValue: @escaping () -> D)
        where Content == PresentedWindowContent<D, C>, D: Decodable, D: Encodable, D: Hashable, C: View {
        self.init(id: id, title: title) {
            PresentedWindowContent(defaultValue: defaultValue, content: content)
        }
    }

    nonisolated public init<D, C>(_ titleKey: LocalizedStringKey, id: String, for type: D.Type = D.self,
                                  @ViewBuilder content: @escaping (Binding<D>) -> C,
                                  defaultValue: @escaping () -> D)
        where Content == PresentedWindowContent<D, C>, D: Decodable, D: Encodable, D: Hashable, C: View {
        self.init(Text(titleKey), id: id, for: type, content: content, defaultValue: defaultValue)
    }

    @available(macOS 13.0, *)
    @_disfavoredOverload
    nonisolated public init<D, C>(_ title: LocalizedStringResource, id: String, for type: D.Type = D.self,
                                  @ViewBuilder content: @escaping (Binding<D>) -> C,
                                  defaultValue: @escaping () -> D)
        where Content == PresentedWindowContent<D, C>, D: Decodable, D: Encodable, D: Hashable, C: View {
        self.init(Text(title), id: id, for: type, content: content, defaultValue: defaultValue)
    }

    @_disfavoredOverload
    nonisolated public init<S, D, C>(_ title: S, id: String, for type: D.Type = D.self,
                                     @ViewBuilder content: @escaping (Binding<D>) -> C,
                                     defaultValue: @escaping () -> D)
        where Content == PresentedWindowContent<D, C>, S: StringProtocol,
              D: Decodable, D: Encodable, D: Hashable, C: View {
        self.init(Text(title), id: id, for: type, content: content, defaultValue: defaultValue)
    }

    @_disfavoredOverload
    nonisolated public init<D, C>(_ title: Text, for type: D.Type = D.self,
                                  @ViewBuilder content: @escaping (Binding<D>) -> C,
                                  defaultValue: @escaping () -> D)
        where Content == PresentedWindowContent<D, C>, D: Decodable, D: Encodable, D: Hashable, C: View {
        self.init(id: nil, title: title) {
            PresentedWindowContent(defaultValue: defaultValue, content: content)
        }
    }

    nonisolated public init<D, C>(_ titleKey: LocalizedStringKey, for type: D.Type = D.self,
                                  @ViewBuilder content: @escaping (Binding<D>) -> C,
                                  defaultValue: @escaping () -> D)
        where Content == PresentedWindowContent<D, C>, D: Decodable, D: Encodable, D: Hashable, C: View {
        self.init(Text(titleKey), for: type, content: content, defaultValue: defaultValue)
    }

    @_disfavoredOverload
    nonisolated public init<S, D, C>(_ title: S, for type: D.Type = D.self,
                                     @ViewBuilder content: @escaping (Binding<D>) -> C,
                                     defaultValue: @escaping () -> D)
        where Content == PresentedWindowContent<D, C>, S: StringProtocol,
              D: Decodable, D: Encodable, D: Hashable, C: View {
        self.init(Text(title), for: type, content: content, defaultValue: defaultValue)
    }

    @available(macOS 13.0, *)
    @_disfavoredOverload
    nonisolated public init<D, C>(_ title: LocalizedStringResource, for type: D.Type = D.self,
                                  @ViewBuilder content: @escaping (Binding<D>) -> C,
                                  defaultValue: @escaping () -> D)
        where Content == PresentedWindowContent<D, C>, D: Decodable, D: Encodable, D: Hashable, C: View {
        self.init(Text(title), for: type, content: content, defaultValue: defaultValue)
    }
}
