/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Unicode categories and bidi classes from the system ICU Unicode tables. */
#include "CarbonCore_Finch.h"
#include <unicode/uchar.h>

static UCCharPropertyValue
general_category(UCharCategory category)
{
    switch (category) {
    case U_UNASSIGNED: return kUCGenlCatOtherNotAssigned;
    case U_CONTROL_CHAR: return kUCGenlCatOtherControl;
    case U_FORMAT_CHAR: return kUCGenlCatOtherFormat;
    case U_SURROGATE: return kUCGenlCatOtherSurrogate;
    case U_PRIVATE_USE_CHAR: return kUCGenlCatOtherPrivateUse;
    case U_NON_SPACING_MARK: return kUCGenlCatMarkNonSpacing;
    case U_COMBINING_SPACING_MARK: return kUCGenlCatMarkSpacingCombining;
    case U_ENCLOSING_MARK: return kUCGenlCatMarkEnclosing;
    case U_DECIMAL_DIGIT_NUMBER: return kUCGenlCatNumberDecimalDigit;
    case U_LETTER_NUMBER: return kUCGenlCatNumberLetter;
    case U_OTHER_NUMBER: return kUCGenlCatNumberOther;
    case U_SPACE_SEPARATOR: return kUCGenlCatSeparatorSpace;
    case U_LINE_SEPARATOR: return kUCGenlCatSeparatorLine;
    case U_PARAGRAPH_SEPARATOR: return kUCGenlCatSeparatorParagraph;
    case U_UPPERCASE_LETTER: return kUCGenlCatLetterUppercase;
    case U_LOWERCASE_LETTER: return kUCGenlCatLetterLowercase;
    case U_TITLECASE_LETTER: return kUCGenlCatLetterTitlecase;
    case U_MODIFIER_LETTER: return kUCGenlCatLetterModifier;
    case U_OTHER_LETTER: return kUCGenlCatLetterOther;
    case U_CONNECTOR_PUNCTUATION: return kUCGenlCatPunctConnector;
    case U_DASH_PUNCTUATION: return kUCGenlCatPunctDash;
    case U_START_PUNCTUATION: return kUCGenlCatPunctOpen;
    case U_END_PUNCTUATION: return kUCGenlCatPunctClose;
    case U_INITIAL_PUNCTUATION: return kUCGenlCatPunctInitialQuote;
    case U_FINAL_PUNCTUATION: return kUCGenlCatPunctFinalQuote;
    case U_OTHER_PUNCTUATION: return kUCGenlCatPunctOther;
    case U_MATH_SYMBOL: return kUCGenlCatSymbolMath;
    case U_CURRENCY_SYMBOL: return kUCGenlCatSymbolCurrency;
    case U_MODIFIER_SYMBOL: return kUCGenlCatSymbolModifier;
    case U_OTHER_SYMBOL: return kUCGenlCatSymbolOther;
    default: return kUCGenlCatOtherNotAssigned;
    }
}

static UChar32
first_scalar(const UniChar *chars, UniCharCount length)
{
    UChar32 scalar = chars[0];
    if (length > 1 && U16_IS_LEAD(chars[0]) && U16_IS_TRAIL(chars[1]))
        scalar = U16_GET_SUPPLEMENTARY(chars[0], chars[1]);
    return scalar;
}

OSStatus
UCGetCharProperty(const UniChar *charPtr, UniCharCount textLength, UCCharPropertyType propType,
                  UCCharPropertyValue *propValue)
{
    if (!charPtr || !textLength || !propValue)
        return paramErr;
    UChar32 scalar = first_scalar(charPtr, textLength);
    switch (propType) {
    case kUCCharPropTypeGenlCategory:
        *propValue = general_category((UCharCategory)u_charType(scalar));
        return noErr;
    case kUCCharPropTypeCombiningClass:
        *propValue = u_getCombiningClass(scalar);
        return noErr;
    case kUCCharPropTypeBidiCategory: {
        UCharDirection direction = u_charDirection(scalar);
        *propValue = u_charType(scalar) == U_UNASSIGNED ? kUCBidiCatNotApplicable : (UCCharPropertyValue)direction + 1;
        return noErr;
    }
    case kUCCharPropTypeDecimalDigitValue: {
        int32_t digit = u_charDigitValue(scalar);
        if (digit < 0 || digit > 9)
            return paramErr;
        *propValue = (UCCharPropertyValue)digit;
        return noErr;
    }
    default:
        return paramErr;
    }
}
