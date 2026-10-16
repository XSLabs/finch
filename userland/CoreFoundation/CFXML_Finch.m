/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* CFXML nodes are small CF objects; XML document parsing uses Finch's libxml2. */
#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFXMLNode.h>
#include <CoreFoundation/CFXMLParser.h>
#include "CFRuntime_Internal.h"
#include <libxml/parser.h>
#include <libxml/tree.h>
#include <pthread.h>
#include <limits.h>

#define FINCH_EXPORT __attribute__((visibility("default")))

struct __CFXMLNode {
    CFRuntimeBase _base;
    CFXMLNodeTypeCode type;
    CFStringRef string;
    void *info;
    CFIndex version;
};

static CFTypeID sCFXMLNodeTypeID;
static pthread_once_t sCFXMLNodeOnce = PTHREAD_ONCE_INIT;

static void *copy_info(CFAllocatorRef allocator, CFXMLNodeTypeCode type, const void *source);
static void free_info(CFAllocatorRef allocator, CFXMLNodeTypeCode type, void *info);

static void
xml_node_finalize(CFTypeRef cf)
{
    struct __CFXMLNode *node = (struct __CFXMLNode *)cf;
    CFAllocatorRef allocator = CFGetAllocator(cf);
    if (node->string)
        CFRelease(node->string);
    free_info(allocator, node->type, node->info);
}

static Boolean
xml_node_equal(CFTypeRef a, CFTypeRef b)
{
    const struct __CFXMLNode *one = (const struct __CFXMLNode *)a;
    const struct __CFXMLNode *two = (const struct __CFXMLNode *)b;
    return one->type == two->type && one->version == two->version && CFEqual(one->string, two->string);
}

static CFHashCode
xml_node_hash(CFTypeRef cf)
{
    const struct __CFXMLNode *node = (const struct __CFXMLNode *)cf;
    return CFHash(node->string) ^ (CFHashCode)node->type;
}

static CFStringRef
xml_node_description(CFTypeRef cf)
{
    const struct __CFXMLNode *node = (const struct __CFXMLNode *)cf;
    return CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("<CFXMLNode %ld %@>"), (long)node->type, node->string);
}

static void
register_xml_node(void)
{
    static const CFRuntimeClass cls = {
        .version = 0,
        .className = "CFXMLNode",
        .finalize = xml_node_finalize,
        .equal = xml_node_equal,
        .hash = xml_node_hash,
        .copyDebugDesc = xml_node_description,
    };
    sCFXMLNodeTypeID = _CFRuntimeRegisterClass(&cls);
}

FINCH_EXPORT CFTypeID
CFXMLNodeGetTypeID(void)
{
    pthread_once(&sCFXMLNodeOnce, register_xml_node);
    return sCFXMLNodeTypeID;
}

