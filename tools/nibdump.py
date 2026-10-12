#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Dump a compiled nib (NIBArchive format) as objects with their keys and values.

    tools/nibdump.py FILE.nib [--connections]

Objects print as "#N ClassName" followed by their keys; references to other objects
print as "-> #N ClassName". --connections lists only the nib's connectors (source,
label, destination), which is what to look at when an app's nib fails to wire up.
"""
import struct
import sys


def varint(b, i):
    """NIBArchive's variable-length integers: 7 bits per byte, the high bit ends it."""
    v = shift = 0
    while True:
        c = b[i]
        i += 1
        v |= (c & 0x7F) << shift
        shift += 7
        if c & 0x80:
            return v, i


def load(path):
    b = open(path, "rb").read()
    if not b.startswith(b"NIBArchive"):
        sys.exit(f"{path}: not a NIBArchive nib")
    (nobj, oobj, nkey, okey, nval, oval, ncls, ocls) = struct.unpack_from("<8I", b, 18)
    keys = []
    i = okey
    for _ in range(nkey):
        n, i = varint(b, i)
        keys.append(b[i:i + n].decode("utf-8", "replace"))
        i += n
    classes = []
    i = ocls
    for _ in range(ncls):
        n, i = varint(b, i)
        extra, i = varint(b, i)
        i += 4 * extra
        classes.append(b[i:i + n].rstrip(b"\0").decode())
        i += n
    values = []
    i = oval
    for _ in range(nval):
        k, i = varint(b, i)
        t = b[i]
        i += 1
        if t == 0:
            v = struct.unpack_from("<b", b, i)[0]; i += 1
        elif t == 1:
            v = struct.unpack_from("<h", b, i)[0]; i += 2
        elif t == 2:
            v = struct.unpack_from("<i", b, i)[0]; i += 4
        elif t == 3:
            v = struct.unpack_from("<q", b, i)[0]; i += 8
        elif t == 4:
            v = True
        elif t == 5:
            v = False
        elif t == 6:
            v = struct.unpack_from("<f", b, i)[0]; i += 4
        elif t == 7:
            v = struct.unpack_from("<d", b, i)[0]; i += 8
        elif t == 8:
            n, i = varint(b, i)
            v = b[i:i + n]; i += n
        elif t == 9:
            v = None
        elif t == 10:
            v = ("ref", struct.unpack_from("<I", b, i)[0]); i += 4
        else:
            sys.exit(f"{path}: unknown value type {t}")
        values.append((keys[k], v))
    objects = []
    i = oobj
    for _ in range(nobj):
        c, i = varint(b, i)
        first, i = varint(b, i)
        count, i = varint(b, i)
        objects.append((classes[c], values[first:first + count]))
    return objects


def show(objects, v):
    if isinstance(v, tuple) and v[0] == "ref":
        return f"-> #{v[1]} {objects[v[1]][0]}"
    if isinstance(v, bytes):
        try:
            s = v.decode("utf-8")
            if s.isprintable():
                return repr(s)
        except UnicodeDecodeError:
            pass
        return f"<{len(v)} bytes>"
    return repr(v)


def string_of(objects, v):
    """An NSString object's text (its NS.bytes), or the value as shown."""
    if isinstance(v, tuple) and v[0] == "ref":
        for k, x in objects[v[1]][1]:
            if k == "NS.bytes" and isinstance(x, bytes):
                return x.decode("utf-8", "replace")
    return show(objects, v)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    objects = load(sys.argv[1])
    if "--connections" in sys.argv:
        for n, (cls, vals) in enumerate(objects):
            if not cls.endswith("Connector") and "Connection" not in cls:
                continue
            d = dict(vals)
            src, dst = d.get("NSSource"), d.get("NSDestination")
            print(f"#{n} {cls}: {show(objects, src)} .{string_of(objects, d.get('NSLabel'))} {show(objects, dst)}")
        return
    for n, (cls, vals) in enumerate(objects):
        print(f"#{n} {cls}")
        for k, v in vals:
            print(f"    {k} = {show(objects, v)}")


if __name__ == "__main__":
    main()
