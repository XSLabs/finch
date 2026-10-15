// SPDX-License-Identifier: MIT OR Apache-2.0
//
// The color shading and path fill used by Canvas, drawn into its CoreGraphics context.

import OpenCoreGraphicsShims

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
}
