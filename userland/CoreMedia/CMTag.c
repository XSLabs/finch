/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CoreMedia's tags, tag collections and tagged buffer groups, Finch's. A tag is a
 * category and a typed value; a collection keeps its tags sorted (by category, type,
 * then value) without duplicates, as Apple's does, and reads and writes them as a
 * dictionary or as data laid out as Apple's ('tgco' holding 'tgin' and 'tgli'). A
 * tagged buffer group pairs tag collections with pixel or sample buffers.
 */
#include "CMInternal.h"
#include <CoreVideo/CoreVideo.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

/* --- tags --- */

const CMTag kCMTagInvalid = {0, kCMTagDataType_Invalid, 0};
const CMTag kCMTagMediaTypeVideo = {kCMTagCategory_MediaType, kCMTagDataType_OSType, kCMMediaType_Video};
const CMTag kCMTagMediaSubTypeMebx = {kCMTagCategory_MediaSubType, kCMTagDataType_OSType, kCMMetadataFormatType_Boxed};
const CMTag kCMTagMediaTypeAudio = {kCMTagCategory_MediaType, kCMTagDataType_OSType, kCMMediaType_Audio};
const CMTag kCMTagMediaTypeMetadata = {kCMTagCategory_MediaType, kCMTagDataType_OSType, kCMMediaType_Metadata};
const CMTag kCMTagStereoLeftEye = {kCMTagCategory_StereoView, kCMTagDataType_Flags, kCMStereoView_LeftEye};
const CMTag kCMTagStereoRightEye = {kCMTagCategory_StereoView, kCMTagDataType_Flags, kCMStereoView_RightEye};
const CMTag kCMTagStereoLeftAndRightEye = {kCMTagCategory_StereoView, kCMTagDataType_Flags, kCMStereoView_LeftEye | kCMStereoView_RightEye};
const CMTag kCMTagStereoNone = {kCMTagCategory_StereoView, kCMTagDataType_Flags, kCMStereoView_None};
const CMTag kCMTagStereoInterpretationOrderReversed = {kCMTagCategory_StereoViewInterpretation, kCMTagDataType_Flags,
                                                       kCMStereoViewInterpretation_StereoOrderReversed};
const CMTag kCMTagProjectionTypeRectangular = {kCMTagCategory_ProjectionType, kCMTagDataType_OSType, kCMProjectionType_Rectangular};
const CMTag kCMTagProjectionTypeEquirectangular = {kCMTagCategory_ProjectionType, kCMTagDataType_OSType, kCMProjectionType_Equirectangular};
const CMTag kCMTagProjectionTypeHalfEquirectangular = {kCMTagCategory_ProjectionType, kCMTagDataType_OSType, kCMProjectionType_HalfEquirectangular};
const CMTag kCMTagProjectionTypeFisheye = {kCMTagCategory_ProjectionType, kCMTagDataType_OSType, kCMProjectionType_Fisheye};
const CMTag kCMTagProjectionTypeParametricImmersive = {kCMTagCategory_ProjectionType, kCMTagDataType_OSType, kCMProjectionType_ParametricImmersive};
const CMTag kCMTagPackingTypeNone = {kCMTagCategory_PackingType, kCMTagDataType_OSType, kCMPackingType_None};
const CMTag kCMTagPackingTypeSideBySide = {kCMTagCategory_PackingType, kCMTagDataType_OSType, kCMPackingType_SideBySide};
const CMTag kCMTagPackingTypeOverUnder = {kCMTagCategory_PackingType, kCMTagDataType_OSType, kCMPackingType_OverUnder};

CMTagDataType
CMTagGetValueDataType(CMTag tag)
{
    return tag.dataType;
}

Boolean
CMTagHasSInt64Value(CMTag tag)
{
    return tag.dataType == kCMTagDataType_SInt64;
}

/* (the getters read the value whatever its type, as Apple's do) */
int64_t
CMTagGetSInt64Value(CMTag tag)
{
    return (int64_t)tag.value;
}

Boolean
CMTagHasFloat64Value(CMTag tag)
{
    return tag.dataType == kCMTagDataType_Float64;
}

Float64
CMTagGetFloat64Value(CMTag tag)
{
    Float64 f;
    memcpy(&f, &tag.value, sizeof f);
    return f;
}

Boolean
CMTagHasOSTypeValue(CMTag tag)
{
    return tag.dataType == kCMTagDataType_OSType;
}

OSType
CMTagGetOSTypeValue(CMTag tag)
{
    return tag.dataType == kCMTagDataType_Float64 ? 0 : (OSType)tag.value;
}

Boolean
CMTagHasFlagsValue(CMTag tag)
{
    return tag.dataType == kCMTagDataType_Flags;
}

uint64_t
CMTagGetFlagsValue(CMTag tag)
{
    return tag.value;
}

CMTag
CMTagMakeWithSInt64Value(CMTagCategory category, int64_t value)
{
    return (CMTag){category, kCMTagDataType_SInt64, (CMTagValue)value};
}

