/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Stable data and coding behavior shared by Apple's and Finch's Intents. */
#import <Foundation/Foundation.h>
#import <Intents/Intents.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

static NSString *
stableDescription(id object)
{
    NSString *description = [object description] ?: @"(nil)";
    NSRegularExpression *addresses = [NSRegularExpression regularExpressionWithPattern:@"0x[0-9a-fA-F]+"
                                                                                  options:0 error:NULL];
    description = [addresses stringByReplacingMatchesInString:description options:0
                                                         range:NSMakeRange(0, description.length)
                                                  withTemplate:@"0xADDR"];
    NSRegularExpression *dates = [NSRegularExpression regularExpressionWithPattern:@"20[0-9]{2}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}"
                                                                            options:0 error:NULL];
    return [dates stringByReplacingMatchesInString:description options:0
                                             range:NSMakeRange(0, description.length)
                                      withTemplate:@"DATE"];
}

static void
printObject(const char *name, id object)
{
    if (!object) {
        printf("%s: (nil)\n", name);
        return;
    }
    BOOL copyable = [object conformsToProtocol:@protocol(NSCopying)];
    id copied = copyable ? [object copy] : nil;
    NSError *error = nil;
    NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:object requiringSecureCoding:YES error:&error];
    id decoded = archive ? [NSKeyedUnarchiver unarchivedObjectOfClass:[object class] fromData:archive error:&error] : nil;
    printf("%s: copyable %d copy-equal %d archive %d decode-equal %d description '%s'\n", name,
           copyable, copyable ? [object isEqual:copied] : -1, archive != nil,
           [object isEqual:decoded],
           stableDescription(object).UTF8String ?: "");
}

static void
printFramework(void)
{
    Dl_info info = {0};
    dladdr((__bridge const void *)objc_getClass("INPerson"), &info);
    printf("framework: %s\n", info.dli_fname ?: "unknown");
}

static int
runStoreCheck(void)
{
    @autoreleasepool {
    const char *configuredHome = getenv("CFFIXED_USER_HOME");
    if (!configuredHome || !configuredHome[0])
        return 2;
    NSString *home = NSHomeDirectory();
    if (![home isEqualToString:[NSString stringWithUTF8String:configuredHome]])
        return 2;
    INAnswerCallIntent *intent = [[INAnswerCallIntent alloc] initWithAudioRoute:INCallAudioRouteUnknown
                                                                 callIdentifier:@"store-check"];
    INInteraction *interaction = [[INInteraction alloc] initWithIntent:intent response:nil];
    interaction.identifier = @"store-check";
    __block NSError *donationError = nil;
    [interaction donateInteractionWithCompletion:^(NSError *error) { donationError = error; }];
    NSString *archive = [[home stringByAppendingPathComponent:@"Library/Finch/Intents"]
        stringByAppendingPathComponent:@"interactions.archive"];
    NSData *data = [NSData dataWithContentsOfFile:archive];
    NSSet *classes = [NSSet setWithObjects:[NSArray class], [NSMutableArray class],
        [NSDictionary class], [NSMutableDictionary class], [NSString class], [NSNumber class],
        [NSDate class], [NSDateInterval class], [INInteraction class], [INAnswerCallIntent class], nil];
    NSError *decodeError = nil;
    NSArray *stored = data ? [NSKeyedUnarchiver unarchivedObjectOfClasses:classes
                                                                  fromData:data error:&decodeError] : nil;
    INInteraction *saved = [stored.firstObject isKindOfClass:[INInteraction class]] ? stored.firstObject : nil;
    BOOL storedOne = stored.count == 1 && [saved.identifier isEqualToString:@"store-check"] &&
        !donationError && !decodeError;
    __block NSError *deletionError = nil;
    [INInteraction deleteAllInteractionsWithCompletion:^(NSError *error) { deletionError = error; }];
    NSData *clearedData = [NSData dataWithContentsOfFile:archive];
    NSError *clearDecodeError = nil;
    NSArray *cleared = clearedData ? [NSKeyedUnarchiver unarchivedObjectOfClasses:classes
                                                                           fromData:clearedData error:&clearDecodeError] : nil;
    BOOL storeCleared = cleared && cleared.count == 0 && !deletionError && !clearDecodeError;
    printf("store count: %lu cleared count: %lu donation error: %ld decode error: %ld delete error: %ld\n",
           (unsigned long)stored.count, (unsigned long)cleared.count, (long)donationError.code,
           (long)decodeError.code, (long)deletionError.code);
    [[NSFileManager defaultManager] removeItemAtPath:[home stringByAppendingPathComponent:@"Library/Finch"]
                                               error:NULL];
    return storedOne && storeCleared ? 0 : 1;
    }
}

