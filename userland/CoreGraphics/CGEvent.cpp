/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Quartz Event Services: CGEvent (events as values: keyboard, mouse and scroll events,
 * their fields, flags and locations), CGEventSource (the user's input state, from the
 * window server), and posting events, which the window server takes as it takes the
 * keyboard and mouse. Event taps need the user's permission to monitor input, which
 * Finch doesn't grant to apps yet, so creating one fails as it does on macOS without
 * that permission (NULL). Also the screen and window images (CGWindowListCreateImage,
 * CGDisplayCreateImage), from the window server's composited screen.
 */
#include "CGInternal.h"
#include "../WindowServer/FinchWSProtocol.h"
#include <CoreGraphics/CGEvent.h>
#include <CoreGraphics/CGEventSource.h>
#include <math.h>
#include <stdarg.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

extern "C" {
void FWSPostEvent(const FWSEvent *e);
bool FWSGetInputState(FWSInputState *out);
bool FWSGetDisplayInfo(FWSDisplayInfo *out);
CGImageRef FWSCopyScreenImage(void);
}

enum { kFields = 256 };

struct CGEventSourceObj {
    CGRuntimeBase base;
    CGEventSourceStateID state;
    CGEventSourceKeyboardType keyboardType;
    double pixelsPerLine;
    int64_t userData;
    CFTimeInterval suppression;
    CGEventFilterMask filters[3];
};

struct CGEventObj {
    CGRuntimeBase base;
    CGEventType type;
    CGEventFlags flags;
    CGPoint location;
    CGEventTimestamp timestamp;
    double fields[kFields];
    UniChar text[20];
    UniCharCount textLength;
    CGEventSourceStateID state;
};

static double
seconds_since_boot(void)
{
    return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9;
}

/* --- sources --- */

static CFStringRef
source_desc(CFTypeRef cf)
{
    return CGTypeCopyDescriptionPrefix(cf, "CGEventSource");
}

static const CGRuntimeClass source_class = {0, "CGEventSource", NULL, NULL, NULL, NULL, NULL, NULL, source_desc, NULL, NULL, 0};
static CFTypeID source_type;

extern "C" CFTypeID
CGEventSourceGetTypeID(void)
{
    return CGTypeRegister(&source_class, &source_type);
}

extern "C" CGEventSourceRef
CGEventSourceCreate(CGEventSourceStateID stateID)
{
    if (stateID != kCGEventSourceStatePrivate && stateID != kCGEventSourceStateCombinedSessionState &&
        stateID != kCGEventSourceStateHIDSystemState)
        return NULL;
    CGEventSourceObj *s = (CGEventSourceObj *)CGTypeCreateInstance(CGEventSourceGetTypeID(), sizeof(CGEventSourceObj));
    s->state = stateID;
    if (stateID == kCGEventSourceStatePrivate) { /* a state of its own, as Apple's gives each */
        static _Atomic int32_t next = 0;
        if (!next)
            next = (int32_t)(arc4random() & 0x3fffffff) + 1;
        s->state = (CGEventSourceStateID)next++;
    }
    s->keyboardType = 40; /* ANSI */
    s->pixelsPerLine = 10;
    s->suppression = 0.25;
    for (int i = 0; i < 3; i++)
        s->filters[i] = kCGEventFilterMaskPermitAllEvents;
    return (CGEventSourceRef)s;
}

#define SRC(s) ((CGEventSourceObj *)(s))

extern "C" CGEventSourceKeyboardType CGEventSourceGetKeyboardType(CGEventSourceRef s) { return s ? SRC(s)->keyboardType : 40; }
extern "C" void CGEventSourceSetKeyboardType(CGEventSourceRef s, CGEventSourceKeyboardType t) { if (s) SRC(s)->keyboardType = t; }
extern "C" double CGEventSourceGetPixelsPerLine(CGEventSourceRef s) { return s ? SRC(s)->pixelsPerLine : 10; }
extern "C" void CGEventSourceSetPixelsPerLine(CGEventSourceRef s, double p) { if (s) SRC(s)->pixelsPerLine = p; }
extern "C" CGEventSourceStateID CGEventSourceGetSourceStateID(CGEventSourceRef s) { return s ? SRC(s)->state : kCGEventSourceStatePrivate; }
extern "C" int64_t CGEventSourceGetUserData(CGEventSourceRef s) { return s ? SRC(s)->userData : 0; }
extern "C" void CGEventSourceSetUserData(CGEventSourceRef s, int64_t d) { if (s) SRC(s)->userData = d; }
extern "C" CFTimeInterval CGEventSourceGetLocalEventsSuppressionInterval(CGEventSourceRef s) { return s ? SRC(s)->suppression : 0.25; }
extern "C" void CGEventSourceSetLocalEventsSuppressionInterval(CGEventSourceRef s, CFTimeInterval t) { if (s) SRC(s)->suppression = t; }

