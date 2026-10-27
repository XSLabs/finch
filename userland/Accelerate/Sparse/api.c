/*
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * The typed _Sparse* entry points the Sparse/Solve.h inline layer calls for
 * factorizations: numeric factor objects (which live in the factor storage
 * the caller hands over, hold a reference on their symbolic factor and are
 * reference counted), solves, subfactors, refactoring and inertia.
 */
#include <stdlib.h>
#include <string.h>

#include "factor.h"
#include "typed.h"

#define WORKSPACE 16

/* LDL^T and LU defaults resolve to their threshold partial pivoting forms. */
static SparseFactorization_t resolved(SparseFactorization_t type)
{
	if (type == SparseFactorizationLDLT)
		return SparseFactorizationLDLTTPP;
	if (type == SparseFactorizationLU)
		return SparseFactorizationLUTPP;
	return type;
}

/*
 * Factors the matrix into storage (struct numeric). The numeric factor takes
 * over one reference on the symbolic factor.
 */
static struct numeric *build(int type, SparseOpaqueSymbolicFactorization *symbolic, const struct matrix_view *A,
    const SparseNumericFactorOptions *options, void *storage, SparseStatus_t *status)
{
	struct numeric *f = storage;
	memset(f, 0, sizeof *f);
	f->refs = 1;
	f->type = type;
	f->ftype = resolved(symbolic->type);
	f->options = *options;
	f->symbolic = *symbolic;
	*status = numeric_factor(f, A);
	return f;
}

static struct numeric *numeric_of(void *p)
{
	return p;
}

