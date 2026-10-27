// SPDX-License-Identifier: MIT OR Apache-2.0
// Network's C API for QUIC, WebSocket and custom framers. Their options, metadata,
// requests, responses and messages hold and give back their settings; Finch's
// connections don't speak these protocols yet, so a connection whose stack names one
// fails with EPROTONOSUPPORT (CAPIConnection.swift).
import Darwin
import Dispatch
import Foundation

let nwQUICDefinition = NWProtocolDefinition(name: "QUIC")
let nwWebSocketDefinition = NWProtocolDefinition(name: "WebSocket")

// MARK: - QUIC

final class NWQUICOptions: NWCOnlyOptions, @unchecked Sendable {
    let tls = NWProtocolTLS.Options()
    var alpn: [String] = []
    var idleTimeout: UInt32 = 0
    var maxUDPPayloadSize: UInt16 = 0
    var maxDatagramFrameSize: UInt16 = 0
    var initialMaxData: UInt64 = 0
    var initialMaxStreamDataBidirectionalLocal: UInt64 = 0
    var initialMaxStreamDataBidirectionalRemote: UInt64 = 0
    var initialMaxStreamDataUnidirectional: UInt64 = 0
    var initialMaxStreamsBidirectional: UInt64 = 0
    var initialMaxStreamsUnidirectional: UInt64 = 0
    var streamIsUnidirectional = false
    var streamIsDatagram = false
    init() { super.init(definition: nwQUICDefinition) }
}

final class NWQUICMetadata: NWProtocolMetadata, @unchecked Sendable {
    var streamID: UInt64 = 0
    var streamType: UInt8 = 0
    var applicationError: UInt64 = 0
    var applicationErrorReason: String?
    var streamApplicationError: UInt64 = 0
    var keepaliveInterval: UInt16 = 0
    var localMaxStreamsBidirectional: UInt64 = 0
    var localMaxStreamsUnidirectional: UInt64 = 0
    var remoteMaxStreamsBidirectional: UInt64 = 0
    var remoteMaxStreamsUnidirectional: UInt64 = 0
    var remoteIdleTimeout: UInt64 = 0
    var usableDatagramFrameSize: UInt16 = 0
    let strings = NWCStrings()
    init() { super.init(definition: nwQUICDefinition) }
}

func nwQUIC(_ o: nw_protocol_options_t) -> NWQUICOptions? { nwOptions(o, NWQUICOptions.self) }
func nwQUICMeta(_ m: nw_protocol_metadata_t) -> NWQUICMetadata? { nwMetadata(m, NWQUICMetadata.self) }

@_cdecl("nw_protocol_copy_quic_definition")
public func finch_nw_protocol_copy_quic_definition() -> UnsafeMutableRawPointer? { nwRetained(NWConcreteProtocolDefinition(nwQUICDefinition)) }

@_cdecl("nw_quic_create_options")
public func finch_nw_quic_create_options() -> UnsafeMutableRawPointer? { nwRetained(NWConcreteProtocolOptions(NWQUICOptions())) }

@_cdecl("nw_protocol_options_is_quic")
public func finch_nw_protocol_options_is_quic(_ o: nw_protocol_options_t) -> Bool { nwQUIC(o) != nil }

@_cdecl("nw_protocol_metadata_is_quic")
public func finch_nw_protocol_metadata_is_quic(_ m: nw_protocol_metadata_t) -> Bool { nwMetadataIs(m, nwQUICDefinition) }

@_cdecl("nw_parameters_create_quic")
public func finch_nw_parameters_create_quic(_ configure: @convention(block) (nw_protocol_options_t) -> Void) -> UnsafeMutableRawPointer? {
    let p = NWParameters(dtls: nil)
    let quic = NWQUICOptions()
    nwApply(configure, quic)
    p.otherApplicationProtocols = [quic]
    return nwRetained(NWConcreteParameters(p))
}

@_cdecl("nw_quic_copy_sec_protocol_options")
public func finch_nw_quic_copy_sec_protocol_options(_ o: nw_protocol_options_t) -> UnsafeMutableRawPointer? {
    nwRetained(nwQUIC(o)?.tls.securityProtocolOptions as AnyObject?)
}
@_cdecl("nw_quic_copy_sec_protocol_metadata")
public func finch_nw_quic_copy_sec_protocol_metadata(_ m: nw_protocol_metadata_t) -> UnsafeMutableRawPointer? { nil }
@_cdecl("nw_quic_add_tls_application_protocol")
public func finch_nw_quic_add_tls_application_protocol(_ o: nw_protocol_options_t, _ p: UnsafePointer<CChar>) { nwQUIC(o)?.alpn.append(String(cString: p)) }

