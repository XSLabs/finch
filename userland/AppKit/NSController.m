/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The Cocoa bindings controllers: NSController (editors and their commits),
 * NSObjectController (one content object, its selection proxy), NSArrayController
 * (sorting, filtering and the selection of an array), NSTreeController (a tree of
 * objects by their children, selected by index path) and NSUserDefaultsController
 * (a bindable view of NSUserDefaults, "values.key").
 *
 * The selection (and NSUserDefaultsController's values) is a proxy,
 * _NSControllerObjectProxy as in Apple's: its values are the selected
 * objects' values, or a marker (NSNoSelectionMarker, NSMultipleValuesMarker),
 * setting one sets it on every selected object, and observing one of its
 * keys observes that key on the selected objects. arrangedObjects is an
 * array proxy, _NSControllerArrayProxy, whose keys can be observed too
 * ("arrangedObjects.name"). The controllers post KVO for their own
 * properties when they change, for bindings to follow.
 *
 * As measured on macOS 26 (appkit-bindings-test.m): add:, insert:, remove:,
 * selectNext: and selectPrevious:, and NSUserDefaultsController's save:,
 * revert: and revertToInitialValues: happen on the next turn of the run
 * loop; setting content selects the first object (avoidsEmptySelection),
 * rearranging keeps the selected objects (preservesSelection) or clears the
 * selection, never filling an empty one; inserting clears the filter
 * (clearsFilterPredicateOnInsertion) and puts the new object into the
 * arrangement without sorting it, and at the end of the content; removing
 * selected objects selects the object that took their place.
 */
#import "NSKeyValueBinding_Finch.h"
#import "NSTreeNode_Finch.h"

#pragma mark - Proxies

@class _NSControllerObjectProxy;

@interface NSObject (FinchControllerProxy)
/* What a proxy shows: the controller's values for a key path, the objects behind it. */
- (id)_finchProxyValueForKeyPath:(NSString *)keyPath;
- (void)_finchProxySetValue:(id)value forKeyPath:(NSString *)keyPath;
- (NSArray *)_finchProxyObjects;
@end

/* An observer of a proxy's key path. */
@interface _FinchProxyObservation : NSObject {
@public
    id _observer;
    NSString *_keyPath;
    NSKeyValueObservingOptions _options;
    void *_context;
}
@end
@implementation _FinchProxyObservation
- (void)dealloc
{
    [_keyPath release];
    [super dealloc];
}
@end

static int proxyContext;

/* What the two proxies share: observers of keys, forwarded from the objects behind them. */
@interface _FinchObservingProxySupport : NSObject {
@public
    id _proxy;                      /* not retained */
    NSMutableArray *_observations;  /* _FinchProxyObservation */
    NSArray *_watchedObjects;       /* the objects observed for them */
    NSMutableSet *_watchedPaths;
}
@end

static void
watch(id obj, id observer, NSSet *paths, BOOL add)
{
    if (obj == [NSNull null])
        return;
    for (NSString *kp in paths)
        @try {
            if (add)
                [obj addObserver:observer forKeyPath:kp options:NSKeyValueObservingOptionPrior context:&proxyContext];
            else
                [obj removeObserver:observer forKeyPath:kp context:&proxyContext];
        } @catch (NSException *e) {
        }
}

@implementation _FinchObservingProxySupport

- (instancetype)init
{
    self = [super init];
    _observations = [[NSMutableArray alloc] init];
    _watchedPaths = [[NSMutableSet alloc] init];
    return self;
}

- (void)_finchUnwatch
{
    NSHashTable *seen = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality |
                                                          NSPointerFunctionsStrongMemory];
    for (id o in _watchedObjects)
        if (![seen containsObject:o]) {
            [seen addObject:o];
            watch(o, self, _watchedPaths, NO);
        }
    [_watchedObjects release];
    _watchedObjects = nil;
    [_watchedPaths removeAllObjects];
}

- (void)dealloc
{
    [self _finchUnwatch];
    [_observations release];
    [_watchedPaths release];
    [super dealloc];
}

/* Observe what the observers want on the objects behind the proxy now: only the objects
   that came or went, and the key paths added or dropped, change. A content array is
   rewatched before and after every change and as each observer arrives; observing everything
   again each time makes filling a controller with many objects quadratic in KVO work. */
- (void)_finchRewatch:(NSArray *)objects
{
    NSMutableSet *paths = [NSMutableSet set];
    for (_FinchProxyObservation *o in _observations)
        if (![o->_keyPath hasPrefix:@"@"])
            [paths addObject:o->_keyPath];
    NSMutableSet *added = [[paths mutableCopy] autorelease], *dropped = [[_watchedPaths mutableCopy] autorelease];
    [added minusSet:_watchedPaths];
    [dropped minusSet:paths];
    NSPointerFunctionsOptions identity = NSPointerFunctionsObjectPointerPersonality | NSPointerFunctionsStrongMemory;
    NSHashTable *before = [NSHashTable hashTableWithOptions:identity], *after = [NSHashTable hashTableWithOptions:identity];
    for (id obj in _watchedObjects)
        [before addObject:obj];
    for (id obj in objects)
        [after addObject:obj];
    for (id obj in before) {
        if (![after containsObject:obj]) {
            watch(obj, self, _watchedPaths, NO);
        } else {
            watch(obj, self, dropped, NO);
            watch(obj, self, added, YES);
        }
    }
    for (id obj in after)
        if (![before containsObject:obj])
            watch(obj, self, paths, YES);
    NSArray *copy = [objects copy];
    [_watchedObjects release];
    _watchedObjects = copy;
    [_watchedPaths setSet:paths];
}

- (void)_finchNotify:(NSString *)keyPath prior:(BOOL)prior
{
    for (_FinchProxyObservation *o in [[_observations copy] autorelease]) {
        BOOL match = [o->_keyPath isEqualToString:keyPath] || !keyPath;
        if (!match && keyPath) {
            /* a change of "a" is a change of "a.b" */
            match = [o->_keyPath hasPrefix:[keyPath stringByAppendingString:@"."]];
        }
        if (!match)
            continue;
        if (prior && !(o->_options & NSKeyValueObservingOptionPrior))
            continue;
        NSMutableDictionary *c = [NSMutableDictionary dictionaryWithObject:@(NSKeyValueChangeSetting) forKey:NSKeyValueChangeKindKey];
        if (prior)
            [c setObject:@YES forKey:NSKeyValueChangeNotificationIsPriorKey];
        else if (o->_options & NSKeyValueObservingOptionNew)
            [c setObject:[NSNull null] forKey:NSKeyValueChangeNewKey];
        if (o->_options & NSKeyValueObservingOptionOld)
            [c setObject:[NSNull null] forKey:NSKeyValueChangeOldKey];
        [o->_observer observeValueForKeyPath:o->_keyPath ofObject:_proxy change:c context:o->_context];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context != &proxyContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    [self _finchNotify:keyPath prior:[[change objectForKey:NSKeyValueChangeNotificationIsPriorKey] boolValue]];
}

- (void)addObserver:(id)observer forKeyPath:(NSString *)keyPath options:(NSKeyValueObservingOptions)options
            context:(void *)context objects:(NSArray *)objects
{
    _FinchProxyObservation *o = [[_FinchProxyObservation alloc] init];
    o->_observer = observer;
    o->_keyPath = [keyPath copy];
    o->_options = options;
    o->_context = context;
    [_observations addObject:o];
    [o release];
    [self _finchRewatch:objects];
    if (options & NSKeyValueObservingOptionInitial) {
        NSMutableDictionary *c = [NSMutableDictionary dictionaryWithObject:@(NSKeyValueChangeSetting) forKey:NSKeyValueChangeKindKey];
        if (options & NSKeyValueObservingOptionNew)
            [c setObject:[_proxy valueForKeyPath:keyPath] ?: [NSNull null] forKey:NSKeyValueChangeNewKey];
        [observer observeValueForKeyPath:keyPath ofObject:_proxy change:c context:context];
    }
}

- (void)removeObserver:(id)observer forKeyPath:(NSString *)keyPath anyContext:(BOOL)any context:(void *)context
                objects:(NSArray *)objects
{
    for (NSInteger i = (NSInteger)[_observations count] - 1; i >= 0; i--) {
        _FinchProxyObservation *o = [_observations objectAtIndex:(NSUInteger)i];
        if (o->_observer == observer && [o->_keyPath isEqualToString:keyPath] && (any || o->_context == context)) {
            [_observations removeObjectAtIndex:(NSUInteger)i];
            [self _finchRewatch:objects];
            return;
        }
    }
    [NSException raise:NSRangeException
                format:@"Cannot remove an observer <%@ %p> for the key path \"%@\" from <%@ %p> because it is not registered as an observer.",
                       [observer class], observer, keyPath, [_proxy class], _proxy];
}

@end

@interface _NSControllerObjectProxy : NSObject {
    id _controller; /* not retained */
    _FinchObservingProxySupport *_support;
}
- (instancetype)_finchInitWithController:(id)controller;
- (void)_finchObjectsChanged;
- (void)_finchNotifyKeyPath:(NSString *)keyPath prior:(BOOL)prior;
- (NSArray *)_finchObservedKeys;
@end

@implementation _NSControllerObjectProxy

- (instancetype)_finchInitWithController:(id)controller
{
    self = [super init];
    _controller = controller;
    _support = [[_FinchObservingProxySupport alloc] init];
    _support->_proxy = self;
    return self;
}

- (void)dealloc
{
    [_support release];
    [super dealloc];
}

- (id)valueForKey:(NSString *)key { return [_controller _finchProxyValueForKeyPath:key]; }
- (id)valueForKeyPath:(NSString *)keyPath { return [_controller _finchProxyValueForKeyPath:keyPath]; }
- (void)setValue:(id)value forKey:(NSString *)key { [_controller _finchProxySetValue:value forKeyPath:key]; }
- (void)setValue:(id)value forKeyPath:(NSString *)keyPath { [_controller _finchProxySetValue:value forKeyPath:keyPath]; }

- (void)addObserver:(NSObject *)observer forKeyPath:(NSString *)keyPath options:(NSKeyValueObservingOptions)options
            context:(void *)context
{
    [_support addObserver:observer forKeyPath:keyPath options:options context:context objects:[_controller _finchProxyObjects]];
}

- (void)removeObserver:(NSObject *)observer forKeyPath:(NSString *)keyPath context:(void *)context
{
    [_support removeObserver:observer forKeyPath:keyPath anyContext:NO context:context objects:[_controller _finchProxyObjects]];
}

- (void)removeObserver:(NSObject *)observer forKeyPath:(NSString *)keyPath
{
    [_support removeObserver:observer forKeyPath:keyPath anyContext:YES context:NULL objects:[_controller _finchProxyObjects]];
}

- (void)_finchObjectsChanged { [_support _finchRewatch:[_controller _finchProxyObjects]]; }
- (void)_finchNotifyKeyPath:(NSString *)keyPath prior:(BOOL)prior { [_support _finchNotify:keyPath prior:prior]; }

- (NSArray *)_finchObservedKeys
{
    NSMutableSet *keys = [NSMutableSet set];
    for (_FinchProxyObservation *o in _support->_observations) {
        NSRange dot = [o->_keyPath rangeOfString:@"."];
        [keys addObject:dot.location == NSNotFound ? o->_keyPath : [o->_keyPath substringToIndex:dot.location]];
    }
    return [keys allObjects];
}

@end

@interface _NSControllerArrayProxy : NSArray {
    id _controller; /* not retained */
    _FinchObservingProxySupport *_support;
}
- (instancetype)_finchInitWithController:(id)controller;
- (void)_finchObjectsChanged;
@end

@interface NSArrayController (FinchProxy)
- (NSArray *)_finchArranged;
@end

@implementation _NSControllerArrayProxy

- (instancetype)_finchInitWithController:(id)controller
{
    self = [super init];
    _controller = controller;
    _support = [[_FinchObservingProxySupport alloc] init];
    _support->_proxy = self;
    return self;
}

- (void)dealloc
{
    [_support release];
    [super dealloc];
}

- (NSUInteger)count { return [[_controller _finchArranged] count]; }
- (id)objectAtIndex:(NSUInteger)index { return [[_controller _finchArranged] objectAtIndex:index]; }

- (void)addObserver:(NSObject *)observer forKeyPath:(NSString *)keyPath options:(NSKeyValueObservingOptions)options
            context:(void *)context
{
    [_support addObserver:observer forKeyPath:keyPath options:options context:context objects:[_controller _finchArranged]];
}

- (void)removeObserver:(NSObject *)observer forKeyPath:(NSString *)keyPath context:(void *)context
{
    [_support removeObserver:observer forKeyPath:keyPath anyContext:NO context:context objects:[_controller _finchArranged]];
}

- (void)removeObserver:(NSObject *)observer forKeyPath:(NSString *)keyPath
{
    [_support removeObserver:observer forKeyPath:keyPath anyContext:YES context:NULL objects:[_controller _finchArranged]];
}

- (void)_finchObjectsChanged { [_support _finchRewatch:[_controller _finchArranged]]; }

@end

#pragma mark - NSController

@implementation NSController {
    NSMutableArray *_editors;
}

- (instancetype)init
{
    self = [super init];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
}

- (void)dealloc
{
    [_editors release];
    [super dealloc];
}

- (BOOL)isEditing { return [_editors count] > 0; }

- (void)objectDidBeginEditing:(id<NSEditor>)editor
{
    if (!_editors)
        _editors = [[NSMutableArray alloc] init];
    if ([_editors indexOfObjectIdenticalTo:editor] != NSNotFound)
        return;
    BOOL was = [self isEditing];
    if (!was)
        [self willChangeValueForKey:@"editing"];
    [_editors addObject:editor];
    if (!was)
        [self didChangeValueForKey:@"editing"];
}

- (void)objectDidEndEditing:(id<NSEditor>)editor
{
    NSUInteger i = [_editors indexOfObjectIdenticalTo:editor];
    if (i == NSNotFound)
        return;
    BOOL last = [_editors count] == 1;
    if (last)
        [self willChangeValueForKey:@"editing"];
    [_editors removeObjectAtIndex:i];
    if (last)
        [self didChangeValueForKey:@"editing"];
}

- (void)discardEditing
{
    NSArray *eds = [[_editors copy] autorelease];
    for (id<NSEditor> e in eds)
        [e discardEditing];
    if ([_editors count]) {
        [self willChangeValueForKey:@"editing"];
        [_editors removeAllObjects];
        [self didChangeValueForKey:@"editing"];
    }
}

- (BOOL)commitEditing
{
    for (id<NSEditor> e in [[_editors copy] autorelease])
        if (![e commitEditing])
            return NO;
    return YES;
}

- (BOOL)commitEditingAndReturnError:(NSError **)error
{
    if (error)
        *error = nil;
    return [self commitEditing];
}

- (void)commitEditingWithDelegate:(id)delegate didCommitSelector:(SEL)sel contextInfo:(void *)contextInfo
{
    BOOL ok = [self commitEditing];
    if (delegate && sel)
        ((void (*)(id, SEL, id, BOOL, void *))objc_msgSend)(delegate, sel, self, ok, contextInfo);
}

@end

#pragma mark - NSObjectController

/* The keys a controller notifies about itself (setters don't notify automatically). */
static NSSet *
controller_keys(void)
{
    static NSSet *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = [[NSSet alloc] initWithObjects:@"content", @"selection", @"selectedObjects", @"canAdd", @"canRemove",
                                              @"canInsert", @"arrangedObjects", @"selectionIndexes", @"selectionIndex",
                                              @"canSelectNext", @"canSelectPrevious", @"sortDescriptors", @"filterPredicate",
                                              @"editable", @"isEditable", @"hasUnappliedChanges", nil];
    });
    return keys;
}

