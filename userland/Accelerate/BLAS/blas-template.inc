/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * One precision of Finch's BLAS, included by blas.c with P (s, d, c or z), T (the
 * element type), R (its real type) and CPLX (1 for complex) defined.
 *
 * Everything is computed through matrix descriptors (Mat): a storage kind (general,
 * banded, symmetric, Hermitian or triangular; full, banded or packed), the stored
 * triangle, a unit diagonal, and whether the matrix is used transposed and/or
 * conjugated. Row-major CBLAS calls become the column-major ones on the transpose by
 * flipping those flags, as the reference CBLAS does.
 *
 * The Fortran-convention entry points are finch_<name>_ (BLAS's names, ILP64 integers
 * by pointer); the CBLAS ones finch_cblas_<name> (ILP64 integers by value). abi.c,
 * generated from the SDK's headers, exports them under Apple's names and ABIs.
 */

#define CAT_(a, b) a##b
#define CAT(a, b) CAT_(a, b)
#define F(name) CAT(CAT(finch_, P), CAT(name, _))     /* finch_sgemm_ */
#define CB(name) CAT(CAT(finch_cblas_, P), name)      /* finch_cblas_sgemm */
#define IN(name) CAT(CAT(blas_, P), name)             /* internal */

#if CPLX
#define CONJ(v) CAT(conj, RS)(v)
#define REALP(v) CAT(creal, RS)(v)
#define IMAGP(v) CAT(cimag, RS)(v)
#define ABS1(v) (CAT(fabs, RS)(REALP(v)) + CAT(fabs, RS)(IMAGP(v)))
#else
#define CONJ(v) (v)
#define REALP(v) (v)
#define IMAGP(v) ((R)0)
#define ABS1(v) CAT(fabs, RS)(v)
#endif
#define RABS(v) CAT(fabs, RS)(v)
#define RSQRT(v) CAT(sqrt, RS)(v)

typedef struct {
    const T *a;
    long ld, n; /* n: order, for packed storage */
    int kind;
    int upper, unit, trans, conj;
    long kl, ku; /* bands (ku also the k of symmetric and triangular bands) */
} IN(Mat);

/* the stored element (i, j), which the caller knows to be in the stored part */
static inline T IN(raw)(const IN(Mat) *m, long i, long j)
{
    switch (m->kind) {
    case K_GB:
        return m->a[m->ku + i - j + j * m->ld];
    case K_SB:
    case K_HB:
    case K_TB:
        return m->upper ? m->a[m->ku + i - j + j * m->ld] : m->a[i - j + j * m->ld];
    case K_SP:
    case K_HP:
    case K_TP:
        return m->upper ? m->a[i + j * (j + 1) / 2] : m->a[i + (2 * m->n - j - 1) * j / 2];
    default:
        return m->a[i + j * m->ld];
    }
}

/* element (i, j) of op(A) */
static T IN(elem)(const IN(Mat) *m, long i, long j)
{
    if (m->trans) {
        long t = i;
        i = j;
        j = t;
    }
    T v;
    switch (m->kind) {
    case K_GE:
        v = m->a[i + j * m->ld];
        break;
    case K_GB:
        if (i - j > m->kl || j - i > m->ku)
            return 0;
        v = IN(raw)(m, i, j);
        break;
    case K_SY:
    case K_SB:
    case K_SP:
    case K_HE:
    case K_HB:
    case K_HP: {
        int band = m->kind == K_SB || m->kind == K_HB, herm = m->kind == K_HE || m->kind == K_HB || m->kind == K_HP;
        if (band && (i - j > m->ku || j - i > m->ku))
            return 0;
        int stored = m->upper ? i <= j : i >= j;
        v = stored ? IN(raw)(m, i, j) : IN(raw)(m, j, i);
        if (herm) {
            if (i == j)
                v = REALP(v);
            else if (!stored)
                v = CONJ(v);
        }
        break;
    }
    default: { /* triangular */
        int stored = m->upper ? i <= j : i >= j;
        if (!stored || (m->kind == K_TB && (i - j > m->ku || j - i > m->ku)))
            return 0;
        if (i == j && m->unit)
            return 1;
        v = IN(raw)(m, i, j);
        break;
    }
    }
    return m->conj ? CONJ(v) : v;
}

static IN(Mat) IN(mat)(int kind, const T *a, long ld)
{
    IN(Mat) m = {.a = a, .ld = ld, .kind = kind};
    return m;
}

/* MARK: - Level 1 */

static long IN(iamax)(long n, const T *x, long incx)
{
    if (n < 1 || incx <= 0)
        return 0;
    long best = 0;
    R top = ABS1(x[0]);
    for (long i = 1; i < n; ++i) {
        R v = ABS1(x[i * incx]);
        if (v > top || (isnan(v) && !isnan(top))) {
            top = v;
            best = i;
        }
    }
    return best + 1;
}

static R IN(asum)(long n, const T *x, long incx)
{
    R sum = 0;
    if (n < 1 || incx <= 0)
        return 0;
    for (long i = 0; i < n; ++i)
        sum += ABS1(x[i * incx]);
    return sum;
}

static R IN(nrm2)(long n, const T *x, long incx)
{
    if (n < 1 || incx <= 0)
        return 0;
    R scale = 0, ssq = 1;
    for (long i = 0; i < n; ++i) {
        R parts[2] = {REALP(x[i * incx]), IMAGP(x[i * incx])};
        for (int k = 0; k < 1 + CPLX; ++k) {
            if (parts[k] != 0) {
                R a = RABS(parts[k]);
                if (scale < a) {
                    ssq = 1 + ssq * (scale / a) * (scale / a);
                    scale = a;
                } else
                    ssq += (a / scale) * (a / scale);
            }
        }
    }
    return scale * RSQRT(ssq);
}

static void IN(axpby)(long n, T alpha, const T *x, long incx, T beta, T *y, long incy)
{
    for (long i = 0; i < n; ++i) {
        T *yi = &y[IX(i, incy, n)];
        T xi = x[IX(i, incx, n)];
        *yi = beta == 0 ? alpha * xi : alpha * xi + beta * *yi;
    }
}

static void IN(copy)(long n, const T *x, long incx, T *y, long incy)
{
    for (long i = 0; i < n; ++i)
        y[IX(i, incy, n)] = x[IX(i, incx, n)];
}

static void IN(swap)(long n, T *x, long incx, T *y, long incy)
{
    for (long i = 0; i < n; ++i) {
        T t = x[IX(i, incx, n)];
        x[IX(i, incx, n)] = y[IX(i, incy, n)];
        y[IX(i, incy, n)] = t;
    }
}

static void IN(scal)(long n, T alpha, T *x, long incx)
{
    if (incx <= 0)
        return;
    for (long i = 0; i < n; ++i)
        x[i * incx] *= alpha;
}

static void IN(set)(long n, T alpha, T *x, long incx)
{
    for (long i = 0; i < n; ++i)
        x[IX(i, incx, n)] = alpha;
}

/* sum of conj?(x) * y */
static T IN(dot)(long n, const T *x, long incx, const T *y, long incy, int conjx)
{
    T sum = 0;
    for (long i = 0; i < n; ++i) {
        T xi = x[IX(i, incx, n)];
        sum += (conjx ? CONJ(xi) : xi) * y[IX(i, incy, n)];
    }
    return sum;
}

/* plane rotation with real c and s */
static void IN(rot)(long n, T *x, long incx, T *y, long incy, R c, R s)
{
    for (long i = 0; i < n; ++i) {
        T *xi = &x[IX(i, incx, n)], *yi = &y[IX(i, incy, n)];
        T a = *xi, b = *yi;
        *xi = c * a + s * b;
        *yi = c * b - s * a;
    }
}

