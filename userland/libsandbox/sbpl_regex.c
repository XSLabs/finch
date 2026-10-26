/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * SBPL regexes (POSIX extended syntax) compiled to FSB1 regex programs for the
 * Pike-VM matcher in kernel/sandbox/fsb_eval.c: alternation, grouping, the
 * * + ? {m,n} quantifiers, ., bracket expressions with ranges and [:class:]
 * names, ^ and $ anchors, and backslash escapes.
 */
#include "sbpl.h"
#include "fsb_format.h"

#include <ctype.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { RX_LIT, RX_ANY, RX_CLASS, RX_CAT, RX_ALT, RX_REPEAT, RX_BOL, RX_EOL, RX_EMPTY };

struct rx_node {
	int kind;
	int c;			/* RX_LIT */
	uint32_t set[8];	/* RX_CLASS */
	struct rx_node *a, *b;	/* RX_CAT, RX_ALT; RX_REPEAT uses a */
	int min, max;		/* RX_REPEAT; max -1: unbounded */
};

struct rx_parser {
	const char *s;
	size_t n, i;
	char *error;
	struct rx_node **all;
	size_t count, cap;
	int depth;
};

static void
rx_fail(struct rx_parser *p, const char *fmt, ...)
{
	if (p->error) {
		return;
	}
	va_list ap;
	va_start(ap, fmt);
	char *msg = NULL;
	if (vasprintf(&msg, fmt, ap) < 0) {
		msg = NULL;
	}
	va_end(ap);
	if (msg && asprintf(&p->error, "regex \"%.*s\": %s", (int)p->n, p->s, msg) < 0) {
		p->error = NULL;
	}
	free(msg);
	if (!p->error) {
		p->error = strdup("regex: out of memory");
	}
}

static struct rx_node *
rx_new(struct rx_parser *p, int kind)
{
	if (p->count == p->cap) {
		size_t cap = p->cap ? p->cap * 2 : 32;
		struct rx_node **all = realloc(p->all, cap * sizeof(*all));
		if (!all) {
			rx_fail(p, "out of memory");
			return NULL;
		}
		p->all = all;
		p->cap = cap;
	}
	struct rx_node *n = calloc(1, sizeof(*n));
	if (!n) {
		rx_fail(p, "out of memory");
		return NULL;
	}
	n->kind = kind;
	p->all[p->count++] = n;
	return n;
}

static void
set_bit(uint32_t set[8], int c)
{
	set[(c & 0xff) >> 5] |= 1u << (c & 31);
}

static bool
class_name(struct rx_parser *p, uint32_t set[8])
{
	/* at "[:", inside a bracket expression */
	static const struct {
		const char *name;
		int (*test)(int);
	} classes[] = {
		{ "alpha", isalpha }, { "digit", isdigit }, { "alnum", isalnum },
		{ "upper", isupper }, { "lower", islower }, { "space", isspace },
		{ "xdigit", isxdigit }, { "punct", ispunct }, { "print", isprint },
		{ "graph", isgraph }, { "cntrl", iscntrl }, { "blank", isblank },
	};
	size_t start = p->i + 2, end = start;
	while (end + 1 < p->n && !(p->s[end] == ':' && p->s[end + 1] == ']')) {
		end++;
	}
	if (end + 1 >= p->n) {
		rx_fail(p, "unterminated character class name");
		return false;
	}
	for (size_t k = 0; k < sizeof(classes) / sizeof(classes[0]); k++) {
		if (strlen(classes[k].name) == end - start &&
		    memcmp(classes[k].name, p->s + start, end - start) == 0) {
			for (int c = 0; c < 128; c++) {
				if (classes[k].test(c)) {
					set_bit(set, c);
				}
			}
			p->i = end + 2;
			return true;
		}
	}
	rx_fail(p, "unknown character class [:%.*s:]", (int)(end - start), p->s + start);
	return false;
}

static struct rx_node *
rx_bracket(struct rx_parser *p)
{
	struct rx_node *n = rx_new(p, RX_CLASS);
	bool negate = false, first = true;

	if (!n) {
		return NULL;
	}
	p->i++;		/* '[' */
	if (p->i < p->n && p->s[p->i] == '^') {
		negate = true;
		p->i++;
	}
	for (;;) {
		if (p->i >= p->n) {
			rx_fail(p, "unterminated bracket expression");
			return NULL;
		}
		int c = (unsigned char)p->s[p->i];
		if (c == ']' && !first) {
			p->i++;
			break;
		}
		first = false;
		if (c == '[' && p->i + 1 < p->n && p->s[p->i + 1] == ':') {
			if (!class_name(p, n->set)) {
				return NULL;
			}
			continue;
		}
		if (c == '\\' && p->i + 1 < p->n) {
			/* macOS's sandbox regexes take backslash escapes in brackets too */
			p->i++;
			c = (unsigned char)p->s[p->i];
		}
		p->i++;
		if (p->i + 1 < p->n && p->s[p->i] == '-' && p->s[p->i + 1] != ']') {
			int hi = (unsigned char)p->s[p->i + 1];
			p->i += 2;
			if (hi == '\\' && p->i < p->n) {
				hi = (unsigned char)p->s[p->i++];
			}
			if (hi < c) {
				rx_fail(p, "bad range %c-%c", c, hi);
				return NULL;
			}
			for (int k = c; k <= hi; k++) {
				set_bit(n->set, k);
			}
		} else {
			set_bit(n->set, c);
		}
	}
	if (negate) {
		for (int k = 0; k < 8; k++) {
			n->set[k] = ~n->set[k];
		}
	}
	return n;
}

