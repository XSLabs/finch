/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Deciding a request against a compiled profile (fsb_format.h). The same
 * source builds into the kernel (FinchSandbox) and into libsandbox, where
 * the compiler's tests use it. It allocates nothing and never recurses
 * deeper than FSB_MAX_DEPTH.
 */
#include "fsb_format.h"

#ifdef KERNEL
#include <string.h>
#include <sys/errno.h>
#else
#include <errno.h>
#include <string.h>
#endif

static const char *const fsb_op_names[FSB_OP_COUNT] = { FSB_OP_NAMES };
static const uint32_t fsb_op_parents[FSB_OP_COUNT] = { FSB_OP_PARENTS };

uint32_t
fsb_op_parent(uint32_t op)
{
	return op < FSB_OP_COUNT ? fsb_op_parents[op] : FSB_NONE;
}

const char *
fsb_op_name(uint32_t op)
{
	return op < FSB_OP_COUNT ? fsb_op_names[op] : NULL;
}

uint32_t
fsb_op_lookup(const char *name, size_t len)
{
	for (uint32_t i = 0; i < FSB_OP_COUNT; i++) {
		if (strlen(fsb_op_names[i]) == len &&
		    memcmp(fsb_op_names[i], name, len) == 0) {
			return i;
		}
	}
	return FSB_NONE;
}

void
fsb_request_init(struct fsb_request *r, uint32_t op)
{
	memset(r, 0, sizeof(*r));
	r->op = op;
}

void
fsb_request_string(struct fsb_request *r, int field, const char *s, size_t len)
{
	if (field >= 0 && FSB_F_IS_STRING(field) && s != NULL) {
		r->string[field] = s;
		r->length[field] = len;
		r->strings_present |= 1u << field;
	}
}

void
fsb_request_number(struct fsb_request *r, int field, uint64_t value)
{
	if (field >= FSB_F_TARGET && field < FSB_F_FIELD_MAX) {
		r->number[FSB_F_NUM_INDEX(field)] = value;
		r->numbers_present |= 1ull << FSB_F_NUM_INDEX(field);
	}
}

/* ---- validation ---- */

struct fsb_view {
	const uint8_t *base;
	const struct fsb_header *h;
	const struct fsb_op *ops;
	const struct fsb_rule *rules;
	const struct fsb_node *nodes;
	const uint32_t *children;
	const uint8_t *data;
};

static int
fsb_range(uint32_t size, uint32_t off, uint32_t count, uint32_t elem)
{
	uint64_t end = (uint64_t)off + (uint64_t)count * elem;

	return (off & 3) == 0 && off <= size && end <= size;
}

static int
fsb_regex_valid(const uint32_t *prog, uint32_t words)
{
	if (words == 0 || words > FSB_MAX_REGEX_INSNS) {
		return 0;
	}
	for (uint32_t pc = 0; pc < words; pc++) {
		uint32_t w = prog[pc];
		switch (FSB_RX_OP(w)) {
		case FSB_RX_CHAR:
			if (FSB_RX_ARG(w) > 0xff) {
				return 0;
			}
			break;
		case FSB_RX_ANY:
		case FSB_RX_BOL:
		case FSB_RX_EOL:
		case FSB_RX_MATCH:
			break;
		case FSB_RX_CLASS:
			if (pc + 8 >= words) {
				return 0;
			}
			pc += 8;
			break;
		case FSB_RX_SPLIT:
			if (pc + 1 >= words || FSB_RX_ARG(w) >= words ||
			    prog[pc + 1] >= words) {
				return 0;
			}
			pc++;
			break;
		case FSB_RX_JMP:
			if (FSB_RX_ARG(w) >= words) {
				return 0;
			}
			break;
		default:
			return 0;
		}
	}
	/* A jump target must be an instruction, not a CLASS bitmap or SPLIT's second word. */
	for (uint32_t pc = 0; pc < words; pc++) {
		uint32_t w = prog[pc], t1 = FSB_NONE, t2 = FSB_NONE;
		if (FSB_RX_OP(w) == FSB_RX_SPLIT) {
			t1 = FSB_RX_ARG(w);
			t2 = prog[pc + 1];
		} else if (FSB_RX_OP(w) == FSB_RX_JMP) {
			t1 = FSB_RX_ARG(w);
		}
		for (int k = 0; k < 2; k++) {
			uint32_t t = k == 0 ? t1 : t2;
			if (t == FSB_NONE) {
				continue;
			}
			/* Walk from the start to see that t begins an instruction. */
			uint32_t at = 0;
			while (at < t) {
				uint32_t op = FSB_RX_OP(prog[at]);
				at += op == FSB_RX_CLASS ? 9 : op == FSB_RX_SPLIT ? 2 : 1;
			}
			if (at != t) {
				return 0;
			}
		}
		if (FSB_RX_OP(w) == FSB_RX_CLASS) {
			pc += 8;
		} else if (FSB_RX_OP(w) == FSB_RX_SPLIT) {
			pc++;
		}
	}
	return 1;
}

