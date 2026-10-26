/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Finch's SBPL compiler. SBPL is a small Scheme: profiles define helpers with
 * define/lambda/let, build paths with string-append and param, and call
 * (allow OPERATION... FILTER... MODIFIER...) and (deny ...) to add rules. This
 * file reads and evaluates that Scheme, collects the rules, and writes them
 * in the FSB1 format (kernel/sandbox/fsb_format.h).
 *
 * Semantics follow macOS's compiler where profiles depend on them: several
 * filters in one rule match if any does; with-filter ANDs its filter into the
 * rules inside it; a filter the compiler can't express exactly (an unknown
 * constant, a sandbox extension) is lowered so it never widens access: it
 * matches in a deny rule and fails in an allow rule.
 */
#include "sbpl.h"
#include "sbpl_consts.h"
#include "fsb_format.h"

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* ==== values ==== */

enum {
	T_NIL, T_PAIR, T_SYM, T_STR, T_INT, T_BOOL, T_CHAR, T_PRIM, T_CLOSURE,
	T_FILTER, T_MODIFIER, T_UNSPEC, T_OPREF, T_MACRO
};

typedef struct obj obj;
typedef struct env env;
struct ctx;

typedef obj *(*prim_fn)(struct ctx *, obj *args, env *e);

struct filt;

struct obj {
	int t;
	union {
		struct { obj *car, *cdr; } p;
		struct { const char *s; size_t n; bool regex; } str;	/* T_STR, T_SYM */
		long long i;					/* T_INT, T_BOOL, T_CHAR */
		struct { prim_fn fn; const char *name; bool special; } prim;
		struct { obj *params; obj *body; env *e; } clo;
		struct filt *f;					/* T_FILTER */
		struct { uint32_t set, clear; const char *what; } mod;	/* T_MODIFIER */
	} u;
};

struct binding {
	obj *sym;
	obj *value;
	struct binding *next;
};

struct env {
	struct binding *b;
	env *up;
	/* the global frame hashes its symbols */
	struct binding **table;
	size_t table_size;
};

/* Filters, before lowering to FSB1 nodes. */
enum {
	F_TRUE = FSB_N_TRUE, F_FALSE = FSB_N_FALSE, F_ALL = FSB_N_ALL, F_ANY = FSB_N_ANY,
	F_NOT = FSB_N_NOT, F_STR_EQ = FSB_N_STR_EQ, F_STR_PREFIX = FSB_N_STR_PREFIX,
	F_SUBPATH = FSB_N_SUBPATH, F_REGEX = FSB_N_REGEX, F_NUM_EQ = FSB_N_NUM_EQ,
	F_NUM_BITS = FSB_N_NUM_BITS, F_EXTENSION = FSB_N_EXTENSION,
	F_UNKNOWN = 100		/* never widens access (see lowering) */
};

struct filt {
	int kind;
	int field;
	const char *s;		/* string, or regex source */
	size_t n;
	uint64_t num;
	struct filt **kids;
	size_t nkids;
	const char *why;	/* F_UNKNOWN: what it stands for */
	uint32_t node;		/* FSB_NONE until emitted */
	uint32_t *prog;		/* F_REGEX */
	uint32_t words;
};

struct rule {
	uint32_t op;
	uint32_t flags;
	struct filt *f;		/* NULL: every request */
};

struct arena_block {
	struct arena_block *next;
	size_t used, size;
	max_align_t data[];
};

struct ctx {
	const struct sbpl_options *opt;
	jmp_buf fail;
	char *error;
	struct arena_block *arena;
	env *global;
	obj *nil, *t, *f, *unspec;
	obj **symtab;
	size_t symtab_size, symcount;
	struct rule *rules;
	size_t nrules, caprules;
	struct filt **with_filters;	/* with-filter stack */
	size_t nwith, capwith;
	uint32_t with_flags;		/* (with ...) modifier stack, OR'd */
	int depth;
	int import_depth;
	const char *source_name;
	int line;
	uint32_t profile_flags;
	int version;
	/* imported files already read, to keep repeated imports cheap */
	char **imported;
	size_t nimported;
	bool regex_failed;
	const char *calling;	/* the primitive being called, for messages */
};

static void fail(struct ctx *c, const char *fmt, ...) __attribute__((noreturn, format(printf, 2, 3)));

static void
fail(struct ctx *c, const char *fmt, ...)
{
	va_list ap;
	char *msg = NULL;

	va_start(ap, fmt);
	if (vasprintf(&msg, fmt, ap) < 0) {
		msg = NULL;
	}
	va_end(ap);
	if (!c->error) {
		if (msg && c->source_name &&
		    asprintf(&c->error, "%s:%d: %s", c->source_name, c->line, msg) >= 0) {
		} else {
			c->error = msg ? strdup(msg) : strdup("out of memory");
		}
	}
	free(msg);
	longjmp(c->fail, 1);
}

static void *
alloc(struct ctx *c, size_t size)
{
	size = (size + _Alignof(max_align_t) - 1) & ~(_Alignof(max_align_t) - 1);
	if (!c->arena || c->arena->size - c->arena->used < size) {
		size_t bsize = size > 65536 ? size : 65536;
		struct arena_block *b = malloc(sizeof(*b) + bsize);
		if (!b) {
			fail(c, "out of memory");
		}
		b->next = c->arena;
		b->used = 0;
		b->size = bsize;
		c->arena = b;
	}
	void *p = (char *)c->arena->data + c->arena->used;
	c->arena->used += size;
	memset(p, 0, size);
	return p;
}

static obj *
mk(struct ctx *c, int t)
{
	obj *o = alloc(c, sizeof(*o));
	o->t = t;
	return o;
}

static obj *
cons(struct ctx *c, obj *a, obj *d)
{
	obj *o = mk(c, T_PAIR);
	o->u.p.car = a;
	o->u.p.cdr = d;
	return o;
}

static obj *
mkint(struct ctx *c, long long i)
{
	obj *o = mk(c, T_INT);
	o->u.i = i;
	return o;
}

static obj *
mkstr(struct ctx *c, const char *s, size_t n)
{
	obj *o = mk(c, T_STR);
	char *copy = alloc(c, n + 1);
	memcpy(copy, s, n);
	o->u.str.s = copy;
	o->u.str.n = n;
	return o;
}

static obj *
mkbool(struct ctx *c, bool v)
{
	return v ? c->t : c->f;
}

static uint64_t
hash(const char *s, size_t n)
{
	uint64_t h = 1469598103934665603ull;
	for (size_t i = 0; i < n; i++) {
		h = (h ^ (unsigned char)s[i]) * 1099511628211ull;
	}
	return h;
}

static obj *
intern(struct ctx *c, const char *s, size_t n)
{
	if (c->symcount * 2 >= c->symtab_size) {
		size_t size = c->symtab_size ? c->symtab_size * 2 : 1024;
		obj **tab = alloc(c, size * sizeof(*tab));
		for (size_t i = 0; i < c->symtab_size; i++) {
			obj *o = c->symtab[i];
			if (o) {
				size_t h = hash(o->u.str.s, o->u.str.n) & (size - 1);
				while (tab[h]) {
					h = (h + 1) & (size - 1);
				}
				tab[h] = o;
			}
		}
		c->symtab = tab;
		c->symtab_size = size;
	}
	size_t h = hash(s, n) & (c->symtab_size - 1);
	while (c->symtab[h]) {
		obj *o = c->symtab[h];
		if (o->u.str.n == n && memcmp(o->u.str.s, s, n) == 0) {
			return o;
		}
		h = (h + 1) & (c->symtab_size - 1);
	}
	obj *o = mkstr(c, s, n);
	o->t = T_SYM;
	c->symtab[h] = o;
	c->symcount++;
	return o;
}

static obj *
sym(struct ctx *c, const char *s)
{
	return intern(c, s, strlen(s));
}

#define CAR(o) ((o)->u.p.car)
#define CDR(o) ((o)->u.p.cdr)
#define IS(o, ty) ((o)->t == (ty))

static bool
truthy(struct ctx *c, obj *o)
{
	return o != c->f;
}

static size_t
list_length(struct ctx *c, obj *l)
{
	size_t n = 0;
	while (IS(l, T_PAIR)) {
		n++;
		l = CDR(l);
	}
	if (!IS(l, T_NIL)) {
		fail(c, "improper list");
	}
	return n;
}

static const char *
type_name(int t)
{
	static const char *names[] = { "()", "pair", "symbol", "string", "integer", "boolean",
		"character", "procedure", "procedure", "filter", "modifier", "unspecified", "operation",
		"macro" };
	return t >= 0 && t < (int)(sizeof(names) / sizeof(names[0])) ? names[t] : "?";
}

static obj *
arg(struct ctx *c, obj **args, const char *who)
{
	if (!IS(*args, T_PAIR)) {
		fail(c, "%s: too few arguments", who);
	}
	obj *a = CAR(*args);
	*args = CDR(*args);
	return a;
}

static obj *
arg_type(struct ctx *c, obj **args, int t, const char *who)
{
	obj *a = arg(c, args, who);
	if (!IS(a, t)) {
		fail(c, "%s: expected %s, got %s", who, type_name(t), type_name(a->t));
	}
	return a;
}

static void
no_more(struct ctx *c, obj *args, const char *who)
{
	if (!IS(args, T_NIL)) {
		fail(c, "%s: too many arguments", who);
	}
}

/* ==== environments ==== */

static env *
env_new(struct ctx *c, env *up)
{
	env *e = alloc(c, sizeof(*e));
	e->up = up;
	return e;
}

static struct binding **
global_slot(env *e, obj *s)
{
	size_t h = ((uintptr_t)s >> 4) & (e->table_size - 1);
	struct binding **b = &e->table[h];
	while (*b && (*b)->sym != s) {
		b = &(*b)->next;
	}
	return b;
}

static struct binding *
lookup(env *e, obj *s)
{
	for (; e; e = e->up) {
		if (e->table) {
			struct binding **b = global_slot(e, s);
			if (*b) {
				return *b;
			}
			continue;
		}
		for (struct binding *b = e->b; b; b = b->next) {
			if (b->sym == s) {
				return b;
			}
		}
	}
	return NULL;
}

static void
define(struct ctx *c, env *e, obj *s, obj *v)
{
	if (e->table) {
		struct binding **b = global_slot(e, s);
		if (!*b) {
			*b = alloc(c, sizeof(**b));
			(*b)->sym = s;
		}
		(*b)->value = v;
		return;
	}
	for (struct binding *b = e->b; b; b = b->next) {
		if (b->sym == s) {
			b->value = v;
			return;
		}
	}
	struct binding *b = alloc(c, sizeof(*b));
	b->sym = s;
	b->value = v;
	b->next = e->b;
	e->b = b;
}

/* ==== reader ==== */

struct reader {
	struct ctx *c;
	const char *s;
	size_t n, i;
	int line;
};

static void
skip_space(struct reader *r)
{
	for (;;) {
		while (r->i < r->n && isspace((unsigned char)r->s[r->i])) {
			if (r->s[r->i] == '\n') {
				r->line++;
			}
			r->i++;
		}
		if (r->i < r->n && r->s[r->i] == ';') {
			while (r->i < r->n && r->s[r->i] != '\n') {
				r->i++;
			}
			continue;
		}
		if (r->i + 1 < r->n && r->s[r->i] == '#' && r->s[r->i + 1] == '|') {
			r->i += 2;
			while (r->i + 1 < r->n && !(r->s[r->i] == '|' && r->s[r->i + 1] == '#')) {
				if (r->s[r->i] == '\n') {
					r->line++;
				}
				r->i++;
			}
			r->i += 2;
			continue;
		}
		break;
	}
}

static bool
delimiter(int ch)
{
	return isspace(ch) || ch == '(' || ch == ')' || ch == '"' || ch == ';' || ch == '\'';
}

static obj *read_form(struct reader *r);

static obj *
read_string(struct reader *r, bool regex)
{
	struct ctx *c = r->c;
	size_t cap = 64, len = 0;
	char *buf = malloc(cap);

	if (!buf) {
		fail(c, "out of memory");
	}
	r->i++;		/* opening quote */
	for (;;) {
		if (r->i >= r->n) {
			free(buf);
			fail(c, "unterminated string");
		}
		char ch = r->s[r->i++];
		if (ch == '"') {
			break;
		}
		if (ch == '\n') {
			r->line++;
		}
		if (ch == '\\' && r->i < r->n) {
			char e = r->s[r->i++];
			if (regex) {
				/* A regex literal keeps its escapes for the regex compiler,
				   except an escaped quote. */
				if (e != '"') {
					if (len + 2 >= cap) {
						cap *= 2;
						char *nb = realloc(buf, cap);
						if (!nb) { free(buf); fail(c, "out of memory"); }
						buf = nb;
					}
					buf[len++] = '\\';
				}
				ch = e;
			} else {
				switch (e) {
				case 'n': ch = '\n'; break;
				case 't': ch = '\t'; break;
				case 'r': ch = '\r'; break;
				case '0': ch = '\0'; break;
				case 'x': {
					int v = 0, k = 0;
					while (k < 2 && r->i < r->n && isxdigit((unsigned char)r->s[r->i])) {
						char h = r->s[r->i++];
						v = v * 16 + (isdigit((unsigned char)h) ? h - '0' : (tolower(h) - 'a' + 10));
						k++;
					}
					ch = (char)v;
					break;
				}
				default: ch = e; break;
				}
			}
		}
		if (len + 1 >= cap) {
			cap *= 2;
			char *nb = realloc(buf, cap);
			if (!nb) { free(buf); fail(c, "out of memory"); }
			buf = nb;
		}
		buf[len++] = ch;
	}
	obj *o = mkstr(c, buf, len);
	o->u.str.regex = regex;
	free(buf);
	return o;
}