static struct rx_node *rx_alt(struct rx_parser *p);

static struct rx_node *
rx_atom(struct rx_parser *p)
{
	int c = (unsigned char)p->s[p->i];
	struct rx_node *n;

	switch (c) {
	case '(':
		if (++p->depth > 200) {
			rx_fail(p, "nested too deeply");
			return NULL;
		}
		p->i++;
		n = rx_alt(p);
		if (!n) {
			return NULL;
		}
		if (p->i >= p->n || p->s[p->i] != ')') {
			rx_fail(p, "missing )");
			return NULL;
		}
		p->i++;
		p->depth--;
		return n;
	case '[':
		return rx_bracket(p);
	case '.':
		p->i++;
		return rx_new(p, RX_ANY);
	case '^':
		p->i++;
		return rx_new(p, RX_BOL);
	case '$':
		p->i++;
		return rx_new(p, RX_EOL);
	case '\\':
		if (p->i + 1 >= p->n) {
			rx_fail(p, "trailing backslash");
			return NULL;
		}
		p->i++;
		c = (unsigned char)p->s[p->i];
		break;
	default:
		break;
	}
	p->i++;
	n = rx_new(p, RX_LIT);
	if (n) {
		n->c = c;
	}
	return n;
}

static bool
rx_number(struct rx_parser *p, int *out)
{
	int v = 0;
	size_t start = p->i;
	while (p->i < p->n && isdigit((unsigned char)p->s[p->i])) {
		v = v * 10 + (p->s[p->i++] - '0');
		if (v > 1000) {
			rx_fail(p, "repeat count too large");
			return false;
		}
	}
	*out = v;
	return p->i > start;
}

static struct rx_node *
rx_piece(struct rx_parser *p)
{
	struct rx_node *a = rx_atom(p);

	while (a && p->i < p->n) {
		int c = p->s[p->i], min, max;
		if (c == '*') {
			min = 0, max = -1;
			p->i++;
		} else if (c == '+') {
			min = 1, max = -1;
			p->i++;
		} else if (c == '?') {
			min = 0, max = 1;
			p->i++;
		} else if (c == '{' && p->i + 1 < p->n && isdigit((unsigned char)p->s[p->i + 1])) {
			/* A '{' that doesn't start a whole {m}, {m,} or {m,n} is a literal,
			   as macOS's sandbox compiler takes it. */
			size_t save = p->i;
			p->i++;
			if (!rx_number(p, &min)) {
				return NULL;
			}
			max = min;
			if (p->i < p->n && p->s[p->i] == ',') {
				p->i++;
				max = -1;
				if (p->i < p->n && isdigit((unsigned char)p->s[p->i]) && !rx_number(p, &max)) {
					return NULL;
				}
			}
			if (p->i >= p->n || p->s[p->i] != '}') {
				p->i = save;
				break;
			}
			if (max >= 0 && max < min) {
				rx_fail(p, "bad {m,n}");
				return NULL;
			}
			p->i++;
		} else {
			break;
		}
		struct rx_node *r = rx_new(p, RX_REPEAT);
		if (!r) {
			return NULL;
		}
		r->a = a;
		r->min = min;
		r->max = max;
		a = r;
	}
	return a;
}

static struct rx_node *
rx_cat(struct rx_parser *p)
{
	struct rx_node *result = NULL;

	while (p->i < p->n && p->s[p->i] != '|' && p->s[p->i] != ')') {
		struct rx_node *piece = rx_piece(p);
		if (!piece) {
			return NULL;
		}
		if (!result) {
			result = piece;
		} else {
			struct rx_node *c = rx_new(p, RX_CAT);
			if (!c) {
				return NULL;
			}
			c->a = result;
			c->b = piece;
			result = c;
		}
	}
	return result ? result : rx_new(p, RX_EMPTY);
}

static struct rx_node *
rx_alt(struct rx_parser *p)
{
	struct rx_node *a = rx_cat(p);

	while (a && p->i < p->n && p->s[p->i] == '|') {
		p->i++;
		struct rx_node *b = rx_cat(p);
		if (!b) {
			return NULL;
		}
		struct rx_node *n = rx_new(p, RX_ALT);
		if (!n) {
			return NULL;
		}
		n->a = a;
		n->b = b;
		a = n;
	}
	return a;
}

/* ---- code generation ---- */

struct rx_code {
	uint32_t *w;
	uint32_t n, cap;
	bool overflow;
};

