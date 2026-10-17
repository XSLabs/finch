/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* The classic Folder Manager calls built on Finch's FSFindFolder table. */
#include "CarbonCore_Finch.h"
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const FolderType folder_types[] = {
    kDomainLibraryFolderType, kPreferencesFolderType,      kApplicationSupportFolderType,
    kCachedDataFolderType,    kFontsFolderType,            kDesktopFolderType,
    kDocumentsFolderType,     kDownloadsFolderType,        kMovieDocumentsFolderType,
    kMusicDocumentsFolderType,kPictureDocumentsFolderType, kPublicFolderType,
    kCurrentUserFolderType,   kApplicationsFolderType,     kTrashFolderType,
    kLogsFolderType,          kFrameworksFolderType,       kPreferencePanesFolderType,
    kInternetPlugInFolderType,kAudioComponentsFolderType,  kColorSyncProfilesFolderType,
    kKeyboardLayoutsFolderType,kScriptsFolderType,         kServicesFolderType,
    kSharedUserDataFolderType,kUsersFolderType,            kSystemFolderType,
    kCoreServicesFolderType,  kUtilitiesFolderType
};

OSErr
FindFolder(FSVolumeRefNum vRefNum, OSType folderType, Boolean createFolder, FSVolumeRefNum *foundVRefNum,
           SInt32 *foundDirID)
{
    FSRef ref;
    OSErr error = FSFindFolder(vRefNum, folderType, createFolder, &ref);
    if (error)
        return error;
    FSCatalogInfo info;
    error = FSGetCatalogInfo(&ref, kFSCatInfoVolume | kFSCatInfoNodeID, &info, NULL, NULL, NULL);
    if (error)
        return error;
    if (foundVRefNum)
        *foundVRefNum = info.volume;
    if (foundDirID)
        *foundDirID = (SInt32)info.nodeID;
    return noErr;
}

OSErr
GetFolderTypes(UInt32 requestedTypeCount, UInt32 *totalTypeCount, FolderType *theTypes)
{
    if (!totalTypeCount || (requestedTypeCount && !theTypes))
        return paramErr;
    UInt32 count = (UInt32)(sizeof folder_types / sizeof folder_types[0]);
    *totalTypeCount = count;
    if (theTypes) {
        UInt32 copied = requestedTypeCount < count ? requestedTypeCount : count;
        memcpy(theTypes, folder_types, copied * sizeof *theTypes);
    }
    return noErr;
}

OSStatus
GetFolderNameUnicode(FSVolumeRefNum vRefNum, OSType foldType, FSVolumeRefNum *foundVRefNum, HFSUniStr255 *name)
{
    if (!name)
        return paramErr;
    FSRef ref;
    OSErr error = FSFindFolder(vRefNum, foldType, false, &ref);
    if (error)
        return error;
    if (foundVRefNum) {
        FSCatalogInfo info;
        error = FSGetCatalogInfo(&ref, kFSCatInfoVolume, &info, NULL, NULL, NULL);
        if (error)
            return error;
        *foundVRefNum = info.volume;
    }
    UInt8 path[PATH_MAX];
    error = FSRefMakePath(&ref, path, sizeof path);
    if (error)
        return error;
    const char *leaf = strrchr((const char *)path, '/');
    leaf = leaf ? leaf + 1 : (const char *)path;
    CFStringRef text = CFStringCreateWithFileSystemRepresentation(NULL, leaf);
    if (!text)
        return paramErr;
    CFIndex length = CFStringGetLength(text);
    if (length > 255) {
        CFRelease(text);
        return bdNamErr;
    }
    name->length = (UInt16)length;
    if (length)
        CFStringGetCharacters(text, CFRangeMake(0, length), name->unicode);
    CFRelease(text);
    return noErr;
}

OSErr
ReleaseFolder(FSVolumeRefNum vRefNum, OSType folderType)
{
    /* Folder Manager holds are not used on macOS. */
    (void)vRefNum;
    (void)folderType;
    return noErr;
}

