/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Sparse BLAS: every sparse_* function of Sparse/BLAS.h for float, double and their
 * complex types, run on Apple's Accelerate and Finch's and compared
 * (tools/host-tests.sh). The data is chosen so results are exact. Left out is what
 * macOS gets wrong or only approximates: column permutations and variable-block
 * products corrupt, negative strides in the triangular solves read the wrong elements,
 * a column-major solve with a leading dimension past the rows reads the wrong rows,
 * a zero inserted over a stored value sometimes lands and sometimes not, a trace
 * past the matrix is not zero,
 * an invalid order, transpose or leading dimension aborts in CBLAS, and the operator
 * 2-norm stops short of the largest singular value.
 */
#include <Accelerate/Accelerate.h>
#include <complex.h>
#include <stdio.h>

static void put_value(double re, double im, int complex_type)
{
	if (complex_type)
		printf(" %g%+gi", re, im);
	else
		printf(" %g", re);
}

#define DEFINE_TESTS(S, T, R, CPLX, MAKE)                                                                      \
	static T S##_v(double re, double im)                                                               \
	{                                                                                                  \
		return MAKE;                                                                               \
	}                                                                                                  \
	static void S##_print(const char *label, const T *v, long n)                                       \
	{                                                                                                  \
		printf("  %s:", label);                                                                    \
		for (long k = 0; k < n; k++)                                                               \
			put_value(creal(v[k]), cimag(v[k]), CPLX);                                         \
		printf("\n");                                                                              \
	}                                                                                                  \
	static void S##_dump(const char *label, sparse_matrix_##S A)                                       \
	{                                                                                                  \
		long M = (long)sparse_get_matrix_number_of_rows(A), N = (long)sparse_get_matrix_number_of_columns(A); \
		printf("  %s: %ld x %ld, %ld nonzeros, rows", label, M, N, sparse_get_matrix_nonzero_count(A)); \
		for (long i = 0; i < M; i++)                                                               \
			printf(" %ld", sparse_get_matrix_nonzero_count_for_row(A, i));                     \
		printf(", cols");                                                                          \
		for (long j = 0; j < N; j++)                                                               \
			printf(" %ld", sparse_get_matrix_nonzero_count_for_column(A, j));                  \
		printf("\n");                                                                              \
		for (long i = 0; i < M; i++) {                                                             \
			T x[16] = {0}, y[16] = {0};                                                        \
			printf("   ");                                                                     \
			for (long j = 0; j < N; j++) {                                                     \
				for (long k = 0; k < N; k++)                                               \
					x[k] = k == j;                                                     \
				for (long k = 0; k < M; k++)                                               \
					y[k] = 0;                                                          \
				sparse_matrix_vector_product_dense_##S(CblasNoTrans, 1, A, x, 1, y, 1);    \
				put_value(creal(y[i]), cimag(y[i]), CPLX);                                 \
			}                                                                                  \
			printf("\n");                                                                      \
		}                                                                                          \
	}                                                                                                  \
	static sparse_matrix_##S S##_make(long M, long N, const double *d)                                 \
	{                                                                                                  \
		sparse_matrix_##S A = sparse_matrix_create_##S(M, N);                                      \
		for (long k = 0; k < M * N; k++)                                                           \
			if (d[k] != 0)                                                                     \
				sparse_insert_entry_##S(A, S##_v(d[k], CPLX ? (double)(k % 3) : 0), k / N, k % N); \
		return A;                                                                                  \
	}                                                                                                  \
	static void S##_tests(void)                                                                        \
	{                                                                                                  \
		printf("== " #S "\n");                                                                     \
		/* Level 1 */                                                                              \
		T x[4] = {S##_v(1, 1), S##_v(2, 0), S##_v(3, -1), S##_v(4, 2)};                          \
		T y[8];                                                                                    \
		for (int k = 0; k < 8; k++)                                                                \
			y[k] = S##_v(10 * (k + 1), k);                                                     \
		sparse_index ix[] = {0, 2, 3, 5}, iy[] = {1, 2, 5, 6};                                     \
		T r[1];                                                                                    \
		r[0] = sparse_inner_product_dense_##S(3, x, ix, y, 1);                                     \
		S##_print("inner dense", r, 1);                                                            \
		r[0] = sparse_inner_product_dense_##S(2, x, ix, y, 2);                                     \
		S##_print("inner dense, stride 2", r, 1);                                                  \
		r[0] = sparse_inner_product_dense_##S(3, x, ix, y + 7, -1);                                \
		S##_print("inner dense, stride -1", r, 1);                                                 \
		r[0] = sparse_inner_product_dense_##S(0, x, ix, y, 1);                                     \
		S##_print("inner dense, empty", r, 1);                                                     \
		r[0] = sparse_inner_product_sparse_##S(4, 4, x, ix, y, iy);                                \
		S##_print("inner sparse", r, 1);                                                           \
		T z[8] = {0};                                                                              \
		sparse_vector_add_with_scale_dense_##S(3, S##_v(2, 1), x, ix, z, 1);                      \
		S##_print("add with scale", z, 6);                                                         \
		sparse_vector_add_with_scale_dense_##S(3, 0, x, ix, z, 1);                                 \
		S##_print("add with scale 0", z, 6);                                                       \
		T z2[8] = {0};                                                                             \
		sparse_vector_add_with_scale_dense_##S(3, 2, x, ix, z2 + 7, -1);                           \
		S##_print("add with scale, stride -1", z2, 8);                                             \
		T xn[] = {S##_v(3, 0), S##_v(-4, 0), S##_v(1, CPLX ? 2 : 0)};                             \
		printf("  vector norms: %g %g %g %g %g\n", (double)sparse_vector_norm_##S(3, xn, ix, SPARSE_NORM_ONE), \
		    (double)sparse_vector_norm_##S(3, xn, ix, SPARSE_NORM_TWO),                            \
		    (double)sparse_vector_norm_##S(3, xn, ix, SPARSE_NORM_INF),                            \
		    (double)sparse_vector_norm_##S(3, xn, ix, SPARSE_NORM_R1),                             \
		    (double)sparse_vector_norm_##S(3, xn, ix, (sparse_norm)5));                            \
		T d[] = {0, S##_v(3, 0), 0, 0, S##_v(-4, 1), S##_v(5, 0), 0};                             \
		printf("  nonzero counts: %ld %ld %ld\n", sparse_get_vector_nonzero_count_##S(7, d, 1),   \
		    sparse_get_vector_nonzero_count_##S(3, d, 2), sparse_get_vector_nonzero_count_##S(7, d + 6, -1)); \
		T pv[4] = {S##_v(-1, 0), S##_v(-1, 0), S##_v(-1, 0), S##_v(-1, 0)};                       \
		sparse_index pi[4] = {-1, -1, -1, -1};                                                     \
		long c = sparse_pack_vector_##S(7, 2, d, 1, pv, pi);                                       \
		printf("  pack 2: %ld at %lld %lld", c, pi[0], pi[1]);                                     \
		S##_print("values", pv, 3);                                                                \
		c = sparse_pack_vector_##S(7, 4, d + 6, -1, pv, pi);                                       \
		printf("  pack reversed: %ld at %lld %lld %lld", c, pi[0], pi[1], pi[2]);                  \
		S##_print("values", pv, 3);                                                                \
		T u[6];                                                                                    \
		for (int k = 0; k < 6; k++)                                                                \
			u[k] = 9;                                                                          \
		sparse_unpack_vector_##S(6, 3, true, x, ix, u, 1);                                         \
		S##_print("unpack, zeroing", u, 6);                                                        \
		for (int k = 0; k < 6; k++)                                                                \
			u[k] = 9;                                                                          \
		sparse_unpack_vector_##S(3, 4, false, x, ix, u, 1);                                        \
		S##_print("unpack N 3", u, 6);                                                             \
		for (int k = 0; k < 6; k++)                                                                \
			u[k] = 9;                                                                          \
		sparse_unpack_vector_##S(6, 3, true, x, ix, u + 5, -1);                                    \
		S##_print("unpack reversed", u, 6);                                                        \
                                                                                                           \
		/* Building matrices */                                                                    \
		sparse_matrix_##S A = sparse_matrix_create_##S(3, 4);                                      \
		printf("  inserts: %d %d %d %d", sparse_insert_entry_##S(A, 1, 0, 0),                      \
		    sparse_insert_entry_##S(A, 2, 0, 0), sparse_insert_entry_##S(A, 0, 1, 1),              \
		    sparse_insert_entry_##S(A, S##_v(5, 1), 2, 3));                                        \
		printf(", property after: %d\n", sparse_set_matrix_property(A, SPARSE_UPPER_TRIANGULAR));  \
		S##_dump("first insert wins, zero dropped", A);                                            \
		sparse_insert_entry_##S(A, 6, 0, 0);                                                       \
		printf("  commit %d\n", sparse_commit(A));                                                 \
		sparse_insert_entry_##S(A, 7, 0, 0);                                                       \
		S##_dump("later insert overwrites", A);                                                    \
		T cv[] = {7, 8};                                                                           \
		sparse_index ci[] = {2, 0}, cj[] = {3, 0};                                                 \
		printf("  insert col %d row %d\n", sparse_insert_col_##S(A, 1, 2, cv, ci),                 \
		    sparse_insert_row_##S(A, 1, 2, cv, cj));                                               \
		T ev[] = {S##_v(1, 1), 2, 3};                                                              \
		sparse_index ei[] = {2, 1, 0}, ej[] = {0, 2, 2};                                           \
		printf("  insert entries %d\n", sparse_insert_entries_##S(A, 3, ev, ei, ej));              \
		S##_dump("A", A);                                                                          \
		{                                                                                          \
			T vv[8];                                                                           \
			sparse_index jj[8], end = -5;                                                      \
			for (long i = 0; i < 3; i++) {                                                     \
				long k = sparse_extract_sparse_row_##S(A, i, 0, &end, 8, vv, jj);          \
				printf("  row %ld: %ld, end %lld, at", i, k, end);                         \
				for (long q = 0; q < k; q++)                                               \
					printf(" %lld", jj[q]);                                            \
				S##_print("values", vv, k);                                                \
			}                                                                                  \
			long k = sparse_extract_sparse_row_##S(A, 0, 1, &end, 1, vv, jj);                  \
			printf("  row 0 from 1, 1 value: %ld, end %lld, at %lld\n", k, end, jj[0]);        \
			k = sparse_extract_sparse_row_##S(A, 1, 0, &end, 1, vv, jj);                       \
			printf("  row 1, 1 value: %ld, end %lld, at %lld\n", k, end, jj[0]);               \
			k = sparse_extract_sparse_column_##S(A, 2, 0, &end, 8, vv, jj);                    \
			printf("  column 2: %ld, end %lld, at %lld %lld\n", k, end, jj[0], jj[1]);         \
			k = sparse_extract_sparse_column_##S(A, 0, 0, &end, 1, vv, jj);                    \
			printf("  column 0, 1 value: %ld, end %lld, at %lld\n", k, end, jj[0]);            \
			k = sparse_extract_sparse_column_##S(A, 1, 1, &end, 8, vv, jj);                    \
			printf("  column 1 from row 1: %ld, end %lld, at %lld\n", k, end, jj[0]);          \
		}                                                                                          \
		sparse_index p[] = {2, 0, 1};                                                              \
		printf("  permute rows %d\n", sparse_permute_rows_##S(A, p));                              \
		S##_dump("permuted", A);                                                                   \
		printf("  trace %g %g %g %g\n", creal(sparse_matrix_trace_##S(A, 0)),                     \
		    creal(sparse_matrix_trace_##S(A, 1)), creal(sparse_matrix_trace_##S(A, -1)),           \
		    cimag(sparse_matrix_trace_##S(A, 3)));                                                 \
		printf("  elementwise norms %g %g %g %g %g\n", (double)sparse_elementwise_norm_##S(A, SPARSE_NORM_ONE), \
		    (double)sparse_elementwise_norm_##S(A, SPARSE_NORM_TWO),                               \
		    (double)sparse_elementwise_norm_##S(A, SPARSE_NORM_INF),                               \
		    (double)sparse_elementwise_norm_##S(A, SPARSE_NORM_R1),                                \
		    (double)sparse_elementwise_norm_##S(A, (sparse_norm)1));                               \
		printf("  operator norms %g %g %g %g\n", (double)sparse_operator_norm_##S(A, SPARSE_NORM_ONE), \
		    (double)sparse_operator_norm_##S(A, SPARSE_NORM_INF),                                  \
		    (double)sparse_operator_norm_##S(A, SPARSE_NORM_R1),                                   \
		    (double)sparse_operator_norm_##S(A, (sparse_norm)1));                                  \
		printf("  block dimensions of a point matrix %ld %ld\n", sparse_get_block_dimension_for_row(A, 0), \
		    sparse_get_block_dimension_for_col(A, 0));                                             \
		{                                                                                          \
			T bv[4];                                                                           \
			printf("  block calls on a point matrix %d %d\n", sparse_insert_block_##S(A, bv, 2, 1, 0, 0), \
			    sparse_extract_block_##S(A, 0, 0, 2, 1, bv));                                  \
		}                                                                                          \
                                                                                                           \
		/* Level 2 */                                                                              \
		{                                                                                          \
			T vx[4] = {1, S##_v(2, 1), 3, 4}, vy[4] = {1, 1, 1, 1};                            \
			printf("  product %d", sparse_matrix_vector_product_dense_##S(CblasNoTrans, 2, A, vx, 1, vy, 1)); \
			S##_print("y", vy, 3);                                                             \
			T wy[8] = {1, 1, 1, 1, 1, 1, 1, 1};                                                \
			printf("  transposed %d", sparse_matrix_vector_product_dense_##S(CblasTrans, 1, A, vx, 1, wy, 2)); \
			S##_print("y", wy, 8);                                                             \
			T qy[4] = {0};                                                                     \
			printf("  conjugate transposed %d",                                                \
			    sparse_matrix_vector_product_dense_##S(CblasConjTrans, 1, A, vx, 1, qy, 1));   \
			S##_print("y", qy, 4);                                                             \
		}                                                                                          \
		{                                                                                          \
			double up[] = {2, 1, 3, 9, 4, 6, 7, 5, 8};                                         \
			sparse_matrix_##S U = sparse_matrix_create_##S(3, 3);                              \
			printf("  properties: set %d", sparse_set_matrix_property(U, SPARSE_UPPER_TRIANGULAR)); \
			printf(" get %ld %ld %ld\n", sparse_get_matrix_property(U, SPARSE_UPPER_TRIANGULAR), \
			    sparse_get_matrix_property(U, SPARSE_LOWER_TRIANGULAR),                        \
			    sparse_get_matrix_property(U, (sparse_matrix_property)3));                     \
			for (int k = 0; k < 9; k++)                                                        \
				sparse_insert_entry_##S(U, up[k], k / 3, k % 3);                           \
			T b[3] = {16, 8, 32};                                                              \
			printf("  upper solve %d", sparse_vector_triangular_solve_dense_##S(CblasNoTrans, 2, U, b, 1)); \
			S##_print("x", b, 3);                                                              \
			T bt[6] = {4, 0, 12, 0, 48, 0};                                                    \
			printf("  transposed upper solve %d",                                              \
			    sparse_vector_triangular_solve_dense_##S(CblasTrans, 1, U, bt, 2));            \
			S##_print("x", bt, 6);                                                             \
			T bc[3] = {1, 2, 3};                                                               \
			printf("  conjugate transposed solve %d",                                          \
			    sparse_vector_triangular_solve_dense_##S(CblasConjTrans, 1, U, bc, 1));        \
			S##_print("x", bc, 3);                                                             \
			sparse_matrix_##S G = S##_make(3, 3, up);                                          \
			printf("  solve without a triangle %d\n",                                          \
			    sparse_vector_triangular_solve_dense_##S(CblasNoTrans, 1, G, bc, 1));          \
			sparse_matrix_##S L = sparse_matrix_create_##S(3, 3);                              \
			sparse_set_matrix_property(L, SPARSE_LOWER_TRIANGULAR);                            \
			double lo[] = {4, 0, 0, 2, 8, 0, 1, 3, 2};                                         \
			for (int k = 0; k < 9; k++)                                                        \
				if (lo[k] != 0)                                                            \
					sparse_insert_entry_##S(L, lo[k], k / 3, k % 3);                   \
			T B[6] = {8, 4, 20, 40, 21, 14};                                                   \
			printf("  matrix solve, row major %d",                                             \
			    sparse_matrix_triangular_solve_dense_##S(CblasRowMajor, CblasNoTrans, 2, 1, L, B, 2)); \
			S##_print("X", B, 6);                                                              \
			T Bc[6] = {8, 20, 21, 4, 40, 14};                                                  \
			printf("  matrix solve, column major %d",                                          \
			    sparse_matrix_triangular_solve_dense_##S(CblasColMajor, CblasNoTrans, 2, 1, L, Bc, 3)); \
			S##_print("X", Bc, 6);                                                             \
			T Bt[3] = {8, 16, 4};                                                              \
			printf("  matrix solve, transposed %d",                                            \
			    sparse_matrix_triangular_solve_dense_##S(CblasRowMajor, CblasTrans, 1, 1, L, Bt, 1)); \
			S##_print("X", Bt, 3);                                                             \
			sparse_matrix_destroy(U);                                                          \
			sparse_matrix_destroy(G);                                                          \
			sparse_matrix_destroy(L);                                                          \
		}                                                                                          \
		{                                                                                          \
			sparse_matrix_##S C = NULL;                                                        \
			T ox[] = {1, S##_v(2, 1)}, oy[] = {1, 2};                                          \
			sparse_index oj[] = {0, 3};                                                        \
			printf("  outer product %d\n", sparse_outer_product_dense_##S(2, 4, 2, 3, ox, 1, oy, oj, &C)); \
			S##_dump("C", C);                                                                  \
			sparse_matrix_##S C2 = NULL;                                                       \
			printf("  outer product nz > N %d, left alone %d\n",                               \
			    sparse_outer_product_dense_##S(2, 1, 2, 3, ox, 1, oy, oj, &C2), C2 == NULL);   \
			sparse_matrix_destroy(C);                                                          \
		}                                                                                          \
                                                                                                           \
		/* Level 3 */                                                                              \
		{                                                                                          \
			double ad[] = {1, 0, 2, 0, 3, 4};                                                  \
			sparse_matrix_##S M = S##_make(2, 3, ad);                                          \
			T Bd[] = {1, 2, 3, 4, 5, 6}, Cd[4] = {100, 100, 100, 100};                         \
			printf("  product dense, row major %d",                                            \
			    sparse_matrix_product_dense_##S(CblasRowMajor, CblasNoTrans, 2, 2, M, Bd, 2, Cd, 2)); \
			S##_print("C", Cd, 4);                                                             \
			T Ct[9] = {0};                                                                     \
			printf("  product dense, column major, transposed %d",                             \
			    sparse_matrix_product_dense_##S(CblasColMajor, CblasTrans, 3, 1, M, Bd, 2, Ct, 3)); \
			S##_print("C", Ct, 9);                                                             \
			T Ch[9] = {0};                                                                     \
			printf("  product dense, conjugate transposed %d",                                 \
			    sparse_matrix_product_dense_##S(CblasRowMajor, CblasConjTrans, 3, 1, M, Bd, 3, Ch, 3)); \
			S##_print("C", Ch, 9);                                                             \
			double bd[] = {1, 0, 0, 2, 3, 0};                                                  \
			sparse_matrix_##S N = S##_make(3, 2, bd);                                          \
			T Cs[4] = {0};                                                                     \
			printf("  product sparse %d",                                                      \
			    sparse_matrix_product_sparse_##S(CblasRowMajor, CblasNoTrans, 1, M, N, Cs, 2)); \
			S##_print("C", Cs, 4);                                                             \
			T Cq[9] = {0};                                                                     \
			printf("  product sparse, A^T A %d",                                               \
			    sparse_matrix_product_sparse_##S(CblasColMajor, CblasTrans, 2, M, M, Cq, 3));  \
			S##_print("C", Cq, 9);                                                             \
			sparse_matrix_destroy(M);                                                          \
			sparse_matrix_destroy(N);                                                          \
		}                                                                                          \
                                                                                                           \
		/* Block matrices */                                                                       \
		{                                                                                          \
			sparse_matrix_##S B = sparse_matrix_block_create_##S(2, 3, 2, 2);                  \
			printf("  block matrix %lld x %lld, block dimensions %ld %ld %ld\n",               \
			    sparse_get_matrix_number_of_rows(B), sparse_get_matrix_number_of_columns(B),   \
			    sparse_get_block_dimension_for_row(B, 1), sparse_get_block_dimension_for_col(B, 5), \
			    sparse_get_block_dimension_for_col(B, 6));                                     \
			T blk[] = {1, S##_v(2, 2), 3, 0};                                                  \
			printf("  insert block %d, point insert %d\n", sparse_insert_block_##S(B, blk, 2, 1, 1, 2), \
			    sparse_insert_entry_##S(B, 5, 0, 0));                                          \
			S##_dump("B", B);                                                                  \
			T ex[4] = {-1, -1, -1, -1};                                                        \
			printf("  extract block %d", sparse_extract_block_##S(B, 1, 2, 1, 2, ex));         \
			S##_print("values", ex, 4);                                                        \
			printf("  extract empty block %d", sparse_extract_block_##S(B, 0, 0, 2, 1, ex));   \
			S##_print("values", ex, 4);                                                        \
			{                                                                                  \
				T vv[4];                                                                   \
				sparse_index jj[4], end;                                                   \
				printf("  row extract on a block matrix %d\n",                             \
				    sparse_extract_sparse_row_##S(B, 2, 0, &end, 4, vv, jj));              \
			}                                                                                  \
			sparse_dimension K[] = {1, 2}, Lb[] = {2, 1, 1};                                   \
			sparse_matrix_##S W = sparse_matrix_variable_block_create_##S(2, 3, K, Lb);        \
			printf("  variable block %lld x %lld, dimensions %ld %ld %ld %ld %ld\n",           \
			    sparse_get_matrix_number_of_rows(W), sparse_get_matrix_number_of_columns(W),   \
			    sparse_get_block_dimension_for_row(W, 0), sparse_get_block_dimension_for_row(W, 2), \
			    sparse_get_block_dimension_for_col(W, 1), sparse_get_block_dimension_for_col(W, 2), \
			    sparse_get_block_dimension_for_col(W, 5));                                     \
			T b2[] = {1, 2, 3, 4}, b3[] = {7};                                                 \
			printf("  insert %d %d", sparse_insert_block_##S(W, b2, 2, 1, 1, 0),               \
			    sparse_insert_block_##S(W, b3, 1, 1, 0, 2));                                   \
			printf(", nonzeros %ld, rows %ld %ld %ld\n", sparse_get_matrix_nonzero_count(W),   \
			    sparse_get_matrix_nonzero_count_for_row(W, 0), sparse_get_matrix_nonzero_count_for_row(W, 1), \
			    sparse_get_matrix_nonzero_count_for_row(W, 2));                                \
			T e4[4] = {-1, -1, -1, -1};                                                        \
			sparse_extract_block_##S(W, 1, 0, 1, 2, e4);                                       \
			S##_print("block 1,0", e4, 4);                                                     \
			sparse_extract_block_##S(W, 0, 2, 1, 1, e4);                                       \
			S##_print("block 0,2", e4, 1);                                                     \
			printf("  destroy %d %d\n", sparse_matrix_destroy(B), sparse_matrix_destroy(W));   \
		}                                                                                          \
		printf("  destroy %d\n", sparse_matrix_destroy(A));                                        \
	}

DEFINE_TESTS(float, float, float, 0, ((void)im, (float)re))
DEFINE_TESTS(double, double, double, 0, ((void)im, re))
DEFINE_TESTS(float_complex, float _Complex, float, 1, CMPLXF((float)re, (float)im))
DEFINE_TESTS(double_complex, double _Complex, double, 1, CMPLX(re, im))

int main(void)
{
	float_tests();
	double_tests();
	float_complex_tests();
	double_complex_tests();
	return 0;
}
