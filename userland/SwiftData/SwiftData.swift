// SPDX-License-Identifier: MIT OR Apache-2.0
//
// SwiftData, to Apple's interface: the @Model macro's models keep their properties in backing
// data, which Finch's keeps as each property's value encoded (JSON); a container's store is a
// file of those records by model and identifier (beside where Apple's SQLite store would be,
// under its own name). A context fetches models (filtered by their predicate, sorted, limited),
// inserts and deletes them, and saves its changes to the store. A model actor's work runs on
// its executor's serial queue.
//
// Not yet: relationships kept between launches (related models are kept while the app runs),
// migrations between schema versions, history, CloudKit, and custom data stores.

import Foundation
import Observation

// MARK: - Identifiers and errors

public struct PersistentIdentifier: Hashable, Identifiable, Comparable, Codable, Sendable {
    public let id: ID
    public var entityName: String { id.entityName }
    public var storeIdentifier: String? { id.storeIdentifier }

    public struct ID: Hashable, Comparable, Codable, Sendable {
        let entityName: String
        let uuid: UUID
        let storeIdentifier: String?

        public static func < (a: ID, b: ID) -> Bool {
            (a.entityName, a.uuid.uuidString) < (b.entityName, b.uuid.uuidString)
        }
    }

    init(entityName: String, uuid: UUID = UUID(), storeIdentifier: String?) {
        id = ID(entityName: entityName, uuid: uuid, storeIdentifier: storeIdentifier)
    }

    public static func < (a: PersistentIdentifier, b: PersistentIdentifier) -> Bool {
        a.id < b.id
    }
}

public struct SwiftDataError: Error, Hashable {
    let code: Int

    public static let includePendingChangesWithBatchSize = SwiftDataError(code: 1)
    public static let unsupportedPredicate = SwiftDataError(code: 2)
    public static let unsupportedKeyPath = SwiftDataError(code: 3)
    public static let sortingPendingChangesWithIdentifiers = SwiftDataError(code: 4)
    public static let unsupportedSortDescriptor = SwiftDataError(code: 5)
    public static let duplicateConfiguration = SwiftDataError(code: 6)
    public static let configurationFileNameTooLong = SwiftDataError(code: 7)
    public static let configurationFileNameContainsInvalidCharacters = SwiftDataError(code: 8)
    public static let configurationSchemaNotFoundInContainerSchema = SwiftDataError(code: 9)
    public static let loadIssueModelContainer = SwiftDataError(code: 10)
    public static let modelValidationFailure = SwiftDataError(code: 11)
    public static let missingModelContext = SwiftDataError(code: 12)
    public static let backwardMigration = SwiftDataError(code: 13)
    public static let unknownSchema = SwiftDataError(code: 14)
    public static let historyTokenExpired = SwiftDataError(code: 15)
    public static let invalidTransactionFetchRequest = SwiftDataError(code: 16)

    public static func ~= (lhs: SwiftDataError, rhs: any Error) -> Bool {
        (rhs as? SwiftDataError) == lhs
    }
}

// MARK: - Schema

public protocol SchemaProperty: Decodable, Encodable, Hashable {}

public final class Schema: Codable, Hashable {
    public struct Version: Codable, Hashable, Comparable, CustomStringConvertible, Sendable {
        public let major: Int
        public let minor: Int
        public let patch: Int

        public init(_ major: Int, _ minor: Int, _ patch: Int) {
            self.major = major
            self.minor = minor
            self.patch = patch
        }

        public static func < (a: Version, b: Version) -> Bool {
            (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }

        public var description: String { "\(major).\(minor).\(patch)" }
    }

    /// A model property as the @Model macro describes it.
    public struct PropertyMetadata {
        public let name: String
        public let keypath: AnyKeyPath
        public let defaultValue: Any?
        public let metadata: (any SchemaProperty)?

        public init(name: String, keypath: AnyKeyPath, defaultValue: Any?, metadata: (any SchemaProperty)?) {
            self.name = name
            self.keypath = keypath
            self.defaultValue = defaultValue
            self.metadata = metadata
        }
    }

    public let version: Version
    let types: [any PersistentModel.Type]
    var entityNames: [String] { types.map { _entityName($0) } }

    public init(_ types: [any PersistentModel.Type], version: Version = Version(1, 0, 0)) {
        self.types = types
        self.version = version
    }

    public convenience init(_ types: any PersistentModel.Type..., version: Version = Version(1, 0, 0)) {
        self.init(types, version: version)
    }

