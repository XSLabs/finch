/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* The effect units' parameters, latencies, tails and factory presets, with the values
   Apple's have (tools/audiotoolbox/gen-effect-tables.sh). */
#include "AudioUnitEffects.h"

static const struct EffectParam aufx_dely_params[] = {
    {0, "Dry/Wet Mix", 16, 0.0f, 100.0f, 50.0f, 50.0f, 0xc8000000},
    {1, "Delay Time", 4, 9.99999975e-05f, 2.0f, 1.0f, 1.0f, 0xc9800000},
    {2, "Feedback", 3, -99.9000015f, 99.9000015f, 50.0f, 50.0f, 0xc8000000},
    {3, "Lowpass Cutoff Frequency", 8, 10.0f, 22050.0f, 15000.0f, 15000.0f, 0xc8400000},
};
#define aufx_dely_TABLE {'aufx', 'dely', "Apple: AUDelay", 0x10600, 0, 20.9315686, 4, aufx_dely_params, 0, NULL, -1}

static const struct EffectParam aufx_dist_params[] = {
    {0, "Delay", 24, 0.100000001f, 500.0f, 0.100000001f, 4.5999999f, 0xc8910000},
    {1, "Decay", 7, 0.100000001f, 50.0f, 1.0f, 9.72999954f, 0xc8910000},
    {2, "Delay Mix", 3, 0.0f, 100.0f, 50.0f, 3.4000001f, 0xc8100000},
    {3, "Decimation", 3, 0.0f, 100.0f, 50.0f, 0.5f, 0xc8910000},
    {4, "Rounding", 3, 0.0f, 100.0f, 0.0f, 65.1999969f, 0xc8930000},
    {5, "Decimation Mix", 3, 0.0f, 100.0f, 50.0f, 100.0f, 0xc8100000},
    {6, "Linear Term", 14, 0.0f, 1.0f, 1.0f, 0.0f, 0xc8100000},
    {7, "Squared Term", 14, 0.0f, 20.0f, 0.0f, 18.1100006f, 0xc8100000},
    {8, "Cubic Term", 14, 0.0f, 20.0f, 0.0f, 0.0f, 0xc8100000},
    {9, "Polynomial Mix", 3, 0.0f, 100.0f, 50.0f, 100.0f, 0xc8100000},
    {10, "Ring Mod Freq 1", 8, 0.5f, 8000.0f, 100.0f, 44.0f, 0xc8d00000},
    {11, "Ring Mod Freq 2", 8, 0.5f, 8000.0f, 100.0f, 1147.0f, 0xc8d00000},
    {12, "Ring Mod Balance", 3, 0.0f, 100.0f, 50.0f, 50.0f, 0xc8100000},
    {13, "Ring Mod Mix", 3, 0.0f, 100.0f, 0.0f, 0.0f, 0xc8100000},
    {14, "Soft Clip Gain", 13, -80.0f, 20.0f, -6.02059984f, -0.899999976f, 0xc8100000},
    {15, "Wet/Dry Mix", 3, 0.0f, 100.0f, 50.0f, 44.5999985f, 0xc8100000},
};
static const float aufx_dist_preset0[] = {4.5999999f, 9.72999954f, 3.4000001f, 0.5f, 65.1999969f, 100.0f, 0.0f, 18.1100006f, 0.0f, 100.0f, 44.0f, 1147.0f, 50.0f, 0.0f, -0.899999976f, 44.5999985f};
static const float aufx_dist_preset1[] = {15.5f, 35.7000008f, 75.6999969f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 15.0f, 82.4000015f, 324.5f, 303.899994f, 52.0f, 16.8999996f, -0.300000012f, 100.0f};
static const float aufx_dist_preset2[] = {1.60000002f, 0.680000007f, 84.5f, 12.0f, 18.7000008f, 0.0f, 0.0f, 0.949999988f, 8.0f, 100.0f, 4000.0f, 5000.0f, 50.0f, 13.5f, 20.0f, 100.0f};
static const float aufx_dist_preset3[] = {0.100000001f, 0.100000001f, 0.0f, 0.0f, 20.0f, 70.9000015f, 0.0f, 14.7299995f, 1.0f, 100.0f, 67.5199966f, 87.4100037f, 0.0f, 54.0999985f, 0.400000006f, 100.0f};
static const float aufx_dist_preset4[] = {0.100000001f, 1.0f, 0.0f, 1.0f, 85.6999969f, 100.0f, 0.405000001f, 4.73000002f, 3.38000011f, 53.4000015f, 0.5f, 0.5f, 0.0f, 0.0f, 9.89999962f, 100.0f};
static const float aufx_dist_preset5[] = {4.5999999f, 11.9099998f, 100.0f, 5.5999999f, 88.5999985f, 100.0f, 0.0f, 2.43000007f, 1.0f, 58.0999985f, 865.5f, 1897.0f, 52.7000008f, 98.5999985f, 4.5f, 100.0f};
static const float aufx_dist_preset6[] = {15.5f, 35.7000008f, 0.0f, 61.4000015f, 0.0f, 12.1999998f, 0.0f, 15.0f, 1.0f, 51.4000015f, 0.5f, 0.5f, 0.0f, 0.0f, 6.5f, 100.0f};
static const float aufx_dist_preset7[] = {15.5f, 35.7000008f, 0.0f, 4.0999999f, 82.8000031f, 43.2000008f, 0.0f, 4.73000002f, 1.0f, 40.5f, 0.5f, 0.5f, 0.0f, 0.0f, 13.1999998f, 100.0f};
static const float aufx_dist_preset8[] = {4.80000019f, 50.0f, 0.0f, 12.0f, 16.0f, 100.0f, 0.0f, 0.0f, 0.0f, 0.0f, 3400.0f, 300.0f, 74.3000031f, 0.0f, 20.0f, 100.0f};
static const float aufx_dist_preset9[] = {0.100000001f, 1.0f, 0.0f, 0.5f, 0.0f, 100.0f, 0.0f, 13.5100002f, 1.0f, 100.0f, 106.699997f, 711.299988f, 50.0f, 93.9000015f, 7.19999981f, 62.2000008f};
static const float aufx_dist_preset10[] = {0.100000001f, 0.100000001f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 20.0f, 100.0f, 0.5f, 0.5f, 0.0f, 0.0f, 7.19999981f, 100.0f};
static const float aufx_dist_preset11[] = {0.100000001f, 0.100000001f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 20.0f, 0.0f, 100.0f, 0.5f, 0.5f, 0.0f, 0.0f, 7.19999981f, 100.0f};
static const float aufx_dist_preset12[] = {356.700012f, 2.1500001f, 100.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.5f, 0.5f, 0.0f, 0.0f, 18.0f, 100.0f};
static const float aufx_dist_preset13[] = {473.299988f, 6.73999977f, 100.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.5f, 0.5f, 0.0f, 0.0f, 3.79999995f, 100.0f};
static const float aufx_dist_preset14[] = {22.0f, 10.0200005f, 100.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.5f, 0.5f, 0.0f, 0.0f, 5.80000019f, 100.0f};
static const float aufx_dist_preset15[] = {54.9000015f, 6.5f, 100.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.5f, 0.5f, 0.0f, 0.0f, 7.80000019f, 100.0f};
static const float aufx_dist_preset16[] = {0.5f, 35.7000008f, 100.0f, 1.0f, 68.6999969f, 100.0f, 0.0f, 13.6499996f, 16.0809994f, 4.69999981f, 0.5f, 0.60799998f, 52.7000008f, 98.5999985f, 2.4000001f, 100.0f};
static const float aufx_dist_preset17[] = {201.800003f, 7.23999977f, 10.1000004f, 1.5f, 76.4000015f, 16.2000008f, 0.0f, 12.1599998f, 17.9729996f, 17.6000004f, 1504.0f, 2159.0f, 40.5f, 98.5999985f, 15.3000002f, 100.0f};
static const float aufx_dist_preset18[] = {0.100000001f, 1.0f, 2.70000005f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 3400.0f, 300.0f, 93.9000015f, 100.0f, 14.6000004f, 100.0f};
static const float aufx_dist_preset19[] = {15.5f, 12.2399998f, 22.2999992f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 1618.0f, 3141.0f, 50.7000008f, 89.9000015f, 9.89999962f, 100.0f};
static const float aufx_dist_preset20[] = {28.1000004f, 2.1500001f, 58.7999992f, 39.0f, 20.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 29.5599995f, 87.4100037f, 89.9000015f, 98.5999985f, 13.8999996f, 100.0f};
static const float aufx_dist_preset21[] = {0.100000001f, 0.100000001f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 44.0f, 48.0f, 50.0f, 100.0f, 16.6000004f, 100.0f};
static const struct EffectPreset aufx_dist_presets[] = {
    {0, "Drums- Bit Brush", aufx_dist_preset0},
    {1, "Drums- Buffer Beats", aufx_dist_preset1},
    {2, "Drums- Lo-Fi", aufx_dist_preset2},
    {3, "Multi- Broken Speaker", aufx_dist_preset3},
    {4, "Multi - Cellphone Concert", aufx_dist_preset4},
    {5, "Multi- Decimated 1", aufx_dist_preset5},
    {6, "Multi- Decimated 2", aufx_dist_preset6},
    {7, "Multi- Decimated 3", aufx_dist_preset7},
    {8, "Multi- Decimated 4", aufx_dist_preset8},
    {9, "Multi- Distorted Funk", aufx_dist_preset9},
    {10, "Multi- Distorted Cubed", aufx_dist_preset10},
    {11, "Multi- Distorted Squared", aufx_dist_preset11},
    {12, "Multi- Echo 1", aufx_dist_preset12},
    {13, "Multi- Echo 2", aufx_dist_preset13},
    {14, "Multi- Echo Tight 1", aufx_dist_preset14},
    {15, "Multi- Echo Tight 2", aufx_dist_preset15},
    {16, "Multi- Everything is Broken", aufx_dist_preset16},
    {17, "Speech- Alien Chatter", aufx_dist_preset17},
    {18, "Speech- Cosmic Interference", aufx_dist_preset18},
    {19, "Speech- Golden Pi", aufx_dist_preset19},
    {20, "Speech- Radio Tower", aufx_dist_preset20},
    {21, "Speech- Waves", aufx_dist_preset21},
};
#define aufx_dist_TABLE {'aufx', 'dist', "Apple: AUDistortion", 0x10600, 0, 0.000100000001, 16, aufx_dist_params, 22, aufx_dist_presets, 0}

