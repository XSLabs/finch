// SPDX-License-Identifier: MIT OR Apache-2.0
// Async AVFoundation properties and convenience calls built on Finch's synchronous APIs.
import Foundation
import AVFoundation
import CoreMedia

public class AVAnyAsyncProperty: CustomStringConvertible, @unchecked Sendable {
    let key: String
    private let label: String

    init(key: String, label: String) {
        self.key = key
        self.label = label
    }

    public var description: String { label }
}

public class AVPartialAsyncProperty<Root>: AVAnyAsyncProperty, @unchecked Sendable {
    override public var description: String { super.description }
}

public class AVAsyncProperty<Root, Value>: AVPartialAsyncProperty<Root>, @unchecked Sendable {
    let read: (Root) -> Value

    init(key: String, label: String, read: @escaping (Root) -> Value) {
        self.read = read
        super.init(key: key, label: label)
    }

    @frozen public enum Status {
        case notYetLoaded
        case loading
        case loaded(Value)
        case failed(NSError)

        public var description: String {
            switch self {
            case .notYetLoaded: return "Not yet loaded"
            case .loading: return "Loading"
            case .loaded(let value): return "Loaded (\(value))"
            case .failed(let error): return "Failed (\(error))"
            }
        }
    }
}

private func property<Root, Value>(_ key: String, _ read: @escaping (Root) -> Value) -> AVAsyncProperty<Root, Value> {
    AVAsyncProperty(key: key, label: "\(Root.self).\(key)", read: read)
}

extension AVPartialAsyncProperty where Root: AVAsset {
    public static var duration: AVAsyncProperty<Root, CMTime> { property("duration") { $0.duration } }
    public static var preferredRate: AVAsyncProperty<Root, Float> { property("preferredRate") { $0.preferredRate } }
    public static var preferredVolume: AVAsyncProperty<Root, Float> { property("preferredVolume") { $0.preferredVolume } }
    public static var preferredTransform: AVAsyncProperty<Root, CGAffineTransform> { property("preferredTransform") { $0.preferredTransform } }
    public static var minimumTimeOffsetFromLive: AVAsyncProperty<Root, CMTime> { property("minimumTimeOffsetFromLive") { $0.minimumTimeOffsetFromLive } }
    public static var providesPreciseDurationAndTiming: AVAsyncProperty<Root, Bool> { property("providesPreciseDurationAndTiming") { $0.providesPreciseDurationAndTiming } }
    public static var tracks: AVAsyncProperty<Root, [AVAssetTrack]> { property("tracks") { $0.tracks } }
    public static var availableMediaCharacteristicsWithMediaSelectionOptions: AVAsyncProperty<Root, [AVMediaCharacteristic]> {
        property("availableMediaCharacteristicsWithMediaSelectionOptions") { $0.availableMediaCharacteristicsWithMediaSelectionOptions }
    }
    public static var metadata: AVAsyncProperty<Root, [AVMetadataItem]> { property("metadata") { $0.metadata } }
    public static var preferredMediaSelection: AVAsyncProperty<Root, AVMediaSelection> {
        property("preferredMediaSelection") { $0.preferredMediaSelection }
    }
}

extension AVPartialAsyncProperty where Root: AVURLAsset {
    public static var tracks: AVAsyncProperty<Root, [AVAssetTrack]> { property("tracks") { $0.tracks } }
    public static var variants: AVAsyncProperty<Root, [AVAssetVariant]> { property("variants") { $0.variants } }
}

public extension AVAssetVariant {
    var averageBitRate: Double? {
        guard let value = value(forKey: "averageBitRate") as? NSNumber, value.doubleValue >= 0 else { return nil }
        return value.doubleValue
    }

    var peakBitRate: Double? {
        guard let value = value(forKey: "peakBitRate") as? NSNumber, value.doubleValue >= 0 else { return nil }
        return value.doubleValue
    }
}

extension AVCapturePhotoOutput {
    @_silgen_name("$sSo20AVCapturePhotoOutputC12AVFoundationE19supportedFlashModesSaySo0aF4ModeVGvg")
    public func finchSupportedFlashModes() -> [AVCaptureDevice.FlashMode] {
        let numbers = value(forKey: "supportedFlashModes") as? [NSNumber] ?? []
        return numbers.compactMap { AVCaptureDevice.FlashMode(rawValue: $0.intValue) }
    }
}

extension AVPartialAsyncProperty where Root: AVAssetTrack {
    public static var naturalSize: AVAsyncProperty<Root, CGSize> { property("naturalSize") { $0.naturalSize } }
    public static var formatDescriptions: AVAsyncProperty<Root, [CMFormatDescription]> {
        property("formatDescriptions") { $0.formatDescriptions.map { $0 as! CMFormatDescription } }
    }
    public static var preferredTransform: AVAsyncProperty<Root, CGAffineTransform> { property("preferredTransform") { $0.preferredTransform } }
    public static var timeRange: AVAsyncProperty<Root, CMTimeRange> { property("timeRange") { $0.timeRange } }
}

