/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* CoreMIDI's per-process graph. Virtual endpoints exchange MIDI data locally. */
#include <CoreMIDI/MIDIServices.h>
#include <Block.h>
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define MAX_OBJECTS 512
#define MAX_CONNECTIONS 1024

const CFStringRef kMIDIPropertyName = NULL;
const CFStringRef kMIDIPropertyManufacturer = NULL;
const CFStringRef kMIDIPropertyModel = NULL;
const CFStringRef kMIDIPropertyUniqueID = NULL;
const CFStringRef kMIDIPropertyOffline = NULL;
const CFStringRef kMIDIPropertyPrivate = NULL;
const CFStringRef kMIDIPropertyDriverOwner = NULL;
const CFStringRef kMIDIPropertyDisplayName = NULL;
const CFStringRef kMIDIPropertyProtocolID = NULL;

static CFStringRef const MIDIKeyName = CFSTR("name");
static CFStringRef const MIDIKeyUniqueID = CFSTR("uniqueID");
static CFStringRef const MIDIKeyOffline = CFSTR("offline");
static CFStringRef const MIDIKeyPrivate = CFSTR("private");
static CFStringRef const MIDIKeyProtocolID = CFSTR("protocolID");
static CFStringRef const MIDIKeyDisplayName = CFSTR("displayName");

enum ObjectKind {
    ObjectClient,
    ObjectInputPort,
    ObjectOutputPort,
    ObjectSource,
    ObjectDestination
};

struct Object {
    MIDIObjectRef id;
    enum ObjectKind kind;
    MIDIClientRef owner;
    CFMutableDictionaryRef properties;
    MIDIProtocolID protocol;
    MIDINotifyProc notifyProc;
    void *notifyRefCon;
    MIDINotifyBlock notifyBlock;
    MIDIReadProc readProc;
    MIDIReadBlock readBlock;
    MIDIReceiveBlock receiveBlock;
    void *readRefCon;
};

struct Connection {
    MIDIEndpointRef source;
    MIDIPortRef port;
    void *refCon;
};

static struct Object objects[MAX_OBJECTS];
static struct Connection connections[MAX_CONNECTIONS];
static pthread_mutex_t graphLock = PTHREAD_MUTEX_INITIALIZER;
static MIDIObjectRef nextObjectID = 0x1000;

static struct Object *
object_locked(MIDIObjectRef id)
{
    for (size_t i = 0; i < MAX_OBJECTS; i++)
        if (objects[i].id == id)
            return &objects[i];
    return NULL;
}

static struct Object *
free_slot_locked(void)
{
    for (size_t i = 0; i < MAX_OBJECTS; i++)
        if (!objects[i].id)
            return &objects[i];
    return NULL;
}

static void
set_property(CFMutableDictionaryRef properties, CFStringRef key, CFTypeRef value)
{
    if (key && value)
        CFDictionarySetValue(properties, key, value);
}

static MIDIObjectRef
create_object_locked(enum ObjectKind kind, MIDIClientRef owner, CFStringRef name, MIDIProtocolID protocol)
{
    struct Object *object = free_slot_locked();
    if (!object)
        return 0;
    memset(object, 0, sizeof *object);
    object->id = nextObjectID++;
    if (!object->id)
        object->id = nextObjectID++;
    object->kind = kind;
    object->owner = owner;
    object->protocol = protocol;
    object->properties = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
                                                   &kCFTypeDictionaryValueCallBacks);
    if (!object->properties) {
        memset(object, 0, sizeof *object);
        return 0;
    }
    set_property(object->properties, MIDIKeyName, name);
    if (kind == ObjectSource || kind == ObjectDestination) {
        SInt32 uniqueID = (SInt32)object->id;
        CFNumberRef unique = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &uniqueID);
        set_property(object->properties, MIDIKeyUniqueID, unique);
        if (unique)
            CFRelease(unique);
        SInt32 offline = 0, isPrivate = 0, protocolValue = (SInt32)protocol;
        CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &offline);
        set_property(object->properties, MIDIKeyOffline, number);
        if (number)
            CFRelease(number);
        number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &isPrivate);
        set_property(object->properties, MIDIKeyPrivate, number);
        if (number)
            CFRelease(number);
        number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &protocolValue);
        set_property(object->properties, MIDIKeyProtocolID, number);
        if (number)
            CFRelease(number);
        set_property(object->properties, MIDIKeyDisplayName, name);
    }
    return object->id;
}

static MIDIObjectType
object_type(enum ObjectKind kind)
{
    switch (kind) {
    case ObjectSource: return kMIDIObjectType_Source;
    case ObjectDestination: return kMIDIObjectType_Destination;
    default: return kMIDIObjectType_Other;
    }
}

struct Notice {
    MIDINotifyProc proc;
    void *refCon;
    MIDINotifyBlock block;
    MIDINotificationMessageID messageID;
    MIDIObjectRef object;
    MIDIObjectType type;
    CFStringRef property;
};