static const struct EffectParam aufx_nbeq_params[] = {
    {0, "Global Gain", 13, -96.0f, 24.0f, 0.0f, 0.0f, 0xc8000000},
    {1000, "Bypass", 2, 0.0f, 1.0f, 1.0f, 1.0f, 0xc8100000},
    {2000, "Type", 1, 0.0f, 10.0f, 0.0f, 0.0f, 0xd8100000},
    {3000, "Frequency", 8, 10.0f, 21609.0f, 1000.0f, 40.0f, 0xc8100000},
    {4000, "Gain", 13, -96.0f, 24.0f, 0.0f, 0.0f, 0xc8100000},
    {5000, "Bandwidth", 21, 0.0500000007f, 5.0f, 0.5f, 0.5f, 0xc8100000},
    {1001, "Bypass", 2, 0.0f, 1.0f, 1.0f, 1.0f, 0xc8100000},
    {2001, "Type", 1, 0.0f, 10.0f, 0.0f, 0.0f, 0xd8100000},
    {3001, "Frequency", 8, 10.0f, 21609.0f, 1000.0f, 57.7993088f, 0xc8100000},
    {4001, "Gain", 13, -96.0f, 24.0f, 0.0f, 0.0f, 0xc8100000},
    {5001, "Bandwidth", 21, 0.0500000007f, 5.0f, 0.5f, 0.5f, 0xc8100000},
    {1002, "Bypass", 2, 0.0f, 1.0f, 1.0f, 1.0f, 0xc8100000},
    {2002, "Type", 1, 0.0f, 10.0f, 0.0f, 0.0f, 0xd8100000},
    {3002, "Frequency", 8, 10.0f, 21609.0f, 1000.0f, 83.5190048f, 0xc8100000},
    {4002, "Gain", 13, -96.0f, 24.0f, 0.0f, 0.0f, 0xc8100000},
    {5002, "Bandwidth", 21, 0.0500000007f, 5.0f, 0.5f, 0.5f, 0xc8100000},
    {1003, "Bypass", 2, 0.0f, 1.0f, 1.0f, 1.0f, 0xc8100000},
    {2003, "Type", 1, 0.0f, 10.0f, 0.0f, 0.0f, 0xd8100000},
    {3003, "Frequency", 8, 10.0f, 21609.0f, 1000.0f, 120.683525f, 0xc8100000},
    {4003, "Gain", 13, -96.0f, 24.0f, 0.0f, 0.0f, 0xc8100000},
    {5003, "Bandwidth", 21, 0.0500000007f, 5.0f, 0.5f, 0.5f, 0xc8100000},
    {1004, "Bypass", 2, 0.0f, 1.0f, 1.0f, 1.0f, 0xc8100000},
    {2004, "Type", 1, 0.0f, 10.0f, 0.0f, 0.0f, 0xd8100000},
    {3004, "Frequency", 8, 10.0f, 21609.0f, 1000.0f, 174.38562f, 0xc8100000},
    {4004, "Gain", 13, -96.0f, 24.0f, 0.0f, 0.0f, 0xc8100000},
    {5004, "Bandwidth", 21, 0.0500000007f, 5.0f, 0.5f, 0.5f, 0xc8100000},
    {1005, "Bypass", 2, 0.0f, 1.0f, 1.0f, 1.0f, 0xc8100000},
    {2005, "Type", 1, 0.0f, 10.0f, 0.0f, 0.0f, 0xd8100000},
    {3005, "Frequency", 8, 10.0f, 21609.0f, 1000.0f, 251.984207f, 0xc8100000},
    {4005, "Gain", 13, -96.0f, 24.0f, 0.0f, 0.0f, 0xc8100000},
    {5005, "Bandwidth", 21, 0.0500000007f, 5.0f, 0.5f, 0.5f, 0xc8100000},
    {1006, "Bypass", 2, 0.0f, 1.0f, 1.0f, 1.0f, 0xc8100000},
    {2006, "Type", 1, 0.0f, 10.0f, 0.0f, 0.0f, 0xd8100000},
    {3006, "Frequency", 8, 10.0f, 21609.0f, 1000.0f, 364.112854f, 0xc8100000},
    {4006, "Gain", 13, -96.0f, 24.0f, 0.0f, 0.0f, 0xc8100000},
    {5006, "Bandwidth", 21, 0.0500000007f, 5.0f, 0.5f, 0.5f, 0xc8100000},
    {1007, "Bypass", 2, 0.0f, 1.0f, 1.0f, 1.0f, 0xc8100000},
    {2007, "Type", 1, 0.0f, 10.0f, 0.0f, 0.0f, 0xd8100000},
    {3007, "Frequency", 8, 10.0f, 21609.0f, 1000.0f, 526.13678f, 0xc8100000},
    {4007, "Gain", 13, -96.0f, 24.0f, 0.0f, 0.0f, 0xc8100000},
    {5007, "Bandwidth", 21, 0.0500000007f, 5.0f, 0.5f, 0.5f, 0xc8100000},
};
#define aufx_nbeq_TABLE {'aufx', 'nbeq', "Apple: AUNBandEQ", 0x10600, 0, 0.05, 41, aufx_nbeq_params, 0, NULL, -1}

