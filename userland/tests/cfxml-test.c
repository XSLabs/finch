/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFXMLNode.h>
#include <CoreFoundation/CFXMLParser.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void
show_string(const char *label, CFStringRef value)
{
    char buffer[256] = "(null)";
    if (value)
        CFStringGetCString(value, buffer, sizeof(buffer), kCFStringEncodingUTF8);
    printf("%s: %s\n", label, buffer);
}

static void
show_node(const char *label, CFXMLNodeRef node)
{
    printf("%s: %ld v%ld\n", label, (long)CFXMLNodeGetTypeCode(node), (long)CFXMLNodeGetVersion(node));
    show_string("  string", CFXMLNodeGetString(node));
}

typedef struct {
    int created;
    int attached;
    int ended;
    void *objects[64];
} ParseCounts;

static void *
create_structure(CFXMLParserRef parser, CFXMLNodeRef node, void *info)
{
    (void)parser;
    ParseCounts *counts = info;
    int *type = malloc(sizeof(*type));
    if (!type || counts->created >= 64) {
        free(type);
        return NULL;
    }
    *type = (int)CFXMLNodeGetTypeCode(node);
    counts->objects[counts->created++] = type;
    return type;
}

static void
add_child(CFXMLParserRef parser, void *parent, void *child, void *info)
{
    (void)parser;
    (void)parent;
    (void)child;
    ((ParseCounts *)info)->attached++;
}

static void
end_structure(CFXMLParserRef parser, void *node, void *info)
{
    (void)parser;
    (void)node;
    ((ParseCounts *)info)->ended++;
}

int
main(void)
{
    const char *source = "<root a=\"one\" b=\"two\"><child/>text<![CDATA[x]]><!--c--><?p data?></root>";
    CFDataRef data = CFDataCreate(NULL, (const UInt8 *)source, (CFIndex)strlen(source));
    CFXMLTreeRef document = CFXMLTreeCreateFromData(NULL, data, NULL, kCFXMLParserNoOptions, kCFXMLNodeCurrentVersion);
    printf("parsed: %d\n", document != NULL);
    if (!document) {
        CFRelease(data);
        return 1;
    }

    CFXMLNodeRef documentNode = CFXMLTreeGetNode(document);
    show_node("document", documentNode);
    const CFXMLDocumentInfo *documentInfo = CFXMLNodeGetInfoPtr(documentNode);
    printf("encoding: %lu\n", (unsigned long)(documentInfo ? documentInfo->encoding : 0));

    CFTreeRef rootTree = CFTreeGetFirstChild(document);
    CFXMLNodeRef rootNode = CFXMLTreeGetNode(rootTree);
    show_node("root", rootNode);
    const CFXMLElementInfo *element = CFXMLNodeGetInfoPtr(rootNode);
    printf("root children: %ld\n", (long)CFTreeGetChildCount(rootTree));
    printf("root attributes: %ld empty:%d\n", (long)CFDictionaryGetCount(element->attributes), element->isEmpty);
    CFStringRef firstKey = CFArrayGetValueAtIndex(element->attributeOrder, 0);
    CFStringRef firstValue = CFDictionaryGetValue(element->attributes, firstKey);
    show_string("first attribute", firstKey);
    show_string("first value", firstValue);

    CFXMLNodeRef childNode = CFXMLTreeGetNode(CFTreeGetFirstChild(rootTree));
    show_node("child", childNode);
    const CFXMLElementInfo *childInfo = CFXMLNodeGetInfoPtr(childNode);
    printf("child empty: %d\n", childInfo->isEmpty);

    CFXMLNodeRef copy = CFXMLNodeCreateCopy(NULL, rootNode);
    printf("node copy: %d\n", CFXMLNodeGetTypeCode(copy) == CFXMLNodeGetTypeCode(rootNode) &&
           CFEqual(CFXMLNodeGetString(copy), CFXMLNodeGetString(rootNode)));
    if (copy) CFRelease(copy);

    CFXMLTreeRef withError = CFXMLTreeCreateFromDataWithError(NULL, data, NULL, kCFXMLParserNoOptions,
                                                               kCFXMLNodeCurrentVersion, NULL);
    printf("tree with error api: %d\n", withError != NULL);
    CFDataRef serialized = CFXMLTreeCreateXMLData(NULL, document);
    printf("serialized: %ld bytes\n", (long)(serialized ? CFDataGetLength(serialized) : -1));
    if (serialized) {
        fwrite(CFDataGetBytePtr(serialized), 1, (size_t)CFDataGetLength(serialized), stdout);
        putchar('\n');
    }

    ParseCounts counts = { 0 };
    CFXMLParserCallBacks callbacks = { 0, create_structure, add_child, end_structure, NULL, NULL };
    CFXMLParserContext context = { 0, &counts, NULL, NULL, NULL };
    CFXMLParserRef parser = CFXMLParserCreate(NULL, data, NULL, kCFXMLParserNoOptions,
                                               kCFXMLNodeCurrentVersion, &callbacks, &context);
    printf("parser: %d type:%d status:%ld\n", parser != NULL,
           parser && CFGetTypeID(parser) == CFXMLParserGetTypeID(), (long)CFXMLParserGetStatusCode(parser));
    Boolean parsed = parser ? CFXMLParserParse(parser) : false;
    printf("parser result: %d status:%ld nodes:%d children:%d ended:%d document:%d line:%ld location:%ld\n",
           parsed, (long)CFXMLParserGetStatusCode(parser), counts.created,
           counts.attached, counts.ended, parser && CFXMLParserGetDocument(parser) != NULL,
           (long)CFXMLParserGetLineNumber(parser), (long)CFXMLParserGetLocation(parser));
    CFXMLParserCallBacks copiedCallbacks = { 0 };
    CFXMLParserGetCallBacks(parser, &copiedCallbacks);
    CFXMLParserContext copiedContext = { 0 };
    CFXMLParserGetContext(parser, &copiedContext);
    CFStringRef parseError = CFXMLParserCopyErrorDescription(parser);
    printf("parser callbacks: %d context:%d source:%d error:%d\n",
           copiedCallbacks.createXMLStructure == create_structure,
           copiedContext.info == &counts, CFXMLParserGetSourceURL(parser) == NULL,
           parseError != NULL);

    const char *badXML = "<root>";
    CFDataRef badData = CFDataCreate(NULL, (const UInt8 *)badXML, (CFIndex)strlen(badXML));
    CFDictionaryRef errors = NULL;
    CFXMLTreeRef badTree = CFXMLTreeCreateFromDataWithError(NULL, badData, NULL, kCFXMLParserNoOptions,
                                                             kCFXMLNodeCurrentVersion, &errors);
    CFNumberRef errorStatus = errors ? (CFNumberRef)CFDictionaryGetValue(errors, kCFXMLTreeErrorStatusCode) : NULL;
    long errorCode = 0;
    if (errorStatus) CFNumberGetValue(errorStatus, kCFNumberLongType, &errorCode);
    printf("malformed xml: tree:%d dictionary:%d status:%ld\n", badTree != NULL, errors != NULL, errorCode);

    CFIndex objectCount = counts.created;
    for (CFIndex i = 0; i < objectCount; i++) free(counts.objects[i]);
    if (parser) CFRelease(parser);
    if (parseError) CFRelease(parseError);
    if (withError) CFRelease(withError);
    if (serialized) CFRelease(serialized);
    if (errors) CFRelease(errors);
    if (badTree) CFRelease(badTree);
    CFRelease(badData);
    CFRelease(document);
    CFRelease(data);
    return 0;
}
