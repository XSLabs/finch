/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * vBasicOps and vBigNum: integer arithmetic on the lanes of a vector (8- to 64-bit
 * lanes, and 128-bit) and on 128- to 1024-bit numbers. Numbers are little-endian
 * 32-bit words, as Apple's unions lay them out on arm64. Where vBasicOps.h speaks of
 * "even" and "odd" elements in big-endian order, the even ones are the upper lanes
 * of each pair here, as on Apple's; shift and rotate counts come from byte 0 (and
 * byte 8 for the second 64-bit lane of the "2" forms). Division by zero gives a
 * quotient of all ones and the numerator as the remainder.
 */
/* the header's arm64 inline forms of a few of these would hide their declarations */
#define __clang_tapi__ 1
#include <Accelerate/Accelerate.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

/* MARK: - Multiword numbers (n 32-bit words, least significant first) */

#define MAXW 64 /* a 1024-bit full product has 64 words */

static bool negative(const uint32_t *a, int n) { return a[n - 1] >> 31; }

static uint32_t add_words(uint32_t *r, const uint32_t *a, const uint32_t *b, int n)
{
    uint64_t carry = 0;
    for (int i = 0; i < n; ++i) {
        carry += (uint64_t)a[i] + b[i];
        r[i] = (uint32_t)carry;
        carry >>= 32;
    }
    return (uint32_t)carry;
}

static uint32_t sub_words(uint32_t *r, const uint32_t *a, const uint32_t *b, int n)
{
    int64_t borrow = 0;
    for (int i = 0; i < n; ++i) {
        int64_t d = (int64_t)a[i] - b[i] - borrow;
        r[i] = (uint32_t)d;
        borrow = d < 0;
    }
    return (uint32_t)borrow;
}

static void neg_words(uint32_t *r, const uint32_t *a, int n)
{
    uint64_t carry = 1;
    for (int i = 0; i < n; ++i) {
        carry += (uint32_t)~a[i];
        r[i] = (uint32_t)carry;
        carry >>= 32;
    }
}

static void fill_words(uint32_t *r, int n, uint32_t low, uint32_t rest, uint32_t top)
{
    for (int i = 0; i < n; ++i)
        r[i] = rest;
    r[0] = low;
    r[n - 1] = top;
}

static void adds_unsigned(uint32_t *r, const uint32_t *a, const uint32_t *b, int n)
{
    if (add_words(r, a, b, n))
        fill_words(r, n, UINT32_MAX, UINT32_MAX, UINT32_MAX);
}

static void subs_unsigned(uint32_t *r, const uint32_t *a, const uint32_t *b, int n)
{
    if (sub_words(r, a, b, n))
        memset(r, 0, (size_t)n * 4);
}

static void saturate_signed(uint32_t *r, int n, bool toward_negative)
{
    if (toward_negative)
        fill_words(r, n, 0, 0, 0x80000000u);
    else
        fill_words(r, n, UINT32_MAX, UINT32_MAX, 0x7fffffffu);
}

static void adds_signed(uint32_t *r, const uint32_t *a, const uint32_t *b, int n)
{
    bool na = negative(a, n), nb = negative(b, n);
    add_words(r, a, b, n);
    if (na == nb && negative(r, n) != na)
        saturate_signed(r, n, na);
}

static void subs_signed(uint32_t *r, const uint32_t *a, const uint32_t *b, int n)
{
    bool na = negative(a, n), nb = negative(b, n);
    sub_words(r, a, b, n);
    if (na != nb && negative(r, n) != na)
        saturate_signed(r, n, na);
}

/* r (2n words, or n for a half product) = a * b, unsigned */
static void mul_words(uint32_t *r, int rn, const uint32_t *a, const uint32_t *b, int n)
{
    uint32_t t[MAXW] = {0};
    for (int i = 0; i < n; ++i) {
        uint64_t carry = 0;
        for (int j = 0; j < n && i + j < rn; ++j) {
            carry += (uint64_t)a[i] * b[j] + t[i + j];
            t[i + j] = (uint32_t)carry;
            carry >>= 32;
        }
        if (i + n < rn)
            t[i + n] = (uint32_t)carry;
    }
    memcpy(r, t, (size_t)rn * 4);
}