static const struct EffectParam aufx_mrev_params[] = {
    {0, "Dry/Wet Mix", 16, 0.0f, 100.0f, 100.0f, 100.0f, 0xc8100000},
    {1, "Small/Large Mix", 16, 0.0f, 100.0f, 72.0f, 35.0f, 0xc8100000},
    {2, "Small Size", 4, 9.99999975e-05f, 0.0500000007f, 0.0267210007f, 0.0147449998f, 0xc9100000},
    {3, "Large Size", 4, 0.00499999989f, 0.150000006f, 0.071800001f, 0.0614f, 0xc9100000},
    {4, "Pre-Delay", 4, 0.00100000005f, 0.0299999993f, 0.0157949999f, 0.0149250003f, 0xc9100000},
    {5, "Large Delay", 4, 0.00100000005f, 0.100000001f, 0.00990999956f, 0.00100000005f, 0xc9100000},
    {6, "Small Density", 0, 0.0f, 1.0f, 0.519999981f, 0.654999971f, 0xc9100000},
    {7, "Large Density", 0, 0.0f, 1.0f, 0.74000001f, 0.680000007f, 0xc9100000},
    {8, "Large Delay Range", 0, 0.0f, 1.0f, 0.485000014f, 0.584999979f, 0xc9100000},
    {9, "Small HiFreq Absorption", 0, 0.100000001f, 1.0f, 0.848999977f, 0.75f, 0xc9100000},
    {10, "Large HiFreq Absorption", 0, 0.100000001f, 1.0f, 0.415499985f, 0.640500009f, 0xc9100000},
    {11, "Small Delay Range", 0, 0.0f, 1.0f, 0.580420017f, 0.395604998f, 0xc9100000},
    {12, "Modulation Rate", 8, 0.00100000005f, 2.0f, 1.68014002f, 1.23036504f, 0xc9500000},
    {13, "Modulation Depth", 0, 0.0f, 1.0f, 0.514999986f, 0.400000006f, 0xc9100000},
    {14, "Filter Frequency", 8, 10.0f, 22050.0f, 800.0f, 800.0f, 0xc9500000},
    {15, "Filter Bandwidth", 21, 0.0500000007f, 4.0f, 3.0f, 3.0f, 0xc9100000},
    {16, "Filter Gain", 13, -18.0f, 18.0f, 0.0f, 0.0f, 0xc9100000},
};
static const float aufx_mrev_preset0[] = {100.0f, 74.4990005f, 0.00484000007f, 0.0401500016f, 0.00200000009f, 0.0113949999f, 0.449999988f, 0.280000001f, 0.319999993f, 0.999991f, 0.774990976f, 1.0f, 0.75f, 0.400000006f, 800.0f, 3.0f, 0.0f};
static const float aufx_mrev_preset1[] = {100.0f, 30.4989986f, 0.0170000009f, 0.0382959992f, 0.00499999989f, 0.0130000003f, 0.579999983f, 0.209999993f, 0.524999976f, 0.958999991f, 0.969500005f, 1.0f, 0.75f, 0.600000024f, 800.0f, 3.0f, 0.0f};
static const float aufx_mrev_preset2[] = {100.0f, 66.0f, 0.0354689993f, 0.0336499996f, 0.00680000009f, 0.0297100004f, 0.469999999f, 0.944999993f, 0.284990013f, 0.98150003f, 0.337000012f, 0.564835012f, 1.28955495f, 0.180000007f, 800.0f, 3.0f, 0.0f};
static const float aufx_mrev_preset3[] = {100.0f, 72.0f, 0.0267210007f, 0.071800001f, 0.0157949999f, 0.00990999956f, 0.519999981f, 0.74000001f, 0.485000014f, 0.848999977f, 0.415499985f, 0.580420017f, 1.68014002f, 0.514999986f, 800.0f, 3.0f, 0.0f};
static const float aufx_mrev_preset4[] = {100.0f, 50.0f, 0.0172359999f, 0.0869999975f, 0.0109999999f, 0.0213849992f, 0.735000014f, 0.639999986f, 0.564999998f, 0.680000007f, 0.739499986f, 0.585415006f, 0.749724984f, 0.310000002f, 800.0f, 3.0f, 0.0f};
static const float aufx_mrev_preset5[] = {100.0f, 14.500001f, 0.0101779997f, 0.0199999996f, 0.00505999988f, 0.0232749991f, 0.50999999f, 0.63499999f, 0.624989986f, 0.932491004f, 0.797491014f, 0.999989986f, 0.959720016f, 0.310000002f, 800.0f, 3.0f, 0.0f};
static const float aufx_mrev_preset6[] = {100.0f, 44.9999962f, 0.0165069997f, 0.0458500013f, 0.0062239999f, 0.0128800003f, 0.589999974f, 0.774999976f, 0.764989972f, 0.666499972f, 0.714999974f, 0.999989986f, 1.38029003f, 0.154990003f, 800.0f, 3.0f, 0.0f};
static const float aufx_mrev_preset7[] = {100.0f, 30.0f, 0.0165069997f, 0.0432499982f, 0.0062239999f, 0.0128800003f, 0.785000026f, 0.899999976f, 0.304989994f, 0.666499972f, 0.714999974f, 0.449999988f, 0.5f, 0.300000012f, 800.0f, 3.0f, 0.0f};
static const float aufx_mrev_preset8[] = {100.0f, 85.5f, 0.0282179993f, 0.0926000029f, 0.0149250003f, 0.00100000005f, 0.495000005f, 0.999989986f, 0.430000007f, 0.948000014f, 0.384000003f, 0.615384996f, 0.869965017f, 0.75f, 800.0f, 3.0f, 0.0f};
static const float aufx_mrev_preset9[] = {100.0f, 30.0f, 0.0162569992f, 0.0718500018f, 0.00100000005f, 0.0237700008f, 0.589999974f, 0.469999999f, 0.999989986f, 0.765500009f, 0.638499975f, 0.849550009f, 0.400000006f, 0.400000006f, 800.0f, 3.0f, 0.0f};
static const float aufx_mrev_preset10[] = {100.0f, 39.0f, 0.0182380006f, 0.0614f, 0.0149250003f, 0.00100000005f, 0.654999971f, 0.600000024f, 0.584999979f, 0.848999977f, 0.640500009f, 0.770229995f, 0.800000012f, 0.300000012f, 800.0f, 3.0f, 0.0f};
static const float aufx_mrev_preset11[] = {100.0f, 35.0f, 0.0147449998f, 0.0614f, 0.0149250003f, 0.00100000005f, 0.654999971f, 0.680000007f, 0.584999979f, 0.75f, 0.640500009f, 0.395604998f, 1.23036504f, 0.400000006f, 800.0f, 3.0f, 0.0f};
static const float aufx_mrev_preset12[] = {100.0f, 57.0f, 0.0359679982f, 0.0432499982f, 0.0062239999f, 0.0128800003f, 0.574999988f, 0.86500001f, 0.304989994f, 0.509000003f, 0.841000021f, 0.270130008f, 0.350805014f, 0.400000006f, 800.0f, 3.0f, 0.0f};
static const struct EffectPreset aufx_mrev_presets[] = {
    {0, "Small Room", aufx_mrev_preset0},
    {1, "Medium Room", aufx_mrev_preset1},
    {2, "Large Room", aufx_mrev_preset2},
    {3, "Medium Hall", aufx_mrev_preset3},
    {4, "Large Hall", aufx_mrev_preset4},
    {5, "Plate", aufx_mrev_preset5},
    {6, "Medium Chamber", aufx_mrev_preset6},
    {7, "Large Chamber", aufx_mrev_preset7},
    {8, "Cathedral", aufx_mrev_preset8},
    {9, "Large Room 2", aufx_mrev_preset9},
    {10, "Medium Hall 2", aufx_mrev_preset10},
    {11, "Medium Hall 3", aufx_mrev_preset11},
    {12, "Large Hall 2", aufx_mrev_preset12},
};
#define aufx_mrev_TABLE {'aufx', 'mrev', "Apple: AUMatrixReverb", 0x10600, 0, 10, 17, aufx_mrev_params, 13, aufx_mrev_presets, 11}

