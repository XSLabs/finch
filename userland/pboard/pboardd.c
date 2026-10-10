/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-pboardd: the pasteboard server (Apple's is pboard). It keeps every user's
 * pasteboards (the general one, find, drag, fonts, rulers and named ones) apart, each a
 * list of items whose flavors hold data or a promise of it from the process that wrote
 * them; a read of a promise asks that process for the data, over the connection it
 * wrote with, and keeps what it gives. Clients are CoreFoundation's pasteboard calls
 * (CFPasteboard_Finch.c) under NSPasteboard and the Pasteboard Manager.
 *
 * Requests (XPC dictionaries, "op" and "name"):
 *   clear             a new change count ("seed"); the caller owns it
 *   seed              the current change count
 *   put               a flavor ("item", "type", "data" or none: promised) on the
 *                     caller's change count ("seed"); "stale" if it has moved on
 *   items             [{id, types}] and the change count
 *   get               a flavor's data ("item", "type"): kept, or asked of the owner
 *   release           forget the pasteboard
 * The owner is asked with {op: provide, name, seed, item, type} and replies {data}.
 */
#include <Block.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <xpc/xpc.h>

#define SERVICE "org.finch.pboard"
#define PROVIDE_TIMEOUT (10 * NSEC_PER_SEC)

typedef struct Flavor {
    char *type;
    xpc_object_t data; /* NULL: promised */
    struct Flavor *next;
} Flavor;

typedef struct Item {
    uint64_t id;
    Flavor *flavors; /* in the order written */
    struct Item *next;
} Item;

typedef struct Pasteboard {
    char *key; /* "uid:name" */
    char *name;
    int64_t seed;
    xpc_connection_t owner; /* who wrote the current contents */
    Item *items;
    struct Pasteboard *next;
} Pasteboard;

static Pasteboard *pasteboards;
static int64_t next_seed = 1;
static dispatch_queue_t queue;

static void
free_items(Item *it)
{
    while (it) {
        Item *n = it->next;
        for (Flavor *f = it->flavors; f;) {
            Flavor *fn = f->next;
            free(f->type);
            if (f->data)
                xpc_release(f->data);
            free(f);
            f = fn;
        }
        free(it);
        it = n;
    }
}

/* The caller's pasteboard of this name (its user's: users' pasteboards are apart). */
static Pasteboard *
find(xpc_connection_t peer, const char *name, int make)
{
    char key[1024];
    snprintf(key, sizeof key, "%u:%s", (unsigned)xpc_connection_get_euid(peer), name);
    for (Pasteboard *p = pasteboards; p; p = p->next)
        if (!strcmp(p->key, key))
            return p;
    if (!make)
        return NULL;
    Pasteboard *p = calloc(1, sizeof *p);
    p->key = strdup(key);
    p->name = strdup(name);
    p->next = pasteboards;
    pasteboards = p;
    return p;
}

static Item *
item_of(Pasteboard *p, uint64_t id, int make)
{
    Item **at = &p->items;
    for (; *at; at = &(*at)->next)
        if ((*at)->id == id)
            return *at;
    if (!make)
        return NULL;
    *at = calloc(1, sizeof **at);
    (*at)->id = id;
    return *at;
}

static Flavor *
flavor_of(Item *it, const char *type, int make)
{
    Flavor **at = &it->flavors;
    for (; *at; at = &(*at)->next)
        if (!strcmp((*at)->type, type))
            return *at;
    if (!make)
        return NULL;
    *at = calloc(1, sizeof **at);
    (*at)->type = strdup(type);
    return *at;
}

static void
set_owner(Pasteboard *p, xpc_connection_t owner)
{
    if (p->owner)
        xpc_release(p->owner);
    p->owner = owner ? xpc_retain(owner) : NULL;
}

/* Asks the owner for a promised flavor; answers the reader when it replies (or doesn't). */
static void
ask_owner(Pasteboard *p, Item *it, Flavor *f, xpc_object_t reply, xpc_connection_t reader)
{
    xpc_object_t ask = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(ask, "op", "provide");
    xpc_dictionary_set_string(ask, "name", p->name);
    xpc_dictionary_set_int64(ask, "seed", p->seed);
    xpc_dictionary_set_uint64(ask, "item", it->id);
    xpc_dictionary_set_string(ask, "type", f->type);
    char *key = strdup(p->key), *type = strdup(f->type);
    int64_t seed = p->seed;
    uint64_t id = it->id;
    xpc_retain(reply);
    xpc_retain(reader);
    __block int answered = 0;
    void (^answer)(xpc_object_t data) = ^(xpc_object_t data) {
      if (answered)
          return;
      answered = 1;
      if (data) {
          xpc_dictionary_set_value(reply, "data", data);
          /* (kept: the next reader gets it without asking) */
          for (Pasteboard *q = pasteboards; q; q = q->next)
              if (!strcmp(q->key, key) && q->seed == seed) {
                  Item *i = item_of(q, id, 0);
                  Flavor *fl = i ? flavor_of(i, type, 0) : NULL;
                  if (fl && !fl->data)
                      fl->data = xpc_retain(data);
              }
      }
      xpc_connection_send_message(reader, reply);
      xpc_release(reply);
      xpc_release(reader);
      free(key);
      free(type);
    };
    answer = Block_copy(answer); /* (kept until both its callers have been: a few bytes a read) */
    xpc_connection_send_message_with_reply(p->owner, ask, queue, ^(xpc_object_t r) {
      answer(xpc_get_type(r) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_value(r, "data") : NULL);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, PROVIDE_TIMEOUT), queue, ^{
      answer(NULL);
    });
    xpc_release(ask);
}

static void
handle(xpc_connection_t peer, xpc_object_t msg)
{
    const char *op = xpc_dictionary_get_string(msg, "op"), *name = xpc_dictionary_get_string(msg, "name");
    xpc_object_t reply = xpc_dictionary_create_reply(msg);
    if (!reply)
        return;
    if (!op || !name) {
        xpc_connection_send_message(peer, reply);
        xpc_release(reply);
        return;
    }
    Pasteboard *p = find(peer, name, strcmp(op, "release") != 0);
    if (!strcmp(op, "clear")) {
        free_items(p->items);
        p->items = NULL;
        p->seed = next_seed++;
        set_owner(p, peer);
        xpc_dictionary_set_int64(reply, "seed", p->seed);
    } else if (!strcmp(op, "seed")) {
        xpc_dictionary_set_int64(reply, "seed", p->seed);
    } else if (!strcmp(op, "put")) {
        const char *type = xpc_dictionary_get_string(msg, "type");
        if (xpc_dictionary_get_int64(msg, "seed") != p->seed || !type) {
            xpc_dictionary_set_bool(reply, "stale", true);
        } else {
            Flavor *f = flavor_of(item_of(p, xpc_dictionary_get_uint64(msg, "item"), 1), type, 1);
            xpc_object_t data = xpc_dictionary_get_value(msg, "data");
            if (f->data)
                xpc_release(f->data);
            f->data = data ? xpc_retain(data) : NULL;
        }
    } else if (!strcmp(op, "items")) {
        xpc_dictionary_set_int64(reply, "seed", p->seed);
        xpc_object_t items = xpc_array_create(NULL, 0);
        for (Item *it = p->items; it; it = it->next) {
            xpc_object_t d = xpc_dictionary_create(NULL, NULL, 0);
            xpc_dictionary_set_uint64(d, "id", it->id);
            xpc_object_t types = xpc_array_create(NULL, 0);
            for (Flavor *f = it->flavors; f; f = f->next)
                xpc_array_set_string(types, XPC_ARRAY_APPEND, f->type);
            xpc_dictionary_set_value(d, "types", types);
            xpc_release(types);
            xpc_array_append_value(items, d);
            xpc_release(d);
        }
        xpc_dictionary_set_value(reply, "items", items);
        xpc_release(items);
    } else if (!strcmp(op, "get")) {
        const char *type = xpc_dictionary_get_string(msg, "type");
        Item *it = item_of(p, xpc_dictionary_get_uint64(msg, "item"), 0);
        Flavor *f = it && type ? flavor_of(it, type, 0) : NULL;
        if (f && f->data) {
            xpc_dictionary_set_value(reply, "data", f->data);
        } else if (f && p->owner) {
            ask_owner(p, it, f, reply, peer);
            xpc_release(reply);
            return;
        }
    } else if (!strcmp(op, "release") && p) {
        free_items(p->items);
        p->items = NULL;
        set_owner(p, NULL);
    }
    xpc_connection_send_message(peer, reply);
    xpc_release(reply);
}

int
main(void)
{
    queue = dispatch_queue_create("org.finch.pboardd", DISPATCH_QUEUE_SERIAL);
    xpc_connection_t listener = xpc_connection_create_mach_service(SERVICE, queue, XPC_CONNECTION_MACH_SERVICE_LISTENER);
    xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
      if (xpc_get_type(peer) != XPC_TYPE_CONNECTION)
          return;
      xpc_connection_set_event_handler(peer, ^(xpc_object_t msg) {
        if (xpc_get_type(msg) == XPC_TYPE_DICTIONARY) {
            handle(peer, msg);
        } else if (msg == XPC_ERROR_CONNECTION_INVALID) {
            /* a writer gone: its promises can't be kept */
            for (Pasteboard *p = pasteboards; p; p = p->next)
                if (p->owner == peer)
                    set_owner(p, NULL);
        }
      });
      xpc_connection_resume(peer);
    });
    xpc_connection_resume(listener);
    dispatch_main();
}
