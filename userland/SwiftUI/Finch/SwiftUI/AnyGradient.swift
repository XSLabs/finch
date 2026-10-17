// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Type-erased gradients keep their stops and remain usable by gradient styles.

@_spi(ForOpenSwiftUIOnly) import SwiftUICore

@available(macOS 13.0, *)
@frozen
public struct AnyGradient: Hashable, ShapeStyle, @unchecked Sendable {
    package var gradient: Gradient

    public init(_ gradient: Gradient) {
        self.gradient = gradient
    }

    public func _apply(to shape: inout _ShapeStyle_Shape) {
        let vertical = LinearGradient(gradient: gradient, startPoint: .top, endPoint: .bottom)
        shape.result = .style(AnyShapeStyle(vertical))
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(gradient.stops.count)
        for stop in gradient.stops {
            hasher.combine(stop.color)
            hasher.combine(stop.location)
        }
    }

    public static func == (lhs: AnyGradient, rhs: AnyGradient) -> Bool {
        lhs.gradient == rhs.gradient
    }

    public var hashValue: Int {
        var hasher = Hasher()
        hash(into: &hasher)
        return hasher.finalize()
    }

    @available(macOS 14.0, *)
    public typealias Resolved = Never
}
