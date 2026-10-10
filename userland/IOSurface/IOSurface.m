/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * IOSurface.framework, Finch's: shared pixel buffers. A surface is a Mach memory object
 * laid out as Apple's are (rows aligned to 128 bytes, the allocation and each plane to
 * 16K pages), preceded by a page that describes it: width, height, formats, planes, and
 * the shared modification seed and use count. IOSurfaceCreateMachPort hands out the
 * memory object; IOSurfaceLookupFromMachPort maps it and reads that page, so a surface
 * passes between processes over Mach messages or XPC as Apple's does. IDs are looked up
 * within the process (there's no system-wide surface registry yet). IOSurfaceRef and the
 * IOSurface class are the same object, as with Apple's.
 */
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <IOSurface/IOSurfaceObjC.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <pthread.h>
#include <stdatomic.h>
#include <xpc/xpc.h>

/* (libxpc's: a send right's type) */
extern const struct _xpc_type_s _xpc_type_mach_send;
#define XPC_TYPE_MACH_SEND (&_xpc_type_mach_send)

#define FINCH_INIT __attribute__((objc_method_family(init)))

enum {
    kPage = 16384,
    kRowAlignment = 128,
    kMaxPlanes = 5,
    kMaxDimension = 16384,
    kMagic = 0x46494F53, /* 'FIOS' */
};

typedef struct {
    uint64_t width, height, bytesPerElement, bytesPerRow, elementWidth, elementHeight, offset, size;
} Plane;

/* The page before the pixels: what a surface is, shared by every process that maps it. */
typedef struct {
    uint32_t magic;
    uint32_t pixelFormat;
    uint64_t width, height, bytesPerElement, bytesPerRow, elementWidth, elementHeight, allocSize;
    uint32_t planeCount;
    uint32_t pixelSizeCastingAllowed;
    Plane planes[kMaxPlanes];
    _Atomic uint32_t seed;
    _Atomic int32_t useCount;
    _Atomic uint32_t purgeable;
    uint32_t cacheMode;
    uint32_t surfaceID;
} Header;

static CFTypeID surface_type;

typedef struct {
    CFIndex version;
    const char *className;
    void (*init)(CFTypeRef);
    CFTypeRef (*copy)(CFAllocatorRef, CFTypeRef);
    void (*finalize)(CFTypeRef);
    Boolean (*equal)(CFTypeRef, CFTypeRef);
    CFHashCode (*hash)(CFTypeRef);
    CFStringRef (*copyFormattingDesc)(CFTypeRef, CFDictionaryRef);
    CFStringRef (*copyDebugDesc)(CFTypeRef);
    void (*reclaim)(CFTypeRef);
    uint32_t (*refcount)(intptr_t, CFTypeRef);
    uintptr_t requiredAlignment;
} CFRuntimeClass;
extern CFTypeID _CFRuntimeRegisterClass(const CFRuntimeClass *cls);

CFTypeID
IOSurfaceGetTypeID(void)
{
    static dispatch_once_t once;
    static const CFRuntimeClass cls = {0, "IOSurface", NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 0};
    dispatch_once(&once, ^{
      surface_type = _CFRuntimeRegisterClass(&cls);
    });
    return surface_type;
}

/* This process's surfaces, by ID: the use count this process holds on each (shared by
   all its objects for that surface, as Apple's is), how many objects it has, and one of
   them (for IOSurfaceLookup). */
typedef struct {
    int32_t useCount;
    int32_t objects;
    void *all; /* an NSHashTable of the objects, weak */
} Local;
static NSMutableDictionary<NSNumber *, NSValue *> *locals;
static pthread_mutex_t id_lock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic uint32_t next_id = 1;

static Local *
local(uint32_t surfaceID, BOOL make)
{
    if (!locals)
        locals = [NSMutableDictionary dictionary];
    NSValue *v = locals[@(surfaceID)];
    if (!v && make) {
        Local *l = calloc(1, sizeof *l);
        l->all = (__bridge_retained void *)[NSHashTable weakObjectsHashTable];
        v = [NSValue valueWithPointer:l];
        locals[@(surfaceID)] = v;
    }
    return v.pointerValue;
}

@interface IOSurface () {
  @public
    Header *_header;     /* the mapping's first page */
    uint8_t *_base;      /* the pixels */
    mach_vm_size_t _mapSize;
    mach_port_t _entry;  /* the memory object */
    IOSurfaceID _id;
    int _locks;
    NSMutableDictionary *_values;
    pthread_mutex_t _lock;
}
- (instancetype)_finchInitWithEntry:(mach_port_t)entry size:(mach_vm_size_t)size FINCH_INIT;
@end

static size_t
round_up(size_t v, size_t a)
{
    return a ? (v + a - 1) / a * a : v;
}

static size_t
number(CFDictionaryRef d, CFStringRef key, size_t fallback)
{
    CFTypeRef v = d ? CFDictionaryGetValue(d, key) : NULL;
    long long n;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID() && CFNumberGetValue(v, kCFNumberLongLongType, &n) && n >= 0)
        return (size_t)n;
    return fallback;
}

