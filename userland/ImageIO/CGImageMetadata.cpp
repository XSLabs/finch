/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Image metadata tags and XMP packets, represented with Core Foundation
 * values and parsed as XML without resolving external resources. */
#include "ImageIOInternal.h"
#include <Block.h>
#include <dispatch/dispatch.h>
#include <libxml/parser.h>
#include <libxml/tree.h>
#include <libxml/xmlwriter.h>
#include <limits.h>
#include <string>
#include <vector>

struct CGImageMetadata {
    IIORuntimeBase base;
    CFMutableArrayRef tags;
    CFMutableDictionaryRef namespaces;
};

struct CGImageMetadataTag {
    IIORuntimeBase base;
    CFStringRef xmlns;
    CFStringRef prefix;
    CFStringRef name;
    CGImageMetadataType type;
    CFTypeRef value;
    CFArrayRef qualifiers;
};

static CFTypeID metadata_type_id, tag_type_id;

static void
metadata_finalize(CFTypeRef cf)
{
    CGImageMetadataRef metadata = (CGImageMetadataRef)cf;
    if (metadata->tags)
        CFRelease(metadata->tags);
    if (metadata->namespaces)
        CFRelease(metadata->namespaces);
}

static void
tag_finalize(CFTypeRef cf)
{
    CGImageMetadataTagRef tag = (CGImageMetadataTagRef)cf;
    if (tag->xmlns) CFRelease(tag->xmlns);
    if (tag->prefix) CFRelease(tag->prefix);
    if (tag->name) CFRelease(tag->name);
    if (tag->value) CFRelease(tag->value);
    if (tag->qualifiers) CFRelease(tag->qualifiers);
}

static const IIORuntimeClass metadata_class = {
    0, "CGImageMetadata", NULL, NULL, metadata_finalize, NULL, NULL, NULL, NULL, NULL, NULL, 0,
};

static const IIORuntimeClass tag_class = {
    0, "CGImageMetadataTag", NULL, NULL, tag_finalize, NULL, NULL, NULL, NULL, NULL, NULL, 0,
};

CFTypeID
CGImageMetadataGetTypeID(void)
{
    return IIOTypeRegister(&metadata_class, &metadata_type_id);
}

CFTypeID
CGImageMetadataTagGetTypeID(void)
{
    return IIOTypeRegister(&tag_class, &tag_type_id);
}

static std::string
utf8(CFStringRef string)
{
    if (!string)
        return {};
    CFIndex size = CFStringGetMaximumSizeForEncoding(CFStringGetLength(string), kCFStringEncodingUTF8) + 1;
    if (size <= 0)
        return {};
    std::string result((size_t)size, '\0');
    if (!CFStringGetCString(string, &result[0], size, kCFStringEncodingUTF8))
        return {};
    result.resize(strlen(result.c_str()));
    return result;
}

static CFStringRef
string_from_utf8(const xmlChar *bytes)
{
    if (!bytes)
        return NULL;
    return CFStringCreateWithBytes(NULL, bytes, (CFIndex)xmlStrlen(bytes), kCFStringEncodingUTF8, false);
}

static const char *
known_prefix(CFStringRef xmlns)
{
    struct Pair { CFStringRef uri; const char *prefix; };
    static const Pair pairs[] = {
        {kCGImageMetadataNamespaceExif, "exif"},
        {kCGImageMetadataNamespaceExifAux, "aux"},
        {kCGImageMetadataNamespaceExifEX, "exifEX"},
        {kCGImageMetadataNamespaceDublinCore, "dc"},
        {kCGImageMetadataNamespaceIPTCCore, "Iptc4xmpCore"},
        {kCGImageMetadataNamespaceIPTCExtension, "Iptc4xmpExt"},
        {kCGImageMetadataNamespacePhotoshop, "photoshop"},
        {kCGImageMetadataNamespaceTIFF, "tiff"},
        {kCGImageMetadataNamespaceXMPBasic, "xmp"},
        {kCGImageMetadataNamespaceXMPRights, "xmpRights"},
    };
    for (const Pair &pair : pairs)
        if (CFEqual(xmlns, pair.uri))
            return pair.prefix;
    return NULL;
}

static CFStringRef
copy_value(CFTypeRef value)
{
    if (!value)
        return NULL;
    CFTypeID type = CFGetTypeID(value);
    if (type == CFStringGetTypeID())
        return (CFStringRef)CFRetain(value);
    if (type == CFBooleanGetTypeID())
        return CFStringCreateWithFormat(NULL, NULL, CFSTR("%@"), CFBooleanGetValue((CFBooleanRef)value) ? CFSTR("true") : CFSTR("false"));
    if (type == CFNumberGetTypeID())
        return CFStringCreateWithFormat(NULL, NULL, CFSTR("%@"), value);
    return NULL;
}

static CFTypeRef
copy_container(CFTypeRef value, CGImageMetadataType type)
{
    if (!value)
        return NULL;
    if (type == kCGImageMetadataTypeString)
        return copy_value(value);
    if (type >= kCGImageMetadataTypeArrayUnordered && type <= kCGImageMetadataTypeAlternateText &&
        CFGetTypeID(value) == CFArrayGetTypeID())
        return CFArrayCreateCopy(NULL, (CFArrayRef)value);
    if (type == kCGImageMetadataTypeStructure && CFGetTypeID(value) == CFDictionaryGetTypeID())
        return CFDictionaryCreateCopy(NULL, (CFDictionaryRef)value);
    return NULL;
}

static Boolean
valid_name(CFStringRef name)
{
    std::string text = utf8(name);
    return !text.empty() && xmlValidateNCName(BAD_CAST text.c_str(), 0) == 0;
}

