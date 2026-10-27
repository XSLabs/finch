/*
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * LinearAlgebra: lazy matrix, vector and splat objects. The argument checks,
 * their order and the statuses they produce follow macOS (which is looser than
 * the headers in places: la_vector_length of any matrix is its row count, an
 * inner product's left operand may be any matrix, a negative splat index is
 * accepted). Error objects carry no scalar type, so passing one as a right
 * operand reports a precision mismatch; a singular solve is found only when its
 * elements are read, and objects already built on it are not told.
 */
#include <vecLib/LinearAlgebra/LinearAlgebra.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "internal.h"

#define FLOAT LA_SCALAR_TYPE_FLOAT
#define DOUBLE LA_SCALAR_TYPE_DOUBLE

enum {
	OP_NONE,
	OP_TRANSPOSE,
	OP_SCALE,
	OP_SUM,
	OP_DIFFERENCE,
	OP_ELEMENTWISE,
	OP_INNER,
	OP_OUTER,
	OP_PRODUCT,
	OP_NORMALIZE,
	OP_SLICE,
	OP_DIAGONAL,
	OP_DIAGONAL_MATRIX,
	OP_ELEMENT,
	OP_FROM_SPLAT,
	OP_SOLVE,
};

/* Product modes: how the operands are read. */
enum { PRODUCT_PLAIN, PRODUCT_LEFT_TRANSPOSED, PRODUCT_RIGHT_TRANSPOSED };

#define OBJ "la_object_t _Nonnull"
#define SIG(name, args) "la_object_t  _Nonnull " name "(" args ")"

static la_object_t make(int kind, unsigned type, la_count_t rows, la_count_t cols, la_attribute_t attributes)
{
	struct la_s *o = la_object_alloc();
	o->kind = kind;
	o->type = type;
	o->rows = rows;
	o->cols = cols;
	o->attributes = attributes;
	return o;
}

static la_object_t lazy(la_object_t o, int op, la_object_t a, la_object_t b)
{
	o->op = op;
	o->a = a ? la_retain(a) : NULL;
	o->b = b ? la_retain(b) : NULL;
	return o;
}

static const char *status_name(la_status_t status, const char **text)
{
	switch (status) {
	case LA_INVALID_PARAMETER_ERROR:
		*text = "One or more parameter has an illegal value";
		return "LA_INVALID_PARAMETER_ERROR";
	case LA_DIMENSION_MISMATCH_ERROR:
		*text = "Encountered a dimension mismatch";
		return "LA_DIMENSION_MISMATCH_ERROR";
	case LA_PRECISION_MISMATCH_ERROR:
		*text = "Precision of underlying scalar values must match";
		return "LA_PRECISION_MISMATCH_ERROR";
	case LA_SINGULAR_ERROR:
		*text = "Matrix is singular";
		return "LA_SINGULAR_ERROR";
	case LA_SLICE_OUT_OF_BOUNDS_ERROR:
		*text = "Requested slice not within bounds";
		return "LA_SLICE_OUT_OF_BOUNDS_ERROR";
	default:
		*text = "Internal error";
		return "LA_INTERNAL_ERROR";
	}
}

/* An error object, logged when the attributes ask for it. */
static la_object_t __attribute__((format(printf, 4, 5)))
fail(const char *signature, la_attribute_t attributes, la_status_t status, const char *format, ...)
{
	la_object_t o = make(LA_KIND_ERROR, 0, 0, 0, attributes);
	o->status = status;
	o->evaluated = 1;
	if (attributes & LA_ATTRIBUTE_ENABLE_LOGGING) {
		const char *text;
		const char *name = status_name(status, &text);
		fprintf(stderr, "%s:\n\t%s: %s\n\t", signature, name, text);
		va_list ap;
		va_start(ap, format);
		vfprintf(stderr, format, ap);
		va_end(ap);
		fputc('\n', stderr);
	}
	return o;
}

static int is_vector(la_object_t o)
{
	return o->kind == LA_KIND_MATRIX && (o->rows == 1 || o->cols == 1);
}

static la_count_t length(la_object_t o)
{
	return o->rows == 1 ? o->cols : o->rows;
}

static double fix(la_object_t o, double x)
{
	return o->type == FLOAT ? (double)(float)x : x;
}

/* Element k of an evaluated operand in row-major order; a splat repeats. */
static double flat(la_object_t o, la_count_t k)
{
	return o->kind == LA_KIND_SPLAT ? o->value : o->v[k];
}

static double at(la_object_t o, la_count_t i, la_count_t j)
{
	return o->kind == LA_KIND_SPLAT ? o->value : o->v[i * o->cols + j];
}

#pragma mark - Solving

/*
 * Cholesky when the matrix looks positive definite, else LU with partial pivoting, as
 * macOS (dpotrf, dgetrf). The triangular solves multiply by reciprocal pivots, as its dtrsm.
 */
