# PDFKit

Finch's PDFKit is an Objective-C framework built on Finch CoreGraphics, CoreText and
AppKit. It uses manual retain and release, like the nearby frameworks. The build uses
the macOS 26.4 SDK headers for declarations, then installs only Finch's implementation;
it does not copy SDK headers, module maps or API notes into the source tree or Finch
image. No Apple framework binary or closed implementation code is included.

`PDFDocument` reads PDFs from data or a file URL. It exposes pages, metadata, page
permissions, outlines, search results and selections. `PDFPage` reads page boxes,
rotation and annotations, draws through CoreGraphics, makes thumbnails, and extracts
text. Text extraction reads each PDF font's Unicode map and uses CoreText for glyph
measurements. `findString:withOptions:` searches that extracted text. The asynchronous
find calls post the document and page notifications as they scan.

The current `PDFView` draws the selected page in an AppKit view. It supports page
navigation and history, display and scale settings, zoom, selection and printing.
`PDFThumbnailView` draws page thumbnails and marks the current page. These views do not
yet match every PDFKit layout mode, delegate callback or annotation interaction.

PDFKit reads basic annotations, including link rectangles and URI actions. It can save
an unchanged file byte for byte. After a document changes, it rebuilds the pages through
`CGPDFContext` and writes outlines plus simple URI links with the default border. If an
annotation has other fields, another action, or a different border, saving returns no
data instead of silently dropping that information. Generic annotations, forms,
encrypted writes, incremental saves and PDF features that need appearance streams are
not supported yet.

Quartz's umbrella framework re-exports the top-level PDFKit binary, as the SDK does.
The build order places PDFKit after AppKit and before Quartz. `pdfkit-test` creates a
two-page PDF with CoreGraphics, then compares text search, links, an outline, saving,
reopening and page navigation against Apple's framework.

The API report for the macOS 26.4 SDK finds 371 of 562 PDFKit items present (66.0%).
The Quartz/PDFKit view reports the same count. The report checks whether names are
present, not whether they behave correctly; the host comparison checks the behavior
listed above. Most annotation subclasses, delegate methods, newer view helpers and
specialized PDF features remain absent.
