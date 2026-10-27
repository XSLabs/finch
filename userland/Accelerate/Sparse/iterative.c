/*
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Iterative methods, written for Finch: preconditioned conjugate gradients,
 * GMRES (restarted, with the flexible formulation serving all three variants;
 * DQGMRES restarts every nvec iterations rather than truncating) and LSMR
 * (Fong and Saunders), each as a single-step iteration over caller-held
 * state, which the solve functions drive with the documented convergence
 * tests. Vectors are double complex internally; the caller's operator and
 * preconditioner see their own scalar type.
 */
#include <Block.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "typed.h"

typedef void (^op_fn)(bool accumulate, enum CBLAS_TRANSPOSE trans, const V *x, int xlen, V *y, int ylen);
typedef void (^prec_fn)(enum CBLAS_TRANSPOSE trans, const V *x, V *y, int len);

enum { METHOD_CG = 0, METHOD_GMRES = 1, METHOD_LSMR = 2 };

static double epsilon(int type)
{
	return is_single(type) ? 1.1920928955078125e-07 : 2.220446049250313e-16;
}

static V dot(const V *a, const V *b, int n)
{
	V s = 0;
	for (int i = 0; i < n; i++)
		s += conj(a[i]) * b[i];
	return s;
}

static double norm2(const V *a, int n)
{
	double s = 0;
	for (int i = 0; i < n; i++)
		s += abs2(a[i]);
	return sqrt(s);
}

static void precondition(prec_fn P, enum CBLAS_TRANSPOSE trans, const V *x, V *y, int n)
{
	if (P)
		P(trans, x, y, n);
	else if (x != y)
		memcpy(y, x, (size_t)n * sizeof *y);
}

#pragma mark - State layout

/* Per right-hand side, a fixed block of V slots; scalars first. */
#define SCALARS 32

static int gmres_nvec(const SparseGMRESOptions *o)
{
	return o->nvec > 0 ? o->nvec : 16;
}

static size_t slots_per_rhs(int method, const SparseIterativeMethod *m, int rows, int cols)
{
	int n = cols > rows ? cols : rows;
	switch (method) {
	case METHOD_CG:
		return SCALARS + 4 * (size_t)n;
	case METHOD_GMRES: {
		int k = gmres_nvec(&m->options.gmres);
		return SCALARS + (size_t)(k + 1) * n + (size_t)k * n + (size_t)(k + 1) * k + 3 * (size_t)(k + 1) + 2 * (size_t)n;
	}
	default:
		return SCALARS + 6 * (size_t)n;
	}
}

size_t iterative_state_size(const SparseIterativeMethod *method, int m, int n, int nrhs)
{
	return 64 + (size_t)nrhs * slots_per_rhs(method->method, method, m, n) * sizeof(V);
}

static V *rhs_state(void *state, const SparseIterativeMethod *method, int m, int n, int j)
{
	return (V *)((char *)state + 64) + (size_t)j * slots_per_rhs(method->method, method, m, n);
}

#pragma mark - Conjugate gradients

/* Slots: 0 rho, 1 rnorm; vectors p, q, z, r. */
static void cg_step(int iteration, V *st, int n, const V *b, V *x, V *r, op_fn A, prec_fn P, int type)
{
	(void)type;
	(void)b;
	V *p = st + SCALARS, *q = p + n, *z = q + n, *res = z + n;
	if (iteration == 0) {
		memcpy(res, r, (size_t)n * sizeof *res);
		precondition(P, CblasNoTrans, res, z, n);
		memcpy(p, z, (size_t)n * sizeof *p);
		st[0] = dot(res, z, n);
	}
	A(false, CblasNoTrans, p, n, q, n);
	V pq = dot(p, q, n);
	V alpha = pq == 0 ? 0 : st[0] / pq;
	for (int i = 0; i < n; i++) {
		x[i] += alpha * p[i];
		res[i] -= alpha * q[i];
	}
	precondition(P, CblasNoTrans, res, z, n);
	V rho = dot(res, z, n);
	V beta = st[0] == 0 ? 0 : rho / st[0];
	st[0] = rho;
	for (int i = 0; i < n; i++)
		p[i] = z[i] + beta * p[i];
	st[1] = norm2(res, n);
	st[2] = pq == 0 ? 1 : 0; /* breakdown */
}

#pragma mark - GMRES

/*
 * Slots: 0 k (inner step), 1 beta, 2 residual estimate; then basis V
 * ((nvec+1) x n), preconditioned basis Z (nvec x n), Hessenberg H
 * ((nvec+1) x nvec, column-major), Givens c and s and the rotated g
 * (nvec+1 each), and the initial x and a scratch vector.
 */
struct gmres {
	int k, nvec, n;
	V *basis, *zbasis, *h, *c, *s, *g, *x0, *w;
};

