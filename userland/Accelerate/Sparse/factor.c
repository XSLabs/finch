/*
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Sparse direct factorizations, written for Finch: a right-looking
 * elimination over sparse columns shared by
 *   - LDL^T / LDL^H with Cholesky, unpivoted, supernode Bunch-Kaufman (static
 *     pivoting) and threshold partial pivoting (1x1 and 2x2 pivots, delayed
 *     when they fail the test) variants, in a minimum degree order;
 *   - Householder QR (and Cholesky of A'A, which keeps R only) in a column
 *     minimum degree order;
 *   - LU with threshold partial row pivoting.
 * The factors' forms follow Sparse/Solve.h: SAS = PLDL'P', A = QRP (A = P'R'Q'
 * when A is wide) and S_r A S_c = P Abar Q.
 */
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "factor.h"

#pragma mark - Sparse vectors

static void sv_reserve(struct svec *v, int need)
{
	if (need <= v->cap)
		return;
	int c = v->cap ? v->cap * 2 : 8;
	while (c < need)
		c *= 2;
	v->i = realloc(v->i, (size_t)c * sizeof *v->i);
	v->x = realloc(v->x, (size_t)c * sizeof *v->x);
	v->cap = c;
}

static void sv_free(struct svec *v)
{
	free(v->i);
	free(v->x);
	*v = (struct svec){0};
}

static int sv_find(const struct svec *v, int row)
{
	int lo = 0, hi = v->n;
	while (lo < hi) {
		int mid = (lo + hi) / 2;
		if (v->i[mid] < row)
			lo = mid + 1;
		else
			hi = mid;
	}
	return lo < v->n && v->i[lo] == row ? lo : -1;
}

static V sv_get(const struct svec *v, int row)
{
	int k = sv_find(v, row);
	return k < 0 ? 0 : v->x[k];
}

static void sv_remove(struct svec *v, int row)
{
	int k = sv_find(v, row);
	if (k < 0)
		return;
	memmove(v->i + k, v->i + k + 1, (size_t)(v->n - k - 1) * sizeof *v->i);
	memmove(v->x + k, v->x + k + 1, (size_t)(v->n - k - 1) * sizeof *v->x);
	v->n--;
}

/* dst += a * src over rows not in skip. */
static void sv_axpy(struct svec *dst, V a, const struct svec *src, const char *skip)
{
	if (a == 0 || !src->n)
		return;
	int n = dst->n + src->n;
	int *oi = malloc((size_t)n * sizeof *oi);
	V *ox = malloc((size_t)n * sizeof *ox);
	int p = 0, q = 0, k = 0;
	while (p < dst->n || q < src->n) {
		if (q < src->n && skip && skip[src->i[q]]) {
			q++;
			continue;
		}
		if (q >= src->n || (p < dst->n && dst->i[p] < src->i[q])) {
			oi[k] = dst->i[p];
			ox[k++] = dst->x[p++];
		} else if (p >= dst->n || src->i[q] < dst->i[p]) {
			oi[k] = src->i[q];
			ox[k++] = a * src->x[q++];
		} else {
			oi[k] = dst->i[p];
			ox[k++] = dst->x[p++] + a * src->x[q++];
		}
	}
	free(dst->i);
	free(dst->x);
	dst->i = oi;
	dst->x = ox;
	dst->n = k;
	dst->cap = n;
}

static void sv_from_column(struct svec *v, const struct csc *A, int j)
{
	int len = (int)(A->p[j + 1] - A->p[j]);
	sv_reserve(v, len);
	memcpy(v->i, A->i + A->p[j], (size_t)len * sizeof *v->i);
	memcpy(v->x, A->x + A->p[j], (size_t)len * sizeof *v->x);
	v->n = len;
}

/* Gathers columns (as sparse vectors over final indices) into compressed columns. */
static struct csc *csc_from_columns(int m, int n, struct svec *cols, const int *map)
{
	long nnz = 0;
	for (int j = 0; j < n; j++)
		nnz += cols[j].n;
	struct csc *C = csc_new(m, n, nnz);
	long at = 0;
	for (int j = 0; j < n; j++) {
		C->p[j] = at;
		for (int k = 0; k < cols[j].n; k++) {
			C->i[at] = map ? map[cols[j].i[k]] : cols[j].i[k];
			C->x[at++] = cols[j].x[k];
		}
	}
	C->p[n] = at;
	csc_tidy(C);
	return C;
}

#pragma mark - Structure

/* Size of a maximum matching between rows and columns (structural rank). */
static int structural_rank(const struct csc *A)
{
	int *match_row = malloc((size_t)(A->m ? A->m : 1) * sizeof *match_row);
	int *seen = malloc((size_t)(A->m ? A->m : 1) * sizeof *seen);
	int *stack = malloc((size_t)(A->n ? A->n : 1) * sizeof *stack), *pos = malloc((size_t)(A->n ? A->n : 1) * sizeof *pos);
	int *via = malloc((size_t)(A->n ? A->n : 1) * sizeof *via);
	for (int i = 0; i < A->m; i++) {
		match_row[i] = -1;
		seen[i] = -1;
	}
	int rank = 0;
	for (int start = 0; start < A->n; start++) {
		/* Depth-first search for an augmenting path from column start. */
		int top = 0, found = -1;
		stack[0] = start;
		pos[0] = (int)A->p[start];
		via[0] = -1;
		while (top >= 0 && found < 0) {
			int j = stack[top];
			if (pos[top] >= A->p[j + 1]) {
				top--;
				continue;
			}
			int i = A->i[pos[top]++];
			if (seen[i] == start)
				continue;
			seen[i] = start;
			via[top] = i;
			if (match_row[i] < 0) {
				found = top;
				break;
			}
			top++;
			stack[top] = match_row[i];
			pos[top] = (int)A->p[stack[top]];
		}
		if (found >= 0) {
			for (int t = 0; t <= found; t++)
				match_row[via[t]] = stack[t];
			rank++;
		}
	}
	free(match_row);
	free(seen);
	free(stack);
	free(pos);
	free(via);
	return rank;
}

