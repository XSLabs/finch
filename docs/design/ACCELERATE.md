# Accelerate

Apple's Accelerate framework is an umbrella for vector math, image work,
matrix math and neural-network routines. Finch now builds its own
`Accelerate.framework` at Apple's install path. The framework contains the
calls imported by the apps found on this Mac today.

## What works today

The framework exports the app-used symbols listed in
`userland/Accelerate/exports.txt`:

- vDSP vector math, filters, complex-number packing and FFTs;
- vForce vector functions for square root, sine/cosine and `atan2`;
- vImage scaling, convolution, channel transforms, table lookups, histograms
  and conversion between image buffers and CoreGraphics images;
- the imported CBLAS calls and the `sscal_`, `sgemv_`, `dgels_`, `dgetrf_`,
  `dgetri_` and `dgtsv_` routines.

These are Finch's own C routines. FFTs with radix 3 or 5 use a direct discrete
Fourier transform, which is correct for the supported sizes but slower than a
fast FFT. Image scaling can differ from Apple's by one byte because of rounding.

This is not the full Accelerate API. BNNS, sparse solvers and public functions
not imported by the scanned apps are not implemented. The app scan only covers
apps and bundled programs installed on the Mac used to build Finch.

## Build and check

`tools/build-system.sh Accelerate` builds the framework after CoreGraphics and
ImageIO. It installs `Versions/A/Accelerate` with Apple's install name and the
usual framework links. Finch's vImage image conversions use Finch's
CoreGraphics; the rest use libSystem and the math library.

`userland/tests/accelerate-test.c` runs the same calls against Apple's
framework and Finch's. `tools/host-tests.sh accelerate-test` compares their
printed results. Floating-point values are printed to three decimal places;
the planar scaling case accepts a one-byte difference. All routines here were
written for Finch. No Apple binary, closed Apple code or outside source code
was copied, so Accelerate adds no third-party package or licence notice.
