// SPDX-License-Identifier: MIT OR Apache-2.0
//
// FileDocument and fileExporter, to Apple's interface. Exporting shows a save panel (as a
// sheet on the view's window when it has one) and writes the document's file wrapper to the
// chosen URL; the completion hears the URL or the error.

public import AppKit
public import Foundation
import OpenAttributeGraphShims
@_spi(ForOpenSwiftUIOnly)
import SwiftUICore
public import UniformTypeIdentifiers

@available(OpenSwiftUI_v2_0, *)
public struct FileDocumentReadConfiguration {
    public let contentType: UTType
    public let file: FileWrapper
}

@available(OpenSwiftUI_v2_0, *)
public struct FileDocumentWriteConfiguration {
    public let contentType: UTType
    public let existingFile: FileWrapper?
}

@available(*, unavailable) extension FileDocumentReadConfiguration: Sendable {}
@available(*, unavailable) extension FileDocumentWriteConfiguration: Sendable {}

@available(OpenSwiftUI_v2_0, *)
@preconcurrency
public protocol FileDocument: Sendable {
    static var readableContentTypes: [UTType] { get }
    static var writableContentTypes: [UTType] { get }
    init(configuration: Self.ReadConfiguration) throws
    typealias ReadConfiguration = FileDocumentReadConfiguration
    func fileWrapper(configuration: Self.WriteConfiguration) throws -> FileWrapper
    typealias WriteConfiguration = FileDocumentWriteConfiguration
}

@available(OpenSwiftUI_v2_0, *)
extension FileDocument {
    public static var writableContentTypes: [UTType] { readableContentTypes }
}

/// Shows the save panel when the binding turns true, then writes the document.
struct _FinchFileExporter<Content: View>: View {
    var content: Content
    var isPresented: Binding<Bool>
    var contentType: UTType
    var defaultFilename: String?
    var write: (URL, UTType) throws -> Void
    var onCompletion: (Result<URL, any Error>) -> Void
    var onCancellation: () -> Void

    var body: some View {
        content.onChange(of: isPresented.wrappedValue) { _, presented in
            guard presented else { return }
            present()
        }
    }

    @MainActor
    private func present() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        if let defaultFilename { panel.nameFieldStringValue = defaultFilename }
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            isPresented.wrappedValue = false
            guard response == .OK, let url = panel.url else {
                onCancellation()
                return
            }
            do {
                try write(url, contentType)
                onCompletion(.success(url))
            } catch {
                onCompletion(.failure(error))
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }
}

@available(OpenSwiftUI_v2_0, *)
extension View {
    nonisolated public func fileExporter<D>(isPresented: Binding<Bool>, document: D?, contentType: UTType, defaultFilename: String? = nil,
                                            onCompletion: @escaping (_ result: Result<URL, any Error>) -> Void) -> some View
        where D: FileDocument {
        _FinchFileExporter(content: self, isPresented: isPresented, contentType: contentType, defaultFilename: defaultFilename,
                           write: { url, type in
                               guard let document else { return }
                               let wrapper = try document.fileWrapper(configuration: .init(contentType: type, existingFile: nil))
                               try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
                           },
                           onCompletion: onCompletion, onCancellation: {})
    }

    nonisolated public func fileExporter<D>(isPresented: Binding<Bool>, document: D?, contentTypes: [UTType] = [],
                                            defaultFilename: String? = nil,
                                            onCompletion: @escaping (Result<URL, any Error>) -> Void,
                                            onCancellation: @escaping () -> Void = {}) -> some View where D: FileDocument {
        _FinchFileExporter(content: self, isPresented: isPresented,
                           contentType: contentTypes.first ?? D.writableContentTypes.first ?? .data,
                           defaultFilename: defaultFilename,
                           write: { url, type in
                               guard let document else { return }
                               let wrapper = try document.fileWrapper(configuration: .init(contentType: type, existingFile: nil))
                               try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
                           },
                           onCompletion: onCompletion, onCancellation: onCancellation)
    }
}