/* A new surface for these properties (Apple's rules for what's left out). */
IOSurfaceRef
IOSurfaceCreate(CFDictionaryRef properties)
{
    Header h;
    memset(&h, 0, sizeof h);
    h.magic = kMagic;
    h.width = number(properties, kIOSurfaceWidth, 0);
    h.height = number(properties, kIOSurfaceHeight, 0);
    h.bytesPerElement = number(properties, kIOSurfaceBytesPerElement, 1);
    h.elementWidth = number(properties, kIOSurfaceElementWidth, 1) ?: 1;
    h.elementHeight = number(properties, kIOSurfaceElementHeight, 1) ?: 1;
    h.pixelFormat = (uint32_t)number(properties, kIOSurfacePixelFormat, 0);
    h.cacheMode = (uint32_t)number(properties, kIOSurfaceCacheMode, 0);
    CFTypeRef cast = properties ? CFDictionaryGetValue(properties, kIOSurfacePixelSizeCastingAllowed) : NULL;
    h.pixelSizeCastingAllowed = cast ? CFBooleanGetValue(cast) : 1;
    /* (Apple's makes surfaces past the reported maximum; only nonsense is refused) */
    if (!h.width || !h.height || h.width > (1u << 24) || h.height > (1u << 24))
        return NULL;
    size_t offset = number(properties, kIOSurfaceOffset, 0);
    CFArrayRef planes = properties ? CFDictionaryGetValue(properties, kIOSurfacePlaneInfo) : NULL;
    size_t end;
    if (planes && CFGetTypeID(planes) == CFArrayGetTypeID() && CFArrayGetCount(planes) > 0) {
        h.planeCount = (uint32_t)MIN(CFArrayGetCount(planes), kMaxPlanes);
        size_t at = round_up(offset, kPage);
        for (uint32_t i = 0; i < h.planeCount; i++) {
            CFDictionaryRef p = CFArrayGetValueAtIndex(planes, i);
            Plane *pl = &h.planes[i];
            pl->width = number(p, kIOSurfacePlaneWidth, h.width);
            pl->height = number(p, kIOSurfacePlaneHeight, h.height);
            pl->bytesPerElement = number(p, kIOSurfacePlaneBytesPerElement, 1);
            pl->elementWidth = number(p, kIOSurfacePlaneElementWidth, 1) ?: 1;
            pl->elementHeight = number(p, kIOSurfacePlaneElementHeight, 1) ?: 1;
            size_t rowElements = (pl->width + pl->elementWidth - 1) / pl->elementWidth;
            pl->bytesPerRow = number(p, kIOSurfacePlaneBytesPerRow, round_up(rowElements * pl->bytesPerElement, kRowAlignment));
            pl->offset = number(p, kIOSurfacePlaneOffset, at);
            pl->size = number(p, kIOSurfacePlaneSize, pl->bytesPerRow * ((pl->height + pl->elementHeight - 1) / pl->elementHeight));
            at = round_up(pl->offset + pl->size, kPage);
        }
        /* (a planar surface's own row figures are its first plane's) */
        h.bytesPerElement = h.planes[0].bytesPerElement;
        h.bytesPerRow = h.planes[0].bytesPerRow;
        end = at;
    } else {
        size_t rowElements = (h.width + h.elementWidth - 1) / h.elementWidth;
        h.bytesPerRow = number(properties, kIOSurfaceBytesPerRow, round_up(rowElements * h.bytesPerElement, kRowAlignment));
        end = offset + h.bytesPerRow * ((h.height + h.elementHeight - 1) / h.elementHeight);
    }
    h.allocSize = number(properties, kIOSurfaceAllocSize, round_up(end, kPage));
    if (h.allocSize < end)
        return NULL;

    mach_vm_size_t size = kPage + round_up(h.allocSize, kPage);
    mach_vm_address_t addr = 0;
    if (mach_vm_allocate(mach_task_self(), &addr, size, VM_FLAGS_ANYWHERE) != KERN_SUCCESS)
        return NULL;
    memory_object_size_t entrySize = size;
    mach_port_t entry = MACH_PORT_NULL;
    if (mach_make_memory_entry_64(mach_task_self(), &entrySize, addr, VM_PROT_READ | VM_PROT_WRITE, &entry, MACH_PORT_NULL) !=
        KERN_SUCCESS) {
        mach_vm_deallocate(mach_task_self(), addr, size);
        return NULL;
    }
    h.surfaceID = atomic_fetch_add(&next_id, 1) | ((arc4random() & 0x7fff) << 16);
    memcpy((void *)addr, &h, sizeof h);
    IOSurface *s = [[IOSurface alloc] _finchInitWithEntry:entry size:size];
    /* (the memory object keeps the memory: the surface has its own mapping of it) */
    mach_vm_deallocate(mach_task_self(), addr, size);
    if (!s)
        return NULL;
    CFStringRef name = properties ? CFDictionaryGetValue(properties, kIOSurfaceName) : NULL;
    if (name)
        s->_values[(__bridge NSString *)kIOSurfaceName] = (__bridge NSString *)name;
    return (__bridge_retained IOSurfaceRef)s;
}