static const struct EffectParam aufx_rvb2_params[] = {
    {0, "Dry/Wet Mix", 3, 0.0f, 100.0f, 50.0f, 0.5f, 0xc8000000},
    {1, "Gain", 13, -20.0f, 20.0f, 0.0f, 1.0f, 0xc8000000},
    {2, "Min Delay Time", 4, 9.99999975e-05f, 1.0f, 0.00800000038f, 0.00800000038f, 0xc9400000},
    {3, "Max Delay Time", 4, 9.99999975e-05f, 1.0f, 0.0500000007f, 0.0500000007f, 0xc9400000},
    {4, "Low Freq Decay Time", 4, 0.00100000005f, 20.0f, 1.0f, 1.0f, 0xc8050000},
    {5, "High Freq Decay Time", 4, 0.00100000005f, 20.0f, 1.0f, 0.5f, 0xc8400000},
    {6, "Randomize Reflections", 0, 1.0f, 1000.0f, 1.0f, 1.0f, 0xc9000000},
};
static const float aufx_rvb2_preset0[] = {0.5f, 1.0f, 0.00200000009f, 0.0140000004f, 0.300000012f, 0.0799999982f, 1.0f};
static const float aufx_rvb2_preset1[] = {0.5f, 1.0f, 0.00499999989f, 0.0450000018f, 0.850000024f, 0.300000012f, 1.0f};
static const float aufx_rvb2_preset2[] = {0.5f, 1.0f, 0.00999999978f, 0.0700000003f, 1.0f, 0.600000024f, 1.0f};
static const float aufx_rvb2_preset3[] = {0.5f, 1.0f, 0.00999999978f, 0.0700000003f, 2.0999999f, 1.10000002f, 1.0f};
static const float aufx_rvb2_preset4[] = {0.5f, 1.0f, 0.0179999992f, 0.100000001f, 2.9000001f, 2.0f, 1.0f};
static const float aufx_rvb2_preset5[] = {0.5f, 1.0f, 0.00499999989f, 0.0450000018f, 7.0f, 2.5f, 1.0f};
static const float aufx_rvb2_preset6[] = {0.5f, 1.0f, 0.00999999978f, 0.0280000009f, 1.20000005f, 0.370000005f, 1.0f};
static const float aufx_rvb2_preset7[] = {0.5f, 1.0f, 0.00999999978f, 0.0280000009f, 2.0f, 0.670000017f, 1.0f};
static const float aufx_rvb2_preset8[] = {0.5f, 1.0f, 0.0299999993f, 0.200000003f, 9.0f, 3.0f, 1.0f};
static const float aufx_rvb2_preset9[] = {0.5f, 1.0f, 0.00650000013f, 0.0799999982f, 1.0f, 0.600000024f, 1.0f};
static const float aufx_rvb2_preset10[] = {0.5f, 1.0f, 0.00600000005f, 0.0399999991f, 2.0999999f, 1.10000002f, 1.0f};
static const float aufx_rvb2_preset11[] = {0.5f, 1.0f, 0.00800000038f, 0.0549999997f, 2.0999999f, 1.10000002f, 1.0f};
static const float aufx_rvb2_preset12[] = {0.5f, 1.0f, 0.00600000005f, 0.0399999991f, 2.9000001f, 2.0f, 1.0f};
static const struct EffectPreset aufx_rvb2_presets[] = {
    {0, "Small Room", aufx_rvb2_preset0},
    {1, "Medium Room", aufx_rvb2_preset1},
    {2, "Large Room", aufx_rvb2_preset2},
    {3, "Medium Hall", aufx_rvb2_preset3},
    {4, "Large Hall", aufx_rvb2_preset4},
    {5, "Plate", aufx_rvb2_preset5},
    {6, "Medium Chamber", aufx_rvb2_preset6},
    {7, "Large Chamber", aufx_rvb2_preset7},
    {8, "Cathedral", aufx_rvb2_preset8},
    {9, "Large Room 2", aufx_rvb2_preset9},
    {10, "Medium Hall 2", aufx_rvb2_preset10},
    {11, "Medium Hall 3", aufx_rvb2_preset11},
    {12, "Large Hall 2", aufx_rvb2_preset12},
};
#define aufx_rvb2_TABLE {'aufx', 'rvb2', "Apple: AUReverb2", 0x10600, 0, 8.70000029, 7, aufx_rvb2_params, 13, aufx_rvb2_presets, -1}