static struct gmres gmres_layout(V *st, int n, int nvec)
{
	struct gmres g = {.k = (int)creal(st[0]), .nvec = nvec, .n = n};
	g.basis = st + SCALARS;
	g.zbasis = g.basis + (size_t)(nvec + 1) * n;
	g.h = g.zbasis + (size_t)nvec * n;
	g.c = g.h + (size_t)(nvec + 1) * nvec;
	g.s = g.c + nvec + 1;
	g.g = g.s + nvec + 1;
	g.x0 = g.g + nvec + 1;
	g.w = g.x0 + n;
	return g;
}

static void gmres_start(V *st, struct gmres *g, const V *r)
{
	double beta = norm2(r, g->n);
	for (int i = 0; i < g->n; i++)
		g->basis[i] = beta == 0 ? 0 : r[i] / beta;
	memset(g->g, 0, (size_t)(g->nvec + 1) * sizeof *g->g);
	g->g[0] = beta;
	g->k = 0;
	st[0] = 0;
	st[1] = beta;
	st[2] = beta;
}

/* x += Z y with H y = g over the first k steps. */
static void gmres_update(struct gmres *g, V *x)
{
	int k = g->k, nv = g->nvec;
	if (!k)
		return;
	V *y = calloc((size_t)k, sizeof *y);
	for (int i = k - 1; i >= 0; i--) {
		V s = g->g[i];
		for (int j = i + 1; j < k; j++)
			s -= g->h[(size_t)j * (nv + 1) + i] * y[j];
		V d = g->h[(size_t)i * (nv + 1) + i];
		y[i] = d == 0 ? 0 : s / d;
	}
	for (int j = 0; j < k; j++)
		for (int i = 0; i < g->n; i++)
			x[i] += g->zbasis[(size_t)j * g->n + i] * y[j];
	free(y);
}

static void residual(op_fn A, const V *b, const V *x, V *r, int m, int n)
{
	A(false, CblasNoTrans, x, n, r, m);
	for (int i = 0; i < m; i++)
		r[i] = b[i] - r[i];
}

static void gmres_step(int iteration, V *st, int n, int nvec, const V *b, V *x, V *r, op_fn A, prec_fn P)
{
	struct gmres g = gmres_layout(st, n, nvec);
	if (iteration == 0)
		gmres_start(st, &g, r);
	int k = g.k;
	V *vk = g.basis + (size_t)k * n, *zk = g.zbasis + (size_t)k * n, *w = g.w;
	precondition(P, CblasNoTrans, vk, zk, n);
	A(false, CblasNoTrans, zk, n, w, n);
	V *hk = g.h + (size_t)k * (nvec + 1);
	for (int i = 0; i <= k; i++) {
		V *vi = g.basis + (size_t)i * n;
		hk[i] = dot(vi, w, n);
		for (int q = 0; q < n; q++)
			w[q] -= hk[i] * vi[q];
	}
	double hn = norm2(w, n);
	hk[k + 1] = hn;
	V *vn = g.basis + (size_t)(k + 1) * n;
	for (int q = 0; q < n; q++)
		vn[q] = hn == 0 ? 0 : w[q] / hn;
	/* Apply the earlier rotations, then make one for this column. */
	for (int i = 0; i < k; i++) {
		V a = hk[i], b2 = hk[i + 1];
		hk[i] = conj(g.c[i]) * a + conj(g.s[i]) * b2;
		hk[i + 1] = -g.s[i] * a + g.c[i] * b2;
	}
	double denom = sqrt(abs2(hk[k]) + abs2(hk[k + 1]));
	V cs = denom == 0 ? 1 : hk[k] / denom, sn = denom == 0 ? 0 : hk[k + 1] / denom;
	g.c[k] = cs;
	g.s[k] = sn;
	hk[k] = denom;
	hk[k + 1] = 0;
	V gk = g.g[k];
	g.g[k] = conj(cs) * gk;
	g.g[k + 1] = -sn * gk;
	g.k = k + 1;
	st[0] = g.k;
	st[2] = sqrt(abs2(g.g[k + 1]));
	if (g.k == nvec) {
		/* Restart from the updated iterate and its true residual. */
		gmres_update(&g, x);
		residual(A, b, x, w, n, n);
		gmres_start(st, &g, w);
		st[2] = st[1];
	}
}

#pragma mark - LSMR

/*
 * Slots: scalars as in Fong and Saunders' LSMR; vectors u (m), v, h, hbar,
 * y (n; x = M y when preconditioned) and a scratch vector.
 */
enum {
	L_ALPHA, L_BETA, L_ZETABAR, L_ALPHABAR, L_RHO, L_RHOBAR, L_CBAR, L_SBAR, L_BETADD, L_BETAD,
	L_RHODOLD, L_TAUTILDEOLD, L_THETATILDE, L_ZETA, L_D, L_NORMA2, L_MAXRBAR, L_MINRBAR, L_NORMB,
	L_NORMAR, L_NORMR, L_NORMA, L_COND
};

