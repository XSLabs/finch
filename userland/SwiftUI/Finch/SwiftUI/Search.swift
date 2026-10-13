// SPDX-License-Identifier: MIT OR Apache-2.0
//
// searchable and its placements, suggestions and completions, to Apple's interface. On
// macOS the search field is a toolbar item at the trailing end of the window's toolbar: an
// NSSearchField bound to the text. Tokens aren't shown in the field yet, and suggestions
// aren't listed under it.

public import AppKit
import OpenAttributeGraphShims
@_spi(ForOpenSwiftUIOnly)
import SwiftUICore

@available(OpenSwiftUI_v3_0, *)
public struct SearchFieldPlacement: Sendable {
    enum Kind: Sendable { case automatic, toolbar, toolbarPrincipal, sidebar, navigationBarDrawer }
    let kind: Kind

    public static let automatic = SearchFieldPlacement(kind: .automatic)
    public static let toolbar = SearchFieldPlacement(kind: .toolbar)
    public static var toolbarPrincipal: SearchFieldPlacement { .init(kind: .toolbarPrincipal) }
    public static var sidebar: SearchFieldPlacement { .init(kind: .sidebar) }
}

/// The search field: an NSSearchField whose text is the binding's.
struct _FinchSearchField: NSViewRepresentable {
    var text: Binding<String>
    var prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField(frame: NSRect(x: 0, y: 0, width: 180, height: 22))
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))
        field.sendsSearchStringImmediately = true
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text.wrappedValue { field.stringValue = text.wrappedValue }
        field.placeholderString = prompt.isEmpty ? "Search" : prompt
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: _FinchSearchField
        init(_ parent: _FinchSearchField) { self.parent = parent }
        @objc func changed(_ sender: NSSearchField) { parent.text.wrappedValue = sender.stringValue }
    }
}

extension View {
    /// The content with a search field in its window's toolbar.
    func _finchSearchable(text: Binding<String>, prompt: Text?) -> some View {
        let promptString = prompt?._resolveText(in: EnvironmentValues()) ?? ""
        return toolbar {
            ToolbarItem(placement: .automatic) {
                _FinchSearchField(text: text, prompt: promptString).frame(width: 180)
            }
        }
    }
}

@available(OpenSwiftUI_v3_0, *)
extension View {
    nonisolated public func searchable(text: Binding<String>, placement: SearchFieldPlacement = .automatic, prompt: Text? = nil) -> some View {
        _finchSearchable(text: text, prompt: prompt)
    }

    nonisolated public func searchable(text: Binding<String>, placement: SearchFieldPlacement = .automatic,
                                       prompt: LocalizedStringKey) -> some View {
        _finchSearchable(text: text, prompt: Text(prompt))
    }

    @_disfavoredOverload
    nonisolated public func searchable<S>(text: Binding<String>, placement: SearchFieldPlacement = .automatic, prompt: S) -> some View
        where S: StringProtocol {
        _finchSearchable(text: text, prompt: Text(prompt))
    }

    nonisolated public func searchable<S>(text: Binding<String>, placement: SearchFieldPlacement = .automatic, prompt: Text? = nil,
                                          @ViewBuilder suggestions: () -> S) -> some View where S: View {
        _finchSearchable(text: text, prompt: prompt)
    }

    nonisolated public func searchable<S>(text: Binding<String>, placement: SearchFieldPlacement = .automatic, prompt: LocalizedStringKey,
                                          @ViewBuilder suggestions: () -> S) -> some View where S: View {
        _finchSearchable(text: text, prompt: Text(prompt))
    }

    nonisolated public func searchSuggestions<S>(@ViewBuilder _ suggestions: () -> S) -> some View where S: View { self }

    nonisolated public func searchCompletion(_ completion: String) -> some View { self }
}

@available(OpenSwiftUI_v4_0, *)
extension View {
    nonisolated public func searchable<C, T, S>(text: Binding<String>, tokens: Binding<C>, placement: SearchFieldPlacement = .automatic,
                                                prompt: S, @ViewBuilder token: @escaping (C.Element) -> T) -> some View
        where C: RandomAccessCollection, C: RangeReplaceableCollection, T: View, S: StringProtocol, C.Element: Identifiable {
        _finchSearchable(text: text, prompt: Text(prompt))
    }

    nonisolated public func searchable<C, T>(text: Binding<String>, tokens: Binding<C>, placement: SearchFieldPlacement = .automatic,
                                             prompt: Text? = nil, @ViewBuilder token: @escaping (C.Element) -> T) -> some View
        where C: RandomAccessCollection, C: RangeReplaceableCollection, T: View, C.Element: Identifiable {
        _finchSearchable(text: text, prompt: prompt)
    }
}

@available(OpenSwiftUI_v5_0, *)
extension View {
    nonisolated public func searchable<C>(text: Binding<String>, editableTokens: Binding<C>, placement: SearchFieldPlacement = .automatic,
                                          prompt: Text? = nil, @ViewBuilder token: @escaping (Binding<C.Element>) -> some View) -> some View
        where C: RandomAccessCollection, C: RangeReplaceableCollection, C.Element: Identifiable {
        _finchSearchable(text: text, prompt: prompt)
    }

    nonisolated public func searchable<C>(text: Binding<String>, editableTokens: Binding<C>, isPresented: Binding<Bool>,
                                          placement: SearchFieldPlacement = .automatic, prompt: Text? = nil,
                                          @ViewBuilder token: @escaping (Binding<C.Element>) -> some View) -> some View
        where C: RandomAccessCollection, C: RangeReplaceableCollection, C.Element: Identifiable {
        _finchSearchable(text: text, prompt: prompt)
    }

    nonisolated public func searchable(text: Binding<String>, isPresented: Binding<Bool>, placement: SearchFieldPlacement = .automatic,
                                       prompt: Text? = nil) -> some View {
        _finchSearchable(text: text, prompt: prompt)
    }
}