    public convenience init(versionedSchema: any VersionedSchema.Type) {
        self.init(versionedSchema.models, version: versionedSchema.versionIdentifier)
    }

    enum CodingKeys: String, CodingKey { case version, entities }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(entityNames, forKey: .entities)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Version.self, forKey: .version)
        types = []
    }

    public static func == (a: Schema, b: Schema) -> Bool {
        a.version == b.version && a.entityNames == b.entityNames
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(version)
        hasher.combine(entityNames)
    }
}

public protocol VersionedSchema: SendableMetatype {
    static var versionIdentifier: Schema.Version { get }
    static var models: [any PersistentModel.Type] { get }
}

public protocol SchemaMigrationPlan: SendableMetatype {
    static var schemas: [any VersionedSchema.Type] { get }
    static var stages: [MigrationStage] { get }
}

public enum MigrationStage: @unchecked Sendable {
    case lightweight(fromVersion: any VersionedSchema.Type, toVersion: any VersionedSchema.Type)
    case custom(fromVersion: any VersionedSchema.Type, toVersion: any VersionedSchema.Type,
                willMigrate: ((ModelContext) throws -> Void)?, didMigrate: ((ModelContext) throws -> Void)?)
}

func _entityName(_ type: Any.Type) -> String {
    String(describing: type)
}

// MARK: - Models and backing data

public protocol RelationshipCollection {
    associatedtype PersistentElement: PersistentModel
}

extension Array: RelationshipCollection where Element: PersistentModel {
    public typealias PersistentElement = Element
}

public protocol PersistentModel: AnyObject, Observable, Hashable, Identifiable, SendableMetatype {
    init(backingData: any BackingData<Self>)
    var persistentBackingData: any BackingData<Self> { get set }
    static var schemaMetadata: [Schema.PropertyMetadata] { get }
    associatedtype Root: PersistentModel = Self
}

public protocol BackingData<Model> {
    associatedtype Model: PersistentModel
    init(for modelType: Model.Type)
    var persistentModelID: PersistentIdentifier? { get set }
    var metadata: Any { get }
    @_disfavoredOverload func getValue<Value>(forKey: KeyPath<Model, Value>) -> Value where Value: Decodable
    func getValue<Value>(forKey: KeyPath<Model, Value>) -> Value where Value: PersistentModel
    func getValue<Value>(forKey: KeyPath<Model, Value?>) -> Value? where Value: PersistentModel
    func getValue<Value, OtherModel>(forKey: KeyPath<Model, Value>) -> Value
        where Value: RelationshipCollection, OtherModel == Value.PersistentElement
    func getValue<Value, OtherModel>(forKey: KeyPath<Model, Value>) -> Value
        where Value: Decodable, Value: RelationshipCollection, OtherModel == Value.PersistentElement
    func getTransformableValue<Value>(forKey: KeyPath<Model, Value>) -> Value
    @_disfavoredOverload func setValue<Value>(forKey: KeyPath<Model, Value>, to newValue: Value) where Value: Encodable
    func setValue<Value>(forKey: KeyPath<Model, Value>, to newValue: Value) where Value: PersistentModel
    func setValue<Value>(forKey: KeyPath<Model, Value?>, to newValue: Value?) where Value: PersistentModel
    func setValue<Value, OtherModel>(forKey: KeyPath<Model, Value>, to newValue: Value)
        where Value: RelationshipCollection, OtherModel == Value.PersistentElement
    func setValue<Value, OtherModel>(forKey: KeyPath<Model, Value>, to newValue: Value)
        where Value: Encodable, Value: RelationshipCollection, OtherModel == Value.PersistentElement
    func setTransformableValue<Value>(forKey: KeyPath<Model, Value>, to newValue: Value)
}

extension BackingData {
    public func _generateCurrentClassBackingData<CurrentClass>() -> any BackingData<CurrentClass> where CurrentClass: PersistentModel {
        _FinchBackingData<CurrentClass>(for: CurrentClass.self)
    }

    public func _superClassBackingData<SuperClass>(of givenType: any PersistentModel.Type) -> any BackingData<SuperClass>
        where SuperClass: PersistentModel {
        _FinchBackingData<SuperClass>(for: SuperClass.self)
    }
}

/// What a context and the store see of a model's backing data, whatever its model.
protocol _FinchBacking: AnyObject {
    var entityName: String { get }
    var identifier: PersistentIdentifier? { get set }
    var encodedValues: [String: Data] { get }
    var context: ModelContext? { get set }
    var changed: Bool { get set }
    var model: AnyObject? { get }
}

