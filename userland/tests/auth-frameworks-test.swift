// SPDX-License-Identifier: MIT OR Apache-2.0
import AppKit
import AuthenticationServices
import Foundation
import ObjectiveC
import SecurityInterface

func imageName(_ type: AnyClass) -> String {
    guard let path = class_getImageName(type) else { return "missing" }
    return String(cString: path)
}

print("images: \(imageName(SFCertificateView.self)) | \(imageName(ASAuthorizationController.self))")

let certificateView = SFCertificateView(frame: .zero)
print("certificate-view: \(certificateView.isEditable()) \(certificateView.isTrustDisplayed()) \(certificateView.detailsDisplayed()) \(certificateView.detailsDisclosed()) \(certificateView.policiesDisclosed()) \(certificateView.policies()?.count ?? 0)")

let appleIDProvider = ASAuthorizationAppleIDProvider()
let appleIDRequest = appleIDProvider.createRequest()
appleIDRequest.requestedScopes = [.email, .fullName]
appleIDRequest.state = "finch-state"
appleIDRequest.nonce = "finch-nonce"
appleIDRequest.requestedOperation = .operationLogin
print("apple-id-request: \(appleIDRequest.provider is ASAuthorizationAppleIDProvider) \(appleIDRequest.requestedScopes?.count ?? 0) \(appleIDRequest.state ?? "") \(appleIDRequest.nonce ?? "") \(appleIDRequest.requestedOperation.rawValue)")

let challenge = Data([1, 2, 3, 4])
let platformProvider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: "example.test")
let assertionRequest = platformProvider.createCredentialAssertionRequest(challenge: challenge)
print("passkey-request: \(assertionRequest.challenge == challenge) \(assertionRequest.relyingPartyIdentifier) \(assertionRequest.allowedCredentials.count)")

let clientData = ASPublicKeyCredentialClientData(challenge: challenge, origin: "https://example.test", topOrigin: "https://parent.test", crossOrigin: .crossOrigin)
let browserRequest = platformProvider.createCredentialAssertionRequest(clientData: clientData)
let returnedClientData = browserRequest.clientData
print("client-data: \(returnedClientData?.challenge == challenge) \(returnedClientData?.origin ?? "") \(returnedClientData?.topOrigin ?? "") \(returnedClientData?.crossOrigin == .crossOrigin)")

let password = ASPasswordCredential(user: "finch-user", password: "finch-password")
print("password-credential: \(password.user) \(password.password)")
