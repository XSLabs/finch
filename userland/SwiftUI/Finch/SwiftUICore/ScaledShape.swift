// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ScaledShape (Shape.scale), to Apple's interface: a shape's path scaled about an anchor in
// its rect.

public import OpenCoreGraphicsShims

@available(OpenSwiftUI_v1_0, *)
@frozen
public struct ScaledShape<Content>: Shape where Content: Shape {
    public var shape: Content
    public var scale: CGSize
    public var anchor: UnitPoint

    @inlinable
    public init(shape: Content, scale: CGSize, anchor: UnitPoint = .center) {
        self.shape = shape
        self.scale = scale
        self.anchor = anchor
    }

    nonisolated public func path(in rect: CGRect) -> Path {
        let x = rect.minX + rect.width * anchor.x
        let y = rect.minY + rect.height * anchor.y
        let transform = CGAffineTransform(translationX: x, y: y)
            .scaledBy(x: scale.width, y: scale.height)
            .translatedBy(x: -x, y: -y)
        return shape.path(in: rect).applying(transform)
    }

    nonisolated public static var role: ShapeRole { Content.role }

    nonisolated public var layoutDirectionBehavior: LayoutDirectionBehavior { shape.layoutDirectionBehavior }

    public typealias AnimatableData = AnimatablePair<Content.AnimatableData, AnimatablePair<CGSize.AnimatableData, UnitPoint.AnimatableData>>

    public var animatableData: AnimatableData {
        get { AnimatablePair(shape.animatableData, AnimatablePair(scale.animatableData, anchor.animatableData)) }
        set {
            shape.animatableData = newValue.first
            scale.animatableData = newValue.second.first
            anchor.animatableData = newValue.second.second
        }
    }
}

@available(OpenSwiftUI_v1_0, *)
extension Shape {
    @inlinable
    nonisolated public func scale(x: CGFloat = 1, y: CGFloat = 1, anchor: UnitPoint = .center) -> ScaledShape<Self> {
        ScaledShape(shape: self, scale: CGSize(width: x, height: y), anchor: anchor)
    }

    @inlinable
    nonisolated public func scale(_ scale: CGFloat, anchor: UnitPoint = .center) -> ScaledShape<Self> {
        self.scale(x: scale, y: scale, anchor: anchor)
    }
}

/// The trailing edge of a list row's separator: the row's trailing edge.
@available(OpenSwiftUI_v4_0, *)
extension HorizontalAlignment {
    public static let listRowSeparatorTrailing = HorizontalAlignment(_FinchListRowSeparatorTrailing.self)
}

enum _FinchListRowSeparatorTrailing: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat { context.width }
}

@available(OpenSwiftUI_v1_0, *)
extension Text {
    /// The text with an accessibility label (Finch's accessibility reads the text itself).
    public func accessibilityLabel(_ label: Text) -> Text {
        self
    }
}
