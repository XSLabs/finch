/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Foundation's constants that apps import and Finch had no other place for: metadata
 * query and ubiquitous-item keys, extension keys, linguistic tags, AppleScript and
 * grammar keys, with Apple's values (read from Apple's Foundation). Generated from the
 * import sweep; keep sorted.
 */
#import <Foundation/Foundation.h>

#define FINCH_CONST __attribute__((visibility("default")))

FINCH_CONST NSString *const NSAppleScriptErrorBriefMessage = @"NSAppleScriptErrorBriefMessage";
FINCH_CONST NSString *const NSExtensionContainingAppName = @"NSExtensionContainingApp";
FINCH_CONST NSString *const NSExtensionHostDidEnterBackgroundNotification = @"NSExtensionHostDidEnterBackgroundNotification";
FINCH_CONST NSString *const NSExtensionIdentifierName = @"NSExtensionIdentifier";
FINCH_CONST NSString *const NSExtensionPointName = @"NSExtensionPointName";
FINCH_CONST NSString *const NSExtensionPointUIServices = @"com.apple.ui-services";
FINCH_CONST NSString *const NSGrammarCorrections = @"NSGrammarCorrections";
FINCH_CONST NSString *const NSGrammarRange = @"NSGrammarRange";
FINCH_CONST NSString *const NSLanguageIdentifierAttributeName = @"NSLanguage";
FINCH_CONST NSString *const NSLinguisticTagConjunction = @"Conjunction";
FINCH_CONST NSString *const NSLinguisticTagDeterminer = @"Determiner";
FINCH_CONST NSString *const NSLinguisticTagPreposition = @"Preposition";
FINCH_CONST NSString *const NSLinguisticTagSchemeNameTypeOrLexicalClass = @"NameTypeOrLexicalClass";
FINCH_CONST NSString *const NSMetadataItemPathKey = @"kMDItemPath";
FINCH_CONST NSString *const NSMetadataItemURLKey = @"kMDItemURL";
FINCH_CONST NSString *const NSMetadataQueryDidFinishGatheringNotification = @"NSMetadataQueryDidFinishGatheringNotification";
FINCH_CONST NSString *const NSMetadataQueryDidStartGatheringNotification = @"NSMetadataQueryDidStartGatheringNotification";
FINCH_CONST NSString *const NSMetadataQueryDidUpdateNotification = @"NSMetadataQueryDidUpdateNotification";
FINCH_CONST NSString *const NSMetadataQueryUbiquitousDocumentsScope = @"NSMetadataQueryUbiquitousDocumentsScope";
FINCH_CONST NSString *const NSMetadataQueryUpdateAddedItemsKey = @"kMDQueryUpdateAddedItems";
FINCH_CONST NSString *const NSMetadataQueryUpdateChangedItemsKey = @"kMDQueryUpdateChangedItems";
FINCH_CONST NSString *const NSMetadataQueryUpdateRemovedItemsKey = @"kMDQueryUpdateRemovedItems";
FINCH_CONST NSString *const NSMetadataUbiquitousItemDownloadingStatusCurrent = @"NSMetadataUbiquitousItemDownloadingStatusCurrent";
FINCH_CONST NSString *const NSMetadataUbiquitousItemDownloadingStatusDownloaded = @"NSMetadataUbiquitousItemDownloadingStatusDownloaded";
FINCH_CONST NSString *const NSMetadataUbiquitousItemDownloadingStatusKey = @"NSMetadataUbiquitousItemDownloadingStatusKey";
FINCH_CONST NSString *const NSMetadataUbiquitousItemDownloadingStatusNotDownloaded = @"NSMetadataUbiquitousItemDownloadingStatusNotDownloaded";
FINCH_CONST NSString *const NSMetadataUbiquitousItemHasUnresolvedConflictsKey = @"NSMetadataUbiquitousItemHasUnresolvedConflictsKey";
FINCH_CONST NSString *const NSMetadataUbiquitousItemIsDownloadingKey = @"NSMetadataUbiquitousItemIsDownloadingKey";
FINCH_CONST NSString *const NSMetadataUbiquitousItemIsUploadedKey = @"NSMetadataUbiquitousItemIsUploadedKey";
FINCH_CONST NSString *const NSMetadataUbiquitousItemIsUploadingKey = @"NSMetadataUbiquitousItemIsUploadingKey";
FINCH_CONST NSString *const NSMetadataUbiquitousItemPercentDownloadedKey = @"NSMetadataUbiquitousItemPercentDownloadedKey";
FINCH_CONST NSString *const NSMetadataUbiquitousItemPercentUploadedKey = @"NSMetadataUbiquitousItemPercentUploadedKey";
FINCH_CONST NSString *const NSMetadataUbiquitousItemUploadingErrorKey = @"NSMetadataUbiquitousItemUploadingErrorKey";
FINCH_CONST NSString *const NSUbiquitousKeyValueStoreChangeReasonKey = @"NSUbiquitousKeyValueStoreChangeReasonKey";
FINCH_CONST NSString *const NSUbiquitousKeyValueStoreChangedKeysKey = @"NSUbiquitousKeyValueStoreChangedKeysKey";
FINCH_CONST NSString *const NSUbiquitousKeyValueStoreDidChangeExternallyNotification = @"NSUbiquitousKeyValueStoreDidChangeExternallyNotification";
FINCH_CONST NSString *const NSUbiquityIdentityDidChangeNotification = @"NSUbiquityIdentityDidChangeNotification";

/* (CFNetwork's and Metadata's, which Apple's Foundation re-exports) */
FINCH_CONST NSString *const NSURLProtectionSpaceHTTP = @"http";
FINCH_CONST NSString *const NSMetadataItemPixelHeightKey = @"kMDItemPixelHeight";
FINCH_CONST NSString *const NSMetadataItemPixelWidthKey = @"kMDItemPixelWidth";

#pragma mark - Small functions apps import

#import <objc/runtime.h>

#define FINCH_FUNC __attribute__((visibility("default")))

void *objc_autoreleasePoolPush(void);
void objc_autoreleasePoolPop(void *);

FINCH_FUNC NSString *NSStringFromBOOL(BOOL b) { return b ? @"YES" : @"NO"; }

/* "-[Class selector]" (or "+[...]" for a class), as Apple's exception messages name methods. */
FINCH_FUNC NSString *
_NSFullMethodName(id object, SEL sel)
{
    BOOL meta = object && object_isClass(object);
    Class c = object ? (meta ? (Class)object : object_getClass(object)) : Nil;
    return [NSString stringWithFormat:@"%c[%s %s]", meta ? '+' : '-', c ? class_getName(c) : "nil", sel ? sel_getName(sel) : "(null)"];
}

FINCH_FUNC void *NSAllocateScannedUncollectable(NSUInteger size) { return calloc(1, size); }
FINCH_FUNC void *NSPushAutoreleasePool(NSUInteger capacity) { return objc_autoreleasePoolPush(); }
FINCH_FUNC void NSPopAutoreleasePool(void *token) { objc_autoreleasePoolPop(token); }

/* What an abstract class's method raises when a subclass doesn't define it. */
FINCH_FUNC void
NSRequestConcreteImplementation(id self, SEL cmd, Class absClass)
{
    [NSException raise:NSInvalidArgumentException
                format:@"*** -%s only defined for abstract class.  Define -[%@ %s]!", sel_getName(cmd),
                       NSStringFromClass(object_getClass(self)), sel_getName(cmd)];
}
