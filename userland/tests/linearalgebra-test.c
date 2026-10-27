/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * LinearAlgebra: every la_* function on matrices, vectors in both orientations, splats
 * and error objects, run on Apple's Accelerate and Finch's and compared
 * (tools/host-tests.sh). Statuses, dimensions and elements print exactly, except
 * la_solve's results, which print to 6 digits with tiny values as zero (macOS's LAPACK
 * and BLAS round their own way).
 * Left out are what macOS gets wrong: a negative splat index reads outside the vector,
 * a stride-0 store aborts in cblas_dcopy and a splat-backed right-hand side is solved in
 * place on its single element.
 */
#include <Accelerate/Accelerate.h>
#include <math.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static int digits = 17;

static void show(const char *name, la_object_t o)
{
	la_count_t r = la_matrix_rows(o), c = la_matrix_cols(o);
	printf("%s: status %ld, %lu x %lu, length %lu", name, la_status(o), r, c, la_vector_length(o));
	if (r * c && r * c <= 36) {
		double b[36];
		la_status_t s = la_matrix_to_double_buffer(b, c, o);
		if (s == LA_PRECISION_MISMATCH_ERROR) {
			float f[36];
			s = la_matrix_to_float_buffer(f, c, o);
			for (la_count_t i = 0; i < r * c; i++)
				b[i] = f[i];
		}
		printf(" [%ld]", s);
		for (la_count_t i = 0; i < r * c; i++)
			printf(" %.*g", digits, digits < 17 && fabs(b[i]) < 1e-5 ? 0.0 : b[i]);
	}
	printf(", then status %ld\n", la_status(o));
	la_release(o);
}