static void mul_signed(uint32_t *r, int rn, const uint32_t *a, const uint32_t *b, int n)
{
    uint32_t ua[MAXW / 2], ub[MAXW / 2];
    bool na = negative(a, n), nb = negative(b, n);
    if (na)
        neg_words(ua, a, n);
    else
        memcpy(ua, a, (size_t)n * 4);
    if (nb)
        neg_words(ub, b, n);
    else
        memcpy(ub, b, (size_t)n * 4);
    mul_words(r, rn, ua, ub, n);
    if (na != nb)
        neg_words(r, r, rn);
}

static bool is_zero(const uint32_t *a, int n)
{
    for (int i = 0; i < n; ++i)
        if (a[i])
            return false;
    return true;
}

static int compare_words(const uint32_t *a, const uint32_t *b, int n)
{
    for (int i = n - 1; i >= 0; --i)
        if (a[i] != b[i])
            return a[i] < b[i] ? -1 : 1;
    return 0;
}

/* shift-and-subtract long division, unsigned */
static void div_words(uint32_t *q, uint32_t *rem, const uint32_t *a, const uint32_t *d, int n)
{
    uint32_t quotient[MAXW / 2] = {0}, r[MAXW / 2] = {0};
    if (is_zero(d, n)) {
        if (rem)
            memcpy(rem, a, (size_t)n * 4);
        if (q)
            memset(q, 0xff, (size_t)n * 4);
        return;
    }
    for (int bit = n * 32 - 1; bit >= 0; --bit) {
        uint32_t top = r[n - 1] >> 31;
        for (int i = n - 1; i > 0; --i)
            r[i] = (r[i] << 1) | (r[i - 1] >> 31);
        r[0] = (r[0] << 1) | ((a[bit / 32] >> (bit % 32)) & 1);
        if (top || compare_words(r, d, n) >= 0) {
            sub_words(r, r, d, n);
            quotient[bit / 32] |= 1u << (bit % 32);
        }
    }
    if (q)
        memcpy(q, quotient, (size_t)n * 4);
    if (rem)
        memcpy(rem, r, (size_t)n * 4);
}

/* truncating signed division; the remainder takes the numerator's sign */
static void div_signed(uint32_t *q, uint32_t *rem, const uint32_t *a, const uint32_t *d, int n)
{
    uint32_t ua[MAXW / 2], ud[MAXW / 2], uq[MAXW / 2], ur[MAXW / 2];
    bool na = negative(a, n), nd = negative(d, n);
    if (na)
        neg_words(ua, a, n);
    else
        memcpy(ua, a, (size_t)n * 4);
    if (nd)
        neg_words(ud, d, n);
    else
        memcpy(ud, d, (size_t)n * 4);
    div_words(uq, ur, ua, ud, n);
    if (is_zero(d, n)) {
        if (q)
            memset(q, 0xff, (size_t)n * 4);
        if (rem)
            memcpy(rem, a, (size_t)n * 4);
        return;
    }
    if (na != nd)
        neg_words(uq, uq, n);
    if (na)
        neg_words(ur, ur, n);
    if (q)
        memcpy(q, uq, (size_t)n * 4);
    if (rem)
        memcpy(rem, ur, (size_t)n * 4);
}

static uint32_t word_at(const uint32_t *a, int n, int i, uint32_t fill) { return i >= 0 && i < n ? a[i] : fill; }

/* left shift by s bits (s may be 0..32n), filling with zeros */
static void shl_words(uint32_t *r, const uint32_t *a, int n, unsigned s)
{
    uint32_t t[MAXW / 2];
    int w = (int)(s / 32), b = (int)(s % 32);
    for (int i = 0; i < n; ++i) {
        uint32_t lo = word_at(a, n, i - w, 0), lower = word_at(a, n, i - w - 1, 0);
        t[i] = b ? (lo << b) | (lower >> (32 - b)) : lo;
    }
    memcpy(r, t, (size_t)n * 4);
}

/* right shift, logical or arithmetic */
static void shr_words(uint32_t *r, const uint32_t *a, int n, unsigned s, bool arithmetic)
{
    uint32_t t[MAXW / 2], fill = arithmetic && negative(a, n) ? UINT32_MAX : 0;
    int w = (int)(s / 32), b = (int)(s % 32);
    for (int i = 0; i < n; ++i) {
        uint32_t hi = word_at(a, n, i + w, fill), higher = word_at(a, n, i + w + 1, fill);
        t[i] = b ? (hi >> b) | (higher << (32 - b)) : hi;
    }
    memcpy(r, t, (size_t)n * 4);
}

