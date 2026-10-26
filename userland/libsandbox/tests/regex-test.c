/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The SBPL regex compiler and FSB1 matcher against the host's POSIX extended
 * regexes (regcomp/regexec), which macOS's sandbox regexes follow: every
 * pattern against every subject, with search semantics.
 */
#include "../sbpl.h"
#include "../../../kernel/sandbox/fsb_eval.c"

#include <regex.h>
#include <stdio.h>
#include <stdlib.h>

static const char *patterns[] = {
	"^/private/etc/hosts$", "hosts$", "etc/hos", "^/a(b|c)*d$", "^/[a-z]+/[0-9]{2,3}$",
	"x+y?z", "^$", "", "a|b|c", "(ab|a)(c|bcd)", "^/Users/[^/]+/Library/Caches/",
	"\\.plist$", "^/dev/tty[a-z0-9]*$", "[[:digit:]]+", "^(/private)?/var/folders/[^/]+/[^/]+/[CT]/",
	"a{3}", "a{2,}", "a{0,2}b", "(a*)*b", "(a|)+c", "[]a]", "[^]a]x", "[a-]z", "\\$\\.\\*",
	"^/System/Library/(Frameworks|PrivateFrameworks)/[^/]+\\.framework/", "[A-F0-9]{8}-[A-F0-9]{4}",
	"^/Library/Preferences/com\\.apple\\.[^/]*\\.plist$", ".*", "^.*$", "(^a|b$)", "a^b", "^^a", "a$$",
};
static const char *subjects[] = {
	"", "/private/etc/hosts", "/private/etc/hosts2", "/abd", "/abcbcd", "/ad", "/xyz/123", "/xyz/1234",
	"xz", "xxyz", "abc", "abcd", "abcbcd", "/Users/me/Library/Caches/x", "/Users/a/b/Library/Caches/",
	"a.plist", "aplist", "/dev/ttys001", "/dev/tty", "/dev/ttyX!", "abc123", "/var/folders/ab/cd/T/x",
	"/private/var/folders/ab/cd/C/", "aaa", "aa", "b", "ab", "aab", "aaab", "c", "ac", "]", "a", "]x", "-z",
	"z", "$.*", "/System/Library/Frameworks/AppKit.framework/AppKit", "DEADBEEF-1234", "deadbeef-1234",
	"/Library/Preferences/com.apple.foo.plist", "/Library/Preferences/com.apple.plist", "ba", "a^b",
};

int main(void)
{
	void *scratch = malloc(FSB_SCRATCH_BYTES);
	int failures = 0, checks = 0;

	for (size_t i = 0; i < sizeof(patterns) / sizeof(patterns[0]); i++) {
		regex_t re;
		uint32_t *prog, words;
		char *error = NULL;
		int posix_ok = regcomp(&re, patterns[i], REG_EXTENDED | REG_NOSUB) == 0;
		int ours_ok = sbpl_regex_compile(patterns[i], strlen(patterns[i]), &prog, &words, &error) == 0;
		/* macOS's sandbox takes empty branches, which the host's regcomp refuses */
		int apple_takes = strcmp(patterns[i], "(a|)+c") == 0;
		if (!posix_ok || !ours_ok) {
			if (posix_ok != ours_ok && !(apple_takes && ours_ok)) {
				printf("compile differs for /%s/: posix %d, finch %d (%s)\n", patterns[i],
				    posix_ok, ours_ok, error ? error : "");
				failures++;
			}
			free(error);
			if (posix_ok) regfree(&re);
			continue;
		}
		if (!fsb_regex_valid(prog, words)) {
			printf("invalid program for /%s/\n", patterns[i]);
			failures++;
		}
		for (size_t j = 0; j < sizeof(subjects) / sizeof(subjects[0]); j++) {
			int want = regexec(&re, subjects[j], 0, NULL, 0) == 0;
			int got = fsb_rx_search(prog, words, subjects[j], strlen(subjects[j]), scratch);
			checks++;
			if (want != got) {
				printf("/%s/ on \"%s\": posix %d, finch %d\n", patterns[i], subjects[j], want, got);
				failures++;
			}
		}
		regfree(&re);
		free(prog);
	}
	free(scratch);
	printf("%d regex checks, %d differences\n", checks, failures);
	return failures != 0;
}
