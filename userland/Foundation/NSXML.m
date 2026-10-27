/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSXMLNode, NSXMLElement, NSXMLDocument, NSXMLDTD and NSXMLDTDNode: an XML tree of
 * Finch's own, read with libxml2 (as Apple's is: parse errors carry libxml2's codes)
 * and written by Finch to Apple's rules, measured with xml-test.m:
 *
 *  - Whitespace-only text is dropped when reading unless NSXMLNodePreserveWhitespace;
 *    CDATA becomes text unless NSXMLNodePreserveCDATA; entities are replaced.
 *  - A read document has a declaration: version 1.0 and UTF-8 unless its declaration
 *    says otherwise, and standalone="yes" whenever it had a declaration that didn't
 *    say "no". A made document writes one only once given a version, encoding or
 *    standalone flag.
 *  - Elements are written <a></a> when empty (<a/> with
 *    NSXMLNodeCompactEmptyElement, or as read with NSXMLNodePreserveEmptyElements);
 *    namespaces come before attributes; text escapes & < >, attributes " as well.
 *  - Pretty printing puts a child on a new line, indented four spaces per level below
 *    the root element, unless it follows text; an element holding only text stays on
 *    one line, and its end tag goes on a new line only after a non-text child.
 *  - HTML documents write no declaration and void elements without end tags; XHTML
 *    documents write empty elements as <br />.
 *
 * XPath runs on a libxml2 copy of the tree, its results mapped back to these nodes;
 * XQuery takes the XPath subset. XSLT needs libxslt, which Finch doesn't build yet.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <libxml/parser.h>
#include <libxml/parserInternals.h>
#include <libxml/tree.h>
#include <libxml/xpath.h>
#include <libxml/xpathInternals.h>
#include <libxml/valid.h>
#include <libxml/HTMLparser.h>
#include <libxml/xmlerror.h>

#pragma mark - Node storage

/* What every node keeps beyond the header's ivars (_parent, _objectValue, _kind). */
@interface NSXMLNode () {
@package
    NSString *_fname;          /* element, attribute, namespace (prefix), PI, DTD and DTD node names */
    NSString *_fURI;           /* element and attribute namespace URIs */
    NSMutableArray *_fchildren; /* document, element and DTD children */
    NSXMLNodeKind _fkind;
    NSXMLNodeOptions _foptions;
    unichar _fquote; /* an attribute's quote as read (NSXMLNodePreserveQuotes) */
    BOOL _fhadChildren; /* (Apple's children array exists from the first child on) */
}
@end

/* Apple's class for attributes, namespaces and processing instructions. */
@interface NSXMLNamedNode : NSXMLNode
@end
@implementation NSXMLNamedNode
@end

@interface NSXMLElement () {
@package
    NSMutableArray *_fattributes, *_fnamespaces;
    BOOL _fwasEmpty; /* read as <a/> (NSXMLNodePreserveEmptyElements) */
}
@end

@interface NSXMLDocument () {
@package
    NSString *_fMIME;
    BOOL _fhasDecl, _fquotesAssigned;
    NSData *_fsource; /* what it was read from: attributes' quotes, when output asks to keep them */
}
@end

@interface NSXMLDTD () {
@package
    NSString *_fpublicID, *_fsystemID;
}
@end

@interface NSXMLNode (FinchXPath)
- (NSArray *)_finchEvaluate:(NSString *)expression nodesOnly:(BOOL)nodesOnly error:(NSError **)error;
- (void)_finchWrite:(NSMutableString *)out options:(NSXMLNodeOptions)options contentKind:(NSXMLDocumentContentKind)contentKind;
- (void)_finchCopyExtrasInto:(NSXMLNode *)copy zone:(NSZone *)zone;
@end

static void assign_quotes(NSXMLNode *node, NSString *source, NSUInteger *cursor);

@interface NSXMLDocument (FinchQuotes)
- (void)_finchAssignQuotes;
@end

@interface NSXMLDTD (FinchWriting)
- (void)_finchWriteDoctype:(NSMutableString *)out options:(NSXMLNodeOptions)options contentKind:(NSXMLDocumentContentKind)contentKind;
@end

static void raise_has_parent(NSXMLNode *child)
{
    [NSException raise:NSInternalInconsistencyException
                format:@"Cannot add a child that has a parent; detach or copy first"];
}

/* Apple's range errors here are its children array's, with its messages. */
static void raise_out_of_bounds(const char *method, NSUInteger index, NSUInteger count, BOOL inserting)
{
    NSUInteger bound = inserting ? count : count - 1;
    if (count == 0 && !inserting)
        [NSException raise:NSRangeException format:@"*** -[__NSArrayM %s]: index %lu beyond bounds for empty array", method, (unsigned long)index];
    if (count == 0)
        [NSException raise:NSRangeException format:@"*** -[__NSArrayM %s]: index %lu beyond bounds for empty array", method, (unsigned long)index];
    [NSException raise:NSRangeException format:@"*** -[__NSArrayM %s]: index %lu beyond bounds [0 .. %lu]", method, (unsigned long)index,
                       (unsigned long)bound];
}

static BOOL is_container(NSXMLNodeKind k)
{
    return k == NSXMLDocumentKind || k == NSXMLElementKind || k == NSXMLDTDKind;
}

static NSString *xml_escape(NSString *s, BOOL attribute, unichar quote);

#pragma mark - NSXMLNode

@implementation NSXMLNode

+ (Class)_finchClassForKind:(NSXMLNodeKind)kind
{
    switch (kind) {
    case NSXMLDocumentKind: return [NSXMLDocument class];
    case NSXMLElementKind: return [NSXMLElement class];
    case NSXMLDTDKind: return [NSXMLDTD class];
    case NSXMLEntityDeclarationKind:
    case NSXMLAttributeDeclarationKind:
    case NSXMLElementDeclarationKind:
    case NSXMLNotationDeclarationKind: return [NSXMLDTDNode class];
    case NSXMLAttributeKind:
    case NSXMLNamespaceKind:
    case NSXMLProcessingInstructionKind: return [NSXMLNamedNode class];
    default: return [NSXMLNode class];
    }
}

- (instancetype)init
{
    return [self initWithKind:NSXMLInvalidKind options:NSXMLNodeOptionsNone];
}

- (instancetype)initWithKind:(NSXMLNodeKind)kind
{
    return [self initWithKind:kind options:NSXMLNodeOptionsNone];
}

/* (a kind with its own class gets an object of that class, as Apple's) */
- (instancetype)initWithKind:(NSXMLNodeKind)kind options:(NSXMLNodeOptions)options
{
    Class want = [NSXMLNode _finchClassForKind:kind];
    if (![self isKindOfClass:want]) {
        [self release];
        return [[want alloc] initWithKind:kind options:options];
    }
    if ((self = [super init])) {
        _fkind = kind;
        _foptions = options;
        if (is_container(kind))
            _fchildren = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)dealloc
{
    for (NSXMLNode *c in _fchildren)
        c->_parent = nil;
    [_fchildren release];
    [_fname release];
    [_fURI release];
    [_objectValue release];
    [super dealloc];
}

#pragma mark Makers

+ (id)document { return [[[NSXMLDocument alloc] init] autorelease]; }
+ (id)documentWithRootElement:(NSXMLElement *)element { return [[[NSXMLDocument alloc] initWithRootElement:element] autorelease]; }
+ (id)elementWithName:(NSString *)name { return [[[NSXMLElement alloc] initWithName:name] autorelease]; }
+ (id)elementWithName:(NSString *)name URI:(NSString *)URI { return [[[NSXMLElement alloc] initWithName:name URI:URI] autorelease]; }
+ (id)elementWithName:(NSString *)name stringValue:(NSString *)string
{
    return [[[NSXMLElement alloc] initWithName:name stringValue:string] autorelease];
}

+ (id)elementWithName:(NSString *)name children:(NSArray<NSXMLNode *> *)children attributes:(NSArray<NSXMLNode *> *)attributes
{
    NSXMLElement *e = [[[NSXMLElement alloc] initWithName:name] autorelease];
    [e setChildren:children];
    [e setAttributes:attributes];
    return e;
}

static NSXMLNode *
make_node(NSXMLNodeKind kind, NSString *name, NSString *uri, id value)
{
    NSXMLNode *n = [[[NSXMLNode alloc] initWithKind:kind] autorelease];
    n->_fname = [name copy];
    n->_fURI = [uri copy];
    n->_objectValue = [value copy];
    return n;
}

+ (id)attributeWithName:(NSString *)name stringValue:(NSString *)stringValue
{
    return make_node(NSXMLAttributeKind, name, nil, stringValue ?: @"");
}

+ (id)attributeWithName:(NSString *)name URI:(NSString *)URI stringValue:(NSString *)stringValue
{
    return make_node(NSXMLAttributeKind, name, URI, stringValue ?: @"");
}

+ (id)namespaceWithName:(NSString *)name stringValue:(NSString *)stringValue
{
    return make_node(NSXMLNamespaceKind, name ?: @"", nil, stringValue ?: @"");
}

+ (id)processingInstructionWithName:(NSString *)name stringValue:(NSString *)stringValue
{
    return make_node(NSXMLProcessingInstructionKind, name, nil, stringValue ?: @"");
}

+ (id)commentWithStringValue:(NSString *)stringValue { return make_node(NSXMLCommentKind, nil, nil, stringValue ?: @""); }
+ (id)textWithStringValue:(NSString *)stringValue { return make_node(NSXMLTextKind, nil, nil, stringValue ?: @""); }

+ (id)DTDNodeWithXMLString:(NSString *)string { return [[[NSXMLDTDNode alloc] initWithXMLString:string] autorelease]; }

+ (NSString *)localNameForName:(NSString *)name
{
    NSRange colon = [name rangeOfString:@":"];
    return colon.location == NSNotFound ? name : [name substringFromIndex:NSMaxRange(colon)];
}

+ (NSString *)prefixForName:(NSString *)name
{
    NSRange colon = [name rangeOfString:@":"];
    return colon.location == NSNotFound ? @"" : [name substringToIndex:colon.location];
}

+ (NSXMLNode *)predefinedNamespaceForPrefix:(NSString *)name
{
    static NSDictionary *known;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        known = [@{
            @"xml" : @"http://www.w3.org/XML/1998/namespace",
            @"xs" : @"http://www.w3.org/2001/XMLSchema",
            @"xsi" : @"http://www.w3.org/2001/XMLSchema-instance",
            @"fn" : @"http://www.w3.org/2003/11/xpath-functions",
            @"local" : @"http://www.w3.org/2003/11/xquery-local-functions",
        } retain];
    });
    NSString *uri = known[name];
    return uri ? [NSXMLNode namespaceWithName:name stringValue:uri] : nil;
}

