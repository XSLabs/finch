/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Views of the typed public structures, and FOR_EACH_TYPE to stamp out the
 * typed entry points: X(SUFFIX, TYPE_ID, T) for _Float, _Double,
 * _Complex_Float and _Complex_Double.
 */
#ifndef FINCH_SPARSE_TYPED_H
#define FINCH_SPARSE_TYPED_H

#include "internal.h"

#define FOR_EACH_TYPE(X)                                     \
	X(Float, T_FLOAT, float)                             \
	X(Double, T_DOUBLE, double)                          \
	X(Complex_Float, T_FLOAT_COMPLEX, float _Complex)    \
	X(Complex_Double, T_DOUBLE_COMPLEX, double _Complex)

#define DEFINE_VIEWS(S, ID, T)                                                                        \
	static inline struct matrix_view view_##S(const SparseMatrix_##S *A)                           \
	{                                                                                              \
		struct matrix_view v = {                                                               \
		    .type = ID,                                                                        \
		    .rows = A->structure.rowCount,                                                     \
		    .cols = A->structure.columnCount,                                                  \
		    .starts = A->structure.columnStarts,                                               \
		    .indices = A->structure.rowIndices,                                                \
		    .transpose = A->structure.attributes.transpose,                                    \
		    .triangle = A->structure.attributes.triangle,                                      \
		    .kind = A->structure.attributes.kind,                                              \
		    .block = A->structure.blockSize,                                                   \
		    .data = A->data,                                                                   \
		};                                                                                     \
		v.conjugate = conjugate_bit_##S(&A->structure.attributes);                             \
		return v;                                                                              \
	}                                                                                              \
	static inline struct dense_view dense_##S(const DenseMatrix_##S *X)                            \
	{                                                                                              \
		struct dense_view v = {                                                                \
		    .type = ID,                                                                        \
		    .rows = X->rowCount,                                                               \
		    .cols = X->columnCount,                                                            \
		    .stride = X->columnStride,                                                         \
		    .transpose = X->attributes.transpose,                                              \
		    .data = X->data,                                                                   \
		};                                                                                     \
		v.conjugate = conjugate_bit_##S(&X->attributes) && X->attributes.transpose;            \
		return v;                                                                              \
	}

static inline unsigned conjugate_bit_Float(const SparseAttributes_t *a)
{
	(void)a;
	return 0;
}
static inline unsigned conjugate_bit_Double(const SparseAttributes_t *a)
{
	(void)a;
	return 0;
}
static inline unsigned conjugate_bit_Complex_Float(const SparseAttributesComplex_t *a)
{
	return a->conjugate_transpose;
}
static inline unsigned conjugate_bit_Complex_Double(const SparseAttributesComplex_t *a)
{
	return a->conjugate_transpose;
}

FOR_EACH_TYPE(DEFINE_VIEWS)

#endif
