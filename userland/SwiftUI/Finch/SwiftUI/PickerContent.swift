// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Picker content (SwiftUI's newer picker API, which Calculator uses): options declared as
// PickerContent (PickerOption(value:content:), groups of them, disabled or with keyboard
// shortcuts) built by PickerBuilder. Each piece of content is shown through its identified
// view, the view a picker's options are made of, tagged with the option's value; a picker of
// picker content is a picker of those views.
//
// PickerBuilder's blocks are inlined into apps: an app's block makes a _TuplePickerContent of
// its contents' identified views itself, so that type's one stored value (the tuple) is laid
// out as Apple's is.

import SwiftUICore

@available(OpenSwiftUI_v6_0, *)
public protocol PickerContent<SelectionValue> {
    associatedtype SelectionValue: Hashable
    associatedtype _IdentifiedView: View
    associatedtype Body: PickerContent

    var _identifiedView: _IdentifiedView { get }

    @PickerBuilder<SelectionValue>
    var body: Body { get }
}

/// Composite content's identified view: its body's.
@available(OpenSwiftUI_v6_0, *)
public struct _PickerContentBodyAdaptor<Content>: View where Content: PickerContent {
    var content: Content

    public var body: Content.Body._IdentifiedView {
        content.body._identifiedView
    }
}

@available(OpenSwiftUI_v6_0, *)
extension PickerContent where _IdentifiedView == _PickerContentBodyAdaptor<Self> {
    public var _identifiedView: _PickerContentBodyAdaptor<Self> {
        _PickerContentBodyAdaptor(content: self)
    }
}

// MARK: - Options

@available(OpenSwiftUI_v6_0, *)
public struct PickerOption<SelectionValue, Content>: PickerContent where SelectionValue: Hashable, Content: View {
    var value: SelectionValue
    var isAlternate: Bool
    var content: Content

    public init(value: SelectionValue, content: () -> Content) {
        self.init(value: value, isAlternate: false, content: content)
    }

    public init(value: SelectionValue, isAlternate: Bool, content: () -> Content) {
        self.value = value
        self.isAlternate = isAlternate
        self.content = content()
    }

    public init(_ value: SelectionValue, content: () -> Content) {
        self.init(value: value, isAlternate: false, content: content)
    }

    public init(_ value: SelectionValue, isAlternate: Bool, content: () -> Content) {
        self.init(value: value, isAlternate: isAlternate, content: content)
    }

    public var _identifiedView: some View {
        content.tag(value)
    }

    public var body: PickerOption<SelectionValue, Content> { self }
}

@available(OpenSwiftUI_v6_0, *)
extension PickerOption where Content == Text {
    public init(_ titleKey: LocalizedStringKey, value: SelectionValue) {
        self.init(value: value, isAlternate: false) { Text(titleKey) }
    }

    public init(_ titleKey: LocalizedStringKey, value: SelectionValue, isAlternate: Bool) {
        self.init(value: value, isAlternate: isAlternate) { Text(titleKey) }
    }

    @_disfavoredOverload
    public init<S>(_ title: S, value: SelectionValue) where S: StringProtocol {
        self.init(value: value, isAlternate: false) { Text(title) }
    }

    @_disfavoredOverload
    public init<S>(_ title: S, value: SelectionValue, isAlternate: Bool) where S: StringProtocol {
        self.init(value: value, isAlternate: isAlternate) { Text(title) }
    }
}

// MARK: - Containers and modifiers

@available(OpenSwiftUI_v6_0, *)
@frozen
public struct _TuplePickerContent<SelectionValue, T>: PickerContent where SelectionValue: Hashable {
    @usableFromInline
    var value: T

    @inlinable
    public init(_ value: T) {
        self.value = value
    }

    public var _identifiedView: TupleView<T> {
        TupleView(value)
    }

    public var body: _TuplePickerContent<SelectionValue, T> { self }
}

@available(OpenSwiftUI_v6_0, *)
public struct _DisabledPickerContent<Content>: PickerContent where Content: PickerContent {
    public typealias SelectionValue = Content.SelectionValue
    var content: Content
    var isDisabled: Bool

    public var _identifiedView: some View {
        content._identifiedView.disabled(isDisabled)
    }

    public var body: _DisabledPickerContent<Content> { self }
}