#pragma mark Properties

- (NSXMLNodeKind)kind { return _fkind; }
- (NSString *)name { return _fname; }

- (void)setName:(NSString *)name
{
    if (_fkind == NSXMLTextKind || _fkind == NSXMLCommentKind || _fkind == NSXMLDocumentKind)
        return;
    [_fname autorelease];
    _fname = [name copy];
}

- (id)objectValue { return _objectValue; }

- (void)setObjectValue:(id)value
{
    if (is_container(_fkind) && _fkind != NSXMLDTDKind) {
        [self setStringValue:[self _finchStringForObject:value]];
        return;
    }
    [_objectValue autorelease];
    _objectValue = [value retain];
}

/* As Apple's: numbers in XML Schema's canonical double form (42 is 4.2E1), dates in
   ISO 8601, data in base64, everything else as it describes itself. */
- (NSString *)_finchStringForObject:(id)value
{
    if (!value)
        return @"";
    if ([value isKindOfClass:[NSString class]])
        return value;
    if ([value isKindOfClass:[NSNumber class]]) {
        if (value == (id)kCFBooleanTrue || value == (id)kCFBooleanFalse)
            return [value boolValue] ? @"true" : @"false";
        double d = [value doubleValue];
        if (d == 0)
            return @"0.0E0";
        if (isnan(d))
            return @"NaN";
        if (isinf(d))
            return d > 0 ? @"INF" : @"-INF";
        int exp = (int)floor(log10(fabs(d)));
        double mant = d / pow(10, exp);
        NSString *m = [NSString stringWithFormat:@"%.15g", mant];
        if ([m rangeOfString:@"."].location == NSNotFound)
            m = [m stringByAppendingString:@".0"];
        return [NSString stringWithFormat:@"%@E%d", m, exp];
    }
    if ([value isKindOfClass:[NSDate class]]) {
        NSISO8601DateFormatter *f = [[[NSISO8601DateFormatter alloc] init] autorelease];
        return [f stringFromDate:value];
    }
    if ([value isKindOfClass:[NSData class]])
        return [value base64EncodedStringWithOptions:0];
    return [value description];
}

- (NSString *)stringValue
{
    switch (_fkind) {
    case NSXMLDocumentKind:
    case NSXMLElementKind: {
        NSMutableString *s = [NSMutableString string];
        for (NSXMLNode *c in _fchildren)
            if (c->_fkind != NSXMLCommentKind)
                [s appendString:[c stringValue] ?: @""];
        return s;
    }
    case NSXMLDTDKind: return nil;
    default: return [self _finchStringForObject:_objectValue];
    }
}

- (void)setStringValue:(NSString *)string
{
    if (_fkind == NSXMLElementKind || _fkind == NSXMLDocumentKind) {
        for (NSXMLNode *c in _fchildren)
            c->_parent = nil;
        [_fchildren removeAllObjects];
        if ([string length]) {
            NSXMLNode *t = [NSXMLNode textWithStringValue:string];
            t->_parent = self;
            [_fchildren addObject:t];
        }
        return;
    }
    [_objectValue autorelease];
    _objectValue = [string copy];
}

/* (with resolving, the five XML entities and character references are replaced) */
- (void)setStringValue:(NSString *)string resolvingEntities:(BOOL)resolve
{
    if (resolve && string) {
        NSMutableString *m = [[string mutableCopy] autorelease];
        NSDictionary *named = @{@"&lt;" : @"<", @"&gt;" : @">", @"&quot;" : @"\"", @"&apos;" : @"'"};
        for (NSString *k in named)
            [m replaceOccurrencesOfString:k withString:named[k] options:0 range:NSMakeRange(0, [m length])];
        NSRegularExpression *refs = [NSRegularExpression regularExpressionWithPattern:@"&#(x?)([0-9A-Fa-f]+);" options:0 error:NULL];
        NSArray *matches = [refs matchesInString:m options:0 range:NSMakeRange(0, [m length])];
        for (NSTextCheckingResult *r in [matches reverseObjectEnumerator]) {
            BOOL hex = [r rangeAtIndex:1].length > 0;
            unsigned long code = strtoul([[m substringWithRange:[r rangeAtIndex:2]] UTF8String], NULL, hex ? 16 : 10);
            UTF32Char c = (UTF32Char)code;
            NSString *ch = [[[NSString alloc] initWithBytes:&c length:4 encoding:NSUTF32LittleEndianStringEncoding] autorelease];
            [m replaceCharactersInRange:r.range withString:ch ?: @""];
        }
        [m replaceOccurrencesOfString:@"&amp;" withString:@"&" options:0 range:NSMakeRange(0, [m length])];
        string = m;
    }
    [self setStringValue:string];
}

- (NSString *)URI { return _fURI; }

- (void)setURI:(NSString *)URI
{
    [_fURI autorelease];
    _fURI = [URI copy];
}

- (NSString *)localName { return _fname ? [NSXMLNode localNameForName:_fname] : nil; }

- (NSString *)prefix
{
    if (!_fname)
        return nil;
    if (_fkind == NSXMLNamespaceKind)
        return @"";
    return [NSXMLNode prefixForName:_fname];
}

#pragma mark Tree

- (NSXMLNode *)parent { return _parent; }

- (NSUInteger)index
{
    if (!_parent)
        return 0;
    NSArray *siblings = _fkind == NSXMLAttributeKind     ? ((NSXMLElement *)_parent)->_fattributes
                        : _fkind == NSXMLNamespaceKind ? ((NSXMLElement *)_parent)->_fnamespaces
                                                       : _parent->_fchildren;
    NSUInteger i = [siblings indexOfObjectIdenticalTo:self];
    return i == NSNotFound ? 0 : i;
}

- (NSUInteger)level
{
    NSUInteger n = 0;
    for (NSXMLNode *p = _parent; p; p = p->_parent)
        n++;
    return n;
}

- (NSXMLDocument *)rootDocument
{
    NSXMLNode *n = self;
    while (n->_parent)
        n = n->_parent;
    return n->_fkind == NSXMLDocumentKind ? (NSXMLDocument *)n : nil;
}

- (NSUInteger)childCount { return [_fchildren count]; }
- (NSArray<NSXMLNode *> *)children { return _fchildren ? [[_fchildren copy] autorelease] : nil; }
- (NSXMLNode *)childAtIndex:(NSUInteger)index { return index < [_fchildren count] ? _fchildren[index] : nil; }

- (NSXMLNode *)_finchSibling:(NSInteger)delta
{
    if (!_parent || _fkind == NSXMLAttributeKind || _fkind == NSXMLNamespaceKind)
        return nil;
    NSInteger i = (NSInteger)[_parent->_fchildren indexOfObjectIdenticalTo:self] + delta;
    return i >= 0 && i < (NSInteger)[_parent->_fchildren count] ? _parent->_fchildren[(NSUInteger)i] : nil;
}

- (NSXMLNode *)previousSibling { return [self _finchSibling:-1]; }
- (NSXMLNode *)nextSibling { return [self _finchSibling:1]; }

/* Document order: the first child, else the next sibling of this node or its nearest
   ancestor that has one. */
- (NSXMLNode *)nextNode
{
    if ([_fchildren count])
        return _fchildren[0];
    for (NSXMLNode *n = self; n; n = n->_parent) {
        NSXMLNode *s = [n nextSibling];
        if (s)
            return s;
    }
    return nil;
}

- (NSXMLNode *)previousNode
{
    NSXMLNode *s = [self previousSibling];
    if (!s)
        return _parent;
    while ([s->_fchildren count])
        s = [s->_fchildren lastObject];
    return s;
}

- (void)detach
{
    NSXMLNode *p = _parent;
    if (!p)
        return;
    [self retain];
    if (_fkind == NSXMLAttributeKind)
        [((NSXMLElement *)p)->_fattributes removeObjectIdenticalTo:self];
    else if (_fkind == NSXMLNamespaceKind)
        [((NSXMLElement *)p)->_fnamespaces removeObjectIdenticalTo:self];
    else
        [p->_fchildren removeObjectIdenticalTo:self];
    _parent = nil;
    [self autorelease];
}

/* An XPath to this node: each step its name and position among same-named siblings
   (text(), comment() and the like for other kinds; @name for attributes). */
- (NSString *)XPath
{
    if (_fkind == NSXMLDocumentKind)
        return @"/";
    NSString *step;
    if (_fkind == NSXMLAttributeKind)
        step = [@"@" stringByAppendingString:_fname ?: @""];
    else if (_fkind == NSXMLNamespaceKind)
        step = [NSString stringWithFormat:@"namespace::%@", _fname ?: @""];
    else {
        NSString *test = _fkind == NSXMLElementKind                 ? _fname
                         : _fkind == NSXMLTextKind                 ? @"text()"
                         : _fkind == NSXMLCommentKind              ? @"comment()"
                         : _fkind == NSXMLProcessingInstructionKind ? @"processing-instruction()"
                                                                    : @"node()";
        if (!_parent)
            return test;
        NSUInteger position = 1;
        for (NSXMLNode *s in _parent->_fchildren) {
            if (s == self)
                break;
            if (s->_fkind == _fkind && (_fkind != NSXMLElementKind || [s->_fname isEqualToString:_fname]))
                position++;
        }
        step = [NSString stringWithFormat:@"%@[%lu]", test, (unsigned long)position];
    }
    if (!_parent)
        return step;
    NSString *above = [_parent XPath];
    return [above hasSuffix:@"/"] ? [above stringByAppendingString:step] : [NSString stringWithFormat:@"%@/%@", above, step];
}

#pragma mark Children (documents, elements, DTDs)

- (void)_finchCheckChild:(NSXMLNode *)child { [self _finchCheckChild:child replacing:nil]; }

- (void)_finchCheckChild:(NSXMLNode *)child replacing:(NSXMLNode *)replaced
{
    if (!child)
        [NSException raise:NSInvalidArgumentException format:@"*** -[%@ addChild:]: nil child", [self class]];
    if (child->_parent)
        raise_has_parent(child);
    if (_fkind == NSXMLDocumentKind && [child kind] == NSXMLElementKind)
        for (NSXMLNode *c in _fchildren)
            if (c != replaced && c->_fkind == NSXMLElementKind)
                [NSException raise:NSInternalInconsistencyException format:@"Cannot add a second element to a document"];
    /* (as Apple's: what an element may hold) */
    if ([self kind] == NSXMLElementKind) {
        NSXMLNodeKind k = [child kind];
        if (k != NSXMLTextKind && k != NSXMLElementKind && k != NSXMLProcessingInstructionKind && k != NSXMLCommentKind)
            [NSException raise:NSInternalInconsistencyException
                        format:@"Elements can only have text, elements, processing instructions, and comments as children"];
    }
}