CMTag
CMTagMakeWithFloat64Value(CMTagCategory category, Float64 value)
{
    CMTag t = {category, kCMTagDataType_Float64, 0};
    memcpy(&t.value, &value, sizeof value);
    return t;
}

CMTag
CMTagMakeWithOSTypeValue(CMTagCategory category, OSType value)
{
    return (CMTag){category, kCMTagDataType_OSType, value};
}

CMTag
CMTagMakeWithFlagsValue(CMTagCategory category, uint64_t flagsForTag)
{
    return (CMTag){category, kCMTagDataType_Flags, flagsForTag};
}

Boolean
CMTagEqualToTag(CMTag tag1, CMTag tag2)
{
    return tag1.category == tag2.category && tag1.dataType == tag2.dataType && tag1.value == tag2.value;
}

/* Category, then type, then the value's bits, unsigned (so -1 comes after 1, as with Apple's). */
CFComparisonResult
CMTagCompare(CMTag tag1, CMTag tag2)
{
    if (tag1.category != tag2.category)
        return tag1.category < tag2.category ? kCFCompareLessThan : kCFCompareGreaterThan;
    if (tag1.dataType != tag2.dataType)
        return tag1.dataType < tag2.dataType ? kCFCompareLessThan : kCFCompareGreaterThan;
    return tag1.value < tag2.value ? kCFCompareLessThan : tag1.value > tag2.value ? kCFCompareGreaterThan : kCFCompareEqualTo;
}

CFHashCode
CMTagHash(CMTag tag)
{
    uint64_t h = 1469598103934665603ull;
    uint8_t bytes[16];
    memcpy(bytes, &tag, sizeof bytes);
    for (int i = 0; i < 16; i++)
        h = (h ^ bytes[i]) * 1099511628211ull;
    return (CFHashCode)h;
}

static void
append_code(CFMutableStringRef s, uint32_t c)
{
    char b[5] = {(char)(c >> 24), (char)(c >> 16), (char)(c >> 8), (char)c, 0};
    int start = 0;
    while (start < 4 && !b[start])
        start++;
    CFStringAppendFormat(s, NULL, CFSTR("'%s'"), b + start);
}

static void
append_tag(CFMutableStringRef s, CMTag tag)
{
    CFStringAppend(s, CFSTR("{category:"));
    append_code(s, tag.category);
    switch (tag.dataType) {
    case kCMTagDataType_SInt64: CFStringAppendFormat(s, NULL, CFSTR(" value:%lld <int64>}"), (long long)tag.value); break;
    case kCMTagDataType_Float64: CFStringAppendFormat(s, NULL, CFSTR(" value:%.2f <Flt64>}"), CMTagGetFloat64Value(tag)); break;
    case kCMTagDataType_OSType:
        CFStringAppend(s, CFSTR(" value:"));
        append_code(s, (uint32_t)tag.value);
        CFStringAppend(s, CFSTR(" <OSType>}"));
        break;
    case kCMTagDataType_Flags: CFStringAppendFormat(s, NULL, CFSTR(" value:0x%llx <flags>}"), (unsigned long long)tag.value); break;
    default: CFStringAppend(s, CFSTR("{INVALID}"));
    }
}

CFStringRef
CMTagCopyDescription(CFAllocatorRef allocator, CMTag tag)
{
    CFMutableStringRef s = CFStringCreateMutable(allocator, 0);
    append_tag(s, tag);
    return s;
}

static void
set_number(CFMutableDictionaryRef d, CFStringRef key, long long v)
{
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberLongLongType, &v);
    CFDictionarySetValue(d, key, n);
    CFRelease(n);
}

