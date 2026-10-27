# Accelerate

Apple's Accelerate framework is an umbrella for vector math, image work,
matrix math and neural-network routines. Finch builds its own
`Accelerate.framework` at Apple's install path, laid out as Apple's:

```
Accelerate.framework/Versions/A/Accelerate          re-exports vecLib and vImage
  Frameworks/vecLib.framework/Versions/A/vecLib     re-exports the libraries below
    libvDSP.dylib     all of vDSP
    libvMisc.dylib    vForce, vfp, vBasicOps, vBigNum, vectorOps
    libBLAS.dylib     BLAS levels 1-3: CBLAS and Fortran, in every ABI
    libLAPACK.dylib   LAPACK (the calls apps import)
  Frameworks/vImage.framework/Versions/A/vImage     vImage (the calls apps import)
```

Each library exports the symbols Apple's `.tbd` for it lists and Finch defines
(`userland/Accelerate/tbd-exports.py`), so a symbol is always found in the
library that has it on macOS.

## vDSP

`userland/Accelerate/vDSP/` implements every public vDSP function of the SDK
baseline (469), in single and double precision:

- `vector.c`: arithmetic, scalar forms, clipping and thresholds, reductions
  (with index), dot products, sums, integration, interpolation and tables,
  ramps (including the fixed-point `vrampmul` forms), gathering, compression,
  sorting, decibels and polar/rectangular conversion;
- `convert.c`: conversions between floating point and 8-, 16-, 24- and 32-bit
  integers, and between single and double precision;
- `complex.c`: split-complex vectors, spectra, coherence, transfer functions,
  complex convolution and matrices, and interleaving;
- `fft.c`: FFT setups, complex and real FFTs (in place, out of place, multiple
  and two-dimensional, radix 2, 3 and 5), DFT and DCT setups and execution
  (planar and interleaved) and the fixed 16- and 32-point FFTs;
- `filter.c`: convolution, decimation, `deq22`, cascaded biquads (single and
  multi-channel, with coefficient ramps), image filters, Wiener-Levinson,
  windows and matrix multiply, transpose and copy.

They follow Apple's behaviour where it departs from `vDSP.h`'s pseudocode,
found by running Apple's routines:

- complex FFTs and DFTs are unscaled in both directions;
- real-to-complex transforms return twice the DFT, packed with the DC and
  Nyquist terms in element 0, and their inverses are unscaled;
- DFT and DCT setups accept only the lengths Apple's do (Apple's own DCT setup
  overruns memory on some lengths it rejects in `vDSP.h`);
- out-of-range float-to-integer conversions give the bit patterns Apple's
  vector code gives (a saturating 32- or 64-bit conversion, then the low
  bits), routine by routine;
- `vDSP_biquadm_SetActiveFilters` switches sections, not channels, and an
  inactive section passes its input through.

Transforms are computed in double precision by a radix-2 FFT combined with a
small DFT for the odd factor, so results agree with Apple's to rounding.

## vMisc

`userland/Accelerate/vMisc/` has all of libvMisc's public API:

- `vforce.c`: vForce's array functions in both precisions, also under their
  Fortran names (`vvexpf_`, `VVEXPF`, `VVEXPF_`);
- `vfp.c`: the `vFloat` functions of `vfp.h`;
- `bignum.c`: vBasicOps' lane arithmetic (8- to 128-bit lanes) and vBigNum's
  128- to 1024-bit numbers, as little-endian words; where `vBasicOps.h` speaks
  of big-endian "even" elements, those are the upper lanes, and shift counts
  come from byte 0 (and byte 8), as on Apple's;
- `vectorops.c`: vecLib's original BLAS over `vFloat` arrays.

Apple's give +0 for `sinpi` and `tanpi` at the integers (except double
`sinpi`, whose zero has the sign of x times (-1)^x) and +0 for zero
remainders, and `vsincosf` returns cosines and stores sines; Finch's do the
same. Apple's arm64 `vIsamax`, `vIsamin`, `vIsmax`, `vIsmin`, `vSnrm2`,
`vSgevv`, `vSndot` and `vSnaxpy` do not compute what `vectorOps.h` describes
(they return other indexes, a negative norm or leave their output alone);
Finch's follow the header. The 50 libvMisc symbols with no public declaration
(`vMultMatMat_4x4` and the like) are not provided.

## BLAS

`userland/Accelerate/BLAS/` is Finch's BLAS: levels 1, 2 and 3 in single,
double, complex and double complex precision (`blas-template.inc`, included
once per precision by `blas.c`), with the reference BLAS's algorithms, the
`catlas_` and `appleblas_` extensions and the mixed-precision dot products.
Every operation goes through a matrix descriptor (storage kind, triangle, unit
diagonal, transposed, conjugated), so a row-major CBLAS call is the
column-major one on the transpose with flags flipped, as the reference CBLAS
does it. A non-trivial op(A) is packed before multiplying.

Apple exports each routine under several names and ABIs: the legacy Fortran
ones (`sgemm_`, `sgemm`, `SGEMM`; 32-bit integers, and real functions return
`double` as `fortran_blas.h` says), `blas_new.h`'s (`sgemm$NEWLAPACK`, and
`$NEWLAPACK$ILP64` with 64-bit integers), and CBLAS in the same three forms.
Finch implements each once, with 64-bit integers; `BLAS/gen-abi.py` reads the
SDK's headers and Apple's `.tbd` at build time and writes a wrapper per
exported name (1,220).