static int
fsb_view(const void *profile, size_t size, struct fsb_view *v)
{
	const struct fsb_header *h = profile;

	if (profile == NULL || size < sizeof(*h) || size > FSB_MAX_SIZE ||
	    ((uintptr_t)profile & 3) != 0) {
		return EINVAL;
	}
	if (h->magic != FSB_MAGIC || h->version != FSB_VERSION || h->size != size ||
	    h->op_count != FSB_OP_COUNT || h->reserved[0] != 0 || h->reserved[1] != 0 ||
	    (h->flags & ~FSB_PROFILE_FLAGS) != 0) {
		return EINVAL;
	}
	if (!fsb_range(h->size, h->ops_off, h->op_count, sizeof(struct fsb_op)) ||
	    !fsb_range(h->size, h->rules_off, h->rule_count, sizeof(struct fsb_rule)) ||
	    !fsb_range(h->size, h->nodes_off, h->node_count, sizeof(struct fsb_node)) ||
	    !fsb_range(h->size, h->children_off, h->child_count, sizeof(uint32_t)) ||
	    !fsb_range(h->size, h->data_off, h->data_size, 1)) {
		return EINVAL;
	}
	v->base = profile;
	v->h = h;
	v->ops = (const struct fsb_op *)(v->base + h->ops_off);
	v->rules = (const struct fsb_rule *)(v->base + h->rules_off);
	v->nodes = (const struct fsb_node *)(v->base + h->nodes_off);
	v->children = (const uint32_t *)(v->base + h->children_off);
	v->data = v->base + h->data_off;
	return 0;
}

int
fsb_profile_validate(const void *profile, size_t size)
{
	struct fsb_view v;
	int error = fsb_view(profile, size, &v);

	if (error != 0) {
		return error;
	}
	for (uint32_t i = 0; i < FSB_OP_COUNT; i++) {
		uint64_t end = (uint64_t)v.ops[i].first_rule + v.ops[i].rule_count;
		if (end > v.h->rule_count) {
			return EINVAL;
		}
	}
	for (uint32_t i = 0; i < v.h->rule_count; i++) {
		const struct fsb_rule *r = &v.rules[i];
		if ((r->flags & ~(FSB_RULE_DENY | FSB_RULE_REPORT | FSB_RULE_NO_REPORT)) != 0 ||
		    (r->node != FSB_NONE && r->node >= v.h->node_count)) {
			return EINVAL;
		}
	}
	/* Depth: each node's is one more than its deepest child's. */
	for (uint32_t i = 0; i < v.h->node_count; i++) {
		const struct fsb_node *n = &v.nodes[i];
		switch (n->kind) {
		case FSB_N_TRUE:
		case FSB_N_FALSE:
			break;
		case FSB_N_ALL:
		case FSB_N_ANY:
			if ((uint64_t)n->a + n->b > v.h->child_count) {
				return EINVAL;
			}
			for (uint32_t c = 0; c < n->b; c++) {
				if (v.children[n->a + c] >= i) {
					return EINVAL;	/* children come first */
				}
			}
			break;
		case FSB_N_NOT:
			if (n->a >= i) {
				return EINVAL;
			}
			break;
		case FSB_N_STR_EQ:
		case FSB_N_STR_PREFIX:
		case FSB_N_SUBPATH:
			if (!FSB_F_IS_STRING(n->field) ||
			    (uint64_t)n->a + n->b > v.h->data_size) {
				return EINVAL;
			}
			break;
		case FSB_N_REGEX:
			if (!FSB_F_IS_STRING(n->field) || (n->a & 3) != 0 ||
			    (uint64_t)n->a + (uint64_t)n->b * 4 > v.h->data_size ||
			    ((v.h->data_off + n->a) & 3) != 0 ||
			    !fsb_regex_valid((const uint32_t *)(v.data + n->a), n->b)) {
				return EINVAL;
			}
			break;
		case FSB_N_NUM_EQ:
		case FSB_N_NUM_BITS:
			if (n->field < FSB_F_TARGET || n->field >= FSB_F_FIELD_MAX) {
				return EINVAL;
			}
			break;
		case FSB_N_EXTENSION:
			if (n->b == 0 || (uint64_t)n->a + n->b > v.h->data_size) {
				return EINVAL;
			}
			break;
		default:
			return EINVAL;
		}
	}
	return 0;
}

