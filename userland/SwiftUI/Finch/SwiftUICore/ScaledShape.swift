// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ScaledShape (Shape.scale), to Apple's interface: a shape's path scaled about an anchor in
// its rect.

public import OpenCoreGraphicsShims

@available(OpenSwiftUI_v1_0, *)
@_originallyDefinedIn(module: "SwiftUI", macOS 15.0)
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
@_originallyDefinedIn(module: "SwiftUI", macOS 15.0)
extension Shape {
    @inlinable
    nonisolated public func scale(x: CGFloat = 1, y: CGFloat = 1, anchor: UnitPoint = .center) -> ScaledShape<Self> {
        ScaledShape(shape: self, scale: CGSize(width: x, height: y), anchor: anchor)
    }

    @inlinable
    nonisolated public func scale(_ scale: CGFloat, anchor: UnitPoint = .center) -> ScaledShape<Self> {
        self.scale(x: scale, y: scale, anchor: anchor)
    }

    /// Returns this shape moved by the given amount.
    @inlinable
    nonisolated public func offset(_ offset: CGSize) -> OffsetShape<Self> {
        OffsetShape(shape: self, offset: offset)
    }

    @inlinable
    nonisolated public func offset(_ offset: CGPoint) -> OffsetShape<Self> {
        OffsetShape(shape: self, offset: CGSize(width: offset.x, height: offset.y))
    }

    /// Returns this shape moved horizontally and vertically.
    @inlinable
    nonisolated public func offset(x: CGFloat = 0, y: CGFloat = 0) -> OffsetShape<Self> {
        offset(CGSize(width: x, height: y))
    }

    @inlinable
    nonisolated public func transform(_ transform: CGAffineTransform) -> TransformedShape<Self> {
        TransformedShape(shape: self, transform: transform)
    }

    @inlinable
    nonisolated public func size(_ size: CGSize) -> some Shape {
        _SizedShape(shape: self, size: size)
    }

    @inlinable
    nonisolated public func size(width: CGFloat, height: CGFloat) -> some Shape {
        size(CGSize(width: width, height: height))
    }

    @available(OpenSwiftUI_v6_0, *)
    nonisolated public func size(_ size: CGSize, anchor: UnitPoint) -> some Shape {
        _AnchoredSizedShape(shape: self, size: size, anchor: anchor)
    }

    @available(OpenSwiftUI_v6_0, *)
    nonisolated public func size(width: CGFloat, height: CGFloat, anchor: UnitPoint) -> some Shape {
        size(CGSize(width: width, height: height), anchor: anchor)
    }

    /// Returns this shape turned around an anchor point.
    @inlinable
    nonisolated public func rotation(_ angle: Angle, anchor: UnitPoint = .center) -> RotatedShape<Self> {
        RotatedShape(shape: self, angle: angle, anchor: anchor)
    }
}

/// A shape whose path is moved by a fixed amount.
@available(OpenSwiftUI_v1_0, *)
@_originallyDefinedIn(module: "SwiftUI", macOS 15.0)
@frozen
public struct OffsetShape<Content>: Shape where Content: Shape {
    public var shape: Content
    public var offset: CGSize

    @inlinable
    public init(shape: Content, offset: CGSize) {
        self.shape = shape
        self.offset = offset
    }

    nonisolated public func path(in rect: CGRect) -> Path {
        shape.path(in: rect).applying(CGAffineTransform(translationX: offset.width, y: offset.height))
    }

    nonisolated public static var role: ShapeRole { Content.role }
    nonisolated public var layoutDirectionBehavior: LayoutDirectionBehavior { shape.layoutDirectionBehavior }

    public typealias AnimatableData = AnimatablePair<Content.AnimatableData, CGSize.AnimatableData>

    public var animatableData: AnimatableData {
        get { AnimatablePair(shape.animatableData, offset.animatableData) }
        set {
            shape.animatableData = newValue.first
            offset.animatableData = newValue.second
        }
    }
}

/// A shape whose path is turned around an anchor point.
@available(OpenSwiftUI_v1_0, *)
@_originallyDefinedIn(module: "SwiftUI", macOS 15.0)
@frozen
public struct RotatedShape<Content>: Shape where Content: Shape {
    public var shape: Content
    public var angle: Angle
    public var anchor: UnitPoint

    @inlinable
    public init(shape: Content, angle: Angle, anchor: UnitPoint = .center) {
        self.shape = shape
        self.angle = angle
        self.anchor = anchor
    }

    nonisolated public func path(in rect: CGRect) -> Path {
        let x = rect.minX + rect.width * anchor.x
        let y = rect.minY + rect.height * anchor.y
        let transform = CGAffineTransform(translationX: x, y: y)
            .rotated(by: angle.radians)
            .translatedBy(x: -x, y: -y)
        return shape.path(in: rect).applying(transform)
    }

    nonisolated public static var role: ShapeRole { Content.role }
    nonisolated public var layoutDirectionBehavior: LayoutDirectionBehavior { shape.layoutDirectionBehavior }

    public typealias AnimatableData = AnimatablePair<Content.AnimatableData, AnimatablePair<Angle.AnimatableData, UnitPoint.AnimatableData>>

    public var animatableData: AnimatableData {
        get { AnimatablePair(shape.animatableData, AnimatablePair(angle.animatableData, anchor.animatableData)) }
        set {
            shape.animatableData = newValue.first
            angle.animatableData = newValue.second.first
            anchor.animatableData = newValue.second.second
        }
    }
}

@available(OpenSwiftUI_v1_0, *)
@_originallyDefinedIn(module: "SwiftUI", macOS 15.0)
extension OffsetShape: InsettableShape where Content: InsettableShape {
    public typealias InsetShape = OffsetShape<Content.InsetShape>

    public func inset(by amount: CGFloat) -> InsetShape {
        InsetShape(shape: shape.inset(by: amount), offset: offset)
    }
}

@available(OpenSwiftUI_v1_0, *)
@_originallyDefinedIn(module: "SwiftUI", macOS 15.0)
extension RotatedShape: InsettableShape where Content: InsettableShape {
    public typealias InsetShape = RotatedShape<Content.InsetShape>

    public func inset(by amount: CGFloat) -> InsetShape {
        InsetShape(shape: shape.inset(by: amount), angle: angle, anchor: anchor)
    }
}

/// The trailing edge of a list row's separator: the row's trailing edge.
@available(OpenSwiftUI_v4_0, *)
extension HorizontalAlignment {
    public static let listRowSeparatorLeading = HorizontalAlignment(_FinchListRowSeparatorLeading.self)
    public static let listRowSeparatorTrailing = HorizontalAlignment(_FinchListRowSeparatorTrailing.self)
}

enum _FinchListRowSeparatorLeading: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat { 0 }
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
