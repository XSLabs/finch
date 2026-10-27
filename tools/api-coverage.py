#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Measure Finch's public API coverage against the installed macOS SDK.

    tools/api-coverage.py [--markdown] [--json] [--missing FRAMEWORK]

The SDK is read at run time. Per-framework API manifests are cached under build/;
the generated Markdown contains counts only, while the JSON report stays in build/.
"""
import argparse
import bisect
import contextlib
import datetime
import hashlib
import importlib.util
import io
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILD_ROOT = ROOT / "build/root"
SDK_CACHE = ROOT / "build/api-coverage-cache"
REPORT_JSON = ROOT / "build/api-coverage.json"
APP_SWEEP_CACHE = ROOT / "build/api-coverage-app-sweep.json"
REPORT_MARKDOWN = ROOT / "docs/COMPATIBILITY.md"
RESPONDER_SOURCE = ROOT / "tools/api-audit/responds.m"
RESPONDER = ROOT / "build/tools/api-coverage-responds"
CACHE_SCHEMA = 4
OBJC_FILTER_SCHEMA = 1
_RUNTIME_IDENTITY_UNSET = object()
TARGET = "arm64e-apple-macosx"
SWIFT_DECL_KINDS = {
    "Func", "Var", "Constructor", "Destructor", "TypeAlias", "Struct",
    "Enum", "Class", "Protocol", "Subscript", "EnumElement", "AssociatedType",
}


def command(args, **kwargs):
    return subprocess.run(args, capture_output=True, text=True, **kwargs)


def output(args):
    result = command(args, check=True)
    return result.stdout.strip()


def load_tool(relative, module_name):
    spec = importlib.util.spec_from_file_location(module_name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def strip_comments(text):
    def blank(match):
        return re.sub(r"[^\n]", " ", match.group(0))
    text = re.sub(r"/\*.*?\*/", blank, text, flags=re.S)
    return re.sub(r"//[^\n]*", blank, text)


def unavailable_on_macos(text):
    if re.search(r"\bNS_UNAVAILABLE\b|__attribute__\s*\(\(\s*unavailable\b", text):
        return True
    for macro in re.findall(r"\bAPI_UNAVAILABLE\s*\(([^)]*)\)", text):
        if re.search(r"\bmacos(?:x)?\b", macro, re.I):
            return True
    for macro in re.findall(r"\bAPI_DEPRECATED(?:_WITH_REPLACEMENT)?\s*\(([^)]*)\)", text):
        if re.search(r"\bmacos(?:x)?\s*\([^)]*\bunavailable\b", macro, re.I):
            return True
    return bool(re.search(r"availability\s*\(\s*macos(?:x)?\s*,\s*unavailable\b", text, re.I))


def unavailable_regions(text):
    regions, stack = [], []
    pattern = re.compile(r"\bAPI_UNAVAILABLE_BEGIN\s*\(([^)]*)\)|\bAPI_UNAVAILABLE_END\b")
    for match in pattern.finditer(text):
        if match.group(1) is not None:
            stack.append((match.start(), bool(re.search(r"\bmacos(?:x)?\b", match.group(1), re.I))))
        elif stack:
            start, unavailable = stack.pop()
            if unavailable:
                regions.append((start, match.end()))
    for start, unavailable in stack:
        if unavailable:
            regions.append((start, len(text)))
    return regions


def in_unavailable_region(offset, regions):
    return any(start <= offset < end for start, end in regions)


def is_spi(text):
    return bool(re.search(r"\b(?:API_SPI|NS_SPI|_SPI|SPI_AVAILABLE|SPI_REQUIRES)\w*\b", text))


def declaration_context(source, start, end):
    line_start = source.rfind("\n", 0, start) + 1
    line_end = source.find("\n", end)
    if line_end < 0:
        line_end = len(source)
    context = source[line_start:line_end]
    previous_end = line_start - 1
    previous_start = source.rfind("\n", 0, max(0, previous_end)) + 1
    previous = source[previous_start:previous_end].strip()
    if previous and ";" not in previous and re.search(
            r"API_UNAVAILABLE|API_DEPRECATED|availability\s*\(|API_SPI|SPI_AVAILABLE|SPI_REQUIRES", previous):
        context = previous + "\n" + context
    return context


def objc_selector(signature):
    """Build an Objective-C selector without mistaking an argument name for a label."""
    first = re.match(r"\s*([A-Za-z_]\w*)", signature)
    if not first:
        return None
    selector = first.group(1)
    pos = first.end()
    if pos >= len(signature) or signature[pos] != ":":
        return selector
    selector += ":"
    pos += 1

    while pos < len(signature):
        while pos < len(signature) and signature[pos].isspace():
            pos += 1
        if pos >= len(signature) or signature[pos] != "(":
            break
        depth, end = 1, pos + 1
        while end < len(signature) and depth:
            if signature[end] == "(":
                depth += 1
            elif signature[end] == ")":
                depth -= 1
            end += 1
        if depth:
            break
        pos = end
        while pos < len(signature) and signature[pos].isspace():
            pos += 1
        argument = re.match(r"[A-Za-z_]\w*", signature[pos:])
        if not argument:
            break
        pos += argument.end()
        while pos < len(signature) and signature[pos].isspace():
            pos += 1
        if pos < len(signature) and signature[pos] == ":":
            selector += ":"
            pos += 1
            continue
        label = re.match(r"([A-Za-z_]\w*)\s*:", signature[pos:])
        if not label:
            break
        selector += label.group(1) + ":"
        pos += label.end()
    return selector


def objc_items(framework):
    """Read public Objective-C interfaces, categories, methods, and properties."""
    headers = framework / "Headers"
    items = {}
    excluded_classes, available_classes = set(), set()
    sources = sorted(headers.rglob("*.h")) if headers.is_dir() else []
    for path in sources:
        try:
            original = path.read_text(errors="replace")
        except OSError as error:
            raise RuntimeError(f"could not read {path.name}: {error}") from error
        source = strip_comments(original)
        unavailable = unavailable_regions(source)
        starts = list(re.finditer(r"@(interface|protocol)\s+([A-Za-z_]\w*)\b", source))
        for index, start in enumerate(starts):
            end = source.find("@end", start.end())
            next_start = starts[index + 1].start() if index + 1 < len(starts) else len(source)
            if end < 0 or next_start < end:
                continue
            kind, owner = start.group(1), start.group(2)
            block_end = end + len("@end")
            block = source[start.start():block_end]
            header_end = source.find("\n", start.start())
            if header_end < 0 or header_end > end:
                header_end = end
            header = original[start.start():header_end]
            context = declaration_context(original, start.start(), header_end)
            unavailable_here = (in_unavailable_region(start.start(), unavailable) or
                                unavailable_on_macos(header + "\n" + context) or
                                is_spi(header + "\n" + context))
            is_category = kind == "interface" and source[start.end():header_end].lstrip().startswith("(")
            if kind == "interface" and not is_category and not owner.startswith("_"):
                if unavailable_here:
                    excluded_classes.add(owner)
                else:
                    available_classes.add(owner)
            if not unavailable_here and not owner.startswith("_"):
                if kind == "protocol":
                    item_id = f"objc-protocol:{owner}"
                    items[item_id] = {"id": item_id, "kind": "objc protocol", "name": owner,
                                      "check": {"type": "protocol", "name": owner}}
                elif not is_category:
                    item_id = f"objc-class:{owner}"
                    items[item_id] = {"id": item_id, "kind": "objc class", "name": owner,
                                      "check": {"type": "class", "name": owner}}

            for match in re.finditer(r"^[ \t]*([-+])\s*\(([^;]*?)\)\s*([^;]+?);", block, re.M):
                context = declaration_context(original, start.start() + match.start(), start.start() + match.end())
                if (in_unavailable_region(start.start() + match.start(), unavailable) or
                        unavailable_here or
                        unavailable_on_macos(context) or is_spi(context)):
                    continue
                signature = re.sub(
                    r"\b(?:NS_|API_|__|FOUNDATION_|CF_|DEPRECATED|APPKIT_)\w*"
                    r"(\([^()]*(\([^()]*\))*[^()]*\))?", "", match.group(3))
                selector = objc_selector(signature)
                if not selector:
                    continue
                owner_kind = "protocol" if kind == "protocol" else "class"
                item_id = f"objc-{owner_kind}-method:{owner}:{match.group(1)}{selector}"
                check = {"type": "protocol method" if kind == "protocol" else "method",
                         "name": owner, "selector": match.group(1) + selector}
                items[item_id] = {"id": item_id, "kind": "objc method", "name": f"{owner} {match.group(1)}{selector}",
                                  "check": check}

            for match in re.finditer(r"@property\s*(\(([^)]*)\))?([^;]*);", block, re.S):
                context = declaration_context(original, start.start() + match.start(), start.start() + match.end())
                if (in_unavailable_region(start.start() + match.start(), unavailable) or
                        unavailable_here or
                        unavailable_on_macos(context) or is_spi(context)):
                    continue
                declaration = re.sub(
                    r"\b(?:NS_|API_|__|FOUNDATION_|CF_|DEPRECATED|APPKIT_)\w*"
                    r"(\([^()]*(\([^()]*\))*[^()]*\))?", "", match.group(3)).strip()
                name_match = re.search(r"([A-Za-z_]\w*)\s*$", declaration)
                if not name_match:
                    continue
                property_name = name_match.group(1)
                attrs = match.group(2) or ""
                getter = re.search(r"\bgetter\s*=\s*([A-Za-z_]\w*)", attrs)
                setter = re.search(r"\bsetter\s*=\s*([A-Za-z_]\w*:)\s*", attrs)
                getter_name = getter.group(1) if getter else property_name
                read_only = bool(re.search(r"\breadonly\b", attrs))
                setter_name = setter.group(1) if setter else ("set" + property_name[:1].upper() + property_name[1:] + ":")
                owner_kind = "protocol" if kind == "protocol" else "class"
                item_id = f"objc-{owner_kind}-property:{owner}:{property_name}"
                selector_prefix = "+" if re.search(r"\bclass\b", attrs) else "-"
                check = {"type": "protocol property" if kind == "protocol" else "property",
                         "name": owner, "property": property_name,
                         "getter": selector_prefix + getter_name,
                         "setter": None if read_only else selector_prefix + setter_name}
                items[item_id] = {"id": item_id, "kind": "objc property", "name": f"{owner} {property_name}",
                                  "check": check}
    excluded_classes -= available_classes
    for item_id, item in list(items.items()):
        if (item_id.startswith(("objc-class-method:", "objc-class-property:")) and
                item["check"]["name"] in excluded_classes):
            del items[item_id]
    return list(items.values()), [str(path) for path in sources], excluded_classes


def tbd_strings(raw):
    result = []
    for single, double, bare in re.findall(r"'([^']*)'|\"([^\"]*)\"|([^,\s]+)", raw):
        value = single or double or bare
        if value:
            result.append(value.strip())
    return result


def tbd_exports(path):
    """Read arm64e macOS exports from a text-based SDK stub (TAPI .tbd)."""
    text = path.read_text(errors="replace")
    docs = re.split(r"(?m)^--- !tapi-tbd\s*$", text)
    if len(docs) < 2:
        raise RuntimeError(f"{path.name} is not a TAPI stub")
    document = docs[1]
    top_targets = re.search(r"(?m)^targets:\s*\[([^]]*)\]", document)
    if not top_targets:
        raise RuntimeError(f"{path.name} has no target list")
    exports, objc_classes, reexports = set(), set(), set()
    if "arm64e-macos" not in top_targets.group(1):
        return {"symbols": [], "classes": [], "libraries": [], "install_name": None}
    install = re.search(r"(?m)^install-name:\s*['\"]?([^'\"\n]+)", document)
    install_name = install.group(1).strip() if install else None
    section = re.search(r"(?ms)^exports:\s*\n(.*?)(?=^[^ \t#\n]|\Z)", document)
    if section:
        body = section.group(1)
        entries = re.finditer(
            r"(?ms)^\s{2}-\s+targets:\s*\[([^]]*)\][ \t]*\n(.*?)(?=^\s{2}-\s+targets:|^[^ \t#\n]|\Z)", body)
        for entry in entries:
            if "arm64e-macos" not in entry.group(1):
                continue
            for key, raw in re.findall(r"(?ms)^\s{4,}([\w-]+):\s*\[([^]]*)\]", entry.group(2)):
                values = tbd_strings(raw)
                if key in ("symbols", "weak-symbols", "thread-local-symbols"):
                    exports.update(values)
                elif key == "objc-classes":
                    objc_classes.update(values)
    else:
        # Older SDK stubs put target-specific export groups directly below targets.
        old_blocks = re.finditer(r"(?ms)^\s{2,}-\s+targets:\s*\[([^]]*)\][ \t]*\n(.*?)(?=^\s{2,}-\s+targets:|^[^ \t#\n]|\Z)", document)
        for entry in old_blocks:
            if "arm64e-macos" not in entry.group(1):
                continue
            for key, raw in re.findall(r"(?ms)^\s{4,}([\w-]+):\s*\[([^]]*)\]", entry.group(2)):
                values = tbd_strings(raw)
                if key in ("symbols", "weak-symbols", "thread-local-symbols"):
                    exports.update(values)
                elif key == "objc-classes":
                    objc_classes.update(values)

    reexport_section = re.search(
        r"(?ms)^reexported-libraries:\s*\n(.*?)(?=^[^ \t#\n]|\Z)", document)
    if reexport_section:
        for entry in re.finditer(
                r"(?ms)^\s{2}-\s+targets:\s*\[([^]]*)\][ \t]*\n(.*?)(?=^\s{2}-\s+targets:|^[^ \t#\n]|\Z)",
                reexport_section.group(1)):
            if "arm64e-macos" not in entry.group(1):
                continue
            for raw in re.findall(r"(?m)^\s{4,}libraries:\s*\[([^]]*)\]", entry.group(2)):
                reexports.update(tbd_strings(raw))
    return {"symbols": sorted(exports), "classes": sorted(objc_classes),
            "libraries": sorted(reexports), "install_name": install_name}


def tbd_path_for_install(sdk, install_name):
    if not install_name or not install_name.startswith("/"):
        return None
    candidate = (Path(sdk) / install_name.lstrip("/")).with_suffix(".tbd")
    return candidate if candidate.is_file() else None


def resolve_reexports(specs, sdk):
    """Connect public TAPI re-exports to the framework or dylib they name."""
    by_install = {}
    by_id = {spec["id"]: spec for spec in specs}
    for spec in specs:
        spec["tbd_data"] = None
        spec["reexport_ids"] = []
        spec["reexport_errors"] = []
        if not spec.get("tbd"):
            continue
        try:
            spec["tbd_data"] = tbd_exports(spec["tbd"])
        except (OSError, RuntimeError):
            continue
        install = spec["tbd_data"].get("install_name")
        if install:
            by_install[install] = spec

    for spec in specs:
        data = spec.get("tbd_data") or {}
        for library in data.get("libraries", []):
            child = by_install.get(library)
            if child:
                spec["reexport_ids"].append(child["id"])
                continue
            if "PrivateFrameworks/" in library or "/_" in library:
                continue
            candidate = tbd_path_for_install(sdk, library)
            if candidate:
                child = None
                framework_root = Path(sdk) / "System/Library/Frameworks"
                owner = next((path for path in candidate.parents if path.name.endswith(".framework")), None)
                if owner and not library.endswith(".dylib"):
                    child = framework_spec(owner, framework_root, candidate)
                elif owner:
                    child = dylib_spec(candidate, Path(sdk))
                else:
                    child = dylib_spec(candidate, Path(sdk))
                if child:
                    known = by_id.get(child["id"])
                    if known:
                        child = known
                    else:
                        child["tbd_data"] = None
                        child["reexport_ids"] = []
                        child["reexport_errors"] = []
                        try:
                            child["tbd_data"] = tbd_exports(child["tbd"])
                        except (OSError, RuntimeError) as error:
                            child["reexport_errors"].append(f"TAPI export list: {error}")
                        specs.append(child)
                        by_id[child["id"]] = child
                    by_install[library] = child
                    if child["id"] not in spec["reexport_ids"]:
                        spec["reexport_ids"].append(child["id"])
                else:
                    spec["reexport_errors"].append(
                        f"TAPI re-export {library} is not in the public SDK inventory")
            else:
                spec["reexport_errors"].append(
                    f"TAPI re-export could not be found in the SDK: {library}")


def public_c_symbol(symbol):
    if not symbol.startswith("_") or symbol.startswith(("__", "_$s", "_$S", "_OBJC_", "_symbolic")):
        return False
    return not symbol.startswith(("$ld$", "R8289209$"))


def cache_name(name):
    safe = re.sub(r"[^A-Za-z0-9_.-]", "_", name)
    digest = hashlib.sha256(name.encode()).hexdigest()[:10]
    return SDK_CACHE / f"{safe}-{digest}.json"


def input_fingerprint(paths, sdk_version, schema=CACHE_SCHEMA):
    rows = []
    for path in sorted(set(Path(p) for p in paths)):
        try:
            stat = path.stat()
        except OSError:
            rows.append((str(path), None, None))
        else:
            rows.append((str(path), stat.st_size, stat.st_mtime_ns))
    return hashlib.sha256(json.dumps([schema, sdk_version, TARGET, rows]).encode()).hexdigest()


def has_filtered_objc_interfaces(spec):
    """Whether an interface or category has a class-level macOS/SPI filter."""
    headers = spec["sdk_path"] / "Headers"
    if not headers.is_dir():
        return False
    for path in headers.rglob("*.h"):
        source = strip_comments(path.read_text(errors="replace"))
        for start in re.finditer(r"@interface\s+([A-Za-z_]\w*)\b", source):
            end = source.find("@end", start.end())
            header_end = source.find("\n", start.start())
            if header_end < 0 or (end >= 0 and header_end > end):
                header_end = end if end >= 0 else len(source)
            if header_end < 0:
                continue
            header = source[start.start():header_end]
            context = declaration_context(source, start.start(), header_end)
            if (unavailable_on_macos(header + "\n" + context) or
                    is_spi(header + "\n" + context)):
                return True
    return False


def add_item(items, item_id, kind, name, check):
    items[item_id] = {"id": item_id, "kind": kind, "name": name, "check": check}


def swift_nodes(root, module_name):
    found = {}
    def walk(node):
        if isinstance(node, dict):
            kind = node.get("declKind")
            attrs = node.get("declAttributes", [])
            if (kind in SWIFT_DECL_KINDS and node.get("usr") and
                    not any(a in attrs for a in ("SPI", "SPIAccessControl", "Unavailable", "Hidden")) and
                    not node.get("name", "").startswith("_") and
                    (node.get("moduleName") in (None, module_name))):
                usr = node["usr"]
                mangled = node.get("mangledName", "")
                if usr.startswith("s:") or mangled.startswith(("$s", "$S")):
                    item_id = "swift:" + usr
                    check = {"type": "swift", "usr": usr, "mangled": mangled,
                             "kind": kind, "protocol_req": bool(node.get("protocolReq")),
                             "accessors": []}
                    for accessor in node.get("accessors", []):
                        symbol = accessor.get("mangledName")
                        if symbol:
                            check["accessors"].append(symbol)
                    label = node.get("printedName") or node.get("name") or usr
                    found[item_id] = {"id": item_id, "kind": "swift", "name": label, "check": check}
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)
    walk(root)
    return list(found.values())


def digester_dump(module, sdk, target, output_path, include_path=None, force_interface=False):
    cmd = ["xcrun", "swift-api-digester", "-dump-sdk", "-module", module,
           "-sdk", str(sdk), "-target", target,
           "-F", str(sdk / "System/Library/Frameworks"), "-avoid-location"]
    if include_path:
        include_paths = include_path if isinstance(include_path, (list, tuple)) else [include_path]
        for path in include_paths:
            cmd += ["-I", str(path)]
    if force_interface:
        cmd += ["-use-interface-for-module", module]
    cmd += ["-o", str(output_path)]
    result = command(cmd)
    if result.returncode:
        raise RuntimeError((result.stderr or result.stdout).strip()[-1800:])
    try:
        document = json.loads(output_path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError(f"swift-api-digester did not write usable JSON: {error}") from error
    root = document.get("ABIRoot", {})
    if root.get("name") != module:
        detail = (result.stderr or result.stdout).strip()
        raise RuntimeError((detail or f"digester loaded {root.get('name') or 'no module'} instead of {module}")[-1800:])
    return root


def framework_inputs(spec):
    path = spec["sdk_path"]
    inputs = [path]
    headers = path / "Headers"
    if headers.is_dir():
        inputs.extend(headers.rglob("*.h"))
    inputs.extend(path.glob("Modules/module.modulemap"))
    inputs.extend(path.glob("module.modulemap"))
    inputs.extend(spec.get("swift_interfaces", []))
    if spec.get("swift_binary"):
        inputs.append(spec["swift_binary"])
    if spec.get("tbd"):
        inputs.append(spec["tbd"])
    return inputs


def stage_module_files(root, spec, files):
    module = spec.get("module", spec["name"])
    include_path = root / cache_name(spec["id"]).stem
    module_dir = include_path / f"{module}.swiftmodule"
    module_dir.mkdir(parents=True, exist_ok=True)
    for source in files:
        link = module_dir / source.name
        try:
            if link.is_symlink() or link.exists():
                link.unlink()
            link.symlink_to(source.resolve())
        except OSError:
            link.write_bytes(source.read_bytes())
    return include_path


def prepare_sdk_modules(specs):
    root = ROOT / "build/api-coverage/sdk-modules"
    for spec in specs:
        interface = spec.get("swift_interfaces", [])
        binary = spec.get("swift_binary")
        if interface:
            files = interface[:1]
        elif binary:
            files = sorted(binary.parent.glob("arm64e-apple-macos.*"))
            if binary not in files:
                files.append(binary)
        else:
            continue
        spec["sdk_swift_include"] = stage_module_files(root, spec, files)


def parse_sdk_api(spec, ctx, force=False):
    name = spec.get("module", spec["name"])
    cached = cache_name(spec["id"])
    schema = [CACHE_SCHEMA, OBJC_FILTER_SCHEMA] if (
        spec["kind"] == "framework" and has_filtered_objc_interfaces(spec)) else CACHE_SCHEMA
    fingerprint = input_fingerprint(framework_inputs(spec), ctx["sdk_version"], schema)
    if not force and cached.is_file():
        try:
            data = json.loads(cached.read_text())
            if data.get("fingerprint") == fingerprint and spec["name"] != "DriverKit":
                if spec["kind"] == "dylib":
                    filtered = [error for error in data["errors"]
                                if error != "TAPI lists Swift exports, but no SDK Swift module or interface was found"]
                    if filtered != data["errors"]:
                        data["errors"] = filtered
                        cached.write_text(json.dumps(data, sort_keys=True, separators=(",", ":")))
                return data["items"], data["errors"], data["sources"]
        except (OSError, json.JSONDecodeError, KeyError):
            pass

    items = {}
    errors, sources = [], []
    exports = None
    if spec.get("tbd"):
        try:
            exports = spec.get("tbd_data") or tbd_exports(spec["tbd"])
            sources.append("TAPI export list")
        except (OSError, RuntimeError) as error:
            errors.append(f"TAPI export list: {error}")

    has_headers = spec["kind"] == "framework" and any((spec["sdk_path"] / "Headers").rglob("*.h"))
    excluded_objc_classes = set()
    if has_headers:
        c_audit = ctx["c_audit"]
        try:
            c_declarations = c_audit.sdk_declarations(name, spec["sdk_path"])
            sources.append("public C header declarations")
            c_symbols = set(c_declarations)
            if exports is not None:
                apple_symbols = {symbol for symbol in exports["symbols"] if public_c_symbol(symbol)}
                c_symbols &= apple_symbols
            for symbol in sorted(c_symbols):
                add_item(items, "c:" + symbol, "C symbol", symbol[1:] if symbol.startswith("_") else symbol,
                         {"type": "symbol", "symbol": symbol})
        except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
            errors.append(f"C headers: {error}")

        try:
            declarations, header_paths, excluded_objc_classes = objc_items(spec["sdk_path"])
            sources.append("public Objective-C headers")
            for item in declarations:
                items[item["id"]] = item
            spec["header_paths"] = header_paths
        except (OSError, RuntimeError) as error:
            errors.append(f"Objective-C headers: {error}")

    if not has_headers and exports is not None:
        sources.append("public dylib export list")
        for symbol in exports["symbols"]:
            if public_c_symbol(symbol):
                add_item(items, "c:" + symbol, "C symbol", symbol[1:],
                         {"type": "symbol", "symbol": symbol})

    if exports is not None:
        for class_name in exports["classes"]:
            if class_name.startswith("_") or class_name in excluded_objc_classes:
                continue
            item_id = "objc-class:" + class_name
            add_item(items, item_id, "objc class", class_name,
                     {"type": "class", "name": class_name})

    if spec.get("swift_interfaces") or spec.get("swift_binary"):
        interface = (spec["swift_interfaces"][0] if spec.get("swift_interfaces")
                     else spec["swift_binary"])
        try:
            with tempfile.NamedTemporaryFile(prefix="sdk-", suffix=".json", dir=SDK_CACHE, delete=False) as temp:
                dump_path = Path(temp.name)
            try:
                root = digester_dump(name, ctx["sdk"], ctx["target"], dump_path,
                                     include_path=spec.get("sdk_swift_include"),
                                     force_interface=bool(spec.get("swift_interfaces")))
            finally:
                dump_path.unlink(missing_ok=True)
            for item in swift_nodes(root, name):
                items[item["id"]] = item
            sources.append("Swift API digester")
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            errors.append(f"Swift interface {interface.name}: {error}")

    has_swift_exports = bool(exports and any(
        symbol.startswith(("_$s", "_$S", "_symbolic")) for symbol in exports["symbols"]))
    if (spec["kind"] == "framework" and has_swift_exports and
            not (spec.get("swift_interfaces") or spec.get("swift_binary"))):
        errors.append("TAPI lists Swift exports, but no SDK Swift module or interface was found")

    if not sources:
        errors.append("no public headers, Swift interface, or export list was found")
    data = {"fingerprint": fingerprint, "items": list(items.values()), "errors": errors, "sources": sources}
    cached.parent.mkdir(parents=True, exist_ok=True)
    cached.write_text(json.dumps(data, sort_keys=True, separators=(",", ":")))
    return data["items"], errors, sources


def merged_sdk_manifest(spec_id, specs_by_id, manifests, memo, active=None):
    """Add the public APIs a framework exposes through its TAPI re-exports."""
    if spec_id in memo:
        return memo[spec_id]
    active = set() if active is None else set(active)
    if spec_id in active:
        return [], [f"TAPI re-export cycle includes {spec_id}"], []
    spec = specs_by_id[spec_id]
    direct_items, direct_errors, direct_sources = manifests[spec_id]
    items = {item["id"]: dict(item) for item in direct_items}
    errors = list(direct_errors) + list(spec.get("reexport_errors", []))
    sources = list(direct_sources)
    active.add(spec_id)
    for child_id in spec.get("reexport_ids", []):
        child_items, child_errors, child_sources = merged_sdk_manifest(
            child_id, specs_by_id, manifests, memo, active)
        errors.extend(child_errors)
        for item in child_items:
            if item["id"] in items:
                continue
            inherited = dict(item)
            inherited["reexported"] = True
            inherited["origin_framework"] = item.get("origin_framework", child_id)
            items[inherited["id"]] = inherited
        if child_sources:
            sources.append(f"public APIs re-exported from {child_id}")
    result = (list(items.values()), list(dict.fromkeys(errors)), list(dict.fromkeys(sources)))
    memo[spec_id] = result
    return result


def framework_spec(path, framework_root, tbd_override=None):
    relative = path.relative_to(framework_root)
    components = [part[:-len(".framework")] for part in relative.parts
                  if part.endswith(".framework")]
    if not components or any(component.startswith("_") for component in components):
        return None
    module = components[-1]
    name = "/".join(components)
    interface = path / "Modules" / f"{module}.swiftmodule" / "arm64e-apple-macos.swiftinterface"
    if not interface.is_file():
        candidates = sorted(p for p in path.rglob("arm64e-apple-macos.swiftinterface")
                            if ".private." not in p.name and ".package." not in p.name)
        interface = candidates[0] if candidates else None
    module_dir = path / "Modules" / f"{module}.swiftmodule"
    swift_binary = next(iter(sorted(module_dir.glob("arm64e-apple-macos.swiftmodule"))), None)
    if not swift_binary:
        swift_binary = next(iter(sorted(path.rglob("arm64e-apple-macos.swiftmodule"))), None)
    tbd_candidates = [tbd_override] if tbd_override else [path / f"{module}.tbd", *path.rglob(f"{module}.tbd")]
    tbd = next((candidate for candidate in tbd_candidates if candidate and candidate.is_file()), None)
    return {"id": name, "name": name, "module": module,
            "priority_name": module, "parent_name": components[0],
            "relative_path": relative,
            "kind": "framework", "sdk_path": path,
            "tbd": tbd, "swift_interfaces": [interface] if interface else [],
            "swift_binary": swift_binary, "binary": None}


def dylib_spec(tbd, sdk):
    framework_root = sdk / "System/Library/Frameworks"
    owner = next((path for path in tbd.parents if path.name.endswith(".framework")), None)
    if owner:
        try:
            components = [part[:-len(".framework")] for part in owner.relative_to(framework_root).parts
                          if part.endswith(".framework")]
        except ValueError:
            return None
        if any(component.startswith("_") for component in components):
            return None
        name = tbd.name[:-len(".tbd")]
        identifier = "/".join(components + [name])
        return {"id": identifier, "name": identifier, "module": name,
                "priority_name": name, "parent_name": components[0] if components else None,
                "relative_path": None, "kind": "dylib", "sdk_path": tbd,
                "tbd": tbd, "swift_interfaces": [], "swift_binary": None,
                "binary": None}

    library_root = sdk / "usr/lib"
    try:
        relative = tbd.relative_to(library_root)
    except ValueError:
        return None
    parts = relative.with_suffix("").parts
    if parts and parts[0] == "system":
        parts = parts[1:]
    name = parts[-1] if parts else tbd.name[:-len(".tbd")]
    identifier = "/".join(parts) or name
    return {"id": identifier, "name": identifier, "module": name,
            "priority_name": name, "parent_name": None,
            "relative_path": None, "kind": "dylib", "sdk_path": tbd,
            "tbd": tbd, "swift_interfaces": [], "swift_binary": None,
            "binary": None}


def framework_specs(sdk):
    specs = []
    framework_root = sdk / "System/Library/Frameworks"
    for path in sorted(framework_root.rglob("*.framework")):
        spec = framework_spec(path, framework_root)
        if spec:
            specs.append(spec)

    lib_root = sdk / "usr/lib"
    if lib_root.is_dir():
        for tbd in sorted(lib_root.rglob("*.tbd")):
            name = tbd.name[:-len(".tbd")]
            if name.endswith(("_debug", "_profile", "_asan")) or name in ("libSystemHealth", "libobjc-trampolines"):
                continue
            spec = dylib_spec(tbd, sdk)
            if spec:
                specs.append(spec)
    unique = {}
    for spec in specs:
        unique[spec["id"]] = spec
    return sorted(unique.values(), key=lambda item: item["id"].casefold())


def target_binary(spec, build_root):
    if spec["kind"] == "framework":
        if spec.get("tbd"):
            try:
                install = tbd_exports(spec["tbd"])["install_name"]
            except (OSError, RuntimeError):
                install = None
            if install:
                candidate = build_root / install.lstrip("/")
                if candidate.is_file():
                    return candidate
        bundle = build_root / "System/Library/Frameworks" / spec.get(
            "relative_path", Path(f"{spec['module']}.framework"))
        candidate = bundle / spec.get("module", spec["name"])
    else:
        try:
            install = tbd_exports(spec["tbd"])["install_name"]
        except (OSError, RuntimeError):
            install = None
        if not install:
            return None
        candidate = build_root / install.lstrip("/")
    return candidate if candidate.is_file() else None


def nm_exports(binary):
    result = command(["nm", "-gU", "-arch", "arm64e", str(binary)])
    if result.returncode:
        raise RuntimeError((result.stderr or result.stdout).strip())
    return {line.split()[-1] for line in result.stdout.splitlines() if line.split()}


_REEXPORTED_EXPORTS = {}


def reexported_exports(binary, build_root, seen=None):
    """The symbols Finch's image re-exports from its other images, found statically.

    Loading Finch's libSystem into a host process to ask dlsym gets the process killed,
    so umbrella libraries are read from disk: each LC_REEXPORT_DYLIB that Finch builds,
    and what it re-exports in turn. A library Finch doesn't build adds nothing."""
    seen = set() if seen is None else seen
    key = str(binary)
    if key in _REEXPORTED_EXPORTS:
        return _REEXPORTED_EXPORTS[key]
    symbols = set()
    try:
        libraries = macho_reexports(binary)
    except RuntimeError:
        libraries = set()
    for install in sorted(libraries):
        child = build_root / install.lstrip("/")
        if not child.is_file() or str(child) in seen:
            continue
        seen.add(str(child))
        try:
            symbols |= nm_exports(child)
        except RuntimeError:
            result = command(["nm", "-gU", str(child)])
            if not result.returncode:
                symbols |= {line.split()[-1] for line in result.stdout.splitlines() if line.split()}
        symbols |= reexported_exports(child, build_root, seen)
    _REEXPORTED_EXPORTS[key] = symbols
    return symbols


