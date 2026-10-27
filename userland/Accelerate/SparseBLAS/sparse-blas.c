/*
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * libSparseBLAS: Sparse/BLAS.h for float, double and their complex types.
 * A matrix keeps its entries as a list sorted by row then column; insertions
 * queue until a computation or sparse_commit needs them. Values are held as
 * double complex and rounded to the matrix's type after every operation;
 * products accumulate with fused multiply-adds, as macOS's kernels do.
 *
 * Behaviour follows macOS where it is defined: inserted zeros are not stored
 * (but overwrite a stored value), the first of several queued insertions at
 * one place wins, matrix properties only gate the triangular solves, a
 * triangular solve divides by alpha (x = (alpha T)^-1 x) and the
 * permutations swap rows in turn as the header describes. Where macOS crashes
 * or corrupts (an invalid order or transpose, a short leading dimension,
 * column permutations, variable-block products) Finch does what the header
 * says.
 */
#include <complex.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <vecLib/Sparse/BLAS.h>

typedef double _Complex V;

enum { T_FLOAT, T_DOUBLE, T_FLOAT_COMPLEX, T_DOUBLE_COMPLEX };
enum { POINT, BLOCK, VARIABLE_BLOCK };

#define MAGIC 0x53504d58u /* 'SPMX' */

struct entry {
	sparse_index i, j;
	V v;
};

struct matrix {
	unsigned magic;
	int type, format;
	sparse_dimension rows, cols;
	sparse_dimension block_rows, block_cols;
	sparse_dimension *row_offset, *col_offset; /* block starts, block_rows+1 and block_cols+1 */
	long properties;
	int inserted;
	struct entry *e, *queue;
	size_t n, cap, queued, queue_cap;
};

static int is_complex(int type)
{
	return type >= T_FLOAT_COMPLEX;
}

static V fix(int type, V x)
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

/* s + a * b, fused for real types. */
static V mac(int type, V s, V a, V b)
{
	if (!is_complex(type))
		return fix(type, fma(creal(a), creal(b), creal(s)));
	double re = fma(creal(a), creal(b), fma(-cimag(a), cimag(b), creal(s)));
	double im = fma(creal(a), cimag(b), fma(cimag(a), creal(b), cimag(s)));
	return fix(type, CMPLX(re, im));
}

static V mul(int type, V a, V b)
{
	return fix(type, is_complex(type) ? a * b : creal(a) * creal(b));
}

static V divide(int type, V a, V b)
{
	return fix(type, is_complex(type) ? a / b : creal(a) / creal(b));
}

static V get(int type, const void *p, long k)
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

static void put(int type, void *p, long k, V x)
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

/* |x| as the norms count it: |re| + |im| for complex values (as BLAS's asum). */
static double abs1(V x)
{
	return fabs(creal(x)) + fabs(cimag(x));
}

static double abs2(V x)
{
	return creal(x) * creal(x) + cimag(x) * cimag(x);
}

static double round_real(int type, double x)
{
	return type == T_FLOAT || type == T_FLOAT_COMPLEX ? (double)(float)x : x;
}

#pragma mark - Storage

static struct matrix *matrix_of(void *A)
{
	struct matrix *m = A;
	return m && m->magic == MAGIC ? m : NULL;
}

static struct matrix *create(int type, int format, sparse_dimension rows, sparse_dimension cols)
{
	struct matrix *m = calloc(1, sizeof *m);
	if (!m)
		return NULL;
	m->magic = MAGIC;
	m->type = type;
	m->format = format;
	m->rows = rows;
	m->cols = cols;
	return m;
}

static int by_place(const void *a, const void *b)
{
	const struct entry *x = a, *y = b;
	if (x->i != y->i)
		return x->i < y->i ? -1 : 1;
	if (x->j != y->j)
		return x->j < y->j ? -1 : 1;
	return 0;
}

static void reserve(struct entry **e, size_t *cap, size_t need)
{
	if (need <= *cap)
		return;
	size_t c = *cap ? *cap * 2 : 16;
	while (c < need)
		c *= 2;
	*e = realloc(*e, c * sizeof **e);
	*cap = c;
}

static void enqueue(struct matrix *m, sparse_index i, sparse_index j, V v)
{
	reserve(&m->queue, &m->queue_cap, m->queued + 1);
	m->queue[m->queued++] = (struct entry){i, j, fix(m->type, v)};
	m->inserted = 1;
}

static struct entry *find(struct matrix *m, sparse_index i, sparse_index j)
{
	struct entry key = {i, j, 0};
	return bsearch(&key, m->e, m->n, sizeof key, by_place);
}

