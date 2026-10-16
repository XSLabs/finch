/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <Accelerate/Accelerate.h>
#include <math.h>

vFloat vatan2f(vFloat y, vFloat x)
{
    vFloat result;
    size_t lane;
    for (lane = 0; lane < sizeof(result) / sizeof(float); ++lane)
        result[lane] = atan2f(y[lane], x[lane]);
    return result;
}

vFloat vsincosf(vFloat value, vFloat *sine)
{
    vFloat cosine;
    size_t lane;
    for (lane = 0; lane < sizeof(value) / sizeof(float); ++lane) {
        cosine[lane] = cosf(value[lane]);
        (*sine)[lane] = sinf(value[lane]);
    }
    return cosine;
}

vFloat vsqrtf(vFloat value)
{
    vFloat result;
    size_t lane;
    for (lane = 0; lane < sizeof(value) / sizeof(float); ++lane)
        result[lane] = sqrtf(value[lane]);
    return result;
}
