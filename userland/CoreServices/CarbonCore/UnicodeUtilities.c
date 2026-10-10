/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * UCKeyTranslate: what a key types, read from keyboard layout data in the 'uchr' form
 * (UCKeyboardLayout, UnicodeUtilities.h): the keyboard type's modifier-to-table map
 * picks a table, the table gives the key's output, a character, a sequence or a state
 * record, and state records carry dead keys from one key to the next (with each dead
 * state's terminator typed when what follows doesn't combine). Text Input Sources
 * serve the current layout's data (HIToolbox's TextInputSources.c).
 */
#include <CoreServices/CoreServices.h>
#include <string.h>

static const void *
at(const UCKeyboardLayout *layout, UInt32 offset)
{
    return offset ? (const UInt8 *)layout + offset : NULL;
}

static const UCKeyboardTypeHeader *
type_header(const UCKeyboardLayout *layout, UInt32 keyboardType)
{
    for (UInt32 i = 0; i < layout->keyboardTypeCount; i++) {
        const UCKeyboardTypeHeader *h = &layout->keyboardTypeList[i];
        if (keyboardType >= h->keyboardTypeFirst && keyboardType <= h->keyboardTypeLast)
            return h;
    }
    return layout->keyboardTypeCount ? &layout->keyboardTypeList[0] : NULL;
}

/* Appends one output (a character, or a sequence's characters) to the result. */
static void
emit(const UCKeyboardLayout *layout, const UCKeyboardTypeHeader *h, UInt16 out, UniChar *buf, UniCharCount max, UniCharCount *len)
{
    if (out == 0xFFFE || out == 0xFFFF)
        return;
    if ((out & kUCKeyOutputTestForIndexMask) == kUCKeyOutputSequenceIndexMask) {
        const UCKeySequenceDataIndex *seq = at(layout, h->keySequenceDataIndexOffset);
        UInt16 i = out & kUCKeyOutputGetIndexMask;
        if (seq && i < seq->charSequenceCount) {
            const UniChar *chars = (const UniChar *)((const UInt8 *)seq + seq->charSequenceOffsets[i]);
            UInt16 n = (UInt16)((seq->charSequenceOffsets[i + 1] - seq->charSequenceOffsets[i]) / 2);
            for (UInt16 k = 0; k < n; k++)
                if (*len < max)
                    buf[(*len)++] = chars[k];
        }
        return;
    }
    if (*len < max)
        buf[(*len)++] = out;
}

/* A dead state's terminator: what's typed when the state ends without combining. */
static UniChar
terminator(const UCKeyboardLayout *layout, const UCKeyboardTypeHeader *h, UInt32 state)
{
    const UCKeyStateTerminators *t = at(layout, h->keyStateTerminatorsOffset);
    return t && state && state <= t->keyStateTerminatorCount ? t->keyStateTerminators[state - 1] : 0xFFFF;
}

