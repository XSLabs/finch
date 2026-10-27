/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-network-c-test: Network's C API, compiled with ARC as apps use it: endpoints,
 * TXT records, parameters and protocol stacks, content contexts, errors, a loopback TCP
 * listener and connection exchanging messages, a refused connection, a path monitor,
 * and QUIC, WebSocket and framer options. Compared with Apple's Network.
 */
#import <Foundation/Foundation.h>
#import <Network/Network.h>
#include <arpa/inet.h>
#include <stdio.h>
#include <string.h>

static void
endpoint(const char *label, nw_endpoint_t e)
{
    if (!e) {
        printf("%s: nil\n", label);
        return;
    }
    char *address = nw_endpoint_copy_address_string(e), *port = nw_endpoint_copy_port_string(e);
    printf("%s: type %d host %s port %u (%s) address %s", label, nw_endpoint_get_type(e), nw_endpoint_get_hostname(e) ?: "-",
           nw_endpoint_get_port(e), port ?: "-", address ?: "-");
    if (nw_endpoint_get_type(e) == nw_endpoint_type_bonjour_service)
        printf(" service %s %s %s", nw_endpoint_get_bonjour_service_name(e), nw_endpoint_get_bonjour_service_type(e),
               nw_endpoint_get_bonjour_service_domain(e));
    if (nw_endpoint_get_type(e) == nw_endpoint_type_url)
        printf(" url %s", nw_endpoint_get_url(e));
    printf("\n");
    free(address);
    free(port);
}

static const char *
state_name(nw_connection_state_t s)
{
    switch (s) {
    case nw_connection_state_waiting: return "waiting";
    case nw_connection_state_preparing: return "preparing";
    case nw_connection_state_ready: return "ready";
    case nw_connection_state_failed: return "failed";
    case nw_connection_state_cancelled: return "cancelled";
    default: return "invalid";
    }
}