SparseOpaqueSymbolicFactorization symbolic_factor(SparseFactorization_t type, const SparseMatrixStructure *S,
    const SparseSymbolicFactorOptions *options, int family)
{
	SparseOpaqueSymbolicFactorization out = {
	    .status = SparseStatusOK,
	    .rowCount = S->rowCount,
	    .columnCount = S->columnCount,
	    .attributes = S->attributes,
	    .blockSize = S->blockSize,
	    .type = type,
	};
	struct csc *A = csc_pattern(S);
	void *(*alloc)(size_t) = options->malloc ? options->malloc : malloc;
	struct symbolic *s = alloc(sizeof *s);
	memset(s, 0, sizeof *s);
	s->refs = 1;
	s->type = type;
	s->options = *options;
	if (!s->options.malloc)
		s->options.malloc = malloc;
	if (!s->options.free)
		s->options.free = free;
	s->family = family;
	s->m = A->m;
	s->n = A->n;
	if (family == FAMILY_LU && A->m != A->n) {
		sparse_report(options->reportError,
		    "Sparse LU factorization only supports square matrices, but supplied matrix without any ignored rows "
		    "and columns has shape %dx%d.\n",
		    A->m, A->n);
		out.status = SparseInternalError;
	} else if (family == FAMILY_QR && type == SparseFactorizationQR && A->m < A->n) {
		struct csc *T = csc_transpose(A, 0);
		csc_free(A);
		A = T;
		s->wide = 1;
		s->m = A->m;
		s->n = A->n;
	}
	if (out.status == SparseStatusOK && family != FAMILY_SYMMETRIC) {
		int need = A->m < A->n ? A->m : A->n;
		if (structural_rank(A) < need) {
			if (family == FAMILY_LU)
				sparse_report(options->reportError, "Matrix is structurally singular.");
			out.status = SparseInternalError;
		}
	}
	if (out.status == SparseStatusOK) {
		SparseOrder_t method = options->orderMethod;
		int n = A->n;
		if (method == SparseOrderUser) {
			s->perm = malloc((size_t)(n ? n : 1) * sizeof *s->perm);
			const int *user = options->order;
			if (family == FAMILY_LU && user)
				user += A->m;
			for (int k = 0; k < n; k++)
				s->perm[k] = user ? user[k] : k;
			if (family == FAMILY_LU) {
				s->row_perm = malloc((size_t)(A->m ? A->m : 1) * sizeof *s->row_perm);
				for (int k = 0; k < A->m; k++)
					s->row_perm[k] = options->order ? options->order[k] : k;
			}
		} else {
			int column = family != FAMILY_SYMMETRIC &&
			             (method == SparseOrderDefault || method == SparseOrderCOLAMD);
			s->perm = column ? order_colamd(A) : order_amd(A);
			if (options->order) {
				if (family == FAMILY_LU) {
					for (int k = 0; k < A->m; k++)
						options->order[k] = k;
					memcpy(options->order + A->m, s->perm, (size_t)n * sizeof *s->perm);
				} else {
					memcpy(options->order, s->perm, (size_t)n * sizeof *s->perm);
				}
			}
		}
		out.factorization = s;
		out.factorSize_Float = out.factorSize_Double = sizeof(struct numeric);
		out.workspaceSize_Float = out.workspaceSize_Double = 16;
	} else {
		s->options.free(s);
	}
	csc_free(A);
	return out;
}

void _SparseRetainSymbolic(SparseOpaqueSymbolicFactorization *symbolicFactor)
{
	struct symbolic *s = symbolicFactor->factorization;
	if (s)
		s->refs++;
}

void _SparseDestroyOpaqueSymbolic(SparseOpaqueSymbolicFactorization *toFree)
{
	struct symbolic *s = toFree->factorization;
	if (!s || --s->refs > 0)
		return;
	free(s->perm);
	free(s->row_perm);
	s->options.free(s);
	toFree->factorization = NULL;
	toFree->status = SparseStatusReleased;
}

SparseSymbolicFactorOptions _SparseGetOptionsFromSymbolicFactor(SparseOpaqueSymbolicFactorization *factor)
{
	struct symbolic *s = factor->factorization;
	if (s)
		return s->options;
	return (SparseSymbolicFactorOptions){.malloc = malloc, .free = free};
}

SparseOpaqueSymbolicFactorization _SparseSymbolicFactorSymmetric(SparseFactorization_t factorType,
    const SparseMatrixStructure *Matrix, const SparseSymbolicFactorOptions *options)
{
	return symbolic_factor(factorType, Matrix, options, FAMILY_SYMMETRIC);
}

SparseOpaqueSymbolicFactorization _SparseSymbolicFactorQR(SparseFactorization_t factorType,
    const SparseMatrixStructure *Matrix, const SparseSymbolicFactorOptions *options)
{
	return symbolic_factor(factorType, Matrix, options, FAMILY_QR);
}

SparseOpaqueSymbolicFactorization _SparseSymbolicFactorLU(SparseFactorization_t factorType,
    const SparseMatrixStructure *Matrix, const SparseSymbolicFactorOptions *options)
{
	return symbolic_factor(factorType, Matrix, options, FAMILY_LU);
}

#pragma mark - Scaling

/* Symmetric infinity-norm equilibration (Ruiz): s such that max_j |s_i a_ij s_j| -> 1. */
static double *equilibrate_symmetric(const struct csc *A)
{
	int n = A->n;
	double *s = malloc((size_t)(n ? n : 1) * sizeof *s), *r = malloc((size_t)(n ? n : 1) * sizeof *r);
	for (int k = 0; k < n; k++)
		s[k] = 1;
	for (int it = 0; it < 20; it++) {
		for (int k = 0; k < n; k++)
			r[k] = 0;
		for (int j = 0; j < n; j++)
			for (long k = A->p[j]; k < A->p[j + 1]; k++) {
				double v = sqrt(abs2(A->x[k])) * s[A->i[k]] * s[j];
				if (v > r[A->i[k]])
					r[A->i[k]] = v;
			}
		double worst = 0;
		for (int k = 0; k < n; k++) {
			if (r[k] > 0) {
				s[k] /= sqrt(r[k]);
				if (fabs(1 - r[k]) > worst)
					worst = fabs(1 - r[k]);
			}
		}
		if (worst < 1e-2)
			break;
	}
	free(r);
	return s;
}

/* Row then column infinity-norm scaling for LU (one Ruiz-style pass each way, repeated). */
static double *equilibrate_unsymmetric(const struct csc *A)
{
	int m = A->m, n = A->n;
	double *s = malloc((size_t)(m + n ? m + n : 1) * sizeof *s);
	double *r = malloc((size_t)(m + n ? m + n : 1) * sizeof *r);
	for (int k = 0; k < m + n; k++)
		s[k] = 1;
	for (int it = 0; it < 20; it++) {
		for (int k = 0; k < m + n; k++)
			r[k] = 0;
		for (int j = 0; j < n; j++)
			for (long k = A->p[j]; k < A->p[j + 1]; k++) {
				double v = sqrt(abs2(A->x[k])) * s[A->i[k]] * s[m + j];
				if (v > r[A->i[k]])
					r[A->i[k]] = v;
				if (v > r[m + j])
					r[m + j] = v;
			}
		double worst = 0;
		for (int k = 0; k < m + n; k++)
			if (r[k] > 0) {
				s[k] /= sqrt(r[k]);
				if (fabs(1 - r[k]) > worst)
					worst = fabs(1 - r[k]);
			}
		if (worst < 1e-2)
			break;
	}
	free(r);
	return s;
}