- (void)insertChild:(NSXMLNode *)child atIndex:(NSUInteger)index
{
    if (index > [_fchildren count])
        raise_out_of_bounds("insertObject:atIndex:", index, [_fchildren count], YES);
    [self _finchCheckChild:child];
    [_fchildren insertObject:child atIndex:index];
    child->_parent = self;
    _fhadChildren = YES;
}

- (void)insertChildren:(NSArray<NSXMLNode *> *)children atIndex:(NSUInteger)index
{
    for (NSXMLNode *c in children)
        [self insertChild:c atIndex:index++];
}

- (void)addChild:(NSXMLNode *)child { [self insertChild:child atIndex:[_fchildren count]]; }

/* As Apple's: an index past the end is ignored, the one at the end raises, and a node
   that never had children ignores both. */
- (void)removeChildAtIndex:(NSUInteger)index
{
    if (!_fhadChildren || index > [_fchildren count])
        return;
    if (index == [_fchildren count])
        raise_out_of_bounds("objectAtIndex:", index, [_fchildren count], NO);
    NSXMLNode *c = [_fchildren objectAtIndex:index];
    c->_parent = nil;
    [_fchildren removeObjectAtIndex:index];
}

- (void)setChildren:(NSArray<NSXMLNode *> *)children
{
    while ([_fchildren count])
        [self removeChildAtIndex:[_fchildren count] - 1];
    for (NSXMLNode *c in children)
        [self addChild:c];
}

/* Apple's: a removal, then an insertion where it was. */
- (void)replaceChildAtIndex:(NSUInteger)index withNode:(NSXMLNode *)node
{
    [self _finchCheckChild:node replacing:index < [_fchildren count] ? [_fchildren objectAtIndex:index] : nil];
    [self removeChildAtIndex:index];
    if (index > [_fchildren count])
        raise_out_of_bounds("insertObject:atIndex:", index, [_fchildren count], NO);
    [self insertChild:node atIndex:index];
}

#pragma mark Copying

- (id)copyWithZone:(NSZone *)zone
{
    NSXMLNode *c = [[[self class] allocWithZone:zone] initWithKind:_fkind options:_foptions];
    c->_fname = [_fname copy];
    c->_fURI = [_fURI copy];
    c->_objectValue = [_objectValue copy];
    for (NSXMLNode *child in _fchildren) {
        NSXMLNode *cc = [child copyWithZone:zone];
        [c->_fchildren addObject:cc];
        cc->_parent = c;
        [cc release];
    }
    [self _finchCopyExtrasInto:c zone:zone];
    return c;
}

- (void)_finchCopyExtrasInto:(NSXMLNode *)copy zone:(NSZone *)zone { copy->_fquote = _fquote; }

#pragma mark Output

- (NSString *)description { return [self XMLString]; }
- (NSString *)XMLString { return [self XMLStringWithOptions:NSXMLNodeOptionsNone]; }

- (NSString *)XMLStringWithOptions:(NSXMLNodeOptions)options
{
    NSMutableString *out = [NSMutableString string];
    if ((options & NSXMLNodePreserveQuotes) == NSXMLNodePreserveQuotes)
        [[self rootDocument] _finchAssignQuotes];
    [self _finchWrite:out options:options contentKind:[[self rootDocument] documentContentKind]];
    return out;
}

/* The node as XML, the output kind deciding empty elements (the document's, or XML). */
- (void)_finchWrite:(NSMutableString *)out options:(NSXMLNodeOptions)options contentKind:(NSXMLDocumentContentKind)contentKind
{
    unichar quote = (options & NSXMLNodePreserveQuotes) == NSXMLNodePreserveQuotes && _fquote ? _fquote
                    : (options & NSXMLNodeUseSingleQuotes) && !(options & NSXMLNodeUseDoubleQuotes) ? '\''
                                                                                                    : '"';
    NSString *value = [self stringValue] ?: @"";
    switch (_fkind) {
    case NSXMLTextKind:
        if ((_foptions & NSXMLNodeIsCDATA) && !(options & NSXMLNodeNeverEscapeContents))
            [out appendFormat:@"<![CDATA[%@]]>", value];
        else
            [out appendString:(options & NSXMLNodeNeverEscapeContents) ? value : xml_escape(value, NO, 0)];
        break;
    case NSXMLCommentKind: [out appendFormat:@"<!--%@-->", value]; break;
    case NSXMLProcessingInstructionKind:
        [out appendFormat:[value length] ? @"<?%@ %@?>" : @"<?%@%@?>", _fname ?: @"", value];
        break;
    case NSXMLAttributeKind:
        [out appendFormat:@"%@=%C%@%C", _fname ?: @"", quote, xml_escape(value, YES, quote), quote];
        break;
    case NSXMLNamespaceKind:
        if ([_fname length])
            [out appendFormat:@"xmlns:%@=%C%@%C", _fname, quote, xml_escape(value, YES, quote), quote];
        else
            [out appendFormat:@"xmlns=%C%@%C", quote, xml_escape(value, YES, quote), quote];
        break;
    default: break;
    }
}

- (NSString *)canonicalXMLStringPreservingComments:(BOOL)comments
{
    NSMutableString *out = [NSMutableString string];
    [self _finchCanonical:out comments:comments];
    return out;
}

- (void)_finchCanonical:(NSMutableString *)out comments:(BOOL)comments
{
    if (_fkind == NSXMLCommentKind) {
        if (comments)
            [out appendString:[self XMLString]];
        return;
    }
    if (_fkind == NSXMLDocumentKind) {
        for (NSXMLNode *c in _fchildren)
            if (c->_fkind != NSXMLDTDKind)
                [c _finchCanonical:out comments:comments];
        return;
    }
    switch (_fkind) {
    case NSXMLElementKind: {
        /* (C14N: namespaces then attributes, each sorted; no empty-element shorthand) */
        NSXMLElement *e = (NSXMLElement *)self;
        [out appendFormat:@"<%@", _fname ?: @""];
        NSSortDescriptor *byName = [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES];
        for (NSXMLNode *n in [e->_fnamespaces sortedArrayUsingDescriptors:@[ byName ]])
            [out appendFormat:@" %@", [n XMLStringWithOptions:NSXMLNodeUseDoubleQuotes]];
        for (NSXMLNode *a in [e->_fattributes sortedArrayUsingDescriptors:@[ byName ]])
            [out appendFormat:@" %@=\"%@\"", [a name], xml_escape([a stringValue], YES, '"')];
        [out appendString:@">"];
        for (NSXMLNode *c in _fchildren)
            [c _finchCanonical:out comments:comments];
        [out appendFormat:@"</%@>", _fname ?: @""];
        break;
    }
    default: [out appendString:[self XMLStringWithOptions:NSXMLNodeUseDoubleQuotes]]; break;
    }
}

#pragma mark XPath and XQuery

- (NSArray<__kindof NSXMLNode *> *)nodesForXPath:(NSString *)xpath error:(NSError **)error
{
    return [self _finchEvaluate:xpath nodesOnly:YES error:error];
}

- (NSArray *)objectsForXQuery:(NSString *)xquery constants:(NSDictionary<NSString *, id> *)constants error:(NSError **)error
{
    return [self _finchEvaluate:xquery nodesOnly:NO error:error];
}

- (NSArray *)objectsForXQuery:(NSString *)xquery error:(NSError **)error
{
    return [self _finchEvaluate:xquery nodesOnly:NO error:error];
}

@end

#pragma mark - Escaping

/* & < > in text; quotes too in attribute values (the quote in use; " always when it's
   the one), newlines and tabs left as they are, as Apple's. */
static NSString *
xml_escape(NSString *s, BOOL attribute, unichar quote)
{
    if (!s)
        return @"";
    NSMutableString *out = [NSMutableString stringWithCapacity:[s length]];
    NSUInteger n = [s length];
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [s characterAtIndex:i];
        switch (c) {
        case '&': [out appendString:@"&amp;"]; break;
        case '<': [out appendString:@"&lt;"]; break;
        case '>': [out appendString:@"&gt;"]; break;
        case '"':
            if (attribute && quote == '"')
                [out appendString:@"&quot;"];
            else
                [out appendString:@"\""];
            break;
        case '\'':
            if (attribute && quote == '\'')
                [out appendString:@"&apos;"];
            else
                [out appendString:@"'"];
            break;
        default: [out appendFormat:@"%C", c]; break;
        }
    }
    return out;
}

#pragma mark - NSXMLElement

static NSSet *
html_void_elements(void)
{
    static NSSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[NSSet alloc] initWithObjects:@"area", @"base", @"basefont", @"br", @"col", @"embed", @"frame", @"hr", @"img", @"input",
                                           @"isindex", @"link", @"meta", @"param", @"source", @"track", @"wbr", nil];
    });
    return s;
}

@implementation NSXMLElement

- (instancetype)initWithKind:(NSXMLNodeKind)kind options:(NSXMLNodeOptions)options
{
    if ((self = [super initWithKind:NSXMLElementKind options:options])) {
        _fattributes = [[NSMutableArray alloc] init];
        _fnamespaces = [[NSMutableArray alloc] init];
    }
    return self;
}

- (instancetype)initWithName:(NSString *)name { return [self initWithName:name URI:nil]; }

- (instancetype)initWithName:(NSString *)name URI:(NSString *)URI
{
    if ((self = [self initWithKind:NSXMLElementKind options:NSXMLNodeOptionsNone])) {
        _fname = [name copy];
        _fURI = [URI copy];
    }
    return self;
}

- (instancetype)initWithName:(NSString *)name stringValue:(NSString *)string
{
    if ((self = [self initWithName:name]))
        [self setStringValue:string];
    return self;
}

/* The string's root element, detached from the document read. */
- (instancetype)initWithXMLString:(NSString *)string error:(NSError **)error
{
    NSError *e = nil;
    NSXMLDocument *d = [[[NSXMLDocument alloc] initWithXMLString:string options:NSXMLNodeOptionsNone error:&e] autorelease];
    NSXMLElement *root = [d rootElement];
    [self release];
    if (!root) {
        /* (an element read from nothing, or from an unfinished tag, ends early in Apple's:
           NSXMLParserPrematureDocumentEndError) */
        if (e && ([string length] == 0 || [e code] == NSXMLParserUnfinishedTagError))
            e = [NSError errorWithDomain:NSXMLParserErrorDomain code:NSXMLParserPrematureDocumentEndError userInfo:[e userInfo]];
        if (error)
            *error = e;
        return nil;
    }
    [root retain];
    [root detach];
    return root;
}

