// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Scenes, commands and view modifiers apps call, to Apple's interface: the Settings scene
// (its window opened from the app menu's Settings item), sidebar commands, presented-value
// window groups, scene placement and closing; navigation split view styles, inspectors,
// list item tints, alternating row backgrounds, scroll edge effects, deletion and command
// handlers, slider marks, printing hosting views, and smaller values. Where Finch has
// nothing to change for a modifier yet (scroll edge effects, form insets, autocorrection),
// the content is shown as it is.

public import AppKit
public import Foundation
import OpenAttributeGraphShims
@_spi(ForOpenSwiftUIOnly)
import SwiftUICore

// MARK: - Settings

@available(OpenSwiftUI_v2_0, *)
public struct Settings<Content>: Scene where Content: View {
    var content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    @MainActor
    @preconcurrency
    public var body: some Scene {
        _FinchSettingsWindow.content = AnyView(content)
        return _FinchSettingsCommand()
    }
}

@available(*, unavailable) extension Settings: Sendable {}

/// The settings window: opened (or brought forward) from the app menu's Settings item.
@MainActor
enum _FinchSettingsWindow {
    static var content: AnyView? {
        didSet { _FinchMainMenu.scheduleInstall() }
    }
    private static var controller: NSWindowController?

    static func show() {
        guard let content else { return }
        if let window = controller?.window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = "Settings"
        let size = hosting.view.fittingSize
        if size.width > 0, size.height > 0 { window.setContentSize(size) }
        window.center()
        let controller = NSWindowController(window: window)
        self.controller = controller
        controller.showWindow(nil)
    }
}

/// The Settings item, as a command in the app menu's settings group.
struct _FinchSettingsCommand: Scene {
    var body: some Scene {
        _FinchEmptyScene()
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { _FinchSettingsWindow.show() }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}

/// A scene with no windows, for scene modifiers to hang on.
struct _FinchEmptyScene: PrimitiveScene {
    nonisolated static func _makeScene(scene: _GraphValue<Self>, inputs: _SceneInputs) -> _SceneOutputs {
        _SceneOutputs()
    }
}

// MARK: - Commands

@available(OpenSwiftUI_v2_0, *)
public struct SidebarCommands: Commands {
    public init() {}

    @MainActor
    @preconcurrency
    public var body: some Commands {
        CommandGroup(before: .sidebar) {
            Button("Toggle Sidebar") {
                NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
        }
    }
}

@available(*, unavailable) extension SidebarCommands: Sendable {}

@available(OpenSwiftUI_v2_0, *)
extension Scene {
    /// The app's commands, without the standard ones: Finch's menus keep them for now.
    nonisolated public func commandsRemoved() -> some Scene { self }

    /// Where a scene's windows first appear: Finch centers them.
    nonisolated public func defaultPosition(_ position: UnitPoint) -> some Scene { self }

    /// Asked before a window of the scene closes.
    nonisolated public func windowShouldClose(_ shouldClose: @escaping () -> Bool) -> some Scene { self }
}

// MARK: - Presented-value window groups

@available(OpenSwiftUI_v4_0, *)
public struct PresentedWindowContent<Data, Content>: View where Data: Decodable, Data: Encodable, Data: Hashable, Content: View {
    var content: (Binding<Data?>) -> Content

    nonisolated public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        AnyView._makeView(view: _GraphValue(Child(view: view.value)), inputs: inputs)
    }

    nonisolated public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        AnyView._makeViewList(view: _GraphValue(Child(view: view.value)), inputs: inputs)
    }

    nonisolated public static func _viewListCount(inputs: _ViewListCountInputs) -> Int? { nil }

    public typealias Body = Never
    public var body: Never { fatalError("\(Self.self) has no body") }

    /// The content for a window opened without a value.
    private struct Child: Rule {
        @Attribute var view: PresentedWindowContent
        var value: AnyView { AnyView(view.content(.constant(nil))) }
    }
}

@available(*, unavailable) extension PresentedWindowContent: Sendable {}

@available(OpenSwiftUI_v4_0, *)
extension WindowGroup {
    nonisolated public init<D, C>(id: String, for type: D.Type, @ViewBuilder content: @escaping (Binding<D?>) -> C)
        where Content == PresentedWindowContent<D, C>, D: Decodable, D: Encodable, D: Hashable, C: View {
        self.init(id: id, title: nil) { PresentedWindowContent(content: content) }
    }