IOSurfaceRef
IOSurfaceLookupFromMachPort(mach_port_t port)
{
    if (!MACH_PORT_VALID(port))
        return NULL;
    /* (the first page says how big the rest is) */
    mach_vm_address_t addr = 0;
    if (mach_vm_map(mach_task_self(), &addr, kPage, 0, VM_FLAGS_ANYWHERE, port, 0, FALSE, VM_PROT_READ, VM_PROT_READ,
                    VM_INHERIT_NONE) != KERN_SUCCESS)
        return NULL;
    Header h = *(Header *)addr;
    mach_vm_deallocate(mach_task_self(), addr, kPage);
    if (h.magic != kMagic)
        return NULL;
    mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_SEND, 1);
    IOSurface *s = [[IOSurface alloc] _finchInitWithEntry:port size:kPage + round_up(h.allocSize, kPage)];
    return s ? (__bridge_retained IOSurfaceRef)s : NULL;
}

mach_port_t
IOSurfaceCreateMachPort(IOSurfaceRef buffer)
{
    IOSurface *s = (__bridge IOSurface *)buffer;
    mach_port_mod_refs(mach_task_self(), s->_entry, MACH_PORT_RIGHT_SEND, 1);
    return s->_entry;
}

xpc_object_t
IOSurfaceCreateXPCObject(IOSurfaceRef aSurface)
{
    extern xpc_object_t xpc_mach_send_create(mach_port_t port);
    IOSurface *s = (__bridge IOSurface *)aSurface;
    return xpc_mach_send_create(s->_entry);
}

IOSurfaceRef
IOSurfaceLookupFromXPCObject(xpc_object_t xobj)
{
    extern mach_port_t xpc_mach_send_copy_right(xpc_object_t xsend);
    mach_port_t port = xpc_mach_send_copy_right(xobj);
    IOSurfaceRef s = IOSurfaceLookupFromMachPort(port);
    if (MACH_PORT_VALID(port))
        mach_port_deallocate(mach_task_self(), port);
    return s;
}

IOSurfaceRef
IOSurfaceLookup(IOSurfaceID csid)
{
    pthread_mutex_lock(&id_lock);
    Local *l = local(csid, NO);
    IOSurface *s = l ? [(__bridge NSHashTable *)l->all anyObject] : nil;
    mach_port_t entry = MACH_PORT_NULL;
    if (s) {
        entry = s->_entry;
        mach_port_mod_refs(mach_task_self(), entry, MACH_PORT_RIGHT_SEND, 1);
    }
    pthread_mutex_unlock(&id_lock);
    if (!MACH_PORT_VALID(entry))
        return NULL;
    IOSurfaceRef r = IOSurfaceLookupFromMachPort(entry);
    mach_port_deallocate(mach_task_self(), entry);
    return r;
}

#define S ((__bridge IOSurface *)buffer)
#define H (S->_header)

IOSurfaceID IOSurfaceGetID(IOSurfaceRef buffer) { return S->_id; }
size_t IOSurfaceGetAllocSize(IOSurfaceRef buffer) { return (size_t)H->allocSize; }
size_t IOSurfaceGetWidth(IOSurfaceRef buffer) { return (size_t)H->width; }
size_t IOSurfaceGetHeight(IOSurfaceRef buffer) { return (size_t)H->height; }
size_t IOSurfaceGetBytesPerElement(IOSurfaceRef buffer) { return (size_t)H->bytesPerElement; }
size_t IOSurfaceGetBytesPerRow(IOSurfaceRef buffer) { return (size_t)H->bytesPerRow; }
void *IOSurfaceGetBaseAddress(IOSurfaceRef buffer) { return S->_base; }
size_t IOSurfaceGetElementWidth(IOSurfaceRef buffer) { return (size_t)H->elementWidth; }
size_t IOSurfaceGetElementHeight(IOSurfaceRef buffer) { return (size_t)H->elementHeight; }
OSType IOSurfaceGetPixelFormat(IOSurfaceRef buffer) { return H->pixelFormat; }
uint32_t IOSurfaceGetSeed(IOSurfaceRef buffer) { return atomic_load(&H->seed); }
size_t IOSurfaceGetPlaneCount(IOSurfaceRef buffer) { return H->planeCount; }
Boolean IOSurfaceAllowsPixelSizeCasting(IOSurfaceRef buffer) { return H->pixelSizeCastingAllowed != 0; }
IOSurfaceSubsampling IOSurfaceGetSubsampling(IOSurfaceRef buffer) { return kIOSurfaceSubsamplingUnknown; }