#define DEFINE_SOLVE(NAME, T, SQRT)                                                         \
	static int NAME(la_count_t n, la_count_t m, const double *av, const double *bv,     \
	    int rhs_row, la_count_t bcols, double *out)                                      \
	{                                                                                     \
		T *a = malloc(n * n * sizeof(T)), *x = malloc(n * m * sizeof(T));             \
		la_count_t *perm = malloc(n * sizeof(la_count_t));                            \
		int ok = 1, spd = 1;                                                          \
		for (la_count_t i = 0; i < n * n; i++)                                        \
			a[i] = (T)av[i];                                                      \
		for (la_count_t i = 0; i < n; i++)                                            \
			for (la_count_t j = 0; j < m; j++)                                    \
				x[i * m + j] = (T)(rhs_row ? bv[i] : bv[i * bcols + j]);      \
		for (la_count_t i = 0; i < n && spd; i++) {                                   \
			spd = a[i * n + i] > 0;                                               \
			for (la_count_t j = 0; j < i && spd; j++)                             \
				spd = a[i * n + j] == a[j * n + i];                           \
		}                                                                             \
		if (spd) {                                                                    \
			/* L in the lower triangle; the upper triangle keeps A. */            \
			for (la_count_t j = 0; j < n && spd; j++) {                           \
				T d = a[j * n + j];                                           \
				for (la_count_t k = 0; k < j; k++)                            \
					d -= a[j * n + k] * a[j * n + k];                     \
				if (!(d > 0)) {                                               \
					spd = 0;                                              \
					break;                                                \
				}                                                             \
				d = SQRT(d);                                                  \
				a[j * n + j] = d;                                             \
				for (la_count_t i = j + 1; i < n; i++) {                      \
					T s = a[j * n + i];                                   \
					for (la_count_t k = 0; k < j; k++)                    \
						s -= a[i * n + k] * a[j * n + k];             \
					a[i * n + j] = s / d;                                 \
				}                                                             \
			}                                                                     \
			if (spd) {                                                            \
				for (la_count_t c = 0; c < m; c++) {                          \
					for (la_count_t i = 0; i < n; i++) {                  \
						T s = x[i * m + c];                           \
						for (la_count_t k = 0; k < i; k++)            \
							s -= a[i * n + k] * x[k * m + c];     \
						x[i * m + c] = s * ((T)1 / a[i * n + i]);              \
					}                                                     \
					for (la_count_t i = n; i-- > 0;) {                    \
						T s = x[i * m + c];                           \
						for (la_count_t k = i + 1; k < n; k++)        \
							s -= a[k * n + i] * x[k * m + c];     \
						x[i * m + c] = s * ((T)1 / a[i * n + i]);              \
					}                                                     \
				}                                                             \
			}                                                                     \
		}                                                                             \
		if (!spd) {                                                             \
			/* LU of the transpose (macOS hands its row-major matrix to dgetrf as is). */\
			for (la_count_t i = 0; i < n; i++)                              \
				for (la_count_t j = 0; j < n; j++)                      \
					a[i * n + j] = (T)av[j * n + i];                \
			for (la_count_t k = 0; k < n && ok; k++) {                      \
				la_count_t p = k;                                       \
				for (la_count_t i = k + 1; i < n; i++)                  \
					if (fabs((double)a[i * n + k]) > fabs((double)a[p * n + k]))\
						p = i;                                  \
				perm[k] = p;                                            \
				if (a[p * n + k] == 0) {                                \
					ok = 0;                                         \
					break;                                          \
				}                                                       \
				if (p != k)                                             \
					for (la_count_t j = 0; j < n; j++) {            \
						T t = a[k * n + j];                     \
						a[k * n + j] = a[p * n + j];            \
						a[p * n + j] = t;                       \
					}                                               \
				T r = (T)1 / a[k * n + k];                              \
				for (la_count_t i = k + 1; i < n; i++) {                \
					T l = a[i * n + k] * r;                         \
					a[i * n + k] = l;                               \
					for (la_count_t j = k + 1; j < n; j++)          \
						a[i * n + j] -= l * a[k * n + j];       \
				}                                                       \
			}                                                               \
			/* A = U^T L^T P^T: solve with U^T, then L^T, then permute. */  \
			if (ok)                                                         \
				for (la_count_t c = 0; c < m; c++) {                    \
					for (la_count_t i = 0; i < n; i++) {            \
						T s = x[i * m + c];                     \
						for (la_count_t k = 0; k < i; k++)      \
							s -= a[k * n + i] * x[k * m + c];\
						x[i * m + c] = s * ((T)1 / a[i * n + i]);\
					}                                               \
					for (la_count_t i = n; i-- > 0;) {              \
						T s = x[i * m + c];                     \
						for (la_count_t k = i + 1; k < n; k++)  \
							s -= a[k * n + i] * x[k * m + c];\
						x[i * m + c] = s;                       \
					}                                               \
					for (la_count_t k = n; k-- > 0;) {              \
						la_count_t p = perm[k];                 \
						T t = x[k * m + c];                     \
						x[k * m + c] = x[p * m + c];            \
						x[p * m + c] = t;                       \
					}                                               \
				}                                                       \
		}                                                                       \
		if (ok)                                                                       \
			for (la_count_t i = 0; i < n * m; i++)                                \
				out[i] = x[i];                                                \
		free(a);                                                                      \
		free(x);                                                                      \
		free(perm);                                                                   \
		return ok;                                                                    \
	}

DEFINE_SOLVE(solve_float, float, sqrtf)
DEFINE_SOLVE(solve_double, double, sqrt)

#pragma mark - Evaluation

/*
 * Norms of the elements in row-major order. macOS takes a vector's L2 norm with dnrm2
 * (a plain sum of squares) and a matrix's with dlange's scaled sum (dlassq).
 */
static double norm_of(la_object_t o, la_norm_t norm)
{
	la_count_t n = o->rows * o->cols;
	double r = 0;
	if (norm == LA_L2_NORM && !is_vector(o)) {
		double scale = 0, ssq = 1;
		for (la_count_t k = 0; k < n; k++) {
			double x = fabs(o->v[k]);
			if (x == 0)
				continue;
			if (scale < x) {
				ssq = 1 + ssq * (scale / x) * (scale / x);
				scale = x;
			} else {
				ssq += (x / scale) * (x / scale);
			}
		}
		return scale * sqrt(ssq);
	}
	for (la_count_t k = 0; k < n; k++) {
		double x = fabs(o->v[k]);
		if (norm == LA_L1_NORM)
			r += x;
		else if (norm == LA_L2_NORM)
			r += x * x;
		else if (x > r)
			r = x;
	}
	return norm == LA_L2_NORM ? sqrt(r) : r;
}

