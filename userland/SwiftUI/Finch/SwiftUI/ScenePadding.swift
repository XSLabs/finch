// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Scene padding gives window content a small margin from the scene's edges.

import SwiftUICore

@available(OpenSwiftUI_v1_0, *)
public struct ScenePadding: Equatable, Sendable {
    fileprivate var length: CGFloat

    private init(length: CGFloat) {
        self.length = length
    }

    public static let minimum = ScenePadding(length: 8)

    public static func == (lhs: ScenePadding, rhs: ScenePadding) -> Bool {
        lhs.length == rhs.length
    }
}

@available(OpenSwiftUI_v1_0, *)
extension View {
    nonisolated public func scenePadding(_ edges: Edge.Set = .all) -> some View {
        padding(edges, Self.scenePaddingLength)
    }

    nonisolated public func scenePadding(_ padding: ScenePadding, edges: Edge.Set = .all) -> some View {
        self.padding(edges, padding.length)
    }

    private static var scenePaddingLength: CGFloat { ScenePadding.minimum.length }
}