extern "C" void
CGEventSourceSetLocalEventsFilterDuringSuppressionState(CGEventSourceRef s, CGEventFilterMask filter, CGEventSuppressionState state)
{
    if (s && state < 3)
        SRC(s)->filters[state] = filter;
}

extern "C" CGEventFilterMask
CGEventSourceGetLocalEventsFilterDuringSuppressionState(CGEventSourceRef s, CGEventSuppressionState state)
{
    return s && state < 3 ? SRC(s)->filters[state] : kCGEventFilterMaskPermitAllEvents;
}

static bool
input_state(CGEventSourceStateID state, FWSInputState *st)
{
    bool shared = state == kCGEventSourceStateCombinedSessionState || state == kCGEventSourceStateHIDSystemState;
    if (!shared || !FWSGetInputState(st)) {
        memset(st, 0, sizeof *st);
        return false;
    }
    return true;
}

extern "C" CGEventFlags
CGEventSourceFlagsState(CGEventSourceStateID state)
{
    FWSInputState st;
    input_state(state, &st);
    return (CGEventFlags)st.modifiers;
}

extern "C" bool
CGEventSourceButtonState(CGEventSourceStateID state, CGMouseButton button)
{
    FWSInputState st;
    input_state(state, &st);
    return button < 64 && (st.buttons >> button) & 1;
}

extern "C" bool
CGEventSourceKeyState(CGEventSourceStateID state, CGKeyCode key)
{
    FWSInputState st;
    input_state(state, &st);
    return key < 128 && (st.keys[key / 8] >> (key % 8)) & 1;
}

extern "C" CFTimeInterval
CGEventSourceSecondsSinceLastEventType(CGEventSourceStateID state, CGEventType type)
{
    FWSInputState st;
    if (!input_state(state, &st) || st.last_event <= 0)
        return seconds_since_boot();
    return seconds_since_boot() - st.last_event;
}

extern "C" uint32_t
CGEventSourceCounterForEventType(CGEventSourceStateID state, CGEventType type)
{
    FWSInputState st;
    input_state(state, &st);
    if (type == kCGAnyInputEventType) {
        uint32_t n = 0;
        for (int i = 0; i < 32; i++)
            n += st.counts[i];
        return n;
    }
    return type < 32 ? st.counts[type] : 0;
}

/* --- events --- */

static CFStringRef
event_desc(CFTypeRef cf)
{
    const CGEventObj *e = (const CGEventObj *)cf;
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("<CGEvent %p> type=%u loc=(%g,%g) flags=0x%llx"), cf, (unsigned)e->type,
                                    e->location.x, e->location.y, (unsigned long long)e->flags);
}

static const CGRuntimeClass event_class = {0, "CGEvent", NULL, NULL, NULL, NULL, NULL, NULL, event_desc, NULL, NULL, 0};
static CFTypeID event_type;

extern "C" CFTypeID
CGEventGetTypeID(void)
{
    return CGTypeRegister(&event_class, &event_type);
}

#define EV(e) ((CGEventObj *)(e))

static CGEventObj *
new_event(CGEventSourceRef source, CGEventType type)
{
    CGEventObj *e = (CGEventObj *)CGTypeCreateInstance(CGEventGetTypeID(), sizeof(CGEventObj));
    e->type = type;
    e->timestamp = (CGEventTimestamp)clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    e->state = source ? SRC(source)->state : kCGEventSourceStatePrivate;
    FWSInputState st;
    if (input_state(source ? SRC(source)->state : kCGEventSourceStateHIDSystemState, &st))
        e->location = CGPointMake(st.x, st.y);
    if (source) {
        e->flags = CGEventSourceFlagsState(SRC(source)->state);
        e->fields[kCGEventSourceUserData] = (double)SRC(source)->userData;
        e->fields[kCGEventSourceStateID] = SRC(source)->state;
        e->fields[kCGKeyboardEventKeyboardType] = SRC(source)->keyboardType;
    }
    e->fields[kCGEventSourceUnixProcessID] = getpid();
    return e;
}

