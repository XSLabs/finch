// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Drop delegates and onDrop(of:delegate:), and onDrag, to Apple's interface. A drop target
// is an AppKit view over the content, registered for the content types' pasteboard types:
// it takes part in hit testing only while a drag is under way (clicks go through to the
// content), and turns AppKit's dragging calls into the delegate's, with the item providers
// read from the dragging pasteboard.

public import AppKit
public import Foundation
import OpenAttributeGraphShims
@_spi(ForOpenSwiftUIOnly)
import SwiftUICore
public import UniformTypeIdentifiers

@available(OpenSwiftUI_v1_0, *)
public enum DropOperation: Sendable {
    case cancel, forbidden, copy, move, delete, alias

    public struct Set: OptionSet, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let cancel = Set(rawValue: 1 << 0)
        public static let copy = Set(rawValue: 1 << 1)
        public static let move = Set(rawValue: 1 << 2)
        public static let forbidden = Set(rawValue: 1 << 3)
        public static let delete = Set(rawValue: 1 << 4)
        public static let alias = Set(rawValue: 1 << 5)
    }

    var dragOperation: NSDragOperation {
        switch self {
        case .cancel, .forbidden: []
        case .copy: .copy
        case .move: .move
        case .delete: .delete
        case .alias: .link
        }
    }
}

@available(OpenSwiftUI_v1_0, *)
public struct DropProposal: Sendable {
    public let operation: DropOperation
    public let operationOutsideApplication: DropOperation?

    public init(operation: DropOperation) {
        self.operation = operation
        operationOutsideApplication = nil
    }
}

@available(OpenSwiftUI_v1_0, *)
public struct DropInfo {
    public var location: CGPoint
    var pasteboard: NSPasteboard

    @available(OpenSwiftUI_v2_0, *)
    public func hasItemsConforming(to contentTypes: [UTType]) -> Bool {
        !_finchItemProviders(pasteboard, contentTypes).isEmpty
    }

    @available(OpenSwiftUI_v2_0, *)
    public func itemProviders(for contentTypes: [UTType]) -> [NSItemProvider] {
        _finchItemProviders(pasteboard, contentTypes)
    }
}

@available(*, unavailable) extension DropInfo: Sendable {}

/// Item providers for the pasteboard's items of the types (a file URL's file, or the data).
func _finchItemProviders(_ pasteboard: NSPasteboard, _ types: [UTType]) -> [NSItemProvider] {
    var providers: [NSItemProvider] = []
    for item in pasteboard.pasteboardItems ?? [] {
        if let urlString = item.string(forType: .fileURL), let url = URL(string: urlString) {
            let fileType = UTType(filenameExtension: url.pathExtension) ?? .data
            if types.contains(where: { fileType.conforms(to: $0) || $0 == .fileURL || $0 == .url }) {
                providers.append(NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL))
            }
            continue
        }
        for type in types {
            let pasteboardType = NSPasteboard.PasteboardType(type.identifier)
            if let data = item.data(forType: pasteboardType) {
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
                    completion(data, nil)
                    return nil
                }
                providers.append(provider)
                break
            }
            if type.conforms(to: .text), let string = item.string(forType: .string) {
                providers.append(NSItemProvider(object: string as NSString))
                break
            }
        }
    }
    return providers
}

@available(OpenSwiftUI_v1_0, *)
@MainActor
@preconcurrency
public protocol DropDelegate {
    func validateDrop(info: DropInfo) -> Bool
    func performDrop(info: DropInfo) -> Bool
    func dropEntered(info: DropInfo)
    func dropUpdated(info: DropInfo) -> DropProposal?
    func dropExited(info: DropInfo)
}

@available(OpenSwiftUI_v1_0, *)
extension DropDelegate {
    public func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.item]) }
    public func dropEntered(info: DropInfo) {}
    public func dropUpdated(info: DropInfo) -> DropProposal? { nil }
    public func dropExited(info: DropInfo) {}
}

/// The drop target over the content.
struct _FinchDropTarget: NSViewRepresentable {
    var types: [UTType]
    var delegate: any DropDelegate

    func makeNSView(context: Context) -> _FinchDropView { _FinchDropView() }

