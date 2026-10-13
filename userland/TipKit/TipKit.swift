// SPDX-License-Identifier: MIT OR Apache-2.0
//
// TipKit, to Apple's interface: tips an app shows when their rules hold. Events record their
// donations (when each happened, with any information given) and parameters their values,
// kept in a file at the datastore's location; a rule is a predicate over an event or a
// parameter (the #Rule macro builds it from Foundation's predicate expressions) and is
// evaluated with them. A tip
// is available once TipKit is configured, while its rules hold, until it's invalidated (closed,
// its action performed, shown too often or too long). popoverTip shows an available tip in a
// popover; TipView shows it inline.

import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - Tips

@frozen
public enum Tips {}

extension Tips: @unchecked Sendable {}
extension Tips: BitwiseCopyable {}

/// Where TipKit keeps its state: the app's defaults, under one key per record.
final class _TipStore: @unchecked Sendable {
    static let shared = _TipStore()
    static let changed = Notification.Name("FinchTipKitChanged")

    private let lock = NSLock()
    var configured = false
    var showAllForTesting: Bool?
    var shownForTesting: Set<String> = []
    var hiddenForTesting: Set<String> = []
    var displayFrequency: Tips.ConfigurationOption.DisplayFrequency = .immediate

    /// The records, each encoded, by key; kept in a file (the datastore location's, or the
    /// app's own in Application Support), read when first needed.
    private var records: [String: Data]?
    private var location: URL?

    static var defaultLocation: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent(Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
            .appendingPathComponent(".tipkit")
    }

    private var file: URL { (location ?? Self.defaultLocation).appendingPathComponent("FinchTipKit.json") }

    /// Where the records are from now on (configure's datastore location).
    func use(_ directory: URL?) {
        lock.lock()
        location = directory
        records = nil
        lock.unlock()
    }

    private func loaded() -> [String: Data] {
        if let records { return records }
        let r = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Data].self, from: $0) } ?? [:]
        records = r
        return r
    }

    private func write() {
        guard let records else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(records).write(to: file, options: .atomic)
    }

    private func key(_ kind: String, _ id: String) -> String { "\(kind).\(id)" }

    func data(_ kind: String, _ id: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return loaded()[key(kind, id)]
    }

    func setData(_ data: Data?, _ kind: String, _ id: String) {
        lock.lock()
        var r = loaded()
        r[key(kind, id)] = data
        records = r
        write()
        lock.unlock()
        notify()
    }

    func value<T: Decodable>(_ type: T.Type, _ kind: String, _ id: String) -> T? {
        data(kind, id).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    func setValue<T: Encodable>(_ value: T?, _ kind: String, _ id: String) {
        setData(value.flatMap { try? JSONEncoder().encode($0) }, kind, id)
    }

    func notify() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    func reset() {
        lock.lock()
        records = [:]
        try? FileManager.default.removeItem(at: file)
        lock.unlock()
        notify()
    }
}

extension Tips {
    public struct ConfigurationOption: Sendable {
        enum Kind: Sendable {
            case cloudKit, datastore(DatastoreLocation), displayFrequency(DisplayFrequency)
        }
        var kind: Kind

        public static func cloudKitContainer(_ cloudKitContainer: CloudKitContainer?) -> ConfigurationOption {
            ConfigurationOption(kind: .cloudKit)
        }

        public struct CloudKitContainer: Equatable, Sendable {
            var name: String?
            public static var automatic: CloudKitContainer { CloudKitContainer(name: nil) }
            public static func named(_ containerName: String) -> CloudKitContainer { CloudKitContainer(name: containerName) }
        }

        public static func datastoreLocation(_ storeLocation: DatastoreLocation) -> ConfigurationOption {
            ConfigurationOption(kind: .datastore(storeLocation))
        }

        public struct DatastoreLocation: Equatable, Sendable {
            var url: URL?
            var group: String?
            public static var applicationDefault: DatastoreLocation { DatastoreLocation() }
            public static func groupContainer(identifier: String) throws -> DatastoreLocation { DatastoreLocation(group: identifier) }
            public static func url(_ url: URL) -> DatastoreLocation { DatastoreLocation(url: url) }
        }