extern "C" CGEventRef
CGEventCreate(CGEventSourceRef source)
{
    return (CGEventRef)new_event(source, kCGEventNull);
}

extern "C" CGEventRef
CGEventCreateCopy(CGEventRef event)
{
    if (!event)
        return NULL;
    CGEventObj *e = (CGEventObj *)CGTypeCreateInstance(CGEventGetTypeID(), sizeof(CGEventObj));
    memcpy((char *)e + sizeof(CGRuntimeBase), (const char *)event + sizeof(CGRuntimeBase), sizeof(CGEventObj) - sizeof(CGRuntimeBase));
    return (CGEventRef)e;
}

/* The U.S. layout: a virtual key's character, and with Shift. */
static const struct {
    uint8_t key;
    char plain, shifted;
} us_layout[] = {
    {0, 'a', 'A'},   {1, 's', 'S'},   {2, 'd', 'D'},   {3, 'f', 'F'},   {4, 'h', 'H'},   {5, 'g', 'G'},
    {6, 'z', 'Z'},   {7, 'x', 'X'},   {8, 'c', 'C'},   {9, 'v', 'V'},   {11, 'b', 'B'},  {12, 'q', 'Q'},
    {13, 'w', 'W'},  {14, 'e', 'E'},  {15, 'r', 'R'},  {16, 'y', 'Y'},  {17, 't', 'T'},  {18, '1', '!'},
    {19, '2', '@'},  {20, '3', '#'},  {21, '4', '$'},  {22, '6', '^'},  {23, '5', '%'},  {24, '=', '+'},
    {25, '9', '('},  {26, '7', '&'},  {27, '-', '_'},  {28, '8', '*'},  {29, '0', ')'},  {30, ']', '}'},
    {31, 'o', 'O'},  {32, 'u', 'U'},  {33, '[', '{'},  {34, 'i', 'I'},  {35, 'p', 'P'},  {36, '\r', '\r'},
    {37, 'l', 'L'},  {38, 'j', 'J'},  {39, '\'', '"'}, {40, 'k', 'K'},  {41, ';', ':'},  {42, '\\', '|'},
    {43, ',', '<'},  {44, '/', '?'},  {45, 'n', 'N'},  {46, 'm', 'M'},  {47, '.', '>'},  {48, '\t', '\t'},
    {49, ' ', ' '},  {50, '`', '~'},  {51, 0x08, 0x08}, {53, 0x1b, 0x1b}, {76, 3, 3},
    /* the keypad */
    {65, '.', '.'},  {67, '*', '*'},  {69, '+', '+'},  {71, 0x1b, 0x1b}, {75, '/', '/'}, {78, '-', '-'},
    {81, '=', '='},  {82, '0', '0'},  {83, '1', '1'},  {84, '2', '2'},  {85, '3', '3'},  {86, '4', '4'},
    {87, '5', '5'},  {88, '6', '6'},  {89, '7', '7'},  {91, '8', '8'},  {92, '9', '9'},
};

static void
key_text(CGEventObj *e, CGKeyCode key)
{
    bool shift = (e->flags & kCGEventFlagMaskShift) != 0;
    bool caps = (e->flags & kCGEventFlagMaskAlphaShift) != 0;
    for (size_t i = 0; i < sizeof us_layout / sizeof *us_layout; i++)
        if (us_layout[i].key == key) {
            char c = shift ? us_layout[i].shifted : us_layout[i].plain;
            if (caps && c >= 'a' && c <= 'z')
                c = (char)(c - 32);
            e->text[0] = (UniChar)(unsigned char)c;
            e->textLength = 1;
            return;
        }
    /* function, navigation and arrow keys: the control characters a key event carries */
    static const struct {
        uint8_t key;
        UniChar ch;
    } special[] = {{123, 0x1c}, {124, 0x1d}, {125, 0x1f}, {126, 0x1e}, {115, 0x01}, {119, 0x04}, {116, 0x0b},
                   {121, 0x0c}, {117, 0x7f}, {114, 0x05}, {122, 0x10}, {120, 0x10}, {99, 0x10},  {118, 0x10},
                   {96, 0x10},  {97, 0x10},  {98, 0x10},  {100, 0x10}, {101, 0x10}, {109, 0x10}, {103, 0x10},
                   {111, 0x10}, {105, 0x10}, {107, 0x10}, {113, 0x10}, {106, 0x10}, {64, 0x10},  {79, 0x10},
                   {80, 0x10},  {90, 0x10}};
    for (size_t i = 0; i < sizeof special / sizeof *special; i++)
        if (special[i].key == key) {
            e->text[0] = special[i].ch;
            e->textLength = 1;
            return;
        }
    e->textLength = 0;
}