- (void)dealloc
{
    for (NSXMLNode *a in _fattributes)
        a->_parent = nil;
    for (NSXMLNode *n in _fnamespaces)
        n->_parent = nil;
    [_fattributes release];
    [_fnamespaces release];
    [super dealloc];
}

- (void)_finchCopyExtrasInto:(NSXMLNode *)copy zone:(NSZone *)zone
{
    NSXMLElement *c = (NSXMLElement *)copy;
    for (NSXMLNode *a in _fattributes) {
        NSXMLNode *ac = [a copyWithZone:zone];
        [c->_fattributes addObject:ac];
        ac->_parent = c;
        [ac release];
    }
    for (NSXMLNode *n in _fnamespaces) {
        NSXMLNode *nc = [n copyWithZone:zone];
        [c->_fnamespaces addObject:nc];
        nc->_parent = c;
        [nc release];
    }
    c->_fwasEmpty = _fwasEmpty;
}

/* (an element's URI is its own, else its prefix's namespace) */
- (NSString *)URI
{
    if (_fURI)
        return _fURI;
    NSXMLNode *ns = [self resolveNamespaceForName:_fname];
    return [ns stringValue];
}

#pragma mark Elements

- (NSArray<NSXMLElement *> *)elementsForName:(NSString *)name
{
    NSMutableArray *out = [NSMutableArray array];
    for (NSXMLNode *c in _fchildren)
        if (c->_fkind == NSXMLElementKind && ([c->_fname isEqualToString:name] || ([[c localName] isEqualToString:name] && ![[c prefix] length])))
            [out addObject:c];
    return out;
}

- (NSArray<NSXMLElement *> *)elementsForLocalName:(NSString *)localName URI:(NSString *)URI
{
    NSMutableArray *out = [NSMutableArray array];
    for (NSXMLNode *c in _fchildren)
        if (c->_fkind == NSXMLElementKind && [[c localName] isEqualToString:localName] &&
            ([c URI] == URI || [[c URI] isEqualToString:URI]))
            [out addObject:c];
    return out;
}

#pragma mark Attributes

- (NSArray<NSXMLNode *> *)attributes { return [_fattributes count] ? [[_fattributes copy] autorelease] : nil; }

- (void)addAttribute:(NSXMLNode *)attribute
{
    if (!attribute)
        return;
    /* (Apple's takes the node as its own before finding it isn't an attribute: it's left
       with this element as its parent) */
    if ([attribute kind] != NSXMLAttributeKind) {
        if (!attribute->_parent)
            attribute->_parent = self;
        [NSException raise:NSInternalInconsistencyException format:@"Not an attribute"];
    }
    if (attribute->_parent)
        raise_has_parent(attribute);
    /* (an attribute of the same name is replaced) */
    for (NSUInteger i = 0; i < [_fattributes count]; i++)
        if ([[_fattributes[i] name] isEqualToString:[attribute name]]) {
            ((NSXMLNode *)_fattributes[i])->_parent = nil;
            [_fattributes removeObjectAtIndex:i];
            break;
        }
    [_fattributes addObject:attribute];
    attribute->_parent = self;
}

- (void)removeAttributeForName:(NSString *)name
{
    for (NSUInteger i = 0; i < [_fattributes count]; i++)
        if ([[_fattributes[i] name] isEqualToString:name]) {
            ((NSXMLNode *)_fattributes[i])->_parent = nil;
            [_fattributes removeObjectAtIndex:i];
            return;
        }
}

- (void)setAttributes:(NSArray<NSXMLNode *> *)attributes
{
    for (NSXMLNode *a in _fattributes)
        a->_parent = nil;
    [_fattributes removeAllObjects];
    for (NSXMLNode *a in attributes)
        [self addAttribute:a];
}

- (void)setAttributesWithDictionary:(NSDictionary<NSString *, NSString *> *)attributes
{
    NSMutableArray *list = [NSMutableArray array];
    for (NSString *k in attributes)
        [list addObject:[NSXMLNode attributeWithName:k stringValue:[attributes[k] description]]];
    [self setAttributes:list];
}

- (void)setAttributesAsDictionary:(NSDictionary *)attributes { [self setAttributesWithDictionary:attributes]; }

- (NSXMLNode *)attributeForName:(NSString *)name
{
    for (NSXMLNode *a in _fattributes)
        if ([[a name] isEqualToString:name])
            return a;
    return nil;
}

- (NSXMLNode *)attributeForLocalName:(NSString *)localName URI:(NSString *)URI
{
    for (NSXMLNode *a in _fattributes) {
        NSString *uri = [a URI] ?: [[self resolveNamespaceForName:[a name]] stringValue];
        if ([[a localName] isEqualToString:localName] && (uri == URI || [uri isEqualToString:URI]))
            return a;
    }
    return nil;
}

#pragma mark Namespaces

- (NSArray<NSXMLNode *> *)namespaces { return [[_fnamespaces copy] autorelease]; }

- (void)addNamespace:(NSXMLNode *)aNamespace
{
    if (!aNamespace)
        return;
    if ([aNamespace kind] != NSXMLNamespaceKind)
        [NSException raise:NSInternalInconsistencyException format:@"Not a namespace"];
    if (aNamespace->_parent)
        raise_has_parent(aNamespace);
    [self removeNamespaceForPrefix:[aNamespace name] ?: @""];
    [_fnamespaces addObject:aNamespace];
    aNamespace->_parent = self;
}

- (void)removeNamespaceForPrefix:(NSString *)name
{
    for (NSUInteger i = 0; i < [_fnamespaces count]; i++)
        if ([([_fnamespaces[i] name] ?: @"") isEqualToString:name ?: @""]) {
            ((NSXMLNode *)_fnamespaces[i])->_parent = nil;
            [_fnamespaces removeObjectAtIndex:i];
            return;
        }
}

- (void)setNamespaces:(NSArray<NSXMLNode *> *)namespaces
{
    for (NSXMLNode *n in _fnamespaces)
        n->_parent = nil;
    [_fnamespaces removeAllObjects];
    for (NSXMLNode *n in namespaces)
        [self addNamespace:n];
}

- (NSXMLNode *)namespaceForPrefix:(NSString *)name
{
    for (NSXMLNode *n in _fnamespaces)
        if ([([n name] ?: @"") isEqualToString:name ?: @""])
            return n;
    return nil;
}

/* The namespace a prefixed name's prefix stands for, here or above (the default one
   for an unprefixed name), else a predefined one. */
- (NSXMLNode *)resolveNamespaceForName:(NSString *)name
{
    NSString *prefix = [NSXMLNode prefixForName:name ?: @""];
    for (NSXMLNode *n = self; n; n = n->_parent) {
        if (n->_fkind != NSXMLElementKind)
            continue;
        NSXMLNode *ns = [(NSXMLElement *)n namespaceForPrefix:prefix];
        if (ns)
            return ns;
    }
    return [prefix length] ? [NSXMLNode predefinedNamespaceForPrefix:prefix] : nil;
}

- (NSString *)resolvePrefixForNamespaceURI:(NSString *)namespaceURI
{
    for (NSXMLNode *n = self; n; n = n->_parent) {
        if (n->_fkind != NSXMLElementKind)
            continue;
        for (NSXMLNode *ns in ((NSXMLElement *)n)->_fnamespaces)
            if ([[ns stringValue] isEqualToString:namespaceURI])
                return [ns name];
    }
    return nil;
}

#pragma mark Text

/* Runs of text joined into one node (CDATA kept apart when asked). */
- (void)normalizeAdjacentTextNodesPreservingCDATA:(BOOL)preserve
{
    for (NSUInteger i = 0; i < [_fchildren count];) {
        NSXMLNode *c = _fchildren[i];
        if (c->_fkind == NSXMLElementKind)
            [(NSXMLElement *)c normalizeAdjacentTextNodesPreservingCDATA:preserve];
        if (c->_fkind == NSXMLTextKind && i + 1 < [_fchildren count]) {
            NSXMLNode *d = _fchildren[i + 1];
            BOOL cdata = (c->_foptions | d->_foptions) & NSXMLNodeIsCDATA;
            if (d->_fkind == NSXMLTextKind && !(preserve && cdata)) {
                [c setStringValue:[[c stringValue] stringByAppendingString:[d stringValue]]];
                [self removeChildAtIndex:i + 1];
                continue;
            }
        }
        if (c->_fkind == NSXMLTextKind && ![[c stringValue] length]) {
            [self removeChildAtIndex:i];
            continue;
        }
        i++;
    }
}

#pragma mark Output

/* (NSXMLNodePreserveEmptyElements is both the expand and compact bits: as read, then) */
static BOOL
compact_empty(NSXMLNodeOptions options, NSXMLNodeOptions readWith, BOOL wasEmpty)
{
    if ((options & NSXMLNodePreserveEmptyElements) == NSXMLNodePreserveEmptyElements ||
        (readWith & NSXMLNodePreserveEmptyElements) == NSXMLNodePreserveEmptyElements)
        return wasEmpty;
    return (options & NSXMLNodeCompactEmptyElement) != 0;
}

static NSString *
indent_for(NSUInteger level)
{
    NSUInteger n = level > 1 ? 4 * (level - 1) : 0;
    return [@"" stringByPaddingToLength:n withString:@" " startingAtIndex:0];
}

