/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* ATS.framework, Finch's: what's left of Apple Type Services apps link, the font
   validation keys (Finch has no font validator yet: validations report nothing). */
#include <CoreFoundation/CoreFoundation.h>

const CFStringRef kATSValidationPostScriptName = CFSTR("fontname");
const CFStringRef kATSValidationRuleResult = CFSTR("result");
const CFStringRef kATSValidationRuleSeverity = CFSTR("severity");
const CFStringRef kATSValidationRulesList = CFSTR("ruleslist");
const CFStringRef kATSValidationTestsFailed = CFSTR("fail");
const CFStringRef kATSValidationTestsPassed = CFSTR("pass");
const CFStringRef kATSValidationTestsWarned = CFSTR("warn");
