// SPDX-License-Identifier: MIT OR Apache-2.0
import Foundation
import CoreGraphics
import Intents

@available(macOS 11.0, *)
public struct TimelineEntryRelevance: Codable, Hashable {
    public var score: Float
    public var duration: TimeInterval

    public init(score: Float, duration: TimeInterval = 0.0) {
        self.score = score
        self.duration = duration
    }
}

@available(macOS 11.0, *)
public protocol TimelineEntry {
    var date: Date { get }
    var relevance: TimelineEntryRelevance? { get }
}

@available(macOS 11.0, *)
public extension TimelineEntry {
    var relevance: TimelineEntryRelevance? { nil }
}

@available(macOS 11.0, *)
public struct TimelineReloadPolicy: Equatable {
    fileprivate enum Value: Equatable {
        case atEnd
        case never
        case after(Date)
    }

    fileprivate let value: Value
    public static let atEnd = TimelineReloadPolicy(value: .atEnd)
    public static let never = TimelineReloadPolicy(value: .never)

    public static func after(_ date: Date) -> TimelineReloadPolicy {
        TimelineReloadPolicy(value: .after(date))
    }

    public static func == (lhs: TimelineReloadPolicy, rhs: TimelineReloadPolicy) -> Bool {
        lhs.value == rhs.value
    }
}

@available(macOS 11.0, *)
public struct Timeline<EntryType> where EntryType: TimelineEntry {
    public let entries: [EntryType]
    public let policy: TimelineReloadPolicy

    public init(entries: [EntryType], policy: TimelineReloadPolicy) {
        self.entries = entries
        self.policy = policy
    }
}

@available(macOS 11.0, *)
public enum WidgetFamily: Int, CustomStringConvertible, CustomDebugStringConvertible, Sendable {
    case systemSmall = 0
    case systemMedium = 1
    case systemLarge = 2
    @available(macOS 14.0, *) case systemExtraLarge = 3

    public var description: String {
        switch self {
        case .systemSmall: return "systemSmall"
        case .systemMedium: return "systemMedium"
        case .systemLarge: return "systemLarge"
        case .systemExtraLarge: return "systemExtraLarge"
        }
    }

    public var debugDescription: String { description }
}

@available(macOS 13.0, *)
public struct WidgetRenderingMode: Equatable, CustomStringConvertible, Sendable {
    fileprivate enum Value: Equatable {
        case fullColor
        case accented
        case vibrant
    }

    fileprivate let value: Value
    public static let fullColor = WidgetRenderingMode(value: .fullColor)
    public static let accented = WidgetRenderingMode(value: .accented)
    public static let vibrant = WidgetRenderingMode(value: .vibrant)

    public var description: String {
        switch value {
        case .fullColor: return "fullColor"
        case .accented: return "accented"
        case .vibrant: return "vibrant"
        }
    }

    public static func == (lhs: WidgetRenderingMode, rhs: WidgetRenderingMode) -> Bool {
        lhs.value == rhs.value
    }
}

@available(macOS 15.0, *)
public struct WidgetAccentedRenderingMode: Hashable, Sendable {
    fileprivate enum Value: Hashable {
        case accented
        case desaturated
        case accentedDesaturated
        case fullColor
    }

    fileprivate let value: Value
    public static let accented = WidgetAccentedRenderingMode(value: .accented)
    public static let desaturated = WidgetAccentedRenderingMode(value: .desaturated)
    public static let accentedDesaturated = WidgetAccentedRenderingMode(value: .accentedDesaturated)
    public static let fullColor = WidgetAccentedRenderingMode(value: .fullColor)
}

@available(macOS 11.0, *)
public struct TimelineProviderContext {
    public let family: WidgetFamily
    public let isPreview: Bool
    public let displaySize: CGSize

    internal init(family: WidgetFamily, isPreview: Bool, displaySize: CGSize) {
        self.family = family
        self.isPreview = isPreview
        self.displaySize = displaySize
    }
}

@available(macOS 11.0, *)
public protocol TimelineProvider {
    associatedtype Entry: TimelineEntry
    typealias Context = TimelineProviderContext

    func placeholder(in context: Context) -> Entry
    func getSnapshot(in context: Context, completion: @escaping @Sendable (Entry) -> Void)
    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<Entry>) -> Void)
}

@available(macOS 11.0, *)
public struct WidgetInfo: Hashable, Identifiable, CustomDebugStringConvertible, @unchecked Sendable {
    public let configuration: INIntent?
    public let family: WidgetFamily
    public let kind: String
    public var id: WidgetInfo { self }

    internal init(configuration: INIntent?, family: WidgetFamily, kind: String) {
        self.configuration = configuration
        self.family = family
        self.kind = kind
    }

    public static func == (lhs: WidgetInfo, rhs: WidgetInfo) -> Bool {
        lhs.kind == rhs.kind && lhs.family == rhs.family && lhs.configuration === rhs.configuration
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(family)
        hasher.combine(configuration.map { ObjectIdentifier($0) })
    }

    public var hashValue: Int {
        var hasher = Hasher()
        hash(into: &hasher)
        return hasher.finalize()
    }

    public var debugDescription: String {
        "WidgetInfo(kind: \(kind), family: \(family))"
    }
}

@available(macOS 26.0, *)
public struct WidgetPushInfo: Sendable {
    public let token: Data
}

@available(macOS 26.0, *)
public protocol WidgetPushHandler {
    init()
    func pushTokenDidChange(_ pushInfo: WidgetPushInfo, widgets: [WidgetInfo])
}

@available(macOS 11.0, *)
public class WidgetCenter {
    public static let shared = WidgetCenter()

    public struct UserInfoKey {
        public static let kind = "WGWidgetUserInfoKeyKind"
        public static let family = "WGWidgetUserInfoKeyFamily"
        public static let activityID = "WGWidgetUserInfoKeyActivityID"
    }

    private init() {}

    public func reloadTimelines(ofKind kind: String) {
        _ = kind
    }

    public func reloadAllTimelines() {}

    @preconcurrency public func getCurrentConfigurations(
        _ completion: @escaping (Result<[WidgetInfo], any Error>) -> Void
    ) {
        DispatchQueue.main.async {
            completion(.failure(NSError(domain: "ChronoCoreErrorDomain", code: 27)))
        }
    }

    @available(macOS 13.0, *)
    public func invalidateConfigurationRecommendations() {}

    @available(macOS 15.0, *)
    public func invalidateRelevance(ofKind kind: String) {
        _ = kind
    }

    @available(macOS 15.0, *)
    public func currentConfigurations() async throws -> [WidgetInfo] {
        throw NSError(domain: "ChronoCoreErrorDomain", code: 27)
    }

}

@available(macOS 26.0, *)
public extension WidgetCenter {
    var currentPushInfo: WidgetPushInfo? {
        get async { nil }
    }
}
