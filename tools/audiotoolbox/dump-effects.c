/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Prints, as C, the parameters (names, units, ranges, defaults and the values a new
 * instance starts with), latency, tail time and factory presets of Apple's effect
 * units on this Mac, for userland/AudioToolbox/AudioUnitEffectTables.c. Only values
 * are taken; the units' signal processing is Finch's.
 */
#include <AudioToolbox/AudioToolbox.h>
#include <stdio.h>
#include <string.h>

static const OSType wanted[][2] = {
    {'aufx', 'dely'}, {'aufx', 'dist'}, {'aufx', 'nbeq'}, {'aufx', 'mrev'}, {'aufx', 'rvb2'},
    {'aufx', 'lpas'}, {'aufx', 'hpas'}, {'aufx', 'bpas'}, {'aufx', 'lshf'}, {'aufx', 'hshf'},
    {'aufx', 'pmeq'}, {'aufx', 'lmtr'}, {'aufx', 'dcmp'}, {'aufx', 'sdly'}, {'aufx', 'nutp'},
    {'aufc', 'nutp'}, {'aufc', 'vari'}, {'aumu', 'samp'},
};

static void
cstring(CFStringRef s, char *out, size_t size)
{
    out[0] = 0;
    if (s)
        CFStringGetCString(s, out, (CFIndex)size, kCFStringEncodingUTF8);
}

static void
quoted(const char *s)
{
    putchar('"');
    for (; *s; s++) {
        if (*s == '"' || *s == '\\')
            putchar('\\');
        putchar(*s);
    }
    putchar('"');
}

static void
number(double v)
{
    char b[64];
    snprintf(b, sizeof b, "%.9g", v);
    if (!strpbrk(b, ".einn"))
        strcat(b, ".0");
    printf("%sf", b);
}

static int
params(AudioUnit u, AudioUnitParameterID *ids)
{
    UInt32 size = 0;
    if (AudioUnitGetPropertyInfo(u, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, &size, NULL))
        return 0;
    AudioUnitGetProperty(u, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, ids, &size);
    return (int)(size / sizeof *ids);
}

static void
values(AudioUnit u, const AudioUnitParameterID *ids, int n)
{
    printf("{");
    for (int i = 0; i < n; i++) {
        AudioUnitParameterValue v = 0;
        AudioUnitGetParameter(u, ids[i], kAudioUnitScope_Global, 0, &v);
        printf("%s", i ? ", " : "");
        number(v);
    }
    printf("}");
}

int
main(void)
{
    for (size_t w = 0; w < sizeof wanted / sizeof wanted[0]; w++) {
        AudioComponentDescription d = {wanted[w][0], wanted[w][1], kAudioUnitManufacturer_Apple, 0, 0};
        AudioComponent c = AudioComponentFindNext(NULL, &d);
        AudioUnit u;
        if (!c || AudioComponentInstanceNew(c, &u)) {
            fprintf(stderr, "missing %.4s\n", (char *)&wanted[w][1]);
            return 1;
        }
        char tag[32];
        snprintf(tag, sizeof tag, "%c%c%c%c_%c%c%c%c", (char)(d.componentType >> 24), (char)(d.componentType >> 16),
            (char)(d.componentType >> 8), (char)d.componentType, (char)(d.componentSubType >> 24),
            (char)(d.componentSubType >> 16), (char)(d.componentSubType >> 8), (char)d.componentSubType);
        for (char *p = tag; *p; p++)
            if (*p == ' ')
                *p = '_';
        AudioUnitParameterID ids[512];
        int n = params(u, ids);
        printf("static const struct EffectParam %s_params[] = {\n", tag);
        for (int i = 0; i < n; i++) {
            AudioUnitParameterInfo pi;
            UInt32 size = sizeof pi;
            memset(&pi, 0, sizeof pi);
            AudioUnitGetProperty(u, kAudioUnitProperty_ParameterInfo, kAudioUnitScope_Global, ids[i], &pi, &size);
            char name[256];
            cstring(pi.cfNameString, name, sizeof name);
            if (!name[0])
                strcpy(name, pi.name);
            AudioUnitParameterValue v = 0;
            AudioUnitGetParameter(u, ids[i], kAudioUnitScope_Global, 0, &v);
            printf("    {%u, ", ids[i]);
            quoted(name);
            printf(", %u, ", pi.unit);
            number(pi.minValue);
            printf(", ");
            number(pi.maxValue);
            printf(", ");
            number(pi.defaultValue);
            printf(", ");
            number(v);
            printf(", 0x%08x},\n", pi.flags);
        }
        printf("};\n");

        CFArrayRef presets = NULL;
        UInt32 size = sizeof presets;
        int count = 0;
        AUPreset present = {-1, NULL};
        if (!AudioUnitGetProperty(u, kAudioUnitProperty_FactoryPresets, kAudioUnitScope_Global, 0, &presets, &size) && presets) {
            UInt32 psize = sizeof present;
            AudioUnitGetProperty(u, kAudioUnitProperty_PresentPreset, kAudioUnitScope_Global, 0, &present, &psize);
            count = (int)CFArrayGetCount(presets);
            for (int i = 0; i < count; i++) {
                const AUPreset *p = CFArrayGetValueAtIndex(presets, i);
                AudioUnitSetProperty(u, kAudioUnitProperty_PresentPreset, kAudioUnitScope_Global, 0, p, sizeof *p);
                printf("static const float %s_preset%d[] = ", tag, i);
                values(u, ids, n);
                printf(";\n");
            }
            printf("static const struct EffectPreset %s_presets[] = {\n", tag);
            for (int i = 0; i < count; i++) {
                const AUPreset *p = CFArrayGetValueAtIndex(presets, i);
                char name[256];
                cstring(p->presetName, name, sizeof name);
                printf("    {%d, ", (int)p->presetNumber);
                quoted(name);
                printf(", %s_preset%d},\n", tag, i);
            }
            printf("};\n");
        }
        Float64 latency = 0, tail = 0;
        size = sizeof latency;
        AudioUnitGetProperty(u, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &size);
        size = sizeof tail;
        AudioUnitGetProperty(u, kAudioUnitProperty_TailTime, kAudioUnitScope_Global, 0, &tail, &size);
        CFStringRef cname = NULL;
        AudioComponentCopyName(c, &cname);
        char name[256];
        cstring(cname, name, sizeof name);
        UInt32 version = 0;
        AudioComponentGetVersion(c, &version);
        printf("#define %s_TABLE {'%.4s', '%.4s', ", tag, tag, tag + 5);
        quoted(name);
        printf(", 0x%x, %.9g, %.9g, %d, %s_params, %d, %s, %d}\n\n", version, latency, tail, n, tag, count,
            count ? strcat(strcpy((char[64]){0}, tag), "_presets") : "NULL", count ? (int)present.presetNumber : -1);
        AudioComponentInstanceDispose(u);
    }
    return 0;
}
