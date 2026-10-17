#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Generate local runtime glue from the installed macOS SDK declarations.

The SDK stays the source of the declarations. This writes only Finch's class
registrations and generic value accessors into build/, never headers or docs.
"""

import argparse
import glob
import re
from pathlib import Path


def without_comments(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", " ", text)


def blocks(source, pattern, end_marker="@end"):
    starts = list(re.finditer(pattern, source))
    for i, start in enumerate(starts):
        end = source.find(end_marker, start.end())
        next_start = starts[i + 1].start() if i + 1 < len(starts) else len(source)
        if end < 0 or next_start < end:
            continue
        yield start, source[start.start():end + len(end_marker)]


def property_type_kind(type_name, enum_unsigned, object_types=()):
    clean = re.sub(r"\b(?:nullable|nonnull|_Nullable|_Nonnull|__kindof|const|volatile)\b", " ", type_name)
    clean = re.sub(r"\s+", " ", clean).strip()
    if "*" in clean or "^" in clean or clean in ("id", "Class") or clean.startswith("id<"):
        return 0, "@"
    if clean in ("BOOL", "bool", "_Bool"):
        return 1, "B"
    if clean == "float":
        return 5, "f"
    if clean in ("double", "CGFloat"):
        return 2, "d"
    if clean in ("void", "SEL") or clean.startswith(("struct ", "union ")):
        return None, None
    if clean in ("NSInteger", "long", "long long", "int64_t", "int"):
        return 3, "q"
    if clean in ("NSUInteger", "unsigned long", "unsigned long long", "uint64_t", "unsigned int"):
        return 4, "Q"
    if clean in object_types:
        return 0, "@"
    if clean in enum_unsigned:
        return 4, "Q"
    if re.fullmatch(r"[A-Za-z_]\w*", clean):
        return 3, "q"
    return None, None


def parse_method_arguments(rest, enum_unsigned=(), object_types=()):
    """Return (selector, argument names, argument kinds, encodings)."""
    args = []
    pos = 0
    selector_parts = []
    while pos < len(rest):
        label = re.match(r"\s*([A-Za-z_]\w*)\s*:", rest[pos:])
        if not label:
            break
        name = label.group(1)
        pos += label.end()
        while pos < len(rest) and rest[pos].isspace():
            pos += 1
        if pos >= len(rest) or rest[pos] != "(":
            break
        depth = 1
        end = pos + 1
        while end < len(rest) and depth:
            if rest[end] == "(":
                depth += 1
            elif rest[end] == ")":
                depth -= 1
            end += 1
        if depth:
            break
        argument_type = rest[pos + 1:end - 1]
        argument_name = re.match(r"\s*\*?\s*([A-Za-z_]\w*)", rest[end:])
        if not argument_name:
            break
        kind, encoding = property_type_kind(argument_type, enum_unsigned, object_types)
        if kind is None:
            return "", [], [], []
        args.append(argument_name.group(1))
        selector_parts.append(name + ":")
        args[-1] = (args[-1], kind, encoding)
        pos = end + argument_name.end()
    if not selector_parts:
        first = re.match(r"\s*([A-Za-z_]\w*)", rest)
        return (first.group(1) if first else ""), [], [], []
    return ("".join(selector_parts), [a[0] for a in args],
            [a[1] for a in args], [a[2] for a in args])


def c_string(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sdk", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    headers = args.sdk / "System/Library/Frameworks/Intents.framework/Versions/A/Headers"
    if not headers.is_dir():
        raise SystemExit(f"Intents SDK headers are missing: {headers}")

    files = sorted(glob.glob(str(headers / "*.h")))
    interfaces = {}
    properties = {}
    initializers = {}
    factories = {}
    protocols = set()
    protocol_properties = {}
    class_protocols = {}
    class_instance_properties = {}
    enum_unsigned = set()
    object_types = set()
    sources = [without_comments(Path(filename).read_text(errors="replace")) for filename in files]
    for source in sources:
        enum_unsigned.update(re.findall(r"NS_OPTIONS\s*\(\s*NSUInteger\s*,\s*([A-Za-z_]\w*)", source))
        enum_unsigned.update(re.findall(r"NS_ENUM\s*\(\s*NSUInteger\s*,\s*([A-Za-z_]\w*)", source))
        object_types.update(re.findall(r"typedef\s+(?:const\s+)?NSString\s*\*\s*([A-Za-z_]\w*)\b", source))
    for source in sources:
        for match in re.finditer(r"@protocol\s+([A-Za-z_]\w*)\s*<", source):
            protocols.add(match.group(1))
        for start, block in blocks(source, r"@protocol\s+[A-Za-z_]\w*"):
            header = source[start.start():source.find("\n", start.start())]
            protocol_match = re.match(r"@protocol\s+([A-Za-z_]\w*)", header)
            if not protocol_match or not re.search(r"<", header):
                continue
            protocol_name = protocol_match.group(1)
            protocols.add(protocol_name)
            for prop in re.finditer(r"@property\s*(\(([^)]*)\))?([^;]*);", block, re.S):
                declaration = re.sub(r"\s+\b(?:API_AVAILABLE|API_UNAVAILABLE|API_DEPRECATED|NS_SWIFT_NAME)\b.*$", "", prop.group(3)).strip()
                declaration = re.sub(r"\b(?:API_|FOUNDATION_|NS_)[A-Z_]+(?:\([^;]*?\))?", " ", declaration).strip()
                name_match = re.search(r"([A-Za-z_]\w*)\s*$", declaration)
                if not name_match:
                    continue
                property_name = name_match.group(1)
                type_name = declaration[:name_match.start()].strip()
                kind, encoding = property_type_kind(type_name, enum_unsigned, object_types)
                if kind is None:
                    continue
                attributes = prop.group(2) or ""
                getter_match = re.search(r"\bgetter\s*=\s*([A-Za-z_]\w*)", attributes)
                setter_match = re.search(r"\bsetter\s*=\s*([A-Za-z_]\w*:)", attributes)
                getter = getter_match.group(1) if getter_match else property_name
                setter = None if re.search(r"\breadonly\b", attributes) else (
                    setter_match.group(1) if setter_match else "set" + property_name[:1].upper() + property_name[1:] + ":")
                class_property = bool(re.search(r"\bclass\b", attributes))
                protocol_properties.setdefault(protocol_name, {})[(property_name, class_property)] = (
                    getter, setter, kind, encoding, bool(re.search(r"\bcopy\b", attributes)))
        for start, block in blocks(source, r"@interface\s+[A-Za-z_]\w*"):
            header = source[start.start():source.find("\n", start.start())]
            interface = re.match(r"@interface\s+([A-Za-z_]\w*)(.*)", header)
            if not interface:
                continue
            name, tail = interface.group(1), interface.group(2)
            if tail.lstrip().startswith("("):
                owner = name
                category = True
            else:
                category = False
                owner = name
                super_match = re.search(r":\s*([A-Za-z_]\w*)", tail)
                superclass = super_match.group(1) if super_match else "NSObject"
                protocol_match = re.search(r"<([^>]*)>", tail)
                conformance = protocol_match.group(1) if protocol_match else ""
                class_protocols[name] = {value.strip().split()[0] for value in conformance.split(",") if value.strip()}
                flags = (1 if "NSCopying" in conformance else 0) | (2 if "NSSecureCoding" in conformance or "NSCoding" in conformance else 0)
                previous = interfaces.get(name, (superclass, 0))
                interfaces[name] = (superclass, previous[1] | flags)

            for prop in re.finditer(r"@property\s*(\(([^)]*)\))?([^;]*);", block, re.S):
                declaration = re.sub(r"\s+\b(?:API_AVAILABLE|API_UNAVAILABLE|API_DEPRECATED|NS_SWIFT_NAME)\b.*$", "", prop.group(3)).strip()
                declaration = re.sub(r"\b(?:API_|FOUNDATION_|NS_)[A-Z_]+(?:\([^;]*?\))?", " ", declaration).strip()
                name_match = re.search(r"([A-Za-z_]\w*)\s*$", declaration)
                if not name_match:
                    continue
                property_name = name_match.group(1)
                type_name = declaration[:name_match.start()].strip()
                kind, encoding = property_type_kind(type_name, enum_unsigned, object_types)
                if kind is None:
                    continue
                attributes = prop.group(2) or ""
                getter_match = re.search(r"\bgetter\s*=\s*([A-Za-z_]\w*)", attributes)
                setter_match = re.search(r"\bsetter\s*=\s*([A-Za-z_]\w*:)", attributes)
                getter = getter_match.group(1) if getter_match else property_name
                setter = None if re.search(r"\breadonly\b", attributes) else (
                    setter_match.group(1) if setter_match else "set" + property_name[:1].upper() + property_name[1:] + ":")
                class_property = bool(re.search(r"\bclass\b", attributes))
                key = (owner, property_name, class_property)
                properties[key] = (getter, setter, kind, encoding,
                                   bool(re.search(r"\bcopy\b", attributes)))
                if not category and not class_property:
                    class_instance_properties.setdefault(owner, set()).add(property_name)

            for method in re.finditer(r"^[ \t]*([-+])\s*\(([^;]*?)\)\s*([^;]+?);", block, re.M):
                prefix, return_type, rest = method.groups()
                selector, arg_names, arg_kinds, arg_encodings = parse_method_arguments(rest, enum_unsigned, object_types)
                if not selector:
                    continue
                if prefix == "-" and selector.startswith("init") and arg_names:
                    if any(kind not in (0, 1, 2, 3, 4) for kind in arg_kinds):
                        continue
                    key = (owner, selector)
                    initializers[key] = (arg_names, arg_kinds, "@@:" + "".join(arg_encodings))
                is_resolution_factory = prefix == "+" and "ResolutionResult" in owner
                is_value_factory = prefix == "+" and (owner, selector) in {
                    ("INPaymentMethod", "applePayPaymentMethod"),
                    ("INSendMessageAttachment", "attachmentWithAudioMessageFile:"),
                }
                if is_resolution_factory or is_value_factory:
                    if return_type.strip() not in ("instancetype", "id") and "*" not in return_type:
                        continue
                    factories[(owner, selector)] = (arg_names, arg_kinds,
                                                    "@:" + "".join(arg_encodings))

    for class_name, adopted in class_protocols.items():
        for protocol_name in adopted:
            for (property_name, class_property), value in protocol_properties.get(protocol_name, {}).items():
                properties.setdefault((class_name, property_name, class_property), value)

    class_impls = sorted(interfaces)
    if not class_impls:
        raise SystemExit("No public Objective-C classes found in the SDK headers")

    out = [
        "/* Generated from SDK declarations at build time. Do not install this file. */",
        "#import <Intents/Intents.h>",
        "#import <Foundation/Foundation.h>",
        "#import <objc/runtime.h>",
        '#pragma clang diagnostic ignored "-Wobjc-designated-initializers"',
        "extern void FinchIntentsRegisterClass(const char *, unsigned);",
        "extern void FinchIntentsRegisterProperty(const char *, const char *, const char *, const char *, unsigned, unsigned, unsigned, const char *);",
        "extern id FinchIntentsCreateObject(id, unsigned);",
        "extern void FinchIntentsSetArgumentValue(id, const char *, id);",
        "extern void FinchIntentsSetResolutionStatus(id, const char *);",
        "extern void FinchIntentsRegisterMethod(const char *, const char *, unsigned, unsigned, const char *, IMP);",
        "",
    ]
    for name in class_impls:
        out.append(f"@implementation {name}")
        declared = sorted(class_instance_properties.get(name, set()))
        if declared:
            out.append("@dynamic " + ", ".join(declared) + ";")
        out.append("@end")
    out.append("")
    if protocols:
        out.append(f"__attribute__((used)) static Protocol *FinchIntentsProtocols[{len(protocols)}];")
        out.append("")

    method_index = 0
    typed_methods = []
    for (owner, selector), (arg_names, arg_kinds, arg_encodings) in sorted(initializers.items()):
        typed_methods.append((owner, selector, arg_names, arg_kinds, arg_encodings, 0, 0, method_index))
        method_index += 1
    for (owner, selector), (arg_names, arg_kinds, arg_encodings) in sorted(factories.items()):
        typed_methods.append((owner, selector, arg_names, arg_kinds, arg_encodings, 1, 1, method_index))
        method_index += 1

    c_types = {0: "id", 1: "BOOL", 2: "double", 3: "NSInteger", 4: "NSUInteger", 5: "float"}
    for owner, selector, arg_names, arg_kinds, arg_encodings, class_method, factory, index in typed_methods:
        parameters = ["id receiver", "SEL selector"] + [
            f"{c_types[kind]} argument{position}" for position, kind in enumerate(arg_kinds)
        ]
        out.append(f"static id FinchGeneratedMethod{index}({', '.join(parameters)})")
        out.append("{")
        out.append("    (void)selector;")
        out.append(f"    id object = FinchIntentsCreateObject(receiver, {class_method});")
        out.append("    if (!object) return nil;")
        for position, (name, kind) in enumerate(zip(arg_names, arg_kinds)):
            value = f"argument{position}" if kind == 0 else f"@(argument{position})"
            out.append(f"    FinchIntentsSetArgumentValue(object, {c_string(name)}, {value});")
        if factory:
            out.append(f"    FinchIntentsSetResolutionStatus(object, {c_string(selector)});")
        out.append("    return object;")
        out.append("}")
    out.append("")

    out.append("void FinchIntentsInstallGenerated(void)\n{")
    for index, name in enumerate(sorted(protocols)):
        out.append(f"    FinchIntentsProtocols[{index}] = @protocol({name});")
    for name, (_, flags) in sorted(interfaces.items()):
        out.append(f"    FinchIntentsRegisterClass({c_string(name)}, {flags});")
    for (owner, name, class_property), (getter, setter, kind, encoding, copied) in sorted(properties.items()):
        out.append(
            f"    FinchIntentsRegisterProperty({c_string(owner)}, {c_string(name)}, {c_string(getter)}, "
            f"{c_string(setter) if setter else 'NULL'}, {kind}, {1 if copied else 0}, "
            f"{1 if class_property else 0}, {c_string(encoding)});")

    for owner, selector, _, _, arg_encodings, class_method, factory, index in typed_methods:
        out.append(f"    FinchIntentsRegisterMethod({c_string(owner)}, {c_string(selector)}, {class_method}, {factory}, "
                   f"{c_string(arg_encodings)}, (IMP)FinchGeneratedMethod{index});")
    out.append("}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(out) + "\n")
    print(f"Intents SDK glue: {len(class_impls)} classes, {len(properties)} properties, "
          f"{len(initializers)} constructors, {len(factories)} resolution factories")


if __name__ == "__main__":
    main()
