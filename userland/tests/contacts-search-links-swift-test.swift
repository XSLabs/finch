// SPDX-License-Identifier: MIT OR Apache-2.0
import CoreSpotlight
import Foundation

@main
struct ContactsSearchLinksSwiftTest {
    static func performIndexOperation(_ action: (@escaping @Sendable (Error?) -> Void) -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            action { error in continuation.resume(returning: error == nil) }
        }
    }

    static func main() async {
        print("CoreSpotlight Swift async search")
        let searchableIndex = CSSearchableIndex(name: "org.finch.swift-overlay-comparison-test")
        let cleared = await performIndexOperation { completion in
            searchableIndex.deleteAllSearchableItems(completionHandler: completion)
        }
        let attributes = CSSearchableItemAttributeSet(itemContentType: "public.text")
        attributes.title = "Finch Swift Search Item"
        let item = CSSearchableItem(uniqueIdentifier: "swift-search-item", domainIdentifier: "swift-test",
                                    attributeSet: attributes)
        let indexed = await performIndexOperation { completion in
            searchableIndex.indexSearchableItems([item], completionHandler: completion)
        }

        let context = CSSearchQueryContext()
        context.fetchAttributes = ["title"]
        let query = CSSearchQuery(queryString: "title == \"Finch Swift Search Item\"", queryContext: context)
        var results: [String] = []
        var failure = ""
        if indexed {
            do {
                for try await result in query.results {
                    results.append(result.item.attributeSet.title ?? "")
                }
            } catch {
                failure = "\((error as NSError).code)"
            }
        }
        print("swift search: cleared \(cleared ? 1 : 0) indexed \(indexed ? 1 : 0) results \(results.count) '\(results.joined(separator: ","))' error '\(failure)'")
        _ = await performIndexOperation { completion in
            searchableIndex.deleteSearchableItems(withDomainIdentifiers: ["swift-test"], completionHandler: completion)
        }
    }
}
