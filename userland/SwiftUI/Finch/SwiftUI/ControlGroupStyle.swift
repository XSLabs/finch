// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Control group styles choose how related controls are shown together.

import SwiftUICore
import AppKit

@available(OpenSwiftUI_v3_0, *)
@MainActor
@preconcurrency
public protocol ControlGroupStyle {
    associatedtype Body: View
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
    typealias Configuration = ControlGroupStyleConfiguration
}

@available(OpenSwiftUI_v3_0, *)
struct _FinchAnyControlGroupStyle {
    var makeBody: (ControlGroupStyleConfiguration) -> AnyView

    init<S: ControlGroupStyle>(_ style: S) {
        makeBody = { AnyView(style.makeBody(configuration: $0)) }
    }
}

@available(OpenSwiftUI_v3_0, *)
private struct _FinchControlGroupStylesKey: EnvironmentKey {
    static let defaultValue = [_FinchAnyControlGroupStyle(AutomaticControlGroupStyle())]
}

@available(OpenSwiftUI_v3_0, *)
extension EnvironmentValues {
    var _finchControlGroupStyles: [_FinchAnyControlGroupStyle] {
        get { self[_FinchControlGroupStylesKey.self] }
        set { self[_FinchControlGroupStylesKey.self] = newValue }
    }
}

@available(OpenSwiftUI_v3_0, *)
extension View {
    nonisolated public func controlGroupStyle<S>(_ style: S) -> some View where S: ControlGroupStyle {
        transformEnvironment(\._finchControlGroupStyles) {
            $0.append(_FinchAnyControlGroupStyle(style))
        }
    }
}

@available(OpenSwiftUI_v3_0, *)
@MainActor @preconcurrency
public struct AutomaticControlGroupStyle: ControlGroupStyle {
    @usableFromInline init() {}

    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) { configuration.content }
            .buttonStyle(.borderless)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            .fixedSize()
    }
}

@available(macOS 14.0, *)
@MainActor @preconcurrency
public struct PaletteControlGroupStyle: ControlGroupStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.content }
            .buttonStyle(.bordered)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
            .fixedSize()
    }
}

@available(OpenSwiftUI_v3_0, *)
@MainActor @preconcurrency
public struct NavigationControlGroupStyle: ControlGroupStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.content }
            .buttonStyle(.borderless)
            .fixedSize()
    }
}

@available(macOS 13.3, *)
@MainActor @preconcurrency
public struct MenuControlGroupStyle: ControlGroupStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        Menu { configuration.content } label: {
            if configuration._hasLabel { configuration.label }
            else { Image(systemName: "ellipsis") }
        }
    }
}

@available(macOS 13.3, *)
@MainActor @preconcurrency
public struct CompactMenuControlGroupStyle: ControlGroupStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        Menu { configuration.content } label: {
            if configuration._hasLabel { configuration.label }
            else { Image(systemName: "ellipsis") }
        }
        .menuStyle(.borderlessButton)
    }
}

@available(OpenSwiftUI_v3_0, *)
extension ControlGroupStyle where Self == AutomaticControlGroupStyle {
    public static var automatic: AutomaticControlGroupStyle { AutomaticControlGroupStyle() }
}

@available(macOS 14.0, *)
extension ControlGroupStyle where Self == PaletteControlGroupStyle {
    public static var palette: PaletteControlGroupStyle { PaletteControlGroupStyle() }
}

@available(OpenSwiftUI_v3_0, *)
extension ControlGroupStyle where Self == NavigationControlGroupStyle {
    public static var navigation: NavigationControlGroupStyle { NavigationControlGroupStyle() }
}

@available(macOS 13.3, *)
extension ControlGroupStyle where Self == MenuControlGroupStyle {
    public static var menu: MenuControlGroupStyle { MenuControlGroupStyle() }
}

@available(macOS 13.3, *)
extension ControlGroupStyle where Self == CompactMenuControlGroupStyle {
    public static var compactMenu: CompactMenuControlGroupStyle { CompactMenuControlGroupStyle() }
}

@MainActor
protocol _FinchLabeledControlGroupContent {
    var _finchLabel: AnyView { get }
    var _finchContent: AnyView { get }
}

extension LabeledControlGroupContent: _FinchLabeledControlGroupContent {
    var _finchLabel: AnyView { AnyView(label) }
    var _finchContent: AnyView { AnyView(content) }
}