@_cdecl("nw_quic_set_idle_timeout") public func finch_nw_quic_set_idle_timeout(_ o: nw_protocol_options_t, _ v: UInt32) { nwQUIC(o)?.idleTimeout = v }
@_cdecl("nw_quic_get_idle_timeout") public func finch_nw_quic_get_idle_timeout(_ o: nw_protocol_options_t) -> UInt32 { nwQUIC(o)?.idleTimeout ?? 0 }
@_cdecl("nw_quic_set_max_udp_payload_size") public func finch_nw_quic_set_max_udp_payload_size(_ o: nw_protocol_options_t, _ v: UInt16) { nwQUIC(o)?.maxUDPPayloadSize = v }
@_cdecl("nw_quic_get_max_udp_payload_size") public func finch_nw_quic_get_max_udp_payload_size(_ o: nw_protocol_options_t) -> UInt16 { nwQUIC(o)?.maxUDPPayloadSize ?? 0 }
@_cdecl("nw_quic_set_max_datagram_frame_size") public func finch_nw_quic_set_max_datagram_frame_size(_ o: nw_protocol_options_t, _ v: UInt16) { nwQUIC(o)?.maxDatagramFrameSize = v }
@_cdecl("nw_quic_get_max_datagram_frame_size") public func finch_nw_quic_get_max_datagram_frame_size(_ o: nw_protocol_options_t) -> UInt16 { nwQUIC(o)?.maxDatagramFrameSize ?? 0 }
@_cdecl("nw_quic_set_initial_max_data") public func finch_nw_quic_set_initial_max_data(_ o: nw_protocol_options_t, _ v: UInt64) { nwQUIC(o)?.initialMaxData = v }
@_cdecl("nw_quic_get_initial_max_data") public func finch_nw_quic_get_initial_max_data(_ o: nw_protocol_options_t) -> UInt64 { nwQUIC(o)?.initialMaxData ?? 0 }
@_cdecl("nw_quic_set_initial_max_stream_data_bidirectional_local") public func finch_nw_quic_set_initial_max_stream_data_bidirectional_local(_ o: nw_protocol_options_t, _ v: UInt64) { nwQUIC(o)?.initialMaxStreamDataBidirectionalLocal = v }
@_cdecl("nw_quic_get_initial_max_stream_data_bidirectional_local") public func finch_nw_quic_get_initial_max_stream_data_bidirectional_local(_ o: nw_protocol_options_t) -> UInt64 { nwQUIC(o)?.initialMaxStreamDataBidirectionalLocal ?? 0 }
@_cdecl("nw_quic_set_initial_max_stream_data_bidirectional_remote") public func finch_nw_quic_set_initial_max_stream_data_bidirectional_remote(_ o: nw_protocol_options_t, _ v: UInt64) { nwQUIC(o)?.initialMaxStreamDataBidirectionalRemote = v }
@_cdecl("nw_quic_get_initial_max_stream_data_bidirectional_remote") public func finch_nw_quic_get_initial_max_stream_data_bidirectional_remote(_ o: nw_protocol_options_t) -> UInt64 { nwQUIC(o)?.initialMaxStreamDataBidirectionalRemote ?? 0 }
@_cdecl("nw_quic_set_initial_max_stream_data_unidirectional") public func finch_nw_quic_set_initial_max_stream_data_unidirectional(_ o: nw_protocol_options_t, _ v: UInt64) { nwQUIC(o)?.initialMaxStreamDataUnidirectional = v }
@_cdecl("nw_quic_get_initial_max_stream_data_unidirectional") public func finch_nw_quic_get_initial_max_stream_data_unidirectional(_ o: nw_protocol_options_t) -> UInt64 { nwQUIC(o)?.initialMaxStreamDataUnidirectional ?? 0 }
@_cdecl("nw_quic_set_initial_max_streams_bidirectional") public func finch_nw_quic_set_initial_max_streams_bidirectional(_ o: nw_protocol_options_t, _ v: UInt64) { nwQUIC(o)?.initialMaxStreamsBidirectional = v }
@_cdecl("nw_quic_get_initial_max_streams_bidirectional") public func finch_nw_quic_get_initial_max_streams_bidirectional(_ o: nw_protocol_options_t) -> UInt64 { nwQUIC(o)?.initialMaxStreamsBidirectional ?? 0 }
@_cdecl("nw_quic_set_initial_max_streams_unidirectional") public func finch_nw_quic_set_initial_max_streams_unidirectional(_ o: nw_protocol_options_t, _ v: UInt64) { nwQUIC(o)?.initialMaxStreamsUnidirectional = v }
@_cdecl("nw_quic_get_initial_max_streams_unidirectional") public func finch_nw_quic_get_initial_max_streams_unidirectional(_ o: nw_protocol_options_t) -> UInt64 { nwQUIC(o)?.initialMaxStreamsUnidirectional ?? 0 }
@_cdecl("nw_quic_set_stream_is_unidirectional") public func finch_nw_quic_set_stream_is_unidirectional(_ o: nw_protocol_options_t, _ v: Bool) { nwQUIC(o)?.streamIsUnidirectional = v }
@_cdecl("nw_quic_get_stream_is_unidirectional") public func finch_nw_quic_get_stream_is_unidirectional(_ o: nw_protocol_options_t) -> Bool { nwQUIC(o)?.streamIsUnidirectional ?? false }
@_cdecl("nw_quic_set_stream_is_datagram") public func finch_nw_quic_set_stream_is_datagram(_ o: nw_protocol_options_t, _ v: Bool) { nwQUIC(o)?.streamIsDatagram = v }
@_cdecl("nw_quic_get_stream_is_datagram") public func finch_nw_quic_get_stream_is_datagram(_ o: nw_protocol_options_t) -> Bool { nwQUIC(o)?.streamIsDatagram ?? false }

