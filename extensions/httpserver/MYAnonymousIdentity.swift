//
//  MYAnonymousIdentity.swift
//  MYUtilities
//
//  Created by Jens Alfke on 12/5/14.
//  Swift translation.
//

import Foundation
import Security
import CommonCrypto

let kMYAnonymousIdentityDefaultExpirationInterval: TimeInterval = 60 * 60 * 24 * 365.0

// Key size of kCertTemplate:
private let kKeySizeInBits: Int = 2048

// These are offsets into kCertTemplate where values need to be substituted:
private let kSerialLength: Int = 1
private let kDateLength: Int = 13
private let kPublicKeyLength: UInt = 270
private let kCSROffset: Int = 0
private let kSignatureLength: UInt = 256

// MARK: - Private Helpers

private func checkErr(_ err: OSStatus, _ outError: inout NSError?) -> Bool {
    if err == noErr { return true }

    let message = SecCopyErrorMessageString(err, nil) as String?
    var info: [String: Any]? = nil
    if let message = message {
        info = [NSLocalizedDescriptionKey: "\(message) (\(err))"]
    }
    outError = NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: info)
    return false
}

private func generateRSAKeyPair(sizeInBits: Int, permanent: Bool, label: String,
                                 publicKey: inout SecKey?, privateKey: inout SecKey?,
                                 outError: inout NSError?) -> Bool {
    let pairAttrs: [CFString: Any] = [
        kSecAttrKeyType: kSecAttrKeyTypeRSA,
        kSecAttrKeySizeInBits: sizeInBits,
        kSecAttrLabel: label,
        kSecAttrIsPermanent: permanent,
    ]

    var pubKey: SecKey?
    var privKey: SecKey?
    let err = SecKeyGeneratePair(pairAttrs as CFDictionary, &pubKey, &privKey)
    guard checkErr(err, &outError) else { return false }

    publicKey = pubKey
    privateKey = privKey
    return true
}

private func getPublicKeyData(_ publicKey: SecKey) -> Data? {
    var data: CFData?
    let err = SecItemExport(publicKey, .formatBSAFE, [], nil, &data)
    guard err == noErr, let cfData = data else { return nil }
    return cfData as Data
}

private func signData(_ privateKey: SecKey, _ inputData: Data) -> Data? {
    guard let transform = SecSignTransformCreate(privateKey, nil) else { return nil }
    defer { /* transform is managed by ARC for SecTransform */ }

    guard SecTransformSetAttribute(transform, kSecDigestTypeAttribute, kSecDigestSHA1, nil),
          SecTransformSetAttribute(transform, kSecTransformInputAttributeName, inputData as CFData, nil) else {
        return nil
    }

    let resultData = SecTransformExecute(transform, nil)
    return resultData as? Data
}

private func generateAnonymousCert(publicKey: SecKey, privateKey: SecKey,
                                    expirationInterval: TimeInterval,
                                    outError: inout NSError?) -> Data? {
    // Read the original template certificate file:
    let data = NSMutableData(bytes: kCertTemplate, length: MemoryLayout.size(ofValue: kCertTemplate))
    let buf = data.mutableBytes.assumingMemoryBound(to: UInt8.self)

    // Write the serial number:
    guard SecRandomCopyBytes(kSecRandomDefault, kSerialLength, &buf[Int(kSerialOffset)]) == 0 else {
        NSLog("SecRandomCopyBytes() failed")
        return nil
    }
    buf[Int(kSerialOffset)] &= 0x7F // non-negative

    // Write the issue and expiration dates:
    let x509DateFormatter = DateFormatter()
    x509DateFormatter.dateFormat = "yyMMddHHmmss'Z'"
    x509DateFormatter.timeZone = TimeZone(identifier: "GMT")

    var date = Date()
    var dateStr = x509DateFormatter.string(from: date)
    dateStr.withCString { ptr in
        memcpy(&buf[Int(kIssueDateOffset)], ptr, kDateLength)
    }

    date = date.addingTimeInterval(expirationInterval)
    dateStr = x509DateFormatter.string(from: date)
    dateStr.withCString { ptr in
        memcpy(&buf[Int(kExpDateOffset)], ptr, kDateLength)
    }

    // Copy the public key:
    guard let keyData = getPublicKeyData(publicKey) else { return nil }
    guard keyData.count == kPublicKeyLength else {
        NSLog("ERROR: keyData.length (%lu) != kPublicKeyLength (%u)", keyData.count, kPublicKeyLength)
        return nil
    }
    keyData.withUnsafeBytes { ptr in
        memcpy(&buf[Int(kPublicKeyOffset)], ptr.baseAddress!, Int(kPublicKeyLength))
    }

    // Sign the cert:
    let csr = data.subdata(with: NSRange(location: kCSROffset, length: Int(kCSRLength)))
    guard let sig = signData(privateKey, csr) else { return nil }
    guard sig.count == kSignatureLength else {
        NSLog("ERROR: sig.length (%lu) != kSignatureLength (%u)", sig.count, kSignatureLength)
        return nil
    }
    data.append(sig)

    return data as Data
}

