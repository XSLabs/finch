/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_SPARSE_FACTOR_H
#define FINCH_SPARSE_FACTOR_H

#include "internal.h"

enum { FAMILY_SYMMETRIC, FAMILY_QR, FAMILY_LU };

/* Behind SparseOpaqueSymbolicFactorization.factorization. */
struct symbolic {
	int refs;
	SparseFactorization_t type;
	SparseSymbolicFactorOptions options;
	int family;
	int m, n;        /* point dimensions of op(A) as factored (QR: m >= n after any transpose) */
	int wide;        /* QR of a matrix with fewer rows than columns: A' is factored */
	int *perm;       /* symmetric and QR: column order (new -> old); LU: column order */
	int *row_perm;   /* LU: row order (new -> old) */
};

/* A sorted sparse vector. */
struct svec {
	int n, cap;
	int *i;
	V *x;
};

/* Behind SparseOpaqueFactorization_*.numericFactorization; lives in factor storage. */
struct numeric {
	int refs;
	int type;
	int family;
	int factored;           /* elements are valid */
	SparseFactorization_t ftype;
	SparseNumericFactorOptions options;
	SparseOpaqueSymbolicFactorization symbolic;
	int hermitian;          /* symmetric family: L D L^H (else L D L^T) */
	int m, n;
	int *perm;              /* final symmetric / QR column / LU column order (new -> old) */
	int *row_perm;          /* LU row order, QR pivot rows (step -> row) */
	double *scale;          /* symmetric: n; LU: m row then n column */
	/* symmetric */
	struct csc *L;          /* strictly lower, unit diagonal, in pivot order */
	V *d, *e;               /* D: diagonal and the subdiagonal of 2x2 blocks */
	int cholesky;           /* L carries sqrt(D) */
	int positive, zero, negative;
	/* QR */
	struct csc *H;          /* Householder vectors, column k over original rows */
	V *beta;
	struct csc *R;          /* upper triangular, rows and columns by step */
	/* LU */
	struct csc *LU_L;       /* unit lower, rows and columns by step */
	struct csc *LU_U;       /* upper, by step */
	void *storage;          /* factor storage to free, if Sparse allocated it */
	void (*free_storage)(void *);
};

SparseOpaqueSymbolicFactorization symbolic_factor(SparseFactorization_t type, const SparseMatrixStructure *S,
    const SparseSymbolicFactorOptions *options, int family);
SparseStatus_t numeric_factor(struct numeric *f, const struct matrix_view *A);
void numeric_release(struct numeric *f);
void numeric_solve(const struct numeric *f, int transpose, int conjugate, const struct dense_view *B,
    const struct dense_view *X);
void subfactor_apply(const struct numeric *f, SparseSubfactor_t which, int transpose, int conjugate, int solve,
    const struct dense_view *in, const struct dense_view *out);

#endif