- (void)_finchWrite:(NSMutableString *)out options:(NSXMLNodeOptions)options contentKind:(NSXMLDocumentContentKind)contentKind
{
    BOOL pretty = (options & NSXMLNodePrettyPrint) != 0;
    /* (as Apple's: an element without a name writes no tags) */
    if (!_fname) {
        for (NSXMLNode *c in _fchildren)
            [out appendString:[c XMLStringWithOptions:options]];
        return;
    }
    [out appendFormat:@"<%@", _fname];
    for (NSXMLNode *n in _fnamespaces) {
        [out appendString:@" "];
        [n _finchWrite:out options:options contentKind:contentKind];
    }
    for (NSXMLNode *a in _fattributes) {
        [out appendString:@" "];
        [a _finchWrite:out options:options contentKind:contentKind];
    }
    if (![_fchildren count]) {
        NSString *lower = [_fname lowercaseString];
        if (contentKind == NSXMLDocumentHTMLKind && [html_void_elements() containsObject:lower])
            [out appendString:@">"];
        else if (contentKind == NSXMLDocumentXHTMLKind && [html_void_elements() containsObject:lower])
            [out appendString:@" />"];
        else if (compact_empty(options, _foptions, _fwasEmpty))
            [out appendString:@"/>"];
        else
            [out appendFormat:@"></%@>", _fname ?: @""];
        return;
    }
    [out appendString:@">"];
    BOOL onlyText = YES;
    for (NSXMLNode *c in _fchildren)
        onlyText = onlyText && c->_fkind == NSXMLTextKind;
    NSXMLNode *previous = nil;
    for (NSXMLNode *c in _fchildren) {
        if (pretty && !onlyText) {
            BOOL breakLine = previous ? previous->_fkind != NSXMLTextKind : c->_fkind != NSXMLTextKind;
            if (breakLine)
                [out appendFormat:@"\n%@", indent_for([c level])];
        }
        [c _finchWrite:out options:options contentKind:contentKind];
        previous = c;
    }
    if (pretty && !onlyText && [(NSXMLNode *)[_fchildren lastObject] kind] != NSXMLTextKind)
        [out appendFormat:@"\n%@", indent_for([self level])];
    [out appendFormat:@"</%@>", _fname ?: @""];
}

@end

#pragma mark - NSXMLDocument

@implementation NSXMLDocument

+ (Class)replacementClassForClass:(Class)cls { return cls; }

- (instancetype)init
{
    return [self initWithKind:NSXMLDocumentKind options:NSXMLNodeOptionsNone];
}

- (instancetype)initWithKind:(NSXMLNodeKind)kind options:(NSXMLNodeOptions)options
{
    return [super initWithKind:NSXMLDocumentKind options:options];
}

- (instancetype)initWithRootElement:(NSXMLElement *)element
{
    if ((self = [self init]) && element)
        [self setRootElement:element];
    return self;
}

- (void)dealloc
{
    [_encoding release];
    [_version release];
    [_fMIME release];
    [_fsource release];
    [super dealloc];
}

/* (the quotes as read, found the first time output asks for them) */
- (void)_finchAssignQuotes
{
    if (_fquotesAssigned || !_fsource)
        return;
    _fquotesAssigned = YES;
    NSString *source = [[[NSString alloc] initWithData:_fsource encoding:NSUTF8StringEncoding] autorelease];
    NSUInteger cursor = 0;
    if (source)
        assign_quotes(self, source, &cursor);
}

- (void)_finchCopyExtrasInto:(NSXMLNode *)copy zone:(NSZone *)zone
{
    NSXMLDocument *c = (NSXMLDocument *)copy;
    c->_encoding = [_encoding copy];
    c->_version = [_version copy];
    c->_fMIME = [_fMIME copy];
    c->_standalone = _standalone;
    c->_contentKind = _contentKind;
    c->_fhasDecl = _fhasDecl;
}

- (NSString *)characterEncoding { return _encoding; }
- (void)setCharacterEncoding:(NSString *)encoding
{
    [_encoding autorelease];
    _encoding = [encoding length] ? [encoding copy] : nil;
    if (encoding) _fhasDecl = YES;
}
- (NSString *)version { return _version; }
- (void)setVersion:(NSString *)version
{
    if (version && ![version length])
        return;
    [_version autorelease];
    _version = [version copy];
    if (version) _fhasDecl = YES;
}
- (BOOL)isStandalone { return _standalone; }
- (void)setStandalone:(BOOL)standalone { _standalone = standalone; if (standalone) _fhasDecl = YES; }
- (NSXMLDocumentContentKind)documentContentKind { return _contentKind; }
- (void)setDocumentContentKind:(NSXMLDocumentContentKind)kind { _contentKind = kind; }
- (NSString *)MIMEType { return _fMIME; }
- (void)setMIMEType:(NSString *)MIMEType
{
    [_fMIME autorelease];
    _fMIME = [MIMEType copy];
}

- (NSXMLDTD *)DTD
{
    for (NSXMLNode *c in _fchildren)
        if (c->_fkind == NSXMLDTDKind)
            return (NSXMLDTD *)c;
    return nil;
}

- (void)setDTD:(NSXMLDTD *)DTD
{
    NSXMLDTD *old = [self DTD];
    if (old)
        [old detach];
    if (DTD)
        [self insertChild:DTD atIndex:0];
}

- (NSXMLElement *)rootElement
{
    for (NSXMLNode *c in _fchildren)
        if (c->_fkind == NSXMLElementKind)
            return (NSXMLElement *)c;
    return nil;
}

/* (Apple's: the root element replaces all the document's children) */
- (void)setRootElement:(NSXMLElement *)root
{
    [self setChildren:root ? @[ root ] : nil];
}

- (NSString *)stringValue { return [[self rootElement] stringValue]; }

- (NSString *)XMLStringWithOptions:(NSXMLNodeOptions)options
{
    NSMutableString *out = [NSMutableString string];
    if ((options & NSXMLNodePreserveQuotes) == NSXMLNodePreserveQuotes)
        [self _finchAssignQuotes];
    [self _finchWrite:out options:options contentKind:_contentKind];
    return out;
}

- (void)_finchWrite:(NSMutableString *)out options:(NSXMLNodeOptions)options contentKind:(NSXMLDocumentContentKind)contentKind
{
    BOOL pretty = (options & NSXMLNodePrettyPrint) != 0;
    BOOL wroteSomething = NO;
    BOOL declares = contentKind != NSXMLDocumentHTMLKind && contentKind != NSXMLDocumentTextKind &&
                    (_fhasDecl || _version || _encoding || _standalone);
    if (declares) {
        [out appendFormat:@"<?xml version=\"%@\"", _version ?: @"1.0"];
        if (_encoding)
            [out appendFormat:@" encoding=\"%@\"", _encoding];
        if (_standalone)
            [out appendString:@" standalone=\"yes\""];
        [out appendString:@"?>"];
        wroteSomething = YES;
    }
    BOOL separatesDTD = [self DTD] != nil;
    for (NSXMLNode *c in _fchildren) {
        if ((pretty || separatesDTD) && wroteSomething)
            [out appendString:@"\n"];
        if (c->_fkind == NSXMLDTDKind)
            [(NSXMLDTD *)c _finchWriteDoctype:out options:options contentKind:contentKind];
        else
            [c _finchWrite:out options:options contentKind:contentKind];
        wroteSomething = YES;
    }
}

- (NSData *)XMLData { return [self XMLDataWithOptions:NSXMLNodeOptionsNone]; }

- (NSData *)XMLDataWithOptions:(NSXMLNodeOptions)options
{
    NSString *s = [self XMLStringWithOptions:options];
    CFStringEncoding cf = _encoding ? CFStringConvertIANACharSetNameToEncoding((CFStringRef)_encoding) : kCFStringEncodingUTF8;
    NSStringEncoding enc = cf == kCFStringEncodingInvalidId ? NSUTF8StringEncoding : CFStringConvertEncodingToNSStringEncoding(cf);
    return [s dataUsingEncoding:enc allowLossyConversion:YES];
}

/* (a document read from a string is in UTF-8, as Apple's, whatever its declaration says) */
- (instancetype)initWithXMLString:(NSString *)string options:(NSXMLNodeOptions)mask error:(NSError **)error
{
    self = [self initWithData:[string dataUsingEncoding:NSUTF8StringEncoding] options:mask error:error];
    if (self && !_encoding)
        _encoding = @"UTF-8";
    return self;
}

- (instancetype)initWithContentsOfURL:(NSURL *)url options:(NSXMLNodeOptions)mask error:(NSError **)error
{
    NSData *d = [NSData dataWithContentsOfURL:url options:0 error:error];
    if (!d) {
        [self release];
        return nil;
    }
    return [self initWithData:d options:mask error:error];
}

/* (no XSLT processor yet: libxslt isn't built) */
- (id)objectByApplyingXSLT:(NSData *)xslt arguments:(NSDictionary<NSString *, NSString *> *)arguments error:(NSError **)error
{
    if (error)
        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFeatureUnsupportedError
                                 userInfo:@{NSLocalizedDescriptionKey : @"XSLT isn't available"}];
    return nil;
}

- (id)objectByApplyingXSLTString:(NSString *)xslt arguments:(NSDictionary<NSString *, NSString *> *)arguments error:(NSError **)error
{
    return [self objectByApplyingXSLT:[xslt dataUsingEncoding:NSUTF8StringEncoding] arguments:arguments error:error];
}

- (id)objectByApplyingXSLTAtURL:(NSURL *)xsltURL arguments:(NSDictionary<NSString *, NSString *> *)argument error:(NSError **)error
{
    return [self objectByApplyingXSLT:[NSData dataWithContentsOfURL:xsltURL] arguments:argument error:error];
}

@end

#pragma mark - NSXMLDTD

@implementation NSXMLDTD

- (instancetype)init { return [self initWithKind:NSXMLDTDKind options:NSXMLNodeOptionsNone]; }

- (instancetype)initWithKind:(NSXMLNodeKind)kind options:(NSXMLNodeOptions)options
{
    return [super initWithKind:NSXMLDTDKind options:options];
}

- (void)dealloc
{
    [_fpublicID release];
    [_fsystemID release];
    [super dealloc];
}

- (void)_finchCopyExtrasInto:(NSXMLNode *)copy zone:(NSZone *)zone
{
    ((NSXMLDTD *)copy)->_fpublicID = [_fpublicID copy];
    ((NSXMLDTD *)copy)->_fsystemID = [_fsystemID copy];
}

- (NSString *)publicID { return _fpublicID; }
- (void)setPublicID:(NSString *)publicID
{
    [_fpublicID autorelease];
    _fpublicID = [publicID copy];
}
- (NSString *)systemID { return _fsystemID; }
- (void)setSystemID:(NSString *)systemID
{
    [_fsystemID autorelease];
    _fsystemID = [systemID copy];
}

- (NSXMLDTDNode *)_finchDeclaration:(NSXMLNodeKind)kind name:(NSString *)name
{
    for (NSXMLNode *c in _fchildren)
        if (c->_fkind == kind && [c->_fname isEqualToString:name])
            return (NSXMLDTDNode *)c;
    return nil;
}

