/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* AudioUnit.framework must re-export the software AudioUnit API in AudioToolbox. */
#include <AudioUnit/AudioUnit.h>
#include <AudioToolbox/AudioToolbox.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <string.h>

static const char *
audio_unit_image(void)
{
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *path = _dyld_get_image_name(i);
        if (path && strstr(path, "AudioUnit.framework"))
            return path;
    }
    return "?";
}

int
main(void)
{
    printf("AudioUnit: %s\n", audio_unit_image());
    AudioComponentDescription description = {
        kAudioUnitType_FormatConverter, kAudioUnitSubType_AUConverter, kAudioUnitManufacturer_Apple, 0, 0
    };
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    AudioUnit unit = NULL;
    OSStatus create = component ? AudioComponentInstanceNew(component, &unit) : kAudio_ParamError;
    OSStatus initialize = create ? create : AudioUnitInitialize(unit);
    OSStatus uninitialize = initialize ? initialize : AudioUnitUninitialize(unit);
    OSStatus dispose = unit ? AudioComponentInstanceDispose(unit) : create;
    printf("component %d create %d initialize %d uninitialize %d dispose %d\n",
           component != NULL, (int)create, (int)initialize, (int)uninitialize, (int)dispose);
    return 0;
}