static CGImageMetadataTagRef
tag_create(CFStringRef xmlns, CFStringRef prefix, CFStringRef name, CGImageMetadataType type, CFTypeRef value,
    CFArrayRef qualifiers)
{
    if (!xmlns || !name || !value || !valid_name(name))
        return NULL;
    CFStringRef actualPrefix = prefix;
    if (!actualPrefix) {
        const char *known = known_prefix(xmlns);
        if (!known)
            return NULL;
        actualPrefix = CFStringCreateWithCString(NULL, known, kCFStringEncodingUTF8);
    } else {
        CFRetain(actualPrefix);
    }
    if (!valid_name(actualPrefix)) {
        CFRelease(actualPrefix);
        return NULL;
    }

    if (type == kCGImageMetadataTypeDefault) {
        CFTypeID valueType = CFGetTypeID(value);
        type = valueType == CFArrayGetTypeID() ? kCGImageMetadataTypeArrayOrdered :
            valueType == CFDictionaryGetTypeID() ? kCGImageMetadataTypeStructure : kCGImageMetadataTypeString;
    }
    CFTypeRef saved = copy_container(value, type);
    if (!saved) {
        CFRelease(actualPrefix);
        return NULL;
    }
    if (type == kCGImageMetadataTypeArrayUnordered || type == kCGImageMetadataTypeArrayOrdered ||
        type == kCGImageMetadataTypeAlternateArray || type == kCGImageMetadataTypeAlternateText) {
        CFArrayRef array = (CFArrayRef)saved;
        for (CFIndex i = 0; i < CFArrayGetCount(array); i++) {
            CFTypeRef item = CFArrayGetValueAtIndex(array, i);
            CFTypeID itemType = CFGetTypeID(item);
            if (itemType != CFStringGetTypeID() && itemType != CGImageMetadataTagGetTypeID()) {
                CFRelease(saved);
                CFRelease(actualPrefix);
                return NULL;
            }
        }
    } else if (type == kCGImageMetadataTypeStructure) {
        CFDictionaryRef dictionary = (CFDictionaryRef)saved;
        CFIndex count = CFDictionaryGetCount(dictionary);
        std::vector<const void *> keys((size_t)count), values((size_t)count);
        CFDictionaryGetKeysAndValues(dictionary, keys.data(), values.data());
        for (CFIndex i = 0; i < count; i++) {
            CFTypeID keyType = CFGetTypeID(keys[(size_t)i]);
            CFTypeID valueType = CFGetTypeID(values[(size_t)i]);
            if (keyType != CFStringGetTypeID() ||
                (valueType != CFStringGetTypeID() && valueType != CGImageMetadataTagGetTypeID())) {
                CFRelease(saved);
                CFRelease(actualPrefix);
                return NULL;
            }
        }
    } else if (type != kCGImageMetadataTypeString) {
        CFRelease(saved);
        CFRelease(actualPrefix);
        return NULL;
    }

    CGImageMetadataTagRef tag = (CGImageMetadataTagRef)IIOTypeCreateInstance(CGImageMetadataTagGetTypeID(), sizeof(struct CGImageMetadataTag));
    if (!tag) {
        CFRelease(saved);
        CFRelease(actualPrefix);
        return NULL;
    }
    tag->xmlns = (CFStringRef)CFRetain(xmlns);
    tag->prefix = actualPrefix;
    tag->name = (CFStringRef)CFRetain(name);
    tag->type = type;
    tag->value = saved;
    tag->qualifiers = qualifiers && CFArrayGetCount(qualifiers) ? CFArrayCreateCopy(NULL, qualifiers) : NULL;
    return tag;
}

CGImageMetadataTagRef
CGImageMetadataTagCreate(CFStringRef xmlns, CFStringRef prefix, CFStringRef name, CGImageMetadataType type, CFTypeRef value)
{
    return tag_create(xmlns, prefix, name, type, value, NULL);
}

CFStringRef
CGImageMetadataTagCopyNamespace(CGImageMetadataTagRef tag)
{
    return tag ? (CFStringRef)CFRetain(tag->xmlns) : NULL;
}

CFStringRef
CGImageMetadataTagCopyPrefix(CGImageMetadataTagRef tag)
{
    return tag ? (CFStringRef)CFRetain(tag->prefix) : NULL;
}

CFStringRef
CGImageMetadataTagCopyName(CGImageMetadataTagRef tag)
{
    return tag ? (CFStringRef)CFRetain(tag->name) : NULL;
}

CFTypeRef
CGImageMetadataTagCopyValue(CGImageMetadataTagRef tag)
{
    return tag && tag->value ? CFRetain(tag->value) : NULL;
}

CGImageMetadataType
CGImageMetadataTagGetType(CGImageMetadataTagRef tag)
{
    return tag ? tag->type : kCGImageMetadataTypeInvalid;
}

CFArrayRef
CGImageMetadataTagCopyQualifiers(CGImageMetadataTagRef tag)
{
    return tag && tag->qualifiers ? CFArrayCreateCopy(NULL, tag->qualifiers) : NULL;
}