/* What changes, for KVO: the content itself, the arrangement, the selection. */
enum { CH_CONTENT = 1, CH_ARRANGED = 2, CH_SELECTION = 4, CH_ALL = 7 };

static NSArray *
change_keys(BOOL array, int mask)
{
    NSMutableArray *k = [NSMutableArray array];
    if (mask & CH_CONTENT)
        [k addObjectsFromArray:array ? @[ @"content" ] : @[ @"content", @"canAdd" ]];
    if (array && (mask & CH_ARRANGED))
        [k addObject:@"arrangedObjects"];
    if (mask & CH_SELECTION)
        [k addObjectsFromArray:array ? @[ @"selectionIndexes", @"selectionIndex", @"selectedObjects", @"selection", @"canRemove" ]
                                     : @[ @"selectedObjects", @"selection", @"canRemove" ]];
    if (array && (mask & (CH_ARRANGED | CH_SELECTION)))
        [k addObjectsFromArray:@[ @"canSelectNext", @"canSelectPrevious" ]];
    return k;
}

@implementation NSObjectController {
@protected
    id _content;
    Class _objectClass;
    NSString *_objectClassName;
    BOOL _editable, _autoPrepares;
    _NSControllerObjectProxy *_selectionProxy;
    NSInteger _changeDepth;
    int _changeMask;
}

+ (BOOL)automaticallyNotifiesObserversForKey:(NSString *)key
{
    if ([controller_keys() containsObject:key])
        return NO;
    return [super automaticallyNotifiesObserversForKey:key];
}

+ (NSArray *)_finchBuiltinBindings { return @[ NSEditableBinding, NSContentObjectBinding, NSManagedObjectContextBinding ]; }

- (instancetype)init
{
    return [self initWithContent:nil];
}

- (instancetype)initWithContent:(id)content
{
    self = [super init];
    if (!self)
        return nil;
    _editable = YES;
    _content = [content retain];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self)
        return nil;
    _editable = [coder decodeBoolForKey:@"NSEditable"];
    _autoPrepares = [coder decodeBoolForKey:@"NSAutomaticallyPreparesContent"];
    _objectClassName = [[coder decodeObjectForKey:@"NSObjectClassName"] copy];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    if (_editable)
        [coder encodeBool:YES forKey:@"NSEditable"];
    if (_autoPrepares)
        [coder encodeBool:YES forKey:@"NSAutomaticallyPreparesContent"];
    if (_objectClassName || _objectClass)
        [coder encodeObject:_objectClassName ?: NSStringFromClass(_objectClass) forKey:@"NSObjectClassName"];
}

- (void)dealloc
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [_content release];
    [_objectClassName release];
    [_selectionProxy release];
    [super dealloc];
}

- (void)awakeFromNib
{
    if (_autoPrepares && !_content && ![self _finchContentIsBound])
        [self prepareContent];
}

- (BOOL)_finchContentIsBound { return FinchBindingFor(self, NSContentObjectBinding) != nil; }

#pragma mark Change notification

- (BOOL)_finchIsArray { return NO; }

- (void)_finchWillChange { [self _finchWillChange:CH_ALL]; }

- (void)_finchWillChange:(int)mask
{
    if (_changeDepth++)
        return;
    _changeMask = mask;
    for (NSString *k in change_keys([self _finchIsArray], mask))
        [self willChangeValueForKey:k];
}

- (void)_finchDidChange
{
    if (--_changeDepth)
        return;
    [self _finchObjectsChanged];
    for (NSString *k in [change_keys([self _finchIsArray], _changeMask) reverseObjectEnumerator])
        [self didChangeValueForKey:k];
}

- (void)_finchObjectsChanged
{
    [_selectionProxy _finchObjectsChanged];
}

#pragma mark Content

- (id)content { return [[_content retain] autorelease]; }

- (void)_finchSetContent:(id)content
{
    [self _finchWillChange];
    [content retain];
    [_content release];
    _content = content;
    [self _finchDidChange];
}

- (void)setContent:(id)content
{
    [self _finchSetContent:content];
}

- (id)selection
{
    if (!_selectionProxy)
        _selectionProxy = [[_NSControllerObjectProxy alloc] _finchInitWithController:self];
    return _selectionProxy;
}

- (NSArray *)selectedObjects { return _content ? @[ _content ] : @[]; }

- (NSArray *)_finchProxyObjects { return [self selectedObjects]; }

- (BOOL)_finchAlwaysUsesMultipleValuesMarker { return NO; }

- (id)_finchProxyValueForKeyPath:(NSString *)keyPath
{
    NSArray *objs = [self selectedObjects];
    NSUInteger n = [objs count];
    if (!n)
        return [NSBindingSelectionMarker noSelectionMarker];
    id first = [[objs objectAtIndex:0] valueForKeyPath:keyPath];
    if (n == 1)
        return first;
    if ([self _finchAlwaysUsesMultipleValuesMarker])
        return [NSBindingSelectionMarker multipleValuesSelectionMarker];
    for (NSUInteger i = 1; i < n; i++) {
        id v = [[objs objectAtIndex:i] valueForKeyPath:keyPath];
        if (!(v == first || [v isEqual:first]))
            return [NSBindingSelectionMarker multipleValuesSelectionMarker];
    }
    return first;
}

- (void)_finchProxySetValue:(id)value forKeyPath:(NSString *)keyPath
{
    for (id o in [self selectedObjects])
        [o setValue:value forKeyPath:keyPath];
}

#pragma mark Objects

- (BOOL)automaticallyPreparesContent { return _autoPrepares; }
- (void)setAutomaticallyPreparesContent:(BOOL)flag { _autoPrepares = flag; }

- (Class)objectClass
{
    if (_objectClass)
        return _objectClass;
    Class c = _objectClassName ? NSClassFromString(_objectClassName) : Nil;
    return c ?: [NSMutableDictionary class];
}

- (void)setObjectClass:(Class)objectClass
{
    _objectClass = objectClass;
    [_objectClassName release];
    _objectClassName = nil;
}

- (id)newObject
{
    return [[[self objectClass] alloc] init];
}

- (void)prepareContent
{
    id o = [self newObject];
    [self setContent:o];
    [o release];
}

/* Content set by the controller itself: the bound object follows. */
- (void)_finchContentChangedByController
{
    _FinchBinding *b = FinchBindingFor(self, NSContentObjectBinding);
    if (b)
        [b push:_content];
}

- (void)addObject:(id)object
{
    [self _finchSetContent:object];
    [self _finchContentChangedByController];
}

- (void)removeObject:(id)object
{
    if (object != _content)
        return;
    [self _finchSetContent:nil];
    [self _finchContentChangedByController];
}

- (BOOL)isEditable { return _editable; }

- (void)setEditable:(BOOL)flag
{
    [self willChangeValueForKey:@"editable"];
    [self willChangeValueForKey:@"canAdd"];
    [self willChangeValueForKey:@"canRemove"];
    _editable = flag;
    [self didChangeValueForKey:@"canRemove"];
    [self didChangeValueForKey:@"canAdd"];
    [self didChangeValueForKey:@"editable"];
}

- (BOOL)canAdd { return _editable && !_content; }
- (BOOL)canRemove { return _editable && [[self selectedObjects] count] > 0; }

- (void)_finchDeferredAdd
{
    id o = [self newObject];
    [self addObject:o];
    [o release];
}

- (void)_finchDeferredRemove
{
    for (id o in [[[self selectedObjects] copy] autorelease])
        [self removeObject:o];
}

