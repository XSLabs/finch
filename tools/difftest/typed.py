#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Build safe, type-driven cases from Clang's SDK declaration details."""
from __future__ import annotations

import json
import re
from collections import Counter
from pathlib import Path


MAX_CASES = 8
POOL_DESCRIPTIONS = {
    "integer": [0, 1, -1, 2, -2, "minimum", "maximum"],
    "floating": [0.0, "negative-zero", "positive-infinity", "negative-infinity", "nan", "subnormal", 0.5],
    "boolean": [False, True],
    "range": [[0, 0], [0, 1], [1, 0]],
    "string": ["empty", "ASCII", "unicode/combining/emoji/RTL", "long-65536"],
    "number": [0, 1, -1, "minimum", "maximum", 0.5, "nan"],
    "date": [0, -1, 700000000, 800000000],
    "data": ["empty", "small-binary", "UTF-8"],
    "array": ["empty", "mixed", "strings"],
    "dictionary": ["empty", "mixed"],
    "set": ["empty", "mixed"],
    "URL": ["https://example.invalid/a%20b?q=1#part", "mailto:finch@example.invalid", "relative/path"],
    "locale": ["en_US_POSIX", "fr_CA", "ar_EG"],
    "time-zone": ["UTC", "America/Toronto", "Asia/Kathmandu"],
    "calendar": ["gregorian", "iso8601"],
    "character-set": ["ASCII", "letters", "custom/unicode"],
}


SIDE_EFFECT_RULES = (
    ("diagnostic output", re.compile(r"^CFShowStr$")),
    ("user-defaults", re.compile(r"NSUserDefaults|CFPreferences", re.I)),
    ("notifications", re.compile(r"CFUserNotification|NSDistributedNotification|NSUserNotification|DistributedLock|DarwinNotify|GetDarwinNotifyCenter", re.I)),
    ("network", re.compile(r"URLSession|URLConnection|CFHost|NSHost|CFSocket|SocketToHost|Network|HTTP|WebSocket|Bonjour|NSNetService|NS(?:Input|Output)?Stream|Ubiquitous|checkResourceIsReachable|(?:load|fetch|request|download).*?(?:URL|Host)|(?:URL|Host).*?(?:load|fetch|request|download)", re.I)),
    ("processes", re.compile(r"NSTask|NSWorkspace|NSXPC|NSConnection|NSMachPort|NSPort|LaunchApplication|LaunchProcess|Spawn|ForkProcess|CreateProcess|BackgroundActivityScheduler", re.I)),
    ("blocking", re.compile(r"\bCFRunLoopRun(?:InMode)?\b", re.I)),
    ("blocking", re.compile(r"NSCondition|NSLock|NSRecursiveLock|waitUntilFinished|waitUntilDate|waitForDataInBackgroundAndNotify|lockWhenCondition|lockBeforeDate|waitForCompletion|sleepForTimeInterval|performSelector:onThread", re.I)),
    ("autorelease-pools", re.compile(r"NSAutoreleasePool", re.I)),
    ("processes", re.compile(r"NSOperationQueue|NSOperation -start|NSBackgroundActivityScheduler", re.I)),
    ("streams", re.compile(r"(?:WithStream|toStream|FromStream|StreamWith)", re.I)),
    ("filesystem", re.compile(r"NSFile|FileHandle|FileCoordinator|FileWrapper|FileVersion|NSMetadataQuery|NSBundle|CFURL(?:CreateDataAndPropertiesFromResource|WriteDataAndPropertiesToResource|ResourceIsReachable|SetResourcePropert)|(?:read|write|create|remove|move|copy|replace|load|fetch|archive|init).*?(?:File|URL|Path)|(?:File|URL|Path).*?(?:write|create|remove|move|copy|replace|load|fetch|archive|init)|(?:to|From|WithContentsOf)(?:File|URL|Path)|resourceValues|ResourceValue|BookmarkData|AccessingSecurityScopedResource|WriteToFile|WriteToURL|CreateDirectory|MoveItem|CopyItem|RemoveItem|ReplaceItem|CreateFile|OpenFile|check.*Reachable|isReachable", re.I)),
)


def _clean_type(value: str) -> str:
    value = re.sub(r"\b(?:const|volatile|restrict|__kindof|_Nullable|_Nonnull|_Null_unspecified|nullable|nonnull|__nullable|__nonnull|CF_AVAILABLE|CF_DEPRECATED|NS_AVAILABLE|NS_DEPRECATED|API_AVAILABLE|API_DEPRECATED|NS_RETURNS_RETAINED|NS_RETURNS_NOT_RETAINED|CF_RETURNS_RETAINED|CF_RETURNS_NOT_RETAINED)\b", " ", value)
    value = re.sub(r"\s+", " ", value).strip()
    return value


def _base_type(value: str) -> str:
    value = _clean_type(value)
    value = re.sub(r"\[[^]]*\]", " ", value)
    return value.replace("*", " ").strip()


def _is_cf_ref(value: str) -> bool:
    return "*" not in value and bool(re.fullmatch(r"CF[A-Za-z0-9_]*Ref", _base_type(value)))


def _is_cf_string_alias(value: str) -> bool:
    return _base_type(value) in {
        "CFCalendarIdentifier", "CFDateFormatterKey", "CFLocaleIdentifier", "CFLocaleKey", "CFNotificationName",
        "CFNumberFormatterKey", "CFRunLoopMode", "CFStreamPropertyKey", "CFStringTransformIdentifier",
    }


def _is_objc_object(value: str) -> bool:
    base = _base_type(value)
    named_string = base.startswith("NS") and base.endswith(("Key", "Name", "Identifier", "Domain"))
    if _is_function_pointer(value) or _scalar_kind(value) or _pointer_depth(value) > 1:
        return False
    if base in {"id", "Class", "instancetype"} or re.fullmatch(r"id<[^>]+>", base):
        if base == "id<NSPredicateValidating>":
            return False
        return True
    if _is_cf_string_alias(value) or named_string:
        return True
    if base in {"NSZone", "NSDecimal", "NSHashEnumerator", "NSMapEnumerator", "NSPredicateValidating", "NSHashTableCallBacks",
                "NSMapTableKeyCallBacks", "NSMapTableValueCallBacks", "NSUncaughtExceptionHandler"}:
        return False
    return bool("*" in value and re.fullmatch(r"(?:NS|__NS)[A-Za-z0-9_]+", base))


def _pointer_depth(value: str) -> int:
    return value.count("*")


def _is_function_pointer(value: str) -> bool:
    return bool(re.search(r"\(\s*\*|\(\s*\^|\(\s*\*\s*\w+\s*\)", value))


def _enum_pool(parameter: dict, enum_values: list[dict]) -> list[int]:
    names = {_clean_type(parameter.get("type", "")), _clean_type(parameter.get("desugared_type", ""))}
    enum_match = re.search(r"\benum\s+(\w+)", " ".join(names))
    if enum_match:
        names.add(enum_match.group(1))
    prefixes = {
        "CFStringEncoding": ("kCFStringEncoding",),
        "CFStringCompareFlags": ("kCFCompare",),
        "CFNumberFormatterStyle": ("kCFNumberFormatter",),
        "CFDateFormatterStyle": ("kCFDateFormatter",),
    }
    type_name = _base_type(parameter.get("type", ""))
    wanted_prefixes = prefixes.get(type_name, ())
    values = []
    for entry in enum_values:
        matched_enum = entry.get("enum") in names or entry.get("enum") and re.search(
            rf"\b{re.escape(entry['enum'])}\b", " ".join(names))
        matched_prefix = any(entry.get("name", "").startswith(prefix) for prefix in wanted_prefixes)
        if matched_enum or matched_prefix:
            try:
                numeric = int(str(entry.get("value")), 0)
            except ValueError:
                continue
            if numeric not in values:
                values.append(numeric)
    return values[:MAX_CASES]


def _category(name: str) -> str:
    lower = name.lower()
    if "string" in lower or "character" in lower or "tokenizer" in lower:
        return "strings"
    if "number" in lower or "decimal" in lower or "math" in lower:
        return "numbers"
    if "date" in lower or "calendar" in lower or "timezone" in lower or "time_zone" in lower:
        return "dates"
    if "url" in lower or "uri" in lower:
        return "urls"
    if "data" in lower or "stream" in lower:
        return "data"
    if "array" in lower or "dictionary" in lower or "set" in lower or "collection" in lower:
        return "collections"
    if "error" in lower or "exception" in lower:
        return "errors"
    return "other"


def _skip_reason(name: str) -> str | None:
    for category, pattern in SIDE_EFFECT_RULES:
        if pattern.search(name):
            return f"side-effect category: {category}"
    if name == "CFGetRetainCount":
        return "runtime-specific value: retain counts are not stable across implementations"
    if name in {"NSDeallocateObject", "NSDecrementExtraRefCountWasZero", "NSExtraRefCount"}:
        return "object lifetime helper needs a privately owned runtime object"
    return None


def _int_values(parameter: dict) -> list[int]:
    qtype = _clean_type(parameter.get("type", ""))
    desugared = _clean_type(parameter.get("desugared_type", qtype))
    typename = _base_type(desugared or qtype)
    name = parameter.get("name", "").lower()
    if name in {"basedirection", "direction", "writingdirection"}:
        # NSWritingDirection has only Natural, LTR, and RTL as documented inputs.
        return [-1, 0, 1]
    if (name.startswith("idx") or any(word in name for word in
            ("index", "indices", "location", "loc", "offset", "position", "start", "end"))):
        return [0, 1]
    if "page" in name:
        return [1, 2, 4]
    if "byte" in name:
        return [0, 1, 2, 16]
    if "scale" in name:
        return [-2, 0, 2]
    if any(word in name for word in ("flags", "options", "mask")):
        return [0, 1, 2]
    if any(word in name for word in ("length", "count", "capacity", "size", "limit", "bits", "num", "len")):
        # These values stay inside the small objects the input pool creates.
        return [0, 1, 2]
    if "hour" in name:
        return [0, 1, 12]
    if "minute" in name or "second" in name:
        return [0, 1, 59]
    if "month" in name:
        return [1, 2, 12]
    if "day" in name:
        return [1, 2, 28]
    if "year" in name or name == "value":
        return [0, 1, -1, 2]
    if "unsigned" in desugared or typename.startswith("u") or typename in ("size_t", "NSUInteger", "CFOptionFlags"):
        return [0, 1, 2, 255, 65535, 2**32 - 1, 2**64 - 1]
    if "char" in typename:
        return [0, 1, -1, 127, -128]
    if "short" in typename:
        return [0, 1, -1, 32767, -32768]
    if "long long" in desugared or typename in ("int64_t", "NSInteger", "CFIndex", "long"):
        return [0, 1, -1, 2**63 - 1, -(2**63)]
    return [0, 1, -1, 2**31 - 1, -(2**31)]


def _float_values() -> list[str]:
    return ["0.0", "-0.0", "INFINITY", "-INFINITY", "NAN", "0x1p-1074", "0.5"]


def _is_time_type(value: str) -> bool:
    return _base_type(value) in {"CFAbsoluteTime", "CFTimeInterval", "NSTimeInterval"}


def _scalar_kind(value: str) -> str | None:
    clean = _clean_type(value)
    base = _base_type(clean)
    if base in ("BOOL", "Boolean", "bool", "_Bool"):
        return "bool"
    if base in ("float", "double", "long double", "CGFloat", "CFAbsoluteTime", "CFTimeInterval", "NSTimeInterval"):
        return "float"
    if base in ("CFRange", "NSRange"):
        return "range"
    if base in ("CGPoint", "CGSize", "CGRect", "NSPoint", "NSSize", "NSRect", "CGAffineTransform", "CATransform3D"):
        return "struct"
    if base in ("void", "id", "Class", "SEL", "instancetype"):
        return None
    if re.fullmatch(r"(?:unsigned|signed)?\s*(?:char|short|int|long|long long|size_t|ssize_t|NSUInteger|NSInteger|CFIndex|CFOptionFlags|CFTypeID|CFStringEncoding|CFNumberType|CFCalendarUnit|CFStringCompareFlags|unichar|UniChar|UTF32Char|UInt8|UInt16|UInt32|UInt64|SInt8|SInt16|SInt32|SInt64|uint8_t|uint16_t|uint32_t|uint64_t|int8_t|int16_t|int32_t|int64_t|NSComparisonResult|CFComparisonResult)", base):
        return "integer"
    if re.fullmatch(r"(?:NS|CF)[A-Za-z0-9_]*(?:Options|Flags|Mask|Style|Type|Unit|Mode|Kind|Format|Encoding|Result|State|Status|Policy|Level|Order|Direction|Phase|Quality|RoundingMode)", base):
        return "integer"
    return None