/// A model's properties, each its value encoded, and the related models it holds.
final class _FinchBackingData<M: PersistentModel>: BackingData, _FinchBacking, @unchecked Sendable {
    typealias Model = M

    private let lock = NSLock()
    var values: [String: Data] = [:]
    var cache: [String: Any] = [:]
    var related: [String: Any] = [:]
    var persistentModelID: PersistentIdentifier?
    weak var context: ModelContext?
    weak var model: AnyObject?
    var changed = false

    init(for modelType: M.Type) {}

    init(values: [String: Data], identifier: PersistentIdentifier) {
        self.values = values
        persistentModelID = identifier
    }

    var metadata: Any { M.schemaMetadata }
    var entityName: String { _entityName(M.self) }

    var identifier: PersistentIdentifier? {
        get { persistentModelID }
        set { persistentModelID = newValue }
    }

    var encodedValues: [String: Data] {
        lock.lock(); defer { lock.unlock() }
        return values
    }

    private func name(_ keyPath: AnyKeyPath) -> String {
        M.schemaMetadata.first { $0.keypath == keyPath }?.name ?? "\(keyPath)"
    }

    private func defaultValue(_ keyPath: AnyKeyPath) -> Any? {
        M.schemaMetadata.first { $0.keypath == keyPath }?.defaultValue
    }

    private func markChanged() {
        changed = true
        context?._noteChange(self)
    }

    func getValue<Value>(forKey key: KeyPath<M, Value>) -> Value where Value: Decodable {
        let n = name(key)
        lock.lock(); defer { lock.unlock() }
        // (a missing entry, not a cached nil: `as?` to an optional type turns nothing into nil)
        if let cached = cache[n], let v = cached as? Value { return v }
        if let data = values[n], let v = _decode(Value.self, data) {
            cache[n] = v
            return v
        }
        if let v = defaultValue(key) as? Value { return v }
        // a value never set: an optional's nil, else what decodes from nothing
        if let v = _decode(Value.self, Data("null".utf8)) { return v }
        fatalError("SwiftData: no value for \(M.self).\(n)")
    }

    func getValue<Value>(forKey key: KeyPath<M, Value>) -> Value where Value: PersistentModel {
        lock.lock(); defer { lock.unlock() }
        return related[name(key)] as! Value
    }

    func getValue<Value>(forKey key: KeyPath<M, Value?>) -> Value? where Value: PersistentModel {
        lock.lock(); defer { lock.unlock() }
        return related[name(key)] as? Value
    }

    func getValue<Value, OtherModel>(forKey key: KeyPath<M, Value>) -> Value
        where Value: RelationshipCollection, OtherModel == Value.PersistentElement {
        lock.lock(); defer { lock.unlock() }
        if let stored = related[name(key)], let v = stored as? Value { return v }
        return ([OtherModel]() as Any) as! Value
    }

    func getValue<Value, OtherModel>(forKey key: KeyPath<M, Value>) -> Value
        where Value: Decodable, Value: RelationshipCollection, OtherModel == Value.PersistentElement {
        lock.lock(); defer { lock.unlock() }
        if let stored = related[name(key)], let v = stored as? Value { return v }
        return ([OtherModel]() as Any) as! Value
    }

    func getTransformableValue<Value>(forKey key: KeyPath<M, Value>) -> Value {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[name(key)], let v = cached as? Value { return v }
        if let data = values[name(key)], let v = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as? Value {
            return v
        }
        return defaultValue(key) as! Value
    }

    func setValue<Value>(forKey key: KeyPath<M, Value>, to newValue: Value) where Value: Encodable {
        let n = name(key)
        lock.lock()
        cache[n] = newValue
        values[n] = _encode(newValue)
        lock.unlock()
        markChanged()
    }

    func setValue<Value>(forKey key: KeyPath<M, Value>, to newValue: Value) where Value: PersistentModel {
        lock.lock(); related[name(key)] = newValue; lock.unlock()
        markChanged()
    }

    func setValue<Value>(forKey key: KeyPath<M, Value?>, to newValue: Value?) where Value: PersistentModel {
        lock.lock(); related[name(key)] = newValue; lock.unlock()
        markChanged()
    }

    func setValue<Value, OtherModel>(forKey key: KeyPath<M, Value>, to newValue: Value)
        where Value: RelationshipCollection, OtherModel == Value.PersistentElement {
        lock.lock(); related[name(key)] = newValue; lock.unlock()
        markChanged()
    }

