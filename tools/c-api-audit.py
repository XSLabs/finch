#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Compare a framework's public C declarations with Finch's exported symbols.

    tools/c-api-audit.py FRAMEWORK

The macOS SDK headers are parsed at run time with Clang. Finch's built framework
is checked with nm. Missing functions and variables are grouped by SDK header;
no SDK files are copied into the repository.
"""
import json
from functools import lru_cache
import os
import re
import subprocess
import sys
from pathlib import Path

FINCH_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FRAMEWORKS = os.path.join(FINCH_ROOT, "build/root/System/Library/Frameworks")


def run(command, **kwargs):
    return subprocess.run(command, capture_output=True, text=True, check=True, **kwargs).stdout.strip()


@lru_cache(maxsize=1)
def macos_sdk_version():
    return run(["xcrun", "--sdk", "macosx", "--show-sdk-version"])


def sdk_path():
    return run(["xcrun", "--show-sdk-path"])


def local_include(path, include, name, headers):
    """Resolve an include only when it stays inside this framework's Headers."""
    if include.startswith(name + "/"):
        candidate = headers / include[len(name) + 1:]
    elif include.startswith("/"):
        return None
    else:
        candidate = path.parent / include
    try:
        candidate = candidate.resolve(strict=True)
        candidate.relative_to(headers.resolve())
    except (OSError, ValueError):
        return None
    return candidate if candidate.is_file() else None


def public_headers(framework, name):
    """Find the framework umbrella and the headers it includes."""
    candidates = [framework / "Modules/module.modulemap", framework / "module.modulemap"]
    module_text = "\n".join(p.read_text(errors="replace") for p in candidates if p.is_file())
    headers = framework / "Headers"
    umbrella = headers / (name + ".h")
    roots = []
    if umbrella.is_file():
        roots.append(umbrella)
    else:
        match = re.search(r'umbrella\s+header\s+"([^"]+)"', module_text)
        if match:
            root = headers / match.group(1)
            if root.is_file():
                roots.append(root)
        if not roots and re.search(r'umbrella\s+"\."', module_text):
            roots.extend(sorted(headers.rglob("*.h")))
        if not roots:
            roots.extend(sorted(headers.rglob("*.h")))
    if not roots:
        raise FileNotFoundError(f"no public headers in {headers}")

    found, pending = set(), list(roots)
    include_re = re.compile(r'^\s*#\s*(?:include|import)\s*[<"]([^>"]+)[>"]', re.M)
    while pending:
        path = pending.pop().resolve()
        if path in found:
            continue
        found.add(path)
        source = path.read_text(errors="replace")
        for include in include_re.findall(source):
            child = local_include(path, include, name, headers)
            if child is not None and child not in found:
                pending.append(child)
    return headers.resolve(), [str(path) for path in sorted(found)], [root.resolve() for root in roots]


def declaration_source(node, header_root, header_paths, source_lines=None, token_patterns=None):
    """Return the SDK header that owns a declaration, including macro uses."""
    locations = []
    for key in ("range", "loc"):
        loc = node.get(key, {})
        if key == "range":
            loc = loc.get("begin", {})
        for subkey in ("expansionLoc", "spellingLoc"):
            if subkey in loc:
                locations.append(loc[subkey])
        locations.append(loc)
    for loc in locations:
        path = loc.get("file")
        if path:
            try:
                resolved = os.path.realpath(path)
                if os.path.commonpath((resolved, str(header_root))) == str(header_root) and resolved in header_paths:
                    return resolved
            except (OSError, ValueError):
                pass

    name = node.get("name")
    loc = node.get("loc", {})
    line = loc.get("line")
    column = loc.get("col")
    if name and line:
        candidates = []
        token = (token_patterns or {}).get(name)
        if token is None:
            token = re.compile(rf"(?<![A-Za-z0-9_]){re.escape(name)}(?![A-Za-z0-9_])")
            if token_patterns is not None:
                token_patterns[name] = token
        for path in header_paths:
            lines = (source_lines or {}).get(path)
            if lines is None:
                with open(path, errors="replace") as header_file:
                    lines = header_file.read().splitlines()
                if source_lines is not None:
                    source_lines[path] = lines
            if line <= len(lines) and token.search(lines[line - 1]):
                if not column or token.search(lines[line - 1][max(0, column - 1):]):
                    candidates.append(path)
        if len(candidates) == 1:
            return candidates[0]
    return None


