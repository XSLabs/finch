// SPDX-License-Identifier: MIT OR Apache-2.0
// Swift async AVFoundation properties, image generation and export, compared with Apple.
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

@main
struct AVFoundationOverlayTest {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("avfoundation-overlay-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source.mov")
        let destination = directory.appendingPathComponent("export.mov")
        try AVFoundationOverlayTestMovie().write(to: source, options: .atomic)
        let asset = AVURLAsset(url: source)
        let durationProperty: AVAsyncProperty<AVURLAsset, CMTime> = .duration
        print("property: \(durationProperty.description)")

        let (duration, tracks, metadata) = try await asset.load(.duration, .tracks, .metadata)
        print("loaded: duration=\(duration.value)/\(duration.timescale) tracks=\(tracks.count) metadata=\(metadata.count)")
        print("status: \(asset.status(of: durationProperty))")

        let generator = AVAssetImageGenerator(asset: asset)
        let result = try await generator.image(at: CMTime(value: 0, timescale: 6))
        print("image: \(result.image.width)x\(result.image.height) actual=\(result.actualTime.value)/\(result.actualTime.timescale)")

        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw NSError(domain: "AVFoundationOverlayTest", code: 1)
        }
        try await exporter.export(to: destination, as: .mov)
        let exported = AVURLAsset(url: destination)
        let exportedDuration = try await exported.load(.duration)
        let exportedTracks = try await exported.load(.tracks)
        print("export: status=\(exporter.status.rawValue) duration=\(exportedDuration.value)/\(exportedDuration.timescale) tracks=\(exportedTracks.count)")
    }
}