def _c_input(parameter: dict, index: int, enum_values: list[dict], function_name: str,
             nonempty_objects: bool = False) -> tuple[str, list[str], list[str]] | tuple[None, str, None]:
    """Return expression, declarations, output readers; reject unsafe unknown pointers."""
    qtype = parameter.get("type", "")
    clean = _clean_type(qtype)
    base = _base_type(clean)
    name = parameter.get("name", f"arg{index}")
    case_index = f"typed_case_{index}"
    safe_name = re.sub(r"\W+", "_", name)
    local = f"typed_arg_{index}"
    if _is_function_pointer(qtype):
        return None, "callback parameters need API-specific safe blocks", None
    if base == "CFAllocatorRef":
        if "deallocator" in name.lower():
            return "kCFAllocatorNull", [], []
        return "kCFAllocatorDefault", [], []
    if base == "CFNotificationCenterRef":
        return "(CFNotificationCenterRef)CFNotificationCenterGetLocalCenter()", [], []
    if _is_cf_string_alias(qtype):
        if base == "CFLocaleIdentifier":
            return f"(CFLocaleIdentifier)auto_locale_identifier({case_index})", [], []
        constant = {
            "CFCalendarIdentifier": "kCFGregorianCalendar",
            "CFDateFormatterKey": "kCFDateFormatterTimeZone",
            "CFLocaleKey": "kCFLocaleIdentifier",
            "CFNotificationName": "kCFTimeZoneSystemTimeZoneDidChangeNotification",
            "CFNumberFormatterKey": "kCFNumberFormatterDecimalSeparator",
            "CFRunLoopMode": "kCFRunLoopDefaultMode",
            "CFStreamPropertyKey": "kCFStreamPropertyDataWritten",
            "CFStringTransformIdentifier": "kCFStringTransformToLatin",
        }.get(base)
        if constant:
            return f"({qtype}){constant}", [], []
        return None, f"no declared string constant for {base}", None
    if _is_objc_object(qtype):
        type_literal = json.dumps(qtype)
        expr = f"({qtype})auto_object(@{type_literal}, {case_index})"
        if parameter.get("nullable"):
            expr = f"({qtype})({case_index} == 7 ? NULL : {expr})"
        return expr, [], []
    if _is_cf_ref(qtype):
        if base == "CFReadStreamRef":
            return f"(CFReadStreamRef)auto_cf_input(\"CFReadStreamRef\", {case_index}, 0, {json.dumps(function_name)}, {json.dumps(name)})", [], []
        if base == "CFWriteStreamRef":
            return f"(CFWriteStreamRef)auto_cf_input(\"CFWriteStreamRef\", {case_index}, 0, {json.dumps(function_name)}, {json.dumps(name)})", [], []
        if base in ("CFTypeRef", "CFPropertyListRef", "CFArrayRef", "CFMutableArrayRef", "CFDictionaryRef", "CFMutableDictionaryRef", "CFSetRef", "CFMutableSetRef", "CFBagRef", "CFMutableBagRef", "CFStringRef", "CFMutableStringRef", "CFDataRef", "CFMutableDataRef", "CFDateRef", "CFNumberRef", "CFBooleanRef", "CFNullRef", "CFURLRef", "CFUUIDRef", "CFCharacterSetRef", "CFMutableCharacterSetRef", "CFLocaleRef", "CFTimeZoneRef", "CFCalendarRef", "CFErrorRef", "CFAttributedStringRef", "CFMutableAttributedStringRef", "CFDateFormatterRef", "CFNumberFormatterRef"):
            nonempty = int(nonempty_objects or bool(re.search(r"Index|Indices|Range|Bytes|Character|Substring|Delete|Replace|Insert|Append|Localizations|Combining", function_name, re.I)))
            expr = f"({qtype})auto_cf_input(\"{base}\", {case_index}, {nonempty}, {json.dumps(function_name)}, {json.dumps(name)})"
            if parameter.get("nullable"):
                expr = f"({qtype})({case_index} == 7 ? NULL : {expr})"
            return expr, [], []
        if parameter.get("nullable"):
            return f"({qtype})NULL", [], []
        return None, f"no safe object factory for {base}", None

    if base == "CFTypeID":
        return f"(CFTypeID)auto_type_id({case_index})", [], []
    if base == "CFStringEncoding" and function_name in {
        "CFStringCreateWithCString", "CFStringCreateWithCStringNoCopy", "CFStringAppendCString"
    }:
        values_name = f"typed_encoding_{index}"
        decl = f"static const CFStringEncoding {values_name}[] = {{kCFStringEncodingMacRoman, kCFStringEncodingWindowsLatin1, kCFStringEncodingISOLatin1, kCFStringEncodingASCII, kCFStringEncodingUTF8}};"
        return f"({qtype}){values_name}[{case_index} % (sizeof({values_name}) / sizeof({values_name}[0]))]", [decl], []
    if function_name == "CFDataCreateMutableCopy" and name.lower() == "capacity":
        return f"({qtype})0", [], []
    if function_name == "CFStringGetHyphenationLocationBeforeIndex" and name.lower() == "location":
        values_name = f"typed_hyphenation_location_{index}"
        decl = f"static const CFIndex {values_name}[] = {{5, 8}};"
        return f"({qtype}){values_name}[{case_index} % 2]", [decl], []
    if function_name in {"CFStringGetFileSystemRepresentation", "CFURLGetFileSystemRepresentation"} and "len" in name.lower():
        return f"({qtype})65537", [], []
    if function_name == "CFNumberCreate" and base == "CFNumberType":
        return "(CFNumberType)kCFNumberSInt64Type", [], []
    if function_name == "CFNumberFormatterCreateStringWithValue" and base == "CFNumberType":
        return "(CFNumberType)kCFNumberDoubleType", [], []

    if function_name == "CFNumberCreate" and _pointer_depth(qtype) == 1 and "void" in base and "value" in name.lower():
        decl = f"static const int64_t {local}[] = {{0, 1, -1, INT64_MAX, INT64_MIN, 42, -257, 255}};"
        return f"(const void *)&{local}[{case_index} % (sizeof({local}) / sizeof({local}[0]))]", [decl], []
    if function_name == "CFNumberFormatterCreateStringWithValue" and _pointer_depth(qtype) == 1 and "void" in base and "value" in name.lower():
        decl = f"static const double {local}[] = {{0.0, -0.0, 0.5, -1.25, 42.0, 1e6, 1e-6, 3.14159}};"
        return f"(const void *)&{local}[{case_index} % (sizeof({local}) / sizeof({local}[0]))]", [decl], []

    scalar_kind = _scalar_kind(qtype) if not _pointer_depth(qtype) else None
    if scalar_kind == "integer":
        choices = _enum_pool(parameter, enum_values)
        if choices:
            values_name = f"typed_enum_{index}"
            decl = f"static const long long {values_name}[] = {{{', '.join(str(v) for v in choices)}}};"
            return f"({qtype}){values_name}[{case_index} % (sizeof({values_name}) / sizeof({values_name}[0]))]", [decl], []
        values = _int_values(parameter)
        values_name = f"typed_int_{index}"
        unsigned = "unsigned" in _clean_type(parameter.get("desugared_type", qtype)) or base.startswith("u") or base in ("size_t", "NSUInteger", "CFOptionFlags", "CFTypeID", "UInt8", "UInt16", "UInt32", "UInt64")
        if unsigned:
            literal_values = [f"{value}ULL" if value >= 0 else f"({value})" for value in values]
            storage_type = "unsigned long long"
        else:
            literal_values = ["(-9223372036854775807LL - 1LL)" if value == -(2**63) else f"{value}LL" for value in values]
            storage_type = "long long"
        decl = f"static const {storage_type} {values_name}[] = {{{', '.join(literal_values)}}};"
        return f"({qtype}){values_name}[{case_index} % (sizeof({values_name}) / sizeof({values_name}[0]))]", [decl], []
    if scalar_kind == "bool":
        return f"({qtype})({case_index} & 1)", [], []
    if scalar_kind == "float":
        return f"({qtype})auto_time({case_index})" if _is_time_type(qtype) else f"({qtype})auto_real({case_index})", [], []
    if scalar_kind == "range":
        if base == "CFRange":
            if function_name == "CFStringGetHyphenationLocationBeforeIndex":
                return "CFRangeMake(0, 11)", [], []
            return f"CFRangeMake(0, (CFIndex)({case_index} & 1))", [], []
        return None, "NSRange is unavailable in this CoreFoundation C input context", None
    if scalar_kind == "struct":
        return f"({qtype}){{0}}", [], []

    depth = _pointer_depth(clean)
    if depth:
        if depth > 2:
            return None, f"unsupported {depth}-level pointer parameter", None
        if depth == 1 and base == "NSDecimal":
            number = f"typed_decimal_number_{index}"
            initial = f"[NSDecimalNumber decimalNumberWithString:decimal_values_{index}[{case_index} % 4]]" if "const" in qtype else "[NSDecimalNumber zero]"
            declarations = [
                f"static NSString *const decimal_values_{index}[] = {{@\"0\", @\"1.25\", @\"-1.5\", @\"999999.125\"}};",
                f"NSDecimalNumber *{number} = {initial};",
                f"NSDecimal {local} = [{number} decimalValue];",
            ]
            reader = f"auto_print(auto_canonical([NSDecimalNumber decimalNumberWithDecimal:{local}]));"
            return f"({qtype})&{local}", declarations, [reader]
        if re.search(r"\b(?:char|signed char|unsigned char|UInt8|SInt8|uint8_t|int8_t)\s*\*", clean) and depth == 1:
            if function_name in {"CFAttributedStringGetBidiLevelsAndResolvedDirections", "CFAttributedStringGetStatisticalWritingDirections"} and re.search(r"bidi|level|direction", name, re.I):
                decl = f"UInt8 {local}[256] = {{0}};"
                return f"({qtype}){local}", [decl], [f"auto_print_bytes({local}, sizeof({local}));"]
            if function_name in ("CFStringCreateWithBytes", "CFStringCreateWithBytesNoCopy") and "bytes" in name.lower():
                decl = f"static const UInt8 {local}[] = {{'a', 'b', 'c', 0xc3, 0xa9}};"
                return f"({qtype}){local}", [decl], []
            if "const" in qtype:
                if re.search(r"\b(?:UInt8|SInt8|uint8_t|int8_t|unsigned char)\b", clean):
                    decl = f"static const UInt8 {local}[] = {{0, 1, 127, 128, 254, 255}};"
                    return f"({qtype}){local}", [decl], []
                return f"(const char *)samples[{case_index} % SAMPLE_COUNT]", [], []
            if any(word in name.lower() for word in ("buffer", "output", "result", "out")):
                if function_name in {"CFStringGetFileSystemRepresentation", "CFURLGetFileSystemRepresentation"}:
                    decl = f"UInt8 {local}[65537] = {{0}};"
                    return f"({qtype}){local}", [decl], [f"auto_print_cstring((const char *){local});"]
                decl = f"UInt8 {local}[256] = {{0}};"
                return f"({qtype}){local}", [decl], [f"auto_print_bytes({local}, sizeof({local}));"]
            return f"({qtype})samples[{case_index} % SAMPLE_COUNT]", [], []
        if re.search(r"\b(?:UniChar|unichar|UTF16Char)\s*\*", clean) and depth == 1:
            if "const" in qtype:
                decl = f"static const UniChar {local}[] = {{'a', 0x00e9, 0x4e2d, 0}};"
                return f"({qtype}){local}", [decl], []
            decl = f"UniChar {local}[256] = {{0}};"
            return f"({qtype}){local}", [decl], [f"auto_print_bytes((const UInt8 *){local}, sizeof({local}));"]
        if depth == 1 and "void" in base and "const" in qtype:
            if any(word in name.lower() for word in ("bytes", "buffer", "characters")):
                decl = f"static const UInt8 {local}[] = {{0, 1, 127, 128, 254, 255}};"
                return f"({qtype}){local}", [decl], []
            return f"({qtype})auto_cf_input(\"CFTypeRef\", {case_index}, 0, {json.dumps(function_name)}, {json.dumps(name)})", [], []
        if depth == 2 and "void" in base and any(word in name.lower() for word in ("values", "keys")):
            if function_name.startswith(("CFArrayGetValues", "CFDictionaryGetKeysAndValues", "CFSetGetValues", "CFBagGetValues")):
                decl = f"const void *{local}[32] = {{0}};"
                return f"({qtype}){local}", [decl], [f"auto_print_cf((CFTypeRef){local}[0]);"]
            decl = f"const void *{local}[4] = {{(CFTypeRef)auto_cf_input(\"CFStringRef\", {case_index}, 1, {json.dumps(function_name)}, {json.dumps(name)}), (CFTypeRef)auto_cf_input(\"CFNumberRef\", {case_index}, 0, {json.dumps(function_name)}, {json.dumps(name)}), NULL, NULL}};"
            return f"({qtype}){local}", [decl], []
        if "CallBacks" in base and depth == 1:
            symbol = {
                "CFArrayCallBacks": "kCFTypeArrayCallBacks",
                "CFDictionaryKeyCallBacks": "kCFTypeDictionaryKeyCallBacks",
                "CFDictionaryValueCallBacks": "kCFTypeDictionaryValueCallBacks",
                "CFSetCallBacks": "kCFTypeSetCallBacks",
                "CFBagCallBacks": "kCFTypeBagCallBacks",
            }.get(base)
            if symbol:
                return f"({qtype})&{symbol}", [], []
        pointee = base
        if pointee == "void":
            if parameter.get("nullable") and "valuePtr" not in name and "buffer" not in name.lower():
                return "NULL", [], []
            if any(word in name.lower() for word in ("value", "buffer", "bytes", "result", "out", "destination")):
                decl = f"long double {local}[16] = {{0}};"
                return f"(void *){local}", [decl], [f"auto_print_bytes((const UInt8 *){local}, sizeof({local}));"]
            return None, "void pointer has no documented input or output role", None
        if depth == 1 and pointee in ("CFRange", "NSRange"):
            decl = f"{pointee} {local} = {{0, 0}};" if pointee == "CFRange" else ""
            # NSRange is not part of a CoreFoundation C harness.
            if not decl:
                return None, "unsupported range pointer in this framework", None
            return f"({qtype})&{local}", [decl], [f"printf(\"%ld,%ld\", (long){local}.location, (long){local}.length);"]
        if depth == 1 and _scalar_kind(pointee) in ("integer", "bool", "float", "struct"):
            if "const" in qtype:
                return None, "input pointer lacks a safe backing value", None
            init = "{0}" if _scalar_kind(pointee) == "struct" else "0"
            decl = f"{pointee} {local} = {init};"
            if _scalar_kind(pointee) == "float":
                reader = f"printf(\"%a\", (double){local});"
            else:
                reader = f"printf(\"%lld\", (long long){local});"
            return f"({qtype})&{local}", [decl], [reader]
        if depth == 1 and _is_cf_ref(pointee):
            decl = f"{pointee} {local} = NULL;"
            return f"({qtype})&{local}", [decl], [f"auto_print_cf((CFTypeRef){local});"]
        return None, f"no safe value builder for pointer type {qtype}", None
    return None, f"no safe input pool for type {qtype}", None


def _c_return(type_name: str, variable: str = "typed_result") -> tuple[str | None, str | None]:
    clean = _clean_type(type_name)
    base = _base_type(clean)
    if base == "void" and "*" not in clean:
        return 'fputs("void", stdout);', None
    if base == "CFTypeID":
        return f"auto_print_typeid({variable});", None
    if _is_cf_ref(clean):
        return f"auto_print_cf((CFTypeRef){variable});", None
    if _is_cf_string_alias(clean):
        return f"auto_print_cf((CFTypeRef){variable});", None
    if _is_objc_object(clean):
        return f"auto_print(auto_canonical({variable}));", None
    if "*" in clean:
        if "char *" in clean:
            return f"auto_print_cstring((const char *){variable});", None
        return f'printf("pointer:%s", {variable} ? "nonnull" : "null");', None
    scalar = _scalar_kind(clean)
    if scalar == "float":
        return f'printf("%a", (double){variable});', None
    if scalar == "range" and base == "CFRange":
        return f'printf("%ld,%ld", (long){variable}.location, (long){variable}.length);', None
    if scalar in ("integer", "bool"):
        if "unsigned" in clean or base.startswith("u") or base in ("size_t", "NSUInteger", "CFOptionFlags", "CFTypeID", "UInt8", "UInt16", "UInt32", "UInt64"):
            return f'printf("%llu", (unsigned long long){variable});', None
        return f'printf("%lld", (long long){variable});', None
    return None, f"unsupported return type {type_name}"


def _make_c_function(function: dict, enum_values: list[dict], finch_symbols: set[str]) -> tuple[str | None, str | None]:
    name = function["name"]
    reason = _skip_reason(name)
    if reason:
        return None, reason
    if function.get("inline"):
        return None, "SDK inline function has no Finch framework implementation to compare"
    if function.get("symbol") not in finch_symbols:
        return None, "Finch framework does not export this C symbol"
    if function.get("variadic"):
        return None, "variadic functions need API-specific format arguments"
    return_type = _clean_type(function.get("return_type", ""))
    return_code, reason = _c_return(return_type)
    if reason:
        return None, reason
    declarations = []
    arguments = []
    readers = []
    parameters = function.get("parameters", [])
    nonempty_objects = any(re.search(r"range|index|indices|idx|position|location|\bloc\b", p.get("name", ""), re.I)
                           for p in parameters)
    for index, parameter in enumerate(parameters):
        declarations.append(f"const size_t typed_case_{index} = (case_index * {index * 2 + 1} + {index}) % {MAX_CASES};")
        expr, decl, out = _c_input(parameter, index, enum_values, name, nonempty_objects)
        if expr is None:
            return None, decl
        declarations.extend(decl)
        readers.extend(out)
        qtype = parameter.get("type", "")
        base = _base_type(qtype)
        if _is_cf_ref(qtype) and base.startswith("CFMutable"):
            local = f"typed_object_{index}"
            declarations.append(f"{qtype} {local} = {expr};")
            arguments.append(local)
            readers.append(f"auto_print_cf((CFTypeRef){local});")
        else:
            arguments.append(expr)
    case_count = MAX_CASES if function.get("parameters") else 1
    func_name = "typed_c_" + re.sub(r"\W+", "_", name)
    lines = [f"static void {func_name}(void)", "{", f"    for (size_t case_index = 0; case_index < {case_count}; case_index++) {{"]
    lines.extend(f"        {decl}" for decl in declarations)
    call = f"{name}({', '.join(arguments)})"
    if _base_type(return_type) == "void" and "*" not in return_type:
        lines.append(f"        {call};")
        lines.append('        printf("%zu\\t", case_index);')
        lines.append(f"        {return_code}")
    else:
        lines.append(f"        {return_type} typed_result = {call};")
        lines.append('        printf("%zu\\t", case_index);')
        lines.append(f"        {return_code}")
    for reader in readers:
        lines.append('        putchar(\'\\t\');')
        lines.append(f"        {reader}")
    lines.extend(["        putchar('\\n');", "    }", "}"])
    return "\n".join(lines), None


