# Accelerate

Apple's Accelerate framework is an umbrella for vector math, image work,
matrix math and neural-network routines. Finch builds its own
`Accelerate.framework` at Apple's install path, laid out as Apple's:

```
Accelerate.framework/Versions/A/Accelerate          re-exports vecLib and vImage
  Frameworks/vecLib.framework/Versions/A/vecLib     re-exports the libraries below
    libvDSP.dylib     all of vDSP
    libvMisc.dylib    vForce (the calls apps import)
    libBLAS.dylib     CBLAS and BLAS (the calls apps import)
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

## The rest

vForce, vImage, BLAS and LAPACK still have only the calls imported by the apps
found on this Mac: vForce's square root, sine/cosine and `atan2`; vImage
scaling, convolution, channel transforms, table lookups, histograms and
conversion between image buffers and CoreGraphics images; the imported CBLAS
calls and the `sscal_`, `sgemv_`, `dgels_`, `dgetrf_`, `dgetri_` and `dgtsv_`
routines. BNNS, sparse solvers, LinearAlgebra and Quadrature are not
implemented. Complete BLAS and LAPACK are planned from a permissively licensed
implementation.

## Build and check

`tools/build-system.sh Accelerate` builds the framework after CoreGraphics and
ImageIO. Finch's vImage image conversions use Finch's CoreGraphics; the rest
use libSystem and the math library. Test runners put the nested frameworks
(`Accelerate.framework/Versions/A/Frameworks`) on `DYLD_FRAMEWORK_PATH` and
vecLib's folder on `DYLD_LIBRARY_PATH`, as dyld finds those by leaf name.

`userland/tests/accelerate-test.c` and `userland/tests/vdsp-test.c` run the
same calls against Apple's framework and Finch's, and `tools/host-tests.sh`
compares their printed results. All routines here were written for Finch. No
Apple binary, closed Apple code or outside source code was copied, so
Accelerate adds no third-party package or licence notice.
