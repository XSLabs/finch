// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Shape transforms and path combinations that Apple's SwiftUI exposes from macOS 15.

public import OpenCoreGraphicsShims

@available(OpenSwiftUI_v1_0, *)
@_originallyDefinedIn(module: "SwiftUI", macOS 15.0)
@frozen
public struct TransformedShape<Content>: Shape where Content: Shape {
    public var shape: Content
    public var transform: CGAffineTransform

    @inlinable
    public init(shape: Content, transform: CGAffineTransform) {
        self.shape = shape
        self.transform = transform
    }

    nonisolated public func path(in rect: CGRect) -> Path {
        shape.path(in: rect).applying(transform)
    }

    nonisolated public static var role: ShapeRole { Content.role }
    nonisolated public var layoutDirectionBehavior: LayoutDirectionBehavior { shape.layoutDirectionBehavior }

    public typealias AnimatableData = Content.AnimatableData

    public var animatableData: AnimatableData {
        get { shape.animatableData }
        set { shape.animatableData = newValue }
    }
}

@available(OpenSwiftUI_v1_0, *)
@_originallyDefinedIn(module: "SwiftUI", macOS 15.0)
@frozen
public struct _SizedShape<Content>: Shape where Content: Shape {
    public var shape: Content
    public var size: CGSize

    @inlinable
    public init(shape: Content, size: CGSize) {
        self.shape = shape
        self.size = size
    }

    nonisolated public func path(in rect: CGRect) -> Path {
        let origin = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        return shape.path(in: CGRect(origin: origin, size: size))
    }

    nonisolated public func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize { size }
    nonisolated public static var role: ShapeRole { Content.role }
    nonisolated public var layoutDirectionBehavior: LayoutDirectionBehavior { shape.layoutDirectionBehavior }

    public typealias AnimatableData = AnimatablePair<Content.AnimatableData, CGSize.AnimatableData>

    public var animatableData: AnimatableData {
        get { AnimatablePair(shape.animatableData, size.animatableData) }
        set {
            shape.animatableData = newValue.first
            size.animatableData = newValue.second
        }
    }
}

@available(OpenSwiftUI_v6_0, *)
struct _AnchoredSizedShape<Content: Shape>: Shape {
    var shape: Content
    var size: CGSize
    var anchor: UnitPoint

    nonisolated func path(in rect: CGRect) -> Path {
        let origin = CGPoint(x: rect.minX + (rect.width - size.width) * anchor.x,
                             y: rect.minY + (rect.height - size.height) * anchor.y)
        return shape.path(in: CGRect(origin: origin, size: size))
    }

    nonisolated func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize { size }
    nonisolated static var role: ShapeRole { Content.role }
    nonisolated var layoutDirectionBehavior: LayoutDirectionBehavior { shape.layoutDirectionBehavior }

    typealias AnimatableData = AnimatablePair<Content.AnimatableData, AnimatablePair<CGSize.AnimatableData, UnitPoint.AnimatableData>>

    var animatableData: AnimatableData {
        get { AnimatablePair(shape.animatableData, AnimatablePair(size.animatableData, anchor.animatableData)) }
        set {
            shape.animatableData = newValue.first
            size.animatableData = newValue.second.first
            anchor.animatableData = newValue.second.second
        }
    }
}

@available(OpenSwiftUI_v5_0, *)
@_originallyDefinedIn(module: "SwiftUI", macOS 15.0)
extension Shape {
    @inlinable
    nonisolated public func intersection<Other: Shape>(_ other: Other, eoFill: Bool = false) -> some Shape {
        _ShapeIntersection(self, other, eoFill: eoFill)
    }

    @inlinable
    nonisolated public func union<Other: Shape>(_ other: Other, eoFill: Bool = false) -> some Shape {
        _ShapeUnion(self, other, eoFill: eoFill)
    }

    @inlinable
    nonisolated public func subtracting<Other: Shape>(_ other: Other, eoFill: Bool = false) -> some Shape {
        _ShapeSubtraction(self, other, eoFill: eoFill)
    }

    @inlinable
    nonisolated public func symmetricDifference<Other: Shape>(_ other: Other, eoFill: Bool = false) -> some Shape {
        _ShapeSymmetricDifference(self, other, eoFill: eoFill)
    }
}

@available(OpenSwiftUI_v5_0, *)
@_originallyDefinedIn(module: "SwiftUI", macOS 15.0)
@frozen
public struct _ShapeIntersection<Left, Right>: Shape where Left: Shape, Right: Shape {
    @usableFromInline internal var lhs: Left
    @usableFromInline internal var rhs: Right
    @usableFromInline internal var eoFill: Bool