static obj *
read_atom(struct reader *r)
{
	struct ctx *c = r->c;
	size_t start = r->i;

	while (r->i < r->n && !delimiter((unsigned char)r->s[r->i])) {
		r->i++;
	}
	const char *s = r->s + start;
	size_t n = r->i - start;
	if (n == 0) {
		fail(c, "unexpected '%c'", r->s[r->i]);
	}
	if (s[0] == '#' && n >= 2) {
		if (n == 2 && (s[1] == 't' || s[1] == 'f')) {
			return mkbool(c, s[1] == 't');
		}
		if (n == 5 && memcmp(s, "#true", 5) == 0) {
			return c->t;
		}
		if (n == 6 && memcmp(s, "#false", 6) == 0) {
			return c->f;
		}
		int base = s[1] == 'x' || s[1] == 'X' ? 16 : s[1] == 'o' || s[1] == 'O' ? 8 :
		    s[1] == 'b' || s[1] == 'B' ? 2 : s[1] == 'd' ? 10 : 0;
		if (base) {
			char buf[64];
			char *end;
			if (n - 2 >= sizeof(buf)) {
				fail(c, "number too long");
			}
			memcpy(buf, s + 2, n - 2);
			buf[n - 2] = 0;
			long long v = strtoll(buf, &end, base);
			if (*end) {
				fail(c, "bad number %.*s", (int)n, s);
			}
			return mkint(c, v);
		}
		if (s[1] == '\\') {
			obj *o = mk(c, T_CHAR);
			if (n == 3) {
				o->u.i = (unsigned char)s[2];
			} else if (n == 7 && memcmp(s + 2, "space", 5) == 0) {
				o->u.i = ' ';
			} else if (n == 9 && memcmp(s + 2, "newline", 7) == 0) {
				o->u.i = '\n';
			} else if (n == 5 && memcmp(s + 2, "tab", 3) == 0) {
				o->u.i = '\t';
			} else {
				o->u.i = (unsigned char)s[2];
			}
			return o;
		}
		fail(c, "unknown syntax %.*s", (int)n, s);
	}
	/* numbers */
	{
		size_t k = (s[0] == '-' || s[0] == '+') && n > 1 ? 1 : 0;
		bool digits = k < n;
		for (size_t j = k; j < n; j++) {
			if (!isdigit((unsigned char)s[j])) {
				digits = false;
				break;
			}
		}
		if (digits) {
			char buf[64];
			if (n >= sizeof(buf)) {
				fail(c, "number too long");
			}
			memcpy(buf, s, n);
			buf[n] = 0;
			return mkint(c, strtoll(buf, NULL, 10));
		}
	}
	return intern(c, s, n);
}

static obj *
read_list(struct reader *r)
{
	struct ctx *c = r->c;
	obj *head = c->nil, **tail = &head;
	int line = r->line;

	r->i++;		/* '(' */
	for (;;) {
		skip_space(r);
		if (r->i >= r->n) {
			r->line = line;
			fail(c, "unterminated list");
		}
		if (r->s[r->i] == ')') {
			r->i++;
			return head;
		}
		/* dotted tail */
		if (r->s[r->i] == '.' && r->i + 1 < r->n && delimiter((unsigned char)r->s[r->i + 1]) &&
		    head != c->nil) {
			r->i++;
			*tail = read_form(r);
			skip_space(r);
			if (r->i >= r->n || r->s[r->i] != ')') {
				fail(c, "bad dotted list");
			}
			r->i++;
			return head;
		}
		obj *x = read_form(r);
		*tail = cons(c, x, c->nil);
		tail = &CDR(*tail);
	}
}

static obj *
quoted(struct reader *r, const char *what)
{
	struct ctx *c = r->c;
	return cons(c, sym(c, what), cons(c, read_form(r), c->nil));
}

static obj *
read_form(struct reader *r)
{
	struct ctx *c = r->c;

	skip_space(r);
	if (r->i >= r->n) {
		fail(c, "unexpected end of input");
	}
	c->line = r->line;
	char ch = r->s[r->i];
	switch (ch) {
	case '(':
		return read_list(r);
	case ')':
		fail(c, "unexpected )");
	case '"':
		return read_string(r, false);
	case '\'':
		r->i++;
		return quoted(r, "quote");
	case '`':
		r->i++;
		return quoted(r, "quasiquote");
	case ',':
		r->i++;
		if (r->i < r->n && r->s[r->i] == '@') {
			r->i++;
			return quoted(r, "unquote-splicing");
		}
		return quoted(r, "unquote");
	case '#':
		if (r->i + 1 < r->n && r->s[r->i + 1] == '"') {
			r->i++;
			return read_string(r, true);
		}
		if (r->i + 1 < r->n && r->s[r->i + 1] == ';') {
			r->i += 2;
			(void)read_form(r);
			return read_form(r);
		}
		break;
	default:
		break;
	}
	return read_atom(r);
}

/* ==== evaluation ==== */

static obj *eval(struct ctx *c, obj *x, env *e);

static obj *
eval_body(struct ctx *c, obj *body, env *e)
{
	obj *result = c->unspec;
	for (; IS(body, T_PAIR); body = CDR(body)) {
		result = eval(c, CAR(body), e);
	}
	return result;
}

static obj *
eval_list(struct ctx *c, obj *l, env *e)
{
	obj *head = c->nil, **tail = &head;
	for (; IS(l, T_PAIR); l = CDR(l)) {
		*tail = cons(c, eval(c, CAR(l), e), c->nil);
		tail = &CDR(*tail);
	}
	return head;
}

static obj *
apply(struct ctx *c, obj *f, obj *args, env *caller)
{
	if (IS(f, T_PRIM)) {
		return f->u.prim.fn(c, args, caller);
	}
	if (!IS(f, T_CLOSURE)) {
		fail(c, "not a procedure: %s", IS(f, T_SYM) ? f->u.str.s : type_name(f->t));
	}
	env *e = env_new(c, f->u.clo.e);
	obj *params = f->u.clo.params;
	while (IS(params, T_PAIR)) {
		if (!IS(args, T_PAIR)) {
			fail(c, "too few arguments");
		}
		define(c, e, CAR(params), CAR(args));
		params = CDR(params);
		args = CDR(args);
	}
	if (IS(params, T_SYM)) {
		define(c, e, params, args);	/* rest argument */
	} else if (!IS(args, T_NIL)) {
		fail(c, "too many arguments");
	}
	return eval_body(c, f->u.clo.body, e);
}

static obj *
eval(struct ctx *c, obj *x, env *e)
{
	if (IS(x, T_SYM)) {
		struct binding *b = lookup(e, x);
		if (!b) {
			/* macOS's (syscall-group-NAME) filters: groups of system calls */
			if (x->u.str.n > 14 && memcmp(x->u.str.s, "syscall-group-", 14) == 0) {
				return lookup(c->global, sym(c, "%unknown-filter"))->value;
			}
			fail(c, "unbound variable: %s", x->u.str.s);
		}
		return b->value;
	}
	if (!IS(x, T_PAIR)) {
		return x;
	}
	if (++c->depth > 2000) {
		fail(c, "recursion too deep");
	}
	obj *f = eval(c, CAR(x), e), *result;
	if (IS(f, T_PRIM)) {
		c->calling = f->u.prim.name;
	}
	if (IS(f, T_MACRO)) {
		/* TinyScheme's macro: the body sees the whole form and returns the code
		   to run in its place */
		env *me = env_new(c, f->u.clo.e);
		define(c, me, f->u.clo.params, x);
		obj *expansion = eval_body(c, f->u.clo.body, me);
		result = eval(c, expansion, e);
	} else if (IS(f, T_PRIM) && f->u.prim.special) {
		result = f->u.prim.fn(c, CDR(x), e);
	} else {
		result = apply(c, f, eval_list(c, CDR(x), e), e);
	}
	c->depth--;
	return result;
}

/* ---- special forms ---- */

static obj *
sf_quote(struct ctx *c, obj *args, env *e)
{
	(void)e;
	obj *x = arg(c, &args, "quote");
	return x;
}

static obj *
qq(struct ctx *c, obj *x, env *e, int depth)
{
	if (!IS(x, T_PAIR)) {
		return x;
	}
	obj *unquote = sym(c, "unquote"), *splice = sym(c, "unquote-splicing");
	if (CAR(x) == unquote) {
		return depth == 0 ? eval(c, CAR(CDR(x)), e) : x;
	}
	obj *head = c->nil, **tail = &head;
	for (; IS(x, T_PAIR); x = CDR(x)) {
		obj *item = CAR(x);
		if (CAR(x) == unquote) {	/* `(a . ,b) */
			*tail = eval(c, CAR(CDR(x)), e);
			return head;
		}
		if (IS(item, T_PAIR) && CAR(item) == splice && depth == 0) {
			obj *l = eval(c, CAR(CDR(item)), e);
			for (; IS(l, T_PAIR); l = CDR(l)) {
				*tail = cons(c, CAR(l), c->nil);
				tail = &CDR(*tail);
			}
			continue;
		}
		*tail = cons(c, qq(c, item, e, depth), c->nil);
		tail = &CDR(*tail);
	}
	*tail = x;
	return head;
}

static obj *
sf_quasiquote(struct ctx *c, obj *args, env *e)
{
	return qq(c, arg(c, &args, "quasiquote"), e, 0);
}

static obj *
sf_if(struct ctx *c, obj *args, env *e)
{
	obj *test = arg(c, &args, "if"), *then = arg(c, &args, "if");
	if (truthy(c, eval(c, test, e))) {
		return eval(c, then, e);
	}
	return IS(args, T_PAIR) ? eval(c, CAR(args), e) : c->unspec;
}

static obj *
make_closure(struct ctx *c, obj *params, obj *body, env *e)
{
	obj *o = mk(c, T_CLOSURE);
	o->u.clo.params = params;
	o->u.clo.body = body;
	o->u.clo.e = e;
	return o;
}

static obj *
sf_define(struct ctx *c, obj *args, env *e)
{
	obj *target = arg(c, &args, "define");
	if (IS(target, T_PAIR)) {
		/* (define (name . params) body...) */
		define(c, e, CAR(target), make_closure(c, CDR(target), args, e));
		return c->unspec;
	}
	if (!IS(target, T_SYM)) {
		fail(c, "define: bad name");
	}
	define(c, e, target, IS(args, T_PAIR) ? eval(c, CAR(args), e) : c->unspec);
	return c->unspec;
}

/* (macro (name form) body...) */
static obj *
sf_macro(struct ctx *c, obj *args, env *e)
{
	obj *sig = arg_type(c, &args, T_PAIR, "macro");
	if (!IS(CAR(sig), T_SYM) || !IS(CDR(sig), T_PAIR) || !IS(CAR(CDR(sig)), T_SYM)) {
		fail(c, "macro: expected (macro (name form) body...)");
	}
	obj *m = make_closure(c, CAR(CDR(sig)), args, e);
	m->t = T_MACRO;
	define(c, e, CAR(sig), m);
	return c->unspec;
}

static obj *
sf_set(struct ctx *c, obj *args, env *e)
{
	obj *s = arg_type(c, &args, T_SYM, "set!");
	struct binding *b = lookup(e, s);
	if (!b) {
		fail(c, "set!: unbound variable %s", s->u.str.s);
	}
	b->value = eval(c, arg(c, &args, "set!"), e);
	return c->unspec;
}

static obj *
sf_lambda(struct ctx *c, obj *args, env *e)
{
	obj *params = arg(c, &args, "lambda");
	return make_closure(c, params, args, e);
}

static obj *
sf_begin(struct ctx *c, obj *args, env *e)
{
	return eval_body(c, args, e);
}

static obj *
let_common(struct ctx *c, obj *args, env *e, int kind)	/* 0 let, 1 let*, 2 letrec */
{
	obj *bindings = arg(c, &args, "let");
	if (kind == 0 && IS(bindings, T_SYM)) {
		/* named let: (let loop ((v init)...) body) */
		obj *name = bindings, *params = c->nil, **pt = &params, *inits = c->nil, **it = &inits;
		bindings = arg(c, &args, "let");
		for (; IS(bindings, T_PAIR); bindings = CDR(bindings)) {
			obj *b = CAR(bindings);
			*pt = cons(c, CAR(b), c->nil);
			pt = &CDR(*pt);
			*it = cons(c, eval(c, CAR(CDR(b)), e), c->nil);
			it = &CDR(*it);
		}
		env *le = env_new(c, e);
		obj *loop = make_closure(c, params, args, le);
		define(c, le, name, loop);
		return apply(c, loop, inits, e);
	}
	env *ne = env_new(c, e);
	for (obj *b = bindings; IS(b, T_PAIR); b = CDR(b)) {
		obj *pair = CAR(b);
		obj *name = IS(pair, T_PAIR) ? CAR(pair) : pair;
		if (kind == 2) {
			define(c, ne, name, c->unspec);
		}
	}
	for (obj *b = bindings; IS(b, T_PAIR); b = CDR(b)) {
		obj *pair = CAR(b);
		obj *name = IS(pair, T_PAIR) ? CAR(pair) : pair;
		obj *init = IS(pair, T_PAIR) && IS(CDR(pair), T_PAIR) ? CAR(CDR(pair)) : c->unspec;
		obj *v = eval(c, init, kind == 0 ? e : ne);
		if (kind == 1) {
			ne = env_new(c, ne);
		}
		define(c, ne, name, v);
	}
	return eval_body(c, args, ne);
}

static obj *sf_let(struct ctx *c, obj *a, env *e) { return let_common(c, a, e, 0); }
static obj *sf_letstar(struct ctx *c, obj *a, env *e) { return let_common(c, a, e, 1); }
static obj *sf_letrec(struct ctx *c, obj *a, env *e) { return let_common(c, a, e, 2); }

static obj *
sf_and(struct ctx *c, obj *args, env *e)
{
	obj *v = c->t;
	for (; IS(args, T_PAIR); args = CDR(args)) {
		v = eval(c, CAR(args), e);
		if (!truthy(c, v)) {
			return c->f;
		}
	}
	return v;
}

static obj *
sf_or(struct ctx *c, obj *args, env *e)
{
	for (; IS(args, T_PAIR); args = CDR(args)) {
		obj *v = eval(c, CAR(args), e);
		if (truthy(c, v)) {
			return v;
		}
	}
	return c->f;
}

