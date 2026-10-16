// SPDX-License-Identifier: MIT OR Apache-2.0
import Darwin
import Dispatch
import Foundation

@_silgen_name("finch_network_dns_resolve")
private func finchDNSResolve(_ name: UnsafePointer<CChar>, _ type: UnsafePointer<CChar>,
                             _ domain: UnsafePointer<CChar>, _ interfaceIndex: UInt32,
                             _ callback: DNSServiceResolveCallback, _ client: UnsafeMutableRawPointer?,
                             _ error: UnsafeMutablePointer<Int32>) -> UnsafeMutableRawPointer?
@_silgen_name("finch_network_dns_fd")
private func finchDNSFileDescriptor(_ service: UnsafeMutableRawPointer?) -> Int32
@_silgen_name("finch_network_dns_process")
private func finchDNSProcess(_ service: UnsafeMutableRawPointer?) -> Int32
@_silgen_name("finch_network_dns_cancel")
private func finchDNSCancel(_ service: UnsafeMutableRawPointer?)

private typealias DNSServiceResolveCallback = @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, Int32,
    UnsafePointer<CChar>?, UnsafePointer<CChar>?, UInt16, UInt16, UnsafePointer<UInt8>?) -> Void

private final class DNSServiceResolution {
    var host: String?
    var port: UInt16?
    var error: Int32 = 0
    var finished = false
}

private let networkServiceResolveCallback: DNSServiceResolveCallback = { context, _, _, error, _, host, port, _, _ in
    guard let context else { return }
    let resolution = Unmanaged<DNSServiceResolution>.fromOpaque(context).takeUnretainedValue()
    resolution.error = error
    resolution.host = host.map(String.init(cString:))
    resolution.port = UInt16(bigEndian: port)
    resolution.finished = true
}

struct NetworkSocketAddress {
    var storage = sockaddr_storage()
    var length: socklen_t = 0
    var family: Int32 { Int32(storage.ss_family) }
}

func networkAddresses(for endpoint: NWEndpoint, socketType: Int32, passive: Bool = false) -> [NetworkSocketAddress] {
    switch endpoint {
    case let .unix(path):
        var address = NetworkSocketAddress()
        var unix = sockaddr_un()
        unix.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: unix.sun_path) else { return [] }
        address.length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1)
        unix.sun_len = UInt8(address.length)
        withUnsafeMutableBytes(of: &unix.sun_path) { target in
            target.initializeMemory(as: UInt8.self, repeating: 0)
            target.copyBytes(from: bytes)
        }
        withUnsafeBytes(of: unix) { source in
            withUnsafeMutableBytes(of: &address.storage) { target in target.copyBytes(from: source.prefix(Int(address.length))) }
        }
        return [address]

    case let .hostPort(host, port):
        switch host {
        case let .ipv4(address):
            var socketAddress = sockaddr_in()
            socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            socketAddress.sin_family = sa_family_t(AF_INET)
            socketAddress.sin_port = port.rawValue.bigEndian
            address.rawValue.withUnsafeBytes { bytes in
                withUnsafeMutableBytes(of: &socketAddress.sin_addr) { $0.copyBytes(from: bytes) }
            }
            var result = NetworkSocketAddress()
            result.length = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeBytes(of: socketAddress) { bytes in
                withUnsafeMutableBytes(of: &result.storage) { $0.copyBytes(from: bytes) }
            }
            return [result]
        case let .ipv6(address):
            var socketAddress = sockaddr_in6()
            socketAddress.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            socketAddress.sin6_family = sa_family_t(AF_INET6)
            socketAddress.sin6_port = port.rawValue.bigEndian
            socketAddress.sin6_scope_id = UInt32(address.interface?.index ?? 0)
            address.rawValue.withUnsafeBytes { bytes in
                withUnsafeMutableBytes(of: &socketAddress.sin6_addr) { $0.copyBytes(from: bytes) }
            }
            var result = NetworkSocketAddress()
            result.length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            withUnsafeBytes(of: socketAddress) { bytes in
                withUnsafeMutableBytes(of: &result.storage) { $0.copyBytes(from: bytes) }
            }
            return [result]
        case let .name(name, _):
            return lookupAddresses(host: name, port: String(port.rawValue), socketType: socketType, passive: false)
        }

    case let .url(url):
        guard let host = url.host else { return [] }
        let port: Int
        if let explicit = url.port { port = explicit }
        else if ["https", "wss"].contains(url.scheme?.lowercased() ?? "") { port = 443 }
        else if ["http", "ws"].contains(url.scheme?.lowercased() ?? "") { port = 80 }
        else { return [] }
        return lookupAddresses(host: host, port: String(port), socketType: socketType, passive: false)

    case let .service(name, type, domain, interface):
        guard let resolved = resolveService(name: name, type: type, domain: domain,
                                            interfaceIndex: UInt32(interface?.index ?? 0)) else { return [] }
        return lookupAddresses(host: resolved.host, port: String(resolved.port), socketType: socketType, passive: false)
    }
}

