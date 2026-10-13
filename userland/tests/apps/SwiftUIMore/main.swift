// SPDX-License-Identifier: MIT OR Apache-2.0
// SwiftUIMore: the containers, scenes and modifiers Font Book uses (a Settings scene, group
// boxes, tab views, a canvas, outline lists, scene storage, a search field, an inspector,
// a colour picker), built against Apple's SDK as Xcode would.
import SwiftUI
import Observation

struct Node: Identifiable {
    let id = UUID()
    let name: String
    var children: [Node]?
}

@main
struct SwiftUIMoreApp: App {
    @StateObject private var library = Library()
    var body: some Scene {
        WindowGroup("SwiftUI More") {
            More()
                .environmentObject(library)
                .onAppear { library.reset() }
        }
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
            .background(selection.selected == name ? Color.accentColor.opacity(0.3) : Color.clear)
            .onTapGesture { selection.selected = name }
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