        public static func displayFrequency(_ displayFrequency: DisplayFrequency) -> ConfigurationOption {
            ConfigurationOption(kind: .displayFrequency(displayFrequency))
        }

        public struct DisplayFrequency: Equatable, Sendable {
            var interval: TimeInterval
            public static var immediate: DisplayFrequency { DisplayFrequency(interval: 0) }
            public static var hourly: DisplayFrequency { DisplayFrequency(interval: 3600) }
            public static var daily: DisplayFrequency { DisplayFrequency(interval: 86400) }
            public static var weekly: DisplayFrequency { DisplayFrequency(interval: 7 * 86400) }
            public static var monthly: DisplayFrequency { DisplayFrequency(interval: 30 * 86400) }
        }
    }

    /// Starts TipKit: tips can be shown from now on.
    public static func configure(_ configuration: [ConfigurationOption] = []) throws {
        let store = _TipStore.shared
        // configuring again changes nothing (Apple's doesn't throw either)
        if store.configured { return }
        for option in configuration {
            switch option.kind {
            case .datastore(let location):
                if let url = location.url {
                    store.use(url)
                } else if let group = location.group,
                          let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
                    store.use(container.appendingPathComponent("Library/Application Support/.tipkit"))
                }
            case .displayFrequency(let frequency):
                store.displayFrequency = frequency
            case .cloudKit:
                break
            }
        }
        store.configured = true
        store.notify()
    }

    public static func resetDatastore() throws {
        _TipStore.shared.reset()
    }

    public static func showAllTipsForTesting() {
        _TipStore.shared.showAllForTesting = true
        _TipStore.shared.notify()
    }

    public static func showTipsForTesting(_ tips: [any Tip.Type]) {
        _TipStore.shared.shownForTesting.formUnion(tips.map { String(reflecting: $0) })
        _TipStore.shared.notify()
    }

    public static func hideAllTipsForTesting() {
        _TipStore.shared.showAllForTesting = false
        _TipStore.shared.notify()
    }

    public static func hideTipsForTesting(_ tips: [any Tip.Type]) {
        _TipStore.shared.hiddenForTesting.formUnion(tips.map { String(reflecting: $0) })
        _TipStore.shared.notify()
    }
}

public struct TipKitError: Error, LocalizedError, Hashable {
    var code: Int

    public var description: String {
        switch code {
        case 1: "The value given to a tips predicate isn't of a supported type."
        case 2: "The app lacks the group container entitlement."
        default: "Tips has already been configured."
        }
    }

    public var errorDescription: String? { description }

    public static let invalidPredicateValueType = TipKitError(code: 1)
    public static let missingGroupContainerEntitlements = TipKitError(code: 2)
    public static let tipsDatastoreAlreadyConfigured = TipKitError(code: 3)
}

// MARK: - Events

extension Tips {
    public struct EmptyDonation: Codable, Sendable {
        public init() {}

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encodeNil()
        }