func resolveService(name: String, type: String, domain: String,
                    interfaceIndex: UInt32) -> (host: String, port: UInt16)? {
    let resolution = Unmanaged.passRetained(DNSServiceResolution())
    var error: Int32 = 0
    let handle = name.withCString { namePointer in
        type.withCString { typePointer in
            domain.withCString { domainPointer in
                finchDNSResolve(namePointer, typePointer, domainPointer, interfaceIndex,
                                networkServiceResolveCallback, resolution.toOpaque(), &error)
            }
        }
    }
    guard let handle else {
        resolution.release()
        return nil
    }
    defer {
        finchDNSCancel(handle)
        resolution.release()
    }
    let fd = finchDNSFileDescriptor(handle)
    guard fd >= 0 else { return nil }
    let value = resolution.takeUnretainedValue()
    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    var remaining = 5_000
    while !value.finished && remaining > 0 {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = Darwin.poll(&descriptor, 1, Int32(remaining))
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        remaining = max(0, remaining - max(1, elapsed))
        if result < 0 {
            if errno == EINTR { continue }
            return nil
        }
        if result == 0 { break }
        if finchDNSProcess(handle) != 0 { return nil }
    }
    guard value.finished, value.error == 0, let host = value.host, let port = value.port else { return nil }
    return (host, port)
}

func networkHostName(_ host: NWEndpoint.Host) -> String {
    switch host {
    case let .name(name, _): return name
    case let .ipv4(address): return address.debugDescription
    case let .ipv6(address): return String(address.debugDescription.dropFirst().dropLast())
    }
}

private func lookupAddresses(host: String?, port: String, socketType: Int32, passive: Bool) -> [NetworkSocketAddress] {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = socketType
    hints.ai_protocol = socketType == SOCK_STREAM ? IPPROTO_TCP : IPPROTO_UDP
    hints.ai_flags = passive ? AI_PASSIVE : 0
    var result: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(host, port, &hints, &result)
    guard status == 0, let first = result else { return [] }
    defer { freeaddrinfo(result) }

    var addresses: [NetworkSocketAddress] = []
    for item in sequence(first: first, next: { $0.pointee.ai_next }) {
        guard let raw = item.pointee.ai_addr else { continue }
        var address = NetworkSocketAddress()
        address.length = socklen_t(item.pointee.ai_addrlen)
        withUnsafeMutableBytes(of: &address.storage) { target in
            target.copyBytes(from: UnsafeRawBufferPointer(start: raw, count: Int(address.length)))
        }
        addresses.append(address)
    }
    return addresses
}

func networkEndpoint(for address: sockaddr_storage) -> NWEndpoint? {
    switch Int32(address.ss_family) {
    case AF_INET:
        let value = withUnsafePointer(to: address) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee } }
        let bytes = withUnsafeBytes(of: value.sin_addr) { Data($0) }
        guard let ip = IPv4Address(bytes) else { return nil }
        return .hostPort(host: .ipv4(ip), port: NWEndpoint.Port(rawValue: UInt16(bigEndian: value.sin_port))!)
    case AF_INET6:
        let value = withUnsafePointer(to: address) { $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee } }
        let bytes = withUnsafeBytes(of: value.sin6_addr) { Data($0) }
        let interface = value.sin6_scope_id == 0 ? nil : interfaceForIndex(value.sin6_scope_id)
        guard let ip = IPv6Address(bytes, interface) else { return nil }
        return .hostPort(host: .ipv6(ip), port: NWEndpoint.Port(rawValue: UInt16(bigEndian: value.sin6_port))!)
    case AF_UNIX:
        let value = withUnsafePointer(to: address) { $0.withMemoryRebound(to: sockaddr_un.self, capacity: 1) { $0.pointee } }
        let path = withUnsafeBytes(of: value.sun_path) { bytes -> String in
            let chars = bytes.bindMemory(to: CChar.self)
            return String(cString: chars.baseAddress!)
        }
        return .unix(path: path)
    default:
        return nil
    }
}