def macho_reexports(binary):
    result = command(["otool", "-l", str(binary)])
    if result.returncode:
        raise RuntimeError((result.stderr or result.stdout).strip())
    lines = result.stdout.splitlines()
    libraries = set()
    for index, line in enumerate(lines):
        if line.strip() != "cmd LC_REEXPORT_DYLIB":
            continue
        for candidate in lines[index + 1:index + 5]:
            match = re.match(r"\s*name\s+(.+?)\s+\(offset \d+\)", candidate)
            if match:
                libraries.add(match.group(1))
                break
    return libraries


def normalized_swift_symbol(symbol):
    return symbol[1:] if symbol.startswith("_$") else symbol


def swift_symbol_present(check, exports, normalized_exports=None, sorted_exports=None):
    candidates = [check.get("mangled", ""), *check.get("accessors", [])]
    if check.get("kind") == "Constructor":
        candidates += [symbol[:-1] + "C" for symbol in candidates if symbol.endswith("c")]
    candidates = [normalized_swift_symbol(symbol) for symbol in candidates if symbol]
    normalized = normalized_exports
    if normalized is None:
        normalized = {normalized_swift_symbol(symbol) for symbol in exports}
    if any(symbol in normalized for symbol in candidates):
        return True
    if check.get("kind") in ("Class", "Struct", "Enum", "Protocol", "EnumElement") or check.get("protocol_req"):
        if sorted_exports is None:
            return any(any(export.startswith(symbol) for export in normalized) for symbol in candidates)
        return any(
            (index := bisect.bisect_left(sorted_exports, symbol)) < len(sorted_exports)
            and sorted_exports[index].startswith(symbol)
            for symbol in candidates)
    return False


