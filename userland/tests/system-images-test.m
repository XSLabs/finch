/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AppKit's system images by name (NSImageNameAddTemplate, NSImageNameCaution, the
 * private NSDisclosable, ...): each one's size, template flag and name, and that +imageNamed: gives the same object twice. Finch's are its own artwork;
 * SYSTEM_IMAGES_SHEET=PATH saves them all as a contact sheet. Compared with Apple's.
 */
#import <AppKit/AppKit.h>

static NSString *const names[] = {
    @"NSActionTemplate",
    @"NSAddTemplate",
    @"NSAdvanced",
    @"NSBluetoothTemplate",
    @"NSBonjour",
    @"NSBookmarksTemplate",
    @"NSCaution",
    @"NSColorPanel",
    @"NSColumnViewTemplate",
    @"NSComputer",
    @"NSDisclosable",
    @"NSDisclosed",
    @"NSDotMac",
    @"NSEnterFullScreenTemplate",
    @"NSEveryone",
    @"NSExitFullScreenTemplate",
    @"NSFlowViewTemplate",
    @"NSFolder",
    @"NSFolderBurnable",
    @"NSFolderSmart",
    @"NSFollowLinkFreestandingTemplate",
    @"NSFontPanel",
    @"NSGoBackTemplate",
    @"NSGoForwardTemplate",
    @"NSGoLeftTemplate",
    @"NSGoRightTemplate",
    @"NSHomeTemplate",
    @"NSIChatTheaterTemplate",
    @"NSIconViewTemplate",
    @"NSInfo",
    @"NSInvalidDataFreestandingTemplate",
    @"NSLeftFacingTriangleTemplate",
    @"NSListViewTemplate",
    @"NSLockLockedTemplate",
    @"NSLockUnlockedTemplate",
    @"NSMenuMixedStateTemplate",
    @"NSMenuOnStateTemplate",
    @"NSMobileMe",
    @"NSMultipleDocuments",
    @"NSNetwork",
    @"NSPathTemplate",
    @"NSPauseTemplate",
    @"NSPlayTemplate",
    @"NSPreferencesGeneral",
    @"NSPrintTemplate",
    @"NSQuickLookTemplate",
    @"NSRefreshFreestandingTemplate",
    @"NSRefreshTemplate",
    @"NSRemoveTemplate",
    @"NSRevealFreestandingTemplate",
    @"NSRightFacingTriangleTemplate",
    @"NSShareTemplate",
    @"NSSlideshowTemplate",
    @"NSSmartBadgeTemplate",
    @"NSStatusAvailable",
    @"NSStatusNone",
    @"NSStatusPartiallyAvailable",
    @"NSStatusUnavailable",
    @"NSStopProgressFreestandingTemplate",
    @"NSStopProgressTemplate",
    @"NSTouchBarAddDetailTemplate",
    @"NSTouchBarAddTabTemplate",
    @"NSTouchBarAddTemplate",
    @"NSTouchBarAlarmTemplate",
    @"NSTouchBarAudioInputMuteTemplate",
    @"NSTouchBarAudioInputTemplate",
    @"NSTouchBarAudioOutputMuteTemplate",
    @"NSTouchBarAudioOutputVolumeHighTemplate",
    @"NSTouchBarAudioOutputVolumeLowTemplate",
    @"NSTouchBarAudioOutputVolumeMediumTemplate",
    @"NSTouchBarAudioOutputVolumeOffTemplate",
    @"NSTouchBarBookmarksTemplate",
    @"NSTouchBarColorPickerFill",
    @"NSTouchBarColorPickerFont",
    @"NSTouchBarColorPickerStroke",
    @"NSTouchBarCommunicationAudioTemplate",
    @"NSTouchBarCommunicationVideoTemplate",
    @"NSTouchBarComposeTemplate",
    @"NSTouchBarDeleteTemplate",
    @"NSTouchBarDownloadTemplate",
    @"NSTouchBarEnterFullScreenTemplate",
    @"NSTouchBarExitFullScreenTemplate",
    @"NSTouchBarFastForwardTemplate",
    @"NSTouchBarFolderCopyToTemplate",
    @"NSTouchBarFolderMoveToTemplate",
    @"NSTouchBarFolderTemplate",
    @"NSTouchBarGetInfoTemplate",
    @"NSTouchBarGoBackTemplate",
    @"NSTouchBarGoDownTemplate",
    @"NSTouchBarGoForwardTemplate",
    @"NSTouchBarGoUpTemplate",
    @"NSTouchBarHistoryTemplate",
    @"NSTouchBarIconViewTemplate",
    @"NSTouchBarListViewTemplate",
    @"NSTouchBarMailTemplate",
    @"NSTouchBarNewFolderTemplate",
    @"NSTouchBarNewMessageTemplate",
    @"NSTouchBarOpenInBrowserTemplate",
    @"NSTouchBarPauseTemplate",
    @"NSTouchBarPlayPauseTemplate",
    @"NSTouchBarPlayTemplate",
    @"NSTouchBarPlayheadTemplate",
    @"NSTouchBarQuickLookTemplate",
    @"NSTouchBarRecordStartTemplate",
    @"NSTouchBarRecordStopTemplate",
    @"NSTouchBarRefreshTemplate",
    @"NSTouchBarRemoveTemplate",
    @"NSTouchBarRewindTemplate",
    @"NSTouchBarRotateLeftTemplate",
    @"NSTouchBarRotateRightTemplate",
    @"NSTouchBarSearchTemplate",
    @"NSTouchBarShareTemplate",
    @"NSTouchBarSidebarTemplate",
    @"NSTouchBarSkipAheadTemplate",
    @"NSTouchBarSkipBackTemplate",
    @"NSTouchBarSkipToEndTemplate",
    @"NSTouchBarSkipToStartTemplate",
    @"NSTouchBarSlideshowTemplate",
    @"NSTouchBarTagIconTemplate",
    @"NSTouchBarTextBoldTemplate",
    @"NSTouchBarTextBoxTemplate",
    @"NSTouchBarTextCenterAlignTemplate",
    @"NSTouchBarTextItalicTemplate",
    @"NSTouchBarTextJustifiedAlignTemplate",
    @"NSTouchBarTextLeftAlignTemplate",
    @"NSTouchBarTextListTemplate",
    @"NSTouchBarTextRightAlignTemplate",
    @"NSTouchBarTextStrikethroughTemplate",
    @"NSTouchBarTextUnderlineTemplate",
    @"NSTouchBarUserAddTemplate",
    @"NSTouchBarUserGroupTemplate",
    @"NSTouchBarUserTemplate",
    @"NSTouchBarVolumeDownTemplate",
    @"NSTouchBarVolumeUpTemplate",
    @"NSTrashEmpty",
    @"NSTrashFull",
    @"NSUser",
    @"NSUserAccounts",
    @"NSUserGroup",
    @"NSUserGuest"
};

