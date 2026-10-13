// SPDX-License-Identifier: MIT OR Apache-2.0
// Swift System's FilePath to and from file URLs. Apple's Foundation carries
// these (first in the _System_Foundation module, since macOS 15 in Foundation,
// keeping that module's symbol names).
import System

@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
@_originallyDefinedIn(module: "_System_Foundation", macOS 15, iOS 18, tvOS 18, watchOS 11)
extension FilePath {
    /// The path of a file URL; nil for any other URL.
    @available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
    public init?(_ url: URL) {
        guard url.isFileURL else { return nil }
        guard let path = url.withUnsafeFileSystemRepresentation({ $0.map { FilePath(platformString: $0) } }) else {
            return nil
        }
        self = path
    }
}

@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
@_originallyDefinedIn(module: "_System_Foundation", macOS 15, iOS 18, tvOS 18, watchOS 11)
extension URL {
    /// A file URL for a path, nil when the path isn't valid Unicode.
    public init?(_ path: FilePath) {
        guard let s = String(validating: path) else { return nil }
        self.init(fileURLWithPath: s)
    }

    public init?(_ path: FilePath, isDirectory: Bool) {
        guard let s = String(validating: path) else { return nil }
        self.init(fileURLWithPath: s, isDirectory: isDirectory)
    }
}