def swift_module_item_present(check, own_usrs, exports, normalized_exports=None, sorted_exports=None):
    """Compare a Swift declaration from Finch's module with its emitted ABI symbols."""
    if check["usr"] not in own_usrs:
        return False
    if check.get("kind") in ("TypeAlias", "AssociatedType"):
        # These are compile-time declarations and have no standalone link symbol.
        return True
    if not check.get("mangled") and not check.get("accessors"):
        return True
    return swift_symbol_present(check, exports, normalized_exports, sorted_exports)


def prepare_finch_modules(specs, build_root):
    module_root = ROOT / "build/api-coverage/modules"
    module_root.mkdir(parents=True, exist_ok=True)
    staged = {}
    for spec in specs:
        if spec["kind"] != "framework":
            continue
        name = spec.get("module", spec["name"])
        bundle = build_root / "System/Library/Frameworks" / spec["relative_path"]
        module_dir = bundle / "Modules" / f"{name}.swiftmodule"
        candidates = [
            module_dir / "arm64e-apple-macos.swiftinterface",
            ROOT / "build/obj" / name / f"{name}.swiftinterface",
        ]
        interface = next((candidate for candidate in candidates if candidate.is_file()), None)
        binary = module_dir / "arm64e-apple-macos.swiftmodule"
        if not interface and not binary.is_file():
            continue
        staged_files = [interface] if interface else sorted(module_dir.glob("arm64e-apple-macos.*"))
        include_path = stage_module_files(module_root, spec, staged_files)
        package_roots = [ROOT / "build/obj" / suffix
                         for suffix in (name, f"{name}-pkg", f"{name}-swift", f"{name}-module")]
        package_modules = []
        for package_root in package_roots:
            if package_root.is_dir():
                package_modules.extend(path for path in package_root.rglob("Modules")
                                       if path.is_dir() and any(path.glob("*.swiftmodule")))
        include_paths = list(dict.fromkeys([include_path, *sorted(package_modules)]))
        staged[spec["id"]] = {
            "interface": bool(interface), "module": name,
            "include_path": include_paths,
        }
    return module_root, staged


