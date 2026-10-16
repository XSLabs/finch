// SPDX-License-Identifier: MIT OR Apache-2.0
// The newer half of AppKit's Swift overlay: diffable data source snapshots and the
// collection and table view data sources, text suggestions, @NSView.Invalidating,
// frame-resize cursor directions, menu section headers, pull-down pop-up buttons and
// the AppKit attribute scope; compared with Apple's.
import AppKit

final class Watched: NSView {
  var layouts = 0
  var displays = 0
  @NSView.Invalidating(.layout) var size: CGFloat = 1
  @NSView.Invalidating(.layout, .display) var color: Int = 0
  override var needsLayout: Bool {
    didSet { if needsLayout { layouts += 1 } }
  }
  override var needsDisplay: Bool {
    didSet { if needsDisplay { displays += 1 } }
  }
}

final class Item: NSCollectionViewItem {
  override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10)) }
}

@main
struct Main {
  @MainActor static func main() {
    _ = NSApplication.shared

    // snapshots
    var s = NSDiffableDataSourceSnapshot<String, Int>()
    s.appendSections(["a", "b"])
    s.appendItems([1, 2, 3], toSection: "a")
    s.appendItems([4, 5])
    print("snapshot:", s.numberOfSections, s.numberOfItems, s.sectionIdentifiers, s.itemIdentifiers)
    print("  in b:", s.itemIdentifiers(inSection: "b"), s.numberOfItems(inSection: "a"), s.sectionIdentifier(containingItem: 5) ?? "-",
          s.indexOfItem(4) ?? -1, s.indexOfSection("b") ?? -1)
    s.insertItems([10], beforeItem: 2)
    s.insertItems([11], afterItem: 5)
    s.moveItem(1, afterItem: 3)
    s.moveItem(5, beforeItem: 4)
    s.deleteItems([10])
    print("  edited:", s.itemIdentifiers(inSection: "a"), s.itemIdentifiers(inSection: "b"))
    s.insertSections(["z"], beforeSection: "a")
    s.moveSection("z", afterSection: "b")
    s.reloadItems([2])
    s.reloadSections(["a"])
    print("  sections:", s.sectionIdentifiers, s.numberOfItems(inSection: "z"))
    s.deleteSections(["z"])
    var copy = s
    copy.deleteAllItems()
    print("  after delete:", s.sectionIdentifiers, copy.numberOfSections, copy.numberOfItems)

    // collection view data source
    let cv = NSCollectionView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
    cv.register(Item.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("item"))
    var made: [Int] = []
    let ds = NSCollectionViewDiffableDataSource<String, Int>(collectionView: cv) { cv, indexPath, id in
      made.append(id)
      return cv.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("item"), for: indexPath)
    }
    print("collection data source set:", cv.dataSource === ds)
    var applied = false
    ds.apply(s, animatingDifferences: false) { applied = true }
    print("  applied:", applied, ds.numberOfSections(in: cv), ds.collectionView(cv, numberOfItemsInSection: 1))
    print("  lookups:", ds.itemIdentifier(for: IndexPath(item: 1, section: 1)) ?? -1, ds.indexPath(for: 3).map { "\($0.section).\($0.item)" } ?? "-",
          ds.itemIdentifier(for: IndexPath(item: 9, section: 0)).map(String.init) ?? "nil")
    print("  snapshot back:", ds.snapshot().itemIdentifiers)
    print("  provider not yet asked:", made.isEmpty)

    // table view data source
    let tv = NSTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
    tv.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c")))
    let tds = NSTableViewDiffableDataSource<String, Int>(tableView: tv) { _, _, row, id in
      let f = NSTextField(labelWithString: "\(id)")
      f.tag = row
      return f
    }
    tds.apply(s, animatingDifferences: false)
    print("table data source set:", tv.dataSource === tds, tds.numberOfRows(in: tv))
    print("  rows:", tds.itemIdentifier(forRow: 0) ?? -1, tds.row(forItemIdentifier: 4) ?? -1, tds.sectionIdentifier(forRow: 0) ?? "nil",
          tds.row(forSectionIdentifier: "b").map(String.init) ?? "nil")
    tds.sectionHeaderViewProvider = { _, _, id in NSTextField(labelWithString: id) }
    print("  with headers:", tds.numberOfRows(in: tv), tds.sectionIdentifier(forRow: 0) ?? "nil", tds.itemIdentifier(forRow: 1) ?? -1,
          tds.row(forSectionIdentifier: "b") ?? -1, tds.row(forItemIdentifier: 4) ?? -1)

    // suggestions
    var item = NSSuggestionItem(representedValue: 7, title: "Seven")
    item.secondaryTitle = "the number"
    item.toolTip = "tip"
    let section = NSSuggestionItemSection(title: "Numbers", items: [item])
    var response = NSSuggestionItemResponse(itemSections: [section])
    response.phase = .intermediate
    print("suggestions:", item.title, item.secondaryTitle ?? "-", item.representedValue, String(item.attributedTitle.characters),
          section.title ?? "-", section.items.count, response.itemSections.count, response.phase == .intermediate,
          response.preferredHighlight == .automatic)
    print("  items init:", NSSuggestionItemResponse(items: [item]).itemSections.count, NSSuggestionItemResponse<Int>().itemSections.count,
          item == NSSuggestionItem(representedValue: 7, title: "Seven"), NSSuggestionItemResponse<Int>().phase == .final)