#pragma mark - Symmetric

static SparseStatus_t factor_symmetric(struct numeric *f, struct csc *A, const struct symbolic *s)
{
	int n = A->n;
	SparseFactorization_t type = f->ftype;
	int herm = f->hermitian;
	double u = f->options.pivotTolerance;
	if (u < 0)
		u = 0;
	if (u > 0.5)
		u = 0.5;
	double zero = f->options.zeroTolerance;
	double static_pivot = sqrt(is_single(f->type) ? 1.1920928955078125e-07 : 2.220446049250313e-16);
	int pivoting = type == SparseFactorizationLDLT || type == SparseFactorizationLDLTTPP;

	struct svec *col = calloc((size_t)(n ? n : 1), sizeof *col);
	for (int j = 0; j < n; j++)
		sv_from_column(&col[j], A, j);
	char *gone = calloc((size_t)(n ? n : 1), 1);
	int *queue = malloc((size_t)(2 * n + 1) * sizeof *queue);
	int head = 0, tail = 0;
	for (int k = 0; k < n; k++)
		queue[tail++] = s->perm[k];
	int *seq = malloc((size_t)(n ? n : 1) * sizeof *seq);
	struct svec *lcol = calloc((size_t)(n ? n : 1), sizeof *lcol);
	V *d = calloc((size_t)(n ? n : 1), sizeof *d), *e = calloc((size_t)(n ? n : 1), sizeof *e);
	int step = 0, stalled = 0;
	SparseStatus_t status = SparseStatusOK;
	f->positive = f->zero = f->negative = 0;

	while (step < n) {
		int k = queue[head % (2 * n + 1)];
		head++;
		if (gone[k])
			continue;
		V akk = sv_get(&col[k], k);
		double maxk = 0;
		int r = -1;
		for (int t = 0; t < col[k].n; t++)
			if (col[k].i[t] != k && sqrt(abs2(col[k].x[t])) > maxk) {
				maxk = sqrt(abs2(col[k].x[t]));
				r = col[k].i[t];
			}
		int size = 1;
		int remaining = tail - head + 1;
		if (pivoting) {
			if (sqrt(abs2(akk)) >= u * maxk && !(maxk == 0 && sqrt(abs2(akk)) <= zero && stalled < remaining))
				size = 1;
			else if (r >= 0) {
				V arr = sv_get(&col[r], r), ark = sv_get(&col[k], r);
				V det = akk * arr - (herm ? ark * conj(ark) : ark * ark);
				double maxk2 = 0, maxr = 0;
				for (int t = 0; t < col[k].n; t++)
					if (col[k].i[t] != k && col[k].i[t] != r && sqrt(abs2(col[k].x[t])) > maxk2)
						maxk2 = sqrt(abs2(col[k].x[t]));
				for (int t = 0; t < col[r].n; t++)
					if (col[r].i[t] != k && col[r].i[t] != r && sqrt(abs2(col[r].x[t])) > maxr)
						maxr = sqrt(abs2(col[r].x[t]));
				int ok = 0;
				if (det != 0) {
					double ad = sqrt(abs2(det));
					double i11 = sqrt(abs2(arr)) / ad, i12 = sqrt(abs2(ark)) / ad, i22 = sqrt(abs2(akk)) / ad;
					ok = u == 0 || (i11 * maxk2 + i12 * maxr <= 1 / u && i12 * maxk2 + i22 * maxr <= 1 / u);
				}
				if (ok)
					size = 2;
				else if (stalled < remaining) {
					queue[tail % (2 * n + 1)] = k;
					tail++;
					stalled++;
					continue;
				} else {
					size = sqrt(abs2(akk)) > zero || det == 0 ? 1 : 2;
				}
			} else if (stalled < remaining && sqrt(abs2(akk)) <= zero) {
				queue[tail % (2 * n + 1)] = k;
				tail++;
				stalled++;
				continue;
			}
		} else if (type == SparseFactorizationLDLTSBK) {
			/* Bunch-Kaufman with the next candidate; tiny 1x1 pivots are perturbed. */
			const double alpha = (1 + sqrt(17.0)) / 8;
			if (sqrt(abs2(akk)) < alpha * maxk && r >= 0) {
				V arr = sv_get(&col[r], r), ark = sv_get(&col[k], r);
				V det = akk * arr - (herm ? ark * conj(ark) : ark * ark);
				if (det != 0 && sqrt(abs2(det)) > static_pivot * maxk * maxk)
					size = 2;
			}
		}
		stalled = 0;

		if (size == 1) {
			V dk = akk;
			if (type == SparseFactorizationCholesky &&
			    (creal(dk) <= 0 || (is_complex(f->type) && fabs(cimag(dk)) > 0))) {
				status = SparseFactorizationFailed;
				break;
			}
			if (type == SparseFactorizationLDLTUnpivoted && dk == 0) {
				status = SparseFactorizationFailed;
				break;
			}
			if (type == SparseFactorizationLDLTSBK && sqrt(abs2(dk)) < static_pivot)
				dk = creal(dk) < 0 ? -static_pivot : static_pivot;
			if (pivoting && sqrt(abs2(dk)) <= zero)
				dk = 0;
			gone[k] = 1;
			seq[step] = k;
			d[step] = dk;
			e[step] = 0;
			double re = creal(dk);
			if (dk == 0)
				f->zero++;
			else if (re > 0)
				f->positive++;
			else
				f->negative++;
			struct svec *l = &lcol[step];
			for (int t = 0; t < col[k].n; t++) {
				int i = col[k].i[t];
				if (i == k)
					continue;
				sv_reserve(l, l->n + 1);
				l->i[l->n] = i;
				l->x[l->n++] = dk == 0 ? 0 : col[k].x[t] / dk;
			}
			/* Schur update: column j -= col_k * conj?(a_jk) / d. */
			for (int t = 0; t < col[k].n; t++) {
				int j = col[k].i[t];
				if (j == k)
					continue;
				sv_remove(&col[j], k);
				if (dk != 0)
					sv_axpy(&col[j], -conj_if(herm, col[k].x[t]) / dk, &col[k], gone);
			}
			step++;
		} else {
			V arr = sv_get(&col[r], r), ark = sv_get(&col[k], r);
			V akr = herm ? conj(ark) : ark;
			V det = akk * arr - akr * ark;
			/* D = [akk akr; ark arr]; Dinv = [arr -akr; -ark akk] / det. */
			V i11 = arr / det, i12 = -akr / det, i21 = -ark / det, i22 = akk / det;
			gone[k] = gone[r] = 1;
			seq[step] = k;
			seq[step + 1] = r;
			d[step] = akk;
			d[step + 1] = arr;
			e[step] = ark;
			e[step + 1] = 0;
			/* Inertia of a 2x2 block from its determinant and trace. */
			if (creal(det) < 0)
				f->positive++, f->negative++;
			else if (creal(akk + arr) > 0)
				f->positive += 2;
			else
				f->negative += 2;
			struct svec *l1 = &lcol[step], *l2 = &lcol[step + 1];
			/* Rows touched by either column. */
			struct svec rows = {0};
			sv_axpy(&rows, 1, &col[k], gone);
			sv_axpy(&rows, 1, &col[r], gone);
			for (int t = 0; t < rows.n; t++) {
				int i = rows.i[t];
				V aik = sv_get(&col[k], i), air = sv_get(&col[r], i);
				/* [l_ik l_ir] = [a_ik a_ir] Dinv. */
				V lk = aik * i11 + air * i21, lr = aik * i12 + air * i22;
				sv_reserve(l1, l1->n + 1);
				l1->i[l1->n] = i;
				l1->x[l1->n++] = lk;
				sv_reserve(l2, l2->n + 1);
				l2->i[l2->n] = i;
				l2->x[l2->n++] = lr;
			}
			for (int t = 0; t < rows.n; t++) {
				int j = rows.i[t];
				V ajk = conj_if(herm, sv_get(&col[k], j)), ajr = conj_if(herm, sv_get(&col[r], j));
				/* column j -= col_k (i11 ajk + i12 ajr) + col_r (i21 ajk + i22 ajr). */
				V ck = i11 * ajk + i12 * ajr, cr = i21 * ajk + i22 * ajr;
				sv_remove(&col[j], k);
				sv_remove(&col[j], r);
				sv_axpy(&col[j], -ck, &col[k], gone);
				sv_axpy(&col[j], -cr, &col[r], gone);
			}
			sv_free(&rows);
			step += 2;
		}
	}
	if (status == SparseStatusOK) {
		int *pos = malloc((size_t)(n ? n : 1) * sizeof *pos);
		for (int t = 0; t < n; t++)
			pos[seq[t]] = t;
		f->L = csc_from_columns(n, n, lcol, pos);
		free(pos);
		f->perm = seq;
		f->d = d;
		f->e = e;
		if (type == SparseFactorizationCholesky) {
			/* L sqrt(D), with the diagonal stored. */
			struct csc *C = csc_new(n, n, f->L->p[n] + n);
			long at = 0;
			for (int j = 0; j < n; j++) {
				double sd = sqrt(creal(d[j]));
				C->p[j] = at;
				C->i[at] = j;
				C->x[at++] = sd;
				for (long q = f->L->p[j]; q < f->L->p[j + 1]; q++) {
					C->i[at] = f->L->i[q];
					C->x[at++] = f->L->x[q] * sd;
				}
			}
			C->p[n] = at;
			csc_free(f->L);
			f->L = C;
			f->cholesky = 1;
		}
	} else {
		free(seq);
		free(d);
		free(e);
	}
	for (int j = 0; j < n; j++) {
		sv_free(&col[j]);
		sv_free(&lcol[j]);
	}
	free(col);
	free(lcol);
	free(gone);
	free(queue);
	return status;
}

