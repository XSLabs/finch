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
    var body: some Scene {
        WindowGroup("SwiftUI More") {
            More()
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