static void commit(struct matrix *m)
{
	if (!m->queued)
		return;
	size_t q = m->queued;
	struct entry *queue = m->queue;
	struct entry *sorted = malloc(q * sizeof *sorted);
	/* Sort by place keeping arrival order (a merge sort of indices). */
	size_t *idx = malloc(q * sizeof *idx);
	for (size_t k = 0; k < q; k++)
		idx[k] = k;
	for (size_t width = 1; width < q; width *= 2) {
		size_t *tmp = malloc(q * sizeof *tmp);
		for (size_t lo = 0; lo < q; lo += 2 * width) {
			size_t mid = lo + width < q ? lo + width : q, hi = lo + 2 * width < q ? lo + 2 * width : q;
			size_t a = lo, b = mid, t = lo;
			while (a < mid && b < hi)
				tmp[t++] = by_place(&queue[idx[b]], &queue[idx[a]]) < 0 ? idx[b++] : idx[a++];
			while (a < mid)
				tmp[t++] = idx[a++];
			while (b < hi)
				tmp[t++] = idx[b++];
		}
		memcpy(idx, tmp, q * sizeof *tmp);
		free(tmp);
	}
	for (size_t k = 0; k < q; k++)
		sorted[k] = queue[idx[k]];
	free(idx);
	m->queued = 0;
	/* Merge: the first queued value at a place wins; a stored value is overwritten. */
	struct entry *out = NULL;
	size_t n = 0, cap = 0, a = 0, b = 0;
	while (a < m->n || b < q) {
		struct entry next;
		if (b >= q || (a < m->n && by_place(&m->e[a], &sorted[b]) < 0)) {
			next = m->e[a++];
		} else {
			struct entry first = sorted[b];
			while (b < q && by_place(&sorted[b], &first) == 0)
				b++;
			if (a < m->n && by_place(&m->e[a], &first) == 0) {
				next = m->e[a++];
				next.v = first.v;
			} else if (first.v != 0) {
				next = first;
			} else {
				continue;
			}
		}
		reserve(&out, &cap, n + 1);
		out[n++] = next;
	}
	free(sorted);
	free(m->e);
	m->e = out;
	m->n = n;
	m->cap = cap;
}

static void resort(struct matrix *m)
{
	qsort(m->e, m->n, sizeof *m->e, by_place);
}

/* The matrix as a dense row-major array. */
static void dense_of(struct matrix *m, V *d)
{
	memset(d, 0, m->rows * m->cols * sizeof *d);
	for (size_t k = 0; k < m->n; k++)
		d[m->e[k].i * (sparse_index)m->cols + m->e[k].j] = m->e[k].v;
}

#pragma mark - Level 1

static V inner_dense(int type, sparse_dimension nz, const void *x, const sparse_index *indx, const void *y,
    sparse_stride incy)
{
	V s = 0;
	for (sparse_dimension k = 0; k < nz; k++)
		s = mac(type, s, get(type, x, (long)k), get(type, y, indx[k] * incy));
	return s;
}

static V inner_sparse(int type, sparse_dimension nzx, sparse_dimension nzy, const void *x, const sparse_index *indx,
    const void *y, const sparse_index *indy)
{
	V s = 0;
	sparse_dimension a = 0, b = 0;
	while (a < nzx && b < nzy) {
		if (indx[a] < indy[b]) {
			a++;
		} else if (indx[a] > indy[b]) {
			b++;
		} else {
			s = mac(type, s, get(type, x, (long)a), get(type, y, (long)b));
			a++;
			b++;
		}
	}
	return s;
}

static void add_with_scale(int type, sparse_dimension nz, V alpha, const void *x, const sparse_index *indx, void *y,
    sparse_stride incy)
{
	if (alpha == 0)
		return;
	for (sparse_dimension k = 0; k < nz; k++) {
		long at = indx[k] * incy;
		put(type, y, at, mac(type, get(type, y, at), alpha, get(type, x, (long)k)));
	}
}

static double vector_norm(int type, sparse_dimension nz, const void *x, sparse_norm norm)
{
	double r = 0;
	if (norm == SPARSE_NORM_R1)
		norm = SPARSE_NORM_TWO;
	for (sparse_dimension k = 0; k < nz; k++) {
		V v = get(type, x, (long)k);
		if (norm == SPARSE_NORM_ONE)
			r = round_real(type, r + abs1(v));
		else if (norm == SPARSE_NORM_TWO)
			r = round_real(type, r + abs2(v));
		else if (abs1(v) > r)
			r = abs1(v);
	}
	return norm == SPARSE_NORM_TWO ? round_real(type, sqrt(r)) : r;
}

static long nonzero_count(int type, sparse_dimension n, const void *x, sparse_stride incx)
{
	long c = 0;
	for (sparse_dimension k = 0; k < n; k++)
		c += get(type, x, (long)k * incx) != 0;
	return c;
}

static long pack(int type, sparse_dimension n, sparse_dimension nz, const void *x, sparse_stride incx, void *y,
    sparse_index *indy)
{
	long c = 0;
	for (sparse_dimension k = 0; k < n && (sparse_dimension)c < nz; k++) {
		V v = get(type, x, (long)k * incx);
		if (v != 0) {
			put(type, y, c, v);
			indy[c++] = (sparse_index)k;
		}
	}
	return c;
}

static void unpack(int type, sparse_dimension n, sparse_dimension nz, bool zero, const void *x,
    const sparse_index *indx, void *y, sparse_stride incy)
{
	if (zero)
		for (sparse_dimension k = 0; k < n; k++)
			put(type, y, (long)k * incy, 0);
	for (sparse_dimension k = 0; k < nz; k++)
		if (indx[k] < (sparse_index)n)
			put(type, y, indx[k] * incy, get(type, x, (long)k));
}

#pragma mark - Level 2

static int transpose_ok(enum CBLAS_TRANSPOSE t, int allow_conj)
{
	return t == CblasNoTrans || t == CblasTrans || (t == CblasConjTrans && allow_conj);
}

static V conj_if(int c, V v)
{
	return c ? conj(v) : v;
}