int
main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc > 1 && !strcmp(argv[1], "--store-check"))
        return runStoreCheck();
    @autoreleasepool {
        printFramework();

        const unsigned char png[] = {
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
            0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00,
            0x0b, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x60, 0x00, 0x02, 0x00,
            0x00, 0x05, 0x00, 0x01, 0xa5, 0xf6, 0x45, 0x40, 0x00, 0x00, 0x00, 0x00,
            0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82
        };
        NSData *imageData = [NSData dataWithBytes:png length:sizeof(png)];
        INImage *image = [INImage imageWithImageData:imageData];
        INPersonHandle *handle = [[INPersonHandle alloc] initWithValue:@"+14165550123"
                                                                  type:(INPersonHandleType)1
                                                                 label:INPersonHandleLabelHome];
        NSPersonNameComponents *name = [[NSPersonNameComponents alloc] init];
        name.givenName = @"Finch";
        name.familyName = @"User";
        INPerson *person = [[INPerson alloc] initWithPersonHandle:handle nameComponents:name
                                                      displayName:nil image:image
                                                contactIdentifier:@"contact-1"
                                                  customIdentifier:@"person-1"];
        INObject *object = [[INObject alloc] initWithIdentifier:@"object-1" displayString:@"Display"
                                                  subtitleString:@"Subtitle" displayImage:image];
        INSpeakableString *speakable = [[INSpeakableString alloc] initWithVocabularyIdentifier:@"phrase-1"
                                                                                 spokenPhrase:@"hello finch"
                                                                            pronunciationHint:@"finch"];
        INAirline *airline = [[INAirline alloc] initWithName:@"Finch Air" iataCode:@"FC" icaoCode:@"FNC"];
        INFile *file = [INFile fileWithData:[@"intent data" dataUsingEncoding:NSUTF8StringEncoding]
                                   filename:@"note.txt" typeIdentifier:@"public.plain-text"];
        INPaymentMethod *paymentMethod = [INPaymentMethod applePayPaymentMethod];
        INSendMessageAttachment *attachment = [INSendMessageAttachment attachmentWithAudioMessageFile:file];

        INAnswerCallIntent *intent = [[INAnswerCallIntent alloc] initWithAudioRoute:(INCallAudioRoute)0
                                                                    callIdentifier:@"call-1"];
        intent.suggestedInvocationPhrase = @"make a Finch note";
        INAnswerCallIntentResponse *response = [[INAnswerCallIntentResponse alloc]
            initWithCode:(INAnswerCallIntentResponseCode)1 userActivity:nil];
        INBooleanResolutionResult *resolution = [INBooleanResolutionResult successWithResolvedValue:YES];
        NSUserActivity *activity = [[NSUserActivity alloc] initWithActivityType:@"org.finch.intents-test"];
        activity.title = @"Finch action";
        INShortcut *shortcut = [[INShortcut alloc] initWithUserActivity:activity];
        Class relevantClass = NSClassFromString(@"INRelevantShortcut");
        id relevant = nil;
        if (relevantClass && shortcut) {
            SEL initializer = sel_registerName("initWithShortcut:");
            relevant = ((id (*)(id, SEL, id))objc_msgSend)([relevantClass alloc], initializer, shortcut);
        }
        INInteraction *interaction = [[INInteraction alloc] initWithIntent:intent response:response];
        interaction.identifier = @"interaction-1";
        interaction.groupIdentifier = @"group-1";
        interaction.direction = (INInteractionDirection)1;

        printObject("person handle", handle);
        printf("person handle keys: value '%s' type %ld label '%s'\n", handle.value.UTF8String ?: "",
               (long)handle.type, handle.label.UTF8String ?: "");
        printObject("person", person);
        printf("person keys: name '%s' handle '%s' contact '%s' custom '%s'\n",
               person.displayName.UTF8String ?: "", person.personHandle.value.UTF8String ?: "",
               person.contactIdentifier.UTF8String ?: "", person.customIdentifier.UTF8String ?: "");
        printObject("object", object);
        printf("object keys: identifier '%s' display '%s' subtitle '%s' spoken '%s'\n",
               object.identifier.UTF8String ?: "", object.displayString.UTF8String ?: "",
               object.subtitleString.UTF8String ?: "", object.spokenPhrase.UTF8String ?: "");
        printObject("speakable string", speakable);
        printf("speakable keys: vocabulary '%s' phrase '%s' hint '%s'\n",
               speakable.vocabularyIdentifier.UTF8String ?: "", speakable.spokenPhrase.UTF8String ?: "",
               speakable.pronunciationHint.UTF8String ?: "");
        printObject("airline", airline);
        printf("airline keys: name '%s' iata '%s' icao '%s'\n", airline.name.UTF8String ?: "",
               airline.iataCode.UTF8String ?: "", airline.icaoCode.UTF8String ?: "");
        printObject("file", file);
        printf("file keys: name '%s' type '%s' bytes %lu\n", file.filename.UTF8String ?: "",
               file.typeIdentifier.UTF8String ?: "", (unsigned long)file.data.length);
        printf("Apple Pay method: %ld\n", (long)paymentMethod.type);
        printf("audio attachment: %s\n", attachment.audioMessageFile.filename.UTF8String ?: "");
        printf("deferred string: '%s'\n",
               [NSString deferredLocalizedIntentsStringWithFormat:@"Call %@ (%d)", @"Finch", 7].UTF8String ?: "");
        Class focusCenterClass = NSClassFromString(@"INFocusStatusCenter");
        id focusCenter = focusCenterClass ? ((id (*)(id, SEL))objc_msgSend)(focusCenterClass,
            sel_registerName("defaultCenter")) : nil;
        NSInteger focusStatus = focusCenter ? ((NSInteger (*)(id, SEL))objc_msgSend)(focusCenter,
            sel_registerName("authorizationStatus")) : -1;
        id focusStatusObject = focusCenter ? ((id (*)(id, SEL))objc_msgSend)(focusCenter,
            sel_registerName("focusStatus")) : nil;
        printf("Focus authorization status: %ld\n", (long)focusStatus);
        printObject("Focus status", focusStatusObject);
        printf("Focus is active: %s\n", [[focusStatusObject valueForKey:@"isFocused"] description].UTF8String ?: "(nil)");
        __block NSError *voiceShortcutError = nil;
        [[INVoiceShortcutCenter sharedCenter] getAllVoiceShortcutsWithCompletion:^(NSArray *shortcuts, NSError *error) {
            voiceShortcutError = error;
            (void)shortcuts;
        }];
        printf("Voice shortcut error: '%s' code %ld\n", voiceShortcutError.domain.UTF8String ?: "",
               (long)voiceShortcutError.code);
        printObject("intent", intent);
        printf("intent keys: identifier '%s' phrase '%s' image %d\n", intent.callIdentifier.UTF8String ?: "",
               intent.suggestedInvocationPhrase.UTF8String ?: "", [intent keyImage] != nil);
        printObject("intent response", response);
        printf("intent response keys: code %ld activity %d\n", (long)response.code, response.userActivity != nil);
        printObject("boolean resolution", resolution);
        printf("resolution class: %s\n", class_getName([resolution class]));
        printObject("shortcut", shortcut);
        printf("shortcut keys: intent %d activity %d\n", shortcut.intent != nil, shortcut.userActivity != nil);
        printObject("relevant shortcut", relevant);
        printf("relevant shortcut keys: present %d shortcut %d providers %lu\n", relevant != nil,
               [[relevant valueForKey:@"shortcut"] isEqual:shortcut],
               (unsigned long)[[relevant valueForKey:@"relevanceProviders"] count]);
        printObject("interaction", interaction);
        printf("interaction keys: intent %d response %d identifier '%s' group '%s' direction %ld\n",
               interaction.intent != nil, interaction.intentResponse != nil,
               interaction.identifier.UTF8String ?: "", interaction.groupIdentifier.UTF8String ?: "",
               (long)interaction.direction);
        Class preferences = NSClassFromString(@"INPreferences");
        SEL statusSelector = sel_registerName("siriAuthorizationStatus");
        SEL languageSelector = sel_registerName("siriLanguageCode");
        NSInteger status = preferences && class_respondsToSelector(object_getClass(preferences), statusSelector)
            ? ((NSInteger (*)(id, SEL))objc_msgSend)(preferences, statusSelector) : -1;
        NSString *language = preferences && class_respondsToSelector(object_getClass(preferences), languageSelector)
            ? ((id (*)(id, SEL))objc_msgSend)(preferences, languageSelector) : @"";
        printf("Siri status: %ld language '%s'\n", (long)status, language.UTF8String ?: "");
    }
    return 0;
}
