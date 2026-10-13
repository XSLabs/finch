// SPDX-License-Identifier: MIT OR Apache-2.0
//
// GraphicsContext over CoreGraphics, text renderers, the brightness effect, drawing groups,
// symbols' variable-value mode, and rounded rectangular shapes, to Apple's interface. A
// GraphicsContext made for a canvas (Finch/SwiftUI/Canvas.swift) hands out the CoreGraphics
// context it draws into (withCGContext). A text renderer is kept but the text draws as it
// would without one. A drawing group is the view itself (Finch already draws views through
// CoreGraphics).

public import Foundation
import OpenAttributeGraphShims
public import OpenCoreGraphicsShims

// MARK: - GraphicsContext over CoreGraphics

@available(OpenSwiftUI_v3_0, *)
extension GraphicsContext {
    /// A context drawing into `cgContext`, with the view's environment (Canvas's, in SwiftUI).
    package init(_finchCGContext cgContext: CGContext, environment: EnvironmentValues) {
        self.init(storage: Storage(cgContext: cgContext, environment: environment))
    }

    public func withCGContext(content: (CGContext) throws -> Void) rethrows {
        guard let cg = storage.cgContext else { return }
        cg.saveGState()
        defer { cg.restoreGState() }
        try content(cg)
    }

    public mutating func scaleBy(x: CGFloat, y: CGFloat) {
        storage.cgContext?.scaleBy(x: x, y: y)
    }

    public mutating func rotate(by angle: Angle) {
        storage.cgContext?.rotate(by: CGFloat(angle.radians))
    }

    public mutating func concatenate(_ matrix: CGAffineTransform) {
        storage.cgContext?.concatenate(matrix)
    }

    /// A line of laid-out text (from a text renderer): Finch's text renderers aren't given
    /// layouts yet, so there's nothing to draw.
    public func draw(_ line: Text.Layout.Line, options: Text.Layout.DrawingOptions = .init()) {}
}

// MARK: - Text renderers

@available(OpenSwiftUI_v5_0, *)
public protocol TextRenderer: Animatable {
    func draw(layout: Text.Layout, in ctx: inout GraphicsContext)

    @available(OpenSwiftUI_v6_0, *)
    func sizeThatFits(proposal: ProposedViewSize, text: TextProxy) -> CGSize

    @available(OpenSwiftUI_v6_0, *)
    var displayPadding: EdgeInsets { get }
}

@available(OpenSwiftUI_v5_0, *)
extension TextRenderer {
    @available(OpenSwiftUI_v6_0, *)
    public func sizeThatFits(proposal: ProposedViewSize, text: TextProxy) -> CGSize {
        text.sizeThatFits(proposal)
    }

    @available(OpenSwiftUI_v6_0, *)
    public var displayPadding: EdgeInsets { EdgeInsets() }
}

@available(OpenSwiftUI_v5_0, *)
@frozen
public struct _TextRendererViewModifier<Renderer> where Renderer: TextRenderer {
    @usableFromInline
    var renderer: Renderer

    @_alwaysEmitIntoClient
    init(renderer: Renderer) {
        self.renderer = renderer
    }

    public typealias Body = Never
}

/// The text draws as it would without the renderer (Finch doesn't hand renderers layouts yet).
@available(OpenSwiftUI_v5_0, *)
extension _TextRendererViewModifier: ViewModifier, PrimitiveViewModifier {
    nonisolated public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs,
                                             body: @escaping (_Graph, _ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        body(_Graph(), inputs)
    }

    nonisolated public static func _makeViewList(modifier: _GraphValue<Self>, inputs: _ViewListInputs,
                                                 body: @escaping (_Graph, _ViewListInputs) -> _ViewListOutputs) -> _ViewListOutputs {
        body(_Graph(), inputs)
    }
}

@available(OpenSwiftUI_v5_0, *)
extension View {
    @_alwaysEmitIntoClient
    nonisolated public func textRenderer<T>(_ renderer: T) -> some View where T: TextRenderer {
        modifier(_TextRendererViewModifier(renderer: renderer))
    }
}

