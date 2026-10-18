import Foundation
import CryptoKit

public class TandemCrypto {
    public static let shared = TandemCrypto()
    
    private static let kdfSalt = "Tandem-v0.2-Salt".data(using: .utf8)!
    private static let kdfInfo = "AES-256-GCM".data(using: .utf8)!
    
    private var privateKey: P256.KeyAgreement.PrivateKey?
    private(set) public var sessionKey: SymmetricKey?
    private(set) public var securityCode: String?
    
    public var isEncrypted: Bool { sessionKey != nil }
    
    public init() {
        resetKeypair()
    }
    
    public func resetKeypair() {
        privateKey = P256.KeyAgreement.PrivateKey()
        sessionKey = nil
        securityCode = nil
    }
    
    /// Returns our local 64-byte uncompressed raw public key representation (X || Y)
    public func getLocalRawPublicKey() -> Data? {
        guard let priv = privateKey else { return nil }
        return priv.publicKey.rawRepresentation
    }
    
    /// Computes shared secret from peer raw public key, derives AES-256 session key, and generates 6-digit SAS code
    public func completeKeyExchange(peerRawPub: Data) throws -> String {
        guard let myPriv = privateKey else {
            throw TandemCryptoError.missingPrivateKey
        }
        guard peerRawPub.count == 64 else {
            throw TandemCryptoError.invalidPublicKeyLength(peerRawPub.count)
        }
        
        let peerPub = try P256.KeyAgreement.PublicKey(rawRepresentation: peerRawPub)
        let sharedSecret = try myPriv.sharedSecretFromKeyAgreement(with: peerPub)
        
        let derivedKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Self.kdfSalt,
            sharedInfo: Self.kdfInfo,
            outputByteCount: 32
        )
        self.sessionKey = derivedKey
        
        // Compute 6-digit Short Authentication String (SAS)
        let myPubRaw = myPriv.publicKey.rawRepresentation
        let sas = Self.computeSasCode(pubA: myPubRaw, pubB: peerRawPub)
        self.securityCode = sas
        return sas
    }
    
    /// Encrypts plaintext string with AES-256-GCM.
    /// Returns Base64-encoded combined payload: IV (12 bytes) + Ciphertext + Tag (16 bytes)
    public func encrypt(plaintext: String) throws -> String {
        guard let key = sessionKey else {
            throw TandemCryptoError.noActiveSessionKey
        }
        guard let data = plaintext.data(using: .utf8) else {
            throw TandemCryptoError.encodingError
        }
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else {
            throw TandemCryptoError.encryptionFailed
        }
        return combined.base64EncodedString()
    }
    
    /// Decrypts Base64-encoded combined payload: IV (12 bytes) + Ciphertext + Tag (16 bytes)
    public func decrypt(base64Ciphertext: String) throws -> String {
        guard let key = sessionKey else {
            throw TandemCryptoError.noActiveSessionKey
        }
        guard let combinedData = Data(base64Encoded: base64Ciphertext) else {
            throw TandemCryptoError.invalidBase64
        }
        let sealedBox = try AES.GCM.SealedBox(combined: combinedData)
        let decryptedData = try AES.GCM.open(sealedBox, using: key)
        guard let text = String(data: decryptedData, encoding: .utf8) else {
            throw TandemCryptoError.decodingError
        }
        return text
    }
    
    /// Generates identical 6-digit code on both sides by ordering public keys lexicographically
    public static func computeSasCode(pubA: Data, pubB: Data) -> String {
        let (first, second) = pubA.lexicographicallyPrecedes(pubB) ? (pubA, pubB) : (pubB, pubA)
        var combined = Data()
        combined.append(first)
        combined.append(second)
        let digest = SHA256.hash(data: combined)
        let prefixBytes = Array(digest.prefix(4))
        let num = (UInt32(prefixBytes[0]) << 24) |
                  (UInt32(prefixBytes[1]) << 16) |
                  (UInt32(prefixBytes[2]) << 8)  |
                   UInt32(prefixBytes[3])
        let code = num % 1_000_000
        return String(format: "%03d-%03d", code / 1000, code % 1000)
    }
}

public enum TandemCryptoError: LocalizedError {
    case missingPrivateKey
    case invalidPublicKeyLength(Int)
    case noActiveSessionKey
    case encodingError
    case decodingError
    case invalidBase64
    case encryptionFailed
    
    public var errorDescription: String? {
        switch self {
        case .missingPrivateKey: return "Local private key not initialized"
        case .invalidPublicKeyLength(let len): return "Expected 64-byte raw public key, received \(len) bytes"
        case .noActiveSessionKey: return "No active E2EE session key derived"
        case .encodingError: return "Failed to encode plaintext to UTF-8"
        case .decodingError: return "Failed to decode decrypted bytes as UTF-8"
        case .invalidBase64: return "Invalid Base64 ciphertext input"
        case .encryptionFailed: return "AES-GCM encryption seal operation failed"
        }
    }
}
