// SPDX-License-Identifier: MIT OR Apache-2.0
#import "GCGameControllerPrivate.h"

enum {
    GCElementKindOther,
    GCElementKindButton,
    GCElementKindAxis,
    GCElementKindDpad,
    GCElementKindTouchpad
};

static float GCSaturate(float value, float minimum, float maximum)
{
    if (!isfinite(value))
        return 0.0f;
    return fminf(maximum, fmaxf(minimum, value));
}

static void GCDispatchDeviceHandler(id<GCDevice> device, dispatch_block_t handler)
{
    dispatch_queue_t queue = device.handlerQueue;
    if (!queue)
        queue = dispatch_get_main_queue();
    dispatch_async(queue, handler);
}

@implementation GCControllerElement {
    GCControllerElement *_collection;
    id<GCDevice> _owner;
    NSSet *_aliases;
    NSString *_localizedName;
    NSString *_sfSymbolsName;
    NSString *_unmappedLocalizedName;
    NSString *_unmappedSfSymbolsName;
    GCSystemGestureState _preferredSystemGestureState;
    BOOL _analog;
}

- (instancetype)init
{
    return [self _initWithAlias:nil collection:nil analog:YES owner:nil];
}

- (instancetype)_initWithAlias:(NSString *)alias collection:(GCControllerElement *)collection
                        analog:(BOOL)analog owner:(id<GCDevice>)owner
{
    self = [super init];
    if (self) {
        _collection = collection;
        _owner = owner;
        _analog = analog;
        _preferredSystemGestureState = GCSystemGestureStateEnabled;
        _aliases = alias ? [[NSSet alloc] initWithObjects:alias, nil] : [[NSSet alloc] init];
        _localizedName = [alias copy];
        _unmappedLocalizedName = [alias copy];
    }
    return self;
}

- (void)dealloc
{
    [_aliases release];
    [_localizedName release];
    [_sfSymbolsName release];
    [_unmappedLocalizedName release];
    [_unmappedSfSymbolsName release];
    [super dealloc];
}

- (void)_setOwner:(id<GCDevice>)owner { _owner = owner; }
- (id<GCDevice>)_owner { return _owner; }
- (void)_setAliases:(NSSet *)aliases
{
    if (_aliases != aliases) {
        [_aliases release];
        _aliases = [aliases copy];
    }
}

- (GCControllerElement *)collection { return _collection; }
- (BOOL)isAnalog { return _analog; }
- (BOOL)isBoundToSystemGesture { return NO; }
- (GCSystemGestureState)preferredSystemGestureState { return _preferredSystemGestureState; }
- (void)setPreferredSystemGestureState:(GCSystemGestureState)state
{
    if (state >= GCSystemGestureStateEnabled && state <= GCSystemGestureStateDisabled)
        _preferredSystemGestureState = state;
}
- (NSSet<NSString *> *)aliases { return _aliases; }
- (NSString *)localizedName { return _localizedName; }
- (void)setLocalizedName:(NSString *)name
{
    if (_localizedName != name) {
        [_localizedName release];
        _localizedName = [name copy];
    }
}
- (NSString *)sfSymbolsName { return _sfSymbolsName; }
- (void)setSfSymbolsName:(NSString *)name
{
    if (_sfSymbolsName != name) {
        [_sfSymbolsName release];
        _sfSymbolsName = [name copy];
    }
}
- (NSString *)unmappedLocalizedName { return _unmappedLocalizedName; }
- (void)setUnmappedLocalizedName:(NSString *)name
{
    if (_unmappedLocalizedName != name) {
        [_unmappedLocalizedName release];
        _unmappedLocalizedName = [name copy];
    }
}
- (NSString *)unmappedSfSymbolsName { return _unmappedSfSymbolsName; }
- (void)setUnmappedSfSymbolsName:(NSString *)name
{
    if (_unmappedSfSymbolsName != name) {
        [_unmappedSfSymbolsName release];
        _unmappedSfSymbolsName = [name copy];
    }
}

