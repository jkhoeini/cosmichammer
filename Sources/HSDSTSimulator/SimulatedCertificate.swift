import Foundation
import HSDSTCore

public final class SimulatedCertificate: CertificateProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig

    private var nextID: UInt64 = 1

    // Key pair storage
    public var keyPairs: [UInt64: KeyPairHandle] = [:]

    // Certificate storage
    public var certificates: [UInt64: CertificateInfo] = [:]
    public var certificateDER: [UInt64: Data] = [:]
    public var certificateKeyPairBindings: [UInt64: UInt64] = [:]  // certID -> keyPairID

    // Identity storage (certificate + key pair)
    public var identities: [UInt64: (certificateID: UInt64, keyPairID: UInt64)] = [:]

    // Keychain state
    public var keychainCertificates: Set<UInt64> = []
    public var certificatePreferences: [String: UInt64] = [:]  // domain -> certID

    public init(rng: RPRNG, faults: FaultConfig) {
        self.rng = rng
        self.faults = faults
    }

    private func allocateID() -> UInt64 {
        let id = nextID
        nextID += 1
        return id
    }

    // MARK: - Key generation

    public func generateKeyPair(keySize: Int, label: String) -> UInt64? {
        let id = allocateID()
        let publicKeyData = Data((0..<(keySize / 8)).map { _ in UInt8(rng.next() & 0xFF) })
        keyPairs[id] = KeyPairHandle(id: id, publicKeyData: publicKeyData, keySize: keySize)
        return id
    }

    public func destroyKeyPair(keyPairID: UInt64) -> Bool {
        keyPairs.removeValue(forKey: keyPairID) != nil
    }

    // MARK: - Certificate creation

    public func createSelfSignedCertificate(keyPairID: UInt64, commonName: String, validDays: Int) -> UInt64? {
        guard keyPairs[keyPairID] != nil else { return nil }
        let id = allocateID()
        let now = Date()
        let serialBytes = (0..<8).map { _ in String(format: "%02X", UInt8(rng.next() & 0xFF)) }
        let fingerprintBytes = (0..<20).map { _ in String(format: "%02x", UInt8(rng.next() & 0xFF)) }
        certificates[id] = CertificateInfo(
            commonName: commonName,
            serialNumber: serialBytes.joined(separator: ":"),
            issuer: commonName,
            notBefore: now,
            notAfter: Calendar.current.date(byAdding: .day, value: validDays, to: now),
            isValid: true,
            fingerprint: fingerprintBytes.joined(separator: ":"),
            subjectSummary: commonName
        )
        certificateDER[id] = Data((0..<256).map { _ in UInt8(rng.next() & 0xFF) })
        certificateKeyPairBindings[id] = keyPairID
        return id
    }

    public func loadCertificate(fromDER data: Data) -> UInt64? {
        guard !data.isEmpty else { return nil }
        let id = allocateID()
        certificates[id] = CertificateInfo(
            commonName: "Imported",
            serialNumber: "00:00:00:01",
            isValid: true,
            subjectSummary: "Imported Certificate"
        )
        certificateDER[id] = data
        return id
    }

    public func certificateInfo(certificateID: UInt64) -> CertificateInfo? {
        certificates[certificateID]
    }

    public func certificateDERData(certificateID: UInt64) -> Data? {
        certificateDER[certificateID]
    }

    public func destroyCertificate(certificateID: UInt64) -> Bool {
        guard certificates.removeValue(forKey: certificateID) != nil else { return false }
        certificateDER.removeValue(forKey: certificateID)
        certificateKeyPairBindings.removeValue(forKey: certificateID)
        keychainCertificates.remove(certificateID)
        certificatePreferences = certificatePreferences.filter { $0.value != certificateID }
        return true
    }

    // MARK: - Identity

    public func createIdentity(certificateID: UInt64, keyPairID: UInt64) -> UInt64? {
        guard certificates[certificateID] != nil, keyPairs[keyPairID] != nil else { return nil }
        let id = allocateID()
        identities[id] = (certificateID: certificateID, keyPairID: keyPairID)
        return id
    }

    public func destroyIdentity(identityID: UInt64) -> Bool {
        identities.removeValue(forKey: identityID) != nil
    }

    // MARK: - Keychain operations

    public func addToKeychain(certificateID: UInt64) -> Bool {
        guard certificates[certificateID] != nil else { return false }
        keychainCertificates.insert(certificateID)
        return true
    }

    public func removeFromKeychain(certificateID: UInt64) -> Bool {
        keychainCertificates.remove(certificateID) != nil
    }

    public func setCertificatePreference(certificateID: UInt64, forDomain domain: String) -> Bool {
        guard certificates[certificateID] != nil else { return false }
        certificatePreferences[domain] = certificateID
        return true
    }

    public func findPreferredCertificate(forDomain domain: String) -> UInt64? {
        certificatePreferences[domain]
    }

    // MARK: - Trust evaluation

    public func evaluateTrust(certificateChain: [UInt64]) -> TrustEvaluationResult {
        let infos = certificateChain.compactMap { certificates[$0] }
        guard !infos.isEmpty, infos.count == certificateChain.count else {
            return TrustEvaluationResult(trusted: false, certificateChain: [])
        }
        let allValid = infos.allSatisfy { $0.isValid }
        return TrustEvaluationResult(trusted: allValid, certificateChain: infos)
    }

    // MARK: - Data signing

    public func signData(_ data: Data, withKeyPairID keyPairID: UInt64) -> Data? {
        guard keyPairs[keyPairID] != nil else { return nil }
        // Produce deterministic pseudo-signature from rng
        return Data((0..<64).map { _ in UInt8(rng.next() & 0xFF) })
    }
}