    func setValue<Value, OtherModel>(forKey key: KeyPath<M, Value>, to newValue: Value)
        where Value: Encodable, Value: RelationshipCollection, OtherModel == Value.PersistentElement {
        lock.lock(); related[name(key)] = newValue; lock.unlock()
        markChanged()
    }

    func setTransformableValue<Value>(forKey key: KeyPath<M, Value>, to newValue: Value) {
        let n = name(key)
        lock.lock()
        cache[n] = newValue
        if let object = newValue as AnyObject?,
           let data = try? NSKeyedArchiver.archivedData(withRootObject: object, requiringSecureCoding: false) {
            values[n] = data
        }
        lock.unlock()
        markChanged()
    }
}

/// A value as JSON (a bare value wrapped, as JSON needs a container).
func _encode<T: Encodable>(_ value: T) -> Data? {
    try? JSONEncoder().encode([value])
}

func _decode<T: Decodable>(_ type: T.Type, _ data: Data) -> T? {
    if let array = try? JSONDecoder().decode([T].self, from: data), let first = array.first { return first }
    return try? JSONDecoder().decode(T.self, from: data)
}

extension PersistentModel {
    public static func createBackingData<P>() -> some BackingData<P> where P: PersistentModel {
        _FinchBackingData<P>(for: P.self)
    }

    private var finchBacking: _FinchBackingData<Self>? {
        persistentBackingData as? _FinchBackingData<Self>
    }

    @_disfavoredOverload
    public func getValue<Value>(forKey key: KeyPath<Self, Value>) -> Value where Value: Decodable {
        persistentBackingData.getValue(forKey: key)
    }

    public func getValue<Value>(forKey key: KeyPath<Self, Value>) -> Value where Value: PersistentModel {
        persistentBackingData.getValue(forKey: key)
    }

    public func getValue<Value>(forKey key: KeyPath<Self, Value?>) -> Value? where Value: PersistentModel {
        persistentBackingData.getValue(forKey: key)
    }

    public func getValue<Value, OtherModel>(forKey key: KeyPath<Self, Value>) -> Value
        where Value: RelationshipCollection, OtherModel == Value.PersistentElement {
        persistentBackingData.getValue(forKey: key)
    }

    public func getValue<Value, OtherModel>(forKey key: KeyPath<Self, Value>) -> Value
        where Value: Decodable, Value: RelationshipCollection, OtherModel == Value.PersistentElement {
        persistentBackingData.getValue(forKey: key)
    }

    public func getTransformableValue<Value>(forKey key: KeyPath<Self, Value>) -> Value {
        persistentBackingData.getTransformableValue(forKey: key)
    }

    @_disfavoredOverload
    public func setValue<Value>(forKey key: KeyPath<Self, Value>, to newValue: Value) where Value: Encodable {
        persistentBackingData.setValue(forKey: key, to: newValue)
    }

    public func setValue<Value>(forKey key: KeyPath<Self, Value>, to newValue: Value) where Value: PersistentModel {
        persistentBackingData.setValue(forKey: key, to: newValue)
    }

    public func setValue<Value>(forKey key: KeyPath<Self, Value?>, to newValue: Value?) where Value: PersistentModel {
        persistentBackingData.setValue(forKey: key, to: newValue)
    }

    public func setValue<Value, OtherModel>(forKey key: KeyPath<Self, Value>, to newValue: Value)
        where Value: RelationshipCollection, OtherModel == Value.PersistentElement {
        persistentBackingData.setValue(forKey: key, to: newValue)
    }

    public func setValue<Value, OtherModel>(forKey key: KeyPath<Self, Value>, to newValue: Value)
        where Value: Encodable, Value: RelationshipCollection, OtherModel == Value.PersistentElement {
        persistentBackingData.setValue(forKey: key, to: newValue)
    }

    public func setTransformableValue<Value>(forKey key: KeyPath<Self, Value>, to newValue: Value) {
        persistentBackingData.setTransformableValue(forKey: key, to: newValue)
    }

    public var modelContext: ModelContext? { finchBacking?.context }

    public var persistentModelID: PersistentIdentifier {
        if let id = persistentBackingData.persistentModelID { return id }
        // not inserted yet: an identifier of its own from now on
        let id = PersistentIdentifier(entityName: _entityName(Self.self), storeIdentifier: nil)
        finchBacking?.persistentModelID = id
        return id
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs === rhs }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    public var id: PersistentIdentifier { persistentModelID }

    public var hasChanges: Bool { finchBacking?.changed ?? false }

    public var isDeleted: Bool {
        guard let backing = finchBacking, let context = backing.context else { return false }
        return context._isDeleted(backing)
    }
}

// MARK: - Configurations and containers

