# Six small framework images

These images cover app imports that Finch previously could not load at all. Each build uses declarations from the macOS SDK at compile time. Finch does not ship those headers or Apple's binaries.

The API coverage tool finds 712 of 1,433 items across the six images. That count records names and selectors found in the images; the host comparisons below check behavior for the cases they exercise.

| Image | Present | Main behavior checked |
|---|---:|---|
| MediaPlayer | 275 / 635 | Now-playing state, command targets, artwork, and item keys |
| MediaAccessibility | 41 / 53 | Caption defaults, profiles, selected languages, and image-captioning errors |
| CoreBluetooth | 136 / 225 | UUID parsing, GATT values, constants, and unsupported manager callbacks |
| libsandbox.1.dylib | 7 / 27 | Unsandboxed checks, local extension tokens, and parameter storage |
| CryptoTokenKit | 154 / 221 | BER, Simple, and Compact TLV records, token values, and PIN formatting |
| WidgetKit | 99 / 272 | Timeline values, rendering modes, no-host results, and push info |

## MediaPlayer

`MPNowPlayingInfoCenter` keeps the current dictionary and playback state in the process. `MPRemoteCommandCenter` exposes its command objects and records target handlers. Artwork requests render from Finch `NSImage` values at the requested, bounds-limited size.

Finch has no menu-bar now-playing service, and its window server does not report media-key events to these commands. The app can still read and update its state or invoke a command directly.

## MediaAccessibility

Caption appearance reads the user's accessibility preferences and uses Apple's default values when a setting is absent. Profile names, active profiles, profile-scoped reads, selected languages, and the image-caption metadata key match the host comparison.

Finch has no image-captioning model. Captioning requests report the same unavailable error as Apple does when its service is absent.

## CoreBluetooth

`CBUUID` parses short, wide, and full UUID forms, expands Bluetooth base UUIDs, and compares the normalized bytes. Mutable services, characteristics, descriptors, and L2CAP value types keep their public values.

Central and peripheral managers report `CBManagerStateUnsupported`. They deliver the state callback on the requested queue. Authorization and error values match the host comparison. Finch has no Bluetooth radio, so scans return no devices and no channels open.

## libsandbox.1.dylib

Finch currently runs apps without per-process sandbox enforcement. `sandbox_is_sandboxed` reports that state, and `sandbox_check` allows valid requests. File and generic extension tokens are random, process-local values that can be consumed and released. Parameter sets hold copied key/value pairs. The profile compiler is not available, so compile requests and attempts to install a sandbox profile return `ENOTSUP` with an error string.

This compatibility library does not change the sandbox client or the future kernel policy described in `SANDBOX.md`, and it does not claim that Finch apps are sandboxed.

## CryptoTokenKit

The watcher reports no tokens; the smart-card slot manager is absent and reports no slots. BER, Simple, and Compact TLV records parse and encode their formats. Token keychain values and `TKSmartCardPINFormat` hold their public data, with the defaults and property changes checked against Apple.

Finch has no card reader or token service. It does not create smart cards or report a token that is not present.

## WidgetKit

Timeline entries, reload policies, provider protocols, widget families, rendering modes, and `WidgetInfo` are Swift values. `WidgetCenter` returns Apple's no-host error for configuration requests and no current push info.

The SDK declares `Widget` and `WidgetConfiguration` in Finch's SwiftUI module. This task forbids changes to SwiftUI, so those protocols and configuration builders remain unsupported. Finch does not have a widget host to display or schedule widgets.

## Tests

`tools/host-tests.sh` compares `media-player-test`, `media-accessibility-test`, `corebluetooth-test`, `libsandbox-test`, `cryptotokenkit-test`, and `widgetkit-test` with Apple's output. Finch-only tests check unsupported Bluetooth state and the empty token/slot state.

The app sweep now finds no missing `libsandbox` or CryptoTokenKit imports. It still finds five apps looking for the separate iOS support copy of MediaPlayer and eight looking for the iOS support copy of WidgetKit; this build provides the regular macOS framework images. It also finds missing MediaPlayer symbols in Music (413 imports), MediaAccessibility symbols in Preview (2), and CoreBluetooth symbols in Find My and VoiceOver Utility (7 total).
