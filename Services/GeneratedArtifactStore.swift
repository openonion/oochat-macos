import CryptoKit
import Foundation

nonisolated enum GeneratedArtifactStoreError: LocalizedError, Equatable {
    case invalidIdentifier
    case invalidName
    case invalidSize
    case invalidHash
    case tooLarge
    case cacheMissing
    case destinationExists
    case desktopUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier:
            return "The Agent returned an invalid file identifier."
        case .invalidName:
            return "The Agent returned an invalid file name."
        case .invalidSize:
            return "The downloaded file size does not match its metadata."
        case .invalidHash:
            return "The downloaded file failed its integrity check."
        case .tooLarge:
            return "The downloaded file exceeds the 8 MB limit."
        case .cacheMissing:
            return "This file is no longer available in the local cache."
        case .destinationExists:
            return "A file already exists at that location."
        case .desktopUnavailable:
            return "The Desktop folder is unavailable."
        }
    }
}

nonisolated final class GeneratedArtifactStore: @unchecked Sendable {
    static let shared = GeneratedArtifactStore()
    static let maximumPayloadBytes = 8 * 1_024 * 1_024

    private let fileManager: FileManager
    private let rootDirectory: URL
    private let desktopDirectoryProvider: () throws -> URL
    private let lock = NSLock()

    init(
        fileManager: FileManager = .default,
        rootDirectory: URL? = nil,
        desktopDirectoryProvider: (() throws -> URL)? = nil
    ) {
        self.fileManager = fileManager
        self.rootDirectory = rootDirectory
            ?? Self.defaultRootDirectory(fileManager: fileManager)
        self.desktopDirectoryProvider = desktopDirectoryProvider ?? {
            guard let desktop = fileManager.urls(
                for: .desktopDirectory,
                in: .userDomainMask
            ).first else {
                throw GeneratedArtifactStoreError.desktopUnavailable
            }
            return desktop
        }
    }

    @discardableResult
    func record(_ payload: GeneratedArtifactPayload) throws
        -> GeneratedArtifactReference {
        try validate(payload)
        return try lock.withLock {
            try prepareRootDirectory()
            let destination = cacheURL(for: payload.reference)
            if fileManager.fileExists(atPath: destination.path) {
                let existingData = try Data(
                    contentsOf: destination,
                    options: [.mappedIfSafe]
                )
                guard existingData == payload.data else {
                    throw GeneratedArtifactStoreError.invalidHash
                }
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: destination.path
                )
                return payload.reference
            }
            try payload.data.write(to: destination, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
            return payload.reference
        }
    }

    func contains(_ reference: GeneratedArtifactReference) -> Bool {
        lock.withLock {
            fileManager.fileExists(atPath: cacheURL(for: reference).path)
        }
    }

    func save(
        _ reference: GeneratedArtifactReference,
        to destination: URL,
        replacingExisting: Bool
    ) throws -> URL {
        try lock.withLock {
            let data = try verifiedData(for: reference)
            if fileManager.fileExists(atPath: destination.path),
               !replacingExisting {
                throw GeneratedArtifactStoreError.destinationExists
            }
            try data.write(to: destination, options: [.atomic])
            return destination
        }
    }

    func saveToDesktop(_ reference: GeneratedArtifactReference) throws -> URL {
        try lock.withLock {
            let data = try verifiedData(for: reference)
            let desktop = try desktopDirectoryProvider()
            var destination = desktop.appendingPathComponent(
                reference.name,
                isDirectory: false
            )
            var suffix = 2
            while fileManager.fileExists(atPath: destination.path) {
                destination = desktop.appendingPathComponent(
                    Self.numberedName(reference.name, suffix: suffix),
                    isDirectory: false
                )
                suffix += 1
            }
            try data.write(to: destination, options: [.atomic])
            return destination
        }
    }

    func removeArtifacts(_ references: [GeneratedArtifactReference]) {
        lock.withLock {
            for reference in references {
                try? fileManager.removeItem(at: cacheURL(for: reference))
            }
        }
    }

    private func verifiedData(
        for reference: GeneratedArtifactReference
    ) throws -> Data {
        let url = cacheURL(for: reference)
        guard fileManager.fileExists(atPath: url.path) else {
            throw GeneratedArtifactStoreError.cacheMissing
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        try validate(GeneratedArtifactPayload(reference: reference, data: data))
        return data
    }

    private func validate(_ payload: GeneratedArtifactPayload) throws {
        let reference = payload.reference
        guard UUID(uuidString: reference.artifactID) != nil else {
            throw GeneratedArtifactStoreError.invalidIdentifier
        }
        guard Self.isValidFileName(reference.name) else {
            throw GeneratedArtifactStoreError.invalidName
        }
        guard payload.data.count <= Self.maximumPayloadBytes else {
            throw GeneratedArtifactStoreError.tooLarge
        }
        guard payload.data.count == reference.sizeBytes,
              reference.sizeBytes >= 0 else {
            throw GeneratedArtifactStoreError.invalidSize
        }
        let digest = SHA256.hash(data: payload.data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest.caseInsensitiveCompare(reference.sha256) == .orderedSame else {
            throw GeneratedArtifactStoreError.invalidHash
        }
    }

    private func prepareRootDirectory() throws {
        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: rootDirectory.path
        )
    }

    private func cacheURL(for reference: GeneratedArtifactReference) -> URL {
        rootDirectory.appendingPathComponent(
            "\(reference.artifactID).artifact",
            isDirectory: false
        )
    }

    private static func defaultRootDirectory(fileManager: FileManager) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("ConnectOnionMacClient", isDirectory: true)
            .appendingPathComponent("GeneratedArtifacts", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    private static func isValidFileName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\\")
            && !name.contains("\0")
            && URL(fileURLWithPath: name).lastPathComponent == name
    }

    private static func numberedName(_ name: String, suffix: Int) -> String {
        let url = URL(fileURLWithPath: name)
        let fileExtension = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        if fileExtension.isEmpty {
            return "\(stem) (\(suffix))"
        }
        return "\(stem) (\(suffix)).\(fileExtension)"
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
