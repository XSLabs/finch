/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <CoreServices/CoreServices.h>
#include <OSServices/CSIdentity.h>
#include <OSServices/CSIdentityAuthority.h>
#include <OSServices/CSIdentityQuery.h>
#include <inttypes.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <sys/acl.h>
#include <unistd.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static void
print_wide(const char *name, wide value)
{
    printf("%s %d %u\n", name, value.hi, value.lo);
}

static void
time_math(void)
{
    Nanoseconds n = DurationToNanoseconds(1);
    printf("duration-ms %u %u\n", n.hi, n.lo);
    n = DurationToNanoseconds(-1);
    printf("duration-us %u %u\n", n.hi, n.lo);
    printf("duration-roundtrip %d %d %d\n", NanosecondsToDuration(DurationToNanoseconds(2)),
           NanosecondsToDuration(DurationToNanoseconds(-17)), NanosecondsToDuration(DurationToNanoseconds(0)));

    wide value;
    WideMultiply(-1234567, 321, &value);
    print_wide("wide-multiply", value);
    SInt32 remainder = 0;
    printf("wide-divide %d ", WideDivide(&value, 17, &remainder));
    printf("%d\n", remainder);
    WideWideDivide(&value, 17, &remainder);
    print_wide("wide-wide-divide", value);
    printf("wide-remainder %d\n", remainder);

    value.hi = 0;
    value.lo = 101;
    WideShift(&value, 1);
    print_wide("wide-rounded-right", value);
    value.hi = 0;
    value.lo = 101;
    WideBitShift(&value, 1);
    print_wide("wide-bit-right", value);
    value.hi = 0;
    value.lo = 10000;
    printf("wide-sqrt %u\n", WideSquareRoot(&value));
    printf("wide-compare %d %d\n", WideCompare(&value, &value), U64Compare(9, 10));
    printf("fixed-mul-div %u\n", UnsignedFixedMulDiv(0x10000, 0x18000, 0x20000));

    UInt8 bits[3] = {0};
    BitSet(bits, 0);
    BitSet(bits, 10);
    printf("bits %d %d %d ", BitTst(bits, 0), BitTst(bits, 10), BitTst(bits, 8));
    BitClr(bits, 0);
    printf("%d\n", BitTst(bits, 0));
    printf("bit-ops %ld %ld %ld %ld %ld\n", BitAnd(0x55, 0x33), BitOr(0x55, 0x33),
           BitXor(0x55, 0x33), BitNot(0), BitShift(3, 4));

    SInt32 word = 6;
    SInt32 old = AddAtomic(5, &word);
    printf("atomic-add %d %d\n", old, word);
    old = IncrementAtomic(&word);
    printf("atomic-inc %d %d\n", old, word);
    UInt16 half = 0x00f0;
    UInt16 oldHalf = BitOrAtomic16(0x100, &half);
    printf("atomic-or16 %u %u\n", oldHalf, half);
    UInt8 byte = 0x0f;
    UInt8 oldByte = BitXorAtomic8(0xf0, &byte);
    printf("atomic-xor8 %u %u\n", oldByte, byte);
    UInt32 swap = 3;
    Boolean changed = CompareAndSwap(3, 9, &swap);
    Boolean unchanged = CompareAndSwap(3, 7, &swap);
    printf("compare-swap %d %u %d\n", changed, swap, unchanged);
    UInt8 flag = 0;
    Boolean wasSet = TestAndSet(2, &flag);
    Boolean wasCleared = TestAndClear(2, &flag);
    printf("test-set-clear %d %d %u\n", wasSet, wasCleared, flag);
}

static void
legacy_utilities(void)
{
    MachineLocation location = {0};
    ReadLocation(&location);
    printf("legacy-utilities %d %u %d %d %ld\n", IsMetric(), (unsigned)TaskLevel(), location.latitude,
           location.longitude, location.u.gmtDelta);

    Handle handle = NewHandle(6);
    memcpy(*handle, "abcabc", 6);
    long position = Munger(handle, 0, "bc", 2, "X", 1);
    printf("legacy-munger %ld %ld %.*s\n", position, (long)GetHandleSize(handle),
           (int)GetHandleSize(handle), *handle);
    long absent = Munger(handle, 0, "missing", 7, "?", 1);
    printf("legacy-munger-absent %ld %ld\n", absent, (long)GetHandleSize(handle));
    DisposeHandle(handle);
}

static void
hfs_strings(void)
{
    CFStringRef source = CFStringCreateWithCString(NULL, "Crème", kCFStringEncodingUTF8);
    HFSUniStr255 encoded = {0};
    OSStatus status = FSGetHFSUniStrFromString(source, &encoded);
    CFStringRef restored = FSCreateStringFromHFSUniStr(NULL, &encoded);
    printf("hfs-string %d %u %d\n", (int)status, encoded.length,
           restored && source && CFStringCompare(source, restored, 0) == kCFCompareEqualTo);
    if (restored) CFRelease(restored);
    if (source) CFRelease(source);
}

