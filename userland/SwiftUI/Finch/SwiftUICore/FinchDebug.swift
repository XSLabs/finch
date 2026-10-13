// SPDX-License-Identifier: MIT OR Apache-2.0
// Debugging aids for apps Finch runs (not Apple API).
import Foundation

/// A Published value's current value, from Finch's Combine.
@_silgen_name("_finchCombinePublishedValue")
private func _finchCombinePublishedValue(_ value: Any) -> Any?

private let _finchDumpObjects = getenv("FINCH_SWIFTUI_OBJECTS") != nil

/// With FINCH_SWIFTUI_OBJECTS set, prints an environment or observed object a view updates
/// with, and its stored fields (each value's description, cut short).
package func _finchDumpObject(_ object: AnyObject, changed: Bool) {
    guard _finchDumpObjects else { return }
    var line = "SwiftUI object \(type(of: object)) \(ObjectIdentifier(object))\(changed ? " changed" : ""):"
    var mirror: Mirror? = Mirror(reflecting: object)
    while let m = mirror {
        for child in m.children {
            var value = _finchUnwrap(child.value, depth: 0)
            if value.count > 60 { value = String(value.prefix(60)) + "…" }
            line += " \(child.label ?? "?")=\(value)"
        }
        mirror = m.superclassMirror
    }
    fputs(line + "\n", stderr)
}

/// A Published value's current value (through its storage or subject), or the value itself.
private func _finchUnwrap(_ value: Any, depth: Int) -> String {
    if let current = _finchCombinePublishedValue(value) {
        return String(describing: current)
    }
    let typeName = String(describing: type(of: value))
    let m = Mirror(reflecting: value)
    if depth < 6, typeName.hasPrefix("Published") || m.displayStyle == .enum && depth > 0 || typeName.contains("Subject") {
        for child in m.children where child.label == nil || ["_storage", "value", "publisher", "subject", "currentValue", "_value"].contains(child.label!) {
            return _finchUnwrap(child.value, depth: depth + 1)
        }
    }
    return String(describing: value)
}
