// SPDX-License-Identifier: MIT OR Apache-2.0
// A small app for checking SwiftUI focus, key handling, native text entry, and menu shortcuts.
import SwiftUI
import Combine

private final class FocusKeyboardModel: ObservableObject {
    @Published var menuShortcutCount = 0
    @Published var bubbleCount = 0
    @Published var disableFirst = false
    @Published var showSecond = true
}

private let focusKeyboardModel = FocusKeyboardModel()

private enum FocusTarget: Hashable {
    case first
    case second
    case editor
}

@main
struct SwiftUIFocusKeyboardApp: App {
    var body: some Scene {
        WindowGroup("SwiftUI Focus Keyboard") {
            FocusKeyboardView()
        }
        .commands {
            CommandMenu("Focus Test") {
                Button("Menu Shortcut") {
                    focusKeyboardModel.menuShortcutCount += 1
                }
                .keyboardShortcut("m")
                Button("Disable First") {
                    focusKeyboardModel.disableFirst.toggle()
                }
                .keyboardShortcut("d", modifiers: .command)
                Button("Hide Second") {
                    focusKeyboardModel.showSecond = false
                }
                .keyboardShortcut("h", modifiers: .command)
            }
        }
    }
}

private struct FocusKeyboardView: View {
    @FocusState private var target: FocusTarget?
    @State private var firstCount = 0
    @State private var secondCount = 0
    @State private var text = ""
    @ObservedObject private var model = focusKeyboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Selected: \(target.map { String(describing: $0) } ?? "none")")
            HStack(spacing: 12) {
                targetView("First", count: firstCount, target: .first, isDisabled: model.disableFirst) {
                    firstCount += 1
                }
                if model.showSecond {
                    targetView("Second", count: secondCount, target: .second, onRemove: {
                        model.showSecond = false
                    }) {
                        secondCount += 1
                    }
                }
            }
            TextField("Type here", text: $text)
                .focused($target, equals: .editor)
            Text("Text: \(text)")
            Text("Menu shortcut: \(model.menuShortcutCount)")
            Text("Return bubble count: \(model.bubbleCount)")
        }
        .padding(20)
        .onKeyPress(.return) {
            model.bubbleCount += 1
            return .handled
        }
        .onAppear {
            if target == nil {
                target = .first
            }
        }
    }

    private func targetView(
        _ name: String,
        count: Int,
        target focusTarget: FocusTarget,
        isDisabled: Bool = false,
        onRemove: (() -> Void)? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Text("\(name): \(count)")
            .frame(width: 130, height: 52)
            .background(target == focusTarget ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.15))
            .contentShape(Rectangle())
            .focusable()
            .focused($target, equals: focusTarget)
            .disabled(isDisabled)
            .onKeyPress(.space) {
                action()
                return .handled
            }
            .onKeyPress(.return) { .ignored }
            .onKeyPress(.escape) {
                guard let onRemove else { return .ignored }
                onRemove()
                return .handled
            }
            .onTapGesture {
                target = focusTarget
            }
    }
}
