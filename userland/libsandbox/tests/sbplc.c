/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * sbplc: compile SBPL profiles with Finch's compiler, for tests.
 *
 *   sbplc [-I dir]... [-D NAME=VALUE]... [-E entitlement]... [-o out] profile...
 *
 * Prints one line per profile: "ok NAME SIZE" or "error NAME: message".
 * With -o, writes the (single) compiled profile there. Exits 1 if any failed.
 */
#include "../sbpl.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void
warn(void *arg, const char *message)
{
	printf("warning %s: %s\n", (const char *)arg, message);
}

int main(int argc, char **argv)
{
	int warnings = 0;
	const char *dirs[64], *ents[256], *out = NULL;
	struct sbpl_param params[512];
	size_t ndirs = 0, nparams = 0, nents = 0;
	int failures = 0, i;

	for (i = 1; i < argc && argv[i][0] == '-'; i++) {
		if (!strcmp(argv[i], "-I") && i + 1 < argc && ndirs < 64) {
			dirs[ndirs++] = argv[++i];
		} else if (!strcmp(argv[i], "-D") && i + 1 < argc && nparams < 512) {
			char *eq = strchr(argv[++i], '=');
			if (!eq) {
				fprintf(stderr, "-D needs NAME=VALUE\n");
				return 2;
			}
			*eq = 0;
			params[nparams].name = argv[i];
			params[nparams++].value = eq + 1;
		} else if (!strcmp(argv[i], "-E") && i + 1 < argc && nents < 256) {
			ents[nents++] = argv[++i];
		} else if (!strcmp(argv[i], "-w")) {
			warnings = 1;
		} else if (!strcmp(argv[i], "-o") && i + 1 < argc) {
			out = argv[++i];
		} else {
			fprintf(stderr, "usage: sbplc [-I dir] [-D NAME=VALUE] [-E ent] [-o out] profile...\n");
			return 2;
		}
	}
	struct sbpl_options opt = {
		.params = params, .param_count = nparams,
		.search_paths = dirs, .search_path_count = ndirs,
		.entitlements = ents, .entitlement_count = nents,
	};
	for (; i < argc; i++) {
		void *profile;
		size_t size;
		char *error;
		opt.warn = warnings ? warn : NULL;
		opt.warn_arg = argv[i];
		if (sbpl_compile_file(argv[i], &opt, &profile, &size, &error) != 0) {
			printf("error %s: %s\n", argv[i], error ? error : "?");
			free(error);
			failures++;
			continue;
		}
		printf("ok %s %zu\n", argv[i], size);
		if (out) {
			FILE *f = fopen(out, "wb");
			if (!f || fwrite(profile, 1, size, f) != size || fclose(f) != 0) {
				perror(out);
				failures++;
			}
		}
		free(profile);
	}
	return failures != 0;
}