static sparse_status matrix_vector(int type, enum CBLAS_TRANSPOSE trans, V alpha, void *A, const void *x,
    sparse_stride incx, void *y, sparse_stride incy)
{
	struct matrix *m = matrix_of(A);
	if (!m || m->type != type || !transpose_ok(trans, 1))
		return SPARSE_ILLEGAL_PARAMETER;
	commit(m);
	int t = trans != CblasNoTrans, c = trans == CblasConjTrans && is_complex(type);
	sparse_dimension out = t ? m->cols : m->rows;
	V *s = calloc(out ? out : 1, sizeof *s);
	for (size_t k = 0; k < m->n; k++) {
		struct entry *e = &m->e[k];
		sparse_index r = t ? e->j : e->i, col = t ? e->i : e->j;
		s[r] = mac(type, s[r], conj_if(c, e->v), get(type, x, col * incx));
	}
	for (sparse_dimension r = 0; r < out; r++)
		put(type, y, (long)r * incy, mac(type, get(type, y, (long)r * incy), alpha, s[r]));
	free(s);
	return SPARSE_SUCCESS;
}

/* Solves op(T) X = B column by column over the triangle the properties name, then divides by alpha. */
static sparse_status triangular_solve(int type, enum CBLAS_TRANSPOSE trans, V alpha, struct matrix *m, void *b,
    long nrhs, long row_step, long col_step)
{
	commit(m);
	int upper = (m->properties & SPARSE_UPPER_TRIANGULAR) != 0;
	int t = trans == CblasTrans;
	long n = (long)m->rows;
	V *d = malloc((n ? n * n : 1) * sizeof *d), *x = malloc((n ? n : 1) * sizeof *x);
	memset(d, 0, (n ? n * n : 1) * sizeof *d);
	for (size_t k = 0; k < m->n; k++) {
		struct entry *e = &m->e[k];
		if (e->i < n && e->j < n && (upper ? e->j >= e->i : e->j <= e->i))
			d[t ? e->j * n + e->i : e->i * n + e->j] = e->v;
	}
	/* op(T) is lower when T is lower and untransposed, or upper and transposed. */
	int lower = upper == t;
	for (long r = 0; r < nrhs; r++) {
		/* macOS divides by alpha before a transposed solve and after an untransposed one. */
		for (long i = 0; i < n; i++)
			x[i] = get(type, b, i * row_step + r * col_step);
		if (t)
			for (long i = 0; i < n; i++)
				x[i] = divide(type, x[i], alpha);
		for (long s = 0; s < n; s++) {
			long i = lower ? s : n - 1 - s;
			V sum = x[i];
			if (lower)
				for (long k = 0; k < i; k++)
					sum = mac(type, sum, -d[i * n + k], x[k]);
			else
				for (long k = n - 1; k > i; k--)
					sum = mac(type, sum, -d[i * n + k], x[k]);
			x[i] = divide(type, sum, d[i * n + i]);
		}
		for (long i = 0; i < n; i++)
			put(type, b, i * row_step + r * col_step, t ? x[i] : divide(type, x[i], alpha));
	}
	free(d);
	free(x);
	return SPARSE_SUCCESS;
}

static int is_triangular(struct matrix *m)
{
	return (m->properties & (SPARSE_UPPER_TRIANGULAR | SPARSE_LOWER_TRIANGULAR)) != 0;
}

static sparse_status vector_triangular_solve(int type, enum CBLAS_TRANSPOSE trans, V alpha, void *T, void *x,
    sparse_stride incx)
{
	struct matrix *m = matrix_of(T);
	if (!m || m->type != type || !transpose_ok(trans, 0) || !is_triangular(m))
		return SPARSE_ILLEGAL_PARAMETER;
	return triangular_solve(type, trans, alpha, m, x, 1, incx, 0);
}

static sparse_status outer_product(int type, sparse_dimension M, sparse_dimension N, sparse_dimension nz, V alpha,
    const void *x, sparse_stride incx, const void *y, const sparse_index *indy, void **C)
{
	if (nz > N)
		return SPARSE_ILLEGAL_PARAMETER;
	struct matrix *m = create(type, POINT, M, N);
	if (!m) {
		*C = NULL;
		return SPARSE_SYSTEM_ERROR;
	}
	for (sparse_dimension i = 0; i < M; i++) {
		V xi = mul(type, alpha, get(type, x, (long)i * incx));
		for (sparse_dimension k = 0; k < nz; k++)
			enqueue(m, (sparse_index)i, indy[k], mul(type, xi, get(type, y, (long)k)));
	}
	commit(m);
	*C = m;
	return SPARSE_SUCCESS;
}

/* Swap row (or column) k with perm[k], for k in turn. */
static sparse_status permute(int type, void *A, const sparse_index *perm, int columns)
{
	struct matrix *m = matrix_of(A);
	if (!m || m->type != type)
		return SPARSE_ILLEGAL_PARAMETER;
	commit(m);
	sparse_dimension n = columns ? m->cols : m->rows;
	sparse_index *at = malloc((n ? n : 1) * sizeof *at), *from = malloc((n ? n : 1) * sizeof *from);
	for (sparse_dimension k = 0; k < n; k++)
		at[k] = (sparse_index)k;
	for (sparse_dimension k = 0; k < n; k++) {
		sparse_index t = at[k];
		at[k] = at[perm[k]];
		at[perm[k]] = t;
	}
	for (sparse_dimension k = 0; k < n; k++)
		from[at[k]] = (sparse_index)k;
	for (size_t k = 0; k < m->n; k++) {
		if (columns)
			m->e[k].j = from[m->e[k].j];
		else
			m->e[k].i = from[m->e[k].i];
	}
	resort(m);
	free(at);
	free(from);
	return SPARSE_SUCCESS;
}