def obsoleted_before_sdk(attr, sources):
    """Check whether an availability macro obsoletes this API in the current SDK."""
    begin = attr.get("range", {}).get("begin", {})
    spelling = begin.get("spellingLoc", begin)

    def source_at(location):
        path = location.get("file")
        if not path:
            return None, None
        source = sources.get(path)
        if source is None:
            try:
                source = Path(path).read_text(errors="replace")
            except OSError:
                return None, None
            sources[path] = source
        offset = location.get("offset")
        return source, offset if isinstance(offset, int) else None

    def version_tuple(value):
        if not re.fullmatch(r"\d+(?:\.\d+){0,2}", value.strip()):
            return None
        return tuple(int(part) for part in value.strip().split("."))

    definition_source, definition_offset = source_at(spelling)
    if definition_source is None or definition_offset is None:
        return False
    definition_text = definition_source[definition_offset:definition_offset + 400]
    obsolete = re.search(
        r"availability\s*\(\s*macos(?:x)?\s*,[^)]*\bobsoleted\s*=\s*([\w.]+)",
        definition_text,
    )
    obsolete_version = version_tuple(obsolete.group(1)) if obsolete else None

    if not obsolete_version and obsolete:
        parameter = obsolete.group(1)
        definitions = list(re.finditer(r"(?m)^\s*#\s*define\s+\w+\s*\(([^)]*)\)",
                                       definition_source[:definition_offset]))
        for macro in reversed(definitions):
            parameters = [value.strip() for value in macro.group(1).split(",")]
            if parameter not in parameters:
                continue
            body = definition_source[macro.end():definition_offset + 400]
            declaration = re.search(
                rf"availability\s*\(\s*macos(?:x)?\s*,[^)]*\bobsoleted\s*=\s*{re.escape(parameter)}\b",
                body,
            )
            if not declaration:
                continue
            expansion = begin.get("expansionLoc", begin)
            invocation_source, invocation_offset = source_at(expansion)
            if invocation_source is None or invocation_offset is None:
                return False
            line_end = invocation_source.find("\n", invocation_offset)
            if line_end < 0:
                line_end = len(invocation_source)
            invocation = re.match(r"\s*[A-Za-z_]\w*\s*\(([^)]*)\)",
                                  invocation_source[invocation_offset:line_end])
            if not invocation:
                return False
            arguments = [value.strip() for value in invocation.group(1).split(",")]
            obsolete_version = version_tuple(arguments[parameters.index(parameter)]) \
                if len(arguments) == len(parameters) else None
            break

    if not obsolete_version:
        return False
    target_version = version_tuple(macos_sdk_version())
    return target_version is not None and obsolete_version <= target_version


def unavailable_on_macos(node, sources, include_obsoleted=False):
    for attr in node.get("inner", []):
        kind = attr.get("kind")
        if kind == "UnavailableAttr":
            return True
        if kind != "AvailabilityAttr":
            continue
        if include_obsoleted and obsoleted_before_sdk(attr, sources):
            return True
        begin = attr.get("range", {}).get("begin", {})
        loc = begin.get("expansionLoc", begin.get("spellingLoc", begin))
        path, offset = loc.get("file"), loc.get("offset")
        if not path or offset is None:
            continue
        source = sources.get(path)
        if source is None:
            try:
                with open(path, errors="replace") as source_file:
                    source = source_file.read()
            except OSError:
                continue
            sources[path] = source
        snippet = source[offset:offset + 240]
        unavailable = re.search(r"API_UNAVAILABLE\s*\(([^)]*)\)", snippet)
        if unavailable and re.search(r"\bmacos(?:x)?\b", unavailable.group(1), re.I):
            return True
        if re.search(r"availability\s*\(\s*macos(?:x)?\s*,\s*unavailable\b", snippet, re.I):
            return True
    return False


