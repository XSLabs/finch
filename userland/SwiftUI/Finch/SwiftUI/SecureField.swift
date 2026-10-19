// SPDX-License-Identifier: MIT OR Apache-2.0
//
// SecureField edits the same string binding as TextField but uses AppKit's masked entry.

public import Foundation
import SwiftUICore

@available(OpenSwiftUI_v1_0, *)
@MainActor
@preconcurrency
public struct SecureField<Label>: View where Label: View {
    var model: _FinchTextFieldModel
    var label: Label

    nonisolated init(model: _FinchTextFieldModel, label: Label) {
        self.model = model
        self.label = label
    }

    @MainActor
    @preconcurrency
    public var body: some View {
        _FinchStyledTextField(model: model, label: label)
    }
}

@available(OpenSwiftUI_v1_0, *)
extension SecureField where Label == Text {
    nonisolated public init(_ titleKey: LocalizedStringKey, text: Binding<String>, prompt: Text?) {
        let title = Text(titleKey)
        self.init(model: textModel(text, placeholder: prompt ?? title, secure: true), label: title)
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, text: Binding<String>, prompt: Text?) where S: StringProtocol {
        let label = Text(title)
        self.init(model: textModel(text, placeholder: prompt ?? label, secure: true), label: label)
    }

    nonisolated public init(_ titleKey: LocalizedStringKey, text: Binding<String>, onCommit: @escaping () -> Void) {
        let title = Text(titleKey)
        self.init(model: textModel(text, placeholder: title, onCommit: onCommit, secure: true), label: title)
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, text: Binding<String>, onCommit: @escaping () -> Void)
        where S: StringProtocol {
        let label = Text(title)
        self.init(model: textModel(text, placeholder: label, onCommit: onCommit, secure: true), label: label)
    }

    nonisolated public init(_ titleKey: LocalizedStringKey, text: Binding<String>) {
        self.init(titleKey, text: text, prompt: nil)
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, text: Binding<String>) where S: StringProtocol {
        self.init(title, text: text, prompt: nil)
    }

    @available(macOS 13.0, *)
    @_disfavoredOverload
    nonisolated public init(_ title: LocalizedStringResource, text: Binding<String>, prompt: Text? = nil) {
        self.init(text: text, prompt: prompt, label: { Text(title) })
    }
}

@available(OpenSwiftUI_v1_0, *)
extension SecureField {
    nonisolated public init(text: Binding<String>, prompt: Text? = nil, @ViewBuilder label: () -> Label) {
        self.init(model: textModel(text, placeholder: prompt, secure: true), label: label())
    }
}

@available(*, unavailable)
extension SecureField: Sendable {}