@_cdecl("nw_quic_get_stream_id") public func finch_nw_quic_get_stream_id(_ m: nw_protocol_metadata_t) -> UInt64 { nwQUICMeta(m)?.streamID ?? 0 }
@_cdecl("nw_quic_get_stream_type") public func finch_nw_quic_get_stream_type(_ m: nw_protocol_metadata_t) -> UInt8 { nwQUICMeta(m)?.streamType ?? 0 }
@_cdecl("nw_quic_get_stream_application_error") public func finch_nw_quic_get_stream_application_error(_ m: nw_protocol_metadata_t) -> UInt64 { nwQUICMeta(m)?.streamApplicationError ?? UInt64.max }
@_cdecl("nw_quic_set_stream_application_error") public func finch_nw_quic_set_stream_application_error(_ m: nw_protocol_metadata_t, _ v: UInt64) { nwQUICMeta(m)?.streamApplicationError = v }
@_cdecl("nw_quic_get_local_max_streams_bidirectional") public func finch_nw_quic_get_local_max_streams_bidirectional(_ m: nw_protocol_metadata_t) -> UInt64 { nwQUICMeta(m)?.localMaxStreamsBidirectional ?? 0 }
@_cdecl("nw_quic_set_local_max_streams_bidirectional") public func finch_nw_quic_set_local_max_streams_bidirectional(_ m: nw_protocol_metadata_t, _ v: UInt64) { nwQUICMeta(m)?.localMaxStreamsBidirectional = v }
@_cdecl("nw_quic_get_local_max_streams_unidirectional") public func finch_nw_quic_get_local_max_streams_unidirectional(_ m: nw_protocol_metadata_t) -> UInt64 { nwQUICMeta(m)?.localMaxStreamsUnidirectional ?? 0 }
@_cdecl("nw_quic_set_local_max_streams_unidirectional") public func finch_nw_quic_set_local_max_streams_unidirectional(_ m: nw_protocol_metadata_t, _ v: UInt64) { nwQUICMeta(m)?.localMaxStreamsUnidirectional = v }
@_cdecl("nw_quic_get_remote_max_streams_bidirectional") public func finch_nw_quic_get_remote_max_streams_bidirectional(_ m: nw_protocol_metadata_t) -> UInt64 { nwQUICMeta(m)?.remoteMaxStreamsBidirectional ?? 0 }
@_cdecl("nw_quic_get_remote_max_streams_unidirectional") public func finch_nw_quic_get_remote_max_streams_unidirectional(_ m: nw_protocol_metadata_t) -> UInt64 { nwQUICMeta(m)?.remoteMaxStreamsUnidirectional ?? 0 }
@_cdecl("nw_quic_get_remote_idle_timeout") public func finch_nw_quic_get_remote_idle_timeout(_ m: nw_protocol_metadata_t) -> UInt64 { nwQUICMeta(m)?.remoteIdleTimeout ?? 0 }
@_cdecl("nw_quic_get_keepalive_interval") public func finch_nw_quic_get_keepalive_interval(_ m: nw_protocol_metadata_t) -> UInt16 { nwQUICMeta(m)?.keepaliveInterval ?? 0 }
@_cdecl("nw_quic_set_keepalive_interval") public func finch_nw_quic_set_keepalive_interval(_ m: nw_protocol_metadata_t, _ v: UInt16) { nwQUICMeta(m)?.keepaliveInterval = v }
@_cdecl("nw_quic_get_stream_usable_datagram_frame_size") public func finch_nw_quic_get_stream_usable_datagram_frame_size(_ m: nw_protocol_metadata_t) -> UInt16 { nwQUICMeta(m)?.usableDatagramFrameSize ?? 0 }
@_cdecl("nw_quic_get_application_error") public func finch_nw_quic_get_application_error(_ m: nw_protocol_metadata_t) -> UInt64 { nwQUICMeta(m)?.applicationError ?? UInt64.max }
@_cdecl("nw_quic_get_application_error_reason")
public func finch_nw_quic_get_application_error_reason(_ m: nw_protocol_metadata_t) -> UnsafePointer<CChar>? {
    nwQUICMeta(m).flatMap { $0.strings.pointer("reason", $0.applicationErrorReason) }
}
@_cdecl("nw_quic_set_application_error")
public func finch_nw_quic_set_application_error(_ m: nw_protocol_metadata_t, _ error: UInt64, _ reason: UnsafePointer<CChar>?) {
    nwQUICMeta(m)?.applicationError = error
    nwQUICMeta(m)?.applicationErrorReason = nwString(reason)
}

