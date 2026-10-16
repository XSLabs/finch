// SPDX-License-Identifier: MIT OR Apache-2.0
import Combine
import Foundation
import ObjectiveC

@_silgen_name("CDPerformBlock")
private func _finchPerformBlock(_ context: NSManagedObjectContext, _ block: @convention(block) () -> Void)

@_silgen_name("CDPerformBlockAndWait")
private func _finchPerformBlockAndWait(_ context: NSManagedObjectContext, _ block: @convention(block) () -> Void)

@_silgen_name("CDCountForFetchRequest")
private func _finchCountForFetchRequest(
    _ context: NSManagedObjectContext,
    _ request: NSFetchRequest<any NSFetchRequestResult>,
    _ result: UnsafeMutablePointer<UInt>
) -> Unmanaged<NSError>?

@_silgen_name("CDFetchForFetchRequest")
private func _finchFetchForFetchRequest(
    _ context: NSManagedObjectContext,
    _ request: NSFetchRequest<any NSFetchRequestResult>,
    _ result: UnsafeMutablePointer<Unmanaged<NSArray>?>
) -> Unmanaged<NSError>?

@_silgen_name("CDReplacePersistentStore")
private func _finchReplacePersistentStore(
    _ coordinator: NSPersistentStoreCoordinator,
    _ destinationURL: NSURL,
    _ destinationOptions: NSDictionary?,
    _ sourceURL: NSURL,
    _ sourceOptions: NSDictionary?,
    _ storeType: NSString
) -> Unmanaged<NSError>?

@_silgen_name("CDAddPersistentStore")
private func _finchAddPersistentStore(
    _ coordinator: NSPersistentStoreCoordinator,
    _ type: NSString,
    _ configuration: NSString?,
    _ url: NSURL,
    _ options: NSDictionary?,
    _ result: UnsafeMutablePointer<Unmanaged<NSPersistentStore>?>
) -> Unmanaged<NSError>?

@_silgen_name("CDDestroyPersistentStore")
private func _finchDestroyPersistentStore(
    _ coordinator: NSPersistentStoreCoordinator,
    _ url: NSURL,
    _ type: NSString,
    _ options: NSDictionary?
) -> Unmanaged<NSError>?

@_silgen_name("CDGetDidMigrateHandler")
private func _finchGetDidMigrateHandler(
    _ stage: NSCustomMigrationStage
) -> (@convention(block) (NSStagedMigrationManager, NSCustomMigrationStage, UnsafeMutablePointer<NSError?>?) -> Bool)?

@_silgen_name("CDSetDidMigrateHandler")
private func _finchSetDidMigrateHandler(
    _ stage: NSCustomMigrationStage,
    _ handler: (@convention(block) (NSStagedMigrationManager, NSCustomMigrationStage, UnsafeMutablePointer<NSError?>?) -> Bool)?
)

@_silgen_name("CDGetWillMigrateHandler")
private func _finchGetWillMigrateHandler(
    _ stage: NSCustomMigrationStage
) -> (@convention(block) (NSStagedMigrationManager, NSCustomMigrationStage, UnsafeMutablePointer<NSError?>?) -> Bool)?

@_silgen_name("CDSetWillMigrateHandler")
private func _finchSetWillMigrateHandler(
    _ stage: NSCustomMigrationStage,
    _ handler: (@convention(block) (NSStagedMigrationManager, NSCustomMigrationStage, UnsafeMutablePointer<NSError?>?) -> Bool)?
)

@available(macOS 12.0, *)
extension NSPersistentStore {
    @frozen public struct StoreType: RawRepresentable, Hashable {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }
}

@available(macOS 12.0, *)
extension NSPersistentStore.StoreType {
    public static let sqlite = Self(rawValue: "SQLite")
    public static let binary = Self(rawValue: "Binary")
    public static let inMemory = Self(rawValue: "InMemory")
    public static let xml = Self(rawValue: "XML")
}

@available(macOS 12.0, *)
extension NSPersistentStoreCoordinator {
    public func addPersistentStore(
        type: NSPersistentStore.StoreType,
        configuration: String? = nil,
        at storeURL: URL,
        options: [AnyHashable: Any]? = nil
    ) throws -> NSPersistentStore {
        var store: Unmanaged<NSPersistentStore>?
        if let error = _finchAddPersistentStore(
            self,
            type.rawValue as NSString,
            configuration as NSString?,
            storeURL as NSURL,
            options as NSDictionary?,
            &store
        ) { throw error.takeRetainedValue() }
        return store!.takeRetainedValue()
    }

    public func destroyPersistentStore(
        at url: URL,
        type storeType: NSPersistentStore.StoreType,
        options: [AnyHashable: Any]? = nil
    ) throws {
        if let error = _finchDestroyPersistentStore(
            self,
            url as NSURL,
            storeType.rawValue as NSString,
            options as NSDictionary?
        ) { throw error.takeRetainedValue() }
    }

    public func replacePersistentStore(
        at destinationURL: URL,
        destinationOptions: [AnyHashable: Any]? = nil,
        withPersistentStoreFrom sourceURL: URL,
        sourceOptions: [AnyHashable: Any]? = nil,
        type sourceType: NSPersistentStore.StoreType
    ) throws {
        if let error = _finchReplacePersistentStore(
            self,
            destinationURL as NSURL,
            destinationOptions as NSDictionary?,
            sourceURL as NSURL,
            sourceOptions as NSDictionary?,
            sourceType.rawValue as NSString
        ) { throw error.takeRetainedValue() }
    }
}

extension CocoaError.Code {
    public static let validationMissingMandatoryProperty = Self(rawValue: 1570)
}

@available(macOS 12.0, *)
extension NSManagedObjectContext {
    @frozen public enum ScheduledTaskType: Hashable {
        case immediate
        case enqueued
    }

