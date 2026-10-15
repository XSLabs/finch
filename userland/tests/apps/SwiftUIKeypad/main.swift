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
            KeypadView(model: model)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandMenu("Mode") {
                ForEach(Array(Pad.allCases.enumerated()), id: \.1) { i, pad in
                    Button(pad.rawValue.capitalized) {
                        report("mode \(pad.rawValue)")
                        model.switchTo(pad)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
            }
        }
    }
}

struct KeypadView: View {
    let model: Model
    @Environment(\.colorScheme) private var colorScheme
    private let dark = ProcessInfo.processInfo.environment["KEYPAD_DARK"] != nil

    var body: some View {
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
            Keys(model: model, pad: model.pad)
                .id(model.pad)
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
                        } label: {
                            Text("\(n)")
                                .font(.system(size: 18))
                                .frame(minWidth: 44, maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.bordered)
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