def compile_responder():
    RESPONDER.parent.mkdir(parents=True, exist_ok=True)
    result = command(["xcrun", "clang", "-fobjc-arc", "-o", str(RESPONDER), str(RESPONDER_SOURCE), "-framework", "Foundation"])
    if result.returncode:
        raise RuntimeError((result.stderr or result.stdout).strip())


def objc_responses(spec, items, binary, build_root):
    # (a library's re-exported C symbols are read from Finch's images on disk instead;
    # see reexported_exports)
    runtime_items = [item for item in items if (item["kind"].startswith("objc ") and
                                                not (item["kind"] == "objc class" and spec["kind"] != "framework")) or
                     (item.get("reexported") and item["check"]["type"] in ("symbol", "swift") and spec["kind"] == "framework")]
    if not runtime_items:
        return {}, None
    if not binary:
        return {item["id"]: False for item in runtime_items}, None
    lines, item_queries = [], {}
    class_names = {item["check"]["name"] for item in runtime_items if item["kind"] == "objc class"}
    for name in sorted(class_names):
        line = f"@class {name}"
        lines.append(line)
        item_queries["objc-class:" + name] = [line]
    for item in runtime_items:
        check = item["check"]
        if item["kind"] == "objc class":
            continue
        if check["type"] == "method":
            line = f"{check['name']} {check['selector']}"
            lines.append(line)
            item_queries[item["id"]] = [line]
        elif check["type"] == "property":
            queries = [f"{check['name']} {check['getter']}"]
            if check.get("setter"):
                queries.append(f"{check['name']} {check['setter']}")
            lines.extend(queries)
            item_queries[item["id"]] = queries
        elif check["type"] == "protocol":
            line = f"@protocol {check['name']}"
            lines.append(line)
            item_queries[item["id"]] = [line]
        elif check["type"] == "protocol method":
            line = f"@protocol-method {check['name']} {check['selector']}"
            lines.append(line)
            item_queries[item["id"]] = [line]
        elif check["type"] == "protocol property":
            line = f"@protocol-property {check['name']} {check['property']} {check['getter'][0]}"
            lines.append(line)
            item_queries[item["id"]] = [line]
        elif check["type"] == "symbol":
            symbol = check["symbol"]
            query = symbol[1:] if symbol.startswith("_") else symbol
            line = f"@symbol {query}"
            lines.append(line)
            item_queries[item["id"]] = [line]
        elif check["type"] == "swift":
            if check.get("kind") in ("TypeAlias", "AssociatedType"):
                # Re-exported Swift type aliases have no runtime symbol of their own.
                item_queries[item["id"]] = []
                continue
            if check.get("kind") == "Var" and check.get("accessors"):
                # A property's descriptor is metadata, not a callable accessor. Check its
                # getter and setter symbols instead; requiring the descriptor hid real APIs.
                symbols = list(check["accessors"])
            else:
                symbols = [check.get("mangled", ""), *check.get("accessors", [])]
            if check.get("kind") == "Constructor":
                symbols += [symbol[:-1] + "C" for symbol in symbols if symbol.endswith("c")]
            queries = [f"@symbol {symbol[1:] if symbol.startswith('_') else symbol}"
                       for symbol in symbols if symbol]
            lines.extend(queries)
            item_queries[item["id"]] = queries
    env = os.environ.copy()
    system = build_root / "System/Library"
    env["DYLD_FRAMEWORK_PATH"] = ":".join(str(p) for p in (
        system / "Frameworks", system / "PrivateFrameworks",
        system / "Frameworks/Quartz.framework/Frameworks",
        system / "Frameworks/CoreServices.framework/Versions/A/Frameworks",
        system / "Frameworks/ApplicationServices.framework/Versions/A/Frameworks",
        system / "Frameworks/Carbon.framework/Versions/A/Frameworks"))
    with tempfile.TemporaryDirectory() as standalone:
        # Finch's standalone libraries, alone on the library path, as tools/host-tests.sh
        # has them (all of usr/lib would swap in Finch's libSystem as well).
        for library in ("usr/lib/libMobileGestalt.dylib", "usr/lib/libDiagnosticMessagesClient.dylib",
                        "usr/lib/system/libfinchaccount.dylib", "usr/lib/system/libsystem_dnssd.dylib"):
            if (build_root / library).is_file():
                os.symlink(build_root / library, Path(standalone) / Path(library).name)
        env["DYLD_LIBRARY_PATH"] = ":".join(str(path) for path in (
            build_root / "usr/lib/swift", Path(standalone),
            build_root / "System/Library/Frameworks/OpenGL.framework/Versions/A/Libraries",
        ) if path.is_dir())
        env["FINCH_THEME"] = "Classic"
        result = command([str(RESPONDER), str(binary)], input="\n".join(lines) + "\n", env=env)
    if result.returncode:
        return {item["id"]: False for item in runtime_items}, \
            (result.stderr or result.stdout).strip()[-1400:] or f"the responder exited with status {result.returncode}"
    missing = {line.strip() for line in result.stdout.splitlines() if line.strip()}
    answers = {}
    for item in runtime_items:
        queries = item_queries.get(item["id"], [])
        check = item["check"]
        if check["type"] == "swift" and check.get("kind") in ("TypeAlias", "AssociatedType"):
            answers[item["id"]] = True
        elif check["type"] == "swift" and check.get("kind") == "Var" and check.get("accessors"):
            # All public accessors matter for a writable property.
            answers[item["id"]] = bool(queries) and all(query not in missing for query in queries)
        else:
            # For functions, constructors and type metadata, the mangled forms are
            # alternatives. One exported form is enough to make the API usable.
            answers[item["id"]] = bool(queries) and any(query not in missing for query in queries)
    return answers, None