/* MARK: - Level 2 */

static void IN(scale_vector)(long n, T beta, T *y, long incy)
{
    if (beta == 1)
        return;
    for (long i = 0; i < n; ++i)
        y[IX(i, incy, n)] = beta == 0 ? 0 : beta * y[IX(i, incy, n)];
}

/* y = alpha * op(A) * x + beta * y, op(A) being rows by cols */
static void IN(mv)(const IN(Mat) *a, long rows, long cols, T alpha, const T *x, long incx, T beta, T *y, long incy)
{
    if (rows <= 0 || cols <= 0 || (alpha == 0 && beta == 1))
        return;
    IN(scale_vector)(rows, beta, y, incy);
    if (alpha == 0)
        return;
    if (a->kind == K_GE && !a->trans && !a->conj) {
        for (long j = 0; j < cols; ++j) {
            T t = alpha * x[IX(j, incx, cols)];
            const T *col = a->a + j * a->ld;
            for (long i = 0; i < rows; ++i)
                y[IX(i, incy, rows)] += t * col[i];
        }
        return;
    }
    for (long i = 0; i < rows; ++i) {
        T sum = 0;
        for (long j = 0; j < cols; ++j)
            sum += IN(elem)(a, i, j) * x[IX(j, incx, cols)];
        y[IX(i, incy, rows)] += alpha * sum;
    }
}

/* x = op(A) * x, A triangular */
static void IN(trmv)(const IN(Mat) *a, long n, T *x, long incx)
{
    if (n <= 0)
        return;
    T *t = malloc((size_t)n * sizeof(T));
    if (!t)
        return;
    for (long i = 0; i < n; ++i) {
        T sum = 0;
        for (long j = 0; j < n; ++j)
            sum += IN(elem)(a, i, j) * x[IX(j, incx, n)];
        t[i] = sum;
    }
    for (long i = 0; i < n; ++i)
        x[IX(i, incx, n)] = t[i];
    free(t);
}

/* solves op(A) * x = b in place, A triangular; x[i] is x + i*stride */
static void IN(trsv_strided)(const IN(Mat) *a, long n, T *x, long stride)
{
    int lower = a->trans ? a->upper : !a->upper; /* op(A) lower triangular */
    if (lower) {
        for (long i = 0; i < n; ++i) {
            T sum = x[i * stride];
            for (long j = 0; j < i; ++j)
                sum -= IN(elem)(a, i, j) * x[j * stride];
            x[i * stride] = a->unit ? sum : sum / IN(elem)(a, i, i);
        }
    } else {
        for (long i = n - 1; i >= 0; --i) {
            T sum = x[i * stride];
            for (long j = i + 1; j < n; ++j)
                sum -= IN(elem)(a, i, j) * x[j * stride];
            x[i * stride] = a->unit ? sum : sum / IN(elem)(a, i, i);
        }
    }
}

static void IN(trsv)(const IN(Mat) *a, long n, T *x, long incx)
{
    if (n <= 0)
        return;
    if (incx < 0)
        IN(trsv_strided)(a, n, x + (n - 1) * -incx, incx); /* element i at x + (n-1-i)*|incx| */
    else
        IN(trsv_strided)(a, n, x, incx);
}

/* A (rows by cols, column-major, lda) += alpha * x * op(y)^T, with optional conjugation
   of x and y */
static void IN(ger)(long rows, long cols, T alpha, const T *x, long incx, int conjx, const T *y, long incy, int conjy,
                    T *a, long lda)
{
    if (rows <= 0 || cols <= 0 || alpha == 0)
        return;
    for (long j = 0; j < cols; ++j) {
        T yj = y[IX(j, incy, cols)];
        T t = alpha * (conjy ? CONJ(yj) : yj);
        for (long i = 0; i < rows; ++i) {
            T xi = x[IX(i, incx, rows)];
            a[i + j * lda] += (conjx ? CONJ(xi) : xi) * t;
        }
    }
}

/* the address of stored element (i, j) of a symmetric or Hermitian matrix */
static T *IN(slot)(int kind, int upper, T *a, long lda, long n, long i, long j)
{
    if (kind == K_SP || kind == K_HP)
        return upper ? &a[i + j * (j + 1) / 2] : &a[i + (2 * n - j - 1) * j / 2];
    return &a[i + j * lda];
}

/* A += alpha * x * conj?(x)^T (+ conj?(alpha) * y * x^...) on the stored triangle:
   rank 1 (y NULL) or rank 2 updates of symmetric or Hermitian matrices */
static void IN(syr)(int kind, int upper, long n, T alpha, const T *x, long incx, const T *y, long incy, int conjx,
                    T *a, long lda)
{
    int herm = kind == K_HE || kind == K_HP;
    if (n <= 0 || alpha == 0)
        return;
    for (long j = 0; j < n; ++j) {
        long from = upper ? 0 : j, to = upper ? j : n - 1;
        for (long i = from; i <= to; ++i) {
            T xi = x[IX(i, incx, n)], xj = x[IX(j, incx, n)];
            if (conjx) {
                xi = CONJ(xi);
                xj = CONJ(xj);
            }
            T v;
            if (y) {
                T yi = y[IX(i, incy, n)], yj = y[IX(j, incy, n)];
                if (conjx) {
                    yi = CONJ(yi);
                    yj = CONJ(yj);
                }
                v = herm ? alpha * xi * CONJ(yj) + CONJ(alpha) * yi * CONJ(xj) : alpha * (xi * yj + yi * xj);
            } else
                v = herm ? alpha * xi * CONJ(xj) : alpha * xi * xj;
            T *s = IN(slot)(kind, upper, a, lda, n, i, j);
            *s += v;
            if (herm && i == j)
                *s = REALP(*s);
        }
    }
}

/* MARK: - Level 3 */

/* C (m by n, column-major) = alpha * op(A) * op(B) + beta * C, op(A) m by k */
static void IN(mm)(long m, long n, long k, T alpha, const IN(Mat) *a, const IN(Mat) *b, T beta, T *c, long ldc)
{
    if (m <= 0 || n <= 0)
        return;
    for (long j = 0; j < n; ++j)
        for (long i = 0; i < m; ++i)
            c[i + j * ldc] = beta == 0 ? 0 : beta * c[i + j * ldc];
    if (alpha == 0 || k <= 0)
        return;
    /* op(A) is packed column by column first unless it is a plain column-major matrix */
    const T *pa = a->a;
    long lda = a->ld;
    T *packed = NULL;
    if (a->kind != K_GE || a->trans || a->conj) {
        packed = malloc((size_t)(m * k) * sizeof(T));
        if (!packed)
            return;
        for (long l = 0; l < k; ++l)
            for (long i = 0; i < m; ++i)
                packed[i + l * m] = IN(elem)(a, i, l);
        pa = packed;
        lda = m;
    }
    for (long j = 0; j < n; ++j)
        for (long l = 0; l < k; ++l) {
            T t = alpha * IN(elem)(b, l, j);
            if (t == 0)
                continue;
            const T *col = pa + l * lda;
            T *out = c + j * ldc;
            for (long i = 0; i < m; ++i)
                out[i] += t * col[i];
        }
    free(packed);
}

/* the triangle of C (n by n) = alpha * op(A) op(B) + alpha2 * op(A2) op(B2) + beta * C
   (A2 NULL for rank k) */