        public init(from decoder: any Decoder) throws {}
    }

    public struct DonationTimeRange: Hashable, Codable, Sendable {
        var seconds: TimeInterval

        public static var minute: DonationTimeRange { DonationTimeRange(seconds: 60) }
        public static var hour: DonationTimeRange { DonationTimeRange(seconds: 3600) }
        public static var day: DonationTimeRange { DonationTimeRange(seconds: 86400) }
        public static var week: DonationTimeRange { DonationTimeRange(seconds: 7 * 86400) }
        public static func minutes(_ value: Int) -> DonationTimeRange { DonationTimeRange(seconds: 60 * TimeInterval(value)) }
        public static func hours(_ value: Int) -> DonationTimeRange { DonationTimeRange(seconds: 3600 * TimeInterval(value)) }
        public static func days(_ value: Int) -> DonationTimeRange { DonationTimeRange(seconds: 86400 * TimeInterval(value)) }
        public static func weeks(_ value: Int) -> DonationTimeRange { DonationTimeRange(seconds: 7 * 86400 * TimeInterval(value)) }
    }

    public struct DonationLimit: Sendable {
        public let maximumCount: Int
        public let maximumAge: DonationTimeRange?

        public init(maximumCount: Int, maximumAge: DonationTimeRange? = nil) {
            self.maximumCount = maximumCount
            self.maximumAge = maximumAge
        }
    }

    /// Something that happens in the app, recorded each time it does.
    public struct Event<DonationInfo>: Identifiable, Sendable where DonationInfo: Decodable, DonationInfo: Encodable, DonationInfo: Sendable {
        public let id: String
        var limit: DonationLimit?

        public typealias ID = String

        public init(id: String) where DonationInfo == EmptyDonation {
            self.id = id
        }

        public init(id: String) {
            self.id = id
        }

        public init(id: String, donationLimit: DonationLimit) where DonationInfo == EmptyDonation {
            self.id = id
            limit = donationLimit
        }

        public init(id: String, donationLimit: DonationLimit) {
            self.id = id
            limit = donationLimit
        }

        public var donations: [Donation] {
            _TipStore.shared.value([Donation].self, "event", id) ?? []
        }

        func record(_ info: DonationInfo) {
            var all = donations
            all.append(Donation(date: Date(), info: info))
            if let limit {
                if let age = limit.maximumAge {
                    let cutoff = Date().addingTimeInterval(-age.seconds)
                    all.removeAll { $0.date < cutoff }
                }
                if all.count > limit.maximumCount { all.removeFirst(all.count - limit.maximumCount) }
            }
            _TipStore.shared.setValue(all, "event", id)
        }
    }
}

extension Tips.Event {
    /// One time the event happened.
    @dynamicMemberLookup
    public struct Donation: Codable, Sendable {
        public let date: Date
        let info: DonationInfo

        init(date: Date, info: DonationInfo) {
            self.date = date
            self.info = info
        }

        public subscript<Value>(dynamicMember keyPath: KeyPath<DonationInfo, Value>) -> Value {
            info[keyPath: keyPath]
        }

        enum CodingKeys: String, CodingKey { case date, info }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(date, forKey: .date)
            try c.encode(info, forKey: .info)
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            date = try c.decode(Date.self, forKey: .date)
            info = try c.decode(DonationInfo.self, forKey: .info)
        }
    }

    public func donate() async where DonationInfo == Tips.EmptyDonation {
        record(Tips.EmptyDonation())
    }

    public func donate(_ donation: DonationInfo) async {
        record(donation)
    }

    public func sendDonation(_ completion: (@Sendable () -> Void)? = nil) where DonationInfo == Tips.EmptyDonation {
        record(Tips.EmptyDonation())
        completion?()
    }

    public func sendDonation(_ donation: DonationInfo, _ completion: (@Sendable () -> Void)? = nil) {
        record(donation)
        completion?()
    }

    public func deleteDonations() async throws {
        _TipStore.shared.setData(nil, "event", id)
    }
}

extension Sequence {
    public func donatedWithin<DonationInfo>(_ timeRange: Tips.DonationTimeRange) -> [Element]
        where DonationInfo: Decodable, DonationInfo: Encodable, DonationInfo: Sendable, Element == Tips.Event<DonationInfo>.Donation {
        let cutoff = Date().addingTimeInterval(-timeRange.seconds)
        return filter { $0.date >= cutoff }
    }

    public func largestSubset<DonationInfo, Value>(groupedBy keyPath: KeyPath<DonationInfo, Value>) -> [Element]
        where DonationInfo: Decodable, DonationInfo: Encodable, DonationInfo: Sendable, Value: Hashable,
              Element == Tips.Event<DonationInfo>.Donation {
        Dictionary(grouping: self) { $0.info[keyPath: keyPath] }.values.max { $0.count < $1.count } ?? []
    }

    public func smallestSubset<DonationInfo, Value>(groupedBy keyPath: KeyPath<DonationInfo, Value>) -> [Element]
        where DonationInfo: Decodable, DonationInfo: Encodable, DonationInfo: Sendable, Value: Hashable,
              Element == Tips.Event<DonationInfo>.Donation {
        Dictionary(grouping: self) { $0.info[keyPath: keyPath] }.values.min { $0.count < $1.count } ?? []
    }
}

// MARK: - Parameters

