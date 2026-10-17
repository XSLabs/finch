// SPDX-License-Identifier: MIT OR Apache-2.0
//
// fileImporter presents the native open panel and returns the selected URLs.

import AppKit
import Foundation
import SwiftUICore
public import UniformTypeIdentifiers

@available(OpenSwiftUI_v2_0, *)
private struct _FinchFileImporter<Content: View>: View {
    var content: Content
    var isPresented: Binding<Bool>
    var allowedContentTypes: [UTType]
    var allowsMultipleSelection: Bool
    var onCompletion: (Result<[URL], any Error>) -> Void
    var onCancellation: () -> Void

    var body: some View {
        content.onChange(of: isPresented.wrappedValue) { _, presented in
            guard presented else { return }
            present()
        }
    }

    @MainActor
    private func present() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = allowedContentTypes
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canChooseDirectories = allowedContentTypes.contains(.folder)

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            isPresented.wrappedValue = false
            guard response == .OK else {
                onCancellation()
                return
            }
            onCompletion(.success(panel.urls))
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
    nonisolated public func fileImporter(
        isPresented: Binding<Bool>,
        allowedContentTypes: [UTType],
        onCompletion: @escaping (_ result: Result<URL, any Error>) -> Void
    ) -> some View {
        _FinchFileImporter(content: self, isPresented: isPresented,
                           allowedContentTypes: allowedContentTypes, allowsMultipleSelection: false,
                           onCompletion: { result in
                               switch result {
                               case .success(let urls):
                                   if let url = urls.first {
                                       onCompletion(.success(url))
                                   } else {
                                       onCompletion(.failure(CancellationError()))
                                   }
                               case .failure(let error):
                                   onCompletion(.failure(error))
                               }
                           }, onCancellation: {
                               onCompletion(.failure(CancellationError()))
                           })
    }

    nonisolated public func fileImporter(
        isPresented: Binding<Bool>,
        allowedContentTypes: [UTType],
        allowsMultipleSelection: Bool,
        onCompletion: @escaping (_ result: Result<[URL], any Error>) -> Void
    ) -> some View {
        _FinchFileImporter(content: self, isPresented: isPresented,
                           allowedContentTypes: allowedContentTypes,
                           allowsMultipleSelection: allowsMultipleSelection,
                           onCompletion: onCompletion,
                           onCancellation: { onCompletion(.failure(CancellationError())) })
    }

    @available(OpenSwiftUI_v5_0, *)
    nonisolated public func fileImporter(
        isPresented: Binding<Bool>,
        allowedContentTypes: [UTType],
        allowsMultipleSelection: Bool,
        onCompletion: @escaping (_ result: Result<[URL], any Error>) -> Void,
        onCancellation: @escaping () -> Void
    ) -> some View {
        _FinchFileImporter(content: self, isPresented: isPresented,
                           allowedContentTypes: allowedContentTypes,
                           allowsMultipleSelection: allowsMultipleSelection,
                           onCompletion: onCompletion,
                           onCancellation: onCancellation)
    }
}