static const Plane *
plane(IOSurfaceRef buffer, size_t i)
{
    return i < H->planeCount ? &H->planes[i] : NULL;
}

/* (plane 0 of a surface without planes is the surface itself, as with Apple's) */
#define PLANE_FIELD(fn, field, whole)                                     \
    size_t fn(IOSurfaceRef buffer, size_t planeIndex)                     \
    {                                                                     \
        const Plane *p = plane(buffer, planeIndex);                       \
        return p ? (size_t)p->field : (planeIndex == 0 ? (size_t)(whole) : 0); \
    }
PLANE_FIELD(IOSurfaceGetWidthOfPlane, width, H->width)
PLANE_FIELD(IOSurfaceGetHeightOfPlane, height, H->height)
PLANE_FIELD(IOSurfaceGetBytesPerElementOfPlane, bytesPerElement, H->bytesPerElement)
PLANE_FIELD(IOSurfaceGetBytesPerRowOfPlane, bytesPerRow, H->bytesPerRow)
PLANE_FIELD(IOSurfaceGetElementWidthOfPlane, elementWidth, H->elementWidth)
PLANE_FIELD(IOSurfaceGetElementHeightOfPlane, elementHeight, H->elementHeight)
PLANE_FIELD(IOSurfaceGetSizeOfPlane, size, H->allocSize)

void *
IOSurfaceGetBaseAddressOfPlane(IOSurfaceRef buffer, size_t planeIndex)
{
    const Plane *p = plane(buffer, planeIndex);
    return p ? S->_base + p->offset : (planeIndex == 0 ? S->_base : NULL);
}

/* Components: Apple's describe them for the formats it knows; with none described, a plane
   has none. */
size_t IOSurfaceGetNumberOfComponentsOfPlane(IOSurfaceRef buffer, size_t planeIndex) { return 0; }
IOSurfaceComponentName IOSurfaceGetNameOfComponentOfPlane(IOSurfaceRef buffer, size_t p, size_t c) { return kIOSurfaceComponentNameUnknown; }
IOSurfaceComponentType IOSurfaceGetTypeOfComponentOfPlane(IOSurfaceRef buffer, size_t p, size_t c) { return kIOSurfaceComponentTypeUnknown; }
IOSurfaceComponentRange IOSurfaceGetRangeOfComponentOfPlane(IOSurfaceRef buffer, size_t p, size_t c) { return kIOSurfaceComponentRangeUnknown; }
size_t IOSurfaceGetBitDepthOfComponentOfPlane(IOSurfaceRef buffer, size_t p, size_t c) { return 0; }
size_t IOSurfaceGetBitOffsetOfComponentOfPlane(IOSurfaceRef buffer, size_t p, size_t c) { return 0; }

/* Locking marks CPU access; a lock for writing moves the seed on, as Apple's does. */
kern_return_t
IOSurfaceLock(IOSurfaceRef buffer, IOSurfaceLockOptions options, uint32_t *seed)
{
    pthread_mutex_lock(&S->_lock);
    S->_locks++;
    pthread_mutex_unlock(&S->_lock);
    if (!(options & kIOSurfaceLockReadOnly))
        atomic_fetch_add(&H->seed, 1);
    if (seed)
        *seed = atomic_load(&H->seed);
    return KERN_SUCCESS;
}

kern_return_t
IOSurfaceUnlock(IOSurfaceRef buffer, IOSurfaceLockOptions options, uint32_t *seed)
{
    pthread_mutex_lock(&S->_lock);
    BOOL locked = S->_locks > 0;
    if (locked)
        S->_locks--;
    pthread_mutex_unlock(&S->_lock);
    if (!locked)
        return (kern_return_t)0xe00002c2; /* kIOReturnBadArgument */
    if (seed)
        *seed = atomic_load(&H->seed);
    return KERN_SUCCESS;
}

/* --- attachments --- */

void
IOSurfaceSetValue(IOSurfaceRef buffer, CFStringRef key, CFTypeRef value)
{
    pthread_mutex_lock(&S->_lock);
    if (key && value)
        S->_values[(__bridge NSString *)key] = (__bridge id)value;
    pthread_mutex_unlock(&S->_lock);
}