def current_difftest_identity(framework, sdk_path, sdk_version, build_root, specs, *,
                              runtime_identity=_RUNTIME_IDENTITY_UNSET, runner=None):
    """Return the identity a fresh differential run for this framework must have."""
    spec = specs.get(framework)
    if spec is None:
        return None
    binary = target_binary(spec, build_root)
    if binary is None:
        return None
    runner = runner or load_tool("tools/difftest/run.py", "finch_difftest_for_coverage")
    try:
        if runtime_identity is _RUNTIME_IDENTITY_UNSET:
            runtime_identity = runner.finch_runtime_identity(build_root)
        if runtime_identity is None:
            return None
        return runner.evidence_identity(
            framework, sdk_path, sdk_version, binary,
            build_root=build_root, runtime_identity=runtime_identity,
        )
    except (OSError, RuntimeError):
        return None


def has_fresh_difftest_evidence(document, framework, *, sdk_path, sdk_version, build_root, specs,
                                runtime_identity=_RUNTIME_IDENTITY_UNSET, runner=None):
    evidence = document.get("difftest_evidence")
    if not isinstance(evidence, dict) or evidence.get("schema_version") != 1:
        return False
    if not re.fullmatch(r"[0-9a-f]{32}", str(evidence.get("run_id", ""))):
        return False
    identity = current_difftest_identity(
        framework, sdk_path, sdk_version, build_root, specs,
        runtime_identity=runtime_identity, runner=runner,
    )
    if identity is None or evidence.get("identity") != identity:
        return False
    if not re.fullmatch(r"[0-9a-f]{64}", str(evidence.get("test_source_sha256", ""))):
        return False
    if not re.fullmatch(r"[0-9a-f]{64}", str(evidence.get("test_binary_sha256", ""))):
        return False
    if not re.fullmatch(r"[0-9a-f]{64}", str(evidence.get("input_manifest_sha256", ""))):
        return False
    try:
        api_items = int(evidence["api_items"])
        compared_items = int(evidence["compared_items"])
        input_count = int(document["input_count"])
    except (KeyError, TypeError, ValueError):
        return False
    return api_items > 0 and 0 < compared_items <= api_items and input_count > 0