static void rotl_words(uint32_t *r, const uint32_t *a, int n, unsigned s)
{
    uint32_t left[MAXW / 2], right[MAXW / 2];
    s %= (unsigned)(n * 32);
    shl_words(left, a, n, s);
    shr_words(right, a, n, (unsigned)(n * 32) - s, false);
    for (int i = 0; i < n; ++i)
        r[i] = s ? left[i] | right[i] : a[i];
}

/* MARK: - vBigNum: 256, 512 and 1024 bits (and 128-bit full multiply) */

#define W(p) ((uint32_t *)(p))
#define CW(p) ((const uint32_t *)(p))

#define BIGNUM(bits, n)                                                                                  \
    void vU##bits##Add(const vU##bits *a, const vU##bits *b, vU##bits *r) { add_words(W(r), CW(a), CW(b), n); } \
    void vS##bits##Add(const vS##bits *a, const vS##bits *b, vS##bits *r) { add_words(W(r), CW(a), CW(b), n); } \
    void vU##bits##AddS(const vU##bits *a, const vU##bits *b, vU##bits *r) { adds_unsigned(W(r), CW(a), CW(b), n); } \
    void vS##bits##AddS(const vS##bits *a, const vS##bits *b, vS##bits *r) { adds_signed(W(r), CW(a), CW(b), n); } \
    void vU##bits##Sub(const vU##bits *a, const vU##bits *b, vU##bits *r) { sub_words(W(r), CW(a), CW(b), n); } \
    void vS##bits##Sub(const vS##bits *a, const vS##bits *b, vS##bits *r) { sub_words(W(r), CW(a), CW(b), n); } \
    void vU##bits##SubS(const vU##bits *a, const vU##bits *b, vU##bits *r) { subs_unsigned(W(r), CW(a), CW(b), n); } \
    void vS##bits##SubS(const vS##bits *a, const vS##bits *b, vS##bits *r) { subs_signed(W(r), CW(a), CW(b), n); } \
    void vU##bits##Neg(const vU##bits *a, vU##bits *r) { neg_words(W(r), CW(a), n); }                  \
    void vS##bits##Neg(const vS##bits *a, vS##bits *r) { neg_words(W(r), CW(a), n); }                  \
    void vU##bits##HalfMultiply(const vU##bits *a, const vU##bits *b, vU##bits *r)                       \
    {                                                                                                    \
        mul_words(W(r), n, CW(a), CW(b), n);                                                             \
    }                                                                                                    \
    void vS##bits##HalfMultiply(const vS##bits *a, const vS##bits *b, vS##bits *r)                       \
    {                                                                                                    \
        mul_signed(W(r), n, CW(a), CW(b), n);                                                            \
    }                                                                                                    \
    void vU##bits##Divide(const vU##bits *a, const vU##bits *d, vU##bits *q, vU##bits *rem)              \
    {                                                                                                    \
        div_words(W(q), rem ? W(rem) : NULL, CW(a), CW(d), n);                                           \
    }                                                                                                    \
    void vS##bits##Divide(const vS##bits *a, const vS##bits *d, vS##bits *q, vS##bits *rem)              \
    {                                                                                                    \
        div_signed(W(q), rem ? W(rem) : NULL, CW(a), CW(d), n);                                          \
    }                                                                                                    \
    void vU##bits##Mod(const vU##bits *a, const vU##bits *d, vU##bits *rem) { div_words(NULL, W(rem), CW(a), CW(d), n); } \
    void vS##bits##Mod(const vS##bits *a, const vS##bits *d, vS##bits *rem) { div_signed(NULL, W(rem), CW(a), CW(d), n); } \
    void vLL##bits##Shift(const vU##bits *a, uint32_t s, vU##bits *r) { shl_words(W(r), CW(a), n, s % (bits)); } \
    void vLR##bits##Shift(const vU##bits *a, uint32_t s, vU##bits *r) { shr_words(W(r), CW(a), n, s % (bits), false); } \
    void vA##bits##Shift(const vS##bits *a, uint32_t s, vS##bits *r) { shr_words(W(r), CW(a), n, s % (bits), true); } \
    void vL##bits##Rotate(const vU##bits *a, uint32_t s, vU##bits *r) { rotl_words(W(r), CW(a), n, s); } \
    void vR##bits##Rotate(const vU##bits *a, uint32_t s, vU##bits *r)                                    \
    {                                                                                                    \
        rotl_words(W(r), CW(a), n, (unsigned)(bits) - s % (bits));                                       \
    }