static void
deliver_notice(void *context)
{
    struct Notice *notice = context;
    if (notice->messageID == kMIDIMsgObjectAdded || notice->messageID == kMIDIMsgObjectRemoved) {
        MIDIObjectAddRemoveNotification message = {
            notice->messageID, sizeof message, 0, kMIDIObjectType_Other, notice->object, notice->type
        };
        if (notice->proc)
            notice->proc((const MIDINotification *)&message, notice->refCon);
        if (notice->block)
            notice->block((const MIDINotification *)&message);
    } else if (notice->messageID == kMIDIMsgPropertyChanged) {
        MIDIObjectPropertyChangeNotification message = {
            notice->messageID, sizeof message, notice->object, notice->type, notice->property
        };
        if (notice->proc)
            notice->proc((const MIDINotification *)&message, notice->refCon);
        if (notice->block)
            notice->block((const MIDINotification *)&message);
    } else {
        MIDINotification message = {notice->messageID, sizeof message};
        if (notice->proc)
            notice->proc(&message, notice->refCon);
        if (notice->block)
            notice->block(&message);
    }
    if (notice->property)
        CFRelease(notice->property);
    if (notice->block)
        Block_release(notice->block);
    free(notice);
}

static void
notify_clients(MIDINotificationMessageID messageID, MIDIObjectRef objectID, MIDIObjectType type, CFStringRef property)
{
    struct Notice *notices[MAX_OBJECTS];
    size_t count = 0;
    pthread_mutex_lock(&graphLock);
    for (size_t i = 0; i < MAX_OBJECTS; i++) {
        struct Object *client = &objects[i];
        if (client->kind != ObjectClient || !client->id || (!client->notifyProc && !client->notifyBlock))
            continue;
        struct Notice *notice = calloc(1, sizeof *notice);
        if (!notice)
            continue;
        notice->proc = client->notifyProc;
        notice->refCon = client->notifyRefCon;
        notice->block = client->notifyBlock ? Block_copy(client->notifyBlock) : NULL;
        notice->messageID = messageID;
        notice->object = objectID;
        notice->type = type;
        notice->property = property ? CFRetain(property) : NULL;
        notices[count++] = notice;
    }
    pthread_mutex_unlock(&graphLock);
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
    for (size_t i = 0; i < count; i++)
        dispatch_async_f(queue, notices[i], deliver_notice);
}

static void
remove_object_locked(struct Object *object)
{
    MIDIObjectRef id = object->id;
    if (object->properties)
        CFRelease(object->properties);
    if (object->notifyBlock)
        Block_release(object->notifyBlock);
    if (object->readBlock)
        Block_release(object->readBlock);
    if (object->receiveBlock)
        Block_release(object->receiveBlock);
    for (size_t i = 0; i < MAX_CONNECTIONS; i++)
        if (connections[i].port == id || connections[i].source == id)
            memset(&connections[i], 0, sizeof connections[i]);
    memset(object, 0, sizeof *object);
}

static size_t
packet_list_size(const MIDIPacketList *list)
{
    if (!list)
        return 0;
    const MIDIPacket *packet = &list->packet[0];
    for (UInt32 i = 0; i < list->numPackets; i++)
        packet = MIDIPacketNext(packet);
    return (size_t)((const uint8_t *)packet - (const uint8_t *)list);
}

static size_t
event_list_size(const MIDIEventList *list)
{
    if (!list)
        return 0;
    const MIDIEventPacket *packet = &list->packet[0];
    for (UInt32 i = 0; i < list->numPackets; i++)
        packet = MIDIEventPacketNext(packet);
    return (size_t)((const uint8_t *)packet - (const uint8_t *)list);
}

enum DeliveryKind { DeliveryReadProc, DeliveryReadBlock, DeliveryReceiveBlock };

struct Delivery {
    enum DeliveryKind kind;
    MIDIReadProc readProc;
    MIDIReadBlock readBlock;
    MIDIReceiveBlock receiveBlock;
    void *readRefCon;
    void *connectionRefCon;
    size_t length;
    uint8_t bytes[];
};

static void
deliver_packet(void *context)
{
    struct Delivery *delivery = context;
    if (delivery->kind == DeliveryReadProc)
        delivery->readProc((const MIDIPacketList *)delivery->bytes, delivery->readRefCon, delivery->connectionRefCon);
    else
        delivery->readBlock((const MIDIPacketList *)delivery->bytes, delivery->connectionRefCon);
    if (delivery->readBlock)
        Block_release(delivery->readBlock);
    free(delivery);
}

static void
deliver_event(void *context)
{
    struct Delivery *delivery = context;
    delivery->receiveBlock((const MIDIEventList *)delivery->bytes, delivery->connectionRefCon);
    if (delivery->receiveBlock)
        Block_release(delivery->receiveBlock);
    free(delivery);
}