static uint32_t
emit(struct rx_code *c, uint32_t word)
{
	if (c->n >= FSB_MAX_REGEX_INSNS) {
		c->overflow = true;
		return c->n;
	}
	if (c->n == c->cap) {
		uint32_t cap = c->cap ? c->cap * 2 : 64;
		uint32_t *w = realloc(c->w, cap * sizeof(*w));
		if (!w) {
			c->overflow = true;
			return c->n;
		}
		c->w = w;
		c->cap = cap;
	}
	c->w[c->n] = word;
	return c->n++;
}

static void
patch_arg(struct rx_code *c, uint32_t at, uint32_t target)
{
	if (at < c->n) {
		c->w[at] = FSB_RX_WORD(FSB_RX_OP(c->w[at]), target);
	}
}

static void
patch_word(struct rx_code *c, uint32_t at, uint32_t value)
{
	if (at < c->n) {
		c->w[at] = value;
	}
}

static void gen(struct rx_code *c, const struct rx_node *n);

/* x? : SPLIT L1, L2; L1: x; L2: */
static void
gen_optional(struct rx_code *c, const struct rx_node *x)
{
	uint32_t split = emit(c, FSB_RX_WORD(FSB_RX_SPLIT, 0));
	uint32_t other = emit(c, 0);
	patch_arg(c, split, c->n);
	gen(c, x);
	patch_word(c, other, c->n);
}

/* x* : L1: SPLIT L2, L3; L2: x; JMP L1; L3: */
static void
gen_star(struct rx_code *c, const struct rx_node *x)
{
	uint32_t top = emit(c, FSB_RX_WORD(FSB_RX_SPLIT, 0));
	uint32_t other = emit(c, 0);
	patch_arg(c, top, c->n);
	gen(c, x);
	emit(c, FSB_RX_WORD(FSB_RX_JMP, top));
	patch_word(c, other, c->n);
}

static void
gen(struct rx_code *c, const struct rx_node *n)
{
	if (c->overflow) {
		return;
	}
	switch (n->kind) {
	case RX_EMPTY:
		break;
	case RX_LIT:
		emit(c, FSB_RX_WORD(FSB_RX_CHAR, (uint32_t)n->c));
		break;
	case RX_ANY:
		emit(c, FSB_RX_WORD(FSB_RX_ANY, 0));
		break;
	case RX_BOL:
		emit(c, FSB_RX_WORD(FSB_RX_BOL, 0));
		break;
	case RX_EOL:
		emit(c, FSB_RX_WORD(FSB_RX_EOL, 0));
		break;
	case RX_CLASS:
		emit(c, FSB_RX_WORD(FSB_RX_CLASS, 0));
		for (int k = 0; k < 8; k++) {
			emit(c, n->set[k]);
		}
		break;
	case RX_CAT:
		gen(c, n->a);
		gen(c, n->b);
		break;
	case RX_ALT: {
		/* SPLIT L1, L2; L1: a; JMP L3; L2: b; L3: */
		uint32_t split = emit(c, FSB_RX_WORD(FSB_RX_SPLIT, 0));
		uint32_t other = emit(c, 0);
		patch_arg(c, split, c->n);
		gen(c, n->a);
		uint32_t jmp = emit(c, FSB_RX_WORD(FSB_RX_JMP, 0));
		patch_word(c, other, c->n);
		gen(c, n->b);
		patch_arg(c, jmp, c->n);
		break;
	}
	case RX_REPEAT:
		for (int k = 0; k < n->min && !c->overflow; k++) {
			gen(c, n->a);
		}
		if (n->max < 0) {
			gen_star(c, n->a);
		} else {
			for (int k = n->min; k < n->max && !c->overflow; k++) {
				gen_optional(c, n->a);
			}
		}
		break;
	}
}

int
sbpl_regex_compile(const char *pattern, size_t length, uint32_t **program,
    uint32_t *words, char **error)
{
	struct rx_parser p = { .s = pattern, .n = length };
	struct rx_code code = { 0 };
	struct rx_node *root;
	int result = -1;

	/* macOS's sandbox compiler refuses an empty regex too */
	if (length == 0) {
		*program = NULL;
		*words = 0;
		*error = strdup("regex: empty");
		return -1;
	}
	root = rx_alt(&p);

	*program = NULL;
	*words = 0;
	if (root && p.i < p.n) {
		rx_fail(&p, "unmatched )");
	}
	if (!p.error && root) {
		gen(&code, root);
		emit(&code, FSB_RX_WORD(FSB_RX_MATCH, 0));
		if (code.overflow) {
			rx_fail(&p, "too large (over %d instructions)", FSB_MAX_REGEX_INSNS);
		} else {
			*program = code.w;
			*words = code.n;
			code.w = NULL;
			result = 0;
		}
	}
	free(code.w);
	for (size_t k = 0; k < p.count; k++) {
		free(p.all[k]);
	}
	free(p.all);
	if (result != 0) {
		*error = p.error ? p.error : strdup("regex: invalid");
	} else {
		free(p.error);
	}
	return result;
}