- (NSXMLDTDNode *)entityDeclarationForName:(NSString *)name { return [self _finchDeclaration:NSXMLEntityDeclarationKind name:name]; }
- (NSXMLDTDNode *)notationDeclarationForName:(NSString *)name { return [self _finchDeclaration:NSXMLNotationDeclarationKind name:name]; }
- (NSXMLDTDNode *)elementDeclarationForName:(NSString *)name { return [self _finchDeclaration:NSXMLElementDeclarationKind name:name]; }

- (NSXMLDTDNode *)attributeDeclarationForName:(NSString *)name elementName:(NSString *)elementName
{
    for (NSXMLNode *c in _fchildren)
        if (c->_fkind == NSXMLAttributeDeclarationKind && [c->_fname isEqualToString:name] &&
            [[(NSXMLDTDNode *)c notationName] isEqualToString:elementName])
            return (NSXMLDTDNode *)c;
    return nil;
}

+ (NSXMLDTDNode *)predefinedEntityDeclarationForName:(NSString *)name
{
    NSDictionary *five = @{@"lt" : @"<", @"gt" : @">", @"amp" : @"&", @"quot" : @"\"", @"apos" : @"'"};
    if (!five[name])
        return nil;
    NSXMLDTDNode *n = [[[NSXMLDTDNode alloc] initWithKind:NSXMLEntityDeclarationKind options:NSXMLNodeOptionsNone] autorelease];
    [n setName:name];
    [n setStringValue:five[name]];
    [n setDTDKind:NSXMLEntityPredefined];
    return n;
}

- (instancetype)initWithContentsOfURL:(NSURL *)url options:(NSXMLNodeOptions)mask error:(NSError **)error
{
    NSData *d = [NSData dataWithContentsOfURL:url options:0 error:error];
    if (!d) {
        [self release];
        return nil;
    }
    return [self initWithData:d options:mask error:error];
}

/* The declarations, one to a line, indented as inside a DOCTYPE. */
- (void)_finchWrite:(NSMutableString *)out options:(NSXMLNodeOptions)options contentKind:(NSXMLDocumentContentKind)contentKind
{
    for (NSXMLNode *c in _fchildren) {
        [out appendString:@"    "];
        [c _finchWrite:out options:options contentKind:contentKind];
        [out appendString:@"\n"];
    }
}

/* As a document writes it: the DOCTYPE around the declarations. */
- (void)_finchWriteDoctype:(NSMutableString *)out options:(NSXMLNodeOptions)options contentKind:(NSXMLDocumentContentKind)contentKind
{
    [out appendFormat:@"<!DOCTYPE %@", _fname ?: @""];
    if (_fpublicID)
        [out appendFormat:@" PUBLIC \"%@\" \"%@\"", _fpublicID, _fsystemID ?: @""];
    else if (_fsystemID)
        [out appendFormat:@" SYSTEM \"%@\"", _fsystemID];
    if ([_fchildren count]) {
        [out appendString:@" [\n"];
        [self _finchWrite:out options:options contentKind:contentKind];
        [out appendString:@"]"];
    }
    [out appendString:@">"];
}

@end

#pragma mark - NSXMLDTDNode

@implementation NSXMLDTDNode

/* (as Apple's: a node that isn't a declaration is of no kind and writes nothing) */
- (instancetype)init { return [self initWithKind:NSXMLInvalidKind options:NSXMLNodeOptionsNone]; }

- (instancetype)initWithKind:(NSXMLNodeKind)kind options:(NSXMLNodeOptions)options
{
    if (kind < NSXMLEntityDeclarationKind || kind > NSXMLNotationDeclarationKind)
        kind = NSXMLInvalidKind;
    return [super initWithKind:kind options:options];
}

/* A declaration read from its own markup ("<!ENTITY name "value">" and the like). */
- (instancetype)initWithXMLString:(NSString *)string
{
    NSString *wrapped = [NSString stringWithFormat:@"<!DOCTYPE d [%@]><d/>", string ?: @""];
    NSXMLDocument *doc = [[[NSXMLDocument alloc] initWithXMLString:wrapped options:NSXMLNodePreserveDTD error:NULL] autorelease];
    NSXMLNode *decl = [[[doc DTD] children] firstObject];
    [self release];
    if (!decl)
        return nil;
    [decl retain];
    [decl detach];
    return (NSXMLDTDNode *)decl;
}

- (void)dealloc
{
    [_notationName release];
    [_publicID release];
    [_systemID release];
    [super dealloc];
}

- (void)_finchCopyExtrasInto:(NSXMLNode *)copy zone:(NSZone *)zone
{
    NSXMLDTDNode *c = (NSXMLDTDNode *)copy;
    c->_DTDKind = _DTDKind;
    c->_notationName = [_notationName copy];
    c->_publicID = [_publicID copy];
    c->_systemID = [_systemID copy];
}

- (NSXMLDTDNodeKind)DTDKind { return _DTDKind; }
- (void)setDTDKind:(NSXMLDTDNodeKind)kind { _DTDKind = kind; }
- (BOOL)isExternal { return _systemID != nil; }
- (NSString *)publicID { return _publicID; }
- (void)setPublicID:(NSString *)publicID
{
    [_publicID autorelease];
    _publicID = [publicID copy];
}
- (NSString *)systemID { return _systemID; }
- (void)setSystemID:(NSString *)systemID
{
    [_systemID autorelease];
    _systemID = [systemID copy];
}
- (NSString *)notationName { return _notationName; }
- (void)setNotationName:(NSString *)notationName
{
    [_notationName autorelease];
    _notationName = [notationName copy];
}

- (void)_finchWrite:(NSMutableString *)out options:(NSXMLNodeOptions)options contentKind:(NSXMLDocumentContentKind)contentKind
{
    NSString *value = [self stringValue] ?: @"";
    switch (_fkind) {
    case NSXMLInvalidKind: break;
    case NSXMLElementDeclarationKind: [out appendFormat:@"<!ELEMENT %@ %@>", _fname, value]; break;
    case NSXMLAttributeDeclarationKind: [out appendFormat:@"<!ATTLIST %@ %@ %@>", _notationName ?: @"", _fname, value]; break;
    case NSXMLNotationDeclarationKind:
        if (_publicID)
            [out appendFormat:@"<!NOTATION %@ PUBLIC \"%@\"%@>", _fname, _publicID, _systemID ? [NSString stringWithFormat:@" \"%@\"", _systemID] : @""];
        else
            [out appendFormat:@"<!NOTATION %@ SYSTEM \"%@\">", _fname, _systemID ?: @""];
        break;
    default:
        if (_systemID && _publicID)
            [out appendFormat:@"<!ENTITY %@ PUBLIC \"%@\" \"%@\"%@>", _fname, _publicID, _systemID,
                              _notationName ? [NSString stringWithFormat:@" NDATA %@", _notationName] : @""];
        else if (_systemID)
            [out appendFormat:@"<!ENTITY %@ SYSTEM \"%@\"%@>", _fname, _systemID,
                              _notationName ? [NSString stringWithFormat:@" NDATA %@", _notationName] : @""];
        else
            [out appendFormat:@"<!ENTITY %@ \"%@\">", _fname, value];
        break;
    }
}

@end

#pragma mark - Reading with libxml2

static NSString *
str(const xmlChar *s)
{
    return s ? [NSString stringWithUTF8String:(const char *)s] : nil;
}

static NSString *
qualified(const xmlChar *name, xmlNsPtr ns)
{
    NSString *n = str(name);
    return ns && ns->prefix ? [NSString stringWithFormat:@"%s:%@", (const char *)ns->prefix, n] : n;
}

static BOOL
whitespace_only(const xmlChar *s)
{
    for (; s && *s; s++)
        if (!strchr(" \t\r\n", *s))
            return NO;
    return YES;
}

static NSString *
element_content_string(xmlElementContentPtr content)
{
    char buf[4096] = "";
    if (content)
        xmlSnprintfElementContent(buf, sizeof buf, content, 1);
    return [NSString stringWithUTF8String:buf];
}

static NSXMLNode *convert(xmlNodePtr n, NSXMLNodeOptions options);

/* The libxml2 node's children, converted and added. */
static void
convert_children(xmlNodePtr parent, NSXMLNode *into, NSXMLNodeOptions options)
{
    for (xmlNodePtr c = parent->children; c; c = c->next) {
        NSXMLNode *child = convert(c, options);
        if (child)
            [into addChild:child];
    }
}

