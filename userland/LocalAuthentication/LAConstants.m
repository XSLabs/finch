/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* LocalAuthentication's exported constants, with the values Apple's have (tools/gen-constants.py). */
#import <Foundation/Foundation.h>

NSString *const LAAvailableMechanisms = @"AvailableMechanisms";
NSString *const LABiometryDatabaseHash = @"BiometryDatabaseHash";
NSString *const LAEnabledBiometryUsers = @"EnabledBiometryUsers";
NSString *const LAErrorDomain = @"com.apple.LocalAuthentication";
NSString *const LAErrorInfoBiometryType = @"BiometryType";
NSString *const LAErrorInfoTCCServerPrompt = @"TCCServerPrompt";
NSString *const LAErrorInfoTCCService = @"TCCService";
NSString *const LAErrorNonceKey = @"Nonce";
NSString *const LAErrorSubcodeKey = @"Subcode";
NSString *const LAMechanismTree = @"MechanismTree";
NSString *const LAPasswordRetryTime = @"RetryTime";
NSString *const LAStorageErrorDomain = @"com.apple.LocalAuthentication.Storage";
const double LATouchIDAuthenticationMaximumAllowableReuseDuration = 300;
NSString *const LAUserErrorDomain = @"com.apple.LocalAuthentication.UserErrorDomain";
NSString *const kAPKekPassword = @"kAPMP";
NSString *const kAPMasterKey = @"kAPMK";
