/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* UIKitMacHelper (private): Mac Catalyst's bridge to AppKit. Finch runs no Catalyst apps,
   so there's no shared delegate to hand out. */
__attribute__((visibility("default"))) void *UINSSharedApplicationDelegate(void) { return 0; }
