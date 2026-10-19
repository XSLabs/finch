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
    @State private var scrollTargetFrames: [AnyHashable: CGRect] = [:]
    @State private var appliedDefaultAnchor = false
    @State private var appliedPosition: ScrollPosition?
    @State private var lastPositionOffset: CGPoint?
    @State private var lastWheelVelocity: CGPoint = .zero
    @Environment(\._finchScrollReader) private var reader
    @Environment(\._finchScrollPosition) private var scrollPosition
    @Environment(\._finchScrollPositionAnchor) private var scrollPositionAnchor
    @Environment(\._finchDefaultScrollAnchor) private var defaultScrollAnchor
    @Environment(\._finchDefaultScrollAnchors) private var defaultScrollAnchors
    @Environment(\._finchScrollClipDisabled) private var scrollClipDisabled
    @Environment(\._finchScrollTargetBehavior) private var scrollTargetBehavior
    @Environment(\.self) private var environment
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
        let scrollPosition = scrollPosition
        let scrollPositionAnchor = scrollPositionAnchor
        let clipDisabled = scrollClipDisabled
        let contentAlignment = _finchScrollAlignment(scrollAnchor(for: .alignment))
        target.axes = axes
        target.scroll = { [$offset] rect, anchor in
            MainActor.assumeIsolated {
                $offset.wrappedValue = target.offset(toShow: rect, anchor: anchor, from: $offset.wrappedValue)
            }
        }
        let scrolledContent = content
            // in a reader: the identified views say where they are, and the reader can find us
            .environment(\._finchReportsScrollTargets, reader != nil || scrollPosition != nil)
            .background(_FinchScrollRootReporter(enabled: reader != nil || scrollPosition != nil))
            .onPreferenceChange(_FinchScrollTargetsKey.self) { targets in
                MainActor.assumeIsolated {
                    let root = targets[_FinchScrollRootReporter.id]?.origin ?? .zero
                    let localTargets = targets.mapValues { $0.offsetBy(dx: -root.x, dy: -root.y) }
                    target.targets = localTargets
                    scrollTargetFrames = localTargets.filter { $0.key != _FinchScrollRootReporter.id }
                    reader?.register(target)
                    if let position = scrollPosition?.wrappedValue {
                        apply(position, anchor: scrollPositionAnchor)
                    }
                }
            }
            // not for a scroller around this one: its views aren't in that one's content
            .transformPreference(_FinchScrollTargetsKey.self) { $0 = [:] }
            // along the scrolling axes, the content's ideal size
            .fixedSize(horizontal: axes.contains(.horizontal), vertical: axes.contains(.vertical))
            .onChange(of: scrollPosition?.wrappedValue) { _, position in
                if let position { apply(position, anchor: scrollPositionAnchor) }
            }
            .onGeometryChange(for: CGSize.self, of: { $0.size }) {
                contentSize = $0
                target.contentSize = $0
                applyDefaultAnchorIfNeeded()
                if let position = scrollPosition?.wrappedValue { apply(position, anchor: scrollPositionAnchor) }
            }
            .onChange(of: scrollGeometry) { _, geometry in
                for observer in geometryObservers {
                    observer.report(geometry)
                }
                let moved = lastPositionOffset.map { $0 != geometry.contentOffset } ?? false
                lastPositionOffset = geometry.contentOffset
                if moved, let scrollPosition {
                    updateUserPosition(scrollPosition, geometry: geometry)
                }
            }
            .offset(x: -shown.x, y: -shown.y)
            // as small as offered along the scrolling axes (a frame is otherwise at least its
            // content's size); across them, the content's size
            .frame(minWidth: axes.contains(.horizontal) ? 0 : nil,
                   maxWidth: axes.contains(.horizontal) ? .infinity : nil,
                   minHeight: axes.contains(.vertical) ? 0 : nil,
                   maxHeight: axes.contains(.vertical) ? .infinity : nil,
                   alignment: contentAlignment)
            .onGeometryChange(for: CGSize.self, of: { $0.size }) {
                viewport = $0
                target.viewport = $0
                applyDefaultAnchorIfNeeded()
                if let position = scrollPosition?.wrappedValue { apply(position, anchor: scrollPositionAnchor) }
            }
        return Group {
            if clipDisabled {
                scrolledContent
            } else {
                scrolledContent.clipped()
            }
        }
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
                lastWheelVelocity = CGPoint(x: -dx, y: -dy)
                offsetState.wrappedValue = CGPoint(
                    x: _finchScrolledOffset(offsetState.wrappedValue.x, delta: dx, limit: limit.x,
                                            bounces: activeBounceAxes.contains(.horizontal)),
                    y: _finchScrolledOffset(offsetState.wrappedValue.y, delta: dy, limit: limit.y,
                                            bounces: activeBounceAxes.contains(.vertical)))
            }, scrollEnded: {
                let current = offsetState.wrappedValue
                var destination = CGPoint(x: min(max(0, current.x), limit.x), y: min(max(0, current.y), limit.y))
                if let scrollTargetBehavior {
                    var target = ScrollTarget(rect: CGRect(origin: destination, size: viewport))
                    let context = ScrollTargetBehaviorContext(
                        originalTarget: target,
                        velocity: CGVector(dx: lastWheelVelocity.x, dy: lastWheelVelocity.y),
                        contentSize: contentSize,
                        containerSize: viewport,
                        axes: axes,
                        targetRects: Array(scrollTargetFrames.values),
                        environment: environment)
                    scrollTargetBehavior.update(&target, context)
                    destination = target.anchor.map { self.target.offset(toShow: target.rect, anchor: $0, from: destination) }
                        ?? target.rect.origin
                    destination.x = min(max(0, destination.x), limit.x)
                    destination.y = min(max(0, destination.y), limit.y)
                }
                lastWheelVelocity = .zero
                let settled = destination
                guard settled != current else { return }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                    offsetState.wrappedValue = settled
                }
            }))
    }

    /// Set the initial offset once the scroll view knows both the content and viewport sizes.
    /// A bound ScrollPosition takes precedence and can still move the view afterward.
    private func applyDefaultAnchorIfNeeded() {
        guard viewport.width > 0, viewport.height > 0,
              contentSize.width > 0, contentSize.height > 0,
              scrollPosition?.wrappedValue == nil else { return }
        let anchor: UnitPoint?
        if appliedDefaultAnchor {
            anchor = scrollAnchor(for: .sizeChanges)
        } else {
            appliedDefaultAnchor = true
            anchor = scrollAnchor(for: .initialOffset)
        }
        guard let anchor else { return }
        let limit = maxOffset
        offset = CGPoint(x: limit.x * min(1, max(0, anchor.x)),
                         y: limit.y * min(1, max(0, anchor.y)))
    }

    private func scrollAnchor(for role: _FinchScrollAnchorRole) -> UnitPoint? {
        defaultScrollAnchors[role] ?? defaultScrollAnchor
    }

    private func apply(_ position: ScrollPosition, anchor: UnitPoint?) {
        guard !position.isPositionedByUser, position != appliedPosition else { return }
        guard (!axes.contains(.horizontal) || viewport.width > 0 && contentSize.width > 0),
              (!axes.contains(.vertical) || viewport.height > 0 && contentSize.height > 0) else { return }
        if let id = position._viewID, let rect = target.targets[id] {
            offset = target.offset(toShow: rect, anchor: position._anchor ?? anchor, from: offset)
            appliedPosition = position
            return
        }
        if let edge = position.edge {
            switch edge {
            case .top: offset.y = 0
            case .bottom: offset.y = max(0, contentSize.height - viewport.height)
            case .leading: offset.x = 0
            case .trailing: offset.x = max(0, contentSize.width - viewport.width)
            }
            appliedPosition = position
            return
        }
        if let point = position.point {
            offset = CGPoint(x: min(max(0, point.x), max(0, contentSize.width - viewport.width)),
                             y: min(max(0, point.y), max(0, contentSize.height - viewport.height)))
            appliedPosition = position
            return
        }
        if position._x != nil || position._y != nil {
            offset = CGPoint(x: min(max(0, position._x ?? offset.x), max(0, contentSize.width - viewport.width)),
                             y: min(max(0, position._y ?? offset.y), max(0, contentSize.height - viewport.height)))
            appliedPosition = position
        }
    }

    private func updateUserPosition(_ position: Binding<ScrollPosition>, geometry: ScrollGeometry) {
        guard !scrollTargetFrames.isEmpty else { return }
        let vertical = axes.contains(.vertical)
        let offset = vertical ? geometry.contentOffset.y : geometry.contentOffset.x
        let extent = vertical ? geometry.containerSize.height : geometry.containerSize.width
        let target = scrollTargetFrames
            .filter { entry in
                let start = vertical ? entry.value.minY : entry.value.minX
                let end = vertical ? entry.value.maxY : entry.value.maxX
                return end > offset && start < offset + extent
            }
            .min { lhs, rhs in
                let left = vertical ? lhs.value.minY : lhs.value.minX
                let right = vertical ? rhs.value.minY : rhs.value.minX
                return abs(left - offset) < abs(right - offset)
            }
        guard let target else { return }
        var value = position.wrappedValue
        value._finchSetVisibleID(target.key)
        guard value != position.wrappedValue else { return }
        position.wrappedValue = value
        appliedPosition = value
    }
}

private func _finchScrollAlignment(_ point: UnitPoint?) -> Alignment {
    guard let point else { return .topLeading }
    let horizontal: HorizontalAlignment = point.x < 0.25 ? .leading : point.x > 0.75 ? .trailing : .center
    let vertical: VerticalAlignment = point.y < 0.25 ? .top : point.y > 0.75 ? .bottom : .center
    return Alignment(horizontal: horizontal, vertical: vertical)
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
