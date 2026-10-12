/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSItemProvider: registering items, objects, data and files, asking what a provider has,
 * and loading each back, compared with Apple's.
 */
#import <Foundation/Foundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static void
wait_for(dispatch_semaphore_t s)
{
    /* (the run loop turns meanwhile: some completions arrive on the main queue) */
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:5];
    while (dispatch_semaphore_wait(s, DISPATCH_TIME_NOW)) {
        if ([limit timeIntervalSinceNow] < 0) {
            printf("  (timed out)\n");
            return;
        }
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
}

static const char *
kind(id o)
{
    return !o ? "nil" : [o isKindOfClass:[NSData class]] ? "NSData" : [o isKindOfClass:[NSString class]] ? "NSString"
         : [o isKindOfClass:[NSURL class]] ? "NSURL" : "other";
}

static const char *
types(NSArray *a)
{
    return [a componentsJoinedByString:@","].UTF8String;
}

static const char *
err(NSError *e)
{
    return e ? [NSString stringWithFormat:@"%@ %ld", e.domain, (long)e.code].UTF8String : "none";
}

int
main(void)
{
    @autoreleasepool {
        NSItemProvider *empty = [NSItemProvider new];
        printf("empty: [%s] name %s\n", types(empty.registeredTypeIdentifiers), empty.suggestedName.UTF8String);

        /* an object: a string */
        NSItemProvider *s = [[NSItemProvider alloc] initWithObject:@"hello"];
        printf("string: [%s]\n", types(s.registeredTypeIdentifiers));
        printf("  conforms public.text %d public.plain-text %d public.utf8-plain-text %d public.data %d public.image %d\n",
            [s hasItemConformingToTypeIdentifier:@"public.text"], [s hasItemConformingToTypeIdentifier:@"public.plain-text"],
            [s hasItemConformingToTypeIdentifier:@"public.utf8-plain-text"], [s hasItemConformingToTypeIdentifier:@"public.data"],
            [s hasItemConformingToTypeIdentifier:@"public.image"]);
        printf("  can load NSString %d NSURL %d NSAttributedString %d\n", [s canLoadObjectOfClass:[NSString class]],
            [s canLoadObjectOfClass:[NSURL class]], [s canLoadObjectOfClass:[NSAttributedString class]]);
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        NSProgress *p = [s loadObjectOfClass:[NSString class] completionHandler:^(id<NSItemProviderReading> o, NSError *e) {
          printf("  loaded object: %s %s main %d\n", [(id)o description].UTF8String, err(e), [NSThread isMainThread]);
          dispatch_semaphore_signal(done);
        }];
        wait_for(done);
        printf("  progress %d total %lld\n", p != nil, p.totalUnitCount);
        [s loadDataRepresentationForTypeIdentifier:@"public.utf8-plain-text" completionHandler:^(NSData *d, NSError *e) {
          printf("  data: %s %s\n", d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding].UTF8String : "nil", err(e));
          dispatch_semaphore_signal(done);
        }];
        wait_for(done);
        [s loadDataRepresentationForTypeIdentifier:@"public.png" completionHandler:^(NSData *d, NSError *e) {
          printf("  png data: %s %s\n", d ? "data" : "nil", err(e));
          dispatch_semaphore_signal(done);
        }];
        wait_for(done);
        [s loadItemForTypeIdentifier:@"public.utf8-plain-text" options:nil completionHandler:^(id item, NSError *e) {
          printf("  item: %s %s main %d\n", kind(item), err(e), [NSThread isMainThread]);
          dispatch_semaphore_signal(done);
        }];
        wait_for(done);

        /* a URL */
        NSURL *url = [NSURL URLWithString:@"https://example.com/a"];
        NSItemProvider *u = [[NSItemProvider alloc] initWithObject:url];
        printf("url: [%s] can load NSURL %d NSString %d\n", types(u.registeredTypeIdentifiers), [u canLoadObjectOfClass:[NSURL class]],
            [u canLoadObjectOfClass:[NSString class]]);
        [u loadObjectOfClass:[NSURL class] completionHandler:^(id<NSItemProviderReading> o, NSError *e) {
          printf("  url back: %s %s\n", [(id)o description].UTF8String, err(e));
          dispatch_semaphore_signal(done);
        }];
        wait_for(done);
        [u loadObjectOfClass:[NSString class] completionHandler:^(id<NSItemProviderReading> o, NSError *e) {
          printf("  url as string: %s %s\n", [(id)o description].UTF8String, err(e));
          dispatch_semaphore_signal(done);
        }];
        wait_for(done);

        /* initWithItem:typeIdentifier: */
        NSItemProvider *i = [[NSItemProvider alloc] initWithItem:@"item text" typeIdentifier:@"public.plain-text"];
        printf("item: [%s]\n", types(i.registeredTypeIdentifiers));
        [i loadItemForTypeIdentifier:@"public.plain-text" options:nil completionHandler:^(id item, NSError *e) {
          printf("  item back: %s (%s) %s\n", [item description].UTF8String, kind(item), err(e));
          dispatch_semaphore_signal(done);
        }];
        wait_for(done);
        [i loadItemForTypeIdentifier:@"public.jpeg" options:nil completionHandler:^(id item, NSError *e) {
          printf("  jpeg: %s %s\n", item ? "item" : "nil", err(e));
          dispatch_semaphore_signal(done);
        }];
        wait_for(done);

        /* data representations, registered in order */
        NSItemProvider *d = [NSItemProvider new];
        [d registerDataRepresentationForTypeIdentifier:@"public.json" visibility:NSItemProviderRepresentationVisibilityAll
                                           loadHandler:^NSProgress *(void (^completion)(NSData *, NSError *)) {
                                             completion([@"{\"a\":1}" dataUsingEncoding:NSUTF8StringEncoding], nil);
                                             return nil;
                                           }];
        [d registerDataRepresentationForTypeIdentifier:@"public.plain-text" visibility:NSItemProviderRepresentationVisibilityOwnProcess
                                           loadHandler:^NSProgress *(void (^completion)(NSData *, NSError *)) {
                                             completion(nil, [NSError errorWithDomain:@"test" code:7 userInfo:nil]);
                                             return nil;
                                           }];
        d.suggestedName = @"thing";
        printf("data: [%s] name %s\n", types(d.registeredTypeIdentifiers), d.suggestedName.UTF8String);
        printf("  in place [%s] open in place [%s]\n", types([d registeredTypeIdentifiersWithFileOptions:NSItemProviderFileOptionOpenInPlace]),
            types([d registeredTypeIdentifiersWithFileOptions:0]));
        [d loadDataRepresentationForTypeIdentifier:@"public.json" completionHandler:^(NSData *data, NSError *e) {
          printf("  json: %s %s\n", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String, err(e));
          dispatch_semaphore_signal(done);
        }];
        wait_for(done);
        [d loadDataRepresentationForTypeIdentifier:@"public.plain-text" completionHandler:^(NSData *data, NSError *e) {
          printf("  failing: %s %s\n", data ? "data" : "nil", err(e));
          dispatch_semaphore_signal(done);
        }];
        wait_for(done);
        [d loadFileRepresentationForTypeIdentifier:@"public.json" completionHandler:^(NSURL *file, NSError *e) {
          NSString *text = file ? [NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:NULL] : nil;
          printf("  json as file: %s ext %s %s\n", text.UTF8String, file.pathExtension.UTF8String, err(e));
          dispatch_semaphore_signal(done);
        }];
        wait_for(done);

        /* a file */
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"finch-itemprovider.txt"];
        [@"file text" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSItemProvider *f = [[NSItemProvider alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path]];
        printf("file: [%s] name %s\n", types(f.registeredTypeIdentifiers), f.suggestedName.UTF8String);
        [f loadFileRepresentationForTypeIdentifier:@"public.plain-text" completionHandler:^(NSURL *file, NSError *e) {
          printf("  copy: same path %d text %s %s\n", [file.path isEqualToString:path],
              [NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:NULL].UTF8String, err(e));
          dispatch_semaphore_signal(done);
        }];
        wait_for(done);
        [f loadDataRepresentationForTypeIdentifier:@"public.plain-text" completionHandler:^(NSData *data, NSError *e) {
          printf("  file data: %s %s\n", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String, err(e));
          dispatch_semaphore_signal(done);
        }];
        wait_for(done);
        [f loadItemForTypeIdentifier:@"public.plain-text" options:nil completionHandler:^(id item, NSError *e) {
          printf("  file item: %s %s\n", kind(item), err(e));
          dispatch_semaphore_signal(done);
        }];
        wait_for(done);
        NSItemProvider *missing = [[NSItemProvider alloc] initWithContentsOfURL:[NSURL fileURLWithPath:@"/nonexistent/file.txt"]];
        printf("missing file: %s\n", missing ? types(missing.registeredTypeIdentifiers) : "nil");
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];

        /* registered objects and classes */
        NSItemProvider *o = [NSItemProvider new];
        [o registerObject:@"registered" visibility:NSItemProviderRepresentationVisibilityAll];
        [o registerObjectOfClass:[NSURL class] visibility:NSItemProviderRepresentationVisibilityAll
                     loadHandler:^NSProgress *(void (^completion)(id<NSItemProviderWriting>, NSError *)) {
                       completion([NSURL URLWithString:@"https://example.com/b"], nil);
                       return nil;
                     }];
        printf("objects: [%s]\n", types(o.registeredTypeIdentifiers));
        [o loadObjectOfClass:[NSURL class] completionHandler:^(id<NSItemProviderReading> obj, NSError *e) {
          printf("  url: %s %s\n", [(id)obj description].UTF8String, err(e));
          dispatch_semaphore_signal(done);
        }];
        wait_for(done);

        /* content types */
        printf("content types: [%s]\n", types([s.registeredContentTypes valueForKey:@"identifier"]));
        printf("  conforms UTTypeText %d\n", [s registeredContentTypesForOpenInPlace].count == 0);
        NSItemProvider *c = [[NSItemProvider alloc] initWithContentsOfURL:[NSURL fileURLWithPath:@"/etc/hosts"] contentType:UTTypePlainText
                                                         openInPlace:YES coordinated:NO visibility:NSItemProviderRepresentationVisibilityAll];
        printf("hosts: [%s] open in place [%s]\n", types(c.registeredTypeIdentifiers),
            types([c registeredTypeIdentifiersWithFileOptions:NSItemProviderFileOptionOpenInPlace]));
        printf("description: %s\n", [[s description] containsString:@"NSItemProvider"] ? "names the class" : [s description].UTF8String);
        printf("NSString writable [%s]\n", types([NSString writableTypeIdentifiersForItemProvider]));
        printf("NSString readable [%s]\n", types([NSString readableTypeIdentifiersForItemProvider]));
        printf("NSURL writable [%s]\n", types([NSURL writableTypeIdentifiersForItemProvider]));
        printf("NSURL readable [%s]\n", types([NSURL readableTypeIdentifiersForItemProvider]));
        printf("error domain %s\n", NSItemProviderErrorDomain.UTF8String);
    }
    return 0;
}
