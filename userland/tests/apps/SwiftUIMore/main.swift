// SPDX-License-Identifier: MIT OR Apache-2.0
// SwiftUIMore: the containers, scenes and modifiers Font Book uses (a Settings scene, group
// boxes, tab views, a canvas, outline lists, scene storage, a search field, an inspector,
// a colour picker), built against Apple's SDK as Xcode would.
import SwiftUI
import Observation
import CoreGraphics

struct Node: Identifiable {
    let id = UUID()
    let name: String
    var children: [Node]?
}

private struct GapTableRow: Identifiable {
    let id: Int
    let name: String
}

@objcMembers
private final class GapObjectRow: NSObject, Identifiable {
    let id: Int
    let name: String
    let count: Int

    init(id: Int, name: String, count: Int) {
        self.id = id
        self.name = name
        self.count = count
    }
}

@main
struct SwiftUIMoreApp: App {
    @StateObject private var library = Library()

    init() {
        // MORE_LOCTEST=bundle-path: how that bundle's plural strings localize here
        if let path = ProcessInfo.processInfo.environment["MORE_LOCTEST"], let b = Bundle(path: path) {
            let raw = b.localizedString(forKey: "style-count %lld", value: nil, table: nil)
            func print(_ items: Any...) { fputs(items.map { "\($0)" }.joined(separator: " ") + "\n", stderr) }
            print("loctest localizations:", b.localizations, "preferred:", b.preferredLocalizations,
                  "current:", Locale.current.identifier, Locale.preferredLanguages)
            print("loctest raw:", raw, "format:", String(format: raw, 4 as Int64))
            print("loctest localized:", String(localized: "style-count \(4)", bundle: b))
        }
    }
    var body: some Scene {
        WindowGroup("SwiftUI More") {
            if ProcessInfo.processInfo.environment["SWIFTUI_GAPS_TEST"] != nil {
                SwiftUIGapsView()
            } else {
                More()
                    .environmentObject(library)
                    .onAppear { library.reset() }
            }
        }
        .windowToolbarLabelStyle(fixed: .titleAndIcon)
        .commands {
            SidebarCommands()
            MoreCommands()
        }
        Settings {
            Text("Settings").padding()
        }
    }
}

@Observable
final class MoreModel {
    var count = 0
}

/// Loads as Font Book's model does: off the main actor, then publishes on it.
@Observable
final class Loader {
    var isLoading = true
    var items: [String] = []

    @MainActor
    func load() async {
        let found = await Task.detached { () -> [String] in
            try? await Task.sleep(for: .milliseconds(300))
            return ["Inter", "Liberation Sans"]
        }.value
        items = found
        isLoading = false
    }
}

struct LoaderView: View {
    @State private var loader = Loader()
    var body: some View {
        Group {
            if loader.isLoading {
                ProgressView()
            } else {
                Text("Loaded: " + loader.items.joined(separator: ", "))
            }
        }
        .task { await loader.load() }
    }
}

/// Font Book's library model: an ObservableObject in the environment, published from
/// another thread.
final class Library: ObservableObject {
    @Published var isLoading = true
    @Published var families: [String] = []

    func reset() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            self.families = ["Inter", "Liberation Serif"]
            self.isLoading = false
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var library: Library
    var body: some View {
        if library.isLoading {
            ProgressView()
        } else {
            Text("Library: " + library.families.joined(separator: ", "))
        }
    }
}

/// Font Book's grid: tiles read an environment object, inside a lazy grid with tags.
final class Selection: ObservableObject {
    @Published var selected: String?
}

struct Tile: View {
    @EnvironmentObject private var selection: Selection
    let name: String
    var body: some View {
        Text(name)
            .padding(4)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .compositingGroup()
            .opacity(0.95)
            .background(selection.selected == name ? Color.accentColor.opacity(0.3) : Color.clear)
            // as Font Book's tiles: a double click opens, a click selects, a command-click adds
            // as Font Book's tiles: a click selects and a double click opens, simultaneously
            .gesture(TapGesture().onEnded {
                fputs("tile select \(name)\n", stderr)
                selection.selected = name
            }.simultaneously(with: TapGesture(count: 2).onEnded { fputs("tile open \(name)\n", stderr) }))
            .simultaneousGesture(TapGesture().modifiers(.command).onEnded { fputs("tile add \(name)\n", stderr) })
            .onDrag { NSItemProvider(object: name as NSString) }
            .contextMenu { Button("Show \(name)") {} }
    }
}

