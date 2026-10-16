/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Local CoreMIDI graph: virtual source/destination traffic and UMP event lists. */
#include <CoreMIDI/MIDIServices.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

struct Capture {
    pthread_mutex_t lock;
    pthread_cond_t ready;
    int calls;
    UInt16 length;
    Byte bytes[16];
    MIDIProtocolID protocol;
    UInt32 word;
};

static struct Capture packetInput = {.lock = PTHREAD_MUTEX_INITIALIZER, .ready = PTHREAD_COND_INITIALIZER};
static struct Capture packetDestination = {.lock = PTHREAD_MUTEX_INITIALIZER, .ready = PTHREAD_COND_INITIALIZER};
static struct Capture eventInput = {.lock = PTHREAD_MUTEX_INITIALIZER, .ready = PTHREAD_COND_INITIALIZER};

static void
record_packet(struct Capture *capture, const MIDIPacketList *list)
{
    pthread_mutex_lock(&capture->lock);
    capture->calls++;
    if (list->numPackets) {
        const MIDIPacket *packet = &list->packet[0];
        capture->length = packet->length;
        memcpy(capture->bytes, packet->data, packet->length < sizeof capture->bytes ? packet->length : sizeof capture->bytes);
    }
    pthread_cond_broadcast(&capture->ready);
    pthread_mutex_unlock(&capture->lock);
}

static void
read_packet(const MIDIPacketList *list, void *refCon, void *sourceRefCon)
{
    record_packet(refCon, list);
}

static void
read_event(const MIDIEventList *list, void *refCon)
{
    struct Capture *capture = refCon;
    pthread_mutex_lock(&capture->lock);
    capture->calls++;
    capture->protocol = list->protocol;
    if (list->numPackets)
        capture->word = list->packet[0].words[0];
    pthread_cond_broadcast(&capture->ready);
    pthread_mutex_unlock(&capture->lock);
}

static int
wait_for(struct Capture *capture)
{
    struct timespec limit;
    clock_gettime(CLOCK_REALTIME, &limit);
    limit.tv_sec += 2;
    pthread_mutex_lock(&capture->lock);
    while (!capture->calls) {
        if (pthread_cond_timedwait(&capture->ready, &capture->lock, &limit) != 0)
            break;
    }
    int ready = capture->calls != 0;
    pthread_mutex_unlock(&capture->lock);
    return ready;
}

static int
has_endpoint(MIDIEndpointRef endpoint, int source)
{
    ItemCount count = source ? MIDIGetNumberOfSources() : MIDIGetNumberOfDestinations();
    for (ItemCount i = 0; i < count; i++)
        if ((source ? MIDIGetSource(i) : MIDIGetDestination(i)) == endpoint)
            return 1;
    return 0;
}

static const char *
framework_image(void)
{
    Dl_info info = {0};
    return dladdr((void *)MIDIClientCreate, &info) ? info.dli_fname : "?";
}