/* The modifier keys: their flag, and the device-dependent bit for the left or right one. */
static const struct {
    uint8_t key;
    CGEventFlags flag, device;
} modifier_keys[] = {
    {56, kCGEventFlagMaskShift, 0x2},       {60, kCGEventFlagMaskShift, 0x4},
    {59, kCGEventFlagMaskControl, 0x1},     {62, kCGEventFlagMaskControl, 0x2000},
    {58, kCGEventFlagMaskAlternate, 0x20},  {61, kCGEventFlagMaskAlternate, 0x40},
    {55, kCGEventFlagMaskCommand, 0x8},     {54, kCGEventFlagMaskCommand, 0x10},
    {57, kCGEventFlagMaskAlphaShift, 0},    {63, kCGEventFlagMaskSecondaryFn, 0},
};

/* Bit 29, which Apple's sets on every key event it makes (not in CGEventTypes.h). */
static const CGEventFlags kKeyEventMark = 0x20000000;

/* The flags a key carries of itself: the keypad, the function-key row, Help. */
static CGEventFlags
key_flags(CGKeyCode key)
{
    if (key >= 123 && key <= 126)
        return kCGEventFlagMaskNumericPad | kCGEventFlagMaskSecondaryFn;
    if (key == 114)
        return kCGEventFlagMaskHelp | kCGEventFlagMaskSecondaryFn;
    if ((key >= 115 && key <= 122) || key == 96 || key == 97 || key == 98 || key == 99 || key == 100 || key == 101 ||
        key == 103 || key == 105 || key == 106 || key == 107 || key == 109 || key == 111 || key == 113 || key == 64 ||
        key == 79 || key == 80 || key == 90)
        return kCGEventFlagMaskSecondaryFn;
    if (key == 65 || key == 67 || key == 69 || key == 71 || key == 75 || key == 76 || key == 78 || (key >= 81 && key <= 92))
        return kCGEventFlagMaskNumericPad;
    return 0;
}

extern "C" CGEventRef
CGEventCreateKeyboardEvent(CGEventSourceRef source, CGKeyCode virtualKey, bool keyDown)
{
    CGEventObj *e = new_event(source, keyDown ? kCGEventKeyDown : kCGEventKeyUp);
    e->fields[kCGKeyboardEventKeycode] = virtualKey;
    e->flags |= kKeyEventMark | key_flags(virtualKey);
    /* a modifier key changes the flags rather than typing */
    for (size_t i = 0; i < sizeof modifier_keys / sizeof *modifier_keys; i++)
        if (modifier_keys[i].key == virtualKey) {
            e->type = kCGEventFlagsChanged;
            if (keyDown)
                e->flags |= modifier_keys[i].flag | modifier_keys[i].device;
            return (CGEventRef)e;
        }
    key_text(e, virtualKey);
    return (CGEventRef)e;
}

extern "C" CGEventRef
CGEventCreateMouseEvent(CGEventSourceRef source, CGEventType mouseType, CGPoint mouseCursorPosition, CGMouseButton mouseButton)
{
    CGEventObj *e = new_event(source, mouseType);
    e->location = mouseCursorPosition;
    e->fields[kCGMouseEventButtonNumber] = mouseType == kCGEventLeftMouseDown || mouseType == kCGEventLeftMouseUp ||
                                                   mouseType == kCGEventLeftMouseDragged
                                               ? kCGMouseButtonLeft
                                           : mouseType == kCGEventRightMouseDown || mouseType == kCGEventRightMouseUp ||
                                                   mouseType == kCGEventRightMouseDragged
                                               ? kCGMouseButtonRight
                                               : mouseButton;
    /* a button held: down or dragging */
    bool held = mouseType == kCGEventLeftMouseDown || mouseType == kCGEventRightMouseDown || mouseType == kCGEventOtherMouseDown ||
                mouseType == kCGEventLeftMouseDragged || mouseType == kCGEventRightMouseDragged ||
                mouseType == kCGEventOtherMouseDragged;
    e->fields[kCGMouseEventClickState] = held ? 1 : 0;
    e->fields[kCGMouseEventPressure] = held ? 1 : 0;
    return (CGEventRef)e;
}

