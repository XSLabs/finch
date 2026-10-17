// SPDX-License-Identifier: MIT OR Apache-2.0
// Finch: the newer half of AppKit's Swift overlay, Finch's own code, declared as Apple's
// interface declares it (so apps' imports resolve): diffable data sources and their
// snapshots, text suggestions, @NSView.Invalidating, frame-resize cursors, menu section
// headers' older spelling, pull-down pop-up buttons, the glass bezel styles. AppKitOverlay.swift has the
// historical half.

import Foundation
@_exported import AppKit

@available(macOS 15.0, *)
@frozen public enum NSHorizontalDirection: Int8, CaseIterable, Codable {
  case left
  case right

  @frozen public struct Set: OptionSet, Equatable, Hashable {
    public typealias Element = NSHorizontalDirection.Set
    public typealias RawValue = Int8
    public typealias ArrayLiteralElement = NSHorizontalDirection.Set.Element

    public let rawValue: Int8

    public init(rawValue: Int8) { self.rawValue = rawValue }
    public init(_ direction: NSHorizontalDirection) { self = direction == .left ? .left : .right }

    public static let left = Set(rawValue: 1 << NSHorizontalDirection.left.rawValue)
    public static let right = Set(rawValue: 1 << NSHorizontalDirection.right.rawValue)
    public static let all: Set = [.left, .right]

    public func contains(_ member: NSHorizontalDirection) -> Bool {
      contains(Set(member))
    }

    @discardableResult
    public mutating func insert(_ newMember: __owned NSHorizontalDirection) -> (inserted: Bool, memberAfterInsert: NSHorizontalDirection) {
      let inserted = !contains(newMember)
      self = Set(rawValue: rawValue | Set(newMember).rawValue)
      return (inserted, newMember)
    }

    @discardableResult
    public mutating func remove(_ member: NSHorizontalDirection) -> NSHorizontalDirection? {
      guard contains(member) else { return nil }
      self = Set(rawValue: rawValue & ~Set(member).rawValue)
      return member
    }

    @discardableResult
    public mutating func update(with newMember: __owned NSHorizontalDirection) -> NSHorizontalDirection? {
      let oldMember = contains(newMember) ? newMember : nil
      self = Set(rawValue: rawValue | Set(newMember).rawValue)
      return oldMember
    }
  }

  public typealias AllCases = [NSHorizontalDirection]
  public typealias RawValue = Int8

  public static var allCases: [NSHorizontalDirection] { [.left, .right] }

  public static func leading(relativeTo layoutDirection: NSUserInterfaceLayoutDirection) -> NSHorizontalDirection {
    layoutDirection == .rightToLeft ? .right : .left
  }

  public static func trailing(relativeTo layoutDirection: NSUserInterfaceLayoutDirection) -> NSHorizontalDirection {
    layoutDirection == .rightToLeft ? .left : .right
  }
}

@available(macOS 15.0, *)
@frozen public enum NSVerticalDirection: Int8, CaseIterable, Codable {
  case up
  case down

  @frozen public struct Set: OptionSet, Equatable, Hashable {
    public typealias Element = NSVerticalDirection.Set
    public typealias RawValue = Int8
    public typealias ArrayLiteralElement = NSVerticalDirection.Set.Element

    public let rawValue: Int8

    public init(rawValue: Int8) { self.rawValue = rawValue }
    public init(_ direction: NSVerticalDirection) { self = direction == .up ? .up : .down }

    public static let up = Set(rawValue: 1 << NSVerticalDirection.up.rawValue)
    public static let down = Set(rawValue: 1 << NSVerticalDirection.down.rawValue)
    public static let all: Set = [.up, .down]

    public func contains(_ member: NSVerticalDirection) -> Bool {
      contains(Set(member))
    }

    @discardableResult
    public mutating func insert(_ newMember: __owned NSVerticalDirection) -> (inserted: Bool, memberAfterInsert: NSVerticalDirection) {
      let inserted = !contains(newMember)
      self = Set(rawValue: rawValue | Set(newMember).rawValue)
      return (inserted, newMember)
    }

    @discardableResult
    public mutating func remove(_ member: NSVerticalDirection) -> NSVerticalDirection? {
      guard contains(member) else { return nil }
      self = Set(rawValue: rawValue & ~Set(member).rawValue)
      return member
    }

    @discardableResult
    public mutating func update(with newMember: __owned NSVerticalDirection) -> NSVerticalDirection? {
      let oldMember = contains(newMember) ? newMember : nil
      self = Set(rawValue: rawValue | Set(newMember).rawValue)
      return oldMember
    }
  }

  public typealias AllCases = [NSVerticalDirection]
  public typealias RawValue = Int8

  public static var allCases: [NSVerticalDirection] { [.up, .down] }
}

// MARK: - Toolbar badges

@available(macOS 14.0, *)
extension NSMenuItemBadge {
  @objc dynamic public var stringValue: String? {
    let state = self.perform(Selector(("_finchCodingState"))).takeUnretainedValue() as! [String: Any]
    return state["stringValue"] as? String
  }
}

@available(macOS 15.0, *)
extension NSMenuItemBadge: Codable {
  private enum CodingKeys: String, CodingKey {
    case itemCount
    case stringValue
    case type
    case usesPreferredLocalization
  }

  public required convenience init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let itemCount = try container.decode(Int.self, forKey: .itemCount)
    let stringValue = try container.decodeIfPresent(String.self, forKey: .stringValue)
    let type = try container.decode(Int.self, forKey: .type)
    let usesPreferredLocalization = try container.decode(Bool.self, forKey: .usesPreferredLocalization)

    if type == NSMenuItemBadge.BadgeType.none.rawValue && itemCount == 0, let stringValue {
      self.init(string: stringValue)
    } else {
      self.init(count: itemCount)
    }

    let state: [String: Any] = [
      "itemCount": itemCount,
      "stringValue": stringValue as Any? ?? NSNull(),
      "type": type,
      "usesPreferredLocalization": usesPreferredLocalization,
    ]
    _ = self.perform(Selector(("_finchSetCodingState:")), with: state)
  }

  public func encode(to encoder: Encoder) throws {
    let state = self.perform(Selector(("_finchCodingState"))).takeUnretainedValue() as! [String: Any]
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(state["itemCount"] as! Int, forKey: .itemCount)
    if state["itemCount"] as! Int == 0,
       state["type"] as! Int == NSMenuItemBadge.BadgeType.none.rawValue,
       let stringValue = state["stringValue"] as? String {
      try container.encode(stringValue, forKey: .stringValue)
    } else {
      try container.encodeNil(forKey: .stringValue)
    }
    try container.encode(state["type"] as! Int, forKey: .type)
    try container.encode(state["usesPreferredLocalization"] as! Bool, forKey: .usesPreferredLocalization)
  }
}

@_silgen_name("FinchAppKitSwiftItemBadgeWithCount")
private func _finchItemBadgeWithCount(_ count: Int) -> AnyObject
@_silgen_name("FinchAppKitSwiftItemBadgeWithText")
private func _finchItemBadgeWithText(_ text: NSString) -> AnyObject
@_silgen_name("FinchAppKitSwiftItemBadgeIndicator")
private func _finchItemBadgeIndicator() -> AnyObject
@_silgen_name("FinchAppKitSwiftItemBadgeText")
private func _finchItemBadgeText(_ badge: AnyObject) -> NSString
@_silgen_name("FinchAppKitSwiftToolbarItemBadge")
private func _finchToolbarItemBadge(_ item: NSToolbarItem) -> AnyObject?
@_silgen_name("FinchAppKitSwiftSetToolbarItemBadge")
private func _finchSetToolbarItemBadge(_ item: NSToolbarItem, _ badge: AnyObject?)

