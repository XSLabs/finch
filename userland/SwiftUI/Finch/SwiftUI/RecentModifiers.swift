// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Smaller pieces of SwiftUI's interface that apps on macOS 26 use (Calculator among them):
// modifier-key changes, safe-area bars, toolbars of views, swipe actions and presentation
// detents (which do nothing on macOS), accessibility attributes, Solarium, LazyState2 (state
// whose initial value is made when first read) and the performance-test hooks (no test runs
// in Finch).

public import Accessibility
import AppKit
import OpenAttributeGraphShims
@_spi(ForOpenSwiftUIOnly)
import SwiftUICore

// MARK: - Modifier keys

/// Tells its action when the modifier keys held down change.
struct _FinchModifierKeysMonitor: NSViewRepresentable {
    var mask: EventModifiers
    var initial: Bool
    var action: (EventModifiers, EventModifiers) -> Void

    final class Coordinator {
        var monitor: Any?
        var current: EventModifiers = []
        var parent: _FinchModifierKeysMonitor?

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> EventModifiers {
        var m: EventModifiers = []
        if flags.contains(.capsLock) { m.insert(.capsLock) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.numericPad) { m.insert(.numericPad) }
        if flags.contains(.function) { m.insert(.function) }
        return m
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.current = Self.modifiers(NSEvent.modifierFlags).intersection(mask)
        if initial {
            let now = coordinator.current
            DispatchQueue.main.async { action([], now) }
        }
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak coordinator] event in
            guard let coordinator, let parent = coordinator.parent else { return event }
            let new = Self.modifiers(event.modifierFlags).intersection(parent.mask)
            if new != coordinator.current {
                let old = coordinator.current
                coordinator.current = new
                parent.action(old, new)
            }
            return event
        }
        return NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.parent = self
    }
}

@available(OpenSwiftUI_v5_0, *)
extension View {
    nonisolated public func onModifierKeysChanged(mask: EventModifiers = .all, initial: Bool = true,
                                                  _ action: @escaping (EventModifiers, EventModifiers) -> Void) -> some View {
        background(_FinchModifierKeysMonitor(mask: mask, initial: initial, action: action).allowsHitTesting(false))
    }
}

// MARK: - Bars, toolbars, swipe actions, detents

@available(OpenSwiftUI_v7_0, *)
extension View {
    /// A bar along an edge of the safe area: the view inset by it, the bar in the inset.
    nonisolated public func safeAreaBar(edge: VerticalEdge, alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil,
                                        @ViewBuilder content: () -> some View) -> some View {
        safeAreaInset(edge: edge, alignment: alignment, spacing: spacing, content: content)
    }

    nonisolated public func safeAreaBar(edge: HorizontalEdge, alignment: VerticalAlignment = .center, spacing: CGFloat? = nil,
                                        @ViewBuilder content: () -> some View) -> some View {
        safeAreaInset(edge: edge, alignment: alignment, spacing: spacing, content: content)
    }

    nonisolated public func scrollEdgeEffectDisabled(_ disabled: Bool) -> some View {
        self
    }
}

@available(OpenSwiftUI_v2_0, *)
extension View {
    /// Views as the window's toolbar items.
    nonisolated public func toolbar<Content>(@ViewBuilder content: () -> Content) -> some View where Content: View {
        let views = content()
        return toolbar {
            ToolbarItemGroup(placement: .automatic) { views }
        }
    }
}

@available(OpenSwiftUI_v3_0, *)
extension View {
    /// Swipe actions are for touch; on macOS a row has none.
    nonisolated public func swipeActions<T>(edge: HorizontalEdge = .trailing, allowsFullSwipe: Bool = true,
                                            @ViewBuilder content: () -> T) -> some View where T: View {
        self
    }
}

@available(OpenSwiftUI_v4_0, *)
public struct PresentationDetent: Hashable, Sendable {
    enum Kind: Hashable { case medium, large, fraction(CGFloat), height(CGFloat), custom(ObjectIdentifier) }
    var kind: Kind

    public static let medium = PresentationDetent(kind: .medium)
    public static let large = PresentationDetent(kind: .large)

    public static func fraction(_ fraction: CGFloat) -> PresentationDetent {
        PresentationDetent(kind: .fraction(fraction))
    }

    public static func height(_ height: CGFloat) -> PresentationDetent {
        PresentationDetent(kind: .height(height))
    }
}

@available(OpenSwiftUI_v4_0, *)
extension View {
    /// Detents size sheets on iOS; macOS sheets size to their content.
    nonisolated public func presentationDetents(_ detents: Set<PresentationDetent>) -> some View {
        self
    }