// MARK: - WebSocket

final class NWWebSocketOptions: NWCOnlyOptions, @unchecked Sendable {
    let version: nw_ws_version_t
    var headers: [(String, String)] = []
    var subprotocols: [String] = []
    var autoReplyPing = false
    var maximumMessageSize = 0
    var skipHandshake = false
    var requestHandler: ((nw_ws_request_t) -> nw_ws_response_t)?
    var requestQueue: DispatchQueue?
    init(version: nw_ws_version_t) {
        self.version = version
        super.init(definition: nwWebSocketDefinition)
    }
}

final class NWWebSocketMetadata: NWProtocolMetadata, @unchecked Sendable {
    let opcode: nw_ws_opcode_t
    var closeCode = nw_ws_close_code_normal_closure
    var pongHandler: ((nw_error_t?) -> Void)?
    var pongQueue: DispatchQueue?
    var serverResponse: NWConcreteWebSocketResponse?
    init(opcode: nw_ws_opcode_t) {
        self.opcode = opcode
        super.init(definition: nwWebSocketDefinition)
    }
}

func nwWS(_ o: nw_protocol_options_t) -> NWWebSocketOptions? { nwOptions(o, NWWebSocketOptions.self) }
func nwWSMeta(_ m: nw_protocol_metadata_t) -> NWWebSocketMetadata? { nwMetadata(m, NWWebSocketMetadata.self) }