CFTypeRef
IOSurfaceCopyValue(IOSurfaceRef buffer, CFStringRef key)
{
    pthread_mutex_lock(&S->_lock);
    id v = key ? S->_values[(__bridge NSString *)key] : nil;
    pthread_mutex_unlock(&S->_lock);
    return v ? CFBridgingRetain(v) : NULL;
}

void
IOSurfaceRemoveValue(IOSurfaceRef buffer, CFStringRef key)
{
    pthread_mutex_lock(&S->_lock);
    if (key)
        [S->_values removeObjectForKey:(__bridge NSString *)key];
    pthread_mutex_unlock(&S->_lock);
}

void
IOSurfaceSetValues(IOSurfaceRef buffer, CFDictionaryRef keysAndValues)
{
    pthread_mutex_lock(&S->_lock);
    [S->_values addEntriesFromDictionary:(__bridge NSDictionary *)keysAndValues];
    pthread_mutex_unlock(&S->_lock);
}

CFDictionaryRef
IOSurfaceCopyAllValues(IOSurfaceRef buffer)
{
    pthread_mutex_lock(&S->_lock);
    NSDictionary *d = [S->_values copy];
    pthread_mutex_unlock(&S->_lock);
    return CFBridgingRetain(d);
}

void
IOSurfaceRemoveAllValues(IOSurfaceRef buffer)
{
    pthread_mutex_lock(&S->_lock);
    [S->_values removeAllObjects];
    pthread_mutex_unlock(&S->_lock);
}

/* --- use counts: this process's, and every process's (in the shared page) --- */

void
IOSurfaceIncrementUseCount(IOSurfaceRef buffer)
{
    pthread_mutex_lock(&id_lock);
    if (local(S->_id, YES)->useCount++ == 0)
        atomic_fetch_add(&H->useCount, 1);
    pthread_mutex_unlock(&id_lock);
}

void
IOSurfaceDecrementUseCount(IOSurfaceRef buffer)
{
    pthread_mutex_lock(&id_lock);
    Local *l = local(S->_id, YES);
    if (l->useCount > 0 && --l->useCount == 0)
        atomic_fetch_sub(&H->useCount, 1);
    pthread_mutex_unlock(&id_lock);
}

int32_t
IOSurfaceGetUseCount(IOSurfaceRef buffer)
{
    pthread_mutex_lock(&id_lock);
    int32_t n = local(S->_id, YES)->useCount;
    pthread_mutex_unlock(&id_lock);
    return n;
}

/* In use: some process holds a use count, or a port made for the surface is still out
   (here: send rights beyond those this process's objects hold). */
Boolean
IOSurfaceIsInUse(IOSurfaceRef buffer)
{
    if (atomic_load(&H->useCount) > 0)
        return true;
    mach_port_urefs_t refs = 0;
    mach_port_get_refs(mach_task_self(), S->_entry, MACH_PORT_RIGHT_SEND, &refs);
    pthread_mutex_lock(&id_lock);
    int32_t objects = local(S->_id, YES)->objects;
    pthread_mutex_unlock(&id_lock);
    return (int32_t)refs > objects;
}

/* --- limits and alignment, Apple's --- */

size_t
IOSurfaceGetPropertyMaximum(CFStringRef property)
{
    if (CFEqual(property, kIOSurfaceWidth) || CFEqual(property, kIOSurfaceHeight))
        return kMaxDimension;
    if (CFEqual(property, kIOSurfaceBytesPerRow))
        return kMaxDimension * 16;
    if (CFEqual(property, kIOSurfaceBytesPerElement))
        return 16;
    if (CFEqual(property, kIOSurfaceElementWidth) || CFEqual(property, kIOSurfaceElementHeight))
        return 8;
    return SIZE_MAX;
}

size_t
IOSurfaceGetPropertyAlignment(CFStringRef property)
{
    if (CFEqual(property, kIOSurfaceBytesPerRow) || CFEqual(property, kIOSurfacePlaneBytesPerRow))
        return kRowAlignment;
    if (CFEqual(property, kIOSurfaceOffset) || CFEqual(property, kIOSurfacePlaneOffset))
        return kPage;
    return 1;
}

size_t
IOSurfaceAlignProperty(CFStringRef property, size_t value)
{
    return round_up(value, IOSurfaceGetPropertyAlignment(property));
}

/* --- purgeability and ownership: memory stays as it is --- */

kern_return_t
IOSurfaceSetPurgeable(IOSurfaceRef buffer, uint32_t newState, uint32_t *oldState)
{
    uint32_t old = atomic_load(&H->purgeable);
    if (newState != kIOSurfacePurgeableKeepCurrent)
        atomic_store(&H->purgeable, newState);
    if (oldState)
        *oldState = old;
    return KERN_SUCCESS;
}

