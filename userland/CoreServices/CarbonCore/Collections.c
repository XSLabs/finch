/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "CarbonCore_Finch.h"
#include <pthread.h>

#undef NewCollectionFlattenUPP
#undef NewCollectionExceptionUPP
#undef DisposeCollectionFlattenUPP
#undef DisposeCollectionExceptionUPP
#undef InvokeCollectionFlattenUPP
#undef InvokeCollectionExceptionUPP

struct collection_item {
    CollectionTag tag;
    SInt32 id;
    SInt32 attributes;
    SInt32 size;
    void *data;
};

struct OpaqueCollection {
    struct OpaqueCollection *next;
    pthread_mutex_t lock;
    struct collection_item *items;
    SInt32 count;
    SInt32 capacity;
    SInt32 defaultAttributes;
    ItemCount references;
    CollectionExceptionUPP exceptionProc;
};

static struct OpaqueCollection *collections;
static pthread_mutex_t collections_lock = PTHREAD_MUTEX_INITIALIZER;

static struct OpaqueCollection *
collection_get(Collection c)
{
    pthread_mutex_lock(&collections_lock);
    struct OpaqueCollection *found = NULL;
    for (struct OpaqueCollection *p = collections; p; p = p->next)
        if (p == c) {
            found = p;
            break;
        }
    pthread_mutex_unlock(&collections_lock);
    return found;
}

static SInt32
collection_find(struct OpaqueCollection *c, CollectionTag tag, SInt32 id)
{
    for (SInt32 i = 0; i < c->count; i++)
        if (c->items[i].tag == tag && c->items[i].id == id)
            return i;
    return -1;
}

static Boolean
collection_reserve(struct OpaqueCollection *c, SInt32 count)
{
    if (count <= c->capacity)
        return true;
    if (count < 0 || (size_t)count > SIZE_MAX / sizeof *c->items)
        return false;
    SInt32 capacity = c->capacity ? c->capacity : 8;
    while (capacity < count) {
        if (capacity > INT32_MAX / 2) {
            capacity = count;
            break;
        }
        capacity *= 2;
    }
    void *items = realloc(c->items, (size_t)capacity * sizeof *c->items);
    if (!items)
        return false;
    c->items = items;
    c->capacity = capacity;
    return true;
}

static void
collection_remove_at(struct OpaqueCollection *c, SInt32 index)
{
    free(c->items[index].data);
    c->count--;
    if (index < c->count)
        memmove(&c->items[index], &c->items[index + 1], (size_t)(c->count - index) * sizeof *c->items);
}

static OSErr
collection_add(Collection c, CollectionTag tag, SInt32 id, SInt32 itemSize, const void *itemData)
{
    struct OpaqueCollection *object = collection_get(c);
    if (!object || itemSize < 0 || (itemSize && !itemData))
        return paramErr;
    void *copy = malloc(itemSize ? (size_t)itemSize : 1);
    if (!copy)
        return memFullErr;
    if (itemSize)
        memcpy(copy, itemData, (size_t)itemSize);

    pthread_mutex_lock(&object->lock);
    SInt32 index = collection_find(object, tag, id);
    if (index >= 0) {
        free(object->items[index].data);
        object->items[index].data = copy;
        object->items[index].size = itemSize;
    } else if (!collection_reserve(object, object->count + 1)) {
        pthread_mutex_unlock(&object->lock);
        free(copy);
        return memFullErr;
    } else {
        object->items[object->count++] = (struct collection_item){tag, id, object->defaultAttributes,
                                                                  itemSize, copy};
    }
    pthread_mutex_unlock(&object->lock);
    return noErr;
}

static OSErr
collection_get_data(Collection c, SInt32 index, SInt32 *itemSize, void *itemData)
{
    struct OpaqueCollection *object = collection_get(c);
    if (!object)
        return paramErr;
    pthread_mutex_lock(&object->lock);
    if (index < 0 || index >= object->count) {
        pthread_mutex_unlock(&object->lock);
        return collectionIndexRangeErr;
    }
    struct collection_item *item = &object->items[index];
    if (itemSize)
        *itemSize = item->size;
    if (itemData && item->size)
        memcpy(itemData, item->data, (size_t)item->size);
    pthread_mutex_unlock(&object->lock);
    return noErr;
}

