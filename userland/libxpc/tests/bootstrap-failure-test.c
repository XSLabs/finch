/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Startup failure tests for finch-init's declared Mach services. These check
 * that an unstarted service wakes old callers, keeps its name for a retry,
 * and keeps queued work after a service has checked in once.
 */

#include <dispatch/dispatch.h>
#include <errno.h>
#include <mach/mach.h>
#include <mach/notify.h>
#include <servers/bootstrap.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include "../internal.h"
#include <unistd.h>
#include <xpc/xpc.h>

#define BOOTSTRAPD_TESTING
static int block_checkin_reply;
static mach_port_t reply_receive_to_kill;
static mach_port_t reply_send_once_to_kill;
static kern_return_t reply_receive_destroy_result;
static mach_port_type_t reply_send_once_type_after_destroy;
static int reply_send_status;

void
bootstrapd_test_before_check_in_reply(xpc_object_t reply)
{
	(void)reply;
	if (__atomic_exchange_n(&block_checkin_reply, 0, __ATOMIC_ACQ_REL)) {
		reply_receive_destroy_result = mach_port_mod_refs(mach_task_self(),
		    reply_receive_to_kill, MACH_PORT_RIGHT_RECEIVE, -1);
		reply_send_once_type_after_destroy = 0;
		(void)mach_port_type(mach_task_self(), reply_send_once_to_kill,
		    &reply_send_once_type_after_destroy);
	}
}

void
bootstrapd_test_reply_status(int status)
{
	reply_send_status = status;
}

/* Keep the queue-drain helper visible so the count-at-entry limit is tested
 * with a request added after that count is taken. */
#include "../../finch-init/bootstrapd.c"

static int fake_job;
static int failures, checks;
static int demand_count;
static dispatch_semaphore_t demanded;
static dispatch_queue_t server_queue;

#define CHECK(condition) do { \
	checks++; \
	if (!(condition)) { \
		failures++; \
		printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition); \
		fflush(stdout); \
	} \
} while (0)

static void
fake_demand(void *owner)
{
	if (owner == &fake_job) {
		__atomic_add_fetch(&demand_count, 1, __ATOMIC_RELAXED);
		dispatch_semaphore_signal(demanded);
	}
}

static bool
fake_may_check_in(void *owner, pid_t pid)
{
	return owner == &fake_job && pid == getpid();
}

static const struct bootstrapd_hooks fake_hooks = {
	.demand = fake_demand,
	.may_check_in = fake_may_check_in,
};

static bool
wait_for_demand(void)
{
	return dispatch_semaphore_wait(demanded,
	    dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0;
}

static mach_port_t
new_reply_port(void)
{
	mach_port_t port = MACH_PORT_NULL;
	CHECK(mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port) == KERN_SUCCESS);
	return port;
}

static void
send_request(mach_port_t service, mach_port_t reply, mach_msg_id_t id)
{
	mach_msg_header_t message = {
		.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE),
		.msgh_size = sizeof(message),
		.msgh_remote_port = service,
		.msgh_local_port = reply,
		.msgh_id = id,
	};
	CHECK(mach_msg(&message, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(message), 0,
	    MACH_PORT_NULL, 1000, MACH_PORT_NULL) == MACH_MSG_SUCCESS);
}

static void
send_large_request(mach_port_t service, mach_port_t reply, mach_msg_id_t id)
{
	struct {
		mach_msg_header_t header;
		uint8_t body[512];
	} message = {0};
	message.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
	message.header.msgh_size = sizeof(message);
	message.header.msgh_remote_port = service;
	message.header.msgh_local_port = reply;
	message.header.msgh_id = id;
	CHECK(mach_msg(&message.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(message), 0,
	    MACH_PORT_NULL, 1000, MACH_PORT_NULL) == MACH_MSG_SUCCESS);
}

static mach_msg_id_t
receive_message(mach_port_t port, mach_msg_timeout_t timeout)
{
	union {
		mach_msg_header_t header;
		uint8_t bytes[sizeof(mach_msg_header_t) + MAX_TRAILER_SIZE];
	} message;
	kern_return_t kr = mach_msg(&message.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0,
	    sizeof(message), port, timeout, MACH_PORT_NULL);
	if (kr != MACH_MSG_SUCCESS) {
		return -1;
	}
	mach_msg_id_t id = message.header.msgh_id;
	mach_msg_destroy(&message.header);
	return id;
}

