// SPDX-License-Identifier: MIT OR Apache-2.0
//
// AppIntents, to Apple's interface: the protocols an app's intents, enums and values conform
// to (with Apple's requirements and their defaults, which an app's conformances rely on), how
// they're shown (display representations), intent parameters, dialogs and results. Finch has
// no Shortcuts or Siri to run intents yet: an app declares them and they wait.

import Foundation
import CoreGraphics
public import CoreSpotlight
public import UniformTypeIdentifiers

// MARK: - Identification and display

public protocol PersistentlyIdentifiable {
    static var persistentIdentifier: String { get }
}

extension PersistentlyIdentifiable {
    public static var persistentIdentifier: String { String(describing: Self.self) }
}

public protocol _SupportsAppDependencies {}

public struct TypeDisplayRepresentation: ExpressibleByStringLiteral {
    public var name: LocalizedStringResource
    public var numericFormat: LocalizedStringResource?
    public var synonyms: [LocalizedStringResource] = []

    public init(name: LocalizedStringResource, numericFormat: LocalizedStringResource? = nil) {
        self.name = name
        self.numericFormat = numericFormat
    }

    public init(name: LocalizedStringResource, numericFormat: LocalizedStringResource? = nil, synonyms: [LocalizedStringResource]) {
        self.name = name
        self.numericFormat = numericFormat
        self.synonyms = synonyms
    }

    public init(stringLiteral value: String) {
        name = LocalizedStringResource(stringLiteral: value)
    }
}

extension TypeDisplayRepresentation: @unchecked Sendable {}

public protocol TypeDisplayRepresentable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { get }
}

public protocol InstanceDisplayRepresentable: CustomLocalizedStringResourceConvertible {
    var displayRepresentation: DisplayRepresentation { get }
    func displayRepresentation(with components: DisplayRepresentation.Components) async -> DisplayRepresentation
}

public protocol DisplayRepresentable: InstanceDisplayRepresentable, TypeDisplayRepresentable {}

public struct DisplayRepresentation: ExpressibleByStringLiteral, Equatable {
    public struct Components: OptionSet, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let text = Components(rawValue: 1 << 0)
        public static let image = Components(rawValue: 1 << 1)
    }


    public var title: LocalizedStringResource
    public var subtitle: LocalizedStringResource?
    public var image: Image?
    public var synonyms: [LocalizedStringResource] = []

    public struct Image: Equatable {
        enum Source: Equatable, Codable { case systemName(String), named(String), url(URL), data(Data) }
        var source: Source
        public var isTemplate: Bool?

        public init(systemName: String, isTemplate: Bool? = nil) {
            source = .systemName(systemName)
            self.isTemplate = isTemplate
        }

        public init(named name: String, isTemplate: Bool? = nil) {
            source = .named(name)
            self.isTemplate = isTemplate
        }

        public init(url: URL, isTemplate: Bool? = nil) {
            source = .url(url)
            self.isTemplate = isTemplate
        }

        public init(data: Data, isTemplate: Bool? = nil) {
            source = .data(data)
            self.isTemplate = isTemplate
        }
    }

    public init(title: LocalizedStringResource, subtitle: LocalizedStringResource? = nil, image: Image? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.image = image
    }

    public init(title: LocalizedStringResource, subtitle: LocalizedStringResource? = nil, image: Image? = nil,
                synonyms: [LocalizedStringResource] = []) {
        self.title = title
        self.subtitle = subtitle
        self.image = image
        self.synonyms = synonyms
    }

    public init(stringLiteral value: String) {
        title = LocalizedStringResource(stringLiteral: value)
    }

    public static func == (a: DisplayRepresentation, b: DisplayRepresentation) -> Bool {
        a.title.key == b.title.key && a.subtitle?.key == b.subtitle?.key && a.image == b.image
    }

}

extension DisplayRepresentation: @unchecked Sendable {}
extension DisplayRepresentation.Image: @unchecked Sendable {}
extension DisplayRepresentation.Image: Codable {}

public struct AppEntityVisualState: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public init(isSelected: Bool, isHighlighted: Bool, isFocused: Bool, isDisabled: Bool,
                isEditing: Bool, isPrimary: Bool) {
        rawValue = (isSelected ? Self.selected.rawValue : 0)
            | (isHighlighted ? Self.highlighted.rawValue : 0)
            | (isFocused ? Self.focused.rawValue : 0)
            | (isDisabled ? Self.disabled.rawValue : 0)
            | (isEditing ? Self.editing.rawValue : 0)
            | (isPrimary ? Self.primary.rawValue : 0)
    }

    public var isSelected: Bool { contains(.selected) }
    public var isHighlighted: Bool { contains(.highlighted) }
    public var isFocused: Bool { contains(.focused) }
    public var isDisabled: Bool { contains(.disabled) }
    public var isEditing: Bool { contains(.editing) }
    public var isPrimary: Bool { contains(.primary) }

    public static let selected = AppEntityVisualState(rawValue: 1 << 0)
    public static let highlighted = AppEntityVisualState(rawValue: 1 << 1)
    public static let focused = AppEntityVisualState(rawValue: 1 << 2)
    public static let disabled = AppEntityVisualState(rawValue: 1 << 3)
    public static let editing = AppEntityVisualState(rawValue: 1 << 4)
    public static let primary = AppEntityVisualState(rawValue: 1 << 5)
}

public struct AppEntityUIElement: Hashable, Sendable {
    public struct State: Hashable, Sendable {
        public var isSelected: Bool

        public init(isSelected: Bool = false) {
            self.isSelected = isSelected
        }

        public static let selected = State(isSelected: true)
    }

    public var identifier: EntityIdentifier
    public var bounds: CGRect
    public var state: State
    public var subelements: [AppEntityUIElement]

    public init(identifier: EntityIdentifier, bounds: CGRect, state: State = State(), subelements: [AppEntityUIElement] = []) {
        self.identifier = identifier
        self.bounds = bounds
        self.state = state
        self.subelements = subelements
    }

    public init<Entity: AppEntity>(_ entity: Entity, bounds: CGRect, state: State = State(), subelements: [AppEntityUIElement] = []) {
        self.init(identifier: EntityIdentifier(for: entity), bounds: bounds, state: state, subelements: subelements)
    }
}

public struct AppEntityUIElementsContext: Sendable {
    public enum ElementsRequest: Hashable, Sendable {
        case visible(CGRect)
        case selected
    }

    public let bounds: CGRect
    public let requests: Set<ElementsRequest>

    public init(bounds: CGRect, requests: Set<ElementsRequest>) {
        self.bounds = bounds
        self.requests = requests
    }

    public var queryRect: CGRect {
        requests.reduce(CGRect.zero) { rect, request in
            guard case .visible(let requestedBounds) = request else { return rect }
            return rect.isEmpty ? requestedBounds.intersection(bounds) : rect.union(requestedBounds.intersection(bounds))
        }
    }

    public var _includeAllSelectedUIElements: Bool {
        requests.contains(.selected)
    }
}

public protocol CaseDisplayRepresentable: CustomLocalizedStringResourceConvertible, CaseIterable, Hashable {
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] { get }
}

extension CaseDisplayRepresentable {
    public var localizedStringResource: LocalizedStringResource {
        Self.caseDisplayRepresentations[self]?.title ?? LocalizedStringResource(stringLiteral: String(describing: self))
    }
}

extension InstanceDisplayRepresentable {
    public var localizedStringResource: LocalizedStringResource { displayRepresentation.title }

    public func displayRepresentation(with components: DisplayRepresentation.Components) async -> DisplayRepresentation {
        displayRepresentation
    }
}

extension DisplayRepresentable where Self: CaseDisplayRepresentable {
    public var displayRepresentation: DisplayRepresentation {
        Self.caseDisplayRepresentations[self] ?? DisplayRepresentation(title: LocalizedStringResource(stringLiteral: String(describing: self)))
    }
}

public protocol StaticDisplayRepresentable: CaseDisplayRepresentable, TypeDisplayRepresentable {}

// MARK: - Values

/// Something that resolves a parameter's value (Shortcuts asks it; Finch has no Shortcuts).
public protocol Resolver: Sendable {}

public protocol ResolverSpecification: Hashable, Sendable, Sequence where Element == any Resolver {
    associatedtype Output: _IntentValue
}

/// The resolvers of a value with none of its own: none.
public struct EmptyResolverSpecification<Output>: ResolverSpecification where Output: _IntentValue {
    public typealias Element = any Resolver

    public init() {}

    public func makeIterator() -> IndexingIterator<[any Resolver]> {
        [any Resolver]().makeIterator()
    }

    public static func == (a: Self, b: Self) -> Bool { true }
    public func hash(into hasher: inout Hasher) {}
}

public typealias _FinchEmptyResolverSpecification<Output: _IntentValue> = EmptyResolverSpecification<Output>

public protocol _IntentValue {
    associatedtype ValueType: _IntentValue = Self
    associatedtype UnwrappedType: _IntentValue = Self
    associatedtype Specification: ResolverSpecification
    static var defaultResolverSpecification: Specification { get }
}

public protocol AppValue: PersistentlyIdentifiable, TypeDisplayRepresentable, _IntentValue, Sendable {}

public protocol AppEnum: AppValue, StaticDisplayRepresentable, RawRepresentable where RawValue: LosslessStringConvertible {}

extension AppEnum {
    public static var defaultResolverSpecification: some ResolverSpecification {
        EmptyResolverSpecification<Self>()
    }
}

extension Optional: _IntentValue where Wrapped: _IntentValue {
    public typealias ValueType = Wrapped.ValueType
    public typealias UnwrappedType = Wrapped
    public static var defaultResolverSpecification: EmptyResolverSpecification<Optional<Wrapped>> {
        EmptyResolverSpecification()
    }
}

extension String: _IntentValue {
    public static var defaultResolverSpecification: EmptyResolverSpecification<String> { EmptyResolverSpecification() }
}

extension Int: _IntentValue {
    public static var defaultResolverSpecification: EmptyResolverSpecification<Int> { EmptyResolverSpecification() }
}

extension Double: _IntentValue {
    public static var defaultResolverSpecification: EmptyResolverSpecification<Double> { EmptyResolverSpecification() }
}

extension Bool: _IntentValue {
    public static var defaultResolverSpecification: EmptyResolverSpecification<Bool> { EmptyResolverSpecification() }
}

extension Date: _IntentValue {
    public static var defaultResolverSpecification: EmptyResolverSpecification<Date> { EmptyResolverSpecification() }
}

extension DateComponents: _IntentValue {
    public static var defaultResolverSpecification: EmptyResolverSpecification<DateComponents> { EmptyResolverSpecification() }
}

extension URL: _IntentValue {
    public static var defaultResolverSpecification: EmptyResolverSpecification<URL> { EmptyResolverSpecification() }
}

extension AttributedString: _IntentValue {
    public static var defaultResolverSpecification: EmptyResolverSpecification<AttributedString> { EmptyResolverSpecification() }
}

public protocol ResultsCollection<Result> {
    associatedtype Result: _IntentValue
    var promptLabel: LocalizedStringResource? { get }
    var usesIndexedCollation: Bool { get }
    var items: [Result.ValueType] { get }
    static var empty: Self { get }
}

extension Array: ResultsCollection where Element: _IntentValue {
    public typealias Result = Element

    public var promptLabel: LocalizedStringResource? { nil }
    public var usesIndexedCollation: Bool { false }
    public var items: [Element.ValueType] { compactMap { $0 as? Element.ValueType } }
    public static var empty: [Element] { [] }
}

extension Array: _IntentValue where Element: _IntentValue {
    public static var defaultResolverSpecification: EmptyResolverSpecification<[Element]> { EmptyResolverSpecification() }
}

public protocol EntityIdentifierConvertible {
    var entityIdentifierString: String { get }
    static func entityIdentifier(for entityIdentifierString: String) -> Self?
}

extension String: EntityIdentifierConvertible {
    public var entityIdentifierString: String { self }
    public static func entityIdentifier(for entityIdentifierString: String) -> String? { entityIdentifierString }
}

extension Int: EntityIdentifierConvertible {
    public var entityIdentifierString: String { String(self) }
    public static func entityIdentifier(for entityIdentifierString: String) -> Int? { Int(entityIdentifierString) }
}

extension Float: EntityIdentifierConvertible {
    public var entityIdentifierString: String { String(self) }
    public static func entityIdentifier(for entityIdentifierString: String) -> Float? { Float(entityIdentifierString) }
}

extension UUID: EntityIdentifierConvertible {
    public var entityIdentifierString: String { uuidString }
    public static func entityIdentifier(for entityIdentifierString: String) -> UUID? { UUID(uuidString: entityIdentifierString) }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, *)
public struct FileEntityIdentifier: Hashable, Sendable, Codable, EntityIdentifierConvertible {
    private enum Storage: Hashable, Sendable, Codable {
        case ephemeral(url: URL)
        case draft(String)
    }

    private let storage: Storage

    private init(storage: Storage) { self.storage = storage }

    public static func file(url: URL) throws -> FileEntityIdentifier {
        guard url.isFileURL else { throw URLError(.unsupportedURL) }
        return FileEntityIdentifier(storage: .ephemeral(url: url))
    }

    public static func draft(identifier: String) -> FileEntityIdentifier {
        FileEntityIdentifier(storage: .draft(identifier))
    }

    public var fileURL: URL? {
        get async throws {
            guard case .ephemeral(let url) = storage else { return nil }
            return url
        }
    }

    public var draftIdentifier: String? {
        guard case .draft(let identifier) = storage else { return nil }
        return identifier
    }

    public var isDraft: Bool {
        if case .draft = storage { return true }
        return false
    }

    public var entityIdentifierString: String {
        guard case .draft = storage else { return "{}" }
        guard let data = try? JSONEncoder().encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func entityIdentifier(for entityIdentifierString: String) -> FileEntityIdentifier? {
        guard entityIdentifierString != "{}" else { return nil }
        return try? JSONDecoder().decode(Self.self, from: Data(entityIdentifierString.utf8))
    }
}

public struct EntityIdentifier: Hashable, Sendable, CustomStringConvertible {
    public let entityType: any AppEntity.Type
    public let identifier: String
    public static let valueMaximumLength = 512

    public init<Entity>(for entity: Entity) where Entity: AppEntity {
        entityType = Entity.self
        identifier = entity.id.entityIdentifierString
    }

    public init<Entity>(for entityType: Entity.Type, identifier: Entity.ID) where Entity: AppEntity {
        self.entityType = entityType
        self.identifier = identifier.entityIdentifierString
    }

    public var description: String { "\(entityType.persistentIdentifier):\(identifier)" }

    public static func == (lhs: EntityIdentifier, rhs: EntityIdentifier) -> Bool {
        ObjectIdentifier(lhs.entityType) == ObjectIdentifier(rhs.entityType) && lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(entityType))
        hasher.combine(identifier)
    }
}