static void lsmr_step(int iteration, V *st, int m, int n, double lambda, const V *b, V *x, V *r, op_fn A,
    prec_fn P)
{
	(void)b;
	int len = m > n ? m : n;
	V *u = st + SCALARS, *v = u + len, *h = v + len, *hbar = h + len, *y = hbar + len, *t = y + len;
	double *s = (double *)st; /* real scalars, two per slot */
	if (iteration == 0) {
		/* beta u = r; alpha v = M^H A^H u. */
		memcpy(u, r, (size_t)m * sizeof *u);
		double beta = norm2(u, m);
		for (int i = 0; i < m; i++)
			u[i] = beta == 0 ? 0 : u[i] / beta;
		A(false, CblasTrans, u, m, t, n);
		precondition(P, CblasTrans, t, v, n);
		double alpha = norm2(v, n);
		for (int i = 0; i < n; i++)
			v[i] = alpha == 0 ? 0 : v[i] / alpha;
		memset(y, 0, (size_t)n * sizeof *y);
		s[L_ALPHA] = alpha;
		s[L_BETA] = beta;
		s[L_ZETABAR] = alpha * beta;
		s[L_ALPHABAR] = alpha;
		s[L_RHO] = 1;
		s[L_RHOBAR] = 1;
		s[L_CBAR] = 1;
		s[L_SBAR] = 0;
		memcpy(h, v, (size_t)n * sizeof *h);
		memset(hbar, 0, (size_t)n * sizeof *hbar);
		s[L_BETADD] = beta;
		s[L_BETAD] = 0;
		s[L_RHODOLD] = 1;
		s[L_TAUTILDEOLD] = 0;
		s[L_THETATILDE] = 0;
		s[L_ZETA] = 0;
		s[L_D] = 0;
		s[L_NORMA2] = alpha * alpha;
		s[L_MAXRBAR] = 0;
		s[L_MINRBAR] = 1e100;
		s[L_NORMB] = beta;
		s[L_NORMAR] = alpha * beta;
		s[L_NORMR] = beta;
		/* The iteration builds a correction to x0, kept in the scratch vector. */
		memcpy(t, x, (size_t)n * sizeof *t);
	}
	double alpha = s[L_ALPHA], beta = s[L_BETA];
	/* Bidiagonalization step. */
	{
		V *Mv = calloc((size_t)n, sizeof *Mv), *Av = calloc((size_t)m, sizeof *Av);
		precondition(P, CblasNoTrans, v, Mv, n);
		A(false, CblasNoTrans, Mv, n, Av, m);
		for (int i = 0; i < m; i++)
			u[i] = Av[i] - alpha * u[i];
		beta = norm2(u, m);
		if (beta > 0) {
			for (int i = 0; i < m; i++)
				u[i] /= beta;
			V *Atu = calloc((size_t)n, sizeof *Atu), *MAtu = calloc((size_t)n, sizeof *MAtu);
			A(false, CblasTrans, u, m, Atu, n);
			precondition(P, CblasTrans, Atu, MAtu, n);
			for (int i = 0; i < n; i++)
				v[i] = MAtu[i] - beta * v[i];
			alpha = norm2(v, n);
			if (alpha > 0)
				for (int i = 0; i < n; i++)
					v[i] /= alpha;
			free(Atu);
			free(MAtu);
		}
		free(Mv);
		free(Av);
	}
	/* Rotations (with damping lambda). */
	double alphabar = s[L_ALPHABAR];
	double alphahat = sqrt(alphabar * alphabar + lambda * lambda);
	double chat = alphabar / alphahat, shat = lambda / alphahat;
	double rhoold = s[L_RHO];
	double rho = sqrt(alphahat * alphahat + beta * beta);
	double c = alphahat / rho, sn = beta / rho;
	double thetanew = sn * alpha;
	alphabar = c * alpha;
	double rhobarold = s[L_RHOBAR], zetaold = s[L_ZETA];
	double thetabar = s[L_SBAR] * rho;
	double rhotemp = s[L_CBAR] * rho;
	double rhobar = sqrt(rhotemp * rhotemp + thetanew * thetanew);
	double cbar = rhotemp / rhobar, sbar = thetanew / rhobar;
	double zeta = cbar * s[L_ZETABAR];
	double zetabar = -sbar * s[L_ZETABAR];
	/* Update h, hbar and y. */
	for (int i = 0; i < n; i++) {
		hbar[i] = h[i] - (thetabar * rho / (rhoold * rhobarold)) * hbar[i];
		y[i] += (zeta / (rho * rhobar)) * hbar[i];
		h[i] = v[i] - (thetanew / rho) * h[i];
	}
	/* Estimates of ||r|| and ||A^H r||. */
	double betaacute = chat * s[L_BETADD], betacheck = -shat * s[L_BETADD];
	double betahat = c * betaacute;
	double betadd = -sn * betaacute;
	double thetatildeold = s[L_THETATILDE];
	double rhotildeold = sqrt(s[L_RHODOLD] * s[L_RHODOLD] + thetabar * thetabar);
	double ctildeold = s[L_RHODOLD] / rhotildeold, stildeold = thetabar / rhotildeold;
	double thetatilde = stildeold * rhobar;
	double rhodold = ctildeold * rhobar;
	double betad = -stildeold * s[L_BETAD] + ctildeold * betahat;
	double tautildeold = (zetaold - thetatildeold * s[L_TAUTILDEOLD]) / rhotildeold;
	double taud = (zeta - thetatilde * tautildeold) / rhodold;
	double d = s[L_D] + betacheck * betacheck;
	double normr = sqrt(d + (betad - taud) * (betad - taud) + betadd * betadd);
	double normA2 = s[L_NORMA2] + beta * beta;
	double normA = sqrt(normA2);
	normA2 += alpha * alpha;
	double maxrbar = rhobarold > s[L_MAXRBAR] ? rhobarold : s[L_MAXRBAR];
	double minrbar = iteration > 0 && rhobarold < s[L_MINRBAR] ? rhobarold : s[L_MINRBAR];
	double condA = maxrbar / (rhotemp < minrbar ? rhotemp : minrbar);
	double normar = fabs(zetabar);
	s[L_ALPHA] = alpha;
	s[L_BETA] = beta;
	s[L_ZETABAR] = zetabar;
	s[L_ALPHABAR] = alphabar;
	s[L_RHO] = rho;
	s[L_RHOBAR] = rhobar;
	s[L_CBAR] = cbar;
	s[L_SBAR] = sbar;
	s[L_BETADD] = betadd;
	s[L_BETAD] = betad;
	s[L_RHODOLD] = rhodold;
	s[L_TAUTILDEOLD] = tautildeold;
	s[L_THETATILDE] = thetatilde;
	s[L_ZETA] = zeta;
	s[L_D] = d;
	s[L_NORMA2] = normA2;
	s[L_MAXRBAR] = maxrbar;
	s[L_MINRBAR] = minrbar;
	s[L_NORMAR] = normar;
	s[L_NORMR] = normr;
	s[L_NORMA] = normA;
	s[L_COND] = condA;
	/* x = x0 + M y. */
	V *My = calloc((size_t)n, sizeof *My);
	precondition(P, CblasNoTrans, y, My, n);
	for (int i = 0; i < n; i++)
		x[i] = t[i] + My[i];
	free(My);
}

