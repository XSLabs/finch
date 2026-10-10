/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * HIToolbox's raw key translation, as Terminal (and others) use it:
 * TSMProcessRawKeyCode() takes a keyboard Carbon event (a raw key down,
 * repeat or up with kEventParamKeyCode and kEventParamKeyModifiers) and adds
 * what the key types in the current layout: kEventParamKeyUnicodes and,
 * when they fit Mac Roman, kEventParamKeyMacCharCodes. Dead keys are kept
 * between calls (TSMGetDeadKeyState / TSMSetDeadKeyState, as Apple's private
 * calls are). The layout is the US one, with its Option layers and the
 * grave, acute, circumflex, diaeresis and tilde dead keys.
 */
#include <Carbon/Carbon.h>

OSStatus TSMProcessRawKeyCode(EventRef inEvent);
UInt32 TSMGetDeadKeyState(void);
UInt32 TSMSetDeadKeyState(UInt32 inState);

/* in Apple's numbering of the dead states */
enum { DEAD_NONE, DEAD_ACUTE, DEAD_GRAVE, DEAD_CIRCUMFLEX, DEAD_DIAERESIS, DEAD_TILDE };
#define DEAD(n) (0xF0000 | (n))   /* a table entry that starts a dead key */

static UInt32 dead_state;

UInt32 TSMGetDeadKeyState(void) { return dead_state; }

UInt32
TSMSetDeadKeyState(UInt32 inState)
{
    UInt32 old = dead_state;
    dead_state = inState;
    return old;
}