static struct Delivery *
make_packet_delivery(const MIDIPacketList *list, size_t length, MIDIReadProc proc, MIDIReadBlock block,
                     void *readRefCon, void *connectionRefCon)
{
    if (!length || (!proc && !block) || length > SIZE_MAX - sizeof(struct Delivery))
        return NULL;
    struct Delivery *delivery = calloc(1, sizeof *delivery + length);
    if (!delivery)
        return NULL;
    delivery->kind = proc ? DeliveryReadProc : DeliveryReadBlock;
    delivery->readProc = proc;
    delivery->readBlock = block ? Block_copy(block) : NULL;
    delivery->readRefCon = readRefCon;
    delivery->connectionRefCon = connectionRefCon;
    delivery->length = length;
    memcpy(delivery->bytes, list, length);
    return delivery;
}

static struct Delivery *
make_event_delivery(const MIDIEventList *list, size_t length, MIDIReceiveBlock block, void *connectionRefCon)
{
    if (!length || !block || length > SIZE_MAX - sizeof(struct Delivery))
        return NULL;
    struct Delivery *delivery = calloc(1, sizeof *delivery + length);
    if (!delivery)
        return NULL;
    delivery->kind = DeliveryReceiveBlock;
    delivery->receiveBlock = Block_copy(block);
    delivery->connectionRefCon = connectionRefCon;
    delivery->length = length;
    memcpy(delivery->bytes, list, length);
    return delivery;
}

static MIDIClientRef
create_client(CFStringRef name, MIDINotifyProc proc, void *refCon, MIDINotifyBlock block)
{
    pthread_mutex_lock(&graphLock);
    MIDIObjectRef id = create_object_locked(ObjectClient, 0, name, kMIDIProtocol_1_0);
    struct Object *client = object_locked(id);
    if (client) {
        client->notifyProc = proc;
        client->notifyRefCon = refCon;
        client->notifyBlock = block ? Block_copy(block) : NULL;
    }
    pthread_mutex_unlock(&graphLock);
    return id;
}

OSStatus
MIDIClientCreate(CFStringRef name, MIDINotifyProc notifyProc, void *notifyRefCon, MIDIClientRef *outClient)
{
    if (outClient)
        *outClient = 0;
    if (!outClient)
        return kMIDIUnknownError;
    MIDIClientRef client = create_client(name, notifyProc, notifyRefCon, NULL);
    if (!client)
        return kMIDIUnknownError;
    *outClient = client;
    return noErr;
}

OSStatus
MIDIClientCreateWithBlock(CFStringRef name, MIDIClientRef *outClient, MIDINotifyBlock notifyBlock)
{
    if (outClient)
        *outClient = 0;
    if (!outClient)
        return kMIDIUnknownError;
    MIDIClientRef client = create_client(name, NULL, NULL, notifyBlock);
    if (!client)
        return kMIDIUnknownError;
    *outClient = client;
    return noErr;
}

OSStatus
MIDIClientDispose(MIDIClientRef clientID)
{
    pthread_mutex_lock(&graphLock);
    struct Object *client = object_locked(clientID);
    if (!client || client->kind != ObjectClient) {
        pthread_mutex_unlock(&graphLock);
        return kMIDIInvalidClient;
    }
    for (size_t i = 0; i < MAX_OBJECTS; i++)
        if (objects[i].id && (objects[i].id == clientID || objects[i].owner == clientID))
            remove_object_locked(&objects[i]);
    pthread_mutex_unlock(&graphLock);
    notify_clients(kMIDIMsgSetupChanged, 0, kMIDIObjectType_Other, NULL);
    return noErr;
}

static MIDIObjectRef
create_port(MIDIClientRef clientID, CFStringRef name, enum ObjectKind kind, MIDIProtocolID protocol,
            MIDIReadProc proc, MIDIReadBlock readBlock, MIDIReceiveBlock receiveBlock, void *refCon)
{
    pthread_mutex_lock(&graphLock);
    struct Object *client = object_locked(clientID);
    if (!client || client->kind != ObjectClient) {
        pthread_mutex_unlock(&graphLock);
        return 0;
    }
    MIDIObjectRef id = create_object_locked(kind, clientID, name, protocol);
    struct Object *port = object_locked(id);
    if (port) {
        port->readProc = proc;
        port->readBlock = readBlock ? Block_copy(readBlock) : NULL;
        port->receiveBlock = receiveBlock ? Block_copy(receiveBlock) : NULL;
        port->readRefCon = refCon;
    }
    pthread_mutex_unlock(&graphLock);
    return id;
}

OSStatus
MIDIInputPortCreate(MIDIClientRef client, CFStringRef portName, MIDIReadProc readProc, void *refCon, MIDIPortRef *outPort)
{
    if (outPort)
        *outPort = 0;
    if (!outPort)
        return kMIDIUnknownError;
    MIDIPortRef port = create_port(client, portName, ObjectInputPort, kMIDIProtocol_1_0, readProc, NULL, NULL, refCon);
    if (!port)
        return kMIDIInvalidClient;
    *outPort = port;
    return noErr;
}

