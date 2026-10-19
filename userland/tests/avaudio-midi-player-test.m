/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Compare file-backed MIDI transport without making sound a test requirement. */
#import <AVFAudio/AVMIDIPlayer.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        static const unsigned char bytes[] = {
            'M','T','h','d', 0,0,0,6, 0,0, 0,1, 1,0xe0,
            'M','T','r','k', 0,0,0,13,
            0,0x90,60,100, 0x83,0x60,0x80,60,0, 0,0xff,0x2f,0
        };
        NSError *error = nil;
        NSData *data = [NSData dataWithBytes:bytes length:sizeof(bytes)];
        AVMIDIPlayer *player = [[AVMIDIPlayer alloc] initWithData:data soundBankURL:nil error:&error];
        printf("%s\n", class_getImageName([AVMIDIPlayer class]));
        printf("loaded=%d error=%ld duration=%.2f playing=%d\n", player != nil,
            (long)error.code, player.duration, player.isPlaying);
        player.rate = 1.5f;
        player.currentPosition = 0.25;
        [player prepareToPlay];
        printf("rate=%.2f position=%.2f prepared-playing=%d\n", player.rate, player.currentPosition, player.isPlaying);
        [player stop];
    }
    return 0;
}