static NSXMLNode *
convert(xmlNodePtr n, NSXMLNodeOptions options)
{
    switch (n->type) {
    case XML_ELEMENT_NODE: {
        NSXMLElement *e = [[[NSXMLElement alloc] initWithName:qualified(n->name, n->ns)] autorelease];
        e->_foptions = options & NSXMLNodePreserveEmptyElements;
        if (n->ns && n->ns->href)
            [e setURI:str(n->ns->href)];
        for (xmlNsPtr ns = n->nsDef; ns; ns = ns->next)
            [e addNamespace:[NSXMLNode namespaceWithName:str(ns->prefix) ?: @"" stringValue:str(ns->href)]];
        for (xmlAttrPtr a = n->properties; a; a = a->next) {
            xmlChar *v = xmlNodeListGetString(n->doc, a->children, 1);
            NSXMLNode *attr = [NSXMLNode attributeWithName:qualified(a->name, a->ns) stringValue:str(v) ?: @""];
            if (a->ns && a->ns->href)
                [attr setURI:str(a->ns->href)];
            xmlFree(v);
            [e addAttribute:attr];
        }
        /* (libxml2 marks <a/> as having no children and the "extra" flag unset) */
        e->_fwasEmpty = n->children == NULL && n->extra == 0;
        convert_children(n, e, options);
        if (!n->children)
            e->_fwasEmpty = YES;
        return e;
    }
    case XML_TEXT_NODE:
        if (!(options & NSXMLNodePreserveWhitespace) && whitespace_only(n->content))
            return nil;
        return [NSXMLNode textWithStringValue:str(n->content) ?: @""];
    case XML_CDATA_SECTION_NODE: {
        NSXMLNode *t = [NSXMLNode textWithStringValue:str(n->content) ?: @""];
        if (options & NSXMLNodePreserveCDATA)
            t->_foptions |= NSXMLNodeIsCDATA;
        return t;
    }
    case XML_COMMENT_NODE: return [NSXMLNode commentWithStringValue:str(n->content) ?: @""];
    case XML_PI_NODE: return [NSXMLNode processingInstructionWithName:str(n->name) stringValue:str(n->content) ?: @""];
    case XML_ENTITY_REF_NODE: {
        /* (entities replaced: their text) */
        xmlChar *v = xmlNodeGetContent(n);
        NSXMLNode *t = v ? [NSXMLNode textWithStringValue:str(v)] : nil;
        xmlFree(v);
        return t;
    }
    case XML_DTD_NODE: {
        xmlDtdPtr d = (xmlDtdPtr)n;
        NSXMLDTD *dtd = [[[NSXMLDTD alloc] init] autorelease];
        [dtd setName:str(d->name)];
        [dtd setPublicID:str(d->ExternalID)];
        [dtd setSystemID:str(d->SystemID)];
        for (xmlNodePtr c = d->children; c; c = c->next) {
            NSXMLDTDNode *decl = nil;
            if (c->type == XML_ELEMENT_DECL) {
                xmlElementPtr el = (xmlElementPtr)c;
                decl = [[[NSXMLDTDNode alloc] initWithKind:NSXMLElementDeclarationKind options:0] autorelease];
                [decl setName:str(el->name)];
                NSString *content = el->etype == XML_ELEMENT_TYPE_EMPTY ? @"EMPTY"
                                    : el->etype == XML_ELEMENT_TYPE_ANY ? @"ANY"
                                                                        : element_content_string(el->content);
                [decl setStringValue:content];
                [decl setDTDKind:el->etype == XML_ELEMENT_TYPE_EMPTY ? NSXMLElementDeclarationEmptyKind
                                 : el->etype == XML_ELEMENT_TYPE_ANY ? NSXMLElementDeclarationAnyKind
                                 : el->etype == XML_ELEMENT_TYPE_MIXED ? NSXMLElementDeclarationMixedKind
                                                                       : NSXMLElementDeclarationElementKind];
            } else if (c->type == XML_ATTRIBUTE_DECL) {
                xmlAttributePtr at = (xmlAttributePtr)c;
                decl = [[[NSXMLDTDNode alloc] initWithKind:NSXMLAttributeDeclarationKind options:0] autorelease];
                [decl setName:str(at->name)];
                [decl setNotationName:str(at->elem)];
                static const char *types[] = {"", "CDATA", "ID", "IDREF", "IDREFS", "ENTITY", "ENTITIES", "NMTOKEN", "NMTOKENS", "", "NOTATION"};
                NSMutableString *v = [NSMutableString string];
                if (at->atype == XML_ATTRIBUTE_ENUMERATION || at->atype == XML_ATTRIBUTE_NOTATION) {
                    NSMutableArray *names = [NSMutableArray array];
                    for (xmlEnumerationPtr e = at->tree; e; e = e->next)
                        [names addObject:str(e->name)];
                    [v appendFormat:@"%@(%@)", at->atype == XML_ATTRIBUTE_NOTATION ? @"NOTATION " : @"", [names componentsJoinedByString:@"|"]];
                } else
                    [v appendString:@(types[at->atype < 11 ? at->atype : 0])];
                const char *defaults[] = {"", "", "#REQUIRED", "#IMPLIED", "#FIXED"};
                if (at->def >= 2 && at->def <= 4)
                    [v appendFormat:@" %s", defaults[at->def]];
                if (at->defaultValue)
                    [v appendFormat:@" \"%s\"", (const char *)at->defaultValue];
                [decl setStringValue:v];
            } else if (c->type == XML_ENTITY_DECL) {
                xmlEntityPtr en = (xmlEntityPtr)c;
                decl = [[[NSXMLDTDNode alloc] initWithKind:NSXMLEntityDeclarationKind options:0] autorelease];
                [decl setName:str(en->name)];
                [decl setStringValue:str(en->orig ? en->content : en->content) ?: @""];
                [decl setPublicID:str(en->ExternalID)];
                [decl setSystemID:str(en->SystemID)];
                [decl setDTDKind:en->etype == XML_INTERNAL_PARAMETER_ENTITY || en->etype == XML_EXTERNAL_PARAMETER_ENTITY
                                     ? NSXMLEntityParameterKind
                                 : en->etype == XML_EXTERNAL_GENERAL_UNPARSED_ENTITY ? NSXMLEntityUnparsedKind
                                 : en->etype == XML_EXTERNAL_GENERAL_PARSED_ENTITY   ? NSXMLEntityParsedKind
                                                                                      : NSXMLEntityGeneralKind];
            }
            if (decl)
                [dtd addChild:decl];
        }
        return dtd;
    }
    default: return nil;
    }
}

/* libxml2's errors, kept instead of printed: the first one is the one reported, as
   Apple's reports it. */
static __thread xmlError first_error;
static __thread BOOL have_first;

static void
keep_error(void *context, const xmlError *error)
{
    if (!have_first && error) {
        xmlResetError(&first_error);
        xmlCopyError((xmlErrorPtr)error, &first_error);
        have_first = YES;
    }
}

static void
quiet_error(void *context, const xmlError *error) {}

static void
start_errors(void)
{
    if (have_first)
        xmlResetError(&first_error);
    have_first = NO;
    xmlResetLastError();
    xmlSetStructuredErrorFunc(NULL, (xmlStructuredErrorFunc)keep_error);
}

static const xmlError *
finish_errors(void)
{
    xmlSetStructuredErrorFunc(NULL, NULL);
    return have_first ? &first_error : NULL;
}

static NSError *
xml_error(const xmlError *e)
{
    int code = e ? e->code : 1;
    NSString *message = e && e->message ? [[NSString stringWithUTF8String:e->message] stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]]
                                        : @"The document could not be read";
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:message forKey:NSLocalizedDescriptionKey];
    if (e && e->line)
        info[@"NSXMLParserErrorLineNumber"] = @(e->line);
    return [NSError errorWithDomain:NSXMLParserErrorDomain code:code userInfo:info];
}

/* The quotes each attribute was written with: the source's start tags walked in
   document order, each attribute found in its element's tag. */
static void
assign_quotes(NSXMLNode *node, NSString *source, NSUInteger *cursor)
{
    if ([node kind] == NSXMLElementKind) {
        NSXMLElement *e = (NSXMLElement *)node;
        NSRange tag = [source rangeOfString:[@"<" stringByAppendingString:[e name] ?: @""] options:0
                                     range:NSMakeRange(*cursor, [source length] - *cursor)];
        if (tag.location != NSNotFound) {
            NSRange close = [source rangeOfString:@">" options:0 range:NSMakeRange(NSMaxRange(tag), [source length] - NSMaxRange(tag))];
            NSUInteger end = close.location == NSNotFound ? [source length] : close.location;
            NSString *inside = [source substringWithRange:NSMakeRange(NSMaxRange(tag), end - NSMaxRange(tag))];
            for (NSXMLNode *a in e->_fattributes) {
                NSString *pattern = [NSString stringWithFormat:@"(^|\\s)%@\\s*=\\s*(['\"])", [NSRegularExpression escapedPatternForString:[a name]]];
                NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:NULL];
                NSTextCheckingResult *m = [re firstMatchInString:inside options:0 range:NSMakeRange(0, [inside length])];
                if (m)
                    a->_fquote = [inside characterAtIndex:[m rangeAtIndex:2].location];
            }
            *cursor = end;
        }
    }
    for (NSXMLNode *c in node->_fchildren)
        assign_quotes(c, source, cursor);
}

@implementation NSXMLDocument (FinchReading)

/* Read by libxml2 (HTML's parser for NSXMLDocumentTidyHTML), then made into this tree;
   a parse error is NSXMLParserErrorDomain's with libxml2's code, as Apple's. */
- (instancetype)initWithData:(NSData *)data options:(NSXMLNodeOptions)mask error:(NSError **)error
{
    self = [self initWithKind:NSXMLDocumentKind options:mask];
    if (!self)
        return nil;
    if (!data) {
        [self release];
        return nil;
    }
    start_errors();
    xmlDocPtr doc;
    BOOL html = (mask & NSXMLDocumentTidyHTML) != 0;
    if (html)
        doc = htmlReadMemory([data bytes], (int)[data length], NULL, NULL, HTML_PARSE_RECOVER | HTML_PARSE_NOERROR | HTML_PARSE_NOWARNING | HTML_PARSE_NONET);
    else {
        int opts = XML_PARSE_NOENT | XML_PARSE_NONET | XML_PARSE_NOERROR | XML_PARSE_NOWARNING | XML_PARSE_NOCDATA * 0 | XML_PARSE_HUGE;
        if (mask & NSXMLDocumentTidyXML)
            opts |= XML_PARSE_RECOVER;
        if (mask & NSXMLDocumentValidate)
            opts |= XML_PARSE_DTDVALID;
        if (mask & NSXMLNodeLoadExternalEntitiesAlways)
            opts = (opts & ~XML_PARSE_NONET) | XML_PARSE_DTDLOAD;
        if (mask & NSXMLDocumentXInclude)
            opts |= XML_PARSE_XINCLUDE;
        doc = xmlReadMemory([data bytes], (int)[data length], NULL, NULL, opts);
    }
    const xmlError *problem = finish_errors();
    if (!doc || !xmlDocGetRootElement(doc) || (problem && problem->level >= XML_ERR_ERROR && !(mask & (NSXMLDocumentTidyXML | NSXMLDocumentTidyHTML)))) {
        /* (nothing to read is an empty document, as libxml2 reports it when it says) */
        if (error)
            *error = !problem && [data length] == 0
                         ? [NSError errorWithDomain:NSXMLParserErrorDomain code:NSXMLParserEmptyDocumentError
                                           userInfo:@{NSLocalizedDescriptionKey: @"Document is empty"}]
                         : xml_error(problem);
        if (doc)
            xmlFreeDoc(doc);
        [self release];
        return nil;
    }
    /* (a tidied document reports that it needed tidying, as Apple's: an internal error) */
    if (problem && error)
        *error = [NSError errorWithDomain:NSXMLParserErrorDomain code:NSXMLParserInternalError userInfo:[xml_error(problem) userInfo]];
    _version = [str(doc->version) ?: @"1.0" copy];
    _encoding = [str(doc->encoding) copy];
    /* (libxml2: -1 without a declaration, -2 with one that doesn't say; Apple's counts
       the latter as standalone) */
    _standalone = doc->standalone == 1 || doc->standalone == -2;
    _fhasDecl = YES;
    _contentKind = html ? NSXMLDocumentXHTMLKind : NSXMLDocumentXMLKind;
    for (xmlNodePtr c = doc->children; c; c = c->next) {
        if (c->type == XML_DTD_NODE && !((xmlDtdPtr)c)->children && !(mask & NSXMLNodePreserveDTD)) {
            NSXMLNode *dtd = convert(c, mask);
            [self addChild:dtd];
            continue;
        }
        NSXMLNode *n = convert(c, mask);
        if (n)
            [self addChild:n];
    }
    xmlFreeDoc(doc);
    _fsource = [data copy];
    return self;
}