    public static let didSaveObjectsNotification = Notification.Name(
        rawValue: "NSManagingContextDidSaveChangesNotification"
    )
    public static let didChangeObjectsNotification = Notification.Name(
        rawValue: "NSObjectsChangedInManagingContextNotification"
    )
    public static let didMergeChangesObjectIDsNotification = Notification.Name(
        rawValue: "NSManagedObjectContextDidMergeChangesObjectIDsNotification"
    )

    public func fetch<ResultType: NSFetchRequestResult>(
        _ request: NSFetchRequest<ResultType>
    ) throws -> [ResultType] {
        var values: Unmanaged<NSArray>?
        if let error = _finchFetchForFetchRequest(self, request as! NSFetchRequest<any NSFetchRequestResult>, &values) {
            throw error.takeRetainedValue()
        }
        return values!.takeRetainedValue() as! [ResultType]
    }

    public func count<ResultType: NSFetchRequestResult>(
        for request: NSFetchRequest<ResultType>
    ) throws -> Int {
        var value: UInt = 0
        if let error = _finchCountForFetchRequest(self, request as! NSFetchRequest<any NSFetchRequestResult>, &value) {
            throw error.takeRetainedValue()
        }
        return Int(value)
    }

    public func performAndWait<ResultType>(_ block: () throws -> ResultType) throws -> ResultType {
        var result: Result<ResultType, Error>!
        _finchPerformBlockAndWait(self) { result = Result { try block() } }
        return try result.get()
    }

    public func perform<ResultType>(
        schedule: ScheduledTaskType = .immediate,
        _ block: @escaping () throws -> ResultType
    ) async throws -> ResultType {
        return try await withCheckedThrowingContinuation { continuation in
            let work = { continuation.resume(with: Result { try block() }) }
            if schedule == .immediate {
                _finchPerformBlockAndWait(self, work)
            } else {
                _finchPerformBlock(self, work)
            }
        }
    }
}

@available(macOS 14.0, *)
extension NSCustomMigrationStage {
    public convenience init(
        migratingFrom currentModel: NSManagedObjectModelReference,
        to nextModel: NSManagedObjectModelReference
    ) {
        self.init(__currentModelReference: currentModel, nextModelReference: nextModel)
    }

    public var willMigrateHandler: ((NSStagedMigrationManager, NSCustomMigrationStage) throws -> Void)? {
        get {
            guard let handler = _finchGetWillMigrateHandler(self) else { return nil }
            return { manager, stage in
                var error: NSError?
                if !handler(manager, stage, &error) {
                    throw error ?? NSError(domain: "NSCocoaErrorDomain", code: 134110)
                }
            }
        }
        set {
            guard let newValue else {
                _finchSetWillMigrateHandler(self, nil)
                return
            }
            let handler: @convention(block) (
                NSStagedMigrationManager,
                NSCustomMigrationStage,
                UnsafeMutablePointer<NSError?>?
            ) -> Bool = { manager, stage, error in
                do {
                    try newValue(manager, stage)
                    return true
                } catch let caughtError {
                    error?.pointee = caughtError as NSError
                    return false
                }
            }
            _finchSetWillMigrateHandler(self, handler)
        }
    }

    public var didMigrateHandler: ((NSStagedMigrationManager, NSCustomMigrationStage) throws -> Void)? {
        get {
            guard let handler = _finchGetDidMigrateHandler(self) else { return nil }
            return { manager, stage in
                var error: NSError?
                if !handler(manager, stage, &error) {
                    throw error ?? NSError(domain: "NSCocoaErrorDomain", code: 134110)
                }
            }
        }
        set {
            guard let newValue else {
                _finchSetDidMigrateHandler(self, nil)
                return
            }
            let handler: @convention(block) (
                NSStagedMigrationManager,
                NSCustomMigrationStage,
                UnsafeMutablePointer<NSError?>?
            ) -> Bool = { manager, stage, error in
                do {
                    try newValue(manager, stage)
                    return true
                } catch let caughtError {
                    error?.pointee = caughtError as NSError
                    return false
                }
            }
            _finchSetDidMigrateHandler(self, handler)
        }
    }
}

@available(macOS 14.0, *)
extension NSStagedMigrationManager {
    public convenience init(_ stages: [NSMigrationStage]) {
        self.init(__migrationStages: stages)
    }
}

@available(macOS 12.0, *)
@_cdecl("$sSo22NSManagedObjectContextC8CoreDataE17ScheduledTaskTypeO9immediateyA2EmFWC")
public func _finchImmediateScheduledTaskType() -> UInt8 { 0 }

@available(macOS 12.0, *)
@_cdecl("$sSo22NSManagedObjectContextC8CoreDataE17ScheduledTaskTypeO8enqueuedyA2EmFWC")
public func _finchEnqueuedScheduledTaskType() -> UInt8 { 1 }

private var objectWillChangeKey: UInt8 = 0

@available(macOS 10.15, *)
extension NSManagedObject: ObservableObject {
    public var objectWillChange: ObservableObjectPublisher {
        if let publisher = objc_getAssociatedObject(self, &objectWillChangeKey) as? ObservableObjectPublisher {
            return publisher
        }
        let publisher = ObservableObjectPublisher()
        objc_setAssociatedObject(self, &objectWillChangeKey, publisher, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return publisher
    }

    @objc(_finchNotifyObjectWillChange)
    public func _finchNotifyObjectWillChange() {
        objectWillChange.send()
    }
}

@available(macOS 12.0, *)
extension NSCoreDataCoreSpotlightDelegate {
    public static let indexDidUpdateNotification = Notification.Name(
        "NSCoreDataCoreSpotlightDelegateIndexDidUpdateNotification"
    )
}
