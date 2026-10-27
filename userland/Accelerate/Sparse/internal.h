/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_SPARSE_INTERNAL_H
#define FINCH_SPARSE_INTERNAL_H

#include <Accelerate/Accelerate.h>
#include <complex.h>
#include <stdbool.h>
#include <stddef.h>

/*
 * libSparse works on one internal form for every scalar type: values are
 * double complex, rounded to the caller's type when they leave. Matrices are
 * expanded to point (non-block) compressed columns with the transpose and the
 * symmetric, Hermitian or triangular storage applied.
 */
typedef double _Complex V;

enum { T_FLOAT, T_DOUBLE, T_FLOAT_COMPLEX, T_DOUBLE_COMPLEX };

static inline int is_complex(int type)
{
	return type >= T_FLOAT_COMPLEX;
}

static inline int is_single(int type)
{
	return type == T_FLOAT || type == T_FLOAT_COMPLEX;
}

static inline size_t scalar_size(int type)
{
	static const size_t sizes[] = {4, 8, 8, 16};
	return sizes[type];
}

static inline V fix(int type, V x)
{
	switch (type) {
	case T_FLOAT:
		return (float)creal(x);
	case T_DOUBLE:
		return creal(x);
	case T_FLOAT_COMPLEX:
		return CMPLX((float)creal(x), (float)cimag(x));
	default:
		return x;
	}
}

static inline V load(int type, const void *p, long k)
{
	switch (type) {
	case T_FLOAT:
		return ((const float *)p)[k];
	case T_DOUBLE:
		return ((const double *)p)[k];
	case T_FLOAT_COMPLEX:
		return ((const float _Complex *)p)[k];
	default:
		return ((const double _Complex *)p)[k];
	}
}

static inline void store(int type, void *p, long k, V x)
{
	switch (type) {
	case T_FLOAT:
		((float *)p)[k] = (float)creal(x);
		break;
	case T_DOUBLE:
		((double *)p)[k] = creal(x);
		break;
	case T_FLOAT_COMPLEX:
		((float _Complex *)p)[k] = (float _Complex)x;
		break;
	default:
		((double _Complex *)p)[k] = x;
		break;
	}
}

static inline V conj_if(int c, V v)
{
	return c ? conj(v) : v;
}

static inline double abs2(V v)
{
	return creal(v) * creal(v) + cimag(v) * cimag(v);
}

/* A point matrix in compressed columns. */
struct csc {
	int m, n;
	long *p;
	int *i;
	V *x;
};

struct csc *csc_new(int m, int n, long nnz);
void csc_free(struct csc *A);
struct csc *csc_transpose(const struct csc *A, int conjugate);
/* Sorts each column's rows and sums duplicates. */
void csc_tidy(struct csc *A);

/* A generic view of the typed public structures. */
struct matrix_view {
	int type;
	int rows, cols; /* in blocks */
	const long *starts;
	const int *indices;
	unsigned transpose, conjugate, triangle, kind, block;
	const void *data;
};

struct dense_view {
	int type;
	int rows, cols, stride;
	unsigned transpose, conjugate;
	void *data;
};

/* op(A) of a public matrix as a point matrix; symmetric and Hermitian storage is mirrored. */
struct csc *csc_from_view(const struct matrix_view *A);
/* The structure only (values 1), as stored with no kind applied. */
struct csc *csc_pattern(const SparseMatrixStructure *S);

/* Element (i, j) of op(X) for a dense view. */
static inline long dense_at(const struct dense_view *X, long i, long j)
{
	return X->transpose ? i * X->stride + j : j * X->stride + i;
}

static inline int dense_rows(const struct dense_view *X)
{
	return X->transpose ? X->cols : X->rows;
}

static inline int dense_cols(const struct dense_view *X)
{
	return X->transpose ? X->rows : X->cols;
}

static inline V dense_get(const struct dense_view *X, long i, long j)
{
	V v = load(X->type, X->data, dense_at(X, i, j));
	return X->conjugate ? conj(v) : v;
}

static inline void dense_put(const struct dense_view *X, long i, long j, V v)
{
	store(X->type, X->data, dense_at(X, i, j), X->conjugate ? conj(v) : v);
}

/* Y = alpha op(A) X (+ Y when accumulating). */
void spmv(V alpha, const struct matrix_view *A, const struct dense_view *X, bool accumulate, const struct dense_view *Y);

/* Orderings: a permutation perm (new -> old) of n. */
int *order_amd(const struct csc *A);         /* of A + A' */
int *order_colamd(const struct csc *A);      /* of A'A */

void sparse_report(void (*report)(const char *), const char *format, ...) __attribute__((format(printf, 2, 3)));

#endif