    @_alwaysEmitIntoClient
    @usableFromInline
    internal init(_ lhs: Left, _ rhs: Right, eoFill: Bool) {
        self.lhs = lhs
        self.rhs = rhs
        self.eoFill = eoFill
    }

    nonisolated public func path(in rect: CGRect) -> Path { lhs.path(in: rect).intersection(rhs.path(in: rect), eoFill: eoFill) }
    nonisolated public func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize { lhs.sizeThatFits(proposal) }
    public typealias AnimatableData = AnimatablePair<Left.AnimatableData, Right.AnimatableData>
    public var animatableData: AnimatableData {
        get { AnimatablePair(lhs.animatableData, rhs.animatableData) }
        set { lhs.animatableData = newValue.first; rhs.animatableData = newValue.second }
    }
}

@available(OpenSwiftUI_v5_0, *)
@_originallyDefinedIn(module: "SwiftUI", macOS 15.0)
@frozen
public struct _ShapeUnion<Left, Right>: Shape where Left: Shape, Right: Shape {
    @usableFromInline internal var lhs: Left
    @usableFromInline internal var rhs: Right
    @usableFromInline internal var eoFill: Bool

    @_alwaysEmitIntoClient
    @usableFromInline
    internal init(_ lhs: Left, _ rhs: Right, eoFill: Bool) {
        self.lhs = lhs
        self.rhs = rhs
        self.eoFill = eoFill
    }

    nonisolated public func path(in rect: CGRect) -> Path { lhs.path(in: rect).union(rhs.path(in: rect), eoFill: eoFill) }
    nonisolated public func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize { lhs.sizeThatFits(proposal) }
    public typealias AnimatableData = AnimatablePair<Left.AnimatableData, Right.AnimatableData>
    public var animatableData: AnimatableData {
        get { AnimatablePair(lhs.animatableData, rhs.animatableData) }
        set { lhs.animatableData = newValue.first; rhs.animatableData = newValue.second }
    }
}

@available(OpenSwiftUI_v5_0, *)
@_originallyDefinedIn(module: "SwiftUI", macOS 15.0)
@frozen
public struct _ShapeSubtraction<Left, Right>: Shape where Left: Shape, Right: Shape {
    @usableFromInline internal var lhs: Left
    @usableFromInline internal var rhs: Right
    @usableFromInline internal var eoFill: Bool

    @_alwaysEmitIntoClient
    @usableFromInline
    internal init(_ lhs: Left, _ rhs: Right, eoFill: Bool) {
        self.lhs = lhs
        self.rhs = rhs
        self.eoFill = eoFill
    }

    nonisolated public func path(in rect: CGRect) -> Path { lhs.path(in: rect).subtracting(rhs.path(in: rect), eoFill: eoFill) }
    nonisolated public func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize { lhs.sizeThatFits(proposal) }
    public typealias AnimatableData = AnimatablePair<Left.AnimatableData, Right.AnimatableData>
    public var animatableData: AnimatableData {
        get { AnimatablePair(lhs.animatableData, rhs.animatableData) }
        set { lhs.animatableData = newValue.first; rhs.animatableData = newValue.second }
    }
}

@available(OpenSwiftUI_v5_0, *)
@_originallyDefinedIn(module: "SwiftUI", macOS 15.0)
@frozen
public struct _ShapeSymmetricDifference<Left, Right>: Shape where Left: Shape, Right: Shape {
    @usableFromInline internal var lhs: Left
    @usableFromInline internal var rhs: Right
    @usableFromInline internal var eoFill: Bool

    @_alwaysEmitIntoClient
    @usableFromInline
    internal init(_ lhs: Left, _ rhs: Right, eoFill: Bool) {
        self.lhs = lhs
        self.rhs = rhs
        self.eoFill = eoFill
    }

    nonisolated public func path(in rect: CGRect) -> Path { lhs.path(in: rect).symmetricDifference(rhs.path(in: rect), eoFill: eoFill) }
    nonisolated public func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize { lhs.sizeThatFits(proposal) }
    public typealias AnimatableData = AnimatablePair<Left.AnimatableData, Right.AnimatableData>
    public var animatableData: AnimatableData {
        get { AnimatablePair(lhs.animatableData, rhs.animatableData) }
        set { lhs.animatableData = newValue.first; rhs.animatableData = newValue.second }
    }
}
