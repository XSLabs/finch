// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Window styles and options, to Apple's interface: a hidden title bar (the content runs under
// the title bar, the window buttons over it), the toolbar styles, the window level (floating
// above other apps' windows) and dragging a window by its background. A scene's options apply
// to the windows it opens, as they are when the scene is made.
//
// withCurrentWindow (an environment action) gives its closure the window the view is in.

public import AppKit
import OpenAttributeGraphShims
@_spi(ForOpenSwiftUIOnly)
import SwiftUICore

/// What the scenes' window modifiers ask of the windows they open.
@MainActor
struct _FinchWindowOptions {
    var hiddenTitleBar = false
    var unifiedToolbar: Bool?
    var toolbarShowsTitle = true
    var toolbarLabelStyle: ToolbarLabelStyle?
    var level: NSWindow.Level?
    var movableByBackground: Bool?

    static var current = _FinchWindowOptions()

    func apply(to window: NSWindow) {
        if hiddenTitleBar {
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
        if let unifiedToolbar {
            window.toolbarStyle = unifiedToolbar ? .unified : .expanded
            if !toolbarShowsTitle { window.titleVisibility = .hidden }
        }
        if let toolbarLabelStyle { window.toolbar?.displayMode = toolbarLabelStyle._finchDisplayMode }
        if let level { window.level = level }
        if let movableByBackground { window.isMovableByWindowBackground = movableByBackground }
    }
}

/// A scene modifier that sets window options from its value as the scene is made.
struct _FinchWindowOptionsModifier<Value>: PrimitiveSceneModifier {
    var value: Value
    var update: @MainActor (inout _FinchWindowOptions, Value) -> Void

    nonisolated static func _makeScene(modifier: _GraphValue<Self>, inputs: _SceneInputs,
                                       body: @escaping (_Graph, _SceneInputs) -> _SceneOutputs) -> _SceneOutputs {
        let m = modifier.value.value
        MainActor.assumeIsolated {
            m.update(&_FinchWindowOptions.current, m.value)
        }
        return body(_Graph(), inputs)
    }
}

// MARK: - Window styles

@available(OpenSwiftUI_v2_0, *)
public protocol WindowStyle {
    associatedtype _Body: View
}

@available(OpenSwiftUI_v2_0, *)
public struct DefaultWindowStyle: WindowStyle {
    public typealias _Body = Never
    public init() {}
}

@available(OpenSwiftUI_v2_0, *)
public struct HiddenTitleBarWindowStyle: WindowStyle {
    public typealias _Body = Never
    public init() {}
}

@available(OpenSwiftUI_v2_0, *)
public struct TitleBarWindowStyle: WindowStyle {
    public typealias _Body = Never
    public init() {}
}

@available(OpenSwiftUI_v2_0, *)
extension WindowStyle where Self == DefaultWindowStyle {
    public static var automatic: DefaultWindowStyle { DefaultWindowStyle() }
}

@available(OpenSwiftUI_v2_0, *)
extension WindowStyle where Self == HiddenTitleBarWindowStyle {
    public static var hiddenTitleBar: HiddenTitleBarWindowStyle { HiddenTitleBarWindowStyle() }
}

@available(OpenSwiftUI_v2_0, *)
extension WindowStyle where Self == TitleBarWindowStyle {
    public static var titleBar: TitleBarWindowStyle { TitleBarWindowStyle() }
}

@available(OpenSwiftUI_v2_0, *)
public protocol WindowToolbarStyle {
    associatedtype _Body: View
}

@available(OpenSwiftUI_v2_0, *)
public struct DefaultWindowToolbarStyle: WindowToolbarStyle {
    public typealias _Body = Never
    public init() {}
}

@available(OpenSwiftUI_v2_0, *)
public struct UnifiedWindowToolbarStyle: WindowToolbarStyle {
    public typealias _Body = Never
    var showsTitle = true
    public init() {}
    public init(showsTitle: Bool) { self.showsTitle = showsTitle }
}

@available(OpenSwiftUI_v2_0, *)
public struct UnifiedCompactWindowToolbarStyle: WindowToolbarStyle {
    public typealias _Body = Never
    var showsTitle = true
    public init() {}
    public init(showsTitle: Bool) { self.showsTitle = showsTitle }
}

@available(OpenSwiftUI_v2_0, *)
public struct ExpandedWindowToolbarStyle: WindowToolbarStyle {
    public typealias _Body = Never
    public init() {}
}

@available(OpenSwiftUI_v2_0, *)
extension Scene {
    nonisolated public func windowStyle<S>(_ style: S) -> some Scene where S: WindowStyle {
        modifier(_FinchWindowOptionsModifier(value: style is HiddenTitleBarWindowStyle) { options, hidden in
            options.hiddenTitleBar = hidden
        })
    }

    nonisolated public func windowToolbarStyle<S>(_ style: S) -> some Scene where S: WindowToolbarStyle {
        let unified: Bool?
        var showsTitle = true
        switch style {
        case let s as UnifiedWindowToolbarStyle:
            unified = true
            showsTitle = s.showsTitle
        case let s as UnifiedCompactWindowToolbarStyle:
            unified = true
            showsTitle = s.showsTitle
        case is ExpandedWindowToolbarStyle:
            unified = false
        default:
            unified = nil
        }
        return modifier(_FinchWindowOptionsModifier(value: (unified, showsTitle)) { options, value in
            options.unifiedToolbar = value.0
            options.toolbarShowsTitle = value.1
        })
    }
}

// MARK: - Window level and dragging

@available(OpenSwiftUI_v6_0, *)
public struct WindowLevel: Sendable, Hashable {
    enum Kind: Hashable { case automatic, desktop, floating, normal }
    var kind: Kind

    public static var automatic: WindowLevel { WindowLevel(kind: .automatic) }
    public static var desktop: WindowLevel { WindowLevel(kind: .desktop) }
    public static var floating: WindowLevel { WindowLevel(kind: .floating) }
    public static var normal: WindowLevel { WindowLevel(kind: .normal) }

    var nsLevel: NSWindow.Level? {
        switch kind {
        case .automatic: nil
        case .desktop: NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)))
        case .floating: .floating
        case .normal: .normal
        }
    }
}

@available(OpenSwiftUI_v6_0, *)
public struct WindowInteractionBehavior: Sendable {
    var enabled: Bool?

    public static let automatic = WindowInteractionBehavior(enabled: nil)
    public static let enabled = WindowInteractionBehavior(enabled: true)
    public static let disabled = WindowInteractionBehavior(enabled: false)
}

@available(OpenSwiftUI_v6_0, *)
extension Scene {
    nonisolated public func windowLevel(_ level: WindowLevel) -> some Scene {
        modifier(_FinchWindowOptionsModifier(value: level) { options, level in
            options.level = level.nsLevel
        })
    }

    nonisolated public func windowBackgroundDragBehavior(_ behavior: WindowInteractionBehavior) -> some Scene {
        modifier(_FinchWindowOptionsModifier(value: behavior) { options, behavior in
            options.movableByBackground = behavior.enabled
        })
    }
}

// MARK: - The current window

/// Calls its closure with the window the view is in (the key window, failing that the main).
@available(OpenSwiftUI_v6_0, *)
public struct WithCurrentWindowAction {
    public func callAsFunction(_ body: (NSWindow?) -> Void) {
        MainActor.assumeIsolated {
            body(NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible })
        }
    }
}

@available(OpenSwiftUI_v6_0, *)
extension EnvironmentValues {
    public var withCurrentWindow: WithCurrentWindowAction { WithCurrentWindowAction() }
}