@end

@implementation GCControllerButtonInput {
    float _value;
    BOOL _pressed;
    BOOL _touched;
    GCControllerButtonValueChangedHandler _valueChangedHandler;
    GCControllerButtonValueChangedHandler _pressedChangedHandler;
    GCControllerButtonTouchedChangedHandler _touchedChangedHandler;
}

- (void)dealloc
{
    [_valueChangedHandler release];
    [_pressedChangedHandler release];
    [_touchedChangedHandler release];
    [super dealloc];
}

- (float)value { return _value; }
- (BOOL)isPressed { return _pressed; }
- (BOOL)isTouched { return _touched; }
- (GCControllerButtonValueChangedHandler)valueChangedHandler { return _valueChangedHandler; }
- (void)setValueChangedHandler:(GCControllerButtonValueChangedHandler)handler
{
    if (_valueChangedHandler != handler) {
        [_valueChangedHandler release];
        _valueChangedHandler = [handler copy];
    }
}
- (GCControllerButtonValueChangedHandler)pressedChangedHandler { return _pressedChangedHandler; }
- (void)setPressedChangedHandler:(GCControllerButtonValueChangedHandler)handler
{
    if (_pressedChangedHandler != handler) {
        [_pressedChangedHandler release];
        _pressedChangedHandler = [handler copy];
    }
}
- (GCControllerButtonTouchedChangedHandler)touchedChangedHandler { return _touchedChangedHandler; }
- (void)setTouchedChangedHandler:(GCControllerButtonTouchedChangedHandler)handler
{
    if (_touchedChangedHandler != handler) {
        [_touchedChangedHandler release];
        _touchedChangedHandler = [handler copy];
    }
}

- (void)setValue:(float)value
{
    id<GCDevice> owner = [self _owner];
    if ([owner isKindOfClass:[GCController class]] && [(GCController *)owner isSnapshot])
        [self _setInputValue:value touched:value > 0 notify:NO];
}

- (void)_setInputValue:(float)value touched:(BOOL)touched notify:(BOOL)notify
{
    value = GCSaturate(value, 0.0f, 1.0f);
    BOOL wasPressed = _pressed;
    BOOL wasTouched = _touched;
    BOOL valueChanged = _value != value;
    _value = value;
    _pressed = value > 0.0f;
    _touched = touched || value > 0.0f;
    if (!notify)
        return;
    GCControllerButtonValueChangedHandler valueHandler = valueChanged ? [_valueChangedHandler copy] : nil;
    GCControllerButtonValueChangedHandler pressedHandler = wasPressed != _pressed ? [_pressedChangedHandler copy] : nil;
    GCControllerButtonTouchedChangedHandler touchedHandler =
        wasTouched != _touched ? [_touchedChangedHandler copy] : nil;
    if (valueHandler || pressedHandler || touchedHandler) {
        float currentValue = _value;
        BOOL currentPressed = _pressed, currentTouched = _touched;
        GCDispatchDeviceHandler([self _owner], ^{
            if (valueHandler) valueHandler(self, currentValue, currentPressed);
            if (pressedHandler) pressedHandler(self, currentValue, currentPressed);
            if (touchedHandler) touchedHandler(self, currentValue, currentPressed, currentTouched);
        });
        [valueHandler release]; [pressedHandler release]; [touchedHandler release];
    }
}

@end

@implementation GCControllerAxisInput {
    float _value;
    GCControllerAxisValueChangedHandler _valueChangedHandler;
}

