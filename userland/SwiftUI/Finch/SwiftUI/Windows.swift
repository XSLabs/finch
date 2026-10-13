// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Window scenes, openWindow and dismissWindow, windowResizability and defaultSize, to
// Apple's interface. An app's windows are its scenes' windows: the first window scene's opens
// as the app launches; openWindow(id:) opens another for the scene with that id (a Window
// scene, which is one window, is brought to the front if it's open); dismissWindow closes them.
// Windows size themselves to their content, so resizability and default sizes change nothing
// yet.

import AppKit
import OpenAttributeGraphShims
@_spi(ForOpenSwiftUIOnly)
import SwiftUICore

// MARK: - Opening windows

@MainActor
enum _FinchWindows {
    /// The open windows' controllers, and the scene each shows.
    private static var open: [(id: SceneID, controller: NSWindowController)] = []
    /// The ids of Window scenes (each one window).
    static var singleWindowIDs: Set<String> = []

    private static var items: [SceneList.Item] { AppGraph.shared?.rootSceneList?.items ?? [] }

    /// Opens a window for a scene.
    @discardableResult
    static func open(_ item: SceneList.Item) -> NSWindowController {
        Update.begin()
        defer { Update.end() }
        // The scene stores app values, including environment objects, separately from its view.
        let rootView = item.value.view
            ._finchInheriting(item.environment)
            .rootEnvironment()
        let hostingVC = NSHostingController(rootView: rootView)
        let initialSize = initialContentSize(for: hostingVC)
        hostingVC.preferredContentSize = initialSize
        hostingVC.view.setFrameSize(initialSize)
        dumpViewSize("initial preferred", initialSize)
        let windowVC = WindowController(hostingVC)
        let title: String
        if case let .windowGroup(configuration) = item.value, let text = configuration.title {
            title = text._resolveText(in: EnvironmentValues())
        } else {
            title = currentAppName()
        }
        windowVC.window?.title = title
        if let window = windowVC.window { _FinchWindowOptions.current.apply(to: window) }
        if shouldDumpViewSizing {
            dumpWindowSizing("pre-show", hostingVC: hostingVC, window: windowVC.window, preferred: initialSize,
                             fitting: hostingVC.view.fittingSize)
        }
        windowVC.showWindow(nil)
        // the window at its content's size, centered (a window opened later doesn't take it
        // from its controller by itself)
        if let window = windowVC.window {
            let size = hostingVC.view.fittingSize
            dumpWindowSizing("post-show", hostingVC: hostingVC, window: window, preferred: initialSize, fitting: size)
            if size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
               window.contentRect(forFrameRect: window.frame).size != size {
                window.setContentSize(size)
                window.center()
            }
            dumpWindowSizing("post-size", hostingVC: hostingVC, window: window, preferred: initialSize, fitting: size)
            if shouldDumpViewSizing {
                let measured = hostingVC.host.sizeThatFits(_ProposedSize(width: window.contentView?.bounds.width, height: nil))
                dumpViewSize("post-show measured at window width", measured)
                if let bounds = window.contentView?.bounds.size {
                    dumpViewSize("post-show measured at window size",
                                 hostingVC.host.sizeThatFits(_ProposedSize(width: bounds.width, height: bounds.height)))
                }
                DispatchQueue.main.async {
                    let measured = hostingVC.host.sizeThatFits(_ProposedSize(width: window.contentView?.bounds.width, height: nil))
                    dumpViewSize("next-turn measured at window width", measured)
                }
            }
        }
        // and again: showing the window titles it after its controller
        windowVC.window?.title = title
        open.removeAll { $0.controller.window?.isVisible != true }
        open.append((item.id, windowVC))
        return windowVC
    }

