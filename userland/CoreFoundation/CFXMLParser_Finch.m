/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* The deprecated CFXMLParser API over Finch's libxml2-backed CFXML tree. */
#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFXMLNode.h>
#include <CoreFoundation/CFXMLParser.h>
#include "CFRuntime_Internal.h"
#include <libxml/parser.h>
#include <libxml/xmlwriter.h>
#include <limits.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#define FINCH_EXPORT __attribute__((visibility("default")))

struct __CFXMLParser {
    CFRuntimeBase base;
    CFDataRef data;
    CFURLRef sourceURL;
    CFXMLParserCallBacks callbacks;
    CFXMLParserContext context;
    CFOptionFlags options;
    CFIndex version;
    CFIndex location;
    CFIndex line;
    CFXMLParserStatusCode status;
    CFStringRef error;
    void *document;
    Boolean parsing;
    Boolean parsed;
    Boolean aborted;
};

static CFTypeID sParserTypeID;
static pthread_once_t sParserOnce = PTHREAD_ONCE_INIT;

static void
parser_finalize(CFTypeRef object)
{
    struct __CFXMLParser *parser = (struct __CFXMLParser *)object;
    if (parser->data) CFRelease(parser->data);
    if (parser->sourceURL) CFRelease(parser->sourceURL);
    if (parser->error) CFRelease(parser->error);
    if (parser->context.info && parser->context.release)
        parser->context.release(parser->context.info);
}

static void
register_parser_type(void)
{
    static const CFRuntimeClass cls = {
        .version = 0,
        .className = "CFXMLParser",
        .finalize = parser_finalize,
    };
    sParserTypeID = _CFRuntimeRegisterClass(&cls);
}

FINCH_EXPORT CFTypeID
CFXMLParserGetTypeID(void)
{
    pthread_once(&sParserOnce, register_parser_type);
    return sParserTypeID;
}

static struct __CFXMLParser *
valid_parser(CFXMLParserRef parser)
{
    return parser && CFGetTypeID(parser) == CFXMLParserGetTypeID() ? (struct __CFXMLParser *)parser : NULL;
}

static CFDataRef
copy_url_data(CFAllocatorRef allocator, CFURLRef url)
{
    CFDataRef data = NULL;
    return url && CFURLCreateDataAndPropertiesFromResource(allocator, url, &data, NULL, NULL, NULL) ? data : NULL;
}

static CFXMLParserRef
create_parser(CFAllocatorRef allocator, CFDataRef data, CFURLRef sourceURL, CFOptionFlags options,
              CFIndex version, CFXMLParserCallBacks *callbacks, CFXMLParserContext *context)
{
    if (!data || version != kCFXMLNodeCurrentVersion || !callbacks ||
        !callbacks->createXMLStructure || !callbacks->addChild || !callbacks->endXMLStructure)
        return NULL;
    if (callbacks->version != 0 || (context && context->version != 0))
        return NULL;

    struct __CFXMLParser *parser = (struct __CFXMLParser *)_CFRuntimeCreateInstance(
        allocator, CFXMLParserGetTypeID(), sizeof(*parser) - sizeof(CFRuntimeBase), NULL);
    if (!parser)
        return NULL;
    parser->data = CFRetain(data);
    parser->sourceURL = sourceURL ? CFRetain(sourceURL) : NULL;
    parser->callbacks = *callbacks;
    if (context) {
        parser->context = *context;
        if (parser->context.info && parser->context.retain)
            parser->context.info = (void *)parser->context.retain(parser->context.info);
    }
    parser->options = options;
    parser->version = version;
    parser->status = kCFXMLStatusParseNotBegun;
    return (CFXMLParserRef)parser;
}

FINCH_EXPORT CFXMLParserRef
CFXMLParserCreate(CFAllocatorRef allocator, CFDataRef data, CFURLRef sourceURL, CFOptionFlags options,
                  CFIndex version, CFXMLParserCallBacks *callbacks, CFXMLParserContext *context)
{
    return create_parser(allocator, data, sourceURL, options, version, callbacks, context);
}

FINCH_EXPORT CFXMLParserRef
CFXMLParserCreateWithDataFromURL(CFAllocatorRef allocator, CFURLRef sourceURL, CFOptionFlags options,
                                 CFIndex version, CFXMLParserCallBacks *callbacks, CFXMLParserContext *context)
{
    CFDataRef data = copy_url_data(allocator, sourceURL);
    if (!data)
        return NULL;
    CFXMLParserRef parser = create_parser(allocator, data, sourceURL, options, version, callbacks, context);
    CFRelease(data);
    return parser;
}