@available(macOS 26.0, *)
public struct NSItemBadge : Equatable {
  fileprivate let _object: AnyObject

  fileprivate init(_object: AnyObject) { self._object = _object }

  public static func count(_ count: Int) -> NSItemBadge {
    NSItemBadge(_object: _finchItemBadgeWithCount(count))
  }

  public static func text(_ text: String) -> NSItemBadge {
    NSItemBadge(_object: _finchItemBadgeWithText(text as NSString))
  }

  public static var indicator: NSItemBadge {
    NSItemBadge(_object: _finchItemBadgeIndicator())
  }

  public var text: String { _finchItemBadgeText(_object) as String }

  public static func == (lhs: NSItemBadge, rhs: NSItemBadge) -> Bool {
    lhs.text == rhs.text
  }
}

@available(macOS 26.0, *)
@MainActor
extension NSToolbarItem {
  public var badge: NSItemBadge? {
    get {
      guard let object = _finchToolbarItemBadge(self) else { return nil }
      return NSItemBadge(_object: object)
    }
    set {
      _finchSetToolbarItemBadge(self, newValue?._object)
    }
  }
}

// MARK: - View layout regions

@_silgen_name("FinchAppKitSwiftLayoutGuideForRegion")
private func _finchLayoutGuideForRegion(_ view: NSView, _ kind: Int, _ axis: Int) -> NSLayoutGuide
@_silgen_name("FinchAppKitSwiftEdgeInsetsForRegion")
private func _finchEdgeInsetsForRegion(_ view: NSView, _ kind: Int, _ axis: Int) -> NSEdgeInsets
@_silgen_name("FinchAppKitSwiftRectForRegion")
private func _finchRectForRegion(_ view: NSView, _ kind: Int, _ axis: Int) -> NSRect

@available(macOS 26.0, *)
extension NSView {
  public struct LayoutRegion : Hashable, Equatable {
    public enum AdaptivityAxis : Equatable, Hashable {
      case horizontal
      case vertical

      fileprivate var _value: Int {
        switch self {
        case .horizontal: return 1
        case .vertical: return 2
        }
      }

      public static func == (a: AdaptivityAxis, b: AdaptivityAxis) -> Bool {
        a._value == b._value
      }

      public func hash(into hasher: inout Hasher) { hasher.combine(_value) }

      public var hashValue: Int {
        var hasher = Hasher()
        hash(into: &hasher)
        return hasher.finalize()
      }
    }

    private enum _Kind: Int { case safeArea, margins }
    private let _kind: _Kind
    private let _axis: AdaptivityAxis?

    private init(kind: _Kind, axis: AdaptivityAxis?) {
      _kind = kind
      _axis = axis
    }

    fileprivate var _kindValue: Int { _kind.rawValue }
    fileprivate var _axisValue: Int { _axis?._value ?? 0 }

    public static func safeArea(cornerAdaptation: AdaptivityAxis? = nil) -> LayoutRegion {
      LayoutRegion(kind: .safeArea, axis: cornerAdaptation)
    }

    public static func margins(cornerAdaptation: AdaptivityAxis? = nil) -> LayoutRegion {
      LayoutRegion(kind: .margins, axis: cornerAdaptation)
    }

    public static func == (a: LayoutRegion, b: LayoutRegion) -> Bool {
      a._kind == b._kind && a._axis == b._axis
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(_kind.rawValue)
      hasher.combine(_axis?._value ?? 0)
    }

    public var hashValue: Int {
      var hasher = Hasher()
      hash(into: &hasher)
      return hasher.finalize()
    }
  }

  public func layoutGuide(for region: LayoutRegion) -> NSLayoutGuide {
    _finchLayoutGuideForRegion(self, region._kindValue, region._axisValue)
  }

  public func edgeInsets(for region: LayoutRegion) -> NSEdgeInsets {
    _finchEdgeInsetsForRegion(self, region._kindValue, region._axisValue)
  }

  public func rect(for region: LayoutRegion) -> NSRect {
    _finchRectForRegion(self, region._kindValue, region._axisValue)
  }
}

// MARK: - Snapshots

@available(macOS 10.15.1, *)
public struct NSDiffableDataSourceSnapshot<SectionIdentifierType, ItemIdentifierType> where SectionIdentifierType : Hashable, ItemIdentifierType : Hashable {
  internal var _sections: [SectionIdentifierType] = []
  internal var _items: [SectionIdentifierType: [ItemIdentifierType]] = [:]
  internal var _reloadedItems: Set<ItemIdentifierType> = []
  internal var _reloadedSections: Set<SectionIdentifierType> = []

  public init() {}

  public var numberOfItems: Int { _sections.reduce(0) { $0 + (_items[$1]?.count ?? 0) } }
  public var numberOfSections: Int { _sections.count }
  public var sectionIdentifiers: [SectionIdentifierType] { _sections }
  public var itemIdentifiers: [ItemIdentifierType] { _sections.flatMap { _items[$0] ?? [] } }

  public func numberOfItems(inSection identifier: SectionIdentifierType) -> Int {
    _items[identifier]?.count ?? 0
  }

  public func itemIdentifiers(inSection identifier: SectionIdentifierType) -> [ItemIdentifierType] {
    _items[identifier] ?? []
  }

  public func sectionIdentifier(containingItem identifier: ItemIdentifierType) -> SectionIdentifierType? {
    _sections.first { _items[$0]?.contains(identifier) ?? false }
  }

  public func indexOfItem(_ identifier: ItemIdentifierType) -> Int? {
    itemIdentifiers.firstIndex(of: identifier)
  }

  public func indexOfSection(_ identifier: SectionIdentifierType) -> Int? {
    _sections.firstIndex(of: identifier)
  }

  /// (to the last section when none is named, as Apple's)
  public mutating func appendItems(_ identifiers: [ItemIdentifierType], toSection sectionIdentifier: SectionIdentifierType? = nil) {
    guard let section = sectionIdentifier ?? _sections.last else {
      fatalError("There are currently no sections in the data source. Please add a section first.")
    }
    _items[section, default: []].append(contentsOf: identifiers)
  }

  private func _locate(_ identifier: ItemIdentifierType) -> (SectionIdentifierType, Int)? {
    for s in _sections {
      if let i = _items[s]?.firstIndex(of: identifier) { return (s, i) }
    }
    return nil
  }

  public mutating func insertItems(_ identifiers: [ItemIdentifierType], beforeItem beforeIdentifier: ItemIdentifierType) {
    guard let (s, i) = _locate(beforeIdentifier) else { fatalError("Invalid item identifier specified for insert") }
    _items[s]!.insert(contentsOf: identifiers, at: i)
  }

  public mutating func insertItems(_ identifiers: [ItemIdentifierType], afterItem afterIdentifier: ItemIdentifierType) {
    guard let (s, i) = _locate(afterIdentifier) else { fatalError("Invalid item identifier specified for insert") }
    _items[s]!.insert(contentsOf: identifiers, at: i + 1)
  }

  public mutating func deleteItems(_ identifiers: [ItemIdentifierType]) {
    let gone = Set(identifiers)
    for s in _sections { _items[s]?.removeAll { gone.contains($0) } }
  }

  public mutating func deleteAllItems() {
    _sections = []
    _items = [:]
  }

  public mutating func moveItem(_ identifier: ItemIdentifierType, beforeItem toIdentifier: ItemIdentifierType) {
    guard identifier != toIdentifier else { return }
    deleteItems([identifier])
    insertItems([identifier], beforeItem: toIdentifier)
  }