int
main(void)
{
    printf("CoreMIDI: %s\n", framework_image());
    MIDIClientRef client = 0;
    OSStatus createClient = MIDIClientCreate(CFSTR("Finch local graph test"), NULL, NULL, &client);

    MIDIEndpointRef source = 0, destination = 0, eventSource = 0;
    MIDIPortRef input = 0, output = 0, eventPort = 0;
    OSStatus makeSource = MIDISourceCreate(client, CFSTR("Finch Test Source"), &source);
    OSStatus makeInput = MIDIInputPortCreate(client, CFSTR("Finch Test Input"), read_packet, &packetInput, &input);
    OSStatus connect = MIDIPortConnectSource(input, source, NULL);

    union { uint64_t align; Byte bytes[512]; } packetStorage = {0};
    MIDIPacketList *packetList = (MIDIPacketList *)packetStorage.bytes;
    MIDIPacket *packet = MIDIPacketListInit(packetList);
    const Byte note[] = {0x90, 60, 100};
    packet = MIDIPacketListAdd(packetList, sizeof packetStorage, packet, 0, sizeof note, note);
    OSStatus received = packet ? MIDIReceived(source, packetList) : -1;
    int gotInput = wait_for(&packetInput);

    OSStatus makeDestination = MIDIDestinationCreate(client, CFSTR("Finch Test Destination"), read_packet,
                                                     &packetDestination, &destination);
    OSStatus makeOutput = MIDIOutputPortCreate(client, CFSTR("Finch Test Output"), &output);
    OSStatus sent = MIDISend(output, destination, packetList);
    int gotDestination = wait_for(&packetDestination);

    OSStatus makeEventSource = MIDISourceCreateWithProtocol(client, CFSTR("Finch Event Source"), kMIDIProtocol_1_0,
                                                            &eventSource);
    MIDIReceiveBlock eventReader = ^(const MIDIEventList *list, void *sourceRefCon) {
        read_event(list, &eventInput);
    };
    OSStatus makeEventPort = MIDIInputPortCreateWithProtocol(client, CFSTR("Finch Event Input"), kMIDIProtocol_1_0,
                                                             &eventPort, eventReader);
    OSStatus connectEvent = MIDIPortConnectSource(eventPort, eventSource, NULL);
    union { uint64_t align; Byte bytes[128]; } eventStorage = {0};
    MIDIEventList *eventList = (MIDIEventList *)eventStorage.bytes;
    MIDIEventPacket *eventPacket = MIDIEventListInit(eventList, kMIDIProtocol_1_0);
    const UInt32 ump = 0x20903c64;
    eventPacket = MIDIEventListAdd(eventList, sizeof eventStorage, eventPacket, 0, 1, &ump);
    OSStatus receivedEvent = eventPacket ? MIDIReceivedEventList(eventSource, eventList) : -1;
    int gotEvent = wait_for(&eventInput);

    CFStringRef sourceName = NULL;
    OSStatus gotName = MIDIObjectGetStringProperty(source, kMIDIPropertyName, &sourceName);
    char name[128] = "?";
    if (sourceName)
        CFStringGetCString(sourceName, name, sizeof name, kCFStringEncodingUTF8);
    MIDIObjectType sourceType = kMIDIObjectType_Other;
    MIDIObjectRef found = 0;
    SInt32 uniqueID = 0;
    MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &uniqueID);
    OSStatus findSource = MIDIObjectFindByUniqueID(uniqueID, &found, &sourceType);

    printf("client %d source %d input %d connect %d received %d inputData %d %u %02x %02x %02x\n",
           (int)createClient, (int)makeSource, (int)makeInput, (int)connect, (int)received, gotInput,
           (unsigned)packetInput.length, packetInput.bytes[0], packetInput.bytes[1], packetInput.bytes[2]);
    printf("destination %d output %d sent %d destinationData %d %u %02x %02x %02x\n",
           (int)makeDestination, (int)makeOutput, (int)sent, gotDestination,
           (unsigned)packetDestination.length, packetDestination.bytes[0], packetDestination.bytes[1], packetDestination.bytes[2]);
    printf("eventSource %d eventPort %d connect %d received %d eventData %d protocol %d word %08x\n",
           (int)makeEventSource, (int)makeEventPort, (int)connectEvent, (int)receivedEvent, gotEvent,
           (int)eventInput.protocol, eventInput.word);
    printf("name %d %s type %d uniqueLookup %d found %d visible %d %d\n", (int)gotName, name,
           (int)sourceType, (int)findSource, found == source, has_endpoint(source, 1), has_endpoint(destination, 0));

    if (sourceName)
        CFRelease(sourceName);
    if (eventPort)
        MIDIPortDisconnectSource(eventPort, eventSource);
    if (input)
        MIDIPortDisconnectSource(input, source);
    if (eventPort)
        MIDIPortDispose(eventPort);
    if (input)
        MIDIPortDispose(input);
    if (output)
        MIDIPortDispose(output);
    if (source)
        MIDIEndpointDispose(source);
    if (eventSource)
        MIDIEndpointDispose(eventSource);
    if (destination)
        MIDIEndpointDispose(destination);
    if (client)
        MIDIClientDispose(client);
    return 0;
}
