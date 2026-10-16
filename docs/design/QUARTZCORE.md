# QuartzCore (Core Animation)

Updated 2026-10-16.

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

## API coverage and app imports

On the macOS 26.4 SDK, the QuartzCore audit reported 1,607 of 3,413 items
present before this work and 1,617 present afterward. The missing count moved
from 1,806 to 1,796. The increase includes a fix to the audit tool: it now reads
Objective-C methods with unlabeled arguments correctly. The implementation
adds software CGL rendering for `CAOpenGLLayer` and `CARenderer`, the `NSValue`
CATransform3D category, corner-curve expansion lookup, the Metal renderer
option key, and the automatic dynamic-range value.

The audit follows QuartzCore's public re-exports, so its missing count also
includes CoreImage APIs. It still lists display controls, remote layers and
Metal-only paths. Those need services or hardware Finch does not provide. The
SDK-only `CAEAGLLayer` entry is unavailable on macOS. `CALayerDelegate` is built
into a client when that client uses `@protocol(CALayerDelegate)`; the comparison
test checks its optional callback descriptions in that normal use.

The app scan on this Mac no longer reports missing `CAOpenGLLayer` or
`CARenderer` imports. Ten app bundles still have a QuartzCore import Finch does
not provide: eight import private `CALayerHost` for remote layer content,
Music imports private `CAMeshTransform`, and Weather imports private
`CADisplay`. Finch leaves these out because it has no matching private service.

## Checks

`userland/tests/quartzcore-test.m` compares transforms, timing functions,
corner curves, delegate protocols, constants, the OpenGL layer callbacks and
the CGL renderer API with Apple's framework. The Finch-only
`quartzcore-renderer-test` checks the actual software-rendered pixel values.
`calayer-test` compares layer geometry, actions, animation objects and
CoreGraphics drawing with Apple.

The 2026-10-16 host run passed `quartzcore-test`, `quartzcore-renderer-test`,
`calayer-test`, `appkit-core-test`, `appkit-draw-test`, `cg-test`, and all eleven
window-server expected-output tests. No VM test was run.