public struct ModelConfiguration: Identifiable, Hashable, CustomDebugStringConvertible, Sendable {
    public let url: URL
    public let name: String
    public let groupAppContainerIdentifier: String?
    public let cloudKitContainerIdentifier: String?
    public let groupContainer: GroupContainer
    public let cloudKitDatabase: CloudKitDatabase
    public var schema: Schema? {
        get { schemaBox.schema }
        set { schemaBox = _SchemaBox(schema: newValue) }
    }
    var schemaBox: _SchemaBox
    public let allowsSave: Bool
    public let isStoredInMemoryOnly: Bool

    public struct CloudKitDatabase: Sendable {
        var name: String?
        public static var automatic: CloudKitDatabase { CloudKitDatabase(name: "automatic") }
        public static var none: CloudKitDatabase { CloudKitDatabase(name: nil) }
        public static func `private`(_ privateDBName: String) -> CloudKitDatabase { CloudKitDatabase(name: privateDBName) }
    }

    public struct GroupContainer: Sendable {
        var identifier: String?
        var automatic: Bool
        public static var automatic: GroupContainer { GroupContainer(identifier: nil, automatic: true) }
        public static var none: GroupContainer { GroupContainer(identifier: nil, automatic: false) }
        public static func identifier(_ groupName: String) -> GroupContainer { GroupContainer(identifier: groupName, automatic: false) }
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    public init(isStoredInMemoryOnly: Bool = false) {
        self.init(nil, schema: nil, isStoredInMemoryOnly: isStoredInMemoryOnly)
    }

    public init(for forTypes: any PersistentModel.Type..., isStoredInMemoryOnly: Bool = false) {
        self.init(nil, schema: Schema(forTypes), isStoredInMemoryOnly: isStoredInMemoryOnly)
    }

    public init(_ name: String? = nil, schema: Schema? = nil, isStoredInMemoryOnly: Bool = false, allowsSave: Bool = true,
                groupContainer: GroupContainer = .automatic, cloudKitDatabase: CloudKitDatabase = .automatic) {
        let storeName = name ?? "default"
        self.name = storeName
        url = Self.defaultDirectory.appendingPathComponent(storeName + ".store")
        groupAppContainerIdentifier = groupContainer.identifier
        cloudKitContainerIdentifier = cloudKitDatabase.name
        self.groupContainer = groupContainer
        self.cloudKitDatabase = cloudKitDatabase
        schemaBox = _SchemaBox(schema: schema)
        self.allowsSave = allowsSave
        self.isStoredInMemoryOnly = isStoredInMemoryOnly
    }

    public init(_ name: String? = nil, schema: Schema? = nil, url: URL, allowsSave: Bool = true,
                cloudKitDatabase: CloudKitDatabase = .automatic) {
        self.name = name ?? url.deletingPathExtension().lastPathComponent
        self.url = url
        groupAppContainerIdentifier = nil
        cloudKitContainerIdentifier = cloudKitDatabase.name
        groupContainer = .none
        self.cloudKitDatabase = cloudKitDatabase
        schemaBox = _SchemaBox(schema: schema)
        self.allowsSave = allowsSave
        isStoredInMemoryOnly = false
    }

    public var id: URL { url }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }

    public static func == (lhs: ModelConfiguration, rhs: ModelConfiguration) -> Bool {
        lhs.url == rhs.url && lhs.isStoredInMemoryOnly == rhs.isStoredInMemoryOnly
    }

    public var debugDescription: String { "ModelConfiguration(\(name), \(url.path))" }

    /// Where Finch keeps the store: beside Apple's, under its own name.
    var finchStoreURL: URL { url.appendingPathExtension("finch.json") }
}

struct _SchemaBox: @unchecked Sendable {
    var schema: Schema?
}

/// The records of a store: each model's properties, by model and identifier.
final class _Store: @unchecked Sendable {
    let configuration: ModelConfiguration
    let identifier = UUID().uuidString
    private let lock = NSLock()
    /// entity → uuid → property → encoded value
    private var records: [String: [UUID: [String: Data]]] = [:]

    init(_ configuration: ModelConfiguration) {
        self.configuration = configuration
        load()
    }

    private func load() {
        guard !configuration.isStoredInMemoryOnly,
              let data = try? Data(contentsOf: configuration.finchStoreURL),
              let decoded = try? JSONDecoder().decode([String: [UUID: [String: Data]]].self, from: data) else { return }
        records = decoded
    }

