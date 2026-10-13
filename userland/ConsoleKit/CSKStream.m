/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * ConsoleKit, Finch's own: log streams and the views that show them.
 *
 * Sources:
 *   - CSKStreamDeviceSource: the Mac's live log, from Finch's log store
 *     (/var/db/diagnostics/finch/os_log.records, finch-logd's records): the recent past
 *     when it starts, then each record as it's appended. Info and debug messages only
 *     when asked for; one process when given a PID.
 *   - CSKStreamASLSource: a text log file's lines, one message each.
 *   - CSKStreamArchiveSource: a .logarchive is Apple's tracev3 format, which Finch
 *     doesn't read yet: opening one fails with an error saying so.
 *   - CSKStreamSQLSource: no messages (Apple's reads its persistence database).
 *
 * CSKStreamViewController shows a source: a table of messages (columns by layout,
 * newest at the bottom, followed in "now" mode), a details pane with the selected
 * message, and a status bar with the count. Filters are Console's search tokens: tokens
 * of one kind match any of their values, different kinds must all match.
 * CSKTokenFieldController turns the search field's tokens and text into filters.
 */
#import "ConsoleKit.h"
#include <sys/stat.h>
#include "../logd/logstore.h"

/* ---- the log store ---- */

static NSInteger
csk_type(uint8_t t)
{
    switch (t) {
    case 0x01: return CSKMessageTypeInfo;
    case 0x02: return CSKMessageTypeDebug;
    case 0x10: return CSKMessageTypeError;
    case 0x11: return CSKMessageTypeFault;
    default: return CSKMessageTypeDefault;
    }
}

NSArray *
CSKReadLogStore(NSString *path, off_t *offset, BOOL includeInfo, BOOL includeDebug, NSInteger pid, NSTimeInterval since)
{
    static uint64_t serial;
    NSMutableArray *out = [NSMutableArray array];
    int fd = open(path.fileSystemRepresentation, O_RDONLY);
    if (fd < 0)
        return out;
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size <= *offset) {
        if (st.st_size < *offset)
            *offset = 0; /* rotated */
        close(fd);
        return out;
    }
    size_t len = (size_t)(st.st_size - *offset);
    uint8_t *buf = malloc(len);
    ssize_t n = pread(fd, buf, len, *offset);
    close(fd);
    size_t at = 0;
    while (n > 0 && at + sizeof(struct logstore_record) <= (size_t)n) {
        const struct logstore_record *r = (const void *)(buf + at);
        if (r->size < sizeof *r || at + r->size > (size_t)n)
            break;
        at += r->size;
        NSInteger type = csk_type(r->type);
        if ((type == CSKMessageTypeInfo && !includeInfo) || (type == CSKMessageTypeDebug && !includeDebug))
            continue;
        if (pid > 0 && r->pid != pid)
            continue;
        double t = r->time_ns / 1e9;
        if (since > 0 && t < since)
            continue;
        const char *s = r->strings;
        NSString *process = [[NSString alloc] initWithBytes:s length:r->process_len encoding:NSUTF8StringEncoding];
        s += r->process_len + 1;
        NSString *subsystem = [[NSString alloc] initWithBytes:s length:r->subsystem_len encoding:NSUTF8StringEncoding];
        s += r->subsystem_len + 1;
        NSString *category = [[NSString alloc] initWithBytes:s length:r->category_len encoding:NSUTF8StringEncoding];
        s += r->category_len + 1;
        NSString *text = [[NSString alloc] initWithBytes:s length:r->message_len encoding:NSUTF8StringEncoding]
                             ?: [[NSString alloc] initWithBytes:s length:r->message_len encoding:NSISOLatin1StringEncoding];
        CSKMessage *m = [CSKMessage new];
        m->_identifierNumber = @(++serial);
        m->_messageText = text ?: @"";
        m.type = type;
        m.timestamp = [NSDate dateWithTimeIntervalSince1970:t];
        m.timeZone = [NSTimeZone localTimeZone];
        m.processName = process.lastPathComponent;
        m->_processImagePathString = process;
        m.processIdentifier = @(r->pid);
        m.threadIdentifier = [NSString stringWithFormat:@"0x%llx", (unsigned long long)r->thread];
        m.subsystem = subsystem.length ? subsystem : nil;
        m.category = category.length ? category : nil;
        [out addObject:m];
    }
    *offset += at;
    free(buf);
    return out;
}

/* ---- sources ---- */

@implementation CSKStreamSource {
@protected
    BOOL _streaming;
}

- (BOOL)isStreaming { return _streaming; }
- (BOOL)isLive { return NO; }
- (void)resume { _streaming = YES; }
- (void)stop { _streaming = NO; }
- (void)finish { [self stop]; }
- (NSArray *)processStatistics { return @[]; }
- (NSArray *)availableLoadRanges { return @[]; }

- (void)deliver:(NSArray *)entities
{
    if (!entities.count)
        return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.client streamSource:self didStreamForwardEntities:entities];
    });
}