static obj *
sf_when(struct ctx *c, obj *args, env *e)
{
	if (truthy(c, eval(c, arg(c, &args, "when"), e))) {
		return eval_body(c, args, e);
	}
	return c->unspec;
}

static obj *
sf_unless(struct ctx *c, obj *args, env *e)
{
	if (!truthy(c, eval(c, arg(c, &args, "unless"), e))) {
		return eval_body(c, args, e);
	}
	return c->unspec;
}

static obj *
sf_cond(struct ctx *c, obj *args, env *e)
{
	obj *else_sym = sym(c, "else");
	for (; IS(args, T_PAIR); args = CDR(args)) {
		obj *clause = CAR(args);
		if (!IS(clause, T_PAIR)) {
			fail(c, "cond: bad clause");
		}
		if (CAR(clause) == else_sym) {
			return eval_body(c, CDR(clause), e);
		}
		obj *v = eval(c, CAR(clause), e);
		if (truthy(c, v)) {
			return IS(CDR(clause), T_NIL) ? v : eval_body(c, CDR(clause), e);
		}
	}
	return c->unspec;
}

static int resolve_op(const char *name, size_t n, uint32_t out[3]);

static obj *
sf_defined(struct ctx *c, obj *args, env *e)
{
	/* (defined? 'name): the argument is evaluated, as Scheme's would be */
	obj *s = eval(c, arg(c, &args, "defined?"), e);
	if (!IS(s, T_SYM)) {
		fail(c, "defined?: expected a symbol");
	}
	uint32_t found[3];
	return mkbool(c, lookup(e, s) != NULL || resolve_op(s->u.str.s, s->u.str.n, found) >= 0);
}

/* ---- Scheme builtins ---- */

static bool
equal(obj *a, obj *b)
{
	if (a == b) {
		return true;
	}
	if (a->t != b->t) {
		return false;
	}
	switch (a->t) {
	case T_STR:
		return a->u.str.n == b->u.str.n && memcmp(a->u.str.s, b->u.str.s, a->u.str.n) == 0;
	case T_INT:
	case T_CHAR:
	case T_BOOL:
		return a->u.i == b->u.i;
	case T_PAIR:
		return equal(a->u.p.car, b->u.p.car) && equal(a->u.p.cdr, b->u.p.cdr);
	default:
		return false;
	}
}

static obj *p_equal(struct ctx *c, obj *a, env *e) { (void)e; obj *x = arg(c, &a, "equal?"), *y = arg(c, &a, "equal?"); return mkbool(c, equal(x, y)); }
static obj *p_eq(struct ctx *c, obj *a, env *e) { (void)e; obj *x = arg(c, &a, "eq?"), *y = arg(c, &a, "eq?"); return mkbool(c, x == y || ((IS(x, T_INT) || IS(x, T_CHAR)) && x->t == y->t && x->u.i == y->u.i) || (IS(x, T_NIL) && IS(y, T_NIL))); }
static obj *p_not(struct ctx *c, obj *a, env *e) { (void)e; return mkbool(c, !truthy(c, arg(c, &a, "not"))); }
static obj *p_car(struct ctx *c, obj *a, env *e) { (void)e; return CAR(arg_type(c, &a, T_PAIR, "car")); }
static obj *p_cdr(struct ctx *c, obj *a, env *e) { (void)e; return CDR(arg_type(c, &a, T_PAIR, "cdr")); }
static obj *p_cadr(struct ctx *c, obj *a, env *e) { (void)e; obj *l = arg_type(c, &a, T_PAIR, "cadr"); if (!IS(CDR(l), T_PAIR)) fail(c, "cadr: list too short"); return CAR(CDR(l)); }
static obj *p_cddr(struct ctx *c, obj *a, env *e) { (void)e; obj *l = arg_type(c, &a, T_PAIR, "cddr"); if (!IS(CDR(l), T_PAIR)) fail(c, "cddr: list too short"); return CDR(CDR(l)); }
static obj *p_cons(struct ctx *c, obj *a, env *e) { (void)e; obj *x = arg(c, &a, "cons"), *y = arg(c, &a, "cons"); return cons(c, x, y); }
static obj *p_list(struct ctx *c, obj *a, env *e) { (void)c; (void)e; return a; }
static obj *p_nullp(struct ctx *c, obj *a, env *e) { (void)e; return mkbool(c, IS(arg(c, &a, "null?"), T_NIL)); }
static obj *p_pairp(struct ctx *c, obj *a, env *e) { (void)e; return mkbool(c, IS(arg(c, &a, "pair?"), T_PAIR)); }
static obj *p_listp(struct ctx *c, obj *a, env *e) { (void)e; obj *l = arg(c, &a, "list?"); while (IS(l, T_PAIR)) l = CDR(l); return mkbool(c, IS(l, T_NIL)); }
static obj *p_stringp(struct ctx *c, obj *a, env *e) { (void)e; return mkbool(c, IS(arg(c, &a, "string?"), T_STR)); }
static obj *p_symbolp(struct ctx *c, obj *a, env *e) { (void)e; return mkbool(c, IS(arg(c, &a, "symbol?"), T_SYM)); }
static obj *p_numberp(struct ctx *c, obj *a, env *e) { (void)e; return mkbool(c, IS(arg(c, &a, "number?"), T_INT)); }
static obj *p_booleanp(struct ctx *c, obj *a, env *e) { (void)e; return mkbool(c, IS(arg(c, &a, "boolean?"), T_BOOL)); }
static obj *p_procedurep(struct ctx *c, obj *a, env *e) { (void)e; obj *x = arg(c, &a, "procedure?"); return mkbool(c, IS(x, T_PRIM) || IS(x, T_CLOSURE)); }

static obj *
p_length(struct ctx *c, obj *a, env *e)
{
	(void)e;
	return mkint(c, (long long)list_length(c, arg(c, &a, "length")));
}

static obj *
p_append(struct ctx *c, obj *a, env *e)
{
	(void)e;
	obj *head = c->nil, **tail = &head;
	for (; IS(a, T_PAIR); a = CDR(a)) {
		obj *l = CAR(a);
		if (IS(CDR(a), T_NIL)) {
			*tail = l;	/* the last list is shared, as Scheme's append does */
			return head;
		}
		for (; IS(l, T_PAIR); l = CDR(l)) {
			*tail = cons(c, CAR(l), c->nil);
			tail = &CDR(*tail);
		}
	}
	return head;
}

static obj *
p_reverse(struct ctx *c, obj *a, env *e)
{
	(void)e;
	obj *r = c->nil;
	for (obj *l = arg(c, &a, "reverse"); IS(l, T_PAIR); l = CDR(l)) {
		r = cons(c, CAR(l), r);
	}
	return r;
}

static obj *
p_map(struct ctx *c, obj *a, env *e)
{
	obj *f = arg(c, &a, "map");
	obj *head = c->nil, **tail = &head;
	obj *lists = a;
	for (;;) {
		obj *args = c->nil, **at = &args;
		for (obj *l = lists; IS(l, T_PAIR); l = CDR(l)) {
			if (!IS(CAR(l), T_PAIR)) {
				return head;
			}
			*at = cons(c, CAR(CAR(l)), c->nil);
			at = &CDR(*at);
			CAR(l) = CDR(CAR(l));
		}
		if (IS(args, T_NIL)) {
			return head;
		}
		*tail = cons(c, apply(c, f, args, e), c->nil);
		tail = &CDR(*tail);
	}
}

static obj *
p_for_each(struct ctx *c, obj *a, env *e)
{
	p_map(c, a, e);
	return c->unspec;
}

static obj *
p_apply(struct ctx *c, obj *a, env *e)
{
	obj *f = arg(c, &a, "apply");
	/* (apply f a b ... list) */
	obj *head = c->nil, **tail = &head;
	for (; IS(a, T_PAIR); a = CDR(a)) {
		if (IS(CDR(a), T_NIL)) {
			*tail = CAR(a);
			break;
		}
		*tail = cons(c, CAR(a), c->nil);
		tail = &CDR(*tail);
	}
	return apply(c, f, head, e);
}

static obj *
p_filter(struct ctx *c, obj *a, env *e)
{
	obj *f = arg(c, &a, "filter"), *l = arg(c, &a, "filter");
	obj *head = c->nil, **tail = &head;
	for (; IS(l, T_PAIR); l = CDR(l)) {
		if (truthy(c, apply(c, f, cons(c, CAR(l), c->nil), e))) {
			*tail = cons(c, CAR(l), c->nil);
			tail = &CDR(*tail);
		}
	}
	return head;
}

static obj *
p_member(struct ctx *c, obj *a, env *e)
{
	(void)e;
	obj *x = arg(c, &a, "member");
	for (obj *l = arg(c, &a, "member"); IS(l, T_PAIR); l = CDR(l)) {
		if (equal(x, CAR(l))) {
			return l;
		}
	}
	return c->f;
}

static obj *
p_assoc(struct ctx *c, obj *a, env *e)
{
	(void)e;
	obj *x = arg(c, &a, "assoc");
	for (obj *l = arg(c, &a, "assoc"); IS(l, T_PAIR); l = CDR(l)) {
		if (IS(CAR(l), T_PAIR) && equal(x, CAR(CAR(l)))) {
			return CAR(l);
		}
	}
	return c->f;
}

static obj *
p_list_ref(struct ctx *c, obj *a, env *e)
{
	(void)e;
	obj *l = arg(c, &a, "list-ref");
	long long k = arg_type(c, &a, T_INT, "list-ref")->u.i;
	for (; k > 0 && IS(l, T_PAIR); k--) {
		l = CDR(l);
	}
	if (!IS(l, T_PAIR)) {
		fail(c, "list-ref: index out of range");
	}
	return CAR(l);
}

static long long
num_arg(struct ctx *c, obj **a, const char *who)
{
	return arg_type(c, a, T_INT, who)->u.i;
}

static obj *p_add(struct ctx *c, obj *a, env *e) { (void)e; long long v = 0; while (IS(a, T_PAIR)) v += num_arg(c, &a, "+"); return mkint(c, v); }
static obj *p_mul(struct ctx *c, obj *a, env *e) { (void)e; long long v = 1; while (IS(a, T_PAIR)) v *= num_arg(c, &a, "*"); return mkint(c, v); }
static obj *
p_sub(struct ctx *c, obj *a, env *e)
{
	(void)e;
	long long v = num_arg(c, &a, "-");
	if (IS(a, T_NIL)) {
		return mkint(c, -v);
	}
	while (IS(a, T_PAIR)) {
		v -= num_arg(c, &a, "-");
	}
	return mkint(c, v);
}

static obj *
compare(struct ctx *c, obj *a, int op, const char *who)
{
	long long prev = num_arg(c, &a, who);
	bool ok = true;
	while (IS(a, T_PAIR)) {
		long long v = num_arg(c, &a, who);
		switch (op) {
		case 0: ok = ok && prev == v; break;
		case 1: ok = ok && prev < v; break;
		case 2: ok = ok && prev > v; break;
		case 3: ok = ok && prev <= v; break;
		case 4: ok = ok && prev >= v; break;
		}
		prev = v;
	}
	return mkbool(c, ok);
}

static obj *p_numeq(struct ctx *c, obj *a, env *e) { (void)e; return compare(c, a, 0, "="); }
static obj *p_lt(struct ctx *c, obj *a, env *e) { (void)e; return compare(c, a, 1, "<"); }
static obj *p_gt(struct ctx *c, obj *a, env *e) { (void)e; return compare(c, a, 2, ">"); }
static obj *p_le(struct ctx *c, obj *a, env *e) { (void)e; return compare(c, a, 3, "<="); }
static obj *p_ge(struct ctx *c, obj *a, env *e) { (void)e; return compare(c, a, 4, ">="); }
static obj *p_zerop(struct ctx *c, obj *a, env *e) { (void)e; return mkbool(c, num_arg(c, &a, "zero?") == 0); }
static obj *p_positivep(struct ctx *c, obj *a, env *e) { (void)e; return mkbool(c, num_arg(c, &a, "positive?") > 0); }
static obj *p_negativep(struct ctx *c, obj *a, env *e) { (void)e; return mkbool(c, num_arg(c, &a, "negative?") < 0); }

static obj *
p_logior(struct ctx *c, obj *a, env *e)
{
	(void)e;
	long long v = 0;
	while (IS(a, T_PAIR)) {
		v |= num_arg(c, &a, "logior");
	}
	return mkint(c, v);
}

static obj *
p_logand(struct ctx *c, obj *a, env *e)
{
	(void)e;
	long long v = -1;
	while (IS(a, T_PAIR)) {
		v &= num_arg(c, &a, "logand");
	}
	return mkint(c, v);
}

static obj *
p_string_append(struct ctx *c, obj *a, env *e)
{
	(void)e;
	size_t n = 0;
	for (obj *l = a; IS(l, T_PAIR); l = CDR(l)) {
		if (!IS(CAR(l), T_STR)) {
			fail(c, "string-append: expected strings, got %s", type_name(CAR(l)->t));
		}
		n += CAR(l)->u.str.n;
	}
	char *buf = alloc(c, n + 1);
	size_t at = 0;
	bool regex = false;
	for (obj *l = a; IS(l, T_PAIR); l = CDR(l)) {
		memcpy(buf + at, CAR(l)->u.str.s, CAR(l)->u.str.n);
		at += CAR(l)->u.str.n;
		regex = regex || CAR(l)->u.str.regex;
	}
	obj *o = mk(c, T_STR);
	o->u.str.s = buf;
	o->u.str.n = n;
	o->u.str.regex = regex;
	return o;
}

static obj *p_string_length(struct ctx *c, obj *a, env *e) { (void)e; return mkint(c, (long long)arg_type(c, &a, T_STR, "string-length")->u.str.n); }

static obj *
p_substring(struct ctx *c, obj *a, env *e)
{
	(void)e;
	obj *s = arg_type(c, &a, T_STR, "substring");
	long long from = num_arg(c, &a, "substring");
	long long to = IS(a, T_PAIR) ? num_arg(c, &a, "substring") : (long long)s->u.str.n;
	if (from < 0 || to < from || (size_t)to > s->u.str.n) {
		fail(c, "substring: index out of range");
	}
	return mkstr(c, s->u.str.s + from, (size_t)(to - from));
}