static SInt32
collection_index_for_tag(struct OpaqueCollection *object, CollectionTag tag, SInt32 wanted)
{
    for (SInt32 i = 0; i < object->count; i++) {
        if (object->items[i].tag != tag)
            continue;
        if (wanted-- == 0)
            return i;
    }
    return -1;
}

Collection
NewCollection(void)
{
    struct OpaqueCollection *c = calloc(1, sizeof *c);
    if (!c)
        return NULL;
    pthread_mutex_init(&c->lock, NULL);
    c->defaultAttributes = kCollectionDefaultAttributes;
    c->references = 2;
    pthread_mutex_lock(&collections_lock);
    c->next = collections;
    collections = c;
    pthread_mutex_unlock(&collections_lock);
    return c;
}

void
DisposeCollection(Collection c)
{
    struct OpaqueCollection *object = collection_get(c);
    if (!object)
        return;
    pthread_mutex_lock(&collections_lock);
    struct OpaqueCollection **link = &collections;
    while (*link && *link != object)
        link = &(*link)->next;
    if (*link)
        *link = object->next;
    pthread_mutex_unlock(&collections_lock);
    for (SInt32 i = 0; i < object->count; i++)
        free(object->items[i].data);
    free(object->items);
    pthread_mutex_destroy(&object->lock);
    free(object);
}

SInt32
CountCollectionItems(Collection c)
{
    struct OpaqueCollection *object = collection_get(c);
    if (!object)
        return 0;
    pthread_mutex_lock(&object->lock);
    SInt32 count = object->count;
    pthread_mutex_unlock(&object->lock);
    return count;
}

SInt32
CountCollectionOwners(Collection c)
{
    struct OpaqueCollection *object = collection_get(c);
    return object ? (SInt32)GetCollectionRetainCount(c) : 0;
}

OSStatus
RetainCollection(Collection c)
{
    struct OpaqueCollection *object = collection_get(c);
    if (!object)
        return paramErr;
    pthread_mutex_lock(&object->lock);
    object->references++;
    pthread_mutex_unlock(&object->lock);
    return noErr;
}

OSStatus
ReleaseCollection(Collection c)
{
    struct OpaqueCollection *object = collection_get(c);
    if (!object)
        return paramErr;
    pthread_mutex_lock(&object->lock);
    ItemCount references = object->references;
    if (references > 1)
        object->references--;
    pthread_mutex_unlock(&object->lock);
    if (references <= 1)
        DisposeCollection(c);
    return noErr;
}

ItemCount
GetCollectionRetainCount(Collection c)
{
    struct OpaqueCollection *object = collection_get(c);
    if (!object)
        return 0;
    pthread_mutex_lock(&object->lock);
    ItemCount references = object->references;
    pthread_mutex_unlock(&object->lock);
    return references;
}

Collection
CopyCollection(Collection srcCollection, Collection dstCollection)
{
    struct OpaqueCollection *source = collection_get(srcCollection);
    struct OpaqueCollection *destination = collection_get(dstCollection);
    if (!source || !destination || source == destination)
        return NULL;
    pthread_mutex_lock(&source->lock);
    struct collection_item *items = calloc((size_t)source->count, sizeof *items);
    if (!items && source->count) {
        pthread_mutex_unlock(&source->lock);
        return NULL;
    }
    SInt32 count = source->count;
    SInt32 defaultAttributes = source->defaultAttributes;
    CollectionExceptionUPP exceptionProc = source->exceptionProc;
    for (SInt32 i = 0; i < count; i++) {
        items[i] = source->items[i];
        items[i].data = malloc(items[i].size ? (size_t)items[i].size : 1);
        if (!items[i].data) {
            for (SInt32 j = 0; j < i; j++)
                free(items[j].data);
            free(items);
            pthread_mutex_unlock(&source->lock);
            return NULL;
        }
        if (items[i].size)
            memcpy(items[i].data, source->items[i].data, (size_t)items[i].size);
    }
    pthread_mutex_unlock(&source->lock);

    pthread_mutex_lock(&destination->lock);
    for (SInt32 i = 0; i < destination->count; i++)
        free(destination->items[i].data);
    free(destination->items);
    destination->items = items;
    destination->count = count;
    destination->capacity = count;
    destination->defaultAttributes = defaultAttributes;
    destination->exceptionProc = exceptionProc;
    pthread_mutex_unlock(&destination->lock);
    return dstCollection;
}