// MARK: - Brightness and drawing groups

@available(OpenSwiftUI_v1_0, *)
@frozen
public struct _BrightnessEffect: Equatable {
    public var amount: Double

    @inlinable
    nonisolated public init(amount: Double) {
        self.amount = amount
    }

    public var animatableData: Double {
        get { amount }
        set { amount = newValue }
    }

    public static func == (a: _BrightnessEffect, b: _BrightnessEffect) -> Bool { a.amount == b.amount }

    public typealias AnimatableData = Double
    public typealias Body = Never
}

/// Brightening or darkening: an overlay of white or black, as much as the amount, blended
/// over the content's own pixels only.
@available(OpenSwiftUI_v1_0, *)
extension _BrightnessEffect: ViewModifier {
    public func body(content: Content) -> some View {
        content.overlay(
            (amount >= 0 ? Color.white : Color.black)
                .opacity(min(abs(amount), 1))
                .allowsHitTesting(false)
        )
    }
}

@available(OpenSwiftUI_v1_0, *)
extension View {
    @inlinable
    nonisolated public func brightness(_ amount: Double) -> some View {
        modifier(_BrightnessEffect(amount: amount))
    }

    nonisolated public func drawingGroup(opaque: Bool = false, colorMode: ColorRenderingMode = .nonLinear) -> some View {
        self
    }
}

// MARK: - Symbols' variable values

@available(OpenSwiftUI_v7_0, *)
public struct SymbolVariableValueMode: Equatable, Sendable {
    let isDraw: Bool
    public static let color = SymbolVariableValueMode(isDraw: false)
    public static let draw = SymbolVariableValueMode(isDraw: true)
    public static func == (a: SymbolVariableValueMode, b: SymbolVariableValueMode) -> Bool { a.isDraw == b.isDraw }
}

// MARK: - Rounded rectangular shapes

@available(OpenSwiftUI_v7_0, *)
extension Edge {
    /// A rectangle's corner.
    public enum Corner: Int8, CaseIterable, Hashable, Sendable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        /// A corner's rounding: a fixed radius, or concentric with its container's.
        public struct Style: Sendable, Hashable, Animatable {
            var radius: CGFloat
            var isConcentric: Bool
            var minimum: CGFloat?

            public static func fixed(_ radius: CGFloat) -> Style { Style(radius: radius, isConcentric: false, minimum: nil) }
            public static var concentric: Style { Style(radius: 0, isConcentric: true, minimum: nil) }
            public static func concentric(minimum: Style? = nil) -> Style {
                Style(radius: minimum?.radius ?? 0, isConcentric: true, minimum: minimum?.radius)
            }

            public var animatableData: AnimatableData {
                get { AnimatableData(radius: Double(radius)) }
                set { radius = CGFloat(newValue.radius) }
            }

            public struct AnimatableData: VectorArithmetic, Sendable {
                var radius: Double
                public static func - (lhs: AnimatableData, rhs: AnimatableData) -> AnimatableData { AnimatableData(radius: lhs.radius - rhs.radius) }
                public static func + (lhs: AnimatableData, rhs: AnimatableData) -> AnimatableData { AnimatableData(radius: lhs.radius + rhs.radius) }
                public mutating func scale(by rhs: Double) { radius *= rhs }
                public var magnitudeSquared: Double { radius * radius }
                public static var zero: AnimatableData { AnimatableData(radius: 0) }
            }
        }
    }
}

@available(OpenSwiftUI_v7_0, *)
extension Edge.Corner.Style: ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral {
    public typealias FloatLiteralType = Float
    public typealias IntegerLiteralType = Int
    public init(floatLiteral value: Float) { self = .fixed(CGFloat(value)) }
    public init(integerLiteral value: Int) { self = .fixed(CGFloat(value)) }
}