    nonisolated public init<D, C>(for type: D.Type, @ViewBuilder content: @escaping (Binding<D?>) -> C)
        where Content == PresentedWindowContent<D, C>, D: Decodable, D: Encodable, D: Hashable, C: View {
        self.init(id: nil, title: nil) { PresentedWindowContent(content: content) }
    }

    @_disfavoredOverload
    nonisolated public init<D, C>(_ title: Text, id: String, for type: D.Type, @ViewBuilder content: @escaping (Binding<D?>) -> C)
        where Content == PresentedWindowContent<D, C>, D: Decodable, D: Encodable, D: Hashable, C: View {
        self.init(id: id, title: title) { PresentedWindowContent(content: content) }
    }

    nonisolated public init<D, C>(_ titleKey: LocalizedStringKey, id: String, for type: D.Type,
                                  @ViewBuilder content: @escaping (Binding<D?>) -> C)
        where Content == PresentedWindowContent<D, C>, D: Decodable, D: Encodable, D: Hashable, C: View {
        self.init(id: id, title: Text(titleKey)) { PresentedWindowContent(content: content) }
    }
}

// MARK: - Navigation split view styles

@available(OpenSwiftUI_v4_0, *)
@MainActor
@preconcurrency
public protocol NavigationSplitViewStyle {
    associatedtype Body: View
    @ViewBuilder
    func makeBody(configuration: Self.Configuration) -> Self.Body
    typealias Configuration = NavigationSplitViewStyleConfiguration
}

@available(OpenSwiftUI_v4_0, *)
public struct NavigationSplitViewStyleConfiguration {}

/// The split view as Finch lays it out, whichever style: the columns side by side.
@available(OpenSwiftUI_v4_0, *)
@MainActor
@preconcurrency
public struct AutomaticNavigationSplitViewStyle: NavigationSplitViewStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { EmptyView() }
}

@available(OpenSwiftUI_v4_0, *)
@MainActor
@preconcurrency
public struct BalancedNavigationSplitViewStyle: NavigationSplitViewStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { EmptyView() }
}

@available(OpenSwiftUI_v4_0, *)
@MainActor
@preconcurrency
public struct ProminentDetailNavigationSplitViewStyle: NavigationSplitViewStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { EmptyView() }
}

@available(OpenSwiftUI_v4_0, *)
extension NavigationSplitViewStyle where Self == AutomaticNavigationSplitViewStyle {
    public static var automatic: AutomaticNavigationSplitViewStyle { .init() }
}

@available(OpenSwiftUI_v4_0, *)
extension NavigationSplitViewStyle where Self == BalancedNavigationSplitViewStyle {
    public static var balanced: BalancedNavigationSplitViewStyle { .init() }
}

@available(OpenSwiftUI_v4_0, *)
extension NavigationSplitViewStyle where Self == ProminentDetailNavigationSplitViewStyle {
    public static var prominentDetail: ProminentDetailNavigationSplitViewStyle { .init() }
}

@available(OpenSwiftUI_v4_0, *)
extension View {
    nonisolated public func navigationSplitViewStyle<S>(_ style: S) -> some View where S: NavigationSplitViewStyle { self }

    nonisolated public func navigationSubtitle(_ subtitle: Text) -> some View { self }
    nonisolated public func navigationSubtitle(_ subtitleKey: LocalizedStringKey) -> some View { self }
    @_disfavoredOverload
    nonisolated public func navigationSubtitle<S>(_ subtitle: S) -> some View where S: StringProtocol { self }
}

// MARK: - Inspectors

private struct _FinchInspectorWidthKey: EnvironmentKey {
    static var defaultValue: CGFloat { 260 }
}

extension EnvironmentValues {
    var _finchInspectorWidth: CGFloat {
        get { self[_FinchInspectorWidthKey.self] }
        set { self[_FinchInspectorWidthKey.self] = newValue }
    }
}

/// The inspector at the trailing edge, beside the content, while it's presented.
struct _FinchInspector<Content: View, Inspector: View>: View {
    var content: Content
    var isPresented: Binding<Bool>
    var inspector: Inspector
    @State private var width: CGFloat = 260

