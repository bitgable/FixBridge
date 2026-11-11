import CryptoKit
import Foundation

@main
struct CredentialChecks {
    static func reject(_ operation: () throws -> Void) {
        do {
            try operation()
            fatalError("Expected invalid credentials to be rejected")
        } catch {}
    }

    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let certificateURL = directory.appendingPathComponent("certificate.p7b")
        let keyURL = directory.appendingPathComponent("identity.pk8")
        let certificate = try IdentityStore.readCertificate(certificateURL)
        let key = try Data(contentsOf: keyURL)
        let identity = try MFIIdentity(certificate: certificate, pkcs8: key)
        guard let validity = identity.certificateValidity else { fatalError("Missing certificate validity") }
        assert(validity.expiresAt.timeIntervalSince(validity.startsAt) == 86_400)
        assert(validity.status(at: validity.startsAt.addingTimeInterval(-1)) == .notYetValid)
        assert(validity.status(at: validity.startsAt) == .valid)
        assert(validity.status(at: validity.expiresAt) == .valid)
        assert(validity.status(at: validity.expiresAt.addingTimeInterval(1)) == .expired)
        let digest = SHA256.hash(data: Data("FixBridge regression fixture".utf8))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: identity.sign(challenge: Data(digest)))
        let publicKey = try P256.Signing.PrivateKey(derRepresentation: key).publicKey
        assert(publicKey.isValidSignature(signature, for: digest))
        reject { _ = try IdentityStore.readCertificate(keyURL) }
        reject { _ = try MFIIdentity(certificate: certificate, pkcs8: Data(contentsOf: certificateURL)) }
        reject {
            _ = try MFIIdentity(
                certificate: certificate,
                pkcs8: P256.Signing.PrivateKey().derRepresentation)
        }
        reject { _ = try identity.sign(challenge: Data(repeating: 0, count: 31)) }
        reject { _ = try MFIIdentity.Certificate(data: Data()) }
        reject { _ = try MFIIdentity.Certificate(data: Data(repeating: 0, count: MFIIdentity.maximumBytes + 1)) }
        reject { _ = try IdentityStore.readCertificate(directory.appendingPathComponent("not-a-file")) }
        print(
            "Credential checks passed: parsing, matching, signature verification, swapped files, wrong key, size limits, non-regular file rejection. No keychain writes."
        )
    }
}
