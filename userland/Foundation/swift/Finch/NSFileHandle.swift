// SPDX-License-Identifier: MIT OR Apache-2.0
// Swift's FileHandle methods use the same file descriptor as NSFileHandle.

import Darwin

@available(macOS 10.15.4, iOS 13.4, watchOS 6.2, tvOS 13.4, *)
extension FileHandle {
    public func read(upToCount count: Int) throws -> Data? {
        guard count >= 0 else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)
        }
        if count == 0 {
            return Data()
        }
        return try finchRead(fileDescriptor, maximum: count, untilEnd: false)
    }

    public func readToEnd() throws -> Data? {
        try finchRead(fileDescriptor, maximum: nil, untilEnd: true)
    }

    public func seekToEnd() throws -> UInt64 {
        let position = Darwin.lseek(fileDescriptor, 0, SEEK_END)
        guard position >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return UInt64(position)
    }

    public func write<T: DataProtocol>(contentsOf data: T) throws {
        let bytes = Data(data)
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fileDescriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                if n == 0 {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                }
                offset += n
            }
        }
    }
}

private func finchRead(_ descriptor: Int32, maximum: Int?, untilEnd: Bool) throws -> Data? {
    var result = Data()
    var firstRead = true
    while firstRead || untilEnd {
        firstRead = false
        let remaining = maximum.map { $0 - result.count } ?? 65536
        if remaining <= 0 {
            break
        }
        let size = min(remaining, 65536)
        var bytes = [UInt8](repeating: 0, count: size)
        let n = bytes.withUnsafeMutableBytes { buffer in
            Darwin.read(descriptor, buffer.baseAddress!, buffer.count)
        }
        if n < 0 {
            if errno == EINTR { continue }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        if n == 0 {
            break
        }
        result.append(contentsOf: bytes.prefix(n))
        if !untilEnd {
            break
        }
    }
    return result.isEmpty ? nil : result
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension URLCache {
    public convenience init(memoryCapacity: Int, diskCapacity: Int, directory: URL? = nil) {
        self.init(memoryCapacity: memoryCapacity, diskCapacity: diskCapacity, diskPath: directory?.path)
    }
}
