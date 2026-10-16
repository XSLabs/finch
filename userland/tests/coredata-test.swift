// SPDX-License-Identifier: MIT OR Apache-2.0
import CoreData
import Foundation

func stop(_ message: String) -> Never {
    fputs("coredata-test: \(message)\n", stderr)
    exit(1)
}

guard CommandLine.arguments.count == 4 else {
    stop("usage: finch-coredata-test write|read STORE MODEL")
}

let mode = CommandLine.arguments[1]
let storeURL = URL(fileURLWithPath: CommandLine.arguments[2])
let modelURL = URL(fileURLWithPath: CommandLine.arguments[3])
guard mode == "write" || mode == "read" else { stop("mode must be write or read") }

print("CoreData: \(Bundle(for: NSManagedObjectContext.self).bundleURL.path)")
if mode == "write" {
    for suffix in ["", "-shm", "-wal"] {
        try? FileManager.default.removeItem(atPath: storeURL.path + suffix)
    }
}
guard let model = NSManagedObjectModel(contentsOf: modelURL) else { stop("could not load the compiled model") }
let container = NSPersistentContainer(name: "CoreDataTest", managedObjectModel: model)
let description = NSPersistentStoreDescription(url: storeURL)
description.shouldAddStoreAsynchronously = false
description.isReadOnly = mode == "read"
container.persistentStoreDescriptions = [description]

let loaded = DispatchSemaphore(value: 0)
var loadError: Error?
container.loadPersistentStores { _, error in
    loadError = error
    loaded.signal()
}
guard loaded.wait(timeout: .now() + 15) == .success else { stop("timed out loading the store") }
if let loadError { stop("could not load the store: \(loadError.localizedDescription)") }

let context = container.newBackgroundContext()
do {
    let lines = try context.performAndWait { () throws -> [String] in
        if mode == "write" {
            let ada = NSEntityDescription.insertNewObject(forEntityName: "Owner", into: context)
            ada.setValue("Ada", forKey: "name")
            let grace = NSEntityDescription.insertNewObject(forEntityName: "Owner", into: context)
            grace.setValue("Grace", forKey: "name")
            for (name, score, owner) in [("alpha", 4, ada), ("bravo", 9, ada), ("charlie", 12, grace)] {
                let record = NSEntityDescription.insertNewObject(forEntityName: "Record", into: context)
                record.setValue(name, forKey: "name")
                record.setValue(score, forKey: "score")
                record.setValue(owner, forKey: "owner")
            }
            try context.save()
        }

        let request = NSFetchRequest<NSManagedObject>(entityName: "Record")
        request.predicate = NSPredicate(format: "score >= %d", 9)
        request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        let records = try context.fetch(request)
        let count = try context.count(for: request)
        var result = ["count=\(count)"]
        for record in records {
            let owner = record.value(forKey: "owner") as? NSManagedObject
            let ownerName = owner?.value(forKey: "name") as? String ?? "(none)"
            result.append("\(record.value(forKey: "name")!)|\(record.value(forKey: "score")!)|\(ownerName)")
        }
        return result
    }
    lines.forEach { print($0) }
} catch {
    stop("store operation failed: \(error.localizedDescription)")
}