@_cdecl("nw_protocol_copy_ws_definition")
public func finch_nw_protocol_copy_ws_definition() -> UnsafeMutableRawPointer? { nwRetained(NWConcreteProtocolDefinition(nwWebSocketDefinition)) }
@_cdecl("nw_protocol_metadata_is_ws")
public func finch_nw_protocol_metadata_is_ws(_ m: nw_protocol_metadata_t) -> Bool { nwMetadataIs(m, nwWebSocketDefinition) }
@_cdecl("nw_ws_create_options")
public func finch_nw_ws_create_options(_ version: nw_ws_version_t) -> UnsafeMutableRawPointer? { nwRetained(NWConcreteProtocolOptions(NWWebSocketOptions(version: version))) }
@_cdecl("nw_ws_options_add_additional_header")
public func finch_nw_ws_options_add_additional_header(_ o: nw_protocol_options_t, _ name: UnsafePointer<CChar>, _ value: UnsafePointer<CChar>) {
    nwWS(o)?.headers.append((String(cString: name), String(cString: value)))
}
@_cdecl("nw_ws_options_add_subprotocol")
public func finch_nw_ws_options_add_subprotocol(_ o: nw_protocol_options_t, _ p: UnsafePointer<CChar>) { nwWS(o)?.subprotocols.append(String(cString: p)) }
@_cdecl("nw_ws_options_set_auto_reply_ping")
public func finch_nw_ws_options_set_auto_reply_ping(_ o: nw_protocol_options_t, _ v: Bool) { nwWS(o)?.autoReplyPing = v }
@_cdecl("nw_ws_options_set_maximum_message_size")
public func finch_nw_ws_options_set_maximum_message_size(_ o: nw_protocol_options_t, _ v: Int) { nwWS(o)?.maximumMessageSize = v }
@_cdecl("nw_ws_options_set_skip_handshake")
public func finch_nw_ws_options_set_skip_handshake(_ o: nw_protocol_options_t, _ v: Bool) { nwWS(o)?.skipHandshake = v }
@_cdecl("nw_ws_options_set_client_request_handler")
public func finch_nw_ws_options_set_client_request_handler(_ o: nw_protocol_options_t, _ q: DispatchQueue,
                                                          _ h: @escaping @convention(block) (nw_ws_request_t) -> nw_ws_response_t) {
    nwWS(o)?.requestQueue = q
    nwWS(o)?.requestHandler = { h($0) }
}

@_cdecl("nw_ws_create_metadata")
public func finch_nw_ws_create_metadata(_ opcode: nw_ws_opcode_t) -> UnsafeMutableRawPointer? {
    nwRetained(NWConcreteProtocolMetadata(NWWebSocketMetadata(opcode: opcode)))
}
@_cdecl("nw_ws_metadata_get_opcode")
public func finch_nw_ws_metadata_get_opcode(_ m: nw_protocol_metadata_t) -> nw_ws_opcode_t { nwWSMeta(m)?.opcode ?? nw_ws_opcode_invalid }
@_cdecl("nw_ws_metadata_set_close_code")
public func finch_nw_ws_metadata_set_close_code(_ m: nw_protocol_metadata_t, _ v: nw_ws_close_code_t) { nwWSMeta(m)?.closeCode = v }
@_cdecl("nw_ws_metadata_get_close_code")
public func finch_nw_ws_metadata_get_close_code(_ m: nw_protocol_metadata_t) -> nw_ws_close_code_t { nwWSMeta(m)?.closeCode ?? nw_ws_close_code_normal_closure }
@_cdecl("nw_ws_metadata_set_pong_handler")
public func finch_nw_ws_metadata_set_pong_handler(_ m: nw_protocol_metadata_t, _ q: DispatchQueue, _ h: @escaping @convention(block) (nw_error_t?) -> Void) {
    nwWSMeta(m)?.pongQueue = q
    nwWSMeta(m)?.pongHandler = { h($0) }
}
@_cdecl("nw_ws_metadata_copy_server_response")
public func finch_nw_ws_metadata_copy_server_response(_ m: nw_protocol_metadata_t) -> UnsafeMutableRawPointer? { nwRetained(nwWSMeta(m)?.serverResponse) }

@objc(NWConcrete_nw_ws_request)
final class NWConcreteWebSocketRequest: NSObject, OS_nw_ws_request {
    var subprotocols: [String] = []
    var headers: [(String, String)] = []
}

@objc(NWConcrete_nw_ws_response)
final class NWConcreteWebSocketResponse: NSObject, OS_nw_ws_response {
    let status: nw_ws_response_status_t
    let subprotocol: String?
    var headers: [(String, String)] = []
    let strings = NWCStrings()
    init(status: nw_ws_response_status_t, subprotocol: String?) {
        self.status = status
        self.subprotocol = subprotocol
        super.init()
    }
}