static obj *
p_string_eq(struct ctx *c, obj *a, env *e)
{
	(void)e;
	obj *x = arg_type(c, &a, T_STR, "string=?"), *y = arg_type(c, &a, T_STR, "string=?");
	return mkbool(c, equal(x, y));
}

static obj *
p_string_prefixp(struct ctx *c, obj *a, env *e)
{
	(void)e;
	obj *p = arg_type(c, &a, T_STR, "string-prefix?"), *s = arg_type(c, &a, T_STR, "string-prefix?");
	return mkbool(c, s->u.str.n >= p->u.str.n && memcmp(s->u.str.s, p->u.str.s, p->u.str.n) == 0);
}

static obj *
p_string_suffixp(struct ctx *c, obj *a, env *e)
{
	(void)e;
	obj *p = arg_type(c, &a, T_STR, "string-suffix?"), *s = arg_type(c, &a, T_STR, "string-suffix?");
	return mkbool(c, s->u.str.n >= p->u.str.n &&
	    memcmp(s->u.str.s + s->u.str.n - p->u.str.n, p->u.str.s, p->u.str.n) == 0);
}

static obj *
p_symbol_to_string(struct ctx *c, obj *a, env *e)
{
	(void)e;
	obj *s = arg_type(c, &a, T_SYM, "symbol->string");
	return mkstr(c, s->u.str.s, s->u.str.n);
}

static obj *
p_string_to_symbol(struct ctx *c, obj *a, env *e)
{
	(void)e;
	obj *s = arg_type(c, &a, T_STR, "string->symbol");
	return intern(c, s->u.str.s, s->u.str.n);
}

static obj *
p_number_to_string(struct ctx *c, obj *a, env *e)
{
	(void)e;
	long long v = num_arg(c, &a, "number->string");
	int base = IS(a, T_PAIR) ? (int)num_arg(c, &a, "number->string") : 10;
	char buf[80];
	if (base == 16) {
		snprintf(buf, sizeof(buf), "%llx", v);
	} else if (base == 8) {
		snprintf(buf, sizeof(buf), "%llo", v);
	} else {
		snprintf(buf, sizeof(buf), "%lld", v);
	}
	return mkstr(c, buf, strlen(buf));
}

static obj *
p_string_to_number(struct ctx *c, obj *a, env *e)
{
	(void)e;
	obj *s = arg_type(c, &a, T_STR, "string->number");
	char buf[64], *end;
	if (s->u.str.n >= sizeof(buf)) {
		return c->f;
	}
	memcpy(buf, s->u.str.s, s->u.str.n);
	buf[s->u.str.n] = 0;
	long long v = strtoll(buf, &end, IS(a, T_PAIR) ? (int)num_arg(c, &a, "string->number") : 10);
	return *end || end == buf ? c->f : mkint(c, v);
}

static obj *
p_string(struct ctx *c, obj *a, env *e)
{
	(void)e;
	size_t n = list_length(c, a);
	char *buf = alloc(c, n + 1);
	for (size_t i = 0; i < n; i++) {
		buf[i] = (char)arg_type(c, &a, T_CHAR, "string")->u.i;
	}
	obj *o = mk(c, T_STR);
	o->u.str.s = buf;
	o->u.str.n = n;
	return o;
}

static obj *
p_string_to_list(struct ctx *c, obj *a, env *e)
{
	(void)e;
	obj *s = arg_type(c, &a, T_STR, "string->list");
	obj *head = c->nil, **tail = &head;
	for (size_t i = 0; i < s->u.str.n; i++) {
		obj *ch = mk(c, T_CHAR);
		ch->u.i = (unsigned char)s->u.str.s[i];
		*tail = cons(c, ch, c->nil);
		tail = &CDR(*tail);
	}
	return head;
}

static obj *
p_list_to_string(struct ctx *c, obj *a, env *e)
{
	return p_string(c, arg(c, &a, "list->string"), e);
}

static obj *
p_string_ref(struct ctx *c, obj *a, env *e)
{
	(void)e;
	obj *s = arg_type(c, &a, T_STR, "string-ref");
	long long k = num_arg(c, &a, "string-ref");
	if (k < 0 || (size_t)k >= s->u.str.n) {
		fail(c, "string-ref: index out of range");
	}
	obj *ch = mk(c, T_CHAR);
	ch->u.i = (unsigned char)s->u.str.s[k];
	return ch;
}

static obj *
p_char_upcase(struct ctx *c, obj *a, env *e)
{
	(void)e;
	obj *ch = mk(c, T_CHAR);
	ch->u.i = toupper((int)arg_type(c, &a, T_CHAR, "char-upcase")->u.i);
	return ch;
}

static obj *
p_char_downcase(struct ctx *c, obj *a, env *e)
{
	(void)e;
	obj *ch = mk(c, T_CHAR);
	ch->u.i = tolower((int)arg_type(c, &a, T_CHAR, "char-downcase")->u.i);
	return ch;
}

/* (split-string "a:b" ":") => ("a" "b") */
static obj *
p_split_string(struct ctx *c, obj *a, env *e)
{
	(void)e;
	obj *str = arg_type(c, &a, T_STR, "split-string"), *sep = arg_type(c, &a, T_STR, "split-string");
	obj *head = c->nil, **tail = &head;
	const char *s = str->u.str.s, *end = s + str->u.str.n;
	if (sep->u.str.n == 0) {
		fail(c, "split-string: empty separator");
	}
	for (;;) {
		const char *hit = NULL;
		for (const char *p = s; p + sep->u.str.n <= end; p++) {
			if (memcmp(p, sep->u.str.s, sep->u.str.n) == 0) {
				hit = p;
				break;
			}
		}
		const char *stop = hit ? hit : end;
		*tail = cons(c, mkstr(c, s, (size_t)(stop - s)), c->nil);
		tail = &CDR(*tail);
		if (!hit) {
			return head;
		}
		s = hit + sep->u.str.n;
	}
}

static obj *
p_char_eq(struct ctx *c, obj *a, env *e)
{
	(void)e;
	obj *x = arg_type(c, &a, T_CHAR, "char=?"), *y = arg_type(c, &a, T_CHAR, "char=?");
	return mkbool(c, x->u.i == y->u.i);
}

/* (flatten '(a (b (c)) d)) => (a b c d) */
static void
flatten_into(struct ctx *c, obj *l, obj ***tail)
{
	for (; IS(l, T_PAIR); l = CDR(l)) {
		if (IS(CAR(l), T_PAIR) || IS(CAR(l), T_NIL)) {
			flatten_into(c, CAR(l), tail);
		} else {
			**tail = cons(c, CAR(l), c->nil);
			*tail = &CDR(**tail);
		}
	}
	if (!IS(l, T_NIL)) {
		**tail = cons(c, l, c->nil);
		*tail = &CDR(**tail);
	}
}

static obj *
p_flatten(struct ctx *c, obj *a, env *e)
{
	(void)e;
	obj *head = c->nil, **tail = &head;
	flatten_into(c, arg(c, &a, "flatten"), &tail);
	return head;
}

static obj *p_atomp(struct ctx *c, obj *a, env *e) { (void)e; return mkbool(c, !IS(arg(c, &a, "atom?"), T_PAIR)); }

static obj *
p_error(struct ctx *c, obj *a, env *e)
{
	(void)e;
	obj *msg = IS(a, T_PAIR) ? CAR(a) : NULL;
	fail(c, "error: %s", msg && IS(msg, T_STR) ? msg->u.str.s : "(error)");
}

/* ==== SBPL: parameters, entitlements, imports ==== */

static obj *
p_param(struct ctx *c, obj *a, env *e)
{
	(void)e;
	obj *name = arg_type(c, &a, T_STR, "param");
	for (size_t i = 0; i < c->opt->param_count; i++) {
		const struct sbpl_param *p = &c->opt->params[i];
		if (strlen(p->name) == name->u.str.n && memcmp(p->name, name->u.str.s, name->u.str.n) == 0) {
			return p->value ? mkstr(c, p->value, strlen(p->value)) : c->f;
		}
	}
	return c->f;
}

static const char *
entitlement_value(struct ctx *c, const char *name, size_t n, bool *present)
{
	*present = false;
	for (size_t i = 0; i < c->opt->entitlement_count; i++) {
		const char *s = c->opt->entitlements[i];
		if (strncmp(s, name, n) == 0 && (s[n] == '\0' || s[n] == '=')) {
			*present = true;
			return s[n] == '=' ? s + n + 1 : NULL;
		}
	}
	return NULL;
}

static obj *
p_entitlement(struct ctx *c, obj *a, env *e)
{
	(void)e;
	obj *name = arg_type(c, &a, T_STR, "entitlement");
	bool present;
	const char *value = entitlement_value(c, name->u.str.s, name->u.str.n, &present);
	if (!present) {
		return c->f;
	}
	if (!value || strcmp(value, "true") == 0) {
		return c->t;
	}
	if (strcmp(value, "false") == 0) {
		return c->f;
	}
	return mkstr(c, value, strlen(value));
}

static obj *
p_array_entitlement(struct ctx *c, obj *a, env *e)
{
	/* (sandbox-array-entitlement "name" proc): calls proc with each value */
	obj *name = arg_type(c, &a, T_STR, "sandbox-array-entitlement");
	obj *proc = IS(a, T_PAIR) ? arg(c, &a, "sandbox-array-entitlement") : NULL;
	bool present;
	const char *value = entitlement_value(c, name->u.str.s, name->u.str.n, &present);
	if (!present || !value || !proc) {
		return c->unspec;
	}
	/* values are separated by commas in the option string */
	const char *s = value;
	while (*s) {
		const char *end = strchr(s, ',');
		size_t n = end ? (size_t)(end - s) : strlen(s);
		apply(c, proc, cons(c, mkstr(c, s, n), c->nil), e);
		s += n + (end ? 1 : 0);
	}
	return c->unspec;
}

static obj *
p_false(struct ctx *c, obj *a, env *e)
{
	(void)a;
	(void)e;
	return c->f;
}

static int compile_source(struct ctx *c, const char *source, size_t n, const char *name);

static char *
find_file(struct ctx *c, const char *name)
{
	struct stat st;
	char *path = NULL;

	if (strchr(name, '/')) {
		return stat(name, &st) == 0 ? strdup(name) : NULL;
	}
	for (size_t i = 0; i < c->opt->search_path_count; i++) {
		for (int ext = 0; ext < 2; ext++) {
			if (asprintf(&path, "%s/%s%s", c->opt->search_paths[i], name, ext ? ".sb" : "") < 0) {
				return NULL;
			}
			if (stat(path, &st) == 0 && S_ISREG(st.st_mode)) {
				return path;
			}
			free(path);
			path = NULL;
		}
	}
	return NULL;
}

static char *
read_file(const char *path, size_t *n)
{
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	struct stat st;
	char *buf = NULL;

	if (fd < 0) {
		return NULL;
	}
	if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size < (16 << 20)) {
		buf = malloc((size_t)st.st_size + 1);
		if (buf) {
			size_t got = 0;
			while (got < (size_t)st.st_size) {
				ssize_t r = read(fd, buf + got, (size_t)st.st_size - got);
				if (r <= 0) {
					free(buf);
					buf = NULL;
					break;
				}
				got += (size_t)r;
			}
			if (buf) {
				buf[got] = 0;
				*n = got;
			}
		}
	}
	close(fd);
	return buf;
}

static obj *
p_import(struct ctx *c, obj *a, env *e)
{
	(void)e;
	obj *name = arg_type(c, &a, T_STR, "import");
	char *path = find_file(c, name->u.str.s);
	if (!path) {
		fail(c, "import: can't find %s", name->u.str.s);
	}
	/* Each file is read once per profile, as macOS's compiler does. */
	for (size_t i = 0; i < c->nimported; i++) {
		if (strcmp(c->imported[i], path) == 0) {
			free(path);
			return c->unspec;
		}
	}
	char **list = realloc(c->imported, (c->nimported + 1) * sizeof(*list));
	if (!list) {
		free(path);
		fail(c, "out of memory");
	}
	c->imported = list;
	c->imported[c->nimported++] = path;
	if (++c->import_depth > 32) {
		fail(c, "import: nested too deeply");
	}
	size_t n = 0;
	char *src = read_file(path, &n);
	if (!src) {
		fail(c, "import: can't read %s", path);
	}
	const char *saved_name = c->source_name;
	int saved_line = c->line;
	struct binding *ip = lookup(c->global, sym(c, "*import-path*"));
	obj *saved_import = ip->value;
	ip->value = mkstr(c, path, strlen(path));
	int r = compile_source(c, src, n, path);
	ip->value = saved_import;
	free(src);
	c->source_name = saved_name;
	c->line = saved_line;
	c->import_depth--;
	if (r != 0) {
		longjmp(c->fail, 1);
	}
	return c->unspec;
}

/* ==== filters ==== */

static struct filt *
filt_new(struct ctx *c, int kind)
{
	struct filt *f = alloc(c, sizeof(*f));
	f->kind = kind;
	f->node = FSB_NONE;
	return f;
}

static obj *
filt_obj(struct ctx *c, struct filt *f)
{
	obj *o = mk(c, T_FILTER);
	o->u.f = f;
	return o;
}

static struct filt *
filt_unknown(struct ctx *c, const char *why)
{
	struct filt *f = filt_new(c, F_UNKNOWN);
	f->why = why;
	return f;
}

static struct filt *
filt_combine(struct ctx *c, int kind, struct filt **kids, size_t n)
{
	if (n == 1) {
		return kids[0];
	}
	struct filt *f = filt_new(c, kind);
	f->kids = alloc(c, n * sizeof(*kids));
	memcpy(f->kids, kids, n * sizeof(*kids));
	f->nkids = n;
	return f;
}

/*
 * macOS's pattern variables in path filters: "/Volumes/${ANY_UUID}". A string
 * with them becomes a regex (anchored as the filter's kind requires); a
 * variable only the running process knows makes the filter unknown. NULL if
 * the string has none.
 */