Collection
CloneCollection(Collection c)
{
    Collection clone = NewCollection();
    if (!clone)
        return NULL;
    if (!CopyCollection(c, clone)) {
        DisposeCollection(clone);
        return NULL;
    }
    return clone;
}

SInt32
GetCollectionDefaultAttributes(Collection c)
{
    struct OpaqueCollection *object = collection_get(c);
    if (!object)
        return 0;
    pthread_mutex_lock(&object->lock);
    SInt32 attributes = object->defaultAttributes;
    pthread_mutex_unlock(&object->lock);
    return attributes;
}

void
SetCollectionDefaultAttributes(Collection c, SInt32 whichAttributes, SInt32 newAttributes)
{
    struct OpaqueCollection *object = collection_get(c);
    if (!object)
        return;
    pthread_mutex_lock(&object->lock);
    object->defaultAttributes = (object->defaultAttributes & ~whichAttributes) | (newAttributes & whichAttributes);
    pthread_mutex_unlock(&object->lock);
}

OSErr
AddCollectionItem(Collection c, CollectionTag tag, SInt32 id, SInt32 itemSize, const void *itemData)
{
    return collection_add(c, tag, id, itemSize, itemData);
}

OSErr
GetCollectionItem(Collection c, CollectionTag tag, SInt32 id, SInt32 *itemSize, void *itemData)
{
    struct OpaqueCollection *object = collection_get(c);
    if (!object)
        return paramErr;
    pthread_mutex_lock(&object->lock);
    SInt32 index = collection_find(object, tag, id);
    pthread_mutex_unlock(&object->lock);
    return index < 0 ? collectionItemNotFoundErr : collection_get_data(c, index, itemSize, itemData);
}

OSErr
RemoveCollectionItem(Collection c, CollectionTag tag, SInt32 id)
{
    struct OpaqueCollection *object = collection_get(c);
    if (!object)
        return paramErr;
    pthread_mutex_lock(&object->lock);
    SInt32 index = collection_find(object, tag, id);
    if (index >= 0)
        collection_remove_at(object, index);
    pthread_mutex_unlock(&object->lock);
    return index < 0 ? collectionItemNotFoundErr : noErr;
}

OSErr
SetCollectionItemInfo(Collection c, CollectionTag tag, SInt32 id, SInt32 whichAttributes, SInt32 newAttributes)
{
    struct OpaqueCollection *object = collection_get(c);
    if (!object)
        return paramErr;
    pthread_mutex_lock(&object->lock);
    SInt32 index = collection_find(object, tag, id);
    if (index >= 0)
        object->items[index].attributes = (object->items[index].attributes & ~whichAttributes) |
                                          (newAttributes & whichAttributes);
    pthread_mutex_unlock(&object->lock);
    return index < 0 ? collectionItemNotFoundErr : noErr;
}

OSErr
GetCollectionItemInfo(Collection c, CollectionTag tag, SInt32 id, SInt32 *itemIndex, SInt32 *itemSize,
                      SInt32 *attributes)
{
    struct OpaqueCollection *object = collection_get(c);
    if (!object)
        return paramErr;
    pthread_mutex_lock(&object->lock);
    SInt32 index = collection_find(object, tag, id);
    if (index >= 0) {
        if (itemIndex) *itemIndex = index + 1;
        if (itemSize) *itemSize = object->items[index].size;
        if (attributes) *attributes = object->items[index].attributes;
    }
    pthread_mutex_unlock(&object->lock);
    return index < 0 ? collectionItemNotFoundErr : noErr;
}