/// Font Book's grid: tiles read an environment object, in a lazy grid in a scroll view (whose
/// content Finch hosts apart, so the object must reach it).
struct TileGrid: View {
    @EnvironmentObject private var library: Library
    @StateObject private var selection = Selection()
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))]) {
                ForEach(library.families, id: \.self) { family in
                    Tile(name: family).tag(family)
                }
            }
        }
        .environmentObject(selection)
        .frame(height: 40)
    }
}

struct MoreCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.moreCount) private var count
    var body: some Commands {
        CommandMenu("More") {
            Button("Open Another") { openWindow(id: "more") }
            Text("Count \(count ?? 0)")
        }
    }
}

extension FocusedValues {
    @Entry var moreCount: Int?
}

private func gapLog(_ message: String) {
    fputs(message + "\n", stderr)
}

struct LegacyPresentationModeControl: View {
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        Button("Dismiss") { presentationMode.wrappedValue.dismiss() }
    }
}

/// A small headless test surface for the views and drawing APIs added by Finch.
struct SwiftUIGapsView: View {
    @State private var count = 0
    @State private var text = "Edit me"
    @State private var secret = ""
    @State private var checked = false
    @State private var buttonToggle = false
    @State private var importerPresented = false
    @State private var sizingPresented = false
    @State private var scrollSelection: Int? = 0
    @State private var date = Date(timeIntervalSince1970: 1_700_000_000)
    @State private var objectSortOrder = [SortDescriptor<GapObjectRow>(\.name)]
    @FocusState private var exitCommandFocused: Bool