    /// Gives AppKit a finite starting size before it asks the hosting view for its intrinsic size.
    private static func initialContentSize<Content: View>(for hostingVC: NSHostingController<Content>) -> NSSize {
        let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        let proposalWidth = visibleFrame.width.isFinite && visibleFrame.width > 0
            ? min(500, visibleFrame.width)
            : 500
        let proposalHeight = visibleFrame.height.isFinite && visibleFrame.height > 0
            ? min(600, visibleFrame.height)
            : 600
        // as Apple's hosting view: the content's ideal size, when it has one
        let ideal = hostingVC.host.sizeThatFits(_ProposedSize(width: nil, height: nil))
        dumpViewSize("ideal", ideal)
        if shouldDumpViewSizing {
            dumpViewSize("minimum", hostingVC.host.sizeThatFits(_ProposedSize(width: 0, height: 0)))
            dumpViewSize("maximum", hostingVC.host.sizeThatFits(_ProposedSize(width: .infinity, height: .infinity)))
            dumpViewSize("ideal width at height nil, width 0", hostingVC.host.sizeThatFits(_ProposedSize(width: 0, height: nil)))
        }
        if _FinchWindowOptions.current.sizedToContent, ideal.width.isFinite, ideal.width > 0, ideal.width <= visibleFrame.width || visibleFrame.width <= 0,
           ideal.height.isFinite, ideal.height > 0, ideal.height <= visibleFrame.height || visibleFrame.height <= 0 {
            return ideal
        }
        let natural = hostingVC.host.sizeThatFits(_ProposedSize(width: proposalWidth, height: nil))
        dumpViewSize("natural", natural)
        if natural.width.isFinite, natural.width > 0, natural.height.isFinite, natural.height > 0 {
            return NSSize(width: natural.width, height: natural.height)
        }

        // Some flexible roots have no natural height. Measure them again inside a finite viewport.
        let viewport = hostingVC.host.sizeThatFits(_ProposedSize(width: proposalWidth, height: proposalHeight))
        dumpViewSize("viewport", viewport)
        let width = viewport.width.isFinite && viewport.width > 0 ? viewport.width : proposalWidth
        let height = viewport.height.isFinite && viewport.height > 0 ? viewport.height : proposalHeight
        return NSSize(width: width, height: height)
    }

    private static var shouldDumpViewSizing: Bool {
        ProcessInfo.processInfo.environment["FINCH_DUMP_VIEWS"] == "1"
    }

    private static func dumpViewSize(_ label: String, _ size: NSSize) {
        guard shouldDumpViewSizing else { return }
        writeSizeTrace("FINCH_DUMP_VIEWS \(label): \(String(describing: size))")
    }