- (void)dealloc
{
    [_valueChangedHandler release];
    [super dealloc];
}
- (float)value { return _value; }
- (GCControllerAxisValueChangedHandler)valueChangedHandler { return _valueChangedHandler; }
- (void)setValueChangedHandler:(GCControllerAxisValueChangedHandler)handler
{
    if (_valueChangedHandler != handler) {
        [_valueChangedHandler release];
        _valueChangedHandler = [handler copy];
    }
}
- (void)setValue:(float)value
{
    id<GCDevice> owner = [self _owner];
    if ([owner isKindOfClass:[GCController class]] && [(GCController *)owner isSnapshot])
        [self _setInputValue:value notify:NO];
}
- (void)_setInputValue:(float)value notify:(BOOL)notify
{
    value = GCSaturate(value, -1.0f, 1.0f);
    BOOL changed = _value != value;
    _value = value;
    if (notify && changed && _valueChangedHandler) {
        GCControllerAxisValueChangedHandler handler = [_valueChangedHandler copy];
        float value = _value;
        GCDispatchDeviceHandler([self _owner], ^{ handler(self, value); });
        [handler release];
    }
}

@end

@implementation GCControllerDirectionPad {
    GCControllerDirectionPadValueChangedHandler _valueChangedHandler;
    GCControllerAxisInput *_xAxis;
    GCControllerAxisInput *_yAxis;
    GCControllerButtonInput *_up;
    GCControllerButtonInput *_down;
    GCControllerButtonInput *_left;
    GCControllerButtonInput *_right;
}

- (instancetype)init
{
    return [self _initWithAlias:nil owner:nil analog:YES];
}

- (instancetype)_initWithAlias:(NSString *)alias owner:(id<GCDevice>)owner analog:(BOOL)analog
{
    self = [super _initWithAlias:alias collection:nil analog:analog owner:owner];
    if (self) {
        _xAxis = [[GCControllerAxisInput alloc] _initWithAlias:@"X Axis" collection:self analog:analog owner:owner];
        _yAxis = [[GCControllerAxisInput alloc] _initWithAlias:@"Y Axis" collection:self analog:analog owner:owner];
        _up = [[GCControllerButtonInput alloc] _initWithAlias:@"Up" collection:self analog:analog owner:owner];
        _down = [[GCControllerButtonInput alloc] _initWithAlias:@"Down" collection:self analog:analog owner:owner];
        _left = [[GCControllerButtonInput alloc] _initWithAlias:@"Left" collection:self analog:analog owner:owner];
        _right = [[GCControllerButtonInput alloc] _initWithAlias:@"Right" collection:self analog:analog owner:owner];
    }
    return self;
}

- (void)_setOwner:(id<GCDevice>)owner
{
    [super _setOwner:owner];
    [_xAxis _setOwner:owner]; [_yAxis _setOwner:owner];
    [_up _setOwner:owner]; [_down _setOwner:owner]; [_left _setOwner:owner]; [_right _setOwner:owner];
}

- (void)dealloc
{
    [_valueChangedHandler release];
    [_xAxis release]; [_yAxis release]; [_up release]; [_down release]; [_left release]; [_right release];
    [super dealloc];
}
- (GCControllerDirectionPadValueChangedHandler)valueChangedHandler { return _valueChangedHandler; }
- (void)setValueChangedHandler:(GCControllerDirectionPadValueChangedHandler)handler
{
    if (_valueChangedHandler != handler) {
        [_valueChangedHandler release];
        _valueChangedHandler = [handler copy];
    }
}
- (GCControllerAxisInput *)xAxis { return _xAxis; }
- (GCControllerAxisInput *)yAxis { return _yAxis; }
- (GCControllerButtonInput *)up { return _up; }
- (GCControllerButtonInput *)down { return _down; }
- (GCControllerButtonInput *)left { return _left; }
- (GCControllerButtonInput *)right { return _right; }
- (void)setValueForXAxis:(float)x yAxis:(float)y
{
    id<GCDevice> owner = [self _owner];
    if ([owner isKindOfClass:[GCController class]] && [(GCController *)owner isSnapshot])
        [self _setPositionX:x y:y notify:NO];
}
- (void)_setPositionX:(float)x y:(float)y notify:(BOOL)notify
{
    x = GCSaturate(x, -1.0f, 1.0f);
    y = GCSaturate(y, -1.0f, 1.0f);
    BOOL changed = _xAxis.value != x || _yAxis.value != y;
    [_xAxis _setInputValue:x notify:notify];
    [_yAxis _setInputValue:y notify:notify];
    [_left _setInputValue:x < 0.0f ? -x : 0.0f touched:NO notify:notify];
    [_right _setInputValue:x > 0.0f ? x : 0.0f touched:NO notify:notify];
    [_down _setInputValue:y < 0.0f ? -y : 0.0f touched:NO notify:notify];
    [_up _setInputValue:y > 0.0f ? y : 0.0f touched:NO notify:notify];
    if (notify && changed && _valueChangedHandler) {
        GCControllerDirectionPadValueChangedHandler handler = [_valueChangedHandler copy];
        GCDispatchDeviceHandler([self _owner], ^{ handler(self, x, y); });
        [handler release];
    }
}