private func addCertToKeychain(_ certData: Data, label: String,
                                outError: inout NSError?) -> SecCertificate? {
    guard let certRef = SecCertificateCreateWithData(nil, certData as CFData) else {
        _ = checkErr(errSecIO, &outError)
        return nil
    }

    let attrs: [CFString: Any] = [
        kSecClass: kSecClassCertificate,
        kSecValueRef: certRef,
    ]
    var result: CFTypeRef?
    var err = SecItemAdd(attrs as CFDictionary, &result)
    if err != noErr {
        NSLog("ERROR: SecItemAdd() returned %i", err)
    }

    // kSecAttrLabel is not settable on Mac OS (it's automatically generated from the principal
    // name.) Instead we use the "preference" mapping mechanism, which only exists on Mac OS.
    if err == noErr {
        err = SecCertificateSetPreferred(certRef, label as CFString, nil)
    }
    if err == noErr {
        // Check if this is an identity cert, i.e. we have the corresponding private key.
        // If so, we'll also set the preference for the resulting SecIdentityRef.
        var identRef: SecIdentity?
        if SecIdentityCreateWithCertificate(nil, certRef, &identRef) == noErr, let ident = identRef {
            err = SecIdentitySetPreferred(ident, label as CFString, nil)
        }
    }
    _ = checkErr(err, &outError)
    return certRef
}

private func relativeTimeFromOID(_ values: [AnyHashable: Any], _ oid: CFString) -> Double {
    guard let entry = values[oid as String] as? [String: Any],
          let dateNum = entry["value"] as? Double else {
        return 0.0
    }
    return dateNum - CFAbsoluteTimeGetCurrent()
}

private func checkCertValid(_ cert: SecCertificate, expirationInterval: TimeInterval) -> Bool {
    let oids: [CFString] = [kSecOIDX509V1ValidityNotAfter, kSecOIDX509V1ValidityNotBefore]
    guard let valuesRef = SecCertificateCopyValues(cert, oids as CFArray, nil) else { return false }
    let values = valuesRef as! [AnyHashable: Any]
    return relativeTimeFromOID(values, kSecOIDX509V1ValidityNotAfter) >= 0.0
        && relativeTimeFromOID(values, kSecOIDX509V1ValidityNotBefore) <= 0.0
}

private func findIdentity(_ label: String, expirationInterval: TimeInterval) -> SecIdentity? {
    guard let identity = SecIdentityCopyPreferred(label as CFString, nil, nil) else { return nil }

    // Check that the cert hasn't expire yet:
    var cert: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &cert) == noErr, let certRef = cert else {
        return nil
    }
    if !checkCertValid(certRef, expirationInterval: expirationInterval) {
        NSLog("SSL identity labeled \"%@\" has expired", label)
        _ = MYDeleteAnonymousIdentity(label)
        return nil
    }
    return identity
}

// MARK: - Public API

/// Generates a valid but anonymous X.509 certificate (with 2048-bit RSA key) that's useable for
/// an SSL server. It's anonymous because it's self-signed and the "subject" and "issuer" strings
/// are just fixed placeholders.
/// The cert and key are stored in the keychain under the given label; if they already exist and
/// haven't expired, the existing identity will be returned instead of creating a new one.
@discardableResult
public func MYGetOrCreateAnonymousIdentity(_ label: String,
                                            _ expirationInterval: TimeInterval,
                                            _ outError: inout NSError?) -> SecIdentity? {
    precondition(!label.isEmpty)
    if let ident = findIdentity(label, expirationInterval: expirationInterval) {
        return ident
    }

    NSLog("Generating new anonymous self-signed SSL identity labeled \"%@\"...", label)
    var publicKey: SecKey?
    var privateKey: SecKey?
    guard generateRSAKeyPair(sizeInBits: kKeySizeInBits, permanent: true, label: label,
                              publicKey: &publicKey, privateKey: &privateKey,
                              outError: &outError) else {
        return nil
    }
    guard let certData = generateAnonymousCert(publicKey: publicKey!, privateKey: privateKey!,
                                                expirationInterval: expirationInterval,
                                                outError: &outError) else {
        return nil
    }
    guard let certRef = addCertToKeychain(certData, label: label, outError: &outError) else {
        return nil
    }

    var ident: SecIdentity?
    guard checkErr(SecIdentityCreateWithCertificate(nil, certRef, &ident), &outError) else {
        NSLog("MYAnonymousIdentity: Can't find identity we just created")
        return nil
    }
    return ident
}

/// Removes an identity created by MYGetOrCreateAnonymousIdentity from the keychain.
@discardableResult
public func MYDeleteAnonymousIdentity(_ label: String) -> Bool {
    let attrs: [CFString: Any] = [
        kSecClass: kSecClassIdentity,
        kSecAttrLabel: label,
    ]
    let err = SecItemDelete(attrs as CFDictionary)
    if err != noErr && err != errSecItemNotFound {
        NSLog("Unexpected error %d deleting identity from keychain", err)
    }
    return err == noErr
}

/// Convenience function to get the SHA-1 digest of a certificate.
/// This is a handy way to uniquely identify the certificate.
public func MYGetCertificateDigest(_ cert: SecCertificate) -> Data {
    let data = SecCertificateCopyData(cert) as Data
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
    data.withUnsafeBytes { ptr in
        CC_SHA1(ptr.baseAddress, CC_LONG(data.count), &digest)
    }
    return Data(digest)
}

/*
 Copyright (c) 2014-15, Jens Alfke <jens@mooseyard.com>. All rights reserved.

 Redistribution and use in source and binary forms, with or without modification, are permitted
 provided that the following conditions are met:

 * Redistributions of source code must retain the above copyright notice, this list of conditions
 and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright notice, this list of conditions
 and the following disclaimer in the documentation and/or other materials provided with the
 distribution.

 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR
 IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
 FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRI-
 BUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
  PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
 THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
