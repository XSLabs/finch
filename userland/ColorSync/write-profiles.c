/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Writes the standard profiles Finch's ColorSync makes (ColorSyncProfileCreateWithName)
 * into a folder as the installed profiles, /System/Library/ColorSync/Profiles, under the
 * file names macOS uses for them. Run by build.sh against the ColorSync just built.
 *   write-profiles DIR
 */
#include <ColorSync/ColorSync.h>
#include <stdio.h>

static const struct {
    const CFStringRef *name;
    const char *file;
} profiles[] = {
    {&kColorSyncSRGBProfile, "sRGB Profile.icc"},
    {&kColorSyncDisplayP3Profile, "Display P3.icc"},
    {&kColorSyncDCIP3Profile, "DCI(P3) RGB.icc"},
    {&kColorSyncAdobeRGB1998Profile, "AdobeRGB1998.icc"},
    {&kColorSyncITUR709Profile, "ITU-709.icc"},
    {&kColorSyncITUR2020Profile, "ITU-2020.icc"},
    {&kColorSyncACESCGLinearProfile, "ACESCG Linear.icc"},
    {&kColorSyncROMMRGBProfile, "ROMM RGB.icc"},
    {&kColorSyncGenericRGBProfile, "Generic RGB Profile.icc"},
    {&kColorSyncGenericGrayProfile, "Generic Gray Profile.icc"},
    {&kColorSyncGenericGrayGamma22Profile, "Generic Gray Gamma 2.2 Profile.icc"},
    {&kColorSyncGenericLabProfile, "Generic Lab Profile.icc"},
    {&kColorSyncGenericXYZProfile, "Generic XYZ Profile.icc"},
};

int
main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: write-profiles DIR\n");
        return 2;
    }
    for (size_t i = 0; i < sizeof profiles / sizeof *profiles; i++) {
        ColorSyncProfileRef p = ColorSyncProfileCreateWithName(*profiles[i].name);
        CFDataRef d = p ? ColorSyncProfileCopyData(p, NULL) : NULL;
        if (!d) {
            fprintf(stderr, "write-profiles: no data for %s\n", profiles[i].file);
            return 1;
        }
        char path[1024];
        snprintf(path, sizeof path, "%s/%s", argv[1], profiles[i].file);
        FILE *f = fopen(path, "wb");
        if (!f || fwrite(CFDataGetBytePtr(d), 1, (size_t)CFDataGetLength(d), f) != (size_t)CFDataGetLength(d)) {
            perror(path);
            return 1;
        }
        fclose(f);
        CFRelease(d);
        CFRelease(p);
    }
    return 0;
}