    var body: some View {
        HStack(spacing: 0) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            if isPresented.wrappedValue {
                Divider()
                inspector
                    .frame(width: width)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .onPreferenceChange(_FinchInspectorWidthPreference.self) { if let w = $0 { width = w } }
            }
        }
    }
}

struct _FinchInspectorWidthPreference: PreferenceKey {
    static var defaultValue: CGFloat? { nil }
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() ?? value }
}

@available(OpenSwiftUI_v5_0, *)
extension View {
    nonisolated public func inspector<V>(isPresented: Binding<Bool>, @ViewBuilder content: () -> V) -> some View where V: View {
        _FinchInspector(content: self, isPresented: isPresented, inspector: content())
    }

    nonisolated public func inspectorColumnWidth(min: CGFloat? = nil, ideal: CGFloat, max: CGFloat? = nil) -> some View {
        preference(key: _FinchInspectorWidthPreference.self, value: ideal)
    }

    nonisolated public func inspectorColumnWidth(_ width: CGFloat) -> some View {
        preference(key: _FinchInspectorWidthPreference.self, value: width)
    }
}

// MARK: - Lists

@available(OpenSwiftUI_v2_0, *)
public struct ListItemTint: Sendable {
    enum Kind: Sendable { case fixed(Color), preferred(Color), monochrome }
    let kind: Kind
    public static func fixed(_ tint: Color) -> ListItemTint { ListItemTint(kind: .fixed(tint)) }
    public static func preferred(_ tint: Color) -> ListItemTint { ListItemTint(kind: .preferred(tint)) }
    public static let monochrome = ListItemTint(kind: .monochrome)
}

@available(OpenSwiftUI_v2_0, *)
@usableFromInline
struct ListItemTintTraitKey: _ViewTraitKey {
    @inlinable
    static var defaultValue: ListItemTint? { nil }
    @usableFromInline
    typealias Value = ListItemTint?
}

@available(OpenSwiftUI_v2_0, *)
extension View {
    @inlinable
    nonisolated public func listItemTint(_ tint: ListItemTint?) -> some View {
        _trait(ListItemTintTraitKey.self, tint)
    }

    @inlinable
    nonisolated public func listItemTint(_ tint: Color?) -> some View {
        listItemTint(tint.map { .fixed($0) })
    }
}

@available(OpenSwiftUI_v1_0, *)
@usableFromInline
struct OnDeleteTraitKey: _ViewTraitKey {
    @inlinable
    static var defaultValue: Optional<(IndexSet) -> Void> { nil }
    @usableFromInline
    typealias Value = Optional<(IndexSet) -> Void>
}

@available(OpenSwiftUI_v1_0, *)
extension DynamicViewContent {
    @inlinable
    nonisolated public func onDelete(perform action: Optional<(IndexSet) -> Void>) -> some DynamicViewContent {
        modifier(_TraitWritingModifier<OnDeleteTraitKey>(value: action))
    }
}

@available(OpenSwiftUI_v5_0, *)
public struct AlternatingRowBackgroundBehavior: Hashable, Sendable {
    let enabled: Bool?
    public static let automatic = AlternatingRowBackgroundBehavior(enabled: nil)
    public static let enabled = AlternatingRowBackgroundBehavior(enabled: true)
    public static let disabled = AlternatingRowBackgroundBehavior(enabled: false)
}

@available(OpenSwiftUI_v5_0, *)
extension View {
    nonisolated public func alternatingRowBackgrounds(_ behavior: AlternatingRowBackgroundBehavior = .enabled) -> some View { self }
}

// MARK: - Scrolling

@available(OpenSwiftUI_v7_0, *)
public struct ScrollEdgeEffectStyle: Hashable, Sendable {
    enum Kind: Hashable { case automatic, hard, soft }
    let kind: Kind
    public static var automatic: ScrollEdgeEffectStyle { .init(kind: .automatic) }
    public static var hard: ScrollEdgeEffectStyle { .init(kind: .hard) }
    public static var soft: ScrollEdgeEffectStyle { .init(kind: .soft) }
}

@available(OpenSwiftUI_v7_0, *)
extension View {
    nonisolated public func scrollEdgeEffectStyle(_ style: ScrollEdgeEffectStyle?, for edges: Edge.Set) -> some View { self }
    nonisolated public func scrollEdgeEffectDisabled(_ disabled: Bool = true, for edges: Edge.Set = .all) -> some View { self }
}