static void
register_common_namespaces(CGMutableImageMetadataRef metadata)
{
    struct Pair { CFStringRef prefix; CFStringRef uri; };
    static const Pair pairs[] = {
        {kCGImageMetadataPrefixExif, kCGImageMetadataNamespaceExif},
        {kCGImageMetadataPrefixExifAux, kCGImageMetadataNamespaceExifAux},
        {kCGImageMetadataPrefixExifEX, kCGImageMetadataNamespaceExifEX},
        {kCGImageMetadataPrefixDublinCore, kCGImageMetadataNamespaceDublinCore},
        {kCGImageMetadataPrefixIPTCCore, kCGImageMetadataNamespaceIPTCCore},
        {kCGImageMetadataPrefixIPTCExtension, kCGImageMetadataNamespaceIPTCExtension},
        {kCGImageMetadataPrefixPhotoshop, kCGImageMetadataNamespacePhotoshop},
        {kCGImageMetadataPrefixTIFF, kCGImageMetadataNamespaceTIFF},
        {kCGImageMetadataPrefixXMPBasic, kCGImageMetadataNamespaceXMPBasic},
        {kCGImageMetadataPrefixXMPRights, kCGImageMetadataNamespaceXMPRights},
    };
    for (const Pair &pair : pairs)
        CFDictionarySetValue(metadata->namespaces, pair.prefix, pair.uri);
}

CGMutableImageMetadataRef
CGImageMetadataCreateMutable(void)
{
    CGMutableImageMetadataRef metadata = (CGMutableImageMetadataRef)IIOTypeCreateInstance(CGImageMetadataGetTypeID(), sizeof(struct CGImageMetadata));
    if (!metadata)
        return NULL;
    metadata->tags = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    metadata->namespaces = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    register_common_namespaces(metadata);
    return metadata;
}

CGMutableImageMetadataRef
CGImageMetadataCreateMutableCopy(CGImageMetadataRef source)
{
    if (!source || CFGetTypeID(source) != CGImageMetadataGetTypeID())
        return NULL;
    CGMutableImageMetadataRef metadata = CGImageMetadataCreateMutable();
    if (!metadata)
        return NULL;
    CFArrayRemoveAllValues(metadata->tags);
    for (CFIndex i = 0; i < CFArrayGetCount(source->tags); i++)
        CFArrayAppendValue(metadata->tags, CFArrayGetValueAtIndex(source->tags, i));
    CFDictionaryRemoveAllValues(metadata->namespaces);
    CFIndex count = CFDictionaryGetCount(source->namespaces);
    std::vector<const void *> keys((size_t)count), values((size_t)count);
    CFDictionaryGetKeysAndValues(source->namespaces, keys.data(), values.data());
    for (CFIndex i = 0; i < count; i++)
        CFDictionarySetValue(metadata->namespaces, keys[(size_t)i], values[(size_t)i]);
    return metadata;
}

CFArrayRef
CGImageMetadataCopyTags(CGImageMetadataRef metadata)
{
    return metadata && metadata->tags ? CFArrayCreateCopy(NULL, metadata->tags) : NULL;
}

static CFStringRef
path_for_tag(CGImageMetadataTagRef tag)
{
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("%@:%@"), tag->prefix, tag->name);
}

static CGImageMetadataTagRef
find_top_tag(CGImageMetadataRef metadata, CFStringRef prefix, CFStringRef name)
{
    for (CFIndex i = 0; i < CFArrayGetCount(metadata->tags); i++) {
        CGImageMetadataTagRef tag = (CGImageMetadataTagRef)CFArrayGetValueAtIndex(metadata->tags, i);
        if (CFEqual(tag->prefix, prefix) && CFEqual(tag->name, name))
            return tag;
    }
    return NULL;
}

struct ParsedPath {
    CFStringRef prefix = NULL;
    CFStringRef name = NULL;
    std::string suffix;
};

static bool
parse_path(CFStringRef path, ParsedPath &out)
{
    std::string text = utf8(path);
    size_t colon = text.find(':');
    if (colon == std::string::npos || colon == 0 || colon + 1 >= text.size())
        return false;
    size_t end = text.find_first_of(".[?", colon + 1);
    if (end == std::string::npos)
        end = text.size();
    if (end == colon + 1)
        return false;
    out.prefix = CFStringCreateWithBytes(NULL, (const UInt8 *)text.data(), (CFIndex)colon, kCFStringEncodingUTF8, false);
    out.name = CFStringCreateWithBytes(NULL, (const UInt8 *)text.data() + colon + 1, (CFIndex)(end - colon - 1), kCFStringEncodingUTF8, false);
    out.suffix = text.substr(end);
    if (!out.prefix || !out.name) {
        if (out.prefix) CFRelease(out.prefix);
        if (out.name) CFRelease(out.name);
        out.prefix = out.name = NULL;
        return false;
    }
    return true;
}

static CGImageMetadataTagRef
find_path(CGImageMetadataRef metadata, CGImageMetadataTagRef parent, CFStringRef path)
{
    ParsedPath parsed;
    if (!parse_path(path, parsed))
        return NULL;
    CGImageMetadataTagRef tag = parent ? parent : find_top_tag(metadata, parsed.prefix, parsed.name);
    if (parent && (!CFEqual(parent->prefix, parsed.prefix) || !CFEqual(parent->name, parsed.name)))
        tag = NULL;
    CFRelease(parsed.prefix);
    CFRelease(parsed.name);
    if (!tag || !parsed.suffix.empty())
        return NULL;
    return tag;
}

CGImageMetadataTagRef
CGImageMetadataCopyTagWithPath(CGImageMetadataRef metadata, CGImageMetadataTagRef parent, CFStringRef path)
{
    if (!metadata || !path)
        return NULL;
    CGImageMetadataTagRef tag = find_path(metadata, parent, path);
    return tag ? (CGImageMetadataTagRef)CFRetain(tag) : NULL;
}

CFStringRef
CGImageMetadataCopyStringValueWithPath(CGImageMetadataRef metadata, CGImageMetadataTagRef parent, CFStringRef path)
{
    CGImageMetadataTagRef tag = CGImageMetadataCopyTagWithPath(metadata, parent, path);
    if (!tag)
        return NULL;
    CFStringRef value = tag->type == kCGImageMetadataTypeString ? (CFStringRef)CFRetain(tag->value) : NULL;
    CFRelease(tag);
    return value;
}