static void
unicode_helpers(void)
{
    TextToUnicodeInfo toUnicode = NULL;
    UnicodeToTextInfo fromUnicode = NULL;
    OSStatus toInfoStatus = CreateTextToUnicodeInfoByEncoding(kTextEncodingMacRoman, &toUnicode);
    OSStatus fromInfoStatus = CreateUnicodeToTextInfoByEncoding(kTextEncodingMacRoman, &fromUnicode);
    Str255 source = {5, 'C', 'r', 0x8a, 'm', 'e'};
    UniChar unicode[8] = {0};
    ByteCount unicodeLength = 0;
    OSStatus toStatus = ConvertFromPStringToUnicode(toUnicode, source, sizeof unicode, &unicodeLength, unicode);
    Str255 restored = {0};
    OSStatus fromStatus = ConvertFromUnicodeToPString(fromUnicode, unicodeLength, unicode, restored);
    printf("unicode-pascal %d %d %d %u %04x %04x %04x %04x %04x %u %d\n", (int)toInfoStatus,
           (int)fromInfoStatus, (int)toStatus, (unsigned)unicodeLength, unicode[0], unicode[1],
           unicode[2], unicode[3], unicode[4], restored[0],
           restored[0] == source[0] && memcmp(restored + 1, source + 1, source[0]) == 0 && fromStatus == noErr);
    if (toUnicode) DisposeTextToUnicodeInfo(&toUnicode);
    if (fromUnicode) DisposeUnicodeToTextInfo(&fromUnicode);

    TextEncoding encoding = kTextEncodingMacRoman;
    UnicodeToTextRunInfo runInfo = NULL;
    OSStatus createStatus = CreateUnicodeToTextRunInfoByEncoding(1, &encoding, &runInfo);
    UniChar runSource[] = {'A', 0x00e9};
    UInt8 output[16] = {0};
    ByteCount inputRead = 0, outputLength = 0;
    ItemCount runCount = 0;
    ScriptCodeRun runs[4] = {0};
    OSStatus runStatus = ConvertFromUnicodeToScriptCodeRun(runInfo, sizeof runSource, runSource, 0,
        0, NULL, NULL, NULL, sizeof output, &inputRead, &outputLength, output, 4, &runCount, runs);
    printf("unicode-script-runs %d %d %u %u %lu %d %u %u\n", (int)createStatus, (int)runStatus,
           (unsigned)inputRead, (unsigned)outputLength, (unsigned long)runCount,
           runCount ? runs[0].script : -1, output[0], output[1]);
    if (runInfo) DisposeUnicodeToTextRunInfo(&runInfo);
}

static void
folder_helpers(void)
{
    FSRef folder;
    OSErr found = FSFindFolder(kUserDomain, kDocumentsFolderType, false, &folder);
    FSRef outside;
    OSErr outsideStatus = FSPathMakeRef((const UInt8 *)"/tmp", &outside, false);
    Boolean pathResult = false, refResult = false;
    OSErr pathStatus = fnfErr, refStatus = fnfErr;
    FolderType identified = 0;
    OSErr identifyStatus = fnfErr;
    if (found == noErr) {
        FSCatalogInfo info;
        pathStatus = DetermineIfPathIsEnclosedByFolder(kOnAppropriateDisk, kDocumentsFolderType,
                                                       (const UInt8 *)"/tmp", true, &pathResult);
        refStatus = FSDetermineIfRefIsEnclosedByFolder(kOnAppropriateDisk, kDocumentsFolderType,
                                                       &outside, &refResult);
        if (FSGetCatalogInfo(&folder, kFSCatInfoVolume | kFSCatInfoNodeID, &info, NULL, NULL, NULL) == noErr)
            identifyStatus = IdentifyFolder(info.volume, (SInt32)info.nodeID, &identified);
    }
    printf("folder-helpers %d %d %d %d %d %d %d %08x %d %d\n", (int)found, (int)outsideStatus,
           (int)pathStatus,
           pathResult, (int)refStatus, refResult, (int)identifyStatus, (unsigned)identified,
           (int)ReleaseFolder(kOnSystemDisk, kDocumentsFolderType),
           (int)InvalidateFolderDescriptorCache(kOnSystemDisk, 0));
}

