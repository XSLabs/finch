// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Render a SwiftUI view into an AppKit bitmap for export or drawing.

public import AppKit
public import Combine
public import SwiftUICore

@available(macOS 13.0, *)
@MainActor
public final class ImageRenderer<Content>: ObservableObject where Content: View {
    public typealias ObjectWillChangePublisher = PassthroughSubject<Void, Never>

    public let objectWillChange = PassthroughSubject<Void, Never>()

    public var content: Content {
        didSet { objectWillChange.send() }
    }

    public var proposedSize = ProposedViewSize.unspecified {
        didSet { objectWillChange.send() }
    }

    public var scale: CGFloat = 1 {
        didSet { objectWillChange.send() }
    }

    public var isOpaque = false {
        didSet { objectWillChange.send() }
    }

    public var colorMode: ColorRenderingMode = .nonLinear {
        didSet { objectWillChange.send() }
    }

    private var dynamicRange: Any?

    @available(macOS 26.0, *)
    public var allowedDynamicRange: Image.DynamicRange? {
        get { dynamicRange as? Image.DynamicRange }
        set {
            dynamicRange = newValue
            objectWillChange.send()
        }
    }

    public init(content: Content) {
        self.content = content
    }

    public var cgImage: CGImage? {
        makeBitmap(scale: scale)
    }

    @available(macOS 13.0, *)
    public func render(
        rasterizationScale: CGFloat = 1,
        renderer: (CGSize, (CGContext) -> Void) -> Void
    ) {
        let outputScale = scale * rasterizationScale
        guard rasterizationScale.isFinite, rasterizationScale > 0,
              outputScale.isFinite, outputScale > 0,
              let image = makeBitmap(scale: outputScale) else { return }

        let imageSize = CGSize(width: CGFloat(image.width) / outputScale,
                               height: CGFloat(image.height) / outputScale)
        renderer(imageSize) { context in
            context.draw(image, in: CGRect(origin: .zero, size: imageSize))
        }
    }

    public var nsImage: NSImage? {
        guard let image = cgImage, scale.isFinite, scale > 0 else { return nil }
        return NSImage(cgImage: image, size: CGSize(width: CGFloat(image.width) / scale,
                                                    height: CGFloat(image.height) / scale))
    }

    private func makeBitmap(scale: CGFloat) -> CGImage? {
        guard scale.isFinite, scale > 0 else { return nil }

        let root: AnyView
        if #available(macOS 26.0, *), let range = dynamicRange as? Image.DynamicRange {
            root = AnyView(AnyView(content).environment(\.allowedDynamicRange, range))
        } else {
            root = AnyView(content)
        }

        let hostingView = NSHostingView(rootView: root)
        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        let size = CGSize(width: max(0, proposedSize.width ?? fittingSize.width),
                          height: max(0, proposedSize.height ?? fittingSize.height))
        guard size.width > 0, size.height > 0 else { return nil }

        hostingView.setFrameSize(size)
        hostingView.layoutSubtreeIfNeeded()
        let pixelsWide = max(1, Int(ceil(size.width * scale)))
        let pixelsHigh = max(1, Int(ceil(size.height * scale)))
        let colorSpaceName: CFString
        switch colorMode {
        case .nonLinear: colorSpaceName = CGColorSpace.sRGB
        case .linear: colorSpaceName = CGColorSpace.linearSRGB
        case .extendedLinear: colorSpaceName = CGColorSpace.extendedLinearSRGB
        }
        guard let colorSpace = CGColorSpace(name: colorSpaceName) else { return nil }
        let usesExtendedRange: Bool
        switch colorMode {
        case .nonLinear, .linear: usesExtendedRange = false
        case .extendedLinear: usesExtendedRange = true
        }
        let bitsPerComponent = usesExtendedRange ? 16 : 8
        var bitmapInfo = isOpaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        if usesExtendedRange {
            bitmapInfo |= CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        }
        guard let context = CGContext(data: nil,
                                      width: pixelsWide,
                                      height: pixelsHigh,
                                      bitsPerComponent: bitsPerComponent,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: bitmapInfo) else { return nil }

        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        context.scaleBy(x: scale, y: scale)
        hostingView.displayIgnoringOpacity(hostingView.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