def _make_c_variable(variable: dict, finch_symbols: set[str]) -> tuple[str | None, str | None]:
    name = variable["name"]
    if variable.get("symbol") not in finch_symbols:
        return None, "Finch framework does not export this C symbol"
    declared_type = variable.get("type", "")
    qtype = declared_type
    base = _base_type(qtype)
    if name.startswith("kCFAllocator"):
        printer = f'printf("pointer:%s", {name} ? "nonnull" : "null");'
    elif _base_type(qtype) == "CFTypeID":
        printer = f"auto_print_typeid({name});"
    elif _is_cf_ref(qtype):
        printer = f"auto_print_cf((CFTypeRef){name});"
    elif _is_cf_string_alias(qtype):
        printer = f"auto_print_cf((CFTypeRef){name});"
    else:
        # Public NSString aliases such as NSFileAttributeKey and
        # NSExceptionName are pointers after Clang resolves their typedef.
        qtype = variable.get("desugared_type", qtype)
        base = _base_type(qtype)
        if _is_objc_object(qtype):
            printer = f"auto_print(auto_canonical({name}));"
        elif _scalar_kind(qtype) == "float":
            printer = f'printf("%a", (double){name});'
        elif _scalar_kind(qtype) in ("integer", "bool"):
            cast = "unsigned long long" if "unsigned" in qtype or base.startswith("u") else "long long"
            printer = f'printf("%llu", ({cast}){name});' if cast.startswith("unsigned") else f'printf("%lld", ({cast}){name});'
        elif _scalar_kind(qtype) == "range" and base == "CFRange":
            printer = f'printf("%ld,%ld", (long){name}.location, (long){name}.length);'
        elif "char *" in qtype:
            printer = f"auto_print_cstring((const char *){name});"
        elif "*" in qtype:
            printer = f'printf("pointer:%s", {name} ? "nonnull" : "null");'
        else:
            return None, f"no canonical reader for variable type {declared_type}"
    func_name = "typed_v_" + re.sub(r"\W+", "_", name)
    return f"static void {func_name}(void) {{ {printer} putchar('\\n'); }}", None


def _c_runtime() -> str:
    return r'''
static double auto_real(size_t index)
{
    static const double values[] = {0.0, -0.0, INFINITY, -INFINITY, NAN, 0x1p-1074, 0.5};
    return values[index % (sizeof(values) / sizeof(values[0]))];
}

static double auto_time(size_t index)
{
    static const double values[] = {0.0, -1.0, 700000000.0, 800000000.0,
        1000000000.0, 123456789.0, 31536000.0, 86400.0};
    return values[index % (sizeof(values) / sizeof(values[0]))];
}

static void auto_print_cstring(const char *value)
{
    if (!value) { fputs("null", stdout); return; }
    for (const unsigned char *p = (const unsigned char *)value; *p; p++) printf("%02x", *p);
}

static void auto_print_bytes(const UInt8 *value, size_t length)
{
    for (size_t i = 0; i < length; i++) printf("%02x", value[i]);
}

static CFStringRef auto_cf_canonical(CFTypeRef value);

static void auto_append_hex(CFMutableStringRef out, const UInt8 *bytes, size_t length)
{
    for (size_t i = 0; i < length; i++) CFStringAppendFormat(out, NULL, CFSTR("%02x"), bytes[i]);
}

static CFComparisonResult auto_compare_cf_text(const void *left, const void *right, void *context)
{
    (void)context;
    return CFStringCompare((CFStringRef)left, (CFStringRef)right, 0);
}

static CFStringRef auto_string(size_t index, int nonempty)
{
    static const size_t choices[] = {0, 3, 8, 15, SAMPLE_COUNT - 1};
    static const size_t nonempty_choices[] = {3, 8, 15, SAMPLE_COUNT - 1};
    if (nonempty) {
        const char *text = samples[nonempty_choices[index % (sizeof(nonempty_choices) / sizeof(nonempty_choices[0]))]];
        return CFStringCreateWithBytes(kCFAllocatorDefault, (const UInt8 *)text, (CFIndex)strlen(text), kCFStringEncodingUTF8, false);
    }
    const char *text = samples[choices[index % (sizeof(choices) / sizeof(choices[0]))]];
    return CFStringCreateWithBytes(kCFAllocatorDefault, (const UInt8 *)text, (CFIndex)strlen(text), kCFStringEncodingUTF8, false);
}

static CFStringRef auto_locale_identifier(size_t index)
{
    static CFStringRef values[] = {CFSTR("en_US_POSIX"), CFSTR("fr_CA"), CFSTR("ar_EG")};
    return values[index % (sizeof(values) / sizeof(values[0]))];
}

static CFTypeID auto_type_id(size_t index)
{
    switch (index % 8) {
        case 0: return CFStringGetTypeID();
        case 1: return CFNumberGetTypeID();
        case 2: return CFArrayGetTypeID();
        case 3: return CFDictionaryGetTypeID();
        case 4: return CFSetGetTypeID();
        case 5: return CFDataGetTypeID();
        case 6: return CFDateGetTypeID();
        default: return CFURLGetTypeID();
    }
}

static CFTypeRef auto_cf_input(const char *type, size_t index, int nonempty,
    const char *function_name, const char *parameter_name)
{
    CFStringRef s = auto_string(index, nonempty);
    if (!strcmp(function_name, "CFDateFormatterCreateDateFormatFromTemplate")) {
        static CFStringRef templates[] = {CFSTR("yMd"), CFSTR("MMMMd"), CFSTR("Hm"), CFSTR("EEE")};
        CFRelease(s); s = CFStringCreateCopy(kCFAllocatorDefault,
            templates[index % (sizeof(templates) / sizeof(templates[0]))]);
    }
    static const double numberValues[] = {0.0, -0.0, INFINITY, -INFINITY, NAN, 0x1p-1074, 0.5, 1.0, -1.0};
    double value = numberValues[index % (sizeof(numberValues) / sizeof(numberValues[0]))];
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &value);
    static const UInt8 bytes[] = {0, 1, 127, 128, 254, 255};
    CFIndex dataLength = nonempty ? (CFIndex)(index % sizeof(bytes) + 1) : (CFIndex)(index % (sizeof(bytes) + 1));
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, bytes, dataLength);
    CFDateRef date = CFDateCreate(kCFAllocatorDefault, (CFAbsoluteTime[]){0, -1, 700000000, 800000000}[index % 4]);
    if (!strcmp(type, "CFTypeRef") && !strcmp(function_name, "CFNumberFormatterSetProperty") &&
        !strcmp(parameter_name, "value")) {
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date);
        return CFStringCreateCopy(kCFAllocatorDefault, CFSTR("."));
    }
    if (!strcmp(type, "CFTypeRef") && !strcmp(function_name, "CFDateFormatterSetProperty") &&
        !strcmp(parameter_name, "value")) {
        CFTimeZoneRef zone = CFTimeZoneCreateWithName(kCFAllocatorDefault, CFSTR("UTC"), false);
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date); return zone;
    }
    if (!strcmp(type, "CFStringRef") || !strcmp(type, "CFMutableStringRef")) {
        if (!strcmp(function_name, "CFLocaleGetLanguageCharacterDirection") ||
            !strcmp(function_name, "CFLocaleGetLanguageLineDirection")) {
            static const char *languages[] = {"en", "ar", "he"};
            CFStringRef result = CFStringCreateWithCString(kCFAllocatorDefault,
                languages[index % (sizeof(languages) / sizeof(languages[0]))], kCFStringEncodingUTF8);
            CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date); return result;
        }
        if (!strcmp(function_name, "CFStringGetHyphenationLocationBeforeIndex")) {
            CFStringRef result = CFStringCreateCopy(kCFAllocatorDefault, CFSTR("hyphenation"));
            CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date); return result;
        }
        if (!strcmp(function_name, "CFStringCreateByCombiningStrings")) {
            CFRelease(s); s = CFStringCreateCopy(kCFAllocatorDefault, CFSTR(", "));
        }
        if (!strcmp(type, "CFMutableStringRef")) {
            CFMutableStringRef result = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, s);
            CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date); return result;
        }
        CFRelease(number); CFRelease(data); CFRelease(date); return s;
    }
    if (!strcmp(type, "CFDataRef") && !strcmp(function_name, "CFStringCreateFromExternalRepresentation")) {
        static const UInt8 utf8[] = {'a', 'b', 'c', 0xc3, 0xa9};
        CFRelease(s); CFRelease(number); CFRelease(date);
        CFIndex length = index % 2 ? 5 : 3;
        CFRelease(data); return CFDataCreate(kCFAllocatorDefault, utf8, length);
    }
    if (!strcmp(type, "CFNumberRef")) { CFRelease(s); CFRelease(data); CFRelease(date); return number; }
    if (!strcmp(type, "CFDateRef")) { CFRelease(s); CFRelease(number); CFRelease(data); return date; }
    if (!strcmp(type, "CFDataRef") || !strcmp(type, "CFMutableDataRef")) {
        if (!strcmp(type, "CFMutableDataRef")) {
            CFMutableDataRef result = CFDataCreateMutableCopy(kCFAllocatorDefault, 0, data);
            CFRelease(data); CFRelease(s); CFRelease(number); CFRelease(date); return result;
        }
        CFRelease(s); CFRelease(number); CFRelease(date); return data;
    }
    if (!strcmp(type, "CFBooleanRef")) {
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date);
        return (CFTypeRef)CFRetain(index & 1 ? kCFBooleanTrue : kCFBooleanFalse);
    }
    if (!strcmp(type, "CFNullRef")) {
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date); return (CFTypeRef)CFRetain(kCFNull);
    }
    if (!strcmp(type, "CFURLRef")) {
        CFRelease(number); CFRelease(data); CFRelease(date); CFRelease(s);
        static CFStringRef urls[] = {
            CFSTR("https://example.invalid/a%20b?q=1#part"),
            CFSTR("mailto:finch@example.invalid"),
            CFSTR("relative/path")
        };
        CFStringRef text = urls[index % (sizeof(urls) / sizeof(urls[0]))];
        return CFURLCreateWithString(kCFAllocatorDefault, text, NULL);
    }
    if (!strcmp(type, "CFUUIDRef")) {
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date);
        return CFUUIDCreateFromString(kCFAllocatorDefault, CFSTR("68753a44-4d6f-1226-9c60-0050e4c00067"));
    }
    if (!strcmp(type, "CFCharacterSetRef") || !strcmp(type, "CFMutableCharacterSetRef")) {
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date);
        CFCharacterSetRef set = CFCharacterSetCreateWithCharactersInString(kCFAllocatorDefault, CFSTR("aé中🙂"));
        if (!strcmp(type, "CFMutableCharacterSetRef")) {
            CFMutableCharacterSetRef mutable = CFCharacterSetCreateMutableCopy(kCFAllocatorDefault, set);
            CFRelease(set); return mutable;
        }
        return set;
    }
    if (!strcmp(type, "CFLocaleRef")) {
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date);
        if (strstr(function_name, "Hyphenation"))
            return CFLocaleCreate(kCFAllocatorDefault, CFSTR("en_US"));
        static CFStringRef identifiers[] = {CFSTR("en_US_POSIX"), CFSTR("fr_CA"), CFSTR("ar_EG")};
        return CFLocaleCreate(kCFAllocatorDefault, identifiers[index % (sizeof(identifiers) / sizeof(identifiers[0]))]);
    }
    if (!strcmp(type, "CFTimeZoneRef")) {
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date);
        static CFStringRef names[] = {CFSTR("UTC"), CFSTR("America/Toronto"), CFSTR("Asia/Kathmandu")};
        return CFTimeZoneCreateWithName(kCFAllocatorDefault, names[index % (sizeof(names) / sizeof(names[0]))], true);
    }
    if (!strcmp(type, "CFCalendarRef")) {
        CFLocaleRef locale = CFLocaleCreate(kCFAllocatorDefault, CFSTR("en_US_POSIX"));
        CFTimeZoneRef zone = CFTimeZoneCreateWithName(kCFAllocatorDefault, CFSTR("UTC"), false);
        CFCalendarRef result = CFCalendarCreateWithIdentifier(kCFAllocatorDefault,
            index & 1 ? kCFISO8601Calendar : kCFGregorianCalendar);
        CFCalendarSetLocale(result, locale); CFCalendarSetTimeZone(result, zone);
        CFRelease(locale); CFRelease(zone);
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date);
        return result;
    }
    if (!strcmp(type, "CFDateFormatterRef")) {
        CFLocaleRef locale = CFLocaleCreate(kCFAllocatorDefault, CFSTR("en_US_POSIX"));
        CFDateFormatterRef result = CFDateFormatterCreate(kCFAllocatorDefault, locale, kCFDateFormatterNoStyle, kCFDateFormatterNoStyle);
        CFRelease(locale); CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date); return result;
    }
    if (!strcmp(type, "CFReadStreamRef")) {
        CFReadStreamRef result = CFReadStreamCreateWithBytesNoCopy(kCFAllocatorDefault, bytes, dataLength, kCFAllocatorNull);
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date); return result;
    }
    if (!strcmp(type, "CFWriteStreamRef")) {
        CFWriteStreamRef result = CFWriteStreamCreateWithAllocatedBuffers(kCFAllocatorDefault, kCFAllocatorDefault);
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date); return result;
    }
    if (!strcmp(type, "CFNumberFormatterRef")) {
        CFLocaleRef locale = CFLocaleCreate(kCFAllocatorDefault, CFSTR("en_US_POSIX"));
        CFNumberFormatterRef result = CFNumberFormatterCreate(kCFAllocatorDefault, locale, kCFNumberFormatterDecimalStyle);
        CFRelease(locale); CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date); return result;
    }
    if (!strcmp(type, "CFErrorRef")) {
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date);
        return CFErrorCreate(kCFAllocatorDefault, CFSTR("org.finch.difftest"), 1, NULL);
    }
    if (!strcmp(type, "CFAttributedStringRef") || !strcmp(type, "CFMutableAttributedStringRef")) {
        CFRelease(number); CFRelease(data); CFRelease(date);
        CFAttributedStringRef result = CFAttributedStringCreate(kCFAllocatorDefault, s, NULL);
        CFRelease(s);
        if (!strcmp(type, "CFMutableAttributedStringRef")) {
            CFMutableAttributedStringRef mutable = CFAttributedStringCreateMutableCopy(kCFAllocatorDefault, 0, result);
            CFRelease(result); return mutable;
        }
        return result;
    }
    if (!strcmp(type, "CFBagRef") || !strcmp(type, "CFMutableBagRef")) {
        const void *values[] = {s, number};
        CFIndex count = nonempty || index % 4 != 0 ? 2 : 0;
        CFBagRef result = CFBagCreate(kCFAllocatorDefault, count ? values : NULL, count, &kCFTypeBagCallBacks);
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date);
        if (!strcmp(type, "CFMutableBagRef")) {
            CFMutableBagRef mutable = CFBagCreateMutableCopy(kCFAllocatorDefault, 0, result);
            CFRelease(result); return mutable;
        }
        return result;
    }
    if (!strcmp(type, "CFArrayRef") || !strcmp(type, "CFMutableArrayRef") || !strcmp(type, "CFPropertyListRef") || !strcmp(type, "CFTypeRef")) {
        Boolean localizations = strstr(function_name, "Localizations") != NULL;
        Boolean combiningStrings = !strcmp(function_name, "CFStringCreateByCombiningStrings");
        CFStringRef firstString = localizations ? auto_locale_identifier(index) : s;
        CFStringRef secondString = localizations ? auto_locale_identifier(index + 1) :
            (combiningStrings ? CFSTR("Finch") : NULL);
        const void *values[] = {firstString, (localizations || combiningStrings) ? secondString : number};
        CFIndex count = (localizations || combiningStrings) ? 2 : (nonempty || index % 4 != 0 ? 2 : 0);
        CFArrayRef result = CFArrayCreate(kCFAllocatorDefault, count ? values : NULL, count, &kCFTypeArrayCallBacks);
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date);
        if (!strcmp(type, "CFMutableArrayRef")) {
            CFMutableArrayRef mutable = CFArrayCreateMutableCopy(kCFAllocatorDefault, 0, result);
            CFRelease(result); return mutable;
        }
        return result;
    }
    if (!strcmp(type, "CFDictionaryRef") || !strcmp(type, "CFMutableDictionaryRef")) {
        const void *keys[] = {CFSTR("text"), CFSTR("number")};
        const void *values[] = {s, number};
        CFIndex count = nonempty || index % 4 != 0 ? 2 : 0;
        if (!strcmp(function_name, "CFLocaleCreateLocaleIdentifierFromComponents")) {
            keys[0] = kCFLocaleLanguageCode; keys[1] = kCFLocaleCountryCode;
            values[0] = CFSTR("en"); values[1] = CFSTR("CA"); count = 2;
        } else if (!strcmp(function_name, "CFTimeZoneSetAbbreviationDictionary")) {
            keys[0] = CFSTR("EST"); keys[1] = CFSTR("PST");
            values[0] = CFSTR("America/Toronto"); values[1] = CFSTR("America/Los_Angeles"); count = 2;
        }
        CFDictionaryRef result = CFDictionaryCreate(kCFAllocatorDefault, count ? keys : NULL, count ? values : NULL, count,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date);
        if (!strcmp(type, "CFMutableDictionaryRef")) {
            CFMutableDictionaryRef mutable = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, result);
            CFRelease(result); return mutable;
        }
        return result;
    }
    if (!strcmp(type, "CFSetRef") || !strcmp(type, "CFMutableSetRef")) {
        const void *values[] = {s, number};
        CFIndex count = nonempty || index % 4 != 0 ? 2 : 0;
        CFSetRef result = CFSetCreate(kCFAllocatorDefault, count ? values : NULL, count, &kCFTypeSetCallBacks);
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date);
        if (!strcmp(type, "CFMutableSetRef")) {
            CFMutableSetRef mutable = CFSetCreateMutableCopy(kCFAllocatorDefault, 0, result);
            CFRelease(result); return mutable;
        }
        return result;
    }
    CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date); return NULL;
}

static CFStringRef auto_cf_canonical(CFTypeRef value)
{
    if (!value) return CFStringCreateCopy(kCFAllocatorDefault, CFSTR("null"));
    CFTypeID type = CFGetTypeID(value);
    if (type == CFStringGetTypeID()) {
        CFStringRef string = (CFStringRef)value;
        CFIndex cap = CFStringGetMaximumSizeForEncoding(CFStringGetLength(string), kCFStringEncodingUTF8) + 1;
        UInt8 *bytes = malloc((size_t)cap);
        CFMutableStringRef out = CFStringCreateMutable(kCFAllocatorDefault, 0);
        CFStringAppend(out, CFSTR("string:"));
        if (!bytes || !CFStringGetCString(string, (char *)bytes, cap, kCFStringEncodingUTF8)) CFStringAppend(out, CFSTR("unencodable"));
        else auto_append_hex(out, bytes, strlen((const char *)bytes));
        free(bytes); return out;
    }
    if (type == CFNumberGetTypeID()) {
        double number = 0;
        CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &number);
        char text[96]; snprintf(text, sizeof(text), "number:%a", number);
        return CFStringCreateWithCString(kCFAllocatorDefault, text, kCFStringEncodingUTF8);
    }
    if (type == CFBooleanGetTypeID()) {
        return CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("bool:%d"), CFBooleanGetValue((CFBooleanRef)value));
    }
    if (type == CFDateGetTypeID()) {
        return CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("date:%a"), CFDateGetAbsoluteTime((CFDateRef)value));
    }
    if (type == CFDataGetTypeID()) {
        CFDataRef data = (CFDataRef)value;
        CFMutableStringRef out = CFStringCreateMutable(kCFAllocatorDefault, 0);
        CFStringAppendFormat(out, NULL, CFSTR("data:%ld:"), (long)CFDataGetLength(data));
        auto_append_hex(out, CFDataGetBytePtr(data), (size_t)CFDataGetLength(data)); return out;
    }
    if (type == CFURLGetTypeID()) {
        CFMutableStringRef out = CFStringCreateMutable(kCFAllocatorDefault, 0);
        CFStringAppend(out, CFSTR("url:"));
        CFStringRef string = CFURLGetString((CFURLRef)value);
        CFStringRef inner = auto_cf_canonical(string); CFStringAppend(out, inner); CFRelease(inner); return out;
    }
    if (type == CFErrorGetTypeID()) {
        CFErrorRef error = (CFErrorRef)value;
        CFStringRef domain = auto_cf_canonical(CFErrorGetDomain(error));
        CFMutableStringRef out = CFStringCreateMutable(kCFAllocatorDefault, 0);
        CFStringAppendFormat(out, NULL, CFSTR("error:%@:%ld"), domain, (long)CFErrorGetCode(error));
        CFRelease(domain); return out;
    }
    if (type == CFUUIDGetTypeID()) {
        CFStringRef string = CFUUIDCreateString(kCFAllocatorDefault, (CFUUIDRef)value);
        CFStringRef result = auto_cf_canonical(string); CFRelease(string); return result;
    }
    if (type == CFArrayGetTypeID()) {
        CFArrayRef array = (CFArrayRef)value;
        CFMutableStringRef out = CFStringCreateMutable(kCFAllocatorDefault, 0); CFStringAppend(out, CFSTR("array:["));
        for (CFIndex i = 0; i < CFArrayGetCount(array); i++) {
            if (i) CFStringAppend(out, CFSTR(","));
            CFStringRef part = auto_cf_canonical(CFArrayGetValueAtIndex(array, i)); CFStringAppend(out, part); CFRelease(part);
        }
        CFStringAppend(out, CFSTR("]")); return out;
    }
    if (type == CFSetGetTypeID() || type == CFBagGetTypeID()) {
        CFIndex count = type == CFSetGetTypeID() ? CFSetGetCount((CFSetRef)value) : CFBagGetCount((CFBagRef)value);
        const void **values = calloc((size_t)(count ? count : 1), sizeof(void *));
        if (type == CFSetGetTypeID()) CFSetGetValues((CFSetRef)value, values); else CFBagGetValues((CFBagRef)value, values);
        CFMutableArrayRef parts = CFArrayCreateMutable(kCFAllocatorDefault, count, &kCFTypeArrayCallBacks);
        for (CFIndex i = 0; i < count; i++) { CFStringRef part = auto_cf_canonical(values[i]); CFArrayAppendValue(parts, part); CFRelease(part); }
        CFArraySortValues(parts, CFRangeMake(0, count), auto_compare_cf_text, NULL);
        CFMutableStringRef out = CFStringCreateMutable(kCFAllocatorDefault, 0); CFStringAppend(out, CFSTR("set:{"));
        for (CFIndex i = 0; i < count; i++) { if (i) CFStringAppend(out, CFSTR(",")); CFStringAppend(out, CFArrayGetValueAtIndex(parts, i)); }
        CFStringAppend(out, CFSTR("}")); CFRelease(parts); free(values); return out;
    }
    if (type == CFDictionaryGetTypeID()) {
        CFDictionaryRef dictionary = (CFDictionaryRef)value; CFIndex count = CFDictionaryGetCount(dictionary);
        const void **keys = calloc((size_t)(count ? count : 1), sizeof(void *));
        const void **values = calloc((size_t)(count ? count : 1), sizeof(void *));
        CFDictionaryGetKeysAndValues(dictionary, keys, values);
        CFMutableArrayRef pairs = CFArrayCreateMutable(kCFAllocatorDefault, count, &kCFTypeArrayCallBacks);
        for (CFIndex i = 0; i < count; i++) {
            CFStringRef key = auto_cf_canonical(keys[i]), val = auto_cf_canonical(values[i]);
            CFStringRef pair = CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("%@=%@"), key, val);
            CFArrayAppendValue(pairs, pair); CFRelease(key); CFRelease(val); CFRelease(pair);
        }
        CFArraySortValues(pairs, CFRangeMake(0, count), auto_compare_cf_text, NULL);
        CFMutableStringRef out = CFStringCreateMutable(kCFAllocatorDefault, 0); CFStringAppend(out, CFSTR("dictionary:{"));
        for (CFIndex i = 0; i < count; i++) { if (i) CFStringAppend(out, CFSTR(",")); CFStringAppend(out, CFArrayGetValueAtIndex(pairs, i)); }
        CFStringAppend(out, CFSTR("}")); CFRelease(pairs); free(keys); free(values); return out;
    }
    if (type == CFLocaleGetTypeID()) {
        CFStringRef identifier = CFLocaleGetIdentifier((CFLocaleRef)value);
        return CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("locale:%@"), identifier);
    }
    if (type == CFTimeZoneGetTypeID()) {
        CFStringRef name = CFTimeZoneGetName((CFTimeZoneRef)value);
        return CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("timezone:%@:%ld"), name,
            (long)CFTimeZoneGetSecondsFromGMT((CFTimeZoneRef)value, 700000000));
    }
    if (type == CFCalendarGetTypeID()) {
        CFStringRef identifier = CFCalendarGetIdentifier((CFCalendarRef)value);
        return CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("calendar:%@"), identifier);
    }
    if (type == CFAttributedStringGetTypeID()) {
        CFStringRef string = CFAttributedStringGetString((CFAttributedStringRef)value);
        CFStringRef inner = auto_cf_canonical(string);
        CFStringRef result = CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("attributed:%@"), inner);
        CFRelease(inner); return result;
    }
    CFStringRef typeName = CFCopyTypeIDDescription(type);
    if (!typeName) return CFStringCreateCopy(kCFAllocatorDefault, CFSTR("object:opaque"));
    CFMutableStringRef out = CFStringCreateMutable(kCFAllocatorDefault, 0);
    CFStringAppend(out, CFSTR("object:type:")); CFStringAppend(out, typeName); CFRelease(typeName);
    return out;
}

static void auto_print_cf(CFTypeRef value)
{
    CFStringRef text = auto_cf_canonical(value);
    CFIndex cap = CFStringGetMaximumSizeForEncoding(CFStringGetLength(text), kCFStringEncodingUTF8) + 1;
    UInt8 *bytes = malloc((size_t)cap);
    if (!bytes || !CFStringGetCString(text, (char *)bytes, cap, kCFStringEncodingUTF8)) fputs("<unencodable>", stdout);
    else auto_print_cstring((const char *)bytes);
    free(bytes); CFRelease(text);
}

static void auto_print_typeid(CFTypeID type)
{
    if (type == CFMessagePortGetTypeID()) { fputs("typeid:CFMessagePort", stdout); return; }
    CFStringRef description = CFCopyTypeIDDescription(type);
    if (!description) { fputs("typeid:unknown", stdout); return; }
    CFIndex capacity = CFStringGetMaximumSizeForEncoding(CFStringGetLength(description), kCFStringEncodingUTF8) + 1;
    char *bytes = malloc((size_t)capacity);
    if (!bytes || !CFStringGetCString(description, bytes, capacity, kCFStringEncodingUTF8))
        fputs("typeid:unavailable", stdout);
    else {
        fputs("typeid:", stdout);
        auto_print_cstring(bytes);
    }
    free(bytes);
    CFRelease(description);
}
'''


