// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Scroll target behaviors choose where a scroll view settles after wheel input.

public import Foundation
public import SwiftUICore

@available(macOS 14.0, *)
public protocol ScrollTargetBehavior {
    typealias TargetContext = ScrollTargetBehaviorContext
    func updateTarget(_ target: inout ScrollTarget, context: TargetContext)

    @available(macOS 15.4, *)
    typealias Properties = ScrollTargetBehaviorProperties
    @available(macOS 15.4, *)
    typealias PropertiesContext = ScrollTargetBehaviorPropertiesContext

    @available(macOS 15.4, *)
    func properties(context: PropertiesContext) -> Properties
}

@available(macOS 15.4, *)
public struct ScrollTargetBehaviorProperties: Equatable, Sendable {
    public init() {}

    public static func == (lhs: Self, rhs: Self) -> Bool { true }
}

@available(macOS 15.4, *)
public struct ScrollTargetBehaviorPropertiesContext {
    public var environment: EnvironmentValues
    public var axes: Axis.Set

    package init(environment: EnvironmentValues, axes: Axis.Set) {
        self.environment = environment
        self.axes = axes
    }
}

@available(macOS 14.0, *)
@dynamicMemberLookup
public struct ScrollTargetBehaviorContext {
    public var originalTarget: ScrollTarget
    public var velocity: CGVector
    public var contentSize: CGSize
    public var containerSize: CGSize
    public var axes: Axis.Set
    package var targetRects: [CGRect]
    private var environment: EnvironmentValues

    package init(originalTarget: ScrollTarget, velocity: CGVector, contentSize: CGSize,
                 containerSize: CGSize, axes: Axis.Set, targetRects: [CGRect], environment: EnvironmentValues) {
        self.originalTarget = originalTarget
        self.velocity = velocity
        self.contentSize = contentSize
        self.containerSize = containerSize
        self.axes = axes
        self.targetRects = targetRects
        self.environment = environment
    }

    public subscript<Value>(dynamicMember keyPath: KeyPath<EnvironmentValues, Value>) -> Value {
        environment[keyPath: keyPath]
    }
}

@available(macOS 14.0, *)
extension ScrollTargetBehavior {
    @available(macOS 15.4, *)
    public func properties(context: PropertiesContext) -> Properties { .init() }
}

@available(macOS 14.0, *)
struct _FinchAnyScrollTargetBehavior {
    var update: (inout ScrollTarget, ScrollTargetBehaviorContext) -> Void

    init<Behavior: ScrollTargetBehavior>(_ behavior: Behavior) {
        update = behavior.updateTarget
    }
}

@available(macOS 14.0, *)
private struct _FinchScrollTargetBehaviorKey: EnvironmentKey {
    static var defaultValue: _FinchAnyScrollTargetBehavior? { nil }
}

@available(macOS 14.0, *)
extension EnvironmentValues {
    var _finchScrollTargetBehavior: _FinchAnyScrollTargetBehavior? {
        get { self[_FinchScrollTargetBehaviorKey.self] }
        set { self[_FinchScrollTargetBehaviorKey.self] = newValue }
    }
}

@available(macOS 14.0, *)
extension View {
    nonisolated public func scrollTargetBehavior(_ behavior: some ScrollTargetBehavior) -> some View {
        environment(\._finchScrollTargetBehavior, _FinchAnyScrollTargetBehavior(behavior))
    }
}

@available(macOS 14.0, *)
public struct PagingScrollTargetBehavior: ScrollTargetBehavior {
    public init() {}

    public func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let width = max(1, context.containerSize.width)
        let height = max(1, context.containerSize.height)
        let maxX = max(0, context.contentSize.width - width)
        let maxY = max(0, context.contentSize.height - height)
        if context.axes.contains(.horizontal) {
            let projected = target.rect.minX + context.velocity.dx
            target.rect.origin.x = min(max(0, (projected / width).rounded() * width), maxX)
        }
        if context.axes.contains(.vertical) {
            let projected = target.rect.minY + context.velocity.dy
            target.rect.origin.y = min(max(0, (projected / height).rounded() * height), maxY)
        }
    }
}

@available(macOS 14.0, *)
extension ScrollTargetBehavior where Self == PagingScrollTargetBehavior {
    public static var paging: PagingScrollTargetBehavior { .init() }
}

@available(macOS 14.0, *)
public struct ViewAlignedScrollTargetBehavior: ScrollTargetBehavior {
    public struct LimitBehavior: Equatable, Hashable, Sendable {
        private let value: UInt8
        private init(_ value: UInt8) { self.value = value }

        public static let automatic = Self(0)
        public static let always = Self(1)
        @available(macOS 15.0, *) public static let alwaysByFew = Self(2)
        @available(macOS 15.0, *) public static let alwaysByOne = Self(3)
        public static let never = Self(4)
    }

    private var limitBehavior: LimitBehavior
    private var anchor: UnitPoint?

    public init(limitBehavior: LimitBehavior = .automatic) {
        self.limitBehavior = limitBehavior
        anchor = nil
    }

    @available(macOS 26.0, *)
    public init(limitBehavior: LimitBehavior, anchor: UnitPoint?) {
        self.limitBehavior = limitBehavior
        self.anchor = anchor
    }

    @available(macOS 26.0, *)
    public init(anchor: UnitPoint?) {
        limitBehavior = .automatic
        self.anchor = anchor
    }

    public func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard limitBehavior != .never, !context.targetRects.isEmpty else { return }
        let vertical = context.axes.contains(.vertical)
        let proposed = vertical ? target.rect.minY : target.rect.minX
        guard let nearest = context.targetRects.min(by: { lhs, rhs in
            let lhsStart = vertical ? lhs.minY : lhs.minX
            let rhsStart = vertical ? rhs.minY : rhs.minX
            return abs(lhsStart - proposed) < abs(rhsStart - proposed)
        }) else { return }
        target.rect = nearest
        target.anchor = anchor ?? (vertical ? .top : .leading)
    }
}

@available(macOS 14.0, *)
extension ScrollTargetBehavior where Self == ViewAlignedScrollTargetBehavior {
    public static var viewAligned: ViewAlignedScrollTargetBehavior { .init() }

    public static func viewAligned(limitBehavior: ViewAlignedScrollTargetBehavior.LimitBehavior)
        -> ViewAlignedScrollTargetBehavior {
        .init(limitBehavior: limitBehavior)
    }

    @available(macOS 26.0, *)
    public static func viewAligned(anchor: UnitPoint?) -> ViewAlignedScrollTargetBehavior {
        .init(anchor: anchor)
    }

    @available(macOS 26.0, *)
    public static func viewAligned(limitBehavior: ViewAlignedScrollTargetBehavior.LimitBehavior,
                                   anchor: UnitPoint?) -> ViewAlignedScrollTargetBehavior {
        .init(limitBehavior: limitBehavior, anchor: anchor)
    }
}
