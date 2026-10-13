// SPDX-License-Identifier: MIT OR Apache-2.0
//
// AppIntents, to Apple's interface: the protocols an app's intents, enums and values conform
// to (with Apple's requirements and their defaults, which an app's conformances rely on), how
// they're shown (display representations), intent parameters, dialogs and results. Finch has
// no Shortcuts or Siri to run intents yet: an app declares them and they wait.

import Foundation

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

public struct DisplayRepresentation: ExpressibleByStringLiteral, Equatable {
    public var title: LocalizedStringResource
    public var subtitle: LocalizedStringResource?
    public var image: Image?
    public var synonyms: [LocalizedStringResource] = []

    public struct Image: Equatable {
        enum Source: Equatable { case systemName(String), named(String), url(URL), data(Data) }
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

public protocol CaseDisplayRepresentable: CustomLocalizedStringResourceConvertible, CaseIterable, Hashable {
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] { get }
}

extension CaseDisplayRepresentable {
    public var localizedStringResource: LocalizedStringResource {
        Self.caseDisplayRepresentations[self]?.title ?? LocalizedStringResource(stringLiteral: String(describing: self))
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
public struct _FinchEmptyResolverSpecification<Output>: ResolverSpecification where Output: _IntentValue {
    public typealias Element = any Resolver

    public func makeIterator() -> IndexingIterator<[any Resolver]> {
        [any Resolver]().makeIterator()
    }

    public static func == (a: Self, b: Self) -> Bool { true }
    public func hash(into hasher: inout Hasher) {}
}

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
        _FinchEmptyResolverSpecification<Self>()
    }
}

extension Optional: _IntentValue where Wrapped: _IntentValue {
    public typealias ValueType = Wrapped.ValueType
    public typealias UnwrappedType = Wrapped
    public static var defaultResolverSpecification: _FinchEmptyResolverSpecification<Optional<Wrapped>> {
        _FinchEmptyResolverSpecification()
    }
}

extension String: _IntentValue {
    public static var defaultResolverSpecification: _FinchEmptyResolverSpecification<String> { _FinchEmptyResolverSpecification() }
}

extension Int: _IntentValue {
    public static var defaultResolverSpecification: _FinchEmptyResolverSpecification<Int> { _FinchEmptyResolverSpecification() }
}

extension Double: _IntentValue {
    public static var defaultResolverSpecification: _FinchEmptyResolverSpecification<Double> { _FinchEmptyResolverSpecification() }
}

extension Bool: _IntentValue {
    public static var defaultResolverSpecification: _FinchEmptyResolverSpecification<Bool> { _FinchEmptyResolverSpecification() }
}

extension Date: _IntentValue {
    public static var defaultResolverSpecification: _FinchEmptyResolverSpecification<Date> { _FinchEmptyResolverSpecification() }
}

extension URL: _IntentValue {
    public static var defaultResolverSpecification: _FinchEmptyResolverSpecification<URL> { _FinchEmptyResolverSpecification() }
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

    public enum ForegroundMode: Sendable {
        case immediate, dynamic, deferred
    }

    public static func foreground(_ foregroundMode: ForegroundMode) -> IntentModes {
        switch foregroundMode {
        case .immediate: IntentModes(rawValue: 1 << 1)
        case .dynamic: IntentModes(rawValue: 1 << 2)
        case .deferred: IntentModes(rawValue: 1 << 3)
        }
    }

    public static var background: IntentModes { IntentModes(rawValue: 1) }
    public static var foreground: IntentModes { .foreground(.immediate) }
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

@propertyWrapper
public final class IntentParameter<Value>: @unchecked Sendable where Value: _IntentValue, Value: Sendable {
    public final let defaultValue: Value.UnwrappedType?
    public final let title: LocalizedStringResource
    let parameterDescription: LocalizedStringResource?
    private var value: Value?

    public enum ValueState {
        case unset
        case set(Value)
    }

    public init() {
        defaultValue = nil
        title = ""
        parameterDescription = nil
    }

    init(title: LocalizedStringResource, description: LocalizedStringResource?, defaultValue: Value.UnwrappedType?) {
        self.title = title
        parameterDescription = description
        self.defaultValue = defaultValue
    }

    public final var isOptional: Bool { Value.self != Value.UnwrappedType.self }

    public final var projectedValue: IntentParameter<Value> { self }

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
        self.init(title: title, description: description, defaultValue: defaultValue)
    }

    public convenience init(description: LocalizedStringResource? = nil, default defaultValue: _const Value.UnwrappedType? = nil,
                            requestValueDialog: IntentDialog? = nil, requestDisambiguationDialog: IntentDialog? = nil,
                            inputConnectionBehavior: _const InputConnectionBehavior = .default,
                            supportedValues: [Value.ValueType] = Array(Value.ValueType.allCases)) {
        self.init(title: "", description: description, defaultValue: defaultValue)
    }
}

extension IntentParameter {
    public convenience init(title: LocalizedStringResource, description: LocalizedStringResource? = nil,
                            requestValueDialog: IntentDialog? = nil, inputConnectionBehavior: _const InputConnectionBehavior = .default) {
        self.init(title: title, description: description, defaultValue: nil)
    }
}

// MARK: - Intents and results

public protocol IntentResult: Sendable {
    associatedtype Value: _IntentValue
    var value: Value? { get }
}

/// A result with nothing in it.
public struct _FinchIntentResult: IntentResult {
    public var value: String? { nil }
}

extension IntentResult {
    public static func result() -> some IntentResult { _FinchIntentResult() }
}

public protocol ParameterSummary {
    associatedtype Intent: AppIntent
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
    public static var openAppWhenRun: Bool { false }
    public static var supportedModes: IntentModes { openAppWhenRun ? .foreground : .background }
    public static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }
    public static var isDiscoverable: Bool { true }
    public static var description: IntentDescription? { nil }
    public static var parameterSummary: some ParameterSummary { _FinchParameterSummary<Self>() }
}

public protocol SystemIntent: AppIntent {}

public protocol OpenIntent: SystemIntent {
    associatedtype Value: AppValue
    var target: Value { get set }
}

extension OpenIntent {
    public static var openAppWhenRun: Bool { true }

    public func perform() async throws -> some IntentResult {
        _FinchIntentResult()
    }
}
