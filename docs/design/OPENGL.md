# OpenGL

Apple deprecated OpenGL in macOS 10.14 but still ships it, and older apps and some
system apps (Grapher, Chess, ColorSync Utility) link it. Finch's OpenGL.framework keeps
Apple's layout: an `OpenGL` binary that re-exports `Libraries/libGL.dylib` and
`Libraries/libGLU.dylib`.

## Pieces

| Piece | Source | What it does |
|---|---|---|
| `libGL.dylib` | Mesa 25.0.7, built by `userland/OpenGL/mesa.sh` | The GL entry points and the renderer: softpipe (Gallium's CPU rasterizer) through OSMesa, with no LLVM. |
| `OpenGL` (CGL) | `userland/OpenGL/CGL.c`, Finch's own | CGL's pixel formats, renderer info, contexts, the current context and parameters, over OSMesa contexts. It reports one renderer, a software one, and refuses `CGLSetOffScreen` with `kCGLBadOffScreen`, as Apple silicon Macs do. |
| `libGLU.dylib` | `userland/OpenGL/GLU.c`, Finch's own | Projections, project/unproject, pick matrices, quadrics, mipmap building, error and version strings. No tessellator or NURBS yet. |
| `NSOpenGLPixelFormat`, `NSOpenGLContext`, `NSOpenGLView` | `userland/AppKit/NSOpenGL.m` | AppKit's classes. AppKit loads OpenGL lazily (`dlopen`) so apps that don't use GL don't pay for Mesa. |

## Drawing into windows

A context attached to a view (`-setView:`) renders into an OSMesa buffer the size of the
view's backing. `-flushBuffer` reads the pixels (`FinchCGLGetPixels`, SPI between the
two frameworks) into a CGImage that the view keeps; the view draws that image after
`-drawRect:`, inside its normal display pass, so the window server composites GL content
like any other drawing, but after the rest of the window's views: as on macOS, a GL
surface shows above the window's ordinary drawing (including the GL view's own subviews)
unless its context's surface order is -1, which puts it under its view's siblings. A
view that isn't opaque, or a surface opacity of 0, composites the frame with its alpha.
A flush outside a display pass (a timer, an animation) marks the view for display.
`-prepareOpenGL`, `-reshape` and `-drawRect:` come in Apple's order. `FINCH_DEBUG_GL=1`
traces drawables and flushes and saves the last frame to `/tmp/finch-gl-last.png`.

## Limits

- Legacy (2.1-style) contexts only; Apple's 3.2 and 4.1 core profiles aren't offered yet.
- CPU rendering: fine for the small scenes the system apps draw, slow for games.
- Hardware rendering waits for a device (Metal's or a GPU driver).

## Tests

- `opengl-test`: CGL pixel formats and contexts, clears, geometry, depth, display lists,
  GLU projection and quadrics, lighting, picking, errors; compared with Apple's.
- `appkit-opengl-test`: an `NSOpenGLView` on the headless window server (call order,
  pixels on screen, resizing, a timer-driven redraw); Finch-only, with an expected file.