@available(OpenSwiftUI_v7_0, *)
public struct RoundedRectangularShapeCorners: Sendable, Hashable, Animatable {
    public var topLeading: Edge.Corner.Style
    public var bottomLeading: Edge.Corner.Style
    public var topTrailing: Edge.Corner.Style
    public var bottomTrailing: Edge.Corner.Style

    public init(topLeading: Edge.Corner.Style = 0, topTrailing: Edge.Corner.Style = 0, bottomLeading: Edge.Corner.Style = 0,
                bottomTrailing: Edge.Corner.Style = 0) {
        self.topLeading = topLeading
        self.topTrailing = topTrailing
        self.bottomLeading = bottomLeading
        self.bottomTrailing = bottomTrailing
    }

    public init(all: Edge.Corner.Style) {
        self.init(topLeading: all, topTrailing: all, bottomLeading: all, bottomTrailing: all)
    }

    public static func fixed(_ radius: CGFloat) -> RoundedRectangularShapeCorners { .init(all: .fixed(radius)) }
    public static var concentric: RoundedRectangularShapeCorners { .init(all: .concentric) }
    public static func concentric(minimum: Edge.Corner.Style? = nil) -> RoundedRectangularShapeCorners {
        .init(all: .concentric(minimum: minimum))
    }

    public subscript(corner: Edge.Corner) -> Edge.Corner.Style {
        switch corner {
        case .topLeading: topLeading
        case .topTrailing: topTrailing
        case .bottomLeading: bottomLeading
        case .bottomTrailing: bottomTrailing
        }
    }

    public var animatableData: AnimatableData {
        get { AnimatableData(values: [topLeading.radius, topTrailing.radius, bottomLeading.radius, bottomTrailing.radius].map(Double.init)) }
        set {
            guard newValue.values.count == 4 else { return }
            topLeading.radius = CGFloat(newValue.values[0])
            topTrailing.radius = CGFloat(newValue.values[1])
            bottomLeading.radius = CGFloat(newValue.values[2])
            bottomTrailing.radius = CGFloat(newValue.values[3])
        }
    }

    public struct AnimatableData: Equatable, VectorArithmetic, Sendable {
        var values: [Double]
        public mutating func scale(by rhs: Double) { values = values.map { $0 * rhs } }
        public var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
        public static var zero: AnimatableData { AnimatableData(values: [0, 0, 0, 0]) }
        private static func combine(_ a: AnimatableData, _ b: AnimatableData, _ f: (Double, Double) -> Double) -> AnimatableData {
            let n = max(a.values.count, b.values.count)
            return AnimatableData(values: (0 ..< n).map { f($0 < a.values.count ? a.values[$0] : 0, $0 < b.values.count ? b.values[$0] : 0) })
        }
        public static func + (lhs: AnimatableData, rhs: AnimatableData) -> AnimatableData { combine(lhs, rhs, +) }
        public static func - (lhs: AnimatableData, rhs: AnimatableData) -> AnimatableData { combine(lhs, rhs, -) }
    }
}

@available(OpenSwiftUI_v7_0, *)
public protocol RoundedRectangularShape: InsettableShape {
    typealias Corners = RoundedRectangularShapeCorners
    func corners(in size: CGSize?) -> Self.Corners?
}

@available(OpenSwiftUI_v7_0, *)
extension Rectangle: RoundedRectangularShape {
    public func corners(in size: CGSize?) -> RoundedRectangularShapeCorners? { .init(all: 0) }
}

@available(OpenSwiftUI_v7_0, *)
public struct _ContainerRoundedRectangularShapeModifier<Shape> where Shape: RoundedRectangularShape {
    public var shape: Shape

    public init(shape: Shape) {
        self.shape = shape
    }

    public typealias Body = Never
}

/// The container's shape, for the views inside to be concentric with: Finch doesn't round
/// to containers yet, so the content is as it is.
@available(OpenSwiftUI_v7_0, *)
extension _ContainerRoundedRectangularShapeModifier: ViewModifier, PrimitiveViewModifier {
    nonisolated public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs,
                                             body: @escaping (_Graph, _ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        body(_Graph(), inputs)
    }
}