- (void)finished:(NSUInteger)total
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_streaming = NO;
        [self.client streamSourceDidFinish:self total:total failures:0];
    });
}

@end

@implementation CSKStreamDeviceSource {
    CSKDevice *_device;
    NSInteger _pid;
    off_t _offset;
    dispatch_source_t _timer;
    BOOL _started;
}

- (instancetype)init { return [self initWithDevice:[CSKDevice hostDevice] PID:-1]; }

- (instancetype)initWithDevice:(CSKDevice *)device PID:(NSInteger)pid
{
    if ((self = [super init])) {
        _device = device ?: [CSKDevice hostDevice];
        _pid = pid;
    }
    return self;
}

- (CSKDevice *)device { return _device; }
- (BOOL)isLive { return YES; }

- (void)poll
{
    BOOL first = !_started;
    _started = YES;
    NSMutableArray *all = [NSMutableArray array];
    /* the rotated file first, when starting */
    if (first) {
        off_t o = 0;
        [all addObjectsFromArray:CSKReadLogStore(@LOGSTORE_PATH ".0", &o, _includesInfoEntities, _includesDebugEntities, _pid,
                                                 [NSDate date].timeIntervalSince1970 - 300)];
    }
    [all addObjectsFromArray:CSKReadLogStore(@LOGSTORE_PATH, &_offset, _includesInfoEntities, _includesDebugEntities, _pid,
                                             first ? [NSDate date].timeIntervalSince1970 - 300 : 0)];
    [self deliver:all];
}

- (void)resume
{
    if (_streaming)
        return;
    [super resume];
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    __weak CSKStreamDeviceSource *weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf poll]; });
    dispatch_resume(_timer);
}

- (void)stop
{
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
    [super stop];
}

- (void)dealloc { [self stop]; }

@end

@implementation CSKStreamSQLSource
- (void)resume
{
    [super resume];
    [self finished:0];
}
@end

@implementation CSKStreamArchiveSource

- (instancetype)initWithArchiveURL:(NSURL *)url error:(NSError **)error
{
    if (error)
        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError
                                 userInfo:@{NSLocalizedDescriptionKey : @"Log archives can't be opened on Finch yet.", NSURLErrorKey : url ?: @""}];
    return nil;
}

- (BOOL)isArchiveCorrupted { return YES; }

- (void)resume
{
    [super resume];
    [self finished:0];
}

@end

@implementation CSKStreamASLSource {
    NSURL *_url;
}

+ (instancetype)diagnosticAndUsageDataASLSource { return [[self alloc] initWithFileURL:nil]; }

- (instancetype)initWithFileURL:(NSURL *)url
{
    if ((self = [super init]))
        _url = url;
    return self;
}

- (void)resume
{
    [super resume];
    NSURL *url = _url;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *text = url ? [NSString stringWithContentsOfURL:url usedEncoding:NULL error:NULL] : nil;
        NSMutableArray *msgs = [NSMutableArray array];
        uint64_t n = 0;
        for (NSString *line in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
            if (!line.length)
                continue;
            CSKMessage *m = [CSKMessage new];
            m->_identifierNumber = @(++n);
            m->_messageText = line;
            m.type = CSKMessageTypeDefault;
            m.processName = url.lastPathComponent;
            [msgs addObject:m];
        }
        [self deliver:msgs];
        [self finished:msgs.count];
    });
}

@end

/* ---- the delegates' methods (Console implements them) ---- */

