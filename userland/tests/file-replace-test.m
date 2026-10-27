/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-file-replace-test: -[NSFileManager replaceItemAtURL:withItemAtURL:backupItemName:options:resultingItemURL:error:],
 * compared with Apple's on the host: the new item takes the original's place and is used up, the
 * original's permissions are kept unless the new item's are asked for, a backup is left only when
 * asked for, a missing original is no obstacle and a missing new item is an error.
 */
#import <Foundation/Foundation.h>
#include <sys/stat.h>
static NSString *dir;
static NSURL *U(NSString *n){ return [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:n]]; }
static void put(NSString *n, NSString *text, int mode){ [text writeToURL:U(n) atomically:NO encoding:4 error:nil]; chmod(U(n).fileSystemRepresentation, mode); }
static NSString *rd(NSString *n){ return [NSString stringWithContentsOfURL:U(n) encoding:4 error:nil] ?: @"(none)"; }
static int mode(NSString *n){ struct stat st; return stat(U(n).fileSystemRepresentation,&st)==0 ? st.st_mode & 0777 : -1; }
static void run(const char *label, NSString *bak, NSUInteger opts){
  NSFileManager *fm=[NSFileManager defaultManager]; NSURL *res=nil; NSError *e=nil;
  BOOL ok=[fm replaceItemAtURL:U(@"orig.txt") withItemAtURL:U(@"new.txt") backupItemName:bak options:opts resultingItemURL:&res error:&e];
  printf("%s: ok %d res %s err %s/%ld | orig=%s mode %o | new=%s | bak=%s\n",label,ok,res.lastPathComponent.UTF8String,e.domain.UTF8String,(long)e.code,rd(@"orig.txt").UTF8String,mode(@"orig.txt"),rd(@"new.txt").UTF8String,bak?rd(bak).UTF8String:"-");
}
int main(void){@autoreleasepool{ dir=[NSTemporaryDirectory() stringByAppendingPathComponent:@"finch-file-replace"]; NSFileManager *fm=[NSFileManager defaultManager];
 [fm removeItemAtPath:dir error:nil]; [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
 put(@"orig.txt",@"old",0600); put(@"new.txt",@"new",0644); run("basic",nil,0);
 put(@"orig.txt",@"old",0600); put(@"new.txt",@"new",0644); run("new metadata",nil,1);
 put(@"orig.txt",@"old",0600); put(@"new.txt",@"new",0644); run("backup kept",@"orig~.txt",2);
 [fm removeItemAtURL:U(@"orig~.txt") error:nil];
 put(@"orig.txt",@"old",0600); put(@"new.txt",@"new",0644); run("backup deleted",@"orig~.txt",0);
 [fm removeItemAtURL:U(@"orig.txt") error:nil]; put(@"new.txt",@"new",0644); run("no original",nil,0);
 put(@"orig.txt",@"old",0600); [fm removeItemAtURL:U(@"new.txt") error:nil]; run("no new",nil,0);
}}