- (IBAction)add:(id)sender
{
    if (![self commitEditing])
        return;
    [self performSelector:@selector(_finchDeferredAdd) withObject:nil afterDelay:0];
}

/* As Apple's, removing happens at once (adding waits for the run loop). */
- (IBAction)remove:(id)sender
{
    if (![self commitEditing])
        return;
    [self _finchDeferredRemove];
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item
{
    SEL a = [item action];
    if (a == @selector(add:))
        return [self canAdd];
    if (a == @selector(remove:))
        return [self canRemove];
    return YES;
}

#pragma mark Bindings

- (BOOL)_finchHandlesBinding:(NSString *)binding
{
    return [binding isEqualToString:NSContentObjectBinding] || [super _finchHandlesBinding:binding];
}

- (Class)_finchValueClassForBinding:(NSString *)binding
{
    if ([binding isEqualToString:NSContentObjectBinding] || [binding isEqualToString:NSContentArrayBinding] ||
        [binding isEqualToString:NSContentSetBinding])
        return [NSObject class];
    if ([binding isEqualToString:NSEditableBinding])
        return [NSNumber class];
    return [super _finchValueClassForBinding:binding];
}

- (NSDictionary *)_finchDefaultOptionsForBinding:(NSString *)binding
{
    if ([binding isEqualToString:NSContentObjectBinding] || [binding isEqualToString:NSContentArrayBinding] ||
        [binding isEqualToString:NSContentSetBinding]) {
        NSMutableDictionary *d = [[[super _finchDefaultOptionsForBinding:binding] mutableCopy] autorelease];
        [d addEntriesFromDictionary:@{
            NSAlwaysPresentsApplicationModalAlertsBindingOption : @NO,
            NSConditionallySetsEditableBindingOption : @YES,
            NSDeletesObjectsOnRemoveBindingsOption : @NO,
            NSHandlesContentAsCompoundValueBindingOption : @NO,
            NSValidatesImmediatelyBindingOption : @NO,
        }];
        if ([self _finchIsArray])
            [d setObject:@NO forKey:NSSelectsAllWhenSettingContentBindingOption];
        return d;
    }
    return [super _finchDefaultOptionsForBinding:binding];
}

- (void)_finchBindingChanged:(_FinchBinding *)b
{
    if ([b->_name isEqualToString:NSContentObjectBinding]) {
        int kind;
        id v = [b valueWithKind:&kind];
        [self setContent:NSIsControllerMarker(v) ? nil : v];
        return;
    }
    [super _finchBindingChanged:b];
}

@end

#pragma mark - NSArrayController

@implementation NSArrayController {
    NSMutableArray *_arranged;
    NSMutableIndexSet *_selection;
    NSArray *_sortDescriptors;
    NSPredicate *_filterPredicate;
    _NSControllerArrayProxy *_arrangedProxy;
    struct {
        unsigned avoidsEmpty : 1;
        unsigned preserves : 1;
        unsigned selectsInserted : 1;
        unsigned clearsFilter : 1;
        unsigned autoRearranges : 1;
        unsigned alwaysMultiple : 1;
        unsigned selectsAllOnContent : 1;
    } _ac;
    NSArray *_rearrangeKeys; /* observed on the content objects */
    NSArray *_rearrangeObserved;
}

+ (NSArray *)_finchBuiltinBindings
{
    return @[
        NSEditableBinding, NSContentArrayBinding, NSSelectionIndexesBinding, NSContentArrayForMultipleSelectionBinding,
        NSContentSetBinding, NSManagedObjectContextBinding, NSSortDescriptorsBinding, NSContentObjectBinding,
        NSFilterPredicateBinding
    ];
}

static void
ac_defaults(NSArrayController *self)
{
    self->_arranged = [[NSMutableArray alloc] init];
    self->_selection = [[NSMutableIndexSet alloc] init];
    self->_ac.avoidsEmpty = self->_ac.preserves = self->_ac.selectsInserted = self->_ac.clearsFilter = 1;
}

- (instancetype)initWithContent:(id)content
{
    self = [super initWithContent:nil];
    if (!self)
        return nil;
    ac_defaults(self);
    [self setContent:content ?: [NSMutableArray array]];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self)
        return nil;
    ac_defaults(self);
    _ac.avoidsEmpty = [coder decodeBoolForKey:@"NSAvoidsEmptySelection"];
    _ac.preserves = [coder decodeBoolForKey:@"NSPreservesSelection"];
    _ac.selectsInserted = [coder decodeBoolForKey:@"NSSelectsInsertedObjects"];
    _ac.clearsFilter = [coder decodeBoolForKey:@"NSClearsFilterPredicateOnInsertion"];
    _ac.autoRearranges = [coder decodeBoolForKey:@"NSAutomaticallyRearrangesObjects"];
    _ac.alwaysMultiple = [coder decodeBoolForKey:@"NSAlwaysUsesMultipleValuesMarker"];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    if (_ac.avoidsEmpty)
        [coder encodeBool:YES forKey:@"NSAvoidsEmptySelection"];
    if (_ac.preserves)
        [coder encodeBool:YES forKey:@"NSPreservesSelection"];
    if (_ac.selectsInserted)
        [coder encodeBool:YES forKey:@"NSSelectsInsertedObjects"];
    if (_ac.clearsFilter)
        [coder encodeBool:YES forKey:@"NSClearsFilterPredicateOnInsertion"];
    [coder encodeBool:YES forKey:@"NSFilterRestrictsInsertion"];
    if (_ac.autoRearranges)
        [coder encodeBool:YES forKey:@"NSAutomaticallyRearrangesObjects"];
    if (_ac.alwaysMultiple)
        [coder encodeBool:YES forKey:@"NSAlwaysUsesMultipleValuesMarker"];
}

- (void)dealloc
{
    [self _finchStopRearrangeObserving];
    [_arranged release];
    [_selection release];
    [_sortDescriptors release];
    [_filterPredicate release];
    [_arrangedProxy release];
    [_rearrangeKeys release];
    [super dealloc];
}

- (BOOL)_finchIsArray { return YES; }

/* The selection proxy watches every arranged object, as Apple's notifies selection keys for any of them. */
- (NSArray *)_finchProxyObjects { return _arranged; }

- (BOOL)_finchContentIsBound
{
    return FinchBindingFor(self, NSContentArrayBinding) || FinchBindingFor(self, NSContentSetBinding) ||
           [super _finchContentIsBound];
}

- (void)_finchObjectsChanged
{
    [super _finchObjectsChanged];
    [_arrangedProxy _finchObjectsChanged];
    [self _finchUpdateRearrangeObserving];
}

#pragma mark Flags

- (BOOL)avoidsEmptySelection { return _ac.avoidsEmpty; }
- (void)setAvoidsEmptySelection:(BOOL)flag { _ac.avoidsEmpty = flag; }
- (BOOL)preservesSelection { return _ac.preserves; }
- (void)setPreservesSelection:(BOOL)flag { _ac.preserves = flag; }
- (BOOL)selectsInsertedObjects { return _ac.selectsInserted; }
- (void)setSelectsInsertedObjects:(BOOL)flag { _ac.selectsInserted = flag; }
- (BOOL)clearsFilterPredicateOnInsertion { return _ac.clearsFilter; }
- (void)setClearsFilterPredicateOnInsertion:(BOOL)flag { _ac.clearsFilter = flag; }
- (BOOL)alwaysUsesMultipleValuesMarker { return _ac.alwaysMultiple; }
- (void)setAlwaysUsesMultipleValuesMarker:(BOOL)flag
{
    [self willChangeValueForKey:@"selection"];
    _ac.alwaysMultiple = flag;
    [self didChangeValueForKey:@"selection"];
}
- (BOOL)_finchAlwaysUsesMultipleValuesMarker { return _ac.alwaysMultiple; }

- (BOOL)automaticallyRearrangesObjects { return _ac.autoRearranges; }

- (void)setAutomaticallyRearrangesObjects:(BOOL)flag
{
    _ac.autoRearranges = flag;
    [self _finchUpdateRearrangeObserving];
}

#pragma mark Arranging

static NSArray *
content_array(id content)
{
    if (!content)
        return @[];
    if ([content isKindOfClass:[NSArray class]])
        return content;
    if ([content isKindOfClass:[NSSet class]] || [content isKindOfClass:[NSOrderedSet class]])
        return [content allObjects];
    return @[ content ];
}

- (NSArray *)_finchArranged { return _arranged; }

- (id)arrangedObjects
{
    if (!_arrangedProxy)
        _arrangedProxy = [[_NSControllerArrayProxy alloc] _finchInitWithController:self];
    return _arrangedProxy;
}

- (NSArray *)arrangeObjects:(NSArray *)objects
{
    NSArray *a = objects;
    if (_filterPredicate)
        a = [a filteredArrayUsingPredicate:_filterPredicate];
    if ([_sortDescriptors count])
        a = [a sortedArrayUsingDescriptors:_sortDescriptors];
    return a;
}

static void
key_paths_of_expression(NSExpression *e, NSMutableArray *out)
{
    if (!e)
        return;
    switch ([e expressionType]) {
    case NSKeyPathExpressionType:
        if (![out containsObject:[e keyPath]])
            [out addObject:[e keyPath]];
        break;
    case NSFunctionExpressionType:
        key_paths_of_expression([e operand], out);
        for (NSExpression *a in [e arguments])
            key_paths_of_expression(a, out);
        break;
    default:
        break;
    }
}

static void
key_paths_of_predicate(NSPredicate *p, NSMutableArray *out)
{
    if ([p isKindOfClass:[NSCompoundPredicate class]]) {
        for (NSPredicate *s in [(NSCompoundPredicate *)p subpredicates])
            key_paths_of_predicate(s, out);
    } else if ([p isKindOfClass:[NSComparisonPredicate class]]) {
        key_paths_of_expression([(NSComparisonPredicate *)p leftExpression], out);
        key_paths_of_expression([(NSComparisonPredicate *)p rightExpression], out);
    }
}

- (NSArray<NSString *> *)automaticRearrangementKeyPaths
{
    NSMutableArray *out = [NSMutableArray array];
    for (NSSortDescriptor *d in _sortDescriptors)
        if ([d key] && ![out containsObject:[d key]])
            [out addObject:[d key]];
    key_paths_of_predicate(_filterPredicate, out);
    return [out count] ? out : nil;
}

- (void)didChangeArrangementCriteria
{
    [self _finchUpdateRearrangeObserving];
}

static int rearrangeContext;

- (void)_finchStopRearrangeObserving
{
    for (id o in _rearrangeObserved)
        for (NSString *k in _rearrangeKeys)
            @try {
                [o removeObserver:self forKeyPath:k context:&rearrangeContext];
            } @catch (NSException *e) {
            }
    [_rearrangeObserved release];
    _rearrangeObserved = nil;
}