#pragma mark - QR

static SparseStatus_t factor_qr(struct numeric *f, struct csc *A, const struct symbolic *s, int keep_q)
{
	int m = A->m, n = A->n;
	struct svec *col = calloc((size_t)(n ? n : 1), sizeof *col);
	for (int k = 0; k < n; k++)
		sv_from_column(&col[k], A, s->perm[k]);
	char *used = calloc((size_t)(m ? m : 1), 1);
	int *rowstep = malloc((size_t)(m ? m : 1) * sizeof *rowstep);
	int *pivot_row = malloc((size_t)(n ? n : 1) * sizeof *pivot_row);
	struct svec *H = calloc((size_t)(n ? n : 1), sizeof *H), *R = calloc((size_t)(n ? n : 1), sizeof *R);
	V *beta = calloc((size_t)(n ? n : 1), sizeof *beta);
	int steps = n < m ? n : m;
	for (int k = 0; k < n; k++) {
		struct svec *c = &col[k];
		/* The R part (pivot rows of earlier steps) and the Householder part. */
		double norm2 = 0;
		int pr = -1;
		for (int t = 0; t < c->n; t++) {
			int i = c->i[t];
			if (used[i]) {
				sv_reserve(&R[k], R[k].n + 1);
				R[k].i[R[k].n] = rowstep[i];
				R[k].x[R[k].n++] = c->x[t];
			} else {
				norm2 += abs2(c->x[t]);
				if (pr < 0)
					pr = i;
			}
		}
		if (k >= steps)
			continue;
		if (pr < 0)
			for (int i = 0; i < m; i++)
				if (!used[i]) {
					pr = i;
					break;
				}
		used[pr] = 1;
		rowstep[pr] = k;
		pivot_row[k] = pr;
		V x0 = sv_get(c, pr);
		double norm = sqrt(norm2), ax0 = sqrt(abs2(x0));
		V alpha;
		struct svec *v = &H[k];
		if (norm == 0) {
			alpha = 0;
			beta[k] = 0;
		} else {
			V phase = ax0 == 0 ? 1 : x0 / ax0;
			alpha = -phase * norm;
			for (int t = 0; t < c->n; t++) {
				int i = c->i[t];
				if (rowstep[i] != k && used[i])
					continue;
				sv_reserve(v, v->n + 1);
				v->i[v->n] = i;
				v->x[v->n++] = i == pr ? c->x[t] - alpha : c->x[t];
			}
			if (sv_find(v, pr) < 0) {
				struct svec one = {0};
				sv_reserve(&one, 1);
				one.i[0] = pr;
				one.x[0] = -alpha;
				one.n = 1;
				sv_axpy(v, 1, &one, NULL);
				sv_free(&one);
			}
			beta[k] = 1 / (norm * (norm + ax0));
		}
		sv_reserve(&R[k], R[k].n + 1);
		R[k].i[R[k].n] = k;
		R[k].x[R[k].n++] = alpha;
		/* Apply H = I - beta v v^H to the later columns. */
		if (beta[k] != 0)
			for (int j = k + 1; j < n; j++) {
				V dot = 0;
				struct svec *cj = &col[j];
				int p = 0, q = 0;
				while (p < v->n && q < cj->n) {
					if (v->i[p] < cj->i[q])
						p++;
					else if (v->i[p] > cj->i[q])
						q++;
					else
						dot += conj(v->x[p++]) * cj->x[q++];
				}
				if (dot != 0)
					sv_axpy(cj, -beta[k] * dot, v, NULL);
			}
	}
	f->R = csc_from_columns(n, n, R, NULL);
	if (keep_q) {
		f->H = csc_from_columns(m, steps, H, NULL);
		f->beta = beta;
	} else {
		free(beta);
	}
	f->row_perm = pivot_row;
	f->perm = malloc((size_t)(n ? n : 1) * sizeof *f->perm);
	memcpy(f->perm, s->perm, (size_t)n * sizeof *f->perm);
	for (int k = 0; k < n; k++) {
		sv_free(&col[k]);
		sv_free(&H[k]);
		sv_free(&R[k]);
	}
	free(col);
	free(H);
	free(R);
	free(used);
	free(rowstep);
	return SparseStatusOK;
}

