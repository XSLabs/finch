import CryptoKit
import Darwin
import Foundation

func loadedFramework() -> String {
    for index in 0..<_dyld_image_count() {
        guard let name = _dyld_get_image_name(index) else { continue }
        let path = String(cString: name)
        if path.contains("/CryptoKit.framework/") {
            return path
        }
    }
    return "CryptoKit framework not found"
}

func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
}

func scalar(_ length: Int, _ last: UInt8) -> Data {
    var bytes = [UInt8](repeating: 0, count: length)
    bytes[length - 1] = last
    return Data(bytes)
}

func keyBytes(_ key: SymmetricKey) -> Data {
    key.withUnsafeBytes { Data($0) }
}

let message = Data("Finch CryptoKit comparison".utf8)
print("framework: \(loadedFramework())")
print("SHA256: \(hex(SHA256.hash(data: message)))")
print("SHA384: \(hex(SHA384.hash(data: message)))")
print("SHA512: \(hex(SHA512.hash(data: message)))")
print("SHA1: \(hex(Insecure.SHA1.hash(data: message)))")
print("MD5: \(hex(Insecure.MD5.hash(data: message)))")

let symmetricKey = SymmetricKey(data: scalar(32, 7))
let mac = HMAC<SHA256>.authenticationCode(for: message, using: symmetricKey)
print("HMAC-SHA256: \(hex(mac))")
print("HMAC verified: \(HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: message, using: symmetricKey))")

let derivedKey = HKDF<SHA256>.deriveKey(
    inputKeyMaterial: symmetricKey,
    salt: Data("fixed salt".utf8),
    info: Data("Finch comparison".utf8),
    outputByteCount: 32
)
print("HKDF-SHA256: \(hex(keyBytes(derivedKey)))")

let nonceBytes = Data((0..<12).map { UInt8($0) })
let aesNonce = try AES.GCM.Nonce(data: nonceBytes)
let aesBox = try AES.GCM.seal(message, using: symmetricKey, nonce: aesNonce)
print("AES-GCM: \(hex(aesBox.combined ?? Data()))")
print("AES-GCM opened: \(try AES.GCM.open(aesBox, using: symmetricKey) == message)")

let chachaNonce = try ChaChaPoly.Nonce(data: nonceBytes)
let chachaBox = try ChaChaPoly.seal(message, using: symmetricKey, nonce: chachaNonce)
print("ChaChaPoly: \(hex(chachaBox.combined))")
print("ChaChaPoly opened: \(try ChaChaPoly.open(chachaBox, using: symmetricKey) == message)")

let p256Alice = try P256.KeyAgreement.PrivateKey(rawRepresentation: scalar(32, 1))
let p256Bob = try P256.KeyAgreement.PrivateKey(rawRepresentation: scalar(32, 2))
let p256Left = try p256Alice.sharedSecretFromKeyAgreement(with: p256Bob.publicKey)
let p256Right = try p256Bob.sharedSecretFromKeyAgreement(with: p256Alice.publicKey)
let p256Shared = p256Left.withUnsafeBytes { Data($0) }
let p256Public = try P256.KeyAgreement.PublicKey(rawRepresentation: p256Alice.publicKey.rawRepresentation)
let p256X963 = try P256.KeyAgreement.PublicKey(x963Representation: p256Alice.publicKey.x963Representation)
let p256Private = try P256.KeyAgreement.PrivateKey(rawRepresentation: p256Alice.rawRepresentation)
print("P256 shared secret: \(hex(p256Shared))")
print("P256 agreement representations: \(p256Private.rawRepresentation == p256Alice.rawRepresentation && p256Public.rawRepresentation == p256Alice.publicKey.rawRepresentation && p256X963.rawRepresentation == p256Alice.publicKey.rawRepresentation)")
let p256Signer = try P256.Signing.PrivateKey(rawRepresentation: scalar(32, 3))
let p256Signature = try p256Signer.signature(for: message)
let p256SigningPublic = try P256.Signing.PublicKey(x963Representation: p256Signer.publicKey.x963Representation)
print("P256 signature verified: \(p256SigningPublic.isValidSignature(p256Signature, for: message))")
print("P256 signing representation: \(p256SigningPublic.rawRepresentation == p256Signer.publicKey.rawRepresentation)")
print("P256 peers agree: \(p256Shared == p256Right.withUnsafeBytes { Data($0) })")

let p384Alice = try P384.KeyAgreement.PrivateKey(rawRepresentation: scalar(48, 1))
let p384Bob = try P384.KeyAgreement.PrivateKey(rawRepresentation: scalar(48, 2))
let p384Left = try p384Alice.sharedSecretFromKeyAgreement(with: p384Bob.publicKey)
let p384Right = try p384Bob.sharedSecretFromKeyAgreement(with: p384Alice.publicKey)
let p384Shared = p384Left.withUnsafeBytes { Data($0) }
let p384Public = try P384.KeyAgreement.PublicKey(rawRepresentation: p384Alice.publicKey.rawRepresentation)
let p384X963 = try P384.KeyAgreement.PublicKey(x963Representation: p384Alice.publicKey.x963Representation)
let p384Private = try P384.KeyAgreement.PrivateKey(rawRepresentation: p384Alice.rawRepresentation)
print("P384 shared secret: \(hex(p384Shared))")
print("P384 agreement representations: \(p384Private.rawRepresentation == p384Alice.rawRepresentation && p384Public.rawRepresentation == p384Alice.publicKey.rawRepresentation && p384X963.rawRepresentation == p384Alice.publicKey.rawRepresentation)")
let p384Signer = try P384.Signing.PrivateKey(rawRepresentation: scalar(48, 3))
let p384Signature = try p384Signer.signature(for: message)
let p384SigningPublic = try P384.Signing.PublicKey(x963Representation: p384Signer.publicKey.x963Representation)
print("P384 signature verified: \(p384SigningPublic.isValidSignature(p384Signature, for: message))")
print("P384 signing representation: \(p384SigningPublic.rawRepresentation == p384Signer.publicKey.rawRepresentation)")
print("P384 peers agree: \(p384Shared == p384Right.withUnsafeBytes { Data($0) })")

let curveAlice = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x11, count: 32))
let curveBob = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x22, count: 32))
let curveLeft = try curveAlice.sharedSecretFromKeyAgreement(with: curveBob.publicKey)
let curveRight = try curveBob.sharedSecretFromKeyAgreement(with: curveAlice.publicKey)
let curveShared = curveLeft.withUnsafeBytes { Data($0) }
let curvePublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: curveAlice.publicKey.rawRepresentation)
let curvePrivate = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: curveAlice.rawRepresentation)
print("Curve25519 shared secret: \(hex(curveShared))")
print("Curve25519 agreement representations: \(curvePrivate.rawRepresentation == curveAlice.rawRepresentation && curvePublic.rawRepresentation == curveAlice.publicKey.rawRepresentation)")
let curveSigner = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x33, count: 32))
let curveSignature = try curveSigner.signature(for: message)
let curveSigningPublic = try Curve25519.Signing.PublicKey(rawRepresentation: curveSigner.publicKey.rawRepresentation)
print("Curve25519 signature verified: \(curveSigningPublic.isValidSignature(curveSignature, for: message))")
print("Curve25519 signing representation: \(curveSigningPublic.rawRepresentation == curveSigner.publicKey.rawRepresentation)")
print("Curve25519 peers agree: \(curveShared == curveRight.withUnsafeBytes { Data($0) })")