static void
file_security(void)
{
    FSFileSecurityRef security = FSFileSecurityCreate(kCFAllocatorDefault);
    UInt32 owner = 0, group = 0;
    UInt16 mode = 0;
    CFUUIDBytes ownerUUID = {0}, groupUUID = {0};
    acl_t acl = NULL;
    printf("file-security-type %d\n", security && CFGetTypeID(security) == FSFileSecurityGetTypeID());
    printf("file-security-empty %d %d %d %d %d\n", (int)FSFileSecurityGetOwner(security, &owner),
           (int)FSFileSecurityGetGroup(security, &group), (int)FSFileSecurityGetMode(security, &mode),
           (int)FSFileSecurityGetOwnerUUID(security, &ownerUUID),
           (int)FSFileSecurityCopyAccessControlList(security, &acl));

    CFUUIDRef ownerValue = CFUUIDCreateFromString(kCFAllocatorDefault, CFSTR("12345678-1234-5678-9ABC-DEF012345678"));
    CFUUIDRef groupValue = CFUUIDCreateFromString(kCFAllocatorDefault, CFSTR("87654321-4321-8765-CBA9-876543210FED"));
    CFUUIDBytes ownerBytes = CFUUIDGetUUIDBytes(ownerValue), groupBytes = CFUUIDGetUUIDBytes(groupValue);
    OSStatus setOwner = FSFileSecuritySetOwner(security, 501);
    OSStatus setGroup = FSFileSecuritySetGroup(security, 20);
    OSStatus setMode = FSFileSecuritySetMode(security, 0640);
    OSStatus setOwnerUUID = FSFileSecuritySetOwnerUUID(security, &ownerBytes);
    OSStatus setGroupUUID = FSFileSecuritySetGroupUUID(security, &groupBytes);
    OSStatus getOwner = FSFileSecurityGetOwner(security, &owner);
    OSStatus getGroup = FSFileSecurityGetGroup(security, &group);
    OSStatus getMode = FSFileSecurityGetMode(security, &mode);
    OSStatus getOwnerUUID = FSFileSecurityGetOwnerUUID(security, &ownerUUID);
    OSStatus getGroupUUID = FSFileSecurityGetGroupUUID(security, &groupUUID);
    printf("file-security-values %d %d %d %d %d %d %d %d %d %d %u %u %04x %d %d\n",
           (int)setOwner, (int)setGroup, (int)setMode, (int)setOwnerUUID, (int)setGroupUUID,
           (int)getOwner, (int)getGroup, (int)getMode, (int)getOwnerUUID, (int)getGroupUUID,
           owner, group, mode, memcmp(&ownerUUID, &ownerBytes, sizeof ownerUUID) == 0,
           memcmp(&groupUUID, &groupBytes, sizeof groupUUID) == 0);

    FSFileSecurityRef copy = FSFileSecurityRefCreateCopy(kCFAllocatorDefault, security);
    UInt32 copyOwner = 0;
    OSStatus copyStatus = FSFileSecurityGetOwner(copy, &copyOwner);
    acl_t emptyACL = acl_init(0);
    OSStatus setACL = FSFileSecuritySetAccessControlList(security, emptyACL);
    OSStatus copyACL = FSFileSecurityCopyAccessControlList(security, &acl);
    printf("file-security-copy-acl %d %d %u %d %d\n", copy != NULL, (int)copyStatus, copyOwner,
           (int)setACL, (int)copyACL);
    if (acl && acl != kFSFileSecurityRemoveACL) acl_free(acl);
    if (emptyACL) acl_free(emptyACL);

    FSPermissionInfo permissions = {.userID = 42, .groupID = 43, .userAccess = 1, .mode = 0600};
    FSFileSecurityRef fromPermissions = FSFileSecurityCreateWithFSPermissionInfo(kCFAllocatorDefault, &permissions);
    UInt32 permissionOwner = 0, permissionGroup = 0;
    UInt16 permissionMode = 0;
    OSStatus permissionOwnerStatus = FSFileSecurityGetOwner(fromPermissions, &permissionOwner);
    OSStatus permissionGroupStatus = FSFileSecurityGetGroup(fromPermissions, &permissionGroup);
    OSStatus permissionModeStatus = FSFileSecurityGetMode(fromPermissions, &permissionMode);
    printf("file-security-permissions %d %d %d %d %u %u %04x\n", fromPermissions != NULL,
           (int)permissionOwnerStatus, (int)permissionGroupStatus, (int)permissionModeStatus,
           permissionOwner, permissionGroup, permissionMode);

    if (fromPermissions) CFRelease(fromPermissions);
    if (copy) CFRelease(copy);
    if (security) CFRelease(security);
    if (ownerValue) CFRelease(ownerValue);
    if (groupValue) CFRelease(groupValue);
}

static void
date_time(void)
{
    CFAbsoluteTime time = 0;
    OSStatus status = UCConvertSecondsToCFAbsoluteTime(0, &time);
    printf("seconds-to-cf %d %.6f\n", (int)status, time);
    UTCDateTime date = {0, 0, 32768};
    status = UCConvertUTCDateTimeToCFAbsoluteTime(&date, &time);
    printf("utc-to-cf %d %.6f\n", (int)status, time);
    UTCDateTime roundTrip = {0};
    status = UCConvertCFAbsoluteTimeToUTCDateTime(0.5, &roundTrip);
    printf("cf-to-utc %d %u %u %u\n", (int)status, roundTrip.highSeconds, roundTrip.lowSeconds,
           roundTrip.fraction);
    LongDateTime longDate = 0;
    status = UCConvertCFAbsoluteTimeToLongDateTime(0, &longDate);
    printf("cf-to-long %d %" PRId64 "\n", (int)status, (int64_t)longDate);
    status = UCConvertLongDateTimeToCFAbsoluteTime(longDate, &time);
    printf("long-to-cf %d %.6f\n", (int)status, time);
    UInt32 seconds = 0;
    status = UCConvertCFAbsoluteTimeToSeconds(0, &seconds);
    printf("cf-to-seconds %d %u\n", (int)status, seconds);
    status = UCConvertCFAbsoluteTimeToSeconds(-4000000000.0, &seconds);
    printf("cf-seconds-underflow %d\n", (int)status);
}