static void IN(rk)(int upper, long n, long k, T alpha, const IN(Mat) *a, const IN(Mat) *b, T alpha2,
                   const IN(Mat) *a2, const IN(Mat) *b2, T beta, int herm, T *c, long ldc)
{
    for (long j = 0; j < n; ++j) {
        long from = upper ? 0 : j, to = upper ? j : n - 1;
        for (long i = from; i <= to; ++i) {
            T sum = 0, sum2 = 0;
            for (long l = 0; l < k; ++l) {
                sum += IN(elem)(a, i, l) * IN(elem)(b, l, j);
                if (a2)
                    sum2 += IN(elem)(a2, i, l) * IN(elem)(b2, l, j);
            }
            T *ci = &c[i + j * ldc];
            T old = beta == 0 ? 0 : beta * *ci;
            T terms = (alpha == 0 ? 0 : alpha * sum) + (a2 && alpha2 != 0 ? alpha2 * sum2 : 0);
            /* (on a Hermitian diagonal only the real part of the update is added: Apple's
               keep beta times the imaginary part there, where the reference BLAS zeroes it) */
            *ci = herm && i == j ? old + REALP(terms) : old + terms;
        }
    }
}

/* B = alpha * op(A) * B (left) or alpha * B * op(A) (right), A triangular */
static void IN(trmm)(int left, const IN(Mat) *a, long m, long n, T alpha, T *b, long ldb)
{
    if (m <= 0 || n <= 0)
        return;
    T *t = malloc((size_t)(m * n) * sizeof(T));
    if (!t)
        return;
    IN(Mat) bm = IN(mat)(K_GE, b, ldb);
    if (left)
        IN(mm)(m, n, m, alpha, a, &bm, 0, t, m);
    else
        IN(mm)(m, n, n, alpha, &bm, a, 0, t, m);
    for (long j = 0; j < n; ++j)
        memcpy(b + j * ldb, t + j * m, (size_t)m * sizeof(T));
    free(t);
}

/* solves op(A) * X = alpha * B (left) or X * op(A) = alpha * B (right) in place */
static void IN(trsm)(int left, const IN(Mat) *a, long m, long n, T alpha, T *b, long ldb)
{
    if (m <= 0 || n <= 0)
        return;
    for (long j = 0; j < n; ++j)
        for (long i = 0; i < m; ++i)
            b[i + j * ldb] = alpha == 0 ? 0 : alpha * b[i + j * ldb];
    if (alpha == 0)
        return;
    if (left) {
        for (long j = 0; j < n; ++j)
            IN(trsv_strided)(a, m, b + j * ldb, 1);
    } else {
        /* x op(A) = b  <=>  op(A)^T x^T = b^T */
        IN(Mat) t = *a;
        t.trans = !t.trans;
        for (long i = 0; i < m; ++i)
            IN(trsv_strided)(&t, n, b + i, ldb);
    }
}

/* MARK: - Fortran-convention entry points */

static int IN(is)(const char *c, char want) { return (*c | 0x20) == (want | 0x20); }

/* trans character to the (trans, conj) flags */
static void IN(op)(const char *c, int *trans, int *conj)
{
    *trans = !IN(is)(c, 'N');
    *conj = CPLX && IN(is)(c, 'C');
}

static IN(Mat) IN(tri)(int kind, const char *uplo, const char *trans, const char *diag, const T *a, long ld, long n,
                       long k)
{
    IN(Mat) m = IN(mat)(kind, a, ld);
    m.upper = IN(is)(uplo, 'U');
    m.unit = IN(is)(diag, 'U');
    m.n = n;
    m.ku = m.kl = k;
    IN(op)(trans, &m.trans, &m.conj);
    return m;
}

static IN(Mat) IN(sym)(int kind, const char *uplo, const T *a, long ld, long n, long k)
{
    IN(Mat) m = IN(mat)(kind, a, ld);
    m.upper = IN(is)(uplo, 'U');
    m.n = n;
    m.ku = m.kl = k;
    return m;
}

#if CPLX
#define SYMKIND(full, herm) (herm)
#else
#define SYMKIND(full, herm) (full)
#endif

long NAME_IAMAX(const long *n, const T *x, const long *incx) { return IN(iamax)(*n, x, *incx); }
R NAME_ASUM(const long *n, const T *x, const long *incx) { return IN(asum)(*n, x, *incx); }
R NAME_NRM2(const long *n, const T *x, const long *incx) { return IN(nrm2)(*n, x, *incx); }
void F(axpy)(const long *n, const T *alpha, const T *x, const long *incx, T *y, const long *incy)
{
    if (*alpha != 0)
        IN(axpby)(*n, *alpha, x, *incx, 1, y, *incy);
}
void F(axpby)(const long *n, const T *alpha, const T *x, const long *incx, const T *beta, T *y, const long *incy)
{
    IN(axpby)(*n, *alpha, x, *incx, *beta, y, *incy);
}
void F(copy)(const long *n, const T *x, const long *incx, T *y, const long *incy) { IN(copy)(*n, x, *incx, y, *incy); }
void F(swap)(const long *n, T *x, const long *incx, T *y, const long *incy) { IN(swap)(*n, x, *incx, y, *incy); }
void F(scal)(const long *n, const T *alpha, T *x, const long *incx) { IN(scal)(*n, *alpha, x, *incx); }

