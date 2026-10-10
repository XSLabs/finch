/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Carbon event targets and handlers, and hot keys. A target (the application's, which
 * is also the event dispatcher's here) has a stack of handlers, each for some event
 * classes and kinds; SendEventToEventTarget calls them newest first until one handles
 * the event, and CallNextEventHandler passes it along. Hot keys are registered with the
 * window server, which sends the key to this app whichever app is active; AppKit hands
 * those to FinchHIToolboxHotKey, which sends kEventHotKeyPressed/Released to the hot
 * key's target, as on macOS. Symbolic (system) hot keys: Finch has none yet.
 */
#include <Carbon/Carbon.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

void FWSRegisterHotKey(uint32_t id, uint32_t key_code, uint64_t modifiers);
void FWSUnregisterHotKey(uint32_t id);

struct OpaqueEventHandlerRef {
    struct OpaqueEventHandlerRef *next;
    struct OpaqueEventTargetRef *target;
    EventHandlerUPP handler;
    void *userData;
    EventTypeSpec *types;
    ItemCount count;
};

struct OpaqueEventTargetRef {
    struct OpaqueEventHandlerRef *handlers; /* newest first */
};

struct OpaqueEventHandlerCallRef {
    struct OpaqueEventHandlerRef *at; /* the handler being called */
};

static struct OpaqueEventTargetRef application_target;
static pthread_mutex_t lock = PTHREAD_RECURSIVE_MUTEX_INITIALIZER;

EventTargetRef GetApplicationEventTarget(void) { return &application_target; }
EventTargetRef GetEventDispatcherTarget(void) { return &application_target; }
EventTargetRef GetUserFocusEventTarget(void) { return &application_target; }
EventTargetRef GetEventMonitorTarget(void) { return &application_target; }

OSStatus
InstallEventHandler(EventTargetRef inTarget, EventHandlerUPP inHandler, ItemCount inNumTypes, const EventTypeSpec *inList,
                    void *inUserData, EventHandlerRef *outRef)
{
    if (!inTarget || !inHandler)
        return paramErr;
    EventHandlerRef h = calloc(1, sizeof *h);
    h->target = inTarget;
    h->handler = inHandler;
    h->userData = inUserData;
    h->count = inNumTypes;
    if (inNumTypes) {
        h->types = malloc(inNumTypes * sizeof(EventTypeSpec));
        memcpy(h->types, inList, inNumTypes * sizeof(EventTypeSpec));
    }
    pthread_mutex_lock(&lock);
    h->next = inTarget->handlers;
    inTarget->handlers = h;
    pthread_mutex_unlock(&lock);
    if (outRef)
        *outRef = h;
    return noErr;
}

OSStatus
RemoveEventHandler(EventHandlerRef inHandlerRef)
{
    if (!inHandlerRef)
        return paramErr;
    pthread_mutex_lock(&lock);
    for (EventHandlerRef *p = &inHandlerRef->target->handlers; *p; p = &(*p)->next)
        if (*p == inHandlerRef) {
            *p = inHandlerRef->next;
            break;
        }
    pthread_mutex_unlock(&lock);
    free(inHandlerRef->types);
    free(inHandlerRef);
    return noErr;
}

OSStatus
AddEventTypesToHandler(EventHandlerRef inHandlerRef, ItemCount inNumTypes, const EventTypeSpec *inList)
{
    pthread_mutex_lock(&lock);
    inHandlerRef->types = realloc(inHandlerRef->types, (inHandlerRef->count + inNumTypes) * sizeof(EventTypeSpec));
    memcpy(inHandlerRef->types + inHandlerRef->count, inList, inNumTypes * sizeof(EventTypeSpec));
    inHandlerRef->count += inNumTypes;
    pthread_mutex_unlock(&lock);
    return noErr;
}

OSStatus
RemoveEventTypesFromHandler(EventHandlerRef inHandlerRef, ItemCount inNumTypes, const EventTypeSpec *inList)
{
    pthread_mutex_lock(&lock);
    for (ItemCount i = 0; i < inNumTypes; i++)
        for (ItemCount j = 0; j < inHandlerRef->count; j++)
            if (inHandlerRef->types[j].eventClass == inList[i].eventClass && inHandlerRef->types[j].eventKind == inList[i].eventKind) {
                inHandlerRef->types[j] = inHandlerRef->types[--inHandlerRef->count];
                break;
            }
    pthread_mutex_unlock(&lock);
    return noErr;
}

static Boolean
wants(EventHandlerRef h, EventRef e)
{
    OSType cls = GetEventClass(e);
    UInt32 kind = GetEventKind(e);
    for (ItemCount i = 0; i < h->count; i++)
        if (h->types[i].eventClass == cls && h->types[i].eventKind == kind)
            return true;
    return false;
}

/* Calls the handlers from `from` on until one handles the event. */
static OSStatus
dispatch(EventHandlerRef from, EventRef e)
{
    for (EventHandlerRef h = from; h; h = h->next) {
        if (!wants(h, e))
            continue;
        struct OpaqueEventHandlerCallRef call = {h};
        OSStatus r = h->handler(&call, e, h->userData);
        if (r != eventNotHandledErr)
            return r;
    }
    return eventNotHandledErr;
}

OSStatus
SendEventToEventTarget(EventRef inEvent, EventTargetRef inTarget)
{
    if (!inEvent || !inTarget)
        return paramErr;
    return dispatch(inTarget->handlers, inEvent);
}

OSStatus
SendEventToEventTargetWithOptions(EventRef inEvent, EventTargetRef inTarget, OptionBits inOptions)
{
    return SendEventToEventTarget(inEvent, inTarget);
}

OSStatus
CallNextEventHandler(EventHandlerCallRef inCallRef, EventRef inEvent)
{
    if (!inCallRef || !inCallRef->at)
        return paramErr;
    return dispatch(inCallRef->at->next, inEvent);
}

/* --- hot keys --- */

struct OpaqueEventHotKeyRef {
    struct OpaqueEventHotKeyRef *next;
    uint32_t serial;
    EventHotKeyID hotKeyID;
    EventTargetRef target;
};

static struct OpaqueEventHotKeyRef *hotkeys;
static uint32_t next_serial = 1;

/* Carbon's modifiers as Quartz's flags, which the window server matches. */
static uint64_t
quartz_flags(UInt32 m)
{
    uint64_t f = 0;
    if (m & cmdKey)
        f |= kCGEventFlagMaskCommand;
    if (m & (shiftKey | rightShiftKey))
        f |= kCGEventFlagMaskShift;
    if (m & (optionKey | rightOptionKey))
        f |= kCGEventFlagMaskAlternate;
    if (m & (controlKey | rightControlKey))
        f |= kCGEventFlagMaskControl;
    return f;
}

OSStatus
RegisterEventHotKey(UInt32 inHotKeyCode, UInt32 inHotKeyModifiers, EventHotKeyID inHotKeyID, EventTargetRef inTarget,
                    OptionBits inOptions, EventHotKeyRef *outRef)
{
    if (!outRef)
        return paramErr;
    EventHotKeyRef k = calloc(1, sizeof *k);
    k->hotKeyID = inHotKeyID;
    k->target = inTarget ? inTarget : &application_target;
    pthread_mutex_lock(&lock);
    k->serial = next_serial++;
    k->next = hotkeys;
    hotkeys = k;
    pthread_mutex_unlock(&lock);
    FWSRegisterHotKey(k->serial, inHotKeyCode, quartz_flags(inHotKeyModifiers));
    *outRef = k;
    return noErr;
}

OSStatus
UnregisterEventHotKey(EventHotKeyRef inHotKey)
{
    if (!inHotKey)
        return paramErr;
    pthread_mutex_lock(&lock);
    for (EventHotKeyRef *p = &hotkeys; *p; p = &(*p)->next)
        if (*p == inHotKey) {
            *p = inHotKey->next;
            break;
        }
    pthread_mutex_unlock(&lock);
    FWSUnregisterHotKey(inHotKey->serial);
    free(inHotKey);
    return noErr;
}

/* From AppKit, on the main thread: a hot key the window server sent this app. */
__attribute__((visibility("default"))) void
FinchHIToolboxHotKey(uint32_t serial, bool pressed)
{
    EventHotKeyID id = {0, 0};
    EventTargetRef target = NULL;
    pthread_mutex_lock(&lock);
    for (EventHotKeyRef k = hotkeys; k; k = k->next)
        if (k->serial == serial) {
            id = k->hotKeyID;
            target = k->target;
        }
    pthread_mutex_unlock(&lock);
    if (!target)
        return;
    EventRef e = NULL;
    if (CreateEvent(NULL, kEventClassKeyboard, pressed ? kEventHotKeyPressed : kEventHotKeyReleased, 0, kEventAttributeNone, &e))
        return;
    SetEventParameter(e, kEventParamDirectObject, typeEventHotKeyID, sizeof id, &id);
    SendEventToEventTarget(e, target);
    ReleaseEvent(e);
}

/* System-wide symbolic hot keys (screenshot, Spotlight, ...): none on Finch yet. */
OSStatus
CopySymbolicHotKeys(CFArrayRef *outHotKeyArray)
{
    if (!outHotKeyArray)
        return paramErr;
    *outHotKeyArray = CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
    return noErr;
}

static UInt32 symbolic_mode_depth;
void *PushSymbolicHotKeyMode(OptionBits inOptions) { symbolic_mode_depth++; return (void *)(uintptr_t)symbolic_mode_depth; }
void PopSymbolicHotKeyMode(void *inToken) { if (symbolic_mode_depth) symbolic_mode_depth--; }
OptionBits GetSymbolicHotKeyMode(void) { return symbolic_mode_depth ? kHIHotKeyModeAllDisabled : 0; }
