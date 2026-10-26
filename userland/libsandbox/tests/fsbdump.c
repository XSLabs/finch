/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * fsbdump: show a compiled FSB1 profile's rules for some operations, and
 * which rule decides a request.
 *
 *   fsbdump [-D NAME=VALUE]... [-I dir]... profile.sb OPERATION [FIELD=VALUE]...
 *
 * FIELD is path, global-name, sysctl-name, ipc-posix-name or
 * notification-name. Prints every rule on OPERATION and its groups (last
 * first, as they are tried) and the decision.
 */
#include "../sbpl.h"
#include "fsb_format.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const struct fsb_header *H;
static const uint8_t *B;

static void
dump_node(uint32_t i, int depth)
{
	const struct fsb_node *n = (const struct fsb_node *)(B + H->nodes_off) + i;
	const uint32_t *kids = (const uint32_t *)(B + H->children_off);
	const char *data = (const char *)(B + H->data_off);
	switch (n->kind) {
	case FSB_N_TRUE: printf("#t"); break;
	case FSB_N_FALSE: printf("#f"); break;
	case FSB_N_ALL:
	case FSB_N_ANY:
		printf("(%s", n->kind == FSB_N_ALL ? "all" : "any");
		for (uint32_t k = 0; k < n->b; k++) {
			printf(" ");
			if (depth > 6) {
				printf("...");
				break;
			}
			dump_node(kids[n->a + k], depth + 1);
		}
		printf(")");
		break;
	case FSB_N_NOT:
		printf("(not ");
		dump_node(n->a, depth + 1);
		printf(")");
		break;
	case FSB_N_STR_EQ: printf("(f%u = \"%.*s\")", n->field, (int)n->b, data + n->a); break;
	case FSB_N_STR_PREFIX: printf("(f%u prefix \"%.*s\")", n->field, (int)n->b, data + n->a); break;
	case FSB_N_SUBPATH: printf("(f%u subpath \"%.*s\")", n->field, (int)n->b, data + n->a); break;
	case FSB_N_REGEX: printf("(f%u regex, %u words)", n->field, n->b); break;
	case FSB_N_NUM_EQ: printf("(f%u == %llu)", n->field, (unsigned long long)n->a | ((unsigned long long)n->b << 32)); break;
	case FSB_N_NUM_BITS: printf("(f%u has %u)", n->field, n->a); break;
	default: printf("?%u", n->kind);
	}
}

int
main(int argc, char **argv)
{
	const char *dirs[16];
	struct sbpl_param params[256];
	size_t ndirs = 0, nparams = 0;
	int i;
	for (i = 1; i < argc && argv[i][0] == '-'; i++) {
		if (!strcmp(argv[i], "-I") && i + 1 < argc) {
			dirs[ndirs++] = argv[++i];
		} else if (!strcmp(argv[i], "-D") && i + 1 < argc) {
			char *eq = strchr(argv[++i], '=');
			*eq = 0;
			params[nparams].name = argv[i];
			params[nparams++].value = eq + 1;
		}
	}
	if (i + 2 > argc) {
		fprintf(stderr, "usage: fsbdump [-D N=V] [-I dir] profile.sb OPERATION [FIELD=VALUE]...\n");
		return 2;
	}
	struct sbpl_options opt = { .params = params, .param_count = nparams,
		.search_paths = dirs, .search_path_count = ndirs };
	void *profile;
	size_t size;
	char *error;
	if (sbpl_compile_file(argv[i], &opt, &profile, &size, &error) != 0) {
		printf("error: %s\n", error);
		return 1;
	}
	H = profile;
	B = profile;
	uint32_t op = fsb_op_lookup(argv[i + 1], strlen(argv[i + 1]));
	if (op == FSB_NONE) {
		printf("unknown operation %s\n", argv[i + 1]);
		return 1;
	}
	struct fsb_request r;
	fsb_request_init(&r, op);
	static const struct { const char *name; int field; } fields[] = {
		{ "path", FSB_F_PATH }, { "global-name", FSB_F_GLOBAL_NAME }, { "sysctl-name", FSB_F_SYSCTL_NAME },
		{ "ipc-posix-name", FSB_F_IPC_POSIX_NAME }, { "notification-name", FSB_F_NOTIFICATION_NAME },
		{ "xpc-service-name", FSB_F_XPC_SERVICE_NAME },
	};
	for (int k = i + 2; k < argc; k++) {
		char *eq = strchr(argv[k], '=');
		if (!eq) {
			continue;
		}
		*eq = 0;
		for (size_t f = 0; f < sizeof(fields) / sizeof(fields[0]); f++) {
			if (!strcmp(fields[f].name, argv[k])) {
				fsb_request_string(&r, fields[f].field, eq + 1, strlen(eq + 1));
			}
		}
	}
	const struct fsb_op *ops = (const struct fsb_op *)(B + H->ops_off);
	const struct fsb_rule *rules = (const struct fsb_rule *)(B + H->rules_off);
	for (uint32_t o = op; o != FSB_NONE; o = fsb_op_parent(o)) {
		printf("%s: %u rules\n", fsb_op_name(o), ops[o].rule_count);
		for (uint32_t k = ops[o].rule_count; k > 0; k--) {
			const struct fsb_rule *rule = &rules[ops[o].first_rule + k - 1];
			printf("  #%u %s ", k - 1, rule->flags & FSB_RULE_DENY ? "deny" : "allow");
			if (rule->node == FSB_NONE) {
				printf("(everything)");
			} else {
				dump_node(rule->node, 0);
			}
			printf("\n");
		}
	}
	void *scratch = malloc(FSB_SCRATCH_BYTES);
	uint32_t flags;
	int d = fsb_evaluate(profile, &r, scratch, &flags);
	printf("decision: %s (rule flags %#x)\n", d == FSB_ALLOW ? "allow" : "deny", flags);
	return 0;
}