/* The US layout: plain, Shift, Option and Shift-Option, by virtual key code. */
static const struct Key {
    UInt16 code;
    UInt32 plain, shift, option, shift_option;
} keys[] = {
    {kVK_ANSI_A, 'a', 'A', 0xE5, 0xC5},          {kVK_ANSI_S, 's', 'S', 0xDF, 0xCD},
    {kVK_ANSI_D, 'd', 'D', 0x2202, 0xCE},        {kVK_ANSI_F, 'f', 'F', 0x192, 0xCF},
    {kVK_ANSI_H, 'h', 'H', 0x2D9, 0xD3},         {kVK_ANSI_G, 'g', 'G', 0xA9, 0x2DD},
    {kVK_ANSI_Z, 'z', 'Z', 0x3A9, 0xB8},         {kVK_ANSI_X, 'x', 'X', 0x2248, 0x2DB},
    {kVK_ANSI_C, 'c', 'C', 0xE7, 0xC7},          {kVK_ANSI_V, 'v', 'V', 0x221A, 0x25CA},
    {kVK_ANSI_B, 'b', 'B', 0x222B, 0x131},       {kVK_ANSI_Q, 'q', 'Q', 0x153, 0x152},
    {kVK_ANSI_W, 'w', 'W', 0x2211, 0x201E},      {kVK_ANSI_E, 'e', 'E', DEAD(DEAD_ACUTE), 0xB4},
    {kVK_ANSI_R, 'r', 'R', 0xAE, 0x2030},        {kVK_ANSI_Y, 'y', 'Y', 0xA5, 0xC1},
    {kVK_ANSI_T, 't', 'T', 0x2020, 0x2C7},       {kVK_ANSI_1, '1', '!', 0xA1, 0x2044},
    {kVK_ANSI_2, '2', '@', 0x2122, 0x20AC},      {kVK_ANSI_3, '3', '#', 0xA3, 0x2039},
    {kVK_ANSI_4, '4', '$', 0xA2, 0x203A},        {kVK_ANSI_6, '6', '^', 0xA7, 0xFB02},
    {kVK_ANSI_5, '5', '%', 0x221E, 0xFB01},      {kVK_ANSI_Equal, '=', '+', 0x2260, 0xB1},
    {kVK_ANSI_9, '9', '(', 0xAA, 0xB7},          {kVK_ANSI_7, '7', '&', 0xB6, 0x2021},
    {kVK_ANSI_Minus, '-', '_', 0x2013, 0x2014},  {kVK_ANSI_8, '8', '*', 0x2022, 0xB0},
    {kVK_ANSI_0, '0', ')', 0xBA, 0x201A},        {kVK_ANSI_RightBracket, ']', '}', 0x2018, 0x2019},
    {kVK_ANSI_O, 'o', 'O', 0xF8, 0xD8},          {kVK_ANSI_U, 'u', 'U', DEAD(DEAD_DIAERESIS), 0xA8},
    {kVK_ANSI_LeftBracket, '[', '{', 0x201C, 0x201D}, {kVK_ANSI_I, 'i', 'I', DEAD(DEAD_CIRCUMFLEX), 0x2C6},
    {kVK_ANSI_P, 'p', 'P', 0x3C0, 0x220F},       {kVK_ANSI_L, 'l', 'L', 0xAC, 0xD2},
    {kVK_ANSI_J, 'j', 'J', 0x2206, 0xD4},        {kVK_ANSI_Quote, '\'', '"', 0xE6, 0xC6},
    {kVK_ANSI_K, 'k', 'K', 0x2DA, 0xF8FF},       {kVK_ANSI_Semicolon, ';', ':', 0x2026, 0xDA},
    {kVK_ANSI_Backslash, '\\', '|', 0xAB, 0xBB}, {kVK_ANSI_Comma, ',', '<', 0x2264, 0xAF},
    {kVK_ANSI_Slash, '/', '?', 0xF7, 0xBF},      {kVK_ANSI_N, 'n', 'N', DEAD(DEAD_TILDE), 0x2DC},
    {kVK_ANSI_M, 'm', 'M', 0xB5, 0xC2},          {kVK_ANSI_Period, '.', '>', 0x2265, 0x2D8},
    {kVK_ANSI_Grave, '`', '~', DEAD(DEAD_GRAVE), '`'},
    {kVK_Space, ' ', ' ', 0xA0, 0xA0},           {kVK_Return, '\r', '\r', '\r', '\r'},
    {kVK_Tab, '\t', '\t', '\t', '\t'},           {kVK_Delete, 0x08, 0x08, 0x08, 0x08},
    {kVK_Escape, 0x1B, 0x1B, 0x1B, 0x1B},        {kVK_ForwardDelete, 0x7F, 0x7F, 0x7F, 0x7F},
    {kVK_LeftArrow, 0x1C, 0x1C, 0x1C, 0x1C},     {kVK_RightArrow, 0x1D, 0x1D, 0x1D, 0x1D},
    {kVK_UpArrow, 0x1E, 0x1E, 0x1E, 0x1E},       {kVK_DownArrow, 0x1F, 0x1F, 0x1F, 0x1F},
    {kVK_Home, 0x01, 0x01, 0x01, 0x01},          {kVK_End, 0x04, 0x04, 0x04, 0x04},
    {kVK_PageUp, 0x0B, 0x0B, 0x0B, 0x0B},        {kVK_PageDown, 0x0C, 0x0C, 0x0C, 0x0C},
    {kVK_Help, 0x05, 0x05, 0x05, 0x05},          {kVK_ANSI_KeypadEnter, 0x03, 0x03, 0x03, 0x03},
    {kVK_ANSI_KeypadClear, 0x1B, 0x1B, 0x1B, 0x1B}, {kVK_ANSI_KeypadDecimal, '.', '.', '.', '.'},
    {kVK_ANSI_KeypadMultiply, '*', '*', '*', '*'}, {kVK_ANSI_KeypadPlus, '+', '+', '+', '+'},
    {kVK_ANSI_KeypadDivide, '/', '/', '/', '/'}, {kVK_ANSI_KeypadMinus, '-', '-', '-', '-'},
    {kVK_ANSI_KeypadEquals, '=', '=', '=', '='}, {kVK_ANSI_Keypad0, '0', '0', '0', '0'},
    {kVK_ANSI_Keypad1, '1', '1', '1', '1'},      {kVK_ANSI_Keypad2, '2', '2', '2', '2'},
    {kVK_ANSI_Keypad3, '3', '3', '3', '3'},      {kVK_ANSI_Keypad4, '4', '4', '4', '4'},
    {kVK_ANSI_Keypad5, '5', '5', '5', '5'},      {kVK_ANSI_Keypad6, '6', '6', '6', '6'},
    {kVK_ANSI_Keypad7, '7', '7', '7', '7'},      {kVK_ANSI_Keypad8, '8', '8', '8', '8'},
    {kVK_ANSI_Keypad9, '9', '9', '9', '9'},
    /* the function keys: the function-key character, 0x10 */
    {kVK_F1, 0x10, 0x10, 0x10, 0x10},  {kVK_F2, 0x10, 0x10, 0x10, 0x10},  {kVK_F3, 0x10, 0x10, 0x10, 0x10},
    {kVK_F4, 0x10, 0x10, 0x10, 0x10},  {kVK_F5, 0x10, 0x10, 0x10, 0x10},  {kVK_F6, 0x10, 0x10, 0x10, 0x10},
    {kVK_F7, 0x10, 0x10, 0x10, 0x10},  {kVK_F8, 0x10, 0x10, 0x10, 0x10},  {kVK_F9, 0x10, 0x10, 0x10, 0x10},
    {kVK_F10, 0x10, 0x10, 0x10, 0x10}, {kVK_F11, 0x10, 0x10, 0x10, 0x10}, {kVK_F12, 0x10, 0x10, 0x10, 0x10},
    {kVK_F13, 0x10, 0x10, 0x10, 0x10}, {kVK_F14, 0x10, 0x10, 0x10, 0x10}, {kVK_F15, 0x10, 0x10, 0x10, 0x10},
    {kVK_F16, 0x10, 0x10, 0x10, 0x10}, {kVK_F17, 0x10, 0x10, 0x10, 0x10}, {kVK_F18, 0x10, 0x10, 0x10, 0x10},
    {kVK_F19, 0x10, 0x10, 0x10, 0x10},
};