static void *
copy_info(CFAllocatorRef allocator, CFXMLNodeTypeCode type, const void *source)
{
    if (!source)
        return NULL;

    switch (type) {
    case kCFXMLNodeTypeElement: {
        const CFXMLElementInfo *src = (const CFXMLElementInfo *)source;
        CFXMLElementInfo *dst = CFAllocatorAllocate(allocator, sizeof(*dst), 0);
        if (!dst)
            return NULL;
        *dst = *src;
        dst->attributes = src->attributes ? CFDictionaryCreateCopy(allocator, src->attributes) : NULL;
        dst->attributeOrder = src->attributeOrder ? CFArrayCreateCopy(allocator, src->attributeOrder) : NULL;
        if ((src->attributes && !dst->attributes) || (src->attributeOrder && !dst->attributeOrder)) {
            if (dst->attributes) CFRelease(dst->attributes);
            if (dst->attributeOrder) CFRelease(dst->attributeOrder);
            CFAllocatorDeallocate(allocator, dst);
            return NULL;
        }
        return dst;
    }
    case kCFXMLNodeTypeProcessingInstruction: {
        const CFXMLProcessingInstructionInfo *src = source;
        CFXMLProcessingInstructionInfo *dst = CFAllocatorAllocate(allocator, sizeof(*dst), 0);
        if (!dst) return NULL;
        dst->dataString = src->dataString ? CFRetain(src->dataString) : NULL;
        return dst;
    }
    case kCFXMLNodeTypeDocument: {
        const CFXMLDocumentInfo *src = source;
        CFXMLDocumentInfo *dst = CFAllocatorAllocate(allocator, sizeof(*dst), 0);
        if (!dst) return NULL;
        dst->sourceURL = src->sourceURL ? CFRetain(src->sourceURL) : NULL;
        dst->encoding = src->encoding;
        return dst;
    }
    case kCFXMLNodeTypeDocumentType:
    case kCFXMLNodeTypeNotation: {
        const CFXMLDocumentTypeInfo *src = source;
        CFXMLDocumentTypeInfo *dst = CFAllocatorAllocate(allocator, sizeof(*dst), 0);
        if (!dst) return NULL;
        dst->externalID.systemID = src->externalID.systemID ? CFRetain(src->externalID.systemID) : NULL;
        dst->externalID.publicID = src->externalID.publicID ? CFRetain(src->externalID.publicID) : NULL;
        return dst;
    }
    case kCFXMLNodeTypeEntity: {
        const CFXMLEntityInfo *src = source;
        CFXMLEntityInfo *dst = CFAllocatorAllocate(allocator, sizeof(*dst), 0);
        if (!dst) return NULL;
        *dst = *src;
        if (dst->replacementText) CFRetain(dst->replacementText);
        if (dst->entityID.systemID) CFRetain(dst->entityID.systemID);
        if (dst->entityID.publicID) CFRetain(dst->entityID.publicID);
        if (dst->notationName) CFRetain(dst->notationName);
        return dst;
    }
    case kCFXMLNodeTypeEntityReference: {
        CFXMLEntityReferenceInfo *dst = CFAllocatorAllocate(allocator, sizeof(*dst), 0);
        if (dst) *dst = *(const CFXMLEntityReferenceInfo *)source;
        return dst;
    }
    default:
        return NULL;
    }
}

static void
free_info(CFAllocatorRef allocator, CFXMLNodeTypeCode type, void *info)
{
    if (!info)
        return;
    switch (type) {
    case kCFXMLNodeTypeElement: {
        CFXMLElementInfo *value = info;
        if (value->attributes) CFRelease(value->attributes);
        if (value->attributeOrder) CFRelease(value->attributeOrder);
        break;
    }
    case kCFXMLNodeTypeProcessingInstruction:
        if (((CFXMLProcessingInstructionInfo *)info)->dataString)
            CFRelease(((CFXMLProcessingInstructionInfo *)info)->dataString);
        break;
    case kCFXMLNodeTypeDocument:
        if (((CFXMLDocumentInfo *)info)->sourceURL)
            CFRelease(((CFXMLDocumentInfo *)info)->sourceURL);
        break;
    case kCFXMLNodeTypeDocumentType:
    case kCFXMLNodeTypeNotation: {
        CFXMLDocumentTypeInfo *value = info;
        if (value->externalID.systemID) CFRelease(value->externalID.systemID);
        if (value->externalID.publicID) CFRelease(value->externalID.publicID);
        break;
    }
    case kCFXMLNodeTypeEntity: {
        CFXMLEntityInfo *value = info;
        if (value->replacementText) CFRelease(value->replacementText);
        if (value->entityID.systemID) CFRelease(value->entityID.systemID);
        if (value->entityID.publicID) CFRelease(value->entityID.publicID);
        if (value->notationName) CFRelease(value->notationName);
        break;
    }
    default:
        break;
    }
    CFAllocatorDeallocate(allocator, info);
}

