// SPDX-License-Identifier: MIT OR Apache-2.0
// Entry points Apple's libswiftSystem keeps for apps built against older SDKs and
// swift-system's sources no longer have: _read(into:retryOnInterrupt:) and
// _duplicate(as:retryOnInterrupt:) as they were first declared, marked throws.
// They forward to the current, non-throwing ones.

extension FileDescriptor {
    @usableFromInline
    @_silgen_name("$s6System14FileDescriptorV5_read4into16retryOnInterrupts6ResultOySiAA5ErrnoVGSw_SbtKF")
    internal func _finchThrowingRead(into buffer: UnsafeMutableRawBufferPointer, retryOnInterrupt: Bool) throws -> Result<Int, Errno> {
        _read(into: buffer, retryOnInterrupt: retryOnInterrupt)
    }

    @available(System 0.0.2, *)
    @usableFromInline
    @_silgen_name("$s6System14FileDescriptorV10_duplicate2as16retryOnInterrupts6ResultOyAcA5ErrnoVGACSg_SbtKF")
    internal func _finchThrowingDuplicate(as target: FileDescriptor?, retryOnInterrupt: Bool) throws -> Result<FileDescriptor, Errno> {
        _duplicate(as: target, retryOnInterrupt: retryOnInterrupt)
    }
}
