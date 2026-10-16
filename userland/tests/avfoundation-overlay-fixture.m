/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#import "avfoundation-overlay-test.h"
#include "avmovie.h"
#include "avframes.h"

NSData *
AVFoundationOverlayTestMovie(void)
{
    NSArray *frames = @[
        [NSData dataWithBytes:frame0 length:sizeof frame0],
        [NSData dataWithBytes:frame1 length:sizeof frame1],
        [NSData dataWithBytes:frame0 length:sizeof frame0],
        [NSData dataWithBytes:frame1 length:sizeof frame1],
        [NSData dataWithBytes:frame0 length:sizeof frame0],
        [NSData dataWithBytes:frame1 length:sizeof frame1],
    ];
    return build_movie_with_frames(frames);
}
