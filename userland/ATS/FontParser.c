/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* libFontParser, Finch's: a font's protection (embedding) information. Finch reports
   every font as installable (no restrictions). */
#include <stdint.h>

uint32_t FPFontGetProtectionInfo(const void *parserFont) { return 0; }