static const struct EffectParam aufx_lpas_params[] = {
    {0, "Cutoff Frequency", 8, 10.0f, 21829.5f, 6900.0f, 6900.0f, 0xc8c00000},
    {1, "Resonance", 13, -20.0f, 40.0f, 0.0f, 0.0f, 0xc8000000},
};
#define aufx_lpas_TABLE {'aufx', 'lpas', "Apple: AULowpass", 0x10600, 0, 0.001, 2, aufx_lpas_params, 0, NULL, -1}

static const struct EffectParam aufx_hpas_params[] = {
    {0, "Cutoff Frequency", 8, 10.0f, 22050.0f, 6900.0f, 6900.0f, 0xc8c00000},
    {1, "Resonance", 13, -20.0f, 40.0f, 0.0f, 0.0f, 0xc8000000},
};
#define aufx_hpas_TABLE {'aufx', 'hpas', "Apple: AUHipass", 0x10600, 0, 0.001, 2, aufx_hpas_params, 0, NULL, -1}

static const struct EffectParam aufx_bpas_params[] = {
    {0, "Center Frequency", 8, 20.0f, 22050.0f, 5000.0f, 5000.0f, 0xc8c00000},
    {1, "Bandwidth", 9, 100.0f, 12000.0f, 600.0f, 600.0f, 0xc8000000},
};
#define aufx_bpas_TABLE {'aufx', 'bpas', "Apple: AUBandpass", 0x10600, 0, 0.001, 2, aufx_bpas_params, 0, NULL, -1}