OSStatus
MIDIInputPortCreateWithBlock(MIDIClientRef client, CFStringRef portName, MIDIPortRef *outPort, MIDIReadBlock readBlock)
{
    if (outPort)
        *outPort = 0;
    if (!outPort)
        return kMIDIUnknownError;
    MIDIPortRef port = create_port(client, portName, ObjectInputPort, kMIDIProtocol_1_0, NULL, readBlock, NULL, NULL);
    if (!port)
        return kMIDIInvalidClient;
    *outPort = port;
    return noErr;
}

OSStatus
MIDIInputPortCreateWithProtocol(MIDIClientRef client, CFStringRef portName, MIDIProtocolID protocol,
                                MIDIPortRef *outPort, MIDIReceiveBlock receiveBlock)
{
    if (outPort)
        *outPort = 0;
    if (!outPort || (protocol != kMIDIProtocol_1_0 && protocol != kMIDIProtocol_2_0))
        return kMIDIUnknownError;
    MIDIPortRef port = create_port(client, portName, ObjectInputPort, protocol, NULL, NULL, receiveBlock, NULL);
    if (!port)
        return kMIDIInvalidClient;
    *outPort = port;
    return noErr;
}

OSStatus
MIDIOutputPortCreate(MIDIClientRef client, CFStringRef portName, MIDIPortRef *outPort)
{
    if (outPort)
        *outPort = 0;
    if (!outPort)
        return kMIDIUnknownError;
    MIDIPortRef port = create_port(client, portName, ObjectOutputPort, kMIDIProtocol_1_0, NULL, NULL, NULL, NULL);
    if (!port)
        return kMIDIInvalidClient;
    *outPort = port;
    return noErr;
}

OSStatus
MIDIPortDispose(MIDIPortRef portID)
{
    pthread_mutex_lock(&graphLock);
    struct Object *port = object_locked(portID);
    if (!port || (port->kind != ObjectInputPort && port->kind != ObjectOutputPort)) {
        pthread_mutex_unlock(&graphLock);
        return kMIDIInvalidPort;
    }
    remove_object_locked(port);
    pthread_mutex_unlock(&graphLock);
    return noErr;
}

static MIDIObjectRef
create_endpoint(MIDIClientRef clientID, CFStringRef name, enum ObjectKind kind, MIDIProtocolID protocol,
                MIDIReadProc proc, MIDIReadBlock readBlock, MIDIReceiveBlock receiveBlock, void *refCon)
{
    pthread_mutex_lock(&graphLock);
    struct Object *client = object_locked(clientID);
    if (!client || client->kind != ObjectClient) {
        pthread_mutex_unlock(&graphLock);
        return 0;
    }
    MIDIObjectRef id = create_object_locked(kind, clientID, name, protocol);
    struct Object *endpoint = object_locked(id);
    if (endpoint) {
        endpoint->readProc = proc;
        endpoint->readBlock = readBlock ? Block_copy(readBlock) : NULL;
        endpoint->receiveBlock = receiveBlock ? Block_copy(receiveBlock) : NULL;
        endpoint->readRefCon = refCon;
    }
    pthread_mutex_unlock(&graphLock);
    if (id)
        notify_clients(kMIDIMsgObjectAdded, id, object_type(kind), NULL);
    return id;
}

OSStatus
MIDISourceCreate(MIDIClientRef client, CFStringRef name, MIDIEndpointRef *outSource)
{
    if (outSource)
        *outSource = 0;
    if (!outSource)
        return kMIDIUnknownError;
    MIDIEndpointRef source = create_endpoint(client, name, ObjectSource, kMIDIProtocol_1_0, NULL, NULL, NULL, NULL);
    if (!source)
        return kMIDIInvalidClient;
    *outSource = source;
    return noErr;
}

OSStatus
MIDISourceCreateWithProtocol(MIDIClientRef client, CFStringRef name, MIDIProtocolID protocol, MIDIEndpointRef *outSource)
{
    if (outSource)
        *outSource = 0;
    if (!outSource || (protocol != kMIDIProtocol_1_0 && protocol != kMIDIProtocol_2_0))
        return kMIDIUnknownError;
    MIDIEndpointRef source = create_endpoint(client, name, ObjectSource, protocol, NULL, NULL, NULL, NULL);
    if (!source)
        return kMIDIInvalidClient;
    *outSource = source;
    return noErr;
}

OSStatus
MIDIDestinationCreate(MIDIClientRef client, CFStringRef name, MIDIReadProc readProc, void *refCon,
                      MIDIEndpointRef *outDestination)
{
    if (outDestination)
        *outDestination = 0;
    if (!outDestination)
        return kMIDIUnknownError;
    MIDIEndpointRef destination = create_endpoint(client, name, ObjectDestination, kMIDIProtocol_1_0,
                                                   readProc, NULL, NULL, refCon);
    if (!destination)
        return kMIDIInvalidClient;
    *outDestination = destination;
    return noErr;
}

