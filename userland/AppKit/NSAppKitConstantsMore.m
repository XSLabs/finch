/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AppKit's constants that apps import and Finch had no other place for: notification
 * names, sharing and inspector-bar keys, menu names and private keys, with Apple's
 * values (read from Apple's AppKit). Generated from the import sweep; keep sorted.
 */
#import <AppKit/AppKit.h>

#define FINCH_CONST __attribute__((visibility("default")))

FINCH_CONST NSString *const NSAppearanceNameFunctionRow = @"NSAppearanceNameFunctionRow";
FINCH_CONST NSString *const NSAppleMenuName = @"NSAppleMenu";
FINCH_CONST NSString *NSApplicationShouldBeginSuppressingHighDynamicRangeContentNotification = /* (the SDK declares it without const) */ @"NSApplicationShouldBeginSuppressingHighDynamicRangeContentNotification";
FINCH_CONST NSString *NSApplicationShouldEndSuppressingHighDynamicRangeContentNotification = /* (the SDK declares it without const) */ @"NSApplicationShouldEndSuppressingHighDynamicRangeContentNotification";
FINCH_CONST NSString *const NSControlDidEndContinuousTrackingNotification = @"NSControlDidEndContinuousTrackingNotification";
FINCH_CONST NSString *NSControlTintDidChangeNotification = /* (the SDK declares it without const) */ @"NSControlTintDidChangeNotification";
FINCH_CONST NSString *const NSControlWillBeginContinuousTrackingNotification = @"NSControlWillBeginContinuousTrackingNotification";
FINCH_CONST NSString *const NSFlowLayoutCommonRowHorizontalAlignmentKey = @"UIFlowLayoutCommonRowHorizontalAlignmentKey";
FINCH_CONST NSString *const NSFlowLayoutLastRowHorizontalAlignmentKey = @"UIFlowLayoutLastRowHorizontalAlignmentKey";
FINCH_CONST NSString *const NSImageNameToolbarBookmarks = @"NSToolbarBookmarks";
FINCH_CONST NSString *const NSInspectorBarFontFamilyItemIdentifier = @"NSInspectorBarFontFamilyItemIdentifier";
FINCH_CONST NSString *const NSInspectorBarFontSizeItemIdentifier = @"NSInspectorBarFontSizeItemIdentifier";
FINCH_CONST NSString *const NSInspectorBarFontStyleItemIdentifier = @"NSInspectorBarFontStyleItemIdentifier";
FINCH_CONST NSString *const NSInspectorBarSpaceItemIdentifier = @"NSInspectorBarSpaceItemIdentifier";
FINCH_CONST NSString *const NSInspectorBarTextAlignmentItemIdentifier = @"NSInspectorBarTextAlignmentItemIdentifier";
FINCH_CONST NSString *const NSInspectorBarTextBackgroundColorItemIdentifier = @"NSInspectorBarTextBackgroundColorItemIdentifier";
FINCH_CONST NSString *const NSInspectorBarTextForegroundColorItemIdentifier = @"NSInspectorBarTextForegroundColorItemIdentifier";
FINCH_CONST NSString *const NSInspectorBarTextListItemIdentifier = @"NSInspectorBarTextListItemIdentifier";
FINCH_CONST NSString *const NSMenuDidCompleteInteractionNotification = @"NSMenuDidCompleteInteractionNotification";
FINCH_CONST NSString *const NSRecentDocumentsMenuName = @"NSRecentDocumentsMenu";
FINCH_CONST NSString *const NSSharingServiceMailExportFileKey = @"file";
FINCH_CONST NSString *const NSSharingServiceMailExportFileObjectsKey = @"fileObjects";
FINCH_CONST NSString *const NSSharingServiceMailExportFilesKey = @"files";
FINCH_CONST NSString *const NSSharingServiceMailExportImageObjectsKey = @"imageObjects";
FINCH_CONST NSString *const NSSharingServiceMailExportImagesKey = @"images";
FINCH_CONST NSString *const NSSharingServiceMailExportTextKey = @"text";
FINCH_CONST NSString *const NSSharingServiceMailExportTextObjectKey = @"textObject";
FINCH_CONST NSString *const NSSharingServiceMailExportURLObjectKey = @"URLObject";
FINCH_CONST NSString *const NSSharingServiceMailExportWebArchiveObjectKey = @"webArchiveObject";
FINCH_CONST NSString *const NSSharingServiceNameUseAsAccountPicture = @"com.apple.share.System.set-account-picture";
FINCH_CONST NSString *const NSSharingServiceParametersDefaultRecipientsKey = @"NSSharingServiceParametersDefaultRecipientsKey";
FINCH_CONST NSString *const NSTableViewCurrentRowSizeStyleDidChange = @"_NSTableViewCurrentRowSizeStyleDidChange";
FINCH_CONST NSString *const NSTextInputReplacementRangeAttributeName = @"NSTextInputReplacementRangeAttributeName";
FINCH_CONST NSString *const NSToolbarItemKey = @"item";
FINCH_CONST NSString *const NSWindowWillEnterVersionBrowserNotification = @"NSWindowWillEnterVersionBrowserNotification";
FINCH_CONST NSString *const NSWindowWillOrderOnScreenNotification = @"_NSWindowWillBecomeVisible";
FINCH_CONST NSString *const NSWindowsMenuName = @"NSWindowsMenu";
FINCH_CONST NSString *const _NSAccessibilityFrameAttribute = @"AXFrame";
FINCH_CONST NSString *const _NSPrintProtected = @"NSPrintProtected";
FINCH_CONST NSString *const _NSTextFormattingViewControllerFontAttributesComponentKey = @"_NSTextFormattingViewControllerFontAttributesComponent";
FINCH_CONST NSString *const _NSTextFormattingViewControllerFontPickerComponentKey = @"_NSTextFormattingViewControllerFontPickerComponent";
FINCH_CONST NSString *const _NSTextFormattingViewControllerFontSizeComponentKey = @"_NSTextFormattingViewControllerFontSizeComponent";
FINCH_CONST NSString *const _NSTextFormattingViewControllerTextAlignmentComponentKey = @"_NSTextFormattingViewControllerTextAlignmentComponent";
FINCH_CONST NSString *const _NSTextFormattingViewControllerTextBackgroundColorComponentKey = @"_NSTextFormattingViewControllerTextBackgroundComponent";
FINCH_CONST NSString *const _NSTextFormattingViewControllerTextColorComponentKey = @"_NSTextFormattingViewControllerTextColorComponent";
FINCH_CONST NSString *const _NXSmartPaste = @"NeXT smart paste pasteboard type";
FINCH_CONST void *_NSAppKitGlobalLock = 0; /* (not an object in Apple's: an empty word) */

#pragma mark - Small functions apps import

#define FINCH_FUNC __attribute__((visibility("default")))

/* An image's rect centred in bounds less an inset; an image too big for it gets all of it. */
FINCH_FUNC NSRect
_NSCenteredRectForImage(NSSize imageSize, NSRect bounds, CGFloat inset)
{
    NSRect r = inset != 0 ? NSInsetRect(bounds, inset, inset) : bounds;
    if (imageSize.width > r.size.width || imageSize.height > r.size.height)
        return r;
    return NSMakeRect(NSMidX(r) - imageSize.width / 2, NSMidY(r) - imageSize.height / 2, imageSize.width, imageSize.height);
}

FINCH_FUNC NSScrollerStyle _NSRecommendedScrollerStyle(void) { return [NSScroller preferredScrollerStyle]; }

/* An element's accessibility attributes and whether it is one, for accessibility clients. */
FINCH_FUNC NSArray *
NSAccessibilityEntryPointAttributeNames(id element)
{
    if ([element respondsToSelector:@selector(accessibilityAttributeNames)])
        return [element accessibilityAttributeNames];
    return @[];
}

FINCH_FUNC BOOL
NSAccessibilityEntryPointIsAccessibilityElement(id element)
{
    if (!element)
        return NO;
    return [element respondsToSelector:@selector(isAccessibilityElement)] ? [element isAccessibilityElement] : YES;
}

FINCH_FUNC void NSAccessibilityHandleFocusChanged(void) {}

/* (the accent colour is the system's own: Finch has no user choice of it yet) */
FINCH_FUNC BOOL NSColorControlAccentIsDefaultColor(void) { return YES; }

/* The sidebar row size the user chose: medium, Finch's only one. */
FINCH_FUNC NSTableViewRowSizeStyle NSTableViewCurrentRowSizeStyle(void) { return NSTableViewRowSizeStyleMedium; }

/* UIKit's rounding helpers AppKit carries for Catalyst code: a rect to whole pixels at a
   scale, and a rect centred on a point, rounded the same way. */
FINCH_FUNC CGRect
UIRectIntegralWithScale(CGRect r, CGFloat scale)
{
    if (scale <= 0)
        scale = 1;
    CGFloat x0 = floor(CGRectGetMinX(r) * scale) / scale, y0 = floor(CGRectGetMinY(r) * scale) / scale;
    CGFloat x1 = ceil(CGRectGetMaxX(r) * scale) / scale, y1 = ceil(CGRectGetMaxY(r) * scale) / scale;
    return CGRectMake(x0, y0, x1 - x0, y1 - y0);
}

FINCH_FUNC CGRect
UIRectCenteredAboutPointScale(CGRect r, CGPoint p, CGFloat scale)
{
    if (scale <= 0)
        scale = 1;
    return CGRectMake(round((p.x - r.size.width / 2) * scale) / scale, round((p.y - r.size.height / 2) * scale) / scale, r.size.width,
                      r.size.height);
}