@protocol CSKFinchDelegateMethods <NSObject>
@optional
- (void)streamViewController:(id)vc selectionDidChangeWithEntities:(NSArray *)entities;
- (void)streamViewController:(id)vc didUpdateFilterFractionCompleted:(double)fraction;
- (void)streamViewController:(id)vc nowModeStateDidChange:(BOOL)on;
- (void)streamViewControllerFilteringDidStart:(id)vc;
- (void)streamViewControllerFilteringDidFinish:(id)vc;
- (void)streamViewControllerStreamingDidStart:(id)vc;
- (void)streamViewControllerStreamingDidFail:(id)vc;
- (void)streamViewControllerStreamingDidFinish:(id)vc total:(NSUInteger)total;
- (void)streamViewControllerDisplayedCountDidChange:(id)vc items:(NSUInteger)items;
- (void)streamViewControllerContentDidReset:(id)vc;
- (void)streamViewControllerDetailsPaneDidShow:(id)vc;
- (void)tokenFieldController:(id)c filtersDidUpdate:(NSArray *)filters;
- (void)tokenFieldController:(id)c basicSearchDidUpdateWithTerm:(NSString *)term;
- (NSArray *)tokenFieldController:(id)c menuItemsForFilter:(id)filter;
- (void)tokenFieldController:(id)c filter:(id)filter configureMenu:(NSMenu *)menu;
@end

/* ---- the stream view controller ---- */

@interface CSKStreamViewController : NSViewController <CSKFinchStreamSourceClient, NSTableViewDataSource, NSTableViewDelegate>
@property (weak, nonatomic) id<CSKFinchDelegateMethods> delegate;
@property (readonly) CSKStreamSource *source;
@end

@implementation CSKStreamViewController {
    CSKStreamSource *_source;
    NSUInteger _capacity;
    NSMutableArray *_all, *_shown;
    NSArray *_filters;
    CSKTableColumnLayout *_layout;
    NSString *_messagesAutosave, *_activitiesAutosave;
    NSTableView *_table;
    NSScrollView *_tableScroll, *_detailsScroll;
    NSTextView *_details;
    NSSplitView *_split;
    NSView *_status, *_trailing;
    NSTextField *_count;
    NSFont *_font;
    CGFloat _fontSize;
    BOOL _streamingMode, _nowMode, _showsDetails, _showsStatus, _showsActivities;
}

- (instancetype)init { return [self initWithStreamSource:nil capacity:0]; }
- (instancetype)initWithCoder:(NSCoder *)c { return [self initWithStreamSource:nil capacity:0]; }
- (instancetype)initWithNibName:(NSNibName)nib bundle:(NSBundle *)bundle { return [self initWithStreamSource:nil capacity:0]; }

- (instancetype)initWithStreamSource:(CSKStreamSource *)source capacity:(NSUInteger)capacity
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _source = source;
        _source.client = self;
        _capacity = capacity ?: 100000;
        _all = [NSMutableArray array];
        _shown = [NSMutableArray array];
        _filters = @[];
        _layout = [CSKMessagesTableColumnLayout new];
        _fontSize = 11;
        _font = [NSFont monospacedSystemFontOfSize:_fontSize weight:NSFontWeightRegular];
        _showsDetails = YES;
        _showsStatus = YES;
        _nowMode = YES;
    }
    return self;
}

- (void)dealloc { [_source stop]; }
- (CSKStreamSource *)source { return _source; }

/* ---- the view ---- */

