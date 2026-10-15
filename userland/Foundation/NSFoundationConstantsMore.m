/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Foundation's constants that apps import and Finch had no other place for: metadata
 * query and ubiquitous-item keys, extension keys, linguistic tags, AppleScript and
 * grammar keys, with Apple's values (read from Apple's Foundation). Generated from the
 * import sweep; keep sorted.
 */
#import <Foundation/Foundation.h>

#define FINCH_CONST __attribute__((visibility("default")))

FINCH_CONST NSString *const NSAppleScriptErrorAppName = @"NSAppleScriptErrorAppName";
FINCH_CONST NSString *const NSAppleScriptErrorBriefMessage = @"NSAppleScriptErrorBriefMessage";
FINCH_CONST NSString *const NSAppleScriptErrorMessage = @"NSAppleScriptErrorMessage";
FINCH_CONST NSString *const NSAppleScriptErrorNumber = @"NSAppleScriptErrorNumber";
FINCH_CONST NSString *const NSAppleScriptErrorRange = @"NSAppleScriptErrorRange";
FINCH_CONST NSString *const NSExtensionContainingAppName = @"NSExtensionContainingApp";
FINCH_CONST NSString *const NSExtensionHostDidEnterBackgroundNotification = @"NSExtensionHostDidEnterBackgroundNotification";
FINCH_CONST NSString *const NSExtensionIdentifierName = @"NSExtensionIdentifier";
FINCH_CONST NSString *const NSExtensionPointName = @"NSExtensionPointName";
FINCH_CONST NSString *const NSExtensionPointUIServices = @"com.apple.ui-services";
FINCH_CONST NSString *const NSGrammarCorrections = @"NSGrammarCorrections";
FINCH_CONST NSString *const NSGrammarRange = @"NSGrammarRange";
FINCH_CONST NSString *const NSLanguageIdentifierAttributeName = @"NSLanguage";
FINCH_CONST NSString *const NSLinguisticTagAdjective = @"Adjective";
FINCH_CONST NSString *const NSLinguisticTagAdverb = @"Adverb";
FINCH_CONST NSString *const NSLinguisticTagClassifier = @"Classifier";
FINCH_CONST NSString *const NSLinguisticTagCloseParenthesis = @"CloseParenthesis";
FINCH_CONST NSString *const NSLinguisticTagCloseQuote = @"CloseQuote";
FINCH_CONST NSString *const NSLinguisticTagConjunction = @"Conjunction";
FINCH_CONST NSString *const NSLinguisticTagDash = @"Dash";
FINCH_CONST NSString *const NSLinguisticTagDeterminer = @"Determiner";
FINCH_CONST NSString *const NSLinguisticTagIdiom = @"Idiom";
FINCH_CONST NSString *const NSLinguisticTagInterjection = @"Interjection";
FINCH_CONST NSString *const NSLinguisticTagNoun = @"Noun";
FINCH_CONST NSString *const NSLinguisticTagNumber = @"Number";
FINCH_CONST NSString *const NSLinguisticTagOpenParenthesis = @"OpenParenthesis";
FINCH_CONST NSString *const NSLinguisticTagOpenQuote = @"OpenQuote";
FINCH_CONST NSString *const NSLinguisticTagOrganizationName = @"OrganizationName";
FINCH_CONST NSString *const NSLinguisticTagOther = @"Other";
FINCH_CONST NSString *const NSLinguisticTagOtherPunctuation = @"Punctuation";
FINCH_CONST NSString *const NSLinguisticTagOtherWhitespace = @"Whitespace";
FINCH_CONST NSString *const NSLinguisticTagOtherWord = @"OtherWord";
FINCH_CONST NSString *const NSLinguisticTagParagraphBreak = @"ParagraphBreak";
FINCH_CONST NSString *const NSLinguisticTagParticle = @"Particle";
FINCH_CONST NSString *const NSLinguisticTagPersonalName = @"PersonalName";
FINCH_CONST NSString *const NSLinguisticTagPlaceName = @"PlaceName";
FINCH_CONST NSString *const NSLinguisticTagPreposition = @"Preposition";
FINCH_CONST NSString *const NSLinguisticTagPronoun = @"Pronoun";
FINCH_CONST NSString *const NSLinguisticTagPunctuation = @"Punctuation";
FINCH_CONST NSString *const NSLinguisticTagSchemeLanguage = @"Language";
FINCH_CONST NSString *const NSLinguisticTagSchemeLemma = @"Lemma";
FINCH_CONST NSString *const NSLinguisticTagSchemeLexicalClass = @"LexicalClass";
FINCH_CONST NSString *const NSLinguisticTagSchemeNameType = @"NameType";
FINCH_CONST NSString *const NSLinguisticTagSchemeNameTypeOrLexicalClass = @"NameTypeOrLexicalClass";
FINCH_CONST NSString *const NSLinguisticTagSchemeScript = @"Script";
FINCH_CONST NSString *const NSLinguisticTagSchemeTokenType = @"TokenType";
FINCH_CONST NSString *const NSLinguisticTagSentenceTerminator = @"SentenceTerminator";
FINCH_CONST NSString *const NSLinguisticTagVerb = @"Verb";
FINCH_CONST NSString *const NSLinguisticTagWhitespace = @"Whitespace";
FINCH_CONST NSString *const NSLinguisticTagWord = @"Word";
FINCH_CONST NSString *const NSLinguisticTagWordJoiner = @"WordJoiner";
FINCH_CONST NSString *const NSMetadataItemAcquisitionMakeKey = @"kMDItemAcquisitionMake";
FINCH_CONST NSString *const NSMetadataItemAcquisitionModelKey = @"kMDItemAcquisitionModel";
FINCH_CONST NSString *const NSMetadataItemAlbumKey = @"kMDItemAlbum";
FINCH_CONST NSString *const NSMetadataItemAltitudeKey = @"kMDItemAltitude";
FINCH_CONST NSString *const NSMetadataItemApertureKey = @"kMDItemAperture";
FINCH_CONST NSString *const NSMetadataItemAppleLoopDescriptorsKey = @"kMDItemAppleLoopDescriptors";
FINCH_CONST NSString *const NSMetadataItemAppleLoopsKeyFilterTypeKey = @"kMDItemAppleLoopsKeyFilterType";
FINCH_CONST NSString *const NSMetadataItemAppleLoopsLoopModeKey = @"kMDItemAppleLoopsLoopMode";
FINCH_CONST NSString *const NSMetadataItemAppleLoopsRootKeyKey = @"kMDItemAppleLoopsRootKey";
FINCH_CONST NSString *const NSMetadataItemApplicationCategoriesKey = @"kMDItemApplicationCategories";
FINCH_CONST NSString *const NSMetadataItemAttributeChangeDateKey = @"kMDItemAttributeChangeDate";
FINCH_CONST NSString *const NSMetadataItemAudiencesKey = @"kMDItemAudiences";
FINCH_CONST NSString *const NSMetadataItemAudioBitRateKey = @"kMDItemAudioBitRate";
FINCH_CONST NSString *const NSMetadataItemAudioChannelCountKey = @"kMDItemAudioChannelCount";
FINCH_CONST NSString *const NSMetadataItemAudioEncodingApplicationKey = @"kMDItemAudioEncodingApplication";
FINCH_CONST NSString *const NSMetadataItemAudioSampleRateKey = @"kMDItemAudioSampleRate";
FINCH_CONST NSString *const NSMetadataItemAudioTrackNumberKey = @"kMDItemAudioTrackNumber";
FINCH_CONST NSString *const NSMetadataItemAuthorAddressesKey = @"kMDItemAuthorAddresses";
FINCH_CONST NSString *const NSMetadataItemAuthorEmailAddressesKey = @"kMDItemAuthorEmailAddresses";
FINCH_CONST NSString *const NSMetadataItemAuthorsKey = @"kMDItemAuthors";
FINCH_CONST NSString *const NSMetadataItemBitsPerSampleKey = @"kMDItemBitsPerSample";
FINCH_CONST NSString *const NSMetadataItemCameraOwnerKey = @"kMDItemCameraOwner";
FINCH_CONST NSString *const NSMetadataItemCFBundleIdentifierKey = @"kMDItemCFBundleIdentifier";
FINCH_CONST NSString *const NSMetadataItemCityKey = @"kMDItemCity";
FINCH_CONST NSString *const NSMetadataItemCodecsKey = @"kMDItemCodecs";
FINCH_CONST NSString *const NSMetadataItemColorSpaceKey = @"kMDItemColorSpace";
FINCH_CONST NSString *const NSMetadataItemCommentKey = @"kMDItemComment";
FINCH_CONST NSString *const NSMetadataItemComposerKey = @"kMDItemComposer";
FINCH_CONST NSString *const NSMetadataItemContactKeywordsKey = @"kMDItemContactKeywords";
FINCH_CONST NSString *const NSMetadataItemContainerIdentifierKey = @"NSMetadataItemContainerIdentifierKey";
FINCH_CONST NSString *const NSMetadataItemContentCreationDateKey = @"kMDItemContentCreationDate";
FINCH_CONST NSString *const NSMetadataItemContentModificationDateKey = @"kMDItemContentModificationDate";
FINCH_CONST NSString *const NSMetadataItemContentTypeKey = @"kMDItemContentType";
FINCH_CONST NSString *const NSMetadataItemContentTypeTreeKey = @"kMDItemContentTypeTree";
FINCH_CONST NSString *const NSMetadataItemContributorsKey = @"kMDItemContributors";
FINCH_CONST NSString *const NSMetadataItemCopyrightKey = @"kMDItemCopyright";
FINCH_CONST NSString *const NSMetadataItemCountryKey = @"kMDItemCountry";
FINCH_CONST NSString *const NSMetadataItemCoverageKey = @"kMDItemCoverage";
FINCH_CONST NSString *const NSMetadataItemCreatorKey = @"kMDItemCreator";
FINCH_CONST NSString *const NSMetadataItemDateAddedKey = @"kMDItemDateAdded";
FINCH_CONST NSString *const NSMetadataItemDeliveryTypeKey = @"kMDItemDeliveryType";
FINCH_CONST NSString *const NSMetadataItemDescriptionKey = @"kMDItemDescription";
FINCH_CONST NSString *const NSMetadataItemDirectorKey = @"kMDItemDirector";
FINCH_CONST NSString *const NSMetadataItemDisplayNameKey = @"kMDItemDisplayName";
FINCH_CONST NSString *const NSMetadataItemDownloadedDateKey = @"kMDItemDownloadedDate";
FINCH_CONST NSString *const NSMetadataItemDueDateKey = @"kMDItemDueDate";
FINCH_CONST NSString *const NSMetadataItemDurationSecondsKey = @"kMDItemDurationSeconds";
FINCH_CONST NSString *const NSMetadataItemEditorsKey = @"kMDItemEditors";
FINCH_CONST NSString *const NSMetadataItemEmailAddressesKey = @"kMDItemEmailAddresses";
FINCH_CONST NSString *const NSMetadataItemEncodingApplicationsKey = @"kMDItemEncodingApplications";
FINCH_CONST NSString *const NSMetadataItemExecutableArchitecturesKey = @"kMDItemExecutableArchitectures";
FINCH_CONST NSString *const NSMetadataItemExecutablePlatformKey = @"kMDItemExecutablePlatform";
FINCH_CONST NSString *const NSMetadataItemEXIFGPSVersionKey = @"kMDItemEXIFGPSVersion";
FINCH_CONST NSString *const NSMetadataItemEXIFVersionKey = @"kMDItemEXIFVersion";
FINCH_CONST NSString *const NSMetadataItemExposureModeKey = @"kMDItemExposureMode";
FINCH_CONST NSString *const NSMetadataItemExposureProgramKey = @"kMDItemExposureProgram";
FINCH_CONST NSString *const NSMetadataItemExposureTimeSecondsKey = @"kMDItemExposureTimeSeconds";
FINCH_CONST NSString *const NSMetadataItemExposureTimeStringKey = @"kMDItemExposureTimeString";
FINCH_CONST NSString *const NSMetadataItemFinderCommentKey = @"kMDItemFinderComment";
FINCH_CONST NSString *const NSMetadataItemFlashOnOffKey = @"kMDItemFlashOnOff";
FINCH_CONST NSString *const NSMetadataItemFNumberKey = @"kMDItemFNumber";
FINCH_CONST NSString *const NSMetadataItemFocalLengthKey = @"kMDItemFocalLength";
FINCH_CONST NSString *const NSMetadataItemFontsKey = @"kMDItemFonts";
FINCH_CONST NSString *const NSMetadataItemFSContentChangeDateKey = @"kMDItemFSContentChangeDate";
FINCH_CONST NSString *const NSMetadataItemFSCreationDateKey = @"kMDItemFSCreationDate";
FINCH_CONST NSString *const NSMetadataItemFSNameKey = @"kMDItemFSName";
FINCH_CONST NSString *const NSMetadataItemFSSizeKey = @"kMDItemFSSize";
FINCH_CONST NSString *const NSMetadataItemGenreKey = @"kMDItemGenre";
FINCH_CONST NSString *const NSMetadataItemGPSAreaInformationKey = @"kMDItemGPSAreaInformation";
FINCH_CONST NSString *const NSMetadataItemGPSDateStampKey = @"kMDItemGPSDateStamp";
FINCH_CONST NSString *const NSMetadataItemGPSDestBearingKey = @"kMDItemGPSDestBearing";
FINCH_CONST NSString *const NSMetadataItemGPSDestDistanceKey = @"kMDItemGPSDestDistance";
FINCH_CONST NSString *const NSMetadataItemGPSDestLatitudeKey = @"kMDItemGPSDestLatitude";
FINCH_CONST NSString *const NSMetadataItemGPSDestLongitudeKey = @"kMDItemGPSDestLongitude";
FINCH_CONST NSString *const NSMetadataItemGPSDifferentalKey = @"kMDItemGPSDifferental";
FINCH_CONST NSString *const NSMetadataItemGPSDOPKey = @"kMDItemGPSDOP";
FINCH_CONST NSString *const NSMetadataItemGPSMapDatumKey = @"kMDItemGPSMapDatum";
FINCH_CONST NSString *const NSMetadataItemGPSMeasureModeKey = @"kMDItemGPSMeasureMode";
FINCH_CONST NSString *const NSMetadataItemGPSProcessingMethodKey = @"kMDItemGPSProcessingMethod";
FINCH_CONST NSString *const NSMetadataItemGPSStatusKey = @"kMDItemGPSStatus";
FINCH_CONST NSString *const NSMetadataItemGPSTrackKey = @"kMDItemGPSTrack";
FINCH_CONST NSString *const NSMetadataItemHasAlphaChannelKey = @"kMDItemHasAlphaChannel";
FINCH_CONST NSString *const NSMetadataItemHeadlineKey = @"kMDItemHeadline";
FINCH_CONST NSString *const NSMetadataItemIdentifierKey = @"kMDItemIdentifier";
FINCH_CONST NSString *const NSMetadataItemImageDirectionKey = @"kMDItemImageDirection";
FINCH_CONST NSString *const NSMetadataItemInformationKey = @"kMDItemInformation";
FINCH_CONST NSString *const NSMetadataItemInstantMessageAddressesKey = @"kMDItemInstantMessageAddresses";
FINCH_CONST NSString *const NSMetadataItemInstructionsKey = @"kMDItemInstructions";
FINCH_CONST NSString *const NSMetadataItemIsApplicationManagedKey = @"kMDItemIsApplicationManaged";
FINCH_CONST NSString *const NSMetadataItemIsGeneralMIDISequenceKey = @"kMDItemIsGeneralMIDISequence";
FINCH_CONST NSString *const NSMetadataItemIsLikelyJunkKey = @"kMDItemIsLikelyJunk";
FINCH_CONST NSString *const NSMetadataItemISOSpeedKey = @"kMDItemISOSpeed";
FINCH_CONST NSString *const NSMetadataItemIsUbiquitousKey = @"NSMetadataItemIsUbiquitousKey";
FINCH_CONST NSString *const NSMetadataItemKeySignatureKey = @"kMDItemKeySignature";
FINCH_CONST NSString *const NSMetadataItemKeywordsKey = @"kMDItemKeywords";
FINCH_CONST NSString *const NSMetadataItemKindKey = @"kMDItemKind";
FINCH_CONST NSString *const NSMetadataItemLanguagesKey = @"kMDItemLanguages";
FINCH_CONST NSString *const NSMetadataItemLastUsedDateKey = @"kMDItemLastUsedDate";
FINCH_CONST NSString *const NSMetadataItemLatitudeKey = @"kMDItemLatitude";
FINCH_CONST NSString *const NSMetadataItemLayerNamesKey = @"kMDItemLayerNames";
FINCH_CONST NSString *const NSMetadataItemLensModelKey = @"kMDItemLensModel";
FINCH_CONST NSString *const NSMetadataItemLongitudeKey = @"kMDItemLongitude";
FINCH_CONST NSString *const NSMetadataItemLyricistKey = @"kMDItemLyricist";
FINCH_CONST NSString *const NSMetadataItemMaxApertureKey = @"kMDItemMaxAperture";
FINCH_CONST NSString *const NSMetadataItemMediaTypesKey = @"kMDItemMediaTypes";
FINCH_CONST NSString *const NSMetadataItemMeteringModeKey = @"kMDItemMeteringMode";
FINCH_CONST NSString *const NSMetadataItemMusicalGenreKey = @"kMDItemMusicalGenre";
FINCH_CONST NSString *const NSMetadataItemMusicalInstrumentCategoryKey = @"kMDItemMusicalInstrumentCategory";
FINCH_CONST NSString *const NSMetadataItemMusicalInstrumentNameKey = @"kMDItemMusicalInstrumentName";
FINCH_CONST NSString *const NSMetadataItemNamedLocationKey = @"kMDItemNamedLocation";
FINCH_CONST NSString *const NSMetadataItemNumberOfPagesKey = @"kMDItemNumberOfPages";
FINCH_CONST NSString *const NSMetadataItemOrganizationsKey = @"kMDItemOrganizations";
FINCH_CONST NSString *const NSMetadataItemOrientationKey = @"kMDItemOrientation";
FINCH_CONST NSString *const NSMetadataItemOriginalFormatKey = @"kMDItemOriginalFormat";
FINCH_CONST NSString *const NSMetadataItemOriginalSourceKey = @"kMDItemOriginalSource";
FINCH_CONST NSString *const NSMetadataItemPageHeightKey = @"kMDItemPageHeight";
FINCH_CONST NSString *const NSMetadataItemPageWidthKey = @"kMDItemPageWidth";
FINCH_CONST NSString *const NSMetadataItemParticipantsKey = @"kMDItemParticipants";
FINCH_CONST NSString *const NSMetadataItemPathKey = @"kMDItemPath";
FINCH_CONST NSString *const NSMetadataItemPerformersKey = @"kMDItemPerformers";
FINCH_CONST NSString *const NSMetadataItemPhoneNumbersKey = @"kMDItemPhoneNumbers";
FINCH_CONST NSString *const NSMetadataItemPixelCountKey = @"kMDItemPixelCount";
FINCH_CONST NSString *const NSMetadataItemPixelHeightKey = @"kMDItemPixelHeight";
FINCH_CONST NSString *const NSMetadataItemPixelWidthKey = @"kMDItemPixelWidth";
FINCH_CONST NSString *const NSMetadataItemProducerKey = @"kMDItemProducer";
FINCH_CONST NSString *const NSMetadataItemProfileNameKey = @"kMDItemProfileName";
FINCH_CONST NSString *const NSMetadataItemProjectsKey = @"kMDItemProjects";
FINCH_CONST NSString *const NSMetadataItemPublishersKey = @"kMDItemPublishers";
FINCH_CONST NSString *const NSMetadataItemRecipientAddressesKey = @"kMDItemRecipientAddresses";
FINCH_CONST NSString *const NSMetadataItemRecipientEmailAddressesKey = @"kMDItemRecipientEmailAddresses";
FINCH_CONST NSString *const NSMetadataItemRecipientsKey = @"kMDItemRecipients";
FINCH_CONST NSString *const NSMetadataItemRecordingDateKey = @"kMDItemRecordingDate";
FINCH_CONST NSString *const NSMetadataItemRecordingYearKey = @"kMDItemRecordingYear";
FINCH_CONST NSString *const NSMetadataItemRedEyeOnOffKey = @"kMDItemRedEyeOnOff";
FINCH_CONST NSString *const NSMetadataItemResolutionHeightDPIKey = @"kMDItemResolutionHeightDPI";
FINCH_CONST NSString *const NSMetadataItemResolutionWidthDPIKey = @"kMDItemResolutionWidthDPI";
FINCH_CONST NSString *const NSMetadataItemRightsKey = @"kMDItemRights";
FINCH_CONST NSString *const NSMetadataItemSecurityMethodKey = @"kMDItemSecurityMethod";
FINCH_CONST NSString *const NSMetadataItemSpeedKey = @"kMDItemSpeed";
FINCH_CONST NSString *const NSMetadataItemStarRatingKey = @"kMDItemStarRating";
FINCH_CONST NSString *const NSMetadataItemStateOrProvinceKey = @"kMDItemStateOrProvince";
FINCH_CONST NSString *const NSMetadataItemStreamableKey = @"kMDItemStreamable";
FINCH_CONST NSString *const NSMetadataItemSubjectKey = @"kMDItemSubject";
FINCH_CONST NSString *const NSMetadataItemTempoKey = @"kMDItemTempo";
FINCH_CONST NSString *const NSMetadataItemTextContentKey = @"kMDItemTextContent";
FINCH_CONST NSString *const NSMetadataItemThemeKey = @"kMDItemTheme";
FINCH_CONST NSString *const NSMetadataItemTimeSignatureKey = @"kMDItemTimeSignature";
FINCH_CONST NSString *const NSMetadataItemTimestampKey = @"kMDItemTimestamp";
FINCH_CONST NSString *const NSMetadataItemTitleKey = @"kMDItemTitle";
FINCH_CONST NSString *const NSMetadataItemTotalBitRateKey = @"kMDItemTotalBitRate";
FINCH_CONST NSString *const NSMetadataItemURLKey = @"kMDItemURL";
FINCH_CONST NSString *const NSMetadataItemVersionKey = @"kMDItemVersion";
FINCH_CONST NSString *const NSMetadataItemVideoBitRateKey = @"kMDItemVideoBitRate";
FINCH_CONST NSString *const NSMetadataItemWhereFromsKey = @"kMDItemWhereFroms";
FINCH_CONST NSString *const NSMetadataItemWhiteBalanceKey = @"kMDItemWhiteBalance";
FINCH_CONST NSString *const NSMetadataQueryAccessibleUbiquitousExternalDocumentsScope = @"NSMetadataQueryAccessibleUbiquitousExternalDocumentsScope";
FINCH_CONST NSString *const NSMetadataQueryDidFinishGatheringNotification = @"NSMetadataQueryDidFinishGatheringNotification";
FINCH_CONST NSString *const NSMetadataQueryDidStartGatheringNotification = @"NSMetadataQueryDidStartGatheringNotification";
FINCH_CONST NSString *const NSMetadataQueryDidUpdateNotification = @"NSMetadataQueryDidUpdateNotification";
FINCH_CONST NSString *const NSMetadataQueryExternalDocumentsScope = @"NSMetadataQueryExternalDocumentsScope";
FINCH_CONST NSString *const NSMetadataQueryGatheringProgressNotification = @"NSMetadataQueryGatheringProgressNotification";
FINCH_CONST NSString *const NSMetadataQueryIndexedLocalComputerScope = @"kMDQueryScopeComputerIndexed";
FINCH_CONST NSString *const NSMetadataQueryIndexedNetworkScope = @"kMDQueryScopeNetworkIndexed";
FINCH_CONST NSString *const NSMetadataQueryLocalComputerScope = @"kMDQueryScopeComputer";
FINCH_CONST NSString *const NSMetadataQueryLocalDocumentsScope = @"NSMetadataQueryLocalDocumentsScope";
FINCH_CONST NSString *const NSMetadataQueryNetworkScope = @"kMDQueryScopeNetwork";
FINCH_CONST NSString *const NSMetadataQueryPerAppExternalDocumentsScope = @"NSMetadataQueryExternalDocumentsScope";
FINCH_CONST NSString *const NSMetadataQueryResultContentRelevanceAttribute = @"NSMetadataQueryResultContentRelevanceAttribute";
FINCH_CONST NSString *const NSMetadataQueryUbiquitousDataScope = @"NSMetadataQueryUbiquitousDataScope";
FINCH_CONST NSString *const NSMetadataQueryUbiquitousDocumentsScope = @"NSMetadataQueryUbiquitousDocumentsScope";
FINCH_CONST NSString *const NSMetadataQueryUpdateAddedItemsKey = @"kMDQueryUpdateAddedItems";
FINCH_CONST NSString *const NSMetadataQueryUpdateChangedItemsKey = @"kMDQueryUpdateChangedItems";
FINCH_CONST NSString *const NSMetadataQueryUpdateRemovedItemsKey = @"kMDQueryUpdateRemovedItems";
FINCH_CONST NSString *const NSMetadataQueryUserHomeScope = @"kMDQueryScopeHome";
FINCH_CONST NSString *const NSMetadataUbiquitousItemContainerDisplayNameKey = @"NSMetadataUbiquitousItemContainerDisplayNameKey";
FINCH_CONST NSString *const NSMetadataUbiquitousItemDownloadingErrorKey = @"NSMetadataUbiquitousItemDownloadingErrorKey";
FINCH_CONST NSString *const NSMetadataUbiquitousItemDownloadingStatusCurrent = @"NSMetadataUbiquitousItemDownloadingStatusCurrent";
FINCH_CONST NSString *const NSMetadataUbiquitousItemDownloadingStatusDownloaded = @"NSMetadataUbiquitousItemDownloadingStatusDownloaded";
FINCH_CONST NSString *const NSMetadataUbiquitousItemDownloadingStatusKey = @"NSMetadataUbiquitousItemDownloadingStatusKey";
FINCH_CONST NSString *const NSMetadataUbiquitousItemDownloadingStatusNotDownloaded = @"NSMetadataUbiquitousItemDownloadingStatusNotDownloaded";
FINCH_CONST NSString *const NSMetadataUbiquitousItemDownloadRequestedKey = @"NSMetadataUbiquitousItemDownloadRequestedKey";
FINCH_CONST NSString *const NSMetadataUbiquitousItemHasUnresolvedConflictsKey = @"NSMetadataUbiquitousItemHasUnresolvedConflictsKey";
FINCH_CONST NSString *const NSMetadataUbiquitousItemIsDownloadedKey = @"NSMetadataUbiquitousItemIsDownloadedKey";
FINCH_CONST NSString *const NSMetadataUbiquitousItemIsDownloadingKey = @"NSMetadataUbiquitousItemIsDownloadingKey";
FINCH_CONST NSString *const NSMetadataUbiquitousItemIsExternalDocumentKey = @"NSMetadataUbiquitousItemIsExternalDocumentKey";
FINCH_CONST NSString *const NSMetadataUbiquitousItemIsSharedKey = @"NSMetadataUbiquitousItemIsSharedKey";
FINCH_CONST NSString *const NSMetadataUbiquitousItemIsUploadedKey = @"NSMetadataUbiquitousItemIsUploadedKey";
FINCH_CONST NSString *const NSMetadataUbiquitousItemIsUploadingKey = @"NSMetadataUbiquitousItemIsUploadingKey";
FINCH_CONST NSString *const NSMetadataUbiquitousItemPercentDownloadedKey = @"NSMetadataUbiquitousItemPercentDownloadedKey";
FINCH_CONST NSString *const NSMetadataUbiquitousItemPercentUploadedKey = @"NSMetadataUbiquitousItemPercentUploadedKey";
FINCH_CONST NSString *const NSMetadataUbiquitousItemUploadingErrorKey = @"NSMetadataUbiquitousItemUploadingErrorKey";
FINCH_CONST NSString *const NSMetadataUbiquitousItemURLInLocalContainerKey = @"NSMetadataUbiquitousItemURLInLocalContainerKey";
FINCH_CONST NSString *const NSMetadataUbiquitousSharedItemCurrentUserPermissionsKey = @"NSMetadataUbiquitousSharedItemCurrentUserPermissionsKey";
FINCH_CONST NSString *const NSMetadataUbiquitousSharedItemCurrentUserRoleKey = @"NSMetadataUbiquitousSharedItemCurrentUserRoleKey";
FINCH_CONST NSString *const NSMetadataUbiquitousSharedItemMostRecentEditorNameComponentsKey = @"NSMetadataUbiquitousSharedItemMostRecentEditorNameComponentsKey";
FINCH_CONST NSString *const NSMetadataUbiquitousSharedItemOwnerNameComponentsKey = @"NSMetadataUbiquitousSharedItemOwnerNameComponentsKey";
FINCH_CONST NSString *const NSMetadataUbiquitousSharedItemOwnerNameKey = @"NSMetadataUbiquitousSharedItemOwnerNameKey";
FINCH_CONST NSString *const NSMetadataUbiquitousSharedItemPermissionsKey = @"NSMetadataUbiquitousSharedItemPermissionsKey";
FINCH_CONST NSString *const NSMetadataUbiquitousSharedItemPermissionsReadOnly = @"NSMetadataUbiquitousSharedItemPermissionsReadOnly";
FINCH_CONST NSString *const NSMetadataUbiquitousSharedItemPermissionsReadWrite = @"NSMetadataUbiquitousSharedItemPermissionsReadWrite";
FINCH_CONST NSString *const NSMetadataUbiquitousSharedItemReadOnlyPermissions = @"NSMetadataUbiquitousSharedItemReadOnlyPermissions";
FINCH_CONST NSString *const NSMetadataUbiquitousSharedItemReadWritePermissions = @"NSMetadataUbiquitousSharedItemReadWritePermissions";
FINCH_CONST NSString *const NSMetadataUbiquitousSharedItemRoleKey = @"NSMetadataUbiquitousSharedItemRoleKey";
FINCH_CONST NSString *const NSMetadataUbiquitousSharedItemRoleOwner = @"NSMetadataUbiquitousSharedItemRoleOwner";
FINCH_CONST NSString *const NSMetadataUbiquitousSharedItemRoleParticipant = @"NSMetadataUbiquitousSharedItemRoleParticipant";
FINCH_CONST NSString *const NSUbiquitousKeyValueStoreChangedKeysKey = @"NSUbiquitousKeyValueStoreChangedKeysKey";
FINCH_CONST NSString *const NSUbiquitousKeyValueStoreChangeReasonKey = @"NSUbiquitousKeyValueStoreChangeReasonKey";
FINCH_CONST NSString *const NSUbiquitousKeyValueStoreDidChangeExternallyNotification = @"NSUbiquitousKeyValueStoreDidChangeExternallyNotification";
FINCH_CONST NSString *const NSUbiquitousUserDefaultsCompletedInitialSyncNotification = @"NSUbiquitousUserDefaultsCompletedInitialSyncNotification";
FINCH_CONST NSString *const NSUbiquitousUserDefaultsDidChangeAccountsNotification = @"NSUbiquitousUserDefaultsDidChangeAccountsNotification";
FINCH_CONST NSString *const NSUbiquitousUserDefaultsNoCloudAccountNotification = @"NSUbiquitousUserDefaultsNoCloudAccountNotification";
FINCH_CONST NSString *const NSUbiquityIdentityDidChangeNotification = @"NSUbiquityIdentityDidChangeNotification";

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
