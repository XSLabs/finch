/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Carbon File Manager parameter blocks over Finch's FSRef calls. */
#include "CarbonCore_Finch.h"
#include <pthread.h>

typedef void (*PBWorkProc)(void *);

struct pb_work {
    ParmBlkPtr param;
    IOCompletionUPP completion;
    PBWorkProc work;
};

static void *
run_pb_work(void *context)
{
    struct pb_work *pending = context;
    pending->work(pending->param);
    if (pending->completion)
        InvokeIOCompletionUPP(pending->param, pending->completion);
    free(pending);
    return NULL;
}

static void
schedule_pb_work(ParmBlkPtr param, PBWorkProc work)
{
    FSRefParam *header = (FSRefParam *)param;
    struct pb_work *pending = malloc(sizeof *pending);
    if (!pending) {
        header->ioResult = memFullErr;
        if (header->ioCompletion)
            InvokeIOCompletionUPP(param, header->ioCompletion);
        return;
    }
    *pending = (struct pb_work){param, header->ioCompletion, work};
    pthread_t thread;
    int error = pthread_create(&thread, NULL, run_pb_work, pending);
    if (error) {
        free(pending);
        work(param);
        if (header->ioCompletion)
            InvokeIOCompletionUPP(param, header->ioCompletion);
        return;
    }
    pthread_detach(thread);
}