OSErr
ReplaceIndexedCollectionItem(Collection c, SInt32 itemIndex, SInt32 itemSize, const void *itemData)
{
    struct OpaqueCollection *object = collection_get(c);
    if (!object || itemSize < 0 || (itemSize && !itemData))
        return paramErr;
    void *copy = malloc(itemSize ? (size_t)itemSize : 1);
    if (!copy)
        return memFullErr;
    if (itemSize)
        memcpy(copy, itemData, (size_t)itemSize);
    pthread_mutex_lock(&object->lock);
    if (itemIndex < 1 || itemIndex > object->count) {
        pthread_mutex_unlock(&object->lock);
        free(copy);
        return collectionIndexRangeErr;
    }
    struct collection_item *item = &object->items[itemIndex - 1];
    free(item->data);
    item->data = copy;
    item->size = itemSize;
    pthread_mutex_unlock(&object->lock);
    return noErr;
}

OSErr
GetIndexedCollectionItem(Collection c, SInt32 itemIndex, SInt32 *itemSize, void *itemData)
{
    return collection_get_data(c, itemIndex - 1, itemSize, itemData);
}

OSErr
RemoveIndexedCollectionItem(Collection c, SInt32 itemIndex)
{
    struct OpaqueCollection *object = collection_get(c);
    if (!object)
        return paramErr;
    pthread_mutex_lock(&object->lock);
    if (itemIndex < 1 || itemIndex > object->count) {
        pthread_mutex_unlock(&object->lock);
        return collectionIndexRangeErr;
    }
    collection_remove_at(object, itemIndex - 1);
    pthread_mutex_unlock(&object->lock);
    return noErr;
}

OSErr
SetIndexedCollectionItemInfo(Collection c, SInt32 itemIndex, SInt32 whichAttributes, SInt32 newAttributes)
{
    struct OpaqueCollection *object = collection_get(c);
    if (!object)
        return paramErr;
    pthread_mutex_lock(&object->lock);
    if (itemIndex < 1 || itemIndex > object->count) {
        pthread_mutex_unlock(&object->lock);
        return collectionIndexRangeErr;
    }
    struct collection_item *item = &object->items[itemIndex - 1];
    item->attributes = (item->attributes & ~whichAttributes) | (newAttributes & whichAttributes);
    pthread_mutex_unlock(&object->lock);
    return noErr;
}

OSErr
GetIndexedCollectionItemInfo(Collection c, SInt32 itemIndex, CollectionTag *tag, SInt32 *id,
                             SInt32 *itemSize, SInt32 *attributes)
{
    struct OpaqueCollection *object = collection_get(c);
    if (!object)
        return paramErr;
    pthread_mutex_lock(&object->lock);
    if (itemIndex < 1 || itemIndex > object->count) {
        pthread_mutex_unlock(&object->lock);
        return collectionIndexRangeErr;
    }
    struct collection_item *item = &object->items[itemIndex - 1];
    if (tag) *tag = item->tag;
    if (id) *id = item->id;
    if (itemSize) *itemSize = item->size;
    if (attributes) *attributes = item->attributes;
    pthread_mutex_unlock(&object->lock);
    return noErr;
}

Boolean
CollectionTagExists(Collection c, CollectionTag tag)
{
    struct OpaqueCollection *object = collection_get(c);
    if (!object)
        return false;
    pthread_mutex_lock(&object->lock);
    Boolean found = false;
    for (SInt32 i = 0; i < object->count; i++)
        found |= object->items[i].tag == tag;
    pthread_mutex_unlock(&object->lock);
    return found;
}

SInt32
CountCollectionTags(Collection c)
{
    struct OpaqueCollection *object = collection_get(c);
    if (!object)
        return 0;
    pthread_mutex_lock(&object->lock);
    SInt32 count = 0;
    for (SInt32 i = 0; i < object->count; i++) {
        Boolean seen = false;
        for (SInt32 j = 0; j < i; j++)
            seen |= object->items[i].tag == object->items[j].tag;
        if (!seen)
            count++;
    }
    pthread_mutex_unlock(&object->lock);
    return count;
}

OSErr
GetIndexedCollectionTag(Collection c, SInt32 tagIndex, CollectionTag *tag)
{
    struct OpaqueCollection *object = collection_get(c);
    if (!object || !tag)
        return paramErr;
    if (tagIndex < 1)
        return collectionIndexRangeErr;
    pthread_mutex_lock(&object->lock);
    SInt32 at = 0;
    for (SInt32 i = 0; i < object->count; i++) {
        Boolean seen = false;
        for (SInt32 j = 0; j < i; j++)
            seen |= object->items[i].tag == object->items[j].tag;
        if (!seen && ++at == tagIndex) {
            *tag = object->items[i].tag;
            pthread_mutex_unlock(&object->lock);
            return noErr;
        }
    }
    pthread_mutex_unlock(&object->lock);
    return collectionIndexRangeErr;
}