func isOnLocalLink(_ peer: sockaddr_storage) -> Bool {
    switch Int32(peer.ss_family) {
    case AF_UNIX:
        return true
    case AF_INET:
        let remote = withUnsafePointer(to: peer) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr } }
        let host = UInt32(bigEndian: remote)
        if host >> 24 == 127 { return true }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard item.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = item.pointee.ifa_addr, Int32(address.pointee.sa_family) == AF_INET,
                  let mask = item.pointee.ifa_netmask, Int32(mask.pointee.sa_family) == AF_INET else { continue }
            let local = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let subnet = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            if remote & subnet == local & subnet { return true }
        }
        return false
    case AF_INET6:
        let remote = withUnsafePointer(to: peer) { $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee } }
        let remoteBytes = withUnsafeBytes(of: remote.sin6_addr) { Array($0) }
        if remoteBytes.dropLast().allSatisfy({ $0 == 0 }) && remoteBytes.last == 1 {
            return true
        }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard item.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = item.pointee.ifa_addr, Int32(address.pointee.sa_family) == AF_INET6,
                  let mask = item.pointee.ifa_netmask, Int32(mask.pointee.sa_family) == AF_INET6 else { continue }
            let index = if_nametoindex(item.pointee.ifa_name)
            if remote.sin6_scope_id != 0 && remote.sin6_scope_id != index { continue }
            let localValue = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            let maskValue = mask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            let local = withUnsafeBytes(of: localValue) { Array($0) }
            let subnet = withUnsafeBytes(of: maskValue) { Array($0) }
            var matches = true
            for offset in 0..<min(remoteBytes.count, min(local.count, subnet.count)) {
                if remoteBytes[offset] & subnet[offset] != local[offset] & subnet[offset] {
                    matches = false
                    break
                }
            }
            if matches && remoteBytes.count == 16 && local.count == 16 && subnet.count == 16 {
                return true
            }
        }
        return false
    default:
        return false
    }
}

func socketFamily(for endpoint: NWEndpoint) -> Int32? {
    switch endpoint {
    case let .hostPort(host, _):
        switch host {
        case .name: return nil
        case .ipv4: return AF_INET
        case .ipv6: return AF_INET6
        }
    case .unix: return AF_UNIX
    case .service, .url: return nil
    }
}

func interfaceForIndex(_ index: UInt32) -> NWInterface? {
    var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
    guard if_indextoname(index, &name) != nil else { return nil }
    let value = String(cString: name)
    return NWInterface(name: value, type: interfaceType(value))
}

func socketEndpoint(_ descriptor: Int32, peer: Bool) -> NWEndpoint? {
    var address = sockaddr_storage()
    var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let result = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            peer ? getpeername(descriptor, $0, &length) : getsockname(descriptor, $0, &length)
        }
    }
    return result == 0 ? networkEndpoint(for: address) : nil
}