@end

@implementation GCPhysicalInputProfile {
    id<GCDevice> _device;
    NSTimeInterval _lastEventTimestamp;
    BOOL _hasRemappedElements;
    void (^_valueDidChangeHandler)(__kindof GCPhysicalInputProfile *, GCControllerElement *);
    NSMutableDictionary *_elements;
    NSMutableDictionary *_buttons;
    NSMutableDictionary *_axes;
    NSMutableDictionary *_dpads;
    NSMutableDictionary *_touchpads;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _elements = [[NSMutableDictionary alloc] init];
        _buttons = [[NSMutableDictionary alloc] init];
        _axes = [[NSMutableDictionary alloc] init];
        _dpads = [[NSMutableDictionary alloc] init];
        _touchpads = [[NSMutableDictionary alloc] init];
    }
    return self;
}
- (void)dealloc
{
    [_valueDidChangeHandler release];
    [_elements release]; [_buttons release]; [_axes release]; [_dpads release]; [_touchpads release];
    [super dealloc];
}
- (void)_setDevice:(id<GCDevice>)device
{
    _device = device;
    for (GCControllerElement *element in [_elements allValues])
        [element _setOwner:device];
}
- (void)_setLastEventTimestamp:(NSTimeInterval)timestamp { _lastEventTimestamp = timestamp; }
- (id<GCDevice>)device { return _device; }
- (NSTimeInterval)lastEventTimestamp { return _lastEventTimestamp; }
- (BOOL)hasRemappedElements { return _hasRemappedElements; }
- (void (^)(__kindof GCPhysicalInputProfile *, GCControllerElement *))valueDidChangeHandler { return _valueDidChangeHandler; }
- (void)setValueDidChangeHandler:(void (^)(__kindof GCPhysicalInputProfile *, GCControllerElement *))handler
{
    if (_valueDidChangeHandler != handler) {
        [_valueDidChangeHandler release];
        _valueDidChangeHandler = [handler copy];
    }
}
- (NSDictionary *)elements { return _elements; }
- (NSDictionary *)buttons { return _buttons; }
- (NSDictionary *)axes { return _axes; }
- (NSDictionary *)dpads { return _dpads; }
- (NSDictionary *)touchpads { return _touchpads; }
- (NSSet *)allElements { return [NSSet setWithArray:[_elements allValues]]; }
- (NSSet *)allButtons { return [NSSet setWithArray:[_buttons allValues]]; }
- (NSSet *)allAxes { return [NSSet setWithArray:[_axes allValues]]; }
- (NSSet *)allDpads { return [NSSet setWithArray:[_dpads allValues]]; }
- (NSSet *)allTouchpads { return [NSSet setWithArray:[_touchpads allValues]]; }
- (GCControllerElement *)objectForKeyedSubscript:(NSString *)key { return key ? [_elements objectForKey:key] : nil; }