    func updateNSView(_ view: _FinchDropView, context: Context) {
        view.delegate = delegate
        view.contentTypes = types
        let pasteboardTypes = types.map { NSPasteboard.PasteboardType($0.identifier) } + [.fileURL, .URL, .string]
        view.registerForDraggedTypes(pasteboardTypes)
    }
}

final class _FinchDropView: NSView {
    var delegate: (any DropDelegate)?
    var contentTypes: [UTType] = []

    override var isFlipped: Bool { true }

    /// Only drags find it; clicks and the rest go to the content beneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard NSApp.currentEvent?.type == .leftMouseDragged || NSApp.currentEvent?.type == .periodic,
              bounds.contains(convert(point, from: superview))
        else { return nil }
        return self
    }

    private func info(_ sender: any NSDraggingInfo) -> DropInfo {
        DropInfo(location: convert(sender.draggingLocation, from: nil), pasteboard: sender.draggingPasteboard)
    }

    private func operation(for sender: any NSDraggingInfo) -> NSDragOperation {
        guard let delegate else { return [] }
        let info = info(sender)
        let valid = MainActor.assumeIsolated { delegate.validateDrop(info: info) }
        guard valid else { return [] }
        let proposal = MainActor.assumeIsolated { delegate.dropUpdated(info: info) }
        return (proposal?.operation ?? .copy).dragOperation
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if let delegate {
            let info = info(sender)
            MainActor.assumeIsolated { delegate.dropEntered(info: info) }
        }
        return operation(for: sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { operation(for: sender) }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        guard let sender, let delegate else { return }
        let info = info(sender)
        MainActor.assumeIsolated { delegate.dropExited(info: info) }
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let delegate else { return false }
        let info = info(sender)
        return MainActor.assumeIsolated { delegate.performDrop(info: info) }
    }
}

@available(OpenSwiftUI_v1_0, *)
extension View {
    nonisolated public func onDrop(of supportedContentTypes: [UTType], delegate: any DropDelegate) -> some View {
        overlay(_FinchDropTarget(types: supportedContentTypes, delegate: delegate))
    }

    nonisolated public func onDrop(of supportedContentTypes: [UTType], isTargeted: Binding<Bool>?,
                                   perform action: @escaping ([NSItemProvider]) -> Bool) -> some View {
        overlay(_FinchDropTarget(types: supportedContentTypes,
                                 delegate: _FinchActionDropDelegate(types: supportedContentTypes, isTargeted: isTargeted, action: action)))
    }

    nonisolated public func onDrop(of supportedContentTypes: [UTType], isTargeted: Binding<Bool>?,
                                   perform action: @escaping ([NSItemProvider], CGPoint) -> Bool) -> some View {
        overlay(_FinchDropTarget(types: supportedContentTypes,
                                 delegate: _FinchActionDropDelegate(types: supportedContentTypes, isTargeted: isTargeted,
                                                                    locatedAction: action)))
    }

    /// The content as a drag source: Finch's SwiftUI doesn't start drags from views yet.
    nonisolated public func onDrag(_ data: @escaping () -> NSItemProvider) -> some View { self }

    nonisolated public func onDrag<V>(_ data: @escaping () -> NSItemProvider, @ViewBuilder preview: () -> V) -> some View
        where V: View { self }
}

struct _FinchActionDropDelegate: DropDelegate {
    var types: [UTType]
    var isTargeted: Binding<Bool>?
    var action: (([NSItemProvider]) -> Bool)?
    var locatedAction: (([NSItemProvider], CGPoint) -> Bool)?

    init(types: [UTType], isTargeted: Binding<Bool>?, action: @escaping ([NSItemProvider]) -> Bool) {
        self.types = types
        self.isTargeted = isTargeted
        self.action = action
    }

    init(types: [UTType], isTargeted: Binding<Bool>?, locatedAction: @escaping ([NSItemProvider], CGPoint) -> Bool) {
        self.types = types
        self.isTargeted = isTargeted
        self.locatedAction = locatedAction
    }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: types) }
    func dropEntered(info: DropInfo) { isTargeted?.wrappedValue = true }
    func dropExited(info: DropInfo) { isTargeted?.wrappedValue = false }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted?.wrappedValue = false
        let providers = info.itemProviders(for: types)
        if let action { return action(providers) }
        return locatedAction?(providers, info.location) ?? false
    }
}