  public mutating func moveItem(_ identifier: ItemIdentifierType, afterItem toIdentifier: ItemIdentifierType) {
    guard identifier != toIdentifier else { return }
    deleteItems([identifier])
    insertItems([identifier], afterItem: toIdentifier)
  }

  public mutating func reloadItems(_ identifiers: [ItemIdentifierType]) {
    _reloadedItems.formUnion(identifiers)
  }

  public mutating func appendSections(_ identifiers: [SectionIdentifierType]) {
    for s in identifiers where !_sections.contains(s) {
      _sections.append(s)
      _items[s] = _items[s] ?? []
    }
  }

  public mutating func insertSections(_ identifiers: [SectionIdentifierType], beforeSection toIdentifier: SectionIdentifierType) {
    guard let i = _sections.firstIndex(of: toIdentifier) else { fatalError("Invalid section identifier specified for insert") }
    _sections.insert(contentsOf: identifiers, at: i)
    for s in identifiers { _items[s] = _items[s] ?? [] }
  }

  public mutating func insertSections(_ identifiers: [SectionIdentifierType], afterSection toIdentifier: SectionIdentifierType) {
    guard let i = _sections.firstIndex(of: toIdentifier) else { fatalError("Invalid section identifier specified for insert") }
    _sections.insert(contentsOf: identifiers, at: i + 1)
    for s in identifiers { _items[s] = _items[s] ?? [] }
  }

  public mutating func deleteSections(_ identifiers: [SectionIdentifierType]) {
    let gone = Set(identifiers)
    _sections.removeAll { gone.contains($0) }
    for s in identifiers { _items[s] = nil }
  }

  public mutating func moveSection(_ identifier: SectionIdentifierType, beforeSection toIdentifier: SectionIdentifierType) {
    guard identifier != toIdentifier, let from = _sections.firstIndex(of: identifier) else { return }
    _sections.remove(at: from)
    _sections.insert(identifier, at: _sections.firstIndex(of: toIdentifier) ?? _sections.endIndex)
  }

  public mutating func moveSection(_ identifier: SectionIdentifierType, afterSection toIdentifier: SectionIdentifierType) {
    guard identifier != toIdentifier, let from = _sections.firstIndex(of: identifier) else { return }
    _sections.remove(at: from)
    let at = _sections.firstIndex(of: toIdentifier).map { $0 + 1 } ?? _sections.endIndex
    _sections.insert(identifier, at: at)
  }

  public mutating func reloadSections(_ identifiers: [SectionIdentifierType]) {
    _reloadedSections.formUnion(identifiers)
  }

  /// The (section, item) at an index path, as the data sources look it up.
  internal func _item(at indexPath: IndexPath) -> ItemIdentifierType? {
    guard indexPath.section >= 0, indexPath.section < _sections.count else { return nil }
    let items = _items[_sections[indexPath.section]] ?? []
    return indexPath.item >= 0 && indexPath.item < items.count ? items[indexPath.item] : nil
  }

  internal func _indexPath(of identifier: ItemIdentifierType) -> IndexPath? {
    for (s, section) in _sections.enumerated() {
      if let i = _items[section]?.firstIndex(of: identifier) { return IndexPath(item: i, section: s) }
    }
    return nil
  }
}

// MARK: - Collection view data source

@available(macOS 10.15.1, *)
open class NSCollectionViewDiffableDataSource<SectionIdentifierType, ItemIdentifierType> : NSObject, NSCollectionViewDataSource where SectionIdentifierType : Hashable, ItemIdentifierType : Hashable {
  public typealias ItemProvider = (NSCollectionView, IndexPath, ItemIdentifierType) -> NSCollectionViewItem?
  public typealias SupplementaryViewProvider = (NSCollectionView, String, IndexPath) -> (any NSView & NSCollectionViewElement)?

  private weak var _collectionView: NSCollectionView?
  private let _itemProvider: ItemProvider
  private var _snapshot = NSDiffableDataSourceSnapshot<SectionIdentifierType, ItemIdentifierType>()
  private var _supplementaryViewProvider: SupplementaryViewProvider?

  public var supplementaryViewProvider: SupplementaryViewProvider? {
    get { _supplementaryViewProvider }
    set { _supplementaryViewProvider = newValue }
  }

  public init(collectionView: NSCollectionView, itemProvider: @escaping ItemProvider) {
    _collectionView = collectionView
    _itemProvider = itemProvider
    super.init()
    collectionView.dataSource = self
  }

  open func apply(_ snapshot: NSDiffableDataSourceSnapshot<SectionIdentifierType, ItemIdentifierType>, animatingDifferences: Bool = true, completion: (() -> Void)? = nil) {
    _snapshot = snapshot
    _snapshot._reloadedItems = []
    _snapshot._reloadedSections = []
    _collectionView?.reloadData()
    completion?()
  }

  open func snapshot() -> NSDiffableDataSourceSnapshot<SectionIdentifierType, ItemIdentifierType> { _snapshot }
  open func itemIdentifier(for indexPath: IndexPath) -> ItemIdentifierType? { _snapshot._item(at: indexPath) }
  open func indexPath(for itemIdentifier: ItemIdentifierType) -> IndexPath? { _snapshot._indexPath(of: itemIdentifier) }

  @objc open func numberOfSections(in collectionView: NSCollectionView) -> Int { _snapshot.numberOfSections }

  @objc open func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
    guard section >= 0, section < _snapshot._sections.count else { return 0 }
    return _snapshot.numberOfItems(inSection: _snapshot._sections[section])
  }

  @objc open func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
    guard let identifier = _snapshot._item(at: indexPath), let item = _itemProvider(collectionView, indexPath, identifier) else {
      fatalError("NSCollectionViewDiffableDataSource: the item provider returned nil for \(indexPath)")
    }
    return item
  }

  @objc open func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind, at indexPath: IndexPath) -> NSView {
    guard let view = _supplementaryViewProvider?(collectionView, kind, indexPath) else {
      fatalError("NSCollectionViewDiffableDataSource: no supplementary view for \(kind) at \(indexPath)")
    }
    return view
  }

  public func description() -> String {
    "<\(type(of: self)): \(_snapshot.numberOfSections) sections, \(_snapshot.numberOfItems) items>"
  }
}

// MARK: - Table view data source

@available(macOS 11.0, *)
open class NSTableViewDiffableDataSource<SectionIdentifierType, ItemIdentifierType> : NSObject, NSTableViewDataSource where SectionIdentifierType : Hashable, ItemIdentifierType : Hashable {
  public typealias CellProvider = (_ tableView: NSTableView, _ tableColumn: NSTableColumn, _ row: Int, _ identifier: ItemIdentifierType) -> NSView
  public typealias SectionHeaderViewProvider = (_ tableView: NSTableView, _ row: Int, _ identifier: SectionIdentifierType) -> NSView
  public typealias RowProvider = (_ tableView: NSTableView, _ row: Int, _ identifier: AnyHashable) -> NSTableRowView

  public var rowViewProvider: RowProvider?
  /// (header rows follow it from the next snapshot applied, as Apple's do)
  public var sectionHeaderViewProvider: SectionHeaderViewProvider?
  private var _headers = false
  public var defaultRowAnimation: NSTableView.AnimationOptions = .effectFade

  private weak var _tableView: NSTableView?
  private let _cellProvider: CellProvider
  private var _snapshot = NSDiffableDataSourceSnapshot<SectionIdentifierType, ItemIdentifierType>()

  public init(tableView: NSTableView, cellProvider: @escaping CellProvider) {
    _tableView = tableView
    _cellProvider = cellProvider
    super.init()
    tableView.dataSource = self
  }

  public func snapshot() -> NSDiffableDataSourceSnapshot<SectionIdentifierType, ItemIdentifierType> { _snapshot }

