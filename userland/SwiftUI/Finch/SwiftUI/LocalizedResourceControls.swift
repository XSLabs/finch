// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Localized labels for controls. Each initializer keeps the resource on Text so it is
// resolved by the same text and menu drawing path as the corresponding string-key form.

public import Foundation
import SwiftUICore

@available(macOS 13.0, *)
extension GroupBox where Label == Text {
    @_disfavoredOverload
    nonisolated public init(_ title: LocalizedStringResource, @ViewBuilder content: () -> Content) {
        self.init(label: Text(title), content: content)
    }
}

@available(macOS 13.0, *)
extension Menu where Label == Text {
    @_disfavoredOverload
    nonisolated public init(_ title: LocalizedStringResource, @ViewBuilder content: () -> Content) {
        self.init(label: Text(title), content: content(), primaryAction: nil)
    }

    @_disfavoredOverload
    nonisolated public init(_ title: LocalizedStringResource, @ViewBuilder content: () -> Content,
                            primaryAction: @escaping () -> Void) {
        self.init(label: Text(title), content: content(), primaryAction: primaryAction)
    }
}

@available(macOS 13.0, *)
extension Section where Parent == Text, Content: View, Footer == EmptyView {
    @_disfavoredOverload
    nonisolated public init(_ title: LocalizedStringResource, @ViewBuilder content: () -> Content) {
        self.init(header: Text(title), content: content(), footer: EmptyView(), isExpanded: nil)
    }

}

@available(macOS 14.0, *)
extension Section where Parent == Text, Content: View, Footer == EmptyView {
    @_disfavoredOverload
    nonisolated public init(_ title: LocalizedStringResource, isExpanded: Binding<Bool>,
                            @ViewBuilder content: () -> Content) {
        self.init(header: Text(title), content: content(), footer: EmptyView(), isExpanded: isExpanded)
    }
}

@available(macOS 13.0, *)
extension Picker where Label == Text {
    @_disfavoredOverload
    nonisolated public init(_ title: LocalizedStringResource, selection: Binding<SelectionValue>,
                            @ViewBuilder content: () -> Content) {
        self.init(selection: _FinchPickerSelection(selection), label: Text(title), content: content())
    }

    @_disfavoredOverload
    nonisolated public init<C>(_ title: LocalizedStringResource, sources: C,
                               selection: KeyPath<C.Element, Binding<SelectionValue>>,
                               @ViewBuilder content: () -> Content) where C: RandomAccessCollection {
        self.init(selection: _FinchPickerSelection(sources: sources, selection: selection), label: Text(title),
                  content: content())
    }
}

@available(macOS 13.0, *)
extension Stepper where Label == Text {
    @_disfavoredOverload
    nonisolated public init(_ title: LocalizedStringResource, onIncrement: (() -> Void)?,
                            onDecrement: (() -> Void)?, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.init(onIncrement: onIncrement, onDecrement: onDecrement, onEditingChanged: onEditingChanged) {
            Text(title)
        }
    }

    @_disfavoredOverload
    nonisolated public init<V>(_ title: LocalizedStringResource, value: Binding<V>, step: V.Stride = 1,
                               onEditingChanged: @escaping (Bool) -> Void = { _ in }) where V: Strideable {
        self.init(value: value, step: step, onEditingChanged: onEditingChanged) { Text(title) }
    }

    @_disfavoredOverload
    nonisolated public init<V>(_ title: LocalizedStringResource, value: Binding<V>, in bounds: ClosedRange<V>,
                               step: V.Stride = 1, onEditingChanged: @escaping (Bool) -> Void = { _ in })
        where V: Strideable {
        self.init(value: value, in: bounds, step: step, onEditingChanged: onEditingChanged) { Text(title) }
    }
}

@available(macOS 13.0, *)
extension TextField where Label == Text {
    @_disfavoredOverload
    nonisolated public init(_ title: LocalizedStringResource, text: Binding<String>) {
        let label = Text(title)
        self.init(model: textModel(text, placeholder: label), label: label)
    }

    @_disfavoredOverload
    nonisolated public init(_ title: LocalizedStringResource, text: Binding<String>, prompt: Text?) {
        let label = Text(title)
        self.init(model: textModel(text, placeholder: prompt ?? label), label: label)
    }

    @_disfavoredOverload
    nonisolated public init(_ title: LocalizedStringResource, text: Binding<String>, axis: Axis) {
        let label = Text(title)
        self.init(model: textModel(text, placeholder: label, multiline: axis == .vertical), label: label)
    }

    @_disfavoredOverload
    nonisolated public init(_ title: LocalizedStringResource, text: Binding<String>, prompt: Text?, axis: Axis) {
        let label = Text(title)
        self.init(model: textModel(text, placeholder: prompt ?? label, multiline: axis == .vertical), label: label)
    }

    @_disfavoredOverload
    nonisolated public init<F>(_ title: LocalizedStringResource, value: Binding<F.FormatInput>, format: F,
                               prompt: Text? = nil)
        where F: ParseableFormatStyle, F.FormatOutput == String {
        let label = Text(title)
        self.init(model: formatModel(value, format: format, placeholder: prompt ?? label), label: label)
    }

    @_disfavoredOverload
    nonisolated public init<F>(_ title: LocalizedStringResource, value: Binding<F.FormatInput?>, format: F,
                               prompt: Text? = nil)
        where F: ParseableFormatStyle, F.FormatOutput == String {
        let label = Text(title)
        self.init(model: optionalFormatModel(value, format: format, placeholder: prompt ?? label), label: label)
    }

    @_disfavoredOverload
    nonisolated public init<V>(_ title: LocalizedStringResource, value: Binding<V>, formatter: Formatter,
                               prompt: Text?) {
        let label = Text(title)
        self.init(model: formatterModel(value, formatter: formatter, placeholder: prompt ?? label), label: label)
    }

    @_disfavoredOverload
    nonisolated public init<V>(_ title: LocalizedStringResource, value: Binding<V>, formatter: Formatter) {
        let label = Text(title)
        self.init(model: formatterModel(value, formatter: formatter, placeholder: label), label: label)
    }
}

@available(macOS 13.0, *)
extension Toggle where Label == Text {
    @_disfavoredOverload
    nonisolated public init(_ title: LocalizedStringResource, isOn: Binding<Bool>) {
        self.init(toggledOn: [isOn]) { Text(title) }
    }

    @_disfavoredOverload
    nonisolated public init<C>(_ title: LocalizedStringResource, sources: C,
                               isOn: KeyPath<C.Element, Binding<Bool>>) where C: RandomAccessCollection {
        self.init(toggledOn: sources.lazy.map { $0[keyPath: isOn] }) { Text(title) }
    }
}
