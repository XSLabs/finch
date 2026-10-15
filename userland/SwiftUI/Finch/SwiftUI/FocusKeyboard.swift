// SPDX-License-Identifier: MIT OR Apache-2.0
// Native macOS keyboard and focus support for pure SwiftUI focus targets.

#if os(macOS)
import AppKit
import ObjectiveC
import OpenAttributeGraphShims
@_spi(ForOpenSwiftUIOnly)
import OpenSwiftUICore

private enum FinchFocusAssociations {
    static var bridge: UInt8 = 0
    static var windowObserver: UInt8 = 0
    static var focusDisabled: UInt8 = 0
    static var colorSchemeOwner: UInt8 = 0  // the hosting view whose preferredColorScheme a window has
}

private final class FinchWindowFocusObserver {
    weak var bridge: FocusBridge?
    weak var window: NSWindow?
    private var observation: NSKeyValueObservation?

    init(window: NSWindow, bridge: FocusBridge) {
        self.window = window
        self.bridge = bridge
        observation = window.observe(\.firstResponder, options: [.new]) { [weak bridge] _, _ in
            DispatchQueue.main.async {
                bridge?.synchronizeFocusFromNativeResponder()
            }
        }
    }
}

private final class FinchWindowFocusObservers {
    var values: [ObjectIdentifier: FinchWindowFocusObserver] = [:]
}

protocol FinchFocusHosting: AnyObject, FocusBridgeProvider, FocusHost {
    func finchSetFocusedItem(_ item: FocusItem?)
    func finchFocusItem(for nativeView: NSView) -> FocusItem?
}

final class FinchFocusKeyView: NSView, FocusRingDelegate {
    weak var responder: ViewResponder?
    var focused = false {
        didSet {
            if oldValue != focused {
                needsDisplay = true
            }
        }
    }

    private lazy var ringHelper = FocusRingHelper(responder: responder, focusRingView: self)
    private var isForwardingKeyEvent = false

    var canShowFocusRing: Bool {
        focusResponderForAnchor != nil
    }

