/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * QuartzFilters: Quartz filters (.qfilter property lists) that change how a context's
 * drawing comes out, and the manager that finds them in the filter folders.
 *
 * A filter's FilterData says what it does. Finch's own filters (userland/Quartz/
 * QuartzFilters/Filters) describe their colour effect as FinchColorEffect: Luminance (to
 * gray, weighed in linear light), Threshold (to black or white), Tint (gains for red,
 * green and blue after that), Gain and Lift (each channel scaled, then raised toward
 * white). Applying a filter sets that effect as the context's colour filter
 * (CGContextSetFinchColorFilter); image scale settings are kept for writers that read
 * them. Apple's filters do their colour work with ICC abstract profiles, which Finch
 * doesn't evaluate yet: those apply without a colour change.
 */
#import "QuartzFiltersInternal.h"

NSString *const kQFilterName = @"Name";
NSString *const kQFilterType = @"FilterType";
NSString *const kQFilterDomains = @"Domains";
NSString *const kQFilterURL = @"URL";
NSString *const kQFilterColorSettings = @"ColorSettings";
NSString *const kQFilterImageSettings = @"ImageSettings";
NSString *const kQFilterReadOnly = @"Read Only";
NSString *const kQFilterPrintingDomain = @"Printing";
NSString *const kQFilterAppLicationDomain = @"Applications";
NSString *const kQFilterPDFX3Settings = @"PDF/X-3 Settings";
NSString *const kQFilterDocumentColorSettings = @"DocumentColorSettings";
NSString *const kQFilterImageColorSettings = @"ImageColorSettings";
NSString *const kQFilterTargetColorSpace = @"TargetColorSpace";
NSString *const kQFilterIntermediateColorSpace = @"IntermediateColorSpace";
NSString *const kQFilterSourceRenderingIntent = @"SourceRenderingIntent";
NSString *const kQFilterBlackPointCompensation = @"BlackPointCompensation";
NSString *const kQFilterImageScaleSettings = @"ImageScaleSettings";
NSString *const kQFilterImageScaleFactor = @"ImageScaleFactor";
NSString *const kQFilterImageScaleInterpolate = @"ImageScaleInterpolate";
NSString *const kQFilterData = @"FilterData";
NSString *const kQFilterProfileData = @"FilterProfileArray";
NSString *const kQFilterDefaultCMYKColorSpace = @"DefaultCMYKColorSpace";
NSString *const kQFilterDefaultRGBColorSpace = @"DefaultRGBColorSpace";
NSString *const kQFilterDefaultGrayColorSpace = @"DefaultGrayColorSpace";
NSString *const kQFilterAssignCMYKColorSpace = @"AssignCMYKColorSpace";
NSString *const kQFilterAssignRGBColorSpace = @"AssignRGBColorSpace";
NSString *const kQFilterAssignGrayColorSpace = @"AssignGrayColorSpace";
NSString *kQuartzFilterApplicationDomain = @"QuartzFilterApplicationDomain";
NSString *kQuartzFilterPDFWorkflowDomain = @"QuartzFilterPDFWorkflowDomain";
NSString *kQuartzFilterPrintingDomain = @"QuartzFilterPrintingDomain";

extern void CGContextSetFinchColorFilter(CGContextRef c, const float *matrix, const uint8_t *tables, bool linear);

/* The colour effect, as a 4x5 matrix (Skia's, row-major) and tables, from FinchColorEffect.
   NO when the filter changes no colours. */
