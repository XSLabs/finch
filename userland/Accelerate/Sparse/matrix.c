/*
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Sparse matrices: conversion from coordinates and from Sparse BLAS objects,
 * multiplication, and the internal compressed-column form.
 */
#include <os/log.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "typed.h"

#pragma mark - Compressed columns

struct csc *csc_new(int m, int n, long nnz)
{
	struct csc *A = calloc(1, sizeof *A);
	A->m = m;
	A->n = n;
	A->p = calloc((size_t)n + 1, sizeof *A->p);
	A->i = malloc((nnz ? (size_t)nnz : 1) * sizeof *A->i);
	A->x = malloc((nnz ? (size_t)nnz : 1) * sizeof *A->x);
	return A;
}

void csc_free(struct csc *A)
{
	if (!A)
		return;
	free(A->p);
	free(A->i);
	free(A->x);
	free(A);
}

struct csc *csc_transpose(const struct csc *A, int conjugate)
{
	long nnz = A->p[A->n];
	struct csc *T = csc_new(A->n, A->m, nnz);
	long *next = calloc((size_t)A->m + 1, sizeof *next);
	for (long k = 0; k < nnz; k++)
		next[A->i[k] + 1]++;
	for (int r = 0; r < A->m; r++)
		next[r + 1] += next[r];
	memcpy(T->p, next, ((size_t)A->m + 1) * sizeof *next);
	for (int j = 0; j < A->n; j++)
		for (long k = A->p[j]; k < A->p[j + 1]; k++) {
			long at = next[A->i[k]]++;
			T->i[at] = j;
			T->x[at] = conj_if(conjugate, A->x[k]);
		}
	free(next);
	return T;
}

static int by_row(const void *a, const void *b)
{
	const struct {
		int i;
		V x;
	} *x = a, *y = b;
	return (x->i > y->i) - (x->i < y->i);
}

void csc_tidy(struct csc *A)
{
	struct pair {
		int i;
		V x;
	};
	long out = 0;
	struct pair *tmp = NULL;
	size_t cap = 0;
	for (int j = 0; j < A->n; j++) {
		long a = A->p[j], b = A->p[j + 1];
		size_t len = (size_t)(b - a);
		if (len > cap) {
			cap = len;
			tmp = realloc(tmp, cap * sizeof *tmp);
		}
		for (size_t k = 0; k < len; k++)
			tmp[k] = (struct pair){A->i[a + (long)k], A->x[a + (long)k]};
		qsort(tmp, len, sizeof *tmp, by_row);
		A->p[j] = out;
		for (size_t k = 0; k < len; k++) {
			if (k && tmp[k].i == tmp[k - 1].i) {
				A->x[out - 1] += tmp[k].x;
				continue;
			}
			A->i[out] = tmp[k].i;
			A->x[out++] = tmp[k].x;
		}
	}
	A->p[A->n] = out;
	free(tmp);
}

/* Calls emit(r, c, v) for each entry of A (untransposed), mirroring symmetric storage. */
static void each_entry(const struct matrix_view *A, void (^emit)(int r, int c, V v))
{
	int bs = A->block ? A->block : 1;
	int symmetric = A->kind == SparseSymmetric || A->kind == SparseHermitian;
	int triangular = A->kind == SparseTriangular || A->kind == SparseUnitTriangular;
	int lower = A->triangle == SparseLowerTriangle;
	for (int bj = 0; bj < A->cols; bj++)
		for (long k = A->starts[bj]; k < A->starts[bj + 1]; k++) {
			int bi = A->indices[k];
			for (int c = 0; c < bs; c++)
				for (int r = 0; r < bs; r++) {
					int i = bi * bs + r, j = bj * bs + c;
					V v = load(A->type, A->data, k * bs * bs + c * bs + r);
					if ((symmetric || triangular) && i != j && (lower ? i < j : i > j))
						continue;
					if (A->kind == SparseUnitTriangular && i == j)
						continue;
					emit(i, j, v);
					if (symmetric && i != j)
						emit(j, i, A->kind == SparseHermitian ? conj(v) : v);
				}
		}
	if (A->kind == SparseUnitTriangular)
		for (int d = 0; d < A->rows * bs && d < A->cols * bs; d++)
			emit(d, d, 1);
}

