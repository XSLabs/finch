/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CoreSymbolication.framework (private), Finch's own: the part of Apple's
 * symbolication API that Apple's open-source tools use (zprint and zlog, from
 * system_cmds), for the running kernel. Declarations are Finch's, written to
 * the calling conventions those tools use: every object is a two-word value
 * passed and returned in registers, null when both words are zero.
 */
#ifndef _CORESYMBOLICATION_H_
#define _CORESYMBOLICATION_H_

#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#include <stdbool.h>
#include <stdint.h>

__BEGIN_DECLS

typedef struct _CSTypeRef {
    uintptr_t _opaque_1;
    uintptr_t _opaque_2;
} CSTypeRef;

typedef CSTypeRef CSSymbolicatorRef;
typedef CSTypeRef CSSymbolOwnerRef;
typedef CSTypeRef CSSymbolRef;
typedef CSTypeRef CSSourceInfoRef;
typedef CSTypeRef CSRegionRef;
typedef CSTypeRef CSSegmentRef;

typedef struct _CSRange {
    mach_vm_address_t location;
    mach_vm_size_t length;
} CSRange;

typedef uint64_t CSMachineTime;

/* "Now", for the ...AtTime lookups (the kernel doesn't change under them). */
#define kCSNow ((CSMachineTime)0x8000000000000000ULL)

#define kCSNull ((CSTypeRef){ 0, 0 })

bool CSIsNull(CSTypeRef cs);
CSTypeRef CSRetain(CSTypeRef cs);
void CSRelease(CSTypeRef cs);

/* The running kernel, from its file in /System/Library/Kernels (or a kernel
   collection) whose UUID is the running kernel's, at the kernel's unslid
   addresses (the ones it reports); null when there's no such file. */
CSSymbolicatorRef CSSymbolicatorCreateWithMachKernel(void);

CSSymbolOwnerRef CSSymbolicatorGetSymbolOwnerWithAddressAtTime(CSSymbolicatorRef symbolicator,
    mach_vm_address_t address, CSMachineTime time);
CSSymbolRef CSSymbolicatorGetSymbolWithAddressAtTime(CSSymbolicatorRef symbolicator, mach_vm_address_t address,
    CSMachineTime time);
CSSourceInfoRef CSSymbolicatorGetSourceInfoWithAddressAtTime(CSSymbolicatorRef symbolicator,
    mach_vm_address_t address, CSMachineTime time);

const char *CSSymbolOwnerGetName(CSSymbolOwnerRef owner);
const char *CSSymbolOwnerGetPath(CSSymbolOwnerRef owner);
const CFUUIDBytes *CSSymbolOwnerGetCFUUIDBytes(CSSymbolOwnerRef owner);
mach_vm_address_t CSSymbolOwnerGetBaseAddress(CSSymbolOwnerRef owner);
size_t CSSymbolOwnerForeachSegment(CSSymbolOwnerRef owner, void (^block)(CSSegmentRef segment));

const char *CSSymbolGetName(CSSymbolRef symbol);
const char *CSSymbolGetMangledName(CSSymbolRef symbol);
CSRange CSSymbolGetRange(CSSymbolRef symbol);
CSSymbolOwnerRef CSSymbolGetSymbolOwner(CSSymbolRef symbol);

const char *CSRegionGetName(CSRegionRef region);
CSRange CSRegionGetRange(CSRegionRef region);

const char *CSSourceInfoGetPath(CSSourceInfoRef info);
uint32_t CSSourceInfoGetLineNumber(CSSourceInfoRef info);

__END_DECLS

#endif /* _CORESYMBOLICATION_H_ */
