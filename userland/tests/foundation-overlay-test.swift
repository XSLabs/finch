// SPDX-License-Identifier: MIT OR Apache-2.0
import Foundation
import Darwin

@main
struct FoundationOverlayTest {
    static func main() throws {
        print("Foundation Swift overlay")
        let path = NSTemporaryDirectory() + "finch-foundation-overlay-\(getpid())"
        FileManager.default.createFile(atPath: path, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: path) }

        let handle = FileHandle(forUpdatingAtPath: path)!
        try handle.write(contentsOf: Data("finch".utf8))
        let end = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let first = try handle.read(upToCount: 2)!
        let rest = try handle.readToEnd()!
        handle.closeFile()
        print("file handle \(end) \(String(data: first, encoding: .utf8)!) \(String(data: rest, encoding: .utf8)!)")

        let cache = URLCache(memoryCapacity: 1234, diskCapacity: 5678, directory: nil)
        print("cache \(cache.memoryCapacity) \(cache.diskCapacity)")
        print("file scheme \(NSURLFileScheme)")

        let markdown = try NSAttributedString(markdown: "**bold**")
        print("markdown \(markdown.string) \(markdown.length) \(markdown.attributes(at: 0, effectiveRange: nil).count)")

        let archive = try NSKeyedArchiver.archivedData(
            withRootObject: [NSString(string: "red"), NSString(string: "blue")],
            requiringSecureCoding: true
        )
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archive)
        unarchiver.requiresSecureCoding = true
        let decoded = unarchiver.decodeArrayOfObjects(ofClass: NSString.self, forKey: NSKeyedArchiveRootObjectKey) ?? []
        unarchiver.finishDecoding()
        print("decoded \(decoded.map { $0 as String }.joined(separator: ","))")
    }
}
