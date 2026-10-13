// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Group boxes (and their styles), tab views and tab items, colour pickers, help buttons and
// LabeledContent's title initializers, to Apple's interface. A group box is its label over
// its content in a rounded, tinted box; a tab view is a row of tabs (each child's tabItem
// label) over the selected child; a colour picker is an NSColorWell; a help button is
// AppKit's round help button, which opens the help book at its anchor.

public import AppKit
import OpenAttributeGraphShims
@_spi(ForOpenSwiftUIOnly)
import SwiftUICore

// MARK: - GroupBox

@available(OpenSwiftUI_v2_0, *)
@MainActor
@preconcurrency
public protocol GroupBoxStyle {
    associatedtype Body: View
    @ViewBuilder
    func makeBody(configuration: Self.Configuration) -> Self.Body
    typealias Configuration = GroupBoxStyleConfiguration
}

@available(OpenSwiftUI_v2_0, *)
public struct GroupBoxStyleConfiguration {
    @MainActor
    @preconcurrency
    public struct Label: ViewAlias {
        public typealias Body = Never
        nonisolated init() {}
    }

    @MainActor
    @preconcurrency
    public struct Content: ViewAlias {
        public typealias Body = Never
        nonisolated init() {}
    }

    public let label: GroupBoxStyleConfiguration.Label
    public let content: GroupBoxStyleConfiguration.Content

    init() {
        label = Label()
        content = Content()
    }
}

@available(*, unavailable) extension GroupBoxStyleConfiguration: Sendable {}
@available(*, unavailable) extension GroupBoxStyleConfiguration.Label: Sendable {}
@available(*, unavailable) extension GroupBoxStyleConfiguration.Content: Sendable {}

/// The box AppKit draws (NSBox's): the label above, the content inset in a rounded,
/// lightly tinted box.
struct _FinchDefaultGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            configuration.label
                .font(.system(size: 11))
            VStack(alignment: .leading, spacing: 0) {
                configuration.content
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
        }
    }
}

struct _FinchAnyGroupBoxStyle {
    let body: (GroupBoxStyleConfiguration) -> AnyView
    init<S: GroupBoxStyle>(_ style: S) {
        body = { AnyView(_FinchStyleView(style: style, configuration: $0) { $0.makeBody(configuration: $1) }) }
    }
}

private struct _FinchGroupBoxStyleKey: EnvironmentKey {
    static var defaultValue: _FinchAnyGroupBoxStyle? { nil }
}

extension EnvironmentValues {
    var _finchGroupBoxStyle: _FinchAnyGroupBoxStyle? {
        get { self[_FinchGroupBoxStyleKey.self] }
        set { self[_FinchGroupBoxStyleKey.self] = newValue }
    }
}

@available(OpenSwiftUI_v1_0, *)
public struct GroupBox<Label, Content>: View where Label: View, Content: View {
    var label: Label
    var content: Content
    @Environment(\._finchGroupBoxStyle) private var style

    @available(OpenSwiftUI_v1_0, *)
    @_alwaysEmitIntoClient
    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.init(label: label(), content: content)
    }

    public init(label: Label, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    @MainActor
    @preconcurrency
    public var body: some View {
        let configuration = GroupBoxStyleConfiguration()
        let styled: AnyView = style?.body(configuration) ?? AnyView(_FinchDefaultGroupBoxStyle().makeBody(configuration: configuration))
        return styled
            .viewAlias(GroupBoxStyleConfiguration.Label.self) { label }
            .viewAlias(GroupBoxStyleConfiguration.Content.self) { content }
    }
}

@available(*, unavailable) extension GroupBox: Sendable {}

@available(OpenSwiftUI_v2_0, *)
extension GroupBox where Label == GroupBoxStyleConfiguration.Label, Content == GroupBoxStyleConfiguration.Content {
    nonisolated public init(_ configuration: GroupBoxStyleConfiguration) {
        label = configuration.label
        content = configuration.content
    }
}

@available(OpenSwiftUI_v1_0, *)
extension GroupBox where Label == EmptyView {
    nonisolated public init(@ViewBuilder content: () -> Content) {
        self.init(label: EmptyView(), content: content)
    }
}

@available(OpenSwiftUI_v1_0, *)
extension GroupBox where Label == Text {
    nonisolated public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(label: Text(titleKey), content: content)
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, @ViewBuilder content: () -> Content) where S: StringProtocol {
        self.init(label: Text(title), content: content)
    }
}

