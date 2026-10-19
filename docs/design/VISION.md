# Vision

Finch Vision builds against the macOS SDK headers. The build uses those headers but does
not install them. The framework is written in Objective-C with manual retain and release.

`VNImageRequestHandler` accepts Core Graphics images, Core Image images, pixel buffers,
image data, URLs, and sample buffers. It applies image orientation, keeps request settings,
checks each request revision, runs supported work on the CPU, and stores results on the
request. Sequence handlers keep the previous image and use it to track translation between
frames. Region settings are used by the supported detection requests.

## What works

- Geometry values and image-coordinate helpers use Vision's normalized coordinate system.
- Rectangle requests find dark connected outlines and return their corner points. This is a
  simple, axis-aligned detector. It does not estimate perspective or match Apple's results
  on every image.
- Barcode requests decode QR Code version 1 payloads in byte, numeric, and alphanumeric
  modes. Other QR versions and other barcode types return no decoded payload or an explicit
  unsupported-request error; Finch does not claim to read them.
- Contour requests find dark connected components and return their bounding outline. They
  do not trace curved edges or build inner contours for holes.
- Horizon requests look for a long dark line and check that the image has different average
  brightness above and below it. This does not replace Apple's scene model.
- Image registration finds a pixel translation by comparing image samples. The homography
  requests currently return that same translation in a matrix; they do not solve for
  rotation, scale, or perspective.
- Feature-print observations store numeric values and compare matching arrays. Finch has no
  model to generate Apple's image feature prints.

Face, landmark, text, classification, animal, body-pose, saliency, and segmentation requests
need models Finch does not ship. They return `VNErrorUnsupportedRequest` (or
`VNErrorUnsupportedRevision` when the revision itself is invalid); they never return made-up
observations. Core ML model requests also fail clearly. The macOS SDK exposes no public image
histogram request, so Finch does not add one.

The API coverage report finds 603 of 2,674 Vision items present, with 51 behavior-verified
through the focused host test. The count of present items records declarations and exported
symbols; it is not a claim that every item has Apple's behavior. The test checks geometry, a
rectangle, QR payload decoding, empty contours, a line-only horizon image, translation
registration, two-frame sequence tracking, and an invalid revision. It prints values rounded
to three decimals. The host comparison allows at most 0.015 normalized units and 0.03
confidence for rectangle results, and 0.005 for QR bounds and confidence. It compares every
other output exactly. Finch's Core Image does not yet include `CIQRCodeGenerator`, so the
test uses its fixed `FINCH` QR pattern when that filter is missing; Apple's run uses the
filter directly.

The app sweep no longer lists Vision as a missing framework. Before this framework was
added, Vision blocked 13 checked apps; some of those apps still need other frameworks.

Build with `userland/Vision/build.sh` after Foundation, CoreGraphics, CoreMedia, CoreVideo,
ImageIO, and Core Image. The framework is registered in `tools/build-system.sh` after those
dependencies. Run the comparison directly with `tools/host-tests.sh vision-test` so the
Finch framework paths stay available to dyld.