private struct _FinchScrollDisabledKey: EnvironmentKey {
    static var defaultValue: Bool { false }
}

extension EnvironmentValues {
    var _finchScrollDisabled: Bool {
        get { self[_FinchScrollDisabledKey.self] }
        set { self[_FinchScrollDisabledKey.self] = newValue }
    }
}

@available(OpenSwiftUI_v4_0, *)
extension View {
    nonisolated public func scrollDisabled(_ disabled: Bool) -> some View {
        transformEnvironment(\._finchScrollDisabled) { $0 = $0 || disabled }
    }

    nonisolated public func scrollContentBackground<S>(_ style: S?) -> some View where S: ShapeStyle { self }
}

@available(OpenSwiftUI_v2_0, *)
extension ScrollViewProxy {
    /// Scrolls the reader's scroll view to show the rectangle (in its content's coordinates).
    public func scrollTo(rect: CGRect, anchor: UnitPoint? = nil) {
        let box = box
        MainActor.assumeIsolated { box.scrollTo(rect: rect, anchor: anchor) }
    }
}

// MARK: - Commands as actions

/// Puts a command responder after the window's content in the responder chain.
struct _FinchCommandHost: NSViewRepresentable {
    var selector: Selector
    var action: (() -> Void)?

    func makeNSView(context: Context) -> _FinchCommandView { _FinchCommandView() }

    func updateNSView(_ view: _FinchCommandView, context: Context) {
        view.commands[selector] = action
    }
}

final class _FinchCommandView: NSView {
    var commands: [Selector: () -> Void] = [:]

    override func responds(to aSelector: Selector!) -> Bool {
        if let aSelector, commands[aSelector] != nil { return true }
        return super.responds(to: aSelector)
    }

    override func doCommand(by selector: Selector) {
        if let action = commands[selector] { action() } else { super.doCommand(by: selector) }
    }