- (void)loadView
{
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 500)];
    _table = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 800, 360)];
    _table.headerView = [[NSTableHeaderView alloc] initWithFrame:NSMakeRect(0, 0, 800, 24)];
    _table.dataSource = self;
    _table.delegate = self;
    _table.allowsMultipleSelection = YES;
    _table.usesAlternatingRowBackgroundColors = YES;
    _table.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    _table.rowHeight = 16;
    /* the messages get most of the height, the details pane the rest */
    _tableScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 800, 360)];
    _tableScroll.documentView = _table;
    _tableScroll.hasVerticalScroller = YES;
    _tableScroll.hasHorizontalScroller = YES;
    _tableScroll.autohidesScrollers = YES;

    _details = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 800, 120)];
    _details.editable = NO;
    _details.font = _font;
    _details.textContainerInset = NSMakeSize(6, 6);
    _details.autoresizingMask = NSViewWidthSizable;
    _detailsScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 800, 120)];
    _detailsScroll.documentView = _details;
    _detailsScroll.hasVerticalScroller = YES;

    _split = [[NSSplitView alloc] initWithFrame:NSMakeRect(0, 0, 800, 481)];
    _split.vertical = NO;
    _split.dividerStyle = NSSplitViewDividerStyleThin;
    [_split addArrangedSubview:_tableScroll];
    [_split addArrangedSubview:_detailsScroll];
    _split.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_split];

    _status = [[NSView alloc] initWithFrame:NSZeroRect];
    _status.translatesAutoresizingMaskIntoConstraints = NO;
    _count = [NSTextField labelWithString:@""];
    _count.font = [NSFont systemFontOfSize:11];
    _count.textColor = NSColor.secondaryLabelColor;
    _count.translatesAutoresizingMaskIntoConstraints = NO;
    [_status addSubview:_count];
    [root addSubview:_status];
    [NSLayoutConstraint activateConstraints:@[
        [_split.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_split.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_split.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_split.bottomAnchor constraintEqualToAnchor:_status.topAnchor],
        [_status.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_status.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_status.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [_status.heightAnchor constraintEqualToConstant:24],
        [_count.leadingAnchor constraintEqualToAnchor:_status.leadingAnchor constant:10],
        [_count.centerYAnchor constraintEqualToAnchor:_status.centerYAnchor],
    ]];
    self.view = root;
    [self rebuildColumns];
    _detailsScroll.hidden = !_showsDetails;
    _status.hidden = !_showsStatus;
    [self updateCount];
}

- (void)viewDidAppear
{
    [super viewDidAppear];
    if (_showsDetails)
        [_split setPosition:_split.bounds.size.height * 0.72 ofDividerAtIndex:0];
}

- (void)rebuildColumns
{
    while (_table.tableColumns.count)
        [_table removeTableColumn:_table.tableColumns.lastObject];
    NSDictionary *widths = @{CSKColumnType : @60, CSKColumnTime : @110, CSKColumnProcess : @120, CSKColumnPID : @60, CSKColumnThread : @90,
                             CSKColumnSubsystem : @160, CSKColumnCategory : @100, CSKColumnLibrary : @120, CSKColumnMessage : @600};
    for (NSString *ident in _layout.layoutColumnIdentifiers) {
        NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:ident];
        c.title = [CSKTableColumnLayout titleForColumnIdentifier:ident];
        c.width = [(_layout.layoutColumnInitialWidths[ident] ?: widths[ident] ?: @100) doubleValue];
        [_table addTableColumn:c];
    }
    [_table reloadData];
}

/* ---- table ---- */

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return (NSInteger)_shown.count; }

