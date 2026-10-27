#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Generate abi.c: Apple's BLAS entry points over Finch's (blas.c).

Apple exports each BLAS routine under several names and ABIs:

    sgemm_, sgemm, SGEMM             the legacy Fortran ABI (int *; real functions return double)
    sgemm$NEWLAPACK                   blas_new.h with 32-bit integers
    sgemm$NEWLAPACK$ILP64             blas_new.h with 64-bit integers
    cblas_sgemm, ...$NEWLAPACK, ...$NEWLAPACK$ILP64   CBLAS, integers by value

Finch implements each once (finch_sgemm_, finch_cblas_sgemm, with 64-bit integers);
this script reads the SDK's headers for the parameter lists and Apple's .tbd for which
names exist, and writes a wrapper per exported name that widens the integers.

    gen-abi.py SDK_HEADERS_DIR LIBBLAS_TBD > abi.c
"""
import re
import sys

HEADERS, TBD = sys.argv[1], sys.argv[2]


def exported(tbd):
    text = open(tbd).read().split("exports:", 1)[1]
    return set(re.findall(r"'?(_[A-Za-z0-9_$.]+)'?", text))


def prototypes(path):
    text = open(path).read()
    text = re.sub(r"//[^\n]*", "", text)
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    found = {}
    for m in re.finditer(r"(?m)^(?:extern\s+)?([A-Za-z_][\w \*]*?)\s*\b(\w+)\s*\(([^;{]*?)\)\s*"
                         r"(?:__LAPACK_ALIAS\w*\(\w+\)\s*)?(?:API_AVAILABLE[^;]*)?;", text):
        ret, name, params = m.group(1).strip(), m.group(2), " ".join(m.group(3).split())
        if ret.startswith(("#", "typedef", "return")) or name in found:
            continue
        params = re.sub(r"\b_Nonnull\b|\b_Nullable\b|\b__nonnull\b|\b__nullable\b", "", params)
        found[name] = (ret, params)
    return found


class Param:
    def __init__(self, text, index):
        text = " ".join(text.replace("*", " * ").split())
        self.variadic = text == "..."
        if self.variadic:
            return
        words = text.split()
        if len(words) > 1 and re.match(r"^\w+$", words[-1]) and words[-1] not in ("int", "float", "double", "char"):
            self.name, type_words = words[-1], words[:-1]
        else:
            self.name, type_words = f"p{index}", words
        self.name = f"a_{self.name}"
        type_words = [w for w in type_words if w != "const"]
        self.pointer = "*" in type_words
        base = " ".join(w for w in type_words if w != "*")
        self.is_int = base == "__LAPACK_int"
        self.enum = not self.pointer and (base.startswith("enum ") or base == "int")
        if self.pointer:
            self.ctype = "void *"
        elif self.is_int or base.startswith("enum ") or base == "int":
            self.ctype = "int"
            self.is_int = True
        elif base in ("float", "double"):
            self.ctype = base
        else:
            self.ctype = "void *"  # callbacks

    def declare(self, wide):
        if self.variadic:
            return "..."
        if self.is_int and not self.pointer and not self.enum:
            return f"{'long' if wide else 'int'} {self.name}"
        return f"{self.ctype} {self.name}"


def split_params(params):
    if params.strip() in ("", "void"):
        return []
    return [Param(p.strip(), i) for i, p in enumerate(params.split(","))]


def c_return(ret, wide, legacy_ret=None):
    if legacy_ret is not None:
        ret = legacy_ret
    ret = ret.replace("extern", "").replace("const", "").strip()
    if ret in ("__LAPACK_int", "int", "CBLAS_INDEX"):
        return "long" if wide else "int"
    if ret in ("float", "double", "void"):
        return ret
    return "void"


def core_name(name):
    if name.startswith("cblas_"):
        return "finch_cblas_" + name[len("cblas_"):]
    if name.startswith("catlas_"):
        return "finch_cblas_" + name[len("catlas_"):]
    return "finch_" + name


counter = 0


def wrapper(symbol, name, ret, params, wide, fortran, legacy_ret=None):
    """One exported symbol calling Finch's implementation."""
    global counter
    counter += 1
    out_ret = c_return(ret, wide, legacy_ret)
    core_ret = c_return(ret, True)
    fn = f"abi_{counter}"
    decl = ", ".join(p.declare(wide) for p in params) or "void"
    lines = [f"{out_ret} {fn}({decl}) __asm(\"{symbol}\");", f"{out_ret} {fn}({decl})", "{"]
    args = []
    for p in params:
        if p.variadic:
            continue
        if fortran and p.is_int and p.pointer and not wide:
            lines.append(f"    long w_{p.name} = {p.name} ? *(const int *){p.name} : 0;")
            args.append(f"{p.name} ? &w_{p.name} : (long *)0")
        else:
            args.append(p.name)
    call = f"{core_name(name)}({', '.join(args)})"
    if out_ret == "void":
        lines.append(f"    {call};")
    elif core_ret == "void":
        lines.append(f"    {call};")
        lines.append("    return 0;")
    else:
        lines.append(f"    return ({out_ret}){call};")
    lines.append("}")
    return "\n".join(lines)


