// SPDX-License-Identifier: MIT OR Apache-2.0
// Network's C API: connections, their establishment and data-transfer reports, and
// listeners, over Finch's NWConnection and NWListener.
import Darwin
import Dispatch
import Foundation

func nwData(_ content: __DispatchData?) -> Data? { content.map { Data($0 as DispatchData) } }

func nwDispatchData(_ data: Data?) -> __DispatchData? {
    data.map { d in d.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData }
}

@_silgen_name("finch_nw_send_is_idempotent")
func nwSendIsIdempotent(_ block: AnyObject) -> Bool

/* A protocol Finch's connections can't speak yet, if the parameters ask for one. */
func nwUnsupportedProtocol(_ parameters: NWParameters) -> Bool {
    parameters.otherApplicationProtocols.contains { $0 is NWCOnlyOptions }
}

// MARK: - Connections

@objc(NWConcrete_nw_connection)
final class NWConcreteConnection: NSObject, OS_nw_connection {
    let connection: NWConnection
    let endpointObject: NWConcreteEndpoint
    let parametersObject: NWConcreteParameters
    var queue: DispatchQueue?
    var stateHandler: ((nw_connection_state_t, nw_error_t?) -> Void)?
    var failedEarly = false

    init(_ connection: NWConnection) {
        self.connection = connection
        endpointObject = NWConcreteEndpoint(connection.endpoint)
        parametersObject = NWConcreteParameters(connection.parameters)
        super.init()
    }

    override var description: String { connection.debugDescription }
}

func nwConnection(_ object: nw_connection_t?) -> NWConcreteConnection? { object as AnyObject? as? NWConcreteConnection }

func nwConnectionState(_ state: NWConnection.State) -> (nw_connection_state_t, NWConcreteError?) {
    switch state {
    case .setup: return (nw_connection_state_invalid, nil)
    case let .waiting(error): return (nw_connection_state_waiting, NWConcreteError(error))
    case .preparing: return (nw_connection_state_preparing, nil)
    case .ready: return (nw_connection_state_ready, nil)
    case let .failed(error): return (nw_connection_state_failed, NWConcreteError(error))
    case .cancelled: return (nw_connection_state_cancelled, nil)
    }
}

@_cdecl("nw_connection_create")
public func finch_nw_connection_create(_ endpoint: nw_endpoint_t, _ parameters: nw_parameters_t) -> UnsafeMutableRawPointer? {
    guard let e = nwEndpoint(endpoint), let p = nwParameters(parameters) else { return nil }
    return nwRetained(NWConcreteConnection(NWConnection(to: e, using: p.copy())))
}

@_cdecl("nw_connection_copy_endpoint")
public func finch_nw_connection_copy_endpoint(_ c: nw_connection_t) -> UnsafeMutableRawPointer? { nwRetained(nwConnection(c)?.endpointObject) }

@_cdecl("nw_connection_copy_parameters")
public func finch_nw_connection_copy_parameters(_ c: nw_connection_t) -> UnsafeMutableRawPointer? { nwRetained(nwConnection(c)?.parametersObject) }

@_cdecl("nw_connection_set_queue")
public func finch_nw_connection_set_queue(_ c: nw_connection_t, _ queue: DispatchQueue) { nwConnection(c)?.queue = queue }

@_cdecl("nw_connection_set_state_changed_handler")
public func finch_nw_connection_set_state_changed_handler(_ c: nw_connection_t,
                                                         _ handler: (@convention(block) (nw_connection_state_t, nw_error_t?) -> Void)?) {
    guard let connection = nwConnection(c) else { return }
    guard let handler else {
        connection.stateHandler = nil
        connection.connection.stateUpdateHandler = nil
        return
    }
    connection.stateHandler = { handler($0, $1) }
    connection.connection.stateUpdateHandler = { state in
        let (s, error) = nwConnectionState(state)
        guard s != nw_connection_state_invalid else { return }
        handler(s, error)
    }
}