FINCH_EXPORT CFXMLNodeRef
CFXMLNodeCreate(CFAllocatorRef allocator, CFXMLNodeTypeCode type, CFStringRef string, const void *info, CFIndex version)
{
    if (version != kCFXMLNodeCurrentVersion || type < kCFXMLNodeTypeDocument || type > kCFXMLNodeTypeAttributeListDeclaration)
        return NULL;
    if (!string)
        return NULL;

    struct __CFXMLNode *node = (struct __CFXMLNode *)_CFRuntimeCreateInstance(
        allocator, CFXMLNodeGetTypeID(), sizeof(*node) - sizeof(CFRuntimeBase), NULL);
    if (!node)
        return NULL;
    node->type = type;
    node->string = CFRetain(string);
    node->version = version;
    node->info = copy_info(CFGetAllocator(node), type, info);
    if (info && !node->info) {
        CFRelease(node);
        return NULL;
    }
    return (CFXMLNodeRef)node;
}

FINCH_EXPORT CFXMLNodeRef
CFXMLNodeCreateCopy(CFAllocatorRef allocator, CFXMLNodeRef original)
{
    if (!original)
        return NULL;
    const struct __CFXMLNode *node = (const struct __CFXMLNode *)original;
    return CFXMLNodeCreate(allocator, node->type, node->string, node->info, node->version);
}

FINCH_EXPORT CFXMLNodeTypeCode
CFXMLNodeGetTypeCode(CFXMLNodeRef node)
{
    return node ? ((const struct __CFXMLNode *)node)->type : 0;
}

FINCH_EXPORT CFStringRef
CFXMLNodeGetString(CFXMLNodeRef node)
{
    return node ? ((const struct __CFXMLNode *)node)->string : NULL;
}

FINCH_EXPORT const void *
CFXMLNodeGetInfoPtr(CFXMLNodeRef node)
{
    return node ? ((const struct __CFXMLNode *)node)->info : NULL;
}

FINCH_EXPORT CFIndex
CFXMLNodeGetVersion(CFXMLNodeRef node)
{
    return node ? ((const struct __CFXMLNode *)node)->version : 0;
}

static const void *
xml_tree_retain(const void *info)
{
    return info ? CFRetain(info) : NULL;
}

static void
xml_tree_release(const void *info)
{
    if (info) CFRelease(info);
}

FINCH_EXPORT CFXMLTreeRef
CFXMLTreeCreateWithNode(CFAllocatorRef allocator, CFXMLNodeRef node)
{
    if (!node)
        return NULL;
    CFTreeContext context = { 0, (void *)node, xml_tree_retain, xml_tree_release, NULL };
    return CFTreeCreate(allocator, &context);
}

FINCH_EXPORT CFXMLNodeRef
CFXMLTreeGetNode(CFXMLTreeRef tree)
{
    if (!tree || CFGetTypeID(tree) != CFTreeGetTypeID())
        return NULL;
    CFTreeContext context = { 0 };
    CFTreeGetContext(tree, &context);
    return (CFXMLNodeRef)context.info;
}

static CFStringRef
string_from_xml(CFAllocatorRef allocator, const xmlChar *bytes)
{
    if (!bytes)
        return CFStringCreateWithCString(allocator, "", kCFStringEncodingUTF8);
    return CFStringCreateWithBytes(allocator, bytes, (CFIndex)xmlStrlen(bytes), kCFStringEncodingUTF8, false);
}

static CFStringEncoding
document_encoding(xmlDocPtr doc)
{
    if (!doc || !doc->encoding)
        return kCFStringEncodingUTF8;
    if (xmlStrcasecmp(doc->encoding, BAD_CAST "UTF-8") == 0 || xmlStrcasecmp(doc->encoding, BAD_CAST "UTF8") == 0)
        return kCFStringEncodingUTF8;
    if (xmlStrcasecmp(doc->encoding, BAD_CAST "UTF-16") == 0 || xmlStrcasecmp(doc->encoding, BAD_CAST "UTF-16LE") == 0)
        return kCFStringEncodingUTF16LE;
    if (xmlStrcasecmp(doc->encoding, BAD_CAST "UTF-16BE") == 0)
        return kCFStringEncodingUTF16BE;
    if (xmlStrcasecmp(doc->encoding, BAD_CAST "ISO-8859-1") == 0)
        return kCFStringEncodingISOLatin1;
    return kCFStringEncodingUTF8;
}

