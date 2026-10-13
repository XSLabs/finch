// SPDX-License-Identifier: MIT OR Apache-2.0
//
// SwiftData: a @Model saved to a store, fetched sorted, filtered and limited, changed, deleted,
// read from a second context and from a model actor; then all again with a new container, which
// reads the first's store back. Compared between Apple's SwiftData and Finch's.
//
//   build/userland/finch-swiftdata-test

import Foundation
import SwiftData

@Model final class Entry {
    var expression: String
    var result: Double
    var date: Date
    var note: String?
    init(expression: String, result: Double, date: Date, note: String? = nil) {
        self.expression = expression; self.result = result; self.date = date; self.note = note
    }
}

enum V1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [Entry.self] }
}

@ModelActor actor Store {
    func add(_ e: String, _ r: Double, _ t: Double) throws {
        modelContext.insert(Entry(expression: e, result: r, date: Date(timeIntervalSince1970: t)))
        try modelContext.save()
    }
    func count() throws -> Int { try modelContext.fetch(FetchDescriptor<Entry>()).count }
}

var info = Dl_info()
dladdr(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "$s9SwiftData14ModelContainerCMa"), &info)
print(info.dli_fname.map { String(cString: $0) } ?? "?")

func run(_ url: URL) async throws {
    let config = ModelConfiguration("test", schema: Schema([Entry.self]), url: url, allowsSave: true)
    let container = try ModelContainer(for: Schema(versionedSchema: V1.self), migrationPlan: nil, configurations: config)
    let context = ModelContext(container)
    let existing = try context.fetch(FetchDescriptor<Entry>())
    print("existing", existing.count, existing.map(\.expression).sorted())
    try context.delete(model: Entry.self)
    try context.save()
    for (i, e) in ["1+2", "3×4", "10÷4", "2^10"].enumerated() {
        context.insert(Entry(expression: e, result: Double(i), date: Date(timeIntervalSince1970: Double(1000 - i))))
    }
    print("hasChanges", context.hasChanges)
    try context.save()
    let sorted = try context.fetch(FetchDescriptor<Entry>(sortBy: [SortDescriptor(\.date)]))
    print("sorted", sorted.map { "\($0.expression)=\($0.result)" })
    let filtered = try context.fetch(FetchDescriptor<Entry>(predicate: #Predicate { $0.result >= 2 }, sortBy: [SortDescriptor(\.result, order: .reverse)]))
    print("filtered", filtered.map(\.expression))
    var limited = FetchDescriptor<Entry>(sortBy: [SortDescriptor(\.expression)])
    limited.fetchLimit = 2
    print("limited", try context.fetch(limited).map(\.expression))
    sorted[0].note = "changed"
    print("changed hasChanges", context.hasChanges, sorted[0].hasChanges)
    try context.save()
    context.delete(sorted[1])
    try context.save()
    let second = ModelContext(container)
    print("second", try second.fetch(FetchDescriptor<Entry>(sortBy: [SortDescriptor(\.date)])).map { "\($0.expression) \($0.note ?? "-")" })
    print("count", try second.fetchCount(FetchDescriptor<Entry>()))
    let store = Store(modelContainer: container)
    try await store.add("7-1", 6, 5)
    print("actor count", try await store.count())
    print("same model", sorted[0] == sorted[0], sorted[0] == sorted[2])
}

// a store of this run's own
let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("swiftdata-test-\(getpid())")
try? FileManager.default.removeItem(at: directory)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let url = directory.appendingPathComponent("test.store")
try await run(url)
print("-- again")
try await run(url)
try? FileManager.default.removeItem(at: directory)