struct csc *csc_from_view(const struct matrix_view *A)
{
	int bs = A->block ? A->block : 1;
	int m = A->rows * bs, n = A->cols * bs;
	long nnz = A->starts[A->cols] * bs * bs * 2 + (m < n ? m : n);
	struct csc *C = csc_new(m, n, nnz);
	long *colcount = C->p;
	/* Two passes: count per column, then fill. */
	each_entry(A, ^(int r, int c, V v) {
		(void)r;
		(void)v;
		colcount[c + 1]++;
	});
	for (int j = 0; j < n; j++)
		colcount[j + 1] += colcount[j];
	long *next = malloc(((size_t)n + 1) * sizeof *next);
	memcpy(next, C->p, ((size_t)n + 1) * sizeof *next);
	int *ci = C->i;
	V *cx = C->x;
	each_entry(A, ^(int r, int c, V v) {
		long at = next[c]++;
		ci[at] = r;
		cx[at] = v;
	});
	free(next);
	csc_tidy(C);
	if (A->transpose) {
		struct csc *T = csc_transpose(C, A->conjugate);
		csc_free(C);
		return T;
	}
	return C;
}

struct csc *csc_pattern(const SparseMatrixStructure *S)
{
	struct matrix_view v = {
	    .type = T_DOUBLE,
	    .rows = S->rowCount,
	    .cols = S->columnCount,
	    .starts = S->columnStarts,
	    .indices = S->rowIndices,
	    .transpose = S->attributes.transpose,
	    .triangle = S->attributes.triangle,
	    .kind = S->attributes.kind,
	    .block = S->blockSize,
	};
	int bs = S->blockSize ? S->blockSize : 1;
	long nnz = S->columnStarts[S->columnCount] * bs * bs;
	double *ones = malloc((nnz ? (size_t)nnz : 1) * sizeof *ones);
	for (long k = 0; k < nnz; k++)
		ones[k] = 1;
	v.data = ones;
	struct csc *C = csc_from_view(&v);
	free(ones);
	return C;
}

#pragma mark - Multiplication

void spmv(V alpha, const struct matrix_view *A, const struct dense_view *X, bool accumulate, const struct dense_view *Y)
{
	int bs = A->block ? A->block : 1;
	int m = (A->transpose ? A->cols : A->rows) * bs;
	int nrhs = dense_cols(X);
	V *t = calloc((size_t)m * (nrhs ? (size_t)nrhs : 1), sizeof *t);
	int transpose = A->transpose, conjugate = A->conjugate;
	each_entry(A, ^(int r, int c, V v) {
		int row = transpose ? c : r, col = transpose ? r : c;
		V a = transpose ? conj_if(conjugate, v) : v;
		for (int k = 0; k < nrhs; k++)
			t[(long)k * m + row] += a * dense_get(X, col, k);
	});
	for (int k = 0; k < nrhs; k++)
		for (int i = 0; i < m; i++) {
			V y = accumulate ? dense_get(Y, i, k) : 0;
			dense_put(Y, i, k, fix(Y->type, y + alpha * t[(long)k * m + i]));
		}
	free(t);
}

#pragma mark - Errors

void sparse_report(void (*report)(const char *), const char *format, ...)
{
	char message[256];
	va_list ap;
	va_start(ap, format);
	vsnprintf(message, sizeof message, format, ap);
	va_end(ap);
	if (report) {
		report(message);
		return;
	}
	os_log_error(OS_LOG_DEFAULT, "%{public}s", message);
	_SparseTrap();
}

void _SparseTrap(void)
{
	__builtin_trap();
}

#pragma mark - Complex attributes

SparseKind_t _SparseFromKindComplex(SparseKind_t K)
{
	return K;
}

SparseKind_t _SparseToKindComplex(SparseKind_t K)
{
	return K;
}

SparseAttributes_t _SparseFromAttributeComplex(SparseAttributesComplex_t K)
{
	return (SparseAttributes_t){
	    .transpose = K.transpose,
	    .triangle = K.triangle,
	    .kind = K.kind == SparseHermitian ? SparseSymmetric : K.kind,
	    ._allocatedBySparse = K._allocatedBySparse,
	};
}

SparseAttributesComplex_t _SparseToAttributeComplex(SparseAttributes_t K)
{
	return (SparseAttributesComplex_t){
	    .transpose = K.transpose,
	    .triangle = K.triangle,
	    .kind = K.kind,
	    ._allocatedBySparse = K._allocatedBySparse,
	};
}

SparseMatrixStructure _SparseFromStructureComplex(SparseMatrixStructureComplex K)
{
	return (SparseMatrixStructure){
	    .rowCount = K.rowCount,
	    .columnCount = K.columnCount,
	    .columnStarts = K.columnStarts,
	    .rowIndices = K.rowIndices,
	    .attributes = _SparseFromAttributeComplex(K.attributes),
	    .blockSize = K.blockSize,
	};
}