@available(OpenSwiftUI_v2_0, *)
public struct DefaultGroupBoxStyle: GroupBoxStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        _FinchDefaultGroupBoxStyle().makeBody(configuration: configuration)
    }
}

@available(OpenSwiftUI_v2_0, *)
extension GroupBoxStyle where Self == DefaultGroupBoxStyle {
    @_alwaysEmitIntoClient
    public static var automatic: DefaultGroupBoxStyle { .init() }
}

@available(OpenSwiftUI_v2_0, *)
extension View {
    nonisolated public func groupBoxStyle<S>(_ style: S) -> some View where S: GroupBoxStyle {
        environment(\._finchGroupBoxStyle, _FinchAnyGroupBoxStyle(style))
    }
}

// MARK: - TabView

/// A child's tabItem label.
struct _FinchTabItemTraitKey: _ViewTraitKey {
    static var defaultValue: AnyView? { nil }
}

@available(OpenSwiftUI_v1_0, *)
extension View {
    nonisolated public func tabItem<V>(@ViewBuilder _ label: () -> V) -> some View where V: View {
        _trait(_FinchTabItemTraitKey.self, AnyView(label()))
    }
}

@available(OpenSwiftUI_v1_0, *)
public struct TabView<SelectionValue, Content>: View where SelectionValue: Hashable, Content: View {
    var selection: Binding<SelectionValue>?
    var content: Content

    public init(selection: Binding<SelectionValue>?, @ViewBuilder content: () -> Content) {
        self.selection = selection
        self.content = content()
    }

    @MainActor
    @preconcurrency
    public var body: some View {
        _VariadicView.Tree(_FinchTabViewRoot<SelectionValue>(selection: selection)) {
            content
        }
    }
}

@available(*, unavailable) extension TabView: Sendable {}

@available(OpenSwiftUI_v1_0, *)
extension TabView where SelectionValue == Int {
    nonisolated public init(@ViewBuilder content: () -> Content) {
        self.init(selection: nil, content: content)
    }
}

/// The tabs over the selected child. Without a selection binding, the view keeps its own
/// (the first tab to begin with).
struct _FinchTabViewRoot<Value: Hashable>: _VariadicView_UnaryViewRoot {
    var selection: Binding<Value>?
    @State private var ownIndex = 0

