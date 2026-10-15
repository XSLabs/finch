// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Continuous pointer movement through an AppKit tracking area, with SwiftUI coordinates.

import AppKit
import SwiftUICore

@available(OpenSwiftUI_v4_0, *)
@frozen
public enum HoverPhase: Equatable, Sendable {
    case active(CGPoint)
    case ended
}

@available(OpenSwiftUI_v4_0, *)
private struct _FinchContinuousHoverModifier: ViewModifier {
    var coordinateSpace: CoordinateSpace
    var action: (HoverPhase) -> Void

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { proxy in
                _FinchContinuousHoverRegion { phase in
                    switch phase {
                    case .active(let point):
                        let frame = proxy.frame(in: coordinateSpace)
                        action(.active(CGPoint(x: frame.minX + point.x, y: frame.minY + point.y)))
                    case .ended:
                        action(.ended)
                    }
                }
            }
        }
    }
}

@available(OpenSwiftUI_v4_0, *)
private struct _FinchContinuousHoverRegion: NSViewRepresentable {
    var action: (HoverPhase) -> Void

    final class RegionView: NSView {
        var action: (HoverPhase) -> Void = { _ in }
        private var area: NSTrackingArea?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let new = NSTrackingArea(rect: bounds,
                                     options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                     owner: self, userInfo: nil)
            addTrackingArea(new)
            area = new
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
            updateTrackingAreas()
        }

        private func report(_ event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            action(.active(CGPoint(x: point.x, y: bounds.maxY - point.y)))
        }

        override func mouseEntered(with event: NSEvent) { report(event) }
        override func mouseMoved(with event: NSEvent) { report(event) }
        override func mouseExited(with event: NSEvent) { action(.ended) }
    }

    func makeNSView(context: Context) -> RegionView { RegionView() }

    func updateNSView(_ view: RegionView, context: Context) {
        view.action = action
    }
}

@available(OpenSwiftUI_v4_0, *)
extension View {
    @_disfavoredOverload
    nonisolated public func onContinuousHover(
        coordinateSpace: CoordinateSpace = .local,
        perform action: @escaping (HoverPhase) -> Void
    ) -> some View {
        modifier(_FinchContinuousHoverModifier(coordinateSpace: coordinateSpace, action: action))
    }
}

@available(OpenSwiftUI_v5_0, *)
extension View {
    nonisolated public func onContinuousHover(
        coordinateSpace: some CoordinateSpaceProtocol = .local,
        perform action: @escaping (HoverPhase) -> Void
    ) -> some View {
        modifier(_FinchContinuousHoverModifier(coordinateSpace: coordinateSpace.coordinateSpace, action: action))
    }
}