static bool
wait_for_send_once(mach_port_t reply)
{
	return receive_message(reply, 2000) == MACH_NOTIFY_SEND_ONCE;
}

static void
test_failed_first_start(mach_port_t bootstrap)
{
	const char *name = "org.finch.test.start-failure";
	mach_port_t service = MACH_PORT_NULL, same_service = MACH_PORT_NULL;
	mach_port_t reply1 = new_reply_port(), reply2 = new_reply_port();
	__block int err = -1;

	dispatch_sync(server_queue, ^{ err = bootstrapd_declare(bootstrap, name, &fake_job); });
	CHECK(err == 0);
	CHECK(bootstrap_look_up(bootstrap, name, &service) == BOOTSTRAP_SUCCESS);

	/* Two callers are queued before the first process fails to spawn. */
	send_request(service, reply1, 0x101);
	send_request(service, reply2, 0x102);
	CHECK(wait_for_demand());
	CHECK(__atomic_load_n(&demand_count, __ATOMIC_RELAXED) == 1);
	dispatch_sync(server_queue, ^{
		bootstrapd_start_failed(&fake_job);
		bootstrapd_rearm(&fake_job);
	});
	CHECK(wait_for_send_once(reply1));
	CHECK(wait_for_send_once(reply2));

	/* The name stays live, so a later caller can trigger another start. */
	CHECK(bootstrap_look_up(bootstrap, name, &same_service) == BOOTSTRAP_SUCCESS);
	CHECK(same_service == service);
	CHECK(mach_port_deallocate(mach_task_self(), same_service) == KERN_SUCCESS);
	CHECK(mach_port_mod_refs(mach_task_self(), reply1, MACH_PORT_RIGHT_RECEIVE, -1) == KERN_SUCCESS);
	CHECK(mach_port_mod_refs(mach_task_self(), reply2, MACH_PORT_RIGHT_RECEIVE, -1) == KERN_SUCCESS);

	/* A later request is delivered to a process that checks in successfully. */
	mach_port_t reply3 = new_reply_port(), receive = MACH_PORT_NULL;
	send_request(service, reply3, 0x103);
	CHECK(wait_for_demand());
	CHECK(bootstrap_check_in(bootstrap, name, &receive) == BOOTSTRAP_SUCCESS);
	CHECK(receive_message(receive, 2000) == 0x103);
	CHECK(wait_for_send_once(reply3));
	CHECK(mach_port_mod_refs(mach_task_self(), receive, MACH_PORT_RIGHT_RECEIVE, -1) == KERN_SUCCESS);
	CHECK(mach_port_mod_refs(mach_task_self(), reply3, MACH_PORT_RIGHT_RECEIVE, -1) == KERN_SUCCESS);
	CHECK(mach_port_deallocate(mach_task_self(), service) == KERN_SUCCESS);
}

static void
test_restart_keeps_queued_request(mach_port_t bootstrap)
{
	const char *name = "org.finch.test.restart-queue";
	mach_port_t service = MACH_PORT_NULL, receive = MACH_PORT_NULL;
	mach_port_t reply = new_reply_port();
	__block int err = -1;

	dispatch_sync(server_queue, ^{ err = bootstrapd_declare(bootstrap, name, &fake_job); });
	CHECK(err == 0);
	CHECK(bootstrap_look_up(bootstrap, name, &service) == BOOTSTRAP_SUCCESS);
	CHECK(bootstrap_check_in(bootstrap, name, &receive) == BOOTSTRAP_SUCCESS);

	/* This request waits while the checked-in service restarts. */
	send_request(service, reply, 0x201);
	CHECK(mach_port_mod_refs(mach_task_self(), receive, MACH_PORT_RIGHT_RECEIVE, -1) == KERN_SUCCESS);
	CHECK(wait_for_demand());  /* The receive right returned with the request queued. */
	dispatch_sync(server_queue, ^{
		bootstrapd_start_failed(&fake_job);
		bootstrapd_rearm(&fake_job);
	});
	CHECK(wait_for_demand());  /* Re-arming must still see the same queued request. */
	CHECK(receive_message(reply, 100) == -1);  /* The request was not dropped. */

	CHECK(bootstrap_check_in(bootstrap, name, &receive) == BOOTSTRAP_SUCCESS);
	CHECK(receive_message(receive, 2000) == 0x201);
	CHECK(wait_for_send_once(reply));
	CHECK(mach_port_mod_refs(mach_task_self(), receive, MACH_PORT_RIGHT_RECEIVE, -1) == KERN_SUCCESS);
	CHECK(mach_port_mod_refs(mach_task_self(), reply, MACH_PORT_RIGHT_RECEIVE, -1) == KERN_SUCCESS);
	CHECK(mach_port_deallocate(mach_task_self(), service) == KERN_SUCCESS);
}

