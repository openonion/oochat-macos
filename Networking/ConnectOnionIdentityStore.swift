import ConnectOnionKit
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
        return try loadOrCreateIdentityLocked()
    }

    /// Call with `lock` held.
    private func loadOrCreateIdentityLocked() throws -> ConnectOnionIdentity {
        if let identity = try storedIdentityLocked() {
            return identity
        }

        let identity = ConnectOnionIdentity()
        try saveIdentityFile(identity.rawPrivateKey)
        cachedIdentity = identity
        return identity
    }

    /// The identity in the cache or the key file, without minting one. Call with `lock` held.
    private func storedIdentityLocked() throws -> ConnectOnionIdentity? {
        if let cachedIdentity {
            return cachedIdentity
        }
        guard let data = try loadIdentityFile() else { return nil }
        let identity = try ConnectOnionIdentity(rawPrivateKey: data)
        cachedIdentity = identity
        return identity
    }

    // MARK: Device Link

    /// Takes on the key a Device Link delivered: writes it atomically in place of the current one,
    /// so the next signature uses it, and marks this device linked. A malformed key changes nothing.
    func replacePrivateKey(with rawKey: Data) throws {
        let identity = try ConnectOnionIdentity(rawPrivateKey: rawKey)
        lock.lock()
        defer { lock.unlock() }
        try saveIdentityFile(identity.rawPrivateKey)
        cachedIdentity = identity
        // The key is what matters: a flag that failed to write only leaves the viewer off.
        try? writeLinkedFlag(for: identity)
    }

    /// Whether this device shares its Identity with another. The flag beside the key holds the
    /// Address it was set for, so it counts only while that key is the current one: a lost and
    /// re-created key reads as unlinked with nothing to clean up.
    var isLinked: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let fileURL = try? identityFileURL(),
              let flag = try? Data(contentsOf: Self.linkedFlagURL(for: fileURL)),
              let identity = try? storedIdentityLocked()
        else { return false }
        return flag == Data(identity.address.utf8)
    }

    /// The Giving Device, once its Identity was sent.
    func markLinked() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let identity = try storedIdentityLocked() else { throw CocoaError(.fileReadNoSuchFile) }
        try writeLinkedFlag(for: identity)
    }

    /// The saved key, or nil if there is none yet. Never creates one.
    func storedPrivateKey() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return try storedIdentityLocked()?.rawPrivateKey
    }

    private static func linkedFlagURL(for identityFileURL: URL) -> URL {
        identityFileURL.appendingPathExtension("linked")
    }

    private func writeLinkedFlag(for identity: ConnectOnionIdentity) throws {
        let fileURL = try identityFileURL()
        try secureIdentityDirectory(at: fileURL.deletingLastPathComponent())
        try Data(identity.address.utf8).write(to: Self.linkedFlagURL(for: fileURL), options: .atomic)
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
        "0x" + Hex.encode(privateKey.publicKey.rawRepresentation)
    }

    var rawPrivateKey: Data {
        privateKey.rawRepresentation
    }

    func canonicalJSON(for payload: [String: Any]) throws -> Data {
        CanonicalJSON.data(from: payload.mapValues { JSONValue(any: $0) })
    }

    func signature(for payload: [String: Any]) throws -> String {
        let canonical = try canonicalJSON(for: payload)
        return Hex.encode(try privateKey.signature(for: canonical))
    }
}

/// All mutable state is guarded by `lock`.
extension ConnectOnionIdentityStore: @unchecked Sendable {}
