#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Every method and property the SDK's public headers declare, by class.

    tools/api-audit/headers.py FRAMEWORK...   ->  "Class -selector" / "Class +selector" lines

Read from the SDK's headers as data (tools/api-audit.sh compares them with what
Apple's and Finch's classes answer at run time)."""
import re,glob,subprocess,sys
sdk=subprocess.run(["xcrun","--show-sdk-path"],capture_output=True,text=True).stdout.strip()
out=set()
for fw in sys.argv[1:]:
    for h in glob.glob(f"{sdk}/System/Library/Frameworks/{fw}.framework/Headers/*.h"):
        t=open(h,errors="ignore").read()
        t=re.sub(r'/\*.*?\*/','',t,flags=re.S); t=re.sub(r'//[^\n]*','',t)
        for blk in re.finditer(r'@interface\s+(\w+)\b(.*?)@end',t,re.S):
            cls=blk.group(1); body=blk.group(2)
            body=re.sub(r'\{[^{}]*\}','',body,count=1) if body.lstrip().startswith((':', '(')) else body
            for m in re.finditer(r'^[ \t]*([-+])\s*\(([^;]*?)\)\s*([^;]+?);',body,re.M):
                sig=re.sub(r'\b(NS_|API_|__|FOUNDATION_|CF_|DEPRECATED|APPKIT_)\w*(\([^()]*(\([^()]*\))*[^()]*\))?','',m.group(3))
                parts=re.findall(r'(\w+)\s*:',sig)
                sel="".join(p+":" for p in parts) if parts else re.match(r'\s*(\w+)',sig).group(1)
                out.add(f"{cls} {m.group(1)}{sel}")
            for m in re.finditer(r'@property\s*(\(([^)]*)\))?([^;]*);',body):
                attrs=m.group(2) or ""; decl=re.sub(r'\b(NS_|API_|__|FOUNDATION_|CF_|DEPRECATED|APPKIT_)\w*(\([^()]*(\([^()]*\))*[^()]*\))?','',m.group(3))
                names=re.findall(r'\**\s*(\w+)\s*(?:,|$)',decl.strip())
                if not names: continue
                name=names[-1]
                pre="+" if re.search(r'\bclass\b',attrs) else "-"
                g=re.search(r'getter\s*=\s*(\w+)',attrs); out.add(f"{cls} {pre}{g.group(1) if g else name}")
                if not re.search(r'\breadonly\b',attrs):
                    s=re.search(r'setter\s*=\s*(\w+:)',attrs); out.add(f"{cls} {pre}{s.group(1) if s else 'set'+name[0].upper()+name[1:]+':'}")
print("\n".join(sorted(out)))