SparseMatrixStructureComplex _SparseToStructureComplex(SparseMatrixStructure K)
{
	return (SparseMatrixStructureComplex){
	    .rowCount = K.rowCount,
	    .columnCount = K.columnCount,
	    .columnStarts = K.columnStarts,
	    .rowIndices = K.rowIndices,
	    .attributes = _SparseToAttributeComplex(K.attributes),
	    .blockSize = K.blockSize,
	};
}

#pragma mark - Conversion

struct block_entry {
	int r, c;
	long k;     /* input position; negative (-k - 1) when mirrored */
	long order; /* the first input position of this place */
};

static int by_place(const void *a, const void *b)
{
	const struct block_entry *x = a, *y = b;
	if (x->c != y->c)
		return x->c < y->c ? -1 : 1;
	if (x->r != y->r)
		return x->r < y->r ? -1 : 1;
	return (x->k > y->k) - (x->k < y->k);
}

static int by_column_then_first(const void *a, const void *b)
{
	const struct block_entry *x = a, *y = b;
	if (x->c != y->c)
		return x->c < y->c ? -1 : 1;
	if (x->order != y->order)
		return x->order < y->order ? -1 : 1;
	return (x->k > y->k) - (x->k < y->k);
}

/*
 * Builds block compressed columns in storage: column starts, then row
 * indices, then 16-byte aligned values. Duplicates are summed into their
 * first appearance; entries of a
 * symmetric or Hermitian matrix are folded into its stored triangle, and a
 * triangular matrix drops the other triangle (and a unit one its diagonal).
 */
static void convert(int type, int m, int n, long count, int bs, unsigned kind, unsigned triangle, const int *row,
    const int *col, const void *val, char *storage, long **starts_out, int **rows_out, void **data_out)
{
	(void)m;
	if (bs < 1)
		bs = 1;
	struct block_entry *e = malloc((count ? (size_t)count : 1) * sizeof *e);
	int symmetric = kind == SparseSymmetric || kind == SparseHermitian;
	int triangular = kind == SparseTriangular || kind == SparseUnitTriangular;
	int lower = triangle == SparseLowerTriangle;
	long kept = 0;
	for (long k = 0; k < count; k++) {
		int r = row[k], c = col[k];
		int wrong = lower ? r < c : r > c;
		if (triangular && (wrong || (kind == SparseUnitTriangular && r == c)))
			continue;
		int mirrored = symmetric && wrong;
		if (mirrored) {
			int t = r;
			r = c;
			c = t;
		}
		e[kept++] = (struct block_entry){r, c, mirrored ? -k - 1 : k, 0};
	}
	/*
	 * Group duplicates, then order each column's rows by their first
	 * appearance, as macOS does (rows within a column are not sorted).
	 */
	qsort(e, (size_t)kept, sizeof *e, by_place);
	long *first = malloc((kept ? (size_t)kept : 1) * sizeof *first);
	for (long k = 0, g = 0; k < kept; k = g) {
		long lo = e[k].k < 0 ? -e[k].k - 1 : e[k].k;
		for (g = k; g < kept && e[g].r == e[k].r && e[g].c == e[k].c; g++) {
			long at = e[g].k < 0 ? -e[g].k - 1 : e[g].k;
			if (at < lo)
				lo = at;
		}
		for (long q = k; q < g; q++)
			first[q] = lo;
	}
	for (long k = 0; k < kept; k++)
		e[k].order = first[k];
	free(first);
	qsort(e, (size_t)kept, sizeof *e, by_column_then_first);
	long *starts = (long *)storage;
	memset(starts, 0, ((size_t)n + 1) * sizeof *starts);
	long unique = 0;
	for (long k = 0; k < kept; k++)
		if (!k || e[k].r != e[k - 1].r || e[k].c != e[k - 1].c)
			unique++;
	int *rows = (int *)(starts + n + 1);
	size_t offset = ((size_t)(n + 1) * sizeof *starts + (size_t)unique * sizeof *rows + 15) & ~(size_t)15;
	char *data = storage + offset;
	size_t bsz = (size_t)bs * (size_t)bs;
	memset(data, 0, (size_t)unique * bsz * scalar_size(type));
	long at = -1;
	for (long k = 0; k < kept; k++) {
		if (!k || e[k].r != e[k - 1].r || e[k].c != e[k - 1].c) {
			at++;
			rows[at] = e[k].r;
			starts[e[k].c + 1]++;
		}
		long src = e[k].k < 0 ? -e[k].k - 1 : e[k].k;
		int mirrored = e[k].k < 0;
		for (int cc = 0; cc < bs; cc++)
			for (int rr = 0; rr < bs; rr++) {
				/* A mirrored block is transposed (and conjugated when Hermitian). */
				long from = src * (long)bsz + (mirrored ? rr * bs + cc : cc * bs + rr);
				V v = load(type, val, from);
				if (mirrored && kind == SparseHermitian)
					v = conj(v);
				long to = at * (long)bsz + cc * bs + rr;
				store(type, data, to, load(type, data, to) + v);
			}
	}
	for (int j = 0; j < n; j++)
		starts[j + 1] += starts[j];
	free(e);
	*starts_out = starts;
	*rows_out = rows;
	*data_out = data;
}