BIGNUM(256, 8)
BIGNUM(512, 16)
BIGNUM(1024, 32)

#define FULLMUL(bits, wide, n)                                                                           \
    void vU##bits##FullMultiply(const vU##bits *a, const vU##bits *b, vU##wide *r)                       \
    {                                                                                                    \
        mul_words(W(r), 2 * n, CW(a), CW(b), n);                                                         \
    }                                                                                                    \
    void vS##bits##FullMultiply(const vS##bits *a, const vS##bits *b, vS##wide *r)                       \
    {                                                                                                    \
        mul_signed(W(r), 2 * n, CW(a), CW(b), n);                                                        \
    }

FULLMUL(128, 256, 4)
FULLMUL(256, 512, 8)
FULLMUL(512, 1024, 16)

/* MARK: - vBasicOps: lanes of a vector */

#define LANEWISE_DIVIDE(name, V, T, U, LANES)                                                            \
    V name(V n, V d, V *remainder)                                                                       \
    {                                                                                                    \
        V q, r;                                                                                          \
        for (int i = 0; i < LANES; ++i) {                                                                \
            T a = n[i], b = d[i];                                                                        \
            if (b == 0) {                                                                                \
                q[i] = (T)(U)-1;                                                                         \
                r[i] = a;                                                                                \
            } else if ((T)-1 < 0 && b == (T)-1 && (T)(a - 1) > a) { /* the most negative value over -1 */                \
                q[i] = a;                                                                                \
                r[i] = 0;                                                                                \
            } else {                                                                                     \
                q[i] = (T)(a / b);                                                                       \
                r[i] = (T)(a % b);                                                                       \
            }                                                                                            \
        }                                                                                                \
        if (remainder)                                                                                   \
            *remainder = r;                                                                              \
        return q;                                                                                        \
    }

_Pragma("clang diagnostic push") _Pragma("clang diagnostic ignored \"-Wtautological-compare\"")
_Pragma("clang diagnostic ignored \"-Wtype-limits\"") _Pragma("clang diagnostic ignored \"-Wsign-compare\"")
LANEWISE_DIVIDE(vU8Divide, vUInt8, uint8_t, uint8_t, 16)
LANEWISE_DIVIDE(vS8Divide, vSInt8, int8_t, uint8_t, 16)
LANEWISE_DIVIDE(vU16Divide, vUInt16, uint16_t, uint16_t, 8)
LANEWISE_DIVIDE(vS16Divide, vSInt16, int16_t, uint16_t, 8)
LANEWISE_DIVIDE(vU32Divide, vUInt32, uint32_t, uint32_t, 4)
LANEWISE_DIVIDE(vS32Divide, vSInt32, int32_t, uint32_t, 4)
_Pragma("clang diagnostic pop")

#define HALFMUL(name, V, T, LANES)                                                                       \
    V name(V a, V b)                                                                                     \
    {                                                                                                    \
        V r;                                                                                             \
        for (int i = 0; i < LANES; ++i)                                                                  \
            r[i] = (T)((uint64_t)a[i] * (uint64_t)b[i]);                                                 \
        return r;                                                                                        \
    }

HALFMUL(vU8HalfMultiply, vUInt8, uint8_t, 16)
HALFMUL(vS8HalfMultiply, vSInt8, int8_t, 16)
HALFMUL(vU16HalfMultiply, vUInt16, uint16_t, 8)
HALFMUL(vS16HalfMultiply, vSInt16, int16_t, 8)
HALFMUL(vU32HalfMultiply, vUInt32, uint32_t, 4)
HALFMUL(vS32HalfMultiply, vSInt32, int32_t, 4)

/* 32-bit lanes (1, 3 for even; 0, 2 for odd) to 64-bit products */
#define FULLMUL32(name, V, T, W64, FIRST)                                                                \
    V name(V a, V b)                                                                                     \
    {                                                                                                    \
        union {                                                                                          \
            W64 w[2];                                                                                    \
            V v;                                                                                         \
        } r;                                                                                             \
        r.w[0] = (W64)(T)a[FIRST] * (W64)(T)b[FIRST];                                                    \
        r.w[1] = (W64)(T)a[FIRST + 2] * (W64)(T)b[FIRST + 2];                                            \
        return r.v;                                                                                      \
    }