static void evaluate(la_object_t o)
{
	if (o->evaluated)
		return;
	o->evaluated = 1;
	la_object_t a = o->a, b = o->b;
	if (a)
		evaluate(a);
	if (b)
		evaluate(b);
	if (o->kind == LA_KIND_SPLAT) {
		long k = o->p[0];
		o->value = k < 0 ? 0 : flat(a, (la_count_t)k);
		goto done;
	}
	la_count_t rows = o->rows, cols = o->cols, n = rows * cols;
	double *v = o->v = calloc(n ? n : 1, sizeof(double));
	switch (o->op) {
	case OP_TRANSPOSE:
		for (la_count_t i = 0; i < rows; i++)
			for (la_count_t j = 0; j < cols; j++)
				v[i * cols + j] = a->v[j * rows + i];
		break;
	case OP_SCALE:
		for (la_count_t k = 0; k < n; k++)
			v[k] = fix(o, a->v[k] * o->scalar);
		break;
	case OP_SUM:
	case OP_DIFFERENCE:
	case OP_ELEMENTWISE:
		for (la_count_t k = 0; k < n; k++) {
			double x = flat(a, k), y = flat(b, k);
			v[k] = fix(o, o->op == OP_SUM ? x + y : o->op == OP_DIFFERENCE ? x - y : x * y);
		}
		break;
	case OP_INNER: {
		double s = 0;
		for (la_count_t k = 0; k < (la_count_t)o->p[0]; k++)
			s = fix(o, s + fix(o, flat(a, k) * flat(b, k)));
		v[0] = s;
		break;
	}
	case OP_OUTER:
		for (la_count_t i = 0; i < rows; i++)
			for (la_count_t j = 0; j < cols; j++)
				v[i * cols + j] = fix(o, a->v[i] * b->v[j]);
		break;
	case OP_PRODUCT: {
		la_count_t depth = (la_count_t)o->p[1];
		for (la_count_t i = 0; i < rows; i++)
			for (la_count_t j = 0; j < cols; j++) {
				double s = 0;
				for (la_count_t k = 0; k < depth; k++) {
					double x = o->p[0] == PRODUCT_LEFT_TRANSPOSED ? at(a, k, i) : at(a, i, k);
					double y = o->p[0] == PRODUCT_RIGHT_TRANSPOSED ? at(b, j, k) : at(b, k, j);
					s = fix(o, s + fix(o, x * y));
				}
				v[i * cols + j] = s;
			}
		break;
	}
	case OP_NORMALIZE: {
		double norm = fix(o, norm_of(a, (la_norm_t)o->p[0]));
		for (la_count_t k = 0; k < n; k++)
			v[k] = norm == 0 ? 0 : fix(o, a->v[k] * fix(o, 1 / norm));
		break;
	}
	case OP_SLICE:
		for (la_count_t i = 0; i < rows; i++)
			for (la_count_t j = 0; j < cols; j++)
				v[i * cols + j] = at(a, (la_count_t)(o->p[0] + (long)i * o->p[2]),
				    (la_count_t)(o->p[1] + (long)j * o->p[3]));
		break;
	case OP_DIAGONAL: {
		long d = o->p[0];
		for (la_count_t i = 0; i < rows; i++)
			v[i] = at(a, i + (d < 0 ? (la_count_t)-d : 0), i + (d > 0 ? (la_count_t)d : 0));
		break;
	}
	case OP_DIAGONAL_MATRIX: {
		long d = o->p[0];
		la_count_t len = length(a);
		for (la_count_t i = 0; i < len; i++)
			v[(i + (d < 0 ? (la_count_t)-d : 0)) * cols + i + (d > 0 ? (la_count_t)d : 0)] = a->v[i];
		break;
	}
	case OP_FROM_SPLAT:
		for (la_count_t k = 0; k < n; k++)
			v[k] = a->value;
		break;
	case OP_SOLVE: {
		int row = b->rows != rows;
		int ok = o->type == FLOAT ? solve_float(rows, cols, a->v, b->v, row, b->cols, v)
		                          : solve_double(rows, cols, a->v, b->v, row, b->cols, v);
		if (!ok) {
			memset(v, 0, n * sizeof(double));
			o->status = LA_SINGULAR_ERROR;
		}
		break;
	}
	}
done:
	o->a = o->b = NULL;
	if (a)
		la_release(a);
	if (b)
		la_release(b);
}

void la_object_dispose(struct la_s *o)
{
	free(o->v);
	if (o->deallocator)
		o->deallocator(o->buffer);
	if (o->a)
		la_release(o->a);
	if (o->b)
		la_release(o->b);
}

#pragma mark - Objects

la_object_t la_retain(la_object_t object)
{
	return os_retain(object);
}

void la_release(la_object_t object)
{
	os_release(object);
}

void la_add_attributes(la_object_t object, la_attribute_t attributes)
{
	object->attributes |= attributes;
}

void la_remove_attributes(la_object_t object, la_attribute_t attributes)
{
	object->attributes &= ~attributes;
}

la_status_t la_status(la_object_t object)
{
	return object->status;
}

static la_object_t from_buffer(const char *signature, const void *buffer, unsigned type, la_count_t rows,
    la_count_t cols, la_count_t stride, la_attribute_t attributes)
{
	if (!rows || !cols)
		return fail(signature, attributes, LA_INVALID_PARAMETER_ERROR,
		    "matrix dimensions must be greater than zero; failed comparison: %lu x %lu", rows, cols);
	if (!stride)
		return fail(signature, attributes, LA_INVALID_PARAMETER_ERROR,
		    "row stride must be greater than zero; failed comparison: 0 > 0");
	if (stride < cols)
		return fail(signature, attributes, LA_DIMENSION_MISMATCH_ERROR,
		    "row stride must be greater than or equal to number of columns; failed comparison: %lu >= %lu",
		    stride, cols);
	la_object_t o = make(LA_KIND_MATRIX, type, rows, cols, attributes);
	o->v = malloc(rows * cols * sizeof(double));
	for (la_count_t i = 0; i < rows; i++)
		for (la_count_t j = 0; j < cols; j++)
			o->v[i * cols + j] = type == FLOAT ? ((const float *)buffer)[i * stride + j]
			                                   : ((const double *)buffer)[i * stride + j];
	o->evaluated = 1;
	return o;
}

