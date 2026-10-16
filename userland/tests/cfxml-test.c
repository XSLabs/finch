/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFXMLNode.h>
#include <CoreFoundation/CFXMLParser.h>
#include <stdio.h>
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
    CFRelease(document);
    CFRelease(data);
    return 0;
}