struct flatten_totals {
    SInt32 items;
    SInt32 bytes;
};

static OSErr
count_flattened_item(SInt32 size, void *data, void *refCon)
{
    (void)data;
    struct flatten_totals *totals = refCon;
    totals->items++;
    totals->bytes += size;
    return noErr;
}

static void
collections(void)
{
    const CollectionTag tag = 0x74657374;
    const UInt8 first[] = {1, 2, 3};
    const UInt8 second[] = {8, 9};
    Collection c = NewCollection();
    printf("collection-create %d %d %d\n", c != NULL, CountCollectionItems(c), GetCollectionDefaultAttributes(c));
    OSErr firstAdded = AddCollectionItem(c, tag, 1, sizeof first, first);
    OSErr secondAdded = AddCollectionItem(c, tag, 2, sizeof second, second);
    printf("collection-add %d %d\n", firstAdded, secondAdded);
    printf("collection-counts %d %d %d %d\n", CountCollectionItems(c), CountCollectionTags(c),
           CountTaggedCollectionItems(c, tag), CollectionTagExists(c, tag));
    SInt32 size = 0;
    UInt8 data[8] = {0};
    OSErr error = GetCollectionItem(c, tag, 1, &size, data);
    printf("collection-get %d %d %u %u %u\n", error, size, data[0], data[1], data[2]);
    SInt32 index = 0, attributes = 0;
    error = GetCollectionItemInfo(c, tag, 2, &index, &size, &attributes);
    printf("collection-info %d %d %d %d\n", error, index, size, attributes);
    CollectionTag indexedTag = 0;
    OSErr tagError = GetIndexedCollectionTag(c, 1, &indexedTag);
    printf("collection-tag %d %08x\n", tagError, (unsigned)indexedTag);
    SInt32 taggedIndex = 0;
    error = GetTaggedCollectionItemInfo(c, tag, 1, NULL, &taggedIndex, &size, NULL);
    printf("collection-tag-info %d %d %d\n", error, taggedIndex, size);
    error = SetCollectionItemInfo(c, tag, 2, kCollectionUser0Mask, kCollectionUser0Mask);
    printf("collection-set-info %d %d\n", error, GetCollectionItemInfo(c, tag, 2, NULL, NULL, &attributes) == noErr ? attributes : -1);

    Handle item = NewHandle(16);
    error = GetCollectionItemHdl(c, tag, 1, item);
    printf("collection-handle %d %ld %u %u\n", error, (long)GetHandleSize(item), (*item)[0], (*item)[2]);
    DisposeHandle(item);

    Collection copy = NewCollection();
    Collection copied = CopyCollection(c, copy);
    Collection clone = CloneCollection(c);
    printf("collection-copy %d %d %d %d\n", copied == copy, CountCollectionItems(copy),
           clone != NULL, CountCollectionItems(clone));
    RetainCollection(c);
    printf("collection-owners %d %lu\n", CountCollectionOwners(c), (unsigned long)GetCollectionRetainCount(c));
    ReleaseCollection(c);
    OSErr removed = RemoveCollectionItem(c, tag, 1);
    OSErr removedAgain = RemoveCollectionItem(c, tag, 1);
    printf("collection-remove %d %d %d\n", removed, removedAgain, CountCollectionItems(c));
    EmptyCollection(copy);
    PurgeCollectionTag(clone, tag);
    printf("collection-empty %d %d\n", CountCollectionItems(copy), CountCollectionItems(clone));
    DisposeCollection(copy);
    DisposeCollection(clone);
    DisposeCollection(c);

    Collection source = NewCollection();
    AddCollectionItem(source, tag, 7, sizeof first, first);
    AddCollectionItem(source, tag, 8, sizeof second, second);
    Handle flattened = NewHandle(0);
    OSErr flattenStatus = FlattenCollectionToHdl(source, flattened);
    Collection restored = NewCollection();
    OSErr unflattenStatus = UnflattenCollectionFromHdl(restored, flattened);
    memset(data, 0, sizeof data);
    size = 0;
    OSErr restoredStatus = GetCollectionItem(restored, tag, 7, &size, data);
    printf("collection-flatten %d %ld %d %ld %d %d %u %u %u\n", (int)flattenStatus,
           (long)GetHandleSize(flattened), (int)unflattenStatus, (long)CountCollectionItems(restored),
           (int)restoredStatus, size, data[0], data[1], data[2]);
    struct flatten_totals totals = {0};
    OSErr callbackStatus = FlattenCollection(restored, NewCollectionFlattenUPP(count_flattened_item), &totals);
    printf("collection-callback %d %d %d\n", (int)callbackStatus, totals.items, totals.bytes);
    DisposeHandle(flattened);
    DisposeCollection(restored);
    DisposeCollection(source);
}

