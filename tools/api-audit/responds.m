#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
// SPDX-License-Identifier: MIT OR Apache-2.0
// Reads "Class -selector" / "Class +selector" lines on standard input and prints those the
// running frameworks don't answer: asked of a real instance where the class is a cluster
// (Finch and Apple implement those on different subclasses), of the alloc placeholder for
// init methods, and of the class otherwise; "(no class)" when the class is missing.
// Built and run by tools/api-audit.sh, against Apple's frameworks and then Finch's.
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
int main(){ @autoreleasepool{ setvbuf(stdout,0,_IONBF,0); char buf[512]; while(fgets(buf,512,stdin)){ char c[128],s[384]; if(sscanf(buf,"%127s %383s",c,s)!=2) continue; NSString *cls=@(c); Class k=NSClassFromString(cls); if(!k){printf("%s %s (no class)\n",c,s);continue;}
  SEL sel=sel_registerName(s+1); BOOL ok; if(getenv("TRACE")) fprintf(stderr,"%s %s\n",c,s);
  if(s[0]==0x2b) ok=class_respondsToSelector(object_getClass(k),sel); else if (!strncmp(s+1,"init",4)) { id a=[k alloc]; (void)CFBridgingRetain(a); ok=class_respondsToSelector(object_getClass(a),sel) || class_respondsToSelector(k,sel); } else { id o=inst(cls); ok = o ? [o respondsToSelector:sel] : class_respondsToSelector(k,sel); }
  if(!ok) printf("%s %s\n",c,s); } }}