#pragma mark - LU

static SparseStatus_t factor_lu(struct numeric *f, struct csc *A, const struct symbolic *s)
{
	int n = A->n;
	SparseFactorization_t type = f->ftype;
	double u = f->options.pivotTolerance;
	if (u < 0)
		u = 0;
	if (u > 0.5)
		u = 0.5;
	double static_pivot = sqrt(is_single(f->type) ? 1.1920928955078125e-07 : 2.220446049250313e-16);
	struct svec *col = calloc((size_t)(n ? n : 1), sizeof *col);
	for (int k = 0; k < n; k++)
		sv_from_column(&col[k], A, s->perm[k]);
	/* A structural diagonal (a matching) gives each step a preferred row. */
	int *prefer = malloc((size_t)(n ? n : 1) * sizeof *prefer);
	{
		struct csc *P = csc_new(n, n, A->p[n]);
		long at = 0;
		for (int k = 0; k < n; k++) {
			P->p[k] = at;
			for (int t = 0; t < col[k].n; t++) {
				P->i[at] = col[k].i[t];
				P->x[at++] = 1;
			}
		}
		P->p[n] = at;
		/* Greedy augmenting matching, column by column. */
		int *match = malloc((size_t)(n ? n : 1) * sizeof *match), *seen = malloc((size_t)(n ? n : 1) * sizeof *seen);
		int *stack = malloc((size_t)(n ? n : 1) * sizeof *stack), *pos = malloc((size_t)(n ? n : 1) * sizeof *pos);
		int *via = malloc((size_t)(n ? n : 1) * sizeof *via);
		for (int i = 0; i < n; i++)
			match[i] = -1, seen[i] = -1, prefer[i] = -1;
		for (int start = 0; start < n; start++) {
			int top = 0, found = -1;
			stack[0] = start;
			pos[0] = (int)P->p[start];
			while (top >= 0 && found < 0) {
				int j = stack[top];
				if (pos[top] >= P->p[j + 1]) {
					top--;
					continue;
				}
				int i = P->i[pos[top]++];
				if (seen[i] == start)
					continue;
				seen[i] = start;
				via[top] = i;
				if (match[i] < 0) {
					found = top;
					break;
				}
				top++;
				stack[top] = match[i];
				pos[top] = (int)P->p[stack[top]];
			}
			for (int t = 0; t <= found; t++)
				match[via[t]] = stack[t];
		}
		for (int i = 0; i < n; i++)
			if (match[i] >= 0)
				prefer[match[i]] = i;
		free(match);
		free(seen);
		free(stack);
		free(pos);
		free(via);
		csc_free(P);
	}
	char *used = calloc((size_t)(n ? n : 1), 1);
	int *rowstep = malloc((size_t)(n ? n : 1) * sizeof *rowstep), *pivot_row = malloc((size_t)(n ? n : 1) * sizeof *pivot_row);
	struct svec *lcol = calloc((size_t)(n ? n : 1), sizeof *lcol), *ucol = calloc((size_t)(n ? n : 1), sizeof *ucol);
	for (int k = 0; k < n; k++) {
		struct svec *c = &col[k];
		double best = 0;
		int r = -1;
		for (int t = 0; t < c->n; t++)
			if (!used[c->i[t]] && sqrt(abs2(c->x[t])) > best) {
				best = sqrt(abs2(c->x[t]));
				r = c->i[t];
			}
		int pref = prefer[k] >= 0 && !used[prefer[k]] ? prefer[k] : -1;
		if (pref < 0)
			for (int t = 0; t < c->n && pref < 0; t++)
				if (!used[c->i[t]])
					pref = c->i[t];
		if (pref < 0)
			for (int i = 0; i < n; i++)
				if (!used[i]) {
					pref = i;
					break;
				}
		if (type == SparseFactorizationLUUnpivoted || r < 0 || sqrt(abs2(sv_get(c, pref))) >= u * best)
			r = pref;
		used[r] = 1;
		rowstep[r] = k;
		pivot_row[k] = r;
		V piv = sv_get(c, r);
		if (type == SparseFactorizationLUSPP && sqrt(abs2(piv)) < static_pivot * (best > 1 ? best : 1)) {
			piv = creal(piv) < 0 ? -static_pivot : static_pivot;
			int at = sv_find(c, r);
			if (at >= 0)
				c->x[at] = piv;
		}
		/* U column k: the rows already pivoted, then the pivot. */
		for (int t = 0; t < c->n; t++)
			if (used[c->i[t]]) {
				sv_reserve(&ucol[k], ucol[k].n + 1);
				ucol[k].i[ucol[k].n] = rowstep[c->i[t]];
				ucol[k].x[ucol[k].n++] = c->i[t] == r ? piv : c->x[t];
			}
		if (sv_find(c, r) < 0) {
			sv_reserve(&ucol[k], ucol[k].n + 1);
			ucol[k].i[ucol[k].n] = k;
			ucol[k].x[ucol[k].n++] = piv;
		}
		/* L column k: the unpivoted rows over the pivot. */
		struct svec *l = &lcol[k];
		for (int t = 0; t < c->n; t++)
			if (!used[c->i[t]]) {
				sv_reserve(l, l->n + 1);
				l->i[l->n] = c->i[t];
				l->x[l->n++] = piv == 0 ? 0 : c->x[t] / piv;
			}
		/* Update the later columns with an entry in the pivot row. */
		for (int j = k + 1; j < n; j++) {
			V arj = sv_get(&col[j], r);
			if (arj != 0)
				sv_axpy(&col[j], -arj, l, used);
		}
	}
	/* L's rows by step. */
	for (int k = 0; k < n; k++)
		for (int t = 0; t < lcol[k].n; t++)
			lcol[k].i[t] = rowstep[lcol[k].i[t]];
	f->LU_L = csc_from_columns(n, n, lcol, NULL);
	f->LU_U = csc_from_columns(n, n, ucol, NULL);
	f->row_perm = pivot_row;
	f->perm = malloc((size_t)(n ? n : 1) * sizeof *f->perm);
	memcpy(f->perm, s->perm, (size_t)n * sizeof *f->perm);
	for (int k = 0; k < n; k++) {
		sv_free(&col[k]);
		sv_free(&lcol[k]);
		sv_free(&ucol[k]);
	}
	free(col);
	free(lcol);
	free(ucol);
	free(used);
	free(rowstep);
	free(prefer);
	return SparseStatusOK;
}