#define DEFINE_PB_PAIR(name, type, operation)                                      \
    static OSErr name##_operation(type *pb)                                        \
    {                                                                               \
        if (!pb)                                                                    \
            return paramErr;                                                        \
        return (operation);                                                         \
    }                                                                               \
    OSErr name##Sync(type *pb)                                                      \
    {                                                                               \
        OSErr error = name##_operation(pb);                                          \
        if (pb)                                                                     \
            pb->ioResult = error;                                                   \
        return error;                                                               \
    }                                                                               \
    static void name##_work(void *context)                                          \
    {                                                                               \
        (void)name##Sync((type *)context);                                           \
    }                                                                               \
    void name##Async(type *pb)                                                      \
    {                                                                               \
        if (pb)                                                                     \
            schedule_pb_work((ParmBlkPtr)pb, name##_work);                          \
    }

DEFINE_PB_PAIR(PBMakeFSRefUnicode, FSRefParam,
               FSMakeFSRefUnicode(pb->parentRef, pb->nameLength, pb->name, pb->textEncodingHint, pb->newRef))
DEFINE_PB_PAIR(PBCompareFSRefs, FSRefParam, FSCompareFSRefs(pb->ref, pb->parentRef))
DEFINE_PB_PAIR(PBCreateFileUnicode, FSRefParam,
               FSCreateFileUnicode(pb->parentRef, pb->nameLength, pb->name, pb->whichInfo, pb->catInfo, pb->newRef,
                                   pb->spec))
DEFINE_PB_PAIR(PBCreateDirectoryUnicode, FSRefParam,
               FSCreateDirectoryUnicode(pb->parentRef, pb->nameLength, pb->name, pb->whichInfo, pb->catInfo,
                                        pb->newRef, pb->spec, &pb->ioDirID))
DEFINE_PB_PAIR(PBDeleteObject, FSRefParam, FSDeleteObject(pb->ref))
DEFINE_PB_PAIR(PBUnlinkObject, FSRefParam, FSUnlinkObject(pb->ref))
DEFINE_PB_PAIR(PBMoveObject, FSRefParam, FSMoveObject(pb->ref, pb->parentRef, pb->newRef))
DEFINE_PB_PAIR(PBExchangeObjects, FSRefParam, FSExchangeObjects(pb->ref, pb->parentRef))
DEFINE_PB_PAIR(PBRenameUnicode, FSRefParam,
               FSRenameUnicode(pb->ref, pb->nameLength, pb->name, pb->textEncodingHint, pb->newRef))
DEFINE_PB_PAIR(PBGetCatalogInfo, FSRefParam,
               FSGetCatalogInfo(pb->ref, pb->whichInfo, pb->catInfo, pb->outName, pb->spec, pb->parentRef))
DEFINE_PB_PAIR(PBSetCatalogInfo, FSRefParam, FSSetCatalogInfo(pb->ref, pb->whichInfo, pb->catInfo))

DEFINE_PB_PAIR(PBOpenIterator, FSCatalogBulkParam,
               FSOpenIterator(pb->container, pb->iteratorFlags, &pb->iterator))
DEFINE_PB_PAIR(PBCloseIterator, FSCatalogBulkParam, FSCloseIterator(pb->iterator))
DEFINE_PB_PAIR(PBGetCatalogInfoBulk, FSCatalogBulkParam,
               FSGetCatalogInfoBulk(pb->iterator, pb->maximumItems, &pb->actualItems, &pb->containerChanged,
                                    pb->whichInfo, pb->catalogInfo, pb->refs, pb->specs, pb->names))
DEFINE_PB_PAIR(PBIterateForks, FSForkIOParam,
               FSIterateForks(pb->ref, &pb->forkIterator, pb->outForkName, &pb->positionOffset,
                              &pb->allocationAmount))

DEFINE_PB_PAIR(PBCreateFork, FSForkIOParam,
               FSCreateFork(pb->ref, pb->forkNameLength, pb->forkName))
DEFINE_PB_PAIR(PBDeleteFork, FSForkIOParam,
               FSDeleteFork(pb->ref, pb->forkNameLength, pb->forkName))
DEFINE_PB_PAIR(PBOpenFork, FSForkIOParam,
               FSOpenFork(pb->ref, pb->forkNameLength, pb->forkName, pb->permissions, &pb->forkRefNum))
DEFINE_PB_PAIR(PBGetForkPosition, FSForkIOParam,
               FSGetForkPosition(pb->forkRefNum, &pb->positionOffset))
DEFINE_PB_PAIR(PBSetForkPosition, FSForkIOParam,
               FSSetForkPosition(pb->forkRefNum, pb->positionMode, pb->positionOffset))
DEFINE_PB_PAIR(PBGetForkSize, FSForkIOParam,
               FSGetForkSize(pb->forkRefNum, &pb->positionOffset))
DEFINE_PB_PAIR(PBSetForkSize, FSForkIOParam,
               FSSetForkSize(pb->forkRefNum, pb->positionMode, pb->positionOffset))
DEFINE_PB_PAIR(PBAllocateFork, FSForkIOParam,
               FSAllocateFork(pb->forkRefNum, pb->allocationFlags, pb->positionMode, pb->positionOffset,
                              pb->allocationAmount, &pb->allocationAmount))
DEFINE_PB_PAIR(PBFlushFork, FSForkIOParam, FSFlushFork(pb->forkRefNum))
DEFINE_PB_PAIR(PBCloseFork, FSForkIOParam, FSCloseFork(pb->forkRefNum))

DEFINE_PB_PAIR(PBGetVolumeInfo, FSVolumeInfoParam,
               FSGetVolumeInfo(pb->ioVRefNum, pb->volumeIndex, &pb->ioVRefNum, pb->whichInfo, pb->volumeInfo,
                               pb->volumeName, pb->ref))

static OSStatus
resolve_node_id(FSRefParam *pb)
{
    if (!pb)
        return paramErr;
    return FSResolveNodeID(pb->ioVRefNum, pb->ioDirID, pb->newRef);
}

OSStatus
PBFSResolveNodeIDSync(FSRefParam *pb)
{
    OSStatus error = resolve_node_id(pb);
    if (pb)
        pb->ioResult = (OSErr)error;
    return error;
}

OSStatus
PBFSResolveNodeIDAsync(FSRefParam *pb)
{
    return PBFSResolveNodeIDSync(pb);
}

static OSStatus
flush_volume(FSRefParam *pb)
{
    return pb ? FSFlushVolume(pb->ioVRefNum) : paramErr;
}

OSStatus
PBFlushVolumeSync(FSRefParam *pb)
{
    OSStatus error = flush_volume(pb);
    if (pb)
        pb->ioResult = (OSErr)error;
    return error;
}

OSStatus
PBFlushVolumeAsync(FSRefParam *pb)
{
    return PBFlushVolumeSync(pb);
}

OSStatus
PBXLockRangeSync(FSRangeLockParam *pb)
{
    if (!pb)
        return paramErr;
    OSStatus error = FSLockRange(pb->forkRefNum, pb->positionMode, pb->positionOffset, pb->requestCount,
                                 &pb->rangeStart);
    pb->ioResult = (OSErr)error;
    return error;
}

OSStatus
PBXLockRangeAsync(FSRangeLockParam *pb)
{
    return PBXLockRangeSync(pb);
}

OSStatus
PBXUnlockRangeSync(FSRangeLockParam *pb)
{
    if (!pb)
        return paramErr;
    OSStatus error = FSUnlockRange(pb->forkRefNum, pb->positionMode, pb->positionOffset, pb->requestCount,
                                   &pb->rangeStart);
    pb->ioResult = (OSErr)error;
    return error;
}

OSStatus
PBXUnlockRangeAsync(FSRangeLockParam *pb)
{
    return PBXUnlockRangeSync(pb);
}

static OSErr
read_fork(FSForkIOParam *pb)
{
    if (!pb)
        return paramErr;
    ByteCount actual = 0;
    OSErr error = FSReadFork(pb->forkRefNum, pb->positionMode, pb->positionOffset, pb->requestCount, pb->buffer,
                             &actual);
    pb->actualCount = (UInt32)actual;
    return error;
}

OSErr
PBReadForkSync(FSForkIOParam *pb)
{
    OSErr error = read_fork(pb);
    if (pb)
        pb->ioResult = error;
    return error;
}

static void
read_fork_work(void *context)
{
    (void)PBReadForkSync(context);
}

void
PBReadForkAsync(FSForkIOParam *pb)
{
    if (pb)
        schedule_pb_work((ParmBlkPtr)pb, read_fork_work);
}

static OSErr
write_fork(FSForkIOParam *pb)
{
    if (!pb)
        return paramErr;
    ByteCount actual = 0;
    OSErr error = FSWriteFork(pb->forkRefNum, pb->positionMode, pb->positionOffset, pb->requestCount, pb->buffer,
                              &actual);
    pb->actualCount = (UInt32)actual;
    return error;
}

OSErr
PBWriteForkSync(FSForkIOParam *pb)
{
    OSErr error = write_fork(pb);
    if (pb)
        pb->ioResult = error;
    return error;
}

static void
write_fork_work(void *context)
{
    (void)PBWriteForkSync(context);
}

void
PBWriteForkAsync(FSForkIOParam *pb)
{
    if (pb)
        schedule_pb_work((ParmBlkPtr)pb, write_fork_work);
}

static OSErr
create_file_and_open(FSRefForkIOParam *pb)
{
    if (!pb)
        return paramErr;
    FSRef localRef;
    FSRef *newRef = pb->newRef ? pb->newRef : &localRef;
    OSErr error = FSCreateFileUnicode(pb->parentRef, pb->nameLength, pb->name, pb->whichInfo, pb->catInfo, newRef,
                                      NULL);
    if (error)
        return error;
    return FSOpenFork(newRef, pb->forkNameLength, pb->forkName, pb->permissions, &pb->forkRefNum);
}

OSStatus
PBCreateFileAndOpenForkUnicodeSync(FSRefForkIOParam *pb)
{
    OSStatus error = create_file_and_open(pb);
    if (pb)
        pb->ioResult = (OSErr)error;
    return error;
}

static void
create_file_and_open_work(void *context)
{
    (void)PBCreateFileAndOpenForkUnicodeSync(context);
}

void
PBCreateFileAndOpenForkUnicodeAsync(FSRefForkIOParam *pb)
{
    if (pb)
        schedule_pb_work((ParmBlkPtr)pb, create_file_and_open_work);
}

#undef DEFINE_PB_PAIR