static double elementwise_norm(int type, void *A, sparse_norm norm)
{
	struct matrix *m = matrix_of(A);
	if (!m || m->type != type)
		return NAN;
	commit(m);
	double r = 0;
	if (norm == SPARSE_NORM_R1) {
		double *col = calloc(m->cols ? m->cols : 1, sizeof *col);
		for (size_t k = 0; k < m->n; k++)
			col[m->e[k].j] = round_real(type, col[m->e[k].j] + abs2(m->e[k].v));
		for (sparse_dimension j = 0; j < m->cols; j++)
			r = round_real(type, r + round_real(type, sqrt(col[j])));
		free(col);
		return r;
	}
	for (size_t k = 0; k < m->n; k++) {
		V v = m->e[k].v;
		if (norm == SPARSE_NORM_ONE)
			r = round_real(type, r + abs1(v));
		else if (norm == SPARSE_NORM_TWO)
			r = round_real(type, r + abs2(v));
		else if (abs1(v) > r)
			r = abs1(v);
	}
	return norm == SPARSE_NORM_TWO ? round_real(type, sqrt(r)) : r;
}

/* The largest singular value: power iteration on A^H A until it settles. */
static double largest_singular_value(struct matrix *m)
{
	sparse_dimension n = m->cols;
	if (!n || !m->rows)
		return 0;
	V *x = malloc(n * sizeof *x), *y = calloc(m->rows, sizeof *y), *z = malloc(n * sizeof *z);
	for (sparse_dimension j = 0; j < n; j++)
		x[j] = 1 / sqrt((double)n);
	double lambda = 0;
	for (int it = 0; it < 10000; it++) {
		memset(y, 0, m->rows * sizeof *y);
		memset(z, 0, n * sizeof *z);
		for (size_t k = 0; k < m->n; k++)
			y[m->e[k].i] += m->e[k].v * x[m->e[k].j];
		for (size_t k = 0; k < m->n; k++)
			z[m->e[k].j] += conj(m->e[k].v) * y[m->e[k].i];
		double norm = 0;
		for (sparse_dimension j = 0; j < n; j++)
			norm += abs2(z[j]);
		norm = sqrt(norm);
		if (norm == 0) {
			lambda = 0;
			break;
		}
		for (sparse_dimension j = 0; j < n; j++)
			x[j] = z[j] / norm;
		if (fabs(norm - lambda) <= 1e-15 * norm) {
			lambda = norm;
			break;
		}
		lambda = norm;
	}
	free(x);
	free(y);
	free(z);
	return sqrt(lambda);
}

static double operator_norm(int type, void *A, sparse_norm norm)
{
	struct matrix *m = matrix_of(A);
	if (!m || m->type != type)
		return NAN;
	commit(m);
	if (norm == SPARSE_NORM_R1)
		return NAN;
	if (norm == SPARSE_NORM_TWO)
		return round_real(type, largest_singular_value(m));
	int by_column = norm == SPARSE_NORM_ONE;
	sparse_dimension n = by_column ? m->cols : m->rows;
	double *sum = calloc(n ? n : 1, sizeof *sum), r = 0;
	for (size_t k = 0; k < m->n; k++) {
		sparse_index at = by_column ? m->e[k].j : m->e[k].i;
		sum[at] = round_real(type, sum[at] + abs1(m->e[k].v));
	}
	for (sparse_dimension k = 0; k < n; k++)
		if (sum[k] > r)
			r = sum[k];
	free(sum);
	return r;
}

static V trace(int type, void *A, sparse_index offset)
{
	struct matrix *m = matrix_of(A);
	if (!m || m->type != type)
		return 0;
	commit(m);
	V s = 0;
	for (size_t k = 0; k < m->n; k++)
		if (m->e[k].j - m->e[k].i == offset)
			s = fix(type, s + m->e[k].v);
	return s;
}

#pragma mark - Level 3

/* Element (i, j) of a dense matrix in the given order and leading dimension. */
static long dense_at(enum CBLAS_ORDER order, long ld, long i, long j)
{
	return order == CblasRowMajor ? i * ld + j : j * ld + i;
}