#pragma mark - Numeric factorization

static void clear_numeric(struct numeric *f)
{
	free(f->perm);
	free(f->row_perm);
	free(f->scale);
	csc_free(f->L);
	free(f->d);
	free(f->e);
	csc_free(f->H);
	free(f->beta);
	csc_free(f->R);
	csc_free(f->LU_L);
	csc_free(f->LU_U);
	f->perm = f->row_perm = NULL;
	f->scale = NULL;
	f->L = f->H = f->R = f->LU_L = f->LU_U = NULL;
	f->d = f->e = f->beta = NULL;
	f->factored = 0;
}

SparseStatus_t numeric_factor(struct numeric *f, const struct matrix_view *view)
{
	const struct symbolic *s = f->symbolic.factorization;
	clear_numeric(f);
	struct csc *A = csc_from_view(view);
	f->family = s->family;
	SparseStatus_t status = SparseStatusOK;
	if (s->family == FAMILY_SYMMETRIC) {
		f->m = f->n = A->n;
		f->hermitian = !is_complex(f->type) || view->kind == SparseHermitian;
		SparseScaling_t method = f->options.scalingMethod;
		int ldlt = f->ftype != SparseFactorizationCholesky;
		double *sc = NULL;
		if (method == SparseScalingUser) {
			if (f->options.scaling) {
				sc = malloc((size_t)(A->n ? A->n : 1) * sizeof *sc);
				for (int k = 0; k < A->n; k++)
					sc[k] = creal(load(f->type, f->options.scaling, k));
			}
		} else if (method == SparseScalingEquilibriationInf || method == SparseScalingHungarianScalingOnly ||
		           method == SparseScalingHungarianScalingAndOrdering || (method == SparseScalingDefault && ldlt)) {
			sc = equilibrate_symmetric(A);
			if (f->options.scaling)
				for (int k = 0; k < A->n; k++)
					store(f->type, f->options.scaling, k, sc[k]);
		}
		if (sc)
			for (int j = 0; j < A->n; j++)
				for (long k = A->p[j]; k < A->p[j + 1]; k++)
					A->x[k] *= sc[A->i[k]] * sc[j];
		status = factor_symmetric(f, A, s);
		f->scale = sc;
	} else if (s->family == FAMILY_QR) {
		if (s->wide) {
			struct csc *T = csc_transpose(A, 1);
			csc_free(A);
			A = T;
		}
		f->m = A->m;
		f->n = A->n;
		status = factor_qr(f, A, s, f->ftype == SparseFactorizationQR);
	} else {
		f->m = f->n = A->n;
		SparseScaling_t method = f->options.scalingMethod;
		double *sc = NULL;
		if (method == SparseScalingUser) {
			if (f->options.scaling) {
				sc = malloc((size_t)(2 * A->n ? 2 * A->n : 1) * sizeof *sc);
				for (int k = 0; k < 2 * A->n; k++)
					sc[k] = creal(load(f->type, f->options.scaling, k));
			}
		} else if (method == SparseScalingEquilibriationInf || method == SparseScalingHungarianScalingOnly ||
		           method == SparseScalingHungarianScalingAndOrdering) {
			sc = equilibrate_unsymmetric(A);
			if (f->options.scaling)
				for (int k = 0; k < 2 * A->n; k++)
					store(f->type, f->options.scaling, k, sc[k]);
		}
		if (sc)
			for (int j = 0; j < A->n; j++)
				for (long k = A->p[j]; k < A->p[j + 1]; k++)
					A->x[k] *= sc[A->i[k]] * sc[A->n + j];
		status = factor_lu(f, A, s);
		f->scale = sc;
	}
	csc_free(A);
	f->factored = status == SparseStatusOK;
	return status;
}

void numeric_release(struct numeric *f)
{
	clear_numeric(f);
}

#pragma mark - Triangular and permutation kernels

/* Solves with a triangular csc (columns), on a dense column x of length n. */
static void tri_solve(const struct csc *T, int lower, int unit, int transpose, int conjugate, V *x, int zero_inverse)
{
	int n = T->n;
	if (!transpose) {
		if (lower) {
			for (int j = 0; j < n; j++) {
				V diag = 1;
				for (long k = T->p[j]; k < T->p[j + 1]; k++)
					if (T->i[k] == j)
						diag = conj_if(conjugate, T->x[k]);
				if (!unit)
					x[j] = diag == 0 && zero_inverse ? 0 : x[j] / diag;
				for (long k = T->p[j]; k < T->p[j + 1]; k++)
					if (T->i[k] > j)
						x[T->i[k]] -= conj_if(conjugate, T->x[k]) * x[j];
			}
		} else {
			for (int j = n - 1; j >= 0; j--) {
				V diag = 1;
				for (long k = T->p[j]; k < T->p[j + 1]; k++)
					if (T->i[k] == j)
						diag = conj_if(conjugate, T->x[k]);
				if (!unit)
					x[j] = diag == 0 && zero_inverse ? 0 : x[j] / diag;
				for (long k = T->p[j]; k < T->p[j + 1]; k++)
					if (T->i[k] < j)
						x[T->i[k]] -= conj_if(conjugate, T->x[k]) * x[j];
			}
		}
	} else {
		/* op(T) = T^T: lower becomes upper; walk columns as rows. */
		if (lower) {
			for (int j = n - 1; j >= 0; j--) {
				V s = x[j], diag = 1;
				for (long k = T->p[j]; k < T->p[j + 1]; k++) {
					if (T->i[k] > j)
						s -= conj_if(conjugate, T->x[k]) * x[T->i[k]];
					else if (T->i[k] == j)
						diag = conj_if(conjugate, T->x[k]);
				}
				x[j] = unit ? s : (diag == 0 && zero_inverse ? 0 : s / diag);
			}
		} else {
			for (int j = 0; j < n; j++) {
				V s = x[j], diag = 1;
				for (long k = T->p[j]; k < T->p[j + 1]; k++) {
					if (T->i[k] < j)
						s -= conj_if(conjugate, T->x[k]) * x[T->i[k]];
					else if (T->i[k] == j)
						diag = conj_if(conjugate, T->x[k]);
				}
				x[j] = unit ? s : (diag == 0 && zero_inverse ? 0 : s / diag);
			}
		}
	}
}