- (void)_finchUpdateRearrangeObserving
{
    [self _finchStopRearrangeObserving];
    NSArray *keys = _ac.autoRearranges ? [self automaticRearrangementKeyPaths] : nil;
    [_rearrangeKeys release];
    _rearrangeKeys = [keys copy];
    if (![keys count])
        return;
    _rearrangeObserved = [content_array(_content) copy];
    for (id o in _rearrangeObserved)
        for (NSString *k in keys)
            @try {
                [o addObserver:self forKeyPath:k options:0 context:&rearrangeContext];
            } @catch (NSException *e) {
            }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context == &rearrangeContext) {
        [self rearrangeObjects];
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

/* Arrange the content again; the selection follows its objects, or is cleared. */
- (void)_finchRearrangeAvoidingEmpty:(BOOL)avoid
{
    NSArray *old = [self selectedObjects];
    NSArray *now = [self arrangeObjects:content_array(_content)];
    [_arranged setArray:now ?: @[]];
    [_selection removeAllIndexes];
    if (_ac.preserves)
        for (id o in old) {
            NSUInteger i = [_arranged indexOfObjectIdenticalTo:o];
            if (i != NSNotFound)
                [_selection addIndex:i];
        }
    if (avoid && ![_selection count] && [_arranged count]) {
        if (_ac.selectsAllOnContent)
            [_selection addIndexesInRange:NSMakeRange(0, [_arranged count])];
        else
            [_selection addIndex:0];
    }
}

- (void)rearrangeObjects
{
    [self _finchWillChange:CH_ARRANGED | CH_SELECTION];
    [self _finchRearrangeAvoidingEmpty:NO];
    [self _finchDidChange];
    [self _finchSelectionChangedByController];
}

- (void)_finchSetContent:(id)content
{
    [self _finchWillChange];
    [content retain];
    [_content release];
    _content = content;
    [self _finchRearrangeAvoidingEmpty:_ac.avoidsEmpty];
    [self _finchDidChange];
    [self _finchSelectionChangedByController];
}

- (NSArray *)sortDescriptors { return _sortDescriptors ?: @[]; }

- (void)setSortDescriptors:(NSArray *)descriptors
{
    [self willChangeValueForKey:@"sortDescriptors"];
    [_sortDescriptors release];
    _sortDescriptors = [descriptors copy];
    [self didChangeValueForKey:@"sortDescriptors"];
    _FinchBinding *b = FinchBindingFor(self, NSSortDescriptorsBinding);
    if (b && !b->_pushing)
        [b push:_sortDescriptors];
    [self didChangeArrangementCriteria];
    [self rearrangeObjects];
}

- (NSPredicate *)filterPredicate { return _filterPredicate; }

- (void)setFilterPredicate:(NSPredicate *)predicate
{
    [self willChangeValueForKey:@"filterPredicate"];
    [predicate retain];
    [_filterPredicate release];
    _filterPredicate = predicate;
    [self didChangeValueForKey:@"filterPredicate"];
    _FinchBinding *b = FinchBindingFor(self, NSFilterPredicateBinding);
    if (b && !b->_pushing)
        [b push:_filterPredicate];
    [self didChangeArrangementCriteria];
    [self rearrangeObjects];
}

#pragma mark Selection

- (NSIndexSet *)selectionIndexes { return [[_selection copy] autorelease]; }
- (NSUInteger)selectionIndex { return [_selection count] ? [_selection firstIndex] : NSNotFound; }
- (NSArray *)selectedObjects { return [_arranged objectsAtIndexes:_selection]; }

/* The selection, changed by the controller: a bound selectionIndexes follows. */
- (void)_finchSelectionChangedByController
{
    _FinchBinding *b = FinchBindingFor(self, NSSelectionIndexesBinding);
    if (b && !b->_pushing)
        [b push:[self selectionIndexes]];
}

- (BOOL)_finchSelect:(NSIndexSet *)indexes
{
    NSMutableIndexSet *valid = [NSMutableIndexSet indexSet];
    [indexes enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
        if (i < [_arranged count])
            [valid addIndex:i];
    }];
    if ([valid isEqualToIndexSet:_selection])
        return YES;
    [self _finchWillChange:CH_SELECTION];
    [_selection removeAllIndexes];
    [_selection addIndexes:valid];
    [self _finchDidChange];
    [self _finchSelectionChangedByController];
    return YES;
}

- (BOOL)setSelectionIndexes:(NSIndexSet *)indexes
{
    if (![self commitEditing])
        return NO;
    return [self _finchSelect:indexes ?: [NSIndexSet indexSet]];
}

- (BOOL)setSelectionIndex:(NSUInteger)index
{
    return [self setSelectionIndexes:index == NSNotFound ? [NSIndexSet indexSet] : [NSIndexSet indexSetWithIndex:index]];
}

- (BOOL)addSelectionIndexes:(NSIndexSet *)indexes
{
    NSMutableIndexSet *s = [[_selection mutableCopy] autorelease];
    [s addIndexes:indexes];
    return [self setSelectionIndexes:s];
}

- (BOOL)removeSelectionIndexes:(NSIndexSet *)indexes
{
    NSMutableIndexSet *s = [[_selection mutableCopy] autorelease];
    [s removeIndexes:indexes];
    return [self setSelectionIndexes:s];
}

- (NSIndexSet *)_finchIndexesOfObjects:(NSArray *)objects
{
    NSMutableIndexSet *s = [NSMutableIndexSet indexSet];
    for (id o in objects) {
        NSUInteger i = [_arranged indexOfObject:o];
        if (i != NSNotFound)
            [s addIndex:i];
    }
    return s;
}

- (BOOL)setSelectedObjects:(NSArray *)objects { return [self setSelectionIndexes:[self _finchIndexesOfObjects:objects]]; }
- (BOOL)addSelectedObjects:(NSArray *)objects { return [self addSelectionIndexes:[self _finchIndexesOfObjects:objects]]; }
- (BOOL)removeSelectedObjects:(NSArray *)objects { return [self removeSelectionIndexes:[self _finchIndexesOfObjects:objects]]; }

- (BOOL)canSelectNext
{
    NSUInteger i = [self selectionIndex];
    return i != NSNotFound && i + 1 < [_arranged count];
}

- (BOOL)canSelectPrevious
{
    NSUInteger i = [self selectionIndex];
    return i != NSNotFound && i > 0;
}

- (void)_finchDeferredSelectNext
{
    if ([self canSelectNext])
        [self setSelectionIndex:[self selectionIndex] + 1];
}

- (void)_finchDeferredSelectPrevious
{
    if ([self canSelectPrevious])
        [self setSelectionIndex:[self selectionIndex] - 1];
}

- (IBAction)selectNext:(id)sender
{
    [self performSelector:@selector(_finchDeferredSelectNext) withObject:nil afterDelay:0];
}

- (IBAction)selectPrevious:(id)sender
{
    [self performSelector:@selector(_finchDeferredSelectPrevious) withObject:nil afterDelay:0];
}

#pragma mark Adding and removing

- (BOOL)canAdd { return [self isEditable]; }
- (BOOL)canInsert { return [self isEditable]; }
- (BOOL)canRemove { return [self isEditable] && [_selection count] > 0; }

/* Change the content: in the bound array, in a mutable content array, or in a copy. */
- (void)_finchMutateContent:(void (^)(NSMutableArray *content))change
{
    _FinchBinding *b = FinchBindingFor(self, NSContentArrayBinding);
    if (b && b->_observed) {
        b->_pushing = YES;
        @try {
            change([b->_observed mutableArrayValueForKeyPath:b->_keyPath]);
        } @finally {
            b->_pushing = NO;
        }
        id now = [b rawValue];
        if (now != _content) {
            [now retain];
            [_content release];
            _content = now;
        }
        return;
    }
    if ([_content isKindOfClass:[NSMutableArray class]]) {
        @try {
            change(_content);
            return;
        } @catch (NSException *e) {
        }
    }
    NSMutableArray *copy = [NSMutableArray arrayWithArray:content_array(_content)];
    change(copy);
    [_content release];
    _content = [copy retain];
}

- (void)_finchPrepareForInsertion
{
    if (_ac.clearsFilter && _filterPredicate) {
        [self willChangeValueForKey:@"filterPredicate"];
        [_filterPredicate release];
        _filterPredicate = nil;
        [self didChangeValueForKey:@"filterPredicate"];
        _FinchBinding *b = FinchBindingFor(self, NSFilterPredicateBinding);
        if (b)
            [b push:nil];
        [self didChangeArrangementCriteria];
        [self _finchRearrangeAvoidingEmpty:NO];
    }
}

- (void)insertObjects:(NSArray *)objects atArrangedObjectIndexes:(NSIndexSet *)indexes
{
    if (![objects count])
        return;
    [self _finchWillChange:CH_ARRANGED | CH_SELECTION];
    /* the objects go where the ones at those indexes are now (in the arrangement after clearing the filter) */
    NSMutableArray *anchors = [NSMutableArray array];
    __block NSUInteger k = 0;
    [indexes enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
        [anchors addObject:i < [_arranged count] ? [_arranged objectAtIndex:i] : [NSNull null]];
        if (++k >= [objects count])
            *stop = YES;
    }];
    [self _finchPrepareForInsertion];
    [self _finchMutateContent:^(NSMutableArray *content) {
        [content addObjectsFromArray:objects];
    }];
    NSMutableIndexSet *inserted = [NSMutableIndexSet indexSet];
    for (NSUInteger j = 0; j < [objects count]; j++) {
        id o = [objects objectAtIndex:j];
        if (_filterPredicate && ![_filterPredicate evaluateWithObject:o])
            continue;
        id anchor = j < [anchors count] ? [anchors objectAtIndex:j] : [NSNull null];
        NSUInteger at = anchor == [NSNull null] ? NSNotFound : [_arranged indexOfObjectIdenticalTo:anchor];
        if (at == NSNotFound)
            at = [_arranged count];
        /* shift what was selected or inserted at or after the new index */
        [_selection shiftIndexesStartingAtIndex:at by:1];
        [inserted shiftIndexesStartingAtIndex:at by:1];
        [_arranged insertObject:o atIndex:at];
        [inserted addIndex:at];
    }
    if (_ac.selectsInserted && [inserted count]) {
        [_selection removeAllIndexes];
        [_selection addIndexes:inserted];
    }
    if (_ac.autoRearranges && [_sortDescriptors count]) {
        /* rearranging automatically: the new objects are sorted in, the selection kept */
        NSArray *selected = [self selectedObjects];
        [_arranged setArray:[self arrangeObjects:content_array(_content)]];
        [_selection removeAllIndexes];
        [_selection addIndexes:[self _finchIndexesOfObjects:selected]];
    }
    [self _finchDidChange];
    [self _finchSelectionChangedByController];
}

- (void)insertObject:(id)object atArrangedObjectIndex:(NSUInteger)index
{
    [self insertObjects:@[ object ] atArrangedObjectIndexes:[NSIndexSet indexSetWithIndex:index]];
}

- (void)addObjects:(NSArray *)objects
{
    NSMutableIndexSet *at = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < [objects count]; i++)
        [at addIndex:[_arranged count] + 1000000 + i]; /* past the end: appended */
    [self insertObjects:objects atArrangedObjectIndexes:at];
}

- (void)addObject:(id)object
{
    [self addObjects:@[ object ]];
}

- (void)removeObjectsAtArrangedObjectIndexes:(NSIndexSet *)indexes
{
    NSMutableIndexSet *valid = [NSMutableIndexSet indexSet];
    [indexes enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
        if (i < [_arranged count])
            [valid addIndex:i];
    }];
    if (![valid count])
        return;
    NSArray *gone = [_arranged objectsAtIndexes:valid];
    NSUInteger firstSelected = [_selection count] ? [_selection firstIndex] : NSNotFound;
    __block BOOL removedSelected = NO;
    [valid enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
        if ([_selection containsIndex:i])
            removedSelected = *stop = YES;
    }];
    [self _finchWillChange:CH_ARRANGED | CH_SELECTION];
    [self _finchMutateContent:^(NSMutableArray *content) {
        for (id o in gone) {
            NSUInteger i = [content indexOfObjectIdenticalTo:o];
            if (i != NSNotFound)
                [content removeObjectAtIndex:i];
        }
    }];
    /* the selection keeps its remaining objects */
    NSMutableIndexSet *sel = [NSMutableIndexSet indexSet];
    [_selection enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
        if ([valid containsIndex:i])
            return;
        NSUInteger below = [valid countOfIndexesInRange:NSMakeRange(0, i)];
        [sel addIndex:i - below];
    }];
    [_arranged removeObjectsAtIndexes:valid];
    if (![sel count] && removedSelected && _ac.avoidsEmpty && [_arranged count]) {
        NSUInteger i = firstSelected - [valid countOfIndexesInRange:NSMakeRange(0, firstSelected)];
        [sel addIndex:MIN(i, [_arranged count] - 1)];
    }
    [_selection removeAllIndexes];
    [_selection addIndexes:sel];
    [self _finchDidChange];
    [self _finchSelectionChangedByController];
}