    private func write() throws {
        guard !configuration.isStoredInMemoryOnly else { return }
        let data = try JSONEncoder().encode(records)
        try FileManager.default.createDirectory(at: configuration.finchStoreURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: configuration.finchStoreURL, options: .atomic)
    }

    func records(of entity: String) -> [UUID: [String: Data]] {
        lock.lock(); defer { lock.unlock() }
        return records[entity] ?? [:]
    }

    func commit(saving: [(entity: String, uuid: UUID, values: [String: Data])], deleting: [(entity: String, uuid: UUID)]) throws {
        lock.lock()
        for record in saving {
            records[record.entity, default: [:]][record.uuid] = record.values
        }
        for record in deleting {
            records[record.entity]?[record.uuid] = nil
        }
        lock.unlock()
        if configuration.allowsSave { try write() }
    }

    func erase() {
        lock.lock()
        records = [:]
        lock.unlock()
        try? FileManager.default.removeItem(at: configuration.finchStoreURL)
    }
}

public class ModelContainer: Equatable, @unchecked Sendable {
    public final let schema: Schema
    public final let migrationPlan: (any SchemaMigrationPlan.Type)?
    public var configurations: Set<ModelConfiguration>
    let store: _Store
    private var _mainContext: ModelContext?

    public init(for givenSchema: Schema, migrationPlan: (any SchemaMigrationPlan.Type)? = nil,
                configurations: [ModelConfiguration]) throws {
        schema = givenSchema
        self.migrationPlan = migrationPlan
        var configs = configurations
        if configs.isEmpty { configs = [ModelConfiguration(schema: givenSchema)] }
        self.configurations = Set(configs)
        store = _Store(configs[0])
    }

    public convenience init(for givenSchema: Schema, migrationPlan: (any SchemaMigrationPlan.Type)? = nil,
                            configurations: ModelConfiguration...) throws {
        try self.init(for: givenSchema, migrationPlan: migrationPlan, configurations: configurations)
    }

    public convenience init(for forTypes: any PersistentModel.Type..., migrationPlan: (any SchemaMigrationPlan.Type)? = nil,
                            configurations: ModelConfiguration...) throws {
        try self.init(for: Schema(forTypes), migrationPlan: migrationPlan, configurations: configurations)
    }

    @MainActor
    public var mainContext: ModelContext {
        if let _mainContext { return _mainContext }
        let context = ModelContext(self)
        context.autosaveEnabled = true
        _mainContext = context
        return context
    }

    public static func == (lhs: ModelContainer, rhs: ModelContainer) -> Bool { lhs === rhs }

    public func deleteAllData() {
        store.erase()
    }

    public func erase() throws {
        store.erase()
    }
}

// MARK: - Fetching

public struct FetchDescriptor<T>: @unchecked Sendable where T: PersistentModel {
    public var predicate: Predicate<T>?
    public var sortBy: [SortDescriptor<T>]
    public var fetchLimit: Int?
    public var fetchOffset: Int?
    public var includePendingChanges = true
    public var propertiesToFetch: [PartialKeyPath<T>] = []
    public var relationshipKeyPathsForPrefetching: [PartialKeyPath<T>] = []

    public init(predicate: Predicate<T>? = nil, sortBy: [SortDescriptor<T>] = []) {
        self.predicate = predicate
        self.sortBy = sortBy
    }
}

public struct FetchResultsCollection<Element>: RandomAccessCollection {
    let elements: [Element]
    public var startIndex: Int { elements.startIndex }
    public var endIndex: Int { elements.endIndex }
    public subscript(position: Int) -> Element { elements[position] }
    public typealias Index = Int
}

extension FetchResultsCollection: Sendable where Element: Sendable {}

// MARK: - Contexts

public struct EditingState: Identifiable, Sendable {
    public typealias ID = UUID
    public let id = UUID()
    public var author: String?
}

public class ModelContext: Equatable, SendableMetatype {
    public var author: String?
    public var undoManager: UndoManager?
    public var editingState = EditingState()
    public let container: ModelContainer
    public var autosaveEnabled = false

    private let lock = NSRecursiveLock()
    /// Models this context has, by identifier.
    private var registered: [PersistentIdentifier: any _FinchBacking] = [:]
    private var inserted: [PersistentIdentifier: any _FinchBacking] = [:]
    private var deleted: [PersistentIdentifier: any _FinchBacking] = [:]
    private var autosaveScheduled = false

    public static let willSave = Notification.Name("SwiftData.ModelContext.willSave")
    public static let didSave = Notification.Name("SwiftData.ModelContext.didSave")

