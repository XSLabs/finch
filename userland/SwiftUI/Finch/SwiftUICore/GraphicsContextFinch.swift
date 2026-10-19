// SPDX-License-Identifier: MIT OR Apache-2.0
//
// The color shading and path fill used by Canvas, drawn into its CoreGraphics context.

public import OpenCoreGraphicsShims

@available(OpenSwiftUI_v3_0, *)
extension GraphicsContext.Shading {
    public static func color(_ color: Color) -> GraphicsContext.Shading {
        GraphicsContext.Shading(_finchColor: color)
    }
}

@available(OpenSwiftUI_v3_0, *)
extension GraphicsContext {
    public func fill(_ path: Path, with shading: Shading, style: FillStyle = FillStyle()) {
        guard let cgContext = storage.cgContext,
              let color = shading.finchColor?.resolve(in: storage.environment).cgColor else { return }

        cgContext.saveGState()
        defer { cgContext.restoreGState() }
        cgContext.setShouldAntialias(style.isAntialiased)
        cgContext.setFillColor(color)
        cgContext.addPath(path.cgPath)
        cgContext.drawPath(using: style.isEOFilled ? .eoFill : .fill)
    }

    /// Draws the outline of a path with a color and the requested line style.
    public func stroke(_ path: Path, with shading: Shading, style: StrokeStyle = StrokeStyle()) {
        guard let cgContext = storage.cgContext,
              let color = shading.finchColor?.resolve(in: storage.environment).cgColor else { return }

        cgContext.saveGState()
        defer { cgContext.restoreGState() }
        cgContext.setStrokeColor(color)
        cgContext.setLineWidth(style.lineWidth)
        cgContext.setLineCap(style.lineCap)
        cgContext.setLineJoin(style.lineJoin)
        cgContext.setMiterLimit(style.miterLimit)
        cgContext.setLineDash(phase: style.dashPhase, lengths: style.dash)
        cgContext.addPath(path.cgPath)
        cgContext.strokePath()
    }

    /// Draws the outline of a path with a color and a fixed line width.
    public func stroke(_ path: Path, with shading: Shading, lineWidth: CGFloat) {
        stroke(path, with: shading, style: StrokeStyle(lineWidth: lineWidth))
    }
}