OSErr
InvalidateFolderDescriptorCache(FSVolumeRefNum vRefNum, SInt32 dirID)
{
    /* FSFindFolder resolves paths on demand, so there is no descriptor cache. */
    (void)vRefNum;
    (void)dirID;
    return noErr;
}

static OSErr
folder_real_path(FSVolumeRefNum domainOrVRefNum, OSType folderType, char path[PATH_MAX])
{
    FSRef ref;
    FSVolumeRefNum domain = domainOrVRefNum;
    if (domainOrVRefNum == kOnAppropriateDisk) {
        switch (folderType) {
        case kDesktopFolderType:
        case kDocumentsFolderType:
        case kDownloadsFolderType:
        case kMovieDocumentsFolderType:
        case kMusicDocumentsFolderType:
        case kPictureDocumentsFolderType:
        case kPublicFolderType:
        case kCurrentUserFolderType:
        case kTrashFolderType:
        case kPreferencesFolderType:
        case kApplicationSupportFolderType:
        case kCachedDataFolderType:
            domain = kUserDomain;
            break;
        default:
            domain = kSystemDomain;
            break;
        }
    } else if (domainOrVRefNum == kOnSystemDisk) {
        domain = kSystemDomain;
    }
    OSErr error = FSFindFolder(domain, folderType, false, &ref);
    if (error)
        return error;
    UInt8 rawPath[PATH_MAX];
    error = FSRefMakePath(&ref, rawPath, sizeof rawPath);
    if (error)
        return error;
    if (!realpath((const char *)rawPath, path))
        return fnfErr;
    return noErr;
}

static Boolean
path_is_inside(const char *parent, const char *child)
{
    size_t length = strlen(parent);
    if (strncmp(parent, child, length) != 0)
        return false;
    return child[length] == 0 || parent[length - 1] == '/' || child[length] == '/';
}

OSErr
DetermineIfPathIsEnclosedByFolder(FSVolumeRefNum domainOrVRefNum, OSType folderType,
                                  const UInt8 *utf8Path, Boolean pathIsRealPath, Boolean *outResult)
{
    if (!utf8Path)
        return paramErr;
    char folder[PATH_MAX];
    OSErr error = folder_real_path(domainOrVRefNum, folderType, folder);
    if (error)
        return error;

    char path[PATH_MAX];
    if (pathIsRealPath) {
        if (strlcpy(path, (const char *)utf8Path, sizeof path) >= sizeof path)
            return bdNamErr;
    } else if (!realpath((const char *)utf8Path, path)) {
        return fnfErr;
    }
    if (outResult)
        *outResult = path_is_inside(folder, path);
    return noErr;
}

OSErr
FSDetermineIfRefIsEnclosedByFolder(FSVolumeRefNum domainOrVRefNum, OSType folderType,
                                   const FSRef *inRef, Boolean *outResult)
{
    if (!inRef)
        return paramErr;
    (void)domainOrVRefNum;
    (void)folderType;
    if (outResult)
        *outResult = false;
    /* Apple's current implementation rejects these refs with errFSBadFSRef. */
    return errFSBadFSRef;
}

OSErr
IdentifyFolder(FSVolumeRefNum vRefNum, SInt32 dirID, FolderType *folderType)
{
    if (!folderType)
        return paramErr;
    const FSVolumeRefNum domains[] = { kUserDomain, kLocalDomain, kSystemDomain };
    for (size_t domain = 0; domain < sizeof domains / sizeof domains[0]; domain++) {
        for (size_t i = 0; i < sizeof folder_types / sizeof folder_types[0]; i++) {
            FSRef ref;
            if (FSFindFolder(domains[domain], folder_types[i], false, &ref) != noErr)
                continue;
            FSCatalogInfo info;
            if (FSGetCatalogInfo(&ref, kFSCatInfoVolume | kFSCatInfoNodeID, &info, NULL, NULL, NULL) != noErr)
                continue;
            if ((SInt32)info.nodeID == dirID && info.volume == vRefNum) {
                *folderType = folder_types[i];
                return noErr;
            }
        }
    }
    return fnfErr;
}
