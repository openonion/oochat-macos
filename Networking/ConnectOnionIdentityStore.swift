import CryptoKit
import Foundation

/// Loads or lazily creates the app's Ed25519 identity on disk. File and
/// directory permissions are re-tightened to 0600/0700 on every access so a
/// permissive umask never leaves the private key exposed.
nonisolated final class ConnectOnionIdentityStore {
    static let shared = ConnectOnionIdentityStore()

    private let identityFileURLOverride: URL?
    private let lock = NSLock()
    private var cachedIdentity: ConnectOnionIdentity?

    init(identityFileURL: URL? = nil) {
        identityFileURLOverride = identityFileURL
    }

    func loadOrCreateIdentity() throws -> ConnectOnionIdentity {
        lock.lock()
        defer { lock.unlock() }

        if let cachedIdentity {
            return cachedIdentity
        }

        if let data = try loadIdentityFile() {
            let identity = try ConnectOnionIdentity(rawPrivateKey: data)
            cachedIdentity = identity
            return identity
        }

        let identity = ConnectOnionIdentity()
        try saveIdentityFile(identity.rawPrivateKey)
        cachedIdentity = identity
        return identity
    }

    private func loadIdentityFile() throws -> Data? {
        let fileURL = try identityFileURL()
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        try secureIdentityDirectory(at: fileURL.deletingLastPathComponent())
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        return try Data(contentsOf: fileURL)
    }

    private func saveIdentityFile(_ data: Data) throws {
        let fileURL = try identityFileURL()
        try secureIdentityDirectory(at: fileURL.deletingLastPathComponent())
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private func identityFileURL() throws -> URL {
        if let identityFileURLOverride {
            return identityFileURLOverride
        }

        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport
            .appendingPathComponent(
                "ai.openonion.oochat.macos",
                isDirectory: true
            )
            .appendingPathComponent("connectonion-identity", isDirectory: true)
            .appendingPathComponent("ed25519-private-key", isDirectory: false)
    }

    private func secureIdentityDirectory(at directoryURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
    }

}

/// Ed25519 keypair behind the client's `0x` address. Signatures cover
/// canonical key-sorted JSON so the agent can rebuild the exact signed bytes.
nonisolated struct ConnectOnionIdentity {
    private let privateKey: Curve25519.Signing.PrivateKey

    init() {
        privateKey = Curve25519.Signing.PrivateKey()
    }

    init(rawPrivateKey: Data) throws {
        privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawPrivateKey)
    }

    var address: String {
        "0x" + privateKey.publicKey.rawRepresentation.hexString
    }

    var rawPrivateKey: Data {
        privateKey.rawRepresentation
    }

    func canonicalJSON(for payload: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        )
    }

    func signature(for payload: [String: Any]) throws -> String {
        let canonical = try canonicalJSON(for: payload)
        return try privateKey.signature(for: canonical).hexString
    }
}

/// Lowercase hex, the encoding the protocol uses for addresses and signatures.
nonisolated private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