extension EntityIdentifier: _IntentValue {
    public static var defaultResolverSpecification: EmptyResolverSpecification<EntityIdentifier> { EmptyResolverSpecification() }
}

public protocol DynamicOptionsProvider: _SupportsAppDependencies {
    associatedtype Result: ResultsCollection
    associatedtype DefaultValue: _IntentValue = Result.Result where DefaultValue.ValueType == Result.Result.ValueType
    static var useForParameterResolution: Bool { get }
    func results() async throws -> Result
    func defaultResult() async -> DefaultValue?
}

extension DynamicOptionsProvider {
    public static var useForParameterResolution: Bool { true }
    public func defaultResult() async -> DefaultValue? { nil }
}

public protocol AppEntity: AppValue, DisplayRepresentable, Identifiable where Self == ValueType, ID: EntityIdentifierConvertible, ID: Sendable {
    associatedtype DefaultQuery: EntityQuery where ValueType == DefaultQuery.Entity
    static var defaultQuery: DefaultQuery { get }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, *)
public protocol FileEntity: AppEntity where ID == FileEntityIdentifier {
    static var supportedContentTypes: [UTType] { get }
}

extension AppEntity {
    public static var defaultResolverSpecification: EmptyResolverSpecification<Self> { EmptyResolverSpecification() }
}

extension AppEntity where Self: CaseDisplayRepresentable {
    public var displayRepresentation: DisplayRepresentation {
        Self.caseDisplayRepresentations[self] ?? DisplayRepresentation(title: localizedStringResource)
    }
}

@available(macOS 15.0, iOS 18.0, visionOS 2.0, *)
@available(watchOS, unavailable)
@available(tvOS, unavailable)
public protocol IndexedEntity: AppEntity {
    var attributeSet: CSSearchableItemAttributeSet { get }
    @available(macOS 15.4, iOS 18.4, visionOS 2.4, *)
    var hideInSpotlight: Bool { get }
}

@available(macOS 15.0, iOS 18.0, visionOS 2.0, *)
@available(watchOS, unavailable)
@available(tvOS, unavailable)
extension IndexedEntity {
    public var defaultAttributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .item)
        attributes.title = String(localized: displayRepresentation.title)
        return attributes
    }

    public var attributeSet: CSSearchableItemAttributeSet { defaultAttributeSet }
}

@available(macOS 15.4, iOS 18.4, visionOS 2.4, *)
@available(watchOS, unavailable)
@available(tvOS, unavailable)
extension IndexedEntity {
    public var hideInSpotlight: Bool { false }
}

public protocol EntityQuery: DynamicOptionsProvider, PersistentlyIdentifiable, Sendable {
    associatedtype Entity: AppEntity = Result.Result.ValueType where Entity == Result.Result
    associatedtype Result: ResultsCollection = [Entity]
    init()
    func entities(for identifiers: [Entity.ID]) async throws -> [Entity]
    func suggestedEntities() async throws -> Result
    func displayRepresentations(for identifiers: [Entity.ID], requestedComponents: DisplayRepresentation.Components) async throws -> [Entity.ID: DisplayRepresentation]
}

extension EntityQuery {
    public func suggestedEntities() async throws -> Result { .empty }

    public func results() async throws -> Result { try await suggestedEntities() }

    public func displayRepresentations(for identifiers: [Entity.ID], requestedComponents: DisplayRepresentation.Components) async throws -> [Entity.ID: DisplayRepresentation] {
        let entities = try await entities(for: identifiers)
        var representations: [Entity.ID: DisplayRepresentation] = [:]
        representations.reserveCapacity(entities.count)
        for entity in entities {
            representations[entity.id] = await entity.displayRepresentation(with: requestedComponents)
        }
        return representations
    }
}

public protocol EntityStringQuery: EntityQuery {
    func entities(matching string: String) async throws -> Result
}

public protocol EnumerableEntityQuery: EntityQuery {
    func allEntities() async throws -> Result
    static var findIntentDescription: IntentDescription? { get }
}

extension EnumerableEntityQuery {
    public static var findIntentDescription: IntentDescription? { nil }
    public func suggestedEntities() async throws -> Result { try await allEntities() }
}

// MARK: - Entity-property queries

public protocol EntityPropertyQuery: EntityQuery {
    associatedtype ComparatorMappingType
    static var properties: QueryProperties { get }
    static var sortingOptions: SortingOptions { get }
    static var findIntentDescription: IntentDescription? { get }
    func entities(matching comparators: [ComparatorMappingType], mode: ComparatorMode,
                  sortedBy: [EntityQuerySort<Entity>], limit: Int?) async throws -> Result
}

extension EntityPropertyQuery {
    public typealias ComparatorMode = EntityQueryComparatorMode
    public typealias QueryProperties = EntityQueryProperties<Self.Entity, Self.ComparatorMappingType>
    public typealias Property = EntityQueryProperty
    public typealias SortingOptions = EntityQuerySortingOptions<Self.Entity>
    public typealias SortableBy = EntityQuerySortableByProperty<Self.Entity>
    public typealias Sort = EntityQuerySort
}

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
extension EntityPropertyQuery {
    public static var findIntentDescription: IntentDescription? { nil }
}

@frozen public enum EntityQueryComparatorMode: Sendable {
    case and
    case or
}

extension EntityQueryComparatorMode: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.and, .and), (.or, .or): true
        default: false
        }
    }
}

extension EntityQueryComparatorMode: Hashable {}

public class EntityQueryComparator<Property, PropertyType, InputType, ComparatorMappingType>
where Property: EntityProperty<PropertyType>, PropertyType: _IntentValue, PropertyType: Sendable,
      InputType: _IntentValue {
    fileprivate let mappingTransform: Any

    internal init(_ mappingTransform: Any) {
        self.mappingTransform = mappingTransform
    }
}

public struct AnyEntityQueryComparator<Entity, Subject, Property, PropertyType, ComparatorMappingType>
where Property: EntityProperty<PropertyType>, PropertyType: _IntentValue, PropertyType: Sendable {
    fileprivate let comparator: Any

    internal init<Comparator>(_ comparator: Comparator) {
        self.comparator = comparator
    }
}

@resultBuilder
public enum EntityQueryComparatorsBuilder<Entity, Subject, Property, PropertyType, ComparatorMappingType>
where Entity: AppEntity, Subject: AppEntity, Property: EntityProperty<PropertyType>,
      PropertyType: _IntentValue, PropertyType: Sendable {
    public static func buildExpression(
        _ expression: EntityQueryComparator<Property, PropertyType, PropertyType, ComparatorMappingType>
    ) -> AnyEntityQueryComparator<Entity, Subject, Property, PropertyType, ComparatorMappingType> {
        AnyEntityQueryComparator(expression)
    }

    public static func buildExpression(
        _ expression: EntityQueryComparator<Property, PropertyType, PropertyType.UnwrappedType, ComparatorMappingType>
    ) -> AnyEntityQueryComparator<Entity, Subject, Property, PropertyType, ComparatorMappingType>
    where PropertyType: ExpressibleByNilLiteral {
        AnyEntityQueryComparator(expression)
    }

    public static func buildExpression<InputType>(
        _ expression: ContainsComparator<Property, PropertyType, InputType, ComparatorMappingType>
    ) -> AnyEntityQueryComparator<Entity, Subject, Property, PropertyType, ComparatorMappingType>
    where InputType: _IntentValue {
        AnyEntityQueryComparator(expression)
    }

    public static func buildExpression<InputType>(
        _ expression: IsBetweenComparator<Property, PropertyType, InputType, ComparatorMappingType>
    ) -> AnyEntityQueryComparator<Entity, Subject, Property, PropertyType, ComparatorMappingType>
    where InputType: Comparable, InputType == PropertyType.UnwrappedType {
        AnyEntityQueryComparator(expression)
    }

    public static func buildBlock(
        _ components: AnyEntityQueryComparator<Entity, Subject, Property, PropertyType, ComparatorMappingType>...
    ) -> [AnyEntityQueryComparator<Entity, Subject, Property, PropertyType, ComparatorMappingType>] {
        components
    }
}

public class EntityQueryPropertyDeclaration<Entity, ComparatorMappingType> {
    internal init() {}
}

public final class EntityQueryProperty<Entity, Subject, Property, PropertyType, ComparatorMappingType>:
    EntityQueryPropertyDeclaration<Entity, ComparatorMappingType>
where Entity: AppEntity, Subject: AppEntity, Property: EntityProperty<PropertyType>,
      PropertyType: _IntentValue, PropertyType: Sendable {
    public typealias QueryComparators = [AnyEntityQueryComparator<Entity, Subject, Property, PropertyType, ComparatorMappingType>]

    fileprivate let keyPath: KeyPath<Subject, Property>
    fileprivate let entityProvider: (Entity) -> Subject
    fileprivate let queryComparators: QueryComparators

    public init(_ keyPath: KeyPath<Subject, Property>, entityProvider: @escaping (Entity) -> Subject,
                @EntityQueryComparatorsBuilder<Entity, Subject, Property, PropertyType, ComparatorMappingType>
                comparators: () -> QueryComparators) {
        self.keyPath = keyPath
        self.entityProvider = entityProvider
        queryComparators = comparators()
        super.init()
    }

    public convenience init(_ keyPath: KeyPath<Subject, Property>,
                            @EntityQueryComparatorsBuilder<Entity, Entity, Property, PropertyType, ComparatorMappingType>
                            comparators: () -> [AnyEntityQueryComparator<Entity, Entity, Property, PropertyType, ComparatorMappingType>])
    where Entity == Subject {
        self.init(keyPath, entityProvider: { $0 }, comparators: comparators)
    }
}

@resultBuilder
public enum EntityQueryPropertiesBuilder<Entity, ComparatorMappingType> where Entity: AppEntity {
    public static func buildExpression(
        _ expression: EntityQueryPropertyDeclaration<Entity, ComparatorMappingType>
    ) -> EntityQueryPropertyDeclaration<Entity, ComparatorMappingType> {
        expression
    }

    public static func buildBlock(
        _ components: EntityQueryPropertyDeclaration<Entity, ComparatorMappingType>...
    ) -> [EntityQueryPropertyDeclaration<Entity, ComparatorMappingType>] {
        components
    }
}

public struct EntityQueryProperties<Entity, ComparatorMappingType> where Entity: AppEntity {
    private let declarations: [EntityQueryPropertyDeclaration<Entity, ComparatorMappingType>]

    public init(@EntityQueryPropertiesBuilder<Entity, ComparatorMappingType>
                properties: () -> [EntityQueryPropertyDeclaration<Entity, ComparatorMappingType>]) {
        declarations = properties()
    }

    public subscript(index: Int) -> EntityQueryPropertyDeclaration<Entity, ComparatorMappingType> {
        declarations[index]
    }
}

public struct EntityQuerySortableByProperty<Entity> where Entity: AppEntity {
    fileprivate let keyPath: PartialKeyPath<Entity>

    public init<Property>(_ keyPath: KeyPath<Entity, Property>) where Property: AnyIntentValue {
        self.keyPath = keyPath
    }
}

@resultBuilder
public enum EntityQuerySortingOptionsBuilder<Entity> where Entity: AppEntity {
    public static func buildExpression(_ expression: EntityQuerySortableByProperty<Entity>) -> EntityQuerySortableByProperty<Entity> {
        expression
    }

    public static func buildBlock(_ components: EntityQuerySortableByProperty<Entity>...) -> [EntityQuerySortableByProperty<Entity>] {
        components
    }
}

public struct EntityQuerySortingOptions<Entity> where Entity: AppEntity {
    private let properties: [EntityQuerySortableByProperty<Entity>]

    public init() {
        properties = []
    }

    public init(@EntityQuerySortingOptionsBuilder<Entity>
                content: () -> [EntityQuerySortableByProperty<Entity>]) {
        properties = content()
    }

    public subscript(index: Int) -> EntityQuerySortableByProperty<Entity> {
        properties[index]
    }
}

public struct EntityQuerySort<Entity> where Entity: AppEntity {
    @frozen
    public enum Ordering: Sendable {
        case ascending
        case descending
    }

    public let by: PartialKeyPath<Entity>
    public let order: Ordering

    public init(by: PartialKeyPath<Entity>, order: Ordering) {
        self.by = by
        self.order = order
    }
}

extension EntityQuerySort.Ordering: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.ascending, .ascending), (.descending, .descending): true
        default: false
        }
    }
}

extension EntityQuerySort.Ordering: Hashable {}

public final class EqualToComparator<Property, PropertyType, ComparatorMappingType>:
    EntityQueryComparator<Property, PropertyType, PropertyType, ComparatorMappingType>
where Property: EntityProperty<PropertyType>, PropertyType: _IntentValue,
      PropertyType: Equatable, PropertyType: Sendable {
    public init(mappingTransform: @escaping (PropertyType) -> ComparatorMappingType) {
        super.init(mappingTransform)
    }
}

public final class NotEqualToComparator<Property, PropertyType, ComparatorMappingType>:
    EntityQueryComparator<Property, PropertyType, PropertyType, ComparatorMappingType>
where Property: EntityProperty<PropertyType>, PropertyType: _IntentValue,
      PropertyType: Equatable, PropertyType: Sendable {
    public init(mappingTransform: @escaping (PropertyType) -> ComparatorMappingType) {
        super.init(mappingTransform)
    }
}

public final class GreaterThanComparator<Property, PropertyType, ComparatorMappingType>:
    EntityQueryComparator<Property, PropertyType, PropertyType.UnwrappedType, ComparatorMappingType>
where Property: EntityProperty<PropertyType>, PropertyType: _IntentValue, PropertyType: Sendable,
      PropertyType.UnwrappedType: Comparable {
    public init(mappingTransform: @escaping (PropertyType.UnwrappedType) -> ComparatorMappingType) {
        super.init(mappingTransform)
    }
}

public final class LessThanComparator<Property, PropertyType, ComparatorMappingType>:
    EntityQueryComparator<Property, PropertyType, PropertyType.UnwrappedType, ComparatorMappingType>
where Property: EntityProperty<PropertyType>, PropertyType: _IntentValue, PropertyType: Sendable,
      PropertyType.UnwrappedType: Comparable {
    public init(mappingTransform: @escaping (PropertyType.UnwrappedType) -> ComparatorMappingType) {
        super.init(mappingTransform)
    }
}

public final class GreaterThanOrEqualToComparator<Property, PropertyType, ComparatorMappingType>:
    EntityQueryComparator<Property, PropertyType, PropertyType.UnwrappedType, ComparatorMappingType>
where Property: EntityProperty<PropertyType>, PropertyType: _IntentValue, PropertyType: Sendable,
      PropertyType.UnwrappedType: Comparable {
    public init(mappingTransform: @escaping (PropertyType.UnwrappedType) -> ComparatorMappingType) {
        super.init(mappingTransform)
    }
}

public final class LessThanOrEqualToComparator<Property, PropertyType, ComparatorMappingType>:
    EntityQueryComparator<Property, PropertyType, PropertyType.UnwrappedType, ComparatorMappingType>