OSStatus
MIDIDestinationCreateWithBlock(MIDIClientRef client, CFStringRef name, MIDIEndpointRef *outDestination,
                               MIDIReadBlock readBlock)
{
    if (outDestination)
        *outDestination = 0;
    if (!outDestination)
        return kMIDIUnknownError;
    MIDIEndpointRef destination = create_endpoint(client, name, ObjectDestination, kMIDIProtocol_1_0,
                                                   NULL, readBlock, NULL, NULL);
    if (!destination)
        return kMIDIInvalidClient;
    *outDestination = destination;
    return noErr;
}

OSStatus
MIDIDestinationCreateWithProtocol(MIDIClientRef client, CFStringRef name, MIDIProtocolID protocol,
                                  MIDIEndpointRef *outDestination, MIDIReceiveBlock receiveBlock)
{
    if (outDestination)
        *outDestination = 0;
    if (!outDestination || (protocol != kMIDIProtocol_1_0 && protocol != kMIDIProtocol_2_0))
        return kMIDIUnknownError;
    MIDIEndpointRef destination = create_endpoint(client, name, ObjectDestination, protocol,
                                                   NULL, NULL, receiveBlock, NULL);
    if (!destination)
        return kMIDIInvalidClient;
    *outDestination = destination;
    return noErr;
}

OSStatus
MIDIEndpointDispose(MIDIEndpointRef endpointID)
{
    pthread_mutex_lock(&graphLock);
    struct Object *endpoint = object_locked(endpointID);
    if (!endpoint || (endpoint->kind != ObjectSource && endpoint->kind != ObjectDestination)) {
        pthread_mutex_unlock(&graphLock);
        return kMIDIUnknownEndpoint;
    }
    MIDIObjectType type = object_type(endpoint->kind);
    remove_object_locked(endpoint);
    pthread_mutex_unlock(&graphLock);
    notify_clients(kMIDIMsgObjectRemoved, endpointID, type, NULL);
    return noErr;
}

OSStatus
MIDIPortConnectSource(MIDIPortRef portID, MIDIEndpointRef sourceID, void *connRefCon)
{
    pthread_mutex_lock(&graphLock);
    struct Object *port = object_locked(portID), *source = object_locked(sourceID);
    if (!port || port->kind != ObjectInputPort) {
        pthread_mutex_unlock(&graphLock);
        return kMIDIInvalidPort;
    }
    if (!source || (source->kind != ObjectSource && source->kind != ObjectDestination)) {
        pthread_mutex_unlock(&graphLock);
        return kMIDIUnknownEndpoint;
    }
    if (source->kind != ObjectSource) {
        pthread_mutex_unlock(&graphLock);
        return kMIDIWrongEndpointType;
    }
    struct Connection *freeConnection = NULL;
    for (size_t i = 0; i < MAX_CONNECTIONS; i++) {
        if (connections[i].port == portID && connections[i].source == sourceID) {
            connections[i].refCon = connRefCon;
            pthread_mutex_unlock(&graphLock);
            return noErr;
        }
        if (!connections[i].port && !freeConnection)
            freeConnection = &connections[i];
    }
    if (!freeConnection) {
        pthread_mutex_unlock(&graphLock);
        return kMIDIUnknownError;
    }
    *freeConnection = (struct Connection){sourceID, portID, connRefCon};
    pthread_mutex_unlock(&graphLock);
    return noErr;
}

OSStatus
MIDIPortDisconnectSource(MIDIPortRef portID, MIDIEndpointRef sourceID)
{
    pthread_mutex_lock(&graphLock);
    struct Object *port = object_locked(portID);
    if (!port || port->kind != ObjectInputPort) {
        pthread_mutex_unlock(&graphLock);
        return kMIDIInvalidPort;
    }
    for (size_t i = 0; i < MAX_CONNECTIONS; i++) {
        if (connections[i].port == portID && connections[i].source == sourceID) {
            memset(&connections[i], 0, sizeof connections[i]);
            pthread_mutex_unlock(&graphLock);
            return noErr;
        }
    }
    pthread_mutex_unlock(&graphLock);
    return kMIDINoConnection;
}

static OSStatus
deliver_from_source(MIDIEndpointRef sourceID, const MIDIPacketList *packetList, const MIDIEventList *eventList)
{
    size_t length = packetList ? packet_list_size(packetList) : event_list_size(eventList);
    if (!length)
        return kMIDIUnknownError;
    struct Delivery *deliveries[MAX_CONNECTIONS];
    size_t count = 0;
    pthread_mutex_lock(&graphLock);
    struct Object *source = object_locked(sourceID);
    if (!source || source->kind != ObjectSource) {
        pthread_mutex_unlock(&graphLock);
        return kMIDIUnknownEndpoint;
    }
    for (size_t i = 0; i < MAX_CONNECTIONS; i++) {
        if (connections[i].source != sourceID)
            continue;
        struct Object *port = object_locked(connections[i].port);
        if (!port || port->kind != ObjectInputPort)
            continue;
        struct Delivery *delivery = NULL;
        if (packetList) {
            if (port->readProc || port->readBlock)
                delivery = make_packet_delivery(packetList, length, port->readProc, port->readBlock,
                                                 port->readRefCon, connections[i].refCon);
        } else if (port->receiveBlock && port->protocol == eventList->protocol) {
            delivery = make_event_delivery(eventList, length, port->receiveBlock, connections[i].refCon);
        }
        if (delivery)
            deliveries[count++] = delivery;
    }
    pthread_mutex_unlock(&graphLock);
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
    for (size_t i = 0; i < count; i++) {
        if (deliveries[i]->kind == DeliveryReceiveBlock)
            dispatch_async_f(queue, deliveries[i], deliver_event);
        else
            dispatch_async_f(queue, deliveries[i], deliver_packet);
    }
    return noErr;
}

