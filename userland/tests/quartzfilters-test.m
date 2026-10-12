/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Quartz filters: the property keys and domains, the filters the manager lists (by the
 * names Finch's and Apple's share), filters from properties and URLs, selection and its
 * notification, the filter view and panel, and what applying a filter does to a bitmap
 * context's drawing, by its character (Finch's filters are its own): gray stays gray,
 * black and white is one or the other, sepia is warm, blue tone is cool, lightness goes
 * down or up, and removing the filter draws as before. Then ImageKit's save options
 * (type, properties, the user's selection, a save panel's accessory). Compared with Apple's.
 */
#import <AppKit/AppKit.h>
#import <Quartz/Quartz.h>
#include <dlfcn.h>

static NSString *
key(const char *name)
{
    void **p = dlsym(RTLD_DEFAULT, name);
    return p ? (__bridge NSString *)*p : @"(none)";
}

/* Red drawn through the filter, and after its removal. */
static void
filtered_red(QuartzFilter *f, uint8_t out[3], uint8_t after[3])
{
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(NULL, 8, 4, 8, 32, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    [f applyToContext:c];
    CGContextSetRGBFillColor(c, 1, 0, 0, 1);
    CGContextFillRect(c, CGRectMake(0, 0, 4, 4));
    [f removeFromContext:c];
    CGContextFillRect(c, CGRectMake(4, 0, 4, 4));
    const uint8_t *p = CGBitmapContextGetData(c);
    memcpy(out, p, 3);
    memcpy(after, p + 16, 3);
    CGContextRelease(c);
}

static int selections;

int
main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        const char *names[] = {"kQFilterName", "kQFilterType", "kQFilterDomains", "kQFilterURL", "kQFilterColorSettings",
                               "kQFilterImageSettings", "kQFilterReadOnly", "kQFilterPrintingDomain", "kQFilterAppLicationDomain",
                               "kQFilterPDFX3Settings", "kQFilterDocumentColorSettings", "kQFilterImageColorSettings",
                               "kQFilterTargetColorSpace", "kQFilterIntermediateColorSpace", "kQFilterSourceRenderingIntent",
                               "kQFilterBlackPointCompensation", "kQFilterImageScaleSettings", "kQFilterImageScaleFactor",
                               "kQFilterImageScaleInterpolate", "kQFilterData", "kQFilterProfileData", "kQFilterDefaultCMYKColorSpace",
                               "kQFilterDefaultRGBColorSpace", "kQFilterDefaultGrayColorSpace", "kQFilterAssignCMYKColorSpace",
                               "kQFilterAssignRGBColorSpace", "kQFilterAssignGrayColorSpace"};
        for (unsigned i = 0; i < sizeof names / sizeof *names; i++)
            printf("%s = %s\n", names[i], key(names[i]).UTF8String);
        printf("domains: %s %s %s\n", kQuartzFilterApplicationDomain.UTF8String, kQuartzFilterPDFWorkflowDomain.UTF8String,
               kQuartzFilterPrintingDomain.UTF8String);
        printf("notifications: %s %s %s %s\n", kQuartzFilterManagerDidAddFilterNotification.UTF8String,
               kQuartzFilterManagerDidRemoveFilterNotification.UTF8String, kQuartzFilterManagerDidModifyFilterNotification.UTF8String,
               kQuartzFilterManagerDidSelectFilterNotification.UTF8String);

        NSArray *all = [QuartzFilterManager filtersInDomains:nil];
        NSMutableDictionary *byName = [NSMutableDictionary dictionary];
        for (QuartzFilter *f in all)
            byName[f.localizedName] = f;
        NSArray *shared = @[@"Black & White", @"Blue Tone", @"Gray Tone", @"Lightness Decrease", @"Lightness Increase",
                            @"Reduce File Size", @"Sepia Tone"];
        for (NSString *n in shared) {
            QuartzFilter *f = byName[n];
            printf("%s: listed %d, url in /System/Library/Filters %d, type %s, applications %d, printing %d\n", n.UTF8String, f != nil,
                   [f.url.path containsString:@"System/Library/Filters/"], [[f.properties[@"FilterType"] description] UTF8String],
                   [f.properties[@"Domains"][@"Applications"] boolValue], [f.properties[@"Domains"][@"Printing"] boolValue]);
        }
        int printing = 0, application = 0;
        for (QuartzFilter *f in [QuartzFilterManager filtersInDomains:@[kQuartzFilterPrintingDomain]])
            printing += [shared containsObject:f.localizedName];
        for (QuartzFilter *f in [QuartzFilterManager filtersInDomains:@[kQuartzFilterApplicationDomain]])
            application += [shared containsObject:f.localizedName];
        printf("in the printing domain %d, the application domain %d\n", printing, application);

        uint8_t c[3], after[3];
        filtered_red(byName[@"Gray Tone"], c, after);
        printf("gray tone: gray %d, mid %d, after removal red %d\n", c[0] == c[1] && c[1] == c[2], c[0] > 60 && c[0] < 200,
               after[0] == 255 && after[1] == 0);
        filtered_red(byName[@"Black & White"], c, after);
        printf("black & white: extreme %d\n", (c[0] < 10 || c[0] > 245) && abs(c[0] - c[2]) < 4);
        filtered_red(byName[@"Sepia Tone"], c, after);
        printf("sepia: warm %d\n", c[0] > c[1] && c[1] > c[2]);
        filtered_red(byName[@"Blue Tone"], c, after);
        printf("blue tone: cool %d\n", c[2] > c[1] && c[1] > c[0]);
        filtered_red(byName[@"Lightness Decrease"], c, after);
        printf("lightness decrease: darker red %d\n", c[0] < 240 && c[0] > 100 && c[1] < 10);
        filtered_red(byName[@"Lightness Increase"], c, after);
        printf("lightness increase: lighter red %d\n", c[0] > 245 && c[1] > 20 && c[1] < 120);
        filtered_red(byName[@"Reduce File Size"], c, after);
        printf("reduce file size: colour kept %d\n", c[0] == 255 && c[1] == 0 && c[2] == 0);

        QuartzFilter *p = [QuartzFilter quartzFilterWithProperties:@{@"Name" : @"Mine", @"FilterType" : @1}];
        printf("from properties: name %s, url %d, properties kept %d\n", p.localizedName.UTF8String, p.url != nil,
               [p.properties isEqual:(@{@"Name" : @"Mine", @"FilterType" : @1})]);
        printf("missing file: %d, from a file: %d\n", [QuartzFilter quartzFilterWithURL:[NSURL fileURLWithPath:@"/nonexistent.qfilter"]] != nil,
               [QuartzFilter quartzFilterWithURL:[byName[@"Gray Tone"] url]] != nil);

        QuartzFilterManager *m = [QuartzFilterManager filterManager];
        id observer = [[NSNotificationCenter defaultCenter] addObserverForName:kQuartzFilterManagerDidSelectFilterNotification object:m
                                                                         queue:nil usingBlock:^(NSNotification *n) { selections++; }];
        printf("manager: selected at first %d\n", m.selectedFilter != nil);
        /* (Apple's crashes selecting a filter when it has no view yet: Finch's only) */
        if (getenv("FINCH_FILTER_DIRS")) {
            BOOL ok = [m selectFilter:byName[@"Sepia Tone"]];
            fprintf(stderr, "select: %d, selected %s, notifications %d\n", ok, m.selectedFilter.localizedName.UTF8String, selections);
        }
        printf("view is a view %d, panel %s\n", [m.filterView isKindOfClass:[NSView class]],
               NSStringFromClass([m.filterPanel class]).UTF8String);
        [[NSNotificationCenter defaultCenter] removeObserver:observer];

        IKSaveOptions *o = [[IKSaveOptions alloc] initWithImageProperties:@{@"DPIWidth" : @72} imageUTType:@"public.jpeg"];
        printf("save options: type %s, properties %s, selection type %s\n", o.imageUTType.UTF8String,
               [[o.imageProperties[@"DPIWidth"] description] UTF8String], [[o.userSelection[@"documentType"] description] UTF8String]);
        NSSavePanel *sp = [NSSavePanel savePanel];
        [o addSaveOptionsAccessoryViewToSavePanel:sp];
        printf("accessory %d, first allowed type %s\n", sp.accessoryView != nil, sp.allowedContentTypes.firstObject.identifier.UTF8String);
        NSView *host = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 100)];
        [o addSaveOptionsToView:host];
        printf("options added to a view: %lu\n", (unsigned long)host.subviews.count);
        IKSaveOptions *none = [[IKSaveOptions alloc] initWithImageProperties:nil imageUTType:nil];
        printf("empty options: type %d properties %d\n", none.imageUTType != nil, none.imageProperties != nil);
    }
    return 0;
}
