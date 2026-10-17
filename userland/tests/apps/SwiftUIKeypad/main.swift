// SPDX-License-Identifier: MIT OR Apache-2.0
// SwiftUIKeypad: a keypad window shaped like Calculator's (a display over a Grid of
// buttons, a toolbar picker, ⌘1/⌘2 switching between a 20-key and a 60-key pad), built
// against Apple's SDK as Xcode would. It times each keypad from the switch to the
// first run loop turn after it appears, and counts the process's CPU time from the switch
// to a second after that, which takes in the layout that follows, on stderr
// ("keypad basic: 20 keys in N ms, CPU M ms").
// KEYPAD_PROBE=1: the window is moved to the bottom of the screen, the keypad switches to the
// bigger one, and the window's frame and the screen's visible frame are printed: whether a
// window growing to fit its content is kept on the screen. Then it quits.
// KEYPAD_DARK=1: the window asks for .preferredColorScheme(.dark); its appearance is printed,
// and it quits (KEYPAD_DARK=show: stays open).
import SwiftUI
import AppKit

enum Pad: String, CaseIterable, Identifiable {
    case basic, scientific
    var id: String { rawValue }
    var columns: Int { self == .basic ? 4 : 10 }
    var rows: Int { 5 + (self == .basic ? 0 : 1) }
}

@Observable
final class Model {
    var pad: Pad = .basic
    var display = "0"
    var sidebar: NavigationSplitViewVisibility = .detailOnly
    var switched = Date()
    var switchedCPU = cpuTime()

    func switchTo(_ pad: Pad) {
        switched = Date()
        switchedCPU = cpuTime()
        self.pad = pad
    }
}

func report(_ s: String) { fputs(s + "\n", stderr) }

/// The process's user and system time, in seconds.
func cpuTime() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

@main
struct SwiftUIKeypadApp: App {
    @State private var model = Model()

    var body: some Scene {
        Window("Keypad", id: "keypad") {
            if ProcessInfo.processInfo.environment["KEYPAD_SAFE_AREA_PROBE"] != nil {
                SafeAreaSplitProbe()
            } else if ProcessInfo.processInfo.environment["KEYPAD_SPLIT"] != nil {
                SplitKeypadView(model: model)
            } else {
                KeypadView(model: model)
            }
        }
        .defaultSize(width: 900, height: 356)
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified)
        .commands {
            CommandMenu("Mode") {
                ForEach(Array(Pad.allCases.enumerated()), id: \.1) { i, pad in
                    Button(pad.rawValue.capitalized) {
                        report("mode \(pad.rawValue)")
                        model.switchTo(pad)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
                Button("Sidebar") {
                    model.sidebar = model.sidebar == .detailOnly ? .all : .detailOnly
                    report("sidebar \(model.sidebar == .all ? "shown" : "hidden")")
                }
                .keyboardShortcut("4", modifiers: .command)
            }
        }
    }
}

/// A host comparison for the safe-area layout around a floating split-view sidebar.
struct SafeAreaSplitProbe: View {
    @State private var visibility: NavigationSplitViewVisibility = .detailOnly

    var body: some View {
        splitView
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Probe") {}
                }
            }
            .coordinateSpace(name: "safe-area-probe")
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    reportProbeWindow("hidden")
                    visibility = .all
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        reportProbeWindow("shown")
                        if let view = SafeAreaProbeHost.ProbeView.buttonView {
                            let frame = view.convert(view.bounds, to: nil)
                            report("safe-area probe button-host actual: x \(Int(frame.minX)) width \(Int(frame.width))")
                        }
                        if ProcessInfo.processInfo.environment["KEYPAD_SAFE_AREA_PROBE_SHOW"] == nil {
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: Binding(get: { visibility }, set: { visibility = $0 })) {
            List(0..<3, id: \.self) { Text("record \($0)") }
                .navigationSplitViewColumnWidth(220)
        } detail: {
            SafeAreaProbeDetail().frame(width: 900)
        }
    }

    private func reportProbeWindow(_ label: String) {
        guard let window = NSApp.windows.first(where: \.isVisible) else { return }
        let screen = window.screen?.visibleFrame ?? .zero
        report("safe-area probe \(label): window \(Int(window.frame.width)) at \(Int(window.frame.minX))," +
               " visible \(Int(screen.width)) from \(Int(screen.minX))")
    }
}