static void
pascal_strings(void)
{
    Str255 text = {11, 'H', 'e', 'l', 'l', 'o', ' ', 'W', 'o', 'r', 'l', 'd'};
    Str255 prefix = {5, 'H', 'e', 'l', 'l', 'o'};
    Str255 search = {5, 'W', 'o', 'r', 'l', 'd'};
    Str255 chars = {2, ' ', '!'};
    Str255 copy = {0};
    printf("pascal-base %d %d %d %d %d %d\n", PLstrlen(text), PLstrcmp(text, prefix),
           PLstrncmp(text, prefix, 5), PLstrspn(text, prefix), PLpos(text, search),
           PLpos(text, chars));
    printf("pascal-search %td %td %td %td\n", PLstrchr(text, 'o') - (Ptr)text,
           PLstrrchr(text, 'o') - (Ptr)text, PLstrpbrk(text, chars) - (Ptr)text,
           PLstrstr(text, search) - (Ptr)text);
    PLstrcpy(copy, prefix);
    printf("pascal-copy %d %d\n", PLstrlen(copy), PLstrcmp(copy, prefix));
    PLstrncpy(copy, text, 5);
    PLstrncat(copy, search, 2);
    printf("pascal-append %d %d %d\n", PLstrlen(copy), PLstrncmp(copy, text, 5), PLpos(copy, search));
    PLstrcat(copy, search);
    printf("pascal-cat %d %d\n", PLstrlen(copy), PLpos(copy, search));
}

static void
locales(void)
{
    LocaleRef locale = NULL;
    OSStatus status = LocaleRefFromLocaleString("en_US", &locale);
    char part[32] = {0};
    OSStatus partStatus = LocaleRefGetPartString(locale, kLocaleLanguageMask, sizeof part, part);
    printf("locale-ref %d %d %s\n", (int)status, (int)partStatus, part);
    LocaleRef coded = NULL;
    OSStatus codeStatus = LocaleRefFromLangOrRegionCode(langEnglish, verUS, &coded);
    memset(part, 0, sizeof part);
    OSStatus codedPartStatus = LocaleRefGetPartString(coded, kLocaleRegionMask, sizeof part, part);
    printf("locale-codes %d %d %s\n", (int)codeStatus, (int)codedPartStatus, part);
    LocaleRef regionOnly = NULL;
    LocaleRef languageOnly = NULL;
    LocaleRefFromLangOrRegionCode(langUnspecified, verUS, &regionOnly);
    LocaleRefFromLangOrRegionCode(langEnglish, -1, &languageOnly);
    memset(part, 0, sizeof part);
    LocaleRefGetPartString(regionOnly, kLocaleRegionMask, sizeof part, part);
    printf("locale-region-only %s\n", part);
    memset(part, 0, sizeof part);
    LocaleRefGetPartString(languageOnly, kLocaleLanguageMask, sizeof part, part);
    printf("locale-language-only %s\n", part);
    CFStringRef languageIdentifier = CFLocaleCreateCanonicalLocaleIdentifierFromScriptManagerCodes(NULL, langEnglish, -1);
    CFStringRef regionIdentifier = CFLocaleCreateCanonicalLocaleIdentifierFromScriptManagerCodes(NULL, -1, verUS);
    char identifier[64] = {0};
    CFStringGetCString(languageIdentifier, identifier, sizeof identifier, kCFStringEncodingUTF8);
    printf("locale-language-id %s\n", identifier);
    memset(identifier, 0, sizeof identifier);
    CFStringGetCString(regionIdentifier, identifier, sizeof identifier, kCFStringEncodingUTF8);
    printf("locale-region-id %s\n", identifier);
    ItemCount count = 0;
    OSStatus operationStatus = LocaleOperationCountLocales(kUnicodeCollationClass, &count);
    printf("locale-operation-count %d %lu\n", (int)operationStatus, (unsigned long)count);
    LocaleAndVariant operationLocales[256] = {0};
    ItemCount actualLocales = 0;
    OSStatus listStatus = LocaleOperationGetLocales(kUnicodeCollationClass, 256, &actualLocales, operationLocales);
    printf("locale-operation-list %d %lu\n", (int)listStatus, (unsigned long)actualLocales);
    for (ItemCount i = 0; i < actualLocales; i++) {
        char languagePart[32] = {0}, languageVariant[32] = {0}, scriptPart[32] = {0};
        char scriptVariant[32] = {0}, regionPart[32] = {0}, regionVariant[32] = {0};
        char allParts[128] = {0};
        LocaleRefGetPartString(operationLocales[i].locale, kLocaleLanguageMask, sizeof languagePart, languagePart);
        LocaleRefGetPartString(operationLocales[i].locale, kLocaleLanguageVariantMask, sizeof languageVariant, languageVariant);
        LocaleRefGetPartString(operationLocales[i].locale, kLocaleScriptMask, sizeof scriptPart, scriptPart);
        LocaleRefGetPartString(operationLocales[i].locale, kLocaleScriptVariantMask, sizeof scriptVariant, scriptVariant);
        LocaleRefGetPartString(operationLocales[i].locale, kLocaleRegionMask, sizeof regionPart, regionPart);
        LocaleRefGetPartString(operationLocales[i].locale, kLocaleRegionVariantMask, sizeof regionVariant, regionVariant);
        LocaleRefGetPartString(operationLocales[i].locale, kLocaleAllPartsMask, sizeof allParts, allParts);
        printf("locale-operation-item %lu %s|%s|%s|%s|%s|%s|%s|%u\n", (unsigned long)i, languagePart,
               languageVariant, scriptPart, scriptVariant, regionPart, regionVariant, allParts, operationLocales[i].opVariant);
    }
    LangCode language = -1;
    RegionCode region = -1;
    OSStatus stringCodesStatus = LocaleStringToLangAndRegionCodes("en_US", &language, &region);
    printf("locale-string-codes %d %d %d\n", (int)stringCodesStatus, language, region);
    CollatorRef collator = NULL;
    OSStatus collatorStatus = UCCreateCollator(locale, 0, kUCCollateStandardOptions, &collator);
    UniChar a[] = {'a'}, b[] = {'b'};
    Boolean equivalent = false;
    SInt32 order = 0;
    OSStatus compareStatus = collator ? UCCompareText(collator, a, 1, b, 1, &equivalent, &order) : paramErr;
    SInt32 orderSign = order > 0 ? 1 : order < 0 ? -1 : 0;
    printf("locale-collation %d %d %d %d\n", (int)collatorStatus, (int)compareStatus, equivalent, orderSign);
    if (collator) UCDisposeCollator(&collator);
}