OSStatus
MIDIReceived(MIDIEndpointRef source, const MIDIPacketList *packetList)
{
    return deliver_from_source(source, packetList, NULL);
}

OSStatus
MIDIReceivedEventList(MIDIEndpointRef source, const MIDIEventList *eventList)
{
    return deliver_from_source(source, NULL, eventList);
}

static OSStatus
send_to_destination(MIDIPortRef portID, MIDIEndpointRef destinationID, const MIDIPacketList *packetList,
                    const MIDIEventList *eventList)
{
    if ((!packetList && !eventList) || (packetList && eventList))
        return kMIDIUnknownError;
    size_t length = packetList ? packet_list_size(packetList) : event_list_size(eventList);
    if (!length)
        return kMIDIUnknownError;
    struct Delivery *delivery = NULL;
    Boolean hasReceiver = false;
    pthread_mutex_lock(&graphLock);
    struct Object *port = object_locked(portID), *destination = object_locked(destinationID);
    if (!port || port->kind != ObjectOutputPort) {
        pthread_mutex_unlock(&graphLock);
        return kMIDIInvalidPort;
    }
    if (!destination || (destination->kind != ObjectSource && destination->kind != ObjectDestination)) {
        pthread_mutex_unlock(&graphLock);
        return kMIDIUnknownEndpoint;
    }
    if (destination->kind != ObjectDestination) {
        pthread_mutex_unlock(&graphLock);
        return kMIDIWrongEndpointType;
    }
    if (packetList && (destination->readProc || destination->readBlock)) {
        hasReceiver = true;
        delivery = make_packet_delivery(packetList, length, destination->readProc, destination->readBlock,
                                        destination->readRefCon, NULL);
    } else if (eventList && destination->receiveBlock) {
        hasReceiver = true;
        if (destination->protocol == eventList->protocol) {
            delivery = make_event_delivery(eventList, length, destination->receiveBlock, NULL);
        }
    }
    pthread_mutex_unlock(&graphLock);
    if (hasReceiver && !delivery)
        return kMIDIWrongEndpointType;
    if (delivery) {
        dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
        dispatch_async_f(queue, delivery, delivery->kind == DeliveryReceiveBlock ? deliver_event : deliver_packet);
    }
    return noErr;
}

OSStatus
MIDISend(MIDIPortRef port, MIDIEndpointRef destination, const MIDIPacketList *packetList)
{
    return send_to_destination(port, destination, packetList, NULL);
}