SInt32
CountTaggedCollectionItems(Collection c, CollectionTag tag)
{
    struct OpaqueCollection *object = collection_get(c);
    if (!object)
        return 0;
    pthread_mutex_lock(&object->lock);
    SInt32 count = 0;
    for (SInt32 i = 0; i < object->count; i++)
        count += object->items[i].tag == tag;
    pthread_mutex_unlock(&object->lock);
    return count;
}

OSErr
GetTaggedCollectionItem(Collection c, CollectionTag tag, SInt32 whichItem, SInt32 *itemSize, void *itemData)
{
    struct OpaqueCollection *object = collection_get(c);
    if (!object)
        return paramErr;
    pthread_mutex_lock(&object->lock);
    SInt32 index = collection_index_for_tag(object, tag, whichItem - 1);
    pthread_mutex_unlock(&object->lock);
    return index < 0 ? collectionItemNotFoundErr : collection_get_data(c, index, itemSize, itemData);
}

OSErr
GetTaggedCollectionItemInfo(Collection c, CollectionTag tag, SInt32 whichItem, SInt32 *id,
                            SInt32 *itemIndex, SInt32 *itemSize, SInt32 *attributes)
{
    struct OpaqueCollection *object = collection_get(c);
    if (!object)
        return paramErr;
    pthread_mutex_lock(&object->lock);
    SInt32 index = collection_index_for_tag(object, tag, whichItem - 1);
    if (index >= 0) {
        struct collection_item *item = &object->items[index];
        if (id) *id = item->id;
        if (itemIndex) *itemIndex = index + 1;
        if (itemSize) *itemSize = item->size;
        if (attributes) *attributes = item->attributes;
    }
    pthread_mutex_unlock(&object->lock);
    return index < 0 ? collectionItemNotFoundErr : noErr;
}

void
PurgeCollection(Collection c, SInt32 whichAttributes, SInt32 matchingAttributes)
{
    struct OpaqueCollection *object = collection_get(c);
    if (!object)
        return;
    pthread_mutex_lock(&object->lock);
    for (SInt32 i = object->count - 1; i >= 0; i--)
        if ((object->items[i].attributes & whichAttributes) == matchingAttributes)
            collection_remove_at(object, i);
    pthread_mutex_unlock(&object->lock);
}

void
PurgeCollectionTag(Collection c, CollectionTag tag)
{
    struct OpaqueCollection *object = collection_get(c);
    if (!object)
        return;
    pthread_mutex_lock(&object->lock);
    for (SInt32 i = object->count - 1; i >= 0; i--)
        if (object->items[i].tag == tag)
            collection_remove_at(object, i);
    pthread_mutex_unlock(&object->lock);
}

void
EmptyCollection(Collection c)
{
    struct OpaqueCollection *object = collection_get(c);
    if (!object)
        return;
    pthread_mutex_lock(&object->lock);
    for (SInt32 i = 0; i < object->count; i++)
        free(object->items[i].data);
    object->count = 0;
    pthread_mutex_unlock(&object->lock);
}

CollectionExceptionUPP
GetCollectionExceptionProc(Collection c)
{
    struct OpaqueCollection *object = collection_get(c);
    if (!object)
        return NULL;
    pthread_mutex_lock(&object->lock);
    CollectionExceptionUPP proc = object->exceptionProc;
    pthread_mutex_unlock(&object->lock);
    return proc;
}

void
SetCollectionExceptionProc(Collection c, CollectionExceptionUPP exceptionProc)
{
    struct OpaqueCollection *object = collection_get(c);
    if (!object)
        return;
    pthread_mutex_lock(&object->lock);
    object->exceptionProc = exceptionProc;
    pthread_mutex_unlock(&object->lock);
}

static UInt32
collection_read_be32(const UInt8 *bytes)
{
    UInt32 value;
    memcpy(&value, bytes, sizeof value);
    return CFSwapInt32BigToHost(value);
}

