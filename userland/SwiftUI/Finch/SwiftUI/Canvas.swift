// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Canvas, to Apple's interface: an AppKit view whose drawing runs the canvas's renderer in
// the view's CoreGraphics context (flipped to SwiftUI's top-left origin), through a
// GraphicsContext over that context (Finch/SwiftUICore/Canvas.swift). Symbols aren't drawn.

public import AppKit
import OpenAttributeGraphShims
@_spi(ForOpenSwiftUIOnly)
import SwiftUICore

@available(OpenSwiftUI_v3_0, *)
public struct Canvas<Symbols> where Symbols: View {
    public var symbols: Symbols
    public var renderer: (inout GraphicsContext, CGSize) -> Void
    public var isOpaque: Bool
    public var colorMode: ColorRenderingMode
    public var rendersAsynchronously: Bool

    public init(opaque: Bool = false, colorMode: ColorRenderingMode = .nonLinear, rendersAsynchronously: Bool = false,
                renderer: @escaping (inout GraphicsContext, CGSize) -> Void, @ViewBuilder symbols: () -> Symbols) {
        self.symbols = symbols()
        self.renderer = renderer
        isOpaque = opaque
        self.colorMode = colorMode
        self.rendersAsynchronously = rendersAsynchronously
    }

    nonisolated public static func _makeView(view: _GraphValue<Canvas<Symbols>>, inputs: _ViewInputs) -> _ViewOutputs {
        _FinchCanvasView._makeView(view: _GraphValue(Child(canvas: view.value)), inputs: inputs)
    }

    public typealias Body = Never

    private struct Child: Rule {
        @Attribute var canvas: Canvas<Symbols>
        var value: _FinchCanvasView {
            let canvas = canvas
            return _FinchCanvasView(isOpaque: canvas.isOpaque, renderer: canvas.renderer)
        }
    }
}

@available(OpenSwiftUI_v3_0, *)
extension Canvas: View, UnaryView, PrimitiveView {}

@available(OpenSwiftUI_v3_0, *)
extension Canvas where Symbols == EmptyView {
    public init(opaque: Bool = false, colorMode: ColorRenderingMode = .nonLinear, rendersAsynchronously: Bool = false,
                renderer: @escaping (inout GraphicsContext, CGSize) -> Void) {
        self.init(opaque: opaque, colorMode: colorMode, rendersAsynchronously: rendersAsynchronously, renderer: renderer) { EmptyView() }
    }
}

@available(*, unavailable) extension Canvas: Sendable {}

/// The canvas's drawing: an AppKit view whose draw(_:) runs the renderer in the view's
/// CoreGraphics context, flipped to SwiftUI's top-left origin.
struct _FinchCanvasView: View {
    var isOpaque: Bool
    var renderer: (inout GraphicsContext, CGSize) -> Void
    @Environment(\.self) private var environment

    var body: some View {
        _FinchCanvasRepresentable(isOpaque: isOpaque, renderer: renderer, environment: environment)
    }
}

struct _FinchCanvasRepresentable: NSViewRepresentable {
    var isOpaque: Bool
    var renderer: (inout GraphicsContext, CGSize) -> Void
    var environment: EnvironmentValues

    func makeNSView(context: Context) -> _FinchCanvasNSView { _FinchCanvasNSView() }

    func updateNSView(_ view: _FinchCanvasNSView, context: Context) {
        view.renderer = renderer
        view.environment = environment
        view.drawsOpaque = isOpaque
        view.needsDisplay = true
    }
}

final class _FinchCanvasNSView: NSView {
    var renderer: ((inout GraphicsContext, CGSize) -> Void)?
    var environment = EnvironmentValues()
    var drawsOpaque = false

    override var isFlipped: Bool { true }
    override var isOpaque: Bool {
        get { drawsOpaque }
        set { drawsOpaque = newValue }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let renderer, let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState()
        defer { cg.restoreGState() }
        var context = GraphicsContext(_finchCGContext: cg, environment: environment)
        renderer(&context, bounds.size)
    }
}

