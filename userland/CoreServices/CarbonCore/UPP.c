/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* On Mach, Carbon UPPs are plain function pointers. These exported forms
   keep the same direct-call behavior as the SDK's inline helpers. */
#include "CarbonCore_Finch.h"

#undef NewComponentFunctionUPP
#undef DisposeComponentFunctionUPP
#undef NewComponentMPWorkFunctionUPP
#undef DisposeComponentMPWorkFunctionUPP
#undef NewComponentRoutineUPP
#undef DisposeComponentRoutineUPP
#undef NewDebugAssertOutputHandlerUPP
#undef DisposeDebugAssertOutputHandlerUPP
#undef NewDebugComponentCallbackUPP
#undef DisposeDebugComponentCallbackUPP
#undef NewDebuggerDisposeThreadUPP
#undef DisposeDebuggerDisposeThreadUPP
#undef NewDebuggerNewThreadUPP
#undef DisposeDebuggerNewThreadUPP
#undef NewDebuggerThreadSchedulerUPP
#undef DisposeDebuggerThreadSchedulerUPP
#undef NewDeferredTaskUPP
#undef DisposeDeferredTaskUPP
#undef NewExceptionHandlerUPP
#undef DisposeExceptionHandlerUPP
#undef NewFSVolumeEjectUPP
#undef DisposeFSVolumeEjectUPP
#undef NewFSVolumeMountUPP
#undef DisposeFSVolumeMountUPP
#undef NewFSVolumeUnmountUPP
#undef DisposeFSVolumeUnmountUPP
#undef NewFolderManagerNotificationUPP
#undef DisposeFolderManagerNotificationUPP
#undef NewGetMissingComponentResourceUPP
#undef DisposeGetMissingComponentResourceUPP
#undef NewIOCompletionUPP
#undef DisposeIOCompletionUPP
#undef NewIndexToUCStringUPP
#undef DisposeIndexToUCStringUPP
#undef NewKCCallbackUPP
#undef DisposeKCCallbackUPP
#undef NewResErrUPP
#undef DisposeResErrUPP
#undef NewSleepQUPP
#undef DisposeSleepQUPP
#undef NewThreadEntryUPP
#undef DisposeThreadEntryUPP
#undef NewThreadSchedulerUPP
#undef DisposeThreadSchedulerUPP
#undef NewThreadSwitchUPP
#undef DisposeThreadSwitchUPP
#undef NewThreadTerminationUPP
#undef DisposeThreadTerminationUPP
#undef NewTimerUPP
#undef DisposeTimerUPP
#undef NewUnicodeToTextFallbackUPP
#undef DisposeUnicodeToTextFallbackUPP
#undef InvokeComponentMPWorkFunctionUPP
#undef InvokeComponentRoutineUPP
#undef InvokeDebugAssertOutputHandlerUPP
#undef InvokeDebugComponentCallbackUPP
#undef InvokeDebuggerDisposeThreadUPP
#undef InvokeDebuggerNewThreadUPP
#undef InvokeDebuggerThreadSchedulerUPP
#undef InvokeDeferredTaskUPP
#undef InvokeExceptionHandlerUPP
#undef InvokeFSVolumeEjectUPP
#undef InvokeFSVolumeMountUPP
#undef InvokeFSVolumeUnmountUPP
#undef InvokeFolderManagerNotificationUPP
#undef InvokeGetMissingComponentResourceUPP
#undef InvokeIOCompletionUPP
#undef InvokeIndexToUCStringUPP
#undef InvokeResErrUPP
#undef InvokeThreadEntryUPP
#undef InvokeThreadSchedulerUPP
#undef InvokeThreadSwitchUPP
#undef InvokeThreadTerminationUPP
#undef InvokeTimerUPP
#undef InvokeUnicodeToTextFallbackUPP

#define DEFINE_UPP_CREATE(name, uppType, procType) \
    uppType name(procType routine) { return (uppType)routine; }
#define DEFINE_UPP_DISPOSE(name, uppType) \
    void name(uppType routine) { (void)routine; }