struct SafeAreaProbeDetail: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {} label: {
                Text("button in safe area")
                    .frame(width: 876, height: 24, alignment: .leading)
                    .background(Color.gray.opacity(0.45))
                    .background(SafeAreaProbeHost(name: "button-host"))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading) {
                Text("plain VStack")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.gray.opacity(0.45))
            }
            .frame(width: 876, height: 48)
            .background(SafeAreaProbeFrame(name: "VStack"))

            SafeAreaProbeLayout {
                ForEach(0..<20, id: \.self) { index in
                    Button {} label: {
                        Text(index % 4 == 3 ? ["÷", "×", "−", "+", "="][index / 4] : "\(index)")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(index % 4 == 3 ? Color.orange : Color.gray.opacity(0.45), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(SafeAreaProbeFrame(name: "Layout"))

            ZStack(alignment: .leading) {
                Color.cyan.opacity(0.45).ignoresSafeArea()
                Text("ZStack background ignoresSafeArea")
                    .padding(8)
            }
            .frame(width: 876, height: 48)
            .background(SafeAreaProbeFrame(name: "ZStack"))
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(SafeAreaProbeHost(name: "detail-host"))
        .background(SafeAreaProbeFrame(name: "detail"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Detail") {}
            }
        }
    }
}

struct SafeAreaProbeHost: NSViewRepresentable {
    let name: String

    final class ProbeView: NSView {
        static weak var buttonView: ProbeView?
        var name = ""

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportFrame()
        }

        override func layout() {
            super.layout()
            reportFrame()
        }

        private func reportFrame() {
            guard window != nil else { return }
            if name == "button-host" { Self.buttonView = self }
            let frame = convert(bounds, to: nil)
            report("safe-area probe host \(name): x \(Int(frame.minX)) width \(Int(frame.width))")
        }
    }

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ view: ProbeView, context: Context) { view.name = name }
}

struct SafeAreaProbeFrame: View {
    let name: String

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("safe-area-probe")) } action: { frame in
                    report("safe-area probe \(name): x \(Int(frame.minX)) width \(Int(frame.width)) " +
                           "safe leading \(Int(geometry.safeAreaInsets.leading))")
                }
        }
    }
}