static struct filt *
pattern_filter(struct ctx *c, obj *v, int field, int kind)
{
	const char *s = v->u.str.s, *end = s + v->u.str.n;
	if (!memmem(s, v->u.str.n, "${", 2)) {
		return NULL;
	}
	size_t cap = v->u.str.n * 2 + 256, n = 0;
	char *re = alloc(c, cap);
#define PUT(ch) do { if (n + 2 >= cap) fail(c, "pattern too long"); re[n++] = (ch); } while (0)
	bool regex = kind == F_REGEX;
	if (!regex) {
		PUT('^');
	}
	while (s < end) {
		if (s + 1 < end && s[0] == '$' && s[1] == '{') {
			const char *close = memchr(s, '}', (size_t)(end - s));
			if (!close) {
				fail(c, "unterminated ${ in \"%.*s\"", (int)v->u.str.n, v->u.str.s);
			}
			size_t vn = (size_t)(close - s - 2);
			const char *var = s + 2, *value = NULL;
			char name[64];
			snprintf(name, sizeof(name), "%.*s", (int)vn, var);
			if (!strcmp(name, "ANY_UUID")) {
				value = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}";
				for (const char *q = value; *q; q++) {
					PUT(*q);
				}
			} else if (!strcmp(name, "ANY_USER")) {
				for (const char *q = "[^/]+"; *q; q++) {
					PUT(*q);
				}
			} else {
				for (size_t i = 0; i < c->opt->param_count; i++) {
					if (!strcmp(c->opt->params[i].name, name)) {
						value = c->opt->params[i].value;
					}
				}
				if (!value) {
					return filt_unknown(c, "pattern variable");
				}
				for (const char *q = value; *q; q++) {
					if (strchr("\\.^$|()[]{}*+?", *q)) {
						PUT('\\');
					}
					PUT(*q);
				}
			}
			s = close + 1;
			continue;
		}
		if (!regex && strchr("\\.^$|()[]{}*+?", *s)) {
			PUT('\\');
		}
		PUT(*s);
		s++;
	}
	if (!regex) {
		if (kind == F_STR_EQ) {
			PUT('$');
		} else if (kind == F_SUBPATH) {
			for (const char *q = "(/|$)"; *q; q++) {
				PUT(*q);
			}
		}
	}
#undef PUT
	struct filt *f = filt_new(c, F_REGEX);
	f->field = field;
	f->s = re;
	f->n = n;
	return f;
}

/* A string matcher on a field from one argument: a string, a regex string, or a filter. */
static struct filt *
string_filter(struct ctx *c, obj *v, int field, int kind, const char *who)
{
	if (IS(v, T_FILTER)) {
		return v->u.f;
	}
	if (!IS(v, T_STR)) {
		fail(c, "%s: expected a string, got %s", who, type_name(v->t));
	}
	if (field == FSB_F_PATH) {
		struct filt *p = pattern_filter(c, v, field, kind);
		if (p) {
			return p;
		}
	}
	/* The filter decides whether a string is a regex: #"..." only keeps its
	   backslashes, as macOS's compiler reads it. */
	struct filt *f = filt_new(c, kind);
	f->field = field;
	f->s = v->u.str.s;
	f->n = v->u.str.n;
	if (field == FSB_F_PATH && (f->kind == F_SUBPATH || f->kind == F_STR_EQ)) {
		/* Paths compare without a trailing slash, except "/" itself. */
		while (f->n > 1 && f->s[f->n - 1] == '/') {
			f->n--;
		}
	}
	return f;
}

/* (NAME s ...): any of the strings. */
static obj *
string_filters(struct ctx *c, obj *a, int field, int kind, const char *who)
{
	size_t n = list_length(c, a);
	if (n == 0) {
		fail(c, "%s: no arguments", who);
	}
	struct filt **kids = alloc(c, n * sizeof(*kids));
	for (size_t i = 0; i < n; i++) {
		kids[i] = string_filter(c, arg(c, &a, who), field, kind, who);
	}
	return filt_obj(c, filt_combine(c, F_ANY, kids, n));
}

struct string_filter_def {
	const char *name;
	int field;
	int kind;
};

#define SF(name, field, kind) { name, field, kind }
static const struct string_filter_def string_filter_defs[] = {
	SF("literal", FSB_F_PATH, F_STR_EQ), SF("subpath", FSB_F_PATH, F_SUBPATH),
	SF("prefix", FSB_F_PATH, F_STR_PREFIX), SF("regex", FSB_F_PATH, F_REGEX),
	SF("path", FSB_F_PATH, F_STR_EQ),
	/* resolving-*: macOS resolves symlinks in these at compile time; Finch's
	   kernel compares resolved paths, so they act like the plain filters */
	SF("resolving-literal", FSB_F_PATH, F_STR_EQ), SF("resolving-subpath", FSB_F_PATH, F_SUBPATH),
	SF("resolving-prefix", FSB_F_PATH, F_STR_PREFIX), SF("resolving-regex", FSB_F_PATH, F_REGEX),
	SF("global-name", FSB_F_GLOBAL_NAME, F_STR_EQ), SF("global-name-prefix", FSB_F_GLOBAL_NAME, F_STR_PREFIX),
	SF("global-name-regex", FSB_F_GLOBAL_NAME, F_REGEX),
	SF("local-name", FSB_F_LOCAL_NAME, F_STR_EQ), SF("local-name-prefix", FSB_F_LOCAL_NAME, F_STR_PREFIX),
	SF("local-name-regex", FSB_F_LOCAL_NAME, F_REGEX),
	SF("ipc-posix-name", FSB_F_IPC_POSIX_NAME, F_STR_EQ), SF("ipc-posix-name-prefix", FSB_F_IPC_POSIX_NAME, F_STR_PREFIX),
	SF("ipc-posix-name-regex", FSB_F_IPC_POSIX_NAME, F_REGEX),
	SF("sysctl-name", FSB_F_SYSCTL_NAME, F_STR_EQ), SF("sysctl-name-prefix", FSB_F_SYSCTL_NAME, F_STR_PREFIX),
	SF("sysctl-name-regex", FSB_F_SYSCTL_NAME, F_REGEX),
	SF("notification-name", FSB_F_NOTIFICATION_NAME, F_STR_EQ), SF("notification-name-prefix", FSB_F_NOTIFICATION_NAME, F_STR_PREFIX),
	SF("notification-name-regex", FSB_F_NOTIFICATION_NAME, F_REGEX),
	SF("preference-domain", FSB_F_PREFERENCE_DOMAIN, F_STR_EQ), SF("preference-domain-prefix", FSB_F_PREFERENCE_DOMAIN, F_STR_PREFIX),
	SF("preference-domain-regex", FSB_F_PREFERENCE_DOMAIN, F_REGEX),
	SF("iokit-user-client-class", FSB_F_IOKIT_USER_CLIENT_CLASS, F_STR_EQ),
	SF("iokit-user-client-class-prefix", FSB_F_IOKIT_USER_CLIENT_CLASS, F_STR_PREFIX),
	SF("iokit-user-client-class-regex", FSB_F_IOKIT_USER_CLIENT_CLASS, F_REGEX),
	SF("iokit-registry-entry-class", FSB_F_IOKIT_REGISTRY_ENTRY_CLASS, F_STR_EQ),
	SF("iokit-registry-entry-class-prefix", FSB_F_IOKIT_REGISTRY_ENTRY_CLASS, F_STR_PREFIX),
	SF("iokit-registry-entry-class-regex", FSB_F_IOKIT_REGISTRY_ENTRY_CLASS, F_REGEX),
	SF("iokit-property", FSB_F_IOKIT_PROPERTY, F_STR_EQ), SF("iokit-property-prefix", FSB_F_IOKIT_PROPERTY, F_STR_PREFIX),
	SF("iokit-property-regex", FSB_F_IOKIT_PROPERTY, F_REGEX),
	SF("xattr", FSB_F_XATTR, F_STR_EQ), SF("xattr-prefix", FSB_F_XATTR, F_STR_PREFIX), SF("xattr-regex", FSB_F_XATTR, F_REGEX),
	SF("nvram-variable", FSB_F_NVRAM_VARIABLE, F_STR_EQ), SF("nvram-variable-prefix", FSB_F_NVRAM_VARIABLE, F_STR_PREFIX),
	SF("nvram-variable-regex", FSB_F_NVRAM_VARIABLE, F_REGEX),
	SF("right-name", FSB_F_RIGHT_NAME, F_STR_EQ), SF("right-name-prefix", FSB_F_RIGHT_NAME, F_STR_PREFIX),
	SF("right-name-regex", FSB_F_RIGHT_NAME, F_REGEX),
	SF("xpc-service-name", FSB_F_XPC_SERVICE_NAME, F_STR_EQ), SF("xpc-service-name-prefix", FSB_F_XPC_SERVICE_NAME, F_STR_PREFIX),
	SF("xpc-service-name-regex", FSB_F_XPC_SERVICE_NAME, F_REGEX),
	SF("control-name", FSB_F_CONTROL_NAME, F_STR_EQ), SF("control-name-prefix", FSB_F_CONTROL_NAME, F_STR_PREFIX),
	SF("kext-bundle-id", FSB_F_KEXT_BUNDLE_ID, F_STR_EQ),
	SF("signing-identifier", FSB_F_SIGNING_IDENTIFIER, F_STR_EQ),
	SF("mac-policy-name", FSB_F_MAC_POLICY_NAME, F_STR_EQ),
	SF("process-path", FSB_F_PROCESS_PATH, F_STR_EQ), SF("process-path-prefix", FSB_F_PROCESS_PATH, F_STR_PREFIX),
	SF("process-path-regex", FSB_F_PROCESS_PATH, F_REGEX),
};

static obj *
p_string_filter(struct ctx *c, obj *a, env *e)
{
	(void)e;
	/* the definition rides in the first (hidden) argument */
	const struct string_filter_def *d = (const void *)(uintptr_t)CAR(a)->u.i;
	return string_filters(c, CDR(a), d->field, d->kind, d->name);
}

/* (require-any f ...), (require-all f ...), (require-not f) */
static struct filt *
as_filter(struct ctx *c, obj *v, const char *who)
{
	if (IS(v, T_FILTER)) {
		return v->u.f;
	}
	if (IS(v, T_BOOL)) {
		return filt_new(c, v->u.i ? F_TRUE : F_FALSE);
	}
	fail(c, "%s: expected a filter, got %s", who, type_name(v->t));
}

static obj *
combine_args(struct ctx *c, obj *a, int kind, const char *who)
{
	size_t n = list_length(c, a);
	if (n == 0) {
		fail(c, "%s: argument expected but none provided", who);
	}
	struct filt **kids = alloc(c, n * sizeof(*kids));
	for (size_t i = 0; i < n; i++) {
		kids[i] = as_filter(c, arg(c, &a, who), who);
	}
	return filt_obj(c, filt_combine(c, kind, kids, n));
}

static obj *p_require_any(struct ctx *c, obj *a, env *e) { (void)e; return combine_args(c, a, F_ANY, "require-any"); }
static obj *p_require_all(struct ctx *c, obj *a, env *e) { (void)e; return combine_args(c, a, F_ALL, "require-all"); }

static obj *
p_require_not(struct ctx *c, obj *a, env *e)
{
	(void)e;
	struct filt *f = filt_new(c, F_NOT);
	f->kids = alloc(c, sizeof(*f->kids));
	f->kids[0] = as_filter(c, arg(c, &a, "require-not"), "require-not");
	f->nkids = 1;
	no_more(c, a, "require-not");
	return filt_obj(c, f);
}

/* Numeric filters. Their arguments may be numbers or symbolic constants
   (SYS_open, AF_UNIX, ...); an unknown constant gives an unknown filter. */
static struct filt *
num_filter(struct ctx *c, obj *v, int field, int kind, const char *who)
{
	struct filt *f = filt_new(c, kind);
	f->field = field;
	if (IS(v, T_INT)) {
		f->num = (uint64_t)v->u.i;
		return f;
	}
	if (IS(v, T_FILTER)) {
		return v->u.f;
	}
	if (IS(v, T_SYM)) {
		long long value;
		if (sbpl_constant(v->u.str.s, &value)) {
			f->num = (uint64_t)value;
			return f;
		}
		return filt_unknown(c, v->u.str.s);
	}
	fail(c, "%s: expected a number or a constant", who);
}

static obj *
num_filters_special(struct ctx *c, obj *a, env *e, int field, int kind, const char *who)
{
	size_t n = list_length(c, a);
	if (n == 0) {
		fail(c, "%s: no arguments", who);
	}
	struct filt **kids = alloc(c, n * sizeof(*kids));
	for (size_t i = 0; i < n; i++) {
		obj *x = arg(c, &a, who);
		/* A bound symbol is a variable; an unbound one, a constant name. */
		if (IS(x, T_SYM) && lookup(e, x)) {
			x = eval(c, x, e);
		} else if (!IS(x, T_SYM)) {
			x = eval(c, x, e);
		}
		kids[i] = num_filter(c, x, field, kind, who);
	}
	return filt_obj(c, filt_combine(c, F_ANY, kids, n));
}

#define NUMF(fn, field, who) \
	static obj *fn(struct ctx *c, obj *a, env *e) { return num_filters_special(c, a, e, field, F_NUM_EQ, who); }