#define BUFFER_ARGS(T) T " * _Nonnull, la_count_t, la_count_t, la_count_t, la_hint_t, la_attribute_t"
#define NOCOPY_ARGS(T) T " * _Nonnull, la_count_t, la_count_t, la_count_t, la_hint_t, la_deallocator_t _Nullable, la_attribute_t"

la_object_t la_matrix_from_float_buffer(const float *buffer, la_count_t rows, la_count_t cols, la_count_t stride,
    la_hint_t hint, la_attribute_t attributes)
{
	return from_buffer(SIG("la_matrix_from_float_buffer", BUFFER_ARGS("const float")), buffer, FLOAT, rows, cols,
	    stride, attributes);
}

la_object_t la_matrix_from_double_buffer(const double *buffer, la_count_t rows, la_count_t cols,
    la_count_t stride, la_hint_t hint, la_attribute_t attributes)
{
	return from_buffer(SIG("la_matrix_from_double_buffer", BUFFER_ARGS("const double")), buffer, DOUBLE, rows,
	    cols, stride, attributes);
}

la_object_t la_matrix_from_float_buffer_nocopy(float *buffer, la_count_t rows, la_count_t cols,
    la_count_t stride, la_hint_t hint, la_deallocator_t deallocator, la_attribute_t attributes)
{
	la_object_t o = from_buffer(SIG("la_matrix_from_float_buffer_nocopy", NOCOPY_ARGS("float")), buffer, FLOAT,
	    rows, cols, stride, attributes);
	if (o->kind == LA_KIND_MATRIX) {
		o->buffer = buffer;
		o->deallocator = deallocator;
	}
	return o;
}

la_object_t la_matrix_from_double_buffer_nocopy(double *buffer, la_count_t rows, la_count_t cols,
    la_count_t stride, la_hint_t hint, la_deallocator_t deallocator, la_attribute_t attributes)
{
	la_object_t o = from_buffer(SIG("la_matrix_from_double_buffer_nocopy", NOCOPY_ARGS("double")), buffer, DOUBLE,
	    rows, cols, stride, attributes);
	if (o->kind == LA_KIND_MATRIX) {
		o->buffer = buffer;
		o->deallocator = deallocator;
	}
	return o;
}

/* Writes element k of the object to buffer[k*stride] (BLAS order for a negative stride). */
static la_status_t store(void *buffer, unsigned type, la_object_t o, int vector, la_count_t row_stride,
    la_index_t stride)
{
	if (o->type != type)
		return LA_PRECISION_MISMATCH_ERROR;
	if (o->kind != LA_KIND_MATRIX || (vector && !is_vector(o)) || (vector && !stride))
		return LA_INVALID_PARAMETER_ERROR;
	la_status_t status = o->status;
	if (status < 0)
		return status;
	evaluate(o);
	la_count_t rows = o->rows, cols = o->cols;
	for (la_count_t i = 0; i < rows; i++)
		for (la_count_t j = 0; j < cols; j++) {
			long at;
			if (vector) {
				long k = (long)(i * cols + j), n = (long)(rows * cols);
				at = stride < 0 ? (k - (n - 1)) * stride : k * stride;
			} else {
				at = (long)(i * row_stride + j);
			}
			if (type == FLOAT)
				((float *)buffer)[at] = (float)o->v[i * cols + j];
			else
				((double *)buffer)[at] = o->v[i * cols + j];
		}
	return status;
}

la_status_t la_matrix_to_float_buffer(float *buffer, la_count_t stride, la_object_t matrix)
{
	return store(buffer, FLOAT, matrix, 0, stride, 0);
}

la_status_t la_matrix_to_double_buffer(double *buffer, la_count_t stride, la_object_t matrix)
{
	return store(buffer, DOUBLE, matrix, 0, stride, 0);
}

la_status_t la_vector_to_float_buffer(float *buffer, la_index_t stride, la_object_t vector)
{
	return store(buffer, FLOAT, vector, 1, 0, stride);
}

la_status_t la_vector_to_double_buffer(double *buffer, la_index_t stride, la_object_t vector)
{
	return store(buffer, DOUBLE, vector, 1, 0, stride);
}

la_count_t la_matrix_rows(la_object_t matrix)
{
	return matrix->kind == LA_KIND_MATRIX && matrix->status >= 0 ? matrix->rows : 0;
}

la_count_t la_matrix_cols(la_object_t matrix)
{
	return matrix->kind == LA_KIND_MATRIX && matrix->status >= 0 ? matrix->cols : 0;
}

la_count_t la_vector_length(la_object_t vector)
{
	return vector->kind == LA_KIND_MATRIX && vector->status >= 0 ? length(vector) : 0;
}

la_object_t la_identity_matrix(la_count_t size, la_scalar_type_t type, la_attribute_t attributes)
{
	if (type != FLOAT && type != DOUBLE)
		return fail(SIG("la_identity_matrix", "la_count_t, la_scalar_type_t, la_attribute_t"), attributes,
		    LA_INVALID_PARAMETER_ERROR, "scalar_type must be LA_SCALAR_TYPE_DOUBLE or LA_SCALAR_TYPE_DOUBLE");
	la_object_t o = make(LA_KIND_MATRIX, type, size, size, attributes);
	o->v = calloc(size ? size * size : 1, sizeof(double));
	for (la_count_t i = 0; i < size; i++)
		o->v[i * size + i] = 1;
	o->evaluated = 1;
	return o;
}