static void tri_multiply(const struct csc *T, int lower, int unit, int transpose, int conjugate, V *x)
{
	int n = T->n;
	V *y = calloc((size_t)(n ? n : 1), sizeof *y);
	for (int j = 0; j < n; j++) {
		if (unit)
			y[j] += x[j];
		for (long k = T->p[j]; k < T->p[j + 1]; k++) {
			int i = T->i[k];
			if (unit && i == j)
				continue;
			if (lower ? i < j : i > j)
				continue;
			V a = conj_if(conjugate, T->x[k]);
			if (!transpose)
				y[i] += a * x[j];
			else
				y[j] += a * x[i];
		}
	}
	memcpy(x, y, (size_t)n * sizeof *x);
	free(y);
}

/* D (block diagonal) times x, or its solve; transposition only conjugates Hermitian blocks. */
static void d_apply(const struct numeric *f, int transpose, int conjugate, int solve, V *x)
{
	int n = f->n;
	for (int k = 0; k < n; k++) {
		if (k + 1 < n && f->e[k] != 0) {
			V a = f->d[k], b = f->d[k + 1], sub = f->e[k];
			V sup = f->hermitian ? conj(sub) : sub;
			if (transpose) {
				V t = sub;
				sub = sup;
				sup = t;
				if (conjugate) {
					a = conj(a), b = conj(b), sub = conj(sub), sup = conj(sup);
				}
			}
			V x0 = x[k], x1 = x[k + 1];
			if (!solve) {
				x[k] = a * x0 + sup * x1;
				x[k + 1] = sub * x0 + b * x1;
			} else {
				V det = a * b - sup * sub;
				x[k] = (b * x0 - sup * x1) / det;
				x[k + 1] = (a * x1 - sub * x0) / det;
			}
			k++;
		} else {
			V a = transpose && conjugate ? conj(f->d[k]) : f->d[k];
			x[k] = solve ? (a == 0 ? 0 : x[k] / a) : a * x[k];
		}
	}
}

/* QR: z = Q_full^H z (forward) or Q_full z. */
static void q_apply(const struct numeric *f, int adjoint, V *z)
{
	int steps = f->H->n;
	for (int s = 0; s < steps; s++) {
		int k = adjoint ? s : steps - 1 - s;
		if (f->beta[k] == 0)
			continue;
		V dot = 0;
		for (long q = f->H->p[k]; q < f->H->p[k + 1]; q++)
			dot += conj(f->H->x[q]) * z[f->H->i[q]];
		V t = f->beta[k] * dot;
		for (long q = f->H->p[k]; q < f->H->p[k + 1]; q++)
			z[f->H->i[q]] -= t * f->H->x[q];
	}
}

#pragma mark - Solve

/* One right-hand side, in place on x (length max(m, n)). */
static void solve_one(const struct numeric *f, int transpose, int conjugate, V *x)
{
	int n = f->n;
	if (f->family == FAMILY_SYMMETRIC) {
		/* A' for a complex Hermitian matrix is conj(A); for a symmetric one, A. */
		int flip = transpose && !conjugate && f->hermitian && is_complex(f->type);
		if (flip)
			for (int i = 0; i < n; i++)
				x[i] = conj(x[i]);
		V *z = malloc((size_t)(n ? n : 1) * sizeof *z);
		for (int k = 0; k < n; k++)
			z[k] = x[f->perm[k]] * (f->scale ? f->scale[f->perm[k]] : 1);
		int herm = f->hermitian;
		if (f->cholesky) {
			tri_solve(f->L, 1, 0, 0, 0, z, 0);
			tri_solve(f->L, 1, 0, 1, herm, z, 0);
		} else {
			tri_solve(f->L, 1, 1, 0, 0, z, 0);
			d_apply(f, 0, 0, 1, z);
			tri_solve(f->L, 1, 1, 1, herm, z, 0);
		}
		for (int k = 0; k < n; k++)
			x[f->perm[k]] = z[k] * (f->scale ? f->scale[f->perm[k]] : 1);
		if (flip)
			for (int i = 0; i < n; i++)
				x[i] = conj(x[i]);
		free(z);
		return;
	}
	if (f->family == FAMILY_LU) {
		int t = transpose, c = transpose && conjugate;
		const double *sr = f->scale, *sc = f->scale ? f->scale + n : NULL;
		V *z = malloc((size_t)(n ? n : 1) * sizeof *z);
		int zero_inverse = f->ftype != SparseFactorizationLUUnpivoted;
		if (!t) {
			for (int k = 0; k < n; k++)
				z[k] = x[f->row_perm[k]] * (sr ? sr[f->row_perm[k]] : 1);
			tri_solve(f->LU_L, 1, 1, 0, 0, z, 0);
			tri_solve(f->LU_U, 0, 0, 0, 0, z, zero_inverse);
			for (int k = 0; k < n; k++)
				x[f->perm[k]] = z[k] * (sc ? sc[f->perm[k]] : 1);
		} else {
			for (int k = 0; k < n; k++)
				z[k] = x[f->perm[k]] * (sc ? sc[f->perm[k]] : 1);
			tri_solve(f->LU_U, 0, 0, 1, c, z, zero_inverse);
			tri_solve(f->LU_L, 1, 1, 1, c, z, 0);
			for (int k = 0; k < n; k++)
				x[f->row_perm[k]] = z[k] * (sr ? sr[f->row_perm[k]] : 1);
		}
		free(z);
		return;
	}
	/* QR family: F = QRP is the factored matrix (op(A), or its adjoint when wide). */
	const struct symbolic *s = f->symbolic.factorization;
	int m = f->m;
	int adjoint = transpose ^ s->wide; /* solving with F^H rather than F */
	int flip = transpose && !conjugate && is_complex(f->type);
	if (flip)
		for (int i = 0; i < (m > n ? m : n); i++)
			x[i] = conj(x[i]);
	if (f->ftype == SparseFactorizationCholeskyAtA) {
		V *z = malloc((size_t)(n ? n : 1) * sizeof *z);
		for (int k = 0; k < n; k++)
			z[k] = x[f->perm[k]];
		tri_solve(f->R, 0, 0, 1, 1, z, 0);
		tri_solve(f->R, 0, 0, 0, 0, z, 0);
		for (int k = 0; k < n; k++)
			x[f->perm[k]] = z[k];
		free(z);
	} else if (!adjoint) {
		/* Least squares: x = P' R^-1 (Q^H b). */
		V *w = malloc((size_t)(m ? m : 1) * sizeof *w), *z = malloc((size_t)(n ? n : 1) * sizeof *z);
		memcpy(w, x, (size_t)m * sizeof *w);
		q_apply(f, 1, w);
		for (int k = 0; k < n; k++)
			z[k] = k < f->H->n ? w[f->row_perm[k]] : 0;
		tri_solve(f->R, 0, 0, 0, 0, z, 0);
		for (int i = 0; i < (m > n ? m : n); i++)
			x[i] = 0;
		for (int k = 0; k < n; k++)
			x[f->perm[k]] = z[k];
		free(w);
		free(z);
	} else {
		/* Minimum norm: x = Q R^-H P b. */
		V *z = malloc((size_t)(n ? n : 1) * sizeof *z), *w = calloc((size_t)(m ? m : 1), sizeof *w);
		for (int k = 0; k < n; k++)
			z[k] = x[f->perm[k]];
		tri_solve(f->R, 0, 0, 1, 1, z, 0);
		for (int k = 0; k < f->H->n; k++)
			w[f->row_perm[k]] = z[k];
		q_apply(f, 0, w);
		memcpy(x, w, (size_t)m * sizeof *x);
		free(z);
		free(w);
	}
	if (flip)
		for (int i = 0; i < (m > n ? m : n); i++)
			x[i] = conj(x[i]);
}