NUMF(p_syscall_number, FSB_F_SYSCALL_NUMBER, "syscall-number")
NUMF(p_machtrap_number, FSB_F_MACHTRAP_NUMBER, "machtrap-number")
NUMF(p_kernel_mig_routine, FSB_F_KERNEL_MIG_ROUTINE, "kernel-mig-routine")
NUMF(p_ioctl_command, FSB_F_IOCTL_COMMAND, "ioctl-command")
NUMF(p_fsctl_command, FSB_F_FSCTL_COMMAND, "fsctl-command")
NUMF(p_fcntl_command, FSB_F_FCNTL_COMMAND, "fcntl-command")
NUMF(p_iokit_method_number, FSB_F_IOKIT_METHOD_NUMBER, "iokit-method-number")
NUMF(p_privilege_id, FSB_F_PRIVILEGE_ID, "privilege-id")
NUMF(p_uid, FSB_F_UID, "uid")
NUMF(p_message_number, FSB_F_MESSAGE_NUMBER, "message-number")
NUMF(p_mac_syscall_number, FSB_F_MAC_SYSCALL_NUMBER, "mac-syscall-number")
NUMF(p_socket_domain, FSB_F_SOCKET_DOMAIN, "socket-domain")
NUMF(p_socket_type, FSB_F_SOCKET_TYPE, "socket-type")
NUMF(p_socket_protocol, FSB_F_SOCKET_PROTOCOL, "socket-protocol")
NUMF(p_socket_option_level, FSB_F_SOCKET_OPTION_LEVEL, "socket-option-level")
NUMF(p_socket_option_name, FSB_F_SOCKET_OPTION_NAME, "socket-option-name")

static obj *
p_file_mode(struct ctx *c, obj *a, env *e)
{
	return num_filters_special(c, a, e, FSB_F_FILE_MODE, F_NUM_BITS, "file-mode");
}

/* (target self|others|children|parent|same-sandbox) */
static obj *
p_target(struct ctx *c, obj *a, env *e)
{
	(void)e;
	size_t n = list_length(c, a);
	uint64_t bits = 0;
	for (size_t i = 0; i < n; i++) {
		obj *x = arg(c, &a, "target");
		const char *s = IS(x, T_SYM) || IS(x, T_STR) ? x->u.str.s : "";
		if (!strcmp(s, "self")) bits |= FSB_TARGET_SELF;
		else if (!strcmp(s, "others")) bits |= FSB_TARGET_OTHERS;
		else if (!strcmp(s, "same-sandbox")) bits |= FSB_TARGET_SAME_SANDBOX;
		else if (!strcmp(s, "children")) bits |= FSB_TARGET_CHILDREN;
		else if (!strcmp(s, "parent")) bits |= FSB_TARGET_PARENT;
		else return filt_obj(c, filt_unknown(c, "target"));
	}
	struct filt *f = filt_new(c, F_NUM_EQ);
	f->field = FSB_F_TARGET;
	f->num = bits;
	return filt_obj(c, f);
}

/* (vnode-type REGULAR-FILE DIRECTORY ...) */
static obj *
p_vnode_type(struct ctx *c, obj *a, env *e)
{
	(void)e;
	static const struct { const char *name; int v; } types[] = {
		{ "REGULAR-FILE", FSB_VNODE_REGULAR }, { "DIRECTORY", FSB_VNODE_DIRECTORY },
		{ "BLOCK-DEVICE", FSB_VNODE_BLOCK_DEVICE }, { "CHARACTER-DEVICE", FSB_VNODE_CHARACTER_DEVICE },
		{ "SYMLINK", FSB_VNODE_SYMLINK }, { "SOCKET", FSB_VNODE_SOCKET }, { "FIFO", FSB_VNODE_FIFO },
		{ "TTY", FSB_VNODE_TTY },
	};
	size_t n = list_length(c, a);
	struct filt **kids = alloc(c, (n ? n : 1) * sizeof(*kids));
	for (size_t i = 0; i < n; i++) {
		obj *x = arg(c, &a, "vnode-type");
		kids[i] = NULL;
		for (size_t k = 0; k < sizeof(types) / sizeof(types[0]); k++) {
			if ((IS(x, T_SYM) || IS(x, T_STR)) && !strcmp(x->u.str.s, types[k].name)) {
				kids[i] = filt_new(c, F_NUM_EQ);
				kids[i]->field = FSB_F_VNODE_TYPE;
				kids[i]->num = (uint64_t)types[k].v;
			}
		}
		if (!kids[i]) {
			kids[i] = filt_unknown(c, "vnode-type");
		}
	}
	if (n == 0) {
		fail(c, "vnode-type: no arguments");
	}
	return filt_obj(c, filt_combine(c, F_ANY, kids, n));
}

/* (file-attribute NAME) and (process-attribute NAME): attribute bits */
static obj *
attribute_filter(struct ctx *c, obj *a, int field, const char *who)
{
	static const struct { const char *name; int field; uint32_t bit; } attrs[] = {
		{ "union-mounted-filesystem", FSB_F_FILE_ATTRIBUTES, FSB_FILE_ATTR_UNION_MOUNTED_FILESYSTEM },
		{ "has-multiple-names", FSB_F_FILE_ATTRIBUTES, FSB_FILE_ATTR_HAS_MULTIPLE_NAMES },
		{ "apfs-preboot-volume", FSB_F_FILE_ATTRIBUTES, FSB_FILE_ATTR_APFS_PREBOOT_VOLUME },
		{ "apfs-recovery-volume", FSB_F_FILE_ATTRIBUTES, FSB_FILE_ATTR_APFS_RECOVERY_VOLUME },
		{ "fileprovider-owned", FSB_F_FILE_ATTRIBUTES, FSB_FILE_ATTR_FILEPROVIDER_OWNED },
		{ "is-platform-binary", FSB_F_PROCESS_ATTRIBUTES, FSB_PROCESS_ATTR_IS_PLATFORM_BINARY },
		{ "is-apple-signed-executable", FSB_F_PROCESS_ATTRIBUTES, FSB_PROCESS_ATTR_IS_APPLE_SIGNED },
		{ "is-restricted", FSB_F_PROCESS_ATTRIBUTES, FSB_PROCESS_ATTR_IS_RESTRICTED },
		{ "is-plugin", FSB_F_PROCESS_ATTRIBUTES, FSB_PROCESS_ATTR_IS_PLUGIN },
	};
	obj *x = arg(c, &a, who);
	no_more(c, a, who);
	const char *name = IS(x, T_SYM) || IS(x, T_STR) ? x->u.str.s : "";
	for (size_t i = 0; i < sizeof(attrs) / sizeof(attrs[0]); i++) {
		if (attrs[i].field == field && !strcmp(attrs[i].name, name)) {
			struct filt *f = filt_new(c, F_NUM_BITS);
			f->field = field;
			f->num = attrs[i].bit;
			return filt_obj(c, f);
		}
	}
	fail(c, "%s: unknown attribute %s", who, name);
}

static obj *p_file_attribute(struct ctx *c, obj *a, env *e) { (void)e; return attribute_filter(c, a, FSB_F_FILE_ATTRIBUTES, "file-attribute"); }
static obj *p_process_attribute(struct ctx *c, obj *a, env *e) { (void)e; return attribute_filter(c, a, FSB_F_PROCESS_ATTRIBUTES, "process-attribute"); }

/* (extension "class" ...): the caller holds an extension of one of these
   classes covering the request (FinchSandbox keeps consumed extensions). */
static obj *
p_extension(struct ctx *c, obj *a, env *e)
{
	(void)e;
	struct filt *kids[16];
	size_t n = 0;
	while (IS(a, T_PAIR) && n < 16) {
		obj *cls = arg(c, &a, "extension");
		if (!IS(cls, T_STR) || cls->u.str.n == 0) {
			return filt_obj(c, filt_unknown(c, "extension"));
		}
		struct filt *f = filt_new(c, F_EXTENSION);
		f->s = cls->u.str.s;
		f->n = cls->u.str.n;
		kids[n++] = f;
	}
	if (n == 0 || !IS(a, T_NIL)) {
		return filt_obj(c, filt_unknown(c, "extension"));
	}
	return filt_obj(c, filt_combine(c, F_ANY, kids, n));
}

/* Filters Finch can't evaluate (yet): sandbox extensions, entitlement checks
   at run time, process attributes, network addresses, ... */
static obj *
p_unknown_filter(struct ctx *c, obj *a, env *e)
{
	(void)a;
	(void)e;
	return filt_obj(c, filt_unknown(c, c->calling ? c->calling : "filter"));
}

static obj *
p_unknown_special(struct ctx *c, obj *a, env *e)
{
	/* arguments may be bare constant symbols (tcp, ip, ...): not evaluated */
	(void)a;
	(void)e;
	return filt_obj(c, filt_unknown(c, c->calling ? c->calling : "filter"));
}

/* ==== rules ==== */

static obj *
p_with_modifier(struct ctx *c, obj *a, env *e)
{
	/* (with report), (with no-report), (with send-signal SIGKILL), (with message "x") */
	(void)e;
	obj *what = arg(c, &a, "with");
	obj *m = mk(c, T_MODIFIER);
	const char *s = IS(what, T_SYM) ? what->u.str.s : "";
	if (!strcmp(s, "report")) {
		m->u.mod.set = FSB_RULE_REPORT;
	} else if (!strcmp(s, "no-report") || !strcmp(s, "no-log")) {
		m->u.mod.set = FSB_RULE_NO_REPORT;
	}
	m->u.mod.what = s;
	return m;
}

static void
add_rule(struct ctx *c, uint32_t op, uint32_t flags, struct filt *f)
{
	if (c->nrules == c->caprules) {
		size_t cap = c->caprules ? c->caprules * 2 : 256;
		struct rule *r = realloc(c->rules, cap * sizeof(*r));
		if (!r) {
			fail(c, "out of memory");
		}
		c->rules = r;
		c->caprules = cap;
	}
	c->rules[c->nrules].op = op;
	c->rules[c->nrules].flags = flags;
	c->rules[c->nrules].f = f;
	c->nrules++;
}

/*
 * Operation names macOS's compiler takes besides the kernel table's
 * (tools/sandbox/ops.txt): older names and wildcards over a few operations.
 */
static const struct {
	const char *name;
	const char *ops[3];
} op_aliases[] = {
	{ "iokit-open", { "iokit-open-user-client" } },
	{ "ipc-posix-sem", { "ipc-posix-sem*" } },
	{ "ipc-posix-shm", { "ipc-posix-shm*" } },
	{ "ipc-posix-shm-read*", { "ipc-posix-shm-read-data" } },
	{ "process-exec", { "process-exec*" } },
	{ "file-issue-extension*", { "file-issue-extension" } },
	{ "managed-preference*", { "managed-preference-read" } },
	/* accepted, but no longer an operation: it grants nothing (a lookup is
	   mach-lookup's to allow) */
	{ "mach-per-user-lookup", { NULL } },
	{ "file-fsctl", { "system-fsctl" } },
	{ "file-unlink", { "file-write-unlink" } },
	{ "file-write-mount", { "file-mount" } },
	{ "file-write-umount", { "file-unmount" } },
	{ "ipc-posix-shm-read-metadata", { "ipc-posix-shm-read-data" } },
	{ "process-codesigning*", { "process-codesigning", "process-legacy-codesigning*" } },
	{ "process-codesigning-status*", { "process-legacy-codesigning-status*" } },
	{ "process-codesigning-blob-get", { "process-legacy-codesigning-blob-get" } },
	{ "process-codesigning-cdhash-get", { "process-legacy-codesigning-cdhash-get" } },
	{ "process-codesigning-entitlements-blob-get", { "process-legacy-codesigning-entitlements-blob-get" } },
	{ "process-codesigning-entitlements-der-blob-get", { "process-legacy-codesigning-entitlements-der-blob-get" } },
	{ "process-codesigning-identity-get", { "process-legacy-codesigning-identity-get" } },
	{ "process-codesigning-status-get", { "process-legacy-codesigning-status-get" } },
	{ "process-codesigning-status-set", { "process-legacy-codesigning-status-set" } },
	{ "process-codesigning-teamid-get", { "process-legacy-codesigning-teamid-get" } },
	{ "process-codesigning-text-offset-get", { "process-legacy-codesigning-text-offset-get" } },
};

/* The operations a name stands for (possibly none); -1 if it isn't an operation name. */
static int
resolve_op(const char *name, size_t n, uint32_t out[3])
{
	uint32_t op = fsb_op_lookup(name, n);
	if (op != FSB_NONE) {
		out[0] = op;
		return 1;
	}
	for (size_t i = 0; i < sizeof(op_aliases) / sizeof(op_aliases[0]); i++) {
		if (strlen(op_aliases[i].name) == n && memcmp(op_aliases[i].name, name, n) == 0) {
			int k = 0;
			for (; k < 3 && op_aliases[i].ops[k]; k++) {
				out[k] = fsb_op_lookup(op_aliases[i].ops[k], strlen(op_aliases[i].ops[k]));
			}
			return k;
		}
	}
	return -1;
}

static obj *
rule_form(struct ctx *c, obj *a, env *e, bool deny)
{
	const char *who = deny ? "deny" : "allow";
	uint32_t ops[FSB_OP_COUNT];
	size_t nops = 0;
	struct filt *filters[256];
	size_t nfilters = 0;
	uint32_t flags = (deny ? FSB_RULE_DENY : 0) | c->with_flags;

	for (; IS(a, T_PAIR); a = CDR(a)) {
		obj *x = CAR(a);
		if (IS(x, T_SYM)) {
			uint32_t found[3];
			int k = resolve_op(x->u.str.s, x->u.str.n, found);
			if (k >= 0) {
				for (int j = 0; j < k && nops < FSB_OP_COUNT; j++) {
					ops[nops++] = found[j];
				}
				continue;
			}
			/* Otherwise a variable holding a filter or a list; an unknown
			   operation name fails as an unbound variable, as macOS's does. */
		}
		obj *v = eval(c, x, e);
		if (IS(v, T_FILTER)) {
			if (nfilters == sizeof(filters) / sizeof(filters[0])) {
				fail(c, "%s: too many filters", who);
			}
			filters[nfilters++] = v->u.f;
		} else if (IS(v, T_MODIFIER)) {
			flags |= v->u.mod.set;
		} else {
			/* Anything else (a list, a boolean, nothing) is refused, as macOS's
			   compiler refuses it: dropping it could widen the rule. */
			fail(c, "illegal argument: %s", type_name(v->t));
		}
	}
	if (deny && (flags & FSB_RULE_REPORT)) {
		fail(c, "report modifier does not apply to deny action");
	}
	struct filt *f = nfilters ? filt_combine(c, F_ANY, filters, nfilters) : NULL;
	if (c->nwith > 0) {
		struct filt **all = alloc(c, (c->nwith + 1) * sizeof(*all));
		memcpy(all, c->with_filters, c->nwith * sizeof(*all));
		size_t n = c->nwith;
		if (f) {
			all[n++] = f;
		}
		f = filt_combine(c, F_ALL, all, n);
	}
	for (size_t i = 0; i < nops; i++) {
		add_rule(c, ops[i], flags, f);
	}
	return c->unspec;
}