  public func apply(_ snapshot: NSDiffableDataSourceSnapshot<SectionIdentifierType, ItemIdentifierType>, animatingDifferences: Bool, completion: (() -> Void)? = nil) {
    _snapshot = snapshot
    _headers = sectionHeaderViewProvider != nil
    _tableView?.reloadData()
    completion?()
  }

  /// Rows, in order: a header row for each section when there's a header provider,
  /// then the section's items.
  private enum Row { case section(SectionIdentifierType), item(ItemIdentifierType) }

  private var _rows: [Row] {
    var rows: [Row] = []
    for s in _snapshot._sections {
      if _headers { rows.append(.section(s)) }
      rows.append(contentsOf: (_snapshot._items[s] ?? []).map { .item($0) })
    }
    return rows
  }

  public func itemIdentifier(forRow row: Int) -> ItemIdentifierType? {
    let rows = _rows
    guard row >= 0, row < rows.count, case let .item(i) = rows[row] else { return nil }
    return i
  }

  public func row(forItemIdentifier identifier: ItemIdentifierType) -> Int? {
    _rows.firstIndex { if case let .item(i) = $0 { return i == identifier }; return false }
  }

  public func sectionIdentifier(forRow row: Int) -> SectionIdentifierType? {
    let rows = _rows
    guard row >= 0, row < rows.count, case let .section(s) = rows[row] else { return nil }
    return s
  }

  public func row(forSectionIdentifier identifier: SectionIdentifierType) -> Int? {
    _rows.firstIndex { if case let .section(s) = $0 { return s == identifier }; return false }
  }

  @objc public func numberOfRows(in tableView: NSTableView) -> Int { _rows.count }

  /// (the table asks its data source for views when its delegate doesn't make them; NSTableView.m)
  @objc(tableView:viewForTableColumn:row:)
  public func _finchTableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let rows = _rows
    guard row >= 0, row < rows.count else { return nil }
    switch rows[row] {
    case let .section(s): return sectionHeaderViewProvider?(tableView, row, s)
    case let .item(i):
      guard let column = tableColumn ?? tableView.tableColumns.first else { return nil }
      return _cellProvider(tableView, column, row, i)
    }
  }

  @objc(tableView:rowViewForRow:)
  public func _finchTableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    let rows = _rows
    guard let provider = rowViewProvider, row >= 0, row < rows.count else { return nil }
    switch rows[row] {
    case let .section(s): return provider(tableView, row, AnyHashable(s))
    case let .item(i): return provider(tableView, row, AnyHashable(i))
    }
  }

  @objc(tableView:isGroupRow:)
  public func _finchTableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
    sectionIdentifier(forRow: row) != nil
  }
}

// MARK: - Text suggestions

@available(macOS 15.0, *)
public struct NSSuggestionItem<SuggestionItemType> {
  public var representedValue: SuggestionItemType
  private var _title: AttributedString
  private var _secondaryTitle: AttributedString?
  public var title: String {
    get { String(_title.characters) }
    set { _title = AttributedString(newValue) }
  }
  public var attributedTitle: AttributedString {
    get { _title }
    set { _title = newValue }
  }
  public var secondaryTitle: String? {
    get { _secondaryTitle.map { String($0.characters) } }
    set { _secondaryTitle = newValue.map { AttributedString($0) } }
  }
  public var attributedSecondaryTitle: AttributedString? {
    get { _secondaryTitle }
    set { _secondaryTitle = newValue }
  }
  public var toolTip: String?
  public var image: NSImage?

  public init(representedValue: SuggestionItemType, title: String) {
    self.representedValue = representedValue
    _title = AttributedString(title)
  }

  public init(representedValue: SuggestionItemType, attributedTitle: AttributedString) {
    self.representedValue = representedValue
    _title = attributedTitle
  }
}

@available(macOS 15.0, *)
extension NSSuggestionItem : Equatable where SuggestionItemType : Equatable {
  public static func == (lhs: NSSuggestionItem<SuggestionItemType>, rhs: NSSuggestionItem<SuggestionItemType>) -> Bool {
    lhs.representedValue == rhs.representedValue && lhs._title == rhs._title && lhs._secondaryTitle == rhs._secondaryTitle
      && lhs.toolTip == rhs.toolTip && lhs.image === rhs.image
  }
}

@available(macOS 15.0, *)
extension NSSuggestionItem : Hashable where SuggestionItemType : Hashable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(representedValue)
    hasher.combine(title)
  }
}

@available(macOS 15.0, *)
public struct NSSuggestionItemResponse<SuggestionItemType> {
  public typealias Item = NSSuggestionItem<SuggestionItemType>
  public typealias ItemSection = NSSuggestionItemSection<SuggestionItemType>
  public var itemSections: [ItemSection]
  public enum Phase : Equatable, Hashable {
    case intermediate
    case final
  }
  public var phase: Phase = .final
  public enum Highlight : Equatable, Hashable {
    case automatic
    case firstSelectableItem
  }
  public var preferredHighlight: Highlight = .automatic

  public init(itemSections: [ItemSection]) { self.itemSections = itemSections }
  public init(items: [Item]) { self.itemSections = [ItemSection(items: items)] }
  public init() { self.itemSections = [] }
}

@available(macOS 15.0, *)
extension NSSuggestionItemResponse : Equatable where SuggestionItemType : Equatable {
  public static func == (a: NSSuggestionItemResponse<SuggestionItemType>, b: NSSuggestionItemResponse<SuggestionItemType>) -> Bool {
    a.itemSections == b.itemSections && a.phase == b.phase && a.preferredHighlight == b.preferredHighlight
  }
}

@available(macOS 15.0, *)
extension NSSuggestionItemResponse : Hashable where SuggestionItemType : Hashable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(itemSections)
    hasher.combine(phase)
  }
}

@available(macOS 15.0, *)
public struct NSSuggestionItemSection<SuggestionItemType> {
  public typealias Item = NSSuggestionItem<SuggestionItemType>
  public var title: String?
  public var items: [Item]
  public init(title: String?, items: [Item]) {
    self.title = title
    self.items = items
  }
  public init(items: [Item]) { self.init(title: nil, items: items) }
}

@available(macOS 15.0, *)
extension NSSuggestionItemSection : Equatable where SuggestionItemType : Equatable {
  public static func == (a: NSSuggestionItemSection<SuggestionItemType>, b: NSSuggestionItemSection<SuggestionItemType>) -> Bool {
    a.title == b.title && a.items == b.items
  }
}

@available(macOS 15.0, *)
extension NSSuggestionItemSection : Hashable where SuggestionItemType : Hashable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(title)
    hasher.combine(items)
  }
}

@available(macOS 15.0, *)
@MainActor public protocol NSTextSuggestionsDelegate<SuggestionItemType> : AnyObject {
  associatedtype SuggestionItemType
  typealias Item = NSSuggestionItem<Self.SuggestionItemType>
  typealias ItemSection = NSSuggestionItemSection<Self.SuggestionItemType>
  typealias ItemResponse = NSSuggestionItemResponse<Self.SuggestionItemType>
  func textField(_ textField: NSTextField, provideUpdatedSuggestions responseHandler: @escaping (Self.ItemResponse) -> Void)
  func textField(_ textField: NSTextField, textCompletionFor item: Self.Item) -> String?
  func textField(_ textField: NSTextField, didSelect item: Self.Item)
}

extension NSTextSuggestionsDelegate {
  @available(macOS 15.0, *)
  public func textField(_ textField: NSTextField, textCompletionFor item: Self.Item) -> String? { item.title }
  @available(macOS 15.0, *)
  public func textField(_ textField: NSTextField, didSelect item: Self.Item) {}
}

