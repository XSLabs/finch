/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Trust settings: the user's, the administrator's and the system's choices of which
 * certificates to trust for what. Finch keeps none yet (and has no system root store:
 * docs/design/SECURITY.md), so each domain answers as one without settings does.
 */
#include <Security/Security.h>

OSStatus
SecTrustSettingsCopyCertificates(SecTrustSettingsDomain domain, CFArrayRef *certArray)
{
    if (certArray)
        *certArray = NULL;
    return errSecNoTrustSettings;
}

OSStatus
SecTrustSettingsCopyTrustSettings(SecCertificateRef certRef, SecTrustSettingsDomain domain, CFArrayRef *trustSettings)
{
    if (trustSettings)
        *trustSettings = NULL;
    return certRef ? errSecItemNotFound : errSecParam;
}

OSStatus
SecTrustSettingsCopyModificationDate(SecCertificateRef certRef, SecTrustSettingsDomain domain, CFDateRef *modificationDate)
{
    if (modificationDate)
        *modificationDate = NULL;
    return certRef ? errSecItemNotFound : errSecParam;
}

/* (changing them: there's no settings store to keep them in yet) */
OSStatus
SecTrustSettingsSetTrustSettings(SecCertificateRef certRef, SecTrustSettingsDomain domain, CFTypeRef trustSettingsDictOrArray)
{
    return errSecUnimplemented;
}

OSStatus
SecTrustSettingsRemoveTrustSettings(SecCertificateRef certRef, SecTrustSettingsDomain domain)
{
    return errSecItemNotFound;
}

OSStatus
SecTrustSettingsCreateExternalRepresentation(SecTrustSettingsDomain domain, CFDataRef *trustSettings)
{
    if (trustSettings)
        *trustSettings = NULL;
    return errSecNoTrustSettings;
}

OSStatus
SecTrustSettingsImportExternalRepresentation(SecTrustSettingsDomain domain, CFDataRef trustSettings)
{
    return errSecUnimplemented;
}