static void
set_error(CFErrorRef *error, CGImageMetadataErrors code)
{
    if (error)
        *error = CFErrorCreate(NULL, kCFErrorDomainCGImageMetadata, code, NULL);
}

bool
CGImageMetadataRegisterNamespaceForPrefix(CGMutableImageMetadataRef metadata, CFStringRef xmlns, CFStringRef prefix, CFErrorRef *error)
{
    if (error)
        *error = NULL;
    if (!metadata || !xmlns || !prefix || !valid_name(prefix) || CFStringGetLength(xmlns) == 0) {
        set_error(error, kCGImageMetadataErrorBadArgument);
        return false;
    }
    /* Apple accepts a prefix again with another URI and uses the new
     * association for subsequent path operations. */
    CFDictionarySetValue(metadata->namespaces, prefix, xmlns);
    return true;
}

static void
replace_top_tag(CGMutableImageMetadataRef metadata, CGImageMetadataTagRef oldTag, CGImageMetadataTagRef newTag)
{
    if (oldTag) {
        CFIndex index = CFArrayGetFirstIndexOfValue(metadata->tags, CFRangeMake(0, CFArrayGetCount(metadata->tags)), oldTag);
        if (index >= 0)
            CFArraySetValueAtIndex(metadata->tags, index, newTag);
    } else {
        CFArrayAppendValue(metadata->tags, newTag);
    }
}

bool
CGImageMetadataSetTagWithPath(CGMutableImageMetadataRef metadata, CGImageMetadataTagRef parent, CFStringRef path, CGImageMetadataTagRef tag)
{
    if (!metadata || !path || !tag || parent)
        return false;
    ParsedPath parsed;
    if (!parse_path(path, parsed))
        return false;
    CFTypeRef registered = CFDictionaryGetValue(metadata->namespaces, tag->prefix);
    bool direct = parsed.suffix.empty() && CFEqual(parsed.prefix, tag->prefix) && CFEqual(parsed.name, tag->name) &&
        registered && CFEqual(registered, tag->xmlns);
    if (direct) {
        CGImageMetadataTagRef old = find_top_tag(metadata, parsed.prefix, parsed.name);
        replace_top_tag(metadata, old, tag);
    }
    CFRelease(parsed.prefix);
    CFRelease(parsed.name);
    return direct;
}

bool
CGImageMetadataSetValueWithPath(CGMutableImageMetadataRef metadata, CGImageMetadataTagRef parent, CFStringRef path, CFTypeRef value)
{
    if (!metadata || parent || !path || !value)
        return false;
    ParsedPath parsed;
    if (!parse_path(path, parsed))
        return false;
    CFStringRef xmlns = (CFStringRef)CFDictionaryGetValue(metadata->namespaces, parsed.prefix);
    bool ok = false;
    if (xmlns && parsed.suffix.empty()) {
        CGImageMetadataTagRef made = tag_create(xmlns, parsed.prefix, parsed.name, kCGImageMetadataTypeDefault, value, NULL);
        if (made) {
            CGImageMetadataTagRef old = find_top_tag(metadata, parsed.prefix, parsed.name);
            replace_top_tag(metadata, old, made);
            CFRelease(made);
            ok = true;
        }
    }
    CFRelease(parsed.prefix);
    CFRelease(parsed.name);
    return ok;
}

bool
CGImageMetadataRemoveTagWithPath(CGMutableImageMetadataRef metadata, CGImageMetadataTagRef parent, CFStringRef path)
{
    if (!metadata || parent || !path)
        return false;
    ParsedPath parsed;
    if (!parse_path(path, parsed))
        return false;
    CGImageMetadataTagRef tag = parsed.suffix.empty() ? find_top_tag(metadata, parsed.prefix, parsed.name) : NULL;
    if (tag) {
        CFIndex index = CFArrayGetFirstIndexOfValue(metadata->tags, CFRangeMake(0, CFArrayGetCount(metadata->tags)), tag);
        if (index >= 0)
            CFArrayRemoveValueAtIndex(metadata->tags, index);
    }
    CFRelease(parsed.prefix);
    CFRelease(parsed.name);
    return tag != NULL;
}

static bool
enumerate_one(CFStringRef path, CGImageMetadataTagRef tag, CGImageMetadataTagBlock block, bool recursive)
{
    if (!block(path, tag))
        return false;
    if (!recursive)
        return true;
    if (tag->type == kCGImageMetadataTypeStructure) {
        CFDictionaryRef values = (CFDictionaryRef)tag->value;
        CFIndex count = CFDictionaryGetCount(values);
        std::vector<const void *> keys((size_t)count), items((size_t)count);
        CFDictionaryGetKeysAndValues(values, keys.data(), items.data());
        for (CFIndex i = 0; i < count; i++) {
            if (CFGetTypeID(items[(size_t)i]) != CGImageMetadataTagGetTypeID())
                continue;
            CGImageMetadataTagRef child = (CGImageMetadataTagRef)items[(size_t)i];
            CFStringRef childPath = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@.%@:%@"), path, child->prefix, child->name);
            bool keepGoing = enumerate_one(childPath, child, block, true);
            CFRelease(childPath);
            if (!keepGoing)
                return false;
        }
    } else if (tag->type >= kCGImageMetadataTypeArrayUnordered && tag->type <= kCGImageMetadataTypeAlternateText) {
        CFArrayRef values = (CFArrayRef)tag->value;
        for (CFIndex i = 0; i < CFArrayGetCount(values); i++) {
            CFTypeRef item = CFArrayGetValueAtIndex(values, i);
            if (CFGetTypeID(item) != CGImageMetadataTagGetTypeID())
                continue;
            CGImageMetadataTagRef child = (CGImageMetadataTagRef)item;
            CFStringRef childPath = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@[%ld]"), path, i);
            bool keepGoing = enumerate_one(childPath, child, block, true);
            CFRelease(childPath);
            if (!keepGoing)
                return false;
        }
    }
    return true;
}