static NSString *
cell_text(CSKMessage *m, NSString *ident)
{
    if ([ident isEqualToString:CSKColumnType])
        return m.type == CSKMessageTypeDefault ? @"" : [CSKMessage localizedMessageTypeNameForType:m.type];
    if ([ident isEqualToString:CSKColumnTime])
        return m.formattedTime;
    if ([ident isEqualToString:CSKColumnProcess])
        return m.processName;
    if ([ident isEqualToString:CSKColumnPID])
        return m.processIdentifier.stringValue;
    if ([ident isEqualToString:CSKColumnThread])
        return m.threadIdentifier;
    if ([ident isEqualToString:CSKColumnSubsystem])
        return m.subsystem;
    if ([ident isEqualToString:CSKColumnCategory])
        return m.category;
    if ([ident isEqualToString:CSKColumnLibrary])
        return m.libraryName;
    return [m.message stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
}

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row
{
    NSTextField *f = [tv makeViewWithIdentifier:@"CSKCell" owner:nil];
    if (!f) {
        f = [NSTextField labelWithString:@""];
        f.identifier = @"CSKCell";
        f.lineBreakMode = NSLineBreakByTruncatingTail;
    }
    CSKMessage *m = _shown[row];
    f.font = _font;
    f.stringValue = cell_text(m, col.identifier) ?: @"";
    f.textColor = m.type == CSKMessageTypeError ? NSColor.systemOrangeColor
                  : m.type == CSKMessageTypeFault ? NSColor.systemRedColor
                  : m.type == CSKMessageTypeDebug ? NSColor.secondaryLabelColor
                                                  : NSColor.labelColor;
    return f;
}

- (void)tableViewSelectionDidChange:(NSNotification *)n
{
    NSArray *sel = self.selectedEntities;
    _details.string = [[sel valueForKey:@"description"] componentsJoinedByString:@"\n"];
    if ([_delegate respondsToSelector:@selector(streamViewController:selectionDidChangeWithEntities:)])
        [_delegate streamViewController:self selectionDidChangeWithEntities:sel];
    /* choosing a message leaves "now" mode */
    if (sel.count && _nowMode && _streamingMode)
        [self setNowMode:NO];
}

- (NSArray *)selectedEntities { return [_shown objectsAtIndexes:_table.selectedRowIndexes]; }
- (NSUInteger)displayedItemsCount { return _shown.count; }

- (NSString *)joinedPasteboardDescriptionsForSelectedEntities
{
    return [[self.selectedEntities valueForKey:@"description"] componentsJoinedByString:@"\n"];
}

- (void)copy:(id)sender
{
    [[NSPasteboard generalPasteboard] clearContents];
    [[NSPasteboard generalPasteboard] setString:self.joinedPasteboardDescriptionsForSelectedEntities forType:NSPasteboardTypeString];
}

/* ---- filtering ---- */

- (BOOL)passes:(CSKMessage *)m
{
    NSMutableDictionary *byType = [NSMutableDictionary dictionary];
    for (CSKFilter *f in _filters) {
        NSNumber *k = @(f.type);
        BOOL ok = [f matchesMessage:m];
        BOOL negative = f.comparisonType == CSKFilterComparisonDoesNotContain || f.comparisonType == CSKFilterComparisonDoesNotEqual;
        /* values of one kind: any positive one, and every negative one */
        NSMutableDictionary *g = byType[k] ?: (byType[k] = [@{@"any" : @NO, @"hasPositive" : @NO, @"all" : @YES} mutableCopy]);
        if (negative)
            g[@"all"] = @([g[@"all"] boolValue] && ok);
        else {
            g[@"hasPositive"] = @YES;
            g[@"any"] = @([g[@"any"] boolValue] || ok);
        }
    }
    for (NSDictionary *g in byType.allValues)
        if (![g[@"all"] boolValue] || ([g[@"hasPositive"] boolValue] && ![g[@"any"] boolValue]))
            return NO;
    return YES;
}

- (void)applyFilters:(NSArray *)filters
{
    _filters = [filters copy] ?: @[];
    if ([_delegate respondsToSelector:@selector(streamViewControllerFilteringDidStart:)])
        [_delegate streamViewControllerFilteringDidStart:self];
    [_shown removeAllObjects];
    for (CSKMessage *m in _all)
        if ([self passes:m])
            [_shown addObject:m];
    [_table reloadData];
    [self scrollIfNow];
    [self updateCount];
    if ([_delegate respondsToSelector:@selector(streamViewController:didUpdateFilterFractionCompleted:)])
        [_delegate streamViewController:self didUpdateFilterFractionCompleted:1.0];
    if ([_delegate respondsToSelector:@selector(streamViewControllerFilteringDidFinish:)])
        [_delegate streamViewControllerFilteringDidFinish:self];
}

- (NSArray *)currentFilters { return _filters; }

/* ---- streaming ---- */

- (void)streamSource:(CSKStreamSource *)source didStreamForwardEntities:(NSArray *)entities
{
    [_all addObjectsFromArray:entities];
    NSUInteger before = _shown.count;
    for (CSKMessage *m in entities)
        if ([self passes:m])
            [_shown addObject:m];
    if (_all.count > _capacity) {
        NSUInteger drop = _all.count - _capacity;
        NSSet *gone = [NSSet setWithArray:[_all subarrayWithRange:NSMakeRange(0, drop)]];
        [_all removeObjectsInRange:NSMakeRange(0, drop)];
        [_shown filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id m, NSDictionary *b) { return ![gone containsObject:m]; }]];
        [_table reloadData];
    } else if (_shown.count > before) {
        [_table insertRowsAtIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(before, _shown.count - before)] withAnimation:0];
    }
    [self scrollIfNow];
    [self updateCount];
}