- (void)removeObjectAtArrangedObjectIndex:(NSUInteger)index
{
    [self removeObjectsAtArrangedObjectIndexes:[NSIndexSet indexSetWithIndex:index]];
}

- (void)removeObjects:(NSArray *)objects
{
    NSMutableIndexSet *s = [NSMutableIndexSet indexSet];
    for (id o in objects) {
        NSUInteger i = [_arranged indexOfObjectIdenticalTo:o];
        if (i != NSNotFound) {
            [s addIndex:i];
        } else {
            /* not arranged (filtered out): only from the content */
            [self _finchWillChange:CH_ARRANGED];
            [self _finchMutateContent:^(NSMutableArray *content) {
                NSUInteger j = [content indexOfObjectIdenticalTo:o];
                if (j != NSNotFound)
                    [content removeObjectAtIndex:j];
            }];
            [self _finchDidChange];
        }
    }
    [self removeObjectsAtArrangedObjectIndexes:s];
}

- (void)removeObject:(id)object
{
    [self removeObjects:@[ object ]];
}

- (void)_finchDeferredAdd
{
    id o = [self newObject];
    [self addObject:o];
    [o release];
}

- (void)_finchDeferredInsert
{
    id o = [self newObject];
    NSUInteger i = [self selectionIndex];
    [self insertObject:o atArrangedObjectIndex:i == NSNotFound ? 0 : i];
    [o release];
}

- (void)_finchDeferredRemove
{
    [self removeObjectsAtArrangedObjectIndexes:[self selectionIndexes]];
}

- (IBAction)insert:(id)sender
{
    if (![self commitEditing])
        return;
    [self performSelector:@selector(_finchDeferredInsert) withObject:nil afterDelay:0];
}

- (void)prepareContent
{
    [self setContent:[NSMutableArray array]];
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item
{
    SEL a = [item action];
    if (a == @selector(insert:))
        return [self canInsert];
    if (a == @selector(selectNext:))
        return [self canSelectNext];
    if (a == @selector(selectPrevious:))
        return [self canSelectPrevious];
    return [super validateUserInterfaceItem:item];
}

#pragma mark Bindings

- (BOOL)_finchHandlesBinding:(NSString *)binding
{
    return [binding isEqualToString:NSContentArrayBinding] || [binding isEqualToString:NSContentSetBinding] ||
           [binding isEqualToString:NSSelectionIndexesBinding] || [binding isEqualToString:NSSortDescriptorsBinding] ||
           [binding isEqualToString:NSFilterPredicateBinding] || [super _finchHandlesBinding:binding];
}

- (Class)_finchValueClassForBinding:(NSString *)binding
{
    if ([binding isEqualToString:NSSelectionIndexesBinding])
        return [NSIndexSet class];
    if ([binding isEqualToString:NSSortDescriptorsBinding])
        return [NSArray class];
    if ([binding isEqualToString:NSFilterPredicateBinding])
        return [NSPredicate class];
    return [super _finchValueClassForBinding:binding];
}

- (NSDictionary *)_finchDefaultOptionsForBinding:(NSString *)binding
{
    if ([binding isEqualToString:NSSelectionIndexesBinding] || [binding isEqualToString:NSSortDescriptorsBinding] ||
        [binding isEqualToString:NSFilterPredicateBinding]) {
        NSMutableDictionary *d = [[[super _finchDefaultOptionsForBinding:binding] mutableCopy] autorelease];
        [d setObject:@NO forKey:NSAlwaysPresentsApplicationModalAlertsBindingOption];
        [d setObject:@NO forKey:NSValidatesImmediatelyBindingOption];
        return d;
    }
    return [super _finchDefaultOptionsForBinding:binding];
}

- (void)_finchBindingChanged:(_FinchBinding *)b
{
    NSString *name = b->_name;
    int kind;
    id v = [b valueWithKind:&kind];
    if (NSIsControllerMarker(v))
        v = nil;
    if ([name isEqualToString:NSContentArrayBinding] || [name isEqualToString:NSContentSetBinding] ||
        [name isEqualToString:NSContentObjectBinding]) {
        _ac.selectsAllOnContent = [[b->_options objectForKey:NSSelectsAllWhenSettingContentBindingOption] boolValue];
        [self _finchSetContent:v];
        _ac.selectsAllOnContent = 0;
        return;
    }
    if ([name isEqualToString:NSSelectionIndexesBinding]) {
        [self _finchSelect:[v isKindOfClass:[NSIndexSet class]] ? v : [NSIndexSet indexSet]];
        return;
    }
    if ([name isEqualToString:NSSortDescriptorsBinding]) {
        b->_pushing = YES;
        [self setSortDescriptors:[v isKindOfClass:[NSArray class]] ? v : @[]];
        b->_pushing = NO;
        return;
    }
    if ([name isEqualToString:NSFilterPredicateBinding]) {
        b->_pushing = YES;
        [self setFilterPredicate:[v isKindOfClass:[NSPredicate class]] ? v : nil];
        b->_pushing = NO;
        return;
    }
    [super _finchBindingChanged:b];
}

@end

#pragma mark - NSTreeController

@class NSTreeController;
extern NSArray *FinchTreeNodeSortDescriptors(NSArray *sortDescriptors); /* (NSTreeNode.m) */

/* A tree controller's node: its children are its object's, by the controller's
   children key path, built when first asked for and kept (so a node stays the same
   object) until the controller rearranges or the object's children change under KVO. */
@interface NSTreeControllerTreeNode : NSTreeNode {
@public
    NSTreeController *_controller; /* (not retained) */
    BOOL _built, _observing;
}
@end

/* The arranged objects: the root node, whose object holds the content under the
   children key path, as Apple's. */
@interface _NSControllerTreeProxy : NSTreeControllerTreeNode
@end

@interface NSTreeController ()
- (NSArray *)_finchChildObjectsOfNode:(NSTreeControllerTreeNode *)node;
- (BOOL)_finchNodeIsLeaf:(NSTreeControllerTreeNode *)node;
- (void)_finchChildrenChangedOfNode:(NSTreeControllerTreeNode *)node;
- (BOOL)_finchIsMutating;
@end

static char tree_children_context;

@implementation NSTreeControllerTreeNode

- (void)_finchStopObserving
{
    if (_observing && _controller && [_controller childrenKeyPath])
        @try {
            [[self representedObject] removeObserver:self forKeyPath:[_controller childrenKeyPath] context:&tree_children_context];
        } @catch (NSException *e) {
        }
    _observing = NO;
}

/* (the whole subtree stops watching and forgets its controller) */
- (void)_finchDetach
{
    [self _finchStopObserving];
    for (NSTreeControllerTreeNode *c in [self _finchChildStorage])
        [c _finchDetach];
    _controller = nil;
}

- (void)dealloc
{
    [self _finchStopObserving];
    [super dealloc];
}

- (void)_finchBuild
{
    if (_built || !_controller)
        return;
    _built = YES;
    if ([_controller _finchNodeIsLeaf:self] && ![self isKindOfClass:[_NSControllerTreeProxy class]])
        return;
    NSArray *objects = [_controller _finchChildObjectsOfNode:self];
    NSMutableArray *nodes = [NSMutableArray arrayWithCapacity:[objects count]];
    for (id o in objects) {
        NSTreeControllerTreeNode *n = [[NSTreeControllerTreeNode alloc] initWithRepresentedObject:o];
        n->_controller = _controller;
        [nodes addObject:n];
        [n release];
    }
    [self _finchSetChildren:nodes];
    if (!_observing && ![self isKindOfClass:[_NSControllerTreeProxy class]] && [_controller childrenKeyPath]) {
        [[self representedObject] addObserver:self forKeyPath:[_controller childrenKeyPath] options:0 context:&tree_children_context];
        _observing = YES;
    }
}

/* Rebuilt from the objects as they are now, keeping the nodes of objects still there
   (and their subtrees, rebuilt in turn). */
- (void)_finchRebuild
{
    if (!_built) {
        [self _finchBuild];
        return;
    }
    NSArray *objects = [_controller _finchNodeIsLeaf:self] && ![self isKindOfClass:[_NSControllerTreeProxy class]]
                           ? @[]
                           : [_controller _finchChildObjectsOfNode:self];
    NSArray *old = [[[self _finchChildStorage] copy] autorelease];
    NSMutableArray *nodes = [NSMutableArray arrayWithCapacity:[objects count]];
    for (id o in objects) {
        NSTreeControllerTreeNode *found = nil;
        for (NSTreeControllerTreeNode *n in old)
            if ([n representedObject] == o && ![nodes containsObject:n]) {
                found = n;
                break;
            }
        if (!found) {
            found = [[[NSTreeControllerTreeNode alloc] initWithRepresentedObject:o] autorelease];
            found->_controller = _controller;
        }
        [nodes addObject:found];
    }
    for (NSTreeControllerTreeNode *n in old)
        if (![nodes containsObject:n])
            [n _finchDetach];
    [self _finchSetChildren:nodes];
    for (NSTreeControllerTreeNode *n in nodes)
        if (n->_built)
            [n _finchRebuild];
    if (!_observing && ![self isKindOfClass:[_NSControllerTreeProxy class]] && [_controller childrenKeyPath] && [nodes count]) {
        [[self representedObject] addObserver:self forKeyPath:[_controller childrenKeyPath] options:0 context:&tree_children_context];
        _observing = YES;
    }
}

- (NSArray *)childNodes
{
    [self _finchBuild];
    return [super childNodes];
}

- (BOOL)isLeaf
{
    if ([self isKindOfClass:[_NSControllerTreeProxy class]])
        return NO;
    return _controller ? [_controller _finchNodeIsLeaf:self] : [super isLeaf];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context != &tree_children_context) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    if (_controller && ![_controller _finchIsMutating])
        [_controller _finchChildrenChangedOfNode:self];
}

@end

@implementation _NSControllerTreeProxy
@end

enum { TC_CONTENT = 1, TC_ARRANGED = 2, TC_SELECTION = 4, TC_ALL = 7 };

static NSArray *
tree_change_keys(int mask)
{
    NSMutableArray *k = [NSMutableArray array];
    if (mask & TC_CONTENT)
        [k addObject:@"content"];
    if (mask & TC_ARRANGED)
        [k addObject:@"arrangedObjects"];
    if (mask & (TC_SELECTION | TC_ARRANGED))
        [k addObjectsFromArray:@[ @"selectionIndexPaths", @"selectionIndexPath", @"selectedObjects", @"selectedNodes", @"selection",
                                  @"canRemove", @"canAddChild", @"canInsertChild" ]];
    return k;
}

static NSIndexPath *
path_by_adding(NSIndexPath *p, NSUInteger index)
{
    return p ? [p indexPathByAddingIndex:index] : [NSIndexPath indexPathWithIndex:index];
}

