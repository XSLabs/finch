/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* IOBluetoothTransferProgress (private, Apple's class): an OBEX transfer's byte counts,
   rate and time remaining. IOBluetoothUI's progress panel subclasses it. */
#import <Foundation/Foundation.h>

@interface IOBluetoothTransferProgress : NSObject <NSCopying> {
@protected
    unsigned short mThreshold;
    int mTransferState;
    unsigned long long mTotalBytes, mTransferedBytes, mRemainingBytes;
    float mPercentDone, mTransferRate;
    NSDate *mTimeOfTransferStart;
    double mSecondsRemaining;
}
- (instancetype)initWithTotalBytes:(unsigned int)totalBytes;
- (void)moreBytesTransferred:(unsigned int)bytes;
- (void)setBytesTransferred:(unsigned long long)bytes;
- (void)setTotalBytes:(unsigned long long)bytes;
- (void)setBytesRemaining:(unsigned long long)bytes;
- (void)setPercentDone:(float)percent;
- (void)setTransferRate:(float)rate;
- (void)setSecondsRemaining:(double)seconds;
- (void)setDeterminateThreshold:(unsigned short)threshold;
- (void)setTransferState:(int)state;
- (int)transferState;
- (unsigned long long)getBytesTotal;
- (unsigned long long)getBytesTransferred;
- (unsigned long long)getRemainingBytes;
- (float)getTransferPercentage;
- (float)getByteTransferRate;
- (double)getTimeElapsed;
- (double)getEstimatedTimeRemaining;
- (NSDate *)getEstimatedTimeRemainingDate;
- (NSDate *)getStartTime;
- (void)updateUI;
@end