    var body: some View {
        let stage = ProcessInfo.processInfo.environment["SWIFTUI_GAPS_STAGE"] ?? "all"
        VStack(alignment: .leading, spacing: 8) {
            if stage == "all" || stage == "stepper" {
                Stepper(value: $count, in: 0...3, onEditingChanged: { gapLog("editing: \($0)") }) {
                    Text("Count: \(count)")
                }
                .onChange(of: count) { _, value in gapLog("stepper: \(value)") }
            }

            if stage == "task-id" {
                Button("Start task") { count += 1 }
                    .task(id: count) { gapLog("task-id: \(count)") }
            }

            if stage == "checkbox" {
                Toggle("Checkbox", isOn: $checked)
                    .toggleStyle(.checkbox)
                    .onChange(of: checked) { _, value in gapLog("checkbox: \(value)") }
            }

            if stage == "button-toggle" {
                Toggle("Button toggle", isOn: $buttonToggle)
                    .toggleStyle(.button)
                    .onAppear { gapLog("button-toggle: \(buttonToggle)") }
                    .onChange(of: buttonToggle) { _, value in gapLog("button-toggle: \(value)") }
            }

            if stage == "button-repeat" {
                Button("Repeat") {
                    count += 1
                    gapLog("button-repeat: \(count)")
                }
                .buttonRepeatBehavior(.enabled)
            }

            if stage == "date-picker" {
                DatePicker("Date", selection: $date, in: Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: 2_000_000_000),
                           displayedComponents: .date)
                    .datePickerStyle(.field)
                    .onAppear { gapLog("date-picker: \(Int(date.timeIntervalSince1970))") }
                    .onChange(of: date) { _, value in gapLog("date-picker: \(Int(value.timeIntervalSince1970))") }
            }

            if stage == "file-importer" {
                Button("Choose file") { importerPresented = true }
                    .fileImporter(isPresented: $importerPresented, allowedContentTypes: [.plainText],
                                  allowsMultipleSelection: true, onCompletion: { result in
                                      if case .success(let urls) = result {
                                          gapLog("file-importer: selected \(urls.count)")
                                      }
                                  }, onCancellation: {
                                      gapLog("file-importer: cancelled")
                                  })
            }

            if stage == "exit-command" {
                Text("Press Escape")
                    .frame(width: 130, height: 52)
                    .focusable()
                    .focused($exitCommandFocused)
                    .onAppear { exitCommandFocused = true }
                    .onExitCommand { gapLog("exit-command: handled") }
            }

            if stage == "table-style" {
                Table([GapTableRow(id: 1, name: "Alpha"), GapTableRow(id: 2, name: "Beta")]) {
                    TableColumn(LocalizedStringKey("Name"), value: \.name)
                }
                .tableStyle(.bordered(alternatesRowBackgrounds: false))
                .frame(width: 240, height: 100)
                .onAppear { gapLog("table-style: bordered") }
            }

            if stage == "gauge" {
                Gauge(value: 0.73) {
                    Text("Capacity")
                } currentValueLabel: {
                    Text("73%")
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .frame(width: 100, height: 70)
                .onAppear {
                    let rendered = Gauge(value: 0.73) {
                        Text("Capacity")
                    } currentValueLabel: {
                        Text("73%")
                    }.gaugeStyle(.accessoryCircularCapacity).frame(width: 100, height: 70)
                    let size = ImageRenderer(content: rendered).cgImage.map { "\($0.width)x\($0.height)" } ?? "nil"
                    gapLog("gauge: \(size)")
                }
            }

            if stage == "control-group-style" {
                ControlGroup("Actions") {
                    Button("Add") {}
                    Button("Remove") {}
                }
                .controlGroupStyle(.menu)
                .frame(width: 100, height: 36)
                .onAppear {
                    let rendered = ControlGroup("Actions") {
                        Button("Add") {}
                        Button("Remove") {}
                    }.controlGroupStyle(.menu).frame(width: 100, height: 36)
                    let size = ImageRenderer(content: rendered).cgImage.map { "\($0.width)x\($0.height)" } ?? "nil"
                    gapLog("control-group-style: \(size)")
                }
            }

            if stage == "table-column-sort" {
                let rows = [
                    GapObjectRow(id: 1, name: "Zebra", count: 2),
                    GapObjectRow(id: 2, name: "Alpha", count: 1),
                ]
                Table(rows, sortOrder: $objectSortOrder) {
                    TableColumn(LocalizedStringKey("Name"), value: \.name)
                    TableColumnForEach(0..<1) { index in
                        TableColumn(LocalizedStringKey("Count \(index)"), value: \.count) { Text(String($0.count)) }
                    }
                }
                .frame(width: 280, height: 110)
                .onAppear {
                    guard let comparator = objectSortOrder.first else { return }
                    let names = rows.sorted { comparator.compare($0, $1) == .orderedAscending }.map(\.name)
                    gapLog("table-column-sort: " + names.joined(separator: ","))
                }
                .onChange(of: objectSortOrder) { _, order in
                    guard let comparator = order.first else { return }
                    let names = rows.sorted { comparator.compare($0, $1) == .orderedAscending }.map(\.name)
                    gapLog("table-column-sort: " + names.joined(separator: ","))
                }
            }

            if stage == "image-renderer" {
                Text("Image renderer")
                    .onAppear {
                        let renderer = ImageRenderer(content: Color.red.frame(width: 10, height: 20))
                        renderer.scale = 2
                        let size = renderer.cgImage.map { "\($0.width)x\($0.height)" } ?? "nil"
                        gapLog("image-renderer: \(size)")
                    }
            }

            if stage == "shape-style-gradients" {
                let gradient = AnyGradient(Gradient(colors: [.red, .blue]))
                Rectangle()
                    .fill(.linearGradient(gradient, startPoint: .leading, endPoint: .trailing))
                    .frame(width: 80, height: 20)
                    .onAppear {
                        _ = gradient == Color.red.gradient
                        let renderer = ImageRenderer(content: Rectangle()
                            .fill(.linearGradient(gradient, startPoint: .leading, endPoint: .trailing))
                            .frame(width: 80, height: 20))
                        let size = renderer.cgImage.map { "\($0.width)x\($0.height)" } ?? "nil"
                        gapLog("shape-style-gradients: \(size)")
                    }
            }

            if stage == "shape-style-types" {
                HStack(spacing: 4) {
                    Rectangle().fill(.fill)
                    Text("Link").foregroundStyle(.link)
                    Text("Hint").foregroundStyle(.placeholder)
                    Rectangle().fill(.selection)
                    Rectangle().fill(.windowBackground)
                }
                .frame(width: 180, height: 24)
                .onAppear {
                    let renderer = ImageRenderer(content: HStack(spacing: 4) {
                        Rectangle().fill(.fill)
                        Text("Link").foregroundStyle(.link)
                        Text("Hint").foregroundStyle(.placeholder)
                        Rectangle().fill(.selection)
                        Rectangle().fill(.windowBackground)
                    }.frame(width: 180, height: 24))
                    let size = renderer.cgImage.map { "\($0.width)x\($0.height)" } ?? "nil"
                    gapLog("shape-style-types: \(size)")
                }
            }

            if stage == "any-shape" {
                AnyShape(Capsule())
                    .fill(.red)
                    .frame(width: 80, height: 32)
                    .onAppear {
                        let rendered = ImageRenderer(content: AnyShape(Capsule()).fill(.red)
                            .frame(width: 80, height: 32))
                        let size = rendered.cgImage.map { "\($0.width)x\($0.height)" } ?? "nil"
                        gapLog("any-shape: \(size)")
                    }
            }

            if stage == "shape-operations" {
                Text("Shape operations")
                    .onAppear {
                        func contains(_ path: Path, _ point: CGPoint) -> Bool {
                            path.cgPath.contains(point)
                        }
                        let left = Path(CGRect(x: 0, y: 0, width: 20, height: 20))
                        let right = Path(CGRect(x: 10, y: 0, width: 20, height: 20))
                        let intersection = left.intersection(right)
                        let union = left.union(right)
                        let subtraction = left.subtracting(right)
                        let symmetricDifference = left.symmetricDifference(right)
                        let normalized = union.normalized()
                        let transformed = Rectangle()
                            .transform(CGAffineTransform(translationX: 10, y: 0))
                            .path(in: CGRect(x: 0, y: 0, width: 20, height: 20))
                        let offset = Rectangle().offset(CGPoint(x: 10, y: 0))
                            .path(in: CGRect(x: 0, y: 0, width: 20, height: 20))
                        let sized = Rectangle().size(width: 10, height: 5)
                            .path(in: CGRect(x: 0, y: 0, width: 30, height: 20))
                        let anchored = Rectangle().size(width: 10, height: 5, anchor: .topLeading)
                            .path(in: CGRect(x: 0, y: 0, width: 30, height: 20))
                        let shapeIntersection = Rectangle().intersection(Rectangle().offset(CGPoint(x: 10, y: 0)))
                            .path(in: CGRect(x: 0, y: 0, width: 20, height: 20))
                        let shapeUnion = Rectangle().union(Rectangle().offset(CGPoint(x: 10, y: 0)))
                            .path(in: CGRect(x: 0, y: 0, width: 20, height: 20))
                        let shapeSubtraction = Rectangle().subtracting(Rectangle().offset(CGPoint(x: 10, y: 0)))
                            .path(in: CGRect(x: 0, y: 0, width: 20, height: 20))
                        let shapeXor = Rectangle().symmetricDifference(Rectangle().offset(CGPoint(x: 10, y: 0)))
                            .path(in: CGRect(x: 0, y: 0, width: 20, height: 20))
                        let inside = CGPoint(x: 15, y: 10)
                        let leftOnly = CGPoint(x: 5, y: 10)
                        let rightOnly = CGPoint(x: 25, y: 10)
                        let checks: [(String, Bool)] = [
                            ("path intersection", contains(intersection, inside) && !contains(intersection, leftOnly)),
                            ("path union", contains(union, leftOnly) && contains(union, rightOnly)),
                            ("path subtraction", contains(subtraction, leftOnly) && !contains(subtraction, inside)),
                            ("path symmetric difference", contains(symmetricDifference, leftOnly)
                                && contains(symmetricDifference, rightOnly) && !contains(symmetricDifference, inside)),
                            ("path normalization", contains(normalized, leftOnly) && contains(normalized, rightOnly)),
                            ("shape transform", contains(transformed, rightOnly)),
                            ("shape point offset", contains(offset, rightOnly)),
                            ("shape size", contains(sized, inside) && !contains(sized, leftOnly)),
                            ("anchored shape size", contains(anchored, CGPoint(x: 5, y: 2)) && !contains(anchored, inside)),
                            ("shape intersection", contains(shapeIntersection, inside) && !contains(shapeIntersection, leftOnly)),
                            ("shape union", contains(shapeUnion, leftOnly) && contains(shapeUnion, rightOnly)),
                            ("shape subtraction", contains(shapeSubtraction, leftOnly) && !contains(shapeSubtraction, inside)),
                            ("shape symmetric difference", contains(shapeXor, leftOnly)
                                && contains(shapeXor, rightOnly) && !contains(shapeXor, inside)),
                        ]
                        for (name, passed) in checks where !passed { gapLog("shape-operations failed: \(name)") }
                        gapLog("shape-operations: \(checks.allSatisfy { $0.1 } ? "pass" : "fail")")
                    }
            }

            if stage == "font-size" {
                Text("Font size")
                    .font(Font.system(size: 12).bold(true).scaled(by: 2).pointSize(18).italic(false))
                    .onAppear {
                        let renderer = ImageRenderer(content: Text("Font size")
                            .font(Font.system(size: 12).bold(true).scaled(by: 2).pointSize(18).italic(false)))
                        let size = renderer.cgImage.map { "\($0.width)x\($0.height)" } ?? "nil"
                        gapLog("font-size: \(size)")
                    }
            }

            if stage == "text-accessibility" {
                Text("Visible text")
                    .accessibilityLabel(LocalizedStringResource("Spoken label"))
                    .accessibilityTextContentType(.plain)
                    .accessibilityHeading(.h1)
                    .speechAlwaysIncludesPunctuation()
                    .speechSpellsOutCharacters()
                    .speechAdjustedPitch(0.2)
                    .speechAlwaysIncludesPunctuation(false)
                    .onAppear { gapLog("text-accessibility: ready") }
            }

            if stage == "localized-accessibility" {
                Text("Visible text")
                    .accessibilityLabel(LocalizedStringResource("Tab label"), isEnabled: true)
                    .onAppear { gapLog("localized-accessibility: ready") }
            }

            if stage == "all" || stage == "editor" {
                TextEditor(text: $text)
                    .frame(height: 64)
                    .onChange(of: text) { _, value in gapLog("editor: \(value)") }
            }

            if stage == "secure-field" {
                SecureField("Password", text: $secret, prompt: Text("Password"))
                    .frame(width: 180)
                    .onChange(of: secret) { _, value in
                        gapLog("secure-field: \(value.isEmpty ? "empty" : "received \(value.count) characters")")
                    }
            }

            if stage == "help-link" {
                VStack(alignment: .leading, spacing: 4) {
                    HelpLink(action: { gapLog("help-link: activated") })
                    HelpLink(destination: URL(string: "https://example.com/help")!)
                    HelpLink(anchor: "guide")
                    HelpLink(anchor: "guide", book: "HelpBook")
                }
            }

            if stage == "accessory-bar" {
                Button("Accessory action") { gapLog("accessory-bar: activated") }
                    .buttonStyle(.accessoryBar)
            }

            if stage == "presentation-mode" {
                LegacyPresentationModeControl()
            }

            if #available(macOS 15.0, *), stage == "presentation-sizing" {
                Button("Show fitted sheet") { sizingPresented = true }
                    .sheet(isPresented: $sizingPresented) {
                        Text("Fitted sheet").presentationSizing(.fitted)
                    }
            }

            if #available(macOS 26.0, *), stage.hasPrefix("toolbar-spacer") {
                Text("Toolbar spacer")
                    .onAppear { gapLog("toolbar-spacer: ready") }
                    .toolbar {
                        ToolbarSpacer(stage.hasSuffix("fixed") ? .fixed : .flexible)
                    }
            }