#define SHOW(e) show(#e, e)
#define STATUS(e)                                                                                    \
	do {                                                                                         \
		la_object_t o_ = (e);                                                                \
		printf("%-64s %ld\n", #e, la_status(o_));                                           \
		la_release(o_);                                                                      \
	} while (0)

static int deallocated;
static void deallocate(void *p)
{
	deallocated++;
	free(p);
}

int main(void)
{
	double a[] = {4, 1, 2, 1, 3, 0, 2, 0, 5}, n[] = {4, 1, 2, 7, 3, 0, 9, 0, 5};
	double m23[] = {1, 2, 3, 4, 5, 6}, v3[] = {1, 2, 3}, v2[] = {1, 2}, z[] = {0, 0, 0};
	float f4[] = {1, 2, 3, 4};
	la_object_t A = la_matrix_from_double_buffer(a, 3, 3, 3, LA_NO_HINT, LA_DEFAULT_ATTRIBUTES);
	la_object_t N = la_matrix_from_double_buffer(n, 3, 3, 3, LA_NO_HINT, LA_DEFAULT_ATTRIBUTES);
	la_object_t M = la_matrix_from_double_buffer(m23, 2, 3, 3, LA_NO_HINT, LA_DEFAULT_ATTRIBUTES);
	la_object_t F = la_matrix_from_float_buffer(f4, 2, 2, 2, LA_NO_HINT, LA_DEFAULT_ATTRIBUTES);
	la_object_t V = la_vector_from_double_buffer(v3, 3, 1, LA_DEFAULT_ATTRIBUTES);
	la_object_t W = la_vector_from_double_buffer(v2, 2, 1, LA_DEFAULT_ATTRIBUTES);
	la_object_t R = la_transpose(V);
	la_object_t FV = la_vector_from_float_buffer(f4, 2, 1, LA_DEFAULT_ATTRIBUTES);
	la_object_t SD = la_splat_from_double(2.5, LA_DEFAULT_ATTRIBUTES);
	la_object_t SF = la_splat_from_float(1, LA_DEFAULT_ATTRIBUTES);
	la_object_t E = la_sum(V, W);
	la_object_t ES = la_splat_from_vector_element(V, 9);

	printf("== objects\n");
	Class cls = object_getClass((id)A);
	printf("class %s, superclass %s\n", class_getName(cls), class_getName(class_getSuperclass(cls)));
	printf("retain returns its argument: %d\n", la_retain(A) == A);
	la_release(A);
	la_add_attributes(A, LA_ATTRIBUTE_ENABLE_LOGGING);
	la_remove_attributes(A, LA_ATTRIBUTE_ENABLE_LOGGING);
	printf("rows/cols/length: A %lu %lu %lu, M %lu %lu %lu, R %lu %lu %lu, splat %lu %lu %lu, error %lu %lu %lu\n",
	    la_matrix_rows(A), la_matrix_cols(A), la_vector_length(A), la_matrix_rows(M), la_matrix_cols(M),
	    la_vector_length(M), la_matrix_rows(R), la_matrix_cols(R), la_vector_length(R), la_matrix_rows(SD),
	    la_matrix_cols(SD), la_vector_length(SD), la_matrix_rows(E), la_matrix_cols(E), la_vector_length(E));
	{
		float *buffer = malloc(4 * sizeof(float));
		for (int i = 0; i < 4; i++)
			buffer[i] = (float)i;
		la_object_t owner = la_matrix_from_float_buffer_nocopy(buffer, 2, 2, 2, LA_NO_HINT, deallocate,
		    LA_DEFAULT_ATTRIBUTES);
		la_object_t view = la_transpose(owner);
		la_release(owner);
		printf("deallocated while a view lives: %d\n", deallocated);
		la_release(view);
		printf("deallocated after: %d\n", deallocated);
	}

	printf("== creation\n");
	SHOW(la_matrix_from_double_buffer(a, 3, 3, 3, LA_NO_HINT, 0));
	SHOW(la_matrix_from_double_buffer(m23, 2, 2, 3, LA_SHAPE_DIAGONAL | LA_FEATURE_SYMMETRIC, 0));
	SHOW(la_matrix_from_float_buffer(f4, 2, 2, 2, 1 << 5, 0));
	SHOW(la_matrix_from_double_buffer_nocopy(m23, 2, 3, 3, LA_NO_HINT, NULL, 0));
	SHOW(la_vector_from_double_buffer(m23, 3, 2, 0));
	SHOW(la_vector_from_float_buffer(f4, 2, 2, 0));
	STATUS(la_matrix_from_double_buffer(a, 0, 3, 3, 0, 0));
	STATUS(la_matrix_from_double_buffer(a, 3, 0, 3, 0, 0));
	STATUS(la_matrix_from_double_buffer(a, 3, 3, 2, 0, 0));
	STATUS(la_matrix_from_double_buffer(a, 1, 3, 1, 0, 0));
	STATUS(la_matrix_from_double_buffer(a, 1, 3, 0, 0, 0));
	STATUS(la_matrix_from_double_buffer(a, 3, 1, 0, 0, 0));
	STATUS(la_matrix_from_double_buffer_nocopy(a, 3, 3, 2, 0, NULL, 0));
	SHOW(la_identity_matrix(3, LA_SCALAR_TYPE_DOUBLE, 0));
	SHOW(la_identity_matrix(2, LA_SCALAR_TYPE_FLOAT, 0));
	SHOW(la_identity_matrix(0, LA_SCALAR_TYPE_DOUBLE, 0));
	STATUS(la_identity_matrix(2, 7, 0));
	STATUS(la_identity_matrix(2, LA_SCALAR_TYPE_DOUBLE | LA_SCALAR_TYPE_FLOAT, 0));

	printf("== splats\n");
	SHOW(la_retain(SD));
	SHOW(la_matrix_from_splat(SD, 2, 3));
	SHOW(la_vector_from_splat(SD, 3));
	SHOW(la_vector_from_splat(SF, 2));
	SHOW(la_matrix_from_splat(SD, 0, 2));
	SHOW(la_vector_from_splat(SD, 0));
	SHOW(la_vector_from_splat(la_splat_from_vector_element(V, 2), 2));
	SHOW(la_vector_from_splat(la_splat_from_vector_element(R, 1), 2));
	SHOW(la_vector_from_splat(la_splat_from_matrix_element(N, 2, 0), 2));
	SHOW(la_vector_from_splat(la_splat_from_matrix_element(M, 1, 2), 1));
	STATUS(la_splat_from_vector_element(V, 3));
	STATUS(la_splat_from_vector_element(A, 0));
	STATUS(la_splat_from_vector_element(SD, 0));
	STATUS(la_splat_from_vector_element(E, 0));
	STATUS(la_splat_from_matrix_element(A, 3, 0));
	STATUS(la_splat_from_matrix_element(A, 0, 3));
	STATUS(la_splat_from_matrix_element(SD, 0, 0));
	STATUS(la_splat_from_matrix_element(E, 0, 0));
	STATUS(la_vector_from_splat(V, 2));
	STATUS(la_vector_from_splat(E, 2));
	STATUS(la_vector_from_splat(ES, 2));
	STATUS(la_matrix_from_splat(A, 2, 2));

	printf("== element-wise\n");
	SHOW(la_sum(A, N));
	SHOW(la_sum(A, SD));
	SHOW(la_sum(SD, A));
	SHOW(la_difference(A, N));
	SHOW(la_difference(SD, A));
	SHOW(la_difference(V, la_splat_from_double(1, 0)));
	SHOW(la_elementwise_product(A, N));
	SHOW(la_elementwise_product(F, SF));
	SHOW(la_sum(F, F));
	SHOW(la_sum(V, R));
	SHOW(la_sum(R, V));
	SHOW(la_sum(R, R));
	SHOW(la_elementwise_product(R, V));
	SHOW(la_scale_with_double(N, 0.1));
	SHOW(la_scale_with_float(F, 0.1f));
	SHOW(la_transpose(N));
	SHOW(la_transpose(M));
	SHOW(la_transpose(la_transpose(M)));
	STATUS(la_sum(A, F));
	STATUS(la_sum(F, la_splat_from_double(1, 0)));
	STATUS(la_sum(SD, SD));
	STATUS(la_sum(SD, SF));
	STATUS(la_sum(A, V));
	STATUS(la_sum(M, V));
	STATUS(la_sum(V, W));
	STATUS(la_difference(SD, SD));
	STATUS(la_elementwise_product(SD, SD));
	STATUS(la_scale_with_float(A, 2));
	STATUS(la_scale_with_double(F, 2));
	STATUS(la_scale_with_double(SD, 2));
	STATUS(la_scale_with_double(E, 2));
	STATUS(la_scale_with_float(ES, 2));
	STATUS(la_transpose(SD));
	STATUS(la_transpose(E));
	STATUS(la_transpose(ES));

	printf("== error propagation\n");
	STATUS(la_retain(E));
	STATUS(la_retain(ES));
	STATUS(la_sum(E, V));
	STATUS(la_sum(V, E));
	STATUS(la_sum(E, F));
	STATUS(la_sum(F, E));
	STATUS(la_sum(V, ES));
	STATUS(la_sum(ES, V));
	STATUS(la_sum(SD, E));
	STATUS(la_sum(E, SD));
	STATUS(la_sum(la_sum(A, F), E));
	STATUS(la_sum(la_transpose(SD), la_sum(A, F)));
	STATUS(la_matrix_product(E, F));
	STATUS(la_matrix_product(V, E));
	STATUS(la_inner_product(V, E));
	STATUS(la_outer_product(E, F));
	STATUS(la_solve(E, F));
	STATUS(la_solve(A, E));

	printf("== products\n");
	SHOW(la_matrix_product(A, N));
	SHOW(la_matrix_product(N, V));
	SHOW(la_matrix_product(R, N));
	SHOW(la_matrix_product(V, N));
	SHOW(la_matrix_product(M, V));
	SHOW(la_matrix_product(M, R));
	SHOW(la_matrix_product(W, M));
	SHOW(la_matrix_product(la_transpose(W), M));
	SHOW(la_matrix_product(M, la_transpose(M)));
	SHOW(la_matrix_product(V, R));
	SHOW(la_matrix_product(R, V));
	SHOW(la_matrix_product(M, SD));
	SHOW(la_matrix_product(SD, M));
	SHOW(la_matrix_product(F, F));
	SHOW(la_matrix_product(F, FV));
	STATUS(la_matrix_product(M, M));
	STATUS(la_matrix_product(V, M));
	STATUS(la_matrix_product(SD, SD));
	STATUS(la_matrix_product(SD, SF));
	STATUS(la_matrix_product(A, F));
	SHOW(la_inner_product(V, V));
	SHOW(la_inner_product(R, V));
	SHOW(la_inner_product(V, R));
	SHOW(la_inner_product(V, SD));
	SHOW(la_inner_product(SD, V));
	SHOW(la_inner_product(FV, FV));
	SHOW(la_inner_product(N, V));
	SHOW(la_inner_product(la_transpose(N), V));
	SHOW(la_inner_product(M, W));
	SHOW(la_inner_product(SD, N));
	SHOW(la_inner_product(N, SD));
	STATUS(la_inner_product(V, W));
	STATUS(la_inner_product(V, N));
	STATUS(la_inner_product(N, N));
	STATUS(la_inner_product(SD, SD));
	STATUS(la_inner_product(SD, SF));
	SHOW(la_outer_product(V, W));
	SHOW(la_outer_product(R, R));
	SHOW(la_outer_product(FV, FV));
	STATUS(la_outer_product(V, SD));
	STATUS(la_outer_product(SD, V));
	STATUS(la_outer_product(N, V));
	STATUS(la_outer_product(V, M));
	STATUS(la_outer_product(F, V));

	printf("== norms\n");
	printf("double: %.17g %.17g %.17g; %.17g %.17g %.17g\n", la_norm_as_double(N, LA_L1_NORM),
	    la_norm_as_double(N, LA_L2_NORM), la_norm_as_double(N, LA_LINF_NORM), la_norm_as_double(R, LA_L1_NORM),
	    la_norm_as_double(R, LA_L2_NORM), la_norm_as_double(R, LA_LINF_NORM));
	printf("float: %.9g %.9g %.9g\n", la_norm_as_float(F, LA_L1_NORM), la_norm_as_float(F, LA_L2_NORM),
	    la_norm_as_float(F, LA_LINF_NORM));
	printf("NaN cases: %g %g %g %g %g %g\n", la_norm_as_double(F, LA_L2_NORM), la_norm_as_float(A, LA_L2_NORM),
	    la_norm_as_double(A, 4), la_norm_as_double(A, 0), la_norm_as_double(SD, LA_L2_NORM),
	    la_norm_as_double(E, LA_L2_NORM));
	SHOW(la_normalized_vector(V, LA_L1_NORM));
	SHOW(la_normalized_vector(V, LA_L2_NORM));
	SHOW(la_normalized_vector(V, LA_LINF_NORM));
	SHOW(la_normalized_vector(M, LA_LINF_NORM));
	SHOW(la_normalized_vector(N, LA_L2_NORM));
	SHOW(la_normalized_vector(FV, LA_L2_NORM));
	SHOW(la_normalized_vector(la_vector_from_double_buffer(z, 3, 1, 0), LA_L2_NORM));
	STATUS(la_normalized_vector(V, 9));
	STATUS(la_normalized_vector(SD, LA_L2_NORM));
	STATUS(la_normalized_vector(E, LA_L2_NORM));
	STATUS(la_normalized_vector(E, 9));

	printf("== slices\n");
	SHOW(la_matrix_slice(N, 2, 2, -1, -1, 3, 3));
	SHOW(la_matrix_slice(N, 0, 1, 2, 1, 2, 2));
	SHOW(la_matrix_slice(N, 1, 1, 0, 0, 2, 2));
	SHOW(la_matrix_slice(N, 2, 0, -1, 1, 3, 1));
	SHOW(la_matrix_slice(V, 0, 0, 2, 0, 2, 1));
	STATUS(la_matrix_slice(N, 2, 2, 1, 1, 3, 3));
	STATUS(la_matrix_slice(N, 0, 0, 1, 1, 0, 0));
	STATUS(la_matrix_slice(N, -1, 0, 1, 1, 1, 1));
	STATUS(la_matrix_slice(N, 2, 0, -1, 1, 4, 1));
	STATUS(la_matrix_slice(SD, 0, 0, 1, 1, 1, 1));
	STATUS(la_matrix_slice(E, 0, 0, 1, 1, 1, 1));
	SHOW(la_vector_slice(V, 2, -1, 3));
	SHOW(la_vector_reverse(V));
	SHOW(la_vector_slice(V, 1, 0, 3));
	SHOW(la_vector_slice(R, 1, 1, 2));
	SHOW(la_vector_slice(la_vector_from_double_buffer(m23, 6, 1, 0), 1, 2, 3));
	STATUS(la_vector_slice(V, 0, 1, 4));
	STATUS(la_vector_slice(V, 0, 1, 0));
	STATUS(la_vector_slice(V, -1, 1, 2));
	STATUS(la_vector_slice(M, 0, 1, 2));
	STATUS(la_vector_slice(SD, 0, 1, 1));
	STATUS(la_vector_slice(E, 0, 1, 1));
	SHOW(la_vector_from_matrix_row(N, 1));
	SHOW(la_vector_from_matrix_row(M, 1));
	SHOW(la_vector_from_matrix_col(N, 0));
	SHOW(la_vector_from_matrix_col(M, 2));
	STATUS(la_vector_from_matrix_row(N, 3));
	STATUS(la_vector_from_matrix_col(M, 3));
	STATUS(la_vector_from_matrix_row(SD, 0));
	STATUS(la_vector_from_matrix_col(E, 0));
	SHOW(la_vector_from_matrix_diagonal(N, 0));
	SHOW(la_vector_from_matrix_diagonal(N, 1));
	SHOW(la_vector_from_matrix_diagonal(N, -2));
	SHOW(la_vector_from_matrix_diagonal(M, 0));
	SHOW(la_vector_from_matrix_diagonal(M, 2));
	SHOW(la_vector_from_matrix_diagonal(M, -1));
	STATUS(la_vector_from_matrix_diagonal(M, -2));
	STATUS(la_vector_from_matrix_diagonal(N, 3));
	STATUS(la_vector_from_matrix_diagonal(SD, 0));
	STATUS(la_vector_from_matrix_diagonal(E, 9));
	SHOW(la_diagonal_matrix_from_vector(V, 0));
	SHOW(la_diagonal_matrix_from_vector(V, -1));
	SHOW(la_diagonal_matrix_from_vector(R, 2));
	SHOW(la_diagonal_matrix_from_vector(FV, 1));
	STATUS(la_diagonal_matrix_from_vector(M, 0));
	STATUS(la_diagonal_matrix_from_vector(SD, 0));
	STATUS(la_diagonal_matrix_from_vector(E, 0));
	STATUS(la_diagonal_matrix_from_vector(ES, 0));

	printf("== stores\n");
	{
		double d[8];
		float f[8];
		for (int i = 0; i < 8; i++)
			d[i] = -7;
		la_status_t s = la_vector_to_double_buffer(d, 2, V);
		printf("stride 2: %ld %g %g %g %g %g\n", s, d[0], d[1], d[2], d[3], d[4]);
		s = la_vector_to_double_buffer(d, -1, V);
		printf("stride -1: %ld %g %g %g\n", s, d[0], d[1], d[2]);
		s = la_vector_to_double_buffer(d, 1, R);
		printf("row: %ld %g %g %g\n", s, d[0], d[1], d[2]);
		for (int i = 0; i < 8; i++)
			d[i] = -7;
		s = la_matrix_to_double_buffer(d, 4, M);
		printf("matrix stride 4: %ld %g %g %g %g %g %g %g %g\n", s, d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7]);
		s = la_matrix_to_double_buffer(d, 2, M);
		printf("matrix stride 2: %ld %g %g %g %g %g\n", s, d[0], d[1], d[2], d[3], d[4]);
		s = la_vector_to_float_buffer(f, 1, FV);
		printf("float: %ld %g %g\n", s, f[0], f[1]);
		for (int i = 0; i < 8; i++)
			d[i] = -7;
		printf("refused: %ld %ld %ld %ld %ld %ld %ld %ld; untouched %g\n", la_vector_to_double_buffer(d, 1, A),
		    la_vector_to_double_buffer(d, 1, E), la_vector_to_double_buffer(d, 1, SD),
		    la_vector_to_double_buffer(d, 1, ES), la_matrix_to_double_buffer(d, 3, F),
		    la_matrix_to_double_buffer(d, 3, SD), la_matrix_to_double_buffer(d, 3, E),
		    la_vector_to_float_buffer(f, 1, V), d[0]);
	}

	printf("== solve\n");
	digits = 6;
	double sing[] = {1, 2, 2, 4}, b2[] = {1, 3}, u[] = {2, 1, 0, 0, 3, 1, 0, 0, 4};
	double g[] = {0, 2, 1, 1, 1, 0, 3, 0, 1}, wide[] = {1, 1, 1, 2, 1, 3};
	float ff[] = {3, 1, 1, 2};
	SHOW(la_solve(A, V));
	SHOW(la_solve(A, R));
	SHOW(la_solve(N, V));
	SHOW(la_solve(la_matrix_from_double_buffer(g, 3, 3, 3, 0, 0), V));
	SHOW(la_solve(la_matrix_from_double_buffer(u, 3, 3, 3, LA_SHAPE_UPPER_TRIANGULAR, 0), V));
	SHOW(la_solve(la_matrix_from_double_buffer(a, 3, 3, 3, LA_SHAPE_DIAGONAL, 0), V));
	SHOW(la_solve(N, N));
	SHOW(la_solve(N, la_transpose(M)));
	SHOW(la_solve(la_matrix_from_float_buffer(ff, 2, 2, 2, 0, 0), FV));
	SHOW(la_solve(F, F));
	STATUS(la_solve(M, W));
	STATUS(la_solve(la_matrix_from_double_buffer(wide, 3, 2, 2, 0, 0), V));
	STATUS(la_solve(A, W));
	STATUS(la_solve(A, la_transpose(W)));
	STATUS(la_solve(A, SD));
	STATUS(la_solve(SD, V));
	STATUS(la_solve(A, F));
	{
		/* Singularity is found when the result is read: the status changes then. */
		la_object_t S = la_matrix_from_double_buffer(sing, 2, 2, 2, 0, 0);
		la_object_t B = la_vector_from_double_buffer(b2, 2, 1, 0);
		SHOW(la_solve(S, B));
		la_object_t x = la_solve(S, B);
		la_object_t later = la_sum(x, B);
		printf("before reading: %ld, length %lu\n", la_status(x), la_vector_length(x));
		show("sum read first", later);
		printf("after: %ld, length %lu\n", la_status(x), la_vector_length(x));
		STATUS(la_sum(x, B));
		STATUS(la_sum(B, x));
		la_release(x);
		x = la_solve(S, B);
		printf("norm of the unread solve: %g, then %ld\n", la_norm_as_double(x, LA_L2_NORM), la_status(x));
		la_release(x);
		x = la_solve(S, B);
		SHOW(la_solve(S, x));
		la_release(x);
		SHOW(la_solve(la_matrix_from_double_buffer(z, 1, 1, 1, 0, 0), la_vector_from_double_buffer(v2, 1, 1, 0)));
		la_release(S);
		la_release(B);
	}

	la_release(A);
	la_release(N);
	la_release(M);
	la_release(F);
	la_release(V);
	la_release(W);
	la_release(R);
	la_release(FV);
	la_release(SD);
	la_release(SF);
	la_release(E);
	la_release(ES);
	return 0;
}
