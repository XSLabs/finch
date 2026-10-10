/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-cgevent-test: Quartz Event Services' events as values (types, fields, flags,
 * characters, data round trips) and sources, one result per line so runs against
 * Apple's CoreGraphics and Finch's can be diffed. Nothing is posted, and nothing that
 * depends on the user's input at the moment (the cursor, keys held) is printed.
 */
#include <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>
#include <stdio.h>

static void
show(const char *label, CGEventRef e)
{
    UniChar u[8] = {0};
    UniCharCount n = 0;
    CGEventKeyboardGetUnicodeString(e, 8, &n, u);
    printf("%s: type %u flags 0x%llx keycode %lld text %lu", label, (unsigned)CGEventGetType(e),
           (unsigned long long)CGEventGetFlags(e), (long long)CGEventGetIntegerValueField(e, kCGKeyboardEventKeycode),
           (unsigned long)n);
    for (UniCharCount i = 0; i < n; i++)
        printf(" %04x", u[i]);
    printf(" button %lld clicks %lld pressure %g", (long long)CGEventGetIntegerValueField(e, kCGMouseEventButtonNumber),
           (long long)CGEventGetIntegerValueField(e, kCGMouseEventClickState),
           CGEventGetDoubleValueField(e, kCGMouseEventPressure));
    printf(" scroll %lld/%lld %g %g cont %lld\n", (long long)CGEventGetIntegerValueField(e, kCGScrollWheelEventDeltaAxis1),
           (long long)CGEventGetIntegerValueField(e, kCGScrollWheelEventDeltaAxis2),
           CGEventGetDoubleValueField(e, kCGScrollWheelEventPointDeltaAxis1),
           CGEventGetDoubleValueField(e, kCGScrollWheelEventFixedPtDeltaAxis1),
           (long long)CGEventGetIntegerValueField(e, kCGScrollWheelEventIsContinuous));
}

int
main(void)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    Dl_info info;
    dladdr((void *)CGEventCreate, &info);
    printf("CoreGraphics: %s\n", info.dli_fname);
    printf("type IDs distinct %d\n", CGEventGetTypeID() != CGEventSourceGetTypeID());

    CGEventRef a = CGEventCreateKeyboardEvent(NULL, 0, true);
    show("a down", a);
    CGEventSetFlags(a, kCGEventFlagMaskShift);
    show("a shifted", a);
    CGEventRef up = CGEventCreateKeyboardEvent(NULL, 36, false);
    show("return up", up);
    CGEventRef left = CGEventCreateKeyboardEvent(NULL, 123, true);
    show("left arrow", left);
    UniChar text[] = {'h', 'i'};
    CGEventKeyboardSetUnicodeString(left, 2, text);
    show("set text", left);
    CGEventSetIntegerValueField(left, kCGKeyboardEventKeycode, 1);
    show("set keycode", left);

    CGEventRef m = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, CGPointMake(10, 20), kCGMouseButtonLeft);
    show("left down", m);
    CGPoint p = CGEventGetLocation(m);
    printf("location %g %g\n", p.x, p.y);
    CGEventRef r = CGEventCreateMouseEvent(NULL, kCGEventRightMouseUp, CGPointMake(1, 2), kCGMouseButtonLeft);
    show("right up", r);
    CGEventRef o = CGEventCreateMouseEvent(NULL, kCGEventOtherMouseDown, CGPointMake(1, 2), kCGMouseButtonCenter);
    show("other down", o);
    show("left up", CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, CGPointMake(1, 2), kCGMouseButtonLeft));
    show("right down", CGEventCreateMouseEvent(NULL, kCGEventRightMouseDown, CGPointMake(1, 2), kCGMouseButtonRight));
    show("left dragged", CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDragged, CGPointMake(1, 2), kCGMouseButtonLeft));
    show("other up", CGEventCreateMouseEvent(NULL, kCGEventOtherMouseUp, CGPointMake(1, 2), 4));
    for (CGKeyCode k = 114; k <= 126; k++)
        show("special", CGEventCreateKeyboardEvent(NULL, k, true));
    show("keypad 1", CGEventCreateKeyboardEvent(NULL, 83, true));
    show("keypad enter", CGEventCreateKeyboardEvent(NULL, 76, true));
    show("shift key", CGEventCreateKeyboardEvent(NULL, 56, true));
    show("tab", CGEventCreateKeyboardEvent(NULL, 48, true));
    show("delete", CGEventCreateKeyboardEvent(NULL, 51, true));
    show("escape", CGEventCreateKeyboardEvent(NULL, 53, true));
    show("F5", CGEventCreateKeyboardEvent(NULL, 96, true));
    CGEventRef mv = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, CGPointMake(5, 5), kCGMouseButtonLeft);
    show("moved", mv);
    CGEventSetIntegerValueField(mv, kCGMouseEventDeltaX, 7);
    printf("delta %lld %g\n", (long long)CGEventGetIntegerValueField(mv, kCGMouseEventDeltaX),
           CGEventGetDoubleValueField(mv, kCGMouseEventDeltaX));

    CGEventRef s = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitLine, 2, 3, -1);
    show("scroll lines", s);
    CGEventRef sp = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 1, 25);
    show("scroll pixels", sp);

    CGEventRef copy = CGEventCreateCopy(a);
    show("copy", copy);
    CFDataRef d = CGEventCreateData(NULL, a);
    CGEventRef back = CGEventCreateFromData(NULL, d);
    show("from data", back);
    CGEventRef plain = CGEventCreate(NULL);
    printf("plain type %u flags 0x%llx\n", (unsigned)CGEventGetType(plain), (unsigned long long)CGEventGetFlags(plain));
    CGEventSetType(plain, kCGEventKeyDown);
    printf("set type %u\n", (unsigned)CGEventGetType(plain));
    CGEventSetTimestamp(plain, 12345);
    printf("timestamp %llu\n", (unsigned long long)CGEventGetTimestamp(plain));

    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStatePrivate);
    /* a private source gets a state of its own (not the shared ones) */
    CGEventSourceStateID own = CGEventSourceGetSourceStateID(src);
    printf("source state own %d pixels/line %g suppression %g\n", own > 0, CGEventSourceGetPixelsPerLine(src),
           CGEventSourceGetLocalEventsSuppressionInterval(src));
    CGEventSourceSetUserData(src, 42);
    CGEventRef withSource = CGEventCreateKeyboardEvent(src, 1, true);
    printf("user data %lld state field is the source's %d\n",
           (long long)CGEventGetIntegerValueField(withSource, kCGEventSourceUserData),
           CGEventGetIntegerValueField(withSource, kCGEventSourceStateID) == own);
    CGEventSourceRef from = CGEventCreateSourceFromEvent(withSource);
    printf("source from event: same state %d user data %lld\n", CGEventSourceGetSourceStateID(from) == own,
           (long long)CGEventSourceGetUserData(from));
    return 0;
}