- (void)streamSourceDidFinish:(CSKStreamSource *)source total:(NSUInteger)total failures:(NSUInteger)failures
{
    if ([_delegate respondsToSelector:@selector(streamViewControllerStreamingDidFinish:total:)])
        [_delegate streamViewControllerStreamingDidFinish:self total:total];
}

- (void)streamSourceDidFail:(CSKStreamSource *)source
{
    if ([_delegate respondsToSelector:@selector(streamViewControllerStreamingDidFail:)])
        [_delegate streamViewControllerStreamingDidFail:self];
}

- (void)scrollIfNow
{
    if (_nowMode && _shown.count)
        [_table scrollRowToVisible:(NSInteger)_shown.count - 1];
}

- (void)updateCount
{
    NSString *n = [CSKHelpers formattedNumberFromUnsignedInteger:_shown.count];
    _count.stringValue = _all.count == _shown.count
                             ? [NSString stringWithFormat:@"%@ messages", n]
                             : [NSString stringWithFormat:@"%@ of %@ messages", n, [CSKHelpers formattedNumberFromUnsignedInteger:_all.count]];
    if ([_delegate respondsToSelector:@selector(streamViewControllerDisplayedCountDidChange:items:)])
        [_delegate streamViewControllerDisplayedCountDidChange:self items:_shown.count];
}

- (BOOL)wantsStreamingMode { return _streamingMode; }

- (void)setWantsStreamingMode:(BOOL)on
{
    if (on == _streamingMode)
        return;
    _streamingMode = on;
    if (on) {
        [_source resume];
        if ([_delegate respondsToSelector:@selector(streamViewControllerStreamingDidStart:)])
            [_delegate streamViewControllerStreamingDidStart:self];
        [self setNowMode:YES];
    } else {
        [_source stop];
        if ([_delegate respondsToSelector:@selector(streamViewControllerStreamingDidFinish:total:)])
            [_delegate streamViewControllerStreamingDidFinish:self total:_all.count];
    }
}

- (void)pauseStreaming { self.wantsStreamingMode = NO; }

- (void)setNowMode:(BOOL)on
{
    if (on == _nowMode)
        return;
    _nowMode = on;
    if (on)
        [self scrollIfNow];
    if ([_delegate respondsToSelector:@selector(streamViewController:nowModeStateDidChange:)])
        [_delegate streamViewController:self nowModeStateDidChange:on];
}

- (void)setWantsNowMode:(BOOL)on { [self setNowMode:on]; }

- (void)reload
{
    if (_source.isLive)
        return;
    [self clearContent];
    [_source resume];
}

- (void)clearContent
{
    [_all removeAllObjects];
    [_shown removeAllObjects];
    [_table reloadData];
    _details.string = @"";
    [self updateCount];
    if ([_delegate respondsToSelector:@selector(streamViewControllerContentDidReset:)])
        [_delegate streamViewControllerContentDidReset:self];
}

- (void)clear { [self clearContent]; }

/* ---- presentation ---- */

- (void)setShowsDetailsPane:(BOOL)on
{
    if (on == _showsDetails && (!self.isViewLoaded || _detailsScroll.hidden == !on))
        return;
    _showsDetails = on;
    _detailsScroll.hidden = !on;
    [_split adjustSubviews];
    if (on && [_delegate respondsToSelector:@selector(streamViewControllerDetailsPaneDidShow:)])
        [_delegate streamViewControllerDetailsPaneDidShow:self];
}

- (BOOL)showsDetailsPane { return _showsDetails; }

- (void)setShowsStatusView:(BOOL)on
{
    _showsStatus = on;
    _status.hidden = !on;
}

- (void)setShowsActivities:(BOOL)on { _showsActivities = on; }

- (void)addTrailingViewToStatusView:(NSView *)v
{
    [self removeTrailingViewFromStatusView];
    if (!v)
        return;
    (void)self.view;
    _trailing = v;
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [_status addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
        [v.trailingAnchor constraintEqualToAnchor:_status.trailingAnchor constant:-8],
        [v.centerYAnchor constraintEqualToAnchor:_status.centerYAnchor],
    ]];
}

- (void)removeTrailingViewFromStatusView
{
    [_trailing removeFromSuperview];
    _trailing = nil;
}

- (void)setDefaultFont:(NSFont *)font
{
    if (!font)
        return;
    _font = font;
    _fontSize = font.pointSize;
    _details.font = font;
    _table.rowHeight = ceil(font.pointSize * 1.45);
    [_table reloadData];
}

