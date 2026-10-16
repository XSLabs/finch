#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Compare a framework's public C declarations with Finch's exported symbols.

    tools/c-api-audit.py FRAMEWORK

The macOS SDK headers are parsed at run time with Clang. Finch's built framework
is checked with nm. Missing functions and variables are grouped by SDK header;
no SDK files are copied into the repository.
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

FINCH_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FRAMEWORKS = os.path.join(FINCH_ROOT, "build/root/System/Library/Frameworks")


def run(command, **kwargs):
    return subprocess.run(command, capture_output=True, text=True, check=True, **kwargs).stdout.strip()


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


<<<<<<< ours
def declaration_source(node, header_root, header_paths, header_lines):
=======
def declaration_source(node, header_root, header_paths, source_lines=None, token_patterns=None):
>>>>>>> theirs
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
<<<<<<< ours
            lines = header_lines[path]
=======
            lines = (source_lines or {}).get(path)
            if lines is None:
                with open(path, errors="replace") as header_file:
                    lines = header_file.read().splitlines()
                if source_lines is not None:
                    source_lines[path] = lines
>>>>>>> theirs
            if line <= len(lines) and token.search(lines[line - 1]):
                if not column or token.search(lines[line - 1][max(0, column - 1):]):
                    candidates.append(path)
        if len(candidates) == 1:
            return candidates[0]
    return None


def unavailable_on_macos(node, sources):
    for attr in node.get("inner", []):
        kind = attr.get("kind")
        if kind == "UnavailableAttr":
            return True
        if kind != "AvailabilityAttr":
            continue
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


def sdk_declarations(name, framework_path=None):
    sdk = sdk_path()
    framework = (Path(framework_path) if framework_path else
                 Path(sdk) / "System/Library/Frameworks" / f"{name}.framework")
    header_root, header_paths, roots = public_headers(Path(framework), name)
    version = run(["xcrun", "--sdk", "macosx", "--show-sdk-version"])
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
    sources = {}
<<<<<<< ours
    # Clang omits the file name on many AST locations after the first one in
    # each header. Cache these lines once; without this, every declaration
    # would reopen every SDK header while resolving its source.
    header_lines = {path: Path(path).read_text(errors="replace").splitlines() for path in header_paths}
=======
    header_lines, token_patterns = {}, {}
>>>>>>> theirs
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
<<<<<<< ours
                path = declaration_source(node, header_root, header_paths, header_lines)
=======
                path = declaration_source(node, header_root, header_paths, header_lines, token_patterns)
>>>>>>> theirs
                if path:
                    relative = os.path.relpath(path, header_root)
                    declarations.setdefault(symbol, set()).add(relative)
        nested = inside_function or kind in ("FunctionDecl", "BlockDecl", "ObjCMethodDecl")
        for child in node.get("inner", []):
            walk(child, nested)

    walk(ast)
    return {symbol: sorted(headers)[0] for symbol, headers in declarations.items()}


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