    init(responder: ViewResponder) {
        self.responder = responder
        super.init(frame: .zero)
        setFlipped(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { focusResponderForAnchor != nil }

    override var canBecomeKeyView: Bool { focusResponderForAnchor != nil }

    override var focusRingMaskBounds: NSRect {
        ringHelper.focusRingMaskBounds
    }

    override func drawFocusRingMask() {
        ringHelper.drawFocusRingMask()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let bridge = focusBridge else { return }
        if let window {
            bridge.observeFirstResponderChanges(in: window)
            bridge.refreshKeyViewLoop()
            if let item = bridge.host?.focusedItem,
               case .view = item.base,
               item.responder?.focusRingView === self,
               window.firstResponder !== self {
                window.makeFirstResponder(self)
            }
        } else {
            nextKeyView = nil
            bridge.clearFocus(ifOwnedBy: responder)
        }
    }

    override func becomeFirstResponder() -> Bool {
        guard let focusResponder = focusResponderForAnchor,
              let item = focusResponder.focusItem,
              case .view = item.base else {
            return false
        }
        let accepted = super.becomeFirstResponder()
        if accepted {
            focused = true
            focusBridge?.host?.focus(item: item)
            focusBridge?.refreshKeyViewLoop()
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let wasFocused = window?.firstResponder === self
        let resigned = super.resignFirstResponder()
        if resigned {
            focused = false
            if wasFocused {
                DispatchQueue.main.async { [weak self] in
                    self?.focusBridge?.synchronizeFocusFromNativeResponder()
                }
            }
        }
        return resigned
    }

    override func keyDown(with event: NSEvent) {
        handleKeyEvent(event, phase: event.isARepeat ? .repeat : .down) {
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        handleKeyEvent(event, phase: .up) {
            super.keyUp(with: event)
        }
    }

    private func handleKeyEvent(_ event: NSEvent, phase: KeyPress.Phases, fallback: () -> Void) {
        guard !isForwardingKeyEvent else { return }
        guard window?.firstResponder === self,
              dispatchKeyPress(event, phase: phase) else {
            isForwardingKeyEvent = true
            defer { isForwardingKeyEvent = false }
            fallback()
            return
        }
    }

    private func dispatchKeyPress(_ event: NSEvent, phase: KeyPress.Phases) -> Bool {
        guard let characters = event.charactersIgnoringModifiers,
              let character = characters.first,
              let focusResponder = focusResponderForAnchor else {
            return false
        }
        let keyPress = KeyPress(
            phase: phase,
            key: KeyEquivalent(character),
            characters: event.characters ?? characters,
            modifiers: EventModifiers(event.modifierFlags)
        )
        DefaultModifierKeySource.monitor.observe(keyPress.modifiers)
        // Environment handlers arrive from the outer view toward the focused child.
        // Walk backward so a child can handle the key first, then let ignored keys
        // reach handlers on its parents.
        for handler in focusResponder.keyPressHandlers.reversed() where handler.phases.contains(phase) {
            guard handlerMatches(handler, keyPress: keyPress) else { continue }
            if case .handled = handler.action(keyPress) {
                return true
            }
        }
        return false
    }

    private func handlerMatches(_ handler: KeyPress.Handler, keyPress: KeyPress) -> Bool {
        switch handler.subject {
        case let .keys(keys):
            keys.contains(keyPress.key)
        case let .characters(characters):
            keyPress.characters.unicodeScalars.contains(where: characters.contains)
        case .all:
            true
        }
    }

    private var focusBridge: FocusBridge? {
        responder?.host?.as(FocusBridgeProvider.self)?.focusBridge
    }

    private var focusResponderForAnchor: (any FocusResponder)? {
        guard let owner = responder as? ResponderNode else { return nil }
        if let focused = focusBridge?.host?.focusedItem?.responder,
           let focusedNode = focused as? ResponderNode,
           focusedNode.isDescendant(of: owner),
           focused.focusRingView === self,
           isEligibleForKeyboardFocus(focused) {
            return focused
        }
        var candidate: (any FocusResponder)?
        owner.visitFocusResponders { responder in
            guard responder.focusRingView === self,
                  isEligibleForKeyboardFocus(responder) else { return .next }
            candidate = responder
            return .cancel
        }
        return candidate
    }

    private func isEligibleForKeyboardFocus(_ responder: any FocusResponder) -> Bool {
        guard let item = responder.focusItem,
              case .view = item.base else { return false }
        if let focusable = responder as? FocusableViewResponder {
            return focusable.isEligibleForFocus && focusable.isInVisibleRect
        }
        return item.isFocusable && (item.receivesFocusFromKeyboard || item.receivesFocusFromMouse)
    }
}

extension NSHostingView: FocusBridgeProvider, FocusHost, FinchFocusHosting {
    var focusBridge: FocusBridge {
        if let bridge = objc_getAssociatedObject(self, &FinchFocusAssociations.bridge) as? FocusBridge {
            return bridge
        }
        let bridge = FocusBridge()
        bridge.finchHost = self
        objc_setAssociatedObject(self, &FinchFocusAssociations.bridge, bridge, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return bridge
    }

    var focusedItem: FocusItem? {
        guard let attribute = viewGraph[FocusViewGraph.self]?.pointee.$focusedItem else { return nil }
        return attribute.value ?? nil
    }

    var focusedValues: FocusedValues {
        get { viewGraph[FocusViewGraph.self]?.pointee.$focusedValues?.value ?? .init() }
        set {
            guard let attribute = viewGraph[FocusViewGraph.self]?.pointee.$focusedValues else { return }
            attribute.value = newValue
        }
    }

    var currentAccessibilityFocusStore: AccessibilityFocusStore {
        get { viewGraph[FocusViewGraph.self]!.pointee.$accessibilityFocusStore.value }
        set { viewGraph[FocusViewGraph.self]!.pointee.$accessibilityFocusStore.value = newValue }
    }

    func focus(item: FocusItem) {
        // `FocusItem` deliberately compares unequal, even when the target is
        // unchanged. AppKit can call this again while the graph is updating
        // after we make the focus anchor first responder, so compare identity
        // before writing the same target back into the graph.
        if focusedItem?.hasEqualIdentity(to: item) == true {
            return
        }
        finchSetFocusedItem(item)
    }

    func focusDidChange() {
        focusBridge.focusDidChange()
    }

    func finchSetFocusedItem(_ item: FocusItem?) {
        guard let attribute = viewGraph[FocusViewGraph.self]?.pointee.$focusedItem else { return }
        attribute.value = item
        focusBridge.updateFocusRingState()
        invalidateProperties(.focusedItem)
    }

    package var finchCurrentFocusedResponder: ResponderNode? {
        focusBridge.host?.focusedItem?.responder as? ResponderNode
    }

    package func finchFocusOnMouseDown(at point: CGPoint) {
        focusBridge.focusResponder(at: point)
    }

    func finchFocusItem(for nativeView: NSView) -> FocusItem? {
        var result: FocusItem?
        responderNode?.visit { node in
            guard let focusResponder = node as? any FocusResponder,
                  let item = focusResponder.focusItem,
                  item.isFocusable else { return .next }
            if let ringView = focusResponder.focusRingView,
               ringView === nativeView {
                result = item
                return .cancel
            }
            if let view = platformView(in: item),
               nativeView === view || nativeView.isDescendant(of: view) || view.isDescendant(of: nativeView) {
                result = item
                return .cancel
            }
            return .next
        }
        return result
    }

    private func platformView(in item: FocusItem) -> NSView? {
        guard case let .platformResponder(box) = item.base else { return nil }
        return box.base
    }
}

extension NSHostingView {
    @_spi(ForOpenSwiftUIOnly)
    @available(OpenSwiftUI_v6_0, *)
    public func preferencesDidChange() {
        // FocusState registrations and their focused flags are host preferences.
        // Rebuild the store when SwiftUI reports that those preferences changed.
        invalidateProperties(.focusStore)
        applyPreferredColorScheme()
    }

    /// preferredColorScheme, as Apple's: the window takes that appearance (and so does the
    /// content, whose colour scheme follows its appearance); back to its own when the
    /// preference goes, if it was this view that set it.
    package func applyPreferredColorScheme() {
        guard let window else { return }
        let owner = objc_getAssociatedObject(window, &FinchFocusAssociations.colorSchemeOwner) as AnyObject?
        switch preferenceValue(PreferredColorSchemeKey.self) {
        case let scheme?:
            let name: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
            // (after this update: the change rebuilds this view's environment, which an update
            // in progress would overwrite)
            if window.appearance?.name != name {
                DispatchQueue.main.async { [weak window] in window?.appearance = NSAppearance(named: name) }
            }
            objc_setAssociatedObject(window, &FinchFocusAssociations.colorSchemeOwner, self, .OBJC_ASSOCIATION_ASSIGN)
        case nil where owner === self:
            DispatchQueue.main.async { [weak window] in window?.appearance = nil }
            objc_setAssociatedObject(window, &FinchFocusAssociations.colorSchemeOwner, nil, .OBJC_ASSOCIATION_ASSIGN)
        case nil:
            break
        }
    }

    package func updateFocusStore() {
        guard let attribute = viewGraph[FocusViewGraph.self]?.pointee.$focusStore else { return }
        attribute.value = FocusStore(preferenceValue(FocusStoreList.Key.self))
    }

    package func updateFocusedItem() {
        focusBridge.updateFocusRingState()
        focusBridge.updateNativeFirstResponder()
    }

    package func updateFocusedValues() {
        if let values = viewGraph[FocusViewGraph.self]?.pointee.$focusedValues?.value {
            focusedValues = values
        }
    }
}

extension FocusBridge {
    func observeFirstResponderChanges(in window: NSWindow) {
        let observers: FinchWindowFocusObservers
        if let existing = objc_getAssociatedObject(window, &FinchFocusAssociations.windowObserver) as? FinchWindowFocusObservers {
            observers = existing
        } else {
            observers = FinchWindowFocusObservers()
            objc_setAssociatedObject(window, &FinchFocusAssociations.windowObserver, observers, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        let identifier = ObjectIdentifier(self)
        if let observer = observers.values[identifier], observer.window === window { return }
        let observer = FinchWindowFocusObserver(window: window, bridge: self)
        observers.values[identifier] = observer
    }

    func synchronizeFocusFromNativeResponder() {
        guard let host,
              let focusHost = host as? any FinchFocusHosting,
              let window = host.window else { return }
        let nativeResponder: NSView?
        if let fieldEditor = window.firstResponder as? NSTextView,
                  let delegate = fieldEditor.delegate as? NSView {
            nativeResponder = delegate
        } else if let view = window.firstResponder as? NSView {
            nativeResponder = view
        } else {
            nativeResponder = nil
        }
        guard let nativeResponder else {
            if (window.firstResponder == nil || window.firstResponder === window),
               let ringView = host.focusedItem?.responder?.focusRingView as? FinchFocusKeyView,
               ringView.isDescendant(of: host) {
                focusHost.finchSetFocusedItem(nil)
            }
            return
        }
        if host.focusedItem?.responder?.focusRingView === nativeResponder {
            return
        }
        if let item = focusHost.finchFocusItem(for: nativeResponder) {
            if host.focusedItem?.hasEqualIdentity(to: item) == true { return }
            focusHost.finchSetFocusedItem(item)
        } else if nativeResponder === host || nativeResponder.isDescendant(of: host) {
            focusHost.finchSetFocusedItem(nil)
        }
    }

    func updateFocusRingState() {
        let focusedRing = host?.focusedItem?.responder?.focusRingView
        host?.responderNode?.visitFocusResponders { responder in
            responder.focusRingView?.focused = responder.focusRingView === focusedRing
            return .next
        }
        refreshKeyViewLoop()
    }

    func updateNativeFirstResponder() {
        guard let host, let window = host.window else { return }
        observeFirstResponderChanges(in: window)
        guard let item = host.focusedItem else {
            if let firstResponder = window.firstResponder as? NSView,
               firstResponder is FinchFocusKeyView,
               firstResponder.isDescendant(of: host) {
                window.makeFirstResponder(nil)
            }
            return
        }
        let target: NSView?
        if case let .platformResponder(box) = item.base {
            target = box.base?.firstFocusableDescendant
        } else {
            target = item.responder?.focusRingView
        }
        guard let target, target.window === window else { return }
        if let current = nativeView(for: window.firstResponder),
           current === target || current.isDescendant(of: target) || target.isDescendant(of: current) {
            return
        }
        window.makeFirstResponder(target)
    }

    private func nativeView(for responder: NSResponder?) -> NSView? {
        if let editor = responder as? NSTextView,
           let delegate = editor.delegate as? NSView {
            return delegate
        }
        return responder as? NSView
    }

    func clearFocus(ifOwnedBy responder: ViewResponder?) {
        guard let host,
              let focusHost = host as? any FinchFocusHosting,
              let focusedItem = host.focusedItem else { return }
        if let responder,
           let owner = responder as? ResponderNode,
           let focused = focusedItem.responder as? ResponderNode,
           !focused.isDescendant(of: owner) {
            return
        }
        focusHost.finchSetFocusedItem(nil)
    }

    func refreshKeyViewLoop() {
        guard let host, let window = host.window, let root = host.responderNode else { return }
        var candidates: [NSView] = []
        var seen = Set<ObjectIdentifier>()
        root.visitFocusResponders { responder in
            guard let item = responder.focusItem,
                  item.isFocusable,
                  item.receivesFocusFromKeyboard,
                  responder.isEnabled,
                  responder.isInVisibleRect else { return .next }
            if let focusable = responder as? FocusableViewResponder,
               !focusable.isEligibleForFocus {
                return .next
            }
            let keyView: NSView?
            switch item.base {
            case .view:
                keyView = responder.focusRingView
            case let .platformResponder(box):
                if let view = box.base {
                    keyView = view.firstFocusableDescendant ?? (view.canBecomeKeyView ? view : nil)
                } else {
                    keyView = nil
                }
            case .platformItem:
                keyView = nil
            }
            guard let keyView, keyView.window === window,
                  seen.insert(ObjectIdentifier(keyView)).inserted else { return .next }
            candidates.append(keyView)
            return .next
        }
        for index in candidates.indices {
            candidates[index].nextKeyView = candidates.count > 1
                ? candidates[(index + 1) % candidates.count]
                : candidates[index]
        }
    }

    func focusResponder(at point: CGPoint) {
        guard let host, let root = host.responderNode else { return }
        var best: FocusableViewResponder?
        root.visitFocusResponders { responder in
            guard let responder = responder as? FocusableViewResponder,
                  responder.isEligibleForFocus,
                  responder.focusItem?.receivesFocusFromMouse == true,
                  let frame = responder.frame,
                  frame.contains(point) else { return .next }
            if let bestFrame = best?.frame {
                if frame.width * frame.height <= bestFrame.width * bestFrame.height {
                    best = responder
                }
            } else {
                best = responder
            }
            return .next
        }
        guard let item = best?.focusItem else { return }
        moveFocus(to: item, designatedPlatformResponder: nil)
    }

    func focusDidChange() {
        guard let host else { return }
        if let item = host.focusedItem,
           let responder = item.responder as? FocusableViewResponder,
           !responder.isEligibleForFocus {
            clearFocus(ifOwnedBy: responder)
        }
        updateFocusRingState()
        updateNativeFirstResponder()
    }
}

enum FinchFocusBridgeSupport {
    static func moveFocus(
        _ bridge: FocusBridge,
        to item: FocusItem,
        designatedPlatformResponder: NSView?
    ) {
        guard let host = bridge.host else { return }
        host.focus(item: item)
        let target: NSView?
        if let designatedPlatformResponder {
            target = designatedPlatformResponder
        } else if case let .platformResponder(box) = item.base {
            target = box.base?.firstFocusableDescendant
        } else {
            target = item.responder?.focusRingView
        }
        guard let target, let window = host.window, target.window === window else { return }
        bridge.observeFirstResponderChanges(in: window)
        window.makeFirstResponder(target)
    }

    static func defaultFocusItem(for responder: any BaseFocusResponder) -> FocusItem? {
        var result: FocusItem?
        responder.visitBaseFocusResponders { candidate in
            guard let candidate = candidate as? any FocusResponder,
                  let item = candidate.focusItem,
                  item.isFocusable else { return .next }
            if let pureResponder = candidate as? FocusableViewResponder,
               !pureResponder.isEligibleForFocus {
                return .next
            }
            if let baseResponder = candidate as? any BaseFocusResponder,
               !baseResponder.isEnabled {
                return .next
            }
            let canReceiveClientUpdate: Bool
            if case let .view(view) = item.base {
                canReceiveClientUpdate = view.options.contains(.fromClientUpdate)
            } else {
                canReceiveClientUpdate = false
            }
            guard item.receivesFocusFromKeyboard || item.receivesFocusFromMouse || canReceiveClientUpdate else {
                return .next
            }
            result = item
            return .cancel
        }
        return result
    }
}

extension FocusableViewResponder {
    var isEligibleForFocus: Bool {
        baseItem?.isFocusable == true && isEnabled && !isFocusDisabled
    }

    var isFocusDisabled: Bool {
        get { _finchFocusDisabled }
        set { _finchFocusDisabled = newValue }
    }

    private var _finchFocusDisabled: Bool {
        get { objc_getAssociatedObject(self, &FinchFocusAssociations.focusDisabled) as? Bool ?? false }
        set { objc_setAssociatedObject(self, &FinchFocusAssociations.focusDisabled, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

#endif
