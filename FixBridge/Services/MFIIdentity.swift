import CryptoKit
import Darwin
import Foundation
import Security

struct MFIIdentity: Sendable {
    static let maximumBytes = 32_768

    struct CertificateValidity: Sendable {
        enum Status: Equatable { case valid, notYetValid, expired }

        let startsAt: Date
        let expiresAt: Date

        func status(at date: Date) -> Status {
            if date < startsAt { return .notYetValid }
            if date > expiresAt { return .expired }
            return .valid
        }

        fileprivate init?(_ certificate: SecCertificate) {
            let keys = [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter]
            guard
                let properties = SecCertificateCopyValues(certificate, keys as CFArray, nil)
                    as? [String: [String: Any]]
            else { return nil }

            func date(for key: CFString) -> Date? {
                // Security returns these X.509 fields as seconds since the CF absolute time epoch.
                let value = properties[key as String]?[kSecPropertyKeyValue as String]
                guard let number = value as? NSNumber, number.doubleValue.isFinite else { return nil }
                return Date(timeIntervalSinceReferenceDate: number.doubleValue)
            }

            guard let start = date(for: kSecOIDX509V1ValidityNotBefore),
                let end = date(for: kSecOIDX509V1ValidityNotAfter), start <= end
            else { return nil }
            startsAt = start
            expiresAt = end
        }
    }

    struct Certificate: Sendable {
        fileprivate struct Entry: Sendable {
            let publicKey: Data
            let validity: CertificateValidity?
        }

        let data: Data
        fileprivate let entries: [Entry]

        init(data: Data) throws {
            guard (1...MFIIdentity.maximumBytes).contains(data.count) else {
                throw FixBridgeError("The certificate or private key file is empty or too large. Select another file.")
            }
            var decoder: CMSDecoder?
            guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder,
                data.withUnsafeBytes({
                    guard let bytes = $0.baseAddress else { return errSecParam }
                    return CMSDecoderUpdateMessage(decoder, bytes, $0.count)
                }) == errSecSuccess,
                CMSDecoderFinalizeMessage(decoder) == errSecSuccess
            else {
                throw FixBridgeError("Choose a DER PKCS#7 certificate (certificate.p7b).")
            }
            var certs: CFArray?
            guard CMSDecoderCopyAllCerts(decoder, &certs) == errSecSuccess,
                let certs = certs as? [SecCertificate]
            else {
                throw FixBridgeError("The file contains no usable MFi certificate. Select another certificate file.")
            }
            let entries = certs.compactMap { certificate -> Entry? in
                guard let key = SecCertificateCopyKey(certificate),
                    let data = SecKeyCopyExternalRepresentation(key, nil) as Data?,
                    (try? P256.Signing.PublicKey(x963Representation: data)) != nil
                else { return nil }
                return Entry(publicKey: data, validity: CertificateValidity(certificate))
            }
            guard !entries.isEmpty else {
                throw FixBridgeError("The file contains no usable MFi certificate. Select another certificate file.")
            }
            self.data = data
            self.entries = entries
        }
    }

    let certificate: Data
    let certificateValidity: CertificateValidity?
    private let key: P256.Signing.PrivateKey

    init(certificate: Certificate, pkcs8: Data) throws {
        guard (1...Self.maximumBytes).contains(pkcs8.count) else {
            throw FixBridgeError("The certificate or private key file is empty or too large. Select another file.")
        }
        let key: P256.Signing.PrivateKey
        do {
            key = try P256.Signing.PrivateKey(derRepresentation: pkcs8)
        } catch {
            throw FixBridgeError("Choose an unencrypted DER P-256 private key (identity.pk8).")
        }
        let publicKey = key.publicKey.x963Representation
        let matches = certificate.entries.filter { $0.publicKey == publicKey }
        guard matches.count == 1, let match = matches.first else {
            throw FixBridgeError(
                "The certificate and private key do not match, or the certificate file contains duplicate certificates. Select the correct files and try again."
            )
        }
        self.certificate = certificate.data
        certificateValidity = match.validity
        self.key = key
    }

    func sign(challenge: Data) throws -> Data {
        guard challenge.count == 32 else {
            throw FixBridgeError("The iPhone returned an MFi challenge with an invalid length.")
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 256,
        ]
        guard
            let signingKey = SecKeyCreateWithData(
                key.x963Representation as CFData, attributes as CFDictionary, nil
            ),
            let der = SecKeyCreateSignature(
                signingKey, .ecdsaSignatureDigestX962SHA256, challenge as CFData, nil
            ) as Data?
        else {
            throw FixBridgeError("Local MFi signing failed.")
        }
        return try P256.Signing.ECDSASignature(derRepresentation: der).rawRepresentation
    }
}

enum IdentityStore {
    private struct Files: Codable {
        let certificate: Data
        let pkcs8: Data
    }

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ApplicationIdentity.currentIdentifier,
            kSecAttrAccount as String: "MFi-v3",
            kSecUseDataProtectionKeychain as String: false,
        ]
    }

    static func load() throws -> MFIIdentity? {
        var search = query
        search[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw FixBridgeError("Could not read the keychain (\(status)).")
        }
        let files = try PropertyListDecoder().decode(Files.self, from: data)
        return try MFIIdentity(certificate: MFIIdentity.Certificate(data: files.certificate), pkcs8: files.pkcs8)
    }

    static func readCertificate(_ url: URL) throws -> MFIIdentity.Certificate {
        try MFIIdentity.Certificate(data: read(url))
    }

    static func save(certificate: MFIIdentity.Certificate, key: URL) throws -> MFIIdentity {
        let files = try Files(certificate: certificate.data, pkcs8: read(key))
        let identity = try MFIIdentity(certificate: certificate, pkcs8: files.pkcs8)
        let data = try PropertyListEncoder().encode(files)
        try Task.checkCancellation()
        let change = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, change as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(change) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw FixBridgeError("Could not save to the keychain (\(status)).")
        }
        return identity
    }

    private static func read(_ url: URL) throws -> Data {
        let invalidFile = FixBridgeError("Choose a readable certificate or private key file.")
        guard url.isFileURL else { throw invalidFile }
        let fd = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        }
        guard fd >= 0 else { throw invalidFile }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }

        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw invalidFile }
        let limit = MFIIdentity.maximumBytes
        guard info.st_size <= limit else { throw FixBridgeError("The credential file is too large.") }
        var data = Data()
        while let chunk = try handle.read(upToCount: limit + 1 - data.count), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= limit else { throw FixBridgeError("The credential file is too large.") }
        }
        return data
    }
}
