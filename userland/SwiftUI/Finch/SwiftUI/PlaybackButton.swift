// SPDX-License-Identifier: MIT OR Apache-2.0
// The small playback control used by AppIntents' local SwiftUI bridge.

public import Foundation
import SwiftUICore

@MainActor
@preconcurrency
public struct PlaybackButton: View {
    public enum State: Hashable, Codable, Sendable {
        case paused(Date)
        case playing
        case unplayed
    }

    private let state: State
    private let systemImage: String?
    private let alignment: Alignment
    private let action: () -> Void

    @_spi(AppIntents)
    public nonisolated init(interval: ClosedRange<Date>?, state: State, systemImage: String?, alignment: Alignment,
                           lnAction: NSObject, perform action: @escaping () -> Void) {
        self.state = state
        self.systemImage = systemImage
        self.alignment = alignment
        self.action = action
    }

    @preconcurrency
    public var body: some View {
        let name = systemImage ?? (state == .playing ? "pause.fill" : "play.fill")
        Button(action: action) {
            Image(systemName: name)
                .frame(maxWidth: .infinity, alignment: alignment)
        }
    }
}