static sparse_status product_dense(int type, enum CBLAS_ORDER order, enum CBLAS_TRANSPOSE trans,
    sparse_dimension n, V alpha, void *A, const void *B, sparse_dimension ldb, void *C, sparse_dimension ldc)
{
	struct matrix *m = matrix_of(A);
	if (!m || m->type != type || (order != CblasRowMajor && order != CblasColMajor) || !transpose_ok(trans, 1))
		return SPARSE_ILLEGAL_PARAMETER;
	int t = trans != CblasNoTrans, c = trans == CblasConjTrans && is_complex(type);
	sparse_dimension rows = t ? m->cols : m->rows, inner = t ? m->rows : m->cols;
	if (order == CblasRowMajor ? (ldb < n || ldc < n) : (ldb < inner || ldc < rows))
		return SPARSE_ILLEGAL_PARAMETER;
	commit(m);
	V *s = calloc(rows * n ? rows * n : 1, sizeof *s);
	for (size_t k = 0; k < m->n; k++) {
		struct entry *e = &m->e[k];
		sparse_index r = t ? e->j : e->i, col = t ? e->i : e->j;
		for (sparse_dimension j = 0; j < n; j++)
			s[r * (sparse_index)n + (sparse_index)j] = mac(type, s[r * (sparse_index)n + (sparse_index)j],
			    conj_if(c, e->v), get(type, B, dense_at(order, (long)ldb, col, (long)j)));
	}
	for (sparse_dimension i = 0; i < rows; i++)
		for (sparse_dimension j = 0; j < n; j++) {
			long at = dense_at(order, (long)ldc, (long)i, (long)j);
			put(type, C, at, mac(type, get(type, C, at), alpha, s[i * n + j]));
		}
	free(s);
	return SPARSE_SUCCESS;
}

static sparse_status product_sparse(int type, enum CBLAS_ORDER order, enum CBLAS_TRANSPOSE trans, V alpha, void *A,
    void *B, void *C, sparse_dimension ldc)
{
	struct matrix *a = matrix_of(A), *b = matrix_of(B);
	if (!a || !b || a->type != type || b->type != type || (order != CblasRowMajor && order != CblasColMajor) ||
	    !transpose_ok(trans, 1))
		return SPARSE_ILLEGAL_PARAMETER;
	int t = trans != CblasNoTrans, c = trans == CblasConjTrans && is_complex(type);
	sparse_dimension rows = t ? a->cols : a->rows, n = b->cols;
	if (order == CblasRowMajor ? ldc < n : ldc < rows)
		return SPARSE_ILLEGAL_PARAMETER;
	commit(a);
	commit(b);
	V *db = malloc((b->rows * b->cols ? b->rows * b->cols : 1) * sizeof *db);
	dense_of(b, db);
	V *s = calloc(rows * n ? rows * n : 1, sizeof *s);
	for (size_t k = 0; k < a->n; k++) {
		struct entry *e = &a->e[k];
		sparse_index r = t ? e->j : e->i, col = t ? e->i : e->j;
		if ((sparse_dimension)col >= b->rows)
			continue;
		for (sparse_dimension j = 0; j < n; j++)
			s[r * (sparse_index)n + (sparse_index)j] =
			    mac(type, s[r * (sparse_index)n + (sparse_index)j], conj_if(c, e->v), db[col * (sparse_index)n + (sparse_index)j]);
	}
	for (sparse_dimension i = 0; i < rows; i++)
		for (sparse_dimension j = 0; j < n; j++) {
			long at = dense_at(order, (long)ldc, (long)i, (long)j);
			put(type, C, at, mac(type, get(type, C, at), alpha, s[i * n + j]));
		}
	free(db);
	free(s);
	return SPARSE_SUCCESS;
}

static sparse_status matrix_triangular_solve(int type, enum CBLAS_ORDER order, enum CBLAS_TRANSPOSE trans,
    sparse_dimension nrhs, V alpha, void *T, void *B, sparse_dimension ldb)
{
	struct matrix *m = matrix_of(T);
	if (!m || m->type != type || (order != CblasRowMajor && order != CblasColMajor) || !transpose_ok(trans, 0) ||
	    !is_triangular(m) || (order == CblasRowMajor ? ldb < nrhs : ldb < m->rows))
		return SPARSE_ILLEGAL_PARAMETER;
	long row_step = order == CblasRowMajor ? (long)ldb : 1, col_step = order == CblasRowMajor ? 1 : (long)ldb;
	return triangular_solve(type, trans, alpha, m, B, (long)nrhs, row_step, col_step);
}

#pragma mark - Point-wise matrices

static void *point_matrix(int type, void *A)
{
	struct matrix *m = matrix_of(A);
	return m && m->type == type && m->format == POINT ? m : NULL;
}

static sparse_status insert_entries(int type, void *A, sparse_dimension n, const void *val, const sparse_index *indx,
    const sparse_index *jndx, sparse_index fixed_i, sparse_index fixed_j)
{
	struct matrix *m = point_matrix(type, A);
	if (!m)
		return SPARSE_ILLEGAL_PARAMETER;
	for (sparse_dimension k = 0; k < n; k++)
		enqueue(m, indx ? indx[k] : fixed_i, jndx ? jndx[k] : fixed_j, get(type, val, (long)k));
	return SPARSE_SUCCESS;
}

/* Up to nz entries of a row (or column) from start on; *end is the next one's index. */
static sparse_status extract(int type, void *A, sparse_index line, sparse_index start, sparse_index *end,
    sparse_dimension nz, void *val, sparse_index *ind, int column)
{
	struct matrix *m = point_matrix(type, A);
	if (!m)
		return SPARSE_ILLEGAL_PARAMETER;
	commit(m);
	long c = 0;
	*end = (sparse_index)(column ? m->rows : m->cols);
	for (size_t k = 0; k < m->n; k++) {
		struct entry *e = &m->e[k];
		sparse_index along = column ? e->i : e->j;
		if ((column ? e->j : e->i) != line || along < start)
			continue;
		if ((sparse_dimension)c == nz) {
			*end = along;
			break;
		}
		put(type, val, c, e->v);
		ind[c++] = along;
	}
	return (sparse_status)c;
}