#if CPLX
void F(dotu)(T *ret, const long *n, const T *x, const long *incx, const T *y, const long *incy)
{
    *ret = IN(dot)(*n, x, *incx, y, *incy, 0);
}
void F(dotc)(T *ret, const long *n, const T *x, const long *incx, const T *y, const long *incy)
{
    *ret = IN(dot)(*n, x, *incx, y, *incy, 1);
}
void NAME_RSCAL(const long *n, const R *alpha, T *x, const long *incx) { IN(scal)(*n, *alpha, x, *incx); }
void NAME_RROT(const long *n, T *x, const long *incx, T *y, const long *incy, const R *c, const R *s)
{
    IN(rot)(*n, x, *incx, y, *incy, *c, *s);
}
/* complex Givens rotation, as the reference BLAS computes it */
void F(rotg)(T *a, const T *b, R *c, T *s)
{
    R absa = CAT(cabs, RS)(*a);
    if (absa == 0) {
        *c = 0;
        *s = 1;
        *a = *b;
        return;
    }
    R scale = absa + CAT(cabs, RS)(*b);
    R ra = CAT(cabs, RS)(*a / scale), rb = CAT(cabs, RS)(*b / scale);
    R norm = scale * RSQRT(ra * ra + rb * rb);
    T alpha = *a / absa;
    *c = absa / norm;
    *s = alpha * CONJ(*b) / norm;
    *a = alpha * norm;
}
#else
T F(dot)(const long *n, const T *x, const long *incx, const T *y, const long *incy)
{
    return IN(dot)(*n, x, *incx, y, *incy, 0);
}
void F(rot)(const long *n, T *x, const long *incx, T *y, const long *incy, const T *c, const T *s)
{
    IN(rot)(*n, x, *incx, y, *incy, *c, *s);
}
/* real Givens rotation, as the reference BLAS computes it */
void F(rotg)(T *a, T *b, T *c, T *s)
{
    T roe = RABS(*a) > RABS(*b) ? *a : *b, scale = RABS(*a) + RABS(*b), r, z;
    if (scale == 0) {
        *c = 1;
        *s = 0;
        r = z = 0;
    } else {
        T sa = *a / scale, sb = *b / scale;
        r = scale * RSQRT(sa * sa + sb * sb);
        r = CAT(copysign, RS)(1, roe) * r;
        *c = *a / r;
        *s = *b / r;
        z = 1;
        if (RABS(*a) > RABS(*b))
            z = *s;
        if (RABS(*b) >= RABS(*a) && *c != 0)
            z = 1 / *c;
    }
    *a = r;
    *b = z;
}
void F(rotm)(const long *n_, T *x, const long *incx_, T *y, const long *incy_, const T *param)
{
    long n = *n_, incx = *incx_, incy = *incy_;
    T flag = param[0], h11, h12, h21, h22;
    if (n <= 0 || flag == -2)
        return;
    if (flag < 0) {
        h11 = param[1];
        h21 = param[2];
        h12 = param[3];
        h22 = param[4];
    } else if (flag == 0) {
        h11 = 1;
        h21 = param[2];
        h12 = param[3];
        h22 = 1;
    } else {
        h11 = param[1];
        h21 = -1;
        h12 = 1;
        h22 = param[4];
    }
    for (long i = 0; i < n; ++i) {
        T *xi = &x[IX(i, incx, n)], *yi = &y[IX(i, incy, n)];
        T w = *xi, z = *yi;
        *xi = w * h11 + z * h12;
        *yi = w * h21 + z * h22;
    }
}
/* modified Givens rotation, as the reference BLAS computes it */
void F(rotmg)(T *d1, T *d2, T *x1, const T *y1, T *param)
{
    const T gam = 4096, gamsq = gam * gam, rgamsq = 1 / gamsq;
    T flag, h11 = 0, h12 = 0, h21 = 0, h22 = 0;
    if (*d1 < 0) {
        flag = -1;
        *d1 = *d2 = *x1 = 0;
    } else {
        T p2 = *d2 * *y1;
        if (p2 == 0) {
            param[0] = -2;
            return;
        }
        T p1 = *d1 * *x1, q2 = p2 * *y1, q1 = p1 * *x1;
        if (RABS(q1) > RABS(q2)) {
            h21 = -*y1 / *x1;
            h12 = p2 / p1;
            T u = 1 - h12 * h21;
            if (u > 0) {
                flag = 0;
                *d1 /= u;
                *d2 /= u;
                *x1 *= u;
            } else {
                flag = -1;
                h11 = h12 = h21 = h22 = 0;
                *d1 = *d2 = *x1 = 0;
            }
        } else if (q2 < 0) {
            flag = -1;
            h11 = h12 = h21 = h22 = 0;
            *d1 = *d2 = *x1 = 0;
        } else {
            flag = 1;
            h11 = p1 / p2;
            h22 = *x1 / *y1;
            T u = 1 + h11 * h22, t = *d2 / u;
            *d2 = *d1 / u;
            *d1 = t;
            *x1 = *y1 * u;
        }
        if (*d1 != 0) {
            while (*d1 <= rgamsq || *d1 >= gamsq) {
                if (flag == 0) {
                    h11 = 1;
                    h22 = 1;
                    flag = -1;
                } else {
                    h21 = -1;
                    h12 = 1;
                    flag = -1;
                }
                if (*d1 <= rgamsq) {
                    *d1 *= gam * gam;
                    *x1 /= gam;
                    h11 /= gam;
                    h12 /= gam;
                } else {
                    *d1 /= gam * gam;
                    *x1 *= gam;
                    h11 *= gam;
                    h12 *= gam;
                }
            }
        }
        if (*d2 != 0) {
            while (RABS(*d2) <= rgamsq || RABS(*d2) >= gamsq) {
                if (flag == 0) {
                    h11 = 1;
                    h22 = 1;
                    flag = -1;
                } else {
                    h21 = -1;
                    h12 = 1;
                    flag = -1;
                }
                if (RABS(*d2) <= rgamsq) {
                    *d2 *= gam * gam;
                    h21 /= gam;
                    h22 /= gam;
                } else {
                    *d2 /= gam * gam;
                    h21 *= gam;
                    h22 *= gam;
                }
            }
        }
    }
    if (flag < 0) {
        param[1] = h11;
        param[2] = h21;
        param[3] = h12;
        param[4] = h22;
    } else if (flag == 0) {
        param[2] = h21;
        param[3] = h12;
    } else {
        param[1] = h11;
        param[4] = h22;
    }
    param[0] = flag;
}
#endif

void F(gemv)(const char *trans, const long *m, const long *n, const T *alpha, const T *a, const long *lda, const T *x,
             const long *incx, const T *beta, T *y, const long *incy)
{
    IN(Mat) am = IN(mat)(K_GE, a, *lda);
    IN(op)(trans, &am.trans, &am.conj);
    long rows = am.trans ? *n : *m, cols = am.trans ? *m : *n;
    IN(mv)(&am, rows, cols, *alpha, x, *incx, *beta, y, *incy);
}

void F(gbmv)(const char *trans, const long *m, const long *n, const long *kl, const long *ku, const T *alpha,
             const T *a, const long *lda, const T *x, const long *incx, const T *beta, T *y, const long *incy)
{
    IN(Mat) am = IN(mat)(K_GB, a, *lda);
    am.kl = *kl;
    am.ku = *ku;
    IN(op)(trans, &am.trans, &am.conj);
    long rows = am.trans ? *n : *m, cols = am.trans ? *m : *n;
    IN(mv)(&am, rows, cols, *alpha, x, *incx, *beta, y, *incy);
}

#define SYMMETRIC_MV(name, KIND, ARGS, MAT)                                                              \
    void F(name) ARGS                                                                                    \
    {                                                                                                    \
        IN(Mat) am = MAT;                                                                                \
        IN(mv)(&am, *n, *n, *alpha, x, *incx, *beta, y, *incy);                                          \
    }

#if CPLX
#define SY_NAME(s, h) h
#else
#define SY_NAME(s, h) s
#endif

SYMMETRIC_MV(SY_NAME(symv, hemv), SYMKIND(K_SY, K_HE),
             (const char *uplo, const long *n, const T *alpha, const T *a, const long *lda, const T *x,
              const long *incx, const T *beta, T *y, const long *incy),
             IN(sym)(SYMKIND(K_SY, K_HE), uplo, a, *lda, *n, 0))
SYMMETRIC_MV(SY_NAME(sbmv, hbmv), SYMKIND(K_SB, K_HB),
             (const char *uplo, const long *n, const long *k, const T *alpha, const T *a, const long *lda,
              const T *x, const long *incx, const T *beta, T *y, const long *incy),
             IN(sym)(SYMKIND(K_SB, K_HB), uplo, a, *lda, *n, *k))
SYMMETRIC_MV(SY_NAME(spmv, hpmv), SYMKIND(K_SP, K_HP),
             (const char *uplo, const long *n, const T *alpha, const T *ap, const T *x, const long *incx,
              const T *beta, T *y, const long *incy),
             IN(sym)(SYMKIND(K_SP, K_HP), uplo, ap, 0, *n, 0))