static const struct EffectParam aufx_lshf_params[] = {
    {0, "Cutoff Frequency", 8, 10.0f, 200.0f, 80.0f, 80.0f, 0xc8400000},
    {1, "Gain", 13, -40.0f, 40.0f, 0.0f, 0.0f, 0xc8000000},
};
#define aufx_lshf_TABLE {'aufx', 'lshf', "Apple: AULowShelfFilter", 0x10600, 0, 0.001, 2, aufx_lshf_params, 0, NULL, -1}

static const struct EffectParam aufx_hshf_params[] = {
    {0, "Cutoff Frequency", 8, 10000.0f, 22050.0f, 10000.0f, 10000.0f, 0xc8400000},
    {1, "Gain", 13, -40.0f, 40.0f, 0.0f, 0.0f, 0xc8000000},
};
#define aufx_hshf_TABLE {'aufx', 'hshf', "Apple: AUHighShelfFilter", 0x10600, 0, 0.001, 2, aufx_hshf_params, 0, NULL, -1}

static const struct EffectParam aufx_pmeq_params[] = {
    {0, "Center Frequency", 8, 20.0f, 21829.5f, 2000.0f, 2000.0f, 0xc8400000},
    {1, "Q", 0, 1.0f, 20.0f, 10.0f, 10.0f, 0xc8000000},
    {2, "Gain", 13, -20.0f, 20.0f, 0.0f, 0.0f, 0xc8000000},
};
#define aufx_pmeq_TABLE {'aufx', 'pmeq', "Apple: AUParametricEQ", 0x10600, 0, 0.001, 3, aufx_pmeq_params, 0, NULL, -1}