/* Each dead key's accent alone, and what it makes of the letters it combines with. */
static const struct {
    UniChar alone;
    const char *bases;
    const UniChar *combined;
} accents[] = {
    [DEAD_GRAVE] = {'`', "aeiouAEIOU", (const UniChar[]){0xE0, 0xE8, 0xEC, 0xF2, 0xF9, 0xC0, 0xC8, 0xCC, 0xD2, 0xD9}},
    [DEAD_ACUTE] = {0xB4, "aeiouAEIOU", (const UniChar[]){0xE1, 0xE9, 0xED, 0xF3, 0xFA, 0xC1, 0xC9, 0xCD, 0xD3, 0xDA}},
    [DEAD_CIRCUMFLEX] = {0x2C6, "aeiouAEIOU", (const UniChar[]){0xE2, 0xEA, 0xEE, 0xF4, 0xFB, 0xC2, 0xCA, 0xCE, 0xD4, 0xDB}},
    [DEAD_DIAERESIS] = {0xA8, "aeiouyAEIOUY",
                        (const UniChar[]){0xE4, 0xEB, 0xEF, 0xF6, 0xFC, 0xFF, 0xC4, 0xCB, 0xCF, 0xD6, 0xDC, 0x178}},
    [DEAD_TILDE] = {0x2DC, "anoANO", (const UniChar[]){0xE3, 0xF1, 0xF5, 0xC3, 0xD1, 0xD5}},
};

/* The character a key gives in a modifier layer (or DEAD(n) for a dead key), before
 * any pending dead key is taken into account. */
static UInt32
layer_char(const struct Key *k, UInt32 mods)
{
    Boolean shift = (mods & (shiftKey | rightShiftKey)) != 0, option = (mods & (optionKey | rightOptionKey)) != 0;
    Boolean control = (mods & (controlKey | rightControlKey)) != 0, caps = (mods & alphaLock) != 0;
    Boolean command = (mods & cmdKey) != 0;
    UInt32 c;
    if (control) {
        /* the control layer, as Apple's US layout: letters and [ \ ] - make control codes,
         * other keys their plain character (Shift and Option don't count) */
        UInt32 base = k->plain;
        c = base >= 'a' && base <= 'z' ? base - 'a' + 1
            : base == '[' ? 0x1B : base == '\\' ? 0x1C : base == ']' ? 0x1D : base == '-' ? 0x1F : base;
    } else if (command) {
        /* Command: the plain key (Shift and Caps Lock don't count); with Option, the Option
         * layer, its dead keys typing their accents */
        c = option ? (shift ? k->shift_option : k->option) : k->plain;
        if ((c & 0xF0000) == 0xF0000 && c != 0xF8FF) {
            UInt32 d = c & 0xFFFF;
            c = d == DEAD_CIRCUMFLEX ? '^' : d == DEAD_TILDE ? '~' : accents[d].alone;
        }
    } else {
        c = option ? (shift ? k->shift_option : k->option) : (shift ? k->shift : k->plain);
        if (caps && !option && c >= 'a' && c <= 'z')
            c -= 'a' - 'A';
    }
    return c;
}

static const struct Key *
key_for(UInt32 code)
{
    for (size_t i = 0; i < sizeof keys / sizeof keys[0]; i++)
        if (keys[i].code == code)
            return &keys[i];
    return NULL;
}

/* What the key types with these modifiers; with a dead key pending, combined with it.
 * Returns the number of UniChars (0 when the key starts a dead key). */