static CFURLRef
copy_url_from_xml(CFAllocatorRef allocator, const xmlChar *value)
{
    if (!value)
        return NULL;
    CFStringRef string = string_from_xml(allocator, value);
    CFURLRef url = string ? CFURLCreateWithString(allocator, string, NULL) : NULL;
    if (string) CFRelease(string);
    return url;
}

static CFXMLNodeRef
create_node_from_xml(CFAllocatorRef allocator, xmlDocPtr doc, xmlNodePtr source, CFURLRef sourceURL)
{
    if (!source)
        return NULL;
    CFXMLNodeTypeCode type;
    CFStringRef string = NULL;
    void *raw = NULL;
    CFXMLElementInfo element = { 0 };
    CFXMLDocumentInfo document = { sourceURL, document_encoding(doc) };
    CFXMLProcessingInstructionInfo instruction = { NULL };
    CFXMLDocumentTypeInfo documentType = { { NULL, NULL } };
    Boolean releaseString = true;

    switch (source->type) {
    case XML_DOCUMENT_NODE:
    case XML_HTML_DOCUMENT_NODE:
        type = kCFXMLNodeTypeDocument;
        string = CFSTR("");
        raw = &document;
        releaseString = false;
        break;
    case XML_ELEMENT_NODE: {
        type = kCFXMLNodeTypeElement;
        string = string_from_xml(allocator, source->name);
        CFMutableDictionaryRef attributes = CFDictionaryCreateMutable(allocator, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFMutableArrayRef order = CFArrayCreateMutable(allocator, 0, &kCFTypeArrayCallBacks);
        for (xmlAttrPtr attribute = source->properties; attribute; attribute = attribute->next) {
            CFStringRef key = string_from_xml(allocator, attribute->name);
            xmlChar *xmlValue = xmlNodeListGetString(doc, attribute->children, 1);
            CFStringRef value = string_from_xml(allocator, xmlValue);
            if (xmlValue) xmlFree(xmlValue);
            if (key && value) {
                CFDictionarySetValue(attributes, key, value);
                CFArrayAppendValue(order, key);
            }
            if (key) CFRelease(key);
            if (value) CFRelease(value);
        }
        element.attributes = attributes;
        element.attributeOrder = order;
        element.isEmpty = source->children == NULL;
        raw = &element;
        CFXMLNodeRef result = (string && attributes && order) ? CFXMLNodeCreate(allocator, type, string, raw, kCFXMLNodeCurrentVersion) : NULL;
        if (attributes) CFRelease(attributes);
        if (order) CFRelease(order);
        if (string) CFRelease(string);
        return result;
    }
    case XML_TEXT_NODE:
        type = xmlIsBlankNode(source) ? kCFXMLNodeTypeWhitespace : kCFXMLNodeTypeText;
        string = string_from_xml(allocator, source->content);
        break;
    case XML_CDATA_SECTION_NODE:
        type = kCFXMLNodeTypeCDATASection;
        string = string_from_xml(allocator, source->content);
        break;
    case XML_COMMENT_NODE:
        type = kCFXMLNodeTypeComment;
        string = string_from_xml(allocator, source->content);
        break;
    case XML_PI_NODE:
        type = kCFXMLNodeTypeProcessingInstruction;
        string = string_from_xml(allocator, source->name);
        instruction.dataString = string_from_xml(allocator, source->content);
        raw = &instruction;
        break;
    case XML_DTD_NODE:
        type = kCFXMLNodeTypeDocumentType;
        string = string_from_xml(allocator, source->name);
        documentType.externalID.systemID = copy_url_from_xml(allocator, ((xmlDtdPtr)source)->SystemID);
        documentType.externalID.publicID = string_from_xml(allocator, ((xmlDtdPtr)source)->ExternalID);
        raw = &documentType;
        break;
    case XML_ENTITY_REF_NODE: {
        type = kCFXMLNodeTypeEntityReference;
        string = string_from_xml(allocator, source->name);
        CFXMLEntityReferenceInfo entity = { kCFXMLEntityTypeParsedInternal };
        return string ? CFXMLNodeCreate(allocator, type, string, &entity, kCFXMLNodeCurrentVersion) : NULL;
    }
    default:
        return NULL;
    }

    CFXMLNodeRef result = string ? CFXMLNodeCreate(allocator, type, string, raw, kCFXMLNodeCurrentVersion) : NULL;
    if (type == kCFXMLNodeTypeProcessingInstruction && instruction.dataString)
        CFRelease(instruction.dataString);
    if (type == kCFXMLNodeTypeDocumentType) {
        if (documentType.externalID.systemID) CFRelease(documentType.externalID.systemID);
        if (documentType.externalID.publicID) CFRelease(documentType.externalID.publicID);
    }
    if (releaseString && string) CFRelease(string);
    return result;
}

static CFTreeRef
create_tree_from_xml(CFAllocatorRef allocator, xmlDocPtr doc, xmlNodePtr source, CFURLRef sourceURL, CFOptionFlags options)
{
    if (!source)
        return NULL;
    if ((options & kCFXMLParserSkipMetaData) && (source->type == XML_COMMENT_NODE || source->type == XML_DTD_NODE))
        return NULL;
    if ((options & kCFXMLParserSkipWhitespace) && source->type == XML_TEXT_NODE && xmlIsBlankNode(source))
        return NULL;

    CFXMLNodeRef node = create_node_from_xml(allocator, doc, source, sourceURL);
    if (!node)
        return NULL;
    CFTreeRef tree = CFXMLTreeCreateWithNode(allocator, node);
    CFRelease(node);
    if (!tree)
        return NULL;

    if (source->type == XML_DOCUMENT_NODE || source->type == XML_HTML_DOCUMENT_NODE ||
        source->type == XML_ELEMENT_NODE) {
        for (xmlNodePtr child = source->children; child; child = child->next) {
            CFTreeRef childTree = create_tree_from_xml(allocator, doc, child, sourceURL, options);
            if (childTree) {
                CFTreeAppendChild(tree, childTree);
                CFRelease(childTree);
            }
        }
    }
    return tree;
}

FINCH_EXPORT CFXMLTreeRef
CFXMLTreeCreateFromData(CFAllocatorRef allocator, CFDataRef data, CFURLRef sourceURL, CFOptionFlags options, CFIndex version)
{
    if (!data || version != kCFXMLNodeCurrentVersion)
        return NULL;
    CFIndex length = CFDataGetLength(data);
    if (length <= 0 || length > INT_MAX)
        return NULL;

    int parseOptions = XML_PARSE_NONET | XML_PARSE_NOERROR | XML_PARSE_NOWARNING;
    if (options & kCFXMLParserSkipWhitespace) parseOptions |= XML_PARSE_NOBLANKS;
    if (options & kCFXMLParserReplacePhysicalEntities) parseOptions |= XML_PARSE_NOENT;
    if (options & kCFXMLParserResolveExternalEntities) parseOptions |= XML_PARSE_DTDLOAD | XML_PARSE_NOENT;

    char base[PATH_MAX];
    const char *baseName = NULL;
    if (sourceURL) {
        CFStringRef absolute = CFURLGetString(sourceURL);
        if (absolute && CFStringGetCString(absolute, base, sizeof(base), kCFStringEncodingUTF8))
            baseName = base;
    }
    xmlDocPtr doc = xmlReadMemory((const char *)CFDataGetBytePtr(data), (int)length, baseName, NULL, parseOptions);
    if (!doc)
        return NULL;
    CFTreeRef tree = create_tree_from_xml(allocator, doc, (xmlNodePtr)doc, sourceURL, options);
    xmlFreeDoc(doc);
    return tree;
}
