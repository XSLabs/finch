// SPDX-License-Identifier: MIT OR Apache-2.0
// Swift name formatting and parsing built on Finch's Objective-C formatter.

#if canImport(FoundationEssentials)
import FoundationEssentials
#endif

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension PersonNameComponents {
    public init(namePrefix: String? = nil, givenName: String? = nil, middleName: String? = nil,
                familyName: String? = nil, nameSuffix: String? = nil, nickname: String? = nil,
                phoneticRepresentation: PersonNameComponents? = nil) {
        self.init()
        self.namePrefix = namePrefix
        self.givenName = givenName
        self.middleName = middleName
        self.familyName = familyName
        self.nameSuffix = nameSuffix
        self.nickname = nickname
        self.phoneticRepresentation = phoneticRepresentation
    }

    public struct FormatStyle: Foundation.FormatStyle, Codable, Hashable, Sendable {
        public var style: Style
        public var locale: Locale

        public init(style: Style = .medium, locale: Locale = .autoupdatingCurrent) {
            self.style = style
            self.locale = locale
        }

        public func locale(_ locale: Locale) -> Self {
            var copy = self
            copy.locale = locale
            return copy
        }

        public var attributed: AttributedStyle {
            AttributedStyle(style: style, locale: locale)
        }

        public func format(_ value: PersonNameComponents) -> String {
            let formatter = PersonNameComponentsFormatter()
            formatter.style = style.foundationStyle
            formatter.locale = locale
            return formatter.string(from: value)
        }

        public enum Style: Int, Codable, Hashable, Sendable {
            case short = 1
            case medium = 2
            case long = 3
            case abbreviated = 4

            fileprivate var foundationStyle: PersonNameComponentsFormatter.Style {
                switch self {
                case .short: return .short
                case .medium: return .medium
                case .long: return .long
                case .abbreviated: return .abbreviated
                }
            }
        }

        public typealias FormatInput = PersonNameComponents
        public typealias FormatOutput = String
    }

    public struct AttributedStyle: Foundation.FormatStyle, Codable, Hashable, Sendable {
        public var style: FormatStyle.Style
        public var locale: Locale

        public init(style: FormatStyle.Style = .medium, locale: Locale = .autoupdatingCurrent) {
            self.style = style
            self.locale = locale
        }

        public func locale(_ locale: Locale) -> Self {
            var copy = self
            copy.locale = locale
            return copy
        }

        public func format(_ value: PersonNameComponents) -> AttributedString {
            let formatter = PersonNameComponentsFormatter()
            formatter.style = style.foundationStyle
            formatter.locale = locale
            let annotated = formatter.annotatedString(from: value)
            return (try? AttributedString(annotated, including: \.foundation)) ?? AttributedString(annotated.string)
        }

        public typealias FormatInput = PersonNameComponents
        public typealias FormatOutput = AttributedString
    }

    public struct ParseStrategy: Foundation.ParseStrategy, Codable, Hashable, Sendable {
        public init() {}

        public func parse(_ value: String) throws -> PersonNameComponents {
            let formatter = PersonNameComponentsFormatter()
            guard let result = formatter.personNameComponents(from: value) else {
                throw CocoaError(.coderInvalidValue)
            }
            return result
        }

        public typealias ParseInput = String
        public typealias ParseOutput = PersonNameComponents
    }

    public func formatted<S>(_ style: S) -> S.FormatOutput
    where S: Foundation.FormatStyle, S.FormatInput == PersonNameComponents {
        style.format(self)
    }

    public func formatted() -> String { FormatStyle().format(self) }

    public init<S>(_ value: S.ParseInput, strategy: S) throws
    where S: Foundation.ParseStrategy, S.ParseOutput == PersonNameComponents {
        self = try strategy.parse(value)
    }

    public init(_ value: String) throws {
        self = try ParseStrategy().parse(value)
    }
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension PersonNameComponents.FormatStyle: ParseableFormatStyle {
    public var parseStrategy: PersonNameComponents.ParseStrategy { PersonNameComponents.ParseStrategy() }
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension FormatStyle where Self == PersonNameComponents.FormatStyle {
    public static func name(style: PersonNameComponents.FormatStyle.Style) -> Self {
        PersonNameComponents.FormatStyle(style: style)
    }
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension ParseableFormatStyle where Self == PersonNameComponents.FormatStyle {
    public static func name(style: PersonNameComponents.FormatStyle.Style) -> Self {
        PersonNameComponents.FormatStyle(style: style)
    }
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension ParseStrategy where Self == PersonNameComponents.ParseStrategy {
    public static var name: PersonNameComponents.ParseStrategy { PersonNameComponents.ParseStrategy() }
}