FINCH_EXPORT void
CFXMLParserGetContext(CFXMLParserRef object, CFXMLParserContext *context)
{
    struct __CFXMLParser *parser = valid_parser(object);
    if (!context)
        return;
    if (parser)
        *context = parser->context;
    else
        memset(context, 0, sizeof(*context));
}

FINCH_EXPORT void
CFXMLParserGetCallBacks(CFXMLParserRef object, CFXMLParserCallBacks *callbacks)
{
    struct __CFXMLParser *parser = valid_parser(object);
    if (!callbacks)
        return;
    if (parser)
        *callbacks = parser->callbacks;
    else
        memset(callbacks, 0, sizeof(*callbacks));
}

FINCH_EXPORT CFURLRef
CFXMLParserGetSourceURL(CFXMLParserRef object)
{
    struct __CFXMLParser *parser = valid_parser(object);
    return parser ? parser->sourceURL : NULL;
}

FINCH_EXPORT CFIndex
CFXMLParserGetLocation(CFXMLParserRef object)
{
    struct __CFXMLParser *parser = valid_parser(object);
    return parser ? parser->location : 0;
}

FINCH_EXPORT CFIndex
CFXMLParserGetLineNumber(CFXMLParserRef object)
{
    struct __CFXMLParser *parser = valid_parser(object);
    return parser ? parser->line : 0;
}

FINCH_EXPORT void *
CFXMLParserGetDocument(CFXMLParserRef object)
{
    struct __CFXMLParser *parser = valid_parser(object);
    return parser ? parser->document : NULL;
}

FINCH_EXPORT CFXMLParserStatusCode
CFXMLParserGetStatusCode(CFXMLParserRef object)
{
    struct __CFXMLParser *parser = valid_parser(object);
    return parser ? parser->status : kCFXMLStatusParseNotBegun;
}

FINCH_EXPORT CFStringRef
CFXMLParserCopyErrorDescription(CFXMLParserRef object)
{
    struct __CFXMLParser *parser = valid_parser(object);
    return parser && parser->error ? CFRetain(parser->error) : NULL;
}

FINCH_EXPORT void
CFXMLParserAbort(CFXMLParserRef object, CFXMLParserStatusCode errorCode, CFStringRef errorDescription)
{
    struct __CFXMLParser *parser = valid_parser(object);
    if (!parser || !parser->parsing || errorCode <= 0 || !errorDescription)
        return;
    if (parser->error) CFRelease(parser->error);
    parser->error = CFRetain(errorDescription);
    parser->status = errorCode;
    parser->aborted = true;
}

static CFIndex
line_count(CFDataRef data)
{
    const UInt8 *bytes = CFDataGetBytePtr(data);
    CFIndex length = CFDataGetLength(data), line = 1;
    for (CFIndex i = 0; i < length; i++)
        if (bytes[i] == '\n') line++;
    return line;
}

static void *
walk_tree(struct __CFXMLParser *parser, CFTreeRef tree, void *parent)
{
    if (parser->aborted)
        return NULL;
    CFXMLNodeRef node = CFXMLTreeGetNode(tree);
    void *object = parser->callbacks.createXMLStructure((CFXMLParserRef)parser, node, parser->context.info);
    if (!object) {
        if (!parent && CFXMLNodeGetTypeCode(node) == kCFXMLNodeTypeDocument) {
            for (CFTreeRef child = CFTreeGetFirstChild(tree); child; child = CFTreeGetNextSibling(child)) {
                object = walk_tree(parser, child, NULL);
                if (object) break;
            }
        }
        return object;
    }
    if (parent)
        parser->callbacks.addChild((CFXMLParserRef)parser, parent, object, parser->context.info);
    else
        parser->document = object;
    for (CFTreeRef child = CFTreeGetFirstChild(tree); child && !parser->aborted; child = CFTreeGetNextSibling(child))
        (void)walk_tree(parser, child, object);
    if (!parser->aborted && CFXMLNodeGetTypeCode(node) != kCFXMLNodeTypeDocument)
        parser->callbacks.endXMLStructure((CFXMLParserRef)parser, object, parser->context.info);
    return object;
}

static CFXMLParserStatusCode status_for_xml_error(const xmlError *error, CFIndex length);

