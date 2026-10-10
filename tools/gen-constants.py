#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Generate a framework's exported constants with the values Apple's has.

    tools/gen-constants.py <Framework> <out.m> [name[:kind] ...]

Reads the data symbols from the SDK's .tbd (arm64e-macos), their types from the
SDK's headers (NSString/CFString objects, doubles, floats, integers), and their
values from Apple's framework on this Mac (each probed in a child process, so a
symbol that isn't what its declaration says can't stop the run). Writes an
Objective-C file of definitions. Only values are taken (as data); the code that
uses them is Finch's. Symbols with no declaration in the headers are written
when their value reads as a plain (ASCII) string, and listed on stderr otherwise.
Names after out.m are probed too (symbols apps import that the SDK no longer
declares), as kind obj, double, float, int or int64 (default obj).
"""
import glob, os, re, subprocess, sys, tempfile

fw, out = sys.argv[1], sys.argv[2]
extra = [a.split(':') for a in sys.argv[3:]]
sdk = subprocess.run(['xcrun', '--show-sdk-path'], capture_output=True, text=True).stdout.strip()
# "Umbrella/Sub" names a subframework (Carbon/HIToolbox)
umbrella, _, sub = fw.partition('/')
if sub:
    rel = f'{umbrella}.framework/Versions/A/Frameworks/{sub}.framework'
    fw = sub
else:
    rel = f'{fw}.framework'
base = f'{sdk}/System/Library/Frameworks/{rel}'
tbd = open(glob.glob(f'{base}/**/{fw}.tbd', recursive=True)[0]).read()
syms = set()
for block in re.split(r'\n  - targets:', tbd):
    if 'arm64e-macos' not in block.split('\n')[0]:
        continue
    m = re.search(r'\n\s*symbols:\s*\[(.*?)\]', block, re.S)
    if m:
        syms |= {s.strip().strip("'") for s in m.group(1).split(',') if s.strip()}
headers = ' '.join(open(f, errors='ignore').read() for f in glob.glob(f'{base}/**/Headers/*.h', recursive=True))
data = []
for s in sorted(syms):
    if s.startswith('$') or not s.startswith('_') or s.startswith('_$'):
        continue
    name = s[1:]
    # a declaration "extern <type> name" / "const <type> name"
    m = re.search(r'(?:extern|EXPORT|EXTERN)[A-Z_ ]*\s+((?:const\s+)?[A-Za-z_][A-Za-z0-9_]*(?:\s*\*)?(?:\s*const)?)\s+' + re.escape(name) + r'\b\s*[A-Z_(;]',
                  headers)
    if not m:
        m = re.search(r'\b((?:const\s+)?[A-Za-z_][A-Za-z0-9_]*\s*\*?\s*const)\s+' + re.escape(name) + r'\b', headers)
    decl = m.group(1).replace('const', '').strip() if m else None
    if decl and re.search(r'\b' + re.escape(name) + r'\s*\(', headers):
        continue  # a function
    if not decl and re.search(r'\b' + re.escape(name) + r'\s*\(', headers):
        continue
    data.append((name, decl))
known = {n for n, _ in data}
for e in extra:
    if e[0] not in known:
        data.append((e[0], {'double': 'double', 'float': 'float', 'int': 'int', 'int64': 'int64_t'}.get(e[1] if len(e) > 1 else '', None)))
probe = r'''
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach-o/loader.h>
int main(int argc, char **argv) { @autoreleasepool {
  void *h = dlopen(argv[1], RTLD_NOW); void *p = dlsym(h, argv[2]); if (!p) { printf("MISSING\n"); return 0; }
  /* (a symbol in a section of instructions is code: a function the headers don't declare) */
  Dl_info di; if (dladdr(p, &di) && di.dli_fbase) {
    const struct mach_header_64 *mh = di.dli_fbase; const struct load_command *lc = (const void *)(mh + 1); uintptr_t slide = 0;
    for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const void *)((const char *)lc + lc->cmdsize))
      if (lc->cmd == LC_SEGMENT_64 && !strcmp(((const struct segment_command_64 *)lc)->segname, "__TEXT")) slide = (uintptr_t)mh - ((const struct segment_command_64 *)lc)->vmaddr;
    lc = (const void *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const void *)((const char *)lc + lc->cmdsize)) {
      if (lc->cmd != LC_SEGMENT_64) continue; const struct segment_command_64 *sg = (const void *)lc;
      const struct section_64 *sc = (const void *)(sg + 1);
      for (uint32_t j = 0; j < sg->nsects; j++, sc++)
        if ((sc->flags & (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS)) && (uintptr_t)p >= sc->addr + slide &&
            (uintptr_t)p < sc->addr + slide + sc->size) { printf("CODE\n"); return 0; } } }
  const char *k = argv[3];
  if (!strcmp(k, "obj")) { id o = (__bridge id)*(void **)p; if ([o isKindOfClass:[NSString class]]) {
      NSString *s = o; NSMutableString *e = [NSMutableString string];
      for (NSUInteger i = 0; i < s.length; i++) { unichar c = [s characterAtIndex:i];
        if (c == '\\' || c == '"') [e appendFormat:@"\\%C", c]; else if (c < 32 || c > 126) [e appendFormat:@"\\u%04x", c]; else [e appendFormat:@"%C", c]; }
      printf("STR %s\n", e.UTF8String); } else printf("OBJ %s\n", [[o description] UTF8String]); }
  else if (!strcmp(k, "double")) printf("DOUBLE %.17g\n", *(double *)p);
  else if (!strcmp(k, "float")) printf("FLOAT %.9g\n", *(float *)p);
  else if (!strcmp(k, "int64")) printf("INT64 %lld\n", *(long long *)p);
  else printf("INT %d\n", *(int *)p);
  return 0; } }
'''
tmp = tempfile.mkdtemp()
open(f'{tmp}/p.m', 'w').write(probe)
subprocess.run(['clang', '-fobjc-arc', '-w', f'{tmp}/p.m', '-framework', 'Foundation', '-o', f'{tmp}/p'], check=True)
binary = f'/System/Library/Frameworks/{rel}/{fw}'
OBJ = re.compile(r'(NSString|CFStringRef|Key|Name|Identifier|Option|Domain|Type|Mode|Category|Notification|Attribute|String)')
lines = ['/* SPDX-License-Identifier: MIT OR Apache-2.0 */',
         f"/* {fw}'s exported constants, with the values Apple's have (tools/gen-constants.py). */",
         '#import <Foundation/Foundation.h>', '']
for name, decl in data:
    if decl in ('double', 'CGFloat', 'NSTimeInterval', 'CFTimeInterval') or (decl and re.search(r'(Accuracy|Distance|Degrees|Direction|Speed|Duration)$', decl or '')):
        kind = 'double'
    elif decl in ('float',):
        kind = 'float'
    elif decl in ('int64_t', 'long long', 'NSInteger', 'long', 'uint64_t', 'NSUInteger', 'unsigned long'):
        kind = 'int64'
    elif decl in ('int', 'int32_t', 'SInt32', 'OSStatus', 'uint32_t', 'UInt32', 'unsigned', 'unsigned int', 'short', 'CFIndex') or (decl and 'Format' in decl and '*' not in decl):
        kind = 'int'
    else:
        kind = 'obj'
    r = subprocess.run([f'{tmp}/p', binary, name, kind], capture_output=True, text=True).stdout.strip()
    if r.startswith('STR ') and (decl or (name[0] != '$' and '\\u' not in r)):
        lines.append(f'NSString *const {name} = @"{r[4:]}";')
    elif r.startswith('DOUBLE '):
        v = r[7:]
        v = {'inf': 'INFINITY', '-inf': '-INFINITY'}.get(v, v)
        lines.append(f'const double {name} = {v};')
    elif r.startswith('FLOAT '):
        lines.append(f'const float {name} = {r[6:]}f;')
    elif r.startswith('INT64 '):
        lines.append(f'const int64_t {name} = {r[6:]}LL;')
    elif r.startswith('INT '):
        lines.append(f'const int {name} = {r[4:]};')
    else:
        print(f'skipped {name} ({decl}): {r or "crashed"}', file=sys.stderr)
open(out, 'w').write('\n'.join(lines) + '\n')
print(f'{out}: {len(lines) - 4} constants', file=sys.stderr)