OSStatus
UCKeyTranslate(const UCKeyboardLayout *keyLayoutPtr, UInt16 virtualKeyCode, UInt16 keyAction, UInt32 modifierKeyState,
               UInt32 keyboardType, OptionBits keyTranslateOptions, UInt32 *deadKeyState, UniCharCount maxStringLength,
               UniCharCount *actualStringLength, UniChar unicodeString[])
{
    if (!keyLayoutPtr || !deadKeyState || !actualStringLength)
        return paramErr;
    *actualStringLength = 0;
    if (keyLayoutPtr->keyLayoutHeaderFormat != kUCKeyLayoutHeaderFormat)
        return paramErr;
    const UCKeyboardTypeHeader *h = type_header(keyLayoutPtr, keyboardType);
    if (!h)
        return paramErr;
    /* (a key up is answered as Apple's is: what the key shows, as for kUCKeyActionDisplay) */
    Boolean display = keyAction == kUCKeyActionDisplay || keyAction == kUCKeyActionUp;
    const UCKeyModifiersToTableNum *mods = at(keyLayoutPtr, h->keyModifiersToTableNumOffset);
    const UCKeyToCharTableIndex *tables = at(keyLayoutPtr, h->keyToCharTableIndexOffset);
    if (!mods || !tables)
        return paramErr;
    UInt32 ks = modifierKeyState & 0xFF;
    UInt32 table = ks < mods->modifiersCount ? mods->tableNum[ks] : mods->defaultTableNum;
    if (table >= tables->keyToCharTableCount || virtualKeyCode >= tables->keyToCharTableSize)
        return noErr;
    const UCKeyOutput *row = at(keyLayoutPtr, tables->keyToCharTableOffsets[table]);
    UCKeyOutput out = row[virtualKeyCode];
    Boolean noDead = (keyTranslateOptions & (1 << kUCKeyTranslateNoDeadKeysBit)) || display;
    /* the pending state is the low 16 bits (the high ones remember the last combination) */
    UInt32 state = display ? 0 : *deadKeyState & 0xFFFF;

    if ((out & kUCKeyOutputTestForIndexMask) == kUCKeyOutputStateIndexMask) {
        const UCKeyStateRecordsIndex *records = at(keyLayoutPtr, h->keyStateRecordsIndexOffset);
        UInt16 ri = out & kUCKeyOutputGetIndexMask;
        if (!records || ri >= records->keyStateRecordCount)
            return noErr;
        const UCKeyStateRecord *r = at(keyLayoutPtr, records->keyStateRecordOffsets[ri]);
        if (state) {
            /* a dead key pending: this key's entry for the state, if it has one */
            if (r->stateEntryFormat == kUCKeyStateEntryTerminalFormat) {
                const UCKeyStateEntryTerminal *e = (const UCKeyStateEntryTerminal *)r->stateEntryData;
                for (UInt16 i = 0; i < r->stateEntryCount; i++)
                    if (e[i].curState == state) {
                        emit(keyLayoutPtr, h, e[i].charData, unicodeString, maxStringLength, actualStringLength);
                        *deadKeyState = state << 16; /* as Apple's: the combination just made */
                        return noErr;
                    }
            } else if (r->stateEntryFormat == kUCKeyStateEntryRangeFormat) {
                const UCKeyStateEntryRange *e = (const UCKeyStateEntryRange *)r->stateEntryData;
                for (UInt16 i = 0; i < r->stateEntryCount; i++)
                    if (state >= e[i].curStateStart && state <= (UInt32)e[i].curStateStart + e[i].curStateRange) {
                        UInt32 delta = (state - e[i].curStateStart) * e[i].deltaMultiplier;
                        if (e[i].nextState) {
                            *deadKeyState = e[i].nextState + delta;
                            return noErr;
                        }
                        emit(keyLayoutPtr, h, (UInt16)(e[i].charData + delta), unicodeString, maxStringLength, actualStringLength);
                        *deadKeyState = state << 16;
                        return noErr;
                    }
            }
            /* no entry: the pending state's terminator, then the key afresh */
            emit(keyLayoutPtr, h, terminator(keyLayoutPtr, h, state), unicodeString, maxStringLength, actualStringLength);
            state = 0;
        }
        if (r->stateZeroNextState) {
            if (noDead) {
                /* shown, or dead keys off: the accent itself */
                UInt16 c = r->stateZeroCharData != 0xFFFF ? r->stateZeroCharData : terminator(keyLayoutPtr, h, r->stateZeroNextState);
                emit(keyLayoutPtr, h, c, unicodeString, maxStringLength, actualStringLength);
                /* shown, the dead state is still reported, as Apple's does */
                *deadKeyState = display ? r->stateZeroNextState : 0;
                return noErr;
            }
            *deadKeyState = r->stateZeroNextState;
            return noErr;
        }
        emit(keyLayoutPtr, h, r->stateZeroCharData, unicodeString, maxStringLength, actualStringLength);
        if (!display)
            *deadKeyState = 0;
        return noErr;
    }
    /* a plain output; a pending dead key types its terminator first */
    if (state)
        emit(keyLayoutPtr, h, terminator(keyLayoutPtr, h, state), unicodeString, maxStringLength, actualStringLength);
    emit(keyLayoutPtr, h, out, unicodeString, maxStringLength, actualStringLength);
    if (!display)
        *deadKeyState = 0;
    return noErr;
}

/* The layout's features: the largest output any key gives (one character, or a
   sequence's length). */
OSStatus
UCGetKeyboardLayoutFeature(const UCKeyboardLayout *keyLayoutPtr, OSType featureSelector, UInt32 *response)
{
    if (!keyLayoutPtr || !response)
        return paramErr;
    *response = 0;
    const UCKeyLayoutFeatureInfo *info = at(keyLayoutPtr, keyLayoutPtr->keyLayoutFeatureInfoOffset);
    *response = info ? info->maxOutputStringLength : 2;
    return noErr;
}