extension Tips {
    public struct ParameterOption: Sendable {
        var transient: Bool
        public static var transient: ParameterOption { ParameterOption(transient: true) }
    }

    /// A value rules can depend on, kept between launches (unless transient).
    public struct Parameter<Value>: Identifiable, Sendable where Value: Decodable, Value: Encodable, Value: Sendable {
        public let id: String
        let initialValue: Value
        let transient: Bool

        public typealias ID = String

        public init(_ enclosingInstance: (some Any).Type, _ name: String, _ initialValue: Value, _ options: ParameterOption...) {
            id = "\(String(reflecting: enclosingInstance)).\(name)"
            self.initialValue = initialValue
            transient = options.contains { $0.transient }
        }

        @_disfavoredOverload
        public init<T>(_ keyPath: KeyPath<T, Value>, _ initialValue: Value, _ options: ParameterOption...) {
            id = "\(keyPath)"
            self.initialValue = initialValue
            transient = options.contains { $0.transient }
        }

        public var wrappedValue: Value {
            get {
                if transient { return _TipTransientValues.shared.value(id) as? Value ?? initialValue }
                return _TipStore.shared.value(Value.self, "parameter", id) ?? initialValue
            }
            nonmutating set {
                if transient {
                    _TipTransientValues.shared.set(newValue, id)
                    _TipStore.shared.notify()
                } else {
                    _TipStore.shared.setValue(newValue, "parameter", id)
                }
            }
        }
    }
}

final class _TipTransientValues: @unchecked Sendable {
    static let shared = _TipTransientValues()
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    func value(_ id: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return values[id]
    }

    func set(_ value: Any, _ id: String) {
        lock.lock(); values[id] = value; lock.unlock()
    }
}

// MARK: - Rules

/// What a rule about an event is made of (the #Rule macro's expressions).
public protocol EventPredicateExpression<Output>: PredicateExpression {}

extension PredicateExpressions.Equal: EventPredicateExpression where LHS: EventPredicateExpression, RHS: EventPredicateExpression {}
extension PredicateExpressions.NotEqual: EventPredicateExpression where LHS: EventPredicateExpression, RHS: EventPredicateExpression {}
extension PredicateExpressions.Comparison: EventPredicateExpression where LHS: EventPredicateExpression, RHS: EventPredicateExpression {}
extension PredicateExpressions.KeyPath: EventPredicateExpression where Root: EventPredicateExpression {}
extension PredicateExpressions.Value: EventPredicateExpression {}
extension PredicateExpressions.Variable: EventPredicateExpression {}

extension PredicateExpressions {
    public enum DonationFilterOperator: Codable, Sendable, Hashable {
        case equal, notEqual, lessThan, lessThanOrEqual, greaterThan, greaterThanOrEqual
    }

    public struct DonationFilter<DonationInfo, Value, Input>: EventPredicateExpression, Sendable
        where DonationInfo: Decodable, DonationInfo: Encodable, DonationInfo: Sendable, Value: Decodable, Value: Encodable,
              Value: Sendable, Input: Sendable, Input: EventPredicateExpression, Input.Output == [Tips.Event<DonationInfo>.Donation],
              Value: Comparable {
        let input: Input
        nonisolated(unsafe) let keyPath: Swift.KeyPath<DonationInfo, Value>
        let op: DonationFilterOperator
        let value: Value

        public func evaluate(_ bindings: PredicateBindings) throws -> [Tips.Event<DonationInfo>.Donation] {
            try input.evaluate(bindings).filter { donation in
                let v = donation.info[keyPath: keyPath]
                switch op {
                case .equal: return v == value
                case .notEqual: return v != value
                case .lessThan: return v < value
                case .lessThanOrEqual: return v <= value
                case .greaterThan: return v > value
                case .greaterThanOrEqual: return v >= value
                }
            }
        }

        public typealias Output = [Tips.Event<DonationInfo>.Donation]
    }