def _objc_runtime() -> str:
    return r'''
static NSString *auto_clean_type(NSString *type)
{
    NSString *clean = [type stringByReplacingOccurrencesOfString:@"const" withString:@""];
    for (NSString *word in @[@"_Nullable", @"_Nonnull", @"_Null_unspecified", @"__nullable", @"__nonnull", @"nullable", @"nonnull", @"__kindof"])
        clean = [clean stringByReplacingOccurrencesOfString:word withString:@""];
    return [clean stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *auto_hex(NSString *value)
{
    value = [value stringByReplacingOccurrencesOfString:@"0x[0-9a-fA-F]+" withString:@"<ADDRESS>"
        options:NSRegularExpressionSearch range:NSMakeRange(0, value.length)];
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
    const unsigned char *bytes = data.bytes;
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < data.length; i++) [out appendFormat:@"%02x", bytes[i]];
    return out;
}

static NSString *auto_canonical(id value);

static NSString *auto_canonical(id value)
{
    if (!value || value == NSNull.null) return @"null";
    if ([value isKindOfClass:NSString.class]) return [@"string:" stringByAppendingString:auto_hex(value)];
    if ([value isKindOfClass:NSNumber.class]) {
        if (CFGetTypeID((CFTypeRef)value) == CFBooleanGetTypeID())
            return [NSString stringWithFormat:@"bool:%d", [value boolValue]];
        return [@"number:" stringByAppendingString:auto_hex([value stringValue])];
    }
    if ([value isKindOfClass:NSData.class]) {
        const unsigned char *bytes = [value bytes]; NSMutableString *hex = [NSMutableString stringWithFormat:@"data:%lu:", (unsigned long)[value length]];
        for (NSUInteger i = 0; i < [value length]; i++) [hex appendFormat:@"%02x", bytes[i]];
        return hex;
    }
    if ([value isKindOfClass:NSDate.class]) return [NSString stringWithFormat:@"date:%a", [value timeIntervalSinceReferenceDate]];
    if ([value isKindOfClass:NSDateComponents.class]) {
        NSDateComponents *parts = value;
        NSString *calendar = parts.calendar.calendarIdentifier ?: @"";
        NSString *zone = parts.timeZone.name ?: @"";
        return [NSString stringWithFormat:@"date-components:%ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%d:%@:%@",
            (long)parts.era, (long)parts.year, (long)parts.month, (long)parts.day, (long)parts.hour,
            (long)parts.minute, (long)parts.second, (long)parts.nanosecond, (long)parts.weekday,
            (long)parts.weekdayOrdinal, (long)parts.quarter, (long)parts.weekOfMonth,
            (long)parts.weekOfYear, parts.isLeapMonth, auto_hex(calendar), auto_hex(zone)];
    }
    if ([value isKindOfClass:NSURL.class]) return [@"url:" stringByAppendingString:auto_hex([value absoluteString] ?: @"")];
    if ([value isKindOfClass:NSURLComponents.class]) return [@"url-components:" stringByAppendingString:auto_hex([value string] ?: @"")];
    if ([value isKindOfClass:NSLocale.class]) return [@"locale:" stringByAppendingString:auto_hex([value localeIdentifier] ?: @"")];
    if ([value isKindOfClass:NSTimeZone.class]) return [NSString stringWithFormat:@"timezone:%@:%ld", auto_hex([value name]), (long)[value secondsFromGMTForDate:[NSDate dateWithTimeIntervalSinceReferenceDate:700000000]]];
    if ([value isKindOfClass:NSThread.class]) return [NSString stringWithFormat:@"thread:%@", auto_hex([value name] ?: @"")];
    if ([value isKindOfClass:NSPointerFunctions.class]) return [NSString stringWithFormat:@"pointer-functions:%lu", (unsigned long)[(NSPointerFunctions *)value options]];
    if ([value isKindOfClass:NSCalendar.class]) {
        NSCalendar *calendar = value; NSTimeZone *zone = calendar.timeZone;
        return [NSString stringWithFormat:@"calendar:%@:%@:%lu", auto_hex([calendar calendarIdentifier]), auto_hex([zone name]), (unsigned long)calendar.firstWeekday];
    }
    if ([value isKindOfClass:NSError.class]) return [NSString stringWithFormat:@"error:%@:%ld", auto_hex([value domain]), (long)[value code]];
    if ([value isKindOfClass:NSNotificationCenter.class]) return @"notification-center";
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *parts = [NSMutableArray array]; for (id object in value) [parts addObject:auto_canonical(object)];
        return [NSString stringWithFormat:@"array:[%@]", [parts componentsJoinedByString:@","]];
    }
    if ([value isKindOfClass:NSEnumerator.class]) {
        NSMutableArray *parts = [NSMutableArray array]; id object;
        while ((object = [value nextObject])) [parts addObject:auto_canonical(object)];
        return [NSString stringWithFormat:@"enumerator:[%@]", [parts componentsJoinedByString:@","]];
    }
    if ([value isKindOfClass:NSOrderedSet.class]) {
        NSMutableArray *parts = [NSMutableArray array]; for (id object in value) [parts addObject:auto_canonical(object)];
        return [NSString stringWithFormat:@"ordered-set:[%@]", [parts componentsJoinedByString:@","]];
    }
    if ([value isKindOfClass:NSSet.class]) {
        NSMutableArray *parts = [NSMutableArray array]; for (id object in value) [parts addObject:auto_canonical(object)];
        [parts sortUsingSelector:@selector(compare:)];
        return [NSString stringWithFormat:@"set:{%@}", [parts componentsJoinedByString:@","]];
    }
    if ([value isKindOfClass:NSHashTable.class]) {
        NSHashTable *table = (NSHashTable *)value;
        NSMutableArray *parts = [NSMutableArray array]; for (id object in table.allObjects) [parts addObject:auto_canonical(object)];
        [parts sortUsingSelector:@selector(compare:)];
        return [NSString stringWithFormat:@"hash-table:{%@}", [parts componentsJoinedByString:@","]];
    }
    if ([value isKindOfClass:NSMapTable.class]) return auto_canonical([(NSMapTable *)value dictionaryRepresentation]);
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableArray *parts = [NSMutableArray array];
        for (id key in value) [parts addObject:[NSString stringWithFormat:@"%@=%@", auto_canonical(key), auto_canonical(value[key])]];
        [parts sortUsingSelector:@selector(compare:)];
        return [NSString stringWithFormat:@"dictionary:{%@}", [parts componentsJoinedByString:@","]];
    }
    if ([value isKindOfClass:NSAttributedString.class]) {
        id attributes = [value length] ? [value attributesAtIndex:0 effectiveRange:NULL] : @{};
        return [NSString stringWithFormat:@"attributed:%@:%@", auto_canonical([value string]), auto_canonical(attributes)];
    }
    if ([value isKindOfClass:NSValue.class]) {
        const char *type = [value objCType];
        if (!strcmp(type, @encode(NSRange))) { NSRange range = [value rangeValue]; return [NSString stringWithFormat:@"range:%lu,%lu", (unsigned long)range.location, (unsigned long)range.length]; }
        if (!strcmp(type, @encode(NSPoint))) { NSPoint point = [value pointValue]; return [NSString stringWithFormat:@"point:%a,%a", point.x, point.y]; }
        if (!strcmp(type, @encode(NSSize))) { NSSize size = [value sizeValue]; return [NSString stringWithFormat:@"size:%a,%a", size.width, size.height]; }
        if (!strcmp(type, @encode(NSRect))) { NSRect rect = [value rectValue]; return [NSString stringWithFormat:@"rect:%a,%a,%a,%a", rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]; }
        return [NSString stringWithFormat:@"value:%s:%@", type, auto_hex([value description])];
    }
    if ([value isKindOfClass:NSCharacterSet.class]) {
        static const UTF32Char chars[] = {'a', 'A', 0x00e9, 0x4e2d, 0x1f642, 0x05d0};
        NSMutableString *bits = [NSMutableString stringWithString:@"charset:"];
        for (size_t i = 0; i < sizeof(chars) / sizeof(chars[0]); i++) [bits appendFormat:@"%d", [value longCharacterIsMember:chars[i]]];
        return bits;
    }
    NSString *description = [value description] ?: @"";
    description = [description stringByReplacingOccurrencesOfString:@"0x[0-9a-fA-F]+" withString:@"<ADDRESS>"
        options:NSRegularExpressionSearch range:NSMakeRange(0, description.length)];
    return [NSString stringWithFormat:@"%@:%@", NSStringFromClass([value class]), auto_hex(description)];
}

static void auto_print(NSString *value)
{
    const unsigned char *bytes = [value UTF8String];
    if (!bytes) { fputs("null", stdout); return; }
    while (*bytes) printf("%02x", *bytes++);
}

static id auto_object(NSString *type, NSUInteger index)
{
    NSString *clean = auto_clean_type(type);
    NSString *base = [[clean componentsSeparatedByString:@"<"] firstObject];
    base = [[base componentsSeparatedByString:@"*"] firstObject];
    base = [base stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([base isEqualToString:@"id"] || [base isEqualToString:@"NSObject"]) {
        NSArray *any = @[@"", @"Finch", @1, @-1, @[@"a", @2], @{ @"key": @"value" }, [NSData dataWithBytes:"\0\1\xff" length:3], [NSDate dateWithTimeIntervalSinceReferenceDate:700000000]];
        return any[index % any.count];
    }
    if ([base isEqualToString:@"NSString"] || [base isEqualToString:@"NSMutableString"]) {
        NSString *value = @[@"", @"Finch", @"cafe\u0301 👩🏽‍💻 עברית", @"العربية", [@"x" stringByPaddingToLength:65536 withString:@"x" startingAtIndex:0]][index % 5];
        return [base isEqualToString:@"NSMutableString"] ? [value mutableCopy] : value;
    }
    if ([base isEqualToString:@"NSNumber"]) return @[@0, @1, @-1, @(LLONG_MAX), @(LLONG_MIN), @0.5, @(NAN), @(INFINITY)][index % 8];
    if ([base isEqualToString:@"NSDecimalNumber"]) return @[[NSDecimalNumber zero], [NSDecimalNumber one], [NSDecimalNumber decimalNumberWithString:@"-1.25" locale:@{NSLocaleIdentifier:@"en_US_POSIX"}], [NSDecimalNumber decimalNumberWithString:@"999999.125" locale:@{NSLocaleIdentifier:@"en_US_POSIX"}]][index % 4];
    if ([base isEqualToString:@"NSDate"]) return @[[NSDate dateWithTimeIntervalSinceReferenceDate:0], [NSDate dateWithTimeIntervalSinceReferenceDate:-1], [NSDate dateWithTimeIntervalSinceReferenceDate:700000000], [NSDate dateWithTimeIntervalSinceReferenceDate:800000000]][index % 4];
    if ([base isEqualToString:@"NSCalendarDate"]) return [NSCalendarDate dateWithTimeIntervalSinceReferenceDate:700000000];
    if ([base isEqualToString:@"NSData"] || [base isEqualToString:@"NSMutableData"]) {
        NSData *value = @[[NSData data], [NSData dataWithBytes:"\0\1\x7f\x80\xfe\xff" length:6], [@"café🙂" dataUsingEncoding:NSUTF8StringEncoding]][index % 3];
        return [base isEqualToString:@"NSMutableData"] ? [value mutableCopy] : value;
    }
    if ([base isEqualToString:@"NSArray"] || [base isEqualToString:@"NSMutableArray"] || [base isEqualToString:@"NSOrderedSet"] || [base isEqualToString:@"NSMutableOrderedSet"]) {
        NSArray *values = @[@[], @[@"a", @1], @[@"cafe\u0301", @"🙂", @-1]][index % 3];
        if ([base isEqualToString:@"NSOrderedSet"]) return [NSOrderedSet orderedSetWithArray:values];
        if ([base isEqualToString:@"NSMutableOrderedSet"]) return [NSMutableOrderedSet orderedSetWithArray:values];
        return [base isEqualToString:@"NSMutableArray"] ? [values mutableCopy] : values;
    }
    if ([base isEqualToString:@"NSDictionary"] || [base isEqualToString:@"NSMutableDictionary"]) {
        NSDictionary *value = @[@{}, @{ @"a": @1, @"é": @"e\u0301" }, @{ @"z": @2, @"a": @1 }][index % 3];
        return [base isEqualToString:@"NSMutableDictionary"] ? [value mutableCopy] : value;
    }
    if ([base isEqualToString:@"NSSet"] || [base isEqualToString:@"NSMutableSet"] || [base isEqualToString:@"NSCountedSet"]) {
        NSSet *value = @[[NSSet set], [NSSet setWithArray:@[@"a", @"a", @1]], [NSSet setWithArray:@[@"🙂", @"é", @-1]]][index % 3];
        if ([base isEqualToString:@"NSMutableSet"]) return [value mutableCopy];
        if ([base isEqualToString:@"NSCountedSet"]) return [NSCountedSet setWithArray:value.allObjects];
        return value;
    }
    if ([base isEqualToString:@"NSURL"]) return @[[NSURL URLWithString:@"https://example.invalid/a%20b?q=1#part"], [NSURL URLWithString:@"mailto:finch@example.invalid"], [NSURL URLWithString:@"relative/path"]][index % 3];
    if ([base isEqualToString:@"NSURLComponents"]) return @[[NSURLComponents componentsWithString:@"https://example.invalid/a%20b?q=1#part"], [NSURLComponents componentsWithString:@"mailto:finch@example.invalid"], [NSURLComponents componentsWithString:@"relative/path"]][index % 3];
    if ([base isEqualToString:@"NSLocale"]) return @[[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"], [[NSLocale alloc] initWithLocaleIdentifier:@"fr_CA"], [[NSLocale alloc] initWithLocaleIdentifier:@"ar_EG"]][index % 3];
    if ([base isEqualToString:@"NSTimeZone"]) return @[[NSTimeZone timeZoneWithName:@"UTC"], [NSTimeZone timeZoneWithName:@"America/Toronto"], [NSTimeZone timeZoneWithName:@"Asia/Kathmandu"]][index % 3];
    if ([base isEqualToString:@"NSCalendar"]) {
        NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:index & 1 ? NSCalendarIdentifierISO8601 : NSCalendarIdentifierGregorian];
        calendar.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        calendar.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
        return calendar;
    }
    if ([base isEqualToString:@"NSDateComponents"]) {
        NSDateComponents *components = [[[NSDateComponents alloc] init] autorelease];
        components.year = 2001; components.month = 1; components.day = 2;
        components.hour = 3; components.minute = 4; components.second = 5;
        components.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
        return components;
    }
    if ([base isEqualToString:@"NSCharacterSet"]) return @[[NSCharacterSet characterSetWithCharactersInString:@"aé中🙂"], [NSCharacterSet alphanumericCharacterSet], [NSCharacterSet whitespaceAndNewlineCharacterSet]][index % 3];
    if ([base isEqualToString:@"NSAttributedString"]) return [[NSAttributedString alloc] initWithString:@"cafe\u0301 🙂" attributes:@{@"FinchTest":@"value"}];
    if ([base isEqualToString:@"NSMutableAttributedString"]) return [[NSMutableAttributedString alloc] initWithString:@"cafe\u0301 🙂" attributes:@{@"FinchTest":@"value"}];
    if ([base isEqualToString:@"NSError"]) return [NSError errorWithDomain:@"org.finch.difftest" code:(NSInteger)index userInfo:nil];
    if ([base isEqualToString:@"NSUUID"]) return [[NSUUID alloc] initWithUUIDString:@"68753a44-4d6f-1226-9c60-0050e4c00067"];
    if ([base isEqualToString:@"NSNull"]) return NSNull.null;
    if ([base isEqualToString:@"NSRange"]) return [NSValue valueWithRange:NSMakeRange(0, 0)];
    if ([base isEqualToString:@"NSValue"]) return [NSValue valueWithRange:NSMakeRange(0, 1)];
    if ([base isEqualToString:@"NSPredicate"]) return [NSPredicate predicateWithValue:YES];
    if ([base isEqualToString:@"NSExpression"]) return [NSExpression expressionForConstantValue:@1];
    if ([base isEqualToString:@"NSInvocation"]) {
        NSMethodSignature *signature = [NSObject instanceMethodSignatureForSelector:@selector(description)];
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = @"Finch"; invocation.selector = @selector(description); return invocation;
    }
    if ([base isEqualToString:@"NSSortDescriptor"]) return [NSSortDescriptor sortDescriptorWithKey:nil ascending:YES];
    if ([base isEqualToString:@"NSRegularExpression"]) return [NSRegularExpression regularExpressionWithPattern:@"a+" options:0 error:NULL];
    if ([base isEqualToString:@"NSException"]) return [NSException exceptionWithName:@"FinchTest" reason:@"fixed" userInfo:nil];
    if ([base isEqualToString:@"NSNotification"]) return [NSNotification notificationWithName:@"FinchTest" object:nil];
    if ([base isEqualToString:@"NSNotificationCenter"]) return [NSNotificationCenter defaultCenter];
    if ([base isEqualToString:@"NSMapTable"]) return [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsStrongMemory valueOptions:NSPointerFunctionsStrongMemory capacity:0];
    if ([base isEqualToString:@"NSHashTable"]) return [[NSHashTable alloc] initWithOptions:NSPointerFunctionsStrongMemory capacity:0];
    if ([base isEqualToString:@"NSCache"]) return [[NSCache alloc] init];
    if ([base isEqualToString:@"NSXMLDocument"]) return [[NSXMLDocument alloc] initWithXMLString:@"<root><item>value</item></root>" options:0 error:NULL];
    if ([base isEqualToString:@"NSXMLElement"]) return [NSXMLElement elementWithName:@"root"];
    if ([base isEqualToString:@"NSXMLNode"]) return [NSXMLNode elementWithName:@"node"];
    if ([base isEqualToString:@"NSNotificationName"] || [base hasSuffix:@"Key"] || [base hasSuffix:@"Name"])
        return @[@"", @"FinchTest", @"cafe\u0301"][index % 3];
    if ([base hasSuffix:@"Identifier"] || [base hasSuffix:@"Domain"] || [base hasSuffix:@"Type"])
        return @[@"en_US_POSIX", @"fr_CA", @"ar_EG"][index % 3];
    if ([base hasPrefix:@"CF"] && [base hasSuffix:@"Ref"]) {
        NSString *bridge = [base stringByReplacingOccurrencesOfString:@"CF" withString:@"NS" options:0 range:NSMakeRange(0, 2)];
        bridge = [bridge stringByReplacingOccurrencesOfString:@"Ref" withString:@""];
        return auto_object([bridge stringByAppendingString:@" *"], index);
    }
    Class cls = NSClassFromString(base);
    if (cls) { @try { return [[cls alloc] init]; } @catch (__unused NSException *exception) { return nil; } }
    return nil;
}

static BOOL auto_type_is_mutable(NSString *type)
{
    return [type containsString:@"NSMutable"] || [type containsString:@"CFMutable"] ||
        [@[@"NSCountedSet", @"NSMapTable", @"NSHashTable", @"NSCache", @"NSCalendar",
           @"NSDateFormatter", @"NSNumberFormatter"] containsObject:type];
}

static id auto_method_object(NSString *type, NSString *parameterName, NSString *className,
    NSString *selectorName, NSUInteger index)
{
    NSString *base = [[auto_clean_type(type) componentsSeparatedByString:@"*"] firstObject];
    base = [base stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *name = [parameterName lowercaseString] ?: @"";
    if ([className isEqualToString:@"NSDate"] && [selectorName containsString:@"NaturalLanguage"] &&
        [name containsString:@"locale"])
        return @{NSLocaleIdentifier:@"en_US_POSIX"};
    if ([className isEqualToString:@"NSDecimalNumber"] && [name containsString:@"behavior"])
        return [NSDecimalNumberHandler decimalNumberHandlerWithRoundingMode:NSRoundPlain scale:2
            raiseOnExactness:NO raiseOnOverflow:NO raiseOnUnderflow:NO raiseOnDivideByZero:NO];
    if ([className isEqualToString:@"NSDateInterval"] && [base isEqualToString:@"NSDate"])
        return [NSDate dateWithTimeIntervalSinceReferenceDate:[name containsString:@"end"] ? 800000000 : 700000000];
    if ([className isEqualToString:@"NSDateComponentsFormatter"] && [base isEqualToString:@"NSDateComponents"]) {
        NSDateComponents *components = [[[NSDateComponents alloc] init] autorelease];
        components.hour = 1; components.minute = 2; components.second = 3;
        return components;
    }
    if ([className isEqualToString:@"NSMutableDictionary"] &&
        [selectorName isEqualToString:@"dictionaryWithSharedKeySet:"])
        return [NSMutableDictionary sharedKeySetForKeys:@[@"a", @"b"]];
    if ([className isEqualToString:@"NSExpression"] && [name containsString:@"format"])
        return @"SELF == 1";
    if ([className isEqualToString:@"NSMethodSignature"] &&
        ([name containsString:@"types"] || [name containsString:@"encoding"]))
        return @"v@:";
    if ([className isEqualToString:@"NSCalendar"] && [type containsString:@"NSCalendarIdentifier"])
        return @[NSCalendarIdentifierGregorian, NSCalendarIdentifierISO8601][index % 2];
    if ([base isEqualToString:@"NSString"] || [base isEqualToString:@"NSMutableString"]) {
        if ([className isEqualToString:@"NSLocale"]) {
            if ([selectorName containsString:@"DirectionForLanguage"])
                return @[@"en", @"ar", @"he"][index % 3];
            if ([selectorName containsString:@"canonicalLanguageIdentifier"])
                return @[@"en", @"ar-EG", @"he-IL"][index % 3];
            if ([selectorName containsString:@"Identifier"] || [name containsString:@"language"] ||
                [name containsString:@"locale"] || [name containsString:@"identifier"])
                return @[@"en_US_POSIX", @"ar_EG", @"he_IL"][index % 3];
            if ([name isEqualToString:@"key"]) return NSLocaleIdentifier;
        }
        if ([className isEqualToString:@"NSCalendar"] && [name containsString:@"identifier"])
            return @[NSCalendarIdentifierGregorian, NSCalendarIdentifierISO8601][index % 2];
        if ([className isEqualToString:@"NSTimeZone"] &&
            ([selectorName containsString:@"WithName"] || [name containsString:@"name"]))
            return @[@"UTC", @"America/Toronto", @"Asia/Kathmandu"][index % 3];
        if ([className isEqualToString:@"NSURL"] && [name containsString:@"path"])
            return @[@"/tmp/finch-difftest", @"/tmp/finch-difftest/file.txt"][index % 2];
        if ([className isEqualToString:@"NSURLComponents"] && [name containsString:@"percentencoded"]) {
            if ([name containsString:@"host"]) return @"example.test";
            if ([name containsString:@"user"]) return @"finch";
            if ([name containsString:@"password"]) return @"secret";
            if ([name containsString:@"path"]) return @"/a%20b";
            if ([name containsString:@"query"]) return @"q=1";
            if ([name containsString:@"fragment"]) return @"part";
        }
        if ([className isEqualToString:@"NSDecimalNumber"] &&
            ([selectorName containsString:@"WithString"] || [name containsString:@"string"] || [name containsString:@"numbervalue"]))
            return @[@"0", @"-1.25", @"42.5", @"999999.125"][index % 4];
        if ([className isEqualToString:@"NSCalendarDate"] && [name containsString:@"locale"])
            return @{NSLocaleIdentifier:@"en_US_POSIX"};
        if ([className isEqualToString:@"NSCalendarDate"]) {
            if ([name containsString:@"format"]) return @"%Y-%m-%d %H:%M:%S";
            if ([selectorName containsString:@"String"] &&
                ([name containsString:@"description"] || [name containsString:@"string"]))
                return @"2001-01-02 03:04:05";
        }
        if ([className isEqualToString:@"NSXMLDocument"] && [name containsString:@"string"])
            return @"<root><item>value</item></root>";
        if ([className isEqualToString:@"NSXMLDocument"] && [name containsString:@"stylesheet"])
            return @"<?xml version=\"1.0\"?><xsl:stylesheet version=\"1.0\" xmlns:xsl=\"http://www.w3.org/1999/XSL/Transform\"><xsl:template match=\"/\"><result/></xsl:template></xsl:stylesheet>";
        if ([className isEqualToString:@"NSDateFormatter"]) {
            if ([name containsString:@"format"]) return @"yyyy-MM-dd HH:mm:ss";
            if ([name containsString:@"string"]) return @"2001-01-02 03:04:05";
        }
        if ([className isEqualToString:@"NSExpression"] && [name containsString:@"function"])
            return @"sum:";
    }
    if ([base isEqualToString:@"NSArray"] && [className isEqualToString:@"NSExpression"] &&
        [name containsString:@"argument"])
        return @[[NSExpression expressionForConstantValue:@1], [NSExpression expressionForConstantValue:@2]];
    if ([base isEqualToString:@"NSData"] && [className isEqualToString:@"NSJSONSerialization"] &&
        [name containsString:@"data"]) {
        NSArray *json = @[@"{\"key\":1}", @"[1,2]", @"null"];
        return [json[index % json.count] dataUsingEncoding:NSUTF8StringEncoding];
    }
    if ([base isEqualToString:@"NSData"] && [className isEqualToString:@"NSXMLDocument"] &&
        [name containsString:@"data"])
        return [@"<root><item>value</item></root>" dataUsingEncoding:NSUTF8StringEncoding];
    if ([base isEqualToString:@"id"] && [className isEqualToString:@"NSDecimalNumber"] && [name containsString:@"locale"])
        return @{NSLocaleIdentifier:@"en_US_POSIX", NSLocaleDecimalSeparator:@"."};
    if ([base isEqualToString:@"id"] && [className isEqualToString:@"NSCalendarDate"] && [name containsString:@"locale"])
        return @{NSLocaleIdentifier:@"en_US_POSIX"};
    if ([base isEqualToString:@"id"] && [selectorName containsString:@"descriptionWithLocale"] && [name containsString:@"locale"])
        return nil;
    return auto_object(type, index);
}

static id auto_receiver(NSString *className, NSString *selectorName)
{
    Class cls = NSClassFromString(className);
    if (!cls) return nil;
    if ([selectorName hasPrefix:@"init"]) return [cls alloc];
    if ([className isEqualToString:@"NSObject"]) return [[NSObject alloc] init];
    if ([className isEqualToString:@"NSString"]) return @"Finch";
    if ([className isEqualToString:@"NSMutableString"]) return [NSMutableString stringWithString:@"Finch"];
    if ([className isEqualToString:@"NSNumber"]) return @1;
    if ([className isEqualToString:@"NSDecimalNumber"]) return [NSDecimalNumber decimalNumberWithString:@"1.25"];
    if ([className isEqualToString:@"NSDate"]) return [NSDate dateWithTimeIntervalSinceReferenceDate:700000000];
    if ([className isEqualToString:@"NSData"]) return [NSData dataWithBytes:"\0\1\xff" length:3];
    if ([className isEqualToString:@"NSMutableData"]) return [NSMutableData dataWithBytes:"\0\1\xff" length:3];
    if ([className isEqualToString:@"NSArray"]) return @[@"a", @1];
    if ([className isEqualToString:@"NSMutableArray"]) return [NSMutableArray arrayWithArray:@[@"a", @1]];
    if ([className isEqualToString:@"NSDictionary"]) return @{@"a":@1};
    if ([className isEqualToString:@"NSMutableDictionary"]) return [NSMutableDictionary dictionaryWithDictionary:@{@"a":@1}];
    if ([className isEqualToString:@"NSSet"]) return [NSSet setWithArray:@[@"a", @1]];
    if ([className isEqualToString:@"NSMutableSet"]) return [NSMutableSet setWithArray:@[@"a", @1]];
    if ([className isEqualToString:@"NSCountedSet"]) return [NSCountedSet setWithArray:@[@"a", @"a", @1]];
    if ([className isEqualToString:@"NSOrderedSet"]) return [NSOrderedSet orderedSetWithArray:@[@"a", @1]];
    if ([className isEqualToString:@"NSMutableOrderedSet"]) return [NSMutableOrderedSet orderedSetWithArray:@[@"a", @1]];
    if ([className isEqualToString:@"NSCalendar"]) {
        NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        calendar.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        calendar.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
        return calendar;
    }
    if ([className isEqualToString:@"NSURL"]) return [NSURL URLWithString:@"https://example.invalid/a%20b?q=1#part"];
    if ([className isEqualToString:@"NSURLComponents"]) return [NSURLComponents componentsWithString:@"https://example.invalid/a%20b?q=1#part"];
    if ([className isEqualToString:@"NSLocale"]) return [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    if ([className isEqualToString:@"NSTimeZone"]) return [NSTimeZone timeZoneWithName:@"UTC"];
    if ([className isEqualToString:@"NSCalendar"]) {
        NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        calendar.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        calendar.timeZone = [NSTimeZone timeZoneWithName:@"UTC"]; return calendar;
    }
    if ([className isEqualToString:@"NSCalendarDate"]) {
        NSCalendarDate *date = [NSCalendarDate dateWithTimeIntervalSinceReferenceDate:700000000];
        [date setTimeZone:[NSTimeZone timeZoneWithName:@"UTC"]]; return date;
    }
    if ([className isEqualToString:@"NSDateInterval"])
        return [[[NSDateInterval alloc] initWithStartDate:[NSDate dateWithTimeIntervalSinceReferenceDate:700000000] duration:3600] autorelease];
    if ([className isEqualToString:@"NSDateFormatter"]) {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
        formatter.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss"; return formatter;
    }
    if ([className isEqualToString:@"NSNumberFormatter"]) {
        NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
        formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.numberStyle = NSNumberFormatterDecimalStyle; return formatter;
    }
    if ([className isEqualToString:@"NSCharacterSet"]) return [NSCharacterSet characterSetWithCharactersInString:@"aé中🙂"];
    if ([className isEqualToString:@"NSAttributedString"]) return [[NSAttributedString alloc] initWithString:@"Finch" attributes:nil];
    if ([className isEqualToString:@"NSMutableAttributedString"]) return [[NSMutableAttributedString alloc] initWithString:@"Finch" attributes:nil];
    if ([className isEqualToString:@"NSPredicate"]) return [NSPredicate predicateWithValue:YES];
    if ([className isEqualToString:@"NSNotificationCenter"]) return [NSNotificationCenter defaultCenter];
    if ([className isEqualToString:@"NSMapTable"]) return [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsStrongMemory valueOptions:NSPointerFunctionsStrongMemory capacity:0];
    if ([className isEqualToString:@"NSHashTable"]) return [[NSHashTable alloc] initWithOptions:NSPointerFunctionsStrongMemory capacity:0];
    if ([className isEqualToString:@"NSCache"]) return [[NSCache alloc] init];
    if ([className isEqualToString:@"NSXMLDocument"]) {
        if ([selectorName isEqualToString:@"addChild:"] || [selectorName isEqualToString:@"insertChild:atIndex:"])
            return [[[NSXMLDocument alloc] init] autorelease];
        return [[NSXMLDocument alloc] initWithXMLString:@"<root><item>value</item></root>" options:0 error:NULL];
    }
    if ([className isEqualToString:@"NSXMLElement"]) return [NSXMLElement elementWithName:@"root"];
    if ([className isEqualToString:@"NSRegularExpression"]) return [NSRegularExpression regularExpressionWithPattern:@"a+" options:0 error:NULL];
    if ([className isEqualToString:@"NSUUID"]) return [[NSUUID alloc] initWithUUIDString:@"68753a44-4d6f-1226-9c60-0050e4c00067"];
    return nil;
}

static NSArray *auto_enum_values(NSDictionary *parameter)
{
    NSArray *values = parameter[@"enum_values"];
    return [values isKindOfClass:NSArray.class] ? values : @[];
}

static void auto_store_scalar(void *destination, const char *encoding, NSString *type, NSUInteger index,
    NSDictionary *parameter, NSString *className, NSString *selectorName, NSUInteger storageSize)
{
    NSString *clean = auto_clean_type(type);
    NSString *name = [parameter[@"name"] lowercaseString] ?: @"";
    NSArray *enumValues = auto_enum_values(parameter);
    if ([clean containsString:@"NSRange"]) {
        NSRange range = [className isEqualToString:@"NSOrderedSet"] && [selectorName isEqualToString:@"getObjects:range:"] ?
            NSMakeRange(0, 2) : NSMakeRange(0, index % 2);
        memcpy(destination, &range, sizeof(range)); return;
    }
    if ([clean containsString:@"CFRange"]) {
        CFRange range = CFRangeMake(0, (CFIndex)(index % 2));
        memcpy(destination, &range, sizeof(range)); return;
    }
    if ([clean containsString:@"Point"] || [clean containsString:@"Size"] || [clean containsString:@"Rect"] || [clean containsString:@"Transform"]) {
        memset(destination, 0, storageSize); return;
    }
    if ([className isEqualToString:@"NSDateInterval"] && [name containsString:@"duration"]) {
        static const double values[] = {0.0, 1.0, 60.0, 3600.0};
        double value = values[index % 4];
        if (encoding[0] == 'f') { float v = (float)value; memcpy(destination, &v, sizeof(v)); }
        else memcpy(destination, &value, sizeof(value));
        return;
    }
    if (encoding[0] == 'f' || encoding[0] == 'd') {
        static const double values[] = {0.0, -0.0, INFINITY, -INFINITY, NAN, 0x1p-1074, 0.5};
        static const double timeValues[] = {0.0, -1.0, 700000000.0, 800000000.0, 1000000000.0, 123456789.0, 31536000.0, 86400.0};
        BOOL timeType = [clean containsString:@"AbsoluteTime"] || [clean containsString:@"TimeInterval"];
        double number = timeType ? timeValues[index % 8] : values[index % 7];
        if (encoding[0] == 'f') { float v = (float)number; memcpy(destination, &v, sizeof(v)); }
        else memcpy(destination, &number, sizeof(number));
        return;
    }
    if ([className isEqualToString:@"NSString"] &&
        [selectorName isEqualToString:@"initWithCharactersNoCopy:length:freeWhenDone:"] &&
        [name isEqualToString:@"freebuffer"]) {
        unsigned char value = 0; memcpy(destination, &value, MIN(storageSize, sizeof(value))); return;
    }
    if (encoding[0] == 'B' || [clean isEqualToString:@"BOOL"] || [clean isEqualToString:@"Boolean"] || [clean isEqualToString:@"bool"]) {
        unsigned char v = (unsigned char)(index & 1); memcpy(destination, &v, sizeof(v)); return;
    }
    if ([className isEqualToString:@"NSCalendar"] && [name isEqualToString:@"firstweekday"]) {
        long long values[] = {1, 2, 7}; NSUInteger size = 0; NSGetSizeAndAlignment(encoding, &size, NULL);
        memset(destination, 0, size); memcpy(destination, &values[index % 3], MIN(size, sizeof(long long))); return;
    }
    if ([className isEqualToString:@"NSCalendar"] &&
        [selectorName containsString:@"dateBySettingHour"] && [name isEqualToString:@"opts"]) {
        long long value = 0; NSUInteger size = 0; NSGetSizeAndAlignment(encoding, &size, NULL);
        memset(destination, 0, size); memcpy(destination, &value, MIN(size, sizeof(value))); return;
    }
    if ([className isEqualToString:@"NSXMLDocument"] && [name containsString:@"index"] &&
        ([selectorName containsString:@"ChildAtIndex"] || [selectorName containsString:@"insertChild"])) {
        long long value = 0; NSUInteger size = 0; NSGetSizeAndAlignment(encoding, &size, NULL);
        memset(destination, 0, size); memcpy(destination, &value, MIN(size, sizeof(value))); return;
    }
    if ([selectorName containsString:@"descriptionWithLocale"] && [name isEqualToString:@"level"]) {
        long long values[] = {0, 1, 2}; NSUInteger size = 0; NSGetSizeAndAlignment(encoding, &size, NULL);
        memset(destination, 0, size); memcpy(destination, &values[index % 3], MIN(size, sizeof(long long))); return;
    }
    if ([className isEqualToString:@"NSCalendarDate"] &&
        ([name containsString:@"year"] || [name containsString:@"month"] || [name containsString:@"day"] ||
         [name containsString:@"hour"] || [name containsString:@"minute"] || [name containsString:@"second"])) {
        long long value = [name containsString:@"year"] ? 2001 : [name containsString:@"month"] ? 1 :
            [name containsString:@"day"] ? 2 : [name containsString:@"hour"] ? 3 :
            [name containsString:@"minute"] ? 4 : 5;
        NSUInteger size = 0; NSGetSizeAndAlignment(encoding, &size, NULL);
        memset(destination, 0, size); memcpy(destination, &value, MIN(size, sizeof(value))); return;
    }
    if ([className isEqualToString:@"NSCalendar"] && [name hasSuffix:@"value"]) {
        long long values[] = {1, 2001, 1, 2, 12, 34, 56, 0};
        NSUInteger position = [name containsString:@"era"] ? 0 : [name containsString:@"year"] ? 1 :
            [name containsString:@"month"] ? 2 : [name containsString:@"day"] ? 3 :
            [name containsString:@"hour"] ? 4 : [name containsString:@"minute"] ? 5 :
            [name containsString:@"second"] ? 6 : 7;
        long long value = values[position]; NSUInteger size = 0; NSGetSizeAndAlignment(encoding, &size, NULL);
        memset(destination, 0, size); memcpy(destination, &value, MIN(size, sizeof(value))); return;
    }
    if ([className isEqualToString:@"NSCalendar"] &&
        [selectorName containsString:@"dateBySettingHour"] &&
        ([name isEqualToString:@"h"] || [name isEqualToString:@"m"] || [name isEqualToString:@"s"] ||
         [name isEqualToString:@"hour"] || [name isEqualToString:@"minute"] || [name isEqualToString:@"second"])) {
        BOOL isHour = [name isEqualToString:@"h"] || [name isEqualToString:@"hour"];
        BOOL isMinute = [name isEqualToString:@"m"] || [name isEqualToString:@"minute"];
        long long values[] = {0, 1, isHour ? 12 : isMinute ? 34 : 56};
        long long value = values[index % 3]; NSUInteger size = 0; NSGetSizeAndAlignment(encoding, &size, NULL);
        memset(destination, 0, size); memcpy(destination, &value, MIN(size, sizeof(value))); return;
    }
    if ([name hasPrefix:@"idx"] || [name containsString:@"index"] || [name containsString:@"location"] ||
        [name containsString:@"offset"] || [name containsString:@"position"] || [name containsString:@"start"] ||
        [name containsString:@"end"] || [name isEqualToString:@"loc"]) {
        long long values[] = {0, 1}; NSUInteger size = 0; NSGetSizeAndAlignment(encoding, &size, NULL);
        memset(destination, 0, size); memcpy(destination, &values[index % 2], MIN(size, sizeof(long long))); return;
    }
    if ([name containsString:@"length"] || [name containsString:@"count"] || [name isEqualToString:@"cnt"] || [name isEqualToString:@"len"] || [name containsString:@"capacity"] ||
        [name containsString:@"num"] ||
        [name containsString:@"size"] || [name containsString:@"limit"] || [name containsString:@"bufferlen"] ||
        [name containsString:@"indent"]) {
        long long values[] = {0, 1, 2}; NSUInteger size = 0; NSGetSizeAndAlignment(encoding, &size, NULL);
        memset(destination, 0, size); memcpy(destination, &values[index % 3], MIN(size, sizeof(long long))); return;
    }
    if ([name containsString:@"scale"]) {
        long long values[] = {-2, 0, 2}; NSUInteger size = 0; NSGetSizeAndAlignment(encoding, &size, NULL);
        memset(destination, 0, size); memcpy(destination, &values[index % 3], MIN(size, sizeof(long long))); return;
    }
    if ([name containsString:@"hour"] || [name containsString:@"minute"] || [name containsString:@"second"] ||
        [name containsString:@"month"] || [name containsString:@"day"] || [name containsString:@"year"] ||
        [name isEqualToString:@"value"]) {
        long long values[] = {0, 1, -1, 2}; NSUInteger size = 0; NSGetSizeAndAlignment(encoding, &size, NULL);
        memset(destination, 0, size); memcpy(destination, &values[index % 4], MIN(size, sizeof(long long))); return;
    }
    if ([clean containsString:@"Encoding"] || [name containsString:@"encoding"]) {
        unsigned long values[] = {NSUTF8StringEncoding, NSASCIIStringEncoding,
            NSISOLatin1StringEncoding, NSMacOSRomanStringEncoding};
        NSUInteger size = 0; NSGetSizeAndAlignment(encoding, &size, NULL); memset(destination, 0, size);
        memcpy(destination, &values[index % 4], MIN(size, sizeof(unsigned long))); return;
    }
    if ([name containsString:@"mantissa"]) {
        unsigned long long values[] = {0, 1, 125, 99999};
        NSUInteger size = 0; NSGetSizeAndAlignment(encoding, &size, NULL); memset(destination, 0, size);
        memcpy(destination, &values[index % 4], MIN(size, sizeof(unsigned long long))); return;
    }
    if ([clean isEqualToString:@"NSPointerFunctionsOptions"]) enumValues = @[@0];
    if (enumValues.count) {
        long long value = [enumValues[index % enumValues.count] longLongValue];
        NSUInteger size = 0; NSGetSizeAndAlignment(encoding, &size, NULL); memset(destination, 0, size);
        memcpy(destination, &value, MIN(size, sizeof(value))); return;
    }
    long long signedValues[] = {0, 1, -1, 2, LLONG_MAX, LLONG_MIN, -2};
    unsigned long long unsignedValues[] = {0, 1, 2, 255, 65535, UINT_MAX, ULLONG_MAX};
    NSUInteger size = 0; NSGetSizeAndAlignment(encoding, &size, NULL); memset(destination, 0, size);
    if (strchr("CISLQ", encoding[0])) {
        unsigned long long value = unsignedValues[index % 7]; memcpy(destination, &value, MIN(size, sizeof(value)));
    } else {
        long long value = signedValues[index % 7]; memcpy(destination, &value, MIN(size, sizeof(value)));
    }
}

static void auto_test_method(NSDictionary *item)
{
    NSString *className = item[@"class"];
    NSString *selectorName = item[@"selector"];
    SEL selector = NSSelectorFromString(selectorName);
    BOOL classMethod = [item[@"class_method"] boolValue];
    Class cls = NSClassFromString(className);
    id classOrReceiver = classMethod ? (id)cls : auto_receiver(className, selectorName);
    if (!classOrReceiver) { puts("0\tnot-exercised:no-safe-receiver"); return; }
    NSMethodSignature *signature = [classOrReceiver methodSignatureForSelector:selector];
    if (!signature) { puts("0\tno-method-signature"); return; }
    NSArray *parameters = item[@"parameters"];
    NSUInteger argumentCount = signature.numberOfArguments > 2 ? signature.numberOfArguments - 2 : 0;
    NSUInteger cases = argumentCount ? 8 : 1;
    for (NSUInteger caseIndex = 0; caseIndex < cases; caseIndex++) {
        @autoreleasepool {
            id receiver = classMethod ? (id)cls : auto_receiver(className, selectorName);
            if (!receiver) { printf("%lu\tnot-exercised:no-safe-receiver\n", (unsigned long)caseIndex); continue; }
            NSMethodSignature *sig = [receiver methodSignatureForSelector:selector];
            if (!sig) { printf("%lu\tno-method-signature\n", (unsigned long)caseIndex); continue; }
            NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
            invocation.target = receiver; invocation.selector = selector;
            NSMutableArray *outputPointers = [NSMutableArray array];
            NSMutableArray *argumentObjects = [NSMutableArray arrayWithCapacity:argumentCount];
            BOOL hasSafeInputs = YES;
            for (NSUInteger argIndex = 0; argIndex < argumentCount; argIndex++) {
                NSDictionary *parameter = argIndex < parameters.count ? parameters[argIndex] : @{};
                NSString *type = parameter[@"type"] ?: @"id";
                const char *encoding = [sig getArgumentTypeAtIndex:argIndex + 2];
                while (strchr("rnNoORV", encoding[0])) encoding++;
                if ([className isEqualToString:@"NSUUID"] &&
                    [selectorName isEqualToString:@"getUUIDBytes:"] &&
                    [parameter[@"name"] isEqualToString:@"uuid"]) {
                    void *storage = calloc(16, 1);
                    if (!storage) { hasSafeInputs = NO; void *value = NULL; [invocation setArgument:&value atIndex:argIndex + 2]; continue; }
                    void *value = storage; [argumentObjects addObject:NSNull.null];
                    [invocation setArgument:&value atIndex:argIndex + 2];
                    [outputPointers addObject:@{ @"type":type, @"storage":[NSValue valueWithPointer:storage], @"size":@16 }];
                    continue;
                }
                if ([className isEqualToString:@"NSUUID"] &&
                    [selectorName isEqualToString:@"initWithUUIDBytes:"] &&
                    [parameter[@"name"] isEqualToString:@"bytes"]) {
                    static const unsigned char uuidBytes[16] = {0x68, 0x75, 0x3a, 0x44, 0x4d, 0x6f, 0x12, 0x26, 0x9c, 0x60, 0x00, 0x50, 0xe4, 0xc0, 0x00, 0x67};
                    void *value = (void *)uuidBytes; [argumentObjects addObject:NSNull.null];
                    [invocation setArgument:&value atIndex:argIndex + 2]; continue;
                }
                if (encoding[0] == '@') {
                    id value = nil;
                    if (encoding[1] == '?' || [type containsString:@"(^"]) {
                        if ([parameter[@"name"] localizedCaseInsensitiveContainsString:@"comparator"] ||
                            [selectorName localizedCaseInsensitiveContainsString:@"comparator"]) {
                            NSComparator comparator = ^NSComparisonResult(id a, id b) { return [[a description] compare:[b description]]; };
                            value = [comparator copy];
                        } else hasSafeInputs = NO;
                    } else {
                        value = auto_method_object(type, parameter[@"name"] ?: @"", className,
                            selectorName, caseIndex + argIndex);
                        if ([parameter[@"nullable"] boolValue] && caseIndex == 7) value = nil;
                        if (!value && [parameter[@"nullable"] boolValue]) value = NSNull.null;
                    }
                    if (!value && ![parameter[@"nullable"] boolValue]) hasSafeInputs = NO;
                    [argumentObjects addObject:value ?: NSNull.null];
                    if (value == NSNull.null) value = nil;
                    [invocation setArgument:&value atIndex:argIndex + 2];
                    continue;
                }
                if (encoding[0] == '#') {
                    Class value = NSClassFromString([type containsString:@"*"] ? [type componentsSeparatedByString:@"*"][0] : @"NSObject");
                    if (!value) value = NSObject.class;
                    [argumentObjects addObject:value];
                    [invocation setArgument:&value atIndex:argIndex + 2]; continue;
                }
                if (encoding[0] == ':') {
                    SEL value = [className isEqualToString:@"NSComparisonPredicate"] &&
                        [selectorName containsString:@"customSelector"] ? @selector(compare:) : @selector(description);
                    [argumentObjects addObject:NSNull.null]; [invocation setArgument:&value atIndex:argIndex + 2]; continue;
                }
                if (encoding[0] == '^' || encoding[0] == '*') {
                    NSString *parameterName = parameter[@"name"] ?: @"";
                    NSString *direction = parameter[@"direction"] ?: @"unspecified";
                    BOOL outputName = [parameterName rangeOfString:@"(?:error|out|result|start|end|length|location|range|count|offset|used|remaining|destination|response|buffer|characters)" options:NSRegularExpressionSearch | NSCaseInsensitiveSearch].location != NSNotFound;
                    BOOL noCopyCharacters = [className isEqualToString:@"NSString"] &&
                        [selectorName isEqualToString:@"initWithCharactersNoCopy:length:freeWhenDone:"] &&
                        [parameterName.lowercaseString isEqualToString:@"characters"];
                    if (noCopyCharacters) outputName = NO;
                    if ([className isEqualToString:@"NSDateFormatter"] &&
                        [selectorName isEqualToString:@"getObjectValue:forString:range:error:"] &&
                        [parameterName.lowercaseString isEqualToString:@"obj"]) outputName = YES;
                    if ([className isEqualToString:@"NSOrderedSet"] &&
                        [selectorName isEqualToString:@"getObjects:range:"] &&
                        [parameterName.lowercaseString isEqualToString:@"objects"]) outputName = YES;
                    BOOL output = [direction isEqualToString:@"out"] || [direction isEqualToString:@"inout"] || outputName;
                    if (noCopyCharacters) output = NO;
                    BOOL uuidMethod = [className isEqualToString:@"NSUUID"];
                    if (noCopyCharacters) {
                        static const unichar characters[] = {'c', 'a', 'f', 0x00e9, 0x0301, 0xd83d, 0xde42};
                        NSMutableData *storage = [NSMutableData dataWithBytes:characters length:sizeof(characters)];
                        void *value = storage.mutableBytes; [argumentObjects addObject:storage];
                        [invocation setArgument:&value atIndex:argIndex + 2]; continue;
                    }
                    if ([className isEqualToString:@"NSOrderedSet"] &&
                        [selectorName isEqualToString:@"getObjects:range:"] &&
                        [parameterName.lowercaseString isEqualToString:@"objects"]) {
                        void *storage = calloc(2, sizeof(id));
                        if (!storage) { hasSafeInputs = NO; void *value = NULL; [invocation setArgument:&value atIndex:argIndex + 2]; continue; }
                        void *value = storage; [argumentObjects addObject:NSNull.null];
                        [invocation setArgument:&value atIndex:argIndex + 2];
                        [outputPointers addObject:@{@"type":type, @"storage":[NSValue valueWithPointer:storage], @"size":@(2 * sizeof(id)), @"kind":@"object-array"}];
                        continue;
                    }
                    if ([className isEqualToString:@"NSIndexPath"] &&
                        [selectorName isEqualToString:@"indexPathWithIndexes:length:"] &&
                        [parameterName.lowercaseString isEqualToString:@"indexes"]) {
                        NSMutableData *valueStorage = [NSMutableData dataWithLength:3 * sizeof(NSUInteger)];
                        NSUInteger *indexes = [valueStorage mutableBytes]; indexes[0] = 0; indexes[1] = 1; indexes[2] = 2;
                        void *value = indexes; [argumentObjects addObject:valueStorage];
                        [invocation setArgument:&value atIndex:argIndex + 2]; continue;
                    }
                    if ([type containsString:@"const"] &&
                        ([type containsString:@"ObjectType"] || [type containsString:@"KeyType"] ||
                         [type containsString:@"ValueType"] || [type containsString:@"id"]) &&
                        [type containsString:@"*"] && [type rangeOfString:@"char *"].location == NSNotFound) {
                        NSArray *backing = [parameterName.lowercaseString containsString:@"key"] ?
                            @[@"a", @"é", @"b"] : @[@"a", @1, @"b"];
                        NSMutableData *valueStorage = [NSMutableData dataWithLength:3 * sizeof(id)];
                        id *values = [valueStorage mutableBytes];
                        values[0] = backing[0]; values[1] = backing[1]; values[2] = backing[2];
                        void *value = values; [argumentObjects addObject:backing];
                        [argumentObjects addObject:valueStorage];
                        [invocation setArgument:&value atIndex:argIndex + 2]; continue;
                    }
                    BOOL unsignedBytePointer = [type containsString:@"unsigned char *"] || [type containsString:@"UInt8 *"] || [type containsString:@"uint8_t *"];
                    if (unsignedBytePointer && [type containsString:@"const"]) {
                        static const unsigned char bytes[16] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15};
                        void *value = (void *)bytes; [argumentObjects addObject:NSNull.null];
                        [invocation setArgument:&value atIndex:argIndex + 2]; continue;
                    }
                    if (unsignedBytePointer && output && [parameterName rangeOfString:@"buffer|bytes|characters|uuid" options:NSRegularExpressionSearch | NSCaseInsensitiveSearch].location != NSNotFound) {
                        NSUInteger byteCount = uuidMethod ? 16 : 4096;
                        void *storage = calloc(byteCount, 1);
                        if (!storage) { hasSafeInputs = NO; void *value = NULL; [invocation setArgument:&value atIndex:argIndex + 2]; continue; }
                        void *value = storage; [argumentObjects addObject:NSNull.null];
                        [invocation setArgument:&value atIndex:argIndex + 2];
                        [outputPointers addObject:@{@"type":type, @"storage":[NSValue valueWithPointer:storage], @"size":@(byteCount)}];
                        continue;
                    }
                    if ((encoding[0] == '*' || [type containsString:@"char *"]) &&
                        !unsignedBytePointer && [type containsString:@"const"]) {
                        NSString *string = auto_method_object(@"NSString *", parameter[@"name"] ?: @"",
                            className, selectorName, caseIndex + argIndex);
                        [argumentObjects addObject:string ?: NSNull.null];
                        const char *value = [string UTF8String]; [invocation setArgument:&value atIndex:argIndex + 2]; continue;
                    }
                    if ([type containsString:@"void *"] && !output &&
                        [parameterName rangeOfString:@"bytes|buffer|data" options:NSRegularExpressionSearch | NSCaseInsensitiveSearch].location != NSNotFound) {
                        static const unsigned char inputBytes[] = {0, 1, 127, 128, 254, 255, 42, 99, 0};
                        void *value = (void *)inputBytes;
                        if ([selectorName containsString:@"NoCopy"]) {
                            value = malloc(sizeof(inputBytes));
                            if (!value) { hasSafeInputs = NO; [argumentObjects addObject:NSNull.null]; continue; }
                            memcpy(value, inputBytes, sizeof(inputBytes));
                        }
                        [argumentObjects addObject:NSNull.null];
                        [invocation setArgument:&value atIndex:argIndex + 2]; continue;
                    }
                    if (encoding[0] == '*' || [type containsString:@"char *"]) {
                        if (output && [parameterName rangeOfString:@"buffer|bytes|characters" options:NSRegularExpressionSearch | NSCaseInsensitiveSearch].location != NSNotFound) {
                            char *storage = calloc(4096, 1);
                            if (!storage) { hasSafeInputs = NO; void *value = NULL; [invocation setArgument:&value atIndex:argIndex + 2]; continue; }
                            void *value = storage; [invocation setArgument:&value atIndex:argIndex + 2];
                            [argumentObjects addObject:NSNull.null];
                            [outputPointers addObject:@{@"type":type, @"storage":[NSValue valueWithPointer:storage], @"size":@(4096)}];
                            continue;
                        }
                        if ([parameter[@"nullable"] boolValue]) {
                            void *value = NULL; [invocation setArgument:&value atIndex:argIndex + 2];
                            [argumentObjects addObject:NSNull.null]; continue;
                        }
                        hasSafeInputs = NO; void *value = NULL; [invocation setArgument:&value atIndex:argIndex + 2];
                        [argumentObjects addObject:NSNull.null]; continue;
                    }
                    if ([type containsString:@"void *"] && output && ([parameterName rangeOfString:@"bytes|buffer|data" options:NSRegularExpressionSearch | NSCaseInsensitiveSearch].location != NSNotFound)) {
                        NSData *data = auto_object(@"NSData *", caseIndex + argIndex);
                        NSUInteger size = 4096;
                        void *storage = calloc(size, 1);
                        if (!storage) { hasSafeInputs = NO; void *value = NULL; [invocation setArgument:&value atIndex:argIndex + 2]; continue; }
                        if (data.length) memcpy(storage, data.bytes, MIN(data.length, size));
                        [argumentObjects addObject:data ?: NSNull.null];
                        void *value = storage; [invocation setArgument:&value atIndex:argIndex + 2];
                        [outputPointers addObject:@{@"type":type, @"storage":[NSValue valueWithPointer:storage], @"size":@(size)}]; continue;
                    }
                    if (!output) {
                        if ([parameter[@"nullable"] boolValue]) {
                            void *value = NULL; [invocation setArgument:&value atIndex:argIndex + 2];
                            [argumentObjects addObject:NSNull.null]; continue;
                        }
                        hasSafeInputs = NO; void *value = NULL; [invocation setArgument:&value atIndex:argIndex + 2];
                        [argumentObjects addObject:NSNull.null]; continue;
                    }
                    if ([parameter[@"nullable"] boolValue] && caseIndex == 7) {
                        void *value = NULL; [invocation setArgument:&value atIndex:argIndex + 2];
                        [argumentObjects addObject:NSNull.null]; continue;
                    }
                    NSUInteger size = 0; NSGetSizeAndAlignment(encoding + 1, &size, NULL);
                    if (!size || size > 4096) size = 8;
                    void *storage = calloc(1, MAX(size, sizeof(void *)));
                    if (!storage) { hasSafeInputs = NO; void *value = NULL; [invocation setArgument:&value atIndex:argIndex + 2]; continue; }
                    if ([className isEqualToString:@"NSDateFormatter"] &&
                        [selectorName isEqualToString:@"getObjectValue:forString:range:error:"] &&
                        [parameterName.lowercaseString isEqualToString:@"rangep"]) {
                        NSRange initialRange = NSMakeRange(0, 19);
                        memcpy(storage, &initialRange, sizeof(initialRange));
                    }
                    [invocation setArgument:&storage atIndex:argIndex + 2];
                    [argumentObjects addObject:NSNull.null];
                    [outputPointers addObject:@{ @"type":type, @"storage": [NSValue valueWithPointer:storage], @"size":@(MAX(size, sizeof(void *))) }];
                    continue;
                }
                NSUInteger size = 0; NSGetSizeAndAlignment(encoding, &size, NULL);
                if (!size || size > 4096) size = sizeof(long long);
                void *storage = calloc(1, size);
                auto_store_scalar(storage, encoding, type, caseIndex + argIndex, parameter,
                    className, selectorName, size);
                [invocation setArgument:storage atIndex:argIndex + 2];
                [argumentObjects addObject:NSNull.null];
                free(storage);
            }
            if (!hasSafeInputs) {
                printf("%lu\tnot-exercised:no-safe-input\n", (unsigned long)caseIndex);
                for (NSDictionary *slot in outputPointers) free([[slot objectForKey:@"storage"] pointerValue]);
                continue;
            }
            @try {
                [invocation invoke];
                printf("%lu\t", (unsigned long)caseIndex);
                const char *returnType = sig.methodReturnType;
                while (strchr("rnNoORV", returnType[0])) returnType++;
                if (returnType[0] == 'v') fputs("void", stdout);
                else if (returnType[0] == '@') {
                    __unsafe_unretained id result = nil; [invocation getReturnValue:&result];
                    auto_print(auto_canonical(result));
                    if (!classMethod && [selectorName hasPrefix:@"init"]) receiver = result;
                }
                else if (returnType[0] == '^' || returnType[0] == '*') {
                    void *result = NULL; [invocation getReturnValue:&result];
                    NSString *returnName = item[@"return_type"];
                    if (returnType[0] == '*' && [returnName containsString:@"char *"] && result)
                        auto_print(auto_canonical([NSString stringWithUTF8String:(const char *)result]));
                    else if ([returnName hasPrefix:@"CF"] && ([returnName containsString:@"Ref"] || [returnName containsString:@"Identifier"] || [returnName containsString:@"Key"] || [returnName containsString:@"Name"]))
                        auto_print(auto_canonical((id)result));
                    else printf("pointer:%s", result ? "nonnull" : "null");
                }
                else if (returnType[0] == '#' || returnType[0] == ':') {
                    void *result = NULL; [invocation getReturnValue:&result];
                    NSString *name = returnType[0] == '#' ? NSStringFromClass((Class)result) : NSStringFromSelector((SEL)result);
                    auto_print(auto_hex(name ?: @""));
                }
                else if (strchr("fd", returnType[0])) { double value = 0; [invocation getReturnValue:&value]; printf("%a", value); }
                else if (returnType[0] == '{') {
                    NSUInteger size = sig.methodReturnLength; void *bytes = calloc(1, size); [invocation getReturnValue:bytes];
                    if ([item[@"return_type"] containsString:@"NSRange"]) { NSRange range; memcpy(&range, bytes, MIN(size, sizeof(range))); printf("range:%lu,%lu", (unsigned long)range.location, (unsigned long)range.length); }
                    else if ([item[@"return_type"] containsString:@"CFRange"]) { CFRange range; memcpy(&range, bytes, MIN(size, sizeof(range))); printf("range:%ld,%ld", (long)range.location, (long)range.length); }
                    else { fputs("struct:", stdout); for (NSUInteger i = 0; i < size; i++) printf("%02x", ((unsigned char *)bytes)[i]); }
                    free(bytes);
                } else {
                    unsigned long long value = 0; [invocation getReturnValue:&value];
                    if (strchr("CISLQ", returnType[0])) printf("%llu", value);
                    else printf("%lld", (long long)value);
                }
                for (NSDictionary *slot in outputPointers) {
                    putchar('\t'); void *storage = [slot[@"storage"] pointerValue]; NSString *type = slot[@"type"];
                    if ([slot[@"kind"] isEqualToString:@"object-array"]) {
                        NSMutableArray *values = [NSMutableArray array]; id *objects = storage;
                        for (NSUInteger i = 0; i < 2; i++) [values addObject:auto_canonical(objects[i]) ?: @"null"];
                        auto_print(auto_canonical(values));
                    } else if ([type containsString:@"NSRange"] && [type componentsSeparatedByString:@"*"].count == 2) {
                        NSRange range; memcpy(&range, storage, sizeof(range)); printf("range:%lu,%lu", (unsigned long)range.location, (unsigned long)range.length);
                    } else if ([type containsString:@"CFRange"] && [type componentsSeparatedByString:@"*"].count == 2) {
                        CFRange range; memcpy(&range, storage, sizeof(range)); printf("range:%ld,%ld", (long)range.location, (long)range.length);
                    } else {
                        NSString *cleanType = auto_clean_type(type);
                        BOOL objectPointer = [cleanType rangeOfString:@"^id\\s*(?:<[^>]+>\\s*)?\\*"
                            options:NSRegularExpressionSearch].location != NSNotFound;
                        if ([type containsString:@"NSError"] || [type containsString:@"NSString"] || objectPointer) {
                        __unsafe_unretained id value = *(__unsafe_unretained id *)storage; auto_print(auto_canonical(value));
                        } else {
                        NSUInteger size = [slot[@"size"] unsignedIntegerValue];
                        fputs("out:", stdout); for (NSUInteger i = 0; i < MIN(size, (NSUInteger)16); i++) printf("%02x", ((unsigned char *)storage)[i]);
                        }
                    }
                    free(storage);
                }
                if (!classMethod && (returnType[0] == 'v' || auto_type_is_mutable(className))) {
                    putchar('\t'); auto_print(auto_canonical(receiver));
                }
                for (NSUInteger argIndex = 0; argIndex < argumentObjects.count; argIndex++) {
                    id value = argumentObjects[argIndex];
                    NSDictionary *parameter = argIndex < parameters.count ? parameters[argIndex] : @{};
                    if (value != NSNull.null && auto_type_is_mutable(parameter[@"type"] ?: @"")) {
                        printf("\targ%lu=", (unsigned long)argIndex); auto_print(auto_canonical(value));
                    }
                }
                putchar('\n');
            } @catch (NSException *exception) {
                printf("%lu\texception:", (unsigned long)caseIndex); auto_print(auto_hex(exception.name)); putchar(':'); auto_print(auto_hex(exception.reason ?: @"")); putchar('\n');
                for (NSDictionary *slot in outputPointers) free([[slot objectForKey:@"storage"] pointerValue]);
            }
        }
    }
}

static BOOL auto_run_objc_item(const char *name, const char *metadataPath)
{
    NSData *data = [NSData dataWithBytes:metadataPath length:strlen(metadataPath)];
    NSError *error = nil; NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![root isKindOfClass:NSDictionary.class] || ![root[@"name"] isEqualToString:[NSString stringWithUTF8String:name]]) return NO;
    NSDictionary *item = root;
    @try { auto_test_method(item); }
    @catch (NSException *exception) { fputs("exception\t", stdout); auto_print(auto_hex(exception.name)); putchar(':'); auto_print(auto_hex(exception.reason ?: @"")); putchar('\n'); }
    return YES;
}
'''


