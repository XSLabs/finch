/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Focused comparison for the Foundation APIs added with this change. */
#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <poll.h>
#include <pthread.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

@interface FoundationGapMetricsDelegate : NSObject <NSURLSessionTaskDelegate>
@property (nonatomic, strong) NSURLSessionTaskMetrics *metrics;
@property (nonatomic, strong) dispatch_semaphore_t completed;
@end

@implementation FoundationGapMetricsDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didFinishCollectingMetrics:(NSURLSessionTaskMetrics *)metrics
{
    self.metrics = metrics;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    dispatch_semaphore_signal(self.completed);
}
@end

static int metricsListener = -1;

static void *
serveMetrics(void *unused)
{
    struct pollfd listener = {.fd = metricsListener, .events = POLLIN};
    if (poll(&listener, 1, 5000) <= 0)
        return NULL;
    int client = accept(metricsListener, NULL, NULL);
    if (client >= 0) {
        struct timeval timeout = {5, 0};
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        char request[2048];
        size_t used = 0;
        while (used + 1 < sizeof(request)) {
            ssize_t count = read(client, request + used, sizeof(request) - used - 1);
            if (count <= 0)
                break;
            used += (size_t)count;
            request[used] = '\0';
            if (strstr(request, "\r\n\r\n"))
                break;
        }
        static const char response[] = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 7\r\nConnection: close\r\n\r\nmetrics";
        write(client, response, sizeof(response) - 1);
        shutdown(client, SHUT_WR);
        close(client);
    }
    return NULL;
}