static CGEventRef
scroll_event(CGEventSourceRef source, CGScrollEventUnit units, uint32_t count, const int32_t *wheels)
{
    CGEventObj *e = new_event(source, kCGEventScrollWheel);
    double ppl = source ? SRC(source)->pixelsPerLine : 10;
    CGEventField line[3] = {kCGScrollWheelEventDeltaAxis1, kCGScrollWheelEventDeltaAxis2, kCGScrollWheelEventDeltaAxis3};
    CGEventField point[3] = {kCGScrollWheelEventPointDeltaAxis1, kCGScrollWheelEventPointDeltaAxis2,
                             kCGScrollWheelEventPointDeltaAxis3};
    CGEventField fixed[3] = {kCGScrollWheelEventFixedPtDeltaAxis1, kCGScrollWheelEventFixedPtDeltaAxis2,
                             kCGScrollWheelEventFixedPtDeltaAxis3};
    for (uint32_t i = 0; i < count && i < 3; i++) {
        double pts = units == kCGScrollEventUnitPixel ? wheels[i] : wheels[i] * ppl;
        double lines = units == kCGScrollEventUnitLine ? wheels[i] : wheels[i] / ppl;
        e->fields[line[i]] = units == kCGScrollEventUnitLine ? wheels[i] : trunc(lines);
        e->fields[point[i]] = pts;
        e->fields[fixed[i]] = lines;
    }
    e->fields[kCGScrollWheelEventIsContinuous] = units == kCGScrollEventUnitPixel ? 1 : 0;
    /* (Apple's carries empty characters, one more than the wheels) */
    e->textLength = count + 1 < 20 ? count + 1 : 20;
    return (CGEventRef)e;
}

extern "C" CGEventRef
CGEventCreateScrollWheelEvent(CGEventSourceRef source, CGScrollEventUnit units, uint32_t wheelCount, int32_t wheel1, ...)
{
    int32_t w[3] = {wheel1, 0, 0};
    va_list ap;
    va_start(ap, wheel1);
    for (uint32_t i = 1; i < wheelCount && i < 3; i++)
        w[i] = va_arg(ap, int32_t);
    va_end(ap);
    return scroll_event(source, units, wheelCount, w);
}

extern "C" CGEventRef
CGEventCreateScrollWheelEvent2(CGEventSourceRef source, CGScrollEventUnit units, uint32_t wheelCount, int32_t wheel1,
                               int32_t wheel2, int32_t wheel3)
{
    int32_t w[3] = {wheel1, wheel2, wheel3};
    return scroll_event(source, units, wheelCount, w);
}

/* As data: a version, then the event's own fields. */
extern "C" CFDataRef
CGEventCreateData(CFAllocatorRef allocator, CGEventRef event)
{
    if (!event)
        return NULL;
    CFMutableDataRef d = CFDataCreateMutable(allocator, 0);
    uint32_t version = 1;
    CFDataAppendBytes(d, (const UInt8 *)&version, 4);
    CFDataAppendBytes(d, (const UInt8 *)event + sizeof(CGRuntimeBase), sizeof(CGEventObj) - sizeof(CGRuntimeBase));
    return d;
}

extern "C" CGEventRef
CGEventCreateFromData(CFAllocatorRef allocator, CFDataRef data)
{
    if (!data || (size_t)CFDataGetLength(data) != 4 + sizeof(CGEventObj) - sizeof(CGRuntimeBase))
        return NULL;
    CGEventObj *e = (CGEventObj *)CGTypeCreateInstance(CGEventGetTypeID(), sizeof(CGEventObj));
    memcpy((char *)e + sizeof(CGRuntimeBase), CFDataGetBytePtr(data) + 4, sizeof(CGEventObj) - sizeof(CGRuntimeBase));
    return (CGEventRef)e;
}