static obj *sf_allow(struct ctx *c, obj *a, env *e) { return rule_form(c, a, e, false); }
static obj *sf_deny(struct ctx *c, obj *a, env *e) { return rule_form(c, a, e, true); }

static obj *
sf_with_filter(struct ctx *c, obj *a, env *e)
{
	struct filt *f = as_filter(c, eval(c, arg(c, &a, "with-filter"), e), "with-filter");
	if (c->nwith == c->capwith) {
		size_t cap = c->capwith ? c->capwith * 2 : 8;
		struct filt **w = alloc(c, cap * sizeof(*w));
		if (c->nwith) {
			memcpy(w, c->with_filters, c->nwith * sizeof(*w));
		}
		c->with_filters = w;
		c->capwith = cap;
	}
	c->with_filters[c->nwith++] = f;
	eval_body(c, a, e);
	c->nwith--;
	return c->unspec;
}

static obj *
sf_with(struct ctx *c, obj *a, env *e)
{
	/* (with report), (with send-signal SIGKILL), (with message "..."): a modifier
	   for the rule it appears in. Arguments after the name aren't evaluated. */
	return p_with_modifier(c, cons(c, arg(c, &a, "with"), c->nil), e);
}

/* (with-modifier (with no-report) body...): the modifier on every rule inside */
static obj *
sf_with_modifier(struct ctx *c, obj *a, env *e)
{
	obj *m = eval(c, arg(c, &a, "with-modifier"), e);
	if (!IS(m, T_MODIFIER)) {
		fail(c, "with-modifier: expected a modifier");
	}
	uint32_t saved = c->with_flags;
	c->with_flags |= m->u.mod.set;
	eval_body(c, a, e);
	c->with_flags = saved;
	return c->unspec;
}

static obj *
sf_apply_message_filter(struct ctx *c, obj *a, env *e)
{
	/* (allow iokit-open-user-client (apply-message-filter (deny ...) (allow ...)))
	   nests per-message rules. FinchSandbox has no message hooks: rules
	   inside are added as rules on their own message operations. */
	eval_body(c, a, e);
	obj *m = mk(c, T_MODIFIER);
	m->u.mod.what = "apply-message-filter";
	return m;
}

static obj *
sf_version(struct ctx *c, obj *a, env *e)
{
	obj *v = eval(c, arg(c, &a, "version"), e);
	if (!IS(v, T_INT) || v->u.i < 1 || v->u.i > 3) {
		fail(c, "version: unsupported");
	}
	/* The profile's own version decides; an imported file's doesn't change it. */
	if (c->import_depth == 0) {
		c->version = (int)v->u.i;
	}
	return c->unspec;
}

/* (sbpl-version-compatible? n): the profile declared (version n) or older */
static obj *
p_version_compatible(struct ctx *c, obj *a, env *e)
{
	(void)e;
	long long n = num_arg(c, &a, "sbpl-version-compatible?");
	return mkbool(c, (c->version ? c->version : 1) <= n);
}

static obj *
sf_debug(struct ctx *c, obj *a, env *e)
{
	(void)e;
	obj *what = arg(c, &a, "debug");
	if (IS(what, T_SYM) && !strcmp(what->u.str.s, "deny")) {
		c->profile_flags |= FSB_PROFILE_DEBUG_DENIALS;
	}
	return c->unspec;
}

static obj *
sf_ignore(struct ctx *c, obj *a, env *e)
{
	(void)a;
	(void)e;
	return c->unspec;
}

/* (path-ancestors "/a/b/c" ...): the folders above each path ("/", "/a", "/a/b") */
static obj *
p_path_ancestors(struct ctx *c, obj *a, env *e)
{
	(void)e;
	struct filt *kids[512];
	size_t n = 0;
	for (; IS(a, T_PAIR); a = CDR(a)) {
		obj *p = CAR(a);
		if (!IS(p, T_STR)) {
			fail(c, "path-ancestors: expected strings");
		}
		for (size_t i = 0; i < p->u.str.n; i++) {
			if (p->u.str.s[i] != '/' || n == sizeof(kids) / sizeof(kids[0])) {
				continue;
			}
			struct filt *f = filt_new(c, F_STR_EQ);
			f->field = FSB_F_PATH;
			f->s = p->u.str.s;
			f->n = i ? i : 1;
			kids[n++] = f;
		}
	}
	return filt_obj(c, n ? filt_combine(c, F_ANY, kids, n) : filt_new(c, F_FALSE));
}

/* (_IO "g" n): the ioctl/fsctl command number <sys/ioccom.h>'s _IO makes */
static obj *
p_io(struct ctx *c, obj *a, env *e)
{
	(void)e;
	obj *g = arg(c, &a, "_IO");
	long long group = IS(g, T_STR) && g->u.str.n == 1 ? (unsigned char)g->u.str.s[0] :
	    IS(g, T_CHAR) || IS(g, T_INT) ? g->u.i : -1;
	if (group < 0) {
		fail(c, "_IO: expected a one-letter group");
	}
	long long n = num_arg(c, &a, "_IO");
	return mkint(c, 0x20000000LL | ((group & 0xff) << 8) | (n & 0xff));
}

/* (variable-quote s): macOS escapes ${...} pattern variables with it; Finch
   has none, so strings stay as they are. */
static obj *
p_variable_quote(struct ctx *c, obj *a, env *e)
{
	(void)e;
	return arg_type(c, &a, T_STR, "variable-quote");
}

static obj *
p_regex_quote(struct ctx *c, obj *a, env *e)
{
	(void)e;
	obj *s = arg_type(c, &a, T_STR, "regex-quote");
	char *buf = alloc(c, s->u.str.n * 2 + 1);
	size_t n = 0;
	for (size_t i = 0; i < s->u.str.n; i++) {
		if (strchr("\\.^$|()[]{}*+?", s->u.str.s[i])) {
			buf[n++] = '\\';
		}
		buf[n++] = s->u.str.s[i];
	}
	obj *o = mk(c, T_STR);
	o->u.str.s = buf;
	o->u.str.n = n;
	o->u.str.regex = true;
	return o;
}

/* ==== the global environment ==== */

static void
prim(struct ctx *c, const char *name, prim_fn fn, bool special)
{
	obj *o = mk(c, T_PRIM);
	o->u.prim.fn = fn;
	o->u.prim.name = name;
	o->u.prim.special = special;
	define(c, c->global, sym(c, name), o);
}

/* A string filter is a primitive with its definition bound as the first argument. */
static obj *
string_filter_trampoline(struct ctx *c, obj *a, env *e)
{
	(void)c;
	(void)a;
	(void)e;
	return NULL;
}

static void
setup(struct ctx *c)
{
	c->global = env_new(c, NULL);
	c->global->table_size = 1024;
	c->global->table = alloc(c, c->global->table_size * sizeof(*c->global->table));
	c->nil = mk(c, T_NIL);
	c->t = mk(c, T_BOOL);
	c->t->u.i = 1;
	c->f = mk(c, T_BOOL);
	c->unspec = mk(c, T_UNSPEC);

	static const struct { const char *name; prim_fn fn; bool special; } prims[] = {
		{ "quote", sf_quote, true }, { "quasiquote", sf_quasiquote, true }, { "if", sf_if, true },
		{ "define", sf_define, true }, { "set!", sf_set, true }, { "lambda", sf_lambda, true },
		{ "begin", sf_begin, true }, { "let", sf_let, true }, { "let*", sf_letstar, true },
		{ "letrec", sf_letrec, true }, { "letrec*", sf_letrec, true }, { "and", sf_and, true },
		{ "or", sf_or, true }, { "when", sf_when, true }, { "unless", sf_unless, true },
		{ "cond", sf_cond, true }, { "defined?", sf_defined, true },
		{ "allow", sf_allow, true }, { "deny", sf_deny, true }, { "with-filter", sf_with_filter, true },
		{ "with", sf_with, true }, { "version", sf_version, true }, { "debug", sf_debug, true },
		{ "apply-message-filter", sf_apply_message_filter, true }, { "trace", sf_ignore, true },
		{ "macro", sf_macro, true }, { "disable-callouts", sf_ignore, true },
		{ "disable-full-symbolication", sf_ignore, true }, { "disable-syscall-filtering", sf_ignore, true },
		{ "%unknown-filter", p_unknown_filter, false }, { "_IO", p_io, false },
		{ "sbpl-version-compatible?", p_version_compatible, false },
		{ "split-string", p_split_string, false }, { "char=?", p_char_eq, false },
		{ "atom?", p_atomp, false }, { "flatten", p_flatten, false }, { "with-modifier", sf_with_modifier, true },
		{ "target-signing-identifier", p_unknown_filter, false },
		{ "container", p_unknown_filter, false }, { "application-group", p_unknown_filter, false },
		{ "device-conforms-to", p_unknown_special, true }, { "filesystem-name", p_unknown_special, true },
		{ "process-is-plugin", p_unknown_filter, false }, { "semaphore-owner", p_unknown_special, true },
		{ "necp-client-action", p_unknown_special, true }, { "variable-quote", p_variable_quote, false },
		{ "iokit-connection", p_unknown_special, true }, { "info-type", p_unknown_special, true },
		{ "file-attribute", p_file_attribute, true }, { "appleevent-destination", p_unknown_special, true },
		{ "codesigning-operation", p_unknown_special, true }, { "daemon-container", p_unknown_special, true },
		{ "extension-path-ancestor", p_unknown_filter, false }, { "extension-class-regex", p_unknown_filter, false },
		{ "extension-class-prefix", p_unknown_filter, false }, { "%entitlement-is-present", p_unknown_filter, false },
		{ "mount-relative-literal", p_unknown_filter, false }, { "mount-relative-subpath", p_unknown_filter, false },
		{ "mount-relative-prefix", p_unknown_filter, false }, { "mount-relative-regex", p_unknown_filter, false },
		{ "syscall-number", p_syscall_number, true }, { "machtrap-number", p_machtrap_number, true },
		{ "kernel-mig-routine", p_kernel_mig_routine, true }, { "ioctl-command", p_ioctl_command, true },
		{ "fsctl-command", p_fsctl_command, true }, { "fcntl-command", p_fcntl_command, true },
		{ "iokit-method-number", p_iokit_method_number, true }, { "privilege-id", p_privilege_id, true },
		{ "uid", p_uid, true }, { "message-number", p_message_number, true },
		{ "mac-syscall-number", p_mac_syscall_number, true }, { "socket-domain", p_socket_domain, true },
		{ "socket-type", p_socket_type, true }, { "socket-protocol", p_socket_protocol, true },
		{ "socket-option-level", p_socket_option_level, true }, { "socket-option-name", p_socket_option_name, true },
		{ "file-mode", p_file_mode, true }, { "target", p_target, true }, { "vnode-type", p_vnode_type, true },
		{ "remote", p_unknown_special, true }, { "local", p_unknown_special, true },
		{ "process-attribute", p_process_attribute, true }, { "system-attribute", p_false, true },
		{ "state-flag", p_unknown_filter, false }, { "extension", p_extension, false },
		{ "extension-class", p_unknown_filter, false }, { "require-entitlement", p_unknown_filter, false },
		{ "entitlement-is-present", p_unknown_filter, false }, { "entitlement-is-bool-true", p_unknown_filter, false },
		{ "entitlement-value", p_unknown_filter, false }, { "storage-class", p_unknown_filter, false },
		{ "storage-class-extension", p_unknown_filter, false }, { "debug-mode", p_unknown_filter, false },
		{ "require-any", p_require_any, false }, { "require-all", p_require_all, false },
		{ "require-not", p_require_not, false },
		{ "param", p_param, false }, { "entitlement", p_entitlement, false },
		{ "sandbox-array-entitlement", p_array_entitlement, false }, { "import", p_import, false },
		{ "regex-quote", p_regex_quote, false }, { "path-ancestors", p_path_ancestors, false },
		{ "equal?", p_equal, false }, { "eq?", p_eq, false }, { "eqv?", p_eq, false }, { "not", p_not, false },
		{ "car", p_car, false }, { "cdr", p_cdr, false }, { "cadr", p_cadr, false }, { "cddr", p_cddr, false },
		{ "cons", p_cons, false }, { "list", p_list, false }, { "null?", p_nullp, false },
		{ "pair?", p_pairp, false }, { "list?", p_listp, false }, { "string?", p_stringp, false },
		{ "symbol?", p_symbolp, false }, { "number?", p_numberp, false }, { "integer?", p_numberp, false },
		{ "boolean?", p_booleanp, false }, { "procedure?", p_procedurep, false },
		{ "length", p_length, false }, { "append", p_append, false }, { "reverse", p_reverse, false },
		{ "map", p_map, false }, { "for-each", p_for_each, false }, { "apply", p_apply, false },
		{ "filter", p_filter, false }, { "member", p_member, false }, { "assoc", p_assoc, false },
		{ "list-ref", p_list_ref, false },
		{ "+", p_add, false }, { "-", p_sub, false }, { "*", p_mul, false }, { "=", p_numeq, false },
		{ "<", p_lt, false }, { ">", p_gt, false }, { "<=", p_le, false }, { ">=", p_ge, false },
		{ "zero?", p_zerop, false }, { "positive?", p_positivep, false }, { "negative?", p_negativep, false },
		{ "logior", p_logior, false }, { "logand", p_logand, false },
		{ "string-append", p_string_append, false }, { "string-length", p_string_length, false },
		{ "substring", p_substring, false }, { "string=?", p_string_eq, false },
		{ "string-prefix?", p_string_prefixp, false }, { "string-suffix?", p_string_suffixp, false },
		{ "symbol->string", p_symbol_to_string, false }, { "string->symbol", p_string_to_symbol, false },
		{ "number->string", p_number_to_string, false }, { "string->number", p_string_to_number, false },
		{ "string", p_string, false }, { "string->list", p_string_to_list, false },
		{ "list->string", p_list_to_string, false }, { "string-ref", p_string_ref, false },
		{ "char-upcase", p_char_upcase, false }, { "char-downcase", p_char_downcase, false },
		{ "error", p_error, false },
	};
	for (size_t i = 0; i < sizeof(prims) / sizeof(prims[0]); i++) {
		prim(c, prims[i].name, prims[i].fn, prims[i].special);
	}
	/* String filters: a closure over their definition. */
	for (size_t i = 0; i < sizeof(string_filter_defs) / sizeof(string_filter_defs[0]); i++) {
		obj *def = mkint(c, (long long)(uintptr_t)&string_filter_defs[i]);
		obj *inner = mk(c, T_PRIM);
		inner->u.prim.fn = p_string_filter;
		inner->u.prim.name = string_filter_defs[i].name;
		/* (lambda args (apply inner def args)) without the reader: */
		obj *args = sym(c, "args");
		obj *body = cons(c, cons(c, sym(c, "apply"), cons(c, inner, cons(c, def, cons(c, args, c->nil)))), c->nil);
		define(c, c->global, sym(c, string_filter_defs[i].name), make_closure(c, args, body, c->global));
	}
	(void)string_filter_trampoline;
	/* Modifiers used bare: (allow op (with report)) is handled by "with". */
	define(c, c->global, sym(c, "else"), c->t);
	/* the file being imported, or #f in the top-level profile */
	define(c, c->global, sym(c, "*import-path*"), c->f);
	/* macOS's prelude constants */
	define(c, c->global, sym(c, "apple-internal"), sym(c, "apple-internal"));
}

