/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-keylayout-test: Text Input Sources' current keyboard layout and UCKeyTranslate
 * on its 'uchr' data: each key in each modifier layer, dead keys and what they combine
 * with, and the display action, one result per line so runs against Apple's Carbon
 * and Finch's can be diffed. Needs a U.S.-style English layout (U.S. or Canadian
 * English) selected on the Mac it runs on; the ISO keyboard's extra key (§) is left
 * out, as it differs between them.
 */
#include <Carbon/Carbon.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

static const UCKeyboardLayout *layout;

static void
key(const char *label, UInt16 code, UInt32 mods, UInt16 action, UInt32 *dead, OptionBits options)
{
    UniChar buf[8];
    UniCharCount n = 0;
    OSStatus err = UCKeyTranslate(layout, code, action, (mods >> 8) & 0xFF, LMGetKbdType(), options, dead, 8, &n, buf);
    printf("%s key %u mods %04x: err %d dead %u n %lu", label, code, (unsigned)mods, (int)err, (unsigned)*dead, (unsigned long)n);
    for (UniCharCount i = 0; i < n; i++)
        printf(" %04x", buf[i]);
    printf("\n");
}

int
main(void)
{
    Dl_info info;
    dladdr((void *)TISCopyCurrentKeyboardLayoutInputSource, &info);
    printf("HIToolbox: %s\n", info.dli_fname);
    TISInputSourceRef src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource();
    CFStringRef sid = TISGetInputSourceProperty(src, kTISPropertyInputSourceID);
    char buf[256];
    CFStringGetCString(sid, buf, sizeof buf, kCFStringEncodingUTF8);
    printf("source is a keyboard layout %d\n", CFStringHasPrefix(sid, CFSTR("com.apple.keylayout.")));
    printf("ascii %d category %s\n", CFBooleanGetValue(TISGetInputSourceProperty(src, kTISPropertyInputSourceIsASCIICapable)),
           CFEqual(TISGetInputSourceProperty(src, kTISPropertyInputSourceCategory), kTISCategoryKeyboardInputSource) ? "keyboard" : "?");
    CFDataRef data = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData);
    layout = (const UCKeyboardLayout *)CFDataGetBytePtr(data);
    printf("layout format %x\n", layout->keyLayoutHeaderFormat);
    /* (GetKeys reads the live keyboard, which someone at the Mac may be using: only
       that it answers is checked) */
    KeyMap keys;
    memset(keys, 0xff, sizeof keys);
    GetKeys(keys);
    KeyMapByteArray keyBytes;
    memcpy(keyBytes, keys, sizeof keyBytes);
    printf("GetKeys answered %d\n", keyBytes[15] != 0xff || keyBytes[14] != 0xff);

    UInt32 layers[] = {0, shiftKey, alphaLock, optionKey, optionKey | shiftKey, controlKey, cmdKey, cmdKey | shiftKey,
                       cmdKey | optionKey, alphaLock | shiftKey};
    for (size_t l = 0; l < sizeof layers / sizeof *layers; l++)
        for (UInt16 code = 0; code < 51; code++) {
            if (code == kVK_ISO_Section)
                continue;
            UInt32 dead = 0;
            key("layer", code, layers[l], kUCKeyActionDown, &dead, 0);
        }
    for (UInt16 code = 82; code <= 92; code++) {
        UInt32 dead = 0;
        key("keypad", code, 0, kUCKeyActionDown, &dead, 0);
    }
    for (UInt16 code = 115; code <= 126; code++) {
        UInt32 dead = 0;
        key("nav", code, 0, kUCKeyActionDown, &dead, 0);
    }
    /* dead keys: Option-E then E, then Space, then X; Option-U then U; two dead keys */
    UInt16 deads[] = {kVK_ANSI_E, kVK_ANSI_U, kVK_ANSI_I, kVK_ANSI_N, kVK_ANSI_Grave};
    UInt16 follow[] = {kVK_ANSI_E, kVK_ANSI_A, kVK_ANSI_O, kVK_Space, kVK_ANSI_X, kVK_ANSI_N, kVK_ANSI_Y};
    for (size_t d = 0; d < sizeof deads / sizeof *deads; d++)
        for (size_t f = 0; f < sizeof follow / sizeof *follow; f++) {
            UInt32 dead = 0;
            key("dead", deads[d], optionKey, kUCKeyActionDown, &dead, 0);
            key("  then", follow[f], 0, kUCKeyActionDown, &dead, 0);
            UInt32 dead2 = 0;
            key("  shifted", deads[d], optionKey, kUCKeyActionDown, &dead2, 0);
            key("  then", follow[f], shiftKey, kUCKeyActionDown, &dead2, 0);
        }
    UInt32 dead = 0;
    key("two dead", kVK_ANSI_E, optionKey, kUCKeyActionDown, &dead, 0);
    key("  second", kVK_ANSI_U, optionKey, kUCKeyActionDown, &dead, 0);
    key("  then", kVK_ANSI_A, 0, kUCKeyActionDown, &dead, 0);
    dead = 0;
    key("display", kVK_ANSI_E, optionKey, kUCKeyActionDisplay, &dead, 0);
    dead = 0;
    key("no dead", kVK_ANSI_E, optionKey, kUCKeyActionDown, &dead, 1 << kUCKeyTranslateNoDeadKeysBit);
    dead = 0;
    key("up", kVK_ANSI_A, 0, kUCKeyActionUp, &dead, 0);
    dead = 0;
    key("autokey", kVK_ANSI_A, 0, kUCKeyActionAutoKey, &dead, 0);
    CFRelease(src);
    return 0;
}
