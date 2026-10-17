// SPDX-License-Identifier: MIT OR Apache-2.0
import Foundation
import WidgetKit

private struct TestEntry: TimelineEntry {
    let date: Date
}

@main
private struct WidgetKitTest {
    static func main() async {
        if #available(macOS 15.0, *) {
            print(Bundle(for: WidgetCenter.self).bundleURL.path)
            let date = Date(timeIntervalSince1970: 1_800_000_000)
            let timeline = Timeline(entries: [TestEntry(date: date)], policy: .after(date))
            let configurations: (Bool, Int, String)
            do {
                configurations = (true, try await WidgetCenter.shared.currentConfigurations().count, "")
            } catch {
                let failure = error as NSError
                configurations = (false, -1, "\(failure.domain):\(failure.code)")
            }
            let callbackResult: (Bool, Int, String) = await withCheckedContinuation { continuation in
                WidgetCenter.shared.getCurrentConfigurations { result in
                    switch result {
                    case .success(let values): continuation.resume(returning: (true, values.count, ""))
                    case .failure(let error):
                        let failure = error as NSError
                        continuation.resume(returning: (false, -1, "\(failure.domain):\(failure.code)"))
                    }
                }
            }
            print("timeline entries=\(timeline.entries.count) date=\(Int(timeline.entries[0].date.timeIntervalSince1970)) policy=\(timeline.policy == .after(date))")
            print("widget family=\(WidgetFamily.systemSmall.rawValue) configurations=\(configurations.0)/\(configurations.1)/\(configurations.2) callback=\(callbackResult.0)/\(callbackResult.1)/\(callbackResult.2)")
            print("rendering=\(WidgetRenderingMode.fullColor),\(WidgetRenderingMode.accented),\(WidgetRenderingMode.vibrant) equal=\(WidgetRenderingMode.fullColor == .fullColor)")
            print("accented modes=\(WidgetAccentedRenderingMode.accented == .accented),\(WidgetAccentedRenderingMode.desaturated == .desaturated),\(WidgetAccentedRenderingMode.accentedDesaturated == .accentedDesaturated),\(WidgetAccentedRenderingMode.fullColor == .fullColor)")
            if #available(macOS 26.0, *) {
                print("push info=\(await WidgetCenter.shared.currentPushInfo == nil)")
            }
        }
    }
}
