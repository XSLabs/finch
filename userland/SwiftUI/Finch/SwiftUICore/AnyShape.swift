// SPDX-License-Identifier: MIT OR Apache-2.0
//
// AnyShape, with copy-on-write storage for the wrapped shape.

public import Foundation

@available(macOS 13.0, *)
@usableFromInline
internal class AnyShapeBox {
    func copy() -> AnyShapeBox {
        _openSwiftUIBaseClassAbstractMethod()
    }

    func path(in rect: CGRect) -> Path {
        _openSwiftUIBaseClassAbstractMethod()
    }

    var animatableData: _AnyAnimatableData {
        get { _openSwiftUIBaseClassAbstractMethod() }
        set { _openSwiftUIBaseClassAbstractMethod() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize {
        _openSwiftUIBaseClassAbstractMethod()
    }
}

@available(macOS 13.0, *)
private final class _ConcreteAnyShapeBox<S: Shape>: AnyShapeBox {
    var shape: S

    init(shape: S) {
        self.shape = shape
    }

    override func copy() -> AnyShapeBox {
        _ConcreteAnyShapeBox(shape: shape)
    }

    override func path(in rect: CGRect) -> Path {
        shape.path(in: rect)
    }

    override var animatableData: _AnyAnimatableData {
        get { _AnyAnimatableData(shape) }
        set { newValue.update(&shape) }
    }

    override func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize {
        shape.sizeThatFits(proposal)
    }
}

@available(macOS 13.0, *)
@_originallyDefinedIn(module: "SwiftUI", macOS 15.0)
@frozen
public struct AnyShape: Shape, @unchecked Sendable {
    @usableFromInline
    internal var storage: AnyShapeBox

    public init<S>(_ shape: S) where S: Shape {
        storage = _ConcreteAnyShapeBox(shape: shape)
    }

    nonisolated public func path(in rect: CGRect) -> Path {
        storage.path(in: rect)
    }

    nonisolated public func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize {
        storage.sizeThatFits(proposal)
    }

    public typealias AnimatableData = _AnyAnimatableData

    public var animatableData: AnimatableData {
        get { storage.animatableData }
        set {
            if !isKnownUniquelyReferenced(&storage) {
                storage = storage.copy()
            }
            storage.animatableData = newValue
        }
    }

    public typealias Body = _ShapeView<AnyShape, ForegroundStyle>
}
