/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <CarbonCore/PLStringFuncs.h>
#include <string.h>

static short
pl_compare(ConstStr255Param left, ConstStr255Param right, size_t limit)
{
    size_t leftLength = left[0];
    size_t rightLength = right[0];
    size_t count = leftLength < rightLength ? leftLength : rightLength;
    if (count > limit) count = limit;
    int result = memcmp(left + 1, right + 1, count);
    if (result) return (short)result;
    if (count == limit) return 0;
    return leftLength < rightLength ? -1 : leftLength > rightLength ? 1 : 0;
}

short
PLstrcmp(ConstStr255Param str1, ConstStr255Param str2)
{
    return pl_compare(str1, str2, 255);
}

short
PLstrncmp(ConstStr255Param str1, ConstStr255Param str2, short num)
{
    return pl_compare(str1, str2, num > 0 ? (size_t)num : 0);
}

StringPtr
PLstrcpy(StringPtr dest, ConstStr255Param source)
{
    memmove(dest, source, (size_t)source[0] + 1);
    return dest;
}

StringPtr
PLstrncpy(StringPtr dest, ConstStr255Param source, short num)
{
    size_t count = source[0];
    if (num < 0) num = 0;
    if (count > (size_t)num) count = (size_t)num;
    memmove(dest + 1, source + 1, count);
    dest[0] = (UInt8)count;
    return dest;
}

StringPtr
PLstrcat(StringPtr str, ConstStr255Param append)
{
    size_t oldLength = str[0];
    size_t addLength = append[0];
    if (addLength > 255 - oldLength) addLength = 255 - oldLength;
    memmove(str + oldLength + 1, append + 1, addLength);
    str[0] = (UInt8)(oldLength + addLength);
    return str;
}

StringPtr
PLstrncat(StringPtr str, ConstStr255Param append, short num)
{
    size_t oldLength = str[0];
    size_t addLength = append[0];
    if (num < 0) num = 0;
    if (addLength > (size_t)num) addLength = (size_t)num;
    if (addLength > 255 - oldLength) addLength = 255 - oldLength;
    memmove(str + oldLength + 1, append + 1, addLength);
    str[0] = (UInt8)(oldLength + addLength);
    return str;
}

Ptr
PLstrchr(ConstStr255Param str, short ch)
{
    const UInt8 *found = memchr(str + 1, (UInt8)ch, str[0]);
    return (Ptr)found;
}

Ptr
PLstrrchr(ConstStr255Param str, short ch)
{
    UInt8 wanted = (UInt8)ch;
    for (size_t i = str[0]; i > 0; i--)
        if (str[i] == wanted) return (Ptr)(str + i);
    return NULL;
}

Ptr
PLstrpbrk(ConstStr255Param str, ConstStr255Param charSet)
{
    for (size_t i = 1; i <= str[0]; i++)
        for (size_t j = 1; j <= charSet[0]; j++)
            if (str[i] == charSet[j]) return (Ptr)(str + i);
    return NULL;
}

short
PLstrspn(ConstStr255Param str, ConstStr255Param charSet)
{
    size_t i = 1;
    for (; i <= str[0]; i++) {
        size_t j = 1;
        for (; j <= charSet[0] && str[i] != charSet[j]; j++) {}
        if (j > charSet[0]) break;
    }
    return (short)(i - 1);
}

Ptr
PLstrstr(ConstStr255Param str, ConstStr255Param search)
{
    size_t length = search[0];
    if (length == 0) return (Ptr)(str + 1);
    if (length > str[0]) return NULL;
    for (size_t i = 1; i + length - 1 <= str[0]; i++)
        if (memcmp(str + i, search + 1, length) == 0) return (Ptr)(str + i);
    return NULL;
}

short
PLstrlen(ConstStr255Param str)
{
    return str[0];
}

short
PLpos(ConstStr255Param str, ConstStr255Param search)
{
    Ptr found = PLstrstr(str, search);
    return found ? (short)(found - (Ptr)str) : 0;
}