Where Apple's departs from the reference BLAS, Finch's follows Apple's:
`herk` and `her2k` keep beta times the imaginary part of the diagonal rather
than zeroing it.

## vImage

`userland/Accelerate/vImage/` is Finch's vImage, one file per header area:
`convert.c`, `convert-channels.c`, `convert-10bit.c`, `convert-dither.c` and
`convert-ycbcr.c` (`Conversion.h`),
`alpha.c`, `morphology.c`, `histogram.c`, `convolution.c`, `transform.c`
(matrix multiply, gamma, lookup tables, piecewise functions) and `geometry.c`;
`common.h` holds the buffer checks and sample conversions they share, and
`legacy.c` the CoreGraphics interop (`vImageBuffer_InitWithCGImage`,
`vImageCreateCGImageFromBuffer`). `Alpha.h`, `Convolution.h`, `Histogram.h`,
`Morphology.h`, `Transform.h`, `Geometry.h` and `Conversion.h` are complete.

vImage's results are matched to Apple's, quirks included: its vector loops
(groups of four pixels) and scalar tails compute some operations differently,
and divisions use NEON's reciprocal estimate refined twice, so `common.h` has
both. Geometry follows Apple's design, where shears are the resampling core:
each line is resampled with a normalized Lanczos kernel at positions rounded to
64 phases a pixel (fewer when shrinking), scaling is two shears and rotation an
exact quarter turn then three shears. Those match Apple's in floating point;
Apple's 8- and 16-bit resamplers use fixed-point weights and can differ from
Finch's by one, and Finch's affine warp samples the inverse map directly,
within about a level of Apple's. Where Apple's departs from its header through
a bug (flood fills storing a 16-bit value's low byte twice, reads past a
buffer's edge), Finch follows the header, and the tests compare only result
codes there.

`convert-10bit.c` has the 10-bit RGB formats (RGBA1010102, XRGB2101010,
ARGB2101010), whose results Apple computes in fixed point in its vector loops
(groups of eight pixels) and with the header's or single-precision formulas in
the scalar tail; Finch does the same, so they match.

`convert-dither.c` has the dithered conversions and the 1-, 2- and 4-bit
planar and indexed formats. Ordered dithering adds Finch's own blue noise (a
64 by 64 void-and-cluster pattern made at first use), so it agrees with
Apple's in kind, not sample for sample. Apple's 2- and 4-bit conversions step
the destination by the source's `rowBytes` when not diffusing, writing past
a narrower destination; Finch's use the destination's.

`convert-ycbcr.c` has the Y'CbCr conversions (4:4:4, 4:2:2 and 4:2:0; 8, 10
and 16 bits) with Apple's arithmetic, worked out from its results: fixed point
for Y'CbCr to 8-bit RGB and for 8-bit RGB to 8-bit Y'CbCr, single precision
elsewhere (one apart from Apple's in a few 10- and 16-bit samples). The
generated conversions are Finch's own layout of the opaque structures.

`utilities.c` has `vImage_Utilities.h` and `BasicImageTypes.h`: buffer
allocation (with Apple's row padding), the `vImage_CGImageFormat` helpers, the
PNG decompression filter, and `vImageConverter` with `vImageConvert_AnyToAny`.
A converter reads any CG pixel format (byte orders, packed 16- and 32-bit
pixels, indexed colour, half and single floats, decode arrays) as double
precision, converts colour through ColorSync when the spaces differ, and
handles alpha as vImage's integer functions do (8- and 16-bit unpremultiplying,
narrowing first to an 8-bit destination). Within a colour space its results
match Apple's; Apple's dithers 5- and 6-bit destinations and rounds between 8
bits and half floats its own way. ColorSync code fragments and
`CGColorConversionInfo` converters run between the formats' own colour spaces.
vImage links ColorSync, which the system build now makes before Accelerate.

Still missing: `vImage_CVUtilities.h` (30 calls).

## The rest

LAPACK has only the calls imported by the apps found on this Mac: `dgels_`,
`dgetrf_`, `dgetri_` and `dgtsv_` (`LAPACK/lapack.c`). BNNS, sparse solvers,
LinearAlgebra and Quadrature are not implemented. Complete LAPACK is planned
from a permissively licensed implementation.

## Build and check

`tools/build-system.sh Accelerate` builds the framework after CoreGraphics and
ImageIO. Finch's vImage image conversions use Finch's CoreGraphics; the rest
use libSystem and the math library. Test runners put the nested frameworks
(`Accelerate.framework/Versions/A/Frameworks`) on `DYLD_FRAMEWORK_PATH` and
vecLib's folder on `DYLD_LIBRARY_PATH`, as dyld finds those by leaf name.

`userland/tests/accelerate-test.c`, `vdsp-test.c`, `vmisc-test.c`, `blas-test.c` and
`vimage-test.c` run the
same calls against Apple's framework and Finch's, and `tools/host-tests.sh`
compares their printed results. All routines here were written for Finch. No
Apple binary, closed Apple code or outside source code was copied, so
Accelerate adds no third-party package or licence notice.