CFDictionaryRef
CMTagCopyAsDictionary(CMTag tag, CFAllocatorRef allocator)
{
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(allocator, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    set_number(d, kCMTagCategoryKey, tag.category);
    set_number(d, kCMTagDataTypeKey, tag.dataType);
    set_number(d, kCMTagValueKey, (long long)tag.value);
    return d;
}

static bool
get_number(CFDictionaryRef d, CFStringRef key, long long *out)
{
    CFTypeRef v = d ? CFDictionaryGetValue(d, key) : NULL;
    return v && CFGetTypeID(v) == CFNumberGetTypeID() && CFNumberGetValue(v, kCFNumberLongLongType, out);
}

CMTag
CMTagMakeFromDictionary(CFDictionaryRef dict)
{
    long long c, t, v;
    if (!get_number(dict, kCMTagCategoryKey, &c) || !get_number(dict, kCMTagDataTypeKey, &t) || !get_number(dict, kCMTagValueKey, &v))
        return kCMTagInvalid;
    return (CMTag){(CMTagCategory)c, (CMTagDataType)t, (CMTagValue)v};
}

/* --- collections --- */

struct OpaqueCMTagCollection {
    CFRuntimeBase base;
    bool mutable_;
    CMTag *tags;
    CMItemCount count, capacity;
};

typedef struct OpaqueCMTagCollection *TagSet;

static void
collection_finalize(CFTypeRef cf)
{
    free(((TagSet)cf)->tags);
}

static Boolean
collection_equal(CFTypeRef a, CFTypeRef b)
{
    TagSet x = (TagSet)a, y = (TagSet)b;
    return x->count == y->count && (!x->count || !memcmp(x->tags, y->tags, sizeof(CMTag) * (size_t)x->count));
}

static CFHashCode
collection_hash(CFTypeRef cf)
{
    TagSet c = (TagSet)cf;
    CFHashCode h = (CFHashCode)c->count;
    for (CMItemCount i = 0; i < c->count; i++)
        h = h * 31 + CMTagHash(c->tags[i]);
    return h;
}

static CFStringRef
collection_description(CFTypeRef cf)
{
    TagSet c = (TagSet)cf;
    CFMutableStringRef s = CFStringCreateMutable(NULL, 0);
    CFStringAppend(s, c->mutable_ ? CFSTR("CMMutableTagCollection{\n") : CFSTR("CMTagCollection{\n"));
    for (CMItemCount i = 0; i < c->count; i++) {
        append_tag(s, c->tags[i]);
        CFStringAppend(s, CFSTR("\n"));
    }
    CFStringAppend(s, CFSTR("}"));
    return s;
}

CM_DEFINE_TYPE(CMTagCollectionGetTypeID, "CMTagCollection", collection_finalize, collection_equal, collection_hash, collection_description)

static TagSet
new_collection(CFAllocatorRef allocator, bool mutable_)
{
    TagSet c = (TagSet)cm_create(allocator, CMTagCollectionGetTypeID(), sizeof(struct OpaqueCMTagCollection));
    if (c)
        c->mutable_ = mutable_;
    return c;
}

/* Puts the tag in its place, unless it's there already. */
static bool
insert(TagSet c, CMTag tag)
{
    CMItemCount lo = 0, hi = c->count;
    while (lo < hi) {
        CMItemCount mid = (lo + hi) / 2;
        CFComparisonResult r = CMTagCompare(c->tags[mid], tag);
        if (r == kCFCompareEqualTo)
            return true;
        if (r == kCFCompareLessThan)
            lo = mid + 1;
        else
            hi = mid;
    }
    if (c->count == c->capacity) {
        CMItemCount cap = c->capacity ? c->capacity * 2 : 4;
        CMTag *t = realloc(c->tags, sizeof *t * (size_t)cap);
        if (!t)
            return false;
        c->tags = t, c->capacity = cap;
    }
    memmove(c->tags + lo + 1, c->tags + lo, sizeof(CMTag) * (size_t)(c->count - lo));
    c->tags[lo] = tag;
    c->count++;
    return true;
}

static CMItemCount
find(CMTagCollectionRef c, CMTag tag)
{
    for (CMItemCount i = 0; i < c->count; i++)
        if (CMTagEqualToTag(c->tags[i], tag))
            return i;
    return -1;
}

OSStatus
CMTagCollectionCreate(CFAllocatorRef allocator, const CMTag *tags, CMItemCount tagCount, CMTagCollectionRef *newCollectionOut)
{
    if (!newCollectionOut || (tagCount && !tags) || tagCount < 0)
        return kCMTagCollectionError_ParamErr;
    TagSet c = new_collection(allocator, false);
    if (!c)
        return kCMTagCollectionError_AllocationFailed;
    for (CMItemCount i = 0; i < tagCount; i++)
        insert(c, tags[i]);
    *newCollectionOut = c;
    return noErr;
}

OSStatus
CMTagCollectionCreateMutable(CFAllocatorRef allocator, CFIndex capacity, CMMutableTagCollectionRef *newMutableCollectionOut)
{
    if (!newMutableCollectionOut || capacity < 0)
        return kCMTagCollectionError_ParamErr;
    TagSet c = new_collection(allocator, true);
    if (!c)
        return kCMTagCollectionError_AllocationFailed;
    *newMutableCollectionOut = c;
    return noErr;
}

static OSStatus
copy_collection(CMTagCollectionRef from, CFAllocatorRef allocator, bool mutable_, CMTagCollectionRef *out)
{
    if (!from || !out)
        return kCMTagCollectionError_ParamErr;
    TagSet c = new_collection(allocator, mutable_);
    if (!c)
        return kCMTagCollectionError_AllocationFailed;
    if (from->count) {
        c->tags = malloc(sizeof(CMTag) * (size_t)from->count);
        memcpy(c->tags, from->tags, sizeof(CMTag) * (size_t)from->count);
        c->count = c->capacity = from->count;
    }
    *out = c;
    return noErr;
}

OSStatus
CMTagCollectionCreateCopy(CMTagCollectionRef tagCollection, CFAllocatorRef allocator, CMTagCollectionRef *newCollectionCopyOut)
{
    return copy_collection(tagCollection, allocator, false, newCollectionCopyOut);
}

OSStatus
CMTagCollectionCreateMutableCopy(CMTagCollectionRef tagCollection, CFAllocatorRef allocator, CMMutableTagCollectionRef *newMutableCollectionCopyOut)
{
    return copy_collection(tagCollection, allocator, true, (CMTagCollectionRef *)newMutableCollectionCopyOut);
}

CFStringRef
CMTagCollectionCopyDescription(CFAllocatorRef allocator, CMTagCollectionRef tagCollection)
{
    return tagCollection ? collection_description(tagCollection) : NULL;
}

CMItemCount
CMTagCollectionGetCount(CMTagCollectionRef tagCollection)
{
    return tagCollection ? tagCollection->count : 0;
}

Boolean
CMTagCollectionContainsTag(CMTagCollectionRef tagCollection, CMTag tag)
{
    return tagCollection && find(tagCollection, tag) >= 0;
}

Boolean
CMTagCollectionContainsTagsOfCollection(CMTagCollectionRef tagCollection, CMTagCollectionRef containedTagCollection)
{
    if (!tagCollection || !containedTagCollection)
        return false;
    return CMTagCollectionContainsSpecifiedTags(tagCollection, containedTagCollection->tags, containedTagCollection->count);
}

Boolean
CMTagCollectionContainsSpecifiedTags(CMTagCollectionRef tagCollection, const CMTag *containedTags, CMItemCount containedTagCount)
{
    if (!tagCollection)
        return false;
    for (CMItemCount i = 0; i < containedTagCount; i++)
        if (find(tagCollection, containedTags[i]) < 0)
            return false;
    return true;
}

Boolean
CMTagCollectionContainsCategory(CMTagCollectionRef tagCollection, CMTagCategory category)
{
    return CMTagCollectionGetCountOfCategory(tagCollection, category) > 0;
}

CMItemCount
CMTagCollectionGetCountOfCategory(CMTagCollectionRef tagCollection, CMTagCategory category)
{
    CMItemCount n = 0;
    for (CMItemCount i = 0; tagCollection && i < tagCollection->count; i++)
        n += tagCollection->tags[i].category == category;
    return n;
}

/* Copies the tags that pass into the buffer, as many as fit (ExhaustedBufferSize past that). */
static OSStatus
copy_out(CMTagCollectionRef c, CMTag *buffer, CMItemCount bufferCount, CMItemCount *copied, Boolean (*pass)(CMTag, void *), void *context)
{
    if (!c || !buffer)
        return kCMTagCollectionError_ParamErr;
    CMItemCount n = 0;
    OSStatus e = noErr;
    for (CMItemCount i = 0; i < c->count; i++) {
        if (pass && !pass(c->tags[i], context))
            continue;
        if (n == bufferCount) {
            e = kCMTagCollectionError_ExhaustedBufferSize;
            break;
        }
        buffer[n++] = c->tags[i];
    }
    if (copied)
        *copied = n;
    return e;
}

OSStatus
CMTagCollectionGetTags(CMTagCollectionRef tagCollection, CMTag *tagBuffer, CMItemCount tagBufferCount, CMItemCount *numberOfTagsCopied)
{
    return copy_out(tagCollection, tagBuffer, tagBufferCount, numberOfTagsCopied, NULL, NULL);
}

static Boolean
of_category(CMTag tag, void *context)
{
    return tag.category == *(CMTagCategory *)context;
}

OSStatus
CMTagCollectionGetTagsWithCategory(CMTagCollectionRef tagCollection, CMTagCategory category, CMTag *tagBuffer, CMItemCount tagBufferCount,
                                   CMItemCount *numberOfTagsCopied)
{
    return copy_out(tagCollection, tagBuffer, tagBufferCount, numberOfTagsCopied, of_category, &category);
}

CMItemCount
CMTagCollectionCountTagsWithFilterFunction(CMTagCollectionRef tagCollection, CMTagCollectionTagFilterFunction filterApplier, void *context)
{
    CMItemCount n = 0;
    for (CMItemCount i = 0; tagCollection && filterApplier && i < tagCollection->count; i++)
        n += filterApplier(tagCollection->tags[i], context) ? 1 : 0;
    return n;
}

OSStatus
CMTagCollectionGetTagsWithFilterFunction(CMTagCollectionRef tagCollection, CMTag *tagBuffer, CMItemCount tagBufferCount,
                                         CMItemCount *numberOfTagsCopied, CMTagCollectionTagFilterFunction filter, void *context)
{
    if (!filter)
        return kCMTagCollectionError_ParamErr;
    return copy_out(tagCollection, tagBuffer, tagBufferCount, numberOfTagsCopied, filter, context);
}

OSStatus
CMTagCollectionCopyTagsOfCategories(CFAllocatorRef allocator, CMTagCollectionRef tagCollection, const CMTagCategory *categories,
                                    CMItemCount categoriesCount, CMTagCollectionRef *collectionWithTagsOfCategories)
{
    if (!tagCollection || !collectionWithTagsOfCategories || (categoriesCount && !categories))
        return kCMTagCollectionError_ParamErr;
    TagSet c = new_collection(allocator, true);
    for (CMItemCount i = 0; i < tagCollection->count; i++)
        for (CMItemCount k = 0; k < categoriesCount; k++)
            if (tagCollection->tags[i].category == categories[k]) {
                insert(c, tagCollection->tags[i]);
                break;
            }
    *collectionWithTagsOfCategories = c;
    return noErr;
}

void
CMTagCollectionApply(CMTagCollectionRef tagCollection, CMTagCollectionApplierFunction applier, void *context)
{
    for (CMItemCount i = 0; tagCollection && applier && i < tagCollection->count; i++)
        applier(tagCollection->tags[i], context);
}

CMTag
CMTagCollectionApplyUntil(CMTagCollectionRef tagCollection, CMTagCollectionTagFilterFunction applier, void *context)
{
    for (CMItemCount i = 0; tagCollection && applier && i < tagCollection->count; i++)
        if (applier(tagCollection->tags[i], context))
            return tagCollection->tags[i];
    return kCMTagInvalid;
}

Boolean
CMTagCollectionIsEmpty(CMTagCollectionRef tagCollection)
{
    return !tagCollection || !tagCollection->count;
}

/* The set operations: each tag of either, kept by what the operation keeps. */
static OSStatus
combine(CMTagCollectionRef a, CMTagCollectionRef b, bool inA, bool inB, bool inBoth, CMTagCollectionRef *out)
{
    if (!a || !b || !out)
        return kCMTagCollectionError_ParamErr;
    TagSet c = new_collection(NULL, true);
    for (CMItemCount i = 0; i < a->count; i++)
        if (find(b, a->tags[i]) >= 0 ? inBoth : inA)
            insert(c, a->tags[i]);
    for (CMItemCount i = 0; i < b->count; i++)
        if (find(a, b->tags[i]) < 0 && inB)
            insert(c, b->tags[i]);
    *out = c;
    return noErr;
}

OSStatus
CMTagCollectionCreateIntersection(CMTagCollectionRef tagCollection1, CMTagCollectionRef tagCollection2, CMTagCollectionRef *tagCollectionOut)
{
    return combine(tagCollection1, tagCollection2, false, false, true, tagCollectionOut);
}

OSStatus
CMTagCollectionCreateUnion(CMTagCollectionRef tagCollection1, CMTagCollectionRef tagCollection2, CMTagCollectionRef *tagCollectionOut)
{
    return combine(tagCollection1, tagCollection2, true, true, true, tagCollectionOut);
}

OSStatus
CMTagCollectionCreateDifference(CMTagCollectionRef tagCollectionMinuend, CMTagCollectionRef tagCollectionSubtrahend, CMTagCollectionRef *tagCollectionOut)
{
    return combine(tagCollectionMinuend, tagCollectionSubtrahend, true, false, false, tagCollectionOut);
}

OSStatus
CMTagCollectionCreateExclusiveOr(CMTagCollectionRef tagCollection1, CMTagCollectionRef tagCollection2, CMTagCollectionRef *tagCollectionOut)
{
    return combine(tagCollection1, tagCollection2, true, true, false, tagCollectionOut);
}

OSStatus
CMTagCollectionAddTag(CMMutableTagCollectionRef tagCollection, CMTag tagToAdd)
{
    if (!tagCollection || !tagCollection->mutable_)
        return kCMTagCollectionError_ParamErr;
    return insert((TagSet)tagCollection, tagToAdd) ? noErr : kCMTagCollectionError_AllocationFailed;
}

OSStatus
CMTagCollectionRemoveTag(CMMutableTagCollectionRef tagCollection, CMTag tagToRemove)
{
    if (!tagCollection || !tagCollection->mutable_)
        return kCMTagCollectionError_ParamErr;
    CMItemCount i = find(tagCollection, tagToRemove);
    if (i < 0)
        return kCMTagCollectionError_TagNotFound;
    TagSet c = (TagSet)tagCollection;
    memmove(c->tags + i, c->tags + i + 1, sizeof(CMTag) * (size_t)(c->count - i - 1));
    c->count--;
    return noErr;
}

OSStatus
CMTagCollectionRemoveAllTags(CMMutableTagCollectionRef tagCollection)
{
    if (!tagCollection || !tagCollection->mutable_)
        return kCMTagCollectionError_ParamErr;
    ((TagSet)tagCollection)->count = 0;
    return noErr;
}

OSStatus
CMTagCollectionRemoveAllTagsOfCategory(CMMutableTagCollectionRef tagCollection, CMTagCategory category)
{
    if (!tagCollection || !tagCollection->mutable_)
        return kCMTagCollectionError_ParamErr;
    TagSet c = (TagSet)tagCollection;
    CMItemCount kept = 0;
    for (CMItemCount i = 0; i < c->count; i++)
        if (c->tags[i].category != category)
            c->tags[kept++] = c->tags[i];
    c->count = kept;
    return noErr;
}

OSStatus
CMTagCollectionAddTagsFromCollection(CMMutableTagCollectionRef tagCollection, CMTagCollectionRef collectionWithTagsToAdd)
{
    if (!collectionWithTagsToAdd)
        return kCMTagCollectionError_ParamErr;
    return CMTagCollectionAddTagsFromArray(tagCollection, collectionWithTagsToAdd->tags, collectionWithTagsToAdd->count);
}

OSStatus
CMTagCollectionAddTagsFromArray(CMMutableTagCollectionRef tagCollection, CMTag *tags, CMItemCount tagCount)
{
    if (!tagCollection || !tagCollection->mutable_ || (tagCount && !tags))
        return kCMTagCollectionError_ParamErr;
    for (CMItemCount i = 0; i < tagCount; i++)
        if (!insert((TagSet)tagCollection, tags[i]))
            return kCMTagCollectionError_AllocationFailed;
    return noErr;
}

CFDictionaryRef
CMTagCollectionCopyAsDictionary(CMTagCollectionRef tagCollection, CFAllocatorRef allocator)
{
    if (!tagCollection)
        return NULL;
    CFMutableArrayRef tags = CFArrayCreateMutable(allocator, tagCollection->count, &kCFTypeArrayCallBacks);
    for (CMItemCount i = 0; i < tagCollection->count; i++) {
        CFDictionaryRef d = CMTagCopyAsDictionary(tagCollection->tags[i], allocator);
        CFArrayAppendValue(tags, d);
        CFRelease(d);
    }
    CFDictionaryRef d = CFDictionaryCreate(allocator, (const void **)&kCMTagCollectionTagsArrayKey, (const void **)&tags, 1,
                                           &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(tags);
    return d;
}

OSStatus
CMTagCollectionCreateFromDictionary(CFDictionaryRef dict, CFAllocatorRef allocator, CMTagCollectionRef *newCollectionOut)
{
    if (!dict || !newCollectionOut)
        return kCMTagCollectionError_ParamErr;
    CFArrayRef tags = CFDictionaryGetValue(dict, kCMTagCollectionTagsArrayKey);
    if (!tags || CFGetTypeID(tags) != CFArrayGetTypeID())
        return kCMTagCollectionError_InvalidTagCollectionDictionary;
    TagSet c = new_collection(allocator, false);
    for (CFIndex i = 0; i < CFArrayGetCount(tags); i++) {
        CFDictionaryRef t = CFArrayGetValueAtIndex(tags, i);
        if (CFGetTypeID(t) != CFDictionaryGetTypeID()) {
            CFRelease(c);
            return kCMTagCollectionError_InvalidTagCollectionDictionary;
        }
        insert(c, CMTagMakeFromDictionary(t));
    }
    *newCollectionOut = c;
    return noErr;
}

static void
put32(UInt8 *p, uint32_t v)
{
    p[0] = (UInt8)(v >> 24), p[1] = (UInt8)(v >> 16), p[2] = (UInt8)(v >> 8), p[3] = (UInt8)v;
}

static uint32_t
get32(const UInt8 *p)
{
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

/* As Apple's writes it: 'tgco' { 'tgin' {version 0, "tag coll"}, 'tgli' {version 0, count, tags} },
   each tag its category, type and value, big-endian. */
CFDataRef
CMTagCollectionCopyAsData(CMTagCollectionRef tagCollection, CFAllocatorRef allocator)
{
    if (!tagCollection)
        return NULL;
    size_t list = 16 + 16 * (size_t)tagCollection->count, total = 8 + 20 + list;
    UInt8 *b = calloc(1, total), *p = b;
    put32(p, (uint32_t)total), memcpy(p + 4, "tgco", 4), p += 8;
    put32(p, 20), memcpy(p + 4, "tgin", 4), memcpy(p + 12, "tag coll", 8), p += 20;
    put32(p, (uint32_t)list), memcpy(p + 4, "tgli", 4), put32(p + 12, (uint32_t)tagCollection->count), p += 16;
    for (CMItemCount i = 0; i < tagCollection->count; i++, p += 16) {
        CMTag t = tagCollection->tags[i];
        put32(p, t.category);
        put32(p + 4, t.dataType);
        put32(p + 8, (uint32_t)(t.value >> 32));
        put32(p + 12, (uint32_t)t.value);
    }
    CFDataRef d = CFDataCreate(allocator, b, (CFIndex)total);
    free(b);
    return d;
}

OSStatus
CMTagCollectionCreateFromData(CFDataRef data, CFAllocatorRef allocator, CMTagCollectionRef *newCollectionOut)
{
    if (!data || !newCollectionOut)
        return kCMTagCollectionError_ParamErr;
    const UInt8 *b = CFDataGetBytePtr(data);
    size_t n = (size_t)CFDataGetLength(data);
    if (n < 8 || get32(b) != n || memcmp(b + 4, "tgco", 4))
        return -12894; /* (what Apple's gives for data that isn't a tag collection's atom) */
    /* (the 'tgli' among the container's atoms) */
    for (size_t at = 8; at + 8 <= n;) {
        size_t size = get32(b + at);
        if (size < 8 || at + size > n)
            return kCMTagCollectionError_InvalidTagCollectionData;
        if (!memcmp(b + at + 4, "tgli", 4)) {
            if (size < 16)
                return kCMTagCollectionError_InvalidTagCollectionData;
            if (get32(b + at + 8))
                return kCMTagCollectionError_InvalidTagCollectionDataVersion;
            size_t count = get32(b + at + 12);
            if (16 + 16 * count > size)
                return kCMTagCollectionError_InvalidTagCollectionData;
            TagSet c = new_collection(allocator, false);
            for (size_t i = 0; i < count; i++) {
                const UInt8 *t = b + at + 16 + 16 * i;
                insert(c, (CMTag){get32(t), get32(t + 4), (uint64_t)get32(t + 8) << 32 | get32(t + 12)});
            }
            *newCollectionOut = c;
            return noErr;
        }
        at += size;
    }
    return kCMTagCollectionError_InvalidTagCollectionData;
}

/* --- tagged buffer groups --- */

struct OpaqueCMTaggedBufferGroup {
    CFRuntimeBase base;
    CFArrayRef collections, buffers;
};

typedef struct OpaqueCMTaggedBufferGroup *Group;

static void
group_finalize(CFTypeRef cf)
{
    Group g = (Group)cf;
    if (g->collections)
        CFRelease(g->collections);
    if (g->buffers)
        CFRelease(g->buffers);
}

static Boolean
group_equal(CFTypeRef a, CFTypeRef b)
{
    return CFEqual(((Group)a)->collections, ((Group)b)->collections) && CFEqual(((Group)a)->buffers, ((Group)b)->buffers);
}

CM_DEFINE_TYPE(CMTaggedBufferGroupGetTypeID, "CMTaggedBufferGroup", group_finalize, group_equal, NULL, NULL)

static bool
is_buffer(CFTypeRef b)
{
    return b && (CFGetTypeID(b) == CVPixelBufferGetTypeID() || CFGetTypeID(b) == CMSampleBufferGetTypeID());
}

OSStatus
CMTaggedBufferGroupCreate(CFAllocatorRef allocator, CFArrayRef tagCollections, CFArrayRef buffers, CMTaggedBufferGroupRef *groupOut)
{
    if (!tagCollections || !buffers || !groupOut || CFArrayGetCount(tagCollections) != CFArrayGetCount(buffers))
        return kCMTaggedBufferGroupError_ParamErr;
    for (CFIndex i = 0; i < CFArrayGetCount(buffers); i++)
        if (!is_buffer(CFArrayGetValueAtIndex(buffers, i)) || CFGetTypeID(CFArrayGetValueAtIndex(tagCollections, i)) != CMTagCollectionGetTypeID())
            return kCMTaggedBufferGroupError_ParamErr;
    Group g = (Group)cm_create(allocator, CMTaggedBufferGroupGetTypeID(), sizeof(struct OpaqueCMTaggedBufferGroup));
    if (!g)
        return kCMTaggedBufferGroupError_AllocationFailed;
    g->collections = CFArrayCreateCopy(allocator, tagCollections);
    g->buffers = CFArrayCreateCopy(allocator, buffers);
    *groupOut = g;
    return noErr;
}

OSStatus
CMTaggedBufferGroupCreateCombined(CFAllocatorRef allocator, CFArrayRef taggedBufferGroups, CMTaggedBufferGroupRef *groupOut)
{
    if (!taggedBufferGroups || !groupOut)
        return kCMTaggedBufferGroupError_ParamErr;
    CFMutableArrayRef collections = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks), buffers = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < CFArrayGetCount(taggedBufferGroups); i++) {
        Group g = (Group)CFArrayGetValueAtIndex(taggedBufferGroups, i);
        CFArrayAppendArray(collections, g->collections, CFRangeMake(0, CFArrayGetCount(g->collections)));
        CFArrayAppendArray(buffers, g->buffers, CFRangeMake(0, CFArrayGetCount(g->buffers)));
    }
    OSStatus e = CMTaggedBufferGroupCreate(allocator, collections, buffers, groupOut);
    CFRelease(collections);
    CFRelease(buffers);
    return e;
}

CMItemCount
CMTaggedBufferGroupGetCount(CMTaggedBufferGroupRef group)
{
    return group ? CFArrayGetCount(group->buffers) : 0;
}

CMTagCollectionRef
CMTaggedBufferGroupGetTagCollectionAtIndex(CMTaggedBufferGroupRef group, CFIndex index)
{
    return group && index >= 0 && index < CFArrayGetCount(group->collections) ? (CMTagCollectionRef)CFArrayGetValueAtIndex(group->collections, index)
                                                                              : NULL;
}

static CFTypeRef
buffer_at(CMTaggedBufferGroupRef group, CFIndex index, CFTypeID type)
{
    if (!group || index < 0 || index >= CFArrayGetCount(group->buffers))
        return NULL;
    CFTypeRef b = CFArrayGetValueAtIndex(group->buffers, index);
    return CFGetTypeID(b) == type ? b : NULL;
}

CVPixelBufferRef
CMTaggedBufferGroupGetCVPixelBufferAtIndex(CMTaggedBufferGroupRef group, CFIndex index)
{
    return (CVPixelBufferRef)buffer_at(group, index, CVPixelBufferGetTypeID());
}

CMSampleBufferRef
CMTaggedBufferGroupGetCMSampleBufferAtIndex(CMTaggedBufferGroupRef group, CFIndex index)
{
    return (CMSampleBufferRef)buffer_at(group, index, CMSampleBufferGetTypeID());
}

/* The one buffer whose tags contain these (none if more than one do). */
static CFTypeRef
buffer_for(CMTaggedBufferGroupRef group, const CMTag *tags, CMItemCount count, CFTypeID type, CFIndex *indexOut)
{
    CFIndex found = -1, matches = 0;
    for (CFIndex i = 0; group && i < CFArrayGetCount(group->collections); i++)
        if (CMTagCollectionContainsSpecifiedTags(CFArrayGetValueAtIndex(group->collections, i), tags, count)) {
            found = i;
            matches++;
        }
    if (matches != 1)
        return NULL;
    CFTypeRef b = buffer_at(group, found, type);
    if (b && indexOut)
        *indexOut = found;
    return b;
}

CVPixelBufferRef
CMTaggedBufferGroupGetCVPixelBufferForTag(CMTaggedBufferGroupRef group, CMTag tag, CFIndex *indexOut)
{
    return (CVPixelBufferRef)buffer_for(group, &tag, 1, CVPixelBufferGetTypeID(), indexOut);
}

CVPixelBufferRef
CMTaggedBufferGroupGetCVPixelBufferForTagCollection(CMTaggedBufferGroupRef group, CMTagCollectionRef tagCollection, CFIndex *indexOut)
{
    return tagCollection ? (CVPixelBufferRef)buffer_for(group, tagCollection->tags, tagCollection->count, CVPixelBufferGetTypeID(), indexOut) : NULL;
}

CMSampleBufferRef
CMTaggedBufferGroupGetCMSampleBufferForTag(CMTaggedBufferGroupRef group, CMTag tag, CFIndex *indexOut)
{
    return (CMSampleBufferRef)buffer_for(group, &tag, 1, CMSampleBufferGetTypeID(), indexOut);
}

CMSampleBufferRef
CMTaggedBufferGroupGetCMSampleBufferForTagCollection(CMTaggedBufferGroupRef group, CMTagCollectionRef tagCollection, CFIndex *indexOut)
{
    return tagCollection ? (CMSampleBufferRef)buffer_for(group, tagCollection->tags, tagCollection->count, CMSampleBufferGetTypeID(), indexOut) : NULL;
}

CMItemCount
CMTaggedBufferGroupGetNumberOfMatchesForTagCollection(CMTaggedBufferGroupRef group, CMTagCollectionRef tagCollection)
{
    CMItemCount n = 0;
    for (CFIndex i = 0; group && tagCollection && i < CFArrayGetCount(group->collections); i++)
        n += CMTagCollectionContainsTagsOfCollection(CFArrayGetValueAtIndex(group->collections, i), tagCollection);
    return n;
}

OSStatus
CMTaggedBufferGroupFormatDescriptionCreateForTaggedBufferGroupWithExtensions(CFAllocatorRef allocator, CMTaggedBufferGroupRef taggedBufferGroup,
                                                                             CFDictionaryRef extensions,
                                                                             CMTaggedBufferGroupFormatDescriptionRef *formatDescriptionOut)
{
    if (!taggedBufferGroup || !formatDescriptionOut)
        return kCMTaggedBufferGroupError_ParamErr;
    return CMFormatDescriptionCreate(allocator, kCMMediaType_TaggedBufferGroup, 'tbgr', extensions, formatDescriptionOut);
}

OSStatus
CMTaggedBufferGroupFormatDescriptionCreateForTaggedBufferGroup(CFAllocatorRef allocator, CMTaggedBufferGroupRef taggedBufferGroup,
                                                               CMTaggedBufferGroupFormatDescriptionRef *formatDescriptionOut)
{
    return CMTaggedBufferGroupFormatDescriptionCreateForTaggedBufferGroupWithExtensions(allocator, taggedBufferGroup, NULL, formatDescriptionOut);
}

Boolean
CMTaggedBufferGroupFormatDescriptionMatchesTaggedBufferGroup(CMTaggedBufferGroupFormatDescriptionRef desc, CMTaggedBufferGroupRef taggedBufferGroup)
{
    return desc && taggedBufferGroup && CMFormatDescriptionGetMediaType(desc) == kCMMediaType_TaggedBufferGroup;
}