#define DEFINE_FACTORS(S, ID, T)                                                                              \
	typedef __typeof__(((SparseOpaqueFactorization_##S *)0)->attributes) attributes_##S;                   \
                                                                                                               \
	static SparseOpaqueFactorization_##S numeric_##S(SparseOpaqueSymbolicFactorization *symbolic,           \
	    const SparseMatrix_##S *Matrix, const SparseNumericFactorOptions *options, void *storage, int retain) \
	{                                                                                                      \
		SparseOpaqueFactorization_##S out = {0};                                                       \
		out.symbolicFactorization = *symbolic;                                                         \
		out.attributes = Matrix->structure.attributes;                                                 \
		out.attributes.transpose = false;                                                              \
		if (symbolic->status != SparseStatusOK || !symbolic->factorization) {                          \
			out.status = symbolic->status == SparseInternalError ? SparseMatrixIsSingular          \
			                                                     : symbolic->status;               \
			return out;                                                                            \
		}                                                                                              \
		if (retain)                                                                                    \
			_SparseRetainSymbolic(symbolic);                                                       \
		struct matrix_view v = view_##S(Matrix);                                                       \
		SparseStatus_t status;                                                                         \
		struct numeric *f = build(ID, symbolic, &v, options, storage, &status);                        \
		out.status = status;                                                                           \
		out.numericFactorization = f;                                                                  \
		out.solveWorkspaceRequiredStatic = WORKSPACE;                                                  \
		out.solveWorkspaceRequiredPerRHS = WORKSPACE;                                                  \
		return out;                                                                                    \
	}                                                                                                      \
                                                                                                               \
	static SparseOpaqueFactorization_##S all_in_one_##S(SparseFactorization_t type,                         \
	    const SparseMatrix_##S *Matrix, const SparseSymbolicFactorOptions *sfoptions,                      \
	    const SparseNumericFactorOptions *nfoptions, int family)                                           \
	{                                                                                                      \
		SparseMatrixStructure structure = {                                                            \
		    .rowCount = Matrix->structure.rowCount,                                                    \
		    .columnCount = Matrix->structure.columnCount,                                              \
		    .columnStarts = Matrix->structure.columnStarts,                                            \
		    .rowIndices = Matrix->structure.rowIndices,                                                \
		    .blockSize = Matrix->structure.blockSize,                                                  \
		};                                                                                             \
		structure.attributes.transpose = Matrix->structure.attributes.transpose;                       \
		structure.attributes.triangle = Matrix->structure.attributes.triangle;                         \
		structure.attributes.kind = Matrix->structure.attributes.kind == SparseHermitian               \
		                                ? SparseSymmetric                                              \
		                                : Matrix->structure.attributes.kind;                           \
		SparseOpaqueSymbolicFactorization symbolic = symbolic_factor(type, &structure, sfoptions, family); \
		if (symbolic.status != SparseStatusOK) {                                                       \
			SparseOpaqueFactorization_##S out = {0};                                               \
			out.status = family == FAMILY_LU && Matrix->structure.rowCount != Matrix->structure.columnCount \
			                 ? SparseParameterError                                                \
			                 : SparseMatrixIsSingular;                                             \
			out.symbolicFactorization = symbolic;                                                  \
			return out;                                                                            \
		}                                                                                              \
		struct symbolic *s = symbolic.factorization;                                                   \
		void *storage = s->options.malloc(symbolic.factorSize_Double);                                 \
		return numeric_##S(&symbolic, Matrix, nfoptions, storage, 0);                                  \
	}                                                                                                      \
                                                                                                               \
	SparseOpaqueFactorization_##S _SparseNumericFactorSymmetric_##S(SparseOpaqueSymbolicFactorization *symbolicFactor, \
	    const SparseMatrix_##S *Matrix, const SparseNumericFactorOptions *options, void *factorStorage,     \
	    void *workspace)                                                                                   \
	{                                                                                                      \
		(void)workspace;                                                                               \
		return numeric_##S(symbolicFactor, Matrix, options, factorStorage, 1);                         \
	}                                                                                                      \
	SparseOpaqueFactorization_##S _SparseNumericFactorQR_##S(SparseOpaqueSymbolicFactorization *symbolicFactor, \
	    const SparseMatrix_##S *Matrix, const SparseNumericFactorOptions *options, void *factorStorage,     \
	    void *workspace)                                                                                   \
	{                                                                                                      \
		(void)workspace;                                                                               \
		return numeric_##S(symbolicFactor, Matrix, options, factorStorage, 1);                         \
	}                                                                                                      \
	SparseOpaqueFactorization_##S _SparseNumericFactorLU_##S(SparseOpaqueSymbolicFactorization *symbolicFactor, \
	    const SparseMatrix_##S *Matrix, const SparseNumericFactorOptions *options, void *factorStorage,     \
	    void *workspace)                                                                                   \
	{                                                                                                      \
		(void)workspace;                                                                               \
		return numeric_##S(symbolicFactor, Matrix, options, factorStorage, 1);                         \
	}                                                                                                      \
	SparseOpaqueFactorization_##S _SparseFactorSymmetric_##S(SparseFactorization_t factorType,             \
	    const SparseMatrix_##S *Matrix, const SparseSymbolicFactorOptions *sfoptions,                      \
	    const SparseNumericFactorOptions *nfoptions)                                                       \
	{                                                                                                      \
		return all_in_one_##S(factorType, Matrix, sfoptions, nfoptions, FAMILY_SYMMETRIC);             \
	}                                                                                                      \
	SparseOpaqueFactorization_##S _SparseFactorQR_##S(SparseFactorization_t factorType,                    \
	    const SparseMatrix_##S *Matrix, const SparseSymbolicFactorOptions *sfoptions,                      \
	    const SparseNumericFactorOptions *nfoptions)                                                       \
	{                                                                                                      \
		return all_in_one_##S(factorType, Matrix, sfoptions, nfoptions, FAMILY_QR);                    \
	}                                                                                                      \
	SparseOpaqueFactorization_##S _SparseFactorLU_##S(SparseFactorization_t factorType,                    \
	    const SparseMatrix_##S *Matrix, const SparseSymbolicFactorOptions *sfoptions,                      \
	    const SparseNumericFactorOptions *nfoptions)                                                       \
	{                                                                                                      \
		return all_in_one_##S(factorType, Matrix, sfoptions, nfoptions, FAMILY_LU);                    \
	}                                                                                                      \
                                                                                                               \
	static void refactor_##S(const SparseMatrix_##S *Matrix, SparseOpaqueFactorization_##S *F,              \
	    const SparseNumericFactorOptions *nfoptions)                                                       \
	{                                                                                                      \
		struct numeric *f = numeric_of(F->numericFactorization);                                       \
		if (!f) {                                                                                      \
			F->status = SparseParameterError;                                                      \
			return;                                                                                \
		}                                                                                              \
		f->options = *nfoptions;                                                                       \
		struct matrix_view v = view_##S(Matrix);                                                       \
		F->status = numeric_factor(f, &v);                                                             \
	}                                                                                                      \
	void _SparseRefactorSymmetric_##S(const SparseMatrix_##S *Matrix, SparseOpaqueFactorization_##S *Factorization, \
	    const SparseNumericFactorOptions *nfoptions, void *workspace)                                      \
	{                                                                                                      \
		(void)workspace;                                                                               \
		refactor_##S(Matrix, Factorization, nfoptions);                                                \
	}                                                                                                      \
	void _SparseRefactorQR_##S(const SparseMatrix_##S *Matrix, SparseOpaqueFactorization_##S *Factorization, \
	    const SparseNumericFactorOptions *nfoptions, void *workspace)                                      \
	{                                                                                                      \
		(void)workspace;                                                                               \
		refactor_##S(Matrix, Factorization, nfoptions);                                                \
	}                                                                                                      \
	void _SparseRefactorLU_##S(const SparseMatrix_##S *Matrix, SparseOpaqueFactorization_##S *Factorization, \
	    const SparseNumericFactorOptions *nfoptions, void *workspace)                                      \
	{                                                                                                      \
		(void)workspace;                                                                               \
		refactor_##S(Matrix, Factorization, nfoptions);                                                \
	}                                                                                                      \
	void _SparseUpdatePartialRefactorLU_##S(SparseOpaqueFactorization_##S *Opaque, int updateCount,        \
	    const int *updatedIndices, SparseMatrix_##S newMatrix)                                             \
	{                                                                                                      \
		(void)updateCount;                                                                             \
		(void)updatedIndices;                                                                          \
		struct numeric *f = numeric_of(Opaque->numericFactorization);                                  \
		if (!f) {                                                                                      \
			Opaque->status = SparseParameterError;                                                 \
			return;                                                                                \
		}                                                                                              \
		refactor_##S(&newMatrix, Opaque, &f->options);                                                 \
	}                                                                                                      \
                                                                                                               \
	void _SparseSolveOpaque_##S(const SparseOpaqueFactorization_##S *Factored, const DenseMatrix_##S *RHS,  \
	    const DenseMatrix_##S *Soln, void *workspace)                                                      \
	{                                                                                                      \
		(void)workspace;                                                                               \
		struct numeric *f = numeric_of(Factored->numericFactorization);                                \
		struct dense_view X = dense_##S(Soln), B;                                                      \
		if (RHS)                                                                                       \
			B = dense_##S(RHS);                                                                    \
		numeric_solve(f, Factored->attributes.transpose,                                               \
		    conjugate_bit_##S((const void *)&Factored->attributes), RHS ? &B : NULL, &X);              \
	}                                                                                                      \
	void _SparseMultiplySubfactor_##S(const SparseOpaqueSubfactor_##S *Subfactor, const DenseMatrix_##S *x, \
	    const DenseMatrix_##S *y, char *workspace)                                                         \
	{                                                                                                      \
		(void)workspace;                                                                               \
		struct numeric *f = numeric_of(Subfactor->factor.numericFactorization);                        \
		struct dense_view Y = dense_##S(y), X = x ? dense_##S(x) : Y;                                  \
		subfactor_apply(f, Subfactor->contents, Subfactor->attributes.transpose,                       \
		    conjugate_bit_##S((const void *)&Subfactor->attributes), 0, &X, &Y);                       \
	}                                                                                                      \
	void _SparseSolveSubfactor_##S(const SparseOpaqueSubfactor_##S *Subfactor, const DenseMatrix_##S *b,    \
	    const DenseMatrix_##S *x, char *workspace)                                                         \
	{                                                                                                      \
		(void)workspace;                                                                               \
		struct numeric *f = numeric_of(Subfactor->factor.numericFactorization);                        \
		struct dense_view X = dense_##S(x), B = b ? dense_##S(b) : X;                                  \
		subfactor_apply(f, Subfactor->contents, Subfactor->attributes.transpose,                       \
		    conjugate_bit_##S((const void *)&Subfactor->attributes), 1, &B, &X);                       \
	}                                                                                                      \
                                                                                                               \
	void _SparseDestroyOpaqueNumeric_##S(SparseOpaqueFactorization_##S *toFree)                            \
	{                                                                                                      \
		struct numeric *f = numeric_of(toFree->numericFactorization);                                  \
		if (f && --f->refs <= 0) {                                                                     \
			struct symbolic *s = f->symbolic.factorization;                                        \
			void (*release)(void *) = s ? s->options.free : free;                                  \
			numeric_release(f);                                                                    \
			_SparseDestroyOpaqueSymbolic(&f->symbolic);                                            \
			if (!toFree->userFactorStorage)                                                        \
				release(f);                                                                    \
		} else if (!f) {                                                                               \
			_SparseDestroyOpaqueSymbolic(&toFree->symbolicFactorization);                          \
		}                                                                                              \
		toFree->numericFactorization = NULL;                                                           \
		toFree->status = SparseStatusReleased;                                                         \
	}                                                                                                      \
	void _SparseRetainNumeric_##S(SparseOpaqueFactorization_##S *numericFactor)                            \
	{                                                                                                      \
		struct numeric *f = numeric_of(numericFactor->numericFactorization);                           \
		if (f)                                                                                         \
			f->refs++;                                                                             \
	}                                                                                                      \
	SparseNumericFactorOptions _SparseGetOptionsFromNumericFactor_##S(SparseOpaqueFactorization_##S *factor) \
	{                                                                                                      \
		struct numeric *f = numeric_of(factor->numericFactorization);                                  \
		return f ? f->options : (SparseNumericFactorOptions){0};                                       \
	}                                                                                                      \
	void _SparseGetWorkspaceRequired_##S(SparseSubfactor_t Subfactor, SparseOpaqueFactorization_##S Factor, \
	    size_t *workStatic, size_t *workPerRHS)                                                            \
	{                                                                                                      \
		(void)Subfactor;                                                                               \
		(void)Factor;                                                                                  \
		*workStatic = WORKSPACE;                                                                       \
		*workPerRHS = WORKSPACE;                                                                       \
	}                                                                                                      \
                                                                                                               \
	__attribute__((overloadable)) int SparseGetInertia(SparseOpaqueFactorization_##S Factored,             \
	    int *num_positive, int *num_zero, int *num_negative)                                               \
	{                                                                                                      \
		struct numeric *f = numeric_of(Factored.numericFactorization);                                 \
		if (!f || Factored.status != SparseStatusOK || f->family != FAMILY_SYMMETRIC ||                \
		    f->ftype != SparseFactorizationLDLTTPP) {                                                  \
			sparse_report(_SparseGetOptionsFromSymbolicFactor(&Factored.symbolicFactorization).reportError, \
			    "SparseGetInertia is only supported for SparseFactorizationLDLTTPP factorizations.\n"); \
			return -1;                                                                             \
		}                                                                                              \
		*num_positive = f->positive;                                                                   \
		*num_zero = f->zero;                                                                           \
		*num_negative = f->negative;                                                                   \
		return 0;                                                                                      \
	}

FOR_EACH_TYPE(DEFINE_FACTORS)

/* Hermitian factorizations of complex matrices are the symmetric family with conjugation. */
#define DEFINE_HERMITIAN(S)                                                                                   \
	SparseOpaqueFactorization_##S _SparseNumericFactorHermitian_##S(SparseOpaqueSymbolicFactorization *symbolicFactor, \
	    const SparseMatrix_##S *Matrix, const SparseNumericFactorOptions *options, void *factorStorage,     \
	    void *workspace)                                                                                   \
	{                                                                                                      \
		return _SparseNumericFactorSymmetric_##S(symbolicFactor, Matrix, options, factorStorage, workspace); \
	}                                                                                                      \
	SparseOpaqueFactorization_##S _SparseFactorHermitian_##S(SparseFactorization_t factorType,             \
	    const SparseMatrix_##S *Matrix, const SparseSymbolicFactorOptions *sfoptions,                      \
	    const SparseNumericFactorOptions *nfoptions)                                                       \
	{                                                                                                      \
		return _SparseFactorSymmetric_##S(factorType, Matrix, sfoptions, nfoptions);                   \
	}                                                                                                      \
	void _SparseRefactorHermitian_##S(const SparseMatrix_##S *Matrix, SparseOpaqueFactorization_##S *Factorization, \
	    const SparseNumericFactorOptions *nfoptions, void *workspace)                                      \
	{                                                                                                      \
		_SparseRefactorSymmetric_##S(Matrix, Factorization, nfoptions, workspace);                     \
	}

DEFINE_HERMITIAN(Complex_Float)
DEFINE_HERMITIAN(Complex_Double)
