// SPDX-License-Identifier: MIT OR Apache-2.0
// URL formatting and parsing for Finch's Swift Foundation overlay.

#if canImport(FoundationEssentials)
import FoundationEssentials
#endif

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
private struct _URLDisplayCondition: Codable, Hashable, Sendable {
    var component: URL.FormatStyle.Component
    var requirements: Set<String>
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
private enum _URLDisplayRule: Codable, Hashable, Sendable {
    case always
    case never
    case displayWhen(_URLDisplayCondition)
    case omitWhen(_URLDisplayCondition)
    case omitIfHTTPFamily
    case omitSubdomains(Set<String>, includeMultiLevel: Bool, condition: _URLDisplayCondition?)
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension URL {
    public struct FormatStyle: Codable, Hashable, Sendable {
        private var schemeOption: ComponentDisplayOption
        private var userOption: ComponentDisplayOption
        private var passwordOption: ComponentDisplayOption
        private var hostOption: HostDisplayOption
        private var portOption: ComponentDisplayOption
        private var pathOption: ComponentDisplayOption
        private var queryOption: ComponentDisplayOption
        private var fragmentOption: ComponentDisplayOption

        public init(scheme: ComponentDisplayOption = .always,
                    user: ComponentDisplayOption = .never,
                    password: ComponentDisplayOption = .never,
                    host: HostDisplayOption = .always,
                    port: ComponentDisplayOption = .omitIfHTTPFamily,
                    path: ComponentDisplayOption = .always,
                    query: ComponentDisplayOption = .never,
                    fragment: ComponentDisplayOption = .never) {
            schemeOption = scheme
            userOption = user
            passwordOption = password
            hostOption = host
            portOption = port
            pathOption = path
            queryOption = query
            fragmentOption = fragment
        }

        public enum Component: Int, Codable, Hashable, Sendable, CustomStringConvertible {
            case scheme
            case user
            case password
            case host
            case port
            case path
            case query
            case fragment

            public var description: String {
                switch self {
                case .scheme: return "scheme"
                case .user: return "user"
                case .password: return "password"
                case .host: return "host"
                case .port: return "port"
                case .path: return "path"
                case .query: return "query"
                case .fragment: return "fragment"
                }
            }
        }

        public struct ComponentDisplayOption: Codable, Hashable, Sendable, CustomStringConvertible {
            private var rule: _URLDisplayRule

            private init(rule: _URLDisplayRule) { self.rule = rule }

            public static var always: Self { Self(rule: .always) }
            public static var never: Self { Self(rule: .never) }
            public static var omitIfHTTPFamily: Self { Self(rule: .omitIfHTTPFamily) }

            public static func displayWhen(_ component: Component, matches requirements: Set<String>) -> Self {
                Self(rule: .displayWhen(_URLDisplayCondition(component: component, requirements: requirements)))
            }

            public static func omitWhen(_ component: Component, matches requirements: Set<String>) -> Self {
                Self(rule: .omitWhen(_URLDisplayCondition(component: component, requirements: requirements)))
            }

            public var description: String {
                switch rule {
                case .always: return "always"
                case .never: return "never"
                case .displayWhen(let condition):
                    return "displayWhen(\(condition.component), matches: \(condition.requirements))"
                case .omitWhen(let condition):
                    return "omitWhen(\(condition.component), matches: \(condition.requirements))"
                case .omitIfHTTPFamily: return "omitIfHTTPFamily"
                case .omitSubdomains: return "omitSpecificSubdomains"
                }
            }

            fileprivate func shouldDisplay(component: Component, values: [Component: String]) -> Bool {
                switch rule {
                case .always:
                    return true
                case .never:
                    return false
                case .displayWhen(let condition):
                    return values[condition.component].map(condition.requirements.contains) ?? false
                case .omitWhen(let condition):
                    return !(values[condition.component].map(condition.requirements.contains) ?? false)
                case .omitIfHTTPFamily:
                    guard component == .port,
                          let scheme = values[.scheme]?.lowercased() else { return true }
                    guard let port = values[.port], let number = Int(port) else { return true }
                    switch (scheme, number) {
                    case ("http", 80), ("https", 443), ("ws", 80), ("wss", 443):
                        return false
                    default:
                        return true
                    }
                case .omitSubdomains:
                    return true
                }
            }
        }

        public struct HostDisplayOption: Codable, Hashable, Sendable, CustomStringConvertible {
            private var rule: _URLDisplayRule

            private init(rule: _URLDisplayRule) { self.rule = rule }

            public static var always: Self { Self(rule: .always) }
            public static var never: Self { Self(rule: .never) }
            public static var omitIfHTTPFamily: Self { Self(rule: .omitIfHTTPFamily) }

            public static func displayWhen(_ component: Component, matches requirements: Set<String>) -> Self {
                Self(rule: .displayWhen(_URLDisplayCondition(component: component, requirements: requirements)))
            }

            public static func omitWhen(_ component: Component, matches requirements: Set<String>) -> Self {
                Self(rule: .omitWhen(_URLDisplayCondition(component: component, requirements: requirements)))
            }

            public static func omitSpecificSubdomains(_ subdomainsToOmit: Set<String> = [],
                                                      includeMultiLevelSubdomains: Bool = false) -> Self {
                Self(rule: .omitSubdomains(subdomainsToOmit, includeMultiLevel: includeMultiLevelSubdomains, condition: nil))
            }

            public static func omitSpecificSubdomains(_ subdomainsToOmit: Set<String> = [],
                                                      includeMultiLevelSubdomains: Bool = false,
                                                      when component: Component,
                                                      matches requirements: Set<String>) -> Self {
                let condition = _URLDisplayCondition(component: component, requirements: requirements)
                return Self(rule: .omitSubdomains(subdomainsToOmit, includeMultiLevel: includeMultiLevelSubdomains, condition: condition))
            }

            public var description: String {
                switch rule {
                case .always: return "always"
                case .never: return "never"
                case .displayWhen(let condition):
                    return "displayWhen(\(condition.component), matches: \(condition.requirements))"
                case .omitWhen(let condition):
                    return "omitWhen(\(condition.component), matches: \(condition.requirements))"
                case .omitIfHTTPFamily: return "omitIfHTTPFamily"
                case .omitSubdomains(let names, let includeMultiLevel, _):
                    return "omitSpecificSubdomains(\(names), includeMultiLevelSubdomains: \(includeMultiLevel))"
                }
            }

            fileprivate func shouldDisplay(values: [Component: String]) -> Bool {
                switch rule {
                case .always:
                    return true
                case .never:
                    return false
                case .displayWhen(let condition):
                    return values[condition.component].map(condition.requirements.contains) ?? false
                case .omitWhen(let condition):
                    return !(values[condition.component].map(condition.requirements.contains) ?? false)
                case .omitIfHTTPFamily:
                    guard let scheme = values[.scheme]?.lowercased() else { return true }
                    return !["http", "https", "ws", "wss"].contains(scheme)
                case .omitSubdomains:
                    return true
                }
            }

            fileprivate func host(_ host: String, values: [Component: String]) -> String? {
                guard shouldDisplay(values: values) else { return nil }
                guard case .omitSubdomains(let omitted, let includeMultiLevel, let condition) = rule,
                      condition.map({ values[$0.component].map($0.requirements.contains) ?? false }) ?? true else {
                    return host
                }
                let lowered = Set(omitted.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
                var labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
                if includeMultiLevel {
                    while let first = labels.first, lowered.contains(first.lowercased()), labels.count > 1 {
                        labels.removeFirst()
                    }
                } else if let first = labels.first, lowered.contains(first.lowercased()), labels.count > 1 {
                    labels.removeFirst()
                }
                return labels.joined(separator: ".")
            }
        }

        public func scheme(_ strategy: ComponentDisplayOption = .always) -> Self { setting(scheme: strategy) }
        public func user(_ strategy: ComponentDisplayOption = .never) -> Self { setting(user: strategy) }
        public func password(_ strategy: ComponentDisplayOption = .never) -> Self { setting(password: strategy) }
        public func host(_ strategy: HostDisplayOption = .always) -> Self { setting(host: strategy) }
        public func port(_ strategy: ComponentDisplayOption = .omitIfHTTPFamily) -> Self { setting(port: strategy) }
        public func path(_ strategy: ComponentDisplayOption = .always) -> Self { setting(path: strategy) }
        public func query(_ strategy: ComponentDisplayOption = .never) -> Self { setting(query: strategy) }
        public func fragment(_ strategy: ComponentDisplayOption = .never) -> Self { setting(fragment: strategy) }

        private func setting(scheme: ComponentDisplayOption? = nil,
                             user: ComponentDisplayOption? = nil,
                             password: ComponentDisplayOption? = nil,
                             host: HostDisplayOption? = nil,
                             port: ComponentDisplayOption? = nil,
                             path: ComponentDisplayOption? = nil,
                             query: ComponentDisplayOption? = nil,
                             fragment: ComponentDisplayOption? = nil) -> Self {
            var copy = self
            if let scheme { copy.schemeOption = scheme }
            if let user { copy.userOption = user }
            if let password { copy.passwordOption = password }
            if let host { copy.hostOption = host }
            if let port { copy.portOption = port }
            if let path { copy.pathOption = path }
            if let query { copy.queryOption = query }
            if let fragment { copy.fragmentOption = fragment }
            return copy
        }

        public func format(_ value: URL) -> String {
            guard var components = URLComponents(url: value, resolvingAgainstBaseURL: false) else {
                return value.absoluteString
            }
            var values: [Component: String] = [.path: components.path]
            if let scheme = components.scheme { values[.scheme] = scheme }
            if let user = components.user { values[.user] = user }
            if let password = components.password { values[.password] = password }
            if let host = components.host { values[.host] = host }
            if let port = components.port { values[.port] = String(port) }
            if let query = components.query { values[.query] = query }
            if let fragment = components.fragment { values[.fragment] = fragment }

            if !schemeOption.shouldDisplay(component: .scheme, values: values) { components.scheme = nil }
            if !userOption.shouldDisplay(component: .user, values: values) { components.percentEncodedUser = nil }
            if !passwordOption.shouldDisplay(component: .password, values: values) { components.percentEncodedPassword = nil }
            if let host = components.host, let shownHost = hostOption.host(host, values: values) {
                if shownHost != host { components.host = shownHost }
            } else if components.host != nil {
                components.host = nil
            }
            if !portOption.shouldDisplay(component: .port, values: values) { components.port = nil }
            if !pathOption.shouldDisplay(component: .path, values: values) { components.percentEncodedPath = "" }
            if !queryOption.shouldDisplay(component: .query, values: values) { components.percentEncodedQuery = nil }
            if !fragmentOption.shouldDisplay(component: .fragment, values: values) { components.percentEncodedFragment = nil }
            return components.string ?? value.absoluteString
        }

        public typealias FormatInput = URL
        public typealias FormatOutput = String
    }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension URL.FormatStyle: Foundation.FormatStyle, ParseableFormatStyle {
    public var parseStrategy: URL.ParseStrategy { URL.ParseStrategy() }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension URL.FormatStyle {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.schemeOption == rhs.schemeOption && lhs.userOption == rhs.userOption &&
        lhs.passwordOption == rhs.passwordOption && lhs.hostOption == rhs.hostOption &&
        lhs.portOption == rhs.portOption && lhs.pathOption == rhs.pathOption &&
        lhs.queryOption == rhs.queryOption && lhs.fragmentOption == rhs.fragmentOption
    }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension FormatStyle where Self == URL.FormatStyle {
    public static var url: URL.FormatStyle { URL.FormatStyle() }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension ParseableFormatStyle where Self == URL.FormatStyle {
    public static var url: URL.FormatStyle { URL.FormatStyle() }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension URL {
    public func formatted<F>(_ format: F) -> F.FormatOutput
    where F: Foundation.FormatStyle, F.FormatInput == URL {
        format.format(self)
    }

    public func formatted() -> String { URL.FormatStyle().format(self) }

    public init<S>(_ value: S.ParseInput, strategy: S) throws
    where S: Foundation.ParseStrategy, S.ParseOutput == URL {
        self = try strategy.parse(value)
    }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension URL {
    public struct ParseStrategy: Codable, Hashable, Sendable {
        public enum ComponentParseStrategy<Component>: Codable, Hashable, Sendable, CustomStringConvertible
        where Component: Codable & Hashable & Sendable {
            case required
            case optional
            case defaultValue(Component)

            public var description: String {
                switch self {
                case .required: return "required"
                case .optional: return "optional"
                case .defaultValue(let value): return "defaultValue(\(value))"
                }
            }
        }

        private var schemeStrategy: ComponentParseStrategy<String>
        private var userStrategy: ComponentParseStrategy<String>
        private var passwordStrategy: ComponentParseStrategy<String>
        private var hostStrategy: ComponentParseStrategy<String>
        private var portStrategy: ComponentParseStrategy<Int>
        private var pathStrategy: ComponentParseStrategy<String>
        private var queryStrategy: ComponentParseStrategy<String>
        private var fragmentStrategy: ComponentParseStrategy<String>

        public init(scheme: ComponentParseStrategy<String> = .required,
                    user: ComponentParseStrategy<String> = .optional,
                    password: ComponentParseStrategy<String> = .optional,
                    host: ComponentParseStrategy<String> = .required,
                    port: ComponentParseStrategy<Int> = .optional,
                    path: ComponentParseStrategy<String> = .optional,
                    query: ComponentParseStrategy<String> = .optional,
                    fragment: ComponentParseStrategy<String> = .optional) {
            schemeStrategy = scheme
            userStrategy = user
            passwordStrategy = password
            hostStrategy = host
            portStrategy = port
            pathStrategy = path
            queryStrategy = query
            fragmentStrategy = fragment
        }

        public func scheme(_ strategy: ComponentParseStrategy<String> = .required) -> Self { setting(scheme: strategy) }
        public func user(_ strategy: ComponentParseStrategy<String> = .optional) -> Self { setting(user: strategy) }
        public func password(_ strategy: ComponentParseStrategy<String> = .optional) -> Self { setting(password: strategy) }
        public func host(_ strategy: ComponentParseStrategy<String> = .required) -> Self { setting(host: strategy) }
        public func port(_ strategy: ComponentParseStrategy<Int> = .optional) -> Self { setting(port: strategy) }
        public func path(_ strategy: ComponentParseStrategy<String> = .optional) -> Self { setting(path: strategy) }
        public func query(_ strategy: ComponentParseStrategy<String> = .optional) -> Self { setting(query: strategy) }
        public func fragment(_ strategy: ComponentParseStrategy<String> = .optional) -> Self { setting(fragment: strategy) }

        private func setting(scheme: ComponentParseStrategy<String>? = nil,
                             user: ComponentParseStrategy<String>? = nil,
                             password: ComponentParseStrategy<String>? = nil,
                             host: ComponentParseStrategy<String>? = nil,
                             port: ComponentParseStrategy<Int>? = nil,
                             path: ComponentParseStrategy<String>? = nil,
                             query: ComponentParseStrategy<String>? = nil,
                             fragment: ComponentParseStrategy<String>? = nil) -> Self {
            var copy = self
            if let scheme { copy.schemeStrategy = scheme }
            if let user { copy.userStrategy = user }
            if let password { copy.passwordStrategy = password }
            if let host { copy.hostStrategy = host }
            if let port { copy.portStrategy = port }
            if let path { copy.pathStrategy = path }
            if let query { copy.queryStrategy = query }
            if let fragment { copy.fragmentStrategy = fragment }
            return copy
        }

        private func value<T>(_ actual: T?, strategy: ComponentParseStrategy<T>) throws -> T?
        where T: Codable & Hashable & Sendable {
            switch strategy {
            case .required:
                guard let actual else { throw URLError(.badURL) }
                return actual
            case .optional:
                return actual
            case .defaultValue(let fallback):
                return actual ?? fallback
            }
        }

        public func parse(_ value: String) throws -> URL {
            guard var components = URLComponents(string: value) else { throw URLError(.badURL) }
            components.scheme = try self.value(components.scheme, strategy: schemeStrategy)
            components.user = try self.value(components.user, strategy: userStrategy)
            components.password = try self.value(components.password, strategy: passwordStrategy)
            components.host = try self.value(components.host, strategy: hostStrategy)
            components.port = try self.value(components.port, strategy: portStrategy)
            components.path = try self.value(components.path, strategy: pathStrategy) ?? ""
            components.query = try self.value(components.query, strategy: queryStrategy)
            components.fragment = try self.value(components.fragment, strategy: fragmentStrategy)
            guard let url = components.url else { throw URLError(.badURL) }
            return url
        }

        internal func matchURL(in input: String, url: inout URL?) -> Range<String.Index>? {
            var start = input.startIndex
            while start < input.endIndex {
                if let result = try? consuming(input, startingAt: start, in: start..<input.endIndex) {
                    url = result.output
                    return start..<result.upperBound
                }
                start = input.index(after: start)
            }
            url = nil
            return nil
        }

        public typealias ParseInput = String
        public typealias ParseOutput = URL
    }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension URL.ParseStrategy: Foundation.ParseStrategy {
    public static var url: URL.ParseStrategy { URL.ParseStrategy() }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension ParseStrategy where Self == URL.ParseStrategy {
    public static var url: URL.ParseStrategy { URL.ParseStrategy() }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension URL.ParseStrategy: CustomConsumingRegexComponent {
    public typealias RegexOutput = URL

    public func consuming(_ input: String, startingAt index: String.Index,
                          in bounds: Range<String.Index>) throws -> (upperBound: String.Index, output: URL)? {
        guard index < bounds.upperBound else { return nil }
        var end = index
        while end < bounds.upperBound {
            let character = input[end]
            if character.isWhitespace || character == "\"" || character == "<" || character == ">" || character == "|" {
                break
            }
            end = input.index(after: end)
        }
        while end > index {
            if let parsed = try? parse(String(input[index..<end])) {
                return (end, parsed)
            }
            end = input.index(before: end)
        }
        return nil
    }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension RegexComponent where Self == URL.ParseStrategy {
    public static func url(scheme: URL.ParseStrategy.ComponentParseStrategy<String> = .required,
                           user: URL.ParseStrategy.ComponentParseStrategy<String> = .optional,
                           password: URL.ParseStrategy.ComponentParseStrategy<String> = .optional,
                           host: URL.ParseStrategy.ComponentParseStrategy<String> = .required,
                           port: URL.ParseStrategy.ComponentParseStrategy<Int> = .optional,
                           path: URL.ParseStrategy.ComponentParseStrategy<String> = .optional,
                           query: URL.ParseStrategy.ComponentParseStrategy<String> = .optional,
                           fragment: URL.ParseStrategy.ComponentParseStrategy<String> = .optional) -> Self {
        URL.ParseStrategy(scheme: scheme, user: user, password: password, host: host, port: port,
                          path: path, query: query, fragment: fragment)
    }
}