void F(trmv)(const char *uplo, const char *trans, const char *diag, const long *n, const T *a, const long *lda, T *x,
             const long *incx)
{
    IN(Mat) am = IN(tri)(K_TR, uplo, trans, diag, a, *lda, *n, 0);
    IN(trmv)(&am, *n, x, *incx);
}
void F(tbmv)(const char *uplo, const char *trans, const char *diag, const long *n, const long *k, const T *a,
             const long *lda, T *x, const long *incx)
{
    IN(Mat) am = IN(tri)(K_TB, uplo, trans, diag, a, *lda, *n, *k);
    IN(trmv)(&am, *n, x, *incx);
}
void F(tpmv)(const char *uplo, const char *trans, const char *diag, const long *n, const T *ap, T *x,
             const long *incx)
{
    IN(Mat) am = IN(tri)(K_TP, uplo, trans, diag, ap, 0, *n, 0);
    IN(trmv)(&am, *n, x, *incx);
}
void F(trsv)(const char *uplo, const char *trans, const char *diag, const long *n, const T *a, const long *lda, T *x,
             const long *incx)
{
    IN(Mat) am = IN(tri)(K_TR, uplo, trans, diag, a, *lda, *n, 0);
    IN(trsv)(&am, *n, x, *incx);
}
void F(tbsv)(const char *uplo, const char *trans, const char *diag, const long *n, const long *k, const T *a,
             const long *lda, T *x, const long *incx)
{
    IN(Mat) am = IN(tri)(K_TB, uplo, trans, diag, a, *lda, *n, *k);
    IN(trsv)(&am, *n, x, *incx);
}
void F(tpsv)(const char *uplo, const char *trans, const char *diag, const long *n, const T *ap, T *x,
             const long *incx)
{
    IN(Mat) am = IN(tri)(K_TP, uplo, trans, diag, ap, 0, *n, 0);
    IN(trsv)(&am, *n, x, *incx);
}

#if CPLX
void F(geru)(const long *m, const long *n, const T *alpha, const T *x, const long *incx, const T *y, const long *incy,
             T *a, const long *lda)
{
    IN(ger)(*m, *n, *alpha, x, *incx, 0, y, *incy, 0, a, *lda);
}
void F(gerc)(const long *m, const long *n, const T *alpha, const T *x, const long *incx, const T *y, const long *incy,
             T *a, const long *lda)
{
    IN(ger)(*m, *n, *alpha, x, *incx, 0, y, *incy, 1, a, *lda);
}
void F(her)(const char *uplo, const long *n, const R *alpha, const T *x, const long *incx, T *a, const long *lda)
{
    IN(syr)(K_HE, IN(is)(uplo, 'U'), *n, *alpha, x, *incx, NULL, 0, 0, a, *lda);
}
void F(hpr)(const char *uplo, const long *n, const R *alpha, const T *x, const long *incx, T *ap)
{
    IN(syr)(K_HP, IN(is)(uplo, 'U'), *n, *alpha, x, *incx, NULL, 0, 0, ap, 0);
}
void F(her2)(const char *uplo, const long *n, const T *alpha, const T *x, const long *incx, const T *y,
             const long *incy, T *a, const long *lda)
{
    IN(syr)(K_HE, IN(is)(uplo, 'U'), *n, *alpha, x, *incx, y, *incy, 0, a, *lda);
}
void F(hpr2)(const char *uplo, const long *n, const T *alpha, const T *x, const long *incx, const T *y,
             const long *incy, T *ap)
{
    IN(syr)(K_HP, IN(is)(uplo, 'U'), *n, *alpha, x, *incx, y, *incy, 0, ap, 0);
}
#else
void F(ger)(const long *m, const long *n, const T *alpha, const T *x, const long *incx, const T *y, const long *incy,
            T *a, const long *lda)
{
    IN(ger)(*m, *n, *alpha, x, *incx, 0, y, *incy, 0, a, *lda);
}
void F(syr)(const char *uplo, const long *n, const T *alpha, const T *x, const long *incx, T *a, const long *lda)
{
    IN(syr)(K_SY, IN(is)(uplo, 'U'), *n, *alpha, x, *incx, NULL, 0, 0, a, *lda);
}
void F(spr)(const char *uplo, const long *n, const T *alpha, const T *x, const long *incx, T *ap)
{
    IN(syr)(K_SP, IN(is)(uplo, 'U'), *n, *alpha, x, *incx, NULL, 0, 0, ap, 0);
}
void F(syr2)(const char *uplo, const long *n, const T *alpha, const T *x, const long *incx, const T *y,
             const long *incy, T *a, const long *lda)
{
    IN(syr)(K_SY, IN(is)(uplo, 'U'), *n, *alpha, x, *incx, y, *incy, 0, a, *lda);
}
void F(spr2)(const char *uplo, const long *n, const T *alpha, const T *x, const long *incx, const T *y,
             const long *incy, T *ap)
{
    IN(syr)(K_SP, IN(is)(uplo, 'U'), *n, *alpha, x, *incx, y, *incy, 0, ap, 0);
}
#endif

void F(gemm)(const char *transa, const char *transb, const long *m, const long *n, const long *k, const T *alpha,
             const T *a, const long *lda, const T *b, const long *ldb, const T *beta, T *c, const long *ldc)
{
    IN(Mat) am = IN(mat)(K_GE, a, *lda), bm = IN(mat)(K_GE, b, *ldb);
    IN(op)(transa, &am.trans, &am.conj);
    IN(op)(transb, &bm.trans, &bm.conj);
    IN(mm)(*m, *n, *k, *alpha, &am, &bm, *beta, c, *ldc);
}

static void IN(symm)(int kind, const char *side, const char *uplo, long m, long n, T alpha, const T *a, long lda,
                     const T *b, long ldb, T beta, T *c, long ldc)
{
    int left = IN(is)(side, 'L');
    IN(Mat) am = IN(sym)(kind, uplo, a, lda, left ? m : n, 0), bm = IN(mat)(K_GE, b, ldb);
    if (left)
        IN(mm)(m, n, m, alpha, &am, &bm, beta, c, ldc);
    else
        IN(mm)(m, n, n, alpha, &bm, &am, beta, c, ldc);
}

void F(symm)(const char *side, const char *uplo, const long *m, const long *n, const T *alpha, const T *a,
             const long *lda, const T *b, const long *ldb, const T *beta, T *c, const long *ldc)
{
    IN(symm)(K_SY, side, uplo, *m, *n, *alpha, a, *lda, b, *ldb, *beta, c, *ldc);
}

/* rank k (and 2k) updates; herm: C = alpha A A^H (+ conj(alpha) B A^H) with real diagonal */
static void IN(syrk)(int herm, const char *uplo, const char *trans, long n, long k, T alpha, const T *a, long lda,
                     const T *b, long ldb, T beta, T *c, long ldc)
{
    int t = !IN(is)(trans, 'N');
    IN(Mat) am = IN(mat)(K_GE, a, lda), at = am;
    am.trans = t;
    at.trans = !t;
    if (herm) {
        am.conj = t;
        at.conj = !t;
    }
    if (!b) {
        IN(rk)(IN(is)(uplo, 'U'), n, k, alpha, &am, &at, 0, NULL, NULL, beta, herm, c, ldc);
        return;
    }
    IN(Mat) bm = IN(mat)(K_GE, b, ldb), bt = bm;
    bm.trans = t;
    bt.trans = !t;
    if (herm) {
        bm.conj = t;
        bt.conj = !t;
    }
    IN(rk)(IN(is)(uplo, 'U'), n, k, alpha, &am, &bt, herm ? CONJ(alpha) : alpha, &bm, &at, beta, herm, c, ldc);
}

void F(syrk)(const char *uplo, const char *trans, const long *n, const long *k, const T *alpha, const T *a,
             const long *lda, const T *beta, T *c, const long *ldc)
{
    IN(syrk)(0, uplo, trans, *n, *k, *alpha, a, *lda, NULL, 0, *beta, c, *ldc);
}
void F(syr2k)(const char *uplo, const char *trans, const long *n, const long *k, const T *alpha, const T *a,
              const long *lda, const T *b, const long *ldb, const T *beta, T *c, const long *ldc)
{
    IN(syrk)(0, uplo, trans, *n, *k, *alpha, a, *lda, b, *ldb, *beta, c, *ldc);
}

