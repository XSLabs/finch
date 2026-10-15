// SPDX-License-Identifier: MIT OR Apache-2.0
//
// TextEditor, backed by an AppKit text view so selection, typing, and scrolling use the
// system's normal text editing behavior.

import AppKit
import SwiftUICore

@available(OpenSwiftUI_v4_0, *)
@MainActor
@preconcurrency
public struct TextEditor: View {
    @Binding private var text: String
    @Environment(\.isEnabled) private var isEnabled

    public init(text: Binding<String>) {
        _text = text
    }

    public var body: some View {
        _FinchTextEditor(text: $text, isEnabled: isEnabled)
    }
}

@MainActor
struct _FinchTextEditor: NSViewRepresentable {
    var text: Binding<String>
    var isEnabled: Bool

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var isUpdating = false

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = NSTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize))
        textView.isRichText = false
        textView.isEditable = isEnabled
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width,
                                                       height: .greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 5, height: 5)
        textView.drawsBackground = false
        textView.delegate = context.coordinator
        textView.string = text.wrappedValue
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = text
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.isEditable = isEnabled
        textView.isSelectable = true
        guard textView.string != text.wrappedValue else { return }

        let selection = textView.selectedRange()
        context.coordinator.isUpdating = true
        textView.string = text.wrappedValue
        context.coordinator.isUpdating = false
        let length = textView.string.utf16.count
        let location = min(selection.location, length)
        textView.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
    }
}