def is_difftest_record(item):
    return isinstance(item, dict) and any(
        key in item for key in ("difftest_name", "category", "examples"))


def verified_difftest_record(item, evidence_is_fresh, evidence_run_id):
    examples = item.get("examples") if isinstance(item, dict) else None
    return (evidence_is_fresh and evidence_run_id and
            item.get("difftest_run_id") == evidence_run_id and item.get("status") == "verified" and
            item.get("finch_source_verified") is True and isinstance(examples, dict) and
            isinstance(examples.get("apple"), int) and examples["apple"] > 0 and
            isinstance(examples.get("finch"), int) and examples["finch"] > 0)


def verification_results(*, sdk_path=None, sdk_version=None, build_root=None, specs=None):
    verified = {}
    directory = ROOT / "build/compat-results"
    if not directory.is_dir():
        return verified
    specs = specs or {}
    build_root = build_root or BUILD_ROOT
    identity_arguments_available = sdk_path is not None and sdk_version is not None
    runtime_runner = None
    runtime_identity = None
    if identity_arguments_available:
        try:
            runtime_runner = load_tool("tools/difftest/run.py", "finch_difftest_for_coverage")
            runtime_identity = runtime_runner.finch_runtime_identity(build_root)
        except (OSError, RuntimeError):
            runtime_identity = None
    for path in sorted(directory.glob("*.json")):
        try:
            document = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        framework = document.get("framework", path.stem)
        evidence_is_fresh = False
        evidence = document.get("difftest_evidence", {})
        evidence_run_id = evidence.get("run_id") if isinstance(evidence, dict) else None
        if identity_arguments_available:
            evidence_is_fresh = has_fresh_difftest_evidence(
                document, framework, sdk_path=sdk_path, sdk_version=sdk_version,
                build_root=build_root, specs=specs,
                runtime_identity=runtime_identity, runner=runtime_runner)
        item_records = document.get("items", {})
        if isinstance(item_records, list):
            item_records = {str(item["id"]): item for item in item_records
                            if isinstance(item, dict) and item.get("id")}
        elif not isinstance(item_records, dict):
            item_records = {}
        values = set()
        candidates = document.get("verified", [])
        if isinstance(candidates, list):
            for value in candidates:
                key = str(value)
                record = item_records.get(key)
                if record is None:
                    continue
                if is_difftest_record(record) and not verified_difftest_record(
                        record, evidence_is_fresh, evidence_run_id):
                    continue
                values.add(key)
        results = document.get("results", [])
        if isinstance(results, list):
            for row in results:
                if isinstance(row, dict) and row.get("id") and (
                        row.get("verified") is True or row.get("passed") is True or
                        row.get("status") in ("verified", "passed")):
                    values.add(str(row["id"]))
        items = document.get("items", {})
        if isinstance(items, dict):
            for key, value in items.items():
                if is_difftest_record(value):
                    if verified_difftest_record(value, evidence_is_fresh, evidence_run_id):
                        values.add(key)
                    else:
                        values.discard(key)
                    continue
                if isinstance(value, dict):
                    status = value.get("status")
                    if status in ("differs", "crashes", "not-exercised") or value.get("verified") is False or value.get("passed") is False:
                        values.discard(key)
                    elif (value.get("verified") is True or value.get("passed") is True or
                          status in ("verified", "passed")):
                        values.add(key)
                elif value is False:
                    values.discard(key)
                elif value is True or value in ("verified", "passed"):
                    values.add(key)
        elif isinstance(items, list):
            for row in items:
                if not isinstance(row, dict) or not row.get("id"):
                    continue
                item_id = str(row["id"])
                if is_difftest_record(row):
                    if verified_difftest_record(row, evidence_is_fresh, evidence_run_id):
                        values.add(item_id)
                    else:
                        values.discard(item_id)
                    continue
                if (row.get("status") in ("differs", "crashes", "not-exercised") or
                        row.get("verified") is False or row.get("passed") is False):
                    values.discard(item_id)
                elif (row.get("verified") is True or row.get("passed") is True or
                      row.get("status") in ("verified", "passed")):
                    values.add(item_id)
        verified.setdefault(framework, set()).update(values)
    return verified


def app_sweep_inputs(module):
    """Fingerprint the app binaries and Finch images used by app-sweep."""
    paths = {Path(directory) for directory in module.DIRS}
    paths.update({ROOT / "tools/app-sweep.py", ROOT / "tools/check-imports.py"})
    for directory in module.DIRS:
        if not os.path.isdir(directory):
            continue
        for entry in sorted(os.listdir(directory)):
            if not entry.endswith(".app"):
                continue
            app = os.path.join(directory, entry)
            paths.add(Path(app))
            for folder in ("Frameworks", "PlugIns", "Resources"):
                paths.add(Path(app) / "Contents" / folder)
            executable = module.executable(app)
            if executable:
                paths.add(Path(executable))
            paths.update(Path(path) for path in module.bundled(app))

    if BUILD_ROOT.is_dir():
        for directory, subdirectories, files in os.walk(BUILD_ROOT):
            paths.add(Path(directory))
            paths.update(Path(directory) / name for name in subdirectories)
            paths.update(Path(directory) / name for name in files)

    rows, latest = [], 0
    for path in sorted(paths, key=str):
        try:
            stat = path.stat()
            rows.append((str(path), stat.st_size, stat.st_mtime_ns))
            latest = max(latest, stat.st_mtime_ns)
        except OSError:
            rows.append((str(path), None, None))
    fingerprint = hashlib.sha256(json.dumps(rows, separators=(",", ":")).encode()).hexdigest()
    return fingerprint, latest