    public static func build_DonationFilter<DonationInfo, Input, Value>(_ input: Input, keyPath: Swift.KeyPath<DonationInfo, Value>,
                                                                        op: DonationFilterOperator, value: Value)
        -> DonationFilter<DonationInfo, Value, Input>
        where DonationInfo: Decodable, DonationInfo: Encodable, DonationInfo: Sendable, Value: Decodable, Value: Encodable,
              Value: Sendable, Value: Comparable, Input: Sendable, Input: EventPredicateExpression,
              Input.Output == [Tips.Event<DonationInfo>.Donation] {
        DonationFilter(input: input, keyPath: keyPath, op: op, value: value)
    }

    public struct DonatedWithin<DonationInfo, Input>: EventPredicateExpression, Sendable
        where DonationInfo: Decodable, DonationInfo: Encodable, DonationInfo: Sendable, Input: Sendable,
              Input: EventPredicateExpression, Input.Output == [Tips.Event<DonationInfo>.Donation] {
        let input: Input
        let timeRange: Tips.DonationTimeRange

        public func evaluate(_ bindings: PredicateBindings) throws -> [Tips.Event<DonationInfo>.Donation] {
            try input.evaluate(bindings).donatedWithin(timeRange)
        }

        public typealias Output = [Tips.Event<DonationInfo>.Donation]
    }

    public static func build_donatedWithin<DonationInfo, Input>(_ input: Input, _ timeRange: Tips.DonationTimeRange)
        -> DonatedWithin<DonationInfo, Input>
        where DonationInfo: Decodable, DonationInfo: Encodable, DonationInfo: Sendable, Input: Sendable,
              Input: EventPredicateExpression, Input.Output == [Tips.Event<DonationInfo>.Donation] {
        DonatedWithin(input: input, timeRange: timeRange)
    }
}

extension Tips {
    public protocol RuleInput {
        associatedtype Value
    }

    /// A condition for showing a tip.
    public struct Rule: Sendable {
        public enum CompoundOperation: Sendable, Hashable {
            case disjunction
            case conjunction
        }

        let check: @Sendable () -> Bool

        public init(_ operation: CompoundOperation, _ rules: [Rule]) {
            check = {
                operation == .conjunction ? rules.allSatisfy { $0.check() } : rules.contains { $0.check() }
            }
        }

        public init<Donation>(_ event: Event<Donation>,
                              _ eventBuilder: (PredicateExpressions.Variable<Event<Donation>>) -> any EventPredicateExpression<Bool>)
            where Donation: Decodable, Donation: Encodable, Donation: Sendable {
            let variable = PredicateExpressions.Variable<Event<Donation>>()
            let expression = _TipExpression(eventBuilder(variable))
            check = {
                (try? expression.evaluate(PredicateBindings((variable, event)))) ?? false
            }
        }

        public init<Value>(_ parameter: Parameter<Value>,
                           _ parameterBuilder: (PredicateExpressions.Variable<Value>) -> any StandardPredicateExpression<Bool>)
            where Value: Decodable, Value: Encodable, Value: Sendable {
            let variable = PredicateExpressions.Variable<Value>()
            let expression = _TipExpression(parameterBuilder(variable))
            check = {
                (try? expression.evaluate(PredicateBindings((variable, parameter.wrappedValue)))) ?? false
            }
        }
    }

    @resultBuilder
    public struct RuleBuilder {
        public static func buildBlock() -> [Rule] { [] }
        public static func buildExpression(_ child: Rule) -> [Rule] { [child] }
        @_disfavoredOverload public static func buildExpression(_ child: Rule?) -> [Rule] { child.map { [$0] } ?? [] }
        public static func buildExpression(_ child: [Rule]) -> [Rule] { child }
        @_disfavoredOverload public static func buildExpression(_ child: [Rule?]) -> [Rule] { child.compactMap { $0 } }
        public static func buildEither(first: [Rule]) -> [Rule] { first }
        public static func buildEither(second: [Rule]) -> [Rule] { second }
        public static func buildOptional(_ component: Rule?) -> [Rule] { component.map { [$0] } ?? [] }
        public static func buildOptional(_ component: [Rule?]) -> [Rule] { component.compactMap { $0 } }
        public static func buildPartialBlock(first: [Rule]) -> [Rule] { first }
        public static func buildPartialBlock(accumulated: [Rule], next: [Rule]) -> [Rule] { accumulated + next }
    }
}