extension AVPartialAsyncProperty where Root: AVMetadataItem {
    public static var stringValue: AVAsyncProperty<Root, String?> { property("stringValue") { $0.stringValue } }
    public static var dateValue: AVAsyncProperty<Root, Date?> { property("dateValue") { $0.dateValue } }
}

extension AVAsyncProperty.Status: Equatable where Value: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.notYetLoaded, .notYetLoaded), (.loading, .loading): return true
        case let (.loaded(a), .loaded(b)): return a == b
        case let (.failed(a), .failed(b)): return a == b
        default: return false
        }
    }
}

extension AVAsyncProperty.Status: Sendable where Value: Sendable {}

private func loadAsyncKeys<Root: AVAsynchronousKeyValueLoading>(_ root: Root, keys: [String]) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        root.loadValuesAsynchronously(forKeys: keys) {
            for key in keys {
                var error: NSError?
                switch root.statusOfValue(forKey: key, error: &error) {
                case .loaded:
                    continue
                case .failed:
                    continuation.resume(throwing: error ?? NSError(domain: AVFoundationErrorDomain, code: -11800))
                    return
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                    return
                default:
                    continuation.resume(throwing: error ?? NSError(domain: AVFoundationErrorDomain, code: -11800))
                    return
                }
            }
            continuation.resume()
        }
    }
}

private func loadedValue<Root: AVAsynchronousKeyValueLoading, Value>(
    _ root: Root, of property: AVAsyncProperty<Root, Value>
) throws -> Value {
    var error: NSError?
    switch root.statusOfValue(forKey: property.key, error: &error) {
    case .loaded:
        return property.read(root)
    case .failed:
        throw error ?? NSError(domain: AVFoundationErrorDomain, code: -11800)
    case .cancelled:
        throw CancellationError()
    default:
        throw error ?? NSError(domain: AVFoundationErrorDomain, code: -11800)
    }
}

public extension AVAsynchronousKeyValueLoading {
    func load<Value>(_ property: AVAsyncProperty<Self, Value>, isolation actor: isolated (any Actor)? = #isolation) async throws -> Value {
        try await loadAsyncKeys(self, keys: [property.key])
        return try loadedValue(self, of: property)
    }

    func load<A, B, each C>(_ first: AVAsyncProperty<Self, A>, _ second: AVAsyncProperty<Self, B>,
                            _ rest: repeat AVAsyncProperty<Self, each C>,
                            isolation actor: isolated (any Actor)? = #isolation) async throws -> (A, B, repeat each C) {
        var keys = [first.key, second.key]
        for property in repeat each rest { keys.append(property.key) }
        try await loadAsyncKeys(self, keys: keys)
        return (try loadedValue(self, of: first), try loadedValue(self, of: second),
                repeat try loadedValue(self, of: each rest))
    }

    func status<Value>(of property: AVAsyncProperty<Self, Value>) -> AVAsyncProperty<Self, Value>.Status {
        var error: NSError?
        switch statusOfValue(forKey: property.key, error: &error) {
        case .loaded: return .loaded(property.read(self))
        case .loading: return .loading
        case .failed: return .failed(error ?? NSError(domain: AVFoundationErrorDomain, code: -11800))
        default: return .notYetLoaded
        }
    }
}

public extension AVAssetExportSession {
    func export(to url: URL, as fileType: AVFileType, isolation actor: isolated (any Actor)? = #isolation) async throws {
        nonisolated(unsafe) let session = self
        session.outputURL = url
        session.outputFileType = fileType
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                session.exportAsynchronously {
                    if let error = session.error {
                        continuation.resume(throwing: error)
                    } else if session.status == .completed {
                        continuation.resume()
                    } else if session.status == .cancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(throwing: NSError(domain: AVFoundationErrorDomain, code: -11800))
                    }
                }
            }
        } onCancel: {
            session.cancelExport()
        }
    }
}

public extension AVAssetImageGenerator {
    func image(at time: CMTime) async throws -> (image: CGImage, actualTime: CMTime) {
        nonisolated(unsafe) let generator = self
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(CGImage, CMTime), Error>) in
                generator.generateCGImageAsynchronously(for: time) { image, actualTime, error in
                    if let image {
                        continuation.resume(returning: (image, actualTime))
                    } else {
                        continuation.resume(throwing: error ?? NSError(domain: AVFoundationErrorDomain, code: -11800))
                    }
                }
            }
        } onCancel: {
            generator.cancelAllCGImageGeneration()
        }
    }
}