static void
collection_write_be32(UInt8 *bytes, UInt32 value)
{
    value = CFSwapInt32HostToBig(value);
    memcpy(bytes, &value, sizeof value);
}

static size_t
collection_align2(size_t value)
{
    return (value + 1) & ~(size_t)1;
}

OSErr
FlattenCollectionToHdl(Collection collection, Handle flattened)
{
    struct OpaqueCollection *object = collection_get(collection);
    if (!object || !flattened)
        return paramErr;
    pthread_mutex_lock(&object->lock);
    size_t headerSize = 12 + (size_t)object->count * 16;
    size_t dataSize = 0;
    for (SInt32 i = 0; i < object->count; i++) {
        if (object->items[i].size > 0) {
            size_t itemBytes = collection_align2((size_t)object->items[i].size);
            if (itemBytes > SIZE_MAX - dataSize - 4) {
                pthread_mutex_unlock(&object->lock);
                return memFullErr;
            }
            dataSize += 4 + itemBytes;
        }
    }
    if (headerSize > SIZE_MAX - (dataSize ? dataSize + 4 : 0) ||
        headerSize + (dataSize ? dataSize + 4 : 0) > LONG_MAX) {
        pthread_mutex_unlock(&object->lock);
        return memFullErr;
    }
    Size flattenedSize = (Size)(headerSize + (dataSize ? dataSize + 4 : 0));
    SetHandleSize(flattened, flattenedSize);
    OSErr memoryStatus = MemError();
    if (memoryStatus != noErr) {
        pthread_mutex_unlock(&object->lock);
        return memoryStatus;
    }
    HLock(flattened);
    UInt8 *bytes = (UInt8 *)*flattened;
    memset(bytes, 0, (size_t)flattenedSize);
    collection_write_be32(bytes, 0x00010000);
    collection_write_be32(bytes + 4, (UInt32)object->defaultAttributes);
    collection_write_be32(bytes + 8, (UInt32)object->count);
    size_t nextDataOffset = 0;
    for (SInt32 i = 0; i < object->count; i++) {
        struct collection_item *item = &object->items[i];
        UInt8 *record = bytes + 12 + (size_t)i * 16;
        collection_write_be32(record, item->tag);
        collection_write_be32(record + 4, (UInt32)item->id);
        collection_write_be32(record + 8, (UInt32)item->attributes);
        collection_write_be32(record + 12, item->size > 0 ? (UInt32)(nextDataOffset + 4) : 0);
        if (item->size > 0)
            nextDataOffset += 4 + collection_align2((size_t)item->size);
    }
    if (dataSize) {
        size_t dataOffset = headerSize + 4;
        collection_write_be32(bytes + headerSize, (UInt32)dataSize);
        for (SInt32 i = 0; i < object->count; i++) {
            struct collection_item *item = &object->items[i];
            if (item->size <= 0)
                continue;
            collection_write_be32(bytes + dataOffset, (UInt32)item->size);
            memcpy(bytes + dataOffset + 4, item->data, (size_t)item->size);
            dataOffset += 4 + collection_align2((size_t)item->size);
        }
    }
    HUnlock(flattened);
    pthread_mutex_unlock(&object->lock);
    return noErr;
}