ComponentFunctionUPP
NewComponentFunctionUPP(ProcPtr userRoutine, ProcInfoType procInfo)
{
    (void)procInfo;
    return (ComponentFunctionUPP)userRoutine;
}
DEFINE_UPP_DISPOSE(DisposeComponentFunctionUPP, ComponentFunctionUPP)
DEFINE_UPP_CREATE(NewComponentMPWorkFunctionUPP, ComponentMPWorkFunctionUPP, ComponentMPWorkFunctionProcPtr)
DEFINE_UPP_DISPOSE(DisposeComponentMPWorkFunctionUPP, ComponentMPWorkFunctionUPP)
DEFINE_UPP_CREATE(NewComponentRoutineUPP, ComponentRoutineUPP, ComponentRoutineProcPtr)
DEFINE_UPP_DISPOSE(DisposeComponentRoutineUPP, ComponentRoutineUPP)
DEFINE_UPP_CREATE(NewDebugAssertOutputHandlerUPP, DebugAssertOutputHandlerUPP, DebugAssertOutputHandlerProcPtr)
DEFINE_UPP_DISPOSE(DisposeDebugAssertOutputHandlerUPP, DebugAssertOutputHandlerUPP)
DEFINE_UPP_CREATE(NewDebugComponentCallbackUPP, DebugComponentCallbackUPP, DebugComponentCallbackProcPtr)
DEFINE_UPP_DISPOSE(DisposeDebugComponentCallbackUPP, DebugComponentCallbackUPP)
DEFINE_UPP_CREATE(NewDebuggerDisposeThreadUPP, DebuggerDisposeThreadUPP, DebuggerDisposeThreadProcPtr)
DEFINE_UPP_DISPOSE(DisposeDebuggerDisposeThreadUPP, DebuggerDisposeThreadUPP)
DEFINE_UPP_CREATE(NewDebuggerNewThreadUPP, DebuggerNewThreadUPP, DebuggerNewThreadProcPtr)
DEFINE_UPP_DISPOSE(DisposeDebuggerNewThreadUPP, DebuggerNewThreadUPP)
DEFINE_UPP_CREATE(NewDebuggerThreadSchedulerUPP, DebuggerThreadSchedulerUPP, DebuggerThreadSchedulerProcPtr)
DEFINE_UPP_DISPOSE(DisposeDebuggerThreadSchedulerUPP, DebuggerThreadSchedulerUPP)
DEFINE_UPP_CREATE(NewDeferredTaskUPP, DeferredTaskUPP, DeferredTaskProcPtr)
DEFINE_UPP_DISPOSE(DisposeDeferredTaskUPP, DeferredTaskUPP)
DEFINE_UPP_CREATE(NewExceptionHandlerUPP, ExceptionHandlerUPP, ExceptionHandlerProcPtr)
DEFINE_UPP_DISPOSE(DisposeExceptionHandlerUPP, ExceptionHandlerUPP)
DEFINE_UPP_CREATE(NewFSVolumeEjectUPP, FSVolumeEjectUPP, FSVolumeEjectProcPtr)
DEFINE_UPP_DISPOSE(DisposeFSVolumeEjectUPP, FSVolumeEjectUPP)
DEFINE_UPP_CREATE(NewFSVolumeMountUPP, FSVolumeMountUPP, FSVolumeMountProcPtr)
DEFINE_UPP_DISPOSE(DisposeFSVolumeMountUPP, FSVolumeMountUPP)
DEFINE_UPP_CREATE(NewFSVolumeUnmountUPP, FSVolumeUnmountUPP, FSVolumeUnmountProcPtr)
DEFINE_UPP_DISPOSE(DisposeFSVolumeUnmountUPP, FSVolumeUnmountUPP)
DEFINE_UPP_CREATE(NewFolderManagerNotificationUPP, FolderManagerNotificationUPP, FolderManagerNotificationProcPtr)
DEFINE_UPP_DISPOSE(DisposeFolderManagerNotificationUPP, FolderManagerNotificationUPP)
DEFINE_UPP_CREATE(NewGetMissingComponentResourceUPP, GetMissingComponentResourceUPP,
                  GetMissingComponentResourceProcPtr)