static const struct EffectParam aufx_lmtr_params[] = {
    {0, "Attack Time", 4, 0.000500000024f, 0.0299999993f, 0.00200000009f, 0.00200000009f, 0xc9400000},
    {1, "Release Time", 4, 0.00100000005f, 0.0399999991f, 0.00499999989f, 0.00499999989f, 0xc8400000},
    {2, "Pre-Gain", 13, -40.0f, 40.0f, 0.0f, 0.0f, 0xc8000000},
};
#define aufx_lmtr_TABLE {'aufx', 'lmtr', "Apple: AUPeakLimiter", 0x10600, 0.00200000009, 0.1, 3, aufx_lmtr_params, 0, NULL, -1}

static const struct EffectParam aufx_dcmp_params[] = {
    {0, "Compression Threshold", 13, -100.0f, 20.0f, -15.0f, -35.0f, 0xc8000000},
    {1, "Headroom", 13, 0.100000001f, 40.0f, 5.5999999f, 30.0f, 0xc8000000},
    {2, "Expansion Ratio", 7, 1.0f, 50.0f, 1.0f, 1.0f, 0xc8400000},
    {3, "Expansion Threshold", 13, -120.0f, 0.0f, -100.0f, -100.0f, 0xc8000000},
    {4, "Attack Time", 4, 0.00100000005f, 0.300000012f, 0.0500000007f, 0.0299999993f, 0xc8400000},
    {5, "Release Time", 4, 0.00999999978f, 3.0f, 0.0299999993f, 0.0299999993f, 0xc8400000},
    {6, "Master Gain", 13, -40.0f, 40.0f, 0.0f, 0.0f, 0xc8000000},
};
static const float aufx_dcmp_preset0[] = {-35.0f, 30.0f, 1.0f, -100.0f, 0.0299999993f, 0.0299999993f, 0.0f};
static const float aufx_dcmp_preset1[] = {-25.0f, 5.0f, 1.0f, -100.0f, 0.0199999996f, 0.0199999996f, 0.0f};
static const float aufx_dcmp_preset2[] = {-35.0f, 40.0f, 1.0f, -100.0f, 0.0500000007f, 0.200000003f, 0.0f};
static const float aufx_dcmp_preset3[] = {20.0f, 40.0f, 2.0f, -50.0f, 0.0500000007f, 0.0500000007f, 0.0f};
static const float aufx_dcmp_preset4[] = {20.0f, 40.0f, 4.0f, -50.0f, 0.0500000007f, 0.0500000007f, 0.0f};
static const float aufx_dcmp_preset5[] = {20.0f, 40.0f, 50.0f, -50.0f, 0.0500000007f, 0.0500000007f, 0.0f};
static const struct EffectPreset aufx_dcmp_presets[] = {
    {0, "Fast and Smooth", aufx_dcmp_preset0},
    {1, "Hard", aufx_dcmp_preset1},
    {2, "Light", aufx_dcmp_preset2},
    {3, "Light Gate", aufx_dcmp_preset3},
    {4, "Medium Gate", aufx_dcmp_preset4},
    {5, "Hard Gate", aufx_dcmp_preset5},
};
#define aufx_dcmp_TABLE {'aufx', 'dcmp', "Apple: AUDynamicsProcessor", 0x10600, 0.00580498866, 0.2, 7, aufx_dcmp_params, 6, aufx_dcmp_presets, 0}