static uint16_t
startMetricsServer(pthread_t *thread)
{
    metricsListener = socket(AF_INET, SOCK_STREAM, 0);
    if (metricsListener < 0)
        return 0;
    int yes = 1;
    setsockopt(metricsListener, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in address = {.sin_len = sizeof(address), .sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    if (bind(metricsListener, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(metricsListener, 1) != 0) {
        close(metricsListener);
        metricsListener = -1;
        return 0;
    }
    socklen_t length = sizeof(address);
    if (getsockname(metricsListener, (struct sockaddr *)&address, &length) != 0 || pthread_create(thread, NULL, serveMetrics, NULL) != 0) {
        close(metricsListener);
        metricsListener = -1;
        return 0;
    }
    return ntohs(address.sin_port);
}

static void
print_date(NSString *label, NSCalendar *calendar, NSDate *date)
{
    NSDateComponents *parts = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay |
                                                  NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond
                                             fromDate:date];
    printf("%s: %ld-%02ld-%02ld %02ld:%02ld:%02ld\n", label.UTF8String, (long)parts.year, (long)parts.month, (long)parts.day,
           (long)parts.hour, (long)parts.minute, (long)parts.second);
}

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        printf("Foundation gaps\n");

        NSByteCountFormatter *bytes = [NSByteCountFormatter new];
        bytes.countStyle = NSByteCountFormatterCountStyleFile;
        bytes.allowedUnits = NSByteCountFormatterUseAll;
        NSMeasurement *byteMeasurement = [[NSMeasurement alloc] initWithDoubleValue:1536 unit:[NSUnitInformationStorage bytes]];
        printf("byte count: %s / %s\n", [bytes stringFromMeasurement:byteMeasurement].UTF8String,
               [NSByteCountFormatter stringFromMeasurement:byteMeasurement countStyle:NSByteCountFormatterCountStyleFile].UTF8String);

        NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:@"(?<word>f(o)o)" options:0 error:NULL];
        NSTextCheckingResult *regexMatch = [expression firstMatchInString:@"xx foo yy" options:0 range:NSMakeRange(0, 9)];
        NSRange namedRange = [regexMatch rangeWithName:@"word"], captureRange = [regexMatch rangeAtIndex:2];
        NSRange shiftedRange = [[regexMatch resultByAdjustingRangesWithOffset:-2] range];
        NSTextCheckingResult *linkResult = [NSTextCheckingResult linkCheckingResultWithRange:NSMakeRange(1, 3)
                                                                                         URL:[NSURL URLWithString:@"https://example.com"]];
        NSTextCheckingResult *correction = [NSTextCheckingResult correctionCheckingResultWithRange:NSMakeRange(0, 2)
                                                                                  replacementString:@"ok"
                                                                                 alternativeStrings:@[@"yes"]];
        printf("regex captures: %lu %ld %ld / %ld %ld / %ld %ld\n", (unsigned long)regexMatch.numberOfRanges,
               (long)regexMatch.range.location, (long)regexMatch.range.length, (long)namedRange.location, (long)namedRange.length,
               (long)captureRange.location, (long)captureRange.length);
        printf("regex results: %ld %ld / %d %s / %s\n", (long)shiftedRange.location, (long)shiftedRange.length,
               linkResult.resultType == NSTextCheckingTypeLink, linkResult.URL.absoluteString.UTF8String,
               correction.alternativeStrings.firstObject.UTF8String);

        NSUserActivity *activity = [[NSUserActivity alloc] initWithActivityType:@"org.finch.foundation-gaps"];
        activity.title = @"A document";
        activity.userInfo = @{ @"document" : @"one" };
        [activity addUserInfoEntriesFromDictionary:@{ @"selection" : @4 }];
        activity.requiredUserInfoKeys = [NSSet setWithObject:@"document"];
        activity.keywords = [NSSet setWithObjects:@"notes", @"draft", nil];
        activity.webpageURL = [NSURL URLWithString:@"https://example.com/document"];
        activity.referrerURL = [NSURL URLWithString:@"https://example.com/"];
        activity.targetContentIdentifier = @"document-one";
        activity.expirationDate = [NSDate dateWithTimeIntervalSince1970:100];
        activity.needsSave = YES;
        activity.supportsContinuationStreams = YES;
        activity.eligibleForHandoff = YES;
        activity.eligibleForSearch = YES;
        activity.eligibleForPublicIndexing = NO;
        printf("user activity: %s %s %lu %d %d %d %d %d %s\n", activity.activityType.UTF8String,
               activity.title.UTF8String, (unsigned long)activity.userInfo.count, activity.needsSave,
               activity.supportsContinuationStreams, activity.eligibleForHandoff, activity.eligibleForSearch,
               activity.eligibleForPublicIndexing, activity.targetContentIdentifier.UTF8String);

        NSMutableAttributedString *localizedAppend = [[NSMutableAttributedString alloc] initWithString:@"kept "];
        NSAttributedString *localizedFormat = [[NSAttributedString alloc] initWithString:@"%@"
                                                                              attributes:@{@"FinchLocalizedFormatAttribute" : @"format"}];
        [localizedAppend appendLocalizedFormat:localizedFormat, @"value"];
        id localizedFormatAttribute = [localizedAppend attribute:@"FinchLocalizedFormatAttribute" atIndex:5 effectiveRange:NULL];
        printf("localized append: %s %d\n", localizedAppend.string.UTF8String, [localizedFormatAttribute isEqual:@"format"]);

        NSString *lockDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
        [[NSFileManager defaultManager] createDirectoryAtPath:lockDirectory withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *lockPath = [lockDirectory stringByAppendingPathComponent:@"shared.lock"];
        NSDistributedLock *firstLock = [[NSDistributedLock alloc] initWithPath:lockPath];
        NSDistributedLock *secondLock = [[NSDistributedLock alloc] initWithPath:lockPath];
        BOOL firstLockAcquired = [firstLock tryLock];
        BOOL lockDateExists = firstLock.lockDate != nil;
        BOOL secondLockBlocked = ![secondLock tryLock];
        BOOL secondLockDateWhileBlocked = secondLock.lockDate != nil;
        [firstLock unlock];
        BOOL firstLockDateAfterUnlock = firstLock.lockDate != nil;
        BOOL secondLockAcquired = [secondLock tryLock];
        [secondLock breakLock];
        BOOL secondLockDateAfterBreak = secondLock.lockDate != nil;
        NSDistributedLock *freshLock = [[NSDistributedLock alloc] initWithPath:lockPath];
        BOOL freshLockDateAfterBreak = freshLock.lockDate != nil;
        BOOL firstLockRetaken = [firstLock tryLock];
        NSDistributedLock *breaker = [[NSDistributedLock alloc] initWithPath:lockPath];
        [breaker breakLock];
        BOOL secondLockAfterBreak = [secondLock tryLock];
        if (secondLockAfterBreak)
            [secondLock unlock];
        else
            [firstLock unlock];
        printf("distributed lock: %d %d %d %d %d %d %d %d %d %d\n", firstLockAcquired, lockDateExists, secondLockBlocked,
               secondLockDateWhileBlocked, firstLockDateAfterUnlock, secondLockAcquired, secondLockDateAfterBreak,
               freshLockDateAfterBreak, firstLockRetaken, secondLockAfterBreak);
        [[NSFileManager defaultManager] removeItemAtPath:lockDirectory error:NULL];

        NSLocale *locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        NSNumberFormatter *numberFormatter = [NSNumberFormatter new];
        numberFormatter.locale = locale;

        NSLengthFormatter *length = [NSLengthFormatter new];
        length.numberFormatter = numberFormatter;
        length.unitStyle = NSFormattingUnitStyleLong;
        NSLengthFormatterUnit usedLengthUnit = NSLengthFormatterUnitMeter;
        NSString *lengthUnit = [length unitStringFromMeters:1234 usedUnit:&usedLengthUnit];
        printf("length: %s / %s / %ld\n", [length stringFromMeters:1234].UTF8String,
               [length stringFromValue:12 unit:NSLengthFormatterUnitFoot].UTF8String, (long)usedLengthUnit);
        printf("length unit: %s\n", lengthUnit.UTF8String);
        for (NSNumber *meters in @[@4.3, @100, @500, @1000, @1234, @1609, @2000]) {
            NSLengthFormatterUnit unit = NSLengthFormatterUnitMeter;
            NSString *unitName = [length unitStringFromMeters:meters.doubleValue usedUnit:&unit];
            printf("length scale %.1f: %s / %ld / %s\n", meters.doubleValue,
                   [length stringFromMeters:meters.doubleValue].UTF8String, (long)unit, unitName.UTF8String);
        }
        length.forPersonHeightUse = YES;
        NSLengthFormatterUnit personUnit = NSLengthFormatterUnitMeter;
        NSString *personUnitName = [length unitStringFromMeters:4.3 usedUnit:&personUnit];
        printf("person height: %s / %s / %ld / %s\n", [length stringFromMeters:4.3].UTF8String,
               [length stringFromMeters:1234].UTF8String, (long)personUnit, personUnitName.UTF8String);
        length.forPersonHeightUse = NO;
        NSNumberFormatter *metricNumbers = [NSNumberFormatter new];
        metricNumbers.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"fr_FR"];
        NSLengthFormatter *metricLength = [NSLengthFormatter new];
        metricLength.numberFormatter = metricNumbers;
        metricLength.unitStyle = NSFormattingUnitStyleLong;
        printf("metric length: %s / %s\n", [metricLength stringFromMeters:1.75].UTF8String,
               [metricLength stringFromMeters:1234].UTF8String);
        metricLength.forPersonHeightUse = YES;
        printf("metric person height: %s\n", [metricLength stringFromMeters:1.75].UTF8String);

        NSMassFormatter *mass = [NSMassFormatter new];
        mass.numberFormatter = numberFormatter;
        mass.unitStyle = NSFormattingUnitStyleLong;
        NSMassFormatterUnit usedMassUnit = NSMassFormatterUnitKilogram;
        NSString *massUnit = [mass unitStringFromKilograms:72 usedUnit:&usedMassUnit];
        printf("mass: %s / %s / %ld\n", [mass stringFromKilograms:72].UTF8String,
               [mass stringFromValue:2 unit:NSMassFormatterUnitPound].UTF8String, (long)usedMassUnit);
        printf("mass unit: %s\n", massUnit.UTF8String);

        NSEnergyFormatter *energy = [NSEnergyFormatter new];
        energy.numberFormatter = numberFormatter;
        energy.unitStyle = NSFormattingUnitStyleLong;
        NSEnergyFormatterUnit usedEnergyUnit = NSEnergyFormatterUnitJoule;
        NSString *energyUnit = [energy unitStringFromJoules:16000 usedUnit:&usedEnergyUnit];
        printf("energy: %s / %s / %ld\n", [energy stringFromJoules:16000].UTF8String,
               [energy stringFromValue:2 unit:NSEnergyFormatterUnitKilocalorie].UTF8String, (long)usedEnergyUnit);
        printf("energy unit: %s\n", energyUnit.UTF8String);
        energy.forFoodEnergyUse = YES;
        NSEnergyFormatterUnit foodUnit = NSEnergyFormatterUnitJoule;
        NSString *foodUnitName = [energy unitStringFromJoules:16000 usedUnit:&foodUnit];
        printf("food energy: %s / %ld / %s\n", [energy stringFromJoules:16000].UTF8String, (long)foodUnit, foodUnitName.UTF8String);

        NSCalendar *calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
        calendar.locale = locale;
        calendar.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        NSDateComponents *parts = [NSDateComponents new];
        parts.year = 2024;
        parts.month = 2;
        parts.day = 28;
        parts.hour = 10;
        parts.minute = 15;
        NSDate *date = [calendar dateFromComponents:parts];
        NSDateComponents *newComponents = [NSDateComponents new];
        newComponents.dayOfYear = 59;
        newComponents.repeatedDay = YES;
        printf("calendar component values: %ld %d %ld\n", (long)newComponents.dayOfYear, newComponents.isRepeatedDay,
               (long)[calendar component:NSCalendarUnitDayOfYear fromDate:date]);
        NSDate *nextDay = [calendar dateBySettingUnit:NSCalendarUnitDay value:29 ofDate:date options:0];
        NSDate *sameDayLater = [date dateByAddingTimeInterval:3600];
        NSDateComponents *match = [NSDateComponents new];
        match.month = 2;
        match.day = 28;
        printf("calendar: %ld %d %d\n", (long)[calendar compareDate:date toDate:sameDayLater toUnitGranularity:NSCalendarUnitDay],
               [calendar date:date matchesComponents:match], [calendar date:nextDay matchesComponents:match]);
        printf("calendar equal day: %d\n", [calendar isDate:date equalToDate:sameDayLater toUnitGranularity:NSCalendarUnitDay]);
        print_date(@"calendar next day", calendar, nextDay);
        NSDate *nextHour = [calendar nextDateAfterDate:date matchingHour:11 minute:0 second:0 options:0];
        print_date(@"calendar next hour", calendar, nextHour);
        NSDate *nextMonthStart = [calendar nextDateAfterDate:date matchingUnit:NSCalendarUnitDay value:1 options:NSCalendarMatchNextTime];
        print_date(@"calendar next unit", calendar, nextMonthStart);
        NSDateComponents *weekend = [NSDateComponents new];
        weekend.weekday = 7;
        NSDate *nextMatch = [calendar nextDateAfterDate:date matchingComponents:weekend options:NSCalendarMatchNextTime];
        print_date(@"calendar next match", calendar, nextMatch);
        __block NSDate *enumeratedMatch = nil;
        [calendar enumerateDatesStartingAfterDate:date matchingComponents:weekend options:NSCalendarMatchNextTime
                                        usingBlock:^(NSDate *matchedDate, BOOL exactMatch, BOOL *stop) {
            enumeratedMatch = matchedDate;
            *stop = YES;
        }];
        print_date(@"calendar enumerated", calendar, enumeratedMatch);
        NSInteger era, year, month, day, weekYear, weekNumber, weekday, hour, minute, second, nanosecond;
        [calendar getEra:&era year:&year month:&month day:&day fromDate:date];
        [calendar getEra:&era yearForWeekOfYear:&weekYear weekOfYear:&weekNumber weekday:&weekday fromDate:date];
        [calendar getHour:&hour minute:&minute second:&second nanosecond:&nanosecond fromDate:date];
        printf("calendar fields: %ld %ld %ld %ld / %ld %ld %ld / %ld:%ld:%ld.%ld\n", (long)year, (long)month, (long)day,
               (long)era, (long)weekYear, (long)weekNumber, (long)weekday, (long)hour, (long)minute, (long)second, (long)nanosecond);
        NSDate *weekDate = [calendar dateWithEra:era yearForWeekOfYear:weekYear weekOfYear:weekNumber weekday:weekday
                                            hour:hour minute:minute second:second nanosecond:nanosecond];
        print_date(@"calendar week date", calendar, weekDate);
        NSDateComponents *finishParts = [NSDateComponents new];
        finishParts.year = 2024;
        finishParts.month = 3;
        finishParts.day = 2;
        finishParts.hour = 10;
        finishParts.minute = 15;
        NSDateComponents *dateDifference = [calendar components:NSCalendarUnitDay fromDateComponents:parts
                                               toDateComponents:finishParts options:0];
        printf("calendar components difference: %ld\n", (long)dateDifference.day);
        NSDate *weekendStart = nil;
        NSTimeInterval weekendLength = 0;
        BOOL hasWeekend = [calendar nextWeekendStartDate:&weekendStart interval:&weekendLength options:0 afterDate:date];
        printf("calendar weekend: %d %.0f\n", hasWeekend, weekendLength);
        print_date(@"calendar weekend start", calendar, weekendStart);
        NSDate *weekendRangeStart = nil;
        NSTimeInterval weekendRangeLength = 0;
        BOOL hasWeekendRange = [calendar rangeOfWeekendStartDate:&weekendRangeStart interval:&weekendRangeLength containingDate:weekendStart];
        printf("calendar weekend range: %d %.0f\n", hasWeekendRange, weekendRangeLength);
        print_date(@"calendar weekend range start", calendar, weekendRangeStart);

        NSAttributedStringMarkdownParsingOptions *options = [NSAttributedStringMarkdownParsingOptions new];
        options.languageCode = @"en";
        options.appliesSourcePositionAttributes = YES;
        NSAttributedStringMarkdownParsingOptions *copiedOptions = [options copy];
        printf("markdown options: %ld %ld %d %d %s\n", (long)options.interpretedSyntax, (long)options.failurePolicy,
               options.allowsExtendedAttributes, copiedOptions.appliesSourcePositionAttributes, copiedOptions.languageCode.UTF8String);
        NSAttributedStringMarkdownSourcePosition *position = [[NSAttributedStringMarkdownSourcePosition alloc]
            initWithStartLine:1 startColumn:2 endLine:1 endColumn:3];
        NSRange sourceRange = [position rangeInString:@"abc\ndef"];
        printf("markdown source: %ld %ld\n", (long)sourceRange.location, (long)sourceRange.length);
        NSPresentationIntent *paragraph = [NSPresentationIntent paragraphIntentWithIdentity:1 nestedInsideIntent:nil];
        NSPresentationIntent *sameParagraph = [NSPresentationIntent paragraphIntentWithIdentity:2 nestedInsideIntent:nil];
        NSPresentationIntent *header = [NSPresentationIntent headerIntentWithIdentity:3 level:2 nestedInsideIntent:paragraph];
        printf("presentation: %ld %ld %ld %d %d\n", (long)header.intentKind, (long)header.headerLevel,
               (long)header.indentationLevel, [paragraph isEquivalentToPresentationIntent:sameParagraph],
               [header isEquivalentToPresentationIntent:paragraph]);
        NSError *archiveError = nil;
        NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:header requiringSecureCoding:YES error:&archiveError];
        NSPresentationIntent *decoded = archive ? [NSKeyedUnarchiver unarchivedObjectOfClass:[NSPresentationIntent class]
                                                                                      fromData:archive error:&archiveError] : nil;
        printf("presentation archive: %d %d\n", decoded != nil, [decoded isEqual:header]);

        NSURL *baseURL = [NSURL URLWithString:@"https://example.com/a/"];
        NSData *urlData = [@"../b?q=x" dataUsingEncoding:NSUTF8StringEncoding];
        NSURL *dataURL = [[NSURL alloc] initWithDataRepresentation:urlData relativeToURL:baseURL];
        NSURL *absoluteDataURL = [NSURL absoluteURLWithDataRepresentation:urlData relativeToURL:baseURL];
        NSURL *schemeURL = [[NSURL alloc] initWithScheme:@"https" host:@"example.com" path:@"/a b"];
        NSURL *encodedURL = [NSURL URLWithString:@"https://example.com/a b?q=x y" encodingInvalidCharacters:YES];
        printf("URL data: %s / %s\n", dataURL.relativeString.UTF8String, absoluteDataURL.absoluteString.UTF8String);
        printf("URL parts: %s / %s\n", schemeURL.absoluteString.UTF8String, encodedURL.absoluteString.UTF8String);

        NSBundle *bundle = [NSBundle bundleForClass:[NSObject class]];
        NSString *fallback = [bundle localizedStringForKey:@"finch-foundation-gaps-unknown" value:@"fallback" table:nil
                                               localizations:@[@"fr", @"en"]];
        NSArray *missingPaths = [bundle pathsForResourcesOfType:@"finch-no-such-resource-type" inDirectory:nil forLocalization:@"en"];
        NSArray *classMissingPaths = [NSBundle pathsForResourcesOfType:@"finch-no-such-resource-type" inDirectory:@""];
        NSURL *missingURL = [NSBundle URLForResource:@"finch-no-such-resource" withExtension:@"none" subdirectory:nil
                                           inBundleWithURL:bundle.bundleURL];
        printf("bundle: %s %lu %lu %d\n", fallback.UTF8String, (unsigned long)missingPaths.count,
               (unsigned long)classMissingPaths.count, missingURL == nil);

        NSString *temporary = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
        NSString *filePath = [temporary stringByAppendingPathComponent:@"source.txt"];
        NSString *hardLinkPath = [temporary stringByAppendingPathComponent:@"linked.txt"];
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSError *fileError = nil;
        [fileManager createDirectoryAtPath:temporary withIntermediateDirectories:YES attributes:nil error:&fileError];
        [@"foundation gaps" writeToFile:filePath atomically:YES encoding:NSUTF8StringEncoding error:&fileError];
        BOOL linked = [fileManager linkItemAtURL:[NSURL fileURLWithPath:filePath] toURL:[NSURL fileURLWithPath:hardLinkPath] error:&fileError];
        NSURLRelationship relationship = NSURLRelationshipOther;
        BOOL related = [fileManager getRelationship:&relationship ofDirectoryAtURL:[NSURL fileURLWithPath:temporary isDirectory:YES]
                                           toItemAtURL:[NSURL fileURLWithPath:hardLinkPath] error:&fileError];
        NSArray *displayParts = [fileManager componentsToDisplayForPath:@"/System/Library"];
        printf("file manager: %d %d %ld %lu\n", linked, related, (long)relationship, (unsigned long)displayParts.count);
        NSURL *libraryDirectory = [NSURL fileURLWithPath:@"/System/Library" isDirectory:YES];
        NSURLRelationship searchRelationship = NSURLRelationshipOther;
        BOOL searchRelated = [fileManager getRelationship:&searchRelationship ofDirectory:NSLibraryDirectory inDomain:NSSystemDomainMask
                                                toItemAtURL:libraryDirectory error:&fileError];
        printf("search path relationship: %d %ld\n", searchRelated, (long)searchRelationship);
        NSArray *volumes = [fileManager mountedVolumeURLsIncludingResourceValuesForKeys:@[NSURLIsVolumeKey]
                                                                                 options:NSVolumeEnumerationSkipHiddenVolumes];
        BOOL includesRootVolume = NO;
        for (NSURL *volume in volumes)
            if ([[volume path] isEqualToString:@"/"]) includesRootVolume = YES;
        printf("mounted volumes include root: %d\n", includesRootVolume);
        NSFileWrapper *wrapper = [[NSFileWrapper alloc] initWithPath:filePath];
        NSString *wrapperPath = [temporary stringByAppendingPathComponent:@"wrapper.txt"];
        BOOL unchanged = ![wrapper needsToBeUpdatedFromPath:filePath];
        BOOL updated = [wrapper updateFromPath:filePath];
        BOOL wroteWrapper = [wrapper writeToFile:wrapperPath atomically:YES updateFilenames:YES];
        NSFileWrapper *linkWrapper = [[NSFileWrapper alloc] initSymbolicLinkWithDestination:@"source.txt"];
        NSFileWrapper *directoryWrapper = [[NSFileWrapper alloc] initDirectoryWithFileWrappers:@{}];
        NSString *addedFile = [directoryWrapper addFileWithPath:filePath];
        NSString *addedLink = [directoryWrapper addSymbolicLinkWithDestination:@"source.txt" preferredFilename:@"link.txt"];
        printf("file wrapper: %d %d %d %d %s %s %s\n", wrapper.isRegularFile, unchanged, updated, wroteWrapper,
               wrapper.regularFileContents.description.UTF8String, linkWrapper.symbolicLinkDestination.UTF8String,
               addedFile.UTF8String);
        printf("file wrapper links: %s %lu\n", addedLink.UTF8String, (unsigned long)directoryWrapper.fileWrappers.count);

        pthread_t metricsServerThread;
        uint16_t metricsPort = startMetricsServer(&metricsServerThread);
        FoundationGapMetricsDelegate *metricsDelegate = [FoundationGapMetricsDelegate new];
        metricsDelegate.completed = dispatch_semaphore_create(0);
        NSURLSession *metricsSession = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]
                                                                      delegate:metricsDelegate delegateQueue:nil];
        NSString *metricsURL = [NSString stringWithFormat:@"http://127.0.0.1:%u/metrics", metricsPort];
        NSURLSessionDataTask *metricsTask = [metricsSession dataTaskWithURL:[NSURL URLWithString:metricsURL]];
        [metricsTask resume];
        BOOL metricsCompleted = metricsPort && dispatch_semaphore_wait(metricsDelegate.completed,
                                                                       dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0;
        NSURLSessionTaskMetrics *taskMetrics = metricsDelegate.metrics;
        NSURLSessionTaskTransactionMetrics *transaction = taskMetrics.transactionMetrics.firstObject;
        printf("session metrics: %d %lu %lu %d %d %d %d %d %d %d %d %d %d %d %d %lu\n", metricsCompleted,
               (unsigned long)taskMetrics.transactionMetrics.count, (unsigned long)taskMetrics.redirectCount,
               taskMetrics.taskInterval != nil, transaction.request != nil, transaction.response != nil,
               transaction.fetchStartDate != nil, transaction.connectStartDate != nil, transaction.connectEndDate != nil,
               transaction.requestStartDate != nil, transaction.requestEndDate != nil, transaction.responseStartDate != nil,
               transaction.responseEndDate != nil, transaction.countOfRequestHeaderBytesSent > 0,
               transaction.countOfResponseBodyBytesReceived > 0, (unsigned long)transaction.resourceFetchType);
        [metricsSession invalidateAndCancel];
        if (metricsPort) {
            pthread_join(metricsServerThread, NULL);
            close(metricsListener);
            metricsListener = -1;
        }
        [fileManager removeItemAtPath:temporary error:NULL];
    }
    return 0;
}