void
CGImageMetadataEnumerateTagsUsingBlock(CGImageMetadataRef metadata, CFStringRef rootPath, CFDictionaryRef options, CGImageMetadataTagBlock block)
{
    if (!metadata || !block)
        return;
    bool recursive = options && CFDictionaryGetValue(options, kCGImageMetadataEnumerateRecursively) &&
        CFBooleanGetValue((CFBooleanRef)CFDictionaryGetValue(options, kCGImageMetadataEnumerateRecursively));
    if (rootPath && CFStringGetLength(rootPath)) {
        CGImageMetadataTagRef root = CGImageMetadataCopyTagWithPath(metadata, NULL, rootPath);
        if (root) {
            enumerate_one(rootPath, root, block, recursive);
            CFRelease(root);
        }
        return;
    }
    for (CFIndex i = 0; i < CFArrayGetCount(metadata->tags); i++) {
        CGImageMetadataTagRef tag = (CGImageMetadataTagRef)CFArrayGetValueAtIndex(metadata->tags, i);
        CFStringRef path = path_for_tag(tag);
        bool keepGoing = enumerate_one(path, tag, block, recursive);
        CFRelease(path);
        if (!keepGoing)
            break;
    }
}

struct ImagePropertyMap {
    CFStringRef dictionary;
    CFStringRef property;
    CFStringRef xmlns;
    CFStringRef prefix;
    CFStringRef name;
};

static const ImagePropertyMap image_properties[] = {
    {kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, kCGImageMetadataNamespaceTIFF, kCGImageMetadataPrefixTIFF, CFSTR("Orientation")},
    {kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFMake, kCGImageMetadataNamespaceTIFF, kCGImageMetadataPrefixTIFF, CFSTR("Make")},
    {kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFModel, kCGImageMetadataNamespaceTIFF, kCGImageMetadataPrefixTIFF, CFSTR("Model")},
    {kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFSoftware, kCGImageMetadataNamespaceTIFF, kCGImageMetadataPrefixTIFF, CFSTR("Software")},
    {kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFDateTime, kCGImageMetadataNamespaceTIFF, kCGImageMetadataPrefixTIFF, CFSTR("DateTime")},
    {kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal, kCGImageMetadataNamespacePhotoshop, kCGImageMetadataPrefixPhotoshop, CFSTR("DateCreated")},
};

static const ImagePropertyMap *
property_map(CFStringRef dictionary, CFStringRef property)
{
    for (const ImagePropertyMap &map : image_properties)
        if (CFEqual(dictionary, map.dictionary) && CFEqual(property, map.property))
            return &map;
    return NULL;
}

CGImageMetadataTagRef
CGImageMetadataCopyTagMatchingImageProperty(CGImageMetadataRef metadata, CFStringRef dictionaryName, CFStringRef propertyName)
{
    if (!metadata || !dictionaryName || !propertyName)
        return NULL;
    const ImagePropertyMap *map = property_map(dictionaryName, propertyName);
    if (!map)
        return NULL;
    CFStringRef path = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@:%@"), map->prefix, map->name);
    CGImageMetadataTagRef tag = CGImageMetadataCopyTagWithPath(metadata, NULL, path);
    CFRelease(path);
    return tag;
}

bool
CGImageMetadataSetValueMatchingImageProperty(CGMutableImageMetadataRef metadata, CFStringRef dictionaryName, CFStringRef propertyName, CFTypeRef value)
{
    if (!metadata || !dictionaryName || !propertyName || !value)
        return false;
    const ImagePropertyMap *map = property_map(dictionaryName, propertyName);
    if (!map)
        return false;
    CFStringRef path = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@:%@"), map->prefix, map->name);
    bool ok = CGImageMetadataSetValueWithPath(metadata, NULL, path, value);
    CFRelease(path);
    return ok;
}

