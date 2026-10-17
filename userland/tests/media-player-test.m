// SPDX-License-Identifier: MIT OR Apache-2.0
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <MediaPlayer/MediaPlayer.h>
#include <dlfcn.h>
#include <stdio.h>

static void printImage(void)
{
    Dl_info info = {0};
    if (dladdr((__bridge const void *)[MPNowPlayingInfoCenter class], &info) && info.dli_fname)
        puts(info.dli_fname);
    else puts("(MediaPlayer image unavailable)");
}

int main(void)
{
    @autoreleasepool {
        printImage();
        MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
        NSDictionary *oldInfo = [center.nowPlayingInfo copy];
        MPNowPlayingPlaybackState oldState = center.playbackState;
        NSDictionary *info = @{
            MPMediaItemPropertyTitle: @"Finch Test",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: @12.5
        };
        center.nowPlayingInfo = info;
        center.playbackState = MPNowPlayingPlaybackStatePlaying;
        printf("now playing: %s %.1f state=%ld\n",
            [center.nowPlayingInfo[MPMediaItemPropertyTitle] UTF8String],
            [center.nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] doubleValue],
            (long)center.playbackState);

        MPRemoteCommand *command = [MPRemoteCommandCenter.sharedCommandCenter playCommand];
        BOOL oldEnabled = command.enabled;
        printf("play command default enabled=%d\n", oldEnabled);
        command.enabled = YES;
        id token = [command addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
            (void)event;
            return MPRemoteCommandHandlerStatusSuccess;
        }];
        printf("play command: enabled=%d target=%d\n", command.enabled, token != nil);
        [command removeTarget:token];

        MPMediaItemArtwork *artwork = [[MPMediaItemArtwork alloc] initWithBoundsSize:NSMakeSize(2, 2)
            requestHandler:^NSImage *(CGSize size) {
                NSImage *source = [[NSImage alloc] initWithSize:size];
                [source lockFocus];
                [[NSColor redColor] set];
                NSRectFill(NSMakeRect(0, 0, size.width, size.height));
                [source unlockFocus];
                return source;
            }];
        NSImage *rendered = [artwork imageWithSize:CGSizeMake(8, 8)];
        printf("artwork: bounds=%.0fx%.0f image=%.0fx%.0f tiff=%d\n",
            artwork.bounds.size.width, artwork.bounds.size.height,
            rendered.size.width, rendered.size.height, rendered.TIFFRepresentation.length > 0);

        center.nowPlayingInfo = oldInfo;
        center.playbackState = oldState;
        command.enabled = oldEnabled;
    }
    return 0;
}
