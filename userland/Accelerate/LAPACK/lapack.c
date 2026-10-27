/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* The LAPACK routines apps on this Mac import: LU factorization and inverse, least
   squares and tridiagonal solves. */
#define ACCELERATE_NEW_LAPACK 1
#include <Accelerate/Accelerate.h>
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

void dgetrf_(const __LAPACK_int *m, const __LAPACK_int *n, double *a,
             const __LAPACK_int *lda, __LAPACK_int *ipiv, __LAPACK_int *info)
{
    __LAPACK_int i, j, k, limit;
    if (!info) return;
    *info = 0;
    if (!m) { *info = -1; return; }
    if (!n) { *info = -2; return; }
    if (!lda) { *info = -4; return; }
    if (*m < 0) { *info = -1; return; }
    if (*n < 0) { *info = -2; return; }
    if (*lda < (*m > 1 ? *m : 1)) { *info = -4; return; }
    limit = *m < *n ? *m : *n;
    if (limit && (!a || !ipiv)) { *info = -3; return; }
    for (k = 0; k < limit; ++k) {
        __LAPACK_int pivot = k;
        double magnitude = fabs(a[k + k * *lda]);
        for (i = k + 1; i < *m; ++i) {
            double candidate = fabs(a[i + k * *lda]);
            if (candidate > magnitude) { magnitude = candidate; pivot = i; }
        }
        ipiv[k] = pivot + 1;
        if (a[pivot + k * *lda] == 0.0) {
            if (*info == 0) *info = k + 1;
            continue;
        }
        if (pivot != k)
            for (j = 0; j < *n; ++j) {
                double swap = a[k + j * *lda];
                a[k + j * *lda] = a[pivot + j * *lda];
                a[pivot + j * *lda] = swap;
            }
        for (i = k + 1; i < *m; ++i)
            a[i + k * *lda] /= a[k + k * *lda];
        for (j = k + 1; j < *n; ++j) {
            double top = a[k + j * *lda];
            for (i = k + 1; i < *m; ++i)
                a[i + j * *lda] -= a[i + k * *lda] * top;
        }
    }
}

void dgetri_(const __LAPACK_int *n, double *a, const __LAPACK_int *lda,
             const __LAPACK_int *ipiv, double *work, const __LAPACK_int *lwork,
             __LAPACK_int *info)
{
    __LAPACK_int i, j, k;
    double *inverse;
    if (!info) return;
    *info = 0;
    if (!n) { *info = -1; return; }
    if (!lda) { *info = -3; return; }
    if (!lwork) { *info = -6; return; }
    if (*n < 0) { *info = -1; return; }
    if (*lda < (*n > 1 ? *n : 1)) { *info = -3; return; }
    if (*lwork == -1) {
        if (!work) { *info = -5; return; }
        work[0] = (double)(*n > 1 ? *n * 64 : 1);
        return;
    }
    if (*lwork < (*n > 1 ? *n : 1)) { *info = -6; return; }
    if (*n == 0) { if (work) work[0] = 1; return; }
    if (!a || !ipiv || !work) { *info = -2; return; }
    for (i = 0; i < *n; ++i)
        if (a[i + i * *lda] == 0.0) { *info = i + 1; return; }
    if ((size_t)*n > SIZE_MAX / (size_t)*n / sizeof(*inverse)) { *info = -2; return; }
    inverse = calloc((size_t)*n * (size_t)*n, sizeof(*inverse));
    if (!inverse) { *info = -2; return; }
    for (j = 0; j < *n; ++j) {
        double *column = work;
        for (i = 0; i < *n; ++i) column[i] = i == j ? 1.0 : 0.0;
        for (i = 0; i < *n; ++i) {
            __LAPACK_int pivot = ipiv[i] - 1;
            if (pivot < 0 || pivot >= *n) { free(inverse); *info = -4; return; }
            if (pivot != i) {
                double swap = column[i];
                column[i] = column[pivot];
                column[pivot] = swap;
            }
        }
        for (i = 0; i < *n; ++i)
            for (k = 0; k < i; ++k)
                column[i] -= a[i + k * *lda] * column[k];
        for (i = *n; i-- > 0;) {
            for (k = i + 1; k < *n; ++k)
                column[i] -= a[i + k * *lda] * column[k];
            column[i] /= a[i + i * *lda];
            inverse[i + j * *n] = column[i];
        }
    }
    for (j = 0; j < *n; ++j)
        for (i = 0; i < *n; ++i)
            a[i + j * *lda] = inverse[i + j * *n];
    work[0] = (double)(*n > 1 ? *n * 64 : 1);
    free(inverse);
}