@_cdecl("nw_connection_set_viability_changed_handler")
public func finch_nw_connection_set_viability_changed_handler(_ c: nw_connection_t, _ handler: (@convention(block) (Bool) -> Void)?) {
    nwConnection(c)?.connection.viabilityUpdateHandler = handler.map { h in { h($0) } }
}

@_cdecl("nw_connection_set_better_path_available_handler")
public func finch_nw_connection_set_better_path_available_handler(_ c: nw_connection_t, _ handler: (@convention(block) (Bool) -> Void)?) {
    nwConnection(c)?.connection.betterPathUpdateHandler = handler.map { h in { h($0) } }
}

@_cdecl("nw_connection_set_path_changed_handler")
public func finch_nw_connection_set_path_changed_handler(_ c: nw_connection_t, _ handler: (@convention(block) (nw_path_t) -> Void)?) {
    nwConnection(c)?.connection.pathUpdateHandler = handler.map { h in { h(NWConcretePath($0)) } }
}

@_cdecl("nw_connection_start")
public func finch_nw_connection_start(_ c: nw_connection_t) {
    guard let connection = nwConnection(c) else { return }
    let queue = connection.queue ?? DispatchQueue(label: "nw_connection")
    if nwUnsupportedProtocol(connection.connection.parameters) {
        connection.failedEarly = true
        let handler = connection.stateHandler
        queue.async {
            handler?(nw_connection_state_preparing, nil)
            handler?(nw_connection_state_failed, NWConcreteError(.posix(.EPROTONOSUPPORT)))
        }
        return
    }
    connection.connection.start(queue: queue)
}

@_cdecl("nw_connection_restart")
public func finch_nw_connection_restart(_ c: nw_connection_t) { nwConnection(c)?.connection.restart() }

@_cdecl("nw_connection_cancel")
public func finch_nw_connection_cancel(_ c: nw_connection_t) {
    guard let connection = nwConnection(c) else { return }
    if connection.failedEarly {
        let handler = connection.stateHandler
        (connection.queue ?? .global()).async { handler?(nw_connection_state_cancelled, nil) }
        connection.failedEarly = false
        return
    }
    connection.connection.cancel()
}

@_cdecl("nw_connection_force_cancel")
public func finch_nw_connection_force_cancel(_ c: nw_connection_t) { finch_nw_connection_cancel(c) }

@_cdecl("nw_connection_cancel_current_endpoint")
public func finch_nw_connection_cancel_current_endpoint(_ c: nw_connection_t) { nwConnection(c)?.connection.cancelCurrentEndpoint() }

@_cdecl("nw_connection_send")
public func finch_nw_connection_send(_ c: nw_connection_t, _ content: __DispatchData?, _ context: nw_content_context_t,
                                     _ isComplete: Bool, _ completion: @escaping @convention(block) (nw_error_t?) -> Void) {
    guard let connection = nwConnection(c) else { return }
    let ctx = (context as AnyObject as? NWConcreteContentContext)?.swiftContext ?? .defaultMessage
    let done: NWConnection.SendCompletion = nwSendIsIdempotent(completion as AnyObject) ? .idempotent
        : .contentProcessed({ (error: NWError?) in completion(nwErrorObject(error)) })
    connection.connection.send(content: nwData(content), contentContext: ctx, isComplete: isComplete, completion: done)
}