int
main(void)
{
    @autoreleasepool {
        unsigned n = sizeof names / sizeof names[0];
        for (unsigned i = 0; i < n; i++) {
            NSImage *im = [NSImage imageNamed:names[i]];
            if (!im) {
                printf("%s: none\n", names[i].UTF8String);
                continue;
            }
            printf("%s: %gx%g template %d name %s same %d\n", names[i].UTF8String, im.size.width, im.size.height, im.template,
                   im.name ? "set" : "nil", [NSImage imageNamed:names[i]] == im);
        }
        const char *sheet = getenv("SYSTEM_IMAGES_SHEET");
        if (sheet) {
            /* each image twice its size, on paper and on dark, in a grid */
            int cols = 10, cell = 72;
            int rows = (int)((n + cols - 1) / cols);
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:cols * cell pixelsHigh:rows * cell
                bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:32];
            [NSGraphicsContext saveGraphicsState];
            NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
            [[NSColor colorWithWhite:0.96 alpha:1] setFill];
            NSRectFill(NSMakeRect(0, 0, cols * cell, rows * cell));
            for (unsigned i = 0; i < n; i++) {
                NSImage *im = [NSImage imageNamed:names[i]];
                NSSize s = NSMakeSize(im.size.width * 2, im.size.height * 2);
                NSRect c = NSMakeRect((i % cols) * cell, (rows - 1 - i / cols) * cell, cell, cell);
                [im drawInRect:NSMakeRect(NSMidX(c) - s.width / 2, NSMidY(c) - s.height / 2, s.width, s.height)];
            }
            [NSGraphicsContext restoreGraphicsState];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(sheet) atomically:YES];
        }
    }
    return 0;
}