static bool
write_xml_value(xmlTextWriterPtr writer, CGImageMetadataTagRef tag, unsigned depth)
{
    if (depth > 64)
        return false;
    std::string prefix = utf8(tag->prefix), name = utf8(tag->name), xmlns = utf8(tag->xmlns);
    std::string qname = prefix + ":" + name;
    if (xmlTextWriterStartElement(writer, BAD_CAST qname.c_str()) < 0 ||
        xmlTextWriterWriteAttribute(writer, BAD_CAST ("xmlns:" + prefix).c_str(), BAD_CAST xmlns.c_str()) < 0)
        return false;
    if (tag->type == kCGImageMetadataTypeString) {
        std::string value = utf8((CFStringRef)tag->value);
        if (xmlTextWriterWriteString(writer, BAD_CAST value.c_str()) < 0)
            return false;
    } else if (tag->type >= kCGImageMetadataTypeArrayUnordered && tag->type <= kCGImageMetadataTypeAlternateText) {
        const char *kind = tag->type == kCGImageMetadataTypeArrayUnordered ? "Bag" :
            tag->type == kCGImageMetadataTypeAlternateArray || tag->type == kCGImageMetadataTypeAlternateText ? "Alt" : "Seq";
        if (xmlTextWriterStartElement(writer, BAD_CAST (std::string("rdf:") + kind).c_str()) < 0 ||
            xmlTextWriterWriteAttribute(writer, BAD_CAST "xmlns:rdf", BAD_CAST "http://www.w3.org/1999/02/22-rdf-syntax-ns#") < 0)
            return false;
        CFArrayRef values = (CFArrayRef)tag->value;
        for (CFIndex i = 0; i < CFArrayGetCount(values); i++) {
            CFTypeRef item = CFArrayGetValueAtIndex(values, i);
            if (xmlTextWriterStartElement(writer, BAD_CAST "rdf:li") < 0)
                return false;
            if (CFGetTypeID(item) == CFStringGetTypeID()) {
                std::string text = utf8((CFStringRef)item);
                if (xmlTextWriterWriteString(writer, BAD_CAST text.c_str()) < 0)
                    return false;
            } else if (!write_xml_value(writer, (CGImageMetadataTagRef)item, depth + 1)) {
                return false;
            }
            if (xmlTextWriterEndElement(writer) < 0)
                return false;
        }
        if (xmlTextWriterEndElement(writer) < 0)
            return false;
    } else if (tag->type == kCGImageMetadataTypeStructure) {
        CFDictionaryRef values = (CFDictionaryRef)tag->value;
        CFIndex count = CFDictionaryGetCount(values);
        std::vector<const void *> keys((size_t)count), items((size_t)count);
        CFDictionaryGetKeysAndValues(values, keys.data(), items.data());
        for (CFIndex i = 0; i < count; i++) {
            if (CFGetTypeID(items[(size_t)i]) == CGImageMetadataTagGetTypeID()) {
                if (!write_xml_value(writer, (CGImageMetadataTagRef)items[(size_t)i], depth + 1))
                    return false;
            } else {
                std::string key = utf8((CFStringRef)keys[(size_t)i]);
                if (xmlTextWriterStartElement(writer, BAD_CAST (prefix + ":" + key).c_str()) < 0)
                    return false;
                std::string text = utf8((CFStringRef)items[(size_t)i]);
                if (xmlTextWriterWriteString(writer, BAD_CAST text.c_str()) < 0 || xmlTextWriterEndElement(writer) < 0)
                    return false;
            }
        }
    }
    return xmlTextWriterEndElement(writer) >= 0;
}

CFDataRef
CGImageMetadataCreateXMPData(CGImageMetadataRef metadata, CFDictionaryRef options)
{
    if (!metadata)
        return NULL;
    xmlBufferPtr buffer = xmlBufferCreate();
    xmlTextWriterPtr writer = buffer ? xmlNewTextWriterMemory(buffer, 0) : NULL;
    if (!writer) {
        if (buffer) xmlBufferFree(buffer);
        return NULL;
    }
    bool ok = xmlTextWriterStartDocument(writer, "1.0", "UTF-8", NULL) >= 0 &&
        xmlTextWriterStartElement(writer, BAD_CAST "x:xmpmeta") >= 0 &&
        xmlTextWriterWriteAttribute(writer, BAD_CAST "xmlns:x", BAD_CAST "adobe:ns:meta/") >= 0 &&
        xmlTextWriterStartElement(writer, BAD_CAST "rdf:RDF") >= 0 &&
        xmlTextWriterWriteAttribute(writer, BAD_CAST "xmlns:rdf", BAD_CAST "http://www.w3.org/1999/02/22-rdf-syntax-ns#") >= 0 &&
        xmlTextWriterStartElement(writer, BAD_CAST "rdf:Description") >= 0 &&
        xmlTextWriterWriteAttribute(writer, BAD_CAST "rdf:about", BAD_CAST "") >= 0;
    for (CFIndex i = 0; ok && i < CFArrayGetCount(metadata->tags); i++)
        ok = write_xml_value(writer, (CGImageMetadataTagRef)CFArrayGetValueAtIndex(metadata->tags, i), 0);
    if (ok)
        ok = xmlTextWriterEndElement(writer) >= 0 && xmlTextWriterEndElement(writer) >= 0 &&
            xmlTextWriterEndElement(writer) >= 0 && xmlTextWriterEndDocument(writer) >= 0;
    CFDataRef result = ok ? CFDataCreate(NULL, xmlBufferContent(buffer), (CFIndex)xmlBufferLength(buffer)) : NULL;
    xmlFreeTextWriter(writer);
    xmlBufferFree(buffer);
    return result;
}

