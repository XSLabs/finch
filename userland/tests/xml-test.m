/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSXMLDocument, NSXMLElement, NSXMLNode and NSXMLDTD: parsing (options, errors),
 * the tree (kinds, names, values, children, attributes, namespaces, indexes, paths),
 * editing, output (compact, pretty printed, options), XPath, entities, CDATA,
 * comments, processing instructions and DTDs. Compared with Apple's.
 */
#import <Foundation/Foundation.h>

static void
show(const char *label, NSString *s)
{
    printf("%s: %s\n", label, s ? [[s stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"] UTF8String] : "(nil)");
}

static NSString *
kinds(NSArray *nodes)
{
    NSMutableArray *a = [NSMutableArray array];
    for (NSXMLNode *n in nodes)
        [a addObject:[NSString stringWithFormat:@"%lu:%@", (unsigned long)n.kind, n.name ?: @"-"]];
    return [a componentsJoinedByString:@" "];
}

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        printf("NSXML\n");
        NSString *src = @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                         "<!-- a library -->\n"
                         "<library xmlns=\"urn:lib\" xmlns:x=\"urn:extra\" city=\"Oslo\">\n"
                         "  <book id=\"b1\" year=\"1999\"><title>Dune &amp; more</title><x:note>first</x:note></book>\n"
                         "  <book id=\"b2\"><title><![CDATA[<raw> & text]]></title><?render fast?></book>\n"
                         "  <empty/>\n"
                         "</library>";
        NSError *error = nil;
        NSXMLDocument *doc = [[NSXMLDocument alloc] initWithXMLString:src options:0 error:&error];
        printf("parsed: %d, error %ld, kind %lu, version %s, encoding %s, standalone %d, content kind %lu\n", doc != nil, (long)error.code,
            (unsigned long)doc.kind, doc.version.UTF8String, doc.characterEncoding.UTF8String, doc.isStandalone,
            (unsigned long)doc.documentContentKind);
        printf("children: %s\n", kinds(doc.children).UTF8String);
        NSXMLElement *root = doc.rootElement;
        printf("root: %s uri %s prefix [%s] local %s, attributes %s\n", root.name.UTF8String, root.URI.UTF8String, root.prefix.UTF8String,
            root.localName.UTF8String, kinds(root.attributes).UTF8String);
        printf("namespaces: %s, resolve x %s, prefix for urn:extra %s\n", kinds(root.namespaces).UTF8String,
            [root resolveNamespaceForName:@"x:note"].stringValue.UTF8String, [root resolvePrefixForNamespaceURI:@"urn:extra"].UTF8String);
        printf("root children: %s\n", kinds(root.children).UTF8String);
        NSXMLElement *book = [root elementsForName:@"book"].firstObject;
        printf("book: index %lu level %lu, attr id %s year %s, xpath %s\n", (unsigned long)book.index, (unsigned long)book.level,
            [book attributeForName:@"id"].stringValue.UTF8String, [book attributeForName:@"year"].stringValue.UTF8String, book.XPath.UTF8String);
        NSXMLNode *title = book.children.firstObject;
        show("title string", title.stringValue);
        show("title XML", title.XMLString);
        show("note", [book elementsForLocalName:@"note" URI:@"urn:extra"].firstObject.XMLString);
        NSXMLElement *book2 = [root elementsForName:@"book"][1];
        printf("cdata: kind %lu %s\n", (unsigned long)[book2.children[0] childAtIndex:0].kind, [book2.children[0] stringValue].UTF8String);
        NSXMLNode *pi = book2.children[1];
        printf("pi: kind %lu name %s value %s\n", (unsigned long)pi.kind, pi.name.UTF8String, pi.stringValue.UTF8String);
        printf("comment: %s\n", [doc.children[0] stringValue].UTF8String);
        printf("navigation: next %s, previous %s, root %s, parent %s\n", [title nextNode].name.UTF8String, [book2 previousSibling].name.UTF8String,
            [title rootDocument] == doc ? "doc" : "?", title.parent.name.UTF8String);
        printf("string value of root: [%s]\n", [[root.stringValue stringByReplacingOccurrencesOfString:@"\n" withString:@"|"] UTF8String]);
        show("compact", doc.XMLString);
        show("pretty", [doc XMLStringWithOptions:NSXMLNodePrettyPrint]);
        show("element pretty", [book XMLStringWithOptions:NSXMLNodePrettyPrint]);
        show("description", book.description);

        /* XPath */
        NSArray *found = [doc nodesForXPath:@"//*[local-name()='book']/@id" error:&error];
        printf("xpath ids: %s\n", [[found valueForKey:@"stringValue"] componentsJoinedByString:@","].UTF8String);
        found = [root nodesForXPath:@"./*" error:&error];
        printf("xpath children: %s\n", kinds(found).UTF8String);
        found = [doc nodesForXPath:@"count(//*)" error:&error];
        printf("xpath count: %lu %s\n", (unsigned long)found.count, error ? "error" : "ok");
        error = nil;
        found = [doc nodesForXPath:@"//[" error:&error];
        printf("bad xpath: %s %s %ld\n", found ? "array" : "nil", error.domain.UTF8String, (long)error.code);

        /* building */
        NSXMLElement *e = [NSXMLElement elementWithName:@"item" stringValue:@"a < b"];
        [e addAttribute:[NSXMLNode attributeWithName:@"n" stringValue:@"1 & \"2\""]];
        [e addAttribute:[NSXMLNode attributeWithName:@"a" stringValue:@"first"]];
        [e addChild:[NSXMLNode commentWithStringValue:@" note "]];
        [e addChild:[NSXMLElement elementWithName:@"sub" children:@[ [NSXMLNode textWithStringValue:@"t"] ] attributes:nil]];
        [e insertChild:[NSXMLNode processingInstructionWithName:@"pi" stringValue:@"x"] atIndex:0];
        show("built", e.XMLString);
        show("built pretty", [e XMLStringWithOptions:NSXMLNodePrettyPrint]);
        [e setAttributesWithDictionary:@{@"z" : @"26"}];
        show("attrs replaced", e.XMLString);
        [e removeChildAtIndex:0];
        [e replaceChildAtIndex:0 withNode:[NSXMLNode textWithStringValue:@"new"]];
        show("edited", e.XMLString);
        NSXMLElement *copy = [e copy];
        [copy setName:@"copy"];
        show("copy", copy.XMLString);
        printf("detach: ");
        NSXMLNode *sub = [e elementsForName:@"sub"].firstObject;
        [sub detach];
        printf("%s parent %s\n", e.XMLString.UTF8String, sub.parent ? "set" : "nil");
        @try {
            [root addChild:title];
        } @catch (NSException *ex) {
            printf("child with parent: %s\n", ex.name.UTF8String);
        }
        NSXMLDocument *made = [NSXMLDocument documentWithRootElement:[NSXMLElement elementWithName:@"r"]];
        [made setVersion:@"1.0"];
        [made setCharacterEncoding:@"UTF-8"];
        [made.rootElement addChild:[NSXMLElement elementWithName:@"c" stringValue:@"v"]];
        show("made doc", made.XMLString);
        NSData *data = [made XMLDataWithOptions:NSXMLNodePrettyPrint];
        show("made data", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
        made.documentContentKind = NSXMLDocumentHTMLKind;
        [made.rootElement addChild:[NSXMLElement elementWithName:@"br"]];
        show("html kind", made.XMLString);

        /* options and errors */
        NSXMLDocument *ws = [[NSXMLDocument alloc] initWithXMLString:@"<a>  <b> x </b>  </a>" options:NSXMLNodePreserveWhitespace error:nil];
        show("preserve whitespace", ws.XMLString);
        ws = [[NSXMLDocument alloc] initWithXMLString:@"<a>  <b> x </b>  </a>" options:0 error:nil];
        show("default whitespace", ws.XMLString);
        error = nil;
        NSXMLDocument *bad = [[NSXMLDocument alloc] initWithXMLString:@"<a><b></a>" options:0 error:&error];
        printf("malformed: %s, error %s %ld\n", bad ? "doc" : "nil", error.domain.UTF8String, (long)error.code);
        error = nil;
        NSXMLDocument *tidy = [[NSXMLDocument alloc] initWithXMLString:@"<a><b>x</a>" options:NSXMLDocumentTidyXML error:&error];
        show("tidy", tidy.XMLString);
        printf("  tidy error: %ld\n", (long)error.code);
        NSXMLDocument *ent = [[NSXMLDocument alloc] initWithXMLString:@"<a q='&apos;'>&lt;&#65;&#x42;</a>" options:0 error:nil];
        show("entities", ent.XMLString);
        printf("  value: %s attr %s\n", ent.rootElement.stringValue.UTF8String, [ent.rootElement attributeForName:@"q"].stringValue.UTF8String);

        /* DTD */
        NSString *withDTD = @"<?xml version=\"1.0\"?><!DOCTYPE note [<!ELEMENT note (#PCDATA)><!ATTLIST note day CDATA #IMPLIED><!ENTITY who \"Ada\">]><note day=\"Mon\">&who;</note>";
        NSXMLDocument *dd = [[NSXMLDocument alloc] initWithXMLString:withDTD options:0 error:&error];
        NSXMLDTD *dtd = dd.DTD;
        printf("dtd: %s name %s, children %s\n", dtd ? "yes" : "no", dtd.name.UTF8String, kinds(dtd.children).UTF8String);
        printf("  element decl %s, entity %s value %s\n", [dtd elementDeclarationForName:@"note"].stringValue.UTF8String,
            [dtd entityDeclarationForName:@"who"].name.UTF8String, [dtd entityDeclarationForName:@"who"].stringValue.UTF8String);
        printf("  note text: %s\n", dd.rootElement.stringValue.UTF8String);
        show("  dtd XML", dtd.XMLString);
        printf("predefined amp: %s\n", [NSXMLDTD predefinedEntityDeclarationForName:@"amp"].stringValue.UTF8String);

        /* class helpers */
        printf("names: local %s prefix %s, nil prefix [%s]\n", [NSXMLNode localNameForName:@"a:b"].UTF8String,
            [NSXMLNode prefixForName:@"a:b"].UTF8String, [NSXMLNode prefixForName:@"b"].UTF8String);
        printf("predefined namespace xml: %s\n", [NSXMLNode predefinedNamespaceForPrefix:@"xml"].stringValue.UTF8String);
        NSXMLNode *ns = [NSXMLNode namespaceWithName:@"p" stringValue:@"urn:p"];
        printf("namespace node: kind %lu %s\n", (unsigned long)ns.kind, ns.XMLString.UTF8String);
        NSXMLNode *text = [[NSXMLNode alloc] initWithKind:NSXMLTextKind];
        text.objectValue = @42;
        printf("object value: %s %s\n", text.stringValue.UTF8String, [text.objectValue description].UTF8String);
        printf("canonical: %s\n", [[[NSXMLDocument alloc] initWithXMLString:@"<a b='2'  a='1'><c/></a>" options:0 error:nil]
                                         XMLStringWithOptions:NSXMLNodePreserveAll | NSXMLNodeCompactEmptyElement].UTF8String);
        printf("canonical form: %s\n", [[[[NSXMLDocument alloc] initWithXMLString:@"<a b='2'  a='1'><c/></a>" options:0 error:nil] canonicalXMLStringPreservingComments:NO] UTF8String]);
    }
    return 0;
}