@_cdecl("nw_ws_request_enumerate_subprotocols")
public func finch_nw_ws_request_enumerate_subprotocols(_ r: nw_ws_request_t, _ block: @convention(block) (UnsafePointer<CChar>) -> Bool) -> Bool {
    let list = (r as AnyObject as? NWConcreteWebSocketRequest)?.subprotocols ?? []
    for p in list where !p.withCString({ block($0) }) { return false }
    return !list.isEmpty
}
@_cdecl("nw_ws_request_enumerate_additional_headers")
public func finch_nw_ws_request_enumerate_additional_headers(_ r: nw_ws_request_t,
                                                            _ block: @convention(block) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Bool) -> Bool {
    let list = (r as AnyObject as? NWConcreteWebSocketRequest)?.headers ?? []
    for (n, v) in list where !n.withCString({ np in v.withCString { block(np, $0) } }) { return false }
    return !list.isEmpty
}
@_cdecl("nw_ws_response_create")
public func finch_nw_ws_response_create(_ status: nw_ws_response_status_t, _ subprotocol: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    nwRetained(NWConcreteWebSocketResponse(status: status, subprotocol: nwString(subprotocol)))
}
@_cdecl("nw_ws_response_get_status")
public func finch_nw_ws_response_get_status(_ r: nw_ws_response_t) -> nw_ws_response_status_t {
    (r as AnyObject as? NWConcreteWebSocketResponse)?.status ?? nw_ws_response_status_invalid
}
@_cdecl("nw_ws_response_get_selected_subprotocol")
public func finch_nw_ws_response_get_selected_subprotocol(_ r: nw_ws_response_t) -> UnsafePointer<CChar>? {
    (r as AnyObject as? NWConcreteWebSocketResponse).flatMap { $0.strings.pointer("subprotocol", $0.subprotocol) }
}
@_cdecl("nw_ws_response_add_additional_header")
public func finch_nw_ws_response_add_additional_header(_ r: nw_ws_response_t, _ name: UnsafePointer<CChar>, _ value: UnsafePointer<CChar>) {
    (r as AnyObject as? NWConcreteWebSocketResponse)?.headers.append((String(cString: name), String(cString: value)))
}
@_cdecl("nw_ws_response_enumerate_additional_headers")
public func finch_nw_ws_response_enumerate_additional_headers(_ r: nw_ws_response_t,
                                                             _ block: @convention(block) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Bool) -> Bool {
    let list = (r as AnyObject as? NWConcreteWebSocketResponse)?.headers ?? []
    for (n, v) in list where !n.withCString({ np in v.withCString { block(np, $0) } }) { return false }
    return !list.isEmpty
}

// MARK: - Framers

final class NWFramerDefinition: NWProtocolDefinition, @unchecked Sendable {
    let flags: UInt32
    let start: (nw_framer_t) -> nw_framer_start_result_t
    init(identifier: String, flags: UInt32, start: @escaping (nw_framer_t) -> nw_framer_start_result_t) {
        self.flags = flags
        self.start = start
        super.init(name: identifier)
    }
}

final class NWFramerOptions: NWCOnlyOptions, @unchecked Sendable {
    var values: [String: AnyObject] = [:]
}

/* A framer message: metadata carrying the framer's values (objects and raw values). */
final class NWFramerMessage: NWProtocolMetadata, @unchecked Sendable {
    var objects: [String: AnyObject] = [:]
    var values: [String: (UnsafeMutableRawPointer?, ((UnsafeMutableRawPointer?) -> Void)?)] = [:]
    deinit { values.values.forEach { $0.1?($0.0) } }
}

@objc(NWConcrete_nw_framer)
final class NWConcreteFramer: NSObject, OS_nw_framer {
    let definition: NWFramerDefinition
    let options: NWFramerOptions
    var inputHandler: ((nw_framer_t) -> Int)?
    var outputHandler: ((nw_framer_t, nw_framer_message_t, Int, Bool) -> Void)?
    var wakeupHandler: ((nw_framer_t) -> Void)?
    var stopHandler: ((nw_framer_t) -> Bool)?
    var cleanupHandler: ((nw_framer_t) -> Void)?
    init(definition: NWFramerDefinition, options: NWFramerOptions) {
        self.definition = definition
        self.options = options
        super.init()
    }
}

func nwFramer(_ f: nw_framer_t) -> NWConcreteFramer? { f as AnyObject as? NWConcreteFramer }
func nwFramerMessage(_ m: nw_framer_message_t) -> NWFramerMessage? { nwMetadata(m, NWFramerMessage.self) }

@_cdecl("nw_framer_create_definition")
public func finch_nw_framer_create_definition(_ identifier: UnsafePointer<CChar>, _ flags: UInt32,
                                              _ start: @escaping @convention(block) (nw_framer_t) -> nw_framer_start_result_t) -> UnsafeMutableRawPointer? {
    nwRetained(NWConcreteProtocolDefinition(NWFramerDefinition(identifier: String(cString: identifier), flags: flags, start: { start($0) })))
}