            if stage == "all" || stage.hasPrefix("canvas") {
                Canvas { context, _ in
                    switch stage {
                    case "canvas-empty":
                        break
                    case "canvas-shade":
                        _ = GraphicsContext.Shading.color(.red)
                    case "canvas-path":
                        _ = Path(CGRect(x: 0, y: 0, width: 48, height: 20))
                    case "canvas-cg":
                        context.withCGContext { cg in
                            cg.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
                            cg.fill(CGRect(x: 0, y: 0, width: 48, height: 20))
                        }
                    case "canvas-stroke":
                        var path = Path()
                        path.move(to: CGPoint(x: 4, y: 10))
                        path.addLine(to: CGPoint(x: 44, y: 10))
                        context.stroke(path, with: .color(.blue), style: StrokeStyle(lineWidth: 4))
                    default:
                        context.fill(Path(CGRect(x: 0, y: 0, width: 48, height: 20)), with: .color(.red))
                    }
                }
                .frame(width: 48, height: 20)
            }

            if stage == "all" || stage == "scroll" {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(0..<8) { index in
                            Text("Row \(index)").frame(height: 30)
                        }
                    }
                }
                .frame(height: 60)
                .scrollBounceBehavior(.basedOnSize)
                .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > 5 } action: { old, new in
                    gapLog("scroll: \(old) -> \(new)")
                }
            }

            if stage == "shape-transform" {
                HStack {
                    Circle().offset(x: 4, y: 2).stroke(.blue)
                    RoundedRectangle(cornerRadius: 4).rotation(.degrees(15)).stroke(.red)
                }
                .frame(width: 100, height: 40)
            }

            if stage == "position-layout" {
                Text("Positioned").position(x: 50, y: 20)
            }

            if stage == "edit-actions" {
                let actions: EditActions<[String]> = .move
                Text(actions.contains(.move) ? "Move enabled" : "Move disabled")
            }

            if stage == "scroll-position" {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(0..<10) { index in
                            Text("Target \(index)").frame(height: 30).id(index)
                        }
                    }
                }
                .frame(height: 60)
                .scrollPosition(id: $scrollSelection, anchor: .top)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { scrollSelection = 5 }
                }
                .onScrollGeometryChange(for: Int.self) { Int($0.contentOffset.y) } action: { _, offset in
                    if scrollSelection == 5 { gapLog("scroll-position: \(offset)") }
                }
            }

            if stage == "scroll-default-anchor" {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(0..<10) { index in
                            Text("Anchor \(index)").frame(height: 30)
                        }
                    }
                }
                .frame(height: 60)
                .defaultScrollAnchor(.bottom)
                .onScrollGeometryChange(for: Int.self) { Int($0.contentOffset.y) } action: { _, offset in
                    gapLog("scroll-default-anchor: \(offset)")
                }
            }

            if stage == "scroll-anchor-role" {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(0..<10) { index in
                            Text("Role \(index)").frame(height: 30)
                        }
                    }
                }
                .frame(height: 60)
                .defaultScrollAnchor(.top)
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .onScrollGeometryChange(for: Int.self) { Int($0.contentOffset.y) } action: { _, offset in
                    gapLog("scroll-anchor-role: \(offset)")
                }
            }

            if stage == "scroll-paging" {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(0..<6) { index in
                            Text("Page \(index)").frame(height: 60)
                        }
                    }
                }
                .frame(height: 60)
                .scrollTargetBehavior(.paging)
                .onScrollGeometryChange(for: Int.self) { Int($0.contentOffset.y) } action: { _, offset in
                    gapLog("scroll-paging: \(offset)")
                }
            }

            if stage == "bounce-default" || stage == "bounce-size" || stage == "bounce-always" {
                let behavior: ScrollBounceBehavior = switch stage {
                case "bounce-always": .always
                case "bounce-size": .basedOnSize
                default: .automatic
                }
                ScrollView {
                    Text("Short content").frame(height: 30)
                }
                .frame(height: 60)
                .scrollBounceBehavior(behavior)
                .onScrollGeometryChange(for: Bool.self) { abs($0.contentOffset.y) > 5 } action: { old, new in
                    gapLog("bounce: \(old) -> \(new)")
                }
            }

            if stage == "all" || stage == "move" {
                Button("Move collection") {
                    var values = ["A", "B", "C"]
                    values.move(fromOffsets: IndexSet(integer: 1), toOffset: 3)
                    gapLog("move: \(values.joined())")
                }
            }

            if stage == "hover" {
                Text("Hover here")
                    .frame(width: 120, height: 60)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): gapLog("hover: active \(Int(point.x)),\(Int(point.y))")
                        case .ended: gapLog("hover: ended")
                        }
                    }
            }
        }
        .padding()
        .frame(width: 300, height: 300)
    }
}