where Property: EntityProperty<PropertyType>, PropertyType: _IntentValue, PropertyType: Sendable,
      PropertyType.UnwrappedType: Comparable {
    public init(mappingTransform: @escaping (PropertyType.UnwrappedType) -> ComparatorMappingType) {
        super.init(mappingTransform)
    }
}

public final class IsBetweenComparator<Property, PropertyType, InputType, ComparatorMappingType>:
    EntityQueryComparator<Property, PropertyType, InputType, ComparatorMappingType>
where Property: EntityProperty<PropertyType>, PropertyType: _IntentValue, PropertyType: Sendable,
      InputType: Comparable, InputType == PropertyType.UnwrappedType {
    public init(mappingTransform: @escaping (InputType, InputType) -> ComparatorMappingType) {
        super.init(mappingTransform)
    }
}

public final class ContainsComparator<Property, PropertyType, InputType, ComparatorMappingType>:
    EntityQueryComparator<Property, PropertyType, InputType, ComparatorMappingType>
where Property: EntityProperty<PropertyType>, PropertyType: _IntentValue, PropertyType: Sendable,
      InputType: _IntentValue {
    public init(mappingTransform: @escaping (InputType) -> ComparatorMappingType)
    where Property: EntityProperty<String>, PropertyType == String, InputType == String {
        super.init(mappingTransform)
    }
}

// MARK: - App-owned values

public protocol AnyIntentValue: Sendable {
    associatedtype Value: _IntentValue, Sendable
    var isOptional: Bool { get }
    var title: LocalizedStringResource { get }
}

@propertyWrapper
public final class EntityProperty<Value>: AnyIntentValue, @unchecked Sendable where Value: _IntentValue, Value: Sendable {
    private var storedValue: Value?
    private var defaultValue: Value.UnwrappedType?
    public final var title: LocalizedStringResource

    @available(*, unavailable)
    public init() {
        fatalError("Use an entity property initializer")
    }

    init(title: LocalizedStringResource, defaultValue: Value.UnwrappedType? = nil) {
        self.title = title
        self.defaultValue = defaultValue
    }

    public final var isOptional: Bool { Value.self != Value.UnwrappedType.self }
    public final var projectedValue: EntityProperty<Value> { self }

    fileprivate var urlRepresentationValue: Any? {
        if let storedValue { return storedValue }
        if let value = defaultValue as? Value { return value }
        if let defaultValue,
           let value = Optional<Value.UnwrappedType>.some(defaultValue) as? Value {
            return value
        }
        if let value = Optional<Value.UnwrappedType>.none as? Value { return value }
        return nil
    }

    public final var wrappedValue: Value {
        get {
            if let storedValue { return storedValue }
            if let value = defaultValue as? Value { return value }
            if let defaultValue, let optional = Optional<Value.UnwrappedType>.some(defaultValue) as? Value {
                return optional
            }
            if let none = Optional<Value.UnwrappedType>.none as? Value { return none }
            fatalError("AppIntents: \(title.key) has no value")
        }
        set { storedValue = newValue }
    }
}

extension EntityProperty where Value.ValueType == String {
    public convenience init(title: LocalizedStringResource) { self.init(title: title, defaultValue: nil) }
    public convenience init() { self.init(title: "", defaultValue: nil) }
}

extension EntityProperty where Value.ValueType == Int {
    public convenience init(title: LocalizedStringResource) { self.init(title: title, defaultValue: nil) }
    public convenience init() { self.init(title: "", defaultValue: nil) }
}

extension EntityProperty where Value.ValueType == Double {
    public convenience init(title: LocalizedStringResource) { self.init(title: title, defaultValue: nil) }
    public convenience init() { self.init(title: "", defaultValue: nil) }
}

extension EntityProperty where Value.ValueType == Bool {
    public convenience init(title: LocalizedStringResource) { self.init(title: title, defaultValue: nil) }
    public convenience init() { self.init(title: "", defaultValue: nil) }
}

extension EntityProperty where Value.ValueType == Date {
    public convenience init(title: LocalizedStringResource) { self.init(title: title, defaultValue: nil) }
    public convenience init() { self.init(title: "", defaultValue: nil) }
}

extension EntityProperty where Value.ValueType == DateComponents {
    public convenience init(title: LocalizedStringResource) { self.init(title: title, defaultValue: nil) }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, *)
    public convenience init() { self.init(title: "", defaultValue: nil) }
}

extension EntityProperty where Value.ValueType == URL {
    public convenience init(title: LocalizedStringResource) { self.init(title: title, defaultValue: nil) }
    public convenience init() { self.init(title: "", defaultValue: nil) }
}

extension EntityProperty where Value.ValueType == AttributedString {
    public convenience init(title: LocalizedStringResource) { self.init(title: title, defaultValue: nil) }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, *)
    public convenience init() { self.init(title: "", defaultValue: nil) }
}

extension EntityProperty where Value.ValueType == IntentFile {
    public convenience init(title: LocalizedStringResource) { self.init(title: title, defaultValue: nil) }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, *)
    public convenience init() { self.init(title: "", defaultValue: nil) }
}

extension EntityProperty where Value.ValueType: AppEntity {
    public convenience init(title: LocalizedStringResource) { self.init(title: title, defaultValue: nil) }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, *)
    public convenience init() { self.init(title: "", defaultValue: nil) }
}

extension EntityProperty where Value.ValueType: AppEnum {
    public convenience init(title: LocalizedStringResource) { self.init(title: title, defaultValue: nil) }
    public convenience init() { self.init(title: "", defaultValue: nil) }
}

private struct AppDependencyKey: Hashable {
    let type: ObjectIdentifier
    let key: AnyHashable?
}

private enum AppDependencyProvider {
    case value(@Sendable () -> Any)
    case throwing(() throws -> Any)
    case asynchronous(@Sendable () async throws -> Any)
}

private final class AppDependencyEntry {
    let provider: AppDependencyProvider
    var cachedValue: Any?

    init(_ provider: AppDependencyProvider) { self.provider = provider }
}

final public class AppDependencyManager: @unchecked Sendable {
    public static let shared = AppDependencyManager()

    private let lock = NSRecursiveLock()
    private var entries: [AppDependencyKey: AppDependencyEntry] = [:]

    public init() {}

    @_silgen_name("$s10AppIntents0A17DependencyManagerC3add3key10dependencyys11AnyHashableVSg_xyXAts8SendableRzlF")
    @_disfavoredOverload
    final public func add<Dependency>(key: AnyHashable? = nil,
                                      dependency dependencyProvider: @autoclosure @escaping @Sendable () -> Dependency)
    where Dependency: Sendable {
        store(.value { dependencyProvider() }, type: Dependency.self, key: key)
    }

    @_silgen_name("$s10AppIntents0A17DependencyManagerC3add3key10dependencyys11AnyHashableVSg_xyKcyXAts8SendableRzlF")
    final public func add<Dependency>(key: AnyHashable? = nil,
                                      dependency dependencyProvider: @autoclosure @escaping () -> @Sendable () throws -> Dependency)
    where Dependency: Sendable {
        let provider = dependencyProvider()
        store(.throwing { try provider() }, type: Dependency.self, key: key)
    }

    @_silgen_name("$s10AppIntents0A17DependencyManagerC3add3key10dependencyys11AnyHashableVSg_xyYaKcts8SendableRzlF")
    final public func add<Dependency>(key: AnyHashable? = nil,
                                      dependency dependencyProvider: @escaping @Sendable () async throws -> Dependency)
    where Dependency: Sendable {
        store(.asynchronous { try await dependencyProvider() }, type: Dependency.self, key: key)
    }

    private func store<Value>(_ provider: AppDependencyProvider, type: Value.Type, key: AnyHashable?) {
        let dependencyKey = AppDependencyKey(type: ObjectIdentifier(type), key: key)
        lock.lock()
        entries[dependencyKey] = AppDependencyEntry(provider)
        lock.unlock()
    }

    fileprivate func resolve<Value: Sendable>(_ type: Value.Type, key: AnyHashable?) -> Result<Value, Swift.Error>? {
        let dependencyKey = AppDependencyKey(type: ObjectIdentifier(type), key: key)
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[dependencyKey] else { return nil }
        if let cached = entry.cachedValue {
            guard let value = cached as? Value else {
                return .failure(Error<Value>.incorrectDependencyType(key ?? AnyHashable(String(reflecting: type)), type, Swift.type(of: cached)))
            }
            return .success(value)
        }
        switch entry.provider {
        case .value(let provider):
            let value = provider()
            entry.cachedValue = value
            guard let typed = value as? Value else {
                return .failure(Error<Value>.incorrectDependencyType(key ?? AnyHashable(String(reflecting: type)), type, Swift.type(of: value)))
            }
            return .success(typed)
        case .throwing(let provider):
            do {
                let value = try provider()
                entry.cachedValue = value
                guard let typed = value as? Value else {
                    return .failure(Error<Value>.incorrectDependencyType(key ?? AnyHashable(String(reflecting: type)), type, Swift.type(of: value)))
                }
                return .success(typed)
            } catch {
                return .failure(Error<Value>.failedToLoadDependency(key ?? AnyHashable(String(reflecting: type)), type))
            }
        case .asynchronous:
            return .failure(Error<Value>.failedToRetrieveDependency(key ?? AnyHashable(String(reflecting: type)), type))
        }
    }

    public enum Error<Value>: LocalizedError, @unchecked Sendable {
        case failedToRetrieveDependency(AnyHashable, Value.Type)
        case failedToLoadDependency(AnyHashable, Value.Type)
        case incorrectDependencyType(AnyHashable, Value.Type, any Any.Type)

        public var errorDescription: String? {
            switch self {
            case .failedToRetrieveDependency(let key, let type):
                "No local dependency registered for \(key) (\(type))"
            case .failedToLoadDependency(let key, let type):
                "The local dependency provider failed for \(key) (\(type))"
            case .incorrectDependencyType(let key, let expected, let actual):
                "The local dependency for \(key) was \(actual), not \(expected)"
            }
        }
    }
}

@propertyWrapper
final public class AppDependency<Value>: @unchecked Sendable where Value: Sendable {
    private let key: AnyHashable?
    private let manager: AppDependencyManager
    private let defaultProvider: (() -> Value)?
    private let asynchronousDefaultProvider: (() async throws -> Value)?
    private var storedValue: Value?

    @available(*, unavailable)
    public init() { fatalError("Use an app dependency initializer") }

    convenience public init(key: AnyHashable? = nil, manager: AppDependencyManager = .shared) {
        self.init(key: key, manager: manager, defaultProvider: nil, asynchronousDefaultProvider: nil)
    }

    convenience public init(key: AnyHashable? = nil, manager: AppDependencyManager = .shared,
                            default defaultValueProvider: @autoclosure @escaping () -> Value) {
        self.init(key: key, manager: manager, defaultProvider: { defaultValueProvider() }, asynchronousDefaultProvider: nil)
    }

    convenience public init(key: AnyHashable? = nil, manager: AppDependencyManager = .shared,
                            default defaultValueProvider: @escaping () async throws -> Value) {
        self.init(key: key, manager: manager, defaultProvider: nil, asynchronousDefaultProvider: defaultValueProvider)
    }

    private init(key: AnyHashable?, manager: AppDependencyManager, defaultProvider: (() -> Value)?,
                 asynchronousDefaultProvider: (() async throws -> Value)?) {
        self.key = key
        self.manager = manager
        self.defaultProvider = defaultProvider
        self.asynchronousDefaultProvider = asynchronousDefaultProvider
    }

    final public var projectedValue: AppDependency<Value> { self }

    final public var wrappedValue: Value {
        get {
            if let storedValue { return storedValue }
            if let result = manager.resolve(Value.self, key: key) {
                switch result {
                case .success(let value): return value
                case .failure(let error): fatalError(error.localizedDescription)
                }
            }
            if let defaultProvider { return defaultProvider() }
            if asynchronousDefaultProvider != nil {
                AppIntentsSystemServices.recordUnavailable("asynchronous dependency resolution")
                fatalError("AppIntents: asynchronous dependencies require the unavailable intent runner")
            }
            fatalError(AppDependencyManager.Error<Value>.failedToRetrieveDependency(
                key ?? AnyHashable(String(reflecting: Value.self)), Value.self
            ).localizedDescription)
        }
        set { storedValue = newValue }
    }
}

// MARK: - Files

public struct IntentFile: Sendable {
    public enum IntentFileError: Error, CustomNSError, Hashable {
        case failedToLoadData
        case failedToLoadFile

        public static var errorDomain: String { "AppIntents.IntentFile" }
        public var errorCode: Int { self == .failedToLoadData ? 1 : 2 }
        public var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: "The intent file could not be loaded"] }
    }

    private let storedData: Data?
    private let storedFileURL: URL?
    public let filename: String
    public let type: UTType?
    public var removedOnCompletion: Bool

    public var data: Data {
        if let storedData { return storedData }
        guard let storedFileURL, let data = try? Data(contentsOf: storedFileURL) else {
            preconditionFailure("AppIntents: the intent file could not be read")
        }
        return data
    }

    public var fileURL: URL? { storedFileURL }

    public init(data: Data, filename: String, type: UTType? = nil) {
        storedData = data
        storedFileURL = nil
        self.filename = filename
        self.type = type
        removedOnCompletion = false
    }

    public init(fileURL: URL, filename: String? = nil, type: UTType? = nil) {
        storedData = nil
        storedFileURL = fileURL
        self.filename = filename ?? fileURL.lastPathComponent
        self.type = type ?? UTType(filenameExtension: fileURL.pathExtension)
        removedOnCompletion = false
    }

    public func file(contentType: UTType, destinationDirectory: URL? = nil) async throws -> (fileURL: URL, openedInPlace: Bool) {
        guard type == nil || type!.conforms(to: contentType) else { throw IntentFileError.failedToLoadFile }
        if let storedFileURL, destinationDirectory == nil { return (storedFileURL, true) }
        let directory = destinationDirectory ?? FileManager.default.temporaryDirectory
        let destination = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(URL(fileURLWithPath: filename).pathExtension)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            return (destination, false)
        } catch {
            throw IntentFileError.failedToLoadFile
        }
    }

    public func withFile<Result>(contentType: UTType, allowOpenInPlace: Bool = false,
                                 fileHandler: @escaping (URL, Bool) async throws -> Result) async throws -> Result {
        if allowOpenInPlace, let storedFileURL, type == nil || type!.conforms(to: contentType) {
            return try await fileHandler(storedFileURL, true)
        }
        let resolved = try await file(contentType: contentType)
        defer {
            if !removedOnCompletion && resolved.openedInPlace == false {
                try? FileManager.default.removeItem(at: resolved.fileURL)
            }
        }
        return try await fileHandler(resolved.fileURL, resolved.openedInPlace)
    }

    public func data(contentType: UTType) async throws -> Data {
        guard type == nil || type!.conforms(to: contentType) else { throw IntentFileError.failedToLoadData }
        if let storedData { return storedData }
        guard let storedFileURL, let data = try? Data(contentsOf: storedFileURL) else { throw IntentFileError.failedToLoadData }
        return data
    }

    public var availableContentTypes: [UTType] { type.map { [$0] } ?? [.item] }
}

