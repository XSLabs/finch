// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Scrolling within the view graph: the content at its ideal size along the scrolling axes,
// offset by the scroll position and clipped, with overlay scrollers. ScrollView and a list's
// rows scroll this way, so their content stays in the graph around them: its environment,
// preferences, coordinate spaces and gestures are the surroundings' (an app's grid can find
// the tile under a click from frames its tiles report, as Font Book's does).
//
// The mouse wheel scrolls it: an AppKit view over it takes the wheel's events that it can
// act on (along an axis it scrolls, with room to scroll) and no other events, so the
// innermost scroller under the pointer that can move takes them. In a ScrollViewReader,
// its identified views report where they are and the reader scrolls it.

import AppKit
import SwiftUICore

struct _FinchClipScroll<Content: View>: View {
    var content: Content
    var axes: Axis.Set = .vertical
    var showsIndicators = true
    var isDisabled = false
    var geometryObservers: [_FinchScrollGeometryObserver] = []
    @State private var offset: CGPoint = .zero
    @State private var contentSize: CGSize = .zero
    @State private var viewport: CGSize = .zero
    @State private var target = _FinchClipScrollTarget()
    @Environment(\._finchScrollReader) private var reader
    @Environment(\.horizontalScrollBounceBehavior) private var horizontalBounce
    @Environment(\.verticalScrollBounceBehavior) private var verticalBounce

    private var maxOffset: CGPoint {
        CGPoint(x: axes.contains(.horizontal) ? max(0, contentSize.width - viewport.width) : 0,
                y: axes.contains(.vertical) ? max(0, contentSize.height - viewport.height) : 0)
    }

    private var bounceAxes: Axis.Set {
        var result: Axis.Set = []
        if axes.contains(.horizontal) && _finchAllowsBounce(horizontalBounce, content: contentSize.width, viewport: viewport.width) {
            result.insert(.horizontal)
        }
        if axes.contains(.vertical) && _finchAllowsBounce(verticalBounce, content: contentSize.height, viewport: viewport.height) {
            result.insert(.vertical)
        }
        return result
    }

    private var displayedOffset: CGPoint {
        let limit = maxOffset
        let bouncing = bounceAxes
        return CGPoint(x: _finchDisplayedOffset(offset.x, limit: limit.x, bounces: bouncing.contains(.horizontal)),
                       y: _finchDisplayedOffset(offset.y, limit: limit.y, bounces: bouncing.contains(.vertical)))
    }

    private var scrollGeometry: ScrollGeometry {
        ScrollGeometry(contentOffset: displayedOffset, contentSize: contentSize, contentInsets: .zero,
                       containerSize: viewport)
    }

    var body: some View {
        let shown = displayedOffset
        let limit = maxOffset
        let target = target, reader = reader, axes = axes
        let offsetState = $offset
        let activeBounceAxes = bounceAxes
        target.axes = axes
        target.scroll = { [$offset] rect, anchor in
            MainActor.assumeIsolated {
                $offset.wrappedValue = target.offset(toShow: rect, anchor: anchor, from: $offset.wrappedValue)
            }
        }
        return content
            // in a reader: the identified views say where they are, and the reader can find us
            .environment(\._finchReportsScrollTargets, reader != nil)
            .background(_FinchScrollRootReporter(enabled: reader != nil))
            .onPreferenceChange(_FinchScrollTargetsKey.self) { targets in
                MainActor.assumeIsolated {
                    let root = targets[_FinchScrollRootReporter.id]?.origin ?? .zero
                    target.targets = targets.mapValues { $0.offsetBy(dx: -root.x, dy: -root.y) }
                    reader?.register(target)
                }
            }
            // not for a scroller around this one: its views aren't in that one's content
            .transformPreference(_FinchScrollTargetsKey.self) { $0 = [:] }
            // along the scrolling axes, the content's ideal size
            .fixedSize(horizontal: axes.contains(.horizontal), vertical: axes.contains(.vertical))
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { contentSize = $0; target.contentSize = $0 }
            .onChange(of: scrollGeometry) { _, geometry in
                for observer in geometryObservers {
                    observer.report(geometry)
                }
            }
            .offset(x: -shown.x, y: -shown.y)
            // as small as offered along the scrolling axes (a frame is otherwise at least its
            // content's size); across them, the content's size
            .frame(minWidth: axes.contains(.horizontal) ? 0 : nil,
                   maxWidth: axes.contains(.horizontal) ? .infinity : nil,
                   minHeight: axes.contains(.vertical) ? 0 : nil,
                   maxHeight: axes.contains(.vertical) ? .infinity : nil,
                   alignment: .topLeading)
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { viewport = $0; target.viewport = $0 }
            .clipped()
            .overlay(alignment: .topTrailing) {
                if showsIndicators, limit.y > 0, viewport.height > 0 {
                    // the vertical scroller's knob: the visible part of the content, where it is
                    let knob = max(16, viewport.height * viewport.height / contentSize.height)
                    Capsule()
                        .fill(Color.gray.opacity(0.6))
                        .frame(width: 6, height: knob)
                        .offset(x: -3, y: 3 + (viewport.height - knob - 6) * shown.y / limit.y)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if showsIndicators, limit.x > 0, viewport.width > 0 {
                    let knob = max(16, viewport.width * viewport.width / contentSize.width)
                    Capsule()
                        .fill(Color.gray.opacity(0.6))
                        .frame(width: knob, height: 6)
                        .offset(x: 3 + (viewport.width - knob - 6) * shown.x / limit.x, y: -3)
                        .allowsHitTesting(false)
                }
            }
            .overlay(_FinchScrollWheelCatcher(canScroll: isDisabled ? [] : [
                limit.x > 0 || activeBounceAxes.contains(.horizontal) ? Axis.Set.horizontal : [],
                limit.y > 0 || activeBounceAxes.contains(.vertical) ? Axis.Set.vertical : [],
            ], scrolled: { dx, dy in
                offsetState.wrappedValue = CGPoint(
                    x: _finchScrolledOffset(offsetState.wrappedValue.x, delta: dx, limit: limit.x,
                                            bounces: activeBounceAxes.contains(.horizontal)),
                    y: _finchScrolledOffset(offsetState.wrappedValue.y, delta: dy, limit: limit.y,
                                            bounces: activeBounceAxes.contains(.vertical)))
            }, scrollEnded: {
                let current = offsetState.wrappedValue
                let settled = CGPoint(x: min(max(0, current.x), limit.x), y: min(max(0, current.y), limit.y))
                guard settled != current else { return }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                    offsetState.wrappedValue = settled
                }
            }))
    }
}

