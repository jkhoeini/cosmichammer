import Foundation

public struct CertificateInfo: Sendable {
    public var commonName: String?
    public var serialNumber: String?
    public var issuer: String?
    public var notBefore: Date?
    public var notAfter: Date?
    public var isValid: Bool
    public var fingerprint: String?
    public var subjectSummary: String?

    public init(commonName: String? = nil, serialNumber: String? = nil,
                issuer: String? = nil, notBefore: Date? = nil,
                notAfter: Date? = nil, isValid: Bool = false,
                fingerprint: String? = nil, subjectSummary: String? = nil) {
        self.commonName = commonName
        self.serialNumber = serialNumber
        self.issuer = issuer
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.isValid = isValid
        self.fingerprint = fingerprint
        self.subjectSummary = subjectSummary
    }
}

public struct KeyPairHandle: Sendable {
    public var id: UInt64
    public var publicKeyData: Data?
    public var keySize: Int

    public init(id: UInt64 = 0, publicKeyData: Data? = nil, keySize: Int = 2048) {
        self.id = id
        self.publicKeyData = publicKeyData
        self.keySize = keySize
    }
}

public struct TrustEvaluationResult: Sendable {
    public var trusted: Bool
    public var certificateChain: [CertificateInfo]

    public init(trusted: Bool = false, certificateChain: [CertificateInfo] = []) {
        self.trusted = trusted
        self.certificateChain = certificateChain
    }
}

public protocol CertificateProtocol: AnyObject {
    // Key generation
    func generateKeyPair(keySize: Int, label: String) -> UInt64?
    func destroyKeyPair(keyPairID: UInt64) -> Bool

    // Certificate creation
    func createSelfSignedCertificate(keyPairID: UInt64, commonName: String, validDays: Int) -> UInt64?
    func loadCertificate(fromDER data: Data) -> UInt64?
    func certificateInfo(certificateID: UInt64) -> CertificateInfo?
    func certificateDERData(certificateID: UInt64) -> Data?
    func destroyCertificate(certificateID: UInt64) -> Bool

    // Identity (certificate + private key)
    func createIdentity(certificateID: UInt64, keyPairID: UInt64) -> UInt64?
    func destroyIdentity(identityID: UInt64) -> Bool

    // Keychain operations
    func addToKeychain(certificateID: UInt64) -> Bool
    func removeFromKeychain(certificateID: UInt64) -> Bool
    func setCertificatePreference(certificateID: UInt64, forDomain: String) -> Bool
    func findPreferredCertificate(forDomain: String) -> UInt64?

    // Trust evaluation
    func evaluateTrust(certificateChain: [UInt64]) -> TrustEvaluationResult

    // Data signing
    func signData(_ data: Data, withKeyPairID: UInt64) -> Data?
}
