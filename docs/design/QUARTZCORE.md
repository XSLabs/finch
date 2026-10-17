# QuartzCore (Core Animation)

Updated 2026-10-17.

Finch builds its own `QuartzCore.framework` from `userland/QuartzCore`. It uses
manual retain and release, like Finch's Foundation and AppKit. It does not use
Apple's QuartzCore binary or copy Apple's closed code.

## How it works

`CALayer` keeps a layer tree in the app process. It handles layer geometry,
contents, drawing, layout, actions and animation objects. Finch's AppKit tells
the view that owns a layer when its contents need a redraw. `renderInContext:`
draws a layer tree into a CoreGraphics bitmap. Shape, gradient and text layers
draw through CoreGraphics and CoreText. Replicator layers draw their copies.

Animations keep their values and callbacks, but Finch has no render server or
animation clock to play them. An added animation is removed after a short turn
and its delegate is told that it did not finish. `presentationLayer` returns
nil, `modelLayer` returns the layer itself, and layer timing setters do not
change a clock. `CADisplayLink` uses a run-loop timer, so its ticks are not tied
to screen refresh.

`CAEmitterLayer` and `CAEmitterCell` keep their settings, but do not emit
particles. `CAMetalLayer` keeps its public settings, but there is no Metal
device and `nextDrawable` returns nil.

## OpenGL rendering

`CAOpenGLLayer` creates a CGL context and calls the subclass's drawing methods.
Finch's software CGL hook gives Mesa a memory-backed drawable. QuartzCore copies
those pixels into a CoreGraphics image and composites it with the other layer
contents. The hook is Finch's own; Apple's CGL has no such entry points.

`CARenderer` accepts a CGL context, draws its layer tree into a CoreGraphics
bitmap, then copies the bitmap into the context with OpenGL. It tracks the union
of requested update rectangles, but each render draws the full bounds. Its next
frame time is infinite because it has no animation clock.

The renderer honors its CoreGraphics color-space option. The Metal texture and
Metal command-queue paths are unavailable without a Metal device. The OpenGL
layer stores asynchronous and extended-range settings, but does not schedule
asynchronous drawing or produce extended-range pixels.

## CoreImage typed filters

Finch's CoreImage filters render pixels on the CPU. Its typed built-ins use the
SDK's filter protocols for filters Finch implements. The SDK factory methods
resolve to the same filter registry, and typed properties read and write the
same input values as `valueForKey:`. Property types come from the protocol
metadata, including properties inherited from parent protocols.
Factory methods still return only filters in Finch's registry. `CIBloom`,
`CIColorThresholdOtsu`, `CICannyEdgeDetector`, `CILineOverlay`, `CIXRay`,
`CIThermal` and the photo-effect presets stay unregistered because the current
pixel code did not match Apple's behavior.

The comparison tests cover scalar, point, rectangle, transform, object, vector
and color-space properties. They also compare output pixels for color
posterize, vibrance, rectangle morphology, an identity color cube and an
identity convolution. `CIContext.offlineGPUCount` returns zero because Finch's
CoreImage renderer cannot use an offline GPU.

## API coverage and app imports

On the macOS 26.4 SDK, the 2026-10-16 QuartzCore audit reported 1,607 of 3,413
items present before the CGL and Core Animation updates and 1,617 afterward.
The missing count moved from 1,806 to 1,796. That increase includes a fix to
the audit tool: it now reads Objective-C methods with unlabeled arguments
correctly. The work added software CGL rendering for `CAOpenGLLayer` and
`CARenderer`, the `NSValue` CATransform3D category, corner-curve expansion
lookup, the Metal renderer option key, and the automatic dynamic-range value.

The 2026-10-17 audit reports 2,276 of 3,413 QuartzCore items present, up 659
from 1,617, with 1,137 still missing. The direct CoreImage audit reports 1,399
of 1,899 present, up 600 from 799, with 500 still missing. QuartzCore's SDK
stub re-exports CoreImage, so Finch's QuartzCore build now re-exports Finch's
CoreImage framework too.

The audit follows QuartzCore's public re-exports, so its missing count also
includes CoreImage APIs. It still lists display controls, remote layers and
Metal-only paths. Those need services or hardware Finch does not provide. The
SDK-only `CAEAGLLayer` entry is unavailable on macOS. `CALayerDelegate` is built
into a client when that client uses `@protocol(CALayerDelegate)`; the comparison
test checks its optional callback descriptions in that normal use.

The 2026-10-16 app scan on this Mac no longer reported missing `CAOpenGLLayer` or
`CARenderer` imports. Ten app bundles still have a QuartzCore import Finch does
not provide: eight import private `CALayerHost` for remote layer content,
Music imports private `CAMeshTransform`, and Weather imports private
`CADisplay`. Finch leaves these out because it has no matching private service.

## Checks

`userland/tests/coreimage-test.m` compares typed filter properties and selected
filter output pixels with Apple's framework. `userland/tests/quartzcore-test.m`
also checks that a typed Gaussian blur filter works through QuartzCore's
CoreImage re-export, along with transforms, timing functions, corner curves,
delegate protocols, constants, OpenGL layer callbacks and the CGL renderer API.
The Finch-only
`quartzcore-renderer-test` checks the actual software-rendered pixel values.
`calayer-test` compares layer geometry, actions, animation objects and
CoreGraphics drawing with Apple.

The 2026-10-17 host run passed `coreimage-test`, `constants-test`,
`quartzcore-test` and `calayer-test`. The 2026-10-16 host run passed
`quartzcore-test`, `quartzcore-renderer-test`,
`calayer-test`, `appkit-core-test`, `appkit-draw-test`, `cg-test`, and all eleven
window-server expected-output tests. No VM test was run.
