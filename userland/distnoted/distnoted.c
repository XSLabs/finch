/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-distnoted: distributed notifications between a user's processes (macOS's
 * distnoted, whose protocol is private; Finch's CoreFoundation is the only client).
 * A per-user agent, Mach service org.finch.distnoted, with a root instance in the
 * system domain for root's processes.
 *
 * Each client connection says what it observes and posts:
 *
 *   { op: "observe", id, name?, object? }   a filter (no name: any name)
 *   { op: "unobserve", id }
 *   { op: "post", name, object?, userInfo? }   (userInfo: a binary property list)
 *
 * and each post goes to every connection with a filter it matches, the poster's
 * included, as { op: "notification", name, object?, userInfo? }. The client matches
 * it to its observers (CFNotificationCenter_Finch.m).
 */
#include <dispatch/dispatch.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <xpc/xpc.h>

#define SERVICE "org.finch.distnoted"

struct filter {
    int64_t id;
    char *name;     /* NULL: any */
    char *object;   /* NULL: any */
};

struct client {
    xpc_connection_t connection;
    struct filter *filters;
    size_t count, capacity;
    struct client *next;
};

static struct client *clients;
static dispatch_queue_t queue;

static char *
copy_string(xpc_object_t message, const char *key)
{
    const char *s = xpc_dictionary_get_string(message, key);
    return s ? strdup(s) : NULL;
}

static bool
matches(const struct filter *f, const char *name, const char *object)
{
    return (!f->name || !strcmp(f->name, name)) && (!f->object || (object && !strcmp(f->object, object)));
}

static void
drop(struct client *c)
{
    for (struct client **p = &clients; *p; p = &(*p)->next) {
        if (*p == c) {
            *p = c->next;
            break;
        }
    }
    for (size_t i = 0; i < c->count; i++) {
        free(c->filters[i].name);
        free(c->filters[i].object);
    }
    free(c->filters);
    xpc_release(c->connection);
    free(c);
}

static void
observe(struct client *c, xpc_object_t message)
{
    if (c->count == c->capacity) {
        c->capacity = c->capacity ? c->capacity * 2 : 8;
        c->filters = realloc(c->filters, c->capacity * sizeof(*c->filters));
    }
    c->filters[c->count++] = (struct filter){
        .id = xpc_dictionary_get_int64(message, "id"),
        .name = copy_string(message, "name"),
        .object = copy_string(message, "object"),
    };
}

static void
unobserve(struct client *c, int64_t id)
{
    size_t k = 0;
    for (size_t i = 0; i < c->count; i++) {
        if (c->filters[i].id == id) {
            free(c->filters[i].name);
            free(c->filters[i].object);
        } else {
            c->filters[k++] = c->filters[i];
        }
    }
    c->count = k;
}

static void
post(xpc_object_t message)
{
    const char *name = xpc_dictionary_get_string(message, "name");
    if (!name)
        return;
    const char *object = xpc_dictionary_get_string(message, "object");
    size_t length = 0;
    const void *info = xpc_dictionary_get_data(message, "userInfo", &length);
    xpc_object_t note = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(note, "op", "notification");
    xpc_dictionary_set_string(note, "name", name);
    if (object)
        xpc_dictionary_set_string(note, "object", object);
    if (info)
        xpc_dictionary_set_data(note, "userInfo", info, length);
    for (struct client *c = clients; c; c = c->next) {
        for (size_t i = 0; i < c->count; i++) {
            if (matches(&c->filters[i], name, object)) {
                xpc_connection_send_message(c->connection, note);
                break;
            }
        }
    }
    xpc_release(note);
}

static void
accept_client(xpc_connection_t connection)
{
    struct client *c = calloc(1, sizeof(*c));
    c->connection = (xpc_connection_t)xpc_retain(connection);
    c->next = clients;
    clients = c;
    xpc_connection_set_target_queue(connection, queue);
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_ERROR) {
            if (event == XPC_ERROR_CONNECTION_INVALID)
                drop(c);
            return;
        }
        if (xpc_get_type(event) != XPC_TYPE_DICTIONARY)
            return;
        const char *op = xpc_dictionary_get_string(event, "op");
        if (!op)
            return;
        if (!strcmp(op, "observe"))
            observe(c, event);
        else if (!strcmp(op, "unobserve"))
            unobserve(c, xpc_dictionary_get_int64(event, "id"));
        else if (!strcmp(op, "post"))
            post(event);
    });
    xpc_connection_resume(connection);
}

int
main(void)
{
    queue = dispatch_queue_create("org.finch.distnoted", DISPATCH_QUEUE_SERIAL);
    xpc_connection_t listener = xpc_connection_create_mach_service(SERVICE, queue, XPC_CONNECTION_MACH_SERVICE_LISTENER);
    xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
        if (xpc_get_type(peer) == XPC_TYPE_CONNECTION)
            accept_client((xpc_connection_t)peer);
    });
    xpc_connection_resume(listener);
    dispatch_main();
}