static int
translate(UInt32 code, UInt32 mods, Boolean down, UniChar out[2])
{
    const struct Key *k = key_for(code);
    if (!k)
        return 0;
    UInt32 c = layer_char(k, mods);
    if ((c & 0xF0000) == 0xF0000 && c != 0xF8FF) {
        if (!down)
            return 0;
        if (dead_state) {
            /* a second dead key: the first's accent, then wait on the second */
            out[0] = accents[dead_state].alone;
            dead_state = c & 0xFFFF;
            return 1;
        }
        dead_state = c & 0xFFFF;
        return 0;
    }
    if (dead_state && down && dead_state < sizeof accents / sizeof accents[0]) {
        UInt32 dead = dead_state;
        dead_state = 0;
        if (c == ' ') {
            out[0] = accents[dead].alone;
            return 1;
        }
        const char *at = c < 0x80 ? strchr(accents[dead].bases, (int)c) : NULL;
        if (at && c) {
            out[0] = accents[dead].combined[at - accents[dead].bases];
            return 1;
        }
        out[0] = accents[dead].alone;
        out[1] = (UniChar)c;
        return 2;
    }
    out[0] = (UniChar)c;
    return 1;
}

OSStatus
TSMProcessRawKeyCode(EventRef inEvent)
{
    if (GetEventClass(inEvent) != kEventClassKeyboard)
        return eventNotHandledErr;
    UInt32 kind = GetEventKind(inEvent);
    if (kind < kEventRawKeyDown || kind > kEventRawKeyUp)
        return noErr;
    UInt32 code = 0, mods = 0;
    GetEventParameter(inEvent, kEventParamKeyCode, typeUInt32, NULL, sizeof code, NULL, &code);
    GetEventParameter(inEvent, kEventParamKeyModifiers, typeUInt32, NULL, sizeof mods, NULL, &mods);
    UInt32 before = dead_state;
    UniChar chars[2];
    int n = translate(code, mods, kind != kEventRawKeyUp, chars);
    if (kind == kEventRawKeyUp)
        dead_state = before;
    OSStatus err = SetEventParameter(inEvent, kEventParamKeyUnicodes, typeUnicodeText, (ByteCount)n * sizeof(UniChar), chars);
    if (err)
        return err;
    /* the same in Mac Roman, when it can be */
    CFStringRef s = CFStringCreateWithCharactersNoCopy(NULL, chars, n, kCFAllocatorNull);
    char roman[4];
    CFIndex used = 0;
    if (!n || (s && CFStringGetBytes(s, CFRangeMake(0, n), kCFStringEncodingMacRoman, 0, false, (UInt8 *)roman, sizeof roman, &used) == n))
        err = SetEventParameter(inEvent, kEventParamKeyMacCharCodes, typeChar, (ByteCount)used, roman);
    else
        RemoveEventParameter(inEvent, kEventParamKeyMacCharCodes);
    if (s)
        CFRelease(s);
    return err;
}

/* --- the layout as 'uchr' data (UCKeyboardLayout, UnicodeUtilities.h), for Text Input
 * Sources' kTISPropertyUnicodeKeyLayoutData and UCKeyTranslate --- */

static void
put16(CFMutableDataRef d, CFIndex at, UInt16 v)
{
    memcpy(CFDataGetMutableBytePtr(d) + at, &v, 2);
}

static void
put32(CFMutableDataRef d, CFIndex at, UInt32 v)
{
    memcpy(CFDataGetMutableBytePtr(d) + at, &v, 4);
}

static CFIndex
grow(CFMutableDataRef d, CFIndex n)
{
    CFIndex at = CFDataGetLength(d);
    CFDataIncreaseLength(d, n);
    return at;
}

/* Whether c combines with some accent (so its key needs a state record). */
static Boolean
combines(UInt32 c)
{
    if (c == ' ')
        return true;
    for (int a = DEAD_ACUTE; a <= DEAD_TILDE; a++)
        if (c && c < 0x80 && strchr(accents[a].bases, (int)c))
            return true;
    return false;
}

