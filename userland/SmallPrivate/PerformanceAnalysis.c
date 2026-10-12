/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * PerformanceAnalysis (private): apps mark operations for Apple's performance tooling.
 * Finch records none; the marks do nothing.
 */
#include <stdint.h>

#define PA_EXPORT __attribute__((visibility("default")))
PA_EXPORT uint64_t PAMarkOperationStart(const void *a, const void *b, const void *c) { return 0; }
PA_EXPORT void PAMarkOperationEnd(const void *a, const void *b, const void *c) {}
PA_EXPORT void PAMarkOperationEvent(const void *a, const void *b, const void *c) {}
PA_EXPORT uint64_t PAMarkOperationIntervalStart(const void *a, const void *b, const void *c) { return 0; }
PA_EXPORT void PAMarkOperationIntervalEnd(const void *a, const void *b, const void *c) {}
