// SPDX-License-Identifier: MIT OR Apache-2.0
import Foundation

// CloudKit marks the sync engine's Objective-C declarations as refined for
// Swift. Restore the public Swift names for Finch's imported Objective-C types.
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
public typealias CKSyncEngine = __CKSyncEngine
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
public typealias CKSyncEngineConfiguration = __CKSyncEngineConfiguration
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
public typealias CKSyncEngineState = __CKSyncEngineState
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
public typealias CKSyncEngineStateSerialization = __CKSyncEngineStateSerialization
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
public typealias CKSyncEnginePendingRecordZoneChange = __CKSyncEnginePendingRecordZoneChange
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
public typealias CKSyncEnginePendingDatabaseChange = __CKSyncEnginePendingDatabaseChange
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
public typealias CKSyncEnginePendingZoneSave = __CKSyncEnginePendingZoneSave
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
public typealias CKSyncEnginePendingZoneDelete = __CKSyncEnginePendingZoneDelete
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
public typealias CKSyncEngineFetchChangesOptions = __CKSyncEngineFetchChangesOptions
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
public typealias CKSyncEngineFetchChangesContext = __CKSyncEngineFetchChangesContext
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
public typealias CKSyncEngineSendChangesOptions = __CKSyncEngineSendChangesOptions
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
public typealias CKSyncEngineSendChangesContext = __CKSyncEngineSendChangesContext

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
public extension CKSyncEngine {
    typealias Configuration = CKSyncEngineConfiguration
    typealias State = CKSyncEngineState
    typealias PendingRecordZoneChange = CKSyncEnginePendingRecordZoneChange
    typealias PendingDatabaseChange = CKSyncEnginePendingDatabaseChange
    typealias PendingZoneSave = CKSyncEnginePendingZoneSave
    typealias PendingZoneDelete = CKSyncEnginePendingZoneDelete
    typealias FetchChangesOptions = CKSyncEngineFetchChangesOptions
    typealias FetchChangesContext = CKSyncEngineFetchChangesContext
    typealias SendChangesOptions = CKSyncEngineSendChangesOptions
    typealias SendChangesContext = CKSyncEngineSendChangesContext
}

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
public extension CKSyncEngineState {
    typealias Serialization = CKSyncEngineStateSerialization
}

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
public extension CKSyncEngineStateSerialization {
    func encodedData() throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: self, requiringSecureCoding: true)
    }

    static func decode(from data: Data) throws -> Self {
        guard let value = try NSKeyedUnarchiver.unarchivedObject(ofClass: Self.self, from: data) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return value
    }
}