#pragma mark - Splats

la_object_t la_splat_from_float(float value, la_attribute_t attributes)
{
	la_object_t o = make(LA_KIND_SPLAT, FLOAT, 0, 0, attributes);
	o->value = value;
	o->evaluated = 1;
	return o;
}

la_object_t la_splat_from_double(double value, la_attribute_t attributes)
{
	la_object_t o = make(LA_KIND_SPLAT, DOUBLE, 0, 0, attributes);
	o->value = value;
	o->evaluated = 1;
	return o;
}

la_object_t la_splat_from_vector_element(la_object_t vector, la_index_t index)
{
	static const char signature[] = SIG("la_splat_from_vector_element", OBJ ", la_index_t");
	if (!is_vector(vector))
		return fail(signature, vector->attributes, LA_INVALID_PARAMETER_ERROR,
		    "requires object to be 1xn or nx1.  actual dimensions were %lu x %lu", la_matrix_rows(vector),
		    la_matrix_cols(vector));
	if (index >= (la_index_t)length(vector))
		return fail(signature, vector->attributes, LA_DIMENSION_MISMATCH_ERROR,
		    "vector_index must be less than the number of elements in the object (zero indexed); failed "
		    "comparison: %ld < %lu",
		    index, length(vector));
	la_object_t o = make(LA_KIND_SPLAT, vector->type, 0, 0, vector->attributes);
	o->p[0] = index;
	return lazy(o, OP_ELEMENT, vector, NULL);
}

static la_object_t inherited(const char *signature, la_object_t from, la_attribute_t attributes, const char *which)
{
	return fail(signature, attributes, from->status, "inherited state from %s operand", which);
}

la_object_t la_splat_from_matrix_element(la_object_t matrix, la_index_t row, la_index_t col)
{
	static const char signature[] = SIG("la_splat_from_matrix_element", OBJ ", la_index_t, la_index_t");
	if (matrix->status < 0)
		return inherited(signature, matrix, matrix->attributes, "object");
	if (matrix->kind != LA_KIND_MATRIX)
		return fail(signature, matrix->attributes, LA_INVALID_PARAMETER_ERROR,
		    "operator splat from matrix element does not support splat");
	if (row >= (la_index_t)matrix->rows || col >= (la_index_t)matrix->cols)
		return fail(signature, matrix->attributes, LA_DIMENSION_MISMATCH_ERROR,
		    "matrix_row and matrix_col must be within the matrix; failed comparison: %ld < %lu, %ld < %lu", row,
		    matrix->rows, col, matrix->cols);
	la_object_t o = make(LA_KIND_SPLAT, matrix->type, 0, 0, matrix->attributes);
	o->p[0] = row < 0 || col < 0 ? -1 : (long)(row * (la_index_t)matrix->cols + col);
	return lazy(o, OP_ELEMENT, matrix, NULL);
}

static la_object_t from_splat(const char *signature, const char *name, la_object_t splat, la_count_t rows,
    la_count_t cols)
{
	if (splat->kind != LA_KIND_SPLAT)
		return fail(signature, splat->attributes, LA_INVALID_PARAMETER_ERROR,
		    "operator %s from splat requires splat", name);
	return lazy(make(LA_KIND_MATRIX, splat->type, rows, cols, splat->attributes), OP_FROM_SPLAT, splat, NULL);
}

la_object_t la_vector_from_splat(la_object_t splat, la_count_t length)
{
	return from_splat(SIG("la_vector_from_splat", OBJ ", la_count_t"), "vector", splat, length, 1);
}

la_object_t la_matrix_from_splat(la_object_t splat, la_count_t rows, la_count_t cols)
{
	return from_splat(SIG("la_matrix_from_splat", OBJ ", la_count_t, la_count_t"), "matrix", splat, rows, cols);
}

#pragma mark - Arithmetic

#define BINARY_ARGS OBJ ", " OBJ

/* The checks every binary operation makes first: the left operand's status, then precision. */
static la_object_t check_pair(const char *signature, la_object_t a, la_object_t b, la_attribute_t attributes,
    const char *names)
{
	if (a->status < 0)
		return inherited(signature, a, attributes, "left");
	if (a->type != b->type)
		return fail(signature, attributes, LA_PRECISION_MISMATCH_ERROR,
		    "%s must both have the same scalar type (float / double)", names);
	return NULL;
}

static la_object_t elementwise(const char *signature, const char *name, int op, la_object_t a, la_object_t b)
{
	la_attribute_t attributes = a->attributes | b->attributes;
	la_object_t e = check_pair(signature, a, b, attributes, "obj_left and obj_right");
	if (e)
		return e;
	if (a->kind == LA_KIND_SPLAT && b->kind == LA_KIND_SPLAT)
		return fail(signature, attributes, LA_INVALID_PARAMETER_ERROR,
		    "operator %s does not support op(splat,splat)", name);
	la_count_t rows, cols;
	if (a->kind == LA_KIND_SPLAT || b->kind == LA_KIND_SPLAT) {
		la_object_t m = a->kind == LA_KIND_SPLAT ? b : a;
		rows = m->rows;
		cols = m->cols;
	} else if (a->rows == b->rows && a->cols == b->cols) {
		rows = a->rows;
		cols = a->cols;
	} else if (is_vector(a) && is_vector(b) && length(a) == length(b)) {
		rows = length(a);
		cols = 1;
	} else if (a->rows != b->rows) {
		return fail(signature, attributes, LA_DIMENSION_MISMATCH_ERROR,
		    "obj_left rows must be equal to obj_right rows; failed comparison: %lu == %lu", a->rows, b->rows);
	} else {
		return fail(signature, attributes, LA_DIMENSION_MISMATCH_ERROR,
		    "obj_left cols must be equal to obj_right cols; failed comparison: %lu == %lu", a->cols, b->cols);
	}
	return lazy(make(LA_KIND_MATRIX, a->type, rows, cols, attributes), op, a, b);
}