DEFINE_UPP_DISPOSE(DisposeGetMissingComponentResourceUPP, GetMissingComponentResourceUPP)
DEFINE_UPP_CREATE(NewIOCompletionUPP, IOCompletionUPP, IOCompletionProcPtr)
DEFINE_UPP_DISPOSE(DisposeIOCompletionUPP, IOCompletionUPP)
DEFINE_UPP_CREATE(NewIndexToUCStringUPP, IndexToUCStringUPP, IndexToUCStringProcPtr)
DEFINE_UPP_DISPOSE(DisposeIndexToUCStringUPP, IndexToUCStringUPP)
DEFINE_UPP_CREATE(NewKCCallbackUPP, KCCallbackUPP, KCCallbackProcPtr)
DEFINE_UPP_DISPOSE(DisposeKCCallbackUPP, KCCallbackUPP)
DEFINE_UPP_CREATE(NewResErrUPP, ResErrUPP, ResErrProcPtr)
DEFINE_UPP_DISPOSE(DisposeResErrUPP, ResErrUPP)
DEFINE_UPP_CREATE(NewSleepQUPP, SleepQUPP, SleepQProcPtr)
DEFINE_UPP_DISPOSE(DisposeSleepQUPP, SleepQUPP)
DEFINE_UPP_CREATE(NewThreadEntryUPP, ThreadEntryUPP, ThreadEntryProcPtr)
DEFINE_UPP_DISPOSE(DisposeThreadEntryUPP, ThreadEntryUPP)
DEFINE_UPP_CREATE(NewThreadSchedulerUPP, ThreadSchedulerUPP, ThreadSchedulerProcPtr)
DEFINE_UPP_DISPOSE(DisposeThreadSchedulerUPP, ThreadSchedulerUPP)
DEFINE_UPP_CREATE(NewThreadSwitchUPP, ThreadSwitchUPP, ThreadSwitchProcPtr)
DEFINE_UPP_DISPOSE(DisposeThreadSwitchUPP, ThreadSwitchUPP)
DEFINE_UPP_CREATE(NewThreadTerminationUPP, ThreadTerminationUPP, ThreadTerminationProcPtr)
DEFINE_UPP_DISPOSE(DisposeThreadTerminationUPP, ThreadTerminationUPP)
DEFINE_UPP_CREATE(NewTimerUPP, TimerUPP, TimerProcPtr)
DEFINE_UPP_DISPOSE(DisposeTimerUPP, TimerUPP)
DEFINE_UPP_CREATE(NewUnicodeToTextFallbackUPP, UnicodeToTextFallbackUPP, UnicodeToTextFallbackProcPtr)
DEFINE_UPP_DISPOSE(DisposeUnicodeToTextFallbackUPP, UnicodeToTextFallbackUPP)

ComponentResult
InvokeComponentMPWorkFunctionUPP(void *globalRefCon, ComponentMPWorkFunctionHeaderRecordPtr header,
                                 ComponentMPWorkFunctionUPP userUPP)
{
    return (*userUPP)(globalRefCon, header);
}

ComponentResult
InvokeComponentRoutineUPP(ComponentParameters *parameters, Handle componentStorage, ComponentRoutineUPP userUPP)
{
    return (*userUPP)(parameters, componentStorage);
}

void
InvokeDebugAssertOutputHandlerUPP(OSType componentSignature, UInt32 options, const char *assertionString,
                                  const char *exceptionLabelString, const char *errorString, const char *fileName,
                                  long lineNumber, void *value, ConstStr255Param outputMsg,
                                  DebugAssertOutputHandlerUPP userUPP)
{
    (*userUPP)(componentSignature, options, assertionString, exceptionLabelString, errorString, fileName, lineNumber,
               value, outputMsg);
}

void
InvokeDebugComponentCallbackUPP(SInt32 optionSelectorNum, UInt32 command, Boolean *optionSetting,
                                DebugComponentCallbackUPP userUPP)
{
    (*userUPP)(optionSelectorNum, command, optionSetting);
}

void
InvokeDebuggerDisposeThreadUPP(ThreadID threadDeleted, DebuggerDisposeThreadUPP userUPP)
{
    (*userUPP)(threadDeleted);
}