__attribute__((visibility("default"))) CFDataRef
FinchCopyUSKeyLayoutData(void)
{
    enum { KEYS = 128, COMBOS = 32, STATES = DEAD_TILDE };
    /* the layer tables, one per distinct modifier combination's output */
    UInt32 table[COMBOS][KEYS];
    int table_of[COMBOS], ntables = 0, unique[COMBOS];
    for (int m = 0; m < COMBOS; m++) {
        UInt32 mods = (UInt32)m << 8;
        for (int code = 0; code < KEYS; code++) {
            const struct Key *k = key_for((UInt32)code);
            table[m][code] = k ? layer_char(k, mods) : 0xFFFF;
        }
        table_of[m] = -1;
        for (int t = 0; t < ntables; t++)
            if (!memcmp(table[unique[t]], table[m], sizeof table[m]))
                table_of[m] = t;
        if (table_of[m] < 0) {
            unique[ntables] = m;
            table_of[m] = ntables++;
        }
    }
    /* state records: one per dead key, and one per character that combines */
    UInt32 records[256];
    int nrecords = 0;
    for (int t = 0; t < ntables; t++)
        for (int code = 0; code < KEYS; code++) {
            UInt32 c = table[unique[t]][code];
            if (!((c & 0xF0000) == 0xF0000 && c != 0xF8FF) && !combines(c))
                continue;
            Boolean have = false;
            for (int r = 0; r < nrecords; r++)
                have = have || records[r] == c;
            if (!have && nrecords < 256)
                records[nrecords++] = c;
        }

    CFMutableDataRef d = CFDataCreateMutable(NULL, 0);
    /* header and the one keyboard-type entry (every type) */
    CFIndex header = grow(d, 12 + 28);
    put16(d, header, kUCKeyLayoutHeaderFormat);
    put16(d, header + 2, 0x0100);
    put32(d, header + 4, 0);
    put32(d, header + 8, 1);
    CFIndex type = header + 12;
    put32(d, type, 0);
    put32(d, type + 4, 0);
    /* modifiers to table: 256 states, the right-side keys folded into the left */
    CFIndex mods = grow(d, 8 + 256);
    put32(d, type + 8, (UInt32)mods);
    put16(d, mods, kUCKeyModifiersToTableNumFormat);
    put16(d, mods + 2, 0);
    put32(d, mods + 4, 256);
    for (int ks = 0; ks < 256; ks++) {
        int folded = (ks & 0x1F) | ((ks >> 4) & 0x02) | ((ks >> 3) & 0x08) | ((ks >> 3) & 0x10);
        CFDataGetMutableBytePtr(d)[mods + 8 + ks] = (UInt8)table_of[folded & 0x1F];
    }
    /* key-to-char tables */
    CFIndex index = grow(d, 8 + 4 * ntables);
    put32(d, type + 12, (UInt32)index);
    put16(d, index, kUCKeyToCharTableIndexFormat);
    put16(d, index + 2, KEYS);
    put32(d, index + 4, (UInt32)ntables);
    for (int t = 0; t < ntables; t++) {
        CFIndex at = grow(d, 2 * KEYS);
        put32(d, index + 8 + 4 * t, (UInt32)at);
        for (int code = 0; code < KEYS; code++) {
            UInt32 c = table[unique[t]][code];
            UInt16 out = (UInt16)c;
            for (int r = 0; r < nrecords; r++)
                if (records[r] == c)
                    out = (UInt16)(kUCKeyOutputStateIndexMask | r);
            put16(d, at + 2 * code, out);
        }
    }
    /* the state records */
    CFIndex sidx = grow(d, 4 + 4 * nrecords);
    put32(d, type + 16, (UInt32)sidx);
    put16(d, sidx, kUCKeyStateRecordsIndexFormat);
    put16(d, sidx + 2, (UInt16)nrecords);
    for (int r = 0; r < nrecords; r++) {
        UInt32 c = records[r];
        Boolean dead = (c & 0xF0000) == 0xF0000;
        UInt16 entries = 0;
        UInt16 state[STATES], out[STATES];
        if (!dead)
            for (int a = DEAD_ACUTE; a <= DEAD_TILDE; a++) {
                const char *at = c < 0x80 ? strchr(accents[a].bases, (int)c) : NULL;
                if (c == ' ' || at) {
                    state[entries] = (UInt16)a;
                    out[entries++] = c == ' ' ? accents[a].alone : accents[a].combined[at - accents[a].bases];
                }
            }
        CFIndex rec = grow(d, 8 + 4 * entries);
        put32(d, sidx + 4 + 4 * r, (UInt32)rec);
        put16(d, rec, dead ? 0xFFFF : (UInt16)c);
        put16(d, rec + 2, dead ? (UInt16)(c & 0xFFFF) : 0);
        put16(d, rec + 4, entries);
        put16(d, rec + 6, kUCKeyStateEntryTerminalFormat);
        for (int e = 0; e < entries; e++) {
            put16(d, rec + 8 + 4 * e, state[e]);
            put16(d, rec + 10 + 4 * e, out[e]);
        }
    }
    /* each dead state's terminator: its accent alone */
    CFIndex term = grow(d, 4 + 2 * STATES);
    put32(d, type + 20, (UInt32)term);
    put16(d, term, kUCKeyStateTerminatorsFormat);
    put16(d, term + 2, STATES);
    for (int a = DEAD_ACUTE; a <= DEAD_TILDE; a++)
        put16(d, term + 4 + 2 * (a - 1), accents[a].alone);
    put32(d, type + 24, 0); /* no sequences */
    return d;
}