la_object_t la_sum(la_object_t a, la_object_t b)
{
	return elementwise(SIG("la_sum", BINARY_ARGS), "element wise sum", OP_SUM, a, b);
}

la_object_t la_difference(la_object_t a, la_object_t b)
{
	return elementwise(SIG("la_difference", BINARY_ARGS), "element wise difference", OP_DIFFERENCE, a, b);
}

la_object_t la_elementwise_product(la_object_t a, la_object_t b)
{
	return elementwise(SIG("la_elementwise_product", BINARY_ARGS), "element wise product", OP_ELEMENTWISE, a, b);
}

la_object_t la_transpose(la_object_t matrix)
{
	static const char signature[] = SIG("la_transpose", OBJ);
	if (matrix->status < 0)
		return inherited(signature, matrix, matrix->attributes, "object");
	if (matrix->kind != LA_KIND_MATRIX)
		return fail(signature, matrix->attributes, LA_INVALID_PARAMETER_ERROR,
		    "operator transpose does not support splat");
	return lazy(make(LA_KIND_MATRIX, matrix->type, matrix->cols, matrix->rows, matrix->attributes), OP_TRANSPOSE,
	    matrix, NULL);
}

static la_object_t scale(const char *signature, la_object_t matrix, unsigned type, double scalar)
{
	if (matrix->status < 0)
		return inherited(signature, matrix, matrix->attributes, "object");
	if (matrix->kind != LA_KIND_MATRIX)
		return fail(signature, matrix->attributes, LA_INVALID_PARAMETER_ERROR,
		    "operator scale does not support splat");
	if (matrix->type != type)
		return fail(signature, matrix->attributes, LA_PRECISION_MISMATCH_ERROR, "matrix must be %s type",
		    type == FLOAT ? "float" : "double");
	la_object_t o = make(LA_KIND_MATRIX, type, matrix->rows, matrix->cols, matrix->attributes);
	o->scalar = scalar;
	return lazy(o, OP_SCALE, matrix, NULL);
}

la_object_t la_scale_with_float(la_object_t matrix, float scalar)
{
	return scale(SIG("la_scale_with_float", OBJ ", float"), matrix, FLOAT, scalar);
}

la_object_t la_scale_with_double(la_object_t matrix, double scalar)
{
	return scale(SIG("la_scale_with_double", OBJ ", double"), matrix, DOUBLE, scalar);
}

la_object_t la_inner_product(la_object_t a, la_object_t b)
{
	static const char signature[] = SIG("la_inner_product", BINARY_ARGS);
	la_attribute_t attributes = a->attributes | b->attributes;
	la_object_t e = check_pair(signature, a, b, attributes, "vector_left and vector_right");
	if (e)
		return e;
	int sa = a->kind == LA_KIND_SPLAT, sb = b->kind == LA_KIND_SPLAT;
	if (sa && sb)
		return fail(signature, attributes, LA_INVALID_PARAMETER_ERROR,
		    "operator inner product does not support op(splat,splat)");
	if (!sa && !sb && !is_vector(a) && !is_vector(b))
		return fail(signature, attributes, LA_INVALID_PARAMETER_ERROR,
		    "requires each object to be 1xn or nx1.  actual dimensions were %lu x %lu and %lu x %lu", a->rows,
		    a->cols, b->rows, b->cols);
	la_count_t n = sa ? length(b) : length(a);
	if ((!sa && !sb && !is_vector(b)) || (!sb && length(b) != n))
		return fail(signature, attributes, LA_DIMENSION_MISMATCH_ERROR,
		    "requires each object to be 1xn or nx1.  actual dimensions were %lu x %lu and %lu x %lu", a->rows,
		    a->cols, b->rows, b->cols);
	la_object_t o = make(LA_KIND_MATRIX, a->type, 1, 1, attributes);
	o->p[0] = (long)n;
	return lazy(o, OP_INNER, a, b);
}

la_object_t la_outer_product(la_object_t a, la_object_t b)
{
	static const char signature[] = SIG("la_outer_product", BINARY_ARGS);
	la_attribute_t attributes = a->attributes | b->attributes;
	la_object_t e = check_pair(signature, a, b, attributes, "vector_left and vector_right");
	if (e)
		return e;
	if (a->kind == LA_KIND_SPLAT || b->kind == LA_KIND_SPLAT)
		return fail(signature, attributes, LA_INVALID_PARAMETER_ERROR,
		    "operator outer product does not support splat");
	if (!is_vector(a) || !is_vector(b))
		return fail(signature, attributes, LA_INVALID_PARAMETER_ERROR,
		    "requires each object to be 1xn or nx1.  actual dimensions were %lu x %lu and %lu x %lu", a->rows,
		    a->cols, b->rows, b->cols);
	return lazy(make(LA_KIND_MATRIX, a->type, length(a), length(b), attributes), OP_OUTER, a, b);
}