#pragma mark - Driving

struct problem {
	int type;
	int m, n, nrhs;
	op_fn A;
	prec_fn P;
};

/* One iteration over every unconverged column; x, b, r are column-major arrays. */
static void iterate(const SparseIterativeMethod *method, const struct problem *pr, int iteration, void *state,
    const bool *converged, V *x, const V *b, V *r, int rstride)
{
	int m = pr->m, n = pr->n;
	for (int j = 0; j < pr->nrhs; j++) {
		if (converged && converged[j])
			continue;
		V *st = rhs_state(state, method, m, n, j);
		V *xj = x + (size_t)j * n, *rj = r + (size_t)j * rstride;
		const V *bj = b + (size_t)j * m;
		if (iteration < 0) {
			if (method->method == METHOD_GMRES) {
				struct gmres g = gmres_layout(st, n, gmres_nvec(&method->options.gmres));
				gmres_update(&g, xj);
				V *w = calloc((size_t)m, sizeof *w);
				residual(pr->A, bj, xj, w, m, n);
				gmres_start(st, &g, w);
				free(w);
			}
			residual(pr->A, bj, xj, rj, m, n);
			continue;
		}
		switch (method->method) {
		case METHOD_CG:
			cg_step(iteration, st, n, bj, xj, rj, pr->A, pr->P, pr->type);
			rj[0] = st[1];
			break;
		case METHOD_GMRES:
			gmres_step(iteration, st, n, gmres_nvec(&method->options.gmres), bj, xj, rj, pr->A, pr->P);
			rj[0] = st[2];
			break;
		default: {
			const SparseLSMROptions *o = &method->options.lsmr;
			lsmr_step(iteration, st, m, n, o->lambda, bj, xj, rj, pr->A, pr->P);
			double *s = (double *)st;
			rj[0] = s[L_NORMAR];
			if (rstride > 1)
				rj[1] = s[L_NORMR];
			if (rstride > 2)
				rj[2] = s[L_NORMA];
			if (rstride > 3)
				rj[3] = s[L_COND];
			break;
		}
		}
	}
}

static void report(void (*status)(const char *), int iteration, double value)
{
	if (!status)
		return;
	char line[128];
	snprintf(line, sizeof line, "%8d %12.4e\n", iteration, value);
	status(line);
}