void
InvokeDebuggerNewThreadUPP(ThreadID threadCreated, DebuggerNewThreadUPP userUPP)
{
    (*userUPP)(threadCreated);
}

ThreadID
InvokeDebuggerThreadSchedulerUPP(SchedulerInfoRecPtr schedulerInfo, DebuggerThreadSchedulerUPP userUPP)
{
    return (*userUPP)(schedulerInfo);
}

void
InvokeDeferredTaskUPP(long parameter, DeferredTaskUPP userUPP)
{
    (*userUPP)(parameter);
}

OSStatus
InvokeExceptionHandlerUPP(ExceptionInformation *exception, ExceptionHandlerUPP userUPP)
{
    return (*userUPP)(exception);
}

void
InvokeFSVolumeEjectUPP(FSVolumeOperation operation, void *clientData, OSStatus error, FSVolumeRefNum volume,
                       pid_t dissenter, FSVolumeEjectUPP userUPP)
{
    (*userUPP)(operation, clientData, error, volume, dissenter);
}

void
InvokeFSVolumeMountUPP(FSVolumeOperation operation, void *clientData, OSStatus error, FSVolumeRefNum volume,
                       FSVolumeMountUPP userUPP)
{
    (*userUPP)(operation, clientData, error, volume);
}

void
InvokeFSVolumeUnmountUPP(FSVolumeOperation operation, void *clientData, OSStatus error, FSVolumeRefNum volume,
                         pid_t dissenter, FSVolumeUnmountUPP userUPP)
{
    (*userUPP)(operation, clientData, error, volume, dissenter);
}

OSStatus
InvokeFolderManagerNotificationUPP(OSType message, void *argument, void *userRefCon,
                                   FolderManagerNotificationUPP userUPP)
{
    return (*userUPP)(message, argument, userRefCon);
}

OSErr
InvokeGetMissingComponentResourceUPP(Component component, OSType resourceType, SInt16 resourceID, void *refCon,
                                     Handle *resource, GetMissingComponentResourceUPP userUPP)
{
    return (*userUPP)(component, resourceType, resourceID, refCon, resource);
}

void
InvokeIOCompletionUPP(ParmBlkPtr paramBlock, IOCompletionUPP userUPP)
{
    (*userUPP)(paramBlock);
}

Boolean
InvokeIndexToUCStringUPP(UInt32 index, void *listData, void *refCon, CFStringRef *outString,
                         UCTypeSelectOptions *options, IndexToUCStringUPP userUPP)
{
    return (*userUPP)(index, listData, refCon, outString, options);
}

voidPtr
InvokeThreadEntryUPP(void *threadParam, ThreadEntryUPP userUPP)
{
    return (*userUPP)(threadParam);
}

ThreadID
InvokeThreadSchedulerUPP(SchedulerInfoRecPtr schedulerInfo, ThreadSchedulerUPP userUPP)
{
    return (*userUPP)(schedulerInfo);
}

void
InvokeThreadSwitchUPP(ThreadID threadBeingSwitched, void *switchProcParam, ThreadSwitchUPP userUPP)
{
    (*userUPP)(threadBeingSwitched, switchProcParam);
}

void
InvokeThreadTerminationUPP(ThreadID threadTerminated, void *terminationProcParam, ThreadTerminationUPP userUPP)
{
    (*userUPP)(threadTerminated, terminationProcParam);
}

void
InvokeTimerUPP(TMTaskPtr timerTask, TimerUPP userUPP)
{
    (*userUPP)(timerTask);
}

OSStatus
InvokeUnicodeToTextFallbackUPP(UniChar *source, ByteCount sourceLength, ByteCount *convertedSourceLength,
                               TextPtr destination, ByteCount destinationLength, ByteCount *convertedDestinationLength,
                               LogicalAddress info, ConstUnicodeMappingPtr mapping,
                               UnicodeToTextFallbackUPP userUPP)
{
    return (*userUPP)(source, sourceLength, convertedSourceLength, destination, destinationLength,
                      convertedDestinationLength, info, mapping);
}

#undef DEFINE_UPP_CREATE
#undef DEFINE_UPP_DISPOSE