struct More: View {
    @SceneStorage("tab") private var tab = 0
    @State private var search = ""
    @State private var inspector = true
    @State private var color = Color.orange
    private let tree = [Node(name: "Fonts", children: [Node(name: "Inter", children: nil), Node(name: "Liberation", children: nil)]),
                        Node(name: "Collections", children: nil)]

    var body: some View {
        TabView(selection: $tab) {
            VStack(alignment: .leading, spacing: 10) {
                GroupBox("Group box") {
                    Text("Inside a group box")
                    ColorPicker("Colour", selection: $color)
                }
                Canvas { context, size in
                    context.withCGContext { cg in
                        cg.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.3, alpha: 1))
                        cg.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
                    }
                }
                .frame(width: 160, height: 40)
                LabeledContent("Search", value: search.isEmpty ? "(none)" : search)
                LoaderView()
                LibraryView()
                if let path = ProcessInfo.processInfo.environment["MORE_LOCTEST"], let b = Bundle(path: path) {
                    Text("style-count \(4)", bundle: b)
                }
                TileGrid()
                HStack {
                    Label("Favourites", systemImage: "star.fill")
                    Image(systemName: "folder").foregroundStyle(.blue)
                    Image(systemName: "gearshape")
                }
            }
            .padding()
            .tabItem { Text("First") }
            .tag(0)
            List(tree, children: \.children) { node in
                Text(node.name)
            }
            .tabItem { Text("Outline") }
            .tag(1)
        }
        .searchable(text: $search, prompt: "Fonts")
        .inspector(isPresented: $inspector) {
            Text("Inspector").padding()
        }
        .frame(width: 520, height: 320)
    }
}