    @objc func delete(_ sender: Any?) { commands[#selector(NSText.delete(_:))]?() }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@available(OpenSwiftUI_v1_0, *)
extension View {
    nonisolated public func onDeleteCommand(perform action: (() -> Void)?) -> some View {
        background(_FinchCommandHost(selector: #selector(NSText.delete(_:)), action: action))
    }

    nonisolated public func onCommand(_ selector: Selector, perform action: (() -> Void)?) -> some View {
        background(_FinchCommandHost(selector: selector, action: action))
    }

    nonisolated public func onCopyCommand(perform payloadAction: (() -> [NSItemProvider])?) -> some View { self }
}

// MARK: - Forms and controls

@available(OpenSwiftUI_v7_0, *)
extension View {
    nonisolated public func formInsets(_ edges: Edge.Set = .all, _ length: CGFloat) -> some View { self }
}

@available(OpenSwiftUI_v1_0, *)
extension View {
    nonisolated public func disableAutocorrection(_ disable: Bool?) -> some View { self }
    nonisolated public func autocorrectionDisabled(_ disable: Bool = true) -> some View { self }
    nonisolated public func interactiveDismissDisabled(_ isDisabled: Bool = true) -> some View { self }
}

public struct ControlSizingBehavior_v0: Sendable, Hashable {
    let flexible: Bool
    public static var flexible: ControlSizingBehavior_v0 { .init(flexible: true) }
    public static var fitted: ControlSizingBehavior_v0 { .init(flexible: false) }
    public static var automatic: ControlSizingBehavior_v0 { .init(flexible: false) }
}

extension View {
    nonisolated public func _controlSizingBehavior(_ behavior: ControlSizingBehavior_v0) -> some View { self }
}

// MARK: - Gestures

@available(OpenSwiftUI_v1_0, *)
public struct MagnificationGesture: Gesture {
    public var minimumScaleDelta: CGFloat

    public init(minimumScaleDelta: CGFloat = 0.01) {
        self.minimumScaleDelta = minimumScaleDelta
    }

    /// Finch's pointer has no pinch yet: the gesture never begins.
    nonisolated public static func _makeGesture(gesture: _GraphValue<MagnificationGesture>,
                                               inputs: _GestureInputs) -> _GestureOutputs<CGFloat> {
        _GestureOutputs(phase: Attribute(value: GesturePhase<CGFloat>.failed))
    }

    public typealias Value = CGFloat
    public typealias Body = Never
    public var body: Never { fatalError("\(Self.self) has no body") }
}

@available(OpenSwiftUI_v1_0, *)
public struct _ModifiersGesture<Content>: Gesture where Content: Gesture {
    var content: Content
    var modifiers: EventModifiers

    /// The gesture, over events with the modifier keys held: one without them fails it.
    nonisolated public static func _makeGesture(gesture: _GraphValue<_ModifiersGesture<Content>>,
                                               inputs: _GestureInputs) -> _GestureOutputs<Content.Value> {
        let filter = Attribute(_FinchModifiersFilter(gesture: gesture.value))
        return EventFilter<Content.Value>._makeGesture(modifier: _GraphValue(filter), inputs: inputs) { inputs in
            Content._makeGesture(gesture: gesture[offset: { .of(&$0.content) }], inputs: inputs)
        }
    }

    public typealias Body = Never
    public typealias Value = Content.Value
    public var body: Never { fatalError("\(Self.self) has no body") }
}

/// A modifiers gesture's event filter: events with modifier keys must hold the gesture's.
private struct _FinchModifiersFilter<Content: Gesture>: Rule {
    @Attribute var gesture: _ModifiersGesture<Content>

    var value: EventFilter<Content.Value> {
        let required = gesture.modifiers
        return EventFilter { event in
            guard let event = event as? any ModifiersEventType else {
                return true
            }
            return event.modifiers.contains(required)
        }
    }
}

@available(OpenSwiftUI_v1_0, *)
extension Gesture {
    @MainActor
    @preconcurrency
    public func modifiers(_ modifiers: EventModifiers) -> _ModifiersGesture<Self> {
        _ModifiersGesture(content: self, modifiers: modifiers)
    }
}

// MARK: - Alignment

@available(OpenSwiftUI_v7_0, *)
extension VerticalAlignment {
    /// The center of the first line of text: its baseline, which Finch aligns to.
    public static var firstTextLineCenter: VerticalAlignment { .firstTextBaseline }
}

// MARK: - Slider marks

@available(OpenSwiftUI_v7_0, *)
public struct SliderMark<Value> {
    public var value: Value
    public init(_ value: Value) {
        self.value = value
    }
}

@available(OpenSwiftUI_v7_0, *)
@resultBuilder
public struct SliderMarkBuilder<Value> {
    public static func buildBlock(_ marks: SliderMark<Value>...) -> [SliderMark<Value>] { marks }
}

@available(OpenSwiftUI_v7_0, *)
extension Slider where ValueLabel == EmptyView {
    /// A slider with marks along it (Finch's shows no marks yet).
    public init<V>(value: Binding<V>, in bounds: ClosedRange<V> = 0 ... 1, @ViewBuilder label: () -> Label,
                   @SliderMarkBuilder<V> marks: () -> [SliderMark<V>], onEditingChanged: @escaping (Bool) -> Void = { _ in })
        where V: BinaryFloatingPoint, V.Stride: BinaryFloatingPoint {
        self.init(value: value, in: bounds, label: label, onEditingChanged: onEditingChanged)
    }
}

// MARK: - Symbols' variable values

private struct _FinchSymbolVariableValueModeKey: EnvironmentKey {
    static var defaultValue: SymbolVariableValueMode? { nil }
}

@available(OpenSwiftUI_v7_0, *)
extension EnvironmentValues {
    public var symbolVariableValueMode: SymbolVariableValueMode? {
        get { self[_FinchSymbolVariableValueModeKey.self] }
        set { self[_FinchSymbolVariableValueModeKey.self] = newValue }
    }
}

@available(OpenSwiftUI_v7_0, *)
extension View {
    nonisolated public func symbolVariableValueMode(_ mode: SymbolVariableValueMode?) -> some View {
        environment(\.symbolVariableValueMode, mode)
    }
}

// MARK: - Printing

/// A hosting view for printing: the content drawn at its size, as an NSView prints.
@available(OpenSwiftUI_v1_0, *)
public class PrintingHostingView<Content>: NSHostingView<Content> where Content: View {
    public required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