def sdk_ast(name, framework_path=None):
    """Parse the public umbrella headers once and return the AST and header map."""
    sdk = sdk_path()
    framework = (Path(framework_path) if framework_path else
                 Path(sdk) / "System/Library/Frameworks" / f"{name}.framework")
    header_root, header_paths, roots = public_headers(Path(framework), name)
    version = macos_sdk_version()
    include_lines = []
    sdk_headers = Path(sdk) / "usr/include"
    for root in roots:
        try:
            include = f"{name}/{root.relative_to(header_root).as_posix()}"
        except ValueError:
            try:
                root.relative_to(sdk_headers)
            except ValueError as error:
                raise RuntimeError(f"umbrella header resolves outside the SDK's public headers: {root}") from error
            include = root.name
        include_lines.append(f"#include <{include}>")
    source = "\n".join(include_lines) + "\n"
    language = "objective-c++" if name == "DriverKit" else "objective-c"
    command = [
        "xcrun", "clang", "-target", f"arm64e-apple-macosx{version}", "-isysroot", sdk,
        "-F", str(framework.parent),
        "-F", os.path.join(sdk, "System/Library/Frameworks"),
        "-fblocks", "-fsyntax-only", "-x", language, "-Xclang", "-ast-dump=json", "-",
    ]
    parsed = subprocess.run(command, input=source, capture_output=True, text=True)
    if parsed.returncode:
        raise RuntimeError(f"Clang could not parse {name}'s SDK headers:\n{parsed.stderr.strip()}")
    ast = json.loads(parsed.stdout)
    return ast, header_root, header_paths