kern_return_t IOSurfaceSetOwnership(IOSurfaceRef buffer, task_t newOwner, int newLedgerTag, uint32_t newLedgerOptions) { return KERN_SUCCESS; }
kern_return_t IOSurfaceSetOwnershipIdentity(IOSurfaceRef buffer, task_id_token_t token, int newLedgerTag, uint32_t newLedgerOptions) { return KERN_SUCCESS; }

/* --- the object --- */

@implementation IOSurface

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)_finchInitWithEntry:(mach_port_t)entry size:(mach_vm_size_t)size
{
    if (!(self = [super init]))
        return nil;
    mach_vm_address_t addr = 0;
    if (mach_vm_map(mach_task_self(), &addr, size, 0, VM_FLAGS_ANYWHERE, entry, 0, FALSE, VM_PROT_READ | VM_PROT_WRITE,
                    VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_NONE) != KERN_SUCCESS)
        return nil;
    _header = (Header *)addr;
    _base = (uint8_t *)addr + kPage;
    _mapSize = size;
    _entry = entry;
    _values = [NSMutableDictionary dictionary];
    pthread_mutex_init(&_lock, NULL);
    _id = _header->surfaceID;
    pthread_mutex_lock(&id_lock);
    Local *l = local(_id, YES);
    l->objects++;
    [(__bridge NSHashTable *)l->all addObject:self];
    pthread_mutex_unlock(&id_lock);
    return self;
}

- (instancetype)initWithProperties:(NSDictionary *)properties
{
    return (__bridge_transfer IOSurface *)IOSurfaceCreate((__bridge CFDictionaryRef)properties);
}

- (void)dealloc
{
    pthread_mutex_lock(&id_lock);
    Local *l = local(_id, NO);
    if (l && --l->objects == 0) {
        /* (the process's last object: its use count goes with it) */
        if (l->useCount > 0)
            atomic_fetch_sub(&_header->useCount, 1);
        [locals removeObjectForKey:@(_id)];
        CFRelease(l->all);
        free(l);
    } else if (l) {
        [(__bridge NSHashTable *)l->all removeObject:self];
    }
    pthread_mutex_unlock(&id_lock);
    mach_vm_deallocate(mach_task_self(), (mach_vm_address_t)_header, _mapSize);
    mach_port_deallocate(mach_task_self(), _entry);
    pthread_mutex_destroy(&_lock);
}

- (CFTypeID)_cfTypeID { return IOSurfaceGetTypeID(); }

#define REF ((__bridge IOSurfaceRef)self)
- (kern_return_t)lockWithOptions:(IOSurfaceLockOptions)options seed:(uint32_t *)seed { return IOSurfaceLock(REF, options, seed); }
- (kern_return_t)unlockWithOptions:(IOSurfaceLockOptions)options seed:(uint32_t *)seed { return IOSurfaceUnlock(REF, options, seed); }
- (NSInteger)allocationSize { return (NSInteger)IOSurfaceGetAllocSize(REF); }
- (NSInteger)width { return (NSInteger)IOSurfaceGetWidth(REF); }
- (NSInteger)height { return (NSInteger)IOSurfaceGetHeight(REF); }
- (void *)baseAddress { return IOSurfaceGetBaseAddress(REF); }
- (OSType)pixelFormat { return IOSurfaceGetPixelFormat(REF); }
- (NSInteger)bytesPerRow { return (NSInteger)IOSurfaceGetBytesPerRow(REF); }
- (NSInteger)bytesPerElement { return (NSInteger)IOSurfaceGetBytesPerElement(REF); }
- (NSInteger)elementWidth { return (NSInteger)IOSurfaceGetElementWidth(REF); }
- (NSInteger)elementHeight { return (NSInteger)IOSurfaceGetElementHeight(REF); }
- (uint32_t)surfaceID { return IOSurfaceGetID(REF); }
- (uint32_t)seed { return IOSurfaceGetSeed(REF); }
- (NSUInteger)planeCount { return IOSurfaceGetPlaneCount(REF); }
- (NSInteger)widthOfPlaneAtIndex:(NSUInteger)i { return (NSInteger)IOSurfaceGetWidthOfPlane(REF, i); }
- (NSInteger)heightOfPlaneAtIndex:(NSUInteger)i { return (NSInteger)IOSurfaceGetHeightOfPlane(REF, i); }
- (NSInteger)bytesPerRowOfPlaneAtIndex:(NSUInteger)i { return (NSInteger)IOSurfaceGetBytesPerRowOfPlane(REF, i); }
- (NSInteger)bytesPerElementOfPlaneAtIndex:(NSUInteger)i { return (NSInteger)IOSurfaceGetBytesPerElementOfPlane(REF, i); }
- (NSInteger)elementWidthOfPlaneAtIndex:(NSUInteger)i { return (NSInteger)IOSurfaceGetElementWidthOfPlane(REF, i); }
- (NSInteger)elementHeightOfPlaneAtIndex:(NSUInteger)i { return (NSInteger)IOSurfaceGetElementHeightOfPlane(REF, i); }
- (void *)baseAddressOfPlaneAtIndex:(NSUInteger)i { return IOSurfaceGetBaseAddressOfPlane(REF, i); }
- (void)setAttachment:(id)anObject forKey:(NSString *)key { IOSurfaceSetValue(REF, (__bridge CFStringRef)key, (__bridge CFTypeRef)anObject); }
- (id)attachmentForKey:(NSString *)key { return CFBridgingRelease(IOSurfaceCopyValue(REF, (__bridge CFStringRef)key)); }
- (void)removeAttachmentForKey:(NSString *)key { IOSurfaceRemoveValue(REF, (__bridge CFStringRef)key); }
- (void)setAllAttachments:(NSDictionary *)dict { IOSurfaceSetValues(REF, (__bridge CFDictionaryRef)dict); }
- (NSDictionary *)allAttachments { return CFBridgingRelease(IOSurfaceCopyAllValues(REF)); }
- (void)removeAllAttachments { IOSurfaceRemoveAllValues(REF); }
- (BOOL)isInUse { return IOSurfaceIsInUse(REF); }
- (void)incrementUseCount { IOSurfaceIncrementUseCount(REF); }
- (void)decrementUseCount { IOSurfaceDecrementUseCount(REF); }
- (int32_t)localUseCount { return IOSurfaceGetUseCount(REF); }
- (BOOL)allowsPixelSizeCasting { return IOSurfaceAllowsPixelSizeCasting(REF); }
- (kern_return_t)setPurgeable:(IOSurfacePurgeabilityState)newState oldState:(IOSurfacePurgeabilityState *)oldState
{
    return IOSurfaceSetPurgeable(REF, newState, oldState);
}

