#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Writes userland/Metal/MTLDescriptors.m: an implementation of each public Metal class,
its properties synthesized from the SDK's declarations (and the private ones Apple's
classes have, where they're plain), its defaults the values tools/metal/probe.m read
from Apple's (taken as data), descriptor arrays, factories and value semantics.

    tools/metal/gen-descriptors.py probe.txt all-headers.h out.m
"""
import re,sys
rows=[l.rstrip('\n').split('\t') for l in open(sys.argv[1])]
hdr=open(sys.argv[2]).read()
classes=[]; cur=None
for r in rows:
    if r[0]=='C':
        cur={'name':r[1],'super':r[2],'init':r[3]=='init','copy':r[4]=='1' if len(r)>4 else False,'props':[]}
        if not any(c['name']==cur['name'] for c in classes): classes.append(cur)
        else: cur={'props':[]}
    elif r[0]=='P' and cur is not None:
        cur['props'].append((r[1],r[2],r[3],r[4] if len(r)>4 else 'own'))
# interface bodies from headers, to know which properties are public and the class methods
def body(name):
    m=re.search(r'@interface\s+'+name+r'\s*:\s*\w+[^\n]*\n(.*?)@end',hdr,re.S)
    return m.group(1) if m else ''
def public_props(name):
    b=body(name); out=set()
    for m in re.finditer(r'@property\s*(\([^)]*\))?[^;]*?\b(\w+)\s*(API_|NS_|MTL_|__|;)',b):
        pass
    for line in re.findall(r'@property[^;]*;',b,re.S):
        line=re.sub(r'\b(API_\w+|NS_\w+|MTL_\w+|__\w+)\s*\([^()]*(\([^()]*\)[^()]*)*\)','',line)
        line=re.sub(r'\b(NS_\w+|MTL_\w+)\b','',line)
        m=re.search(r'(\w+)\s*;',line)
        if m: out.add(m.group(1))
    return out
def factories(name):
    b=body(name); out=[]
    for m in re.finditer(r'\+\s*\(\s*(instancetype|'+name+r'\s*\*)\s*(_Nonnull|nonnull)?\s*\)\s*(\w+)\s*(API_|NS_|MTL_|;)',b):
        out.append(m.group(3))
    return out
def unavailable_init(name):
    return re.search(r'-\s*\(\s*instancetype\s*\)\s*init\s+(NS_UNAVAILABLE|API_UNAVAILABLE)',body(name)) is not None
o=[]
o.append('/* SPDX-License-Identifier: MIT OR Apache-2.0 */')
o.append('/* Metal\'s descriptor and value classes, with the defaults Apple\'s have (generated from')
o.append('   Apple\'s classes\' declared properties and their values, taken as data). */')
o.append('#import "Metal_Finch.h"\n')
for c in classes:
    n=c['name']
    if not re.search(r'@interface\s+'+n+r'\s*:', hdr): continue
    pub=set()
    k=n
    while k and k!='NSObject':
        pub|=public_props(k)
        m=re.search(r'@interface\s+'+k+r'\s*:\s*(\w+)',hdr)
        k=m.group(1) if m else None
    # Apple's private properties on the class itself (simple types): declared here too
    enc={'Q':'NSUInteger','q':'NSInteger','B':'BOOL','c':'BOOL','C':'unsigned char','i':'int','I':'unsigned int','s':'short','S':'unsigned short','f':'float','d':'double'}
    private=[]; seen=set()
    for (pn,attr,val,where) in c['props']:
        if where!='own' or val=='exc' or pn in pub or pn in seen or pn in ('hash','description','debugDescription','superclass'): continue
        t=attr.split(',')[0][1:]
        if t in enc: typ=enc[t]
        elif t.startswith('@"') and not t.startswith('@"<'): typ=t[2:-1]+' *'
        elif t=='@': typ='id'
        else: continue
        if typ.endswith(' *') and not re.search(r'@interface\s+'+typ[:-2]+r'\b',hdr) and typ[:-2] not in ('NSString','NSArray','NSDictionary','NSURL','NSData','NSNumber','NSSet'): typ='id'
        mods=['nonatomic']
        flags=attr.split(',')
        if 'R' in flags: mods.append('readonly')
        if 'C' in flags: mods.append('copy')
        private.append(f'@property ({", ".join(mods)}) {typ}{"" if typ.endswith("*") else " "}{pn};')
        seen.add(pn); pub.add(pn)
    if private:
        o.append(f'@interface {n} ()')
        o.extend(private)
        o.append('@end')
    defaults=[]
    for (pn,attr,val,where) in c['props']:
        if pn not in pub or val in ('-','nil','exc','num:0'): continue
        if val.startswith('num:'):
            v=val[4:]
            if v.lstrip('-').isdigit() and int(v)>2**63-1: v=v+'ULL'
            defaults.append(f'    [self setValue:@({v}) forKey:@"{pn}"];')
        elif val.startswith('val:'):
            _,typ,hx=val.split(':',2)
            if set(hx)<= {'0'}: continue
            bs=', '.join('0x'+hx[i:i+2] for i in range(0,len(hx),2))
            defaults.append(f'    {{ static const unsigned char b[] = {{{bs}}}; [self setValue:[NSValue valueWithBytes:b objCType:"{typ}"] forKey:@"{pn}"]; }}')
        elif val.startswith('obj:'):
            cls=val[4:]
            pubcls=cls[:-8] if cls.endswith('Internal') else cls
            defaults.append(f'    FinchMTLSetNew(self, @"{pn}", @"{pubcls}");')
        elif val.startswith('str:'):
            s=val[4:].replace('\\','\\\\').replace('"','\\"')
            defaults.append(f'    [self setValue:@"{s}" forKey:@"{pn}"];')
        elif val.startswith('arr:'):
            defaults.append(f'    [self setValue:@[] forKey:@"{pn}"];')
        elif val.startswith('dict:'):
            defaults.append(f'    [self setValue:@{{}} forKey:@"{pn}"];')
    o.append(f'@implementation {n}')
    # null_resettable properties: nil puts the default back
    for line in re.findall(r'@property\s*\(([^)]*null_resettable[^)]*)\)\s*([^;]*);',body(n)):
        attrs,decl=line
        decl=re.sub(r'\b(API_\w+|NS_\w+|MTL_\w+)\s*\([^()]*(\([^()]*\)[^()]*)*\)','',decl).strip()
        m=re.match(r'(.*?)\s*\*?\s*(\w+)$',decl.replace('*',' * '))
        if not m: continue
        pname=m.group(2); typ=decl[:decl.rfind(pname)].strip()
        dflt=[p for p in c['props'] if p[0]==pname]
        cls=None
        if dflt and dflt[0][2].startswith('obj:'):
            cls=dflt[0][2][4:]; cls=cls[:-8] if cls.endswith('Internal') else cls
        setter='set'+pname[0].upper()+pname[1:]
        new=f'[[{cls} alloc] init]' if cls else 'nil'
        o.append(f'- (void){setter}:({typ})value {{ _{pname} = value ?: {new}; }}')
    if c['init'] and not unavailable_init(n):
        o.append('- (instancetype)init\n{\n    if (!(self = [super init]))\n        return nil;')
        o.extend(defaults)
        o.append('    return self;\n}')
    if n.endswith('Array'):
        el={'MTLRasterizationRateLayerArray':'MTLRasterizationRateLayerDescriptor','MTLRasterizationRateSampleArray':'NSNumber'}.get(n,n[:-5])
        o.append(f'- (id)objectAtIndexedSubscript:(NSUInteger)i {{ return FinchMTLArrayGet(self, i, @"{el}"); }}')
        store='FinchMTLArrayStore' if n.startswith('MTLRasterizationRate') else 'FinchMTLArraySet'
        o.append(f'- (void)setObject:(id)obj atIndexedSubscript:(NSUInteger)i {{ {store}(self, i, obj); }}')
    for f in factories(n):
        o.append(f'+ (instancetype){f} {{ return [[self alloc] init]; }}')
    if c['copy'] or 'NSCopying' in (re.search(r'@interface\s+'+n+r'\s*:\s*\w+([^\n]*)',hdr).group(1) if re.search(r'@interface\s+'+n+r'\s*:\s*\w+([^\n]*)',hdr) else ''):
        o.append('- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }')
    if re.search(r'@interface\s+'+n+r'\s*:\s*\w+[^\n]*NSSecureCoding',hdr):
        # (handles across processes: there are none to send, so they code as empty)
        o.append('+ (BOOL)supportsSecureCoding { return YES; }')
        o.append('- (void)encodeWithCoder:(NSCoder *)coder {}')
        o.append('- (instancetype)initWithCoder:(NSCoder *)coder { return [super init]; }')
    o.append('- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }')
    o.append('- (NSUInteger)hash { return FinchMTLHash(self); }')
    o.append('@end\n')
open(sys.argv[3],'w').write('\n'.join(o)+'\n')