OSErr
UnflattenCollectionFromHdl(Collection collection, Handle flattened)
{
    if (!collection_get(collection) || !flattened || !*flattened)
        return paramErr;
    Size length = GetHandleSize(flattened);
    if (length < 12)
        return paramErr;
    HLock(flattened);
    const UInt8 *bytes = (const UInt8 *)*flattened;
    UInt32 version = collection_read_be32(bytes);
    UInt32 defaultAttributes = collection_read_be32(bytes + 4);
    UInt32 itemCount = collection_read_be32(bytes + 8);
    if (version != 0x00010000 || itemCount > (UInt32)((length - 12) / 16)) {
        HUnlock(flattened);
        return paramErr;
    }
    size_t recordsEnd = 12 + (size_t)itemCount * 16;
    size_t dataOffset = recordsEnd;
    UInt32 dataSize = 0;
    if (recordsEnd < (size_t)length) {
        if ((size_t)length - recordsEnd < 4) {
            HUnlock(flattened);
            return paramErr;
        }
        dataSize = collection_read_be32(bytes + recordsEnd);
        dataOffset += 4;
        if (dataSize > (size_t)length - dataOffset) {
            HUnlock(flattened);
            return paramErr;
        }
    }

    Collection parsed = NewCollection();
    if (!parsed) {
        HUnlock(flattened);
        return memFullErr;
    }
    OSErr status = noErr;
    struct OpaqueCollection *parsedObject = collection_get(parsed);
    pthread_mutex_lock(&parsedObject->lock);
    parsedObject->defaultAttributes = (SInt32)defaultAttributes;
    for (UInt32 i = 0; i < itemCount; i++) {
        const UInt8 *record = bytes + 12 + (size_t)i * 16;
        CollectionTag tag = (CollectionTag)collection_read_be32(record);
        SInt32 id = (SInt32)collection_read_be32(record + 4);
        SInt32 attributes = (SInt32)collection_read_be32(record + 8);
        UInt32 itemOffset = collection_read_be32(record + 12);
        UInt32 itemSize = 0;
        const UInt8 *itemData = NULL;
        if (itemOffset) {
            if (itemOffset < 4 || itemOffset > dataSize) {
                status = paramErr;
                break;
            }
            size_t sizePosition = dataOffset + itemOffset - 4;
            if (sizePosition + 4 > (size_t)length) {
                status = paramErr;
                break;
            }
            itemSize = collection_read_be32(bytes + sizePosition);
            if (itemSize > (size_t)length - sizePosition - 4 || itemOffset + itemSize > dataSize) {
                status = paramErr;
                break;
            }
            itemData = bytes + sizePosition + 4;
        }
        if (itemSize > INT32_MAX || !collection_reserve(parsedObject, parsedObject->count + 1)) {
            status = memFullErr;
            break;
        }
        void *copy = malloc(itemSize ? (size_t)itemSize : 1);
        if (!copy) {
            status = memFullErr;
            break;
        }
        if (itemSize)
            memcpy(copy, itemData, itemSize);
        parsedObject->items[parsedObject->count++] = (struct collection_item){tag, id, attributes,
                                                                              (SInt32)itemSize, copy};
    }
    pthread_mutex_unlock(&parsedObject->lock);
    HUnlock(flattened);
    if (status == noErr && !CopyCollection(parsed, collection))
        status = memFullErr;
    if (status == noErr) {
        struct OpaqueCollection *destination = collection_get(collection);
        pthread_mutex_lock(&destination->lock);
        destination->defaultAttributes = (SInt32)defaultAttributes;
        pthread_mutex_unlock(&destination->lock);
    }
    DisposeCollection(parsed);
    return status;
}

static OSErr
collection_flatten_matching(Collection collection, CollectionFlattenUPP callback, void *refCon,
                            SInt32 whichAttributes, SInt32 matchingAttributes)
{
    struct OpaqueCollection *source = collection_get(collection);
    if (!source || !callback)
        return paramErr;
    Collection snapshot = NewCollection();
    if (!snapshot)
        return memFullErr;
    struct OpaqueCollection *copy = collection_get(snapshot);
    pthread_mutex_lock(&source->lock);
    copy->defaultAttributes = source->defaultAttributes;
    OSErr status = noErr;
    for (SInt32 i = 0; i < source->count; i++) {
        struct collection_item *item = &source->items[i];
        if ((item->attributes & whichAttributes) != matchingAttributes)
            continue;
        status = collection_add(snapshot, item->tag, item->id, item->size, item->data);
        if (status)
            break;
        SInt32 copiedIndex = collection_find(copy, item->tag, item->id);
        copy->items[copiedIndex].attributes = item->attributes;
    }
    pthread_mutex_unlock(&source->lock);
    if (status != noErr) {
        DisposeCollection(snapshot);
        return status;
    }

    Handle flattened = NewHandle(0);
    if (!flattened) {
        DisposeCollection(snapshot);
        return MemError();
    }
    status = FlattenCollectionToHdl(snapshot, flattened);
    if (status != noErr) {
        DisposeHandle(flattened);
        DisposeCollection(snapshot);
        return status;
    }
    Size length = GetHandleSize(flattened);
    SInt32 itemCount = CountCollectionItems(snapshot);
    size_t headerSize = 12;
    size_t recordsSize = (size_t)itemCount * 16;
    size_t blockSizeField = headerSize + recordsSize;
    HLock(flattened);
    UInt8 *bytes = (UInt8 *)*flattened;
    status = callback((SInt32)headerSize, bytes, refCon);
    if (status == noErr && recordsSize)
        status = callback((SInt32)recordsSize, bytes + headerSize, refCon);
    if (status == noErr && (size_t)length > blockSizeField) {
        status = callback(4, bytes + blockSizeField, refCon);
        if (status == noErr && (size_t)length > blockSizeField + 4)
            status = callback((SInt32)((size_t)length - blockSizeField - 4), bytes + blockSizeField + 4, refCon);
    }
    HUnlock(flattened);
    DisposeHandle(flattened);
    DisposeCollection(snapshot);
    return status;
}