@implementation NSTreeController {
    NSString *_childrenKeyPath, *_countKeyPath, *_leafKeyPath;
    NSArray *_treeSortDescriptors;
    NSMutableArray *_selectionPaths;
    _NSControllerTreeProxy *_root;
    struct {
        unsigned avoidsEmpty : 1;
        unsigned preserves : 1;
        unsigned selectsInserted : 1;
        unsigned alwaysMultiple : 1;
    } _tc;
    NSInteger _mutating;
}

+ (BOOL)automaticallyNotifiesObserversForKey:(NSString *)key
{
    static NSSet *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = [[NSSet alloc] initWithArray:@[ @"selectionIndexPaths", @"selectionIndexPath", @"selectedNodes", @"canAddChild",
                                               @"canInsertChild", @"childrenKeyPath", @"countKeyPath", @"leafKeyPath" ]];
    });
    if ([keys containsObject:key])
        return NO;
    return [super automaticallyNotifiesObserversForKey:key];
}

+ (NSArray *)_finchBuiltinBindings
{
    return @[
        NSEditableBinding, NSContentArrayBinding, NSContentObjectBinding, NSSelectionIndexPathsBinding, NSSortDescriptorsBinding,
        NSManagedObjectContextBinding
    ];
}

static void
tc_defaults(NSTreeController *self)
{
    self->_selectionPaths = [[NSMutableArray alloc] init];
    self->_tc.avoidsEmpty = self->_tc.preserves = self->_tc.selectsInserted = 1;
}

- (instancetype)initWithContent:(id)content
{
    self = [super initWithContent:nil];
    if (!self)
        return nil;
    tc_defaults(self);
    if (content)
        [self setContent:content];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self)
        return nil;
    tc_defaults(self);
    _childrenKeyPath = [[coder decodeObjectForKey:@"NSTreeContentChildrenKey"] copy];
    _countKeyPath = [[coder decodeObjectForKey:@"NSTreeContentCountKey"] copy];
    _leafKeyPath = [[coder decodeObjectForKey:@"NSTreeContentLeafKey"] copy];
    _tc.avoidsEmpty = [coder decodeBoolForKey:@"NSAvoidsEmptySelection"];
    _tc.preserves = [coder decodeBoolForKey:@"NSPreservesSelection"];
    _tc.selectsInserted = [coder decodeBoolForKey:@"NSSelectsInsertedObjects"];
    _tc.alwaysMultiple = [coder decodeBoolForKey:@"NSAlwaysUsesMultipleValuesMarker"];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    if (_childrenKeyPath)
        [coder encodeObject:_childrenKeyPath forKey:@"NSTreeContentChildrenKey"];
    if (_countKeyPath)
        [coder encodeObject:_countKeyPath forKey:@"NSTreeContentCountKey"];
    if (_leafKeyPath)
        [coder encodeObject:_leafKeyPath forKey:@"NSTreeContentLeafKey"];
    if (_tc.avoidsEmpty)
        [coder encodeBool:YES forKey:@"NSAvoidsEmptySelection"];
    if (_tc.preserves)
        [coder encodeBool:YES forKey:@"NSPreservesSelection"];
    if (_tc.selectsInserted)
        [coder encodeBool:YES forKey:@"NSSelectsInsertedObjects"];
    if (_tc.alwaysMultiple)
        [coder encodeBool:YES forKey:@"NSAlwaysUsesMultipleValuesMarker"];
}

- (void)dealloc
{
    [_root _finchDetach];
    [_root release];
    [_childrenKeyPath release];
    [_countKeyPath release];
    [_leafKeyPath release];
    [_treeSortDescriptors release];
    [_selectionPaths release];
    [super dealloc];
}

#pragma mark Change notification

- (void)_finchWillChange { [self _finchWillChange:TC_ALL]; }

- (void)_finchWillChange:(int)mask
{
    if (_changeDepth++) {
        _changeMask |= mask;
        return;
    }
    _changeMask = mask;
    for (NSString *k in tree_change_keys(mask))
        [self willChangeValueForKey:k];
}

- (void)_finchDidChange
{
    if (--_changeDepth)
        return;
    [self _finchObjectsChanged];
    for (NSString *k in [tree_change_keys(_changeMask) reverseObjectEnumerator])
        [self didChangeValueForKey:k];
}

- (NSArray *)_finchProxyObjects { return [self selectedObjects]; }
- (BOOL)_finchAlwaysUsesMultipleValuesMarker { return _tc.alwaysMultiple; }
- (BOOL)_finchIsMutating { return _mutating > 0; }

- (BOOL)_finchContentIsBound
{
    return FinchBindingFor(self, NSContentArrayBinding) || [super _finchContentIsBound];
}

#pragma mark Keys and flags

- (NSString *)childrenKeyPath { return _childrenKeyPath; }
- (NSString *)countKeyPath { return _countKeyPath; }
- (NSString *)leafKeyPath { return _leafKeyPath; }

/* (a key path changes what the nodes are: the tree is made again) */
- (void)_finchSetKey:(NSString **)slot to:(NSString *)value
{
    if (*slot == value || [*slot isEqualToString:value])
        return;
    [self _finchWillChange:TC_ARRANGED];
    [_root _finchDetach];
    [_root release];
    _root = nil;
    [*slot release];
    *slot = [value copy];
    [self _finchDidChange];
}

- (void)setChildrenKeyPath:(NSString *)keyPath { [self _finchSetKey:&_childrenKeyPath to:keyPath]; }
- (void)setCountKeyPath:(NSString *)keyPath { [self _finchSetKey:&_countKeyPath to:keyPath]; }
- (void)setLeafKeyPath:(NSString *)keyPath { [self _finchSetKey:&_leafKeyPath to:keyPath]; }
- (NSString *)childrenKeyPathForNode:(NSTreeNode *)node { return _childrenKeyPath; }
- (NSString *)countKeyPathForNode:(NSTreeNode *)node { return _countKeyPath; }
- (NSString *)leafKeyPathForNode:(NSTreeNode *)node { return _leafKeyPath; }

- (BOOL)avoidsEmptySelection { return _tc.avoidsEmpty; }
- (void)setAvoidsEmptySelection:(BOOL)flag { _tc.avoidsEmpty = flag; }
- (BOOL)preservesSelection { return _tc.preserves; }
- (void)setPreservesSelection:(BOOL)flag { _tc.preserves = flag; }
- (BOOL)selectsInsertedObjects { return _tc.selectsInserted; }
- (void)setSelectsInsertedObjects:(BOOL)flag { _tc.selectsInserted = flag; }
- (BOOL)alwaysUsesMultipleValuesMarker { return _tc.alwaysMultiple; }
- (void)setAlwaysUsesMultipleValuesMarker:(BOOL)flag
{
    [self _finchWillChange:TC_SELECTION];
    _tc.alwaysMultiple = flag;
    [self _finchDidChange];
}

#pragma mark The tree

/* A node's child objects: the content for the root, the object's children by the
   children key path otherwise, sorted by the sort descriptors. */
- (NSArray *)_finchChildObjectsOfNode:(NSTreeControllerTreeNode *)node
{
    id kids = node == _root ? _content : [[node representedObject] valueForKeyPath:_childrenKeyPath];
    NSArray *objects = content_array(kids);
    if ([_treeSortDescriptors count] && [objects count] > 1)
        objects = [objects sortedArrayUsingDescriptors:_treeSortDescriptors];
    return objects;
}

/* As Apple's: the leaf key path's value if there is one, else no children by the count
   key path, else no children at all. */
- (BOOL)_finchNodeIsLeaf:(NSTreeControllerTreeNode *)node
{
    id o = [node representedObject];
    if (_leafKeyPath)
        return [[o valueForKeyPath:_leafKeyPath] boolValue];
    if (_countKeyPath)
        return [[o valueForKeyPath:_countKeyPath] unsignedIntegerValue] == 0;
    id kids = _childrenKeyPath ? [o valueForKeyPath:_childrenKeyPath] : nil;
    return !kids || [kids count] == 0;
}

- (_NSControllerTreeProxy *)_finchRoot
{
    if (!_root) {
        id holder = _childrenKeyPath ? @{_childrenKeyPath : content_array(_content)} : @{};
        _root = [[_NSControllerTreeProxy alloc] initWithRepresentedObject:holder];
        _root->_controller = self;
    }
    return _root;
}

- (id)arrangedObjects
{
    if (!_childrenKeyPath)
        [NSException raise:NSInternalInconsistencyException
                    format:@"%@[object class: %@] Cannot perform operation because childrenKeyPath is nil", self,
                           NSStringFromClass([self objectClass])];
    return [self _finchRoot];
}

- (NSTreeControllerTreeNode *)_finchNodeAtPath:(NSIndexPath *)path
{
    if (!path || !_childrenKeyPath)
        return nil;
    return (NSTreeControllerTreeNode *)[[self _finchRoot] descendantNodeAtIndexPath:path];
}

/* A node's children changed under KVO: rebuilt, the arrangement notified. */
- (void)_finchChildrenChangedOfNode:(NSTreeControllerTreeNode *)node
{
    [self _finchWillChange:TC_ARRANGED];
    [node _finchRebuild];
    [self _finchDidChange];
}

- (void)rearrangeObjects
{
    [self _finchWillChange:TC_ARRANGED];
    if (_root) {
        NSDictionary *holder = _childrenKeyPath ? @{_childrenKeyPath : content_array(_content)} : @{};
        _NSControllerTreeProxy *root = [[_NSControllerTreeProxy alloc] initWithRepresentedObject:holder];
        root->_controller = self;
        root->_built = YES;
        [root _finchSetChildren:[_root childNodes]];
        [_root release];
        _root = root;
        [_root _finchRebuild];
    }
    [self _finchDidChange];
}

- (NSArray *)sortDescriptors { return _treeSortDescriptors ?: @[]; }

- (void)setSortDescriptors:(NSArray *)descriptors
{
    [self willChangeValueForKey:@"sortDescriptors"];
    [_treeSortDescriptors release];
    _treeSortDescriptors = [descriptors copy];
    [self didChangeValueForKey:@"sortDescriptors"];
    _FinchBinding *b = FinchBindingFor(self, NSSortDescriptorsBinding);
    if (b && !b->_pushing)
        [b push:descriptors];
    [self rearrangeObjects];
}

#pragma mark Content

- (NSArray *)_finchSelectedObjectsNow
{
    NSMutableArray *objects = [NSMutableArray array];
    for (NSIndexPath *p in _selectionPaths) {
        id o = [[self _finchNodeAtPath:p] representedObject];
        if (o)
            [objects addObject:o];
    }
    return objects;
}

- (NSIndexPath *)_finchPathOfObject:(id)object under:(NSTreeNode *)node
{
    for (NSTreeNode *c in [node childNodes]) {
        if ([c representedObject] == object)
            return [c indexPath];
        if (![c isLeaf]) {
            NSIndexPath *p = [self _finchPathOfObject:object under:c];
            if (p)
                return p;
        }
    }
    return nil;
}

/* New content: the tree is made again (keeping nodes of objects still there); the
   selection keeps its objects where it can (preservesSelection) and selects the first
   object when it would be empty (avoidsEmptySelection). */
- (void)_finchSetContent:(id)content
{
    NSArray *kept = _tc.preserves && _childrenKeyPath ? [self _finchSelectedObjectsNow] : nil;
    [self _finchWillChange:TC_ALL];
    [content retain];
    [_content release];
    _content = content;
    if (_root) {
        NSDictionary *holder = _childrenKeyPath ? @{_childrenKeyPath : content_array(_content)} : @{};
        _NSControllerTreeProxy *root = [[_NSControllerTreeProxy alloc] initWithRepresentedObject:holder];
        root->_controller = self;
        root->_built = YES;
        [root _finchSetChildren:[_root childNodes]];
        [_root release];
        _root = root;
        [_root _finchRebuild];
    }
    [_selectionPaths removeAllObjects];
    if (_childrenKeyPath) {
        for (id o in kept) {
            NSIndexPath *p = [self _finchPathOfObject:o under:[self _finchRoot]];
            if (p)
                [_selectionPaths addObject:p];
        }
        if (![_selectionPaths count] && _tc.avoidsEmpty && [content_array(_content) count])
            [_selectionPaths addObject:[NSIndexPath indexPathWithIndex:0]];
    }
    [self _finchDidChange];
    [self _finchSelectionChangedByController];
}

