// SPDX-License-Identifier: MIT OR Apache-2.0
//
// On macOS the exit command is the Escape key.

import SwiftUICore

@available(OpenSwiftUI_v1_0, *)
extension View {
    nonisolated public func onExitCommand(perform action: (() -> Void)?) -> some View {
        onKeyPress(.escape, phases: [.down]) { _ in
            guard let action else { return .ignored }
            action()
            return .handled
        }
    }
}