def sdk_declaration_records(name, framework_path=None, type_records=None):
    """Return public C declarations with their type and owning header."""
    ast, header_root, header_paths = sdk_ast(name, framework_path)
    sources = {}
    header_lines, token_patterns = {}, {}
    declarations = {}
    parsed_types = {}
    parsed_aliases = {}

    def collect_types(node):
        kind = node.get("kind")
        if kind in ("RecordDecl", "CXXRecordDecl") and node.get("completeDefinition"):
            fields = []
            for child in node.get("inner", []):
                if child.get("kind") != "FieldDecl":
                    continue
                fields.append({
                    "name": child.get("name"),
                    "type": child.get("type", {}).get("qualType"),
                    "desugared_type": child.get("type", {}).get("desugaredQualType"),
                    "bitfield": any(part.get("kind") == "ConstantExpr" for part in child.get("inner", [])),
                })
            record = {"id": node.get("id"), "name": node.get("name"),
                      "tag": node.get("tagUsed"), "fields": fields}
            if record["id"]:
                parsed_types[record["id"]] = record
            if record["name"]:
                parsed_types[record["name"]] = record
        elif kind == "TypedefDecl" and node.get("name"):
            alias_type = node.get("type", {}).get("qualType") or ""
            alias_desugared = node.get("type", {}).get("desugaredQualType") or ""
            tag_type = next((value for value in (alias_type, alias_desugared)
                             if re.fullmatch(r"\s*(?:(?:const|volatile)\s+)*(?:struct|union)\s+[A-Za-z_][A-Za-z0-9_]*\s*", value)), "")
            record_ids = set()
            if tag_type:
                def find_direct_record_ids(part):
                    if part.get("kind") == "RecordType":
                        record_id = part.get("decl", {}).get("id")
                        if record_id:
                            record_ids.add(record_id)
                    for child in part.get("inner", []):
                        find_direct_record_ids(child)

                for child in node.get("inner", []):
                    find_direct_record_ids(child)
            parsed_aliases[node["name"]] = {
                "type": alias_type,
                "desugared_type": alias_desugared,
                "record_ids": record_ids,
            }
        for child in node.get("inner", []):
            collect_types(child)

    collect_types(ast)
    for name, alias in parsed_aliases.items():
        target = next((parsed_types.get(record_id) for record_id in alias["record_ids"]
                       if parsed_types.get(record_id)), None)
        alias["record"] = target
        if target:
            target.setdefault("aliases", []).append(name)

    def walk(node, inside_function=False):
        kind = node.get("kind")
        if kind in ("FunctionDecl", "VarDecl") and not inside_function:
            symbol = node.get("mangledName")
            identifier = node.get("name", "")
            inline = node.get("inline") or any(child.get("kind") == "CompoundStmt" for child in node.get("inner", []))
            if (symbol and identifier and not identifier.startswith("_") and
                    node.get("storageClass") != "static" and not inline and
                    not unavailable_on_macos(node, sources)):
                path = declaration_source(node, header_root, header_paths, header_lines, token_patterns)
                if path:
                    relative = os.path.relpath(path, header_root)
                    declarations.setdefault(symbol, {})[(kind, relative)] = {
                        "symbol": symbol,
                        "name": identifier,
                        "kind": kind,
                        "type": node.get("type", {}).get("qualType"),
                        "desugared_type": node.get("type", {}).get("desugaredQualType"),
                        "header": relative,
                    }
        nested = inside_function or kind in ("FunctionDecl", "BlockDecl", "ObjCMethodDecl")
        for child in node.get("inner", []):
            walk(child, nested)

    walk(ast)
    if type_records is not None:
        used_records = {}
        used_aliases = {}

        def collect_used_types(type_value):
            if not type_value:
                return
            for identifier in re.findall(r"[A-Za-z_][A-Za-z0-9_]*", type_value):
                alias = parsed_aliases.get(identifier)
                if not alias:
                    record = parsed_types.get(identifier)
                    if record:
                        used_records[record["id"]] = record
                    continue
                used_aliases[identifier] = alias
                if alias["record"]:
                    used_records[alias["record"]["id"]] = alias["record"]

        for records in declarations.values():
            for declaration in records.values():
                if declaration["kind"] == "VarDecl":
                    collect_used_types(declaration.get("type"))
                    collect_used_types(declaration.get("desugared_type"))

        pending = list(used_records.values())
        while pending:
            record = pending.pop()
            for field in record["fields"]:
                for type_value in (field.get("type"), field.get("desugared_type")):
                    before = set(used_records)
                    collect_used_types(type_value)
                    pending.extend(used_records[key] for key in set(used_records) - before)

        for record in used_records.values():
            if record.get("name"):
                type_records[record["name"]] = record
            for alias in record.get("aliases", []):
                type_records[alias] = record
        type_records["__aliases__"] = {
            name: {key: value for key, value in alias.items()
                   if key not in ("record", "record_ids")}
            for name, alias in used_aliases.items() if not alias["record"]
        }
    return {symbol: sorted(records.values(), key=lambda item: item["header"])
            for symbol, records in declarations.items()}


def sdk_declarations(name, framework_path=None):
    ast, header_root, header_paths = sdk_ast(name, framework_path)
    sources = {}
    header_lines, token_patterns = {}, {}
    declarations = {}

    def walk(node, inside_function=False):
        kind = node.get("kind")
        if kind in ("FunctionDecl", "VarDecl") and not inside_function:
            symbol = node.get("mangledName")
            identifier = node.get("name", "")
            inline = node.get("inline") or any(child.get("kind") == "CompoundStmt" for child in node.get("inner", []))
            if (symbol and identifier and not identifier.startswith("_") and
                    node.get("storageClass") != "static" and not inline and
                    not unavailable_on_macos(node, sources)):
                path = declaration_source(node, header_root, header_paths, header_lines, token_patterns)
                if path:
                    relative = os.path.relpath(path, header_root)
                    declarations.setdefault(symbol, set()).add(relative)
        nested = inside_function or kind in ("FunctionDecl", "BlockDecl", "ObjCMethodDecl")
        for child in node.get("inner", []):
            walk(child, nested)

    walk(ast)
    return {symbol: sorted(headers)[0] for symbol, headers in declarations.items()}