- (BOOL)canMakeTextFontSizeBigger { return _fontSize < 36; }
- (BOOL)canMakeTextFontSizeSmaller { return _fontSize > 7; }
- (void)makeTextFontSizeBigger { [self setDefaultFont:[NSFont fontWithDescriptor:_font.fontDescriptor size:_fontSize + 1]]; }
- (void)makeTextFontSizeSmaller { [self setDefaultFont:[NSFont fontWithDescriptor:_font.fontDescriptor size:_fontSize - 1]]; }
- (void)makeTextFontStandardSize { [self setDefaultFont:[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular]]; }

/* ---- columns ---- */

- (NSString *)layoutDefaultsKey { return _messagesAutosave ? [@"CSKColumnLayout-" stringByAppendingString:_messagesAutosave] : nil; }

- (void)setMessagesColumnLayoutAutosaveName:(NSString *)name
{
    _messagesAutosave = [name copy];
    NSArray *saved = self.layoutDefaultsKey ? [[NSUserDefaults standardUserDefaults] arrayForKey:self.layoutDefaultsKey] : nil;
    if (saved.count) {
        _layout.layoutColumnIdentifiers = saved;
        if (self.isViewLoaded)
            [self rebuildColumns];
    }
}

- (void)setActivitiesColumnLayoutAutosaveName:(NSString *)name { _activitiesAutosave = [name copy]; }
- (CSKTableColumnLayout *)currentColumnLayout { return _layout; }

- (void)applyColumnLayout:(CSKTableColumnLayout *)layout
{
    [self updateMessagesColumnLayoutWithoutInvalidateAndSave:layout];
    if (self.layoutDefaultsKey)
        [[NSUserDefaults standardUserDefaults] setObject:_layout.layoutColumnIdentifiers forKey:self.layoutDefaultsKey];
}

- (void)updateMessagesColumnLayoutWithoutInvalidateAndSave:(CSKTableColumnLayout *)layout
{
    if (!layout)
        return;
    _layout = layout;
    if (self.isViewLoaded)
        [self rebuildColumns];
}

- (void)updateActivitiesColumnLayoutWithoutInvalidateAndSave:(CSKTableColumnLayout *)layout {}

/* ---- load ranges, activities, find ---- */

- (void)populateLoadRangeMenu:(NSMenu *)menu usingBlock:(void (^)(NSMenuItem *))block
{
    [menu removeAllItems];
    for (CSKLoadRange *r in _source.availableLoadRanges) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:r.localizedDescription action:NULL keyEquivalent:@""];
        item.representedObject = r;
        item.state = [r isEqual:_source.currentLoadRange] ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:item];
        if (block)
            block(item);
    }
}

- (void)updateSelectedLoadRange:(CSKLoadRange *)range
{
    _source.currentLoadRange = range;
    [self reload];
}

- (void)expandSelectedEntities {}
- (void)collapseSelectedEntities {}

/* Find: the search tokens do the finding; Command-F focuses the table. */
- (void)performFindPanelAction:(id)sender { [self.view.window makeFirstResponder:_table]; }
- (void)performTextFinderAction:(id)sender { [self performFindPanelAction:sender]; }

@end

/* ---- the search field's tokens ---- */

@interface CSKTokenFieldController : NSObject <NSTokenFieldDelegate>
@property (weak, nonatomic) id<CSKFinchDelegateMethods> delegate;
@property (strong, nonatomic) NSTokenField *tokenField;
@end

@implementation CSKTokenFieldController {
    NSTokenField *_tokenField;
    NSString *_term;
    NSUUID *_searchID;
    BOOL _basic;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _searchID = [NSUUID UUID];
        _term = @"";
    }
    return self;
}

- (void)dealloc { _tokenField.delegate = nil; }
- (NSTokenField *)tokenField { return _tokenField; }

- (void)setTokenField:(NSTokenField *)field
{
    _tokenField.delegate = nil;
    _tokenField = field;
    field.delegate = self;
    field.tokenStyle = NSTokenStyleRounded;
    field.placeholderString = field.placeholderString ?: @"Search";
}