extension IntentFile: Equatable {
    public static func == (lhs: IntentFile, rhs: IntentFile) -> Bool {
        lhs.filename == rhs.filename && lhs.type == rhs.type && lhs.fileURL == rhs.fileURL && lhs.data == rhs.data
    }
}

extension IntentFile: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(filename)
        hasher.combine(type)
        hasher.combine(fileURL)
        hasher.combine(data)
    }
}

extension IntentFile: DisplayRepresentable {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "File" }
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: LocalizedStringResource(stringLiteral: filename)) }
}

extension IntentFile: _IntentValue {
    public static var defaultResolverSpecification: EmptyResolverSpecification<IntentFile> { EmptyResolverSpecification() }
}

extension IntentFile: Codable {
    private enum CodingKeys: String, CodingKey { case data, filename, type, removedOnCompletion }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let data = try container.decode(Data.self, forKey: .data)
        let filename = try container.decode(String.self, forKey: .filename)
        let typeIdentifier = try container.decodeIfPresent(String.self, forKey: .type)
        self.init(data: data, filename: filename, type: typeIdentifier.flatMap { UTType($0) })
        removedOnCompletion = try container.decodeIfPresent(Bool.self, forKey: .removedOnCompletion) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(data, forKey: .data)
        try container.encode(filename, forKey: .filename)
        try container.encodeIfPresent(type?.identifier, forKey: .type)
        try container.encode(removedOnCompletion, forKey: .removedOnCompletion)
    }
}

// MARK: - Dialogs and descriptions

public struct IntentDialog: ExpressibleByStringInterpolation, Sendable {
    let full: LocalizedStringResource
    let supporting: LocalizedStringResource?

    public init(_ string: LocalizedStringResource) {
        full = string
        supporting = nil
    }

    public init(full: LocalizedStringResource, supporting: LocalizedStringResource) {
        self.full = full
        self.supporting = supporting
    }

    public init(full: LocalizedStringResource, systemImageName: String) {
        self.full = full
        supporting = nil
    }

    public init(stringLiteral value: String) {
        full = LocalizedStringResource(stringLiteral: value)
        supporting = nil
    }

    public init(stringInterpolation: String.StringInterpolation) {
        full = LocalizedStringResource(stringLiteral: String(stringInterpolation: stringInterpolation))
        supporting = nil
    }
}

public struct IntentDescription: ExpressibleByStringLiteral {
    public var descriptionText: LocalizedStringResource
    public var categoryName: LocalizedStringResource?
    public var searchKeywords: [LocalizedStringResource]

    public init(_ descriptionText: LocalizedStringResource, categoryName: LocalizedStringResource? = nil,
                searchKeywords: [LocalizedStringResource] = []) {
        self.descriptionText = descriptionText
        self.categoryName = categoryName
        self.searchKeywords = searchKeywords
    }

    public init(stringLiteral value: String) {
        self.init(LocalizedStringResource(stringLiteral: value))
    }
}

extension IntentDescription: @unchecked Sendable {}

public struct IntentModes: OptionSet, Hashable, Equatable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public struct ForegroundMode: Hashable, Sendable {
        fileprivate let rawValue: Int

        private init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static var immediate: ForegroundMode { ForegroundMode(rawValue: 1 << 1) }
        public static var dynamic: ForegroundMode { ForegroundMode(rawValue: 1 << 3) }
        public static var deferred: ForegroundMode { ForegroundMode(rawValue: 1 << 2) }
    }

    public static func foreground(_ foregroundMode: ForegroundMode) -> IntentModes {
        IntentModes(rawValue: foregroundMode.rawValue)
    }

    public static var background: IntentModes { IntentModes(rawValue: 1) }
    public static var foreground: IntentModes { .foreground(.immediate) }
}

public struct IntentPerson: Sendable, Equatable {
    public enum Identifier: Equatable, Hashable, Sendable, Codable {
        case contact(String)
        case applicationDefined(String)
        case unknown
    }

    public enum Name: Equatable, Sendable, Codable {
        case displayName(String)
        case components(PersonNameComponents)
        case unknown
    }

    public struct Handle: Equatable, Hashable, Sendable, Codable {
        public enum Value: Equatable, Hashable, Sendable, Codable {
            case phoneNumber(String)
            case emailAddress(String)
            case applicationDefined(String)
        }

        public enum Label: Equatable, Hashable, Sendable, Codable {
            case home
            case work
            case iPhone
            case mobile
            case main
            case homeFax
            case workFax
            case pager
            case other
            case school
            case custom(String)
        }

        public var value: Value
        public var label: Label

        public init(_ value: Value, label: Label = .other) {
            self.value = value
            self.label = label
        }

        public init(phoneNumber: String, label: Label = .other) {
            self.init(.phoneNumber(phoneNumber), label: label)
        }

        public init(emailAddress: String, label: Label = .other) {
            self.init(.emailAddress(emailAddress), label: label)
        }

        public init(applicationDefined stringValue: String, label labelString: String? = nil) {
            self.init(.applicationDefined(stringValue), label: labelString.map(Label.custom) ?? .other)
        }
    }

    public enum ParameterMode: String, Equatable, Hashable, Sendable {
        case contact
        case email
        case phone
        case emailOrPhone
    }

    public var name: Name
    public var isMe: Bool
    public var identifier: Identifier
    public var handle: Handle?
    public var aliases: [Handle]
    public var image: DisplayRepresentation.Image?

    public init(identifier: Identifier, name: Name, handle: Handle?, aliases: [Handle] = [],
                isMe: Bool = false, image: DisplayRepresentation.Image? = nil) {
        self.name = name
        self.isMe = isMe
        self.identifier = identifier
        self.handle = handle
        self.aliases = aliases
        self.image = image
    }

    public init(handle: Handle) {
        self.init(identifier: .unknown, name: .unknown, handle: handle)
    }

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Person" }

    public var displayRepresentation: DisplayRepresentation {
        let title: String
        switch name {
        case .displayName(let value): title = value
        case .components(let components):
            title = PersonNameComponentsFormatter.localizedString(from: components, style: .default, options: [])
        case .unknown:
            title = handle.map(Self.handleDescription) ?? "Unknown"
        }
        let localizedTitle: LocalizedStringResource = "\(title)"
        return DisplayRepresentation(title: localizedTitle, image: image)
    }

    private static func handleDescription(_ handle: Handle) -> String {
        switch handle.value {
        case .phoneNumber(let value), .emailAddress(let value), .applicationDefined(let value): value
        }
    }
}

extension IntentPerson: DisplayRepresentable, _IntentValue {
    public static var defaultResolverSpecification: EmptyResolverSpecification<IntentPerson> {
        EmptyResolverSpecification()
    }
}

extension IntentPerson: Codable {}

public struct ConfirmationConditions: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let lowConfidenceSource = ConfirmationConditions(rawValue: 1 << 0)
}

public struct ConfirmationActionName: Sendable {
    private let value: String

    private init(_ value: String) { self.value = value }

    public static var `continue`: ConfirmationActionName { ConfirmationActionName("continue") }
}

public enum IntentAuthenticationPolicy: Sendable, Hashable {
    case alwaysAllowed
    case requiresAuthentication
    case requiresLocalDeviceAuthentication
}

public enum InputConnectionBehavior: Hashable {
    case `default`
    case never
    case connectToPreviousIntentResult
}

// MARK: - Parameters

extension String {
    public struct IntentInputOptions: Hashable, Sendable {
        public enum KeyboardType: Hashable, Sendable {
            case `default`, asciiCapable, numbersAndPunctuation, URL, numberPad
        }

        public enum CapitalizationType: Hashable, Sendable {
            case none, words, sentences, allCharacters
        }

        public var keyboardType: KeyboardType
        public var capitalizationType: CapitalizationType
        public var multiline: Bool
        public var autocorrect: Bool
        public var smartQuotes: Bool
        public var smartDashes: Bool

        public init(keyboardType: KeyboardType = .asciiCapable, capitalizationType: CapitalizationType = .sentences,
                    multiline: Bool = false, autocorrect: Bool = true, smartQuotes: Bool = true, smartDashes: Bool = true) {
            self.keyboardType = keyboardType
            self.capitalizationType = capitalizationType
            self.multiline = multiline
            self.autocorrect = autocorrect
            self.smartQuotes = smartQuotes
            self.smartDashes = smartDashes
        }
    }
}

extension Bool {
    public struct IntentDisplayName {
        public let `true`: LocalizedStringResource
        public let `false`: LocalizedStringResource

        public init(true: LocalizedStringResource, false: LocalizedStringResource) {
            self.true = `true`
            self.false = `false`
        }
    }
}

@propertyWrapper
public final class IntentParameter<Value>: @unchecked Sendable where Value: _IntentValue, Value: Sendable {
    public enum DateKind: Hashable {
        case date
        case time
        case dateTime
    }

    public final let defaultValue: Value.UnwrappedType?
    public final let title: LocalizedStringResource
    let parameterDescription: LocalizedStringResource?
    private let storedDateKind: DateKind?
    private let storedInputOptions: String.IntentInputOptions?
    private let storedDisplayName: Bool.IntentDisplayName?
    private let storedSupportedContentTypes: [UTType]?
    private let storedRequestValueDialog: IntentDialog?
    private let storedRequestDisambiguationDialog: IntentDialog?
    private let storedInputConnectionBehavior: InputConnectionBehavior
    private let storedSupportedValues: [Any]?
    private let storedDynamicOptionsProvider: Any?
    private let storedEntityQuery: Any?
    private var value: Value?

    public enum ValueState {
        case unset
        case set(Value)
    }

    @available(*, unavailable)
    public init() {
        fatalError("Use an intent parameter initializer")
    }

    init(title: LocalizedStringResource, description: LocalizedStringResource?, defaultValue: Value.UnwrappedType?,
         dateKind: DateKind? = nil,
         inputOptions: String.IntentInputOptions? = nil, displayName: Bool.IntentDisplayName? = nil,
         supportedContentTypes: [UTType]? = nil, requestValueDialog: IntentDialog? = nil,
         requestDisambiguationDialog: IntentDialog? = nil,
         inputConnectionBehavior: InputConnectionBehavior = .default,
         supportedValues: [Any]? = nil,
         dynamicOptionsProvider: Any? = nil,
         entityQuery: Any? = nil) {
        self.title = title
        parameterDescription = description
        storedDateKind = dateKind
        self.defaultValue = defaultValue
        storedInputOptions = inputOptions
        storedDisplayName = displayName
        storedSupportedContentTypes = supportedContentTypes
        storedRequestValueDialog = requestValueDialog
        storedRequestDisambiguationDialog = requestDisambiguationDialog
        storedInputConnectionBehavior = inputConnectionBehavior
        storedSupportedValues = supportedValues
        storedDynamicOptionsProvider = dynamicOptionsProvider
        storedEntityQuery = entityQuery
    }

    public final var isOptional: Bool { Value.self != Value.UnwrappedType.self }

    public final var projectedValue: IntentParameter<Value> { self }

    fileprivate var urlRepresentationValue: Any? {
        if let value { return value }
        if let value = defaultValue as? Value { return value }
        if let defaultValue,
           let value = Optional<Value.UnwrappedType>.some(defaultValue) as? Value {
            return value
        }
        if let value = Optional<Value.UnwrappedType>.none as? Value { return value }
        return nil
    }

    public final var valueState: ValueState {
        value.map { .set($0) } ?? .unset
    }

    public final var wrappedValue: Value {
        get {
            if let value { return value }
            if let d = defaultValue as? Value { return d }
            if let d = defaultValue, let wrapped = Optional<Value.UnwrappedType>.some(d) as? Value { return wrapped }
            if let none = Optional<Value.UnwrappedType>.none as? Value { return none }
            fatalError("AppIntents: \(title.key) has no value")
        }
        set { value = newValue }
    }
}

extension IntentParameter: AnyIntentValue {}

extension IntentParameter where Value.ValueType == String {
    public final var inputOptions: String.IntentInputOptions? { storedInputOptions }

    public convenience init(title: LocalizedStringResource, description: LocalizedStringResource? = nil,
                            default defaultValue: _const Value.UnwrappedType? = nil,
                            inputOptions: String.IntentInputOptions? = nil,
                            requestValueDialog: IntentDialog? = nil,
                            inputConnectionBehavior: _const InputConnectionBehavior = .default) {
        self.init(title: title, description: description, defaultValue: defaultValue, inputOptions: inputOptions,
                  requestValueDialog: requestValueDialog, inputConnectionBehavior: inputConnectionBehavior)
    }

    public convenience init(description: LocalizedStringResource? = nil,
                            default defaultValue: _const Value.UnwrappedType? = nil,
                            inputOptions: String.IntentInputOptions? = nil,
                            requestValueDialog: IntentDialog? = nil,
                            inputConnectionBehavior: _const InputConnectionBehavior = .default) {
        self.init(title: "", description: description, defaultValue: defaultValue, inputOptions: inputOptions,
                  requestValueDialog: requestValueDialog, inputConnectionBehavior: inputConnectionBehavior)
    }
}

extension IntentParameter where Value.ValueType == Bool {
    public final var displayName: Bool.IntentDisplayName? { storedDisplayName }

    public convenience init(title: LocalizedStringResource, description: LocalizedStringResource? = nil,
                            default defaultValue: _const Value.UnwrappedType? = nil,
                            displayName: Bool.IntentDisplayName? = nil,
                            requestValueDialog: IntentDialog? = nil,
                            inputConnectionBehavior: _const InputConnectionBehavior = .default) {
        self.init(title: title, description: description, defaultValue: defaultValue, displayName: displayName,
                  requestValueDialog: requestValueDialog, inputConnectionBehavior: inputConnectionBehavior)
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    public convenience init(description: LocalizedStringResource? = nil,
                            default defaultValue: _const Value.UnwrappedType? = nil,
                            displayName: Bool.IntentDisplayName? = nil,
                            requestValueDialog: IntentDialog? = nil,
                            inputConnectionBehavior: _const InputConnectionBehavior = .default) {
        self.init(title: "", description: description, defaultValue: defaultValue, displayName: displayName,
                  requestValueDialog: requestValueDialog, inputConnectionBehavior: inputConnectionBehavior)
    }
}

extension IntentParameter.ValueState: Equatable where Value: Equatable {
    public static func == (lhs: IntentParameter<Value>.ValueState, rhs: IntentParameter<Value>.ValueState) -> Bool {
        switch (lhs, rhs) {
        case (.unset, .unset): true
        case let (.set(a), .set(b)): a == b
        default: false
        }
    }
}

extension IntentParameter where Value.ValueType: AppEnum {
    public convenience init(title: LocalizedStringResource, description: LocalizedStringResource? = nil,
                            default defaultValue: _const Value.UnwrappedType? = nil, requestValueDialog: IntentDialog? = nil,
                            requestDisambiguationDialog: IntentDialog? = nil,
                            inputConnectionBehavior: _const InputConnectionBehavior = .default,
                            supportedValues: [Value.ValueType] = Array(Value.ValueType.allCases)) {
        self.init(title: title, description: description, defaultValue: defaultValue,
                  requestValueDialog: requestValueDialog,
                  requestDisambiguationDialog: requestDisambiguationDialog,
                  inputConnectionBehavior: inputConnectionBehavior, supportedValues: supportedValues)
    }

