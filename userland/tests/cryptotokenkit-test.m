// SPDX-License-Identifier: MIT OR Apache-2.0
#import <CryptoTokenKit/CryptoTokenKit.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>

static void printImage(void)
{
    Dl_info info = {0};
    if (dladdr((__bridge const void *)[TKBERTLVRecord class], &info) && info.dli_fname)
        puts(info.dli_fname);
    else puts("(CryptoTokenKit image unavailable)");
}

int main(void)
{
    @autoreleasepool {
        printImage();
        NSData *value = [NSData dataWithBytes:"\x01\x02\x03" length:3];
        TKBERTLVRecord *ber = [[TKBERTLVRecord alloc] initWithTag:0x5a value:value];
        TKTLVRecord *parsed = [TKBERTLVRecord recordFromData:ber.data];
        NSMutableData *both = [NSMutableData dataWithData:ber.data];
        [both appendData:ber.data];
        NSArray *sequence = [TKBERTLVRecord sequenceOfRecordsFromData:both];
        TKSimpleTLVRecord *simple = [[TKSimpleTLVRecord alloc] initWithTag:1 value:value];
        TKCompactTLVRecord *compact = [[TKCompactTLVRecord alloc] initWithTag:2 value:value];
        printf("BER: tag=%llu bytes=%lu parsed=%d value=%lu sequence=%lu simple=%lu compact=%lu\n",
            (unsigned long long)ber.tag, (unsigned long)ber.data.length, parsed.tag == ber.tag,
            (unsigned long)parsed.value.length, (unsigned long)sequence.count,
            (unsigned long)simple.data.length, (unsigned long)compact.data.length);
        TKSmartCardPINFormat *pin = [[TKSmartCardPINFormat alloc] init];
        printf("PIN defaults: charset=%ld encoding=%ld minimum=%ld maximum=%ld block=%ld justification=%ld offset=%ld lengthOffset=%ld lengthSize=%ld\n",
            (long)pin.charset, (long)pin.encoding, (long)pin.minPINLength, (long)pin.maxPINLength,
            (long)pin.PINBlockByteLength, (long)pin.PINJustification, (long)pin.PINBitOffset,
            (long)pin.PINLengthBitOffset, (long)pin.PINLengthBitSize);
        pin.charset = TKSmartCardPINCharsetAlphanumeric;
        pin.encoding = TKSmartCardPINEncodingBCD;
        pin.minPINLength = 6;
        pin.maxPINLength = 12;
        pin.PINBlockByteLength = 7;
        pin.PINJustification = TKSmartCardPINJustificationRight;
        pin.PINBitOffset = 3;
        pin.PINLengthBitOffset = 4;
        pin.PINLengthBitSize = 5;
        printf("PIN values: charset=%ld encoding=%ld minimum=%ld maximum=%ld block=%ld justification=%ld offset=%ld lengthOffset=%ld lengthSize=%ld\n",
            (long)pin.charset, (long)pin.encoding, (long)pin.minPINLength, (long)pin.maxPINLength,
            (long)pin.PINBlockByteLength, (long)pin.PINJustification, (long)pin.PINBitOffset,
            (long)pin.PINLengthBitOffset, (long)pin.PINLengthBitSize);
    }
    return 0;
}