    func body(children: _VariadicView.Children) -> some View {
        let values = children.map { _finchTag(of: $0, as: Value.self) }
        let selectedIndex: Int = {
            if let selection, let index = values.firstIndex(where: { $0 == selection.wrappedValue }) { return index }
            return min(ownIndex, max(children.count - 1, 0))
        }()
        return VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(children.indices, id: \.self) { index in
                    _FinchTabButton(isSelected: index == selectedIndex) {
                        if let label = children[index][_FinchTabItemTraitKey.self] {
                            label
                        } else {
                            Text("Tab \(index + 1)")
                        }
                    } action: {
                        ownIndex = index
                        if let selection, let value = values[index] { selection.wrappedValue = value }
                    }
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            if children.indices.contains(selectedIndex) {
                children[selectedIndex]
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct _FinchTabButton<Label: View>: View {
    var isSelected: Bool
    @ViewBuilder var label: () -> Label
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ColorPicker

/// An NSColorWell, its colour bound to the picker's selection.
struct _FinchColorWell: NSViewRepresentable {
    var color: NSColor
    var supportsOpacity: Bool
    var changed: (NSColor) -> Void

    func makeNSView(context: Context) -> NSColorWell {
        let well = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 23))
        well.target = context.coordinator
        well.action = #selector(Coordinator.changed(_:))
        return well
    }

    func updateNSView(_ well: NSColorWell, context: Context) {
        context.coordinator.parent = self
        if well.color != color { well.color = color }
        well.supportsAlpha = supportsOpacity
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: _FinchColorWell
        init(_ parent: _FinchColorWell) { self.parent = parent }
        @objc func changed(_ sender: NSColorWell) { parent.changed(sender.color) }
    }
}

@available(OpenSwiftUI_v2_0, *)
public struct ColorPicker<Label>: View where Label: View {
    var color: Binding<NSColor>
    var supportsOpacity: Bool
    var label: Label

    public init(selection: Binding<Color>, supportsOpacity: Bool = true, @ViewBuilder label: () -> Label) {
        color = Binding(get: { NSColor(selection.wrappedValue) }, set: { selection.wrappedValue = Color(nsColor: $0) })
        self.supportsOpacity = supportsOpacity
        self.label = label()
    }

    public init(selection: Binding<CGColor>, supportsOpacity: Bool = true, @ViewBuilder label: () -> Label) {
        color = Binding(get: { NSColor(cgColor: selection.wrappedValue) ?? .black }, set: { selection.wrappedValue = $0.cgColor })
        self.supportsOpacity = supportsOpacity
        self.label = label()
    }

    @MainActor
    @preconcurrency
    public var body: some View {
        HStack(spacing: 6) {
            _FinchControlLabel(label: label)
            _FinchColorWell(color: color.wrappedValue, supportsOpacity: supportsOpacity) { color.wrappedValue = $0 }
                .frame(width: 44, height: 23)
        }
    }
}

@available(*, unavailable) extension ColorPicker: Sendable {}

@available(OpenSwiftUI_v2_0, *)
extension ColorPicker where Label == Text {
    nonisolated public init(_ titleKey: LocalizedStringKey, selection: Binding<Color>, supportsOpacity: Bool = true) {
        self.init(selection: selection, supportsOpacity: supportsOpacity) { Text(titleKey) }
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, selection: Binding<Color>, supportsOpacity: Bool = true) where S: StringProtocol {
        self.init(selection: selection, supportsOpacity: supportsOpacity) { Text(title) }
    }

    nonisolated public init(_ titleKey: LocalizedStringKey, selection: Binding<CGColor>, supportsOpacity: Bool = true) {
        self.init(selection: selection, supportsOpacity: supportsOpacity) { Text(titleKey) }
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, selection: Binding<CGColor>, supportsOpacity: Bool = true) where S: StringProtocol {
        self.init(selection: selection, supportsOpacity: supportsOpacity) { Text(title) }
    }
}

// MARK: - HelpButton

/// AppKit's help button; it opens the app's help book at the anchor.
struct _FinchHelpButton: NSViewRepresentable {
    var anchor: String
    var book: String

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.help(_:)))
        button.bezelStyle = .helpButton
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.parent = self }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: _FinchHelpButton
        init(_ parent: _FinchHelpButton) { self.parent = parent }
        @objc func help(_ sender: Any?) {
            NSHelpManager.shared.openHelpAnchor(parent.anchor, inBook: parent.book.isEmpty ? nil : parent.book)
        }
    }
}

public struct HelpButton: View {
    var anchor: String
    var book: String

    public init(anchor: String, book: String) {
        self.anchor = anchor
        self.book = book
    }

    public var body: some View {
        _FinchHelpButton(anchor: anchor, book: book).fixedSize()
    }
}

// MARK: - LabeledContent's title initializers

@available(OpenSwiftUI_v4_0, *)
extension LabeledContent where Label == Text, Content: View {
    nonisolated public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(content: content, label: { Text(titleKey) })
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, @ViewBuilder content: () -> Content) where S: StringProtocol {
        self.init(content: content, label: { Text(title) })
    }
}

@available(OpenSwiftUI_v4_0, *)
extension LabeledContent where Label == Text, Content == Text {
    nonisolated public init<S>(_ titleKey: LocalizedStringKey, value: S) where S: StringProtocol {
        self.init(content: { Text(value) }, label: { Text(titleKey) })
    }

    @_disfavoredOverload
    nonisolated public init<S1, S2>(_ title: S1, value: S2) where S1: StringProtocol, S2: StringProtocol {
        self.init(content: { Text(value) }, label: { Text(title) })
    }

    nonisolated public init<F>(_ titleKey: LocalizedStringKey, value: F.FormatInput, format: F)
        where F: FormatStyle, F.FormatInput: Equatable, F.FormatOutput == String {
        self.init(content: { Text(format.format(value)) }, label: { Text(titleKey) })
    }

    nonisolated public init<S, F>(_ title: S, value: F.FormatInput, format: F)
        where S: StringProtocol, F: FormatStyle, F.FormatInput: Equatable, F.FormatOutput == String {
        self.init(content: { Text(format.format(value)) }, label: { Text(title) })
    }
}
