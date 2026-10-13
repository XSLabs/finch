// SPDX-License-Identifier: MIT OR Apache-2.0
// MagnifierSupport: Finch's Magnifier. Apple's Magnifier.app is a small shell (an app
// delegate adaptor and CompositionRoot.mainScene) over this private framework, which holds
// the whole app; Finch's is its own, to the same ABI.
//
// Apple's magnifies what a camera sees. Finch has no camera support yet, so Finch's
// magnifies the screen around the pointer: a window with the enlarged view, a zoom
// slider, and switches to follow the pointer, freeze the picture and invert its colours.
// The screen comes from the window server through CGDisplayCreateImageForRect.

import AppKit
import Combine
import SwiftUI

// MARK: - The app's delegate

public final class MyAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    public override init() {
        super.init()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - Objective-C entry points the app calls

@objc(MagnifierObjc)
public final class MagnifierObjc: NSObject {
    /// Apple's enters the app sandbox here; Finch runs the app unsandboxed for now.
    @objc public static func sandboxInit() {}

    /// Runs a block, returning NO (and the exception's error) if it raised.
    @objc(catchException:error:)
    public static func catchException(_ block: () -> Void, error: NSErrorPointer) -> Bool {
        block()
        return true
    }

    /// Apple's asks a locked iPhone to unlock first; Finch's has nothing to unlock.
    @objc(sbs_unlockDeviceIfNeededAndPerform:)
    public static func sbs_unlockDeviceIfNeededAndPerform(_ block: @escaping () -> Void) {
        block()
    }
}

// MARK: - The scene

public enum CompositionRoot {
    public static var mainScene: some Scene {
        WindowGroup("Magnifier") {
            MagnifierView()
        }
    }
}

// MARK: - The window's content

final class MagnifierModel: ObservableObject {
    @Published var zoom: Double = 2
    @Published var followsPointer = true
    @Published var frozen = false
    @Published var inverted = false
}

struct MagnifierView: View {
    @StateObject private var model = MagnifierModel()

    var body: some View {
        VStack(spacing: 8) {
            MagnifierCanvasView(model: model)
                .frame(minWidth: 320, minHeight: 220)
            HStack(spacing: 12) {
                Text("Zoom")
                Slider(value: $model.zoom, in: 1...8)
                    .frame(width: 160)
                Text(String(format: "%.1f×", model.zoom))
                    .frame(width: 44, alignment: .leading)
                Toggle("Follow pointer", isOn: $model.followsPointer)
                Toggle("Freeze", isOn: $model.frozen)
                Toggle("Invert", isOn: $model.inverted)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }
}

/// The enlarged view: an AppKit view, refreshed ten times a second.
struct MagnifierCanvasView: NSViewRepresentable {
    @ObservedObject var model: MagnifierModel

    func makeNSView(context: Context) -> MagnifierCanvas {
        let view = MagnifierCanvas(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        view.apply(model)
        return view
    }

    func updateNSView(_ view: MagnifierCanvas, context: Context) {
        view.apply(model)
    }
}

final class MagnifierCanvas: NSView {
    private var zoom: CGFloat = 2
    private var followsPointer = true
    private var frozen = false
    private var inverted = false
    private var image: CGImage?
    private var center = CGPoint.zero
    private var timer: Timer?

    override var isFlipped: Bool { true }

    func apply(_ model: MagnifierModel) {
        zoom = CGFloat(model.zoom)
        followsPointer = model.followsPointer
        frozen = model.frozen
        inverted = model.inverted
        refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    /// The display's area to enlarge: the view's size divided by the zoom, centred on the
    /// pointer (or where it last was), kept on the screen.
    private func refresh() {
        guard !frozen, let screen = window?.screen ?? NSScreen.main else {
            needsDisplay = true
            return
        }
        if followsPointer || center == .zero {
            let p = NSEvent.mouseLocation
            // AppKit's screen coordinates rise from the bottom; the display's fall from the top.
            center = CGPoint(x: p.x - screen.frame.minX, y: screen.frame.maxY - p.y)
        }
        let w = max(1, bounds.width / zoom), h = max(1, bounds.height / zoom)
        var r = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
        r.origin.x = min(max(0, r.origin.x), max(0, screen.frame.width - w))
        r.origin.y = min(max(0, r.origin.y), max(0, screen.frame.height - h))
        // Leave out this window, so that the magnifier doesn't magnify itself.
        if let own = window, own.frame.contains(NSEvent.mouseLocation) && followsPointer {
            needsDisplay = true
            return
        }
        image = displayImage(r)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let image, let cg = NSGraphicsContext.current?.cgContext else {
            let message = "Move the pointer outside this window to magnify the screen."
            let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 13)]
            let size = message.size(withAttributes: attrs)
            message.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
            return
        }
        cg.saveGState()
        cg.interpolationQuality = zoom >= 3 ? .none : .medium
        // The view is flipped: draw the image the right way up.
        cg.translateBy(x: 0, y: bounds.height)
        cg.scaleBy(x: 1, y: -1)
        cg.draw(image, in: CGRect(origin: .zero, size: bounds.size))
        if inverted {
            cg.setBlendMode(.difference)
            cg.setFillColor(NSColor.white.cgColor)
            cg.fill(CGRect(origin: .zero, size: bounds.size))
        }
        cg.restoreGState()
    }
}

/// CGDisplayCreateImageForRect, which the SDK no longer lets Swift name (ScreenCaptureKit
/// replaces it on macOS); Finch's CoreGraphics has it.
private func displayImage(_ rect: CGRect) -> CGImage? {
    typealias Fn = @convention(c) (UInt32, CGRect) -> Unmanaged<CGImage>?
    struct Holder { static let fn: Fn? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGDisplayCreateImageForRect")
        .map { unsafeBitCast($0, to: Fn.self) } }
    guard let fn = Holder.fn else { return nil }
    return fn(CGMainDisplayID(), rect)?.takeRetainedValue()
}