extern "C" CGEventType CGEventGetType(CGEventRef e) { return e ? EV(e)->type : kCGEventNull; }
extern "C" void CGEventSetType(CGEventRef e, CGEventType t) { if (e) EV(e)->type = t; }
extern "C" CGEventTimestamp CGEventGetTimestamp(CGEventRef e) { return e ? EV(e)->timestamp : 0; }
extern "C" void CGEventSetTimestamp(CGEventRef e, CGEventTimestamp t) { if (e) EV(e)->timestamp = t; }
extern "C" CGPoint CGEventGetLocation(CGEventRef e) { return e ? EV(e)->location : CGPointZero; }
extern "C" void CGEventSetLocation(CGEventRef e, CGPoint p) { if (e) EV(e)->location = p; }
extern "C" CGEventFlags CGEventGetFlags(CGEventRef e) { return e ? EV(e)->flags : 0; }

extern "C" void
CGEventSetFlags(CGEventRef e, CGEventFlags flags)
{
    if (!e)
        return;
    EV(e)->flags = flags; /* the characters stay as they were made */
}

/* Bottom-left origin: from the bottom of the main display. */
extern "C" CGPoint
CGEventGetUnflippedLocation(CGEventRef e)
{
    CGPoint p = CGEventGetLocation(e);
    FWSDisplayInfo d;
    if (FWSGetDisplayInfo(&d))
        p.y = d.height - p.y;
    return p;
}

extern "C" int64_t
CGEventGetIntegerValueField(CGEventRef e, CGEventField field)
{
    if (!e || (unsigned)field >= kFields)
        return 0;
    if (field == kCGMouseEventDeltaX || field == kCGMouseEventDeltaY)
        return (int64_t)llround(EV(e)->fields[field]);
    return (int64_t)EV(e)->fields[field];
}

extern "C" void
CGEventSetIntegerValueField(CGEventRef e, CGEventField field, int64_t value)
{
    if (!e || (unsigned)field >= kFields)
        return;
    EV(e)->fields[field] = (double)value;
}

extern "C" double
CGEventGetDoubleValueField(CGEventRef e, CGEventField field)
{
    return e && (unsigned)field < kFields ? EV(e)->fields[field] : 0;
}

extern "C" void
CGEventSetDoubleValueField(CGEventRef e, CGEventField field, double value)
{
    if (e && (unsigned)field < kFields)
        EV(e)->fields[field] = value;
}

extern "C" void
CGEventKeyboardGetUnicodeString(CGEventRef e, UniCharCount maxLength, UniCharCount *actualLength, UniChar *unicodeString)
{
    UniCharCount n = e ? EV(e)->textLength : 0;
    if (actualLength)
        *actualLength = n;
    if (unicodeString)
        memcpy(unicodeString, EV(e)->text, (n < maxLength ? n : maxLength) * sizeof(UniChar));
}

extern "C" void
CGEventKeyboardSetUnicodeString(CGEventRef e, UniCharCount length, const UniChar *unicodeString)
{
    if (!e)
        return;
    UniCharCount n = length < 20 ? length : 20;
    if (unicodeString)
        memcpy(EV(e)->text, unicodeString, n * sizeof(UniChar));
    EV(e)->textLength = unicodeString ? n : 0;
}

extern "C" void
CGEventSetSource(CGEventRef e, CGEventSourceRef source)
{
    if (e && source) {
        EV(e)->state = SRC(source)->state;
        EV(e)->fields[kCGEventSourceStateID] = SRC(source)->state;
        EV(e)->fields[kCGEventSourceUserData] = (double)SRC(source)->userData;
    }
}

extern "C" CGEventSourceRef
CGEventCreateSourceFromEvent(CGEventRef e)
{
    if (!e)
        return NULL;
    /* the event's own source state (a private one stays the same private state) */
    CGEventSourceStateID state = EV(e)->state;
    bool shared = state == kCGEventSourceStateCombinedSessionState || state == kCGEventSourceStateHIDSystemState;
    CGEventSourceRef s = CGEventSourceCreate(shared ? state : kCGEventSourceStateHIDSystemState);
    if (s) {
        SRC(s)->state = state;
        SRC(s)->userData = (int64_t)EV(e)->fields[kCGEventSourceUserData];
    }
    return s;
}

/* --- posting --- */