static void qr_factor(double *a, __LAPACK_int rows, __LAPACK_int cols, double *tau,
                      __LAPACK_int *singular)
{
    __LAPACK_int k, i, j;
    *singular = 0;
    for (k = 0; k < cols; ++k) {
        double norm = 0.0, alpha, beta, denominator;
        for (i = k; i < rows; ++i) norm = hypot(norm, a[i + k * rows]);
        alpha = a[k + k * rows];
        if (norm == 0.0) {
            tau[k] = 0.0;
            if (!*singular) *singular = k + 1;
            continue;
        }
        beta = -copysign(norm, alpha);
        tau[k] = (beta - alpha) / beta;
        denominator = alpha - beta;
        a[k + k * rows] = beta;
        for (i = k + 1; i < rows; ++i) a[i + k * rows] /= denominator;
        for (j = k + 1; j < cols; ++j) {
            double dot = a[k + j * rows];
            for (i = k + 1; i < rows; ++i) dot += a[i + k * rows] * a[i + j * rows];
            dot *= tau[k];
            a[k + j * rows] -= dot;
            for (i = k + 1; i < rows; ++i) a[i + j * rows] -= a[i + k * rows] * dot;
        }
    }
}

static void apply_reflector(const double *a, __LAPACK_int rows, __LAPACK_int k,
                            double tau, double *vector, __LAPACK_int stride)
{
    __LAPACK_int i;
    double dot;
    if (tau == 0.0) return;
    dot = vector[k * stride];
    for (i = k + 1; i < rows; ++i) dot += a[i + k * rows] * vector[i * stride];
    dot *= tau;
    vector[k * stride] -= dot;
    for (i = k + 1; i < rows; ++i) vector[i * stride] -= a[i + k * rows] * dot;
}

void dgels_(const char *trans, const __LAPACK_int *m, const __LAPACK_int *n,
            const __LAPACK_int *nrhs, double *a, const __LAPACK_int *lda,
            double *b, const __LAPACK_int *ldb, double *work,
            const __LAPACK_int *lwork, __LAPACK_int *info)
{
    __LAPACK_int rows, cols, minmn, minWork, singular, i, j, k, rhs;
    int transpose;
    double *matrix, *tau;
    if (!info) return;
    *info = 0;
    if (!trans) { *info = -1; return; }
    if (!m) { *info = -2; return; }
    if (!n) { *info = -3; return; }
    if (!nrhs) { *info = -4; return; }
    if (!lda) { *info = -6; return; }
    if (!ldb) { *info = -8; return; }
    if (!lwork) { *info = -10; return; }
    transpose = (*trans == 'T' || *trans == 't');
    if (!transpose && *trans != 'N' && *trans != 'n') { *info = -1; return; }
    if (*m < 0) { *info = -2; return; }
    if (*n < 0) { *info = -3; return; }
    if (*nrhs < 0) { *info = -4; return; }
    if (*lda < (*m > 1 ? *m : 1)) { *info = -6; return; }
    if (*ldb < (*m > *n ? (*m > 1 ? *m : 1) : (*n > 1 ? *n : 1))) { *info = -8; return; }
    rows = transpose ? *n : *m;
    cols = transpose ? *m : *n;
    minmn = rows < cols ? rows : cols;
    minWork = minmn + (minmn > *nrhs ? minmn : *nrhs);
    if (minWork < 1) minWork = 1;
    if (*lwork == -1) {
        if (!work) { *info = -9; return; }
        work[0] = (double)(minWork * 32);
        return;
    }
    if (*lwork < minWork) { *info = -10; return; }
    if (*m == 0 || *n == 0 || *nrhs == 0) { if (work) work[0] = minWork; return; }
    if (!a || !b || !work) { *info = -5; return; }
    if ((size_t)rows > SIZE_MAX / (size_t)cols / sizeof(*matrix)) { *info = -5; return; }
    matrix = malloc((size_t)rows * (size_t)cols * sizeof(*matrix));
    tau = calloc((size_t)minmn, sizeof(*tau));
    if (!matrix || !tau) { free(matrix); free(tau); *info = -5; return; }
    for (j = 0; j < cols; ++j)
        for (i = 0; i < rows; ++i)
            matrix[i + j * rows] = transpose ? a[j + i * *lda] : a[i + j * *lda];

    if (rows >= cols) {
        qr_factor(matrix, rows, cols, tau, &singular);
        for (k = 0; k < cols; ++k)
            for (rhs = 0; rhs < *nrhs; ++rhs)
                apply_reflector(matrix, rows, k, tau[k], b + rhs * *ldb, 1);
        for (rhs = 0; rhs < *nrhs; ++rhs) {
            double *column = b + rhs * *ldb;
            for (i = cols; i-- > 0;) {
                for (j = i + 1; j < cols; ++j)
                    column[i] -= matrix[i + j * rows] * column[j];
                if (matrix[i + i * rows] == 0.0) {
                    if (!singular) singular = i + 1;
                } else {
                    column[i] /= matrix[i + i * rows];
                }
            }
        }
        for (j = 0; j < cols; ++j)
            for (i = 0; i < rows; ++i)
                if (transpose) a[j + i * *lda] = matrix[i + j * rows];
                else a[i + j * *lda] = matrix[i + j * rows];
    } else {
        double *t = malloc((size_t)cols * (size_t)rows * sizeof(*t));
        double *tauT = calloc((size_t)rows, sizeof(*tauT));
        if (!t || !tauT) { free(t); free(tauT); free(matrix); free(tau); *info = -5; return; }
        for (j = 0; j < rows; ++j)
            for (i = 0; i < cols; ++i)
                t[i + j * cols] = matrix[j + i * rows];
        qr_factor(t, cols, rows, tauT, &singular);
        for (rhs = 0; rhs < *nrhs; ++rhs) {
            double *column = b + rhs * *ldb;
            for (i = 0; i < rows; ++i) {
                for (j = 0; j < i; ++j) column[i] -= t[j + i * cols] * column[j];
                if (t[i + i * cols] == 0.0) {
                    if (!singular) singular = i + 1;
                } else {
                    column[i] /= t[i + i * cols];
                }
            }
            for (i = rows; i < cols; ++i) column[i] = 0.0;
            for (k = rows; k-- > 0;)
                apply_reflector(t, cols, k, tauT[k], column, 1);
        }
        for (j = 0; j < rows; ++j)
            for (i = 0; i < cols; ++i)
                if (transpose) a[j + i * *lda] = t[i + j * cols];
                else a[i + j * *lda] = t[j + i * cols];
        free(t);
        free(tauT);
    }
    *info = singular;
    work[0] = (double)(minWork * 32);
    free(matrix);
    free(tau);
}