    public enum NotificationKey: String {
        case queryGeneration, invalidatedAllIdentifiers, insertedIdentifiers, updatedIdentifiers, deletedIdentifiers
    }

    public init(_ container: ModelContainer) {
        self.container = container
    }

    public static func == (lhs: ModelContext, rhs: ModelContext) -> Bool { lhs === rhs }

    public var insertedModelsArray: [any PersistentModel] {
        lock.lock(); defer { lock.unlock() }
        return inserted.values.compactMap { $0.model as? any PersistentModel }
    }

    public var changedModelsArray: [any PersistentModel] {
        lock.lock(); defer { lock.unlock() }
        return registered.values.filter { $0.changed && inserted[$0.identifier!] == nil }.compactMap { $0.model as? any PersistentModel }
    }

    public var deletedModelsArray: [any PersistentModel] {
        lock.lock(); defer { lock.unlock() }
        return deleted.values.compactMap { $0.model as? any PersistentModel }
    }

    public var hasChanges: Bool {
        lock.lock(); defer { lock.unlock() }
        return !inserted.isEmpty || !deleted.isEmpty || registered.values.contains { $0.changed }
    }

    func _noteChange(_ backing: any _FinchBacking) {
        scheduleAutosave()
    }

    func _isDeleted(_ backing: any _FinchBacking) -> Bool {
        guard let id = backing.identifier else { return false }
        lock.lock(); defer { lock.unlock() }
        return deleted[id] != nil
    }

    private func scheduleAutosave() {
        guard autosaveEnabled else { return }
        lock.lock()
        let already = autosaveScheduled
        autosaveScheduled = true
        lock.unlock()
        if already { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.autosaveScheduled = false; self.lock.unlock()
            try? self.save()
        }
    }

    public func model(for persistentModelID: PersistentIdentifier) -> any PersistentModel {
        lock.lock(); defer { lock.unlock() }
        return registered[persistentModelID]?.model as! any PersistentModel
    }

    public func registeredModel<T>(for persistentModelID: PersistentIdentifier) -> T? where T: PersistentModel {
        lock.lock(); defer { lock.unlock() }
        return registered[persistentModelID]?.model as? T
    }

    public func insert<T>(_ model: T) where T: PersistentModel {
        guard let backing = model.persistentBackingData as? _FinchBackingData<T> else { return }
        if backing.persistentModelID == nil {
            backing.persistentModelID = PersistentIdentifier(entityName: _entityName(T.self), storeIdentifier: container.store.identifier)
        }
        backing.context = self
        backing.model = model
        let id = backing.persistentModelID!
        lock.lock()
        if registered[id] == nil { inserted[id] = backing }
        registered[id] = backing
        deleted[id] = nil
        lock.unlock()
        scheduleAutosave()
    }

    public func rollback() {
        lock.lock()
        for (id, _) in inserted { registered[id] = nil }
        inserted = [:]
        deleted = [:]
        lock.unlock()
    }

    public func processPendingChanges() {}

    public func delete<T>(model: T.Type, where predicate: Predicate<T>? = nil, includeSubclasses: Bool = true) throws
        where T: PersistentModel {
        for m in try fetch(FetchDescriptor<T>(predicate: predicate)) {
            delete(m)
        }
    }

    public func delete<T>(_ model: T) where T: PersistentModel {
        guard let backing = model.persistentBackingData as? _FinchBackingData<T>, let id = backing.persistentModelID else { return }
        lock.lock()
        if inserted[id] != nil {
            inserted[id] = nil
            registered[id] = nil
        } else {
            deleted[id] = backing
        }
        lock.unlock()
        scheduleAutosave()
    }

    public func transaction(block: () throws -> Void) throws {
        try block()
        try save()
    }

    public func save() throws {
        NotificationCenter.default.post(name: Self.willSave, object: self)
        lock.lock()
        let saving = registered.values.filter { deleted[$0.identifier!] == nil && ($0.changed || inserted[$0.identifier!] != nil) }
        let deleting = Array(deleted.values)
        let insertedIDs = Array(inserted.keys), deletedIDs = Array(deleted.keys)
        let updatedIDs = saving.compactMap(\.identifier).filter { inserted[$0] == nil }
        for id in deleted.keys { registered[id] = nil }
        inserted = [:]
        deleted = [:]
        lock.unlock()
        try container.store.commit(
            saving: saving.map { ($0.entityName, $0.identifier!.id.uuid, $0.encodedValues) },
            deleting: deleting.map { ($0.entityName, $0.identifier!.id.uuid) })
        for backing in saving { backing.changed = false }
        NotificationCenter.default.post(name: Self.didSave, object: self, userInfo: [
            NotificationKey.insertedIdentifiers.rawValue: insertedIDs,
            NotificationKey.updatedIdentifiers.rawValue: updatedIDs,
            NotificationKey.deletedIdentifiers.rawValue: deletedIDs,
        ])
    }