@_cdecl("nw_framer_create_options")
public func finch_nw_framer_create_options(_ d: nw_protocol_definition_t) -> UnsafeMutableRawPointer? {
    guard let definition = (d as AnyObject as? NWConcreteProtocolDefinition)?.definition as? NWFramerDefinition else { return nil }
    return nwRetained(NWConcreteProtocolOptions(NWFramerOptions(definition: definition)))
}

@_cdecl("nw_framer_options_set_object_value")
public func finch_nw_framer_options_set_object_value(_ o: nw_protocol_options_t, _ key: UnsafePointer<CChar>, _ value: AnyObject?) {
    nwOptions(o, NWFramerOptions.self)?.values[String(cString: key)] = value
}
@_cdecl("nw_framer_options_copy_object_value")
public func finch_nw_framer_options_copy_object_value(_ o: nw_protocol_options_t, _ key: UnsafePointer<CChar>) -> UnsafeMutableRawPointer? {
    nwRetained(nwOptions(o, NWFramerOptions.self)?.values[String(cString: key)])
}

@_cdecl("nw_framer_protocol_create_message")
public func finch_nw_framer_protocol_create_message(_ d: nw_protocol_definition_t) -> UnsafeMutableRawPointer? {
    guard let definition = (d as AnyObject as? NWConcreteProtocolDefinition)?.definition else { return nil }
    return nwRetained(NWConcreteProtocolMetadata(NWFramerMessage(definition: definition)))
}
@_cdecl("nw_framer_message_create")
public func finch_nw_framer_message_create(_ f: nw_framer_t) -> UnsafeMutableRawPointer? {
    guard let framer = nwFramer(f) else { return nil }
    return nwRetained(NWConcreteProtocolMetadata(NWFramerMessage(definition: framer.definition)))
}
@_cdecl("nw_protocol_metadata_is_framer_message")
public func finch_nw_protocol_metadata_is_framer_message(_ m: nw_protocol_metadata_t) -> Bool { nwFramerMessage(m) != nil }
@_cdecl("nw_framer_message_set_value")
public func finch_nw_framer_message_set_value(_ m: nw_framer_message_t, _ key: UnsafePointer<CChar>, _ value: UnsafeMutableRawPointer?,
                                              _ dispose: (@convention(block) (UnsafeMutableRawPointer?) -> Void)?) {
    guard let message = nwFramerMessage(m) else { return }
    let k = String(cString: key)
    if let old = message.values[k] { old.1?(old.0) }
    message.values[k] = (value, dispose.map { d in { d($0) } })
}
@_cdecl("nw_framer_message_access_value")
public func finch_nw_framer_message_access_value(_ m: nw_framer_message_t, _ key: UnsafePointer<CChar>,
                                                 _ access: @convention(block) (UnsafeRawPointer?) -> Bool) -> Bool {
    access(nwFramerMessage(m)?.values[String(cString: key)]?.0)
}
@_cdecl("nw_framer_message_set_object_value")
public func finch_nw_framer_message_set_object_value(_ m: nw_framer_message_t, _ key: UnsafePointer<CChar>, _ value: AnyObject?) {
    nwFramerMessage(m)?.objects[String(cString: key)] = value
}
@_cdecl("nw_framer_message_copy_object_value")
public func finch_nw_framer_message_copy_object_value(_ m: nw_framer_message_t, _ key: UnsafePointer<CChar>) -> UnsafeMutableRawPointer? {
    nwRetained(nwFramerMessage(m)?.objects[String(cString: key)])
}

/* A framer's runtime calls: Finch's connections don't run framers yet (a stack naming one
   fails), so these only keep what they're given. */