def core_declaration(name, ret, params):
    decl = []
    for p in params:
        if p.variadic:
            continue
        if p.is_int and p.pointer:
            decl.append("long *")
        elif p.enum:
            decl.append("int")
        elif p.is_int:
            decl.append("long")
        else:
            decl.append(p.ctype)
    return f"{c_return(ret, True)} {core_name(name)}({', '.join(decl) or 'void'});"


def main():
    symbols = exported(TBD)
    blas = prototypes(f"{HEADERS}/blas_new.h")
    cblas = prototypes(f"{HEADERS}/cblas_new.h")
    legacy = prototypes(f"{HEADERS}/fortran_blas.h")
    out = ["/* Generated by userland/Accelerate/BLAS/gen-abi.py from the SDK's BLAS headers; do not edit. */",
           "#include <stdarg.h>", "",
           "void finch_cblas_vxerbla(long p, const char *routine, const char *form, va_list args);",
           "long finch_cblas_verrprn(long ierr, long info, const char *form, va_list args);", ""]
    bodies = []
    declared = set()
    for name, (ret, params_text) in sorted(blas.items()):
        if not name.endswith("_"):
            continue
        params = split_params(params_text)
        base = name[:-1]
        if name not in declared:
            out.append(core_declaration(name, ret, params))
            declared.add(name)
        legacy_ret = legacy[name][0] if name in legacy else None
        if legacy_ret and legacy_ret.strip() == "int" and ret.strip() == "void":
            legacy_ret = "void"
        for symbol, wide, lret in ((f"_{base}$NEWLAPACK$ILP64", True, None), (f"_{base}$NEWLAPACK", False, None),
                                   (f"_{name}", False, legacy_ret), (f"_{base}", False, legacy_ret),
                                   (f"_{base.upper()}", False, legacy_ret)):
            if symbol in symbols:
                bodies.append(wrapper(symbol, name, ret, params, wide, True, lret))
    for name, (ret, params_text) in sorted(cblas.items()):
        params = split_params(params_text)
        variadic = any(p.variadic for p in params)
        for symbol, wide in ((f"_{name}$NEWLAPACK$ILP64", True), (f"_{name}$NEWLAPACK", False), (f"_{name}", False)):
            if symbol not in symbols:
                continue
            if variadic:
                global counter
                counter += 1
                fixed = [p for p in params if not p.variadic]
                decl = ", ".join(p.declare(wide) for p in fixed) + ", ..."
                r = c_return(ret, wide)
                last = fixed[-1].name
                target = "finch_cblas_vxerbla" if name == "cblas_xerbla" else "finch_cblas_verrprn"
                call = f"{target}({', '.join(p.name for p in fixed)}, args)"
                body = [f"{r} abi_{counter}({decl}) __asm(\"{symbol}\");", f"{r} abi_{counter}({decl})", "{",
                        "    va_list args;", f"    va_start(args, {last});"]
                if r == "void":
                    body += [f"    {call};", "    va_end(args);"]
                else:
                    body += [f"    {r} result = ({r}){call};", "    va_end(args);", "    return result;"]
                bodies.append("\n".join(body + ["}"]))
                continue
            if name not in declared:
                out.append(core_declaration(name, ret, params))
                declared.add(name)
            bodies.append(wrapper(symbol, name, ret, params, wide, False))
    print("\n".join(out))
    print()
    print("\n\n".join(bodies))


main()