    public convenience init(description: LocalizedStringResource? = nil, default defaultValue: _const Value.UnwrappedType? = nil,
                            requestValueDialog: IntentDialog? = nil, requestDisambiguationDialog: IntentDialog? = nil,
                            inputConnectionBehavior: _const InputConnectionBehavior = .default,
                            supportedValues: [Value.ValueType] = Array(Value.ValueType.allCases)) {
        self.init(title: "", description: description, defaultValue: defaultValue,
                  requestValueDialog: requestValueDialog,
                  requestDisambiguationDialog: requestDisambiguationDialog,
                  inputConnectionBehavior: inputConnectionBehavior, supportedValues: supportedValues)
    }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, *)
extension IntentParameter where Value.ValueType: AppEntity {
    public convenience init(title: LocalizedStringResource, description: LocalizedStringResource? = nil,
                            default defaultValue: Value.UnwrappedType? = nil, requestValueDialog: IntentDialog? = nil,
                            requestDisambiguationDialog: IntentDialog? = nil,
                            inputConnectionBehavior: _const InputConnectionBehavior = .default) {
        self.init(title: title, description: description, defaultValue: defaultValue,
                  requestValueDialog: requestValueDialog,
                  requestDisambiguationDialog: requestDisambiguationDialog,
                  inputConnectionBehavior: inputConnectionBehavior)
    }

    public convenience init(description: LocalizedStringResource? = nil,
                            default defaultValue: Value.UnwrappedType? = nil, requestValueDialog: IntentDialog? = nil,
                            requestDisambiguationDialog: IntentDialog? = nil,
                            inputConnectionBehavior: _const InputConnectionBehavior = .default) {
        self.init(title: "", description: description, defaultValue: defaultValue,
                  requestValueDialog: requestValueDialog,
                  requestDisambiguationDialog: requestDisambiguationDialog,
                  inputConnectionBehavior: inputConnectionBehavior)
    }

    public convenience init<OptionsProvider: DynamicOptionsProvider>(
        title: LocalizedStringResource, description: LocalizedStringResource? = nil,
        default defaultValue: Value.UnwrappedType? = nil,
        requestValueDialog: IntentDialog? = nil,
        requestDisambiguationDialog: IntentDialog? = nil,
        inputConnectionBehavior: _const InputConnectionBehavior = .default,
        optionsProvider: OptionsProvider
    ) where OptionsProvider.DefaultValue.ValueType == Value.ValueType {
        self.init(title: title, description: description, defaultValue: defaultValue,
                  requestValueDialog: requestValueDialog,
                  requestDisambiguationDialog: requestDisambiguationDialog,
                  inputConnectionBehavior: inputConnectionBehavior,
                  dynamicOptionsProvider: optionsProvider)
    }

    public convenience init<Query: EntityQuery>(
        title: LocalizedStringResource, description: LocalizedStringResource? = nil,
        default defaultValue: Value.UnwrappedType? = nil,
        requestValueDialog: IntentDialog? = nil,
        requestDisambiguationDialog: IntentDialog? = nil,
        inputConnectionBehavior: _const InputConnectionBehavior = .default,
        query: Query
    ) where Query.Entity == Value.ValueType {
        self.init(title: title, description: description, defaultValue: defaultValue,
                  requestValueDialog: requestValueDialog,
                  requestDisambiguationDialog: requestDisambiguationDialog,
                  inputConnectionBehavior: inputConnectionBehavior, entityQuery: query)
    }
}

extension IntentParameter {
    public convenience init(title: LocalizedStringResource, description: LocalizedStringResource? = nil,
                            default defaultValue: _const Value.UnwrappedType? = nil,
                            requestValueDialog: IntentDialog? = nil,
                            inputConnectionBehavior: _const InputConnectionBehavior = .default) {
        self.init(title: title, description: description, defaultValue: defaultValue,
                  requestValueDialog: requestValueDialog, inputConnectionBehavior: inputConnectionBehavior)
    }
}

extension IntentParameter where Value.ValueType == IntentFile {
    public convenience init(title: LocalizedStringResource, description: LocalizedStringResource? = nil,
                            default defaultValue: Value.UnwrappedType? = nil,
                            supportedContentTypes: [UTType] = [.item],
                            requestValueDialog: IntentDialog? = nil,
                            inputConnectionBehavior: _const InputConnectionBehavior = .default) {
        self.init(title: title, description: description, defaultValue: defaultValue,
                  supportedContentTypes: supportedContentTypes, requestValueDialog: requestValueDialog,
                  inputConnectionBehavior: inputConnectionBehavior)
    }

    public convenience init(description: LocalizedStringResource? = nil,
                            default defaultValue: Value.UnwrappedType? = nil,
                            supportedContentTypes: [UTType] = [.item],
                            requestValueDialog: IntentDialog? = nil,
                            inputConnectionBehavior: _const InputConnectionBehavior = .default) {
        self.init(title: "", description: description, defaultValue: defaultValue,
                  supportedContentTypes: supportedContentTypes, requestValueDialog: requestValueDialog,
                  inputConnectionBehavior: inputConnectionBehavior)
    }
}

@available(macOS 14.2, iOS 17.2, watchOS 10.2, tvOS 17.2, *)
extension IntentParameter where Value.ValueType == StringSearchCriteria {
    public convenience init(title: LocalizedStringResource, description: LocalizedStringResource? = nil,
                            requestValueDialog: IntentDialog? = nil,
                            inputConnectionBehavior: _const InputConnectionBehavior = .default) {
        self.init(title: title, description: description, defaultValue: nil,
                  requestValueDialog: requestValueDialog, inputConnectionBehavior: inputConnectionBehavior)
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    public convenience init(description: LocalizedStringResource? = nil,
                            requestValueDialog: IntentDialog? = nil,
                            inputConnectionBehavior: _const InputConnectionBehavior = .default) {
        self.init(title: "", description: description, defaultValue: nil,
                  requestValueDialog: requestValueDialog, inputConnectionBehavior: inputConnectionBehavior)
    }
}

extension IntentParameter where Value.ValueType == URL {
    public convenience init(title: LocalizedStringResource, description: LocalizedStringResource? = nil,
                            default defaultValue: Value.UnwrappedType? = nil,
                            requestValueDialog: IntentDialog? = nil,
                            inputConnectionBehavior: _const InputConnectionBehavior = .default) {
        self.init(title: title, description: description, defaultValue: defaultValue,
                  requestValueDialog: requestValueDialog, inputConnectionBehavior: inputConnectionBehavior)
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    public convenience init(description: LocalizedStringResource? = nil,
                            default defaultValue: Value.UnwrappedType? = nil,
                            requestValueDialog: IntentDialog? = nil,
                            inputConnectionBehavior: _const InputConnectionBehavior = .default) {
        self.init(title: "", description: description, defaultValue: defaultValue,
                  requestValueDialog: requestValueDialog, inputConnectionBehavior: inputConnectionBehavior)
    }
}

extension IntentParameter where Value.ValueType == Date {
    public final var dateKind: DateKind? { storedDateKind }