    nonisolated public func presentationDetents(_ detents: Set<PresentationDetent>, selection: Binding<PresentationDetent>) -> some View {
        self
    }
}

// MARK: - Accessibility

@available(OpenSwiftUI_v2_0, *)
@frozen
public struct _AccessibilityIgnoresInvertColorsViewModifier: ViewModifier, PrimitiveViewModifier {
    public var active: Bool

    @inlinable
    public init(active: Bool) { self.active = active }

    nonisolated public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs,
                                             body: @escaping (_Graph, _ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        body(_Graph(), inputs)
    }

    nonisolated public static func _makeViewList(modifier: _GraphValue<Self>, inputs: _ViewListInputs,
                                                 body: @escaping (_Graph, _ViewListInputs) -> _ViewListOutputs) -> _ViewListOutputs {
        body(_Graph(), inputs)
    }

    public typealias Body = Never
}

@available(OpenSwiftUI_v2_0, *)
extension View {
    @inlinable
    nonisolated public func accessibilityIgnoresInvertColors(_ active: Bool = true) -> some View {
        modifier(_AccessibilityIgnoresInvertColorsViewModifier(active: active))
    }
}

@available(OpenSwiftUI_v3_0, *)
extension ModifiedContent where Modifier == AccessibilityAttachmentModifier {
    /// An attribute for assistive apps (Finch's accessibility doesn't carry custom ones).
    nonisolated public func accessibilityCustomAttribute(_ name: String, value: String) -> ModifiedContent<Content, AccessibilityAttachmentModifier> {
        self
    }

    nonisolated public func accessibilityCustomAttribute(_ name: String, value: Bool) -> ModifiedContent<Content, AccessibilityAttachmentModifier> {
        self
    }

    nonisolated public func accessibilityCustomAttribute(_ name: String, value: NSObject) -> ModifiedContent<Content, AccessibilityAttachmentModifier> {
        self
    }

    nonisolated public func accessibilityCustomContent(_ labelKey: LocalizedStringKey, _ value: Text,
                                                       importance: AXCustomContent.Importance = .default) -> ModifiedContent<Content, AccessibilityAttachmentModifier> {
        self
    }
}

// MARK: - Solarium

@available(OpenSwiftUI_v7_0, *)
extension Solarium {
    public static var isEnabled: Bool { true }
}

// MARK: - LazyState2

/// State whose initial value is made when it's first read, and kept.
final class _FinchLazyStateBox<Value> {
    private var make: (() -> Value)?
    private var stored: Value?

    init(_ make: @escaping () -> Value) {
        self.make = make
    }

    var value: Value {
        get {
            if let stored { return stored }
            let v = make!()
            stored = v
            make = nil
            return v
        }
        set { stored = newValue }
    }
}

@available(OpenSwiftUI_v6_0, *)
@propertyWrapper
public struct LazyState2<Value>: DynamicProperty {
    @State private var box: _FinchLazyStateBox<Value>
    @State private var generation = 0

    public init(wrappedValue: @autoclosure @escaping () -> Value) {
        _box = State(wrappedValue: _FinchLazyStateBox(wrappedValue))
    }

    public var wrappedValue: Value {
        get {
            _ = generation
            return box.value
        }
        nonmutating set {
            box.value = newValue
            generation &+= 1
        }
    }

    public var projectedValue: Binding<Value> {
        let box = box, generation = $generation
        return Binding(get: { box.value }, set: { box.value = $0; generation.wrappedValue &+= 1 })
    }
}

// MARK: - Performance tests

/// A performance test an app runs when the test harness asks it to. No harness runs in Finch,
/// so no test starts.
@available(OpenSwiftUI_v2_0, *)
public struct PPTTestCase {
    public struct Name: Hashable {
        var rawValue: String
        public init(_ rawValue: String) { self.rawValue = rawValue }
    }

    var name: Name

    public var parameters: [AnyHashable: Any] { [:] }
    public func startTest() {}
    public func finishTest() {}
    public func performResizeTest(onComplete: ((PPTTestCase) -> Void)?) { onComplete?(self) }
    public func performScrollTest(_ proxy: ScrollViewProxy, onComplete: ((PPTTestCase) -> Void)?) { onComplete?(self) }
}

@available(OpenSwiftUI_v2_0, *)
extension View {
    nonisolated public func onTest(_ name: PPTTestCase.Name, handler: @escaping (PPTTestCase) -> Void) -> some View {
        self
    }
}