private func _finchAllowsBounce(_ behavior: ScrollBounceBehavior, content: CGFloat, viewport: CGFloat) -> Bool {
    switch behavior._finchKind {
    case .always:
        true
    case .automatic, .basedOnSize:
        content > viewport + 0.5
    }
}

private func _finchDisplayedOffset(_ value: CGFloat, limit: CGFloat, bounces: Bool) -> CGFloat {
    guard bounces else { return min(max(0, value), limit) }
    if value < 0 { return max(-120, value * 0.5) }
    if value > limit { return min(limit + 120, limit + (value - limit) * 0.5) }
    return value
}

private func _finchScrolledOffset(_ value: CGFloat, delta: CGFloat, limit: CGFloat, bounces: Bool) -> CGFloat {
    let next = value - delta
    guard bounces else { return min(max(0, next), limit) }
    return min(limit + 240, max(-240, next))
}

/// A clip scroll as a reader's scroll target: where its views are, and scrolling to one.
final class _FinchClipScrollTarget: _FinchScrollTargetView {
    var targets: [AnyHashable: CGRect] = [:]
    var viewport: CGSize = .zero
    var contentSize: CGSize = .zero
    var axes: Axis.Set = .vertical
    var scroll: (CGRect, UnitPoint?) -> Void = { _, _ in }

    func scroll(toShow rect: CGRect, anchor: UnitPoint?) {
        scroll(rect, anchor)
    }

    /// The offset showing the rect: just enough, or with its anchor at the viewport's.
    func offset(toShow rect: CGRect, anchor: UnitPoint?, from offset: CGPoint) -> CGPoint {
        func along(_ minV: CGFloat, _ size: CGFloat, _ anchorV: CGFloat?, _ current: CGFloat, _ visible: CGFloat,
                   _ content: CGFloat) -> CGFloat {
            var value = current
            if let anchorV {
                value = minV + anchorV * size - anchorV * visible
            } else if minV < current {
                value = minV
            } else if minV + size > current + visible {
                value = minV + size - visible
            }
            return min(max(0, value), max(0, content - visible))
        }
        return CGPoint(
            x: axes.contains(.horizontal)
                ? along(rect.minX, rect.width, anchor?.x, offset.x, viewport.width, contentSize.width) : 0,
            y: axes.contains(.vertical)
                ? along(rect.minY, rect.height, anchor?.y, offset.y, viewport.height, contentSize.height) : 0)
    }
}

/// Takes the mouse wheel's events over a view, when it can act on them (along an axis it can
/// scroll), and lets every other event through.
struct _FinchScrollWheelCatcher: NSViewRepresentable {
    var canScroll: Axis.Set
    var scrolled: (CGFloat, CGFloat) -> Void
    var scrollEnded: () -> Void

    final class WheelView: NSView {
        var canScroll: Axis.Set = []
        var scrolled: (CGFloat, CGFloat) -> Void = { _, _ in }
        var scrollEnded: () -> Void = {}
        private var settleWork: DispatchWorkItem?

        deinit { settleWork?.cancel() }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, event.type == .scrollWheel, frame.contains(point) else {
                return nil
            }
            let vertical = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
            return canScroll.contains(vertical ? .vertical : .horizontal) ? self : nil
        }

        override func scrollWheel(with event: NSEvent) {
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            scrolled(canScroll.contains(.horizontal) ? event.scrollingDeltaX * scale : 0,
                     canScroll.contains(.vertical) ? event.scrollingDeltaY * scale : 0)
            settleWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.settleWork = nil
                self.scrollEnded()
            }
            settleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
    }

    func makeNSView(context: Context) -> WheelView { WheelView() }

    func updateNSView(_ view: WheelView, context: Context) {
        view.canScroll = canScroll
        view.scrolled = scrolled
        view.scrollEnded = scrollEnded
    }
}
