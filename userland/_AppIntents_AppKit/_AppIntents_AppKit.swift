// SPDX-License-Identifier: MIT OR Apache-2.0
// AppIntents' AppKit helpers: keep entity annotations on the view that owns them.

@_exported import AppIntents
import AppKit
import ObjectiveC

private var entityIdentifierKey: UInt8 = 0
private var entityAnnotationKey: UInt8 = 0
private var entityProviderKey: UInt8 = 0

private final class EntityIdentifierBox: NSObject {
    let value: EntityIdentifier

    init(_ value: EntityIdentifier) {
        self.value = value
    }
}

public final class AppEntityViewAnnotation {
    let identifier: EntityIdentifier
    var state: AppEntityVisualState

    public init<Entity: AppEntity>(entity: Entity, state: AppEntityVisualState) {
        identifier = EntityIdentifier(for: entity)
        self.state = state
    }
}

extension DisplayRepresentation.Image {
    public init?(systemName name: String, tintColor: NSColor? = nil, symbolConfiguration: NSImage.SymbolConfiguration? = nil) {
        guard var image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        if let symbolConfiguration {
            image = image.withSymbolConfiguration(symbolConfiguration) ?? image
        }

        if let tintColor {
            let tintedImage = NSImage(size: image.size)
            let bounds = NSRect(origin: .zero, size: image.size)
            tintedImage.lockFocus()
            image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
            tintColor.set()
            bounds.fill(using: .sourceAtop)
            tintedImage.unlockFocus()
            image = tintedImage
        }

        guard let data = image.tiffRepresentation else { return nil }
        self.init(data: data, isTemplate: tintColor == nil && image.isTemplate)
    }
}

extension NSView {
    public var appEntityIdentifier: EntityIdentifier? {
        get { (objc_getAssociatedObject(self, &entityIdentifierKey) as? EntityIdentifierBox)?.value }
        set {
            let box = newValue.map(EntityIdentifierBox.init)
            objc_setAssociatedObject(self, &entityIdentifierKey, box, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    public var appEntityUIElementProvider: ((NSView, AppEntityUIElementsContext) -> [AppEntityUIElement])? {
        get { objc_getAssociatedObject(self, &entityProviderKey) as? ((NSView, AppEntityUIElementsContext) -> [AppEntityUIElement]) }
        set { objc_setAssociatedObject(self, &entityProviderKey, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC) }
    }

    public func annotate(with annotation: AppEntityViewAnnotation) {
        appEntityIdentifier = nil
        objc_setAssociatedObject(self, &entityAnnotationKey, annotation, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    public func updateAppEntityAnnotation(with state: AppEntityVisualState) {
        guard let annotation = objc_getAssociatedObject(self, &entityAnnotationKey) as? AppEntityViewAnnotation else { return }
        annotation.state = state
        objc_setAssociatedObject(self, &entityAnnotationKey, annotation, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