/* ---- regex matching (Pike VM: linear in the subject, no backtracking) ---- */

struct fsb_rx {
	const uint32_t *prog;
	uint32_t words;
	uint16_t *stack;	/* FSB_MAX_REGEX_INSNS */
	uint8_t *mark;		/* generation per instruction */
	uint8_t gen;
};

static void
fsb_rx_next_gen(struct fsb_rx *m)
{
	if (++m->gen == 0) {
		memset(m->mark, 0, m->words);
		m->gen = 1;
	}
}

/*
 * Add pc, and everything it reaches without reading a byte, to list. Each
 * instruction is pushed at most once per generation, so the stack can't
 * outgrow the program. 1 if MATCH is reached.
 */
static int
fsb_rx_add(struct fsb_rx *m, uint16_t *list, uint32_t *n, uint32_t pc,
    size_t at, size_t len)
{
	uint32_t sp = 0;

#define FSB_RX_PUSH(t) do { \
	uint32_t t_ = (t); \
	if (m->mark[t_] != m->gen) { \
		m->mark[t_] = m->gen; \
		m->stack[sp++] = (uint16_t)t_; \
	} \
} while (0)
	FSB_RX_PUSH(pc);
	while (sp > 0) {
		pc = m->stack[--sp];
		uint32_t w = m->prog[pc];
		switch (FSB_RX_OP(w)) {
		case FSB_RX_JMP:
			FSB_RX_PUSH(FSB_RX_ARG(w));
			break;
		case FSB_RX_SPLIT:
			FSB_RX_PUSH(m->prog[pc + 1]);
			FSB_RX_PUSH(FSB_RX_ARG(w));
			break;
		case FSB_RX_BOL:
			if (at == 0) {
				FSB_RX_PUSH(pc + 1);
			}
			break;
		case FSB_RX_EOL:
			if (at == len) {
				FSB_RX_PUSH(pc + 1);
			}
			break;
		case FSB_RX_MATCH:
			return 1;
		default:
			list[(*n)++] = (uint16_t)pc;
			break;
		}
	}
#undef FSB_RX_PUSH
	return 0;
}

/* 1 if the program matches somewhere in s, 0 if not. */
static int
fsb_rx_search(const uint32_t *prog, uint32_t words, const char *s, size_t len,
    void *scratch)
{
	struct fsb_rx m;
	uint16_t *cur = scratch, *next = cur + FSB_MAX_REGEX_INSNS, *t;
	uint32_t ncur = 0, nnext;

	m.prog = prog;
	m.words = words;
	m.stack = next + FSB_MAX_REGEX_INSNS;
	m.mark = (uint8_t *)(m.stack + FSB_MAX_REGEX_INSNS);
	memset(m.mark, 0, words);
	m.gen = 0;

	fsb_rx_next_gen(&m);
	if (fsb_rx_add(&m, cur, &ncur, 0, 0, len)) {
		return 1;
	}
	for (size_t at = 0; at < len; at++) {
		uint8_t c = (uint8_t)s[at];

		fsb_rx_next_gen(&m);
		nnext = 0;
		for (uint32_t i = 0; i < ncur; i++) {
			uint32_t pc = cur[i], w = prog[pc], to = pc + 1;
			int take = 0;

			switch (FSB_RX_OP(w)) {
			case FSB_RX_CHAR:
				take = FSB_RX_ARG(w) == c;
				break;
			case FSB_RX_ANY:
				take = 1;
				break;
			case FSB_RX_CLASS:
				take = (prog[pc + 1 + (c >> 5)] >> (c & 31)) & 1;
				to = pc + 9;
				break;
			default:
				break;
			}
			if (take && fsb_rx_add(&m, next, &nnext, to, at + 1, len)) {
				return 1;
			}
		}
		/* A new attempt starts at every position: the search isn't anchored. */
		if (fsb_rx_add(&m, next, &nnext, 0, at + 1, len)) {
			return 1;
		}
		t = cur;
		cur = next;
		next = t;
		ncur = nnext;
	}
	return 0;
}

