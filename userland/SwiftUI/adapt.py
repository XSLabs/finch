#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Adapt a copy of the OpenSwiftUI package so its modules are Apple's: OpenSwiftUI becomes SwiftUI,
OpenSwiftUICore becomes SwiftUICore (with SwiftUI's ABI name, as Apple's SwiftUICore has), so the
symbols are $s7SwiftUI... as apps import them. Its other modules keep their names.
    adapt.py PACKAGE-DIR
"""
import os
import re
import shutil
import sys

# not file names (OpenSwiftUI+NSView.h) or SPI groups the dependencies declare (@_spi(OpenSwiftUI))
MODULE = re.compile(r'(?<!@_spi\()\bOpenSwiftUI(Core)?\b(?!\+)')


# upstream files that Finch's sources replace (relative to Sources/, after the module renames)
REPLACED = [
    'SwiftUI/View/Control/Button/Button.swift',   # an empty placeholder upstream
    'SwiftUI/View/Toggle/Toggle.swift',           # resolves through unfinished toggle styles
    'SwiftUI/View/Control/Slider/SystemSliderStyle.swift',   # draws nothing upstream
    'SwiftUI/View/Control/Button/ButtonStyle/TODO/BorderlessButtonStyle.swift',   # Finch's ButtonStyles.swift
    'SwiftUI/View/Control/Button/ButtonStyle/TODO/PlainButtonStyle.swift',
    'SwiftUI/App/Commands/CommandGroup.swift',   # Finch's MainMenu.swift
]

# (from, to): upstream files that belong in the other module, as Apple's declarations are
# (a conformance's witness table is exported only from the protocol's own module)
MOVED = [
    ('SwiftUI/Layout/Alignment/AlignmentWritingModifier.swift', 'SwiftUICore/Layout/Alignment/AlignmentWritingModifier.swift'),
    # _PositionLayout conforms to SwiftUICore.ViewModifier; keep that conformance in the
    # module that defines the protocol so its witness table is exported to app binaries.
    ('SwiftUI/Layout/Modifier/PositionLayout.swift', 'SwiftUICore/Layout/Modifier/PositionLayout.swift'),
]

# (file, upstream declaration, Apple's): the kind and frozenness of Apple's declarations, which
# decide every mangled name and how values are passed
KINDS = [
    ('SwiftUI/App/Scene/SceneBuilder.swift', 'public enum SceneBuilder', 'public struct SceneBuilder'),
    ('SwiftUICore/Data/Binding/Binding.swift', '@dynamicMemberLookup\npublic struct Binding<Value> {',
     '@dynamicMemberLookup\n@frozen\npublic struct Binding<Value> {'),
]


# (file, upstream code, Finch's): fixes to upstream code
FIXES = [
    # export the task(value:) constructor for compiled apps; its body remains in this module,
    # but an inlinable-only entry has no dynamic symbol for apps that reference it directly
    ('SwiftUI/Modifier/ViewModifier/TaskModifier.swift',
     '''    @inlinable
    public init(
        value: Value,
        priority: TaskPriority,
        action: @escaping @Sendable () async -> Void
    )''',
     '''    public init(
        value: Value,
        priority: TaskPriority,
        action: @escaping @Sendable () async -> Void
    )'''),
    # an optional view can be none: its count of views is known only when its wrapped
    # view's is zero (ForEach took one per element, and showed an option for a nil one)
    ('SwiftUICore/View/OptionalView.swift',
     '''    nonisolated public static func _viewListCount(inputs: _ViewListCountInputs) -> Int? {
        Wrapped._viewListCount(inputs: inputs)
    }''',
     '''    nonisolated public static func _viewListCount(inputs: _ViewListCountInputs) -> Int? {
        Wrapped._viewListCount(inputs: inputs) == 0 ? 0 : nil
    }'''),
    # describing a text storage described itself, without end
    ('SwiftUICore/View/Text/Text/Text.swift',
     '''        var description = "<\\(Self.self): \\(self)>"''',
     '''        var description = "<\\(Self.self): \\(ObjectIdentifier(self))>"'''),
    # the hosting view's safe area (the title bar, over a full-size content view) as the
    # view graph's, as Apple's: content is placed below it, measured with it, and can ignore it
    ('SwiftUI/Integration/Hosting/AppKit/View/NSHostingView.swift',
     '''    package func updateSafeArea() {
        // TODO
    }''',
     '''    package func updateSafeArea() {
        let insets = safeAreaRegions.contains(.container) ? safeAreaInsets : NSEdgeInsetsZero
        let changed = viewGraph.setSafeAreaInsets(
            EdgeInsets(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right))
        if changed {
            invalidateIntrinsicContentSize()
        }
    }'''),
    ('SwiftUI/Integration/Hosting/AppKit/View/NSHostingView.swift',
     '''            invalidateProperties([.size, .containerSize], mayDeferUpdate: false)''',
     '''            invalidateProperties([.size, .containerSize, .safeArea], mayDeferUpdate: false)'''),
    ('SwiftUI/Integration/Hosting/AppKit/View/NSHostingView.swift',
     '''        if window != nil {
            invalidateProperties(.transform)''',
     '''        if window != nil {
            invalidateProperties([.transform, .safeArea])'''),
    ('SwiftUICore/Layout/LayoutComputer/UnaryLayoutView.swift',
     '''        return dimensionsCache.get(proposedSize) {
            layout.sizeThatFits(
                in: proposedSize,
                context: context,
                child: child
            )
        }''',
     '''        return dimensionsCache.get(proposedSize) {
            if _finchTraceLayout { _finchLayoutDepth += 1 }
            let size = layout.sizeThatFits(
                in: proposedSize,
                context: context,
                child: child
            )
            if _finchTraceLayout {
                _finchLayoutDepth -= 1
                print("\\(String(repeating: "  ", count: _finchLayoutDepth))unary \\(layout) \\(proposedSize) -> \\(size)", to: &_finchStandardError)
            }
            return size
        }'''),
    # each custom layout's sizing and its subviews' answers (FINCH_TRACE_LAYOUT=1)
    ('SwiftUICore/Layout/Layout.swift',
     '''    mutating func sizeThatFits(_ proposedSize: _ProposedSize) -> CGSize {
        sizeCache.get(proposedSize) {
            layout.sizeThatFits(
                proposal: ProposedViewSize(proposedSize),
                subviews: LayoutSubviews(
                    context: proxies.context,
                    storage: .direct(proxies.attributes),
                    layoutDirection: layoutDirection
                ),
                cache: &cache
            )
        }
    }''',
     '''    mutating func sizeThatFits(_ proposedSize: _ProposedSize) -> CGSize {
        sizeCache.get(proposedSize) {
            if _finchTraceLayout { _finchLayoutDepth += 1 }
            let size = layout.sizeThatFits(
                proposal: ProposedViewSize(proposedSize),
                subviews: LayoutSubviews(
                    context: proxies.context,
                    storage: .direct(proxies.attributes),
                    layoutDirection: layoutDirection
                ),
                cache: &cache
            )
            if _finchTraceLayout {
                _finchLayoutDepth -= 1
                print("\\(String(repeating: "  ", count: _finchLayoutDepth))layout \\(L.self) \\(proposedSize) -> \\(size)", to: &_finchStandardError)
            }
            return size
        }
    }'''),
    ('SwiftUICore/Layout/Layout.swift',
     '''    public func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize {
        proxy.size(in: .init(proposal))
    }''',
     '''    public func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize {
        let size = proxy.size(in: .init(proposal))
        if _finchTraceLayout {
            print("\\(String(repeating: "  ", count: _finchLayoutDepth))  subview \\(proposal.width.map { "\\($0)" } ?? "nil")x\\(proposal.height.map { "\\($0)" } ?? "nil") -> \\(size)", to: &_finchStandardError)
        }
        return size
    }'''),
    ('SwiftUICore/Layout/Layout.swift',
     '''package import OpenAttributeGraphShims
''',
     '''package import OpenAttributeGraphShims
import Darwin

let _finchTraceLayout = getenv("FINCH_TRACE_LAYOUT") != nil
nonisolated(unsafe) var _finchLayoutDepth = 0
struct _FinchStandardError: TextOutputStream {
    mutating func write(_ string: String) { fputs(string, stderr) }
}
nonisolated(unsafe) var _finchStandardError = _FinchStandardError()
'''),
    # which environment lacks an object: its keys, in the failure (FINCH_ENV_OBJECT_DEBUG=1)
    ('SwiftUICore/Data/Combine/Environment+Objects.swift',
     '''#else
import Combine
#endif
''',
     '''#else
import Combine
#endif
import Darwin
'''),
    ('SwiftUICore/Data/Combine/Environment+Objects.swift',
     '''            guard let object = self[key] else {
                preconditionFailure(''',
     '''            guard let object = self[key] else {
                if getenv("FINCH_ENV_OBJECT_DEBUG") != nil {
                    var names: [String] = []
                    plist.elements?.forEach(filter: BloomFilter()) { element, _ in
                        names.append(String(reflecting: element.takeUnretainedValue().keyType))
                    }
                    fputs("environment without \\(ObjectType.self): \\(names.joined(separator: ", "))\\n", stderr)
                }
                preconditionFailure('''),
    # an @Environment property read outside a view's graph (Finch reads menu commands' content
    # so) reads `EnvironmentValues()`: while Finch reads them, that's the scene's environment
    ('SwiftUICore/Data/Environment/EnvironmentValues.swift',
     '''    public init() {
        _plist = PropertyList()
        tracker = nil
        CoreGlue2.shared.configureEmptyEnvironment(&self)
    }''',
     '''    public init() {
        if let unbound = EnvironmentValues._finchUnbound {
            self = unbound
            return
        }
        _plist = PropertyList()
        tracker = nil
        CoreGlue2.shared.configureEmptyEnvironment(&self)
    }

    /// What an environment property outside any view's graph reads, while Finch reads content
    /// so (on the main thread).
    package nonisolated(unsafe) static var _finchUnbound: EnvironmentValues?

    /// Runs `body` with environment properties outside a graph (a style's) reading `environment`.
    package static func _finchReading<T>(_ environment: EnvironmentValues, _ body: () -> T) -> T {
        let previous = _finchUnbound
        _finchUnbound = environment
        defer { _finchUnbound = previous }
        return body()
    }'''),
    # Xcode's asset symbols (Color(.accent), Image(.icon)): the resource's name and bundle, read
    # from Finch's DeveloperToolsSupport (the SDK's interface doesn't show them)
    ('SwiftUICore/Graphic/Color/NamedColor.swift',
     '''    public init(_ resource: ColorResource) {
        _openSwiftUIUnimplementedFailure()
    }''',
     '''    public init(_ resource: ColorResource) {
        let (name, bundle) = _finchNamedResource(resource)
        self.init(provider: _FinchAssetColor(name: name ?? "", bundle: bundle))
    }
}

import CoreGraphics
import Foundation

/// A colour from an asset catalogue, as AppKit has it (+[NSColor colorNamed:bundle:], reached
/// through the Objective-C runtime: AppKit's Swift overlay imports SwiftUICore), in the light
/// or dark appearance the environment's colour scheme calls for.
private struct _FinchAssetColor: ColorProvider {
    var name: String
    var bundle: Bundle?

    var nsColor: AnyObject? {
        guard let cls = NSClassFromString("NSColor") as? NSObject.Type else { return nil }
        let sel = NSSelectorFromString("colorNamed:bundle:")
        guard cls.responds(to: sel) else { return nil }
        return cls.perform(sel, with: name, with: bundle ?? Bundle.main)?.takeUnretainedValue()
    }

    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        guard let color = nsColor as? NSObject,
              let appearanceClass = NSClassFromString("NSAppearance") as? NSObject.Type else { return .clear }
        let named = environment.colorScheme == .dark ? "NSAppearanceNameDarkAqua" : "NSAppearanceNameAqua"
        let appearance = appearanceClass.perform(NSSelectorFromString("appearanceNamed:"), with: named)?.takeUnretainedValue()
        let current = appearanceClass.perform(NSSelectorFromString("currentAppearance"))?.takeUnretainedValue()
        _ = appearanceClass.perform(NSSelectorFromString("setCurrentAppearance:"), with: appearance)
        defer { _ = appearanceClass.perform(NSSelectorFromString("setCurrentAppearance:"), with: current) }
        guard let cg = color.perform(NSSelectorFromString("CGColor"))?.takeUnretainedValue() else { return .clear }
        return Color.Resolved(failableCGColor: cg as! CGColor) ?? .clear
    }

    var kitColor: AnyObject? { nsColor }

    var colorDescription: String { "Asset(\\(name))" }'''),
    ('SwiftUICore/View/Image/NamedImage.swift',
     '''    public init(_ resource: ImageResource) {
        _openSwiftUIUnimplementedFailure()
    }
}''',
     '''    public init(_ resource: ImageResource) {
        let (name, bundle) = _finchNamedResource(resource)
        self.init(name ?? "", bundle: bundle)
    }
}

/// A resource's asset name and bundle, found in its stored properties.
package func _finchNamedResource(_ resource: Any) -> (String?, Bundle?) {
    var name: String?
    var bundle: Bundle?
    func visit(_ value: Any, depth: Int) {
        guard depth < 6 else { return }
        for child in Mirror(reflecting: value).children {
            if child.label == "name", let s = child.value as? String { name = s }
            if child.label == "bundle", let b = child.value as? Bundle { bundle = b }
            visit(child.value, depth: depth + 1)
        }
    }
    visit(resource, depth: 0)
    return (name, bundle)
}'''),
    # the storage type's metadata accessor was called through a C function pointer made from
    # its address, which isn't signed on arm64e: ask for the type through a generic instead
    ('SwiftUICore/Runtime/ConditionalMetadata.swift',
     '''            typealias Accessor =  @convention(c) (UInt, Metadata, Metadata) -> Metadata
            let nominal = Metadata(_ConditionalContent<Void, Void>.Storage.self).nominalDescriptor!
            let accessorRelativePointer = nominal.advanced(by: 12)
            let accessor = unsafeBitCast(
                accessorRelativePointer.advanced(by:Int(accessorRelativePointer.assumingMemoryBound(to: Int32.self).pointee)),
                to: Accessor.self
            )
            let type = accessor(0, Metadata(metadata.genericType(at: 0)), Metadata(metadata.genericType(at: 1)))
            storage = .either(type.type,''',
     '''            let type = conditionalStorageType(metadata.genericType(at: 0), metadata.genericType(at: 1))
            storage = .either(type,'''),
    # the first window: its content at its own size (not upstream's placeholder 500 x 300
    # frame), titled by its scene or else by the app, as Apple's untitled windows are
    # (Finch's Windows.swift opens windows for scenes; the first as the app launches)
    ('SwiftUI/App/App/AppKit/AppKitAppDelegate.swift',
     '''        let items = AppGraph.shared?.rootSceneList?.items ?? []
        let view = items[0].value.view
        let hostingVC = NSHostingController(rootView: view.frame(width: 500, height: 300).rootEnvironment())
        /* OpenSwiftUI Addition Begin */
        if let rendererConfiguration = graph.rendererConfiguration {
            hostingVC._rendererConfiguration = rendererConfiguration
        }
        /* OpenSwiftUI Addition End */
        let windowVC = WindowController(hostingVC)
        windowVC.showWindow(nil)
        self.windowVC = windowVC''',
     '''        self.windowVC = _FinchWindows.openFirst()'''),
    # centred at its laid-out size, as Apple's new windows are
    ('SwiftUI/App/App/AppKit/AppWindowsController.swift',
     '''        window = NSWindow(contentViewController: hostingVC)
        window?.center()''',
     '''        window = NSWindow(contentViewController: hostingVC)
        window?.layoutIfNeeded()
        window?.center()'''),
    ('SwiftUICore/Graphic/Color/AccentColor.swift', '// MARK: - Color + accentColor',
     'import Foundation\nimport CoreGraphics\n\n// MARK: - Color + accentColor'),
    # the system accent colour without CoreUI's asset catalogue: AppKit's control accent
    # colour (Finch's accent), looked up at run time, as SwiftUICore doesn't link AppKit
    ('SwiftUICore/Graphic/Color/AccentColor.swift',
     '''        let colorName = systemAccentValueProvider.accentColorName(value: systemAccentValue)
        guard let color = appearance(allowsVibrantBlending: nil)
            .asset(for: colorName)?
            .0
        else {
            return .blue
        }
        return Color(color)''',
     '''        _ = systemAccentValueProvider
        guard let nsColor = (NSClassFromString("NSColor") as? NSObject.Type)?
            .perform(NSSelectorFromString("controlAccentColor"))?.takeUnretainedValue() as? NSObject,
            let cgColor = nsColor.perform(NSSelectorFromString("CGColor"))?.takeUnretainedValue()
        else {
            return .blue
        }
        return Color(cgColor: cgColor as! CGColor)'''),
    # Observation's access list lives in the Swift runtime's thread-local slot for it
    # (__PTK_FRAMEWORK_SWIFT_KEY6, as swift/Threading/Impl/Darwin.h has it), which the real
    # Observation library sets while tracking; Apple's SwiftUI shares it the same way
    ('SwiftUICore/Data/Observation/ObservationUtils.swift', '// MARK: - ObservationEntry',
     '''// MARK: - _ThreadLocal

private enum _ThreadLocal {
    static let key = pthread_key_t(106)   // __PTK_FRAMEWORK_SWIFT_KEY6

    static var value: UnsafeMutableRawPointer? {
        get { pthread_getspecific(key) }
        set { pthread_setspecific(key, newValue) }
    }
}

// MARK: - ObservationEntry'''),
    # Gradient is Finch's (Finch/SwiftUICore/Gradients.swift)
    ('SwiftUICore/Graphic/Gradient/ResolvedGradient.swift',
     '''// FIXME
public struct Gradient {
    package init(_ resolved: ResolvedGradient) {
//        self.init(
//            stops: resolved.stops.map {
//                Stop(color: Color($0.color), location: $0.location)
//            }
//        )
    }

}''', ''),
    # a shape filled with a paint that isn't a color (a gradient): drawn by CoreGraphics,
    # clipped to the shape, as the layer's contents
    ('SwiftUICore/Shape/ShapeLayer.swift',
     '''        guard let color else {
            layer.backgroundColor = nil
            layer.borderColor = nil
            layer.borderWidth = 0
            layer.contents = nil
            _openSwiftUIUnimplementedWarning()
            return
        }''',
     '''        guard let color else {
            layer.backgroundColor = nil
            layer.borderColor = nil
            layer.borderWidth = 0
            layer.cornerRadius = 0
            layer.contentsScale = contentsScale > 0 ? contentsScale : 2
            layer.contents = (paint as? _FinchCGPaint).flatMap {
                _finchRasterize($0, shapeType: shapeType, path: path, origin: origin, paintBounds: paintBounds,
                                eoFill: style.isEOFilled, scale: contentsScale)
            }
            return
        }'''),
    ('SwiftUICore/Shape/ShapeLayer.swift', '\nenum ShapeType {',
     '''
/// A paint drawn into an image the size of the layer showing `path` (at `origin` in the
/// shape's space), clipped to the shape; `paintBounds` is the shape's frame in the layer.
func _finchRasterize(_ paint: _FinchCGPaint, shapeType: ShapeType, path: Path, origin: CGPoint, paintBounds: CGRect,
                     eoFill: Bool, scale: CGFloat) -> CGImage? {
    let clip: CGPath
    switch shapeType {
    case .empty:
        return nil
    case let .rect(rect, radius, _):
        clip = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    case let .rectBorder(rect, radius, _, lineWidth):
        let inner = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let r = max(0, radius - lineWidth / 2)
        clip = CGPath(roundedRect: inner, cornerWidth: r, cornerHeight: r, transform: nil)
            .copy(strokingWithWidth: lineWidth, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
    case let .strokedPath(stroked, strokeStyle):
        clip = stroked.strokedPath(strokeStyle).cgPath
    case .other:
        clip = path.cgPath
    }
    // the layer's bounds: the path's (ShapeLayerHelper.makeLayerBounds); a scale not yet
    // known is taken as 2, the scale of Apple Silicon Macs' displays
    let scale = scale > 0 ? scale : 2
    let layerSize = path.boundingRect.isNull ? .zero : path.boundingRect.size
    let width = Int(ceil(layerSize.width * scale)), height = Int(ceil(layerSize.height * scale))
    guard width > 0, height > 0, width < 16384, height < 16384,
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    // in points, then the shape's space (the layer shows its contents flipped, as the shape's
    // space is: y down)
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -origin.x, y: -origin.y)
    context.addPath(clip)
    context.clip(using: eoFill ? .evenOdd : .winding)
    paint._finchDraw(in: context, bounds: paintBounds.offsetBy(dx: origin.x, dy: origin.y))
    return context.makeImage()
}

enum ShapeType {'''),
    # shapes filled with a paint that isn't a color (gradients): a shape with the paint
    ('SwiftUICore/Shape/ShapeStyle/ShapeStyleRendering.swift',
     '''            render(color: resolved)
        default:
            _openSwiftUIUnimplementedFailure()
        }''',
     '''            render(color: resolved)
        case let .paint(paint):
            render(paint: paint)
        default:
            _openSwiftUIUnimplementedFailure()
        }'''),
    ('SwiftUICore/Shape/ShapeStyle/ShapeStyleRendering.swift',
     '''    private mutating func render(paint: AnyResolvedPaint) {
        _openSwiftUIUnimplementedFailure()
    }''',
     '''    private mutating func render(paint: AnyResolvedPaint) {
        defer {
            if let data = interpolatorData {
                addEffect(.interpolatorLayer(data.group, serial: data.serial))
                interpolatorData = nil
            }
        }
        guard !paint.isClear else { return }
        switch shape {
        case let .path(path, fillStyle):
            item.value = .content(DisplayList.Content(.shape(path, paint, fillStyle), seed: contentSeed))
        case .text:
            item.value = .content(DisplayList.Content(.color(.clear), seed: contentSeed))
        case .image, .alphaMask, .empty:
            break
        }
    }'''),
    # Scene.commands is Finch's (MainMenu.swift)
    ('SwiftUI/App/Commands/Commands.swift',
     '''    nonisolated public func commands<Content>(
        @CommandsBuilder content: () -> Content
    ) -> some Scene where Content: Commands {
        modifier(CommandsModifier(content: content()))
    }''', ''),
    # the main menu, as the app finishes launching
    ('SwiftUI/App/App/AppKit/AppKitAppDelegate.swift',
     '''    func applicationWillFinishLaunching(_ notification: Notification) {
        Update.begin()''',
     '''    func applicationWillFinishLaunching(_ notification: Notification) {
        _FinchMainMenu.install()
        Update.begin()'''),
    # an identified view reports its frame where a ScrollViewReader asks (ScrollTargets.swift)
    ('SwiftUICore/View/DynamicView/IDView.swift',
     '''            var inputs = inputs
            inputs.viewPhase = Attribute(phase)
            return Content.makeDebuggableView(view: view[offset: { .of(&$0.content)}], inputs: inputs)''',
     '''            var inputs = inputs
            inputs.viewPhase = Attribute(phase)
            return ModifiedContent<Content, _FinchScrollTargetModifier>.makeDebuggableView(
                view: _GraphValue(_FinchReportedContent(view: view.value)), inputs: inputs)'''),
    ('SwiftUICore/View/DynamicView/IDView.swift',
     '''        inputs.base.pushStableID(id)
        let view = _GraphValue(CachedView(view: view, id: id))
        return Content.makeDebuggableViewList(view: view, inputs: inputs)''',
     '''        inputs.base.pushStableID(id)
        let cached = Attribute(CachedView(view: view, id: id))
        let reported = _GraphValue(_FinchReportedChild(content: cached, id: AnyHashable(id)))
        return ModifiedContent<Content, _FinchScrollTargetModifier>.makeDebuggableViewList(view: reported, inputs: inputs)'''),
    # whether a rounded rectangle holds a point, by its geometry: OpenRenderBox's path
    # storage can't take elements yet, and hit testing a rounded shape built one to ask
    ('SwiftUICore/Shape/RoundedCornerStyle.swift',
     '''    package func contains(_ point: CGPoint) -> Bool {
        withTemporaryPath { path in
            path.contains(point: point, eoFill: false)
        }
    }''',
     '''    package func contains(_ point: CGPoint) -> Bool {
        let r = rect.standardized
        guard r.contains(point) else { return false }
        // the corners' ellipses (continuous corners taken as circular ones)
        let rx = min(abs(cornerSize.width), r.width / 2), ry = min(abs(cornerSize.height), r.height / 2)
        guard rx > 0, ry > 0 else { return true }
        let cx = point.x < r.minX + rx ? r.minX + rx : point.x > r.maxX - rx ? r.maxX - rx : point.x
        let cy = point.y < r.minY + ry ? r.minY + ry : point.y > r.maxY - ry ? r.maxY - ry : point.y
        let dx = (point.x - cx) / rx, dy = (point.y - cy) / ry
        return dx * dx + dy * dy <= 1
    }'''),
    # a stroked path's outline, through CoreGraphics (dashed first when the style has dashes)
    ('SwiftUICore/Shape/Path.swift',
     '''    public func strokedPath(_ style: StrokeStyle) -> Path {
        _openSwiftUIUnimplementedFailure()
    }''',
     '''    public func strokedPath(_ style: StrokeStyle) -> Path {
        var path = cgPath
        if !style.dash.isEmpty {
            path = path.copy(dashingWithPhase: style.dashPhase, lengths: style.dash)
        }
        return Path(path.copy(strokingWithWidth: style.lineWidth, lineCap: style.lineCap,
                              lineJoin: style.lineJoin, miterLimit: style.miterLimit))
    }'''),
    ('SwiftUICore/Runtime/ConditionalMetadata.swift', '\nextension Optional {',
     '''
/// `_ConditionalContent<T, F>.Storage`, for the true and false content types.
private func conditionalStorageType(_ t: any Any.Type, _ f: any Any.Type) -> any Any.Type {
    func withTrue<T>(_: T.Type) -> any Any.Type {
        func withFalse<F>(_: F.Type) -> any Any.Type { _ConditionalContent<T, F>.Storage.self }
        return _openExistential(f, do: withFalse)
    }
    return _openExistential(t, do: withTrue)
}

extension Optional {'''),
    ('SwiftUICore/View/Scroll/ScrollPosition.swift',
     'public struct ScrollPosition {}',
     '''public import CoreGraphics

@available(macOS 15.0, *)
@_originallyDefinedIn(module: "SwiftUI", macOS 15.0)
public struct ScrollPosition: Sendable {
    package var _viewID: AnyHashable?
    package var _idType: ObjectIdentifier?
    package var _edge: Edge?
    package var _point: CGPoint?
    package var _x: CGFloat?
    package var _y: CGFloat?
    package var _anchor: UnitPoint?
    package var _isPositionedByUser: Bool

    package init() {
        _viewID = nil
        _idType = nil
        _edge = nil
        _point = nil
        _x = nil
        _y = nil
        _anchor = nil
        _isPositionedByUser = false
    }
}'''),
    # GraphicsContext's storage: Finch's draws into a CoreGraphics context (Canvas,
    # withCGContext; Finch/SwiftUICore/Canvas.swift)
    ('SwiftUICore/Graphic/GraphicsContext.swift',
     '''    @usableFromInline
    final class Storage {
        
    }''',
     '''    @usableFromInline
    final class Storage {
        var cgContext: CGContext?
        var environment: EnvironmentValues

        init(cgContext: CGContext?, environment: EnvironmentValues) {
            self.cgContext = cgContext
            self.environment = environment
        }
    }'''),
    # an @Observable model read in a scene's body (the app graph, not a view graph) is tracked
    # by its own graph host
    ('SwiftUICore/Data/Observation/ObservationUtils.swift',
     'let weakViewGraph = WeakUncheckedSendable(ViewGraph.current)', 'let weakViewGraph = WeakUncheckedSendable(GraphHost.currentHost)'),
    # the update cycle detectors (scenes' onChange too) count the updates of whichever graph
    # they're in
    ('SwiftUICore/Log/CycleDetector.swift',
     '''    package init() {
        updateSeed = ViewGraph.current.data.$updateSeed
        lastSeed = .max
        ttl = .zero''',
     '''    package init() {
        updateSeed = GraphHost.currentHost.data.$updateSeed
        lastSeed = .max
        ttl = .zero'''),
    ('SwiftUICore/Log/CycleDetector.swift',
     '''    package init() {
        updateSeed = ViewGraph.current.data.$updateSeed
        lastSeed = .max
        hasLogged = false''',
     '''    package init() {
        updateSeed = GraphHost.currentHost.data.$updateSeed
        lastSeed = .max
        hasLogged = false'''),
    # a safe-area inset is one view, in a list too (Font Book's grid has a filter bar inset)
    ('SwiftUICore/Layout/Modifier/InsetViewModifier.swift',
     '''@available(*, unavailable)
extension _InsetViewModifier: Sendable {}''',
     '''@available(*, unavailable)
extension _InsetViewModifier: Sendable {}

extension _InsetViewModifier: UnaryViewModifier {}'''),
    # create a SwiftUI responder and an AppKit focus anchor for focusable views
    ('SwiftUI/Event/Focus/Focusable.swift',
     '''if !modifier.isFocusable || focusDisabled {
                        viewGraph?[FocusViewGraph.self]?.pointee.needsFocusUpdate = true''',
     '''if !modifier.isFocusable || !isEnabled || focusDisabled {
                        viewGraph?[FocusViewGraph.self]?.pointee.needsFocusUpdate = true'''),
    ('SwiftUI/Event/Focus/Focusable.swift',
     '''        #if os(macOS)
        _openSwiftUIUnimplementedFailure()
        #else
        _openSwiftUIUnimplementedFailure()
        #endif
    }
}''',
     '''        var newInputs = inputs
        newInputs.preferences.requiresViewResponders = true
        newInputs.transform = Attribute(FocusCoordinateSpaceTransform(
            transform: inputs.transform,
            position: inputs.animatedPosition()
        ))
        let options = Attribute(ResolvedOptions(
            modifier: modifier.value,
            environment: inputs.environment
        ))
        let item = Attribute(UpdateViewFocusItem(
            modifier: modifier.value,
            options: options,
            inputs: newInputs
        ))
        let responder = FocusableViewResponder(inputs: newInputs)
        let isEnabled = Attribute(value: !newInputs.archivedView.isArchived && !newInputs[UsingGraphicsRenderer.self])
        let focusEffect = Attribute(UpdateFocusEffectView(
            isEnabled: isEnabled,
            responder: responder
        ))
        var outputs = makeSecondaryLayerView(
            secondaryLayer: focusEffect,
            alignment: Attribute(value: Alignment.center),
            inputs: newInputs,
            body: body,
            flipOrder: false
        )
        let responderFilter = Attribute(UpdateFocusableViewResponder(
            inputs: newInputs,
            outputs: outputs,
            item: item,
            responder: responder
        ))
        outputs.preferences.viewResponders = responderFilter
        return outputs
    }
}

@available(*, unavailable)
extension _FocusableModifier: Sendable {}'''),
    ('SwiftUI/Event/Focus/Focusable.swift',
     '''private class FocusableViewResponder: DefaultLayoutViewResponder, FocusResponder {''',
     '''class FocusableViewResponder: DefaultLayoutViewResponder, FocusResponder {'''),
    ('SwiftUI/Event/Focus/Focusable.swift',
     '''    @Attribute var geometry: ContentResponderHelper<TrivialContentResponder>
    @Attribute var children: [ViewResponder]
    @Attribute var isEnabled: Bool''',
     '''    @Attribute var size: ViewSize
    @Attribute var position: ViewOrigin
    @Attribute var transform: ViewTransform
    @Attribute var children: [ViewResponder]
    @Attribute var isEnabled: Bool
    @Attribute var focusDisabled: Bool'''),
    ('SwiftUI/Event/Focus/Focusable.swift',
     '''        item: Attribute<FocusItem.ViewItem>,
        geometry: Attribute<ContentResponderHelper<TrivialContentResponder>>,
        responder: FocusableViewResponder
    ) {
        _item = item
        _geometry = geometry
        _children = outputs.viewResponders()
        _isEnabled = inputs.base.isEnabled''',
     '''        item: Attribute<FocusItem.ViewItem>,
        responder: FocusableViewResponder
    ) {
        _item = item
        _size = inputs.animatedSize()
        _position = inputs.animatedPosition()
        _transform = inputs.transform
        _children = outputs.viewResponders()
        _isEnabled = inputs.base.isEnabled
        _focusDisabled = inputs.base.focusDisabled'''),
    ('SwiftUI/Event/Focus/Focusable.swift',
     '''        let (geometry, geometryChanged) = $geometry.changedValue()
        let (isEnabled, isEnabledChanged) = $isEnabled.changedValue()
        responder.baseItem = item''',
     '''        let (size, sizeChanged) = $size.changedValue()
        let (position, positionChanged) = $position.changedValue()
        let (transform, transformChanged) = $transform.changedValue()
        let (isEnabled, isEnabledChanged) = $isEnabled.changedValue()
        let (focusDisabled, focusDisabledChanged) = $focusDisabled.changedValue()
        responder.baseItem = item'''),
    ('SwiftUI/Event/Focus/Focusable.swift',
     '''        if geometryChanged || !hasValue {
            responder.geometry = geometry
        }
        if isEnabledChanged || !hasValue {
            responder.isEnabled = isEnabled
        }''',
     '''        responder.geometry.update(
            data: (value: TrivialContentResponder(), changed: !hasValue),
            size: (value: size, changed: sizeChanged),
            position: (value: position, changed: positionChanged),
            transform: (value: transform, changed: transformChanged),
            parent: responder
        )
        if isEnabledChanged || !hasValue {
            responder.isEnabled = isEnabled
        }
        if focusDisabledChanged || !hasValue {
            responder.isFocusDisabled = focusDisabled
        }'''),
    ('SwiftUI/Event/Focus/FocusEffectView.swift',
     '''        let view = _FocusRingView(responder: responder)''',
     '''        let view = FinchFocusKeyView(responder: responder)'''),
    ('SwiftUI/Event/Focus/FocusBridge.swift',
     '''    var flags: Flags

    #if os(macOS)''',
     '''    var flags: Flags

    #if os(macOS)
    weak var finchHost: (any PlatformView & FocusBridgeProvider & FocusHost)?
    #endif

    #if os(macOS)'''),
    ('SwiftUI/Event/Focus/FocusBridge.swift',
     '''    init() {
        _openSwiftUIUnimplementedFailure()
    }''',
     '''    init() {
        #if os(macOS)
        flags = [.canAcceptFocus]
        #else
        _openSwiftUIUnimplementedFailure()
        #endif
    }'''),
    ('SwiftUI/Event/Focus/FocusBridge.swift',
     '''    var host: (PlatformView & FocusBridgeProvider & FocusHost)? {
        _openSwiftUIUnimplementedFailure()
    }''',
     '''    var host: (PlatformView & FocusBridgeProvider & FocusHost)? {
        #if os(macOS)
        finchHost
        #else
        _openSwiftUIUnimplementedFailure()
        #endif
    }'''),
    ('SwiftUI/Event/Focus/FocusBridge.swift',
     '''    func moveFocus(to item: FocusItem, designatedPlatformResponder: PlatformView?) {
        _openSwiftUIUnimplementedFailure()
    }''',
     '''    func moveFocus(to item: FocusItem, designatedPlatformResponder: PlatformView?) {
        #if os(macOS)
        FinchFocusBridgeSupport.moveFocus(self, to: item, designatedPlatformResponder: designatedPlatformResponder)
        #else
        _openSwiftUIUnimplementedFailure()
        #endif
    }'''),
    ('SwiftUI/Event/Focus/FocusNavigator.swift',
     '''    func defaultFocusItem(for responder: any BaseFocusResponder) -> FocusItem? {
        _openSwiftUIUnimplementedFailure()
    }''',
     '''    func defaultFocusItem(for responder: any BaseFocusResponder) -> FocusItem? {
        FinchFocusBridgeSupport.defaultFocusItem(for: responder)
    }'''),
    ('SwiftUI/Event/Platform/AppKit/NSViewResponder.swift',
     '''    var isEnabled: Bool {
        _openSwiftUIUnreachableCode()
    }''',
     '''    var isEnabled: Bool {
        platformViewIsEnabled
    }'''),
    ('SwiftUI/Event/Focus/FocusState.swift',
     '''        var outputs = body(_Graph(), inputs)
        guard inputs.preferences.requiresViewResponders else {
            return outputs
        }
        let responder = FocusStateBindingResponder(inputs: inputs)''',
     '''        var newInputs = inputs
        newInputs.preferences.requiresViewResponders = true
        var outputs = body(_Graph(), newInputs)
        let responder = FocusStateBindingResponder(inputs: newInputs)'''),
    ('SwiftUI/Event/Focus/FocusState.swift',
     '''            inputs: inputs,
            outputs: outputs,
            responder: responder
        ))
        let list = Attribute(ListItemFilter(
            modifier: modifier.value,
            responder: responder,
            focusItem: .init(inputs.focusedItem),
            focusBridge: inputs.base.focusBridge,
            focusScopes: inputs.base.focusScopes,''',
     '''            inputs: newInputs,
            outputs: outputs,
            responder: responder
        ))
        let list = Attribute(ListItemFilter(
            modifier: modifier.value,
            responder: responder,
            focusItem: .init(newInputs.focusedItem),
            focusBridge: newInputs.base.focusBridge,
            focusScopes: newInputs.base.focusScopes,'''),
    ('SwiftUI/Event/Focus/FocusState.swift',
     '''            inputs: inputs.preferences,
            key: FocusStoreList.Key.self,''',
     '''            inputs: newInputs.preferences,
            key: FocusStoreList.Key.self,'''),
    ('SwiftUI/Integration/Hosting/AppKit/View/NSHostingView.swift',
     '''        if let environmentOverride {
            environment.plist.override(with: environmentOverride.plist)
        }
        viewGraph.setEnvironment(environment)''',
     '''        // as Apple's: the colour scheme is the view's appearance's (its window's, or Night's)
        environment.colorScheme = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        if let environmentOverride {
            environment.plist.override(with: environmentOverride.plist)
        }
        environment.focusBridge = focusBridge
        viewGraph.setEnvironment(environment)'''),
    ('SwiftUI/Integration/Hosting/AppKit/View/NSHostingView.swift',
     '''    package func `as`<T>(_ type: T.Type) -> T? {
        if ViewGraphRenderDelegate.self == T.self {''',
     '''    package func `as`<T>(_ type: T.Type) -> T? {
        if FocusHost.self == T.self {
            return unsafeBitCast(self as any FocusHost, to: T.self)
        } else if FocusBridgeProvider.self == T.self {
            return unsafeBitCast(self as any FocusBridgeProvider, to: T.self)
        } else if ViewGraphRenderDelegate.self == T.self {'''),
    ('SwiftUI/Integration/Hosting/AppKit/View/NSHostingView.swift',
     '''    final override public var isFlipped: Bool { true }
''',
     '''    final override public var isFlipped: Bool { true }

    open override func mouseDown(with event: NSEvent) {
        finchFocusOnMouseDown(at: convert(event.locationInWindow, from: nil))
        super.mouseDown(with: event)
    }
'''),
    ('SwiftUI/Integration/Hosting/AppKit/View/NSHostingView.swift',
     '''    package var focusedResponder: ResponderNode? {
        // TODO: Return focusBridge.focusedItem?.responder when FocusBridge is available.
        _openSwiftUIUnimplementedWarning()
        return nil
    }''',
     '''    package var focusedResponder: ResponderNode? {
        finchCurrentFocusedResponder
    }'''),
    # inset shapes: the shape in the inset rect, its corners less the inset
    ('SwiftUICore/Shape/InsettableShape.swift',
     'extension RoundedRectangle: InsettableShape {\n    @inlinable\n    public func inset(by amount: CGFloat) -> some InsettableShape {\n        _Inset(base: self, amount: amount)\n    }\n\n    @usableFromInline\n    @frozen\n    struct _Inset: InsettableShape {\n        @usableFromInline\n        var base: RoundedRectangle\n        \n        @usableFromInline\n        var amount: CGFloat\n    \n        @inlinable\n        init(base: RoundedRectangle, amount: CGFloat) {\n            (self.base, self.amount) = (base, amount)\n        }\n\n        @usableFromInline\n        nonisolated func path(in rect: CGRect) -> Path {\n            _openSwiftUIUnimplementedFailure()\n        }',
     'extension RoundedRectangle: InsettableShape {\n    @inlinable\n    public func inset(by amount: CGFloat) -> some InsettableShape {\n        _Inset(base: self, amount: amount)\n    }\n\n    @usableFromInline\n    @frozen\n    struct _Inset: InsettableShape {\n        @usableFromInline\n        var base: RoundedRectangle\n        \n        @usableFromInline\n        var amount: CGFloat\n    \n        @inlinable\n        init(base: RoundedRectangle, amount: CGFloat) {\n            (self.base, self.amount) = (base, amount)\n        }\n\n        @usableFromInline\n        nonisolated func path(in rect: CGRect) -> Path {\n            RoundedRectangle(cornerSize: CGSize(width: max(0, base.cornerSize.width - amount),\n                                                 height: max(0, base.cornerSize.height - amount)),\n                             style: base.style)\n                .path(in: rect.insetBy(dx: amount, dy: amount))\n        }'),
    ('SwiftUICore/Shape/InsettableShape.swift',
     'extension UnevenRoundedRectangle: InsettableShape {\n    @inlinable\n    public func inset(by amount: CGFloat) -> some InsettableShape {\n        _Inset(base: self, amount: amount)\n    }\n\n    @usableFromInline\n    @frozen\n    struct _Inset: InsettableShape {\n        @usableFromInline\n        var base: UnevenRoundedRectangle\n        \n        @usableFromInline\n        var amount: CGFloat\n    \n        @inlinable\n        init(base: UnevenRoundedRectangle, amount: CGFloat) {\n            (self.base, self.amount) = (base, amount)\n        }\n\n        @usableFromInline\n        nonisolated func path(in rect: CGRect) -> Path {\n            _openSwiftUIUnimplementedFailure()\n        }',
     'extension UnevenRoundedRectangle: InsettableShape {\n    @inlinable\n    public func inset(by amount: CGFloat) -> some InsettableShape {\n        _Inset(base: self, amount: amount)\n    }\n\n    @usableFromInline\n    @frozen\n    struct _Inset: InsettableShape {\n        @usableFromInline\n        var base: UnevenRoundedRectangle\n        \n        @usableFromInline\n        var amount: CGFloat\n    \n        @inlinable\n        init(base: UnevenRoundedRectangle, amount: CGFloat) {\n            (self.base, self.amount) = (base, amount)\n        }\n\n        @usableFromInline\n        nonisolated func path(in rect: CGRect) -> Path {\n            UnevenRoundedRectangle(\n                topLeadingRadius: max(0, base.cornerRadii.topLeading - amount),\n                bottomLeadingRadius: max(0, base.cornerRadii.bottomLeading - amount),\n                bottomTrailingRadius: max(0, base.cornerRadii.bottomTrailing - amount),\n                topTrailingRadius: max(0, base.cornerRadii.topTrailing - amount),\n                style: base.style)\n                .path(in: rect.insetBy(dx: amount, dy: amount))\n        }'),
    ('SwiftUICore/Shape/InsettableShape.swift',
     'extension Capsule: InsettableShape {\n    @inlinable\n    public func inset(by amount: CGFloat) -> some InsettableShape {\n        _Inset(amount: _Inset._makeInset(amount, style: style))\n    }\n\n    @usableFromInline\n    @frozen\n    struct _Inset: InsettableShape {\n        @usableFromInline\n        var amount: CGFloat\n    \n        @inlinable\n        init(amount: CGFloat) {\n            self.amount = amount\n        }\n\n        @usableFromInline\n        nonisolated func path(in rect: CGRect) -> Path {\n            _openSwiftUIUnimplementedFailure()\n        }',
     'extension Capsule: InsettableShape {\n    @inlinable\n    public func inset(by amount: CGFloat) -> some InsettableShape {\n        _Inset(amount: _Inset._makeInset(amount, style: style))\n    }\n\n    @usableFromInline\n    @frozen\n    struct _Inset: InsettableShape {\n        @usableFromInline\n        var amount: CGFloat\n    \n        @inlinable\n        init(amount: CGFloat) {\n            self.amount = amount\n        }\n\n        @usableFromInline\n        nonisolated func path(in rect: CGRect) -> Path {\n            Capsule().path(in: rect.insetBy(dx: amount, dy: amount))\n        }'),
    ('SwiftUICore/Shape/InsettableShape.swift',
     'extension Ellipse: InsettableShape {\n    @inlinable\n    public func inset(by amount: CGFloat) -> some InsettableShape {\n        _Inset(amount: amount)\n    }\n\n    @usableFromInline\n    @frozen\n    struct _Inset: InsettableShape {\n        @usableFromInline\n        var amount: CGFloat\n    \n        @inlinable\n        init(amount: CGFloat) {\n            self.amount = amount\n        }\n\n        @usableFromInline\n        nonisolated func path(in rect: CGRect) -> Path {\n            _openSwiftUIUnimplementedFailure()\n        }',
     'extension Ellipse: InsettableShape {\n    @inlinable\n    public func inset(by amount: CGFloat) -> some InsettableShape {\n        _Inset(amount: amount)\n    }\n\n    @usableFromInline\n    @frozen\n    struct _Inset: InsettableShape {\n        @usableFromInline\n        var amount: CGFloat\n    \n        @inlinable\n        init(amount: CGFloat) {\n            self.amount = amount\n        }\n\n        @usableFromInline\n        nonisolated func path(in rect: CGRect) -> Path {\n            Ellipse().path(in: rect.insetBy(dx: amount, dy: amount))\n        }'),
    ('SwiftUICore/Shape/InsettableShape.swift',
     'extension Circle: InsettableShape {\n    @inlinable\n    public func inset(by amount: CGFloat) -> some InsettableShape {\n        _Inset(amount: amount)\n    }\n\n    @usableFromInline\n    @frozen\n    struct _Inset: InsettableShape {\n        @usableFromInline\n        var amount: CGFloat\n    \n        @inlinable\n        init(amount: CGFloat) {\n            self.amount = amount\n        }\n\n        @usableFromInline\n        nonisolated func path(in rect: CGRect) -> Path {\n            _openSwiftUIUnimplementedFailure()\n        }',
     'extension Circle: InsettableShape {\n    @inlinable\n    public func inset(by amount: CGFloat) -> some InsettableShape {\n        _Inset(amount: amount)\n    }\n\n    @usableFromInline\n    @frozen\n    struct _Inset: InsettableShape {\n        @usableFromInline\n        var amount: CGFloat\n    \n        @inlinable\n        init(amount: CGFloat) {\n            self.amount = amount\n        }\n\n        @usableFromInline\n        nonisolated func path(in rect: CGRect) -> Path {\n            Circle().path(in: rect.insetBy(dx: amount, dy: amount))\n        }'),
    # a layout's children's gestures keep the gesture graph's clock (as mergeViewInputs does),
    # so their deadlines pass (a double tap failing lets the single tap through)
    ('SwiftUICore/Event/Responder/DefaultLayoutViewResponder.swift',
     '''            var childInputs = inputs
            childInputs.viewInputs = self.inputs
            childInputs.copyCaches()''',
     '''            var childInputs = inputs
            let gestureTime = childInputs.viewInputs.time
            childInputs.viewInputs = self.inputs
            childInputs.viewInputs.time = gestureTime
            childInputs.copyCaches()'''),
    # FINCH_SWIFTUI_OBJECTS: each environment or observed object a view updates with, and its
    # fields (to see a model's state from outside an app)
    ('SwiftUICore/Data/Combine/EnvironmentObject.swift',
     '''        let newStore = property._store
        if let newStore {''',
     '''        let newStore = property._store
        if let newStore { _finchDumpObject(newStore, changed: changed || signal.changedValue()?.changed == true) }
        if let newStore {'''),
    ('SwiftUICore/Data/Combine/ObservedObject.swift',
     '''        lastObject = object
        let changed = subscriber.attribute.changedValue()?.changed ?? false''',
     '''        lastObject = object
        let changed = subscriber.attribute.changedValue()?.changed ?? false
        _finchDumpObject(object, changed: changed)'''),
    # runtime warnings (Finch's log can't show their private text): also to stderr with
    # FINCH_SWIFTUI_WARNINGS set
    ('SwiftUICore/Log/Logging.swift',
     '''    package static func externalWarning(_ message: String) {
        #if OPENSWIFTUI_SWIFT_LOG''',
     '''    package static func externalWarning(_ message: String) {
        if getenv("FINCH_SWIFTUI_WARNINGS") != nil {
            fputs("SwiftUI: \\(message)\\n", stderr)
        }
        #if OPENSWIFTUI_SWIFT_LOG'''),
    # named images and symbols without CoreUI: AppKit's (the bundle's image, or Finch's symbol
    # artwork), drawn from their CGImage at twice their size; symbols are templates
    ('SwiftUICore/View/Image/NamedImage.swift',
     '''            #endif
            return resolveError(in: context.environment)
        }''',
     '''            #endif
            var platformScale: Double = 1
            var platformTemplate = false
            if let cg = name.withCString({ _FinchPlatformImageCreate($0, location.bundle.map { Unmanaged.passUnretained($0).toOpaque() },
                                                                       &platformScale, &platformTemplate) })?.takeRetainedValue() {
                return Image.Resolved(
                    image: GraphicsImage(
                        contents: .cgImage(cg),
                        scale: platformScale,
                        unrotatedPixelSize: CGSize(width: cg.width, height: cg.height),
                        orientation: .up,
                        isTemplate: platformTemplate
                    ),
                    decorative: decorative,
                    label: label
                )
            }
            return resolveError(in: context.environment)
        }'''),
    ('SwiftUICore/View/Image/NamedImage.swift', 'public import Foundation\n',
     'public import Foundation\n\n/* (userland/SwiftUI/stubs.c) */\n@_silgen_name("_FinchPlatformImageCreate")\n'
     'func _FinchPlatformImageCreate(_ name: UnsafePointer<CChar>, _ bundle: UnsafeMutableRawPointer?, _ scale: UnsafeMutablePointer<Double>,'
     ' _ isTemplate: UnsafeMutablePointer<Bool>) -> Unmanaged<CGImage>?\n'),
    # PresentedWindowContent is Finch's, generic as Apple's is (Finch/SwiftUI/ScenesAndModifiers.swift)
    ('SwiftUI/Modifier/ViewModifier/PresentedSceneValueInputModifier.swift',
     '// TODO\npublic struct PresentedWindowContent {}\n', ''),
    # the attribute scope is Apple's SwiftUIAttributes (AttributeScopes.swiftUI)
    ('SwiftUICore/View/Text/AttributedString/Text+AttributedString.swift',
     'public var openSwiftUI: OpenSwiftUIAttributes.Type', 'public var swiftUI: OpenSwiftUIAttributes.Type'),
    ('SwiftUICore/View/Text/AttributedString/Text+AttributedString.swift',
     'including: \\.openSwiftUI', 'including: \\.swiftUI'),
    # unbounded axes have no intrinsic size to send to AppKit
    ('SwiftUI/Integration/Hosting/AppKit/View/NSHostingView.swift',
     '''        var size = idealSize()
        let pixelLength = convertFromBacking(CGSize(width: 1, height: 1))
        size.width = size.width.rounded(.up, toMultipleOf: pixelLength.width)
        size.height = size.height.rounded(.up, toMultipleOf: pixelLength.height)''',
     '''        var size = intrinsicSizeForAppKit(from: idealSize())'''),
    ('SwiftUI/Integration/Hosting/AppKit/View/NSHostingView.swift',
     '''    private func _layoutSizeThatFits(_ size: CGSize, fixedAxes: UInt) -> CGSize {''',
     '''    private func intrinsicSizeForAppKit(from size: CGSize) -> CGSize {
        let pixelLength = convertFromBacking(CGSize(width: 1, height: 1))
        func metric(_ value: CGFloat, pixelLength: CGFloat) -> CGFloat {
            guard value.isFinite else { return NSView.noIntrinsicMetric }
            let rounded = value.rounded(.up, toMultipleOf: pixelLength)
            return rounded.isFinite ? rounded : NSView.noIntrinsicMetric
        }
        return CGSize(
            width: metric(size.width, pixelLength: pixelLength.width),
            height: metric(size.height, pixelLength: pixelLength.height)
        )
    }

    private func _layoutSizeThatFits(_ size: CGSize, fixedAxes: UInt) -> CGSize {'''),
    ('SwiftUI/Integration/Hosting/AppKit/View/NSHostingView.swift',
     '''        let pixelLength = convertFromBacking(CGSize(width: 1, height: 1))
        let result = fittingSize.rounded(.up, toMultipleOf: pixelLength.width)''',
     '''        let result = intrinsicSizeForAppKit(from: fittingSize)'''),
    # preferredColorScheme: the host reads the preference and gives its window that appearance
    ('SwiftUI/Integration/Hosting/AppKit/View/NSHostingView.swift',
     '''        appendViewGraphFeatures()
        initializeViewGraph()
''',
     '''        appendViewGraphFeatures()
        initializeViewGraph()
        viewGraph.addPreference(PreferredColorSchemeKey.self)
'''),
    ('SwiftUI/Integration/Hosting/AppKit/View/NSHostingView.swift',
     '''        if window != nil {
            invalidateProperties([.transform, .safeArea])''',
     '''        if window != nil {
            applyPreferredColorScheme()
            invalidateProperties([.transform, .safeArea])'''),
]


def rename(m):
    return 'SwiftUICore' if m.group(1) else 'SwiftUI'


def main():
    root = sys.argv[1]
    p = os.path.join(root, 'Package.swift')
    s = open(p).read()
    s = s.replace('"-module-abi-name", "OpenSwiftUI"', '"-module-abi-name", "SwiftUI"')
    s = re.sub(r'"OpenSwiftUI(Core)?"', lambda m: '"SwiftUICore"' if m.group(1) else '"SwiftUI"', s)
    # the build switches stay OPENSWIFTUI_*, as its dependencies read them
    s = s.replace('register(domain: "SwiftUI")', 'register(domain: "OpenSwiftUI")')
    open(p, 'w').write(s)
    src = os.path.join(root, 'Sources')
    # the bridge to Apple's SwiftUI: there is none to bridge to (and the module is SwiftUI itself)
    bridge = os.path.join(src, 'OpenSwiftUIBridge', 'SwiftUI')
    if os.path.isdir(bridge):
        for f in os.listdir(bridge):
            os.remove(os.path.join(bridge, f))
        os.rmdir(bridge)
    for old, new in (('OpenSwiftUICore', 'SwiftUICore'), ('OpenSwiftUI', 'SwiftUI')):
        if os.path.isdir(os.path.join(src, old)):
            os.rename(os.path.join(src, old), os.path.join(src, new))
    # Finch's own sources (userland/SwiftUI/Finch/<module>/), and the upstream files they replace
    finch = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'Finch')
    for module in os.listdir(finch):
        if not os.path.isdir(os.path.join(finch, module)):
            continue
        dest = os.path.join(src, module, 'Finch')
        os.makedirs(dest, exist_ok=True)
        for f in os.listdir(os.path.join(finch, module)):
            if f.endswith('.swift'):
                shutil.copy(os.path.join(finch, module, f), dest)
    for rel in REPLACED:
        os.remove(os.path.join(src, rel))
    for old, new in MOVED:
        t = open(os.path.join(src, old)).read()
        t = t.replace('@_spi(ForOpenSwiftUIOnly)\npublic import SwiftUICore\n', '')
        os.makedirs(os.path.dirname(os.path.join(src, new)), exist_ok=True)
        open(os.path.join(src, new), 'w').write(t)
        os.remove(os.path.join(src, old))
    # kinds Apple's declarations have (the kind is part of every mangled name)
    for rel, old, new in KINDS + FIXES:
        path = os.path.join(src, rel)
        t = open(path).read()
        assert old in t, (rel, old)
        open(path, 'w').write(t.replace(old, new))
    for dirpath, _, files in os.walk(src):
        for f in files:
            if not f.endswith(('.swift', '.modulemap', '.c', '.h', '.m', '.cpp', '.mm')):
                continue
            path = os.path.join(dirpath, f)
            t = open(path, encoding='utf-8', errors='surrogateescape').read()
            # mangled names in strings (@_silgen_name, protocol descriptor lookups) name the modules too
            u = t.replace('15OpenSwiftUICore', '11SwiftUICore').replace('11OpenSwiftUI', '7SwiftUI')
            # Apple's attribute scope (and its key path)
            u = u.replace('OpenSwiftUIAttributes', 'SwiftUIAttributes').replace('self.openSwiftUI.fontModifiers', 'self.swiftUI.fontModifiers')
            if f.endswith(('.swift', '.modulemap')):
                u = MODULE.sub(rename, u)
            if f.endswith('.swift') and (os.sep + 'SwiftUI' in dirpath):
                # the real Observation, not OpenObservation (see build.sh); its SPI group is SwiftUI
                u = u.replace('@_spi(OpenSwiftUI)\npackage import OpenObservation', '@_spi(SwiftUI)\npackage import Observation')
                u = re.sub(r'\b(import|public import|package import) OpenObservation\b', r'\1 Observation', u)
            if u != t:
                open(path, 'w', encoding='utf-8', errors='surrogateescape').write(u)


main()