struct SafeAreaProbeLayout: Layout {
    private let minimumWidth: CGFloat = 876
    private let height: CGFloat = 180

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposedWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? minimumWidth
        return CGSize(width: max(minimumWidth, proposedWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cellWidth = bounds.width / 4
        let cellHeight = bounds.height / 5
        for (index, subview) in subviews.enumerated() {
            let column = index % 4
            let row = index / 4
            subview.place(at: CGPoint(x: bounds.minX + (CGFloat(column) + 0.5) * cellWidth,
                                      y: bounds.minY + (CGFloat(row) + 0.5) * cellHeight),
                          anchor: .center,
                          proposal: ProposedViewSize(width: cellWidth, height: cellHeight))
        }
    }
}

/// KEYPAD_SPLIT=1: the keypad as the detail of a split view whose sidebar (a list, as
/// Calculator's history) starts hidden; ⌘4 shows or hides it. KEYPAD_SPLIT=probe: the
/// sidebar is shown after a second, and the window's, sidebar's and detail's widths are
/// printed before and after; then it quits.
struct SplitKeypadView: View {
    let model: Model
    @State private var sidebarWidth = 0.0
    @State private var detailWidth = 0.0
    @State private var detailInset = 0.0

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(get: { model.sidebar }, set: { model.sidebar = $0 })) {
            List(0..<3, id: \.self) { Text("record \($0)") }
                .contentMargins(.horizontal, 12, for: .scrollContent)
                .navigationSplitViewColumnWidth(220)
                .background(GeometryReader { g in Color.clear.onAppear { sidebarWidth = g.size.width }
                    .onChange(of: g.size.width) { sidebarWidth = g.size.width } })
        } detail: {
            // as wide as Calculator's keypad, so the sidebar doesn't fit beside it in the window
            // (KEYPAD_SPLIT_GRID=1: no minimum, the width the scientific keypad's grid needs;
            // KEYPAD_SPLIT_IGNORE=1: as Calculator, the keypad ignores the safe area and reads
            // its insets through onGeometryChange)
            if ProcessInfo.processInfo.environment["KEYPAD_SPLIT_IGNORE"] != nil {
                let keypad = IgnoringKeypad(model: model)
                Group {
                    if ProcessInfo.processInfo.environment["KEYPAD_SPLIT_FLEX"] != nil {
                        keypad.frame(minWidth: 900, maxWidth: .infinity)
                    } else {
                        keypad.frame(width: 900)
                    }
                }
                    .background(GeometryReader { g in
                        Color.clear.onGeometryChange(for: CGSize.self) { $0.size } action: { detailWidth = $0.width }
                            .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: {
                                detailInset = $0.leading
                            }
                    })
            } else if ProcessInfo.processInfo.environment["KEYPAD_SPLIT_LAYOUT"] != nil {
                let keypad = KeypadView(model: model)
                    .frame(minWidth: ProcessInfo.processInfo.environment["KEYPAD_SPLIT_GRID"] != nil ? nil : 760)
                Group {
                    if ProcessInfo.processInfo.environment["KEYPAD_SPLIT_NAVIGATION"] != nil {
                        NavigationStack { keypad }
                    } else {
                        keypad
                    }
                }
                    .background {
                        Color.clear
                            .onGeometryChange(for: CGSize.self) { $0.size } action: { detailWidth = $0.width }
                            .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: {
                                detailInset = $0.leading
                            }
                    }
            } else {
                KeypadView(model: model)
                    .frame(minWidth: ProcessInfo.processInfo.environment["KEYPAD_SPLIT_GRID"] != nil ? nil : 760)
                    .background(GeometryReader { g in Color.clear.onAppear { detailWidth = g.size.width; detailInset = g.safeAreaInsets.leading }
                        .onChange(of: g.size.width) { detailWidth = g.size.width; detailInset = g.safeAreaInsets.leading } })
            }
        }
        .onAppear {
            guard ProcessInfo.processInfo.environment["KEYPAD_SPLIT"] == "probe" else { return }
            func widths(_ label: String) {
                let w = NSApp.windows.first { $0.title == "Keypad" }
                report("\(label): window \(Int(w?.frame.width ?? 0)) sidebar \(Int(sidebarWidth)) detail \(Int(detailWidth)) inset \(Int(detailInset))")
            }
            if ProcessInfo.processInfo.environment["KEYPAD_SPLIT_GRID"] != nil { model.switchTo(.scientific) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                widths("hidden")
                model.sidebar = .all
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    widths("shown")
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

/// The keypad under a safe area it ignores, padded by the insets onGeometryChange reports.
struct IgnoringKeypad: View {
    let model: Model
    @State private var insets = EdgeInsets()
    @State private var size = CGSize.zero

    var body: some View {
        KeypadView(model: model)
            .padding(.leading, insets.leading)
            .ignoresSafeArea()
            .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets = $0 }
            .onGeometryChange(for: CGSize.self) { $0.size } action: {
                size = $0
                report("ignoring keypad: size \(Int($0.width))x\(Int($0.height)) insets \(Int(insets.leading)) top \(Int(insets.top))")
            }
            .onChange(of: insets) { report("ignoring keypad: insets leading \(Int(insets.leading)) top \(Int(insets.top)) size \(Int(size.width))") }
    }
}

struct KeypadView: View {
    let model: Model
    @Environment(\.colorScheme) private var colorScheme
    private let dark = ProcessInfo.processInfo.environment["KEYPAD_DARK"] != nil

    @ViewBuilder
    var body: some View {
        if ProcessInfo.processInfo.environment["KEYPAD_SPLIT_SAFE_AREA_BAR"] != nil {
            keypadBody.safeAreaBar(edge: .top, spacing: 0) {
                Color.clear.frame(height: 1)
            }
        } else {
            keypadBody
        }
    }

    private var keypadBody: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Text(model.display)
                .font(.system(size: 36, weight: .light))
                .frame(maxWidth: .infinity, alignment: .trailing)
            if ProcessInfo.processInfo.environment["KEYPAD_SCALE"] != nil {
                // KEYPAD_SCALE=1: a label too wide for its frame, which minimumScaleFactor shrinks
                HStack {
                    Text("enter").font(.system(size: 24)).lineLimit(1).minimumScaleFactor(0.5)
                        .frame(width: 30).border(.red)
                    Text("enter").font(.system(size: 24)).lineLimit(1)
                        .frame(width: 30).border(.blue)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if ProcessInfo.processInfo.environment["KEYPAD_SPLIT_GRID_VIEW"] != nil {
                CalculatorGridProbe()
            } else if ProcessInfo.processInfo.environment["KEYPAD_SPLIT_LAYOUT"] != nil {
                CalculatorLayoutProbe {
                    ForEach(0..<20, id: \.self) { index in
                        let label: AnyView = index % 4 == 3
                            ? AnyView(Image(systemName: ["divide", "multiply", "minus", "plus", "equal"][index / 4])
                                .font(.system(size: 22)))
                            : AnyView(Text("\(index)").font(.system(size: 22)))
                        if ProcessInfo.processInfo.environment["KEYPAD_SPLIT_BUTTONS"] != nil {
                            Button {} label: {
                                label
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(index % 4 == 3 ? Color.orange : Color.gray, in: Circle())
                            }
                            .buttonStyle(.plain)
                        } else {
                            label
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(index % 4 == 3 ? Color.orange : Color.gray, in: Circle())
                        }
                    }
                }
                    .frame(maxWidth: .infinity)
                    .frame(height: 264)
                    .background {
                        GeometryReader { _ in
                            Color.clear
                                .onGeometryChange(for: CGSize.self) { $0.size } action: {
                                    report("custom layout geometry: size \(Int($0.width))x\(Int($0.height))")
                                }
                                .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: {
                                    report("custom layout geometry: safe leading \(Int($0.leading))")
                                }
                        }
                    }
            } else {
                Keys(model: model, pad: model.pad)
                    .id(model.pad)
            }
        }
        .padding(12)
        .preferredColorScheme(dark ? .dark : nil)
        .onChange(of: colorScheme, initial: true) {
            guard dark else { return }
            report("dark: scheme \(colorScheme == .dark ? "dark" : "light")")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let w = NSApp.windows.first { $0.isVisible }
                report("dark: window \(w?.effectiveAppearance.name.rawValue ?? "-")")
                if ProcessInfo.processInfo.environment["KEYPAD_DARK"] != "show" { NSApp.terminate(nil) }
            }
        }
        .toolbar {
            Picker("Mode", selection: Binding(get: { model.pad }, set: { model.switchTo($0) })) {
                ForEach(Pad.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }
}

/// A four-column Grid with the same button faces as the calculator's keypad.
struct CalculatorGridProbe: View {
    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 6) {
            ForEach(0..<5, id: \.self) { row in
                GridRow {
                    ForEach(0..<4, id: \.self) { column in
                        let index = row * 4 + column
                        let label: AnyView = column == 3
                            ? AnyView(Image(systemName: ["divide", "multiply", "minus", "plus", "equal"][row])
                                .font(.system(size: 22)))
                            : AnyView(Text("\(index)").font(.system(size: 22)))
                        Button {} label: {
                            label
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(column == 3 ? Color.orange : Color.gray, in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 264)
    }
}

/// A small custom keypad whose width follows the size its parent offers, as Calculator's
/// keypad layout does. Its log shows what happens when a sidebar narrows that offer.
struct CalculatorLayoutProbe: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposedWidth = proposal.width ?? .infinity
        let width = proposedWidth == 0 ? 98 : (proposedWidth.isFinite ? proposedWidth : 760)
        let height: CGFloat = 264
        let fittedWidth = width.isFinite ? String(Int(width)) : String(describing: width)
        report("custom keypad layout: proposed \(String(describing: proposal.width)) -> \(fittedWidth)")
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = 4
        let rows = 5
        let cellWidth = bounds.width / CGFloat(columns)
        let cellHeight = bounds.height / CGFloat(rows)
        for (index, subview) in subviews.enumerated() {
            let column = index % columns
            let row = index / columns
            subview.place(
                at: CGPoint(x: bounds.minX + (CGFloat(column) + 0.5) * cellWidth,
                           y: bounds.minY + (CGFloat(row) + 0.5) * cellHeight),
                anchor: .center,
                proposal: ProposedViewSize(width: cellWidth, height: cellHeight))
        }
    }
}

struct DigitShortcut: ViewModifier {
    let digit: Int?

    func body(content: Content) -> some View {
        if let digit, ProcessInfo.processInfo.environment["KEYPAD_KEYS"] != nil {
            content.keyboardShortcut(KeyEquivalent(Character("\(digit)")), modifiers: [])
        } else {
            content
        }
    }
}

struct Keys: View {
    let model: Model
    let pad: Pad

    func probe() {
        guard pad == .basic else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let w = NSApp.windows.first { $0.isVisible }
                report("probe: grown \(w.map { NSStringFromRect($0.frame) } ?? "-") visible \(w?.screen.map { NSStringFromRect($0.visibleFrame) } ?? "-")")
                NSApp.terminate(nil)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let w = NSApp.windows.first(where: { $0.isVisible }), let visible = w.screen?.visibleFrame else { return }
            w.setFrameOrigin(NSPoint(x: w.frame.origin.x, y: visible.minY))
            report("probe: low \(NSStringFromRect(w.frame))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { model.switchTo(.scientific) }
        }
    }

    var body: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(0..<pad.rows, id: \.self) { row in
                GridRow {
                    ForEach(0..<pad.columns, id: \.self) { column in
                        let n = row * pad.columns + column
                        Button {
                            model.display = model.display == "0" ? "\(n)" : model.display + "\(n)"
                            report("key \(n): display \(model.display)")
                        } label: {
                            Text("\(n)")
                                .font(.system(size: 18))
                                .frame(minWidth: 44, maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.bordered)
                        // KEYPAD_KEYS=1: keys 0-9 are their digits' shortcuts with no modifiers, as
                        // Calculator's are
                        .modifier(DigitShortcut(digit: n < 10 ? n : nil))
                    }
                }
            }
        }
        .onAppear {
            if ProcessInfo.processInfo.environment["KEYPAD_PROBE"] != nil {
                probe()
                return
            }
            let keys = pad.rows * pad.columns
            DispatchQueue.main.async {
                let ms = Int(Date().timeIntervalSince(model.switched) * 1000)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let cpu = Int((cpuTime() - model.switchedCPU) * 1000)
                    report("keypad \(pad.rawValue): \(keys) keys in \(ms) ms, CPU \(cpu) ms")
                }
            }
        }
    }
}