/* ---- evaluation ---- */

static int
fsb_match(const struct fsb_view *v, const struct fsb_request *r, uint32_t node,
    void *scratch, int depth)
{
	const struct fsb_node *n = &v->nodes[node];
	const char *s;
	size_t len;

	if (depth > FSB_MAX_DEPTH) {
		return -1;
	}
	switch (n->kind) {
	case FSB_N_TRUE:
		return 1;
	case FSB_N_FALSE:
		return 0;
	case FSB_N_ALL:
	case FSB_N_ANY:
		for (uint32_t c = 0; c < n->b; c++) {
			int m = fsb_match(v, r, v->children[n->a + c], scratch, depth + 1);
			if (m < 0) {
				return m;
			}
			if (n->kind == FSB_N_ALL && m == 0) {
				return 0;
			}
			if (n->kind == FSB_N_ANY && m == 1) {
				return 1;
			}
		}
		return n->kind == FSB_N_ALL;
	case FSB_N_NOT: {
		int m = fsb_match(v, r, n->a, scratch, depth + 1);
		return m < 0 ? m : !m;
	}
	case FSB_N_STR_EQ:
	case FSB_N_STR_PREFIX:
	case FSB_N_SUBPATH:
	case FSB_N_REGEX:
		if ((r->strings_present & (1u << n->field)) == 0) {
			return 0;	/* a filter on a value the request lacks doesn't match */
		}
		s = r->string[n->field];
		len = r->length[n->field];
		if (n->kind == FSB_N_REGEX) {
			return fsb_rx_search((const uint32_t *)(v->data + n->a), n->b, s, len,
			    scratch);
		}
		if (n->kind == FSB_N_STR_EQ) {
			return len == n->b && memcmp(s, v->data + n->a, len) == 0;
		}
		if (len < n->b || memcmp(s, v->data + n->a, n->b) != 0) {
			return 0;
		}
		if (n->kind == FSB_N_STR_PREFIX) {
			return 1;
		}
		/* subpath: the path itself, or a path below it ("/" is below everything) */
		return len == n->b || (n->b > 0 && v->data[n->a + n->b - 1] == '/') ||
		       s[n->b] == '/';
	case FSB_N_NUM_EQ:
	case FSB_N_NUM_BITS: {
		uint32_t idx = FSB_F_NUM_INDEX(n->field);
		uint64_t want = (uint64_t)n->a | ((uint64_t)n->b << 32);
		if ((r->numbers_present & (1ull << idx)) == 0) {
			return 0;
		}
		if (n->kind == FSB_N_NUM_EQ) {
			/* target is a set of relations: any shared one matches */
			if (n->field == FSB_F_TARGET) {
				return (r->number[idx] & want) != 0;
			}
			return r->number[idx] == want;
		}
		return (r->number[idx] & want) == want;
	}
	case FSB_N_EXTENSION:
		return r->extension != NULL &&
		       r->extension(r->extension_arg, (const char *)(v->data + n->a), n->b, r);
	default:
		return -1;
	}
}

int
fsb_evaluate(const void *profile, const struct fsb_request *r,
    void *scratch_memory, uint32_t *rule_flags)
{
	struct fsb_view v;

	if (rule_flags != NULL) {
		*rule_flags = 0;
	}
	if (fsb_view(profile, ((const struct fsb_header *)profile)->size, &v) != 0 ||
	    r->op >= FSB_OP_COUNT) {
		return FSB_DENY;
	}
	for (uint32_t op = r->op; op != FSB_NONE; op = fsb_op_parents[op]) {
		const struct fsb_op *o = &v.ops[op];
		/* The last matching rule decides. */
		for (uint32_t i = o->rule_count; i > 0; i--) {
			const struct fsb_rule *rule = &v.rules[o->first_rule + i - 1];
			int m = rule->node == FSB_NONE ? 1 :
			    fsb_match(&v, r, rule->node, scratch_memory, 0);
			if (m < 0) {
				/* A filter that can't be evaluated never grants access. */
				if ((rule->flags & FSB_RULE_DENY) == 0) {
					continue;
				}
				m = 1;
			}
			if (m == 1) {
				if (rule_flags != NULL) {
					*rule_flags = rule->flags;
				}
				return (rule->flags & FSB_RULE_DENY) ? FSB_DENY : FSB_ALLOW;
			}
		}
	}
	return FSB_DENY;
}