def app_sweep_counts():
    """Reuse app-sweep's own launch-impact counts while its inputs stay unchanged."""
    module = load_tool("tools/app-sweep.py", "finch_app_sweep")
    fingerprint, latest_input = app_sweep_inputs(module)

    try:
        cache = json.loads(APP_SWEEP_CACHE.read_text())
        if cache.get("fingerprint") == fingerprint and isinstance(cache.get("counts"), dict):
            return cache["counts"], None, fingerprint
    except (OSError, json.JSONDecodeError):
        pass

    # Reuse a completed report from before this cache was added when none of the
    # app or build binaries have changed since that report was made.
    try:
        previous = json.loads(REPORT_JSON.read_text())
        generated = datetime.datetime.fromisoformat(previous["generated_at"])
        old_error = previous.get("overall", {}).get("app_sweep_error")
        counts = previous.get("app_sweep_apps_blocked")
        if (not old_error and isinstance(counts, dict) and
                int(generated.timestamp() * 1_000_000_000) >= latest_input):
            APP_SWEEP_CACHE.parent.mkdir(parents=True, exist_ok=True)
            APP_SWEEP_CACHE.write_text(json.dumps({"fingerprint": fingerprint, "counts": counts},
                                                  separators=(",", ":")))
            return counts, None, fingerprint
    except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError):
        pass

    old_argv = sys.argv[:]
    captured = io.StringIO()
    try:
        sys.argv = [str(ROOT / "tools/app-sweep.py")]
        with contextlib.redirect_stdout(captured):
            module.main()
    except (OSError, RuntimeError, subprocess.SubprocessError, SystemExit) as error:
        return {}, str(error), fingerprint
    finally:
        sys.argv = old_argv
    text = captured.getvalue()
    counts = {}
    sections = (
        ("frameworks Finch has no image of, by apps blocked:", "blocked by one framework alone:"),
        ("Finch frameworks short of symbols, by apps blocked:", ""),
    )
    for heading, end_marker in sections:
        if heading not in text:
            continue
        body = text.split(heading, 1)[1]
        if end_marker and end_marker in body:
            body = body.split(end_marker, 1)[0]
        for line in body.splitlines():
            match = re.match(r"\s*(\d+)\s+([^\s]+)(?:\s+\([^)]*\))?\s*$", line)
            if match:
                counts[match.group(2)] = max(counts.get(match.group(2), 0), int(match.group(1)))
    APP_SWEEP_CACHE.parent.mkdir(parents=True, exist_ok=True)
    APP_SWEEP_CACHE.write_text(json.dumps({"fingerprint": fingerprint, "counts": counts},
                                          separators=(",", ":")))
    return counts, None, fingerprint


def summarize(results, app_counts, app_error):
    parsed = [row for row in results if row["status"] != "incomplete"]
    total = sum(row["total"] for row in parsed)
    present = sum(row["present"] for row in parsed)
    missing = total - present
    verified = sum(row["verified"] for row in parsed)
    percent = 100.0 * present / total if total else 0.0
    ranking = []
    for row in results:
        apps = app_counts.get(row.get("priority_name", row["name"]), 0)
        if not apps and row.get("parent_name"):
            apps = app_counts.get(row["parent_name"], 0)
        score = apps * row["missing"]
        if score:
            ranking.append({"name": row["name"], "missing": row["missing"], "apps": apps, "score": score})
    ranking.sort(key=lambda row: (-row["score"], -row["missing"], row["name"].casefold()))
    return {"total": total, "present": present, "missing": missing, "verified": verified,
            "percent": percent, "parsed_frameworks": len(parsed),
            "empty_frameworks": sum(row["status"] == "empty" for row in results),
            "incomplete_frameworks": sum(row["status"] == "incomplete" for row in results),
            "app_priority": ranking[:15],
            "app_sweep_error": app_error}


def markdown_report(report):
    summary = report["overall"]
    lines = [
        "# Finch compatibility coverage", "",
        f"SDK baseline: macOS SDK {report['sdk_version']} (arm64e).", "",
        "This report compares public C declarations and SDK export lists, Objective-C "
        "classes, methods and properties, and Swift declarations from the SDK interfaces. "
        "It follows public TAPI re-exports, checks C symbols and Swift API declarations "
        "against Finch's built Swift modules where they exist, and checks Swift symbols "
        "otherwise. It asks Finch's loaded classes "
        "whether they answer the listed selectors. A library's re-exported symbols and "
        "classes (libSystem's, for one) are read from the Finch images it re-exports, on "
        "disk, since loading Finch's libSystem into the host process is not possible. "
        "These checks show API presence; they "
        "do not prove matching behavior. Public framework bundles, including nested "
        "subframeworks, and public dylib stubs under usr/lib, including its subfolders, "
        "are included. PrivateFrameworks "
        "and underscore-named framework bundles are excluded.", "",
        "Behavior-verified counts come from item IDs in build/compat-results/*.json. "
        "Generated comparison records count only when the item's run matches the saved SDK, "
        "test code, and Finch image for this report, the Finch image was loaded during the run, "
        "and both sides produced output. Standalone verified IDs without item records are "
        "kept as history but are not counted. These checks cover the recorded safe inputs, "
        "not every input an API can accept. Constant checks also merge into the framework files. The full "
        "name-by-name report is kept in build/api-coverage.json.", "",
        f"Overall: **{summary['percent']:.1f}%** ({summary['present']:,} of "
        f"{summary['total']:,} API items across {summary['parsed_frameworks']} "
        "parsed frameworks or dylibs).", "",
        f"{summary['incomplete_frameworks']} frameworks or dylibs had a parse or load issue "
        "and are left out of the overall percentage. "
        f"{summary['empty_frameworks']} parsed successfully but had no public macOS API items.", "",
        "| Framework or dylib | API items | Present | Missing | Coverage | Behavior verified | Status |",
        "|---|---:|---:|---:|---:|---:|---|",
    ]
    for row in sorted(report["frameworks"], key=lambda value: value["name"].casefold()):
        percent = f"{row['percent']:.1f}%" if row["status"] != "incomplete" else "incomplete"
        verified = f"{row['verified']}/{row['total']}" if row["total"] else "0/0"
        status = row["status"]
        lines.append(f"| {row['name']} | {row['total']:,} | {row['present']:,} | {row['missing']:,} | "
                     f"{percent} | {verified} | {status} |")
    missing_images = [row for row in report["frameworks"] if not row["image_found"] and row["total"]]
    lines += ["", "## Finch images not built", "",
              "These SDK frameworks or dylibs have no Finch image. The size column is the "
              "number of API items found for that image.", "",
              "| Framework or dylib | API items missing |", "|---|---:|"]
    for row in sorted(missing_images, key=lambda value: (-value["total"], value["name"].casefold())):
        lines.append(f"| {row['name']} | {row['total']:,} |")
    lines += ["", "## App impact", "",
              "Priority score is missing API items multiplied by the number of apps "
              "app-sweep.py finds blocked by that framework.", "",
              "| Framework or dylib | Missing API items | Apps blocked | Score |",
              "|---|---:|---:|---:|"]
    for item in summary["app_priority"]:
        lines.append(f"| {item['name']} | {item['missing']:,} | {item['apps']:,} | {item['score']:,} |")
    if summary.get("app_sweep_error"):
        lines += ["", "app-sweep.py could not provide app counts: " + summary["app_sweep_error"].replace("|", "\\|")]
    lines.append("")
    return "\n".join(lines)


