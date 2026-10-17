// SPDX-License-Identifier: MIT OR Apache-2.0
//
// SceneStorage, to Apple's interface (and its frozen layout: apps lay it out inline): a
// value kept for the app's scenes, read and written through the property, and the view
// updated when it changes. Finch keeps the values in the app's scene-state defaults
// (<bundle id>.SceneStorage), so they are there the next time the app opens, as restored
// scenes' are on macOS; scenes don't yet keep values apart from each other.

public import Foundation
import OpenAttributeGraphShims
@_spi(ForOpenSwiftUIOnly)
import SwiftUICore

/// The value's store: a location in the scene-state defaults.
@available(OpenSwiftUI_v2_0, *)
@usableFromInline
class SceneStorageTransformBox {
    init() {}
}

final class _FinchSceneStorageBox<Value>: SceneStorageTransformBox {
    let location: UserDefaultLocation<Value>

    init(location: UserDefaultLocation<Value>) {
        self.location = location
    }

    static var store: UserDefaults {
        UserDefaults(suiteName: (Bundle.main.bundleIdentifier ?? "app") + ".SceneStorage") ?? .standard
    }
}

@available(OpenSwiftUI_v2_0, *)
@frozen
@propertyWrapper
public struct SceneStorage<Value>: DynamicProperty {
    @usableFromInline
    var _key: String
    @usableFromInline
    var _domain: String?
    @usableFromInline
    var _value: Value
    @usableFromInline
    var _location: AnyLocation<Value>?
    @usableFromInline
    var _transformBox: SceneStorageTransformBox

    init(key: String, defaultValue: Value, read: @escaping (UserDefaults, String) -> Value?,
         write: @escaping (UserDefaults, String, Value) -> Void) {
        _key = key
        _domain = nil
        _value = defaultValue
        _location = nil
        _transformBox = _FinchSceneStorageBox(location: UserDefaultLocation(key: key, store: _FinchSceneStorageBox<Value>.store,
                                                                            defaultValue: defaultValue, read: read, write: write))
    }

    var location: UserDefaultLocation<Value> {
        (_transformBox as! _FinchSceneStorageBox<Value>).location
    }

    public var wrappedValue: Value {
        get { location.get() }
        nonmutating set { location.set(newValue, transaction: Transaction()) }
    }

    public var projectedValue: Binding<Value> {
        let location = location
        return Binding(get: { location.get() }, set: { location.set($0, transaction: $1) })
    }

    public static func _makeProperty<V>(in buffer: inout _DynamicPropertyBuffer, container: _GraphValue<V>, fieldOffset: Int,
                                        inputs: inout _GraphInputs) {
        let attribute = Attribute(value: ())
        buffer.append(SceneStorageBox<Value>(host: .currentHost, invalidation: WeakAttribute(attribute)), fieldOffset: fieldOffset)
    }
}

@available(OpenSwiftUI_v2_0, *)
extension SceneStorage: @unchecked Sendable where Value: Sendable {}

/// Invalidates the view when the value changes.
private final class SceneStorageObserver {
    weak var host: GraphHost?
    let attribute: WeakAttribute<()>

    init(host: GraphHost, attribute: WeakAttribute<()>) {
        self.host = host
        self.attribute = attribute
    }

    func invalidate() {
        let attribute = attribute
        Update.perform {
            guard let host = self.host else { return }
            host.asyncTransaction(.current, invalidating: attribute, style: Update.threadIsUpdating ? .deferred : .immediate)
        }
    }
}

private struct SceneStorageBox<Value>: DynamicPropertyBox {
    let observer: SceneStorageObserver
    var location: UserDefaultLocation<Value>?

    init(host: GraphHost, invalidation: WeakAttribute<()>) {
        observer = SceneStorageObserver(host: host, attribute: invalidation)
    }

    typealias Property = SceneStorage<Value>

    mutating func update(property: inout Property, phase: ViewPhase) -> Bool {
        let current = property.location
        if location !== current {
            location?.stopObserving(observer)
            let observer = observer
            current.observe(observer) { observer.invalidate() }
            location = current
        }
        return observer.attribute.changedValue()?.changed ?? false
    }
}

// MARK: - Values

private func object<T>(_ store: UserDefaults, _ key: String) -> T? {
    store.object(forKey: key) as? T
}

private func setObject<T>(_ store: UserDefaults, _ key: String, _ value: T?) {
    if let value {
        store.set(value, forKey: key)
    } else {
        store.removeObject(forKey: key)
    }
}

@available(OpenSwiftUI_v2_0, *)
extension SceneStorage {
    public init(wrappedValue: Value, _ key: String) where Value == Bool {
        self.init(key: key, defaultValue: wrappedValue, read: object, write: { $0.set($2, forKey: $1) })
    }

    public init(wrappedValue: Value, _ key: String) where Value == Int {
        self.init(key: key, defaultValue: wrappedValue, read: object, write: { $0.set($2, forKey: $1) })
    }