static void
multiprocessing(void)
{
    MPSemaphoreID semaphore = NULL;
    OSStatus createStatus = MPCreateSemaphore(2, 1, &semaphore);
    OSStatus waitStatus = MPWaitOnSemaphore(semaphore, kDurationImmediate);
    OSStatus timeoutStatus = MPWaitOnSemaphore(semaphore, kDurationImmediate);
    OSStatus signalStatus = MPSignalSemaphore(semaphore);
    printf("mp-semaphore %d %d %d %d\n", (int)createStatus, (int)waitStatus,
           (int)timeoutStatus, (int)signalStatus);
    MPDeleteSemaphore(semaphore);

    MPQueueID queue = NULL;
    MPCreateQueue(&queue);
    MPNotifyQueue(queue, (void *)1, (void *)2, (void *)3);
    void *a = NULL, *b = NULL, *c = NULL;
    OSStatus queueStatus = MPWaitOnQueue(queue, &a, &b, &c, kDurationImmediate);
    printf("mp-queue %d %ld %ld %ld %d\n", (int)queueStatus, (long)a, (long)b, (long)c,
           (int)MPWaitOnQueue(queue, NULL, NULL, NULL, kDurationImmediate));
    MPDeleteQueue(queue);

    MPEventID event = NULL;
    MPCreateEvent(&event);
    MPSetEvent(event, 0x5);
    MPEventFlags flags = 0x3;
    OSStatus eventStatus = MPWaitForEvent(event, &flags, kDurationImmediate);
    printf("mp-event %d %u\n", (int)eventStatus, flags);
    MPDeleteEvent(event);

    MPCriticalRegionID region = NULL;
    MPCreateCriticalRegion(&region);
    OSStatus entered = MPEnterCriticalRegion(region, kDurationImmediate);
    OSStatus exited = MPExitCriticalRegion(region);
    printf("mp-critical %d %d\n", (int)entered, (int)exited);
    MPDeleteCriticalRegion(region);

    LogicalAddress block = MPAllocateAligned(32, kMPAllocate32ByteAligned, kMPAllocateClearMask);
    printf("mp-memory %d %d %d\n", block != NULL, MPGetAllocatedBlockSize(block) >= 32,
           block ? ((uintptr_t)block % 32 == 0) : 0);
    MPFree(block);

    TaskStorageIndex index = 0;
    OSStatus indexStatus = MPAllocateTaskStorageIndex(&index);
    MPSetTaskStorageValue(index, (LogicalAddress)(uintptr_t)0x1234);
    printf("mp-storage %d %d\n", (int)indexStatus,
           MPGetTaskStorageValue(index) == (LogicalAddress)(uintptr_t)0x1234);
    MPDeallocateTaskStorageIndex(index);
}

