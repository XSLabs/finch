// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Tips on screen: TipView (a tip inline: its image, title, message and actions, with a close
// button), popoverTip (the tip in a popover from a view while it's available), the tip view
// styles and the AppKit tip popover and view. A tip shown counts toward its display limits;
// closing it invalidates it.

import AppKit
import SwiftUI

// MARK: - Styles

@MainActor
@preconcurrency
public protocol TipViewStyle {
    typealias Configuration = TipViewStyleConfiguration
    associatedtype Body: View

    @ViewBuilder
    @MainActor
    @preconcurrency
    func makeBody(configuration: Configuration) -> Body
}

public struct TipViewStyleConfiguration {
    public let tip: any Tip
    let close: @MainActor () -> Void
    let perform: @MainActor (Tips.Action) -> Void
}

extension TipViewStyleConfiguration: @unchecked Sendable {}

extension TipViewStyleConfiguration {
    @MainActor public var image: Image? { tip.image }
    @MainActor public var title: Text? { tip.title }
    @MainActor public var message: Text? { tip.message }
    @MainActor public var actions: [Tips.Action] { tip.actions }
}

/// The standard tip: image beside title and message, actions below, a close button.
struct _DefaultTipViewStyle: TipViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                if let image = configuration.image {
                    image.font(.system(size: 28)).foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if let title = configuration.title {
                        title.font(.headline)
                    }
                    if let message = configuration.message {
                        message.font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Button(action: configuration.close) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            if !configuration.actions.isEmpty {
                Divider()
                ForEach(configuration.actions, id: \.id) { action in
                    Button(action: { configuration.perform(action) }) {
                        action.label()
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 360, alignment: .leading)
    }
}

@MainActor
@preconcurrency
public struct MiniTipViewStyle: TipViewStyle {
    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            if let image = configuration.image { image.foregroundStyle(Color.accentColor) }
            if let title = configuration.title { title.font(.callout) }
            Button(action: configuration.close) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(8)
    }
}

extension MiniTipViewStyle: Sendable {}

extension TipViewStyle where Self == MiniTipViewStyle {
    nonisolated public static var miniTip: MiniTipViewStyle { MiniTipViewStyle() }
}

struct _TipViewStyleKey: EnvironmentKey {
    static let defaultValue: (any TipViewStyle)? = nil
}

extension EnvironmentValues {
    var _tipViewStyle: (any TipViewStyle)? {
        get { self[_TipViewStyleKey.self] }
        set { self[_TipViewStyleKey.self] = newValue }
    }
}

extension View {
    nonisolated public func tipViewStyle(_ style: some TipViewStyle) -> some View {
        environment(\._tipViewStyle, style)
    }

    nonisolated public func tipBackground<S>(_ style: S) -> some View where S: ShapeStyle { self }
    nonisolated public func tipCornerRadius(_ cornerRadius: CGFloat, antialiased: Bool = true) -> some View { self }
    nonisolated public func tipAnchor<AnchorID>(_ id: AnchorID) -> some View where AnchorID: Hashable, AnchorID: Sendable { self }
    nonisolated public func tipBackgroundInteraction(_ interaction: PresentationBackgroundInteraction) -> some View { self }
    nonisolated public func tipImageSize(_ size: CGSize) -> some View { self }
    nonisolated public func tipImageStyle<S>(_ style: S) -> some View where S: ShapeStyle { self }
    nonisolated public func tipImageStyle<S1, S2>(_ primary: S1, _ secondary: S2) -> some View where S1: ShapeStyle, S2: ShapeStyle { self }
    nonisolated public func tipImageStyle<S1, S2, S3>(_ primary: S1, _ secondary: S2, _ tertiary: S3) -> some View
        where S1: ShapeStyle, S2: ShapeStyle, S3: ShapeStyle { self }
}

/// A tip as its style draws it.
struct _TipBody: View {
    var tip: any Tip
    var close: @MainActor () -> Void
    var perform: @MainActor (Tips.Action) -> Void
    @Environment(\._tipViewStyle) private var style

    var body: some View {
        let configuration = TipViewStyleConfiguration(tip: tip, close: close, perform: perform)
        if let style {
            AnyView(style.makeBody(configuration: configuration))
        } else {
            _DefaultTipViewStyle().makeBody(configuration: configuration)
        }
    }
}

/// Re-reads a tip's status when TipKit's records change.
@MainActor
final class _TipStatusModel: ObservableObject {
    @Published var available = false
    private var observer: NSObjectProtocol?
    var tip: (any Tip)?