void numeric_solve(const struct numeric *f, int transpose, int conjugate, const struct dense_view *B,
    const struct dense_view *X)
{
	const struct symbolic *s = f->symbolic.factorization;
	int m = f->m, n = f->n;
	int len = m > n ? m : n;
	/* Sizes of the right-hand side and solution for this solve. */
	int bsize = len, xsize = len;
	if (f->family == FAMILY_QR && f->ftype == SparseFactorizationQR) {
		int adjoint = transpose ^ s->wide;
		bsize = adjoint ? n : m;
		xsize = adjoint ? m : n;
	}
	const struct dense_view *in = B ? B : X;
	int nrhs = dense_cols(in);
	V *x = malloc((size_t)(len ? len : 1) * sizeof *x);
	for (int r = 0; r < nrhs; r++) {
		for (int i = 0; i < len; i++)
			x[i] = i < (B ? bsize : len) ? dense_get(in, i, r) : 0;
		solve_one(f, transpose, conjugate, x);
		for (int i = 0; i < (B ? xsize : len); i++)
			dense_put(X, i, r, fix(X->type, x[i]));
	}
	free(x);
}

#pragma mark - Subfactors

/* Gathers z[k] = x[perm[k]] (forward) or scatters x[perm[k]] = z[k]. */
static void permute(const int *perm, int n, int gather, V *x)
{
	V *z = malloc((size_t)(n ? n : 1) * sizeof *z);
	for (int k = 0; k < n; k++) {
		if (gather)
			z[k] = x[perm[k]];
		else
			z[perm[k]] = x[k];
	}
	memcpy(x, z, (size_t)n * sizeof *x);
	free(z);
}

static void subfactor_one(const struct numeric *f, SparseSubfactor_t which, int t, int c, int solve, V *x)
{
	int n = f->n;
	switch (which) {
	case SparseSubfactorP:
		if (f->family == FAMILY_QR)
			/* A = QRP: P x gathers by the column order. */
			permute(f->perm, n, (t == solve) ? 0 : 1, x);
		else
			/* PLDL'P' and P Abar Q: P y scatters to the pivot rows. */
			permute(f->family == FAMILY_LU ? f->row_perm : f->perm, n, (t == solve) ? 1 : 0, x);
		break;
	case SparseSubfactorQ:
		if (f->family == FAMILY_LU) {
			permute(f->perm, n, (t == solve) ? 0 : 1, x);
		} else {
			int m = f->m;
			V *w = calloc((size_t)(m ? m : 1), sizeof *w);
			/* Q (thin) maps the step coordinates through the pivot rows. */
			int adjoint = t ^ solve;
			if (!adjoint) {
				for (int k = 0; k < f->H->n; k++)
					w[f->row_perm[k]] = x[k];
				q_apply(f, 0, w);
				for (int i = 0; i < m; i++)
					x[i] = w[i];
			} else {
				/* Q^H b in the first n entries; the rest are left as they were. */
				memcpy(w, x, (size_t)m * sizeof *w);
				q_apply(f, 1, w);
				for (int k = 0; k < f->H->n; k++)
					x[k] = w[f->row_perm[k]];
			}
			free(w);
		}
		break;
	case SparseSubfactorS:
	case SparseSubfactorSr:
	case SparseSubfactorSc: {
		const double *sc = f->scale ? (which == SparseSubfactorSc ? f->scale + n : f->scale) : NULL;
		for (int k = 0; k < n; k++) {
			double s = sc ? sc[k] : 1;
			x[k] = solve ? x[k] / s : x[k] * s;
		}
		break;
	}
	case SparseSubfactorL:
		if (solve)
			tri_solve(f->L, 1, !f->cholesky, t, c, x, 0);
		else
			tri_multiply(f->L, 1, !f->cholesky, t, c, x);
		break;
	case SparseSubfactorD:
		d_apply(f, t, c, solve, x);
		break;
	case SparseSubfactorR:
		if (solve)
			tri_solve(f->R, 0, 0, t, c, x, 0);
		else
			tri_multiply(f->R, 0, 0, t, c, x);
		break;
	case SparseSubfactorRP:
		/* R P, or P' R' when transposed: only solves. */
		if (!t) {
			tri_solve(f->R, 0, 0, 0, 0, x, 0);
			permute(f->perm, n, 0, x);
		} else {
			permute(f->perm, n, 1, x);
			tri_solve(f->R, 0, 0, 1, c, x, 0);
		}
		break;
	case SparseSubfactorPLPS: {
		/* Forward: (P L P' S^-1)^-1 x; transposed: (S^-1 P D L' P')^-1 x. */
		const double *sc = f->scale;
		if (!t) {
			for (int k = 0; k < n; k++)
				x[k] *= sc ? sc[k] : 1;
			permute(f->perm, n, 1, x);
			tri_solve(f->L, 1, !f->cholesky, 0, 0, x, 0);
			permute(f->perm, n, 0, x);
		} else {
			permute(f->perm, n, 1, x);
			if (!f->cholesky)
				d_apply(f, 0, 0, 1, x);
			tri_solve(f->L, 1, !f->cholesky, 1, f->hermitian, x, 0);
			permute(f->perm, n, 0, x);
			for (int k = 0; k < n; k++)
				x[k] *= sc ? sc[k] : 1;
		}
		break;
	}
	default:
		break;
	}
}

void subfactor_apply(const struct numeric *f, SparseSubfactor_t which, int transpose, int conjugate, int solve,
    const struct dense_view *in, const struct dense_view *out)
{
	int len = f->m > f->n ? f->m : f->n;
	int nrhs = dense_cols(out);
	int insize = dense_rows(in), outsize = dense_rows(out);
	V *x = malloc((size_t)(len ? len : 1) * sizeof *x);
	for (int r = 0; r < nrhs; r++) {
		for (int i = 0; i < len; i++)
			x[i] = i < insize ? dense_get(in, i, r) : 0;
		subfactor_one(f, which, transpose, conjugate, solve, x);
		for (int i = 0; i < outsize; i++)
			dense_put(out, i, r, fix(out->type, x[i]));
	}
	free(x);
}
