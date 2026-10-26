/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Finch's SBPL compiler: the sandbox profile language macOS profiles are
 * written in (a small Scheme with allow/deny rules), compiled to the FSB1
 * format FinchSandbox enforces (kernel/sandbox/fsb_format.h).
 */
#ifndef SBPL_H
#define SBPL_H

#include <stddef.h>
#include <stdint.h>

struct sbpl_param {
	const char *name;
	const char *value;
};

struct sbpl_options {
	const struct sbpl_param *params;	/* (param "NAME"); others are #f */
	size_t param_count;
	/* Folders "import" and named profiles are looked up in, in order. */
	const char *const *search_paths;
	size_t search_path_count;
	/* (entitlement "x") answers from these "name" or "name=value" strings;
	   anything else is #f. */
	const char *const *entitlements;
	size_t entitlement_count;
	/* Told of each filter compiled approximately (one Finch can't evaluate),
	   and which way: it never widens access, but a deny rule with one denies
	   more than macOS's would. NULL to ignore. */
	void (*warn)(void *arg, const char *message);
	void *warn_arg;
};

/*
 * Compile SBPL source. On success, *out is a malloc'd FSB1 profile of *out_size
 * bytes and the result is 0. On failure, -1, with *error a malloc'd message
 * (the caller frees both).
 */
int sbpl_compile_string(const char *source, size_t length, const char *source_name,
    const struct sbpl_options *options, void **out, size_t *out_size, char **error);

/* The same for a file; a name without '/' is looked up in the search paths
   (with ".sb" added when missing). */
int sbpl_compile_file(const char *path, const struct sbpl_options *options,
    void **out, size_t *out_size, char **error);

/*
 * Compile a regex in SBPL's syntax (POSIX extended, as macOS's) to an FSB1
 * regex program: malloc'd 32-bit words in *program, *words of them.
 */
int sbpl_regex_compile(const char *pattern, size_t length, uint32_t **program,
    uint32_t *words, char **error);

#endif /* SBPL_H */
