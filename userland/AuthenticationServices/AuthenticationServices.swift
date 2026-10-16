// SPDX-License-Identifier: MIT OR Apache-2.0
import Foundation
import FinchAuthClasses
import ObjectiveC

public struct ASPublicKeyCredentialClientData: Sendable {
    public enum CrossOriginValue: Sendable, Hashable {
        case crossOrigin
        case sameOriginWithAncestors
    }

    public var challenge: Data
    public var origin: String
    public var topOrigin: String?
    public var crossOrigin: CrossOriginValue?

    public init(challenge: Data, origin: String, topOrigin: String? = nil,
                crossOrigin: CrossOriginValue? = nil) {
        self.challenge = challenge
        self.origin = origin
        self.topOrigin = topOrigin
        self.crossOrigin = crossOrigin
    }
}

private final class ClientDataBox: NSObject {
    let value: ASPublicKeyCredentialClientData

    init(_ value: ASPublicKeyCredentialClientData) {
        self.value = value
    }
}

private let clientDataAssociationKey = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

private func remember(_ value: ASPublicKeyCredentialClientData, for request: AnyObject) {
    objc_setAssociatedObject(request, clientDataAssociationKey, ClientDataBox(value), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

private func rememberedValue(for request: AnyObject) -> ASPublicKeyCredentialClientData? {
    (objc_getAssociatedObject(request, clientDataAssociationKey) as? ClientDataBox)?.value
}

public extension ASAuthorizationWebBrowserPlatformPublicKeyCredentialAssertionRequest {
    var clientData: ASPublicKeyCredentialClientData? { rememberedValue(for: self) }
}

public extension ASAuthorizationWebBrowserPlatformPublicKeyCredentialRegistrationRequest {
    var clientData: ASPublicKeyCredentialClientData? { rememberedValue(for: self) }
}

public extension ASAuthorizationWebBrowserSecurityKeyPublicKeyCredentialAssertionRequest {
    var clientData: ASPublicKeyCredentialClientData? { rememberedValue(for: self) }
}

public extension ASAuthorizationWebBrowserSecurityKeyPublicKeyCredentialRegistrationRequest {
    var clientData: ASPublicKeyCredentialClientData? { rememberedValue(for: self) }
}

public extension ASAuthorizationPlatformPublicKeyCredentialProvider {
    func createCredentialAssertionRequest(clientData: ASPublicKeyCredentialClientData) -> ASAuthorizationPlatformPublicKeyCredentialAssertionRequest {
        let request = createCredentialAssertionRequest(challenge: clientData.challenge)
        remember(clientData, for: request)
        return request
    }

    func createCredentialRegistrationRequest(clientData: ASPublicKeyCredentialClientData, name: String, userID: Data) -> ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest {
        let request = createCredentialRegistrationRequest(challenge: clientData.challenge, name: name, userID: userID)
        remember(clientData, for: request)
        return request
    }
}

public extension ASAuthorizationSecurityKeyPublicKeyCredentialProvider {
    func createCredentialAssertionRequest(clientData: ASPublicKeyCredentialClientData) -> ASAuthorizationSecurityKeyPublicKeyCredentialAssertionRequest {
        let request = createCredentialAssertionRequest(challenge: clientData.challenge)
        remember(clientData, for: request)
        return request
    }

    func createCredentialRegistrationRequest(clientData: ASPublicKeyCredentialClientData, displayName: String, name: String, userID: Data) -> ASAuthorizationSecurityKeyPublicKeyCredentialRegistrationRequest {
        let request = createCredentialRegistrationRequest(challenge: clientData.challenge, displayName: displayName, name: name, userID: userID)
        remember(clientData, for: request)
        return request
    }
}
