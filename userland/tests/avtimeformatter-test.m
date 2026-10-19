/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Compare duration formatting with Apple's private AVTimeFormatter. */
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/message.h>

typedef void (*SetInteger)(id, SEL, NSInteger);
typedef void (*SetBool)(id, SEL, BOOL);
typedef void (*SetDouble)(id, SEL, double);
typedef NSString *(*StringForDouble)(id, SEL, double);
typedef NSString *(*StringForTime)(id, SEL, CMTime);
typedef BOOL (*ParseString)(id, SEL, id *, NSString *, NSString **);

int main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        puts("AVFoundation time formatter checks");
        Class formatterClass = NSClassFromString(@"AVTimeFormatter");
        id formatter = [[formatterClass alloc] init];
        printf("class %d selector %d\n", formatterClass != Nil,
            [formatter respondsToSelector:@selector(stringFromSeconds:)]);

        SetInteger setStyle = (SetInteger)objc_msgSend;
        StringForDouble stringFromSeconds = (StringForDouble)objc_msgSend;
        StringForTime stringFromCMTime = (StringForTime)objc_msgSend;
        setStyle(formatter, sel_registerName("setStyle:"), 0);
        printf("style0 %s | %s | %s\n",
            [stringFromSeconds(formatter, sel_registerName("stringFromSeconds:"), 61.2) UTF8String],
            [stringFromSeconds(formatter, sel_registerName("stringFromSeconds:"), -1.2) UTF8String],
            [stringFromSeconds(formatter, sel_registerName("stringFromTimeInterval:"), 3599.8) UTF8String]);

        setStyle(formatter, sel_registerName("setStyle:"), 2);
        printf("style2 %s | %s\n",
            [stringFromSeconds(formatter, sel_registerName("stringFromSeconds:"), 61.2) UTF8String],
            [stringFromSeconds(formatter, sel_registerName("stringFromSeconds:"), -1.2) UTF8String]);

        setStyle(formatter, sel_registerName("setStyle:"), 3);
        printf("style3 %s | %s | %s | %s | %s\n",
            [stringFromSeconds(formatter, sel_registerName("stringFromSeconds:"), 61.2) UTF8String],
            [stringFromSeconds(formatter, sel_registerName("stringFromSeconds:"), 59.9) UTF8String],
            [stringFromSeconds(formatter, sel_registerName("stringFromSeconds:"), 1.5) UTF8String],
            [stringFromCMTime(formatter, sel_registerName("stringFromCMTime:"), CMTimeMake(599, 10)) UTF8String],
            [stringFromCMTime(formatter, sel_registerName("stringFromCMTime:"), kCMTimeInvalid) UTF8String]);
        id objectString = ((id (*)(id, SEL, id))objc_msgSend)(formatter, sel_registerName("stringForObjectValue:"), @1.5);
        id parsedObject = nil;
        NSString *parseError = nil;
        ParseString parseString = (ParseString)objc_msgSend;
        BOOL parsed = parseString(formatter, sel_registerName("getObjectValue:forString:errorDescription:"),
            &parsedObject, @"01:02:03", &parseError);
        printf("object %s parse %d value %s error %s\n", [objectString UTF8String], parsed,
            [[parsedObject description] UTF8String], [[parseError description] UTF8String]);

        SetDouble setTemplate = (SetDouble)objc_msgSend;
        setTemplate(formatter, sel_registerName("setFormatTemplate:"), 1.5);
        SetBool setFullWidth = (SetBool)objc_msgSend;
        setFullWidth(formatter, sel_registerName("setFullWidth:"), YES);
        id copy = [formatter copy];
        printf("copy template %.1f full %d string %s\n",
            [[copy valueForKey:@"formatTemplate"] doubleValue],
            [[copy valueForKey:@"fullWidth"] boolValue],
            [stringFromSeconds(copy, sel_registerName("stringFromSeconds:"), 3661.25) UTF8String]);
    }
    return 0;
}