/// (each text field's suggestions delegate, held weakly beside it)
private final class _FinchWeakSuggestionsDelegate {
  weak var delegate: (any NSTextSuggestionsDelegate)?
  init(_ d: (any NSTextSuggestionsDelegate)?) { delegate = d }
}

nonisolated(unsafe) private var _suggestionsDelegateKey: UInt8 = 0

extension NSTextField {
  @available(macOS 15.0, *)
  @MainActor @preconcurrency weak public var suggestionsDelegate: (any NSTextSuggestionsDelegate)? {
    get { (objc_getAssociatedObject(self, &_suggestionsDelegateKey) as? _FinchWeakSuggestionsDelegate)?.delegate }
    set { objc_setAssociatedObject(self, &_suggestionsDelegateKey, _FinchWeakSuggestionsDelegate(newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
  }
}

// MARK: - @NSView.Invalidating

@available(macOS 12, *)
public protocol NSViewInvalidating {
  func invalidate(view: NSView)
}

extension NSView {
  @available(macOS 12, *)
  @propertyWrapper public struct Invalidating<Value, InvalidationType> where Value : Equatable, InvalidationType : NSViewInvalidating {
    private var _value: Value
    private let _invalidation: InvalidationType

    @available(*, unavailable, message: "@NSView.Invalidating can only be used on subclasses of NSView")
    public var wrappedValue: Value {
      get { fatalError() }
      set { fatalError() }
    }

    public init(wrappedValue: Value, _ invalidation: InvalidationType) {
      _value = wrappedValue
      _invalidation = invalidation
    }

    public init<InvalidationType1, InvalidationType2>(wrappedValue: Value, _ invalidation1: InvalidationType1, _ invalidation2: InvalidationType2) where InvalidationType == NSView.Invalidations.Tuple<InvalidationType1, InvalidationType2>, InvalidationType1 : NSViewInvalidating, InvalidationType2 : NSViewInvalidating {
      self.init(wrappedValue: wrappedValue, NSView.Invalidations.Tuple(invalidation1, invalidation2))
    }

    public init<InvalidationType1, InvalidationType2, InvalidationType3>(wrappedValue: Value, _ invalidation1: InvalidationType1, _ invalidation2: InvalidationType2, _ invalidation3: InvalidationType3) where InvalidationType == NSView.Invalidations.Tuple<NSView.Invalidations.Tuple<InvalidationType1, InvalidationType2>, InvalidationType3>, InvalidationType1 : NSViewInvalidating, InvalidationType2 : NSViewInvalidating, InvalidationType3 : NSViewInvalidating {
      self.init(wrappedValue: wrappedValue, NSView.Invalidations.Tuple(NSView.Invalidations.Tuple(invalidation1, invalidation2), invalidation3))
    }

    public init<InvalidationType1, InvalidationType2, InvalidationType3, InvalidationType4>(wrappedValue: Value, _ invalidation1: InvalidationType1, _ invalidation2: InvalidationType2, _ invalidation3: InvalidationType3, _ invalidation4: InvalidationType4) where InvalidationType == NSView.Invalidations.Tuple<NSView.Invalidations.Tuple<InvalidationType1, InvalidationType2>, NSView.Invalidations.Tuple<InvalidationType3, InvalidationType4>>, InvalidationType1 : NSViewInvalidating, InvalidationType2 : NSViewInvalidating, InvalidationType3 : NSViewInvalidating, InvalidationType4 : NSViewInvalidating {
      self.init(wrappedValue: wrappedValue, NSView.Invalidations.Tuple(NSView.Invalidations.Tuple(invalidation1, invalidation2), NSView.Invalidations.Tuple(invalidation3, invalidation4)))
    }

    public init<InvalidationType1, InvalidationType2, InvalidationType3, InvalidationType4, InvalidationType5>(wrappedValue: Value, _ invalidation1: InvalidationType1, _ invalidation2: InvalidationType2, _ invalidation3: InvalidationType3, _ invalidation4: InvalidationType4, _ invalidation5: InvalidationType5) where InvalidationType == NSView.Invalidations.Tuple<NSView.Invalidations.Tuple<NSView.Invalidations.Tuple<InvalidationType1, InvalidationType2>, NSView.Invalidations.Tuple<InvalidationType3, InvalidationType4>>, InvalidationType5>, InvalidationType1 : NSViewInvalidating, InvalidationType2 : NSViewInvalidating, InvalidationType3 : NSViewInvalidating, InvalidationType4 : NSViewInvalidating, InvalidationType5 : NSViewInvalidating {
      self.init(wrappedValue: wrappedValue, NSView.Invalidations.Tuple(NSView.Invalidations.Tuple(NSView.Invalidations.Tuple(invalidation1, invalidation2), NSView.Invalidations.Tuple(invalidation3, invalidation4)), invalidation5))
    }

    public init<InvalidationType1, InvalidationType2, InvalidationType3, InvalidationType4, InvalidationType5, InvalidationType6>(wrappedValue: Value, _ invalidation1: InvalidationType1, _ invalidation2: InvalidationType2, _ invalidation3: InvalidationType3, _ invalidation4: InvalidationType4, _ invalidation5: InvalidationType5, _ invalidation6: InvalidationType6) where InvalidationType == NSView.Invalidations.Tuple<NSView.Invalidations.Tuple<NSView.Invalidations.Tuple<InvalidationType1, InvalidationType2>, NSView.Invalidations.Tuple<InvalidationType3, InvalidationType4>>, NSView.Invalidations.Tuple<InvalidationType5, InvalidationType6>>, InvalidationType1 : NSViewInvalidating, InvalidationType2 : NSViewInvalidating, InvalidationType3 : NSViewInvalidating, InvalidationType4 : NSViewInvalidating, InvalidationType5 : NSViewInvalidating, InvalidationType6 : NSViewInvalidating {
      self.init(wrappedValue: wrappedValue, NSView.Invalidations.Tuple(NSView.Invalidations.Tuple(NSView.Invalidations.Tuple(invalidation1, invalidation2), NSView.Invalidations.Tuple(invalidation3, invalidation4)), NSView.Invalidations.Tuple(invalidation5, invalidation6)))
    }

    public init<InvalidationType1, InvalidationType2, InvalidationType3, InvalidationType4, InvalidationType5, InvalidationType6, InvalidationType7>(wrappedValue: Value, _ invalidation1: InvalidationType1, _ invalidation2: InvalidationType2, _ invalidation3: InvalidationType3, _ invalidation4: InvalidationType4, _ invalidation5: InvalidationType5, _ invalidation6: InvalidationType6, _ invalidation7: InvalidationType7) where InvalidationType == NSView.Invalidations.Tuple<NSView.Invalidations.Tuple<NSView.Invalidations.Tuple<InvalidationType1, InvalidationType2>, NSView.Invalidations.Tuple<InvalidationType3, InvalidationType4>>, NSView.Invalidations.Tuple<NSView.Invalidations.Tuple<InvalidationType5, InvalidationType6>, InvalidationType7>>, InvalidationType1 : NSViewInvalidating, InvalidationType2 : NSViewInvalidating, InvalidationType3 : NSViewInvalidating, InvalidationType4 : NSViewInvalidating, InvalidationType5 : NSViewInvalidating, InvalidationType6 : NSViewInvalidating, InvalidationType7 : NSViewInvalidating {
      self.init(wrappedValue: wrappedValue, NSView.Invalidations.Tuple(NSView.Invalidations.Tuple(NSView.Invalidations.Tuple(invalidation1, invalidation2), NSView.Invalidations.Tuple(invalidation3, invalidation4)), NSView.Invalidations.Tuple(NSView.Invalidations.Tuple(invalidation5, invalidation6), invalidation7)))
    }

    public init<InvalidationType1, InvalidationType2, InvalidationType3, InvalidationType4, InvalidationType5, InvalidationType6, InvalidationType7, InvalidationType8>(wrappedValue: Value, _ invalidation1: InvalidationType1, _ invalidation2: InvalidationType2, _ invalidation3: InvalidationType3, _ invalidation4: InvalidationType4, _ invalidation5: InvalidationType5, _ invalidation6: InvalidationType6, _ invalidation7: InvalidationType7, _ invalidation8: InvalidationType8) where InvalidationType == NSView.Invalidations.Tuple<NSView.Invalidations.Tuple<NSView.Invalidations.Tuple<InvalidationType1, InvalidationType2>, NSView.Invalidations.Tuple<InvalidationType3, InvalidationType4>>, NSView.Invalidations.Tuple<NSView.Invalidations.Tuple<InvalidationType5, InvalidationType6>, NSView.Invalidations.Tuple<InvalidationType7, InvalidationType8>>>, InvalidationType1 : NSViewInvalidating, InvalidationType2 : NSViewInvalidating, InvalidationType3 : NSViewInvalidating, InvalidationType4 : NSViewInvalidating, InvalidationType5 : NSViewInvalidating, InvalidationType6 : NSViewInvalidating, InvalidationType7 : NSViewInvalidating, InvalidationType8 : NSViewInvalidating {
      self.init(wrappedValue: wrappedValue, NSView.Invalidations.Tuple(NSView.Invalidations.Tuple(NSView.Invalidations.Tuple(invalidation1, invalidation2), NSView.Invalidations.Tuple(invalidation3, invalidation4)), NSView.Invalidations.Tuple(NSView.Invalidations.Tuple(invalidation5, invalidation6), NSView.Invalidations.Tuple(invalidation7, invalidation8))))
    }

    public init<InvalidationType1, InvalidationType2, InvalidationType3, InvalidationType4, InvalidationType5, InvalidationType6, InvalidationType7, InvalidationType8, InvalidationType9>(wrappedValue: Value, _ invalidation1: InvalidationType1, _ invalidation2: InvalidationType2, _ invalidation3: InvalidationType3, _ invalidation4: InvalidationType4, _ invalidation5: InvalidationType5, _ invalidation6: InvalidationType6, _ invalidation7: InvalidationType7, _ invalidation8: InvalidationType8, _ invalidation9: InvalidationType9) where InvalidationType == NSView.Invalidations.Tuple<NSView.Invalidations.Tuple<NSView.Invalidations.Tuple<NSView.Invalidations.Tuple<InvalidationType1, InvalidationType2>, NSView.Invalidations.Tuple<InvalidationType3, InvalidationType4>>, NSView.Invalidations.Tuple<NSView.Invalidations.Tuple<InvalidationType5, InvalidationType6>, NSView.Invalidations.Tuple<InvalidationType7, InvalidationType8>>>, InvalidationType9>, InvalidationType1 : NSViewInvalidating, InvalidationType2 : NSViewInvalidating, InvalidationType3 : NSViewInvalidating, InvalidationType4 : NSViewInvalidating, InvalidationType5 : NSViewInvalidating, InvalidationType6 : NSViewInvalidating, InvalidationType7 : NSViewInvalidating, InvalidationType8 : NSViewInvalidating, InvalidationType9 : NSViewInvalidating {
      self.init(wrappedValue: wrappedValue, NSView.Invalidations.Tuple(NSView.Invalidations.Tuple(NSView.Invalidations.Tuple(NSView.Invalidations.Tuple(invalidation1, invalidation2), NSView.Invalidations.Tuple(invalidation3, invalidation4)), NSView.Invalidations.Tuple(NSView.Invalidations.Tuple(invalidation5, invalidation6), NSView.Invalidations.Tuple(invalidation7, invalidation8))), invalidation9))
    }

    public init<InvalidationType1, InvalidationType2, InvalidationType3, InvalidationType4, InvalidationType5, InvalidationType6, InvalidationType7, InvalidationType8, InvalidationType9, InvalidationType10>(wrappedValue: Value, _ invalidation1: InvalidationType1, _ invalidation2: InvalidationType2, _ invalidation3: InvalidationType3, _ invalidation4: InvalidationType4, _ invalidation5: InvalidationType5, _ invalidation6: InvalidationType6, _ invalidation7: InvalidationType7, _ invalidation8: InvalidationType8, _ invalidation9: InvalidationType9, _ invalidation10: InvalidationType10) where InvalidationType == NSView.Invalidations.Tuple<NSView.Invalidations.Tuple<NSView.Invalidations.Tuple<NSView.Invalidations.Tuple<InvalidationType1, InvalidationType2>, NSView.Invalidations.Tuple<InvalidationType3, InvalidationType4>>, NSView.Invalidations.Tuple<NSView.Invalidations.Tuple<InvalidationType5, InvalidationType6>, NSView.Invalidations.Tuple<InvalidationType7, InvalidationType8>>>, NSView.Invalidations.Tuple<InvalidationType9, InvalidationType10>>, InvalidationType1 : NSViewInvalidating, InvalidationType2 : NSViewInvalidating, InvalidationType3 : NSViewInvalidating, InvalidationType4 : NSViewInvalidating, InvalidationType5 : NSViewInvalidating, InvalidationType6 : NSViewInvalidating, InvalidationType7 : NSViewInvalidating, InvalidationType8 : NSViewInvalidating, InvalidationType9 : NSViewInvalidating, InvalidationType10 : NSViewInvalidating {
      self.init(wrappedValue: wrappedValue, NSView.Invalidations.Tuple(NSView.Invalidations.Tuple(NSView.Invalidations.Tuple(NSView.Invalidations.Tuple(invalidation1, invalidation2), NSView.Invalidations.Tuple(invalidation3, invalidation4)), NSView.Invalidations.Tuple(NSView.Invalidations.Tuple(invalidation5, invalidation6), NSView.Invalidations.Tuple(invalidation7, invalidation8))), NSView.Invalidations.Tuple(invalidation9, invalidation10)))
    }

    public static subscript<EnclosingSelf>(_enclosingInstance observed: EnclosingSelf, wrapped wrappedKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Value>, storage storageKeyPath: ReferenceWritableKeyPath<EnclosingSelf, NSView.Invalidating<Value, InvalidationType>>) -> Value where EnclosingSelf : NSView {
      get { observed[keyPath: storageKeyPath]._value }
      set {
        let old = observed[keyPath: storageKeyPath]._value
        observed[keyPath: storageKeyPath]._value = newValue
        if old != newValue { observed[keyPath: storageKeyPath]._invalidation.invalidate(view: observed) }
      }
    }
  }
}

@available(macOS 12, *)
extension NSViewInvalidating where Self == NSView.Invalidations.Display {
  @_alwaysEmitIntoClient public static var display: NSView.Invalidations.Display { .init() }
}

@available(macOS 12, *)
extension NSViewInvalidating where Self == NSView.Invalidations.Layout {
  @_alwaysEmitIntoClient public static var layout: NSView.Invalidations.Layout { .init() }
}

@available(macOS 12, *)
extension NSViewInvalidating where Self == NSView.Invalidations.Constraints {
  @_alwaysEmitIntoClient public static var constraints: NSView.Invalidations.Constraints { .init() }
}

@available(macOS 12, *)
extension NSViewInvalidating where Self == NSView.Invalidations.IntrinsicContentSize {
  @_alwaysEmitIntoClient public static var intrinsicContentSize: NSView.Invalidations.IntrinsicContentSize { .init() }
}

@available(macOS 12, *)
extension NSViewInvalidating where Self == NSView.Invalidations.RestorableState {
  @_alwaysEmitIntoClient public static var restorableState: NSView.Invalidations.RestorableState { .init() }
}

extension NSView {
  @available(macOS 12, *)
  public enum Invalidations {
    public struct Display : NSViewInvalidating {
      public init() {}
      public func invalidate(view: NSView) { view.needsDisplay = true }
    }
    public struct Layout : NSViewInvalidating {
      public init() {}
      public func invalidate(view: NSView) { view.needsLayout = true }
    }
    public struct Constraints : NSViewInvalidating {
      public init() {}
      public func invalidate(view: NSView) { view.needsUpdateConstraints = true }
    }
    public struct IntrinsicContentSize : NSViewInvalidating {
      public init() {}
      public func invalidate(view: NSView) { view.invalidateIntrinsicContentSize() }
    }
    public struct RestorableState : NSViewInvalidating {
      public init() {}
      public func invalidate(view: NSView) { view.invalidateRestorableState() }
    }
    public struct Tuple<Invalidation1, Invalidation2> : NSViewInvalidating where Invalidation1 : NSViewInvalidating, Invalidation2 : NSViewInvalidating {
      private let _first: Invalidation1
      private let _second: Invalidation2
      public init(_ invalidation1: Invalidation1, _ invalidation2: Invalidation2) {
        _first = invalidation1
        _second = invalidation2
      }
      public func invalidate(view: NSView) {
        _first.invalidate(view: view)
        _second.invalidate(view: view)
      }
    }
  }
}

// MARK: - Cursors, menu items, pop-up buttons, bezels

@_silgen_name("FinchAppKitSwiftColumnResizeCursor")
private func _finchColumnResizeCursor(_ directions: UInt) -> AnyObject
@_silgen_name("FinchAppKitSwiftRowResizeCursor")
private func _finchRowResizeCursor(_ directions: UInt) -> AnyObject

@available(macOS 15.0, *)
extension NSCursor {
  public class func columnResize(directions: NSHorizontalDirection.Set) -> NSCursor {
    _finchColumnResizeCursor(UInt(directions.rawValue)) as! NSCursor
  }

  public class func rowResize(directions: NSVerticalDirection.Set) -> NSCursor {
    _finchRowResizeCursor(UInt(directions.rawValue)) as! NSCursor
  }

  public enum FrameResizeDirection : Int8, CaseIterable {
    case inward
    case outward
    public struct Set : OptionSet, Equatable, Hashable {
      public typealias Element = NSCursor.FrameResizeDirection.Set
      public typealias RawValue = Int8
      public let rawValue: Int8
      public init(rawValue: Int8) { self.rawValue = rawValue }
      /// (bit 0 is left unused, as Apple's leaves it)
      public static let inward = Set(rawValue: 1 << 1)
      public static let outward = Set(rawValue: 1 << 2)
      public static let all: Set = [.inward, .outward]
      public init(_ direction: NSCursor.FrameResizeDirection) { self.init(rawValue: 1 << (direction.rawValue + 1)) }
    }
  }

  /// (the window server draws the arrows Finch has: the resize cursors by axis)
  public class func frameResize(position: NSCursor.FrameResizePosition, directions: NSCursor.FrameResizeDirection.Set) -> NSCursor {
    let horizontal = position == .left || position == .right
    let vertical = position == .top || position == .bottom
    if horizontal { return .resizeLeftRight }
    if vertical { return .resizeUpDown }
    return .crosshair
  }
}

@available(macOS 14.0, *)
extension NSMenuItem {
  @available(*, deprecated, renamed: "sectionHeader(title:)", message: "Use sectionHeader(title:) instead.")
  public static func sectionHeader(withTitle title: String) -> NSMenuItem { sectionHeader(title: title) }
}

extension NSPopUpButton {
  @available(macOS 10.10, *)
  @MainActor @preconcurrency convenience public init(title: String, image: NSImage? = nil, pullDownMenu: NSMenu) {
    self.init(frame: .zero, pullsDown: true)
    _finchConfigurePullDown(title: title, image: image, pullDownMenu: pullDownMenu)
    sizeToFit()
  }

  @available(macOS 10.10, *)
  @MainActor @preconcurrency convenience public init(image: NSImage, pullDownMenu: NSMenu) {
    self.init(frame: .zero, pullsDown: true)
    _finchConfigurePullDown(title: nil, image: image, pullDownMenu: pullDownMenu)
    sizeToFit()
  }

  @MainActor private func _finchConfigurePullDown(title: String?, image: NSImage?, pullDownMenu: NSMenu) {
    pullsDown = true
    bezelStyle = .automatic
    imagePosition = image == nil ? .noImage : (title == nil ? .imageOnly : .imageLeading)
    imageScaling = .scaleProportionallyDown
    menu = pullDownMenu
    if pullDownMenu.numberOfItems > 0 { pullDownMenu.item(at: 0)?.isHidden = false }
    let display = NSMenuItem()
    display.title = title ?? ""
    display.image = image
    (cell as? NSPopUpButtonCell)?.usesItemFromMenu = false
    (cell as? NSPopUpButtonCell)?.menuItem = display
  }
}

extension NSButton.BezelStyle {
  /// (macOS 26's glass bezels; Fieldwork draws them as its own buttons)
  public static var _glass: NSButton.BezelStyle { NSButton.BezelStyle(rawValue: 16)! }
  public static var _clearGlass: NSButton.BezelStyle { NSButton.BezelStyle(rawValue: 30)! }
}

// MARK: - Storyboards

extension NSStoryboard {
  @available(macOS 10.15, *)
  public func instantiateInitialController<Controller>(creator: ((NSCoder) -> Controller?)? = nil) -> Controller? where Controller : NSViewController {
    instantiateInitialController() as? Controller
  }

  @available(macOS 10.15, *)
  public func instantiateInitialController<Controller>(creator: ((NSCoder) -> Controller?)? = nil) -> Controller? where Controller : NSWindowController {
    instantiateInitialController() as? Controller
  }

  /// (the creator isn't called yet: controllers come from the storyboard as it describes them)
  @available(macOS 10.15, *)
  public func instantiateController<Controller>(identifier: NSStoryboard.SceneIdentifier, creator: ((NSCoder) -> Controller?)? = nil) -> Controller where Controller : NSViewController {
    guard let c = instantiateController(withIdentifier: identifier) as? Controller else {
      fatalError("NSStoryboard: no \(Controller.self) for identifier \(identifier)")
    }
    return c
  }

  @available(macOS 10.15, *)
  public func instantiateController<Controller>(identifier: NSStoryboard.SceneIdentifier, creator: ((NSCoder) -> Controller?)? = nil) -> Controller where Controller : NSWindowController {
    guard let c = instantiateController(withIdentifier: identifier) as? Controller else {
      fatalError("NSStoryboard: no \(Controller.self) for identifier \(identifier)")
    }
    return c
  }
}

// MARK: - High dynamic range notifications

extension NSApplication {
  @available(macOS 26.0, *)
  public struct ShouldBeginSuppressingHighDynamicRangeContent {
    public static var name: Notification.Name { Notification.Name("NSApplicationShouldBeginSuppressingHighDynamicRangeContentNotification") }
    public typealias Subject = NSApplication
  }

  @available(macOS 26.0, *)
  public struct ShouldEndSuppressingHighDynamicRangeContent {
    public static var name: Notification.Name { Notification.Name("NSApplicationShouldEndSuppressingHighDynamicRangeContentNotification") }
    public typealias Subject = NSApplication
  }
}

// MARK: - The AppKit attribute scope

@available(macOS 12, *)
extension AttributeScopes {
  public var appKit: AttributeScopes.AppKitAttributes.Type { AppKitAttributes.self }

  /// (the keys with plain values; those that need AppKit's own coding are still to come)
  public struct AppKitAttributes : AttributeScope {
    public let font: FontAttribute
    public let paragraphStyle: ParagraphStyleAttribute
    public let foregroundColor: ForegroundColorAttribute
    public let backgroundColor: BackgroundColorAttribute
    public let ligature: LigatureAttribute
    public let kern: KernAttribute
    public let tracking: TrackingAttribute
    public let strikethroughStyle: StrikethroughStyleAttribute
    public let underlineStyle: UnderlineStyleAttribute
    public let strokeColor: StrokeColorAttribute
    public let strokeWidth: StrokeWidthAttribute
    public let shadow: ShadowAttribute
    public let textEffect: TextEffectAttribute
    public let attachment: AttachmentAttribute
    public let baselineOffset: BaselineOffsetAttribute
    public let underlineColor: UnderlineColorAttribute
    public let strikethroughColor: StrikethroughColorAttribute
    public let obliqueness: ObliquenessAttribute
    public let expansion: ExpansionAttribute
    public let toolTip: ToolTipAttribute
    public let markedClauseSegment: MarkedClauseSegmentAttribute
    public let superscript: SuperscriptAttribute
    public let textAlternatives: TextAlternativesAttribute
    public let glyphInfo: GlyphInfoAttribute
    public let cursor: CursorAttribute
    public let foundation: AttributeScopes.FoundationAttributes
  }
}

@available(macOS 12, *)
extension AttributeDynamicLookup {
  @_disfavoredOverload public subscript<T>(dynamicMember keyPath: KeyPath<AttributeScopes.AppKitAttributes, T>) -> T where T : AttributedStringKey {
    self[T.self]
  }
}

@available(macOS 12, *)
extension AttributeScopes.AppKitAttributes {
  @frozen public enum FontAttribute : AttributedStringKey {
    public typealias Value = NSFont
    public static let name = "NSFont"
  }
  @frozen public enum ParagraphStyleAttribute : AttributedStringKey {
    public typealias Value = NSParagraphStyle
    public static let name = "NSParagraphStyle"
  }
  @frozen public enum ForegroundColorAttribute : AttributedStringKey {
    public typealias Value = NSColor
    public static let name = "NSColor"
  }
  @frozen public enum BackgroundColorAttribute : AttributedStringKey {
    public typealias Value = NSColor
    public static let name = "NSBackgroundColor"
  }
  @frozen public enum LigatureAttribute : AttributedStringKey {
    public typealias Value = Int
    public static let name = "NSLigature"
  }
  @frozen public enum KernAttribute : AttributedStringKey {
    public typealias Value = CGFloat
    public static let name = "NSKern"
  }
  @frozen public enum TrackingAttribute : AttributedStringKey {
    public typealias Value = CGFloat
    public static let name = "NSTracking"
  }
  @frozen public enum StrikethroughStyleAttribute : CodableAttributedStringKey, ObjectiveCConvertibleAttributedStringKey {
    public typealias Value = NSUnderlineStyle
    public typealias ObjectiveCValue = NSNumber
    public static let name = "NSStrikethrough"
    public static func encode(_ value: NSUnderlineStyle, to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      try container.encode(value.rawValue)
    }
    public static func decode(from decoder: Decoder) throws -> NSUnderlineStyle {
      let container = try decoder.singleValueContainer()
      return NSUnderlineStyle(rawValue: try container.decode(Int.self))
    }
    public static func objectiveCValue(for value: NSUnderlineStyle) throws -> NSNumber {
      NSNumber(value: value.rawValue)
    }
    public static func value(for object: NSNumber) throws -> NSUnderlineStyle {
      NSUnderlineStyle(rawValue: object.intValue)
    }
  }
  @frozen public enum UnderlineStyleAttribute : CodableAttributedStringKey, ObjectiveCConvertibleAttributedStringKey {
    public typealias Value = NSUnderlineStyle
    public typealias ObjectiveCValue = NSNumber
    public static let name = "NSUnderline"
    public static func encode(_ value: NSUnderlineStyle, to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      try container.encode(value.rawValue)
    }
    public static func decode(from decoder: Decoder) throws -> NSUnderlineStyle {
      let container = try decoder.singleValueContainer()
      return NSUnderlineStyle(rawValue: try container.decode(Int.self))
    }
    public static func objectiveCValue(for value: NSUnderlineStyle) throws -> NSNumber {
      NSNumber(value: value.rawValue)
    }
    public static func value(for object: NSNumber) throws -> NSUnderlineStyle {
      NSUnderlineStyle(rawValue: object.intValue)
    }
  }
  @frozen public enum StrokeColorAttribute : AttributedStringKey {
    public typealias Value = NSColor
    public static let name = "NSStrokeColor"
  }
  @frozen public enum StrokeWidthAttribute : AttributedStringKey {
    public typealias Value = CGFloat
    public static let name = "NSStrokeWidth"
  }
  @frozen public enum ShadowAttribute : AttributedStringKey {
    public typealias Value = NSShadow
    public static let name = "NSShadow"
  }
  @frozen public enum TextEffectAttribute : CodableAttributedStringKey {
    public typealias Value = NSAttributedString.TextEffectStyle
    public static let name = "NSTextEffect"
    public static func encode(_ value: NSAttributedString.TextEffectStyle, to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      try container.encode(value.rawValue)
    }
    public static func decode(from decoder: Decoder) throws -> NSAttributedString.TextEffectStyle {
      let container = try decoder.singleValueContainer()
      return NSAttributedString.TextEffectStyle(rawValue: try container.decode(String.self))
    }
  }
  @frozen public enum AttachmentAttribute : AttributedStringKey {
    public typealias Value = NSTextAttachment
    public static let name = "NSAttachment"
  }
  @frozen public enum BaselineOffsetAttribute : AttributedStringKey {
    public typealias Value = CGFloat
    public static let name = "NSBaselineOffset"
  }
  @frozen public enum UnderlineColorAttribute : AttributedStringKey {
    public typealias Value = NSColor
    public static let name = "NSUnderlineColor"
  }
  @frozen public enum StrikethroughColorAttribute : AttributedStringKey {
    public typealias Value = NSColor
    public static let name = "NSStrikethroughColor"
  }
  @frozen public enum ObliquenessAttribute : CodableAttributedStringKey {
    public typealias Value = CGFloat
    public static let name = "NSObliqueness"
  }
  @frozen public enum ExpansionAttribute : CodableAttributedStringKey {
    public typealias Value = CGFloat
    public static let name = "NSExpansion"
  }
  @frozen public enum ToolTipAttribute : AttributedStringKey {
    public typealias Value = String
    public static let name = "NSToolTip"
  }
  @frozen public enum SuperscriptAttribute : AttributedStringKey {
    public typealias Value = Int
    public static let name = "NSSuperScript"
  }
  @frozen public enum MarkedClauseSegmentAttribute : CodableAttributedStringKey {
    public typealias Value = Int
    public static let name = "NSMarkedClauseSegment"
  }
  @frozen public enum TextAlternativesAttribute : CodableAttributedStringKey {
    public typealias Value = NSTextAlternatives
    public static let name = "NSTextAlternatives"
  }
  @frozen public enum GlyphInfoAttribute : CodableAttributedStringKey {
    public typealias Value = NSGlyphInfo
    public static let name = "NSGlyphInfo"
  }
  @frozen public enum CursorAttribute : AttributedStringKey {
    public typealias Value = NSCursor
    public static let name = "NSCursor"
  }
}

@available(macOS 12, *)
extension NSUnderlineStyle: Hashable {}