la_object_t la_matrix_product(la_object_t a, la_object_t b)
{
	static const char signature[] = SIG("la_matrix_product", BINARY_ARGS);
	la_attribute_t attributes = a->attributes | b->attributes;
	la_object_t e = check_pair(signature, a, b, attributes, "matrix_left and matrix_right");
	if (e)
		return e;
	int sa = a->kind == LA_KIND_SPLAT, sb = b->kind == LA_KIND_SPLAT;
	if (sa && sb)
		return fail(signature, attributes, LA_INVALID_PARAMETER_ERROR,
		    "operator matrix product does not support op(splat,splat)");
	la_count_t rows, cols, depth;
	long mode = PRODUCT_PLAIN;
	if (sa) {
		rows = 1, cols = b->cols, depth = b->rows;
	} else if (sb) {
		rows = a->rows, cols = 1, depth = a->cols;
	} else if (a->cols == b->rows) {
		rows = a->rows, cols = b->cols, depth = a->cols;
	} else if (a->cols == 1 && a->rows == b->rows) {
		rows = 1, cols = b->cols, depth = a->rows, mode = PRODUCT_LEFT_TRANSPOSED;
	} else if (b->rows == 1 && a->cols == b->cols) {
		rows = a->rows, cols = 1, depth = a->cols, mode = PRODUCT_RIGHT_TRANSPOSED;
	} else {
		return fail(signature, attributes, LA_DIMENSION_MISMATCH_ERROR,
		    "One of the following must be true: 1) left.cols == right.cols; 2) Kx1 * KxN, left is transposed "
		    "giving 1xK * KxN; 3) MxK * 1xK, right is transposed giving MxK * Kx1. Provided operands look like "
		    "(%lu x %lu) * (%lu x %lu). Failed comparison %lu == %lu",
		    a->rows, a->cols, b->rows, b->cols, a->cols, b->rows);
	}
	la_object_t o = make(LA_KIND_MATRIX, a->type, rows, cols, attributes);
	o->p[0] = mode;
	o->p[1] = (long)depth;
	return lazy(o, OP_PRODUCT, a, b);
}

#pragma mark - Norms

static int valid_norm(la_norm_t norm)
{
	return norm == LA_L1_NORM || norm == LA_L2_NORM || norm == LA_LINF_NORM;
}

static double norm(la_object_t o, unsigned type, la_norm_t n)
{
	if (o->type != type || o->kind != LA_KIND_MATRIX || o->status < 0 || !valid_norm(n))
		return NAN;
	evaluate(o);
	return norm_of(o, n);
}

float la_norm_as_float(la_object_t vector, la_norm_t n)
{
	return (float)norm(vector, FLOAT, n);
}

double la_norm_as_double(la_object_t vector, la_norm_t n)
{
	return norm(vector, DOUBLE, n);
}

la_object_t la_normalized_vector(la_object_t vector, la_norm_t n)
{
	static const char signature[] = SIG("la_normalized_vector", OBJ ", la_norm_t");
	if (!valid_norm(n))
		return fail(signature, vector->attributes, LA_INVALID_PARAMETER_ERROR,
		    "norm type must be LA_L1_NORM, LA_L2_NORM, or LA_LINF_NORM\n");
	if (vector->status < 0)
		return inherited(signature, vector, vector->attributes, "object");
	if (vector->kind != LA_KIND_MATRIX)
		return fail(signature, vector->attributes, LA_INVALID_PARAMETER_ERROR,
		    "operator normalized vector does not support splat");
	la_object_t o = make(LA_KIND_MATRIX, vector->type, vector->rows, vector->cols, vector->attributes);
	o->p[0] = (long)n;
	return lazy(o, OP_NORMALIZE, vector, NULL);
}

#pragma mark - Slices and diagonals

static int within(la_index_t first, la_index_t stride, la_count_t count, la_count_t size)
{
	la_index_t last = first + (la_index_t)(count - 1) * stride;
	return count && first >= 0 && first < (la_index_t)size && last >= 0 && last < (la_index_t)size;
}

static la_object_t slice(la_object_t matrix, la_index_t r0, la_index_t c0, la_index_t rs, la_index_t cs,
    la_count_t rows, la_count_t cols)
{
	la_object_t o = make(LA_KIND_MATRIX, matrix->type, rows, cols, matrix->attributes);
	o->p[0] = r0;
	o->p[1] = c0;
	o->p[2] = rs;
	o->p[3] = cs;
	return lazy(o, OP_SLICE, matrix, NULL);
}

la_object_t la_matrix_slice(la_object_t matrix, la_index_t first_row, la_index_t first_col, la_index_t row_stride,
    la_index_t col_stride, la_count_t rows, la_count_t cols)
{
	static const char signature[] = SIG("la_matrix_slice",
	    OBJ ", la_index_t, la_index_t, la_index_t, la_index_t, la_count_t, la_count_t");
	if (matrix->status < 0)
		return inherited(signature, matrix, matrix->attributes, "object");
	if (matrix->kind != LA_KIND_MATRIX)
		return fail(signature, matrix->attributes, LA_INVALID_PARAMETER_ERROR,
		    "operator matrix slice does not support splat");
	if (!within(first_row, row_stride, rows, matrix->rows) || !within(first_col, col_stride, cols, matrix->cols))
		return fail(signature, matrix->attributes, LA_SLICE_OUT_OF_BOUNDS_ERROR,
		    "requested slice [%ld .. %ld] x [%ld .. %ld]. must be within [0 .. %ld] x [0 .. %ld]", first_row,
		    first_row + (la_index_t)(rows - 1) * row_stride, first_col,
		    first_col + (la_index_t)(cols - 1) * col_stride, (la_index_t)matrix->rows - 1,
		    (la_index_t)matrix->cols - 1);
	return slice(matrix, first_row, first_col, row_stride, col_stride, rows, cols);
}

la_object_t la_vector_slice(la_object_t vector, la_index_t first, la_index_t stride, la_count_t length_)
{
	static const char signature[] = SIG("la_vector_slice", OBJ ", la_index_t, la_index_t, la_count_t");
	if (vector->status < 0)
		return inherited(signature, vector, vector->attributes, "object");
	if (!is_vector(vector))
		return fail(signature, vector->attributes, LA_INVALID_PARAMETER_ERROR,
		    "requires object to be 1xn or nx1.  actual dimensions were %lu x %lu", la_matrix_rows(vector),
		    la_matrix_cols(vector));
	la_count_t n = length(vector);
	if (!within(first, stride, length_, n))
		return fail(signature, vector->attributes, LA_SLICE_OUT_OF_BOUNDS_ERROR,
		    "requested slice [%ld .. %ld]. must be within [0 .. %ld]", first,
		    first + (la_index_t)(length_ - 1) * stride, (la_index_t)n - 1);
	if (vector->rows == 1)
		return slice(vector, 0, first, 0, stride, 1, length_);
	return slice(vector, first, 0, stride, 0, length_, 1);
}