#if CPLX
void F(hemm)(const char *side, const char *uplo, const long *m, const long *n, const T *alpha, const T *a,
             const long *lda, const T *b, const long *ldb, const T *beta, T *c, const long *ldc)
{
    IN(symm)(K_HE, side, uplo, *m, *n, *alpha, a, *lda, b, *ldb, *beta, c, *ldc);
}
void F(herk)(const char *uplo, const char *trans, const long *n, const long *k, const R *alpha, const T *a,
             const long *lda, const R *beta, T *c, const long *ldc)
{
    IN(syrk)(1, uplo, trans, *n, *k, *alpha, a, *lda, NULL, 0, *beta, c, *ldc);
}
void F(her2k)(const char *uplo, const char *trans, const long *n, const long *k, const T *alpha, const T *a,
              const long *lda, const T *b, const long *ldb, const R *beta, T *c, const long *ldc)
{
    IN(syrk)(1, uplo, trans, *n, *k, *alpha, a, *lda, b, *ldb, *beta, c, *ldc);
}
#endif

void F(trmm)(const char *side, const char *uplo, const char *transa, const char *diag, const long *m, const long *n,
             const T *alpha, const T *a, const long *lda, T *b, const long *ldb)
{
    int left = IN(is)(side, 'L');
    IN(Mat) am = IN(tri)(K_TR, uplo, transa, diag, a, *lda, left ? *m : *n, 0);
    IN(trmm)(left, &am, *m, *n, *alpha, b, *ldb);
}
void F(trsm)(const char *side, const char *uplo, const char *transa, const char *diag, const long *m, const long *n,
             const T *alpha, const T *a, const long *lda, T *b, const long *ldb)
{
    int left = IN(is)(side, 'L');
    IN(Mat) am = IN(tri)(K_TR, uplo, transa, diag, a, *lda, left ? *m : *n, 0);
    IN(trsm)(left, &am, *m, *n, *alpha, b, *ldb);
}

/* MARK: - CBLAS entry points (row-major as the column-major transpose) */

static const char *IN(trans_char)(int t) { return t == CblasNoTrans ? "N" : t == CblasTrans ? "T" : "C"; }
static const char *IN(uplo_char)(int u, int flip) { return (u == CblasUpper) != flip ? "U" : "L"; }
static const char *IN(diag_char)(int d) { return d == CblasUnit ? "U" : "N"; }
static const char *IN(side_char)(int s, int flip) { return (s == CblasLeft) != flip ? "L" : "R"; }

#if CPLX
#define SCALAR(p) (*(const T *)(p))
#define SCALAR_ARG(t) const void *t
#define VEC(t) const void *t
#define MVEC(t) void *t
#else
#define SCALAR(p) (p)
#define SCALAR_ARG(t) T t
#define VEC(t) const T *t
#define MVEC(t) T *t
#endif

long CB_IAMAX(long n, VEC(x), long incx) { return n < 1 || incx <= 0 ? 0 : IN(iamax)(n, x, incx) - 1; }
R CB_ASUM(long n, VEC(x), long incx) { return IN(asum)(n, x, incx); }
R CB_NRM2(long n, VEC(x), long incx) { return IN(nrm2)(n, x, incx); }
void CB(axpy)(long n, SCALAR_ARG(alpha), VEC(x), long incx, MVEC(y), long incy)
{
    if (SCALAR(alpha) != 0)
        IN(axpby)(n, SCALAR(alpha), x, incx, 1, y, incy);
}
void CB(axpby)(long n, SCALAR_ARG(alpha), VEC(x), long incx, SCALAR_ARG(beta), MVEC(y), long incy)
{
    IN(axpby)(n, SCALAR(alpha), x, incx, SCALAR(beta), y, incy);
}
void CB(set)(long n, SCALAR_ARG(alpha), MVEC(x), long incx) { IN(set)(n, SCALAR(alpha), x, incx); }
void CB(copy)(long n, VEC(x), long incx, MVEC(y), long incy) { IN(copy)(n, x, incx, y, incy); }
void CB(swap)(long n, MVEC(x), long incx, MVEC(y), long incy) { IN(swap)(n, x, incx, y, incy); }
void CB(scal)(long n, SCALAR_ARG(alpha), MVEC(x), long incx) { IN(scal)(n, SCALAR(alpha), x, incx); }

#if CPLX
void CB(dotu_sub)(long n, VEC(x), long incx, VEC(y), long incy, void *dot)
{
    *(T *)dot = IN(dot)(n, x, incx, y, incy, 0);
}
void CB(dotc_sub)(long n, VEC(x), long incx, VEC(y), long incy, void *dot)
{
    *(T *)dot = IN(dot)(n, x, incx, y, incy, 1);
}
void CB_RSCAL(long n, R alpha, void *x, long incx) { IN(scal)(n, alpha, x, incx); }
void CB_RROT(long n, void *x, long incx, void *y, long incy, R c, R s) { IN(rot)(n, x, incx, y, incy, c, s); }
void CB(rotg)(void *a, void *b, R *c, void *s) { F(rotg)(a, b, c, s); }
#else
T CB(dot)(long n, VEC(x), long incx, VEC(y), long incy) { return IN(dot)(n, x, incx, y, incy, 0); }
void CB(rot)(long n, T *x, long incx, T *y, long incy, T c, T s) { IN(rot)(n, x, incx, y, incy, c, s); }
void CB(rotg)(T *a, T *b, T *c, T *s) { F(rotg)(a, b, c, s); }
void CB(rotm)(long n, T *x, long incx, T *y, long incy, const T *p)
{
    F(rotm)(&n, x, &incx, y, &incy, p);
}
void CB(rotmg)(T *d1, T *d2, T *b1, T b2, T *p) { F(rotmg)(d1, d2, b1, &b2, p); }
#endif

/* op(A) for a row-major or column-major general matrix */
static IN(Mat) IN(general)(int order, int trans, const T *a, long lda)
{
    IN(Mat) m = IN(mat)(K_GE, a, lda);
    m.trans = (trans != CblasNoTrans) != (order == CblasRowMajor);
    m.conj = CPLX && trans == CblasConjTrans;
    return m;
}

void CB(gemv)(int order, int trans, long m, long n, SCALAR_ARG(alpha), VEC(a), long lda, VEC(x), long incx,
              SCALAR_ARG(beta), MVEC(y), long incy)
{
    IN(Mat) am = IN(general)(order, trans, a, lda);
    /* a row-major m by n matrix is the column-major n by m transpose */
    long rows = trans == CblasNoTrans ? m : n, cols = trans == CblasNoTrans ? n : m;
    IN(mv)(&am, rows, cols, SCALAR(alpha), x, incx, SCALAR(beta), y, incy);
}

void CB(gbmv)(int order, int trans, long m, long n, long kl, long ku, SCALAR_ARG(alpha), VEC(a), long lda, VEC(x),
              long incx, SCALAR_ARG(beta), MVEC(y), long incy)
{
    IN(Mat) am = IN(mat)(K_GB, a, lda);
    if (order == CblasRowMajor) {
        am.kl = ku;
        am.ku = kl;
    } else {
        am.kl = kl;
        am.ku = ku;
    }
    am.trans = (trans != CblasNoTrans) != (order == CblasRowMajor);
    am.conj = CPLX && trans == CblasConjTrans;
    long rows = trans == CblasNoTrans ? m : n, cols = trans == CblasNoTrans ? n : m;
    IN(mv)(&am, rows, cols, SCALAR(alpha), x, incx, SCALAR(beta), y, incy);
}

/* a symmetric or Hermitian matrix: row-major is the other triangle of the transpose,
   which for a Hermitian matrix is its conjugate */