OSErr
FlattenCollection(Collection collection, CollectionFlattenUPP callback, void *refCon)
{
    return collection_flatten_matching(collection, callback, refCon, 0, 0);
}

OSErr
FlattenPartialCollection(Collection collection, CollectionFlattenUPP callback, void *refCon,
                          SInt32 whichAttributes, SInt32 matchingAttributes)
{
    return collection_flatten_matching(collection, callback, refCon, whichAttributes, matchingAttributes);
}

Collection
GetNewCollection(SInt16 collectionID)
{
    Handle resource = GetResource('cltn', collectionID);
    if (!resource)
        return NULL;
    Collection collection = NewCollection();
    if (!collection)
        return NULL;
    if (UnflattenCollectionFromHdl(collection, resource) != noErr) {
        DisposeCollection(collection);
        return NULL;
    }
    return collection;
}

OSErr
AddCollectionItemHdl(Collection c, CollectionTag tag, SInt32 id, Handle itemData)
{
    if (!itemData || !*itemData)
        return paramErr;
    Size size = GetHandleSize(itemData);
    return AddCollectionItem(c, tag, id, size, *itemData);
}

OSErr
GetCollectionItemHdl(Collection c, CollectionTag tag, SInt32 id, Handle itemData)
{
    if (!itemData)
        return paramErr;
    SInt32 size = 0;
    OSErr error = GetCollectionItem(c, tag, id, &size, NULL);
    if (error)
        return error;
    SetHandleSize(itemData, size);
    if (MemError())
        return MemError();
    return GetCollectionItem(c, tag, id, &size, *itemData);
}

OSErr
ReplaceIndexedCollectionItemHdl(Collection c, SInt32 itemIndex, Handle itemData)
{
    if (!itemData || !*itemData)
        return paramErr;
    Size size = GetHandleSize(itemData);
    return ReplaceIndexedCollectionItem(c, itemIndex, size, *itemData);
}

OSErr
GetIndexedCollectionItemHdl(Collection c, SInt32 itemIndex, Handle itemData)
{
    if (!itemData)
        return paramErr;
    SInt32 size = 0;
    OSErr error = GetIndexedCollectionItem(c, itemIndex, &size, NULL);
    if (error)
        return error;
    SetHandleSize(itemData, size);
    if (MemError())
        return MemError();
    return GetIndexedCollectionItem(c, itemIndex, &size, *itemData);
}

CollectionFlattenUPP
NewCollectionFlattenUPP(CollectionFlattenProcPtr userRoutine)
{
    return userRoutine;
}

CollectionExceptionUPP
NewCollectionExceptionUPP(CollectionExceptionProcPtr userRoutine)
{
    return userRoutine;
}

void DisposeCollectionFlattenUPP(CollectionFlattenUPP userUPP) { (void)userUPP; }
void DisposeCollectionExceptionUPP(CollectionExceptionUPP userUPP) { (void)userUPP; }

OSErr
InvokeCollectionFlattenUPP(SInt32 size, void *data, void *refCon, CollectionFlattenUPP userUPP)
{
    return userUPP ? userUPP(size, data, refCon) : paramErr;
}

OSErr
InvokeCollectionExceptionUPP(Collection c, OSErr status, CollectionExceptionUPP userUPP)
{
    return userUPP ? userUPP(c, status) : paramErr;
}
