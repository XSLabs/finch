/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CoreMedia's block buffers, Finch's: a run of pieces, each a range of a memory block.
 * A block is the caller's memory, memory from an allocator or from a custom block
 * source, allocated when it's first needed (or at once, with the flag); blocks are
 * shared, counted, between the buffers that reference them. A reference to another
 * buffer copies that buffer's pieces in the range, so a buffer is never deeper than
 * one level (as Apple's are when they optimise depth, the default).
 *
 * As Apple's: a length of 0 means to the end of the buffer where a reference, a
 * contiguous buffer or a contiguity check is asked for; filling or replacing bytes
 * allocates memory not yet allocated, reading it is kCMBlockBufferUnallocatedBlockErr.
 */
#include "CMInternal.h"
#include <stdatomic.h>
#include <string.h>

typedef struct {
    _Atomic int refs;
    char *memory;
    size_t size;
    CFAllocatorRef allocator; /* (retained; NULL with a custom source) */
    bool hasSource;
    CMBlockBufferCustomBlockSource source;
} Block;

typedef struct {
    Block *block;
    size_t offset, length;
} Piece;

struct OpaqueCMBlockBuffer {
    CFRuntimeBase base;
    Piece *pieces;
    size_t count, capacity;
    size_t length;
};

static pthread_mutex_t allocating = PTHREAD_MUTEX_INITIALIZER;

static void
block_release(Block *b)
{
    if (atomic_fetch_sub(&b->refs, 1) != 1)
        return;
    if (b->memory) {
        if (b->hasSource) {
            if (b->source.FreeBlock)
                b->source.FreeBlock(b->source.refCon, b->memory, b->size);
        } else if (b->allocator != kCFAllocatorNull)
            CFAllocatorDeallocate(b->allocator, b->memory);
    }
    if (b->allocator)
        CFRelease(b->allocator);
    free(b);
}

/* The block's memory, allocated if it isn't yet; false if it can't be. */
static bool
block_assure(Block *b)
{
    if (b->memory)
        return true;
    pthread_mutex_lock(&allocating);
    if (!b->memory) {
        if (b->hasSource)
            b->memory = b->source.AllocateBlock ? b->source.AllocateBlock(b->source.refCon, b->size) : NULL;
        else if (b->allocator != kCFAllocatorNull)
            b->memory = CFAllocatorAllocate(b->allocator, (CFIndex)b->size, 0);
    }
    pthread_mutex_unlock(&allocating);
    return b->memory != NULL;
}

static void
finalize(CFTypeRef cf)
{
    CMBlockBufferRef bb = (CMBlockBufferRef)cf;
    for (size_t i = 0; i < bb->count; i++)
        block_release(bb->pieces[i].block);
    free(bb->pieces);
}

static CFStringRef
copy_description(CFTypeRef cf)
{
    CMBlockBufferRef bb = (CMBlockBufferRef)cf;
    CFMutableStringRef s = CFStringCreateMutable(NULL, 0);
    CFStringAppendFormat(s, NULL, CFSTR("<CMBlockBuffer %p totalDataLength: %zu"), cf, bb->length);
    for (size_t i = 0; i < bb->count; i++)
        CFStringAppendFormat(s, NULL, CFSTR(" [%zu] memoryBlock %p offset %zu dataLength %zu"), i, bb->pieces[i].block->memory,
                             bb->pieces[i].offset, bb->pieces[i].length);
    CFStringAppend(s, CFSTR(">"));
    return s;
}

CM_DEFINE_TYPE(CMBlockBufferGetTypeID, "CMBlockBuffer", finalize, NULL, NULL, copy_description)

static CMBlockBufferRef
create(CFAllocatorRef allocator)
{
    return (CMBlockBufferRef)cm_create(allocator, CMBlockBufferGetTypeID(), sizeof(struct OpaqueCMBlockBuffer));
}

static bool
append_piece(CMBlockBufferRef bb, Block *block, size_t offset, size_t length)
{
    /* (a piece continuing the last one in the same block joins it) */
    if (bb->count) {
        Piece *last = &bb->pieces[bb->count - 1];
        if (last->block == block && last->offset + last->length == offset) {
            last->length += length;
            bb->length += length;
            block_release(block);
            return true;
        }
    }
    if (bb->count == bb->capacity) {
        size_t c = bb->capacity ? bb->capacity * 2 : 4;
        Piece *p = realloc(bb->pieces, c * sizeof *p);
        if (!p)
            return false;
        bb->pieces = p, bb->capacity = c;
    }
    bb->pieces[bb->count++] = (Piece){block, offset, length};
    bb->length += length;
    return true;
}

/* The piece holding the byte at offset (which must be inside the buffer), and where in it. */
static Piece *
piece_at(CMBlockBufferRef bb, size_t offset, size_t *within)
{
    for (size_t i = 0; i < bb->count; i++) {
        if (offset < bb->pieces[i].length) {
            *within = offset;
            return &bb->pieces[i];
        }
        offset -= bb->pieces[i].length;
    }
    return NULL;
}

/* --- making them --- */

OSStatus
CMBlockBufferCreateEmpty(CFAllocatorRef structureAllocator, uint32_t subBlockCapacity, CMBlockBufferFlags flags, CMBlockBufferRef *blockBufferOut)
{
    if (!blockBufferOut)
        return kCMBlockBufferBadPointerParameterErr;
    *blockBufferOut = create(structureAllocator);
    if (!*blockBufferOut)
        return kCMBlockBufferStructureAllocationFailedErr;
    if (subBlockCapacity) {
        (*blockBufferOut)->pieces = calloc(subBlockCapacity, sizeof(Piece));
        (*blockBufferOut)->capacity = (*blockBufferOut)->pieces ? subBlockCapacity : 0;
    }
    return kCMBlockBufferNoErr;
}

static OSStatus
append_memory(CMBlockBufferRef bb, void *memoryBlock, size_t blockLength, CFAllocatorRef blockAllocator,
              const CMBlockBufferCustomBlockSource *customBlockSource, size_t offsetToData, size_t dataLength, CMBlockBufferFlags flags)
{
    if (!blockLength || !dataLength || offsetToData >= blockLength || dataLength > blockLength - offsetToData)
        return kCMBlockBufferBadLengthParameterErr;
    if (customBlockSource && customBlockSource->version != kCMBlockBufferCustomBlockSourceVersion)
        return kCMBlockBufferBadCustomBlockSourceErr;
    Block *b = calloc(1, sizeof *b);
    if (!b)
        return kCMBlockBufferStructureAllocationFailedErr;
    b->refs = 1;
    b->memory = memoryBlock;
    b->size = blockLength;
    if (customBlockSource) {
        b->hasSource = true;
        memcpy(&b->source, customBlockSource, sizeof b->source);
    } else
        b->allocator = CFRetain(blockAllocator ? blockAllocator : CFAllocatorGetDefault());
    if ((flags & kCMBlockBufferAssureMemoryNowFlag) && !block_assure(b)) {
        block_release(b);
        return kCMBlockBufferBlockAllocationFailedErr;
    }
    if (!append_piece(bb, b, offsetToData, dataLength)) {
        b->memory = NULL; /* (the caller's still) */
        block_release(b);
        return kCMBlockBufferStructureAllocationFailedErr;
    }
    return kCMBlockBufferNoErr;
}

OSStatus
CMBlockBufferCreateWithMemoryBlock(CFAllocatorRef structureAllocator, void *memoryBlock, size_t blockLength, CFAllocatorRef blockAllocator,
                                   const CMBlockBufferCustomBlockSource *customBlockSource, size_t offsetToData, size_t dataLength,
                                   CMBlockBufferFlags flags, CMBlockBufferRef *blockBufferOut)
{
    if (!blockBufferOut)
        return kCMBlockBufferBadPointerParameterErr;
    *blockBufferOut = NULL;
    CMBlockBufferRef bb = create(structureAllocator);
    if (!bb)
        return kCMBlockBufferStructureAllocationFailedErr;
    OSStatus e = append_memory(bb, memoryBlock, blockLength, blockAllocator, customBlockSource, offsetToData, dataLength, flags);
    if (e) {
        CFRelease(bb);
        return e;
    }
    *blockBufferOut = bb;
    return kCMBlockBufferNoErr;
}

OSStatus
CMBlockBufferAppendMemoryBlock(CMBlockBufferRef theBuffer, void *memoryBlock, size_t blockLength, CFAllocatorRef blockAllocator,
                               const CMBlockBufferCustomBlockSource *customBlockSource, size_t offsetToData, size_t dataLength,
                               CMBlockBufferFlags flags)
{
    if (!theBuffer)
        return kCMBlockBufferBadPointerParameterErr;
    return append_memory(theBuffer, memoryBlock, blockLength, blockAllocator, customBlockSource, offsetToData, dataLength, flags);
}

/* The range of target a reference takes (a length of 0: to its end). */
static OSStatus
reference_range(CMBlockBufferRef target, size_t offset, size_t *length, CMBlockBufferFlags flags)
{
    bool permitEmpty = (flags & kCMBlockBufferPermitEmptyReferenceFlag) != 0;
    if (offset > target->length || (offset == target->length && !permitEmpty && target->length))
        return kCMBlockBufferBadOffsetParameterErr;
    if (!*length)
        *length = target->length - offset;
    else if (*length > target->length - offset)
        return kCMBlockBufferBadLengthParameterErr;
    if (!*length && !permitEmpty)
        return target->length ? kCMBlockBufferBadLengthParameterErr : kCMBlockBufferEmptyBBufErr;
    return kCMBlockBufferNoErr;
}

static OSStatus
append_reference(CMBlockBufferRef bb, CMBlockBufferRef target, size_t offset, size_t length)
{
    /* (from a copy of the target's pieces: the target may be bb itself) */
    size_t count = target->count;
    Piece *pieces = malloc((count ? count : 1) * sizeof *pieces);
    if (!pieces)
        return kCMBlockBufferStructureAllocationFailedErr;
    memcpy(pieces, target->pieces, count * sizeof *pieces);
    for (size_t i = 0; i < count && length; i++) {
        Piece p = pieces[i];
        if (offset >= p.length) {
            offset -= p.length;
            continue;
        }
        size_t n = p.length - offset < length ? p.length - offset : length;
        atomic_fetch_add(&p.block->refs, 1);
        if (!append_piece(bb, p.block, p.offset + offset, n)) {
            block_release(p.block);
            free(pieces);
            return kCMBlockBufferStructureAllocationFailedErr;
        }
        length -= n;
        offset = 0;
    }
    free(pieces);
    return kCMBlockBufferNoErr;
}

OSStatus
CMBlockBufferCreateWithBufferReference(CFAllocatorRef structureAllocator, CMBlockBufferRef bufferReference, size_t offsetToData,
                                       size_t dataLength, CMBlockBufferFlags flags, CMBlockBufferRef *blockBufferOut)
{
    if (!blockBufferOut || !bufferReference)
        return kCMBlockBufferBadPointerParameterErr;
    *blockBufferOut = NULL;
    OSStatus e = reference_range(bufferReference, offsetToData, &dataLength, flags);
    if (e)
        return e;
    CMBlockBufferRef bb = create(structureAllocator);
    if (!bb)
        return kCMBlockBufferStructureAllocationFailedErr;
    if ((e = append_reference(bb, bufferReference, offsetToData, dataLength))) {
        CFRelease(bb);
        return e;
    }
    *blockBufferOut = bb;
    return kCMBlockBufferNoErr;
}

OSStatus
CMBlockBufferAppendBufferReference(CMBlockBufferRef theBuffer, CMBlockBufferRef targetBBuf, size_t offsetToData, size_t dataLength,
                                   CMBlockBufferFlags flags)
{
    if (!theBuffer || !targetBBuf)
        return kCMBlockBufferBadPointerParameterErr;
    OSStatus e = reference_range(targetBBuf, offsetToData, &dataLength, flags);
    return e ? e : append_reference(theBuffer, targetBBuf, offsetToData, dataLength);
}

Boolean
CMBlockBufferIsRangeContiguous(CMBlockBufferRef theBuffer, size_t offset, size_t length)
{
    if (!theBuffer || offset >= theBuffer->length)
        return false;
    if (!length)
        length = theBuffer->length - offset;
    if (length > theBuffer->length - offset)
        return false;
    size_t within;
    Piece *p = piece_at(theBuffer, offset, &within);
    return p && within + length <= p->length;
}

static OSStatus copy_bytes(CMBlockBufferRef bb, size_t offset, size_t length, char *out);

OSStatus
CMBlockBufferCreateContiguous(CFAllocatorRef structureAllocator, CMBlockBufferRef sourceBuffer, CFAllocatorRef blockAllocator,
                              const CMBlockBufferCustomBlockSource *customBlockSource, size_t offsetToData, size_t dataLength,
                              CMBlockBufferFlags flags, CMBlockBufferRef *blockBufferOut)
{
    if (!blockBufferOut || !sourceBuffer)
        return kCMBlockBufferBadPointerParameterErr;
    *blockBufferOut = NULL;
    if (!sourceBuffer->length)
        return kCMBlockBufferEmptyBBufErr;
    if (offsetToData >= sourceBuffer->length)
        return kCMBlockBufferBadOffsetParameterErr;
    if (!dataLength)
        dataLength = sourceBuffer->length - offsetToData;
    else if (dataLength > sourceBuffer->length - offsetToData)
        return kCMBlockBufferBadLengthParameterErr;
    if (!(flags & kCMBlockBufferAlwaysCopyDataFlag) && CMBlockBufferIsRangeContiguous(sourceBuffer, offsetToData, dataLength))
        return CMBlockBufferCreateWithBufferReference(structureAllocator, sourceBuffer, offsetToData, dataLength, 0, blockBufferOut);
    CMBlockBufferRef bb = NULL;
    OSStatus e = CMBlockBufferCreateWithMemoryBlock(structureAllocator, NULL, dataLength, blockAllocator, customBlockSource, 0, dataLength,
                                                    kCMBlockBufferAssureMemoryNowFlag, &bb);
    if (e)
        return e;
    if ((e = copy_bytes(sourceBuffer, offsetToData, dataLength, bb->pieces[0].block->memory))) {
        CFRelease(bb);
        return e;
    }
    *blockBufferOut = bb;
    return kCMBlockBufferNoErr;
}

/* --- the bytes --- */

OSStatus
CMBlockBufferAssureBlockMemory(CMBlockBufferRef theBuffer)
{
    if (!theBuffer)
        return kCMBlockBufferBadPointerParameterErr;
    for (size_t i = 0; i < theBuffer->count; i++)
        if (!block_assure(theBuffer->pieces[i].block))
            return kCMBlockBufferBlockAllocationFailedErr;
    return kCMBlockBufferNoErr;
}

/* The checks the byte operations share: a length, inside the buffer. */
static OSStatus
check_range(CMBlockBufferRef bb, size_t offset, size_t length)
{
    if (!length)
        return kCMBlockBufferBadLengthParameterErr;
    if (offset >= bb->length)
        return bb->length ? kCMBlockBufferBadOffsetParameterErr : kCMBlockBufferBadLengthParameterErr;
    if (length > bb->length - offset)
        return kCMBlockBufferBadLengthParameterErr;
    return kCMBlockBufferNoErr;
}

/* Calls fn on each run of the range, in order (allocating if asked); stops at an error. */
static OSStatus
each_run(CMBlockBufferRef bb, size_t offset, size_t length, bool allocate, void (*fn)(char *memory, size_t n, void *context),
         void *context)
{
    for (size_t i = 0; i < bb->count && length; i++) {
        Piece *p = &bb->pieces[i];
        if (offset >= p->length) {
            offset -= p->length;
            continue;
        }
        if (allocate ? !block_assure(p->block) : !p->block->memory)
            return allocate ? kCMBlockBufferBlockAllocationFailedErr : kCMBlockBufferUnallocatedBlockErr;
        size_t n = p->length - offset < length ? p->length - offset : length;
        fn(p->block->memory + p->offset + offset, n, context);
        length -= n;
        offset = 0;
    }
    return kCMBlockBufferNoErr;
}

static void
copy_out(char *memory, size_t n, void *context)
{
    char **at = context;
    memcpy(*at, memory, n);
    *at += n;
}

static void
copy_in(char *memory, size_t n, void *context)
{
    const char **at = context;
    memcpy(memory, *at, n);
    *at += n;
}

static void
fill(char *memory, size_t n, void *context)
{
    memset(memory, *(char *)context, n);
}

static OSStatus
copy_bytes(CMBlockBufferRef bb, size_t offset, size_t length, char *out)
{
    return each_run(bb, offset, length, false, copy_out, &out);
}

OSStatus
CMBlockBufferCopyDataBytes(CMBlockBufferRef theSourceBuffer, size_t offsetToData, size_t dataLength, void *destination)
{
    if (!theSourceBuffer || !destination)
        return kCMBlockBufferBadPointerParameterErr;
    OSStatus e = check_range(theSourceBuffer, offsetToData, dataLength);
    return e ? e : copy_bytes(theSourceBuffer, offsetToData, dataLength, destination);
}

OSStatus
CMBlockBufferReplaceDataBytes(const void *sourceBytes, CMBlockBufferRef destinationBuffer, size_t offsetIntoDestination, size_t dataLength)
{
    if (!sourceBytes || !destinationBuffer)
        return kCMBlockBufferBadPointerParameterErr;
    OSStatus e = check_range(destinationBuffer, offsetIntoDestination, dataLength);
    return e ? e : each_run(destinationBuffer, offsetIntoDestination, dataLength, true, copy_in, &sourceBytes);
}

OSStatus
CMBlockBufferFillDataBytes(char fillByte, CMBlockBufferRef destinationBuffer, size_t offsetIntoDestination, size_t dataLength)
{
    if (!destinationBuffer)
        return kCMBlockBufferBadPointerParameterErr;
    if (!dataLength)
        return offsetIntoDestination <= destinationBuffer->length ? kCMBlockBufferNoErr : kCMBlockBufferBadOffsetParameterErr;
    OSStatus e = check_range(destinationBuffer, offsetIntoDestination, dataLength);
    return e ? e : each_run(destinationBuffer, offsetIntoDestination, dataLength, true, fill, &fillByte);
}

OSStatus
CMBlockBufferAccessDataBytes(CMBlockBufferRef theBuffer, size_t offset, size_t length, void *temporaryBlock, char **returnedPointerOut)
{
    if (!theBuffer || !returnedPointerOut)
        return kCMBlockBufferBadPointerParameterErr;
    *returnedPointerOut = NULL;
    OSStatus e = check_range(theBuffer, offset, length);
    if (e)
        return e;
    size_t within;
    Piece *p = piece_at(theBuffer, offset, &within);
    if (within + length <= p->length) {
        if (!p->block->memory)
            return kCMBlockBufferUnallocatedBlockErr;
        *returnedPointerOut = p->block->memory + p->offset + within;
        return kCMBlockBufferNoErr;
    }
    if (!temporaryBlock)
        return kCMBlockBufferBadPointerParameterErr;
    if ((e = copy_bytes(theBuffer, offset, length, temporaryBlock)))
        return e;
    *returnedPointerOut = temporaryBlock;
    return kCMBlockBufferNoErr;
}

OSStatus
CMBlockBufferGetDataPointer(CMBlockBufferRef theBuffer, size_t offset, size_t *lengthAtOffsetOut, size_t *totalLengthOut,
                            char **dataPointerOut)
{
    if (lengthAtOffsetOut)
        *lengthAtOffsetOut = 0;
    if (dataPointerOut)
        *dataPointerOut = NULL;
    if (!theBuffer)
        return kCMBlockBufferBadPointerParameterErr;
    if (totalLengthOut)
        *totalLengthOut = theBuffer->length;
    if (offset >= theBuffer->length)
        return kCMBlockBufferBadOffsetParameterErr;
    size_t within;
    Piece *p = piece_at(theBuffer, offset, &within);
    if (!p->block->memory)
        return kCMBlockBufferUnallocatedBlockErr;
    if (lengthAtOffsetOut)
        *lengthAtOffsetOut = p->length - within;
    if (dataPointerOut)
        *dataPointerOut = p->block->memory + p->offset + within;
    return kCMBlockBufferNoErr;
}

size_t
CMBlockBufferGetDataLength(CMBlockBufferRef theBuffer)
{
    return theBuffer ? theBuffer->length : 0;
}

Boolean
CMBlockBufferIsEmpty(CMBlockBufferRef theBuffer)
{
    return !theBuffer || !theBuffer->length;
}
