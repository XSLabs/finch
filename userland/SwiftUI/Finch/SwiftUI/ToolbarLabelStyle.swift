// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Toolbar label styles choose which part of each toolbar item's label is shown.

import AppKit
import SwiftUICore

@available(macOS 15.0, *)
public struct ToolbarLabelStyle: Sendable, Equatable {
    enum Kind: UInt8, Sendable {
        case automatic
        case titleAndIcon
        case iconOnly
        case titleOnly
    }

    let kind: Kind

    private init(_ kind: Kind) {
        self.kind = kind
    }

    public static var automatic: ToolbarLabelStyle { ToolbarLabelStyle(.automatic) }
    public static var titleAndIcon: ToolbarLabelStyle { ToolbarLabelStyle(.titleAndIcon) }
    public static var iconOnly: ToolbarLabelStyle { ToolbarLabelStyle(.iconOnly) }
    public static var titleOnly: ToolbarLabelStyle { ToolbarLabelStyle(.titleOnly) }

    var _finchDisplayMode: NSToolbar.DisplayMode {
        switch kind {
        case .automatic: .default
        case .titleAndIcon: .iconAndLabel
        case .iconOnly: .iconOnly
        case .titleOnly: .labelOnly
        }
    }
}

@available(macOS 15.0, *)
private struct _FinchToolbarLabelStyleKey: EnvironmentKey {
    static let defaultValue: ToolbarLabelStyle? = nil
}

@available(macOS 15.0, *)
extension EnvironmentValues {
    public var toolbarLabelStyle: ToolbarLabelStyle? {
        self[_FinchToolbarLabelStyleKey.self]
    }

    var _finchToolbarLabelStyle: ToolbarLabelStyle? {
        get { self[_FinchToolbarLabelStyleKey.self] }
        set { self[_FinchToolbarLabelStyleKey.self] = newValue }
    }
}

@available(macOS 15.0, *)
extension Scene {
    nonisolated public func windowToolbarLabelStyle(fixed style: ToolbarLabelStyle) -> some Scene {
        modifier(_FinchWindowOptionsModifier(value: style) { options, style in
            options.toolbarLabelStyle = style
            if let app = NSApp {
                for window in app.windows { window.toolbar?.displayMode = style._finchDisplayMode }
            }
        })
    }

    nonisolated public func windowToolbarLabelStyle(_ style: Binding<ToolbarLabelStyle>) -> some Scene {
        modifier(_FinchWindowOptionsModifier(value: style) { options, binding in
            let style = binding.wrappedValue
            options.toolbarLabelStyle = style
            if let app = NSApp {
                for window in app.windows { window.toolbar?.displayMode = style._finchDisplayMode }
            }
        })
    }
}