- (void)setContent:(id)content { [self _finchSetContent:content]; }

/* The model array a node's children come from: the content for the root (through the
   content binding when there is one), the object's children otherwise. */
- (void)_finchMutateChildrenOf:(NSTreeControllerTreeNode *)parent with:(void (^)(NSMutableArray *objects))change
{
    _mutating++;
    @try {
        if (parent != _root) {
            change([[parent representedObject] mutableArrayValueForKeyPath:_childrenKeyPath]);
            return;
        }
        _FinchBinding *b = FinchBindingFor(self, NSContentArrayBinding);
        if (b && b->_observed) {
            b->_pushing = YES;
            @try {
                change([b->_observed mutableArrayValueForKeyPath:b->_keyPath]);
            } @finally {
                b->_pushing = NO;
            }
            id now = [b rawValue];
            if (now != _content) {
                [now retain];
                [_content release];
                _content = now;
            }
        } else if ([_content isKindOfClass:[NSMutableArray class]]) {
            change(_content);
        } else {
            NSMutableArray *copy = [NSMutableArray arrayWithArray:content_array(_content)];
            change(copy);
            [_content release];
            _content = [copy retain];
        }
    } @finally {
        _mutating--;
    }
}

/* (the arranged index's model index: where the node now there sits in the model, or the
   end when sorted; the same index when not) */
static NSUInteger
model_index(NSArray *model, NSTreeNode *parent, NSUInteger arranged, BOOL sorted)
{
    if (!sorted)
        return MIN(arranged, [model count]);
    NSArray *kids = [parent childNodes];
    if (arranged < [kids count]) {
        NSUInteger at = [model indexOfObjectIdenticalTo:[kids[arranged] representedObject]];
        if (at != NSNotFound)
            return at;
    }
    return [model count];
}

- (void)insertObjects:(NSArray *)objects atArrangedObjectIndexPaths:(NSArray<NSIndexPath *> *)indexPaths
{
    if (![objects count] || [objects count] != [indexPaths count] || !_childrenKeyPath)
        return;
    [self _finchWillChange:TC_ARRANGED]; /* (not content: Apple's doesn't post it) */
    NSMutableArray *inserted = [NSMutableArray array];
    for (NSUInteger i = 0; i < [objects count]; i++) {
        NSIndexPath *path = indexPaths[i];
        NSIndexPath *parentPath = [path length] > 1 ? [path indexPathByRemovingLastIndex] : nil;
        NSTreeControllerTreeNode *parent = parentPath ? [self _finchNodeAtPath:parentPath] : [self _finchRoot];
        if (!parent)
            continue;
        [parent _finchBuild];
        NSUInteger at = [path indexAtPosition:[path length] - 1];
        id object = objects[i];
        BOOL sorted = [_treeSortDescriptors count] > 0;
        [self _finchMutateChildrenOf:parent
                                with:^(NSMutableArray *model) {
                                    [model insertObject:object atIndex:model_index(model, parent, at, sorted)];
                                }];
        NSTreeControllerTreeNode *node = [[NSTreeControllerTreeNode alloc] initWithRepresentedObject:object];
        node->_controller = self;
        at = MIN(at, [[parent _finchChildStorage] count]);
        [parent _finchInsertChild:node atIndex:at];
        [node release];
        [inserted addObject:path_by_adding(parentPath, at)];
    }
    if (_tc.selectsInserted && [inserted count])
        [_selectionPaths setArray:inserted];
    [self _finchDidChange];
    [self _finchSelectionChangedByController];
}

- (void)insertObject:(id)object atArrangedObjectIndexPath:(NSIndexPath *)indexPath
{
    if (object && indexPath)
        [self insertObjects:@[ object ] atArrangedObjectIndexPaths:@[ indexPath ]];
}

/* (deepest and last first, so the paths left stay good) */
static NSArray *
paths_last_first(NSArray *paths)
{
    return [paths sortedArrayUsingComparator:^NSComparisonResult(NSIndexPath *a, NSIndexPath *b) {
        return [b compare:a];
    }];
}

- (void)_finchRemoveNode:(NSTreeControllerTreeNode *)node
{
    NSTreeControllerTreeNode *parent = (NSTreeControllerTreeNode *)[node parentNode];
    if (!parent)
        return;
    id object = [node representedObject];
    [self _finchMutateChildrenOf:parent
                            with:^(NSMutableArray *model) {
                                NSUInteger at = [model indexOfObjectIdenticalTo:object];
                                if (at != NSNotFound)
                                    [model removeObjectAtIndex:at];
                            }];
    NSUInteger at = [[parent _finchChildStorage] indexOfObjectIdenticalTo:node];
    if (at != NSNotFound) {
        [node _finchDetach];
        [parent _finchRemoveChildAtIndex:at];
    }
}

/* As Apple's, the selection's paths stay as they were. */
- (void)removeObjectsAtArrangedObjectIndexPaths:(NSArray<NSIndexPath *> *)indexPaths
{
    if (![indexPaths count] || !_childrenKeyPath)
        return;
    [self _finchWillChange:TC_ARRANGED]; /* (not content: Apple's doesn't post it) */
    NSMutableArray *nodes = [NSMutableArray array];
    for (NSIndexPath *p in paths_last_first(indexPaths)) {
        NSTreeControllerTreeNode *n = [self _finchNodeAtPath:p];
        if (n)
            [nodes addObject:n];
    }
    for (NSTreeControllerTreeNode *n in nodes)
        [self _finchRemoveNode:n];
    [self _finchDidChange];
}

- (void)removeObjectAtArrangedObjectIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath)
        [self removeObjectsAtArrangedObjectIndexPaths:@[ indexPath ]];
}

/* The nodes leave their parents and go, in order, to the index path's parent from its
   last index on. */
- (void)moveNodes:(NSArray<NSTreeNode *> *)nodes toIndexPath:(NSIndexPath *)startingIndexPath
{
    if (![nodes count] || !startingIndexPath || !_childrenKeyPath)
        return;
    NSIndexPath *parentPath = [startingIndexPath length] > 1 ? [startingIndexPath indexPathByRemovingLastIndex] : nil;
    NSTreeControllerTreeNode *target = parentPath ? [self _finchNodeAtPath:parentPath] : [self _finchRoot];
    if (!target)
        return;
    [self _finchWillChange:TC_ARRANGED]; /* (not content: Apple's doesn't post it) */
    [target _finchBuild];
    NSUInteger at = [startingIndexPath indexAtPosition:[startingIndexPath length] - 1];
    for (NSTreeControllerTreeNode *node in nodes) {
        if (![node isKindOfClass:[NSTreeControllerTreeNode class]] || node->_controller != self)
            continue;
        [node retain];
        id object = [node representedObject];
        NSTreeControllerTreeNode *from = (NSTreeControllerTreeNode *)[node parentNode];
        if (from) {
            NSUInteger was = [[from _finchChildStorage] indexOfObjectIdenticalTo:node];
            [self _finchMutateChildrenOf:from
                                    with:^(NSMutableArray *model) {
                                        NSUInteger i = [model indexOfObjectIdenticalTo:object];
                                        if (i != NSNotFound)
                                            [model removeObjectAtIndex:i];
                                    }];
            if (from == target && was != NSNotFound && was < at)
                at--;
        }
        BOOL sorted = [_treeSortDescriptors count] > 0;
        NSUInteger index = at;
        [self _finchMutateChildrenOf:target
                                with:^(NSMutableArray *model) {
                                    [model insertObject:object atIndex:model_index(model, target, index, sorted)];
                                }];
        [target _finchInsertChild:node atIndex:at];
        [node release];
        at++;
    }
    [self _finchDidChange];
}

- (void)moveNode:(NSTreeNode *)node toIndexPath:(NSIndexPath *)indexPath
{
    if (node)
        [self moveNodes:@[ node ] toIndexPath:indexPath];
}

#pragma mark Selection

- (NSArray<NSIndexPath *> *)selectionIndexPaths { return [[_selectionPaths copy] autorelease]; }
- (NSIndexPath *)selectionIndexPath { return [_selectionPaths firstObject]; }

- (NSArray<NSTreeNode *> *)selectedNodes
{
    NSMutableArray *nodes = [NSMutableArray array];
    for (NSIndexPath *p in _selectionPaths) {
        NSTreeNode *n = [self _finchNodeAtPath:p];
        if (n)
            [nodes addObject:n];
    }
    return nodes;
}

- (NSArray *)selectedObjects { return _childrenKeyPath ? [self _finchSelectedObjectsNow] : @[]; }

- (void)_finchSelectionChangedByController
{
    _FinchBinding *b = FinchBindingFor(self, NSSelectionIndexPathsBinding);
    if (b && !b->_pushing)
        [b push:[self selectionIndexPaths]];
}

/* (kept as given, in order and without duplicates; always answers YES, as Apple's) */
- (BOOL)_finchSelectPaths:(NSArray *)paths
{
    [self _finchWillChange:TC_SELECTION];
    NSMutableArray *unique = [NSMutableArray array];
    for (NSIndexPath *p in paths)
        if ([p isKindOfClass:[NSIndexPath class]] && ![unique containsObject:p])
            [unique addObject:p];
    [_selectionPaths setArray:unique];
    [self _finchDidChange];
    return YES;
}

- (BOOL)setSelectionIndexPaths:(NSArray<NSIndexPath *> *)indexPaths
{
    if (![self commitEditing])
        return NO;
    BOOL r = [self _finchSelectPaths:indexPaths ?: @[]];
    [self _finchSelectionChangedByController];
    return r;
}

- (BOOL)setSelectionIndexPath:(NSIndexPath *)indexPath
{
    return [self setSelectionIndexPaths:indexPath ? @[ indexPath ] : @[]];
}

- (BOOL)addSelectionIndexPaths:(NSArray<NSIndexPath *> *)indexPaths
{
    return [self setSelectionIndexPaths:[_selectionPaths arrayByAddingObjectsFromArray:indexPaths ?: @[]]];
}

- (BOOL)removeSelectionIndexPaths:(NSArray<NSIndexPath *> *)indexPaths
{
    NSMutableArray *left = [[_selectionPaths mutableCopy] autorelease];
    [left removeObjectsInArray:indexPaths ?: @[]];
    return [self setSelectionIndexPaths:left];
}

#pragma mark Adding and removing

- (BOOL)canAdd { return [self isEditable]; }
- (BOOL)canInsert { return [self isEditable]; }
- (BOOL)canRemove { return [self isEditable] && [_selectionPaths count] > 0; }

/* (a child can go under the selection when nothing is selected, at the top, or when the
   first selected node isn't a leaf) */
- (BOOL)canAddChild
{
    if (![self isEditable])
        return NO;
    if (![_selectionPaths count])
        return YES;
    NSTreeNode *n = [self _finchNodeAtPath:_selectionPaths[0]];
    return n && ![n isLeaf];
}

- (BOOL)canInsertChild { return [self canAddChild]; }