    public convenience init(title: LocalizedStringResource, description: LocalizedStringResource? = nil,
                            kind: _const DateKind = .dateTime,
                            requestValueDialog: IntentDialog? = nil,
                            inputConnectionBehavior: _const InputConnectionBehavior = .default) {
        self.init(title: title, description: description, defaultValue: nil, dateKind: kind,
                  requestValueDialog: requestValueDialog, inputConnectionBehavior: inputConnectionBehavior)
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    public convenience init(title: LocalizedStringResource, description: LocalizedStringResource? = nil,
                            default defaultValue: Value.UnwrappedType? = nil,
                            kind: _const DateKind = .dateTime,
                            requestValueDialog: IntentDialog? = nil,
                            inputConnectionBehavior: _const InputConnectionBehavior = .default) {
        self.init(title: title, description: description, defaultValue: defaultValue, dateKind: kind,
                  requestValueDialog: requestValueDialog, inputConnectionBehavior: inputConnectionBehavior)
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    public convenience init(description: LocalizedStringResource? = nil,
                            default defaultValue: Value.UnwrappedType? = nil,
                            kind: _const DateKind = .dateTime,
                            requestValueDialog: IntentDialog? = nil,
                            inputConnectionBehavior: _const InputConnectionBehavior = .default) {
        self.init(title: "", description: description, defaultValue: defaultValue, dateKind: kind,
                  requestValueDialog: requestValueDialog, inputConnectionBehavior: inputConnectionBehavior)
    }
}

extension IntentParameter where Value.ValueType == DateComponents {
    public final var dateKind: DateKind? { storedDateKind }

    public convenience init(title: LocalizedStringResource, description: LocalizedStringResource? = nil,
                            kind: _const DateKind = .dateTime,
                            requestValueDialog: IntentDialog? = nil,
                            inputConnectionBehavior: _const InputConnectionBehavior = .default) {
        self.init(title: title, description: description, defaultValue: nil, dateKind: kind,
                  requestValueDialog: requestValueDialog, inputConnectionBehavior: inputConnectionBehavior)
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    public convenience init(title: LocalizedStringResource, description: LocalizedStringResource? = nil,
                            default defaultValue: Value.UnwrappedType? = nil,
                            kind: _const DateKind = .dateTime,
                            requestValueDialog: IntentDialog? = nil,
                            inputConnectionBehavior: _const InputConnectionBehavior = .default) {
        self.init(title: title, description: description, defaultValue: defaultValue, dateKind: kind,
                  requestValueDialog: requestValueDialog, inputConnectionBehavior: inputConnectionBehavior)
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    public convenience init(description: LocalizedStringResource? = nil,
                            default defaultValue: Value.UnwrappedType? = nil,
                            kind: _const DateKind = .dateTime,
                            requestValueDialog: IntentDialog? = nil,
                            inputConnectionBehavior: _const InputConnectionBehavior = .default) {
        self.init(title: "", description: description, defaultValue: defaultValue, dateKind: kind,
                  requestValueDialog: requestValueDialog, inputConnectionBehavior: inputConnectionBehavior)
    }
}

extension IntentParameter where Value.ValueType == AttributedString {
    public convenience init(title: LocalizedStringResource, description: LocalizedStringResource? = nil,
                            default defaultValue: _const Value.UnwrappedType? = nil,
                            requestValueDialog: IntentDialog? = nil,
                            inputConnectionBehavior: _const InputConnectionBehavior = .default) {
        self.init(title: title, description: description, defaultValue: defaultValue,
                  requestValueDialog: requestValueDialog, inputConnectionBehavior: inputConnectionBehavior)
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    public convenience init(description: LocalizedStringResource? = nil,
                            default defaultValue: _const Value.UnwrappedType? = nil,
                            requestValueDialog: IntentDialog? = nil,
                            inputConnectionBehavior: _const InputConnectionBehavior = .default) {
        self.init(title: "", description: description, defaultValue: defaultValue,
                  requestValueDialog: requestValueDialog, inputConnectionBehavior: inputConnectionBehavior)
    }
}

// MARK: - Intents and results

public struct AppIntentError: Error, CustomNSError, CustomStringConvertible, CustomLocalizedStringResourceConvertible, Equatable {
    private let message: String?
    private let customDescription: String?

    private init(_ message: String? = nil) {
        self.message = message
        customDescription = nil
    }

    fileprivate init(customDescription: String) {
        message = nil
        self.customDescription = customDescription
    }

    public static var restartPerform: AppIntentError { AppIntentError() }

    public var description: String {
        if let customDescription { return customDescription }
        if let message {
            return "AppIntent encountered the following predefined error: \(message)"
        }
        return "AppIntent encountered an error."
    }

    public var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource(stringLiteral: localizedResourceKey)
    }

    private var localizedResourceKey: String {
        switch message {
        case "You need to be signed in to complete this action": "SIGNIN_ERROR"
        case "Please complete your account setup to continue": "ACCOUNT_SETUP_ERROR"
        case "Please confirm the action on the device": "USER_CONFIRMATION_ERROR"
        case "Please grant Siri permission to the app.": "SIRI_PERMISSION_ERROR"
        case "Please grant Local Network permission to the app": "LOCAL_NETWORK_PERMISSION_ERROR"
        case "Please grant Bluetooth permission to the app": "BLUETOOTH_PERMISSION_ERROR"
        case "Please grant Photos permission to the app": "PHOTOS_PERMISSION_ERROR"
        case "Please grant Contacts permission to the app": "CONTACTS_PERMISSION_ERROR"
        case "Please grant Location permission to the app": "LOCATION_PERMISSION_ERROR"
        case "Please grant Precise Location permission to the app": "PRECISE_LOCATION_PERMISSION_ERROR"
        case "You need to be connected to internet for this action": "NETWORK_FAILURE_UNRECOVERABLE_ERROR"
        case "Not every action was completed": "PARTIAL_FAILURE_UNRECOVERABLE_ERROR"
        case "This current action is not allowed": "ACTION_NOT_ALLOWED_UNRECOVERABLE_ERROR"
        case "Something went wrong": "UNKNOWN_ERROR_UNRECOVERABLE_ERROR"
        case "This feature is not supported on this device": "UNSUPPORTED_ON_DEVICE_UNRECOVERABLE_ERROR"
        case "This feature is currently restricted (due to screen time restrictions, MDM profiles etc.)":
            "FEATURE_CURRENTLY_RESTRICTED_UNRECOVERABLE_ERROR"
        case "The entity was not found. Try changing your search criteria.": "ENTITY_NOT_FOUND_UNRECOVERABLE_ERROR"
        default: "%@"
        }
    }

    public static var errorDomain: String { "AppIntents.AppIntentError" }
    public var errorCode: Int { 1 }
    public var errorUserInfo: [String: Any] { [:] }

    public static func == (lhs: AppIntentError, rhs: AppIntentError) -> Bool {
        lhs.message == rhs.message && lhs.customDescription == rhs.customDescription
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    public enum UserActionRequired {
        public static let signin = AppIntentError("You need to be signed in to complete this action")
        public static let accountSetup = AppIntentError("Please complete your account setup to continue")
        public static let confirmation = AppIntentError("Please confirm the action on the device")
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    public enum PermissionRequired {
        public static let siri = AppIntentError("Please grant Siri permission to the app.")
        public static let localNetwork = AppIntentError("Please grant Local Network permission to the app")
        public static let bluetooth = AppIntentError("Please grant Bluetooth permission to the app")
        public static let photos = AppIntentError("Please grant Photos permission to the app")
        public static let contacts = AppIntentError("Please grant Contacts permission to the app")

        public static func location(precise: Bool = false) -> AppIntentError {
            AppIntentError(precise ? "Please grant Precise Location permission to the app" : "Please grant Location permission to the app")
        }
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    public enum Unrecoverable {
        public static let networkFailure = AppIntentError("You need to be connected to internet for this action")
        public static let partialFailure = AppIntentError("Not every action was completed")
        public static let notAllowed = AppIntentError("This current action is not allowed")
        @available(*, deprecated, message: "Prefer throwing an AppIntentError with a clear description")
        public static let unknown = AppIntentError("Something went wrong")
        public static let unsupportedOnDevice = AppIntentError("This feature is not supported on this device")
        public static let featureCurrentlyRestricted = AppIntentError("This feature is currently restricted (due to screen time restrictions, MDM profiles etc.)")
        public static let entityNotFound = AppIntentError("The entity was not found. Try changing your search criteria.")
    }
}

extension IntentParameter {
    public final func needsValueError(_ dialog: IntentDialog? = nil) -> AppIntentError {
        _ = dialog
        return AppIntentError(customDescription: "AppIntent has missing parameter value. You may need to set a default value in the initializer of your @Parameter, or using the default method on your Query.")
    }

    public final func needsDisambiguationError(among itemsToDisambiguate: [Value.ValueType],
                                                dialog: IntentDialog? = nil) -> AppIntentError {
        _ = itemsToDisambiguate
        _ = dialog
        return AppIntentError(customDescription: "AppIntent needs to disambiguate a parameter value.")
    }
}

public protocol IntentResult: Sendable {
    associatedtype Value: _IntentValue = Never
    associatedtype Snippet = Never
    associatedtype Dialog = Never
    var value: Value? { get }
    associatedtype OpensAppIntent: AppIntent = Never
}

public protocol ReturnsValue<Value>: IntentResult {}
public protocol OpensIntent: IntentResult {}
public protocol ProvidesDialog: IntentResult where Dialog == IntentDialog {}

/// A result's value and any dialog or follow-up intent, kept together for the caller.
public struct IntentResultContainer<Value: _IntentValue, OpensAppIntent: AppIntent, Snippet, Dialog>: IntentResult, @unchecked Sendable {
    public var value: Value?
    public var dialog: IntentDialog?
    public var opensIntent: OpensAppIntent?
    public var activityIdentifier: String?

    public init(value: Value? = nil, dialog: IntentDialog? = nil, opensIntent: OpensAppIntent? = nil,
                activityIdentifier: String? = nil) {
        self.value = value
        self.dialog = dialog
        self.opensIntent = opensIntent
        self.activityIdentifier = activityIdentifier
    }
}

extension IntentResult {
    public static func result() -> Self where Self == IntentResultContainer<Never, Never, Never, Never> {
        IntentResultContainer()
    }

    public static func result<Value>(value: Value) -> Self
    where Self == IntentResultContainer<Value, Never, Never, Never>, Value: _IntentValue {
        IntentResultContainer(value: value)
    }

    @_disfavoredOverload
    public static func result<OpensAppIntent>(opensIntent: OpensAppIntent) -> Self
    where Self == IntentResultContainer<Never, OpensAppIntent, Never, Never>, OpensAppIntent: AppIntent {
        _ = opensIntent
        AppIntentsSystemServices.recordUnavailable("OpenIntent")
        return IntentResultContainer()
    }

    @_disfavoredOverload
    public static func result<Value, OpensAppIntent>(value: Value, opensIntent: OpensAppIntent) -> Self
    where Self == IntentResultContainer<Value, OpensAppIntent, Never, Never>,
          Value: _IntentValue, OpensAppIntent: AppIntent {
        _ = opensIntent
        AppIntentsSystemServices.recordUnavailable("OpenIntent")
        return IntentResultContainer(value: value)
    }

    public static func result<Value, OpensAppIntent>(value: Value, opensIntent: OpensAppIntent) -> Self
    where Self == IntentResultContainer<Value, Never, Never, Never>,
          Value: _IntentValue, OpensAppIntent: AppIntent {
        _ = opensIntent
        AppIntentsSystemServices.recordUnavailable("OpenIntent")
        return IntentResultContainer(value: value)
    }

    public static func result(dialog: IntentDialog) -> Self
    where Self == IntentResultContainer<Never, Never, Never, IntentDialog> {
        IntentResultContainer(dialog: dialog)
    }

    public static func result<Value>(value: Value, dialog: IntentDialog) -> Self
    where Self == IntentResultContainer<Value, Never, Never, IntentDialog>, Value: _IntentValue {
        IntentResultContainer(value: value, dialog: dialog)
    }

    @_disfavoredOverload
    public static func result<OpensAppIntent>(opensIntent: OpensAppIntent, dialog: IntentDialog) -> Self
    where Self == IntentResultContainer<Never, OpensAppIntent, Never, IntentDialog>,
          OpensAppIntent: AppIntent {
        _ = opensIntent
        AppIntentsSystemServices.recordUnavailable("OpenIntent")
        return IntentResultContainer(dialog: dialog)
    }

    @_disfavoredOverload
    public static func result<Value, OpensAppIntent>(value: Value, opensIntent: OpensAppIntent,
                                                       dialog: IntentDialog) -> Self
    where Self == IntentResultContainer<Value, OpensAppIntent, Never, IntentDialog>,
          Value: _IntentValue, OpensAppIntent: AppIntent {
        _ = opensIntent
        AppIntentsSystemServices.recordUnavailable("OpenIntent")
        return IntentResultContainer(value: value, dialog: dialog)
    }
}

extension IntentResultContainer: ReturnsValue {}
extension IntentResultContainer: OpensIntent {}
extension IntentResultContainer: ProvidesDialog where Dialog == IntentDialog {}

extension Never: _IntentValue {
    public static var defaultResolverSpecification: EmptyResolverSpecification<Never> { EmptyResolverSpecification() }
}

extension Never: IntentResult {
    public var value: Never? { nil }
}

public protocol ParameterSummary {
    associatedtype Intent: AppIntent
}

extension Never: ParameterSummary {
    public typealias Intent = Never
}

public struct ParameterSummaryString<Intent>: ExpressibleByStringInterpolation {
    private let keyPaths: [PartialKeyPath<Intent>]
    private let formatString: String

    public init(_ value: String) {
        keyPaths = []
        formatString = value
    }

    public init(stringLiteral value: String) { self.init(value) }
    public init(stringInterpolation: StringInterpolation) {
        keyPaths = stringInterpolation.keyPaths
        formatString = stringInterpolation.formatString
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        fileprivate var keyPaths: [PartialKeyPath<Intent>] = []
        fileprivate var formatString: String

        public init(literalCapacity: Int, interpolationCount: Int) {
            formatString = ""
            formatString.reserveCapacity(literalCapacity + interpolationCount * 8)
            keyPaths.reserveCapacity(interpolationCount)
        }

        public mutating func appendLiteral(_ literal: String) { formatString.append(literal) }

        public mutating func appendInterpolation<Value, ParameterKeyPath>(_ subject: ParameterKeyPath)
        where Value: _IntentValue, Value: Sendable, ParameterKeyPath: KeyPath<Intent, IntentParameter<Value>> {
            keyPaths.append(subject)
            formatString.append("%\(keyPaths.count)")
        }
    }
}

extension ParameterSummaryString: @unchecked Sendable {}

public struct IntentParameterSummary<Intent: AppIntent>: ParameterSummary {
    private let string: ParameterSummaryString<Intent>?
    private let table: String?
    private let additionalParameterKeyPaths: [PartialKeyPath<Intent>]

    public init(_ string: ParameterSummaryString<Intent>, table: String? = nil,
                @ParameterKeyPathsBuilder _ additionalParameterKeyPaths: () -> [PartialKeyPath<Intent>]) {
        self.string = string
        self.table = table
        self.additionalParameterKeyPaths = additionalParameterKeyPaths()
    }

    public init(_ string: ParameterSummaryString<Intent>, table: String? = nil) {
        self.string = string
        self.table = table
        additionalParameterKeyPaths = []
    }

    public init(@ParameterKeyPathsBuilder _ additionalParameterKeyPaths: () -> [PartialKeyPath<Intent>]) {
        string = nil
        table = nil
        self.additionalParameterKeyPaths = additionalParameterKeyPaths()
    }

    public init() {
        string = nil
        table = nil
        additionalParameterKeyPaths = []
    }

    @resultBuilder
    public enum ParameterKeyPathsBuilder {
        public static func buildExpression<Value>(_ expression: KeyPath<Intent, IntentParameter<Value>>) -> PartialKeyPath<Intent>
        where Value: _IntentValue, Value: Sendable { expression }

        public static func buildBlock(_ blocks: PartialKeyPath<Intent>...) -> [PartialKeyPath<Intent>] { blocks }
    }
}

@resultBuilder
public enum ParameterSummaryBuilder<Intent: AppIntent> {
    public static func buildExpression<Summary>(_ expression: Summary) -> Summary
    where Summary: ParameterSummary, Intent == Summary.Intent { expression }

    public static func buildBlock<Summary>(_ block: Summary) -> Summary
    where Summary: ParameterSummary, Intent == Summary.Intent { block }
}

public protocol _ParameterSummarySwitchCase {
    associatedtype Intent: AppIntent
    associatedtype Value: _IntentValue
    associatedtype Summary: ParameterSummary
}

public struct ParameterSummaryCaseCondition<Intent: AppIntent, Value: _IntentValue, Summary: ParameterSummary>: _ParameterSummarySwitchCase {
    private let value: [Value]
    private let parameterSummary: Summary

    public init(_ value: Value, @ParameterSummaryBuilder<Intent> _ parameterSummary: () -> Summary) {
        self.value = [value]
        self.parameterSummary = parameterSummary()
    }

    public init(_ value: [Value], @ParameterSummaryBuilder<Intent> _ parameterSummary: () -> Summary) {
        self.value = value
        self.parameterSummary = parameterSummary()
    }
}

public struct ParameterSummaryDefaultCaseCondition<Intent: AppIntent, Value: _IntentValue, Summary: ParameterSummary>: _ParameterSummarySwitchCase {
    private let parameterSummary: Summary

    public init(@ParameterSummaryBuilder<Intent> _ parameterSummary: () -> Summary) {
        self.parameterSummary = parameterSummary()
    }
}

public struct ParameterSummaryTupleCaseCondition<Intent: AppIntent, Value: _IntentValue, ValueType>: _ParameterSummarySwitchCase {
    public typealias Summary = Never
    let value: ValueType
}

@resultBuilder
public enum ParameterSummaryCaseBuilder<Intent: AppIntent, Value: _IntentValue> {
    public static func buildExpression<Condition>(_ expression: Condition) -> Condition
    where Condition: _ParameterSummarySwitchCase, Condition.Intent == Intent, Condition.Value == Value {
        expression
    }

    public static func buildBlock<Condition, DefaultSummary>(
        _ condition: Condition,
        _ defaultCase: ParameterSummaryDefaultCaseCondition<Intent, Value, DefaultSummary>
    ) -> ParameterSummaryTupleCaseCondition<Intent, Value, (Condition, ParameterSummaryDefaultCaseCondition<Intent, Value, DefaultSummary>)>
    where Intent == Condition.Intent, Condition: _ParameterSummarySwitchCase,
          DefaultSummary: ParameterSummary {
        ParameterSummaryTupleCaseCondition(value: (condition, defaultCase))
    }

    public static func buildBlock<First, Second, DefaultSummary>(
        _ first: First,
        _ second: Second,
        _ defaultCase: ParameterSummaryDefaultCaseCondition<Intent, Value, DefaultSummary>
    ) -> ParameterSummaryTupleCaseCondition<Intent, Value, (First, Second, ParameterSummaryDefaultCaseCondition<Intent, Value, DefaultSummary>)>
    where Intent == First.Intent, First: _ParameterSummarySwitchCase,
          Second: _ParameterSummarySwitchCase, DefaultSummary: ParameterSummary,
          First.Intent == Second.Intent {
        ParameterSummaryTupleCaseCondition(value: (first, second, defaultCase))
    }

    public static func buildBlock<First, Second, Third, DefaultSummary>(
        _ first: First,
        _ second: Second,
        _ third: Third,
        _ defaultCase: ParameterSummaryDefaultCaseCondition<Intent, Value, DefaultSummary>
    ) -> ParameterSummaryTupleCaseCondition<Intent, Value, (First, Second, Third, ParameterSummaryDefaultCaseCondition<Intent, Value, DefaultSummary>)>
    where Intent == First.Intent, First: _ParameterSummarySwitchCase,
          Second: _ParameterSummarySwitchCase, Third: _ParameterSummarySwitchCase,
          DefaultSummary: ParameterSummary, First.Intent == Second.Intent,
          Second.Intent == Third.Intent {
        ParameterSummaryTupleCaseCondition(value: (first, second, third, defaultCase))
    }
}

public struct ParameterSummarySwitchCondition<Intent: AppIntent, Value: _IntentValue, CaseCondition: _ParameterSummarySwitchCase>: ParameterSummary {
    private let parameterKeyPath: KeyPath<Intent, IntentParameter<Value>>?
    private let cases: CaseCondition

    public init(_ keyPath: KeyPath<Intent, IntentParameter<Value>>,
                @ParameterSummaryCaseBuilder<Intent, Value> _ builder: () -> CaseCondition) {
        parameterKeyPath = keyPath
        cases = builder()
    }
}

public enum HasValueComparisonOperator: Hashable {
    case hasNoValue
    case hasAnyValue
}

public enum EquatableComparisonOperator: Hashable {
    case notEqualTo
    case equalTo
}

public struct ParameterSummaryWhenCondition<Intent: AppIntent, WhenCondition: ParameterSummary, Otherwise: ParameterSummary>: ParameterSummary {
    private let comparedKeyPath: AnyKeyPath
    private let comparisonOperator: Any
    private let comparedValue: Any?
    private let whenCondition: WhenCondition
    private let otherwiseCondition: Otherwise

    public init<Parameter>(_ keyPath: KeyPath<Intent, Parameter>, _ comparisonOperator: HasValueComparisonOperator,
                          @ParameterSummaryBuilder<Intent> _ when: () -> WhenCondition,
                          @ParameterSummaryBuilder<Intent> otherwise: () -> Otherwise)
    where Parameter: AnyIntentValue {
        comparedKeyPath = keyPath
        self.comparisonOperator = comparisonOperator
        comparedValue = nil
        whenCondition = when()
        otherwiseCondition = otherwise()
    }

    public init<ValueType, Parameter>(_ keyPath: KeyPath<Intent, Parameter>, _ comparisonOperator: EquatableComparisonOperator,
                                      _ value: ValueType,
                                      @ParameterSummaryBuilder<Intent> _ when: () -> WhenCondition,
                                      @ParameterSummaryBuilder<Intent> otherwise: () -> Otherwise)
    where ValueType: Equatable, ValueType == Parameter.Value, Parameter: AnyIntentValue,
          WhenCondition.Intent == Otherwise.Intent {
        comparedKeyPath = keyPath
        self.comparisonOperator = comparisonOperator
        comparedValue = value
        whenCondition = when()
        otherwiseCondition = otherwise()
    }
}

extension ParameterSummaryWhenCondition: CustomReflectable {
    public var customMirror: Mirror {
        Mirror(self, children: [:], displayStyle: .struct)
    }
}

extension AppIntent {
    public typealias Parameter = IntentParameter
    public typealias When = ParameterSummaryWhenCondition
    public typealias Switch<Value, CaseCondition> = ParameterSummarySwitchCondition<Self, Value, CaseCondition>
    where Value: _IntentValue, CaseCondition: _ParameterSummarySwitchCase
    public typealias Case = ParameterSummaryCaseCondition
    public typealias DefaultCase = ParameterSummaryDefaultCaseCondition
    public typealias Summary = IntentParameterSummary<Self>
}

/// The summary of an intent that gives none: its title.
public struct _FinchParameterSummary<Intent>: ParameterSummary where Intent: AppIntent {}

public protocol AppIntent: PersistentlyIdentifiable, _SupportsAppDependencies, Sendable {
    associatedtype PerformResult: IntentResult
    static var title: LocalizedStringResource { get }
    static var openAppWhenRun: Bool { get }
    static var supportedModes: IntentModes { get }
    static var authenticationPolicy: IntentAuthenticationPolicy { get }
    static var isDiscoverable: Bool { get }
    associatedtype SummaryContent: ParameterSummary
    static var parameterSummary: SummaryContent { get }
    static var description: IntentDescription? { get }
    func perform() async throws -> PerformResult
    init()
}

extension AppIntent {
    public static var persistentIdentifier: String { String(describing: Self.self) }
    public static var openAppWhenRun: Bool { false }
    public static var supportedModes: IntentModes { openAppWhenRun ? .foreground : .background }
    public static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }
    public static var isDiscoverable: Bool { true }
    public static var description: IntentDescription? { nil }
    public static var parameterSummary: some ParameterSummary { _FinchParameterSummary<Self>() }
    public var systemContext: IntentSystemContext { IntentSystemContext() }
}

public struct IntentSystemContext: Sendable {
    public enum Source: Equatable, Sendable {
        case shortcuts
        case actionButton
    }

    public enum Kind: Equatable, Sendable {
        case userShortcut
    }

    public var preciseTimestamp: Date? { nil }
    public var source: Source? { nil }
    public var kind: Kind? { nil }
}

public enum ShortcutTileColor: Int, CaseIterable, Hashable, Sendable {
    case red, orange, yellow, green, blue, purple, pink, gray, grayBlue, grayGreen, grayBrown
}

public enum AppShortcutPhraseToken: Hashable {
    case applicationName
}

public struct AppShortcutPhrase<Intent: AppIntent>: ExpressibleByStringInterpolation {
    private var keyPaths: [PartialKeyPath<Intent>]
    private var formatString: String

    public init(_ value: String) {
        keyPaths = []
        formatString = value
    }

    public init(stringLiteral value: String) { self.init(value) }

    public struct StringInterpolation: StringInterpolationProtocol {
        fileprivate var formatString: String
        fileprivate var keyPaths: [PartialKeyPath<Intent>] = []

        public init(literalCapacity: Int, interpolationCount: Int) {
            formatString = ""
            formatString.reserveCapacity(literalCapacity + interpolationCount * 8)
            keyPaths.reserveCapacity(interpolationCount)
        }

        public mutating func appendLiteral(_ literal: String) { formatString.append(literal) }

        public mutating func appendInterpolation(_ token: AppShortcutPhraseToken) {
            switch token {
            case .applicationName: formatString.append("${applicationName}")
            }
        }

        public mutating func appendInterpolation<Value, Subject>(_ subject: Subject)
        where Value: _IntentValue, Value: Sendable, Subject: KeyPath<Intent, IntentParameter<Value>> {
            let index = keyPaths.count
            keyPaths.append(subject)
            formatString.append("${parameter\(index)}")
        }
    }

    public init(stringInterpolation: StringInterpolation) {
        keyPaths = stringInterpolation.keyPaths
        formatString = stringInterpolation.formatString
    }

    fileprivate var value: String { formatString }
}

public struct AppShortcut {
    public let intent: any AppIntent
    public let phrases: [String]
    public let shortTitle: LocalizedStringResource?
    public let systemImageName: String?

    public init<Intent>(intent: Intent, phrases: [AppShortcutPhrase<Intent>],
                        shortTitle: LocalizedStringResource? = nil, systemImageName: _const String? = nil)
    where Intent: AppIntent {
        self.intent = intent
        self.phrases = phrases.map(\.value)
        self.shortTitle = shortTitle
        self.systemImageName = systemImageName
    }

    public init<Intent>(intent: Intent, phrases: [AppShortcutPhrase<Intent>],
                        shortTitle: LocalizedStringResource, systemImageName: _const String)
    where Intent: AppIntent {
        self.intent = intent
        self.phrases = phrases.map(\.value)
        self.shortTitle = shortTitle
        self.systemImageName = systemImageName
    }
}

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
public protocol AppShortcutOptionsCollectionProtocol {
    associatedtype Provider: DynamicOptionsProvider
    var dynamicOptionsProvider: Provider { get }
    var title: LocalizedStringResource { get }
    var systemImageName: String? { get }
}

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
public struct AppShortcutOptionsCollection<Provider: DynamicOptionsProvider>: AppShortcutOptionsCollectionProtocol {
    public let dynamicOptionsProvider: Provider
    public let title: LocalizedStringResource
    public let systemImageName: String?

    public init(_ dynamicOptionsProvider: Provider, title: LocalizedStringResource, systemImageName: String? = nil) {
        self.dynamicOptionsProvider = dynamicOptionsProvider
        self.title = title
        self.systemImageName = systemImageName
    }
}

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
extension AppShortcutsProvider {
    public typealias OptionsCollection = AppShortcutOptionsCollection
}

@resultBuilder
public enum AppShortcutsBuilder {
    @_disfavoredOverload
    public static func buildExpression(_ component: AppShortcut) -> AppShortcut { component }

    @_disfavoredOverload
    public static func buildBlock(_ components: AppShortcut...) -> [AppShortcut] { components }

    @_disfavoredOverload
    public static func buildExpression(_ component: AppShortcut) -> [AppShortcut] { [component] }

    public static func buildExpression(_ component: [AppShortcut]) -> [AppShortcut] { component }
    public static func buildBlock(_ components: [AppShortcut]...) -> [AppShortcut] { components.flatMap { $0 } }
    public static func buildBlock() -> [AppShortcut] { [] }
}

public protocol AppShortcutsProvider: Sendable {
    @AppShortcutsBuilder static var appShortcuts: [AppShortcut] { get }
    static var shortcutTileColor: ShortcutTileColor { get }
}

extension AppShortcutsProvider {
    public static var shortcutTileColor: ShortcutTileColor { .grayBrown }

    /// Finch has no shortcut index service; this marks the request unavailable for the
    /// process instead of claiming that the system's shortcut list was refreshed.
    public static func updateAppShortcutParameters() {
        AppIntentsSystemServices.recordUnavailable("Shortcuts")
    }
}

/// A local description of an assistant intent. It keeps the intent and its phrases
/// together so an app can inspect the declaration even when no assistant service runs.
public struct _AssistantIntent {
    public struct Value {
        fileprivate let keyPath: AnyKeyPath
        fileprivate let values: [String]

        public init<Intent: AppIntent>(for keyPath: PartialKeyPath<Intent>,
                                       @StringValueBuilder builder: () -> [String]) {
            self.keyPath = keyPath
            values = builder()
        }

        public init<Intent: AppIntent, Enum: AppEnum>(_ value: Enum,
                                                       for keyPath: KeyPath<Intent, Enum>) {
            self.keyPath = keyPath
            values = [value.rawValue.description]
        }
    }

    public enum PhraseToken: Hashable, Sendable {
        case applicationName
    }

    public struct Phrase<Intent: AppIntent>: ExpressibleByStringInterpolation {
        fileprivate let keyPaths: [PartialKeyPath<Intent>]
        fileprivate let formatString: String

        public init(_ value: String) {
            keyPaths = []
            formatString = value
        }

        public init(stringLiteral value: String) {
            keyPaths = []
            formatString = value
        }

        public init(stringInterpolation: StringInterpolation) {
            keyPaths = stringInterpolation.keyPaths
            formatString = stringInterpolation.formatString
        }

        public struct StringInterpolation: StringInterpolationProtocol {
            fileprivate var keyPaths: [PartialKeyPath<Intent>] = []
            fileprivate var formatString = ""

            public init(literalCapacity: Int, interpolationCount: Int) {
                keyPaths.reserveCapacity(interpolationCount)
                formatString.reserveCapacity(literalCapacity + interpolationCount * 8)
            }

            public mutating func appendLiteral(_ literal: String) {
                formatString.append(literal)
            }

            public mutating func appendInterpolation(_ token: PhraseToken) {
                switch token {
                case .applicationName:
                    formatString.append("%applicationName")
                }
            }

            public mutating func appendInterpolation(_ keyPath: PartialKeyPath<Intent>) {
                keyPaths.append(keyPath)
                formatString.append("%parameter")
                formatString.append(String(keyPaths.count - 1))
            }
        }
    }

    @dynamicMemberLookup
    public final class IntentProjection<Intent> {
        public init() {}

        @_disfavoredOverload
        public subscript<Value: _IntentValue>(dynamicMember keyPath: KeyPath<Intent, Value>) -> KeyPath<Intent, Value> {
            keyPath
        }

        public subscript<Value: _IntentValue>(
            dynamicMember keyPath: KeyPath<Intent, Value>
        ) -> PartialKeyPath<Intent> {
            keyPath
        }

        public subscript<Value: _IntentValue>(
            dynamicMember keyPath: KeyPath<Intent, IntentParameter<Value>>
        ) -> PartialKeyPath<Intent> {
            keyPath
        }
    }

    public struct NegativeAssistantIntentPhrases {
        fileprivate let phrases: [String]

        public init<Intent: AppIntent>(for intent: Intent.Type,
                                       @StringValueBuilder phrases: () -> [String]) {
            _ = intent
            self.phrases = phrases()
        }
    }

    public let intent: any AppIntent
    fileprivate let phrases: [Any]
    fileprivate let parameterValues: [Value]
    fileprivate let implyingValues: [Value]

    public init<Intent: AppIntent>(
        _ intent: Intent,
        @PhraseBuilder<Intent> phrases: (IntentProjection<Intent>) -> [Phrase<Intent>],
        @ParameterValueBuilder parameterValues: (IntentProjection<Intent>) -> [Value]
    ) {
        let projection = IntentProjection<Intent>()
        self.intent = intent
        self.phrases = phrases(projection)
        self.parameterValues = parameterValues(projection)
        implyingValues = []
    }

    public init<Intent: AppIntent>(
        _ intent: Intent,
        @PhraseBuilder<Intent> phrases: (IntentProjection<Intent>) -> [Phrase<Intent>],
        @ParameterValueBuilder parameterValues: (IntentProjection<Intent>) -> [Value],
        @ParameterValueBuilder implying: (IntentProjection<Intent>) -> [Value]
    ) {
        let projection = IntentProjection<Intent>()
        self.intent = intent
        self.phrases = phrases(projection)
        self.parameterValues = parameterValues(projection)
        implyingValues = implying(projection)
    }

    public init<Intent: AppIntent>(
        _ intent: Intent,
        @PhraseBuilder<Intent> phrases: (IntentProjection<Intent>) -> [Phrase<Intent>],
        @ParameterValueBuilder implying: (IntentProjection<Intent>) -> [Value]
    ) {
        let projection = IntentProjection<Intent>()
        self.intent = intent
        self.phrases = phrases(projection)
        parameterValues = []
        implyingValues = implying(projection)
    }

    @resultBuilder
    public enum Builder {
        public static func buildExpression(_ component: _AssistantIntent) -> [_AssistantIntent] {
            [component]
        }

        public static func buildBlock(_ components: [_AssistantIntent]...) -> [_AssistantIntent] {
            components.flatMap { $0 }
        }

        public static func buildBlock() -> [_AssistantIntent] { [] }
    }

    @resultBuilder
    public enum PhraseBuilder<Intent: AppIntent> {
        public static func buildExpression(_ component: Phrase<Intent>) -> [Phrase<Intent>] {
            [component]
        }

        public static func buildBlock(_ components: [Phrase<Intent>]...) -> [Phrase<Intent>] {
            components.flatMap { $0 }
        }

        public static func buildBlock() -> [Phrase<Intent>] { [] }
    }

    @resultBuilder
    public enum ParameterValueBuilder {
        public static func buildExpression(_ component: Value) -> [Value] { [component] }
        public static func buildBlock(_ components: [Value]...) -> [Value] { components.flatMap { $0 } }
        public static func buildBlock() -> [Value] { [] }
    }

    @resultBuilder
    public enum StringValueBuilder {
        public static func buildExpression(_ component: String) -> [String] { [component] }
        public static func buildBlock(_ components: [String]...) -> [String] { components.flatMap { $0 } }
        public static func buildBlock() -> [String] { [] }
    }

    @resultBuilder
    public enum NegativeAssistantIntentPhrasesBuilder {
        public static func buildExpression(_ component: NegativeAssistantIntentPhrases) -> [NegativeAssistantIntentPhrases] {
            [component]
        }

        public static func buildBlock(_ components: [NegativeAssistantIntentPhrases]...) -> [NegativeAssistantIntentPhrases] {
            components.flatMap { $0 }
        }

        public static func buildBlock() -> [NegativeAssistantIntentPhrases] { [] }
    }
}

public struct _AssistantUniqueEntityExample: Sendable {
    public init() {}
}

public protocol _AssistantIntentsProvider {
    @_AssistantIntent.Builder static var intents: [_AssistantIntent] { get }
    @_AssistantIntent.NegativeAssistantIntentPhrasesBuilder static var negativePhrases: [_AssistantIntent.NegativeAssistantIntentPhrases] { get }
    static var uniqueEntities: [_AssistantUniqueEntityExample] { get }
}

extension _AssistantIntentsProvider {
    public static var uniqueEntities: [_AssistantUniqueEntityExample] { [] }
}

public enum AppIntentsSystemServices {
    private static let lock = NSLock()
    private static var unavailableRequests: [String] = []

    public static var isAvailable: Bool { false }

    public static var lastUnavailableRequest: String? {
        lock.lock()
        defer { lock.unlock() }
        return unavailableRequests.last
    }

    fileprivate static func recordUnavailable(_ service: String) {
        lock.lock()
        unavailableRequests.append(service)
        lock.unlock()
    }
}

private func unavailableOpenIntent() throws -> IntentResultContainer<Never, Never, Never, Never> {
    AppIntentsSystemServices.recordUnavailable("OpenIntent")
    throw AppIntentError(customDescription: "Opening the target requires the unavailable system service.")
}

public protocol SystemIntent: AppIntent {}

public protocol PreparableIntent: AppIntent {
    func prepare() async throws
}

extension PreparableIntent {
    public func prepare() async throws {}
}

public protocol SearchIntent: SystemIntent {
    var searchPhrase: String { get set }
}

public protocol CreateIntent: SystemIntent {
    associatedtype Entity: AppEntity
    var name: String? { get set }
}

public protocol _CreateIntent: SystemIntent where PerformResult.Value: AppEntity {
    associatedtype Entity: AppEntity
}

public enum ChangeOperation: String, AppEnum, CaseIterable {
    case enable
    case disable
    case toggle

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Change operation" }
    public static var caseDisplayRepresentations: [ChangeOperation: DisplayRepresentation] {
        [.enable: "Enable", .disable: "Disable", .toggle: "Toggle"]
    }
}

public protocol ChangeBinarySettingIntent: SystemIntent {
    associatedtype Setting: AppEnum
    var setting: Setting { get set }
    var changeOperation: ChangeOperation { get set }
}

public protocol CloseIntent: SystemIntent {
    associatedtype Value: AppValue
    var target: Value { get set }
}

public enum FavoriteOperation: String, AppEnum, CaseIterable {
    case add
    case remove

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Favorite operation" }
    public static var caseDisplayRepresentations: [FavoriteOperation: DisplayRepresentation] {
        [.add: "Add", .remove: "Remove"]
    }
}

public protocol FavoriteIntent: SystemIntent {
    associatedtype Entity: AppEntity
    var entities: [Entity] { get }
    var operation: FavoriteOperation { get }
}

public protocol PutInContainerIntent: SystemIntent {
    associatedtype Entity: AppEntity
    associatedtype Container: AppValue
    var entities: [Entity] { get set }
    var container: Container { get set }
}

public protocol SetValueIntent: AppIntent {
    associatedtype ValueType: _IntentValue
    var value: ValueType { get set }
}

public enum ResizeBehavior: Hashable, Sendable {
    case larger(Double?)
    case smaller(Double?)
}

public protocol ResizeIntent: SystemIntent {
    var behavior: ResizeBehavior { get set }
}

public enum NavigateSequentiallyDirection: String, AppEnum, CaseIterable {
    case next
    case previous

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Direction" }
    public static var caseDisplayRepresentations: [NavigateSequentiallyDirection: DisplayRepresentation] {
        [.next: "Next", .previous: "Previous"]
    }
}

public protocol NavigateSequentiallyIntent: SystemIntent {
    var direction: NavigateSequentiallyDirection { get set }
}

public enum MailMessageAttribute: String, AppEnum, CaseIterable {
    case flagged
    case junk
    case ready

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Mail message attribute" }
    public static var caseDisplayRepresentations: [MailMessageAttribute: DisplayRepresentation] {
        [.flagged: "Flagged", .junk: "Junk", .ready: "Ready"]
    }
}

public protocol MailAddressee: AppEntity {
    init(displayName: String?, emailAddress: String)
    var displayName: String? { get set }
    var emailAddress: String { get set }
}

extension MailAddressee {
    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName ?? emailAddress)")
    }
}

public protocol MailAccount: AppEntity {
    var displayName: String? { get set }
    var emailAddress: String { get set }
}

extension MailAccount {
    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName ?? emailAddress)")
    }
}

public protocol Mailbox: AppEntity {
    associatedtype Account: MailAccount
    var name: String { get set }
    var account: Account? { get set }
}

extension Mailbox {
    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

public protocol MailMessage: AppEntity {
    associatedtype Addressee: MailAddressee
    associatedtype Account: MailAccount
    associatedtype Mailbox: AppIntents.Mailbox
    var attributes: [MailMessageAttribute] { get set }
    var dateReceived: Date { get set }
    var dateSent: Date { get set }
    var to: [Addressee] { get set }
    var cc: [Addressee] { get set }
    var bcc: [Addressee] { get set }
    var body: AttributedString? { get set }
    var isJunk: Bool { get set }
    var isRead: Bool { get set }
    var sender: Addressee { get set }
    var account: Account? { get set }
    var mailbox: Mailbox? { get set }
    var replyTo: [Addressee] { get set }
    var subject: String? { get set }
}

public protocol SendMailIntent: PreparableIntent {
    associatedtype Addressee: MailAddressee
    associatedtype Account: MailAccount
    associatedtype ReplyMessage: MailMessage
    var attachments: [IntentFile] { get set }
    var cc: [Addressee] { get set }
    var to: [Addressee] { get set }
    var bcc: [Addressee] { get set }
    var body: AttributedString? { get set }
    var account: Account? { get set }
    var subject: String? { get set }
    var inReplyTo: ReplyMessage? { get set }
}

public protocol SetMailMessageIsReadIntent: PreparableIntent {
    associatedtype Message: MailMessage
    var read: Bool { get set }
    var message: Message { get set }
}

public protocol AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { get }
}

extension AppIntentsPackage {
    public static var includedPackages: [any AppIntentsPackage.Type] { [] }
}

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
public protocol AudioPlaybackIntent: SystemIntent {}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public protocol DeleteIntent: SystemIntent {
    associatedtype Entity: AppEntity
    var entities: [Entity] { get }
}

public protocol OpenIntent: SystemIntent {
    associatedtype Value: AppValue
    var target: Value { get set }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public protocol AssistantIntent: AppIntent {}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public protocol AssistantEntity: AppEntity {}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public protocol AssistantEnum: AppEnum {}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public protocol AssistantSchemaIntent: AssistantIntent {
    static var isAssistantOnly: Bool { get }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension AssistantSchemaIntent {
    public static var isAssistantOnly: Bool { false }
    public static var title: LocalizedStringResource { "" }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public protocol AssistantSchemaEntity: AssistantEntity {
    static var isAssistantOnly: Bool { get }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension AssistantSchemaEntity {
    public static var isAssistantOnly: Bool { false }
    public static var typeDisplayRepresentation: TypeDisplayRepresentation { TypeDisplayRepresentation(name: "") }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public protocol AssistantSchemaEnum: AssistantEnum {
    static var isAssistantOnly: Bool { get }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension AssistantSchemaEnum {
    public static var isAssistantOnly: Bool { false }
    public static var typeDisplayRepresentation: TypeDisplayRepresentation { TypeDisplayRepresentation(name: "") }
}

extension OpenIntent {
    public static var openAppWhenRun: Bool {
        !(Self.self is any URLRepresentableIntent.Type
          && Self.Value.self is any URLRepresentableEntity.Type)
    }

    public func perform() async throws -> some IntentResult {
        return try unavailableOpenIntent()
    }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public protocol CustomURLRepresentationParameterConvertible {
    var urlRepresentationParameter: String? { get async }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension String: CustomURLRepresentationParameterConvertible {
    public var urlRepresentationParameter: String? { self }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension Int: CustomURLRepresentationParameterConvertible {
    public var urlRepresentationParameter: String? { String(self) }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension URL: CustomURLRepresentationParameterConvertible {
    public var urlRepresentationParameter: String? { absoluteString }
}

private enum _URLTemplateSegment<Value> {
    case literal(String)
    case value((Value) async -> String?)
}

private func _urlParameterComponent(_ value: String) -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

private func _resolveURLTemplate<Value>(
    _ segments: [_URLTemplateSegment<Value>],
    for value: Value
) async -> URL? {
    var string = ""
    for segment in segments {
        switch segment {
        case .literal(let literal):
            string.append(literal)
        case .value(let getValue):
            guard let component = await getValue(value) else { return nil }
            string.append(_urlParameterComponent(component))
        }
    }
    return URL(string: string)
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public struct EntityURLRepresentation<Entity>: ExpressibleByStringInterpolation where Entity: AppEntity {
    fileprivate let segments: [_URLTemplateSegment<Entity>]

    public init(_ value: String) {
        segments = [.literal(value)]
    }

    public init(stringLiteral value: String) {
        segments = [.literal(value)]
    }

    public init(stringInterpolation: StringInterpolation) {
        segments = stringInterpolation.segments
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        fileprivate var segments: [_URLTemplateSegment<Entity>] = []

        public init(literalCapacity: Int, interpolationCount: Int) {
            segments.reserveCapacity(interpolationCount * 2 + 1)
        }

        public mutating func appendLiteral(_ literal: String) {
            segments.append(.literal(literal))
        }

        public mutating func appendInterpolation<ValueType, Subject>(_ subject: Subject)
        where ValueType: _IntentValue, ValueType: Sendable,
              Subject: KeyPath<Entity, EntityProperty<ValueType>> {
            let keyPath = subject as KeyPath<Entity, EntityProperty<ValueType>>
            segments.append(.value { entity in
                guard let value = entity[keyPath: keyPath].urlRepresentationValue,
                      let convertible = value as? any CustomURLRepresentationParameterConvertible else {
                    return nil
                }
                return await convertible.urlRepresentationParameter
            })
        }

        public mutating func appendInterpolation(_ token: Token) {
            switch token {
            case .id:
                segments.append(.value { $0.id.entityIdentifierString })
            }
        }

        public enum Token: Equatable {
            case id
        }

        public typealias StringLiteralType = String
    }

    fileprivate func url(for entity: Entity) async -> URL? {
        await _resolveURLTemplate(segments, for: entity)
    }

    public typealias ExtendedGraphemeClusterLiteralType = String
    public typealias StringLiteralType = String
    public typealias UnicodeScalarLiteralType = String
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public protocol URLRepresentableEntity: AppEntity, CustomURLRepresentationParameterConvertible {
    static var urlRepresentation: Self.URLRepresentation { get }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension URLRepresentableEntity {
    public typealias URLRepresentation = EntityURLRepresentation<Self>

    public var urlRepresentation: URL? {
        get async { await Self.urlRepresentation.url(for: self) }
    }

    public var urlRepresentationParameter: String? { id.entityIdentifierString }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public struct IntentURLRepresentation<Intent>: ExpressibleByStringInterpolation where Intent: AppIntent {
    fileprivate let segments: [_URLTemplateSegment<Intent>]

    public init(_ value: String) {
        segments = [.literal(value)]
    }

    public init(stringLiteral value: String) {
        segments = [.literal(value)]
    }

    public init(stringInterpolation: StringInterpolation) {
        segments = stringInterpolation.segments
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        fileprivate var segments: [_URLTemplateSegment<Intent>] = []

        public init(literalCapacity: Int, interpolationCount: Int) {
            segments.reserveCapacity(interpolationCount * 2 + 1)
        }

        public mutating func appendLiteral(_ literal: String) {
            segments.append(.literal(literal))
        }

        public mutating func appendInterpolation<ValueType, Subject>(_ subject: Subject)
        where ValueType: _IntentValue, ValueType: Sendable,
              Subject: KeyPath<Intent, IntentParameter<ValueType>> {
            let keyPath = subject as KeyPath<Intent, IntentParameter<ValueType>>
            segments.append(.value { intent in
                guard let value = intent[keyPath: keyPath].urlRepresentationValue,
                      let convertible = value as? any CustomURLRepresentationParameterConvertible else {
                    return nil
                }
                return await convertible.urlRepresentationParameter
            })
        }

        public typealias StringLiteralType = String
    }

    fileprivate func url(for intent: Intent) async -> URL? {
        await _resolveURLTemplate(segments, for: intent)
    }

    public typealias ExtendedGraphemeClusterLiteralType = String
    public typealias StringLiteralType = String
    public typealias UnicodeScalarLiteralType = String
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public protocol URLRepresentableIntent: AppIntent {
    static var urlRepresentation: Self.URLRepresentation { get }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension URLRepresentableIntent {
    public typealias URLRepresentation = IntentURLRepresentation<Self>

    public var urlRepresentation: URL? {
        get async { await Self.urlRepresentation.url(for: self) }
    }

    public func perform() async throws -> Never {
        AppIntentsSystemServices.recordUnavailable("Universal links")
        throw AppIntentError(customDescription: "Opening a URL requires the unavailable system service.")
    }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension URLRepresentableIntent where Self: OpenIntent, Self.Value: URLRepresentableEntity {
    public static var urlRepresentation: Self.URLRepresentation {
        Self.URLRepresentation("")
    }

    public func perform() async throws -> Never {
        AppIntentsSystemServices.recordUnavailable("Universal links")
        throw AppIntentError(customDescription: "Opening a URL requires the unavailable system service.")
    }
}

@available(macOS 14.2, iOS 17.2, watchOS 10.2, tvOS 17.2, *)
public protocol SearchCriteria: _IntentValue, Hashable, Sendable {
    associatedtype SearchScopes = Void
}

@available(macOS 14.2, iOS 17.2, watchOS 10.2, tvOS 17.2, *)
public enum StringSearchScope: String, AppEnum {
    case general
    case movies
    case tv
    case freeformVideo

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Search Scope" }
    public static var caseDisplayRepresentations: [StringSearchScope: DisplayRepresentation] = [
        .general: "General",
        .movies: "Movies",
        .tv: "TV",
        .freeformVideo: "Freeform Video"
    ]
    public static var allCases: [StringSearchScope] { [.general, .movies, .tv, .freeformVideo] }
}

@available(macOS 14.2, iOS 17.2, watchOS 10.2, tvOS 17.2, *)
public struct StringSearchCriteria: SearchCriteria {
    public typealias SearchScopes = [StringSearchScope]
    public typealias Specification = EmptyResolverSpecification<StringSearchCriteria>

    public var term: String

    public init(term: String) { self.term = term }

    public static var defaultResolverSpecification: Specification { Specification() }
}

@available(macOS 14.2, iOS 17.2, watchOS 10.2, tvOS 17.2, *)
public protocol ShowInAppSearchResultsIntent: SystemIntent {
    associatedtype Criteria: SearchCriteria
    static var searchScopes: Criteria.SearchScopes { get }
    var criteria: Criteria { get set }
}

@available(macOS 14.2, iOS 17.2, watchOS 10.2, tvOS 17.2, *)
extension ShowInAppSearchResultsIntent {
    public static var openAppWhenRun: Bool { true }
}

@available(macOS 14.2, iOS 17.2, tvOS 17.2, *)
extension ShowInAppSearchResultsIntent where Criteria.SearchScopes == () {
    public static var searchScopes: Void { () }
}

@available(macOS 14.2, iOS 17.2, watchOS 10.2, tvOS 17.2, visionOS 1.1, *)
extension ShowInAppSearchResultsIntent where Criteria == StringSearchCriteria {
    public static var searchScopes: [StringSearchScope] { [.general] }
}

extension Never: AppIntent {
    public typealias PerformResult = Never

    public static var title: LocalizedStringResource { "" }
    public func perform() async throws -> Never { switch self {} }
    public init() { fatalError("Never has no value") }
}