static void
post(CGEventRef event)
{
    if (!event)
        return;
    CGEventObj *e = EV(event);
    FWSEvent f;
    memset(&f, 0, sizeof f);
    f.type = (uint32_t)e->type;
    f.screen_x = e->location.x;
    f.screen_y = e->location.y;
    f.modifiers = e->flags;
    f.button = (uint32_t)e->fields[kCGMouseEventButtonNumber];
    f.click_count = (uint32_t)e->fields[kCGMouseEventClickState];
    if (e->type == kCGEventScrollWheel) {
        f.delta_y = e->fields[kCGScrollWheelEventPointDeltaAxis1];
        f.delta_x = e->fields[kCGScrollWheelEventPointDeltaAxis2];
    } else {
        f.delta_x = e->fields[kCGMouseEventDeltaX];
        f.delta_y = e->fields[kCGMouseEventDeltaY];
    }
    f.key_code = (uint32_t)e->fields[kCGKeyboardEventKeycode];
    f.is_repeat = (uint32_t)e->fields[kCGKeyboardEventAutorepeat];
    f.length = (uint32_t)(e->textLength < 8 ? e->textLength : 8);
    memcpy(f.characters, e->text, f.length * sizeof(UniChar));
    /* the unmodified characters: as typed without the modifiers */
    CGEventObj plain = *e;
    plain.flags = 0;
    if (e->type == kCGEventKeyDown || e->type == kCGEventKeyUp) {
        key_text(&plain, (CGKeyCode)e->fields[kCGKeyboardEventKeycode]);
        memcpy(f.unmodified, plain.text, (plain.textLength < 8 ? plain.textLength : 8) * sizeof(UniChar));
    }
    FWSPostEvent(&f);
}

extern "C" void CGEventPost(CGEventTapLocation tap, CGEventRef event) { post(event); }
extern "C" void CGEventPostToPSN(void *processSerialNumber, CGEventRef event) { post(event); }
extern "C" void CGEventPostToPid(pid_t pid, CGEventRef event) { post(event); }
extern "C" void CGEventTapPostEvent(CGEventTapProxy proxy, CGEventRef event) { post(event); }

/* The older calls: posting a keyboard or mouse event directly. */
extern "C" CGError
CGPostKeyboardEvent(CGCharCode keyChar, CGKeyCode virtualKey, boolean_t keyDown)
{
    CGEventRef e = CGEventCreateKeyboardEvent(NULL, virtualKey, keyDown);
    post(e);
    CFRelease(e);
    return kCGErrorSuccess;
}

extern "C" CGError
CGPostMouseEvent(CGPoint mouseCursorPosition, boolean_t updateMouseCursorPosition, CGButtonCount buttonCount,
                 boolean_t mouseButtonDown, ...)
{
    CGEventRef e = CGEventCreateMouseEvent(NULL, mouseButtonDown ? kCGEventLeftMouseDown : kCGEventLeftMouseUp,
                                           mouseCursorPosition, kCGMouseButtonLeft);
    post(e);
    CFRelease(e);
    return kCGErrorSuccess;
}

/* --- taps: no input monitoring for apps yet, as on a Mac that hasn't allowed it --- */

extern "C" CFMachPortRef
CGEventTapCreate(CGEventTapLocation tap, CGEventTapPlacement place, CGEventTapOptions options, CGEventMask eventsOfInterest,
                 CGEventTapCallBack callback, void *userInfo)
{
    return NULL;
}

extern "C" CFMachPortRef
CGEventTapCreateForPSN(void *processSerialNumber, CGEventTapPlacement place, CGEventTapOptions options,
                       CGEventMask eventsOfInterest, CGEventTapCallBack callback, void *userInfo)
{
    return NULL;
}

extern "C" CFMachPortRef
CGEventTapCreateForPid(pid_t pid, CGEventTapPlacement place, CGEventTapOptions options, CGEventMask eventsOfInterest,
                       CGEventTapCallBack callback, void *userInfo)
{
    return NULL;
}

extern "C" void CGEventTapEnable(CFMachPortRef tap, bool enable) {}
extern "C" bool CGEventTapIsEnabled(CFMachPortRef tap) { return false; }

extern "C" CGError
CGGetEventTapList(uint32_t maxNumberOfTaps, CGEventTapInformation *tapList, uint32_t *eventTapCount)
{
    if (eventTapCount)
        *eventTapCount = 0;
    return kCGErrorSuccess;
}