    /// The models of a type: the store's (each made once in this context) and those inserted.
    private func all<T>(_ type: T.Type, includePending: Bool) -> [T] where T: PersistentModel {
        let entity = _entityName(T.self)
        var models: [T] = []
        var seen = Set<PersistentIdentifier>()
        for (uuid, values) in container.store.records(of: entity) {
            let id = PersistentIdentifier(entityName: entity, uuid: uuid, storeIdentifier: container.store.identifier)
            seen.insert(id)
            lock.lock()
            if deleted[id] != nil {
                lock.unlock()
                continue
            }
            if let existing = registered[id]?.model as? T {
                lock.unlock()
                models.append(existing)
                continue
            }
            lock.unlock()
            let backing = _FinchBackingData<T>(values: values, identifier: id)
            backing.context = self
            let model = T(backingData: backing)
            backing.model = model
            lock.lock()
            registered[id] = backing
            lock.unlock()
            models.append(model)
        }
        if includePending {
            lock.lock()
            let pending = inserted.filter { !seen.contains($0.key) }.compactMap { $0.value.model as? T }
            lock.unlock()
            models += pending
        }
        return models
    }

    public func fetch<T>(_ descriptor: FetchDescriptor<T>) throws -> [T] where T: PersistentModel {
        var models = all(T.self, includePending: descriptor.includePendingChanges)
        if let predicate = descriptor.predicate {
            models = try models.filter { try predicate.evaluate($0) }
        }
        if !descriptor.sortBy.isEmpty {
            models.sort(using: descriptor.sortBy)
        }
        if let offset = descriptor.fetchOffset { models = Array(models.dropFirst(offset)) }
        if let limit = descriptor.fetchLimit { models = Array(models.prefix(limit)) }
        return models
    }

    public func fetchCount<T>(_ descriptor: FetchDescriptor<T>) throws -> Int where T: PersistentModel {
        try fetch(descriptor).count
    }

    public func fetch<T>(_ descriptor: FetchDescriptor<T>, batchSize: Int) throws -> FetchResultsCollection<T> where T: PersistentModel {
        FetchResultsCollection(elements: try fetch(descriptor))
    }

    public func fetchIdentifiers<T>(_ descriptor: FetchDescriptor<T>) throws -> [PersistentIdentifier] where T: PersistentModel {
        try fetch(descriptor).map(\.persistentModelID)
    }

    public func fetchIdentifiers<T>(_ descriptor: FetchDescriptor<T>, batchSize: Int) throws
        -> FetchResultsCollection<PersistentIdentifier> where T: PersistentModel {
        FetchResultsCollection(elements: try fetchIdentifiers(descriptor))
    }

    public func enumerate<T>(_ fetch: FetchDescriptor<T>, batchSize: Int = 5000, allowEscapingMutations: Bool = false,
                             block: (_ model: T) throws -> Void) throws where T: PersistentModel {
        for model in try self.fetch(fetch) { try block(model) }
    }
}

extension ModelContext: @unchecked Sendable {}

// MARK: - Model actors

public protocol ModelExecutor: Executor {
    var modelContext: ModelContext { get }
}

public protocol SerialModelExecutor: ModelExecutor, SerialExecutor {}

/// Runs a model actor's work in order on a queue of its own.
public class DefaultSerialModelExecutor: @unchecked Sendable, SerialModelExecutor {
    public final let modelContext: ModelContext
    private let queue = DispatchQueue(label: "SwiftData.DefaultSerialModelExecutor")

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    public func enqueue(_ job: __owned ExecutorJob) {
        let unowned = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        queue.async {
            unowned.runSynchronously(on: executor)
        }
    }

    public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}

public protocol ModelActor: Actor {
    nonisolated var modelContainer: ModelContainer { get }
    nonisolated var modelExecutor: any ModelExecutor { get }
}

extension ModelActor {
    nonisolated public var unownedExecutor: UnownedSerialExecutor {
        (modelExecutor as! any SerialExecutor).asUnownedSerialExecutor()
    }

    public var modelContext: ModelContext {
        modelExecutor.modelContext
    }

    public subscript<T>(id: PersistentIdentifier, as as: T.Type) -> T? where T: PersistentModel {
        modelContext.registeredModel(for: id)
    }
}
