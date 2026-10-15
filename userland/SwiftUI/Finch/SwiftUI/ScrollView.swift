// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ScrollView, to Apple's interface: its content scrolled within the view graph (so the
// content's environment, preferences, coordinate spaces and gestures are the surroundings').
// Along the scrolling axes the content takes its ideal size; across them it fits the scroll
// view. The scroll view takes what it is offered along the scrolling axes and its content's
// size across them.

import AppKit
import SwiftUICore

@available(OpenSwiftUI_v1_0, *)
@MainActor
@preconcurrency
public struct ScrollView<Content>: View where Content: View {
    public var content: Content
    var configuration: _FinchScrollConfiguration

    public var axes: Axis.Set {
        get { configuration.axes }
        set { configuration.axes = newValue }
    }

    public var showsIndicators: Bool {
        get { configuration.showsIndicators }
        set { configuration.showsIndicators = newValue }
    }

    nonisolated public init(_ axes: Axis.Set = .vertical, showsIndicators: Bool = true, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.configuration = _FinchScrollConfiguration(axes: axes, showsIndicators: showsIndicators)
    }

    @MainActor
    @preconcurrency
    public var body: some View {
        _FinchScrollView(content: content, configuration: configuration)
    }
}

@available(*, unavailable)
extension ScrollView: Sendable {}

@available(OpenSwiftUI_v1_0, *)
extension ScrollView {
    public var _contentInsets: EdgeInsets {
        get { configuration.contentInsets }
        set { configuration.contentInsets = newValue }
    }

    public var _automaticallyAdjustsContentInsets: Bool {
        get { configuration.automaticallyAdjustsContentInsets }
        set { configuration.automaticallyAdjustsContentInsets = newValue }
    }

    public var _alwaysBounceAxes: Axis.Set {
        get { configuration.alwaysBounceAxes }
        set { configuration.alwaysBounceAxes = newValue }
    }

    @usableFromInline
    nonisolated func scrollDisabled(_ disabled: Bool) -> ScrollView<Content> {
        var view = self
        view.configuration.isScrollDisabled = disabled
        return view
    }
}

struct _FinchScrollConfiguration {
    var axes: Axis.Set
    var showsIndicators: Bool
    var contentInsets = EdgeInsets()
    var automaticallyAdjustsContentInsets = true
    var alwaysBounceAxes: Axis.Set = []
    var isScrollDisabled = false
}

/// The scroll view: its content scrolled within the graph (ClipScroll.swift), inset by the
/// configuration's insets and the content margins.
struct _FinchScrollView<Content: View>: View {
    var content: Content
    var configuration: _FinchScrollConfiguration
    @Environment(\._finchContentMargins) private var margins
    @Environment(\._finchHiddenScrollIndicators) private var hidden
    @Environment(\._finchScrollGeometryObservers) private var geometryObservers

    var body: some View {
        let insets = EdgeInsets(top: configuration.contentInsets.top + margins.top,
                                leading: configuration.contentInsets.leading + margins.leading,
                                bottom: configuration.contentInsets.bottom + margins.bottom,
                                trailing: configuration.contentInsets.trailing + margins.trailing)
        let axes = configuration.axes
        let scrollContent = content.padding(insets).environment(\._finchScrollGeometryObservers, [])
        _FinchClipScroll(content: scrollContent, axes: axes,
                         showsIndicators: configuration.showsIndicators && hidden.isDisjoint(with: axes),
                         isDisabled: configuration.isScrollDisabled, geometryObservers: geometryObservers)
    }
}

extension View {
    /// The environment values content hosted apart (in a scroll view's document, a sheet, a
    /// popover) inherits from where it is presented. Not the whole environment, which holds
    /// the presenting graph's own state.
    /// (colorScheme: false for a window's content, whose colour scheme is its window's appearance's)
    func _finchInheriting(_ environment: EnvironmentValues, colorScheme: Bool = true) -> some View {
        self.transformEnvironment(\.self) { $0._finchInheritAppValues(from: environment) }
            .environment(\.font, environment.font)
            .environment(\.isEnabled, environment.isEnabled)
            .transformEnvironment(\.colorScheme) { if colorScheme { $0 = environment.colorScheme } }
            .environment(\.layoutDirection, environment.layoutDirection)
            .environment(\.locale, environment.locale)
            .environment(\.multilineTextAlignment, environment.multilineTextAlignment)
            .environment(\.lineLimit, environment.lineLimit)
            .environment(\.controlSize, environment.controlSize)
            .environment(\._finchButtonStyles, environment._finchButtonStyles)
            .environment(\._finchTextFieldStyles, environment._finchTextFieldStyles)
            .environment(\._finchFormStyles, environment._finchFormStyles)
            .environment(\._finchListStyle, environment._finchListStyle)
            .environment(\._finchPickerStyle, environment._finchPickerStyle)
    }
}

/// Reports the scroll view's document root frame, under its own id.
struct _FinchScrollRootReporter: View {
    static let id = AnyHashable("org.finch.SwiftUI.scrollRoot")
    var enabled: Bool

    var body: some View {
        if enabled {
            GeometryReader { proxy in
                Color.clear.preference(key: _FinchScrollTargetsKey.self, value: [Self.id: proxy.frame(in: .global)])
            }
        }
    }
}