    init() {
        observer = NotificationCenter.default.addObserver(forName: _TipStore.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() {
        let now = tip?.shouldDisplay ?? false
        if now != available { available = now }
    }
}

// MARK: - TipView

@MainActor
@preconcurrency
public struct TipView<Content>: View where Content: Tip {
    var tip: (any Tip)?
    var isPresented: Binding<Bool>?
    var action: @MainActor @Sendable (Tips.Action) -> Void
    @StateObject private var model = _TipStatusModel()

    public init(_ tip: (any Tip)?, isPresented: Binding<Bool>? = nil, arrowEdge: Edge? = nil,
                action: @escaping @MainActor @Sendable (Tips.Action) -> Void = { _ in }) where Content == AnyTip {
        self.tip = tip
        self.isPresented = isPresented
        self.action = action
    }

    public init<AnchorID>(_ tip: (any Tip)?, isPresented: Binding<Bool>? = nil, arrowEdge: Edge? = nil, anchorID: AnchorID,
                          action: @escaping @MainActor @Sendable (Tips.Action) -> Void = { _ in })
        where Content == AnyTip, AnchorID: Hashable, AnchorID: Sendable {
        self.tip = tip
        self.isPresented = isPresented
        self.action = action
    }

    @_disfavoredOverload
    public init(_ tip: (any Tip)?, arrowEdge: Edge? = nil,
                action: @escaping @MainActor @Sendable (Tips.Action) -> Void = { _ in }) where Content == AnyTip {
        self.init(tip, isPresented: nil, arrowEdge: arrowEdge, action: action)
    }

    public var body: some View {
        Group {
            if let tip, model.available, isPresented?.wrappedValue ?? true {
                _TipBody(tip: tip, close: {
                    tip.invalidate(reason: .tipClosed)
                    isPresented?.wrappedValue = false
                }, perform: action)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                .onAppear { tip.noteDisplayed() }
            }
        }
        .onAppear {
            model.tip = tip
            model.refresh()
        }
    }
}

extension TipView: Sendable {}

// MARK: - popoverTip

/// A popover with the tip while it's available.
struct _PopoverTipModifier: ViewModifier {
    var tip: (any Tip)?
    var isPresented: Binding<Bool>?
    var attachmentAnchor: PopoverAttachmentAnchor
    var arrowEdge: Edge?
    var action: @MainActor @Sendable (Tips.Action) -> Void
    @StateObject private var model = _TipStatusModel()
    @State private var dismissed = false

    func body(content: Content) -> some View {
        let shown = Binding<Bool>(
            get: { model.available && !dismissed && (isPresented?.wrappedValue ?? true) },
            set: { newValue in
                if !newValue {
                    dismissed = true
                    isPresented?.wrappedValue = false
                }
            })
        return content
            .popover(isPresented: shown, attachmentAnchor: attachmentAnchor, arrowEdge: arrowEdge ?? .top) {
                if let tip {
                    _TipBody(tip: tip, close: {
                        tip.invalidate(reason: .tipClosed)
                        shown.wrappedValue = false
                    }, perform: action)
                    .onAppear { tip.noteDisplayed() }
                }
            }
            .onAppear {
                model.tip = tip
                model.refresh()
            }
    }
}

extension View {
    @preconcurrency
    nonisolated public func popoverTip(_ tip: (any Tip)?, isPresented: Binding<Bool>? = nil,
                                       attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds), arrowEdge: Edge? = nil,
                                       action: @escaping @MainActor @Sendable (Tips.Action) -> Void = { _ in }) -> some View {
        modifier(_PopoverTipModifier(tip: tip, isPresented: isPresented, attachmentAnchor: attachmentAnchor,
                                     arrowEdge: arrowEdge, action: action))
    }

    @preconcurrency
    nonisolated public func popoverTip(_ tip: (any Tip)?, isPresented: Binding<Bool>? = nil,
                                       attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds), arrowEdges: Edge.Set,
                                       action: @escaping @MainActor @Sendable (Tips.Action) -> Void = { _ in }) -> some View {
        modifier(_PopoverTipModifier(tip: tip, isPresented: isPresented, attachmentAnchor: attachmentAnchor,
                                     arrowEdge: arrowEdges.contains(.top) ? .top : arrowEdges.contains(.bottom) ? .bottom
                                         : arrowEdges.contains(.leading) ? .leading : .trailing,
                                     action: action))
    }

    @_disfavoredOverload
    @preconcurrency
    nonisolated public func popoverTip(_ tip: (any Tip)?, arrowEdge: Edge? = nil,
                                       action: @escaping @MainActor @Sendable (Tips.Action) -> Void = { _ in }) -> some View {
        modifier(_PopoverTipModifier(tip: tip, isPresented: nil, attachmentAnchor: .rect(.bounds), arrowEdge: arrowEdge, action: action))
    }
}

// MARK: - AppKit

@MainActor
@preconcurrency
public final class TipNSPopover: NSPopover {
    public var backgroundStyle: any ShapeStyle = Color.clear
    public var backgroundColor: NSColor?
    public var cornerRadius: CGFloat = 10
    public var imageSize: CGSize = .zero
    public var imageStyle: (any ShapeStyle)?
    public var viewStyle: any TipViewStyle = MiniTipViewStyle()
    let tip: any Tip

    public required init(_ tip: any Tip, delegate: (any NSPopoverDelegate)? = nil,
                         actionHandler: @escaping @MainActor @Sendable (Tips.Action) -> Void = { _ in }) {
        self.tip = tip
        super.init()
        self.delegate = delegate
        behavior = .transient
        let close: @MainActor () -> Void = { [weak self] in
            tip.invalidate(reason: .tipClosed)
            self?.performClose(nil)
        }
        contentViewController = NSHostingController(rootView: _TipBody(tip: tip, close: close, perform: actionHandler))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var contentViewController: NSViewController? {
        get { super.contentViewController }
        set { super.contentViewController = newValue }
    }
}

@MainActor
@preconcurrency
public final class TipNSView: NSView {
    public var backgroundStyle: any ShapeStyle = Color.clear
    public var backgroundColor: NSColor?
    public var cornerRadius: CGFloat = 10
    public var imageSize: CGSize = .zero
    public var imageStyle: (any ShapeStyle)?
    public var viewStyle: any TipViewStyle = MiniTipViewStyle()

    public convenience init(_ tip: any Tip, arrowEdge: Edge? = nil,
                            actionHandler: @escaping @MainActor @Sendable (Tips.Action) -> Void = { _ in }) {
        self.init(frame: .zero)
        let hosting = NSHostingView(rootView: TipView(tip, arrowEdge: arrowEdge, action: actionHandler))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor), hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor), hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
