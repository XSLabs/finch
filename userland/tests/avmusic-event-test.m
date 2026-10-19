/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Compare the public MIDI event values with Apple's framework. */
#import <AVFAudio/AVMusicEvents.h>
#import <Foundation/Foundation.h>

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        NSData *bytes = [NSData dataWithBytes:"abcde" length:5];
        AVMIDINoteEvent *note = [[AVMIDINoteEvent alloc] initWithChannel:2 key:60 velocity:99 duration:1.25];
        note.key = 61;
        AVMIDIControlChangeEvent *control = [[AVMIDIControlChangeEvent alloc] initWithChannel:3 messageType:AVMIDIControlChangeMessageTypeVolume value:91];
        AVMIDIPolyPressureEvent *poly = [[AVMIDIPolyPressureEvent alloc] initWithChannel:4 key:70 pressure:88];
        AVMIDIProgramChangeEvent *program = [[AVMIDIProgramChangeEvent alloc] initWithChannel:5 programNumber:12];
        AVMIDIChannelPressureEvent *channel = [[AVMIDIChannelPressureEvent alloc] initWithChannel:6 pressure:77];
        AVMIDIPitchBendEvent *bend = [[AVMIDIPitchBendEvent alloc] initWithChannel:7 value:8193];
        AVMIDISysexEvent *sysex = [[AVMIDISysexEvent alloc] initWithData:bytes];
        AVMIDIMetaEvent *meta = [[AVMIDIMetaEvent alloc] initWithType:AVMIDIMetaEventTypeText data:bytes];
        AVMusicUserEvent *user = [[AVMusicUserEvent alloc] initWithData:bytes];
        AVExtendedNoteOnEvent *extended = [[AVExtendedNoteOnEvent alloc] initWithMIDINote:60.5f velocity:80.25f groupID:8 duration:2.5];
        AVParameterEvent *parameter = [[AVParameterEvent alloc] initWithParameterID:9 scope:1 element:2 value:0.75f];
        NSDictionary *presetValue = @{ @"name": @"voice", @"number": @3 };
        AVAUPresetEvent *preset = [[AVAUPresetEvent alloc] initWithScope:0 element:1 dictionary:presetValue];
        AVExtendedTempoEvent *tempo = [[AVExtendedTempoEvent alloc] initWithTempo:123.5];
        puts("AVFAudio MIDI event values");
        printf("note %u %u %u %.2f\n", note.channel, note.key, note.velocity, note.duration);
        printf("control %u %ld %u poly %u %u %u\n", control.channel, (long)control.messageType, control.value,
               poly.channel, poly.key, poly.pressure);
        printf("program %u %u channel pressure %u %u bend %u %u\n", program.channel, program.programNumber,
               channel.channel, channel.pressure, bend.channel, bend.value);
        printf("data %u %ld %u %u\n", sysex.sizeInBytes, (long)meta.type, user.sizeInBytes,
               (unsigned)[preset.presetDictionary[@"number"] unsignedIntegerValue]);
        printf("extended %.2f %.2f %u %u %.2f parameter %u %u %u %.2f tempo %.2f\n",
               extended.midiNote, extended.velocity, extended.instrumentID, extended.groupID, extended.duration,
               parameter.parameterID, parameter.scope, parameter.element, parameter.value, tempo.tempo);
    }
    return 0;
}