static CGImageMetadataTagRef
parse_xml_property(CGMutableImageMetadataRef metadata, xmlNodePtr node, unsigned depth)
{
    if (depth > 64 || !node->ns || !node->ns->href)
        return NULL;
    CFStringRef xmlns = string_from_utf8(node->ns->href);
    CFStringRef prefix = string_from_utf8(node->ns->prefix);
    CFStringRef name = string_from_utf8(node->name);
    if (!prefix) {
        const char *known = known_prefix(xmlns);
        if (known)
            prefix = CFStringCreateWithCString(NULL, known, kCFStringEncodingUTF8);
    }
    if (!xmlns || !prefix || !name || !CGImageMetadataRegisterNamespaceForPrefix(metadata, xmlns, prefix, NULL)) {
        if (xmlns) CFRelease(xmlns);
        if (prefix) CFRelease(prefix);
        if (name) CFRelease(name);
        return NULL;
    }

    xmlNodePtr child = node->children;
    while (child && child->type != XML_ELEMENT_NODE)
        child = child->next;
    CGImageMetadataTagRef result = NULL;
    static const char *rdfURI = "http://www.w3.org/1999/02/22-rdf-syntax-ns#";
    if (child && child->ns && child->ns->href && xmlStrEqual(child->ns->href, BAD_CAST rdfURI) &&
        (xmlStrEqual(child->name, BAD_CAST "Bag") || xmlStrEqual(child->name, BAD_CAST "Seq") || xmlStrEqual(child->name, BAD_CAST "Alt"))) {
        CFMutableArrayRef values = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
        for (xmlNodePtr item = child->children; item; item = item->next)
            if (item->type == XML_ELEMENT_NODE && xmlStrEqual(item->name, BAD_CAST "li")) {
                xmlChar *content = xmlNodeGetContent(item);
                CFStringRef value = string_from_utf8(content);
                if (content) xmlFree(content);
                if (value) {
                    CFArrayAppendValue(values, value);
                    CFRelease(value);
                }
            }
        CGImageMetadataType type = xmlStrEqual(child->name, BAD_CAST "Bag") ? kCGImageMetadataTypeArrayUnordered :
            xmlStrEqual(child->name, BAD_CAST "Alt") ? kCGImageMetadataTypeAlternateText : kCGImageMetadataTypeArrayOrdered;
        result = tag_create(xmlns, prefix, name, type, values, NULL);
        CFRelease(values);
    } else if (child) {
        CFMutableDictionaryRef values = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        bool hasElement = false;
        for (xmlNodePtr item = node->children; item; item = item->next)
            if (item->type == XML_ELEMENT_NODE) {
                hasElement = true;
                CGImageMetadataTagRef nested = parse_xml_property(metadata, item, depth + 1);
                if (nested) {
                    CFStringRef key = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@:%@"), nested->prefix, nested->name);
                    CFDictionarySetValue(values, key, nested);
                    CFRelease(key);
                    CFRelease(nested);
                }
            }
        if (hasElement) {
            result = tag_create(xmlns, prefix, name, kCGImageMetadataTypeStructure, values, NULL);
        } else {
            xmlChar *content = xmlNodeGetContent(node);
            CFStringRef text = string_from_utf8(content);
            if (content) xmlFree(content);
            if (text) {
                result = tag_create(xmlns, prefix, name, kCGImageMetadataTypeString, text, NULL);
                CFRelease(text);
            }
        }
        CFRelease(values);
    } else {
        xmlChar *content = xmlNodeGetContent(node);
        CFStringRef text = string_from_utf8(content);
        if (content) xmlFree(content);
        if (text) {
            result = tag_create(xmlns, prefix, name, kCGImageMetadataTypeString, text, NULL);
            CFRelease(text);
        }
    }
    CFRelease(xmlns);
    CFRelease(prefix);
    CFRelease(name);
    return result;
}

CGImageMetadataRef
CGImageMetadataCreateFromXMPData(CFDataRef data)
{
    if (!data || CFDataGetLength(data) <= 0 || CFDataGetLength(data) > INT_MAX)
        return NULL;
    xmlDocPtr doc = xmlReadMemory((const char *)CFDataGetBytePtr(data), (int)CFDataGetLength(data), "metadata.xmp", NULL,
        XML_PARSE_NONET | XML_PARSE_NOERROR | XML_PARSE_NOWARNING | XML_PARSE_NOBLANKS);
    if (!doc)
        return NULL;
    CGMutableImageMetadataRef metadata = CGImageMetadataCreateMutable();
    if (!metadata) {
        xmlFreeDoc(doc);
        return NULL;
    }
    bool found = false;
    static const char *rdfURI = "http://www.w3.org/1999/02/22-rdf-syntax-ns#";
    for (xmlNodePtr node = xmlDocGetRootElement(doc); node; ) {
        if (node->type == XML_ELEMENT_NODE && node->ns && node->ns->href &&
            xmlStrEqual(node->ns->href, BAD_CAST rdfURI) && xmlStrEqual(node->name, BAD_CAST "RDF")) {
            for (xmlNodePtr description = node->children; description; description = description->next) {
                if (description->type != XML_ELEMENT_NODE || !xmlStrEqual(description->name, BAD_CAST "Description"))
                    continue;
                found = true;
                for (xmlNodePtr property = description->children; property; property = property->next)
                    if (property->type == XML_ELEMENT_NODE) {
                        CGImageMetadataTagRef tag = parse_xml_property(metadata, property, 0);
                        if (tag) {
                            CFArrayAppendValue(metadata->tags, tag);
                            CFRelease(tag);
                        }
                    }
                for (xmlAttrPtr attr = description->properties; attr; attr = attr->next) {
                    if (!attr->ns || !attr->ns->href || xmlStrEqual(attr->name, BAD_CAST "about"))
                        continue;
                    xmlChar *content = xmlNodeListGetString(doc, attr->children, 1);
                    CFStringRef xmlns = string_from_utf8(attr->ns->href);
                    CFStringRef prefix = string_from_utf8(attr->ns->prefix);
                    CFStringRef name = string_from_utf8(attr->name);
                    CFStringRef value = string_from_utf8(content);
                    if (content) xmlFree(content);
                    if (xmlns && prefix && name && value && CGImageMetadataRegisterNamespaceForPrefix(metadata, xmlns, prefix, NULL)) {
                        CGImageMetadataTagRef tag = tag_create(xmlns, prefix, name, kCGImageMetadataTypeString, value, NULL);
                        if (tag) {
                            CFArrayAppendValue(metadata->tags, tag);
                            CFRelease(tag);
                        }
                    }
                    if (xmlns) CFRelease(xmlns);
                    if (prefix) CFRelease(prefix);
                    if (name) CFRelease(name);
                    if (value) CFRelease(value);
                }
            }
            break;
        }
        node = node->children;
    }
    xmlFreeDoc(doc);
    if (!found) {
        CFRelease(metadata);
        return NULL;
    }
    return metadata;
}

struct Animation {
    CGImageSourceRef source;
    CGImageSourceAnimationBlock block;
    size_t count;
    size_t start;
    size_t index;
    size_t cycle;
    size_t cycles;
    double delayOverride;
    bool hasDelayOverride;
};

