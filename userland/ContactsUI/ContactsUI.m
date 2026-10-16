/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * ContactsUI: Finch's own contact picker and contact card. The picker reads the local
 * Contacts store and presents its contacts and requested values in an AppKit popover.
 */
#import <AppKit/AppKit.h>
#import <Contacts/Contacts.h>
#import <ContactsUI/ContactsUI.h>
#import "../Contacts/Contacts_Finch.h"

@interface CNContactProperty (FinchPickerConstruction)
+ (instancetype)contactPropertyWithContact:(CNContact *)contact propertyKey:(NSString *)key identifier:(NSString *)identifier;
@end

@interface CNContactPicker () <NSPopoverDelegate, NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation CNContactPicker {
    NSArray<NSString *> *_displayedKeys;
    id<CNContactPickerDelegate> _delegate;
    NSArray<NSDictionary *> *_rows;
    NSPopover *_popover;
}

- (instancetype)init
{
    if ((self = [super init]))
        _displayedKeys = @[];
    return self;
}

- (NSArray<NSString *> *)displayedKeys { return _displayedKeys; }
- (void)setDisplayedKeys:(NSArray<NSString *> *)keys { _displayedKeys = [keys copy] ?: @[]; }
- (id<CNContactPickerDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<CNContactPickerDelegate>)delegate { _delegate = delegate; }

- (void)_loadRows
{
    NSMutableArray *keys = [NSMutableArray arrayWithArray:@[ CNContactGivenNameKey, CNContactMiddleNameKey,
        CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
        CNContactPostalAddressesKey, CNContactUrlAddressesKey ]];
    [keys addObjectsFromArray:_displayedKeys];
    CNContactFetchRequest *request = [[CNContactFetchRequest alloc] initWithKeysToFetch:keys];
    NSMutableArray *contacts = [NSMutableArray array];
    [[CNContactStore new] enumerateContactsWithFetchRequest:request error:NULL usingBlock:^(CNContact *contact, BOOL *stop) {
        [contacts addObject:contact];
    }];
    [contacts sortUsingComparator:^NSComparisonResult(CNContact *a, CNContact *b) {
        NSString *left = [CNContactFormatter stringFromContact:a style:CNContactFormatterStyleFullName] ?: @"";
        NSString *right = [CNContactFormatter stringFromContact:b style:CNContactFormatterStyleFullName] ?: @"";
        return [left localizedCaseInsensitiveCompare:right];
    }];

    NSMutableArray *rows = [NSMutableArray array];
    for (CNContact *contact in contacts) {
        NSString *name = [CNContactFormatter stringFromContact:contact style:CNContactFormatterStyleFullName] ?: @"";
        if (!_displayedKeys.count) {
            [rows addObject:@{ @"contact" : contact, @"title" : name.length ? name : @"Unnamed Contact" }];
            continue;
        }
        for (NSString *key in _displayedKeys) {
            if (![contact isKeyAvailable:key])
                continue;
            id value = [contact valueForKey:key];
            if ([value isKindOfClass:[NSArray class]]) {
                for (CNLabeledValue *labeled in value) {
                    NSString *text = [labeled.value respondsToSelector:@selector(stringValue)] ? [labeled.value stringValue] : [labeled.value description];
                    NSString *label = [CNLabeledValue localizedStringForLabel:labeled.label ?: @""];
                    CNContactProperty *property = [CNContactProperty contactPropertyWithContact:contact propertyKey:key identifier:labeled.identifier];
                    NSString *title = [NSString stringWithFormat:@"%@ — %@ %@", name, label ?: @"", text ?: @""];
                    [rows addObject:@{ @"contact" : contact, @"property" : property, @"title" : title }];
                }
            } else if (value) {
                CNContactProperty *property = [CNContactProperty contactPropertyWithContact:contact propertyKey:key identifier:nil];
                [rows addObject:@{ @"contact" : contact, @"property" : property,
                                   @"title" : [NSString stringWithFormat:@"%@ — %@", name, value] }];
            }
        }
    }
    _rows = [rows copy];
}