func nwDeliver(_ completion: @escaping @convention(block) (__DispatchData?, nw_content_context_t?, Bool, nw_error_t?) -> Void) -> (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void {
    { data, context, complete, error in
        completion(nwDispatchData(data), context.map { NWConcreteContentContext.wrapping($0) }, complete, nwErrorObject(error))
    }
}

@_cdecl("nw_connection_receive")
public func finch_nw_connection_receive(_ c: nw_connection_t, _ minimum: UInt32, _ maximum: UInt32,
                                        _ completion: @escaping @convention(block) (__DispatchData?, nw_content_context_t?, Bool, nw_error_t?) -> Void) {
    nwConnection(c)?.connection.receive(minimumIncompleteLength: Int(minimum), maximumLength: Int(maximum),
                                        completion: nwDeliver(completion))
}

@_cdecl("nw_connection_receive_message")
public func finch_nw_connection_receive_message(_ c: nw_connection_t, _ completion: @escaping @convention(block) (__DispatchData?, nw_content_context_t?, Bool, nw_error_t?) -> Void) {
    nwConnection(c)?.connection.receiveMessage(completion: nwDeliver(completion))
}

@_cdecl("nw_connection_batch")
public func finch_nw_connection_batch(_ c: nw_connection_t, _ block: @convention(block) () -> Void) { block() }

@_cdecl("nw_connection_copy_description")
public func finch_nw_connection_copy_description(_ c: nw_connection_t) -> UnsafeMutablePointer<CChar>? {
    nwCopiedString(nwConnection(c)?.connection.debugDescription)
}

@_cdecl("nw_connection_copy_current_path")
public func finch_nw_connection_copy_current_path(_ c: nw_connection_t) -> UnsafeMutableRawPointer? {
    nwRetained(nwConnection(c)?.connection.currentPath.map { NWConcretePath($0) })
}

@_cdecl("nw_connection_copy_protocol_metadata")
public func finch_nw_connection_copy_protocol_metadata(_ c: nw_connection_t, _ definition: nw_protocol_definition_t) -> UnsafeMutableRawPointer? {
    guard let d = (definition as AnyObject as? NWConcreteProtocolDefinition)?.definition else { return nil }
    return nwRetained(nwConnection(c)?.connection.metadata(definition: d).map { NWConcreteProtocolMetadata($0) })
}

@_cdecl("nw_connection_get_maximum_datagram_size")
public func finch_nw_connection_get_maximum_datagram_size(_ c: nw_connection_t) -> UInt32 {
    UInt32(clamping: nwConnection(c)?.connection.maximumDatagramSize ?? 0)
}

// MARK: - Establishment reports

@objc(NWConcrete_nw_establishment_report)
final class NWConcreteEstablishmentReport: NSObject, OS_nw_establishment_report {
    let report: NWConnection.EstablishmentReport
    init(_ report: NWConnection.EstablishmentReport) {
        self.report = report
        super.init()
    }
}

@objc(NWConcrete_nw_resolution_report)
final class NWConcreteResolutionReport: NSObject, OS_nw_resolution_report {
    let resolution: NWConnection.EstablishmentReport.Resolution
    init(_ resolution: NWConnection.EstablishmentReport.Resolution) {
        self.resolution = resolution
        super.init()
    }
}

func nwReport(_ r: nw_establishment_report_t) -> NWConnection.EstablishmentReport? { (r as AnyObject as? NWConcreteEstablishmentReport)?.report }
func nwMilliseconds(_ interval: TimeInterval) -> UInt64 { UInt64(max(0, interval * 1000)) }

@_cdecl("nw_connection_access_establishment_report")
public func finch_nw_connection_access_establishment_report(_ c: nw_connection_t, _ queue: DispatchQueue,
                                                           _ block: @escaping @convention(block) (nw_establishment_report_t?) -> Void) {
    guard let connection = nwConnection(c) else { return }
    connection.connection.requestEstablishmentReport(queue: queue) { (report: NWConnection.EstablishmentReport?) in
        block(report.map { NWConcreteEstablishmentReport($0) })
    }
}

@_cdecl("nw_establishment_report_get_duration_milliseconds")
public func finch_nw_establishment_report_get_duration_milliseconds(_ r: nw_establishment_report_t) -> UInt64 {
    nwMilliseconds(nwReport(r)?.duration ?? 0)
}
@_cdecl("nw_establishment_report_get_attempt_started_after_milliseconds")
public func finch_nw_establishment_report_get_attempt_started_after_milliseconds(_ r: nw_establishment_report_t) -> UInt64 {
    nwMilliseconds(nwReport(r)?.attemptStartedAfterInterval ?? 0)
}
@_cdecl("nw_establishment_report_get_previous_attempt_count")
public func finch_nw_establishment_report_get_previous_attempt_count(_ r: nw_establishment_report_t) -> UInt32 {
    UInt32(clamping: nwReport(r)?.previousAttemptCount ?? 0)
}
@_cdecl("nw_establishment_report_get_used_proxy")
public func finch_nw_establishment_report_get_used_proxy(_ r: nw_establishment_report_t) -> Bool { nwReport(r)?.usedProxy ?? false }
@_cdecl("nw_establishment_report_get_proxy_configured")
public func finch_nw_establishment_report_get_proxy_configured(_ r: nw_establishment_report_t) -> Bool { nwReport(r)?.proxyConfigured ?? false }
@_cdecl("nw_establishment_report_copy_proxy_endpoint")
public func finch_nw_establishment_report_copy_proxy_endpoint(_ r: nw_establishment_report_t) -> UnsafeMutableRawPointer? {
    nwRetained(nwReport(r)?.proxyEndpoint.map { NWConcreteEndpoint($0) })
}

func nwResolutionSource(_ s: NWConnection.EstablishmentReport.Resolution.Source) -> nw_report_resolution_source_t {
    switch s {
    case .query: return nw_report_resolution_source_query
    case .cache: return nw_report_resolution_source_cache
    case .expiredCache: return nw_report_resolution_source_expired_cache
    }
}

@_cdecl("nw_establishment_report_enumerate_resolutions")
public func finch_nw_establishment_report_enumerate_resolutions(
    _ r: nw_establishment_report_t,
    _ block: @convention(block) (nw_report_resolution_source_t, UInt64, UInt32, nw_endpoint_t, nw_endpoint_t) -> Bool) {
    for resolution in nwReport(r)?.resolutions ?? [] {
        let keepGoing = block(nwResolutionSource(resolution.source), nwMilliseconds(resolution.duration),
                              UInt32(clamping: resolution.endpointCount), NWConcreteEndpoint(resolution.successfulEndpoint),
                              NWConcreteEndpoint(resolution.preferredEndpoint))
        if !keepGoing { break }
    }
}

@_cdecl("nw_establishment_report_enumerate_resolution_reports")
public func finch_nw_establishment_report_enumerate_resolution_reports(_ r: nw_establishment_report_t,
                                                                      _ block: @convention(block) (nw_resolution_report_t) -> Bool) {
    for resolution in nwReport(r)?.resolutions ?? [] where !block(NWConcreteResolutionReport(resolution)) { break }
}

@_cdecl("nw_establishment_report_enumerate_protocols")
public func finch_nw_establishment_report_enumerate_protocols(_ r: nw_establishment_report_t,
                                                             _ block: @convention(block) (nw_protocol_definition_t, UInt64, UInt64) -> Bool) {
    for handshake in nwReport(r)?.handshakes ?? [] {
        if !block(NWConcreteProtocolDefinition(handshake.definition), nwMilliseconds(handshake.handshakeDuration),
                  nwMilliseconds(handshake.handshakeRTT)) { break }
    }
}

func nwResolution(_ r: nw_resolution_report_t) -> NWConnection.EstablishmentReport.Resolution? {
    (r as AnyObject as? NWConcreteResolutionReport)?.resolution
}

@_cdecl("nw_resolution_report_get_source")
public func finch_nw_resolution_report_get_source(_ r: nw_resolution_report_t) -> nw_report_resolution_source_t {
    nwResolution(r).map { nwResolutionSource($0.source) } ?? nw_report_resolution_source_query
}
@_cdecl("nw_resolution_report_get_milliseconds")
public func finch_nw_resolution_report_get_milliseconds(_ r: nw_resolution_report_t) -> UInt64 { nwMilliseconds(nwResolution(r)?.duration ?? 0) }
@_cdecl("nw_resolution_report_get_endpoint_count")
public func finch_nw_resolution_report_get_endpoint_count(_ r: nw_resolution_report_t) -> UInt32 {
    UInt32(clamping: nwResolution(r)?.endpointCount ?? 0)
}
@_cdecl("nw_resolution_report_copy_successful_endpoint")
public func finch_nw_resolution_report_copy_successful_endpoint(_ r: nw_resolution_report_t) -> UnsafeMutableRawPointer? {
    nwRetained(nwResolution(r).map { NWConcreteEndpoint($0.successfulEndpoint) })
}
@_cdecl("nw_resolution_report_copy_preferred_endpoint")
public func finch_nw_resolution_report_copy_preferred_endpoint(_ r: nw_resolution_report_t) -> UnsafeMutableRawPointer? {
    nwRetained(nwResolution(r).map { NWConcreteEndpoint($0.preferredEndpoint) })
}
@_cdecl("nw_resolution_report_get_protocol")
public func finch_nw_resolution_report_get_protocol(_ r: nw_resolution_report_t) -> nw_report_resolution_protocol_t {
    switch nwResolution(r)?.dnsProtocol {
    case .udp?: return nw_report_resolution_protocol_udp
    case .tcp?: return nw_report_resolution_protocol_tcp
    case .tls?: return nw_report_resolution_protocol_tls
    case .https?: return nw_report_resolution_protocol_https
    default: return nw_report_resolution_protocol_unknown
    }
}

// MARK: - Data transfer reports

@objc(NWConcrete_nw_data_transfer_report)
final class NWConcreteDataTransferReport: NSObject, OS_nw_data_transfer_report {
    let pending: NWConnection.PendingDataTransferReport
    var report: NWConnection.DataTransferReport?
    init(_ pending: NWConnection.PendingDataTransferReport) {
        self.pending = pending
        super.init()
    }
}

func nwTransfer(_ r: nw_data_transfer_report_t) -> NWConcreteDataTransferReport? { r as AnyObject as? NWConcreteDataTransferReport }

/* A path's report; NW_ALL_PATHS (UINT32_MAX) is the aggregate. */
func nwPathReport(_ r: nw_data_transfer_report_t, _ index: UInt32) -> NWConnection.DataTransferReport.PathReport? {
    guard let report = nwTransfer(r)?.report else { return nil }
    if index == UInt32.max { return report.aggregatePathReport }
    return Int(index) < report.pathReports.count ? report.pathReports[Int(index)] : nil
}

@_cdecl("nw_connection_create_new_data_transfer_report")
public func finch_nw_connection_create_new_data_transfer_report(_ c: nw_connection_t) -> UnsafeMutableRawPointer? {
    nwRetained(nwConnection(c).map { NWConcreteDataTransferReport($0.connection.startDataTransferReport()) })
}

@_cdecl("nw_data_transfer_report_collect")
public func finch_nw_data_transfer_report_collect(_ r: nw_data_transfer_report_t, _ queue: DispatchQueue,
                                                  _ block: @escaping @convention(block) (nw_data_transfer_report_t) -> Void) {
    guard let report = nwTransfer(r) else { return }
    report.pending.collect(queue: queue) { collected in
        report.report = collected
        block(report)
    }
}

@_cdecl("nw_data_transfer_report_get_state")
public func finch_nw_data_transfer_report_get_state(_ r: nw_data_transfer_report_t) -> nw_data_transfer_report_state_t {
    nwTransfer(r)?.report == nil ? nw_data_transfer_report_state_collecting : nw_data_transfer_report_state_collected
}
@_cdecl("nw_data_transfer_report_get_duration_milliseconds")
public func finch_nw_data_transfer_report_get_duration_milliseconds(_ r: nw_data_transfer_report_t) -> UInt64 {
    nwMilliseconds(nwTransfer(r)?.report?.duration ?? 0)
}
@_cdecl("nw_data_transfer_report_get_path_count")
public func finch_nw_data_transfer_report_get_path_count(_ r: nw_data_transfer_report_t) -> UInt32 {
    UInt32(nwTransfer(r)?.report?.pathReports.count ?? 0)
}
@_cdecl("nw_data_transfer_report_get_received_ip_packet_count")
public func finch_nw_data_transfer_report_get_received_ip_packet_count(_ r: nw_data_transfer_report_t, _ i: UInt32) -> UInt64 { nwPathReport(r, i)?.receivedIPPacketCount ?? 0 }
@_cdecl("nw_data_transfer_report_get_sent_ip_packet_count")
public func finch_nw_data_transfer_report_get_sent_ip_packet_count(_ r: nw_data_transfer_report_t, _ i: UInt32) -> UInt64 { nwPathReport(r, i)?.sentIPPacketCount ?? 0 }
@_cdecl("nw_data_transfer_report_get_received_transport_byte_count")
public func finch_nw_data_transfer_report_get_received_transport_byte_count(_ r: nw_data_transfer_report_t, _ i: UInt32) -> UInt64 { nwPathReport(r, i)?.receivedTransportByteCount ?? 0 }
@_cdecl("nw_data_transfer_report_get_received_transport_duplicate_byte_count")
public func finch_nw_data_transfer_report_get_received_transport_duplicate_byte_count(_ r: nw_data_transfer_report_t, _ i: UInt32) -> UInt64 { nwPathReport(r, i)?.receivedTransportDuplicateByteCount ?? 0 }
@_cdecl("nw_data_transfer_report_get_received_transport_out_of_order_byte_count")
public func finch_nw_data_transfer_report_get_received_transport_out_of_order_byte_count(_ r: nw_data_transfer_report_t, _ i: UInt32) -> UInt64 { nwPathReport(r, i)?.receivedTransportOutOfOrderByteCount ?? 0 }
@_cdecl("nw_data_transfer_report_get_sent_transport_byte_count")
public func finch_nw_data_transfer_report_get_sent_transport_byte_count(_ r: nw_data_transfer_report_t, _ i: UInt32) -> UInt64 { nwPathReport(r, i)?.sentTransportByteCount ?? 0 }
@_cdecl("nw_data_transfer_report_get_sent_transport_retransmitted_byte_count")
public func finch_nw_data_transfer_report_get_sent_transport_retransmitted_byte_count(_ r: nw_data_transfer_report_t, _ i: UInt32) -> UInt64 { nwPathReport(r, i)?.retransmittedTransportByteCount ?? 0 }
@_cdecl("nw_data_transfer_report_get_transport_smoothed_rtt_milliseconds")
public func finch_nw_data_transfer_report_get_transport_smoothed_rtt_milliseconds(_ r: nw_data_transfer_report_t, _ i: UInt32) -> UInt64 { nwMilliseconds(nwPathReport(r, i)?.transportSmoothedRTT ?? 0) }
@_cdecl("nw_data_transfer_report_get_transport_minimum_rtt_milliseconds")
public func finch_nw_data_transfer_report_get_transport_minimum_rtt_milliseconds(_ r: nw_data_transfer_report_t, _ i: UInt32) -> UInt64 { nwMilliseconds(nwPathReport(r, i)?.transportMinimumRTT ?? 0) }
@_cdecl("nw_data_transfer_report_get_transport_rtt_variance")
public func finch_nw_data_transfer_report_get_transport_rtt_variance(_ r: nw_data_transfer_report_t, _ i: UInt32) -> UInt64 { nwMilliseconds(nwPathReport(r, i)?.transportRTTVariance ?? 0) }
@_cdecl("nw_data_transfer_report_get_received_application_byte_count")
public func finch_nw_data_transfer_report_get_received_application_byte_count(_ r: nw_data_transfer_report_t, _ i: UInt32) -> UInt64 { nwPathReport(r, i)?.receivedApplicationByteCount ?? 0 }
@_cdecl("nw_data_transfer_report_get_sent_application_byte_count")
public func finch_nw_data_transfer_report_get_sent_application_byte_count(_ r: nw_data_transfer_report_t, _ i: UInt32) -> UInt64 { nwPathReport(r, i)?.sentApplicationByteCount ?? 0 }
@_cdecl("nw_data_transfer_report_copy_path_interface")
public func finch_nw_data_transfer_report_copy_path_interface(_ r: nw_data_transfer_report_t, _ i: UInt32) -> UnsafeMutableRawPointer? {
    nwRetained(nwPathReport(r, i).map { NWConcreteInterface($0.interface) })
}
@_cdecl("nw_data_transfer_report_get_path_radio_type")
public func finch_nw_data_transfer_report_get_path_radio_type(_ r: nw_data_transfer_report_t, _ i: UInt32) -> nw_interface_radio_type_t {
    nw_interface_radio_type_unknown
}

// MARK: - Listeners

@objc(NWConcrete_nw_listener)
final class NWConcreteListener: NSObject, OS_nw_listener {
    var listener: NWListener?
    let failure: NWError?
    let parametersObject: NWConcreteParameters
    var queue: DispatchQueue?
    var stateHandler: ((nw_listener_state_t, nw_error_t?) -> Void)?
    var advertise: NWConcreteAdvertiseDescriptor?

    init(listener: NWListener?, failure: NWError?, parameters: NWParameters) {
        self.listener = listener
        self.failure = failure
        parametersObject = NWConcreteParameters(parameters)
        super.init()
    }
}

func nwListener(_ l: nw_listener_t?) -> NWConcreteListener? { l as AnyObject? as? NWConcreteListener }

func nwMakeListener(_ parameters: NWParameters, port: NWEndpoint.Port) -> NWConcreteListener {
    do {
        return NWConcreteListener(listener: try NWListener(using: parameters, on: port), failure: nil, parameters: parameters)
    } catch let error as NWError {
        return NWConcreteListener(listener: nil, failure: error, parameters: parameters)
    } catch {
        return NWConcreteListener(listener: nil, failure: .posix(.EINVAL), parameters: parameters)
    }
}

@_cdecl("nw_listener_create")
public func finch_nw_listener_create(_ parameters: nw_parameters_t) -> UnsafeMutableRawPointer? {
    guard let p = nwParameters(parameters)?.copy() else { return nil }
    return nwRetained(nwMakeListener(p, port: p.requiredLocalEndpoint.map { nwPortNumber($0) }.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any))
}

@_cdecl("nw_listener_create_with_port")
public func finch_nw_listener_create_with_port(_ port: UnsafePointer<CChar>, _ parameters: nw_parameters_t) -> UnsafeMutableRawPointer? {
    guard let p = nwParameters(parameters)?.copy() else { return nil }
    let service = String(cString: port)
    guard let number = UInt16(service).flatMap({ NWEndpoint.Port(rawValue: $0) }) ?? NWEndpoint.Port(service) else { return nil }
    return nwRetained(nwMakeListener(p, port: number))
}

@_cdecl("nw_listener_create_with_connection")
public func finch_nw_listener_create_with_connection(_ connection: nw_connection_t, _ parameters: nw_parameters_t) -> UnsafeMutableRawPointer? {
    guard let p = nwParameters(parameters)?.copy() else { return nil }
    return nwRetained(NWConcreteListener(listener: nil, failure: .posix(.EOPNOTSUPP), parameters: p))
}

@_cdecl("nw_listener_create_with_launchd_key")
public func finch_nw_listener_create_with_launchd_key(_ parameters: nw_parameters_t, _ key: UnsafePointer<CChar>) -> UnsafeMutableRawPointer? {
    guard let p = nwParameters(parameters)?.copy() else { return nil }
    return nwRetained(NWConcreteListener(listener: nil, failure: .posix(.ENOENT), parameters: p))
}

@_cdecl("nw_listener_set_queue")
public func finch_nw_listener_set_queue(_ l: nw_listener_t, _ queue: DispatchQueue) { nwListener(l)?.queue = queue }

func nwListenerState(_ state: NWListener.State) -> (nw_listener_state_t, NWConcreteError?) {
    switch state {
    case .setup: return (nw_listener_state_invalid, nil)
    case let .waiting(error): return (nw_listener_state_waiting, NWConcreteError(error))
    case .ready: return (nw_listener_state_ready, nil)
    case let .failed(error): return (nw_listener_state_failed, NWConcreteError(error))
    case .cancelled: return (nw_listener_state_cancelled, nil)
    }
}

@_cdecl("nw_listener_set_state_changed_handler")
public func finch_nw_listener_set_state_changed_handler(_ l: nw_listener_t,
                                                       _ handler: (@convention(block) (nw_listener_state_t, nw_error_t?) -> Void)?) {
    guard let listener = nwListener(l) else { return }
    listener.stateHandler = handler.map { h in { h($0, $1) } }
    listener.listener?.stateUpdateHandler = handler.map { h in
        { state in
            let (s, error) = nwListenerState(state)
            if s != nw_listener_state_invalid { h(s, error) }
        }
    }
}

@_cdecl("nw_listener_set_new_connection_handler")
public func finch_nw_listener_set_new_connection_handler(_ l: nw_listener_t, _ handler: (@convention(block) (nw_connection_t) -> Void)?) {
    nwListener(l)?.listener?.newConnectionHandler = handler.map { h in { h(NWConcreteConnection($0)) } }
}

@_cdecl("nw_listener_set_new_connection_group_handler")
public func finch_nw_listener_set_new_connection_group_handler(_ l: nw_listener_t, _ handler: (@convention(block) (nw_connection_group_t) -> Void)?) {
    nwListener(l)?.listener?.newConnectionGroupHandler = handler.map { h in { h(NWConcreteConnectionGroup($0)) } }
}

@_cdecl("nw_listener_set_advertised_endpoint_changed_handler")
public func finch_nw_listener_set_advertised_endpoint_changed_handler(_ l: nw_listener_t,
                                                                     _ handler: (@convention(block) (nw_endpoint_t, Bool) -> Void)?) {
    nwListener(l)?.listener?.serviceRegistrationUpdateHandler = handler.map { h in
        { change in
            switch change {
            case let .add(endpoint): h(NWConcreteEndpoint(endpoint), true)
            case let .remove(endpoint): h(NWConcreteEndpoint(endpoint), false)
            }
        }
    }
}

@_cdecl("nw_listener_set_advertise_descriptor")
public func finch_nw_listener_set_advertise_descriptor(_ l: nw_listener_t, _ d: nw_advertise_descriptor_t?) {
    guard let listener = nwListener(l) else { return }
    listener.advertise = d as AnyObject as? NWConcreteAdvertiseDescriptor
    listener.listener?.service = listener.advertise?.service
}

@_cdecl("nw_listener_get_port")
public func finch_nw_listener_get_port(_ l: nw_listener_t) -> UInt16 { nwListener(l)?.listener?.port?.rawValue ?? 0 }

@_cdecl("nw_listener_get_new_connection_limit")
public func finch_nw_listener_get_new_connection_limit(_ l: nw_listener_t) -> UInt32 {
    let limit = nwListener(l)?.listener?.newConnectionLimit ?? NWListener.InfiniteConnectionLimit
    return limit == NWListener.InfiniteConnectionLimit ? UInt32.max : UInt32(clamping: limit)
}

@_cdecl("nw_listener_set_new_connection_limit")
public func finch_nw_listener_set_new_connection_limit(_ l: nw_listener_t, _ limit: UInt32) {
    nwListener(l)?.listener?.newConnectionLimit = limit == UInt32.max ? NWListener.InfiniteConnectionLimit : Int(limit)
}

@_cdecl("nw_listener_start")
public func finch_nw_listener_start(_ l: nw_listener_t) {
    guard let listener = nwListener(l) else { return }
    let queue = listener.queue ?? DispatchQueue(label: "nw_listener")
    if let failure = listener.failure {
        let handler = listener.stateHandler
        queue.async { handler?(nw_listener_state_failed, NWConcreteError(failure)) }
        return
    }
    listener.listener?.start(queue: queue)
}

@_cdecl("nw_listener_cancel")
public func finch_nw_listener_cancel(_ l: nw_listener_t) {
    guard let listener = nwListener(l) else { return }
    if listener.listener == nil {
        let handler = listener.stateHandler
        (listener.queue ?? .global()).async { handler?(nw_listener_state_cancelled, nil) }
        return
    }
    listener.listener?.cancel()
}