static void
test_drain_uses_a_finite_snapshot(void)
{
	mach_port_t receive = MACH_PORT_NULL, send = MACH_PORT_NULL;
	mach_port_t reply1 = new_reply_port(), reply2 = new_reply_port();
	mach_port_status_t status;
	mach_msg_type_number_t info_count = MACH_PORT_RECEIVE_STATUS_COUNT;

	CHECK(mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &receive) == KERN_SUCCESS);
	CHECK(mach_port_insert_right(mach_task_self(), receive, receive, MACH_MSG_TYPE_MAKE_SEND) == KERN_SUCCESS);
	send = receive;
	send_large_request(send, reply1, 0x301);
	CHECK(mach_port_get_attributes(mach_task_self(), receive, MACH_PORT_RECEIVE_STATUS,
	    (mach_port_info_t)&status, &info_count) == KERN_SUCCESS);
	CHECK(status.mps_msgcount == 1);

	/* This second caller arrived after the failure path took its queue count. */
	send_request(send, reply2, 0x302);
	drain_queued(receive, status.mps_msgcount);
	CHECK(wait_for_send_once(reply1));
	CHECK(receive_message(reply2, 100) == -1);
	CHECK(receive_message(receive, 2000) == 0x302);
	CHECK(wait_for_send_once(reply2));

	CHECK(mach_port_mod_refs(mach_task_self(), reply1, MACH_PORT_RIGHT_RECEIVE, -1) == KERN_SUCCESS);
	CHECK(mach_port_mod_refs(mach_task_self(), reply2, MACH_PORT_RIGHT_RECEIVE, -1) == KERN_SUCCESS);
	CHECK(mach_port_mod_refs(mach_task_self(), receive, MACH_PORT_RIGHT_RECEIVE, -1) == KERN_SUCCESS);
	CHECK(mach_port_deallocate(mach_task_self(), send) == KERN_SUCCESS);
}

