/*
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Fill-reducing orderings: minimum degree on the graph of A + A' (AMD) or of
 * A'A (COLAMD), eliminating one node at a time on explicit adjacency sets.
 * Ties go to the lowest index, so orderings are deterministic.
 */
#include <stdlib.h>
#include <string.h>

#include "internal.h"

struct set {
	int n, cap;
	int *v;
};

static void set_add(struct set *s, int x)
{
	int lo = 0, hi = s->n;
	while (lo < hi) {
		int mid = (lo + hi) / 2;
		if (s->v[mid] < x)
			lo = mid + 1;
		else
			hi = mid;
	}
	if (lo < s->n && s->v[lo] == x)
		return;
	if (s->n == s->cap) {
		s->cap = s->cap ? s->cap * 2 : 4;
		s->v = realloc(s->v, (size_t)s->cap * sizeof *s->v);
	}
	memmove(s->v + lo + 1, s->v + lo, (size_t)(s->n - lo) * sizeof *s->v);
	s->v[lo] = x;
	s->n++;
}

static void set_remove(struct set *s, int x)
{
	int lo = 0, hi = s->n;
	while (lo < hi) {
		int mid = (lo + hi) / 2;
		if (s->v[mid] < x)
			lo = mid + 1;
		else
			hi = mid;
	}
	if (lo < s->n && s->v[lo] == x) {
		memmove(s->v + lo, s->v + lo + 1, (size_t)(s->n - lo - 1) * sizeof *s->v);
		s->n--;
	}
}

/* Merge b into a, leaving out skip. */
static void set_union(struct set *a, const struct set *b, int skip)
{
	int *out = malloc((size_t)(a->n + b->n + 1) * sizeof *out);
	int i = 0, j = 0, k = 0;
	while (i < a->n || j < b->n) {
		int x;
		if (j >= b->n || (i < a->n && a->v[i] < b->v[j]))
			x = a->v[i++];
		else if (i >= a->n || b->v[j] < a->v[i])
			x = b->v[j++];
		else {
			x = a->v[i++];
			j++;
		}
		if (x != skip)
			out[k++] = x;
	}
	free(a->v);
	a->v = out;
	a->n = k;
	a->cap = a->n + b->n + 1;
}

/* Minimum degree over a symmetric adjacency (no self loops). */
static int *minimum_degree(struct set *adj, int n)
{
	int *perm = malloc((size_t)(n ? n : 1) * sizeof *perm);
	char *done = calloc((size_t)(n ? n : 1), 1);
	for (int step = 0; step < n; step++) {
		int best = -1;
		for (int v = 0; v < n; v++)
			if (!done[v] && (best < 0 || adj[v].n < adj[best].n))
				best = v;
		perm[step] = best;
		done[best] = 1;
		struct set nb = adj[best];
		for (int k = 0; k < nb.n; k++) {
			int u = nb.v[k];
			set_remove(&adj[u], best);
			set_union(&adj[u], &nb, u);
		}
		free(adj[best].v);
		adj[best] = (struct set){0};
	}
	free(done);
	return perm;
}

int *order_amd(const struct csc *A)
{
	int n = A->n;
	struct set *adj = calloc((size_t)(n ? n : 1), sizeof *adj);
	for (int j = 0; j < n; j++)
		for (long k = A->p[j]; k < A->p[j + 1]; k++) {
			int i = A->i[k];
			if (i != j && i < n) {
				set_add(&adj[i], j);
				set_add(&adj[j], i);
			}
		}
	int *perm = minimum_degree(adj, n);
	for (int v = 0; v < n; v++)
		free(adj[v].v);
	free(adj);
	return perm;
}

int *order_colamd(const struct csc *A)
{
	int n = A->n;
	struct csc *T = csc_transpose(A, 0);
	struct set *adj = calloc((size_t)(n ? n : 1), sizeof *adj);
	/* Columns sharing a row are adjacent in A'A. */
	for (int r = 0; r < T->n; r++)
		for (long a = T->p[r]; a < T->p[r + 1]; a++)
			for (long b = T->p[r]; b < T->p[r + 1]; b++)
				if (T->i[a] != T->i[b])
					set_add(&adj[T->i[a]], T->i[b]);
	csc_free(T);
	int *perm = minimum_degree(adj, n);
	for (int v = 0; v < n; v++)
		free(adj[v].v);
	free(adj);
	return perm;
}