@available(OpenSwiftUI_v6_0, *)
public struct _KeyboardShortcutPickerContent<Content>: PickerContent where Content: PickerContent {
    public typealias SelectionValue = Content.SelectionValue
    var content: Content
    var shortcut: KeyboardShortcut?

    public var _identifiedView: some View {
        content._identifiedView.keyboardShortcut(shortcut)
    }

    public var body: _KeyboardShortcutPickerContent<Content> { self }
}

@available(OpenSwiftUI_v6_0, *)
public struct _OnHoverPickerContent<Content>: PickerContent where Content: PickerContent {
    public typealias SelectionValue = Content.SelectionValue
    var content: Content
    var action: (Bool) -> Void

    public var _identifiedView: some View {
        content._identifiedView.onHover(perform: action)
    }

    public var body: _OnHoverPickerContent<Content> { self }
}

@available(OpenSwiftUI_v6_0, *)
extension PickerContent {
    public func disabled(_ disabled: Bool) -> _DisabledPickerContent<Self> {
        _DisabledPickerContent(content: self, isDisabled: disabled)
    }

    public func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> _KeyboardShortcutPickerContent<Self> {
        _KeyboardShortcutPickerContent(content: self, shortcut: KeyboardShortcut(key, modifiers: modifiers))
    }

    public func keyboardShortcut(_ shortcut: KeyboardShortcut?) -> _KeyboardShortcutPickerContent<Self> {
        _KeyboardShortcutPickerContent(content: self, shortcut: shortcut)
    }

    public func onHover(perform action: @escaping (Bool) -> Void) -> _OnHoverPickerContent<Self> {
        _OnHoverPickerContent(content: self, action: action)
    }
}

// MARK: - PickerBuilder

@available(OpenSwiftUI_v6_0, *)
@resultBuilder
public struct PickerBuilder<SelectionValue> where SelectionValue: Hashable {
    @_alwaysEmitIntoClient
    public static func buildExpression<C>(_ content: C) -> C where C: PickerContent {
        content
    }

    @_alwaysEmitIntoClient
    public static func buildBlock<C>(_ content: C) -> C where C: PickerContent {
        content
    }

    @_alwaysEmitIntoClient
    public static func buildBlock<each C>(_ content: repeat each C)
        -> _TuplePickerContent<SelectionValue, (repeat (each C)._IdentifiedView)> where repeat each C: PickerContent {
        _TuplePickerContent((repeat (each content)._identifiedView))
    }

    /// A picker's content view: the picker content's identified view.
    public struct Content<C>: View where C: PickerContent {
        var content: C

        public var body: C._IdentifiedView {
            content._identifiedView
        }
    }
}

// MARK: - Pickers of picker content

@available(OpenSwiftUI_v6_0, *)
extension Picker {
    nonisolated public init<C>(selection: Binding<SelectionValue>, @PickerBuilder<SelectionValue> content: () -> C,
                               @ViewBuilder label: () -> Label)
        where Content == PickerBuilder<SelectionValue>.Content<C>, C: PickerContent {
        self.init(selection: _FinchPickerSelection(selection), label: label(), content: PickerBuilder<SelectionValue>.Content(content: content()))
    }
}

@available(OpenSwiftUI_v6_0, *)
extension Picker where Label == Text {
    nonisolated public init<C>(_ titleKey: LocalizedStringKey, selection: Binding<SelectionValue>,
                               @PickerBuilder<SelectionValue> content: () -> C)
        where Content == PickerBuilder<SelectionValue>.Content<C>, C: PickerContent {
        self.init(selection: _FinchPickerSelection(selection), label: Text(titleKey),
                  content: PickerBuilder<SelectionValue>.Content(content: content()))
    }

    @_disfavoredOverload
    nonisolated public init<S, C>(_ title: S, selection: Binding<SelectionValue>,
                                  @PickerBuilder<SelectionValue> content: () -> C)
        where Content == PickerBuilder<SelectionValue>.Content<C>, C: PickerContent, S: StringProtocol {
        self.init(selection: _FinchPickerSelection(selection), label: Text(title),
                  content: PickerBuilder<SelectionValue>.Content(content: content()))
    }
}

/// A picker of picker content lists its options as a picker of views does.
extension PickerBuilder.Content: _FinchViewSequence {
    var _finchViews: [Any] { [content._identifiedView] }
}