- (void)_addElement:(GCControllerElement *)element alias:(NSString *)alias kind:(NSUInteger)kind
{
    if (!element || !alias)
        return;
    [_elements setObject:element forKey:alias];
    NSMutableDictionary *target = kind == GCElementKindButton ? _buttons :
                                  kind == GCElementKindAxis ? _axes :
                                  kind == GCElementKindDpad ? _dpads :
                                  kind == GCElementKindTouchpad ? _touchpads : nil;
    if (target)
        [target setObject:element forKey:alias];
    [element _setOwner:_device];
}

- (void)_notifyElementChanged:(GCControllerElement *)element
{
    if (_valueDidChangeHandler) {
        void (^handler)(__kindof GCPhysicalInputProfile *, GCControllerElement *) = [_valueDidChangeHandler copy];
        GCDispatchDeviceHandler(_device, ^{ handler(self, element); });
        [handler release];
    }
}

- (instancetype)capture
{
    GCController *copy = nil;
    if ([self isKindOfClass:[GCExtendedGamepad class]])
        copy = [GCController controllerWithExtendedGamepad];
    else if ([self isKindOfClass:[GCMicroGamepad class]])
        copy = [GCController controllerWithMicroGamepad];
    else if ([self isKindOfClass:[GCGamepad class]])
        copy = [[[GCController alloc] _initSnapshotWithProfileKind:1] autorelease];
    if (!copy)
        return nil;
    [copy.physicalInputProfile _setStateFromProfile:self];
    return [[copy.physicalInputProfile retain] autorelease];
}

- (void)setStateFromPhysicalInput:(GCPhysicalInputProfile *)profile
{
    GCController *owner = (GCController *)_device;
    if ([owner isSnapshot] && profile)
        [self _setStateFromProfile:profile];
}

- (void)_setStateFromProfile:(GCPhysicalInputProfile *)profile
{
    for (NSString *name in _elements) {
        GCControllerElement *target = [_elements objectForKey:name];
        GCControllerElement *source = [profile objectForKeyedSubscript:name];
        if ([target isKindOfClass:[GCControllerButtonInput class]] &&
            [source isKindOfClass:[GCControllerButtonInput class]]) {
            GCControllerButtonInput *button = (GCControllerButtonInput *)source;
            [(GCControllerButtonInput *)target _setInputValue:button.value touched:button.touched notify:NO];
        } else if ([target isKindOfClass:[GCControllerAxisInput class]] &&
                   [source isKindOfClass:[GCControllerAxisInput class]]) {
            [(GCControllerAxisInput *)target _setInputValue:[(GCControllerAxisInput *)source value] notify:NO];
        }
    }
}

- (NSString *)mappedElementAliasForPhysicalInputName:(NSString *)inputName
{
    return [_elements objectForKey:inputName] ? inputName : nil;
}
- (NSSet<NSString *> *)mappedPhysicalInputNamesForElementAlias:(NSString *)elementAlias
{
    GCControllerElement *element = [_elements objectForKey:elementAlias];
    return element ? [NSSet setWithObject:elementAlias] : [NSSet set];
}

@end

@implementation GCDeviceCursor
@end

@implementation GCColor {
    float _red;
    float _green;
    float _blue;
}

+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithRed:(float)red green:(float)green blue:(float)blue
{
    self = [super init];
    if (self) {
        _red = GCSaturate(red, 0.0f, 1.0f);
        _green = GCSaturate(green, 0.0f, 1.0f);
        _blue = GCSaturate(blue, 0.0f, 1.0f);
    }
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    return [self initWithRed:[coder decodeFloatForKey:@"red"]
                       green:[coder decodeFloatForKey:@"green"]
                        blue:[coder decodeFloatForKey:@"blue"]];
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeFloat:_red forKey:@"red"];
    [coder encodeFloat:_green forKey:@"green"];
    [coder encodeFloat:_blue forKey:@"blue"];
}
- (id)copyWithZone:(NSZone *)zone
{
    return [[GCColor allocWithZone:zone] initWithRed:_red green:_green blue:_blue];
}
- (float)red { return _red; }
- (float)green { return _green; }
- (float)blue { return _blue; }
@end