#pragma mark - Block matrices

static struct matrix *block_matrix(int type, sparse_dimension Mb, sparse_dimension Nb, const sparse_dimension *K,
    const sparse_dimension *L, sparse_dimension k, sparse_dimension l)
{
	sparse_dimension *ro = malloc((Mb + 1) * sizeof *ro), *co = malloc((Nb + 1) * sizeof *co);
	ro[0] = co[0] = 0;
	for (sparse_dimension i = 0; i < Mb; i++)
		ro[i + 1] = ro[i] + (K ? K[i] : k);
	for (sparse_dimension j = 0; j < Nb; j++)
		co[j + 1] = co[j] + (L ? L[j] : l);
	struct matrix *m = create(type, K ? VARIABLE_BLOCK : BLOCK, ro[Mb], co[Nb]);
	if (!m) {
		free(ro);
		free(co);
		return NULL;
	}
	m->block_rows = Mb;
	m->block_cols = Nb;
	m->row_offset = ro;
	m->col_offset = co;
	return m;
}

static void *blocked_matrix(int type, void *A)
{
	struct matrix *m = matrix_of(A);
	return m && m->type == type && m->format != POINT ? m : NULL;
}

static sparse_status insert_block(int type, void *A, const void *val, sparse_dimension row_stride,
    sparse_dimension col_stride, sparse_index bi, sparse_index bj)
{
	struct matrix *m = blocked_matrix(type, A);
	if (!m)
		return SPARSE_ILLEGAL_PARAMETER;
	sparse_dimension r0 = m->row_offset[bi], c0 = m->col_offset[bj];
	sparse_dimension k = m->row_offset[bi + 1] - r0, l = m->col_offset[bj + 1] - c0;
	for (sparse_dimension i = 0; i < k; i++)
		for (sparse_dimension j = 0; j < l; j++)
			enqueue(m, (sparse_index)(r0 + i), (sparse_index)(c0 + j),
			    get(type, val, (long)(i * row_stride + j * col_stride)));
	return SPARSE_SUCCESS;
}

static sparse_status extract_block(int type, void *A, sparse_index bi, sparse_index bj, sparse_dimension row_stride,
    sparse_dimension col_stride, void *val)
{
	struct matrix *m = blocked_matrix(type, A);
	if (!m)
		return SPARSE_ILLEGAL_PARAMETER;
	commit(m);
	sparse_dimension r0 = m->row_offset[bi], c0 = m->col_offset[bj];
	sparse_dimension k = m->row_offset[bi + 1] - r0, l = m->col_offset[bj + 1] - c0;
	for (sparse_dimension i = 0; i < k; i++)
		for (sparse_dimension j = 0; j < l; j++) {
			struct entry *e = find(m, (sparse_index)(r0 + i), (sparse_index)(c0 + j));
			put(type, val, (long)(i * row_stride + j * col_stride), e ? e->v : 0);
		}
	return SPARSE_SUCCESS;
}

/* The size of the block holding point row (or column) i. */
static long block_dimension(void *A, sparse_index i, int column)
{
	struct matrix *m = matrix_of(A);
	if (!m || m->format == POINT || i < 0)
		return 0;
	sparse_dimension n = column ? m->block_cols : m->block_rows;
	sparse_dimension *off = column ? m->col_offset : m->row_offset;
	for (sparse_dimension b = 0; b < n; b++)
		if ((sparse_dimension)i < off[b + 1])
			return (long)(off[b + 1] - off[b]);
	return 0;
}

#pragma mark - Typed entry points