static const struct EffectParam aufx_sdly_params[] = {
    {0, "In to Out Delay", 5, 0.0f, 4410.0f, 0.0f, 0.0f, 0xc8000000},
};
#define aufx_sdly_TABLE {'aufx', 'sdly', "Apple: AUSampleDelay", 0x10600, 0, 0, 1, aufx_sdly_params, 0, NULL, -1}

static const struct EffectParam aufx_nutp_params[] = {
    {1, "Pitch Scale", 9, -2400.0f, 2400.0f, 0.0f, 0.0f, 0xc8800000},
    {4, "Smoothness", 0, 3.0f, 32.0f, 8.0f, 8.0f, 0xccc00000},
    {6, "Spectral Coherence", 2, 0.0f, 1.0f, 1.0f, 1.0f, 0xdc000000},
    {7, "Preserve Transients", 2, 0.0f, 1.0f, 1.0f, 1.0f, 0xcc000000},
};
#define aufx_nutp_TABLE {'aufx', 'nutp', "Apple: AUNewPitch", 0x10600, 0, 0, 4, aufx_nutp_params, 0, NULL, -1}

static const struct EffectParam aufc_nutp_params[] = {
    {0, "Rate", 7, 0.03125f, 32.0f, 1.0f, 1.0f, 0xc8c00000},
    {1, "Pitch Scale", 9, -2400.0f, 2400.0f, 0.0f, 0.0f, 0xc8800000},
    {4, "Smoothness", 0, 3.0f, 32.0f, 8.0f, 8.0f, 0xccc00000},
    {6, "Spectral Coherence", 2, 0.0f, 1.0f, 1.0f, 1.0f, 0xdc000000},
    {7, "Preserve Transients", 2, 0.0f, 1.0f, 1.0f, 1.0f, 0xcc000000},
};
#define aufc_nutp_TABLE {'aufc', 'nutp', "Apple: AUNewTimePitch", 0x10600, 0, 0, 5, aufc_nutp_params, 0, NULL, -1}

static const struct EffectParam aufc_vari_params[] = {
    {0, "Playback Rate", 7, 0.25f, 4.0f, 1.0f, 1.0f, 0xd8c00000},
    {1, "Playback Pitch", 9, -2400.0f, 2400.0f, 0.0f, 0.0f, 0xd8800000},
};
#define aufc_vari_TABLE {'aufc', 'vari', "Apple: AUVarispeed", 0x10600, 0, 0, 2, aufc_vari_params, 0, NULL, -1}

static const struct EffectParam aumu_samp_params[] = {
    {900, "Gain", 13, -96.0f, 12.0f, 0.0f, 0.0f, 0xc8100000},
    {901, "Coarse Tuning", 10, -24.0f, 24.0f, 0.0f, 0.0f, 0xc8100000},
    {902, "Fine Tuning", 9, -99.0f, 99.0f, 0.0f, 0.0f, 0xc8100000},
    {903, "Stereo Pan", 18, -100.0f, 100.0f, 0.0f, 0.0f, 0xc8100000},
    {1000, "Performance Parameter 1", 0, 0.0f, 1.0f, 0.0f, 0.0f, 0xc8100010},
    {1001, "Performance Parameter 2", 0, 0.0f, 1.0f, 0.0f, 0.0f, 0xc8100010},
    {1002, "Performance Parameter 3", 0, 0.0f, 1.0f, 0.0f, 0.0f, 0xc8100010},
    {1003, "Performance Parameter 4", 0, 0.0f, 1.0f, 0.0f, 0.0f, 0xc8100010},
    {1004, "Performance Parameter 5", 0, 0.0f, 1.0f, 0.0f, 0.0f, 0xc8100010},
    {1005, "Performance Parameter 6", 0, 0.0f, 1.0f, 0.0f, 0.0f, 0xc8100010},
    {1006, "Performance Parameter 7", 0, 0.0f, 1.0f, 0.0f, 0.0f, 0xc8100010},
};
#define aumu_samp_TABLE {'aumu', 'samp', "Apple: AUSampler", 0x10000, 0, 0, 11, aumu_samp_params, 0, NULL, -1}

const struct EffectTable _FinchEffectTables[] = {
    aufx_dely_TABLE,
    aufx_dist_TABLE,
    aufx_nbeq_TABLE,
    aufx_mrev_TABLE,
    aufx_rvb2_TABLE,
    aufx_lpas_TABLE,
    aufx_hpas_TABLE,
    aufx_bpas_TABLE,
    aufx_lshf_TABLE,
    aufx_hshf_TABLE,
    aufx_pmeq_TABLE,
    aufx_lmtr_TABLE,
    aufx_dcmp_TABLE,
    aufx_sdly_TABLE,
    aufx_nutp_TABLE,
    aufc_nutp_TABLE,
    aufc_vari_TABLE,
    aumu_samp_TABLE,
};
const size_t _FinchEffectTableCount = sizeof _FinchEffectTables / sizeof _FinchEffectTables[0];