static NSString *
string_of(dispatch_data_t d)
{
    if (!d)
        return @"(none)";
    NSMutableData *all = [NSMutableData data];
    dispatch_data_apply(d, ^bool(dispatch_data_t region, size_t offset, const void *buffer, size_t size) {
        [all appendBytes:buffer length:size];
        return true;
    });
    return [[NSString alloc] initWithData:all encoding:NSUTF8StringEncoding];
}

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);

        /* endpoints */
        endpoint("v4", nw_endpoint_create_host("127.0.0.1", "8080"));
        endpoint("v6", nw_endpoint_create_host("::1", "443"));
        endpoint("name", nw_endpoint_create_host("example.com", "https"));
        endpoint("bonjour", nw_endpoint_create_bonjour_service("Printer", "_ipp._tcp", "local."));
        endpoint("url", nw_endpoint_create_url("https://example.org:8443/path"));
        endpoint("bad port", nw_endpoint_create_host("example.com", "not-a-port"));
        struct sockaddr_in sin = {.sin_len = sizeof sin, .sin_family = AF_INET, .sin_port = htons(1234)};
        inet_pton(AF_INET, "10.1.2.3", &sin.sin_addr);
        nw_endpoint_t fromAddress = nw_endpoint_create_address((struct sockaddr *)&sin);
        endpoint("sockaddr", fromAddress);
        const struct sockaddr_in *back = (const struct sockaddr_in *)nw_endpoint_get_address(fromAddress);
        char text[64];
        printf("sockaddr back: family %d port %d %s\n", back->sin_family, ntohs(back->sin_port), inet_ntop(AF_INET, &back->sin_addr, text, sizeof text));

        /* TXT records */
        nw_txt_record_t txt = nw_txt_record_create_dictionary();
        printf("txt set %d %d %d\n", nw_txt_record_set_key(txt, "path", (const uint8_t *)"/x", 2), nw_txt_record_set_key(txt, "flag", NULL, 0),
               nw_txt_record_set_key(txt, "empty", (const uint8_t *)"", 0));
        printf("txt count %zu find %d %d %d %d\n", nw_txt_record_get_key_count(txt), nw_txt_record_find_key(txt, "path"),
               nw_txt_record_find_key(txt, "flag"), nw_txt_record_find_key(txt, "empty"), nw_txt_record_find_key(txt, "missing"));
        nw_txt_record_access_key(txt, "PATH", ^bool(const char *key, nw_txt_record_find_key_t found, const uint8_t *value, size_t length) {
            printf("txt access %s %d %.*s\n", key, found, (int)length, value);
            return true;
        });
        nw_txt_record_access_bytes(txt, ^bool(const uint8_t *raw, size_t length) {
            printf("txt bytes %zu\n", length);
            return true;
        });
        nw_txt_record_t txtCopy = nw_txt_record_copy(txt);
        printf("txt equal %d remove %d equal %d dictionary %d\n", nw_txt_record_is_equal(txt, txtCopy), nw_txt_record_remove_key(txtCopy, "flag"),
               nw_txt_record_is_equal(txt, txtCopy), nw_txt_record_is_dictionary(txt));
        nw_txt_record_t raw = nw_txt_record_create_with_bytes((const uint8_t *)"\x03" "a=b" "\x01" "c", 6);
        printf("txt raw dictionary %d count %zu\n", nw_txt_record_is_dictionary(raw), nw_txt_record_get_key_count(raw));

        /* parameters and protocol stacks */
        nw_parameters_t tcp = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
        nw_protocol_stack_t stack = nw_parameters_copy_default_protocol_stack(tcp);
        __block int applications = 0;
        nw_protocol_stack_iterate_application_protocols(stack, ^(nw_protocol_options_t options) { applications++; });
        nw_protocol_definition_t tcpDefinition = nw_protocol_copy_tcp_definition();
        nw_protocol_options_t transport = nw_protocol_stack_copy_transport_protocol(stack);
        printf("tcp stack: %d application protocols, transport is tcp %d, internet %d\n", applications,
               nw_protocol_definition_is_equal(nw_protocol_options_copy_definition(transport), tcpDefinition),
               nw_protocol_stack_copy_internet_protocol(stack) != nil);
        nw_parameters_t tls = nw_parameters_create_secure_tcp(NW_PARAMETERS_DEFAULT_CONFIGURATION, ^(nw_protocol_options_t options) {
            nw_tcp_options_set_no_delay(options, true);
        });
        applications = 0;
        nw_protocol_stack_iterate_application_protocols(nw_parameters_copy_default_protocol_stack(tls), ^(nw_protocol_options_t options) {
            applications++;
            printf("tls stack application protocol is tls %d\n",
                   nw_protocol_definition_is_equal(nw_protocol_options_copy_definition(options), nw_protocol_copy_tls_definition()));
        });
        printf("tls stack: %d application protocols\n", applications);
        nw_parameters_t udp = nw_parameters_create_secure_udp(NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
        printf("udp transport is udp %d\n",
               nw_protocol_definition_is_equal(nw_protocol_options_copy_definition(nw_protocol_stack_copy_transport_protocol(nw_parameters_copy_default_protocol_stack(udp))),
                                               nw_protocol_copy_udp_definition()));
        nw_parameters_set_reuse_local_address(tcp, true);
        nw_parameters_set_prohibit_expensive(tcp, true);
        nw_parameters_set_include_peer_to_peer(tcp, true);
        nw_parameters_set_service_class(tcp, nw_service_class_background);
        nw_parameters_set_multipath_service(tcp, nw_multipath_service_handover);
        nw_parameters_set_expired_dns_behavior(tcp, nw_parameters_expired_dns_behavior_allow);
        nw_parameters_set_attribution(tcp, nw_parameters_attribution_user);
        nw_parameters_prohibit_interface_type(tcp, nw_interface_type_cellular);
        nw_parameters_t copied = nw_parameters_copy(tcp);
        __block int prohibited = 0;
        nw_parameters_iterate_prohibited_interface_types(copied, ^bool(nw_interface_type_t type) {
            prohibited = type;
            return true;
        });
        printf("parameters: reuse %d expensive %d p2p %d class %d multipath %d dns %d attribution %d prohibited %d local only %d\n",
               nw_parameters_get_reuse_local_address(copied), nw_parameters_get_prohibit_expensive(copied),
               nw_parameters_get_include_peer_to_peer(copied), nw_parameters_get_service_class(copied),
               nw_parameters_get_multipath_service(copied), nw_parameters_get_expired_dns_behavior(copied),
               nw_parameters_get_attribution(copied), prohibited, nw_parameters_get_local_only(copied));
        nw_parameters_set_local_endpoint(tcp, nw_endpoint_create_host("127.0.0.1", "0"));
        endpoint("local endpoint", nw_parameters_copy_local_endpoint(tcp));

        /* content contexts */
        nw_content_context_t context = nw_content_context_create("request");
        nw_content_context_set_is_final(context, true);
        nw_content_context_set_expiration_milliseconds(context, 500);
        nw_content_context_set_relative_priority(context, 0.75);
        nw_content_context_set_antecedent(context, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT);
        printf("context %s final %d expiration %llu priority %.2f antecedent %s\n", nw_content_context_get_identifier(context),
               nw_content_context_get_is_final(context), nw_content_context_get_expiration_milliseconds(context),
               nw_content_context_get_relative_priority(context), nw_content_context_get_identifier(nw_content_context_copy_antecedent(context)));
        printf("final message context final %d, stream context final %d\n", nw_content_context_get_is_final(NW_CONNECTION_FINAL_MESSAGE_CONTEXT),
               nw_content_context_get_is_final(NW_CONNECTION_DEFAULT_STREAM_CONTEXT));

        /* a loopback listener and a connection to it */
        dispatch_queue_t queue = dispatch_queue_create("network-c-test", NULL);
        dispatch_semaphore_t done = dispatch_semaphore_create(0), listening = dispatch_semaphore_create(0);
        nw_parameters_t listenParameters = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
        nw_parameters_set_local_endpoint(listenParameters, nw_endpoint_create_host("127.0.0.1", "0"));
        nw_listener_t listener = nw_listener_create(listenParameters);
        nw_listener_set_queue(listener, queue);
        nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state, nw_error_t error) {
            if (state == nw_listener_state_ready)
                dispatch_semaphore_signal(listening);
        });
        nw_listener_set_new_connection_handler(listener, ^(nw_connection_t accepted) {
            nw_connection_set_queue(accepted, queue);
            nw_connection_start(accepted);
            nw_connection_receive(accepted, 5, 5, ^(dispatch_data_t content, nw_content_context_t ctx, bool complete, nw_error_t error) {
                printf("server received '%s' error %d\n", string_of(content).UTF8String, error != nil);
                dispatch_data_t reply = dispatch_data_create("world", 5, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
                nw_connection_send(accepted, reply, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t sendError) {
                    printf("server sent, error %d\n", sendError != nil);
                });
            });
        });
        nw_listener_start(listener);
        if (dispatch_semaphore_wait(listening, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0)
            printf("listener never became ready\n");
        uint16_t port = nw_listener_get_port(listener);
        printf("listener ready, port set %d, limit %u\n", port != 0, nw_listener_get_new_connection_limit(listener));
        char portText[8];
        snprintf(portText, sizeof portText, "%u", port);
        nw_connection_t connection = nw_connection_create(nw_endpoint_create_host("127.0.0.1", portText),
                                                          nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION));
        nw_connection_set_queue(connection, queue);
        nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t error) {
            printf("client state %s\n", state_name(state));
            if (state == nw_connection_state_ready) {
                dispatch_data_t hello = dispatch_data_create("hello", 5, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
                nw_connection_send(connection, hello, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t sendError) {
                    printf("client sent, error %d\n", sendError != nil);
                });
                nw_connection_receive(connection, 1, 64, ^(dispatch_data_t content, nw_content_context_t ctx, bool complete, nw_error_t receiveError) {
                    printf("client received '%s'\n", string_of(content).UTF8String);
                    nw_path_t path = nw_connection_copy_current_path(connection);
                    printf("path satisfied %d\n", nw_path_get_status(path) == nw_path_status_satisfied);
                    nw_connection_cancel(connection);
                });
            }
            if (state == nw_connection_state_cancelled)
                dispatch_semaphore_signal(done);
        });
        nw_connection_start(connection);
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) != 0)
            printf("connection never finished\n");
        nw_endpoint_t remote = nw_connection_copy_endpoint(connection);
        printf("connection endpoint: type %d host %s port matches %d\n", nw_endpoint_get_type(remote), nw_endpoint_get_hostname(remote),
               nw_endpoint_get_port(remote) == port);
        char *description = nw_connection_copy_description(connection);
        printf("description present %d\n", description != NULL && strlen(description) > 0);
        free(description);
        nw_listener_cancel(listener);

        /* a refused connection */
        nw_connection_t refused = nw_connection_create(nw_endpoint_create_host("127.0.0.1", "1"),
                                                       nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION));
        nw_connection_set_queue(refused, queue);
        nw_connection_set_state_changed_handler(refused, ^(nw_connection_state_t state, nw_error_t error) {
            if (state == nw_connection_state_waiting || state == nw_connection_state_failed) {
                printf("refused: %s domain %d code %d\n", state_name(state), nw_error_get_error_domain(error), nw_error_get_error_code(error));
                CFErrorRef cf = nw_error_copy_cf_error(error);
                printf("refused cf error %s %ld\n", [(__bridge NSString *)CFErrorGetDomain(cf) UTF8String], (long)CFErrorGetCode(cf));
                CFRelease(cf);
                nw_connection_cancel(refused);
            }
            if (state == nw_connection_state_cancelled)
                dispatch_semaphore_signal(done);
        });
        nw_connection_start(refused);
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) != 0)
            printf("refused connection never finished\n");

        /* a path monitor */
        nw_path_monitor_t monitor = nw_path_monitor_create();
        nw_path_monitor_set_queue(monitor, queue);
        nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {
            __block int interfaces = 0;
            nw_path_enumerate_interfaces(path, ^bool(nw_interface_t interface) {
                interfaces++;
                return true;
            });
            printf("monitor: satisfied %d has interfaces %d dns %d\n", nw_path_get_status(path) == nw_path_status_satisfied, interfaces > 0,
                   nw_path_has_dns(path));
            dispatch_semaphore_signal(done);
        });
        nw_path_monitor_set_cancel_handler(monitor, ^{
            printf("monitor cancelled\n");
            dispatch_semaphore_signal(done);
        });
        nw_path_monitor_start(monitor);
        dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        nw_path_monitor_cancel(monitor);
        dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));

        /* QUIC, WebSocket and framer options */
        nw_protocol_options_t quic = nw_quic_create_options();
        nw_quic_set_idle_timeout(quic, 30000);
        nw_quic_set_initial_max_data(quic, 1 << 20);
        nw_quic_set_stream_is_unidirectional(quic, true);
        printf("quic: is quic %d idle %u max data %llu unidirectional %d\n", nw_protocol_options_is_quic(quic), nw_quic_get_idle_timeout(quic),
               nw_quic_get_initial_max_data(quic), nw_quic_get_stream_is_unidirectional(quic));
        nw_protocol_metadata_t ws = nw_ws_create_metadata(nw_ws_opcode_text);
        nw_ws_metadata_set_close_code(ws, nw_ws_close_code_going_away);
        printf("ws metadata: is ws %d opcode %d close %d\n", nw_protocol_metadata_is_ws(ws), nw_ws_metadata_get_opcode(ws),
               nw_ws_metadata_get_close_code(ws));
        nw_ws_response_t response = nw_ws_response_create(nw_ws_response_status_accept, "chat");
        printf("ws response: status %d subprotocol %s\n", nw_ws_response_get_status(response), nw_ws_response_get_selected_subprotocol(response));
        nw_protocol_definition_t framerDefinition = nw_framer_create_definition("Finch", NW_FRAMER_CREATE_FLAGS_DEFAULT,
                                                                                 ^nw_framer_start_result_t(nw_framer_t framer) {
                                                                                     return nw_framer_start_result_ready;
                                                                                 });
        nw_protocol_options_t framerOptions = nw_framer_create_options(framerDefinition);
        nw_framer_options_set_object_value(framerOptions, "key", @"value");
        printf("framer options value %s\n", [(NSString *)nw_framer_options_copy_object_value(framerOptions, "key") UTF8String]);
        nw_framer_message_t message = nw_framer_protocol_create_message(framerDefinition);
        nw_framer_message_set_object_value(message, "count", @3);
        printf("framer message: is message %d count %s\n", nw_protocol_metadata_is_framer_message(message),
               [[(NSNumber *)nw_framer_message_copy_object_value(message, "count") description] UTF8String]);
    }
    return 0;
}
