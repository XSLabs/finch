#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Read Apple's public constant values and generate Finch definitions and tests.

    python3 tools/constants/generate.py

The SDK headers and .tbd files select public data symbols. Values are read from
the running Apple frameworks with dlsym; the generated source contains only
those observed values and no Apple implementation code or binaries.
"""
from __future__ import annotations

import argparse
import collections
import importlib.util
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "build"
FRAMEWORK_ROOT = BUILD / "root/System/Library/Frameworks"
INVENTORY = BUILD / "constants/inventory.json"
APPLE_VALUES = BUILD / "constants/apple-values.json"
CAPTURE_SOURCE = BUILD / "constants/apple-read.m"
TEST_SOURCE = ROOT / "userland/tests/constants-test.m"
FRAMEWORKS_MK = ROOT / "tools/constants/frameworks.mk"
TARGET = "arm64e-apple-macosx"


def load_tool(path: str, module_name: str):
    spec = importlib.util.spec_from_file_location(module_name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


def run(args: list[str], *, input_text: str | None = None,
        env: dict[str, str] | None = None, check: bool = True) -> subprocess.CompletedProcess:
    result = subprocess.run(args, input=input_text, capture_output=True, text=True, env=env)
    if check and result.returncode:
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(args)}\n"
                           f"{(result.stderr or result.stdout).strip()[-3000:]}")
    return result


def sdk_context() -> tuple[Path, str]:
    sdk = Path(run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).stdout.strip())
    version = run(["xcrun", "--sdk", "macosx", "--show-sdk-version"]).stdout.strip()
    return sdk, version


def bundle_binary(bundle: Path, name: str) -> Path | None:
    for candidate in (bundle / name, bundle / "Versions/Current" / name,
                      *sorted(bundle.glob(f"Versions/*/{name}"))):
        if candidate.is_file():
            return candidate
    return None


def tbd_for(bundle: Path, name: str) -> Path | None:
    candidates = [bundle / f"{name}.tbd", *sorted(bundle.rglob(f"{name}.tbd"))]
    return next((path for path in candidates if path.is_file()), None)


def object_files(bundle_relative: Path, name: str) -> list[Path]:
    # CoreServices, Carbon, Quartz and ApplicationServices build their child
    # frameworks in a parent object directory; direct frameworks use their name.
    parts = [part[:-len(".framework")] for part in bundle_relative.parts
             if part.endswith(".framework")]
    candidates = [BUILD / "obj" / Path(*parts), BUILD / "obj" / name]
    files = set()
    for directory in candidates:
        if directory.is_dir():
            files.update(directory.glob("*.o"))
            files.update((directory / "o").glob("*.o"))
    return sorted(files)


def object_definitions(bundle_relative: Path, name: str) -> set[str]:
    files = object_files(bundle_relative, name)
    if not files:
        return set()
    result = run(["nm", "-gU", "-arch", "arm64e", *map(str, files)], check=False)
    return {line.split()[-1] for line in result.stdout.splitlines() if line.split()}


def source_directory(bundle_relative: Path, name: str) -> Path:
    parts = [part[:-len(".framework")] for part in bundle_relative.parts
             if part.endswith(".framework")]
    exact = ROOT / "userland" / Path(*parts)
    if exact.is_dir():
        return exact
    if len(parts) > 1:
        parent = ROOT / "userland" / Path(*parts[:-1])
        if parent.is_dir() and (any(parent.glob(f"{name}.*")) or (parent / "build.sh").is_file()):
            return parent
    candidates = [path for path in (ROOT / "userland").rglob(name)
                  if path.is_dir() and any(path.glob("*.m")) or
                  path.is_dir() and any(path.glob("*.c"))]
    if len(candidates) == 1:
        return candidates[0]
    direct = ROOT / "userland" / name
    return direct


def type_text(record: dict) -> str:
    return (record.get("desugared_type") or record.get("type") or "").strip()


def classify(record: dict, record_types: dict | None = None) -> tuple[str, str | None]:
    raw = record.get("type") or ""
    text = type_text(record)
    aliases = (record_types or {}).get("__aliases__", {})
    for _ in range(len(aliases)):
        replaced = False
        for alias, target in aliases.items():
            underlying = target.get("desugared_type") or target.get("type")
            if not underlying or alias == underlying:
                continue
            updated = re.sub(rf"\b{re.escape(alias)}\b", underlying, text)
            if updated != text:
                text = updated
                replaced = True
        if not replaced:
            break
    compact = re.sub(r"\b(const|volatile|restrict|_Nonnull|_Nullable|__kindof)\b", " ", text)
    compact = " ".join(compact.split())
    if "(*)" in compact or re.search(r"\(\s*\*", compact):
        return "function-pointer", None
    if "__CFString" in text or re.search(r"\bCFStringRef\b", raw):
        return "cf-string", None
    if re.search(r"\b(?:NSString|NS[A-Za-z0-9_]*Name)\s*\*", text) or "NSNotificationName" in raw:
        return "objc-string", None
    if (re.search(r"\bunsigned char\s*\[\s*\]", compact) and
            (record.get("name", "").endswith("VersionString"))):
        return "c-string", None
    if re.search(r"\b(?:unsigned char|uint8_t|UInt8)\s*\[", compact):
        return "byte-array", None
    if re.search(r"\b(?:unsigned char|uint8_t|UInt8)\s*\*", compact):
        return "byte-pointer", None
    if re.search(r"\b(?:const )?char\s*\*", compact) or re.search(r"(?<!unsigned )\bchar\s*\[", compact):
        return "c-string", None
    if re.search(r"\b(?:long double|double|float)\b", compact):
        return "floating", None
    if "enum " in compact:
        return "signed", None
    if re.search(r"\b(?:bool|BOOL|Boolean|char|short|int|long|NSInteger|NSUInteger|size_t|ssize_t|CFIndex|SInt\d+|UInt\d+|u?int\d+_t|OSStatus)\b", compact):
        return ("unsigned" if re.search(r"\b(?:unsigned|NSUInteger|size_t|UInt\d+|uint\d+_t)\b", compact)
                else "signed"), None
    match = re.search(r"\bstruct\s+([A-Za-z_][A-Za-z0-9_]*)\b", compact)
    if match and "*" not in compact:
        return "struct", match.group(1)
    if "*" not in compact and record_types:
        alias = re.search(r"([A-Za-z_][A-Za-z0-9_]*)\s*$", compact)
        if alias:
            candidate = record_types.get(alias.group(1))
            if candidate and candidate.get("tag") == "struct":
                return "struct", alias.group(1)
    if (re.search(r"\bid\b|\bClass\b", raw) or
            re.search(r"\b[A-Za-z_][A-Za-z0-9_]*Ref\b", raw) or
            re.search(r"\b(?:NS|AV|UT|CI|CA|CT)[A-Za-z0-9_]*\s*\*", text)):
        return "object", None
    if "*" in compact:
        return "opaque-pointer", None
    return "unsupported", None


def clean_framework_id(path: Path) -> str:
    return "/".join(part[:-len(".framework")] for part in path.parts
                     if part.endswith(".framework"))


def compile_include(name: str, sdk_framework: Path) -> list[str]:
    audit = load_tool("tools/c-api-audit.py", "finch_c_api_audit")
    header_root, _, roots = audit.public_headers(sdk_framework, name)
    result = []
    for header in roots:
        relative = header.relative_to(header_root).as_posix()
        result.append(f"#import <{name}/{relative}>")
    return result


def scan() -> dict:
    sdk, sdk_version = sdk_context()
    audit = load_tool("tools/c-api-audit.py", "finch_c_api_audit")
    coverage = load_tool("tools/api-coverage.py", "finch_api_coverage")
    frameworks = []
    names_by_install = {}
    bundle_paths = sorted(path for path in FRAMEWORK_ROOT.rglob("*.framework") if path.is_dir())
    for bundle in bundle_paths:
        name = bundle.name[:-len(".framework")]
        relative = bundle.relative_to(FRAMEWORK_ROOT)
        sdk_bundle = sdk / "System/Library/Frameworks" / relative
        if not (sdk_bundle / "Headers").is_dir():
            continue
        binary = bundle_binary(bundle, name)
        tbd = tbd_for(sdk_bundle, name)
        if not binary or not tbd:
            continue
        data = coverage.tbd_exports(tbd)
        exports = {symbol for symbol in data["symbols"]
                   if coverage.public_c_symbol(symbol)}
        type_records: dict = {}
        declarations = audit.sdk_declaration_records(name, sdk_bundle, type_records)
        own = object_definitions(relative, name)
        binary_exports = run(["nm", "-gU", "-arch", "arm64e", str(binary)], check=False)
        present = {line.split()[-1] for line in binary_exports.stdout.splitlines() if line.split()}
        source_dir = source_directory(relative, name)
        constants = []
        for symbol, records in declarations.items():
            if symbol not in exports:
                continue
            variable = next((record for record in records if record["kind"] == "VarDecl"), None)
            if variable is None:
                continue
            kind, record_name = classify(variable, type_records)
            constants.append({
                "framework": clean_framework_id(relative), "module": name,
                "symbol": symbol, "name": variable["name"], "kind": kind,
                "record_name": record_name, "type": variable.get("type"),
                "desugared_type": variable.get("desugared_type"),
                "header": variable["header"], "present": symbol in present,
                "object_defined": symbol in own, "value": None,
                "testable": kind != "unsupported",
            })
        identifier = clean_framework_id(relative)
        frameworks.append({
            "id": identifier, "module": name, "relative_path": relative.as_posix(),
            "install_name": data["install_name"], "reexports": data["libraries"],
            "source_dir": str(source_dir.relative_to(ROOT)) if source_dir.exists() else None,
            "sdk_headers": str((sdk_bundle / "Headers").relative_to(sdk)),
            "includes": compile_include(name, sdk_bundle),
            "types": type_records,
            "constants": sorted(constants, key=lambda item: item["symbol"]),
        })
        if data["install_name"]:
            names_by_install[data["install_name"]] = identifier

    for framework in frameworks:
        framework["reexports"] = [names_by_install[install]
                                  for install in framework["reexports"]
                                  if install in names_by_install]
    return {"schema_version": 1, "sdk_version": sdk_version, "sdk_path": str(sdk),
            "frameworks": frameworks}


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def load_inventory() -> dict | None:
    if not INVENTORY.is_file():
        return None
    try:
        inventory = json.loads(INVENTORY.read_text())
        sdk, version = sdk_context()
    except (OSError, RuntimeError, json.JSONDecodeError):
        return None
    if inventory.get("sdk_version") != version or Path(inventory.get("sdk_path", "")) != sdk:
        return None
    return inventory


def refresh_struct_types(inventory: dict) -> None:
    audit = load_tool("tools/c-api-audit.py", "finch_c_api_audit")
    sdk = Path(inventory["sdk_path"])
    for framework in inventory["frameworks"]:
        needs_types = any(
            constant["kind"] == "struct" or
            (constant["kind"] == "unsupported" and
             "*" not in (constant.get("desugared_type") or constant.get("type") or ""))
            for constant in framework["constants"])
        if not needs_types:
            framework["types"] = {}
        else:
            sdk_bundle = sdk / "System/Library/Frameworks" / framework["relative_path"]
            types: dict = {}
            audit.sdk_declaration_records(framework["module"], sdk_bundle, types)
            framework["types"] = types
        types = framework["types"]
        for constant in framework["constants"]:
            kind, record_name = classify(constant, types)
            constant["kind"] = kind
            constant["record_name"] = record_name
            constant["testable"] = kind != "unsupported"


def c_type_kind(type_text_value: str, raw_type: str = "", record_types: dict | None = None) -> tuple[str, str | None]:
    return classify({"type": raw_type or type_text_value,
                     "desugared_type": type_text_value}, record_types)


def struct_type_name(type_text_value: str) -> str | None:
    match = re.search(r"\bstruct\s+([A-Za-z_][A-Za-z0-9_]*)\b", type_text_value)
    return match.group(1) if match else None


def struct_ctype_name(records: dict, name: str) -> str:
    record = records.get(name)
    if not record:
        raise ValueError(f"no complete struct declaration for {name}")
    if record.get("name"):
        return "struct " + record["name"]
    return next(iter(record.get("aliases", [])), name)


def struct_printers(framework: dict, used: set[str], emitted: set[str] | None = None) -> str:
    records = framework.get("types", {})
    output = []
    emitted = emitted if emitted is not None else set()

    def emit(name: str) -> None:
        if name in emitted:
            return
        record = records.get(name)
        if not record or record.get("tag") != "struct":
            raise ValueError(f"no complete struct declaration for {name}")
        emitted.add(name)
        ctype_name = struct_ctype_name(records, name)
        fields = [field for field in record["fields"] if field.get("name")]
        for field in fields:
            kind, nested = c_type_kind(field.get("desugared_type") or field.get("type") or "",
                                       record_types=records)
            if kind == "struct" and nested:
                emit(nested)
        function = "print_" + re.sub(r"\W", "_", framework["id"] + "_" + name)
        output.append(f"static void {function}(const {ctype_name} *value)\n{{\n    putchar('{{');\n")
        for index, field in enumerate(fields):
            field_name = field["name"]
            field_type = field.get("desugared_type") or field.get("type") or ""
            kind, nested = c_type_kind(field_type, field.get("type") or "", records)
            prefix = "" if index == 0 else "    putchar(',');\n"
            output.append(prefix + f"    json_string(\"{field_name}\"); putchar(':');\n")
            if kind == "byte-pointer":
                length_field = next((candidate.get("name") for candidate in fields
                                     if candidate.get("name", "").lower() in
                                     ("length", "size", "datalength", "datasize")), None)
                if not length_field:
                    raise ValueError(f"no length field for {name}.{field_name}")
                output.append(f"    json_hex_bytes((const unsigned char *)value->{field_name}, (size_t)value->{length_field});\n")
                continue
            if kind == "byte-array":
                output.append(f"    json_hex_bytes((const unsigned char *)value->{field_name}, sizeof(value->{field_name}));\n")
                continue
            if kind == "function-pointer":
                output.append(f"    print_function_pointer((uintptr_t)value->{field_name});\n")
                continue
            if kind == "opaque-pointer":
                if name == "NSMapTableKeyCallBacks" and field_name == "notAKeyMarker":
                    output.append(f"    print_raw_pointer((const void *)value->{field_name});\n")
                else:
                    output.append(f"    print_pointer_value((const void *)value->{field_name});\n")
                continue
            if kind == "unsupported":
                raise ValueError(f"unsupported field {name}.{field_name}: {field_type}")
            expression = f"value->{field_name}"
            output.append(print_expression(expression, field_type, kind, nested, framework["id"], records))
        output.append("    putchar('}');\n}\n\n")
    for name in sorted(used):
        emit(name)
    return "".join(output)


def print_expression(expression: str, type_value: str, kind: str, record_name: str | None,
                     framework_id: str, records: dict) -> str:
    if kind in ("objc-string", "cf-string", "object"):
        return f"    print_object((id){expression});\n"
    if kind == "c-string":
        return f"    json_string((const char *){expression});\n"
    if kind == "byte-pointer":
        return f"    json_hex_bytes((const unsigned char *)({expression}), 0);\n"
    if kind == "opaque-pointer":
        return f"    print_pointer_value((const void *)({expression}));\n"
    if kind == "byte-array":
        return f"    json_hex_bytes((const unsigned char *)({expression}), sizeof({expression}));\n"
    if kind == "signed":
        return f'    printf("\\\"%lld\\\"", (long long)({expression}));\n'
    if kind == "unsigned":
        return f'    printf("\\\"%llu\\\"", (unsigned long long)({expression}));\n'
    if kind == "floating":
        format_string = "%La" if "long double" in type_value else "%a"
        cast = "long double" if "long double" in type_value else "double"
        return f'    printf("\\\"{format_string}\\\"", ({cast})({expression}));\n'
    if kind == "struct" and record_name:
        function = "print_" + re.sub(r"\W", "_", framework_id + "_" + record_name)
        ctype_name = struct_ctype_name(records, record_name)
        return f"    {function}((const {ctype_name} *)&({expression}));\n"
    raise ValueError(f"cannot print {type_value}")


def testable_frameworks(inventory: dict) -> list[dict]:
    return [framework for framework in inventory["frameworks"]
            if any(constant["testable"] for constant in framework["constants"])]


def headers_for_test(frameworks: list[dict]) -> list[str]:
    headers = set()
    for framework in frameworks:
        constants = [constant for constant in framework["constants"] if constant["testable"]]
        if not constants:
            continue
        umbrella = f"#import <{framework['module']}/{framework['module']}.h>"
        if umbrella in framework["includes"]:
            headers.add(umbrella)
        else:
            headers.update(f"#import <{framework['module']}/{constant['header']}>"
                           for constant in constants)
    return sorted(headers)


def symbol_handle_name(index: int) -> str:
    return f"handle_{index}"


def output_code(frameworks: list[dict], *, helper: bool) -> str:
    lines = [
        "/* Generated by tools/constants/generate.py. Do not edit. */",
        "#import <Foundation/Foundation.h>",
        "#include <dlfcn.h>",
        "#include <inttypes.h>",
        "#include <objc/runtime.h>",
        "#include <stdint.h>",
        "#include <stdio.h>",
        "#include <stdlib.h>",
        "#include <string.h>",
        "",
    ]
    lines.extend(headers_for_test(frameworks))
    lines.append("")
    lines.extend([
        "static void json_string(const char *text)",
        "{",
        "    if (!text) { fputs(\"null\", stdout); return; }",
        "    putchar('\\\"');",
        "    for (const unsigned char *p = (const unsigned char *)text; *p; p++) {",
        "        switch (*p) {",
        "        case '\\\"': fputs(\"\\\\\\\"\", stdout); break;",
        "        case '\\\\': fputs(\"\\\\\\\\\", stdout); break;",
        "        case '\\n': fputs(\"\\\\n\", stdout); break;",
        "        case '\\r': fputs(\"\\\\r\", stdout); break;",
        "        case '\\t': fputs(\"\\\\t\", stdout); break;",
        "        default: if (*p < 0x20) printf(\"\\\\u%04x\", *p); else putchar(*p);",
        "        }",
        "    }",
        "    putchar('\\\"');",
        "}",
        "",
        "static NSString *canonical_description(id value)",
        "{",
        "    const char *description = [[value description] UTF8String];",
        "    if (!description) return @\"\";",
        "    size_t length = strlen(description), input = 0, output = 0;",
        "    char *normalized = malloc(length + 1);",
        "    if (!normalized) return [value description];",
        "    while (input < length) {",
        "        if (description[input] == '0' && description[input + 1] == 'x' && description[input + 2] &&",
        "            ((description[input + 2] >= '0' && description[input + 2] <= '9') || (description[input + 2] >= 'a' && description[input + 2] <= 'f') || (description[input + 2] >= 'A' && description[input + 2] <= 'F'))) {",
        "            memcpy(normalized + output, \"0x<address>\", 11); output += 11; input += 2;",
        "            while (input < length && ((description[input] >= '0' && description[input] <= '9') || (description[input] >= 'a' && description[input] <= 'f') || (description[input] >= 'A' && description[input] <= 'F'))) input++;",
        "        } else normalized[output++] = description[input++];",
        "    }",
        "    normalized[output] = '\\0';",
        "    NSString *result = [NSString stringWithUTF8String:normalized];",
        "    free(normalized);",
        "    return result ?: [value description];",
        "}",
        "",
        "static void print_raw_pointer(const void *pointer)",
        "{",
        r'    printf("\"0x%" PRIxPTR "\"", (uintptr_t)pointer);',
        "}",
        "",
        "static void print_pointer_value(const void *pointer)",
        "{",
        "    Dl_info info = {0};",
        "    if (dladdr((void *)pointer, &info) && info.dli_sname) {",
        "        fputs(\"{\\\"symbol\\\":\", stdout); json_string(info.dli_sname); putchar('}'); return;",
        "    }",
        "    if (info.dli_fname) {",
        "        fputs(\"{\\\"image\\\":\", stdout); json_string(info.dli_fname);",
        r'        printf(",\"offset\":\"0x%" PRIxPTR "\"}", (uintptr_t)pointer - (uintptr_t)info.dli_fbase);',
        "        return;",
        "    }",
        r'    printf("\"0x%" PRIxPTR "\"", (uintptr_t)pointer);',
        "}",
        "",
        "static void print_object(id value)",
        "{",
        "    if (!value) { fputs(\"null\", stdout); return; }",
        "    if ((uintptr_t)value < 4096) {",
        "        char pointer[2 + sizeof(uintptr_t) * 2 + 1];",
        "        snprintf(pointer, sizeof(pointer), \"0x%\" PRIxPTR, (uintptr_t)value);",
        "        fputs(\"{\\\"pointer\\\":\", stdout); json_string(pointer); putchar('}');",
        "        return;",
        "    }",
        "    if (!object_getClass(value)) { print_pointer_value(value); return; }",
        "    if ([value isKindOfClass:[NSString class]]) {",
        "        json_string([(NSString *)value UTF8String]);",
        "        return;",
        "    }",
        "    fputs(\"{\\\"class\\\":\", stdout);",
        "    json_string(class_getName(object_getClass(value)));",
        "    fputs(\",\\\"description\\\":\", stdout);",
        "    json_string([canonical_description(value) UTF8String]);",
        "    putchar('}');",
        "}",
        "",
        "static void print_SCNetworkInterfaceRef(SCNetworkInterfaceRef value)",
        "{",
        "    if (!value) { fputs(\"null\", stdout); return; }",
        "    CFStringRef type = SCNetworkInterfaceGetInterfaceType(value);",
        "    fputs(\"{\\\"class\\\":\\\"SCNetworkInterfaceRef\\\",\\\"description\\\":\", stdout);",
        "    if (type) json_string([canonical_description((id)type) UTF8String]); else fputs(\"null\", stdout);",
        "    putchar('}');",
        "}",
        "",
        "static void __attribute__((unused)) json_hex_bytes(const unsigned char *bytes, size_t length)",
        "{",
        "    putchar('\\\"');",
        "    if (bytes) for (size_t i = 0; i < length; i++) printf(\"%02x\", bytes[i]);",
        "    putchar('\\\"');",
        "}",
        "",
        "static void print_function_pointer(uintptr_t pointer)",
        "{",
        "    Dl_info info = {0};",
        "    if (!pointer) { fputs(\"null\", stdout); return; }",
        "    if (dladdr((void *)pointer, &info) && info.dli_sname) { json_string(info.dli_sname); return; }",
        "    if (!info.dli_fname) { fputs(\"null\", stdout); return; }",
        "    fputs(\"{\\\"image\\\":\", stdout); json_string(info.dli_fname);",
        r'    printf(",\"offset\":\"0x%" PRIxPTR "\"}", pointer - (uintptr_t)info.dli_fbase);',
        "}",
        "",
    ])
    lines.extend([
        "static void *open_framework(const char *install_name)",
        "{",
        ("    void *handle = dlopen(install_name, RTLD_LAZY);" if helper else
         "    void *handle = dlopen(install_name, RTLD_LAZY | RTLD_NOLOAD);"),
        "    return handle ? handle : RTLD_DEFAULT;",
        "}",
        "",
    ])

    for framework in frameworks:
        used = {constant["record_name"] for constant in framework["constants"]
                if constant["testable"] and constant["kind"] == "struct"}
        emitted: set[str] = set()
        for name in sorted(used):
            try:
                lines.append(struct_printers(framework, {name}, emitted))
            except ValueError as error:
                for constant in framework["constants"]:
                    if constant["record_name"] == name:
                        constant["testable"] = False
                        constant["unsupported_reason"] = str(error)

    def emit_value(constant: dict, framework_id: str) -> str:
        kind = constant["kind"]
        symbol = constant["symbol"][1:] if constant["symbol"].startswith("_") else constant["symbol"]
        value_type = constant.get("desugared_type") or constant.get("type")
        if not value_type:
            return ""
        read = f"*(({value_type} *)address)"
        if kind in ("objc-string", "cf-string", "object"):
            declared_type = constant.get("type") or value_type
            expression = (f"print_SCNetworkInterfaceRef({read});"
                          if "SCNetworkInterfaceRef" in declared_type or
                          "__SCNetworkInterface" in value_type else
                          f"print_object((id){read});")
        elif kind == "c-string":
            if re.search(r"\[\s*\]", value_type):
                expression = "json_string((const char *)address);"
            else:
                expression = f"json_string((const char *){read});"
        elif kind == "byte-array":
            array_match = re.search(r"\[(\d+)\]", constant.get("desugared_type") or constant.get("type") or "")
            if not array_match:
                return ""
            expression = f"json_hex_bytes((const unsigned char *)address, {array_match.group(1)});"
        elif kind == "signed":
            expression = f'printf("\\\"%lld\\\"", (long long){read});'
        elif kind == "unsigned":
            expression = f'printf("\\\"%llu\\\"", (unsigned long long){read});'
        elif kind == "floating":
            raw = (constant.get("desugared_type") or constant.get("type") or "")
            if "long double" in raw:
                expression = f'printf("\\\"%La\\\"", (long double){read});'
            elif re.search(r"\bfloat\b", raw) and not re.search(r"\bdouble\b", raw):
                expression = f'printf("\\\"%a\\\"", (double){read});'
            else:
                expression = f'printf("\\\"%a\\\"", (double){read});'
        elif kind == "struct" and constant.get("record_name"):
            function = "print_" + re.sub(r"\W", "_", framework_id + "_" + constant["record_name"])
            ctype_name = struct_ctype_name(framework.get("types", {}), constant["record_name"])
            expression = f"{function}((const {ctype_name} *)address);"
        else:
            return ""
        return ("    {\n"
                f"    printf(\"{framework_id}\\t{symbol}\\t\");\n"
                f"    void *address = dlsym(open_framework(\"{constant.get('install_name', '')}\"), \"{symbol}\");\n"
                f"    if (!address) fputs(\"null\", stdout); else {{ {expression} }}\n"
                "    putchar('\\n');\n    }\n")

    # Each record carries its framework install name so dlsym checks that image first.
    for framework in frameworks:
        for constant in framework["constants"]:
            constant["install_name"] = framework["install_name"]
    lines.append("int main(void)\n{\n    setvbuf(stdout, NULL, _IOLBF, 0);\n")
    first = next((constant for framework in frameworks for constant in framework["constants"]
                  if constant["testable"]), None)
    if first:
        symbol = first["symbol"][1:] if first["symbol"].startswith("_") else first["symbol"]
        lines.append(f"    Dl_info info = {{0}};\n    void *first = dlsym(open_framework(\"{first['install_name']}\"), \"{symbol}\");\n")
        lines.append("    if (first && dladdr(first, &info)) printf(\"constants-test: %s\\n\", info.dli_fname);\n")
        lines.append("    else puts(\"constants-test: framework value unavailable\");\n")
    for framework in frameworks:
        for constant in framework["constants"]:
            if constant["testable"]:
                symbol = constant["symbol"][1:] if constant["symbol"].startswith("_") else constant["symbol"]
                code = emit_value(constant, framework["id"])
                if code:
                    lines.append(code)
    lines.append("    return 0;\n}\n")
    return "\n".join(lines)


def link_fragment(inventory: dict) -> str:
    sdk_paths, modules = set(), set()
    for framework in testable_frameworks(inventory):
        path = Path(framework["relative_path"])
        sdk_paths.add((Path(inventory["sdk_path"]) / "System/Library/Frameworks" / path).parent)
        root_bundle = Path(framework["relative_path"]).parts[0]
        modules.add(root_bundle[:-len(".framework")])
    sdk = Path(inventory["sdk_path"])
    relative_paths = sorted(path.relative_to(sdk).as_posix() for path in sdk_paths)
    return ("# Generated by tools/constants/generate.py. Do not edit.\n"
            "CONSTANT_TEST_FRAMEWORK_SEARCH_PATHS := " + " ".join(relative_paths) + "\n"
            "CONSTANT_TEST_FRAMEWORKS := " + " ".join(sorted(modules)) + "\n")


def generated_source(framework: dict) -> tuple[str, list[dict], list[str]]:
    supported, unsupported = [], []
    for constant in framework["constants"]:
        if constant["present"] or constant["object_defined"]:
            continue
        if not constant.get("captured"):
            unsupported.append(constant["name"] + ": no captured value")
            continue
        kind = constant["kind"]
        value = constant["value"]
        if kind in ("objc-string", "cf-string", "object") and (isinstance(value, str) or value is None):
            supported.append(constant)
        elif (kind == "object" and isinstance(value, dict) and
              value.get("class", "").startswith("NSConstant") and
              re.fullmatch(r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?", value.get("description", ""))):
            supported.append(constant)
        elif kind == "c-string" and (isinstance(value, str) or value is None):
            supported.append(constant)
        elif kind == "byte-array" and isinstance(value, str):
            supported.append(constant)
        elif kind == "opaque-pointer" and isinstance(value, dict) and "pointer" in value:
            if int(value["pointer"], 16) < 4096:
                supported.append(constant)
            else:
                unsupported.append(constant["name"] + ": opaque pointers need a Finch-owned value")
        elif kind in ("signed", "unsigned", "floating") and isinstance(value, str):
            supported.append(constant)
        elif kind == "struct" and isinstance(value, dict):
            supported.append(constant)
        else:
            unsupported.append(constant["name"] + ": runtime value cannot be initialized safely")
    if not supported:
        return "", [], unsupported

    includes = ["/* Generated by tools/constants/generate.py. Do not edit. */",
                "#include <CoreFoundation/CoreFoundation.h>"]
    includes.extend(framework["includes"])
    lines = list(dict.fromkeys(includes)) + [""]

    def init_for(kind: str, value, record_name: str | None = None,
                 value_type: str | None = None) -> str:
        if value is None:
            if kind in ("objc-string", "cf-string", "object", "c-string", "byte-pointer", "opaque-pointer"):
                return "NULL"
            raise ValueError(f"null value for {kind}")
        if kind in ("objc-string", "cf-string", "object") and isinstance(value, dict) and "pointer" in value:
            if not value_type:
                raise ValueError("missing object pointer type")
            pointer = int(value["pointer"], 16)
            return f"({value_type})(uintptr_t)0x{pointer:x}"
        if kind == "object" and isinstance(value, dict) and value.get("class", "").startswith("NSConstant"):
            description = value.get("description", "")
            if re.fullmatch(r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?", description):
                return f"@({description})"
        if kind == "opaque-pointer" and isinstance(value, dict) and "pointer" in value:
            if not value_type:
                raise ValueError("missing pointer type")
            pointer = int(value["pointer"], 16)
            return f"({value_type})(uintptr_t)0x{pointer:x}"
        if kind == "cf-string":
            return f"CFSTR({c_literal(value)})"
        if kind in ("objc-string", "object"):
            return "@" + c_literal(value)
        if kind == "c-string":
            return c_literal(value)
        if kind in ("byte-pointer", "byte-array"):
            data = bytes.fromhex(value)
            values = ", ".join(f"0x{byte:02x}" for byte in data)
            if kind == "byte-pointer":
                return "NULL" if not data else f"(void *)(const unsigned char[]){{ {values} }}"
            return "{ " + values + " }"
        if kind in ("signed", "unsigned", "floating"):
            literal = str(value)
            if kind == "floating" and record_name == "float":
                literal += "f"
            if kind == "floating" and literal in ("inf", "-inf", "nan"):
                return {"inf": "INFINITY", "-inf": "-INFINITY", "nan": "NAN"}[literal]
            return literal
        if kind == "struct" and record_name and isinstance(value, dict):
            record = framework["types"].get(record_name)
            if not record or record.get("tag") != "struct":
                raise ValueError(f"missing struct type {record_name}")
            entries = []
            for field in record["fields"]:
                field_name = field.get("name")
                if not field_name or field_name not in value:
                    continue
                field_type = field.get("desugared_type") or field.get("type") or ""
                field_kind, field_record = c_type_kind(field_type, field.get("type") or "", framework["types"])
                field_float = "float" if field_kind == "floating" and "float" in field_type and "double" not in field_type else field_record
                entries.append(f".{field_name} = {init_for(field_kind, value[field_name], field_float, field_type)}")
            return "{ " + ", ".join(entries) + " }"
        raise ValueError(f"no initializer for {kind}")

    emitted = []
    for constant in supported:
        symbol = constant["name"]
        source_value = constant["value"]
        try:
            value_type = constant.get("desugared_type") or constant.get("type")
            initializer = init_for(constant["kind"], source_value,
                                   constant.get("record_name"), value_type)
        except ValueError as error:
            unsupported.append(symbol + ": " + str(error))
            continue
        value_type = constant.get("desugared_type") or constant.get("type")
        if not value_type:
            unsupported.append(symbol + ": missing declared type")
            continue
        declaration = c_declaration(value_type, symbol)
        lines.append(f"__attribute__((visibility(\"default\"))) {declaration} = {initializer};")
        emitted.append(constant)
    return "\n".join(lines) + "\n", emitted, unsupported


def c_literal(value: str) -> str:
    parts = ['"']
    for char in value:
        if char == '"':
            parts.append('\\"')
        elif char == "\\":
            parts.append("\\\\")
        elif char == "\n":
            parts.append("\\n")
        elif char == "\r":
            parts.append("\\r")
        elif char == "\t":
            parts.append("\\t")
        elif ord(char) < 0x20:
            parts.append(f"\\{ord(char):03o}")
        else:
            parts.append(char)
    parts.append('"')
    return "".join(parts)


def c_declaration(value_type: str, symbol: str) -> str:
    array = re.fullmatch(r"(.*?)\s*(\[[^\]]*\])", value_type)
    if array:
        return f"{array.group(1).rstrip()} {symbol}{array.group(2)}"
    return f"{value_type} {symbol}"


def merge_exports(framework: dict, constants: list[dict]) -> None:
    if not constants:
        return
    source_dir = framework.get("source_dir")
    if not source_dir or not (ROOT / source_dir).is_dir():
        source_dir = str(source_directory(Path(framework["relative_path"]), framework["module"]).relative_to(ROOT))
    path = ROOT / source_dir / "exports.txt"
    if not path.is_file():
        return
    existing = path.read_text().splitlines()
    names = {line.strip() for line in existing if line.strip() and not line.lstrip().startswith("#")}
    missing = sorted(constant["symbol"] for constant in constants if constant["symbol"] not in names)
    if missing:
        with path.open("a") as file:
            if existing and existing[-1].strip():
                file.write("\n")
            file.write("\n".join(missing) + "\n")


def generate(inventory: dict) -> None:
    frameworks = testable_frameworks(inventory)
    for framework in frameworks:
        source, emitted, unsupported = generated_source(framework)
        if source:
            source_dir = framework.get("source_dir")
            if not source_dir or not (ROOT / source_dir).is_dir():
                source_dir = str(source_directory(Path(framework["relative_path"]), framework["module"]).relative_to(ROOT))
            directory = ROOT / source_dir
            directory.mkdir(parents=True, exist_ok=True)
            (directory / f"{framework['module']}Constants_Generated.m").write_text(source)
        visible = emitted + [constant for constant in framework["constants"]
                             if not constant["present"] and constant["object_defined"]]
        merge_exports(framework, visible)
        print(f"{framework['id']}: {len(emitted)} definitions generated, {len(unsupported)} unsupported")
        for item in unsupported:
            print(f"  cannot generate {item}")
    TEST_SOURCE.write_text(output_code(frameworks, helper=False))
    FRAMEWORKS_MK.write_text(link_fragment(inventory))


def capture(inventory: dict) -> dict:
    frameworks = testable_frameworks(inventory)
    CAPTURE_SOURCE.parent.mkdir(parents=True, exist_ok=True)
    source = output_code(frameworks, helper=True)
    CAPTURE_SOURCE.write_text(source)
    sdk = Path(inventory["sdk_path"])
    search_paths = set()
    for framework in frameworks:
        path = sdk / "System/Library/Frameworks" / framework["relative_path"]
        search_paths.add(path.parent)
    compiler = run(["xcrun", "--sdk", "macosx", "-f", "clang"]).stdout.strip()
    output = BUILD / "constants/apple-read"
    command = [compiler, "-arch", "arm64e", "-mmacosx-version-min=26.0",
               "-O0", "-Wno-deprecated-declarations", "-o", str(output), str(CAPTURE_SOURCE)]
    for path in sorted(search_paths):
        command.extend(["-F", str(path)])
    command.extend(["-F", str(sdk / "System/Library/Frameworks"), "-framework", "Foundation"])
    env = {key: value for key, value in os.environ.items() if not key.startswith("DYLD_")}
    run(command, env=env)
    captured = run([str(output)], env=env).stdout
    values = {}
    for line in captured.splitlines():
        pieces = line.split("\t", 2)
        if len(pieces) != 3:
            continue
        framework_id, symbol, value = pieces
        try:
            values[f"{framework_id}:{symbol}"] = json.loads(value)
        except json.JSONDecodeError:
            values[f"{framework_id}:{symbol}"] = None
    for framework in frameworks:
        for constant in framework["constants"]:
            key = f"{framework['id']}:{constant['symbol'][1:]}"
            constant["captured"] = key in values
            constant["value"] = values.get(key)
            if not constant["captured"]:
                constant["testable"] = False
                constant["unsupported_reason"] = "Apple helper did not return a value"
    write_json(APPLE_VALUES, {"sdk_version": inventory["sdk_version"], "values": values})
    write_json(INVENTORY, inventory)
    return inventory


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scan", action="store_true", help="scan headers and exports without reading values")
    parser.add_argument("--capture", action="store_true", help="read values from Apple frameworks")
    parser.add_argument("--generate", action="store_true", help="write definitions and the comparison test")
    args = parser.parse_args()
    try:
        if args.scan:
            inventory = scan()
            total = sum(len(framework["constants"]) for framework in inventory["frameworks"])
            missing = sum(not constant["present"] for framework in inventory["frameworks"]
                          for constant in framework["constants"])
            print(f"macOS SDK {inventory['sdk_version']}: {len(inventory['frameworks'])} Finch frameworks, "
                  f"{total} exported data symbols, {missing} missing")
            write_json(INVENTORY, inventory)
            return 0
        inventory = load_inventory()
        if inventory is None:
            inventory = scan()
            total = sum(len(framework["constants"]) for framework in inventory["frameworks"])
            missing = sum(not constant["present"] for framework in inventory["frameworks"]
                          for constant in framework["constants"])
            print(f"macOS SDK {inventory['sdk_version']}: {len(inventory['frameworks'])} Finch frameworks, "
                  f"{total} exported data symbols, {missing} missing")
        needs_capture = args.capture or not args.generate or any(
            "captured" not in constant
            for framework in inventory["frameworks"] for constant in framework["constants"]
            if constant.get("testable"))
        if needs_capture:
            refresh_struct_types(inventory)
            inventory = capture(inventory)
        if args.generate or not args.capture:
            generate(inventory)
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        print(f"constant generation failed: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