OSStatus
MIDISendEventList(MIDIPortRef port, MIDIEndpointRef destination, const MIDIEventList *eventList)
{
    return send_to_destination(port, destination, NULL, eventList);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"

MIDIEventPacket *
MIDIEventListInit(MIDIEventList *eventList, MIDIProtocolID protocol)
{
    if (!eventList || (protocol != kMIDIProtocol_1_0 && protocol != kMIDIProtocol_2_0))
        return NULL;
    eventList->protocol = protocol;
    eventList->numPackets = 0;
    return &eventList->packet[0];
}

MIDIEventPacket *
MIDIEventListAdd(MIDIEventList *eventList, ByteCount listSize, MIDIEventPacket *current,
                 MIDITimeStamp timestamp, ByteCount wordCount, const UInt32 *words)
{
    if (!eventList || !current || !words || wordCount == 0 || wordCount > 4 || listSize > 65536)
        return NULL;
    size_t offset = eventList->numPackets ?
        (size_t)((uint8_t *)MIDIEventPacketNext(current) - (uint8_t *)eventList) : offsetof(MIDIEventList, packet);
    size_t packetSize = offsetof(MIDIEventPacket, words) + wordCount * sizeof(UInt32);
    if (offset > listSize || packetSize > listSize - offset)
        return NULL;
    MIDIEventPacket *packet = (MIDIEventPacket *)((uint8_t *)eventList + offset);
    packet->timeStamp = timestamp;
    packet->wordCount = (UInt32)wordCount;
    memcpy(packet->words, words, wordCount * sizeof(UInt32));
    eventList->numPackets++;
    return packet;
}

MIDIPacket *
MIDIPacketListInit(MIDIPacketList *packetList)
{
    if (!packetList)
        return NULL;
    packetList->numPackets = 0;
    return &packetList->packet[0];
}

MIDIPacket *
MIDIPacketListAdd(MIDIPacketList *packetList, ByteCount listSize, MIDIPacket *current,
                  MIDITimeStamp timestamp, ByteCount dataLength, const Byte *data)
{
    if (!packetList || !current || !data || dataLength == 0 || dataLength > UINT16_MAX || listSize > 65536)
        return NULL;
    size_t offset = packetList->numPackets ?
        (size_t)((uint8_t *)MIDIPacketNext(current) - (uint8_t *)packetList) : offsetof(MIDIPacketList, packet);
    size_t packetSize = (offsetof(MIDIPacket, data) + dataLength + 3) & ~(size_t)3;
    if (offset > listSize || packetSize > listSize - offset)
        return NULL;
    MIDIPacket *packet = (MIDIPacket *)((uint8_t *)packetList + offset);
    packet->timeStamp = timestamp;
    packet->length = (UInt16)dataLength;
    memcpy(packet->data, data, dataLength);
    packetList->numPackets++;
    return packet;
}

#pragma clang diagnostic pop

static ItemCount
count_endpoints(enum ObjectKind kind)
{
    ItemCount count = 0;
    pthread_mutex_lock(&graphLock);
    for (size_t i = 0; i < MAX_OBJECTS; i++)
        if (objects[i].id && objects[i].kind == kind)
            count++;
    pthread_mutex_unlock(&graphLock);
    return count;
}

static MIDIEndpointRef
endpoint_at(enum ObjectKind kind, ItemCount index)
{
    MIDIEndpointRef endpoint = 0;
    pthread_mutex_lock(&graphLock);
    for (size_t i = 0; i < MAX_OBJECTS; i++) {
        if (objects[i].id && objects[i].kind == kind) {
            if (!index--) {
                endpoint = objects[i].id;
                break;
            }
        }
    }
    pthread_mutex_unlock(&graphLock);
    return endpoint;
}

ItemCount MIDIGetNumberOfSources(void) { return count_endpoints(ObjectSource); }
ItemCount MIDIGetNumberOfDestinations(void) { return count_endpoints(ObjectDestination); }
MIDIEndpointRef MIDIGetSource(ItemCount index) { return endpoint_at(ObjectSource, index); }
MIDIEndpointRef MIDIGetDestination(ItemCount index) { return endpoint_at(ObjectDestination, index); }
ItemCount MIDIGetNumberOfDevices(void) { return 0; }
MIDIDeviceRef MIDIGetDevice(ItemCount index) { return 0; }
ItemCount MIDIGetNumberOfExternalDevices(void) { return 0; }
MIDIDeviceRef MIDIGetExternalDevice(ItemCount index) { return 0; }

OSStatus
MIDIEndpointGetEntity(MIDIEndpointRef endpointID, MIDIEntityRef *outEntity)
{
    pthread_mutex_lock(&graphLock);
    struct Object *endpoint = object_locked(endpointID);
    if (!endpoint || (endpoint->kind != ObjectSource && endpoint->kind != ObjectDestination)) {
        pthread_mutex_unlock(&graphLock);
        if (outEntity)
            *outEntity = 0;
        return kMIDIUnknownEndpoint;
    }
    pthread_mutex_unlock(&graphLock);
    if (outEntity)
        *outEntity = 0;
    return noErr;
}

static OSStatus
get_property(MIDIObjectRef objectID, CFStringRef key, CFTypeRef *outValue, CFTypeID expectedType)
{
    if (outValue)
        *outValue = NULL;
    if (!key || !outValue)
        return kMIDIUnknownProperty;
    pthread_mutex_lock(&graphLock);
    struct Object *object = object_locked(objectID);
    if (!object) {
        pthread_mutex_unlock(&graphLock);
        return kMIDIObjectNotFound;
    }
    CFTypeRef value = CFDictionaryGetValue(object->properties, key);
    if (!value) {
        pthread_mutex_unlock(&graphLock);
        return kMIDIUnknownProperty;
    }
    if (expectedType && CFGetTypeID(value) != expectedType) {
        pthread_mutex_unlock(&graphLock);
        return kMIDIWrongPropertyType;
    }
    *outValue = CFRetain(value);
    pthread_mutex_unlock(&graphLock);
    return noErr;
}

static OSStatus
set_property_value(MIDIObjectRef objectID, CFStringRef key, CFTypeRef value, CFTypeID expectedType)
{
    if (!key || !value || (expectedType && CFGetTypeID(value) != expectedType))
        return kMIDIWrongPropertyType;
    pthread_mutex_lock(&graphLock);
    struct Object *object = object_locked(objectID);
    if (!object) {
        pthread_mutex_unlock(&graphLock);
        return kMIDIObjectNotFound;
    }
    CFDictionarySetValue(object->properties, key, value);
    MIDIObjectType type = object_type(object->kind);
    pthread_mutex_unlock(&graphLock);
    notify_clients(kMIDIMsgPropertyChanged, objectID, type, key);
    return noErr;
}

OSStatus
MIDIObjectGetStringProperty(MIDIObjectRef object, CFStringRef propertyID, CFStringRef *outString)
{
    return get_property(object, propertyID ? propertyID : MIDIKeyName,
                        (CFTypeRef *)outString, CFStringGetTypeID());
}

OSStatus
MIDIObjectSetStringProperty(MIDIObjectRef object, CFStringRef propertyID, CFStringRef value)
{
    return set_property_value(object, propertyID ? propertyID : MIDIKeyName,
                              value, CFStringGetTypeID());
}

OSStatus
MIDIObjectGetIntegerProperty(MIDIObjectRef object, CFStringRef propertyID, SInt32 *outValue)
{
    if (outValue)
        *outValue = 0;
    if (!outValue)
        return kMIDIUnknownProperty;
    CFTypeRef value = NULL;
    OSStatus status = get_property(object, propertyID ? propertyID : MIDIKeyUniqueID,
                                   &value, CFNumberGetTypeID());
    if (status == noErr) {
        CFNumberGetValue(value, kCFNumberSInt32Type, outValue);
        CFRelease(value);
    }
    return status;
}

OSStatus
MIDIObjectSetIntegerProperty(MIDIObjectRef object, CFStringRef propertyID, SInt32 value)
{
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &value);
    if (!number)
        return kMIDIUnknownError;
    OSStatus status = set_property_value(object, propertyID ? propertyID : MIDIKeyUniqueID,
                                         number, CFNumberGetTypeID());
    CFRelease(number);
    return status;
}

