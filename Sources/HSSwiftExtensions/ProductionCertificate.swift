import Foundation
import HSDSTCore

final class ProductionCertificate: CertificateProtocol {
    func generateKeyPair(keySize: Int, label: String) -> UInt64? { nil }
    func destroyKeyPair(keyPairID: UInt64) -> Bool { false }

    func createSelfSignedCertificate(keyPairID: UInt64, commonName: String, validDays: Int) -> UInt64? { nil }
    func loadCertificate(fromDER data: Data) -> UInt64? { nil }
    func certificateInfo(certificateID: UInt64) -> CertificateInfo? { nil }
    func certificateDERData(certificateID: UInt64) -> Data? { nil }
    func destroyCertificate(certificateID: UInt64) -> Bool { false }

    func createIdentity(certificateID: UInt64, keyPairID: UInt64) -> UInt64? { nil }
    func destroyIdentity(identityID: UInt64) -> Bool { false }

    func addToKeychain(certificateID: UInt64) -> Bool { false }
    func removeFromKeychain(certificateID: UInt64) -> Bool { false }
    func setCertificatePreference(certificateID: UInt64, forDomain: String) -> Bool { false }
    func findPreferredCertificate(forDomain: String) -> UInt64? { nil }

    func evaluateTrust(certificateChain: [UInt64]) -> TrustEvaluationResult {
        TrustEvaluationResult(trusted: false, certificateChain: [])
    }

    func signData(_ data: Data, withKeyPairID: UInt64) -> Data? { nil }
}