void dgtsv_(const __LAPACK_int *n, const __LAPACK_int *nrhs, double *dl,
            double *d, double *du, double *b, const __LAPACK_int *ldb,
            __LAPACK_int *info)
{
    __LAPACK_int i, rhs;
    double *du2;
    __LAPACK_int *piv;
    if (!info) return;
    *info = 0;
    if (!n) { *info = -1; return; }
    if (!nrhs) { *info = -2; return; }
    if (!ldb) { *info = -7; return; }
    if (*n < 0) { *info = -1; return; }
    if (*nrhs < 0) { *info = -2; return; }
    if (*ldb < (*n > 1 ? *n : 1)) { *info = -7; return; }
    if (*n == 0) return;
    if (!d || !b || (*n > 1 && (!dl || !du))) { *info = -3; return; }
    du2 = calloc((size_t)*n, sizeof(*du2));
    piv = malloc((size_t)*n * sizeof(*piv));
    if (!du2 || !piv) { free(du2); free(piv); *info = -3; return; }
    for (i = 0; i < *n - 1; ++i) {
        if (fabs(d[i]) >= fabs(dl[i])) {
            if (d[i] != 0.0) {
                double factor = dl[i] / d[i];
                dl[i] = factor;
                d[i + 1] -= factor * du[i];
            } else if (*info == 0) *info = i + 1;
            piv[i] = i;
        } else {
            double factor = d[i] / dl[i];
            double diagonal = d[i + 1];
            d[i] = dl[i];
            dl[i] = factor;
            d[i + 1] = du[i] - factor * diagonal;
            if (i + 1 < *n - 1) {
                du2[i] = du[i + 1];
                du[i + 1] = -factor * du[i + 1];
            }
            du[i] = diagonal;
            piv[i] = i + 1;
        }
    }
    piv[*n - 1] = *n - 1;
    if (d[*n - 1] == 0.0 && *info == 0) *info = *n;
    if (*info == 0) {
        for (rhs = 0; rhs < *nrhs; ++rhs) {
            double *column = b + rhs * *ldb;
            for (i = 0; i < *n - 1; ++i) {
                if (piv[i] == i) column[i + 1] -= dl[i] * column[i];
                else {
                    double swap = column[i];
                    column[i] = column[i + 1];
                    column[i + 1] = swap - dl[i] * column[i];
                }
            }
            column[*n - 1] /= d[*n - 1];
            if (*n > 1)
                column[*n - 2] = (column[*n - 2] - du[*n - 2] * column[*n - 1]) / d[*n - 2];
            for (i = *n - 2; i-- > 0;)
                column[i] = (column[i] - du[i] * column[i + 1] - du2[i] * column[i + 2]) / d[i];
        }
    }
    free(du2);
    free(piv);
}
