// SPDX-License-Identifier: MIT OR Apache-2.0
import Foundation

private final class SearchQueryBox: @unchecked Sendable {
    let query: CSSearchQuery

    init(_ query: CSSearchQuery) {
        self.query = query
    }
}

private final class UserQueryBox: @unchecked Sendable {
    let query: CSUserQuery

    init(_ query: CSUserQuery) {
        self.query = query
    }
}

@available(macOS 13.0, *)
public extension CSSuggestion {
    var localizedAttributedSuggestion: AttributedString {
        AttributedString(__localizedAttributedSuggestion.string)
    }
}

@available(macOS 13.0, *)
public extension CSSearchQuery {
    struct Results: AsyncSequence, @unchecked Sendable {
        public struct Item: Identifiable, Hashable, Comparable, @unchecked Sendable {
            public var id: String { item.uniqueIdentifier }
            public var item: CSSearchableItem

            fileprivate init(_ item: CSSearchableItem) {
                self.item = item
            }

            public static func < (lhs: Item, rhs: Item) -> Bool {
                lhs.item.compare(byRank: rhs.item) == .orderedAscending
            }

            public static func == (lhs: Item, rhs: Item) -> Bool {
                lhs.id == rhs.id
            }

            public func hash(into hasher: inout Hasher) {
                hasher.combine(id)
            }
        }

        public struct Iterator: AsyncIteratorProtocol {
            private var base: AsyncThrowingStream<Item, Error>.Iterator

            fileprivate init(_ base: AsyncThrowingStream<Item, Error>.Iterator) {
                self.base = base
            }

            public mutating func next() async throws -> Item? {
                try await base.next()
            }
        }

        public typealias AsyncIterator = Iterator
        public typealias Element = Item

        private let box: SearchQueryBox

        fileprivate init(_ query: CSSearchQuery) {
            box = SearchQueryBox(query)
        }

        public func makeAsyncIterator() -> Iterator {
            let box = self.box
            let stream = AsyncThrowingStream<Item, Error> { continuation in
                box.query.foundItemsHandler = { items in
                    for item in items {
                        continuation.yield(Item(item))
                    }
                }
                box.query.completionHandler = { error in
                    if let error {
                        continuation.finish(throwing: error)
                    } else {
                        continuation.finish()
                    }
                }
                continuation.onTermination = { @Sendable _ in box.query.cancel() }
                box.query.start()
            }
            return Iterator(stream.makeAsyncIterator())
        }
    }

    var results: Results { Results(self) }
}

@available(macOS 13.0, *)
public extension CSUserQuery {
    struct Item: Identifiable, Hashable, Comparable, @unchecked Sendable {
        public var id: String { item.uniqueIdentifier }
        public var item: CSSearchableItem

        fileprivate init(_ item: CSSearchableItem) {
            self.item = item
        }

        public static func < (lhs: Item, rhs: Item) -> Bool {
            lhs.item.compare(byRank: rhs.item) == .orderedAscending
        }

        public static func == (lhs: Item, rhs: Item) -> Bool {
            lhs.id == rhs.id
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }

    struct Suggestion: Identifiable, Hashable, Comparable, @unchecked Sendable {
        public var id: String { String(suggestion.localizedAttributedSuggestion.characters) }
        public var suggestion: CSSuggestion

        fileprivate init(_ suggestion: CSSuggestion) {
            self.suggestion = suggestion
        }

        public static func < (lhs: Suggestion, rhs: Suggestion) -> Bool {
            lhs.suggestion.compare(byRank: rhs.suggestion) == .orderedAscending
        }

        public static func == (lhs: Suggestion, rhs: Suggestion) -> Bool {
            lhs.id == rhs.id
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }

    struct Responses: AsyncSequence, @unchecked Sendable {
        public enum Response: Identifiable, Hashable, @unchecked Sendable {
            case item(Item)
            case suggestion(Suggestion)