FULLMUL32(vU32FullMulEven, vUInt32, uint32_t, uint64_t, 1)
FULLMUL32(vU32FullMulOdd, vUInt32, uint32_t, uint64_t, 0)
FULLMUL32(vS32FullMulEven, vSInt32, int32_t, int64_t, 1)
FULLMUL32(vS32FullMulOdd, vSInt32, int32_t, int64_t, 0)

/* 64-bit lanes (as pairs of 32-bit words) */
typedef union {
    vUInt32 v;
    uint32_t w[4];
} Quad;

static Quad quad(vUInt32 v)
{
    Quad q;
    q.v = v;
    return q;
}

#define LANES64(name, OP)                                                                                \
    vUInt32 name(vUInt32 a, vUInt32 b)                                                                   \
    {                                                                                                    \
        Quad x = quad(a), y = quad(b), r;                                                                \
        OP(r.w, x.w, y.w, 2);                                                                            \
        OP(r.w + 2, x.w + 2, y.w + 2, 2);                                                                \
        return r.v;                                                                                      \
    }
#define SLANES64(name, OP)                                                                               \
    vSInt32 name(vSInt32 a, vSInt32 b)                                                                   \
    {                                                                                                    \
        Quad x = quad((vUInt32)a), y = quad((vUInt32)b), r;                                              \
        OP(r.w, x.w, y.w, 2);                                                                            \
        OP(r.w + 2, x.w + 2, y.w + 2, 2);                                                                \
        return (vSInt32)r.v;                                                                             \
    }
#define WHOLE128(name, V, OP)                                                                            \
    V name(V a, V b)                                                                                     \
    {                                                                                                    \
        Quad x = quad((vUInt32)a), y = quad((vUInt32)b), r;                                              \
        OP(r.w, x.w, y.w, 4);                                                                            \
        return (V)r.v;                                                                                   \
    }

static void add_n(uint32_t *r, const uint32_t *a, const uint32_t *b, int n) { add_words(r, a, b, n); }
static void sub_n(uint32_t *r, const uint32_t *a, const uint32_t *b, int n) { sub_words(r, a, b, n); }
static void half_n(uint32_t *r, const uint32_t *a, const uint32_t *b, int n) { mul_words(r, n, a, b, n); }
static void shalf_n(uint32_t *r, const uint32_t *a, const uint32_t *b, int n) { mul_signed(r, n, a, b, n); }

LANES64(vU64Add, add_n)
LANES64(vU64AddS, adds_unsigned)
LANES64(vU64Sub, sub_n)
LANES64(vU64SubS, subs_unsigned)
LANES64(vU64HalfMultiply, half_n)
SLANES64(vS64Add, add_n)
SLANES64(vS64AddS, adds_signed)
SLANES64(vS64Sub, sub_n)
SLANES64(vS64SubS, subs_signed)
SLANES64(vS64HalfMultiply, shalf_n)
WHOLE128(vU128Add, vUInt32, add_n)
WHOLE128(vU128AddS, vUInt32, adds_unsigned)
WHOLE128(vU128Sub, vUInt32, sub_n)
WHOLE128(vU128SubS, vUInt32, subs_unsigned)
WHOLE128(vU128HalfMultiply, vUInt32, half_n)
WHOLE128(vS128Add, vSInt32, add_n)
WHOLE128(vS128AddS, vSInt32, adds_signed)
WHOLE128(vS128Sub, vSInt32, sub_n)
WHOLE128(vS128SubS, vSInt32, subs_signed)
WHOLE128(vS128HalfMultiply, vSInt32, shalf_n)

/* the upper (even) or lower (odd) 64-bit lanes, to a 128-bit product */
#define FULLMUL64(name, V, MUL, FIRST)                                                                   \
    V name(V a, V b)                                                                                     \
    {                                                                                                    \
        Quad x = quad((vUInt32)a), y = quad((vUInt32)b), r;                                              \
        MUL(r.w, 4, x.w + FIRST, y.w + FIRST, 2);                                                        \
        return (V)r.v;                                                                                   \
    }

FULLMUL64(vU64FullMulEven, vUInt32, mul_words, 2)
FULLMUL64(vU64FullMulOdd, vUInt32, mul_words, 0)
FULLMUL64(vS64FullMulEven, vSInt32, mul_signed, 2)
FULLMUL64(vS64FullMulOdd, vSInt32, mul_signed, 0)