extension Tips.Parameter: Tips.RuleInput {}
extension Tips.Event: Tips.RuleInput {
    public typealias Value = Tips.Event<DonationInfo>
}

/// A predicate expression kept for evaluating later, from any thread.
struct _TipExpression: @unchecked Sendable {
    let evaluateBindings: (PredicateBindings) throws -> Bool

    init(_ expression: any EventPredicateExpression<Bool>) {
        evaluateBindings = { try expression.evaluate($0) }
    }

    init(_ expression: any StandardPredicateExpression<Bool>) {
        evaluateBindings = { try expression.evaluate($0) }
    }

    func evaluate(_ bindings: PredicateBindings) throws -> Bool {
        try evaluateBindings(bindings)
    }
}

// MARK: - Options

public protocol TipOption: Sendable {}

extension Tips {
    public struct IgnoresDisplayFrequency: TipOption {
        let value: Bool
        public init(_ ignoresDisplayFrequency: Bool) { value = ignoresDisplayFrequency }
    }

    public struct MaxDisplayCount: TipOption {
        let value: Int
        public init(_ maxDisplayCount: Int) { value = maxDisplayCount }
    }

    public struct MaxDisplayDuration: TipOption {
        let value: TimeInterval
        public init(_ maxDisplayDuration: TimeInterval) { value = maxDisplayDuration }
    }

    /// The options a builder gathers.
    struct _Options: TipOption {
        var all: [any TipOption]
    }

    @resultBuilder
    public struct OptionsBuilder {
        public static func buildExpression(_ child: some TipOption) -> some TipOption { _Options(all: [child]) }
        @_disfavoredOverload public static func buildExpression(_ child: (any TipOption)?) -> some TipOption { _Options(all: child.map { [$0] } ?? []) }
        public static func buildExpression(_ child: [some TipOption]) -> some TipOption { _Options(all: child) }
        @_disfavoredOverload public static func buildExpression(_ child: [(any TipOption)?]) -> some TipOption { _Options(all: child.compactMap { $0 }) }
        public static func buildEither(first: some TipOption) -> some TipOption { _Options(all: flatten(first)) }
        public static func buildEither(second: some TipOption) -> some TipOption { _Options(all: flatten(second)) }
        public static func buildOptional(_ component: (any TipOption)?) -> some TipOption { _Options(all: component.map(flatten) ?? []) }
        public static func buildOptional(_ component: [(any TipOption)?]) -> some TipOption { _Options(all: component.compactMap { $0 }.flatMap(flatten)) }
        public static func buildBlock() -> some TipOption { _Options(all: []) }
        public static func buildPartialBlock(first: some TipOption) -> some TipOption { _Options(all: flatten(first)) }
        public static func buildPartialBlock(accumulated: some TipOption, next: some TipOption) -> some TipOption {
            _Options(all: flatten(accumulated) + flatten(next))
        }
        public static func buildFinalResult(_ component: some TipOption) -> [any TipOption] { flatten(component) }

        static func flatten(_ option: any TipOption) -> [any TipOption] {
            if let options = option as? _Options { return options.all.flatMap(flatten) }
            return [option]
        }
    }
}

// MARK: - Tip

@_typeEraser(AnyTip)
public protocol Tip: Identifiable, Sendable {
    var id: String { get }
    var title: Text { get }
    var message: Text? { get }
    var image: Image? { get }
    @Tips.ActionBuilder var actions: [Self.Action] { get }
    @Tips.RuleBuilder var rules: [Self.Rule] { get }
    @Tips.OptionsBuilder var options: [any TipOption] { get }
}

extension Tip {
    public typealias Status = Tips.Status
    public typealias InvalidationReason = Tips.InvalidationReason
    public typealias Action = Tips.Action
    public typealias Rule = Tips.Rule
    public typealias Event = Tips.Event
    public typealias Option = TipOption
    public typealias IgnoresDisplayFrequency = Tips.IgnoresDisplayFrequency
    public typealias MaxDisplayCount = Tips.MaxDisplayCount
    public typealias MaxDisplayDuration = Tips.MaxDisplayDuration
}