OSStatus
MIDIObjectGetDataProperty(MIDIObjectRef object, CFStringRef propertyID, CFDataRef *outData)
{
    return get_property(object, propertyID, (CFTypeRef *)outData, CFDataGetTypeID());
}

OSStatus
MIDIObjectSetDataProperty(MIDIObjectRef object, CFStringRef propertyID, CFDataRef data)
{
    return set_property_value(object, propertyID, data, CFDataGetTypeID());
}

OSStatus
MIDIObjectGetDictionaryProperty(MIDIObjectRef object, CFStringRef propertyID, CFDictionaryRef *outDictionary)
{
    return get_property(object, propertyID, (CFTypeRef *)outDictionary, CFDictionaryGetTypeID());
}

OSStatus
MIDIObjectSetDictionaryProperty(MIDIObjectRef object, CFStringRef propertyID, CFDictionaryRef dictionary)
{
    return set_property_value(object, propertyID, dictionary, CFDictionaryGetTypeID());
}

OSStatus
MIDIObjectGetProperties(MIDIObjectRef objectID, CFPropertyListRef *outProperties, Boolean deep)
{
    if (outProperties)
        *outProperties = NULL;
    if (!outProperties)
        return kMIDIUnknownProperty;
    pthread_mutex_lock(&graphLock);
    struct Object *object = object_locked(objectID);
    if (!object) {
        pthread_mutex_unlock(&graphLock);
        return kMIDIObjectNotFound;
    }
    *outProperties = CFDictionaryCreateCopy(kCFAllocatorDefault, object->properties);
    pthread_mutex_unlock(&graphLock);
    return *outProperties ? noErr : kMIDIUnknownError;
}

OSStatus
MIDIObjectRemoveProperty(MIDIObjectRef objectID, CFStringRef propertyID)
{
    if (!propertyID)
        return kMIDIUnknownProperty;
    pthread_mutex_lock(&graphLock);
    struct Object *object = object_locked(objectID);
    if (!object) {
        pthread_mutex_unlock(&graphLock);
        return kMIDIObjectNotFound;
    }
    if (!CFDictionaryContainsKey(object->properties, propertyID)) {
        pthread_mutex_unlock(&graphLock);
        return kMIDIUnknownProperty;
    }
    CFDictionaryRemoveValue(object->properties, propertyID);
    MIDIObjectType type = object_type(object->kind);
    pthread_mutex_unlock(&graphLock);
    notify_clients(kMIDIMsgPropertyChanged, objectID, type, propertyID);
    return noErr;
}

OSStatus
MIDIObjectFindByUniqueID(MIDIUniqueID uniqueID, MIDIObjectRef *outObject, MIDIObjectType *outType)
{
    if (outObject)
        *outObject = 0;
    pthread_mutex_lock(&graphLock);
    for (size_t i = 0; i < MAX_OBJECTS; i++) {
        struct Object *object = &objects[i];
        if (!object->id)
            continue;
        CFNumberRef number = CFDictionaryGetValue(object->properties, MIDIKeyUniqueID);
        SInt32 value = 0;
        if (number && CFNumberGetValue(number, kCFNumberSInt32Type, &value) && value == uniqueID) {
            if (outObject)
                *outObject = object->id;
            if (outType)
                *outType = object_type(object->kind);
            pthread_mutex_unlock(&graphLock);
            return noErr;
        }
    }
    pthread_mutex_unlock(&graphLock);
    return kMIDIObjectNotFound;
}