/* Archived as its memory object: only something that sends ports (XPC) can carry it. */
- (void)encodeWithCoder:(NSCoder *)coder
{
    if ([coder respondsToSelector:@selector(encodeXPCObject:forKey:)])
        [(id)coder encodeXPCObject:IOSurfaceCreateXPCObject(REF) forKey:@"xpcObject"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if (![coder respondsToSelector:@selector(decodeXPCObjectOfType:forKey:)])
        return nil;
    xpc_object_t x = [(id)coder decodeXPCObjectOfType:XPC_TYPE_MACH_SEND forKey:@"xpcObject"];
    return x ? (__bridge_transfer IOSurface *)IOSurfaceLookupFromXPCObject(x) : nil;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<IOSurface: %p>\n    id =  0x%08x \n    width =  %zu \n    height =  %zu \n    pixelFormat =     %x \n    name =  %@",
                                      self, _id, (size_t)_header->width, (size_t)_header->height, _header->pixelFormat,
                                      _values[(__bridge NSString *)kIOSurfaceName] ?: [NSProcessInfo processInfo].processName];
}

@end

/* --- shared events: signalled values across processes (GPU work); with no GPU, a value
   that's set and read here --- */

@interface IOSurfaceSharedEvent : NSObject <NSSecureCoding>
@end

@implementation IOSurfaceSharedEvent {
    _Atomic uint64_t _value;
}
+ (BOOL)supportsSecureCoding { return YES; }
- (uint64_t)signaledValue { return atomic_load(&_value); }
- (void)setSignaledValue:(uint64_t)v { atomic_store(&_value, v); }
- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeInt64:(int64_t)self.signaledValue forKey:@"signaledValue"]; }
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init]))
        atomic_store(&_value, (uint64_t)[coder decodeInt64ForKey:@"signaledValue"]);
    return self;
}
@end

@interface IOSurfaceSharedEventListener : NSObject
@end
@implementation IOSurfaceSharedEventListener
- (instancetype)initWithDispatchQueue:(dispatch_queue_t)queue { return [super init]; }
@end

/* --- private calls apps make (argument layouts as Apple's). Finch's surfaces are plain
   memory: not tiled, not compressed, not protected, with no accelerator bound. --- */

kern_return_t IOSurfaceLockPlane(IOSurfaceRef buffer, size_t plane, IOSurfaceLockOptions options, uint32_t *seed) { return IOSurfaceLock(buffer, options, seed); }
kern_return_t IOSurfaceUnlockPlane(IOSurfaceRef buffer, size_t plane, IOSurfaceLockOptions options, uint32_t *seed) { return IOSurfaceUnlock(buffer, options, seed); }

void
IOSurfaceGetExtendedPixelsOfPlane(IOSurfaceRef buffer, size_t plane, size_t *left, size_t *right, size_t *top, size_t *bottom)
{
    if (left) *left = 0;
    if (right) *right = 0;
    if (top) *top = 0;
    if (bottom) *bottom = 0;
}

