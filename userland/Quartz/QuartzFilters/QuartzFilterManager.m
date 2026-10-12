/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * QuartzFilterManager: the filters in /System/Library/Filters, /Library/Filters and
 * ~/Library/Filters, the selected one, importing new ones (into the user's folder), and
 * a view and panel listing them. Its notifications and delegate calls are Apple's.
 */
#import "QuartzFiltersInternal.h"
#import <objc/message.h>

NSString *kQuartzFilterManagerDidAddFilterNotification = @"QuartzFilterManagerDidAddFilterNotification";
NSString *kQuartzFilterManagerDidRemoveFilterNotification = @"QuartzFilterManagerDidRemoveFilterNotification";
NSString *kQuartzFilterManagerDidModifyFilterNotification = @"QuartzFilterManagerDidModifyFilterNotification";
NSString *kQuartzFilterManagerDidSelectFilterNotification = @"QuartzFilterManagerDidSelectFilterNotification";
Boolean globalUpdateOK = true;

/* The folders filters live in, system first (FINCH_FILTER_DIRS, colon-separated, puts
   others first: tests on a Mac use the build's). */
static NSArray<NSString *> *
filter_folders(void)
{
    const char *env = getenv("FINCH_FILTER_DIRS");
    if (env && *env)
        return [@(env) componentsSeparatedByString:@":"];
    return @[@"/System/Library/Filters", @"/Library/Filters", [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Filters"]];
}

/* Whether a filter belongs to one of the domains asked for (nil: all). */
static BOOL
in_domains(QuartzFilter *f, NSArray *domains)
{
    if (!domains)
        return YES;
    NSDictionary *d = f.properties[@"Domains"];
    if (![d isKindOfClass:[NSDictionary class]])
        return YES; /* (a filter that names none is for any) */
    for (NSString *domain in domains) {
        NSString *key = [domain isEqual:kQuartzFilterPrintingDomain] ? @"Printing"
                        : [domain isEqual:kQuartzFilterPDFWorkflowDomain] ? @"PDFWorkflow"
                                                                            : @"Applications";
        if ([d[key] boolValue] || ([key isEqual:@"PDFWorkflow"] && [d[@"Applications"] boolValue]))
            return YES;
    }
    return NO;
}

@interface QuartzFilterView () <NSTableViewDataSource, NSTableViewDelegate>
@property (assign) QuartzFilterManager *manager;
@property (retain) NSArray<QuartzFilter *> *filters;
@property (retain) NSTableView *table;
- (void)_reload;
- (void)_selectFilter:(QuartzFilter *)filter;
@end

@implementation QuartzFilterManager {
    QuartzFilter *_selected;
    id _delegate;
    QuartzFilterView *_view;
    NSPanel *_panel;
}

+ (QuartzFilterManager *)filterManager { return [[[self alloc] init] autorelease]; }

+ (NSArray *)filtersInDomains:(NSArray *)domains
{
    NSMutableArray *found = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *folder in filter_folders()) {
        NSArray *names = [[fm contentsOfDirectoryAtPath:folder error:NULL] sortedArrayUsingSelector:@selector(compare:)];
        for (NSString *n in names) {
            if (![[n pathExtension] isEqualToString:@"qfilter"])
                continue;
            QuartzFilter *f = [QuartzFilter quartzFilterWithURL:[NSURL fileURLWithPath:[folder stringByAppendingPathComponent:n]]];
            if (f && in_domains(f, domains))
                [found addObject:f];
        }
    }
    return found;
}

- (void)dealloc
{
    [_selected release];
    [_view release];
    [_panel release];
    [super dealloc];
}

- (id)delegate { return _delegate; }
- (void)setDelegate:(id)delegate { _delegate = delegate; }
- (QuartzFilter *)selectedFilter { return _selected; }

- (void)_tell:(SEL)sel notification:(NSString *)name filter:(QuartzFilter *)f
{
    if ([_delegate respondsToSelector:sel])
        ((void (*)(id, SEL, id, id))objc_msgSend)(_delegate, sel, self, f);
    [[NSNotificationCenter defaultCenter] postNotificationName:name object:self userInfo:f ? @{@"filter" : f} : nil];
}

- (BOOL)selectFilter:(QuartzFilter *)filter
{
    if (filter && ![filter isKindOfClass:[QuartzFilter class]])
        return NO;
    [_selected autorelease];
    _selected = [filter retain];
    [_view _selectFilter:filter];
    [self _tell:@selector(quartzFilterManager:didSelectFilter:) notification:kQuartzFilterManagerDidSelectFilterNotification filter:filter];
    return YES;
}

/* A new filter in the user's folder, named after its Name (made unique). */
- (QuartzFilter *)importFilter:(NSDictionary *)properties
{
    if (![properties isKindOfClass:[NSDictionary class]])
        return nil;
    NSString *folder = filter_folders().lastObject;
    [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *base = [properties[kQFilterName] isKindOfClass:[NSString class]] ? properties[kQFilterName] : @"Filter";
    base = [base stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    NSString *path = [folder stringByAppendingPathComponent:[base stringByAppendingPathExtension:@"qfilter"]];
    for (int i = 2; [[NSFileManager defaultManager] fileExistsAtPath:path]; i++)
        path = [folder stringByAppendingPathComponent:[[NSString stringWithFormat:@"%@ %d", base, i] stringByAppendingPathExtension:@"qfilter"]];
    if (![properties writeToFile:path atomically:YES])
        return nil;
    QuartzFilter *f = [QuartzFilter quartzFilterWithURL:[NSURL fileURLWithPath:path]];
    [_view _reload];
    [self _tell:@selector(quartzFilterManager:didAddFilter:) notification:kQuartzFilterManagerDidAddFilterNotification filter:f];
    return f;
}

- (QuartzFilterView *)filterView
{
    if (!_view) {
        _view = [[QuartzFilterView alloc] initWithFrame:NSMakeRect(0, 0, 280, 320)];
        _view.manager = self;
        [_view _reload];
    }
    return _view;
}

- (NSPanel *)filterPanel
{
    if (!_panel) {
        _panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 280, 320)
                                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable |
                                                      NSWindowStyleMaskUtilityWindow
                                              backing:NSBackingStoreBuffered
                                                defer:YES];
        _panel.title = [[NSBundle bundleForClass:[QuartzFilter class]] localizedStringForKey:@"Quartz Filters" value:@"Quartz Filters"
                                                                                       table:@"Filters"];
        _panel.releasedWhenClosed = NO;
        QuartzFilterView *v = [self filterView];
        v.frame = [_panel.contentView bounds];
        v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [_panel.contentView addSubview:v];
    }
    return _panel;
}

@end

/* A list of the filters: choosing one selects it in the manager. */
@implementation QuartzFilterView

- (instancetype)initWithFrame:(NSRect)frame
{
    if (!(self = [super initWithFrame:frame]))
        return nil;
    NSScrollView *scroll = [[[NSScrollView alloc] initWithFrame:self.bounds] autorelease];
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.hasVerticalScroller = YES;
    NSTableView *table = [[[NSTableView alloc] initWithFrame:scroll.bounds] autorelease];
    NSTableColumn *col = [[[NSTableColumn alloc] initWithIdentifier:@"name"] autorelease];
    col.width = frame.size.width;
    [table addTableColumn:col];
    table.headerView = nil;
    table.dataSource = self;
    table.delegate = self;
    scroll.documentView = table;
    [self addSubview:scroll];
    self.table = table;
    return self;
}

- (void)dealloc
{
    [_filters release];
    [_table release];
    [super dealloc];
}

- (void)_reload
{
    self.filters = [QuartzFilterManager filtersInDomains:nil];
    [self.table reloadData];
}

- (void)_selectFilter:(QuartzFilter *)filter
{
    NSUInteger i = NSNotFound;
    for (NSUInteger k = 0; k < self.filters.count; k++)
        if ([self.filters[k].url isEqual:filter.url] && filter.url)
            i = k;
    if (i == NSNotFound)
        [self.table deselectAll:nil];
    else
        [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
}

- (void)sizeToFit
{
    CGFloat h = MAX(120, MIN(480, self.filters.count * (self.table.rowHeight + self.table.intercellSpacing.height) + 4));
    [self setFrameSize:NSMakeSize(self.frame.size.width, h)];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return (NSInteger)self.filters.count; }

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
    return self.filters[(NSUInteger)row].localizedName;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    NSInteger row = self.table.selectedRow;
    QuartzFilter *f = row >= 0 && (NSUInteger)row < self.filters.count ? self.filters[(NSUInteger)row] : nil;
    QuartzFilter *current = self.manager.selectedFilter;
    if (!(f == current || (f.url && [f.url isEqual:current.url])))
        [self.manager selectFilter:f];
}

@end
