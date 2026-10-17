#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Build MRC storage accessors from the installed SDK's CloudKit declarations.

The generated file contains only class and property names. Apple headers stay in
the SDK and are never copied into Finch.
"""

import re
import sys
from pathlib import Path

MANUAL_CLASS_PROPERTIES = {
    ("CKOperation", "configuration"),
    ("CKOperationGroup", "defaultConfiguration"),
}
MANUAL_CATEGORY_PROPERTIES = {
    ("CKContainer", "privateCloudDatabase"),
    ("CKContainer", "publicCloudDatabase"),
    ("CKContainer", "sharedCloudDatabase"),
}


def without_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def property_name_and_type(declaration):
    block = re.search(r"\(\s*\^\s*([A-Za-z_]\w*)\s*\)", declaration)
    if block:
        return block.group(1), "void (^)"
    declaration = re.sub(
        r"\b(?:NS_|API_|__|FOUNDATION_|CF_|DEPRECATED|APPKIT_)\w*"
        r"(\([^()]*(\([^()]*\))*[^()]*\))?",
        "",
        declaration,
    ).strip()
    match = re.search(r"([A-Za-z_]\w*)\s*$", declaration)
    if not match:
        return None, None
    return match.group(1), declaration[:match.start()].strip()


def interfaces(header_dir):
    classes = {}
    category_properties = {}
    for path in sorted(header_dir.glob("*.h")):
        source = without_comments(path.read_text(errors="replace"))
        starts = list(re.finditer(r"@interface\s+(CK[A-Za-z_]\w*)\b", source))
        for start in starts:
            end = source.find("@end", start.end())
            if end < 0:
                continue
            owner = start.group(1)
            block = source[start.start():end]
            class_header_end = source.find("\n", start.start())
            if class_header_end < 0 or class_header_end > end:
                class_header_end = end
            category = source[start.end():class_header_end].lstrip().startswith("(")
            entry = category_properties.setdefault(owner, {}) if category else classes.setdefault(owner, {})
            for match in re.finditer(r"@property\s*(\(([^)]*)\))?([^;]*);", block, re.S):
                name, type_name = property_name_and_type(match.group(3))
                if not name or name.startswith("CKSHARE_REQUEST_ACCESS_INTERFACES_"):
                    continue
                attributes = match.group(2) or ""
                entry[name] = {
                    "attributes": attributes,
                    "type": type_name or "",
                    "category": category,
                }
    return classes, category_properties


def is_retained_object(prop):
    attributes = prop["attributes"]
    if re.search(r"\b(?:assign|weak)\b", attributes):
        return False
    if not re.search(r"\b(?:copy|retain|strong)\b", attributes):
        return False
    type_name = prop["type"]
    if "^" in type_name or re.search(r"\bid\b", type_name):
        return True
    return "*" in type_name and not re.search(r"\b(?:void|char|int|short|long|float|double|BOOL|SEL|IMP)\s*\*", type_name)


def generate(header_dir, output):
    classes, category_properties = interfaces(header_dir)
    has_weak_properties = any(
        re.search(r"\bweak\b", prop["attributes"])
        for properties in (*classes.values(), *category_properties.values())
        for prop in properties.values()
    )
    lines = [
        "// Generated from SDK property declarations; do not edit.",
        "// SPDX-License-Identifier: MIT OR Apache-2.0",
        "#import <CloudKit/CloudKit.h>",
        "#import <objc/runtime.h>",
        "",
    ]
    if has_weak_properties:
        lines.extend([
            "@interface _CKGeneratedWeakPropertyBox : NSObject {",
            "    id __weak _value;",
            "}",
            "- (id)value;",
            "- (void)setValue:(id)value;",
            "@end",
            "",
            "@implementation _CKGeneratedWeakPropertyBox",
            "- (id)value { return _value; }",
            "- (void)setValue:(id)value { _value = value; }",
            "@end",
            "",
        ])
    for owner in sorted(classes):
        properties = classes[owner]
        lines.append(f"@implementation {owner}")
        for name, prop in sorted(properties.items()):
            if (owner, name) in MANUAL_CLASS_PROPERTIES:
                continue
            if re.search(r"\bweak\b", prop["attributes"]):
                lines.append(f"@dynamic {name};")
        stored = []
        releases = []
        for name, prop in sorted(properties.items()):
            if (owner, name) in MANUAL_CLASS_PROPERTIES:
                continue
            if re.search(r"\bclass\b|\bweak\b", prop["attributes"]):
                if re.search(r"\bweak\b", prop["attributes"]):
                    category_properties.setdefault(owner, {})[name] = prop
                continue
            lines.append(f"@synthesize {name} = _{name};")
            if is_retained_object(prop):
                releases.append(name)
            stored.append(name)
        if releases:
            lines.append("- (void)dealloc")
            lines.append("{")
            for name in releases:
                lines.append(f"    [_{name} release];")
            lines.append("    [super dealloc];")
            lines.append("}")
        lines.extend(["@end", ""])
    for owner in sorted(category_properties):
        properties = category_properties[owner]
        for name in sorted(properties):
            if (owner, name) in MANUAL_CATEGORY_PROPERTIES:
                continue
            lines.append(f"static char _CK_{owner}_{name}Key;")
        lines.append(f"@implementation {owner} (FinchGeneratedProperties)")
        for name, prop in sorted(properties.items()):
            if (owner, name) in MANUAL_CATEGORY_PROPERTIES:
                continue
            attributes = prop["attributes"]
            type_name = prop["type"]
            if not type_name:
                continue
            class_property = bool(re.search(r"\bclass\b", attributes))
            prefix = "+" if class_property else "-"
            getter = re.search(r"\bgetter\s*=\s*([A-Za-z_]\w*)", attributes)
            getter_name = getter.group(1) if getter else name
            key = f"_CK_{owner}_{name}Key"
            is_object = "*" in type_name or re.search(r"\bid\b|\bClass\b|\^", type_name)
            is_weak = bool(re.search(r"\bweak\b", attributes))
            accessor_type = "id" if "^" in type_name else type_name
            if is_object:
                lines.append(f"{prefix} ({accessor_type}){getter_name}")
                lines.append("{")
                if is_weak:
                    lines.append(f"    _CKGeneratedWeakPropertyBox *box = objc_getAssociatedObject(self, &{key});")
                    lines.append(f"    return ({accessor_type})[box value];")
                else:
                    lines.append(f"    return ({accessor_type})objc_getAssociatedObject(self, &{key});")
                lines.append("}")
            else:
                lines.append(f"{prefix} ({type_name}){getter_name}")
                lines.append("{")
                lines.append(f"    id value = objc_getAssociatedObject(self, &{key});")
                if "BOOL" in type_name or "bool" in type_name:
                    lines.append("    return [value boolValue];")
                elif "float" in type_name or "double" in type_name or "TimeInterval" in type_name:
                    lines.append("    return [value doubleValue];")
                else:
                    lines.append("    return [value unsignedIntegerValue];")
                lines.append("}")
            setter = re.search(r"\bsetter\s*=\s*([A-Za-z_]\w*:)\s*", attributes)
            setter_name = setter.group(1) if setter else "set" + name[:1].upper() + name[1:] + ":"
            lines.append(f"{prefix} (void){setter_name}({accessor_type})value")
            lines.append("{")
            if is_object:
                if is_weak:
                    lines.append(f"    _CKGeneratedWeakPropertyBox *box = objc_getAssociatedObject(self, &{key});")
                    lines.append("    if (!box && value) {")
                    lines.append("        box = [[_CKGeneratedWeakPropertyBox alloc] init];")
                    lines.append(f"        objc_setAssociatedObject(self, &{key}, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);")
                    lines.append("        [box release];")
                    lines.append("        box = objc_getAssociatedObject(self, &" + key + ");")
                    lines.append("    }")
                    lines.append("    [box setValue:value];")
                else:
                    if re.search(r"\bcopy\b", attributes):
                        policy = "OBJC_ASSOCIATION_COPY_NONATOMIC"
                    elif re.search(r"\b(?:retain|strong)\b", attributes):
                        policy = "OBJC_ASSOCIATION_RETAIN_NONATOMIC"
                    else:
                        policy = "OBJC_ASSOCIATION_ASSIGN"
                    lines.append(f"    objc_setAssociatedObject(self, &{key}, value, {policy});")
            else:
                lines.append(f"    objc_setAssociatedObject(self, &{key}, @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC);")
            lines.append("}")
        lines.extend(["@end", ""])
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines))
    print(f"generated MRC storage for {len(classes)} CloudKit classes")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: generate-properties.py SDK_CloudKit_Headers OUTPUT.m")
    generate(Path(sys.argv[1]), Path(sys.argv[2]))