@end

@implementation NSXMLDTD (FinchReading)

/* As Apple's: the declarations up to the first that can't be read (none of them, from
   data that isn't a DTD) without an error; only empty data is one. */
- (instancetype)initWithData:(NSData *)data options:(NSXMLNodeOptions)mask error:(NSError **)error
{
    if (![data length]) {
        if (error)
            *error = [NSError errorWithDomain:NSXMLParserErrorDomain code:NSXMLParserEmptyDocumentError
                                     userInfo:@{NSLocalizedDescriptionKey: @"Document is empty"}];
        [self release];
        return nil;
    }
    start_errors();
    xmlDtdPtr d = NULL;
    NSXMLDTD *converted = nil;
    xmlParserCtxtPtr ctxt = xmlNewParserCtxt();
    xmlParserInputBufferPtr buffer = ctxt ? xmlParserInputBufferCreateMem([data bytes], (int)[data length], XML_CHAR_ENCODING_NONE) : NULL;
    xmlParserInputPtr input = buffer ? xmlNewIOInputStream(ctxt, buffer, XML_CHAR_ENCODING_NONE) : NULL;
    if (input && xmlPushInput(ctxt, input) >= 0) {
        ctxt->options |= XML_PARSE_NONET;
        ctxt->inSubset = 2;
        ctxt->myDoc = xmlNewDoc((const xmlChar *)"1.0");
        ctxt->myDoc->properties = XML_DOC_INTERNAL;
        ctxt->myDoc->extSubset = xmlNewDtd(ctxt->myDoc, (const xmlChar *)"none", NULL, NULL);
        xmlParseExternalSubset(ctxt, NULL, NULL);
        d = ctxt->myDoc->extSubset;
        if (d)
            converted = [(NSXMLDTD *)convert((xmlNodePtr)d, mask) retain];
        xmlFreeDoc(ctxt->myDoc);
        ctxt->myDoc = NULL;
    } else if (buffer && !input) {
        xmlFreeParserInputBuffer(buffer);
    }
    if (ctxt)
        xmlFreeParserCtxt(ctxt);
    finish_errors();
    if (!converted && error)
        *error = xml_error(NULL);
    [self release];
    return converted;
}

@end

#pragma mark - XPath

/* This tree as libxml2's, for XPath and validation; `map` gets each libxml2 node's
   NSXMLNode. */
static xmlNodePtr build_libxml(NSXMLNode *node, xmlDocPtr doc, xmlNodePtr parent, NSMapTable *map);
static xmlDocPtr mirror(NSXMLNode *from, NSMapTable *map, xmlNodePtr *context);

static xmlNsPtr
find_ns(xmlNodePtr from, NSString *prefix)
{
    return xmlSearchNs(from->doc, from, [prefix length] ? (const xmlChar *)[prefix UTF8String] : NULL);
}

static xmlNodePtr
build_libxml(NSXMLNode *node, xmlDocPtr doc, xmlNodePtr parent, NSMapTable *map)
{
    xmlNodePtr x = NULL;
    switch ([node kind]) {
    case NSXMLElementKind: {
        NSXMLElement *e = (NSXMLElement *)node;
        x = xmlNewDocNode(doc, NULL, (const xmlChar *)[[e localName] UTF8String], NULL);
        if (parent)
            xmlAddChild(parent, x);
        else
            xmlDocSetRootElement(doc, x);
        for (NSXMLNode *ns in e->_fnamespaces)
            xmlNewNs(x, (const xmlChar *)[[ns stringValue] UTF8String], [[ns name] length] ? (const xmlChar *)[[ns name] UTF8String] : NULL);
        xmlNsPtr ns = find_ns(x, [e prefix]);
        if (!ns && [e URI])
            ns = xmlNewNs(x, (const xmlChar *)[[e URI] UTF8String], [[e prefix] length] ? (const xmlChar *)[[e prefix] UTF8String] : NULL);
        xmlSetNs(x, ns);
        for (NSXMLNode *a in e->_fattributes) {
            xmlNsPtr ans = [[a prefix] length] ? find_ns(x, [a prefix]) : NULL;
            xmlAttrPtr ax = xmlNewNsProp(x, ans, (const xmlChar *)[[a localName] UTF8String], (const xmlChar *)[[a stringValue] UTF8String]);
            [map setObject:a forKey:(id)(void *)ax];
        }
        for (NSXMLNode *c in node->_fchildren)
            build_libxml(c, doc, x, map);
        break;
    }
    case NSXMLTextKind: x = xmlNewDocText(doc, (const xmlChar *)[[node stringValue] UTF8String]); break;
    case NSXMLCommentKind: x = xmlNewDocComment(doc, (const xmlChar *)[[node stringValue] UTF8String]); break;
    case NSXMLProcessingInstructionKind:
        x = xmlNewDocPI(doc, (const xmlChar *)[[node name] UTF8String], (const xmlChar *)[[node stringValue] UTF8String]);
        break;
    default: return NULL;
    }
    if (x && [node kind] != NSXMLElementKind && parent)
        xmlAddChild(parent, x);
    if (x) {
        [map setObject:node forKey:(id)(void *)x];
        NSMapTable *reverse = [map objectForKey:(id)(void *)&mirror];
        [reverse setObject:[NSValue valueWithPointer:x] forKey:node];
    }
    return x;
}

static xmlDocPtr
mirror(NSXMLNode *from, NSMapTable *map, xmlNodePtr *context)
{
    /* (each node's libxml2 copy, kept under this function's address in the map) */
    [map setObject:[NSMapTable mapTableWithKeyOptions:NSPointerFunctionsObjectPointerPersonality valueOptions:NSPointerFunctionsStrongMemory]
            forKey:(id)(void *)&mirror];
    NSXMLNode *top = from;
    while ([top parent])
        top = [top parent];
    xmlDocPtr doc = xmlNewDoc((const xmlChar *)"1.0");
    [map setObject:top forKey:(id)(void *)doc];
    if ([top kind] == NSXMLDocumentKind) {
        for (NSXMLNode *c in top->_fchildren) {
            if ([c kind] == NSXMLElementKind)
                build_libxml(c, doc, NULL, map);
            else if ([c kind] != NSXMLDTDKind) {
                xmlNodePtr x = [c kind] == NSXMLCommentKind ? xmlNewDocComment(doc, (const xmlChar *)[[c stringValue] UTF8String])
                               : [c kind] == NSXMLProcessingInstructionKind
                                   ? xmlNewDocPI(doc, (const xmlChar *)[[c name] UTF8String], (const xmlChar *)[[c stringValue] UTF8String])
                                   : NULL;
                if (x) {
                    xmlAddChild((xmlNodePtr)doc, x);
                    [map setObject:c forKey:(id)(void *)x];
                }
            }
        }
    } else if ([top kind] == NSXMLElementKind)
        build_libxml(top, doc, NULL, map);
    *context = (xmlNodePtr)doc;
    if (from != top) {
        NSMapTable *reverse = [map objectForKey:(id)(void *)&mirror];
        NSValue *v = [reverse objectForKey:from];
        if (v)
            *context = [v pointerValue];
    }
    return doc;
}

@implementation NSXMLNode (FinchXPath)

- (NSArray *)_finchEvaluate:(NSString *)expression nodesOnly:(BOOL)nodesOnly error:(NSError **)error
{
    NSMapTable *map = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality
                                            valueOptions:NSPointerFunctionsStrongMemory];
    xmlNodePtr context = NULL;
    xmlDocPtr doc = mirror(self, map, &context);
    xmlXPathContextPtr ctx = xmlXPathNewContext(doc);
    ctx->node = context;
    ctx->error = (xmlStructuredErrorFunc)quiet_error;
    /* (the tree's prefixes are known to the expression) */
    for (NSXMLNode *n = self; n; n = n->_parent)
        if (n->_fkind == NSXMLElementKind)
            for (NSXMLNode *ns in ((NSXMLElement *)n)->_fnamespaces)
                if ([[ns name] length])
                    xmlXPathRegisterNs(ctx, (const xmlChar *)[[ns name] UTF8String], (const xmlChar *)[[ns stringValue] UTF8String]);
    xmlSetStructuredErrorFunc(NULL, (xmlStructuredErrorFunc)quiet_error);
    xmlXPathObjectPtr r = xmlXPathEvalExpression((const xmlChar *)[expression UTF8String], ctx);
    NSMutableArray *out = nil;
    if (!r) {
        if (error)
            *error = [NSError errorWithDomain:@"XQueryErrorDomain" code:3
                                     userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Invalid XPath: %@", expression]}];
    } else {
        out = [NSMutableArray array];
        if (r->type == XPATH_NODESET && r->nodesetval) {
            for (int i = 0; i < r->nodesetval->nodeNr; i++) {
                NSXMLNode *n = [map objectForKey:(id)(void *)r->nodesetval->nodeTab[i]];
                if (n)
                    [out addObject:n];
            }
        } else if (!nodesOnly) {
            if (r->type == XPATH_NUMBER)
                [out addObject:@(r->floatval)];
            else if (r->type == XPATH_STRING)
                [out addObject:str(r->stringval) ?: @""];
            else if (r->type == XPATH_BOOLEAN)
                [out addObject:@(r->boolval != 0)];
        }
        xmlXPathFreeObject(r);
    }
    xmlSetStructuredErrorFunc(NULL, NULL);
    xmlXPathFreeContext(ctx);
    xmlFreeDoc(doc);
    return out;
}

@end

@implementation NSXMLDocument (FinchValidating)

/* Against the document's DTD, by libxml2's validator. */
- (BOOL)validateAndReturnError:(NSError **)error
{
    NSData *data = [self XMLData];
    xmlResetLastError();
    xmlDocPtr doc = xmlReadMemory([data bytes], (int)[data length], NULL, NULL, XML_PARSE_NOERROR | XML_PARSE_NOWARNING | XML_PARSE_NONET);
    if (!doc) {
        if (error)
            *error = xml_error(xmlGetLastError());
        return NO;
    }
    if (!doc->intSubset && !doc->extSubset) {
        xmlFreeDoc(doc);
        return YES;
    }
    xmlValidCtxtPtr v = xmlNewValidCtxt();
    v->error = NULL;
    v->warning = NULL;
    int ok = xmlValidateDocument(v, doc);
    xmlFreeValidCtxt(v);
    if (!ok && error)
        *error = xml_error(xmlGetLastError());
    xmlFreeDoc(doc);
    return ok != 0;
}

@end