static void
test_failed_checkin_reply_returns_receive_right(mach_port_t bootstrap)
{
	const char *name = "org.finch.test.checkin-reply-failure";
	mach_port_t service = MACH_PORT_NULL, receive = MACH_PORT_NULL;
	mach_port_t receive2 = MACH_PORT_NULL;
	__block mach_port_t original_service_port = MACH_PORT_NULL;
	__block mach_port_t restored_service_port = MACH_PORT_NULL;
	mach_port_t waiting_reply = new_reply_port(), served_reply = new_reply_port();
	mach_port_t reply_receive = MACH_PORT_NULL, source = MACH_PORT_NULL;
	mach_port_t send_once = MACH_PORT_NULL;
	__block bool held_after_reply_failure = false;
	__block bool checked_in_once_after_reply = false;
	__block bool watch_cleared_after_return = false;
	__block bool watch_rearmed_after_retry = false;
	__block mach_port_type_t restored_service_type = 0;
	__block int err = -1;
	__block kern_return_t reply_result = KERN_SUCCESS;
	__block mach_port_msgcount_t notify_messages_before = 0, notify_messages_after = 0;
	xpc_object_t request;
	struct _xpc_dictionary_s *request_dict;

	dispatch_sync(server_queue, ^{ err = bootstrapd_declare(bootstrap, name, &fake_job); });
	CHECK(err == 0);
	CHECK(bootstrap_look_up(bootstrap, name, &service) == BOOTSTRAP_SUCCESS);
	send_request(service, waiting_reply, 0x401);
	CHECK(wait_for_demand());
	/* Clear notices from earlier scenarios, then test an empty starting queue. */
	dispatch_sync(server_queue, ^{ port_returned(); });

	CHECK(mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &reply_receive) == KERN_SUCCESS);
	CHECK(mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &source) == KERN_SUCCESS);
	CHECK(mach_port_insert_right(mach_task_self(), source, source, MACH_MSG_TYPE_MAKE_SEND) == KERN_SUCCESS);
	/* Create the send-once right the bootstrap request would carry, but keep
	 * its receive destination name so the test can kill it at the reply point. */
	struct {
		mach_msg_header_t header;
	} outgoing = {{
		.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE),
		.msgh_size = sizeof(mach_msg_header_t),
		.msgh_remote_port = source,
		.msgh_local_port = reply_receive,
		.msgh_id = 0x410,
	}};
	struct {
		mach_msg_header_t header;
		uint8_t bytes[MAX_TRAILER_SIZE];
	} incoming = {0};
	CHECK(mach_msg(&outgoing.header, MACH_SEND_MSG, sizeof(outgoing), 0, MACH_PORT_NULL,
	    MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL) == MACH_MSG_SUCCESS);
	CHECK(mach_msg(&incoming.header, MACH_RCV_MSG, 0, sizeof(incoming), source,
	    MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL) == MACH_MSG_SUCCESS);
	send_once = incoming.header.msgh_remote_port;
	incoming.header.msgh_remote_port = MACH_PORT_NULL;
	incoming.header.msgh_local_port = MACH_PORT_NULL;
	incoming.header.msgh_bits = 0;
	mach_msg_destroy(&incoming.header);
	request = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_string(request, "name", name);
	request_dict = (struct _xpc_dictionary_s *)request;
	request_dict->msgid = XPC_MSGID_PIPE_ROUTINE | 206;
	request_dict->reply_port = send_once;
	request_dict->reply_msgid = 0;
	request_dict->has_audit = true;
	request_dict->audit.val[5] = (uint32_t)getpid();
	reply_receive_to_kill = reply_receive;
	reply_send_once_to_kill = send_once;
	reply_send_status = -1;
	__atomic_store_n(&block_checkin_reply, 1, __ATOMIC_RELEASE);
	/* Run the real check-in and XPC reply path. The test hook kills its reply
	 * destination after check-in clears held but before the Mach send starts. */
	dispatch_sync(server_queue, ^{
		struct service *s = find(domain_for_port(bootstrap), name);
		original_service_port = s != NULL ? s->port : MACH_PORT_NULL;
		mach_port_status_t notify_status;
		mach_msg_type_number_t notify_info_count = MACH_PORT_RECEIVE_STATUS_COUNT;
		if (mach_port_get_attributes(mach_task_self(), notify_port,
		        MACH_PORT_RECEIVE_STATUS, (mach_port_info_t)&notify_status,
		        &notify_info_count) == KERN_SUCCESS) {
			notify_messages_before = notify_status.mps_msgcount;
		}
		handle(domain_for_port(bootstrap), request);
		reply_result = reply_receive_destroy_result;
		s = find(domain_for_port(bootstrap), name);
		held_after_reply_failure = s != NULL && s->held;
		checked_in_once_after_reply = s != NULL && s->checked_in_once;
		if (s != NULL) {
			restored_service_port = s->port;
			(void)mach_port_type(mach_task_self(), s->port, &restored_service_type);
		}
		notify_info_count = MACH_PORT_RECEIVE_STATUS_COUNT;
		if (mach_port_get_attributes(mach_task_self(), notify_port,
		        MACH_PORT_RECEIVE_STATUS, (mach_port_info_t)&notify_status,
		        &notify_info_count) == KERN_SUCCESS) {
			notify_messages_after = notify_status.mps_msgcount;
		}
		bootstrapd_start_failed(&fake_job);
		bootstrapd_rearm(&fake_job);
	});
	CHECK(reply_result == KERN_SUCCESS);
	CHECK(reply_send_status == EPIPE); /* MACH_SEND_INVALID_DEST in pipe.c */
	CHECK((reply_send_once_type_after_destroy & MACH_PORT_TYPE_DEAD_NAME) != 0);
	CHECK(notify_messages_before == 0);
	CHECK(notify_messages_after == 0);
	xpc_release(request);

	/* MACH_SEND_INVALID_DEST restores MOVE_RECEIVE under its original name
	 * before xpc_pipe_routine_reply returns. Start failure then wakes the
	 * caller already queued on this service. */
	CHECK(held_after_reply_failure);
	CHECK(checked_in_once_after_reply == false);
	CHECK(restored_service_port == original_service_port);
	CHECK((restored_service_type & MACH_PORT_TYPE_RECEIVE) != 0);
	CHECK(wait_for_send_once(waiting_reply));

	/* Keep the same registered service, and let a good process check in. */
	CHECK(bootstrap_look_up(bootstrap, name, &service) == BOOTSTRAP_SUCCESS);
	kern_return_t checkin_result = bootstrap_check_in(bootstrap, name, &receive);
	if (checkin_result != BOOTSTRAP_SUCCESS) {
		__block bool held_at_retry = false;
		dispatch_sync(server_queue, ^{
			struct service *s = find(domain_for_port(bootstrap), name);
			held_at_retry = s != NULL && s->held;
		});
		printf("retry check-in result=%d held=%d\n", checkin_result, held_at_retry);
	}
	CHECK(checkin_result == BOOTSTRAP_SUCCESS);
	send_request(service, served_reply, 0x402);
	CHECK(receive_message(receive, 2000) == 0x402);
	CHECK(wait_for_send_once(served_reply));
	CHECK(mach_port_mod_refs(mach_task_self(), receive, MACH_PORT_RIGHT_RECEIVE, -1) == KERN_SUCCESS);
	dispatch_sync(server_queue, ^{
		port_returned();
		struct service *s = find(domain_for_port(bootstrap), name);
		watch_cleared_after_return = s != NULL && s->held && !s->destroyed_notification_armed;
	});
	CHECK(watch_cleared_after_return);
	CHECK(bootstrap_check_in(bootstrap, name, &receive2) == BOOTSTRAP_SUCCESS);
	dispatch_sync(server_queue, ^{
		struct service *s = find(domain_for_port(bootstrap), name);
		watch_rearmed_after_retry = s != NULL && !s->held && s->destroyed_notification_armed;
	});
	CHECK(watch_rearmed_after_retry);
	CHECK(mach_port_mod_refs(mach_task_self(), receive2, MACH_PORT_RIGHT_RECEIVE, -1) == KERN_SUCCESS);
	dispatch_sync(server_queue, ^{
		port_returned();
		struct service *s = find(domain_for_port(bootstrap), name);
		watch_cleared_after_return = s != NULL && s->held && !s->destroyed_notification_armed;
	});
	CHECK(watch_cleared_after_return);
	CHECK(mach_port_mod_refs(mach_task_self(), waiting_reply, MACH_PORT_RIGHT_RECEIVE, -1) == KERN_SUCCESS);
	CHECK(mach_port_mod_refs(mach_task_self(), served_reply, MACH_PORT_RIGHT_RECEIVE, -1) == KERN_SUCCESS);
	CHECK(mach_port_deallocate(mach_task_self(), service) == KERN_SUCCESS);
	CHECK(mach_port_mod_refs(mach_task_self(), source, MACH_PORT_RIGHT_RECEIVE, -1) == KERN_SUCCESS);
	CHECK(mach_port_deallocate(mach_task_self(), source) == KERN_SUCCESS);
}

int
main(void)
{
	setvbuf(stdout, NULL, _IONBF, 0);
	server_queue = dispatch_queue_create("bootstrap-start-failure-test", DISPATCH_QUEUE_SERIAL);
	demanded = dispatch_semaphore_create(0);
	mach_port_t bootstrap = bootstrapd_start(server_queue, &fake_hooks, NULL);
	CHECK(MACH_PORT_VALID(bootstrap));
	bootstrap_port = bootstrap;

	test_failed_first_start(bootstrap);
	test_restart_keeps_queued_request(bootstrap);
	test_drain_uses_a_finite_snapshot();
	test_failed_checkin_reply_returns_receive_right(bootstrap);

	printf("%s: %d/%d startup-failure checks passed\n", failures ? "FAILED" : "PASSED",
	    checks - failures, checks);
	return failures != 0;
}