#define DEFINE_TYPE(S, T, R, ID)                                                                              \
	T sparse_inner_product_dense_##S(sparse_dimension nz, const T *x, const sparse_index *indx, const T *y,  \
	    sparse_stride incy)                                                                                   \
	{                                                                                                         \
		return (T)inner_dense(ID, nz, x, indx, y, incy);                                                  \
	}                                                                                                         \
	T sparse_inner_product_sparse_##S(sparse_dimension nzx, sparse_dimension nzy, const T *x,                \
	    const sparse_index *indx, const T *y, const sparse_index *indy)                                       \
	{                                                                                                         \
		return (T)inner_sparse(ID, nzx, nzy, x, indx, y, indy);                                           \
	}                                                                                                         \
	void sparse_vector_add_with_scale_dense_##S(sparse_dimension nz, T alpha, const T *x,                    \
	    const sparse_index *indx, T *y, sparse_stride incy)                                                   \
	{                                                                                                         \
		add_with_scale(ID, nz, alpha, x, indx, y, incy);                                                  \
	}                                                                                                         \
	R sparse_vector_norm_##S(sparse_dimension nz, const T *x, const sparse_index *indx, sparse_norm norm)     \
	{                                                                                                         \
		return (R)vector_norm(ID, nz, x, norm);                                                           \
	}                                                                                                         \
	sparse_status sparse_matrix_vector_product_dense_##S(enum CBLAS_TRANSPOSE transa, T alpha,               \
	    sparse_matrix_##S A, const T *x, sparse_stride incx, T *y, sparse_stride incy)                        \
	{                                                                                                         \
		return matrix_vector(ID, transa, alpha, A, x, incx, y, incy);                                     \
	}                                                                                                         \
	sparse_status sparse_vector_triangular_solve_dense_##S(enum CBLAS_TRANSPOSE transt, T alpha,             \
	    sparse_matrix_##S T_, T *x, sparse_stride incx)                                                       \
	{                                                                                                         \
		return vector_triangular_solve(ID, transt, alpha, T_, x, incx);                                   \
	}                                                                                                         \
	sparse_status sparse_outer_product_dense_##S(sparse_dimension M, sparse_dimension N, sparse_dimension nz, \
	    T alpha, const T *x, sparse_stride incx, const T *y, const sparse_index *indy, sparse_matrix_##S *C)  \
	{                                                                                                         \
		return outer_product(ID, M, N, nz, alpha, x, incx, y, indy, (void **)C);                          \
	}                                                                                                         \
	sparse_status sparse_permute_rows_##S(sparse_matrix_##S A, const sparse_index *perm)                     \
	{                                                                                                         \
		return permute(ID, A, perm, 0);                                                                   \
	}                                                                                                         \
	sparse_status sparse_permute_cols_##S(sparse_matrix_##S A, const sparse_index *perm)                     \
	{                                                                                                         \
		return permute(ID, A, perm, 1);                                                                   \
	}                                                                                                         \
	R sparse_elementwise_norm_##S(sparse_matrix_##S A, sparse_norm norm)                                     \
	{                                                                                                         \
		return (R)elementwise_norm(ID, A, norm);                                                          \
	}                                                                                                         \
	R sparse_operator_norm_##S(sparse_matrix_##S A, sparse_norm norm)                                        \
	{                                                                                                         \
		return (R)operator_norm(ID, A, norm);                                                             \
	}                                                                                                         \
	T sparse_matrix_trace_##S(sparse_matrix_##S A, sparse_index offset)                                      \
	{                                                                                                         \
		return (T)trace(ID, A, offset);                                                                   \
	}                                                                                                         \
	sparse_status sparse_matrix_product_dense_##S(enum CBLAS_ORDER order, enum CBLAS_TRANSPOSE transa,       \
	    sparse_dimension n, T alpha, sparse_matrix_##S A, const T *B, sparse_dimension ldb, T *C,             \
	    sparse_dimension ldc)                                                                                 \
	{                                                                                                         \
		return product_dense(ID, order, transa, n, alpha, A, B, ldb, C, ldc);                             \
	}                                                                                                         \
	sparse_status sparse_matrix_product_sparse_##S(enum CBLAS_ORDER order, enum CBLAS_TRANSPOSE transa,      \
	    T alpha, sparse_matrix_##S A, sparse_matrix_##S B, T *C, sparse_dimension ldc)                        \
	{                                                                                                         \
		return product_sparse(ID, order, transa, alpha, A, B, C, ldc);                                    \
	}                                                                                                         \
	sparse_status sparse_matrix_triangular_solve_dense_##S(enum CBLAS_ORDER order,                           \
	    enum CBLAS_TRANSPOSE transt, sparse_dimension nrhs, T alpha, sparse_matrix_##S T_, T *B,              \
	    sparse_dimension ldb)                                                                                 \
	{                                                                                                         \
		return matrix_triangular_solve(ID, order, transt, nrhs, alpha, T_, B, ldb);                       \
	}                                                                                                         \
	sparse_matrix_##S sparse_matrix_create_##S(sparse_dimension M, sparse_dimension N)                       \
	{                                                                                                         \
		return (sparse_matrix_##S)create(ID, POINT, M, N);                                                \
	}                                                                                                         \
	sparse_status sparse_insert_entry_##S(sparse_matrix_##S A, T val, sparse_index i, sparse_index j)        \
	{                                                                                                         \
		return insert_entries(ID, A, 1, &val, NULL, NULL, i, j);                                          \
	}                                                                                                         \
	sparse_status sparse_insert_entries_##S(sparse_matrix_##S A, sparse_dimension N, const T *val,           \
	    const sparse_index *indx, const sparse_index *jndx)                                                   \
	{                                                                                                         \
		return insert_entries(ID, A, N, val, indx, jndx, 0, 0);                                           \
	}                                                                                                         \
	sparse_status sparse_insert_col_##S(sparse_matrix_##S A, sparse_index j, sparse_dimension nz,            \
	    const T *val, const sparse_index *indx)                                                               \
	{                                                                                                         \
		return insert_entries(ID, A, nz, val, indx, NULL, 0, j);                                          \
	}                                                                                                         \
	sparse_status sparse_insert_row_##S(sparse_matrix_##S A, sparse_index i, sparse_dimension nz,            \
	    const T *val, const sparse_index *jndx)                                                               \
	{                                                                                                         \
		return insert_entries(ID, A, nz, val, NULL, jndx, i, 0);                                          \
	}                                                                                                         \
	sparse_status sparse_extract_sparse_row_##S(sparse_matrix_##S A, sparse_index row,                       \
	    sparse_index column_start, sparse_index *column_end, sparse_dimension nz, T *val, sparse_index *jndx) \
	{                                                                                                         \
		return extract(ID, A, row, column_start, column_end, nz, val, jndx, 0);                           \
	}                                                                                                         \
	sparse_status sparse_extract_sparse_column_##S(sparse_matrix_##S A, sparse_index column,                 \
	    sparse_index row_start, sparse_index *row_end, sparse_dimension nz, T *val, sparse_index *indx)       \
	{                                                                                                         \
		return extract(ID, A, column, row_start, row_end, nz, val, indx, 1);                              \
	}                                                                                                         \
	sparse_matrix_##S sparse_matrix_block_create_##S(sparse_dimension Mb, sparse_dimension Nb,               \
	    sparse_dimension k, sparse_dimension l)                                                               \
	{                                                                                                         \
		return (sparse_matrix_##S)block_matrix(ID, Mb, Nb, NULL, NULL, k, l);                             \
	}                                                                                                         \
	sparse_matrix_##S sparse_matrix_variable_block_create_##S(sparse_dimension Mb, sparse_dimension Nb,      \
	    const sparse_dimension *K, const sparse_dimension *L)                                                 \
	{                                                                                                         \
		return (sparse_matrix_##S)block_matrix(ID, Mb, Nb, K, L, 0, 0);                                   \
	}                                                                                                         \
	sparse_status sparse_insert_block_##S(sparse_matrix_##S A, const T *val, sparse_dimension row_stride,    \
	    sparse_dimension col_stride, sparse_index bi, sparse_index bj)                                        \
	{                                                                                                         \
		return insert_block(ID, A, val, row_stride, col_stride, bi, bj);                                  \
	}                                                                                                         \
	sparse_status sparse_extract_block_##S(sparse_matrix_##S A, sparse_index bi, sparse_index bj,            \
	    sparse_dimension row_stride, sparse_dimension col_stride, T *val)                                     \
	{                                                                                                         \
		return extract_block(ID, A, bi, bj, row_stride, col_stride, val);                                 \
	}                                                                                                         \
	long sparse_get_vector_nonzero_count_##S(sparse_dimension N, const T *x, sparse_stride incx)             \
	{                                                                                                         \
		return nonzero_count(ID, N, x, incx);                                                             \
	}                                                                                                         \
	long sparse_pack_vector_##S(sparse_dimension N, sparse_dimension nz, const T *x, sparse_stride incx,     \
	    T *y, sparse_index *indy)                                                                             \
	{                                                                                                         \
		return pack(ID, N, nz, x, incx, y, indy);                                                         \
	}                                                                                                         \
	void sparse_unpack_vector_##S(sparse_dimension N, sparse_dimension nz, bool zero, const T *x,            \
	    const sparse_index *indx, T *y, sparse_stride incy)                                                   \
	{                                                                                                         \
		unpack(ID, N, nz, zero, x, indx, y, incy);                                                        \
	}