@_cdecl("nw_framer_set_input_handler")
public func finch_nw_framer_set_input_handler(_ f: nw_framer_t, _ h: @escaping @convention(block) (nw_framer_t) -> Int) { nwFramer(f)?.inputHandler = { h($0) } }
@_cdecl("nw_framer_set_output_handler")
public func finch_nw_framer_set_output_handler(_ f: nw_framer_t, _ h: @escaping @convention(block) (nw_framer_t, nw_framer_message_t, Int, Bool) -> Void) {
    nwFramer(f)?.outputHandler = { h($0, $1, $2, $3) }
}
@_cdecl("nw_framer_set_wakeup_handler")
public func finch_nw_framer_set_wakeup_handler(_ f: nw_framer_t, _ h: @escaping @convention(block) (nw_framer_t) -> Void) { nwFramer(f)?.wakeupHandler = { h($0) } }
@_cdecl("nw_framer_set_stop_handler")
public func finch_nw_framer_set_stop_handler(_ f: nw_framer_t, _ h: @escaping @convention(block) (nw_framer_t) -> Bool) { nwFramer(f)?.stopHandler = { h($0) } }
@_cdecl("nw_framer_set_cleanup_handler")
public func finch_nw_framer_set_cleanup_handler(_ f: nw_framer_t, _ h: @escaping @convention(block) (nw_framer_t) -> Void) { nwFramer(f)?.cleanupHandler = { h($0) } }
@_cdecl("nw_framer_mark_ready")
public func finch_nw_framer_mark_ready(_ f: nw_framer_t) {}
@_cdecl("nw_framer_mark_failed_with_error")
public func finch_nw_framer_mark_failed_with_error(_ f: nw_framer_t, _ error: Int32) {}
@_cdecl("nw_framer_prepend_application_protocol")
public func finch_nw_framer_prepend_application_protocol(_ f: nw_framer_t, _ o: nw_protocol_options_t) -> Bool { false }
@_cdecl("nw_framer_parse_input")
public func finch_nw_framer_parse_input(_ f: nw_framer_t, _ minimum: Int, _ maximum: Int, _ buffer: UnsafeMutablePointer<UInt8>?,
                                        _ parse: @convention(block) (UnsafeMutablePointer<UInt8>?, Int, Bool) -> Int) -> Bool { false }
@_cdecl("nw_framer_parse_output")
public func finch_nw_framer_parse_output(_ f: nw_framer_t, _ minimum: Int, _ maximum: Int, _ buffer: UnsafeMutablePointer<UInt8>?,
                                         _ parse: @convention(block) (UnsafeMutablePointer<UInt8>?, Int, Bool) -> Int) -> Bool { false }
@_cdecl("nw_framer_deliver_input")
public func finch_nw_framer_deliver_input(_ f: nw_framer_t, _ buffer: UnsafePointer<UInt8>, _ length: Int, _ m: nw_framer_message_t, _ complete: Bool) {}
@_cdecl("nw_framer_deliver_input_no_copy")
public func finch_nw_framer_deliver_input_no_copy(_ f: nw_framer_t, _ length: Int, _ m: nw_framer_message_t, _ complete: Bool) -> Bool { false }
@_cdecl("nw_framer_pass_through_input")
public func finch_nw_framer_pass_through_input(_ f: nw_framer_t) {}
@_cdecl("nw_framer_pass_through_output")
public func finch_nw_framer_pass_through_output(_ f: nw_framer_t) {}
@_cdecl("nw_framer_write_output")
public func finch_nw_framer_write_output(_ f: nw_framer_t, _ buffer: UnsafePointer<UInt8>, _ length: Int) {}
@_cdecl("nw_framer_write_output_data")
public func finch_nw_framer_write_output_data(_ f: nw_framer_t, _ data: __DispatchData) {}
@_cdecl("nw_framer_write_output_no_copy")
public func finch_nw_framer_write_output_no_copy(_ f: nw_framer_t, _ length: Int) -> Bool { false }
@_cdecl("nw_framer_schedule_wakeup")
public func finch_nw_framer_schedule_wakeup(_ f: nw_framer_t, _ milliseconds: UInt64) {}
@_cdecl("nw_framer_async")
public func finch_nw_framer_async(_ f: nw_framer_t, _ block: @escaping @convention(block) () -> Void) { DispatchQueue.global().async { block() } }
@_cdecl("nw_framer_copy_remote_endpoint")
public func finch_nw_framer_copy_remote_endpoint(_ f: nw_framer_t) -> UnsafeMutableRawPointer? { nil }
@_cdecl("nw_framer_copy_local_endpoint")
public func finch_nw_framer_copy_local_endpoint(_ f: nw_framer_t) -> UnsafeMutableRawPointer? { nil }
@_cdecl("nw_framer_copy_parameters")
public func finch_nw_framer_copy_parameters(_ f: nw_framer_t) -> UnsafeMutableRawPointer? { nil }
@_cdecl("nw_framer_copy_options")
public func finch_nw_framer_copy_options(_ f: nw_framer_t) -> UnsafeMutableRawPointer? {
    nwRetained(nwFramer(f).map { NWConcreteProtocolOptions($0.options) })
}