static bool
option_number(CFDictionaryRef options, CFStringRef key, double *value)
{
    CFTypeRef item = options ? CFDictionaryGetValue(options, key) : NULL;
    return item && CFGetTypeID(item) == CFNumberGetTypeID() && CFNumberGetValue((CFNumberRef)item, kCFNumberDoubleType, value);
}

static void
animation_finish(Animation *animation)
{
    Block_release(animation->block);
    CFRelease(animation->source);
    free(animation);
}

static double
animation_delay(Animation *animation, size_t index)
{
    if (animation->hasDelayOverride)
        return animation->delayOverride;
    CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(animation->source, index, NULL);
    CFDictionaryRef gif = properties ? (CFDictionaryRef)CFDictionaryGetValue(properties, kCGImagePropertyGIFDictionary) : NULL;
    CFTypeRef delay = gif ? CFDictionaryGetValue(gif, kCGImagePropertyGIFUnclampedDelayTime) : NULL;
    if (!delay && gif)
        delay = CFDictionaryGetValue(gif, kCGImagePropertyGIFDelayTime);
    double seconds = 0.1;
    if (delay && CFGetTypeID(delay) == CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)delay, kCFNumberDoubleType, &seconds);
    if (properties)
        CFRelease(properties);
    if (seconds < 0.02)
        seconds = 0.1;
    return seconds;
}

static void animation_tick(Animation *animation);

static void
animation_schedule(Animation *animation, double delay)
{
    int64_t nanoseconds = delay <= 0 ? 0 : (int64_t)(delay * (double)NSEC_PER_SEC);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, nanoseconds), dispatch_get_main_queue(), ^{
        animation_tick(animation);
    });
}

static void
animation_tick(Animation *animation)
{
    if (animation->index >= animation->count) {
        animation_finish(animation);
        return;
    }
    size_t index = animation->index;
    CGImageRef image = CGImageSourceCreateImageAtIndex(animation->source, index, NULL);
    if (!image) {
        animation_finish(animation);
        return;
    }
    bool stop = false;
    animation->block(index, image, &stop);
    CGImageRelease(image);
    if (stop) {
        animation_finish(animation);
        return;
    }
    double delay = animation_delay(animation, index);
    animation->index++;
    if (animation->index == animation->count) {
        animation->cycle++;
        if (animation->cycles && animation->cycle >= animation->cycles) {
            animation_finish(animation);
            return;
        }
        animation->index = animation->start;
    }
    animation_schedule(animation, delay);
}

static OSStatus
animate_source(CGImageSourceRef source, CFDictionaryRef options, CGImageSourceAnimationBlock block)
{
    if (!source || !block) {
        if (source) CFRelease(source);
        return -50; /* Apple's ImageIO reports paramErr for missing arguments. */
    }
    size_t count = CGImageSourceGetCount(source);
    CFStringRef type = CGImageSourceGetType(source);
    if (!count || !type) {
        CFRelease(source);
        return kCGImageAnimationStatus_CorruptInputImage;
    }
    if (!CFEqual(type, CFSTR("com.compuserve.gif"))) {
        OSStatus status = CFEqual(type, CFSTR("public.png")) ?
            kCGImageAnimationStatus_CorruptInputImage : kCGImageAnimationStatus_UnsupportedFormat;
        CFRelease(source);
        return status;
    }

    Animation *animation = (Animation *)calloc(1, sizeof(Animation));
    if (!animation) {
        CFRelease(source);
        return kCGImageAnimationStatus_AllocationFailure;
    }
    animation->source = source;
    animation->block = (CGImageSourceAnimationBlock)Block_copy(block);
    animation->count = count;
    double start = 0;
    if (option_number(options, kCGImageAnimationStartIndex, &start) && start >= 0)
        animation->start = (size_t)start % count;
    animation->index = animation->start;
    if (option_number(options, kCGImageAnimationDelayTime, &animation->delayOverride))
        animation->hasDelayOverride = true;
    double loops = -1;
    if (option_number(options, kCGImageAnimationLoopCount, &loops)) {
        animation->cycles = loops < 0 ? 0 : (size_t)loops + 1;
    } else {
        CFDictionaryRef properties = CGImageSourceCopyProperties(source, NULL);
        CFDictionaryRef gif = properties ? (CFDictionaryRef)CFDictionaryGetValue(properties, kCGImagePropertyGIFDictionary) : NULL;
        CFTypeRef value = gif ? CFDictionaryGetValue(gif, kCGImagePropertyGIFLoopCount) : NULL;
        double gifLoops = 0;
        if (value && CFGetTypeID(value) == CFNumberGetTypeID() && CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &gifLoops))
            animation->cycles = gifLoops == 0 ? 0 : (size_t)gifLoops + 1;
        else
            animation->cycles = 1;
        if (properties)
            CFRelease(properties);
    }
    animation_schedule(animation, 0);
    return noErr;
}

OSStatus
CGAnimateImageDataWithBlock(CFDataRef data, CFDictionaryRef options, CGImageSourceAnimationBlock block)
{
    if (!data || !block)
        return -50; /* Apple's ImageIO reports paramErr for missing arguments. */
    return animate_source(CGImageSourceCreateWithData(data, NULL), options, block);
}

OSStatus
CGAnimateImageAtURLWithBlock(CFURLRef url, CFDictionaryRef options, CGImageSourceAnimationBlock block)
{
    if (!url || !block)
        return -50; /* Apple's ImageIO reports paramErr for missing arguments. */
    CGImageSourceRef source = CGImageSourceCreateWithURL(url, NULL);
    if (!source)
        return kCGImageAnimationStatus_CorruptInputImage;
    return animate_source(source, options, block);
}
