/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_LA_INTERNAL_H
#define FINCH_LA_INTERNAL_H

#include <stddef.h>

typedef void (*la_dealloc_fn)(void *);

/*
 * One object: a matrix, a splat or an error. Results are lazy, as on macOS:
 * argument errors are found when an object is made, its elements (and a
 * singular solve) only when something reads them. Elements are kept as
 * doubles; float objects round every result to float.
 */
struct la_s {
	const void *isa; /* os_object header */
	int volatile ref_cnt, xref_cnt;
	int kind;          /* LA_KIND_* */
	unsigned type;     /* LA_SCALAR_TYPE_*, 0 for errors */
	long status;
	unsigned long attributes;
	unsigned long rows, cols;
	int evaluated;
	double *v;    /* rows x cols, row-major, once evaluated */
	double value; /* splat value, once evaluated */
	int op;       /* how to evaluate */
	struct la_s *a, *b;
	double scalar;
	long p[4];
	void *buffer; /* nocopy buffer handed back to the deallocator */
	la_dealloc_fn deallocator;
};

enum { LA_KIND_ERROR, LA_KIND_MATRIX, LA_KIND_SPLAT };

struct la_s *la_object_alloc(void);
void la_object_dispose(struct la_s *o);

#endif