- (void)_finchDeferredAdd
{
    id o = [self newObject];
    NSIndexPath *sel = [_selectionPaths firstObject];
    NSIndexPath *parentPath = [sel length] > 1 ? [sel indexPathByRemovingLastIndex] : nil;
    NSTreeNode *parent = parentPath ? [self _finchNodeAtPath:parentPath] : [self _finchRoot];
    [self insertObject:o atArrangedObjectIndexPath:path_by_adding(parentPath, [[parent childNodes] count])];
    [o release];
}

- (void)_finchDeferredInsert
{
    id o = [self newObject];
    [self insertObject:o atArrangedObjectIndexPath:[_selectionPaths firstObject] ?: [NSIndexPath indexPathWithIndex:0]];
    [o release];
}

- (void)_finchDeferredAddChild
{
    id o = [self newObject];
    NSIndexPath *sel = [_selectionPaths firstObject];
    NSTreeNode *parent = sel ? [self _finchNodeAtPath:sel] : [self _finchRoot];
    [self insertObject:o atArrangedObjectIndexPath:path_by_adding(sel, [[parent childNodes] count])];
    [o release];
}

- (void)_finchDeferredInsertChild
{
    id o = [self newObject];
    [self insertObject:o atArrangedObjectIndexPath:path_by_adding([_selectionPaths firstObject], 0)];
    [o release];
}

- (void)_finchDeferredRemove
{
    [self removeObjectsAtArrangedObjectIndexPaths:[self selectionIndexPaths]];
}

- (IBAction)add:(id)sender
{
    if ([self commitEditing])
        [self performSelector:@selector(_finchDeferredAdd) withObject:nil afterDelay:0];
}

- (IBAction)insert:(id)sender
{
    if ([self commitEditing])
        [self performSelector:@selector(_finchDeferredInsert) withObject:nil afterDelay:0];
}

- (IBAction)addChild:(id)sender
{
    if ([self commitEditing])
        [self performSelector:@selector(_finchDeferredAddChild) withObject:nil afterDelay:0];
}

- (IBAction)insertChild:(id)sender
{
    if ([self commitEditing])
        [self performSelector:@selector(_finchDeferredInsertChild) withObject:nil afterDelay:0];
}

- (IBAction)remove:(id)sender
{
    if ([self commitEditing])
        [self _finchDeferredRemove];
}

- (void)addObject:(id)object
{
    [self insertObject:object atArrangedObjectIndexPath:[NSIndexPath indexPathWithIndex:[[[self _finchRoot] childNodes] count]]];
}

- (void)removeObject:(id)object
{
    NSIndexPath *p = [self _finchPathOfObject:object under:[self _finchRoot]];
    if (p)
        [self removeObjectAtArrangedObjectIndexPath:p];
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item
{
    SEL a = [item action];
    if (a == @selector(insert:))
        return [self canInsert];
    if (a == @selector(addChild:))
        return [self canAddChild];
    if (a == @selector(insertChild:))
        return [self canInsertChild];
    if (a == @selector(add:))
        return [self canAdd];
    return [super validateUserInterfaceItem:item];
}

#pragma mark Bindings

- (BOOL)_finchHandlesBinding:(NSString *)binding
{
    return [binding isEqualToString:NSContentArrayBinding] || [binding isEqualToString:NSSelectionIndexPathsBinding] ||
           [binding isEqualToString:NSSortDescriptorsBinding] || [super _finchHandlesBinding:binding];
}

- (Class)_finchValueClassForBinding:(NSString *)binding
{
    if ([binding isEqualToString:NSSelectionIndexPathsBinding] || [binding isEqualToString:NSSortDescriptorsBinding])
        return [NSArray class];
    return [super _finchValueClassForBinding:binding];
}

- (void)_finchBindingChanged:(_FinchBinding *)b
{
    NSString *name = b->_name;
    int kind;
    id v = [b valueWithKind:&kind];
    if (NSIsControllerMarker(v))
        v = nil;
    if ([name isEqualToString:NSContentArrayBinding] || [name isEqualToString:NSContentObjectBinding]) {
        [self _finchSetContent:v];
        return;
    }
    if ([name isEqualToString:NSSelectionIndexPathsBinding]) {
        [self _finchSelectPaths:[v isKindOfClass:[NSArray class]] ? v : @[]];
        return;
    }
    if ([name isEqualToString:NSSortDescriptorsBinding]) {
        b->_pushing = YES;
        [self setSortDescriptors:[v isKindOfClass:[NSArray class]] ? v : @[]];
        b->_pushing = NO;
        return;
    }
    [super _finchBindingChanged:b];
}

@end

#pragma mark - NSUserDefaultsController

@implementation NSUserDefaultsController {
    NSUserDefaults *_defaults;
    NSDictionary *_initialValues;
    NSMutableDictionary *_pending; /* key -> value (NSNull: removed) */
    BOOL _appliesImmediately, _hasUnapplied, _writing;
    _NSControllerObjectProxy *_values;
}

+ (BOOL)automaticallyNotifiesObserversForKey:(NSString *)key
{
    if ([key isEqualToString:@"hasUnappliedChanges"] || [key isEqualToString:@"values"])
        return NO;
    return [super automaticallyNotifiesObserversForKey:key];
}

+ (NSArray *)_finchBuiltinBindings { return @[]; }

+ (NSUserDefaultsController *)sharedUserDefaultsController
{
    static NSUserDefaultsController *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[NSUserDefaultsController alloc] initWithDefaults:nil initialValues:nil];
    });
    return shared;
}

- (instancetype)init
{
    return [self initWithDefaults:nil initialValues:nil];
}

- (void)_finchStart
{
    _pending = [[NSMutableDictionary alloc] init];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_finchDefaultsChanged:)
                                                 name:NSUserDefaultsDidChangeNotification object:_defaults];
}

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults initialValues:(NSDictionary *)initialValues
{
    self = [super init];
    if (!self)
        return nil;
    _defaults = [(defaults ?: [NSUserDefaults standardUserDefaults]) retain];
    _initialValues = [initialValues copy];
    _appliesImmediately = YES;
    [self _finchStart];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ([coder decodeBoolForKey:@"NSSharedInstance"]) {
        [self release];
        return [[NSUserDefaultsController sharedUserDefaultsController] retain];
    }
    self = [super initWithCoder:coder];
    if (!self)
        return nil;
    _defaults = [[NSUserDefaults standardUserDefaults] retain];
    _initialValues = [[coder decodeObjectForKey:@"NSInitialValues"] copy];
    _appliesImmediately = [coder decodeBoolForKey:@"NSAppliesImmediately"];
    [self _finchStart];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    if (self == [NSUserDefaultsController sharedUserDefaultsController]) {
        [coder encodeBool:YES forKey:@"NSSharedInstance"];
        return;
    }
    if (_initialValues)
        [coder encodeObject:_initialValues forKey:@"NSInitialValues"];
    if (_appliesImmediately)
        [coder encodeBool:YES forKey:@"NSAppliesImmediately"];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [_defaults release];
    [_initialValues release];
    [_pending release];
    [_values release];
    [super dealloc];
}

- (NSUserDefaults *)defaults { return _defaults; }
- (NSDictionary *)initialValues { return _initialValues; }

- (void)setInitialValues:(NSDictionary *)values
{
    [_initialValues release];
    _initialValues = [values copy];
}

- (BOOL)appliesImmediately { return _appliesImmediately; }
- (void)setAppliesImmediately:(BOOL)flag { _appliesImmediately = flag; }
- (BOOL)hasUnappliedChanges { return _hasUnapplied; }

- (void)_finchSetHasUnapplied:(BOOL)flag
{
    if (flag == _hasUnapplied)
        return;
    [self willChangeValueForKey:@"hasUnappliedChanges"];
    _hasUnapplied = flag;
    [self didChangeValueForKey:@"hasUnappliedChanges"];
}

- (id)values
{
    if (!_values)
        _values = [[_NSControllerObjectProxy alloc] _finchInitWithController:self];
    return _values;
}

- (NSArray *)_finchProxyObjects { return @[]; }

- (id)_finchProxyValueForKeyPath:(NSString *)keyPath
{
    NSRange dot = [keyPath rangeOfString:@"."];
    NSString *key = dot.location == NSNotFound ? keyPath : [keyPath substringToIndex:dot.location];
    id v = [_pending objectForKey:key];
    if (v == [NSNull null])
        v = nil;
    else if (!v)
        v = [_defaults objectForKey:key] ?: [_initialValues objectForKey:key];
    if (dot.location != NSNotFound)
        v = [v valueForKeyPath:[keyPath substringFromIndex:dot.location + 1]];
    return v;
}

/* Tell the values' observers about keys, before and after a change. */
- (void)_finchNotifyKeys:(NSArray *)keys around:(void (^)(void))change
{
    for (NSString *k in keys)
        [_values _finchNotifyKeyPath:k prior:YES];
    change();
    for (NSString *k in keys)
        [_values _finchNotifyKeyPath:k prior:NO];
}

- (void)_finchWrite:(id)value forKey:(NSString *)key
{
    _writing = YES;
    @try {
        if (value && value != [NSNull null])
            [_defaults setObject:value forKey:key];
        else
            [_defaults removeObjectForKey:key];
    } @finally {
        _writing = NO;
    }
}

- (void)_finchProxySetValue:(id)value forKeyPath:(NSString *)keyPath
{
    NSRange dot = [keyPath rangeOfString:@"."];
    if (dot.location != NSNotFound) {
        [[self _finchProxyValueForKeyPath:[keyPath substringToIndex:dot.location]]
            setValue:value
              forKeyPath:[keyPath substringFromIndex:dot.location + 1]];
        return;
    }
    [self _finchNotifyKeys:@[ keyPath ] around:^{
        if (_appliesImmediately) {
            [self _finchWrite:value forKey:keyPath];
        } else {
            [_pending setObject:value ?: [NSNull null] forKey:keyPath];
        }
    }];
    if (!_appliesImmediately)
        [self _finchSetHasUnapplied:YES];
}

- (void)_finchDefaultsChanged:(NSNotification *)note
{
    if (_writing)
        return;
    NSArray *keys = [_values _finchObservedKeys];
    [self _finchNotifyKeys:keys around:^{
    }];
}

- (void)_finchRevert
{
    NSArray *keys = [_pending allKeys];
    [self _finchNotifyKeys:keys around:^{
        [_pending removeAllObjects];
    }];
    [self _finchSetHasUnapplied:NO];
}

- (void)_finchSave
{
    NSDictionary *p = [[_pending copy] autorelease];
    [_pending removeAllObjects];
    for (NSString *k in p)
        [self _finchWrite:[p objectForKey:k] forKey:k];
    [self _finchSetHasUnapplied:NO];
}

- (void)_finchRevertToInitialValues
{
    if (!_initialValues)
        return;
    NSArray *keys = [_initialValues allKeys];
    [self _finchNotifyKeys:keys around:^{
        for (NSString *k in keys) {
            if (_appliesImmediately)
                [self _finchWrite:[_initialValues objectForKey:k] forKey:k];
            else
                [_pending setObject:[_initialValues objectForKey:k] forKey:k];
        }
    }];
    if (!_appliesImmediately)
        [self _finchSetHasUnapplied:YES];
}

- (IBAction)revert:(id)sender
{
    [self discardEditing];
    [self performSelector:@selector(_finchRevert) withObject:nil afterDelay:0];
}

- (IBAction)save:(id)sender
{
    if (![self commitEditing])
        return;
    [self performSelector:@selector(_finchSave) withObject:nil afterDelay:0];
}

- (IBAction)revertToInitialValues:(id)sender
{
    [self discardEditing];
    [self performSelector:@selector(_finchRevertToInitialValues) withObject:nil afterDelay:0];
}

@end