- (void)showRelativeToRect:(NSRect)rect ofView:(NSView *)view preferredEdge:(NSRectEdge)edge
{
    if (!view || !view.window)
        return;
    [self close];
    [self _loadRows];

    NSTableView *table = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 320, 260)];
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"contact"];
    column.width = 320;
    [table addTableColumn:column];
    table.headerView = nil;
    table.rowHeight = 26;
    table.dataSource = self;
    table.delegate = self;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:table.frame];
    scroll.hasVerticalScroller = YES;
    scroll.documentView = table;
    NSViewController *controller = [[NSViewController alloc] init];
    controller.view = scroll;

    _popover = [[NSPopover alloc] init];
    _popover.behavior = NSPopoverBehaviorTransient;
    _popover.delegate = self;
    _popover.contentViewController = controller;
    [_popover showRelativeToRect:rect ofView:view preferredEdge:edge];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return (NSInteger)_rows.count; }

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
    NSTextField *cell = [tableView makeViewWithIdentifier:@"contact-cell" owner:self];
    if (!cell) {
        cell = [NSTextField labelWithString:@""];
        cell.identifier = @"contact-cell";
        cell.lineBreakMode = NSLineBreakByTruncatingTail;
    }
    cell.stringValue = _rows[(NSUInteger)row][@"title"] ?: @"";
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    NSTableView *table = notification.object;
    NSInteger row = table.selectedRow;
    if (row < 0 || (NSUInteger)row >= _rows.count)
        return;
    NSDictionary *choice = _rows[(NSUInteger)row];
    if (_displayedKeys.count) {
        if ([_delegate respondsToSelector:@selector(contactPicker:didSelectContactProperty:)])
            [_delegate contactPicker:self didSelectContactProperty:choice[@"property"]];
    } else if ([_delegate respondsToSelector:@selector(contactPicker:didSelectContact:)]) {
        [_delegate contactPicker:self didSelectContact:choice[@"contact"]];
    }
    [self close];
}

- (void)popoverWillClose:(NSNotification *)notification
{
    if ([_delegate respondsToSelector:@selector(contactPickerWillClose:)])
        [_delegate contactPickerWillClose:self];
}

- (void)popoverDidClose:(NSNotification *)notification
{
    _popover.delegate = nil;
    _popover = nil;
    if ([_delegate respondsToSelector:@selector(contactPickerDidClose:)])
        [_delegate contactPickerDidClose:self];
}

- (void)close
{
    if (_popover.isShown)
        [_popover close];
    else
        _popover = nil;
}

@end

@implementation CNContactViewController {
    CNContact *_contact;
    NSView *_contactView;
}

+ (id<CNKeyDescriptor>)descriptorForRequiredKeys
{
    return [[CNAggregateKeyDescriptor alloc] initWithKeyDescriptors:@[
        [CNContactFormatter descriptorForRequiredKeysForStyle:CNContactFormatterStyleFullName],
        CNContactPhoneNumbersKey, CNContactEmailAddressesKey
    ] description:@"CNContactViewController"];
}

- (CNContact *)contact { return _contact; }

- (void)setContact:(CNContact *)contact
{
    if (_contact == contact)
        return;
    _contact = [contact copy];
    if (self.isViewLoaded)
        [self _refreshContactView];
}

- (void)loadView
{
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 360, 300)];
    [self _refreshContactView];
}

- (void)_refreshContactView
{
    [_contactView removeFromSuperview];
    _contactView = nil;
    NSMutableArray *lines = [NSMutableArray array];
    if (_contact) {
        NSString *name = [CNContactFormatter stringFromContact:_contact style:CNContactFormatterStyleFullName];
        if (name.length)
            [lines addObject:[NSTextField labelWithString:name]];
        if ([_contact isKeyAvailable:CNContactOrganizationNameKey] && _contact.organizationName.length)
            [lines addObject:[NSTextField labelWithString:_contact.organizationName]];
        for (NSString *key in @[ CNContactPhoneNumbersKey, CNContactEmailAddressesKey ]) {
            if (![_contact isKeyAvailable:key])
                continue;
            NSArray<CNLabeledValue *> *values = [_contact valueForKey:key];
            for (CNLabeledValue *entry in values) {
                NSString *label = [CNLabeledValue localizedStringForLabel:entry.label ?: @""];
                [lines addObject:[NSTextField labelWithString:[NSString stringWithFormat:@"%@  %@", label ?: @"", entry.value]]];
            }
        }
    }
    if (!lines.count)
        [lines addObject:[NSTextField labelWithString:@"No contact selected"]];
    NSStackView *stack = [NSStackView stackViewWithViews:lines];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:16]
    ]];
    _contactView = stack;
}

@end

