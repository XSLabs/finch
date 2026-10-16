#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <string.h>
// SPDX-License-Identifier: MIT OR Apache-2.0
// Reads class, protocol, property, and selector queries on standard input. For methods it
// asks a real instance where the class is a cluster, an alloc placeholder for init methods,
// and the runtime's instance-method table otherwise; "(no class)" marks a missing class.
// Built and run by tools/api-audit.sh and tools/api-coverage.py.
static id inst(NSString *c){
 NSDictionary *m=@{@"NSArray":@[@1],@"NSMutableArray":[NSMutableArray array],@"NSDictionary":@{@1:@2},@"NSMutableDictionary":[NSMutableDictionary dictionary],@"NSSet":[NSSet setWithObject:@1],@"NSMutableSet":[NSMutableSet set],@"NSOrderedSet":[NSOrderedSet orderedSetWithObject:@1],@"NSMutableOrderedSet":[NSMutableOrderedSet orderedSet],@"NSString":@"x",@"NSMutableString":[NSMutableString string],@"NSData":[NSData dataWithBytes:"a" length:1],@"NSMutableData":[NSMutableData data],@"NSNumber":@1,@"NSValue":[NSValue valueWithRange:NSMakeRange(0,1)],@"NSDate":[NSDate date],@"NSAttributedString":[[NSAttributedString alloc] initWithString:@"x"],@"NSMutableAttributedString":[[NSMutableAttributedString alloc] initWithString:@"x"],@"NSCharacterSet":[NSCharacterSet letterCharacterSet],@"NSURL":[NSURL URLWithString:@"http://a/b"],@"NSError":[NSError errorWithDomain:@"d" code:1 userInfo:nil],@"NSIndexSet":[NSIndexSet indexSetWithIndex:1],@"NSMutableIndexSet":[NSMutableIndexSet indexSet],@"NSLocale":[NSLocale currentLocale],@"NSCalendar":[NSCalendar currentCalendar],@"NSTimeZone":[NSTimeZone localTimeZone],@"NSDecimalNumber":[NSDecimalNumber one],@"NSUUID":[NSUUID UUID],@"NSFileManager":[NSFileManager defaultManager],@"NSBundle":[NSBundle mainBundle],@"NSProcessInfo":[NSProcessInfo processInfo],@"NSUserDefaults":[NSUserDefaults standardUserDefaults],@"NSIndexPath":[NSIndexPath indexPathWithIndex:1],@"NSCountedSet":[NSCountedSet set],@"NSTimer":[NSTimer timerWithTimeInterval:100 repeats:NO block:^(NSTimer*t){}],@"NSHashTable":[NSHashTable weakObjectsHashTable],@"NSMapTable":[NSMapTable strongToStrongObjectsMapTable],@"NSPointerArray":[NSPointerArray strongObjectsPointerArray],@"NSPipe":[NSPipe pipe],@"NSFileHandle":[NSFileHandle fileHandleWithNullDevice],@"NSTask":[NSTask new],@"NSURLSession":[NSURLSession sharedSession],@"NSNumberFormatter":[NSNumberFormatter new],@"NSDateFormatter":[NSDateFormatter new],@"NSFileWrapper":[[NSFileWrapper alloc] initDirectoryWithFileWrappers:@{}],@"NSRunLoop":[NSRunLoop currentRunLoop],@"NSPredicate":[NSPredicate predicateWithValue:YES],@"NSProgress":[NSProgress progressWithTotalUnitCount:1],@"NSPort":[NSPort port],@"NSDateComponents":[NSDateComponents new]};
 id value = m[c];
 if (value) return value;
 Class k = NSClassFromString(c);
 if ([c isEqualToString:@"CSSearchableItemAttributeSet"] || [c isEqualToString:@"CSImportExtension"])
  return [[k alloc] init];
 if ([c isEqualToString:@"NSUserActivity"])
  return ((id (*)(id, SEL, id))objc_msgSend)([k alloc], sel_registerName("initWithActivityType:"), @"org.finch.api-audit");
 return nil; }
static BOOL protocolHasMethod(Protocol *p, SEL selector, BOOL instance) {
 return protocol_getMethodDescription(p, selector, YES, instance).name ||
        protocol_getMethodDescription(p, selector, NO, instance).name;
}

int main(int argc, char **argv){ @autoreleasepool{ setvbuf(stdout,0,_IONBF,0);
 void *image=0; if(argc>1 && !(image=dlopen(argv[1],RTLD_NOW|RTLD_GLOBAL))){ fprintf(stderr,"could not load %s: %s\n",argv[1],dlerror()); return 2; }
 char buf[2048]; while(fgets(buf,sizeof(buf),stdin)){
  char kind[32]={0},c[512]={0},s[768]={0},extra[768]={0};
  int count=sscanf(buf,"%31s %511s %767s %767s",kind,c,s,extra);
  if(count>=2 && kind[0]==0x40){
   BOOL ok=NO; NSString *name=@(c);
   if(!strcmp(kind,"@class")) ok=NSClassFromString(name)!=Nil;
   else if(!strcmp(kind,"@protocol")) ok=objc_getProtocol(c)!=nil;
   else if(!strcmp(kind,"@protocol-method") && count>=3) { Protocol *p=objc_getProtocol(c); ok=p && protocolHasMethod(p,sel_registerName(s+1),s[0]!=0x2b); }
   else if(!strcmp(kind,"@protocol-property") && count>=4) { Protocol *p=objc_getProtocol(c); BOOL instance=extra[0]!=0x2b; ok=p && (protocol_getProperty(p,s,YES,instance) || protocol_getProperty(p,s,NO,instance)); }
   else if(!strcmp(kind,"@symbol")){ char underscored[514]; void *symbol=dlsym(image,c); if(!symbol){ snprintf(underscored,sizeof(underscored),"_%s",c); symbol=dlsym(image,underscored); } ok=symbol!=0; }
   if(!ok){ if(!strcmp(kind,"@class") || !strcmp(kind,"@protocol")) printf("%s %s\n",kind,c); else printf("%s %s %s %s\n",kind,c,s,extra); }
   continue;
  }
  if(sscanf(buf,"%127s %383s",c,s)!=2) continue;
  NSString *cls=@(c); Class k=NSClassFromString(cls); if(!k){printf("%s %s (no class)\n",c,s);continue;}
  SEL sel=sel_registerName(s+1); BOOL ok; if(getenv("TRACE")) fprintf(stderr,"%s %s\n",c,s);
  if(s[0]==0x2b) ok=class_respondsToSelector(object_getClass(k),sel); else if (!strncmp(s+1,"init",4)) { id a=[k alloc]; (void)CFBridgingRetain(a); ok=class_respondsToSelector(object_getClass(a),sel) || class_respondsToSelector(k,sel); } else { id o=inst(cls); ok = o ? [o respondsToSelector:sel] : class_respondsToSelector(k,sel); }
  if(!ok) printf("%s %s\n",c,s);
 }
 }}