func configureSocket(_ descriptor: Int32, parameters: NWParameters, reuse: Bool = false, family: Int32? = nil) {
    var one: Int32 = 1
    _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    if reuse || parameters.allowLocalEndpointReuse {
        _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
    }
    var serviceType: Int32
    switch parameters.serviceClass {
    case .bestEffort: serviceType = NET_SERVICE_TYPE_BE
    case .background: serviceType = NET_SERVICE_TYPE_BK
    case .interactiveVideo: serviceType = NET_SERVICE_TYPE_VI
    case .interactiveVoice: serviceType = NET_SERVICE_TYPE_VO
    case .responsiveData: serviceType = NET_SERVICE_TYPE_RD
    case .signaling: serviceType = NET_SERVICE_TYPE_SIG
    }
    _ = setsockopt(descriptor, SOL_SOCKET, SO_NET_SERVICE_TYPE, &serviceType, socklen_t(MemoryLayout<Int32>.size))
    guard parameters.transport == .tcp, family != AF_UNIX else { return }
    let options = parameters.tcpOptions
    var enabled = options.noDelay ? 1 : 0
    _ = setsockopt(descriptor, IPPROTO_TCP, TCP_NODELAY, &enabled, socklen_t(MemoryLayout<Int32>.size))
    enabled = options.enableKeepalive ? 1 : 0
    _ = setsockopt(descriptor, SOL_SOCKET, SO_KEEPALIVE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    if options.enableKeepalive {
        var value = Int32(options.keepaliveIdle)
        _ = setsockopt(descriptor, IPPROTO_TCP, TCP_KEEPALIVE, &value, socklen_t(MemoryLayout<Int32>.size))
        value = Int32(options.keepaliveCount)
        _ = setsockopt(descriptor, IPPROTO_TCP, TCP_KEEPCNT, &value, socklen_t(MemoryLayout<Int32>.size))
        value = Int32(options.keepaliveInterval)
        _ = setsockopt(descriptor, IPPROTO_TCP, TCP_KEEPINTVL, &value, socklen_t(MemoryLayout<Int32>.size))
    }
    if options.maximumSegmentSize > 0 {
        var value = Int32(options.maximumSegmentSize)
        _ = setsockopt(descriptor, IPPROTO_TCP, TCP_MAXSEG, &value, socklen_t(MemoryLayout<Int32>.size))
    }
    if options.noPush {
        var value: Int32 = 1
        _ = setsockopt(descriptor, IPPROTO_TCP, TCP_NOPUSH, &value, socklen_t(MemoryLayout<Int32>.size))
    }
    if options.noOptions {
        var value: Int32 = 1
        _ = setsockopt(descriptor, IPPROTO_TCP, TCP_NOOPT, &value, socklen_t(MemoryLayout<Int32>.size))
    }
    if options.connectionTimeout > 0 {
        var value = Int32(options.connectionTimeout)
        _ = setsockopt(descriptor, IPPROTO_TCP, TCP_CONNECTIONTIMEOUT, &value, socklen_t(MemoryLayout<Int32>.size))
    }
    if options.persistTimeout > 0 {
        var value = Int32(options.persistTimeout)
        _ = setsockopt(descriptor, IPPROTO_TCP, PERSIST_TIMEOUT, &value, socklen_t(MemoryLayout<Int32>.size))
    }
    if options.connectionDropTime > 0 {
        var value = Int32(options.connectionDropTime)
        _ = setsockopt(descriptor, IPPROTO_TCP, TCP_RXT_CONNDROPTIME, &value, socklen_t(MemoryLayout<Int32>.size))
    }
    if options.retransmitFinDrop {
        var value: Int32 = 1
        _ = setsockopt(descriptor, IPPROTO_TCP, TCP_RXT_FINDROP, &value, socklen_t(MemoryLayout<Int32>.size))
    }
    if options.disableAckStretching {
        var value: Int32 = 1
        _ = setsockopt(descriptor, IPPROTO_TCP, TCP_SENDMOREACKS, &value, socklen_t(MemoryLayout<Int32>.size))
    }
    if options.enableFastOpen {
        var value: Int32 = 1
        _ = setsockopt(descriptor, IPPROTO_TCP, TCP_FASTOPEN, &value, socklen_t(MemoryLayout<Int32>.size))
    }
    if options.disableECN {
        var value: Int32 = 0
        _ = setsockopt(descriptor, IPPROTO_TCP, TCP_ENABLE_ECN, &value, socklen_t(MemoryLayout<Int32>.size))
    }
}

func setSocketNonblocking(_ descriptor: Int32) {
    let flags = fcntl(descriptor, F_GETFL, 0)
    if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
}

func networkError(_ code: Int32 = errno) -> NWError {
    .posix(POSIXErrorCode(rawValue: code) ?? .EIO)
}
