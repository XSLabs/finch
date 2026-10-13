/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * osascript: Finch's, over the OSA calls. Runs -e lines, a script file or standard input;
 * arguments after the script go to its run handler. -s h (human-readable, the default) or
 * s (source form) for the result, -s e / o for where errors go; -l names the language
 * (AppleScript is the one there is); -i is accepted.
 */
#import <Carbon/Carbon.h>
#import <Foundation/Foundation.h>

static NSString *
text_of(const AEDesc *d)
{
    Size n = AEGetDescDataSize(d);
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)n];
    AEGetDescData(d, data.mutableBytes, n);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

static void
usage(void)
{
    fprintf(stderr, "usage: osascript [-l language] [-e statement | programfile] [argument ...]\n");
    exit(1);
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        NSMutableString *source = nil;
        NSString *file = nil;
        BOOL human = YES, errorsToStdout = NO;
        int i = 1;
        for (; i < argc; i++) {
            const char *a = argv[i];
            if (!strcmp(a, "-e") && i + 1 < argc) {
                if (!source)
                    source = [NSMutableString string];
                [source appendFormat:@"%@\n", [NSString stringWithUTF8String:argv[++i]] ?: @""];
            } else if (!strcmp(a, "-s") && i + 1 < argc) {
                for (const char *f = argv[++i]; *f; f++) {
                    if (*f == 's')
                        human = NO;
                    else if (*f == 'h')
                        human = YES;
                    else if (*f == 'o')
                        errorsToStdout = YES;
                    else if (*f == 'e')
                        errorsToStdout = NO;
                }
            } else if (!strcmp(a, "-l") && i + 1 < argc) {
                NSString *lang = [NSString stringWithUTF8String:argv[++i]];
                if ([lang caseInsensitiveCompare:@"AppleScript"] != NSOrderedSame) {
                    fprintf(stderr, "osascript: %s: no such component.\n", lang.UTF8String);
                    return 1;
                }
            } else if (!strcmp(a, "-i")) {
            } else if (!strcmp(a, "--")) {
                i++;
                break;
            } else if (a[0] == '-' && a[1]) {
                usage();
            } else
                break;
        }
        if (!source && i < argc)
            file = [NSString stringWithUTF8String:argv[i++]];
        NSMutableArray *args = [NSMutableArray array];
        for (; i < argc; i++)
            [args addObject:[NSString stringWithUTF8String:argv[i]] ?: @""];

        ComponentInstance ci = OpenDefaultComponent(kOSAComponentType, kAppleScriptSubtype);
        OSAID script = kOSANullScript;
        OSAError err;
        AEDesc data = {typeNull, NULL};
        if (source || !file || [file isEqualToString:@"-"]) {
            if (!source) {
                NSData *in = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
                source = [[NSMutableString alloc] initWithData:in encoding:NSUTF8StringEncoding];
            }
            const char *u = source.UTF8String;
            AECreateDesc(typeUTF8Text, u, (Size)strlen(u), &data);
            err = OSACompile(ci, &data, kOSAModeNull, &script);
        } else {
            NSURL *url = [NSURL fileURLWithPath:file];
            err = OSAGetScriptDataFromURL((__bridge CFURLRef)url, NULL, 0, &data);
            if (err) {
                fprintf(stderr, "osascript: %s: No such file or directory\n", file.UTF8String);
                return 1;
            }
            err = OSALoad(ci, &data, kOSAModeNull, &script);
        }
        AEDisposeDesc(&data);

        OSAID result = kOSANullScript;
        if (!err) {
            /* a run event, with the arguments */
            AppleEvent run = {typeNull, NULL};
            AEDesc list = {typeNull, NULL};
            AECreateAppleEvent(kCoreEventClass, kAEOpenApplication, NULL, kAutoGenerateReturnID, kAnyTransactionID, &run);
            if (args.count) {
                AECreateList(NULL, 0, false, &list);
                for (NSString *s in args) {
                    const char *u = s.UTF8String;
                    AEPutPtr(&list, 0, typeUTF8Text, u, (Size)strlen(u));
                }
                AEPutParamDesc(&run, keyDirectObject, &list);
                AEDisposeDesc(&list);
            }
            err = OSAExecuteEvent(ci, &run, script, kOSAModeNull, &result);
            AEDisposeDesc(&run);
        }
        if (err == errOSAScriptError) {
            AEDesc msg = {typeNull, NULL}, num = {typeNull, NULL}, range = {typeNull, NULL};
            OSAScriptError(ci, kOSAErrorMessage, typeUTF8Text, &msg);
            OSAScriptError(ci, kOSAErrorNumber, typeSInt32, &num);
            OSAScriptError(ci, kOSAErrorRange, typeOSAErrorRange, &range);
            SInt32 n = 0;
            AEGetDescData(&num, &n, sizeof n);
            SInt16 start = 0, end = 0;
            DescType t;
            Size sz;
            AEGetParamPtr(&range, keyOSASourceStart, typeSInt16, &t, &start, sizeof start, &sz);
            AEGetParamPtr(&range, keyOSASourceEnd, typeSInt16, &t, &end, sizeof end, &sz);
            BOOL syntax = script == kOSANullScript;
            NSString *line = [NSString stringWithFormat:@"%@%d:%d: %@: %@ (%d)", file ? [file stringByAppendingString:@":"] : @"", start, end,
                                                        syntax ? @"syntax error" : @"execution error", text_of(&msg), (int)n];
            fprintf(errorsToStdout ? stdout : stderr, "%s\n", line.UTF8String);
            return 1;
        }
        if (err) {
            fprintf(stderr, "osascript: couldn't run the script (%d).\n", (int)err);
            return 1;
        }
        if (result != kOSANullScript) {
            AEDesc text = {typeNull, NULL};
            OSADisplay(ci, result, typeUTF8Text, human ? kOSAModeDisplayForHumans : kOSAModeNull, &text);
            printf("%s\n", text_of(&text).UTF8String);
            AEDisposeDesc(&text);
        }
        return 0;
    }
}
