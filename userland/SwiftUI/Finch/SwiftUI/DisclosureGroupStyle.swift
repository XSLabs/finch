// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Disclosure group styles let an app choose how a disclosure row and its expanded content
// appear. The default style follows macOS's disclosure triangle and indented content.

import SwiftUICore

@available(macOS 13.0, *)
@MainActor
@preconcurrency
public protocol DisclosureGroupStyle {
    associatedtype Body: View
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
    typealias Configuration = DisclosureGroupStyleConfiguration
}

@available(macOS 13.0, *)
struct _FinchAnyDisclosureGroupStyle {
    var makeBody: (DisclosureGroupStyleConfiguration) -> AnyView

    init<S: DisclosureGroupStyle>(_ style: S) {
        makeBody = { AnyView(style.makeBody(configuration: $0)) }
    }
}

@available(macOS 13.0, *)
private struct _FinchDisclosureGroupStylesKey: EnvironmentKey {
    static var defaultValue: [_FinchAnyDisclosureGroupStyle] { [] }
}

@available(macOS 13.0, *)
extension EnvironmentValues {
    var _finchDisclosureGroupStyles: [_FinchAnyDisclosureGroupStyle] {
        get { self[_FinchDisclosureGroupStylesKey.self] }
        set { self[_FinchDisclosureGroupStylesKey.self] = newValue }
    }
}

@available(macOS 13.0, *)
extension View {
    nonisolated public func disclosureGroupStyle<S>(_ style: S) -> some View where S: DisclosureGroupStyle {
        transformEnvironment(\._finchDisclosureGroupStyles) { $0.append(_FinchAnyDisclosureGroupStyle(style)) }
    }
}

@available(macOS 13.0, *)
public struct DisclosureGroupStyleConfiguration {
    @MainActor @preconcurrency
    public struct Label: ViewAlias {
        public typealias Body = Never
        package init() {}
    }

    @MainActor @preconcurrency
    public struct Content: ViewAlias {
        public typealias Body = Never
        package init() {}
    }

    public let label = Label()
    public let content = Content()
    @Binding public var isExpanded: Bool

    package init(isExpanded: Binding<Bool>) {
        _isExpanded = isExpanded
    }
}

@available(*, unavailable)
extension DisclosureGroupStyleConfiguration: Sendable {}
@available(*, unavailable)
extension DisclosureGroupStyleConfiguration.Label: Sendable {}
@available(*, unavailable)
extension DisclosureGroupStyleConfiguration.Content: Sendable {}

@available(macOS 13.0, *)
@MainActor
@preconcurrency
public struct AutomaticDisclosureGroupStyle: DisclosureGroupStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(verbatim: configuration.isExpanded ? "\u{25BE}" : "\u{25B8}")
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                configuration.label
            }
            .contentShape(Rectangle())
            .onTapGesture { configuration.isExpanded.toggle() }
            if configuration.isExpanded {
                configuration.content.padding(.leading, 16)
            }
        }
    }
}

@available(*, unavailable)
extension AutomaticDisclosureGroupStyle: Sendable {}

@available(macOS 13.0, *)
extension DisclosureGroupStyle where Self == AutomaticDisclosureGroupStyle {
    public static var automatic: AutomaticDisclosureGroupStyle { .init() }
}