static SparseIterativeStatus_t solve(const SparseIterativeMethod *method, const struct problem *pr, V *x,
    const V *b)
{
	int m = pr->m, n = pr->n, nrhs = pr->nrhs;
	double eps = epsilon(pr->type);
	int maxit;
	double atol, rtol;
	void (*status)(const char *);
	switch (method->method) {
	case METHOD_CG:
		maxit = method->options.cg.maxIterations > 0 ? method->options.cg.maxIterations : 100;
		atol = method->options.cg.atol;
		rtol = method->options.cg.rtol;
		status = method->options.cg.reportStatus;
		break;
	case METHOD_GMRES:
		maxit = method->options.gmres.maxIterations > 0 ? method->options.gmres.maxIterations : 100;
		atol = method->options.gmres.atol;
		rtol = method->options.gmres.rtol;
		status = method->options.gmres.reportStatus;
		break;
	default:
		maxit = method->options.lsmr.maxIterations > 0 ? method->options.lsmr.maxIterations : 4 * n;
		atol = method->options.lsmr.atol;
		rtol = method->options.lsmr.rtol;
		status = method->options.lsmr.reportStatus;
		break;
	}
	if (rtol == 0)
		rtol = sqrt(eps);
	else if (rtol < 0)
		rtol = 0;
	int fong = method->method == METHOD_LSMR && method->options.lsmr.convergenceTest == SparseLSMRCTFongSaunders;
	double btol = 0, conlim = 0;
	if (fong) {
		if (atol == 0)
			atol = eps;
		btol = method->options.lsmr.btol ? method->options.lsmr.btol : eps;
		conlim = method->options.lsmr.conditionLimit ? method->options.lsmr.conditionLimit : 1 / eps;
	}
	if (method->method == METHOD_GMRES && method->options.gmres.variant == SparseVariantFGMRES && !pr->P) {
		sparse_report(method->options.base.reportError,
		    "FGMRES requires a preconditioner.\nIf no preconditioner is available, use GMRES or DQGMRES instead.\n");
		return SparseIterativeParameterError;
	}
	int rstride = m > 4 ? m : 4;
	if (rstride < n)
		rstride = n;
	size_t size = iterative_state_size(method, m, n, nrhs);
	void *state = calloc(1, size);
	V *r = calloc((size_t)rstride * nrhs, sizeof *r);
	bool *converged = calloc((size_t)nrhs, sizeof *converged);
	double *target = calloc((size_t)nrhs, sizeof *target), *bnorm = calloc((size_t)nrhs, sizeof *bnorm);
	for (int j = 0; j < nrhs; j++) {
		V *rj = r + (size_t)j * rstride;
		residual(pr->A, b + (size_t)j * m, x + (size_t)j * n, rj, m, n);
		bnorm[j] = norm2(b + (size_t)j * m, m);
		if (method->method == METHOD_LSMR) {
			/* The default LSMR test is relative to ||A^H r0||. */
			V *atr = calloc((size_t)n, sizeof *atr);
			pr->A(false, CblasTrans, rj, m, atr, n);
			target[j] = norm2(atr, n);
			free(atr);
		} else {
			target[j] = norm2(rj, m);
		}
		if (target[j] == 0)
			converged[j] = true;
	}
	SparseIterativeStatus_t result = SparseIterativeMaxIterations;
	int done = 1;
	for (int j = 0; j < nrhs; j++)
		done &= converged[j];
	for (int it = 0; it < maxit && !done; it++) {
		iterate(method, pr, it, state, converged, x, b, r, rstride);
		done = 1;
		for (int j = 0; j < nrhs; j++) {
			if (converged[j])
				continue;
			V *st = rhs_state(state, method, m, n, j);
			double value = creal(r[(size_t)j * rstride]);
			int ok;
			if (fong) {
				double *s = (double *)st;
				double xnorm = norm2(x + (size_t)j * n, n);
				ok = s[L_NORMR] <= btol * bnorm[j] + atol * s[L_NORMA] * xnorm ||
				     s[L_NORMAR] <= atol * s[L_NORMA] * s[L_NORMR] || s[L_COND] >= conlim;
			} else {
				ok = value < rtol * target[j] + atol;
			}
			if (method->method == METHOD_CG && creal(st[2]) != 0 && !ok) {
				result = SparseIterativeIllConditioned;
				ok = 1;
			}
			if (ok)
				converged[j] = true;
			else
				done = 0;
			if (j == 0)
				report(status, it, value);
		}
	}
	if (done && result != SparseIterativeIllConditioned)
		result = SparseIterativeConverged;
	if (result == SparseIterativeMaxIterations)
		sparse_report(method->options.base.reportError, "Exceeded maximum iteration limit.\n");
	/* Bring X up to date. */
	memset(converged, 0, (size_t)nrhs * sizeof *converged);
	if (method->method == METHOD_GMRES)
		iterate(method, pr, -1, state, converged, x, b, r, rstride);
	free(state);
	free(r);
	free(converged);
	free(target);
	free(bnorm);
	return result;
}