static void
mp_timers_and_notifications(void)
{
    MPQueueID queue = NULL;
    MPNotificationID notification = NULL;
    OSStatus queueStatus = MPCreateQueue(&queue);
    OSStatus createStatus = MPCreateNotification(&notification);
    OSStatus modifyStatus = MPModifyNotification(notification, (MPOpaqueID)queue,
                                                  (void *)11, (void *)12, (void *)13);
    OSStatus causeStatus = MPCauseNotification(notification);
    void *p1 = NULL, *p2 = NULL, *p3 = NULL;
    OSStatus waitStatus = MPWaitOnQueue(queue, &p1, &p2, &p3, 1000);
    printf("mp-notification %d %d %d %d %d %ld %ld %ld\n", (int)queueStatus, (int)createStatus,
           (int)modifyStatus, (int)causeStatus, (int)waitStatus, (long)p1, (long)p2, (long)p3);
    printf("mp-notification-delete %d %d\n", (int)MPDeleteNotification(notification),
           (int)MPDeleteQueue(queue));

    queue = NULL;
    MPTimerID timer = NULL;
    MPCreateQueue(&queue);
    OSStatus timerStatus = MPCreateTimer(&timer);
    OSStatus notifyStatus = MPSetTimerNotify(timer, (MPOpaqueID)queue, (void *)21, (void *)22, (void *)23);
    AbsoluteTime deadline = AddDurationToAbsolute(20, UpTime());
    OSStatus armStatus = MPArmTimer(timer, &deadline, 0);
    p1 = p2 = p3 = NULL;
    OSStatus timerWaitStatus = MPWaitOnQueue(queue, &p1, &p2, &p3, 5000);
    printf("mp-timer %d %d %d %d %d %ld %ld %ld\n", (int)timerStatus, (int)notifyStatus,
           (int)armStatus, (int)timerWaitStatus, (int)MPCancelTimer(timer, NULL), (long)p1, (long)p2, (long)p3);
    printf("mp-timer-delete %d %d\n", (int)MPDeleteTimer(timer), (int)MPDeleteQueue(queue));
}

static void *
thread_entry(void *parameter)
{
    return (void *)((uintptr_t)parameter + 5);
}

static void
threads(void)
{
    ThreadState state = 0;
    OSErr stateStatus = GetThreadState(kCurrentThreadID, &state);
    printf("thread-current-state %d %u\n", (int)stateStatus, state);
    ByteCount freeStack = 0;
    OSErr stackStatus = ThreadCurrentStackSpace(kCurrentThreadID, &freeStack);
    printf("thread-stack %d %d\n", (int)stackStatus, freeStack > 0);
    OSErr criticalBegin = ThreadBeginCritical();
    OSErr criticalEnd = ThreadEndCritical();
    printf("thread-critical %d %d %d\n", (int)criticalBegin, (int)criticalEnd,
           (int)ThreadEndCritical());

    ThreadID thread = 0;
    OSErr createStatus = NewThread(kCooperativeThread, NewThreadEntryUPP(thread_entry), (void *)7, 0, 0, NULL,
                                   &thread);
    ThreadState createdState = 0;
    OSErr createdStateStatus = createStatus == noErr ? GetThreadState(thread, &createdState) : createStatus;
    void *result = NULL;
    OSErr disposeStatus = createStatus == noErr ? DisposeThread(thread, &result, false) : createStatus;
    printf("thread-lifecycle %d %d %u %d %ld\n", (int)createStatus, (int)createdStateStatus, createdState,
           (int)disposeStatus, (long)(uintptr_t)result);
    printf("thread-missing %d\n", (int)GetThreadState((ThreadID)0x7fffffff, &state));
}

static volatile int time_task_fired;

static void
time_task_entry(TMTaskPtr task)
{
    (void)task;
    time_task_fired++;
}

static void
identity_commit_status(CSIdentityRef identity, CFIndex status, CFErrorRef error, void *info)
{
    (void)identity;
    (void)status;
    (void)error;
    (void)info;
}

static void
time_manager(void)
{
    TMTask task = {0};
    task.tmAddr = NewTimerUPP(time_task_entry);
    OSErr installStatus = InstallTimeTask((QElemPtr)&task);
    OSErr primeStatus = PrimeTimeTask((QElemPtr)&task, 5);
    usleep(50000);
    printf("time-task %d %d %d %d %ld\n", (int)installStatus, (int)primeStatus, time_task_fired,
           (task.qType & kTMTaskActive) != 0, task.tmCount);
    printf("time-task-remove %d\n", (int)RemoveTimeTask((QElemPtr)&task));
}

static void
power_manager(void)
{
    printf("power-manager %d %d %d %d\n", BatteryCount(), CurrentProcessorSpeed(),
           MinimumProcessorSpeed(), MaximumProcessorSpeed());
}