DEFINE_TYPE(float, float, float, T_FLOAT)
DEFINE_TYPE(double, double, double, T_DOUBLE)
DEFINE_TYPE(float_complex, float _Complex, float, T_FLOAT_COMPLEX)
DEFINE_TYPE(double_complex, double _Complex, double, T_DOUBLE_COMPLEX)

#pragma mark - Any matrix

long sparse_get_block_dimension_for_row(void *A, sparse_index i)
{
	return block_dimension(A, i, 0);
}

long sparse_get_block_dimension_for_col(void *A, sparse_index j)
{
	return block_dimension(A, j, 1);
}

sparse_status sparse_commit(void *A)
{
	struct matrix *m = matrix_of(A);
	if (!m)
		return SPARSE_ILLEGAL_PARAMETER;
	commit(m);
	return SPARSE_SUCCESS;
}

long sparse_get_matrix_property(void *A, sparse_matrix_property pname)
{
	struct matrix *m = matrix_of(A);
	return m ? (m->properties & (long)pname) : 0;
}

sparse_status sparse_set_matrix_property(void *A, sparse_matrix_property pname)
{
	struct matrix *m = matrix_of(A);
	if (!m)
		return SPARSE_ILLEGAL_PARAMETER;
	if (m->inserted)
		return SPARSE_CANNOT_SET_PROPERTY;
	m->properties |= (long)pname;
	return SPARSE_SUCCESS;
}

sparse_dimension sparse_get_matrix_number_of_rows(void *A)
{
	struct matrix *m = matrix_of(A);
	return m ? m->rows : 0;
}

sparse_dimension sparse_get_matrix_number_of_columns(void *A)
{
	struct matrix *m = matrix_of(A);
	return m ? m->cols : 0;
}

long sparse_get_matrix_nonzero_count(void *A)
{
	struct matrix *m = matrix_of(A);
	if (!m)
		return 0;
	commit(m);
	return (long)m->n;
}

static long line_count(void *A, sparse_index line, int column)
{
	struct matrix *m = matrix_of(A);
	if (!m)
		return 0;
	commit(m);
	long c = 0;
	for (size_t k = 0; k < m->n; k++)
		c += (column ? m->e[k].j : m->e[k].i) == line;
	return c;
}

long sparse_get_matrix_nonzero_count_for_row(void *A, sparse_index i)
{
	return line_count(A, i, 0);
}

long sparse_get_matrix_nonzero_count_for_column(void *A, sparse_index j)
{
	return line_count(A, j, 1);
}

sparse_status sparse_matrix_destroy(void *A)
{
	struct matrix *m = matrix_of(A);
	if (!m)
		return SPARSE_ILLEGAL_PARAMETER;
	m->magic = 0;
	free(m->e);
	free(m->queue);
	free(m->row_offset);
	free(m->col_offset);
	free(m);
	return SPARSE_SUCCESS;
}