            public var id: String {
                switch self {
                case .item(let item): item.id
                case .suggestion(let suggestion): suggestion.id
                }
            }

            public static func == (lhs: Response, rhs: Response) -> Bool {
                switch (lhs, rhs) {
                case (.item(let left), .item(let right)): left == right
                case (.suggestion(let left), .suggestion(let right)): left == right
                default: false
                }
            }

            public func hash(into hasher: inout Hasher) {
                switch self {
                case .item(let item):
                    hasher.combine(0)
                    hasher.combine(item)
                case .suggestion(let suggestion):
                    hasher.combine(1)
                    hasher.combine(suggestion)
                }
            }
        }

        public struct Iterator: AsyncIteratorProtocol {
            private var base: AsyncThrowingStream<Response, Error>.Iterator

            fileprivate init(_ base: AsyncThrowingStream<Response, Error>.Iterator) {
                self.base = base
            }

            public mutating func next() async throws -> Response? {
                try await base.next()
            }
        }

        public typealias AsyncIterator = Iterator
        public typealias Element = Response

        private let box: UserQueryBox

        fileprivate init(_ query: CSUserQuery) {
            box = UserQueryBox(query)
        }

        public func makeAsyncIterator() -> Iterator {
            let box = self.box
            let stream = AsyncThrowingStream<Response, Error> { continuation in
                box.query.foundItemsHandler = { items in
                    for item in items {
                        continuation.yield(.item(Item(item)))
                    }
                }
                box.query.foundSuggestionsHandler = { suggestions in
                    for suggestion in suggestions {
                        continuation.yield(.suggestion(Suggestion(suggestion)))
                    }
                }
                box.query.completionHandler = { error in
                    if let error {
                        continuation.finish(throwing: error)
                    } else {
                        continuation.finish()
                    }
                }
                continuation.onTermination = { @Sendable _ in box.query.cancel() }
                box.query.start()
            }
            return Iterator(stream.makeAsyncIterator())
        }
    }

    struct Suggestions: AsyncSequence, @unchecked Sendable {
        public struct Iterator: AsyncIteratorProtocol {
            private var base: AsyncThrowingStream<Suggestion, Error>.Iterator

            fileprivate init(_ base: AsyncThrowingStream<Suggestion, Error>.Iterator) {
                self.base = base
            }

            public mutating func next() async throws -> Suggestion? {
                try await base.next()
            }
        }

        public typealias AsyncIterator = Iterator
        public typealias Element = Suggestion

        private let box: UserQueryBox

        fileprivate init(_ query: CSUserQuery) {
            box = UserQueryBox(query)
        }

        public func makeAsyncIterator() -> Iterator {
            let box = self.box
            let stream = AsyncThrowingStream<Suggestion, Error> { continuation in
                box.query.foundItemsHandler = nil
                box.query.foundSuggestionsHandler = { suggestions in
                    for suggestion in suggestions {
                        continuation.yield(Suggestion(suggestion))
                    }
                }
                box.query.completionHandler = { error in
                    if let error {
                        continuation.finish(throwing: error)
                    } else {
                        continuation.finish()
                    }
                }
                continuation.onTermination = { @Sendable _ in box.query.cancel() }
                box.query.start()
            }
            return Iterator(stream.makeAsyncIterator())
        }
    }

    var responses: Responses { Responses(self) }
    var suggestions: Suggestions { Suggestions(self) }

    @available(macOS 15.0, *)
    func userEngaged(_ item: Item, visibleItems: [Item], interaction: UserInteractionKind) {
        __userEngaged(with: item.item, visibleItems: visibleItems.map(\.item), userInteractionType: interaction)
    }

    @available(macOS 15.0, *)
    func userEngaged(_ suggestion: Suggestion, visibleSuggestions: [Suggestion], interaction: UserInteractionKind) {
        __userEngaged(with: suggestion.suggestion,
                     visibleSuggestions: visibleSuggestions.map(\.suggestion),
                     userInteractionType: interaction)
    }
}
