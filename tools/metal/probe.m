/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* tools/metal/probe.m: the public Metal classes' declared properties and the values a new
   instance has, on Apple's Metal (tools/metal/gen-descriptors.sh). One class per line in. */
#import <Metal/Metal.h>
#import <objc/runtime.h>
int main(int argc,char**argv){@autoreleasepool{
  NSArray *lines=[[NSString stringWithContentsOfFile:@(argv[1]) encoding:4 error:nil] componentsSeparatedByString:@"\n"];
  for (NSString *l in lines){ if(!l.length) continue;
    NSArray *p=[l componentsSeparatedByString:@" "]; Class c=NSClassFromString(p[0]);
    if(!c){ printf("C\t%s\t%s\tMISSING\n",[p[0] UTF8String],[p[1] UTF8String]); continue; }
    id o=nil; @try{ o=[[c alloc] init]; }@catch(NSException*e){}
    printf("C\t%s\t%s\t%s\t%d\n",[p[0] UTF8String],[p[1] UTF8String],o?"init":"noinit",[c conformsToProtocol:@protocol(NSCopying)]);
    for (Class cc=c; cc && cc!=[NSObject class]; cc=class_getSuperclass(cc)) {
    unsigned n; objc_property_t *props=class_copyPropertyList(cc,&n);
    for(unsigned i=0;i<n;i++){
      const char *name=property_getName(props[i]); const char *attr=property_getAttributes(props[i]);
      NSString *val=@"-";
      if(o){ @try{ id v=[o valueForKey:@(name)];
        if(!v) val=@"nil";
        else if([v isKindOfClass:[NSNumber class]]) val=[NSString stringWithFormat:@"num:%@",v];
        else if([v isKindOfClass:[NSValue class]]){ NSValue *nv=v; NSUInteger sz; NSGetSizeAndAlignment(nv.objCType,&sz,NULL); NSMutableString *h=[NSMutableString string]; unsigned char b[256]; [nv getValue:b size:sz]; for(NSUInteger k=0;k<sz;k++) [h appendFormat:@"%02x",b[k]]; val=[NSString stringWithFormat:@"val:%s:%@",nv.objCType,h]; }
        else if([v isKindOfClass:[NSString class]]) val=[NSString stringWithFormat:@"str:%@",v];
        else if([v isKindOfClass:[NSArray class]]) val=[NSString stringWithFormat:@"arr:%lu",(unsigned long)[v count]];
        else if([v isKindOfClass:[NSDictionary class]]) val=[NSString stringWithFormat:@"dict:%lu",(unsigned long)[v count]];
        else val=[NSString stringWithFormat:@"obj:%s",class_getName([v class])];
      }@catch(NSException *e){ val=@"exc"; } }
      printf("P\t%s\t%s\t%s\t%s\n",name,attr,[val UTF8String],cc==c?"own":class_getName(cc));
    }
    free(props);
    }
  }
}}