#define DEFINE_CONVERT(S, ID, T)                                                                              \
	SparseMatrix_##S _SparseConvertFromCoordinate_##S(int m, int n, long nBlock, uint8_t blockSize,         \
	    __typeof__(((SparseMatrix_##S *)0)->structure.attributes) attributes, const int *row, const int *col, \
	    const T *val, char *storage, int *workspace)                                                       \
	{                                                                                                      \
		(void)workspace;                                                                               \
		long *starts;                                                                                  \
		int *rows;                                                                                     \
		void *data;                                                                                    \
		convert(ID, m, n, nBlock, blockSize, attributes.kind, attributes.triangle, row, col, val,      \
		    storage, &starts, &rows, &data);                                                           \
		SparseMatrix_##S A = {0};                                                                      \
		A.structure.rowCount = m;                                                                      \
		A.structure.columnCount = n;                                                                   \
		A.structure.columnStarts = starts;                                                             \
		A.structure.rowIndices = rows;                                                                 \
		A.structure.attributes = attributes;                                                           \
		A.structure.blockSize = blockSize;                                                             \
		A.data = (T *)data;                                                                            \
		return A;                                                                                      \
	}                                                                                                      \
	void _SparseSpMV_##S(T alpha, SparseMatrix_##S A, DenseMatrix_##S x, bool accumulate, DenseMatrix_##S y) \
	{                                                                                                      \
		struct matrix_view a = view_##S(&A);                                                           \
		struct dense_view X = dense_##S(&x), Y = dense_##S(&y);                                        \
		spmv(alpha, &a, &X, accumulate, &Y);                                                           \
	}

FOR_EACH_TYPE(DEFINE_CONVERT)

/* From a Sparse BLAS object: read it row by row through its public interface. */
#define DEFINE_FROM_OPAQUE(S, ID, T, OLD)                                                                    \
	SparseMatrix_##S _SparseConvertFromOpaque_##S(sparse_matrix_##OLD matrix)                             \
	{                                                                                                     \
		int m = (int)sparse_get_matrix_number_of_rows(matrix);                                        \
		int n = (int)sparse_get_matrix_number_of_columns(matrix);                                     \
		long nnz = sparse_get_matrix_nonzero_count(matrix);                                           \
		int *r = malloc((nnz ? (size_t)nnz : 1) * sizeof *r), *c = malloc((nnz ? (size_t)nnz : 1) * sizeof *c); \
		T *v = malloc((nnz ? (size_t)nnz : 1) * sizeof *v);                                           \
		sparse_index *jj = malloc(((size_t)n + 1) * sizeof *jj);                                      \
		long k = 0;                                                                                   \
		for (int i = 0; i < m; i++) {                                                                 \
			sparse_index end;                                                                     \
			long got = sparse_extract_sparse_row_##OLD(matrix, i, 0, &end, (sparse_dimension)n, v + k, jj); \
			for (long q = 0; q < got; q++) {                                                      \
				r[k + q] = i;                                                                 \
				c[k + q] = (int)jj[q];                                                        \
			}                                                                                     \
			if (got > 0)                                                                          \
				k += got;                                                                     \
		}                                                                                             \
		char *storage = malloc(28 + ((size_t)n + 1) * sizeof(long) + (size_t)k * sizeof(int) +        \
		    (size_t)k * sizeof(T));                                                                   \
		SparseMatrix_##S A = _SparseConvertFromCoordinate_##S(m, n, k, 1, (__typeof__(A.structure.attributes)){0}, \
		    r, c, v, storage, NULL);                                                                  \
		A.structure.attributes._allocatedBySparse = true;                                             \
		free(r);                                                                                      \
		free(c);                                                                                      \
		free(v);                                                                                      \
		free(jj);                                                                                     \
		return A;                                                                                     \
	}

DEFINE_FROM_OPAQUE(Float, T_FLOAT, float, float)
DEFINE_FROM_OPAQUE(Double, T_DOUBLE, double, double)
DEFINE_FROM_OPAQUE(Complex_Float, T_FLOAT_COMPLEX, float _Complex, float_complex)
DEFINE_FROM_OPAQUE(Complex_Double, T_DOUBLE_COMPLEX, double _Complex, double_complex)