static IN(Mat) IN(symmetric)(int kind, int order, int uplo, const T *a, long lda, long n, long k)
{
    IN(Mat) m = IN(sym)(kind, IN(uplo_char)(uplo, order == CblasRowMajor), a, lda, n, k);
    m.conj = CPLX && order == CblasRowMajor && (kind == K_HE || kind == K_HB || kind == K_HP);
    return m;
}

#define CB_SYMMETRIC_MV(name, KIND, ARGS, LDA, K)                                                        \
    void CB(name) ARGS                                                                                   \
    {                                                                                                    \
        IN(Mat) am = IN(symmetric)(KIND, order, uplo, a, LDA, n, K);                                     \
        IN(mv)(&am, n, n, SCALAR(alpha), x, incx, SCALAR(beta), y, incy);                                \
    }

CB_SYMMETRIC_MV(SY_NAME(symv, hemv), SYMKIND(K_SY, K_HE),
                (int order, int uplo, long n, SCALAR_ARG(alpha), VEC(a), long lda, VEC(x), long incx,
                 SCALAR_ARG(beta), MVEC(y), long incy),
                lda, 0)
CB_SYMMETRIC_MV(SY_NAME(sbmv, hbmv), SYMKIND(K_SB, K_HB),
                (int order, int uplo, long n, long k, SCALAR_ARG(alpha), VEC(a), long lda, VEC(x), long incx,
                 SCALAR_ARG(beta), MVEC(y), long incy),
                lda, k)
CB_SYMMETRIC_MV(SY_NAME(spmv, hpmv), SYMKIND(K_SP, K_HP),
                (int order, int uplo, long n, SCALAR_ARG(alpha), VEC(a), VEC(x), long incx, SCALAR_ARG(beta),
                 MVEC(y), long incy),
                0, 0)

/* a triangular matrix: row-major is the other triangle, transposed */
static IN(Mat) IN(triangular)(int kind, int order, int uplo, int trans, int diag, const T *a, long lda, long n,
                              long k)
{
    int row = order == CblasRowMajor;
    IN(Mat) m = IN(tri)(kind, IN(uplo_char)(uplo, row), IN(trans_char)(trans), IN(diag_char)(diag), a, lda, n, k);
    if (row)
        m.trans = !m.trans;
    return m;
}

void CB(trmv)(int order, int uplo, int trans, int diag, long n, VEC(a), long lda, MVEC(x), long incx)
{
    IN(Mat) am = IN(triangular)(K_TR, order, uplo, trans, diag, a, lda, n, 0);
    IN(trmv)(&am, n, x, incx);
}
void CB(tbmv)(int order, int uplo, int trans, int diag, long n, long k, VEC(a), long lda, MVEC(x), long incx)
{
    IN(Mat) am = IN(triangular)(K_TB, order, uplo, trans, diag, a, lda, n, k);
    IN(trmv)(&am, n, x, incx);
}
void CB(tpmv)(int order, int uplo, int trans, int diag, long n, VEC(a), MVEC(x), long incx)
{
    IN(Mat) am = IN(triangular)(K_TP, order, uplo, trans, diag, a, 0, n, 0);
    IN(trmv)(&am, n, x, incx);
}
void CB(trsv)(int order, int uplo, int trans, int diag, long n, VEC(a), long lda, MVEC(x), long incx)
{
    IN(Mat) am = IN(triangular)(K_TR, order, uplo, trans, diag, a, lda, n, 0);
    IN(trsv)(&am, n, x, incx);
}
void CB(tbsv)(int order, int uplo, int trans, int diag, long n, long k, VEC(a), long lda, MVEC(x), long incx)
{
    IN(Mat) am = IN(triangular)(K_TB, order, uplo, trans, diag, a, lda, n, k);
    IN(trsv)(&am, n, x, incx);
}
void CB(tpsv)(int order, int uplo, int trans, int diag, long n, VEC(a), MVEC(x), long incx)
{
    IN(Mat) am = IN(triangular)(K_TP, order, uplo, trans, diag, a, 0, n, 0);
    IN(trsv)(&am, n, x, incx);
}

/* A += alpha x op(y)^T: row-major is A^T += alpha op(y) x^T */
static void IN(cger)(int order, long m, long n, T alpha, const T *x, long incx, const T *y, long incy, int conjy,
                     T *a, long lda)
{
    if (order == CblasRowMajor)
        IN(ger)(n, m, alpha, y, incy, conjy, x, incx, 0, a, lda);
    else
        IN(ger)(m, n, alpha, x, incx, 0, y, incy, conjy, a, lda);
}

#if CPLX
void CB(geru)(int order, long m, long n, SCALAR_ARG(alpha), VEC(x), long incx, VEC(y), long incy, MVEC(a), long lda)
{
    IN(cger)(order, m, n, SCALAR(alpha), x, incx, y, incy, 0, a, lda);
}
void CB(gerc)(int order, long m, long n, SCALAR_ARG(alpha), VEC(x), long incx, VEC(y), long incy, MVEC(a), long lda)
{
    IN(cger)(order, m, n, SCALAR(alpha), x, incx, y, incy, 1, a, lda);
}
/* Hermitian updates: row-major updates the conjugate, so x (and y) go in conjugated */
void CB(her)(int order, int uplo, long n, R alpha, VEC(x), long incx, MVEC(a), long lda)
{
    int row = order == CblasRowMajor;
    IN(syr)(K_HE, *IN(uplo_char)(uplo, row) == 'U', n, alpha, x, incx, NULL, 0, row, a, lda);
}
void CB(hpr)(int order, int uplo, long n, R alpha, VEC(x), long incx, MVEC(a))
{
    int row = order == CblasRowMajor;
    IN(syr)(K_HP, *IN(uplo_char)(uplo, row) == 'U', n, alpha, x, incx, NULL, 0, row, a, 0);
}
void CB(her2)(int order, int uplo, long n, SCALAR_ARG(alpha), VEC(x), long incx, VEC(y), long incy, MVEC(a), long lda)
{
    int row = order == CblasRowMajor;
    if (row)
        IN(syr)(K_HE, *IN(uplo_char)(uplo, row) == 'U', n, SCALAR(alpha), y, incy, x, incx, 1, a, lda);
    else
        IN(syr)(K_HE, uplo == CblasUpper, n, SCALAR(alpha), x, incx, y, incy, 0, a, lda);
}
void CB(hpr2)(int order, int uplo, long n, SCALAR_ARG(alpha), VEC(x), long incx, VEC(y), long incy, MVEC(ap))
{
    int row = order == CblasRowMajor;
    if (row)
        IN(syr)(K_HP, *IN(uplo_char)(uplo, row) == 'U', n, SCALAR(alpha), y, incy, x, incx, 1, ap, 0);
    else
        IN(syr)(K_HP, uplo == CblasUpper, n, SCALAR(alpha), x, incx, y, incy, 0, ap, 0);
}
#else
void CB(ger)(int order, long m, long n, T alpha, const T *x, long incx, const T *y, long incy, T *a, long lda)
{
    IN(cger)(order, m, n, alpha, x, incx, y, incy, 0, a, lda);
}
void CB(syr)(int order, int uplo, long n, T alpha, const T *x, long incx, T *a, long lda)
{
    IN(syr)(K_SY, *IN(uplo_char)(uplo, order == CblasRowMajor) == 'U', n, alpha, x, incx, NULL, 0, 0, a, lda);
}
void CB(spr)(int order, int uplo, long n, T alpha, const T *x, long incx, T *ap)
{
    IN(syr)(K_SP, *IN(uplo_char)(uplo, order == CblasRowMajor) == 'U', n, alpha, x, incx, NULL, 0, 0, ap, 0);
}
void CB(syr2)(int order, int uplo, long n, T alpha, const T *x, long incx, const T *y, long incy, T *a, long lda)
{
    IN(syr)(K_SY, *IN(uplo_char)(uplo, order == CblasRowMajor) == 'U', n, alpha, x, incx, y, incy, 0, a, lda);
}
void CB(spr2)(int order, int uplo, long n, T alpha, const T *x, long incx, const T *y, long incy, T *ap)
{
    IN(syr)(K_SP, *IN(uplo_char)(uplo, order == CblasRowMajor) == 'U', n, alpha, x, incx, y, incy, 0, ap, 0);
}
#endif

