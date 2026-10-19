// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Small SwiftUI entry points used by current Mac apps, backed by Finch's existing controls,
// styles and AppKit window.

public import AppKit
public import Foundation
@_spi(ForOpenSwiftUIOnly) import SwiftUICore

extension Material {
    public static var ultraThick: Material { ._finchSwiftUIUltraThick }
}

extension Link where Label == Text {
    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, destination: URL) where S: StringProtocol {
        self.init(destination: destination) { Text(title) }
    }
}

extension EnvironmentValues {
    public var undoManager: UndoManager? {
        NSApp.keyWindow?.undoManager
    }
}

/// A button that opens an app's Help book or a URL.
@available(macOS 14.0, *)
public struct HelpLink: View {
    private var action: () -> Void

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public init(destination: URL) {
        self.init(action: {
            Task { @MainActor in NSWorkspace.shared.open(destination) }
        })
    }

    public init(anchor: NSHelpManager.AnchorName) {
        self.init(action: {
            Task { @MainActor in NSHelpManager.shared.openHelpAnchor(anchor, inBook: nil) }
        })
    }

    public init(anchor: NSHelpManager.AnchorName, book: NSHelpManager.BookName) {
        self.init(action: {
            Task { @MainActor in NSHelpManager.shared.openHelpAnchor(anchor, inBook: book) }
        })
    }

    public var body: some View {
        Button(action: action) {
            Label("Help", systemImage: "questionmark.circle")
        }
        .buttonStyle(.borderless)
    }
}