def render_missing(row):
    print(f"{row['name']}: {row['present']}/{row['total']} present; {row['missing']} missing; "
          f"{row['verified']} behavior verified; status={row['status']}")
    for error in row["errors"]:
        print(f"  parse/load issue: {error}")
    for item in row["items"]:
        if not item["present"]:
            verified = "verified" if item["behavior_verified"] else "not verified"
            print(f"  [{item['kind']}] {item['name']} ({item['id']}) — {verified}")


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--markdown", action="store_true", help="write docs/COMPATIBILITY.md")
    ap.add_argument("--json", action="store_true", help="write build/api-coverage.json")
    ap.add_argument("--missing", metavar="FRAMEWORK", help="list one framework's missing API items")
    ap.add_argument("--refresh", action="store_true", help="rebuild SDK API caches")
    ap.add_argument("--build-root", type=Path, default=BUILD_ROOT)
    args = ap.parse_args(argv)

    try:
        sdk = Path(output(["xcrun", "--show-sdk-path"]))
        sdk_version = output(["xcrun", "--show-sdk-version"])
        ctx = {"sdk": sdk, "sdk_version": sdk_version,
               "target": TARGET + sdk_version, "c_audit": load_tool("tools/c-api-audit.py", "finch_c_api_audit")}
        specs = framework_specs(sdk)
        resolve_reexports(specs, sdk)
        specs_by_id = {spec["id"]: spec for spec in specs}
        only_missing = bool(args.missing and not args.markdown and not args.json)
        work_specs = specs
        if only_missing:
            matches = [spec for spec in specs
                       if spec["name"] == args.missing or spec["id"] == args.missing]
            if not matches:
                print(f"No framework or dylib named {args.missing!r} in the SDK.", file=sys.stderr)
                return 2
            included = set()

            def include_reexports(spec_id):
                if spec_id in included:
                    return
                included.add(spec_id)
                for child_id in specs_by_id[spec_id].get("reexport_ids", []):
                    include_reexports(child_id)

            for spec in matches:
                include_reexports(spec["id"])
            work_specs = [spec for spec in specs if spec["id"] in included]
        SDK_CACHE.mkdir(parents=True, exist_ok=True)
        module_root, finch_modules = prepare_finch_modules(work_specs, args.build_root)
        prepare_sdk_modules(work_specs)
        verify = verification_results(sdk_path=sdk, sdk_version=sdk_version,
                                      build_root=args.build_root, specs=specs_by_id)
        try:
            compile_responder()
        except RuntimeError as error:
            print(f"Objective-C responder build failed: {error}", file=sys.stderr)
            return 2
        manifests = {}
        for index, spec in enumerate(work_specs, 1):
            if index == 1 or index % 20 == 0:
                print(f"Reading SDK API manifests: {index}/{len(work_specs)} ({spec['name']})", flush=True)
            manifests[spec["id"]] = parse_sdk_api(spec, ctx, force=args.refresh)

        results = []
        merged_cache = {}
        for index, spec in enumerate(work_specs, 1):
            items, errors, sources = merged_sdk_manifest(
                spec["id"], specs_by_id, manifests, merged_cache)
            if index == 1 or index % 20 == 0:
                print(f"Checking Finch images: {index}/{len(work_specs)} ({spec['name']})", flush=True)
            binary = target_binary(spec, args.build_root)
            image_found = binary is not None
            spec["binary"] = binary
            exports = set()
            if binary:
                try:
                    exports = nm_exports(binary)
                except RuntimeError as error:
                    errors.append(f"Finch symbols: {error}")
                    binary = None
                    spec["binary"] = None
            reexported_swift_exports = set()
            reexported_swift_symbols = set()
            reexported_swift_sorted = []
            swift_core = next((specs_by_id[child_id] for child_id in spec.get("reexport_ids", [])
                               if child_id in specs_by_id
                               and specs_by_id[child_id].get("name") == "SwiftUICore"), None)
            if binary and swift_core:
                try:
                    core_install_name = swift_core.get("tbd_data", {}).get("install_name")
                    if core_install_name in macho_reexports(binary):
                        core_binary = target_binary(swift_core, args.build_root)
                        if core_binary:
                            reexported_swift_exports = nm_exports(core_binary)
                            reexported_swift_symbols = {
                                normalized_swift_symbol(symbol) for symbol in reexported_swift_exports}
                            reexported_swift_sorted = sorted(reexported_swift_symbols)
                except RuntimeError as error:
                    errors.append(f"Finch SwiftUICore re-export: {error}")
            if binary and spec["kind"] != "framework":
                exports |= reexported_exports(binary, args.build_root)
            objc_answers, objc_error = objc_responses(spec, items, binary, args.build_root)
            if objc_error:
                errors.append(f"Finch runtime and re-export checks: {objc_error}")
            for item in items:
                check = item["check"]
                if check["type"] == "symbol":
                    item["present"] = check["symbol"] in exports or (
                        item.get("reexported") and objc_answers.get(item["id"], False))
                elif check["type"] == "swift":
                    if item.get("reexported") and spec["kind"] == "framework":
                        item["present"] = objc_answers.get(item["id"], False)
                    elif spec["kind"] == "framework" and spec["id"] in finch_modules:
                        item["present"] = False
                    else:
                        item["present"] = swift_symbol_present(check, exports) if binary else False
                elif item["kind"] == "objc class" and spec["kind"] != "framework":
                    # (a library's classes, like libdispatch's OS_ objects, by their symbols)
                    item["present"] = f"_OBJC_CLASS_$_{check['name']}" in exports
                else:
                    item["present"] = objc_answers.get(item["id"], False)
                item["behavior_verified"] = item["id"] in verify.get(spec["id"], set())
            if spec["kind"] == "framework" and spec["id"] in finch_modules:
                try:
                    with tempfile.NamedTemporaryFile(prefix="finch-", suffix=".json", dir=SDK_CACHE, delete=False) as temp:
                        dump_path = Path(temp.name)
                    try:
                        module_info = finch_modules[spec["id"]]
                        own_root = digester_dump(spec["module"], sdk, ctx["target"], dump_path,
                                                 include_path=module_info["include_path"],
                                                 force_interface=module_info["interface"])
                    finally:
                        dump_path.unlink(missing_ok=True)
                    own_items = swift_nodes(own_root, spec["module"])
                    own_usrs = {item["check"]["usr"] for item in own_items}
                    own_normalized_exports = {normalized_swift_symbol(symbol) for symbol in exports}
                    own_sorted_exports = sorted(own_normalized_exports)
                    for item in items:
                        if item["check"]["type"] == "swift" and not item.get("reexported"):
                            item["present"] = swift_module_item_present(
                                item["check"], own_usrs, exports,
                                own_normalized_exports, own_sorted_exports)
                except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                    errors.append(f"Finch Swift module: {error}")
                    for item in items:
                        if item["check"]["type"] == "swift" and not item.get("reexported"):
                            item["present"] = False
            if reexported_swift_exports:
                # Finch's SwiftUI framework re-exports SwiftUICore. That target uses the
                # SwiftUI ABI name, so its public symbols are part of SwiftUI's own surface.
                for item in items:
                    if item["check"]["type"] == "swift" and not item["present"]:
                        item["present"] = swift_symbol_present(
                            item["check"], (), reexported_swift_symbols, reexported_swift_sorted)
            missing = sum(not item["present"] for item in items)
            status = "complete" if not errors and items else ("empty" if not errors else "incomplete")
            total = len(items)
            row = {"id": spec["id"], "name": spec["name"], "kind": spec["kind"],
                   "priority_name": spec.get("priority_name", spec["name"]),
                   "parent_name": spec.get("parent_name"),
                   "total": total, "present": total - missing, "missing": missing,
                   "percent": (100.0 * (total - missing) / total) if total else 0.0,
                   "verified": sum(item["behavior_verified"] for item in items),
                   "status": status, "errors": errors, "sources": sources,
                   "binary": str(binary) if binary else None, "image_found": image_found,
                   "items": items}
            results.append(row)

        if only_missing:
            row = next(row for row in results
                       if row["name"] == args.missing or row["id"] == args.missing)
            render_missing(row)
            print(f"{row['name']}: {row['present']:,} present, {row['missing']:,} missing of "
                  f"{row['total']:,} API items ({row['percent']:.1f}% coverage).")
            return 0

        app_counts, app_error, app_fingerprint = app_sweep_counts()
        overall = summarize(results, app_counts, app_error)
        report = {"sdk_version": sdk_version, "target": ctx["target"],
                  "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  "overall": overall, "frameworks": results,
                  "app_sweep_apps_blocked": app_counts,
                  "app_sweep_fingerprint": app_fingerprint}
        if args.json:
            REPORT_JSON.parent.mkdir(parents=True, exist_ok=True)
            temporary = None
            try:
                with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", prefix=".api-coverage-",
                                                 suffix=".json", dir=REPORT_JSON.parent,
                                                 delete=False) as report_file:
                    temporary = Path(report_file.name)
                    json.dump(report, report_file, separators=(",", ":"))
                    report_file.write("\n")
                os.replace(temporary, REPORT_JSON)
            except OSError:
                if temporary:
                    temporary.unlink(missing_ok=True)
                raise
            print(f"Wrote {REPORT_JSON.relative_to(ROOT)}")
        if args.markdown:
            REPORT_MARKDOWN.parent.mkdir(parents=True, exist_ok=True)
            REPORT_MARKDOWN.write_text(markdown_report(report))
            print(f"Wrote {REPORT_MARKDOWN.relative_to(ROOT)}")
        if args.missing:
            matches = [row for row in results if row["name"] == args.missing or row["id"] == args.missing]
            if not matches:
                print(f"No framework or dylib named {args.missing!r} in the SDK.", file=sys.stderr)
                return 2
            render_missing(matches[0])
        print(f"macOS SDK {sdk_version}: {overall['percent']:.1f}% API coverage "
              f"({overall['present']:,}/{overall['total']:,} items across "
              f"{overall['parsed_frameworks']} parsed frameworks/dylibs; "
              f"{overall['incomplete_frameworks']} incomplete).")
        if app_error:
            print(f"app-sweep counts unavailable: {app_error}")
        else:
            print("Top app-weighted gaps (missing API items × apps blocked):")
            for item in overall["app_priority"]:
                print(f"  {item['name']}: {item['missing']:,} missing × {item['apps']} apps = {item['score']:,}")
        return 0
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"api coverage failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