static void
identity_services(void)
{
    CSIdentityAuthorityRef local = CSGetLocalIdentityAuthority();
    CFStringRef authorityName = CSIdentityAuthorityCopyLocalizedName(local);
    char authorityText[128] = "?";
    if (authorityName) CFStringGetCString(authorityName, authorityText, sizeof authorityText, kCFStringEncodingUTF8);
    printf("identity-authority %d %s\n", local != NULL, authorityText);
    if (authorityName) CFRelease(authorityName);

    CSIdentityQueryRef query = CSIdentityQueryCreateForCurrentUser(kCFAllocatorDefault);
    Boolean executed = query && CSIdentityQueryExecute(query, 0, NULL);
    CFArrayRef results = executed ? CSIdentityQueryCopyResults(query) : NULL;
    CSIdentityRef user = results && CFArrayGetCount(results) ? (CSIdentityRef)CFArrayGetValueAtIndex(results, 0) : NULL;
    CFStringRef userName = user ? CSIdentityGetPosixName(user) : NULL;
    CFStringRef fullName = user ? CSIdentityGetFullName(user) : NULL;
    char shortText[256] = "?", fullText[256] = "?";
    if (userName) CFStringGetCString(userName, shortText, sizeof shortText, kCFStringEncodingUTF8);
    if (fullName) CFStringGetCString(fullName, fullText, sizeof fullText, kCFStringEncodingUTF8);
    CFStringRef uuidText = user ? CFUUIDCreateString(kCFAllocatorDefault, CSIdentityGetUUID(user)) : NULL;
    char uuidBuffer[64] = "?";
    if (uuidText) CFStringGetCString(uuidText, uuidBuffer, sizeof uuidBuffer, kCFStringEncodingUTF8);
    printf("identity-current %d %ld %ld %s %s %s %d %d %ld\n", executed,
           (long)(results ? CFArrayGetCount(results) : 0), (long)CSIdentityGetPosixID(user),
           shortText, fullText, uuidBuffer, CSIdentityIsEnabled(user), CSIdentityIsHidden(user),
           (long)(CSIdentityGetAliases(user) ? CFArrayGetCount(CSIdentityGetAliases(user)) : -1));

    CSIdentityRef copy = user ? CSIdentityCreateCopy(kCFAllocatorDefault, user) : NULL;
    printf("identity-copy %d %d %d\n", copy != NULL, copy && user && CFEqual(copy, user),
           (int)(copy ? CSIdentityGetClass(copy) : 0));
    CSIdentityQueryRef byName = userName ? CSIdentityQueryCreateForName(kCFAllocatorDefault, userName,
        kCSIdentityQueryStringEquals, kCSIdentityClassUser, local) : NULL;
    Boolean byNameExecuted = byName && CSIdentityQueryExecute(byName, 0, NULL);
    CFArrayRef byNameResults = byNameExecuted ? CSIdentityQueryCopyResults(byName) : NULL;
    printf("identity-name-query %d %ld\n", byNameExecuted,
           (long)(byNameResults ? CFArrayGetCount(byNameResults) : 0));

    CFDataRef reference = user ? CSIdentityCreatePersistentReference(kCFAllocatorDefault, user) : NULL;
    CSIdentityQueryRef byReference = reference ? CSIdentityQueryCreateForPersistentReference(kCFAllocatorDefault, reference) : NULL;
    Boolean referenceExecuted = byReference && CSIdentityQueryExecute(byReference, 0, NULL);
    CFArrayRef byReferenceResults = referenceExecuted ? CSIdentityQueryCopyResults(byReference) : NULL;
    printf("identity-reference %d %d %ld\n", reference != NULL, referenceExecuted,
           (long)(byReferenceResults ? CFArrayGetCount(byReferenceResults) : 0));

    CSIdentityQueryRef groupQuery = CSIdentityQueryCreateForPosixID(kCFAllocatorDefault, getgid(),
        kCSIdentityClassGroup, local);
    Boolean groupExecuted = groupQuery && CSIdentityQueryExecute(groupQuery, 0, NULL);
    CFArrayRef groups = groupExecuted ? CSIdentityQueryCopyResults(groupQuery) : NULL;
    CSIdentityRef group = groups && CFArrayGetCount(groups) ? (CSIdentityRef)CFArrayGetValueAtIndex(groups, 0) : NULL;
    printf("identity-group %d %ld %d\n", groupExecuted, (long)(groups ? CFArrayGetCount(groups) : 0),
           group ? CSIdentityIsMemberOfGroup(user, group) : 0);

    CSIdentityClientContext client = {.version = 0, .statusUpdated = identity_commit_status};
    Boolean idleCommit = user && CSIdentityCommitAsynchronously(user, &client, CFRunLoopGetCurrent(),
                                                                kCFRunLoopDefaultMode, NULL);
    printf("identity-commit-idle %d %d\n", idleCommit, CSIdentityIsCommitting(user));
    CSIdentityRemoveClient(user);

    if (byReferenceResults) CFRelease(byReferenceResults);
    if (byReference) CFRelease(byReference);
    if (reference) CFRelease(reference);
    if (byNameResults) CFRelease(byNameResults);
    if (byName) CFRelease(byName);
    if (groups) CFRelease(groups);
    if (groupQuery) CFRelease(groupQuery);
    if (copy) CFRelease(copy);
    if (uuidText) CFRelease(uuidText);
    if (results) CFRelease(results);
    if (query) CFRelease(query);
}

int
main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    time_math();
    date_time();
    legacy_utilities();
    hfs_strings();
    unicode_helpers();
    folder_helpers();
    file_security();
    power_manager();
    collections();
    pascal_strings();
    multiprocessing();
    if (argc > 1 && strcmp(argv[1], "--threads") == 0) threads();
    if (argc > 1 && strcmp(argv[1], "--time-manager") == 0) time_manager();
    if (argc > 1 && strcmp(argv[1], "--locales") == 0) locales();
    if (argc > 1 && strcmp(argv[1], "--mp-timers") == 0) mp_timers_and_notifications();
    if (argc > 1 && strcmp(argv[1], "--identity") == 0) identity_services();
    return 0;
}