static la_object_t matrix_operand(const char *signature, const char *name, la_object_t matrix)
{
	if (matrix->status < 0)
		return inherited(signature, matrix, matrix->attributes, "object");
	if (matrix->kind != LA_KIND_MATRIX)
		return fail(signature, matrix->attributes, LA_INVALID_PARAMETER_ERROR, "operator %s does not support splat",
		    name);
	return NULL;
}

la_object_t la_vector_from_matrix_row(la_object_t matrix, la_count_t row)
{
	static const char signature[] = SIG("la_vector_from_matrix_row", OBJ ", la_count_t");
	la_object_t e = matrix_operand(signature, "vector from matrix row", matrix);
	if (e)
		return e;
	if (row >= matrix->rows)
		return fail(signature, matrix->attributes, LA_INVALID_PARAMETER_ERROR,
		    "matrix_row must be less than number of matrix rows; failed comparison: %lu < %lu", row, matrix->rows);
	return slice(matrix, (la_index_t)row, 0, 0, 1, 1, matrix->cols);
}

la_object_t la_vector_from_matrix_col(la_object_t matrix, la_count_t col)
{
	static const char signature[] = SIG("la_vector_from_matrix_col", OBJ ", la_count_t");
	la_object_t e = matrix_operand(signature, "vector from matrix col", matrix);
	if (e)
		return e;
	if (col >= matrix->cols)
		return fail(signature, matrix->attributes, LA_INVALID_PARAMETER_ERROR,
		    "matrix_col must be less than number of matrix columns; failed comparison: %lu < %lu", col,
		    matrix->cols);
	return slice(matrix, 0, (la_index_t)col, 1, 0, matrix->rows, 1);
}

la_object_t la_vector_from_matrix_diagonal(la_object_t matrix, la_index_t diagonal)
{
	static const char signature[] = SIG("la_vector_from_matrix_diagonal", OBJ ", la_index_t");
	la_object_t e = matrix_operand(signature, "vector from matrix diagonal", matrix);
	if (e)
		return e;
	la_index_t rows = (la_index_t)matrix->rows, cols = (la_index_t)matrix->cols;
	if (diagonal < 0 && -diagonal > rows - 1)
		return fail(signature, matrix->attributes, LA_INVALID_PARAMETER_ERROR,
		    "matrix_diagonal must be less than number of matrix rows; failed comparison: %ld < %ld", -diagonal,
		    rows);
	if (diagonal > 0 && diagonal > cols - 1)
		return fail(signature, matrix->attributes, LA_INVALID_PARAMETER_ERROR,
		    "matrix_diagonal must be less than number of matrix columns; failed comparison: %ld < %ld", diagonal,
		    cols);
	la_index_t n = diagonal >= 0 ? (rows < cols - diagonal ? rows : cols - diagonal)
	                             : (rows + diagonal < cols ? rows + diagonal : cols);
	la_object_t o = make(LA_KIND_MATRIX, matrix->type, (la_count_t)n, 1, matrix->attributes);
	o->p[0] = diagonal;
	return lazy(o, OP_DIAGONAL, matrix, NULL);
}

la_object_t la_diagonal_matrix_from_vector(la_object_t vector, la_index_t diagonal)
{
	static const char signature[] = SIG("la_diagonal_matrix_from_vector", OBJ ", la_index_t");
	la_object_t e = matrix_operand(signature, "diagonal matrix from vector", vector);
	if (e)
		return e;
	if (!is_vector(vector))
		return fail(signature, vector->attributes, LA_INVALID_PARAMETER_ERROR,
		    "requires object to be 1xn or nx1.  actual dimensions were %lu x %lu", vector->rows, vector->cols);
	la_count_t size = length(vector) + (la_count_t)(diagonal < 0 ? -diagonal : diagonal);
	la_object_t o = make(LA_KIND_MATRIX, vector->type, size, size, vector->attributes);
	o->p[0] = diagonal;
	return lazy(o, OP_DIAGONAL_MATRIX, vector, NULL);
}

#pragma mark - Linear systems

la_object_t la_solve(la_object_t matrix, la_object_t rhs)
{
	static const char signature[] = SIG("la_solve", BINARY_ARGS);
	la_attribute_t attributes = matrix->attributes | rhs->attributes;
	la_object_t e = check_pair(signature, matrix, rhs, attributes, "matrix_system and obj_rhs");
	if (e)
		return e;
	if (matrix->kind != LA_KIND_MATRIX || rhs->kind != LA_KIND_MATRIX)
		return fail(signature, attributes, LA_INVALID_PARAMETER_ERROR, "operator solve does not support splat");
	la_count_t n = matrix->rows, cols;
	if (matrix->cols != n)
		return fail(signature, attributes, LA_DIMENSION_MISMATCH_ERROR,
		    "matrix_system must be square; failed comparison: %lu == %lu", n, matrix->cols);
	if (rhs->rows == n)
		cols = rhs->cols;
	else if (rhs->rows == 1 && rhs->cols == n)
		cols = 1;
	else
		return fail(signature, attributes, LA_DIMENSION_MISMATCH_ERROR,
		    "matrix_system rows must be equal to obj_rhs rows; failed comparison: %lu == %lu", n, rhs->rows);
	return lazy(make(LA_KIND_MATRIX, matrix->type, n, cols, attributes), OP_SOLVE, matrix, rhs);
}
