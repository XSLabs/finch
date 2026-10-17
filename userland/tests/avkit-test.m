/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Compare AVKit's view state and call the platform's PiP support query. */
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <AVKit/AVKit.h>
#include <stdio.h>

int main(void)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    puts("AVKit");
    AVPlayerView *playerView = [[AVPlayerView alloc] initWithFrame:NSMakeRect(0, 0, 320, 180)];
    playerView.controlsStyle = AVPlayerViewControlsStyleNone;
    playerView.showsFullScreenToggleButton = YES;
    printf("player=%d style=%ld fullscreen=%d ready=%d\n", playerView.player == nil,
           (long)playerView.controlsStyle, playerView.showsFullScreenToggleButton,
           playerView.isReadyForDisplay);

    AVRoutePickerView *routePicker = [[AVRoutePickerView alloc] initWithFrame:NSMakeRect(0, 0, 32, 32)];
    printf("route-picker=%d bordered=%d\n", routePicker.player == nil,
           routePicker.isRoutePickerButtonBordered);
    (void)[AVPictureInPictureController isPictureInPictureSupported];
    puts("pip-support-query=called");

    [routePicker release]; [playerView release];
    [pool drain];
    return 0;
}