static BOOL
effect_filter(NSDictionary *effect, float matrix[20], BOOL *useMatrix, uint8_t tables[1024], BOOL *useTables)
{
    *useMatrix = *useTables = NO;
    if (![effect isKindOfClass:[NSDictionary class]])
        return NO;
    BOOL gray = [effect[@"Luminance"] boolValue];
    NSNumber *threshold = effect[@"Threshold"];
    NSArray *tint = effect[@"Tint"];
    double gain = effect[@"Gain"] ? [effect[@"Gain"] doubleValue] : 1;
    double lift = [effect[@"Lift"] doubleValue];
    if (gray) {
        /* luminance, mixed in linear light (Rec. 709 weights) */
        static const float w[3] = {0.2126f, 0.7152f, 0.0722f};
        float m[20] = {0};
        for (int row = 0; row < 3; row++)
            for (int col = 0; col < 3; col++)
                m[row * 5 + col] = w[col];
        m[18] = 1;
        memcpy(matrix, m, sizeof m);
        *useMatrix = YES;
    }
    double gains[3] = {1, 1, 1};
    if ([tint isKindOfClass:[NSArray class]] && tint.count >= 3)
        for (int i = 0; i < 3; i++)
            gains[i] = [tint[i] doubleValue];
    BOOL anyTable = threshold || gain != 1 || lift != 0 || gains[0] != 1 || gains[1] != 1 || gains[2] != 1;
    if (!anyTable)
        return *useMatrix;
    for (int i = 0; i < 256; i++)
        tables[i] = (uint8_t)i; /* alpha */
    for (int ch = 0; ch < 3; ch++)
        for (int i = 0; i < 256; i++) {
            double v = i / 255.0;
            if (threshold)
                v = v >= [threshold doubleValue] ? 1 : 0;
            v *= gains[ch] * gain;
            v = v + (1 - v) * lift;
            v = fmin(1, fmax(0, v));
            tables[256 * (ch + 1) + i] = (uint8_t)lround(v * 255);
        }
    *useTables = YES;
    return YES;
}

@implementation QuartzFilter {
    NSDictionary *_properties;
    NSURL *_url;
    id _owner;
}

+ (QuartzFilter *)quartzFilterWithURL:(NSURL *)aURL
{
    NSDictionary *p = aURL ? [NSDictionary dictionaryWithContentsOfURL:aURL] : nil;
    if (![p isKindOfClass:[NSDictionary class]])
        return nil;
    QuartzFilter *f = [[[self alloc] _initWithProperties:p] autorelease];
    f->_url = [aURL copy];
    return f;
}

+ (QuartzFilter *)quartzFilterWithProperties:(NSDictionary *)properties
{
    if (![properties isKindOfClass:[NSDictionary class]])
        return nil;
    return [[[self alloc] _initWithProperties:properties] autorelease];
}

+ (QuartzFilter *)quartzFilterWithOutputIntents:(NSArray *)outputIntents
{
    if (![outputIntents isKindOfClass:[NSArray class]])
        return nil;
    return [self quartzFilterWithProperties:@{kQFilterType : @1, kQFilterData : @{@"OutputIntents" : outputIntents}}];
}

- (instancetype)_initWithProperties:(NSDictionary *)properties
{
    if ((self = [super init]))
        _properties = [properties copy];
    return self;
}

- (void)dealloc
{
    [_properties release];
    [_url release];
    [super dealloc];
}

- (NSDictionary *)properties { return _properties; }
- (NSURL *)url { return _url; }
- (void)setURL:(NSURL *)url
{
    NSURL *old = _url;
    _url = [url copy];
    [old release];
}
- (void)setOwner:(id)owner { _owner = owner; }

- (NSString *)localizedName
{
    NSString *name = _properties[kQFilterName];
    if (![name isKindOfClass:[NSString class]])
        name = [[[_url path] lastPathComponent] stringByDeletingPathExtension];
    /* (Finch's filters' names are translated in the framework's tables) */
    NSBundle *b = [NSBundle bundleForClass:[QuartzFilter class]];
    return name ? [b localizedStringForKey:name value:name table:@"Filters"] : nil;
}

- (NSDictionary *)contextDictionary { return _properties[kQFilterData]; }

- (BOOL)applyToContext:(CGContextRef)context
{
    if (!context)
        return NO;
    float matrix[20];
    uint8_t tables[1024];
    BOOL useMatrix, useTables;
    NSDictionary *data = _properties[kQFilterData];
    if ([data isKindOfClass:[NSDictionary class]] && effect_filter(data[@"FinchColorEffect"], matrix, &useMatrix, tables, &useTables))
        CGContextSetFinchColorFilter(context, useMatrix ? matrix : NULL, useTables ? tables : NULL, true);
    return YES;
}

- (void)removeFromContext:(CGContextRef)context
{
    if (context)
        CGContextSetFinchColorFilter(context, NULL, NULL, false);
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p> %@", [self class], self, [self localizedName]];
}

@end

/* The C form of +quartzFilterWithOutputIntents: (a new reference, as Create says). */
__attribute__((visibility("default"))) QuartzFilter *
QuartzFilterCreateWithOutputIntents(NSArray *outputIntents)
{
    return [[QuartzFilter quartzFilterWithOutputIntents:outputIntents] retain];
}