FINCH_EXPORT Boolean
CFXMLParserParse(CFXMLParserRef object)
{
    struct __CFXMLParser *parser = valid_parser(object);
    if (!parser || parser->parsing || parser->parsed)
        return false;
    parser->parsing = true;
    parser->status = kCFXMLStatusParseInProgress;
    xmlResetLastError();
    CFXMLTreeRef tree = CFXMLTreeCreateFromData(CFGetAllocator(parser), parser->data, parser->sourceURL,
                                                 parser->options, parser->version);
    if (tree) {
        (void)walk_tree(parser, (CFTreeRef)tree, NULL);
        CFRelease(tree);
    } else if (!parser->aborted) {
        const xmlError *xmlError = xmlGetLastError();
        parser->status = status_for_xml_error(xmlError, CFDataGetLength(parser->data));
        parser->error = xmlError && xmlError->message
            ? CFStringCreateWithCString(CFGetAllocator(parser), xmlError->message, kCFStringEncodingUTF8)
            : CFStringCreateWithCString(CFGetAllocator(parser), "Malformed XML", kCFStringEncodingUTF8);
        if (parser->callbacks.handleError && !parser->callbacks.handleError((CFXMLParserRef)parser, parser->status, parser->context.info))
            parser->aborted = true;
    }
    parser->parsing = false;
    parser->parsed = true;
    parser->location = CFDataGetLength(parser->data) + 1;
    parser->line = line_count(parser->data);
    if (parser->aborted)
        return false;
    if (!tree)
        return false;
    parser->status = kCFXMLStatusParseInProgress;
    return true;
}

static CFXMLParserStatusCode
status_for_xml_error(const xmlError *error, CFIndex length)
{
    if (!error || error->code == XML_ERR_DOCUMENT_EMPTY)
        return kCFXMLErrorNoData;
    if (error->code == XML_ERR_DOCUMENT_END || error->code == XML_ERR_TAG_NOT_FINISHED ||
        error->code == XML_ERR_GT_REQUIRED)
        return kCFXMLErrorUnexpectedEOF;
    if (error->code == XML_ERR_NAME_REQUIRED || error->code == XML_ERR_TAG_NAME_MISMATCH)
        return kCFXMLErrorMalformedName;
    if (length == 0)
        return kCFXMLErrorNoData;
    return kCFXMLErrorMalformedDocument;
}