/* ==== lowering and emission ==== */

struct emitter {
	struct ctx *c;
	struct fsb_node *nodes;
	uint32_t nnodes, capnodes;
	uint32_t *children;
	uint32_t nchildren, capchildren;
	uint8_t *data;
	uint32_t ndata, capdata;
	uint32_t true_node, false_node;
};

static void *
grow(struct ctx *c, void *p, uint32_t *cap, uint32_t need, size_t elem)
{
	if (need <= *cap) {
		return p;
	}
	uint32_t n = *cap ? *cap : 64;
	while (n < need) {
		n *= 2;
	}
	void *q = realloc(p, (size_t)n * elem);
	if (!q) {
		fail(c, "out of memory");
	}
	*cap = n;
	return q;
}

static uint32_t
add_node(struct emitter *m, uint16_t kind, uint16_t field, uint32_t a, uint32_t b)
{
	m->nodes = grow(m->c, m->nodes, &m->capnodes, m->nnodes + 1, sizeof(*m->nodes));
	m->nodes[m->nnodes] = (struct fsb_node){ kind, field, a, b };
	return m->nnodes++;
}

static uint32_t
add_data(struct emitter *m, const void *p, size_t n, size_t align)
{
	uint32_t at = (uint32_t)((m->ndata + align - 1) & ~(align - 1));
	m->data = grow(m->c, m->data, &m->capdata, at + (uint32_t)n + 1, 1);
	memset(m->data + m->ndata, 0, at - m->ndata);
	memcpy(m->data + at, p, n);
	m->ndata = at + (uint32_t)n;
	return at;
}

/*
 * Lower a filter to nodes. polarity is true where a match grants the rule's
 * decision as written and false under an odd number of require-nots. An
 * unknown filter must never make an allow rule match more or a deny rule
 * match less: it becomes TRUE where a match denies and FALSE where it allows.
 */
static uint32_t
lower(struct emitter *m, struct filt *f, bool deny, bool positive, int depth, uint32_t op)
{
	struct ctx *c = m->c;

	if (depth > FSB_MAX_DEPTH - 2) {
		fail(c, "filters nested too deeply");
	}
	switch (f->kind) {
	case F_UNKNOWN: {
		/* matching here means: positive deny -> deny; negative -> the opposite */
		bool match = deny == positive;
		if (c->opt->warn) {
			char msg[256];
			snprintf(msg, sizeof(msg), "%s filter on %s compiled as %s (%s)",
			    f->why ? f->why : "unknown", fsb_op_name(op),
			    match ? "always matching" : "never matching",
			    deny == match ? "denies more" : "allows less");
			c->opt->warn(c->opt->warn_arg, msg);
		}
		return match ? m->true_node : m->false_node;
	}
	case F_TRUE:
		return m->true_node;
	case F_FALSE:
		return m->false_node;
	case F_NOT: {
		uint32_t child = lower(m, f->kids[0], deny, !positive, depth + 1, op);
		return add_node(m, FSB_N_NOT, 0, child, 0);
	}
	case F_ALL:
	case F_ANY: {
		uint32_t *kids = malloc(f->nkids * sizeof(*kids));
		if (!kids) {
			fail(c, "out of memory");
		}
		for (size_t i = 0; i < f->nkids; i++) {
			kids[i] = lower(m, f->kids[i], deny, positive, depth + 1, op);
		}
		m->children = grow(c, m->children, &m->capchildren, m->nchildren + (uint32_t)f->nkids,
		    sizeof(*m->children));
		uint32_t first = m->nchildren;
		memcpy(m->children + first, kids, f->nkids * sizeof(*kids));
		m->nchildren += (uint32_t)f->nkids;
		free(kids);
		return add_node(m, (uint16_t)f->kind, 0, first, (uint32_t)f->nkids);
	}
	case F_STR_EQ:
	case F_STR_PREFIX:
	case F_SUBPATH: {
		if (f->node != FSB_NONE) {
			return f->node;
		}
		uint32_t at = add_data(m, f->s, f->n, 1);
		f->node = add_node(m, (uint16_t)f->kind, (uint16_t)f->field, at, (uint32_t)f->n);
		return f->node;
	}
	case F_REGEX: {
		if (f->node != FSB_NONE) {
			return f->node;
		}
		char *error = NULL;
		if (sbpl_regex_compile(f->s, f->n, &f->prog, &f->words, &error) != 0) {
			char msg[512];
			snprintf(msg, sizeof(msg), "%s", error ? error : "bad regex");
			free(error);
			fail(c, "%s", msg);
		}
		uint32_t at = add_data(m, f->prog, (size_t)f->words * 4, 4);
		f->node = add_node(m, FSB_N_REGEX, (uint16_t)f->field, at, f->words);
		free(f->prog);
		f->prog = NULL;
		return f->node;
	}
	case F_NUM_EQ:
	case F_NUM_BITS:
		return add_node(m, (uint16_t)f->kind, (uint16_t)f->field, (uint32_t)f->num,
		    (uint32_t)(f->num >> 32));
	case F_EXTENSION: {
		if (f->node != FSB_NONE) {
			return f->node;
		}
		uint32_t at = add_data(m, f->s, f->n, 1);
		f->node = add_node(m, FSB_N_EXTENSION, 0, at, (uint32_t)f->n);
		return f->node;
	}
	default:
		fail(c, "internal: bad filter kind %d", f->kind);
	}
}

static int
rule_cmp(const void *x, const void *y)
{
	const struct rule *a = x, *b = y;
	/* stable by op: ties keep source order through the index stored in flags' high bits */
	if (a->op != b->op) {
		return a->op < b->op ? -1 : 1;
	}
	return 0;
}

static void
emit_profile(struct ctx *c, void **out, size_t *out_size)
{
	struct emitter m = { .c = c };
	struct rule *sorted;
	struct fsb_op ops[FSB_OP_COUNT];
	uint32_t *rule_nodes;

	m.true_node = add_node(&m, FSB_N_TRUE, 0, 0, 0);
	m.false_node = add_node(&m, FSB_N_FALSE, 0, 0, 0);
	/* Lower each rule's filter (shared filters are emitted once). */
	rule_nodes = malloc((c->nrules ? c->nrules : 1) * sizeof(*rule_nodes));
	sorted = malloc((c->nrules ? c->nrules : 1) * sizeof(*sorted));
	if (!rule_nodes || !sorted) {
		free(rule_nodes);
		free(sorted);
		fail(c, "out of memory");
	}
	/* Counting sort by operation keeps each operation's rules in source order. */
	uint32_t counts[FSB_OP_COUNT] = { 0 };
	for (size_t i = 0; i < c->nrules; i++) {
		counts[c->rules[i].op]++;
	}
	uint32_t at = 0;
	for (uint32_t op = 0; op < FSB_OP_COUNT; op++) {
		ops[op].first_rule = at;
		ops[op].rule_count = counts[op];
		at += counts[op];
		counts[op] = ops[op].first_rule;
	}
	for (size_t i = 0; i < c->nrules; i++) {
		sorted[counts[c->rules[i].op]++] = c->rules[i];
	}
	(void)rule_cmp;
	struct fsb_rule *rules = malloc((c->nrules ? c->nrules : 1) * sizeof(*rules));
	if (!rules) {
		free(rule_nodes);
		free(sorted);
		fail(c, "out of memory");
	}
	for (size_t i = 0; i < c->nrules; i++) {
		struct rule *r = &sorted[i];
		rules[i].flags = r->flags;
		rules[i].node = r->f ? lower(&m, r->f, (r->flags & FSB_RULE_DENY) != 0, true, 0, r->op) : FSB_NONE;
		/* Filters lowered for one polarity can't be reused for the other. */
		if (r->f) {
			/* cached nodes are polarity-independent (no unknowns inside them) */
		}
	}
	free(rule_nodes);
	free(sorted);

	struct fsb_header h = { 0 };
	h.magic = FSB_MAGIC;
	h.version = FSB_VERSION;
	h.op_count = FSB_OP_COUNT;
	h.flags = c->profile_flags | (c->version >= 2 ? FSB_PROFILE_FILTER_SYSCALLS : 0);
	uint32_t off = sizeof(h);
	h.ops_off = off;
	off += sizeof(ops);
	h.rules_off = off;
	h.rule_count = (uint32_t)c->nrules;
	off += h.rule_count * sizeof(struct fsb_rule);
	h.nodes_off = off;
	h.node_count = m.nnodes;
	off += m.nnodes * sizeof(struct fsb_node);
	h.children_off = off;
	h.child_count = m.nchildren;
	off += m.nchildren * sizeof(uint32_t);
	h.data_off = off;
	h.data_size = (m.ndata + 3) & ~3u;
	off += h.data_size;
	h.size = off;
	if (h.size > FSB_MAX_SIZE) {
		free(rules);
		free(m.nodes);
		free(m.children);
		free(m.data);
		fail(c, "compiled profile is too large (%u bytes)", h.size);
	}
	uint8_t *buf = calloc(1, h.size);
	if (!buf) {
		free(rules);
		fail(c, "out of memory");
	}
	memcpy(buf, &h, sizeof(h));
	memcpy(buf + h.ops_off, ops, sizeof(ops));
	if (c->nrules) {
		memcpy(buf + h.rules_off, rules, c->nrules * sizeof(*rules));
	}
	memcpy(buf + h.nodes_off, m.nodes, m.nnodes * sizeof(*m.nodes));
	if (m.nchildren) {
		memcpy(buf + h.children_off, m.children, m.nchildren * sizeof(uint32_t));
	}
	if (m.ndata) {
		memcpy(buf + h.data_off, m.data, m.ndata);
	}
	free(rules);
	free(m.nodes);
	free(m.children);
	free(m.data);
	if (fsb_profile_validate(buf, h.size) != 0) {
		free(buf);
		fail(c, "internal: the compiled profile doesn't validate");
	}
	*out = buf;
	*out_size = h.size;
}

/* ==== entry points ==== */

static int
compile_source(struct ctx *c, const char *source, size_t n, const char *name)
{
	struct reader r = { .c = c, .s = source, .n = n, .line = 1 };

	c->source_name = name;
	for (;;) {
		skip_space(&r);
		if (r.i >= r.n) {
			return 0;
		}
		obj *form = read_form(&r);
		c->depth = 0;
		eval(c, form, c->global);
	}
}

static void
ctx_free(struct ctx *c)
{
	while (c->arena) {
		struct arena_block *b = c->arena;
		c->arena = b->next;
		free(b);
	}
	for (size_t i = 0; i < c->nimported; i++) {
		free(c->imported[i]);
	}
	free(c->imported);
	free(c->rules);
}

int
sbpl_compile_string(const char *source, size_t length, const char *source_name,
    const struct sbpl_options *options, void **out, size_t *out_size, char **error)
{
	static const struct sbpl_options no_options;
	struct ctx *c = calloc(1, sizeof(*c));
	int result = -1;

	*out = NULL;
	*out_size = 0;
	*error = NULL;
	if (!c) {
		*error = strdup("out of memory");
		return -1;
	}
	c->opt = options ? options : &no_options;
	if (setjmp(c->fail) == 0) {
		setup(c);
		compile_source(c, source, length, source_name ? source_name : "profile");
		if (!c->version) {
			c->line = 0;
			fail(c, "no version specified");
		}
		emit_profile(c, out, out_size);
		result = 0;
	} else {
		*error = c->error ? c->error : strdup("compile failed");
		c->error = NULL;
	}
	free(c->error);
	ctx_free(c);
	free(c);
	return result;
}

int
sbpl_compile_file(const char *path, const struct sbpl_options *options,
    void **out, size_t *out_size, char **error)
{
	struct ctx probe = { .opt = options };
	char *found = NULL;
	size_t n = 0;
	char *src;
	int r;

	if (!probe.opt) {
		static const struct sbpl_options none;
		probe.opt = &none;
	}
	found = find_file(&probe, path);
	if (!found) {
		*out = NULL;
		*out_size = 0;
		if (asprintf(error, "%s: no such profile", path) < 0) {
			*error = NULL;
		}
		return -1;
	}
	src = read_file(found, &n);
	if (!src) {
		if (asprintf(error, "%s: can't read it", found) < 0) {
			*error = NULL;
		}
		free(found);
		return -1;
	}
	r = sbpl_compile_string(src, n, found, options, out, out_size, error);
	free(src);
	free(found);
	return r;
}
