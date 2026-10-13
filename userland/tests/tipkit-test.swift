// SPDX-License-Identifier: MIT OR Apache-2.0
//
// TipKit: a tip with an event rule and a parameter rule and a plain tip, through configuring,
// donating, setting the parameter and invalidating, each status read once TipKit has caught
// up (Apple's updates status asynchronously). Compared between Apple's TipKit and Finch's.
//
//   build/userland/finch-tipkit-test

import Foundation
import SwiftUI
import TipKit

struct ConverterTip: Tip {
    static let opened = Event(id: "openedConverter")
    @Parameter static var isPro: Bool = false
    var title: Text { Text("Convert units") }
    var message: Text? { Text("Choose Convert in the View menu.") }
    var image: Image? { Image(systemName: "arrow.left.arrow.right") }
    var rules: [Rule] {
        #Rule(Self.opened) { $0.donations.count >= 2 }
        #Rule(Self.$isPro) { $0 == true }
    }
    var options: [any TipOption] { MaxDisplayCount(3) }
}

struct PlainTip: Tip {
    var title: Text { Text("Plain") }
}

var info = Dl_info()
dladdr(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "$s6TipKit4TipsO9configureyySayAC19ConfigurationOptionVGKFZ"), &info)
print(info.dli_fname.map { String(cString: $0) } ?? "?")

// Each run uses its own temporary folder; leave the default store alone.
let tip = ConverterTip(), plain = PlainTip()
print("before configure", tip.status, plain.status, plain.shouldDisplay)
try Tips.configure([.displayFrequency(.immediate), .datastoreLocation(.url(URL(fileURLWithPath: NSTemporaryDirectory() + "tipkit-test-\(getpid())")))])
do { try Tips.configure() } catch { print("configure twice:", error) }
try await Task.sleep(for: .seconds(1))
print("configured", tip.status, plain.status)
await ConverterTip.opened.donate()
try await Task.sleep(for: .seconds(1))
print("1 donation", tip.status, ConverterTip.opened.donations.count)
await ConverterTip.opened.donate()
try await Task.sleep(for: .seconds(1))
print("2 donations", tip.status)
ConverterTip.isPro = true
try await Task.sleep(for: .seconds(1))
print("pro", tip.status, tip.shouldDisplay, tip.id)
tip.invalidate(reason: .tipClosed)
try await Task.sleep(for: .seconds(1))
print("closed", tip.status)
plain.invalidate(reason: .actionPerformed)
try await Task.sleep(for: .seconds(1))
print("plain", plain.status)
print("actions", tip.actions.count, "options", tip.options.count)