#pragma mark - Typed entry points

#define DEFINE_ITERATIVE(S, ID, T)                                                                             \
	static op_fn op_##S(void (^ApplyOperator)(bool, enum CBLAS_TRANSPOSE, DenseMatrix_##S, DenseMatrix_##S)) \
	{                                                                                                       \
		return Block_copy(^(bool accumulate, enum CBLAS_TRANSPOSE trans, const V *x, int xlen, V *y, int ylen) { \
			T *tx = malloc((size_t)(xlen ? xlen : 1) * sizeof *tx), *ty = malloc((size_t)(ylen ? ylen : 1) * sizeof *ty); \
			for (int i = 0; i < xlen; i++)                                                          \
				store(ID, tx, i, x[i]);                                                         \
			for (int i = 0; i < ylen; i++)                                                          \
				store(ID, ty, i, accumulate ? y[i] : 0);                                        \
			DenseMatrix_##S X = {.rowCount = xlen, .columnCount = 1, .columnStride = xlen, .data = tx}; \
			DenseMatrix_##S Y = {.rowCount = ylen, .columnCount = 1, .columnStride = ylen, .data = ty}; \
			ApplyOperator(accumulate, trans == CblasNoTrans ? CblasNoTrans : CblasTrans, X, Y);     \
			for (int i = 0; i < ylen; i++)                                                          \
				y[i] = load(ID, ty, i);                                                         \
			free(tx);                                                                               \
			free(ty);                                                                               \
		});                                                                                             \
	}                                                                                                       \
	static prec_fn prec_##S(const SparseOpaquePreconditioner_##S *P)                                       \
	{                                                                                                       \
		if (!P || P->type == SparsePreconditionerNone || !P->apply)                                    \
			return NULL;                                                                            \
		SparseOpaquePreconditioner_##S p = *P;                                                          \
		return Block_copy(^(enum CBLAS_TRANSPOSE trans, const V *x, V *y, int len) {                    \
			T *tx = malloc((size_t)(len ? len : 1) * sizeof *tx), *ty = calloc((size_t)(len ? len : 1), sizeof *ty); \
			for (int i = 0; i < len; i++)                                                           \
				store(ID, tx, i, x[i]);                                                         \
			DenseMatrix_##S X = {.rowCount = len, .columnCount = 1, .columnStride = len, .data = tx}; \
			DenseMatrix_##S Y = {.rowCount = len, .columnCount = 1, .columnStride = len, .data = ty}; \
			p.apply(p.mem, trans, X, Y);                                                            \
			for (int i = 0; i < len; i++)                                                           \
				y[i] = load(ID, ty, i);                                                         \
			free(tx);                                                                               \
			free(ty);                                                                               \
		});                                                                                             \
	}                                                                                                       \
	/* Columns of a dense matrix as a V array (column-major, rows each). */                                 \
	static V *gather_##S(const DenseMatrix_##S *M, int rows, int cols)                                     \
	{                                                                                                       \
		struct dense_view v = dense_##S(M);                                                             \
		V *out = calloc((size_t)(rows * cols ? rows * cols : 1), sizeof *out);                          \
		for (int j = 0; j < cols; j++)                                                                  \
			for (int i = 0; i < rows && i < dense_rows(&v); i++)                                    \
				out[(size_t)j * rows + i] = dense_get(&v, i, j);                                \
		return out;                                                                                     \
	}                                                                                                       \
	static void scatter_##S(const DenseMatrix_##S *M, const V *in, int rows, int cols)                     \
	{                                                                                                       \
		struct dense_view v = dense_##S(M);                                                             \
		for (int j = 0; j < cols; j++)                                                                  \
			for (int i = 0; i < rows && i < dense_rows(&v); i++)                                    \
				dense_put(&v, i, j, fix(ID, in[(size_t)j * rows + i]));                         \
	}                                                                                                       \
	static SparseIterativeStatus_t solve_##S(int kind, const void *opts, DenseMatrix_##S *X, DenseMatrix_##S *B, \
	    void (^ApplyOperator)(bool, enum CBLAS_TRANSPOSE, DenseMatrix_##S, DenseMatrix_##S),                \
	    const SparseOpaquePreconditioner_##S *Preconditioner)                                               \
	{                                                                                                       \
		SparseIterativeMethod method = {.method = kind};                                                \
		memcpy(&method.options, opts,                                                                   \
		    kind == METHOD_CG ? sizeof(SparseCGOptions)                                                 \
		                      : kind == METHOD_GMRES ? sizeof(SparseGMRESOptions) : sizeof(SparseLSMROptions)); \
		struct dense_view xv = dense_##S(X), bv = dense_##S(B);                                         \
		struct problem pr = {.type = ID, .m = dense_rows(&bv), .n = dense_rows(&xv), .nrhs = dense_cols(&xv), \
		    .A = op_##S(ApplyOperator), .P = prec_##S(Preconditioner)};                                 \
		V *x = gather_##S(X, pr.n, pr.nrhs), *b = gather_##S(B, pr.m, pr.nrhs);                        \
		SparseIterativeStatus_t st = solve(&method, &pr, x, b);                                         \
		Block_release(pr.A);                                                                            \
		if (pr.P)                                                                                       \
			Block_release(pr.P);                                                                    \
		scatter_##S(X, x, pr.n, pr.nrhs);                                                               \
		free(x);                                                                                        \
		free(b);                                                                                        \
		return st;                                                                                      \
	}                                                                                                       \
	SparseIterativeStatus_t _SparseCGSolve_##S(const SparseCGOptions *options, DenseMatrix_##S *X,         \
	    DenseMatrix_##S *B, void (^ApplyOperator)(bool, enum CBLAS_TRANSPOSE, DenseMatrix_##S, DenseMatrix_##S), \
	    const SparseOpaquePreconditioner_##S *Preconditioner)                                               \
	{                                                                                                       \
		return solve_##S(METHOD_CG, options, X, B, ApplyOperator, Preconditioner);                      \
	}                                                                                                       \
	SparseIterativeStatus_t _SparseGMRESSolve_##S(SparseGMRESOptions *options, DenseMatrix_##S *X,         \
	    DenseMatrix_##S *B, void (^ApplyOperator)(bool, enum CBLAS_TRANSPOSE, DenseMatrix_##S, DenseMatrix_##S), \
	    const SparseOpaquePreconditioner_##S *Preconditioner)                                               \
	{                                                                                                       \
		return solve_##S(METHOD_GMRES, options, X, B, ApplyOperator, Preconditioner);                   \
	}                                                                                                       \
	SparseIterativeStatus_t _SparseLSMRSolve_##S(SparseLSMROptions *options, DenseMatrix_##S *X,           \
	    DenseMatrix_##S *B, void (^ApplyOperator)(bool, enum CBLAS_TRANSPOSE, DenseMatrix_##S, DenseMatrix_##S), \
	    const SparseOpaquePreconditioner_##S *Preconditioner)                                               \
	{                                                                                                       \
		return solve_##S(METHOD_LSMR, options, X, B, ApplyOperator, Preconditioner);                    \
	}                                                                                                       \
	static void iterate_##S(int kind, const void *opts, int iteration, char *state, const bool *converged, \
	    DenseMatrix_##S *X, DenseMatrix_##S *B, DenseMatrix_##S *R,                                         \
	    const SparseOpaquePreconditioner_##S *Preconditioner,                                               \
	    void (^ApplyOperator)(bool, enum CBLAS_TRANSPOSE, DenseMatrix_##S, DenseMatrix_##S))                \
	{                                                                                                       \
		SparseIterativeMethod method = {.method = kind};                                                \
		memcpy(&method.options, opts,                                                                   \
		    kind == METHOD_CG ? sizeof(SparseCGOptions)                                                 \
		                      : kind == METHOD_GMRES ? sizeof(SparseGMRESOptions) : sizeof(SparseLSMROptions)); \
		struct dense_view xv = dense_##S(X), bv = dense_##S(B), rv = dense_##S(R);                      \
		struct problem pr = {.type = ID, .m = dense_rows(&bv), .n = dense_rows(&xv), .nrhs = dense_cols(&xv), \
		    .A = op_##S(ApplyOperator), .P = prec_##S(Preconditioner)};                                 \
		int rrows = dense_rows(&rv);                                                                    \
		V *x = gather_##S(X, pr.n, pr.nrhs), *b = gather_##S(B, pr.m, pr.nrhs), *r = gather_##S(R, rrows, pr.nrhs); \
		iterate(&method, &pr, iteration, state, converged, x, b, r, rrows);                             \
		Block_release(pr.A);                                                                            \
		if (pr.P)                                                                                       \
			Block_release(pr.P);                                                                    \
		scatter_##S(X, x, pr.n, pr.nrhs);                                                               \
		scatter_##S(R, r, rrows, pr.nrhs);                                                              \
		free(x);                                                                                        \
		free(b);                                                                                        \
		free(r);                                                                                        \
	}                                                                                                       \
	void _SparseCGIterate_##S(const SparseCGOptions *options, int iteration, char *state, const bool *converged, \
	    DenseMatrix_##S *X, DenseMatrix_##S *B, DenseMatrix_##S *R,                                         \
	    const SparseOpaquePreconditioner_##S *Preconditioner,                                               \
	    void (^ApplyOperator)(bool, enum CBLAS_TRANSPOSE, DenseMatrix_##S, DenseMatrix_##S))                \
	{                                                                                                       \
		iterate_##S(METHOD_CG, options, iteration, state, converged, X, B, R, Preconditioner, ApplyOperator); \
	}                                                                                                       \
	void _SparseGMRESIterate_##S(const SparseGMRESOptions *options, int iteration, char *state,            \
	    const bool *converged, DenseMatrix_##S *X, DenseMatrix_##S *B, DenseMatrix_##S *R,                  \
	    const SparseOpaquePreconditioner_##S *Preconditioner,                                               \
	    void (^ApplyOperator)(bool, enum CBLAS_TRANSPOSE, DenseMatrix_##S, DenseMatrix_##S))                \
	{                                                                                                       \
		iterate_##S(METHOD_GMRES, options, iteration, state, converged, X, B, R, Preconditioner, ApplyOperator); \
	}                                                                                                       \
	void _SparseLSMRIterate_##S(const SparseLSMROptions *options, int iteration, char *state,              \
	    const bool *converged, DenseMatrix_##S *X, DenseMatrix_##S *B, DenseMatrix_##S *R,                  \
	    const SparseOpaquePreconditioner_##S *Preconditioner,                                               \
	    void (^ApplyOperator)(bool, enum CBLAS_TRANSPOSE, DenseMatrix_##S, DenseMatrix_##S))                \
	{                                                                                                       \
		iterate_##S(METHOD_LSMR, options, iteration, state, converged, X, B, R, Preconditioner, ApplyOperator); \
	}                                                                                                       \
	size_t _SparseGetIterativeStateSize_##S(const SparseIterativeMethod *method, bool preconditioner, int m, \
	    int n, int nrhs)                                                                                    \
	{                                                                                                       \
		(void)preconditioner;                                                                           \
		return iterative_state_size(method, m, n, nrhs);                                                \
	}                                                                                                       \
                                                                                                                \
	/* Preconditioners: y = D^-1 x with D the diagonal, or the column 2-norms. */                           \
	struct diagonal_##S {                                                                                   \
		int n;                                                                                          \
		V *d;                                                                                           \
	};                                                                                                      \
	static void apply_diagonal_##S(void *mem, enum CBLAS_TRANSPOSE trans, DenseMatrix_##S X, DenseMatrix_##S Y) \
	{                                                                                                       \
		struct diagonal_##S *p = mem;                                                                   \
		struct dense_view xv = dense_##S(&X), yv = dense_##S(&Y);                                       \
		for (int j = 0; j < dense_cols(&xv); j++)                                                       \
			for (int i = 0; i < p->n && i < dense_rows(&xv); i++) {                                 \
				V d = trans == CblasConjTrans ? conj(p->d[i]) : p->d[i];                        \
				dense_put(&yv, i, j, fix(ID, d == 0 ? dense_get(&xv, i, j) : dense_get(&xv, i, j) / d)); \
			}                                                                                       \
	}                                                                                                       \
	SparseOpaquePreconditioner_##S _SparseCreatePreconditioner_##S(SparsePreconditioner_t type, SparseMatrix_##S *A) \
	{                                                                                                       \
		SparseOpaquePreconditioner_##S out = {.type = SparsePreconditionerNone};                        \
		if (type != SparsePreconditionerDiagonal && type != SparsePreconditionerDiagScaling)            \
			return out;                                                                             \
		struct matrix_view v = view_##S(A);                                                             \
		struct csc *C = csc_from_view(&v);                                                              \
		struct diagonal_##S *p = malloc(sizeof *p);                                                     \
		p->n = C->n;                                                                                    \
		p->d = calloc((size_t)(C->n ? C->n : 1), sizeof *p->d);                                         \
		for (int j = 0; j < C->n; j++)                                                                  \
			for (long k = C->p[j]; k < C->p[j + 1]; k++) {                                          \
				if (type == SparsePreconditionerDiagonal && C->i[k] == j)                       \
					p->d[j] = C->x[k];                                                      \
				else if (type == SparsePreconditionerDiagScaling)                               \
					p->d[j] += abs2(C->x[k]);                                               \
			}                                                                                       \
		if (type == SparsePreconditionerDiagScaling)                                                    \
			for (int j = 0; j < C->n; j++)                                                          \
				p->d[j] = sqrt(creal(p->d[j]));                                                 \
		csc_free(C);                                                                                    \
		out.type = type;                                                                                \
		out.mem = p;                                                                                    \
		out.apply = apply_diagonal_##S;                                                                 \
		return out;                                                                                     \
	}                                                                                                       \
	void _SparseReleaseOpaquePreconditioner_##S(SparseOpaquePreconditioner_##S *toFree)                    \
	{                                                                                                       \
		struct diagonal_##S *p = toFree->mem;                                                           \
		if (p) {                                                                                        \
			free(p->d);                                                                             \
			free(p);                                                                                \
		}                                                                                               \
		toFree->mem = NULL;                                                                             \
		toFree->type = SparsePreconditionerNone;                                                        \
	}

FOR_EACH_TYPE(DEFINE_ITERATIVE)