    public init(wrappedValue: Value, _ key: String) where Value == Double {
        self.init(key: key, defaultValue: wrappedValue, read: object, write: { $0.set($2, forKey: $1) })
    }

    public init(wrappedValue: Value, _ key: String) where Value == String {
        self.init(key: key, defaultValue: wrappedValue, read: object, write: { $0.set($2, forKey: $1) })
    }

    public init(wrappedValue: Value, _ key: String) where Value == URL {
        self.init(key: key, defaultValue: wrappedValue, read: { $0.url(forKey: $1) }, write: { $0.set($2, forKey: $1) })
    }

    public init(wrappedValue: Value, _ key: String) where Value == Date {
        self.init(key: key, defaultValue: wrappedValue, read: object, write: { $0.set($2, forKey: $1) })
    }

    public init(wrappedValue: Value, _ key: String) where Value == Data {
        self.init(key: key, defaultValue: wrappedValue, read: object, write: { $0.set($2, forKey: $1) })
    }

    public init(wrappedValue: Value, _ key: String) where Value: RawRepresentable, Value.RawValue == Int {
        self.init(key: key, defaultValue: wrappedValue, read: { (object($0, $1) as Int?).flatMap(Value.init(rawValue:)) },
                  write: { $0.set($2.rawValue, forKey: $1) })
    }

    public init(wrappedValue: Value, _ key: String) where Value: RawRepresentable, Value.RawValue == String {
        self.init(key: key, defaultValue: wrappedValue, read: { (object($0, $1) as String?).flatMap(Value.init(rawValue:)) },
                  write: { $0.set($2.rawValue, forKey: $1) })
    }
}

@available(OpenSwiftUI_v2_0, *)
extension SceneStorage where Value: ExpressibleByNilLiteral {
    public init(_ key: String) where Value == Bool? {
        self.init(key: key, defaultValue: nil, read: { .some(object($0, $1)) }, write: setObject)
    }

    public init(_ key: String) where Value == Int? {
        self.init(key: key, defaultValue: nil, read: { .some(object($0, $1)) }, write: setObject)
    }

    public init(_ key: String) where Value == Double? {
        self.init(key: key, defaultValue: nil, read: { .some(object($0, $1)) }, write: setObject)
    }

    public init(_ key: String) where Value == String? {
        self.init(key: key, defaultValue: nil, read: { .some(object($0, $1)) }, write: setObject)
    }

    public init(_ key: String) where Value == URL? {
        self.init(key: key, defaultValue: nil, read: { .some($0.url(forKey: $1)) },
                  write: { store, key, url in
                      if let url { store.set(url, forKey: key) } else { store.removeObject(forKey: key) }
                  })
    }

    public init(_ key: String) where Value == Date? {
        self.init(key: key, defaultValue: nil, read: { .some(object($0, $1)) }, write: setObject)
    }

    public init(_ key: String) where Value == Data? {
        self.init(key: key, defaultValue: nil, read: { .some(object($0, $1)) }, write: setObject)
    }
}

@available(OpenSwiftUI_v3_0, *)
extension SceneStorage {
    public init<R>(_ key: String) where Value == R?, R: RawRepresentable, R.RawValue == String {
        self.init(key: key, defaultValue: nil, read: { .some((object($0, $1) as String?).flatMap(R.init(rawValue:))) },
                  write: { setObject($0, $1, $2?.rawValue) })
    }

    public init<R>(_ key: String) where Value == R?, R: RawRepresentable, R.RawValue == Int {
        self.init(key: key, defaultValue: nil, read: { .some((object($0, $1) as Int?).flatMap(R.init(rawValue:))) },
                  write: { setObject($0, $1, $2?.rawValue) })
    }
}

/// Codable values, kept as JSON.
@available(OpenSwiftUI_v2_0, *)
extension SceneStorage where Value: Decodable, Value: Encodable {
    public init(wrappedValue: Value, _ key: String) {
        self.init(key: key, defaultValue: wrappedValue,
                  read: { store, key in (store.data(forKey: key)).flatMap { try? JSONDecoder().decode(Value.self, from: $0) } },
                  write: { store, key, value in store.set(try? JSONEncoder().encode(value), forKey: key) })
    }
}

@available(OpenSwiftUI_v3_0, *)
extension SceneStorage {
    public init<RowValue>(wrappedValue: Value = TableColumnCustomization<RowValue>(), _ key: String)
        where Value == TableColumnCustomization<RowValue>, RowValue: Identifiable {
        self.init(key: key, defaultValue: wrappedValue,
                  read: { store, key in
                      store.data(forKey: key).flatMap {
                          try? JSONDecoder().decode(TableColumnCustomization<RowValue>.self, from: $0)
                      }
                  },
                  write: { store, key, value in
                      store.set(try? JSONEncoder().encode(value), forKey: key)
                  })
    }
}