Boolean IOSurfaceIsTiled(IOSurfaceRef buffer) { return false; }
uint32_t IOSurfaceGetCompressionTypeOfPlane(IOSurfaceRef buffer, size_t plane) { return 0; }
size_t IOSurfaceGetCompressedTileWidthOfPlane(IOSurfaceRef buffer, size_t plane) { return 0; }
size_t IOSurfaceGetCompressedTileHeightOfPlane(IOSurfaceRef buffer, size_t plane) { return 0; }
size_t IOSurfaceGetWidthInCompressedTilesOfPlane(IOSurfaceRef buffer, size_t plane) { return 0; }
size_t IOSurfaceGetHeightInCompressedTilesOfPlane(IOSurfaceRef buffer, size_t plane) { return 0; }
size_t IOSurfaceGetBytesPerRowOfTileDataOfPlane(IOSurfaceRef buffer, size_t plane) { return 0; }
size_t IOSurfaceGetBytesPerRowOfCompressedTileHeaderGroupsOfPlane(IOSurfaceRef buffer, size_t plane) { return 0; }
void *IOSurfaceGetBaseAddressOfCompressedTileDataRegionOfPlane(IOSurfaceRef buffer, size_t plane) { return NULL; }
void *IOSurfaceGetBaseAddressOfCompressedTileHeaderRegionOfPlane(IOSurfaceRef buffer, size_t plane) { return NULL; }
uint32_t IOSurfaceGetHTPCVerticalHeaderGroupingModeOfPlane(IOSurfaceRef buffer, size_t plane) { return 0; }
int32_t IOSurfaceGetProhibitUseCount(IOSurfaceRef buffer) { return 0; }
uint64_t IOSurfaceGetProtectionOptions(IOSurfaceRef buffer) { return 0; }
Boolean IOSurfaceSupportsProtectionOptions(IOSurfaceRef buffer, uint64_t options) { return options == 0; }
kern_return_t IOSurfaceBindAccel(IOSurfaceRef buffer, uint32_t accel) { return KERN_SUCCESS; }

/* The YCbCr matrix, kept with the surface's attachments. */
kern_return_t
IOSurfaceGetYCbCrMatrix(IOSurfaceRef buffer, uint32_t *matrix)
{
    if (!buffer)
        return (kern_return_t)0xe00002c2;
    NSNumber *m = (__bridge_transfer NSNumber *)IOSurfaceCopyValue(buffer, CFSTR("IOSurfaceYCbCrMatrix"));
    if (matrix)
        *matrix = m.unsignedIntValue;
    return KERN_SUCCESS;
}

kern_return_t
IOSurfaceSetYCbCrMatrix(IOSurfaceRef buffer, uint32_t matrix)
{
    if (!buffer)
        return (kern_return_t)0xe00002c2;
    IOSurfaceSetValue(buffer, CFSTR("IOSurfaceYCbCrMatrix"), (__bridge CFTypeRef) @(matrix));
    return KERN_SUCCESS;
}

/* Data properties and bulk attachments go to the kernel's surface: there's none to hold
   them. */
kern_return_t IOSurfaceSetDataProperty(IOSurfaceRef buffer, CFStringRef key, const void *data, size_t size) { return (kern_return_t)0xe00002c7; }
kern_return_t IOSurfaceGetDataProperty(IOSurfaceRef buffer, CFStringRef key, void *data, size_t *size) { return (kern_return_t)0xe00002c7; }
kern_return_t IOSurfaceGetBulkAttachments(IOSurfaceRef buffer, void *attachments) { return (kern_return_t)0xe00002bc; }
kern_return_t IOSurfaceSetBulkAttachments2(IOSurfaceRef buffer, const void *attachments, uint32_t which) { return KERN_SUCCESS; }

/* Child surfaces, wrapped client images: not made here. */
IOSurfaceRef IOSurfaceCreateChildSurface(IOSurfaceRef parent, CFDictionaryRef properties) { return NULL; }
IOSurfaceRef IOSurfaceWrapClientImage(void *a, void *b, void *c, void *d, void *e, void *f) { return NULL; }

/* Wiring keeps the memory resident; it always is. */
id
IOSurfaceCreateWiringAssertion(IOSurfaceRef buffer)
{
    return [[NSObject alloc] init];
}

/* Notifiers tell of surfaces' events from the kernel: there are none. */
typedef struct __IOSurfaceNotifier *IOSurfaceNotifierRef;
kern_return_t
IOSurfaceNotifierCreate(IOSurfaceNotifierRef *notifier, void *callback, void *refcon)
{
    if (notifier)
        *notifier = NULL;
    return (kern_return_t)0xe00002c7;
}
void IOSurfaceNotifierSetDispatchQueue(IOSurfaceNotifierRef notifier, dispatch_queue_t queue) {}