    private static func writeSizeTrace(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func dumpWindowSizing<Content: View>(
        _ label: String,
        hostingVC: NSHostingController<Content>,
        window: NSWindow?,
        preferred: NSSize,
        fitting: NSSize
    ) {
        guard shouldDumpViewSizing else { return }
        let frameSize = window.map { String(describing: $0.frame.size) } ?? "nil"
        let contentSize = window.map { String(describing: $0.contentRect(forFrameRect: $0.frame).size) } ?? "nil"
        writeSizeTrace("FINCH_DUMP_VIEWS \(label): preferred=\(String(describing: preferred)) " +
              "frame=\(frameSize) content=\(contentSize) " +
              "view=\(String(describing: hostingVC.view.frame.size)) " +
              "fitting=\(String(describing: fitting))")
    }

    /// The window the app opens as it launches: its first window scene's.
    static func openFirst() -> NSWindowController? {
        guard let item = items.first(where: { if case .settings = $0.value { false } else { true } }) else { return nil }
        return open(item)
    }

    /// Opens a window for the scene with an id (or brings a Window scene's to the front), after
    /// the update the request came in (an action), as a new window's graph can't be made in it.
    static func open(id: String) {
        DispatchQueue.main.async { openNow(id: id) }
    }

    private static func openNow(id: String) {
        guard let item = items.first(where: { $0.id == .string(id) }) else { return }
        if singleWindowIDs.contains(id),
           let existing = open.first(where: { $0.id == .string(id) && $0.controller.window?.isVisible == true }) {
            existing.controller.window?.makeKeyAndOrderFront(nil)
            return
        }
        open(item)
    }

    /// Opens a window for the first window group.
    static func openFirstGroup() {
        DispatchQueue.main.async { openFirstGroupNow() }
    }

    private static func openFirstGroupNow() {
        if let item = items.first(where: { if case .windowGroup = $0.value { true } else { false } }) {
            open(item)
        }
    }

    static func close(id: String?) {
        if let id {
            for entry in open where entry.id == .string(id) { entry.controller.window?.performClose(nil) }
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }
}

// MARK: - Window

@available(OpenSwiftUI_v4_0, *)
@MainActor
@preconcurrency
public struct Window<Content>: Scene where Content: View {
    var title: Text
    var id: String
    var content: Content

    public init(_ title: Text, id: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.id = id
        self.content = content()
    }

    public init(_ titleKey: LocalizedStringKey, id: String, @ViewBuilder content: () -> Content) {
        self.init(Text(titleKey), id: id, content: content)
    }

    @_disfavoredOverload
    public init<S>(_ title: S, id: String, @ViewBuilder content: () -> Content) where S: StringProtocol {
        self.init(Text(title), id: id, content: content)
    }

    @MainActor
    @preconcurrency
    public var body: some Scene {
        _FinchWindows.singleWindowIDs.insert(id)
        return WindowSceneList(
            configuration: WindowSceneConfiguration(
                attributes: WindowGroupConfigurationAttributes(),
                mainContent: AnyView(content),
                title: title,
                presentationDataType: nil,
                decoder: nil),
            id: id,
            contentType: Content.self)
    }
}

@available(*, unavailable) extension Window: Sendable {}

// MARK: - openWindow and dismissWindow

@available(OpenSwiftUI_v4_0, *)
@MainActor
@preconcurrency
public struct OpenWindowAction {
    @available(OpenSwiftUI_v6_0, *)
    public struct SharingBehavior: Sendable {
        public static let requested = SharingBehavior()
        public static let required = SharingBehavior()
    }

    public func callAsFunction(id: String) {
        _FinchWindows.open(id: id)
    }

    public func callAsFunction<D>(value: D) where D: Decodable, D: Encodable, D: Hashable {
        _FinchWindows.openFirstGroup()
    }

    public func callAsFunction<D>(id: String, value: D) where D: Decodable, D: Encodable, D: Hashable {
        _FinchWindows.open(id: id)
    }

    @available(OpenSwiftUI_v6_0, *)
    public func callAsFunction(id: String, sharingBehavior: SharingBehavior) async throws {
        _FinchWindows.open(id: id)
    }

    @available(OpenSwiftUI_v6_0, *)
    public func callAsFunction<D>(value: D, sharingBehavior: SharingBehavior) async throws
        where D: Decodable, D: Encodable, D: Hashable {
        _FinchWindows.openFirstGroup()
    }

    @available(OpenSwiftUI_v6_0, *)
    public func callAsFunction<D>(id: String, value: D, sharingBehavior: SharingBehavior) async throws
        where D: Decodable, D: Encodable, D: Hashable {
        _FinchWindows.open(id: id)
    }
}

@available(OpenSwiftUI_v4_0, *)
@MainActor
@preconcurrency
public struct DismissWindowAction {
    public func callAsFunction() {
        _FinchWindows.close(id: nil)
    }

    public func callAsFunction(id: String) {
        _FinchWindows.close(id: id)
    }

    public func callAsFunction<D>(value: D) where D: Decodable, D: Encodable, D: Hashable {
        _FinchWindows.close(id: nil)
    }

    public func callAsFunction<D>(id: String, value: D) where D: Decodable, D: Encodable, D: Hashable {
        _FinchWindows.close(id: id)
    }
}

@available(OpenSwiftUI_v4_0, *)
extension EnvironmentValues {
    public var openWindow: OpenWindowAction { OpenWindowAction() }

    public var dismissWindow: DismissWindowAction { DismissWindowAction() }
}

// MARK: - Window sizes

@available(OpenSwiftUI_v4_0, *)
public struct WindowResizability: Sendable {
    enum Kind { case automatic, contentSize, contentMinSize }
    var kind: Kind

    public static var automatic: WindowResizability {
        get { .init(kind: .automatic) }
        set {}
    }

    public static var contentSize: WindowResizability {
        get { .init(kind: .contentSize) }
        set {}
    }

    public static var contentMinSize: WindowResizability {
        get { .init(kind: .contentMinSize) }
        set {}
    }
}

/// A scene modifier that leaves the scene as it is.
struct _FinchPassThroughSceneModifier: PrimitiveSceneModifier {
    nonisolated static func _makeScene(modifier: _GraphValue<Self>, inputs: _SceneInputs,
                                       body: @escaping (_Graph, _SceneInputs) -> _SceneOutputs) -> _SceneOutputs {
        body(_Graph(), inputs)
    }
}

@available(OpenSwiftUI_v4_0, *)
extension Scene {
    nonisolated public func windowResizability(_ resizability: WindowResizability) -> some Scene {
        modifier(_FinchWindowOptionsModifier(value: resizability.kind == .contentSize) { options, sized in
            options.sizedToContent = sized
        })
    }

    nonisolated public func defaultSize(_ size: CGSize) -> some Scene {
        modifier(_FinchPassThroughSceneModifier())
    }

    nonisolated public func defaultSize(width: CGFloat, height: CGFloat) -> some Scene {
        modifier(_FinchPassThroughSceneModifier())
    }
}