/* row-major C = op(A) op(B) is the column-major C^T = op(B)^T op(A)^T */
void CB(gemm)(int order, int transa, int transb, long m, long n, long k, SCALAR_ARG(alpha), VEC(a), long lda, VEC(b),
              long ldb, SCALAR_ARG(beta), MVEC(c), long ldc)
{
    const char *ta = IN(trans_char)(transa), *tb = IN(trans_char)(transb);
    T al = SCALAR(alpha), be = SCALAR(beta);
    if (order == CblasRowMajor)
        F(gemm)(tb, ta, &n, &m, &k, &al, b, &ldb, a, &lda, &be, c, &ldc);
    else
        F(gemm)(ta, tb, &m, &n, &k, &al, a, &lda, b, &ldb, &be, c, &ldc);
}

static void IN(csymm)(int kind, int order, int side, int uplo, long m, long n, T alpha, const T *a, long lda,
                      const T *b, long ldb, T beta, T *c, long ldc)
{
    int row = order == CblasRowMajor;
    if (row)
        IN(symm)(kind, IN(side_char)(side, 1), IN(uplo_char)(uplo, 1), n, m, alpha, a, lda, b, ldb, beta, c, ldc);
    else
        IN(symm)(kind, IN(side_char)(side, 0), IN(uplo_char)(uplo, 0), m, n, alpha, a, lda, b, ldb, beta, c, ldc);
}

void CB(symm)(int order, int side, int uplo, long m, long n, SCALAR_ARG(alpha), VEC(a), long lda, VEC(b), long ldb,
              SCALAR_ARG(beta), MVEC(c), long ldc)
{
    IN(csymm)(K_SY, order, side, uplo, m, n, SCALAR(alpha), a, lda, b, ldb, SCALAR(beta), c, ldc);
}

/* row-major: the other triangle, the other transposition */
static const char *IN(rk_trans)(int trans, int row, int herm)
{
    if (!row)
        return IN(trans_char)(trans);
    if (trans == CblasNoTrans)
        return herm ? "C" : "T";
    return "N";
}

void CB(syrk)(int order, int uplo, int trans, long n, long k, SCALAR_ARG(alpha), VEC(a), long lda, SCALAR_ARG(beta),
              MVEC(c), long ldc)
{
    int row = order == CblasRowMajor;
    IN(syrk)(0, IN(uplo_char)(uplo, row), IN(rk_trans)(trans, row, 0), n, k, SCALAR(alpha), a, lda, NULL, 0,
             SCALAR(beta), c, ldc);
}
void CB(syr2k)(int order, int uplo, int trans, long n, long k, SCALAR_ARG(alpha), VEC(a), long lda, VEC(b), long ldb,
               SCALAR_ARG(beta), MVEC(c), long ldc)
{
    int row = order == CblasRowMajor;
    IN(syrk)(0, IN(uplo_char)(uplo, row), IN(rk_trans)(trans, row, 0), n, k, SCALAR(alpha), a, lda, b, ldb,
             SCALAR(beta), c, ldc);
}

#if CPLX
void CB(hemm)(int order, int side, int uplo, long m, long n, SCALAR_ARG(alpha), VEC(a), long lda, VEC(b), long ldb,
              SCALAR_ARG(beta), MVEC(c), long ldc)
{
    IN(csymm)(K_HE, order, side, uplo, m, n, SCALAR(alpha), a, lda, b, ldb, SCALAR(beta), c, ldc);
}
void CB(herk)(int order, int uplo, int trans, long n, long k, R alpha, VEC(a), long lda, R beta, MVEC(c), long ldc)
{
    int row = order == CblasRowMajor;
    IN(syrk)(1, IN(uplo_char)(uplo, row), IN(rk_trans)(trans, row, 1), n, k, alpha, a, lda, NULL, 0, beta, c, ldc);
}
void CB(her2k)(int order, int uplo, int trans, long n, long k, SCALAR_ARG(alpha), VEC(a), long lda, VEC(b), long ldb,
               R beta, MVEC(c), long ldc)
{
    int row = order == CblasRowMajor;
    T al = row ? CONJ(SCALAR(alpha)) : SCALAR(alpha);
    IN(syrk)(1, IN(uplo_char)(uplo, row), IN(rk_trans)(trans, row, 1), n, k, al, a, lda, b, ldb, beta, c, ldc);
}
#endif

static void IN(ctr3)(int solve, int order, int side, int uplo, int transa, int diag, long m, long n, T alpha,
                     const T *a, long lda, T *b, long ldb)
{
    int row = order == CblasRowMajor;
    if (row) {
        long t = m;
        m = n;
        n = t;
    }
    int left = *IN(side_char)(side, row) == 'L';
    IN(Mat) am = IN(tri)(K_TR, IN(uplo_char)(uplo, row), IN(trans_char)(transa), IN(diag_char)(diag), a, lda,
                         left ? m : n, 0);
    if (solve)
        IN(trsm)(left, &am, m, n, alpha, b, ldb);
    else
        IN(trmm)(left, &am, m, n, alpha, b, ldb);
}

void CB(trmm)(int order, int side, int uplo, int transa, int diag, long m, long n, SCALAR_ARG(alpha), VEC(a), long lda,
              MVEC(b), long ldb)
{
    IN(ctr3)(0, order, side, uplo, transa, diag, m, n, SCALAR(alpha), a, lda, b, ldb);
}
void CB(trsm)(int order, int side, int uplo, int transa, int diag, long m, long n, SCALAR_ARG(alpha), VEC(a), long lda,
              MVEC(b), long ldb)
{
    IN(ctr3)(1, order, side, uplo, transa, diag, m, n, SCALAR(alpha), a, lda, b, ldb);
}

#if !CPLX
/* appleblas_?geadd: C = alpha op(A) + beta op(B) */
void CAT(CAT(finch_appleblas_, P), geadd)(int order, int transa, int transb, long m, long n, T alpha, const T *a,
                                           long lda, T beta, const T *b, long ldb, T *c, long ldc)
{
    IN(Mat) am = IN(general)(order, transa, a, lda), bm = IN(general)(order, transb, b, ldb);
    for (long i = 0; i < m; ++i)
        for (long j = 0; j < n; ++j) {
            T v = alpha * IN(elem)(&am, i, j) + beta * IN(elem)(&bm, i, j);
            if (order == CblasRowMajor)
                c[i * ldc + j] = v;
            else
                c[i + j * ldc] = v;
        }
}
#endif

#undef CONJ
#undef REALP
#undef IMAGP
#undef ABS1
#undef RABS
#undef RSQRT
#undef SYMKIND
#undef SY_NAME
#undef SYMMETRIC_MV
#undef CB_SYMMETRIC_MV
#undef SCALAR
#undef SCALAR_ARG
#undef VEC
#undef MVEC
#undef F
#undef CB
#undef IN
#undef CAT
#undef CAT_