def _function_metadata(function: dict, enum_values: list[dict]) -> dict:
    result = dict(function)
    for parameter in result.get("parameters", []):
        parameter["enum_values"] = _enum_pool(parameter, enum_values)
    return result


def prepare(framework: str, c_items: set[str], objc_items: set[str], swift_items: set[str],
            details: dict, manual_names: set[str], finch_symbols: set[str], output_dir: Path) -> dict:
    """Make a generated dispatch table and metadata for every safely buildable call."""
    function_by_name = {item["name"]: item for item in details.get("functions", [])}
    variable_by_name = {item["name"]: item for item in details.get("variables", [])}
    method_by_name = details.get("methods", {})
    enum_values = details.get("enum_values", [])
    auto_c = []
    auto_objc = {}
    skipped: dict[str, str] = {}

    for name in sorted(c_items - manual_names):
        if name in function_by_name:
            source, reason = _make_c_function(function_by_name[name], enum_values, finch_symbols)
            if source:
                auto_c.append({"name": name, "category": f"auto/c/{_category(name)}", "source": source,
                               "kind": "function", "signature": function_by_name[name]["type"]})
            else:
                skipped[name] = reason or "no safe input pool"
        elif name in variable_by_name:
            source, reason = _make_c_variable(variable_by_name[name], finch_symbols)
            if source:
                auto_c.append({"name": name, "category": f"auto/c/{_category(name)}", "source": source,
                               "kind": "variable", "signature": variable_by_name[name]["type"]})
            else:
                skipped[name] = reason or "no canonical reader"
        else:
            skipped[name] = "SDK inventory entry has no parsed C declaration signature"

    for name in sorted(objc_items - manual_names):
        method = method_by_name.get(name)
        if not method:
            skipped[name] = "SDK header inventory entry has no matching Objective-C AST signature"
            continue
        reason = _skip_reason(name)
        if reason:
            skipped[name] = reason
            continue
        if (not method.get("class_method") and method.get("class") in {"NSCoder", "NSArchiver", "NSUnarchiver"}) or \
                method.get("selector") in {"initWithCoder:", "encodeWithCoder:"} or any(
                    "NSCoder" in parameter.get("type", "") or "NSArchiver" in parameter.get("type", "")
                    for parameter in method.get("parameters", [])):
            skipped[name] = "archive context is required to build a safe receiver"
            continue
        if method.get("variadic"):
            skipped[name] = "variadic Objective-C methods need API-specific format arguments"
            continue
        if _base_type(method.get("return_type", "")) == "NSDecimal" and "*" not in method.get("return_type", ""):
            skipped[name] = "NSDecimal structure return needs an ABI-specific result reader"
            continue
        unsupported = None
        for parameter in method.get("parameters", []):
            qtype = parameter.get("type", "")
            base = _base_type(qtype)
            if _is_function_pointer(qtype):
                # Comparator blocks are safe and the invocation harness supplies one.
                if not ("(^" in qtype and re.search(r"comparator", name, re.I)):
                    unsupported = f"callback parameter has no safe builder: {qtype}"
                    break
            elif _scalar_kind(qtype) or _is_cf_ref(qtype) or _is_objc_object(qtype) or _base_type(qtype) == "SEL":
                pass
            elif "char *" in qtype or base in ("void", "NSRange", "CFRange", "CGPoint", "CGSize", "CGRect", "NSPoint", "NSSize", "NSRect", "CGAffineTransform", "CATransform3D"):
                pass
            elif "*" in qtype and parameter.get("nullable"):
                pass
            else:
                unsupported = f"no safe input pool for type {qtype}"
                break
        if unsupported:
            skipped[name] = unsupported
            continue
        data = dict(method)
        data["name"] = name
        for parameter in data.get("parameters", []):
            parameter["enum_values"] = _enum_pool(parameter, enum_values)
        data["category"] = f"auto/objc/{_category(name)}"
        auto_objc[name] = data

    for name in sorted(swift_items - manual_names):
        skipped.setdefault(name, "Swift interface entry has no C or Objective-C selector signature")

    # SDK declarations sometimes appear in both the C and Objective-C scanners.
    duplicate = set(entry["name"] for entry in auto_c) & set(auto_objc)
    for name in duplicate:
        skipped[name] = "ambiguous C and Objective-C inventory spelling"
    auto_c = [entry for entry in auto_c if entry["name"] not in duplicate]
    for name in duplicate:
        auto_objc.pop(name, None)

    c_source = "\n\n".join(entry["source"] for entry in auto_c)
    c_entries = "\n".join(
        "    { " + json.dumps(entry["name"]) + ", " +
        ("typed_c_" if entry["kind"] == "function" else "typed_v_") +
        re.sub(r"\W+", "_", entry["name"]) + " },"
        for entry in auto_c
    )
    metadata = {
        "framework": framework,
        "pool_descriptions": POOL_DESCRIPTIONS,
        "max_cases_per_item": MAX_CASES,
        "c": [{"name": entry["name"], "category": entry["category"], "kind": entry["kind"], "signature": entry["signature"]} for entry in auto_c],
        "objc": auto_objc,
        "skipped": skipped,
    }
    metadata_path = output_dir / f"{framework}.types.json"
    metadata_path.write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    return {
        "c_source": _c_runtime() + "\n" + c_source if auto_c else _c_runtime(),
        "c_entries": c_entries,
        "objc_runtime": _objc_runtime(),
        "auto_c_items": [{"name": entry["name"], "category": entry["category"], "kind": entry["kind"], "signature": entry["signature"]} for entry in auto_c],
        "auto_objc_items": [{"name": name, "category": item["category"], "kind": "objc", "signature": item["return_type"] + " (" + ", ".join(p.get("type", "") for p in item.get("parameters", [])) + ")"} for name, item in auto_objc.items()],
        "skipped": skipped,
        "metadata": str(metadata_path),
    }