    // invalidation
    let w = Watched(frame: .zero)
    w.layouts = 0
    w.displays = 0
    w.size = 1
    let unchanged = w.layouts
    w.size = 2
    w.color = 3
    print("invalidating: unchanged \(unchanged) layouts \(w.layouts > 0) displays \(w.displays > 0) values \(w.size) \(w.color)")

    // cursors, menu items, pop-up buttons, bezels
    let all = NSCursor.FrameResizeDirection.Set.all
    print("frame resize:", all.rawValue, NSCursor.FrameResizeDirection.Set.inward.rawValue, NSCursor.FrameResizeDirection.Set(.outward).rawValue,
          NSCursor.FrameResizeDirection.allCases.count)
    print("  cursor made:", NSCursor.frameResize(position: .left, directions: .all) !== NSCursor.arrow)
    let header = NSMenuItem.sectionHeader(title: "Section")
    print("section header:", header.title, header.isSectionHeader, header.isEnabled)
    let menu = NSMenu()
    menu.addItem(withTitle: "One", action: nil, keyEquivalent: "")
    let pop = NSPopUpButton(title: "Actions", pullDownMenu: menu)
    print("pull-down:", pop.pullsDown, pop.menu === menu, pop.title, pop.numberOfItems)

    // toolbar badges and view layout regions
    let countBadge = NSItemBadge.count(1234)
    let textBadge = NSItemBadge.text("Ready")
    let indicatorBadge = NSItemBadge.indicator
    print("badges:", countBadge.text, textBadge.text, indicatorBadge.text.isEmpty,
          countBadge == NSItemBadge.count(1234), countBadge == textBadge,
          indicatorBadge == NSItemBadge.text(""))
    let toolbarItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("swift-badge"))
    toolbarItem.badge = countBadge
    print("  toolbar badge:", toolbarItem.badge?.text ?? "-", toolbarItem.badge == countBadge)

    let regionView = NSView(frame: NSRect(x: 10, y: 20, width: 100, height: 60))
    regionView.additionalSafeAreaInsets = NSEdgeInsets(top: 3, left: 4, bottom: 5, right: 6)
    let safeRegion = NSView.LayoutRegion.safeArea(cornerAdaptation: .horizontal)
    let sameRegion = NSView.LayoutRegion.safeArea()
    let marginsRegion = NSView.LayoutRegion.margins()
    print("  regions made")
    let safeInsets = regionView.edgeInsets(for: safeRegion)
    print("  safe insets:", safeInsets.top, safeInsets.left, safeInsets.bottom, safeInsets.right)
    let marginInsets = regionView.edgeInsets(for: marginsRegion)
    print("  margin insets:", marginInsets.top, marginInsets.left, marginInsets.bottom, marginInsets.right)
    let marginRect = regionView.rect(for: marginsRegion)
    print("  margin rect:", marginRect)
    let safeDefaultGuide = regionView.layoutGuide(for: sameRegion)
    let safeGuide = regionView.layoutGuide(for: safeRegion)
    let safeVerticalGuide = regionView.layoutGuide(for: .safeArea(cornerAdaptation: .vertical))
    let marginsGuide = regionView.layoutGuide(for: marginsRegion)
    let marginsHorizontalGuide = regionView.layoutGuide(for: .margins(cornerAdaptation: .horizontal))
    let repeatedSafeGuide = regionView.layoutGuide(for: safeRegion)
    print("layout regions:", safeRegion == sameRegion, Set([safeRegion, sameRegion]).count,
          safeInsets.top, safeInsets.left, safeInsets.bottom, safeInsets.right,
          marginRect, marginInsets.top, marginInsets.left,
          marginInsets.bottom, marginInsets.right)
    print("  region guides:", safeDefaultGuide === regionView.safeAreaLayoutGuide,
          safeGuide === regionView.safeAreaLayoutGuide,
          safeVerticalGuide === regionView.safeAreaLayoutGuide,
          marginsGuide === regionView.safeAreaLayoutGuide,
          safeGuide === safeVerticalGuide,
          marginsHorizontalGuide === safeGuide,
          marginsHorizontalGuide === regionView.safeAreaLayoutGuide,
          safeGuide === repeatedSafeGuide)

    // the attribute scope
    var a = AttributedString("hi")
    a.appKit.foregroundColor = NSColor.red
    a.appKit.kern = 2
    print("attributes:", a.appKit.foregroundColor != nil, a.appKit.kern ?? 0, AttributeScopes.AppKitAttributes.FontAttribute.name,
          AttributeScopes.AppKitAttributes.ForegroundColorAttribute.name)
    let ns = NSAttributedString(a)
    print("  bridged:", ns.attribute(.foregroundColor, at: 0, effectiveRange: nil) != nil, ns.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat ?? 0)
  }
}