- (void)setIsBasicSearchEnabled:(BOOL)on { _basic = on; }
- (NSString *)currentSearchID { return _searchID.UUIDString; }
- (NSString *)currentSearchTerm { return _term; }

- (NSArray *)currentSearchFilters
{
    NSMutableArray *a = [NSMutableArray array];
    for (id o in _tokenField.objectValue ?: @[])
        if ([o isKindOfClass:[CSKFilter class]])
            [a addObject:o];
        else if ([o isKindOfClass:[NSString class]] && [o length])
            [a addObject:[[CSKFilter alloc] initWithType:CSKFilterTypeAny value:o]];
    return a;
}

- (void)notify
{
    _searchID = [NSUUID UUID];
    if ([_delegate respondsToSelector:@selector(tokenFieldController:filtersDidUpdate:)])
        [_delegate tokenFieldController:self filtersDidUpdate:self.currentSearchFilters];
}

- (void)updateSearchWithFilters:(NSArray *)filters
{
    _tokenField.objectValue = filters ?: @[];
    [self notify];
}

- (void)addFiltersToSearch:(NSArray *)filters { [self addFiltersToCurrentSearchFilters:filters]; }

- (void)addFiltersToCurrentSearchFilters:(NSArray *)filters
{
    NSMutableArray *a = [self.currentSearchFilters mutableCopy];
    for (CSKFilter *f in filters)
        if (![a containsObject:f])
            [a addObject:f];
    [self updateSearchWithFilters:a];
}

- (void)clearCurrentSearchFilters { [self updateSearchWithFilters:@[]]; }

- (void)controlTextDidChange:(NSNotification *)n
{
    NSText *editor = n.userInfo[@"NSFieldEditor"];
    _term = editor.string ?: _tokenField.stringValue ?: @"";
    if (_basic && [_delegate respondsToSelector:@selector(tokenFieldController:basicSearchDidUpdateWithTerm:)])
        [_delegate tokenFieldController:self basicSearchDidUpdateWithTerm:_term];
}

- (void)controlTextDidEndEditing:(NSNotification *)n { [self notify]; }

/* Tokens are filters: typed text becomes an "Any contains" filter. */
- (id)tokenField:(NSTokenField *)field representedObjectForEditingString:(NSString *)s
{
    return [[CSKFilter alloc] initWithType:CSKFilterTypeAny value:s];
}

- (NSString *)tokenField:(NSTokenField *)field displayStringForRepresentedObject:(id)o
{
    if (![o isKindOfClass:[CSKFilter class]])
        return [o description];
    CSKFilter *f = o;
    NSString *v = f.value ?: f.number.stringValue ?: @"";
    if (f.type == CSKFilterTypeAny && f.comparisonType == CSKFilterComparisonContains)
        return v;
    NSString *cmp = f.comparisonType == CSKFilterComparisonContains ? @":" : [NSString stringWithFormat:@" %@ ", [CSKFilter localizedFilterComparisonTypeNameForComparisonType:f.comparisonType].lowercaseString];
    return [NSString stringWithFormat:@"%@%@%@", [CSKFilter localizedFilterTypeNameForType:f.type], cmp, v];
}

- (NSString *)tokenField:(NSTokenField *)field editingStringForRepresentedObject:(id)o
{
    return [o isKindOfClass:[CSKFilter class]] ? ((CSKFilter *)o).value : [o description];
}

- (BOOL)tokenField:(NSTokenField *)field hasMenuForRepresentedObject:(id)o
{
    return [o isKindOfClass:[CSKFilter class]] && [_delegate respondsToSelector:@selector(tokenFieldController:menuItemsForFilter:)];
}

- (NSMenu *)tokenField:(NSTokenField *)field menuForRepresentedObject:(id)o
{
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    for (NSMenuItem *item in [_delegate tokenFieldController:self menuItemsForFilter:o] ?: @[])
        [menu addItem:item];
    if ([_delegate respondsToSelector:@selector(tokenFieldController:filter:configureMenu:)])
        [_delegate tokenFieldController:self filter:o configureMenu:menu];
    return menu;
}

- (NSArray *)tokenField:(NSTokenField *)field shouldAddObjects:(NSArray *)tokens atIndex:(NSUInteger)index
{
    dispatch_async(dispatch_get_main_queue(), ^{ [self notify]; });
    return tokens;
}

@end