def sdk_declaration_details(name, framework_path=None):
    """Return public C and Objective-C declaration signatures from the same SDK AST."""
    ast, header_root, header_paths = sdk_ast(name, framework_path)
    sources = {}
    header_lines = {path: Path(path).read_text(errors="replace").splitlines() for path in header_paths}
    functions = {}
    variables = {}
    methods = {}
    enum_values = []

    def parameter(node):
        type_info = node.get("type", {})
        qual_type = type_info.get("qualType", "")
        attrs = {attr.get("kind", "") for attr in node.get("inner", [])}
        return {
            "name": node.get("name", ""),
            "type": qual_type,
            "desugared_type": type_info.get("desugaredQualType", qual_type),
            "nullable": bool(re.search(r"\b_Nullable\b|\bnullable\b", qual_type, re.I) or
                               "NullableAttr" in attrs),
            "nonnull": bool(re.search(r"\b_Nonnull\b|\bnonnull\b", qual_type, re.I) or
                             "NonNullAttr" in attrs),
            "direction": "inout" if attrs & {"InOutAttr", "ObjCInOutAttr"} else
                        "out" if attrs & {"OutAttr", "ObjCOutAttr"} else
                        "in" if attrs & {"InAttr", "ObjCInAttr"} else "unspecified",
        }

    def constant_value(node):
        for child in node.get("inner", []):
            if "value" in child:
                return child["value"]
            value = constant_value(child)
            if value is not None:
                return value
        return None

    def walk(node, class_name=None, class_header=None, enum_name=None, inside_function=False):
        kind = node.get("kind")
        current_class = class_name
        current_header = class_header
        if kind in ("ObjCInterfaceDecl", "ObjCCategoryDecl", "ObjCCategoryImplDecl"):
            current_class = node.get("interface", {}).get("name") or node.get("name") or class_name
            current_header = declaration_source(node, header_root, header_paths, header_lines) or class_header

        if kind in ("FunctionDecl", "VarDecl") and not inside_function:
            symbol = node.get("mangledName")
            identifier = node.get("name", "")
            inline = node.get("inline") or any(child.get("kind") == "CompoundStmt" for child in node.get("inner", []))
            if (symbol and identifier and not identifier.startswith("_") and
                    (node.get("storageClass") != "static" or inline) and
                    not unavailable_on_macos(node, sources, include_obsoleted=True)):
                path = declaration_source(node, header_root, header_paths, header_lines)
                if path:
                    relative = os.path.relpath(path, header_root)
                    type_info = node.get("type", {})
                    qual_type = type_info.get("qualType", "")
                    if kind == "FunctionDecl":
                        # A C function's AST type is "return-type (parameters...)".
                        # Keep pointer returns intact; pointer-to-function returns are
                        # intentionally left for the generator to reject as unsupported.
                        result_type = qual_type.split("(", 1)[0].strip()
                        params = [parameter(child) for child in node.get("inner", [])
                                  if child.get("kind") == "ParmVarDecl"]
                        functions.setdefault(symbol, {
                            "name": identifier, "symbol": symbol, "header": relative,
                            "type": qual_type, "return_type": result_type, "parameters": params,
                            "variadic": bool(node.get("variadic")) or
                                        any(child.get("kind") in ("...", "VariadicParamDecl") for child in node.get("inner", [])),
                            "inline": bool(inline),
                        })
                    elif node.get("storageClass") != "static":
                        variables.setdefault(symbol, {
                            "name": identifier, "symbol": symbol, "header": relative,
                            "type": qual_type,
                            "desugared_type": type_info.get("desugaredQualType", qual_type),
                        })

        if kind == "ObjCMethodDecl" and current_class and not unavailable_on_macos(
                node, sources, include_obsoleted=True):
            path = declaration_source(node, header_root, header_paths, header_lines) or current_header
            selector = node.get("name", "")
            if path and selector:
                params = [parameter(child) for child in node.get("inner", [])
                          if child.get("kind") == "ParmVarDecl"]
                return_info = node.get("returnType", node.get("type", {}))
                method = {
                    "class": current_class,
                    "selector": selector,
                    "class_method": not bool(node.get("instance", True)),
                    "return_type": return_info.get("qualType", ""),
                    "parameters": params,
                    "header": os.path.relpath(path, header_root),
                    "variadic": bool(node.get("variadic")),
                }
                key = f"{current_class} {'+' if method['class_method'] else '-'}{selector}"
                methods.setdefault(key, method)

        if kind == "ObjCPropertyDecl" and current_class:
            path = declaration_source(node, header_root, header_paths, header_lines) or current_header
            if path:
                property_name = node.get("name", "")
                property_type = node.get("type", {}).get("qualType", "")
                attrs = set(node.get("propertyAttributes", []))
                class_method = "class" in attrs
                prefix = "+" if class_method else "-"
                getter = node.get("getter", {}).get("name") or property_name
                setter = node.get("setter", {}).get("name") or f"set{property_name[:1].upper()}{property_name[1:]}:"
                key = f"{current_class} {prefix}{getter}"
                methods.setdefault(key, {
                    "class": current_class, "selector": getter, "class_method": class_method,
                    "return_type": property_type, "parameters": [],
                    "header": os.path.relpath(path, header_root),
                })
                if "readonly" not in attrs:
                    key = f"{current_class} {prefix}{setter}"
                    methods.setdefault(key, {
                        "class": current_class, "selector": setter, "class_method": class_method,
                        "return_type": "void", "parameters": [
                            {"name": property_name, "type": property_type,
                             "desugared_type": property_type, "nullable": False, "nonnull": False}
                        ], "header": os.path.relpath(path, header_root),
                    })

        if kind == "EnumDecl":
            enum_name = node.get("name") or enum_name
        if kind == "EnumConstantDecl":
            path = declaration_source(node, header_root, header_paths, header_lines)
            value = constant_value(node)
            if path and value is not None:
                enum_values.append({
                    "name": node.get("name", ""), "enum": enum_name or "",
                    "value": value, "header": os.path.relpath(path, header_root),
                })

        nested = inside_function or kind in ("FunctionDecl", "BlockDecl", "ObjCMethodDecl")
        for child in node.get("inner", []):
            walk(child, current_class, current_header, enum_name, nested)

    walk(ast)
    return {
        "functions": sorted(functions.values(), key=lambda item: item["name"]),
        "variables": sorted(variables.values(), key=lambda item: item["name"]),
        "methods": methods,
        "enum_values": enum_values,
    }


def finch_exports(name):
    binary = os.path.join(FRAMEWORKS, f"{name}.framework", name)
    if not os.path.isfile(binary):
        raise FileNotFoundError(f"Finch's built framework binary was not found: {binary}")
    output = run(["nm", "-gU", "-arch", "arm64e", binary])
    return {line.split()[-1] for line in output.splitlines() if line.split()}


def main(argv):
    if len(argv) != 2 or argv[1].startswith("-"):
        print("usage: tools/c-api-audit.py FRAMEWORK", file=sys.stderr)
        return 2
    name = argv[1]
    try:
        declarations = sdk_declarations(name)
        exports = finch_exports(name)
    except (FileNotFoundError, RuntimeError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        return 2

    missing = sorted(set(declarations) - exports)
    groups = {}
    for symbol in missing:
        groups.setdefault(declarations[symbol], []).append(symbol)
    for header, symbols in sorted(groups.items()):
        print(f"{header}:")
        for symbol in symbols:
            print(f"  {symbol[1:] if symbol.startswith('_') else symbol}")
    exported = len(set(declarations) & exports)
    print(f"{name}: {len(declarations)} public C functions/variables; {exported} exported; {len(missing)} missing")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