#define DIVIDE(name, V, DIV, n)                                                                          \
    V name(V a, V d, V *remainder)                                                                       \
    {                                                                                                    \
        Quad x = quad((vUInt32)a), y = quad((vUInt32)d), q, r;                                           \
        for (int i = 0; i < 4; i += n)                                                                   \
            DIV(q.w + i, r.w + i, x.w + i, y.w + i, n);                                                  \
        if (remainder)                                                                                   \
            *remainder = (V)r.v;                                                                         \
        return (V)q.v;                                                                                   \
    }

DIVIDE(vU64Divide, vUInt32, div_words, 2)
DIVIDE(vS64Divide, vSInt32, div_signed, 2)
DIVIDE(vU128Divide, vUInt32, div_words, 4)
DIVIDE(vS128Divide, vSInt32, div_signed, 4)

vUInt32 vU64Neg(vUInt32 a)
{
    Quad x = quad(a), r;
    neg_words(r.w, x.w, 2);
    neg_words(r.w + 2, x.w + 2, 2);
    return r.v;
}
vSInt32 vS64Neg(vSInt32 a) { return (vSInt32)vU64Neg((vUInt32)a); }
vUInt32 vU128Neg(vUInt32 a)
{
    Quad x = quad(a), r;
    neg_words(r.w, x.w, 4);
    return r.v;
}
vSInt32 vS128Neg(vSInt32 a) { return (vSInt32)vU128Neg((vUInt32)a); }

/* shifts and rotates: by byte 0, or by bytes 0 and 8 for the two lanes of the "2" forms */
enum { SHL, SHR, SAR, ROTL, ROTR };

static vUInt32 shift(vUInt32 a, vUInt8 f, int kind, int n, bool two)
{
    Quad x = quad(a), r;
    for (int i = 0; i < 4; i += n) {
        unsigned bits = (unsigned)n * 32, s = (two && i ? f[8] : f[0]) % bits;
        switch (kind) {
        case SHL: shl_words(r.w + i, x.w + i, n, s); break;
        case SHR: shr_words(r.w + i, x.w + i, n, s, false); break;
        case SAR: shr_words(r.w + i, x.w + i, n, s, true); break;
        case ROTL: rotl_words(r.w + i, x.w + i, n, s); break;
        default: rotl_words(r.w + i, x.w + i, n, bits - s); break;
        }
    }
    return r.v;
}

vUInt32 vLL64Shift(vUInt32 a, vUInt8 f) { return shift(a, f, SHL, 2, false); }
vUInt32 vLR64Shift(vUInt32 a, vUInt8 f) { return shift(a, f, SHR, 2, false); }
vUInt32 vA64Shift(vUInt32 a, vUInt8 f) { return shift(a, f, SAR, 2, false); }
vUInt32 vLL64Shift2(vUInt32 a, vUInt8 f) { return shift(a, f, SHL, 2, true); }
vUInt32 vLR64Shift2(vUInt32 a, vUInt8 f) { return shift(a, f, SHR, 2, true); }
vUInt32 vA64Shift2(vUInt32 a, vUInt8 f) { return shift(a, f, SAR, 2, true); }
vUInt32 vLL128Shift(vUInt32 a, vUInt8 f) { return shift(a, f, SHL, 4, false); }
vUInt32 vLR128Shift(vUInt32 a, vUInt8 f) { return shift(a, f, SHR, 4, false); }
vUInt32 vA128Shift(vUInt32 a, vUInt8 f) { return shift(a, f, SAR, 4, false); }
vUInt32 vL64Rotate(vUInt32 a, vUInt8 f) { return shift(a, f, ROTL, 2, false); }
vUInt32 vR64Rotate(vUInt32 a, vUInt8 f) { return shift(a, f, ROTR, 2, false); }
vUInt32 vL64Rotate2(vUInt32 a, vUInt8 f) { return shift(a, f, ROTL, 2, true); }
vUInt32 vR64Rotate2(vUInt32 a, vUInt8 f) { return shift(a, f, ROTR, 2, true); }
vUInt32 vL128Rotate(vUInt32 a, vUInt8 f) { return shift(a, f, ROTL, 4, false); }
vUInt32 vR128Rotate(vUInt32 a, vUInt8 f) { return shift(a, f, ROTR, 4, false); }