FINCH_EXPORT CFXMLTreeRef
CFXMLTreeCreateFromDataWithError(CFAllocatorRef allocator, CFDataRef data, CFURLRef sourceURL,
                                 CFOptionFlags options, CFIndex version, CFDictionaryRef *errorDictionary)
{
    if (errorDictionary) *errorDictionary = NULL;
    if (!data || version != kCFXMLNodeCurrentVersion)
        return NULL;
    xmlResetLastError();
    CFXMLTreeRef tree = CFXMLTreeCreateFromData(allocator, data, sourceURL, options, version);
    if (tree || !errorDictionary)
        return tree;
    const xmlError *xmlError = xmlGetLastError();
    CFXMLParserStatusCode status = status_for_xml_error(xmlError, CFDataGetLength(data));
    CFStringRef message = xmlError && xmlError->message
        ? CFStringCreateWithCString(allocator, xmlError->message, kCFStringEncodingUTF8)
        : CFStringCreateWithCString(allocator, "Malformed XML", kCFStringEncodingUTF8);
    long line = xmlError ? xmlError->line : 0;
    long location = xmlError ? xmlError->int2 : 0;
    CFNumberRef lineNumber = CFNumberCreate(allocator, kCFNumberLongType, &line);
    CFNumberRef locationNumber = CFNumberCreate(allocator, kCFNumberLongType, &location);
    CFNumberRef statusNumber = CFNumberCreate(allocator, kCFNumberLongType, (long[]){status});
    const void *keys[] = { kCFXMLTreeErrorDescription, kCFXMLTreeErrorLineNumber,
                           kCFXMLTreeErrorLocation, kCFXMLTreeErrorStatusCode };
    const void *values[] = { message, lineNumber, locationNumber, statusNumber };
    *errorDictionary = CFDictionaryCreate(allocator, keys, values, 4,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (message) CFRelease(message);
    if (lineNumber) CFRelease(lineNumber);
    if (locationNumber) CFRelease(locationNumber);
    if (statusNumber) CFRelease(statusNumber);
    return NULL;
}

FINCH_EXPORT CFXMLTreeRef
CFXMLTreeCreateWithDataFromURL(CFAllocatorRef allocator, CFURLRef sourceURL, CFOptionFlags options, CFIndex version)
{
    CFDataRef data = copy_url_data(allocator, sourceURL);
    if (!data)
        return NULL;
    CFXMLTreeRef tree = CFXMLTreeCreateFromData(allocator, data, sourceURL, options, version);
    CFRelease(data);
    return tree;
}

static xmlChar *
xml_string(CFStringRef string)
{
    if (!string)
        return xmlStrdup(BAD_CAST "");
    CFIndex length = CFStringGetMaximumSizeForEncoding(CFStringGetLength(string), kCFStringEncodingUTF8) + 1;
    char *buffer = malloc((size_t)length);
    if (!buffer)
        return NULL;
    xmlChar *result = CFStringGetCString(string, buffer, length, kCFStringEncodingUTF8)
        ? xmlStrdup(BAD_CAST buffer) : NULL;
    free(buffer);
    return result;
}

static bool
write_xml_node(xmlTextWriterPtr writer, CFTreeRef tree)
{
    CFXMLNodeRef node = CFXMLTreeGetNode(tree);
    if (!node)
        return false;
    CFXMLNodeTypeCode type = CFXMLNodeGetTypeCode(node);
    CFStringRef string = CFXMLNodeGetString(node);
    xmlChar *name = xml_string(string);
    if (!name)
        return false;
    int result = 0;
    switch (type) {
    case kCFXMLNodeTypeDocument: {
        result = 0;
        break;
    }
    case kCFXMLNodeTypeElement: {
        result = xmlTextWriterStartElement(writer, name);
        const CFXMLElementInfo *info = CFXMLNodeGetInfoPtr(node);
        if (result >= 0 && info && info->attributes) {
            CFIndex count = info->attributeOrder ? CFArrayGetCount(info->attributeOrder) : CFDictionaryGetCount(info->attributes);
            for (CFIndex i = 0; i < count && result >= 0; i++) {
                CFStringRef key = info->attributeOrder ? CFArrayGetValueAtIndex(info->attributeOrder, i) : NULL;
                if (!key) continue;
                CFTypeRef value = CFDictionaryGetValue(info->attributes, key);
                xmlChar *keyBytes = xml_string(key), *valueBytes = xml_string(value);
                result = keyBytes && valueBytes ? xmlTextWriterWriteAttribute(writer, keyBytes, valueBytes) : -1;
                if (keyBytes) xmlFree(keyBytes);
                if (valueBytes) xmlFree(valueBytes);
            }
        }
        break;
    }
    case kCFXMLNodeTypeText:
    case kCFXMLNodeTypeWhitespace:
        result = xmlTextWriterWriteString(writer, name);
        break;
    case kCFXMLNodeTypeCDATASection:
        result = xmlTextWriterWriteCDATA(writer, name);
        break;
    case kCFXMLNodeTypeComment:
        result = xmlTextWriterWriteComment(writer, name);
        break;
    case kCFXMLNodeTypeProcessingInstruction: {
        const CFXMLProcessingInstructionInfo *info = CFXMLNodeGetInfoPtr(node);
        xmlChar *data = xml_string(info ? info->dataString : NULL);
        result = xmlTextWriterWritePI(writer, name, data ? data : BAD_CAST "");
        if (data) xmlFree(data);
        break;
    }
    case kCFXMLNodeTypeDocumentType: {
        const CFXMLDocumentTypeInfo *info = CFXMLNodeGetInfoPtr(node);
        xmlChar *publicID = info ? xml_string(info->externalID.publicID) : NULL;
        CFStringRef system = info && info->externalID.systemID ? CFURLGetString(info->externalID.systemID) : NULL;
        xmlChar *systemID = xml_string(system);
        result = xmlTextWriterWriteDTD(writer, name, publicID, systemID, NULL);
        if (publicID) xmlFree(publicID);
        if (systemID) xmlFree(systemID);
        break;
    }
    case kCFXMLNodeTypeEntityReference:
        result = xmlTextWriterWriteRaw(writer, BAD_CAST "&");
        if (result >= 0) result = xmlTextWriterWriteRaw(writer, name);
        if (result >= 0) result = xmlTextWriterWriteRaw(writer, BAD_CAST ";");
        break;
    default:
        result = 0;
        break;
    }
    xmlFree(name);
    if (result < 0)
        return false;
    for (CFTreeRef child = CFTreeGetFirstChild(tree); child; child = CFTreeGetNextSibling(child))
        if (!write_xml_node(writer, child)) return false;
    if (type == kCFXMLNodeTypeElement)
        return xmlTextWriterEndElement(writer) >= 0;
    return true;
}

FINCH_EXPORT CFDataRef
CFXMLTreeCreateXMLData(CFAllocatorRef allocator, CFXMLTreeRef tree)
{
    if (!tree || CFGetTypeID(tree) != CFTreeGetTypeID())
        return NULL;
    xmlBufferPtr buffer = xmlBufferCreate();
    if (!buffer)
        return NULL;
    xmlTextWriterPtr writer = xmlNewTextWriterMemory(buffer, 0);
    bool ok = writer && write_xml_node(writer, (CFTreeRef)tree);
    if (writer) xmlFreeTextWriter(writer);
    CFDataRef result = ok ? CFDataCreate(allocator, buffer->content, (CFIndex)buffer->use) : NULL;
    xmlBufferFree(buffer);
    return result;
}