extension Tip {
    public var id: String { String(describing: Self.self) }
    public var message: Text? { nil }
    public var image: Image? { nil }
    public var actions: [Action] { [] }
    public var rules: [Rule] { [] }
    public var options: [any TipOption] { [] }
}

extension Tips {
    public enum Status: Hashable, Sendable {
        case pending
        case available
        case invalidated(InvalidationReason)
    }

    public enum InvalidationReason: Hashable, Sendable, Codable {
        case actionPerformed
        case displayCountExceeded
        case displayDurationExceeded
        case tipClosed
    }

    /// A button in a tip.
    public struct Action: Identifiable, Sendable {
        public let id: String
        public let index: Int?
        public let label: @Sendable () -> Text
        public let handler: @MainActor @Sendable () -> Void

        @_silgen_name("$s6TipKit4TipsO6ActionV2id7perform_AESSSg_yyc7SwiftUI4TextVyYbctcfC")
        public init(id: String? = nil, perform handler: @escaping @MainActor @Sendable () -> Void = {},
                    _ label: @escaping @Sendable () -> Text) {
            self.id = id ?? UUID().uuidString
            index = nil
            self.handler = handler
            self.label = label
        }

        public init(id: String? = nil, title: some StringProtocol, perform handler: @escaping @MainActor @Sendable () -> Void = {}) {
            let title = String(title)
            self.init(id: id, perform: handler) { Text(title) }
        }

        init(id: String, index: Int?, label: @escaping @Sendable () -> Text, handler: @escaping @MainActor @Sendable () -> Void) {
            self.id = id
            self.index = index
            self.label = label
            self.handler = handler
        }

        @usableFromInline
        func with(index: Int) -> Action {
            Action(id: id, index: index, label: label, handler: handler)
        }

        public typealias ID = String
    }

    @resultBuilder
    public struct ActionBuilder {
        @inlinable public static func buildExpression(_ element: Action) -> [Action] { [element] }
        @inlinable public static func buildExpression(_ component: [Action]) -> [Action] { component }
        @inlinable public static func buildPartialBlock(first: [Action]) -> [Action] { first }
        @inlinable public static func buildPartialBlock(accumulated: [Action], next: [Action]) -> [Action] { accumulated + next }
        @inlinable public static func buildArray(_ components: [[Action]]) -> [Action] { components.reduce(into: []) { $0.append(contentsOf: $1) } }
        @inlinable public static func buildEither(first component: [Action]) -> [Action] { component }
        @inlinable public static func buildEither(second component: [Action]) -> [Action] { component }
        @inlinable public static func buildLimitedAvailability(_ component: [Action]) -> [Action] { component }
        @inlinable public static func buildOptional(_ component: [Action]?) -> [Action] { component ?? [] }
        @inlinable public static func buildFinalResult(_ component: [Action]) -> [Action] {
            component.enumerated().map { idx, action in action.with(index: idx) }
        }
    }
}

/// What's known of a tip between launches.
struct _TipRecord: Codable {
    var invalidated: Tips.InvalidationReason?
    var displayCount = 0
    var firstDisplay: Date?
}

extension Tip {
    var record: _TipRecord { _TipStore.shared.value(_TipRecord.self, "tip", id) ?? _TipRecord() }

    func updateRecord(_ change: (inout _TipRecord) -> Void) {
        var r = record
        change(&r)
        _TipStore.shared.setValue(r, "tip", id)
    }

    public var status: Status {
        let store = _TipStore.shared
        let type = String(reflecting: Self.self)
        if store.hiddenForTesting.contains(type) || store.showAllForTesting == false { return .pending }
        if store.showAllForTesting == true || store.shownForTesting.contains(type) { return .available }
        guard store.configured else { return .pending }
        let r = record
        if let reason = r.invalidated { return .invalidated(reason) }
        for option in Tips.OptionsBuilder.flatten(Tips._Options(all: options)) {
            if let max = option as? Tips.MaxDisplayCount, r.displayCount >= max.value {
                return .invalidated(.displayCountExceeded)
            }
            if let max = option as? Tips.MaxDisplayDuration, let first = r.firstDisplay,
               Date().timeIntervalSince(first) > max.value {
                return .invalidated(.displayDurationExceeded)
            }
        }
        return rules.allSatisfy { $0.check() } ? .available : .pending
    }

