// SPDX-License-Identifier: MIT OR Apache-2.0
// Content Finch hosts apart (a scroll view's document, a sheet, a popover) runs in a graph
// of its own. Besides the platform values it inherits (Finch's _finchInheriting), it needs
// the app's own: environment objects and the app's environment keys. Not the rest, which
// holds the presenting graph's state.

/// An environment key whose value can be copied between environments.
private protocol _FinchCarriedKey {
    static var _finchKeyName: String { get }
    static func _finchCarry(from source: EnvironmentValues, to target: inout EnvironmentValues)
}

extension EnvironmentPropertyKey: _FinchCarriedKey {
    fileprivate static var _finchKeyName: String { String(reflecting: Key.self) }

    fileprivate static func _finchCarry(from source: EnvironmentValues, to target: inout EnvironmentValues) {
        target[Key.self] = source[Key.self]
    }
}

extension EnvironmentValues {
    /// Copies the environment objects and app-defined values of `source` into these values.
    package mutating func _finchInheritAppValues(from source: EnvironmentValues) {
        var carried: [any _FinchCarriedKey.Type] = []
        var seen = Set<ObjectIdentifier>()
        source.plist.elements?.forEach(filter: BloomFilter()) { element, _ in
            let type = element.takeUnretainedValue().keyType
            guard let key = type as? any _FinchCarriedKey.Type, seen.insert(ObjectIdentifier(type)).inserted else {
                return
            }
            let name = key._finchKeyName
            let framework = name.hasPrefix("SwiftUI.") || name.hasPrefix("SwiftUICore.")
            let appExtension = name.contains("(extension in ") && !name.contains("(extension in SwiftUI")
            if name.contains("EnvironmentObjectKey<") || !framework || appExtension {
                carried.append(key)
            }
        }
        for key in carried {
            key._finchCarry(from: source, to: &self)
        }
    }
}
