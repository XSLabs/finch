// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Table styles change the table's inset, border and alternating row backgrounds.

import AppKit
import SwiftUICore

@available(OpenSwiftUI_v3_0, *)
@MainActor
@preconcurrency
public protocol TableStyle {
    associatedtype Body: View
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
    typealias Configuration = TableStyleConfiguration
}

@available(OpenSwiftUI_v3_0, *)
public struct TableStyleConfiguration {
    struct Content: ViewAlias {
        public typealias Body = Never
        package init() {}
    }

    let content: TableStyleConfiguration.Content

    init() {
        content = Content()
    }
}

@available(*, unavailable) extension TableStyleConfiguration: Sendable {}
@available(*, unavailable) extension TableStyleConfiguration.Content: Sendable {}

enum _FinchTableStyleKind: Equatable {
    case automatic
    case inset
    case bordered
}

struct _FinchTableStyleAppearance {
    var kind: _FinchTableStyleKind
    var alternatesRowBackgrounds: Bool
}

private struct _FinchTableStyleKey: EnvironmentKey {
    static var defaultValue: [_FinchAnyTableStyle] { [] }
}

private struct _FinchTableAppearanceKey: EnvironmentKey {
    static var defaultValue = _FinchTableStyleAppearance(kind: .automatic, alternatesRowBackgrounds: true)
}

extension EnvironmentValues {
    var _finchTableStyles: [_FinchAnyTableStyle] {
        get { self[_FinchTableStyleKey.self] }
        set { self[_FinchTableStyleKey.self] = newValue }
    }

    var _finchTableAppearance: _FinchTableStyleAppearance {
        get { self[_FinchTableAppearanceKey.self] }
        set { self[_FinchTableAppearanceKey.self] = newValue }
    }
}

struct _FinchAnyTableStyle: @unchecked Sendable {
    let body: (TableStyleConfiguration) -> AnyView

    @MainActor
    init<S: TableStyle>(_ style: S) {
        body = { configuration in
            AnyView(_FinchStyleView(style: style, configuration: configuration) { style, configuration in
                MainActor.assumeIsolated { AnyView(style.makeBody(configuration: configuration)) }
            })
        }
    }
}

@available(OpenSwiftUI_v3_0, *)
extension View {
    nonisolated public func tableStyle<S>(_ style: S) -> some View where S: TableStyle {
        let box = MainActor.assumeIsolated { _FinchAnyTableStyle(style) }
        return transformEnvironment(\._finchTableStyles) { $0.append(box) }
    }
}

private struct _FinchBuiltInTableStyle: View {
    var configuration: TableStyleConfiguration
    var appearance: _FinchTableStyleAppearance

    var body: some View {
        configuration.content
            .environment(\._finchTableAppearance, appearance)
            .padding(appearance.kind == .inset ? 8 : 0)
            .overlay {
                if case .bordered = appearance.kind {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color(nsColor: .separatorColor))
                        .allowsHitTesting(false)
                }
            }
    }
}

@available(OpenSwiftUI_v3_0, *)
public struct AutomaticTableStyle: TableStyle {
    @usableFromInline init() {}

    public func makeBody(configuration: Configuration) -> some View {
        _FinchBuiltInTableStyle(configuration: configuration,
                                appearance: _FinchTableStyleAppearance(kind: .automatic, alternatesRowBackgrounds: true))
    }
}

@available(OpenSwiftUI_v3_0, *)
public struct InsetTableStyle: TableStyle {
    private var alternatesRowBackgrounds: Bool

    public init() {
        alternatesRowBackgrounds = false
    }

    public init(alternatesRowBackgrounds: Bool) {
        self.alternatesRowBackgrounds = alternatesRowBackgrounds
    }

    public func makeBody(configuration: Configuration) -> some View {
        _FinchBuiltInTableStyle(configuration: configuration,
                                appearance: _FinchTableStyleAppearance(kind: .inset,
                                                                       alternatesRowBackgrounds: alternatesRowBackgrounds))
    }
}

@available(OpenSwiftUI_v3_0, *)
public struct BorderedTableStyle: TableStyle {
    private var alternatesRowBackgrounds: Bool

    public init() {
        alternatesRowBackgrounds = true
    }

    public init(alternatesRowBackgrounds: Bool) {
        self.alternatesRowBackgrounds = alternatesRowBackgrounds
    }

    public func makeBody(configuration: Configuration) -> some View {
        _FinchBuiltInTableStyle(configuration: configuration,
                                appearance: _FinchTableStyleAppearance(kind: .bordered,
                                                                       alternatesRowBackgrounds: alternatesRowBackgrounds))
    }
}

@available(*, unavailable) extension AutomaticTableStyle: Sendable {}
@available(*, unavailable) extension InsetTableStyle: Sendable {}
@available(*, unavailable) extension BorderedTableStyle: Sendable {}

extension TableStyle where Self == InsetTableStyle {
    public static var inset: InsetTableStyle { .init() }

    public static func inset(alternatesRowBackgrounds: Bool) -> InsetTableStyle {
        InsetTableStyle(alternatesRowBackgrounds: alternatesRowBackgrounds)
    }
}

extension TableStyle where Self == AutomaticTableStyle {
    public static var automatic: AutomaticTableStyle { .init() }
}

extension TableStyle where Self == BorderedTableStyle {
    public static var bordered: BorderedTableStyle { .init() }

    public static func bordered(alternatesRowBackgrounds: Bool) -> BorderedTableStyle {
        BorderedTableStyle(alternatesRowBackgrounds: alternatesRowBackgrounds)
    }
}