    public var shouldDisplay: Bool { status == .available }

    public var statusUpdates: AsyncStream<Status> {
        AsyncStream { continuation in
            continuation.yield(status)
            let observer = NotificationCenter.default.addObserver(forName: _TipStore.changed, object: nil, queue: .main) { _ in
                continuation.yield(self.status)
            }
            continuation.onTermination = { _ in NotificationCenter.default.removeObserver(observer) }
        }
    }

    public var shouldDisplayUpdates: AsyncMapSequence<AsyncStream<Status>, Bool> {
        statusUpdates.map { $0 == .available }
    }

    public func invalidate(reason: InvalidationReason) {
        updateRecord { $0.invalidated = reason }
    }

    public func resetEligibility() async {
        updateRecord { $0 = _TipRecord() }
    }

    /// The tip was shown once more.
    func noteDisplayed() {
        updateRecord { r in
            r.displayCount += 1
            if r.firstDisplay == nil { r.firstDisplay = Date() }
        }
    }
}

public struct AnyTip: Tip {
    let base: any Tip

    public init(_ tip: some Tip) {
        self.init(any: tip)
    }

    public init<T: Tip>(erasing tip: T) {
        self.init(any: tip)
    }

    init(any tip: any Tip) {
        if let any = tip as? AnyTip { base = any.base } else { base = tip }
    }

    public var id: String { base.id }
    public var title: Text { base.title }
    public var message: Text? { base.message }
    public var image: Image? { base.image }
    public var actions: [Action] { base.actions }
    public var rules: [Rule] { base.rules }
    public var options: [any TipOption] { base.options }

    public typealias ID = String
}

// MARK: - Tip groups

/// Tips shown one at a time: the first available (or the next, in order).
@Observable
public final class TipGroup: @unchecked Sendable {
    public enum Priority: Sendable, Hashable {
        case firstAvailable
        case ordered
    }

    let priority: Priority
    let tips: [any Tip]

    public init(_ priority: Priority = .firstAvailable, @Tips.GroupBuilder _ builder: () -> [any Tip]) {
        self.priority = priority
        tips = builder()
    }

    @MainActor
    public var currentTip: (any Tip)? {
        switch priority {
        case .firstAvailable:
            return tips.first { $0.shouldDisplay }
        case .ordered:
            for tip in tips {
                if tip.shouldDisplay { return tip }
                if case .invalidated = tip.status { continue }
                return nil
            }
            return nil
        }
    }

    public var currentTipUpdates: some AsyncSequence<any Tip, Never> {
        AsyncStream<any Tip> { continuation in
            let observer = NotificationCenter.default.addObserver(forName: _TipStore.changed, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let tip = self?.currentTip { continuation.yield(tip) }
                }
            }
            continuation.onTermination = { _ in NotificationCenter.default.removeObserver(observer) }
        }
    }
}

extension Tips {
    @resultBuilder
    public struct GroupBuilder {
        public static func buildBlock() -> [any Tip] { [] }
        public static func buildBlock(_ components: any Tip...) -> [any Tip] { components }
        public static func buildPartialBlock(first: any Tip) -> [any Tip] { [first] }
        public static func buildPartialBlock(first: [any Tip]) -> [any Tip] { first }
        public static func buildPartialBlock(accumulated: [any Tip], next: any Tip) -> [any Tip] { accumulated + [next] }
        public static func buildPartialBlock(accumulated: [any Tip], next: [any Tip]) -> [any Tip] { accumulated + next }
        public static func buildPartialBlock(first: Void) -> [any Tip] { [] }
        public static func buildPartialBlock(first: Never) -> [any Tip] {}
        public static func buildIf(_ element: [any Tip]?) -> [any Tip] { element ?? [] }
        public static func buildEither(first: [any Tip]) -> [any Tip] { first }
        public static func buildEither(second: [any Tip]) -> [any Tip] { second }
        public static func buildArray(_ components: [[any Tip]]) -> [any Tip] { components.flatMap { $0 } }
    }
}