extern "C" bool CGPreflightListenEventAccess(void) { return false; }
extern "C" bool CGRequestListenEventAccess(void) { return false; }
extern "C" bool CGPreflightPostEventAccess(void) { return true; }
extern "C" bool CGRequestPostEventAccess(void) { return true; }

/* --- screen and window images --- */

extern "C" bool CGPreflightScreenCaptureAccess(void) { return true; }
extern "C" bool CGRequestScreenCaptureAccess(void) { return true; }

/* The composited screen's pixels under rect (points; CGRectInfinite: all of it). */
static CGImageRef
screen_image(CGRect rect)
{
    CGImageRef screen = FWSCopyScreenImage();
    if (!screen)
        return NULL;
    FWSDisplayInfo d;
    double scale = FWSGetDisplayInfo(&d) && d.scale > 0 ? d.scale : 1;
    if (CGRectIsInfinite(rect) || CGRectIsNull(rect))
        return screen;
    CGRect px = CGRectIntegral(CGRectMake(rect.origin.x * scale, rect.origin.y * scale, rect.size.width * scale,
                                          rect.size.height * scale));
    CGImageRef part = CGImageCreateWithImageInRect(screen, px);
    CGImageRelease(screen);
    return part;
}

extern "C" CGImageRef
CGDisplayCreateImage(CGDirectDisplayID displayID)
{
    return screen_image(CGRectInfinite);
}

extern "C" CGImageRef
CGDisplayCreateImageForRect(CGDirectDisplayID display, CGRect rect)
{
    return screen_image(rect);
}

/* A window's frame from the window list (CGWindowListCopyWindowInfo's bounds). */
static bool
window_frame(CGWindowID window, CGRect *frame)
{
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, window);
    bool found = false;
    if (list && CFArrayGetCount(list)) {
        CFDictionaryRef info = (CFDictionaryRef)CFArrayGetValueAtIndex(list, 0);
        CFDictionaryRef bounds = (CFDictionaryRef)CFDictionaryGetValue(info, kCGWindowBounds);
        found = bounds && CGRectMakeWithDictionaryRepresentation(bounds, frame);
    }
    if (list)
        CFRelease(list);
    return found;
}

/* The screen as composited (other windows included, Finch doesn't composite one window
   alone yet), over the rectangle, or the window's frame for CGRectNull. */
extern "C" CGImageRef
CGWindowListCreateImage(CGRect screenBounds, CGWindowListOption listOption, CGWindowID windowID, CGWindowImageOption imageOption)
{
    CGRect r = screenBounds;
    if (CGRectIsNull(r)) {
        if (windowID == kCGNullWindowID || !window_frame(windowID, &r))
            r = CGRectInfinite;
    }
    return screen_image(r);
}

extern "C" CGImageRef
CGWindowListCreateImageFromArray(CGRect screenBounds, CFArrayRef windowArray, CGWindowImageOption imageOption)
{
    CGRect r = screenBounds;
    if (CGRectIsNull(r)) {
        r = CGRectNull;
        for (CFIndex i = 0; windowArray && i < CFArrayGetCount(windowArray); i++) {
            CGWindowID w = (CGWindowID)(uintptr_t)CFArrayGetValueAtIndex(windowArray, i);
            CGRect f;
            if (window_frame(w, &f))
                r = CGRectUnion(r, f);
        }
        if (CGRectIsNull(r))
            r = CGRectInfinite;
    }
    return screen_image(r);
}

/* --- mirroring: one display, never mirrored --- */

extern "C" boolean_t CGDisplayIsInMirrorSet(CGDirectDisplayID display) { return 0; }
extern "C" boolean_t CGDisplayIsAlwaysInMirrorSet(CGDirectDisplayID display) { return 0; }
extern "C" boolean_t CGDisplayIsInHWMirrorSet(CGDirectDisplayID display) { return 0; }
extern "C" CGDirectDisplayID CGDisplayMirrorsDisplay(CGDirectDisplayID display) { return kCGNullDirectDisplay; }
extern "C" boolean_t CGDisplayUsesOpenGLAcceleration(CGDirectDisplayID display) { return 0; }
extern "C" boolean_t CGDisplayIsStereo(CGDirectDisplayID display) { return 0; }
extern "C" boolean_t CGDisplayIsAsleep(CGDirectDisplayID display) { return 0; }
extern "C" CGDirectDisplayID CGDisplayPrimaryDisplay(CGDirectDisplayID display) { return display; }
